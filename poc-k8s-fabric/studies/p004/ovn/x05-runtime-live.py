#!/usr/bin/env python3
"""Read-only G0/G0a admission collector for X05.

The public Python API is usable by the future coordinator.  The command-line
live path deliberately remains disabled until that integration is reviewed.
All authorization reads and the temporary M03 lifecycle run while FD 9 owns
the canonical labctl lock.  The collector only observes the frozen runtime
plan; it does not contain a second resource registry.

A serialized snapshot is schema-checked evidence, never mutation authority.
Authority is the uncopyable ``PreparedAdmission`` returned to its originating
live session, consumed once, and revalidated by the continuing-execution API
while canonical FD 9 is held.  That boundary assumes every cooperating
lifecycle actor takes the same flock; it cannot make reads atomic against a
privileged writer that bypasses it.
"""

from __future__ import annotations

import argparse
import copy
import dataclasses
import datetime as dt
import errno
import fcntl
import hashlib
import importlib.util
import json
import math
import os
import pathlib
import re
import selectors
import signal
import socket
import stat
import subprocess
import sys
import threading
import time
import types
from collections.abc import Callable, Mapping, Sequence
from typing import Any, Protocol


# Loading the frozen local helpers must not create __pycache__ artifacts. This
# keeps the disabled CLI dry-run read-only even when the caller did not export
# PYTHONDONTWRITEBYTECODE.
sys.dont_write_bytecode = True


HERE = pathlib.Path(__file__).resolve().parent
PREFLIGHT_PATH = HERE / "x05-runtime-preflight.py"
PLAN_PATH = HERE / "x05-runtime-plan.py"
DEFAULT_LOCK = pathlib.Path("/var/lock/labctl-mgc-m03.lock")
DEFAULT_STATE = pathlib.Path("/var/lib/labctl/mgc.json")
DEFAULT_M03_MARKER = pathlib.Path("/run/labctl/mgc-m03/active")
DEFAULT_X05_MARKER = pathlib.Path("/run/labctl/mgc-x05/active")
DEFAULT_BUNDLE_ROOT = pathlib.Path("/opt/poc-k8s-fabric")
DEFAULT_LABCTL = DEFAULT_BUNDLE_ROOT / "labctl"
BASE_ENV = {
    "HOME": "/root",
    "LANG": "C",
    "LC_ALL": "C",
    "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
}
MUTABLE_IMAGE_TAGS = ("frrouting/frr:v8.4.1", "ovn/ovn-multi-node:latest")
RECEIPT_KEYS = {
    "k01_uid",
    "p003_gw_uid",
    "k01_canary",
    "p003_gw_canary",
    "timestamp",
    "host",
    "runtime_source_sha256",
}
UID_RE = re.compile(r"^[A-Za-z0-9-]+$")
RUN_RE = re.compile(r"^[0-9a-f]{6}$")
IMAGE_ID_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
CONTAINER_ID_RE = re.compile(r"^[0-9a-f]{64}$")
MAX_OUTPUT = 16 * 1024 * 1024
EXECUTION_EVENT_RE = re.compile(r"^x05-[a-z0-9]+(?:-[a-z0-9]+)*$")
EXECUTION_EVENT_MAX_LENGTH = 96
EXECUTION_DETAIL_MAX_BYTES = 64 * 1024
EXECUTION_DETAIL_MAX_DEPTH = 8
EXECUTION_DETAIL_MAX_ITEMS = 1024
EXECUTION_RESERVED_DETAIL_KEYS = frozenset(
    {
        "admission",
        "anchors_sha256",
        "bundle_manifest_sha256",
        "event_count",
        "event_head_sha256",
        "evidence_path",
        "inputs_sha256",
        "owner",
        "producer",
        "run_hex",
        "snapshot_file_sha256",
        "snapshot_path",
        "snapshot_sha256",
    }
)
REVIEWED_BUNDLE_FILES = {
    "labctl": "843cf96ad857087ec7e98b4cbc0d578d5b868763ca15599d23460cd1f8d3132d",
    "lib/common.sh": "7faf46fecf1834a14b09d861ee1b996f5832a3adf239758799188220dff8bfd4",
    "labs/mgc.sh": "c24962a4382b9f905a448a2621bdf0a5ef0167a12147563a0509c224a33d92bc",
    "studies/p004/ovn/m03.sh": "9bde10234f54cfd3ebcc32ba88a5b60134a195c7b22f8c309eae475c63d5552c",
    "studies/p004/ovn/nb-topology.sh": "48f6abc236ba3803aca88f2f2b7a2b287afc6619812366246e3f52a19807a7aa",
    "studies/p004/ovn/frr-client.conf": "5b4cd244ae1917832f7e8825e0fc6a414f0db53bc08c72ed0dd4d6541d679445",
    "studies/p004/ovn/frr-m03-chassis.conf": "f84c2680e2457ed5d070ef031842f5c9d8dddbff3c4b1fa94aba92d33f3d5497",
    "studies/p004/ovn/frr-m03-client.conf": "5951dda0687c1a847bda61c14fe5135bac014f61c21c02a016d4621998d93206",
    "studies/p004/ovn/x05-runtime-plan.py": "78dd13d8a156611de0ac8088bc244bcbd9c78d22caba552eee53e2edc2efef46",
    "studies/p004/ovn/x05-runtime-preflight.py": "f79f1b731cd3c8072f8658a660cea748a953ec9fa6a53fec4e747d0228d0b97c",
    "studies/p004/ovn/x05-runtime-apply.py": "4b01a3f3571b66ef51e36a280d6ecddc754cf1ecfa26c0c9a9a06c9757acddc1",
    "studies/p004/ovn/x05-capture.py": "2315c7416a6d32880bf276cb3c4d1b20cc5c3f1dc70b6d7f46ec37fd1c048287",
    "studies/p004/ovn/x05-evaluator.py": "95a1afc99a06d26d518a8fbf9d755ffc5ed9b4e37d873ad14bbe6a71f6702dac",
    "studies/p004/ovn/x05-nb-live.py": "cbe6000bca6698e2fe7b71bb07bd5676e68a45925917195793d46840a0dd3141",
    "studies/p004/ovn/x05-coordinator.py": "584bf99c4ade986033679f564f9e83a0030702a25001a700b6e07259d59906d3",
    "studies/p004/ovn/x05-cas.sh": "13081eaf3f66071f6dfef238b423449fe161df2002bc7642e3c1635d6baf162d",
    "studies/p004/ovn/frr-gw1.conf": "8ea15ebfc376e36b980586471e6532cb54cd26b6e8e2295363dbc2762bb40655",
    "studies/p004/ovn/frr-gw2.conf": "df039572ba709947239b94e8a7512864fc09e48cfc9d4effa4f4e785b4f3bfb9",
    "studies/p004/ovn/x05-gw1-add.conf": "4d30657f0b6af7f88c0ccc3e964d26d5f20d4e1938d54cb56a531b71510533d7",
    "studies/p004/ovn/x05-gw1-remove.conf": "3cc0890efe0e98f999370ee53456c97e3ba575865fbe7862807cb4b76ef64014",
    "studies/p004/ovn/x05-gw2-add.conf": "6ce1142b5bd8063a320c4d8224278106ec93a48f78a941fad4b6dd3d7e50291f",
    "studies/p004/ovn/x05-gw2-remove.conf": "c4689cfef5306d0d29aff77986041d98753a7ec494ab2d08c9ca845b52b9921e",
    "studies/p004/ovn/x05-client2.conf": "73cb785be4beb61693de52e33440ade774b4d4cb66fa51f06e86703e9583ced9",
    "studies/p004/ovn/x05-chassis.conf": "9ec32352c308f090362e02e44ce5e725baaa3cda74dbf79b71092e3e0da3cfce",
    "studies/p004/ovn/x05-peer.conf": "9fc6033e407e85f9d03f89c77fedf31a1ac777ed938f06a75737167f969e39de",
}
REVIEWED_BUNDLE_MANIFEST_SHA256 = (
    "66e152b599798519d749c222d172ac42ff52f9542d2263726120202476f675a9"
)


def _load_module(name: str, path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise AdmissionError(f"cannot load {path.name}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PREFLIGHT = None
PLAN = None


def load_local_test_modules() -> None:
    """Load local helpers only for explicit dry-run and test entry points."""
    global PREFLIGHT, PLAN
    if PREFLIGHT is None:
        PREFLIGHT = _load_module("x05_runtime_preflight_live", PREFLIGHT_PATH)
    if PLAN is None:
        PLAN = _load_module("x05_runtime_plan_live", PLAN_PATH)


class AdmissionError(RuntimeError):
    """A readback cannot prove safe admission."""


class AdmissionIncident(AdmissionError):
    """Cleanup was uncertain or failed and durable incident evidence remains."""


class CommandTimeout(AdmissionError):
    """A bounded command and its process group did not finish in time."""


class RetainedDescriptorIncident(CommandTimeout):
    """A detached descendant retained command pipes and possibly inherited FDs."""


class CommandOutputLimit(AdmissionError):
    """A command exceeded the bounded stdout or stderr allocation."""


LOCK_FDINFO_MAX_BYTES = 4096
_LOCK_FDINFO_LINE_COUNT = 5
_MAX_PID = (1 << 31) - 1
_MAX_U32 = (1 << 32) - 1
_MAX_U64 = (1 << 64) - 1
_LOCK_FDINFO_LINE_RE = re.compile(
    r"lock:\t(?P<counter>[1-9][0-9]*): FLOCK  ADVISORY  "
    r"(?P<mode>WRITE|READ|UNLCK) (?P<pid>[1-9][0-9]*) "
    r"(?P<major>[0-9a-f]{2,8}):(?P<minor>[0-9a-f]{2,8}):"
    r"(?P<inode>[1-9][0-9]*) 0 EOF"
)


class _LockFdinfoError(AdmissionError):
    """A Linux fdinfo record cannot prove the expected exclusive flock."""

    def __init__(
        self,
        message: str,
        *,
        exclusive_flock_observed: bool | None = None,
    ) -> None:
        super().__init__(message)
        self.exclusive_flock_observed = exclusive_flock_observed


@dataclasses.dataclass(frozen=True)
class _LockFdinfo:
    position: int
    flags: int
    mount_id: int
    inode: int
    lock_counter: int
    lock_pid: int
    device_major: int
    device_minor: int
    lock_inode: int


def _bounded_uint(text: str, *, base: int, maximum: int, field: str) -> int:
    try:
        value = int(text, base)
    except ValueError as exc:
        raise _LockFdinfoError(f"M03 lock fdinfo {field} is not numeric") from exc
    if value < 0 or value > maximum:
        raise _LockFdinfoError(f"M03 lock fdinfo {field} is out of range")
    return value


def _parse_lock_fdinfo(data: bytes) -> _LockFdinfo:
    """Parse the closed Linux 6.8 regular-file fdinfo grammar used by G0."""
    if len(data) > LOCK_FDINFO_MAX_BYTES:
        raise _LockFdinfoError("M03 lock fdinfo exceeded the read limit")
    if not data.endswith(b"\n"):
        raise _LockFdinfoError("M03 lock fdinfo is truncated")
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError as exc:
        raise _LockFdinfoError("M03 lock fdinfo is not ASCII") from exc
    if "\r" in text or "\x00" in text:
        raise _LockFdinfoError("M03 lock fdinfo contains unsupported controls")
    lines = text[:-1].split("\n")
    if len(lines) not in (_LOCK_FDINFO_LINE_COUNT - 1, _LOCK_FDINFO_LINE_COUNT):
        raise _LockFdinfoError("M03 lock fdinfo has an unexpected line count")

    patterns = (
        (r"pos:\t(0|[1-9][0-9]*)", "position", 10, _MAX_U64),
        (r"flags:\t(0[0-7]+)", "flags", 8, _MAX_U32),
        (r"mnt_id:\t([1-9][0-9]*)", "mount ID", 10, _MAX_PID),
        (r"ino:\t([1-9][0-9]*)", "inode", 10, _MAX_U64),
    )
    values: list[int] = []
    for line, (pattern, field, base, maximum) in zip(lines[:4], patterns, strict=True):
        match = re.fullmatch(pattern, line)
        if match is None:
            raise _LockFdinfoError(
                f"M03 lock fdinfo has malformed or duplicate {field}"
            )
        values.append(
            _bounded_uint(match.group(1), base=base, maximum=maximum, field=field)
        )
    position, flags, mount_id, inode = values
    if position != 0:
        raise _LockFdinfoError("M03 lock fdinfo position is not zero")
    if flags & os.O_ACCMODE != os.O_RDWR:
        raise _LockFdinfoError("M03 lock fdinfo is not open read-write")
    if len(lines) == _LOCK_FDINFO_LINE_COUNT - 1:
        raise _LockFdinfoError(
            "M03 lock fdinfo has no flock record",
            exclusive_flock_observed=False,
        )

    lock_match = _LOCK_FDINFO_LINE_RE.fullmatch(lines[4])
    if lock_match is None:
        raise _LockFdinfoError("M03 lock fdinfo has an unsupported lock record")
    if lock_match.group("mode") != "WRITE":
        raise _LockFdinfoError(
            "M03 lock fdinfo does not show an exclusive flock",
            exclusive_flock_observed=False,
        )
    return _LockFdinfo(
        position=position,
        flags=flags,
        mount_id=mount_id,
        inode=inode,
        lock_counter=_bounded_uint(
            lock_match.group("counter"),
            base=10,
            maximum=_MAX_U64,
            field="lock counter",
        ),
        lock_pid=_bounded_uint(
            lock_match.group("pid"),
            base=10,
            maximum=_MAX_PID,
            field="lock PID",
        ),
        device_major=_bounded_uint(
            lock_match.group("major"),
            base=16,
            maximum=_MAX_U32,
            field="lock device major",
        ),
        device_minor=_bounded_uint(
            lock_match.group("minor"),
            base=16,
            maximum=_MAX_U32,
            field="lock device minor",
        ),
        lock_inode=_bounded_uint(
            lock_match.group("inode"),
            base=10,
            maximum=_MAX_U64,
            field="lock inode",
        ),
    )


def _read_lock_fdinfo_bytes(descriptor: int) -> bytes:
    """Read one fixed procfs fdinfo record to EOF without touching flock state."""
    if sys.platform != "linux":
        raise _LockFdinfoError(
            "M03 lock observation requires Linux procfs fdinfo"
        )
    if type(descriptor) is not int or descriptor < 0:
        raise _LockFdinfoError("M03 lock descriptor number is invalid")
    try:
        open_flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
    except AttributeError as exc:
        raise _LockFdinfoError(
            "M03 lock observation lacks required Linux open flags"
        ) from exc
    path = f"/proc/self/fdinfo/{descriptor}"
    try:
        stream = os.open(path, open_flags)
    except OSError as exc:
        raise _LockFdinfoError("M03 lock fdinfo is unavailable") from exc
    try:
        info = os.fstat(stream)
        if not stat.S_ISREG(info.st_mode):
            raise _LockFdinfoError("M03 lock fdinfo is not a regular proc file")
        data = bytearray()
        while True:
            remaining = LOCK_FDINFO_MAX_BYTES + 1 - len(data)
            if remaining <= 0:
                raise _LockFdinfoError("M03 lock fdinfo exceeded the read limit")
            chunk = os.read(stream, min(1024, remaining))
            if not chunk:
                break
            data.extend(chunk)
            if len(data) > LOCK_FDINFO_MAX_BYTES:
                raise _LockFdinfoError("M03 lock fdinfo exceeded the read limit")
        return bytes(data)
    except OSError as exc:
        raise _LockFdinfoError("M03 lock fdinfo could not be read to EOF") from exc
    finally:
        os.close(stream)


def _observe_lock_fdinfo(descriptor: int) -> _LockFdinfo:
    return _parse_lock_fdinfo(_read_lock_fdinfo_bytes(descriptor))


@dataclasses.dataclass(frozen=True)
class CommandResult:
    argv: tuple[str, ...]
    returncode: int
    stdout: bytes
    stderr: bytes
    elapsed: float


class Runner(Protocol):
    def run(
        self,
        argv: Sequence[str],
        *,
        env: Mapping[str, str],
        timeout: float,
        pass_fds: Sequence[int] = (),
        max_output_bytes: int = MAX_OUTPUT,
    ) -> CommandResult: ...


class SubprocessRunner:
    """Run fixed argv in a new process group with bounded pipe collection."""

    def __init__(self, *, terminate_grace: float = 0.25) -> None:
        if terminate_grace <= 0:
            raise ValueError("terminate_grace must be positive")
        self.terminate_grace = terminate_grace

    def run(
        self,
        argv: Sequence[str],
        *,
        env: Mapping[str, str],
        timeout: float,
        pass_fds: Sequence[int] = (),
        max_output_bytes: int = MAX_OUTPUT,
    ) -> CommandResult:
        command = _validated_argv(argv)
        if timeout <= 0:
            raise ValueError("timeout must be positive")
        if max_output_bytes <= 0 or max_output_bytes > MAX_OUTPUT:
            raise ValueError("max_output_bytes must be within the shared output bound")
        inherited = tuple(pass_fds)
        if any(fd < 0 for fd in inherited) or len(set(inherited)) != len(inherited):
            raise ValueError("pass_fds contains an invalid descriptor")
        started = time.monotonic()
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            shell=False,
            env=dict(env),
            close_fds=True,
            pass_fds=inherited,
            start_new_session=True,
        )
        assert process.stdout is not None and process.stderr is not None
        selector = selectors.DefaultSelector()
        buffers = {"stdout": bytearray(), "stderr": bytearray()}
        for name, pipe in (("stdout", process.stdout), ("stderr", process.stderr)):
            os.set_blocking(pipe.fileno(), False)
            selector.register(pipe, selectors.EVENT_READ, name)

        def collect_until(deadline: float, *, discard: bool = False) -> str | None:
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return "timeout"
                events = selector.select(min(remaining, 0.05))
                if not events:
                    continue
                for key, _ in events:
                    target = buffers[key.data]
                    allowance = max_output_bytes - sum(map(len, buffers.values()))
                    try:
                        chunk = os.read(
                            key.fd,
                            65536 if discard else min(65536, allowance + 1),
                        )
                    except BlockingIOError:
                        continue
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    if discard:
                        continue
                    if len(chunk) > allowance:
                        target.extend(chunk[:allowance])
                        return "output"
                    target.extend(chunk)
            return None

        problem = collect_until(started + timeout)
        if problem is None:
            remaining = started + timeout - time.monotonic()
            try:
                process.wait(timeout=max(0.001, remaining))
            except subprocess.TimeoutExpired:
                problem = "timeout"
        if problem is not None:
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(process.pid, sig)
                except OSError:
                    pass
                collect_until(time.monotonic() + self.terminate_grace, discard=True)
                try:
                    process.wait(timeout=self.terminate_grace)
                except subprocess.TimeoutExpired:
                    pass
                if not selector.get_map() and process.poll() is not None:
                    break
            retained = bool(selector.get_map())
            for pipe in (process.stdout, process.stderr):
                try:
                    selector.unregister(pipe)
                except (KeyError, ValueError):
                    pass
                try:
                    pipe.close()
                except OSError:
                    pass
            selector.close()
            if retained:
                raise RetainedDescriptorIncident(
                    "command did not release output descriptors after bounded group "
                    "termination; inherited descriptors such as FD 9 may remain open: "
                    + " ".join(command)
                )
            if problem == "output":
                raise CommandOutputLimit(
                    "command output exceeds the admission bound: " + " ".join(command)
                )
            raise CommandTimeout(
                "command timed out after " + str(timeout) + "s: " + " ".join(command)
            )
        selector.close()
        stdout = bytes(buffers["stdout"])
        stderr = bytes(buffers["stderr"])
        process.stdout.close()
        process.stderr.close()
        return CommandResult(
            command, process.returncode, stdout, stderr, time.monotonic() - started
        )


def _validated_argv(argv: Sequence[str]) -> tuple[str, ...]:
    if isinstance(argv, (str, bytes)) or not argv:
        raise ValueError("argv must be a nonempty sequence")
    command = tuple(argv)
    if any(
        not isinstance(value, str) or not value or "\x00" in value for value in command
    ):
        raise ValueError("argv contains an invalid value")
    return command


def _canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")


def _digest(value: Any) -> str:
    return hashlib.sha256(_canonical_bytes(value)).hexdigest()


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _validated_execution_event(event: str) -> str:
    if (
        type(event) is not str
        or len(event) > EXECUTION_EVENT_MAX_LENGTH
        or EXECUTION_EVENT_RE.fullmatch(event) is None
    ):
        raise AdmissionError("execution event must use the bounded x05-* namespace")
    return event


def _validated_execution_detail(detail: Any) -> dict[str, Any]:
    """Return a detached strict-JSON detail after all pure bounds checks."""
    if type(detail) is not dict:
        raise AdmissionError("execution event detail must be a built-in JSON object")
    item_count = 0
    encoded_size = 0
    active_containers: set[int] = set()

    def add_encoded_size(size: int) -> None:
        nonlocal encoded_size
        encoded_size += size
        if encoded_size > EXECUTION_DETAIL_MAX_BYTES:
            raise AdmissionError("execution event detail exceeds the encoded size bound")

    def add_scalar_size(value: Any) -> None:
        if type(value) is str and len(value) > EXECUTION_DETAIL_MAX_BYTES:
            raise AdmissionError("execution event detail exceeds the encoded size bound")
        if type(value) is int and value.bit_length() > EXECUTION_DETAIL_MAX_BYTES * 4:
            raise AdmissionError("execution event detail exceeds the encoded size bound")
        try:
            encoded = json.dumps(
                value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
            ).encode("utf-8")
        except (TypeError, ValueError, UnicodeEncodeError) as exc:
            raise AdmissionError("execution event detail is not canonical JSON") from exc
        add_encoded_size(len(encoded))

    def validate(value: Any, *, depth: int) -> Any:
        nonlocal item_count
        if depth > EXECUTION_DETAIL_MAX_DEPTH:
            raise AdmissionError("execution event detail exceeds the depth bound")
        value_type = type(value)
        if value is None or value_type is bool or value_type is str:
            add_scalar_size(value)
            return value
        if value_type is int:
            add_scalar_size(value)
            return value
        if value_type is float:
            if not math.isfinite(value):
                raise AdmissionError("execution event detail contains a non-finite number")
            add_scalar_size(value)
            return value
        if value_type not in (dict, list):
            raise AdmissionError("execution event detail contains a non-JSON value")
        identity = id(value)
        if identity in active_containers:
            raise AdmissionError("execution event detail contains a reference cycle")
        active_containers.add(identity)
        try:
            item_count += len(value)
            if item_count > EXECUTION_DETAIL_MAX_ITEMS:
                raise AdmissionError("execution event detail exceeds the item bound")
            if value_type is list:
                add_encoded_size(2 + max(0, len(value) - 1))
                return [validate(item, depth=depth + 1) for item in value]
            add_encoded_size(2 + max(0, len(value) - 1) + len(value))
            result: dict[str, Any] = {}
            for key, item in value.items():
                if type(key) is not str:
                    raise AdmissionError(
                        "execution event detail contains a non-string object key"
                    )
                if key in EXECUTION_RESERVED_DETAIL_KEYS:
                    raise AdmissionError(
                        "execution event detail attempts to substitute a producer anchor"
                    )
                add_scalar_size(key)
                result[key] = validate(item, depth=depth + 1)
            return result
        finally:
            active_containers.remove(identity)

    normalized = validate(detail, depth=0)
    try:
        encoded = _canonical_bytes(normalized)
    except (TypeError, ValueError, UnicodeEncodeError) as exc:
        raise AdmissionError("execution event detail is not canonical JSON") from exc
    if len(encoded) != encoded_size:
        raise AdmissionError("execution event detail has an inconsistent JSON size")
    return normalized


def _mode(info: os.stat_result) -> int:
    return stat.S_IMODE(info.st_mode)


def _utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def _read_regular(
    path: pathlib.Path,
    *,
    maximum: int,
    required_mode: int | None = None,
    required_uid: int | None = None,
    forbidden_mode_bits: int = 0,
) -> bytes:
    try:
        before = path.lstat()
    except OSError as exc:
        raise AdmissionError(f"required file is unavailable: {path}") from exc
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise AdmissionError(f"required path is not a regular non-symlink file: {path}")
    if required_mode is not None and _mode(before) != required_mode:
        raise AdmissionError(f"required file mode is not {required_mode:o}: {path}")
    if _mode(before) & forbidden_mode_bits:
        raise AdmissionError(f"required file mode is unsafe: {path}")
    if required_uid is not None and before.st_uid != required_uid:
        raise AdmissionError(f"required file owner is wrong: {path}")
    if before.st_size > maximum:
        raise AdmissionError(f"required file exceeds size bound: {path}")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
        try:
            opened = os.fstat(fd)
            if (
                not stat.S_ISREG(opened.st_mode)
                or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
                or (required_mode is not None and _mode(opened) != required_mode)
                or (required_uid is not None and opened.st_uid != required_uid)
                or _mode(opened) & forbidden_mode_bits
            ):
                raise AdmissionError(f"required file changed while opening: {path}")
            data = b""
            while len(data) <= maximum:
                chunk = os.read(fd, min(65536, maximum + 1 - len(data)))
                if not chunk:
                    break
                data += chunk
        finally:
            os.close(fd)
    except OSError as exc:
        raise AdmissionError(f"required file cannot be read: {path}") from exc
    if len(data) > maximum:
        raise AdmissionError(f"required file exceeds size bound: {path}")
    try:
        after = path.lstat()
    except OSError as exc:
        raise AdmissionError(f"required file changed while reading: {path}") from exc
    before_identity = (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_mtime_ns,
        before.st_ctime_ns,
        before.st_mode,
        before.st_uid,
    )
    after_identity = (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
        after.st_ctime_ns,
        after.st_mode,
        after.st_uid,
    )
    if after_identity != before_identity:
        raise AdmissionError(f"required file changed while reading: {path}")
    return data


def _verify_reviewed_bundle(root: pathlib.Path, *, required_uid: int) -> str:
    """Verify the hard-coded reviewed bundle before importing or executing it."""
    if _digest(REVIEWED_BUNDLE_FILES) != REVIEWED_BUNDLE_MANIFEST_SHA256:
        raise AdmissionError("compiled reviewed bundle manifest pin is inconsistent")
    if not root.is_absolute():
        raise AdmissionError("reviewed bundle root is not absolute")
    checked_directories: set[pathlib.Path] = set()
    for relative, expected_digest in REVIEWED_BUNDLE_FILES.items():
        path = root / relative
        current = path.parent
        chain: list[pathlib.Path] = []
        while True:
            chain.append(current)
            if current == root:
                break
            if root not in current.parents:
                raise AdmissionError("reviewed bundle path escapes its root")
            current = current.parent
        for directory in reversed(chain):
            if directory in checked_directories:
                continue
            try:
                info = directory.lstat()
            except OSError as exc:
                raise AdmissionError(
                    "reviewed bundle directory is unavailable: " + str(directory)
                ) from exc
            if (
                stat.S_ISLNK(info.st_mode)
                or not stat.S_ISDIR(info.st_mode)
                or info.st_uid != required_uid
                or _mode(info) & 0o022
            ):
                raise AdmissionError(
                    "reviewed bundle directory owner or mode is unsafe: "
                    + str(directory)
                )
            checked_directories.add(directory)
        data = _read_regular(
            path,
            maximum=8 * 1024 * 1024,
            required_uid=required_uid,
            forbidden_mode_bits=0o022,
        )
        if _sha256(data) != expected_digest:
            raise AdmissionError("reviewed bundle digest changed: " + relative)
    optional_env = root / "labctl.env"
    if optional_env.exists() or optional_env.is_symlink():
        raise AdmissionError("unreviewed optional labctl.env is present")
    return REVIEWED_BUNDLE_MANIFEST_SHA256


def _load_reviewed_bundle_modules(root: pathlib.Path) -> None:
    global PREFLIGHT, PLAN
    ovn = root / "studies/p004/ovn"
    PREFLIGHT = _load_module(
        "x05_runtime_preflight_reviewed", ovn / "x05-runtime-preflight.py"
    )
    PLAN = _load_module("x05_runtime_plan_reviewed", ovn / "x05-runtime-plan.py")


def _assert_private_directory(path: pathlib.Path, uid: int) -> None:
    try:
        info = path.lstat()
    except OSError as exc:
        raise AdmissionError(f"run parent is unavailable: {path}") from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise AdmissionError(f"run parent is not a non-symlink directory: {path}")
    if info.st_uid != uid or _mode(info) != 0o700:
        raise AdmissionError(
            f"run parent must be owned by uid {uid} with mode 0700: {path}"
        )


@dataclasses.dataclass(frozen=True)
class AdmissionConfig:
    run_hex: str
    evidence_path: pathlib.Path
    receipt_path: pathlib.Path
    k01_kubeconfig: pathlib.Path
    p003_kubeconfig: pathlib.Path
    lock_path: pathlib.Path = DEFAULT_LOCK
    state_path: pathlib.Path = DEFAULT_STATE
    m03_marker_path: pathlib.Path = DEFAULT_M03_MARKER
    x05_marker_path: pathlib.Path = DEFAULT_X05_MARKER
    bundle_root: pathlib.Path = DEFAULT_BUNDLE_ROOT
    labctl_path: pathlib.Path = DEFAULT_LABCTL
    meminfo_path: pathlib.Path = pathlib.Path("/proc/meminfo")
    k01_context: str = "kind-k01"
    p003_context: str = "kind-p003-gw"
    command_timeout: float = 15.0
    required_uid: int = 0
    test_only_paths: bool = False
    now: Callable[[], dt.datetime] = _utc_now
    hostname: Callable[[], str] = socket.gethostname

    def __post_init__(self) -> None:
        for field in (
            "evidence_path",
            "receipt_path",
            "k01_kubeconfig",
            "p003_kubeconfig",
            "lock_path",
            "state_path",
            "m03_marker_path",
            "x05_marker_path",
            "bundle_root",
            "labctl_path",
            "meminfo_path",
        ):
            object.__setattr__(self, field, pathlib.Path(getattr(self, field)))
        if RUN_RE.fullmatch(self.run_hex) is None:
            raise ValueError("run_hex must be six lowercase hexadecimal characters")
        if not self.evidence_path.is_absolute():
            raise ValueError("evidence_path must be absolute")
        parts = self.evidence_path.parts
        if parts[-5:] != ("evidence", "P004", "S002", self.run_hex, "08-x05"):
            raise ValueError("evidence_path is not the canonical X05 run path")
        if self.k01_context != "kind-k01" or self.p003_context != "kind-p003-gw":
            raise ValueError("Kubernetes contexts must be explicit canonical contexts")
        if (
            not self.k01_kubeconfig.is_absolute()
            or not self.p003_kubeconfig.is_absolute()
        ):
            raise ValueError("kubeconfig paths must be absolute")
        if self.command_timeout <= 0:
            raise ValueError("command_timeout must be positive")
        if not self.test_only_paths:
            if self.required_uid != 0:
                raise ValueError("production admission requires root ownership")
            if self.now is not _utc_now or self.hostname is not socket.gethostname:
                raise ValueError(
                    "production admission requires the host clock and hostname"
                )
            expected = {
                "lock_path": DEFAULT_LOCK,
                "state_path": DEFAULT_STATE,
                "m03_marker_path": DEFAULT_M03_MARKER,
                "x05_marker_path": DEFAULT_X05_MARKER,
                "bundle_root": DEFAULT_BUNDLE_ROOT,
                "labctl_path": DEFAULT_LABCTL,
                "meminfo_path": pathlib.Path("/proc/meminfo"),
            }
            for field, value in expected.items():
                if getattr(self, field) != value:
                    raise ValueError(field + " is fixed outside explicit test mode")

    @property
    def owner(self) -> str:
        return "labctl-x05-" + self.run_hex

    @property
    def run_parent(self) -> pathlib.Path:
        return self.evidence_path.parent

    @property
    def event_path(self) -> pathlib.Path:
        return self.run_parent / "x05-admission.jsonl"

    @property
    def snapshot_path(self) -> pathlib.Path:
        return self.evidence_path / "runtime-preflight.json"

    @property
    def m03_evidence_path(self) -> pathlib.Path:
        return self.run_parent / "07-m03-setup"


def _admission_config_value_anchor(config: AdmissionConfig) -> tuple[Any, ...]:
    """Return the immutable construction values of one exact config object."""

    if type(config) is not AdmissionConfig:
        raise AdmissionError("admission config has a foreign type")
    values = tuple(
        (field.name, type(value), value)
        for field in dataclasses.fields(AdmissionConfig)
        for value in (getattr(config, field.name),)
    )
    return values + (
        ("owner", str, config.owner),
        ("run_parent", pathlib.Path, config.run_parent),
        ("event_path", pathlib.Path, config.event_path),
        ("snapshot_path", pathlib.Path, config.snapshot_path),
        ("m03_evidence_path", pathlib.Path, config.m03_evidence_path),
    )


class DurableEventLog:
    """Append-only, hash-linked admission events with file and directory fsync."""

    def __init__(self, path: pathlib.Path, *, uid: int) -> None:
        self.path = path
        self.uid = uid
        self._fd: int | None = None
        self._previous = "0" * 64
        self._event_count = 0
        self._identity: tuple[int, int] | None = None

    def open(self) -> None:
        if self._fd is not None:
            raise AdmissionError("event log is already open")
        if self.path.exists() or self.path.is_symlink():
            raise AdmissionError(f"admission event path already exists: {self.path}")
        flags = (
            os.O_WRONLY
            | os.O_APPEND
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
        try:
            self._fd = os.open(self.path, flags, 0o600)
            info = os.fstat(self._fd)
            if info.st_uid != self.uid or _mode(info) != 0o600:
                raise AdmissionError("admission event file is not private")
            self._identity = (info.st_dev, info.st_ino)
            os.fsync(self._fd)
            _fsync_directory(self.path.parent)
        except Exception:
            self.close()
            raise

    def append(self, event: str, detail: Mapping[str, Any]) -> dict[str, Any]:
        if self._fd is None:
            raise AdmissionError("event log is not open")
        body = {
            "schema": "p004-x05-admission-event-v1",
            "sequence": self._event_count + 1,
            "event": event,
            "recorded_at_ns": time.time_ns(),
            "monotonic_ns": time.monotonic_ns(),
            "previous_sha256": self._previous,
            "detail": dict(detail),
        }
        event_hash = _digest(body)
        record = {**body, "event_sha256": event_hash}
        data = _canonical_bytes(record) + b"\n"
        view = memoryview(data)
        while view:
            written = os.write(self._fd, view)
            view = view[written:]
        os.fsync(self._fd)
        _fsync_directory(self.path.parent)
        self._previous = event_hash
        self._event_count += 1
        return record

    @property
    def head(self) -> str:
        return self._previous

    @property
    def count(self) -> int:
        return self._event_count

    def verify(self) -> dict[str, Any]:
        """Re-read the durable log and verify its inode and complete hash chain."""
        if self._fd is None or self._identity is None:
            raise AdmissionError("event log is not open")
        opened = os.fstat(self._fd)
        current = self.path.lstat()
        if (opened.st_dev, opened.st_ino) != self._identity or (
            current.st_dev,
            current.st_ino,
        ) != self._identity:
            raise AdmissionIncident("admission event log identity changed")
        raw = _read_regular(
            self.path,
            maximum=8 * 1024 * 1024,
            required_mode=0o600,
            required_uid=self.uid,
        )
        if raw and not raw.endswith(b"\n"):
            raise AdmissionIncident("admission event log has a partial record")
        previous = "0" * 64
        count = 0
        for line in raw.splitlines():
            try:
                row = PREFLIGHT.parse_json(line, context="admission event")
            except PREFLIGHT.SnapshotError as exc:
                raise AdmissionIncident(str(exc)) from exc
            if not isinstance(row, dict) or set(row) != {
                "schema",
                "sequence",
                "event",
                "recorded_at_ns",
                "monotonic_ns",
                "previous_sha256",
                "detail",
                "event_sha256",
            }:
                raise AdmissionIncident("admission event schema changed")
            count += 1
            body = {key: value for key, value in row.items() if key != "event_sha256"}
            if (
                row.get("schema") != "p004-x05-admission-event-v1"
                or row.get("sequence") != count
                or row.get("previous_sha256") != previous
                or row.get("event_sha256") != _digest(body)
            ):
                raise AdmissionIncident("admission event hash chain is invalid")
            previous = row["event_sha256"]
        if count != self._event_count or previous != self._previous:
            raise AdmissionIncident("admission event log differs from the live chain")
        return {"count": count, "head_sha256": previous, "file_sha256": _sha256(raw)}

    def close(self) -> None:
        if self._fd is not None:
            os.close(self._fd)
            self._fd = None


@dataclasses.dataclass(frozen=True, slots=True)
class _EventLogAuthority:
    """Immutable descriptor and canonical-path identity captured at open."""

    descriptor: int
    identity: tuple[int, int]
    mode: int
    uid: int
    status_flags: int
    descriptor_flags: int


@dataclasses.dataclass(frozen=True, slots=True)
class _AdmissionOrigin:
    """Construction-time objects and callables that admission authorized."""

    session: Any
    session_type: type[Any]
    config: AdmissionConfig
    config_anchor: tuple[Any, ...]
    runner: Any
    runner_type: type[Any]
    runner_run: Callable[..., CommandResult]
    delegate: Runner
    delegate_type: type[Any]
    delegate_run: Callable[..., CommandResult]
    collector: LiveCollector
    collector_type: type[Any]
    collector_methods: tuple[tuple[str, Callable[..., Any]], ...]
    consume_lock: Any
    consume_lock_type: type[Any]
    events: DurableEventLog
    events_type: type[Any]
    event_path: pathlib.Path
    event_uid: int
    event_open: Callable[..., None]
    event_append: Callable[..., dict[str, Any]]
    event_verify: Callable[..., dict[str, Any]]
    event_close: Callable[..., None]
    event_head_get: Callable[[DurableEventLog], str]
    event_count_get: Callable[[DurableEventLog], int]
    session_private_methods: tuple[tuple[str, Callable[..., Any]], ...]
    session_prepare: Callable[..., Any]
    session_consume: Callable[..., Any]
    session_verify_execution: Callable[..., None]
    session_execution_context: Callable[..., dict[str, Any]]
    session_record_execution_event: Callable[..., dict[str, Any]]
    session_close: Callable[..., None]


def _has_instance_shadow(owner: Any, name: str) -> bool:
    try:
        return name in vars(owner)
    except TypeError:
        return False


def _original_session_method(
    origin: _AdmissionOrigin, name: str
) -> Callable[..., Any]:
    """Return one construction-time private session implementation."""

    for method_name, implementation in origin.session_private_methods:
        if method_name == name:
            return implementation
    raise AdmissionIncident("original admission session helper is unavailable: " + name)


def _fsync_directory(path: pathlib.Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0)
    fd = os.open(path, flags)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _decode_ovs(value: Any) -> Any:
    if isinstance(value, list) and len(value) == 2 and value[0] == "uuid":
        if not isinstance(value[1], str):
            raise AdmissionError("OVS JSON UUID atom is malformed")
        return value[1]
    if isinstance(value, list) and len(value) == 2 and value[0] == "set":
        if not isinstance(value[1], list):
            raise AdmissionError("OVS JSON set is malformed")
        decoded = [_decode_ovs(item) for item in value[1]]
        canonical = [_canonical_bytes(item) for item in decoded]
        if len(set(canonical)) != len(canonical):
            raise AdmissionError("OVS JSON set contains duplicates")
        return sorted(decoded, key=_canonical_bytes)
    if isinstance(value, list) and len(value) == 2 and value[0] == "map":
        if not isinstance(value[1], list):
            raise AdmissionError("OVS JSON map is malformed")
        result: dict[str, Any] = {}
        for pair in value[1]:
            if (
                not isinstance(pair, list)
                or len(pair) != 2
                or not isinstance(pair[0], str)
            ):
                raise AdmissionError("OVS JSON map entry is malformed")
            key, item = pair
            if key in result:
                raise AdmissionError("OVS JSON contains a duplicate map key")
            result[key] = _decode_ovs(item)
        return result
    return value


OVS_UUID_SET_COLUMNS = {
    "Bridge": frozenset({"ports"}),
    "Port": frozenset({"interfaces"}),
}
OVN_UUID_SET_COLUMNS = {
    "Logical_Router": frozenset({"ports"}),
    "Logical_Switch": frozenset({"ports"}),
}


def _decode_ovs_uuid_set_column(value: Any) -> Any:
    """Keep a singleton UUID atom list-shaped for schema-declared set columns."""

    decoded = _decode_ovs(value)
    if isinstance(value, list) and len(value) == 2 and value[0] == "uuid":
        return [decoded]
    return decoded


def _ovs_rows(
    raw: bytes,
    context: str,
    *,
    uuid_set_columns: Sequence[str] = (),
) -> list[dict[str, Any]]:
    try:
        value = PREFLIGHT.parse_json(raw, context=context)
    except PREFLIGHT.SnapshotError as exc:
        raise AdmissionError(str(exc)) from exc
    if not isinstance(value, dict) or set(value) != {"headings", "data"}:
        raise AdmissionError(context + " is not an OVS JSON table")
    headings = value["headings"]
    data = value["data"]
    if not isinstance(headings, list) or not all(
        isinstance(item, str) for item in headings
    ):
        raise AdmissionError(context + " headings are malformed")
    if len(set(headings)) != len(headings):
        raise AdmissionError(context + " headings contain duplicates")
    if not isinstance(data, list):
        raise AdmissionError(context + " data is malformed")
    set_columns = frozenset(uuid_set_columns)
    rows: list[dict[str, Any]] = []
    for item in data:
        if not isinstance(item, list) or len(item) != len(headings):
            raise AdmissionError(context + " row width is malformed")
        row: dict[str, Any] = {}
        for key, cell in zip(headings, item, strict=True):
            decoder = _decode_ovs_uuid_set_column if key in set_columns else _decode_ovs
            row[key] = decoder(cell)
        rows.append(row)
    return rows


class LiveCollector:
    """Collect all G0/G0a observations from fixed, read-only commands."""

    def __init__(self, config: AdmissionConfig, runner: Runner) -> None:
        self.config = config
        self.runner = runner
        self._cache: dict[tuple[Any, ...], Any] = {}

    def clear_cache(self) -> None:
        self._cache.clear()

    @property
    def fixture_root(self) -> pathlib.Path:
        return self.config.bundle_root / "studies/p004/ovn"

    def _run(self, argv: Sequence[str]) -> bytes:
        command = _validated_argv(argv)
        result = self.runner.run(
            command, env=BASE_ENV, timeout=self.config.command_timeout, pass_fds=()
        )
        if result.argv != command:
            raise AdmissionError("runner returned a different argv")
        if result.returncode != 0:
            detail = result.stderr.decode("utf-8", "replace")[:512]
            raise AdmissionError(
                f"read-only command failed rc={result.returncode}: {' '.join(command)}: {detail}"
            )
        if len(result.stdout) > MAX_OUTPUT or len(result.stderr) > MAX_OUTPUT:
            raise AdmissionError("read-only command output exceeds the admission bound")
        return result.stdout

    def _json(self, argv: Sequence[str], context: str) -> Any:
        try:
            return PREFLIGHT.parse_json(self._run(argv), context=context)
        except PREFLIGHT.SnapshotError as exc:
            raise AdmissionError(str(exc)) from exc

    def docker_catalog(self) -> dict[str, dict[str, Any]]:
        key = ("docker-catalog",)
        if key in self._cache:
            return self._cache[key]
        raw = self._run(
            (
                "docker",
                "container",
                "ls",
                "--all",
                "--no-trunc",
                "--format",
                "{{json .}}",
            )
        )
        names: set[str] = set()
        for line in raw.splitlines():
            if not line.strip():
                continue
            row = PREFLIGHT.parse_json(line, context="docker container listing")
            if not isinstance(row, dict) or not isinstance(row.get("Names"), str):
                raise AdmissionError("docker container listing row is malformed")
            name = row["Names"]
            if name in names:
                raise AdmissionError("docker container listing repeats a name: " + name)
            names.add(name)
        result: dict[str, dict[str, Any]] = {}
        original_image_labels: dict[str, dict[str, str]] = {}
        interesting = set(PREFLIGHT.MGC_CONTAINER_NAMES) | {
            "mgc-evpn-client-1",
            "mgc-client-2",
            "mgc-x05-peer-2",
            "p003-os",
        }
        for name in sorted(names & interesting):
            value = self._json(
                ("docker", "container", "inspect", name), "docker inspect " + name
            )
            if (
                not isinstance(value, list)
                or len(value) != 1
                or not isinstance(value[0], dict)
            ):
                raise AdmissionError("docker inspect result is malformed: " + name)
            item = value[0]
            container_id = item.get("Id")
            state = item.get("State")
            config = item.get("Config")
            if (
                not isinstance(container_id, str)
                or CONTAINER_ID_RE.fullmatch(container_id) is None
                or not isinstance(state, dict)
                or not isinstance(state.get("Status"), str)
                or not isinstance(config, dict)
            ):
                raise AdmissionError("docker inspect identity is malformed: " + name)
            labels = config.get("Labels")
            if labels is None:
                labels = {}
            if not isinstance(labels, dict) or not all(
                isinstance(k, str) and isinstance(v, str) for k, v in labels.items()
            ):
                raise AdmissionError("docker labels are malformed: " + name)
            image_id = item.get("Image")
            image_labels: dict[str, str] | None = None
            if name in PREFLIGHT.CLUSTER_NAMES:
                if "Labels" not in config:
                    raise AdmissionError(
                        "original container Config.Labels is missing: " + name
                    )
                if not isinstance(image_id, str) or IMAGE_ID_RE.fullmatch(image_id) is None:
                    raise AdmissionError(
                        "original container image ID is malformed: " + name
                    )
                if image_id not in original_image_labels:
                    image_value = self._json(
                        ("docker", "image", "inspect", image_id),
                        "docker image inspect " + image_id,
                    )
                    if (
                        not isinstance(image_value, list)
                        or len(image_value) != 1
                        or not isinstance(image_value[0], dict)
                    ):
                        raise AdmissionError(
                            "original image inspect result is malformed: " + image_id
                        )
                    image_item = image_value[0]
                    if image_item.get("Id") != image_id:
                        raise AdmissionError(
                            "original image ID differs from the captured container image: "
                            + name
                        )
                    image_config = image_item.get("Config")
                    if not isinstance(image_config, dict) or "Labels" not in image_config:
                        raise AdmissionError(
                            "original image Config.Labels is missing: " + image_id
                        )
                    candidate_labels = image_config["Labels"]
                    if candidate_labels is None:
                        candidate_labels = {}
                    if not isinstance(candidate_labels, dict) or not all(
                        isinstance(k, str) and isinstance(v, str)
                        for k, v in candidate_labels.items()
                    ):
                        raise AdmissionError(
                            "original image labels are malformed: " + image_id
                        )
                    original_image_labels[image_id] = dict(candidate_labels)
                image_labels = original_image_labels[image_id]
                if labels != image_labels:
                    raise AdmissionError(
                        "original container labels differ from image labels: " + name
                    )
                if PREFLIGHT.ORIGINAL_OWNERSHIP_LABELS.intersection(labels):
                    raise AdmissionError(
                        "original container carries an ownership label: " + name
                    )
                if PREFLIGHT.ORIGINAL_OWNERSHIP_LABELS.intersection(image_labels):
                    raise AdmissionError(
                        "original image carries an ownership label: " + name
                    )
            result[name] = {
                "id": container_id,
                "state": state["Status"],
                "labels": dict(labels),
                "image": image_id,
            }
            if image_labels is not None:
                result[name]["image_labels"] = dict(image_labels)
        result["__all_names__"] = {name: True for name in sorted(names)}
        self._cache[key] = result
        return result

    def image_ids(self) -> dict[str, str]:
        key = ("images",)
        if key in self._cache:
            return self._cache[key]
        result: dict[str, str] = {}
        for tag in MUTABLE_IMAGE_TAGS:
            value = self._json(
                ("docker", "image", "inspect", tag), "docker image inspect " + tag
            )
            if (
                not isinstance(value, list)
                or len(value) != 1
                or not isinstance(value[0], dict)
            ):
                raise AdmissionError("docker image inspect result is malformed: " + tag)
            image_id = value[0].get("Id")
            repo_tags = value[0].get("RepoTags")
            if (
                not isinstance(image_id, str)
                or IMAGE_ID_RE.fullmatch(image_id) is None
                or not isinstance(repo_tags, list)
                or tag not in repo_tags
            ):
                raise AdmissionError(
                    "mutable image tag is not bound to an immutable ID: " + tag
                )
            result[tag] = image_id
        self._cache[key] = result
        return result

    def state(self) -> dict[str, Any]:
        key = ("state",)
        if key in self._cache:
            return self._cache[key]
        raw = _read_regular(
            self.config.state_path,
            maximum=1024 * 1024,
            required_uid=self.config.required_uid,
            forbidden_mode_bits=0o022,
        )
        value = PREFLIGHT.parse_json(raw, context="MGC state")
        if not isinstance(value, dict):
            raise AdmissionError("MGC state is not an object")
        self._cache[key] = value
        return value

    def ovs(
        self, node: str | None, table: str, columns: Sequence[str]
    ) -> list[dict[str, Any]]:
        key = ("ovs", node, table, *columns)
        if key in self._cache:
            return self._cache[key]
        prefix = () if node is None else ("docker", "exec", node)
        argv = prefix + (
            "ovs-vsctl",
            "--format=json",
            "--data=json",
            "--no-headings",
            "--columns=" + ",".join(columns),
            "list",
            table,
        )
        rows = _ovs_rows(
            self._run(argv),
            f"OVS {node or 'host'} {table}",
            uuid_set_columns=OVS_UUID_SET_COLUMNS.get(table, ()),
        )
        if "name" in columns:
            names = [row.get("name") for row in rows]
            if any(not isinstance(name, str) or not name for name in names) or len(
                set(names)
            ) != len(names):
                raise AdmissionError(
                    f"OVS {node or 'host'} {table} names are malformed or duplicated"
                )
        self._cache[key] = rows
        return rows

    def nb(self, table: str, name: str, columns: Sequence[str]) -> list[dict[str, Any]]:
        key = ("nb", table, name, *columns)
        if key in self._cache:
            return self._cache[key]
        argv = (
            "docker",
            "exec",
            "ovn-central-az1",
            "ovn-nbctl",
            "--format=json",
            "--data=json",
            "--no-headings",
            "--columns=" + ",".join(columns),
            "find",
            table,
            "name=" + name,
        )
        rows = _ovs_rows(
            self._run(argv),
            f"OVN NB {table} {name}",
            uuid_set_columns=OVN_UUID_SET_COLUMNS.get(table, ()),
        )
        self._cache[key] = rows
        return rows

    def links(self, node: str | None) -> list[dict[str, Any]]:
        key = ("links", node)
        if key in self._cache:
            return self._cache[key]
        if node is None:
            prefix: tuple[str, ...] = ()
        elif node.startswith("netns:"):
            _, container, namespace = node.split(":", 2)
            prefix = (
                "docker",
                "exec",
                container,
                "ip",
                "netns",
                "exec",
                namespace,
            )
        else:
            prefix = ("docker", "exec", node)
        value = self._json(prefix + ("ip", "-j", "-d", "link", "show"), "ip link JSON")
        if not isinstance(value, list) or not all(
            isinstance(row, dict) for row in value
        ):
            raise AdmissionError("ip link JSON is malformed")
        names = [row.get("ifname") for row in value]
        if any(not isinstance(name, str) for name in names) or len(set(names)) != len(
            names
        ):
            raise AdmissionError("ip link JSON has malformed or duplicate names")
        self._cache[key] = value
        return value

    def netns_names(self, node: str | None) -> set[str]:
        key = ("netns", node)
        if key in self._cache:
            return self._cache[key]
        prefix = () if node is None else ("docker", "exec", node)
        value = self._json(prefix + ("ip", "-j", "netns", "list"), "ip netns JSON")
        if not isinstance(value, list):
            raise AdmissionError("ip netns JSON is malformed")
        names: set[str] = set()
        for row in value:
            if not isinstance(row, dict) or not isinstance(row.get("name"), str):
                raise AdmissionError("ip netns JSON row is malformed")
            if row["name"] in names:
                raise AdmissionError("ip netns JSON repeats a name")
            names.add(row["name"])
        self._cache[key] = names
        return names

    def container_file(self, node: str, path: str) -> bytes:
        key = ("file", node, path)
        if key not in self._cache:
            self._cache[key] = self._run(("docker", "exec", node, "cat", path))
        return self._cache[key]

    def running_config(self, node: str) -> str:
        key = ("running-config", node)
        if key not in self._cache:
            raw = self._run(
                ("docker", "exec", node, "vtysh", "-c", "show running-config")
            )
            try:
                self._cache[key] = raw.decode("utf-8")
            except UnicodeDecodeError as exc:
                raise AdmissionError("FRR running configuration is not UTF-8") from exc
        return self._cache[key]

    def pathspace_entries(self, node: str, paths: Sequence[str]) -> list[str]:
        key = ("pathspace", node, *paths)
        if key not in self._cache:
            script = 'for path do if [ -e "$path" ] || [ -L "$path" ]; then printf "%s\\n" "$path"; fi; done'
            raw = self._run(("docker", "exec", node, "sh", "-c", script, "sh", *paths))
            try:
                entries = raw.decode("utf-8").splitlines()
            except UnicodeDecodeError as exc:
                raise AdmissionError("pathspace readback is not UTF-8") from exc
            if len(entries) != len(set(entries)) or any(
                item not in paths for item in entries
            ):
                raise AdmissionError("pathspace readback is malformed")
            self._cache[key] = entries
        return self._cache[key]

    def marker(self, path: pathlib.Path, *, required: bool) -> dict[str, Any] | None:
        if not path.exists() and not path.is_symlink():
            if required:
                raise AdmissionError(f"required marker is absent: {path}")
            return None
        raw = _read_regular(
            path,
            maximum=64 * 1024,
            required_mode=0o600,
            required_uid=self.config.required_uid,
        )
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise AdmissionError(f"marker is not UTF-8: {path}") from exc
        try:
            info = path.lstat()
        except OSError as exc:
            raise AdmissionError(f"marker changed after reading: {path}") from exc
        if (
            stat.S_ISLNK(info.st_mode)
            or not stat.S_ISREG(info.st_mode)
            or _mode(info) != 0o600
            or info.st_uid != self.config.required_uid
        ):
            raise AdmissionError(f"marker changed after reading: {path}")
        return {
            "active": True,
            "valid": True,
            "mode": _mode(info),
            # Fake-runner tests execute as an unprivileged workstation user
            # while modelling the root-owned lab host. Production always
            # records the observed uid because test_only_paths is false.
            "uid": 0 if self.config.test_only_paths else info.st_uid,
            "raw": text,
            "bytes": len(raw),
            "sha256": _sha256(raw),
        }

    def validate_receipt(self) -> dict[str, str]:
        raw = _read_regular(
            self.config.receipt_path,
            maximum=64 * 1024,
            required_mode=0o600,
            required_uid=self.config.required_uid,
        )
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise AdmissionError("preflight receipt is not UTF-8") from exc
        fields: dict[str, str] = {}
        for line in text.splitlines():
            if not line or "=" not in line:
                raise AdmissionError("preflight receipt line is malformed")
            key, value = line.split("=", 1)
            if (
                key in fields
                or key not in RECEIPT_KEYS
                or not value
                or any(c.isspace() for c in value)
            ):
                raise AdmissionError("preflight receipt key/value is malformed: " + key)
            fields[key] = value
        if set(fields) != RECEIPT_KEYS:
            raise AdmissionError("preflight receipt keys are incomplete")
        if fields["k01_canary"] != "10/10" or fields["p003_gw_canary"] != "10/10":
            raise AdmissionError("preflight receipt does not contain 10/10 canaries")
        if (
            UID_RE.fullmatch(fields["k01_uid"]) is None
            or UID_RE.fullmatch(fields["p003_gw_uid"]) is None
            or fields["k01_uid"] == fields["p003_gw_uid"]
        ):
            raise AdmissionError("preflight receipt UIDs are invalid")
        host = self.config.hostname()
        if fields["host"] not in {host, host.split(".", 1)[0]}:
            raise AdmissionError("preflight receipt belongs to another host")
        try:
            timestamp = dt.datetime.strptime(
                fields["timestamp"], "%Y-%m-%dT%H:%M:%SZ"
            ).replace(tzinfo=dt.timezone.utc)
        except ValueError as exc:
            raise AdmissionError("preflight receipt timestamp is invalid") from exc
        now = self.config.now()
        if now.tzinfo is None:
            raise AdmissionError("admission clock is not timezone-aware")
        age = (now.astimezone(dt.timezone.utc) - timestamp).total_seconds()
        if age < 0 or age > 86400:
            raise AdmissionError("preflight receipt is outside the 24h window")
        return fields

    def historical_checks(self, receipt: Mapping[str, str]) -> None:
        for path in (self.config.k01_kubeconfig, self.config.p003_kubeconfig):
            raw = _read_regular(
                path,
                maximum=8 * 1024 * 1024,
                required_uid=self.config.required_uid,
                forbidden_mode_bits=0o022,
            )
            if not raw:
                raise AdmissionError("kubeconfig is empty: " + str(path))
        checks = (
            ("k01_uid", self.config.k01_kubeconfig, self.config.k01_context),
            ("p003_gw_uid", self.config.p003_kubeconfig, self.config.p003_context),
        )
        for key, kubeconfig, context in checks:
            raw = self._run(
                (
                    "kubectl",
                    "--kubeconfig",
                    str(kubeconfig),
                    "--context",
                    context,
                    "get",
                    "ns",
                    "kube-system",
                    "-o",
                    "jsonpath={.metadata.uid}",
                )
            )
            try:
                uid = raw.decode("utf-8").strip()
            except UnicodeDecodeError as exc:
                raise AdmissionError("Kubernetes UID is not UTF-8") from exc
            if UID_RE.fullmatch(uid) is None or uid != receipt[key]:
                raise AdmissionError(
                    "live Kubernetes UID differs from the fresh receipt: " + key
                )
        probes = (
            (
                "clab-poc-k8s-kind-client-ext",
                (
                    "curl",
                    "-s",
                    "-o",
                    "/dev/null",
                    "-w",
                    "%{http_code}",
                    "--max-time",
                    "5",
                    "--noproxy",
                    "*",
                    "http://10.201.255.10/hostname",
                ),
            ),
            (
                "clab-p003-gw-fabric-client",
                (
                    "curl",
                    "-s",
                    "-o",
                    "/dev/null",
                    "-w",
                    "%{http_code}",
                    "--max-time",
                    "5",
                    "--noproxy",
                    "*",
                    "-H",
                    "Host: echo.p003.study",
                    "http://10.202.255.10:8080/hostname",
                ),
            ),
        )
        for container, curl_argv in probes:
            for _ in range(10):
                code = self._run(("docker", "exec", container, *curl_argv))
                if code != b"200":
                    raise AdmissionError("historical canary did not return HTTP 200")

    def input_digests(self) -> dict[str, str]:
        return {
            "receipt_sha256": _sha256(
                _read_regular(
                    self.config.receipt_path,
                    maximum=64 * 1024,
                    required_mode=0o600,
                    required_uid=self.config.required_uid,
                )
            ),
            "k01_kubeconfig_sha256": _sha256(
                _read_regular(
                    self.config.k01_kubeconfig,
                    maximum=8 * 1024 * 1024,
                    required_uid=self.config.required_uid,
                    forbidden_mode_bits=0o022,
                )
            ),
            "p003_kubeconfig_sha256": _sha256(
                _read_regular(
                    self.config.p003_kubeconfig,
                    maximum=8 * 1024 * 1024,
                    required_uid=self.config.required_uid,
                    forbidden_mode_bits=0o022,
                )
            ),
        }

    def _memory_available_gib(self) -> int:
        raw = _read_regular(self.config.meminfo_path, maximum=1024 * 1024)
        for line in raw.splitlines():
            if line.startswith(b"MemAvailable:"):
                parts = line.split()
                if len(parts) == 3 and parts[2] == b"kB" and parts[1].isdigit():
                    return int(parts[1]) // 1024 // 1024
        raise AdmissionError("MemAvailable is missing or malformed")

    def mgc_section(self) -> dict[str, Any]:
        catalog = self.docker_catalog()
        state = self.state()
        owner = state.get("owner_token")
        if not isinstance(owner, str) or not owner:
            raise AdmissionError("MGC profile owner token is absent")
        missing = [
            name for name in PREFLIGHT.MGC_CONTAINER_NAMES if name not in catalog
        ]
        if missing:
            raise AdmissionError(
                "required MGC containers are absent: " + ",".join(missing)
            )
        all_names = set(catalog["__all_names__"])
        foreign = sorted(
            name
            for name in all_names
            if re.fullmatch(r"ovn-(?:central-az|gw-|chassis-).+", name)
            and name not in PREFLIGHT.CLUSTER_NAMES
        )
        bridge_rows = self.ovs(None, "Bridge", ("_uuid", "name", "external_ids"))
        by_name = {row.get("name"): row for row in bridge_rows}
        bridges: dict[str, Any] = {}
        recorded_bridges: dict[str, Any] = {}
        for name, state_key in PREFLIGHT.MGC_BRIDGE_ID_KEYS.items():
            row = by_name.get(name)
            if not isinstance(row, dict):
                raise AdmissionError("required MGC bridge is absent: " + name)
            bridges[name] = {
                "uuid": row.get("_uuid"),
                "external_ids": row.get("external_ids"),
            }
            recorded_bridges[state_key] = state.get(state_key)
        return {
            "status": "PASS",
            "profile_owner": owner,
            "expected_cluster_names": list(PREFLIGHT.CLUSTER_NAMES),
            "foreign_names": foreign,
            "container_ids": {
                name: catalog[name]["id"] for name in PREFLIGHT.MGC_CONTAINER_NAMES
            },
            "recorded_ids": {
                key: state.get(key) for key in PREFLIGHT.MGC_ID_KEYS.values()
            },
            "container_states": {
                name: catalog[name]["state"] for name in PREFLIGHT.MGC_CONTAINER_NAMES
            },
            "container_labels": {
                name: catalog[name]["labels"] for name in PREFLIGHT.MGC_CONTAINER_NAMES
            },
            "original_image_bindings": {
                name: {
                    "image_id": catalog[name]["image"],
                    "image_labels": catalog[name]["image_labels"],
                }
                for name in PREFLIGHT.CLUSTER_NAMES
            },
            "recorded_bridge_uuids": recorded_bridges,
            "bridges": bridges,
        }

    def docker_section(self) -> dict[str, Any]:
        catalog = self.docker_catalog()
        names = set(catalog["__all_names__"])
        images = self.image_ids()
        return {
            "status": "PASS",
            "names_absent": {
                name: name not in names for name in PREFLIGHT.FIXED_X05_DOCKER_NAMES
            },
            "foreign_names": [
                name for name in PREFLIGHT.FIXED_X05_DOCKER_NAMES if name in names
            ],
            "resolved_images": images,
            "resolved_images_sha256": PREFLIGHT.canonical_hash(images),
        }

    def gateway_frr_section(self) -> dict[str, Any]:
        rows: dict[str, Any] = {}
        for node, fixture, new_scope in (
            ("ovn-gw-1", "frr-gw1.conf", "ovnvrf300"),
            ("ovn-gw-2", "frr-gw2.conf", "ovnvrf400"),
        ):
            fixture_raw = _read_regular(
                self.fixture_root / fixture,
                maximum=1024 * 1024,
                required_uid=self.config.required_uid
                if not self.config.test_only_paths
                else None,
                forbidden_mode_bits=0o022 if not self.config.test_only_paths else 0,
            )
            base = self.container_file(node, "/etc/frr/frr.conf")
            running = self.running_config(node)
            scopes = list(PREFLIGHT.A_FRR_SCOPES[node])
            running_scope = PREFLIGHT.normalize_frr_running_config(running)
            if base != fixture_raw:
                raise AdmissionError(
                    "gateway FRR canonical bytes differ from fixture: " + node
                )
            if running_scope != scopes:
                raise AdmissionError(
                    "gateway A FRR normalized scope differs from the reviewed baseline: "
                    + node
                )
            if any(new_scope in line.split() for line in running_scope):
                raise AdmissionError(
                    "X05 gateway FRR extension is already present: " + node
                )
            rows[node] = {
                "fixture": fixture,
                "bytes": len(fixture_raw),
                "sha256": _sha256(fixture_raw),
                "matches_fixture": True,
                "base_path": "/etc/frr/frr.conf",
                "base_sha256": _sha256(base),
                "base_bytes": len(base),
                "base_matches": True,
                "extension_absent": True,
                "write_memory": False,
                "vtysh_b": False,
                "a_scopes_before": scopes,
                "a_scopes_sha256": PREFLIGHT.canonical_hash(scopes),
                "running_config_sha256": _sha256(running.encode("utf-8")),
            }
        return {"status": "PASS", "gateways": rows}

    def chassis2_section(self) -> dict[str, Any]:
        rows = self.ovs("ovn-chassis-2", "Open_vSwitch", ("_uuid", "external_ids"))
        if len(rows) != 1 or not isinstance(rows[0].get("external_ids"), dict):
            raise AdmissionError("chassis 2 Open_vSwitch readback is not singular")
        external = rows[0]["external_ids"]
        mapping = external.get("dynamic-routing-port-mapping")
        local_ip = external.get("ovn-evpn-local-ip")
        return {
            "status": "PASS",
            "dynamic-routing-port-mapping": mapping,
            "ovn-evpn-local-ip": local_ip,
            "original_values": {
                "dynamic-routing-port-mapping": mapping,
                "ovn-evpn-local-ip": local_ip,
            },
        }

    def _link_by_name(self, node: str | None) -> dict[str, dict[str, Any]]:
        return {row["ifname"]: row for row in self.links(node)}

    @staticmethod
    def _link_kind(row: Mapping[str, Any]) -> str | None:
        info = row.get("linkinfo")
        return info.get("info_kind") if isinstance(info, dict) else None

    @staticmethod
    def _link_typed(row: Mapping[str, Any], key: str) -> Any:
        info = row.get("linkinfo")
        data = info.get("info_data") if isinstance(info, dict) else None
        return data.get(key) if isinstance(data, dict) else None

    def _m03_links(self, marker_run: str) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = []
        inventories = {
            "chassis": self._link_by_name("ovn-chassis-1"),
            "peer": self._link_by_name("mgc-evpn-client-1"),
        }
        for name, kind, role, node, typed in PREFLIGHT.M03_LINKS:
            row = inventories[role].get(name)
            if row is None or self._link_kind(row) != kind:
                raise AdmissionError(
                    "M03 link is absent or has the wrong kind: " + name
                )
            item: dict[str, Any] = {
                "name": name,
                "kind": kind,
                "role": role,
                "node": node,
                "alias": row.get("ifalias"),
                "ifindex": row.get("ifindex"),
                "iflink": self._link_iflink(node, name),
                "master": row.get("master"),
                "link_type": row.get("link_type"),
                "namespace": {
                    "container": node,
                    "container_id": self.docker_catalog()[node]["id"],
                },
            }
            if typed is not None:
                field, expected = typed
                actual = self._link_typed(row, "id" if field == "vni" else field)
                if actual != expected:
                    raise AdmissionError("M03 link typed identity drifted: " + name)
                item[field] = actual
            if item["alias"] != "labctl-m03-" + marker_run:
                raise AdmissionError("M03 link alias drifted: " + name)
            result.append(item)
        return result

    def _link_iflink(self, node: str, name: str) -> int:
        raw = self._run(
            ("docker", "exec", node, "cat", "/sys/class/net/" + name + "/iflink")
        )
        try:
            value = int(raw.decode("ascii").strip())
        except (UnicodeDecodeError, ValueError) as exc:
            raise AdmissionError("Linux iflink readback is malformed: " + name) from exc
        if value <= 0:
            raise AdmissionError("Linux iflink readback is non-positive: " + name)
        return value

    def _m03_pathspace(self, marker_token: str) -> dict[str, Any]:
        paths = ("/etc/frr/m03", "/run/frr/m03")
        entries = self.pathspace_entries("ovn-chassis-1", paths)
        if entries != list(paths):
            raise AdmissionError("M03 FRR pathspace is incomplete")
        script = (
            "for daemon in zebra bgpd staticd; do "
            'for pid in $(pidof "$daemon" 2>/dev/null || true); do '
            'cmdline=$(tr "\\000" " " <"/proc/$pid/cmdline" 2>/dev/null || true); '
            'case "$cmdline" in *"-N m03"*|*"/run/frr/m03"*) '
            'start=$(awk "{print \\$22}" "/proc/$pid/stat" 2>/dev/null || true); '
            'printf "%s\\t%s\\t%s\\t%s\\n" "$daemon" "$pid" "$start" "$cmdline";; '
            "esac; done; done"
        )
        processes = self._run(("docker", "exec", "ovn-chassis-1", "sh", "-c", script))
        try:
            daemon_rows = processes.decode("ascii").splitlines()
        except UnicodeDecodeError as exc:
            raise AdmissionError("M03 FRR daemon readback is not ASCII") from exc
        daemon_identities: list[dict[str, Any]] = []
        for row in daemon_rows:
            fields = row.split("\t")
            if (
                len(fields) != 4
                or fields[0] not in {"zebra", "bgpd", "staticd"}
                or re.fullmatch(r"[1-9][0-9]*", fields[1]) is None
                or re.fullmatch(r"[1-9][0-9]*", fields[2]) is None
                or not fields[3]
            ):
                raise AdmissionError("M03 FRR daemon readback is malformed")
            daemon_identities.append(
                {
                    "daemon": fields[0],
                    "pid": int(fields[1]),
                    "start_time_ticks": int(fields[2]),
                    "cmdline": fields[3],
                }
            )
        if len(daemon_rows) != 3 or {row["daemon"] for row in daemon_identities} != {
            "zebra",
            "bgpd",
            "staticd",
        }:
            raise AdmissionError("M03 FRR pathspace daemon set is incomplete")
        return {
            "node": "ovn-chassis-1",
            "config_dir": paths[0],
            "run_dir": paths[1],
            "active": True,
            "owner_token": marker_token,
            "daemons": sorted(daemon_identities, key=lambda row: row["daemon"]),
        }

    def _a_fingerprint(self) -> dict[str, Any]:
        tables = (
            (
                "Logical_Switch",
                "ls-mgc-tenant",
                ("_uuid", "name", "ports", "other_config"),
            ),
            ("Logical_Router", "lr-mgc-tenant", ("_uuid", "name", "ports")),
            ("Logical_Router_Port", "lrp-mgc-tenant", ("_uuid", "name", "options")),
        )
        result: dict[str, Any] = {}
        for table, name, columns in tables:
            rows = self.nb(table, name, columns)
            if len(rows) != 1:
                raise AdmissionError("M03 A fingerprint row is not singular: " + table)
            row = rows[0]
            if (
                row.get("name") != name
                or not isinstance(row.get("_uuid"), str)
                or PREFLIGHT.UUID_RE.fullmatch(row["_uuid"]) is None
            ):
                raise AdmissionError(
                    "M03 A fingerprint identity is malformed: " + table
                )
            if table in {"Logical_Switch", "Logical_Router"}:
                ports = row.get("ports")
                if not isinstance(ports, list) or not all(
                    isinstance(value, str)
                    and PREFLIGHT.UUID_RE.fullmatch(value) is not None
                    for value in ports
                ):
                    raise AdmissionError(
                        "M03 A fingerprint port set is malformed: " + table
                    )
            if table == "Logical_Switch":
                other_config = row.get("other_config")
                if (
                    not isinstance(other_config, dict)
                    or other_config.get("dynamic-routing-vni") != "50100"
                ):
                    raise AdmissionError("M03 A logical switch options drifted")
            elif table == "Logical_Router_Port" and not isinstance(
                row.get("options"), dict
            ):
                raise AdmissionError("M03 A router port options are malformed")
            result[table] = row
        return result

    def m03_section(self, profile_owner: str) -> dict[str, Any]:
        marker = self.marker(self.config.m03_marker_path, required=True)
        assert marker is not None
        try:
            token, marker_run, _ = PREFLIGHT._marker_fields(marker["raw"])
        except PREFLIGHT.SnapshotError as exc:
            raise AdmissionError("M03 marker is invalid: " + str(exc)) from exc
        marker.update({"owner": token, "token": token, "run_token": marker_run})
        catalog = self.docker_catalog()
        peer = catalog.get("mgc-evpn-client-1")
        if not isinstance(peer, dict):
            raise AdmissionError("M03 peer is absent")
        interfaces = self.ovs(None, "Interface", ("_uuid", "name", "external_ids"))
        matches = [
            row
            for row in interfaces
            if isinstance(row.get("external_ids"), dict)
            and row["external_ids"].get("container_id") == "mgc-evpn-client-1"
            and row["external_ids"].get("container_iface") == "eth1"
        ]
        if len(matches) != 1:
            raise AdmissionError("M03 peer OVS interface identity is not singular")
        host_iface = matches[0].get("name")
        if (
            not isinstance(host_iface, str)
            or not host_iface
            or not isinstance(matches[0].get("_uuid"), str)
            or PREFLIGHT.UUID_RE.fullmatch(matches[0]["_uuid"]) is None
        ):
            raise AdmissionError("M03 peer OVS interface identity is malformed")
        if matches[0]["external_ids"].get("labctl-m03-owner") != token:
            raise AdmissionError("M03 peer OVS owner differs from marker")
        interface_uuid = matches[0]["_uuid"]
        ports = self.ovs(
            None, "Port", ("_uuid", "name", "interfaces", "tag", "external_ids")
        )
        matching_ports = [
            row
            for row in ports
            if isinstance(row.get("interfaces"), list)
            and interface_uuid in row["interfaces"]
        ]
        if len(matching_ports) != 1:
            raise AdmissionError("M03 peer OVS Port membership is not singular")
        port = matching_ports[0]
        if (
            not isinstance(port.get("_uuid"), str)
            or PREFLIGHT.UUID_RE.fullmatch(port["_uuid"]) is None
            or port.get("interfaces") != [interface_uuid]
        ):
            raise AdmissionError("M03 peer OVS Port identity is malformed")
        bridge = (
            self._run(("ovs-vsctl", "port-to-br", str(host_iface)))
            .decode("utf-8", "strict")
            .strip()
        )
        bridges = self.ovs(None, "Bridge", ("_uuid", "name", "ports"))
        bridge_matches = [
            row
            for row in bridges
            if row.get("name") == bridge
            and isinstance(row.get("ports"), list)
            and port["_uuid"] in row["ports"]
        ]
        if (
            len(bridge_matches) != 1
            or not isinstance(bridge_matches[0].get("_uuid"), str)
            or PREFLIGHT.UUID_RE.fullmatch(bridge_matches[0]["_uuid"]) is None
        ):
            raise AdmissionError("M03 peer OVS bridge membership is not singular")
        lrp_rows = self.nb(
            "Logical_Router_Port", "lrp-mgc-tenant", ("_uuid", "name", "options")
        )
        if len(lrp_rows) != 1 or not isinstance(lrp_rows[0].get("options"), dict):
            raise AdmissionError("M03 tenant LRP options readback is malformed")
        options = lrp_rows[0]["options"]
        chassis_rows = self.ovs(
            "ovn-chassis-1", "Open_vSwitch", ("_uuid", "external_ids")
        )
        if len(chassis_rows) != 1 or not isinstance(
            chassis_rows[0].get("external_ids"), dict
        ):
            raise AdmissionError("M03 chassis mapping readback is malformed")
        mapping = chassis_rows[0]["external_ids"].get("dynamic-routing-port-mapping")
        filter_name = "m03-evpn-" + marker_run
        tenant_link = self._link_by_name("ovn-chassis-1").get("ovnvrf-tenant")
        if (
            tenant_link is None
            or self._link_kind(tenant_link) != "vrf"
            or self._link_typed(tenant_link, "table") != 300
        ):
            raise AdmissionError("M03 tenant VRF identity drifted")
        section = {
            "status": "PASS",
            "owner_token": token,
            "profile_owner": profile_owner,
            "marker": marker,
            "peer": {
                "name": "mgc-evpn-client-1",
                "id": peer["id"],
                "state": peer["state"],
                "labels": peer["labels"],
                "ovs": {
                    "container_id": "mgc-evpn-client-1",
                    "container_iface": "eth1",
                    "owner": matches[0]["external_ids"].get("labctl-m03-owner"),
                    "bridge": bridge,
                    "bridge_uuid": bridge_matches[0]["_uuid"],
                    "port_name": port["name"],
                    "port_uuid": port["_uuid"],
                    "interface_name": host_iface,
                    "interface_uuid": interface_uuid,
                    "port_interfaces": port["interfaces"],
                },
            },
            "return_filter": {
                "port_name": filter_name,
                "lrp": "lrp-mgc-tenant",
                "dynamic-routing-port-name": options.get("dynamic-routing-port-name"),
                "mapping": mapping,
            },
            "links": self._m03_links(marker_run),
            "frr_pathspace": self._m03_pathspace(token),
            "tenant_vrf": {
                "name": "ovnvrf-tenant",
                "kind": "vrf",
                "table": 300,
                "alias": tenant_link.get("ifalias"),
                "node": "ovn-chassis-1",
                "ifindex": tenant_link.get("ifindex"),
                "iflink": self._link_iflink("ovn-chassis-1", "ovnvrf-tenant"),
                "master": tenant_link.get("master"),
                "link_type": tenant_link.get("link_type"),
                "namespace": {
                    "container": "ovn-chassis-1",
                    "container_id": self.docker_catalog()["ovn-chassis-1"]["id"],
                },
            },
            "a_fingerprint": self._a_fingerprint(),
        }
        return section

    def _ovs_name_set(self, node: str | None, table: str) -> set[str]:
        return {
            row["name"]
            for row in self.ovs(node, table, ("_uuid", "name", "external_ids"))
            if isinstance(row.get("name"), str)
        }

    def _observe_resource(self, resource: dict[str, Any], owner: str) -> dict[str, Any]:
        kind = resource["kind"]
        dispatch = {
            "marker": self._observe_marker,
            "docker-container": self._observe_docker,
            "ovs-port-interface": self._observe_ovs_port,
            "ovn-generated-vrf": self._observe_link,
            "linux-veth": self._observe_link,
            "linux-vrf": self._observe_link,
            "linux-bridge": self._observe_link,
            "linux-vxlan": self._observe_link,
            "linux-dummy": self._observe_link,
            "netns": self._observe_netns,
            "frr-config-delta": self._observe_frr,
            "frr-pathspace": self._observe_pathspace,
            "ovs-external-id": self._observe_external_id,
            "lsp-parent-control": self._observe_lsp,
            "capture-processes": self._observe_capture,
            "capture-file": self._observe_capture,
        }
        handler = dispatch.get(kind)
        if handler is None:
            raise AdmissionError(
                "runtime inventory contains an unsupported kind: " + str(kind)
            )
        state, observed = handler(resource)
        observed.update(
            {
                "identity": PREFLIGHT.expected_identity(resource),
                "parent": resource.get("parent"),
            }
        )
        return {
            "identity": PREFLIGHT.expected_identity(resource),
            "ownership": {"owner": owner, "adopt_existing": False},
            "capture_fields": list(resource["capture_before_mutation"]),
            "state": state,
            "observed": observed,
        }

    def _node(self, resource: Mapping[str, Any]) -> str | None:
        host = resource.get("host")
        if host == "host:vm-cilium":
            return None
        if isinstance(host, str) and host.startswith("container:"):
            return host.removeprefix("container:")
        if isinstance(host, str) and host.startswith("netns:"):
            return host
        raise AdmissionError("unsupported runtime host: " + str(host))

    def _parent_absent(self, node: str | None) -> bool:
        if node in {"mgc-client-2", "mgc-x05-peer-2"}:
            return node not in self.docker_catalog()
        if isinstance(node, str) and node.startswith("netns:"):
            _, container, namespace = node.split(":", 2)
            return namespace not in self.netns_names(container)
        return False

    def _observe_marker(self, resource: dict[str, Any]) -> tuple[str, dict[str, Any]]:
        exists = self.marker(self.config.x05_marker_path, required=False) is not None
        return "absent", {"exists": exists}

    def _observe_docker(self, resource: dict[str, Any]) -> tuple[str, dict[str, Any]]:
        exists = resource["name"] in self.docker_catalog()
        return "absent", {"exists": exists, "name": resource["name"]}

    def _observe_link(self, resource: dict[str, Any]) -> tuple[str, dict[str, Any]]:
        node = self._node(resource)
        if self._parent_absent(node):
            exists = False
            state = "absent-parent"
        else:
            exists = resource["name"] in self._link_by_name(node)
            state = "absent"
        observed: dict[str, Any] = {"exists": exists}
        if resource["kind"] == "ovn-generated-vrf":
            observed.update({"generated_by": "OVN", "direct_delete": False})
        return state, observed

    def _observe_netns(self, resource: dict[str, Any]) -> tuple[str, dict[str, Any]]:
        node = self._node(resource)
        return "absent", {"exists": resource["name"] in self.netns_names(node)}

    def _observe_ovs_port(self, resource: dict[str, Any]) -> tuple[str, dict[str, Any]]:
        node = self._node(resource)
        interfaces = self.ovs(node, "Interface", ("_uuid", "name", "external_ids"))
        ports = self.ovs(
            node, "Port", ("_uuid", "name", "interfaces", "tag", "external_ids")
        )
        bridges = self.ovs(node, "Bridge", ("_uuid", "name", "ports"))
        for row in interfaces:
            if (
                not isinstance(row.get("_uuid"), str)
                or PREFLIGHT.UUID_RE.fullmatch(row["_uuid"]) is None
                or not isinstance(row.get("external_ids"), dict)
            ):
                raise AdmissionError("OVS Interface readback is malformed")
        for row in ports:
            if (
                not isinstance(row.get("_uuid"), str)
                or PREFLIGHT.UUID_RE.fullmatch(row["_uuid"]) is None
                or not isinstance(row.get("interfaces"), list)
                or not all(
                    isinstance(value, str)
                    and PREFLIGHT.UUID_RE.fullmatch(value) is not None
                    for value in row["interfaces"]
                )
                or not isinstance(row.get("external_ids"), dict)
            ):
                raise AdmissionError("OVS Port readback is malformed")
        for row in bridges:
            if (
                not isinstance(row.get("_uuid"), str)
                or PREFLIGHT.UUID_RE.fullmatch(row["_uuid"]) is None
                or not isinstance(row.get("ports"), list)
                or not all(
                    isinstance(value, str)
                    and PREFLIGHT.UUID_RE.fullmatch(value) is not None
                    for value in row["ports"]
                )
            ):
                raise AdmissionError("OVS Bridge membership readback is malformed")
        parent = [row for row in bridges if row.get("name") == resource["parent"]]
        if (
            len(parent) != 1
            or not isinstance(parent[0].get("_uuid"), str)
            or PREFLIGHT.UUID_RE.fullmatch(parent[0]["_uuid"]) is None
            or not isinstance(parent[0].get("ports"), list)
        ):
            raise AdmissionError(
                "OVS parent bridge identity is not singular: " + resource["id"]
            )
        logical = resource["name"]
        if ":" in logical:
            container, interface = logical.split(":", 1)
            interface_matches = [
                row
                for row in interfaces
                if (
                    isinstance(row.get("external_ids"), dict)
                    and row["external_ids"].get("container_id") == container
                    and row["external_ids"].get("container_iface") == interface
                )
            ]
        else:
            interface_matches = [
                row for row in interfaces if row.get("name") == logical
            ]
        interface_uuids = {
            row.get("_uuid")
            for row in interface_matches
            if isinstance(row.get("_uuid"), str)
        }
        port_matches = [
            row
            for row in ports
            if (
                row.get("name") == logical
                or bool(interface_uuids & set(row.get("interfaces", [])))
                or (
                    ":" in logical
                    and isinstance(row.get("external_ids"), dict)
                    and row["external_ids"].get("container_id") == container
                    and row["external_ids"].get("container_iface") == interface
                )
            )
        ]
        port_matches = [
            {**row, "parent_member": row.get("_uuid") in parent[0]["ports"]}
            for row in port_matches
        ]
        exists = bool(interface_matches or port_matches)
        return "absent", {
            "exists": exists,
            "parent_bridge_uuid": parent[0]["_uuid"],
            "parent_bridge_ports": parent[0]["ports"],
            "interface_matches": interface_matches,
            "port_matches": port_matches,
        }

    def _observe_frr(self, resource: dict[str, Any]) -> tuple[str, dict[str, Any]]:
        node = self._node(resource)
        assert node is not None
        fixture = resource["desired"]["base_fixture"]
        expected = _read_regular(
            self.fixture_root / fixture,
            maximum=1024 * 1024,
            required_uid=self.config.required_uid
            if not self.config.test_only_paths
            else None,
            forbidden_mode_bits=0o022 if not self.config.test_only_paths else 0,
        )
        actual = self.container_file(node, "/etc/frr/frr.conf")
        running = self.running_config(node)
        running_scope = PREFLIGHT.normalize_frr_running_config(running)
        new_vrf = "ovnvrf300" if node == "ovn-gw-1" else "ovnvrf400"
        return "baseline", {
            "exists": True,
            "fixture": fixture,
            "bytes": len(actual),
            "sha256": _sha256(actual),
            "matches_fixture": actual == expected,
            "extension_absent": not any(
                new_vrf in line.split() for line in running_scope
            ),
            "a_scopes_before": running_scope,
            "a_scopes_sha256": PREFLIGHT.canonical_hash(running_scope),
            "running_config_sha256": _sha256(running.encode("utf-8")),
        }

    def _observe_pathspace(
        self, resource: dict[str, Any]
    ) -> tuple[str, dict[str, Any]]:
        node = self._node(resource)
        if self._parent_absent(node):
            return "absent-parent", {"exists": False, "path_absent": True}
        assert node is not None
        paths = str(resource["parent"]).split(";")
        entries = self.pathspace_entries(node, paths)
        return "absent", {"exists": bool(entries), "path_absent": not entries}

    def _observe_external_id(
        self, resource: dict[str, Any]
    ) -> tuple[str, dict[str, Any]]:
        node = self._node(resource)
        rows = self.ovs(node, "Open_vSwitch", ("_uuid", "external_ids"))
        if len(rows) != 1 or not isinstance(rows[0].get("external_ids"), dict):
            raise AdmissionError("Open_vSwitch external-id readback is malformed")
        value = rows[0]["external_ids"].get(resource["name"])
        state = "baseline" if resource["name"] == "ovn-evpn-local-ip" else "absent"
        observed = {
            "exists": state == "baseline" or value not in (None, "", "absent"),
            "key": resource["name"],
            "value": value,
            "ovs_uuid": rows[0].get("_uuid"),
        }
        return state, observed

    def _observe_lsp(self, resource: dict[str, Any]) -> tuple[str, dict[str, Any]]:
        rows = self.nb("Logical_Switch_Port", resource["name"], ("_uuid", "name"))
        return "absent-parent", {"exists": bool(rows), "b_lsp_absent": not rows}

    def _observe_capture(self, resource: dict[str, Any]) -> tuple[str, dict[str, Any]]:
        target = (
            pathlib.Path(resource["parent"])
            / pathlib.PurePosixPath(resource["name"]).name
        )
        exists = target.exists() or target.is_symlink()
        return "absent", {"exists": exists, "path_absent": not exists}

    def collect_snapshot(self) -> dict[str, Any]:
        mgc = self.mgc_section()
        context = {
            "run_hex": self.config.run_hex,
            "owner": self.config.owner,
            "evidence_path": str(self.config.evidence_path),
            "profile_owner": mgc["profile_owner"],
        }
        plan = PLAN.materialize_plan(
            context["run_hex"],
            context["owner"],
            context["evidence_path"],
            context["profile_owner"],
        )
        resources = {row["id"]: row for row in plan["resources"]}
        if len(resources) != 43:
            raise AdmissionError(
                "materialized runtime plan does not contain exactly 43 resources"
            )
        before = {
            resource_id: self._observe_resource(resource, self.config.owner)
            for resource_id, resource in resources.items()
        }
        if any(
            row["observed"]["exists"]
            for key, row in before.items()
            if row["state"] != "baseline"
        ):
            raise AdmissionError("one or more X05 runtime identities already exist")
        docker = self.docker_section()
        gateway_frr = self.gateway_frr_section()
        m03 = self.m03_section(mgc["profile_owner"])
        generated = {
            resource_id: {
                "exists": before[resource_id]["observed"]["exists"],
                "observation_only": True,
                "generated_by": "OVN",
                "direct_delete": False,
            }
            for resource_id, resource in resources.items()
            if resource["kind"] == "ovn-generated-vrf"
        }
        sections = {
            "m03": m03,
            "mgc": mgc,
            "docker": docker,
            "gateway_frr": gateway_frr,
            "chassis2": self.chassis2_section(),
            "inventory": {
                "status": "PASS",
                "count": 43,
                "gaps": [],
                "resources": sorted(resources),
                "all_absent": True,
                "runtime_plan_sha256": plan["runtime_plan_sha256"],
                "resource_ids_sha256": plan["resource_ids_sha256"],
                "generated_vrfs": generated,
            },
            "evidence": {
                "status": "PASS",
                "path_absent": True,
                "capture_paths": [],
                "capture_processes": [],
            },
        }
        snapshot: dict[str, Any] = {
            "schema": PREFLIGHT.SCHEMA,
            "mode": "live-observed",
            "status": "PASS",
            "errors": [],
            "run_hex": self.config.run_hex,
            "owner": self.config.owner,
            "evidence_path": str(self.config.evidence_path),
            "runtime_plan_sha256": plan["runtime_plan_sha256"],
            "snapshot_sha256": "0" * 64,
            "sections": sections,
            "before": before,
            "x05_marker": {"path": str(DEFAULT_X05_MARKER), "exists": False},
            "journal_seed": {},
        }
        snapshot["snapshot_sha256"] = PREFLIGHT.snapshot_digest(snapshot)
        snapshot["journal_seed"] = {
            "schema": "p004-x05-runtime-journal-seed-v1",
            "run_hex": self.config.run_hex,
            "owner": self.config.owner,
            "evidence_path": str(self.config.evidence_path),
            "runtime_plan_sha256": plan["runtime_plan_sha256"],
            "snapshot_sha256": snapshot["snapshot_sha256"],
            "m03_marker_sha256": m03["marker"]["sha256"],
            "m03_owner_token": m03["owner_token"],
            "m03_run_token": m03["marker"]["run_token"],
            "resource_count": 43,
            "resource_ids_sha256": plan["resource_ids_sha256"],
            "resolved_images": copy.deepcopy(docker["resolved_images"]),
            "resolved_images_sha256": docker["resolved_images_sha256"],
        }
        return snapshot

    def collect_before(self, profile_owner: str) -> dict[str, Any]:
        """Recollect all 43 plan-derived identities with no parallel registry."""
        plan = PLAN.materialize_plan(
            self.config.run_hex,
            self.config.owner,
            str(self.config.evidence_path),
            profile_owner,
        )
        resources = {row["id"]: row for row in plan["resources"]}
        if len(resources) != 43:
            raise AdmissionError(
                "materialized runtime plan does not contain 43 resources"
            )
        before = {
            resource_id: self._observe_resource(resource, self.config.owner)
            for resource_id, resource in resources.items()
        }
        try:
            PREFLIGHT.validate_before(before, resources, self.config.owner)
        except PREFLIGHT.SnapshotError as exc:
            raise AdmissionError(
                "43-resource absence proof failed: " + str(exc)
            ) from exc
        return before

    def g0(self) -> dict[str, Any]:
        receipt = self.validate_receipt()
        self.historical_checks(receipt)
        if self._memory_available_gib() < 4:
            raise AdmissionError("MemAvailable is below 4 GiB")
        catalog = self.docker_catalog()
        if catalog.get("p003-os", {}).get("state") != "exited":
            raise AdmissionError("p003-os is not exited")
        if self.marker(self.config.x05_marker_path, required=False) is not None:
            raise AdmissionError("X05 marker already exists")
        self._assert_m03_absent()
        names = set(catalog["__all_names__"])
        if names & set(PREFLIGHT.FIXED_X05_DOCKER_NAMES):
            raise AdmissionError("X05 Docker identity already exists")
        mgc = self.mgc_section()
        docker = self.docker_section()
        frr = self.gateway_frr_section()
        chassis2 = self.chassis2_section()
        context = {
            "run_hex": self.config.run_hex,
            "owner": self.config.owner,
            "evidence_path": str(self.config.evidence_path),
            "profile_owner": mgc["profile_owner"],
        }
        plan = PLAN.materialize_plan(
            context["run_hex"],
            context["owner"],
            context["evidence_path"],
            context["profile_owner"],
        )
        before = {
            resource["id"]: self._observe_resource(resource, self.config.owner)
            for resource in plan["resources"]
        }
        if any(
            row["observed"]["exists"]
            for row in before.values()
            if row["state"] != "baseline"
        ):
            raise AdmissionError("one or more X05 identities already exist at G0")
        resources = {row["id"]: row for row in plan["resources"]}
        try:
            PREFLIGHT.validate_mgc(mgc)
            PREFLIGHT.validate_docker(docker, resources)
            PREFLIGHT.validate_gateway_frr(frr, resources)
            PREFLIGHT.validate_chassis2(chassis2)
            PREFLIGHT.validate_before(before, resources, self.config.owner)
        except PREFLIGHT.SnapshotError as exc:
            raise AdmissionError("G0 baseline validation failed: " + str(exc)) from exc
        return {
            **self.input_digests(),
            "mgc": mgc,
            "docker": docker,
            "gateway_frr": frr,
            "chassis2": chassis2,
            "before": before,
            "before_sha256": _digest(before),
        }

    def _assert_m03_absent(self) -> None:
        if self.marker(self.config.m03_marker_path, required=False) is not None:
            raise AdmissionError("M03 marker exists outside the owned setup interval")
        catalog = self.docker_catalog()
        if "mgc-evpn-client-1" in catalog:
            raise AdmissionError("M03 peer container residue exists")
        links = self._link_by_name("ovn-chassis-1")
        residue = set(links) & (
            {row[0] for row in PREFLIGHT.M03_LINKS if row[2] == "chassis"}
            | {"ovnvrf-tenant"}
        )
        if residue:
            raise AdmissionError(
                "M03 chassis link residue exists: " + ",".join(sorted(residue))
            )
        host_interfaces = self.ovs(None, "Interface", ("_uuid", "name", "external_ids"))
        if any(
            isinstance(row.get("external_ids"), dict)
            and row["external_ids"].get("container_id") == "mgc-evpn-client-1"
            for row in host_interfaces
        ):
            raise AdmissionError("M03 peer OVS port residue exists")
        if self.pathspace_entries("ovn-chassis-1", ("/etc/frr/m03", "/run/frr/m03")):
            raise AdmissionError("M03 FRR pathspace residue exists")
        lrp = self.nb(
            "Logical_Router_Port", "lrp-mgc-tenant", ("_uuid", "name", "options")
        )
        if len(lrp) != 1 or not isinstance(lrp[0].get("options"), dict):
            raise AdmissionError("baseline tenant LRP readback is malformed")
        if any(
            key in lrp[0]["options"]
            for key in ("dynamic-routing-port-name", "dynamic-routing-maintain-vrf")
        ):
            raise AdmissionError("M03 tenant LRP option residue exists")
        chassis1 = self.ovs("ovn-chassis-1", "Open_vSwitch", ("_uuid", "external_ids"))
        if len(chassis1) != 1 or not isinstance(chassis1[0].get("external_ids"), dict):
            raise AdmissionError("baseline chassis 1 OVS readback is malformed")
        if "dynamic-routing-port-mapping" in chassis1[0]["external_ids"]:
            raise AdmissionError("M03 chassis mapping residue exists")

    @staticmethod
    def baseline_anchors(
        mgc: Mapping[str, Any],
        docker: Mapping[str, Any],
        gateway_frr: Mapping[str, Any],
        chassis2: Mapping[str, Any],
        before: Mapping[str, Any],
    ) -> dict[str, Any]:
        return {
            "container_ids": mgc["container_ids"],
            "recorded_ids": mgc["recorded_ids"],
            "profile_owner": mgc["profile_owner"],
            "bridges": mgc["bridges"],
            "recorded_bridge_uuids": mgc["recorded_bridge_uuids"],
            "container_labels": mgc["container_labels"],
            "original_image_bindings": mgc["original_image_bindings"],
            "gateway_frr": gateway_frr,
            "chassis2": chassis2,
            "resolved_images": docker["resolved_images"],
            "before": before,
        }

    @staticmethod
    def before_absence_anchor(before: Mapping[str, Any]) -> dict[str, Any]:
        """Compare X05 identity absence while allowing owned M03 parent membership."""
        anchored = copy.deepcopy(dict(before))
        for row in anchored.values():
            observed = row.get("observed") if isinstance(row, dict) else None
            if isinstance(observed, dict):
                observed.pop("parent_bridge_ports", None)
        return anchored

    def post_cleanup_baseline(
        self,
        expected_inputs: Mapping[str, str],
        expected_baseline: Mapping[str, Any],
    ) -> None:
        self.clear_cache()
        if self.input_digests() != dict(expected_inputs):
            raise AdmissionIncident(
                "receipt or explicit kubeconfig changed during admission"
            )
        receipt = self.validate_receipt()
        self.historical_checks(receipt)
        if self.marker(self.config.x05_marker_path, required=False) is not None:
            raise AdmissionIncident("X05 marker remains after G0/G0a cleanup")
        self._assert_m03_absent()
        catalog = self.docker_catalog()
        if catalog.get("p003-os", {}).get("state") != "exited":
            raise AdmissionIncident("p003-os changed state during admission")
        mgc = self.mgc_section()
        docker = self.docker_section()
        gateway_frr = self.gateway_frr_section()
        chassis2 = self.chassis2_section()
        try:
            PREFLIGHT.validate_mgc(mgc)
            resources = PREFLIGHT.load_expected_resources()
            PREFLIGHT.validate_docker(docker, resources)
            PREFLIGHT.validate_gateway_frr(gateway_frr, resources)
            PREFLIGHT.validate_chassis2(chassis2)
        except PREFLIGHT.SnapshotError as exc:
            raise AdmissionIncident(
                "post-cleanup baseline ownership drifted: " + str(exc)
            ) from exc
        before = self.collect_before(mgc["profile_owner"])
        current_baseline = self.baseline_anchors(
            mgc, docker, gateway_frr, chassis2, before
        )
        if current_baseline != dict(expected_baseline):
            raise AdmissionIncident("post-cleanup baseline differs from G0")

    @staticmethod
    def anchors_from_snapshot(snapshot: Mapping[str, Any]) -> dict[str, Any]:
        sections = snapshot["sections"]
        return {
            "container_ids": sections["mgc"]["container_ids"],
            "recorded_ids": sections["mgc"]["recorded_ids"],
            "profile_owner": sections["mgc"]["profile_owner"],
            "bridges": sections["mgc"]["bridges"],
            "recorded_bridge_uuids": sections["mgc"]["recorded_bridge_uuids"],
            "container_labels": sections["mgc"]["container_labels"],
            "original_image_bindings": sections["mgc"]["original_image_bindings"],
            "gateway_frr": sections["gateway_frr"],
            "chassis2": sections["chassis2"],
            "resolved_images": sections["docker"]["resolved_images"],
            "m03_marker": sections["m03"]["marker"]["sha256"],
            "m03_owner": sections["m03"]["owner_token"],
            "m03_peer": sections["m03"]["peer"],
            "m03_links": sections["m03"]["links"],
            "m03_filter": sections["m03"]["return_filter"],
            "m03_pathspace": sections["m03"]["frr_pathspace"],
            "m03_tenant_vrf": sections["m03"]["tenant_vrf"],
            "a_fingerprint": sections["m03"]["a_fingerprint"],
            "before": snapshot["before"],
        }

    def current_anchors(self) -> dict[str, Any]:
        self.clear_cache()
        mgc = self.mgc_section()
        frr = self.gateway_frr_section()
        images = self.image_ids()
        m03 = self.m03_section(mgc["profile_owner"])
        chassis2 = self.chassis2_section()
        before = self.collect_before(mgc["profile_owner"])
        return {
            "container_ids": mgc["container_ids"],
            "recorded_ids": mgc["recorded_ids"],
            "profile_owner": mgc["profile_owner"],
            "bridges": mgc["bridges"],
            "recorded_bridge_uuids": mgc["recorded_bridge_uuids"],
            "container_labels": mgc["container_labels"],
            "original_image_bindings": mgc["original_image_bindings"],
            "gateway_frr": frr,
            "chassis2": chassis2,
            "resolved_images": images,
            "m03_marker": m03["marker"]["sha256"],
            "m03_owner": m03["owner_token"],
            "m03_peer": m03["peer"],
            "m03_links": m03["links"],
            "m03_filter": m03["return_filter"],
            "m03_pathspace": m03["frr_pathspace"],
            "m03_tenant_vrf": m03["tenant_vrf"],
            "a_fingerprint": m03["a_fingerprint"],
            "before": before,
        }

    def owned_m03_identity(self, profile_owner: str) -> dict[str, Any] | None:
        """Return complete MGC/M03 ownership readback, or ``None`` on uncertainty."""
        try:
            self.clear_cache()
            mgc = self.mgc_section()
            m03 = self.m03_section(profile_owner)
            PREFLIGHT.validate_mgc(mgc)
            PREFLIGHT.validate_marker(m03, profile_owner)
            if mgc["profile_owner"] != profile_owner:
                raise AdmissionError(
                    "MGC profile owner changed during ownership readback"
                )
        except (AdmissionError, PREFLIGHT.SnapshotError, OSError, ValueError):
            return None
        return {"mgc": mgc, "m03": m03}

    def prove_owned_m03(self, profile_owner: str) -> bool:
        """Return true only for a complete marker/peer/profile ownership proof."""
        return self.owned_m03_identity(profile_owner) is not None


class PreparedAdmission:
    """Opaque, session-bound capability for an immediate coordinator handoff."""

    __slots__ = (
        "_session",
        "_origin",
        "_event_authority",
        "_snapshot_path",
        "_snapshot_sha256",
        "_snapshot_file_sha256",
        "_inputs_sha256",
        "_anchors_sha256",
        "_bundle_manifest_sha256",
        "_event_head",
        "_event_count",
        "_active",
        "_consumed",
    )

    def __init__(
        self,
        session: "AdmissionSession",
        *,
        snapshot_path: pathlib.Path,
        snapshot_sha256: str,
        snapshot_file_sha256: str,
        inputs_sha256: str,
        anchors_sha256: str,
        bundle_manifest_sha256: str,
        event_head: str,
        event_count: int,
    ) -> None:
        origin = session._origin
        event_authority = session._event_authority
        if (
            type(origin) is not _AdmissionOrigin
            or origin.session is not session
            or type(event_authority) is not _EventLogAuthority
        ):
            raise AdmissionError("prepared admission lacks original producer authority")
        self._session = session
        self._origin = origin
        self._event_authority = event_authority
        self._snapshot_path = snapshot_path
        self._snapshot_sha256 = snapshot_sha256
        self._snapshot_file_sha256 = snapshot_file_sha256
        self._inputs_sha256 = inputs_sha256
        self._anchors_sha256 = anchors_sha256
        self._bundle_manifest_sha256 = bundle_manifest_sha256
        self._event_head = event_head
        self._event_count = event_count
        self._active = True
        self._consumed = False

    @property
    def snapshot_path(self) -> pathlib.Path:
        return self._snapshot_path

    @property
    def snapshot_sha256(self) -> str:
        return self._snapshot_sha256

    @property
    def input_digests_sha256(self) -> str:
        return self._inputs_sha256

    @property
    def anchors_sha256(self) -> str:
        return self._anchors_sha256

    @property
    def bundle_manifest_sha256(self) -> str:
        return self._bundle_manifest_sha256

    @property
    def execution_session(self) -> "AdmissionSession":
        """Return the original producer only while this capability revalidates."""
        self._origin.session_verify_execution(self._origin.session, self)
        return self._origin.session

    @property
    def active(self) -> bool:
        return (
            self._active
            and self._session is self._origin.session
            and self._session._origin is self._origin
            and self._session._event_authority is self._event_authority
            and self._session._entered
            and not self._session._closed
            and self._session._prepared is self
        )

    @property
    def consumed(self) -> bool:
        return self._consumed and self.active

    def __copy__(self):
        raise TypeError("PreparedAdmission capabilities cannot be copied")

    def __deepcopy__(self, memo):
        raise TypeError("PreparedAdmission capabilities cannot be copied")

    def __reduce__(self):
        raise TypeError("PreparedAdmission capabilities cannot be serialized")

    def _invalidate(self) -> None:
        self._active = False


class _IncidentTrackingRunner:
    def __init__(self, session: "AdmissionSession", delegate: Runner) -> None:
        delegate_type = type(delegate)
        delegate_run = getattr(delegate_type, "run", None)
        if not callable(delegate_run) or _has_instance_shadow(delegate, "run"):
            raise AdmissionError("runner delegate has no canonical class run method")
        self._session = session
        self._delegate = delegate
        self._delegate_type = delegate_type
        self._delegate_run = delegate_run

    def run(self, *args, **kwargs) -> CommandResult:
        if (
            type(self._delegate) is not self._delegate_type
            or getattr(self._delegate_type, "run", None) is not self._delegate_run
            or _has_instance_shadow(self._delegate, "run")
        ):
            raise AdmissionIncident("runner delegate authority changed")
        try:
            return self._delegate_run(self._delegate, *args, **kwargs)
        except Exception:
            if 9 in tuple(kwargs.get("pass_fds", ())):
                # Once an FD9-inheriting command has an unknown outcome, an
                # escaped descendant cannot safely be ruled out.
                self._session._retained_descriptor = True
            raise


class AdmissionSession:
    """Own FD 9 from G0 until the single owned M03 cleanup finishes."""

    def __init__(self, config: AdmissionConfig, runner: Runner | None = None) -> None:
        if type(config) is not AdmissionConfig:
            raise ValueError("admission requires the canonical config type")
        if (
            not config.test_only_paths
            and runner is not None
            and runner.__class__ is not SubprocessRunner
        ):
            raise ValueError("production admission only accepts SubprocessRunner")
        self.config = config
        delegate = runner if runner is not None else SubprocessRunner()
        self._retained_descriptor = False
        self.runner = _IncidentTrackingRunner(self, delegate)
        self.collector = LiveCollector(config, self.runner)
        self.events = DurableEventLog(config.event_path, uid=config.required_uid)
        self._entered = False
        self._closed = False
        self._lock_fd: int | None = None
        self._lock_keeper_fd: int | None = None
        self._lock_canonical_path: pathlib.Path | None = None
        self._lock_metadata: tuple[int, ...] | None = None
        self._lock_acquisition_pid: int | None = None
        self._lock_fdinfo_anchor: tuple[int, ...] | None = None
        self._lock_authority_lost = False
        self._lock_authority_failure: str | None = None
        self._lock_keeper_retained = False
        self._lock_retention_evidence: dict[str, Any] | None = None
        self._consume_lock = threading.RLock()
        self._execution_failure: str | None = None
        self._prepare_attempted = False
        self._setup_attempted = False
        self._owned_m03 = False
        self._m03_ownership_sha256: str | None = None
        self._cleanup_attempted = False
        self._profile_owner: str | None = None
        self._input_digests: dict[str, str] | None = None
        self._baseline_anchors: dict[str, Any] | None = None
        self._labctl_identity: tuple[int, ...] | None = None
        self._bundle_manifest_sha256: str | None = None
        self._expected_anchors: dict[str, Any] | None = None
        self._prepared: PreparedAdmission | None = None
        self._snapshot_identity: tuple[int, int] | None = None
        self._event_authority: _EventLogAuthority | None = None
        session_private_method_names = (
            "_assert_origin_bindings_locked",
            "_event_descriptor_matches",
            "_capture_event_authority_locked",
            "_assert_event_authority_locked",
            "_event_append_locked",
            "_event_verify_locked",
            "_event_count_locked",
            "_close_original_event_locked",
            "_close_after_origin_loss_locked",
            "_enter_locked",
            "_assert_target_absent",
            "_acquire_lock",
            "_duplicate_lock_keeper",
            "_lock_metadata_tuple",
            "_lock_authority_incident",
            "_verified_lock_metadata_snapshot",
            "_verify_lock_descriptor_boundary",
            "_validated_lock_fdinfo_tuple",
            "_observe_lock_fdinfo_pair",
            "_collect_lock_authority_observation",
            "_descriptor_retention_evidence",
            "_capture_lock_retention_evidence",
            "_remember_lock_retention_evidence",
            "_lock_retention_event_detail",
            "_prove_lock_authority",
            "_release_lock",
            "_verify_bundle",
            "_identity_detail",
            "_lifecycle_env",
            "_labctl",
            "_command_detail",
            "_prepare_locked",
            "_consume_locked",
            "_assert_execution_capability_locked",
            "_remember_execution_failure",
            "_verified_execution_snapshot_locked",
            "_verify_execution_state_locked",
            "_verify_execution_locked",
            "_assert_labctl_executable",
            "_discover_cleanup_ownership",
            "_persist_snapshot",
            "_verify_published_evidence",
            "_close_locked",
        )
        collector_method_names = (
            "_run",
            "anchors_from_snapshot",
            "baseline_anchors",
            "before_absence_anchor",
            "chassis2_section",
            "clear_cache",
            "collect_before",
            "collect_snapshot",
            "current_anchors",
            "docker_section",
            "g0",
            "gateway_frr_section",
            "input_digests",
            "marker",
            "mgc_section",
            "owned_m03_identity",
            "post_cleanup_baseline",
            "validate_receipt",
        )
        event_head_get = DurableEventLog.head.fget
        event_count_get = DurableEventLog.count.fget
        assert event_head_get is not None and event_count_get is not None
        self._origin = _AdmissionOrigin(
            session=self,
            session_type=type(self),
            config=config,
            config_anchor=_admission_config_value_anchor(config),
            runner=self.runner,
            runner_type=type(self.runner),
            runner_run=type(self.runner).run,
            delegate=self.runner._delegate,
            delegate_type=self.runner._delegate_type,
            delegate_run=self.runner._delegate_run,
            collector=self.collector,
            collector_type=type(self.collector),
            collector_methods=tuple(
                (name, getattr(type(self.collector), name))
                for name in collector_method_names
            ),
            consume_lock=self._consume_lock,
            consume_lock_type=type(self._consume_lock),
            events=self.events,
            events_type=type(self.events),
            event_path=self.events.path,
            event_uid=self.events.uid,
            event_open=type(self.events).open,
            event_append=type(self.events).append,
            event_verify=type(self.events).verify,
            event_close=type(self.events).close,
            event_head_get=event_head_get,
            event_count_get=event_count_get,
            session_private_methods=tuple(
                (name, getattr(type(self), name))
                for name in session_private_method_names
            ),
            session_prepare=type(self).prepare,
            session_consume=type(self).consume,
            session_verify_execution=type(self).verify_execution,
            session_execution_context=type(self).execution_context,
            session_record_execution_event=type(self).record_execution_event,
            session_close=type(self).close,
        )

    def _assert_origin_bindings_locked(
        self,
        origin: _AdmissionOrigin,
        event_authority: _EventLogAuthority | None = None,
        *,
        require_event: bool,
    ) -> None:
        """Reject replacement of any construction-time authority object."""

        session_methods = (
            ("prepare", origin.session_prepare),
            ("consume", origin.session_consume),
            ("verify_execution", origin.session_verify_execution),
            ("execution_context", origin.session_execution_context),
            ("record_execution_event", origin.session_record_execution_event),
            ("close", origin.session_close),
        )
        event_methods = (
            ("open", origin.event_open),
            ("append", origin.event_append),
            ("verify", origin.event_verify),
            ("close", origin.event_close),
        )
        try:
            config_anchor = _admission_config_value_anchor(origin.config)
        except (AdmissionError, AttributeError, TypeError, ValueError) as exc:
            raise AdmissionIncident("original admission config changed") from exc
        if (
            origin.session is not self
            or self._origin is not origin
            or type(self) is not origin.session_type
            or self.config is not origin.config
            or config_anchor != origin.config_anchor
            or self.runner is not origin.runner
            or type(origin.runner) is not origin.runner_type
            or origin.runner._session is not self
            or origin.runner._delegate is not origin.delegate
            or origin.runner._delegate_type is not origin.delegate_type
            or origin.runner._delegate_run is not origin.delegate_run
            or getattr(origin.runner_type, "run", None) is not origin.runner_run
            or _has_instance_shadow(origin.runner, "run")
            or type(origin.delegate) is not origin.delegate_type
            or getattr(origin.delegate_type, "run", None) is not origin.delegate_run
            or _has_instance_shadow(origin.delegate, "run")
            or self.collector is not origin.collector
            or type(origin.collector) is not origin.collector_type
            or origin.collector.config is not origin.config
            or origin.collector.runner is not origin.runner
            or self._consume_lock is not origin.consume_lock
            or type(origin.consume_lock) is not origin.consume_lock_type
            or self.events is not origin.events
            or type(origin.events) is not origin.events_type
            or origin.events.path is not origin.event_path
            or type(origin.events.uid) is not int
            or origin.events.uid != origin.event_uid
            or origin.event_path != origin.config.event_path
            or not origin.event_path.is_absolute()
            or type(origin.events_type.head) is not property
            or origin.events_type.head.fget is not origin.event_head_get
            or type(origin.events_type.count) is not property
            or origin.events_type.count.fget is not origin.event_count_get
            or _has_instance_shadow(origin.events, "head")
            or _has_instance_shadow(origin.events, "count")
        ):
            raise AdmissionIncident("original admission authority binding changed")
        for name, implementation in session_methods:
            if (
                getattr(origin.session_type, name, None) is not implementation
                or _has_instance_shadow(self, name)
            ):
                raise AdmissionIncident(
                    "original admission session callable changed: " + name
                )
        for name, implementation in origin.session_private_methods:
            if (
                getattr(origin.session_type, name, None) is not implementation
                or _has_instance_shadow(self, name)
            ):
                raise AdmissionIncident(
                    "original admission session helper changed: " + name
                )
        for name, implementation in origin.collector_methods:
            if (
                getattr(origin.collector_type, name, None) is not implementation
                or _has_instance_shadow(origin.collector, name)
            ):
                raise AdmissionIncident(
                    "original admission collector callable changed: " + name
                )
        for name, implementation in event_methods:
            if (
                getattr(origin.events_type, name, None) is not implementation
                or _has_instance_shadow(origin.events, name)
            ):
                raise AdmissionIncident(
                    "original admission event callable changed: " + name
                )
        if require_event:
            if (
                type(event_authority) is not _EventLogAuthority
                or self._event_authority is not event_authority
            ):
                raise AdmissionIncident("event-log authority anchor changed")
            _original_session_method(origin, "_assert_event_authority_locked")(
                self, origin, event_authority
            )

    @staticmethod
    def _event_descriptor_matches(
        origin: _AdmissionOrigin, authority: _EventLogAuthority
    ) -> bool:
        if (
            type(origin.events._fd) is not int
            or origin.events._fd != authority.descriptor
            or type(origin.events._identity) is not tuple
            or origin.events._identity != authority.identity
        ):
            return False
        try:
            info = os.fstat(authority.descriptor)
            status_flags = fcntl.fcntl(authority.descriptor, fcntl.F_GETFL) & (
                getattr(os, "O_ACCMODE", 3) | os.O_APPEND
            )
            descriptor_flags = fcntl.fcntl(
                authority.descriptor, fcntl.F_GETFD
            ) & fcntl.FD_CLOEXEC
        except OSError:
            return False
        return (
            stat.S_ISREG(info.st_mode)
            and (info.st_dev, info.st_ino) == authority.identity
            and _mode(info) == authority.mode
            and info.st_uid == authority.uid
            and status_flags == authority.status_flags
            and descriptor_flags == authority.descriptor_flags
        )

    def _capture_event_authority_locked(
        self, origin: _AdmissionOrigin
    ) -> _EventLogAuthority:
        descriptor = origin.events._fd
        identity = origin.events._identity
        if (
            type(descriptor) is not int
            or type(identity) is not tuple
            or len(identity) != 2
            or any(type(value) is not int for value in identity)
        ):
            raise AdmissionIncident("opened event log lacks descriptor identity")
        try:
            opened = os.fstat(descriptor)
            current = origin.event_path.lstat()
            status_flags = fcntl.fcntl(descriptor, fcntl.F_GETFL) & (
                getattr(os, "O_ACCMODE", 3) | os.O_APPEND
            )
            descriptor_flags = (
                fcntl.fcntl(descriptor, fcntl.F_GETFD) & fcntl.FD_CLOEXEC
            )
        except OSError as exc:
            raise AdmissionIncident("opened event log cannot be anchored") from exc
        if (
            stat.S_ISLNK(current.st_mode)
            or not stat.S_ISREG(opened.st_mode)
            or not stat.S_ISREG(current.st_mode)
            or (opened.st_dev, opened.st_ino) != identity
            or (current.st_dev, current.st_ino) != identity
            or _mode(opened) != 0o600
            or _mode(current) != 0o600
            or opened.st_uid != origin.event_uid
            or current.st_uid != origin.event_uid
            or status_flags != (os.O_WRONLY | os.O_APPEND)
            or descriptor_flags != fcntl.FD_CLOEXEC
        ):
            raise AdmissionIncident("opened event log is not the canonical private file")
        return _EventLogAuthority(
            descriptor=descriptor,
            identity=identity,
            mode=0o600,
            uid=origin.event_uid,
            status_flags=status_flags,
            descriptor_flags=descriptor_flags,
        )

    def _assert_event_authority_locked(
        self, origin: _AdmissionOrigin, authority: _EventLogAuthority
    ) -> None:
        if not _original_session_method(origin, "_event_descriptor_matches")(
            origin, authority
        ):
            raise AdmissionIncident("event-log descriptor authority changed")
        try:
            current = origin.event_path.lstat()
        except OSError as exc:
            raise AdmissionIncident("canonical event-log path is unavailable") from exc
        if (
            stat.S_ISLNK(current.st_mode)
            or not stat.S_ISREG(current.st_mode)
            or (current.st_dev, current.st_ino) != authority.identity
            or _mode(current) != authority.mode
            or current.st_uid != authority.uid
        ):
            raise AdmissionIncident("canonical event-log path authority changed")

    def _event_append_locked(
        self, event: str, detail: Mapping[str, Any]
    ) -> dict[str, Any]:
        origin = self._origin
        authority = self._event_authority
        guard = _original_session_method(origin, "_assert_origin_bindings_locked")
        guard(self, origin, authority, require_event=True)
        assert type(authority) is _EventLogAuthority
        record = origin.event_append(origin.events, event, detail)
        guard(self, origin, authority, require_event=True)
        return record

    def _event_verify_locked(self) -> dict[str, Any]:
        origin = self._origin
        authority = self._event_authority
        guard = _original_session_method(origin, "_assert_origin_bindings_locked")
        guard(self, origin, authority, require_event=True)
        assert type(authority) is _EventLogAuthority
        chain = origin.event_verify(origin.events)
        guard(self, origin, authority, require_event=True)
        return chain

    def _event_count_locked(self) -> int:
        origin = self._origin
        authority = self._event_authority
        _original_session_method(origin, "_assert_origin_bindings_locked")(
            self, origin, authority, require_event=True
        )
        return origin.event_count_get(origin.events)

    def _close_original_event_locked(
        self, origin: _AdmissionOrigin, authority: _EventLogAuthority | None
    ) -> bool:
        if type(authority) is _EventLogAuthority:
            if not _original_session_method(origin, "_event_descriptor_matches")(
                origin, authority
            ):
                return False
        elif origin.events._fd is not None:
            identity = origin.events._identity
            try:
                info = os.fstat(origin.events._fd)
            except OSError:
                return False
            if (
                identity is None
                or (info.st_dev, info.st_ino) != identity
                or not stat.S_ISREG(info.st_mode)
                or _mode(info) != 0o600
                or info.st_uid != origin.event_uid
            ):
                return False
        origin.event_close(origin.events)
        return True

    def _close_after_origin_loss_locked(
        self, origin: _AdmissionOrigin, failure: AdmissionIncident
    ) -> None:
        if self._prepared is not None:
            self._prepared._invalidate()
        self._lock_authority_lost = True
        if self._lock_authority_failure is None:
            self._lock_authority_failure = str(failure)
        try:
            _original_session_method(origin, "_close_original_event_locked")(
                self, origin, self._event_authority
            )
        except OSError:
            pass
        self._closed = True
        raise failure

    def __enter__(self) -> "AdmissionSession":
        origin = self._origin
        if type(origin) is not _AdmissionOrigin:
            raise AdmissionIncident("original admission provenance changed")
        with origin.consume_lock:
            _original_session_method(origin, "_assert_origin_bindings_locked")(
                self, origin, require_event=False
            )
            return _original_session_method(origin, "_enter_locked")(self, origin)

    def _enter_locked(self, origin: _AdmissionOrigin) -> "AdmissionSession":
        if self._entered or self._closed:
            raise AdmissionError("admission session cannot be entered twice")
        if self.config.test_only_paths:
            load_local_test_modules()
        else:
            self._bundle_manifest_sha256 = _verify_reviewed_bundle(
                self.config.bundle_root, required_uid=self.config.required_uid
            )
            _load_reviewed_bundle_modules(self.config.bundle_root)
            if self._verify_bundle() != self._bundle_manifest_sha256:
                raise AdmissionError("reviewed bundle changed while loading helpers")
        _assert_private_directory(self.config.run_parent, self.config.required_uid)
        self._assert_target_absent()
        if (
            self.config.m03_evidence_path.exists()
            or self.config.m03_evidence_path.is_symlink()
        ):
            raise AdmissionError("M03 setup evidence path already exists")
        self._acquire_lock()
        try:
            origin.event_open(origin.events)
            self._event_authority = _original_session_method(
                origin, "_capture_event_authority_locked"
            )(self, origin)
            _original_session_method(origin, "_assert_origin_bindings_locked")(
                self, origin, self._event_authority, require_event=True
            )
            self._entered = True
            _original_session_method(origin, "_event_append_locked")(
                self, "lock-acquired", self._identity_detail()
            )
        except Exception:
            try:
                _original_session_method(origin, "_close_original_event_locked")(
                    self, origin, self._event_authority
                )
            finally:
                self._entered = False
                self._release_lock()
            raise
        return self

    def __exit__(self, exc_type, exc, traceback) -> bool:
        try:
            origin = self._origin
            if type(origin) is not _AdmissionOrigin:
                raise AdmissionIncident("original admission provenance changed")
            origin.session_close(origin.session)
        except Exception as close_error:
            if exc is None:
                raise
            if hasattr(exc, "add_note"):
                exc.add_note("admission cleanup also failed: " + str(close_error))
        return False

    def _assert_target_absent(self) -> None:
        if self.config.evidence_path.exists() or self.config.evidence_path.is_symlink():
            raise AdmissionError("X05 evidence target already exists")

    def _acquire_lock(self) -> None:
        try:
            os.fstat(9)
        except OSError as exc:
            if exc.errno != errno.EBADF:
                raise
        else:
            raise AdmissionError("FD 9 is already open; refusing to replace it")
        path = self.config.lock_path
        if path.exists() or path.is_symlink():
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
                raise AdmissionError("M03 lock path is not a regular non-symlink file")
            if info.st_uid != self.config.required_uid or _mode(info) != 0o600:
                raise AdmissionError("M03 lock path owner or mode is wrong")
        flags = (
            os.O_RDWR
            | os.O_CREAT
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
        raw_fd = os.open(path, flags, 0o600)
        keeper_fd: int | None = None
        acquisition_pid: int | None = None
        try:
            info = os.fstat(raw_fd)
            if info.st_uid != self.config.required_uid or _mode(info) != 0o600:
                raise AdmissionError("M03 lock descriptor owner or mode is wrong")
            if raw_fd != 9:
                os.dup2(raw_fd, 9, inheritable=True)
                os.close(raw_fd)
                raw_fd = 9
            else:
                os.set_inheritable(raw_fd, True)
            try:
                fcntl.flock(raw_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise AdmissionError("M03 lock is held by another coordinator") from exc
            acquisition_pid = os.getpid()
            opened = os.fstat(raw_fd)
            current = path.lstat()
            if stat.S_ISLNK(current.st_mode) or not stat.S_ISREG(current.st_mode):
                raise AdmissionError("M03 lock path identity changed while opening")
            if (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino):
                raise AdmissionError("FD 9 does not match the M03 lock inode")
            canonical = path.resolve(strict=True)
            if canonical != pathlib.Path(os.path.realpath(path)):
                raise AdmissionError("M03 lock path is not canonical")
            metadata = self._lock_metadata_tuple(opened)
            if self._lock_metadata_tuple(current) != metadata:
                raise AdmissionError("M03 lock path metadata changed while opening")
            keeper_fd = self._duplicate_lock_keeper(raw_fd)
            if self._lock_metadata_tuple(os.fstat(keeper_fd)) != metadata:
                raise AdmissionError("M03 lock keeper does not match FD 9")
            final_path = path.lstat()
            if (
                stat.S_ISLNK(final_path.st_mode)
                or not stat.S_ISREG(final_path.st_mode)
                or self._lock_metadata_tuple(final_path) != metadata
                or path.resolve(strict=True) != canonical
            ):
                raise AdmissionError("M03 lock path changed while creating keeper")
            self._lock_fd = raw_fd
            self._lock_keeper_fd = keeper_fd
            self._lock_canonical_path = canonical
            self._lock_metadata = metadata
            self._lock_acquisition_pid = acquisition_pid
            self._lock_fdinfo_anchor = self._collect_lock_authority_observation()
        except Exception:
            self._lock_fd = None
            self._lock_keeper_fd = None
            self._lock_canonical_path = None
            self._lock_metadata = None
            self._lock_acquisition_pid = None
            self._lock_fdinfo_anchor = None
            if keeper_fd is not None:
                try:
                    os.close(keeper_fd)
                except OSError:
                    pass
            try:
                os.close(raw_fd)
            except OSError:
                pass
            raise

    @staticmethod
    def _duplicate_lock_keeper(fd: int) -> int:
        command = getattr(fcntl, "F_DUPFD_CLOEXEC", None)
        if command is None:
            keeper = os.dup(fd)
        else:
            keeper = fcntl.fcntl(fd, command, 10)
        try:
            descriptor_flags = fcntl.fcntl(keeper, fcntl.F_GETFD)
            fcntl.fcntl(
                keeper,
                fcntl.F_SETFD,
                descriptor_flags | fcntl.FD_CLOEXEC,
            )
            os.set_inheritable(keeper, False)
            if os.get_inheritable(keeper) or not (
                fcntl.fcntl(keeper, fcntl.F_GETFD) & fcntl.FD_CLOEXEC
            ):
                raise AdmissionError("M03 lock keeper is inheritable")
        except Exception:
            os.close(keeper)
            raise
        return keeper

    @staticmethod
    def _lock_metadata_tuple(info: os.stat_result) -> tuple[int, ...]:
        return (
            info.st_dev,
            info.st_ino,
            info.st_mode,
            info.st_uid,
            info.st_gid,
            info.st_nlink,
            info.st_size,
            info.st_mtime_ns,
            info.st_ctime_ns,
        )

    def _lock_authority_incident(self, reason: str) -> AdmissionIncident:
        self._lock_authority_lost = True
        if self._lock_authority_failure is None:
            self._lock_authority_failure = reason
        return AdmissionIncident(self._lock_authority_failure)

    def _verified_lock_metadata_snapshot(
        self,
    ) -> tuple[os.stat_result, os.stat_result]:
        if (
            self._lock_fd != 9
            or self._lock_keeper_fd is None
            or self._lock_canonical_path is None
            or self._lock_metadata is None
        ):
            raise AdmissionError(
                "M03 lock authority has no complete FD/path/keeper anchor"
            )
        try:
            fd9_info = os.fstat(9)
            keeper_info = os.fstat(self._lock_keeper_fd)
            path_info = self.config.lock_path.lstat()
            canonical = self.config.lock_path.resolve(strict=True)
        except (OSError, RuntimeError) as exc:
            raise AdmissionError(
                "M03 lock FD, keeper, or canonical path is unavailable"
            ) from exc
        if (
            stat.S_ISLNK(path_info.st_mode)
            or not stat.S_ISREG(path_info.st_mode)
            or canonical != self._lock_canonical_path
            or self._lock_metadata_tuple(path_info) != self._lock_metadata
            or self._lock_metadata_tuple(fd9_info) != self._lock_metadata
            or self._lock_metadata_tuple(keeper_info) != self._lock_metadata
        ):
            raise AdmissionError(
                "M03 lock FD, keeper, or canonical path metadata drifted"
            )
        return fd9_info, keeper_info

    @staticmethod
    def _verify_lock_descriptor_boundary(
        descriptor: int,
        *,
        expected_inheritable: bool,
        label: str,
    ) -> None:
        try:
            inheritable = os.get_inheritable(descriptor)
            descriptor_flags = fcntl.fcntl(descriptor, fcntl.F_GETFD)
        except OSError as exc:
            raise AdmissionError(
                f"M03 lock {label} descriptor flags could not be observed"
            ) from exc
        expected_cloexec = not expected_inheritable
        if (
            inheritable != expected_inheritable
            or bool(descriptor_flags & fcntl.FD_CLOEXEC) != expected_cloexec
            or descriptor_flags & ~fcntl.FD_CLOEXEC
        ):
            raise AdmissionError(
                f"M03 lock {label} inheritance/CLOEXEC boundary drifted"
            )

    @staticmethod
    def _validated_lock_fdinfo_tuple(
        observation: _LockFdinfo,
        descriptor_info: os.stat_result,
        *,
        acquisition_pid: int,
        expected_cloexec: bool,
        label: str,
    ) -> tuple[int, ...]:
        cloexec_flag = getattr(os, "O_CLOEXEC", 0)
        if not cloexec_flag:
            raise _LockFdinfoError(
                "M03 lock observation lacks the Linux O_CLOEXEC flag"
            )
        if bool(observation.flags & cloexec_flag) != expected_cloexec:
            raise _LockFdinfoError(
                f"M03 lock {label} fdinfo CLOEXEC state drifted",
                exclusive_flock_observed=True,
            )
        if (
            observation.lock_pid != acquisition_pid
            or observation.inode != descriptor_info.st_ino
            or observation.lock_inode != descriptor_info.st_ino
            or observation.device_major != os.major(descriptor_info.st_dev)
            or observation.device_minor != os.minor(descriptor_info.st_dev)
        ):
            raise _LockFdinfoError(
                f"M03 lock {label} fdinfo identity does not match acquisition",
                exclusive_flock_observed=True,
            )
        return (
            observation.position,
            observation.flags & ~cloexec_flag,
            observation.mount_id,
            observation.inode,
            observation.lock_pid,
            observation.device_major,
            observation.device_minor,
            observation.lock_inode,
        )

    def _observe_lock_fdinfo_pair(
        self,
        fd9_info: os.stat_result,
        keeper_info: os.stat_result,
    ) -> tuple[int, ...]:
        if self._lock_keeper_fd is None or self._lock_acquisition_pid is None:
            raise AdmissionError("M03 lock observation anchor is incomplete")
        self._verify_lock_descriptor_boundary(
            self._lock_keeper_fd,
            expected_inheritable=False,
            label="keeper",
        )
        self._verify_lock_descriptor_boundary(
            9,
            expected_inheritable=True,
            label="FD 9",
        )
        keeper = self._validated_lock_fdinfo_tuple(
            _observe_lock_fdinfo(self._lock_keeper_fd),
            keeper_info,
            acquisition_pid=self._lock_acquisition_pid,
            expected_cloexec=True,
            label="keeper",
        )
        fd9 = self._validated_lock_fdinfo_tuple(
            _observe_lock_fdinfo(9),
            fd9_info,
            acquisition_pid=self._lock_acquisition_pid,
            expected_cloexec=False,
            label="FD 9",
        )
        if keeper != fd9:
            raise _LockFdinfoError(
                "M03 lock keeper and FD 9 do not share one observed flock authority",
                exclusive_flock_observed=True,
            )
        return keeper

    def _collect_lock_authority_observation(self) -> tuple[int, ...]:
        fd9_before, keeper_before = self._verified_lock_metadata_snapshot()
        first = self._observe_lock_fdinfo_pair(fd9_before, keeper_before)
        fd9_middle, keeper_middle = self._verified_lock_metadata_snapshot()
        second = self._observe_lock_fdinfo_pair(fd9_middle, keeper_middle)
        self._verified_lock_metadata_snapshot()
        if first != second:
            raise _LockFdinfoError(
                "M03 lock fdinfo changed across repeated observations",
                exclusive_flock_observed=True,
            )
        return first

    def _descriptor_retention_evidence(
        self,
        descriptor: int | None,
        *,
        expected_inheritable: bool,
        label: str,
    ) -> dict[str, Any]:
        evidence: dict[str, Any] = {
            "descriptor": descriptor,
            "descriptor_open": False,
            "metadata_matches": False,
            "exclusive_flock_observed": None,
            "matches_acquisition": False,
            "validated_descriptor_retained": False,
            "state": "missing",
        }
        if descriptor is None or self._lock_metadata is None:
            return evidence
        try:
            descriptor_info = os.fstat(descriptor)
        except OSError as exc:
            evidence["state"] = "closed-or-unavailable"
            evidence["reason"] = str(exc)
            return evidence
        evidence["descriptor_open"] = True
        evidence["metadata_matches"] = (
            self._lock_metadata_tuple(descriptor_info) == self._lock_metadata
        )
        if not evidence["metadata_matches"]:
            evidence["state"] = "foreign-metadata"
            return evidence
        try:
            self._verify_lock_descriptor_boundary(
                descriptor,
                expected_inheritable=expected_inheritable,
                label=label,
            )
        except AdmissionError as exc:
            evidence["state"] = "descriptor-boundary-unknown"
            evidence["reason"] = str(exc)
            return evidence
        try:
            observation = _observe_lock_fdinfo(descriptor)
        except _LockFdinfoError as exc:
            evidence["exclusive_flock_observed"] = (
                exc.exclusive_flock_observed
            )
            evidence["state"] = (
                "not-exclusive"
                if exc.exclusive_flock_observed is False
                else "observation-unknown"
            )
            evidence["reason"] = str(exc)
            return evidence
        evidence["exclusive_flock_observed"] = True
        if self._lock_acquisition_pid is None:
            evidence["state"] = "acquisition-anchor-missing"
            return evidence
        try:
            normalized = self._validated_lock_fdinfo_tuple(
                observation,
                descriptor_info,
                acquisition_pid=self._lock_acquisition_pid,
                expected_cloexec=not expected_inheritable,
                label=label,
            )
        except _LockFdinfoError as exc:
            evidence["state"] = "exclusive-acquisition-mismatch"
            evidence["reason"] = str(exc)
            return evidence
        evidence["matches_acquisition"] = (
            self._lock_fdinfo_anchor is not None
            and normalized == self._lock_fdinfo_anchor
        )
        evidence["validated_descriptor_retained"] = evidence[
            "matches_acquisition"
        ]
        evidence["state"] = (
            "retained-exclusive"
            if evidence["validated_descriptor_retained"]
            else "exclusive-anchor-mismatch"
        )
        return evidence

    def _capture_lock_retention_evidence(self) -> dict[str, Any]:
        return {
            "keeper": self._descriptor_retention_evidence(
                self._lock_keeper_fd,
                expected_inheritable=False,
                label="keeper",
            ),
            "fd9": self._descriptor_retention_evidence(
                9 if self._lock_fd == 9 else None,
                expected_inheritable=True,
                label="FD 9",
            ),
        }

    def _remember_lock_retention_evidence(
        self, evidence: Mapping[str, Any]
    ) -> None:
        self._lock_retention_evidence = copy.deepcopy(dict(evidence))
        keeper = evidence["keeper"]
        self._lock_keeper_retained = bool(
            keeper["validated_descriptor_retained"]
        )

    @staticmethod
    def _lock_retention_event_detail(
        evidence: Mapping[str, Any]
    ) -> dict[str, Any]:
        keeper = evidence["keeper"]
        fd9 = evidence["fd9"]
        return {
            "original_keeper_retained": keeper[
                "validated_descriptor_retained"
            ],
            "original_keeper_exclusive_flock_observed": keeper[
                "exclusive_flock_observed"
            ],
            "fd9_retained": fd9["validated_descriptor_retained"],
            "fd9_exclusive_flock_observed": fd9[
                "exclusive_flock_observed"
            ],
            "lock_retention_evidence": copy.deepcopy(dict(evidence)),
        }

    def _prove_lock_authority(self) -> dict[str, Any]:
        if self._lock_authority_lost:
            raise AdmissionIncident(
                self._lock_authority_failure or "M03 lock authority was lost"
            )
        if (
            self._lock_fd != 9
            or self._lock_keeper_fd is None
            or self._lock_canonical_path is None
            or self._lock_metadata is None
            or self._lock_acquisition_pid is None
            or self._lock_fdinfo_anchor is None
        ):
            raise self._lock_authority_incident(
                "M03 lock authority has no complete FD/path/keeper anchor"
            )
        try:
            observed = self._collect_lock_authority_observation()
        except (AdmissionError, OSError, RuntimeError, ValueError) as exc:
            raise self._lock_authority_incident(
                "M03 lock authority could not be observed without mutation: "
                + str(exc)
            ) from exc
        if observed != self._lock_fdinfo_anchor:
            raise self._lock_authority_incident(
                "M03 lock fdinfo no longer matches the acquisition anchor"
            )
        fd9_info, _ = self._verified_lock_metadata_snapshot()
        return {
            "run_hex": self.config.run_hex,
            "owner": self.config.owner,
            "lock_path": str(self.config.lock_path),
            "lock_canonical_path": str(self._lock_canonical_path),
            "lock_device": fd9_info.st_dev,
            "lock_inode": fd9_info.st_ino,
            "lock_acquisition_pid": self._lock_acquisition_pid,
            "lock_fdinfo_sha256": _digest(list(self._lock_fdinfo_anchor)),
        }

    def _release_lock(self) -> None:
        if self._lock_fd is None and self._lock_keeper_fd is None:
            return
        if self._lock_authority_lost:
            # Either descriptor may now be closed or foreign. Keep every numeric
            # reference untouched and retain only what observation can validate.
            evidence = self._capture_lock_retention_evidence()
            self._remember_lock_retention_evidence(evidence)
            self._lock_fd = None
            return
        self._prove_lock_authority()
        lock_fd = self._lock_fd
        keeper_fd = self._lock_keeper_fd
        self._lock_fd = None
        self._lock_keeper_fd = None
        # Never issue LOCK_UN: inherited descriptors share the original open-file
        # description, so the kernel retains the flock until its last close.
        assert lock_fd == 9 and keeper_fd is not None
        failure: OSError | None = None
        for descriptor in (lock_fd, keeper_fd):
            try:
                os.close(descriptor)
            except OSError as exc:
                if failure is None:
                    failure = exc
        if failure is not None:
            raise failure

    def _verify_bundle(self) -> str:
        if self.config.test_only_paths:
            return "test-only-local-modules"
        digest = _verify_reviewed_bundle(
            self.config.bundle_root, required_uid=self.config.required_uid
        )
        if (
            self._bundle_manifest_sha256 is not None
            and digest != self._bundle_manifest_sha256
        ):
            raise AdmissionIncident("reviewed bundle manifest changed during admission")
        return digest

    def _identity_detail(self) -> dict[str, Any]:
        return self._prove_lock_authority()

    def _lifecycle_env(self) -> dict[str, str]:
        return {
            **BASE_ENV,
            "EVIDENCE_DIR": str(self.config.m03_evidence_path),
            "M03_EVIDENCE_DIR": str(self.config.m03_evidence_path),
            "M03_K01_KUBECONFIG": str(self.config.k01_kubeconfig),
            "M03_LOCK_HELD_FD": "9",
            "M03_P003_KUBECONFIG": str(self.config.p003_kubeconfig),
            "M03_PREFLIGHT_RECEIPT": str(self.config.receipt_path),
            "X05_COORDINATOR_TOKEN": self.config.owner,
        }

    def _labctl(self, action: str, *, m03: bool) -> CommandResult:
        if (action, m03) not in {
            ("up", True),
            ("verify", True),
            ("down", True),
            ("verify", False),
        }:
            raise AdmissionError("unsupported labctl lifecycle action")
        self._verify_bundle()
        current_identity = self._assert_labctl_executable()
        if self._labctl_identity is None or current_identity != self._labctl_identity:
            raise AdmissionError("labctl executable identity changed during admission")
        argv = (str(self.config.labctl_path), "mgc", action) + (
            ("--m03",) if m03 else ()
        )
        self._identity_detail()
        origin = self._origin
        result = origin.runner_run(
            origin.runner,
            argv,
            env=self._lifecycle_env(),
            timeout=self.config.command_timeout,
            pass_fds=(9,),
        )
        if result.argv != argv:
            raise AdmissionError("runner returned a different labctl argv")
        return result

    @staticmethod
    def _command_detail(result: CommandResult) -> dict[str, Any]:
        return {
            "argv": list(result.argv),
            "returncode": result.returncode,
            "stdout_sha256": _sha256(result.stdout),
            "stderr_sha256": _sha256(result.stderr),
        }

    def prepare(self) -> PreparedAdmission:
        origin = self._origin
        if type(origin) is not _AdmissionOrigin:
            raise AdmissionIncident("original admission provenance changed")
        with origin.consume_lock:
            _original_session_method(origin, "_assert_origin_bindings_locked")(
                self, origin, self._event_authority, require_event=True
            )
            return _original_session_method(origin, "_prepare_locked")(self)

    def _prepare_locked(self) -> PreparedAdmission:
        """Run G0/G0a and keep the owned M03 substrate until context exit."""
        if not self._entered or self._closed:
            raise AdmissionError("admission session is not active")
        if self._prepare_attempted:
            raise AdmissionError("G0/G0a preparation may be attempted only once")
        self._identity_detail()
        self._prepare_attempted = True
        self._labctl_identity = self._assert_labctl_executable()
        self._assert_target_absent()
        g0 = self.collector.g0()
        self._profile_owner = g0["mgc"]["profile_owner"]
        self._input_digests = {
            key: g0[key]
            for key in (
                "receipt_sha256",
                "k01_kubeconfig_sha256",
                "p003_kubeconfig_sha256",
            )
        }
        self._baseline_anchors = self.collector.baseline_anchors(
            g0["mgc"],
            g0["docker"],
            g0["gateway_frr"],
            g0["chassis2"],
            g0["before"],
        )
        g0_anchor = copy.deepcopy(self._baseline_anchors)
        self._event_append_locked(
            "g0-pass",
            {
                "receipt_sha256": g0["receipt_sha256"],
                "k01_kubeconfig_sha256": g0["k01_kubeconfig_sha256"],
                "p003_kubeconfig_sha256": g0["p003_kubeconfig_sha256"],
                "anchors_sha256": _digest(g0_anchor),
            },
        )
        if self.collector.input_digests() != self._input_digests:
            raise AdmissionError(
                "receipt or explicit kubeconfig changed before M03 setup"
            )
        self._event_append_locked(
            "m03-up-intent",
            {
                **self._identity_detail(),
                "argv": [str(self.config.labctl_path), "mgc", "up", "--m03"],
            },
        )
        self._setup_attempted = True
        try:
            result = self._labctl("up", m03=True)
        except Exception as exc:
            self._event_append_locked(
                "m03-up-outcome", {"outcome": "unknown", "reason": str(exc)}
            )
            self._discover_cleanup_ownership()
            raise
        self._event_append_locked("m03-up-outcome", self._command_detail(result))
        self._discover_cleanup_ownership()
        if result.returncode != 0:
            raise AdmissionError("labctl mgc up --m03 failed")
        if not self._owned_m03:
            raise AdmissionIncident(
                "M03 up returned success without an owned marker/resource proof"
            )
        try:
            verify = self._labctl("verify", m03=True)
        except Exception as exc:
            self._event_append_locked(
                "m03-verify-outcome",
                {
                    "outcome": "unknown",
                    "reason": str(exc),
                },
            )
            raise
        self._event_append_locked("m03-verify-outcome", self._command_detail(verify))
        if verify.returncode != 0:
            raise AdmissionError("labctl mgc verify --m03 failed")
        self.collector.clear_cache()
        snapshot = self.collector.collect_snapshot()
        expected_anchors = self.collector.anchors_from_snapshot(snapshot)
        stable_g0 = {key: value for key, value in g0_anchor.items() if key != "before"}
        if {
            key: expected_anchors[key] for key in stable_g0
        } != stable_g0 or self.collector.before_absence_anchor(
            expected_anchors["before"]
        ) != self.collector.before_absence_anchor(g0_anchor["before"]):
            raise AdmissionError(
                "MGC/image/FRR identity changed between G0 and G0a collection"
            )
        try:
            PREFLIGHT.validate_snapshot(snapshot)
        except PREFLIGHT.SnapshotError as exc:
            raise AdmissionError(
                "runtime snapshot failed in-memory validation: " + str(exc)
            ) from exc
        current = self.collector.current_anchors()
        if current != expected_anchors:
            raise AdmissionError("runtime identity changed after snapshot collection")
        self._expected_anchors = copy.deepcopy(expected_anchors)
        self.collector.validate_receipt()
        if self.collector.input_digests() != self._input_digests:
            raise AdmissionError(
                "receipt or explicit kubeconfig changed after collection"
            )
        if (
            self.collector.marker(self.config.x05_marker_path, required=False)
            is not None
        ):
            raise AdmissionError("X05 marker appeared during G0/G0a collection")
        self._assert_target_absent()
        self._verify_bundle()
        path = self._persist_snapshot(snapshot)
        published = PREFLIGHT.read_snapshot(path, required_uid=self.config.required_uid)
        try:
            report = PREFLIGHT.validate_snapshot(published)
        except PREFLIGHT.SnapshotError as exc:
            raise AdmissionIncident(
                "published runtime snapshot failed validation: " + str(exc)
            ) from exc
        if report.get("authorizes_mutation") is not False:
            raise AdmissionIncident("serialized snapshot incorrectly claims authority")
        published_raw = _read_regular(
            path,
            maximum=8 * 1024 * 1024,
            required_mode=0o600,
            required_uid=self.config.required_uid,
        )
        published_info = path.lstat()
        self._snapshot_identity = (published_info.st_dev, published_info.st_ino)
        self.collector.clear_cache()
        after_publish = self.collector.current_anchors()
        if after_publish != expected_anchors:
            raise AdmissionIncident(
                "runtime identity changed across snapshot publication"
            )
        if self.collector.input_digests() != self._input_digests:
            raise AdmissionIncident("admission inputs changed across publication")
        self._event_append_locked(
            "g0a-snapshot-published",
            {
                "path": str(path),
                "snapshot_sha256": snapshot["snapshot_sha256"],
                "anchors_sha256": _digest(current),
                "snapshot_file_sha256": _sha256(published_raw),
            },
        )
        self._event_append_locked(
            "prepared-admission",
            {
                "snapshot_sha256": snapshot["snapshot_sha256"],
                "snapshot_file_sha256": _sha256(published_raw),
                "anchors_sha256": _digest(after_publish),
                "inputs_sha256": _digest(self._input_digests),
                "bundle_manifest_sha256": self._verify_bundle(),
            },
        )
        chain = self._event_verify_locked()
        self._prepared = PreparedAdmission(
            self,
            snapshot_path=path,
            snapshot_sha256=snapshot["snapshot_sha256"],
            snapshot_file_sha256=_sha256(published_raw),
            inputs_sha256=_digest(self._input_digests),
            anchors_sha256=_digest(after_publish),
            bundle_manifest_sha256=self._verify_bundle(),
            event_head=chain["head_sha256"],
            event_count=chain["count"],
        )
        return self._prepared

    def admit(self) -> PreparedAdmission:
        """Compatibility spelling for callers that treat G0/G0a as admission."""
        origin = self._origin
        if type(origin) is not _AdmissionOrigin:
            raise AdmissionIncident("original admission provenance changed")
        return origin.session_prepare(origin.session)

    def consume(self, prepared: PreparedAdmission) -> PreparedAdmission:
        if (
            type(prepared) is not PreparedAdmission
            or prepared._session is not self
            or type(prepared._origin) is not _AdmissionOrigin
            or prepared._origin.session is not self
        ):
            raise AdmissionError("prepared admission is foreign, stale, or inactive")
        origin = prepared._origin
        with origin.consume_lock:
            _original_session_method(origin, "_assert_origin_bindings_locked")(
                self, origin, prepared._event_authority, require_event=True
            )
            return _original_session_method(origin, "_consume_locked")(
                self, prepared
            )

    def _consume_locked(self, prepared: PreparedAdmission) -> PreparedAdmission:
        """Revalidate the active evidence and return the same opaque capability."""
        with prepared._origin.consume_lock:
            if (
                not self._entered
                or self._closed
                or prepared is not self._prepared
                or not isinstance(prepared, PreparedAdmission)
                or not prepared.active
            ):
                raise AdmissionError("prepared admission is foreign, stale, or inactive")
            if prepared._consumed:
                raise AdmissionError("prepared admission has already been consumed")
            self._identity_detail()
            if self._verify_bundle() != prepared._bundle_manifest_sha256:
                raise AdmissionIncident("prepared bundle manifest binding changed")
            chain = self._event_verify_locked()
            if (
                chain["head_sha256"] != prepared._event_head
                or chain["count"] != prepared._event_count
            ):
                raise AdmissionIncident("prepared admission event-chain binding changed")
            info = prepared.snapshot_path.lstat()
            if (info.st_dev, info.st_ino) != self._snapshot_identity:
                raise AdmissionIncident("prepared snapshot identity changed")
            snapshot = PREFLIGHT.read_snapshot(
                prepared.snapshot_path, required_uid=self.config.required_uid
            )
            try:
                report = PREFLIGHT.validate_snapshot(snapshot)
            except PREFLIGHT.SnapshotError as exc:
                raise AdmissionIncident(
                    "prepared snapshot no longer validates: " + str(exc)
                ) from exc
            raw = _read_regular(
                prepared.snapshot_path,
                maximum=8 * 1024 * 1024,
                required_mode=0o600,
                required_uid=self.config.required_uid,
            )
            if (
                snapshot.get("snapshot_sha256") != prepared._snapshot_sha256
                or _sha256(raw) != prepared._snapshot_file_sha256
                or report.get("authorizes_mutation") is not False
            ):
                raise AdmissionIncident("prepared snapshot digest binding changed")
            self.collector.validate_receipt()
            if (
                self._input_digests is None
                or self.collector.input_digests() != self._input_digests
                or _digest(self._input_digests) != prepared._inputs_sha256
            ):
                raise AdmissionIncident("admission inputs changed before consumption")
            if self._expected_anchors is None:
                raise AdmissionIncident("prepared runtime anchors are unavailable")
            self.collector.clear_cache()
            current = self.collector.current_anchors()
            if (
                current != self._expected_anchors
                or _digest(current) != prepared._anchors_sha256
            ):
                raise AdmissionIncident("runtime identity changed before consumption")
            if (
                self.collector.marker(self.config.x05_marker_path, required=False)
                is not None
            ):
                raise AdmissionIncident(
                    "X05 marker appeared before admission consumption"
                )
            record = self._event_append_locked(
                "prepared-consume-pass",
                {
                    "snapshot_sha256": prepared._snapshot_sha256,
                    "snapshot_file_sha256": prepared._snapshot_file_sha256,
                    "anchors_sha256": _digest(current),
                    "inputs_sha256": _digest(self._input_digests),
                },
            )
            prepared._event_head = record["event_sha256"]
            prepared._event_count = self._event_count_locked()
            prepared._consumed = True
            self._event_verify_locked()
            return prepared

    def _assert_execution_capability_locked(
        self, prepared: PreparedAdmission
    ) -> None:
        if (
            type(prepared) is not PreparedAdmission
            or prepared is not self._prepared
            or prepared._session is not self
            or type(prepared._origin) is not _AdmissionOrigin
            or prepared._origin.session is not self
            or prepared._origin is not self._origin
            or prepared._event_authority is not self._event_authority
            or not self._entered
            or self._closed
            or not prepared.active
        ):
            raise AdmissionError("execution admission is foreign, stale, or inactive")
        _original_session_method(
            prepared._origin, "_assert_origin_bindings_locked"
        )(
            self,
            prepared._origin,
            prepared._event_authority,
            require_event=True,
        )
        if not prepared._consumed:
            raise AdmissionError("execution admission has not been consumed")
        if self._execution_failure is not None:
            raise AdmissionIncident(self._execution_failure)

    def _remember_execution_failure(self, exc: Exception) -> AdmissionIncident:
        if self._execution_failure is None:
            reason = str(exc) or exc.__class__.__name__
            self._execution_failure = "continuing execution failed: " + reason
        return AdmissionIncident(self._execution_failure)

    def _verified_execution_snapshot_locked(
        self, prepared: PreparedAdmission
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        if self._snapshot_identity is None or self._expected_anchors is None:
            raise AdmissionIncident("execution snapshot anchors are unavailable")
        try:
            before = prepared.snapshot_path.lstat()
        except OSError as exc:
            raise AdmissionIncident("execution snapshot is unavailable") from exc
        if (before.st_dev, before.st_ino) != self._snapshot_identity:
            raise AdmissionIncident("execution snapshot identity changed")
        raw = _read_regular(
            prepared.snapshot_path,
            maximum=8 * 1024 * 1024,
            required_mode=0o600,
            required_uid=self.config.required_uid,
        )
        try:
            after = prepared.snapshot_path.lstat()
        except OSError as exc:
            raise AdmissionIncident("execution snapshot changed while reading") from exc
        if (
            (after.st_dev, after.st_ino) != self._snapshot_identity
            or (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino)
            or not stat.S_ISREG(after.st_mode)
            or _mode(after) != 0o600
            or after.st_uid != self.config.required_uid
        ):
            raise AdmissionIncident("execution snapshot identity changed while reading")
        if _sha256(raw) != prepared._snapshot_file_sha256:
            raise AdmissionIncident("execution snapshot raw digest changed")
        try:
            snapshot = PREFLIGHT.parse_json(raw, context="execution snapshot")
            report = PREFLIGHT.validate_snapshot(snapshot)
        except PREFLIGHT.SnapshotError as exc:
            raise AdmissionIncident(
                "execution snapshot no longer validates: " + str(exc)
            ) from exc
        if (
            report.get("authorizes_mutation") is not False
            or snapshot.get("run_hex") != self.config.run_hex
            or snapshot.get("owner") != self.config.owner
            or snapshot.get("evidence_path") != str(self.config.evidence_path)
            or snapshot.get("snapshot_sha256") != prepared._snapshot_sha256
        ):
            raise AdmissionIncident("execution snapshot binding changed")
        anchors = self.collector.anchors_from_snapshot(snapshot)
        if (
            anchors != self._expected_anchors
            or _digest(anchors) != prepared._anchors_sha256
        ):
            raise AdmissionIncident("execution snapshot anchor binding changed")
        return snapshot, anchors

    def _verify_execution_state_locked(
        self,
        prepared: PreparedAdmission,
        *,
        expected_event_head: str,
        expected_event_count: int,
    ) -> dict[str, Any]:
        identity = self._identity_detail()
        if (
            not self._setup_attempted
            or not self._owned_m03
            or self._profile_owner is None
            or self._input_digests is None
            or self._labctl_identity is None
        ):
            raise AdmissionIncident("execution admission state is incomplete")
        if self._verify_bundle() != prepared._bundle_manifest_sha256:
            raise AdmissionIncident("execution bundle manifest binding changed")
        if self._assert_labctl_executable() != self._labctl_identity:
            raise AdmissionIncident("execution labctl identity changed")
        chain = self._event_verify_locked()
        if (
            chain["head_sha256"] != expected_event_head
            or chain["count"] != expected_event_count
        ):
            raise AdmissionIncident("execution event-chain binding changed")
        snapshot, anchors = self._verified_execution_snapshot_locked(prepared)
        if _digest(self._input_digests) != prepared._inputs_sha256:
            raise AdmissionIncident("execution input digest anchor changed")
        self.collector.validate_receipt()
        current_inputs = self.collector.input_digests()
        if current_inputs != self._input_digests:
            raise AdmissionIncident("execution receipt or kubeconfig input changed")
        return {
            "identity": identity,
            "chain": chain,
            "snapshot": snapshot,
            "anchors": anchors,
            "input_digests": copy.deepcopy(self._input_digests),
        }

    def _verify_execution_locked(
        self, prepared: PreparedAdmission
    ) -> dict[str, Any]:
        origin = prepared._origin
        genuine_consumed = (
            type(prepared) is PreparedAdmission
            and prepared is self._prepared
            and prepared._session is self
            and type(origin) is _AdmissionOrigin
            and origin.session is self
            and type(prepared._event_authority) is _EventLogAuthority
            and prepared._active
            and prepared._consumed
            and self._entered
            and not self._closed
        )
        try:
            _original_session_method(
                origin, "_assert_execution_capability_locked"
            )(self, prepared)
            return _original_session_method(origin, "_verify_execution_state_locked")(
                self,
                prepared,
                expected_event_head=prepared._event_head,
                expected_event_count=prepared._event_count,
            )
        except Exception as exc:
            if not genuine_consumed:
                raise
            incident = _original_session_method(origin, "_remember_execution_failure")(
                self, exc
            )
            if isinstance(exc, (AdmissionError, OSError, ValueError)):
                raise incident from exc
            raise

    def verify_execution(self, prepared: PreparedAdmission) -> None:
        """Revalidate the original consumed capability for continuing effects."""
        if (
            type(prepared) is not PreparedAdmission
            or type(prepared._origin) is not _AdmissionOrigin
            or prepared._origin.session is not self
        ):
            raise AdmissionError("execution admission is foreign, stale, or inactive")
        with prepared._origin.consume_lock:
            _original_session_method(prepared._origin, "_verify_execution_locked")(
                self, prepared
            )

    def execution_context(self, prepared: PreparedAdmission) -> dict[str, Any]:
        """Return detached verified evidence that never grants mutation authority."""
        if (
            type(prepared) is not PreparedAdmission
            or type(prepared._origin) is not _AdmissionOrigin
            or prepared._origin.session is not self
        ):
            raise AdmissionError("execution admission is foreign, stale, or inactive")
        with prepared._origin.consume_lock:
            verified = _original_session_method(
                prepared._origin, "_verify_execution_locked"
            )(self, prepared)
            context = {
                "schema": "p004-x05-execution-context-v1",
                "authorizes_mutation": False,
                "producer": {
                    "run_hex": self.config.run_hex,
                    "owner": self.config.owner,
                    "paths": {
                        "evidence": str(self.config.evidence_path),
                        "events": str(self.config.event_path),
                        "snapshot": str(prepared.snapshot_path),
                        "receipt": str(self.config.receipt_path),
                        "k01_kubeconfig": str(self.config.k01_kubeconfig),
                        "p003_kubeconfig": str(self.config.p003_kubeconfig),
                    },
                },
                "admission": {
                    "snapshot_sha256": prepared._snapshot_sha256,
                    "snapshot_file_sha256": prepared._snapshot_file_sha256,
                    "anchors_sha256": prepared._anchors_sha256,
                    "inputs_sha256": prepared._inputs_sha256,
                    "bundle_manifest_sha256": prepared._bundle_manifest_sha256,
                    "event_head_sha256": prepared._event_head,
                    "event_count": prepared._event_count,
                },
                "input_digests": verified["input_digests"],
                "anchors": verified["anchors"],
                "snapshot": verified["snapshot"],
            }
            return copy.deepcopy(context)

    def record_execution_event(
        self,
        prepared: PreparedAdmission,
        event: str,
        detail: dict[str, Any],
    ) -> dict[str, Any]:
        """Durably append one bounded X05 event before publishing its new head."""
        if (
            type(prepared) is not PreparedAdmission
            or type(prepared._origin) is not _AdmissionOrigin
            or prepared._origin.session is not self
        ):
            raise AdmissionError("execution admission is foreign, stale, or inactive")
        with prepared._origin.consume_lock:
            origin = prepared._origin
            validated_event = _validated_execution_event(event)
            validated_detail = _validated_execution_detail(detail)
            _original_session_method(origin, "_verify_execution_locked")(
                self, prepared
            )
            previous_head = prepared._event_head
            previous_count = prepared._event_count
            wrapped_detail = {
                "producer": {
                    "run_hex": self.config.run_hex,
                    "owner": self.config.owner,
                    "evidence_path": str(self.config.evidence_path),
                },
                "admission": {
                    "snapshot_path": str(prepared.snapshot_path),
                    "snapshot_sha256": prepared._snapshot_sha256,
                    "snapshot_file_sha256": prepared._snapshot_file_sha256,
                    "anchors_sha256": prepared._anchors_sha256,
                    "inputs_sha256": prepared._inputs_sha256,
                    "bundle_manifest_sha256": prepared._bundle_manifest_sha256,
                    "event_head_sha256": previous_head,
                    "event_count": previous_count,
                },
                "detail": validated_detail,
            }
            try:
                record = _original_session_method(origin, "_event_append_locked")(
                    self, validated_event, wrapped_detail
                )
                expected_count = previous_count + 1
                body = {
                    key: value for key, value in record.items() if key != "event_sha256"
                }
                expected_head = _digest(body)
                if (
                    record.get("sequence") != expected_count
                    or record.get("event") != validated_event
                    or record.get("previous_sha256") != previous_head
                    or record.get("detail") != wrapped_detail
                    or record.get("event_sha256") != expected_head
                ):
                    raise AdmissionIncident(
                        "execution append did not return the intended next record"
                    )
                published_record = copy.deepcopy(record)
                _original_session_method(
                    origin, "_verify_execution_state_locked"
                )(
                    self,
                    prepared,
                    expected_event_head=expected_head,
                    expected_event_count=expected_count,
                )
            except Exception as exc:
                incident = _original_session_method(
                    origin, "_remember_execution_failure"
                )(self, exc)
                if isinstance(exc, (AdmissionError, OSError, ValueError)):
                    raise incident from exc
                raise
            prepared._event_head = expected_head
            prepared._event_count = expected_count
            return published_record

    def _assert_labctl_executable(self) -> tuple[int, ...]:
        try:
            info = self.config.labctl_path.lstat()
        except OSError as exc:
            raise AdmissionError("labctl executable is unavailable") from exc
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            raise AdmissionError("labctl executable is not a regular non-symlink file")
        if (
            info.st_uid != self.config.required_uid
            or _mode(info) & 0o022
            or not _mode(info) & 0o100
        ):
            raise AdmissionError("labctl executable owner or mode is unsafe")
        if not self.config.test_only_paths:
            data = _read_regular(
                self.config.labctl_path,
                maximum=8 * 1024 * 1024,
                required_uid=self.config.required_uid,
                forbidden_mode_bits=0o022,
            )
            if _sha256(data) != REVIEWED_BUNDLE_FILES["labctl"]:
                raise AdmissionError("labctl executable differs from reviewed bytes")
        return (
            info.st_dev,
            info.st_ino,
            info.st_size,
            info.st_mtime_ns,
            info.st_ctime_ns,
            info.st_mode,
            info.st_uid,
        )

    def _discover_cleanup_ownership(self) -> None:
        if not self._setup_attempted or self._profile_owner is None:
            return
        identity = self.collector.owned_m03_identity(self._profile_owner)
        self._owned_m03 = identity is not None
        self._m03_ownership_sha256 = _digest(identity) if identity is not None else None
        self._event_append_locked(
            "m03-up-readback",
            {
                "owned": self._owned_m03,
                "identity_sha256": self._m03_ownership_sha256,
            },
        )
        if not self._owned_m03:
            self._event_append_locked(
                "incident",
                {
                    "reason": "M03 setup outcome lacks a complete owned cleanup identity",
                    "cleanup_attempted": False,
                },
            )

    def _persist_snapshot(self, snapshot: Mapping[str, Any]) -> pathlib.Path:
        self._assert_target_absent()
        os.mkdir(self.config.evidence_path, 0o700)
        info = self.config.evidence_path.lstat()
        if info.st_uid != self.config.required_uid or _mode(info) != 0o700:
            raise AdmissionIncident("new X05 evidence directory is not private")
        _fsync_directory(self.config.run_parent)
        flags = (
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
        fd = os.open(self.config.snapshot_path, flags, 0o600)
        try:
            data = _canonical_bytes(snapshot) + b"\n"
            view = memoryview(data)
            while view:
                written = os.write(fd, view)
                view = view[written:]
            os.fsync(fd)
            info = os.fstat(fd)
            if info.st_uid != self.config.required_uid or _mode(info) != 0o600:
                raise AdmissionIncident("runtime snapshot file is not private")
        finally:
            os.close(fd)
        _fsync_directory(self.config.evidence_path)
        return self.config.snapshot_path

    def _verify_published_evidence(self) -> None:
        if self._prepared is None:
            return
        chain = self._event_verify_locked()
        if (
            chain["head_sha256"] != self._prepared._event_head
            or chain["count"] != self._prepared._event_count
        ):
            raise AdmissionIncident("published admission event chain changed")
        info = self._prepared.snapshot_path.lstat()
        if (info.st_dev, info.st_ino) != self._snapshot_identity:
            raise AdmissionIncident("published snapshot identity changed")
        raw = _read_regular(
            self._prepared.snapshot_path,
            maximum=8 * 1024 * 1024,
            required_mode=0o600,
            required_uid=self.config.required_uid,
        )
        snapshot = PREFLIGHT.read_snapshot(
            self._prepared.snapshot_path, required_uid=self.config.required_uid
        )
        try:
            report = PREFLIGHT.validate_snapshot(snapshot)
        except PREFLIGHT.SnapshotError as exc:
            raise AdmissionIncident("published snapshot changed: " + str(exc)) from exc
        if (
            report.get("authorizes_mutation") is not False
            or snapshot.get("snapshot_sha256") != self._prepared._snapshot_sha256
            or _sha256(raw) != self._prepared._snapshot_file_sha256
        ):
            raise AdmissionIncident("published snapshot digest binding changed")

    def close(self) -> None:
        prepared = self._prepared
        origin = (
            prepared._origin
            if type(prepared) is PreparedAdmission
            and type(prepared._origin) is _AdmissionOrigin
            and prepared._origin.session is self
            else self._origin
        )
        if type(origin) is not _AdmissionOrigin or origin.session is not self:
            raise AdmissionIncident("original admission provenance changed")
        with origin.consume_lock:
            if self._closed:
                return
            try:
                _original_session_method(
                    origin, "_assert_origin_bindings_locked"
                )(
                    self,
                    origin,
                    self._event_authority,
                    require_event=self._entered,
                )
            except AdmissionIncident as exc:
                _original_session_method(
                    origin, "_close_after_origin_loss_locked"
                )(self, origin, exc)
            _original_session_method(origin, "_close_locked")(self)

    def _close_locked(self) -> None:
        if self._closed:
            return
        if self._prepared is not None:
            self._prepared._invalidate()
        failure: Exception | None = None
        authority_failure: AdmissionIncident | None = None
        if self._entered:
            try:
                self._identity_detail()
            except AdmissionIncident as exc:
                authority_failure = exc
                failure = exc
                retention = self._capture_lock_retention_evidence()
                self._remember_lock_retention_evidence(retention)
                self._event_append_locked(
                    "incident",
                    {
                        "reason": str(exc),
                        "cleanup_attempted": False,
                        "evidence_retained": True,
                        **self._lock_retention_event_detail(retention),
                        "foreign_fd9_closed": False,
                        "flock_unlock_attempted": False,
                    },
                )
        try:
            if (
                self._setup_attempted
                and self._owned_m03
                and not self._cleanup_attempted
            ):
                self._cleanup_attempted = True
                cleanup_blocked = (
                    authority_failure is not None or self._retained_descriptor
                )
                if authority_failure is not None:
                    x05_marker_present = False
                elif cleanup_blocked:
                    x05_marker_present = False
                    failure = AdmissionIncident(
                        "a detached descendant may retain FD 9; M03 and its flock are retained"
                    )
                    self._event_append_locked(
                        "incident",
                        {
                            "reason": str(failure),
                            "cleanup_attempted": False,
                            "evidence_retained": True,
                            "flock_unlock_attempted": False,
                        },
                    )
                else:
                    try:
                        x05_marker_present = (
                            self.collector.marker(
                                self.config.x05_marker_path, required=False
                            )
                            is not None
                        )
                    except AdmissionError:
                        x05_marker_present = True
                same_owned_m03 = False
                if cleanup_blocked:
                    pass
                elif x05_marker_present:
                    failure = AdmissionIncident(
                        "X05 marker appeared before coordinator cleanup proof; M03 retained"
                    )
                    self._event_append_locked(
                        "incident",
                        {
                            "reason": str(failure),
                            "cleanup_attempted": False,
                            "evidence_retained": True,
                        },
                    )
                else:
                    owned_identity = (
                        self.collector.owned_m03_identity(self._profile_owner)
                        if self._profile_owner is not None
                        else None
                    )
                    owned_digest = (
                        _digest(owned_identity) if owned_identity is not None else None
                    )
                    same_owned_m03 = (
                        owned_digest is not None
                        and owned_digest == self._m03_ownership_sha256
                    )
                    try:
                        self._verify_bundle()
                        self._verify_published_evidence()
                        self.collector.clear_cache()
                        if self._expected_anchors is not None:
                            same_owned_m03 = (
                                same_owned_m03
                                and self.collector.current_anchors()
                                == self._expected_anchors
                            )
                        elif self._baseline_anchors is not None and self._profile_owner:
                            current_mgc = self.collector.mgc_section()
                            current_docker = self.collector.docker_section()
                            current_frr = self.collector.gateway_frr_section()
                            current_chassis2 = self.collector.chassis2_section()
                            current_before = self.collector.collect_before(
                                self._profile_owner
                            )
                            current_baseline = self.collector.baseline_anchors(
                                current_mgc,
                                current_docker,
                                current_frr,
                                current_chassis2,
                                current_before,
                            )
                            stable_expected = {
                                key: value
                                for key, value in self._baseline_anchors.items()
                                if key != "before"
                            }
                            stable_current = {
                                key: value
                                for key, value in current_baseline.items()
                                if key != "before"
                            }
                            same_owned_m03 = (
                                same_owned_m03
                                and stable_current == stable_expected
                                and self.collector.before_absence_anchor(current_before)
                                == self.collector.before_absence_anchor(
                                    self._baseline_anchors["before"]
                                )
                            )
                    except (AdmissionError, OSError, ValueError):
                        same_owned_m03 = False
                    self._event_append_locked(
                        "m03-pre-down-readback",
                        {
                            "owned": owned_identity is not None,
                            "matches_setup": same_owned_m03,
                            "identity_sha256": owned_digest,
                            "setup_identity_sha256": self._m03_ownership_sha256,
                        },
                    )
                if (
                    not cleanup_blocked
                    and not x05_marker_present
                    and not same_owned_m03
                ):
                    self._owned_m03 = False
                    failure = AdmissionIncident(
                        "M03 ownership changed before cleanup; state retained"
                    )
                    self._event_append_locked(
                        "incident",
                        {
                            "reason": str(failure),
                            "cleanup_attempted": False,
                            "evidence_retained": True,
                        },
                    )
                elif not cleanup_blocked and not x05_marker_present:
                    self._event_append_locked(
                        "m03-down-intent",
                        {
                            **self._identity_detail(),
                            "argv": [
                                str(self.config.labctl_path),
                                "mgc",
                                "down",
                                "--m03",
                            ],
                        },
                    )
                    try:
                        try:
                            down = self._labctl("down", m03=True)
                        except Exception as exc:
                            self._event_append_locked(
                                "m03-down-outcome",
                                {
                                    "outcome": "unknown",
                                    "reason": str(exc),
                                },
                            )
                            raise
                        self._event_append_locked(
                            "m03-down-outcome", self._command_detail(down)
                        )
                        if down.returncode != 0:
                            raise AdmissionIncident("labctl mgc down --m03 failed")
                        try:
                            baseline = self._labctl("verify", m03=False)
                        except Exception as exc:
                            self._event_append_locked(
                                "baseline-verify-outcome",
                                {
                                    "outcome": "unknown",
                                    "reason": str(exc),
                                },
                            )
                            raise
                        self._event_append_locked(
                            "baseline-verify-outcome", self._command_detail(baseline)
                        )
                        if baseline.returncode != 0:
                            raise AdmissionIncident("baseline labctl mgc verify failed")
                        if (
                            self._input_digests is None
                            or self._baseline_anchors is None
                        ):
                            raise AdmissionIncident(
                                "admission input or baseline anchors are unavailable"
                            )
                        self.collector.post_cleanup_baseline(
                            self._input_digests, self._baseline_anchors
                        )
                        self._event_append_locked(
                            "baseline-postconditions-pass",
                            {
                                "input_digests": self._input_digests,
                                "baseline_sha256": _digest(self._baseline_anchors),
                            },
                        )
                        self._owned_m03 = False
                    except Exception as exc:
                        failure = (
                            exc
                            if isinstance(exc, AdmissionIncident)
                            else AdmissionIncident(str(exc))
                        )
                        self._event_append_locked(
                            "incident",
                            {
                                "reason": str(failure),
                                "cleanup_attempted": True,
                                "evidence_retained": True,
                            },
                        )
            elif self._setup_attempted and not self._owned_m03:
                self._event_append_locked(
                    "cleanup-skipped",
                    {
                        "reason": "M03 ownership was not proven; foreign or uncertain state is retained",
                    },
                )
        finally:
            try:
                if self._entered:
                    try:
                        identity = self._identity_detail()
                    except AdmissionIncident as exc:
                        if failure is None:
                            failure = exc
                        retention = self._capture_lock_retention_evidence()
                        self._remember_lock_retention_evidence(retention)
                        self._event_append_locked(
                            "lock-retained-incident",
                            {
                                "run_hex": self.config.run_hex,
                                "owner": self.config.owner,
                                "lock_path": str(self.config.lock_path),
                                "reason": str(exc),
                                **self._lock_retention_event_detail(retention),
                                "foreign_fd9_closed": False,
                                "flock_unlock_attempted": False,
                            },
                        )
                    else:
                        self._event_append_locked(
                            "lock-release-intent",
                            {
                                **identity,
                                "operation": "close-without-LOCK_UN",
                                "retained_descriptor": self._retained_descriptor,
                            },
                        )
            finally:
                try:
                    try:
                        event_closed = _original_session_method(
                            self._origin, "_close_original_event_locked"
                        )(self, self._origin, self._event_authority)
                    except OSError as exc:
                        event_closed = False
                        if failure is None:
                            failure = AdmissionIncident(
                                "original event-log descriptor could not be closed: "
                                + str(exc)
                            )
                    if self._entered and not event_closed:
                        self._lock_authority_lost = True
                        if self._lock_authority_failure is None:
                            self._lock_authority_failure = (
                                "event-log authority was lost during close"
                            )
                        if failure is None:
                            failure = AdmissionIncident(
                                self._lock_authority_failure
                            )
                finally:
                    try:
                        self._release_lock()
                    finally:
                        self._closed = True
        if failure is not None:
            raise failure


def dry_run_report() -> dict[str, Any]:
    load_local_test_modules()
    plan = PLAN.build_plan()
    return {
        "schema": "p004-x05-runtime-live-dry-run-v1",
        "status": "DISABLED",
        "live_cli": False,
        "writes": 0,
        "subprocesses": 0,
        "resource_count": len(plan["resources"]),
        "resource_kinds": sorted({row["kind"] for row in plan["resources"]}),
        "lock_fd": 9,
        "lock_path": str(DEFAULT_LOCK),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--dry-run", action="store_true")
    group.add_argument("--execute", action="store_true")
    args = parser.parse_args(argv)
    if args.execute:
        print(
            "X05 RUNTIME NOT_READY: live coordinator CLI is disabled; no effect attempted",
            file=sys.stderr,
        )
        return 75
    print(json.dumps(dry_run_report(), sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
