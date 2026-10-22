#!/usr/bin/env python3
"""Fixture-only checks for four-target source maintenance.

The test module imports the private helper API and creates only root-owned
fixtures below /var/tmp.  It never invokes the production CLI, canonical root,
SSH, or a lab command.  Linux is required because the fixture exercises
flock(2), renameat2(RENAME_EXCHANGE), FIFO/socket store refusals, and ACL
checks.
"""

from __future__ import annotations

import contextlib
import fcntl
import hashlib
import io
import importlib.util
import json
import os
from pathlib import PurePosixPath
import socket
import stat
import struct
import subprocess
import sys
from typing import Any, Mapping


HELPER_NAME = "update-runtime-sources.py"
FIXTURE_PREFIX = "p004-runtime-source-maintenance-fixture-selftest-"


def _load_helper():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), HELPER_NAME)
    spec = importlib.util.spec_from_file_location("p004_runtime_source_maintenance_selftest_helper", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load source maintenance helper")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class _Assertions:
    def __init__(self) -> None:
        self.count = 0

    def true(self, condition: bool, message: str) -> None:
        self.count += 1
        if not condition:
            raise AssertionError(message)

    def equal(self, observed: Any, expected: Any, message: str) -> None:
        self.true(observed == expected, message + ": " + repr(observed) + " != " + repr(expected))

    def raises(self, function, expected: type[BaseException], message: str, *, cause: type[BaseException] | None = None) -> None:
        self.count += 1
        try:
            function()
        except BaseException as error:
            if type(error) is not expected:
                raise AssertionError(message + ": wrong exception " + type(error).__name__) from error
            if cause is not None and (error.__cause__ is None or type(error.__cause__) is not cause):
                observed = "None" if error.__cause__ is None else type(error.__cause__).__name__
                raise AssertionError(message + ": wrong cause " + observed) from error
            return
        raise AssertionError(message)


def _base(helper, index: int) -> str:
    return "/var/tmp/" + FIXTURE_PREFIX + str(os.getpid()) + "-" + str(index)


def _target_path(helper, environment: Any, destination: str) -> str:
    relative = destination[len(helper.PRODUCTION_ROOT) + 1:]
    return os.path.join(environment.config.directories_config.root, relative)


def _ledger_files(environment: Any) -> list[str]:
    return sorted(os.path.join(environment.config.directories_config.store, name) for name in os.listdir(environment.config.directories_config.store))


def _file_state(path: str) -> dict[str, Any]:
    info = os.lstat(path)
    with open(path, "rb") as stream:
        raw = stream.read()
    return {
        "bytes": raw,
        "dev": info.st_dev,
        "inode": info.st_ino,
        "uid": info.st_uid,
        "gid": info.st_gid,
        "mode": stat.S_IMODE(info.st_mode),
        "nlink": info.st_nlink,
        "size": info.st_size,
        "mtime_ns": info.st_mtime_ns,
    }


def _directory_state(path: str) -> tuple[int, int, int, int, int, int]:
    info = os.lstat(path)
    return (info.st_dev, info.st_ino, info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode), info.st_nlink)


def _entry_states(helper, environment: Any) -> dict[str, dict[str, Any]]:
    return {entry.destination: _file_state(_target_path(helper, environment, entry.destination)) for entry in environment.baseline.entries}


def _proof_states(environment: Any) -> dict[str, dict[str, Any]]:
    return {proof.path: _file_state(proof.path) for proof in environment.baseline.prior_terminals}


def _h4_states(environment: Any) -> dict[str, tuple[int, int, int, int, int, int]]:
    return {path: _directory_state(path) for path in environment.baseline.h4_pins}


def _parked_path(helper, environment: Any) -> str:
    return helper._map_path(environment.config, str(environment.baseline.parked_old["path"]))


def _temporary_path(helper, environment: Any, destination: str, attempt: str) -> str:
    index = helper.TARGET_ORDER.index(destination) + 1
    target = _target_path(helper, environment, destination)
    return os.path.join(os.path.dirname(target), ".p004-runtime-source-" + attempt + "-" + format(index, "02d") + ".tmp")


def _assert_store_shape(a: _Assertions, environment: Any, expected: int) -> None:
    files = _ledger_files(environment)
    a.equal(len(files), expected, "ledger record count")
    for path in files:
        info = os.lstat(path)
        a.true(stat.S_ISREG(info.st_mode), "ledger record is regular")
        a.equal((info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode), info.st_nlink), (0, 0, 0o600, 1), "ledger record metadata")


def _read_record(path: str) -> dict[str, Any]:
    with open(path, encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise AssertionError("ledger record is not an object: " + path)
    return value


def _assert_success_ledger(a: _Assertions, environment: Any, attempt: str) -> None:
    prefix = "run-" + attempt
    expected_names = {prefix + ".intent.json", prefix + ".terminal.json"}
    for sequence in range(1, 9):
        stem = prefix + "-effect-" + format(sequence, "03d")
        expected_names.update((stem + ".intent.json", stem + ".result.json"))
    observed_names = {os.path.basename(path) for path in _ledger_files(environment)}
    a.equal(observed_names, expected_names, "success ledger names")
    intent = _read_record(os.path.join(environment.config.directories_config.store, prefix + ".intent.json"))
    a.equal(intent["status"], "INTENT_DURABLE", "run intent status")
    for sequence in range(1, 9):
        stem = os.path.join(environment.config.directories_config.store, prefix + "-effect-" + format(sequence, "03d"))
        effect_intent = _read_record(stem + ".intent.json")
        effect_result = _read_record(stem + ".result.json")
        a.equal(effect_intent["status"], "INTENT_DURABLE", "effect intent status")
        a.equal(effect_intent["sequence"], sequence, "effect intent sequence")
        a.equal(effect_result["status"], "PROVED", "effect result status")
        a.equal(effect_result["sequence"], sequence, "effect result sequence")
    terminal = _read_record(os.path.join(environment.config.directories_config.store, prefix + ".terminal.json"))
    a.equal(terminal["status"], "PASS_UPDATED_FOUR_RUNTIME_SOURCES", "success terminal status")
    a.equal(terminal["effect_count"], 8, "success terminal effect count")
    a.equal(terminal["automatic_retry"], False, "success retry flag")
    a.equal(terminal["automatic_cleanup"], False, "success cleanup flag")
    a.equal(terminal["automatic_rollback"], False, "success rollback flag")
    a.equal(terminal["actual_X05"], "NOT_RUN", "success X05 status")


def _assert_unknown_ledger(a: _Assertions, environment: Any, attempt: str, sequence: int) -> None:
    prefix = "run-" + attempt
    expected_names = {prefix + ".intent.json", prefix + ".terminal.json"}
    for current in range(1, sequence + 1):
        stem = prefix + "-effect-" + format(current, "03d")
        expected_names.update((stem + ".intent.json", stem + ".result.json"))
    observed_names = {os.path.basename(path) for path in _ledger_files(environment)}
    a.equal(observed_names, expected_names, "UNKNOWN ledger names")
    for current in range(1, sequence + 1):
        stem = os.path.join(environment.config.directories_config.store, prefix + "-effect-" + format(current, "03d"))
        result = _read_record(stem + ".result.json")
        a.equal(result["status"], "UNKNOWN" if current == sequence else "PROVED", "UNKNOWN effect status")
    terminal = _read_record(os.path.join(environment.config.directories_config.store, prefix + ".terminal.json"))
    a.equal(terminal["status"], "UNKNOWN_RETAINED_NO_RETRY", "UNKNOWN terminal status")
    a.equal(terminal["effect_count"], sequence, "UNKNOWN terminal effect count")
    a.equal(terminal["automatic_retry"], False, "UNKNOWN retry flag")
    a.equal(terminal["automatic_cleanup"], False, "UNKNOWN cleanup flag")
    a.equal(terminal["automatic_rollback"], False, "UNKNOWN rollback flag")
    a.equal(terminal["actual_X05"], "NOT_RUN", "UNKNOWN X05 status")


def _run_success(helper, a: _Assertions, index: int) -> None:
    env = helper._fixture_environment(_base(helper, index))
    try:
        before = _entry_states(helper, env)
        before_proofs = _proof_states(env)
        before_h4 = _h4_states(env)
        before_parked = _file_state(_parked_path(helper, env))
        a.equal(len(before), helper.EXPECTED_SOURCE_COUNT, "accepted source entry count")
        dry = helper._fixture_dry_run(env, "11111111111111111111111111111111")
        a.equal(dry["status"], "PASS_DRY_RUN", "dry-run status")
        a.true(not os.path.lexists(env.config.directories_config.store), "dry-run leaves store absent")
        after_dry = _entry_states(helper, env)
        a.equal(after_dry, before, "dry-run leaves all target bytes unchanged")
        a.equal(_proof_states(env), before_proofs, "dry-run leaves prior proofs unchanged")
        a.equal(_h4_states(env), before_h4, "dry-run leaves H4 directories unchanged")
        a.equal(_file_state(_parked_path(helper, env)), before_parked, "dry-run leaves parked original unchanged")
    finally:
        env.assets.close()

    env = helper._fixture_environment(_base(helper, index + 1))
    try:
        before = _entry_states(helper, env)
        before_proofs = _proof_states(env)
        before_h4 = _h4_states(env)
        before_parked = _file_state(_parked_path(helper, env))
        result = helper._fixture_apply(env, "22222222222222222222222222222222")
        a.equal(result["status"], "PASS_UPDATED_FOUR_RUNTIME_SOURCES", "apply status")
        a.equal(result["effect_count"], 8, "four stage/four exchange effects")
        _assert_store_shape(a, env, 18)
        _assert_success_ledger(a, env, "22222222222222222222222222222222")
        targets = set(helper.TARGET_ORDER)
        protected = [destination for destination in before if destination not in targets]
        a.equal(len(protected), helper.PROTECTED_SOURCE_COUNT, "protected source entry count")
        after = _entry_states(helper, env)
        for destination in protected:
            a.equal(after[destination], before[destination], "protected source remains unchanged")
        for destination in helper.TARGET_ORDER:
            expected = env.payloads[PurePosixPath(destination).name]
            observed = after[destination]
            a.equal(observed["bytes"], expected, "new target bytes")
            a.equal((observed["uid"], observed["gid"], observed["mode"], observed["nlink"], observed["size"]), (0, 0, 0o644, 1, len(expected)), "new target metadata")
            a.true(observed["inode"] != before[destination]["inode"], "new target has a new inode")
            temp = _temporary_path(helper, env, destination, "22222222222222222222222222222222")
            a.equal(_file_state(temp), before[destination], "original is retained byte-for-byte beside target")
        a.equal(_proof_states(env), before_proofs, "apply leaves prior proofs unchanged")
        a.equal(_h4_states(env), before_h4, "apply leaves H4 directories unchanged")
        a.equal(_file_state(_parked_path(helper, env)), before_parked, "apply leaves parked original unchanged")
        a.raises(lambda: helper._fixture_apply(env, "33333333333333333333333333333333"), helper.MaintenanceRefused, "replay is refused by store presence")
    finally:
        env.assets.close()


def _run_noatime(helper, a: _Assertions, index: int) -> None:
    env = helper._fixture_environment(_base(helper, index))
    try:
        baseline_path = os.path.join(env.assets.code.code_root, helper.BASELINE_NAME)
        before = os.stat(baseline_path, follow_symlinks=False)
        old_atime = max(1, before.st_mtime_ns - 1_000_000_000)
        os.utime(baseline_path, ns=(old_atime, before.st_mtime_ns), follow_symlinks=False)
        raw = helper._read_code_file(env.assets.code, helper.BASELINE_NAME, expected_sha256=helper.BASELINE_SHA256)
        a.true(bool(raw), "private baseline read returned bytes")
        after = os.stat(baseline_path, follow_symlinks=False)
        a.equal(after.st_atime_ns, old_atime, "O_NOATIME preserves private baseline atime")
    finally:
        env.assets.close()


def _run_fixture_modes(helper, a: _Assertions, index: int) -> None:
    previous_umask = os.umask(0o077)
    try:
        env = helper._fixture_environment(_base(helper, index))
    finally:
        os.umask(previous_umask)
    try:
        root = PurePosixPath(env.config.directories_config.root)
        expected = (
            (PurePosixPath(env.base), 0o700),
            (root, 0o755),
            (root / "evidence", 0o755),
            (root / "evidence" / "P004", 0o700),
            (root / "evidence" / "P004" / "S002", 0o700),
            (PurePosixPath(env.config.directories_config.markers[0]).parent, 0o755),
        )
        for path, mode in expected:
            info = os.stat(path, follow_symlinks=False)
            a.equal((info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)), (0, 0, mode), "restrictive-umask fixture directory metadata")
    finally:
        env.assets.close()


def _run_store_presence(helper, a: _Assertions, index: int, kind: str) -> None:
    env = helper._fixture_environment(_base(helper, index))
    store = env.config.directories_config.store
    try:
        if kind == "file":
            fd = os.open(store, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(fd)
        elif kind == "directory":
            os.mkdir(store, 0o700)
        elif kind == "symlink":
            os.symlink("foreign", store)
        elif kind == "fifo":
            os.mkfifo(store, 0o600)
        elif kind == "socket":
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(store)
        else:
            raise AssertionError("unknown store fixture")
        a.raises(lambda: helper._fixture_dry_run(env, "44444444444444444444444444444444"), helper.MaintenanceRefused, kind + " store presence is refused in dry-run")
        a.raises(lambda: helper._fixture_apply(env, "55555555555555555555555555555555"), helper.MaintenanceRefused, kind + " store presence is refused in apply")
    finally:
        if kind == "socket":
            try:
                listener.close()
            except UnboundLocalError:
                pass
        env.assets.close()


def _access_acl(mode: int) -> bytes:
    owner = (mode >> 6) & 0o7
    group = (mode >> 3) & 0o7
    other = mode & 0o7
    entries = (
        (0x0001, owner, 0xFFFFFFFF),
        (0x0002, group, 65534),
        (0x0004, group, 0xFFFFFFFF),
        (0x0010, group, 0xFFFFFFFF),
        (0x0020, other, 0xFFFFFFFF),
    )
    values: list[int] = [2]
    for tag, permission, identifier in entries:
        values.extend((tag, permission, identifier))
    return struct.pack("<I" + "HHI" * len(entries), *values)


def _access_acl_0644() -> bytes:
    return _access_acl(0o644)


def _run_drift(helper, a: _Assertions, index: int, kind: str) -> None:
    env = helper._fixture_environment(_base(helper, index))
    try:
        destination = helper.TARGET_ORDER[0]
        target = _target_path(helper, env, destination)
        original = _file_state(target)
        if kind == "hash":
            changed = bytearray(original["bytes"])
            changed[0] ^= 1
            with open(target, "wb") as stream:
                stream.write(changed)
        elif kind == "symlink":
            foreign = target + ".foreign"
            os.rename(target, foreign)
            os.symlink(foreign, target)
        elif kind == "hardlink":
            foreign = target + ".foreign"
            os.link(target, foreign)
        elif kind == "mode":
            os.chmod(target, 0o755)
        elif kind == "acl":
            os.setxattr(target, "system.posix_acl_access", _access_acl_0644(), follow_symlinks=False)
            info = os.stat(target, follow_symlinks=False)
            a.equal(stat.S_IMODE(info.st_mode), original["mode"], "valid ACL fixture preserves expected file mode")
        else:
            raise AssertionError("unknown drift fixture")
        a.raises(lambda: helper._fixture_dry_run(env, "66666666666666666666666666666666"), helper.MaintenanceRefused, kind + " drift is refused")
    finally:
        env.assets.close()


def _run_lock_holder(helper, a: _Assertions, index: int) -> None:
    env = helper._fixture_environment(_base(helper, index))
    try:
        fd = os.open(env.config.directories_config.lock_path, os.O_RDONLY)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            a.raises(lambda: helper._fixture_dry_run(env, "77777777777777777777777777777777"), helper.MaintenanceRefused, "held lock is refused")
            a.raises(lambda: helper._fixture_apply(env, "88888888888888888888888888888888"), helper.MaintenanceRefused, "held lock refuses apply")
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)
    finally:
        env.assets.close()


def _run_unknown(helper, a: _Assertions, index: int, event: str) -> None:
    env = helper._fixture_environment(_base(helper, index))
    attempt = "99999999999999999999999999999999"
    before = _entry_states(helper, env)
    before_proofs = _proof_states(env)
    before_h4 = _h4_states(env)
    before_parked = _file_state(_parked_path(helper, env))

    def hook(observed: str, values: Mapping[str, Any]) -> None:
        if observed == event:
            raise RuntimeError("fixture fault at " + observed)

    try:
        a.raises(lambda: helper._fixture_apply(env, attempt, hook=hook), helper.MaintenanceUnknown, "fault becomes UNKNOWN: " + event, cause=env.assets.publisher.StageUnknown)
        if event.startswith("after:stage-"):
            current_name = event[len("after:stage-"):]
            staged_index = helper.PAYLOAD_BASENAMES.index(current_name)
            exchanged_count = 0
            sequence = staged_index + 1
        elif event.startswith("after:exchange-"):
            current_name = event[len("after:exchange-"):]
            exchanged_count = helper.PAYLOAD_BASENAMES.index(current_name) + 1
            staged_index = len(helper.TARGET_ORDER) - 1
            sequence = len(helper.TARGET_ORDER) + exchanged_count
        else:
            raise AssertionError("unknown fault event")
        _assert_unknown_ledger(a, env, attempt, sequence)
        for target_index, destination in enumerate(helper.TARGET_ORDER):
            target_path = _target_path(helper, env, destination)
            temp_path = _temporary_path(helper, env, destination, attempt)
            if target_index < exchanged_count:
                observed = _file_state(target_path)
                a.equal(observed["bytes"], env.payloads[PurePosixPath(destination).name], "completed target bytes retained")
                a.equal((observed["uid"], observed["gid"], observed["mode"], observed["nlink"]), (0, 0, 0o644, 1), "completed target metadata")
                a.equal(_file_state(temp_path), before[destination], "completed original is retained beside target")
            elif staged_index is not None and target_index <= staged_index:
                a.equal(_file_state(target_path), before[destination], "staged target remains original")
                staged = _file_state(temp_path)
                a.equal(staged["bytes"], env.payloads[PurePosixPath(destination).name], "staged payload is retained")
                a.equal((staged["uid"], staged["gid"], staged["mode"], staged["nlink"]), (0, 0, 0o644, 1), "staged payload metadata")
            else:
                a.equal(_file_state(target_path), before[destination], "uncompleted target remains original")
                a.true(not os.path.lexists(temp_path), "uncompleted target has no temporary payload")
        for destination in before:
            if destination not in helper.TARGET_ORDER:
                a.equal(_file_state(_target_path(helper, env, destination)), before[destination], "UNKNOWN leaves protected source unchanged")
        a.equal(_proof_states(env), before_proofs, "UNKNOWN leaves prior proofs unchanged")
        a.equal(_h4_states(env), before_h4, "UNKNOWN leaves H4 directories unchanged")
        a.equal(_file_state(_parked_path(helper, env)), before_parked, "UNKNOWN leaves parked original unchanged")
    finally:
        env.assets.close()


def _write_private_record(helper, code, name: str, value: Mapping[str, Any]) -> bytes:
    raw = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
    fd = os.open(os.path.join(code.code_root, name), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.write(fd, raw)
        os.fchown(fd, 0, 0)
        os.fchmod(fd, 0o600)
        os.fsync(fd)
    finally:
        os.close(fd)
    fd_dir = code.directory_fd
    os.fsync(fd_dir)
    return raw


def _replace_private_record(code, name: str, value: Mapping[str, Any]) -> bytes:
    raw = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
    return _replace_private_raw(code, name, raw)


def _replace_private_raw(code, name: str, raw: bytes) -> bytes:
    fd = os.open(os.path.join(code.code_root, name), os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW)
    try:
        os.write(fd, raw)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.fsync(code.directory_fd)
    return raw


def _copy_code_fixture(helper, source_code, index: int) -> str:
    base = "/var/tmp/" + helper.CODE_DIRECTORY_PREFIX + "provenance-" + str(os.getpid()) + "-" + str(index)
    os.mkdir(base, 0o700)
    os.chown(base, 0, 0)
    os.chmod(base, 0o700)
    helper_name = PurePosixPath(helper.__file__).name
    for name in (helper.BASELINE_NAME, helper.PUBLISHER_NAME, helper.OLD_HELPER_NAME, helper_name):
        source = os.path.join(source_code.code_root, name)
        destination = os.path.join(base, name)
        with open(source, "rb") as stream:
            raw = stream.read()
        fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            view = memoryview(raw)
            while view:
                written = os.write(fd, view)
                if written <= 0:
                    raise OSError("short private code fixture write")
                view = view[written:]
            os.fchown(fd, 0, 0)
            os.fchmod(fd, 0o600)
            os.fsync(fd)
        finally:
            os.close(fd)
    directory_fd = os.open(base, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
    return os.path.join(base, helper_name)


def _run_provenance_identity_case(helper, source_assets, a: _Assertions, index: int, kind: str) -> None:
    script_path = _copy_code_fixture(helper, source_assets.code, index)
    assets = None
    try:
        assets = helper._load_assets(script_path=script_path)
        attempt = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        parent_name = helper.PARENT_INTENT_NAME
        remote_name = helper.REMOTE_INTENT_PREFIX + attempt + helper.REMOTE_INTENT_SUFFIX
        expected = helper._provenance_fields(assets, assets.baseline, attempt, {})
        parent_raw = _write_private_record(helper, assets.code, parent_name, expected)
        remote = dict(expected)
        remote["parent_intent_name"] = parent_name
        remote["parent_intent_sha256"] = hashlib.sha256(parent_raw).hexdigest()
        _write_private_record(helper, assets.code, remote_name, remote)
        parent_path = os.path.join(assets.code.code_root, parent_name)
        if kind == "mode":
            os.chmod(parent_path, 0o644)
        elif kind == "symlink":
            foreign = parent_path + ".foreign"
            os.rename(parent_path, foreign)
            os.symlink(foreign, parent_path)
        elif kind == "hardlink":
            os.link(parent_path, parent_path + ".foreign")
        elif kind == "acl":
            os.setxattr(parent_path, "system.posix_acl_access", _access_acl(0o600), follow_symlinks=False)
            info = os.stat(parent_path, follow_symlinks=False)
            a.equal(stat.S_IMODE(info.st_mode), 0o600, "valid provenance ACL preserves mode 0600")
        else:
            raise AssertionError("unknown provenance identity case")
        a.raises(lambda: helper._verify_provenance(assets, assets.baseline, attempt), helper.MaintenanceRefused, "provenance " + kind + " identity is refused")
    finally:
        if assets is not None:
            assets.close()


def _run_provenance(helper, a: _Assertions, index: int) -> None:
    assets = helper._load_assets()
    attempt = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    parent_name = helper.PARENT_INTENT_NAME
    remote_name = helper.REMOTE_INTENT_PREFIX + attempt + helper.REMOTE_INTENT_SUFFIX
    try:
        a.raises(lambda: helper._parse_baseline(b"{}"), helper.MaintenanceRefused, "baseline pin mismatch is refused")
        a.raises(lambda: helper._read_code_file(assets.code, helper.PUBLISHER_NAME, expected_sha256="0" * 64), helper.MaintenanceRefused, "publisher code pin mismatch is refused")
        a.raises(lambda: helper._verify_provenance(assets, assets.baseline, attempt), helper.MaintenanceRefused, "missing provenance is refused")
        expected = helper._provenance_fields(assets, assets.baseline, attempt, {})
        missing = dict(expected)
        missing.pop("store")
        a.raises(lambda: helper._parse_provenance(json.dumps(missing).encode(), "missing", set(expected)), helper.MaintenanceRefused, "missing provenance field is refused")
        extra = dict(expected)
        extra["extra"] = True
        a.raises(lambda: helper._parse_provenance(json.dumps(extra).encode(), "extra", set(expected)), helper.MaintenanceRefused, "extra provenance field is refused")
        parent_raw = _write_private_record(helper, assets.code, parent_name, expected)
        remote = dict(expected)
        remote["parent_intent_name"] = parent_name
        remote["parent_intent_sha256"] = hashlib.sha256(parent_raw).hexdigest()
        _write_private_record(helper, assets.code, remote_name, remote)
        helper._verify_provenance(assets, assets.baseline, attempt)
        a.true(True, "matching copied parent and remote intents verify")
        target = helper.TARGET_ORDER[0]
        bad_parent = json.loads(json.dumps(expected))
        bad_parent["automatic_retry"] = 0
        _replace_private_record(assets.code, parent_name, bad_parent)
        a.raises(lambda: helper._verify_provenance(assets, assets.baseline, attempt), helper.MaintenanceRefused, "parent false-as-int flag is refused")
        _replace_private_record(assets.code, parent_name, expected)
        bad_remote = json.loads(json.dumps(remote))
        bad_remote["automatic_retry"] = 0
        _replace_private_record(assets.code, remote_name, bad_remote)
        a.raises(lambda: helper._verify_provenance(assets, assets.baseline, attempt), helper.MaintenanceRefused, "remote false-as-int flag is refused")
        _replace_private_record(assets.code, remote_name, remote)
        bad_remote = json.loads(json.dumps(remote))
        bad_remote["payloads"][target]["size"] = float(remote["payloads"][target]["size"])
        _replace_private_record(assets.code, remote_name, bad_remote)
        a.raises(lambda: helper._verify_provenance(assets, assets.baseline, attempt), helper.MaintenanceRefused, "remote nested float-size is refused")
        _replace_private_record(assets.code, remote_name, remote)
        bad_parent = dict(expected)
        bad_parent["store"] = "/var/tmp/foreign-runtime-source-maintenance-store"
        _replace_private_record(assets.code, parent_name, bad_parent)
        a.raises(lambda: helper._verify_provenance(assets, assets.baseline, attempt), helper.MaintenanceRefused, "parent store field mismatch is refused")
        _replace_private_record(assets.code, parent_name, expected)
        bad_extra = dict(remote)
        bad_extra["extra"] = True
        _replace_private_record(assets.code, remote_name, bad_extra)
        a.raises(lambda: helper._verify_provenance(assets, assets.baseline, attempt), helper.MaintenanceRefused, "remote extra field is refused by verifier")
        _replace_private_record(assets.code, remote_name, remote)
        remote_json = json.dumps(remote, sort_keys=True, separators=(",", ":"))
        pin = remote["payloads"][target]
        pin_json = json.dumps(target, separators=(",", ":")) + ":{" + json.dumps("sha256") + ":" + json.dumps(pin["sha256"]) + "," + json.dumps("size") + ":" + str(pin["size"]) + "}"
        duplicate_pin_json = json.dumps(target, separators=(",", ":")) + ":{" + json.dumps("sha256") + ":" + json.dumps(pin["sha256"]) + "," + json.dumps("size") + ":" + str(pin["size"]) + "," + json.dumps("size") + ":" + str(pin["size"]) + "}"
        duplicate_json = remote_json.replace(pin_json, duplicate_pin_json, 1)
        a.true(duplicate_json != remote_json, "nested duplicate fixture was constructed")
        _replace_private_raw(assets.code, remote_name, (duplicate_json + "\n").encode())
        a.raises(lambda: helper._verify_provenance(assets, assets.baseline, attempt), helper.MaintenanceRefused, "remote nested duplicate is refused by verifier")
        _replace_private_record(assets.code, remote_name, remote)
        bad_parent_field = dict(remote)
        bad_parent_field["parent_intent_name"] = "wrong-parent.json"
        _replace_private_record(assets.code, remote_name, bad_parent_field)
        a.raises(lambda: helper._verify_provenance(assets, assets.baseline, attempt), helper.MaintenanceRefused, "remote parent field mismatch is refused")
        _replace_private_record(assets.code, remote_name, remote)
        bad = dict(remote)
        bad["parent_intent_sha256"] = "0" * 64
        bad_path = os.path.join(assets.code.code_root, remote_name)
        fd = os.open(bad_path, os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW)
        try:
            bad_raw = (json.dumps(bad, sort_keys=True, separators=(",", ":")) + "\n").encode()
            os.write(fd, bad_raw)
            os.fsync(fd)
        finally:
            os.close(fd)
        os.fsync(assets.code.directory_fd)
        a.raises(lambda: helper._verify_provenance(assets, assets.baseline, attempt), helper.MaintenanceRefused, "copied parent hash mismatch is refused")
        for offset, kind in enumerate(("mode", "symlink", "hardlink", "acl"), start=1):
            _run_provenance_identity_case(helper, assets, a, index + offset, kind)
    finally:
        # Parent and remote intent bytes remain in the private code root.
        assets.close()


def _run_foreign_retarget(helper, a: _Assertions, index: int) -> None:
    env = helper._fixture_environment(_base(helper, index))
    ovn = os.path.join(env.config.directories_config.root, "studies", "p004", "ovn")
    foreign = ovn + ".foreign"
    try:
        os.rename(ovn, foreign)
        os.symlink(foreign, ovn)
        a.raises(lambda: helper._fixture_dry_run(env, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"), env.assets.publisher.StageRefused, "foreign directory retarget is refused")
        a.true(os.path.islink(ovn), "foreign retarget symlink remains for review")
        a.true(os.path.isdir(foreign), "foreign directory remains unchanged")
    finally:
        env.assets.close()


def _run_input_controls(helper, a: _Assertions) -> None:
    a.raises(lambda: helper._safe_json(b'{"payloads":{},"payloads":{}}', "duplicate"), helper.MaintenanceRefused, "duplicate top-level JSON is refused")
    a.raises(lambda: helper._safe_json(b'{"nested":{"x":1,"x":2}}', "duplicate nested"), helper.MaintenanceRefused, "duplicate nested JSON is refused")
    parser = helper._build_parser()
    with contextlib.redirect_stderr(io.StringIO()):
        a.raises(lambda: parser.parse_args(["--dry-run", "--apply", "a" * 32]), SystemExit, "CLI override combination is refused")
    a.true(not helper.ATTEMPT_RE.fullmatch("a" * 31), "short CLI attempt is refused by the operation boundary")


def _run_help_reachability(helper, a: _Assertions) -> None:
    result = subprocess.run(
        ["/usr/bin/python3", "-B", helper.__file__, "--help"],
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )
    a.equal(result.returncode, 0, "private helper --help return code")
    a.true("usage:" in result.stdout, "private helper --help usage")
    a.true("--dry-run" in result.stdout, "private helper --help dry-run option")
    a.true("--apply" in result.stdout, "private helper --help apply option")
    a.equal(result.stderr, "", "private helper --help stderr")


def main() -> int:
    helper = _load_helper()
    assertions = _Assertions()
    _run_help_reachability(helper, assertions)
    if sys.platform != "linux":
        print(json.dumps({"schema": "p004-runtime-source-maintenance-selftest-v3", "status": "SKIP_NON_LINUX"}))
        return 0
    if os.geteuid() != 0 or os.getegid() != 0:
        print(json.dumps({"schema": "p004-runtime-source-maintenance-selftest-v3", "status": "SKIP_NOT_ROOT"}))
        return 0
    _run_success(helper, assertions, 1)
    _run_noatime(helper, assertions, 3)
    _run_fixture_modes(helper, assertions, 4)
    for offset, kind in enumerate(("file", "directory", "symlink", "fifo", "socket"), start=10):
        _run_store_presence(helper, assertions, offset, kind)
    for offset, kind in enumerate(("hash", "symlink", "hardlink", "mode", "acl"), start=20):
        _run_drift(helper, assertions, offset, kind)
    _run_lock_holder(helper, assertions, 30)
    _run_unknown(helper, assertions, 40, "after:stage-x05-coordinator.py")
    _run_unknown(helper, assertions, 41, "after:exchange-x05-coordinator.py")
    _run_unknown(helper, assertions, 42, "after:exchange-x05-coordinator-selftest.py")
    _run_unknown(helper, assertions, 43, "after:exchange-x05-runtime-live.py")
    _run_foreign_retarget(helper, assertions, 50)
    _run_provenance(helper, assertions, 60)
    _run_input_controls(helper, assertions)
    print(json.dumps({"schema": "p004-runtime-source-maintenance-selftest-v3", "status": "PASS", "assertions": assertions.count}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
