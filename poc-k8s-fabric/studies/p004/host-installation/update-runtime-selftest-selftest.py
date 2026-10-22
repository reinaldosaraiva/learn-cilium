#!/usr/bin/env python3
"""Exercise one-file runtime maintenance only in retained private fixtures."""

from __future__ import annotations

import errno
import hashlib
import json
import os
from pathlib import PurePosixPath
import platform
import stat
import struct
import subprocess
import sys
import tempfile
from types import ModuleType
from typing import Any, Callable


CODE_DIRECTORY_PREFIX = "p004-runtime-selftest-maintenance-code-"
FIXTURE_DIRECTORY_PREFIX = "p004-reviewed-source-stage-fixture-"
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
FILE_READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | getattr(os, "O_NOATIME", 0)
FILE_WRITE_FLAGS = os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC
ACL_NAME = "system.posix_acl_access"
MAX_BYTES = 16 * 1024 * 1024
_RETAINED_FIXTURES: list[str] = []


class FixtureSkip(RuntimeError):
    """A required Linux filesystem feature is unavailable for the controls."""


def _reject_acl(fd: int, label: str) -> None:
    try:
        names = set(os.listxattr(fd))
    except (OSError, TypeError) as error:
        raise AssertionError(f"cannot inspect ACLs for {label}: {error}") from error
    if {"system.posix_acl_access", "system.posix_acl_default"} & names:
        raise AssertionError(f"unexpected ACL on {label}")


def _open_absolute_directory(path: str) -> tuple[dict[str, int], int]:
    if not path.startswith("/") or str(PurePosixPath(path)) != path:
        raise AssertionError(f"non-canonical path: {path}")
    fds = {"/": os.open("/", DIRECTORY_FLAGS)}
    current = "/"
    try:
        for part in PurePosixPath(path).parts[1:]:
            child = str(PurePosixPath(current) / part)
            named = os.stat(part, dir_fd=fds[current], follow_symlinks=False)
            if not stat.S_ISDIR(named.st_mode):
                raise AssertionError(f"path component is not a directory: {child}")
            fd = os.open(part, DIRECTORY_FLAGS, dir_fd=fds[current])
            opened = os.fstat(fd)
            if (named.st_dev, named.st_ino) != (opened.st_dev, opened.st_ino):
                os.close(fd)
                raise AssertionError(f"path changed while opening: {child}")
            fds[child] = fd
            current = child
        return fds, fds[current]
    except BaseException:
        for fd in reversed(tuple(fds.values())):
            os.close(fd)
        raise


def _read_regular(parent_fd: int, name: str, *, label: str, mode: int) -> bytes:
    fd = os.open(name, FILE_READ_FLAGS, dir_fd=parent_fd)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or (before.st_uid, before.st_gid, stat.S_IMODE(before.st_mode), before.st_nlink) != (0, 0, mode, 1):
            raise AssertionError(f"unexpected metadata on {label}")
        _reject_acl(fd, label)
        chunks: list[bytes] = []
        total = 0
        while True:
            block = os.read(fd, min(1024 * 1024, MAX_BYTES + 1 - total))
            if not block:
                break
            chunks.append(block)
            total += len(block)
            if total > MAX_BYTES:
                raise AssertionError(f"oversized fixture file: {label}")
        after = os.fstat(fd)
        named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        signature = lambda item: (item.st_dev, item.st_ino, item.st_uid, item.st_gid, item.st_mode, item.st_nlink, item.st_size, item.st_atime_ns, item.st_mtime_ns, item.st_ctime_ns)
        if signature(before) != signature(after) or (named.st_dev, named.st_ino) != (after.st_dev, after.st_ino):
            raise AssertionError(f"fixture file changed while reading: {label}")
        return b"".join(chunks)
    finally:
        os.close(fd)


def _load_helper() -> tuple[ModuleType, str]:
    script_path = os.path.abspath(__file__)
    script = PurePosixPath(script_path)
    code_root = str(script.parent)
    if script.name != "update-runtime-selftest-selftest.py" or PurePosixPath(code_root).parent != PurePosixPath("/var/tmp"):
        raise AssertionError("selftest must be directly inside the private /var/tmp code directory")
    if not PurePosixPath(code_root).name.startswith(CODE_DIRECTORY_PREFIX):
        raise AssertionError("selftest code directory name is outside the fixed prefix")
    fds, code_fd = _open_absolute_directory(code_root)
    try:
        tmp = os.fstat(fds["/var/tmp"])
        info = os.fstat(code_fd)
        if (tmp.st_uid, tmp.st_gid) != (0, 0) or not tmp.st_mode & stat.S_ISVTX:
            raise AssertionError("/var/tmp must be root-owned and sticky")
        if (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != (0, 0, 0o700):
            raise AssertionError("code directory must be root:root mode 0700")
        _reject_acl(fds["/var/tmp"], "/var/tmp")
        _reject_acl(code_fd, code_root)
        raw = _read_regular(code_fd, "update-runtime-selftest.py", label="maintenance helper", mode=0o600)
        module_name = "p004_runtime_selftest_maintenance_selftest_target"
        if module_name in sys.modules:
            raise AssertionError("selftest helper module name is already registered")
        helper = ModuleType(module_name)
        helper.__file__ = f"{code_root}/update-runtime-selftest.py"
        sys.modules[module_name] = helper
        try:
            exec(compile(raw, helper.__file__, "exec"), helper.__dict__)
        except BaseException:
            sys.modules.pop(module_name, None)
            raise
        return helper, code_root
    finally:
        for fd in reversed(tuple(fds.values())):
            os.close(fd)


def _mkdir(path: str, mode: int) -> None:
    old_mask = os.umask(0)
    try:
        os.mkdir(path, mode)
    finally:
        os.umask(old_mask)
    os.chown(path, 0, 0)
    os.chmod(path, mode)


def _write_file(path: str, data: bytes, mode: int) -> None:
    old_mask = os.umask(0)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, mode)
    finally:
        os.umask(old_mask)
    try:
        view = memoryview(data)
        while view:
            written = os.write(fd, view)
            if written <= 0:
                raise OSError("short fixture write")
            view = view[written:]
        os.fchown(fd, 0, 0)
        os.fchmod(fd, mode)
        os.fsync(fd)
    finally:
        os.close(fd)


def _ensure_directory_tree(root: str, parent: str) -> None:
    relative = PurePosixPath(parent).relative_to(root)
    current = root
    for part in relative.parts:
        current = str(PurePosixPath(current) / part)
        try:
            os.mkdir(current, 0o755)
        except FileExistsError:
            info = os.lstat(current)
            if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
                raise AssertionError(f"fixture path component changed type: {current}")
        os.chown(current, 0, 0)
        # The H4-like evidence directories are private and are prepared first.
        if stat.S_IMODE(os.lstat(current).st_mode) not in (0o700, 0o755):
            os.chmod(current, 0o755)


def _make_fixture(helper: ModuleType, assets: Any, payload: bytes) -> dict[str, Any]:
    base = tempfile.mkdtemp(prefix=FIXTURE_DIRECTORY_PREFIX, dir="/var/tmp")
    _RETAINED_FIXTURES.append(base)
    os.chown(base, 0, 0)
    os.chmod(base, 0o700)
    root = str(PurePosixPath(base) / "root")
    evidence = f"{root}/evidence"
    p004 = f"{evidence}/P004"
    s002 = f"{p004}/S002"
    _mkdir(root, 0o755)
    _mkdir(evidence, 0o755)
    _mkdir(p004, 0o700)
    _mkdir(s002, 0o700)
    _mkdir(f"{base}/markers", 0o755)
    _mkdir(f"{base}/history-one", 0o700)
    _mkdir(f"{base}/history-two", 0o700)
    _write_file(f"{base}/lock", b"fixture lock; immutable during maintenance\n", 0o600)
    proof_one = b'{"status":"PROVED"}\n'
    proof_two = b'{"status":"PASS_STAGED_SOURCE_ONLY"}\n'
    _write_file(f"{base}/history-one/terminal.json", proof_one, 0o600)
    _write_file(f"{base}/history-two/terminal.json", proof_two, 0o600)

    old_payload = b"original X05 runtime selftest fixture\n"
    for index, entry in enumerate(assets.baseline.entries):
        destination = helper._entry_path(
            helper._RuntimeConfig(
                directories_config=type("RootConfig", (), {"root": root})(),
                ancestor_pins={},
                code_root="/var/tmp/unused",
                is_fixture=True,
            ),
            entry.destination,
        )
        parent = str(PurePosixPath(destination).parent)
        _ensure_directory_tree(root, parent)
        data = old_payload if entry.destination == helper.TARGET else f"protected fixture entry {index}: {entry.destination}\n".encode()
        _write_file(destination, data, entry.mode)

    config = helper._fixture_config(base, assets.publisher)
    baseline = helper._fixture_baseline(base, assets.publisher, payload, assets.baseline.entries, old_payload)
    return {
        "base": base,
        "root": root,
        "target": helper._entry_path(config, helper.TARGET),
        "old_payload": old_payload,
        "config": config,
        "baseline": baseline,
        "payload": payload,
        "payload_sha256": hashlib.sha256(payload).hexdigest(),
        "store": config.directories_config.store,
    }


def _entry_path(fixture: dict[str, Any], helper: ModuleType, destination: str) -> str:
    return helper._entry_path(fixture["config"], destination)


def _protected_entry(fixture: dict[str, Any], helper: ModuleType) -> Any:
    return next(entry for entry in fixture["baseline"].entries if entry.destination != helper.TARGET)


def _expected_refusal(
    operation: Callable[[], Any],
    label: str,
    cause: str,
    helper: ModuleType,
    assets: Any,
) -> str:
    try:
        operation()
    except Exception as error:
        current: BaseException | None = error
        text = []
        while current is not None:
            text.append(str(current))
            current = current.__cause__
        message = " | ".join(text)
        if cause not in message:
            raise AssertionError(f"{label} was refused for the wrong cause: {message}") from error
        if isinstance(error, helper.MaintenanceUnknown):
            raise AssertionError(f"{label} became UNKNOWN before any fixture effect") from error
        return message
    raise AssertionError(f"{label} was unexpectedly accepted")


def _open_fixture_file(path: str, flags: int = os.O_RDONLY) -> int:
    return os.open(path, flags | os.O_NOFOLLOW | os.O_CLOEXEC)


def _fixture_tree_snapshot(root: str) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    root_fd = os.open(root, DIRECTORY_FLAGS | getattr(os, "O_NOATIME", 0))
    pending: list[tuple[str, int]] = [(".", root_fd)]
    held: list[int] = [root_fd]
    while pending:
        relative, directory_fd = pending.pop()
        for name in sorted(os.listdir(directory_fd)):
            info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
            child = name if relative == "." else f"{relative}/{name}"
            record: dict[str, Any] = {
                "dev": info.st_dev,
                "inode": info.st_ino,
                "uid": info.st_uid,
                "gid": info.st_gid,
                "mode": stat.S_IMODE(info.st_mode),
                "nlink": info.st_nlink,
                "size": info.st_size,
                "atime_ns": info.st_atime_ns,
                "mtime_ns": info.st_mtime_ns,
                "ctime_ns": info.st_ctime_ns,
            }
            if stat.S_ISDIR(info.st_mode):
                fd = os.open(name, DIRECTORY_FLAGS | getattr(os, "O_NOATIME", 0), dir_fd=directory_fd)
                opened = os.fstat(fd)
                if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
                    os.close(fd)
                    raise AssertionError(f"fixture directory changed during snapshot: {child}")
                held.append(fd)
                pending.append((child, fd))
                record["kind"] = "directory"
            elif stat.S_ISREG(info.st_mode):
                fd = os.open(name, FILE_READ_FLAGS, dir_fd=directory_fd)
                try:
                    digest = hashlib.sha256()
                    while block := os.read(fd, 65536):
                        digest.update(block)
                    after = os.fstat(fd)
                    named = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                    if (after.st_dev, after.st_ino) != (info.st_dev, info.st_ino) or (named.st_dev, named.st_ino) != (info.st_dev, info.st_ino):
                        raise AssertionError(f"fixture file changed during snapshot: {child}")
                    record["sha256"] = digest.hexdigest()
                    record["kind"] = "file"
                finally:
                    os.close(fd)
            elif stat.S_ISLNK(info.st_mode):
                target = os.readlink(name, dir_fd=directory_fd)
                after = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                if (after.st_dev, after.st_ino) != (info.st_dev, info.st_ino):
                    raise AssertionError(f"fixture symlink changed during snapshot: {child}")
                record["target"] = target
                record["kind"] = "symlink"
            else:
                record["kind"] = "other"
            result[child] = record
    for fd in reversed(held):
        os.close(fd)
    return result


def _write_fixture_store_shape(fixture: dict[str, Any], shape: str) -> None:
    store = fixture["store"]
    if shape == "empty-directory":
        _mkdir(store, 0o700)
    elif shape == "malformed-file":
        _write_file(store, b"not a ledger directory\n", 0o600)
    elif shape == "symlink":
        os.symlink(fixture["base"] + "/lock", store)
        os.chown(store, 0, 0, follow_symlinks=False)
    else:
        raise AssertionError(f"unknown ledger shape: {shape}")


def _fixture_dry(fixture: dict[str, Any], helper: ModuleType, assets: Any, attempt: str) -> Any:
    return helper._fixture_dry_run(
        assets,
        fixture["config"],
        fixture["baseline"],
        fixture["payload"],
        fixture["payload_sha256"],
        attempt,
    )


def _fixture_apply(fixture: dict[str, Any], helper: ModuleType, assets: Any, attempt: str, hook: Any = None) -> Any:
    return helper._fixture_apply(
        assets,
        fixture["config"],
        fixture["baseline"],
        fixture["payload"],
        fixture["payload_sha256"],
        attempt,
        hook,
    )


def _test_invalid_cli(helper: ModuleType, code_root: str) -> dict[str, Any]:
    helper_path = f"{code_root}/update-runtime-selftest.py"
    cases = (
        ("apply-without-attempt", ["--apply"]),
        ("dry-run-with-attempt", ["--dry-run", "--attempt", "a" * 32]),
        ("uppercase-attempt", ["--apply", "--attempt", "A" * 32]),
        ("root-override", ["--dry-run", "--root", "/tmp/foreign"]),
        ("hash-override", ["--apply", "--attempt", "a" * 32, "--sha256", "0" * 64]),
    )
    results = []
    for label, args in cases:
        process = subprocess.run(
            [sys.executable, "-B", helper_path, *args],
            input=b"",
            capture_output=True,
            cwd="/",
            env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"},
            check=False,
        )
        if process.returncode != 2:
            raise AssertionError(f"invalid CLI case {label} returned {process.returncode}")
        results.append({"case": label, "returncode": process.returncode})
    return {"cases": len(results), "results": results}


def _test_success_and_replay(helper: ModuleType, assets: Any, payload: bytes) -> dict[str, Any]:
    fixture = _make_fixture(helper, assets, payload)
    attempt = "1" * 32
    before = _fixture_tree_snapshot(fixture["base"])
    dry = _fixture_dry(fixture, helper, assets, attempt)
    after_dry = _fixture_tree_snapshot(fixture["base"])
    if dry["status"] != "PASS_DRY_RUN" or dry["effect_count"] != 0 or dry["planned_effect_count"] != 2:
        raise AssertionError(f"fixture dry run did not report exactly two planned effects: {dry}")
    if before != after_dry:
        raise AssertionError("fixture dry run changed bytes or metadata")
    original_info = os.lstat(fixture["target"])
    applied = _fixture_apply(fixture, helper, assets, attempt)
    if applied["status"] != "PASS_UPDATED_RUNTIME_SELFTEST_ONLY" or applied["effect_count"] != 2 or applied["protected_entries"] != 57:
        raise AssertionError(f"one-file fixture apply result drift: {applied}")
    new_bytes = open(fixture["target"], "rb").read()
    parked_path = f"{PurePosixPath(fixture['target']).parent}/.p004-runtime-selftest-{attempt}.tmp"
    old_bytes = open(parked_path, "rb").read()
    parked_info = os.lstat(parked_path)
    new_info = os.lstat(fixture["target"])
    if new_bytes != payload or old_bytes != fixture["old_payload"]:
        raise AssertionError("exchange did not preserve both exact payload versions")
    if (parked_info.st_dev, parked_info.st_ino) != (original_info.st_dev, original_info.st_ino):
        raise AssertionError("exchange did not retain the original inode under the parked name")
    if (parked_info.st_uid, parked_info.st_gid, stat.S_IMODE(parked_info.st_mode), parked_info.st_nlink, parked_info.st_size, parked_info.st_mtime_ns) != (
        0,
        0,
        0o644,
        1,
        len(fixture["old_payload"]),
        original_info.st_mtime_ns,
    ):
        raise AssertionError("parked original metadata drifted")
    if (new_info.st_uid, new_info.st_gid, stat.S_IMODE(new_info.st_mode), new_info.st_nlink, new_info.st_size) != (0, 0, 0o644, 1, len(payload)):
        raise AssertionError("new target metadata drifted")

    ledger_fd = os.open(fixture["store"], DIRECTORY_FLAGS)
    try:
        ledger_names = sorted(os.listdir(ledger_fd))
        expected_names = sorted([
            f"run-{attempt}.intent.json",
            f"run-{attempt}-step-001.intent.json",
            f"run-{attempt}-step-001.result.json",
            f"run-{attempt}-step-002.intent.json",
            f"run-{attempt}-step-002.result.json",
            f"run-{attempt}.terminal.json",
        ])
        if ledger_names != expected_names:
            raise AssertionError(f"fixture ledger record order/names drifted: {ledger_names}")
        records: dict[str, dict[str, Any]] = {}
        for name in ledger_names:
            raw = _read_regular(ledger_fd, name, label=name, mode=0o600)
            record = json.loads(raw)
            records[name] = record
        for sequence in (1, 2):
            intent = records[f"run-{attempt}-step-{sequence:03d}.intent.json"]
            result = records[f"run-{attempt}-step-{sequence:03d}.result.json"]
            if intent["sequence"] != sequence or intent["status"] != "INTENT_DURABLE" or result["sequence"] != sequence or result["status"] != "PROVED":
                raise AssertionError(f"fixture effect ledger sequence {sequence} is not durable/proved")
        terminal = records[f"run-{attempt}.terminal.json"]
        if terminal["status"] != "PASS_UPDATED_RUNTIME_SELFTEST_ONLY" or terminal["effect_count"] != 2 or terminal["protected_entries"] != 57:
            raise AssertionError("fixture terminal does not describe a one-file PASS")
    finally:
        os.close(ledger_fd)

    _expected_refusal(lambda: _fixture_dry(fixture, helper, assets, "2" * 32), "dry replay after success", "path must be absent", helper, assets)
    _expected_refusal(lambda: _fixture_apply(fixture, helper, assets, "2" * 32), "new attempt after success", "path must be absent", helper, assets)
    _expected_refusal(lambda: _fixture_apply(fixture, helper, assets, attempt), "same attempt replay after success", "path must be absent", helper, assets)
    return {"fixture": fixture["base"], "status": applied["status"], "ledger_records": len(ledger_names), "old_inode": parked_info.st_ino, "new_inode": new_info.st_ino}


def _test_preexisting_store_shapes(helper: ModuleType, assets: Any, payload: bytes) -> dict[str, Any]:
    cases = []
    for index, shape in enumerate(("empty-directory", "malformed-file", "symlink"), start=3):
        fixture = _make_fixture(helper, assets, payload)
        _write_fixture_store_shape(fixture, shape)
        attempt = str(index) * 32
        for label, action in (
            ("dry", lambda: _fixture_dry(fixture, helper, assets, attempt)),
            ("apply", lambda: _fixture_apply(fixture, helper, assets, attempt)),
        ):
            _expected_refusal(action, f"preexisting {shape} store {label}", "path must be absent", helper, assets)
        _expected_refusal(lambda: _fixture_apply(fixture, helper, assets, "f" * 32), f"new attempt blocked by {shape} store", "path must be absent", helper, assets)
        cases.append({"fixture": fixture["base"], "shape": shape, "dry_apply_refused": True})
    return {"shapes": len(cases), "cases": cases}


def _test_drift_case(
    helper: ModuleType,
    assets: Any,
    payload: bytes,
    label: str,
    cause: str,
    mutate: Callable[[dict[str, Any]], None],
) -> dict[str, Any]:
    fixture = _make_fixture(helper, assets, payload)
    mutate(fixture)
    _expected_refusal(lambda: _fixture_dry(fixture, helper, assets, "9" * 32), label, cause, helper, assets)
    return {"fixture": fixture["base"], "case": label, "refused": True}


def _set_acl(path: str) -> None:
    fd = _open_fixture_file(path, os.O_RDONLY)
    try:
        mode = stat.S_IMODE(os.fstat(fd).st_mode)
        owner = (mode >> 6) & 0o7
        group = (mode >> 3) & 0o7
        other = mode & 0o7
        # The named-user entry makes this an extended ACL.  Matching the
        # ACL mask to the original group bits keeps the inode mode unchanged.
        acl = struct.pack("<I", 2) + b"".join(
            (
                struct.pack("<HHI", 0x01, owner, 0xFFFFFFFF),
                struct.pack("<HHI", 0x02, 0o0, 1000),
                struct.pack("<HHI", 0x04, group, 0xFFFFFFFF),
                struct.pack("<HHI", 0x10, group, 0xFFFFFFFF),
                struct.pack("<HHI", 0x20, other, 0xFFFFFFFF),
            )
        )
        try:
            os.setxattr(fd, ACL_NAME, acl)
            os.fsync(fd)
        except OSError as error:
            if error.errno in {errno.ENOTSUP, errno.EOPNOTSUPP, errno.ENOSYS, errno.EINVAL}:
                raise FixtureSkip(f"filesystem cannot create the required POSIX ACL control: {error}") from error
            raise
        names = set(os.listxattr(fd))
        if ACL_NAME not in names:
            raise FixtureSkip("filesystem accepted setxattr but did not retain a POSIX ACL")
        if stat.S_IMODE(os.fstat(fd).st_mode) != mode:
            raise FixtureSkip("filesystem ACL changed the original permission bits")
    finally:
        os.close(fd)


def _test_unknown_retention(helper: ModuleType, assets: Any, payload: bytes, phase: str) -> dict[str, Any]:
    fixture = _make_fixture(helper, assets, payload)
    attempt = ("a" if phase == "after-write" else "b") * 32

    def fail_at(event: str, values: Any) -> None:
        expected = "after:create-new-selftest-file" if phase == "after-write" else "after:exchange-old-runtime-selftest"
        if event == expected:
            raise RuntimeError(f"fixture fault at {event}")

    try:
        _fixture_apply(fixture, helper, assets, attempt, fail_at)
    except helper.MaintenanceUnknown as error:
        pass
    else:
        raise AssertionError(f"{phase} fault did not produce sticky UNKNOWN")
    terminal_path = f"{fixture['store']}/run-{attempt}.terminal.json"
    if not os.path.isfile(terminal_path) or json.loads(open(terminal_path, "rb").read())["status"] != "UNKNOWN":
        raise AssertionError(f"{phase} did not retain an UNKNOWN terminal")
    temp_path = f"{PurePosixPath(fixture['target']).parent}/.p004-runtime-selftest-{attempt}.tmp"
    if phase == "after-write":
        if open(fixture["target"], "rb").read() != fixture["old_payload"] or open(temp_path, "rb").read() != payload:
            raise AssertionError("post-write UNKNOWN did not retain old and staged bytes")
    else:
        if open(fixture["target"], "rb").read() != payload or open(temp_path, "rb").read() != fixture["old_payload"]:
            raise AssertionError("post-exchange UNKNOWN did not retain new target and parked old bytes")
    _expected_refusal(lambda: _fixture_dry(fixture, helper, assets, "c" * 32), f"{phase} dry replay", "path must be absent", helper, assets)
    _expected_refusal(lambda: _fixture_apply(fixture, helper, assets, "c" * 32), f"{phase} new attempt", "path must be absent", helper, assets)
    return {"fixture": fixture["base"], "phase": phase, "status": "UNKNOWN_RETAINED_NO_REPLAY"}


def _test_external_retarget(helper: ModuleType, assets: Any, payload: bytes) -> dict[str, Any]:
    fixture = _make_fixture(helper, assets, payload)
    attempt = "d" * 32
    foreign = b"foreign bytes must not be overwritten\n"

    def retarget(event: str, _values: Any) -> None:
        if event != "before:exchange-old-runtime-selftest":
            return
        preserved = f"{fixture['target']}.external-original"
        os.rename(fixture["target"], preserved)
        _write_file(fixture["target"], foreign, 0o644)

    try:
        _fixture_apply(fixture, helper, assets, attempt, retarget)
    except helper.MaintenanceUnknown:
        pass
    else:
        raise AssertionError("external target retarget did not leave the one-shot attempt UNKNOWN")
    if open(fixture["target"], "rb").read() != foreign:
        raise AssertionError("external bytes were overwritten after target retarget")
    if open(f"{fixture['target']}.external-original", "rb").read() != fixture["old_payload"]:
        raise AssertionError("externally displaced original bytes were not retained")
    temp_path = f"{PurePosixPath(fixture['target']).parent}/.p004-runtime-selftest-{attempt}.tmp"
    if open(temp_path, "rb").read() != payload:
        raise AssertionError("staged payload was not retained after the retarget refusal")
    terminal = json.loads(open(f"{fixture['store']}/run-{attempt}.terminal.json", "rb").read())
    if terminal["status"] != "UNKNOWN":
        raise AssertionError("retarget failure did not retain UNKNOWN terminal")
    _expected_refusal(lambda: _fixture_apply(fixture, helper, assets, "e" * 32), "retarget new attempt", "path must be absent", helper, assets)
    return {"fixture": fixture["base"], "status": "FOREIGN_BYTES_PRESERVED_UNKNOWN"}


def _test_source_pins(helper: ModuleType, assets: Any) -> dict[str, Any]:
    wrong_hash = "0" * 64
    _expected_refusal(
        lambda: helper._read_code_file(assets.code, helper.PUBLISHER_NAME, wrong_hash, (0o600, 0o644)),
        "publisher pin mismatch",
        "hash drift",
        helper,
        assets,
    )
    _expected_refusal(
        lambda: helper._read_code_file(assets.code, helper.BASELINE_NAME, wrong_hash, (0o600, 0o644)),
        "baseline pin mismatch",
        "hash drift",
        helper,
        assets,
    )
    return {"publisher_pin_refused": True, "baseline_pin_refused": True}


def _test_no_remote_intent(helper: ModuleType, assets: Any) -> dict[str, Any]:
    attempt = "0" * 32
    _expected_refusal(
        lambda: helper._verify_transport_intent(assets, attempt, "--apply", helper.NEW_SELFTEST_SHA256),
        "missing parent remote intent",
        "cannot open fixed file",
        helper,
        assets,
    )
    return {"missing_remote_intent_refused": True}


def _probe_acl_support(helper: ModuleType, assets: Any, payload: bytes) -> dict[str, Any]:
    fixture = _make_fixture(helper, assets, payload)
    target = _entry_path(fixture, helper, _protected_entry(fixture, helper).destination)
    try:
        _set_acl(target)
    except FixtureSkip:
        raise
    config = fixture["config"]
    baseline = fixture["baseline"]
    try:
        helper._fixture_dry_run(assets, config, baseline, fixture["payload"], fixture["payload_sha256"], "7" * 32)
    except Exception as error:
        if "POSIX ACL present" not in str(error):
            raise AssertionError(f"ACL control was refused for the wrong cause: {error}") from error
    else:
        raise AssertionError("ACL-bearing protected source was accepted")
    return {"fixture": fixture["base"], "acl_refused": True}


def _test_drift_matrix(helper: ModuleType, assets: Any, payload: bytes) -> dict[str, Any]:
    cases = []

    def mutate_hash(fixture: dict[str, Any]) -> None:
        path = _entry_path(fixture, helper, _protected_entry(fixture, helper).destination)
        before = os.lstat(path)
        with open(path, "r+b") as stream:
            original = stream.read()
            if not original:
                raise AssertionError("hash-drift fixture entry unexpectedly empty")
            stream.seek(0)
            stream.write(bytes((original[0] ^ 1,)) + original[1:])
            stream.flush()
            os.fsync(stream.fileno())
        after = os.lstat(path)
        identity_fields = ("st_dev", "st_ino", "st_uid", "st_gid", "st_nlink", "st_size")
        before_metadata = tuple(getattr(before, field) for field in identity_fields) + (stat.S_IMODE(before.st_mode),)
        after_metadata = tuple(getattr(after, field) for field in identity_fields) + (stat.S_IMODE(after.st_mode),)
        if before_metadata != after_metadata:
            raise AssertionError("hash-drift fixture changed metadata besides the content hash")

    cases.append(_test_drift_case(helper, assets, payload, "protected hash drift", "hash drift", mutate_hash))

    def mutate_inode(fixture: dict[str, Any]) -> None:
        entry = _protected_entry(fixture, helper)
        path = _entry_path(fixture, helper, entry.destination)
        old = open(path, "rb").read()
        os.rename(path, f"{path}.old-inode")
        _write_file(path, old, entry.mode)

    cases.append(_test_drift_case(helper, assets, payload, "protected inode drift", "inode drift", mutate_inode))

    def mutate_mode(fixture: dict[str, Any]) -> None:
        path = _entry_path(fixture, helper, _protected_entry(fixture, helper).destination)
        os.chmod(path, 0o600)

    cases.append(_test_drift_case(helper, assets, payload, "protected mode drift", "metadata drift", mutate_mode))

    def mutate_owner(fixture: dict[str, Any]) -> None:
        path = _entry_path(fixture, helper, _protected_entry(fixture, helper).destination)
        os.chown(path, 1000, 1000)

    cases.append(_test_drift_case(helper, assets, payload, "protected owner drift", "metadata drift", mutate_owner))

    def mutate_symlink(fixture: dict[str, Any]) -> None:
        entry = _protected_entry(fixture, helper)
        path = _entry_path(fixture, helper, entry.destination)
        held = f"{path}.symlink-original"
        os.rename(path, held)
        os.symlink(held, path)
        os.chown(path, 0, 0, follow_symlinks=False)

    cases.append(_test_drift_case(helper, assets, payload, "protected symlink drift", "cannot open fixed file", mutate_symlink))

    def mutate_hardlink(fixture: dict[str, Any]) -> None:
        path = _entry_path(fixture, helper, _protected_entry(fixture, helper).destination)
        os.link(path, f"{path}.extra-link")

    cases.append(_test_drift_case(helper, assets, payload, "protected hardlink drift", "metadata drift", mutate_hardlink))

    def mutate_marker(fixture: dict[str, Any]) -> None:
        marker = fixture["config"].directories_config.markers[0]
        _write_file(marker, b"unexpected marker\n", 0o600)

    cases.append(_test_drift_case(helper, assets, payload, "active marker", "path must be absent", mutate_marker))

    def mutate_lock(fixture: dict[str, Any]) -> None:
        with open(fixture["base"] + "/lock", "wb") as stream:
            stream.write(b"changed lock bytes\n")

    cases.append(_test_drift_case(helper, assets, payload, "lock content drift", "fixed canonical lock content drift", mutate_lock))

    def mutate_prior(fixture: dict[str, Any]) -> None:
        with open(fixture["base"] + "/history-one/terminal.json", "wb") as stream:
            stream.write(b'{"status":"BLOCKED"}\n')

    cases.append(_test_drift_case(helper, assets, payload, "prior terminal drift", "hash drift", mutate_prior))

    def replace_private_dir(fixture: dict[str, Any], relative: str) -> None:
        path = f"{fixture['root']}/evidence/{relative}"
        old_path = f"{path}.old"
        os.rename(path, old_path)
        _mkdir(path, 0o700)
        if relative == "P004":
            _mkdir(f"{path}/S002", 0o700)

    cases.append(
        _test_drift_case(
            helper,
            assets,
            payload,
            "P004 inode pin drift",
            "identity drift",
            lambda fixture: replace_private_dir(fixture, "P004"),
        )
    )

    def replace_s002(fixture: dict[str, Any]) -> None:
        path = f"{fixture['root']}/evidence/P004/S002"
        os.rename(path, f"{path}.old")
        _mkdir(path, 0o700)

    cases.append(_test_drift_case(helper, assets, payload, "S002 inode pin drift", "identity drift", replace_s002))

    return {"cases": len(cases), "results": cases}


def _run_suite(helper: ModuleType, assets: Any, code_root: str) -> dict[str, Any]:
    payload = b"reviewed fixture runtime selftest\n"
    report: dict[str, Any] = {"schema": "p004-runtime-selftest-maintenance-selftest-v1", "status": "RUNNING", "fixtures_retained": True}
    try:
        report["source_pins"] = _test_source_pins(helper, assets)
        report["remote_intent"] = _test_no_remote_intent(helper, assets)
        report["invalid_cli"] = _test_invalid_cli(helper, code_root)
        # ACL support is a required negative control. Unsupported filesystems
        # return SKIP 77 so the run cannot be mistaken for a full PASS.
        report["acl"] = _probe_acl_support(helper, assets, payload)
        report["success_replay"] = _test_success_and_replay(helper, assets, payload)
        report["preexisting_store"] = _test_preexisting_store_shapes(helper, assets, payload)
        report["drift"] = _test_drift_matrix(helper, assets, payload)
        report["unknown_after_write"] = _test_unknown_retention(helper, assets, payload, "after-write")
        report["unknown_after_exchange"] = _test_unknown_retention(helper, assets, payload, "after-exchange")
        report["external_retarget"] = _test_external_retarget(helper, assets, payload)
        report["fixtures"] = list(_RETAINED_FIXTURES)
        report["status"] = "PASS"
        return report
    except FixtureSkip as error:
        report.update(status="SKIP", reason=str(error), fixtures=list(_RETAINED_FIXTURES))
        raise
    except BaseException:
        report["fixtures"] = list(_RETAINED_FIXTURES)
        report["status"] = "FAIL"
        raise


def main() -> int:
    if sys.argv[1:]:
        sys.stderr.write("selftest accepts no arguments\n")
        return 2
    if platform.system() != "Linux" or os.geteuid() != 0 or os.getegid() != 0:
        sys.stdout.write(json.dumps({"status": "SKIP", "exit_code": 77, "reason": "Linux effective UID/GID 0 required", "fixtures_retained": True}, sort_keys=True) + "\n")
        return 77
    helper: ModuleType | None = None
    assets: Any = None
    try:
        helper, code_root = _load_helper()
        assets = helper._load_assets(f"{code_root}/update-runtime-selftest.py")
        report = _run_suite(helper, assets, code_root)
        sys.stdout.write(json.dumps(report, sort_keys=True, separators=(",", ":")) + "\n")
        return 0
    except FixtureSkip as error:
        sys.stdout.write(json.dumps({"status": "SKIP", "exit_code": 77, "reason": str(error), "fixtures_retained": True, "fixtures": _RETAINED_FIXTURES}, sort_keys=True) + "\n")
        return 77
    except BaseException as error:
        sys.stderr.write(json.dumps({"status": "FAIL", "error_type": type(error).__name__, "error": str(error)[:1000], "fixtures_retained": True, "fixtures": _RETAINED_FIXTURES}, sort_keys=True) + "\n")
        return 1
    finally:
        if assets is not None:
            assets.close()


if __name__ == "__main__":
    raise SystemExit(main())
