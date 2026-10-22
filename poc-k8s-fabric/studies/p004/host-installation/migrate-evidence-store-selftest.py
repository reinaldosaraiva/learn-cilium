#!/usr/bin/env python3
"""Exercise the migration helper only against disposable /var/tmp fixtures."""

from __future__ import annotations

import argparse
import contextlib
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
from types import ModuleType
from typing import Any


HERE = Path(__file__).resolve().parent
HELPER_PATH = HERE / "migrate-evidence-store.py"
UID = 1000
GID = 1000
FIXTURE_ROOT = Path("/var/tmp")


def _load_helper() -> ModuleType:
    spec = importlib.util.spec_from_file_location("p004_migrate_evidence_store", HELPER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load migration helper")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


migration = _load_helper()


class Fixture:
    def __init__(self) -> None:
        self.base = Path(tempfile.mkdtemp(prefix=migration.FIXTURE_PREFIX, dir=FIXTURE_ROOT))
        os.chmod(self.base, 0o700)
        self.bundle = self.base / "bundle"
        self._populate()
        self.baseline = migration.capture_fixture_baseline(self.base)

    @staticmethod
    def _owned_directory(path: Path, uid: int = UID, gid: int = GID, mode: int = 0o755) -> None:
        os.mkdir(path, mode)
        os.chown(path, uid, gid)
        os.chmod(path, mode)

    @staticmethod
    def _owned_file(path: Path, data: bytes, uid: int = UID, gid: int = GID, mode: int = 0o644) -> None:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, mode)
        try:
            view = memoryview(data)
            while view:
                view = view[os.write(fd, view) :]
            os.fchown(fd, uid, gid)
            os.fchmod(fd, mode)
            os.fsync(fd)
        finally:
            os.close(fd)

    def _populate(self) -> None:
        self._owned_directory(self.bundle)
        self._owned_file(self.bundle / "README.md", b"isolated root fixture\n")
        for name in ("agent", "configs", "docs", "k8s", "scripts", "topo"):
            self._owned_directory(self.bundle / name)

        agent = self.bundle / "agent"
        self._owned_directory(agent / "spec")
        self._owned_directory(agent / "evidence")
        self._owned_file(agent / "README.md", b"fixture consumer readme\n")
        self._owned_file(agent / "harness.py", b"# fixture harness\n")
        self._owned_file(agent / "spec" / "steps.yaml", b"steps: []\n")

        namespaces = migration._load_production_baseline()[0]["scope"]["legacy_namespaces"]
        for name in namespaces:
            namespace = agent / "evidence" / name
            self._owned_directory(namespace)
            self._owned_file(namespace / "record.txt", f"fixture:{name}\n".encode(), mode=0o664)
        nested = agent / "evidence" / namespaces[0] / "existing-dir"
        self._owned_directory(nested)
        self._owned_file(nested / "nested.txt", b"nested legacy record\n")

        link = self.bundle / "evidence"
        os.symlink("agent/evidence", link)
        os.chown(link, 0, 0, follow_symlinks=False)

        configs = self.bundle / "configs" / "frr"
        self._owned_directory(configs)
        self._owned_file(configs / "daemons", b"zebra=yes\n")
        self._owned_file(configs / "frr.conf", b"hostname fixture\n")
        self._owned_file(self.bundle / "docs" / "04-cenario-c-evpn-vxlan.md", b"fixture mount source\n")

        topo_leaf = self.bundle / "topo" / "clab-poc-k8s-kind" / "leaf1"
        self._owned_directory(self.bundle / "topo" / "clab-poc-k8s-kind")
        self._owned_directory(topo_leaf)
        self._owned_file(topo_leaf / "topology.yml", b"name: fixture\n")

        var_dir = self.base / "var"
        run_dir = self.base / "run"
        run_lock = run_dir / "lock"
        self._owned_directory(var_dir, uid=0, gid=0, mode=0o755)
        self._owned_directory(run_dir, uid=0, gid=0, mode=0o755)
        self._owned_directory(run_lock, uid=0, gid=0, mode=0o1777)
        os.symlink(str(run_lock), var_dir / "lock")
        os.chown(var_dir / "lock", 0, 0, follow_symlinks=False)
        lock = run_lock / Path(migration.PRODUCTION_LOCK).name
        self._owned_file(lock, b"fixture lock; immutable during migration\n", uid=0, gid=0, mode=0o600)

    def close(self) -> None:
        # The private base was checked at construction and is never shared with a child.
        if self.base.parent != FIXTURE_ROOT or not self.base.name.startswith(migration.FIXTURE_PREFIX):
            raise AssertionError("refusing to remove a path outside the isolated fixture root")
        info = os.lstat(self.base)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
            raise AssertionError("refusing to remove a fixture whose private root drifted")
        active_error = sys.exc_info()[1]
        if active_error is not None:
            sys.stderr.write(
                json.dumps(
                    {
                        "fixture_status": "PRESERVED_AFTER_TEST_FAILURE",
                        "fixture_base": str(self.base),
                        "attempts_path": str(self.base / "attempts"),
                        "error_type": type(active_error).__name__,
                        "error": str(active_error)[:500],
                    },
                    sort_keys=True,
                )
                + "\n"
            )
            return
        shutil.rmtree(self.base)


def _tree_snapshot(root: Path, *, read_symlink_targets: bool = True) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    pending = [root]
    while pending:
        directory = pending.pop()
        directory_fd = os.open(
            directory,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOATIME", 0) | migration._NOFOLLOW_FLAGS,
        )
        try:
            names = sorted(os.listdir(directory_fd))
            for name in names:
                path = directory / name
                info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                target = None
                if stat.S_ISLNK(info.st_mode) and read_symlink_targets:
                    target = os.readlink(name, dir_fd=directory_fd)
                    after_readlink = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                    if (after_readlink.st_dev, after_readlink.st_ino) != (info.st_dev, info.st_ino):
                        raise AssertionError(f"symlink changed while snapshotting: {path.relative_to(root)}")
                    info = after_readlink
                item: dict[str, Any] = {
                    "dev": info.st_dev,
                    "inode": info.st_ino,
                    "uid": info.st_uid,
                    "gid": info.st_gid,
                    "mode": stat.S_IMODE(info.st_mode),
                    "nlink": info.st_nlink,
                    "size": info.st_size,
                    "mtime_ns": info.st_mtime_ns,
                    "ctime_ns": info.st_ctime_ns,
                    "atime_ns": info.st_atime_ns,
                    "type": migration._file_type(info.st_mode),
                }
                if stat.S_ISLNK(info.st_mode):
                    if read_symlink_targets:
                        item["target"] = target
                elif stat.S_ISREG(info.st_mode):
                    fd = os.open(
                        name,
                        os.O_RDONLY | getattr(os, "O_NOATIME", 0) | migration._NOFOLLOW_FLAGS,
                        dir_fd=directory_fd,
                    )
                    try:
                        digest = hashlib.sha256()
                        while block := os.read(fd, 1024 * 1024):
                            digest.update(block)
                        item["sha256"] = digest.hexdigest()
                    finally:
                        os.close(fd)
                elif stat.S_ISDIR(info.st_mode):
                    pending.append(path)
                else:
                    raise AssertionError(f"unexpected fixture object: {path}")
                result[str(path.relative_to(root))] = item
        finally:
            os.close(directory_fd)
    root_info = os.lstat(root)
    result["."] = {
        "dev": root_info.st_dev,
        "inode": root_info.st_ino,
        "uid": root_info.st_uid,
        "gid": root_info.st_gid,
        "mode": stat.S_IMODE(root_info.st_mode),
        "nlink": root_info.st_nlink,
        "mtime_ns": root_info.st_mtime_ns,
        "ctime_ns": root_info.st_ctime_ns,
        "atime_ns": root_info.st_atime_ns,
        "type": "dir",
    }
    return result


def _snapshot_symlink_targets(snapshot: dict[str, dict[str, Any]]) -> dict[str, str]:
    return {
        path: item["target"]
        for path, item in snapshot.items()
        if item["type"] == "symlink"
    }


def _changed_snapshot_fields(
    before: dict[str, dict[str, Any]],
    after: dict[str, dict[str, Any]],
) -> list[dict[str, Any]]:
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
        changes.append({"path": path, "fields": fields[:12]})
        if len(changes) == 8:
            break
    return changes


def _assert_snapshot_unchanged(
    before: dict[str, dict[str, Any]],
    after: dict[str, dict[str, Any]],
    label: str,
) -> None:
    if before != after:
        changes = _changed_snapshot_fields(before, after)
        raise AssertionError(f"{label} changed fixture metadata: {json.dumps(changes, sort_keys=True)}")


def _assert_symlink_targets_unchanged(
    before: dict[str, str],
    after: dict[str, str],
    label: str,
) -> None:
    changed = sorted(path for path in before.keys() | after.keys() if before.get(path) != after.get(path))
    if changed:
        raise AssertionError(f"{label} changed symlink targets at {changed[:8]}")


def _attempt_id(number: int) -> str:
    return f"{number:032x}"


def _assert_refused(
    function: Any,
    label: str,
    *,
    reason: str | None = None,
    expected_errno: int | None = None,
) -> str:
    try:
        function()
    except migration.MigrationRefused as error:
        if expected_errno is not None:
            raise AssertionError(f"{label} raised MigrationRefused, expected errno {expected_errno}") from error
        if reason is not None and reason not in str(error):
            raise AssertionError(f"{label} failed for the wrong reason: {error}") from error
        return f"{label}: {type(error).__name__}: {error}"
    except OSError as error:
        if expected_errno is not None and error.errno != expected_errno:
            raise AssertionError(f"{label} raised errno {error.errno}, expected {expected_errno}") from error
        if reason is not None and reason not in str(error):
            raise AssertionError(f"{label} failed for the wrong reason: {error}") from error
        return f"{label}: {type(error).__name__}: errno={error.errno}"
    raise AssertionError(f"known-bad state was accepted: {label}")


def _test_pure_cli_surface() -> dict[str, Any]:
    parser = migration._build_parser()
    rejected = 0
    for argv in (
        ["--dry-run", "--root", "/tmp/override"],
        ["--apply", "--attempt", "0" * 32, "--uid", "1000"],
        ["--apply", "--attempt", "0" * 32, "--fixture"],
        ["--dry-run", "--apply"],
    ):
        with open(os.devnull, "w") as sink, contextlib.redirect_stderr(sink):
            try:
                parser.parse_args(argv)
            except SystemExit as error:
                if error.code != 2:
                    raise
                rejected += 1
    if rejected != 4:
        raise AssertionError("CLI override and ambiguous mode inputs were not all rejected")
    baseline, _ = migration._load_production_baseline()
    production_paths = tuple(baseline["scope"]["canonical_source_paths_expected_absent"])
    production_config = migration._production_config(baseline)
    if production_config.lock_alias_path != migration.PRODUCTION_LOCK_ALIAS or production_config.lock_path != migration.PRODUCTION_LOCK_FILE:
        raise AssertionError("production lock opens do not use the fixed /run/lock path behind the pinned /var/lock alias")
    relative_paths = migration._canonical_relative_paths(production_paths)
    production_root_paths = migration._canonical_paths_under(migration.PRODUCTION_ROOT, relative_paths)
    fixture_root = PurePosixPath("/var/tmp/p004-host-installation-fixture-pure/bundle")
    fixture_paths = migration._canonical_paths_under(fixture_root, relative_paths)
    if production_root_paths != production_paths or len(fixture_paths) != 58:
        raise AssertionError("canonical production/fixture path composition changed the pinned manifest")
    if any(not PurePosixPath(path).is_relative_to(fixture_root) for path in fixture_paths):
        raise AssertionError("fixture canonical path escaped its bounded root")
    if any(path.startswith(migration.PRODUCTION_ROOT + "/") for path in fixture_paths):
        raise AssertionError("fixture canonical paths retained production-root prefixes")
    try:
        migration._canonical_paths_under(fixture_root, ("../outside",))
    except migration.MigrationRefused:
        pass
    else:
        raise AssertionError("unsafe relative fixture path was accepted")
    try:
        migration._canonical_relative_paths(("/opt/poc-k8s-fabric-evil/labctl",))
    except migration.MigrationRefused:
        pass
    else:
        raise AssertionError("absolute source outside the fixed production root was accepted")
    return {
        "parser_known_bad_rejected": rejected,
        "canonical_paths": {
            "production": len(production_root_paths),
            "fixture": len(fixture_paths),
            "unsafe_relative_rejected": True,
            "outside_production_root_rejected": True,
        },
        "path_composition_used_filesystem_resolution": False,
        "production_main_invoked": False,
    }


def _test_dry_run_zero_writes() -> dict[str, Any]:
    fixture = Fixture()
    try:
        before_targets = _snapshot_symlink_targets(_tree_snapshot(fixture.base))
        before_tree = _tree_snapshot(fixture.bundle, read_symlink_targets=False)
        before_base = _tree_snapshot(fixture.base, read_symlink_targets=False)
        result = migration.fixture_dry_run(fixture.base, fixture.baseline)
        after_tree = _tree_snapshot(fixture.bundle, read_symlink_targets=False)
        after_base = _tree_snapshot(fixture.base, read_symlink_targets=False)
        after_targets = _snapshot_symlink_targets(_tree_snapshot(fixture.base))
        if result["status"] != "READY_FOR_REVIEWED_APPLY" or result["mode"] != "DRY_RUN_ZERO_WRITES":
            raise AssertionError(f"fixture dry-run did not report a read-only ready state: {result}")
        _assert_snapshot_unchanged(before_tree, after_tree, "fixture dry-run bundle snapshot")
        _assert_snapshot_unchanged(before_base, after_base, "fixture dry-run full snapshot")
        _assert_symlink_targets_unchanged(before_targets, after_targets, "fixture dry-run")
        if "attempts" in after_base:
            raise AssertionError("fixture dry-run created an attempt directory")
        return {"result": result["status"], "entries_unchanged": len(before_tree), "attempt_log_absent": True}
    finally:
        fixture.close()


def _test_known_bad_preconditions() -> dict[str, Any]:
    cases = (
        ("alias-drift", "canonical evidence alias target drift", None),
        ("alias-absent", None, errno.ENOENT),
        ("lock-alias-target", "fixed lock alias target drift", None),
        ("file-hash-drift", "legacy content drift", None),
        ("extra-namespace", "legacy metadata drift", None),
        ("P004-collision", "legacy metadata drift", None),
        ("bundle-entry", "bundle root entries drifted", None),
        ("root-owner-drift", "canonical bundle root initial ownership or mode drift", None),
    )
    outcomes = []
    for number, (case, reason, expected_errno) in enumerate(cases, 1):
        fixture = Fixture()
        try:
            if case == "alias-drift":
                link = fixture.bundle / "evidence"
                os.unlink(link)
                os.symlink("agent", link)
                os.chown(link, 0, 0, follow_symlinks=False)
            elif case == "alias-absent":
                os.unlink(fixture.bundle / "evidence")
            elif case == "lock-alias-target":
                link = fixture.base / "var/lock"
                os.unlink(link)
                os.symlink(str(fixture.base / "run/elsewhere"), link)
                os.chown(link, 0, 0, follow_symlinks=False)
            elif case == "file-hash-drift":
                record = fixture.bundle / "agent/evidence/P002-S001/record.txt"
                with record.open("ab") as stream:
                    stream.write(b"drift\n")
                legacy_fd = os.open(
                    fixture.bundle / "agent/evidence",
                    os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | migration._NOFOLLOW_FLAGS,
                )
                try:
                    fixture.baseline["scope"]["legacy_metadata_entries"] = migration._scan_legacy_tree(legacy_fd)
                finally:
                    os.close(legacy_fd)
            elif case == "extra-namespace":
                fixture._owned_directory(fixture.bundle / "agent/evidence/unregistered")
            elif case == "P004-collision":
                fixture._owned_directory(fixture.bundle / "agent/evidence/P004")
            elif case == "root-owner-drift":
                os.chown(fixture.bundle, 1001, 1001)
            else:
                fixture._owned_file(fixture.bundle / "unregistered-root-entry", b"drift\n")
            message = _assert_refused(
                lambda: migration.fixture_apply(fixture.base, _attempt_id(number), fixture.baseline),
                case,
                reason=reason,
                expected_errno=expected_errno,
            )
            if (fixture.base / "attempts").exists():
                raise AssertionError(f"{case} refusal occurred after creating a durable attempt")
            outcomes.append(message)
        finally:
            fixture.close()

    acl_fixture = Fixture()
    acl_result: dict[str, Any] = {
        "status": "SKIPPED",
        "reason": "kernel/filesystem rejected a valid POSIX ACL xattr",
    }
    try:
        try:
            os.setxattr(acl_fixture.bundle / "agent/evidence", "system.posix_acl_default", _valid_acl_payload())
        except OSError as error:
            if error.errno not in {errno.ENOTSUP, errno.EOPNOTSUPP, errno.EPERM, errno.EINVAL}:
                raise
        else:
            refusal = _assert_refused(
                lambda: migration.fixture_apply(acl_fixture.base, _attempt_id(20), acl_fixture.baseline),
                "inherited POSIX ACL",
                reason="POSIX ACL present on agent/evidence: system.posix_acl_default",
            )
            if (acl_fixture.base / "attempts").exists():
                raise AssertionError("ACL rejection created an attempt or layout effect")
            acl_result = {"status": "PROVED", "refusal": refusal}
    finally:
        acl_fixture.close()
    return {"known_bad_preconditions_rejected": outcomes, "acl_probe": acl_result}


def _terminal(fixture: Fixture, attempt: str) -> dict[str, Any]:
    path = fixture.base / "attempts" / attempt / "terminal.json"
    return json.loads(path.read_text(encoding="utf-8"))


def _legacy_hash_digest(fixture: Fixture) -> str:
    hashes: dict[str, str] = {}
    for item in fixture.baseline["scope"]["legacy_regular_files"]:
        path = fixture.bundle / "agent/evidence" / item["relative"]
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOATIME", 0) | migration._NOFOLLOW_FLAGS)
        try:
            digest = hashlib.sha256()
            while block := os.read(fd, 1024 * 1024):
                digest.update(block)
            hashes[item["relative"]] = digest.hexdigest()
        finally:
            os.close(fd)
    raw = json.dumps(hashes, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def _baseline_legacy_hash_digest(fixture: Fixture) -> str:
    expected = {
        item["relative"]: item["sha256"]
        for item in fixture.baseline["scope"]["legacy_regular_files"]
    }
    raw = json.dumps(expected, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def _valid_acl_payload() -> bytes:
    return struct.pack("<I", 2) + b"".join(
        struct.pack("<HHI", tag, perm, ident)
        for tag, perm, ident in (
            (0x01, 0x07, 0xFFFFFFFF),
            (0x02, 0x07, UID),
            (0x04, 0x05, 0xFFFFFFFF),
            (0x10, 0x05, 0xFFFFFFFF),
            (0x20, 0x05, 0xFFFFFFFF),
        )
    )


def _probe_acl_support() -> dict[str, str]:
    path = Path(tempfile.mkdtemp(prefix=migration.FIXTURE_PREFIX + "acl-probe-", dir=FIXTURE_ROOT))
    os.chmod(path, 0o700)
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | migration._NOFOLLOW_FLAGS)
    acl_set = False
    try:
        try:
            os.setxattr(path, "system.posix_acl_default", _valid_acl_payload())
            acl_set = True
        except OSError as error:
            if error.errno in {errno.ENOTSUP, errno.EOPNOTSUPP, errno.EPERM, errno.EINVAL}:
                return {"status": "SKIPPED", "reason": f"cannot set a valid POSIX ACL xattr: errno={error.errno}"}
            raise
        try:
            migration._reject_acl_fd(fd, "private ACL capability probe")
        except migration.MigrationRefused as error:
            if "POSIX ACL present" in str(error):
                return {"status": "SUPPORTED", "reason": "ACL xattr can be set and observed"}
            if "cannot inspect ACL xattrs" in str(error):
                return {"status": "SKIPPED", "reason": str(error)}
            raise
        raise AssertionError("ACL inspection did not report the ACL set on the private probe")
    finally:
        if acl_set:
            os.removexattr(path, "system.posix_acl_default")
        os.close(fd)
        os.rmdir(path)


def _assert_unknown_is_sticky(fixture: Fixture, attempt: str, label: str) -> None:
    terminal = _terminal(fixture, attempt)
    if terminal["status"] != "UNKNOWN":
        raise AssertionError(f"{label} did not leave an UNKNOWN terminal record")
    if terminal["automatic_retry"] or terminal["automatic_cleanup"] or terminal["automatic_rollback"]:
        raise AssertionError(f"{label} advertised an automatic recovery path")
    if not (fixture.base / "attempts" / attempt).is_dir():
        raise AssertionError(f"{label} removed its durable attempt record")
    attempts_root = fixture.base / "attempts"
    before = _tree_snapshot(attempts_root)
    _assert_refused(
        lambda: migration.fixture_apply(fixture.base, attempt, fixture.baseline),
        f"{label} same-ID replay",
        reason="prior migration ledger exists",
    )
    different_attempt = f"{int(attempt, 16) + 1:032x}"
    _assert_refused(
        lambda: migration.fixture_apply(fixture.base, different_attempt, fixture.baseline),
        f"{label} different-ID replay",
        reason="prior migration ledger exists",
    )
    after = _tree_snapshot(attempts_root)
    if before != after:
        raise AssertionError(f"{label} replay changed immutable prior ledger records")
    if os.path.lexists(attempts_root / different_attempt):
        raise AssertionError(f"{label} different-ID replay created a new ledger")


def _test_unknown_failure_matrix() -> dict[str, Any]:
    fixture = Fixture()
    namespaces = fixture.baseline["scope"]["legacy_namespaces"]
    steps = ["root-ownership", "stage-directory", "P004-directory", "S002-directory"]
    steps.extend(f"alias-{name}" for name in namespaces)
    steps.extend(("publish-stage-mode", "atomic-evidence-exchange"))
    fixture.close()

    probes = 0
    probe_records: list[dict[str, Any]] = []
    for step_index, step in enumerate(steps, 100):
        for boundary in ("before", "after"):
            current = Fixture()
            attempt = _attempt_id(probes + 1000)
            fault_name = f"{boundary}:{step}"

            def fail(event: str, context: Any) -> None:
                if event == fault_name:
                    raise RuntimeError(f"fixture fault at {event}")

            try:
                result = migration.fixture_apply(current.base, attempt, current.baseline, fail)
                if result["status"] != "UNKNOWN" or result["failed_step"] != step:
                    raise AssertionError(f"{fault_name} did not stop as UNKNOWN: {result}")
                _assert_unknown_is_sticky(current, attempt, fault_name)
                original = current.bundle / "agent/evidence"
                canonical = os.lstat(current.bundle / "evidence")
                parked = current.bundle / (migration.STAGE_PREFIX + attempt)
                exchanged = step == "atomic-evidence-exchange" and boundary == "after"
                if exchanged:
                    if not stat.S_ISDIR(canonical.st_mode) or not parked.is_symlink():
                        raise AssertionError("post-exchange UNKNOWN did not retain both names")
                    if os.stat(current.bundle / "evidence/P002-S001").st_ino != os.stat(original / "P002-S001").st_ino:
                        raise AssertionError("published alias no longer resolves to the original namespace inode")
                else:
                    if not stat.S_ISLNK(canonical.st_mode) or os.readlink(current.bundle / "evidence") != "agent/evidence":
                        raise AssertionError(f"{fault_name} changed the canonical alias before exchange")
                    stage_should_exist = step_index > 101 or (step == "stage-directory" and boundary == "after")
                    if stage_should_exist and not parked.exists():
                        raise AssertionError(f"{fault_name} cleaned up a created staging directory")
                terminal_path = current.base / "attempts" / attempt / "terminal.json"
                terminal_raw = terminal_path.read_bytes()
                observed_hashes = _legacy_hash_digest(current)
                expected_hashes = _baseline_legacy_hash_digest(current)
                if observed_hashes != expected_hashes:
                    raise AssertionError(f"{fault_name} changed legacy file content")
                probe_records.append(
                    {
                        "event": fault_name,
                        "status": result["status"],
                        "step": result["failed_step"],
                        "terminal": _terminal(current, attempt),
                        "terminal_sha256": hashlib.sha256(terminal_raw).hexdigest(),
                        "legacy_hashes_sha256": observed_hashes,
                    }
                )
                probes += 1
            finally:
                current.close()

    for step in ("stage-directory", "atomic-evidence-exchange"):
        for boundary in ("fsync", "readback"):
            current = Fixture()
            attempt = _attempt_id(2000 + probes)
            point = f"{boundary}:{step}"

            def fail_sync(event: str, context: Any) -> None:
                if event == point:
                    raise OSError(errno.EIO, f"injected {event}")

            try:
                result = migration.fixture_apply(current.base, attempt, current.baseline, fail_sync)
                if result["status"] != "UNKNOWN" or result["failed_step"] != step:
                    raise AssertionError(f"{point} did not stop as UNKNOWN")
                _assert_unknown_is_sticky(current, attempt, point)
                parked = current.bundle / (migration.STAGE_PREFIX + attempt)
                if step == "atomic-evidence-exchange":
                    if not stat.S_ISDIR(os.lstat(current.bundle / "evidence").st_mode) or not parked.is_symlink():
                        raise AssertionError(f"{point} did not retain the completed exchange")
                elif not parked.is_dir():
                    raise AssertionError(f"{point} removed the created stage")
                terminal_raw = (current.base / "attempts" / attempt / "terminal.json").read_bytes()
                observed_hashes = _legacy_hash_digest(current)
                probe_records.append(
                    {
                        "event": point,
                        "status": result["status"],
                        "step": result["failed_step"],
                        "terminal": _terminal(current, attempt),
                        "terminal_sha256": hashlib.sha256(terminal_raw).hexdigest(),
                        "legacy_hashes_sha256": observed_hashes,
                    }
                )
                probes += 1
            finally:
                current.close()

    unsupported = Fixture()
    unsupported_attempt = _attempt_id(3000 + probes)

    def no_exchange(event: str, context: Any) -> None:
        if event == "syscall:renameat2":
            raise OSError(errno.ENOSYS, "fixture reports unsupported renameat2")

    try:
        result = migration.fixture_apply(unsupported.base, unsupported_attempt, unsupported.baseline, no_exchange)
        call = result.get("exchange_syscall") or {}
        if result["status"] != "UNKNOWN" or call.get("errno") != errno.ENOSYS or call.get("rc") != -1:
            raise AssertionError(f"unsupported renameat2 was not recorded accurately: {result}")
        if not (unsupported.bundle / (migration.STAGE_PREFIX + unsupported_attempt)).is_dir():
            raise AssertionError("unsupported exchange cleaned the complete staged tree")
        if not (unsupported.bundle / "evidence").is_symlink():
            raise AssertionError("unsupported exchange replaced the legacy alias")
        _assert_unknown_is_sticky(unsupported, unsupported_attempt, "unsupported renameat2")
        terminal_raw = (unsupported.base / "attempts" / unsupported_attempt / "terminal.json").read_bytes()
        probe_records.append(
            {
                "event": "syscall:renameat2/ENOSYS",
                "status": result["status"],
                "step": result["failed_step"],
                "terminal": _terminal(unsupported, unsupported_attempt),
                "terminal_sha256": hashlib.sha256(terminal_raw).hexdigest(),
                "exchange_syscall": call,
                "legacy_hashes_sha256": _legacy_hash_digest(unsupported),
            }
        )
        probes += 1
    finally:
        unsupported.close()

    drift = Fixture()
    drift_attempt = _attempt_id(4000 + probes)
    record = drift.bundle / "agent/evidence/P002-S001/record.txt"

    def change_legacy_after_stage(event: str, context: Any) -> None:
        if event == "after:stage-directory":
            with record.open("ab") as stream:
                stream.write(b"concurrent fixture drift\n")

    try:
        result = migration.fixture_apply(drift.base, drift_attempt, drift.baseline, change_legacy_after_stage)
        if result["status"] != "UNKNOWN" or result["failed_step"] != "stage-directory":
            raise AssertionError(f"legacy content drift did not stop before publication: {result}")
        if not (drift.bundle / (migration.STAGE_PREFIX + drift_attempt)).is_dir():
            raise AssertionError("data drift removed the created parking/staging evidence")
        if not (drift.base / "attempts" / drift_attempt / "terminal.json").is_file():
            raise AssertionError("data drift did not retain its durable terminal record")
        _assert_unknown_is_sticky(drift, drift_attempt, "legacy data drift")
        terminal_raw = (drift.base / "attempts" / drift_attempt / "terminal.json").read_bytes()
        probe_records.append(
            {
                "event": "after:stage-directory/legacy-data-drift",
                "status": result["status"],
                "step": result["failed_step"],
                "terminal": _terminal(drift, drift_attempt),
                "terminal_sha256": hashlib.sha256(terminal_raw).hexdigest(),
                "legacy_hashes_sha256": _legacy_hash_digest(drift),
            }
        )
        probes += 1
    finally:
        drift.close()

    return {
        "unknown_failure_probes": probes,
        "effect_steps": len(steps),
        "before_after_each_effect": True,
        "exchange_after_syscall": True,
        "automatic_recovery": False,
        "probe_records": probe_records,
    }


def _test_global_ledger_gate() -> dict[str, Any]:
    cases = (
        ("empty-store", "prior migration ledger exists"),
        ("malformed-incomplete-ledger", "prior migration ledger exists"),
        ("symlinked-store", "prior migration ledger path is a symlink"),
    )
    outcomes = []
    for number, (case, reason) in enumerate(cases, 6000):
        fixture = Fixture()
        store = fixture.base / "attempts"
        try:
            if case == "empty-store":
                os.mkdir(store, 0o700)
            elif case == "malformed-incomplete-ledger":
                os.mkdir(store, 0o700)
                prior = store / "00000000000000000000000000000001"
                os.mkdir(prior, 0o700)
                Fixture._owned_file(prior / "intent.json", b"{\n", uid=0, gid=0, mode=0o600)
            else:
                target = fixture.base / "ledger-target"
                os.mkdir(target, 0o700)
                os.symlink(target, store)

            attempt = _attempt_id(number)
            refusals = []
            for mode, operation in (
                ("dry-run", lambda: migration.fixture_dry_run(fixture.base, fixture.baseline)),
                ("apply", lambda: migration.fixture_apply(fixture.base, attempt, fixture.baseline)),
            ):
                before_targets = _snapshot_symlink_targets(_tree_snapshot(fixture.base))
                before = _tree_snapshot(fixture.base, read_symlink_targets=False)
                label = f"{case} {mode}"
                message = _assert_refused(operation, label, reason=reason)
                if not message.startswith(f"{label}: MigrationRefused:"):
                    raise AssertionError(f"{label} used the wrong refusal type: {message}")
                after = _tree_snapshot(fixture.base, read_symlink_targets=False)
                _assert_snapshot_unchanged(before, after, label)
                after_targets = _snapshot_symlink_targets(_tree_snapshot(fixture.base))
                _assert_symlink_targets_unchanged(before_targets, after_targets, label)
                original_alias = after.get("bundle/evidence", {})
                if original_alias.get("type") != "symlink" or after_targets.get("bundle/evidence") != "agent/evidence":
                    raise AssertionError(f"{label} changed the original canonical alias")
                possible_attempt_paths = {f"attempts/{attempt}", f"ledger-target/{attempt}"}
                if possible_attempt_paths & before.keys():
                    raise AssertionError(f"{label} attempt ID already existed before refusal")
                if possible_attempt_paths & after.keys():
                    raise AssertionError(f"{label} created a new attempt before refusing")
                refusals.append(message)
            outcomes.append({"case": case, "dry_run": refusals[0], "apply": refusals[1]})
        finally:
            fixture.close()
    return {"prior_ledger_states_refused_before_writes": outcomes}


def _test_preexchange_validation() -> dict[str, Any]:
    cases = (
        ("stage-mode-downgrade", "before:atomic-evidence-exchange", "staging directory must be mode0755 before exchange"),
        ("stage-mode-downgrade-after-syscall-hook", "syscall:renameat2", "staging directory must be mode0755 before exchange"),
        ("private-mode", "before:atomic-evidence-exchange", "private P004 directory owner or mode drift"),
        ("alias-target", "before:atomic-evidence-exchange", "staged alias target drift: P002-S001"),
    )
    outcomes = []
    for number, (case, fault_event, reason) in enumerate(cases, 7000):
        fixture = Fixture()
        attempt = _attempt_id(number)
        stage = fixture.bundle / (migration.STAGE_PREFIX + attempt)

        def drift_after_before_hook(event: str, context: Any) -> None:
            if event != fault_event:
                return
            if case == "stage-mode-downgrade":
                os.chmod(stage, 0o700)
            elif case == "stage-mode-downgrade-after-syscall-hook":
                os.chmod(stage, 0o700)
            elif case == "private-mode":
                os.chmod(stage / "P004", 0o750)
            else:
                alias = stage / "P002-S001"
                os.unlink(alias)
                os.symlink("../agent/evidence/P002-S002", alias)

        try:
            result = migration.fixture_apply(fixture.base, attempt, fixture.baseline, drift_after_before_hook)
            if result["status"] != "UNKNOWN" or result["failed_step"] != "atomic-evidence-exchange":
                raise AssertionError(f"{case} did not stop as UNKNOWN before exchange: {result}")
            terminal = _terminal(fixture, attempt)
            error = terminal.get("error", {})
            if error.get("type") != "MigrationUnknown" or reason not in error.get("message", ""):
                raise AssertionError(f"{case} was refused for the wrong cause: {error}")
            original_alias = fixture.bundle / "evidence"
            if not original_alias.is_symlink() or os.readlink(original_alias) != "agent/evidence":
                raise AssertionError(f"{case} replaced the original evidence alias before exchange")
            if not stage.is_dir() or stat.S_IMODE(os.lstat(stage).st_mode) != (0o700 if case.startswith("stage-mode-downgrade") else 0o755):
                raise AssertionError(f"{case} did not retain the staged tree after refusal")
            if _legacy_hash_digest(fixture) != _baseline_legacy_hash_digest(fixture):
                raise AssertionError(f"{case} changed legacy file contents")
            _assert_unknown_is_sticky(fixture, attempt, case)
            outcomes.append({"case": case, "status": result["status"], "failed_step": result["failed_step"], "reason": reason})
        finally:
            fixture.close()
    return {"preexchange_drift_refused": outcomes}


def _test_success_and_uid1000_contract() -> dict[str, Any]:
    fixture = Fixture()
    attempt = _attempt_id(5000)
    initial = fixture.baseline["initial_layout"]
    initial_root = (initial["bundle_root"]["dev"], initial["bundle_root"]["inode"])
    legacy_before = {
        item["relative"]: item["sha256"]
        for item in fixture.baseline["scope"]["legacy_regular_files"]
    }
    try:
        previous_umask = os.umask(0o777)
        try:
            result = migration.fixture_apply(fixture.base, attempt, fixture.baseline)
        finally:
            os.umask(previous_umask)
        if result["status"] != "PROVED":
            raise AssertionError(f"fixture migration did not prove success: {result}")
        verified = migration.fixture_verify_published(fixture.base, fixture.baseline, attempt)
        if verified["status"] != "PROVED" or verified["aliases"] != 19:
            raise AssertionError(f"published fixture did not verify all 19 aliases: {verified}")
        root_info = os.stat(fixture.bundle, follow_symlinks=False)
        evidence_info = os.stat(fixture.bundle / "evidence", follow_symlinks=False)
        parked_info = os.lstat(fixture.bundle / (migration.STAGE_PREFIX + attempt))
        alias_info = initial["evidence_alias"]
        if (root_info.st_dev, root_info.st_ino) != initial_root or (root_info.st_uid, root_info.st_gid, stat.S_IMODE(root_info.st_mode)) != (0, 0, 0o755):
            raise AssertionError("migration replaced the root inode or left root ownership/mode incorrect")
        if (parked_info.st_dev, parked_info.st_ino) != (alias_info["dev"], alias_info["inode"]) or not stat.S_ISLNK(parked_info.st_mode):
            raise AssertionError("original root-owned alias inode was not parked")
        if not stat.S_ISDIR(evidence_info.st_mode) or stat.S_IMODE(evidence_info.st_mode) != 0o755:
            raise AssertionError("canonical evidence name is not the published real root")
        p004 = fixture.bundle / "evidence/P004"
        s002 = p004 / "S002"
        for path in (p004, s002):
            info = os.stat(path, follow_symlinks=False)
            if (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != (0, 0, 0o700):
                raise AssertionError(f"private store path is not root-owned mode0700: {path}")
        actual_hashes = {}
        for item in fixture.baseline["scope"]["legacy_regular_files"]:
            source = fixture.bundle / "agent/evidence" / item["relative"]
            actual_hashes[item["relative"]] = hashlib.sha256(source.read_bytes()).hexdigest()
        if actual_hashes != legacy_before:
            raise AssertionError("successful publication changed any legacy file contents")

        # The base is private during all helper calls. Open execute permission only for this UID probe.
        os.chmod(fixture.base, 0o711)
        try:
            child_code = r'''
import errno, json, os, pathlib, sys
bundle = pathlib.Path(sys.argv[1])
direct = bundle / "agent/evidence/P002-S001"
canonical = bundle / "evidence/P002-S001"
canonical.mkdir(parents=True, exist_ok=True)
record = canonical / "record.txt"
with record.open("ab") as stream:
    stream.write(b"uid1000 append\n")
os.mkdir(canonical / "uid1000-dir")
(canonical / "uid1000-new.txt").write_text("uid1000 new file\n", encoding="utf-8")
(canonical / "uid1000-dir/child.txt").write_text("uid1000 child file\n", encoding="utf-8")
checks = {}
for label, operation in (
    ("canonical_namespace", lambda: os.mkdir(bundle / "evidence/UID1000-namespace")),
    ("alias_create", lambda: os.symlink("../agent/evidence/P002-S001", bundle / "evidence/UID1000-alias")),
    ("alias_remove", lambda: os.unlink(bundle / "evidence/P002-S001")),
    ("bundle_entry", lambda: (bundle / "UID1000-entry").open("x").close()),
    ("bundle_entry_remove", lambda: os.unlink(bundle / "README.md")),
):
    try:
        operation()
    except OSError as error:
        if error.errno != errno.EACCES:
            raise AssertionError(f"{label} failed with errno {error.errno}, expected EACCES")
        checks[label] = error.errno
    else:
        raise AssertionError(f"UID1000 unexpectedly changed the canonical namespace: {label}")
if os.stat(direct).st_ino != os.stat(canonical).st_ino:
    raise AssertionError("direct and canonical namespace paths differ")
if (direct / "uid1000-new.txt").read_text(encoding="utf-8") != "uid1000 new file\n":
    raise AssertionError("new legacy file is not readable through the direct legacy path")
if (direct / "uid1000-dir/child.txt").read_text(encoding="utf-8") != "uid1000 child file\n":
    raise AssertionError("new subdirectory file is not visible through the direct legacy path")
if b"uid1000 append\n" not in (direct / "record.txt").read_bytes():
    raise AssertionError("canonical alias append was not visible through the direct legacy path")
print(json.dumps({"status":"PROVED","denied":checks,"namespace_inode":os.stat(direct).st_ino,"mkdir_exist_ok":True,"append":True,"new_file_and_directory":True}))
'''
            child = subprocess.run(
                [sys.executable, "-c", child_code, str(fixture.bundle)],
                check=True,
                capture_output=True,
                text=True,
                user=UID,
                group=GID,
                extra_groups=[],
                timeout=10,
            )
        finally:
            os.chmod(fixture.base, 0o700)
        child_result = json.loads(child.stdout)
        if child_result["status"] != "PROVED" or len(child_result["denied"]) != 5 or not child_result["mkdir_exist_ok"] or not child_result["append"] or not child_result["new_file_and_directory"]:
            raise AssertionError(f"UID1000 permission contract incomplete: {child_result}")

        future_name = "FUTURE-ROOT-PROVISIONED"
        future = fixture.bundle / "agent/evidence" / future_name
        Fixture._owned_directory(future)
        Fixture._owned_file(future / "future.txt", b"root provisioned\n")
        os.symlink(f"../agent/evidence/{future_name}", fixture.bundle / "evidence" / future_name)
        direct_info = os.stat(future, follow_symlinks=False)
        alias_info = os.stat(fixture.bundle / "evidence" / future_name)
        if (direct_info.st_dev, direct_info.st_ino) != (alias_info.st_dev, alias_info.st_ino):
            raise AssertionError("root-provisioned future alias does not identify its legacy inode")
        _assert_refused(
            lambda: migration.fixture_verify_published(fixture.base, fixture.baseline, attempt),
            "unregistered root-provisioned future namespace",
            reason="fixture canonical namespace set is missing or unregistered",
        )
        return {
            "published_aliases": verified["aliases"],
            "legacy_files_preserved": len(actual_hashes),
            "bundle_root_inode_preserved": initial_root,
            "original_alias_parked": True,
            "uid1000_probe": child_result,
            "root_future_namespace_identity_proved": (direct_info.st_dev, direct_info.st_ino),
            "unregistered_namespace_refused": True,
            "restrictive_umask_preserved_directory_modes": True,
        }
    finally:
        fixture.close()


def _run_linux_root_fixture_suite() -> dict[str, Any]:
    if sys.platform != "linux" or os.geteuid() != 0:
        return {"integration": "SKIPPED", "reason": "actual renameat2/UID-1000 integration requires Linux root"}
    if UID == os.geteuid():
        raise AssertionError("fixture integration requires the controller to differ from UID 1000")
    acl_support = _probe_acl_support()
    if acl_support["status"] == "SKIPPED":
        return {"integration": "SKIPPED", "reason": acl_support["reason"], "acl_probe": acl_support}
    report = {
        "integration": "PASS",
        "acl_support": acl_support,
        "dry_run": _test_dry_run_zero_writes(),
        "known_bad": _test_known_bad_preconditions(),
        "preexchange": _test_preexchange_validation(),
        "prior_ledger": _test_global_ledger_gate(),
        "unknown": _test_unknown_failure_matrix(),
        "success_and_uid1000": _test_success_and_uid1000_contract(),
    }
    if report["known_bad"]["acl_probe"]["status"] == "SKIPPED":
        report["integration"] = "SKIPPED"
        report["reason"] = report["known_bad"]["acl_probe"]["reason"]
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("--linux-root-fixture", action="store_true", required=True)
    args = parser.parse_args(argv)
    report: dict[str, Any] = {"pure_surface": _test_pure_cli_surface()}
    report.update(_run_linux_root_fixture_suite())
    print(json.dumps(report, sort_keys=True, indent=2))
    return 0 if report.get("integration") == "PASS" else 75


if __name__ == "__main__":
    raise SystemExit(main())
