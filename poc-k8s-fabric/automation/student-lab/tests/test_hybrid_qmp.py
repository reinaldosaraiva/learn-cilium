#!/usr/bin/env python3
"""Behavior tests for saved QMP identities and bounded local protocol I/O."""

from __future__ import annotations

import dataclasses
import io
import json
import os
import socket
import tempfile
import threading
import time
import unittest
from pathlib import Path
from typing import Any
from unittest.mock import patch

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import hybrid_qmp

GUEST_UUID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
CONTAINER_ID = "1" * 64


class FakeProc:
    def __init__(self, root: Path, qmp_path: Path, pidfile_path: Path) -> None:
        self.root = root
        self.marker = root / "netns-marker"
        self.marker.write_text("local namespace marker\n", encoding="ascii")
        self.guest_pid = os.getpid()
        self.border_pid = self.guest_pid + 100000
        self.guest_starttime = 12345
        self.border_starttime = 67890
        self.owner_uid = os.getuid()
        self._write_process(
            self.guest_pid,
            self.guest_starttime,
            qemu=True,
            qmp_path=qmp_path,
        )
        self._write_process(self.border_pid, self.border_starttime, qemu=False)
        self._write_text(pidfile_path, f"{self.guest_pid}\n")
        self.pidfile_path = pidfile_path
        self.qmp_path = qmp_path
        qmp_dir_stat = os.lstat(qmp_path.parent)
        qmp_stat = os.lstat(qmp_path)
        pid_stat = os.lstat(pidfile_path)
        netns_stat = os.stat(self.marker)

        self.identity_data: dict[str, Any] = {
            "schema": 1,
            "guest": {
                "name": "ubuntu",
                "uuid": GUEST_UUID,
                "process": {
                    "pid": self.guest_pid,
                    "starttime": self.guest_starttime,
                    "uid": self.owner_uid,
                    "netns": {"device": netns_stat.st_dev, "inode": netns_stat.st_ino},
                },
                "pidfile": {
                    "path": str(pidfile_path),
                    "device": pid_stat.st_dev,
                    "inode": pid_stat.st_ino,
                },
                "qmp_dir": {
                    "path": str(qmp_path.parent),
                    "device": qmp_dir_stat.st_dev,
                    "inode": qmp_dir_stat.st_ino,
                },
                "qmp": {"path": str(qmp_path), "device": qmp_stat.st_dev, "inode": qmp_stat.st_ino},
            },
            "border": {
                "container_id": CONTAINER_ID,
                "process": {
                    "pid": self.border_pid,
                    "starttime": self.border_starttime,
                    "uid": self.owner_uid,
                    "netns": {"device": netns_stat.st_dev, "inode": netns_stat.st_ino},
                },
            },
        }

    def _write_text(self, path: Path, value: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value, encoding="ascii")

    def _write_process(
        self,
        pid: int,
        starttime: int,
        *,
        qemu: bool,
        qmp_path: Path | None = None,
    ) -> None:
        process_dir = self.root / str(pid)
        (process_dir / "ns").mkdir(parents=True)
        os.symlink(self.marker, process_dir / "ns" / "net")
        fields = ["S", "1"] + ["0"] * 17 + [str(starttime)]
        self._write_text(process_dir / "stat", f"{pid} (fake process ) {' '.join(fields)}\n")
        self._write_text(process_dir / "cgroup", f"0::/system.slice/docker-{CONTAINER_ID}.scope\n")
        if qemu:
            assert qmp_path is not None
            argv = [
                b"/usr/bin/qemu-system-x86_64",
                b"-uuid",
                GUEST_UUID.encode("ascii"),
                b"-qmp",
                b"unix:" + os.fsencode(qmp_path) + b",server=on,wait=off",
            ]
            (process_dir / "cmdline").write_bytes(b"\x00".join(argv) + b"\x00")


class FakeQMPServer:
    def __init__(
        self,
        path: Path,
        *,
        uuid_value: str = GUEST_UUID,
        wrong_id: bool = False,
        expect_quit: bool = False,
        delay_greeting: float = 0,
        stream_events: bool = False,
        oversized_reply: bool = False,
    ) -> None:
        self.path = path
        self.uuid_value = uuid_value
        self.wrong_id = wrong_id
        self.expect_quit = expect_quit
        self.delay_greeting = delay_greeting
        self.stream_events = stream_events
        self.oversized_reply = oversized_reply
        self.commands: list[str] = []
        self.accepted = threading.Event()
        self.closed = threading.Event()
        self.finished = threading.Event()
        self.error: BaseException | None = None
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(os.fspath(path))
        os.chmod(path, 0o600)
        self.listener.listen(1)
        self.listener.settimeout(1)
        self.thread = threading.Thread(target=self._serve, daemon=True)

    def __enter__(self) -> FakeQMPServer:
        self.thread.start()
        return self

    def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        self.listener.close()
        self.thread.join(timeout=2)

    def _send(self, connection: socket.socket, message: object, *, fragmented: bool = False) -> None:
        payload = json.dumps(message, separators=(",", ":")).encode("utf-8") + b"\n"
        if fragmented:
            for byte in payload:
                connection.sendall(bytes([byte]))
        else:
            connection.sendall(payload)

    def _read_request(self, connection: socket.socket) -> dict[str, Any]:
        data = bytearray()
        while b"\n" not in data:
            chunk = connection.recv(1024)
            if not chunk:
                raise EOFError
            data.extend(chunk)
        line, _, _remainder = data.partition(b"\n")
        request = json.loads(line)
        if not isinstance(request, dict):
            raise ValueError("request is not an object")
        self.commands.append(str(request.get("execute")))
        return request

    def _reply(self, connection: socket.socket, request: dict[str, Any], result: object) -> None:
        request_id = "wrong-response-id" if self.wrong_id else request["id"]
        self._send(connection, {"return": result, "id": request_id})

    def _serve(self) -> None:
        connection: socket.socket | None = None
        try:
            connection, _address = self.listener.accept()
            connection.settimeout(1)
            self.accepted.set()
            if self.delay_greeting:
                time.sleep(self.delay_greeting)
            self._send(
                connection,
                {"QMP": {"version": {"qemu": {"major": 8}}, "capabilities": []}},
                fragmented=True,
            )
            request = self._read_request(connection)
            if request.get("execute") != "qmp_capabilities":
                raise AssertionError("client did not enable QMP capabilities first")
            self._send(connection, {"event": "RESET", "data": {}})
            self._reply(connection, request, {})

            if self.stream_events:
                request = self._read_request(connection)
                if request.get("execute") != "query-uuid":
                    raise AssertionError("client did not query UUID after capabilities")
                for index in range(40):
                    self._send(connection, {"event": "DEVICE_DELETED", "data": {"index": index}})
                    time.sleep(0.02)
                return

            request = self._read_request(connection)
            if request.get("execute") != "query-uuid":
                raise AssertionError("client did not query UUID after capabilities")
            if self.oversized_reply:
                connection.sendall(b"{" + b"x" * (hybrid_qmp.MAX_QMP_LINE_BYTES + 1))
                if connection.recv(1) == b"":
                    self.closed.set()
                return
            self._send(connection, {"event": "RESET", "data": {}})
            self._reply(connection, request, {"UUID": self.uuid_value})

            if self.expect_quit:
                try:
                    request = self._read_request(connection)
                except EOFError:
                    self.closed.set()
                    return
                if request.get("execute") == "quit":
                    self._reply(connection, request, {})
                else:
                    self.commands.append(f"unexpected:{request.get('execute')}")
            if connection.recv(1) == b"":
                self.closed.set()
        except EOFError:
            self.closed.set()
        except OSError:
            self.closed.set()
        except BaseException as exc:  # captured for the test thread
            self.error = exc
        finally:
            if connection is not None:
                connection.close()
            self.listener.close()
            self.finished.set()


class HybridQMPTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="hybrid-qmp-")
        self.root = Path(self.temporary.name)
        self.proc_root = self.root / "proc"
        self.proc_root.mkdir()
        self.qmp_directory = self.root / "qmp"
        self.qmp_directory.mkdir(mode=0o700)
        self.socket_path = self.qmp_directory / "guest.qmp"
        self.pidfile_path = self.root / "qemu.pid"
        self.server: FakeQMPServer | None = None

    def tearDown(self) -> None:
        if self.server is not None:
            self.server.__exit__(None, None, None)
        self.temporary.cleanup()

    def start_server(self, **kwargs: Any) -> FakeQMPServer:
        self.server = FakeQMPServer(self.socket_path, **kwargs)
        self.server.__enter__()
        deadline = time.monotonic() + 1
        while not self.socket_path.exists() and time.monotonic() < deadline:
            time.sleep(0.001)
        return self.server

    def identity(self) -> hybrid_qmp.Identity:
        fake_proc = FakeProc(self.proc_root, self.socket_path, self.pidfile_path)
        manifest = self.root / "identity.json"
        manifest.write_text(json.dumps(fake_proc.identity_data), encoding="utf-8")
        manifest.chmod(0o600)
        identity = hybrid_qmp.load_identity(manifest)
        self.fake_proc = fake_proc
        return identity

    def assert_server_closed(self, server: FakeQMPServer) -> None:
        server.finished.wait(timeout=1)
        self.assertTrue(server.closed.is_set())
        self.assertIsNone(server.error)

    def test_query_correlates_ids_while_ignoring_interleaved_events(self) -> None:
        server = self.start_server()
        identity = self.identity()

        hybrid_qmp.verify_guest(identity, self.proc_root)

        self.assertEqual(["qmp_capabilities", "query-uuid"], server.commands)
        self.assert_server_closed(server)

    def test_quit_is_sent_only_after_same_connection_uuid_validation(self) -> None:
        server = self.start_server(expect_quit=True)
        identity = self.identity()

        hybrid_qmp.request_quit(identity, self.proc_root)

        self.assertEqual(["qmp_capabilities", "query-uuid", "quit"], server.commands)
        self.assert_server_closed(server)

    def test_mismatched_uuid_closes_socket_without_sending_quit(self) -> None:
        server = self.start_server(uuid_value="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        identity = self.identity()

        with self.assertRaisesRegex(hybrid_qmp.HybridQMPError, "QMP UUID does not match"):
            hybrid_qmp.request_quit(identity, self.proc_root)

        self.assertEqual(["qmp_capabilities", "query-uuid"], server.commands)
        server.finished.wait(timeout=1)
        self.assertTrue(server.closed.is_set())

    def test_wrong_reply_id_is_rejected_and_connection_closes(self) -> None:
        server = self.start_server(wrong_id=True)
        identity = self.identity()

        with self.assertRaisesRegex(hybrid_qmp.HybridQMPError, "reply ID"):
            hybrid_qmp.verify_guest(identity, self.proc_root)

        server.finished.wait(timeout=1)
        self.assertTrue(server.closed.is_set())

    def test_replaced_socket_inode_fails_before_connect(self) -> None:
        server = self.start_server()
        identity = self.identity()
        replaced_guest = dataclasses.replace(
            identity.guest,
            qmp=dataclasses.replace(identity.guest.qmp, inode=identity.guest.qmp.inode + 1),
        )
        replaced_identity = dataclasses.replace(identity, guest=replaced_guest)

        with self.assertRaisesRegex(hybrid_qmp.HybridQMPError, "QMP socket identity changed"):
            hybrid_qmp.verify_guest(replaced_identity, self.proc_root)

        self.assertFalse(server.accepted.is_set())

    def test_qmp_socket_path_obeys_linux_sun_path_boundary(self) -> None:
        maximum_path = "/" + "x" * (hybrid_qmp.MAX_UNIX_SOCKET_PATH_BYTES - 1)
        too_long_path = maximum_path + "x"

        self.assertEqual(len(os.fsencode(maximum_path)), hybrid_qmp.MAX_UNIX_SOCKET_PATH_BYTES)
        self.assertEqual(
            hybrid_qmp._path(maximum_path, "boundary path", qmp=True),
            Path(maximum_path),
        )
        with self.assertRaisesRegex(hybrid_qmp.HybridQMPError, "AF_UNIX limit"):
            hybrid_qmp._path(too_long_path, "long path", qmp=True)

    def test_qmp_socket_with_public_permissions_is_rejected_before_connect(self) -> None:
        server = self.start_server()
        identity = self.identity()
        os.chmod(self.socket_path, 0o666)

        with self.assertRaisesRegex(hybrid_qmp.HybridQMPError, "private directory"):
            hybrid_qmp.verify_guest(identity, self.proc_root)

        self.assertFalse(server.accepted.is_set())

    def test_qemu_daemon_umask_socket_mode_is_safe_inside_private_directory(self) -> None:
        server = self.start_server()
        identity = self.identity()
        os.chmod(self.socket_path, 0o750)

        hybrid_qmp.verify_guest(identity, self.proc_root)

        self.assertEqual(["qmp_capabilities", "query-uuid"], server.commands)
        self.assert_server_closed(server)

    def test_replaced_qmp_directory_fails_before_connect(self) -> None:
        server = self.start_server()
        identity = self.identity()
        directory = identity.guest.qmp_dir.path
        moved_directory = directory.with_name(directory.name + "-old")
        os.rename(directory, moved_directory)
        directory.mkdir(mode=0o700)

        with self.assertRaisesRegex(hybrid_qmp.HybridQMPError, "directory identity changed"):
            hybrid_qmp.verify_guest(identity, self.proc_root)

        self.assertFalse(server.accepted.is_set())

    def test_border_identity_mismatch_fails_without_treating_it_as_absent(self) -> None:
        server = self.start_server()
        identity = self.identity()
        cgroup = self.proc_root / str(identity.border.process.pid) / "cgroup"
        cgroup.unlink()
        cgroup.mkdir()

        with self.assertRaisesRegex(hybrid_qmp.HybridQMPError, "cannot inspect saved border cgroup"):
            hybrid_qmp.verify_guest(identity, self.proc_root)

        self.assertFalse(server.accepted.is_set())

    def test_guest_process_must_match_the_saved_uuid_and_qmp_path(self) -> None:
        server = self.start_server()
        identity = self.identity()
        command_line = self.proc_root / str(identity.guest.process.pid) / "cmdline"
        command_line.write_bytes(
            b"/usr/bin/qemu-system-x86_64\x00-uuid\x00"
            b"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb\x00"
        )

        with self.assertRaisesRegex(hybrid_qmp.HybridQMPError, "guest UUID is absent"):
            hybrid_qmp.verify_guest(identity, self.proc_root)

        self.assertFalse(server.accepted.is_set())

    def test_missing_saved_process_is_an_explicit_error_before_qmp(self) -> None:
        server = self.start_server()
        identity = self.identity()
        border_directory = self.proc_root / str(identity.border.process.pid)
        for path in sorted(border_directory.rglob("*"), reverse=True):
            path.unlink() if path.is_symlink() or path.is_file() else path.rmdir()
        border_directory.rmdir()

        with self.assertRaisesRegex(hybrid_qmp.HybridQMPError, "saved border process is absent"):
            hybrid_qmp.verify_guest(identity, self.proc_root)

        self.assertFalse(server.accepted.is_set())

    def test_request_quit_uses_the_saved_guest_namespace_after_border_exit(self) -> None:
        server = self.start_server(expect_quit=True)
        identity = self.identity()
        border_directory = self.proc_root / str(identity.border.process.pid)
        for path in sorted(border_directory.rglob("*"), reverse=True):
            path.unlink() if path.is_symlink() or path.is_file() else path.rmdir()
        border_directory.rmdir()

        hybrid_qmp.request_quit(identity, self.proc_root)

        self.assertEqual(["qmp_capabilities", "query-uuid", "quit"], server.commands)
        self.assert_server_closed(server)

    def test_identity_can_be_loaded_from_bounded_stdin(self) -> None:
        self.start_server()
        identity = self.identity()
        raw = json.dumps(self.fake_proc.identity_data).encode("utf-8")

        self.assertEqual(identity, hybrid_qmp.load_identity_stream(io.BytesIO(raw)))

    def test_identity_stdin_rejects_other_guest_owners(self) -> None:
        self.start_server()
        fake_proc = FakeProc(self.proc_root, self.socket_path, self.pidfile_path)
        fake_proc.identity_data["guest"]["process"]["uid"] += 1
        raw = json.dumps(fake_proc.identity_data).encode("utf-8")

        with self.assertRaisesRegex(hybrid_qmp.HybridQMPError, "invoking user"):
            hybrid_qmp.load_identity_stream(io.BytesIO(raw))

    def test_identity_stdin_allows_root_to_inspect_a_saved_student_guest(self) -> None:
        self.start_server()
        fake_proc = FakeProc(self.proc_root, self.socket_path, self.pidfile_path)
        raw = json.dumps(fake_proc.identity_data).encode("utf-8")

        with patch("hybrid_qmp.os.geteuid", return_value=0):
            identity = hybrid_qmp.load_identity_stream(io.BytesIO(raw))

        self.assertEqual(fake_proc.owner_uid, identity.guest.process.uid)

    def test_privileged_inspector_still_rejects_a_changed_guest_owner(self) -> None:
        self.start_server()
        identity = self.identity()
        changed_process = dataclasses.replace(identity.guest.process, uid=identity.guest.process.uid + 1)
        changed_identity = dataclasses.replace(
            identity,
            guest=dataclasses.replace(identity.guest, process=changed_process),
        )

        with patch("hybrid_qmp.os.geteuid", return_value=0):
            with self.assertRaisesRegex(hybrid_qmp.HybridQMPError, "PID file owner changed"):
                hybrid_qmp.validate_identity(changed_identity, self.proc_root)

    def test_identity_stdin_has_a_strict_size_limit(self) -> None:
        oversized = io.BytesIO(b" " * (hybrid_qmp.MAX_MANIFEST_BYTES + 1))

        with self.assertRaisesRegex(hybrid_qmp.HybridQMPError, "size limit"):
            hybrid_qmp.load_identity_stream(oversized)

    def test_io_timeout_is_bounded_and_closes_socket(self) -> None:
        server = self.start_server(delay_greeting=0.2)
        identity = self.identity()
        started = time.monotonic()

        with self.assertRaisesRegex(hybrid_qmp.HybridQMPError, "I/O timeout"):
            hybrid_qmp.verify_guest(identity, self.proc_root, io_timeout=0.04, total_timeout=0.5)

        self.assertLess(time.monotonic() - started, 0.5)
        server.finished.wait(timeout=1)

    def test_total_deadline_expires_while_events_keep_arriving(self) -> None:
        server = self.start_server(stream_events=True)
        identity = self.identity()
        started = time.monotonic()

        with self.assertRaisesRegex(hybrid_qmp.HybridQMPError, "total deadline"):
            hybrid_qmp.verify_guest(identity, self.proc_root, io_timeout=0.15, total_timeout=0.13)

        self.assertLess(time.monotonic() - started, 0.7)
        server.finished.wait(timeout=1)

    def test_oversized_qmp_frame_is_rejected(self) -> None:
        server = self.start_server(oversized_reply=True)
        identity = self.identity()

        with self.assertRaisesRegex(hybrid_qmp.HybridQMPError, "size limit"):
            hybrid_qmp.verify_guest(identity, self.proc_root)

        server.finished.wait(timeout=1)
        self.assertTrue(server.closed.is_set())


if __name__ == "__main__":
    unittest.main(verbosity=2)
