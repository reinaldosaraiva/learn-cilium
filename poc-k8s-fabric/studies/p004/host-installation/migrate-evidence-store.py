#!/usr/bin/env python3
"""Prepare the canonical P004 evidence store without altering legacy data.

The production entry point is intentionally fixed to the observed host paths.
Fixture entry points are separate and reject paths outside a private /var/tmp
directory, so tests cannot redirect the production operation.
"""

from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import errno
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import stat
import sys
from dataclasses import dataclass, field
from typing import Any, Callable, Mapping


PRODUCTION_ROOT = "/opt/poc-k8s-fabric"
PRODUCTION_LOG_ROOT = "/var/lib/p004-host-installation"
PRODUCTION_LOCK = "/var/lock/labctl-mgc-m03.lock"
PRODUCTION_LOCK_FILE = "/run/lock/labctl-mgc-m03.lock"
PRODUCTION_LOCK_VAR = "/var"
PRODUCTION_LOCK_ALIAS = "/var/lock"
PRODUCTION_LOCK_RUN = "/run"
PRODUCTION_LOCK_REAL = "/run/lock"
LEGACY_RELATIVE = "agent/evidence"
ALIAS_NAME = "evidence"
STAGE_PREFIX = ".p004-evidence-stage-"
ATTEMPT_RE = re.compile(r"[0-9a-f]{32}\Z")
BASELINE_SHA256 = "477199e496d92e7aaf229fe8e72b7906b598587a3d564a4e93c65218ce0743df"
BASELINE_PATH = Path(__file__).with_name("legacy-baseline.json")
FIXTURE_PREFIX = "p004-host-installation-fixture-"
RENAME_EXCHANGE = 2

_DIRECTORY_FLAGS = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOATIME", 0)
_NOFOLLOW_FLAGS = getattr(os, "O_NOFOLLOW", 0)
_PATH_FLAGS = getattr(os, "O_PATH", os.O_RDONLY)
_ACL_XATTRS = {"system.posix_acl_access", "system.posix_acl_default"}
_PROTECTED_FIXTURE_PATHS = (
    "/opt",
    "/run/labctl",
    "/var/lib/labctl",
    "/var/lib/p004-host-installation",
    PRODUCTION_ROOT,
    PRODUCTION_LOCK,
)


class MigrationRefused(RuntimeError):
    """A fixed precondition failed before the next layout effect."""


class MigrationUnknown(RuntimeError):
    """A layout effect may have happened; the attempt must remain untouched."""


@dataclass(frozen=True)
class _Config:
    root: str
    log_root: str
    lock_path: str
    lock_var_path: str
    lock_alias_path: str
    lock_run_path: str
    lock_real_path: str
    lock_alias_target: str
    marker_paths: tuple[str, ...]
    canonical_paths: tuple[str, ...]
    fixture_base: str | None = None

    @property
    def is_fixture(self) -> bool:
        return self.fixture_base is not None


@dataclass
class _Handles:
    config: _Config
    baseline: Mapping[str, Any]
    root_parent_fd: int
    root_fd: int
    agent_fd: int
    legacy_fd: int
    alias_fd: int
    lock_parent_fd: int
    lock_fd: int
    lock_snapshot: dict[str, Any]
    lock_var_fd: int
    lock_alias_fd: int
    lock_run_fd: int
    source_snapshots: dict[str, dict[str, Any]]
    root_children: list[dict[str, Any]]
    stage_name: str | None = None
    stage_fd: int | None = None
    p004_fd: int | None = None
    s002_fd: int | None = None
    created_aliases: set[str] = field(default_factory=set)
    root_owned: bool = False
    exchanged: bool = False

    def close(self) -> None:
        for fd in (
            self.s002_fd,
            self.p004_fd,
            self.stage_fd,
            self.lock_fd,
            self.lock_parent_fd,
            self.lock_run_fd,
            self.lock_alias_fd,
            self.lock_var_fd,
            self.alias_fd,
            self.legacy_fd,
            self.agent_fd,
            self.root_fd,
            self.root_parent_fd,
        ):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass


class _Ledger:
    """Write immutable intent and result records in one private attempt."""

    def __init__(self, directory_fd: int, attempt: str, baseline_digest: str) -> None:
        self.directory_fd = directory_fd
        self.attempt = attempt
        self.baseline_digest = baseline_digest
        self.completed: list[str] = []
        self.failed_step: str | None = None
        self.exchange_result: dict[str, Any] | None = None

    def write(self, name: str, record: Mapping[str, Any]) -> None:
        if "/" in name or name in {"", ".", ".."}:
            raise ValueError("record name must be one path component")
        raw = (json.dumps(record, sort_keys=True, indent=2) + "\n").encode("utf-8")
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | _NOFOLLOW_FLAGS | getattr(os, "O_CLOEXEC", 0)
        fd = os.open(name, flags, 0o600, dir_fd=self.directory_fd)
        try:
            os.fchmod(fd, 0o600)
            view = memoryview(raw)
            while view:
                written = os.write(fd, view)
                if written <= 0:
                    raise OSError(errno.EIO, "short immutable record write")
                view = view[written:]
            os.fsync(fd)
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_gid != 0:
                raise MigrationUnknown(f"record ownership changed: {name}")
            if stat.S_IMODE(info.st_mode) != 0o600:
                raise MigrationUnknown(f"record mode changed: {name}")
            named = os.stat(name, dir_fd=self.directory_fd, follow_symlinks=False)
            if (named.st_dev, named.st_ino) != (info.st_dev, info.st_ino):
                raise MigrationUnknown(f"record name changed: {name}")
        finally:
            os.close(fd)
        os.fsync(self.directory_fd)

    def begin(self, root: str, stage_name: str) -> None:
        self.write(
            "intent.json",
            {
                "schema": "p004-evidence-migration-intent-v1",
                "status": "INTENT_DURABLE",
                "attempt": self.attempt,
                "started_utc": _now(),
                "canonical_root": root,
                "stage_name": stage_name,
                "baseline_sha256": self.baseline_digest,
                "exchange": "libc.renameat2(RENAME_EXCHANGE=2), same root dirfd",
                "rollback": "not implemented; partial and unknown effects are sticky",
                "X05": "NOT_RUN",
            },
        )

    def step_intent(self, index: int, name: str, target: str) -> None:
        self.write(
            f"step-{index:03d}-{name}.intent.json",
            {
                "schema": "p004-evidence-migration-step-intent-v1",
                "attempt": self.attempt,
                "index": index,
                "step": name,
                "target": target,
                "created_utc": _now(),
            },
        )

    def step_result(
        self,
        index: int,
        name: str,
        status: str,
        details: Mapping[str, Any],
        error: BaseException | None = None,
    ) -> None:
        record: dict[str, Any] = {
            "schema": "p004-evidence-migration-step-result-v1",
            "attempt": self.attempt,
            "index": index,
            "step": name,
            "status": status,
            "completed_utc": _now(),
            "details": dict(details),
        }
        if error is not None:
            record["error"] = _error_record(error)
        self.write(f"step-{index:03d}-{name}.result.json", record)
        if status == "PROVED":
            self.completed.append(name)
        else:
            self.failed_step = name

    def terminal(self, status: str, details: Mapping[str, Any], error: BaseException | None = None) -> None:
        record: dict[str, Any] = {
            "schema": "p004-evidence-migration-terminal-v1",
            "attempt": self.attempt,
            "status": status,
            "completed_utc": _now(),
            "completed_steps": list(self.completed),
            "failed_step": self.failed_step,
            "exchange_syscall": self.exchange_result,
            "details": dict(details),
            "automatic_retry": False,
            "automatic_cleanup": False,
            "automatic_rollback": False,
            "X05": "NOT_RUN",
        }
        if error is not None:
            record["error"] = _error_record(error)
        self.write("terminal.json", record)


def _now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="microseconds")


def _error_record(error: BaseException) -> dict[str, Any]:
    return {
        "type": type(error).__name__,
        "errno": getattr(error, "errno", None),
        "message": str(error)[:500],
    }


def _identity(info: os.stat_result) -> dict[str, Any]:
    return {
        "dev": info.st_dev,
        "inode": info.st_ino,
        "uid": info.st_uid,
        "gid": info.st_gid,
        "mode": oct(stat.S_IMODE(info.st_mode)),
        "nlink": info.st_nlink,
        "size": info.st_size,
        "mtime_ns": info.st_mtime_ns,
        "ctime_ns": info.st_ctime_ns,
        "type": _file_type(info.st_mode),
    }


def _file_type(mode: int) -> str:
    if stat.S_ISDIR(mode):
        return "dir"
    if stat.S_ISREG(mode):
        return "file"
    if stat.S_ISLNK(mode):
        return "symlink"
    return "other"


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise MigrationRefused(message)


def _open_dir_at(parent_fd: int, name: str) -> int:
    if name in {"", ".", ".."} or "/" in name:
        raise MigrationRefused(f"unsafe directory component: {name!r}")
    flags = _DIRECTORY_FLAGS | _NOFOLLOW_FLAGS
    child_fd = os.open(name, flags, dir_fd=parent_fd)
    info = os.fstat(child_fd)
    named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(named.st_mode):
        os.close(child_fd)
        raise MigrationRefused(f"directory component is not a real directory: {name}")
    if (info.st_dev, info.st_ino) != (named.st_dev, named.st_ino):
        os.close(child_fd)
        raise MigrationRefused(f"directory name changed while opening: {name}")
    return child_fd


def _open_absolute_dir(path: str) -> tuple[int, list[tuple[str, os.stat_result]]]:
    if not Path(path).is_absolute():
        raise MigrationRefused(f"path is not absolute: {path}")
    parts = Path(path).parts[1:]
    fd = os.open("/", _DIRECTORY_FLAGS | _NOFOLLOW_FLAGS)
    observations: list[tuple[str, os.stat_result]] = [("/", os.fstat(fd))]
    try:
        for part in parts:
            next_fd = _open_dir_at(fd, part)
            os.close(fd)
            fd = next_fd
            observations.append((str(Path(*Path(path).parts[: len(observations) + 1])), os.fstat(fd)))
        return fd, observations
    except BaseException:
        os.close(fd)
        raise


def _open_abs_parent(path: str) -> tuple[int, str]:
    target = Path(path)
    parent_fd, _ = _open_absolute_dir(str(target.parent))
    return parent_fd, target.name


def _lstat_absolute(path: str) -> os.stat_result | None:
    if Path(path) == Path("/"):
        fd = os.open("/", _DIRECTORY_FLAGS | _NOFOLLOW_FLAGS)
        try:
            return os.fstat(fd)
        finally:
            os.close(fd)
    try:
        parent_fd, name = _open_abs_parent(path)
    except FileNotFoundError:
        return None
    try:
        try:
            return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            return None
    finally:
        os.close(parent_fd)


def _readlink_at(parent_fd: int, name: str) -> str:
    return os.readlink(name, dir_fd=parent_fd)


def _reject_acl_fd(fd: int, label: str) -> None:
    try:
        names = set(os.listxattr(fd))
    except (TypeError, OSError) as error:
        raise MigrationRefused(f"cannot inspect ACL xattrs on {label}: {error}") from error
    present = sorted(names & _ACL_XATTRS)
    if present:
        raise MigrationRefused(f"POSIX ACL present on {label}: {', '.join(present)}")


def _verify_trusted_ancestors(config: _Config, baseline: Mapping[str, Any]) -> None:
    root = Path(config.root)
    fd = os.open("/", _DIRECTORY_FLAGS | _NOFOLLOW_FLAGS)
    root_info = os.fstat(fd)
    if root_info.st_uid != 0 or root_info.st_gid != 0 or root_info.st_mode & 0o022:
        os.close(fd)
        raise MigrationRefused("filesystem root is not root-controlled")
    try:
        _reject_acl_fd(fd, "/")
    except BaseException:
        os.close(fd)
        raise
    path_parts = root.parts[1:-1]
    try:
        for part in path_parts:
            child_fd = _open_dir_at(fd, part)
            os.close(fd)
            fd = child_fd
            current = os.fstat(fd)
            if config.is_fixture and part == "tmp" and str(root).startswith("/var/tmp/"):
                # /var/tmp is intentionally shared; the exact fixture child is private.
                if current.st_uid != 0 or current.st_gid != 0 or not stat.S_ISDIR(current.st_mode):
                    raise MigrationRefused("fixture temp parent is not a real root-owned directory")
                if not (current.st_mode & stat.S_ISVTX):
                    raise MigrationRefused("fixture temp parent lacks the sticky bit")
                _reject_acl_fd(fd, "/var/tmp")
                continue
            if current.st_uid != 0 or current.st_gid != 0 or current.st_mode & 0o022:
                raise MigrationRefused(f"untrusted ancestor component: {part}")
            _reject_acl_fd(fd, part)
    finally:
        os.close(fd)
    expected = baseline.get("initial_layout", {}).get("root_ancestors", [])
    if not config.is_fixture:
        actual: dict[str, dict[str, Any]] = {}
        for ancestor in expected:
            info = _lstat_absolute(ancestor["path"])
            _require(info is not None and stat.S_ISDIR(info.st_mode), f"missing root ancestor: {ancestor['path']}")
            current = _identity(info)
            actual[ancestor["path"]] = current
            _require(current["dev"] == ancestor["dev"] and current["inode"] == ancestor["inode"], f"root ancestor identity drift: {ancestor['path']}")
            _require(current["uid"] == 0 and current["gid"] == 0 and not (info.st_mode & 0o022), f"root ancestor ownership/mode drift: {ancestor['path']}")


def _open_relative_dir(root_fd: int, relative: str) -> int:
    fd = os.dup(root_fd)
    try:
        for part in PurePosixPath(relative).parts:
            if part in {"", ".", ".."}:
                raise MigrationRefused(f"unsafe relative path: {relative}")
            child_fd = _open_dir_at(fd, part)
            os.close(fd)
            fd = child_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def _open_symlink_at(parent_fd: int, name: str) -> int:
    if not hasattr(os, "O_PATH"):
        raise MigrationRefused("Linux O_PATH is required to retain the original evidence alias")
    flags = _PATH_FLAGS | _NOFOLLOW_FLAGS | getattr(os, "O_CLOEXEC", 0)
    fd = os.open(name, flags, dir_fd=parent_fd)
    info = os.fstat(fd)
    named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if not stat.S_ISLNK(info.st_mode) or (info.st_dev, info.st_ino) != (named.st_dev, named.st_ino):
        os.close(fd)
        raise MigrationRefused(f"expected a stable symlink: {name}")
    return fd


def _verify_route_directory(
    fd: int,
    expected: Mapping[str, Any] | None,
    label: str,
    mode: int,
) -> None:
    info = os.fstat(fd)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_gid != 0:
        raise MigrationRefused(f"fixed lock route directory is not root-owned: {label}")
    if stat.S_IMODE(info.st_mode) != mode:
        raise MigrationRefused(f"fixed lock route directory mode drift: {label}")
    if expected is not None:
        actual = _identity(info)
        for key in ("dev", "inode", "uid", "gid", "mode", "type"):
            if actual[key] != expected[key]:
                raise MigrationRefused(f"fixed lock route identity drift: {label}/{key}")
    _reject_acl_fd(fd, label)


def _verify_route_path(path: str, held_fd: int, label: str) -> None:
    named_fd, _ = _open_absolute_dir(path)
    try:
        held = os.fstat(held_fd)
        named = os.fstat(named_fd)
        if (held.st_dev, held.st_ino) != (named.st_dev, named.st_ino):
            raise MigrationRefused(f"fixed lock route pathname no longer names its held directory: {label}")
    finally:
        os.close(named_fd)


def _open_lock_route(
    config: _Config,
    expected: Mapping[str, Any] | None,
) -> tuple[int, int, int, int, dict[str, Any]]:
    expected_paths = (
        ("var_dir", config.lock_var_path),
        ("alias", config.lock_alias_path),
        ("run_dir", config.lock_run_path),
        ("run_lock_dir", config.lock_real_path),
    )
    if expected is not None:
        for key, path in expected_paths:
            if expected[key]["path"] != path:
                raise MigrationRefused(f"fixed lock route path differs from the pinned baseline: {key}")
    if Path(config.lock_alias_path).parent != Path(config.lock_var_path):
        raise MigrationRefused("fixed lock alias is outside its pinned /var directory")
    if Path(config.lock_real_path).parent != Path(config.lock_run_path):
        raise MigrationRefused("fixed lock target is outside its pinned /run directory")
    if config.lock_alias_target != config.lock_real_path:
        raise MigrationRefused("fixed lock alias target differs from the pinned real route")

    var_fd: int | None = None
    alias_fd: int | None = None
    run_fd: int | None = None
    real_fd: int | None = None
    try:
        var_fd, _ = _open_absolute_dir(config.lock_var_path)
        run_fd, _ = _open_absolute_dir(config.lock_run_path)
        real_fd, _ = _open_absolute_dir(config.lock_real_path)

        _verify_route_directory(var_fd, expected["var_dir"] if expected is not None else None, config.lock_var_path, 0o755)
        _verify_route_directory(run_fd, expected["run_dir"] if expected is not None else None, config.lock_run_path, 0o755)
        _verify_route_directory(real_fd, expected["run_lock_dir"] if expected is not None else None, config.lock_real_path, 0o1777)
        if not (os.fstat(real_fd).st_mode & stat.S_ISVTX):
            raise MigrationRefused("fixed real lock parent lacks the sticky bit")
        _verify_route_path(config.lock_var_path, var_fd, config.lock_var_path)
        _verify_route_path(config.lock_run_path, run_fd, config.lock_run_path)
        _verify_route_path(config.lock_real_path, real_fd, config.lock_real_path)

        alias_name = Path(config.lock_alias_path).name
        alias_fd = _open_symlink_at(var_fd, alias_name)
        alias_info = os.fstat(alias_fd)
        alias_named = os.stat(alias_name, dir_fd=var_fd, follow_symlinks=False)
        if not stat.S_ISLNK(alias_info.st_mode) or (alias_info.st_dev, alias_info.st_ino) != (alias_named.st_dev, alias_named.st_ino):
            raise MigrationRefused("fixed lock alias name no longer identifies its held symlink")
        if alias_info.st_uid != 0 or alias_info.st_gid != 0 or stat.S_IMODE(alias_info.st_mode) != 0o777:
            raise MigrationRefused("fixed lock alias type or owner drift")
        alias_target = _readlink_at(var_fd, alias_name)
        if alias_target != config.lock_alias_target:
            raise MigrationRefused("fixed lock alias target drift")
        alias_identity = _identity(alias_info)
        if expected is not None:
            for key in ("dev", "inode", "uid", "gid", "mode", "type"):
                if alias_identity[key] != expected["alias"][key]:
                    raise MigrationRefused(f"fixed lock alias identity drift: {key}")
        if expected is not None and alias_target != expected["alias"]["target"]:
            raise MigrationRefused("fixed lock alias target differs from the pinned baseline")

        named_real = os.stat("lock", dir_fd=run_fd, follow_symlinks=False)
        held_real = os.fstat(real_fd)
        if not stat.S_ISDIR(named_real.st_mode) or (named_real.st_dev, named_real.st_ino) != (held_real.st_dev, held_real.st_ino):
            raise MigrationRefused("fixed /run/lock name no longer identifies its held directory")
        followed_alias = os.stat(alias_name, dir_fd=var_fd, follow_symlinks=True)
        if (followed_alias.st_dev, followed_alias.st_ino) != (held_real.st_dev, held_real.st_ino):
            raise MigrationRefused("fixed lock alias no longer resolves to the pinned real directory")
        alias_after = os.stat(alias_name, dir_fd=var_fd, follow_symlinks=False)
        if (alias_after.st_dev, alias_after.st_ino) != (alias_info.st_dev, alias_info.st_ino) or _readlink_at(var_fd, alias_name) != alias_target:
            raise MigrationRefused("fixed lock alias changed while validating its route")

        route_snapshot = {
            "var_dir": {"path": config.lock_var_path, **{key: _identity(os.fstat(var_fd))[key] for key in ("dev", "inode", "uid", "gid", "mode", "type")}},
            "alias": {"path": config.lock_alias_path, **{key: alias_identity[key] for key in ("dev", "inode", "uid", "gid", "mode", "type")}, "target": alias_target},
            "run_dir": {"path": config.lock_run_path, **{key: _identity(os.fstat(run_fd))[key] for key in ("dev", "inode", "uid", "gid", "mode", "type")}},
            "run_lock_dir": {"path": config.lock_real_path, **{key: _identity(os.fstat(real_fd))[key] for key in ("dev", "inode", "uid", "gid", "mode", "type")}},
            "evidence": dict(expected.get("evidence", {})) if expected is not None else {},
        }
        return var_fd, alias_fd, run_fd, real_fd, route_snapshot
    except BaseException:
        for fd in (real_fd, run_fd, alias_fd, var_fd):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass
        raise


def _verify_lock_route(handles: _Handles) -> None:
    expected = handles.baseline["initial_layout"]["lock_route"]
    config = handles.config
    for key, path in (
        ("var_dir", config.lock_var_path),
        ("alias", config.lock_alias_path),
        ("run_dir", config.lock_run_path),
        ("run_lock_dir", config.lock_real_path),
    ):
        if expected[key]["path"] != path:
            raise MigrationRefused(f"fixed lock route path differs from the pinned baseline: {key}")
    _verify_route_directory(handles.lock_var_fd, expected["var_dir"], config.lock_var_path, 0o755)
    _verify_route_directory(handles.lock_run_fd, expected["run_dir"], config.lock_run_path, 0o755)
    _verify_route_directory(handles.lock_parent_fd, expected["run_lock_dir"], config.lock_real_path, 0o1777)
    if not (os.fstat(handles.lock_parent_fd).st_mode & stat.S_ISVTX):
        raise MigrationRefused("fixed real lock parent lacks the sticky bit")
    _verify_route_path(config.lock_var_path, handles.lock_var_fd, config.lock_var_path)
    _verify_route_path(config.lock_run_path, handles.lock_run_fd, config.lock_run_path)
    _verify_route_path(config.lock_real_path, handles.lock_parent_fd, config.lock_real_path)

    alias_name = Path(config.lock_alias_path).name
    alias_info = os.fstat(handles.lock_alias_fd)
    named_alias = os.stat(alias_name, dir_fd=handles.lock_var_fd, follow_symlinks=False)
    if not stat.S_ISLNK(named_alias.st_mode) or (alias_info.st_dev, alias_info.st_ino) != (named_alias.st_dev, named_alias.st_ino):
        raise MigrationRefused("fixed lock alias name no longer identifies its held symlink")
    if alias_info.st_uid != 0 or alias_info.st_gid != 0 or stat.S_IMODE(alias_info.st_mode) != 0o777:
        raise MigrationRefused("fixed lock alias type or owner drift")
    target = _readlink_at(handles.lock_var_fd, alias_name)
    if target != config.lock_alias_target or target != expected["alias"]["target"]:
        raise MigrationRefused("fixed lock alias target drift")
    alias_identity = _identity(alias_info)
    for key in ("dev", "inode", "uid", "gid", "mode", "type"):
        if alias_identity[key] != expected["alias"][key]:
            raise MigrationRefused(f"fixed lock alias identity drift: {key}")
    named_real = os.stat("lock", dir_fd=handles.lock_run_fd, follow_symlinks=False)
    held_real = os.fstat(handles.lock_parent_fd)
    if not stat.S_ISDIR(named_real.st_mode) or (named_real.st_dev, named_real.st_ino) != (held_real.st_dev, held_real.st_ino):
        raise MigrationRefused("fixed /run/lock name no longer identifies its held directory")
    followed_alias = os.stat(alias_name, dir_fd=handles.lock_var_fd, follow_symlinks=True)
    if (followed_alias.st_dev, followed_alias.st_ino) != (held_real.st_dev, held_real.st_ino):
        raise MigrationRefused("fixed lock alias no longer resolves to the pinned real directory")
    alias_after = os.stat(alias_name, dir_fd=handles.lock_var_fd, follow_symlinks=False)
    if (alias_after.st_dev, alias_after.st_ino) != (alias_info.st_dev, alias_info.st_ino) or _readlink_at(handles.lock_var_fd, alias_name) != target:
        raise MigrationRefused("fixed lock alias changed while validating its route")


def _open_lock(parent_fd: int, name: str) -> tuple[int, dict[str, Any]]:
    flags = os.O_RDONLY | _NOFOLLOW_FLAGS | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOATIME", 0) | getattr(os, "O_NONBLOCK", 0)
    fd = os.open(name, flags, dir_fd=parent_fd)
    try:
        info = os.fstat(fd)
        named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if not stat.S_ISREG(info.st_mode) or (info.st_dev, info.st_ino) != (named.st_dev, named.st_ino):
            raise MigrationRefused("canonical lock is not a stable regular file")
        _reject_acl_fd(fd, "canonical lock file")
        digest = _hash_fd(fd)
        snapshot = {**_identity(info), "sha256": digest}
        return fd, snapshot
    except BaseException:
        os.close(fd)
        raise


def _hash_fd(fd: int) -> str:
    before = os.fstat(fd)
    os.lseek(fd, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    while True:
        block = os.read(fd, 1024 * 1024)
        if not block:
            break
        digest.update(block)
    after = os.fstat(fd)
    if _identity(before) != _identity(after):
        raise MigrationRefused("file metadata changed while hashing")
    return digest.hexdigest()


def _path_snapshot(path: str) -> dict[str, Any]:
    parent_fd, name = _open_abs_parent(path)
    try:
        info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        result = _identity(info)
        if stat.S_ISLNK(info.st_mode):
            result["target"] = _readlink_at(parent_fd, name)
        return result
    finally:
        os.close(parent_fd)


def _path_maybe_snapshot(path: str) -> dict[str, Any] | None:
    try:
        return _path_snapshot(path)
    except FileNotFoundError:
        return None


def _assert_absent(path: str) -> None:
    info = _lstat_absolute(path)
    if info is not None:
        raise MigrationRefused(f"reserved path already exists: {path}")


def _list_children(fd: int) -> list[str]:
    return sorted(os.listdir(fd))


def _metadata_entry(relative: str, info: os.stat_result) -> dict[str, Any]:
    identity = _identity(info)
    return {
        "relative": relative,
        "type": identity["type"],
        "dev": identity["dev"],
        "inode": identity["inode"],
        "uid": identity["uid"],
        "gid": identity["gid"],
        "mode": identity["mode"],
        "nlink": identity["nlink"],
        "size": identity["size"],
        "mtime_ns": identity["mtime_ns"],
        "ctime_ns": identity["ctime_ns"],
    }


def _scan_legacy_tree(legacy_fd: int) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []

    def walk(directory_fd: int, prefix: str) -> None:
        for name in sorted(os.listdir(directory_fd)):
            if name in {".", ".."} or "/" in name:
                raise MigrationRefused(f"unsafe legacy name: {name!r}")
            relative = f"{prefix}/{name}" if prefix else name
            info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
            entries.append(_metadata_entry(relative, info))
            if stat.S_ISDIR(info.st_mode):
                child_fd = _open_dir_at(directory_fd, name)
                try:
                    _reject_acl_fd(child_fd, f"legacy directory {relative}")
                    walk(child_fd, relative)
                finally:
                    os.close(child_fd)
            elif stat.S_ISREG(info.st_mode):
                if info.st_nlink != 1:
                    raise MigrationRefused(f"hard-linked legacy file: {relative}")
            else:
                raise MigrationRefused(f"non-regular legacy object: {relative}")

    _reject_acl_fd(legacy_fd, LEGACY_RELATIVE)
    walk(legacy_fd, "")
    return sorted(entries, key=lambda item: item["relative"])


def _open_file_parent(root_fd: int, relative: str) -> tuple[int, str]:
    parts = PurePosixPath(relative).parts
    if not parts or any(part in {"", ".", ".."} for part in parts):
        raise MigrationRefused(f"unsafe file path: {relative}")
    parent_fd = os.dup(root_fd)
    try:
        for part in parts[:-1]:
            child_fd = _open_dir_at(parent_fd, part)
            os.close(parent_fd)
            parent_fd = child_fd
        return parent_fd, parts[-1]
    except BaseException:
        os.close(parent_fd)
        raise


def _hash_relative(root_fd: int, relative: str) -> str:
    parent_fd, name = _open_file_parent(root_fd, relative)
    flags = os.O_RDONLY | _NOFOLLOW_FLAGS | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOATIME", 0)
    try:
        fd = os.open(name, flags, dir_fd=parent_fd)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise MigrationRefused(f"legacy file is not an exclusive regular file: {relative}")
            return _hash_fd(fd)
        finally:
            os.close(fd)
    finally:
        os.close(parent_fd)


def _legacy_hashes(legacy_fd: int, baseline: Mapping[str, Any]) -> dict[str, str]:
    return {
        item["relative"]: _hash_relative(legacy_fd, item["relative"])
        for item in baseline["scope"]["legacy_regular_files"]
    }


def _verify_legacy(legacy_fd: int, baseline: Mapping[str, Any], hash_files: bool) -> dict[str, Any]:
    actual = _scan_legacy_tree(legacy_fd)
    expected = baseline["scope"]["legacy_metadata_entries"]
    if actual != expected:
        expected_map = {item["relative"]: item for item in expected}
        actual_map = {item["relative"]: item for item in actual}
        changed = sorted(name for name in set(expected_map) | set(actual_map) if expected_map.get(name) != actual_map.get(name))
        raise MigrationRefused(f"legacy metadata drift: {changed[:5]}")
    hashes: dict[str, str] = {}
    if hash_files:
        hashes = _legacy_hashes(legacy_fd, baseline)
        expected_hashes = {item["relative"]: item["sha256"] for item in baseline["scope"]["legacy_regular_files"]}
        if hashes != expected_hashes:
            changed = sorted(name for name in set(hashes) | set(expected_hashes) if hashes.get(name) != expected_hashes.get(name))
            raise MigrationRefused(f"legacy content drift: {changed[:5]}")
    return {"metadata_entries": len(actual), "regular_files": len(hashes) if hash_files else len(baseline["scope"]["legacy_regular_files"]), "hashes_checked": hash_files}


def _verify_consumers(root_fd: int, baseline: Mapping[str, Any]) -> dict[str, str]:
    hashes: dict[str, str] = {}
    for item in baseline["scope"]["consumer_sources"]:
        relative = item["relative"]
        parent_fd, name = _open_file_parent(root_fd, relative)
        try:
            info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != int(item["mode"], 8):
                raise MigrationRefused(f"consumer type or mode drift: {relative}")
            if info.st_uid != item["uid"] or info.st_gid != item["gid"]:
                raise MigrationRefused(f"consumer ownership drift: {relative}")
            digest = _hash_relative(root_fd, relative)
            if digest != item["sha256"]:
                raise MigrationRefused(f"consumer hash drift: {relative}")
            hashes[relative] = digest
        finally:
            os.close(parent_fd)
    return hashes


def _verify_root_children(root_fd: int, baseline: Mapping[str, Any], stage_name: str | None) -> None:
    expected_entries = baseline["scope"]["preserved_top_level_entries"]
    expected_names = {item["name"] for item in expected_entries}
    current_names = set(_list_children(root_fd))
    allowed_names = expected_names | ({stage_name} if stage_name else set())
    if current_names != allowed_names:
        raise MigrationRefused(f"bundle root entries drifted: expected {sorted(allowed_names)}, found {sorted(current_names)}")
    for expected in expected_entries:
        name = expected["name"]
        if name == ALIAS_NAME:
            continue
        info = os.stat(name, dir_fd=root_fd, follow_symlinks=False)
        actual = _identity(info)
        for key in ("dev", "inode", "uid", "gid", "mode", "type"):
            if actual[key] != expected[key]:
                raise MigrationRefused(f"bundle child identity drift: {name}/{key}")


def _verify_alias_descriptor(handles: _Handles, location: str) -> None:
    fd_info = os.fstat(handles.alias_fd)
    named = os.stat(location, dir_fd=handles.root_fd, follow_symlinks=False)
    if not stat.S_ISLNK(named.st_mode) or (fd_info.st_dev, fd_info.st_ino) != (named.st_dev, named.st_ino):
        raise MigrationRefused(f"original evidence alias identity drift at {location}")
    target = _readlink_at(handles.root_fd, location)
    expected = handles.baseline["initial_layout"]["evidence_alias"]["target"]
    if target != expected:
        raise MigrationRefused(f"original evidence alias target drift at {location}")
    if fd_info.st_uid != 0 or fd_info.st_gid != 0:
        raise MigrationRefused("original evidence alias is no longer root-owned")


def _verify_root_identity(handles: _Handles) -> None:
    expected = handles.baseline["initial_layout"]["bundle_root"]
    fd_info = os.fstat(handles.root_fd)
    named = os.stat(Path(handles.config.root).name, dir_fd=handles.root_parent_fd, follow_symlinks=False)
    if (fd_info.st_dev, fd_info.st_ino) != (expected["dev"], expected["inode"]):
        raise MigrationRefused("held bundle root inode differs from the pinned baseline")
    if (named.st_dev, named.st_ino) != (fd_info.st_dev, fd_info.st_ino):
        raise MigrationRefused("bundle root pathname no longer names the held inode")
    expected_owner = 0 if handles.root_owned else expected["uid"]
    if fd_info.st_uid != expected_owner or fd_info.st_gid != expected_owner:
        raise MigrationRefused("bundle root ownership drift")
    if stat.S_IMODE(fd_info.st_mode) != 0o755:
        raise MigrationRefused("bundle root mode drift")
    _reject_acl_fd(handles.root_fd, "bundle root")


def _verify_lock(handles: _Handles) -> None:
    _verify_lock_route(handles)
    if not handles.config.is_fixture and handles.config.lock_path != PRODUCTION_LOCK_FILE:
        raise MigrationRefused("production lock file is outside the pinned /run/lock path")
    current = os.fstat(handles.lock_fd)
    named = os.stat(Path(handles.config.lock_path).name, dir_fd=handles.lock_parent_fd, follow_symlinks=False)
    if (current.st_dev, current.st_ino) != (named.st_dev, named.st_ino):
        raise MigrationRefused("canonical lock path no longer names the held inode")
    current_snapshot = {**_identity(current), "sha256": _hash_fd(handles.lock_fd)}
    if current_snapshot != handles.lock_snapshot:
        raise MigrationRefused("canonical lock changed during migration")
    expected = handles.baseline["initial_layout"]["lock"]
    if not handles.config.is_fixture and (current.st_dev, current.st_ino) != (28, 7):
        raise MigrationRefused("canonical lock does not match the pinned dev28/inode7 identity")
    if current.st_uid != expected["uid"] or current.st_gid != expected["gid"] or stat.S_IMODE(current.st_mode) != int(expected["mode"], 8):
        raise MigrationRefused("canonical lock owner or mode differs from the pinned baseline")


def _verify_absence(config: _Config) -> None:
    for path in config.canonical_paths:
        _assert_absent(path)
    for path in config.marker_paths:
        _assert_absent(path)
    _assert_absent(str(Path(config.root) / "labctl.env"))


def _snapshot_mount_sources(config: _Config, baseline: Mapping[str, Any]) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for path in baseline["scope"]["mount_source_paths"]:
        result[path] = _path_snapshot(path)
    return result


def _verify_stable_mount_sources(handles: _Handles) -> None:
    current = _snapshot_mount_sources(handles.config, handles.baseline)
    if current != handles.source_snapshots:
        changed = sorted(path for path in set(current) | set(handles.source_snapshots) if current.get(path) != handles.source_snapshots.get(path))
        raise MigrationRefused(f"active bind-mount source identity drift: {changed[:5]}")


def _verify_current(
    handles: _Handles,
    check_hashes: bool = False,
    require_complete_stage: bool = False,
) -> dict[str, Any]:
    _verify_root_identity(handles)
    _verify_root_children(handles.root_fd, handles.baseline, handles.stage_name)
    agent_named = os.stat("agent", dir_fd=handles.root_fd, follow_symlinks=False)
    agent_held = os.fstat(handles.agent_fd)
    if (agent_named.st_dev, agent_named.st_ino) != (agent_held.st_dev, agent_held.st_ino):
        raise MigrationRefused("agent directory pathname no longer names the held inode")
    legacy_named = os.stat("evidence", dir_fd=handles.agent_fd, follow_symlinks=False)
    legacy_held = os.fstat(handles.legacy_fd)
    if (legacy_named.st_dev, legacy_named.st_ino) != (legacy_held.st_dev, legacy_held.st_ino):
        raise MigrationRefused("legacy evidence pathname no longer names the held inode")
    _reject_acl_fd(handles.agent_fd, "agent directory")
    _reject_acl_fd(handles.legacy_fd, "legacy evidence root")
    legacy = _verify_legacy(handles.legacy_fd, handles.baseline, check_hashes)
    consumers = _verify_consumers(handles.root_fd, handles.baseline)
    _verify_lock(handles)
    _verify_absence(handles.config)
    _verify_stable_mount_sources(handles)
    if handles.exchanged:
        _verify_published_aliases(handles)
    else:
        _verify_alias_descriptor(handles, ALIAS_NAME)
    if handles.stage_name is not None and not handles.exchanged:
        _verify_stage_contents(handles, require_complete=require_complete_stage)
    return {"legacy": legacy, "consumer_hashes": len(consumers), "mount_sources": len(handles.source_snapshots)}


def _verify_stage_contents(handles: _Handles, *, require_complete: bool = False) -> None:
    if handles.exchanged:
        raise MigrationRefused("staging validation requested after the exchange")
    _verify_store_contents(handles, require_complete=require_complete)


def _verify_store_contents(handles: _Handles, *, require_complete: bool = False) -> None:
    if handles.stage_fd is None or handles.stage_name is None:
        raise MigrationRefused("stage descriptor is missing")

    stage_info = os.fstat(handles.stage_fd)
    store_name = ALIAS_NAME if handles.exchanged else handles.stage_name
    stage_named = os.stat(store_name, dir_fd=handles.root_fd, follow_symlinks=False)
    if not stat.S_ISDIR(stage_info.st_mode) or (stage_info.st_dev, stage_info.st_ino) != (stage_named.st_dev, stage_named.st_ino):
        raise MigrationRefused("staging name no longer identifies its held directory")
    if stage_info.st_uid != 0 or stage_info.st_gid != 0:
        raise MigrationRefused("staging directory is not root-owned")

    stage_mode = stat.S_IMODE(stage_info.st_mode)
    complete = require_complete or handles.exchanged or stage_mode == 0o755
    if complete and stage_mode != 0o755:
        raise MigrationRefused("staging directory must be mode0755 before exchange")
    if stage_mode not in ({0o755} if complete else {0o700}):
        raise MigrationRefused("staging directory mode drift")
    _reject_acl_fd(handles.stage_fd, "staging evidence root")

    namespaces = handles.baseline["scope"]["legacy_namespaces"]
    expected_names = set(namespaces) | {"P004"} if complete else set(handles.created_aliases)
    if handles.p004_fd is not None:
        expected_names.add("P004")
    if complete and (handles.p004_fd is None or handles.s002_fd is None or handles.created_aliases != set(namespaces)):
        raise MigrationRefused("complete staged store has incomplete held descriptors or aliases")
    if set(_list_children(handles.stage_fd)) != expected_names:
        raise MigrationRefused("staging directory contents drifted")

    if handles.p004_fd is not None:
        p004_info = os.fstat(handles.p004_fd)
        p004_named = os.stat("P004", dir_fd=handles.stage_fd, follow_symlinks=False)
        if not stat.S_ISDIR(p004_info.st_mode) or (p004_info.st_dev, p004_info.st_ino) != (p004_named.st_dev, p004_named.st_ino):
            raise MigrationRefused("P004 name no longer identifies its held directory")
        if p004_info.st_uid != 0 or p004_info.st_gid != 0 or stat.S_IMODE(p004_info.st_mode) != 0o700:
            raise MigrationRefused("private P004 directory owner or mode drift")
        _reject_acl_fd(handles.p004_fd, "P004")
        expected_p004_names = {"S002"} if handles.s002_fd is not None else set()
        if set(_list_children(handles.p004_fd)) != expected_p004_names:
            raise MigrationRefused("private P004 contents drifted")

    if handles.s002_fd is not None:
        if handles.p004_fd is None:
            raise MigrationRefused("S002 descriptor exists without P004")
        s002_info = os.fstat(handles.s002_fd)
        s002_named = os.stat("S002", dir_fd=handles.p004_fd, follow_symlinks=False)
        if not stat.S_ISDIR(s002_info.st_mode) or (s002_info.st_dev, s002_info.st_ino) != (s002_named.st_dev, s002_named.st_ino):
            raise MigrationRefused("P004/S002 name no longer identifies its held directory")
        if s002_info.st_uid != 0 or s002_info.st_gid != 0 or stat.S_IMODE(s002_info.st_mode) != 0o700:
            raise MigrationRefused("private P004/S002 directory owner or mode drift")
        _reject_acl_fd(handles.s002_fd, "P004/S002")
        if _list_children(handles.s002_fd):
            raise MigrationRefused("private P004/S002 directory is not empty")

    aliases_to_check = namespaces if complete else sorted(handles.created_aliases)
    for name in aliases_to_check:
        if name not in namespaces:
            raise MigrationRefused(f"unexpected staged alias: {name}")
        alias_fd = _open_symlink_at(handles.stage_fd, name)
        try:
            alias_info = os.fstat(alias_fd)
            alias_named = os.stat(name, dir_fd=handles.stage_fd, follow_symlinks=False)
            if (alias_info.st_dev, alias_info.st_ino) != (alias_named.st_dev, alias_named.st_ino):
                raise MigrationRefused(f"staged alias name changed while opening: {name}")
            if alias_info.st_uid != 0 or alias_info.st_gid != 0 or stat.S_IMODE(alias_info.st_mode) != 0o777:
                raise MigrationRefused(f"staged alias type or owner drift: {name}")
            target = f"../agent/evidence/{name}"
            if _readlink_at(handles.stage_fd, name) != target:
                raise MigrationRefused(f"staged alias target drift: {name}")
            followed = os.stat(name, dir_fd=handles.stage_fd, follow_symlinks=True)
            legacy_named = os.stat(name, dir_fd=handles.legacy_fd, follow_symlinks=False)
            if not stat.S_ISDIR(legacy_named.st_mode) or (followed.st_dev, followed.st_ino) != (legacy_named.st_dev, legacy_named.st_ino):
                raise MigrationRefused(f"staged alias target identity drift: {name}")
            alias_after = os.stat(name, dir_fd=handles.stage_fd, follow_symlinks=False)
            if (alias_after.st_dev, alias_after.st_ino) != (alias_info.st_dev, alias_info.st_ino) or _readlink_at(handles.stage_fd, name) != target:
                raise MigrationRefused(f"staged alias changed while validating: {name}")
        finally:
            os.close(alias_fd)


def _verify_published_aliases(handles: _Handles) -> None:
    if handles.stage_fd is None or handles.p004_fd is None or handles.s002_fd is None:
        raise MigrationRefused("published store descriptors are incomplete")
    evidence_info = os.stat(ALIAS_NAME, dir_fd=handles.root_fd, follow_symlinks=False)
    stage_info = os.fstat(handles.stage_fd)
    if not stat.S_ISDIR(evidence_info.st_mode) or (evidence_info.st_dev, evidence_info.st_ino) != (stage_info.st_dev, stage_info.st_ino):
        raise MigrationRefused("canonical evidence name does not refer to the new store inode")
    park_info = os.stat(handles.stage_name or "", dir_fd=handles.root_fd, follow_symlinks=False)
    alias_info = os.fstat(handles.alias_fd)
    if not stat.S_ISLNK(park_info.st_mode) or (park_info.st_dev, park_info.st_ino) != (alias_info.st_dev, alias_info.st_ino):
        raise MigrationRefused("original evidence alias is not parked at its recorded inode")
    if _readlink_at(handles.root_fd, handles.stage_name or "") != handles.baseline["initial_layout"]["evidence_alias"]["target"]:
        raise MigrationRefused("parked legacy alias target changed")
    _verify_store_contents(handles, require_complete=True)


def _open_layout(config: _Config, baseline: Mapping[str, Any]) -> _Handles:
    _verify_trusted_ancestors(config, baseline)
    owned_fds: list[int] = []
    try:
        root_parent_fd, _root_parts = _open_absolute_dir(str(Path(config.root).parent))
        owned_fds.append(root_parent_fd)
        root_name = Path(config.root).name
        root_info = os.stat(root_name, dir_fd=root_parent_fd, follow_symlinks=False)
        if not stat.S_ISDIR(root_info.st_mode) or stat.S_ISLNK(root_info.st_mode):
            raise MigrationRefused("canonical bundle root is not a real directory")
        root_fd = _open_dir_at(root_parent_fd, root_name)
        owned_fds.append(root_fd)
        expected_root = baseline["initial_layout"]["bundle_root"]
        root_identity = _identity(os.fstat(root_fd))
        _require(root_identity["dev"] == expected_root["dev"] and root_identity["inode"] == expected_root["inode"], "canonical bundle root inode drift")
        _require(root_identity["uid"] == expected_root["uid"] and root_identity["gid"] == expected_root["gid"] and root_identity["mode"] == expected_root["mode"], "canonical bundle root initial ownership or mode drift")

        agent_fd = _open_relative_dir(root_fd, "agent")
        owned_fds.append(agent_fd)
        legacy_fd = _open_dir_at(agent_fd, "evidence")
        owned_fds.append(legacy_fd)
        expected_agent = baseline["initial_layout"]["agent_dir"]
        expected_legacy = baseline["initial_layout"]["legacy_evidence_dir"]
        for info, expected, label in ((os.fstat(agent_fd), expected_agent, "agent"), (os.fstat(legacy_fd), expected_legacy, "agent/evidence")):
            actual = _identity(info)
            for key in ("dev", "inode", "uid", "gid", "mode", "type"):
                if actual[key] != expected[key]:
                    raise MigrationRefused(f"{label} identity drift: {key}")
        alias_info = os.stat(ALIAS_NAME, dir_fd=root_fd, follow_symlinks=False)
        expected_alias = baseline["initial_layout"]["evidence_alias"]
        actual_alias = _identity(alias_info)
        if not stat.S_ISLNK(alias_info.st_mode):
            raise MigrationRefused("canonical evidence name is no longer the legacy symlink")
        for key in ("dev", "inode", "uid", "gid", "mode", "type"):
            if actual_alias[key] != expected_alias[key]:
                raise MigrationRefused(f"canonical evidence alias identity drift: {key}")
        if _readlink_at(root_fd, ALIAS_NAME) != expected_alias["target"]:
            raise MigrationRefused("canonical evidence alias target drift")
        alias_fd = _open_symlink_at(root_fd, ALIAS_NAME)
        owned_fds.append(alias_fd)

        lock_route = baseline["initial_layout"]["lock_route"]
        lock_var_fd, lock_alias_fd, lock_run_fd, lock_parent_fd, _route_snapshot = _open_lock_route(config, lock_route)
        owned_fds.extend((lock_var_fd, lock_alias_fd, lock_run_fd, lock_parent_fd))
        lock_name = Path(config.lock_path).name
        if config.lock_path != str(Path(config.lock_real_path) / lock_name):
            raise MigrationRefused("canonical lock file is outside the pinned real lock directory")
        lock_fd, lock_snapshot = _open_lock(lock_parent_fd, lock_name)
        owned_fds.append(lock_fd)
        expected_lock = baseline["initial_layout"]["lock"]
        for key in ("dev", "inode", "uid", "gid", "mode", "type"):
            if lock_snapshot[key] != expected_lock[key]:
                raise MigrationRefused(f"canonical lock identity drift: {key}")
        if not config.is_fixture and (lock_snapshot["dev"], lock_snapshot["inode"]) != (28, 7):
            raise MigrationRefused("canonical lock does not match pinned dev28/inode7")
        if lock_snapshot["uid"] != expected_lock["uid"] or lock_snapshot["gid"] != expected_lock["gid"] or lock_snapshot["mode"] != expected_lock["mode"]:
            raise MigrationRefused("canonical lock owner or mode differs from pinned baseline")
        if lock_snapshot["nlink"] != expected_lock["nlink"]:
            raise MigrationRefused("canonical lock link count differs from pinned baseline")

        root_children = baseline["scope"]["preserved_top_level_entries"]
        _verify_root_children(root_fd, baseline, None)
        _require(_list_children(root_fd) == sorted(item["name"] for item in root_children), "canonical root has unrecorded entries")
        _verify_legacy(legacy_fd, baseline, hash_files=True)
        _verify_consumers(root_fd, baseline)
        _verify_absence(config)
        source_snapshots = _snapshot_mount_sources(config, baseline)
        _reject_acl_fd(agent_fd, "agent directory")
        _reject_acl_fd(legacy_fd, "legacy evidence root")
        handles = _Handles(
            config=config,
            baseline=baseline,
            root_parent_fd=root_parent_fd,
            root_fd=root_fd,
            agent_fd=agent_fd,
            legacy_fd=legacy_fd,
            alias_fd=alias_fd,
            lock_parent_fd=lock_parent_fd,
            lock_fd=lock_fd,
            lock_snapshot=lock_snapshot,
            lock_var_fd=lock_var_fd,
            lock_alias_fd=lock_alias_fd,
            lock_run_fd=lock_run_fd,
            source_snapshots=source_snapshots,
            root_children=root_children,
        )
        _verify_root_children(root_fd, baseline, None)
        return handles
    except BaseException:
        for fd in reversed(owned_fds):
            try:
                os.close(fd)
            except OSError:
                pass
        raise


def _load_production_baseline() -> tuple[dict[str, Any], str]:
    flags = os.O_RDONLY | _NOFOLLOW_FLAGS | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOATIME", 0)
    fd = os.open(BASELINE_PATH, flags)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise MigrationRefused("legacy baseline is not a regular file")
        chunks = []
        while True:
            block = os.read(fd, 1024 * 1024)
            if not block:
                break
            chunks.append(block)
        raw = b"".join(chunks)
    finally:
        os.close(fd)
    digest = hashlib.sha256(raw).hexdigest()
    if digest != BASELINE_SHA256:
        raise MigrationRefused("legacy baseline companion SHA256 mismatch")
    baseline = json.loads(raw)
    if baseline.get("schema") != "p004-x05-legacy-baseline-v1":
        raise MigrationRefused("unexpected legacy baseline schema")
    if baseline.get("host") != "vm-cilium":
        raise MigrationRefused("legacy baseline is not pinned to vm-cilium")
    return baseline, digest


def _production_config(baseline: Mapping[str, Any]) -> _Config:
    route = baseline["initial_layout"]["lock_route"]
    fixed_paths = {
        "var_dir": PRODUCTION_LOCK_VAR,
        "alias": PRODUCTION_LOCK_ALIAS,
        "run_dir": PRODUCTION_LOCK_RUN,
        "run_lock_dir": PRODUCTION_LOCK_REAL,
    }
    for key, path in fixed_paths.items():
        if route[key]["path"] != path:
            raise MigrationRefused(f"production lock route is not the one pinned in code: {key}")
    if route["alias"]["target"] != PRODUCTION_LOCK_REAL:
        raise MigrationRefused("production lock alias target is not the fixed /run/lock route")
    if baseline["initial_layout"]["lock"]["path"] != PRODUCTION_LOCK:
        raise MigrationRefused("production lock baseline path is not the pinned /var/lock alias")
    canonical_paths = tuple(baseline["scope"]["canonical_source_paths_expected_absent"])
    if any(not path.startswith(PRODUCTION_ROOT + "/") for path in canonical_paths):
        raise MigrationRefused("canonical source baseline contains a path outside the fixed root")
    _canonical_relative_paths(canonical_paths)
    return _Config(
        root=PRODUCTION_ROOT,
        log_root=PRODUCTION_LOG_ROOT,
        lock_path=PRODUCTION_LOCK_FILE,
        lock_var_path=PRODUCTION_LOCK_VAR,
        lock_alias_path=PRODUCTION_LOCK_ALIAS,
        lock_run_path=PRODUCTION_LOCK_RUN,
        lock_real_path=PRODUCTION_LOCK_REAL,
        lock_alias_target=PRODUCTION_LOCK_REAL,
        marker_paths=("/run/labctl/mgc-m03/active", "/run/labctl/mgc-x05/active"),
        canonical_paths=canonical_paths,
    )


def _fixture_config(base: str | os.PathLike[str]) -> _Config:
    base_path = Path(os.path.abspath(os.fspath(base)))
    if base_path.parent != Path("/var/tmp") or not base_path.name.startswith(FIXTURE_PREFIX):
        raise MigrationRefused("fixture base must be a private /var/tmp/p004-host-installation-fixture-* directory")
    base_info = os.lstat(base_path)
    if not stat.S_ISDIR(base_info.st_mode) or stat.S_ISLNK(base_info.st_mode) or base_info.st_uid != 0 or stat.S_IMODE(base_info.st_mode) != 0o700:
        raise MigrationRefused("fixture base must be a root-owned mode0700 directory")
    for protected in _PROTECTED_FIXTURE_PATHS:
        protected_path = Path(protected)
        if base_path == protected_path or protected_path in base_path.parents or base_path in protected_path.parents:
            raise MigrationRefused(f"fixture path intersects protected production path: {protected}")
    root = base_path / "bundle"
    log_root = base_path / "attempts"
    lock_var = base_path / "var"
    lock_run = base_path / "run"
    lock_real = lock_run / "lock"
    baseline, _ = _load_production_baseline()
    relative_paths = _canonical_relative_paths(baseline["scope"]["canonical_source_paths_expected_absent"])
    canonical_paths = _canonical_paths_under(root, relative_paths)
    return _Config(
        root=str(root),
        log_root=str(log_root),
        lock_path=str(lock_real / Path(PRODUCTION_LOCK).name),
        lock_var_path=str(lock_var),
        lock_alias_path=str(lock_var / "lock"),
        lock_run_path=str(lock_run),
        lock_real_path=str(lock_real),
        lock_alias_target=str(lock_real),
        marker_paths=(str(base_path / "markers/mgc-m03/active"), str(base_path / "markers/mgc-x05/active")),
        canonical_paths=canonical_paths,
        fixture_base=str(base_path),
    )


def _canonical_relative_paths(production_paths: tuple[str, ...] | list[str]) -> tuple[str, ...]:
    production_root = PurePosixPath(PRODUCTION_ROOT)
    relative_paths: list[str] = []
    for path in production_paths:
        source = PurePosixPath(path)
        try:
            relative = source.relative_to(production_root)
        except ValueError as error:
            raise MigrationRefused(f"canonical source is outside the fixed production root: {path}") from error
        if not relative.parts or any(part in {"", ".", ".."} for part in relative.parts):
            raise MigrationRefused(f"canonical source has an unsafe relative path: {path}")
        relative_paths.append(str(relative))
    return tuple(relative_paths)


def _canonical_paths_under(root: str | os.PathLike[str], relative_paths: tuple[str, ...]) -> tuple[str, ...]:
    root_path = PurePosixPath(os.fspath(root))
    if not root_path.is_absolute():
        raise MigrationRefused("canonical path root must be absolute")
    paths: list[str] = []
    for relative_path in relative_paths:
        relative = PurePosixPath(relative_path)
        if relative.is_absolute() or not relative.parts or any(part in {"", ".", ".."} for part in relative.parts):
            raise MigrationRefused(f"unsafe canonical relative path: {relative_path}")
        paths.append(str(root_path.joinpath(*relative.parts)))
    return tuple(paths)


def _validate_attempt(attempt: str) -> None:
    if not ATTEMPT_RE.fullmatch(attempt):
        raise MigrationRefused("attempt must be exactly 32 lowercase hexadecimal characters")


def _secure_directory(fd: int, label: str, mode: int | None = None) -> None:
    info = os.fstat(fd)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_gid != 0:
        raise MigrationRefused(f"attempt path is not a root-owned real directory: {label}")
    if info.st_mode & 0o022:
        raise MigrationRefused(f"attempt path is group/other writable: {label}")
    if mode is not None and stat.S_IMODE(info.st_mode) != mode:
        raise MigrationRefused(f"attempt directory mode is not {oct(mode)}: {label}")
    _reject_acl_fd(fd, label)


def _secure_log_parent(config: _Config) -> tuple[int, str]:
    path = Path(config.log_root)
    parent_fd, ancestors = _open_absolute_dir(str(path.parent))
    try:
        for label, info in ancestors:
            shared_tmp = config.is_fixture and label == "/var/tmp"
            if info.st_uid != 0 or info.st_gid != 0 or (info.st_mode & 0o022 and not shared_tmp):
                raise MigrationRefused(f"unsafe attempt-log ancestor: {label}")
            if shared_tmp and not (info.st_mode & stat.S_ISVTX):
                raise MigrationRefused("/var/tmp lacks its sticky bit")
            check_fd, _ = _open_absolute_dir(label)
            try:
                _reject_acl_fd(check_fd, label)
            finally:
                os.close(check_fd)
        return parent_fd, path.name
    except BaseException:
        os.close(parent_fd)
        raise


def _guard_no_prior_attempts(config: _Config) -> None:
    parent_fd, store_name = _secure_log_parent(config)
    try:
        try:
            info = os.stat(store_name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            return
        if stat.S_ISLNK(info.st_mode):
            raise MigrationRefused("prior migration ledger path is a symlink")
        if not stat.S_ISDIR(info.st_mode):
            raise MigrationRefused("prior migration ledger path is not a directory")
        store_fd = _open_dir_at(parent_fd, store_name)
        try:
            _secure_directory(store_fd, config.log_root, 0o700)
            raise MigrationRefused("prior migration ledger exists; attempts are one-shot and have no recovery path")
        finally:
            os.close(store_fd)
    finally:
        os.close(parent_fd)


def _prepare_attempt(config: _Config, attempt: str) -> tuple[int, int, int]:
    parent_fd, store_name = _secure_log_parent(config)
    store_fd: int | None = None
    attempt_fd: int | None = None
    try:
        try:
            os.mkdir(store_name, 0o700, dir_fd=parent_fd)
        except FileExistsError as error:
            raise MigrationRefused("prior migration ledger appeared before exclusive creation") from error
        store_fd = _open_dir_at(parent_fd, store_name)
        os.fchmod(store_fd, 0o700)
        _secure_directory(store_fd, config.log_root, 0o700)
        os.fsync(parent_fd)
        try:
            os.mkdir(attempt, 0o700, dir_fd=store_fd)
        except FileExistsError as error:
            raise MigrationRefused("attempt is already present; attempts are never reused") from error
        attempt_fd = _open_dir_at(store_fd, attempt)
        os.fchmod(attempt_fd, 0o700)
        _secure_directory(attempt_fd, f"{config.log_root}/{attempt}", 0o700)
        os.fsync(store_fd)
        return parent_fd, store_fd, attempt_fd
    except BaseException:
        for fd in (attempt_fd, store_fd, parent_fd):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass
        raise


def _invoke_fault(hook: Callable[[str, Mapping[str, Any]], None] | None, event: str, context: Mapping[str, Any]) -> None:
    if hook is not None:
        hook(event, context)


def _run_step(
    handles: _Handles,
    ledger: _Ledger,
    index: int,
    name: str,
    target: str,
    action: Callable[[dict[str, Any]], None],
    verify: Callable[[], Mapping[str, Any]],
    sync_fd: int,
    hook: Callable[[str, Mapping[str, Any]], None] | None,
) -> None:
    _verify_current(handles, check_hashes=False)
    ledger.step_intent(index, name, target)
    details: dict[str, Any] = {}
    try:
        _invoke_fault(hook, f"before:{name}", {"step": name, "target": target})
        action(details)
        _invoke_fault(hook, f"after:{name}", {"step": name, "target": target, **details})
        _invoke_fault(hook, f"fsync:{name}", {"step": name, "target": target})
        os.fsync(sync_fd)
        _invoke_fault(hook, f"readback:{name}", {"step": name, "target": target})
        observed = dict(verify())
        stable = _verify_current(handles, check_hashes=False)
        details.update({"readback": observed, "stable_state": stable})
        ledger.step_result(index, name, "PROVED", details)
    except BaseException as error:
        if name == "atomic-evidence-exchange" and details:
            ledger.exchange_result = details.get("renameat2")
        try:
            ledger.step_result(index, name, "UNKNOWN", details, error)
        except BaseException:
            pass
        ledger.failed_step = name
        raise MigrationUnknown(f"step {name} has an unknown or partial effect: {error}") from error


def _mkdir_stage(handles: _Handles, name: str, details: dict[str, Any]) -> None:
    os.mkdir(name, 0o700, dir_fd=handles.root_fd)
    handles.stage_name = name
    handles.stage_fd = _open_dir_at(handles.root_fd, name)
    os.fchown(handles.stage_fd, 0, 0)
    os.fchmod(handles.stage_fd, 0o700)
    details["created"] = True


def _mkdir_p004(handles: _Handles, details: dict[str, Any]) -> None:
    if handles.stage_fd is None:
        raise MigrationRefused("staging root is not open")
    os.mkdir("P004", 0o700, dir_fd=handles.stage_fd)
    handles.p004_fd = _open_dir_at(handles.stage_fd, "P004")
    os.fchown(handles.p004_fd, 0, 0)
    os.fchmod(handles.p004_fd, 0o700)
    details["created"] = True


def _mkdir_s002(handles: _Handles, details: dict[str, Any]) -> None:
    if handles.p004_fd is None:
        raise MigrationRefused("P004 staging directory is not open")
    os.mkdir("S002", 0o700, dir_fd=handles.p004_fd)
    handles.s002_fd = _open_dir_at(handles.p004_fd, "S002")
    os.fchown(handles.s002_fd, 0, 0)
    os.fchmod(handles.s002_fd, 0o700)
    details["created"] = True


def _create_alias(handles: _Handles, name: str, details: dict[str, Any]) -> None:
    if handles.stage_fd is None:
        raise MigrationRefused("staging root is not open")
    target = f"../agent/evidence/{name}"
    os.symlink(target, name, dir_fd=handles.stage_fd)
    handles.created_aliases.add(name)
    details.update({"created": True, "target": target})


def _renameat2_exchange(handles: _Handles, details: dict[str, Any], hook: Callable[[str, Mapping[str, Any]], None] | None) -> None:
    if handles.stage_name is None:
        raise MigrationRefused("staging name is missing")
    _verify_current(handles, check_hashes=True, require_complete_stage=True)
    libc = ctypes.CDLL(None, use_errno=True)
    function = getattr(libc, "renameat2", None)
    if function is None:
        details["renameat2"] = {"rc": -1, "errno": errno.ENOSYS, "available": False, "flags": RENAME_EXCHANGE}
        raise OSError(errno.ENOSYS, "libc.renameat2 is unavailable")
    function.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    function.restype = ctypes.c_int
    ctypes.set_errno(0)
    try:
        _invoke_fault(hook, "syscall:renameat2", {"old": ALIAS_NAME, "new": handles.stage_name, "flags": RENAME_EXCHANGE})
    except OSError as error:
        details["renameat2"] = {"rc": -1, "errno": error.errno or errno.EIO, "available": True, "injected": True, "flags": RENAME_EXCHANGE}
        raise
    _verify_current(handles, check_hashes=True, require_complete_stage=True)
    rc = function(handles.root_fd, os.fsencode(ALIAS_NAME), handles.root_fd, os.fsencode(handles.stage_name), RENAME_EXCHANGE)
    call_errno = ctypes.get_errno() if rc != 0 else 0
    details["renameat2"] = {"rc": rc, "errno": call_errno, "available": True, "flags": RENAME_EXCHANGE}
    if rc != 0:
        raise OSError(call_errno, os.strerror(call_errno), handles.stage_name)
    handles.exchanged = True


def _apply_layout(
    handles: _Handles,
    ledger: _Ledger,
    hook: Callable[[str, Mapping[str, Any]], None] | None,
) -> dict[str, Any]:
    stage_name = STAGE_PREFIX + ledger.attempt
    if stage_name in _list_children(handles.root_fd):
        raise MigrationRefused("deterministic staging or parking name already exists")
    handles.stage_name = None
    step_index = 0

    def run(name: str, target: str, action: Callable[[dict[str, Any]], None], verify: Callable[[], Mapping[str, Any]], sync_fd: int) -> None:
        nonlocal step_index
        _run_step(handles, ledger, step_index, name, target, action, verify, sync_fd, hook)
        step_index += 1

    def chown_root(details: dict[str, Any]) -> None:
        os.fchown(handles.root_fd, 0, 0)
        handles.root_owned = True
        details["fchown"] = {"uid": 0, "gid": 0, "dev": os.fstat(handles.root_fd).st_dev, "inode": os.fstat(handles.root_fd).st_ino}

    run(
        "root-ownership",
        PRODUCTION_ROOT if not handles.config.is_fixture else handles.config.root,
        chown_root,
        lambda: {"uid": os.fstat(handles.root_fd).st_uid, "gid": os.fstat(handles.root_fd).st_gid, "mode": oct(stat.S_IMODE(os.fstat(handles.root_fd).st_mode)), "inode": os.fstat(handles.root_fd).st_ino},
        handles.root_fd,
    )
    _verify_current(handles, check_hashes=True)

    run(
        "stage-directory",
        stage_name,
        lambda details: _mkdir_stage(handles, stage_name, details),
        lambda: {"name": stage_name, "inode": os.fstat(handles.stage_fd).st_ino if handles.stage_fd is not None else None, "mode": oct(stat.S_IMODE(os.fstat(handles.stage_fd).st_mode)) if handles.stage_fd is not None else None},
        handles.root_fd,
    )
    run(
        "P004-directory",
        f"{stage_name}/P004",
        lambda details: _mkdir_p004(handles, details),
        lambda: {"inode": os.fstat(handles.p004_fd).st_ino if handles.p004_fd is not None else None, "mode": oct(stat.S_IMODE(os.fstat(handles.p004_fd).st_mode)) if handles.p004_fd is not None else None},
        handles.stage_fd if handles.stage_fd is not None else handles.root_fd,
    )
    run(
        "S002-directory",
        f"{stage_name}/P004/S002",
        lambda details: _mkdir_s002(handles, details),
        lambda: {"inode": os.fstat(handles.s002_fd).st_ino if handles.s002_fd is not None else None, "mode": oct(stat.S_IMODE(os.fstat(handles.s002_fd).st_mode)) if handles.s002_fd is not None else None},
        handles.p004_fd if handles.p004_fd is not None else handles.root_fd,
    )

    names = handles.baseline["scope"]["legacy_namespaces"]
    for namespace in names:
        run(
            f"alias-{namespace}",
            f"{stage_name}/{namespace}",
            lambda details, current=namespace: _create_alias(handles, current, details),
            lambda current=namespace: {"target": _readlink_at(handles.stage_fd, current) if handles.stage_fd is not None else None, "legacy_inode": os.stat(current, dir_fd=handles.legacy_fd, follow_symlinks=False).st_ino},
            handles.stage_fd if handles.stage_fd is not None else handles.root_fd,
        )

    def publish_stage_mode(details: dict[str, Any]) -> None:
        if handles.stage_fd is None:
            raise MigrationRefused("staging root is not open")
        os.fchmod(handles.stage_fd, 0o755)
        details["mode"] = "0o755"

    run(
        "publish-stage-mode",
        stage_name,
        publish_stage_mode,
        lambda: {"uid": os.fstat(handles.stage_fd).st_uid if handles.stage_fd is not None else None, "gid": os.fstat(handles.stage_fd).st_gid if handles.stage_fd is not None else None, "mode": oct(stat.S_IMODE(os.fstat(handles.stage_fd).st_mode)) if handles.stage_fd is not None else None},
        handles.stage_fd if handles.stage_fd is not None else handles.root_fd,
    )

    _verify_current(handles, check_hashes=True)
    run(
        "atomic-evidence-exchange",
        f"{ALIAS_NAME}<->{stage_name}",
        lambda details: _renameat2_exchange(handles, details, hook),
        lambda: _published_readback(handles),
        handles.root_fd,
    )
    ledger.exchange_result = ledger.exchange_result or {"rc": 0, "errno": 0, "available": True, "flags": RENAME_EXCHANGE}
    final = _verify_current(handles, check_hashes=True)
    return {
        "status": "PROVED",
        "root": {"dev": os.fstat(handles.root_fd).st_dev, "inode": os.fstat(handles.root_fd).st_ino, "uid": os.fstat(handles.root_fd).st_uid, "gid": os.fstat(handles.root_fd).st_gid, "mode": oct(stat.S_IMODE(os.fstat(handles.root_fd).st_mode))},
        "evidence": {"dev": os.fstat(handles.stage_fd).st_dev, "inode": os.fstat(handles.stage_fd).st_ino, "uid": os.fstat(handles.stage_fd).st_uid, "gid": os.fstat(handles.stage_fd).st_gid, "mode": oct(stat.S_IMODE(os.fstat(handles.stage_fd).st_mode))},
        "parked_alias": {"name": stage_name, "dev": os.fstat(handles.alias_fd).st_dev, "inode": os.fstat(handles.alias_fd).st_ino, "target": _readlink_at(handles.root_fd, stage_name)},
        "legacy": final["legacy"],
        "mount_sources": len(handles.source_snapshots),
        "lock": {key: handles.lock_snapshot[key] for key in ("dev", "inode", "uid", "gid", "mode", "sha256")},
    }


def _published_readback(handles: _Handles) -> dict[str, Any]:
    _verify_published_aliases(handles)
    if handles.stage_name is None:
        raise MigrationRefused("staging/parking name is missing")
    return {
        "canonical_evidence_inode": os.stat(ALIAS_NAME, dir_fd=handles.root_fd, follow_symlinks=False).st_ino,
        "parked_alias_inode": os.stat(handles.stage_name, dir_fd=handles.root_fd, follow_symlinks=False).st_ino,
        "aliases": len(handles.baseline["scope"]["legacy_namespaces"]),
        "exchange_syscall": "renameat2(RENAME_EXCHANGE)",
    }


def _make_attempt_directory(config: _Config, attempt: str) -> tuple[int, int, int]:
    return _prepare_attempt(config, attempt)


def _run_apply(
    config: _Config,
    baseline: Mapping[str, Any],
    baseline_digest: str,
    attempt: str,
    hook: Callable[[str, Mapping[str, Any]], None] | None = None,
) -> dict[str, Any]:
    _validate_attempt(attempt)
    if not config.is_fixture:
        if platform.system() != "Linux":
            raise MigrationRefused("real apply requires Linux")
        if os.geteuid() != 0:
            raise MigrationRefused("real apply requires effective UID 0")
        if hook is not None:
            raise MigrationRefused("production apply does not accept a test hook")
    elif os.geteuid() != 0:
        raise MigrationRefused("fixture apply requires root for realistic UID ownership checks")
    _guard_no_prior_attempts(config)

    handles = _open_layout(config, baseline)
    log_parent_fd: int | None = None
    store_fd: int | None = None
    attempt_fd: int | None = None
    ledger: _Ledger | None = None
    try:
        _verify_current(handles, check_hashes=True)
        log_parent_fd, store_fd, attempt_fd = _make_attempt_directory(config, attempt)
        ledger = _Ledger(attempt_fd, attempt, baseline_digest)
        stage_name = STAGE_PREFIX + attempt
        ledger.begin(config.root, stage_name)
        try:
            result = _apply_layout(handles, ledger, hook)
            ledger.terminal("PROVED", result)
            return {**result, "attempt": attempt, "attempt_directory": f"{config.log_root}/{attempt}"}
        except BaseException as error:
            ledger.failed_step = ledger.failed_step or "pre-effect-or-layout-step"
            try:
                state = _safe_terminal_state(handles)
                ledger.terminal("UNKNOWN", state, error)
            except BaseException:
                pass
            return {
                "status": "UNKNOWN",
                "attempt": attempt,
                "attempt_directory": f"{config.log_root}/{attempt}",
                "failed_step": ledger.failed_step,
                "exchange_syscall": ledger.exchange_result,
                "error": _error_record(error),
                "automatic_retry": False,
                "automatic_cleanup": False,
                "automatic_rollback": False,
                "X05": "NOT_RUN",
            }
    finally:
        handles.close()
        for fd in (attempt_fd, store_fd, log_parent_fd):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass


def _safe_terminal_state(handles: _Handles) -> dict[str, Any]:
    state: dict[str, Any] = {"root_owned": handles.root_owned, "exchanged": handles.exchanged, "stage_name": handles.stage_name}
    try:
        state["root"] = _identity(os.fstat(handles.root_fd))
    except OSError as error:
        state["root_readback_error"] = _error_record(error)
    if handles.stage_name is not None:
        try:
            info = os.stat(handles.stage_name, dir_fd=handles.root_fd, follow_symlinks=False)
            state["stage_or_park"] = _identity(info)
            if stat.S_ISLNK(info.st_mode):
                state["stage_or_park"]["target"] = _readlink_at(handles.root_fd, handles.stage_name)
        except OSError as error:
            state["stage_or_park_error"] = _error_record(error)
    try:
        info = os.stat(ALIAS_NAME, dir_fd=handles.root_fd, follow_symlinks=False)
        state["canonical_evidence"] = _identity(info)
        if stat.S_ISLNK(info.st_mode):
            state["canonical_evidence"]["target"] = _readlink_at(handles.root_fd, ALIAS_NAME)
    except OSError as error:
        state["canonical_evidence_error"] = _error_record(error)
    return state


def _dry_run(config: _Config, baseline: Mapping[str, Any], baseline_digest: str) -> dict[str, Any]:
    if not config.is_fixture and platform.system() != "Linux":
        raise MigrationRefused("production dry-run requires Linux to inspect O_PATH, ACL, and renameat2 readiness")
    _guard_no_prior_attempts(config)
    handles = _open_layout(config, baseline)
    try:
        state = _verify_current(handles, check_hashes=True)
        return {
            "status": "READY_FOR_REVIEWED_APPLY",
            "mode": "DRY_RUN_ZERO_WRITES",
            "root": config.root,
            "root_identity": _identity(os.fstat(handles.root_fd)),
            "baseline_sha256": baseline_digest,
            "preserved_entries": state["legacy"]["metadata_entries"],
            "preserved_files": state["legacy"]["regular_files"],
            "aliases": len(baseline["scope"]["legacy_namespaces"]),
            "effects": _planned_effects(baseline),
            "X05": "NOT_RUN",
        }
    finally:
        handles.close()


def _planned_effects(baseline: Mapping[str, Any]) -> list[str]:
    names = baseline["scope"]["legacy_namespaces"]
    return [
        "fchown the same canonical root inode to root:root (mode remains 0755)",
        "create a private same-root evidence directory, P004/S002, and exactly 19 relative aliases",
        "atomically exchange root/evidence and the staged directory using renameat2(RENAME_EXCHANGE=2)",
        f"retain the original evidence symlink at {STAGE_PREFIX}<attempt>",
        f"verify legacy namespaces: {', '.join(names)}",
    ]


def capture_fixture_baseline(base: str | os.PathLike[str]) -> dict[str, Any]:
    """Capture a baseline only for an isolated root-owned /var/tmp fixture."""
    config = _fixture_config(base)
    production_baseline, _ = _load_production_baseline()
    root_parent_fd, _ = _open_absolute_dir(str(Path(config.root).parent))
    try:
        root_fd = _open_dir_at(root_parent_fd, Path(config.root).name)
    finally:
        os.close(root_parent_fd)
    try:
        agent_fd = _open_relative_dir(root_fd, "agent")
        legacy_fd = _open_dir_at(agent_fd, "evidence")
        alias = os.stat(ALIAS_NAME, dir_fd=root_fd, follow_symlinks=False)
        if not stat.S_ISLNK(alias.st_mode) or _readlink_at(root_fd, ALIAS_NAME) != "agent/evidence":
            raise MigrationRefused("fixture must start with the original relative evidence alias")
        metadata = _scan_legacy_tree(legacy_fd)
        if [item["relative"] for item in metadata if item["type"] == "dir" and "/" not in item["relative"]] != production_baseline["scope"]["legacy_namespaces"]:
            raise MigrationRefused("fixture must contain the exact 19 legacy namespace names")
        regular = [item for item in metadata if item["type"] == "file"]
        file_records = []
        for item in regular:
            file_records.append({**item, "sha256": _hash_relative(legacy_fd, item["relative"])})
        consumers = []
        for relative in ("agent/harness.py", "agent/spec/steps.yaml", "agent/README.md"):
            parent_fd, name = _open_file_parent(root_fd, relative)
            try:
                info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
                if not stat.S_ISREG(info.st_mode):
                    raise MigrationRefused(f"fixture consumer is not a regular file: {relative}")
                consumers.append({"relative": relative, "uid": info.st_uid, "gid": info.st_gid, "mode": oct(stat.S_IMODE(info.st_mode)), "sha256": _hash_relative(root_fd, relative)})
            finally:
                os.close(parent_fd)
        lock_path = config.lock_path
        route = production_baseline["initial_layout"]["lock_route"]
        lock_var_fd, lock_alias_fd, lock_run_fd, lock_parent_fd, route_snapshot = _open_lock_route(config, None)
        try:
            route_snapshot["evidence"] = dict(route["evidence"])
            lock_name = Path(lock_path).name
            lock_info = os.stat(lock_name, dir_fd=lock_parent_fd, follow_symlinks=False)
            if not stat.S_ISREG(lock_info.st_mode):
                raise MigrationRefused("fixture lock is not a regular file")
            lock = {**_identity(lock_info), "path": lock_path}
        finally:
            os.close(lock_alias_fd)
            os.close(lock_var_fd)
            os.close(lock_run_fd)
            os.close(lock_parent_fd)
        root_children = []
        for name in _list_children(root_fd):
            info = os.stat(name, dir_fd=root_fd, follow_symlinks=False)
            current = _identity(info)
            root_children.append({"name": name, "type": current["type"], "dev": current["dev"], "inode": current["inode"], "uid": current["uid"], "gid": current["gid"], "mode": current["mode"]})
        mount_paths = [str(Path(config.root) / item) for item in ("docs/04-cenario-c-evpn-vxlan.md", "configs/frr/daemons", "topo/clab-poc-k8s-kind/leaf1/topology.yml")]
        for path in mount_paths:
            if _path_maybe_snapshot(path) is None:
                raise MigrationRefused(f"fixture source path is missing: {path}")
        expected_root = _identity(os.fstat(root_fd))
        expected_agent = _identity(os.stat("agent", dir_fd=root_fd, follow_symlinks=False))
        expected_legacy = _identity(os.fstat(legacy_fd))
        expected_alias = {**_identity(alias), "target": _readlink_at(root_fd, ALIAS_NAME)}
        initial = {
            "root_ancestors": [],
            "bundle_root": {"path": config.root, **{key: expected_root[key] for key in ("dev", "inode", "uid", "gid", "mode", "type")}},
            "agent_dir": {"path": str(Path(config.root) / "agent"), **{key: expected_agent[key] for key in ("dev", "inode", "uid", "gid", "mode", "type")}},
            "legacy_evidence_dir": {"path": str(Path(config.root) / LEGACY_RELATIVE), **{key: expected_legacy[key] for key in ("dev", "inode", "uid", "gid", "mode", "type")}},
            "evidence_alias": {"path": str(Path(config.root) / ALIAS_NAME), **{key: expected_alias[key] for key in ("dev", "inode", "uid", "gid", "mode", "type", "target")}},
            "lock": lock,
            "lock_route": route_snapshot,
        }
        relative_paths = _canonical_relative_paths(production_baseline["scope"]["canonical_source_paths_expected_absent"])
        canonical_paths = list(_canonical_paths_under(config.root, relative_paths))
        fixture = {
            "schema": "p004-x05-fixture-baseline-v1",
            "host": "isolated-fixture",
            "initial_layout": initial,
            "scope": {
                "legacy_namespaces": production_baseline["scope"]["legacy_namespaces"],
                "legacy_metadata_entries": metadata,
                "legacy_regular_files": file_records,
                "legacy_regular_file_count": len(file_records),
                "consumer_sources": sorted(consumers, key=lambda item: item["relative"]),
                "preserved_top_level_entries": root_children,
                "canonical_source_paths_expected_absent": canonical_paths,
                "mount_source_paths": mount_paths,
            },
        }
        return fixture
    finally:
        os.close(legacy_fd)
        os.close(agent_fd)
        os.close(root_fd)


def fixture_dry_run(base: str | os.PathLike[str], baseline: Mapping[str, Any]) -> dict[str, Any]:
    """Run the read-only planner against a validated isolated fixture."""
    config = _fixture_config(base)
    digest = hashlib.sha256(json.dumps(baseline, sort_keys=True).encode("utf-8")).hexdigest()
    return _dry_run(config, baseline, digest)


def fixture_apply(
    base: str | os.PathLike[str],
    attempt: str,
    baseline: Mapping[str, Any],
    fault_hook: Callable[[str, Mapping[str, Any]], None] | None = None,
) -> dict[str, Any]:
    """Apply only to a validated private fixture; never uses production paths."""
    config = _fixture_config(base)
    digest = hashlib.sha256(json.dumps(baseline, sort_keys=True).encode("utf-8")).hexdigest()
    return _run_apply(config, baseline, digest, attempt, fault_hook)


def fixture_verify_published(base: str | os.PathLike[str], baseline: Mapping[str, Any], attempt: str) -> dict[str, Any]:
    """Read back the fixture publication and refuse unregistered legacy names."""
    _validate_attempt(attempt)
    config = _fixture_config(base)
    root_parent_fd, _ = _open_absolute_dir(str(Path(config.root).parent))
    root_fd = _open_dir_at(root_parent_fd, Path(config.root).name)
    try:
        agent_fd = _open_relative_dir(root_fd, "agent")
        legacy_fd = _open_dir_at(agent_fd, "evidence")
        stage_name = STAGE_PREFIX + attempt
        park_info = os.stat(stage_name, dir_fd=root_fd, follow_symlinks=False)
        alias_target = _readlink_at(root_fd, stage_name)
        if not stat.S_ISLNK(park_info.st_mode) or alias_target != "agent/evidence":
            raise MigrationRefused("fixture legacy alias is not parked at its deterministic name")
        evidence_fd = _open_dir_at(root_fd, ALIAS_NAME)
        try:
            expected = set(baseline["scope"]["legacy_namespaces"]) | {"P004"}
            if set(_list_children(evidence_fd)) != expected:
                raise MigrationRefused("fixture canonical namespace set is missing or unregistered")
            actual = _scan_legacy_tree(legacy_fd)
            if actual != baseline["scope"]["legacy_metadata_entries"]:
                raise MigrationRefused("fixture legacy namespace or data metadata is unregistered")
            for name in baseline["scope"]["legacy_namespaces"]:
                info = os.stat(name, dir_fd=evidence_fd, follow_symlinks=False)
                if not stat.S_ISLNK(info.st_mode) or _readlink_at(evidence_fd, name) != f"../agent/evidence/{name}":
                    raise MigrationRefused(f"fixture canonical alias is missing or malformed: {name}")
                followed = os.stat(name, dir_fd=evidence_fd, follow_symlinks=True)
                source = os.stat(name, dir_fd=legacy_fd, follow_symlinks=False)
                if (followed.st_dev, followed.st_ino) != (source.st_dev, source.st_ino):
                    raise MigrationRefused(f"fixture alias points to a different namespace: {name}")
            hashes = _legacy_hashes(legacy_fd, baseline)
            expected_hashes = {item["relative"]: item["sha256"] for item in baseline["scope"]["legacy_regular_files"]}
            if hashes != expected_hashes:
                raise MigrationRefused("fixture legacy file content changed")
            return {"status": "PROVED", "aliases": len(baseline["scope"]["legacy_namespaces"]), "files": len(hashes), "parked_alias_inode": park_info.st_ino}
        finally:
            os.close(evidence_fd)
            os.close(legacy_fd)
            os.close(agent_fd)
    finally:
        os.close(root_fd)
        os.close(root_parent_fd)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--dry-run", action="store_true", help="print the fixed production plan without writes")
    modes.add_argument("--apply", action="store_true", help="perform the one-shot fixed-path migration as Linux root")
    parser.add_argument("--attempt", help="required 32-character lowercase hex ID for --apply")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    if args.dry_run and args.attempt is not None:
        parser.error("--attempt is valid only with --apply")
    if args.apply and args.attempt is None:
        parser.error("--apply requires --attempt HEX")
    if args.attempt is not None:
        try:
            _validate_attempt(args.attempt)
        except MigrationRefused as error:
            parser.error(str(error))
    try:
        baseline, digest = _load_production_baseline()
        config = _production_config(baseline)
        if args.dry_run:
            result = _dry_run(config, baseline, digest)
        else:
            result = _run_apply(config, baseline, digest, args.attempt)
        print(json.dumps(result, sort_keys=True, indent=2))
        return 0 if result["status"] in {"PROVED", "READY_FOR_REVIEWED_APPLY"} else 3
    except (MigrationRefused, OSError, ValueError, json.JSONDecodeError) as error:
        print(json.dumps({"status": "REFUSED", "reason": _error_record(error), "X05": "NOT_RUN"}, sort_keys=True), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
