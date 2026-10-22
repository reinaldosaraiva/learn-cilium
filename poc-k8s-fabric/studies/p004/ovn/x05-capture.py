#!/usr/bin/env python3
"""Creator-owned continuous packet captures for the admitted X05 runtime.

The public surface is deliberately small: create from the exact canonical
``RuntimeBuilder``, start the fixed five captures, check their health between
windows, and stop/reap those same children.  Packet interpretation belongs to
the later coordinator; this module proves source, process, file, and PCAP
container integrity only.
"""

from __future__ import annotations

import argparse
import contextlib
import copy
import ctypes
import dataclasses
import errno
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import select
import signal
import stat
import struct
import subprocess
import sys
import time
from collections.abc import Mapping, Sequence
from typing import Any


HERE = pathlib.Path(__file__).resolve().parent
SOURCE_PATH = pathlib.Path(__file__).resolve()
APPLY_PATH = HERE / "x05-runtime-apply.py"
MODULE_NAME = "x05_capture_runtime_contract"
APPLY_MODULE_NAME = "x05_runtime_apply_capture_contract"
SCHEMA = "p004-x05-capture-session-v1"
HEALTH_SCHEMA = "p004-x05-capture-health-v1"
RESULT_SCHEMA = "p004-x05-capture-result-v1"
DLT_LINUX_SLL2 = 276
CAPTURE_STARTUP_SECONDS = 5.0
CAPTURE_LIFETIME_SECONDS = 900.0
CAPTURE_SNAPLEN = 262_144
CAPTURE_MAX_PACKETS = 1_023
CAPTURE_MAX_BYTES = 256 * 1024 * 1024
CAPTURE_MAX_STDERR = 256 * 1024
RETAINED_CAPTURE_DIRECTORY = "completed-captures"
STOP_PHASES = (
    (signal.SIGINT, 3.0),
    (signal.SIGTERM, 2.0),
    (signal.SIGKILL, 2.0),
)
PRODUCTION_TCPDUMP = pathlib.Path("/usr/bin/tcpdump")
PRODUCTION_NSENTER = pathlib.Path("/usr/bin/nsenter")
PRODUCTION_LIBPCAP = pathlib.Path("/usr/lib/x86_64-linux-gnu/libpcap.so.1.10.4")
_PCAP_MAGIC = {
    b"\xd4\xc3\xb2\xa1": ("<", False),
    b"\xa1\xb2\xc3\xd4": (">", False),
    b"\x4d\x3c\xb2\xa1": ("<", True),
    b"\xa1\xb2\x3c\x4d": (">", True),
}
_FOOTER_RE = re.compile(
    rb"(?m)^(\d+) packets? captured\n"
    rb"(\d+) packets? received by filter\n"
    rb"(\d+) packets? dropped by kernel\n?$"
)
_LISTENING_RE = re.compile(
    rb"^(?:tcpdump: )?listening on any, link-type LINUX_SLL2 "
    rb"\(Linux cooked v2\)(?:, snapshot length 262144 bytes)?\n$"
)
_TEST_TOOLCHAIN: dict[str, pathlib.Path] | None = None
_TEST_FAULT: str | None = None
_TEST_RETENTION_BUILDER: Any | None = None


def _load_apply() -> Any:
    existing = sys.modules.get(APPLY_MODULE_NAME)
    if existing is not None:
        if pathlib.Path(getattr(existing, "__file__", "")).resolve() != APPLY_PATH:
            raise RuntimeError("canonical X05 runtime builder path changed")
        return existing
    spec = importlib.util.spec_from_file_location(APPLY_MODULE_NAME, APPLY_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load the reviewed X05 runtime builder")
    module = importlib.util.module_from_spec(spec)
    sys.modules[APPLY_MODULE_NAME] = module
    spec.loader.exec_module(module)
    return module


APPLY = _load_apply()

_RUNTIME_BUILDER_VERIFY_AUTHORITY = APPLY.RuntimeBuilder._verify_authority
_RUNTIME_BUILDER_VERIFY_CAPTURE_CREATOR = (
    APPLY.RuntimeBuilder._verify_capture_creator
)
_RUNTIME_BUILDER_FINAL_ABSENCE = APPLY.RuntimeBuilder._final_absence_check
_PRODUCER_RECORD_EXECUTION_EVENT = APPLY._SESSION_RECORD_EXECUTION_EVENT
_RUNTIME_BUILDER_METHOD_BINDINGS = {
    name: value
    for name, value in APPLY.RuntimeBuilder.__dict__.items()
    if callable(value) or isinstance(value, (staticmethod, classmethod))
}


class CaptureError(APPLY.BuilderError):
    """The creator cannot prove the requested capture state."""


class CaptureSecurityError(CaptureError):
    """A creator, source, process, file, or binding changed."""


class CaptureAmbiguous(CaptureError):
    """A publication may have completed and must never be retried."""


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
        raise CaptureSecurityError("capture value is not canonical JSON") from exc


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _fd_identity(info: os.stat_result) -> tuple[int, int]:
    return (info.st_dev, info.st_ino)


def _source_identity(info: os.stat_result) -> tuple[int, ...]:
    return (
        info.st_dev,
        info.st_ino,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
        info.st_mode,
        info.st_uid,
    )


def _read_fd(descriptor: int, maximum: int) -> bytes:
    if maximum <= 0:
        raise CaptureSecurityError("capture read bound is invalid")
    chunks: list[bytes] = []
    offset = 0
    while offset <= maximum:
        chunk = os.pread(descriptor, min(65536, maximum + 1 - offset), offset)
        if not chunk:
            break
        chunks.append(chunk)
        offset += len(chunk)
        if offset > maximum:
            raise CaptureSecurityError("capture file exceeds its byte bound")
    return b"".join(chunks)


def _pcap_header(raw: bytes) -> tuple[str, bool, int]:
    if len(raw) < 24 or raw[:4] not in _PCAP_MAGIC:
        raise CaptureError("PCAP global header is missing or malformed")
    endian, nanosecond = _PCAP_MAGIC[raw[:4]]
    major, minor, _zone, _sigfigs, snaplen, linktype = struct.unpack(
        endian + "HHIIII", raw[4:24]
    )
    if major != 2 or minor != 4 or snaplen <= 0 or linktype != DLT_LINUX_SLL2:
        raise CaptureError("PCAP global header is not exact SLL2 DLT 276")
    return endian, nanosecond, linktype


def _pcap_records(
    raw: bytes, *, maximum_bytes: int = CAPTURE_MAX_BYTES
) -> dict[str, Any]:
    """Validate a bounded SLL2 PCAP container and return only format facts."""
    if len(raw) > maximum_bytes:
        raise CaptureError("PCAP exceeds the fixed capture byte bound")
    endian, nanosecond, linktype = _pcap_header(raw)
    offset = 24
    count = 0
    ifindices: list[int] = []
    fraction_limit = 1_000_000_000 if nanosecond else 1_000_000
    while offset < len(raw):
        if len(raw) - offset < 16:
            raise CaptureError("PCAP record header is truncated")
        _seconds, fraction, included, original = struct.unpack(
            endian + "IIII", raw[offset : offset + 16]
        )
        offset += 16
        if (
            fraction >= fraction_limit
            or included > original
            or included > maximum_bytes
            or len(raw) - offset < included
        ):
            raise CaptureError("PCAP record lengths or timestamp are invalid")
        packet = raw[offset : offset + included]
        if len(packet) < 20:
            raise CaptureError("PCAP SLL2 record is truncated")
        ifindices.append(int.from_bytes(packet[4:8], "big"))
        offset += included
        count += 1
    if offset != len(raw):
        raise CaptureError("PCAP does not end at a record boundary")
    return {
        "byte_count": len(raw),
        "record_count": count,
        "linktype": linktype,
        "endianness": "little" if endian == "<" else "big",
        "nanosecond": nanosecond,
        "ifindices": ifindices,
    }


def _ifindex_filter(indices: Sequence[int]) -> str:
    values = sorted(set(indices))
    if not values or any(type(value) is not int or value <= 0 for value in values):
        raise CaptureSecurityError("capture ifindex set is invalid")
    return "(" + " or ".join(f"link[4:4] = {value}" for value in values) + ")"


def _process_start_ticks(raw: bytes, context: str) -> int:
    try:
        text = raw.decode("ascii").strip()
        close = text.rindex(")")
        fields = text[close + 2 :].split()
        value = int(fields[19])
    except (UnicodeError, ValueError, IndexError) as exc:
        raise CaptureSecurityError(context + " /proc stat is malformed") from exc
    if value <= 0:
        raise CaptureSecurityError(context + " process start time is invalid")
    return value


def _read_proc(path: pathlib.Path, maximum: int = 1024 * 1024) -> bytes:
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise CaptureSecurityError("capture process evidence is unavailable") from exc
    if len(data) > maximum:
        raise CaptureSecurityError("capture process evidence exceeds its bound")
    return data


def _pidfd_target(descriptor: int) -> int:
    raw = _read_proc(pathlib.Path(f"/proc/self/fdinfo/{descriptor}"), maximum=4096)
    matches = re.findall(rb"(?m)^Pid:\s+(-?\d+)\s*$", raw)
    if len(matches) != 1:
        raise CaptureSecurityError("capture pidfd target is unavailable")
    target = int(matches[0])
    if target == 0 or target < -1:
        raise CaptureSecurityError("capture pidfd target is invalid")
    return target


def _namespace_identity(path: pathlib.Path) -> tuple[int, int]:
    try:
        return _fd_identity(path.stat())
    except OSError as exc:
        raise CaptureSecurityError("capture namespace evidence is unavailable") from exc


def _fault(config: Any, stage: str) -> None:
    if config.test_only_paths and _TEST_FAULT == stage:
        raise CaptureAmbiguous("synthetic capture boundary: " + stage)


def _retained_file_identity(info: os.stat_result) -> tuple[int, ...]:
    """Return the file facts that a same-filesystem rename must preserve."""
    return (
        info.st_dev,
        info.st_ino,
        info.st_size,
        info.st_mtime_ns,
        info.st_mode,
        info.st_uid,
    )


def _retained_identity_document(identity: tuple[int, ...]) -> dict[str, int]:
    if len(identity) != 6 or any(type(value) is not int for value in identity):
        raise CaptureSecurityError("retained capture identity is malformed")
    return dict(
        zip(
            ("device", "inode", "size", "mtime_ns", "mode", "uid"),
            identity,
            strict=True,
        )
    )


def _directory_identity(info: os.stat_result) -> tuple[int, ...]:
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid)


def _rename_noreplace(
    source_directory: int,
    source_name: str,
    destination_directory: int,
    destination_name: str,
) -> None:
    """Perform one Linux renameat2(RENAME_NOREPLACE), without a fallback."""
    if sys.platform != "linux":
        raise CaptureSecurityError("retained capture rename requires Linux")
    for name in (source_name, destination_name):
        if (
            type(name) is not str
            or not name
            or name in {".", ".."}
            or "/" in name
            or "\x00" in name
        ):
            raise CaptureSecurityError("retained capture name is invalid")
    try:
        function = ctypes.CDLL(None, use_errno=True).renameat2
    except (AttributeError, OSError) as exc:
        raise CaptureSecurityError(
            "renameat2(RENAME_NOREPLACE) is unavailable"
        ) from exc
    function.argtypes = (
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    )
    function.restype = ctypes.c_int
    ctypes.set_errno(0)
    result = function(
        source_directory,
        os.fsencode(source_name),
        destination_directory,
        os.fsencode(destination_name),
        1,
    )
    if result != 0:
        error = ctypes.get_errno()
        if error == 0:
            error = errno.EIO
        raise OSError(
            error,
            "renameat2(RENAME_NOREPLACE) failed",
            source_name,
            destination_name,
        )


def _absent_at(directory: int, name: str, context: str) -> None:
    try:
        os.stat(name, dir_fd=directory, follow_symlinks=False)
    except FileNotFoundError:
        return
    except OSError as exc:
        raise CaptureSecurityError(context + " absence is unavailable") from exc
    raise CaptureSecurityError(context + " is already occupied")


@dataclasses.dataclass(frozen=True)
class _ToolPin:
    name: str
    path: pathlib.Path
    descriptor: int
    identity: tuple[int, ...]
    sha256: str
    version: str


@dataclasses.dataclass
class _CaptureHandle:
    capture_id: str
    process: subprocess.Popen[bytes]
    pcap_fd: int
    pcap_identity: tuple[int, int]
    argv: tuple[str, ...]
    capture_argv: tuple[str, ...]
    target: dict[str, Any]
    stderr_receiver: Any
    stderr_descriptor: int | None = None
    stderr_identity: tuple[int, int] | None = None
    pidfd: int | None = None
    pidfd_identity: tuple[int, int] | None = None
    pidfd_guard: int | None = None
    pidfd_guard_identity: tuple[int, int] | None = None
    pcap_guard: int | None = None
    pcap_guard_identity: tuple[int, int] | None = None
    start_ticks: int | None = None
    session_id: int | None = None
    process_group_id: int | None = None
    parent_process_group_id: int | None = None
    launch_proof_complete: bool = False
    stderr: bytes = b""
    wait_receipt: dict[str, int] | None = None
    final_pcap_identity: tuple[int, ...] | None = None
    final_pcap_sha256: str | None = None


_TEST_CHILD = r"""
import os, signal, struct, sys, time
stopping = False
def stop(_signum, _frame):
    global stopping
    stopping = True
signal.signal(signal.SIGINT, stop)
signal.signal(signal.SIGTERM, stop)
os.write(1, struct.pack("<IHHIIII", 0xa1b2c3d4, 2, 4, 0, 0, 262144, 276))
os.fsync(1)
os.write(2, b"listening on any, link-type LINUX_SLL2 (Linux cooked v2)\n")
deadline = time.monotonic() + 900.0
while not stopping and time.monotonic() < deadline:
    time.sleep(0.01)
os.write(2, b"0 packets captured\n0 packets received by filter\n0 packets dropped by kernel\n")
"""


class CaptureSession:
    """The sole owner of the fixed five Popen/pidfd/PCAP triples."""

    def __init__(
        self,
        *,
        builder: Any,
        contract: dict[str, Any],
        tools: dict[str, _ToolPin],
        slots: dict[str, dict[str, Any]],
    ) -> None:
        self._builder = builder
        self._contract = contract
        self._tools = tools
        self._slots = slots
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
        try:
            self._execution_mntns_fd = os.open("/proc/self/ns/mnt", flags)
            self._execution_mntns_identity = _fd_identity(
                os.fstat(self._execution_mntns_fd)
            )
        except BaseException:
            descriptor = getattr(self, "_execution_mntns_fd", None)
            if descriptor is not None:
                with contextlib.suppress(OSError):
                    os.close(descriptor)
            raise CaptureSecurityError(
                "creator execution mount namespace cannot be pinned"
            )
        if _namespace_identity(pathlib.Path("/proc/self/ns/mnt")) != (
            self._execution_mntns_identity
        ):
            os.close(self._execution_mntns_fd)
            raise CaptureSecurityError(
                "creator execution mount namespace changed while pinning"
            )
        self._handles: list[_CaptureHandle] = []
        self._pcap_files: dict[str, dict[str, Any]] = {}
        self._state = "CREATED"
        self._published_state = ""
        self._started_count = 0
        self._ready_count = 0
        self._packet_status = "PENDING"
        self._ownership_status = "PENDING"
        self._publication_unknown = False
        self._pid_raw: bytes | None = None
        self._pid_sha256 = ""
        self._last_marker: dict[str, Any] | None = None
        self._started_monotonic: float | None = None
        self._stop_result: dict[str, Any] | None = None
        self._released = False
        self._retention_started = False
        self._retention_complete = False
        self._retention_unknown = False
        self._retained_locations: dict[str, Any] | None = None
        self._retention_parent_fd: int | None = None
        self._retention_parent_identity: tuple[int, ...] | None = None
        self._retention_directory_fd: int | None = None
        self._retention_directory_identity: tuple[int, ...] | None = None
        self._retention_pid_fd: int | None = None

    @classmethod
    def from_builder(cls, builder: Any) -> "CaptureSession":
        """Bind once to the exact canonical verified builder before spawning."""
        if cls is not CaptureSession or type(builder) is not APPLY.RuntimeBuilder:
            raise CaptureSecurityError("capture requires the canonical RuntimeBuilder")
        if (
            sys.modules.get(MODULE_NAME) is not sys.modules.get(__name__)
            or sys.modules.get(APPLY_MODULE_NAME) is not APPLY
            or APPLY.CAPTURE_MODULE_NAME != MODULE_NAME
            or APPLY.CAPTURE_APPLY_MODULE_NAME != APPLY_MODULE_NAME
        ):
            raise CaptureSecurityError("capture module graph is not canonical")
        contract_copy = builder.capture_bindings()
        contract = builder._capture_contract
        if not isinstance(contract, dict) or contract_copy != contract:
            raise CaptureSecurityError("builder did not retain its capture contract")
        tools = cls._pin_tools(builder)
        try:
            slots = cls._planned_slots(builder, contract, tools)
            session = cls(builder=builder, contract=contract, tools=tools, slots=slots)
        except BaseException:
            for pin in tools.values():
                with contextlib.suppress(OSError):
                    os.close(pin.descriptor)
            raise
        try:
            builder._capture_attach_call(session)
            session._state = "STARTING"
            session._checkpoint("STARTING0", initial=True)
        except BaseException:
            session._close_unstarted()
            raise
        return session

    @staticmethod
    def _pin_one(
        builder: Any, name: str, path: pathlib.Path, *, executable: bool, version: str
    ) -> _ToolPin:
        config = builder._config
        canonical = pathlib.Path(os.path.realpath(path))
        if not config.test_only_paths and canonical != path:
            raise CaptureSecurityError(name + " source path is not canonical")
        if not config.test_only_paths:
            ancestor = canonical.parent
            while True:
                try:
                    directory = ancestor.lstat()
                except OSError as exc:
                    raise CaptureSecurityError(
                        name + " source parent is unavailable"
                    ) from exc
                if (
                    stat.S_ISLNK(directory.st_mode)
                    or not stat.S_ISDIR(directory.st_mode)
                    or directory.st_uid != 0
                    or stat.S_IMODE(directory.st_mode) & 0o022
                ):
                    raise CaptureSecurityError(name + " source parent is unsafe")
                if ancestor == ancestor.parent:
                    break
                ancestor = ancestor.parent
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            before = canonical.lstat()
            descriptor = os.open(canonical, flags)
            opened = os.fstat(descriptor)
        except OSError as exc:
            raise CaptureSecurityError(name + " source cannot be pinned") from exc
        try:
            if (
                stat.S_ISLNK(before.st_mode)
                or not stat.S_ISREG(before.st_mode)
                or _source_identity(before) != _source_identity(opened)
                or (executable and not (opened.st_mode & stat.S_IXUSR))
                or (
                    not config.test_only_paths
                    and (opened.st_uid != 0 or stat.S_IMODE(opened.st_mode) & 0o022)
                )
            ):
                raise CaptureSecurityError(name + " source identity or mode is unsafe")
            raw = _read_fd(descriptor, APPLY.MAX_LOCAL_FILE)
            identity = _source_identity(opened)
        except BaseException:
            os.close(descriptor)
            raise
        return _ToolPin(
            name=name,
            path=canonical,
            descriptor=descriptor,
            identity=identity,
            sha256=_sha256(raw),
            version=version,
        )

    @classmethod
    def _pin_tools(cls, builder: Any) -> dict[str, _ToolPin]:
        config = builder._config
        if config.test_only_paths:
            chain = _TEST_TOOLCHAIN
            if not isinstance(chain, dict) or set(chain) != {
                "tcpdump",
                "nsenter",
                "libpcap",
            }:
                raise CaptureSecurityError("private test toolchain is unavailable")
            paths = {key: pathlib.Path(value) for key, value in chain.items()}
            versions = {
                "tcpdump": "test-tcpdump SLL2",
                "nsenter": "test-nsenter",
                "libpcap": "test-libpcap",
            }
        else:
            if (
                sys.platform != "linux"
                or not hasattr(os, "pidfd_open")
                or not hasattr(os, "P_PIDFD")
                or not hasattr(signal, "pidfd_send_signal")
            ):
                raise CaptureSecurityError("production capture requires Linux pidfds")
            paths = {
                "tcpdump": PRODUCTION_TCPDUMP,
                "nsenter": PRODUCTION_NSENTER,
                "libpcap": PRODUCTION_LIBPCAP,
            }
            versions = {}
            for name, argv in (
                ("tcpdump", (str(paths["tcpdump"]), "--version")),
                ("nsenter", (str(paths["nsenter"]), "--version")),
            ):
                try:
                    completed = subprocess.run(
                        argv,
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT,
                        env={"LC_ALL": "C", "LANG": "C", "PATH": "/usr/bin:/bin"},
                        timeout=2.0,
                        check=False,
                        close_fds=True,
                    )
                except (OSError, subprocess.SubprocessError) as exc:
                    raise CaptureSecurityError(name + " version probe failed") from exc
                if completed.returncode != 0 or len(completed.stdout) > 64 * 1024:
                    raise CaptureSecurityError(name + " version probe is invalid")
                versions[name] = completed.stdout.decode("utf-8", "strict").strip()
            if "libpcap version" not in versions["tcpdump"]:
                raise CaptureSecurityError("tcpdump did not report its libpcap version")
            versions["libpcap"] = versions["tcpdump"]
        pins = {
            name: cls._pin_one(
                builder,
                name,
                paths[name],
                executable=name != "libpcap",
                version=versions[name],
            )
            for name in ("tcpdump", "nsenter", "libpcap")
        }
        return pins

    @staticmethod
    def _capture_argv(tcpdump: pathlib.Path, expression: str) -> tuple[str, ...]:
        return (
            str(tcpdump),
            "-U",
            "-n",
            "-s",
            str(CAPTURE_SNAPLEN),
            "-c",
            str(CAPTURE_MAX_PACKETS),
            "-i",
            "any",
            "-y",
            "LINUX_SLL2",
            "-w",
            "-",
            expression,
        )

    @classmethod
    def _planned_slots(
        cls,
        builder: Any,
        contract: Mapping[str, Any],
        tools: Mapping[str, _ToolPin],
    ) -> dict[str, dict[str, Any]]:
        slots: dict[str, dict[str, Any]] = {}
        for point in contract["points"]:
            indices = [item["ifindex"] for item in point["interfaces"]]
            expression = _ifindex_filter(indices)
            capture_argv = cls._capture_argv(tools["tcpdump"].path, expression)
            target = point["target"]
            if builder._config.test_only_paths:
                argv = (str(tools["tcpdump"].path), "-c", _TEST_CHILD, point["id"])
            elif target["label"] == "host":
                argv = capture_argv
            else:
                argv = (
                    str(tools["nsenter"].path),
                    "--net=/proc/" + str(target["pid"]) + "/ns/net",
                    "--",
                    *capture_argv,
                )
            slots[point["id"]] = {
                "id": point["id"],
                "pid": None,
                "start_ticks": None,
                "argv": list(argv),
                "argv_sha256": APPLY.RuntimeBuilder._command_digest(argv),
                "target_sha256": point["target_sha256"],
                "started_at_ns": None,
                "stop_intent_at_ns": None,
                "reaped_at_ns": None,
                "wait_returncode": None,
                "reaped": False,
                "_capture_argv": capture_argv,
                "_filter": expression,
                "_target": copy.deepcopy(target),
            }
        if tuple(slots) != APPLY.CAPTURE_POINT_IDS:
            raise CaptureSecurityError("capture plan is not exactly five points")
        return slots

    def _slot_values(self) -> list[dict[str, Any]]:
        fields = self._contract["pid_journal"]["entry_fields"]
        return [
            {name: copy.deepcopy(self._slots[capture_id][name]) for name in fields}
            for capture_id in APPLY.CAPTURE_POINT_IDS
        ]

    def _pid_document(self, state: str) -> dict[str, Any]:
        return {
            "schema": APPLY.CAPTURE_PID_SCHEMA,
            "owner": self._contract["owner"],
            "run_hex": self._contract["run_hex"],
            "state": state,
            "builder_marker_sha256": self._contract["marker_sha256"],
            "runtime_journal_path": self._contract["runtime_journal_path"],
            "runtime_journal_sha256": self._contract["runtime_journal_sha256"],
            "runtime_journal_head_sha256": self._contract[
                "runtime_journal_head_sha256"
            ],
            "captures": self._slot_values(),
        }

    def _publish_pid(self, state: str, *, initial: bool) -> None:
        raw = _canonical(self._pid_document(state))
        path = pathlib.Path(self._contract["pid_journal"]["path"])
        _fault(self._builder._config, "pid-before-" + state)
        if initial:
            if self._pid_raw is not None:
                raise CaptureSecurityError("initial PID publication was repeated")
            APPLY._atomic_new(path, raw, uid=self._builder._config.required_uid)
        else:
            if self._pid_raw is None:
                raise CaptureSecurityError("capture PID publication has no predecessor")
            APPLY._atomic_replace(
                path,
                expected=self._pid_raw,
                payload=raw,
                uid=self._builder._config.required_uid,
            )
        _fault(self._builder._config, "pid-after-" + state)
        current, _ = APPLY._read_regular(
            path,
            maximum=1024 * 1024,
            mode=0o600,
            uid=self._builder._config.required_uid,
        )
        if current != raw:
            raise CaptureAmbiguous("capture PID publication readback changed")
        self._pid_raw = raw
        self._pid_sha256 = _sha256(raw)

    def _checkpoint(self, state: str, *, initial: bool = False) -> None:
        if self._publication_unknown:
            raise CaptureAmbiguous("capture publication is already unknown")
        try:
            self._publish_pid(state, initial=initial)
            self._published_state = state
            _fault(self._builder._config, "marker-before-" + state)
            self._last_marker = self._builder._capture_progress_call(self)
            _fault(self._builder._config, "marker-after-" + state)
        except BaseException as exc:
            self._publication_unknown = True
            self._builder._unknown = True
            if isinstance(exc, CaptureAmbiguous):
                raise
            raise CaptureAmbiguous(
                "capture checkpoint outcome is unknown: " + state
            ) from exc

    def _verify_tools(self) -> None:
        for pin in self._tools.values():
            try:
                current = os.fstat(pin.descriptor)
                path_current = pin.path.lstat()
            except OSError as exc:
                raise CaptureSecurityError(
                    "pinned capture source descriptor closed"
                ) from exc
            if (
                _source_identity(current) != pin.identity
                or _source_identity(path_current) != pin.identity
                or _sha256(_read_fd(pin.descriptor, APPLY.MAX_LOCAL_FILE)) != pin.sha256
            ):
                raise CaptureSecurityError("pinned capture source identity changed")

    def _verify_execution_mount(self) -> None:
        try:
            pinned = _fd_identity(os.fstat(self._execution_mntns_fd))
        except OSError as exc:
            raise CaptureSecurityError(
                "creator execution mount namespace descriptor changed"
            ) from exc
        if (
            pinned != self._execution_mntns_identity
            or _namespace_identity(pathlib.Path("/proc/self/ns/mnt"))
            != self._execution_mntns_identity
        ):
            raise CaptureSecurityError("creator execution mount namespace changed")

    def _mark_stderr_unknown(self, message: str) -> None:
        self._packet_status = "ERROR"
        self._publication_unknown = True
        self._builder._unknown = True
        if self._retention_started:
            self._retention_unknown = True
        if isinstance(self._stop_result, dict):
            self._stop_result["packet_status"] = "ERROR"
            errors = self._stop_result.get("errors")
            detail = "CaptureSecurityError:" + message
            if isinstance(errors, list) and detail not in errors:
                errors.append(detail)

    def _verify_stderr(self, handle: _CaptureHandle) -> int:
        receiver = handle.stderr_receiver
        if (
            handle.process.stderr is not receiver
            or receiver is None
            or getattr(receiver, "closed", True)
        ):
            message = "capture stderr receiver changed"
            self._mark_stderr_unknown(message)
            raise CaptureSecurityError(message)
        if handle.stderr_descriptor is None or handle.stderr_identity is None:
            message = "capture stderr acquisition proof is incomplete"
            self._mark_stderr_unknown(message)
            raise CaptureSecurityError(message)
        try:
            descriptor = receiver.fileno()
            current = os.fstat(descriptor)
        except (OSError, ValueError) as exc:
            message = "capture stderr descriptor closed or rebound"
            self._mark_stderr_unknown(message)
            raise CaptureSecurityError(message) from exc
        if (
            type(descriptor) is not int
            or descriptor != handle.stderr_descriptor
            or _fd_identity(current) != handle.stderr_identity
            or not stat.S_ISFIFO(current.st_mode)
        ):
            message = "capture stderr identity changed"
            self._mark_stderr_unknown(message)
            raise CaptureSecurityError(message)
        occupied = {handle.pcap_fd, self._execution_mntns_fd}
        occupied.update(pin.descriptor for pin in self._tools.values())
        occupied.update(
            candidate
            for candidate in (
                handle.pidfd,
                handle.pidfd_guard,
                handle.pcap_guard,
                self._retention_pid_fd,
                self._retention_parent_fd,
                self._retention_directory_fd,
            )
            if candidate is not None
        )
        if type(self._builder) is APPLY.RuntimeBuilder:
            occupied.update(
                candidate
                for candidate in (
                    self._builder._session._lock_fd,
                    self._builder._session._lock_keeper_fd,
                )
                if isinstance(candidate, int)
            )
        if descriptor in occupied:
            message = "capture stderr descriptor overlaps authority"
            self._mark_stderr_unknown(message)
            raise CaptureSecurityError(message)
        return descriptor

    def _verify_signal_authority(self, handle: _CaptureHandle) -> int:
        slot = self._slots[handle.capture_id]
        if handle.pidfd is None or handle.pidfd_identity is None:
            raise CaptureSecurityError(
                "capture has no proved original pidfd authority"
            )
        try:
            pidfd = os.fstat(handle.pidfd)
        except OSError as exc:
            raise CaptureSecurityError(
                "capture signal descriptor closed or rebound"
            ) from exc
        if (
            _fd_identity(pidfd) != handle.pidfd_identity
            or type(handle.process) is not _POPEN_CLASS
            or handle.process.pid != slot["pid"]
            or handle.argv != tuple(slot["argv"])
        ):
            raise CaptureSecurityError("capture original handle identity changed")
        allowed_targets = {slot["pid"], -1}
        if _pidfd_target(handle.pidfd) not in allowed_targets:
            raise CaptureSecurityError("capture signal pidfd target changed")
        if handle.pidfd_guard is None:
            if handle.pidfd_guard_identity is not None:
                raise CaptureSecurityError("capture pidfd guard proof changed")
        else:
            if handle.pidfd_guard_identity is None:
                raise CaptureSecurityError("capture pidfd guard proof is incomplete")
            try:
                guard = os.fstat(handle.pidfd_guard)
            except OSError as exc:
                raise CaptureSecurityError(
                    "capture pidfd guard closed or rebound"
                ) from exc
            if (
                _fd_identity(guard) != handle.pidfd_guard_identity
                or _pidfd_target(handle.pidfd_guard) not in allowed_targets
            ):
                raise CaptureSecurityError("capture pidfd guard identity changed")
        return handle.pidfd

    def _verify_handle(
        self,
        handle: _CaptureHandle,
        *,
        require_live: bool,
        allow_namespace_transition: bool = False,
    ) -> bool:
        if not handle.launch_proof_complete:
            raise CaptureSecurityError("capture launch proof is incomplete")
        self._verify_signal_authority(handle)
        self._verify_stderr(handle)
        try:
            pcap = os.fstat(handle.pcap_fd)
        except OSError as exc:
            raise CaptureSecurityError(
                "capture primary descriptor closed or rebound"
            ) from exc
        if (
            _fd_identity(pcap) != handle.pcap_identity
            or handle.start_ticks is None
            or handle.session_id != handle.process.pid
            or handle.process_group_id != handle.process.pid
            or handle.parent_process_group_id is None
            or handle.parent_process_group_id == handle.process_group_id
        ):
            raise CaptureSecurityError("capture descriptor identity changed")
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
                continue
            try:
                current = os.fstat(descriptor)
            except OSError as exc:
                raise CaptureSecurityError(
                    "capture guard descriptor closed or rebound"
                ) from exc
            expected_identity = identity if identity is not None else original_identity
            if expected_identity is None or _fd_identity(current) != expected_identity:
                raise CaptureSecurityError("capture guard descriptor identity changed")
        if require_live and self._pidfd_exited(handle):
            raise CaptureError("capture child exited before stop: " + handle.capture_id)
        if not self._pidfd_exited(handle):
            stat_raw = _read_proc(pathlib.Path(f"/proc/{handle.process.pid}/stat"))
            if _process_start_ticks(stat_raw, handle.capture_id) != handle.start_ticks:
                raise CaptureSecurityError("capture PID was reused")
            if (
                os.getsid(handle.process.pid) != handle.session_id
                or os.getpgid(handle.process.pid) != handle.process_group_id
            ):
                raise CaptureSecurityError("capture child session or group changed")
            netns = pathlib.Path(f"/proc/{handle.process.pid}/ns/net").stat().st_ino
            mntns = _namespace_identity(
                pathlib.Path(f"/proc/{handle.process.pid}/ns/mnt")
            )
            expected_netns = handle.target["netns_inode"]
            if self._builder._config.test_only_paths:
                expected_netns = pathlib.Path("/proc/self/ns/net").stat().st_ino
            if mntns != self._execution_mntns_identity:
                raise CaptureSecurityError("capture child execution mount changed")
            if netns != expected_netns:
                if allow_namespace_transition:
                    return False
                raise CaptureSecurityError("capture child namespace changed")
            stdout_info = pathlib.Path(f"/proc/{handle.process.pid}/fd/1").stat()
            if _fd_identity(stdout_info) != handle.pcap_identity:
                raise CaptureSecurityError("capture child stdout changed")
            cmdline = tuple(
                item.decode("utf-8", "strict")
                for item in _read_proc(
                    pathlib.Path(f"/proc/{handle.process.pid}/cmdline")
                ).split(b"\0")
                if item
            )
            if cmdline != handle.argv and cmdline != handle.capture_argv:
                raise CaptureSecurityError("capture child argv changed")
        return True

    def _pidfd_exited(self, handle: _CaptureHandle) -> bool:
        pidfd = self._verify_signal_authority(handle)
        poller = select.poll()
        poller.register(pidfd, select.POLLIN)
        return bool(poller.poll(0))

    @staticmethod
    def _listening_ready(stderr: bytes) -> bool:
        found = False
        for line in stderr.splitlines(keepends=True):
            if not line.endswith(b"\n"):
                continue
            if b"listening on" not in line:
                continue
            if _LISTENING_RE.fullmatch(line) is None:
                raise CaptureError("tcpdump listening evidence is malformed or foreign")
            found = True
        return found

    def _drain_stderr(self, handle: _CaptureHandle) -> None:
        while True:
            descriptor = self._verify_stderr(handle)
            try:
                chunk = os.read(descriptor, 65536)
            except BlockingIOError:
                break
            except OSError as exc:
                raise CaptureSecurityError("capture stderr read failed") from exc
            if not chunk:
                break
            if len(handle.stderr) + len(chunk) > CAPTURE_MAX_STDERR:
                raise CaptureError("tcpdump stderr exceeds its fixed bound")
            handle.stderr += chunk

    def _wait_ready(self, handle: _CaptureHandle) -> None:
        deadline = time.monotonic() + CAPTURE_STARTUP_SECONDS
        while time.monotonic() < deadline:
            self._drain_stderr(handle)
            ready = self._verify_handle(
                handle,
                require_live=True,
                allow_namespace_transition=True,
            )
            if not ready:
                time.sleep(0.01)
                continue
            header = os.pread(handle.pcap_fd, 24, 0)
            header_ready = len(header) == 24
            if header_ready:
                _pcap_header(header)
            if header_ready and self._listening_ready(handle.stderr):
                self._verify_handle(handle, require_live=True)
                return
            time.sleep(0.01)
        raise CaptureError("capture readiness timed out: " + handle.capture_id)

    def _open_pcap(self, capture_id: str) -> tuple[int, tuple[int, int]]:
        path = self._builder._config.evidence_path / (capture_id + ".pcap")
        flags = (
            os.O_RDWR
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
        try:
            descriptor = os.open(path, flags, 0o600)
            info = os.fstat(descriptor)
        except OSError as exc:
            raise CaptureSecurityError(
                "exclusive PCAP creation failed: " + capture_id
            ) from exc
        if (
            info.st_uid != self._builder._config.required_uid
            or stat.S_IMODE(info.st_mode) != 0o600
            or not stat.S_ISREG(info.st_mode)
        ):
            os.close(descriptor)
            raise CaptureSecurityError("new PCAP owner, mode, or type is invalid")
        identity = _fd_identity(info)
        if capture_id in self._pcap_files:
            os.close(descriptor)
            raise CaptureSecurityError("capture PCAP creation was repeated")
        self._pcap_files[capture_id] = {
            "descriptor": descriptor,
            "identity": identity,
            "launched": False,
            "final_identity": None,
            "sha256": None,
        }
        APPLY._fsync_directory(path.parent)
        return descriptor, identity

    def start(self) -> dict[str, Any]:
        """Start and prove readiness of the fixed five continuous children."""
        if self._state != "STARTING" or self._started_count != 0:
            raise CaptureSecurityError("capture start is one-shot")
        if sys.platform != "linux" or not hasattr(os, "pidfd_open"):
            raise CaptureSecurityError("capture start requires Linux pidfds")
        self._verify_tools()
        self._verify_execution_mount()
        self._builder._capture_health_call(self)
        self._started_monotonic = time.monotonic()
        try:
            for capture_id in APPLY.CAPTURE_POINT_IDS:
                slot = self._slots[capture_id]
                self._verify_tools()
                self._verify_execution_mount()
                _fault(self._builder._config, "spawn-before-" + capture_id)
                self._builder._capture_spawn_intent_call(self, capture_id)
                parent_process_group_id = os.getpgrp()
                planned_argv = tuple(slot["argv"])
                planned_capture_argv = tuple(slot["_capture_argv"])
                planned_target = copy.deepcopy(slot["_target"])
                pcap_fd, pcap_identity = self._open_pcap(capture_id)
                process = subprocess.Popen(
                    planned_argv,
                    stdin=subprocess.DEVNULL,
                    stdout=pcap_fd,
                    stderr=subprocess.PIPE,
                    env={"LC_ALL": "C", "LANG": "C", "PATH": "/usr/bin:/bin"},
                    close_fds=True,
                    start_new_session=True,
                )
                stderr_receiver = process.stderr
                handle = _CaptureHandle(
                    capture_id=capture_id,
                    process=process,
                    pcap_fd=pcap_fd,
                    pcap_identity=pcap_identity,
                    argv=planned_argv,
                    capture_argv=planned_capture_argv,
                    target=planned_target,
                    stderr_receiver=stderr_receiver,
                    parent_process_group_id=parent_process_group_id,
                )
                try:
                    self._handles.append(handle)
                    self._pcap_files[capture_id]["launched"] = True
                    slot.update(
                        {
                            "pid": process.pid,
                            "started_at_ns": time.time_ns(),
                        }
                    )
                    self._started_count += 1
                except BaseException:
                    self._packet_status = "ERROR"
                    self._ownership_status = "ERROR"
                    self._builder._unknown = True
                    raise
                try:
                    if stderr_receiver is None:
                        self._packet_status = "ERROR"
                        self._ownership_status = "ERROR"
                        self._publication_unknown = True
                        self._builder._unknown = True
                        raise CaptureSecurityError(
                            "capture stderr receiver is unavailable"
                        )
                    try:
                        stderr_descriptor = stderr_receiver.fileno()
                        stderr_info = os.fstat(stderr_descriptor)
                    except (OSError, TypeError, ValueError) as exc:
                        self._packet_status = "ERROR"
                        self._ownership_status = "ERROR"
                        self._publication_unknown = True
                        self._builder._unknown = True
                        raise CaptureSecurityError(
                            "capture stderr acquisition failed"
                        ) from exc
                    if (
                        type(stderr_descriptor) is not int
                        or stderr_descriptor < 0
                        or not stat.S_ISFIFO(stderr_info.st_mode)
                    ):
                        self._packet_status = "ERROR"
                        self._ownership_status = "ERROR"
                        self._publication_unknown = True
                        self._builder._unknown = True
                        raise CaptureSecurityError(
                            "capture stderr acquisition is invalid"
                        )
                    handle.stderr_descriptor = stderr_descriptor
                    handle.stderr_identity = _fd_identity(stderr_info)
                    _fault(self._builder._config, "spawn-after-popen-" + capture_id)
                    handle.pidfd = os.pidfd_open(process.pid, 0)
                    _fault(
                        self._builder._config,
                        "spawn-after-pidfd-open-" + capture_id,
                    )
                    handle.pidfd_identity = _fd_identity(os.fstat(handle.pidfd))
                    _fault(self._builder._config, "spawn-after-pidfd-" + capture_id)
                    _fault(
                        self._builder._config,
                        "spawn-after-pidfd-identity-" + capture_id,
                    )
                    handle.start_ticks = _process_start_ticks(
                        _read_proc(pathlib.Path(f"/proc/{process.pid}/stat")),
                        capture_id,
                    )
                    slot["start_ticks"] = handle.start_ticks
                    _fault(self._builder._config, "spawn-after-proc-" + capture_id)
                    handle.session_id = os.getsid(process.pid)
                    handle.process_group_id = os.getpgid(process.pid)
                    if (
                        handle.session_id != process.pid
                        or handle.process_group_id != process.pid
                        or handle.process_group_id == parent_process_group_id
                    ):
                        raise CaptureSecurityError(
                            "capture child did not enter its own session and group"
                        )
                    handle.launch_proof_complete = True
                    _fault(self._builder._config, "spawn-after-group-" + capture_id)
                    handle.pidfd_guard = os.dup(handle.pidfd)
                    handle.pidfd_guard_identity = _fd_identity(
                        os.fstat(handle.pidfd_guard)
                    )
                    _fault(
                        self._builder._config,
                        "spawn-after-pidfd-dup-" + capture_id,
                    )
                    handle.pcap_guard = os.dup(pcap_fd)
                    handle.pcap_guard_identity = _fd_identity(
                        os.fstat(handle.pcap_guard)
                    )
                    _fault(
                        self._builder._config,
                        "spawn-after-pcap-dup-" + capture_id,
                    )
                    stderr_descriptor = self._verify_stderr(handle)
                    try:
                        os.set_blocking(stderr_descriptor, False)
                    except OSError as exc:
                        message = "capture stderr blocking mode change failed"
                        self._mark_stderr_unknown(message)
                        raise CaptureSecurityError(message) from exc
                    self._verify_stderr(handle)
                    self._checkpoint("STARTING" + str(self._started_count))
                    self._wait_ready(handle)
                    self._verify_tools()
                    self._verify_execution_mount()
                    self._ready_count += 1
                except BaseException:
                    self._packet_status = "ERROR"
                    if not handle.launch_proof_complete:
                        self._ownership_status = "ERROR"
                        self._builder._unknown = True
                    raise
            for handle in self._handles:
                self._verify_handle(handle, require_live=True)
            self._verify_tools()
            self._verify_execution_mount()
            self._builder._capture_health_call(self)
            self._state = "STARTED"
            self._packet_status = "PENDING"
            self._checkpoint("STARTED5ready")
            return self._start_result()
        except BaseException:
            self._packet_status = "ERROR"
            raise

    def _start_result(self) -> dict[str, Any]:
        return {
            "schema": SCHEMA,
            "status": "PASS",
            "state": self._published_state,
            "started_count": self._started_count,
            "ready_count": self._ready_count,
            "points": list(APPLY.CAPTURE_POINT_IDS),
            "pid_journal": {
                "path": self._contract["pid_journal"]["path"],
                "sha256": self._pid_sha256,
            },
            "last_marker": copy.deepcopy(self._last_marker),
        }

    def health(self) -> dict[str, Any]:
        """Recheck the same source/link/handle identities between windows."""
        if self._state != "STARTED" or self._publication_unknown:
            raise CaptureSecurityError("capture health requires durable STARTED state")
        if (
            self._started_monotonic is None
            or time.monotonic() - self._started_monotonic > CAPTURE_LIFETIME_SECONDS
        ):
            self._packet_status = "ERROR"
            raise CaptureError("capture exceeded its fixed lifetime bound")
        self._verify_tools()
        self._verify_execution_mount()
        binding = self._builder._capture_health_call(self)
        sizes: dict[str, int] = {}
        for handle in self._handles:
            self._verify_handle(handle, require_live=True)
            size = os.fstat(handle.pcap_fd).st_size
            if size > CAPTURE_MAX_BYTES:
                self._packet_status = "ERROR"
                raise CaptureError("capture exceeded its fixed byte bound")
            sizes[handle.capture_id] = size
        return {
            "schema": HEALTH_SCHEMA,
            "status": "PASS",
            "state": self._published_state,
            "started_count": self._started_count,
            "ready_count": self._ready_count,
            "points": binding["points"],
            "bytes": sizes,
        }

    def _wait_process(
        self, handle: _CaptureHandle, timeout: float
    ) -> int | None:
        pidfd = self._verify_signal_authority(handle)
        if handle.process.returncode is not None:
            raise CaptureSecurityError("capture child was reaped outside pidfd custody")
        poller = select.poll()
        poller.register(pidfd, select.POLLIN)
        if not poller.poll(max(0, int(timeout * 1000))):
            return None
        pidfd = self._verify_signal_authority(handle)
        try:
            observed = os.waitid(
                os.P_PIDFD,
                pidfd,
                os.WEXITED | os.WNOWAIT | os.WNOHANG,
            )
        except (ChildProcessError, OSError) as exc:
            raise CaptureSecurityError("capture child lost waitability") from exc
        if observed is None or observed.si_pid != handle.process.pid:
            raise CaptureSecurityError("capture child wait receipt is incomplete")
        pidfd = self._verify_signal_authority(handle)
        try:
            receipt = os.waitid(
                os.P_PIDFD,
                pidfd,
                os.WEXITED | os.WNOHANG,
            )
        except (ChildProcessError, OSError) as exc:
            raise CaptureSecurityError("capture child lost waitability") from exc
        if (
            receipt is None
            or receipt.si_pid != handle.process.pid
            or (
                receipt.si_pid,
                receipt.si_uid,
                receipt.si_code,
                receipt.si_status,
            )
            != (
                observed.si_pid,
                observed.si_uid,
                observed.si_code,
                observed.si_status,
            )
        ):
            raise CaptureSecurityError("capture child wait receipt changed")
        expected = (
            receipt.si_status
            if receipt.si_code == os.CLD_EXITED
            else -receipt.si_status
        )
        handle.process.returncode = expected
        returncode = expected
        handle.wait_receipt = {
            "pid": receipt.si_pid,
            "uid": receipt.si_uid,
            "code": receipt.si_code,
            "status": receipt.si_status,
            "returncode": returncode,
        }
        return returncode

    def _finish_handle(self, handle: _CaptureHandle) -> dict[str, Any]:
        slot = self._slots[handle.capture_id]
        self._verify_handle(handle, require_live=False)
        returncode = handle.process.returncode
        if returncode is None:
            raise CaptureSecurityError("capture child was not reaped")
        if (
            handle.wait_receipt is None
            or handle.wait_receipt["pid"] != handle.process.pid
            or handle.wait_receipt["returncode"] != returncode
        ):
            raise CaptureSecurityError("capture child wait result changed")
        slot["wait_returncode"] = returncode
        slot["reaped_at_ns"] = time.time_ns()
        slot["reaped"] = True
        os.fsync(handle.pcap_fd)
        if handle.pcap_guard is not None:
            os.fsync(handle.pcap_guard)
        raw = _read_fd(handle.pcap_fd, CAPTURE_MAX_BYTES)
        handle.final_pcap_identity = _retained_file_identity(
            os.fstat(handle.pcap_fd)
        )
        handle.final_pcap_sha256 = _sha256(raw)
        retained = self._pcap_files.get(handle.capture_id)
        if (
            not isinstance(retained, dict)
            or retained.get("descriptor") != handle.pcap_fd
            or retained.get("identity") != handle.pcap_identity
            or retained.get("launched") is not True
        ):
            raise CaptureSecurityError("capture PCAP custody changed")
        retained["final_identity"] = handle.final_pcap_identity
        retained["sha256"] = handle.final_pcap_sha256
        pcap = _pcap_records(raw)
        self._drain_stderr(handle)
        footer = _FOOTER_RE.search(handle.stderr)
        captured = int(footer.group(1)) if footer is not None else -1
        received = int(footer.group(2)) if footer is not None else -1
        dropped = int(footer.group(3)) if footer is not None else -1
        if (
            returncode != 0
            or footer is None
            or dropped != 0
            or captured != pcap["record_count"]
            or received < captured
        ):
            raise CaptureError("tcpdump termination/footer/drop proof failed")
        return {
            "id": handle.capture_id,
            "pid": handle.process.pid,
            "returncode": returncode,
            "pcap": pcap,
            "stderr_sha256": _sha256(handle.stderr),
            "received_by_filter": received,
            "dropped_by_kernel": dropped,
        }

    def _finish_unlaunched_pcaps(self) -> None:
        """Pin creator-made PCAP files for attempts where Popen made no child."""
        for capture_id, retained in self._pcap_files.items():
            if retained.get("launched") is True:
                continue
            if self._slots[capture_id]["pid"] is not None:
                raise CaptureSecurityError(
                    "unlaunched PCAP has a capture PID: " + capture_id
                )
            descriptor = retained.get("descriptor")
            identity = retained.get("identity")
            if type(descriptor) is not int or not isinstance(identity, tuple):
                raise CaptureSecurityError(
                    "unlaunched PCAP custody is incomplete: " + capture_id
                )
            path = self._builder._config.evidence_path / (capture_id + ".pcap")
            try:
                opened = os.fstat(descriptor)
                current = path.lstat()
            except OSError as exc:
                raise CaptureSecurityError(
                    "unlaunched PCAP path changed: " + capture_id
                ) from exc
            if (
                _fd_identity(opened) != identity
                or _fd_identity(current) != identity
                or not stat.S_ISREG(opened.st_mode)
                or opened.st_uid != self._builder._config.required_uid
                or stat.S_IMODE(opened.st_mode) != 0o600
            ):
                raise CaptureSecurityError(
                    "unlaunched PCAP identity changed: " + capture_id
                )
            os.fsync(descriptor)
            raw = _read_fd(descriptor, CAPTURE_MAX_BYTES)
            retained["final_identity"] = _retained_file_identity(
                os.fstat(descriptor)
            )
            retained["sha256"] = _sha256(raw)

    def stop(self) -> dict[str, Any]:
        """Stop/reap only the retained originals, even after a partial start."""
        if self._stop_result is not None:
            return copy.deepcopy(self._stop_result)
        if self._state not in {"STARTING", "STARTED"}:
            raise CaptureSecurityError("capture stop has no owned active session")
        now = time.time_ns()
        for slot in self._slots.values():
            slot["stop_intent_at_ns"] = now
        packet_errors: list[str] = []
        if self._packet_status == "ERROR":
            packet_errors.append("prior-capture-error")
        if self._started_monotonic is None:
            packet_errors.append("capture-lifetime-unavailable")
        elif time.monotonic() - self._started_monotonic > CAPTURE_LIFETIME_SECONDS:
            packet_errors.append("capture-lifetime-exceeded")
        try:
            self._verify_tools()
            self._verify_execution_mount()
            if not self._publication_unknown:
                self._builder._capture_health_call(self)
        except Exception as exc:
            packet_errors.append(type(exc).__name__ + ":" + str(exc))
        for handle in self._handles:
            if not handle.launch_proof_complete:
                packet_errors.append(
                    "CaptureSecurityError:capture launch proof is incomplete:"
                    + handle.capture_id
                )
            if (
                handle.pidfd_guard is None
                or handle.pidfd_guard_identity is None
                or handle.pcap_guard is None
                or handle.pcap_guard_identity is None
            ):
                packet_errors.append(
                    "CaptureSecurityError:capture guard setup is incomplete:"
                    + handle.capture_id
                )
            if handle.process.returncode is not None:
                continue
            try:
                exited = self._pidfd_exited(handle)
            except Exception as exc:
                packet_errors.append(type(exc).__name__ + ":" + str(exc))
                continue
            if exited:
                try:
                    self._wait_process(handle, 0.0)
                except Exception as exc:
                    packet_errors.append(type(exc).__name__ + ":" + str(exc))
        for signum, timeout in STOP_PHASES:
            live: list[_CaptureHandle] = []
            for handle in self._handles:
                if handle.process.returncode is not None or handle.pidfd is None:
                    continue
                try:
                    if self._pidfd_exited(handle):
                        self._wait_process(handle, 0.0)
                    else:
                        live.append(handle)
                except Exception as exc:
                    packet_errors.append(type(exc).__name__ + ":" + str(exc))
            if not live:
                break
            for handle in live:
                try:
                    self._verify_handle(handle, require_live=True)
                except Exception as exc:
                    packet_errors.append(type(exc).__name__ + ":" + str(exc))
                try:
                    pidfd = self._verify_signal_authority(handle)
                    signal.pidfd_send_signal(pidfd, signum, None, 0)
                except Exception as exc:
                    packet_errors.append(type(exc).__name__ + ":" + str(exc))
            deadline = time.monotonic() + timeout
            for handle in live:
                if handle.process.returncode is None:
                    try:
                        remaining = max(0.0, deadline - time.monotonic())
                        self._wait_process(handle, remaining)
                    except Exception as exc:
                        packet_errors.append(type(exc).__name__ + ":" + str(exc))
        for handle in self._handles:
            if handle.process.returncode is not None or handle.pidfd is None:
                continue
            try:
                if self._pidfd_exited(handle):
                    self._wait_process(handle, 0.0)
            except Exception as exc:
                packet_errors.append(type(exc).__name__ + ":" + str(exc))
        unreaped = [
            handle for handle in self._handles if handle.process.returncode is None
        ]
        finished: list[dict[str, Any]] = []
        for handle in self._handles:
            if handle in unreaped:
                continue
            try:
                finished.append(self._finish_handle(handle))
            except Exception as exc:
                packet_errors.append(type(exc).__name__ + ":" + str(exc))
                if handle.process.returncode is not None:
                    slot = self._slots[handle.capture_id]
                    slot["wait_returncode"] = handle.process.returncode
                    slot["reaped_at_ns"] = slot["reaped_at_ns"] or time.time_ns()
                    slot["reaped"] = True
        try:
            self._finish_unlaunched_pcaps()
        except Exception as exc:
            packet_errors.append(type(exc).__name__ + ":" + str(exc))
        created_ids = {handle.capture_id for handle in self._handles}
        if self._started_count != len(APPLY.CAPTURE_POINT_IDS):
            packet_errors.append("partial-start")
        if self._ready_count != len(APPLY.CAPTURE_POINT_IDS):
            packet_errors.append("partial-readiness")
        self._ownership_status = (
            "PASS"
            if not unreaped
            and created_ids
            == {key for key, slot in self._slots.items() if slot["pid"] is not None}
            and all(self._slots[key]["reaped"] for key in created_ids)
            and all(handle.launch_proof_complete for handle in self._handles)
            else "ERROR"
        )
        self._packet_status = "PASS" if not packet_errors else "ERROR"
        if self._ownership_status == "PASS":
            self._state = "STOPPED"
            if not self._publication_unknown:
                try:
                    self._checkpoint("STOPPED")
                except Exception as exc:
                    packet_errors.append(type(exc).__name__ + ":" + str(exc))
                    self._packet_status = "ERROR"
        else:
            self._state = "STOP_FAILED"
            self._builder._unknown = True
        result = {
            "schema": RESULT_SCHEMA,
            "status": "PASS" if self._ownership_status == "PASS" else "ERROR",
            "state": self._state,
            "ownership_status": self._ownership_status,
            "packet_status": self._packet_status,
            "captures": finished,
            "errors": packet_errors,
            "pid_journal": {
                "path": self._contract["pid_journal"]["path"],
                "sha256": self._pid_sha256,
                "state": self._published_state,
            },
            "last_marker": copy.deepcopy(self._last_marker),
        }
        self._stop_result = copy.deepcopy(result)
        return result

    def _read_owned_pcaps(self) -> dict[str, dict[str, Any]]:
        """Read exact retained PCAP descriptors for the later canonical consumer."""
        if (
            self._state != "STOPPED"
            or self._ownership_status != "PASS"
            or self._released
        ):
            raise CaptureSecurityError("owned PCAP bytes are unavailable")
        result: dict[str, dict[str, Any]] = {}
        for handle in self._handles:
            self._verify_handle(handle, require_live=False)
            raw = _read_fd(handle.pcap_fd, CAPTURE_MAX_BYTES)
            result[handle.capture_id] = {
                "raw": raw,
                "sha256": _sha256(raw),
                "format": _pcap_records(raw),
            }
        if tuple(result) != APPLY.CAPTURE_POINT_IDS:
            raise CaptureSecurityError("owned PCAP inventory is incomplete")
        return result

    def _close_unstarted(self) -> None:
        handled_pcaps = {handle.pcap_fd for handle in self._handles}
        for handle in self._handles:
            for descriptor in (
                handle.pidfd,
                handle.pidfd_guard,
                handle.pcap_fd,
                handle.pcap_guard,
            ):
                if descriptor is not None:
                    with contextlib.suppress(OSError):
                        os.close(descriptor)
        for retained in self._pcap_files.values():
            descriptor = retained.get("descriptor")
            if type(descriptor) is int and descriptor not in handled_pcaps:
                with contextlib.suppress(OSError):
                    os.close(descriptor)
        for pin in self._tools.values():
            with contextlib.suppress(OSError):
                os.close(pin.descriptor)
        with contextlib.suppress(OSError):
            os.close(self._execution_mntns_fd)

    def _mark_retention_unknown(self) -> None:
        self._retention_unknown = True
        self._publication_unknown = True
        self._builder._unknown = True

    def _verify_retention_authority(self, *, direct_absence: bool) -> None:
        builder = self._builder
        if (
            self._state != "STOPPED"
            or self._ownership_status != "PASS"
            or self._publication_unknown
        ):
            raise CaptureSecurityError(
                "capture retention requires durable STOPPED authority"
            )
        self._verify_tools()
        self._verify_execution_mount()
        for handle in self._handles:
            self._verify_handle(handle, require_live=False)
        if (
            builder is _TEST_RETENTION_BUILDER
            and getattr(builder._config, "test_only_paths", False) is True
        ):
            proof = builder._verify_retention_authority(
                self, direct_absence=direct_absence
            )
            if proof != {
                "status": "PASS",
                "state": "COMPENSATED",
                "capture": "STOPPED",
            }:
                raise CaptureSecurityError(
                    "focused retention authority proof is invalid"
                )
            return
        if type(builder) is not APPLY.RuntimeBuilder:
            raise CaptureSecurityError("retention requires the canonical builder")
        if any(
            APPLY.RuntimeBuilder.__dict__.get(name) is not implementation
            or name in builder.__dict__
            for name, implementation in _RUNTIME_BUILDER_METHOD_BINDINGS.items()
        ) or (
            APPLY._SESSION_RECORD_EXECUTION_EVENT
            is not _PRODUCER_RECORD_EXECUTION_EVENT
            or APPLY.RUNTIME.AdmissionSession.record_execution_event
            is not _PRODUCER_RECORD_EXECUTION_EVENT
        ):
            raise CaptureSecurityError(
                "retention producer method binding changed"
            )
        _RUNTIME_BUILDER_VERIFY_AUTHORITY(builder)
        _RUNTIME_BUILDER_VERIFY_CAPTURE_CREATOR(builder, self)
        cleanup = builder._cleanup_result
        if (
            builder._state != "COMPENSATED"
            or builder._unknown
            or not isinstance(cleanup, dict)
            or cleanup.get("status") != "PASS"
            or cleanup.get("state") != "COMPENSATED"
            or not isinstance(builder._final_absence, dict)
            or builder._final_absence.get("status") != "PASS"
        ):
            raise CaptureSecurityError(
                "capture retention requires successful compensation"
            )
        if direct_absence:
            final = _RUNTIME_BUILDER_FINAL_ABSENCE(builder)
            captures = final.get("captures") if isinstance(final, dict) else None
            if (
                not isinstance(final, dict)
                or final.get("status") != "PASS"
                or not isinstance(captures, dict)
                or captures.get("state") != "STOPPED"
                or captures.get("ownership_status") != "PASS"
            ):
                raise CaptureSecurityError(
                    "direct final absence did not retain capture authority"
                )

    def _open_retention_parent(self) -> tuple[int, tuple[int, ...]]:
        parent = self._builder._config.evidence_path
        flags = (
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
        try:
            before = parent.lstat()
            descriptor = os.open(parent, flags)
            opened = os.fstat(descriptor)
        except OSError as exc:
            raise CaptureSecurityError(
                "capture evidence parent cannot be pinned"
            ) from exc
        identity = _directory_identity(opened)
        if (
            stat.S_ISLNK(before.st_mode)
            or not stat.S_ISDIR(before.st_mode)
            or _directory_identity(before) != identity
            or opened.st_uid != self._builder._config.required_uid
            or stat.S_IMODE(opened.st_mode) != 0o700
        ):
            os.close(descriptor)
            raise CaptureSecurityError(
                "capture evidence parent identity or mode changed"
            )
        return descriptor, identity

    def _verify_retention_parent(self) -> os.stat_result:
        descriptor = self._retention_parent_fd
        identity = self._retention_parent_identity
        if descriptor is None or identity is None:
            raise CaptureSecurityError("capture evidence parent is not retained")
        try:
            opened = os.fstat(descriptor)
            current = self._builder._config.evidence_path.lstat()
        except OSError as exc:
            raise CaptureSecurityError(
                "capture evidence parent changed"
            ) from exc
        if (
            _directory_identity(opened) != identity
            or _directory_identity(current) != identity
            or stat.S_ISLNK(current.st_mode)
            or not stat.S_ISDIR(current.st_mode)
            or opened.st_uid != self._builder._config.required_uid
            or stat.S_IMODE(opened.st_mode) != 0o700
        ):
            raise CaptureSecurityError("capture evidence parent changed")
        return opened

    def _verify_retention_directory(self) -> os.stat_result:
        parent_fd = self._retention_parent_fd
        descriptor = self._retention_directory_fd
        identity = self._retention_directory_identity
        if parent_fd is None or descriptor is None or identity is None:
            raise CaptureSecurityError("retained capture directory is unavailable")
        try:
            opened = os.fstat(descriptor)
            current = os.stat(
                RETAINED_CAPTURE_DIRECTORY,
                dir_fd=parent_fd,
                follow_symlinks=False,
            )
        except OSError as exc:
            raise CaptureSecurityError(
                "retained capture directory changed"
            ) from exc
        if (
            _directory_identity(opened) != identity
            or _directory_identity(current) != identity
            or stat.S_ISLNK(current.st_mode)
            or not stat.S_ISDIR(current.st_mode)
            or opened.st_uid != self._builder._config.required_uid
            or stat.S_IMODE(opened.st_mode) != 0o700
        ):
            raise CaptureSecurityError("retained capture directory changed")
        return opened

    def _retention_plan(
        self, parent_fd: int
    ) -> tuple[list[dict[str, Any]], int]:
        parent = self._builder._config.evidence_path
        try:
            parent_device = os.fstat(parent_fd).st_dev
        except OSError as exc:
            raise CaptureSecurityError(
                "capture evidence parent device is unavailable"
            ) from exc
        created = {handle.capture_id: handle for handle in self._handles}
        if (
            len(created) != len(self._handles)
            or not set(self._pcap_files).issubset(APPLY.CAPTURE_POINT_IDS)
            or not set(created).issubset(self._pcap_files)
        ):
            raise CaptureSecurityError("capture evidence inventory changed")
        entries: list[dict[str, Any]] = []
        for capture_id in APPLY.CAPTURE_POINT_IDS:
            name = capture_id + ".pcap"
            handle = created.get(capture_id)
            retained = self._pcap_files.get(capture_id)
            if retained is None:
                if handle is not None:
                    raise CaptureSecurityError(
                        "capture PCAP custody changed: " + capture_id
                    )
                _absent_at(
                    parent_fd,
                    name,
                    "never-created capture evidence " + capture_id,
                )
                continue
            descriptor = retained.get("descriptor")
            original_identity = retained.get("identity")
            launched = retained.get("launched")
            final_identity = retained.get("final_identity")
            digest = retained.get("sha256")
            if (
                type(descriptor) is not int
                or not isinstance(original_identity, tuple)
                or launched is not (handle is not None)
                or not isinstance(final_identity, tuple)
                or type(digest) is not str
            ):
                raise CaptureSecurityError(
                    "final capture evidence identity is unavailable: " + capture_id
                )
            if handle is not None:
                self._verify_handle(handle, require_live=False)
                if (
                    descriptor != handle.pcap_fd
                    or original_identity != handle.pcap_identity
                    or final_identity != handle.final_pcap_identity
                    or digest != handle.final_pcap_sha256
                ):
                    raise CaptureSecurityError(
                        "capture PCAP custody changed: " + capture_id
                    )
            elif self._slots[capture_id]["pid"] is not None:
                raise CaptureSecurityError(
                    "unlaunched capture evidence has a PID: " + capture_id
                )
            try:
                opened = os.fstat(descriptor)
                current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            except OSError as exc:
                raise CaptureSecurityError(
                    "capture evidence path changed: " + capture_id
                ) from exc
            identity = _retained_file_identity(opened)
            if (
                _fd_identity(opened) != original_identity
                or identity != final_identity
                or _retained_file_identity(current) != identity
                or identity[0] != parent_device
                or not stat.S_ISREG(opened.st_mode)
                or opened.st_uid != self._builder._config.required_uid
                or stat.S_IMODE(opened.st_mode) != 0o600
                or _sha256(_read_fd(descriptor, CAPTURE_MAX_BYTES)) != digest
            ):
                raise CaptureSecurityError(
                    "capture evidence path or bytes changed: " + capture_id
                )
            entries.append(
                {
                    "id": capture_id,
                    "name": name,
                    "source_path": str(parent / name),
                    "destination_path": str(
                        parent / RETAINED_CAPTURE_DIRECTORY / name
                    ),
                    "descriptor": descriptor,
                    "maximum": CAPTURE_MAX_BYTES,
                    "identity": identity,
                    "sha256": digest,
                    "location": "source",
                }
            )

        pid_path = pathlib.Path(self._contract["pid_journal"]["path"])
        pid_name = APPLY.CAPTURE_PID_NAME
        if (
            pid_path != parent / pid_name
            or self._published_state != "STOPPED"
            or self._pid_raw is None
            or _sha256(self._pid_raw) != self._pid_sha256
            or self._pid_raw != _canonical(self._pid_document("STOPPED"))
        ):
            raise CaptureSecurityError("current STOPPED PID receipt changed")
        flags = (
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
        pid_fd: int | None = None
        try:
            pid_fd = os.open(pid_name, flags, dir_fd=parent_fd)
            opened = os.fstat(pid_fd)
            current = os.stat(pid_name, dir_fd=parent_fd, follow_symlinks=False)
            raw = _read_fd(pid_fd, 1024 * 1024)
        except BaseException:
            if pid_fd is not None:
                with contextlib.suppress(OSError):
                    os.close(pid_fd)
            raise
        if pid_fd is None:
            raise CaptureSecurityError("current STOPPED PID receipt is unavailable")
        identity = _retained_file_identity(opened)
        if (
            _retained_file_identity(current) != identity
            or identity[0] != parent_device
            or not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != self._builder._config.required_uid
            or stat.S_IMODE(opened.st_mode) != 0o600
            or raw != self._pid_raw
            or _sha256(raw) != self._pid_sha256
        ):
            os.close(pid_fd)
            raise CaptureSecurityError("current STOPPED PID receipt changed")
        entries.append(
            {
                "id": "capture-pid-journal",
                "name": pid_name,
                "source_path": str(pid_path),
                "destination_path": str(
                    parent / RETAINED_CAPTURE_DIRECTORY / pid_name
                ),
                "descriptor": pid_fd,
                "maximum": 1024 * 1024,
                "identity": identity,
                "sha256": self._pid_sha256,
                "location": "source",
            }
        )
        if not 1 <= len(entries) <= len(APPLY.CAPTURE_POINT_IDS) + 1:
            os.close(pid_fd)
            raise CaptureSecurityError("retained capture inventory is invalid")
        return entries, pid_fd

    @staticmethod
    def _retention_event_files(
        entries: Sequence[Mapping[str, Any]], *, completed: bool
    ) -> list[dict[str, Any]]:
        return [
            {
                "id": entry["id"],
                "source_path": entry["source_path"],
                "destination_path": entry["destination_path"],
                "source_identity": _retained_identity_document(entry["identity"]),
                "expected_destination_identity": _retained_identity_document(
                    entry["identity"]
                ),
                "destination_identity": (
                    _retained_identity_document(entry["identity"])
                    if completed
                    else None
                ),
                "source_state": "ABSENT" if completed else "PRESENT",
                "destination_state": "VERIFIED" if completed else "ABSENT",
                "sha256": entry["sha256"],
            }
            for entry in entries
        ]

    def _record_retention_event(
        self, event: str, status: str, entries: Sequence[Mapping[str, Any]]
    ) -> dict[str, Any]:
        detail = {
            "stage": event.removeprefix("x05-"),
            "status": status,
            "operation": "capture-evidence-retention",
            "resource_ids": [entry["id"] for entry in entries],
            "directory": str(
                self._builder._config.evidence_path
                / RETAINED_CAPTURE_DIRECTORY
            ),
            "files": self._retention_event_files(
                entries, completed=status == "VERIFIED"
            ),
        }
        builder = self._builder
        if (
            builder is _TEST_RETENTION_BUILDER
            and getattr(builder._config, "test_only_paths", False) is True
        ):
            return builder._record_retention_event(self, event, detail)
        if (
            type(builder) is not APPLY.RuntimeBuilder
            or APPLY.RUNTIME.AdmissionSession.record_execution_event
            is not _PRODUCER_RECORD_EXECUTION_EVENT
        ):
            raise CaptureSecurityError("retention event authority changed")
        record = _PRODUCER_RECORD_EXECUTION_EVENT(
            builder._session,
            builder._prepared,
            event,
            detail,
        )
        if (
            not isinstance(record, dict)
            or record.get("event") != event
            or record.get("event_sha256") != builder._prepared._event_head
            or record.get("sequence") != builder._prepared._event_count
            or not isinstance(record.get("detail"), dict)
            or record["detail"].get("detail") != detail
        ):
            raise CaptureAmbiguous("capture retention event outcome is unknown")
        return record

    def _refresh_retained_locations(
        self, entries: Sequence[dict[str, Any]]
    ) -> None:
        parent_fd = self._retention_parent_fd
        directory_fd = self._retention_directory_fd
        if parent_fd is None:
            return
        for entry in entries:
            locations: list[str] = []
            for label, descriptor in (
                ("source", parent_fd),
                ("retained", directory_fd),
            ):
                if descriptor is None:
                    continue
                try:
                    current = os.stat(
                        entry["name"],
                        dir_fd=descriptor,
                        follow_symlinks=False,
                    )
                except OSError:
                    continue
                if _retained_file_identity(current) == entry["identity"]:
                    locations.append(label)
            entry["location"] = locations[0] if len(locations) == 1 else "unknown"
        if self._retained_locations is not None:
            by_id = {entry["id"]: entry for entry in entries}
            for item in self._retained_locations["files"]:
                item["location"] = by_id[item["id"]]["location"]

    def _verify_retention_files(
        self,
        entries: Sequence[dict[str, Any]],
        *,
        readback: bool,
    ) -> None:
        parent_fd = self._retention_parent_fd
        if parent_fd is None:
            raise CaptureSecurityError("capture evidence parent is unavailable")
        self._verify_retention_parent()
        if self._retention_directory_fd is not None:
            self._verify_retention_directory()
        for entry in entries:
            try:
                opened = os.fstat(entry["descriptor"])
            except OSError as exc:
                raise CaptureSecurityError(
                    "retained original descriptor changed: " + entry["id"]
                ) from exc
            if _retained_file_identity(opened) != entry["identity"]:
                raise CaptureSecurityError(
                    "retained original descriptor changed: " + entry["id"]
                )
            if entry["location"] == "source":
                directory = parent_fd
                other = self._retention_directory_fd
            elif entry["location"] == "retained":
                directory = self._retention_directory_fd
                other = parent_fd
            else:
                raise CaptureSecurityError(
                    "retained capture location is unknown: " + entry["id"]
                )
            if directory is None:
                raise CaptureSecurityError(
                    "retained capture directory is unavailable"
                )
            try:
                current = os.stat(
                    entry["name"],
                    dir_fd=directory,
                    follow_symlinks=False,
                )
            except OSError as exc:
                raise CaptureSecurityError(
                    "retained capture path changed: " + entry["id"]
                ) from exc
            if _retained_file_identity(current) != entry["identity"]:
                raise CaptureSecurityError(
                    "retained capture path changed: " + entry["id"]
                )
            if other is not None:
                _absent_at(
                    other,
                    entry["name"],
                    "opposite retained capture path " + entry["id"],
                )
            if readback:
                flags = (
                    os.O_RDONLY
                    | getattr(os, "O_CLOEXEC", 0)
                    | getattr(os, "O_NOFOLLOW", 0)
                )
                descriptor: int | None = None
                try:
                    descriptor = os.open(entry["name"], flags, dir_fd=directory)
                    verified = os.fstat(descriptor)
                    raw = _read_fd(descriptor, entry["maximum"])
                except OSError as exc:
                    raise CaptureSecurityError(
                        "retained capture readback failed: " + entry["id"]
                    ) from exc
                finally:
                    if descriptor is not None:
                        with contextlib.suppress(OSError):
                            os.close(descriptor)
                if (
                    _retained_file_identity(verified) != entry["identity"]
                    or _sha256(raw) != entry["sha256"]
                ):
                    raise CaptureSecurityError(
                        "retained capture bytes changed: " + entry["id"]
                    )

    def _verify_all_active_capture_paths_absent(self, parent_fd: int) -> None:
        for capture_id in APPLY.CAPTURE_POINT_IDS:
            _absent_at(
                parent_fd,
                capture_id + ".pcap",
                "active capture evidence " + capture_id,
            )
        _absent_at(
            parent_fd,
            APPLY.CAPTURE_PID_NAME,
            "active capture PID receipt",
        )

    @staticmethod
    def _close_proved_descriptor(
        descriptor: int, identity: tuple[int, ...], context: str
    ) -> None:
        try:
            current = os.fstat(descriptor)
        except OSError as exc:
            raise CaptureSecurityError(context + " descriptor changed") from exc
        if _fd_identity(current) != identity[:2]:
            raise CaptureSecurityError(context + " descriptor changed")
        os.close(descriptor)

    def _close_after_retention(
        self, entries: Sequence[dict[str, Any]]
    ) -> None:
        self._verify_tools()
        self._verify_execution_mount()
        for handle in self._handles:
            self._verify_handle(handle, require_live=False)
        descriptors: list[tuple[int, tuple[int, ...], str]] = []
        for handle in self._handles:
            for descriptor, identity, label in (
                (handle.pidfd, handle.pidfd_identity, "capture pidfd"),
                (
                    handle.pidfd_guard,
                    handle.pidfd_guard_identity,
                    "capture pidfd guard",
                ),
                (handle.pcap_fd, handle.pcap_identity, "capture PCAP"),
                (
                    handle.pcap_guard,
                    handle.pcap_guard_identity,
                    "capture PCAP guard",
                ),
            ):
                if descriptor is not None:
                    if identity is None:
                        raise CaptureSecurityError(label + " identity is unavailable")
                    descriptors.append((descriptor, identity, label))
        launched_pcaps = {handle.pcap_fd for handle in self._handles}
        for capture_id, retained in self._pcap_files.items():
            descriptor = retained.get("descriptor")
            identity = retained.get("identity")
            if descriptor in launched_pcaps:
                continue
            if type(descriptor) is not int or not isinstance(identity, tuple):
                raise CaptureSecurityError(
                    "unlaunched PCAP descriptor is unavailable: " + capture_id
                )
            descriptors.append(
                (descriptor, identity, "unlaunched capture PCAP " + capture_id)
            )
        descriptors.extend(
            (
                pin.descriptor,
                pin.identity,
                "capture tool " + pin.name,
            )
            for pin in self._tools.values()
        )
        descriptors.append(
            (
                self._execution_mntns_fd,
                self._execution_mntns_identity,
                "capture execution mount",
            )
        )
        pid_identity = next(
            (
                entry["identity"]
                for entry in entries
                if entry["id"] == "capture-pid-journal"
            ),
            None,
        )
        for descriptor, identity, label in (
            (
                self._retention_pid_fd,
                pid_identity,
                "retained PID receipt",
            ),
            (
                self._retention_parent_fd,
                self._retention_parent_identity,
                "capture evidence parent",
            ),
            (
                self._retention_directory_fd,
                self._retention_directory_identity,
                "retained capture directory",
            ),
        ):
            if descriptor is None or identity is None:
                raise CaptureSecurityError(label + " descriptor is unavailable")
            descriptors.append((descriptor, identity, label))
        numbers = [descriptor for descriptor, _identity, _label in descriptors]
        stderr_descriptors = [
            (self._verify_stderr(handle), handle.stderr_identity, handle)
            for handle in self._handles
        ]
        stderr_numbers = [
            descriptor for descriptor, _identity, _handle in stderr_descriptors
        ]
        all_numbers = numbers + stderr_numbers
        if len(all_numbers) != len(set(all_numbers)):
            raise CaptureSecurityError("capture descriptor inventory overlaps")
        protected: set[int] = set()
        if type(self._builder) is APPLY.RuntimeBuilder:
            protected = {
                descriptor
                for descriptor in (
                    self._builder._session._lock_fd,
                    self._builder._session._lock_keeper_fd,
                )
                if isinstance(descriptor, int)
            }
        if protected.intersection(all_numbers):
            raise CaptureSecurityError(
                "capture descriptor overlaps producer lock authority"
            )
        for descriptor, identity, label in descriptors:
            current = os.fstat(descriptor)
            if _fd_identity(current) != identity[:2]:
                raise CaptureSecurityError(label + " descriptor changed")
        for descriptor, identity, handle in stderr_descriptors:
            if (
                self._verify_stderr(handle) != descriptor
                or handle.stderr_identity != identity
            ):
                raise CaptureSecurityError("capture stderr descriptor changed")
        for descriptor, identity, label in descriptors:
            self._close_proved_descriptor(descriptor, identity, label)
        for descriptor, identity, handle in stderr_descriptors:
            if (
                self._verify_stderr(handle) != descriptor
                or handle.stderr_identity != identity
            ):
                raise CaptureSecurityError("capture stderr descriptor changed")
            handle.stderr_receiver.close()
        self._retention_pid_fd = None
        self._retention_parent_fd = None
        self._retention_directory_fd = None

    def _release_after_compensation(self) -> dict[str, Any]:
        if self._builder._state != "COMPENSATED" or self._released:
            raise CaptureSecurityError("capture descriptors cannot be released yet")
        if self._retention_started or self._retention_unknown:
            raise CaptureSecurityError("capture retention is one-shot")
        if any(
            CaptureSession.__dict__.get(name) is not implementation
            or name in self.__dict__
            for name, implementation in _CAPTURE_SESSION_METHOD_BINDINGS.items()
        ):
            self._retention_unknown = True
            self._publication_unknown = True
            self._builder._unknown = True
            raise CaptureSecurityError("capture retention method binding changed")
        for handle in self._handles:
            if handle.process.returncode is None:
                raise CaptureSecurityError("live capture cannot release descriptors")

        builder = self._builder
        lock = getattr(builder, "_consume_lock", None)
        if lock is None:
            raise CaptureSecurityError("capture retention mutex is unavailable")
        entries: list[dict[str, Any]] = []
        parent_fd: int | None = None
        pid_fd: int | None = None
        try:
            with lock:
                try:
                    self._verify_retention_authority(direct_absence=True)
                    parent_fd, parent_identity = self._open_retention_parent()
                    entries, pid_fd = self._retention_plan(parent_fd)
                except BaseException:
                    self._mark_retention_unknown()
                    raise
                _absent_at(
                    parent_fd,
                    RETAINED_CAPTURE_DIRECTORY,
                    "retained capture directory",
                )
                self._retention_parent_fd = parent_fd
                self._retention_parent_identity = parent_identity
                self._retention_pid_fd = pid_fd
                self._retained_locations = {
                    "directory": str(
                        builder._config.evidence_path
                        / RETAINED_CAPTURE_DIRECTORY
                    ),
                    "status": "INTENT",
                    "files": [
                        {
                            "id": entry["id"],
                            "source_path": entry["source_path"],
                            "destination_path": entry["destination_path"],
                            "identity": _retained_identity_document(
                                entry["identity"]
                            ),
                            "sha256": entry["sha256"],
                            "location": "source",
                        }
                        for entry in entries
                    ],
                }
                self._retention_started = True
                self._record_retention_event(
                    "x05-capture-retention-intent", "INTENT", entries
                )
                _fault(builder._config, "retention-after-intent")
                self._verify_retention_authority(direct_absence=False)
                self._verify_retention_files(entries, readback=False)
                _absent_at(
                    parent_fd,
                    RETAINED_CAPTURE_DIRECTORY,
                    "retained capture directory",
                )
                os.mkdir(
                    RETAINED_CAPTURE_DIRECTORY,
                    0o700,
                    dir_fd=parent_fd,
                )
                flags = (
                    os.O_RDONLY
                    | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_CLOEXEC", 0)
                    | getattr(os, "O_NOFOLLOW", 0)
                )
                directory_fd = os.open(
                    RETAINED_CAPTURE_DIRECTORY,
                    flags,
                    dir_fd=parent_fd,
                )
                directory_info = os.fstat(directory_fd)
                self._retention_directory_fd = directory_fd
                self._retention_directory_identity = _directory_identity(
                    directory_info
                )
                if (
                    directory_info.st_dev != parent_identity[0]
                    or directory_info.st_uid != builder._config.required_uid
                    or stat.S_IMODE(directory_info.st_mode) != 0o700
                ):
                    raise CaptureSecurityError(
                        "retained capture directory is not same-filesystem private"
                    )
                self._verify_retention_directory()
                os.fsync(parent_fd)
                _fault(builder._config, "retention-after-directory-fsync")

                for entry in entries:
                    self._verify_retention_authority(direct_absence=False)
                    self._verify_retention_files(entries, readback=False)
                    _absent_at(
                        directory_fd,
                        entry["name"],
                        "retained capture destination " + entry["id"],
                    )
                    _rename_noreplace(
                        parent_fd,
                        entry["name"],
                        directory_fd,
                        entry["name"],
                    )
                    entry["location"] = "retained"
                    self._refresh_retained_locations(entries)
                    _fault(
                        builder._config,
                        "retention-after-rename-" + entry["id"],
                    )
                    _fault(
                        builder._config,
                        "retention-before-source-fsync-" + entry["id"],
                    )
                    os.fsync(parent_fd)
                    _fault(
                        builder._config,
                        "retention-before-destination-fsync-" + entry["id"],
                    )
                    os.fsync(directory_fd)
                    self._verify_retention_files(entries, readback=False)

                self._verify_all_active_capture_paths_absent(parent_fd)
                self._verify_retention_files(entries, readback=True)
                os.fsync(parent_fd)
                os.fsync(directory_fd)
                self._verify_retention_authority(direct_absence=False)
                for handle in self._handles:
                    self._verify_handle(handle, require_live=False)
                self._record_retention_event(
                    "x05-capture-retention-complete", "VERIFIED", entries
                )
                self._retention_complete = True
                if self._retained_locations is None:
                    raise CaptureAmbiguous(
                        "capture retention location map is unavailable"
                    )
                self._retained_locations["status"] = "VERIFIED"
                self._verify_retention_authority(direct_absence=False)
                self._verify_all_active_capture_paths_absent(parent_fd)
                self._verify_retention_files(entries, readback=False)
                self._close_after_retention(entries)
                self._released = True
                return {"status": "PASS", "released": True}
        except BaseException:
            if self._retention_started:
                self._mark_retention_unknown()
                self._refresh_retained_locations(entries)
                if self._retained_locations is not None:
                    self._retained_locations["status"] = "UNKNOWN"
                for descriptor in (
                    self._retention_parent_fd,
                    self._retention_directory_fd,
                ):
                    if descriptor is not None:
                        with contextlib.suppress(OSError):
                            os.fsync(descriptor)
            else:
                for descriptor in (pid_fd, parent_fd):
                    if descriptor is not None:
                        with contextlib.suppress(OSError):
                            os.close(descriptor)
            raise


_POPEN_CLASS = subprocess.Popen
_CAPTURE_SESSION_START = CaptureSession.start
_CAPTURE_SESSION_HEALTH = CaptureSession.health
_CAPTURE_SESSION_STOP = CaptureSession.stop
_CAPTURE_SESSION_READ_OWNED = CaptureSession._read_owned_pcaps
_CAPTURE_SESSION_RELEASE = CaptureSession._release_after_compensation
_CAPTURE_SESSION_METHOD_BINDINGS = {
    name: value
    for name, value in CaptureSession.__dict__.items()
    if callable(value) or isinstance(value, (staticmethod, classmethod))
}


def _dry_description() -> dict[str, Any]:
    return {
        "schema": "p004-x05-capture-dry-run-v1",
        "status": "DRY_RUN",
        "live_enabled": False,
        "capture_points": list(APPLY.CAPTURE_POINT_IDS),
        "continuous_processes": 5,
        "pcap_linktype": DLT_LINUX_SLL2,
        "filter": "fixed SLL2 link[4:4] ifindex-only expression",
        "startup_seconds": CAPTURE_STARTUP_SECONDS,
        "lifetime_seconds": CAPTURE_LIFETIME_SECONDS,
        "maximum_bytes_per_pcap": CAPTURE_MAX_BYTES,
        "maximum_packets_per_pcap": CAPTURE_MAX_PACKETS,
        "stop_phases": [
            {"signal": signum.name, "seconds": seconds}
            for signum, seconds in STOP_PHASES
        ],
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Reviewed X05 creator-owned capture library (live CLI disabled)."
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args(argv)
    if args.execute:
        print(
            "X05 capture live CLI is disabled; use the admitted coordinator",
            file=sys.stderr,
        )
        return 75
    print(json.dumps(_dry_description(), sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
