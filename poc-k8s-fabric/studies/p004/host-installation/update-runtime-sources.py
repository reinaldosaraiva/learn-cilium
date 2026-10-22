#!/usr/bin/env python3
"""Four-target, one-shot X05 source maintenance with durable provenance.

The production path has one fixed root, one fixed lock, one accepted baseline,
and four accepted payload hashes.  It stages all four files in their held
parent directories and exchanges them one at a time, retaining every original
inode under the attempt name.  A failed effect is UNKNOWN and is retained.
Private fixture APIs live below the production CLI and are never reachable from
its argument surface.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import ctypes
import dataclasses
import errno
import fcntl
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
PRODUCTION_STORE = "/var/lib/p004-runtime-source-maintenance"
PRODUCTION_LOCK = "/run/lock/labctl-mgc-m03.lock"
PRODUCTION_MARKERS = (
    "/run/labctl/mgc-m03/active",
    "/run/labctl/mgc-x05/active",
)
BASELINE_NAME = "update-runtime-sources-baseline.json"
PUBLISHER_NAME = "stage-reviewed-sources.py"
OLD_HELPER_NAME = "update-runtime-selftest.py"
BASELINE_SHA256 = "9f4c9954a356922ce79d3616bbb5518b897a1f9ce64478f0b1e95697089f099e"
PUBLISHER_SHA256 = "29d525794e767e241c778fe3cd706e60b4231b4ac0eeca7426e5f975594ed436"
OLD_HELPER_SHA256 = "133178564f6cd849c06a7c15dd6715dbe71005640c7042911ca97b0803516118"
SOURCE_CANDIDATE_SHA256 = "251777b777fd62153ba731de44f1b44bd6d325881d3b66a7c0b1421e6adf517e"
SOURCE_ARCHIVE_SHA256 = "27e76c19161ba11d0189b37973d1ed101d79c5286417ce0a709cefb186f1edc7"
SOURCE_MANIFEST_SHA256 = "e26793a0739a0e943ffcb985f832bd7bf2f2809d356685b0f6d3a8720edec17c"
MAX_INPUT_BYTES = 2 * 1024 * 1024
MAX_PAYLOAD_BYTES = 512 * 1024
EXPECTED_SOURCE_COUNT = 58
PROTECTED_SOURCE_COUNT = 54
CODE_DIRECTORY_PREFIX = "p004-runtime-source-maintenance-code-"
FIXTURE_DIRECTORY_PREFIX = "p004-runtime-source-maintenance-fixture-"
ATTEMPT_RE = re.compile(r"[0-9a-f]{32}\Z")
SHA_RE = re.compile(r"[0-9a-f]{64}\Z")
ACL_XATTRS = {"system.posix_acl_access", "system.posix_acl_default"}
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
FILE_READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | getattr(os, "O_NOATIME", 0)
FILE_CREATE_FLAGS = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
RENAME_EXCHANGE = 2
PAYLOAD_BASENAMES = (
    "x05-coordinator.py",
    "x05-coordinator-selftest.py",
    "x05-runtime-live-selftest.py",
    "x05-runtime-live.py",
)
TARGET_ORDER = (
    "/opt/poc-k8s-fabric/studies/p004/ovn/x05-coordinator.py",
    "/opt/poc-k8s-fabric/studies/p004/ovn/x05-coordinator-selftest.py",
    "/opt/poc-k8s-fabric/studies/p004/ovn/x05-runtime-live-selftest.py",
    "/opt/poc-k8s-fabric/studies/p004/ovn/x05-runtime-live.py",
)
PAYLOADS = {
    TARGET_ORDER[0]: {"sha256": "584bf99c4ade986033679f564f9e83a0030702a25001a700b6e07259d59906d3", "size": 119328},
    TARGET_ORDER[1]: {"sha256": "5847e99a3dff25cbd9a00d9730881e7a2e6203d1d51ded42bf55647f1921e6dd", "size": 52954},
    TARGET_ORDER[2]: {"sha256": "7bc530899e73045291a7ed356c206a8c92e231fe20d93eed86bf763bf571b70f", "size": 168714},
    TARGET_ORDER[3]: {"sha256": "cc0f055121ddbd154aafcc8ad35c3c08cce9779de47aed96d8719e5b99284da1", "size": 205282},
}
H4_PINS = {
    "/opt/poc-k8s-fabric": (64769, 262224, 0o755),
    "/opt/poc-k8s-fabric/evidence": (64769, 3742352, 0o755),
    "/opt/poc-k8s-fabric/evidence/P004": (64769, 3742353, 0o700),
    "/opt/poc-k8s-fabric/evidence/P004/S002": (64769, 3742354, 0o700),
}
LOCK_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
PROVENANCE_SCHEMA = "p004-runtime-source-maintenance-apply-intent-v3"
PARENT_INTENT_NAME = "source-maintenance-parent-intent.json"
REMOTE_INTENT_PREFIX = "source-maintenance-apply-intent-"
REMOTE_INTENT_SUFFIX = ".json"


class MaintenanceRefused(RuntimeError):
    """A fixed precondition failed before any source effect."""


class MaintenanceUnknown(RuntimeError):
    """An effect may have occurred; the retained attempt is not retryable."""


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
class _Proof:
    path: str
    sha256: str
    status: str


@dataclasses.dataclass(frozen=True)
class _Baseline:
    sha256: str
    entries: tuple[_Entry, ...]
    payloads: Mapping[str, Mapping[str, Any]]
    target_order: tuple[str, ...]
    prior_terminals: tuple[_Proof, ...]
    parked_old: Mapping[str, Any]
    h4_pins: Mapping[str, tuple[int, int, int]]
    lock: Mapping[str, Any]
    markers: tuple[str, ...]
    store: str
    installation_acceptance_sha256: str
    old_helper_sha256: str
    publisher_sha256: str
    source_candidate_sha256: str
    source_archive_sha256: str
    source_manifest_sha256: str
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
        for path in sorted(self.fds, key=lambda item: (item.count("/"), item)):
            fd = self.fds[path]
            info = os.fstat(fd)
            if not stat.S_ISDIR(info.st_mode) or (info.st_uid, info.st_gid) != (0, 0):
                raise MaintenanceRefused("private code directory identity drift: " + path)
            if path == "/var/tmp":
                if not (info.st_mode & stat.S_ISVTX):
                    raise MaintenanceRefused("/var/tmp lost its sticky bit")
            elif path == self.code_root:
                if stat.S_IMODE(info.st_mode) != 0o700:
                    raise MaintenanceRefused("private code root mode drift")
            elif info.st_mode & 0o022:
                raise MaintenanceRefused("private code ancestor is writable")
            _reject_acl_fd(fd, path)
            if path == "/":
                continue
            parent = str(PurePosixPath(path).parent)
            if parent not in self.fds:
                raise MaintenanceRefused("private code parent is not held")
            named = os.stat(PurePosixPath(path).name, dir_fd=self.fds[parent], follow_symlinks=False)
            if (named.st_dev, named.st_ino) != (info.st_dev, info.st_ino):
                raise MaintenanceRefused("private code name was retargeted")

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
    old_helper_bytes: bytes
    module_name: str
    helper_sha256: str

    def close(self) -> None:
        if sys.modules.get(self.module_name) is self.publisher:
            sys.modules.pop(self.module_name, None)
        self.code.close()


@dataclasses.dataclass
class _Target:
    destination: str
    entry: _Entry
    payload: bytes
    digest: str
    parent_fd: int
    name: str
    temp_name: str
    old_payload: bytes
    old_mtime_ns: int
    new_identity: tuple[int, int] | None = None
    phase: str = "ORIGINAL"


@dataclasses.dataclass
class _Lock:
    config: _RuntimeConfig
    directories: Any
    fd: int

    def check(self) -> None:
        _verify_lock_fd(self.config, self.directories, self.fd)
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            raise MaintenanceRefused("owned canonical lock is no longer held") from error

    def close(self) -> None:
        try:
            os.close(self.fd)
        except OSError:
            pass
        self.fd = -1


@dataclasses.dataclass(frozen=True)
class _Provenance:
    parent_sha256: str
    parent_metadata: Mapping[str, int]
    remote_name: str
    remote_sha256: str
    remote_metadata: Mapping[str, int]


@dataclasses.dataclass
class _Context:
    assets: _Assets
    config: _RuntimeConfig
    baseline: _Baseline
    directories: Any
    lock: _Lock
    targets: dict[str, _Target]
    payloads: Mapping[str, bytes]
    attempt: str
    provenance: _Provenance | None = None
    store_ready: bool = False


def _reject_acl_fd(fd: int, label: str) -> None:
    try:
        names = set(os.listxattr(fd))
    except (OSError, TypeError) as error:
        raise MaintenanceRefused("cannot inspect ACLs on " + label) from error
    present = sorted(names & ACL_XATTRS)
    if present:
        raise MaintenanceRefused("POSIX ACL present on " + label + ": " + ", ".join(present))


def _digest_fd(fd: int) -> str:
    digest = hashlib.sha256()
    while True:
        block = os.read(fd, 1024 * 1024)
        if not block:
            break
        digest.update(block)
    return digest.hexdigest()


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


def _reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key: " + key)
        result[key] = value
    return result


def _safe_json(raw: bytes, label: str) -> Any:
    try:
        return json.loads(
            raw,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=lambda token: (_ for _ in ()).throw(ValueError("non-finite value in " + label)),
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise MaintenanceRefused("invalid JSON in " + label) from error


def _open_held_absolute_directory(path: str, fds: dict[str, int]) -> int:
    if not path.startswith("/") or str(PurePosixPath(path)) != path:
        raise MaintenanceRefused("non-canonical private path")
    if "/" not in fds:
        fds["/"] = os.open("/", DIRECTORY_FLAGS)
    current = "/"
    for part in PurePosixPath(path).parts[1:]:
        child = str(PurePosixPath(current) / part)
        if child in fds:
            current = child
            continue
        parent_fd = fds[current]
        named = os.stat(part, dir_fd=parent_fd, follow_symlinks=False)
        if not stat.S_ISDIR(named.st_mode):
            raise MaintenanceRefused("private path component is not a directory")
        child_fd = os.open(part, DIRECTORY_FLAGS, dir_fd=parent_fd)
        try:
            opened = os.fstat(child_fd)
            if (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino):
                raise MaintenanceRefused("private path changed while opening")
            fds[child] = child_fd
        except BaseException:
            os.close(child_fd)
            raise
        current = child
    return fds[current]


def _bootstrap_code_context(script_path: str) -> _CodeContext:
    script = PurePosixPath(script_path)
    if not script.is_absolute() or str(script) != script_path:
        raise MaintenanceRefused("helper path is not absolute")
    code_root = str(script.parent)
    if PurePosixPath(code_root).parent != PurePosixPath("/var/tmp"):
        raise MaintenanceRefused("private code root must be a direct /var/tmp child")
    if not PurePosixPath(code_root).name.startswith(CODE_DIRECTORY_PREFIX):
        raise MaintenanceRefused("private code root prefix drift")
    fds: dict[str, int] = {}
    try:
        _open_held_absolute_directory("/var/tmp", fds)
        _open_held_absolute_directory(code_root, fds)
        tmp_info = os.fstat(fds["/var/tmp"])
        root_info = os.fstat(fds[code_root])
        if (tmp_info.st_uid, tmp_info.st_gid) != (0, 0) or not (tmp_info.st_mode & stat.S_ISVTX):
            raise MaintenanceRefused("/var/tmp is not root-owned sticky storage")
        if (root_info.st_uid, root_info.st_gid, stat.S_IMODE(root_info.st_mode)) != (0, 0, 0o700):
            raise MaintenanceRefused("private code root must be root:root 0700")
        _reject_acl_fd(fds["/var/tmp"], "/var/tmp")
        _reject_acl_fd(fds[code_root], code_root)
        code = _CodeContext(code_root, fds)
        code.revalidate()
        return code
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
        raise MaintenanceRefused("invalid fixed file name: " + label)
    try:
        fd = os.open(name, FILE_READ_FLAGS, dir_fd=parent_fd)
    except OSError as error:
        raise MaintenanceRefused("cannot open fixed file: " + label) from error
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise MaintenanceRefused("fixed path is not a regular file: " + label)
        if (before.st_uid, before.st_gid) != (0, 0) or stat.S_IMODE(before.st_mode) not in allowed_modes or before.st_nlink != 1:
            raise MaintenanceRefused("fixed file ownership/mode/link drift: " + label)
        if before.st_size > maximum or (expected_size is not None and before.st_size != expected_size):
            raise MaintenanceRefused("fixed file size drift: " + label)
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
                    raise MaintenanceRefused("fixed file metadata drift: " + label)
        _reject_acl_fd(fd, label)
        digest = hashlib.sha256()
        chunks: list[bytes] = []
        size = 0
        while True:
            block = os.read(fd, min(1024 * 1024, maximum + 1 - size))
            if not block:
                break
            chunks.append(block)
            digest.update(block)
            size += len(block)
            if size > maximum:
                raise MaintenanceRefused("fixed file exceeds size bound: " + label)
        raw = b"".join(chunks)
        after = os.fstat(fd)
        named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if _stat_signature(before) != _stat_signature(after) or (named.st_dev, named.st_ino) != (after.st_dev, after.st_ino):
            raise MaintenanceRefused("fixed file changed during read: " + label)
        if size != after.st_size or (expected_size is not None and size != expected_size):
            raise MaintenanceRefused("fixed file readback size drift: " + label)
        if expected_sha256 is not None and digest.hexdigest() != expected_sha256:
            raise MaintenanceRefused("fixed file SHA256 drift: " + label)
        _reject_acl_fd(fd, label)
        return raw, after
    finally:
        os.close(fd)


def _read_code_file(code: _CodeContext, name: str, *, expected_sha256: str | None = None, modes: tuple[int, ...] = (0o600, 0o644), maximum: int = 2 * 1024 * 1024) -> bytes:
    code.revalidate()
    raw, _ = _read_file_at(code.directory_fd, name, label=code.code_root + "/" + name, expected_sha256=expected_sha256, allowed_modes=modes, maximum=maximum)
    code.revalidate()
    return raw


def _parse_baseline(raw: bytes) -> _Baseline:
    if hashlib.sha256(raw).hexdigest() != BASELINE_SHA256:
        raise MaintenanceRefused("baseline bytes do not match the compiled pin")
    value = _safe_json(raw, BASELINE_NAME)
    required = {
        "actual_X05", "automatic_cleanup", "automatic_rollback", "automatic_retry",
        "canonical_lock", "entries", "h4_pins", "installation_acceptance_sha256",
        "markers", "old_helper_sha256", "parked_old", "payloads", "prior_terminals",
        "publisher_sha256", "schema", "session", "source_archive_sha256",
        "source_candidate_sha256", "source_manifest_sha256", "store", "target_order",
    }
    if not isinstance(value, dict) or set(value) != required:
        raise MaintenanceRefused("baseline shape drift")
    if value["schema"] != "p004-runtime-source-maintenance-baseline-v3" or value["session"] != "P004-S002":
        raise MaintenanceRefused("baseline identity drift")
    if value["installation_acceptance_sha256"] != "3cf674e235281401145685fa6902f265011c07c91c68f26146da2c9a5c0812b0":
        raise MaintenanceRefused("accepted installation pin drift")
    if value["old_helper_sha256"] != OLD_HELPER_SHA256 or value["publisher_sha256"] != PUBLISHER_SHA256:
        raise MaintenanceRefused("dependency pin drift in baseline")
    if value["source_candidate_sha256"] != SOURCE_CANDIDATE_SHA256 or value["source_archive_sha256"] != SOURCE_ARCHIVE_SHA256 or value["source_manifest_sha256"] != SOURCE_MANIFEST_SHA256:
        raise MaintenanceRefused("frozen source candidate pin drift")
    if value["store"] != PRODUCTION_STORE or value["markers"] != list(PRODUCTION_MARKERS):
        raise MaintenanceRefused("store/marker pin drift")
    if value["automatic_retry"] is not False or value["automatic_cleanup"] is not False or value["automatic_rollback"] is not False or value["actual_X05"] != "NOT_RUN":
        raise MaintenanceRefused("one-shot baseline flags drift")
    if value["target_order"] != list(TARGET_ORDER):
        raise MaintenanceRefused("target order drift")
    entries_raw = value["entries"]
    if not isinstance(entries_raw, list) or len(entries_raw) != EXPECTED_SOURCE_COUNT:
        raise MaintenanceRefused("baseline must contain exactly 58 entries")
    entries: list[_Entry] = []
    destinations: set[str] = set()
    allowed_entry_keys = {"source", "destination", "dev", "inode", "uid", "gid", "mode", "nlink", "size", "sha256"}
    for item in entries_raw:
        if not isinstance(item, dict) or set(item) != allowed_entry_keys:
            raise MaintenanceRefused("baseline entry shape drift")
        destination = item["destination"]
        pure = PurePosixPath(destination) if isinstance(destination, str) else PurePosixPath(".")
        if not isinstance(destination, str) or not pure.is_absolute() or str(pure) != destination or not destination.startswith(PRODUCTION_ROOT + "/"):
            raise MaintenanceRefused("baseline destination drift")
        if destination in destinations:
            raise MaintenanceRefused("duplicate baseline destination")
        destinations.add(destination)
        if not isinstance(item["source"], str) or not item["source"] or "\\" in item["source"] or "\x00" in item["source"]:
            raise MaintenanceRefused("baseline source name drift")
        for key in ("dev", "inode", "uid", "gid", "nlink", "size"):
            if type(item[key]) is not int or item[key] < 0:
                raise MaintenanceRefused("baseline metadata type drift")
        if item["uid"] != 0 or item["gid"] != 0 or item["nlink"] != 1 or item["mode"] not in {"0o644", "0o755"}:
            raise MaintenanceRefused("baseline ownership/mode drift")
        if not isinstance(item["sha256"], str) or not SHA_RE.fullmatch(item["sha256"]):
            raise MaintenanceRefused("baseline digest drift")
        entries.append(_Entry(item["source"], destination, item["dev"], item["inode"], item["uid"], item["gid"], int(item["mode"], 8), item["nlink"], item["size"], item["sha256"]))
    if len(destinations) != EXPECTED_SOURCE_COUNT:
        raise MaintenanceRefused("baseline destination count drift")
    payloads = value["payloads"]
    if not isinstance(payloads, dict) or set(payloads) != set(TARGET_ORDER):
        raise MaintenanceRefused("baseline payload target set drift")
    normalized_payloads: dict[str, dict[str, Any]] = {}
    for destination in TARGET_ORDER:
        item = payloads[destination]
        if not isinstance(item, dict) or set(item) != {"sha256", "size"} or not SHA_RE.fullmatch(item["sha256"]) or type(item["size"]) is not int or item["size"] <= 0 or item["size"] > MAX_PAYLOAD_BYTES:
            raise MaintenanceRefused("baseline payload pin drift")
        if item != PAYLOADS[destination]:
            raise MaintenanceRefused("compiled payload pin differs from baseline")
        normalized_payloads[destination] = dict(item)
    proofs = value["prior_terminals"]
    if not isinstance(proofs, list) or len(proofs) != 3:
        raise MaintenanceRefused("baseline must contain exactly three prior proofs")
    prior: list[_Proof] = []
    for item in proofs:
        if not isinstance(item, dict) or set(item) != {"path", "sha256", "status"} or not isinstance(item["path"], str) or not SHA_RE.fullmatch(item["sha256"]) or not isinstance(item["status"], str):
            raise MaintenanceRefused("prior proof shape drift")
        prior.append(_Proof(item["path"], item["sha256"], item["status"]))
    parked = value["parked_old"]
    parked_keys = {"dev", "gid", "inode", "mode", "mtime_ns", "nlink", "path", "sha256", "size", "uid"}
    if not isinstance(parked, dict) or set(parked) != parked_keys or parked != {
        "dev": 64769, "gid": 0, "inode": 3742939, "mode": "0o644", "mtime_ns": 1790898330785327108,
        "nlink": 1, "path": "/opt/poc-k8s-fabric/studies/p004/ovn/.p004-runtime-selftest-f3eef7bc468b4d3d8415750c6d93472f.tmp",
        "sha256": "1979880abee1580613175a7c1f0b43da8d1497bbd7150ab97bb3334f80741571", "size": 112287, "uid": 0,
    }:
        raise MaintenanceRefused("parked old pin drift")
    h4_raw = value["h4_pins"]
    if not isinstance(h4_raw, dict) or set(h4_raw) != set(H4_PINS):
        raise MaintenanceRefused("H4 pin path set drift")
    h4: dict[str, tuple[int, int, int]] = {}
    for path in H4_PINS:
        item = h4_raw[path]
        if not isinstance(item, dict) or set(item) != {"dev", "gid", "inode", "mode", "uid"}:
            raise MaintenanceRefused("H4 pin shape drift")
        observed = (item["dev"], item["inode"], int(item["mode"], 8)) if type(item["dev"]) is int and type(item["inode"]) is int and isinstance(item["mode"], str) else None
        if observed != H4_PINS[path] or item["uid"] != 0 or item["gid"] != 0:
            raise MaintenanceRefused("H4 pin value drift")
        h4[path] = observed
    lock = value["canonical_lock"]
    if not isinstance(lock, dict) or set(lock) != {"dev", "gid", "inode", "mode", "nlink", "path", "sha256", "size", "uid"}:
        raise MaintenanceRefused("canonical lock shape drift")
    if lock != {"dev": 28, "gid": 0, "inode": 7, "mode": "0o600", "nlink": 1, "path": PRODUCTION_LOCK, "sha256": LOCK_SHA256, "size": 0, "uid": 0}:
        raise MaintenanceRefused("canonical lock pin drift")
    return _Baseline(
        BASELINE_SHA256,
        tuple(entries),
        normalized_payloads,
        tuple(TARGET_ORDER),
        tuple(prior),
        dict(parked),
        h4,
        dict(lock),
        tuple(PRODUCTION_MARKERS),
        PRODUCTION_STORE,
        value["installation_acceptance_sha256"],
        value["old_helper_sha256"],
        value["publisher_sha256"],
        value["source_candidate_sha256"],
        value["source_archive_sha256"],
        value["source_manifest_sha256"],
    )


def _load_assets(script_path: str | None = None) -> _Assets:
    path = script_path or os.path.abspath(__file__)
    code = _bootstrap_code_context(path)
    module_name = "p004_stage_reviewed_sources_for_four_target_maintenance_" + format(id(code), "x")
    registered_module: ModuleType | None = None
    try:
        baseline_raw = _read_code_file(code, BASELINE_NAME, expected_sha256=BASELINE_SHA256)
        publisher_raw = _read_code_file(code, PUBLISHER_NAME, expected_sha256=PUBLISHER_SHA256)
        old_helper = _read_code_file(code, OLD_HELPER_NAME, expected_sha256=OLD_HELPER_SHA256, modes=(0o600, 0o644))
        if module_name in sys.modules:
            raise MaintenanceRefused("pinned publisher module name is already registered")
        publisher = ModuleType(module_name)
        publisher.__file__ = code.code_root + "/" + PUBLISHER_NAME
        sys.modules[module_name] = publisher
        registered_module = publisher
        try:
            exec(compile(publisher_raw, publisher.__file__, "exec"), publisher.__dict__)
        except BaseException:
            if sys.modules.get(module_name) is registered_module:
                sys.modules.pop(module_name, None)
            raise
        baseline = _parse_baseline(baseline_raw)
        helper_raw = _read_code_file(code, PurePosixPath(path).name, modes=(0o600, 0o644), maximum=2 * 1024 * 1024)
        return _Assets(code, publisher, baseline, old_helper, module_name, hashlib.sha256(helper_raw).hexdigest())
    except BaseException:
        if registered_module is not None and sys.modules.get(module_name) is registered_module:
            sys.modules.pop(module_name, None)
        code.close()
        raise


def _production_config(assets: _Assets) -> _RuntimeConfig:
    stage = assets.publisher._production_config()
    stage = dataclasses.replace(stage, store=PRODUCTION_STORE, archive_sha256=SOURCE_ARCHIVE_SHA256, manifest_sha256=SOURCE_MANIFEST_SHA256)
    return _RuntimeConfig(stage, H4_PINS, assets.code.code_root, False)


def _verify_assets(assets: _Assets) -> None:
    _read_code_file(assets.code, BASELINE_NAME, expected_sha256=BASELINE_SHA256)
    _read_code_file(assets.code, PUBLISHER_NAME, expected_sha256=PUBLISHER_SHA256)
    _read_code_file(assets.code, OLD_HELPER_NAME, expected_sha256=OLD_HELPER_SHA256, modes=(0o600, 0o644))
    helper_raw = _read_code_file(assets.code, PurePosixPath(__file__).name, modes=(0o600, 0o644), maximum=2 * 1024 * 1024)
    if hashlib.sha256(helper_raw).hexdigest() != assets.helper_sha256:
        raise MaintenanceRefused("helper source changed after bootstrap")


def _secure_directory(fd: int, label: str, exact_mode: int | None = None) -> os.stat_result:
    info = os.fstat(fd)
    if not stat.S_ISDIR(info.st_mode) or (info.st_uid, info.st_gid) != (0, 0):
        raise MaintenanceRefused("directory identity drift: " + label)
    if info.st_mode & 0o022:
        raise MaintenanceRefused("directory writable by group/other: " + label)
    if exact_mode is not None and stat.S_IMODE(info.st_mode) != exact_mode:
        raise MaintenanceRefused("directory mode drift: " + label)
    _reject_acl_fd(fd, label)
    return info


def _map_path(config: _RuntimeConfig, path: str) -> str:
    if not config.is_fixture:
        return path
    if path == PRODUCTION_ROOT:
        return config.directories_config.root
    if path.startswith(PRODUCTION_ROOT + "/"):
        return config.directories_config.root + path[len(PRODUCTION_ROOT):]
    return path


def _entry_parent(config: _RuntimeConfig, destination: str, directories: Any) -> tuple[int, str]:
    path = PurePosixPath(_map_path(config, destination))
    parent_fd = directories.hold_directory(str(path.parent))
    if parent_fd is None:
        raise MaintenanceRefused("target parent is absent: " + str(path.parent))
    return parent_fd, path.name


def _ensure_absent(parent_fd: int, name: str, label: str) -> None:
    try:
        os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    raise MaintenanceRefused("path must be absent: " + label)


def _verify_pinned_entry(parent_fd: int, entry: _Entry, *, destination: str | None = None) -> tuple[bytes, os.stat_result]:
    path = destination or entry.destination
    return _read_file_at(
        parent_fd,
        PurePosixPath(path).name,
        label=path,
        expected_sha256=entry.sha256,
        expected_size=entry.size,
        expected_metadata={"dev": entry.dev, "inode": entry.inode, "uid": entry.uid, "gid": entry.gid, "mode": entry.mode, "nlink": entry.nlink},
        allowed_modes=(entry.mode,),
        maximum=max(entry.size, 1),
    )


def _metadata(info: os.stat_result, digest: str) -> dict[str, Any]:
    return {
        "dev": info.st_dev, "inode": info.st_ino, "uid": info.st_uid, "gid": info.st_gid,
        "mode": oct(stat.S_IMODE(info.st_mode)), "nlink": info.st_nlink, "size": info.st_size,
        "mtime_ns": info.st_mtime_ns, "sha256": digest,
    }


def _verify_h4(config: _RuntimeConfig, directories: Any) -> None:
    directories.revalidate()
    for path, (device, inode, mode) in config.ancestor_pins.items():
        fd = directories.hold_directory(path)
        if fd is None:
            raise MaintenanceRefused("H4 directory is absent: " + path)
        info = _secure_directory(fd, path, exact_mode=mode)
        if (info.st_dev, info.st_ino) != (device, inode):
            raise MaintenanceRefused("H4 directory identity drift: " + path)


def _check_markers(config: _RuntimeConfig, directories: Any) -> None:
    for marker in config.directories_config.markers:
        parent = str(PurePosixPath(marker).parent)
        parent_fd = directories.hold_directory(parent, required=False)
        if parent_fd is None:
            continue
        _ensure_absent(parent_fd, PurePosixPath(marker).name, marker)


def _verify_lock_fd(config: _RuntimeConfig, directories: Any, fd: int) -> None:
    lock_config = config.directories_config
    parent = str(PurePosixPath(lock_config.lock_path).parent)
    parent_fd = directories.hold_directory(parent)
    if parent_fd is None:
        raise MaintenanceRefused("canonical lock parent is absent")
    info = os.fstat(fd)
    named = os.stat(PurePosixPath(lock_config.lock_path).name, dir_fd=parent_fd, follow_symlinks=False)
    if not stat.S_ISREG(info.st_mode) or (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode), info.st_nlink) != (0, 0, 0o600, 1):
        raise MaintenanceRefused("canonical lock metadata drift")
    if (info.st_dev, info.st_ino) != lock_config.lock_identity or (named.st_dev, named.st_ino) != (info.st_dev, info.st_ino):
        raise MaintenanceRefused("canonical lock identity drift")
    _reject_acl_fd(fd, lock_config.lock_path)
    os.lseek(fd, 0, os.SEEK_SET)
    digest = _digest_fd(fd)
    os.lseek(fd, 0, os.SEEK_SET)
    after = os.fstat(fd)
    named_after = os.stat(PurePosixPath(lock_config.lock_path).name, dir_fd=parent_fd, follow_symlinks=False)
    if _stat_signature(info) != _stat_signature(after) or (named_after.st_dev, named_after.st_ino) != (after.st_dev, after.st_ino) or digest != lock_config.lock_sha256:
        raise MaintenanceRefused("canonical lock bytes changed")
    _reject_acl_fd(fd, lock_config.lock_path)


def _acquire_lock(config: _RuntimeConfig, directories: Any) -> _Lock:
    try:
        config_obj = config.directories_config
        parent = str(PurePosixPath(config_obj.lock_path).parent)
        parent_fd = directories.hold_directory(parent)
        if parent_fd is None:
            raise MaintenanceRefused("canonical lock parent is absent")
        name = PurePosixPath(config_obj.lock_path).name
        fd = os.open(name, FILE_READ_FLAGS, dir_fd=parent_fd)
    except OSError as error:
        raise MaintenanceRefused("cannot open canonical lock") from error
    try:
        _verify_lock_fd(config, directories, fd)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            if error.errno in {errno.EACCES, errno.EAGAIN}:
                raise MaintenanceRefused("canonical lock is held by another process") from error
            raise MaintenanceRefused("canonical lock cannot be acquired") from error
        _verify_lock_fd(config, directories, fd)
        return _Lock(config, directories, fd)
    except BaseException:
        os.close(fd)
        raise


def _verify_proof(directories: Any, proof: _Proof) -> dict[str, Any]:
    parent = directories.hold_directory(str(PurePosixPath(proof.path).parent))
    if parent is None:
        raise MaintenanceRefused("prior proof parent is absent")
    raw, info = _read_file_at(parent, PurePosixPath(proof.path).name, label=proof.path, expected_sha256=proof.sha256, allowed_modes=(0o600,), maximum=1024 * 1024)
    value = _safe_json(raw, proof.path)
    if not isinstance(value, dict) or value.get("status") != proof.status:
        raise MaintenanceRefused("prior proof status drift: " + proof.path)
    return {"path": proof.path, "status": proof.status, **_metadata(info, proof.sha256)}


def _verify_parked_baseline(config: _RuntimeConfig, baseline: _Baseline, directories: Any) -> dict[str, Any]:
    path = str(_map_path(config, str(baseline.parked_old["path"])))
    parent = directories.hold_directory(str(PurePosixPath(path).parent))
    if parent is None:
        raise MaintenanceRefused("parked original parent is absent")
    entry = _Entry("parked-old", path, baseline.parked_old["dev"], baseline.parked_old["inode"], baseline.parked_old["uid"], baseline.parked_old["gid"], int(baseline.parked_old["mode"], 8), baseline.parked_old["nlink"], baseline.parked_old["size"], baseline.parked_old["sha256"])
    raw, info = _verify_pinned_entry(parent, entry, destination=path)
    if info.st_mtime_ns != baseline.parked_old["mtime_ns"]:
        raise MaintenanceRefused("parked original mtime drift")
    return _metadata(info, hashlib.sha256(raw).hexdigest())


def _verify_new_file(parent_fd: int, name: str, payload: bytes, digest: str, publisher: ModuleType, label: str, expected_identity: tuple[int, int] | None = None) -> dict[str, Any]:
    verified = publisher._verify_file(parent_fd, name, payload, digest, 0o644, label)
    raw, info = _read_file_at(parent_fd, name, label=label, expected_sha256=digest, expected_size=len(payload), expected_metadata={"dev": verified["dev"], "inode": verified["inode"], "uid": 0, "gid": 0, "mode": 0o644, "nlink": 1}, allowed_modes=(0o644,), maximum=MAX_PAYLOAD_BYTES)
    if expected_identity is not None and (info.st_dev, info.st_ino) != expected_identity:
        raise MaintenanceRefused("new payload inode changed: " + label)
    return {**verified, "mtime_ns": info.st_mtime_ns, "size": len(raw)}


def _verify_targets(ctx: _Context) -> None:
    for destination in TARGET_ORDER:
        target = ctx.targets[destination]
        if target.phase in {"ORIGINAL", "STAGED"}:
            _old_raw, old_info = _verify_pinned_entry(target.parent_fd, target.entry, destination=target.name)
            if old_info.st_mtime_ns != target.old_mtime_ns:
                raise MaintenanceRefused("original target mtime changed: " + destination)
        if target.phase == "ORIGINAL":
            _ensure_absent(target.parent_fd, target.temp_name, destination + " temporary")
        elif target.phase == "STAGED":
            _verify_new_file(target.parent_fd, target.temp_name, target.payload, target.digest, ctx.assets.publisher, destination + " temporary", target.new_identity)
        elif target.phase == "EXCHANGED":
            _verify_new_file(target.parent_fd, target.name, target.payload, target.digest, ctx.assets.publisher, destination, target.new_identity)
            parked_entry = dataclasses.replace(target.entry, destination=target.temp_name)
            raw, info = _verify_pinned_entry(target.parent_fd, parked_entry, destination=target.temp_name)
            if info.st_mtime_ns != target.old_mtime_ns or raw != target.old_payload:
                raise MaintenanceRefused("parked target original changed: " + destination)
        else:
            raise MaintenanceRefused("unknown target phase")


def _verify_protected(ctx: _Context) -> None:
    targets = set(TARGET_ORDER)
    count = 0
    for entry in ctx.baseline.entries:
        if entry.destination in targets:
            continue
        parent, name = _entry_parent(ctx.config, entry.destination, ctx.directories)
        _read_file_at(parent, name, label=entry.destination, expected_sha256=entry.sha256, expected_size=entry.size, expected_metadata={"dev": entry.dev, "inode": entry.inode, "uid": entry.uid, "gid": entry.gid, "mode": entry.mode, "nlink": entry.nlink}, allowed_modes=(entry.mode,), maximum=max(entry.size, 1))
        count += 1
    if count != PROTECTED_SOURCE_COUNT:
        raise MaintenanceRefused("protected source count drift")


def _verify_all(ctx: _Context) -> None:
    ctx.assets.code.revalidate()
    _verify_assets(ctx.assets)
    if ctx.provenance is not None:
        parent_metadata = dict(ctx.provenance.parent_metadata)
        _read_file_at(
            ctx.assets.code.directory_fd,
            PARENT_INTENT_NAME,
            label=PARENT_INTENT_NAME,
            expected_sha256=ctx.provenance.parent_sha256,
            expected_size=parent_metadata["size"],
            expected_metadata=parent_metadata,
            allowed_modes=(0o600,),
            maximum=1024 * 1024,
        )
        remote_metadata = dict(ctx.provenance.remote_metadata)
        _read_file_at(
            ctx.assets.code.directory_fd,
            ctx.provenance.remote_name,
            label=ctx.provenance.remote_name,
            expected_sha256=ctx.provenance.remote_sha256,
            expected_size=remote_metadata["size"],
            expected_metadata=remote_metadata,
            allowed_modes=(0o600,),
            maximum=1024 * 1024,
        )
    ctx.directories.revalidate()
    ctx.lock.check()
    _check_markers(ctx.config, ctx.directories)
    _verify_h4(ctx.config, ctx.directories)
    _verify_protected(ctx)
    if len(ctx.baseline.prior_terminals) != 3:
        raise MaintenanceRefused("prior proof count drift")
    for proof in ctx.baseline.prior_terminals:
        _verify_proof(ctx.directories, proof)
    _verify_parked_baseline(ctx.config, ctx.baseline, ctx.directories)
    _verify_targets(ctx)
    store_parent = ctx.directories.hold_directory(str(PurePosixPath(ctx.config.directories_config.store).parent))
    if store_parent is None:
        raise MaintenanceRefused("maintenance store parent is absent")
    store_name = PurePosixPath(ctx.config.directories_config.store).name
    if ctx.store_ready:
        store_fd = ctx.directories.hold_directory(ctx.config.directories_config.store)
        if store_fd is None:
            raise MaintenanceUnknown("maintenance store disappeared")
        _secure_directory(store_fd, ctx.config.directories_config.store, exact_mode=0o700)
    else:
        _ensure_absent(store_parent, store_name, ctx.config.directories_config.store)


def _rename_exchange(parent_fd: int, target_name: str, temp_name: str) -> None:
    function = getattr(ctypes.CDLL(None, use_errno=True), "renameat2", None)
    if function is None:
        raise OSError(errno.ENOSYS, "renameat2 is unavailable")
    function.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    function.restype = ctypes.c_int
    result = function(parent_fd, os.fsencode(target_name), parent_fd, os.fsencode(temp_name), RENAME_EXCHANGE)
    if result != 0:
        number = ctypes.get_errno() or errno.EIO
        raise OSError(number, os.strerror(number), temp_name)


def _probe_exchange(parent_fd: int) -> None:
    try:
        _rename_exchange(parent_fd, "", "")
    except OSError as error:
        if error.errno != errno.ENOENT:
            raise MaintenanceRefused("renameat2 RENAME_EXCHANGE preflight failed") from error
    else:
        raise MaintenanceRefused("renameat2 accepted empty exchange names")


def _write_payload(parent_fd: int, name: str, payload: bytes, digest: str, publisher: ModuleType, label: str) -> dict[str, Any]:
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
                raise OSError(errno.EIO, "short payload write")
            view = view[written:]
        os.fchown(fd, 0, 0)
        os.fchmod(fd, 0o644)
        os.fsync(fd)
        info = os.fstat(fd)
        if (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode), info.st_nlink) != (0, 0, 0o644, 1) or not stat.S_ISREG(info.st_mode):
            raise MaintenanceUnknown("staged payload metadata drift")
        _reject_acl_fd(fd, label)
    finally:
        os.close(fd)
    os.fsync(parent_fd)
    verified = _verify_new_file(parent_fd, name, payload, digest, publisher, label)
    return verified


class _Ledger:
    def __init__(self, publisher: ModuleType, directory_fd: int, attempt: str, baseline: _Baseline, payloads: Mapping[str, bytes]) -> None:
        self.writer = publisher._Ledger(directory_fd, attempt)
        self.directory_fd = directory_fd
        self.attempt = attempt
        self.baseline = baseline
        self.payloads = payloads
        self.sequence = 0
        self.failed_step: str | None = None

    def write(self, name: str, record: Mapping[str, Any]) -> None:
        self.writer.write(name, record)

    def begin(self) -> None:
        self.write(
            "run-" + self.attempt + ".intent.json",
            {
                "schema": "p004-runtime-source-maintenance-intent-v3",
                "status": "INTENT_DURABLE",
                "attempt": self.attempt,
                "canonical_root": PRODUCTION_ROOT if not self.baseline.is_fixture else "fixture",
                "store": self.baseline.store,
                "target_order": list(TARGET_ORDER),
                "payloads": {key: dict(value) for key, value in self.baseline.payloads.items()},
                "source_entries_verified": EXPECTED_SOURCE_COUNT,
                "protected_entries": PROTECTED_SOURCE_COUNT,
                "effect_count": 8,
                "automatic_retry": False,
                "automatic_cleanup": False,
                "automatic_rollback": False,
                "actual_X05": "NOT_RUN",
            },
        )

    def intent(self, operation: str, target: str, sha256: str | None = None) -> int:
        self.sequence += 1
        self.write(
            "run-" + self.attempt + "-effect-" + format(self.sequence, "03d") + ".intent.json",
            {
                "schema": "p004-runtime-source-maintenance-effect-intent-v3",
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
            "schema": "p004-runtime-source-maintenance-effect-result-v3",
            "attempt": self.attempt,
            "sequence": sequence,
            "operation": operation,
            "target": target,
            "status": status,
            "details": dict(details),
        }
        if error is not None:
            record["error"] = {"type": type(error).__name__, "message": str(error)[:500]}
        self.write("run-" + self.attempt + "-effect-" + format(sequence, "03d") + ".result.json", record)
        if status != "PROVED":
            self.failed_step = operation

    def terminal(self, status: str, error: BaseException | None = None, details: Mapping[str, Any] | None = None) -> None:
        record: dict[str, Any] = {
            "schema": "p004-runtime-source-maintenance-terminal-v3",
            "attempt": self.attempt,
            "status": status,
            "failed_step": self.failed_step,
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
        self.write("run-" + self.attempt + ".terminal.json", record)


class _EffectProxy:
    def __init__(self, ctx: _Context) -> None:
        self.ctx = ctx
        self.config = ctx.directories.config

    @property
    def fds(self) -> dict[str, int]:
        return self.ctx.directories.fds

    def __getattr__(self, name: str) -> Any:
        return getattr(self.ctx.directories, name)

    def revalidate(self) -> None:
        self.ctx.directories.revalidate()
        _verify_all(self.ctx)

    def check_markers(self) -> None:
        _check_markers(self.ctx.config, self.ctx.directories)


def _effect(
    ctx: _Context,
    ledger: _Ledger,
    *,
    operation: str,
    target: str,
    action: Callable[[], Mapping[str, Any]],
    hook: Callable[[str, Mapping[str, Any]], None] | None,
    sha256: str | None,
) -> Mapping[str, Any]:
    proxy = _EffectProxy(ctx)
    return ctx.assets.publisher._effect(proxy, ledger, operation=operation, target=target, action=action, hook=hook, sha256=sha256)


def _capture_targets(ctx: _Context) -> None:
    by_destination = {entry.destination: entry for entry in ctx.baseline.entries}
    if set(by_destination) != {entry.destination for entry in ctx.baseline.entries} or any(destination not in by_destination for destination in TARGET_ORDER):
        raise MaintenanceRefused("target baseline set drift")
    for index, destination in enumerate(TARGET_ORDER):
        entry = by_destination[destination]
        digest = ctx.baseline.payloads[destination]["sha256"]
        payload = ctx.payloads[PurePosixPath(destination).name]
        if hashlib.sha256(payload).hexdigest() != digest or len(payload) != ctx.baseline.payloads[destination]["size"]:
            raise MaintenanceRefused("payload does not match accepted target pin")
        parent_fd, name = _entry_parent(ctx.config, destination, ctx.directories)
        old_payload, old_info = _verify_pinned_entry(parent_fd, entry, destination=name)
        temp_name = ".p004-runtime-source-" + ctx.attempt + "-" + format(index + 1, "02d") + ".tmp"
        _ensure_absent(parent_fd, temp_name, destination + " temporary")
        ctx.targets[destination] = _Target(destination, entry, payload, digest, parent_fd, name, temp_name, old_payload, old_info.st_mtime_ns)


def _prepare_context(assets: _Assets, config: _RuntimeConfig, baseline: _Baseline, payloads: Mapping[str, bytes], attempt: str, provenance: _Provenance | None = None) -> _Context:
    if platform.system() != "Linux" or os.geteuid() != 0 or os.getegid() != 0:
        raise MaintenanceRefused("maintenance requires Linux root:root execution")
    if not ATTEMPT_RE.fullmatch(attempt):
        raise MaintenanceRefused("attempt must be exactly 32 lowercase hexadecimal characters")
    expected_names = set(PAYLOAD_BASENAMES)
    if set(payloads) != expected_names:
        raise MaintenanceRefused("payload basename set drift")
    directories = assets.publisher._Directories(config.directories_config)
    lock: _Lock | None = None
    try:
        for path in (config.directories_config.root, config.directories_config.root + "/evidence", config.directories_config.root + "/evidence/P004", config.directories_config.root + "/evidence/P004/S002"):
            directories.hold_directory(path)
        for entry in baseline.entries:
            _entry_parent(config, entry.destination, directories)
        for proof in baseline.prior_terminals:
            directories.hold_directory(str(PurePosixPath(proof.path).parent))
        directories.hold_directory(str(PurePosixPath(_map_path(config, str(baseline.parked_old["path"]))).parent))
        directories.hold_directory(str(PurePosixPath(config.directories_config.store).parent))
        directories.hold_directory(str(PurePosixPath(config.directories_config.lock_path).parent))
        _check_markers(config, directories)
        _verify_h4(config, directories)
        _verify_parked_baseline(config, baseline, directories)
        for proof in baseline.prior_terminals:
            _verify_proof(directories, proof)
        parent_fd = directories.fds[str(PurePosixPath(config.directories_config.lock_path).parent)]
        _probe_exchange(parent_fd)
        lock = _acquire_lock(config, directories)
        ctx = _Context(assets, config, baseline, directories, lock, {}, payloads, attempt, provenance)
        _capture_targets(ctx)
        _verify_all(ctx)
        return ctx
    except BaseException:
        if lock is not None:
            lock.close()
        directories.close()
        raise


def _prepare_store(ctx: _Context) -> int:
    _verify_all(ctx)
    path = ctx.config.directories_config.store
    parent = str(PurePosixPath(path).parent)
    parent_fd = ctx.directories.hold_directory(parent)
    if parent_fd is None:
        raise MaintenanceUnknown("store parent disappeared")
    name = PurePosixPath(path).name
    _ensure_absent(parent_fd, name, path)
    created = False
    store_fd: int | None = None
    try:
        old_mask = os.umask(0)
        try:
            os.mkdir(name, 0o700, dir_fd=parent_fd)
            created = True
        finally:
            os.umask(old_mask)
        os.fsync(parent_fd)
        store_fd = os.open(name, DIRECTORY_FLAGS, dir_fd=parent_fd)
        info = _secure_directory(store_fd, path, exact_mode=0o700)
        named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if (named.st_dev, named.st_ino) != (info.st_dev, info.st_ino):
            raise MaintenanceUnknown("store name changed after mkdir")
        ctx.directories.fds[path] = os.dup(store_fd)
        ctx.store_ready = True
        _verify_all(ctx)
        return store_fd
    except BaseException as error:
        if store_fd is not None:
            try:
                os.close(store_fd)
            except OSError:
                pass
        if created:
            raise MaintenanceUnknown("store creation is ambiguous and retained") from error
        raise


def _verify_input(payloads: Mapping[str, bytes], baseline: _Baseline) -> None:
    if set(payloads) != set(PAYLOAD_BASENAMES):
        raise MaintenanceRefused("stdin payload names are not exactly the four accepted basenames")
    for destination in TARGET_ORDER:
        name = PurePosixPath(destination).name
        payload = payloads[name]
        expected = baseline.payloads[destination]
        if not isinstance(payload, bytes) or len(payload) == 0 or len(payload) > MAX_PAYLOAD_BYTES:
            raise MaintenanceRefused("payload size is outside the fixed bound")
        if hashlib.sha256(payload).hexdigest() != expected["sha256"] or len(payload) != expected["size"]:
            raise MaintenanceRefused("payload hash/size does not match the frozen candidate")


def _actual_helper_sha(assets: _Assets) -> str:
    _verify_assets(assets)
    return assets.helper_sha256


def _provenance_fields(assets: _Assets, baseline: _Baseline, attempt: str, payloads: Mapping[str, bytes]) -> dict[str, Any]:
    return {
        "schema": PROVENANCE_SCHEMA,
        "attempt": attempt,
        "mode": "apply",
        "canonical_root": PRODUCTION_ROOT,
        "store": PRODUCTION_STORE,
        "target_order": list(TARGET_ORDER),
        "payloads": {destination: dict(baseline.payloads[destination]) for destination in TARGET_ORDER},
        "baseline_sha256": baseline.sha256,
        "helper_sha256": _actual_helper_sha(assets),
        "publisher_sha256": PUBLISHER_SHA256,
        "old_helper_sha256": OLD_HELPER_SHA256,
        "source_candidate_sha256": SOURCE_CANDIDATE_SHA256,
        "source_archive_sha256": SOURCE_ARCHIVE_SHA256,
        "source_manifest_sha256": SOURCE_MANIFEST_SHA256,
        "automatic_retry": False,
        "automatic_cleanup": False,
        "automatic_rollback": False,
        "actual_X05": "NOT_RUN",
    }


def _parse_provenance(raw: bytes, label: str, keys: set[str]) -> dict[str, Any]:
    value = _safe_json(raw, label)
    if not isinstance(value, dict) or set(value) != keys:
        raise MaintenanceRefused(label + " shape drift")
    return value


def _exact_json_value(observed: Any, expected: Any) -> bool:
    if type(observed) is not type(expected):
        return False
    if isinstance(expected, dict):
        return set(observed) == set(expected) and all(_exact_json_value(observed[key], expected[key]) for key in expected)
    if isinstance(expected, list):
        return len(observed) == len(expected) and all(_exact_json_value(item, wanted) for item, wanted in zip(observed, expected))
    return observed == expected


def _verify_provenance(assets: _Assets, baseline: _Baseline, attempt: str) -> _Provenance:
    if not ATTEMPT_RE.fullmatch(attempt):
        raise MaintenanceRefused("attempt must be exactly 32 lowercase hexadecimal characters")
    assets.code.revalidate()
    parent_raw, parent_info = _read_file_at(assets.code.directory_fd, PARENT_INTENT_NAME, label=PARENT_INTENT_NAME, allowed_modes=(0o600,), maximum=1024 * 1024)
    parent_sha = hashlib.sha256(parent_raw).hexdigest()
    base_keys = {
        "actual_X05", "attempt", "automatic_cleanup", "automatic_retry", "automatic_rollback",
        "baseline_sha256", "canonical_root", "helper_sha256", "mode", "old_helper_sha256",
        "payloads", "publisher_sha256", "schema", "source_archive_sha256",
        "source_candidate_sha256", "source_manifest_sha256", "store", "target_order",
    }
    parent = _parse_provenance(parent_raw, PARENT_INTENT_NAME, base_keys)
    remote_name = REMOTE_INTENT_PREFIX + attempt + REMOTE_INTENT_SUFFIX
    remote_raw, remote_info = _read_file_at(assets.code.directory_fd, remote_name, label=remote_name, allowed_modes=(0o600,), maximum=1024 * 1024)
    remote_keys = set(base_keys) | {"parent_intent_name", "parent_intent_sha256"}
    remote = _parse_provenance(remote_raw, remote_name, remote_keys)
    expected = _provenance_fields(assets, baseline, attempt, {})
    expected_remote = {
        **expected,
        "parent_intent_name": PARENT_INTENT_NAME,
        "parent_intent_sha256": parent_sha,
    }
    if not _exact_json_value(parent, expected):
        raise MaintenanceRefused("parent provenance value drift")
    if not _exact_json_value(remote, expected_remote):
        raise MaintenanceRefused("remote provenance value drift")
    assets.code.revalidate()
    return _Provenance(
        parent_sha,
        {"dev": parent_info.st_dev, "inode": parent_info.st_ino, "uid": parent_info.st_uid, "gid": parent_info.st_gid, "mode": stat.S_IMODE(parent_info.st_mode), "nlink": parent_info.st_nlink, "size": parent_info.st_size},
        remote_name,
        hashlib.sha256(remote_raw).hexdigest(),
        {"dev": remote_info.st_dev, "inode": remote_info.st_ino, "uid": remote_info.st_uid, "gid": remote_info.st_gid, "mode": stat.S_IMODE(remote_info.st_mode), "nlink": remote_info.st_nlink, "size": remote_info.st_size},
    )


def _stage_target(ctx: _Context, ledger: _Ledger, target: _Target, hook: Callable[[str, Mapping[str, Any]], None] | None) -> Mapping[str, Any]:
    def action() -> Mapping[str, Any]:
        _verify_all(ctx)
        created = _write_payload(target.parent_fd, target.temp_name, target.payload, target.digest, ctx.assets.publisher, target.destination + " temporary")
        target.new_identity = (created["dev"], created["inode"])
        target.phase = "STAGED"
        _verify_all(ctx)
        return {"temporary": target.temp_name, "new": created, "phase": target.phase}
    return _effect(ctx, ledger, operation="stage-" + PurePosixPath(target.destination).name, target=target.destination, action=action, hook=hook, sha256=target.digest)


def _exchange_target(ctx: _Context, ledger: _Ledger, target: _Target, hook: Callable[[str, Mapping[str, Any]], None] | None) -> Mapping[str, Any]:
    def action() -> Mapping[str, Any]:
        _verify_all(ctx)
        if target.new_identity is None or target.phase != "STAGED":
            raise MaintenanceRefused("exchange requires staged target")
        _rename_exchange(target.parent_fd, target.name, target.temp_name)
        os.fsync(target.parent_fd)
        target.phase = "EXCHANGED"
        _verify_all(ctx)
        new_target = _verify_new_file(target.parent_fd, target.name, target.payload, target.digest, ctx.assets.publisher, target.destination, target.new_identity)
        parked_entry = dataclasses.replace(target.entry, destination=target.temp_name)
        parked_raw, parked_info = _verify_pinned_entry(target.parent_fd, parked_entry, destination=target.temp_name)
        if parked_raw != target.old_payload or parked_info.st_mtime_ns != target.old_mtime_ns:
            raise MaintenanceUnknown("parked original readback drift")
        return {
            "new_target": new_target,
            "parked_old": {**_metadata(parked_info, hashlib.sha256(parked_raw).hexdigest()), "path": target.temp_name},
            "exchange_flags": RENAME_EXCHANGE,
            "phase": target.phase,
        }
    return _effect(ctx, ledger, operation="exchange-" + PurePosixPath(target.destination).name, target=target.destination, action=action, hook=hook, sha256=target.digest)


def _run_dry(assets: _Assets, config: _RuntimeConfig, baseline: _Baseline, payloads: Mapping[str, bytes], attempt: str) -> dict[str, Any]:
    _verify_input(payloads, baseline)
    ctx = _prepare_context(assets, config, baseline, payloads, attempt)
    try:
        return {
            "schema": "p004-runtime-source-maintenance-result-v3",
            "status": "PASS_DRY_RUN",
            "attempt": attempt,
            "target_order": list(TARGET_ORDER),
            "effect_count": 0,
            "planned_effect_count": 8,
            "source_entries_verified": EXPECTED_SOURCE_COUNT,
            "protected_entries": PROTECTED_SOURCE_COUNT,
            "payloads": {key: dict(value) for key, value in baseline.payloads.items()},
            "parked_old": dict(baseline.parked_old),
            "canonical_lock_changed": False,
            "receipt_created": False,
            "lab_mutation": False,
            "actual_X05": "NOT_RUN",
        }
    finally:
        ctx.lock.close()
        ctx.directories.close()


def _run_apply(
    assets: _Assets,
    config: _RuntimeConfig,
    baseline: _Baseline,
    payloads: Mapping[str, bytes],
    attempt: str,
    *,
    hook: Callable[[str, Mapping[str, Any]], None] | None = None,
) -> dict[str, Any]:
    _verify_input(payloads, baseline)
    if hook is not None and not config.is_fixture:
        raise MaintenanceRefused("fault hooks are available only for private fixtures")
    provenance: _Provenance | None = None
    if not config.is_fixture:
        provenance = _verify_provenance(assets, baseline, attempt)
    ctx: _Context | None = None
    store_fd: int | None = None
    ledger: _Ledger | None = None
    terminal_written = False
    try:
        ctx = _prepare_context(assets, config, baseline, payloads, attempt, provenance)
        store_fd = _prepare_store(ctx)
        ledger = _Ledger(assets.publisher, store_fd, attempt, baseline, payloads)
        ledger.begin()
        for destination in TARGET_ORDER:
            _stage_target(ctx, ledger, ctx.targets[destination], hook)
        exchange_details: list[Mapping[str, Any]] = []
        for destination in TARGET_ORDER:
            exchange_details.append(_exchange_target(ctx, ledger, ctx.targets[destination], hook))
        _verify_all(ctx)
        detail = {
            "target_phases": {destination: ctx.targets[destination].phase for destination in TARGET_ORDER},
            "exchange_results": [dict(item) for item in exchange_details],
            "source_entries_verified": EXPECTED_SOURCE_COUNT,
            "protected_entries": PROTECTED_SOURCE_COUNT,
        }
        ledger.terminal("PASS_UPDATED_FOUR_RUNTIME_SOURCES", details=detail)
        terminal_written = True
        return {
            "schema": "p004-runtime-source-maintenance-result-v3",
            "status": "PASS_UPDATED_FOUR_RUNTIME_SOURCES",
            "attempt": attempt,
            "target_order": list(TARGET_ORDER),
            "effect_count": 8,
            "source_entries_verified": EXPECTED_SOURCE_COUNT,
            "protected_entries": PROTECTED_SOURCE_COUNT,
            "payloads": {key: dict(value) for key, value in baseline.payloads.items()},
            "ledger": config.directories_config.store,
            "canonical_lock_changed": False,
            "receipt_created": False,
            "lab_mutation": False,
            "actual_X05": "NOT_RUN",
        }
    except BaseException as error:
        if ctx is not None and (ctx.store_ready or store_fd is not None):
            if ledger is not None and not terminal_written:
                try:
                    ledger.terminal("UNKNOWN_RETAINED_NO_RETRY", error=error)
                except BaseException:
                    pass
            raise MaintenanceUnknown("UNKNOWN retained at " + config.directories_config.store) from error
        raise
    finally:
        if store_fd is not None:
            try:
                os.close(store_fd)
            except OSError:
                pass
        if ctx is not None:
            ctx.lock.close()
            ctx.directories.close()


def _read_input() -> dict[str, bytes]:
    raw = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
    if len(raw) > MAX_INPUT_BYTES:
        raise MaintenanceRefused("stdin exceeds the 2MiB bound")
    value = _safe_json(raw, "stdin")
    if not isinstance(value, dict) or set(value) != {"schema", "payloads"} or value["schema"] != "p004-runtime-source-maintenance-input-v1":
        raise MaintenanceRefused("stdin top-level shape drift")
    payload_values = value["payloads"]
    if not isinstance(payload_values, dict) or set(payload_values) != set(PAYLOAD_BASENAMES):
        raise MaintenanceRefused("stdin must contain exactly the four fixed basenames")
    result: dict[str, bytes] = {}
    for name in PAYLOAD_BASENAMES:
        encoded = payload_values[name]
        if not isinstance(encoded, str) or not encoded or len(encoded) % 4 != 0 or any(character.isspace() for character in encoded):
            raise MaintenanceRefused("stdin payload is not strict base64")
        try:
            decoded = base64.b64decode(encoded.encode("ascii"), validate=True)
        except (ValueError, UnicodeEncodeError, binascii.Error) as error:
            raise MaintenanceRefused("stdin payload is not valid base64") from error
        if base64.b64encode(decoded).decode("ascii") != encoded:
            raise MaintenanceRefused("stdin payload is not canonical base64")
        if len(decoded) > MAX_PAYLOAD_BYTES:
            raise MaintenanceRefused("stdin payload exceeds the 512KiB bound")
        result[name] = decoded
    return result


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="four-target X05 source maintenance")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--dry-run", action="store_true")
    group.add_argument("--apply", metavar="ATTEMPT")
    return parser


def _emit(value: Mapping[str, Any]) -> None:
    sys.stdout.write(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")


def main(argv: list[str] | None = None) -> int:
    try:
        args = _build_parser().parse_args(argv)
        if args.apply is not None and not ATTEMPT_RE.fullmatch(args.apply):
            raise MaintenanceRefused("apply attempt must be exactly 32 lowercase hexadecimal characters")
        payloads = _read_input()
        assets = _load_assets()
        try:
            config = _production_config(assets)
            if args.dry_run:
                result = _run_dry(assets, config, assets.baseline, payloads, "00000000000000000000000000000000")
            else:
                result = _run_apply(assets, config, assets.baseline, payloads, args.apply)
            _emit(result)
            return 0
        finally:
            assets.close()
    except MaintenanceUnknown as error:
        _emit({"schema": "p004-runtime-source-maintenance-result-v3", "status": "UNKNOWN_RETAINED_NO_RETRY", "error": str(error), "automatic_retry": False, "automatic_cleanup": False, "automatic_rollback": False, "actual_X05": "NOT_RUN"})
        return 1
    except (MaintenanceRefused, OSError, ValueError) as error:
        _emit({"schema": "p004-runtime-source-maintenance-result-v3", "status": "REFUSED", "error": str(error), "automatic_retry": False, "automatic_cleanup": False, "automatic_rollback": False, "actual_X05": "NOT_RUN"})
        return 1


@dataclasses.dataclass
class _FixtureEnvironment:
    base: str
    assets: _Assets
    config: _RuntimeConfig
    baseline: _Baseline
    payloads: dict[str, bytes]


def _fixture_stage_config(assets: _Assets, base: str) -> Any:
    """Construct a private config from the publisher's pure production shape."""
    base_path = PurePosixPath(base)
    if base_path.parent != PurePosixPath("/var/tmp") or not base_path.name.startswith(FIXTURE_DIRECTORY_PREFIX):
        raise MaintenanceRefused("fixture base name is outside the private fixture namespace")
    root = base_path / "root"
    evidence = root / "evidence"
    p004 = evidence / "P004"
    s002 = p004 / "S002"
    markers_dir = base_path / "markers"
    lock_path = base_path / "lock"
    root_info = os.lstat(root)
    evidence_info = os.lstat(evidence)
    for item, mode in ((root, 0o755), (evidence, 0o755), (p004, 0o700), (s002, 0o700), (markers_dir, 0o755)):
        info = os.lstat(item)
        if not stat.S_ISDIR(info.st_mode) or (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != (0, 0, mode):
            raise MaintenanceRefused("fixture directory metadata drift: " + str(item))
    lock_fd = os.open(lock_path, FILE_READ_FLAGS)
    try:
        lock_info = os.fstat(lock_fd)
        if (lock_info.st_uid, lock_info.st_gid, stat.S_IMODE(lock_info.st_mode), lock_info.st_nlink) != (0, 0, 0o600, 1) or not stat.S_ISREG(lock_info.st_mode):
            raise MaintenanceRefused("fixture lock metadata drift")
        lock_sha = _digest_fd(lock_fd)
    finally:
        os.close(lock_fd)
    stage = assets.publisher._production_config()
    return dataclasses.replace(
        stage,
        root=str(root),
        store=str(base_path / "runtime-source-maintenance"),
        markers=(str(markers_dir / "mgc-m03-active"), str(markers_dir / "mgc-x05-active")),
        lock_path=str(lock_path),
        lock_identity=(lock_info.st_dev, lock_info.st_ino),
        lock_sha256=lock_sha,
        root_identity=(root_info.st_dev, root_info.st_ino),
        evidence_identity=(evidence_info.st_dev, evidence_info.st_ino),
        fixture_base=base,
    )


def _fixture_environment(base: str) -> _FixtureEnvironment:
    """Build an isolated Linux-only fixture; this is not a production override."""
    if platform.system() != "Linux" or os.geteuid() != 0 or os.getegid() != 0:
        raise MaintenanceRefused("fixture execution requires Linux root:root")
    path = PurePosixPath(base)
    if path.parent != PurePosixPath("/var/tmp") or not path.name.startswith(FIXTURE_DIRECTORY_PREFIX):
        raise MaintenanceRefused("fixture base name is outside the private fixture namespace")
    if os.path.exists(base):
        raise MaintenanceRefused("fixture base must be newly created")
    os.mkdir(base, 0o700)
    root = path / "root"
    evidence = root / "evidence"
    s002 = evidence / "P004" / "S002"
    markers = path / "markers"
    for item in (root, evidence, evidence / "P004", s002, s002 / "ovn", markers, path / "history-one", path / "history-two"):
        os.makedirs(item, mode=0o700 if item.name in {"P004", "S002"} else 0o755, exist_ok=True)
    for directory, mode in (
        (root, 0o755),
        (evidence, 0o755),
        (evidence / "P004", 0o700),
        (s002, 0o700),
        (markers, 0o755),
    ):
        os.chmod(directory, mode)
    lock = path / "lock"
    fd = os.open(lock, FILE_CREATE_FLAGS, 0o600)
    os.close(fd)
    assets = _load_assets()
    try:
        stage_config = _fixture_stage_config(assets, base)
        stage_config = dataclasses.replace(stage_config, store=str(path / "runtime-source-maintenance"))
        h4_pins = {
            str(root): (os.stat(root).st_dev, os.stat(root).st_ino, 0o755),
            str(evidence): (os.stat(evidence).st_dev, os.stat(evidence).st_ino, 0o755),
            str(evidence / "P004"): (os.stat(evidence / "P004").st_dev, os.stat(evidence / "P004").st_ino, 0o700),
            str(s002): (os.stat(s002).st_dev, os.stat(s002).st_ino, 0o700),
        }
        config = _RuntimeConfig(stage_config, h4_pins, assets.code.code_root, True)
        old_bytes: dict[str, bytes] = {}
        entries: list[_Entry] = []
        for index, item in enumerate(assets.baseline.entries):
            mapped = _map_path(config, item.destination)
            os.makedirs(str(PurePosixPath(mapped).parent), mode=0o755, exist_ok=True)
            if item.destination in TARGET_ORDER:
                content = ("fixture-old-" + PurePosixPath(item.destination).name + "\n").encode()
                old_bytes[item.destination] = content
            else:
                content = ("fixture-protected-" + format(index, "02d") + "\n").encode()
            parent_fd = os.open(str(PurePosixPath(mapped).parent), DIRECTORY_FLAGS)
            fd = os.open(PurePosixPath(mapped).name, FILE_CREATE_FLAGS, item.mode, dir_fd=parent_fd)
            try:
                os.write(fd, content)
                os.fchown(fd, 0, 0)
                os.fchmod(fd, item.mode)
                os.fsync(fd)
                info = os.fstat(fd)
            finally:
                os.close(fd)
                os.close(parent_fd)
            entries.append(_Entry(item.source, item.destination, info.st_dev, info.st_ino, 0, 0, item.mode, 1, len(content), hashlib.sha256(content).hexdigest()))
        history = (
            (str(path / "history-one" / "terminal.json"), "PROVED"),
            (str(path / "history-two" / "terminal.json"), "PASS_STAGED_SOURCE_ONLY"),
            (str(path / "history-one" / "runtime-terminal.json"), "PASS_UPDATED_RUNTIME_SELFTEST_ONLY"),
        )
        proofs: list[_Proof] = []
        for proof_path, status in history:
            parent = PurePosixPath(proof_path).parent
            os.makedirs(parent, mode=0o700, exist_ok=True)
            data = (json.dumps({"status": status}, separators=(",", ":")) + "\n").encode()
            proof_parent_fd = os.open(str(parent), DIRECTORY_FLAGS)
            fd = os.open(PurePosixPath(proof_path).name, FILE_CREATE_FLAGS, 0o600, dir_fd=proof_parent_fd)
            try:
                os.write(fd, data)
                os.fchown(fd, 0, 0)
                os.fchmod(fd, 0o600)
                os.fsync(fd)
            finally:
                os.close(fd)
                os.close(proof_parent_fd)
            proofs.append(_Proof(proof_path, hashlib.sha256(data).hexdigest(), status))
        parked_path = str(path / "root" / "studies" / "p004" / "ovn" / ".p004-runtime-source-fixture-old.tmp")
        os.makedirs(str(PurePosixPath(parked_path).parent), mode=0o755, exist_ok=True)
        old_runtime_selftest = old_bytes[TARGET_ORDER[2]]
        parked_parent_fd = os.open(str(PurePosixPath(parked_path).parent), DIRECTORY_FLAGS)
        fd = os.open(PurePosixPath(parked_path).name, FILE_CREATE_FLAGS, 0o644, dir_fd=parked_parent_fd)
        try:
            os.write(fd, old_runtime_selftest)
            os.fchown(fd, 0, 0)
            os.fchmod(fd, 0o644)
            os.fsync(fd)
            parked_info = os.fstat(fd)
        finally:
            os.close(fd)
            os.close(parked_parent_fd)
        payloads: dict[str, bytes] = {}
        for destination in TARGET_ORDER:
            payloads[PurePosixPath(destination).name] = ("fixture-new-" + PurePosixPath(destination).name + "\n").encode()
        canonical_parked = PRODUCTION_ROOT + "/studies/p004/ovn/.p004-runtime-source-fixture-old.tmp"
        parked = {
            "path": canonical_parked, "dev": parked_info.st_dev, "inode": parked_info.st_ino, "uid": 0, "gid": 0,
            "mode": "0o644", "nlink": 1, "size": len(old_runtime_selftest), "mtime_ns": parked_info.st_mtime_ns,
            "sha256": hashlib.sha256(old_runtime_selftest).hexdigest(),
        }
        payload_pins = {
            destination: {"sha256": hashlib.sha256(payloads[PurePosixPath(destination).name]).hexdigest(), "size": len(payloads[PurePosixPath(destination).name])}
            for destination in TARGET_ORDER
        }
        lock_info = os.stat(lock)
        baseline = _Baseline(
            "fixture-" + hashlib.sha256(base.encode()).hexdigest(),
            tuple(entries),
            payload_pins,
            TARGET_ORDER,
            tuple(proofs),
            parked,
            {str(root): (os.stat(root).st_dev, os.stat(root).st_ino, 0o755), str(evidence): (os.stat(evidence).st_dev, os.stat(evidence).st_ino, 0o755), str(evidence / "P004"): (os.stat(evidence / "P004").st_dev, os.stat(evidence / "P004").st_ino, 0o700), str(s002): (os.stat(s002).st_dev, os.stat(s002).st_ino, 0o700)},
            {"path": str(lock), "dev": lock_info.st_dev, "inode": lock_info.st_ino, "uid": 0, "gid": 0, "mode": "0o600", "nlink": 1, "size": 0, "sha256": LOCK_SHA256},
            (str(markers / "mgc-m03-active"), str(markers / "mgc-x05-active")),
            str(path / "runtime-source-maintenance"),
            "fixture-installation",
            OLD_HELPER_SHA256,
            PUBLISHER_SHA256,
            SOURCE_CANDIDATE_SHA256,
            SOURCE_ARCHIVE_SHA256,
            SOURCE_MANIFEST_SHA256,
            True,
        )
        assets.baseline = baseline
        return _FixtureEnvironment(base, assets, config, baseline, payloads)
    except BaseException:
        assets.close()
        raise


def _fixture_dry_run(environment: _FixtureEnvironment, attempt: str = "11111111111111111111111111111111") -> dict[str, Any]:
    return _run_dry(environment.assets, environment.config, environment.baseline, environment.payloads, attempt)


def _fixture_apply(environment: _FixtureEnvironment, attempt: str = "22222222222222222222222222222222", hook: Callable[[str, Mapping[str, Any]], None] | None = None) -> dict[str, Any]:
    return _run_apply(environment.assets, environment.config, environment.baseline, environment.payloads, attempt, hook=hook)


if __name__ == "__main__":
    raise SystemExit(main())
