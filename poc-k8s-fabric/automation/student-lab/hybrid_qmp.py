#!/usr/bin/env python3
"""Verify and stop a QEMU guest through its saved, private QMP socket.

The manifest is a private snapshot of process, namespace, PID-file, and socket
identities. A QMP UUID query on the connected socket is required before quit.
The timeouts bound this local control operation; they are not a readiness SLA.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import re
import socket
import stat
import struct
import sys
import time
import uuid
from pathlib import Path
from typing import Any, BinaryIO

MANIFEST_SCHEMA = 1
MAX_MANIFEST_BYTES = 64 * 1024
MAX_PROC_BYTES = 64 * 1024
MAX_QMP_LINE_BYTES = 64 * 1024
MAX_QMP_EVENTS = 128
MAX_UNIX_SOCKET_PATH_BYTES = 107
DEFAULT_IO_TIMEOUT = 2.0
DEFAULT_TOTAL_TIMEOUT = 8.0


class HybridQMPError(Exception):
    """A saved guest identity or QMP protocol check failed."""


@dataclasses.dataclass(frozen=True)
class FileIdentity:
    path: Path
    device: int
    inode: int


@dataclasses.dataclass(frozen=True)
class NamespaceIdentity:
    device: int
    inode: int


@dataclasses.dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    starttime: int
    uid: int
    netns: NamespaceIdentity


@dataclasses.dataclass(frozen=True)
class GuestIdentity:
    name: str
    qemu_uuid: str
    process: ProcessIdentity
    pidfile: FileIdentity
    qmp_dir: FileIdentity
    qmp: FileIdentity


@dataclasses.dataclass(frozen=True)
class BorderIdentity:
    container_id: str
    process: ProcessIdentity


@dataclasses.dataclass(frozen=True)
class Identity:
    guest: GuestIdentity
    border: BorderIdentity


def _require_keys(value: object, keys: set[str], context: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise HybridQMPError(f"invalid {context} fields")
    return value


def _integer(value: object, context: str, minimum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise HybridQMPError(f"invalid {context}")
    return value


def _path(value: object, context: str, *, qmp: bool = False) -> Path:
    if not isinstance(value, str) or not value.startswith("/") or "\x00" in value:
        raise HybridQMPError(f"invalid {context} path")
    if qmp and ("," in value or "\n" in value):
        raise HybridQMPError("invalid QMP socket path")
    if qmp and len(os.fsencode(value)) > MAX_UNIX_SOCKET_PATH_BYTES:
        raise HybridQMPError("QMP socket path exceeds the Linux AF_UNIX limit")
    return Path(value)


def _file_identity(value: object, context: str, *, qmp: bool = False) -> FileIdentity:
    record = _require_keys(value, {"path", "device", "inode"}, context)
    return FileIdentity(
        path=_path(record["path"], context, qmp=qmp),
        device=_integer(record["device"], f"{context} device", 1),
        inode=_integer(record["inode"], f"{context} inode", 1),
    )


def _namespace_identity(value: object, context: str) -> NamespaceIdentity:
    record = _require_keys(value, {"device", "inode"}, context)
    return NamespaceIdentity(
        device=_integer(record["device"], f"{context} device", 1),
        inode=_integer(record["inode"], f"{context} inode", 1),
    )


def _process_identity(value: object, context: str) -> ProcessIdentity:
    record = _require_keys(value, {"pid", "starttime", "uid", "netns"}, context)
    return ProcessIdentity(
        pid=_integer(record["pid"], f"{context} PID", 2),
        starttime=_integer(record["starttime"], f"{context} start time", 1),
        uid=_integer(record["uid"], f"{context} UID", 0),
        netns=_namespace_identity(record["netns"], f"{context} netns"),
    )


def _identity_from_json(value: object) -> Identity:
    root = _require_keys(value, {"schema", "guest", "border"}, "manifest")
    if _integer(root["schema"], "manifest schema", 1) != MANIFEST_SCHEMA:
        raise HybridQMPError("unsupported identity manifest schema")

    guest_data = _require_keys(
        root["guest"],
        {"name", "uuid", "process", "pidfile", "qmp_dir", "qmp"},
        "guest identity",
    )
    name = guest_data["name"]
    if not isinstance(name, str) or name not in {"ubuntu", "cirros"}:
        raise HybridQMPError("unknown guest name")

    qemu_uuid = guest_data["uuid"]
    if not isinstance(qemu_uuid, str):
        raise HybridQMPError("invalid guest UUID")
    try:
        parsed_uuid = uuid.UUID(qemu_uuid)
    except ValueError as exc:
        raise HybridQMPError("invalid guest UUID") from exc
    if parsed_uuid.version != 4 or str(parsed_uuid) != qemu_uuid:
        raise HybridQMPError("invalid guest UUID")

    border_data = _require_keys(
        root["border"],
        {"container_id", "process"},
        "border identity",
    )
    container_id = border_data["container_id"]
    if not isinstance(container_id, str) or not re.fullmatch(r"[0-9a-f]{64}", container_id):
        raise HybridQMPError("invalid border container ID")

    guest = GuestIdentity(
        name=name,
        qemu_uuid=qemu_uuid.lower(),
        process=_process_identity(guest_data["process"], "guest process"),
        pidfile=_file_identity(guest_data["pidfile"], "guest PID file"),
        qmp_dir=_file_identity(guest_data["qmp_dir"], "guest QMP directory", qmp=True),
        qmp=_file_identity(guest_data["qmp"], "guest QMP socket", qmp=True),
    )
    border = BorderIdentity(
        container_id=container_id,
        process=_process_identity(border_data["process"], "border process"),
    )
    if guest.process.netns != border.process.netns:
        raise HybridQMPError("saved guest and border namespaces differ")
    if guest.process.pid == border.process.pid:
        raise HybridQMPError("guest and border process identities overlap")
    if guest.qmp.path.parent != guest.qmp_dir.path:
        raise HybridQMPError("saved QMP socket is outside its private directory")
    return Identity(guest=guest, border=border)


def load_identity(path: Path) -> Identity:
    """Load one private, versioned identity snapshot without following links."""
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise HybridQMPError("cannot open identity manifest") from exc

    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o077:
            raise HybridQMPError("identity manifest is not a private regular file")
        if metadata.st_size > MAX_MANIFEST_BYTES:
            raise HybridQMPError("identity manifest exceeds the size limit")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            raw = stream.read(MAX_MANIFEST_BYTES + 1)
        if len(raw) > MAX_MANIFEST_BYTES:
            raise HybridQMPError("identity manifest exceeds the size limit")
        identity = _identity_from_bytes(raw)
        if metadata.st_uid != identity.guest.process.uid:
            raise HybridQMPError("identity manifest owner differs from the guest owner")
        return identity
    finally:
        os.close(descriptor)


def load_identity_stream(stream: BinaryIO) -> Identity:
    """Load a bounded identity document from a private caller's stdin."""
    raw = stream.read(MAX_MANIFEST_BYTES + 1)
    if len(raw) > MAX_MANIFEST_BYTES:
        raise HybridQMPError("identity manifest exceeds the size limit")
    identity = _identity_from_bytes(raw)
    caller_uid = os.geteuid()
    if caller_uid not in {0, identity.guest.process.uid}:
        raise HybridQMPError("identity guest owner differs from the invoking user")
    return identity


def _identity_from_bytes(raw: bytes) -> Identity:
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise HybridQMPError("identity manifest is not valid JSON") from exc
    return _identity_from_json(value)


def _read_limited(path: Path, context: str, limit: int = MAX_PROC_BYTES) -> bytes:
    try:
        with path.open("rb") as stream:
            content = stream.read(limit + 1)
    except FileNotFoundError as exc:
        raise HybridQMPError(f"saved {context} is absent") from exc
    except OSError as exc:
        raise HybridQMPError(f"cannot inspect saved {context}") from exc
    if len(content) > limit:
        raise HybridQMPError(f"saved {context} exceeds the size limit")
    return content


def _proc_stat_identity(raw: bytes) -> tuple[int, int]:
    try:
        text = raw.decode("ascii")
        pid_text, remainder = text.rsplit(" (", 1)
        pid = int(pid_text)
        if not remainder.endswith(")") and ") " not in remainder:
            raise ValueError
        _, fields_text = remainder.rsplit(") ", 1)
        fields = fields_text.split()
        starttime = int(fields[19])
    except (UnicodeDecodeError, ValueError, IndexError) as exc:
        raise HybridQMPError("saved process stat is malformed") from exc
    if starttime < 1:
        raise HybridQMPError("saved process start time is invalid")
    return pid, starttime


def _stat_identity(path: Path, context: str, *, follow: bool) -> os.stat_result:
    try:
        return path.stat() if follow else path.lstat()
    except FileNotFoundError as exc:
        raise HybridQMPError(f"saved {context} is absent") from exc
    except OSError as exc:
        raise HybridQMPError(f"cannot inspect saved {context}") from exc


def _validate_file(identity: FileIdentity, owner_uid: int, context: str, *, kind: str) -> None:
    metadata = _stat_identity(identity.path, context, follow=False)
    expected_kind = stat.S_ISSOCK if kind == "socket" else stat.S_ISREG
    if not expected_kind(metadata.st_mode):
        raise HybridQMPError(f"saved {context} has the wrong file type")
    if metadata.st_uid != owner_uid:
        raise HybridQMPError(f"saved {context} owner changed")
    if kind == "socket" and stat.S_IMODE(metadata.st_mode) & 0o027:
        raise HybridQMPError("saved QMP socket permissions exceed its private directory")
    if (metadata.st_dev, metadata.st_ino) != (identity.device, identity.inode):
        raise HybridQMPError(f"saved {context} identity changed")


def _validate_private_directory(identity: FileIdentity, owner_uid: int, context: str) -> None:
    metadata = _stat_identity(identity.path, context, follow=False)
    if not stat.S_ISDIR(metadata.st_mode):
        raise HybridQMPError(f"saved {context} has the wrong file type")
    if metadata.st_uid != owner_uid:
        raise HybridQMPError(f"saved {context} owner changed")
    if stat.S_IMODE(metadata.st_mode) != 0o700:
        raise HybridQMPError(f"saved {context} is not private")
    if (metadata.st_dev, metadata.st_ino) != (identity.device, identity.inode):
        raise HybridQMPError(f"saved {context} identity changed")


def _process_paths(proc_root: Path, process: ProcessIdentity) -> tuple[Path, Path]:
    root = proc_root / str(process.pid)
    return root, root / "stat"


def _validate_process(
    proc_root: Path,
    process: ProcessIdentity,
    context: str,
    *,
    qemu_uuid: str | None = None,
    qmp_path: Path | None = None,
    container_id: str | None = None,
    allow_absent: bool = False,
) -> bool:
    process_dir, stat_path = _process_paths(proc_root, process)
    try:
        metadata = process_dir.stat()
    except FileNotFoundError as exc:
        if allow_absent:
            return False
        raise HybridQMPError(f"saved {context} process is absent") from exc
    except OSError as exc:
        raise HybridQMPError(f"cannot inspect saved {context} process") from exc
    if metadata.st_uid != process.uid:
        raise HybridQMPError(f"saved {context} process owner changed")
    observed_pid, observed_starttime = _proc_stat_identity(_read_limited(stat_path, f"{context} process"))
    if observed_pid != process.pid or observed_starttime != process.starttime:
        raise HybridQMPError(f"saved {context} process start time changed")

    netns_path = process_dir / "ns" / "net"
    netns_stat = _stat_identity(netns_path, f"{context} network namespace", follow=True)
    if (netns_stat.st_dev, netns_stat.st_ino) != (process.netns.device, process.netns.inode):
        raise HybridQMPError(f"saved {context} network namespace changed")

    if container_id is not None:
        cgroup = _read_limited(process_dir / "cgroup", "border cgroup identity")
        if not _cgroup_has_container_id(cgroup, container_id):
            raise HybridQMPError("saved border container identity changed or is unavailable")

    if qemu_uuid is not None and qmp_path is not None:
        argv = _read_limited(process_dir / "cmdline", "guest command line").split(b"\x00")
        if not _contains_pair(argv, b"-uuid", qemu_uuid.encode("ascii")):
            raise HybridQMPError("saved guest UUID is absent from the process command line")
        qmp_value = b"unix:" + os.fsencode(qmp_path) + b","
        if not any(argument.startswith(qmp_value) for argument in argv):
            raise HybridQMPError("saved QMP socket is absent from the process command line")
    return True


def _contains_pair(argv: list[bytes], option: bytes, expected: bytes) -> bool:
    return any(argv[index] == option and argv[index + 1] == expected for index in range(len(argv) - 1))


def _cgroup_has_container_id(raw: bytes, container_id: str) -> bool:
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError:
        raise HybridQMPError("saved border cgroup identity is malformed") from None
    pattern = re.compile(
        rf"(?:^|/)(?:docker/|docker-)?{re.escape(container_id)}(?:\.scope)?(?:/|$)"
    )
    return any(pattern.search(line.rsplit(":", 1)[-1]) for line in text.splitlines())


def validate_identity(
    identity: Identity,
    proc_root: Path = Path("/proc"),
    *,
    allow_border_absent: bool = False,
) -> bool:
    """Recheck process, namespace, PID-file, QMP-socket, and container identity."""
    pidfile = _read_owned_file(identity.guest.pidfile, identity.guest.process.uid, "guest PID file")
    if pidfile.strip() != str(identity.guest.process.pid).encode("ascii"):
        raise HybridQMPError("saved guest PID file contents changed")
    _validate_private_directory(identity.guest.qmp_dir, identity.guest.process.uid, "guest QMP directory")
    _validate_file(identity.guest.qmp, identity.guest.process.uid, "guest QMP socket", kind="socket")
    border_live = _validate_process(
        proc_root,
        identity.border.process,
        "border",
        container_id=identity.border.container_id,
        allow_absent=allow_border_absent,
    )
    _validate_process(
        proc_root,
        identity.guest.process,
        "guest",
        qemu_uuid=identity.guest.qemu_uuid,
        qmp_path=identity.guest.qmp.path,
    )
    return border_live


def _read_owned_file(identity: FileIdentity, owner_uid: int, context: str) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(identity.path, flags)
    except FileNotFoundError as exc:
        raise HybridQMPError(f"saved {context} is absent") from exc
    except OSError as exc:
        raise HybridQMPError(f"cannot inspect saved {context}") from exc
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise HybridQMPError(f"saved {context} has the wrong file type")
        if metadata.st_uid != owner_uid:
            raise HybridQMPError(f"saved {context} owner changed")
        if (metadata.st_dev, metadata.st_ino) != (identity.device, identity.inode):
            raise HybridQMPError(f"saved {context} identity changed")
        content = os.read(descriptor, 4097)
        if len(content) > 4096:
            raise HybridQMPError(f"saved {context} exceeds the size limit")
        return content
    except OSError as exc:
        raise HybridQMPError(f"cannot inspect saved {context}") from exc
    finally:
        os.close(descriptor)
class _QMPConnection:
    """Own one bounded QMP connection and correlate its command replies."""

    def __init__(self, path: Path, io_timeout: float, total_timeout: float) -> None:
        if not 0 < io_timeout <= 60 or not 0 < total_timeout <= 120:
            raise HybridQMPError("QMP timeouts must be finite and within supported bounds")
        self.path = path
        self.io_timeout = io_timeout
        self.deadline = time.monotonic() + total_timeout
        self.connection: socket.socket | None = None
        self.buffer = bytearray()
        self.next_id = 1
        self.event_count = 0

    def __enter__(self) -> _QMPConnection:
        self.connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.connection.settimeout(self._remaining(self.io_timeout))
        try:
            self.connection.connect(os.fspath(self.path))
            self._read_greeting()
        except (OSError, TimeoutError) as exc:
            self.close()
            if isinstance(exc, TimeoutError):
                raise HybridQMPError("QMP connection timed out") from exc
            raise HybridQMPError("cannot connect to the saved QMP socket") from exc
        except BaseException:
            self.close()
            raise
        return self

    def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        self.close()

    def close(self) -> None:
        if self.connection is not None:
            self.connection.close()
            self.connection = None

    def _remaining(self, cap: float) -> float:
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise HybridQMPError("QMP total deadline expired")
        return min(cap, remaining)

    def _read_line(self) -> dict[str, Any]:
        if self.connection is None:
            raise HybridQMPError("QMP connection is closed")
        io_deadline = time.monotonic() + self.io_timeout
        while True:
            newline = self.buffer.find(b"\n")
            if newline >= 0:
                line = bytes(self.buffer[:newline])
                del self.buffer[: newline + 1]
                if not line or len(line) > MAX_QMP_LINE_BYTES:
                    raise HybridQMPError("QMP sent an empty or oversized frame")
                try:
                    message = json.loads(line)
                except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                    raise HybridQMPError("QMP sent invalid JSON") from exc
                if not isinstance(message, dict):
                    raise HybridQMPError("QMP frame is not a JSON object")
                return message

            if len(self.buffer) > MAX_QMP_LINE_BYTES:
                raise HybridQMPError("QMP frame exceeds the size limit")
            wait = min(self._remaining(self.io_timeout), io_deadline - time.monotonic())
            if wait <= 0:
                raise HybridQMPError("QMP I/O timeout expired")
            self.connection.settimeout(wait)
            try:
                chunk = self.connection.recv(min(4096, MAX_QMP_LINE_BYTES + 1 - len(self.buffer)))
            except TimeoutError as exc:
                if time.monotonic() >= self.deadline:
                    raise HybridQMPError("QMP total deadline expired") from exc
                raise HybridQMPError("QMP I/O timeout expired") from exc
            except OSError as exc:
                raise HybridQMPError("QMP read failed") from exc
            if not chunk:
                raise HybridQMPError("QMP peer closed before the expected reply")
            self.buffer.extend(chunk)

    def _read_greeting(self) -> None:
        greeting = self._read_line()
        if set(greeting) != {"QMP"} or not isinstance(greeting.get("QMP"), dict):
            raise HybridQMPError("QMP greeting is invalid")
        details = greeting["QMP"]
        if not isinstance(details.get("version"), dict) or not isinstance(details.get("capabilities"), list):
            raise HybridQMPError("QMP greeting lacks version or capabilities")

    def _send(self, command: str, request_id: str) -> None:
        if self.connection is None:
            raise HybridQMPError("QMP connection is closed")
        payload = json.dumps({"execute": command, "id": request_id}, separators=(",", ":")).encode("utf-8") + b"\n"
        self.connection.settimeout(self._remaining(self.io_timeout))
        try:
            self.connection.sendall(payload)
        except (OSError, TimeoutError) as exc:
            if time.monotonic() >= self.deadline:
                raise HybridQMPError("QMP total deadline expired") from exc
            raise HybridQMPError("QMP write failed") from exc

    def execute(self, command: str) -> Any:
        self.next_id += 1
        request_id = f"student-lab-{self.next_id}"
        self._send(command, request_id)
        for _ in range(MAX_QMP_EVENTS + 1):
            message = self._read_line()
            if "event" in message and "id" not in message:
                if not isinstance(message["event"], str):
                    raise HybridQMPError("QMP event is malformed")
                self.event_count += 1
                if self.event_count > MAX_QMP_EVENTS:
                    raise HybridQMPError("QMP event limit exceeded")
                continue
            if message.get("id") != request_id:
                raise HybridQMPError("QMP reply ID does not match the request")
            if "error" in message:
                raise HybridQMPError(f"QMP rejected {command}")
            if "return" not in message:
                raise HybridQMPError(f"QMP reply for {command} is incomplete")
            return message["return"]
        raise HybridQMPError("QMP event limit exceeded before command reply")

    def enable_capabilities(self) -> None:
        result = self.execute("qmp_capabilities")
        if result != {}:
            raise HybridQMPError("QMP capability reply is invalid")

    def query_uuid(self) -> str:
        result = self.execute("query-uuid")
        if not isinstance(result, dict) or set(result) != {"UUID"}:
            raise HybridQMPError("QMP UUID reply is invalid")
        observed = result["UUID"]
        if not isinstance(observed, str):
            raise HybridQMPError("QMP UUID reply is invalid")
        return observed.lower()

    def quit(self) -> None:
        result = self.execute("quit")
        if result != {}:
            raise HybridQMPError("QMP quit reply is invalid")

    def validate_peer(self, expected_pid: int, expected_uid: int) -> None:
        if self.connection is None or not hasattr(socket, "SO_PEERCRED"):
            return
        try:
            raw = self.connection.getsockopt(
                socket.SOL_SOCKET,
                socket.SO_PEERCRED,
                struct.calcsize("3i"),
            )
        except OSError as exc:
            raise HybridQMPError("cannot inspect QMP peer credentials") from exc
        peer_pid, peer_uid, _peer_gid = struct.unpack("3i", raw)
        if peer_pid != expected_pid or peer_uid != expected_uid:
            raise HybridQMPError("QMP peer process identity does not match the saved guest")


def _open_verified(
    identity: Identity,
    proc_root: Path,
    io_timeout: float,
    total_timeout: float,
    *,
    allow_border_absent: bool = False,
) -> _QMPConnection:
    validate_identity(identity, proc_root, allow_border_absent=allow_border_absent)
    connection = _QMPConnection(identity.guest.qmp.path, io_timeout, total_timeout)
    connection.__enter__()
    try:
        connection.validate_peer(identity.guest.process.pid, identity.guest.process.uid)
        validate_identity(identity, proc_root, allow_border_absent=allow_border_absent)
        connection.enable_capabilities()
        if connection.query_uuid() != identity.guest.qemu_uuid:
            raise HybridQMPError("QMP UUID does not match the saved guest")
        validate_identity(identity, proc_root, allow_border_absent=allow_border_absent)
    except BaseException:
        connection.close()
        raise
    return connection


def verify_guest(
    identity: Identity,
    proc_root: Path = Path("/proc"),
    *,
    io_timeout: float = DEFAULT_IO_TIMEOUT,
    total_timeout: float = DEFAULT_TOTAL_TIMEOUT,
) -> None:
    """Validate the saved process and the UUID returned by its QMP socket."""
    connection = _open_verified(identity, proc_root, io_timeout, total_timeout)
    connection.close()


def request_quit(
    identity: Identity,
    proc_root: Path = Path("/proc"),
    *,
    io_timeout: float = DEFAULT_IO_TIMEOUT,
    total_timeout: float = DEFAULT_TOTAL_TIMEOUT,
) -> None:
    """Send quit only after a same-connection QMP UUID check succeeds."""
    connection = _open_verified(identity, proc_root, io_timeout, total_timeout, allow_border_absent=True)
    try:
        validate_identity(identity, proc_root, allow_border_absent=True)
        connection.validate_peer(identity.guest.process.pid, identity.guest.process.uid)
        connection.quit()
    finally:
        connection.close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("verify", "quit"))
    parser.add_argument("--identity", required=True)
    parser.add_argument("--io-timeout", type=float, default=DEFAULT_IO_TIMEOUT)
    parser.add_argument("--total-timeout", type=float, default=DEFAULT_TOTAL_TIMEOUT)
    args = parser.parse_args(argv)

    try:
        identity = load_identity_stream(sys.stdin.buffer) if args.identity == "-" else load_identity(Path(args.identity))
        operation = verify_guest if args.action == "verify" else request_quit
        operation(
            identity,
            io_timeout=args.io_timeout,
            total_timeout=args.total_timeout,
        )
    except HybridQMPError as exc:
        print(f"hybrid-qmp: {exc}", file=sys.stderr)
        return 2
    except OSError as exc:
        print(f"hybrid-qmp: operating system error {exc.errno}", file=sys.stderr)
        return 2

    result = "identity verified" if args.action == "verify" else "quit accepted"
    print(f"hybrid-qmp: {identity.guest.name} {result}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
