#!/usr/bin/env python3
"""Offline and real-handle checks for the creator-owned X05 captures."""

from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import inspect
import json
import os
import pathlib
import select
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import types
from typing import Any
from unittest import mock


HERE = pathlib.Path(__file__).resolve().parent
CORPUS_LOCATION = pathlib.Path("/tmp/p004-capture-parent-wire-corpus-location.json")
CORPUS_MANIFEST_SHA256 = (
    "301f728436d1b01c6ffdbdd82b9a5a58adf570c0755a1f9fe81378ba77e5a085"
)


def load(name: str, path: pathlib.Path) -> Any:
    existing = sys.modules.get(name)
    if existing is not None:
        assert pathlib.Path(existing.__file__).resolve() == path.resolve()
        return existing
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


CAPTURE = load("x05_capture_runtime_contract", HERE / "x05-capture.py")


def expect_error(error: type[BaseException], function: Any) -> BaseException:
    try:
        function()
    except error as exc:
        return exc
    raise AssertionError("expected " + error.__name__)


def static_checks() -> dict[str, Any]:
    assert CAPTURE.APPLY.NB.RUNTIME is CAPTURE.APPLY.RUNTIME
    assert tuple(inspect.signature(CAPTURE.CaptureSession.from_builder).parameters) == (
        "builder",
    )
    assert tuple(inspect.signature(CAPTURE.CaptureSession.start).parameters) == (
        "self",
    )
    assert tuple(inspect.signature(CAPTURE.CaptureSession.health).parameters) == (
        "self",
    )
    assert tuple(inspect.signature(CAPTURE.CaptureSession.stop).parameters) == ("self",)
    expression = CAPTURE._ifindex_filter((37, 9, 37, 4))
    assert expression == "(link[4:4] = 4 or link[4:4] = 9 or link[4:4] = 37)"
    assert all(
        token not in expression.lower()
        for token in ("icmp", "udp", "vxlan", "src", "dst", "host", "port")
    )
    assert (
        24 + CAPTURE.CAPTURE_MAX_PACKETS * (16 + CAPTURE.CAPTURE_SNAPLEN)
        <= CAPTURE.CAPTURE_MAX_BYTES
    )
    assert CAPTURE.main(["--execute"]) == 75
    assert CAPTURE.main(["--dry-run"]) == 0
    assert CAPTURE.CaptureSession._listening_ready(
        b"tcpdump: listening on any, link-type LINUX_SLL2 (Linux cooked v2), "
        b"snapshot length 262144 bytes\n"
    )
    for foreign in (
        b"listening on eth0, link-type LINUX_SLL2 (Linux cooked v2)\n",
        b"listening on any, link-type EN10MB (Ethernet)\n",
    ):
        expect_error(
            CAPTURE.CaptureError,
            lambda foreign=foreign: CAPTURE.CaptureSession._listening_ready(foreign),
        )

    fake_builder = types.SimpleNamespace(
        _config=types.SimpleNamespace(test_only_paths=False)
    )
    fake_tools = {
        name: types.SimpleNamespace(path=pathlib.Path("/host/" + name))
        for name in ("tcpdump", "nsenter", "libpcap")
    }
    targets = [
        {
            "label": "host" if index == 0 else "container-" + str(index),
            "pid": 5000 + index,
            "netns_inode": 6000 + index,
            "mntns_inode": 7000 + index,
        }
        for index in range(5)
    ]
    contract = {
        "points": [
            {
                "id": capture_id,
                "interfaces": [{"ifindex": index + 10}],
                "target": targets[index],
                "target_sha256": str(index) * 64,
            }
            for index, capture_id in enumerate(CAPTURE.APPLY.CAPTURE_POINT_IDS)
        ]
    }
    planned = CAPTURE.CaptureSession._planned_slots(
        fake_builder, contract, fake_tools
    )
    for capture_id, target in zip(
        CAPTURE.APPLY.CAPTURE_POINT_IDS[1:], targets[1:]
    ):
        argv = planned[capture_id]["argv"]
        assert argv[:3] == [
            "/host/nsenter",
            f"--net=/proc/{target['pid']}/ns/net",
            "--",
        ]
        assert not any(argument.startswith("--mount") for argument in argv)
        assert argv[3] == "/host/tcpdump"
    return {"filter": expression, "public_methods": 3, "source_argv": "net-only"}


def corpus_checks() -> dict[str, Any]:
    location = json.loads(CORPUS_LOCATION.read_text(encoding="utf-8"))
    manifest_path = pathlib.Path(location["manifest"])
    manifest_raw = manifest_path.read_bytes()
    assert hashlib.sha256(manifest_raw).hexdigest() == CORPUS_MANIFEST_SHA256
    manifest = json.loads(manifest_raw)
    assert manifest["schema"] == "p004-capture-parent-wire-corpus-v1"
    assert len(manifest["cases"]) == location["cases"] == 29
    decoded = 0
    rejected = 0
    selected_records = 0
    for case in manifest["cases"]:
        path = pathlib.Path(case["path"])
        raw = path.read_bytes()
        assert len(raw) == case["size"]
        assert hashlib.sha256(raw).hexdigest() == case["sha256"]
        structural_error = case["expected"]["outcome"] == "ERROR"
        if structural_error:
            expect_error(
                CAPTURE.CaptureError, lambda raw=raw: CAPTURE._pcap_records(raw)
            )
            rejected += 1
            continue
        result = CAPTURE._pcap_records(raw)
        assert result["linktype"] == CAPTURE.DLT_LINUX_SLL2
        for ifindex in result["ifindices"]:
            assert CAPTURE._ifindex_filter((ifindex,)) == f"(link[4:4] = {ifindex})"
        selected_records += result["record_count"]
        decoded += 1
    assert decoded + rejected == 29
    return {
        "cases": 29,
        "structurally_valid": decoded,
        "structurally_rejected": rejected,
        "selected_records": selected_records,
    }


class _FocusedBuilder:
    def __init__(self, directory: pathlib.Path) -> None:
        self._config = types.SimpleNamespace(
            test_only_paths=True,
            evidence_path=directory,
            required_uid=os.getuid(),
        )
        self._unknown = False
        self._state = "BUILT"
        self._consume_lock = threading.RLock()
        self._capture_session: Any | None = None
        self._cleanup_result: dict[str, Any] | None = None
        self._final_absence: dict[str, Any] | None = None
        self.retention_events: list[dict[str, Any]] = []
        self.retention_event_failure: str | None = None
        self.progress: list[dict[str, Any]] = []
        self.spawn_intents: list[str] = []

    def _capture_health_call(self, session: Any) -> dict[str, Any]:
        assert session._builder is self
        return {"points": list(CAPTURE.APPLY.CAPTURE_POINT_IDS)}

    def _capture_spawn_intent_call(self, session: Any, capture_id: str) -> None:
        assert session._builder is self
        self.spawn_intents.append(capture_id)

    def _capture_progress_call(self, session: Any) -> dict[str, Any]:
        assert session._builder is self
        marker = {
            "state": session._published_state,
            "sequence": len(self.progress) + 1,
            "previous_sha256": "1" * 64,
            "sha256": hashlib.sha256(
                (session._published_state + str(len(self.progress))).encode("ascii")
            ).hexdigest(),
            "pid_journal_sha256": session._pid_sha256,
        }
        self.progress.append(marker)
        return copy_dict(marker)

    def _verify_retention_authority(
        self, session: Any, *, direct_absence: bool
    ) -> dict[str, str]:
        assert session is self._capture_session
        assert session._builder is self
        assert self._state == "COMPENSATED"
        assert not self._unknown
        assert self._cleanup_result is not None
        assert self._cleanup_result["status"] == "PASS"
        assert self._final_absence is not None
        assert self._final_absence["status"] == "PASS"
        assert session._state == "STOPPED"
        assert session._ownership_status == "PASS"
        assert session._published_state == "STOPPED"
        assert session._pid_raw is not None
        if direct_absence:
            assert (
                pathlib.Path(session._contract["pid_journal"]["path"]).read_bytes()
                == session._pid_raw
            )
        for handle in session._handles:
            session._verify_handle(handle, require_live=False)
        if direct_absence:
            assert self._final_absence["captures"] == len(session._handles)
        return {
            "status": "PASS",
            "state": "COMPENSATED",
            "capture": "STOPPED",
        }

    def _record_retention_event(
        self, session: Any, event: str, detail: dict[str, Any]
    ) -> dict[str, Any]:
        assert session is self._capture_session
        if self.retention_event_failure == event:
            raise CAPTURE.CaptureAmbiguous(
                "synthetic retention event failure: " + event
            )
        record = {
            "sequence": len(self.retention_events) + 1,
            "event": event,
            "detail": copy_dict(detail),
        }
        self.retention_events.append(copy_dict(record))
        return record


def copy_dict(value: dict[str, Any]) -> dict[str, Any]:
    return json.loads(json.dumps(value))


def _focused_contract(directory: pathlib.Path) -> dict[str, Any]:
    netns = pathlib.Path("/proc/self/ns/net").stat().st_ino
    mntns = pathlib.Path("/proc/self/ns/mnt").stat().st_ino
    points = []
    for index, capture_id in enumerate(CAPTURE.APPLY.CAPTURE_POINT_IDS, 1):
        points.append(
            {
                "id": capture_id,
                "target": {
                    "label": "host" if capture_id == "fabric" else "test-" + capture_id,
                    "pid": os.getpid(),
                    "start_ticks": 1,
                    "netns_inode": netns,
                    "mntns_inode": mntns,
                    "container_name": None,
                    "container_id": None,
                    "image_id": None,
                    "labels": None,
                },
                "interfaces": [{"name": "if" + str(index), "ifindex": index}],
                "target_sha256": hashlib.sha256(capture_id.encode("ascii")).hexdigest(),
            }
        )
    return {
        "schema": "p004-x05-runtime-capture-bindings-v1",
        "owner": "focused-capture-test",
        "run_hex": "abc123",
        "marker_sha256": "2" * 64,
        "runtime_journal_path": str(directory / "runtime.jsonl"),
        "runtime_journal_sha256": "3" * 64,
        "runtime_journal_head_sha256": "4" * 64,
        "points": points,
        "sources": [],
        "pid_journal": {
            "schema": CAPTURE.APPLY.CAPTURE_PID_SCHEMA,
            "path": str(directory / CAPTURE.APPLY.CAPTURE_PID_NAME),
            "required_state": "STOPPED",
            "capture_ids": list(CAPTURE.APPLY.CAPTURE_POINT_IDS),
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


def _focused_pin(name: str, path: pathlib.Path) -> Any:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
    info = os.fstat(descriptor)
    return CAPTURE._ToolPin(
        name=name,
        path=path,
        descriptor=descriptor,
        identity=CAPTURE._source_identity(info),
        sha256=hashlib.sha256(
            CAPTURE._read_fd(descriptor, CAPTURE.APPLY.MAX_LOCAL_FILE)
        ).hexdigest(),
        version="focused-test",
    )


@contextlib.contextmanager
def focused_session() -> Any:
    with tempfile.TemporaryDirectory() as raw_directory:
        directory = pathlib.Path(raw_directory)
        builder = _FocusedBuilder(directory)
        executable = pathlib.Path(os.path.realpath(sys.executable))
        tools = {
            "tcpdump": _focused_pin("tcpdump", executable),
            "nsenter": _focused_pin("nsenter", executable),
            "libpcap": _focused_pin("libpcap", pathlib.Path(CAPTURE.__file__).resolve()),
        }
        contract = _focused_contract(directory)
        slots = CAPTURE.CaptureSession._planned_slots(builder, contract, tools)
        session = CAPTURE.CaptureSession(
            builder=builder,
            contract=contract,
            tools=tools,
            slots=slots,
        )
        builder._capture_session = session
        session._state = "STARTING"
        session._checkpoint("STARTING0", initial=True)
        try:
            yield session, builder
        finally:
            for handle in session._handles:
                if handle.process.returncode is None:
                    with contextlib.suppress(ProcessLookupError):
                        handle.process.terminate()
                    with contextlib.suppress(
                        subprocess.TimeoutExpired, ChildProcessError
                    ):
                        handle.process.wait(timeout=2.0)
                if not handle.stderr_receiver.closed:
                    try:
                        session._verify_stderr(handle)
                    except CAPTURE.CaptureSecurityError:
                        pass
                    else:
                        handle.stderr_receiver.close()
            if not session._released:
                session._close_unstarted()
                retained = (
                    session._retention_pid_fd,
                    session._retention_parent_fd,
                    session._retention_directory_fd,
                )
                for descriptor in retained:
                    if descriptor is not None:
                        with contextlib.suppress(OSError):
                            os.close(descriptor)


def focused_failure_checks() -> dict[str, Any]:
    cases = 0

    for fault in ("spawn-before-fabric", "spawn-after-popen-fabric"):
        with focused_session() as (session, builder):
            CAPTURE._TEST_FAULT = fault
            expect_error(CAPTURE.CaptureAmbiguous, session.start)
            post_popen = fault == "spawn-after-popen-fabric"
            assert len(session._handles) == int(post_popen)
            if post_popen:
                assert session._slots["fabric"]["pid"] is not None
            else:
                assert session._slots["fabric"]["pid"] is None
            result = session.stop()
            assert result["packet_status"] == "ERROR"
            if post_popen:
                assert builder._unknown
                assert result["state"] == "STOP_FAILED"
                assert result["ownership_status"] == "ERROR"
            else:
                assert not builder._unknown
                assert result["state"] == "STOPPED"
                assert result["ownership_status"] == "PASS"
            cases += 1
        CAPTURE._TEST_FAULT = None

    with focused_session() as (session, builder):
        with mock.patch.object(CAPTURE.subprocess, "Popen", side_effect=OSError("popen")):
            expect_error(OSError, session.start)
        assert session._handles == [] and session._slots["fabric"]["pid"] is None
        result = session.stop()
        assert result["state"] == "STOPPED"
        assert result["ownership_status"] == "PASS"
        assert result["packet_status"] == "ERROR"
        assert not builder._unknown
        cases += 1

    with focused_session() as (session, builder):
        with mock.patch.object(CAPTURE.os, "pidfd_open", side_effect=OSError("pidfd")):
            expect_error(OSError, session.start)
        assert len(session._handles) == 1
        assert session._slots["fabric"]["pid"] == session._handles[0].process.pid
        result = session.stop()
        assert result["state"] == "STOP_FAILED"
        assert result["ownership_status"] == "ERROR" and builder._unknown
        assert session._slots["fabric"]["pid"] is not None
        cases += 1

    with focused_session() as (session, builder):
        original_open = CAPTURE.os.pidfd_open
        original_fstat = CAPTURE.os.fstat
        opened: list[int] = []
        failed = False

        def remember_pidfd(pid: int, flags: int) -> int:
            descriptor = original_open(pid, flags)
            opened.append(descriptor)
            return descriptor

        def fail_pidfd_identity(descriptor: int) -> os.stat_result:
            nonlocal failed
            if opened and descriptor == opened[0] and not failed:
                failed = True
                raise OSError("pidfd identity")
            return original_fstat(descriptor)

        with mock.patch.object(
            CAPTURE.os, "pidfd_open", side_effect=remember_pidfd
        ), mock.patch.object(CAPTURE.os, "fstat", side_effect=fail_pidfd_identity):
            expect_error(OSError, session.start)
        assert session._handles[0].pidfd is not None
        result = session.stop()
        assert result["state"] == "STOP_FAILED"
        assert result["ownership_status"] == "ERROR" and builder._unknown
        assert session._slots["fabric"]["reaped"] is False
        cases += 1

    with focused_session() as (session, builder):
        original_read_proc = CAPTURE._read_proc
        failed = False

        def fail_process_stat(
            path: pathlib.Path, maximum: int = 1024 * 1024
        ) -> bytes:
            nonlocal failed
            if (
                str(path).startswith("/proc/")
                and str(path).endswith("/stat")
                and not failed
            ):
                failed = True
                raise CAPTURE.CaptureSecurityError("synthetic process stat failure")
            return original_read_proc(path, maximum)

        with mock.patch.object(CAPTURE, "_read_proc", side_effect=fail_process_stat):
            expect_error(CAPTURE.CaptureSecurityError, session.start)
        assert session._handles[0].pidfd is not None
        result = session.stop()
        assert result["state"] == "STOP_FAILED"
        assert result["ownership_status"] == "ERROR" and builder._unknown
        assert session._slots["fabric"]["reaped"] is True
        cases += 1

    for failed_dup in (1, 2):
        with focused_session() as (session, builder):
            original_dup = CAPTURE.os.dup
            calls = 0

            def fail_selected_dup(descriptor: int) -> int:
                nonlocal calls
                calls += 1
                if calls == failed_dup:
                    raise OSError("dup")
                return original_dup(descriptor)

            with mock.patch.object(CAPTURE.os, "dup", side_effect=fail_selected_dup):
                expect_error(OSError, session.start)
            result = session.stop()
            assert result["state"] == "STOPPED"
            assert result["ownership_status"] == "PASS"
            assert result["packet_status"] == "ERROR"
            assert not builder._unknown
            assert session._slots["fabric"]["reaped"] is True
            cases += 1

    for guard_name in ("pidfd_guard", "pcap_guard"):
        with focused_session() as (session, builder):
            CAPTURE._TEST_FAULT = "spawn-before-chassis-1"
            expect_error(CAPTURE.CaptureAmbiguous, session.start)
            handle = session._handles[0]
            guard = getattr(handle, guard_name)
            assert type(guard) is int
            os.close(guard)
            replacement = os.open("/dev/null", os.O_RDONLY)
            if replacement != guard:
                os.dup2(replacement, guard)
                os.close(replacement)
            expect_error(
                CAPTURE.CaptureSecurityError,
                lambda: session._verify_handle(handle, require_live=True),
            )
            result = session.stop()
            assert result["packet_status"] == "ERROR"
            if guard_name == "pidfd_guard":
                assert result["state"] == "STOP_FAILED"
                assert result["ownership_status"] == "ERROR"
                assert builder._unknown
                assert session._slots["fabric"]["reaped"] is False
            else:
                assert result["state"] == "STOPPED"
                assert result["ownership_status"] == "PASS"
                assert not builder._unknown
                assert session._slots["fabric"]["reaped"] is True
            cases += 1
        CAPTURE._TEST_FAULT = None

    for boundary in (
        "pid-before-STARTING1",
        "pid-after-STARTING1",
        "marker-before-STARTING1",
        "marker-after-STARTING1",
    ):
        with focused_session() as (session, builder):
            CAPTURE._TEST_FAULT = boundary
            expect_error(CAPTURE.CaptureAmbiguous, session.start)
            assert session._publication_unknown and builder._unknown
            progress_count = len(builder.progress)
            result = session.stop()
            assert result["ownership_status"] == "PASS"
            assert result["packet_status"] == "ERROR"
            assert session._publication_unknown and builder._unknown
            assert len(builder.progress) == progress_count
            assert session.stop() == result
            cases += 1
        CAPTURE._TEST_FAULT = None

    return {"failure_windows": cases}


def focused_readiness_checks() -> dict[str, Any]:
    header = (
        "os.write(1, struct.pack('<IHHIIII', 0xa1b2c3d4, 2, 4, 0, 0, 262144, 276));"
        "os.fsync(1);"
    )
    listener = (
        "os.write(2, b'listening on any, link-type LINUX_SLL2 (Linux cooked v2)\\n');"
    )
    wait_and_footer = (
        "signal.signal(signal.SIGINT, lambda *_: sys.exit(0));"
        "signal.signal(signal.SIGTERM, lambda *_: sys.exit(0));"
        "time.sleep(30)"
    )
    scripts = {
        "header-only": "import os,signal,struct,sys,time;" + header + wait_and_footer,
        "listening-only": "import os,signal,struct,sys,time;" + listener + wait_and_footer,
        "foreign-listening": (
            "import os,signal,struct,sys,time;"
            + header
            + "os.write(2, b'listening on eth0, link-type EN10MB (Ethernet)\\n');"
            + wait_and_footer
        ),
        "malformed-listening": (
            "import os,signal,struct,sys,time;"
            + header
            + "os.write(2, b'listening on any, link-type LINUX_SLL2 broken\\n');"
            + wait_and_footer
        ),
        "early-exit": "import sys,time;time.sleep(0.02);sys.exit(7)",
    }
    original_child = CAPTURE._TEST_CHILD
    original_startup = CAPTURE.CAPTURE_STARTUP_SECONDS
    try:
        CAPTURE.CAPTURE_STARTUP_SECONDS = 0.08
        for label, script in scripts.items():
            CAPTURE._TEST_CHILD = script
            with focused_session() as (session, _builder):
                expect_error(CAPTURE.CaptureError, session.start)
                assert session._ready_count == 0, label
                result = session.stop()
                assert result["packet_status"] == "ERROR"
                assert result["ownership_status"] == "PASS"
        return {"readiness_negatives": len(scripts)}
    finally:
        CAPTURE._TEST_CHILD = original_child
        CAPTURE.CAPTURE_STARTUP_SECONDS = original_startup


def focused_lifetime_checks() -> dict[str, Any]:
    outcomes: dict[str, bool] = {}
    real_monotonic = time.monotonic
    for label, elapsed in (
        ("below", 899.999),
        ("equal", 900.0),
        ("above", 900.001),
    ):
        with focused_session() as (session, _builder):
            CAPTURE._TEST_FAULT = "spawn-before-chassis-1"
            expect_error(CAPTURE.CaptureAmbiguous, session.start)
            base = real_monotonic()
            session._started_monotonic = base
            first = True

            def clock() -> float:
                nonlocal first
                if first:
                    first = False
                    return base + elapsed
                return real_monotonic()

            with mock.patch.object(CAPTURE.time, "monotonic", side_effect=clock):
                result = session.stop()
            exceeded = "capture-lifetime-exceeded" in result["errors"]
            assert exceeded is (label == "above")
            assert result["ownership_status"] == "PASS"
            assert session._slots["fabric"]["reaped"] is True
            outcomes[label] = exceeded
        CAPTURE._TEST_FAULT = None
    return outcomes


def _wait_for_test_pidfd(descriptor: int, timeout: float = 2.0) -> None:
    poller = select.poll()
    poller.register(descriptor, select.POLLIN)
    assert poller.poll(int(timeout * 1000))


def _assert_test_pidfd_consumed(descriptor: int) -> None:
    expect_error(
        ChildProcessError,
        lambda: os.waitid(
            os.P_PIDFD,
            descriptor,
            os.WEXITED | os.WNOWAIT | os.WNOHANG,
        ),
    )


def focused_stop_reap_checks() -> dict[str, Any]:
    """Prove phase-boundary exits are reaped through the retained pidfd."""
    child = r"""
import os, signal, struct, time
stopping = False
def stop(_signum, _frame):
    global stopping
    stopping = True
signal.signal(signal.SIGINT, signal.SIG_IGN)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
signal.signal(signal.SIGUSR1, stop)
os.write(1, struct.pack("<IHHIIII", 0xa1b2c3d4, 2, 4, 0, 0, 262144, 276))
os.fsync(1)
os.write(2, b"listening on any, link-type LINUX_SLL2 (Linux cooked v2)\n")
while not stopping:
    time.sleep(0.005)
os.write(2, b"0 packets captured\n0 packets received by filter\n0 packets dropped by kernel\n")
"""
    phases = (
        (signal.SIGINT, 0.02),
        (signal.SIGTERM, 0.02),
        (signal.SIGKILL, 0.02),
    )
    original_child = CAPTURE._TEST_CHILD
    original_phases = CAPTURE.STOP_PHASES
    original_wait = CAPTURE.CaptureSession._wait_process
    outcomes: dict[str, int] = {}
    try:
        CAPTURE._TEST_CHILD = child
        CAPTURE.STOP_PHASES = phases

        with focused_session() as (session, _builder):
            CAPTURE._TEST_FAULT = "spawn-before-chassis-1"
            expect_error(CAPTURE.CaptureAmbiguous, session.start)
            handle = session._handles[0]
            exited_after_timeout = False

            def exit_between_phases(
                owner: Any, candidate: Any, timeout: float
            ) -> int | None:
                nonlocal exited_after_timeout
                result = original_wait(owner, candidate, timeout)
                if (
                    candidate is handle
                    and timeout > 0
                    and result is None
                    and not exited_after_timeout
                ):
                    exited_after_timeout = True
                    signal.pidfd_send_signal(
                        candidate.pidfd, signal.SIGUSR1, None, 0
                    )
                    _wait_for_test_pidfd(candidate.pidfd)
                return result

            with mock.patch.object(
                CAPTURE.CaptureSession,
                "_wait_process",
                exit_between_phases,
            ):
                result = session.stop()
            assert exited_after_timeout
            assert result["state"] == "STOPPED"
            assert result["ownership_status"] == "PASS"
            assert result["packet_status"] == "ERROR"
            assert handle.process.returncode == 0
            assert handle.wait_receipt is not None
            assert handle.wait_receipt["pid"] == handle.process.pid
            assert session._slots["fabric"]["reaped"] is True
            assert session.stop() == result
            _assert_test_pidfd_consumed(handle.pidfd)
            outcomes["between_phases"] = handle.wait_receipt["returncode"]
        CAPTURE._TEST_FAULT = None

        with focused_session() as (session, _builder):
            CAPTURE._TEST_FAULT = "spawn-before-chassis-1"
            expect_error(CAPTURE.CaptureAmbiguous, session.start)
            handle = session._handles[0]
            positive_waits = 0

            def exit_at_final_deadline(
                owner: Any, candidate: Any, timeout: float
            ) -> int | None:
                nonlocal positive_waits
                if candidate is handle and timeout > 0:
                    positive_waits += 1
                    if positive_waits == len(phases):
                        _wait_for_test_pidfd(candidate.pidfd)
                        return None
                return original_wait(owner, candidate, timeout)

            with mock.patch.object(
                CAPTURE.CaptureSession,
                "_wait_process",
                exit_at_final_deadline,
            ):
                result = session.stop()
            assert positive_waits == len(phases)
            assert result["state"] == "STOPPED"
            assert result["ownership_status"] == "PASS"
            assert result["packet_status"] == "ERROR"
            assert handle.process.returncode == -signal.SIGKILL
            assert handle.wait_receipt is not None
            assert handle.wait_receipt["pid"] == handle.process.pid
            assert session._slots["fabric"]["reaped"] is True
            assert session.stop() == result
            _assert_test_pidfd_consumed(handle.pidfd)
            outcomes["final_deadline"] = handle.wait_receipt["returncode"]
        CAPTURE._TEST_FAULT = None
        return outcomes
    finally:
        CAPTURE._TEST_CHILD = original_child
        CAPTURE.STOP_PHASES = original_phases
        CAPTURE._TEST_FAULT = None


def foreign_pidfd_refusal_check() -> dict[str, Any]:
    """A rebound primary pidfd is rejected before its foreign status is consumed."""
    with focused_session() as (session, builder):
        CAPTURE._TEST_FAULT = "spawn-before-chassis-1"
        expect_error(CAPTURE.CaptureAmbiguous, session.start)
        handle = session._handles[0]
        assert handle.pidfd is not None and handle.pidfd_guard is not None
        foreign = subprocess.Popen(
            [sys.executable, "-c", "import os; os._exit(23)"],
            start_new_session=True,
        )
        foreign_pidfd = os.pidfd_open(foreign.pid, 0)
        try:
            _wait_for_test_pidfd(foreign_pidfd)
            os.dup2(foreign_pidfd, handle.pidfd)
            expect_error(
                CAPTURE.CaptureSecurityError,
                lambda: session._wait_process(handle, 0.0),
            )
            observed = os.waitid(
                os.P_PIDFD,
                foreign_pidfd,
                os.WEXITED | os.WNOWAIT | os.WNOHANG,
            )
            assert observed is not None and observed.si_pid == foreign.pid

            result = session.stop()
            assert result["state"] == "STOP_FAILED"
            assert result["ownership_status"] == "ERROR"
            assert result["packet_status"] == "ERROR"
            assert builder._unknown
            assert handle.process.returncode is None
            assert session._slots["fabric"]["pid"] == handle.process.pid
            assert session._slots["fabric"]["reaped"] is False
            assert session.stop() == result
            observed_again = os.waitid(
                os.P_PIDFD,
                foreign_pidfd,
                os.WEXITED | os.WNOWAIT | os.WNOHANG,
            )
            assert observed_again is not None
            assert observed_again.si_pid == foreign.pid
            return {
                "foreign_pid": foreign.pid,
                "original_pid": handle.process.pid,
                "foreign_waitable_after_refusal": True,
            }
        finally:
            os.dup2(handle.pidfd_guard, handle.pidfd)
            if handle.process.returncode is None:
                signal.pidfd_send_signal(handle.pidfd, signal.SIGTERM, None, 0)
                handle.process.wait(timeout=2.0)
            if foreign.returncode is None:
                assert foreign.wait(timeout=2.0) == 23
            os.close(foreign_pidfd)
            CAPTURE._TEST_FAULT = None


def focused_stderr_acquisition_accounting_check() -> dict[str, Any]:
    """A successful Popen remains accounted when stderr acquisition fails."""
    created: list[subprocess.Popen[bytes]] = []
    failed = False
    original_popen = CAPTURE.subprocess.Popen
    original_fstat = CAPTURE.os.fstat

    def tracked_popen(*args: Any, **kwargs: Any) -> subprocess.Popen[bytes]:
        process = original_popen(*args, **kwargs)
        created.append(process)
        return process

    def fail_original_stderr(descriptor: int) -> os.stat_result:
        nonlocal failed
        if created and not failed:
            receiver = created[-1].stderr
            if receiver is not None and descriptor == receiver.fileno():
                failed = True
                raise OSError("synthetic original stderr acquisition failure")
        return original_fstat(descriptor)

    with focused_session() as (session, builder):
        try:
            with mock.patch.object(
                CAPTURE.subprocess,
                "Popen",
                side_effect=tracked_popen,
            ), mock.patch.object(
                CAPTURE.os,
                "fstat",
                side_effect=fail_original_stderr,
            ):
                error = expect_error(CAPTURE.CaptureSecurityError, session.start)
            assert str(error) == "capture stderr acquisition failed"
            assert failed and len(created) == 1
            process = created[0]
            assert process.stderr is not None
            assert len(session._handles) == 1
            handle = session._handles[0]
            assert handle.process is process
            assert handle.stderr_receiver is process.stderr
            assert handle.stderr_descriptor is None
            assert handle.stderr_identity is None
            assert handle.pidfd is None and handle.pidfd_identity is None
            assert not handle.launch_proof_complete
            assert session._started_count == 1
            assert session._slots["fabric"]["pid"] == process.pid
            assert session._slots["fabric"]["reaped"] is False
            assert session._pcap_files["fabric"]["launched"] is True
            assert process.poll() is None
            assert builder._unknown and session._publication_unknown

            result = session.stop()
            assert result["status"] == "ERROR"
            assert result["state"] == "STOP_FAILED"
            assert result["ownership_status"] == "ERROR"
            assert result["packet_status"] == "ERROR"
            assert result["captures"] == []
            assert session._slots["fabric"]["pid"] == process.pid
            assert session._slots["fabric"]["reaped"] is False
            assert process.poll() is None
            assert session.stop() == result
            expect_error(
                CAPTURE.CaptureSecurityError,
                session._release_after_compensation,
            )
            assert not session._retention_started
            assert not session._retention_complete
            assert not session._released
            assert not builder.retention_events
            assert not (
                builder._config.evidence_path
                / CAPTURE.RETAINED_CAPTURE_DIRECTORY
            ).exists()
            return {
                "created_children": len(created),
                "accounted_handles": len(session._handles),
                "state": result["state"],
            }
        finally:
            if created:
                process = created[0]
                if process.returncode is None:
                    process.terminate()
                    process.wait(timeout=2.0)
                if process.stderr is not None and not process.stderr.closed:
                    process.stderr.close()


def focused_stderr_identity_checks() -> dict[str, Any]:
    """Reject changed stderr custody without losing safe pidfd stop/reap."""
    outcomes: dict[str, Any] = {}

    with focused_session() as (session, builder):
        CAPTURE._TEST_FAULT = "spawn-before-chassis-1"
        expect_error(CAPTURE.CaptureAmbiguous, session.start)
        CAPTURE._TEST_FAULT = None
        handle = session._handles[0]
        receiver = handle.stderr_receiver
        descriptor = handle.stderr_descriptor
        identity = handle.stderr_identity
        assert handle.process.stderr is receiver
        assert session._verify_stderr(handle) == descriptor
        guard = os.dup(descriptor)
        foreign_path = builder._config.evidence_path / "foreign-stderr-active"
        foreign = os.open(
            foreign_path,
            os.O_RDWR | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        payload = b"foreign stderr must remain unread\n"
        replacement = None
        try:
            os.write(foreign, payload)
            os.lseek(foreign, 0, os.SEEK_SET)
            replacement = os.fdopen(os.dup(foreign), "rb", buffering=0)
            handle.process.stderr = replacement
            expect_error(
                CAPTURE.CaptureSecurityError,
                lambda: session._verify_stderr(handle),
            )
            assert os.lseek(foreign, 0, os.SEEK_CUR) == 0
            handle.process.stderr = receiver
            replacement.close()
            replacement = None

            os.close(descriptor)
            expect_error(
                CAPTURE.CaptureSecurityError,
                lambda: session._verify_stderr(handle),
            )
            assert CAPTURE._fd_identity(os.fstat(guard)) == identity
            os.dup2(guard, descriptor)
            assert session._verify_stderr(handle) == descriptor

            os.dup2(foreign, descriptor)
            foreign_identity = CAPTURE._fd_identity(os.fstat(foreign))
            foreign_blocking = os.get_blocking(foreign)
            assert CAPTURE._fd_identity(os.fstat(descriptor)) == foreign_identity
            expect_error(
                CAPTURE.CaptureSecurityError,
                lambda: session._drain_stderr(handle),
            )
            assert CAPTURE._fd_identity(os.fstat(descriptor)) == foreign_identity
            assert CAPTURE._fd_identity(os.fstat(foreign)) == foreign_identity
            assert os.get_blocking(foreign) is foreign_blocking
            assert os.lseek(foreign, 0, os.SEEK_CUR) == 0
            assert os.pread(foreign, len(payload), 0) == payload

            stopped = session.stop()
            assert stopped["state"] == "STOPPED"
            assert stopped["ownership_status"] == "PASS"
            assert stopped["packet_status"] == "ERROR"
            assert handle.process.returncode is not None
            assert handle.wait_receipt is not None
            assert handle.wait_receipt["pid"] == handle.process.pid
            assert session._slots["fabric"]["reaped"] is True
            assert builder._unknown and session._publication_unknown
            assert CAPTURE._fd_identity(os.fstat(descriptor)) == foreign_identity
            assert os.lseek(foreign, 0, os.SEEK_CUR) == 0
            assert not (
                builder._config.evidence_path
                / CAPTURE.RETAINED_CAPTURE_DIRECTORY
            ).exists()
            outcomes["receiver_closed_drain_and_stop"] = "REFUSED_REAPED"
        finally:
            handle.process.stderr = receiver
            os.dup2(guard, descriptor)
            if replacement is not None:
                replacement.close()
            os.close(guard)
            os.close(foreign)
            CAPTURE._TEST_FAULT = None

    with focused_retention_session() as (session, builder):
        handle = session._handles[0]
        receiver = handle.stderr_receiver
        descriptor = handle.stderr_descriptor
        identity = handle.stderr_identity
        guard = os.dup(descriptor)
        foreign_path = builder._config.evidence_path / "foreign-stderr-release"
        foreign = os.open(
            foreign_path,
            os.O_RDWR | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        payload = b"foreign release descriptor must remain unread and open\n"
        expected = _retention_source_facts(session)
        try:
            os.write(foreign, payload)
            os.lseek(foreign, 0, os.SEEK_SET)
            os.dup2(foreign, descriptor)
            foreign_identity = CAPTURE._fd_identity(os.fstat(foreign))
            foreign_blocking = os.get_blocking(foreign)
            assert CAPTURE._fd_identity(os.fstat(descriptor)) == foreign_identity
            expect_error(
                CAPTURE.CaptureSecurityError,
                session._release_after_compensation,
            )
            assert builder._unknown and session._publication_unknown
            assert session._retention_unknown and not session._retention_started
            assert not session._retention_complete and not session._released
            assert session._retained_locations is None
            assert not builder.retention_events
            assert _retention_source_facts(session) == expected
            assert not (
                builder._config.evidence_path
                / CAPTURE.RETAINED_CAPTURE_DIRECTORY
            ).exists()
            assert CAPTURE._fd_identity(os.fstat(descriptor)) == foreign_identity
            assert CAPTURE._fd_identity(os.fstat(foreign)) == foreign_identity
            assert os.get_blocking(foreign) is foreign_blocking
            assert os.lseek(foreign, 0, os.SEEK_CUR) == 0
            assert os.pread(foreign, len(payload), 0) == payload
            stopped = session.stop()
            assert stopped["state"] == "STOPPED"
            assert stopped["ownership_status"] == "PASS"
            assert stopped["packet_status"] == "ERROR"
            assert handle.process.returncode is not None
            assert handle.wait_receipt is not None
            assert handle.wait_receipt["pid"] == handle.process.pid
            event_count = len(builder.retention_events)
            expect_error(
                CAPTURE.CaptureSecurityError,
                session._release_after_compensation,
            )
            assert len(builder.retention_events) == event_count == 0
            outcomes["final_release_rebind"] = "REFUSED_OPEN_NO_EFFECT"
        finally:
            handle.process.stderr = receiver
            os.dup2(guard, descriptor)
            assert CAPTURE._fd_identity(os.fstat(descriptor)) == identity
            os.close(guard)
            os.close(foreign)

    return outcomes


@contextlib.contextmanager
def focused_retention_session(*, zero_child: bool = False) -> Any:
    """Yield one genuinely stopped owned child behind the verified fake seam."""
    assert CAPTURE._TEST_RETENTION_BUILDER is None
    with focused_session() as (session, builder):
        try:
            if zero_child:
                with mock.patch.object(
                    CAPTURE.subprocess,
                    "Popen",
                    side_effect=OSError("synthetic Popen failure"),
                ):
                    expect_error(OSError, session.start)
            else:
                CAPTURE._TEST_FAULT = "spawn-before-chassis-1"
                expect_error(CAPTURE.CaptureAmbiguous, session.start)
            CAPTURE._TEST_FAULT = None
            stopped = session.stop()
            assert stopped["state"] == "STOPPED"
            assert stopped["ownership_status"] == "PASS"
            assert stopped["packet_status"] == "ERROR"
            assert len(session._handles) == (0 if zero_child else 1)
            if session._handles:
                assert session._handles[0].capture_id == "fabric"
            assert tuple(session._pcap_files) == ("fabric",)
            builder._state = "COMPENSATED"
            builder._final_absence = {
                "status": "PASS",
                "captures": len(session._handles),
            }
            builder._cleanup_result = {
                "status": "PASS",
                "state": "COMPENSATED",
                "final_absence": copy_dict(builder._final_absence),
            }
            CAPTURE._TEST_RETENTION_BUILDER = builder
            yield session, builder
        finally:
            CAPTURE._TEST_FAULT = None
            CAPTURE._TEST_RETENTION_BUILDER = None


def _retention_source_facts(session: Any) -> dict[str, dict[str, Any]]:
    parent = session._builder._config.evidence_path
    names = [
        capture_id + ".pcap"
        for capture_id in CAPTURE.APPLY.CAPTURE_POINT_IDS
        if capture_id in session._pcap_files
    ]
    names.append(CAPTURE.APPLY.CAPTURE_PID_NAME)
    result: dict[str, dict[str, Any]] = {}
    for name in names:
        path = parent / name
        raw = path.read_bytes()
        result[name] = {
            "identity": CAPTURE._retained_file_identity(path.lstat()),
            "sha256": hashlib.sha256(raw).hexdigest(),
            "raw": raw,
        }
    return result


def _assert_retention_success(
    session: Any,
    builder: Any,
    expected: dict[str, dict[str, Any]],
    *,
    packet_status: str,
) -> None:
    parent = builder._config.evidence_path
    retained = parent / CAPTURE.RETAINED_CAPTURE_DIRECTORY
    info = retained.lstat()
    assert info.st_uid == os.getuid()
    assert info.st_mode & 0o777 == 0o700
    assert len(builder.retention_events) == 2
    assert [record["event"] for record in builder.retention_events] == [
        "x05-capture-retention-intent",
        "x05-capture-retention-complete",
    ]
    assert [record["detail"]["status"] for record in builder.retention_events] == [
        "INTENT",
        "VERIFIED",
    ]
    assert all(
        item["destination_identity"] is None
        and item["source_state"] == "PRESENT"
        and item["destination_state"] == "ABSENT"
        for item in builder.retention_events[0]["detail"]["files"]
    )
    assert session._retention_complete and session._released
    assert session._packet_status == packet_status
    assert session._retained_locations is not None
    assert session._retained_locations["status"] == "VERIFIED"
    assert len(session._retained_locations["files"]) == len(expected)
    for name, facts in expected.items():
        source = parent / name
        destination = retained / name
        assert not source.exists() and not source.is_symlink()
        assert CAPTURE._retained_file_identity(destination.lstat()) == facts[
            "identity"
        ]
        raw = destination.read_bytes()
        assert raw == facts["raw"]
        assert hashlib.sha256(raw).hexdigest() == facts["sha256"]
    for capture_id in CAPTURE.APPLY.CAPTURE_POINT_IDS:
        assert not (parent / (capture_id + ".pcap")).exists()
    assert not (parent / CAPTURE.APPLY.CAPTURE_PID_NAME).exists()
    files = builder.retention_events[-1]["detail"]["files"]
    assert len(files) == len(expected)
    assert all(
        item["source_identity"] == item["destination_identity"]
        and item["sha256"] == expected[pathlib.Path(item["source_path"]).name][
            "sha256"
        ]
        for item in files
    )


def focused_retention_checks() -> dict[str, Any]:
    """Exercise retention at the genuine private finalization entrypoint."""
    outcomes: dict[str, Any] = {}

    with focused_retention_session() as (session, builder):
        expected = _retention_source_facts(session)
        retained = builder._config.evidence_path / CAPTURE.RETAINED_CAPTURE_DIRECTORY
        retained.mkdir(mode=0o700)
        expect_error(CAPTURE.CaptureSecurityError, session._release_after_compensation)
        assert not builder.retention_events
        assert not session._retention_started
        assert not builder._unknown
        assert all(
            (builder._config.evidence_path / name).is_file() for name in expected
        )
        retained.rmdir()
        released = session._release_after_compensation()
        assert released == {"status": "PASS", "released": True}
        _assert_retention_success(
            session, builder, expected, packet_status="ERROR"
        )
        outcomes["success_after_preexisting_refusal"] = len(expected)

    with focused_retention_session(zero_child=True) as (session, builder):
        expected = _retention_source_facts(session)
        assert set(expected) == {"fabric.pcap", CAPTURE.APPLY.CAPTURE_PID_NAME}
        assert expected["fabric.pcap"]["raw"] == b""
        released = session._release_after_compensation()
        assert released == {"status": "PASS", "released": True}
        _assert_retention_success(
            session, builder, expected, packet_status="ERROR"
        )
        outcomes["zero_child_creator_file"] = len(expected)

    for replaced in ("fabric.pcap", CAPTURE.APPLY.CAPTURE_PID_NAME):
        with focused_retention_session() as (session, builder):
            parent = builder._config.evidence_path
            source = parent / replaced
            original_raw = source.read_bytes()
            original_identity = CAPTURE._retained_file_identity(source.lstat())
            mutated = False
            original_fault = CAPTURE._fault

            def replace_after_intent(config: Any, stage: str) -> None:
                nonlocal mutated
                original_fault(config, stage)
                if stage == "retention-after-intent" and not mutated:
                    replacement = parent / (replaced + ".replacement")
                    descriptor = os.open(
                        replacement,
                        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                        0o600,
                    )
                    try:
                        os.write(descriptor, original_raw)
                        os.fsync(descriptor)
                    finally:
                        os.close(descriptor)
                    os.replace(replacement, source)
                    mutated = True

            with mock.patch.object(
                CAPTURE, "_fault", side_effect=replace_after_intent
            ):
                expect_error(
                    CAPTURE.CaptureSecurityError,
                    session._release_after_compensation,
                )
            assert mutated
            assert builder._unknown and session._retention_unknown
            assert len(builder.retention_events) == 1
            assert not (
                parent / CAPTURE.RETAINED_CAPTURE_DIRECTORY
            ).exists()
            assert source.read_bytes() == original_raw
            assert CAPTURE._retained_file_identity(source.lstat()) != original_identity
            assert session._retained_locations is not None
            item = next(
                item
                for item in session._retained_locations["files"]
                if pathlib.Path(item["source_path"]).name == replaced
            )
            assert item["location"] == "unknown"
            count = len(builder.retention_events)
            expect_error(
                CAPTURE.CaptureSecurityError,
                session._release_after_compensation,
            )
            assert len(builder.retention_events) == count
            outcomes["replaced_" + replaced] = "REFUSED"

    with focused_retention_session() as (session, builder):
        handle = session._handles[0]
        assert handle.pcap_guard is not None
        os.close(handle.pcap_fd)
        replacement = os.open("/dev/null", os.O_RDONLY)
        if replacement != handle.pcap_fd:
            os.dup2(replacement, handle.pcap_fd)
            os.close(replacement)
        foreign_identity = CAPTURE._fd_identity(os.fstat(handle.pcap_fd))
        expect_error(
            CAPTURE.CaptureSecurityError,
            session._release_after_compensation,
        )
        assert builder._unknown and session._retention_unknown
        assert not builder.retention_events
        assert CAPTURE._fd_identity(os.fstat(handle.pcap_fd)) == foreign_identity
        outcomes["rebound_pcap_fd"] = "REFUSED_OPEN"

    with focused_retention_session() as (session, builder):
        parent = builder._config.evidence_path
        retained = parent / CAPTURE.RETAINED_CAPTURE_DIRECTORY
        displaced = parent / "completed-captures-original"
        retargeted = False
        original_fault = CAPTURE._fault

        def retarget_after_creation(config: Any, stage: str) -> None:
            nonlocal retargeted
            original_fault(config, stage)
            if stage == "retention-after-directory-fsync" and not retargeted:
                retained.rename(displaced)
                retained.mkdir(mode=0o700)
                retargeted = True

        with mock.patch.object(
            CAPTURE, "_fault", side_effect=retarget_after_creation
        ):
            expect_error(
                CAPTURE.CaptureSecurityError,
                session._release_after_compensation,
            )
        assert retargeted
        assert builder._unknown and session._retention_unknown
        assert len(builder.retention_events) == 1
        assert not any(displaced.iterdir()) and not any(retained.iterdir())
        assert session._retained_locations is not None
        assert all(
            item["location"] == "source"
            for item in session._retained_locations["files"]
        )
        outcomes["retargeted_directory"] = "REFUSED"

    with focused_retention_session() as (session, builder):
        parent = builder._config.evidence_path
        CAPTURE._TEST_FAULT = "retention-after-rename-fabric"
        expect_error(CAPTURE.CaptureAmbiguous, session._release_after_compensation)
        CAPTURE._TEST_FAULT = None
        retained = parent / CAPTURE.RETAINED_CAPTURE_DIRECTORY
        assert not (parent / "fabric.pcap").exists()
        assert (retained / "fabric.pcap").is_file()
        assert (parent / CAPTURE.APPLY.CAPTURE_PID_NAME).is_file()
        assert builder._unknown and session._retention_unknown
        assert len(builder.retention_events) == 1
        locations = {
            item["id"]: item["location"]
            for item in session._retained_locations["files"]
        }
        assert locations == {"fabric": "retained", "capture-pid-journal": "source"}
        before = sorted((item.name, item.stat().st_ino) for item in retained.iterdir())
        expect_error(CAPTURE.CaptureSecurityError, session._release_after_compensation)
        assert sorted((item.name, item.stat().st_ino) for item in retained.iterdir()) == before
        outcomes["partial_rename"] = "UNKNOWN_NO_RETRY"

    for role in ("source", "destination"):
        with focused_retention_session() as (session, builder):
            original_fsync = CAPTURE.os.fsync
            parent_calls = 0
            destination_failed = False
            source_failed = False

            def fail_selected_fsync(descriptor: int) -> None:
                nonlocal parent_calls, destination_failed, source_failed
                if descriptor == session._retention_parent_fd:
                    parent_calls += 1
                    if role == "source" and parent_calls == 2:
                        source_failed = True
                        raise OSError("synthetic source parent fsync failure")
                if (
                    role == "destination"
                    and descriptor == session._retention_directory_fd
                    and not destination_failed
                ):
                    destination_failed = True
                    raise OSError("synthetic destination parent fsync failure")
                original_fsync(descriptor)

            with mock.patch.object(
                CAPTURE.os, "fsync", side_effect=fail_selected_fsync
            ):
                expect_error(OSError, session._release_after_compensation)
            assert source_failed is (role == "source")
            assert destination_failed is (role == "destination")
            parent = builder._config.evidence_path
            retained = parent / CAPTURE.RETAINED_CAPTURE_DIRECTORY
            assert not (parent / "fabric.pcap").exists()
            assert (retained / "fabric.pcap").is_file()
            assert (parent / CAPTURE.APPLY.CAPTURE_PID_NAME).is_file()
            assert builder._unknown and session._retention_unknown
            assert len(builder.retention_events) == 1
            outcomes[role + "_fsync"] = "UNKNOWN_NO_RETRY"

    with focused_retention_session() as (session, builder):
        expected = _retention_source_facts(session)
        builder.retention_event_failure = "x05-capture-retention-complete"
        expect_error(
            CAPTURE.CaptureAmbiguous,
            session._release_after_compensation,
        )
        assert builder._unknown and session._retention_unknown
        assert not session._retention_complete and not session._released
        assert len(builder.retention_events) == 1
        parent = builder._config.evidence_path
        retained = parent / CAPTURE.RETAINED_CAPTURE_DIRECTORY
        for name, facts in expected.items():
            assert not (parent / name).exists()
            destination = retained / name
            assert CAPTURE._retained_file_identity(destination.lstat()) == facts[
                "identity"
            ]
            assert destination.read_bytes() == facts["raw"]
        assert all(
            item["location"] == "retained"
            for item in session._retained_locations["files"]
        )
        for handle in session._handles:
            os.fstat(handle.pcap_fd)
            os.fstat(handle.pidfd)
        count = len(builder.retention_events)
        expect_error(CAPTURE.CaptureSecurityError, session._release_after_compensation)
        assert len(builder.retention_events) == count
        outcomes["completion_publication"] = "UNKNOWN_NO_RETRY"

    return outcomes


def process_group_negative_check() -> dict[str, Any]:
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        ready = root / "ready"
        parent_hit = root / "parent-hit"
        child_hit = root / "child-hit"
        child_code = (
            "import pathlib,signal,sys,time;"
            "path=pathlib.Path(sys.argv[1]);"
            "signal.signal(signal.SIGUSR1,lambda *_:path.write_text('hit'));"
            "signal.signal(signal.SIGTERM,lambda *_:sys.exit(0));"
            "time.sleep(30)"
        )
        parent_code = (
            "import json,pathlib,signal,subprocess,sys,time;"
            "ready=pathlib.Path(sys.argv[1]);parent_hit=pathlib.Path(sys.argv[2]);"
            "signal.signal(signal.SIGUSR1,lambda *_:parent_hit.write_text('hit'));"
            "child=subprocess.Popen([sys.executable,'-c',sys.argv[4],sys.argv[3]],"
            "start_new_session=True);"
            "ready.write_text(json.dumps({'pid':child.pid}));"
            "child.wait()"
        )
        parent = subprocess.Popen(
            [
                sys.executable,
                "-c",
                parent_code,
                str(ready),
                str(parent_hit),
                str(child_hit),
                child_code,
            ],
            start_new_session=True,
        )
        child_pid = None
        try:
            deadline = time.monotonic() + 3.0
            while time.monotonic() < deadline and not ready.exists():
                time.sleep(0.01)
            assert ready.exists()
            child_pid = json.loads(ready.read_text())["pid"]
            assert os.getpgid(parent.pid) == parent.pid
            assert os.getpgid(child_pid) == child_pid
            assert os.getsid(child_pid) == child_pid
            os.killpg(parent.pid, signal.SIGUSR1)
            deadline = time.monotonic() + 1.0
            while time.monotonic() < deadline and not parent_hit.exists():
                time.sleep(0.01)
            assert parent_hit.exists()
            time.sleep(0.05)
            assert not child_hit.exists()
            return {"parent_group_isolated": True}
        finally:
            if child_pid is not None:
                with contextlib.suppress(ProcessLookupError):
                    os.kill(child_pid, signal.SIGTERM)
            with contextlib.suppress(ProcessLookupError):
                parent.terminate()
            with contextlib.suppress(subprocess.TimeoutExpired):
                parent.wait(timeout=2.0)


def linux_creator_checks() -> dict[str, Any]:
    support = load(
        "x05_capture_builder_support", HERE / "x05-runtime-apply-selftest.py"
    )
    assert support.APPLY is CAPTURE.APPLY
    executable = pathlib.Path(os.path.realpath(sys.executable))
    assert CAPTURE.CAPTURE_LIFETIME_SECONDS == 900.0
    assert "time.monotonic() + 900.0" in CAPTURE._TEST_CHILD
    focused = {
        **focused_failure_checks(),
        **focused_readiness_checks(),
        "lifetime": focused_lifetime_checks(),
        "stop_reap": focused_stop_reap_checks(),
        "foreign_pidfd": foreign_pidfd_refusal_check(),
        "stderr_acquisition": focused_stderr_acquisition_accounting_check(),
        "stderr_identity": focused_stderr_identity_checks(),
        "retention": focused_retention_checks(),
        **process_group_negative_check(),
    }
    CAPTURE._TEST_TOOLCHAIN = {
        "tcpdump": executable,
        "nsenter": executable,
        "libpcap": pathlib.Path(CAPTURE.__file__).resolve(),
    }
    started = time.monotonic()
    builder = None
    capture = None
    drift = None
    original_ifindex = None
    result = None
    primary = None
    primary_traceback = None
    cleanup_errors: list[str] = []

    original_stop = CAPTURE._CAPTURE_SESSION_STOP
    original_release = CAPTURE._CAPTURE_SESSION_RELEASE
    original_capture_gate = CAPTURE.APPLY._RUNTIME_BUILDER_CAPTURE_STOP
    original_compensate = CAPTURE.APPLY.RuntimeBuilder.compensate
    original_verify_final_absence = CAPTURE.APPLY.RuntimeBuilder.verify_final_absence

    def remember_cleanup_error(label: str, error: BaseException) -> None:
        cleanup_errors.append(f"{label}: {type(error).__name__}: {error}")

    def cleanup_after_failure() -> None:
        nonlocal capture

        if builder is None:
            return
        candidate = capture
        if candidate is None:
            candidate = getattr(builder, "_capture_session", None)
        if candidate is None:
            return

        stop_result = None
        try:
            assert type(candidate) is CAPTURE.CaptureSession
            assert candidate._builder is builder
            assert builder._capture_session is candidate
            assert CAPTURE.CaptureSession.stop is original_stop
            assert "stop" not in candidate.__dict__
            if candidate._state in {"STARTING", "STARTED"}:
                stop_result = original_stop(candidate)
            elif candidate._state == "STOPPED":
                stop_result = candidate._stop_result
            else:
                raise AssertionError(
                    f"capture cleanup is unsafe from {candidate._state!r}"
                )
            assert isinstance(stop_result, dict)
            assert stop_result["state"] == "STOPPED"
            assert stop_result["ownership_status"] == "PASS"
        except BaseException as error:
            remember_cleanup_error("owned capture stop", error)

        restoration_ok = True
        if drift is not None and original_ifindex is not None:
            try:
                drift.ifindex = original_ifindex
            except BaseException as error:
                restoration_ok = False
                remember_cleanup_error("ifindex restoration", error)

        safe_to_compensate = (
            isinstance(stop_result, dict)
            and stop_result.get("state") == "STOPPED"
            and stop_result.get("ownership_status") == "PASS"
            and restoration_ok
            and builder._state in {"BUILT", "COMPENSATED"}
            and not builder._unknown
        )
        if not safe_to_compensate:
            return

        try:
            assert type(builder) is CAPTURE.APPLY.RuntimeBuilder
            assert (
                CAPTURE.APPLY._RUNTIME_BUILDER_CAPTURE_STOP
                is original_capture_gate
            )
            assert CAPTURE.APPLY.RuntimeBuilder.compensate is original_compensate
            assert (
                CAPTURE.APPLY.RuntimeBuilder.verify_final_absence
                is original_verify_final_absence
            )
            assert "compensate" not in builder.__dict__
            assert "verify_final_absence" not in builder.__dict__
            if builder._state == "BUILT":
                authority = original_capture_gate(builder)
                assert authority["ownership_status"] == "PASS"
                cleanup = original_compensate(builder)
                assert cleanup["status"] == "PASS"
            absence = original_verify_final_absence(builder)
            assert absence["status"] == "PASS"
            assert CAPTURE.CaptureSession._release_after_compensation is original_release
            assert "_release_after_compensation" not in candidate.__dict__
            if not candidate._released:
                released = original_release(candidate)
                assert released == {"status": "PASS", "released": True}
        except BaseException as error:
            remember_cleanup_error("original builder compensation", error)

    try:
        try:
            with support.admitted_builder() as (builder, runner, _session, _prepared):
                try:
                    built = builder.build()
                    assert built["status"] == "PASS"
                    capture = CAPTURE.CaptureSession.from_builder(builder)
                    assert builder._capture_session is capture
                    assert len(capture._contract["points"]) == 5
                    assert (
                        sum(
                            len(point["interfaces"])
                            for point in capture._contract["points"]
                        )
                        == 11
                    )
                    assert len(capture._contract["sources"]) == 4
                    started_result = capture.start()
                    assert started_result["state"] == "STARTED5ready"
                    assert (
                        started_result["started_count"]
                        == started_result["ready_count"]
                        == 5
                    )
                    originals = [
                        (
                            handle.process,
                            handle.pidfd,
                            handle.pidfd_guard,
                            handle.pcap_fd,
                            handle.pcap_guard,
                        )
                        for handle in capture._handles
                    ]
                    first = capture.health()
                    second = capture.health()
                    assert first["status"] == second["status"] == "PASS"
                    assert originals == [
                        (
                            handle.process,
                            handle.pidfd,
                            handle.pidfd_guard,
                            handle.pcap_fd,
                            handle.pcap_guard,
                        )
                        for handle in capture._handles
                    ]
                    assert all(
                        handle.session_id == handle.process.pid
                        and handle.process_group_id == handle.process.pid
                        and handle.parent_process_group_id
                        != handle.process_group_id
                        for handle in capture._handles
                    )
                    assert all(
                        CAPTURE._namespace_identity(
                            pathlib.Path(f"/proc/{handle.process.pid}/ns/mnt")
                        )
                        == capture._execution_mntns_identity
                        for handle in capture._handles
                    )
                    child_mount_path = pathlib.Path(
                        f"/proc/{capture._handles[0].process.pid}/ns/mnt"
                    )
                    original_namespace_identity = CAPTURE._namespace_identity

                    def drift_child_mount(path: pathlib.Path) -> tuple[int, int]:
                        value = original_namespace_identity(path)
                        if path == child_mount_path:
                            return (value[0], value[1] + 1)
                        return value

                    with mock.patch.object(
                        CAPTURE,
                        "_namespace_identity",
                        side_effect=drift_child_mount,
                    ):
                        expect_error(CAPTURE.CaptureSecurityError, capture.health)
                    target = builder._targets["ovn-chassis-1"]
                    original_target_mount = target.mntns_inode
                    try:
                        target.mntns_inode += 1
                        expect_error(
                            CAPTURE.APPLY.SecurityError,
                            builder._verify_capture_contract_current,
                        )
                    finally:
                        target.mntns_inode = original_target_mount
                    drift = runner.links["mgc-x05-peer-2"]["vxlan-x05-pr"]
                    original_ifindex = drift.ifindex
                    drift.ifindex += 5000
                    expect_error(
                        CAPTURE.APPLY.SecurityError,
                        builder._verify_complete_runtime,
                    )
                    drift.ifindex = original_ifindex
                    stopped = capture.stop()
                    assert stopped["ownership_status"] == "PASS"
                    assert stopped["packet_status"] == "PASS"
                    assert stopped["state"] == "STOPPED"
                    owned = capture._read_owned_pcaps()
                    assert tuple(owned) == CAPTURE.APPLY.CAPTURE_POINT_IDS
                    assert all(
                        value["format"]["linktype"] == 276
                        for value in owned.values()
                    )
                    pid_path = pathlib.Path(capture._contract["pid_journal"]["path"])
                    original_pid_raw = pid_path.read_bytes()
                    forged_value = json.loads(original_pid_raw)
                    forged_value["captures"][0]["reaped_at_ns"] += 1
                    forged_pid_raw = CAPTURE._canonical(forged_value)
                    CAPTURE.APPLY._atomic_replace(
                        pid_path,
                        expected=original_pid_raw,
                        payload=forged_pid_raw,
                        uid=builder._config.required_uid,
                    )
                    detached = builder._read_stopped_capture_observation()
                    assert detached["state"] == "STOPPED"
                    effects_before_replacement = len(runner.effect_calls)
                    nb_before_replacement = runner.nb_effects
                    marker_before_replacement = copy_dict(
                        builder._capture_last_completed_marker
                    )
                    expect_error(
                        CAPTURE.APPLY.SecurityError,
                        builder.compensate,
                    )
                    assert len(runner.effect_calls) == effects_before_replacement
                    assert runner.nb_effects == nb_before_replacement
                    assert builder._state == "BUILT" and not builder._unknown
                    assert (
                        builder._capture_last_completed_marker
                        == marker_before_replacement
                    )
                    CAPTURE.APPLY._atomic_replace(
                        pid_path,
                        expected=forged_pid_raw,
                        payload=original_pid_raw,
                        uid=builder._config.required_uid,
                    )
                    authority = builder._verify_stopped_captures()
                    assert authority["ownership_status"] == "PASS"
                    assert authority["packet_status"] == "PASS"
                    cleanup = builder.compensate()
                    assert cleanup["status"] == "PASS"
                    assert builder.verify_final_absence()["status"] == "PASS"
                    retained_expected = _retention_source_facts(capture)
                    event_count_before_retention = builder._prepared._event_count
                    released = capture._release_after_compensation()
                    assert released == {"status": "PASS", "released": True}
                    assert (
                        builder._prepared._event_count
                        == event_count_before_retention + 2
                    )
                    retained_directory = (
                        builder._config.evidence_path
                        / CAPTURE.RETAINED_CAPTURE_DIRECTORY
                    )
                    retained_info = retained_directory.lstat()
                    assert retained_info.st_uid == builder._config.required_uid
                    assert stat.S_IMODE(retained_info.st_mode) == 0o700
                    assert capture._retained_locations is not None
                    assert capture._retained_locations["status"] == "VERIFIED"
                    assert len(capture._retained_locations["files"]) == 6
                    for name, facts in retained_expected.items():
                        active = builder._config.evidence_path / name
                        retained_path = retained_directory / name
                        assert not active.exists() and not active.is_symlink()
                        assert (
                            CAPTURE._retained_file_identity(retained_path.lstat())
                            == facts["identity"]
                        )
                        assert retained_path.read_bytes() == facts["raw"]
                    assert all(
                        not (
                            builder._config.evidence_path
                            / (capture_id + ".pcap")
                        ).exists()
                        for capture_id in CAPTURE.APPLY.CAPTURE_POINT_IDS
                    )
                    assert not pid_path.exists() and not pid_path.is_symlink()
                    result = {
                        "elapsed_seconds": round(time.monotonic() - started, 3),
                        "children": len(originals),
                        "marker_sequence": capture._last_marker["sequence"],
                        "runtime_calls": len(runner.runtime_calls),
                        "focused": focused,
                    }
                except BaseException as error:
                    primary = error
                    primary_traceback = error.__traceback__
                    cleanup_after_failure()
        except BaseException as error:
            if primary is None:
                raise
            if error is not primary:
                remember_cleanup_error("fixture finalizer", error)

        if primary is not None:
            for cleanup_error in cleanup_errors:
                primary.add_note(cleanup_error)
            raise primary.with_traceback(primary_traceback)
        assert result is not None
        return result
    finally:
        CAPTURE._TEST_TOOLCHAIN = None
        CAPTURE._TEST_FAULT = None


def main() -> int:
    static = static_checks()
    corpus = corpus_checks()
    if sys.platform != "linux" or not hasattr(os, "pidfd_open"):
        print(
            "X05 capture offline PASS; real Linux handles NOT_RUN: "
            + json.dumps(
                {"static": static, "corpus": corpus},
                sort_keys=True,
                separators=(",", ":"),
            )
        )
        return 77
    linux = linux_creator_checks()
    print(
        "X05 capture creator PASS: "
        + json.dumps(
            {"static": static, "corpus": corpus, "linux": linux},
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
