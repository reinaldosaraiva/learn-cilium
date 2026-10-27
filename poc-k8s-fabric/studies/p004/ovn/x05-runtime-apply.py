#!/usr/bin/env python3
"""Build and compensate the admitted X05 base runtime.

The library surface is intentionally one-shot.  ``RuntimeBuilder`` accepts
only the original consumed admission capability, keeps the producer's Runner
and serialization lock, and records every intended effect before dispatch.
The public CLI never enables live work; it offers a pure dry description and
returns rc 75 for ``--execute``.
"""

from __future__ import annotations

import argparse
import contextlib
import copy
import dataclasses
import hashlib
import importlib.util
import json
import math
import os
import pathlib
import re
import stat
import sys
import time
import types
from collections.abc import Callable, Mapping, Sequence
from typing import Any


HERE = pathlib.Path(__file__).resolve().parent
NB_PATH = HERE / "x05-nb-live.py"
SOURCE_PATH = pathlib.Path(__file__).resolve()
CAPTURE_SOURCE_PATH = HERE / "x05-capture.py"
CAPTURE_MODULE_NAME = "x05_capture_runtime_contract"
CAPTURE_APPLY_MODULE_NAME = "x05_runtime_apply_capture_contract"
SCHEMA = "p004-x05-runtime-apply-v1"
JOURNAL_SCHEMA = "p004-x05-runtime-journal-v1"
CAPTURE_PID_SCHEMA = "p004-x05-capture-pids-v1"
RUNTIME_JOURNAL_NAME = "runtime-apply.jsonl"
CAPTURE_PID_NAME = "tcpdump-pids"
UUID_RE = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\Z")
HEX64_RE = re.compile(r"[0-9a-f]{64}\Z")
IMAGE_ID_RE = re.compile(r"sha256:[0-9a-f]{64}\Z")
IFNAME_RE = re.compile(r"[A-Za-z0-9_.-]{1,15}\Z")
OWNER_RE = re.compile(r"labctl-x05-([0-9a-f]{6})\Z")
MAX_LOCAL_FILE = 16 * 1024 * 1024
PRIVATE_HELPER_OUTPUT = 512 * 1024
KNOWN_VXLAN_STDERR = b"info: Using default fan map value (33)\n"

BASE_MUTABLE_IDS = frozenset(
    {
        "host:vm-cilium/docker-container/dci-client-2",
        "host:vm-cilium/ovs-port-interface/dci-client-2:eth1",
        "host:vm-cilium/ovs-port-interface/dci-client-2:eth2",
        "container:ovn-gw-1/linux-veth/bgpvrf300-ovs",
        "container:ovn-gw-1/linux-veth/bgpvrf300",
        "container:ovn-gw-1/ovs-port-interface/bgpvrf300-ovs",
        "container:ovn-gw-1/frr-config-delta//etc/frr/frr.conf:ovnvrf300",
        "container:ovn-gw-2/linux-veth/bgpvrf400-ovs",
        "container:ovn-gw-2/linux-veth/bgpvrf400",
        "container:ovn-gw-2/ovs-port-interface/bgpvrf400-ovs",
        "container:ovn-gw-2/frr-config-delta//etc/frr/frr.conf:ovnvrf400",
        "container:ovn-chassis-1/netns/x05-tenant-a-vm",
        "container:ovn-chassis-1/linux-veth/x05-tenant-a-p",
        "netns:ovn-chassis-1:x05-tenant-a-vm/linux-veth/x05-tenant-a",
        "container:ovn-chassis-1/ovs-port-interface/x05-tenant-a-p",
        "container:ovn-chassis-2/netns/x05-tenant-b-vm",
        "container:ovn-chassis-2/linux-veth/x05-tenant-b-p",
        "netns:ovn-chassis-2:x05-tenant-b-vm/linux-veth/x05-tenant-b",
        "container:ovn-chassis-2/ovs-port-interface/x05-tenant-b-p",
        "container:ovn-chassis-2/linux-bridge/br-x05-b",
        "container:ovn-chassis-2/linux-vxlan/vxlan-x05-b",
        "container:ovn-chassis-2/linux-dummy/evpn-x05-b",
        "container:ovn-chassis-2/frr-pathspace/x05",
        "container:ovn-chassis-2/ovs-external-id/dynamic-routing-port-mapping",
        "container:ovn-chassis-2/ovs-external-id/ovn-evpn-local-ip",
        "host:vm-cilium/docker-container/dci-x05-peer-2",
        "host:vm-cilium/ovs-port-interface/dci-x05-peer-2:eth1",
        "container:dci-x05-peer-2/linux-vrf/vrf-x05-peer",
        "container:dci-x05-peer-2/linux-bridge/br-x05-peer",
        "container:dci-x05-peer-2/linux-vxlan/vxlan-x05-pr",
        "container:dci-x05-peer-2/linux-dummy/evpn-x05-pr",
        "container:dci-x05-peer-2/frr-pathspace/x05",
    }
)
GENERATED_VRF_IDS = frozenset(
    {
        "container:ovn-gw-1/ovn-generated-vrf/ovnvrf300",
        "container:ovn-gw-2/ovn-generated-vrf/ovnvrf400",
        "container:ovn-chassis-2/ovn-generated-vrf/ovnvrf-x05-b",
    }
)
MARKER_ID = "host:vm-cilium/marker//run/labctl/dci-x05/active"
EXCLUDED_COORDINATOR_KINDS = frozenset(
    {"lsp-parent-control", "capture-processes", "capture-file"}
)
CAPTURE_POINT_IDS = (
    "fabric",
    "chassis-1",
    "chassis-2",
    "gateway-300",
    "gateway-400",
)
CLIENT_CONTAINER_ID = "host:vm-cilium/docker-container/dci-client-2"
CLIENT_ETH1_ID = "host:vm-cilium/ovs-port-interface/dci-client-2:eth1"
CLIENT_ETH2_ID = "host:vm-cilium/ovs-port-interface/dci-client-2:eth2"
PEER_CONTAINER_ID = "host:vm-cilium/docker-container/dci-x05-peer-2"
PEER_ETH1_ID = "host:vm-cilium/ovs-port-interface/dci-x05-peer-2:eth1"
CHASSIS_MAPPING_ID = (
    "container:ovn-chassis-2/ovs-external-id/dynamic-routing-port-mapping"
)
CHASSIS_LOCAL_IP_ID = (
    "container:ovn-chassis-2/ovs-external-id/ovn-evpn-local-ip"
)


def _load_nb_contract() -> Any:
    name = "x05_nb_live_runtime_apply_contract"
    existing = sys.modules.get(name)
    if existing is not None:
        loaded = pathlib.Path(getattr(existing, "__file__", "")).resolve()
        if loaded != NB_PATH.resolve():
            raise RuntimeError("canonical X05 NB contract path changed")
        return existing
    spec = importlib.util.spec_from_file_location(name, NB_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load the reviewed X05 NB contract")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


NB = _load_nb_contract()
RUNTIME = NB.RUNTIME

_INCIDENT_RUNNER_CLASS = RUNTIME._IncidentTrackingRunner
_INCIDENT_RUNNER_RUN = _INCIDENT_RUNNER_CLASS.run
_PRODUCER_SUBPROCESS_RUNNER_CLASS = RUNTIME.SubprocessRunner
_PRODUCER_SUBPROCESS_RUN = _PRODUCER_SUBPROCESS_RUNNER_CLASS.run
_PRODUCER_RLOCK_TYPE = type(RUNTIME.threading.RLock())

# Keep the producer entry points captured from the reviewed module.  Calling
# through an AdmissionSession instance would allow an instance attribute to
# substitute a weaker wrapper after admission.
_SESSION_VERIFY_EXECUTION = RUNTIME.AdmissionSession.verify_execution
_SESSION_EXECUTION_CONTEXT = RUNTIME.AdmissionSession.execution_context
_SESSION_RECORD_EXECUTION_EVENT = RUNTIME.AdmissionSession.record_execution_event
_SESSION_LABCTL = RUNTIME.AdmissionSession._labctl
_EVENT_LOG_APPEND = RUNTIME.DurableEventLog.append
_EVENT_LOG_VERIFY = RUNTIME.DurableEventLog.verify
_COLLECTOR_OWNED_M03_IDENTITY = RUNTIME.LiveCollector.owned_m03_identity
_NB_FORWARD = NB.NBAdapter.forward
_NB_INVERSE = NB.NBAdapter.inverse
_TEST_TERMINAL_FAULT: str | None = None


class BuilderError(RuntimeError):
    """The base runtime cannot safely continue."""


class SecurityError(BuilderError):
    """A capability, source, journal, marker, or identity binding changed."""


class PostconditionError(BuilderError):
    """A fresh readback did not prove the intended state."""


class AmbiguousEffect(BuilderError):
    """A dispatched effect lacks a complete outcome and must not be retried."""


class NotReady(BuilderError):
    """The public live CLI remains deliberately disabled."""


def _require_original_method(
    owner: Any,
    name: str,
    implementation: Any,
    *,
    context: str,
) -> types.MethodType:
    """Return an exact bound method without invoking untrusted equality."""
    try:
        bound = getattr(owner, name)
        shadowed = name in vars(owner)
    except Exception as exc:
        raise SecurityError(context + " implementation cannot be resolved") from exc
    if (
        type(bound) is not types.MethodType
        or bound.__self__ is not owner
        or bound.__func__ is not implementation
        or shadowed
    ):
        raise SecurityError(context + " implementation changed")
    return bound


def _same_bound_method(
    current: Any,
    expected: Any,
    *,
    owner: Any,
    implementation: Any,
) -> bool:
    """Compare bound methods by exact owner/function identity."""
    return (
        type(current) is types.MethodType
        and type(expected) is types.MethodType
        and current.__self__ is owner
        and expected.__self__ is owner
        and current.__func__ is implementation
        and expected.__func__ is implementation
    )


def _canonical(value: Any) -> bytes:
    try:
        return (
            json.dumps(
                value,
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=True,
                allow_nan=False,
            )
            + "\n"
        ).encode("ascii")
    except (TypeError, ValueError, UnicodeError) as exc:
        raise SecurityError("value is not canonical bounded JSON") from exc


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _identity(info: os.stat_result) -> tuple[int, ...]:
    return (
        info.st_dev,
        info.st_ino,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
        info.st_mode,
        info.st_uid,
    )


def _read_regular(
    path: pathlib.Path,
    *,
    maximum: int = MAX_LOCAL_FILE,
    mode: int | None = None,
    uid: int | None = None,
) -> tuple[bytes, tuple[int, ...]]:
    try:
        before = path.lstat()
    except OSError as exc:
        raise SecurityError("required file is unavailable: " + str(path)) from exc
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise SecurityError("required path is not a regular file: " + str(path))
    if before.st_size > maximum:
        raise SecurityError("required file exceeds its bound: " + str(path))
    if mode is not None and stat.S_IMODE(before.st_mode) != mode:
        raise SecurityError("required file mode changed: " + str(path))
    if uid is not None and before.st_uid != uid:
        raise SecurityError("required file owner changed: " + str(path))
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
        try:
            opened = os.fstat(descriptor)
            if _identity(opened) != _identity(before):
                raise SecurityError("required file changed while opening: " + str(path))
            chunks: list[bytes] = []
            total = 0
            while True:
                chunk = os.read(descriptor, min(65536, maximum + 1 - total))
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
                if total > maximum:
                    raise SecurityError("required file exceeds its bound: " + str(path))
        finally:
            os.close(descriptor)
    except OSError as exc:
        raise SecurityError("required file cannot be read: " + str(path)) from exc
    try:
        after = path.lstat()
    except OSError as exc:
        raise SecurityError("required file changed while reading: " + str(path)) from exc
    if _identity(after) != _identity(before):
        raise SecurityError("required file changed while reading: " + str(path))
    return b"".join(chunks), _identity(after)


def _fsync_directory(path: pathlib.Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _atomic_new(path: pathlib.Path, payload: bytes, *, uid: int) -> None:
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    descriptor = os.open(path, flags, 0o600)
    try:
        info = os.fstat(descriptor)
        if info.st_uid != uid or stat.S_IMODE(info.st_mode) != 0o600:
            raise SecurityError("new private file owner or mode is wrong")
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise SecurityError("short private file write")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    _fsync_directory(path.parent)
    current, _ = _read_regular(path, maximum=len(payload), mode=0o600, uid=uid)
    if current != payload:
        raise SecurityError("private file publication did not preserve exact bytes")


def _atomic_replace(
    path: pathlib.Path, *, expected: bytes, payload: bytes, uid: int
) -> None:
    current, _ = _read_regular(path, maximum=MAX_LOCAL_FILE, mode=0o600, uid=uid)
    if current != expected:
        raise SecurityError("private file changed before atomic replacement")
    temporary = path.with_name("." + path.name + ".runtime-next")
    if temporary.exists() or temporary.is_symlink():
        raise SecurityError("private replacement path already exists")
    try:
        _atomic_new(temporary, payload, uid=uid)
        current, _ = _read_regular(path, maximum=MAX_LOCAL_FILE, mode=0o600, uid=uid)
        if current != expected:
            raise SecurityError("private file changed during atomic replacement")
        os.replace(temporary, path)
        _fsync_directory(path.parent)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            temporary.unlink()
        raise
    current, _ = _read_regular(path, maximum=len(payload), mode=0o600, uid=uid)
    if current != payload:
        raise SecurityError("private atomic replacement readback failed")


class DurableJournal:
    """Append-only, hash-chained journal with exact-tail verification."""

    def __init__(self, path: pathlib.Path, *, uid: int, owner: str, run_hex: str) -> None:
        self.path = path
        self.uid = uid
        self.owner = owner
        self.run_hex = run_hex
        self._raw = b""
        self._head = "0" * 64
        self._count = 0
        self._identity: tuple[int, ...] | None = None

    @property
    def head(self) -> str:
        return self._head

    @property
    def count(self) -> int:
        return self._count

    @property
    def digest(self) -> str:
        return _sha256(self._raw)

    def binding(self) -> dict[str, Any]:
        self.verify_current()
        return {
            "artifact_path": str(self.path),
            "artifact_sha256": self.digest,
            "journal_head_sha256": self.head,
            "journal_count": self.count,
        }

    def create(self, anchors: Mapping[str, Any]) -> None:
        if self.path.exists() or self.path.is_symlink():
            raise SecurityError("runtime journal already exists; resume is not implicit")
        entry = self._entry("header", "admitted", {"anchors": dict(anchors)})
        raw = _canonical(entry)
        _atomic_new(self.path, raw, uid=self.uid)
        self._raw = raw
        self._head = entry["record_sha256"]
        self._count = 1
        self._identity = _read_regular(
            self.path, maximum=MAX_LOCAL_FILE, mode=0o600, uid=self.uid
        )[1]

    def _entry(self, kind: str, stage: str, detail: Mapping[str, Any]) -> dict[str, Any]:
        sequence = self._count + 1
        body = {
            "schema": JOURNAL_SCHEMA,
            "sequence": sequence,
            "previous_sha256": self._head,
            "kind": kind,
            "stage": stage,
            "owner": self.owner,
            "run_hex": self.run_hex,
            "at_ns": time.time_ns(),
            "detail": copy.deepcopy(dict(detail)),
        }
        body["record_sha256"] = _sha256(_canonical(body))
        return body

    def verify(self) -> None:
        self.verify_current()
        raw = self._raw
        previous = "0" * 64
        count = 0
        try:
            lines = raw.splitlines(keepends=True)
            if not lines or any(not line.endswith(b"\n") for line in lines):
                raise SecurityError("runtime journal has a torn tail")
            for line in lines:
                value = json.loads(line.decode("ascii"))
                if not isinstance(value, dict):
                    raise SecurityError("runtime journal entry is not an object")
                digest = value.get("record_sha256")
                body = {key: item for key, item in value.items() if key != "record_sha256"}
                count += 1
                if (
                    value.get("schema") != JOURNAL_SCHEMA
                    or value.get("sequence") != count
                    or value.get("previous_sha256") != previous
                    or value.get("owner") != self.owner
                    or value.get("run_hex") != self.run_hex
                    or digest != _sha256(_canonical(body))
                ):
                    raise SecurityError("runtime journal hash chain is invalid")
                previous = digest
        except (UnicodeError, json.JSONDecodeError) as exc:
            raise SecurityError("runtime journal is malformed") from exc
        if count != self._count or previous != self._head:
            raise SecurityError("runtime journal trusted head changed")

    def verify_current(self) -> None:
        """Re-read and hash the exact private bytes before an append/use."""
        if self._identity is None:
            raise SecurityError("runtime journal has no trusted durable binding")
        raw, identity = _read_regular(
            self.path, maximum=MAX_LOCAL_FILE, mode=0o600, uid=self.uid
        )
        if (
            raw != self._raw
            or _sha256(raw) != self.digest
            or identity != self._identity
        ):
            raise SecurityError("runtime journal changed outside the builder")

    def append(self, kind: str, stage: str, detail: Mapping[str, Any]) -> dict[str, Any]:
        self.verify_current()
        entry = self._entry(kind, stage, detail)
        line = _canonical(entry)
        before_info = self.path.lstat()
        flags = os.O_WRONLY | os.O_APPEND | getattr(os, "O_CLOEXEC", 0) | getattr(
            os, "O_NOFOLLOW", 0
        )
        try:
            descriptor = os.open(self.path, flags)
            try:
                opened = os.fstat(descriptor)
                if (
                    (opened.st_dev, opened.st_ino)
                    != (before_info.st_dev, before_info.st_ino)
                    or opened.st_uid != self.uid
                    or stat.S_IMODE(opened.st_mode) != 0o600
                ):
                    raise SecurityError("runtime journal changed while appending")
                view = memoryview(line)
                while view:
                    written = os.write(descriptor, view)
                    if written <= 0:
                        raise SecurityError("runtime journal append was short")
                    view = view[written:]
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        except OSError as exc:
            raise SecurityError("runtime journal append failed") from exc
        expected = self._raw + line
        raw, identity = _read_regular(
            self.path, maximum=MAX_LOCAL_FILE, mode=0o600, uid=self.uid
        )
        if raw != expected:
            raise SecurityError("runtime journal append has an out-of-band tail")
        self._raw = raw
        self._identity = identity
        self._head = entry["record_sha256"]
        self._count += 1
        self.verify_current()
        return copy.deepcopy(entry)


@dataclasses.dataclass
class NamespaceTarget:
    label: str
    pid: int
    start_ticks: int
    netns_inode: int
    mntns_inode: int
    container_name: str | None
    container_id: str | None
    image_id: str | None
    labels: dict[str, str] | None
    descriptor: int | None = None

    def detached(self) -> dict[str, Any]:
        return {
            "label": self.label,
            "pid": self.pid,
            "start_ticks": self.start_ticks,
            "netns_inode": self.netns_inode,
            "mntns_inode": self.mntns_inode,
            "container_name": self.container_name,
            "container_id": self.container_id,
            "image_id": self.image_id,
            "labels": copy.deepcopy(self.labels),
        }


PRIVATE_LINK_HELPER = r'''
import json, os, selectors, subprocess, sys, time

spec = json.loads(sys.argv[1])
deadline = time.monotonic() + float(spec["deadline_seconds"])
maximum = int(spec["maximum_output"])

def run(argv):
    process = subprocess.Popen(argv, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               close_fds=True, start_new_session=False)
    assert process.stdout is not None and process.stderr is not None
    selector = selectors.DefaultSelector()
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    for label, stream in (("stdout", process.stdout), ("stderr", process.stderr)):
        os.set_blocking(stream.fileno(), False)
        selector.register(stream, selectors.EVENT_READ, label)
    while selector.get_map():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            process.kill(); process.wait()
            raise RuntimeError("private helper inner command timed out")
        events = selector.select(min(remaining, 0.05))
        for key, _ in events:
            chunk = os.read(key.fd, 65536)
            if not chunk:
                selector.unregister(key.fileobj); key.fileobj.close(); continue
            if sum(map(len, buffers.values())) + len(chunk) > maximum:
                process.kill(); process.wait()
                raise RuntimeError("private helper inner output exceeded bound")
            buffers[key.data].extend(chunk)
    rc = process.wait(timeout=max(0.001, deadline - time.monotonic()))
    if buffers["stderr"]:
        os.write(2, buffers["stderr"])
    if rc:
        raise RuntimeError("private helper inner command failed rc=%d stdout=%r" %
                           (rc, bytes(buffers["stdout"][:4096])))
    return bytes(buffers["stdout"])

def target_prefix(pid):
    return ["nsenter", "--net=/proc/%d/ns/net" % pid, "--"]

def link(pid, name):
    raw = run(target_prefix(pid) + ["ip", "-j", "-details", "link", "show", "dev", name])
    rows = json.loads(raw)
    if not isinstance(rows, list) or len(rows) != 1:
        raise RuntimeError("private helper link readback is not singular")
    return rows[0]

for target in spec["targets"]:
    pid = int(target["pid"])
    if int(open("/proc/%d/stat" % pid).read().split()[21]) != int(target["start_ticks"]):
        raise RuntimeError("target start time changed")
    if os.stat("/proc/%d/ns/net" % pid).st_ino != int(target["netns_inode"]):
        raise RuntimeError("target namespace changed")
    if os.stat("/proc/%d/ns/mnt" % pid).st_ino != int(target["mntns_inode"]):
        raise RuntimeError("target mount namespace changed")
    descriptor = int(target["descriptor"])
    if descriptor >= 0 and os.fstat(descriptor).st_ino != int(target["netns_inode"]):
        raise RuntimeError("held target namespace descriptor changed")

kind = spec["kind"]
token = spec["alias"]
if kind == "veth":
    left, right = spec["names"]
    run(["ip", "link", "add", left, "type", "veth", "peer", "name", right])
    for name in (left, right):
        run(["ip", "link", "set", "dev", name, "alias", token])
        row = json.loads(run(["ip", "-j", "-details", "link", "show", "dev", name]))[0]
        if row.get("ifalias") != token or row.get("linkinfo", {}).get("info_kind") != "veth":
            raise RuntimeError("staged veth ownership readback failed")
    run(["ip", "link", "set", "dev", left, "netns", str(spec["targets"][0]["pid"])])
    run(["ip", "link", "set", "dev", right, "netns", str(spec["targets"][1]["pid"])])
elif kind == "vxlan":
    name = spec["names"][0]
    target = spec["targets"][0]
    command = target_prefix(int(target["pid"])) + [
        "ip", "link", "add", "name", name, "netns", str(os.getpid()),
        "type", "vxlan", "id", str(spec["vni"]), "dev", spec["underlay"],
        "dstport", str(spec["dstport"]), "local", spec["local"], "nolearning",
    ]
    run(command)
    run(["ip", "link", "set", "dev", name, "alias", token])
    row = json.loads(run(["ip", "-j", "-details", "link", "show", "dev", name]))[0]
    data = row.get("linkinfo", {}).get("info_data", {})
    if (row.get("ifalias") != token or row.get("linkinfo", {}).get("info_kind") != "vxlan"
            or data.get("id") != int(spec["vni"]) or data.get("local") != spec["local"]
            or data.get("port") != int(spec["dstport"]) or data.get("learning") is not False
            or data.get("link") != int(spec["underlay_ifindex"])):
        raise RuntimeError("staged VXLAN ownership readback failed")
    run(["ip", "link", "set", "dev", name, "netns", str(target["pid"])])
else:
    name = spec["names"][0]
    if kind == "vrf":
        command = ["ip", "link", "add", "name", name, "type", "vrf", "table", str(spec["table"])]
    elif kind in ("bridge", "dummy"):
        command = ["ip", "link", "add", "name", name, "type", kind]
    else:
        raise RuntimeError("unsupported private link kind")
    run(command)
    run(["ip", "link", "set", "dev", name, "alias", token])
    row = json.loads(run(["ip", "-j", "-details", "link", "show", "dev", name]))[0]
    if row.get("ifalias") != token or row.get("linkinfo", {}).get("info_kind") != kind:
        raise RuntimeError("staged link ownership readback failed")
    run(["ip", "link", "set", "dev", name, "netns", str(spec["targets"][0]["pid"])])

print(json.dumps({"status": "PUBLISHED", "kind": kind, "names": spec["names"]},
                 sort_keys=True, separators=(",", ":")))
'''


FRR_PROCESS_READER = r'''
space=$1
mode=$2
for daemon in zebra bgpd staticd bfdd; do
    for pid in $(pidof "$daemon" 2>/dev/null || true); do
        [ -r "/proc/$pid/stat" ] && [ -r "/proc/$pid/cmdline" ] || exit 21
        cmd=$(tr '\000' ' ' < "/proc/$pid/cmdline")
        case "$cmd" in *'\t'*|*'\n'*) exit 22;; esac
        include=false
        if [ "$mode" = pathspace ]; then
            case " $cmd " in *" -N $space "*|*"/run/frr/$space"*) include=true;; esac
        else
            include=true
        fi
        if [ "$include" = true ]; then
            start=$(awk '{print $22}' "/proc/$pid/stat")
            case "$pid:$start" in *[!0-9:]*|:*) exit 23;; esac
            printf '%s\t%s\t%s\t%s\n' "$daemon" "$pid" "$start" "$cmd"
        fi
    done
done
'''

FRR_PATHSPACE_STAGE = r'''
space=$1
mkdir -p "/etc/frr/$space" "/run/frr/$space"
printf '%s\n' zebra=yes bgpd=yes staticd=yes bfdd=no ospfd=no ospf6d=no \
    ripd=no ripngd=no isisd=no pimd=no pim6d=no ldpd=no nhrpd=no \
    eigrpd=no sharpd=no pbrd=no fabricd=no vrrpd=no vtysh_enable=yes \
    > "/etc/frr/$space/daemons"
: > "/etc/frr/$space/vtysh.conf"
if getent passwd frr >/dev/null 2>&1; then
    chown -R frr:frr "/etc/frr/$space" "/run/frr/$space"
fi
'''

FRR_PATHSPACE_START = r'''
space=$1
init=
for candidate in /usr/libexec/frr/frrinit.sh /usr/lib/frr/frrinit.sh; do
    if [ -x "$candidate" ]; then init=$candidate; break; fi
done
[ -n "$init" ]
exec "$init" start "$space"
'''

FRR_PATHSPACE_STOP = r'''
space=$1
init=
for candidate in /usr/libexec/frr/frrinit.sh /usr/lib/frr/frrinit.sh; do
    if [ -x "$candidate" ]; then init=$candidate; break; fi
done
[ -n "$init" ]
exec "$init" stop "$space"
'''

FRR_CLIENT_STAGE = r'''
mkdir -p /run/frr
printf '%s\n' zebra=yes bgpd=yes staticd=yes bfdd=yes ospfd=no ospf6d=no \
    ripd=no ripngd=no isisd=no pimd=no pim6d=no ldpd=no nhrpd=no \
    eigrpd=no sharpd=no pbrd=no fabricd=no vrrpd=no vtysh_enable=yes \
    > /etc/frr/daemons
: > /etc/frr/vtysh.conf
if getent passwd frr >/dev/null 2>&1; then
    chown frr:frr /etc/frr/frr.conf /etc/frr/daemons /etc/frr/vtysh.conf
    chown -R frr:frr /run/frr
fi
'''

FRR_CLIENT_ACTION = r'''
action=$1
init=
for candidate in /usr/libexec/frr/frrinit.sh /usr/lib/frr/frrinit.sh; do
    if [ -x "$candidate" ]; then init=$candidate; break; fi
done
[ -n "$init" ]
exec "$init" "$action"
'''

EXPECTED_PATHSPACE_DAEMONS = frozenset({"zebra", "bgpd", "staticd"})
EXPECTED_CLIENT_DAEMONS = frozenset({"zebra", "bgpd", "staticd", "bfdd"})


class RuntimeBuilder:
    """One admitted base-runtime builder and its strict compensator."""

    def __init__(
        self,
        *,
        prepared: Any,
        session: Any,
        config: Any,
        runner: Any,
        runner_call: types.MethodType,
        runner_delegate: Any,
        runner_delegate_type: type[Any],
        runner_delegate_call: types.MethodType,
        runner_delegate_run: Any,
        context: dict[str, Any],
        plan: dict[str, Any],
        nb: Any,
        source_bindings: dict[pathlib.Path, tuple[tuple[int, ...], str]],
    ) -> None:
        self._prepared = prepared
        self._session = session
        self._config = config
        self._runner = runner
        self._runner_call = runner_call
        self._runner_delegate = runner_delegate
        self._runner_delegate_type = runner_delegate_type
        self._runner_delegate_call = runner_delegate_call
        self._runner_delegate_run = runner_delegate_run
        self._consume_lock = session._consume_lock
        self._event_log = session.events
        self._collector = session.collector
        self._context = copy.deepcopy(context)
        self._plan = copy.deepcopy(plan)
        self._resources = {item["id"]: item for item in self._plan["resources"]}
        self._nb = nb
        self._source_bindings = source_bindings
        self._config_binding = self._config_identity(config)
        self._state = "ADMITTED"
        self._unknown = False
        self._journal: DurableJournal | None = None
        self._marker_bytes: bytes | None = None
        self._marker_identity: tuple[int, ...] | None = None
        self._marker_directory_identity: tuple[int, int, int, int] | None = None
        self._targets: dict[str, NamespaceTarget] = {}
        self._bindings: dict[str, Any] = {
            "containers": {},
            "namespaces": {},
            "links": {},
            "ovs": {},
            "generated_vrfs": {},
            "frr": {},
            "ovs_external_ids": None,
            "b_restore": None,
            "nb": {},
        }
        self._built_result: dict[str, Any] | None = None
        self._cleanup_result: dict[str, Any] | None = None
        self._completed_ids: set[str] = set()
        self._capture_contract: dict[str, Any] | None = None
        self._capture_session: Any | None = None
        self._capture_built_marker_bytes: bytes | None = None
        self._capture_last_completed_marker: dict[str, Any] | None = None
        self._capture_stop_call = _require_original_method(
            self,
            "_verify_stopped_captures",
            _RUNTIME_BUILDER_CAPTURE_STOP,
            context="runtime capture-stop gate",
        )
        self._capture_attach_call = _require_original_method(
            self,
            "_attach_capture_session",
            _RUNTIME_BUILDER_CAPTURE_ATTACH,
            context="runtime capture attach friend",
        )
        self._capture_spawn_intent_call = _require_original_method(
            self,
            "_record_capture_spawn_intent",
            _RUNTIME_BUILDER_CAPTURE_SPAWN_INTENT,
            context="runtime capture spawn-intent friend",
        )
        self._capture_progress_call = _require_original_method(
            self,
            "_record_capture_progress",
            _RUNTIME_BUILDER_CAPTURE_PROGRESS,
            context="runtime capture progress friend",
        )
        self._capture_health_call = _require_original_method(
            self,
            "_verify_capture_health",
            _RUNTIME_BUILDER_CAPTURE_HEALTH,
            context="runtime capture health friend",
        )
        self._terminal_finalize_call = _require_original_method(
            self,
            "_finalize_x05_cleanup",
            _RUNTIME_BUILDER_TERMINAL_FINALIZE,
            context="runtime terminal cleanup friend",
        )
        self._session_labctl_call = _require_original_method(
            self._session,
            "_labctl",
            _SESSION_LABCTL,
            context="runtime producer M03 verifier",
        )
        self._built_bindings: dict[str, Any] | None = None
        self._final_absence: dict[str, Any] | None = None
        self._terminal_result: dict[str, Any] | None = None
        producer = self._context["producer"]
        self._owner = producer["owner"]
        self._run_hex = producer["run_hex"]
        self._anchors = copy.deepcopy(self._context["anchors"])
        self._profile_owner = self._anchors["profile_owner"]
        self._image_ids = copy.deepcopy(self._anchors["resolved_images"])
        self._original_container_ids = copy.deepcopy(self._anchors["container_ids"])

    @staticmethod
    def _config_identity(config: Any) -> tuple[Any, ...]:
        return (id(config),) + tuple(
            (field.name, getattr(config, field.name))
            for field in dataclasses.fields(RUNTIME.AdmissionConfig)
        )

    @staticmethod
    def _container_labels(value: Any, context: str) -> dict[str, str]:
        """Normalize Docker's explicit ``null`` and ``{}`` empty label forms."""
        if value is None or value == {}:
            return {}
        if (
            not isinstance(value, dict)
            or any(not isinstance(key, str) or not isinstance(item, str)
                   for key, item in value.items())
        ):
            raise SecurityError(context + " Docker labels are missing or malformed")
        return dict(sorted(value.items()))

    @classmethod
    def from_admission(cls, prepared: Any) -> "RuntimeBuilder":
        """Bind to one exact, active, already-consumed producer capability."""
        if cls is not RuntimeBuilder or type(prepared) is not RUNTIME.PreparedAdmission:
            raise SecurityError("runtime builder requires canonical PreparedAdmission")
        try:
            session = prepared._session
            if (
                type(session) is not RUNTIME.AdmissionSession
                or session._prepared is not prepared
                or type(session.runner) is not RUNTIME._IncidentTrackingRunner
                or type(session.events) is not RUNTIME.DurableEventLog
                or type(session.collector) is not RUNTIME.LiveCollector
                or any(
                    name in session.__dict__
                    for name in (
                        "verify_execution",
                        "execution_context",
                        "record_execution_event",
                    )
                )
                or any(name in session.events.__dict__ for name in ("append", "verify"))
            ):
                raise SecurityError("runtime builder received a foreign producer")
            _SESSION_VERIFY_EXECUTION(session, prepared)
            context = _SESSION_EXECUTION_CONTEXT(session, prepared)
        except SecurityError:
            raise
        except Exception as exc:
            raise SecurityError("runtime admission is stale, foreign, or invalid") from exc
        config = session.config
        if type(config) is not RUNTIME.AdmissionConfig or not prepared.consumed:
            raise SecurityError("runtime admission is not active and consumed")
        runner = session.runner
        if (
            type(runner) is not _INCIDENT_RUNNER_CLASS
            or RUNTIME._IncidentTrackingRunner is not _INCIDENT_RUNNER_CLASS
            or _INCIDENT_RUNNER_CLASS.run is not _INCIDENT_RUNNER_RUN
            or runner._session is not session
        ):
            raise SecurityError("runtime producer runner is not canonical")
        runner_call = _require_original_method(
            runner,
            "run",
            _INCIDENT_RUNNER_RUN,
            context="runtime producer runner",
        )
        runner_delegate = runner._delegate
        runner_delegate_type = type(runner_delegate)
        runner_delegate_run = getattr(runner_delegate_type, "run", None)
        if (
            runner_delegate_run is None
            or (
                not config.test_only_paths
                and (
                    runner_delegate_type is not _PRODUCER_SUBPROCESS_RUNNER_CLASS
                    or runner_delegate_run is not _PRODUCER_SUBPROCESS_RUN
                )
            )
        ):
            raise SecurityError("runtime producer delegate is not canonical")
        runner_delegate_call = _require_original_method(
            runner_delegate,
            "run",
            runner_delegate_run,
            context="runtime producer delegate",
        )
        producer = context.get("producer") if isinstance(context, dict) else None
        paths = producer.get("paths") if isinstance(producer, dict) else None
        if (
            context.get("schema") != "p004-x05-execution-context-v1"
            or context.get("authorizes_mutation") is not False
            or not isinstance(producer, dict)
            or producer.get("run_hex") != config.run_hex
            or producer.get("owner") != config.owner
            or not isinstance(paths, dict)
            or paths.get("evidence") != str(config.evidence_path)
            or paths.get("events") != str(config.event_path)
            or paths.get("snapshot") != str(prepared.snapshot_path)
        ):
            raise SecurityError("runtime execution context does not match producer")
        if OWNER_RE.fullmatch(config.owner) is None:
            raise SecurityError("runtime producer owner is malformed")
        anchors = context.get("anchors")
        snapshot = context.get("snapshot")
        if not isinstance(anchors, dict) or not isinstance(snapshot, dict):
            raise SecurityError("runtime execution context lacks frozen anchors")
        profile_owner = anchors.get("profile_owner")
        if not isinstance(profile_owner, str) or not profile_owner:
            raise SecurityError("runtime execution context lacks DCI profile owner")
        if RUNTIME.PLAN is None or RUNTIME.PREFLIGHT is None:
            raise SecurityError("reviewed runtime plan/preflight modules are unavailable")
        try:
            plan = RUNTIME.PLAN.materialize_plan(
                config.run_hex,
                config.owner,
                str(config.evidence_path),
                profile_owner,
            )
        except (AttributeError, TypeError, ValueError) as exc:
            raise SecurityError("reviewed runtime plan cannot be materialized") from exc
        resources = plan.get("resources") if isinstance(plan, dict) else None
        ids = {
            item.get("id")
            for item in resources
            if isinstance(item, dict) and isinstance(item.get("id"), str)
        } if isinstance(resources, list) else set()
        observed_split = {
            item["id"]
            for item in resources or ()
            if isinstance(item, dict) and item.get("kind") == "ovn-generated-vrf"
        }
        mutable_split = {
            item["id"]
            for item in resources or ()
            if isinstance(item, dict)
            and item.get("id") != MARKER_ID
            and item.get("kind") not in EXCLUDED_COORDINATOR_KINDS
            and item.get("kind") != "ovn-generated-vrf"
        }
        if (
            len(resources or ()) != 43
            or len(ids) != 43
            or mutable_split != BASE_MUTABLE_IDS
            or observed_split != GENERATED_VRF_IDS
            or MARKER_ID not in ids
        ):
            raise SecurityError("runtime inventory is not the frozen 32+1+3 base split")
        if (
            snapshot.get("runtime_plan_sha256") != plan.get("runtime_plan_sha256")
            or snapshot.get("run_hex") != config.run_hex
            or snapshot.get("owner") != config.owner
            or snapshot.get("evidence_path") != str(config.evidence_path)
        ):
            raise SecurityError("runtime plan is not bound to the admitted snapshot")
        marker = snapshot.get("x05_marker")
        if (
            marker != {"path": str(RUNTIME.DEFAULT_X05_MARKER), "exists": False}
            or config.x05_marker_path.exists()
            or config.x05_marker_path.is_symlink()
        ):
            raise SecurityError("X05 marker was not absent at admission handoff")
        relative_sources = (
            "studies/p004/ovn/x05-runtime-plan.py",
            "studies/p004/ovn/x05-runtime-preflight.py",
            "studies/p004/ovn/x05-runtime-apply.py",
            "studies/p004/ovn/x05-capture.py",
        )
        source_bindings: dict[pathlib.Path, tuple[tuple[int, ...], str]] = {}
        for relative in relative_sources:
            expected = RUNTIME.REVIEWED_BUNDLE_FILES.get(relative)
            if not isinstance(expected, str) or HEX64_RE.fullmatch(expected) is None:
                raise SecurityError("runtime source lacks a reviewed producer pin: " + relative)
            path = config.bundle_root / relative
            raw, identity = _read_regular(
                path,
                maximum=MAX_LOCAL_FILE,
                uid=config.required_uid,
            )
            if stat.S_IMODE(identity[5]) & 0o022 or _sha256(raw) != expected:
                raise SecurityError("reviewed runtime source changed: " + relative)
            source_bindings[path] = (identity, expected)
        current_apply, _ = _read_regular(SOURCE_PATH, maximum=MAX_LOCAL_FILE)
        if _sha256(current_apply) != RUNTIME.REVIEWED_BUNDLE_FILES[
            "studies/p004/ovn/x05-runtime-apply.py"
        ]:
            raise SecurityError("loaded runtime builder differs from reviewed source")
        nb = NB.NBAdapter.from_admission(prepared)
        builder = cls(
            prepared=prepared,
            session=session,
            config=config,
            runner=runner,
            runner_call=runner_call,
            runner_delegate=runner_delegate,
            runner_delegate_type=runner_delegate_type,
            runner_delegate_call=runner_delegate_call,
            runner_delegate_run=runner_delegate_run,
            context=context,
            plan=plan,
            nb=nb,
            source_bindings=source_bindings,
        )
        builder._verify_authority()
        return builder

    def _verify_sources(self) -> None:
        for path, (identity, digest) in self._source_bindings.items():
            raw, current = _read_regular(
                path,
                maximum=MAX_LOCAL_FILE,
                uid=self._config.required_uid,
            )
            if current != identity or _sha256(raw) != digest:
                raise SecurityError("reviewed runtime source changed after binding")

    def _verify_object_bindings(self) -> None:
        if (
            type(self) is not RuntimeBuilder
            or self._session.config is not self._config
            or self._config_identity(self._config) != self._config_binding
            or self._runner is not self._session.runner
            or self._runner._delegate is not self._runner_delegate
            or self._runner._session is not self._session
            or RUNTIME._IncidentTrackingRunner is not _INCIDENT_RUNNER_CLASS
            or type(self._runner) is not _INCIDENT_RUNNER_CLASS
            or self._runner_delegate_type is not type(self._runner_delegate)
            or getattr(self._runner_delegate_type, "run", None)
            is not self._runner_delegate_run
            or (
                not self._config.test_only_paths
                and (
                    self._runner_delegate_type is not _PRODUCER_SUBPROCESS_RUNNER_CLASS
                    or self._runner_delegate_run is not _PRODUCER_SUBPROCESS_RUN
                )
            )
            or self._consume_lock is not self._session._consume_lock
            or type(self._consume_lock) is not _PRODUCER_RLOCK_TYPE
            or self._event_log is not self._session.events
            or self._collector is not self._session.collector
            or self._collector.runner is not self._runner
            or type(self._event_log) is not RUNTIME.DurableEventLog
            or type(self._collector) is not RUNTIME.LiveCollector
            or any(
                name in self._session.__dict__
                for name in (
                    "verify_execution",
                    "execution_context",
                    "record_execution_event",
                    "_labctl",
                )
            )
            or any(name in self._event_log.__dict__ for name in ("append", "verify"))
            or RUNTIME.AdmissionSession.verify_execution is not _SESSION_VERIFY_EXECUTION
            or RUNTIME.AdmissionSession.execution_context is not _SESSION_EXECUTION_CONTEXT
            or RUNTIME.AdmissionSession.record_execution_event
            is not _SESSION_RECORD_EXECUTION_EVENT
            or RUNTIME.AdmissionSession._labctl is not _SESSION_LABCTL
            or RUNTIME.DurableEventLog.append is not _EVENT_LOG_APPEND
            or RUNTIME.DurableEventLog.verify is not _EVENT_LOG_VERIFY
            or RUNTIME.LiveCollector.owned_m03_identity
            is not _COLLECTOR_OWNED_M03_IDENTITY
            or self._prepared._session is not self._session
            or not self._prepared.consumed
            or self._config.owner != self._owner
            or self._config.run_hex != self._run_hex
            or type(self._nb) is not NB.NBAdapter
            or NB.NBAdapter.forward is not _NB_FORWARD
            or NB.NBAdapter.inverse is not _NB_INVERSE
            or self._nb._producer_session is not self._session
            or self._nb._prepared is not self._prepared
            or self._nb._producer_config is not self._config
            or self._nb._producer_runner_object is not self._runner
            or self._nb._producer_runner.prepared is not self._prepared
        ):
            raise SecurityError("runtime producer/config/runner binding changed")
        for owner, name, implementation, expected, context in (
            (
                self._runner,
                "run",
                _INCIDENT_RUNNER_RUN,
                self._runner_call,
                "runtime producer runner",
            ),
            (
                self._runner_delegate,
                "run",
                self._runner_delegate_run,
                self._runner_delegate_call,
                "runtime producer delegate",
            ),
            (
                self,
                "_verify_stopped_captures",
                _RUNTIME_BUILDER_CAPTURE_STOP,
                self._capture_stop_call,
                "runtime capture-stop gate",
            ),
            (
                self,
                "_attach_capture_session",
                _RUNTIME_BUILDER_CAPTURE_ATTACH,
                self._capture_attach_call,
                "runtime capture attach friend",
            ),
            (
                self,
                "_record_capture_spawn_intent",
                _RUNTIME_BUILDER_CAPTURE_SPAWN_INTENT,
                self._capture_spawn_intent_call,
                "runtime capture spawn-intent friend",
            ),
            (
                self,
                "_record_capture_progress",
                _RUNTIME_BUILDER_CAPTURE_PROGRESS,
                self._capture_progress_call,
                "runtime capture progress friend",
            ),
            (
                self,
                "_verify_capture_health",
                _RUNTIME_BUILDER_CAPTURE_HEALTH,
                self._capture_health_call,
                "runtime capture health friend",
            ),
            (
                self,
                "_finalize_x05_cleanup",
                _RUNTIME_BUILDER_TERMINAL_FINALIZE,
                self._terminal_finalize_call,
                "runtime terminal cleanup friend",
            ),
            (
                self._session,
                "_labctl",
                _SESSION_LABCTL,
                self._session_labctl_call,
                "runtime producer M03 verifier",
            ),
        ):
            current = _require_original_method(
                owner,
                name,
                implementation,
                context=context,
            )
            if not _same_bound_method(
                current,
                expected,
                owner=owner,
                implementation=implementation,
            ):
                raise SecurityError(context + " captured implementation changed")

    def _verify_authority(self) -> None:
        self._verify_object_bindings()
        _SESSION_VERIFY_EXECUTION(self._session, self._prepared)
        self._verify_sources()
        if self._journal is not None:
            self._journal.verify_current()
        if self._marker_directory_identity is not None:
            info = self._config.x05_marker_path.parent.lstat()
            current_directory = (
                info.st_dev,
                info.st_ino,
                info.st_mode,
                info.st_uid,
            )
            if (
                stat.S_ISLNK(info.st_mode)
                or not stat.S_ISDIR(info.st_mode)
                or current_directory != self._marker_directory_identity
            ):
                raise SecurityError("X05 marker directory changed outside the builder")
        if self._marker_bytes is not None:
            raw, identity = _read_regular(
                self._config.x05_marker_path,
                maximum=65536,
                mode=0o600,
                uid=self._config.required_uid,
            )
            if raw != self._marker_bytes or identity != self._marker_identity:
                raise SecurityError("X05 marker changed outside the builder")

    def _mark_late_callable_drift(
        self, operation: str, failure: BaseException
    ) -> None:
        self._unknown = True
        if self._journal is not None:
            if self._state in {"COMPENSATING", "COMPENSATED", "CLEANUP_FAILED"}:
                self._state = "CLEANUP_FAILED"
            else:
                self._state = "FAILED"
            with contextlib.suppress(Exception):
                self._journal.append(
                    "operation-terminal",
                    operation + "-callable-binding",
                    {
                        "status": "UNKNOWN",
                        "operation": "callable-binding",
                        "resource_ids": [],
                    },
                )
        raise AmbiguousEffect(
            operation + " callable binding changed before operation exit"
        ) from failure

    @contextlib.contextmanager
    def _operation_scope(self, operation: str):
        """Serialize one public operation and verify callable drift at exit."""
        self._verify_object_bindings()
        with self._consume_lock:
            self._verify_authority()
            try:
                yield
            except BaseException:
                try:
                    self._verify_object_bindings()
                except Exception as drift:
                    self._mark_late_callable_drift(operation, drift)
                raise
            try:
                self._verify_object_bindings()
            except Exception as drift:
                self._mark_late_callable_drift(operation, drift)
            self._verify_authority()

    def _journal_append(
        self, kind: str, stage: str, detail: Mapping[str, Any]
    ) -> dict[str, Any]:
        if self._journal is None:
            raise SecurityError("runtime journal has not been created")
        return self._journal.append(kind, stage, detail)

    def _publish(self, event: str, stage: str, detail: Mapping[str, Any]) -> None:
        if self._journal is None:
            raise SecurityError("runtime journal has not been created")
        with self._consume_lock:
            self._verify_object_bindings()
            binding = self._journal.binding()
            parent_detail = {
                "stage": stage,
                "status": detail.get("status"),
                "operation": detail.get("operation"),
                "resource_ids": list(detail.get("resource_ids", ())),
                **binding,
            }
            for key in (
                "command_sha256",
                "stdout_sha256",
                "stderr_sha256",
                "readback_sha256",
                "state",
            ):
                if key in detail:
                    parent_detail[key] = detail[key]
            try:
                record = _SESSION_RECORD_EXECUTION_EVENT(
                    self._session, self._prepared, event, parent_detail
                )
            except BaseException:
                self._verify_object_bindings()
                raise
            self._verify_object_bindings()
            self._journal_append(
                "producer-link",
                stage,
                {
                    "event": event,
                    "sequence": record["sequence"],
                    "event_sha256": record["event_sha256"],
                    "linked_journal_sha256": binding["artifact_sha256"],
                    "linked_journal_head_sha256": binding["journal_head_sha256"],
                },
            )
            self._verify_object_bindings()

    @staticmethod
    def _command_digest(argv: Sequence[str]) -> str:
        return _sha256(_canonical(list(argv)))

    def _checked_result(self, result: Any, argv: tuple[str, ...]) -> Any:
        if type(result) is not RUNTIME.CommandResult:
            raise AmbiguousEffect("runner returned a foreign or incomplete result")
        if (
            type(result.argv) is not tuple
            or result.argv != argv
            or any(type(item) is not str for item in result.argv)
            or type(result.returncode) is not int
            or type(result.stdout) is not bytes
            or type(result.stderr) is not bytes
            or type(result.elapsed) not in (int, float)
            or not math.isfinite(result.elapsed)
            or result.elapsed < 0
            or len(result.stdout) + len(result.stderr) > RUNTIME.MAX_OUTPUT
        ):
            raise AmbiguousEffect("runner result fields are incomplete or inconsistent")
        return result

    def _dispatch(
        self, argv: Sequence[str], *, pass_fds: Sequence[int] = ()
    ) -> Any:
        command = tuple(argv)
        if not command or any(not isinstance(item, str) or not item for item in command):
            raise SecurityError("runtime command argv is invalid")
        with self._consume_lock:
            self._verify_authority()
            runner_call = self._runner_call
            try:
                result = runner_call(
                    command,
                    env=RUNTIME.BASE_ENV,
                    timeout=self._config.command_timeout,
                    pass_fds=tuple(pass_fds),
                    max_output_bytes=RUNTIME.MAX_OUTPUT,
                )
            except BaseException as exc:
                raise AmbiguousEffect("runtime command outcome is unknown") from exc
            try:
                self._verify_authority()
            except Exception as exc:
                raise AmbiguousEffect(
                    "runtime command binding changed after dispatch"
                ) from exc
            return self._checked_result(result, command)

    def _read_command(
        self,
        stage: str,
        argv: Sequence[str],
        *,
        allowed_rc: frozenset[int] = frozenset({0}),
    ) -> Any:
        result = self._dispatch(argv)
        detail = {
            "status": "READ",
            "operation": "uncached-readback",
            "resource_ids": [],
            "command_sha256": self._command_digest(argv),
            "stdout_sha256": _sha256(result.stdout),
            "stderr_sha256": _sha256(result.stderr),
            "returncode": result.returncode,
        }
        self._journal_append("readback", stage, detail)
        if result.returncode not in allowed_rc:
            raise PostconditionError("runtime readback failed: " + stage)
        return result

    def _effect(
        self,
        stage: str,
        resource_ids: Sequence[str],
        argv: Sequence[str],
        postcondition: Callable[[Any], Any],
        *,
        pass_fds: Sequence[int] = (),
        allowed_stderr: frozenset[bytes] | None = None,
    ) -> Any:
        self._verify_authority()
        if self._unknown:
            raise SecurityError("an earlier runtime effect is unresolved")
        ids = list(resource_ids)
        if not ids or any(item not in self._resources for item in ids):
            raise SecurityError("runtime effect has an unreviewed resource identity")
        intent = {
            "status": "INTENT",
            "operation": "command",
            "resource_ids": ids,
            "command_sha256": self._command_digest(argv),
        }
        self._journal_append("effect-intent", stage, {**intent, "argv": list(argv)})
        self._publish("x05-runtime-intent", stage, intent)
        try:
            result = self._dispatch(argv, pass_fds=pass_fds)
        except BaseException as exc:
            self._unknown = True
            with contextlib.suppress(Exception):
                unknown = {
                    "status": "UNKNOWN",
                    "operation": "command",
                    "resource_ids": ids,
                    "command_sha256": intent["command_sha256"],
                }
                self._journal_append("effect-outcome", stage, unknown)
                self._publish("x05-runtime-outcome", stage, unknown)
            if isinstance(exc, AmbiguousEffect):
                raise
            raise AmbiguousEffect("runtime effect outcome is unknown") from exc
        outcome = {
            "status": "DISPATCHED",
            "operation": "command",
            "resource_ids": ids,
            "command_sha256": intent["command_sha256"],
            "returncode": result.returncode,
            "stdout_sha256": _sha256(result.stdout),
            "stderr_sha256": _sha256(result.stderr),
            "stdout_bytes": len(result.stdout),
            "stderr_bytes": len(result.stderr),
        }
        self._journal_append("effect-outcome", stage, outcome)
        self._publish("x05-runtime-outcome", stage, outcome)
        if result.returncode != 0:
            self._unknown = True
            raise AmbiguousEffect("dispatched runtime effect returned nonzero")
        if allowed_stderr is not None and result.stderr not in allowed_stderr:
            self._unknown = True
            raise AmbiguousEffect("runtime effect emitted unreviewed stderr")
        try:
            checked = postcondition(result)
        except BaseException as exc:
            self._unknown = True
            with contextlib.suppress(Exception):
                failed = {
                    "status": "UNKNOWN",
                    "operation": "postcondition",
                    "resource_ids": ids,
                    "command_sha256": intent["command_sha256"],
                }
                self._journal_append("effect-readback", stage, failed)
                self._publish("x05-runtime-readback", stage, failed)
            if isinstance(exc, BuilderError):
                raise AmbiguousEffect(str(exc)) from exc
            raise AmbiguousEffect("runtime effect postcondition is unknown") from exc
        readback_digest = _sha256(_canonical(checked))
        readback = {
            "status": "VERIFIED",
            "operation": "postcondition",
            "resource_ids": ids,
            "readback_sha256": readback_digest,
        }
        self._journal_append("effect-readback", stage, {**readback, "checked": checked})
        self._publish("x05-runtime-readback", stage, readback)
        return checked

    def _local_effect(
        self,
        stage: str,
        resource_ids: Sequence[str],
        operation: str,
        action: Callable[[], Any],
        postcondition: Callable[[Any], Any],
    ) -> Any:
        self._verify_authority()
        if self._unknown:
            raise SecurityError("an earlier runtime effect is unresolved")
        ids = list(resource_ids)
        if not ids or any(item not in self._resources for item in ids):
            raise SecurityError("local runtime effect has an unreviewed identity")
        intent = {
            "status": "INTENT",
            "operation": operation,
            "resource_ids": ids,
            "command_sha256": _sha256(_canonical(["local", operation])),
        }
        self._journal_append("effect-intent", stage, intent)
        self._publish("x05-runtime-intent", stage, intent)
        try:
            value = action()
        except BaseException as exc:
            self._unknown = True
            with contextlib.suppress(Exception):
                unknown = {**intent, "status": "UNKNOWN"}
                self._journal_append("effect-outcome", stage, unknown)
                self._publish("x05-runtime-outcome", stage, unknown)
            raise AmbiguousEffect("local durable effect outcome is unknown") from exc
        outcome = {**intent, "status": "DISPATCHED"}
        self._journal_append("effect-outcome", stage, outcome)
        self._publish("x05-runtime-outcome", stage, outcome)
        try:
            checked = postcondition(value)
        except BaseException as exc:
            self._unknown = True
            raise AmbiguousEffect("local durable effect postcondition failed") from exc
        detail = {
            "status": "VERIFIED",
            "operation": operation,
            "resource_ids": ids,
            "readback_sha256": _sha256(_canonical(checked)),
        }
        self._journal_append("effect-readback", stage, {**detail, "checked": checked})
        self._publish("x05-runtime-readback", stage, detail)
        return checked

    def _library_effect(
        self,
        stage: str,
        resource_ids: Sequence[str],
        operation: str,
        action: Callable[[], Any],
        postcondition: Callable[[Any], Any],
    ) -> Any:
        self._verify_authority()
        if self._unknown:
            raise SecurityError("an earlier runtime effect is unresolved")
        ids = list(resource_ids)
        if not ids or any(item not in self._resources for item in ids):
            raise SecurityError("library runtime effect has an unreviewed identity")
        intent = {
            "status": "INTENT",
            "operation": operation,
            "resource_ids": ids,
            "command_sha256": _sha256(_canonical(["library", operation])),
        }
        self._journal_append("effect-intent", stage, intent)
        self._publish("x05-runtime-intent", stage, intent)
        try:
            value = action()
        except BaseException as exc:
            self._unknown = True
            with contextlib.suppress(Exception):
                unknown = {**intent, "status": "UNKNOWN"}
                self._journal_append("effect-outcome", stage, unknown)
                self._publish("x05-runtime-outcome", stage, unknown)
            raise AmbiguousEffect(operation + " outcome is unresolved") from exc
        self._verify_authority()
        outcome = {**intent, "status": "DISPATCHED"}
        self._journal_append("effect-outcome", stage, outcome)
        self._publish("x05-runtime-outcome", stage, outcome)
        try:
            checked = postcondition(value)
        except BaseException as exc:
            self._unknown = True
            raise AmbiguousEffect(operation + " postcondition is unresolved") from exc
        detail = {
            "status": "VERIFIED",
            "operation": operation,
            "resource_ids": ids,
            "readback_sha256": _sha256(_canonical(checked)),
        }
        self._journal_append("effect-readback", stage, {**detail, "checked": checked})
        self._publish("x05-runtime-readback", stage, detail)
        return checked

    @staticmethod
    def _json(raw: bytes, context: str) -> Any:
        try:
            return json.loads(
                raw.decode("utf-8"),
                object_pairs_hook=lambda pairs: RuntimeBuilder._unique_object(
                    pairs, context
                ),
                parse_constant=lambda value: (_ for _ in ()).throw(
                    PostconditionError(context + " contains " + value)
                ),
            )
        except (UnicodeError, json.JSONDecodeError) as exc:
            raise PostconditionError(context + " is not strict JSON") from exc

    @staticmethod
    def _unique_object(pairs: list[tuple[str, Any]], context: str) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in pairs:
            if key in value:
                raise PostconditionError(context + " contains duplicate JSON key")
            value[key] = item
        return value

    @classmethod
    def _decode_ovs(cls, value: Any, context: str) -> Any:
        if isinstance(value, list) and len(value) == 2 and value[0] == "uuid":
            if not isinstance(value[1], str) or UUID_RE.fullmatch(value[1]) is None:
                raise PostconditionError(context + " has malformed UUID")
            return value[1].lower()
        if isinstance(value, list) and len(value) == 2 and value[0] == "map":
            if not isinstance(value[1], list):
                raise PostconditionError(context + " has malformed map")
            result: dict[str, Any] = {}
            for pair in value[1]:
                if (
                    not isinstance(pair, list)
                    or len(pair) != 2
                    or not isinstance(pair[0], str)
                    or pair[0] in result
                ):
                    raise PostconditionError(context + " has malformed map entry")
                result[pair[0]] = cls._decode_ovs(pair[1], context)
            return result
        if isinstance(value, list) and len(value) == 2 and value[0] == "set":
            if not isinstance(value[1], list):
                raise PostconditionError(context + " has malformed set")
            decoded = [cls._decode_ovs(item, context) for item in value[1]]
            if len({_canonical(item) for item in decoded}) != len(decoded):
                raise PostconditionError(context + " has duplicate set atom")
            return decoded
        if isinstance(value, list):
            return [cls._decode_ovs(item, context) for item in value]
        if isinstance(value, dict):
            return {key: cls._decode_ovs(item, context) for key, item in value.items()}
        return value

    @classmethod
    def _ovs_rows(cls, raw: bytes, context: str) -> list[dict[str, Any]]:
        value = cls._json(raw, context)
        if not isinstance(value, dict) or set(value) != {"headings", "data"}:
            raise PostconditionError(context + " has malformed OVS table")
        headings, data = value["headings"], value["data"]
        if (
            not isinstance(headings, list)
            or not headings
            or len(set(headings)) != len(headings)
            or not all(isinstance(item, str) for item in headings)
            or not isinstance(data, list)
        ):
            raise PostconditionError(context + " has malformed OVS headings")
        rows: list[dict[str, Any]] = []
        for raw_row in data:
            if not isinstance(raw_row, list) or len(raw_row) != len(headings):
                raise PostconditionError(context + " has malformed OVS row")
            rows.append(
                {
                    heading: cls._decode_ovs(item, context + ":" + heading)
                    for heading, item in zip(headings, raw_row)
                }
            )
        return rows

    @staticmethod
    def _process_start_ticks(raw: bytes, context: str) -> int:
        try:
            text = raw.decode("ascii").strip()
            closing = text.rfind(")")
            fields = text[closing + 2 :].split()
            value = int(fields[19])
        except (UnicodeError, ValueError, IndexError) as exc:
            raise PostconditionError(context + " process stat is malformed") from exc
        if value <= 0:
            raise PostconditionError(context + " process start time is invalid")
        return value

    @staticmethod
    def _positive_int(raw: bytes, context: str) -> int:
        try:
            value = int(raw.decode("ascii").strip())
        except (UnicodeError, ValueError) as exc:
            raise PostconditionError(context + " is not an integer") from exc
        if value <= 0:
            raise PostconditionError(context + " is not positive")
        return value

    def _docker_inspect(self, name_or_id: str, stage: str) -> dict[str, Any]:
        result = self._read_command(
            stage, ("docker", "container", "inspect", name_or_id)
        )
        value = self._json(result.stdout, stage)
        if not isinstance(value, list) or len(value) != 1 or not isinstance(value[0], dict):
            raise PostconditionError(stage + " Docker inspect is not singular")
        return value[0]

    def _validate_container_row(
        self,
        row: dict[str, Any],
        *,
        name: str,
        container_id: str,
        image_id: str,
        labels: Mapping[str, str],
    ) -> dict[str, Any]:
        state = row.get("State")
        config = row.get("Config")
        actual_name = row.get("Name")
        if isinstance(actual_name, str):
            actual_name = actual_name.removeprefix("/")
        if (
            row.get("Id") != container_id
            or actual_name != name
            or row.get("Image") != image_id
            or not isinstance(state, dict)
            or state.get("Status") != "running"
            or state.get("Running") is not True
            or type(state.get("Pid")) is not int
            or state["Pid"] <= 0
            or not isinstance(config, dict)
            or "Labels" not in config
        ):
            raise PostconditionError("Docker container identity is not exact: " + name)
        actual_labels = self._container_labels(
            config["Labels"], "created container " + name
        )
        if actual_labels != dict(labels):
            raise PostconditionError("Docker container labels are not exact: " + name)
        configured_image = config.get("Image")
        if configured_image not in {image_id, image_id.removeprefix("sha256:")}:
            raise PostconditionError("Docker configured image is not immutable: " + name)
        return {
            "name": name,
            "id": container_id,
            "image_id": image_id,
            "configured_image": configured_image,
            "labels": copy.deepcopy(actual_labels),
            "pid": state["Pid"],
        }

    def _capture_target(
        self,
        label: str,
        *,
        container_name: str | None = None,
        container_id: str | None = None,
    ) -> NamespaceTarget:
        if label in self._targets:
            target = self._targets[label]
            self._verify_target(target)
            return target
        if container_name is None:
            pid = os.getpid()
            actual_id = None
            captured_image = None
            captured_labels = None
        else:
            if container_id is None:
                raise SecurityError("container namespace target lacks captured ID")
            if container_name in self._bindings["containers"]:
                binding = self._bindings["containers"][container_name]
                image_id = binding["image_id"]
                labels = binding["labels"]
            else:
                image_id = None
                if container_name == "dci-evpn-client-1":
                    labels = self._container_labels(
                        self._anchors.get("m03_peer", {}).get("labels"),
                        "M03 peer container " + container_name,
                    )
                else:
                    label_map = self._context["snapshot"]["sections"]["dci"].get(
                        "container_labels"
                    )
                    if not isinstance(label_map, dict) or container_name not in label_map:
                        raise SecurityError(
                            "snapshot lacks original container labels: " + container_name
                        )
                    labels = self._container_labels(
                        label_map[container_name],
                        "snapshot container " + container_name,
                    )
            row = self._docker_inspect(container_id, "target-inspect-" + label)
            actual_name = row.get("Name")
            if isinstance(actual_name, str):
                actual_name = actual_name.removeprefix("/")
            state = row.get("State")
            if (
                row.get("Id") != container_id
                or actual_name != container_name
                or not isinstance(state, dict)
                or state.get("Status") != "running"
                or type(state.get("Pid")) is not int
                or state["Pid"] <= 0
                or not isinstance(row.get("Image"), str)
                or IMAGE_ID_RE.fullmatch(row["Image"]) is None
                or (image_id is not None and row["Image"] != image_id)
                or not isinstance(row.get("Config"), dict)
                or "Labels" not in row["Config"]
                or labels is None
            ):
                raise SecurityError("container namespace source identity changed: " + label)
            actual_labels = self._container_labels(
                row["Config"]["Labels"], "container source " + label
            )
            if actual_labels != labels:
                raise SecurityError("container namespace source labels changed: " + label)
            pid = state["Pid"]
            actual_id = container_id
            captured_image = row["Image"]
            captured_labels = copy.deepcopy(labels)
        stat_result = self._read_command(
            "target-start-" + label, ("cat", f"/proc/{pid}/stat")
        )
        start_ticks = self._process_start_ticks(stat_result.stdout, label)
        inode_result = self._read_command(
            "target-netns-" + label,
            ("stat", "-Lc", "%i", f"/proc/{pid}/ns/net"),
        )
        inode = self._positive_int(inode_result.stdout, label + " netns")
        mnt_inode_result = self._read_command(
            "target-mntns-" + label,
            ("stat", "-Lc", "%i", f"/proc/{pid}/ns/mnt"),
        )
        mnt_inode = self._positive_int(mnt_inode_result.stdout, label + " mntns")
        descriptor: int | None = None
        if not self._config.test_only_paths:
            try:
                descriptor = os.open(
                    f"/proc/{pid}/ns/net",
                    os.O_RDONLY | getattr(os, "O_CLOEXEC", 0),
                )
                if os.fstat(descriptor).st_ino != inode:
                    raise SecurityError("target namespace changed while pinning")
            except BaseException:
                if descriptor is not None:
                    os.close(descriptor)
                raise
        target = NamespaceTarget(
            label=label,
            pid=pid,
            start_ticks=start_ticks,
            netns_inode=inode,
            mntns_inode=mnt_inode,
            container_name=container_name,
            container_id=actual_id,
            image_id=captured_image,
            labels=captured_labels,
            descriptor=descriptor,
        )
        self._targets[label] = target
        self._verify_target(target)
        return target

    def _verify_target(self, target: NamespaceTarget) -> None:
        if target.container_id is not None:
            row = self._docker_inspect(
                target.container_id, "target-recheck-inspect-" + target.label
            )
            state = row.get("State")
            name = row.get("Name")
            if isinstance(name, str):
                name = name.removeprefix("/")
            if (
                row.get("Id") != target.container_id
                or name != target.container_name
                or not isinstance(state, dict)
                or state.get("Status") != "running"
                or state.get("Pid") != target.pid
                or row.get("Image") != target.image_id
                or not isinstance(row.get("Config"), dict)
                or "Labels" not in row["Config"]
            ):
                raise SecurityError("container target changed: " + target.label)
            if self._container_labels(
                row["Config"]["Labels"], "container target " + target.label
            ) != target.labels:
                raise SecurityError("container target labels changed: " + target.label)
        start = self._read_command(
            "target-recheck-start-" + target.label,
            ("cat", f"/proc/{target.pid}/stat"),
        )
        inode = self._read_command(
            "target-recheck-netns-" + target.label,
            ("stat", "-Lc", "%i", f"/proc/{target.pid}/ns/net"),
        )
        mnt_inode = self._read_command(
            "target-recheck-mntns-" + target.label,
            ("stat", "-Lc", "%i", f"/proc/{target.pid}/ns/mnt"),
        )
        if (
            self._process_start_ticks(start.stdout, target.label) != target.start_ticks
            or self._positive_int(inode.stdout, target.label) != target.netns_inode
            or self._positive_int(mnt_inode.stdout, target.label)
            != target.mntns_inode
            or (
                target.descriptor is not None
                and os.fstat(target.descriptor).st_ino != target.netns_inode
            )
        ):
            raise SecurityError("namespace target identity changed: " + target.label)

    def _close_target(self, label: str) -> None:
        target = self._targets.pop(label, None)
        if target is not None and target.descriptor is not None:
            os.close(target.descriptor)
            target.descriptor = None

    def _target_command(self, target: NamespaceTarget, *argv: str) -> tuple[str, ...]:
        self._verify_target(target)
        if target.container_id is None:
            return tuple(argv)
        return (
            "nsenter",
            "--target",
            str(target.pid),
            "--net",
            "--",
            *argv,
        )

    def _nested_command(
        self, target: NamespaceTarget, namespace: str, *argv: str
    ) -> tuple[str, ...]:
        self._verify_target(target)
        if target.container_id is None:
            raise SecurityError("named netns command requires a container target")
        return (
            "docker",
            "exec",
            target.container_id,
            "ip",
            "netns",
            "exec",
            namespace,
            *argv,
        )

    def _link_read(
        self,
        stage: str,
        target: NamespaceTarget,
        name: str,
        *,
        namespace: str | None = None,
    ) -> dict[str, Any]:
        if IFNAME_RE.fullmatch(name) is None:
            raise SecurityError("unreviewed Linux interface name")
        command = (
            self._nested_command(
                target, namespace, "ip", "-j", "-details", "link", "show", "dev", name
            )
            if namespace is not None
            else self._target_command(
                target, "ip", "-j", "-details", "link", "show", "dev", name
            )
        )
        result = self._read_command(stage + "-link", command)
        rows = self._json(result.stdout, stage + " link")
        if not isinstance(rows, list) or len(rows) != 1 or not isinstance(rows[0], dict):
            raise PostconditionError(stage + " link readback is not singular")
        row = rows[0]
        if (
            row.get("ifname") != name
            or type(row.get("ifindex")) is not int
            or row["ifindex"] <= 0
            or not isinstance(row.get("address"), str)
            or type(row.get("mtu")) is not int
            or row["mtu"] <= 0
        ):
            raise PostconditionError(stage + " link identity is incomplete")
        prefix = (
            self._nested_command(target, namespace, "cat")[:-1]
            if namespace is not None
            else self._target_command(target, "cat")[:-1]
        )
        # Build the two fixed /sys reads explicitly; dropping the temporary
        # trailing ``cat`` avoids accepting an arbitrary command suffix.
        if namespace is not None:
            ifindex_command = self._nested_command(
                target, namespace, "cat", f"/sys/class/net/{name}/ifindex"
            )
            iflink_command = self._nested_command(
                target, namespace, "cat", f"/sys/class/net/{name}/iflink"
            )
        else:
            ifindex_command = self._target_command(
                target, "cat", f"/sys/class/net/{name}/ifindex"
            )
            iflink_command = self._target_command(
                target, "cat", f"/sys/class/net/{name}/iflink"
            )
        del prefix
        sys_index = self._positive_int(
            self._read_command(stage + "-ifindex", ifindex_command).stdout,
            stage + " ifindex",
        )
        sys_link = self._positive_int(
            self._read_command(stage + "-iflink", iflink_command).stdout,
            stage + " iflink",
        )
        if sys_index != row["ifindex"]:
            raise PostconditionError(stage + " ip/sys ifindex mismatch")
        return {
            "target": target.detached(),
            "namespace": namespace,
            "name": name,
            "ifindex": sys_index,
            "iflink": sys_link,
            "alias": row.get("ifalias"),
            "mac": row["address"].lower(),
            "mtu": row["mtu"],
            "operstate": row.get("operstate"),
            "flags": copy.deepcopy(row.get("flags")),
            "master": row.get("master"),
            "linkinfo": copy.deepcopy(row.get("linkinfo")),
        }

    def _address_read(
        self,
        stage: str,
        target: NamespaceTarget,
        name: str,
        *,
        namespace: str | None = None,
    ) -> list[str]:
        command = (
            self._nested_command(
                target, namespace, "ip", "-j", "-4", "address", "show", "dev", name
            )
            if namespace is not None
            else self._target_command(
                target, "ip", "-j", "-4", "address", "show", "dev", name
            )
        )
        rows = self._json(self._read_command(stage, command).stdout, stage)
        if not isinstance(rows, list) or len(rows) != 1 or not isinstance(rows[0], dict):
            raise PostconditionError(stage + " address readback is not singular")
        result: list[str] = []
        for item in rows[0].get("addr_info", []):
            if not isinstance(item, dict) or item.get("family") != "inet":
                continue
            local, prefix = item.get("local"), item.get("prefixlen")
            if not isinstance(local, str) or type(prefix) is not int:
                raise PostconditionError(stage + " address entry is malformed")
            result.append(f"{local}/{prefix}")
        return sorted(result)

    def _private_publish(
        self,
        stage: str,
        resource_ids: Sequence[str],
        *,
        kind: str,
        names: Sequence[str],
        targets: Sequence[NamespaceTarget],
        extra: Mapping[str, Any] | None = None,
        allowed_stderr: frozenset[bytes] | None = frozenset({b""}),
    ) -> list[dict[str, Any]]:
        if any(IFNAME_RE.fullmatch(name) is None for name in names):
            raise SecurityError("private publication has invalid interface name")
        for target in targets:
            self._verify_target(target)
        descriptors = tuple(
            target.descriptor for target in targets if target.descriptor is not None
        )
        specification: dict[str, Any] = {
            "kind": kind,
            "names": list(names),
            "alias": self._owner,
            "targets": [
                {
                    "pid": target.pid,
                    "start_ticks": target.start_ticks,
                    "netns_inode": target.netns_inode,
                    "mntns_inode": target.mntns_inode,
                    "descriptor": target.descriptor
                    if target.descriptor is not None
                    else -1,
                }
                for target in targets
            ],
            "deadline_seconds": max(0.1, self._config.command_timeout * 0.9),
            "maximum_output": PRIVATE_HELPER_OUTPUT,
        }
        if extra:
            specification.update(copy.deepcopy(dict(extra)))
        argv = (
            "unshare",
            "--net",
            "--",
            sys.executable,
            "-B",
            "-c",
            PRIVATE_LINK_HELPER,
            json.dumps(specification, sort_keys=True, separators=(",", ":")),
        )

        def postcondition(result: Any) -> list[dict[str, Any]]:
            helper = self._json(result.stdout, stage + " helper")
            if helper != {"kind": kind, "names": list(names), "status": "PUBLISHED"}:
                raise PostconditionError(stage + " helper acknowledgement changed")
            for target in targets:
                self._verify_target(target)
            rows = [
                self._link_read(stage + f"-final-{index}", target, name)
                for index, (target, name) in enumerate(zip(targets, names), 1)
            ]
            for row in rows:
                info = row.get("linkinfo")
                if row["alias"] != self._owner or not isinstance(info, dict):
                    raise PostconditionError(stage + " final owner alias is missing")
                actual_kind = info.get("info_kind")
                expected_kind = "veth" if kind == "veth" else kind
                if actual_kind != expected_kind:
                    raise PostconditionError(stage + " final link kind changed")
            if kind == "veth":
                if (
                    len(rows) != 2
                    or rows[0]["ifindex"] != rows[1]["iflink"]
                    or rows[1]["ifindex"] != rows[0]["iflink"]
                ):
                    raise PostconditionError(stage + " veth reciprocity is invalid")
            elif kind == "vxlan":
                data = rows[0]["linkinfo"].get("info_data")
                if (
                    not isinstance(data, dict)
                    or data.get("id") != specification.get("vni")
                    or data.get("local") != specification.get("local")
                    or data.get("port") != specification.get("dstport")
                    or data.get("learning") is not False
                    or data.get("link") != specification.get("underlay_ifindex")
                ):
                    raise PostconditionError(stage + " final VXLAN identity changed")
            elif kind == "vrf":
                data = rows[0]["linkinfo"].get("info_data")
                if (
                    not isinstance(data, dict)
                    or data.get("table") != specification.get("table")
                ):
                    raise PostconditionError(stage + " final VRF table changed")
            return rows

        rows = self._effect(
            stage,
            resource_ids,
            argv,
            postcondition,
            pass_fds=descriptors,
            allowed_stderr=allowed_stderr,
        )
        if len(resource_ids) == 1 and len(rows) == 2:
            self._bindings["links"][resource_ids[0]] = {
                "pair": copy.deepcopy(rows)
            }
        else:
            for resource_id, row in zip(resource_ids, rows):
                self._bindings["links"][resource_id] = copy.deepcopy(row)
        return rows

    def _configure_link(
        self,
        stage: str,
        resource_id: str,
        target: NamespaceTarget,
        name: str,
        arguments: Sequence[str],
        validator: Callable[[], dict[str, Any]],
        *,
        namespace: str | None = None,
    ) -> dict[str, Any]:
        command = (
            self._nested_command(target, namespace, "ip", *arguments)
            if namespace is not None
            else self._target_command(target, "ip", *arguments)
        )
        checked = self._effect(
            stage,
            [resource_id],
            command,
            lambda _result: validator(),
            allowed_stderr=frozenset({b""}),
        )
        existing = self._bindings["links"].get(resource_id)
        if isinstance(existing, dict) and isinstance(existing.get("pair"), list):
            configured = existing.setdefault("configured", {})
            configured[(namespace or "base") + ":" + name] = copy.deepcopy(checked)
        else:
            self._bindings["links"][resource_id] = copy.deepcopy(checked)
        return checked

    def _link_absent(
        self,
        stage: str,
        target: NamespaceTarget,
        name: str,
        *,
        namespace: str | None = None,
    ) -> bool:
        command = (
            self._nested_command(
                target, namespace, "ip", "-j", "link", "show", "dev", name
            )
            if namespace is not None
            else self._target_command(target, "ip", "-j", "link", "show", "dev", name)
        )
        result = self._read_command(stage, command, allowed_rc=frozenset({0, 1}))
        if result.returncode == 0:
            rows = self._json(result.stdout, stage)
            return isinstance(rows, list) and not rows
        return (
            result.stdout == b""
            and any(
                fragment in result.stderr
                for fragment in (
                    b"does not exist",
                    b"Cannot find device",
                    b"Device not found",
                )
            )
        )

    @staticmethod
    def _ovs_prefix(container_id: str | None, program: str) -> tuple[str, ...]:
        if container_id is None:
            return (program,)
        return ("docker", "exec", container_id, program)

    def _ovs_find(
        self,
        stage: str,
        *,
        container_id: str | None,
        table: str,
        columns: Sequence[str],
        name: str,
    ) -> list[dict[str, Any]]:
        command = (
            *self._ovs_prefix(container_id, "ovs-vsctl"),
            "--format=json",
            "--data=json",
            "--columns=" + ",".join(columns),
            "find",
            table,
            "name=" + name,
        )
        result = self._read_command(stage, command)
        rows = self._ovs_rows(result.stdout, stage)
        if any(set(row) != set(columns) for row in rows):
            raise PostconditionError(stage + " OVS columns changed")
        return rows

    def _read_ovs_binding(
        self,
        stage: str,
        *,
        container_id: str | None,
        bridge: str,
        interface: str,
        expected_tag: int | None,
        expected_port_external_ids: Mapping[str, str],
        expected_interface_external_ids: Mapping[str, str],
        expected_bridge_uuid: str,
    ) -> dict[str, Any]:
        bridge_rows = self._ovs_find(
            stage + "-bridge",
            container_id=container_id,
            table="Bridge",
            columns=("_uuid", "name", "ports"),
            name=bridge,
        )
        port_rows = self._ovs_find(
            stage + "-port",
            container_id=container_id,
            table="Port",
            columns=("_uuid", "name", "tag", "interfaces", "external_ids"),
            name=interface,
        )
        interface_rows = self._ovs_find(
            stage + "-interface",
            container_id=container_id,
            table="Interface",
            columns=("_uuid", "name", "external_ids"),
            name=interface,
        )
        if len(bridge_rows) != 1 or len(port_rows) != 1 or len(interface_rows) != 1:
            raise PostconditionError(stage + " OVS identity is not singular")
        bridge_row, port_row, interface_row = (
            bridge_rows[0],
            port_rows[0],
            interface_rows[0],
        )
        bridge_uuid = bridge_row["_uuid"]
        port_uuid = port_row["_uuid"]
        interface_uuid = interface_row["_uuid"]
        if not all(
            isinstance(value, str) and UUID_RE.fullmatch(value) is not None
            for value in (bridge_uuid, port_uuid, interface_uuid)
        ):
            raise PostconditionError(stage + " OVS UUID is malformed")
        tag = port_row["tag"]
        actual_tag = None if tag == [] else tag
        bridge_ports = (
            bridge_row["ports"]
            if isinstance(bridge_row["ports"], list)
            else [bridge_row["ports"]]
        )
        port_interfaces = (
            port_row["interfaces"]
            if isinstance(port_row["interfaces"], list)
            else [port_row["interfaces"]]
        )
        if (
            bridge_uuid != expected_bridge_uuid.lower()
            or port_uuid not in bridge_ports
            or interface_uuid not in port_interfaces
            or actual_tag != expected_tag
            or port_row["external_ids"] != dict(expected_port_external_ids)
            or interface_row["external_ids"] != dict(expected_interface_external_ids)
        ):
            raise PostconditionError(stage + " OVS ownership or parent changed")
        return {
            "container_id": container_id,
            "bridge": bridge,
            "bridge_uuid": bridge_uuid,
            "port_name": interface,
            "port_uuid": port_uuid,
            "interface_uuid": interface_uuid,
            "tag": actual_tag,
            "port_external_ids": copy.deepcopy(port_row["external_ids"]),
            "interface_external_ids": copy.deepcopy(interface_row["external_ids"]),
        }

    def _expected_bridge_uuid(self, resource_id: str) -> str:
        before = self._context["snapshot"]["before"].get(resource_id)
        observed = before.get("observed") if isinstance(before, dict) else None
        value = observed.get("parent_bridge_uuid") if isinstance(observed, dict) else None
        if not isinstance(value, str) or UUID_RE.fullmatch(value) is None:
            raise SecurityError("admission lacks exact parent bridge UUID: " + resource_id)
        return value.lower()

    def _add_ovs_port(
        self,
        stage: str,
        resource_id: str,
        *,
        container_id: str | None,
        bridge: str,
        interface: str,
        tag: int | None,
        port_external_ids: Mapping[str, str],
        interface_external_ids: Mapping[str, str],
    ) -> dict[str, Any]:
        command: list[str] = [
            *self._ovs_prefix(container_id, "ovs-vsctl"),
            "--",
            "add-port",
            bridge,
            interface,
            "--",
            "set",
            "Port",
            interface,
        ]
        if tag is not None:
            command.append("tag=" + str(tag))
        else:
            command.append("tag=[]")
        command.extend(
            "external_ids:" + key + "=" + value
            for key, value in sorted(port_external_ids.items())
        )
        command.extend(("--", "set", "Interface", interface))
        command.extend(
            "external_ids:" + key + "=" + value
            for key, value in sorted(interface_external_ids.items())
        )
        expected_bridge_uuid = self._expected_bridge_uuid(resource_id)

        def postcondition(_result: Any) -> dict[str, Any]:
            return self._read_ovs_binding(
                stage + "-readback",
                container_id=container_id,
                bridge=bridge,
                interface=interface,
                expected_tag=tag,
                expected_port_external_ids=port_external_ids,
                expected_interface_external_ids=interface_external_ids,
                expected_bridge_uuid=expected_bridge_uuid,
            )

        binding = self._effect(
            stage,
            [resource_id],
            tuple(command),
            postcondition,
            allowed_stderr=frozenset({b""}),
        )
        self._bindings["ovs"][resource_id] = copy.deepcopy(binding)
        return binding

    @staticmethod
    def _ovs_map(value: Mapping[str, str]) -> list[Any]:
        return ["map", [[key, item] for key, item in sorted(value.items())]]

    @staticmethod
    def _ovs_uuid_set(values: Sequence[str]) -> Any:
        atoms = [["uuid", value] for value in sorted(values)]
        if len(atoms) == 1:
            return atoms[0]
        return ["set", atoms]

    def _ovsdb_effect(
        self,
        stage: str,
        resource_ids: Sequence[str],
        *,
        container_id: str | None,
        transaction: list[Any],
        postcondition: Callable[[Any], Any],
    ) -> Any:
        command = (
            *self._ovs_prefix(container_id, "ovsdb-client"),
            "transact",
            "unix:/var/run/openvswitch/db.sock",
            json.dumps(transaction, sort_keys=True, separators=(",", ":")),
        )

        def checked(result: Any) -> Any:
            reply = self._json(result.stdout, stage + " OVSDB result")
            if not isinstance(reply, list) or len(reply) != len(transaction) - 1:
                raise PostconditionError(stage + " OVSDB result count changed")
            for item in reply:
                if not isinstance(item, dict) or "error" in item:
                    raise PostconditionError(stage + " OVSDB transaction failed")
            return postcondition(reply)

        return self._effect(
            stage,
            resource_ids,
            command,
            checked,
            allowed_stderr=frozenset({b""}),
        )

    def _remove_ovs_port(self, stage: str, resource_id: str) -> dict[str, Any]:
        binding = self._bindings["ovs"].get(resource_id)
        if not isinstance(binding, dict):
            raise SecurityError("OVS cleanup lacks captured identity: " + resource_id)
        current = self._read_ovs_binding(
            stage + "-precheck",
            container_id=binding["container_id"],
            bridge=binding["bridge"],
            interface=binding["port_name"],
            expected_tag=binding["tag"],
            expected_port_external_ids=binding["port_external_ids"],
            expected_interface_external_ids=binding["interface_external_ids"],
            expected_bridge_uuid=binding["bridge_uuid"],
        )
        if current != binding:
            raise SecurityError("OVS identity changed before cleanup: " + resource_id)
        port_row = {
            "_uuid": ["uuid", binding["port_uuid"]],
            "name": binding["port_name"],
            "tag": ["set", []]
            if binding["tag"] is None
            else ["set", [binding["tag"]]],
            "interfaces": ["uuid", binding["interface_uuid"]],
            "external_ids": self._ovs_map(binding["port_external_ids"]),
        }
        interface_row = {
            "_uuid": ["uuid", binding["interface_uuid"]],
            "name": binding["port_name"],
            "external_ids": self._ovs_map(binding["interface_external_ids"]),
        }
        transaction: list[Any] = [
            "Open_vSwitch",
            {
                "op": "wait",
                "table": "Port",
                "where": [["_uuid", "==", ["uuid", binding["port_uuid"]]]],
                "columns": list(port_row),
                "rows": [port_row],
                "until": "==",
                "timeout": 0,
            },
            {
                "op": "wait",
                "table": "Interface",
                "where": [["_uuid", "==", ["uuid", binding["interface_uuid"]]]],
                "columns": list(interface_row),
                "rows": [interface_row],
                "until": "==",
                "timeout": 0,
            },
            {
                "op": "mutate",
                "table": "Bridge",
                "where": [["_uuid", "==", ["uuid", binding["bridge_uuid"]]]],
                "mutations": [
                    ["ports", "delete", ["uuid", binding["port_uuid"]]]
                ],
            },
            {
                "op": "delete",
                "table": "Port",
                "where": [["_uuid", "==", ["uuid", binding["port_uuid"]]]],
            },
            {
                "op": "delete",
                "table": "Interface",
                "where": [["_uuid", "==", ["uuid", binding["interface_uuid"]]]],
            },
        ]

        def postcondition(reply: list[dict[str, Any]]) -> dict[str, Any]:
            counts = [item.get("count") for item in reply[2:]]
            if counts != [1, 1, 1]:
                raise PostconditionError(stage + " guarded OVS delete count changed")
            port_rows = self._ovs_find(
                stage + "-absent-port",
                container_id=binding["container_id"],
                table="Port",
                columns=("_uuid", "name"),
                name=binding["port_name"],
            )
            interface_rows = self._ovs_find(
                stage + "-absent-interface",
                container_id=binding["container_id"],
                table="Interface",
                columns=("_uuid", "name"),
                name=binding["port_name"],
            )
            if port_rows or interface_rows:
                raise PostconditionError(stage + " OVS port/interface remains")
            return {
                "resource_id": resource_id,
                "port_uuid": binding["port_uuid"],
                "interface_uuid": binding["interface_uuid"],
                "absent": True,
            }

        checked = self._ovsdb_effect(
            stage,
            [resource_id],
            container_id=binding["container_id"],
            transaction=transaction,
            postcondition=postcondition,
        )
        del self._bindings["ovs"][resource_id]
        return checked

    def _marker_payload(self, state: str) -> bytes:
        if state not in {"INTENT", "BUILT"} or self._journal is None:
            raise SecurityError("invalid runtime marker state")
        admission = self._context["admission"]
        lines = (
            "version=2",
            "token=" + self._owner,
            "owner=" + self._owner,
            "run_hex=" + self._run_hex,
            "state=" + state,
            "snapshot_sha256=" + admission["snapshot_sha256"],
            "bundle_manifest_sha256=" + admission["bundle_manifest_sha256"],
            "runtime_plan_sha256=" + self._plan["runtime_plan_sha256"],
            "runtime_journal=" + str(self._journal.path),
            "runtime_journal_sha256=" + self._journal.digest,
            "runtime_journal_head_sha256=" + self._journal.head,
        )
        return ("\n".join(lines) + "\n").encode("ascii")

    def _verify_marker_payload(self, raw: bytes, state: str) -> dict[str, Any]:
        try:
            lines = raw.decode("ascii").splitlines()
        except UnicodeError as exc:
            raise PostconditionError("X05 marker is not ASCII") from exc
        values: dict[str, str] = {}
        for line in lines:
            if not line or "=" not in line:
                raise PostconditionError("X05 marker has malformed line")
            key, value = line.split("=", 1)
            if not key or not value or key in values:
                raise PostconditionError("X05 marker has duplicate/empty field")
            values[key] = value
        expected = {
            "version": "2",
            "token": self._owner,
            "owner": self._owner,
            "run_hex": self._run_hex,
            "state": state,
            "snapshot_sha256": self._context["admission"]["snapshot_sha256"],
            "bundle_manifest_sha256": self._context["admission"][
                "bundle_manifest_sha256"
            ],
            "runtime_plan_sha256": self._plan["runtime_plan_sha256"],
            "runtime_journal": str(self._journal.path) if self._journal else "",
        }
        if any(values.get(key) != value for key, value in expected.items()):
            raise PostconditionError("X05 marker binding changed")
        for key in ("runtime_journal_sha256", "runtime_journal_head_sha256"):
            if HEX64_RE.fullmatch(values.get(key, "")) is None:
                raise PostconditionError("X05 marker journal binding is malformed")
        return {
            "state": state,
            "marker_sha256": _sha256(raw),
            "journal_sha256": values["runtime_journal_sha256"],
            "journal_head_sha256": values["runtime_journal_head_sha256"],
        }

    def _create_journal_and_marker(self) -> None:
        journal = DurableJournal(
            self._config.evidence_path / RUNTIME_JOURNAL_NAME,
            uid=self._config.required_uid,
            owner=self._owner,
            run_hex=self._run_hex,
        )
        anchors = {
            "snapshot_sha256": self._context["admission"]["snapshot_sha256"],
            "snapshot_file_sha256": self._context["admission"][
                "snapshot_file_sha256"
            ],
            "bundle_manifest_sha256": self._context["admission"][
                "bundle_manifest_sha256"
            ],
            "runtime_plan_sha256": self._plan["runtime_plan_sha256"],
            "resource_ids_sha256": self._plan["resource_ids_sha256"],
            "mutable_resource_count": len(BASE_MUTABLE_IDS),
            "generated_observation_count": len(GENERATED_VRF_IDS),
        }
        journal.create(anchors)
        self._journal = journal
        created = {
            "status": "VERIFIED",
            "operation": "journal-create",
            "resource_ids": [MARKER_ID],
        }
        self._publish("x05-runtime-state", "journal-created", created)

        marker_directory = self._config.x05_marker_path.parent

        def create_marker_directory() -> tuple[int, int, int, int]:
            grandparent = marker_directory.parent
            parent_info = grandparent.lstat()
            if (
                stat.S_ISLNK(parent_info.st_mode)
                or not stat.S_ISDIR(parent_info.st_mode)
                or parent_info.st_uid != self._config.required_uid
                or stat.S_IMODE(parent_info.st_mode) & 0o022
                or marker_directory.exists()
                or marker_directory.is_symlink()
            ):
                raise SecurityError("X05 marker parent is not a safe absent child")
            os.mkdir(marker_directory, 0o700)
            _fsync_directory(grandparent)
            info = marker_directory.lstat()
            identity = (info.st_dev, info.st_ino, info.st_mode, info.st_uid)
            self._marker_directory_identity = identity
            return identity

        def marker_directory_postcondition(
            expected: tuple[int, int, int, int]
        ) -> dict[str, Any]:
            info = marker_directory.lstat()
            current = (info.st_dev, info.st_ino, info.st_mode, info.st_uid)
            if (
                current != expected
                or not stat.S_ISDIR(info.st_mode)
                or stat.S_IMODE(info.st_mode) != 0o700
                or info.st_uid != self._config.required_uid
                or any(marker_directory.iterdir())
            ):
                raise PostconditionError("X05 marker directory is not exact/private")
            return {"path": str(marker_directory), "mode": "0700", "empty": True}

        self._local_effect(
            "marker-directory",
            [MARKER_ID],
            "marker-directory-create",
            create_marker_directory,
            marker_directory_postcondition,
        )

        def create_marker() -> bytes:
            payload = self._marker_payload("INTENT")
            _atomic_new(
                self._config.x05_marker_path,
                payload,
                uid=self._config.required_uid,
            )
            self._marker_bytes = payload
            _raw, self._marker_identity = _read_regular(
                self._config.x05_marker_path,
                maximum=65536,
                mode=0o600,
                uid=self._config.required_uid,
            )
            return payload

        def marker_postcondition(payload: bytes) -> dict[str, Any]:
            raw, _ = _read_regular(
                self._config.x05_marker_path,
                maximum=65536,
                mode=0o600,
                uid=self._config.required_uid,
            )
            if raw != payload:
                raise PostconditionError("INTENT marker bytes changed")
            return self._verify_marker_payload(raw, "INTENT")

        self._local_effect(
            "marker-intent",
            [MARKER_ID],
            "marker-create",
            create_marker,
            marker_postcondition,
        )
        self._state = "INTENT"

    def _publish_built_marker(self) -> dict[str, Any]:
        if self._marker_bytes is None:
            raise SecurityError("INTENT marker is unavailable")

        def replace_marker() -> bytes:
            previous = self._marker_bytes
            assert previous is not None
            payload = self._marker_payload("BUILT")
            _atomic_replace(
                self._config.x05_marker_path,
                expected=previous,
                payload=payload,
                uid=self._config.required_uid,
            )
            self._marker_bytes = payload
            _raw, self._marker_identity = _read_regular(
                self._config.x05_marker_path,
                maximum=65536,
                mode=0o600,
                uid=self._config.required_uid,
            )
            return payload

        def marker_postcondition(payload: bytes) -> dict[str, Any]:
            raw, _ = _read_regular(
                self._config.x05_marker_path,
                maximum=65536,
                mode=0o600,
                uid=self._config.required_uid,
            )
            if raw != payload:
                raise PostconditionError("BUILT marker bytes changed")
            return self._verify_marker_payload(raw, "BUILT")

        checked = self._local_effect(
            "marker-built",
            [MARKER_ID],
            "marker-replace",
            replace_marker,
            marker_postcondition,
        )
        self._state = "BUILT"
        return checked

    def _nb_artifact_binding(self, *, state: str) -> dict[str, Any]:
        names = (
            (
                "journal.json",
                "preflight.json",
                "forward-tx.json",
                "forward-result.raw.json",
                "forward-checked.json",
                "built-snapshot.json",
                "built-checked.json",
            )
            if state == "forward"
            else (
                "journal.json",
                "preinverse-snapshot.json",
                "inverse-tx.json",
                "inverse-result.raw.json",
                "inverse-checked.json",
                "clean-snapshot.json",
                "clean-checked.json",
            )
        )
        hashes: dict[str, str] = {}
        for name in names:
            raw, _ = _read_regular(
                self._config.evidence_path / name,
                maximum=MAX_LOCAL_FILE,
                mode=0o600,
                uid=self._config.required_uid,
            )
            hashes[name] = _sha256(raw)
        return {"state": state, "artifacts": hashes}

    def _forward_nb(self) -> dict[str, Any]:
        def checked(value: Any) -> dict[str, Any]:
            if (
                not isinstance(value, dict)
                or value.get("status") != "PASS"
                or value.get("owner") != self._owner
                or value.get("run_hex") != self._run_hex
            ):
                raise PostconditionError("NB forward result is not the owned PASS")
            return self._nb_artifact_binding(state="forward")

        binding = self._library_effect(
            "nb-forward",
            [MARKER_ID],
            "nb-forward",
            lambda: _NB_FORWARD(self._nb),
            checked,
        )
        self._bindings["nb"]["forward"] = copy.deepcopy(binding)
        return binding

    def _inverse_nb(self) -> dict[str, Any]:
        def checked(value: Any) -> dict[str, Any]:
            if (
                not isinstance(value, dict)
                or value.get("status") != "PASS"
                or value.get("owner") != self._owner
                or value.get("run_hex") != self._run_hex
            ):
                raise PostconditionError("NB inverse result is not the owned PASS")
            return self._nb_artifact_binding(state="inverse")

        binding = self._library_effect(
            "nb-inverse",
            [MARKER_ID],
            "nb-inverse",
            lambda: _NB_INVERSE(self._nb),
            checked,
        )
        self._bindings["nb"]["inverse"] = copy.deepcopy(binding)
        return binding

    def _central_id(self) -> str:
        value = self._original_container_ids.get("ovn-central-az1")
        if not isinstance(value, str) or HEX64_RE.fullmatch(value) is None:
            raise SecurityError("admission lacks central container ID")
        return value

    def _read_b_restore(self, stage: str) -> dict[str, Any]:
        central = self._central_id()
        ls_command = (
            "docker",
            "exec",
            central,
            "ovn-nbctl",
            "--format=json",
            "--data=json",
            "--columns=_uuid,name,ports",
            "list",
            "Logical_Switch",
        )
        lsp_command = (
            "docker",
            "exec",
            central,
            "ovn-nbctl",
            "--format=json",
            "--data=json",
            "--columns=_uuid,name",
            "find",
            "Logical_Switch_Port",
            "name=x05-tenant-b-vm",
        )
        sb_command = (
            "docker",
            "exec",
            central,
            "ovn-sbctl",
            "--format=json",
            "--data=json",
            "--columns=_uuid,logical_port,datapath",
            "find",
            "Port_Binding",
            "logical_port=x05-tenant-b-vm",
        )
        switches = self._ovs_rows(
            self._read_command(stage + "-switches", ls_command).stdout,
            stage + " switches",
        )
        lsp_rows = self._ovs_rows(
            self._read_command(stage + "-lsp", lsp_command).stdout,
            stage + " LSP",
        )
        sb_rows = self._ovs_rows(
            self._read_command(stage + "-sb", sb_command).stdout,
            stage + " SB",
        )
        if len(lsp_rows) != 1 or len(sb_rows) != 1:
            raise PostconditionError("B LSP/SB binding is not singular")
        lsp_uuid = lsp_rows[0].get("_uuid")
        if (
            lsp_rows[0].get("name") != "x05-tenant-b-vm"
            or not isinstance(lsp_uuid, str)
            or UUID_RE.fullmatch(lsp_uuid) is None
        ):
            raise PostconditionError("B LSP identity is malformed")
        parents: list[tuple[str, str]] = []
        for row in switches:
            ports = row.get("ports")
            values = ports if isinstance(ports, list) else [ports]
            if lsp_uuid in values:
                parents.append((row.get("name"), row.get("_uuid")))
        sb = sb_rows[0]
        datapath = sb.get("datapath")
        if (
            parents != [("ls-x05-tenant-b", parents[0][1] if parents else None)]
            or sb.get("logical_port") != "x05-tenant-b-vm"
            or not isinstance(sb.get("_uuid"), str)
            or UUID_RE.fullmatch(sb["_uuid"]) is None
            or not isinstance(datapath, str)
            or UUID_RE.fullmatch(datapath) is None
        ):
            raise PostconditionError("B LSP is not solely parented by original B")
        return {
            "lsp_uuid": lsp_uuid,
            "logical_switch": parents[0][0],
            "logical_switch_uuid": parents[0][1],
            "port_binding_uuid": sb["_uuid"],
            "datapath_uuid": datapath,
        }

    def _observe_generated_vrf(
        self,
        resource_id: str,
        target: NamespaceTarget,
    ) -> dict[str, Any]:
        resource = self._resources[resource_id]
        row = self._link_read(
            "generated-vrf-" + resource["name"], target, resource["name"]
        )
        info = row.get("linkinfo")
        data = info.get("info_data") if isinstance(info, dict) else None
        if (
            not isinstance(info, dict)
            or info.get("info_kind") != "vrf"
            or not isinstance(data, dict)
            or data.get("table") != resource["desired"]["table"]
        ):
            raise PostconditionError("generated VRF table/type changed: " + resource_id)
        checked = {
            **row,
            "observation_only": True,
            "direct_delete": False,
            "table": data["table"],
        }
        self._bindings["generated_vrfs"][resource_id] = copy.deepcopy(checked)
        return checked

    def _container_absent(self, stage: str, name: str, container_id: str | None = None) -> bool:
        filters = ["name=^/" + name + "$"]
        if container_id is not None:
            filters.append("id=" + container_id)
        for index, value in enumerate(filters):
            command = (
                "docker",
                "container",
                "ls",
                "--all",
                "--no-trunc",
                "--filter",
                value,
                "--format",
                "{{.ID}}\t{{.Names}}",
            )
            result = self._read_command(stage + f"-{index}", command)
            if result.stdout.strip():
                return False
        return True

    def _create_container(self, resource_id: str) -> dict[str, Any]:
        resource = self._resources[resource_id]
        name = resource["name"]
        desired = resource["desired"]
        image_tag = desired["image"]
        image_id = self._image_ids.get(image_tag)
        if not isinstance(image_id, str) or IMAGE_ID_RE.fullmatch(image_id) is None:
            raise SecurityError("admission lacks immutable image ID: " + image_tag)
        labels = desired["labels"]
        expected_labels = {
            "labctl.dci.owner": self._profile_owner,
            "labctl-x05-owner": self._owner,
        }
        if labels != expected_labels:
            raise SecurityError("materialized container labels changed: " + name)
        if not self._container_absent("container-before-" + name, name):
            raise SecurityError("fixed X05 container name is no longer absent: " + name)
        command = (
            "docker",
            "run",
            "--detach",
            "--pull",
            "never",
            "--name",
            name,
            "--hostname",
            name,
            "--network",
            "none",
            "--privileged",
            "--label",
            "labctl.dci.owner=" + self._profile_owner,
            "--label",
            "labctl-x05-owner=" + self._owner,
            "--entrypoint",
            "/bin/sh",
            image_id,
            "-ceu",
            "trap 'exit 0' TERM INT; while :; do sleep 3600 & wait $!; done",
        )

        def postcondition(result: Any) -> dict[str, Any]:
            try:
                container_id = result.stdout.decode("ascii").strip()
            except UnicodeError as exc:
                raise PostconditionError("Docker run ID is not ASCII") from exc
            if HEX64_RE.fullmatch(container_id) is None:
                raise PostconditionError("Docker run did not return a full container ID")
            row = self._docker_inspect(container_id, "container-created-" + name)
            return self._validate_container_row(
                row,
                name=name,
                container_id=container_id,
                image_id=image_id,
                labels=expected_labels,
            )

        binding = self._effect(
            "container-create-" + name,
            [resource_id],
            command,
            postcondition,
            allowed_stderr=frozenset({b""}),
        )
        self._bindings["containers"][name] = copy.deepcopy(binding)
        target = self._capture_target(
            name, container_name=name, container_id=binding["id"]
        )
        binding["namespace"] = target.detached()
        self._bindings["containers"][name] = copy.deepcopy(binding)
        return binding

    def _verify_created_container(self, name: str) -> dict[str, Any]:
        binding = self._bindings["containers"].get(name)
        if not isinstance(binding, dict):
            raise SecurityError("created container binding is missing: " + name)
        row = self._docker_inspect(binding["id"], "container-recheck-" + name)
        checked = self._validate_container_row(
            row,
            name=name,
            container_id=binding["id"],
            image_id=binding["image_id"],
            labels={
                "labctl.dci.owner": self._profile_owner,
                "labctl-x05-owner": self._owner,
            },
        )
        if checked["labels"] != binding["labels"] or checked["pid"] != binding["pid"]:
            raise SecurityError("created container identity changed: " + name)
        target = self._targets.get(name)
        if target is None:
            raise SecurityError("created container namespace pin is missing: " + name)
        self._verify_target(target)
        return copy.deepcopy(binding)

    def _remove_container(self, resource_id: str) -> dict[str, Any]:
        name = self._resources[resource_id]["name"]
        binding = self._verify_created_container(name)
        self._close_target(name)
        command = ("docker", "container", "rm", "--force", binding["id"])

        def postcondition(result: Any) -> dict[str, Any]:
            try:
                removed = result.stdout.decode("ascii").strip()
            except UnicodeError as exc:
                raise PostconditionError("Docker rm output is not ASCII") from exc
            if removed not in {binding["id"], name}:
                raise PostconditionError("Docker rm did not identify captured container")
            if not self._container_absent("container-absent-" + name, name, binding["id"]):
                raise PostconditionError("captured container remains: " + name)
            return {"name": name, "id": binding["id"], "absent": True}

        checked = self._effect(
            "container-remove-" + name,
            [resource_id],
            command,
            postcondition,
            allowed_stderr=frozenset({b""}),
        )
        del self._bindings["containers"][name]
        return checked

    def _set_link_up(
        self,
        stage: str,
        resource_id: str,
        target: NamespaceTarget,
        name: str,
        *,
        namespace: str | None = None,
    ) -> dict[str, Any]:
        def validator() -> dict[str, Any]:
            row = self._link_read(stage + "-readback", target, name, namespace=namespace)
            flags = row.get("flags")
            if not isinstance(flags, list) or "UP" not in flags:
                raise PostconditionError(stage + " link is not up")
            return row

        return self._configure_link(
            stage,
            resource_id,
            target,
            name,
            ("link", "set", "dev", name, "up"),
            validator,
            namespace=namespace,
        )

    def _set_master(
        self,
        stage: str,
        resource_id: str,
        target: NamespaceTarget,
        name: str,
        master: str,
        *,
        namespace: str | None = None,
    ) -> dict[str, Any]:
        def validator() -> dict[str, Any]:
            row = self._link_read(stage + "-readback", target, name, namespace=namespace)
            if row["master"] != master:
                raise PostconditionError(stage + " master changed")
            return row

        return self._configure_link(
            stage,
            resource_id,
            target,
            name,
            ("link", "set", "dev", name, "master", master),
            validator,
            namespace=namespace,
        )

    def _set_mac(
        self,
        stage: str,
        resource_id: str,
        target: NamespaceTarget,
        name: str,
        mac: str,
        *,
        namespace: str | None = None,
    ) -> dict[str, Any]:
        mac = mac.lower()

        def validator() -> dict[str, Any]:
            row = self._link_read(stage + "-readback", target, name, namespace=namespace)
            if row["mac"] != mac:
                raise PostconditionError(stage + " MAC changed")
            return row

        return self._configure_link(
            stage,
            resource_id,
            target,
            name,
            ("link", "set", "dev", name, "address", mac),
            validator,
            namespace=namespace,
        )

    def _add_address(
        self,
        stage: str,
        resource_id: str,
        target: NamespaceTarget,
        name: str,
        address: str,
        *,
        namespace: str | None = None,
    ) -> dict[str, Any]:
        def validator() -> dict[str, Any]:
            row = self._link_read(stage + "-link", target, name, namespace=namespace)
            addresses = self._address_read(
                stage + "-address", target, name, namespace=namespace
            )
            if address not in addresses:
                raise PostconditionError(stage + " address changed")
            row["addresses"] = addresses
            return row

        return self._configure_link(
            stage,
            resource_id,
            target,
            name,
            ("address", "add", address, "dev", name),
            validator,
            namespace=namespace,
        )

    def _original_target(self, name: str) -> NamespaceTarget:
        container_id = self._original_container_ids.get(name)
        if not isinstance(container_id, str) or HEX64_RE.fullmatch(container_id) is None:
            raise SecurityError("admission lacks original container ID: " + name)
        return self._capture_target(
            name, container_name=name, container_id=container_id
        )

    def _host_target(self) -> NamespaceTarget:
        return self._capture_target("host")

    def _created_target(self, name: str) -> NamespaceTarget:
        binding = self._bindings["containers"].get(name)
        if not isinstance(binding, dict):
            raise SecurityError("created target has no container binding: " + name)
        return self._capture_target(
            name, container_name=name, container_id=binding["id"]
        )

    def _set_mtu(
        self,
        stage: str,
        resource_id: str,
        target: NamespaceTarget,
        name: str,
        mtu: int,
        *,
        namespace: str | None = None,
    ) -> dict[str, Any]:
        if type(mtu) is not int or mtu < 576 or mtu > 65535:
            raise SecurityError("unreviewed link MTU")

        def validator() -> dict[str, Any]:
            row = self._link_read(stage + "-readback", target, name, namespace=namespace)
            if row["mtu"] != mtu:
                raise PostconditionError(stage + " MTU changed")
            return row

        return self._configure_link(
            stage,
            resource_id,
            target,
            name,
            ("link", "set", "dev", name, "mtu", str(mtu)),
            validator,
            namespace=namespace,
        )

    def _route_read(
        self,
        stage: str,
        target: NamespaceTarget,
        *,
        namespace: str | None = None,
    ) -> list[dict[str, Any]]:
        command = (
            self._nested_command(target, namespace, "ip", "-j", "-4", "route", "show")
            if namespace is not None
            else self._target_command(target, "ip", "-j", "-4", "route", "show")
        )
        value = self._json(self._read_command(stage, command).stdout, stage)
        if not isinstance(value, list) or any(not isinstance(row, dict) for row in value):
            raise PostconditionError(stage + " route readback is malformed")
        return copy.deepcopy(value)

    def _replace_default_route(
        self,
        stage: str,
        resource_id: str,
        target: NamespaceTarget,
        name: str,
        gateway: str,
        *,
        namespace: str,
    ) -> dict[str, Any]:
        command = self._nested_command(
            target,
            namespace,
            "ip",
            "route",
            "replace",
            "default",
            "via",
            gateway,
            "dev",
            name,
        )

        def postcondition(_result: Any) -> dict[str, Any]:
            routes = self._route_read(stage + "-readback", target, namespace=namespace)
            matches = [
                row
                for row in routes
                if row.get("dst") == "default"
                and row.get("gateway") == gateway
                and row.get("dev") == name
            ]
            if len(matches) != 1:
                raise PostconditionError(stage + " default route changed")
            return {"route": matches[0], "routes_sha256": _sha256(_canonical(routes))}

        checked = self._effect(
            stage,
            [resource_id],
            command,
            postcondition,
            allowed_stderr=frozenset({b""}),
        )
        binding = self._bindings["links"].setdefault(resource_id, {})
        binding["route"] = copy.deepcopy(checked)
        return checked

    def _netns_inode(
        self, stage: str, target: NamespaceTarget, namespace: str
    ) -> int:
        if target.container_id is None:
            raise SecurityError("named namespace requires a container target")
        result = self._read_command(
            stage,
            ("docker", "exec", target.container_id, "stat", "-Lc", "%i",
             "/var/run/netns/" + namespace),
            allowed_rc=frozenset({0, 1}),
        )
        if result.returncode != 0:
            raise PostconditionError(stage + " namespace handle is absent")
        return self._positive_int(result.stdout, stage + " namespace inode")

    def _create_netns(
        self, resource_id: str, target: NamespaceTarget, namespace: str
    ) -> dict[str, Any]:
        if target.container_id is None:
            raise SecurityError("named namespace requires a container target")
        command = ("docker", "exec", target.container_id, "ip", "netns", "add", namespace)

        def postcondition(_result: Any) -> dict[str, Any]:
            inode = self._netns_inode("netns-created-" + namespace, target, namespace)
            return {
                "name": namespace,
                "inode": inode,
                "target": target.detached(),
                "owned_veth_bound": False,
            }

        binding = self._effect(
            "netns-create-" + namespace,
            [resource_id],
            command,
            postcondition,
            allowed_stderr=frozenset({b""}),
        )
        self._bindings["namespaces"][resource_id] = copy.deepcopy(binding)
        return binding

    def _move_link_to_netns(
        self,
        stage: str,
        resource_id: str,
        target: NamespaceTarget,
        name: str,
        namespace: str,
    ) -> dict[str, Any]:
        if target.container_id is None:
            raise SecurityError("named namespace move requires a container target")
        command = (
            "docker", "exec", target.container_id, "ip", "link", "set",
            "dev", name, "netns", namespace,
        )

        def postcondition(_result: Any) -> dict[str, Any]:
            row = self._link_read(
                stage + "-readback", target, name, namespace=namespace
            )
            if row["alias"] != self._owner:
                raise PostconditionError(stage + " moved link lost owner alias")
            return row

        checked = self._effect(
            stage,
            [resource_id],
            command,
            postcondition,
            allowed_stderr=frozenset({b""}),
        )
        self._bindings["links"][resource_id] = copy.deepcopy(checked)
        return checked

    def _verify_netns(self, resource_id: str, *, require_bound: bool = True) -> dict[str, Any]:
        binding = self._bindings["namespaces"].get(resource_id)
        if not isinstance(binding, dict):
            raise SecurityError("namespace binding is missing: " + resource_id)
        target = self._targets.get(binding["target"]["label"])
        if target is None:
            raise SecurityError("namespace target pin is missing: " + resource_id)
        self._verify_target(target)
        if self._netns_inode("netns-recheck-" + binding["name"], target, binding["name"]) != binding["inode"]:
            raise SecurityError("namespace inode changed: " + resource_id)
        if require_bound and binding.get("owned_veth_bound") is not True:
            raise SecurityError("namespace lacks its owned veth binding: " + resource_id)
        return copy.deepcopy(binding)

    def _delete_netns(self, resource_id: str) -> dict[str, Any]:
        binding = self._verify_netns(resource_id)
        target = self._targets[binding["target"]["label"]]
        namespace = binding["name"]
        assert target.container_id is not None
        command = ("docker", "exec", target.container_id, "ip", "netns", "del", namespace)

        def postcondition(_result: Any) -> dict[str, Any]:
            probe = self._read_command(
                "netns-absent-" + namespace,
                ("docker", "exec", target.container_id, "stat", "-Lc", "%i",
                 "/var/run/netns/" + namespace),
                allowed_rc=frozenset({0, 1}),
            )
            if probe.returncode == 0 or probe.stdout:
                raise PostconditionError("namespace handle remains: " + namespace)
            return {"name": namespace, "inode": binding["inode"], "absent": True}

        checked = self._effect(
            "netns-remove-" + namespace,
            [resource_id],
            command,
            postcondition,
            allowed_stderr=frozenset({b""}),
        )
        del self._bindings["namespaces"][resource_id]
        return checked

    @staticmethod
    def _link_identity(row: Mapping[str, Any]) -> dict[str, Any]:
        return {
            key: copy.deepcopy(row.get(key))
            for key in (
                "namespace",
                "name",
                "ifindex",
                "iflink",
                "alias",
                "mac",
                "mtu",
                "master",
                "linkinfo",
            )
        }

    def _fresh_link_from_binding(
        self, stage: str, binding: Mapping[str, Any]
    ) -> dict[str, Any]:
        target_data = binding.get("target")
        if not isinstance(target_data, dict):
            raise SecurityError(stage + " link target binding is missing")
        target = self._targets.get(target_data.get("label"))
        if target is None or target.detached() != target_data:
            raise SecurityError(stage + " link target identity changed")
        name = binding.get("name")
        namespace = binding.get("namespace")
        if not isinstance(name, str) or (
            namespace is not None and not isinstance(namespace, str)
        ):
            raise SecurityError(stage + " link binding is malformed")
        current = self._link_read(stage, target, name, namespace=namespace)
        if self._link_identity(current) != self._link_identity(binding):
            raise SecurityError(stage + " link identity changed")
        if "addresses" in binding:
            addresses = self._address_read(
                stage + "-addresses", target, name, namespace=namespace
            )
            if addresses != binding["addresses"]:
                raise SecurityError(stage + " link addresses changed")
            current["addresses"] = addresses
        return current

    def _attachment_rows(self, resource_id: str) -> list[dict[str, Any]]:
        binding = self._bindings["links"].get(resource_id)
        if not isinstance(binding, dict) or not isinstance(binding.get("pair"), list):
            raise SecurityError("attachment veth binding is missing: " + resource_id)
        configured = binding.get("configured", {})
        if not isinstance(configured, dict):
            raise SecurityError("attachment configuration binding is malformed")
        rows: list[dict[str, Any]] = []
        for original in binding["pair"]:
            if not isinstance(original, dict):
                raise SecurityError("attachment pair binding is malformed")
            key = (original.get("namespace") or "base") + ":" + str(original.get("name"))
            replacement = configured.get(key, original)
            rows.append(copy.deepcopy(replacement))
        if len(rows) != 2:
            raise SecurityError("attachment veth pair is not exact")
        return rows

    def _delete_attachment(self, resource_id: str) -> dict[str, Any]:
        rows = self._attachment_rows(resource_id)
        fresh = [
            self._fresh_link_from_binding("attachment-precheck-" + str(index), row)
            for index, row in enumerate(rows, 1)
        ]
        if (
            fresh[0]["ifindex"] != fresh[1]["iflink"]
            or fresh[1]["ifindex"] != fresh[0]["iflink"]
        ):
            raise SecurityError("attachment veth reciprocity changed")
        left = rows[0]
        target = self._targets[left["target"]["label"]]
        command = self._target_command(
            target, "ip", "link", "del", "dev", left["name"]
        )

        def postcondition(_result: Any) -> dict[str, Any]:
            absent: list[dict[str, Any]] = []
            for row in rows:
                row_target = self._targets[row["target"]["label"]]
                if not self._link_absent(
                    "attachment-absent-" + row["name"],
                    row_target,
                    row["name"],
                    namespace=row.get("namespace"),
                ):
                    raise PostconditionError("attachment veth remains: " + row["name"])
                absent.append({"name": row["name"], "ifindex": row["ifindex"]})
            return {"resource_id": resource_id, "absent": absent}

        checked = self._effect(
            "attachment-remove-" + self._resources[resource_id]["name"],
            [resource_id],
            command,
            postcondition,
            allowed_stderr=frozenset({b""}),
        )
        del self._bindings["links"][resource_id]
        return checked

    def _delete_veth_pair(
        self, left_id: str, right_id: str
    ) -> dict[str, Any]:
        left = self._bindings["links"].get(left_id)
        right = self._bindings["links"].get(right_id)
        if not isinstance(left, dict) or not isinstance(right, dict):
            raise SecurityError("owned veth pair binding is incomplete")
        left_current = self._fresh_link_from_binding("veth-left-precheck", left)
        right_current = self._fresh_link_from_binding("veth-right-precheck", right)
        if (
            left_current["ifindex"] != right_current["iflink"]
            or right_current["ifindex"] != left_current["iflink"]
            or left_current["alias"] != self._owner
            or right_current["alias"] != self._owner
        ):
            raise SecurityError("owned veth reciprocity or aliases changed")
        target = self._targets[left["target"]["label"]]
        command = self._target_command(
            target, "ip", "link", "del", "dev", left["name"]
        )

        def postcondition(_result: Any) -> dict[str, Any]:
            for row in (left, right):
                row_target = self._targets[row["target"]["label"]]
                if not self._link_absent(
                    "veth-absent-" + row["name"],
                    row_target,
                    row["name"],
                    namespace=row.get("namespace"),
                ):
                    raise PostconditionError("owned veth remains: " + row["name"])
            return {
                "left_ifindex": left["ifindex"],
                "right_ifindex": right["ifindex"],
                "absent": True,
            }

        checked = self._effect(
            "veth-remove-" + left["name"],
            [left_id, right_id],
            command,
            postcondition,
            allowed_stderr=frozenset({b""}),
        )
        del self._bindings["links"][left_id]
        del self._bindings["links"][right_id]
        return checked

    def _delete_single_link(self, resource_id: str) -> dict[str, Any]:
        binding = self._bindings["links"].get(resource_id)
        if not isinstance(binding, dict) or "pair" in binding:
            raise SecurityError("single link binding is missing: " + resource_id)
        current = self._fresh_link_from_binding(
            "link-remove-precheck-" + binding["name"], binding
        )
        if current["alias"] != self._owner:
            raise SecurityError("single link owner alias changed: " + resource_id)
        target = self._targets[binding["target"]["label"]]
        command = self._target_command(
            target, "ip", "link", "del", "dev", binding["name"]
        )

        def postcondition(_result: Any) -> dict[str, Any]:
            if not self._link_absent(
                "link-absent-" + binding["name"], target, binding["name"]
            ):
                raise PostconditionError("owned link remains: " + binding["name"])
            return {"name": binding["name"], "ifindex": binding["ifindex"], "absent": True}

        checked = self._effect(
            "link-remove-" + binding["name"],
            [resource_id],
            command,
            postcondition,
            allowed_stderr=frozenset({b""}),
        )
        del self._bindings["links"][resource_id]
        return checked

    def _container_command(
        self, target: NamespaceTarget, *argv: str
    ) -> tuple[str, ...]:
        self._verify_target(target)
        if target.container_id is None:
            raise SecurityError("container command requires a captured container")
        if not argv or any(not isinstance(item, str) or not item for item in argv):
            raise SecurityError("container command argv is invalid")
        return ("docker", "exec", target.container_id, *argv)

    def _fixture(
        self, resource_id: str, key: str
    ) -> tuple[pathlib.Path, bytes, dict[str, Any]]:
        desired = self._resources[resource_id].get("desired")
        if not isinstance(desired, dict):
            raise SecurityError("fixture resource desired state is malformed")
        name = desired.get(key)
        if not isinstance(name, str) or pathlib.PurePath(name).name != name:
            raise SecurityError("fixture name is not a fixed basename")
        size_key = key + "_bytes"
        digest_key = "base_sha256" if key == "base_fixture" else key + "_sha256"
        size = desired.get(size_key)
        digest = desired.get(digest_key)
        if (
            (key != "base_fixture" and (type(size) is not int or size <= 0))
            or not isinstance(digest, str)
        ):
            raise SecurityError("fixture metadata is missing: " + name)
        reviewed = RUNTIME.REVIEWED_BUNDLE_FILES.get(
            "studies/p004/ovn/" + name
        )
        if digest != reviewed or HEX64_RE.fullmatch(digest) is None:
            raise SecurityError("fixture lacks the reviewed bundle pin: " + name)
        path = self._config.bundle_root / "studies" / "p004" / "ovn" / name
        raw, _ = _read_regular(
            path,
            maximum=max(size, 1) if type(size) is int else MAX_LOCAL_FILE,
            uid=self._config.required_uid,
        )
        if (type(size) is int and len(raw) != size) or _sha256(raw) != digest:
            raise SecurityError("fixture bytes changed: " + name)
        size = len(raw)
        return path, raw, {"name": name, "bytes": size, "sha256": digest}

    def _container_file_binding(
        self, stage: str, target: NamespaceTarget, path: str
    ) -> dict[str, Any]:
        if not path.startswith("/") or "\x00" in path or "\n" in path:
            raise SecurityError("container file path is invalid")
        script = (
            "set -eu\n"
            "path=$1\n"
            "test -f \"$path\"\n"
            "bytes=$(wc -c < \"$path\")\n"
            "digest=$(sha256sum -- \"$path\")\n"
            "digest=${digest%% *}\n"
            "printf '%s\\t%s\\n' \"$bytes\" \"$digest\"\n"
        )
        result = self._read_command(
            stage,
            self._container_command(target, "sh", "-ceu", script, "--", path),
        )
        try:
            line = result.stdout.decode("ascii").strip()
            size_text, digest = line.split("\t", 1)
            size = int(size_text)
        except (UnicodeError, ValueError) as exc:
            raise PostconditionError(stage + " file digest readback is malformed") from exc
        if size < 0 or HEX64_RE.fullmatch(digest) is None:
            raise PostconditionError(stage + " file digest readback is invalid")
        return {"path": path, "bytes": size, "sha256": digest}

    def _copy_fixture(
        self,
        stage: str,
        resource_id: str,
        target: NamespaceTarget,
        *,
        fixture_key: str,
        destination: str,
    ) -> dict[str, Any]:
        source, _raw, expected = self._fixture(resource_id, fixture_key)
        assert target.container_id is not None
        command = (
            "docker",
            "container",
            "cp",
            str(source),
            target.container_id + ":" + destination,
        )

        def postcondition(_result: Any) -> dict[str, Any]:
            self._fixture(resource_id, fixture_key)
            actual = self._container_file_binding(
                stage + "-readback", target, destination
            )
            if actual != {"path": destination, **{k: expected[k] for k in ("bytes", "sha256")}}:
                raise PostconditionError(stage + " copied fixture bytes changed")
            return {**actual, "fixture": expected["name"]}

        binding = self._effect(
            stage,
            [resource_id],
            command,
            postcondition,
            allowed_stderr=frozenset({b""}),
        )
        return binding

    def _remove_fixture(
        self,
        stage: str,
        resource_id: str,
        target: NamespaceTarget,
        binding: Mapping[str, Any],
    ) -> dict[str, Any]:
        path = binding.get("path")
        if not isinstance(path, str) or not path.startswith("/"):
            raise SecurityError("fixture cleanup binding is malformed")
        if self._container_file_binding(stage + "-precheck", target, path) != {
            "path": path,
            "bytes": binding.get("bytes"),
            "sha256": binding.get("sha256"),
        }:
            raise SecurityError("fixture changed before cleanup")
        command = self._container_command(target, "rm", "--", path)

        def postcondition(_result: Any) -> dict[str, Any]:
            probe = self._read_command(
                stage + "-absent",
                self._container_command(target, "test", "!", "-e", path),
            )
            if probe.stdout or probe.stderr:
                raise PostconditionError(stage + " fixture absence emitted output")
            return {"path": path, "absent": True}

        return self._effect(
            stage,
            [resource_id],
            command,
            postcondition,
            allowed_stderr=frozenset({b""}),
        )

    def _running_config(
        self, stage: str, target: NamespaceTarget
    ) -> tuple[bytes, list[str]]:
        result = self._read_command(
            stage,
            self._container_command(target, "vtysh", "-c", "show running-config"),
        )
        if result.stderr:
            raise PostconditionError(stage + " running-config emitted stderr")
        try:
            text = result.stdout.decode("utf-8", "strict")
            normalized = RUNTIME.PREFLIGHT.normalize_frr_running_config(text)
        except (UnicodeError, AttributeError, RUNTIME.PREFLIGHT.SnapshotError) as exc:
            raise PostconditionError(stage + " running-config is malformed") from exc
        return result.stdout, normalized

    @staticmethod
    def _without_gateway_extension(
        lines: Sequence[str], *, vrf: str, neighbor: str
    ) -> list[str]:
        result: list[str] = []
        index = 0
        while index < len(lines):
            line = lines[index]
            if line == "vrf " + vrf:
                index += 1
                while index < len(lines) and lines[index] != "exit-vrf":
                    index += 1
                if index >= len(lines):
                    raise PostconditionError("gateway VRF scope is unterminated")
                index += 1
                continue
            if line == "router bgp 100 vrf " + vrf:
                index += 1
                while index < len(lines) and lines[index] != "exit":
                    index += 1
                if index >= len(lines):
                    raise PostconditionError("gateway BGP scope is unterminated")
                index += 1
                continue
            if line == " peer " + neighbor + " vrf " + vrf:
                index += 1
                while index < len(lines) and lines[index].startswith("  "):
                    index += 1
                if index < len(lines) and lines[index] == " exit":
                    index += 1
                continue
            result.append(line)
            index += 1
        return result

    @staticmethod
    def _gateway_extension_signatures(vrf: str, neighbor: str) -> frozenset[str]:
        return frozenset(
            {
                "vrf " + vrf,
                "router bgp 100 vrf " + vrf,
                " neighbor " + neighbor + " remote-as 201",
                " neighbor " + neighbor + " bfd",
                "  network 192.168.100.0/24",
                "  redistribute connected",
                " peer " + neighbor + " vrf " + vrf,
            }
        )

    def _read_frr_processes(
        self,
        stage: str,
        target: NamespaceTarget,
        *,
        space: str,
        mode: str,
        expected_daemons: frozenset[str] | None,
    ) -> list[dict[str, Any]]:
        if mode not in {"pathspace", "client"} or space != "x05":
            raise SecurityError("FRR process readback selector is invalid")
        result = self._read_command(
            stage,
            self._container_command(
                target,
                "sh",
                "-ceu",
                FRR_PROCESS_READER,
                "--",
                space,
                mode,
            ),
        )
        if result.stderr:
            raise PostconditionError(stage + " FRR process readback emitted stderr")
        rows: list[dict[str, Any]] = []
        try:
            text = result.stdout.decode("utf-8", "strict")
            for line in text.splitlines():
                daemon, pid_text, start_text, command = line.split("\t", 3)
                pid = int(pid_text)
                start_ticks = int(start_text)
                if (
                    daemon not in EXPECTED_CLIENT_DAEMONS
                    or pid <= 0
                    or start_ticks <= 0
                    or not command
                    or "\x00" in command
                ):
                    raise ValueError("invalid FRR process identity")
                rows.append(
                    {
                        "daemon": daemon,
                        "pid": pid,
                        "start_ticks": start_ticks,
                        "command": command,
                    }
                )
        except (UnicodeError, ValueError) as exc:
            raise PostconditionError(stage + " FRR process readback is malformed") from exc
        rows.sort(key=lambda row: (row["daemon"], row["pid"]))
        if len({(row["daemon"], row["pid"]) for row in rows}) != len(rows):
            raise PostconditionError(stage + " FRR process identity is duplicated")
        if expected_daemons is not None:
            actual = {row["daemon"] for row in rows}
            if actual != expected_daemons or len(rows) != len(expected_daemons):
                raise PostconditionError(stage + " FRR daemon set is incomplete")
        return rows

    def _start_frr(
        self,
        resource_id: str,
        target: NamespaceTarget,
        *,
        fixture_key: str,
        mode: str,
    ) -> dict[str, Any]:
        if mode == "client":
            destination = "/etc/frr/frr.conf"
            stage_script = FRR_CLIENT_STAGE
            action_script = FRR_CLIENT_ACTION
            action_args = ("start",)
            expected = EXPECTED_CLIENT_DAEMONS
        elif mode == "pathspace":
            destination = "/etc/frr/x05/frr.conf"
            stage_script = FRR_PATHSPACE_STAGE
            action_script = FRR_PATHSPACE_START
            action_args = ("x05",)
            expected = EXPECTED_PATHSPACE_DAEMONS
        else:
            raise SecurityError("FRR start mode is invalid")
        stage_args = ("x05",) if mode == "pathspace" else ()
        if mode == "pathspace":
            def pathspace_postcondition(_result: Any) -> dict[str, Any]:
                probe = self._read_command(
                    "frr-stage-pathspace-readback-" + target.label,
                    self._container_command(
                        target,
                        "sh",
                        "-ceu",
                        "test -d /etc/frr/x05 && test -d /run/frr/x05",
                    ),
                )
                if probe.stdout or probe.stderr:
                    raise PostconditionError("FRR pathspace readback emitted output")
                return {
                    "space": "x05",
                    "directories": ["/etc/frr/x05", "/run/frr/x05"],
                }

            self._effect(
                "frr-stage-" + mode + "-" + target.label,
                [resource_id],
                self._container_command(
                    target, "sh", "-ceu", stage_script, "--", *stage_args
                ),
                pathspace_postcondition,
                allowed_stderr=frozenset({b""}),
            )
        file_binding = self._copy_fixture(
            "frr-copy-" + mode + "-" + target.label,
            resource_id,
            target,
            fixture_key=fixture_key,
            destination=destination,
        )
        self._effect(
            "frr-stage-final-" + mode + "-" + target.label,
            [resource_id],
            self._container_command(
                target, "sh", "-ceu", stage_script, "--", *stage_args
            ),
            lambda _result: self._container_file_binding(
                "frr-stage-readback-" + mode + "-" + target.label,
                target,
                destination,
            ),
            allowed_stderr=frozenset({b""}),
        )

        def postcondition(_result: Any) -> dict[str, Any]:
            processes = self._read_frr_processes(
                "frr-start-readback-" + mode + "-" + target.label,
                target,
                space="x05",
                mode=mode,
                expected_daemons=expected,
            )
            file_current = self._container_file_binding(
                "frr-file-recheck-" + mode + "-" + target.label,
                target,
                destination,
            )
            if file_current != {
                "path": destination,
                "bytes": file_binding["bytes"],
                "sha256": file_binding["sha256"],
            }:
                raise PostconditionError("FRR fixture changed during start")
            return {
                "mode": mode,
                "space": "x05",
                "target": target.detached(),
                "file": copy.deepcopy(file_binding),
                "processes": processes,
            }

        binding = self._effect(
            "frr-start-" + mode + "-" + target.label,
            [resource_id],
            self._container_command(
                target, "sh", "-ceu", action_script, "--", *action_args
            ),
            postcondition,
            allowed_stderr=frozenset({b""}),
        )
        self._bindings["frr"][resource_id] = copy.deepcopy(binding)
        return binding

    def _stop_frr(self, resource_id: str) -> dict[str, Any]:
        binding = self._bindings["frr"].get(resource_id)
        if not isinstance(binding, dict) or binding.get("mode") not in {
            "client",
            "pathspace",
        }:
            raise SecurityError("FRR cleanup binding is missing")
        target_data = binding.get("target")
        target = self._targets.get(
            target_data.get("label") if isinstance(target_data, dict) else None
        )
        if target is None or target.detached() != target_data:
            raise SecurityError("FRR cleanup target changed")
        mode = binding["mode"]
        expected_daemons = (
            EXPECTED_CLIENT_DAEMONS
            if mode == "client"
            else EXPECTED_PATHSPACE_DAEMONS
        )
        current = self._read_frr_processes(
            "frr-stop-precheck-" + target.label,
            target,
            space="x05",
            mode=mode,
            expected_daemons=expected_daemons,
        )
        if current != binding.get("processes"):
            raise SecurityError("FRR process identity changed before stop")
        if mode == "client":
            script, args = FRR_CLIENT_ACTION, ("stop",)
        else:
            script, args = FRR_PATHSPACE_STOP, ("x05",)

        def postcondition(_result: Any) -> dict[str, Any]:
            remaining = self._read_frr_processes(
                "frr-stop-readback-" + target.label,
                target,
                space="x05",
                mode=mode,
                expected_daemons=None,
            )
            if remaining:
                raise PostconditionError("owned FRR processes remain after stop")
            return {
                "mode": mode,
                "space": "x05",
                "stopped": copy.deepcopy(current),
                "absent": True,
            }

        checked = self._effect(
            "frr-stop-" + mode + "-" + target.label,
            [resource_id],
            self._container_command(target, "sh", "-ceu", script, "--", *args),
            postcondition,
            allowed_stderr=frozenset({b""}),
        )
        self._remove_fixture(
            "frr-remove-fixture-" + mode + "-" + target.label,
            resource_id,
            target,
            binding["file"],
        )
        if mode == "pathspace":
            cleanup_script = (
                "set -eu\n"
                "test -d /etc/frr/x05\n"
                "test -d /run/frr/x05\n"
                "rm -f -- /etc/frr/x05/daemons /etc/frr/x05/vtysh.conf\n"
                "rmdir -- /etc/frr/x05 /run/frr/x05\n"
            )
            self._effect(
                "frr-remove-pathspace-" + target.label,
                [resource_id],
                self._container_command(target, "sh", "-ceu", cleanup_script),
                lambda _result: {"space": "x05", "paths_absent": True},
                allowed_stderr=frozenset({b""}),
            )
        del self._bindings["frr"][resource_id]
        return checked

    def _gateway_baseline(
        self, stage: str, resource_id: str, target: NamespaceTarget
    ) -> dict[str, Any]:
        resource = self._resources[resource_id]
        desired = resource["desired"]
        _base_path, base_raw, base_fixture = self._fixture(
            resource_id, "base_fixture"
        )
        canonical = self._container_file_binding(
            stage + "-canonical", target, desired["base_path"]
        )
        if canonical != {
            "path": desired["base_path"],
            "bytes": len(base_raw),
            "sha256": base_fixture["sha256"],
        }:
            raise SecurityError("gateway canonical FRR file changed")
        running_raw, normalized = self._running_config(stage + "-running", target)
        gateway = target.container_name
        section = self._context["snapshot"]["sections"]["gateway_frr"]
        expected = section.get("gateways", {}).get(gateway)
        if (
            not isinstance(expected, dict)
            or expected.get("base_sha256") != base_fixture["sha256"]
            or expected.get("a_scopes_before") != normalized
            or expected.get("running_config_sha256") != _sha256(running_raw)
        ):
            raise SecurityError("gateway running baseline changed since admission")
        return {
            "target": target.detached(),
            "canonical": canonical,
            "running": running_raw.decode("utf-8", "strict"),
            "running_sha256": _sha256(running_raw),
            "normalized": copy.deepcopy(normalized),
        }

    def _apply_gateway_frr(
        self,
        resource_id: str,
        target: NamespaceTarget,
        *,
        vrf: str,
        neighbor: str,
    ) -> dict[str, Any]:
        baseline = self._gateway_baseline(
            "gateway-before-" + target.label, resource_id, target
        )
        add_path = "/run/labctl-x05-" + self._run_hex + "-gateway-add.conf"
        remove_path = "/run/labctl-x05-" + self._run_hex + "-gateway-remove.conf"
        add_binding = self._copy_fixture(
            "gateway-copy-add-" + target.label,
            resource_id,
            target,
            fixture_key="add_fixture",
            destination=add_path,
        )
        validation = self._read_command(
            "gateway-validate-add-" + target.label,
            self._container_command(target, "vtysh", "-C", "-f", add_path),
        )
        if validation.stdout or validation.stderr:
            raise PostconditionError("gateway FRR validation emitted output")

        def postcondition(result: Any) -> dict[str, Any]:
            if result.stdout:
                raise PostconditionError("gateway FRR apply emitted stdout")
            canonical = self._container_file_binding(
                "gateway-after-canonical-" + target.label,
                target,
                baseline["canonical"]["path"],
            )
            if canonical != baseline["canonical"]:
                raise PostconditionError("gateway canonical FRR file was modified")
            running_raw, normalized = self._running_config(
                "gateway-after-running-" + target.label, target
            )
            protected = self._without_gateway_extension(
                normalized, vrf=vrf, neighbor=neighbor
            )
            if protected != baseline["normalized"]:
                raise PostconditionError("gateway protected FRR scopes changed")
            signatures = self._gateway_extension_signatures(vrf, neighbor)
            if not signatures.issubset(set(normalized)):
                raise PostconditionError("gateway X05 FRR scopes are incomplete")
            return {
                "target": target.detached(),
                "vrf": vrf,
                "neighbor": neighbor,
                "canonical": canonical,
                "running_sha256": _sha256(running_raw),
                "protected_normalized": protected,
                "signatures": sorted(signatures),
            }

        applied = self._effect(
            "gateway-apply-add-" + target.label,
            [resource_id],
            self._container_command(target, "vtysh", "-f", add_path),
            postcondition,
            allowed_stderr=frozenset({b""}),
        )
        self._remove_fixture(
            "gateway-remove-add-fixture-" + target.label,
            resource_id,
            target,
            add_binding,
        )
        remove_binding = self._copy_fixture(
            "gateway-copy-remove-" + target.label,
            resource_id,
            target,
            fixture_key="remove_fixture",
            destination=remove_path,
        )
        binding = {
            **applied,
            "mode": "gateway-delta",
            "baseline": baseline,
            "remove_file": remove_binding,
        }
        self._bindings["frr"][resource_id] = copy.deepcopy(binding)
        return binding

    def _remove_gateway_frr(self, resource_id: str) -> dict[str, Any]:
        binding = self._bindings["frr"].get(resource_id)
        if not isinstance(binding, dict) or binding.get("mode") != "gateway-delta":
            raise SecurityError("gateway FRR cleanup binding is missing")
        target_data = binding.get("target")
        target = self._targets.get(
            target_data.get("label") if isinstance(target_data, dict) else None
        )
        if target is None or target.detached() != target_data:
            raise SecurityError("gateway FRR cleanup target changed")
        baseline = binding.get("baseline")
        if not isinstance(baseline, dict):
            raise SecurityError("gateway FRR baseline binding is missing")
        canonical = self._container_file_binding(
            "gateway-remove-canonical-precheck-" + target.label,
            target,
            baseline["canonical"]["path"],
        )
        running_raw, normalized = self._running_config(
            "gateway-remove-running-precheck-" + target.label, target
        )
        if (
            canonical != baseline["canonical"]
            or self._without_gateway_extension(
                normalized, vrf=binding["vrf"], neighbor=binding["neighbor"]
            )
            != baseline["normalized"]
            or not set(binding["signatures"]).issubset(set(normalized))
        ):
            raise SecurityError("gateway FRR state changed before withdrawal")
        remove_path = binding["remove_file"]["path"]
        validation = self._read_command(
            "gateway-validate-remove-" + target.label,
            self._container_command(target, "vtysh", "-C", "-f", remove_path),
        )
        if validation.stdout or validation.stderr:
            raise PostconditionError("gateway FRR removal validation emitted output")

        def postcondition(result: Any) -> dict[str, Any]:
            if result.stdout:
                raise PostconditionError("gateway FRR removal emitted stdout")
            after_canonical = self._container_file_binding(
                "gateway-removed-canonical-" + target.label,
                target,
                baseline["canonical"]["path"],
            )
            after_raw, after_normalized = self._running_config(
                "gateway-removed-running-" + target.label, target
            )
            if (
                after_canonical != baseline["canonical"]
                or after_raw.decode("utf-8", "strict") != baseline["running"]
                or after_normalized != baseline["normalized"]
            ):
                raise PostconditionError("gateway FRR baseline was not restored")
            return {
                "target": target.detached(),
                "canonical": after_canonical,
                "running_sha256": _sha256(after_raw),
                "baseline_restored": True,
            }

        checked = self._effect(
            "gateway-apply-remove-" + target.label,
            [resource_id],
            self._container_command(target, "vtysh", "-f", remove_path),
            postcondition,
            allowed_stderr=frozenset({b""}),
        )
        self._remove_fixture(
            "gateway-remove-remove-fixture-" + target.label,
            resource_id,
            target,
            binding["remove_file"],
        )
        del self._bindings["frr"][resource_id]
        return checked

    def _read_lrp(
        self, stage: str, *, name: str, expected_mac: str
    ) -> dict[str, Any]:
        command = (
            "docker",
            "exec",
            self._central_id(),
            "ovn-nbctl",
            "--format=json",
            "--data=json",
            "--columns=_uuid,name,mac",
            "find",
            "Logical_Router_Port",
            "name=" + name,
        )
        rows = self._ovs_rows(self._read_command(stage, command).stdout, stage)
        if len(rows) != 1 or set(rows[0]) != {"_uuid", "name", "mac"}:
            raise PostconditionError(stage + " LRP identity is not singular")
        row = rows[0]
        mac_value = row["mac"]
        if isinstance(mac_value, list):
            if len(mac_value) != 1:
                raise PostconditionError(stage + " LRP MAC is not singular")
            mac_value = mac_value[0]
        if (
            row["name"] != name
            or not isinstance(row["_uuid"], str)
            or UUID_RE.fullmatch(row["_uuid"]) is None
            or not isinstance(mac_value, str)
            or mac_value.lower() != expected_mac.lower()
        ):
            raise PostconditionError(stage + " LRP UUID/MAC changed")
        return {"name": name, "uuid": row["_uuid"], "mac": mac_value.lower()}

    def _read_openvswitch_map(
        self, stage: str, target: NamespaceTarget
    ) -> dict[str, Any]:
        command = (
            *self._ovs_prefix(target.container_id, "ovs-vsctl"),
            "--format=json",
            "--data=json",
            "--columns=_uuid,external_ids",
            "list",
            "Open_vSwitch",
        )
        rows = self._ovs_rows(
            self._read_command(stage, command).stdout,
            stage + " Open_vSwitch",
        )
        if (
            len(rows) != 1
            or set(rows[0]) != {"_uuid", "external_ids"}
            or not isinstance(rows[0]["_uuid"], str)
            or UUID_RE.fullmatch(rows[0]["_uuid"]) is None
            or not isinstance(rows[0]["external_ids"], dict)
            or any(
                not isinstance(key, str) or not isinstance(value, str)
                for key, value in rows[0]["external_ids"].items()
            )
        ):
            raise PostconditionError(stage + " Open_vSwitch map is malformed")
        return {
            "uuid": rows[0]["_uuid"],
            "external_ids": dict(sorted(rows[0]["external_ids"].items())),
        }

    def _change_external_ids(self, *, inverse: bool) -> dict[str, Any]:
        target = self._original_target("ovn-chassis-2")
        resource_ids = [CHASSIS_MAPPING_ID, CHASSIS_LOCAL_IP_ID]
        if inverse:
            binding = self._bindings.get("ovs_external_ids")
            if not isinstance(binding, dict):
                raise SecurityError("external-id inverse lacks the captured full map")
            current = self._read_openvswitch_map("external-ids-inverse-precheck", target)
            if current != {"uuid": binding["uuid"], "external_ids": binding["updated"]}:
                raise SecurityError("external-id map changed before inverse")
            before, after = binding["updated"], binding["original"]
            stage = "external-ids-inverse"
        else:
            if self._bindings.get("ovs_external_ids") is not None:
                raise SecurityError("external-id map was already captured")
            current = self._read_openvswitch_map("external-ids-forward-precheck", target)
            before_entry = self._context["snapshot"]["before"][CHASSIS_LOCAL_IP_ID]
            observed = before_entry.get("observed")
            mapping_observed = self._context["snapshot"]["before"][
                CHASSIS_MAPPING_ID
            ].get("observed")
            if (
                not isinstance(observed, dict)
                or not isinstance(mapping_observed, dict)
                or observed.get("ovs_uuid") != current["uuid"]
                or mapping_observed.get("ovs_uuid") != current["uuid"]
                or current["external_ids"].get("ovn-evpn-local-ip")
                != "50100-170.168.0.6"
                or current["external_ids"].get("dynamic-routing-port-mapping")
                not in {None, "", "absent"}
            ):
                raise SecurityError("external-id full map differs from admission")
            before = current["external_ids"]
            after = dict(before)
            after["dynamic-routing-port-mapping"] = (
                "x05-b-" + self._run_hex + "=br-x05-b"
            )
            after["ovn-evpn-local-ip"] = (
                "50100-170.168.0.6,50200-170.168.0.6"
            )
            stage = "external-ids-forward"
            binding = {
                "target": target.detached(),
                "uuid": current["uuid"],
                "original": copy.deepcopy(before),
                "updated": copy.deepcopy(after),
            }
        transaction: list[Any] = [
            "Open_vSwitch",
            {
                "op": "wait",
                "table": "Open_vSwitch",
                "where": [["_uuid", "==", ["uuid", binding["uuid"]]]],
                "columns": ["_uuid", "external_ids"],
                "rows": [
                    {
                        "_uuid": ["uuid", binding["uuid"]],
                        "external_ids": self._ovs_map(before),
                    }
                ],
                "until": "==",
                "timeout": 0,
            },
            {
                "op": "update",
                "table": "Open_vSwitch",
                "where": [["_uuid", "==", ["uuid", binding["uuid"]]]],
                "row": {"external_ids": self._ovs_map(after)},
            },
        ]

        def postcondition(reply: list[dict[str, Any]]) -> dict[str, Any]:
            if reply[1].get("count") != 1:
                raise PostconditionError(stage + " full-map CAS count changed")
            readback = self._read_openvswitch_map(stage + "-readback", target)
            if readback != {"uuid": binding["uuid"], "external_ids": after}:
                raise PostconditionError(stage + " full-map readback changed")
            return {
                "uuid": binding["uuid"],
                "before": copy.deepcopy(before),
                "after": copy.deepcopy(after),
                "inverse": inverse,
            }

        checked = self._ovsdb_effect(
            stage,
            resource_ids,
            container_id=target.container_id,
            transaction=transaction,
            postcondition=postcondition,
        )
        if inverse:
            self._bindings["ovs_external_ids"] = None
        else:
            self._bindings["ovs_external_ids"] = copy.deepcopy(binding)
        return checked

    def _require_link_absent(
        self,
        stage: str,
        target: NamespaceTarget,
        name: str,
        *,
        namespace: str | None = None,
    ) -> None:
        if not self._link_absent(stage, target, name, namespace=namespace):
            raise SecurityError("fixed X05 link name is no longer absent: " + name)

    def _require_netns_absent(
        self, stage: str, target: NamespaceTarget, namespace: str
    ) -> None:
        if target.container_id is None:
            raise SecurityError("named namespace requires a container target")
        result = self._read_command(
            stage,
            (
                "docker",
                "exec",
                target.container_id,
                "stat",
                "-Lc",
                "%i",
                "/var/run/netns/" + namespace,
            ),
            allowed_rc=frozenset({0, 1}),
        )
        if result.returncode == 0 or result.stdout:
            raise SecurityError("fixed X05 namespace is no longer absent: " + namespace)

    def _build_attachment(
        self,
        resource_id: str,
        target: NamespaceTarget,
        *,
        host_name: str,
        container_name: str,
        bridge: str,
        address: str,
        tag: int | None,
        mtu: int,
    ) -> dict[str, Any]:
        host = self._host_target()
        self._require_link_absent("attachment-host-before-" + host_name, host, host_name)
        self._require_link_absent(
            "attachment-container-before-" + container_name,
            target,
            container_name,
        )
        rows = self._private_publish(
            "attachment-publish-" + host_name,
            [resource_id],
            kind="veth",
            names=(host_name, container_name),
            targets=(host, target),
        )
        self._set_mtu(
            "attachment-host-mtu-" + host_name,
            resource_id,
            host,
            host_name,
            mtu,
        )
        self._set_link_up(
            "attachment-host-up-" + host_name,
            resource_id,
            host,
            host_name,
        )
        self._set_mtu(
            "attachment-container-mtu-" + container_name,
            resource_id,
            target,
            container_name,
            mtu,
        )
        self._set_link_up(
            "attachment-container-up-" + container_name,
            resource_id,
            target,
            container_name,
        )
        container_link = self._add_address(
            "attachment-container-address-" + container_name,
            resource_id,
            target,
            container_name,
            address,
        )
        assert target.container_id is not None
        ovs = self._add_ovs_port(
            "attachment-ovs-" + host_name,
            resource_id,
            container_id=None,
            bridge=bridge,
            interface=host_name,
            tag=tag,
            port_external_ids={"x05-owner": self._owner},
            interface_external_ids={
                "container_id": target.container_name or "",
                "container_iface": container_name,
                "x05-owner": self._owner,
            },
        )
        return {
            "resource_id": resource_id,
            "logical_container_id": target.container_id,
            "logical_container_name": target.container_name,
            "container_interface": container_name,
            "host_interface": host_name,
            "published": copy.deepcopy(rows),
            "container_link": container_link,
            "ovs": ovs,
        }

    def _build_gateway_mirror(
        self,
        *,
        number: int,
        gateway: str,
        address: str,
        expected_mac: str,
    ) -> dict[str, Any]:
        target = self._original_target(gateway)
        outer_name = f"bgpvrf{number}-ovs"
        inner_name = f"bgpvrf{number}"
        outer_id = f"container:{gateway}/linux-veth/{outer_name}"
        inner_id = f"container:{gateway}/linux-veth/{inner_name}"
        ovs_id = f"container:{gateway}/ovs-port-interface/{outer_name}"
        generated_id = f"container:{gateway}/ovn-generated-vrf/ovnvrf{number}"
        self._require_link_absent("gateway-outer-before-" + gateway, target, outer_name)
        self._require_link_absent("gateway-inner-before-" + gateway, target, inner_name)
        lrp = self._read_lrp(
            "gateway-lrp-" + gateway,
            name=f"lrp-x05-{number}-external",
            expected_mac=expected_mac,
        )
        rows = self._private_publish(
            "gateway-veth-publish-" + gateway,
            [outer_id, inner_id],
            kind="veth",
            names=(outer_name, inner_name),
            targets=(target, target),
        )
        self._set_link_up("gateway-outer-up-" + gateway, outer_id, target, outer_name)
        self._set_master(
            "gateway-inner-master-" + gateway,
            inner_id,
            target,
            inner_name,
            "ovnvrf" + str(number),
        )
        self._set_mac(
            "gateway-inner-mac-" + gateway,
            inner_id,
            target,
            inner_name,
            lrp["mac"],
        )
        self._set_link_up("gateway-inner-up-" + gateway, inner_id, target, inner_name)
        inner = self._add_address(
            "gateway-inner-address-" + gateway,
            inner_id,
            target,
            inner_name,
            address,
        )
        ovs = self._add_ovs_port(
            "gateway-ovs-" + gateway,
            ovs_id,
            container_id=target.container_id,
            bridge="br-int",
            interface=outer_name,
            tag=None,
            port_external_ids={"x05-owner": self._owner},
            interface_external_ids={
                "iface-id": inner_name,
                "x05-owner": self._owner,
            },
        )
        return {
            "number": number,
            "target": target.detached(),
            "lrp": lrp,
            "generated_vrf": copy.deepcopy(
                self._bindings["generated_vrfs"][generated_id]
            ),
            "published": copy.deepcopy(rows),
            "inner": inner,
            "ovs": ovs,
        }

    def _set_namespace_loopback_up(
        self,
        resource_id: str,
        target: NamespaceTarget,
        namespace: str,
    ) -> dict[str, Any]:
        def postcondition(_result: Any) -> dict[str, Any]:
            row = self._link_read(
                "sentinel-loopback-readback-" + namespace,
                target,
                "lo",
                namespace=namespace,
            )
            flags = row.get("flags")
            if not isinstance(flags, list) or "UP" not in flags:
                raise PostconditionError("sentinel loopback is not up")
            return row

        return self._effect(
            "sentinel-loopback-up-" + namespace,
            [resource_id],
            self._nested_command(
                target, namespace, "ip", "link", "set", "dev", "lo", "up"
            ),
            postcondition,
            allowed_stderr=frozenset({b""}),
        )

    def _build_sentinel(
        self,
        *,
        chassis: str,
        suffix: str,
        mac: str,
        address: str,
    ) -> dict[str, Any]:
        target = self._original_target(chassis)
        namespace = "x05-tenant-" + suffix + "-vm"
        outer_name = "x05-tenant-" + suffix + "-p"
        inner_name = "x05-tenant-" + suffix
        namespace_id = f"container:{chassis}/netns/{namespace}"
        outer_id = f"container:{chassis}/linux-veth/{outer_name}"
        inner_id = f"netns:{chassis}:{namespace}/linux-veth/{inner_name}"
        ovs_id = f"container:{chassis}/ovs-port-interface/{outer_name}"
        self._require_netns_absent(
            "sentinel-netns-before-" + suffix, target, namespace
        )
        self._require_link_absent(
            "sentinel-outer-before-" + suffix, target, outer_name
        )
        self._require_link_absent(
            "sentinel-inner-before-" + suffix, target, inner_name
        )
        netns = self._create_netns(namespace_id, target, namespace)
        published = self._private_publish(
            "sentinel-veth-publish-" + suffix,
            [outer_id, inner_id],
            kind="veth",
            names=(outer_name, inner_name),
            targets=(target, target),
        )
        inner = self._move_link_to_netns(
            "sentinel-inner-move-" + suffix,
            inner_id,
            target,
            inner_name,
            namespace,
        )
        outer = self._link_read(
            "sentinel-outer-after-move-" + suffix, target, outer_name
        )
        if (
            outer["alias"] != self._owner
            or inner["alias"] != self._owner
            or outer["ifindex"] != inner["iflink"]
            or inner["ifindex"] != outer["iflink"]
        ):
            raise PostconditionError("sentinel veth identity changed across netns move")
        self._bindings["links"][outer_id] = copy.deepcopy(outer)
        namespace_binding = self._bindings["namespaces"][namespace_id]
        namespace_binding["owned_veth_bound"] = True
        namespace_binding["veth_resource_id"] = inner_id
        namespace_binding["veth_ifindex"] = inner["ifindex"]
        self._set_namespace_loopback_up(namespace_id, target, namespace)
        self._set_link_up(
            "sentinel-outer-up-" + suffix, outer_id, target, outer_name
        )
        self._set_mac(
            "sentinel-inner-mac-" + suffix,
            inner_id,
            target,
            inner_name,
            mac,
            namespace=namespace,
        )
        self._set_link_up(
            "sentinel-inner-up-" + suffix,
            inner_id,
            target,
            inner_name,
            namespace=namespace,
        )
        inner = self._add_address(
            "sentinel-inner-address-" + suffix,
            inner_id,
            target,
            inner_name,
            address,
            namespace=namespace,
        )
        route = self._replace_default_route(
            "sentinel-route-" + suffix,
            inner_id,
            target,
            inner_name,
            "192.168.100.1",
            namespace=namespace,
        )
        ovs = self._add_ovs_port(
            "sentinel-ovs-" + suffix,
            ovs_id,
            container_id=target.container_id,
            bridge="br-int",
            interface=outer_name,
            tag=None,
            port_external_ids={"x05-owner": self._owner},
            interface_external_ids={
                "iface-id": namespace,
                "x05-owner": self._owner,
            },
        )
        return {
            "namespace": copy.deepcopy(namespace_binding),
            "published": copy.deepcopy(published),
            "outer": copy.deepcopy(self._bindings["links"][outer_id]),
            "inner": inner,
            "route": route,
            "ovs": ovs,
        }

    def _build_owned_link(
        self,
        resource_id: str,
        target: NamespaceTarget,
        *,
        kind: str,
        name: str,
        master: str | None = None,
        mac: str | None = None,
        address: str | None = None,
        extra: Mapping[str, Any] | None = None,
        allowed_stderr: frozenset[bytes] | None = frozenset({b""}),
    ) -> dict[str, Any]:
        self._require_link_absent("owned-link-before-" + name, target, name)
        row = self._private_publish(
            "owned-link-publish-" + name,
            [resource_id],
            kind=kind,
            names=(name,),
            targets=(target,),
            extra=extra,
            allowed_stderr=allowed_stderr,
        )[0]
        if master is not None:
            row = self._set_master(
                "owned-link-master-" + name,
                resource_id,
                target,
                name,
                master,
            )
        if mac is not None:
            row = self._set_mac(
                "owned-link-mac-" + name,
                resource_id,
                target,
                name,
                mac,
            )
        row = self._set_link_up(
            "owned-link-up-" + name, resource_id, target, name
        )
        if address is not None:
            row = self._add_address(
                "owned-link-address-" + name,
                resource_id,
                target,
                name,
                address,
            )
        return row

    def _build_chassis_network(self) -> dict[str, Any]:
        target = self._original_target("ovn-chassis-2")
        vrf_id = "container:ovn-chassis-2/ovn-generated-vrf/ovnvrf-x05-b"
        if vrf_id not in self._bindings["generated_vrfs"]:
            raise SecurityError("chassis generated VRF was not observed")
        lrp = self._read_lrp(
            "chassis-tenant-lrp",
            name="lrp-x05-tenant-b",
            expected_mac="02:00:00:20:00:01",
        )
        bridge_id = "container:ovn-chassis-2/linux-bridge/br-x05-b"
        vxlan_id = "container:ovn-chassis-2/linux-vxlan/vxlan-x05-b"
        dummy_id = "container:ovn-chassis-2/linux-dummy/evpn-x05-b"
        bridge = self._build_owned_link(
            bridge_id,
            target,
            kind="bridge",
            name="br-x05-b",
            master="ovnvrf-x05-b",
            mac=lrp["mac"],
        )
        underlay = self._link_read(
            "chassis-vxlan-underlay", target, "vxlan_sys_4789"
        )
        underlay_info = underlay.get("linkinfo")
        if (
            not isinstance(underlay_info, dict)
            or underlay_info.get("info_kind") != "vxlan"
        ):
            raise SecurityError("chassis VXLAN underlay identity changed")
        vxlan = self._build_owned_link(
            vxlan_id,
            target,
            kind="vxlan",
            name="vxlan-x05-b",
            master="br-x05-b",
            extra={
                "vni": 50200,
                "local": "170.168.0.6",
                "underlay": "vxlan_sys_4789",
                "underlay_ifindex": underlay["ifindex"],
                "dstport": 60010,
            },
            allowed_stderr=frozenset({b"", KNOWN_VXLAN_STDERR}),
        )
        dummy = self._build_owned_link(
            dummy_id,
            target,
            kind="dummy",
            name="evpn-x05-b",
            master="br-x05-b",
        )
        return {
            "target": target.detached(),
            "generated_vrf": copy.deepcopy(
                self._bindings["generated_vrfs"][vrf_id]
            ),
            "lrp": lrp,
            "underlay": underlay,
            "bridge": bridge,
            "vxlan": vxlan,
            "dummy": dummy,
        }

    def _build_peer_network(self, target: NamespaceTarget) -> dict[str, Any]:
        vrf_id = "container:dci-x05-peer-2/linux-vrf/vrf-x05-peer"
        bridge_id = "container:dci-x05-peer-2/linux-bridge/br-x05-peer"
        vxlan_id = "container:dci-x05-peer-2/linux-vxlan/vxlan-x05-pr"
        dummy_id = "container:dci-x05-peer-2/linux-dummy/evpn-x05-pr"
        vrf = self._build_owned_link(
            vrf_id,
            target,
            kind="vrf",
            name="vrf-x05-peer",
            extra={"table": 50200},
        )
        bridge = self._build_owned_link(
            bridge_id,
            target,
            kind="bridge",
            name="br-x05-peer",
            master="vrf-x05-peer",
            address="10.251.0.1/32",
        )
        underlay = self._link_read("peer-vxlan-underlay", target, "eth1")
        if self._address_read("peer-vxlan-underlay-address", target, "eth1") != [
            "170.168.0.8/16"
        ]:
            raise SecurityError("peer VXLAN underlay address changed")
        vxlan = self._build_owned_link(
            vxlan_id,
            target,
            kind="vxlan",
            name="vxlan-x05-pr",
            master="br-x05-peer",
            extra={
                "vni": 50200,
                "local": "170.168.0.8",
                "underlay": "eth1",
                "underlay_ifindex": underlay["ifindex"],
                "dstport": 4789,
            },
            allowed_stderr=frozenset({b"", KNOWN_VXLAN_STDERR}),
        )
        dummy = self._build_owned_link(
            dummy_id,
            target,
            kind="dummy",
            name="evpn-x05-pr",
            master="br-x05-peer",
        )
        return {
            "target": target.detached(),
            "underlay": underlay,
            "vrf": vrf,
            "bridge": bridge,
            "vxlan": vxlan,
            "dummy": dummy,
        }

    def _bound_resource_ids(self) -> set[str]:
        ids = set(self._bindings["links"])
        ids.update(self._bindings["namespaces"])
        ids.update(self._bindings["ovs"])
        ids.update(self._bindings["frr"])
        if self._bindings.get("ovs_external_ids") is not None:
            ids.update({CHASSIS_MAPPING_ID, CHASSIS_LOCAL_IP_ID})
        for name in self._bindings["containers"]:
            if name == "dci-client-2":
                ids.add(CLIENT_CONTAINER_ID)
            elif name == "dci-x05-peer-2":
                ids.add(PEER_CONTAINER_ID)
            else:
                raise SecurityError("unexpected created container binding")
        return ids

    def _verify_ovs_binding(self, resource_id: str) -> dict[str, Any]:
        binding = self._bindings["ovs"].get(resource_id)
        if not isinstance(binding, dict):
            raise SecurityError("OVS binding is missing: " + resource_id)
        current = self._read_ovs_binding(
            "ovs-final-recheck-" + self._resources[resource_id]["name"],
            container_id=binding["container_id"],
            bridge=binding["bridge"],
            interface=binding["port_name"],
            expected_tag=binding["tag"],
            expected_port_external_ids=binding["port_external_ids"],
            expected_interface_external_ids=binding["interface_external_ids"],
            expected_bridge_uuid=binding["bridge_uuid"],
        )
        if current != binding:
            raise SecurityError("OVS binding changed: " + resource_id)
        return current

    def _verify_link_binding(self, resource_id: str) -> Any:
        binding = self._bindings["links"].get(resource_id)
        if not isinstance(binding, dict):
            raise SecurityError("link binding is missing: " + resource_id)
        if isinstance(binding.get("pair"), list):
            rows = self._attachment_rows(resource_id)
            fresh = [
                self._fresh_link_from_binding(
                    "link-final-attachment-" + str(index), row
                )
                for index, row in enumerate(rows, 1)
            ]
            if (
                fresh[0]["ifindex"] != fresh[1]["iflink"]
                or fresh[1]["ifindex"] != fresh[0]["iflink"]
                or any(row["alias"] != self._owner for row in fresh)
            ):
                raise SecurityError("attachment identity changed: " + resource_id)
            return fresh
        current = self._fresh_link_from_binding(
            "link-final-" + self._resources[resource_id]["name"], binding
        )
        if current["alias"] != self._owner:
            raise SecurityError("owned link alias changed: " + resource_id)
        return current

    def _verify_frr_binding(self, resource_id: str) -> dict[str, Any]:
        binding = self._bindings["frr"].get(resource_id)
        if not isinstance(binding, dict):
            raise SecurityError("FRR binding is missing: " + resource_id)
        target_data = binding.get("target")
        target = self._targets.get(
            target_data.get("label") if isinstance(target_data, dict) else None
        )
        if target is None or target.detached() != target_data:
            raise SecurityError("FRR target identity changed")
        if binding.get("mode") == "gateway-delta":
            canonical = self._container_file_binding(
                "gateway-final-canonical-" + target.label,
                target,
                binding["baseline"]["canonical"]["path"],
            )
            _raw, normalized = self._running_config(
                "gateway-final-running-" + target.label, target
            )
            if (
                canonical != binding["baseline"]["canonical"]
                or self._without_gateway_extension(
                    normalized,
                    vrf=binding["vrf"],
                    neighbor=binding["neighbor"],
                )
                != binding["baseline"]["normalized"]
                or not set(binding["signatures"]).issubset(set(normalized))
            ):
                raise SecurityError("gateway FRR binding changed")
        else:
            expected = (
                EXPECTED_CLIENT_DAEMONS
                if binding.get("mode") == "client"
                else EXPECTED_PATHSPACE_DAEMONS
            )
            processes = self._read_frr_processes(
                "frr-final-processes-" + target.label,
                target,
                space="x05",
                mode=binding["mode"],
                expected_daemons=expected,
            )
            if processes != binding["processes"]:
                raise SecurityError("FRR process identity changed")
            file_current = self._container_file_binding(
                "frr-final-file-" + target.label,
                target,
                binding["file"]["path"],
            )
            if file_current != {
                "path": binding["file"]["path"],
                "bytes": binding["file"]["bytes"],
                "sha256": binding["file"]["sha256"],
            }:
                raise SecurityError("FRR fixture identity changed")
        return copy.deepcopy(binding)

    def _verify_complete_runtime(self) -> dict[str, Any]:
        self._verify_authority()
        bound = self._bound_resource_ids()
        if bound != BASE_MUTABLE_IDS:
            missing = sorted(BASE_MUTABLE_IDS - bound)
            extra = sorted(bound - BASE_MUTABLE_IDS)
            raise SecurityError(
                "runtime bindings do not cover the frozen base: missing="
                + ",".join(missing)
                + " extra="
                + ",".join(extra)
            )
        for name in ("dci-client-2", "dci-x05-peer-2"):
            self._verify_created_container(name)
        for resource_id in sorted(self._bindings["links"]):
            self._verify_link_binding(resource_id)
        for resource_id in sorted(self._bindings["namespaces"]):
            self._verify_netns(resource_id)
        for resource_id in sorted(self._bindings["ovs"]):
            self._verify_ovs_binding(resource_id)
        for resource_id in sorted(self._bindings["frr"]):
            self._verify_frr_binding(resource_id)
        for resource_id, binding in sorted(
            self._bindings["generated_vrfs"].items()
        ):
            target = self._targets.get(binding["target"]["label"])
            if target is None:
                raise SecurityError("generated VRF target binding is missing")
            current = self._observe_generated_vrf(resource_id, target)
            if self._link_identity(current) != self._link_identity(binding):
                raise SecurityError("generated VRF identity changed")
        external = self._bindings.get("ovs_external_ids")
        if not isinstance(external, dict):
            raise SecurityError("updated Open_vSwitch map binding is missing")
        target = self._targets[external["target"]["label"]]
        current_map = self._read_openvswitch_map("external-ids-final", target)
        if current_map != {"uuid": external["uuid"], "external_ids": external["updated"]}:
            raise SecurityError("updated Open_vSwitch full map changed")
        b_restore = self._read_b_restore("b-restore-built")
        if self._bindings["b_restore"] is None:
            self._bindings["b_restore"] = copy.deepcopy(b_restore)
        elif b_restore != self._bindings["b_restore"]:
            raise SecurityError("B LSP/SB restore identity changed")
        return {
            "mutable_ids": sorted(bound),
            "mutable_count": len(bound),
            "generated_ids": sorted(self._bindings["generated_vrfs"]),
            "generated_count": len(self._bindings["generated_vrfs"]),
            "b_restore": copy.deepcopy(b_restore),
        }

    def _capture_point(
        self,
        point_id: str,
        target: NamespaceTarget,
        interfaces: Sequence[tuple[str, Mapping[str, Any]]],
    ) -> dict[str, Any]:
        rows: list[dict[str, Any]] = []
        for name, lineage in interfaces:
            stage = "capture-binding-" + point_id + "-" + name
            row = self._link_read(stage, target, name)
            row["addresses"] = self._address_read(stage + "-addresses", target, name)
            row["lineage"] = copy.deepcopy(dict(lineage))
            rows.append(row)
        return {
            "id": point_id,
            "target": target.detached(),
            "interfaces": rows,
            "target_sha256": _sha256(
                _canonical(
                    {
                        "id": point_id,
                        "target": target.detached(),
                        "interfaces": rows,
                    }
                )
            ),
        }

    def _capture_source(
        self,
        source_id: str,
        target: NamespaceTarget,
        interface: str,
        address: str,
        receive: Sequence[tuple[str, str]],
        *,
        lineage: Mapping[str, Any],
        owned_m03: Mapping[str, Any] | None = None,
    ) -> dict[str, Any]:
        stage = "capture-source-" + source_id
        link = self._link_read(stage, target, interface)
        link["addresses"] = self._address_read(stage + "-addresses", target, interface)
        link["lineage"] = copy.deepcopy(dict(lineage))
        if address + "/32" not in link["addresses"]:
            raise SecurityError("capture source address changed: " + source_id)
        value = {
            "id": source_id,
            "source": address,
            "target": target.detached(),
            "link": link,
            "receive": [
                {"point": point, "interface": name} for point, name in receive
            ],
            "owned_m03": copy.deepcopy(owned_m03),
        }
        value["source_sha256"] = _sha256(_canonical(value))
        return value

    def capture_bindings(self) -> dict[str, Any]:
        """Return fresh detached identities for exactly five continuous captures."""
        with self._operation_scope("capture-bindings"):
            return self._capture_bindings()

    def _capture_bindings(self) -> dict[str, Any]:
        self._verify_authority()
        if self._state != "BUILT" or self._unknown or self._built_result is None:
            raise SecurityError("capture bindings require this builder's verified BUILT state")
        self._verify_complete_runtime()
        m03 = _COLLECTOR_OWNED_M03_IDENTITY(self._collector, self._profile_owner)
        if (
            not isinstance(m03, dict)
            or m03.get("m03", {}).get("peer") != self._anchors.get("m03_peer")
            or m03.get("m03", {}).get("links") != self._anchors.get("m03_links")
        ):
            raise SecurityError("original M03 capture source identity changed")
        m03_interface = self._anchors.get("m03_peer", {}).get("ovs", {}).get(
            "interface_name"
        )
        if not isinstance(m03_interface, str) or IFNAME_RE.fullmatch(m03_interface) is None:
            raise SecurityError("admission lacks the actual M03 host interface")
        peer_ovs = self._bindings["ovs"].get(PEER_ETH1_ID)
        tap_a_ovs = self._bindings["ovs"].get(
            "container:ovn-chassis-1/ovs-port-interface/x05-tenant-a-p"
        )
        tap_b_ovs = self._bindings["ovs"].get(
            "container:ovn-chassis-2/ovs-port-interface/x05-tenant-b-p"
        )
        gw300_ovs = self._bindings["ovs"].get(
            "container:ovn-gw-1/ovs-port-interface/bgpvrf300-ovs"
        )
        gw400_ovs = self._bindings["ovs"].get(
            "container:ovn-gw-2/ovs-port-interface/bgpvrf400-ovs"
        )
        if any(
            not isinstance(value, dict)
            for value in (peer_ovs, tap_a_ovs, tap_b_ovs, gw300_ovs, gw400_ovs)
        ):
            raise SecurityError("capture OVS lineage binding is incomplete")
        points = [
            self._capture_point(
                "fabric",
                self._host_target(),
                (
                    (
                        "br-ovn",
                        {
                            "kind": "ovs-bridge",
                            "bridge_uuid": self._anchors["bridges"]["br-ovn"]["uuid"],
                        },
                    ),
                    (m03_interface, {"kind": "m03-ovs-port", **self._anchors["m03_peer"]["ovs"]}),
                    (peer_ovs["port_name"], {"kind": "owned-ovs-port", "ovs": peer_ovs}),
                ),
            ),
            self._capture_point(
                "chassis-1",
                self._original_target("ovn-chassis-1"),
                (
                    ("x05-tenant-a-p", {"kind": "owned-ovs-port", "ovs": tap_a_ovs}),
                    ("vxlan_sys_4789", {"kind": "ovn-system-vxlan"}),
                ),
            ),
            self._capture_point(
                "chassis-2",
                self._original_target("ovn-chassis-2"),
                (
                    ("x05-tenant-b-p", {"kind": "owned-ovs-port", "ovs": tap_b_ovs}),
                    ("vxlan_sys_4789", {"kind": "ovn-system-vxlan"}),
                ),
            ),
            self._capture_point(
                "gateway-300",
                self._original_target("ovn-gw-1"),
                (
                    ("bgpvrf100", {"kind": "legacy-gateway-veth", "ovs_peer": "bgpvrf100-ovs"}),
                    ("bgpvrf300", {"kind": "owned-gateway-veth", "ovs": gw300_ovs}),
                ),
            ),
            self._capture_point(
                "gateway-400",
                self._original_target("ovn-gw-2"),
                (
                    ("bgpvrf200", {"kind": "legacy-gateway-veth", "ovs_peer": "bgpvrf200-ovs"}),
                    ("bgpvrf400", {"kind": "owned-gateway-veth", "ovs": gw400_ovs}),
                ),
            ),
        ]
        if tuple(point["id"] for point in points) != CAPTURE_POINT_IDS:
            raise SecurityError("capture point inventory changed")
        assert self._journal is not None and self._marker_bytes is not None
        journal = self._journal.binding()
        sources = [
            self._capture_source(
                "classic-original",
                self._original_target("dci-client-1"),
                "lo",
                "10.0.0.1",
                (("gateway-300", "bgpvrf100"), ("gateway-400", "bgpvrf200")),
                lineage={"kind": "original-dci-client"},
            ),
            self._capture_source(
                "classic-created",
                self._created_target("dci-client-2"),
                "lo",
                "10.0.0.1",
                (("gateway-300", "bgpvrf300"), ("gateway-400", "bgpvrf400")),
                lineage={"kind": "owned-x05-client"},
            ),
            self._capture_source(
                "evpn-original",
                self._capture_target(
                    "dci-evpn-client-1",
                    container_name="dci-evpn-client-1",
                    container_id=m03["m03"]["peer"]["id"],
                ),
                "br-evpn-client",
                "10.250.0.1",
                (("fabric", m03_interface),),
                lineage={"kind": "original-m03-peer"},
                owned_m03=m03,
            ),
            self._capture_source(
                "evpn-created",
                self._created_target("dci-x05-peer-2"),
                "br-x05-peer",
                "10.251.0.1",
                (("fabric", peer_ovs["port_name"]),),
                lineage={"kind": "owned-x05-peer"},
            ),
        ]
        contract = {
            "schema": "p004-x05-runtime-capture-bindings-v1",
            "owner": self._owner,
            "run_hex": self._run_hex,
            "marker_sha256": _sha256(self._marker_bytes),
            "runtime_journal_path": journal["artifact_path"],
            "runtime_journal_sha256": journal["artifact_sha256"],
            "runtime_journal_head_sha256": journal["journal_head_sha256"],
            "points": points,
            "sources": sources,
            "pid_journal": {
                "schema": CAPTURE_PID_SCHEMA,
                "path": str(self._config.evidence_path / CAPTURE_PID_NAME),
                "required_state": "STOPPED",
                "capture_ids": list(CAPTURE_POINT_IDS),
                "entry_fields": [
                    "id",
                    "pid",
                    "start_ticks",
                    "argv",
                    "argv_sha256",
                    "target_sha256",
                    "started_at_ns",
                    "stop_intent_at_ns",
                    "reaped_at_ns",
                    "wait_returncode",
                    "reaped",
                ],
            },
        }
        if self._capture_contract is None:
            self._capture_contract = copy.deepcopy(contract)
        else:
            stable_keys = (
                "schema",
                "owner",
                "run_hex",
                "marker_sha256",
                "points",
                "sources",
            )
            if any(
                contract[key] != self._capture_contract[key] for key in stable_keys
            ) or contract["pid_journal"] != self._capture_contract["pid_journal"]:
                raise SecurityError("capture binding identities changed")
            # Fresh readbacks legitimately advance the private builder journal.
            # The same builder object retains only the most recent checkpoint;
            # the stopped PID artifact must bind that exact checkpoint.
            self._capture_contract = copy.deepcopy(contract)
        return copy.deepcopy(contract)

    def _capture_module(self) -> Any:
        module = sys.modules.get(CAPTURE_MODULE_NAME)
        if (
            module is None
            or pathlib.Path(getattr(module, "__file__", "")).resolve()
            != CAPTURE_SOURCE_PATH.resolve()
            or getattr(module, "APPLY", None) is not sys.modules.get(__name__)
            or getattr(module, "APPLY_MODULE_NAME", None)
            != CAPTURE_APPLY_MODULE_NAME
        ):
            raise SecurityError("canonical capture creator module is unavailable")
        return module

    def _verify_capture_creator(self, capture: Any, *, attached: bool = True) -> Any:
        module = self._capture_module()
        capture_type = getattr(module, "CaptureSession", None)
        if (
            type(capture) is not capture_type
            or capture._builder is not self
            or capture._contract is not self._capture_contract
            or (attached and self._capture_session is not capture)
            or any(
                name in capture.__dict__
                for name in (
                    "start",
                    "health",
                    "stop",
                    "_read_owned_pcaps",
                    "_release_after_compensation",
                )
            )
            or capture_type.start is not module._CAPTURE_SESSION_START
            or capture_type.health is not module._CAPTURE_SESSION_HEALTH
            or capture_type.stop is not module._CAPTURE_SESSION_STOP
            or capture_type._read_owned_pcaps
            is not module._CAPTURE_SESSION_READ_OWNED
            or capture_type._release_after_compensation
            is not module._CAPTURE_SESSION_RELEASE
        ):
            raise SecurityError("capture creator identity or receiver changed")
        return module

    def _verify_normal_capture_path(self) -> None:
        if self._state != "BUILT" or self._unknown or self._built_result is None:
            raise SecurityError("capture requires the verified normal BUILT state")
        forward = self._bindings["nb"].get("forward")
        if not isinstance(forward, dict) or forward != self._nb_artifact_binding(
            state="forward"
        ):
            raise SecurityError("normal NB forward artifact binding changed")
        raw, _ = _read_regular(
            self._config.evidence_path / "journal.json",
            maximum=MAX_LOCAL_FILE,
            mode=0o600,
            uid=self._config.required_uid,
        )
        value = self._json(raw, "NB forward journal")
        if (
            not isinstance(value, dict)
            or value.get("schema") != NB.Journal.SCHEMA
            or value.get("owner") != self._owner
            or value.get("run_hex") != self._run_hex
            or value.get("state") != "NB_FORWARD_VERIFIED"
            or NB.canonical_json(value) != raw
            or any(
                isinstance(event, dict)
                and "RECOVER" in str(event.get("state", ""))
                for event in value.get("events", ())
            )
        ):
            raise SecurityError("capture refuses a recovered or ambiguous NB journal")

    def _verify_capture_contract_current(self) -> None:
        if self._capture_contract is None:
            raise SecurityError("capture bindings are unavailable")
        for point in self._capture_contract["points"]:
            target_data = point["target"]
            target = self._targets.get(target_data["label"])
            if target is None or target.detached() != target_data:
                raise SecurityError("capture point target identity changed")
            self._verify_target(target)
            for expected in point["interfaces"]:
                stage = "capture-health-" + point["id"] + "-" + expected["name"]
                current = self._link_read(stage, target, expected["name"])
                current["addresses"] = self._address_read(
                    stage + "-addresses", target, expected["name"]
                )
                current["lineage"] = copy.deepcopy(expected["lineage"])
                if current != expected:
                    raise SecurityError("capture interface identity changed: " + expected["name"])
                lineage = expected["lineage"]
                owned = lineage.get("ovs") if isinstance(lineage, dict) else None
                if isinstance(owned, dict):
                    current_ovs = self._read_ovs_binding(
                        stage + "-ovs",
                        container_id=owned["container_id"],
                        bridge=owned["bridge"],
                        interface=owned["port_name"],
                        expected_tag=owned["tag"],
                        expected_port_external_ids=owned["port_external_ids"],
                        expected_interface_external_ids=owned[
                            "interface_external_ids"
                        ],
                        expected_bridge_uuid=owned["bridge_uuid"],
                    )
                    if current_ovs != owned:
                        raise SecurityError("capture OVS lineage changed")
        for source in self._capture_contract["sources"]:
            target_data = source["target"]
            target = self._targets.get(target_data["label"])
            if target is None or target.detached() != target_data:
                raise SecurityError("capture source target identity changed")
            expected = source["link"]
            stage = "capture-source-health-" + source["id"]
            current = self._link_read(stage, target, expected["name"])
            current["addresses"] = self._address_read(
                stage + "-addresses", target, expected["name"]
            )
            current["lineage"] = copy.deepcopy(expected["lineage"])
            if current != expected:
                raise SecurityError("capture source link identity changed: " + source["id"])
            if source["owned_m03"] is not None:
                current_m03 = _COLLECTOR_OWNED_M03_IDENTITY(
                    self._collector, self._profile_owner
                )
                if current_m03 != source["owned_m03"]:
                    raise SecurityError("complete original M03 identity changed")

    def _attach_capture_session(self, capture: Any) -> None:
        with self._consume_lock:
            self._verify_authority()
            self._verify_normal_capture_path()
            self._verify_capture_creator(capture, attached=False)
            if self._capture_session is not None or self._marker_bytes is None:
                raise SecurityError("capture creator is already attached")
            if capture._contract is not self._capture_contract:
                raise SecurityError("capture creator did not retain the exact contract")
            self._capture_built_marker_bytes = self._marker_bytes
            self._capture_session = capture

    def _record_capture_spawn_intent(self, capture: Any, capture_id: str) -> None:
        with self._consume_lock:
            self._verify_authority()
            self._verify_normal_capture_path()
            self._verify_capture_creator(capture)
            if capture_id not in CAPTURE_POINT_IDS or capture._state != "STARTING":
                raise SecurityError("capture spawn intent is not canonical")
            detail = {
                "status": "INTENT",
                "operation": "capture-spawn",
                "resource_ids": [capture_id],
                "capture_id": capture_id,
                "argv_sha256": capture._slots[capture_id]["argv_sha256"],
            }
            self._journal_append("capture-intent", "capture-spawn-" + capture_id, detail)
            self._publish("x05-capture-state", "capture-spawn-" + capture_id, detail)

    def _record_capture_progress(self, capture: Any) -> dict[str, Any]:
        with self._consume_lock:
            self._verify_authority()
            self._verify_normal_capture_path()
            self._verify_capture_creator(capture)
            if self._capture_built_marker_bytes is None or self._marker_bytes is None:
                raise SecurityError("capture marker base is unavailable")
            if not capture._pid_raw or _sha256(capture._pid_raw) != capture._pid_sha256:
                raise SecurityError("capture PID publication is not bound")
            pid_raw, _ = _read_regular(
                pathlib.Path(self._capture_contract["pid_journal"]["path"]),
                maximum=1024 * 1024,
                mode=0o600,
                uid=self._config.required_uid,
            )
            if pid_raw != capture._pid_raw:
                raise SecurityError("capture PID publication changed")
            state = capture._published_state
            if state not in {
                "STARTING0",
                "STARTING1",
                "STARTING2",
                "STARTING3",
                "STARTING4",
                "STARTING5",
                "STARTED5ready",
                "STOPPED",
            }:
                raise SecurityError("capture marker state is invalid")
            sequence = 1 + (
                self._capture_last_completed_marker["sequence"]
                if self._capture_last_completed_marker is not None
                else 0
            )
            previous = _sha256(self._marker_bytes)
            lines = (
                "capture_schema=p004-x05-capture-marker-v1",
                "capture_state=" + state,
                "capture_sequence=" + str(sequence),
                "capture_previous_marker_sha256=" + previous,
                "capture_pid_journal_sha256=" + capture._pid_sha256,
                "capture_started_count=" + str(capture._started_count),
                "capture_ready_count=" + str(capture._ready_count),
                "capture_packet_status=" + capture._packet_status,
            )
            payload = self._capture_built_marker_bytes + (
                "\n".join(lines) + "\n"
            ).encode("ascii")
            new_digest = _sha256(payload)
            detail = {
                "status": "INTENT",
                "operation": "capture-marker-successor",
                "resource_ids": [MARKER_ID],
                "capture_state": state,
                "sequence": sequence,
                "old_marker_sha256": previous,
                "new_marker_sha256": new_digest,
                "pid_journal_sha256": capture._pid_sha256,
            }
            self._journal_append("capture-marker-intent", state, detail)
            self._publish("x05-capture-state", "capture-marker-" + state + "-intent", detail)
            old = self._marker_bytes
            _atomic_replace(
                self._config.x05_marker_path,
                expected=old,
                payload=payload,
                uid=self._config.required_uid,
            )
            raw, identity = _read_regular(
                self._config.x05_marker_path,
                maximum=65536,
                mode=0o600,
                uid=self._config.required_uid,
            )
            if raw != payload or not raw.startswith(self._capture_built_marker_bytes):
                raise PostconditionError("capture marker successor readback failed")
            completion = {
                **detail,
                "status": "VERIFIED",
                "operation": "capture-marker-successor-complete",
            }
            self._journal_append("capture-marker-complete", state, completion)
            self._publish(
                "x05-capture-state", "capture-marker-" + state + "-complete", completion
            )
            self._marker_bytes = raw
            self._marker_identity = identity
            accepted = {
                "state": state,
                "sequence": sequence,
                "previous_sha256": previous,
                "sha256": new_digest,
                "pid_journal_sha256": capture._pid_sha256,
            }
            self._capture_last_completed_marker = copy.deepcopy(accepted)
            return accepted

    def _verify_capture_health(self, capture: Any) -> dict[str, Any]:
        with self._consume_lock:
            self._verify_authority()
            self._verify_normal_capture_path()
            self._verify_capture_creator(capture)
            self._verify_capture_contract_current()
            return {
                "schema": "p004-x05-capture-health-v1",
                "status": "PASS",
                "state": capture._published_state,
                "points": list(CAPTURE_POINT_IDS),
            }

    def _bound_stopped_capture_raw(self, capture: Any) -> bytes:
        """Bind current STOPPED bytes to this creator, its slots, and successor."""
        if self._capture_contract is None:
            raise SecurityError("capture session never bound to this builder")
        contract = self._capture_contract
        path = pathlib.Path(contract["pid_journal"]["path"])
        raw, _ = _read_regular(
            path,
            maximum=1024 * 1024,
            mode=0o600,
            uid=self._config.required_uid,
        )
        slots = getattr(capture, "_slots", None)
        fields = contract["pid_journal"]["entry_fields"]
        if not isinstance(slots, dict) or tuple(slots) != CAPTURE_POINT_IDS:
            raise SecurityError("capture creator slot inventory changed")
        try:
            entries = [
                {
                    name: copy.deepcopy(slots[capture_id][name])
                    for name in fields
                }
                for capture_id in CAPTURE_POINT_IDS
            ]
        except (KeyError, TypeError) as exc:
            raise SecurityError("capture creator slot values changed") from exc
        expected = {
            "schema": CAPTURE_PID_SCHEMA,
            "owner": contract["owner"],
            "run_hex": contract["run_hex"],
            "state": "STOPPED",
            "builder_marker_sha256": contract["marker_sha256"],
            "runtime_journal_path": contract["runtime_journal_path"],
            "runtime_journal_sha256": contract["runtime_journal_sha256"],
            "runtime_journal_head_sha256": contract[
                "runtime_journal_head_sha256"
            ],
            "captures": entries,
        }
        digest = _sha256(raw)
        marker = self._capture_last_completed_marker
        marker_payload: bytes | None = None
        marker_base = getattr(self, "_capture_built_marker_bytes", None)
        if isinstance(marker, dict) and isinstance(marker_base, bytes):
            try:
                marker_lines = (
                    "capture_schema=p004-x05-capture-marker-v1",
                    "capture_state=" + marker["state"],
                    "capture_sequence=" + str(marker["sequence"]),
                    "capture_previous_marker_sha256=" + marker["previous_sha256"],
                    "capture_pid_journal_sha256=" + marker["pid_journal_sha256"],
                    "capture_started_count=" + str(capture._started_count),
                    "capture_ready_count=" + str(capture._ready_count),
                    "capture_packet_status=" + capture._packet_status,
                )
                marker_payload = marker_base + (
                    "\n".join(marker_lines) + "\n"
                ).encode("ascii")
            except (KeyError, TypeError, UnicodeError):
                marker_payload = None
        if (
            type(getattr(capture, "_pid_raw", None)) is not bytes
            or raw != capture._pid_raw
            or raw != _canonical(expected)
            or digest != capture._pid_sha256
            or not isinstance(marker, dict)
            or marker.get("state") != "STOPPED"
            or marker.get("pid_journal_sha256") != digest
            or getattr(capture, "_last_marker", None) != marker
            or marker_payload != getattr(self, "_marker_bytes", None)
            or marker.get("sha256") != _sha256(marker_payload or b"")
        ):
            raise SecurityError(
                "capture STOPPED PID publication is not the creator successor"
            )
        return raw

    def _read_stopped_capture_observation(
        self, *, _raw: bytes | None = None
    ) -> dict[str, Any]:
        """Validate the detached STOPPED document without granting authority."""
        if self._capture_contract is None:
            raise SecurityError("capture session never bound to this builder")
        contract = self._capture_contract
        path = pathlib.Path(contract["pid_journal"]["path"])
        if _raw is None:
            raw, _ = _read_regular(
                path,
                maximum=1024 * 1024,
                mode=0o600,
                uid=self._config.required_uid,
            )
        elif type(_raw) is bytes:
            raw = _raw
        else:
            raise SecurityError("capture PID observation bytes are invalid")
        value = self._json(raw, "capture PID journal")
        expected_top = {
            "schema",
            "owner",
            "run_hex",
            "state",
            "builder_marker_sha256",
            "runtime_journal_path",
            "runtime_journal_sha256",
            "runtime_journal_head_sha256",
            "captures",
        }
        if (
            not isinstance(value, dict)
            or set(value) != expected_top
            or _canonical(value) != raw
            or value["schema"] != CAPTURE_PID_SCHEMA
            or value["owner"] != self._owner
            or value["run_hex"] != self._run_hex
            or value["state"] != "STOPPED"
            or value["builder_marker_sha256"] != contract["marker_sha256"]
            or value["runtime_journal_path"] != contract["runtime_journal_path"]
            or value["runtime_journal_sha256"] != contract["runtime_journal_sha256"]
            or value["runtime_journal_head_sha256"]
            != contract["runtime_journal_head_sha256"]
            or not isinstance(value["captures"], list)
        ):
            raise SecurityError("capture PID journal binding is malformed")
        expected_fields = set(contract["pid_journal"]["entry_fields"])
        points = {point["id"]: point for point in contract["points"]}
        checked: list[dict[str, Any]] = []
        for entry in value["captures"]:
            if not isinstance(entry, dict) or set(entry) != expected_fields:
                raise SecurityError("capture PID entry is malformed")
            capture_id = entry.get("id")
            pid = entry.get("pid")
            start_ticks = entry.get("start_ticks")
            argv = entry.get("argv")
            times = (
                entry.get("started_at_ns"),
                entry.get("stop_intent_at_ns"),
                entry.get("reaped_at_ns"),
            )
            common_invalid = (
                capture_id not in points
                or not isinstance(argv, list)
                or not argv
                or any(not isinstance(item, str) or not item for item in argv)
                or entry.get("argv_sha256") != self._command_digest(argv)
                or entry.get("target_sha256") != points[capture_id]["target_sha256"]
                or type(times[1]) is not int
                or times[1] <= 0
            )
            created_invalid = (
                type(pid) is not int
                or pid <= 0
                or type(start_ticks) is not int
                or start_ticks <= 0
                or type(times[0]) is not int
                or times[0] <= 0
                or type(times[2]) is not int
                or times[2] <= 0
                or not (times[0] <= times[1] <= times[2])
                or type(entry.get("wait_returncode")) is not int
                or entry.get("reaped") is not True
            )
            never_created_invalid = (
                any(value is not None for value in (pid, start_ticks, times[0], times[2]))
                or entry.get("wait_returncode") is not None
                or entry.get("reaped") is not False
            )
            created = pid is not None
            if common_invalid or (created and created_invalid) or (
                not created and never_created_invalid
            ):
                raise SecurityError("capture PID stopped proof is invalid")
            current_identity_absent = True
            if created:
                retained = next(
                    (
                        handle
                        for handle in getattr(self._capture_session, "_handles", ())
                        if handle.capture_id == capture_id
                    ),
                    None,
                )
                if (
                    retained is not None
                    and retained.process.pid == pid
                    and retained.start_ticks == start_ticks
                    and retained.process.returncode is not None
                ):
                    current_identity_absent = True
                else:
                    probe = self._read_command(
                        "capture-pid-absence-" + capture_id,
                        ("cat", f"/proc/{pid}/stat"),
                        allowed_rc=frozenset({0, 1}),
                    )
                    if probe.returncode == 0:
                        current_start = self._process_start_ticks(
                            probe.stdout, "capture PID " + capture_id
                        )
                        if current_start == start_ticks:
                            raise SecurityError("captured tcpdump process is still running")
            checked.append(
                {
                    "id": capture_id,
                    "pid": pid,
                    "start_ticks": start_ticks,
                    "current_identity_absent": current_identity_absent,
                    "reaped": entry["reaped"],
                }
            )
        if tuple(sorted(item["id"] for item in checked)) != tuple(
            sorted(CAPTURE_POINT_IDS)
        ) or len(checked) != len(CAPTURE_POINT_IDS):
            raise SecurityError("capture PID journal does not cover exactly five points")
        return {
            "schema": CAPTURE_PID_SCHEMA,
            "path": str(path),
            "sha256": _sha256(raw),
            "state": "STOPPED",
            "captures": sorted(checked, key=lambda item: item["id"]),
        }

    def _verify_stopped_captures(self) -> dict[str, Any]:
        """Require the exact same stopped creator and all retained originals."""
        if self._capture_session is None:
            raise NotReady(
                "creator-owned CaptureSession is required before compensation"
            )
        capture = self._capture_session
        module = self._verify_capture_creator(capture)
        if (
            capture._state != "STOPPED"
            or capture._published_state != "STOPPED"
            or capture._publication_unknown
            or capture._ownership_status != "PASS"
            or self._capture_last_completed_marker is None
            or self._capture_last_completed_marker.get("state") != "STOPPED"
            or self._capture_last_completed_marker.get("sha256")
            != _sha256(self._marker_bytes or b"")
        ):
            raise SecurityError("capture creator is not durably STOPPED")
        stopped_raw = self._bound_stopped_capture_raw(capture)
        observation = self._read_stopped_capture_observation(_raw=stopped_raw)
        fields = self._capture_contract["pid_journal"]["entry_fields"]
        entries = {
            capture_id: {
                name: copy.deepcopy(capture._slots[capture_id][name])
                for name in fields
            }
            for capture_id in CAPTURE_POINT_IDS
        }
        handles = {handle.capture_id: handle for handle in capture._handles}
        created_ids = tuple(
            key for key, value in entries.items() if value["pid"] is not None
        )
        if (
            set(entries) != set(CAPTURE_POINT_IDS)
            or tuple(handle.capture_id for handle in capture._handles) != created_ids
            or len(handles) != len(capture._handles)
        ):
            raise SecurityError("capture creator handle inventory changed")
        try:
            execution_mntns = os.fstat(capture._execution_mntns_fd)
            current_mntns = pathlib.Path("/proc/self/ns/mnt").stat()
        except OSError as exc:
            raise SecurityError(
                "capture creator execution mount binding changed"
            ) from exc
        if (
            (execution_mntns.st_dev, execution_mntns.st_ino)
            != capture._execution_mntns_identity
            or (current_mntns.st_dev, current_mntns.st_ino)
            != capture._execution_mntns_identity
        ):
            raise SecurityError("capture creator execution mount binding changed")
        for capture_id, handle in handles.items():
            entry = entries[capture_id]
            if type(handle.pidfd) is not int or type(handle.pcap_fd) is not int:
                raise SecurityError("capture creator descriptor inventory is incomplete")
            try:
                pidfd = os.fstat(handle.pidfd)
                pcap = os.fstat(handle.pcap_fd)
            except OSError as exc:
                raise SecurityError("capture creator descriptor was closed or rebound") from exc
            guards: list[tuple[os.stat_result, tuple[int, int]]] = []
            for descriptor, identity, original_identity in (
                (
                    handle.pidfd_guard,
                    handle.pidfd_guard_identity,
                    handle.pidfd_identity,
                ),
                (
                    handle.pcap_guard,
                    handle.pcap_guard_identity,
                    handle.pcap_identity,
                ),
            ):
                if descriptor is None:
                    if identity is not None:
                        raise SecurityError(
                            "capture creator guard inventory changed"
                        )
                    continue
                expected_identity = (
                    identity if identity is not None else original_identity
                )
                if type(descriptor) is not int or expected_identity is None:
                    raise SecurityError("capture creator guard inventory changed")
                try:
                    guards.append((os.fstat(descriptor), expected_identity))
                except OSError as exc:
                    raise SecurityError(
                        "capture creator guard was closed or rebound"
                    ) from exc
            if (
                type(handle.process) is not module._POPEN_CLASS
                or handle.process.pid != entry["pid"]
                or handle.start_ticks != entry["start_ticks"]
                or handle.launch_proof_complete is not True
                or handle.session_id != entry["pid"]
                or handle.process_group_id != entry["pid"]
                or handle.parent_process_group_id is None
                or handle.parent_process_group_id == entry["pid"]
                or handle.process.returncode != entry["wait_returncode"]
                or not isinstance(handle.wait_receipt, dict)
                or handle.wait_receipt.get("pid") != entry["pid"]
                or handle.wait_receipt.get("returncode")
                != entry["wait_returncode"]
                or (pidfd.st_dev, pidfd.st_ino) != handle.pidfd_identity
                or (pcap.st_dev, pcap.st_ino) != handle.pcap_identity
                or any(
                    (current.st_dev, current.st_ino) != identity
                    for current, identity in guards
                )
                or entry["reaped"] is not True
            ):
                raise SecurityError("capture creator originals or waitability changed")
        return {
            "schema": "p004-x05-capture-stop-authority-v1",
            "status": "PASS",
            "state": "STOPPED",
            "ownership_status": "PASS",
            "packet_status": capture._packet_status,
            "observation": observation,
            "last_marker": copy.deepcopy(self._capture_last_completed_marker),
            "captures": [
                {
                    "id": entry["id"],
                    "created": entry["pid"] is not None,
                    "reaped": entry["reaped"],
                }
                for entry in (entries[capture_id] for capture_id in CAPTURE_POINT_IDS)
            ],
        }

    def _wait_generated_vrf(
        self, resource_id: str, target: NamespaceTarget
    ) -> dict[str, Any]:
        deadline = time.monotonic() + max(0.1, self._config.command_timeout)
        attempts = 0
        last_error: BuilderError | None = None
        while attempts < 40 and time.monotonic() < deadline:
            attempts += 1
            try:
                binding = self._observe_generated_vrf(resource_id, target)
                binding["readback_attempts"] = attempts
                self._bindings["generated_vrfs"][resource_id] = copy.deepcopy(binding)
                return binding
            except PostconditionError as exc:
                last_error = exc
                remaining = deadline - time.monotonic()
                if remaining > 0:
                    time.sleep(min(0.1, remaining))
        raise PostconditionError(
            "generated VRF did not converge: " + resource_id
        ) from last_error

    def _configure_client_loopback(
        self, target: NamespaceTarget
    ) -> dict[str, Any]:
        resource_id = CLIENT_CONTAINER_ID

        def postcondition(_result: Any) -> dict[str, Any]:
            link = self._link_read("client-loopback-link", target, "lo")
            addresses = self._address_read("client-loopback-address", target, "lo")
            if "10.0.0.1/32" not in addresses:
                raise PostconditionError("client loopback address changed")
            return {"link": link, "addresses": addresses}

        return self._effect(
            "client-loopback-configure",
            [resource_id],
            self._target_command(
                target,
                "ip",
                "address",
                "add",
                "10.0.0.1/32",
                "dev",
                "lo",
            ),
            postcondition,
            allowed_stderr=frozenset({b""}),
        )

    def build(self) -> dict[str, Any]:
        """Build the reviewed 32-resource base and publish one BUILT marker."""
        with self._operation_scope("build"):
            return self._build()

    def _build(self) -> dict[str, Any]:
        self._verify_authority()
        if self._state != "ADMITTED" or self._journal is not None:
            raise SecurityError("runtime builder is one-shot and already started")
        try:
            self._create_journal_and_marker()
            for name in (
                "ovn-central-az1",
                "ovn-gw-1",
                "ovn-gw-2",
                "ovn-chassis-1",
                "ovn-chassis-2",
            ):
                self._original_target(name)
            self._host_target()
            nb = self._forward_nb()
            generated = {
                "container:ovn-gw-1/ovn-generated-vrf/ovnvrf300": (
                    self._original_target("ovn-gw-1"),
                    "ovnvrf300",
                ),
                "container:ovn-gw-2/ovn-generated-vrf/ovnvrf400": (
                    self._original_target("ovn-gw-2"),
                    "ovnvrf400",
                ),
                "container:ovn-chassis-2/ovn-generated-vrf/ovnvrf-x05-b": (
                    self._original_target("ovn-chassis-2"),
                    "ovnvrf-x05-b",
                ),
            }
            generated_bindings: dict[str, Any] = {}
            for resource_id, (target, expected_name) in generated.items():
                if self._resources[resource_id]["name"] != expected_name:
                    raise SecurityError("generated VRF plan identity changed")
                generated_bindings[resource_id] = self._wait_generated_vrf(
                    resource_id, target
                )

            client = self._create_container(CLIENT_CONTAINER_ID)
            client_target = self._created_target("dci-client-2")
            client_eth1 = self._build_attachment(
                CLIENT_ETH1_ID,
                client_target,
                host_name="x05c2e1",
                container_name="eth1",
                bridge="br-ovn-ext",
                address="169.254.254.2/30",
                tag=300,
                mtu=1500,
            )
            client_eth2 = self._build_attachment(
                CLIENT_ETH2_ID,
                client_target,
                host_name="x05c2e2",
                container_name="eth2",
                bridge="br-ovn-ext",
                address="169.254.254.6/30",
                tag=400,
                mtu=1500,
            )
            client_loopback = self._configure_client_loopback(client_target)

            gateway300 = self._build_gateway_mirror(
                number=300,
                gateway="ovn-gw-1",
                address="169.254.254.1/30",
                expected_mac="02:00:2c:00:00:01",
            )
            gateway400 = self._build_gateway_mirror(
                number=400,
                gateway="ovn-gw-2",
                address="169.254.254.5/30",
                expected_mac="02:00:90:00:00:01",
            )
            sentinel_a = self._build_sentinel(
                chassis="ovn-chassis-1",
                suffix="a",
                mac="02:00:00:10:00:11",
                address="192.168.100.11/24",
            )
            sentinel_b = self._build_sentinel(
                chassis="ovn-chassis-2",
                suffix="b",
                mac="02:00:00:10:00:12",
                address="192.168.100.12/24",
            )
            chassis = self._build_chassis_network()

            peer = self._create_container(PEER_CONTAINER_ID)
            peer_target = self._created_target("dci-x05-peer-2")
            peer_eth1 = self._build_attachment(
                PEER_ETH1_ID,
                peer_target,
                host_name="x05p2e1",
                container_name="eth1",
                bridge="br-ovn",
                address="170.168.0.8/16",
                tag=None,
                mtu=1500,
            )
            peer_network = self._build_peer_network(peer_target)
            external_ids = self._change_external_ids(inverse=False)

            gateway_frr300_id = (
                "container:ovn-gw-1/frr-config-delta//etc/frr/frr.conf:ovnvrf300"
            )
            gateway_frr400_id = (
                "container:ovn-gw-2/frr-config-delta//etc/frr/frr.conf:ovnvrf400"
            )
            gateway_frr300 = self._apply_gateway_frr(
                gateway_frr300_id,
                self._original_target("ovn-gw-1"),
                vrf="ovnvrf300",
                neighbor="169.254.254.2",
            )
            gateway_frr400 = self._apply_gateway_frr(
                gateway_frr400_id,
                self._original_target("ovn-gw-2"),
                vrf="ovnvrf400",
                neighbor="169.254.254.6",
            )
            client_frr = self._start_frr(
                CLIENT_CONTAINER_ID,
                client_target,
                fixture_key="frr_fixture",
                mode="client",
            )
            chassis_frr_id = "container:ovn-chassis-2/frr-pathspace/x05"
            chassis_frr = self._start_frr(
                chassis_frr_id,
                self._original_target("ovn-chassis-2"),
                fixture_key="fixture",
                mode="pathspace",
            )
            peer_frr_id = "container:dci-x05-peer-2/frr-pathspace/x05"
            peer_frr = self._start_frr(
                peer_frr_id,
                peer_target,
                fixture_key="fixture",
                mode="pathspace",
            )

            verified = self._verify_complete_runtime()
            self._completed_ids = set(verified["mutable_ids"])
            assert self._journal is not None
            self._journal.verify()
            built_marker = self._publish_built_marker()
            assert self._journal is not None and self._marker_bytes is not None
            self._journal.verify()
            self._built_bindings = copy.deepcopy(self._bindings)
            self._built_result = {
                "schema": SCHEMA,
                "status": "PASS",
                "state": "BUILT",
                "owner": self._owner,
                "run_hex": self._run_hex,
                "inventory": {
                    "total": 43,
                    "mutable_base": 32,
                    "marker": 1,
                    "generated_observation_only": 3,
                    "lsp_parent_control": 1,
                    "capture": 6,
                },
                "completed_resource_ids": sorted(self._completed_ids),
                "generated_resource_ids": sorted(generated_bindings),
                "nb": nb,
                "marker": built_marker,
                "marker_sha256": _sha256(self._marker_bytes),
                "journal": self._journal.binding(),
                "bindings": {
                    "client": {
                        "container": client,
                        "eth1": client_eth1,
                        "eth2": client_eth2,
                        "loopback": client_loopback,
                        "frr": client_frr,
                    },
                    "gateways": {
                        "300": {"network": gateway300, "frr": gateway_frr300},
                        "400": {"network": gateway400, "frr": gateway_frr400},
                    },
                    "sentinels": {"a": sentinel_a, "b": sentinel_b},
                    "chassis": {
                        "network": chassis,
                        "external_ids": external_ids,
                        "frr": chassis_frr,
                    },
                    "peer": {
                        "container": peer,
                        "eth1": peer_eth1,
                        "network": peer_network,
                        "frr": peer_frr,
                    },
                    "generated_vrfs": copy.deepcopy(generated_bindings),
                    "b_restore": copy.deepcopy(self._bindings["b_restore"]),
                },
            }
            return copy.deepcopy(self._built_result)
        except BaseException:
            if self._journal is not None:
                self._state = "FAILED"
                self._unknown = True
            raise

    def _ovs_identity_absent(
        self,
        stage: str,
        *,
        container_id: str | None,
        table: str,
        row_uuid: str,
        name: str,
    ) -> dict[str, Any]:
        command = (
            *self._ovs_prefix(container_id, "ovs-vsctl"),
            "--format=json",
            "--data=json",
            "--columns=_uuid,name",
            "find",
            table,
            "_uuid=" + row_uuid,
        )
        rows = self._ovs_rows(
            self._read_command(stage + "-uuid", command).stdout,
            stage + " UUID",
        )
        name_rows = self._ovs_find(
            stage + "-name",
            container_id=container_id,
            table=table,
            columns=("_uuid", "name"),
            name=name,
        )
        if rows or name_rows:
            raise PostconditionError(stage + " OVS identity remains")
        return {"table": table, "uuid": row_uuid, "name": name, "absent": True}

    def _wait_generated_absent(
        self, resource_id: str, target: NamespaceTarget
    ) -> dict[str, Any]:
        name = self._resources[resource_id]["name"]
        deadline = time.monotonic() + max(0.1, self._config.command_timeout)
        attempts = 0
        while attempts < 40 and time.monotonic() < deadline:
            attempts += 1
            if self._link_absent(
                "generated-vrf-absent-" + name + "-" + str(attempts),
                target,
                name,
            ):
                return {
                    "resource_id": resource_id,
                    "name": name,
                    "absent": True,
                    "observation_only": True,
                    "direct_delete": False,
                    "attempts": attempts,
                }
            remaining = deadline - time.monotonic()
            if remaining > 0:
                time.sleep(min(0.1, remaining))
        raise PostconditionError("generated VRF remains after NB inverse: " + name)

    def _runtime_absence_readback(self) -> dict[str, Any]:
        if self._built_bindings is None:
            raise SecurityError("final absence lacks frozen BUILT bindings")
        frozen = self._built_bindings
        containers: list[dict[str, Any]] = []
        for name, binding in sorted(frozen["containers"].items()):
            if not self._container_absent(
                "final-container-" + name, name, binding["id"]
            ):
                raise PostconditionError("created container remains: " + name)
            containers.append({"name": name, "id": binding["id"], "absent": True})

        ovs_rows: list[dict[str, Any]] = []
        for resource_id, binding in sorted(frozen["ovs"].items()):
            ovs_rows.append(
                {
                    "resource_id": resource_id,
                    "port": self._ovs_identity_absent(
                        "final-ovs-port-" + binding["port_name"],
                        container_id=binding["container_id"],
                        table="Port",
                        row_uuid=binding["port_uuid"],
                        name=binding["port_name"],
                    ),
                    "interface": self._ovs_identity_absent(
                        "final-ovs-interface-" + binding["port_name"],
                        container_id=binding["container_id"],
                        table="Interface",
                        row_uuid=binding["interface_uuid"],
                        name=binding["port_name"],
                    ),
                }
            )

        links: list[dict[str, Any]] = []
        for resource_id, binding in sorted(frozen["links"].items()):
            originals = binding.get("pair") if isinstance(binding.get("pair"), list) else [binding]
            for row in originals:
                target_data = row.get("target")
                label = target_data.get("label") if isinstance(target_data, dict) else None
                if label in {"dci-client-2", "dci-x05-peer-2"}:
                    links.append(
                        {
                            "resource_id": resource_id,
                            "name": row.get("name"),
                            "parent_container_absent": True,
                        }
                    )
                    continue
                target = self._targets.get(label)
                if target is None or target.detached() != target_data:
                    raise SecurityError("final link target identity changed")
                namespace = row.get("namespace")
                if namespace is not None:
                    # The captured named namespace is proved absent separately;
                    # no name-based delete or namespace recreation is allowed.
                    links.append(
                        {
                            "resource_id": resource_id,
                            "name": row.get("name"),
                            "namespace": namespace,
                            "parent_namespace_absent": True,
                        }
                    )
                else:
                    if not self._link_absent(
                        "final-link-" + str(row.get("name")),
                        target,
                        row["name"],
                    ):
                        raise PostconditionError(
                            "owned Linux link remains: " + str(row.get("name"))
                        )
                    links.append(
                        {
                            "resource_id": resource_id,
                            "name": row["name"],
                            "ifindex": row["ifindex"],
                            "absent": True,
                        }
                    )

        namespaces: list[dict[str, Any]] = []
        for resource_id, binding in sorted(frozen["namespaces"].items()):
            target = self._targets.get(binding["target"]["label"])
            if target is None:
                raise SecurityError("final namespace target identity changed")
            assert target.container_id is not None
            probe = self._read_command(
                "final-netns-" + binding["name"],
                (
                    "docker",
                    "exec",
                    target.container_id,
                    "stat",
                    "-Lc",
                    "%i",
                    "/var/run/netns/" + binding["name"],
                ),
                allowed_rc=frozenset({0, 1}),
            )
            if probe.returncode == 0 or probe.stdout:
                raise PostconditionError("owned namespace remains: " + binding["name"])
            namespaces.append(
                {
                    "resource_id": resource_id,
                    "name": binding["name"],
                    "inode": binding["inode"],
                    "absent": True,
                }
            )

        frr: list[dict[str, Any]] = []
        for resource_id, binding in sorted(frozen["frr"].items()):
            target_data = binding["target"]
            label = target_data["label"]
            if label in {"dci-client-2", "dci-x05-peer-2"}:
                frr.append(
                    {"resource_id": resource_id, "parent_container_absent": True}
                )
                continue
            target = self._targets.get(label)
            if target is None or target.detached() != target_data:
                raise SecurityError("final FRR target identity changed")
            if binding["mode"] == "gateway-delta":
                baseline = self._gateway_baseline(
                    "final-gateway-baseline-" + label, resource_id, target
                )
                if (
                    baseline["canonical"] != binding["baseline"]["canonical"]
                    or baseline["running"] != binding["baseline"]["running"]
                ):
                    raise PostconditionError("gateway FRR baseline changed after cleanup")
                frr.append({"resource_id": resource_id, "baseline": baseline})
            else:
                remaining = self._read_frr_processes(
                    "final-frr-processes-" + label,
                    target,
                    space="x05",
                    mode="pathspace",
                    expected_daemons=None,
                )
                if remaining:
                    raise PostconditionError("X05 FRR processes remain: " + label)
                probe = self._read_command(
                    "final-frr-paths-" + label,
                    self._container_command(
                        target,
                        "sh",
                        "-ceu",
                        "test ! -e /etc/frr/x05 && test ! -e /run/frr/x05",
                    ),
                )
                if probe.stdout or probe.stderr:
                    raise PostconditionError("X05 FRR absence emitted output")
                frr.append({"resource_id": resource_id, "absent": True})

        external = frozen["ovs_external_ids"]
        if not isinstance(external, dict):
            raise SecurityError("frozen external-id binding is missing")
        external_target = self._targets.get(external["target"]["label"])
        if external_target is None:
            raise SecurityError("external-id target identity changed")
        external_current = self._read_openvswitch_map(
            "final-external-ids", external_target
        )
        if external_current != {
            "uuid": external["uuid"],
            "external_ids": external["original"],
        }:
            raise PostconditionError("Open_vSwitch full map was not restored")

        return {
            "containers": containers,
            "ovs": ovs_rows,
            "links": links,
            "namespaces": namespaces,
            "frr": frr,
            "external_ids": external_current,
        }

    def _immutable_baseline_readback(self) -> dict[str, Any]:
        collector = self._session.collector
        collector.clear_cache()
        sections = self._context["snapshot"]["sections"]
        dci = collector.dci_section()
        m03 = collector.m03_section(self._profile_owner)
        gateways = collector.gateway_frr_section()
        chassis2 = collector.chassis2_section()
        images = collector.image_ids()
        expected = {
            "dci": sections["dci"],
            "m03": sections["m03"],
            "gateway_frr": sections["gateway_frr"],
            "chassis2": sections["chassis2"],
            "resolved_images": self._anchors["resolved_images"],
        }
        actual = {
            "dci": dci,
            "m03": m03,
            "gateway_frr": gateways,
            "chassis2": chassis2,
            "resolved_images": images,
        }
        if actual != expected:
            raise PostconditionError("M03/DCI immutable baseline changed")
        return {
            key: _sha256(_canonical(value)) for key, value in sorted(actual.items())
        }

    def _final_absence_check(self) -> dict[str, Any]:
        self._verify_authority()
        if self._state not in {"COMPENSATING", "COMPENSATED"}:
            raise SecurityError("final absence requires completed compensation steps")
        if self._marker_bytes is None or self._journal is None:
            raise SecurityError("final absence lacks the retained BUILT marker")
        raw, _ = _read_regular(
            self._config.x05_marker_path,
            maximum=65536,
            mode=0o600,
            uid=self._config.required_uid,
        )
        if raw != self._marker_bytes:
            raise SecurityError("retained BUILT marker changed")
        marker = self._verify_marker_payload(raw, "BUILT")
        captures = self._capture_stop_call()
        runtime = self._runtime_absence_readback()
        generated: list[dict[str, Any]] = []
        assert self._built_bindings is not None
        for resource_id, binding in sorted(
            self._built_bindings["generated_vrfs"].items()
        ):
            target = self._targets.get(binding["target"]["label"])
            if target is None:
                raise SecurityError("generated VRF target identity changed")
            generated.append(self._wait_generated_absent(resource_id, target))
        inverse = self._bindings["nb"].get("inverse")
        if not isinstance(inverse, dict) or inverse != self._nb_artifact_binding(
            state="inverse"
        ):
            raise SecurityError("guarded NB inverse artifact binding changed")
        immutable = self._immutable_baseline_readback()
        return {
            "schema": "p004-x05-runtime-final-absence-v1",
            "status": "PASS",
            "owner": self._owner,
            "run_hex": self._run_hex,
            "marker_retained": marker,
            "captures": captures,
            "runtime": runtime,
            "generated_vrfs": generated,
            "nb_inverse": copy.deepcopy(inverse),
            "immutable_baseline_sha256": immutable,
            "marker_removal_authorized": False,
            "producer_close_authorized": False,
        }

    def compensate(self) -> dict[str, Any]:
        """Remove only captured owned runtime state, retaining marker and producer."""
        with self._operation_scope("compensate"):
            return self._compensate()

    def _compensate(self) -> dict[str, Any]:
        self._verify_authority()
        if self._state != "BUILT" or self._unknown or self._built_bindings is None:
            raise SecurityError("compensation requires this builder's verified BUILT state")
        # Both coordinator-owned prerequisites are direct fresh checks and run
        # before the first compensation effect.
        capture_stop = self._capture_stop_call()
        b_restore = self._read_b_restore("compensation-b-restore-precondition")
        if b_restore != self._bindings.get("b_restore"):
            raise SecurityError("B LSP parent/SB datapath was not exactly restored")
        self._state = "COMPENSATING"
        operations: list[dict[str, Any]] = []

        def done(stage: str, value: Any) -> None:
            operations.append({"stage": stage, "readback": copy.deepcopy(value)})

        try:
            for resource_id in (
                "container:ovn-gw-1/frr-config-delta//etc/frr/frr.conf:ovnvrf300",
                "container:ovn-gw-2/frr-config-delta//etc/frr/frr.conf:ovnvrf400",
            ):
                done("gateway-frr-withdraw", self._remove_gateway_frr(resource_id))
            for resource_id in (
                CLIENT_CONTAINER_ID,
                "container:ovn-chassis-2/frr-pathspace/x05",
                "container:dci-x05-peer-2/frr-pathspace/x05",
            ):
                done("frr-stop", self._stop_frr(resource_id))

            for chassis, suffix in (
                ("ovn-chassis-1", "a"),
                ("ovn-chassis-2", "b"),
            ):
                namespace = "x05-tenant-" + suffix + "-vm"
                outer = "x05-tenant-" + suffix + "-p"
                inner = "x05-tenant-" + suffix
                ovs_id = f"container:{chassis}/ovs-port-interface/{outer}"
                outer_id = f"container:{chassis}/linux-veth/{outer}"
                inner_id = f"netns:{chassis}:{namespace}/linux-veth/{inner}"
                namespace_id = f"container:{chassis}/netns/{namespace}"
                done("sentinel-ovs-remove", self._remove_ovs_port("sentinel-ovs-remove-" + suffix, ovs_id))
                done("sentinel-veth-remove", self._delete_veth_pair(outer_id, inner_id))
                done("sentinel-netns-remove", self._delete_netns(namespace_id))

            for resource_id in (CLIENT_ETH1_ID, CLIENT_ETH2_ID, PEER_ETH1_ID):
                done("host-ovs-remove", self._remove_ovs_port("host-ovs-remove-" + self._resources[resource_id]["name"], resource_id))
            for resource_id in (CLIENT_ETH1_ID, CLIENT_ETH2_ID, PEER_ETH1_ID):
                done("attachment-remove", self._delete_attachment(resource_id))
            done("client-container-remove", self._remove_container(CLIENT_CONTAINER_ID))

            for resource_id in (
                "container:dci-x05-peer-2/linux-dummy/evpn-x05-pr",
                "container:dci-x05-peer-2/linux-vxlan/vxlan-x05-pr",
                "container:dci-x05-peer-2/linux-bridge/br-x05-peer",
                "container:dci-x05-peer-2/linux-vrf/vrf-x05-peer",
            ):
                done("peer-link-remove", self._delete_single_link(resource_id))
            done("peer-container-remove", self._remove_container(PEER_CONTAINER_ID))

            for gateway, number in (("ovn-gw-1", 300), ("ovn-gw-2", 400)):
                outer_name = f"bgpvrf{number}-ovs"
                inner_name = f"bgpvrf{number}"
                ovs_id = f"container:{gateway}/ovs-port-interface/{outer_name}"
                outer_id = f"container:{gateway}/linux-veth/{outer_name}"
                inner_id = f"container:{gateway}/linux-veth/{inner_name}"
                done("gateway-ovs-remove", self._remove_ovs_port("gateway-ovs-remove-" + str(number), ovs_id))
                done("gateway-veth-remove", self._delete_veth_pair(outer_id, inner_id))

            for resource_id in (
                "container:ovn-chassis-2/linux-dummy/evpn-x05-b",
                "container:ovn-chassis-2/linux-vxlan/vxlan-x05-b",
                "container:ovn-chassis-2/linux-bridge/br-x05-b",
            ):
                done("chassis-link-remove", self._delete_single_link(resource_id))
            done("external-ids-inverse", self._change_external_ids(inverse=True))
            done("nb-inverse", self._inverse_nb())
            for resource_id, binding in sorted(
                self._built_bindings["generated_vrfs"].items()
            ):
                target = self._targets[binding["target"]["label"]]
                done("generated-vrf-absence", self._wait_generated_absent(resource_id, target))

            final = self._final_absence_check()
            self._state = "COMPENSATED"
            assert self._journal is not None
            self._cleanup_result = {
                "schema": SCHEMA,
                "status": "PASS",
                "state": "COMPENSATED",
                "owner": self._owner,
                "run_hex": self._run_hex,
                "capture_stop": capture_stop,
                "b_restore": b_restore,
                "operations": operations,
                "final_absence": final,
                "journal": self._journal.binding(),
                "marker_retained": True,
                "producer_open": True,
            }
            self._final_absence = copy.deepcopy(final)
            return copy.deepcopy(self._cleanup_result)
        except BaseException:
            self._state = "CLEANUP_FAILED"
            self._unknown = True
            raise

    def verify_final_absence(self) -> dict[str, Any]:
        """Repeat the direct absence proof without removing marker or closing G0."""
        with self._operation_scope("verify-final-absence"):
            return self._verify_final_absence()

    def _verify_final_absence(self) -> dict[str, Any]:
        self._verify_authority()
        if self._state != "COMPENSATED" or self._cleanup_result is None:
            raise SecurityError("final absence is unavailable before compensation")
        checked = self._final_absence_check()
        self._final_absence = copy.deepcopy(checked)
        return copy.deepcopy(checked)

    def _terminal_fault(self, stage: str) -> None:
        if self._config.test_only_paths and _TEST_TERMINAL_FAULT == stage:
            raise AmbiguousEffect("synthetic terminal cleanup boundary: " + stage)

    def _verify_retained_capture_map(self, capture: Any) -> dict[str, Any]:
        retained = getattr(capture, "_retained_locations", None)
        if (
            not isinstance(retained, dict)
            or retained.get("status") != "VERIFIED"
            or not isinstance(retained.get("directory"), str)
            or not isinstance(retained.get("files"), list)
            or len(retained["files"]) != len(CAPTURE_POINT_IDS) + 1
        ):
            raise SecurityError("completed capture retention map is unavailable")
        directory = self._config.evidence_path / "completed-captures"
        if retained["directory"] != str(directory):
            raise SecurityError("completed capture retention directory changed")
        info = directory.lstat()
        if (
            stat.S_ISLNK(info.st_mode)
            or not stat.S_ISDIR(info.st_mode)
            or info.st_uid != self._config.required_uid
            or stat.S_IMODE(info.st_mode) != 0o700
        ):
            raise SecurityError("completed capture retention directory is unsafe")
        expected_ids = set(CAPTURE_POINT_IDS) | {"capture-pid-journal"}
        observed_ids: set[str] = set()
        checked: list[dict[str, Any]] = []
        for item in retained["files"]:
            if not isinstance(item, dict):
                raise SecurityError("completed capture retention entry is malformed")
            capture_id = item.get("id")
            expected_name = (
                CAPTURE_PID_NAME
                if capture_id == "capture-pid-journal"
                else str(capture_id) + ".pcap"
            )
            destination = directory / expected_name
            source = self._config.evidence_path / expected_name
            identity = item.get("identity")
            expected_identity_keys = {
                "device",
                "inode",
                "size",
                "mtime_ns",
                "mode",
                "uid",
            }
            if (
                capture_id not in expected_ids
                or capture_id in observed_ids
                or item.get("source_path") != str(source)
                or item.get("destination_path") != str(destination)
                or item.get("location") != "retained"
                or not isinstance(identity, dict)
                or set(identity) != expected_identity_keys
                or any(type(value) is not int for value in identity.values())
                or not isinstance(item.get("sha256"), str)
                or HEX64_RE.fullmatch(item["sha256"]) is None
                or source.exists()
                or source.is_symlink()
            ):
                raise SecurityError("completed capture retention entry changed")
            maximum = (
                1024 * 1024
                if capture_id == "capture-pid-journal"
                else 256 * 1024 * 1024
            )
            raw, current = _read_regular(
                destination,
                maximum=maximum,
                mode=0o600,
                uid=self._config.required_uid,
            )
            current_identity = {
                "device": current[0],
                "inode": current[1],
                "size": current[2],
                "mtime_ns": current[3],
                "mode": current[5],
                "uid": current[6],
            }
            if current_identity != identity or _sha256(raw) != item["sha256"]:
                raise SecurityError("completed capture retention bytes changed")
            observed_ids.add(capture_id)
            checked.append(
                {
                    "id": capture_id,
                    "path": str(destination),
                    "sha256": item["sha256"],
                    "identity": copy.deepcopy(identity),
                }
            )
        if observed_ids != expected_ids:
            raise SecurityError("completed capture retention inventory changed")
        return {
            "directory": str(directory),
            "status": "VERIFIED",
            "files": sorted(checked, key=lambda item: item["id"]),
        }

    def _finalize_x05_cleanup(self) -> dict[str, Any]:
        """Release retained evidence and remove only this builder's final marker."""
        marker_unlinked = False
        marker_parent_fd: int | None = None
        with self._consume_lock:
            try:
                self._verify_authority()
                if (
                    self._state != "COMPENSATED"
                    or self._unknown
                    or self._terminal_result is not None
                    or not isinstance(self._cleanup_result, dict)
                    or self._cleanup_result.get("status") != "PASS"
                    or not isinstance(self._final_absence, dict)
                    or self._final_absence.get("status") != "PASS"
                ):
                    raise SecurityError(
                        "terminal cleanup requires exact successful compensation"
                    )
                capture = self._capture_session
                module = self._verify_capture_creator(capture)
                stopped = self._verify_stopped_captures()
                if (
                    stopped.get("status") != "PASS"
                    or stopped.get("state") != "STOPPED"
                    or stopped.get("ownership_status") != "PASS"
                    or stopped.get("packet_status") != "PASS"
                    or self._capture_last_completed_marker is None
                    or self._capture_last_completed_marker.get("state") != "STOPPED"
                    or self._capture_last_completed_marker.get("sha256")
                    != _sha256(self._marker_bytes or b"")
                ):
                    raise SecurityError("terminal cleanup lacks exact STOPPED capture proof")
                direct_absence = self._verify_final_absence()
                m03_before = _COLLECTOR_OWNED_M03_IDENTITY(
                    self._collector, self._profile_owner
                )
                m03_digest = (
                    RUNTIME._digest(m03_before)
                    if isinstance(m03_before, dict)
                    else None
                )
                if (
                    m03_digest is None
                    or m03_digest != self._session._m03_ownership_sha256
                ):
                    raise SecurityError("owned M03 identity changed before terminal cleanup")

                verify_argv = (
                    str(self._config.labctl_path),
                    "dci",
                    "verify",
                    "--m03",
                )
                verify_intent = {
                    "status": "INTENT",
                    "operation": "owned-m03-verify",
                    "resource_ids": [MARKER_ID],
                    "command_sha256": self._command_digest(verify_argv),
                }
                self._journal_append(
                    "terminal-intent", "g7-owned-m03-verify", verify_intent
                )
                self._publish(
                    "x05-terminal-m03",
                    "g7-owned-m03-verify-intent",
                    verify_intent,
                )
                self._terminal_fault("before-m03-verify")
                try:
                    verified = self._checked_result(
                        self._session_labctl_call("verify", m03=True),
                        verify_argv,
                    )
                except BaseException as exc:
                    unknown = {
                        **verify_intent,
                        "status": "UNKNOWN",
                        "operation": "owned-m03-verify-outcome",
                        "error": type(exc).__name__ + ":" + str(exc),
                    }
                    self._journal_append(
                        "terminal-outcome", "g7-owned-m03-verify", unknown
                    )
                    with contextlib.suppress(Exception):
                        self._publish(
                            "x05-terminal-m03",
                            "g7-owned-m03-verify-outcome",
                            unknown,
                        )
                    raise
                verify_outcome = {
                    **verify_intent,
                    "status": "PASS" if verified.returncode == 0 else "FAIL",
                    "operation": "owned-m03-verify-outcome",
                    "returncode": verified.returncode,
                    "stdout_sha256": _sha256(verified.stdout),
                    "stderr_sha256": _sha256(verified.stderr),
                }
                self._journal_append(
                    "terminal-outcome", "g7-owned-m03-verify", verify_outcome
                )
                self._publish(
                    "x05-terminal-m03",
                    "g7-owned-m03-verify-outcome",
                    verify_outcome,
                )
                if verified.returncode != 0:
                    raise PostconditionError("owned M03 verification failed")
                m03_after = _COLLECTOR_OWNED_M03_IDENTITY(
                    self._collector, self._profile_owner
                )
                if m03_after != m03_before:
                    raise SecurityError("owned M03 identity changed across verification")

                self._terminal_fault("before-capture-release")
                release = module._CAPTURE_SESSION_RELEASE(capture)
                if (
                    release != {"status": "PASS", "released": True}
                    or capture._released is not True
                    or capture._retention_complete is not True
                    or capture._retention_unknown is not False
                ):
                    raise SecurityError("capture evidence release did not complete")
                retained = self._verify_retained_capture_map(capture)
                self._verify_object_bindings()
                self._verify_sources()
                _SESSION_VERIFY_EXECUTION(self._session, self._prepared)
                self._journal.verify_current()
                raw, identity = _read_regular(
                    self._config.x05_marker_path,
                    maximum=65536,
                    mode=0o600,
                    uid=self._config.required_uid,
                )
                if raw != self._marker_bytes or identity != self._marker_identity:
                    raise SecurityError("terminal X05 marker changed before removal")
                completed = self._capture_last_completed_marker
                if (
                    not isinstance(completed, dict)
                    or completed.get("state") != "STOPPED"
                    or completed.get("sha256") != _sha256(raw)
                    or completed != capture._last_marker
                ):
                    raise SecurityError("terminal capture marker successor changed")

                archive_sha256 = RUNTIME._digest(retained)
                remove_intent = {
                    "status": "INTENT",
                    "operation": "x05-marker-remove",
                    "resource_ids": [MARKER_ID],
                    "marker_sha256": _sha256(raw),
                    "capture_archive_sha256": archive_sha256,
                }
                self._journal_append(
                    "terminal-intent", "x05-cleaned-marker-remove", remove_intent
                )
                self._publish(
                    "x05-terminal-cleanup",
                    "x05-cleaned-marker-remove-intent",
                    remove_intent,
                )
                self._terminal_fault("before-marker-unlink")
                parent = self._config.x05_marker_path.parent
                flags = (
                    os.O_RDONLY
                    | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_CLOEXEC", 0)
                    | getattr(os, "O_NOFOLLOW", 0)
                )
                marker_parent_fd = os.open(parent, flags)
                parent_info = os.fstat(marker_parent_fd)
                parent_identity = (
                    parent_info.st_dev,
                    parent_info.st_ino,
                    parent_info.st_mode,
                    parent_info.st_uid,
                )
                marker_info = os.stat(
                    self._config.x05_marker_path.name,
                    dir_fd=marker_parent_fd,
                    follow_symlinks=False,
                )
                if (
                    parent_identity != self._marker_directory_identity
                    or _identity(marker_info) != self._marker_identity
                ):
                    raise SecurityError("terminal marker parent or inode changed")
                os.unlink(
                    self._config.x05_marker_path.name,
                    dir_fd=marker_parent_fd,
                )
                marker_unlinked = True
                self._terminal_fault("after-marker-unlink")
                os.fsync(marker_parent_fd)
                self._terminal_fault("after-marker-fsync")
                try:
                    os.stat(
                        self._config.x05_marker_path.name,
                        dir_fd=marker_parent_fd,
                        follow_symlinks=False,
                    )
                except FileNotFoundError:
                    pass
                else:
                    raise SecurityError("terminal X05 marker remains after unlink")
                self._terminal_fault("before-terminal-completion")
                completion = {
                    **remove_intent,
                    "status": "VERIFIED",
                    "operation": "x05-marker-remove-complete",
                    "state": "X05_CLEANED",
                }
                self._journal_append(
                    "terminal-complete", "x05-cleaned", completion
                )
                self._publish(
                    "x05-terminal-cleanup", "x05-cleaned-complete", completion
                )
                self._verify_object_bindings()
                self._verify_sources()
                _SESSION_VERIFY_EXECUTION(self._session, self._prepared)
                self._journal.verify_current()
                if self._config.x05_marker_path.exists() or self._config.x05_marker_path.is_symlink():
                    raise SecurityError("terminal X05 marker absence changed")
                if _COLLECTOR_OWNED_M03_IDENTITY(
                    self._collector, self._profile_owner
                ) != m03_before:
                    raise SecurityError("owned M03 identity changed at terminal exit")
                self._state = "X05_CLEANED"
                self._terminal_result = {
                    "schema": "p004-x05-terminal-cleanup-v1",
                    "status": "PASS",
                    "state": "X05_CLEANED",
                    "owner": self._owner,
                    "run_hex": self._run_hex,
                    "direct_absence": copy.deepcopy(direct_absence),
                    "m03_identity_sha256": m03_digest,
                    "marker_sha256": _sha256(raw),
                    "capture_archive": copy.deepcopy(retained),
                    "capture_archive_sha256": archive_sha256,
                    "journal": self._journal.binding(),
                    "marker_absent": True,
                    "producer_open": True,
                }
                return copy.deepcopy(self._terminal_result)
            except BaseException:
                self._unknown = True
                self._state = (
                    "TERMINAL_UNKNOWN" if marker_unlinked else "CLEANUP_FAILED"
                )
                raise
            finally:
                if marker_parent_fd is not None:
                    with contextlib.suppress(OSError):
                        os.close(marker_parent_fd)


_RUNTIME_BUILDER_CAPTURE_STOP = RuntimeBuilder._verify_stopped_captures
_RUNTIME_BUILDER_CAPTURE_ATTACH = RuntimeBuilder._attach_capture_session
_RUNTIME_BUILDER_CAPTURE_SPAWN_INTENT = RuntimeBuilder._record_capture_spawn_intent
_RUNTIME_BUILDER_CAPTURE_PROGRESS = RuntimeBuilder._record_capture_progress
_RUNTIME_BUILDER_CAPTURE_HEALTH = RuntimeBuilder._verify_capture_health
_RUNTIME_BUILDER_TERMINAL_FINALIZE = RuntimeBuilder._finalize_x05_cleanup


def _dry_description() -> dict[str, Any]:
    return {
        "schema": "p004-x05-runtime-apply-dry-run-v1",
        "status": "DRY_RUN",
        "live_enabled": False,
        "inventory": {
            "total": 43,
            "mutable_base": 32,
            "marker": 1,
            "generated_observation_only": 3,
            "lsp_parent_control": 1,
            "capture": 6,
        },
        "public_api": [
            "RuntimeBuilder.from_admission(prepared)",
            "RuntimeBuilder.build()",
            "RuntimeBuilder.capture_bindings()",
            "RuntimeBuilder.compensate()",
            "RuntimeBuilder.verify_final_absence()",
        ],
        "capture_pid_schema": CAPTURE_PID_SCHEMA,
        "capture_points": list(CAPTURE_POINT_IDS),
        "marker_removal": "coordinator-only",
        "producer_close": "coordinator-only",
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Reviewed X05 runtime builder library (live CLI disabled)."
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--execute", action="store_true")
    arguments = parser.parse_args(argv)
    if arguments.execute:
        print(
            json.dumps(
                {
                    "schema": "p004-x05-runtime-apply-cli-v1",
                    "status": "NOT_READY",
                    "reason": "live execution is available only through the consumed library capability",
                },
                sort_keys=True,
                separators=(",", ":"),
            )
        )
        return 75
    print(json.dumps(_dry_description(), sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
