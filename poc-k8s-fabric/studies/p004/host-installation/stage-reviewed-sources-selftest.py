#!/usr/bin/env python3
"""Exercise the reviewed-source publisher only in private /var/tmp fixtures."""

from __future__ import annotations

import contextlib
import dataclasses
import errno
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path, PurePosixPath
import platform
import stat
import struct
import sys
import tarfile
import tempfile
from typing import Any


SCRIPT = Path(__file__).with_name("stage-reviewed-sources.py")
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("p004_stage_reviewed_sources", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("cannot load the standalone publisher")
PUBLISHER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PUBLISHER
SPEC.loader.exec_module(PUBLISHER)


def _mkdir(path: Path, mode: int) -> None:
    old_mask = os.umask(0)
    try:
        os.mkdir(path, mode)
    finally:
        os.umask(old_mask)


def _new_fixture(*, p004_mode: int = 0o700) -> tuple[str, Path]:
    base = Path(tempfile.mkdtemp(prefix="p004-reviewed-source-stage-fixture-", dir="/var/tmp"))
    root = base / "root"
    _mkdir(root, 0o755)
    evidence = root / "evidence"
    _mkdir(evidence, 0o755)
    p004 = evidence / "P004"
    _mkdir(p004, p004_mode)
    s002 = p004 / "S002"
    _mkdir(s002, 0o700)
    markers = base / "markers"
    _mkdir(markers, 0o755)
    old_mask = os.umask(0)
    try:
        lock_fd = os.open(base / "lock", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    finally:
        os.umask(old_mask)
    os.fsync(lock_fd)
    os.close(lock_fd)
    _mkdir(root / "agent", 0o755)
    with open(s002 / "legacy-evidence.bin", "xb") as stream:
        stream.write(b"legacy evidence stays byte-for-byte unchanged\n")
    os.symlink("../evidence/P004/S002", root / "agent" / "evidence")
    return str(base), root


def _source_files() -> dict[str, bytes]:
    paths = [
        "poc-k8s-fabric/labctl/labctl",
        "poc-k8s-fabric/labctl/lib/common.sh",
        "poc-k8s-fabric/labctl/labs/dci.sh",
    ]
    paths.extend(f"poc-k8s-fabric/studies/p004/ovn/fixture-{index:02d}.sh" for index in range(28))
    paths.extend(f"poc-k8s-fabric/studies/p004/ovn/fixture-{index:02d}.conf" for index in range(27))
    paths.extend(f"poc-k8s-fabric/evidence/P004/S002/historical-{index:02d}.txt" for index in range(12))
    if len(paths) != PUBLISHER.EXPECTED_SOURCE_COUNT:
        raise AssertionError("fixture manifest shape drifted")
    return {path: f"fixture source {index}: {path}\n".encode() for index, path in enumerate(paths)}


def _approved_shaped_archive() -> tuple[bytes, str, str]:
    files = _source_files()
    manifest = {path: hashlib.sha256(data).hexdigest() for path, data in sorted(files.items())}
    manifest_raw = json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w") as archive:
        contents = {"snapshot-manifest.json": manifest_raw, **files}
        for name, data in sorted(contents.items()):
            member = tarfile.TarInfo(name)
            member.size = len(data)
            member.mode = 0o644
            member.uid = 0
            member.gid = 0
            member.mtime = 0
            archive.addfile(member, io.BytesIO(data))
    raw = output.getvalue()
    return raw, hashlib.sha256(raw).hexdigest(), hashlib.sha256(manifest_raw).hexdigest()


def _config(base: str, archive_sha: str, manifest_sha: str) -> Any:
    return PUBLISHER._fixture_config(
        base,
        archive_sha256=archive_sha,
        manifest_sha256=manifest_sha,
    )


def _read_noatime(path: Path) -> bytes:
    flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_NOATIME", 0)
    fd = os.open(path, flags)
    try:
        blocks = []
        while True:
            block = os.read(fd, 65536)
            if not block:
                return b"".join(blocks)
            blocks.append(block)
    finally:
        os.close(fd)


def _metadata(info: os.stat_result, kind: str) -> dict[str, Any]:
    return {
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
        "type": kind,
    }


def _readlink_snapshot(parent_fd: int, name: str, label: str) -> tuple[os.stat_result, str]:
    before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if not stat.S_ISLNK(before.st_mode):
        raise AssertionError(f"symlink changed type while snapshotting: {label}")
    target = os.readlink(name, dir_fd=parent_fd)
    after = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino):
        raise AssertionError(f"symlink changed while snapshotting: {label}")
    return after, target


def _file_snapshot(path: Path) -> dict[str, Any]:
    parent_fd = os.open(
        path.parent,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_NOATIME", 0),
    )
    try:
        named_before = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
        if not stat.S_ISREG(named_before.st_mode):
            raise AssertionError(f"expected regular file while snapshotting: {path}")
        fd = os.open(path.name, PUBLISHER.FILE_READ_FLAGS, dir_fd=parent_fd)
        try:
            before = os.fstat(fd)
            if (before.st_dev, before.st_ino) != (named_before.st_dev, named_before.st_ino):
                raise AssertionError(f"file changed while opening for snapshot: {path}")
            digest = hashlib.sha256()
            while block := os.read(fd, 65536):
                digest.update(block)
            after = os.fstat(fd)
            named_after = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
            if (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino) or (named_after.st_dev, named_after.st_ino) != (after.st_dev, after.st_ino):
                raise AssertionError(f"file changed while snapshotting: {path}")
            return {**_metadata(after, "file"), "sha256": digest.hexdigest()}
        finally:
            os.close(fd)
    finally:
        os.close(parent_fd)


def _tree_snapshot(root: Path) -> dict[str, dict[str, Any]]:
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_NOATIME", 0)
    root_fd = os.open(root, directory_flags)
    held_directories = [root_fd]
    pending = [(".", root_fd)]
    observed: dict[str, dict[str, Any]] = {
        ".": {"parent_fd": None, "name": None, "info": os.fstat(root_fd), "kind": "dir"}
    }
    try:
        while pending:
            relative, directory_fd = pending.pop()
            names = sorted(os.listdir(directory_fd))
            for name in names:
                info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                child = name if relative == "." else f"{relative}/{name}"
                label = str(root / child)
                extra: dict[str, Any] = {}
                if stat.S_ISREG(info.st_mode):
                    fd = os.open(name, PUBLISHER.FILE_READ_FLAGS, dir_fd=directory_fd)
                    try:
                        opened = os.fstat(fd)
                        if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
                            raise AssertionError(f"file changed while opening for snapshot: {label}")
                        digest = hashlib.sha256()
                        while block := os.read(fd, 65536):
                            digest.update(block)
                        info = os.fstat(fd)
                        named_after = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                        if (named_after.st_dev, named_after.st_ino) != (info.st_dev, info.st_ino):
                            raise AssertionError(f"file changed while snapshotting: {label}")
                        extra["sha256"] = digest.hexdigest()
                    finally:
                        os.close(fd)
                    kind = "file"
                elif stat.S_ISLNK(info.st_mode):
                    info, extra["target"] = _readlink_snapshot(directory_fd, name, label)
                    kind = "symlink"
                elif stat.S_ISDIR(info.st_mode):
                    child_fd = os.open(name, directory_flags, dir_fd=directory_fd)
                    child_info = os.fstat(child_fd)
                    if (child_info.st_dev, child_info.st_ino) != (info.st_dev, info.st_ino):
                        os.close(child_fd)
                        raise AssertionError(f"directory changed while opening for snapshot: {label}")
                    held_directories.append(child_fd)
                    pending.append((child, child_fd))
                    info = child_info
                    kind = "dir"
                else:
                    raise AssertionError(f"unexpected fixture object: {label}")
                observed[child] = {
                    "parent_fd": directory_fd,
                    "name": name,
                    "info": info,
                    "kind": kind,
                    **extra,
                }

        result: dict[str, dict[str, Any]] = {}
        for relative, item in observed.items():
            if relative == ".":
                info = os.fstat(root_fd)
            else:
                info = os.stat(item["name"], dir_fd=item["parent_fd"], follow_symlinks=False)
            before = item["info"]
            if (info.st_dev, info.st_ino) != (before.st_dev, before.st_ino):
                raise AssertionError(f"path changed while snapshotting: {relative}")
            entry = _metadata(info, item["kind"])
            for key in ("sha256", "target"):
                if key in item:
                    entry[key] = item[key]
            result[relative] = entry
        return result
    finally:
        for fd in reversed(held_directories):
            os.close(fd)


def _changed_snapshot_fields(before: dict[str, dict[str, Any]], after: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    changes = []
    for path in sorted(before.keys() | after.keys()):
        old = before.get(path)
        new = after.get(path)
        if old == new:
            continue
        if old is None:
            fields = ["added"]
        elif new is None:
            fields = ["removed"]
        else:
            fields = sorted(key for key in old.keys() | new.keys() if old.get(key) != new.get(key))
        changes.append({"path": path, "fields": fields})
        if len(changes) == 8:
            break
    return changes


def _assert_snapshot_unchanged(before: dict[str, dict[str, Any]], after: dict[str, dict[str, Any]], label: str) -> None:
    if before != after:
        changed = _changed_snapshot_fields(before, after)
        raise AssertionError(f"{label} changed fixture metadata: {json.dumps(changed, sort_keys=True)}")


def _symlink_snapshot(path: Path) -> dict[str, Any]:
    parent_fd = os.open(
        path.parent,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_NOATIME", 0),
    )
    try:
        info, target = _readlink_snapshot(parent_fd, path.name, str(path))
        return {**_metadata(info, "symlink"), "target": target}
    finally:
        os.close(parent_fd)


def _rejected(call: Any, label: str, *, contains: str | None = None) -> str:
    try:
        call()
    except (PUBLISHER.StageRefused, PUBLISHER.StageUnknown, OSError) as error:
        if contains is not None and contains not in str(error):
            raise AssertionError(f"{label} rejected for the wrong reason: {error}") from error
        return type(error).__name__
    raise AssertionError(f"unsafe state was accepted: {label}")


def _test_cli_surface() -> None:
    parser = PUBLISHER._build_parser()
    cases = (
        (lambda argv: parser.parse_args(argv), ["--dry-run", "--root", "/tmp/override"], "unrecognized arguments: --root"),
        (lambda argv: parser.parse_args(argv), ["--apply", "--attempt", "a" * 32, "--uid", "1000"], "unrecognized arguments: --uid"),
        (lambda argv: parser.parse_args(argv), ["--dry-run", "--hook"], "unrecognized arguments: --hook"),
        (lambda argv: parser.parse_args(argv), ["--dry-run", "--apply"], "argument --apply: not allowed with argument --dry-run"),
        (PUBLISHER.main, ["--apply", "--attempt", "bad"], "--apply requires --attempt with exactly"),
        (PUBLISHER.main, ["--dry-run", "--attempt", "a" * 32], "--attempt is valid only with --apply"),
    )
    for call, argv, cause in cases:
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            try:
                call(argv)
            except SystemExit as error:
                if error.code != 2:
                    raise
            else:
                raise AssertionError(f"invalid CLI input was accepted: {argv}")
        if cause not in stderr.getvalue():
            raise AssertionError(f"CLI input {argv} failed for the wrong cause: {stderr.getvalue()}")
    try:
        PUBLISHER._fixture_config(
            "/tmp/not-a-fixture",
            archive_sha256="0" * 64,
            manifest_sha256="0" * 64,
        )
    except PUBLISHER.StageRefused:
        pass
    else:
        raise AssertionError("fixture path outside private /var/tmp was accepted")


def _test_acl_gate() -> str:
    base, root = _new_fixture()
    target = root / "acl-probe"
    _mkdir(target, 0o755)
    fd = os.open(target, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    undefined = 0xFFFFFFFF
    entries = (
        (0x01, 0x07, undefined),
        (0x02, 0x04, 12345),
        (0x04, 0x05, undefined),
        (0x10, 0x05, undefined),
        (0x20, 0x05, undefined),
    )
    acl = struct.pack("<I", 0x0002) + b"".join(struct.pack("<HHI", *entry) for entry in entries)
    try:
        os.setxattr(fd, "system.posix_acl_access", acl)
    except OSError as error:
        if error.errno in {errno.EOPNOTSUPP, errno.ENOTSUP, errno.ENOSYS, errno.EPERM, errno.EACCES}:
            raise RuntimeError(f"SKIP: fixture filesystem cannot set a POSIX ACL: {error}") from error
        raise
    try:
        _rejected(
            lambda: PUBLISHER._secure_directory(fd, "ACL fixture"),
            "ACL-bearing directory",
            contains="POSIX ACL present on ACL fixture",
        )
    finally:
        os.close(fd)
    return base


def _test_noreplace_primitive() -> str:
    base, _root = _new_fixture()
    directory = Path(base) / "atomic"
    _mkdir(directory, 0o755)
    (directory / "temp").write_bytes(b"new bytes\n")
    (directory / "destination").write_bytes(b"old bytes\n")
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        try:
            PUBLISHER._rename_noreplace(fd, "temp", "destination")
        except OSError as error:
            if error.errno != errno.EEXIST:
                raise AssertionError(f"no-replace returned errno {error.errno}, expected EEXIST") from error
        else:
            raise AssertionError("no-replace replaced an existing destination")
    finally:
        os.close(fd)
    if (directory / "destination").read_bytes() != b"old bytes\n":
        raise AssertionError("no-replace changed the existing destination bytes")
    if (directory / "temp").read_bytes() != b"new bytes\n":
        raise AssertionError("no-replace consumed the temporary source")
    return base


def _test_dry_run_and_bundle_rejection(raw: bytes, archive_sha: str, manifest_sha: str) -> dict[str, str]:
    base, root = _new_fixture()
    config = _config(base, archive_sha, manifest_sha)
    bundle = PUBLISHER._validate_bundle(raw, config)
    before = _tree_snapshot(root)
    result = PUBLISHER._dry_run(config, bundle)
    after = _tree_snapshot(root)
    if result["status"] != "READY" or result["destinations_absent"] != 58:
        raise AssertionError("valid dry-run did not report the 58 absent destinations")
    _assert_snapshot_unchanged(before, after, "dry-run canonical fixture tree")

    wrong_archive_pin = dataclasses.replace(config, archive_sha256="0" * 64)
    _rejected(lambda: PUBLISHER._validate_bundle(raw, wrong_archive_pin), "archive pin mismatch", contains="archive SHA256 does not match the accepted pin")
    tampered_archive = raw[:-1] + bytes((raw[-1] ^ 1,))
    _rejected(lambda: PUBLISHER._validate_bundle(tampered_archive, config), "tampered archive", contains="archive SHA256 does not match the accepted pin")
    wrong_manifest_pin = dataclasses.replace(config, manifest_sha256="0" * 64)
    _rejected(lambda: PUBLISHER._validate_bundle(raw, wrong_manifest_pin), "manifest pin mismatch", contains="manifest SHA256 does not match the accepted pin")
    drifted_root = dataclasses.replace(config, root_identity=(config.root_identity[0], config.root_identity[1] + 1))
    _rejected(lambda: PUBLISHER._dry_run(drifted_root, bundle), "root inode pin drift", contains="canonical root identity drift")
    _assert_snapshot_unchanged(before, _tree_snapshot(root), "archive/root-pin refusals")
    return {"dry_run": result["status"], "archive_and_manifest_pins": "REFUSED", "tampered_archive": "REFUSED", "root_pin_drift": "REFUSED", "fixture": base}


def _test_destination_collision(raw: bytes, archive_sha: str, manifest_sha: str) -> str:
    base, root = _new_fixture()
    config = _config(base, archive_sha, manifest_sha)
    bundle = PUBLISHER._validate_bundle(raw, config)
    destination = root / "labctl"
    destination.write_bytes(b"pre-existing target\n")
    before = _tree_snapshot(root)
    cause = f"path must be absent: {destination}"
    _rejected(lambda: PUBLISHER._dry_run(config, bundle), "pre-existing target", contains=cause)
    _rejected(lambda: PUBLISHER._apply(config, bundle, "1" * 32), "apply target collision", contains=cause)
    _assert_snapshot_unchanged(before, _tree_snapshot(root), "target-collision refusal")
    return base


def _test_p004_mode_drift(raw: bytes, archive_sha: str, manifest_sha: str) -> dict[str, str]:
    base, root = _new_fixture(p004_mode=0o755)
    config = _config(base, archive_sha, manifest_sha)
    bundle = PUBLISHER._validate_bundle(raw, config)
    before = _tree_snapshot(root)
    p004_path = root / "evidence" / "P004"
    _rejected(
        lambda: PUBLISHER._dry_run(config, bundle),
        "P004 mode drift",
        contains=f"directory mode drift at {p004_path}",
    )
    _assert_snapshot_unchanged(before, _tree_snapshot(root), "P004 mode-drift refusal")
    if os.path.lexists(config.store):
        raise AssertionError("P004 mode-drift refusal created the global ledger")
    return {"fixture": base, "cause": "P004 exact mode 0700 required", "effects": "NONE"}


def _test_prior_store_refusal(raw: bytes, archive_sha: str, manifest_sha: str) -> list[str]:
    retained: list[str] = []
    for shape in ("empty-directory", "malformed-file", "symlink"):
        base, root = _new_fixture()
        config = _config(base, archive_sha, manifest_sha)
        bundle = PUBLISHER._validate_bundle(raw, config)
        store = Path(config.store)
        if shape == "empty-directory":
            _mkdir(store, 0o700)
        elif shape == "malformed-file":
            store.write_bytes(b"not a ledger\n")
        else:
            os.symlink("missing-ledger-target", store)
        before = _tree_snapshot(root)
        for mode in ("dry-run", "apply"):
            if mode == "dry-run":
                call = lambda: PUBLISHER._dry_run(config, bundle)
            else:
                call = lambda: PUBLISHER._apply(config, bundle, "2" * 32)
            _rejected(call, f"prior {shape} store {mode}", contains=f"path must be absent: {config.store}")
        _assert_snapshot_unchanged(before, _tree_snapshot(root), f"prior {shape} store refusal")
        retained.append(base)
    return retained


def _expected_effects(config: Any, bundle: Any, attempt: str) -> tuple[tuple[str, ...], list[tuple[str, str, str | None]]]:
    directories = PUBLISHER._required_destination_directories(config, bundle)
    effects = [("mkdir", path, None) for path in directories]
    for index, (relative, (source, _data, digest)) in enumerate(sorted(bundle.publish.items()), start=1):
        parent = str(PurePosixPath(config.root) / PurePosixPath(relative).parent)
        temporary = f".p004-reviewed-source-{attempt}-{index:03d}.tmp"
        effects.append(("temp-create-write-fsync", f"{parent}/{temporary}", digest))
        effects.append(("publish-noreplace", f"{config.root}/{relative}", digest))
    return directories, effects


def _read_ledger_records(config: Any, attempt: str, bundle: Any, effects: list[tuple[str, str, str | None]], terminal_status: str, failed_step: str | None, *, error_contains: str | None = None) -> dict[str, Any]:
    store_fd = os.open(config.store, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_NOATIME", 0))
    try:
        store_info = os.fstat(store_fd)
        if (store_info.st_uid, store_info.st_gid, stat.S_IMODE(store_info.st_mode)) != (0, 0, 0o700):
            raise AssertionError("global ledger directory is not root:root mode 0700")
        PUBLISHER._reject_acl_fd(store_fd, "fixture ledger")
        records: dict[str, Any] = {}
        names = sorted(os.listdir(store_fd))
        expected_names = {f"run-{attempt}.intent.json", f"run-{attempt}.terminal.json"}
        for sequence in range(1, len(effects) + 1):
            expected_names.add(f"run-{attempt}-step-{sequence:03d}.intent.json")
            expected_names.add(f"run-{attempt}-step-{sequence:03d}.result.json")
        if set(names) != expected_names:
            raise AssertionError(f"ledger record set differs: missing={sorted(expected_names - set(names))[:4]} extra={sorted(set(names) - expected_names)[:4]}")
        for name in names:
            fd = os.open(name, PUBLISHER.FILE_READ_FLAGS, dir_fd=store_fd)
            try:
                before = os.fstat(fd)
                named_before = os.stat(name, dir_fd=store_fd, follow_symlinks=False)
                if not stat.S_ISREG(before.st_mode) or (before.st_uid, before.st_gid, stat.S_IMODE(before.st_mode), before.st_nlink) != (0, 0, 0o600, 1):
                    raise AssertionError(f"ledger record is not root:root mode 0600 nlink 1: {name}")
                if (named_before.st_dev, named_before.st_ino) != (before.st_dev, before.st_ino):
                    raise AssertionError(f"ledger record name changed before read: {name}")
                raw = bytearray()
                while block := os.read(fd, 65536):
                    raw.extend(block)
                after = os.fstat(fd)
                named_after = os.stat(name, dir_fd=store_fd, follow_symlinks=False)
                if (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino) or (named_after.st_dev, named_after.st_ino) != (after.st_dev, after.st_ino):
                    raise AssertionError(f"ledger record changed while read: {name}")
                records[name] = json.loads(raw)
            finally:
                os.close(fd)

        intent = records[f"run-{attempt}.intent.json"]
        if (intent.get("schema"), intent.get("status"), intent.get("attempt"), intent.get("archive_sha256"), intent.get("manifest_sha256")) != (
            "p004-reviewed-source-stage-intent-v1",
            "INTENT_DURABLE",
            attempt,
            bundle.archive_sha256,
            bundle.manifest_sha256,
        ):
            raise AssertionError("global ledger intent does not bind this approved archive and attempt")
        if (intent.get("source_files"), intent.get("published_sources"), intent.get("historical_evidence_not_staged"), intent.get("actual_X05")) != (70, 58, 12, "NOT_RUN"):
            raise AssertionError("global ledger intent does not bind the 70/58/12 source boundary")

        for sequence, (operation, target, digest) in enumerate(effects, start=1):
            intent_name = f"run-{attempt}-step-{sequence:03d}.intent.json"
            result_name = f"run-{attempt}-step-{sequence:03d}.result.json"
            step_intent = records[intent_name]
            step_result = records[result_name]
            if (step_intent.get("schema"), step_intent.get("attempt"), step_intent.get("sequence"), step_intent.get("operation"), step_intent.get("target"), step_intent.get("sha256"), step_intent.get("status")) != (
                "p004-reviewed-source-stage-step-intent-v1",
                attempt,
                sequence,
                operation,
                target,
                digest,
                "INTENT_DURABLE",
            ):
                raise AssertionError(f"step {sequence} intent has the wrong ordered operation, target, digest, or status")
            expected_status = "UNKNOWN" if sequence == len(effects) and terminal_status == "UNKNOWN" else "PROVED"
            if (step_result.get("schema"), step_result.get("attempt"), step_result.get("sequence"), step_result.get("operation"), step_result.get("target"), step_result.get("status")) != (
                "p004-reviewed-source-stage-step-result-v1",
                attempt,
                sequence,
                operation,
                target,
                expected_status,
            ):
                raise AssertionError(f"step {sequence} result does not follow its durable intent")
            details = step_result.get("details")
            if not isinstance(details, dict):
                raise AssertionError(f"step {sequence} result has no details object")
            if expected_status == "UNKNOWN":
                if details.get("effect_may_have_occurred") is not True:
                    raise AssertionError("UNKNOWN result does not identify an ambiguous effect")
                if error_contains is not None and error_contains not in step_result.get("error", {}).get("message", ""):
                    raise AssertionError("UNKNOWN result lost the injected failure cause")
            elif digest is not None:
                if details.get("sha256") != digest:
                    raise AssertionError(f"step {sequence} readback digest differs from its target intent")
            elif (details.get("uid"), details.get("gid"), details.get("mode")) != (0, 0, "0o755"):
                raise AssertionError(f"step {sequence} directory result does not prove root:root mode 0755")

        terminal = records[f"run-{attempt}.terminal.json"]
        if (terminal.get("schema"), terminal.get("attempt"), terminal.get("status"), terminal.get("failed_step")) != (
            "p004-reviewed-source-stage-terminal-v1",
            attempt,
            terminal_status,
            failed_step,
        ):
            raise AssertionError("terminal record does not match the durable effect sequence")
        if (terminal.get("automatic_retry"), terminal.get("automatic_cleanup"), terminal.get("automatic_rollback"), terminal.get("actual_X05")) != (False, False, False, "NOT_RUN"):
            raise AssertionError("terminal record permits retry, cleanup, rollback, or X05")
        return {"records": len(records), "effects": len(effects), "terminal": terminal_status}
    finally:
        os.close(store_fd)


def _test_successful_publication(raw: bytes, archive_sha: str, manifest_sha: str) -> dict[str, Any]:
    base, root = _new_fixture()
    config = _config(base, archive_sha, manifest_sha)
    bundle = PUBLISHER._validate_bundle(raw, config)
    attempt = "3" * 32
    legacy_before = _tree_snapshot(root / "evidence")
    lock_before = _file_snapshot(Path(config.lock_path))
    alias_before = _symlink_snapshot(root / "agent" / "evidence")
    result = PUBLISHER._apply(config, bundle, attempt)
    if result["status"] != "PASS_STAGED_SOURCE_ONLY" or result["source_files_published"] != 58:
        raise AssertionError("fixture publication did not prove all 58 source files")
    if len(result["entries"]) != 58 or result["attempt"] != attempt:
        raise AssertionError("publication result omitted exact entries or attempt identity")
    expected_entries = [
        (source, f"{config.root}/{relative}", digest, "0o755" if relative == "labctl" or relative.endswith(".sh") else "0o644")
        for relative, (source, _data, digest) in sorted(bundle.publish.items())
    ]
    actual_entries = [(entry["source"], entry["destination"], entry["sha256"], entry["mode"]) for entry in result["entries"]]
    if actual_entries != expected_entries:
        raise AssertionError("publication result entries differ from the ordered source/destination/hash manifest")
    directories, effects = _expected_effects(config, bundle, attempt)
    ledger = _read_ledger_records(
        config,
        attempt,
        bundle,
        effects,
        "PASS_STAGED_SOURCE_ONLY",
        None,
    )
    for relative, (_source, data, digest) in bundle.publish.items():
        parent = root / PurePosixPath(relative).parent
        target = parent / PurePosixPath(relative).name
        info = os.lstat(target)
        mode = 0o755 if relative == "labctl" or relative.endswith(".sh") else 0o644
        if not stat.S_ISREG(info.st_mode) or (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode), info.st_nlink) != (0, 0, mode, 1):
            raise AssertionError(f"published mode/owner/link count drift: {relative}")
        if target.read_bytes() != data or hashlib.sha256(target.read_bytes()).hexdigest() != digest:
            raise AssertionError(f"published content drift: {relative}")
    _assert_snapshot_unchanged(legacy_before, _tree_snapshot(root / "evidence"), "legacy evidence tree")
    _assert_snapshot_unchanged(
        {"legacy-alias": alias_before},
        {"legacy-alias": _symlink_snapshot(root / "agent" / "evidence")},
        "legacy evidence alias",
    )
    _assert_snapshot_unchanged(
        {"canonical-lock": lock_before},
        {"canonical-lock": _file_snapshot(Path(config.lock_path))},
        "canonical lock file",
    )
    return {"fixture": base, "status": result["status"], "published": len(bundle.publish), "historical_skipped": len(bundle.historical), "legacy_unchanged": True, "ledger": ledger}


def _test_unknown_after_publication(raw: bytes, archive_sha: str, manifest_sha: str) -> dict[str, Any]:
    base, root = _new_fixture()
    config = _config(base, archive_sha, manifest_sha)
    bundle = PUBLISHER._validate_bundle(raw, config)
    attempt = "4" * 32
    fired = False

    def fail_after_publish(event: str, _values: Any) -> None:
        nonlocal fired
        if event == "after:renameat2":
            fired = True
            raise RuntimeError("fixture failure after atomic publication")

    try:
        PUBLISHER._apply(config, bundle, attempt, hook=fail_after_publish)
    except PUBLISHER.StageUnknown as error:
        if not fired or "UNKNOWN" not in str(error):
            raise AssertionError(f"failure was not retained as post-publication UNKNOWN: {error}") from error
    else:
        raise AssertionError("post-publication fault did not retain UNKNOWN")

    directories, full_effects = _expected_effects(config, bundle, attempt)
    effects = full_effects[: len(directories) + 2]
    ledger = _read_ledger_records(
        config,
        attempt,
        bundle,
        effects,
        "UNKNOWN",
        "publish-noreplace",
        error_contains="fixture failure after atomic publication",
    )
    relative, (source, data, digest) = sorted(bundle.publish.items())[0]
    destination = root / relative
    parent = destination.parent
    temporary = parent / f".p004-reviewed-source-{attempt}-001.tmp"
    mode = 0o755 if relative == "labctl" or relative.endswith(".sh") else 0o644
    published = _file_snapshot(destination)
    if (published["uid"], published["gid"], published["mode"], published["nlink"], published["sha256"]) != (0, 0, mode, 1, digest):
        raise AssertionError("post-rename UNKNOWN did not retain the exact published source")
    if published["size"] != len(data) or PUBLISHER._source_destination(source) != relative:
        raise AssertionError("post-rename UNKNOWN retained-source metadata is incomplete")
    if os.path.lexists(temporary):
        raise AssertionError("atomic rename left its source temporary unexpectedly present")
    for directory in directories:
        info = os.lstat(directory)
        if not stat.S_ISDIR(info.st_mode) or (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != (0, 0, 0o755):
            raise AssertionError(f"post-rename UNKNOWN cleaned or changed destination directory: {directory}")
    for other_relative, _value in sorted(bundle.publish.items())[1:]:
        if os.path.lexists(root / other_relative):
            raise AssertionError(f"post-rename UNKNOWN published a later source unexpectedly: {other_relative}")

    cause = f"path must be absent: {config.store}"
    _rejected(lambda: PUBLISHER._dry_run(config, bundle), "UNKNOWN dry-run replay", contains=cause)
    _rejected(lambda: PUBLISHER._apply(config, bundle, "5" * 32), "UNKNOWN apply replay", contains=cause)
    return {"fixture": base, "ledger": ledger, "published_source_retained": str(destination), "renamed_temporary_absent": str(temporary), "directories_retained": len(directories), "replay": "DRY_RUN_AND_APPLY_REFUSED"}


def _test_unknown_after_temp_creation(raw: bytes, archive_sha: str, manifest_sha: str) -> dict[str, Any]:
    base, root = _new_fixture()
    config = _config(base, archive_sha, manifest_sha)
    bundle = PUBLISHER._validate_bundle(raw, config)
    attempt = "6" * 32
    fired = False

    def fail_after_temp(event: str, _values: Any) -> None:
        nonlocal fired
        if event == "after:temp-create-write-fsync":
            fired = True
            raise RuntimeError("fixture failure after temporary creation")

    try:
        PUBLISHER._apply(config, bundle, attempt, hook=fail_after_temp)
    except PUBLISHER.StageUnknown as error:
        if not fired or "UNKNOWN" not in str(error):
            raise AssertionError(f"temporary-write failure was not retained as UNKNOWN: {error}") from error
    else:
        raise AssertionError("post-temp-write fault did not retain UNKNOWN")

    directories, full_effects = _expected_effects(config, bundle, attempt)
    effects = full_effects[: len(directories) + 1]
    ledger = _read_ledger_records(
        config,
        attempt,
        bundle,
        effects,
        "UNKNOWN",
        "temp-create-write-fsync",
        error_contains="fixture failure after temporary creation",
    )
    relative, (_source, data, digest) = sorted(bundle.publish.items())[0]
    parent = root / PurePosixPath(relative).parent
    temporary = parent / f".p004-reviewed-source-{attempt}-001.tmp"
    mode = 0o755 if relative == "labctl" or relative.endswith(".sh") else 0o644
    retained = _file_snapshot(temporary)
    if (retained["uid"], retained["gid"], retained["mode"], retained["nlink"], retained["size"], retained["sha256"]) != (0, 0, mode, 1, len(data), digest):
        raise AssertionError("post-temp-write UNKNOWN did not retain the exact temporary file")
    if os.path.lexists(root / relative):
        raise AssertionError("post-temp-write UNKNOWN published the destination unexpectedly")
    for directory in directories:
        info = os.lstat(directory)
        if not stat.S_ISDIR(info.st_mode) or (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != (0, 0, 0o755):
            raise AssertionError(f"post-temp-write UNKNOWN cleaned or changed destination directory: {directory}")
    cause = f"path must be absent: {config.store}"
    _rejected(lambda: PUBLISHER._dry_run(config, bundle), "UNKNOWN temp dry-run replay", contains=cause)
    _rejected(lambda: PUBLISHER._apply(config, bundle, "7" * 32), "UNKNOWN temp apply replay", contains=cause)
    return {"fixture": base, "ledger": ledger, "temporary_retained": str(temporary), "directories_retained": len(directories), "replay": "DRY_RUN_AND_APPLY_REFUSED"}


def main() -> int:
    if platform.system() != "Linux" or os.geteuid() != 0 or os.getegid() != 0:
        print(json.dumps({"status": "SKIP", "reason": "Linux and effective UID/GID 0 are required", "exit_code": 77}, sort_keys=True))
        return 77
    try:
        acl_fixture = _test_acl_gate()
        raw, archive_sha, manifest_sha = _approved_shaped_archive()
        _test_cli_surface()
        dry_run = _test_dry_run_and_bundle_rejection(raw, archive_sha, manifest_sha)
        p004_mode_drift = _test_p004_mode_drift(raw, archive_sha, manifest_sha)
        collision_fixture = _test_destination_collision(raw, archive_sha, manifest_sha)
        no_replace_fixture = _test_noreplace_primitive()
        prior_stores = _test_prior_store_refusal(raw, archive_sha, manifest_sha)
        publication = _test_successful_publication(raw, archive_sha, manifest_sha)
        unknown_fixture = _test_unknown_after_publication(raw, archive_sha, manifest_sha)
        unknown_temp_fixture = _test_unknown_after_temp_creation(raw, archive_sha, manifest_sha)
    except RuntimeError as error:
        if str(error).startswith("SKIP:"):
            print(json.dumps({"status": "SKIP", "reason": str(error), "exit_code": 77}, sort_keys=True))
            return 77
        raise
    result = {
        "status": "PASS_FIXTURE_ONLY",
        "acl_gate": "PASS",
        "dry_run_and_pins": dry_run,
        "p004_mode_drift": p004_mode_drift,
        "destination_collision": "REFUSED_WITHOUT_EFFECTS",
        "rename_noreplace": "PASS_EXISTING_BYTES_PRESERVED",
        "prior_store_shapes": ["empty-directory", "malformed-file", "symlink"],
        "prior_store_modes": ["dry-run", "apply"],
        "prior_store_fixtures_retained": prior_stores,
        "publication": publication,
        "legacy_evidence_and_alias": "UNCHANGED_BYTES_OWNERS_MODES_TIMESTAMPS",
        "unknown_replay": "RETAINED; DRY_RUN_AND_APPLY_REFUSED",
        "unknown_fixture_retained": unknown_fixture,
        "unknown_temp_fixture_retained": unknown_temp_fixture,
        "other_fixture_roots": [acl_fixture, collision_fixture, no_replace_fixture],
        "actual_X05": "NOT_RUN",
    }
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
