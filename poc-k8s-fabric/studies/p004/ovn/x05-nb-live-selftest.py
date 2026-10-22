#!/usr/bin/env python3
"""Local fake-runner checks for the X05 NB adapter.

No live helper mode, Docker, SSH, OVSDB, or production marker path is used by
this file.  The runner returns bounded synthetic JSON, and the compatibility
check invokes only the existing helpers' local fixture modes.
"""

from __future__ import annotations

import contextlib
import copy
import dataclasses
import importlib.util
import fcntl
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import threading
from collections.abc import Callable, Iterator
from unittest import mock


HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("x05_nb_live", HERE / "x05-nb-live.py")
assert SPEC and SPEC.loader
LIVE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = LIVE
SPEC.loader.exec_module(LIVE)

PRODUCER_SPEC = importlib.util.spec_from_file_location(
    "x05_runtime_live_selftest_support", HERE / "x05-runtime-live-selftest.py"
)
assert PRODUCER_SPEC and PRODUCER_SPEC.loader
PRODUCER_TEST = importlib.util.module_from_spec(PRODUCER_SPEC)
sys.modules[PRODUCER_SPEC.name] = PRODUCER_TEST
PRODUCER_SPEC.loader.exec_module(PRODUCER_TEST)
PRODUCER_TEST.LIVE = LIVE.RUNTIME
LIVE.RUNTIME.load_local_test_modules()


RUN_HEX = "a1b2c3"
OWNER = "labctl-x05-a1b2c3"
FINGERPRINT = {
    "ls_uuid": "00000000-0000-4000-8000-000000000001",
    "lr_uuid": "00000000-0000-4000-8000-000000000002",
    "lrp_uuid": "00000000-0000-4000-8000-000000000003",
    "ls_ports": ["00000000-0000-4000-8000-000000000004"],
    "lr_ports": ["00000000-0000-4000-8000-000000000003"],
}


class FakeLock:
    def validate(self) -> None:
        return None


class FakeRunner:
    def __init__(
        self,
        *,
        timeout_on_ovsdb: bool = False,
        built_fail: bool = False,
        preinverse_fail: bool = False,
    ) -> None:
        self.calls: list[tuple[str, ...]] = []
        self.timeout_on_ovsdb = timeout_on_ovsdb
        self.built_fail = built_fail
        self.preinverse_fail = preinverse_fail
        self.snapshot_calls = 0

    def run(
        self, command: list[str] | tuple[str, ...], timeout: float
    ) -> LIVE.CommandResult:
        del timeout
        argv = tuple(str(item) for item in command)
        self.calls.append(argv)
        joined = " ".join(argv)
        if "ovsdb-client" in argv:
            if self.timeout_on_ovsdb:
                raise TimeoutError("synthetic OVSDB timeout")
            return LIVE.CommandResult(0, "[{}]\n")
        if "x05-nb-preflight.sh" in joined:
            return LIVE.CommandResult(
                0,
                json.dumps(
                    {
                        "schema": "p004-x05-nb-preflight-v1",
                        "status": "PASS",
                        "planned_rows_absent": 34,
                        "owner_residue": 0,
                        "nb_cfg": 10,
                        "a_fingerprint": FINGERPRINT,
                    }
                )
                + "\n",
            )
        if "x05-nb-full-snapshot.sh" in joined:
            self.snapshot_calls += 1
            returncode = 7 if self.preinverse_fail and self.snapshot_calls == 2 else 0
            return (
                LIVE.CommandResult(
                    0,
                    json.dumps(
                        {
                            "schema": "p004-x05-nb-full-snapshot-v1",
                            "capture_started_ns": 10,
                            "capture_finished_ns": 20,
                            "nb_cfg_before": 10,
                            "nb_cfg_after": 10,
                            "tables": {},
                        }
                    )
                    + "\n",
                )
                if returncode == 0
                else LIVE.CommandResult(
                    returncode,
                    json.dumps(
                        {
                            "schema": "p004-x05-nb-full-snapshot-v1",
                            "capture_started_ns": 10,
                            "capture_finished_ns": 20,
                            "nb_cfg_before": 10,
                            "nb_cfg_after": 10,
                            "tables": {},
                        }
                    )
                    + "\n",
                    "synthetic preinverse failure\n",
                )
            )
        if "--check-result" in argv:
            return LIVE.CommandResult(
                0,
                json.dumps(
                    {
                        "schema": "p004-x05-nb-tx-result-v1",
                        "status": "PASS",
                        "owner": OWNER,
                        "run_hex": RUN_HEX,
                        "a_fingerprint": FINGERPRINT,
                        "inserted": {},
                        "a_ls_attach_count": 1,
                    }
                )
                + "\n",
            )
        if "--check-inverse-result" in argv:
            return LIVE.CommandResult(
                0,
                json.dumps(
                    {
                        "schema": "p004-x05-nb-inverse-result-v1",
                        "status": "PASS",
                        "owner": OWNER,
                        "run_hex": RUN_HEX,
                        "a_fingerprint": FINGERPRINT,
                        "inserted": {},
                        "a_ls_detach_count": 1,
                        "deleted_owned_rows": 34,
                    }
                )
                + "\n",
            )
        if "x05-nb-postflight.py" in joined:
            mode = "built" if "--built" in argv else "clean"
            status = "FAIL" if self.built_fail and mode == "built" else "PASS"
            return LIVE.CommandResult(
                0,
                json.dumps(
                    {
                        "schema": "p004-x05-nb-postflight-v1",
                        "status": status,
                        "mode": mode,
                        "owner": OWNER,
                        "run_hex": RUN_HEX,
                    }
                )
                + "\n",
            )
        if "x05-nb-tx.py" in joined:
            return LIVE.CommandResult(0, '["OVN_Northbound",{}]\n')
        raise AssertionError("unexpected fake command: " + joined)


class ProducerNBFakeRunner(PRODUCER_TEST.FakeRunner):
    """Extend the genuine admission fake with the fixed NB command surface."""

    def __init__(self, config: object) -> None:
        super().__init__(config)
        self.nb_calls: list[tuple[str, ...]] = []
        self.nb_effects = 0
        self.nb_snapshot_calls = 0
        self.nb_result_mode = "ok"
        self.after_nb_command = None
        self.inspect_mutator: Callable[[dict[str, object]], None] | None = None

    def _nb_result(
        self,
        command: tuple[str, ...],
        stdout: bytes,
        *,
        returncode: int = 0,
        stderr: bytes = b"",
    ):
        if self.after_nb_command is not None:
            self.after_nb_command(command)
        return self.result(command, stdout, returncode, stderr)

    def run(
        self,
        argv,
        *,
        env,
        timeout,
        pass_fds=(),
        max_output_bytes=LIVE.RUNTIME.MAX_OUTPUT,
    ):
        command = tuple(argv)
        joined = " ".join(command)
        if command[:3] == ("docker", "container", "inspect"):
            result = super().run(
                command,
                env=env,
                timeout=timeout,
                pass_fds=pass_fds,
                max_output_bytes=max_output_bytes,
            )
            payload = json.loads(result.stdout)
            payload[0]["Name"] = "/" + command[3]
            if self.inspect_mutator is not None:
                self.inspect_mutator(payload[0])
            return self.result(
                command,
                json.dumps(payload, sort_keys=True, separators=(",", ":")).encode(),
                result.returncode,
                result.stderr,
            )
        is_nb_helper = any(
            name in joined
            for name in (
                "x05-nb-preflight.sh",
                "x05-nb-full-snapshot.sh",
                "x05-nb-tx.py",
                "x05-nb-postflight.py",
            )
        )
        is_nb_effect = "ovsdb-client" in command
        if not is_nb_helper and not is_nb_effect:
            return super().run(
                command,
                env=env,
                timeout=timeout,
                pass_fds=pass_fds,
                max_output_bytes=max_output_bytes,
            )

        assert env == LIVE.RUNTIME.BASE_ENV
        assert timeout == self.config.command_timeout
        assert tuple(pass_fds) == ((LIVE.LOCK_FD,) if is_nb_effect else ())
        assert max_output_bytes == LIVE.RUNTIME.MAX_OUTPUT
        self.nb_calls.append(command)

        if is_nb_effect:
            self.nb_effects += 1
            events = [
                json.loads(line)
                for line in self.config.event_path.read_text(
                    encoding="utf-8"
                ).splitlines()
            ]
            assert events[-1]["event"] == "x05-nb-intent"
            assert command[2] == self.ids[LIVE.CENTRAL_CONTAINER]
            mode = self.nb_result_mode
            if mode == "timeout":
                raise LIVE.RUNTIME.CommandTimeout("synthetic NB timeout")
            if mode == "incomplete":
                return object()
            if mode == "invalid-fields":
                return LIVE.RUNTIME.CommandResult(
                    ("wrong-command",), 0, b"[{}]\n", b"", 0.1
                )
            if mode == "invalid-utf8":
                return self._nb_result(command, b"\xff")
            if mode == "stderr":
                return self._nb_result(command, b"[{}]\n", stderr=b"warning\n")
            if mode == "invalid-stderr":
                return self._nb_result(command, b"[{}]\n", stderr=b"\xff")
            if mode == "invalid-both-streams":
                return self._nb_result(command, b"\xfe", stderr=b"\xff")
            if mode == "nonzero":
                return self._nb_result(command, b"[{}]\n", returncode=9)
            if mode == "malformed":
                return self._nb_result(command, b"not-json\n")
            if mode == "oversize":
                return self._nb_result(
                    command,
                    b" " * LIVE.RUNTIME.MAX_OUTPUT,
                    stderr=b"x",
                )
            return self._nb_result(command, b"[{}]\n")

        if "x05-nb-preflight.sh" in joined:
            return self._nb_result(
                command,
                json.dumps(
                    {
                        "schema": "p004-x05-nb-preflight-v1",
                        "status": "PASS",
                        "planned_rows_absent": 34,
                        "owner_residue": 0,
                        "nb_cfg": 10,
                        "a_fingerprint": FINGERPRINT,
                    }
                ).encode()
                + b"\n",
            )
        if "x05-nb-full-snapshot.sh" in joined:
            self.nb_snapshot_calls += 1
            return self._nb_result(
                command,
                json.dumps(
                    {
                        "schema": "p004-x05-nb-full-snapshot-v1",
                        "capture_started_ns": self.nb_snapshot_calls * 10,
                        "capture_finished_ns": self.nb_snapshot_calls * 10 + 5,
                        "nb_cfg_before": 10,
                        "nb_cfg_after": 10,
                        "tables": {},
                    }
                ).encode()
                + b"\n",
            )
        if "--check-result" in command:
            return self._nb_result(
                command,
                json.dumps(
                    {
                        "schema": "p004-x05-nb-tx-result-v1",
                        "status": "PASS",
                        "owner": self.config.owner,
                        "run_hex": self.config.run_hex,
                        "a_fingerprint": FINGERPRINT,
                        "inserted": {},
                        "a_ls_attach_count": 1,
                    }
                ).encode()
                + b"\n",
            )
        if "--check-inverse-result" in command:
            return self._nb_result(
                command,
                json.dumps(
                    {
                        "schema": "p004-x05-nb-inverse-result-v1",
                        "status": "PASS",
                        "owner": self.config.owner,
                        "run_hex": self.config.run_hex,
                        "a_fingerprint": FINGERPRINT,
                        "inserted": {},
                        "a_ls_detach_count": 1,
                        "deleted_owned_rows": 34,
                    }
                ).encode()
                + b"\n",
            )
        if "x05-nb-postflight.py" in joined:
            return self._nb_result(
                command,
                json.dumps(
                    {
                        "schema": "p004-x05-nb-postflight-v1",
                        "status": "PASS",
                        "mode": "built" if "--built" in command else "clean",
                        "owner": self.config.owner,
                        "run_hex": self.config.run_hex,
                    }
                ).encode()
                + b"\n",
            )
        if "x05-nb-tx.py" in joined:
            return self._nb_result(command, b'["OVN_Northbound",{}]\n')
        raise AssertionError("unexpected producer NB command: " + joined)


def _write_marker(path: pathlib.Path) -> None:
    path.write_text("token=" + OWNER + "\n", encoding="utf-8")
    path.chmod(0o600)


def _expect_error(
    expected: type[BaseException], action: Callable[[], object], label: str
) -> BaseException:
    try:
        action()
    except expected as exc:
        return exc
    raise AssertionError(label + " did not fail with " + expected.__name__)


def _override_attribute(owner: object, name: str, value: object) -> Callable[[], None]:
    attributes = vars(owner)
    existed = name in attributes
    previous = attributes.get(name)
    setattr(owner, name, value)

    def restore() -> None:
        if existed:
            setattr(owner, name, previous)
        else:
            delattr(owner, name)

    return restore


def _install_authority_substitution(
    case: str,
    session: object,
    runner: ProducerNBFakeRunner,
    config: object,
    *,
    obvious: bool = False,
) -> Callable[[], None]:
    if case == "config-object":
        return _override_attribute(session, "config", dataclasses.replace(config))
    if case == "runner-object":
        replacement = LIVE.RUNTIME._IncidentTrackingRunner(session, runner)
        return _override_attribute(session, "runner", replacement)
    if case == "runner-call":
        return _override_attribute(
            session.runner,
            "run",
            lambda *args, **kwargs: (_ for _ in ()).throw(
                AssertionError("replacement runner call must stay unreachable")
            ),
        )
    if case == "mutex":
        if obvious:
            class NoopMutex:
                def __enter__(self):
                    return self

                def __exit__(self, exc_type, exc, traceback):
                    return False

            return _override_attribute(session, "_consume_lock", NoopMutex())
        return _override_attribute(
            session, "_consume_lock", LIVE.RUNTIME.threading.RLock()
        )
    if case == "eventlog-object":
        replacement = LIVE.RUNTIME.DurableEventLog(
            config.event_path, uid=config.required_uid
        )
        return _override_attribute(session, "events", replacement)
    if case == "event-append":
        return _override_attribute(
            session.events,
            "append",
            lambda *args, **kwargs: {"suppressed": True},
        )
    if case == "event-verify":
        return _override_attribute(
            session.events,
            "verify",
            lambda: {
                "count": session.events.count,
                "head_sha256": session.events.head,
                "file_sha256": "0" * 64,
            },
        )
    if case == "event-path":
        replacement = type(session.events.path)(str(session.events.path))
        assert replacement is not session.events.path
        return _override_attribute(session.events, "path", replacement)
    if case == "event-uid":
        return _override_attribute(session.events, "uid", config.required_uid + 1)
    if case == "event-identity":
        identity = session.events._identity
        assert identity is not None
        return _override_attribute(
            session.events, "_identity", (identity[0], identity[1] + 1)
        )
    if case == "publisher":
        return _override_attribute(
            session,
            "record_execution_event",
            lambda *args, **kwargs: {"suppressed": True},
        )
    if case == "verifier":
        return _override_attribute(session, "verify_execution", lambda prepared: None)
    if case == "context":
        return _override_attribute(session, "execution_context", lambda prepared: {})
    if case == "delegate-object":
        replacement = object() if obvious else ProducerNBFakeRunner(config)
        return _override_attribute(session.runner, "_delegate", replacement)
    if case == "delegate-call":
        return _override_attribute(
            runner,
            "run",
            lambda *args, **kwargs: (_ for _ in ()).throw(
                AssertionError("replacement delegate call must stay unreachable")
            ),
        )
    if case == "collector-object":
        replacement = (
            object()
            if obvious
            else LIVE.RUNTIME.LiveCollector(config, session.runner)
        )
        return _override_attribute(session, "collector", replacement)
    if case == "collector-config":
        return _override_attribute(
            session.collector, "config", dataclasses.replace(config)
        )
    if case == "collector-runner":
        replacement = LIVE.RUNTIME._IncidentTrackingRunner(session, runner)
        return _override_attribute(session.collector, "runner", replacement)
    if case == "origin-guard":
        return _override_attribute(
            session,
            "_assert_origin_bindings_locked",
            lambda *args, **kwargs: (_ for _ in ()).throw(
                AssertionError("replacement origin guard must stay unreachable")
            ),
        )
    if case == "collector-run":
        return _override_attribute(
            session.collector,
            "_run",
            lambda *args, **kwargs: (_ for _ in ()).throw(
                AssertionError("replacement collector helper must stay unreachable")
            ),
        )
    raise AssertionError("unknown authority substitution: " + case)


def _replace_same_bytes(path: pathlib.Path) -> bytes:
    payload = path.read_bytes()
    mode = path.stat().st_mode & 0o777
    replacement = path.with_name("." + path.name + ".aba")
    replacement.write_bytes(payload)
    replacement.chmod(mode)
    os.replace(replacement, path)
    return payload


def _paths(root: pathlib.Path) -> LIVE.RuntimePaths:
    root = root.resolve()
    helper_dir = root / "helpers"
    helper_dir.mkdir(mode=0o700)
    for name in (
        "x05-nb-preflight.sh",
        "x05-nb-full-snapshot.sh",
        "x05-nb-tx.py",
        "x05-nb-postflight.py",
    ):
        (helper_dir / name).write_text("# fake\n", encoding="utf-8")
    marker_parent = root / "marker"
    marker_parent.mkdir(mode=0o700)
    marker = marker_parent / "active"
    _write_marker(marker)
    lock = root / "lock"
    lock.write_text("", encoding="utf-8")
    return LIVE.RuntimePaths(
        helper_dir=helper_dir,
        marker=marker,
        lock=lock,
        central_container=LIVE.CENTRAL_CONTAINER,
        nb_socket=LIVE.NB_SOCKET,
    )


def _adapter(
    root: pathlib.Path, runner: FakeRunner
) -> tuple[LIVE.NBAdapter, pathlib.Path]:
    root = root.resolve()
    evidence = root / "evidence"
    evidence.mkdir(mode=0o700)
    paths = _paths(root)
    return (
        LIVE.NBAdapter(
            run_hex=RUN_HEX,
            evidence_dir=evidence,
            paths=paths,
            policy=LIVE.SecurityPolicy(
                require_root=False, require_helper_provenance=False
            ),
            runner=runner,
            lock_validator=FakeLock(),
            _test_enable_live=True,
        ),
        evidence,
    )


def _producer_bundle(root: pathlib.Path) -> pathlib.Path:
    bundle = root / "bundle"
    ovn = bundle / "studies" / "p004" / "ovn"
    ovn.mkdir(parents=True)
    for name in (
        *LIVE.HELPER_DIGESTS,
        "x05-nb-live.py",
        "frr-gw1.conf",
        "frr-gw2.conf",
    ):
        shutil.copy2(HERE / name, ovn / name)
    return bundle


def _write_producer_marker(config: object) -> None:
    config.x05_marker_path.parent.mkdir(parents=True, mode=0o700)
    config.x05_marker_path.parent.chmod(0o700)
    config.x05_marker_path.write_text(
        "token="
        + config.owner
        + "\nowner="
        + config.owner
        + "\nrun_hex="
        + config.run_hex
        + "\nstate=INTENT\n",
        encoding="utf-8",
    )
    config.x05_marker_path.chmod(0o600)


def _synthetic_lock_fdinfo(descriptor: int) -> bytes:
    info = os.fstat(descriptor)
    flags = os.O_RDWR
    if not os.get_inheritable(descriptor):
        flags |= os.O_CLOEXEC
    return PRODUCER_TEST.lock_fdinfo_literal(
        flags="0" + format(flags, "o"),
        pid=str(os.getpid()),
        major=f"{os.major(info.st_dev):02x}",
        minor=f"{os.minor(info.st_dev):02x}",
        inode=str(info.st_ino),
    )


@contextlib.contextmanager
def _producer_admission(
    *, consume: bool = True
) -> Iterator[tuple[object, object, ProducerNBFakeRunner, object]]:
    with tempfile.TemporaryDirectory(
        prefix="x05-nb-producer-",
        dir=pathlib.Path(tempfile.gettempdir()).resolve(),
    ) as temporary:
        root = pathlib.Path(temporary)
        config = PRODUCER_TEST.make_config(root)
        object.__setattr__(config, "bundle_root", _producer_bundle(root))
        runner = ProducerNBFakeRunner(config)
        session = LIVE.RUNTIME.AdmissionSession(config, runner)
        fdinfo = (
            contextlib.nullcontext()
            if sys.platform == "linux"
            else mock.patch.object(
                LIVE.RUNTIME,
                "_read_lock_fdinfo_bytes",
                side_effect=_synthetic_lock_fdinfo,
            )
        )
        with fdinfo:
            session.__enter__()
            try:
                prepared = session.admit()
                if consume:
                    session.consume(prepared)
                    _write_producer_marker(config)
                yield session, prepared, runner, config
            finally:
                with contextlib.suppress(FileNotFoundError):
                    config.x05_marker_path.unlink()
                runner.x05_name_present = False
                if not session._closed:
                    try:
                        session.close()
                    except LIVE.RUNTIME.AdmissionIncident:
                        if not (
                            session._retained_descriptor
                            or session._lock_authority_lost
                            or session._execution_failure is not None
                        ):
                            raise
                        PRODUCER_TEST.close_retained_test_descriptors(session)


@contextlib.contextmanager
def _producer_adapter() -> Iterator[
    tuple[object, object, LIVE.NBAdapter, ProducerNBFakeRunner, object]
]:
    with _producer_admission() as (session, prepared, runner, config):
        adapter = LIVE.NBAdapter.from_admission(prepared)
        yield session, prepared, adapter, runner, config


@contextlib.contextmanager
def _central_inspect_override(
    runner: ProducerNBFakeRunner,
    mutate: Callable[[dict[str, object]], None],
) -> Iterator[None]:
    original = runner.inspect_mutator
    runner.inspect_mutator = mutate
    try:
        yield
    finally:
        runner.inspect_mutator = original


def _drift_central_field(row: dict[str, object], field: str) -> None:
    if field == "Name":
        row["Name"] = "/foreign-central-name"
    elif field == "Image":
        row["Image"] = "sha256:" + "f" * 64
    elif field == "Labels":
        config = row["Config"]
        assert isinstance(config, dict)
        config["Labels"] = {"unexpected": "drift"}
    else:
        raise AssertionError("unknown central identity field: " + field)


def test_forward_inverse_order() -> None:
    with tempfile.TemporaryDirectory(prefix="x05-nb-live-selftest-") as temporary:
        root = pathlib.Path(temporary)
        runner = FakeRunner()
        adapter, evidence = _adapter(root, runner)
        adapter.forward()
        adapter.inverse()
        journal = json.loads((evidence / "journal.json").read_text(encoding="utf-8"))
        artifacts = [
            event["artifact"] for event in journal["events"] if "artifact" in event
        ]
        assert artifacts == list(LIVE.ALL_STAGES), artifacts
        kinds = [event["kind"] for event in journal["events"]]
        assert kinds == [
            "artifact",
            "artifact",
            "mutation-prepared",
            "artifact",
            "mutation-outcome",
            "artifact",
            "artifact",
            "artifact",
            "state",
            "artifact",
            "artifact",
            "mutation-prepared",
            "artifact",
            "mutation-outcome",
            "artifact",
            "artifact",
            "artifact",
            "state",
        ]
        assert journal["state"] == "NB_INVERSE_VERIFIED"
        assert (evidence / "clean-checked.json").is_file()
        assert (root / "marker" / "active").read_text(
            encoding="utf-8"
        ) == "token=" + OWNER + "\n"
        ovsdb = [call for call in runner.calls if "ovsdb-client" in call]
        assert len(ovsdb) == 2
        assert ovsdb[0][2] == LIVE.CENTRAL_CONTAINER
        assert ovsdb[0][5] == LIVE.NB_SOCKET

        def contains(call: tuple[str, ...], needle: str) -> bool:
            return any(needle in item for item in call)

        assert (
            "bash",
            str(adapter.paths.helper_dir / "x05-nb-preflight.sh"),
            "--live",
        ) in runner.calls
        assert (
            sum(contains(call, "x05-nb-full-snapshot.sh") for call in runner.calls) == 3
        )
        assert any(
            contains(call, "x05-nb-tx.py") and "--build" in call
            for call in runner.calls
        )
        assert any(
            contains(call, "x05-nb-tx.py") and "--check-result" in call
            for call in runner.calls
        )
        assert any(
            contains(call, "x05-nb-tx.py") and "--build-inverse" in call
            for call in runner.calls
        )
        assert any(
            contains(call, "x05-nb-tx.py") and "--check-inverse-result" in call
            for call in runner.calls
        )
        assert any(
            contains(call, "x05-nb-postflight.py") and "--built" in call
            for call in runner.calls
        )
        assert any(
            contains(call, "x05-nb-postflight.py") and "--clean" in call
            for call in runner.calls
        )
        assert json.loads(ovsdb[0][-1])[0] == "OVN_Northbound"


def test_producer_factory_forward_inverse() -> None:
    """The genuine producer capability owns a complete fake NB round trip."""

    with _producer_adapter() as (session, prepared, adapter, runner, config):
        assert prepared.execution_session is session
        assert adapter.evidence_dir == config.evidence_path
        assert adapter.paths.helper_dir == config.bundle_root / "studies/p004/ovn"
        assert adapter.paths.marker == config.x05_marker_path
        assert adapter.paths.lock == config.lock_path
        assert adapter.paths.central_container == LIVE.CENTRAL_CONTAINER
        assert adapter.paths.nb_socket == LIVE.NB_SOCKET
        assert adapter._test_enable_live is False
        with mock.patch.object(
            LIVE.LockValidator,
            "validate",
            side_effect=AssertionError("legacy validator must stay unreachable"),
        ), mock.patch.object(
            LIVE.subprocess,
            "run",
            side_effect=AssertionError("legacy subprocess must stay unreachable"),
        ):
            adapter.forward()
            adapter.inverse()
        assert runner.nb_effects == 2
        ovsdb = [call for call in runner.nb_calls if "ovsdb-client" in call]
        assert [call[2] for call in ovsdb] == [
            runner.ids[LIVE.CENTRAL_CONTAINER],
            runner.ids[LIVE.CENTRAL_CONTAINER],
        ]
        journal = json.loads(
            (config.evidence_path / "journal.json").read_text(encoding="utf-8")
        )
        assert journal["state"] == "NB_INVERSE_VERIFIED"
        producer_events = PRODUCER_TEST.read_events(config.event_path)
        assert prepared._event_count == len(producer_events)
        assert prepared._event_head == producer_events[-1]["event_sha256"]
        assert [event["sequence"] for event in producer_events] == list(
            range(1, len(producer_events) + 1)
        )
        bridge_events = [
            event for event in producer_events if event["event"].startswith("x05-nb-")
        ]
        assert [event["event"] for event in bridge_events].count("x05-nb-intent") == 2
        assert [event["event"] for event in bridge_events].count("x05-nb-outcome") == 2
        assert {event["event"] for event in bridge_events} >= {
            "x05-nb-artifact",
            "x05-nb-intent",
            "x05-nb-outcome",
            "x05-nb-outcome-artifact",
            "x05-nb-readback",
            "x05-nb-state",
        }
        assert bridge_events[-1]["event"] == "x05-nb-state"
        for event in bridge_events:
            detail = event["detail"]["detail"]
            assert detail["journal_path"] == str(
                (config.evidence_path / "journal.json").absolute()
            )
            assert len(detail["journal_sha256"]) == 64
            assert not (LIVE.RUNTIME.EXECUTION_RESERVED_DETAIL_KEYS & set(detail))


def test_producer_factory_validates_full_central_identity() -> None:
    def apply_case(row: dict[str, object], case: str) -> None:
        if case == "missing-id":
            row.pop("Id")
        elif case == "stale-id":
            row["Id"] = "f" * 64
        elif case == "missing-name":
            row.pop("Name")
        elif case == "foreign-name":
            row["Name"] = "/foreign-central-name"
        elif case == "missing-image":
            row.pop("Image")
        elif case == "malformed-image":
            row["Image"] = "sha256:" + "F" * 64
        elif case == "missing-state":
            row.pop("State")
        elif case == "not-running":
            row["State"] = {"Status": "exited"}
        elif case == "missing-config":
            row.pop("Config")
        elif case == "missing-labels":
            config = row["Config"]
            assert isinstance(config, dict)
            config.pop("Labels")
        elif case == "malformed-labels":
            config = row["Config"]
            assert isinstance(config, dict)
            config["Labels"] = []
        elif case == "non-string-label-value":
            config = row["Config"]
            assert isinstance(config, dict)
            config["Labels"] = {"unexpected": 1}
        elif case == "foreign-label":
            config = row["Config"]
            assert isinstance(config, dict)
            config["Labels"] = {"unexpected": "factory"}
        else:
            raise AssertionError("unknown factory case: " + case)

    cases = (
        "missing-id",
        "stale-id",
        "missing-name",
        "foreign-name",
        "missing-image",
        "malformed-image",
        "missing-state",
        "not-running",
        "missing-config",
        "missing-labels",
        "malformed-labels",
        "non-string-label-value",
        "foreign-label",
    )
    for case in cases:
        with _producer_admission() as (_, prepared, runner, _):
            with _central_inspect_override(
                runner, lambda row, case=case: apply_case(row, case)
            ):
                _expect_error(
                    LIVE.SecurityError,
                    lambda: LIVE.NBAdapter.from_admission(prepared),
                    "central factory " + case,
                )
            assert runner.nb_effects == 0

    _expect_error(
        LIVE.SecurityError,
        lambda: LIVE._canonical_container_labels(
            {1: "value"}, context="non-string key"
        ),
        "non-string label key",
    )
    _expect_error(
        LIVE.SecurityError,
        lambda: LIVE._canonical_container_labels(
            {"key": 1}, context="non-string value"
        ),
        "non-string label value",
    )


def test_producer_factory_canonicalizes_empty_labels_and_captures_actual_image() -> None:
    # Empty labels (None / {}) canonicalize to (); a Config that carries an
    # empty Labels value is accepted by the identity parser (only a MISSING
    # Labels key is rejected, covered in the full-identity test). The
    # factory's snapshot-vs-live comparison still rejects label DRIFT, so
    # the empty-label acceptance is asserted at the parser level rather than
    # through from_admission (whose verified snapshot always carries labels).
    for labels in (None, {}):
        assert (
            LIVE._canonical_container_labels(labels, context="empty labels") == ()
        )
        identity = LIVE._parse_central_container_identity(
            [
                {
                    "Id": "a" * 64,
                    "Name": "/" + LIVE.CENTRAL_CONTAINER,
                    "Image": "sha256:" + "b" * 64,
                    "State": {"Status": "running"},
                    "Config": {"Labels": labels},
                }
            ],
            context="empty central container labels",
        )
        assert identity[3] == ()

    replacement_image = "sha256:" + "e" * 64
    with _producer_admission() as (session, prepared, runner, _):
        context = session.execution_context(prepared)
        resolved_images = context["snapshot"]["sections"]["docker"][
            "resolved_images"
        ]
        assert replacement_image not in resolved_images.values()

        def replace_image(row: dict[str, object]) -> None:
            row["Image"] = replacement_image

        with _central_inspect_override(runner, replace_image):
            adapter = LIVE.NBAdapter.from_admission(prepared)
            assert adapter._central_container_identity is not None
            assert adapter._central_container_identity[2] == replacement_image
            adapter.forward()
        assert runner.nb_effects == 1


def test_central_identity_drift_pre_dispatch_and_after_rpc() -> None:
    for field in ("Name", "Image", "Labels"):
        with _producer_admission() as (_, prepared, runner, _):
            state = {"drift": False}

            def mutate(row: dict[str, object], *, field: str = field) -> None:
                if state["drift"]:
                    _drift_central_field(row, field)

            with _central_inspect_override(runner, mutate):
                adapter = LIVE.NBAdapter.from_admission(prepared)
                state["drift"] = True
                _expect_error(
                    LIVE.SecurityError,
                    adapter.forward,
                    field + " drift before dispatch",
                )
            assert runner.nb_effects == 0

        with _producer_admission() as (_, prepared, runner, config):
            state = {"drift": False}

            def mutate(row: dict[str, object], *, field: str = field) -> None:
                if state["drift"]:
                    _drift_central_field(row, field)

            def drift_after_rpc(command: tuple[str, ...]) -> None:
                if "ovsdb-client" in command:
                    state["drift"] = True

            with _central_inspect_override(runner, mutate):
                adapter = LIVE.NBAdapter.from_admission(prepared)
                runner.after_nb_command = drift_after_rpc
                _expect_error(
                    LIVE.AmbiguousCommit,
                    adapter.forward,
                    field + " drift after RPC",
                )
                assert runner.nb_effects == 1
                assert config.x05_marker_path.is_file()
                journal = json.loads(
                    (config.evidence_path / "journal.json").read_text(
                        encoding="utf-8"
                    )
                )
                assert journal["state"] == "NB_FORWARD_AMBIGUOUS"
                before = runner.nb_effects
                _expect_error(
                    LIVE.SecurityError,
                    adapter.forward,
                    field + " drift forward reissue",
                )
                assert runner.nb_effects == before
            runner.after_nb_command = None


def test_central_identity_rechecks_fixed_helpers_and_intent_publication() -> None:
    command_name = "x05-nb-preflight.sh"
    with _producer_adapter() as (_, _, adapter, runner, _):
        state = {"drift": False}

        def mutate(row: dict[str, object]) -> None:
            if state["drift"]:
                _drift_central_field(row, "Name")

        command = (
            "bash",
            str(adapter.paths.helper_dir / command_name),
            "--live",
        )
        with _central_inspect_override(runner, mutate):
            with adapter._execution_scope():
                state["drift"] = True
                _expect_error(
                    LIVE.SecurityError,
                    lambda: adapter._helper_json(command, context="fixed helper pre"),
                    "fixed helper pre-check",
                )
        assert runner.nb_effects == 0

    with _producer_adapter() as (_, _, adapter, runner, _):
        state = {"drift": False}

        def mutate(row: dict[str, object]) -> None:
            if state["drift"]:
                _drift_central_field(row, "Name")

        def drift_after_helper(command: tuple[str, ...]) -> None:
            if command_name in " ".join(command):
                state["drift"] = True

        command = (
            "bash",
            str(adapter.paths.helper_dir / command_name),
            "--live",
        )
        runner.after_nb_command = drift_after_helper
        with _central_inspect_override(runner, mutate):
            with adapter._execution_scope():
                failure = _expect_error(
                    LIVE.AdapterError,
                    lambda: adapter._helper_json(command, context="fixed helper post"),
                    "fixed helper post-check",
                )
        runner.after_nb_command = None
        assert failure.dispatched is True
        assert runner.nb_effects == 0

    with _producer_admission() as (session, prepared, runner, config):
        state = {"drift": False}

        def mutate(row: dict[str, object]) -> None:
            if state["drift"]:
                _drift_central_field(row, "Name")

        with _central_inspect_override(runner, mutate):
            adapter = LIVE.NBAdapter.from_admission(prepared)
            original_publisher = session.record_execution_event.__func__
            original_event_log = session.events
            event_identity = config.event_path.stat()
            real_fsync = os.fsync
            triggered = 0

            def drift_after_intent_fsync(descriptor: int) -> None:
                nonlocal triggered
                real_fsync(descriptor)
                if state["drift"]:
                    return
                info = os.fstat(descriptor)
                if (info.st_dev, info.st_ino) != (
                    event_identity.st_dev,
                    event_identity.st_ino,
                ):
                    return
                rows = config.event_path.read_bytes().splitlines()
                if rows and json.loads(rows[-1]).get("event") == "x05-nb-intent":
                    triggered += 1
                    state["drift"] = True

            with mock.patch.object(os, "fsync", drift_after_intent_fsync):
                _expect_error(
                    LIVE.SecurityError,
                    adapter.forward,
                    "central identity drift after intent publication",
                )
            assert triggered == 1
            assert session.record_execution_event.__func__ is original_publisher
            assert session.events is original_event_log
        assert runner.nb_effects == 0
        assert config.x05_marker_path.is_file()
        journal = json.loads(
            (config.evidence_path / "journal.json").read_text(encoding="utf-8")
        )
        assert journal["state"] == "NB_FORWARD_INTENT"


def test_terminal_publication_windows_are_ambiguous() -> None:
    for phase in ("forward", "inverse"):
        for publication in ("readback", "state"):
            for field in ("Name", "Image", "Labels"):
                with _producer_admission() as (session, prepared, runner, config):
                    active = False
                    triggered = 0

                    def mutate(row: dict[str, object]) -> None:
                        if active:
                            _drift_central_field(row, field)

                    with _central_inspect_override(runner, mutate):
                        adapter = LIVE.NBAdapter.from_admission(prepared)
                        if phase == "inverse":
                            adapter.forward()
                        expected_effects = 1 if phase == "forward" else 2
                        stage = (
                            "built_checked" if phase == "forward" else "clean_checked"
                        )
                        original_publisher = session.record_execution_event.__func__
                        original_event_log = session.events
                        original_wrapper = session.runner
                        original_delegate = session.runner._delegate
                        event_identity = config.event_path.stat()
                        real_fsync = os.fsync

                        def drift_at_publication_fsync(descriptor: int) -> None:
                            nonlocal active, triggered
                            real_fsync(descriptor)
                            if active:
                                return
                            info = os.fstat(descriptor)
                            if (info.st_dev, info.st_ino) != (
                                event_identity.st_dev,
                                event_identity.st_ino,
                            ):
                                return
                            rows = config.event_path.read_bytes().splitlines()
                            if not rows:
                                return
                            record = json.loads(rows[-1])
                            detail = record.get("detail", {}).get("detail", {})
                            if publication == "readback":
                                matched = (
                                    record.get("event") == "x05-nb-readback"
                                    and detail.get("stage") == stage
                                )
                            else:
                                matched = (
                                    record.get("event") == "x05-nb-state"
                                    and detail.get("phase") == phase
                                    and detail.get("stage") == stage
                                )
                            if matched:
                                triggered += 1
                                active = True

                        with mock.patch.object(
                            os, "fsync", drift_at_publication_fsync
                        ):
                            _expect_error(
                                LIVE.AmbiguousCommit,
                                adapter.forward
                                if phase == "forward"
                                else adapter.inverse,
                                phase + " " + publication + " " + field,
                            )
                        assert triggered == 1
                        assert runner.nb_effects == expected_effects
                        assert session.record_execution_event.__func__ is original_publisher
                        assert session.events is original_event_log
                        assert session.runner is original_wrapper
                        assert session.runner._delegate is original_delegate
                        assert "run" not in vars(original_wrapper)
                        assert "run" not in vars(original_delegate)
                        journal = json.loads(
                            (config.evidence_path / "journal.json").read_text(
                                encoding="utf-8"
                            )
                        )
                        assert journal["state"] == (
                            "NB_" + phase.upper() + "_AMBIGUOUS"
                        )
                        assert config.x05_marker_path.is_file()
                        events = PRODUCER_TEST.read_events(config.event_path)
                        bridge_events = [
                            event
                            for event in events
                            if event["event"].startswith("x05-nb-")
                        ]
                        terminal_verified = [
                            event
                            for event in bridge_events
                            if event["event"] == "x05-nb-state"
                            and event["detail"]["detail"].get("phase") == phase
                            and event["detail"]["detail"].get("status")
                            == "VERIFIED"
                        ]
                        if terminal_verified:
                            terminal_sequence = terminal_verified[-1]["sequence"]
                            assert any(
                                event["sequence"] > terminal_sequence
                                and (
                                    event["event"] == "x05-nb-ambiguous"
                                    or event["detail"]["detail"].get("status")
                                    == "AMBIGUOUS"
                                )
                                for event in bridge_events
                            )
                        before = runner.nb_effects
                        _expect_error(
                            LIVE.AdapterError,
                            adapter.forward
                            if phase == "forward"
                            else adapter.inverse,
                            phase + " ambiguous reissue",
                        )
                        assert runner.nb_effects == before


def test_producer_factory_rejects_noncanonical_capabilities_and_overrides() -> None:
    assert LIVE.RUNTIME is sys.modules["x05_runtime_live_evaluator_contract"]
    _expect_error(
        LIVE.SecurityError,
        lambda: LIVE.NBAdapter.from_admission({"consumed": True}),
        "document admission",
    )
    with _producer_admission(consume=False) as (_, prepared, _, _):
        _expect_error(
            LIVE.SecurityError,
            lambda: LIVE.NBAdapter.from_admission(prepared),
            "unconsumed admission",
        )
    with _producer_admission() as (session, prepared, runner, config):
        _expect_error(TypeError, lambda: copy.copy(prepared), "copied admission")
        foreign = LIVE.RUNTIME.PreparedAdmission(
            session,
            snapshot_path=prepared.snapshot_path,
            snapshot_sha256=prepared.snapshot_sha256,
            snapshot_file_sha256=prepared._snapshot_file_sha256,
            inputs_sha256=prepared.input_digests_sha256,
            anchors_sha256=prepared.anchors_sha256,
            bundle_manifest_sha256=prepared.bundle_manifest_sha256,
            event_head=prepared._event_head,
            event_count=prepared._event_count,
        )
        _expect_error(
            LIVE.SecurityError,
            lambda: LIVE.NBAdapter.from_admission(foreign),
            "foreign admission",
        )
        detached = session.execution_context(prepared)
        _expect_error(
            LIVE.SecurityError,
            lambda: LIVE.NBAdapter.from_admission(detached),
            "detached context",
        )
        for override in (
            {"runner": runner},
            {"paths": LIVE.RuntimePaths()},
            {"lock_validator": FakeLock()},
        ):
            _expect_error(
                TypeError,
                lambda override=override: LIVE.NBAdapter.from_admission(
                    prepared, **override
                ),
                "factory override",
            )
        assert runner.nb_effects == 0
        config.x05_marker_path.unlink()
        runner.x05_name_present = False
        session.close()
        _expect_error(
            LIVE.SecurityError,
            lambda: LIVE.NBAdapter.from_admission(prepared),
            "stale admission",
        )


AUTHORITY_SUBSTITUTIONS = (
    "config-object",
    "runner-object",
    "runner-call",
    "mutex",
    "eventlog-object",
    "event-append",
    "event-verify",
    "event-path",
    "event-uid",
    "event-identity",
    "publisher",
    "verifier",
    "context",
    "delegate-object",
    "delegate-call",
    "collector-object",
    "collector-config",
    "collector-runner",
    "origin-guard",
    "collector-run",
)


def test_producer_factory_rejects_obvious_prefactory_authority_substitution() -> None:
    for case in AUTHORITY_SUBSTITUTIONS:
        with _producer_admission() as (session, prepared, runner, config):
            restore = _install_authority_substitution(
                case, session, runner, config, obvious=True
            )
            try:
                _expect_error(
                    LIVE.SecurityError,
                    lambda: LIVE.NBAdapter.from_admission(prepared),
                    "prefactory " + case,
                )
            finally:
                restore()
            assert runner.nb_effects == 0


def test_producer_factory_rejects_equal_type_prefactory_origins() -> None:
    cases = (
        "config-object",
        "runner-object",
        "delegate-object",
        "mutex",
        "eventlog-object",
        "collector-object",
        "collector-config",
        "collector-runner",
    )
    for case in cases:
        with _producer_admission() as (session, prepared, runner, config):
            original_mutex = session._consume_lock
            acquired = threading.Event()
            release = threading.Event()
            holder: threading.Thread | None = None
            if case == "mutex":
                def hold_original() -> None:
                    with original_mutex:
                        acquired.set()
                        assert release.wait(5), "original mutex release timed out"

                holder = threading.Thread(target=hold_original)
                holder.start()
                assert acquired.wait(2), "original mutex was not acquired"
            restore = _install_authority_substitution(
                case, session, runner, config, obvious=False
            )
            failures: list[BaseException] = []
            done = threading.Event()

            def construct() -> None:
                try:
                    LIVE.NBAdapter.from_admission(prepared)
                except BaseException as exc:
                    failures.append(exc)
                finally:
                    done.set()

            worker = threading.Thread(target=construct)
            worker.start()
            if case == "mutex":
                assert not done.wait(0.1), "factory bypassed the original mutex"
                release.set()
            assert done.wait(5), "factory origin check timed out"
            worker.join(5)
            assert not worker.is_alive()
            if holder is not None:
                holder.join(5)
                assert not holder.is_alive()
            restore()
            assert failures and isinstance(failures[0], LIVE.SecurityError), (
                case,
                failures,
            )
            assert runner.nb_effects == 0

    with _producer_admission() as (session, prepared, runner, config):
        original_timeout = config.command_timeout
        object.__setattr__(config, "command_timeout", original_timeout + 1)
        try:
            _expect_error(
                LIVE.SecurityError,
                lambda: LIVE.NBAdapter.from_admission(prepared),
                "mutated original config value",
            )
        finally:
            object.__setattr__(config, "command_timeout", original_timeout)
        assert session.config is config
        assert runner.nb_effects == 0


def test_producer_factory_rejects_class_callable_substitution() -> None:
    cases = (
        (LIVE.RUNTIME.AdmissionSession, "verify_execution"),
        (LIVE.RUNTIME.AdmissionSession, "execution_context"),
        (LIVE.RUNTIME.AdmissionSession, "record_execution_event"),
        (LIVE.RUNTIME._IncidentTrackingRunner, "run"),
        (ProducerNBFakeRunner, "run"),
        (LIVE.RUNTIME.DurableEventLog, "append"),
        (LIVE.RUNTIME.DurableEventLog, "verify"),
    )
    for owner, name in cases:
        with _producer_admission() as (_, prepared, runner, _):
            original = getattr(owner, name)

            def replacement(*args, **kwargs):
                raise AssertionError("replacement class callable must stay unreachable")

            setattr(owner, name, replacement)
            try:
                _expect_error(
                    LIVE.SecurityError,
                    lambda: LIVE.NBAdapter.from_admission(prepared),
                    "prefactory class " + owner.__name__ + "." + name,
                )
            finally:
                setattr(owner, name, original)
            assert runner.nb_effects == 0


def test_origin_guard_and_collector_run_shadows_refuse_before_effect() -> None:
    for scope in ("instance", "class"):
        for helper in ("central", "collector-run"):
            for timing in ("prefactory", "postfactory"):
                with _producer_admission() as (session, prepared, runner, config):
                    adapter = (
                        LIVE.NBAdapter.from_admission(prepared)
                        if timing == "postfactory"
                        else None
                    )
                    canonical = config.event_path
                    event_bytes = canonical.read_bytes()
                    relocated: pathlib.Path | None = None
                    calls: list[str] = []
                    if helper == "central":
                        relocated = canonical.with_name(
                            canonical.name + ".guard-shadow-original"
                        )
                        os.replace(canonical, relocated)
                        shutil.copyfile(relocated, canonical)
                        canonical.chmod(0o600)
                        session.events.path = relocated
                        owner = session if scope == "instance" else type(session)
                        name = "_assert_origin_bindings_locked"

                        def replacement(*args, **kwargs):
                            calls.append("central substitute reached")

                    else:
                        owner = (
                            session.collector
                            if scope == "instance"
                            else type(session.collector)
                        )
                        name = "_run"

                        def replacement(*args, **kwargs):
                            calls.append("collector substitute reached")
                            raise AssertionError("untrusted collector helper reached")

                    restore = _override_attribute(owner, name, replacement)
                    try:
                        action = (
                            adapter.forward
                            if adapter is not None
                            else lambda: LIVE.NBAdapter.from_admission(prepared)
                        )
                        try:
                            action()
                        except (LIVE.SecurityError, LIVE.RUNTIME.AdmissionError):
                            pass
                        else:
                            raise AssertionError(
                                f"{scope} {helper} {timing} shadow was accepted"
                            )
                        assert runner.nb_effects == 0
                        assert calls == []
                        assert canonical.read_bytes() == event_bytes
                        if relocated is not None:
                            assert relocated.read_bytes() == event_bytes
                        assert not (config.evidence_path / "journal.json").exists()
                    finally:
                        restore()
                        if relocated is not None:
                            session.events.path = canonical
                            canonical.unlink()
                            os.replace(relocated, canonical)


def test_private_session_helper_shadows_use_original_dispatch() -> None:
    helper_timings = (
        ("_assert_event_authority_locked", "prefactory"),
        ("_event_descriptor_matches", "postfactory"),
        ("_assert_execution_capability_locked", "postfactory"),
        ("_verify_execution_state_locked", "postfactory"),
        ("_event_append_locked", "postfactory"),
        ("_event_verify_locked", "prefactory"),
    )
    for scope in ("instance", "class"):
        for name, timing in helper_timings:
            with _producer_admission() as (session, prepared, runner, config):
                adapter = (
                    LIVE.NBAdapter.from_admission(prepared)
                    if timing == "postfactory"
                    else None
                )
                event_bytes = config.event_path.read_bytes()
                calls: list[str] = []

                def replacement(*args, **kwargs):
                    calls.append("private helper substitute reached")
                    raise AssertionError("untrusted private helper reached")

                owner = session if scope == "instance" else type(session)
                restore = _override_attribute(owner, name, replacement)
                try:
                    action = (
                        adapter.forward
                        if adapter is not None
                        else lambda: LIVE.NBAdapter.from_admission(prepared)
                    )
                    try:
                        action()
                    except (LIVE.SecurityError, LIVE.RUNTIME.AdmissionError):
                        pass
                    else:
                        raise AssertionError(
                            f"{scope} {name} {timing} shadow was accepted"
                        )
                    assert runner.nb_effects == 0
                    assert calls == []
                    assert config.event_path.read_bytes() == event_bytes
                    assert not (config.evidence_path / "journal.json").exists()
                finally:
                    restore()


def test_cleanup_helper_shadows_retain_original_authority() -> None:
    cases = (
        ("collector", "_run"),
        ("session", "_close_locked"),
        ("session", "_close_after_origin_loss_locked"),
        ("session", "_close_original_event_locked"),
        ("session", "_verify_published_evidence"),
        ("session", "_release_lock"),
    )
    for scope in ("instance", "class"):
        for target, name in cases:
            with _producer_admission() as (session, prepared, runner, config):
                config.x05_marker_path.unlink()
                runner.x05_name_present = False
                calls: list[str] = []
                command_count = len(runner.calls)

                def replacement(*args, **kwargs):
                    calls.append("cleanup helper substitute reached")
                    raise AssertionError("untrusted cleanup helper reached")

                target_object = session.collector if target == "collector" else session
                owner = target_object if scope == "instance" else type(target_object)
                restore = _override_attribute(owner, name, replacement)
                try:
                    _expect_error(
                        LIVE.RUNTIME.AdmissionIncident,
                        session.close,
                        f"{scope} {target}.{name} cleanup shadow",
                    )
                    assert calls == []
                    assert len(runner.calls) == command_count
                    assert runner.active
                    assert not prepared.active
                    assert session._closed
                    PRODUCER_TEST.assert_competing_lock_blocked(config.lock_path)
                finally:
                    restore()
                    PRODUCER_TEST.close_retained_test_descriptors(session)


def test_consumed_helper_loss_stays_sticky_after_restore() -> None:
    for scope in ("instance", "class"):
        for name in ("_verify_bundle", "_assert_origin_bindings_locked"):
            with _producer_admission() as (session, prepared, runner, config):
                adapter = LIVE.NBAdapter.from_admission(prepared)
                event_bytes = config.event_path.read_bytes()
                calls: list[str] = []

                def substitute(*args, **kwargs):
                    calls.append("substitute reached")
                    return "foreign"

                owner = session if scope == "instance" else type(session)
                restore = _override_attribute(owner, name, substitute)
                try:
                    first = _expect_error(
                        LIVE.RUNTIME.AdmissionIncident,
                        lambda: session.verify_execution(prepared),
                        f"{scope} {name} authority loss",
                    )
                finally:
                    restore()
                failure = session._execution_failure
                assert calls == [] and failure is not None
                assert str(first) == failure
                later_calls: list[str] = []
                later_name = (
                    "_assert_origin_bindings_locked"
                    if name == "_verify_bundle"
                    else "_verify_bundle"
                )

                def later_substitute(*args, **kwargs):
                    later_calls.append("later substitute reached")

                later_restore = _override_attribute(
                    session, later_name, later_substitute
                )
                try:
                    later = _expect_error(
                        LIVE.RUNTIME.AdmissionIncident,
                        lambda: session.verify_execution(prepared),
                        f"{scope} {name} first-cause preservation",
                    )
                finally:
                    later_restore()
                assert later_calls == []
                assert str(later) == failure
                for label, action in (
                    ("verify", lambda: session.verify_execution(prepared)),
                    ("context", lambda: session.execution_context(prepared)),
                    (
                        "publish",
                        lambda: session.record_execution_event(
                            prepared, "x05-after-helper-loss", {"blocked": True}
                        ),
                    ),
                ):
                    replay = _expect_error(
                        LIVE.RUNTIME.AdmissionIncident,
                        action,
                        f"{scope} {name} sticky {label}",
                    )
                    assert str(replay) == failure
                _expect_error(
                    LIVE.AdapterError,
                    lambda: LIVE.NBAdapter.from_admission(prepared),
                    f"{scope} {name} sticky factory",
                )
                _expect_error(
                    LIVE.RUNTIME.AdmissionIncident,
                    adapter.forward,
                    f"{scope} {name} sticky original adapter",
                )
                assert session._execution_failure == failure
                assert runner.nb_effects == 0
                assert config.event_path.read_bytes() == event_bytes
                assert not (config.evidence_path / "journal.json").exists()
            assert not runner.active


def test_invalid_foreign_and_unconsumed_calls_do_not_poison_execution() -> None:
    with _producer_admission(consume=False) as (session, prepared, runner, config):
        event_bytes = config.event_path.read_bytes()
        _expect_error(
            LIVE.RUNTIME.AdmissionError,
            lambda: session.verify_execution(object()),
            "foreign execution capability",
        )
        _expect_error(
            LIVE.RUNTIME.AdmissionError,
            lambda: session.record_execution_event(
                prepared, "invalid-event", {"invalid": True}
            ),
            "invalid unconsumed execution event",
        )
        calls: list[str] = []

        def substitute(*args, **kwargs):
            calls.append("substitute reached")

        restore = _override_attribute(
            session, "_assert_origin_bindings_locked", substitute
        )
        try:
            _expect_error(
                LIVE.RUNTIME.AdmissionIncident,
                lambda: session.verify_execution(prepared),
                "unconsumed helper authority loss",
            )
        finally:
            restore()
        assert calls == []
        assert session._execution_failure is None
        assert config.event_path.read_bytes() == event_bytes

        session.consume(prepared)
        _write_producer_marker(config)
        consumed_event_bytes = config.event_path.read_bytes()
        _expect_error(
            LIVE.RUNTIME.AdmissionError,
            lambda: session.record_execution_event(
                prepared, "invalid-event", {"invalid": True}
            ),
            "invalid consumed execution event",
        )
        assert session._execution_failure is None
        assert config.event_path.read_bytes() == consumed_event_bytes
        adapter = LIVE.NBAdapter.from_admission(prepared)
        assert adapter.forward()["status"] == "PASS"
        assert adapter.inverse()["status"] == "PASS"
        assert runner.nb_effects == 2


def test_original_producer_authorities_are_pinned_before_effect() -> None:
    for case in AUTHORITY_SUBSTITUTIONS:
        with _producer_adapter() as (session, _, adapter, runner, config):
            event_bytes = config.event_path.read_bytes()
            restore = _install_authority_substitution(case, session, runner, config)
            try:
                try:
                    adapter.forward()
                except (LIVE.SecurityError, LIVE.RUNTIME.AdmissionError):
                    pass
                else:
                    raise AssertionError("pre-effect " + case + " was accepted")
            finally:
                restore()
            assert runner.nb_effects == 0
            assert config.event_path.read_bytes() == event_bytes
            assert not (config.evidence_path / "journal.json").exists(), case


def test_post_effect_authority_substitution_is_ambiguous_and_not_reissued() -> None:
    for case in AUTHORITY_SUBSTITUTIONS:
        with _producer_adapter() as (session, _, adapter, runner, config):
            restores: list[Callable[[], None]] = []

            def substitute_after_effect(
                command: tuple[str, ...], *, case: str = case
            ) -> None:
                if "ovsdb-client" in command and not restores:
                    restores.append(
                        _install_authority_substitution(
                            case, session, runner, config
                        )
                    )

            runner.after_nb_command = substitute_after_effect
            try:
                _expect_error(
                    LIVE.AmbiguousCommit,
                    adapter.forward,
                    "post-effect " + case,
                )
            finally:
                runner.after_nb_command = None
                if restores:
                    restores.pop()()
            assert runner.nb_effects == 1
            assert config.x05_marker_path.is_file()
            journal = json.loads(
                (config.evidence_path / "journal.json").read_text(encoding="utf-8")
            )
            assert journal["state"] == "NB_FORWARD_AMBIGUOUS", (case, journal)
            before = runner.nb_effects
            try:
                adapter.forward()
            except (LIVE.AdapterError, LIVE.RUNTIME.AdmissionError):
                pass
            else:
                raise AssertionError("post-effect reissue " + case + " was accepted")
            assert runner.nb_effects == before


def test_canonical_event_authority_rejects_path_retargeting() -> None:
    for case in ("rename-recreate", "rename-copy-retarget", "symlink", "mode"):
        with _producer_adapter() as (session, _, adapter, runner, config):
            canonical = config.event_path
            original_path = session.events.path
            original_bytes = canonical.read_bytes()
            relocated = canonical.with_name(canonical.name + ".original")
            alternate = canonical.with_name(canonical.name + ".alternate")
            try:
                if case in {"rename-recreate", "rename-copy-retarget"}:
                    os.replace(canonical, relocated)
                    canonical.write_bytes(original_bytes)
                    canonical.chmod(0o600)
                    if case == "rename-copy-retarget":
                        session.events.path = relocated
                elif case == "symlink":
                    os.replace(canonical, relocated)
                    alternate.write_bytes(original_bytes)
                    alternate.chmod(0o600)
                    canonical.symlink_to(alternate)
                else:
                    canonical.chmod(0o640)
                _expect_error(
                    LIVE.RUNTIME.AdmissionError,
                    adapter.forward,
                    "canonical event " + case,
                )
                assert runner.nb_effects == 0
                assert not (config.evidence_path / "journal.json").exists()
            finally:
                session.events.path = original_path
                if case == "mode":
                    canonical.chmod(0o600)
                else:
                    canonical.unlink(missing_ok=True)
                    if relocated.exists():
                        os.replace(relocated, canonical)
                    alternate.unlink(missing_ok=True)


def test_event_descriptor_closed_and_recycled_are_rejected_safely() -> None:
    with _producer_adapter() as (session, _, adapter, runner, _):
        descriptor = session._event_authority.descriptor
        saved = os.dup(descriptor)
        os.close(descriptor)
        try:
            _expect_error(
                LIVE.RUNTIME.AdmissionError,
                adapter.forward,
                "closed original event descriptor",
            )
            assert runner.nb_effects == 0
        finally:
            os.dup2(saved, descriptor, inheritable=False)
            os.close(saved)

    with _producer_admission() as (session, prepared, runner, config):
        adapter = LIVE.NBAdapter.from_admission(prepared)
        descriptor = session._event_authority.descriptor
        saved = os.dup(descriptor)
        foreign_path = config.run_parent / "foreign-event-fd"
        os.close(descriptor)
        foreign = os.open(
            foreign_path,
            os.O_RDWR | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
            0o600,
        )
        if foreign != descriptor:
            os.dup2(foreign, descriptor, inheritable=False)
            os.close(foreign)
        foreign_identity = os.fstat(descriptor)
        try:
            _expect_error(
                LIVE.RUNTIME.AdmissionError,
                adapter.forward,
                "recycled original event descriptor",
            )
            assert runner.nb_effects == 0
            _expect_error(
                LIVE.RUNTIME.AdmissionIncident,
                session.close,
                "recycled event descriptor close",
            )
            after = os.fstat(descriptor)
            assert (after.st_dev, after.st_ino) == (
                foreign_identity.st_dev,
                foreign_identity.st_ino,
            )
        finally:
            with contextlib.suppress(OSError):
                os.close(descriptor)
            os.close(saved)
            PRODUCER_TEST.close_retained_test_descriptors(session)


def test_close_never_targets_a_substituted_event_object() -> None:
    with _producer_admission() as (session, _, runner, config):
        original_event = session.events
        descriptor = session._event_authority.descriptor
        replacement = LIVE.RUNTIME.DurableEventLog(
            config.event_path.with_name("foreign-event-object"),
            uid=config.required_uid,
        )
        replacement_close_called = False

        def replacement_close() -> None:
            nonlocal replacement_close_called
            replacement_close_called = True

        replacement.close = replacement_close
        session.events = replacement
        _expect_error(
            LIVE.RUNTIME.AdmissionIncident,
            session.close,
            "substituted event object close",
        )
        assert not replacement_close_called
        assert runner.active
        assert session._closed and session._lock_authority_lost
        try:
            os.fstat(descriptor)
        except OSError:
            pass
        else:
            raise AssertionError("original event descriptor was not safely closed")
        session.events = original_event
        PRODUCER_TEST.close_retained_test_descriptors(session)


def test_public_producer_apis_wait_for_original_mutex() -> None:
    def exercise(action_name: str, *, consume: bool = True) -> None:
        with _producer_admission(consume=consume) as (
            session,
            prepared,
            runner,
            _,
        ):
            original = session._consume_lock
            replacement = LIVE.RUNTIME.threading.RLock()
            acquired = threading.Event()
            release = threading.Event()
            done = threading.Event()
            failures: list[BaseException] = []

            def hold() -> None:
                with original:
                    acquired.set()
                    assert release.wait(5), "mutex canary release timed out"

            def call() -> None:
                try:
                    if action_name == "consume":
                        session.consume(prepared)
                    elif action_name == "verify":
                        session.verify_execution(prepared)
                    elif action_name == "context":
                        session.execution_context(prepared)
                    elif action_name == "publish":
                        session.record_execution_event(
                            prepared, "x05-mutex-canary", {"case": action_name}
                        )
                    else:
                        session.close()
                except BaseException as exc:
                    failures.append(exc)
                finally:
                    done.set()

            holder = threading.Thread(target=hold)
            holder.start()
            assert acquired.wait(2)
            session._consume_lock = replacement
            worker = threading.Thread(target=call)
            worker.start()
            assert not done.wait(0.1), action_name + " bypassed original mutex"
            release.set()
            assert done.wait(5), action_name + " mutex canary timed out"
            worker.join(5)
            holder.join(5)
            assert not worker.is_alive() and not holder.is_alive()
            assert failures and isinstance(
                failures[0], LIVE.RUNTIME.AdmissionError
            ), (action_name, failures)
            assert runner.nb_effects == 0
            if action_name == "close":
                assert session._closed
                PRODUCER_TEST.close_retained_test_descriptors(session)
            else:
                session._consume_lock = original

    exercise("consume", consume=False)
    for name in ("verify", "context", "publish", "close"):
        exercise(name)


def test_post_effect_event_fsync_drift_is_ambiguous_and_sticky() -> None:
    with _producer_adapter() as (session, _, adapter, runner, config):
        canonical = config.event_path
        original_bytes = canonical.read_bytes()
        relocated = canonical.with_name(canonical.name + ".post-effect")
        event_identity = canonical.stat()
        real_fsync = os.fsync
        triggered = 0

        def drift_after_outcome_fsync(descriptor: int) -> None:
            nonlocal triggered
            real_fsync(descriptor)
            if triggered:
                return
            info = os.fstat(descriptor)
            if (info.st_dev, info.st_ino) != (
                event_identity.st_dev,
                event_identity.st_ino,
            ):
                return
            rows = canonical.read_bytes().splitlines()
            if rows and json.loads(rows[-1]).get("event") == "x05-nb-outcome-artifact":
                triggered += 1
                os.replace(canonical, relocated)
                canonical.write_bytes(original_bytes)
                canonical.chmod(0o600)

        try:
            with mock.patch.object(os, "fsync", drift_after_outcome_fsync):
                _expect_error(
                    LIVE.AmbiguousCommit,
                    adapter.forward,
                    "post-effect event fsync drift",
                )
            assert triggered == 1
            assert runner.nb_effects == 1
            assert config.x05_marker_path.is_file()
            journal = json.loads(
                (config.evidence_path / "journal.json").read_text(encoding="utf-8")
            )
            assert journal["state"] == "NB_FORWARD_AMBIGUOUS"
            before = runner.nb_effects
            _expect_error(
                LIVE.RUNTIME.AdmissionError,
                adapter.forward,
                "event drift reissue",
            )
            assert runner.nb_effects == before
        finally:
            canonical.unlink(missing_ok=True)
            if relocated.exists():
                os.replace(relocated, canonical)


def test_adapter_bridge_callable_is_pinned() -> None:
    with _producer_adapter() as (_, _, adapter, runner, config):
        event_bytes = config.event_path.read_bytes()
        restore = _override_attribute(
            adapter.runner,
            "run",
            lambda *args, **kwargs: (_ for _ in ()).throw(
                AssertionError("replacement bridge call must stay unreachable")
            ),
        )
        try:
            _expect_error(
                LIVE.SecurityError,
                adapter.forward,
                "pre-effect bridge call substitution",
            )
        finally:
            restore()
        assert runner.nb_effects == 0
        assert config.event_path.read_bytes() == event_bytes

    with _producer_adapter() as (_, _, adapter, runner, config):
        restores: list[Callable[[], None]] = []

        def substitute_bridge_after_effect(command: tuple[str, ...]) -> None:
            if "ovsdb-client" in command and not restores:
                restores.append(
                    _override_attribute(
                        adapter.runner,
                        "runner_call",
                        lambda *args, **kwargs: (_ for _ in ()).throw(
                            AssertionError(
                                "replacement captured call must stay unreachable"
                            )
                        ),
                    )
                )

        runner.after_nb_command = substitute_bridge_after_effect
        try:
            _expect_error(
                LIVE.AmbiguousCommit,
                adapter.forward,
                "post-effect bridge call substitution",
            )
        finally:
            runner.after_nb_command = None
            if restores:
                restores.pop()()
        assert runner.nb_effects == 1
        assert config.x05_marker_path.is_file()
        journal = json.loads(
            (config.evidence_path / "journal.json").read_text(encoding="utf-8")
        )
        assert journal["state"] == "NB_FORWARD_AMBIGUOUS"
        before = runner.nb_effects
        _expect_error(LIVE.AdapterError, adapter.forward, "bridge-call reissue")
        assert runner.nb_effects == before


def test_producer_result_failures_are_ambiguous_and_not_reissued() -> None:
    expected = {
        "invalid-utf8": (b"\xff", "strict UTF-8"),
        "stderr": (b"[{}]\n", "returned stderr"),
        "invalid-stderr": (b"[{}]\n", "returned stderr"),
        "invalid-both-streams": (b"\xfe", "returned stderr"),
        "nonzero": (b"[{}]\n", "exited nonzero"),
        "malformed": (b"not-json\n", "malformed JSON"),
        "incomplete": (b"", "incomplete result"),
        "invalid-fields": (b"", "invalid result fields"),
        "oversize": (b"", "combined output bound"),
        "timeout": (b"", "outcome is unknown"),
    }
    for mode, (raw, message) in expected.items():
        with _producer_adapter() as (session, prepared, adapter, runner, config):
            runner.nb_result_mode = mode
            failure = _expect_error(
                LIVE.AmbiguousCommit,
                adapter.forward,
                mode + " NB outcome",
            )
            assert message in str(failure), (mode, failure)
            if mode in {"invalid-stderr", "invalid-both-streams"}:
                assert "strict UTF-8" not in str(failure)
                assert failure.result is not None
                assert failure.result.stdout_bytes == raw
                assert failure.result.stderr_bytes == b"\xff"
            assert runner.nb_effects == 1
            assert config.x05_marker_path.is_file()
            journal = json.loads(
                (config.evidence_path / "journal.json").read_text(encoding="utf-8")
            )
            assert journal["state"] == "NB_FORWARD_AMBIGUOUS", (mode, journal)
            assert journal["events"][-1]["kind"] == "mutation-outcome"
            assert journal["events"][-1]["ambiguous"] is True
            assert (
                config.evidence_path / "forward-result.raw.json"
            ).read_bytes() == raw
            session.verify_execution(prepared)
            before = runner.nb_effects
            _expect_error(
                LIVE.SecurityError,
                adapter.forward,
                mode + " forward reissue",
            )
            assert runner.nb_effects == before


def test_producer_inverse_failure_is_ambiguous_and_not_reissued() -> None:
    with _producer_adapter() as (session, prepared, adapter, runner, config):
        adapter.forward()
        runner.nb_result_mode = "stderr"
        _expect_error(
            LIVE.AmbiguousCommit,
            adapter.inverse,
            "inverse stderr outcome",
        )
        assert runner.nb_effects == 2
        journal = json.loads(
            (config.evidence_path / "journal.json").read_text(encoding="utf-8")
        )
        assert journal["state"] == "NB_INVERSE_AMBIGUOUS"
        session.verify_execution(prepared)
        _expect_error(
            LIVE.SecurityError,
            adapter.inverse,
            "inverse reissue",
        )
        assert runner.nb_effects == 2


def test_producer_pre_dispatch_drift_has_no_transaction_effect() -> None:
    with _producer_adapter() as (_, _, adapter, runner, _):
        _replace_same_bytes(adapter.paths.helper_dir / "x05-nb-tx.py")
        _expect_error(
            LIVE.SecurityError,
            adapter.forward,
            "pre-dispatch source ABA",
        )
        assert runner.nb_effects == 0

    with _producer_adapter() as (_, _, adapter, runner, _):
        helper = adapter.paths.helper_dir / "x05-nb-preflight.sh"
        helper.write_bytes(helper.read_bytes() + b"# bundle drift\n")
        _expect_error(
            LIVE.SecurityError,
            adapter.forward,
            "pre-dispatch bundle drift",
        )
        assert runner.nb_effects == 0

    with _producer_adapter() as (_, _, adapter, runner, config):
        receipt = config.receipt_path.read_bytes()
        config.receipt_path.write_bytes(receipt + b" ")
        try:
            _expect_error(
                LIVE.RUNTIME.AdmissionIncident,
                adapter.forward,
                "pre-dispatch input drift",
            )
        finally:
            config.receipt_path.write_bytes(receipt)
        assert runner.nb_effects == 0

    with _producer_adapter() as (_, _, adapter, runner, _):
        adapter.command_timeout += 1
        _expect_error(
            LIVE.SecurityError,
            adapter.forward,
            "producer config override",
        )
        assert runner.nb_effects == 0

    with _producer_adapter() as (_, _, adapter, runner, config):
        fired = False

        def corrupt_journal(command: tuple[str, ...]) -> None:
            nonlocal fired
            if fired or "x05-nb-preflight.sh" not in " ".join(command):
                return
            fired = True
            journal = config.evidence_path / "journal.json"
            journal.write_bytes(journal.read_bytes() + b" ")

        runner.after_nb_command = corrupt_journal
        _expect_error(
            LIVE.SecurityError,
            adapter.forward,
            "pre-dispatch journal drift",
        )
        assert fired and runner.nb_effects == 0
        assert (config.evidence_path / "journal.json").read_bytes().endswith(b" ")

    with _producer_adapter() as (_, _, adapter, runner, config):
        fired = False

        def corrupt_artifact(command: tuple[str, ...]) -> None:
            nonlocal fired
            if (
                fired
                or "x05-nb-tx.py" not in " ".join(command)
                or "--build" not in command
            ):
                return
            fired = True
            preflight = config.evidence_path / "preflight.json"
            preflight.write_bytes(preflight.read_bytes() + b" ")

        runner.after_nb_command = corrupt_artifact
        _expect_error(
            LIVE.SecurityError,
            adapter.forward,
            "pre-dispatch artifact drift",
        )
        assert fired and runner.nb_effects == 0
        assert (config.evidence_path / "preflight.json").read_bytes().endswith(b" ")

    with _producer_adapter() as (session, _, adapter, runner, _):
        del session
        with mock.patch.object(
            LIVE.RUNTIME,
            "_read_lock_fdinfo_bytes",
            return_value=b"invalid-fdinfo\n",
        ):
            _expect_error(
                LIVE.RUNTIME.AdmissionIncident,
                adapter.forward,
                "pre-dispatch lock loss",
            )
        assert runner.nb_effects == 0


def test_producer_post_dispatch_drift_is_ambiguous() -> None:
    with _producer_adapter() as (session, prepared, adapter, runner, config):
        source = adapter.paths.helper_dir / "x05-nb-live.py"

        def replace_source(command: tuple[str, ...]) -> None:
            if "ovsdb-client" in command:
                _replace_same_bytes(source)

        runner.after_nb_command = replace_source
        _expect_error(
            LIVE.AmbiguousCommit,
            adapter.forward,
            "post-dispatch source ABA",
        )
        assert runner.nb_effects == 1
        session.verify_execution(prepared)
        journal = json.loads(
            (config.evidence_path / "journal.json").read_text(encoding="utf-8")
        )
        assert journal["state"] == "NB_FORWARD_AMBIGUOUS"

    with _producer_adapter() as (session, prepared, adapter, runner, config):
        helper = adapter.paths.helper_dir / "x05-nb-preflight.sh"

        def change_bundle_bytes(command: tuple[str, ...]) -> None:
            if "ovsdb-client" in command:
                helper.write_bytes(helper.read_bytes() + b"# drift after dispatch\n")

        runner.after_nb_command = change_bundle_bytes
        _expect_error(
            LIVE.AmbiguousCommit,
            adapter.forward,
            "post-dispatch bundle drift",
        )
        assert runner.nb_effects == 1
        session.verify_execution(prepared)
        journal = json.loads(
            (config.evidence_path / "journal.json").read_text(encoding="utf-8")
        )
        assert journal["state"] == "NB_FORWARD_AMBIGUOUS"

    with _producer_adapter() as (_, _, adapter, runner, config):
        receipt = config.receipt_path.read_bytes()

        def corrupt_input(command: tuple[str, ...]) -> None:
            if "ovsdb-client" in command:
                config.receipt_path.write_bytes(receipt + b" ")

        runner.after_nb_command = corrupt_input
        try:
            _expect_error(
                LIVE.AmbiguousCommit,
                adapter.forward,
                "post-dispatch input drift",
            )
        finally:
            config.receipt_path.write_bytes(receipt)
        assert runner.nb_effects == 1
        journal = json.loads(
            (config.evidence_path / "journal.json").read_text(encoding="utf-8")
        )
        assert journal["state"] == "NB_FORWARD_AMBIGUOUS"

    with _producer_adapter() as (session, prepared, adapter, runner, _):
        original_id = runner.ids[LIVE.CENTRAL_CONTAINER]

        def change_central_id(command: tuple[str, ...]) -> None:
            if "ovsdb-client" in command:
                runner.ids[LIVE.CENTRAL_CONTAINER] = "f" * 64

        runner.after_nb_command = change_central_id
        try:
            _expect_error(
                LIVE.AmbiguousCommit,
                adapter.forward,
                "post-dispatch central identity drift",
            )
        finally:
            runner.ids[LIVE.CENTRAL_CONTAINER] = original_id
        assert runner.nb_effects == 1
        session.verify_execution(prepared)

    for target in ("journal", "artifact"):
        with _producer_adapter() as (session, prepared, adapter, runner, config):
            def corrupt_nb_binding(
                command: tuple[str, ...], *, target: str = target
            ) -> None:
                if "ovsdb-client" not in command:
                    return
                path = config.evidence_path / (
                    "journal.json" if target == "journal" else "preflight.json"
                )
                path.write_bytes(path.read_bytes() + b" ")

            runner.after_nb_command = corrupt_nb_binding
            _expect_error(
                LIVE.AmbiguousCommit,
                adapter.forward,
                "post-dispatch " + target + " drift",
            )
            assert runner.nb_effects == 1
            session.verify_execution(prepared)
            path = config.evidence_path / (
                "journal.json" if target == "journal" else "preflight.json"
            )
            assert path.read_bytes().endswith(b" ")

    with _producer_adapter() as (session, _, adapter, runner, config):
        descriptors = (LIVE.LOCK_FD, session._lock_keeper_fd)
        baseline = {
            descriptor: LIVE.RUNTIME._read_lock_fdinfo_bytes(descriptor)
            for descriptor in descriptors
        }

        def lose_lock(descriptor: int) -> bytes:
            if runner.nb_effects:
                return b"invalid-fdinfo\n"
            return baseline[descriptor]

        with mock.patch.object(
            LIVE.RUNTIME,
            "_read_lock_fdinfo_bytes",
            side_effect=lose_lock,
        ):
            _expect_error(
                LIVE.AmbiguousCommit,
                adapter.forward,
                "post-dispatch lock loss",
            )
        assert runner.nb_effects == 1
        journal = json.loads(
            (config.evidence_path / "journal.json").read_text(encoding="utf-8")
        )
        assert journal["state"] == "NB_FORWARD_AMBIGUOUS"


def test_invalid_authority_after_intent_prevents_transaction_dispatch() -> None:
    with _producer_adapter() as (session, prepared, adapter, runner, config):
        original_publisher = session.record_execution_event.__func__
        original_event_log = session.events
        event_identity = config.event_path.stat()
        real_fsync = os.fsync
        corrupted = False

        def corrupt_after_intent_fsync(descriptor: int) -> None:
            nonlocal corrupted
            real_fsync(descriptor)
            if corrupted:
                return
            info = os.fstat(descriptor)
            if (info.st_dev, info.st_ino) != (
                event_identity.st_dev,
                event_identity.st_ino,
            ):
                return
            rows = config.event_path.read_bytes().splitlines()
            if not rows or json.loads(rows[-1]).get("event") != "x05-nb-intent":
                return
            corrupted = True
            fd = os.open(config.event_path, os.O_WRONLY | os.O_APPEND)
            try:
                os.write(fd, b" ")
                real_fsync(fd)
            finally:
                os.close(fd)

        with mock.patch.object(os, "fsync", corrupt_after_intent_fsync):
            first = _expect_error(
                LIVE.RUNTIME.AdmissionIncident,
                adapter.forward,
                "authority drift after intent publication",
            )
        assert corrupted
        assert session.record_execution_event.__func__ is original_publisher
        assert session.events is original_event_log
        assert runner.nb_effects == 0
        assert config.x05_marker_path.is_file()
        journal = json.loads(
            (config.evidence_path / "journal.json").read_text(encoding="utf-8")
        )
        assert journal["state"] == "NB_FORWARD_INTENT"
        assert not (config.evidence_path / "forward-result.raw.json").exists()
        second = _expect_error(
            LIVE.RUNTIME.AdmissionIncident,
            lambda: session.verify_execution(prepared),
            "sticky authority drift",
        )
        assert str(second) == str(first)


def test_timeout_retains_marker_and_journal() -> None:
    with tempfile.TemporaryDirectory(prefix="x05-nb-live-selftest-") as temporary:
        root = pathlib.Path(temporary)
        runner = FakeRunner(timeout_on_ovsdb=True)
        adapter, evidence = _adapter(root, runner)
        try:
            adapter.forward()
        except LIVE.AmbiguousCommit:
            pass
        else:
            raise AssertionError("timeout must be ambiguous")
        marker = next((root / "marker").glob("active"))
        assert marker.read_text(encoding="utf-8") == "token=" + OWNER + "\n"
        journal = json.loads((evidence / "journal.json").read_text(encoding="utf-8"))
        assert journal["events"][-1]["kind"] == "mutation-outcome"
        assert journal["events"][-1]["ambiguous"] is True
        assert (evidence / "forward-result.raw.json").read_bytes() == b""


def test_postflight_fail_is_recorded_even_with_zero_exit() -> None:
    with tempfile.TemporaryDirectory(prefix="x05-nb-live-selftest-") as temporary:
        root = pathlib.Path(temporary)
        runner = FakeRunner(built_fail=True)
        adapter, evidence = _adapter(root, runner)
        try:
            adapter.forward()
        except LIVE.PostconditionError:
            pass
        else:
            raise AssertionError("postflight FAIL must stop the run")
        report = json.loads(
            (evidence / "built-checked.json").read_text(encoding="utf-8")
        )
        assert report["status"] == "FAIL"
        assert (root / "marker" / "active").read_text(
            encoding="utf-8"
        ) == "token=" + OWNER + "\n"


def test_inverse_rejects_tampered_forward_artifact_before_helper() -> None:
    with tempfile.TemporaryDirectory(prefix="x05-nb-live-selftest-") as temporary:
        root = pathlib.Path(temporary)
        runner = FakeRunner()
        adapter, evidence = _adapter(root, runner)
        adapter.forward()
        calls_before = len(runner.calls)
        checked = evidence / "forward-checked.json"
        checked.write_bytes(checked.read_bytes() + b" ")
        try:
            adapter.inverse()
        except LIVE.SecurityError:
            pass
        else:
            raise AssertionError("tampered forward artifact must stop inverse")
        assert len(runner.calls) == calls_before


def test_inverse_rejects_marker_binding_change_before_helper() -> None:
    with tempfile.TemporaryDirectory(prefix="x05-nb-live-selftest-") as temporary:
        root = pathlib.Path(temporary)
        runner = FakeRunner()
        adapter, evidence = _adapter(root, runner)
        adapter.forward()
        calls_before = len(runner.calls)
        journal_path = evidence / "journal.json"
        journal = json.loads(journal_path.read_text(encoding="utf-8"))
        journal["marker"] = str(root / "other-marker")
        journal_path.write_text(json.dumps(journal) + "\n", encoding="utf-8")
        journal_path.chmod(0o600)
        try:
            adapter.inverse()
        except LIVE.SecurityError:
            pass
        else:
            raise AssertionError("journal marker binding change must stop inverse")
        assert len(runner.calls) == calls_before


def test_preinverse_nonzero_is_recorded_and_stops_before_inverse() -> None:
    with tempfile.TemporaryDirectory(prefix="x05-nb-live-selftest-") as temporary:
        root = pathlib.Path(temporary)
        runner = FakeRunner(preinverse_fail=True)
        adapter, evidence = _adapter(root, runner)
        adapter.forward()
        try:
            adapter.inverse()
        except LIVE.AdapterError as exc:
            assert "preinverse snapshot" in str(exc)
        else:
            raise AssertionError("preinverse failure must stop inverse")
        ovsdb = [call for call in runner.calls if "ovsdb-client" in call]
        assert len(ovsdb) == 1
        assert (evidence / "preinverse-snapshot.json").is_file()
        journal = json.loads((evidence / "journal.json").read_text(encoding="utf-8"))
        assert journal["state"] == "NB_FORWARD_VERIFIED"


def test_inverse_refuses_unverified_forward_states() -> None:
    for runner in (FakeRunner(timeout_on_ovsdb=True), FakeRunner(built_fail=True)):
        with tempfile.TemporaryDirectory(prefix="x05-nb-live-selftest-") as temporary:
            root = pathlib.Path(temporary)
            adapter, evidence = _adapter(root, runner)
            try:
                adapter.forward()
            except LIVE.AdapterError:
                pass
            else:
                raise AssertionError("forward failure must stop the run")
            calls_before = len(runner.calls)
            try:
                adapter.inverse()
            except LIVE.SecurityError:
                pass
            else:
                raise AssertionError("inverse must refuse an unverified forward")
            assert len(runner.calls) == calls_before
            journal = json.loads(
                (evidence / "journal.json").read_text(encoding="utf-8")
            )
            assert journal["state"] in {"NB_FORWARD_AMBIGUOUS", "NB_FORWARD_COMMITTED"}


def test_real_helper_fixture_cli_contract() -> None:
    fixture = HERE / "x05-nb-preflight-fixture.json"
    preflight_command = [
        "bash",
        str(HERE / "x05-nb-preflight.sh"),
        "--fixture",
        str(fixture),
    ]
    preflight_result = subprocess.run(
        preflight_command, capture_output=True, text=True, timeout=10, check=False
    )
    assert preflight_result.returncode == 0, preflight_result.stderr
    preflight = json.loads(preflight_result.stdout)
    tables = (
        "Logical_Switch",
        "Logical_Router",
        "Logical_Switch_Port",
        "Logical_Router_Port",
        "Gateway_Chassis",
        "Logical_Router_Static_Route",
        "Network_Function",
        "Port_Group",
        "Logical_Router_Policy",
        "NAT",
    )
    with tempfile.TemporaryDirectory(prefix="x05-nb-fixture-") as temporary:
        snapshot_fixture = pathlib.Path(temporary) / "snapshot.json"
        snapshot_fixture.write_text(
            json.dumps(
                {
                    "schema": "p004-x05-nb-full-snapshot-v1",
                    "nb_cfg_before": 10,
                    "nb_cfg_after": 10,
                    "tables": {table: [] for table in tables},
                }
            )
            + "\n",
            encoding="utf-8",
        )
        full_command = [
            "bash",
            str(HERE / "x05-nb-full-snapshot.sh"),
            "--fixture",
            str(snapshot_fixture),
        ]
        full_result = subprocess.run(
            full_command, capture_output=True, text=True, timeout=10, check=False
        )
        assert full_result.returncode == 0, full_result.stderr
        full = json.loads(full_result.stdout)
    assert preflight["schema"] == "p004-x05-nb-preflight-v1"
    assert preflight["status"] == "PASS"
    assert full["schema"] == "p004-x05-nb-full-snapshot-v1"


def test_public_live_cli_is_disabled_before_filesystem_or_runner() -> None:
    with tempfile.TemporaryDirectory(prefix="x05-nb-live-selftest-") as temporary:
        evidence = pathlib.Path(temporary) / "evidence"
        evidence.mkdir()
        result = subprocess.run(
            [
                sys.executable,
                str(HERE / "x05-nb-live.py"),
                "--forward",
                "--run-hex",
                RUN_HEX,
                "--evidence-dir",
                str(evidence),
            ],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        assert result.returncode == 75, result.stderr
        assert list(evidence.iterdir()) == []


def test_public_recovery_cli_is_disabled_before_filesystem_or_runner() -> None:
    with tempfile.TemporaryDirectory(prefix="x05-nb-live-selftest-") as temporary:
        evidence = pathlib.Path(temporary) / "evidence"
        evidence.mkdir()
        result = subprocess.run(
            [
                sys.executable,
                str(HERE / "x05-nb-live.py"),
                "--recover",
                "--run-hex",
                RUN_HEX,
                "--evidence-dir",
                str(evidence),
            ],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        assert result.returncode == 75, result.stderr
        assert list(evidence.iterdir()) == []


def test_helper_bundle_provenance_gate() -> None:
    with tempfile.TemporaryDirectory(prefix="x05-nb-live-selftest-") as temporary:
        root = pathlib.Path(temporary)
        runner = FakeRunner()
        adapter, _ = _adapter(root, runner)
        guarded = LIVE.NBAdapter(
            run_hex=RUN_HEX,
            evidence_dir=adapter.evidence_dir,
            paths=adapter.paths,
            policy=LIVE.SecurityPolicy(
                require_root=False, require_helper_provenance=True
            ),
            runner=runner,
            lock_validator=FakeLock(),
            _test_enable_live=True,
        )
        try:
            guarded.forward()
        except LIVE.SecurityError as exc:
            assert "helper directory" in str(exc)
        else:
            raise AssertionError("writable helper bundle must be rejected")
        assert runner.calls == []


def test_foreign_journal_rejected_before_live_helper() -> None:
    with tempfile.TemporaryDirectory(prefix="x05-nb-live-selftest-") as temporary:
        root = pathlib.Path(temporary)
        runner = FakeRunner()
        adapter, evidence = _adapter(root, runner)
        (evidence / "journal.json").write_text(
            json.dumps(
                {
                    "schema": LIVE.Journal.SCHEMA,
                    "owner": "labctl-x05-deadbe",
                    "run_hex": "deadbe",
                    "events": [],
                }
            )
            + "\n",
            encoding="utf-8",
        )
        (evidence / "journal.json").chmod(0o600)
        try:
            adapter.forward()
        except LIVE.SecurityError:
            pass
        else:
            raise AssertionError("foreign journal must be rejected")
        assert runner.calls == []


def test_dry_run_has_no_runner_or_filesystem_side_effect() -> None:
    with tempfile.TemporaryDirectory(prefix="x05-nb-live-selftest-") as temporary:
        root = pathlib.Path(temporary)
        before = sorted(root.iterdir())
        result = LIVE.dry_run(RUN_HEX)
        assert result["external_calls"] == "none in dry-run"
        assert sorted(root.iterdir()) == before


def test_inherited_fd9_requires_an_existing_lock() -> None:
    with tempfile.TemporaryDirectory(prefix="x05-nb-live-selftest-") as temporary:
        root = pathlib.Path(temporary).resolve()
        lock = root / "lock"
        lock.write_text("", encoding="utf-8")
        paths = LIVE.RuntimePaths(helper_dir=root, marker=root / "marker", lock=lock)
        old_fd: int | None = None
        try:
            try:
                old_fd = os.dup(LIVE.LOCK_FD)
            except OSError:
                old_fd = None
            held = os.open(lock, os.O_RDWR)
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            os.dup2(held, LIVE.LOCK_FD)
            LIVE.LockValidator(paths).validate()
            fcntl.flock(LIVE.LOCK_FD, fcntl.LOCK_UN)
            try:
                LIVE.LockValidator(paths).validate()
            except LIVE.SecurityError:
                pass
            else:
                raise AssertionError("unlocked FD 9 must be rejected")
            os.close(held)
        finally:
            if old_fd is not None:
                os.dup2(old_fd, LIVE.LOCK_FD)
                os.close(old_fd)
            else:
                try:
                    os.close(LIVE.LOCK_FD)
                except OSError:
                    pass


def main() -> int:
    test_forward_inverse_order()
    test_producer_factory_forward_inverse()
    test_producer_factory_validates_full_central_identity()
    test_producer_factory_canonicalizes_empty_labels_and_captures_actual_image()
    test_central_identity_drift_pre_dispatch_and_after_rpc()
    test_central_identity_rechecks_fixed_helpers_and_intent_publication()
    test_terminal_publication_windows_are_ambiguous()
    test_producer_factory_rejects_noncanonical_capabilities_and_overrides()
    test_producer_factory_rejects_obvious_prefactory_authority_substitution()
    test_producer_factory_rejects_equal_type_prefactory_origins()
    test_producer_factory_rejects_class_callable_substitution()
    test_origin_guard_and_collector_run_shadows_refuse_before_effect()
    test_private_session_helper_shadows_use_original_dispatch()
    test_cleanup_helper_shadows_retain_original_authority()
    test_consumed_helper_loss_stays_sticky_after_restore()
    test_invalid_foreign_and_unconsumed_calls_do_not_poison_execution()
    test_original_producer_authorities_are_pinned_before_effect()
    test_post_effect_authority_substitution_is_ambiguous_and_not_reissued()
    test_canonical_event_authority_rejects_path_retargeting()
    test_event_descriptor_closed_and_recycled_are_rejected_safely()
    test_close_never_targets_a_substituted_event_object()
    test_public_producer_apis_wait_for_original_mutex()
    test_post_effect_event_fsync_drift_is_ambiguous_and_sticky()
    test_adapter_bridge_callable_is_pinned()
    test_producer_result_failures_are_ambiguous_and_not_reissued()
    test_producer_inverse_failure_is_ambiguous_and_not_reissued()
    test_producer_pre_dispatch_drift_has_no_transaction_effect()
    test_producer_post_dispatch_drift_is_ambiguous()
    test_invalid_authority_after_intent_prevents_transaction_dispatch()
    test_timeout_retains_marker_and_journal()
    test_postflight_fail_is_recorded_even_with_zero_exit()
    test_inverse_rejects_tampered_forward_artifact_before_helper()
    test_inverse_rejects_marker_binding_change_before_helper()
    test_preinverse_nonzero_is_recorded_and_stops_before_inverse()
    test_inverse_refuses_unverified_forward_states()
    test_real_helper_fixture_cli_contract()
    test_public_live_cli_is_disabled_before_filesystem_or_runner()
    test_public_recovery_cli_is_disabled_before_filesystem_or_runner()
    test_helper_bundle_provenance_gate()
    test_foreign_journal_rejected_before_live_helper()
    test_dry_run_has_no_runner_or_filesystem_side_effect()
    test_inherited_fd9_requires_an_existing_lock()
    print(
        "X05 NB live selftest PASS: producer/full central identity binding, "
        "drift/output bounds, order, replay binding, fixture CLI, disabled live, "
        "dry-run"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
