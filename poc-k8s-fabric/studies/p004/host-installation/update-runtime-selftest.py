#!/usr/bin/env python3
"""Replace one pinned X05 runtime selftest while retaining its old inode.

Production accepts only the fixed host layout, one reviewed payload on stdin,
and either a read-only dry run or one attempt ID.  The old file is parked next
to the new file by one same-directory RENAME_EXCHANGE and is never removed.
"""

from __future__ import annotations

import argparse
import ctypes
import dataclasses
import errno
import hashlib
import json
import os
from pathlib import PurePosixPath
import platform
import re
import stat
import sys
from types import ModuleType
from typing import Any, Callable, Mapping


PRODUCTION_ROOT = "/opt/poc-k8s-fabric"
TARGET = "/opt/poc-k8s-fabric/studies/p004/ovn/x05-runtime-live-selftest.py"
PRODUCTION_STORE = "/var/lib/p004-runtime-selftest-maintenance"
PRODUCTION_LOCK = "/run/lock/labctl-dci-m03.lock"
PRODUCTION_MARKERS = (
    "/run/labctl/dci-m03/active",
    "/run/labctl/dci-x05/active",
)
BASELINE_NAME = "update-runtime-selftest-baseline.json"
PUBLISHER_NAME = "stage-reviewed-sources.py"
BASELINE_SHA256 = "b11b3b75794e3832c36f7fd93d5e8881bb02a3748b39376dded4234f189b4890"
PUBLISHER_SHA256 = "29d525794e767e241c778fe3cd706e60b4231b4ac0eeca7426e5f975594ed436"
NEW_SELFTEST_SHA256 = "6d0b32c80363dcc825908353f9bccc2684c0c59a09c7e021b5607bb04268c82f"
OLD_SELFTEST_SHA256 = "1979880abee1580613175a7c1f0b43da8d1497bbd7150ab97bb3334f80741571"
MAX_SELFTEST_BYTES = 512 * 1024
EXPECTED_SOURCE_COUNT = 58
PROTECTED_SOURCE_COUNT = 57
CODE_DIRECTORY_PREFIX = "p004-runtime-selftest-maintenance-code-"
FIXTURE_DIRECTORY_PREFIX = "p004-reviewed-source-stage-fixture-"
ATTEMPT_RE = re.compile(r"[0-9a-f]{32}\Z")
ACL_XATTRS = {"system.posix_acl_access", "system.posix_acl_default"}
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
FILE_READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | getattr(os, "O_NOATIME", 0)
FILE_CREATE_FLAGS = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
RENAME_EXCHANGE = 2
H4_PINS = {
    "/opt/poc-k8s-fabric": (64769, 262224, 0o755),
    "/opt/poc-k8s-fabric/evidence": (64769, 3742352, 0o755),
    "/opt/poc-k8s-fabric/evidence/P004": (64769, 3742353, 0o700),
    "/opt/poc-k8s-fabric/evidence/P004/S002": (64769, 3742354, 0o700),
}
PRIOR_TERMINALS = (
    {
        "path": "/var/lib/p004-host-installation/46813ff4d8ca4af4bd0ecff838210587/terminal.json",
        "sha256": "7c832fac9d06bf570e1e7ab29bd2f4d5e958473c4d8280f1836123e37bba1efc",
        "status": "PROVED",
    },
    {
        "path": "/var/lib/p004-reviewed-source-stage/run-9ea6c54af912498d81eee386f23dd1d9.terminal.json",
        "sha256": "7a7669943d0564c640f92bc7afb39a978d006d87b45a2cc8ec0c396a59b88420",
        "status": "PASS_STAGED_SOURCE_ONLY",
    },
)


class MaintenanceRefused(RuntimeError):
    """A fixed precondition failed before this attempt could write state."""


class MaintenanceUnknown(RuntimeError):
    """An effect may have occurred; the one-shot store must remain retained."""


@dataclasses.dataclass(frozen=True)
class _Entry:
    source: str
    destination: str
    dev: int
    inode: int
    uid: int
    gid: int
    mode: int
    nlink: int
    size: int
    sha256: str


@dataclasses.dataclass(frozen=True)
class _PriorTerminal:
    path: str
    sha256: str
    status: str


@dataclasses.dataclass(frozen=True)
class _Baseline:
    sha256: str
    old_selftest_sha256: str
    target: str
    entries: tuple[_Entry, ...]
    prior_terminals: tuple[_PriorTerminal, ...]
    is_fixture: bool = False


@dataclasses.dataclass(frozen=True)
class _RuntimeConfig:
    directories_config: Any
    ancestor_pins: Mapping[str, tuple[int, int, int]]
    code_root: str
    is_fixture: bool


@dataclasses.dataclass
class _CodeContext:
    code_root: str
    fds: dict[str, int]

    @property
    def directory_fd(self) -> int:
        return self.fds[self.code_root]

    def revalidate(self) -> None:
        for path in sorted(self.fds, key=lambda value: (value.count("/"), value)):
            fd = self.fds[path]
            info = os.fstat(fd)
            if not stat.S_ISDIR(info.st_mode) or (info.st_uid, info.st_gid) != (0, 0):
                raise MaintenanceRefused(f"code path is not a root-owned directory: {path}")
            if path == "/var/tmp":
                if not info.st_mode & stat.S_ISVTX:
                    raise MaintenanceRefused("/var/tmp lost its sticky bit")
            elif path == self.code_root:
                if stat.S_IMODE(info.st_mode) != 0o700:
                    raise MaintenanceRefused("private code directory mode drift")
            elif info.st_mode & 0o022:
                raise MaintenanceRefused(f"code ancestor is group/other writable: {path}")
            _reject_acl_fd(fd, path)
            if path == "/":
                continue
            parent = str(PurePosixPath(path).parent)
            name = PurePosixPath(path).name
            if parent not in self.fds:
                raise MaintenanceRefused(f"code path parent is not held: {parent}")
            named = os.stat(name, dir_fd=self.fds[parent], follow_symlinks=False)
            if not stat.S_ISDIR(named.st_mode) or (named.st_dev, named.st_ino) != (info.st_dev, info.st_ino):
                raise MaintenanceRefused(f"private code path name drift: {path}")

    def close(self) -> None:
        for fd in reversed(tuple(self.fds.values())):
            try:
                os.close(fd)
            except OSError:
                pass
        self.fds.clear()


@dataclasses.dataclass
class _Assets:
    code: _CodeContext
    publisher: ModuleType
    baseline: _Baseline

    def close(self) -> None:
        self.code.close()


def _reject_acl_fd(fd: int, label: str) -> None:
    try:
        names = set(os.listxattr(fd))
    except (OSError, TypeError) as error:
        raise MaintenanceRefused(f"cannot inspect ACLs on {label}: {error}") from error
    present = sorted(names & ACL_XATTRS)
    if present:
        raise MaintenanceRefused(f"POSIX ACL present on {label}: {', '.join(present)}")


def _stat_signature(info: os.stat_result) -> tuple[int, ...]:
    return (
        info.st_dev,
        info.st_ino,
        info.st_uid,
        info.st_gid,
        info.st_mode,
        info.st_nlink,
        info.st_size,
        info.st_atime_ns,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def _open_held_absolute_directory(path: str, fds: dict[str, int]) -> int:
    if not path.startswith("/") or str(PurePosixPath(path)) != path:
        raise MaintenanceRefused(f"non-canonical directory path: {path}")
    current = "/"
    if current not in fds:
        fds[current] = os.open("/", DIRECTORY_FLAGS)
    parent_fd = fds[current]
    for part in PurePosixPath(path).parts[1:]:
        child = str(PurePosixPath(current) / part)
        if child in fds:
            current = child
            parent_fd = fds[child]
            continue
        named = os.stat(part, dir_fd=parent_fd, follow_symlinks=False)
        if not stat.S_ISDIR(named.st_mode):
            raise MaintenanceRefused(f"path component is not a real directory: {child}")
        child_fd = os.open(part, DIRECTORY_FLAGS, dir_fd=parent_fd)
        opened = os.fstat(child_fd)
        if (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino):
            os.close(child_fd)
            raise MaintenanceRefused(f"directory changed while opening: {child}")
        fds[child] = child_fd
        current = child
        parent_fd = child_fd
    return parent_fd


def _open_code_context(script_path: str) -> _CodeContext:
    script = PurePosixPath(script_path)
    if not script.is_absolute() or str(script) != script_path:
        raise MaintenanceRefused("helper path must be absolute and canonical")
    code_root = str(script.parent)
    if PurePosixPath(code_root).parent != PurePosixPath("/var/tmp"):
        raise MaintenanceRefused("private code directory must be directly beneath /var/tmp")
    if not PurePosixPath(code_root).name.startswith(CODE_DIRECTORY_PREFIX):
        raise MaintenanceRefused("private code directory has an unapproved name")
    fds: dict[str, int] = {}
    try:
        _open_held_absolute_directory("/var/tmp", fds)
        code_fd = _open_held_absolute_directory(code_root, fds)
        tmp_info = os.fstat(fds["/var/tmp"])
        if (tmp_info.st_uid, tmp_info.st_gid) != (0, 0) or not stat.S_ISVTX & tmp_info.st_mode:
            raise MaintenanceRefused("/var/tmp is not a root-owned sticky directory")
        code_info = os.fstat(code_fd)
        if not stat.S_ISDIR(code_info.st_mode) or (code_info.st_uid, code_info.st_gid, stat.S_IMODE(code_info.st_mode)) != (0, 0, 0o700):
            raise MaintenanceRefused("private code directory must be root:root mode 0700")
        for fd, label in ((fds["/var/tmp"], "/var/tmp"), (code_fd, code_root)):
            _reject_acl_fd(fd, label)
        context = _CodeContext(code_root=code_root, fds=fds)
        context.revalidate()
        return context
    except BaseException:
        for fd in reversed(tuple(fds.values())):
            try:
                os.close(fd)
            except OSError:
                pass
        raise


def _read_file_at(
    parent_fd: int,
    name: str,
    *,
    label: str,
    expected_sha256: str | None = None,
    expected_size: int | None = None,
    expected_metadata: Mapping[str, int] | None = None,
    allowed_modes: tuple[int, ...] = (0o600, 0o644),
    maximum: int = 16 * 1024 * 1024,
) -> tuple[bytes, os.stat_result]:
    if "/" in name or name in {"", ".", ".."}:
        raise MaintenanceRefused(f"invalid file name: {label}")
    try:
        fd = os.open(name, FILE_READ_FLAGS, dir_fd=parent_fd)
    except OSError as error:
        raise MaintenanceRefused(f"cannot open fixed file {label}: {error}") from error
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise MaintenanceRefused(f"not a regular file: {label}")
        if (before.st_uid, before.st_gid) != (0, 0) or stat.S_IMODE(before.st_mode) not in allowed_modes or before.st_nlink != 1:
            raise MaintenanceRefused(f"fixed file metadata drift: {label}")
        if before.st_size > maximum or (expected_size is not None and before.st_size != expected_size):
            raise MaintenanceRefused(f"fixed file size drift: {label}")
        if expected_metadata is not None:
            actual = {
                "dev": before.st_dev,
                "inode": before.st_ino,
                "uid": before.st_uid,
                "gid": before.st_gid,
                "mode": stat.S_IMODE(before.st_mode),
                "nlink": before.st_nlink,
                "size": before.st_size,
            }
            for key, value in expected_metadata.items():
                if actual.get(key) != value:
                    raise MaintenanceRefused(f"fixed file {key} drift: {label}")
        _reject_acl_fd(fd, label)
        chunks: list[bytes] = []
        size = 0
        digest = hashlib.sha256()
        while True:
            block = os.read(fd, min(1024 * 1024, maximum + 1 - size))
            if not block:
                break
            chunks.append(block)
            digest.update(block)
            size += len(block)
            if size > maximum:
                raise MaintenanceRefused(f"fixed file exceeds size limit: {label}")
        raw = b"".join(chunks)
        after = os.fstat(fd)
        named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if _stat_signature(before) != _stat_signature(after):
            raise MaintenanceRefused(f"file changed while reading: {label}")
        if (named.st_dev, named.st_ino) != (after.st_dev, after.st_ino):
            raise MaintenanceRefused(f"file name changed while reading: {label}")
        if size != after.st_size or (expected_size is not None and size != expected_size):
            raise MaintenanceRefused(f"file readback size drift: {label}")
        if expected_sha256 is not None and digest.hexdigest() != expected_sha256:
            raise MaintenanceRefused(f"file hash drift: {label}")
        _reject_acl_fd(fd, label)
        return raw, after
    finally:
        os.close(fd)


def _read_code_file(code: _CodeContext, name: str, digest: str, modes: tuple[int, ...]) -> bytes:
    code.revalidate()
    raw, _info = _read_file_at(
        code.directory_fd,
        name,
        label=f"{code.code_root}/{name}",
        expected_sha256=digest,
        allowed_modes=modes,
        maximum=2 * 1024 * 1024,
    )
    code.revalidate()
    return raw


def _parse_baseline(raw: bytes) -> _Baseline:
    try:
        value = json.loads(
            raw,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=lambda token: (_ for _ in ()).throw(ValueError(f"non-finite JSON number: {token}")),
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise MaintenanceRefused(f"invalid pinned baseline JSON: {error}") from error
    expected_top = {
        "entries",
        "old_selftest_sha256",
        "prior_terminals",
        "publisher_sha256",
        "schema",
        "session",
        "stage_acceptance_sha256",
        "target",
    }
    if not isinstance(value, dict) or set(value) != expected_top:
        raise MaintenanceRefused("pinned baseline has an unexpected shape")
    if value["schema"] != "p004-runtime-selftest-maintenance-baseline-v1" or value["session"] != "P004-S002":
        raise MaintenanceRefused("pinned baseline identity drift")
    if value["target"] != TARGET or value["old_selftest_sha256"] != OLD_SELFTEST_SHA256:
        raise MaintenanceRefused("pinned baseline target drift")
    if value["publisher_sha256"] != PUBLISHER_SHA256:
        raise MaintenanceRefused("pinned baseline publisher pin drift")
    if value["prior_terminals"] != list(PRIOR_TERMINALS):
        raise MaintenanceRefused("pinned baseline prior proof pins drift")
    entries_raw = value["entries"]
    if not isinstance(entries_raw, list) or len(entries_raw) != EXPECTED_SOURCE_COUNT:
        raise MaintenanceRefused("pinned baseline must contain exactly 58 entries")
    entries: list[_Entry] = []
    destinations: set[str] = set()
    target_entries: list[_Entry] = []
    required_entry_keys = {"destination", "dev", "gid", "inode", "mode", "nlink", "sha256", "size", "source", "uid"}
    for raw_entry in entries_raw:
        if not isinstance(raw_entry, dict) or set(raw_entry) != required_entry_keys:
            raise MaintenanceRefused("pinned baseline entry has an unexpected shape")
        destination = raw_entry["destination"]
        pure = PurePosixPath(destination) if isinstance(destination, str) else PurePosixPath(".")
        if not isinstance(destination, str) or not pure.is_absolute() or str(pure) != destination or not destination.startswith(PRODUCTION_ROOT + "/"):
            raise MaintenanceRefused("pinned baseline destination is outside the canonical root")
        if destination in destinations:
            raise MaintenanceRefused("pinned baseline contains duplicate destinations")
        destinations.add(destination)
        numeric = ("dev", "gid", "inode", "nlink", "size", "uid")
        if any(type(raw_entry[key]) is not int or raw_entry[key] < 0 for key in numeric):
            raise MaintenanceRefused("pinned baseline contains invalid metadata")
        mode_text = raw_entry["mode"]
        if mode_text not in {"0o644", "0o755"}:
            raise MaintenanceRefused("pinned baseline contains an unsupported file mode")
        if raw_entry["uid"] != 0 or raw_entry["gid"] != 0 or raw_entry["nlink"] != 1:
            raise MaintenanceRefused("pinned baseline file ownership/link contract drift")
        digest = raw_entry["sha256"]
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise MaintenanceRefused("pinned baseline contains an invalid SHA256")
        source = raw_entry["source"]
        if not isinstance(source, str) or not source or "\x00" in source or "\\" in source:
            raise MaintenanceRefused("pinned baseline contains an invalid source name")
        entry = _Entry(
            source=source,
            destination=destination,
            dev=raw_entry["dev"],
            inode=raw_entry["inode"],
            uid=raw_entry["uid"],
            gid=raw_entry["gid"],
            mode=int(mode_text, 8),
            nlink=raw_entry["nlink"],
            size=raw_entry["size"],
            sha256=digest,
        )
        entries.append(entry)
        if destination == TARGET:
            target_entries.append(entry)
    if len(target_entries) != 1 or target_entries[0].sha256 != OLD_SELFTEST_SHA256:
        raise MaintenanceRefused("pinned baseline target entry does not match the original selftest")
    if len(destinations) != EXPECTED_SOURCE_COUNT:
        raise MaintenanceRefused("pinned baseline destination count drift")
    proofs = tuple(_PriorTerminal(**item) for item in value["prior_terminals"])
    return _Baseline(
        sha256=BASELINE_SHA256,
        old_selftest_sha256=OLD_SELFTEST_SHA256,
        target=TARGET,
        entries=tuple(entries),
        prior_terminals=proofs,
    )


def _reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _load_assets(script_path: str | None = None) -> _Assets:
    path = script_path or os.path.abspath(__file__)
    code = _open_code_context(path)
    try:
        baseline_raw = _read_code_file(code, BASELINE_NAME, BASELINE_SHA256, (0o600, 0o644))
        publisher_raw = _read_code_file(code, PUBLISHER_NAME, PUBLISHER_SHA256, (0o600, 0o644))
        name = "p004_stage_reviewed_sources_pinned_runtime_selftest_maintenance"
        if name in sys.modules:
            raise MaintenanceRefused("pinned publisher module name is already registered")
        publisher = ModuleType(name)
        publisher.__file__ = f"{code.code_root}/{PUBLISHER_NAME}"
        sys.modules[name] = publisher
        try:
            exec(compile(publisher_raw, publisher.__file__, "exec"), publisher.__dict__)
        except BaseException:
            sys.modules.pop(name, None)
            raise
        baseline = _parse_baseline(baseline_raw)
        return _Assets(code=code, publisher=publisher, baseline=baseline)
    except BaseException:
        code.close()
        raise


def _production_config(assets: _Assets) -> _RuntimeConfig:
    stage_config = dataclasses.replace(assets.publisher._production_config(), store=PRODUCTION_STORE)
    return _RuntimeConfig(
        directories_config=stage_config,
        ancestor_pins=H4_PINS,
        code_root=assets.code.code_root,
        is_fixture=False,
    )


def _fixture_config(base: str, publisher: ModuleType) -> _RuntimeConfig:
    """Build the only test configuration from the approved private fixture API."""
    stage_config = publisher._fixture_config(
        base,
        archive_sha256="0" * 64,
        manifest_sha256="1" * 64,
    )
    stage_config = dataclasses.replace(stage_config, store=f"{base}/runtime-selftest-maintenance")
    root = stage_config.root
    evidence = f"{root}/evidence"
    p004 = f"{evidence}/P004"
    s002 = f"{p004}/S002"
    pins: dict[str, tuple[int, int, int]] = {}
    for path, mode in ((root, 0o755), (evidence, 0o755), (p004, 0o700), (s002, 0o700)):
        info = os.lstat(path)
        if not stat.S_ISDIR(info.st_mode) or (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != (0, 0, mode):
            raise MaintenanceRefused(f"fixture H4 path metadata drift: {path}")
        pins[path] = (info.st_dev, info.st_ino, mode)
    return _RuntimeConfig(
        directories_config=stage_config,
        ancestor_pins=pins,
        code_root="/var/tmp/fixture-code-unused",
        is_fixture=True,
    )


def _fixture_baseline(
    base: str,
    publisher: ModuleType,
    payload: bytes,
    protected_sources: tuple[_Entry, ...],
    old_payload: bytes,
) -> _Baseline:
    """Capture test-only pins after constructing the matching private tree."""
    config = _fixture_config(base, publisher)
    entries: list[_Entry] = []
    for old in protected_sources:
        path = _entry_path(config, old.destination)
        parent_fd, name = _entry_parent(config, old.destination, publisher)
        try:
            raw, info = _read_file_at(parent_fd, name, label=old.destination, allowed_modes=(old.mode,), maximum=MAX_SELFTEST_BYTES)
        finally:
            os.close(parent_fd)
        entries.append(
            _Entry(
                source=old.source,
                destination=old.destination,
                dev=info.st_dev,
                inode=info.st_ino,
                uid=info.st_uid,
                gid=info.st_gid,
                mode=stat.S_IMODE(info.st_mode),
                nlink=info.st_nlink,
                size=len(raw),
                sha256=hashlib.sha256(raw).hexdigest(),
            )
        )
    target_source = next(item for item in protected_sources if item.destination == TARGET)
    target_index = next(index for index, item in enumerate(entries) if item.destination == TARGET)
    target_path = _entry_path(config, TARGET)
    target_parent_fd, target_name = _entry_parent(config, TARGET, publisher)
    try:
        old_raw, old_info = _read_file_at(target_parent_fd, target_name, label=TARGET, allowed_modes=(target_source.mode,), maximum=MAX_SELFTEST_BYTES)
    finally:
        os.close(target_parent_fd)
    if old_raw != old_payload:
        raise MaintenanceRefused("fixture old target payload mismatch")
    entries[target_index] = dataclasses.replace(
        entries[target_index],
        dev=old_info.st_dev,
        inode=old_info.st_ino,
        uid=old_info.st_uid,
        gid=old_info.st_gid,
        mode=stat.S_IMODE(old_info.st_mode),
        nlink=old_info.st_nlink,
        size=len(old_raw),
        sha256=hashlib.sha256(old_raw).hexdigest(),
    )
    prior = (
        _PriorTerminal(f"{base}/history-one/terminal.json", hashlib.sha256(b'{"status":"PROVED"}\n').hexdigest(), "PROVED"),
        _PriorTerminal(f"{base}/history-two/terminal.json", hashlib.sha256(b'{"status":"PASS_STAGED_SOURCE_ONLY"}\n').hexdigest(), "PASS_STAGED_SOURCE_ONLY"),
    )
    baseline_bytes = json.dumps(
        {"entries": [dataclasses.asdict(item) for item in entries], "payload_sha256": hashlib.sha256(payload).hexdigest(), "old_sha256": hashlib.sha256(old_payload).hexdigest()},
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return _Baseline(
        sha256=hashlib.sha256(baseline_bytes).hexdigest(),
        old_selftest_sha256=hashlib.sha256(old_payload).hexdigest(),
        target=TARGET,
        entries=tuple(entries),
        prior_terminals=prior,
        is_fixture=True,
    )


def _entry_path(config: _RuntimeConfig, destination: str) -> str:
    root = config.directories_config.root
    production_relative = PurePosixPath(destination).relative_to(PRODUCTION_ROOT)
    return str(PurePosixPath(root) / production_relative)


def _entry_parent(config: _RuntimeConfig, destination: str, publisher: ModuleType, directories: Any | None = None) -> tuple[int, str]:
    path = PurePosixPath(_entry_path(config, destination))
    parent_path = str(path.parent)
    if directories is not None:
        parent_fd = directories.hold_directory(parent_path)
        assert parent_fd is not None
        return os.dup(parent_fd), path.name
    # Fixture capture is confined to a validated private root. Walk every
    # component with O_NOFOLLOW and compare each held descriptor to its name.
    chain: dict[str, int] = {}
    try:
        parent_fd = _open_held_absolute_directory(parent_path, chain)
        fd = os.dup(parent_fd)
        return fd, path.name
    finally:
        for held in chain.values():
            os.close(held)


def _read_pinned_entry(parent_fd: int, entry: _Entry) -> tuple[bytes, dict[str, Any]]:
    name = PurePosixPath(entry.destination).name
    raw, info = _read_file_at(
        parent_fd,
        name,
        label=entry.destination,
        expected_sha256=entry.sha256,
        expected_size=entry.size,
        expected_metadata={
            "dev": entry.dev,
            "inode": entry.inode,
            "uid": entry.uid,
            "gid": entry.gid,
            "mode": entry.mode,
            "nlink": entry.nlink,
        },
        allowed_modes=(entry.mode,),
        maximum=max(entry.size, 1),
    )
    return raw, {**_metadata(info, hashlib.sha256(raw).hexdigest()), "mtime_ns": info.st_mtime_ns}


def _metadata(info: os.stat_result, digest: str) -> dict[str, Any]:
    return {
        "dev": info.st_dev,
        "inode": info.st_ino,
        "uid": info.st_uid,
        "gid": info.st_gid,
        "mode": oct(stat.S_IMODE(info.st_mode)),
        "nlink": info.st_nlink,
        "size": info.st_size,
        "mtime_ns": info.st_mtime_ns,
        "sha256": digest,
    }


def _verify_h4_pins(config: _RuntimeConfig, directories: Any, publisher: ModuleType) -> None:
    directories.revalidate()
    for path, (device, inode, mode) in config.ancestor_pins.items():
        fd = directories.hold_directory(path)
        assert fd is not None
        info = publisher._secure_directory(fd, path, exact_mode=mode)
        if (info.st_dev, info.st_ino) != (device, inode):
            raise MaintenanceRefused(f"fixed H4 ancestor identity drift: {path}")


def _verify_terminal(
    directories: Any,
    publisher: ModuleType,
    proof: _PriorTerminal,
) -> dict[str, Any]:
    parent = str(PurePosixPath(proof.path).parent)
    parent_fd = directories.hold_directory(parent)
    assert parent_fd is not None
    raw, info = _read_file_at(
        parent_fd,
        PurePosixPath(proof.path).name,
        label=proof.path,
        expected_sha256=proof.sha256,
        allowed_modes=(0o600,),
        maximum=1024 * 1024,
    )
    value = publisher._safe_json(raw, proof.path)
    if not isinstance(value, dict) or value.get("status") != proof.status:
        raise MaintenanceRefused(f"prior terminal status is not {proof.status}: {proof.path}")
    return {"path": proof.path, "sha256": proof.sha256, "status": proof.status, **_metadata(info, proof.sha256)}


def _verify_prior_terminals(config: _RuntimeConfig, baseline: _Baseline, directories: Any, publisher: ModuleType) -> list[dict[str, Any]]:
    if config.is_fixture != baseline.is_fixture:
        raise MaintenanceRefused("fixture baseline/config boundary mismatch")
    if not config.is_fixture and tuple(dataclasses.asdict(item) for item in baseline.prior_terminals) != PRIOR_TERMINALS:
        raise MaintenanceRefused("fixed prior terminal pins changed")
    return [_verify_terminal(directories, publisher, proof) for proof in baseline.prior_terminals]


def _check_fixed_target_entry(baseline: _Baseline) -> _Entry:
    if baseline.target != TARGET or len(baseline.entries) != EXPECTED_SOURCE_COUNT:
        raise MaintenanceRefused("baseline target/count drift")
    matches = [item for item in baseline.entries if item.destination == TARGET]
    if len(matches) != 1 or matches[0].sha256 != baseline.old_selftest_sha256:
        raise MaintenanceRefused("baseline does not contain exactly one pinned old selftest")
    if not baseline.is_fixture and baseline.old_selftest_sha256 != OLD_SELFTEST_SHA256:
        raise MaintenanceRefused("production old selftest hash is not the fixed baseline")
    destinations = [item.destination for item in baseline.entries]
    if len(set(destinations)) != EXPECTED_SOURCE_COUNT:
        raise MaintenanceRefused("baseline contains duplicate source destinations")
    for item in baseline.entries:
        pure = PurePosixPath(item.destination)
        if not pure.is_absolute() or str(pure) != item.destination or not item.destination.startswith(PRODUCTION_ROOT + "/"):
            raise MaintenanceRefused(f"baseline path is outside the canonical root: {item.destination}")
        if (item.uid, item.gid, item.nlink) != (0, 0, 1) or item.mode not in {0o644, 0o755}:
            raise MaintenanceRefused(f"baseline metadata contract drift: {item.destination}")
    return matches[0]


def _verify_entries(
    config: _RuntimeConfig,
    baseline: _Baseline,
    directories: Any,
    publisher: ModuleType,
    *,
    exclude_target: bool = False,
) -> dict[str, dict[str, Any]]:
    readbacks: dict[str, dict[str, Any]] = {}
    target_entry = _check_fixed_target_entry(baseline)
    for entry in baseline.entries:
        if exclude_target and entry == target_entry:
            continue
        parent_fd, name = _entry_parent(config, entry.destination, publisher, directories)
        try:
            raw, info = _read_file_at(
                parent_fd,
                name,
                label=entry.destination,
                expected_sha256=entry.sha256,
                expected_size=entry.size,
                expected_metadata={
                    "dev": entry.dev,
                    "inode": entry.inode,
                    "uid": entry.uid,
                    "gid": entry.gid,
                    "mode": entry.mode,
                    "nlink": entry.nlink,
                },
                allowed_modes=(entry.mode,),
                maximum=max(entry.size, 1),
            )
            # Keep the approved publisher readback boundary in the check path.
            verified = publisher._verify_file(parent_fd, name, raw, entry.sha256, entry.mode, entry.destination)
            if (verified["dev"], verified["inode"], verified["size"]) != (entry.dev, entry.inode, entry.size):
                raise MaintenanceRefused(f"approved readback metadata drift: {entry.destination}")
            readbacks[entry.destination] = _metadata(info, hashlib.sha256(raw).hexdigest())
        finally:
            os.close(parent_fd)
    return readbacks


def _verify_new_file(
    publisher: ModuleType,
    parent_fd: int,
    name: str,
    payload: bytes,
    digest: str,
    *,
    expected_identity: tuple[int, int] | None = None,
    label: str,
) -> dict[str, Any]:
    verified = publisher._verify_file(parent_fd, name, payload, digest, 0o644, label)
    _raw, info = _read_file_at(
        parent_fd,
        name,
        label=label,
        expected_sha256=digest,
        expected_size=len(payload),
        expected_metadata={"dev": verified["dev"], "inode": verified["inode"], "mode": 0o644, "nlink": 1},
        allowed_modes=(0o644,),
        maximum=MAX_SELFTEST_BYTES,
    )
    if (verified["uid"], verified["gid"], verified["mode"], verified["nlink"]) != (0, 0, "0o644", 1):
        raise MaintenanceRefused(f"new selftest metadata drift: {label}")
    if expected_identity is not None and (verified["dev"], verified["inode"]) != expected_identity:
        raise MaintenanceRefused(f"new selftest inode drift: {label}")
    return {**verified, "mtime_ns": info.st_mtime_ns}


class _Ledger:
    """Keep the publisher's durable writer while recording one-file semantics."""

    def __init__(self, publisher: ModuleType, directory_fd: int, attempt: str, baseline: _Baseline, payload_sha256: str) -> None:
        self._writer = publisher._Ledger(directory_fd, attempt)
        self.directory_fd = directory_fd
        self.attempt = attempt
        self.baseline = baseline
        self.payload_sha256 = payload_sha256
        self.sequence = 0
        self.failed_step: str | None = None

    def write(self, name: str, record: Mapping[str, Any]) -> None:
        old_mask = os.umask(0)
        try:
            self._writer.write(name, record)
        finally:
            os.umask(old_mask)

    def begin(self, config: _RuntimeConfig) -> None:
        self.write(
            f"run-{self.attempt}.intent.json",
            {
                "schema": "p004-runtime-selftest-maintenance-intent-v1",
                "status": "INTENT_DURABLE",
                "attempt": self.attempt,
                "operation": "single-file-runtime-selftest-maintenance",
                "target": TARGET,
                "old_selftest_sha256": self.baseline.old_selftest_sha256,
                "new_selftest_sha256": self.payload_sha256,
                "baseline_sha256": self.baseline.sha256,
                "source_entries_verified": EXPECTED_SOURCE_COUNT,
                "protected_entries": PROTECTED_SOURCE_COUNT,
                "effect_count": 2,
                "planned_effects": ["create-new-selftest-file", "renameat2-exchange-old-selftest"],
                "automatic_retry": False,
                "automatic_cleanup": False,
                "automatic_rollback": False,
                "actual_X05": "NOT_RUN",
            },
        )

    def intent(self, operation: str, target: str, sha256: str | None = None) -> int:
        self.sequence += 1
        self.write(
            f"run-{self.attempt}-step-{self.sequence:03d}.intent.json",
            {
                "schema": "p004-runtime-selftest-maintenance-step-intent-v1",
                "attempt": self.attempt,
                "sequence": self.sequence,
                "operation": operation,
                "target": target,
                "sha256": sha256,
                "status": "INTENT_DURABLE",
            },
        )
        return self.sequence

    def result(
        self,
        sequence: int,
        operation: str,
        target: str,
        status: str,
        details: Mapping[str, Any],
        error: BaseException | None = None,
    ) -> None:
        record: dict[str, Any] = {
            "schema": "p004-runtime-selftest-maintenance-step-result-v1",
            "attempt": self.attempt,
            "sequence": sequence,
            "operation": operation,
            "target": target,
            "status": status,
            "details": dict(details),
        }
        if error is not None:
            record["error"] = {"type": type(error).__name__, "message": str(error)[:500]}
        self.write(f"run-{self.attempt}-step-{sequence:03d}.result.json", record)
        if status != "PROVED":
            self.failed_step = operation

    def terminal(self, status: str, error: BaseException | None = None, details: Mapping[str, Any] | None = None) -> None:
        record: dict[str, Any] = {
            "schema": "p004-runtime-selftest-maintenance-terminal-v1",
            "attempt": self.attempt,
            "status": status,
            "failed_step": self.failed_step,
            "target": TARGET,
            "old_selftest_sha256": self.baseline.old_selftest_sha256,
            "new_selftest_sha256": self.payload_sha256,
            "baseline_sha256": self.baseline.sha256,
            "source_entries_verified": EXPECTED_SOURCE_COUNT,
            "protected_entries": PROTECTED_SOURCE_COUNT,
            "effect_count": self.sequence,
            "details": dict(details or {}),
            "automatic_retry": False,
            "automatic_cleanup": False,
            "automatic_rollback": False,
            "canonical_lock_changed": False,
            "receipt_created": False,
            "lab_mutation": False,
            "actual_X05": "NOT_RUN",
        }
        if error is not None:
            record["error"] = {"type": type(error).__name__, "message": str(error)[:500]}
        self.write(f"run-{self.attempt}.terminal.json", record)


class _EffectGuard:
    """Give the approved publisher effect wrapper stronger one-file checks."""

    def __init__(
        self,
        directories: Any,
        assets: _Assets,
        config: _RuntimeConfig,
        baseline: _Baseline,
        payload: bytes,
        payload_sha256: str,
        old_payload: bytes,
        attempt: str,
        target_parent_fd: int,
        target_name: str,
        temp_name: str,
        old_mtime_ns: int,
    ) -> None:
        self.inner = directories
        self.assets = assets
        self.runtime_config = config
        self.baseline = baseline
        self.payload = payload
        self.payload_sha256 = payload_sha256
        self.old_payload = old_payload
        self.attempt = attempt
        self.target_parent_fd = target_parent_fd
        self.target_name = target_name
        self.temp_name = temp_name
        self.old_mtime_ns = old_mtime_ns
        self.phase = "original"
        self.new_identity: tuple[int, int] | None = None
        # _effect expects the approved publisher configuration at this name.
        self.config = directories.config

    @property
    def fds(self) -> dict[str, int]:
        return self.inner.fds

    def __getattr__(self, name: str) -> Any:
        return getattr(self.inner, name)

    def revalidate(self) -> None:
        self.assets.code.revalidate()
        _verify_h4_pins(self.runtime_config, self.inner, self.assets.publisher)
        _verify_entries(self.runtime_config, self.baseline, self.inner, self.assets.publisher, exclude_target=True)
        self._verify_target_phase()
        _verify_prior_terminals(self.runtime_config, self.baseline, self.inner, self.assets.publisher)

    def _verify_target_phase(self) -> None:
        target_entry = _check_fixed_target_entry(self.baseline)
        if self.phase in {"original", "staged"}:
            _read_pinned_entry(self.target_parent_fd, target_entry)
            if self.phase == "staged":
                verified = _verify_new_file(
                    self.assets.publisher,
                    self.target_parent_fd,
                    self.temp_name,
                    self.payload,
                    self.payload_sha256,
                    expected_identity=self.new_identity,
                    label=f"{TARGET} temporary {self.temp_name}",
                )
                if self.new_identity is None:
                    self.new_identity = (verified["dev"], verified["inode"])
            return
        if self.phase != "exchanged" or self.new_identity is None:
            raise MaintenanceRefused("unknown maintenance file phase")
        _verify_new_file(
            self.assets.publisher,
            self.target_parent_fd,
            self.target_name,
            self.payload,
            self.payload_sha256,
            expected_identity=self.new_identity,
            label=TARGET,
        )
        _raw, parked = _read_pinned_entry(self.target_parent_fd, dataclasses.replace(target_entry, destination=self.temp_name))
        if parked["mtime_ns"] != self.old_mtime_ns:
            raise MaintenanceRefused("parked original mtime changed")


def _verify_before_effect(
    config: _RuntimeConfig,
    baseline: _Baseline,
    directories: Any,
    publisher: ModuleType,
) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]]]:
    _verify_h4_pins(config, directories, publisher)
    _check_fixed_target_entry(baseline)
    _verify_lock_and_markers(config, directories, publisher)
    readbacks = _verify_entries(config, baseline, directories, publisher)
    proofs = _verify_prior_terminals(config, baseline, directories, publisher)
    directories.revalidate()
    return proofs, readbacks


def _verify_lock_and_markers(config: _RuntimeConfig, directories: Any, publisher: ModuleType) -> None:
    publisher._check_lock(config.directories_config, directories)
    directories.check_markers()


def _preflight(
    assets: _Assets,
    config: _RuntimeConfig,
    baseline: _Baseline,
    payload: bytes,
    payload_sha256: str,
    attempt: str | None,
) -> tuple[Any, bytes, int, str, str, int, list[dict[str, Any]], dict[str, dict[str, Any]]]:
    if platform.system() != "Linux" or os.geteuid() != 0 or os.getegid() != 0:
        raise MaintenanceRefused("runtime selftest maintenance requires Linux with effective UID/GID 0")
    if len(payload) > MAX_SELFTEST_BYTES or hashlib.sha256(payload).hexdigest() != payload_sha256:
        raise MaintenanceRefused("reviewed runtime selftest payload hash/size mismatch")
    if not config.is_fixture and payload_sha256 != NEW_SELFTEST_SHA256:
        raise MaintenanceRefused("stdin payload does not match the fixed reviewed selftest")
    _check_fixed_target_entry(baseline)
    directories = assets.publisher._Directories(config.directories_config)
    target_parent_fd: int | None = None
    try:
        assets.code.revalidate()
        _ensure_store_absent(config, directories, assets.publisher)
        for path in (
            config.directories_config.root,
            f"{config.directories_config.root}/evidence",
            f"{config.directories_config.root}/evidence/P004/S002",
            str(PurePosixPath(TARGET).parent) if not config.is_fixture else str(PurePosixPath(_entry_path(config, TARGET)).parent),
        ):
            directories.hold_directory(path)
        _verify_h4_pins(config, directories, assets.publisher)
        _verify_lock_and_markers(config, directories, assets.publisher)
        _probe_rename_exchange(directories.fds[str(PurePosixPath(_entry_path(config, TARGET)).parent)])
        target_entry = _check_fixed_target_entry(baseline)
        _proofs, readbacks = _verify_before_effect(config, baseline, directories, assets.publisher)
        target_parent_fd, target_name = _entry_parent(config, TARGET, assets.publisher, directories)
        old_payload, old_metadata = _read_pinned_entry(target_parent_fd, target_entry)
        temp_name = f".p004-runtime-selftest-{attempt}.tmp" if attempt else ".p004-runtime-selftest-planned.tmp"
        if attempt:
            assets.publisher._ensure_absent(target_parent_fd, temp_name, f"{TARGET} temporary {temp_name}")
        assets.code.revalidate()
        _verify_h4_pins(config, directories, assets.publisher)
        _verify_lock_and_markers(config, directories, assets.publisher)
        directories.revalidate()
        return directories, old_payload, target_parent_fd, target_name, temp_name, old_metadata["mtime_ns"], _proofs, readbacks
    except BaseException:
        if target_parent_fd is not None:
            os.close(target_parent_fd)
        directories.close()
        raise


def _ensure_store_absent(config: _RuntimeConfig, directories: Any, publisher: ModuleType) -> None:
    publisher._check_store_absent(config.directories_config, directories)


def _probe_rename_exchange(directory_fd: int) -> None:
    function = getattr(ctypes.CDLL(None, use_errno=True), "renameat2", None)
    if function is None:
        raise MaintenanceRefused("libc renameat2 is required")
    function.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    function.restype = ctypes.c_int
    ctypes.set_errno(0)
    result = function(directory_fd, b"", directory_fd, b"", RENAME_EXCHANGE)
    error_number = ctypes.get_errno()
    if result == 0 or error_number != errno.ENOENT:
        raise MaintenanceRefused(f"renameat2 exchange preflight was unexpected: rc={result}, errno={error_number}")


def _rename_exchange(directory_fd: int, target_name: str, temp_name: str) -> None:
    function = getattr(ctypes.CDLL(None, use_errno=True), "renameat2", None)
    if function is None:
        raise OSError(errno.ENOSYS, "libc renameat2 is unavailable")
    function.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    function.restype = ctypes.c_int
    ctypes.set_errno(0)
    result = function(directory_fd, os.fsencode(target_name), directory_fd, os.fsencode(temp_name), RENAME_EXCHANGE)
    if result != 0:
        error_number = ctypes.get_errno() or errno.EIO
        raise OSError(error_number, os.strerror(error_number), temp_name)


def _prepare_store(config: _RuntimeConfig, directories: Any, publisher: ModuleType) -> int:
    store_path = config.directories_config.store
    parent_path = str(PurePosixPath(store_path).parent)
    parent_fd = directories.hold_directory(parent_path)
    assert parent_fd is not None
    name = PurePosixPath(store_path).name
    publisher._ensure_absent(parent_fd, name, store_path)
    old_mask = os.umask(0)
    try:
        os.mkdir(name, 0o700, dir_fd=parent_fd)
    finally:
        os.umask(old_mask)
    os.fsync(parent_fd)
    store_fd = os.open(name, DIRECTORY_FLAGS, dir_fd=parent_fd)
    try:
        info = publisher._secure_directory(store_fd, store_path, exact_mode=0o700)
        named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if (named.st_dev, named.st_ino) != (info.st_dev, info.st_ino):
            raise MaintenanceUnknown("maintenance store name changed after creation")
        directories.fds[store_path] = os.dup(store_fd)
        return store_fd
    except BaseException:
        os.close(store_fd)
        raise


def _write_new_file(
    parent_fd: int,
    name: str,
    payload: bytes,
    digest: str,
    publisher: ModuleType,
) -> dict[str, Any]:
    old_mask = os.umask(0)
    try:
        fd = os.open(name, FILE_CREATE_FLAGS, 0o644, dir_fd=parent_fd)
    finally:
        os.umask(old_mask)
    try:
        view = memoryview(payload)
        while view:
            written = os.write(fd, view)
            if written <= 0:
                raise OSError(errno.EIO, "short runtime selftest write")
            view = view[written:]
        os.fchown(fd, 0, 0)
        os.fchmod(fd, 0o644)
        os.fsync(fd)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode), info.st_nlink) != (0, 0, 0o644, 1):
            raise MaintenanceUnknown("new runtime selftest metadata drift")
    finally:
        os.close(fd)
    os.fsync(parent_fd)
    verified = publisher._verify_file(parent_fd, name, payload, digest, 0o644, name)
    return {"temporary": name, **verified}


def _verify_parked_old(
    parent_fd: int,
    name: str,
    old_entry: _Entry,
    old_payload: bytes,
    publisher: ModuleType,
    expected_mtime_ns: int,
) -> dict[str, Any]:
    verified = publisher._verify_file(parent_fd, name, old_payload, old_entry.sha256, old_entry.mode, f"parked original {name}")
    _raw, info = _read_file_at(
        parent_fd,
        name,
        label=f"parked original {name}",
        expected_sha256=old_entry.sha256,
        expected_size=old_entry.size,
        expected_metadata={"dev": old_entry.dev, "inode": old_entry.inode, "uid": old_entry.uid, "gid": old_entry.gid, "mode": old_entry.mode, "nlink": 1},
        allowed_modes=(old_entry.mode,),
        maximum=max(old_entry.size, 1),
    )
    if info.st_mtime_ns != expected_mtime_ns:
        raise MaintenanceRefused("parked original mtime changed")
    expected = (old_entry.dev, old_entry.inode, old_entry.uid, old_entry.gid, oct(old_entry.mode), old_entry.nlink, old_entry.size, old_entry.sha256)
    observed = (verified["dev"], verified["inode"], verified["uid"], verified["gid"], verified["mode"], verified["nlink"], verified["size"], verified["sha256"])
    if observed != expected:
        raise MaintenanceRefused("parked original metadata/content drift")
    return {**verified, "mtime_ns": info.st_mtime_ns}


def _run_dry_run(assets: _Assets, config: _RuntimeConfig, baseline: _Baseline, payload: bytes, payload_sha256: str, attempt: str) -> dict[str, Any]:
    _verify_transport_intent(assets, attempt, "--dry-run", payload_sha256)
    directories, old_payload, target_parent_fd, target_name, temp_name, _old_mtime_ns, proofs, readbacks = _preflight(
        assets, config, baseline, payload, payload_sha256, None
    )
    try:
        return {
            "schema": "p004-runtime-selftest-maintenance-result-v1",
            "status": "PASS_DRY_RUN",
            "attempt": attempt,
            "new_selftest_sha256": payload_sha256,
            "baseline_sha256": baseline.sha256,
            "old_selftest_sha256": baseline.old_selftest_sha256,
            "effect_count": 0,
            "planned_effect_count": 2,
            "protected_entries": PROTECTED_SOURCE_COUNT,
            "source_entries_verified": len(readbacks),
            "new_target": {"path": TARGET, "sha256": payload_sha256, "size": len(payload), "uid": 0, "gid": 0, "mode": "0o644", "nlink": 1},
            "parked_old": {"path": f"{PurePosixPath(TARGET).parent}/{temp_name}", "sha256": baseline.old_selftest_sha256, "size": len(old_payload)},
            "effects": [
                {"operation": "create-new-selftest-file", "path": f"{PurePosixPath(TARGET).parent}/{temp_name}", "exclusive": True, "mode": "0o644"},
                {"operation": "renameat2-exchange-old-selftest", "target": TARGET, "parked_old": f"{PurePosixPath(TARGET).parent}/{temp_name}", "flags": RENAME_EXCHANGE},
            ],
            "prior_terminals": proofs,
            "canonical_lock_changed": False,
            "receipt_created": False,
            "lab_mutation": False,
            "actual_X05": "NOT_RUN",
        }
    finally:
        os.close(target_parent_fd)
        directories.close()


def _verify_transport_intent(assets: _Assets, attempt: str, mode: str, payload_sha256: str) -> None:
    if not ATTEMPT_RE.fullmatch(attempt):
        raise MaintenanceRefused("transport attempt must be exactly 32 lowercase hexadecimal characters")
    suffix = "dry" if mode == "--dry-run" else "apply"
    name = f"production-maintenance-{attempt}-{suffix}.intent.json"
    raw, _info = _read_file_at(
        assets.code.directory_fd,
        name,
        label=f"{assets.code.code_root}/{name}",
        allowed_modes=(0o600,),
        maximum=1024 * 1024,
    )
    value = json.loads(raw, object_pairs_hook=_reject_duplicate_pairs)
    config = value.get("configuration") if isinstance(value, dict) else None
    if not isinstance(config, dict):
        raise MaintenanceRefused("parent remote intent lacks a configuration object")
    expected = {
        "attempt": attempt,
        "mode": mode,
        "code_root": assets.code.code_root,
        "new_selftest_sha256": payload_sha256,
        "baseline_sha256": BASELINE_SHA256,
    }
    if any(config.get(key) != item for key, item in expected.items()):
        raise MaintenanceRefused("parent remote intent does not match this fixed maintenance input")
    if value.get("automatic_retry") is not False or value.get("automatic_cleanup") is not False or value.get("automatic_rollback") is not False or value.get("actual_X05") != "NOT_RUN":
        raise MaintenanceRefused("parent remote intent does not preserve one-shot boundaries")
    assets.code.revalidate()


def _run_apply(
    assets: _Assets,
    config: _RuntimeConfig,
    baseline: _Baseline,
    payload: bytes,
    payload_sha256: str,
    attempt: str,
    *,
    hook: Callable[[str, Mapping[str, Any]], None] | None = None,
) -> dict[str, Any]:
    if not ATTEMPT_RE.fullmatch(attempt):
        raise MaintenanceRefused("attempt must be exactly 32 lowercase hexadecimal characters")
    if hook is not None and not config.is_fixture:
        raise MaintenanceRefused("production apply does not accept a test hook")
    if not config.is_fixture:
        _verify_transport_intent(assets, attempt, "--apply", payload_sha256)
    directories, old_payload, target_parent_fd, target_name, temp_name, old_mtime_ns, _proofs, _readbacks = _preflight(
        assets, config, baseline, payload, payload_sha256, attempt
    )
    store_fd: int | None = None
    ledger: _Ledger | None = None
    effect_guard: _EffectGuard | None = None
    try:
        try:
            store_fd = _prepare_store(config, directories, assets.publisher)
        except BaseException as error:
            raise MaintenanceUnknown(f"maintenance store creation is UNKNOWN and retained at {config.directories_config.store}: {error}") from error
        ledger = _Ledger(assets.publisher, store_fd, attempt, baseline, payload_sha256)
        ledger.begin(config)
        target_entry = _check_fixed_target_entry(baseline)
        effect_guard = _EffectGuard(
            directories,
            assets,
            config,
            baseline,
            payload,
            payload_sha256,
            old_payload,
            attempt,
            target_parent_fd,
            target_name,
            temp_name,
            old_mtime_ns,
        )

        def create_action() -> Mapping[str, Any]:
            _verify_before_effect(config, baseline, directories, assets.publisher)
            created = _write_new_file(target_parent_fd, temp_name, payload, payload_sha256, assets.publisher)
            effect_guard.new_identity = (created["dev"], created["inode"])
            effect_guard.phase = "staged"
            return created

        assets.publisher._effect(
            effect_guard,
            ledger,
            operation="create-new-selftest-file",
            target=f"{PurePosixPath(TARGET).parent}/{temp_name}",
            action=create_action,
            hook=hook,
            sha256=payload_sha256,
        )

        def exchange_action() -> Mapping[str, Any]:
            effect_guard.revalidate()
            _verify_lock_and_markers(config, directories, assets.publisher)
            target_current, _info = _read_pinned_entry(target_parent_fd, target_entry)
            if target_current != old_payload:
                raise MaintenanceRefused("old target bytes changed before exchange")
            _verify_new_file(
                assets.publisher,
                target_parent_fd,
                temp_name,
                payload,
                payload_sha256,
                expected_identity=effect_guard.new_identity,
                label=f"{TARGET} temporary {temp_name}",
            )
            _rename_exchange(target_parent_fd, target_name, temp_name)
            os.fsync(target_parent_fd)
            effect_guard.phase = "exchanged"
            new_target = _verify_new_file(
                assets.publisher,
                target_parent_fd,
                target_name,
                payload,
                payload_sha256,
                expected_identity=effect_guard.new_identity,
                label=TARGET,
            )
            parked_old = _verify_parked_old(target_parent_fd, temp_name, target_entry, old_payload, assets.publisher, old_mtime_ns)
            return {"new_target": new_target, "parked_old": parked_old, "exchange_flags": RENAME_EXCHANGE}

        exchange_details = assets.publisher._effect(
            effect_guard,
            ledger,
            operation="exchange-old-runtime-selftest",
            target=TARGET,
            action=exchange_action,
            hook=hook,
            sha256=payload_sha256,
        )
        _verify_h4_pins(config, directories, assets.publisher)
        protected = _verify_entries(config, baseline, directories, assets.publisher, exclude_target=True)
        proofs = _verify_prior_terminals(config, baseline, directories, assets.publisher)
        effect_guard.revalidate()
        result_details = {
            "new_target": dict(exchange_details["new_target"]),
            "parked_old": dict(exchange_details["parked_old"]),
            "protected_entries": len(protected),
            "prior_terminals": proofs,
        }
        ledger.terminal("PASS_UPDATED_RUNTIME_SELFTEST_ONLY", details=result_details)
        return {
            "schema": "p004-runtime-selftest-maintenance-result-v1",
            "status": "PASS_UPDATED_RUNTIME_SELFTEST_ONLY",
            "attempt": attempt,
            "new_selftest_sha256": payload_sha256,
            "baseline_sha256": baseline.sha256,
            "old_selftest_sha256": baseline.old_selftest_sha256,
            "effect_count": 2,
            "protected_entries": len(protected),
            "source_entries_verified": len(protected) + 1,
            "new_target": {"path": TARGET, **dict(exchange_details["new_target"])},
            "parked_old": {"path": f"{PurePosixPath(TARGET).parent}/{temp_name}", **dict(exchange_details["parked_old"])},
            "prior_terminals": proofs,
            "ledger": config.directories_config.store,
            "canonical_lock_changed": False,
            "receipt_created": False,
            "lab_mutation": False,
            "actual_X05": "NOT_RUN",
        }
    except BaseException as error:
        if ledger is not None:
            ledger.failed_step = ledger.failed_step or "preflight-or-maintenance-effect"
            try:
                ledger.terminal("UNKNOWN", error)
            except BaseException:
                pass
            raise MaintenanceUnknown(f"maintenance is UNKNOWN and retained at {config.directories_config.store}: {error}") from error
        if store_fd is not None:
            raise MaintenanceUnknown(f"maintenance is UNKNOWN and retained at {config.directories_config.store}: {error}") from error
        raise
    finally:
        os.close(target_parent_fd)
        directories.close()
        if store_fd is not None:
            try:
                os.close(store_fd)
            except OSError:
                pass


def _fixture_dry_run(
    assets: _Assets,
    config: _RuntimeConfig,
    baseline: _Baseline,
    payload: bytes,
    payload_sha256: str,
    attempt: str,
) -> dict[str, Any]:
    if not config.is_fixture or not baseline.is_fixture:
        raise MaintenanceRefused("test-only dry run requires the approved isolated fixture configuration")
    directories, old_payload, target_parent_fd, _target_name, temp_name, _old_mtime_ns, proofs, readbacks = _preflight(
        assets, config, baseline, payload, payload_sha256, None
    )
    try:
        return {
            "status": "PASS_DRY_RUN",
            "attempt": attempt,
            "new_selftest_sha256": payload_sha256,
            "baseline_sha256": baseline.sha256,
            "effect_count": 0,
            "planned_effect_count": 2,
            "protected_entries": PROTECTED_SOURCE_COUNT,
            "source_entries_verified": len(readbacks),
            "old_target_size": len(old_payload),
            "planned_temp_name": f".p004-runtime-selftest-{attempt}.tmp",
            "prior_terminals": proofs,
        }
    finally:
        os.close(target_parent_fd)
        directories.close()


def _fixture_apply(
    assets: _Assets,
    config: _RuntimeConfig,
    baseline: _Baseline,
    payload: bytes,
    payload_sha256: str,
    attempt: str,
    hook: Callable[[str, Mapping[str, Any]], None] | None = None,
) -> dict[str, Any]:
    if not config.is_fixture or not baseline.is_fixture:
        raise MaintenanceRefused("test-only apply requires the approved isolated fixture configuration")
    return _run_apply(assets, config, baseline, payload, payload_sha256, attempt, hook=hook)


def _read_stdin() -> bytes:
    raw = sys.stdin.buffer.read(MAX_SELFTEST_BYTES + 1)
    if len(raw) > MAX_SELFTEST_BYTES:
        raise MaintenanceRefused("stdin payload exceeds 512 KiB")
    return raw


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--dry-run", action="store_true", help="verify the fixed host state without writes")
    modes.add_argument("--apply", action="store_true", help="replace the single pinned runtime selftest once")
    parser.add_argument("--attempt", help="one-shot 32-character lowercase hexadecimal attempt ID")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    if args.apply and (args.attempt is None or not ATTEMPT_RE.fullmatch(args.attempt)):
        parser.error("--apply requires --attempt with exactly 32 lowercase hexadecimal characters")
    if args.dry_run and args.attempt is not None:
        parser.error("--attempt is valid only with --apply")
    if platform.system() != "Linux" or os.geteuid() != 0 or os.getegid() != 0:
        sys.stderr.write("maintenance refused: Linux effective UID/GID 0 required\n")
        return 2
    try:
        payload = _read_stdin()
        digest = hashlib.sha256(payload).hexdigest()
        if digest != NEW_SELFTEST_SHA256:
            raise MaintenanceRefused("stdin payload SHA256 does not match the fixed reviewed selftest")
        assets = _load_assets()
        try:
            config = _production_config(assets)
            # The parent transport intent carries its unique ID during dry-run;
            # it is read-only and is not exposed as a CLI override.
            if args.dry_run:
                attempt = _read_transport_attempt(assets, "--dry-run")
                result = _run_dry_run(assets, config, assets.baseline, payload, digest, attempt)
            else:
                assert args.attempt is not None
                result = _run_apply(assets, config, assets.baseline, payload, digest, args.attempt)
            sys.stdout.write(json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n")
            return 0
        finally:
            assets.close()
    except (MaintenanceRefused, MaintenanceUnknown, OSError, ValueError) as error:
        if isinstance(error, MaintenanceUnknown):
            sys.stdout.write(
                json.dumps(
                    {
                        "schema": "p004-runtime-selftest-maintenance-result-v1",
                        "status": "UNKNOWN",
                        "attempt": args.attempt,
                        "new_selftest_sha256": NEW_SELFTEST_SHA256,
                        "baseline_sha256": BASELINE_SHA256,
                        "effect_count": None,
                        "automatic_retry": False,
                        "automatic_cleanup": False,
                        "automatic_rollback": False,
                        "actual_X05": "NOT_RUN",
                        "error": {"type": type(error).__name__, "message": str(error)[:500]},
                    },
                    sort_keys=True,
                    separators=(",", ":"),
                )
                + "\n"
            )
        else:
            sys.stderr.write(f"maintenance refused: {error}\n")
        return 1 if isinstance(error, MaintenanceUnknown) else 2


def _read_transport_attempt(assets: _Assets, mode: str) -> str:
    suffix = "dry" if mode == "--dry-run" else "apply"
    prefix = "production-maintenance-"
    matches = [
        name[len(prefix) : -len(f"-{suffix}.intent.json")]
        for name in os.listdir(assets.code.directory_fd)
        if name.startswith(prefix) and name.endswith(f"-{suffix}.intent.json")
    ]
    if len(matches) != 1 or not ATTEMPT_RE.fullmatch(matches[0]):
        raise MaintenanceRefused("exactly one parent remote intent is required for the requested dry run")
    _verify_transport_intent(assets, matches[0], mode, NEW_SELFTEST_SHA256)
    return matches[0]


if __name__ == "__main__":
    raise SystemExit(main())
