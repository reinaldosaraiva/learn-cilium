#!/usr/bin/env python3
"""Publish the pinned X05 source bundle into the H4 canonical tree.

The production command accepts only the fixed H4 host layout and one approved
70-source archive on stdin.  It stages 58 source files; 12 historical evidence
files are validated and deliberately left out.  A partial run is permanent
UNKNOWN state: the ledger, temporary files, created directories, and published
files are retained without retry or rollback.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import stat
import sys
import tarfile
from dataclasses import dataclass
from typing import Any, Callable, Mapping


PRODUCTION_ROOT = "/opt/poc-k8s-fabric"
PRODUCTION_STORE = "/var/lib/p004-reviewed-source-stage"
PRODUCTION_LOCK = "/run/lock/labctl-dci-m03.lock"
PRODUCTION_MARKERS = (
    "/run/labctl/dci-m03/active",
    "/run/labctl/dci-x05/active",
)
APPROVED_ARCHIVE_SHA256 = "c574f03de2035dcfb7626afb281520215e732963615dd400197396c777f9398d"
APPROVED_MANIFEST_SHA256 = "558647b45997a2f81f1f55b185da503c57c41ddd8c6df8cfb77e10fcd353fa79"
MAX_ARCHIVE_BYTES = 16 * 1024 * 1024
MAX_MEMBER_BYTES = 8 * 1024 * 1024
MAX_TOTAL_MEMBER_BYTES = 16 * 1024 * 1024
EXPECTED_SOURCE_COUNT = 70
EXPECTED_PUBLISH_COUNT = 58
EXPECTED_HISTORICAL_COUNT = 12
ATTEMPT_RE = re.compile(r"[0-9a-f]{32}\Z")
ACL_XATTRS = {"system.posix_acl_access", "system.posix_acl_default"}
RENAME_NOREPLACE = 1
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
FILE_READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | getattr(os, "O_NOATIME", 0)
FILE_CREATE_FLAGS = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC


class StageRefused(RuntimeError):
    """A fixed precondition failed before this attempt could continue."""


class StageUnknown(RuntimeError):
    """An effect may have happened; the one-shot attempt must remain retained."""


@dataclass(frozen=True)
class _Config:
    root: str
    store: str
    markers: tuple[str, str]
    lock_path: str
    lock_identity: tuple[int, int]
    lock_sha256: str
    archive_sha256: str
    manifest_sha256: str
    root_identity: tuple[int, int]
    evidence_identity: tuple[int, int]
    fixture_base: str | None = None

    @property
    def is_fixture(self) -> bool:
        return self.fixture_base is not None


@dataclass(frozen=True)
class _Bundle:
    archive_sha256: str
    manifest_sha256: str
    publish: Mapping[str, tuple[str, bytes, str]]
    historical: tuple[str, ...]


def _production_config() -> _Config:
    return _Config(
        root=PRODUCTION_ROOT,
        store=PRODUCTION_STORE,
        markers=PRODUCTION_MARKERS,
        lock_path=PRODUCTION_LOCK,
        lock_identity=(28, 7),
        lock_sha256="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        archive_sha256=APPROVED_ARCHIVE_SHA256,
        manifest_sha256=APPROVED_MANIFEST_SHA256,
        root_identity=(64769, 262224),
        evidence_identity=(64769, 3742352),
    )


def _fixture_config(
    base: str,
    *,
    archive_sha256: str,
    manifest_sha256: str,
) -> _Config:
    """Create the only path-override configuration, under a private fixture."""
    if platform.system() != "Linux" or os.geteuid() != 0:
        raise StageRefused("fixture execution requires Linux and effective UID 0")
    fixture = Path(base)
    if not fixture.is_absolute() or not fixture.name.startswith("p004-reviewed-source-stage-fixture-"):
        raise StageRefused("fixture base must be a named child of /var/tmp")
    if fixture.parent != Path("/var/tmp"):
        raise StageRefused("fixture base must be directly beneath /var/tmp")
    _require_private_fixture_base(str(fixture))
    root = fixture / "root"
    evidence = root / "evidence"
    s002 = evidence / "P004" / "S002"
    markers_dir = fixture / "markers"
    markers = (str(markers_dir / "dci-m03-active"), str(markers_dir / "dci-x05-active"))
    lock_path = fixture / "lock"
    for path in (root, evidence, s002, markers_dir):
        info = os.lstat(path)
        if not stat.S_ISDIR(info.st_mode):
            raise StageRefused(f"fixture directory is not a real directory: {path}")
    root_info = os.lstat(root)
    evidence_info = os.lstat(evidence)
    lock_fd = os.open(lock_path, FILE_READ_FLAGS)
    try:
        lock_info = os.fstat(lock_fd)
        if not stat.S_ISREG(lock_info.st_mode) or (lock_info.st_uid, lock_info.st_gid, stat.S_IMODE(lock_info.st_mode), lock_info.st_nlink) != (0, 0, 0o600, 1):
            raise StageRefused("fixture lock must be a root-owned mode 0600 regular file")
        lock_sha256 = _digest_fd(lock_fd)
    finally:
        os.close(lock_fd)
    return _Config(
        root=str(root),
        store=str(fixture / "ledger"),
        markers=markers,
        lock_path=str(lock_path),
        lock_identity=(lock_info.st_dev, lock_info.st_ino),
        lock_sha256=lock_sha256,
        archive_sha256=archive_sha256,
        manifest_sha256=manifest_sha256,
        root_identity=(root_info.st_dev, root_info.st_ino),
        evidence_identity=(evidence_info.st_dev, evidence_info.st_ino),
        fixture_base=str(fixture),
    )


def _require_private_fixture_base(path: str) -> None:
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise StageRefused("fixture base is not a real directory")
    if (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != (0, 0, 0o700):
        raise StageRefused("fixture base must be root-owned mode 0700")
    _reject_acl_path(path, "fixture base")


def _reject_acl_fd(fd: int, label: str) -> None:
    try:
        names = set(os.listxattr(fd))
    except (OSError, TypeError) as error:
        raise StageRefused(f"cannot inspect ACLs on {label}: {error}") from error
    present = sorted(names & ACL_XATTRS)
    if present:
        raise StageRefused(f"POSIX ACL present on {label}: {', '.join(present)}")


def _reject_acl_path(path: str, label: str) -> None:
    fd = os.open(path, DIRECTORY_FLAGS)
    try:
        _reject_acl_fd(fd, label)
    finally:
        os.close(fd)


def _secure_directory(fd: int, label: str, *, exact_mode: int | None = None) -> os.stat_result:
    info = os.fstat(fd)
    if not stat.S_ISDIR(info.st_mode) or (info.st_uid, info.st_gid) != (0, 0):
        raise StageRefused(f"directory is not root-owned: {label}")
    if info.st_mode & 0o022:
        raise StageRefused(f"directory is group/other writable: {label}")
    if exact_mode is not None and stat.S_IMODE(info.st_mode) != exact_mode:
        raise StageRefused(f"directory mode drift at {label}")
    _reject_acl_fd(fd, label)
    return info


def _absolute_parts(path: str) -> tuple[str, ...]:
    target = PurePosixPath(path)
    if not target.is_absolute() or str(target) != path or any(part in {"", ".", ".."} for part in target.parts[1:]):
        raise StageRefused(f"non-canonical absolute path: {path}")
    return target.parts[1:]


class _Directories:
    """Hold every opened directory and prove its name still reaches that inode."""

    def __init__(self, config: _Config) -> None:
        self.config = config
        self.fds: dict[str, int] = {}
        root_fd = os.open("/", DIRECTORY_FLAGS)
        self.fds["/"] = root_fd
        self._check_directory("/", root_fd)

    def close(self) -> None:
        for fd in reversed(tuple(self.fds.values())):
            try:
                os.close(fd)
            except OSError:
                pass
        self.fds.clear()

    def _check_directory(self, path: str, fd: int) -> os.stat_result:
        if self.config.is_fixture and path == "/var/tmp":
            info = os.fstat(fd)
            if not stat.S_ISDIR(info.st_mode) or (info.st_uid, info.st_gid) != (0, 0):
                raise StageRefused("/var/tmp is not a root-owned real directory")
            if not info.st_mode & stat.S_ISVTX:
                raise StageRefused("/var/tmp lacks its sticky bit")
            _reject_acl_fd(fd, path)
            return info
        if not self.config.is_fixture and path == "/run":
            info = os.fstat(fd)
            if (info.st_dev, info.st_ino, info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != (25, 1, 0, 0, 0o755):
                raise StageRefused("/run identity or metadata drift")
            _reject_acl_fd(fd, path)
            return info
        if not self.config.is_fixture and path == "/run/lock":
            info = os.fstat(fd)
            if (info.st_dev, info.st_ino, info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != (28, 1, 0, 0, 0o1777):
                raise StageRefused("/run/lock identity or metadata drift")
            if not stat.S_ISDIR(info.st_mode):
                raise StageRefused("/run/lock is not a real directory")
            _reject_acl_fd(fd, path)
            return info
        if path == self.config.store:
            return _secure_directory(fd, path, exact_mode=0o700)
        p004_path = str(PurePosixPath(self.config.root) / "evidence" / "P004")
        s002_path = str(PurePosixPath(p004_path) / "S002")
        if path in {p004_path, s002_path}:
            return _secure_directory(fd, path, exact_mode=0o700)
        return _secure_directory(fd, path)

    def hold_directory(self, path: str, *, required: bool = True) -> int | None:
        if path in self.fds:
            return self.fds[path]
        parts = _absolute_parts(path)
        current = "/"
        for part in parts:
            child = str(PurePosixPath(current) / part)
            if child in self.fds:
                current = child
                continue
            parent_fd = self.fds[current]
            try:
                named = os.stat(part, dir_fd=parent_fd, follow_symlinks=False)
            except FileNotFoundError:
                if required:
                    raise StageRefused(f"required directory is absent: {child}")
                return None
            if not stat.S_ISDIR(named.st_mode):
                raise StageRefused(f"path component is not a real directory: {child}")
            child_fd = os.open(part, DIRECTORY_FLAGS, dir_fd=parent_fd)
            opened = os.fstat(child_fd)
            if (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino):
                os.close(child_fd)
                raise StageRefused(f"directory changed while opening: {child}")
            try:
                self._check_directory(child, child_fd)
            except BaseException:
                os.close(child_fd)
                raise
            self.fds[child] = child_fd
            current = child
        return self.fds.get(path)

    def revalidate(self) -> None:
        for path in sorted(self.fds, key=lambda value: (value.count("/"), value)):
            fd = self.fds[path]
            held = self._check_directory(path, fd)
            if path == "/":
                continue
            parent = str(PurePosixPath(path).parent)
            name = PurePosixPath(path).name
            if parent not in self.fds:
                raise StageRefused(f"held parent is missing: {parent}")
            named = os.stat(name, dir_fd=self.fds[parent], follow_symlinks=False)
            if not stat.S_ISDIR(named.st_mode) or (named.st_dev, named.st_ino) != (held.st_dev, held.st_ino):
                raise StageRefused(f"held directory name drift: {path}")
        pinned_paths = {
            self.config.root,
            str(PurePosixPath(self.config.root) / "evidence"),
            str(PurePosixPath(self.config.root) / "evidence" / "P004"),
            str(PurePosixPath(self.config.root) / "evidence" / "P004" / "S002"),
        }
        if pinned_paths <= self.fds.keys():
            self._verify_pins()

    def check_markers(self) -> None:
        _check_markers(self.config, self)

    def _verify_pins(self) -> None:
        root_fd = self.fds[self.config.root]
        root = _secure_directory(root_fd, self.config.root, exact_mode=0o755)
        if (root.st_dev, root.st_ino) != self.config.root_identity:
            raise StageRefused("canonical root identity drift")
        evidence_path = str(PurePosixPath(self.config.root) / "evidence")
        evidence_fd = self.fds[evidence_path]
        evidence = _secure_directory(evidence_fd, evidence_path, exact_mode=0o755)
        if (evidence.st_dev, evidence.st_ino) != self.config.evidence_identity:
            raise StageRefused("canonical evidence identity drift")
        p004_path = str(PurePosixPath(evidence_path) / "P004")
        _secure_directory(self.fds[p004_path], p004_path, exact_mode=0o700)
        s002_path = str(PurePosixPath(p004_path) / "S002")
        _secure_directory(self.fds[s002_path], s002_path, exact_mode=0o700)

    def create_directory(self, path: str) -> int:
        parent = str(PurePosixPath(path).parent)
        name = PurePosixPath(path).name
        if parent not in self.fds:
            raise StageUnknown(f"missing held parent for directory creation: {parent}")
        parent_fd = self.fds[parent]
        old_mask = os.umask(0)
        try:
            os.mkdir(name, 0o755, dir_fd=parent_fd)
        finally:
            os.umask(old_mask)
        os.fsync(parent_fd)
        child_fd = os.open(name, DIRECTORY_FLAGS, dir_fd=parent_fd)
        opened = os.fstat(child_fd)
        named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino):
            os.close(child_fd)
            raise StageUnknown(f"new directory name changed: {path}")
        try:
            _secure_directory(child_fd, path, exact_mode=0o755)
        except BaseException:
            os.close(child_fd)
            raise
        self.fds[path] = child_fd
        return child_fd


class _Ledger:
    def __init__(self, directory_fd: int, attempt: str) -> None:
        self.directory_fd = directory_fd
        self.attempt = attempt
        self.sequence = 0
        self.failed_step: str | None = None

    def write(self, name: str, record: Mapping[str, Any]) -> None:
        if "/" in name or name in {"", ".", ".."}:
            raise ValueError("ledger record name must be one path component")
        raw = (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
        old_mask = os.umask(0)
        try:
            fd = os.open(name, FILE_CREATE_FLAGS, 0o600, dir_fd=self.directory_fd)
        finally:
            os.umask(old_mask)
        try:
            view = memoryview(raw)
            while view:
                written = os.write(fd, view)
                if written <= 0:
                    raise OSError(errno.EIO, "short ledger write")
                view = view[written:]
            os.fsync(fd)
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode), info.st_nlink) != (0, 0, 0o600, 1):
                raise StageUnknown(f"ledger record metadata drift: {name}")
            named = os.stat(name, dir_fd=self.directory_fd, follow_symlinks=False)
            if (named.st_dev, named.st_ino) != (info.st_dev, info.st_ino):
                raise StageUnknown(f"ledger record name drift: {name}")
            readback_fd = os.open(name, FILE_READ_FLAGS, dir_fd=self.directory_fd)
            try:
                readback_info = os.fstat(readback_fd)
                if (readback_info.st_dev, readback_info.st_ino) != (info.st_dev, info.st_ino) or _digest_fd(readback_fd) != hashlib.sha256(raw).hexdigest():
                    raise StageUnknown(f"ledger record readback drift: {name}")
            finally:
                os.close(readback_fd)
        finally:
            os.close(fd)
        os.fsync(self.directory_fd)

    def begin(self, config: _Config, bundle: _Bundle) -> None:
        self.write(
            f"run-{self.attempt}.intent.json",
            {
                "schema": "p004-reviewed-source-stage-intent-v1",
                "status": "INTENT_DURABLE",
                "attempt": self.attempt,
                "archive_sha256": bundle.archive_sha256,
                "manifest_sha256": bundle.manifest_sha256,
                "canonical_root": config.root,
                "source_files": EXPECTED_SOURCE_COUNT,
                "published_sources": EXPECTED_PUBLISH_COUNT,
                "historical_evidence_not_staged": EXPECTED_HISTORICAL_COUNT,
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
                "schema": "p004-reviewed-source-stage-step-intent-v1",
                "attempt": self.attempt,
                "sequence": self.sequence,
                "operation": operation,
                "target": target,
                "sha256": sha256,
                "status": "INTENT_DURABLE",
            },
        )
        return self.sequence

    def result(self, sequence: int, operation: str, target: str, status: str, details: Mapping[str, Any], error: BaseException | None = None) -> None:
        record: dict[str, Any] = {
            "schema": "p004-reviewed-source-stage-step-result-v1",
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

    def terminal(self, status: str, error: BaseException | None = None) -> None:
        record: dict[str, Any] = {
            "schema": "p004-reviewed-source-stage-terminal-v1",
            "attempt": self.attempt,
            "status": status,
            "failed_step": self.failed_step,
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


def _reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise StageRefused(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _safe_json(raw: bytes, label: str) -> Any:
    try:
        return json.loads(raw, object_pairs_hook=_reject_duplicate_pairs, parse_constant=lambda value: (_ for _ in ()).throw(StageRefused(f"non-finite JSON number in {label}: {value}")))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise StageRefused(f"invalid JSON in {label}: {error}") from error


def _source_destination(source: str) -> str | None:
    if source == "poc-k8s-fabric/labctl/labctl":
        return "labctl"
    if source.startswith("poc-k8s-fabric/labctl/lib/") or source.startswith("poc-k8s-fabric/labctl/labs/"):
        return source.removeprefix("poc-k8s-fabric/labctl/")
    if source.startswith("poc-k8s-fabric/studies/p004/ovn/"):
        return source.removeprefix("poc-k8s-fabric/")
    if source.startswith("poc-k8s-fabric/evidence/P004/"):
        return None
    raise StageRefused(f"source path is outside the approved mapping: {source}")


def _validate_source_path(path: str) -> None:
    pure = PurePosixPath(path)
    if pure.is_absolute() or str(pure) != path or not pure.parts or any(part in {"", ".", ".."} for part in pure.parts):
        raise StageRefused(f"unsafe bundle member path: {path!r}")
    if "\\" in path or "\x00" in path:
        raise StageRefused(f"unsafe bundle member path: {path!r}")


def _read_member(archive: tarfile.TarFile, member: tarfile.TarInfo) -> bytes:
    stream = archive.extractfile(member)
    if stream is None:
        raise StageRefused(f"cannot read regular bundle member: {member.name}")
    raw = stream.read(MAX_MEMBER_BYTES + 1)
    if len(raw) != member.size or len(raw) > MAX_MEMBER_BYTES:
        raise StageRefused(f"bundle member size mismatch: {member.name}")
    return raw


def _validate_bundle(raw: bytes, config: _Config) -> _Bundle:
    if len(raw) > MAX_ARCHIVE_BYTES:
        raise StageRefused("approved archive exceeds the bounded input size")
    archive_sha = hashlib.sha256(raw).hexdigest()
    if archive_sha != config.archive_sha256:
        raise StageRefused("archive SHA256 does not match the accepted pin")
    try:
        archive = tarfile.open(fileobj=io.BytesIO(raw), mode="r:*")
    except (tarfile.TarError, OSError) as error:
        raise StageRefused(f"invalid source archive: {error}") from error
    with archive:
        members = archive.getmembers()
        if len(members) != EXPECTED_SOURCE_COUNT + 1:
            raise StageRefused("archive must contain the manifest and exactly 70 source members")
        by_name: dict[str, bytes] = {}
        total_bytes = 0
        for member in members:
            _validate_source_path(member.name)
            if not member.isfile() or member.size > MAX_MEMBER_BYTES or member.name in by_name:
                raise StageRefused(f"unsupported, oversized, or duplicate archive member: {member.name}")
            total_bytes += member.size
            if total_bytes > MAX_TOTAL_MEMBER_BYTES:
                raise StageRefused("unpacked source archive exceeds the bounded total size")
            by_name[member.name] = _read_member(archive, member)
    manifest_raw = by_name.pop("snapshot-manifest.json", None)
    if manifest_raw is None:
        raise StageRefused("source archive has no snapshot manifest")
    manifest_sha = hashlib.sha256(manifest_raw).hexdigest()
    if manifest_sha != config.manifest_sha256:
        raise StageRefused("manifest SHA256 does not match the accepted pin")
    manifest = _safe_json(manifest_raw, "snapshot manifest")
    if not isinstance(manifest, dict) or len(manifest) != EXPECTED_SOURCE_COUNT:
        raise StageRefused("manifest must contain exactly 70 source entries")
    if set(by_name) != set(manifest):
        raise StageRefused("archive members differ from the pinned manifest source set")
    mapped: dict[str, tuple[str, bytes, str]] = {}
    historical: list[str] = []
    for source, expected_digest in manifest.items():
        _validate_source_path(source)
        if not isinstance(expected_digest, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_digest):
            raise StageRefused(f"invalid source digest in manifest: {source}")
        data = by_name[source]
        digest = hashlib.sha256(data).hexdigest()
        if digest != expected_digest:
            raise StageRefused(f"source digest mismatch: {source}")
        relative = _source_destination(source)
        if relative is None:
            historical.append(source)
            continue
        pure = PurePosixPath(relative)
        if pure.is_absolute() or str(pure) != relative or any(part in {"", ".", ".."} for part in pure.parts):
            raise StageRefused(f"unsafe mapped destination: {relative}")
        if relative in mapped:
            raise StageRefused(f"duplicate mapped destination: {relative}")
        mapped[relative] = (source, data, digest)
    if len(mapped) != EXPECTED_PUBLISH_COUNT or len(historical) != EXPECTED_HISTORICAL_COUNT:
        raise StageRefused("approved mapping must contain exactly 58 sources and 12 historical evidence files")
    return _Bundle(archive_sha, manifest_sha, mapped, tuple(sorted(historical)))


def _require_linux_root(config: _Config) -> None:
    if platform.system() != "Linux":
        raise StageRefused("source publication requires Linux")
    if os.geteuid() != 0:
        raise StageRefused("source publication requires effective UID 0")
    if os.getegid() != 0:
        raise StageRefused("source publication requires effective GID 0")
    if config.is_fixture:
        _require_private_fixture_base(config.fixture_base or "")


def _ensure_absent(parent_fd: int, name: str, label: str) -> None:
    try:
        os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    raise StageRefused(f"path must be absent: {label}")


def _check_store_absent(config: _Config, directories: _Directories) -> None:
    store_parent = str(PurePosixPath(config.store).parent)
    parent_fd = directories.hold_directory(store_parent)
    assert parent_fd is not None
    directories.revalidate()
    _ensure_absent(parent_fd, PurePosixPath(config.store).name, config.store)


def _check_markers(config: _Config, directories: _Directories) -> None:
    for marker in config.markers:
        parent = str(PurePosixPath(marker).parent)
        parent_fd = directories.hold_directory(parent, required=False)
        if parent_fd is None:
            continue
        _ensure_absent(parent_fd, PurePosixPath(marker).name, marker)


def _check_lock(config: _Config, directories: _Directories) -> None:
    parent_path = str(PurePosixPath(config.lock_path).parent)
    parent_fd = directories.hold_directory(parent_path)
    name = PurePosixPath(config.lock_path).name
    fd = os.open(name, FILE_READ_FLAGS, dir_fd=parent_fd)
    try:
        info = os.fstat(fd)
        named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if not stat.S_ISREG(info.st_mode) or (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode), info.st_nlink) != (0, 0, 0o600, 1):
            raise StageRefused("fixed canonical lock metadata drift")
        if (info.st_dev, info.st_ino) != config.lock_identity or (named.st_dev, named.st_ino) != (info.st_dev, info.st_ino):
            raise StageRefused("fixed canonical lock identity drift")
        _reject_acl_fd(fd, "fixed canonical lock")
        digest = _digest_fd(fd)
        after = os.fstat(fd)
        named_after = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        observed_before = (info.st_dev, info.st_ino, info.st_uid, info.st_gid, info.st_mode, info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
        observed_after = (after.st_dev, after.st_ino, after.st_uid, after.st_gid, after.st_mode, after.st_nlink, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
        if observed_before != observed_after or (named_after.st_dev, named_after.st_ino) != (after.st_dev, after.st_ino):
            raise StageRefused("fixed canonical lock changed during read")
        if digest != config.lock_sha256:
            raise StageRefused("fixed canonical lock content drift")
    finally:
        os.close(fd)


def _destination_parent(config: _Config, relative: str) -> str:
    return str(PurePosixPath(config.root) / PurePosixPath(relative).parent)


def _required_destination_directories(config: _Config, bundle: _Bundle) -> tuple[str, ...]:
    directories: set[str] = set()
    for relative in bundle.publish:
        parent = PurePosixPath(relative).parent
        current = PurePosixPath(config.root)
        for part in parent.parts:
            if part == ".":
                continue
            current /= part
            directories.add(str(current))
    return tuple(sorted(directories, key=lambda value: (value.count("/"), value)))


def _preflight(config: _Config, bundle: _Bundle) -> tuple[_Directories, tuple[str, ...]]:
    _require_linux_root(config)
    directories = _Directories(config)
    try:
        _check_store_absent(config, directories)
        directories.hold_directory(config.root)
        evidence = str(PurePosixPath(config.root) / "evidence")
        directories.hold_directory(evidence)
        directories.hold_directory(str(PurePosixPath(evidence) / "P004" / "S002"))
        directories._verify_pins()
        _probe_rename_noreplace(directories.fds[config.root])
        _check_lock(config, directories)
        _check_markers(config, directories)

        required = _required_destination_directories(config, bundle)
        for path in required:
            directories.hold_directory(path, required=False)
        missing = tuple(path for path in required if path not in directories.fds)
        for relative in bundle.publish:
            parent = _destination_parent(config, relative)
            parent_fd = directories.fds.get(parent)
            if parent_fd is not None:
                _ensure_absent(parent_fd, PurePosixPath(relative).name, str(PurePosixPath(config.root) / relative))
        directories.revalidate()
        return directories, missing
    except BaseException:
        directories.close()
        raise


def _prepare_store(config: _Config, directories: _Directories) -> int:
    directories.revalidate()
    parent_path = str(PurePosixPath(config.store).parent)
    parent_fd = directories.fds[parent_path]
    name = PurePosixPath(config.store).name
    _ensure_absent(parent_fd, name, config.store)
    old_mask = os.umask(0)
    try:
        os.mkdir(name, 0o700, dir_fd=parent_fd)
    finally:
        os.umask(old_mask)
    os.fsync(parent_fd)
    store_fd = os.open(name, DIRECTORY_FLAGS, dir_fd=parent_fd)
    try:
        _secure_directory(store_fd, config.store, exact_mode=0o700)
        named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        opened = os.fstat(store_fd)
        if (named.st_dev, named.st_ino) != (opened.st_dev, opened.st_ino):
            raise StageUnknown("durable ledger name changed after creation")
        directories.fds[config.store] = os.dup(store_fd)
    except BaseException:
        os.close(store_fd)
        raise
    return store_fd


def _rename_noreplace(directory_fd: int, old_name: str, new_name: str) -> None:
    function = getattr(ctypes.CDLL(None, use_errno=True), "renameat2", None)
    if function is None:
        raise StageRefused("libc renameat2 is required for no-overwrite publication")
    function.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    function.restype = ctypes.c_int
    result = function(directory_fd, os.fsencode(old_name), directory_fd, os.fsencode(new_name), RENAME_NOREPLACE)
    if result != 0:
        call_errno = ctypes.get_errno()
        raise OSError(call_errno, os.strerror(call_errno), new_name)


def _probe_rename_noreplace(directory_fd: int) -> None:
    try:
        _rename_noreplace(directory_fd, "", "")
    except OSError as error:
        if error.errno == errno.ENOENT:
            return
        raise StageRefused(f"renameat2 no-replace preflight failed: {error}") from error
    raise StageRefused("renameat2 accepted an impossible empty path")


def _digest_fd(fd: int) -> str:
    digest = hashlib.sha256()
    while True:
        block = os.read(fd, 1024 * 1024)
        if not block:
            break
        digest.update(block)
    return digest.hexdigest()


def _verify_file(parent_fd: int, name: str, data: bytes, digest: str, mode: int, label: str) -> dict[str, Any]:
    fd = os.open(name, FILE_READ_FLAGS, dir_fd=parent_fd)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or (before.st_uid, before.st_gid, stat.S_IMODE(before.st_mode), before.st_nlink) != (0, 0, mode, 1):
            raise StageUnknown(f"published file metadata drift: {label}")
        _reject_acl_fd(fd, label)
        observed = _digest_fd(fd)
        after = os.fstat(fd)
        named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        before_identity = (before.st_dev, before.st_ino, before.st_uid, before.st_gid, before.st_mode, before.st_nlink, before.st_size, before.st_mtime_ns)
        after_identity = (after.st_dev, after.st_ino, after.st_uid, after.st_gid, after.st_mode, after.st_nlink, after.st_size, after.st_mtime_ns)
        if before_identity != after_identity:
            raise StageUnknown(f"file changed during readback: {label}")
        if (named.st_dev, named.st_ino) != (after.st_dev, after.st_ino):
            raise StageUnknown(f"file name changed during readback: {label}")
        if observed != digest or after.st_size != len(data):
            raise StageUnknown(f"published file content drift: {label}")
        return {"uid": after.st_uid, "gid": after.st_gid, "mode": oct(stat.S_IMODE(after.st_mode)), "nlink": after.st_nlink, "size": after.st_size, "sha256": observed, "dev": after.st_dev, "inode": after.st_ino}
    finally:
        os.close(fd)


def _fault(hook: Callable[[str, Mapping[str, Any]], None] | None, event: str, values: Mapping[str, Any]) -> None:
    if hook is not None:
        hook(event, values)


def _effect(
    directories: _Directories,
    ledger: _Ledger,
    *,
    operation: str,
    target: str,
    action: Callable[[], Mapping[str, Any]],
    hook: Callable[[str, Mapping[str, Any]], None] | None = None,
    sha256: str | None = None,
) -> Mapping[str, Any]:
    directories.revalidate()
    _check_lock(directories.config, directories)
    directories.check_markers()
    sequence = ledger.intent(operation, target, sha256)
    try:
        _fault(hook, f"before:{operation}", {"target": target, "sequence": sequence})
        details = dict(action())
        directories.revalidate()
        _check_lock(directories.config, directories)
        directories.check_markers()
        _fault(hook, f"after:{operation}", {"target": target, "sequence": sequence, **details})
        ledger.result(sequence, operation, target, "PROVED", details)
        return details
    except BaseException as error:
        ledger.failed_step = operation
        try:
            ledger.result(sequence, operation, target, "UNKNOWN", {"effect_may_have_occurred": True}, error)
        except BaseException:
            pass
        raise StageUnknown(f"{operation} left an UNKNOWN effect at {target}: {error}") from error


def _create_destination_directories(
    config: _Config,
    directories: _Directories,
    ledger: _Ledger,
    missing: tuple[str, ...],
    hook: Callable[[str, Mapping[str, Any]], None] | None,
) -> None:
    for path in missing:
        parent = str(PurePosixPath(path).parent)

        def create(path: str = path) -> Mapping[str, Any]:
            fd = directories.create_directory(path)
            info = os.fstat(fd)
            return {"dev": info.st_dev, "inode": info.st_ino, "uid": info.st_uid, "gid": info.st_gid, "mode": oct(stat.S_IMODE(info.st_mode))}

        if parent not in directories.fds:
            raise StageUnknown(f"missing held parent before directory creation: {parent}")
        _effect(directories, ledger, operation="mkdir", target=path, action=create, hook=hook)


def _publish_file(
    config: _Config,
    directories: _Directories,
    ledger: _Ledger,
    attempt: str,
    index: int,
    relative: str,
    source: str,
    data: bytes,
    digest: str,
    hook: Callable[[str, Mapping[str, Any]], None] | None,
) -> dict[str, Any]:
    parent_path = _destination_parent(config, relative)
    parent_fd = directories.fds[parent_path]
    destination_name = PurePosixPath(relative).name
    destination = str(PurePosixPath(config.root) / relative)
    temp_name = f".p004-reviewed-source-{attempt}-{index:03d}.tmp"
    mode = 0o755 if relative == "labctl" or relative.endswith(".sh") else 0o644

    def create_temp() -> Mapping[str, Any]:
        old_mask = os.umask(0)
        try:
            fd = os.open(temp_name, FILE_CREATE_FLAGS, mode, dir_fd=parent_fd)
        finally:
            os.umask(old_mask)
        try:
            view = memoryview(data)
            while view:
                written = os.write(fd, view)
                if written <= 0:
                    raise OSError(errno.EIO, "short staged source write")
                view = view[written:]
            os.fsync(fd)
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode), info.st_nlink) != (0, 0, mode, 1):
                raise StageUnknown(f"temporary file metadata drift: {temp_name}")
        finally:
            os.close(fd)
        os.fsync(parent_fd)
        check = _verify_file(parent_fd, temp_name, data, digest, mode, temp_name)
        return {"temporary": temp_name, **check}

    _effect(directories, ledger, operation="temp-create-write-fsync", target=f"{parent_path}/{temp_name}", action=create_temp, hook=hook, sha256=digest)

    def publish() -> Mapping[str, Any]:
        directories.revalidate()
        _ensure_absent(parent_fd, destination_name, destination)
        _rename_noreplace(parent_fd, temp_name, destination_name)
        _fault(hook, "after:renameat2", {"source": temp_name, "destination": destination})
        os.fsync(parent_fd)
        directories.revalidate()
        check = _verify_file(parent_fd, destination_name, data, digest, mode, destination)
        return {"source": source, "destination": destination, **check}

    return dict(_effect(directories, ledger, operation="publish-noreplace", target=destination, action=publish, hook=hook, sha256=digest))


def _final_readback(config: _Config, directories: _Directories, bundle: _Bundle, entries: list[dict[str, Any]]) -> None:
    if len(entries) != EXPECTED_PUBLISH_COUNT:
        raise StageUnknown("publication count readback did not reach 58")
    directories.revalidate()
    for relative, (_source, data, digest) in bundle.publish.items():
        parent = directories.fds[_destination_parent(config, relative)]
        mode = 0o755 if relative == "labctl" or relative.endswith(".sh") else 0o644
        _verify_file(parent, PurePosixPath(relative).name, data, digest, mode, relative)


def _apply(
    config: _Config,
    bundle: _Bundle,
    attempt: str,
    *,
    hook: Callable[[str, Mapping[str, Any]], None] | None = None,
) -> dict[str, Any]:
    if not ATTEMPT_RE.fullmatch(attempt):
        raise StageRefused("attempt must be exactly 32 lowercase hexadecimal characters")
    if hook is not None and not config.is_fixture:
        raise StageRefused("production apply does not accept a test hook")
    directories, missing = _preflight(config, bundle)
    store_fd: int | None = None
    ledger: _Ledger | None = None
    entries: list[dict[str, Any]] = []
    try:
        try:
            store_fd = _prepare_store(config, directories)
        except BaseException as error:
            raise StageUnknown(f"ledger creation is UNKNOWN and retained at {config.store}: {error}") from error
        ledger = _Ledger(store_fd, attempt)
        try:
            directories.revalidate()
            ledger.begin(config, bundle)
            _create_destination_directories(config, directories, ledger, missing, hook)
            for index, (relative, (source, data, digest)) in enumerate(sorted(bundle.publish.items()), start=1):
                entries.append(_publish_file(config, directories, ledger, attempt, index, relative, source, data, digest, hook))
            _check_markers(config, directories)
            _final_readback(config, directories, bundle, entries)
            _check_lock(config, directories)
            _check_markers(config, directories)
            ledger.terminal("PASS_STAGED_SOURCE_ONLY")
            return {
                "status": "PASS_STAGED_SOURCE_ONLY",
                "schema": "p004-reviewed-source-stage-result-v1",
                "attempt": attempt,
                "archive_sha256": bundle.archive_sha256,
                "manifest_sha256": bundle.manifest_sha256,
                "canonical_root": config.root,
                "source_files_published": len(entries),
                "entries": entries,
                "historical_evidence_not_staged": list(bundle.historical),
                "ledger": config.store,
                "canonical_lock_changed": False,
                "receipt_created": False,
                "lab_mutation": False,
                "actual_X05": "NOT_RUN",
            }
        except BaseException as error:
            ledger.failed_step = ledger.failed_step or "preflight-or-stage-effect"
            try:
                ledger.terminal("UNKNOWN", error)
            except BaseException:
                pass
            raise StageUnknown(f"stage is UNKNOWN and retained at {config.store}: {error}") from error
    finally:
        directories.close()
        if store_fd is not None:
            try:
                os.close(store_fd)
            except OSError:
                pass


def _dry_run(config: _Config, bundle: _Bundle) -> dict[str, Any]:
    directories, missing = _preflight(config, bundle)
    try:
        return {
            "status": "READY",
            "archive_sha256": bundle.archive_sha256,
            "manifest_sha256": bundle.manifest_sha256,
            "canonical_root": config.root,
            "source_files": EXPECTED_SOURCE_COUNT,
            "destinations_absent": EXPECTED_PUBLISH_COUNT,
            "historical_evidence_not_staged": EXPECTED_HISTORICAL_COUNT,
            "directories_to_create": list(missing),
            "canonical_lock_changed": False,
            "receipt_created": False,
            "lab_mutation": False,
            "actual_X05": "NOT_RUN",
        }
    finally:
        directories.close()


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--dry-run", action="store_true", help="validate the pinned archive and fixed host layout without writes")
    modes.add_argument("--apply", action="store_true", help="publish the 58 approved source files once")
    parser.add_argument("--attempt", help="one-shot 32-character lowercase hexadecimal attempt ID")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    if args.apply and (args.attempt is None or not ATTEMPT_RE.fullmatch(args.attempt)):
        parser.error("--apply requires --attempt with exactly 32 lowercase hexadecimal characters")
    if args.dry_run and args.attempt is not None:
        parser.error("--attempt is valid only with --apply")
    config = _production_config()
    try:
        _require_linux_root(config)
        raw = sys.stdin.buffer.read(MAX_ARCHIVE_BYTES + 1)
        bundle = _validate_bundle(raw, config)
        result = _dry_run(config, bundle) if args.dry_run else _apply(config, bundle, args.attempt)
    except StageUnknown as error:
        print(json.dumps({"status": "UNKNOWN", "error": str(error), "automatic_retry": False, "automatic_cleanup": False, "automatic_rollback": False, "actual_X05": "NOT_RUN"}, sort_keys=True))
        return 1
    except (StageRefused, OSError, tarfile.TarError) as error:
        print(json.dumps({"status": "REFUSED", "error": str(error), "actual_X05": "NOT_RUN"}, sort_keys=True))
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
