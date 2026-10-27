#!/usr/bin/env python3
"""Canonical one-shot coordinator for the admitted P004-S002 X05 experiment."""

from __future__ import annotations

import argparse
import contextlib
import copy
import dataclasses
import datetime as dt
import hashlib
import importlib.util
import json
import math
import os
import pathlib
import re
import secrets
import stat
import struct
import sys
import time
import types
from collections.abc import Callable, Mapping, Sequence
from typing import Any


sys.dont_write_bytecode = True

HERE = pathlib.Path(__file__).resolve().parent
SOURCE_PATH = pathlib.Path(__file__).resolve()
CAPTURE_PATH = HERE / "x05-capture.py"
CAPTURE_MODULE_NAME = "x05_capture_runtime_contract"
EVALUATOR_MODULE_NAME = "x05_evaluator_nb_bridge_contract"
RUNTIME_MODULE_NAME = "x05_runtime_live_evaluator_contract"
SCHEMA = "p004-x05-coordinator-v1"
RESULT_SCHEMA = "p004-x05-execution-result-v1"
DECODE_SCHEMA = "p004-x05-capture-semantics-v1"
EVIDENCE_ROOT = pathlib.Path("/opt/poc-k8s-fabric/evidence/P004/S002")
PRODUCTION_NSENTER = pathlib.Path("/usr/bin/nsenter")
PRODUCTION_PING = pathlib.Path("/usr/bin/ping")
CAS_RELATIVE_PATH = "studies/p004/ovn/x05-cas.sh"
MAX_EVIDENCE_BYTES = 256 * 1024 * 1024
GATE_ATTEMPTS = 12
GATE_IO_BYTES = 16 * 1024 * 1024
GATE_ELAPSED_SECONDS = 180.0
GATE_RETRY_DELAY_SECONDS = 0.25
CAS_ATTEMPTS = 12
CAS_ELAPSED_SECONDS = 90.0
CAS_IO_BYTES = 64 * 1024 * 1024
HEX64_RE = re.compile(r"[0-9a-f]{64}\Z")
RUN_RE = re.compile(r"[0-9a-f]{6}\Z")
SAFE_NAME_RE = re.compile(r"[a-z0-9][a-z0-9_.-]{0,126}\Z")
SOURCE_BY_ROLE = types.MappingProxyType({
    "classic-original": "10.0.0.1",
    "classic-created": "10.0.0.1",
    "evpn-original": "10.250.0.1",
    "evpn-created": "10.251.0.1",
})
RECEIVE_BY_ROLE = types.MappingProxyType({
    "classic-original": (
        ("gateway-300", "bgpvrf100"),
        ("gateway-400", "bgpvrf200"),
    ),
    "classic-created": (
        ("gateway-300", "bgpvrf300"),
        ("gateway-400", "bgpvrf400"),
    ),
    "evpn-original": (("fabric", "__M03_ANCHORED_INTERFACE__"),),
    "evpn-created": (("fabric", "__X05_CREATED_INTERFACE__"),),
})
SENTINEL_IPS = frozenset({"192.168.100.11", "192.168.100.12"})
_COORDINATOR_STATES = (
    "INTENT",
    "BUILT",
    "BASELINE_PROVED",
    "LEAK_PROVED",
    "RESTORED",
)
_FIXED_COORDINATOR_STATES = _COORDINATOR_STATES
_FIXED_SOURCE_BY_ROLE = SOURCE_BY_ROLE
_FIXED_RECEIVE_BY_ROLE = RECEIVE_BY_ROLE
_FIXED_SENTINEL_IPS = SENTINEL_IPS


def _load_capture() -> Any:
    existing = sys.modules.get(CAPTURE_MODULE_NAME)
    if existing is not None:
        if pathlib.Path(getattr(existing, "__file__", "")).resolve() != CAPTURE_PATH:
            raise RuntimeError("canonical X05 capture module path changed")
        return existing
    spec = importlib.util.spec_from_file_location(CAPTURE_MODULE_NAME, CAPTURE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load the reviewed X05 capture module")
    module = importlib.util.module_from_spec(spec)
    sys.modules[CAPTURE_MODULE_NAME] = module
    spec.loader.exec_module(module)
    return module


CAPTURE = _load_capture()
APPLY = CAPTURE.APPLY
NB = APPLY.NB
RUNTIME = APPLY.RUNTIME
EVALUATOR = sys.modules.get(EVALUATOR_MODULE_NAME)
if EVALUATOR is None or EVALUATOR.RUNTIME is not RUNTIME:
    raise RuntimeError("canonical X05 evaluator module graph is unavailable")
if sys.modules.get(RUNTIME_MODULE_NAME) is not RUNTIME:
    raise RuntimeError("canonical X05 runtime producer module graph is unavailable")


class CoordinatorError(RuntimeError):
    """The coordinator cannot prove a safe or meaningful result."""


class CoordinatorSecurityError(CoordinatorError):
    """A source, capability, receiver, or identity binding changed."""


class CoordinatorAmbiguous(CoordinatorError):
    """A dispatched effect has no complete outcome and must not be repeated."""


class GateFailure(CoordinatorError):
    """A complete observation contradicted an experimental gate."""


class PacketError(CoordinatorError):
    """Captured bytes cannot support a semantic claim."""


class InputNotReady(CoordinatorError):
    """A fixed production input is missing before admission begins."""


_SESSION_CONSUME = RUNTIME.AdmissionSession.consume
_SESSION_CLOSE = RUNTIME.AdmissionSession.close
_SESSION_VERIFY = RUNTIME.AdmissionSession.verify_execution
_SESSION_RECORD = RUNTIME.AdmissionSession.record_execution_event
_ADMISSION_SESSION_TYPE = RUNTIME.AdmissionSession
_ADMISSION_CONFIG_TYPE = RUNTIME.AdmissionConfig
_PREPARED_ADMISSION_TYPE = RUNTIME.PreparedAdmission
_COMMAND_RESULT_TYPE = RUNTIME.CommandResult
_LIVE_COLLECTOR_TYPE = RUNTIME.LiveCollector
_SUBPROCESS_RUNNER_TYPE = RUNTIME.SubprocessRunner
_ADMISSION_CONFIG_GETATTRIBUTE = RUNTIME.AdmissionConfig.__getattribute__
_LIVE_COLLECTOR_INIT = RUNTIME.LiveCollector.__init__
_LIVE_COLLECTOR_NEW = RUNTIME.LiveCollector.__new__
_LIVE_COLLECTOR_GETATTRIBUTE = RUNTIME.LiveCollector.__getattribute__
_COLLECTOR_VALIDATE_RECEIPT = RUNTIME.LiveCollector.validate_receipt
_SUBPROCESS_RUNNER_INIT = RUNTIME.SubprocessRunner.__init__
_SUBPROCESS_RUNNER_NEW = RUNTIME.SubprocessRunner.__new__
_SUBPROCESS_RUNNER_GETATTRIBUTE = RUNTIME.SubprocessRunner.__getattribute__
_SUBPROCESS_RUNNER_RUN = RUNTIME.SubprocessRunner.run
_RUNTIME_BUILDER_TYPE = APPLY.RuntimeBuilder
_CAPTURE_SESSION_TYPE = CAPTURE.CaptureSession
_BUILDER_FROM_ADMISSION = APPLY.RuntimeBuilder.from_admission.__func__
_BUILDER_BUILD = APPLY.RuntimeBuilder.build
_BUILDER_COMPENSATE = APPLY.RuntimeBuilder.compensate
_BUILDER_FINAL_ABSENCE = APPLY.RuntimeBuilder.verify_final_absence
_BUILDER_TERMINAL = APPLY.RuntimeBuilder._finalize_x05_cleanup
_BUILDER_LINK_READ = APPLY.RuntimeBuilder._link_read
_BUILDER_ADDRESS_READ = APPLY.RuntimeBuilder._address_read
_CAPTURE_FROM_BUILDER = CAPTURE.CaptureSession.from_builder.__func__
_CAPTURE_START = CAPTURE.CaptureSession.start
_CAPTURE_HEALTH = CAPTURE.CaptureSession.health
_CAPTURE_STOP = CAPTURE.CaptureSession.stop
_CAPTURE_READ = CAPTURE.CaptureSession._read_owned_pcaps
_EVALUATOR_COLLECT = EVALUATOR.collect_fixed_commands
_EVALUATOR_G1_COMMANDS = EVALUATOR.g1_commands
_EVALUATOR_G1 = EVALUATOR.evaluate_g1_samples
_EVALUATOR_G2_COMMANDS = EVALUATOR.g2_commands
_EVALUATOR_G2 = EVALUATOR.evaluate_g2_samples
_EVALUATOR_POLL = EVALUATOR.poll_retries
_EVALUATOR_PING = EVALUATOR.evaluate_ping
_EVALUATOR_CAS = EVALUATOR.evaluate_cas_postcondition
_EVALUATOR_PARSE_OVS = EVALUATOR.parse_ovs_rows
_EVALUATOR_FAILED = EVALUATOR.failed
_EVALUATION_TYPE = EVALUATOR.Evaluation
_POLL_BUDGET_TYPE = EVALUATOR.PollBudget
_ITERATION_REPORT_TYPE = EVALUATOR.IterationReport
_CAS_BASELINE_TYPE = EVALUATOR.CASBaseline
_CAS_OBSERVATION_TYPE = EVALUATOR.CASObservation
_OUTCOME_TYPE = EVALUATOR.Outcome
_CAS_STAGE_TYPE = EVALUATOR.CASStage
_G1_TOPOLOGY_TYPE = EVALUATOR.G1Topology
_G2_TOPOLOGY_TYPE = EVALUATOR.G2Topology
_CAPTURE_POINT_IDS = APPLY.CAPTURE_POINT_IDS
_APPLY_FSYNC_DIRECTORY = APPLY._fsync_directory
_RUNTIME_BASE_ENV_OBJECT = RUNTIME.BASE_ENV
_BASE_ENV = types.MappingProxyType(dict(RUNTIME.BASE_ENV))
_RUNTIME_MAX_OUTPUT = RUNTIME.MAX_OUTPUT
_UUID_RE = EVALUATOR.UUID_RE


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
        raise CoordinatorSecurityError("value is not bounded canonical JSON") from exc


def _sha256(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def _digest(value: Any) -> str:
    return _sha256(_canonical(value))


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
    maximum: int,
    uid: int | None = None,
    mode: int | None = None,
) -> tuple[bytes, tuple[int, ...]]:
    try:
        before = path.lstat()
    except OSError as exc:
        raise CoordinatorSecurityError("required source is unavailable: " + str(path)) from exc
    if (
        stat.S_ISLNK(before.st_mode)
        or not stat.S_ISREG(before.st_mode)
        or before.st_size > maximum
        or (uid is not None and before.st_uid != uid)
        or (mode is not None and stat.S_IMODE(before.st_mode) != mode)
    ):
        raise CoordinatorSecurityError("required source identity is unsafe: " + str(path))
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor: int | None = None
    try:
        descriptor = os.open(path, flags)
        opened = os.fstat(descriptor)
        if _identity(opened) != _identity(before):
            raise CoordinatorSecurityError("required source changed while opening: " + str(path))
        chunks: list[bytes] = []
        size = 0
        while True:
            chunk = os.read(descriptor, min(65536, maximum + 1 - size))
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
            if size > maximum:
                raise CoordinatorSecurityError("required source exceeds its bound: " + str(path))
        after = os.fstat(descriptor)
    except OSError as exc:
        raise CoordinatorSecurityError("required source read failed: " + str(path)) from exc
    finally:
        if descriptor is not None:
            os.close(descriptor)
    if _identity(after) != _identity(before):
        raise CoordinatorSecurityError("required source changed while reading: " + str(path))
    return b"".join(chunks), _identity(after)


def _require_method(owner: Any, name: str, implementation: Any, context: str) -> types.MethodType:
    try:
        method = getattr(owner, name)
        shadowed = name in vars(owner)
    except Exception as exc:
        raise CoordinatorSecurityError(context + " is unavailable") from exc
    if (
        type(method) is not types.MethodType
        or method.__self__ is not owner
        or method.__func__ is not implementation
        or shadowed
    ):
        raise CoordinatorSecurityError(context + " implementation changed")
    return method


def _result_detail(result: Any, argv: tuple[str, ...]) -> dict[str, Any]:
    if (
        type(result) is not _COMMAND_RESULT_TYPE
        or type(result.argv) is not tuple
        or result.argv != argv
        or type(result.returncode) is not int
        or type(result.stdout) is not bytes
        or type(result.stderr) is not bytes
        or type(result.elapsed) not in (int, float)
        or not math.isfinite(result.elapsed)
        or result.elapsed < 0
        or len(result.stdout) + len(result.stderr) > _RUNTIME_MAX_OUTPUT
    ):
        raise CoordinatorAmbiguous("runner returned an incomplete or foreign result")
    return {
        "argv": list(argv),
        "argv_sha256": _digest(list(argv)),
        "returncode": result.returncode,
        "stdout_sha256": _sha256(result.stdout),
        "stderr_sha256": _sha256(result.stderr),
        "stdout_bytes": len(result.stdout),
        "stderr_bytes": len(result.stderr),
        "elapsed_seconds": float(result.elapsed),
    }


def _evaluation(value: Any) -> dict[str, Any]:
    if type(value) is not _EVALUATION_TYPE:
        raise CoordinatorSecurityError("evaluator returned a foreign result")
    return {
        "outcome": value.outcome.value,
        "reason": value.reason,
        "facts": copy.deepcopy(dict(value.facts)),
        "proof_kind": value.proof_kind.value,
        "authoritative_x05_pass": value.facts.get("authoritative_x05_pass") is True,
    }


class _Evidence:
    def __init__(self, directory: pathlib.Path, uid: int) -> None:
        self.directory = directory
        self.uid = uid
        info = directory.lstat()
        if (
            stat.S_ISLNK(info.st_mode)
            or not stat.S_ISDIR(info.st_mode)
            or info.st_uid != uid
            or stat.S_IMODE(info.st_mode) != 0o700
        ):
            raise CoordinatorSecurityError("coordinator evidence directory is not private")
        self._files: dict[str, dict[str, Any]] = {}
        self._bytes = 0

    def write(self, name: str, raw: bytes) -> dict[str, Any]:
        if (
            type(name) is not str
            or SAFE_NAME_RE.fullmatch(name) is None
            or type(raw) is not bytes
            or self._bytes + len(raw) > MAX_EVIDENCE_BYTES
            or name in self._files
        ):
            raise CoordinatorSecurityError("coordinator evidence publication is invalid")
        path = self.directory / name
        flags = (
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
        descriptor: int | None = None
        try:
            descriptor = os.open(path, flags, 0o600)
            info = os.fstat(descriptor)
            if info.st_uid != self.uid or stat.S_IMODE(info.st_mode) != 0o600:
                raise CoordinatorSecurityError("new coordinator evidence is not private")
            view = memoryview(raw)
            while view:
                written = os.write(descriptor, view)
                if written <= 0:
                    raise CoordinatorSecurityError("coordinator evidence write was short")
                view = view[written:]
            os.fsync(descriptor)
        finally:
            if descriptor is not None:
                os.close(descriptor)
        _APPLY_FSYNC_DIRECTORY(self.directory)
        current, identity = _read_regular(
            path, maximum=max(1, len(raw)), uid=self.uid, mode=0o600
        )
        if current != raw:
            raise CoordinatorSecurityError("coordinator evidence readback changed")
        binding = {
            "path": str(path),
            "sha256": _sha256(raw),
            "bytes": len(raw),
            "identity": list(identity),
        }
        self._files[name] = copy.deepcopy(binding)
        self._bytes += len(raw)
        return binding

    def json(self, name: str, value: Any) -> dict[str, Any]:
        return self.write(name, _canonical(value))

    def command(self, prefix: str, result: Any, argv: tuple[str, ...]) -> dict[str, Any]:
        detail = _result_detail(result, argv)
        stdout = self.write(prefix + ".stdout", result.stdout)
        stderr = self.write(prefix + ".stderr", result.stderr)
        metadata = self.json(
            prefix + ".json",
            {**detail, "stdout": stdout, "stderr": stderr},
        )
        return {**detail, "metadata": metadata, "stdout": stdout, "stderr": stderr}

    def manifest(self) -> dict[str, Any]:
        return {
            "schema": "p004-x05-coordinator-evidence-v1",
            "files": copy.deepcopy(dict(sorted(self._files.items()))),
        }


class _CoordinatorEvents:
    """Append the one-shot coordinator chain to the original admission log."""

    def __init__(
        self,
        *,
        session: Any,
        prepared: Any,
        evidence: _Evidence,
        source_guard: Callable[[], None],
    ) -> None:
        self.session = session
        self.prepared = prepared
        self.evidence = evidence
        self.source_guard = source_guard
        self._state_index = -1
        self._attempts = 0
        self._failed = False
        self._records: list[dict[str, Any]] = []

    def _append(
        self,
        *,
        label: str,
        event: str,
        detail: Mapping[str, Any],
    ) -> dict[str, Any]:
        if self._failed:
            raise CoordinatorSecurityError("coordinator event chain is sticky-failed")
        if SAFE_NAME_RE.fullmatch(label) is None or type(detail) is not dict:
            raise CoordinatorSecurityError("coordinator event input is invalid")
        self._attempts += 1
        before_head = self.prepared._event_head
        before_count = self.prepared._event_count
        detached = copy.deepcopy(detail)
        try:
            self.source_guard()
            record = _SESSION_RECORD(self.session, self.prepared, event, detached)
            _SESSION_VERIFY(self.session, self.prepared)
            if (
                type(record) is not dict
                or record.get("event") != event
                or record.get("sequence") != before_count + 1
                or record.get("previous_sha256") != before_head
                or record.get("event_sha256") != self.prepared._event_head
                or self.prepared._event_count != before_count + 1
                or record.get("detail", {}).get("detail") != detached
                or not isinstance(record.get("event_sha256"), str)
                or HEX64_RE.fullmatch(record["event_sha256"]) is None
            ):
                raise CoordinatorSecurityError(
                    "producer returned an inconsistent coordinator event"
                )
            self.evidence.json(
                "coordinator-event-%02d-%s.json" % (self._attempts, label),
                record,
            )
        except BaseException:
            self._failed = True
            raise
        summary = {
            "event": event,
            "label": label,
            "sequence": record["sequence"],
            "event_sha256": record["event_sha256"],
            "detail_sha256": _digest(detached),
        }
        self._records.append(summary)
        return copy.deepcopy(summary)

    def state(self, state: str, detail: Mapping[str, Any]) -> dict[str, Any]:
        expected_index = self._state_index + 1
        if (
            expected_index >= len(_COORDINATOR_STATES)
            or state != _COORDINATOR_STATES[expected_index]
            or "state" in detail
        ):
            raise CoordinatorSecurityError("coordinator state progression changed")
        result = self._append(
            label="state-" + state.lower().replace("_", "-"),
            event="x05-coordinator-state",
            detail={**copy.deepcopy(dict(detail)), "state": state},
        )
        self._state_index = expected_index
        return result

    def event(
        self,
        label: str,
        event: str,
        detail: Mapping[str, Any],
    ) -> dict[str, Any]:
        return self._append(label=label, event=event, detail=detail)

    def detached(self) -> list[dict[str, Any]]:
        return copy.deepcopy(self._records)


@dataclasses.dataclass(frozen=True)
class ExecutionResult:
    status: str
    verdict: str
    gates: Mapping[str, Any]
    cleanup: Mapping[str, Any]
    evidence: Mapping[str, Any]
    errors: tuple[str, ...]
    authorizes_mutation: bool = False
    schema: str = RESULT_SCHEMA

    def detached(self) -> dict[str, Any]:
        return {
            "schema": self.schema,
            "status": self.status,
            "verdict": self.verdict,
            "gates": copy.deepcopy(dict(self.gates)),
            "cleanup": copy.deepcopy(dict(self.cleanup)),
            "evidence": copy.deepcopy(dict(self.evidence)),
            "errors": list(self.errors),
            "authorizes_mutation": self.authorizes_mutation,
        }


@dataclasses.dataclass(frozen=True)
class _SourceBinding:
    path: pathlib.Path
    identity: tuple[int, ...]
    sha256: str


_RUNTIME_SOURCE_RELATIVE_PATH = "studies/p004/ovn/x05-runtime-live.py"
_SOURCE_RELATIVE_PATHS = (
    _RUNTIME_SOURCE_RELATIVE_PATH,
    "studies/p004/ovn/x05-evaluator.py",
    "studies/p004/ovn/x05-nb-live.py",
    "studies/p004/ovn/x05-runtime-apply.py",
    "studies/p004/ovn/x05-capture.py",
    "studies/p004/ovn/x05-coordinator.py",
    CAS_RELATIVE_PATH,
)
_FIXED_SOURCE_RELATIVE_PATHS = _SOURCE_RELATIVE_PATHS


@dataclasses.dataclass(frozen=True)
class _CapturedSourceBindings:
    sources: Mapping[str, _SourceBinding]
    receipt: _SourceBinding


def _assert_receipt_collector_binding(
    config: Any, runner: Any, collector: Any
) -> None:
    if type(config) is not _ADMISSION_CONFIG_TYPE:
        raise CoordinatorSecurityError("canonical receipt config is unavailable")
    if (
        type(runner) is not _SUBPROCESS_RUNNER_TYPE
        or type(collector) is not _LIVE_COLLECTOR_TYPE
    ):
        raise CoordinatorSecurityError("canonical receipt collector objects are unavailable")
    try:
        collector_config = object.__getattribute__(collector, "config")
        collector_runner = object.__getattribute__(collector, "runner")
    except AttributeError as exc:
        raise CoordinatorSecurityError(
            "canonical receipt collector object path is incomplete"
        ) from exc
    if collector_config is not config:
        raise CoordinatorSecurityError("preflight receipt collector configuration was redirected")
    if collector_runner is not runner:
        raise CoordinatorSecurityError("preflight receipt collector runner was redirected")


def _validated_receipt_binding(config: Any) -> tuple[_SourceBinding, str]:
    _verify_graph()
    if type(config) is not _ADMISSION_CONFIG_TYPE:
        raise CoordinatorSecurityError("canonical receipt config is unavailable")
    receipt_path = pathlib.Path(object.__getattribute__(config, "receipt_path"))
    required_uid = object.__getattribute__(config, "required_uid")
    raw_before, identity_before = _read_regular(
        receipt_path,
        maximum=64 * 1024,
        uid=required_uid,
        mode=0o600,
    )
    runner = _SUBPROCESS_RUNNER_TYPE()
    if type(runner) is not _SUBPROCESS_RUNNER_TYPE:
        raise CoordinatorSecurityError("canonical receipt runner is unavailable")
    collector = _LIVE_COLLECTOR_TYPE(config, runner)
    _verify_graph()
    if (
        type(collector) is not _LIVE_COLLECTOR_TYPE
        or "validate_receipt" in vars(collector)
        or not callable(_COLLECTOR_VALIDATE_RECEIPT)
    ):
        raise CoordinatorSecurityError("canonical receipt validator is unavailable")
    _assert_receipt_collector_binding(config, runner, collector)
    fields = _COLLECTOR_VALIDATE_RECEIPT(collector)
    _verify_graph()
    _assert_receipt_collector_binding(config, runner, collector)
    if pathlib.Path(object.__getattribute__(config, "receipt_path")) != receipt_path:
        raise CoordinatorSecurityError("preflight receipt path changed during validation")
    raw_after, identity_after = _read_regular(
        receipt_path,
        maximum=64 * 1024,
        uid=required_uid,
        mode=0o600,
    )
    if raw_before != raw_after or identity_before != identity_after:
        raise CoordinatorSecurityError("preflight receipt changed while being captured")
    runtime_sha256 = fields.get("runtime_source_sha256")
    if not isinstance(runtime_sha256, str) or HEX64_RE.fullmatch(runtime_sha256) is None:
        raise CoordinatorSecurityError("preflight receipt runtime source pin is invalid")
    return _SourceBinding(receipt_path, identity_after, _sha256(raw_after)), runtime_sha256


def _capture_source_bindings(config: Any) -> _CapturedSourceBindings:
    _verify_graph()
    receipt_binding, runtime_sha256 = _validated_receipt_binding(config)
    bindings: dict[str, _SourceBinding] = {}
    for relative in _SOURCE_RELATIVE_PATHS:
        expected = (
            runtime_sha256
            if relative == _RUNTIME_SOURCE_RELATIVE_PATH
            else RUNTIME.REVIEWED_BUNDLE_FILES.get(relative)
        )
        if not isinstance(expected, str) or HEX64_RE.fullmatch(expected) is None:
            raise CoordinatorSecurityError("coordinator source lacks reviewed pin: " + relative)
        path = config.bundle_root / relative
        raw, identity = _read_regular(path, maximum=16 * 1024 * 1024, uid=config.required_uid)
        if stat.S_IMODE(identity[5]) & 0o022 or _sha256(raw) != expected:
            raise CoordinatorSecurityError("coordinator source differs from reviewed pin: " + relative)
        bindings[relative] = _SourceBinding(path, identity, expected)
    loaded = {
        "studies/p004/ovn/x05-runtime-live.py": RUNTIME,
        "studies/p004/ovn/x05-evaluator.py": EVALUATOR,
        "studies/p004/ovn/x05-nb-live.py": NB,
        "studies/p004/ovn/x05-runtime-apply.py": APPLY,
        "studies/p004/ovn/x05-capture.py": CAPTURE,
        "studies/p004/ovn/x05-coordinator.py": sys.modules.get(__name__),
    }
    for relative, module in loaded.items():
        if module is None or pathlib.Path(getattr(module, "__file__", "")).resolve() != bindings[relative].path.resolve():
            raise CoordinatorSecurityError("loaded coordinator module path changed: " + relative)
    return _CapturedSourceBindings(types.MappingProxyType(bindings), receipt_binding)


def _verify_source_bindings(bindings: _CapturedSourceBindings, config: Any) -> None:
    if type(bindings) is not _CapturedSourceBindings or set(bindings.sources) != set(_SOURCE_RELATIVE_PATHS):
        raise CoordinatorSecurityError("captured coordinator source set changed")
    receipt_binding, runtime_sha256 = _validated_receipt_binding(config)
    if (
        receipt_binding != bindings.receipt
        or runtime_sha256 != bindings.sources[_RUNTIME_SOURCE_RELATIVE_PATH].sha256
    ):
        raise CoordinatorSecurityError("preflight receipt source binding changed")
    for relative in _SOURCE_RELATIVE_PATHS:
        binding = bindings.sources[relative]
        expected_path = config.bundle_root / relative
        if binding.path.resolve() != expected_path.resolve():
            raise CoordinatorSecurityError("reviewed coordinator source path changed: " + relative)
        raw, identity = _read_regular(binding.path, maximum=16 * 1024 * 1024, uid=config.required_uid)
        if identity != binding.identity or _sha256(raw) != binding.sha256:
            raise CoordinatorSecurityError("reviewed coordinator source changed: " + relative)


def _verify_graph() -> None:
    if (
        RUNTIME.AdmissionSession is not _ADMISSION_SESSION_TYPE
        or RUNTIME.AdmissionConfig is not _ADMISSION_CONFIG_TYPE
        or RUNTIME.PreparedAdmission is not _PREPARED_ADMISSION_TYPE
        or RUNTIME.CommandResult is not _COMMAND_RESULT_TYPE
        or RUNTIME.LiveCollector is not _LIVE_COLLECTOR_TYPE
        or RUNTIME.SubprocessRunner is not _SUBPROCESS_RUNNER_TYPE
        or type(_ADMISSION_CONFIG_TYPE) is not type
        or _ADMISSION_CONFIG_TYPE.__getattribute__ is not _ADMISSION_CONFIG_GETATTRIBUTE
        or not isinstance(_LIVE_COLLECTOR_TYPE, type)
        or not isinstance(_SUBPROCESS_RUNNER_TYPE, type)
        or type(_LIVE_COLLECTOR_TYPE) is not type
        or type(_SUBPROCESS_RUNNER_TYPE) is not type
        or _LIVE_COLLECTOR_TYPE.__init__ is not _LIVE_COLLECTOR_INIT
        or _LIVE_COLLECTOR_TYPE.__new__ is not _LIVE_COLLECTOR_NEW
        or _LIVE_COLLECTOR_TYPE.__getattribute__ is not _LIVE_COLLECTOR_GETATTRIBUTE
        or not callable(_COLLECTOR_VALIDATE_RECEIPT)
        or _LIVE_COLLECTOR_TYPE.validate_receipt is not _COLLECTOR_VALIDATE_RECEIPT
        or _SUBPROCESS_RUNNER_TYPE.__init__ is not _SUBPROCESS_RUNNER_INIT
        or _SUBPROCESS_RUNNER_TYPE.__new__ is not _SUBPROCESS_RUNNER_NEW
        or _SUBPROCESS_RUNNER_TYPE.__getattribute__ is not _SUBPROCESS_RUNNER_GETATTRIBUTE
        or _SUBPROCESS_RUNNER_TYPE.run is not _SUBPROCESS_RUNNER_RUN
        or APPLY.RuntimeBuilder is not _RUNTIME_BUILDER_TYPE
        or CAPTURE.CaptureSession is not _CAPTURE_SESSION_TYPE
        or CAPTURE.APPLY is not APPLY
        or APPLY.NB is not NB
        or APPLY.RUNTIME is not RUNTIME
        or NB.RUNTIME is not RUNTIME
        or EVALUATOR.RUNTIME is not RUNTIME
        or sys.modules.get(CAPTURE_MODULE_NAME) is not CAPTURE
        or sys.modules.get(EVALUATOR_MODULE_NAME) is not EVALUATOR
        or sys.modules.get(RUNTIME_MODULE_NAME) is not RUNTIME
        or CAPTURE.CaptureSession.from_builder.__func__ is not _CAPTURE_FROM_BUILDER
        or APPLY.RuntimeBuilder.from_admission.__func__ is not _BUILDER_FROM_ADMISSION
        or RUNTIME.AdmissionSession.consume is not _SESSION_CONSUME
        or RUNTIME.AdmissionSession.close is not _SESSION_CLOSE
        or RUNTIME.AdmissionSession.verify_execution is not _SESSION_VERIFY
        or RUNTIME.AdmissionSession.record_execution_event is not _SESSION_RECORD
        or APPLY.RuntimeBuilder.build is not _BUILDER_BUILD
        or APPLY.RuntimeBuilder.compensate is not _BUILDER_COMPENSATE
        or APPLY.RuntimeBuilder.verify_final_absence is not _BUILDER_FINAL_ABSENCE
        or APPLY.RuntimeBuilder._finalize_x05_cleanup is not _BUILDER_TERMINAL
        or APPLY.RuntimeBuilder._link_read is not _BUILDER_LINK_READ
        or APPLY.RuntimeBuilder._address_read is not _BUILDER_ADDRESS_READ
        or CAPTURE.CaptureSession.start is not _CAPTURE_START
        or CAPTURE.CaptureSession.health is not _CAPTURE_HEALTH
        or CAPTURE.CaptureSession.stop is not _CAPTURE_STOP
        or CAPTURE.CaptureSession._read_owned_pcaps is not _CAPTURE_READ
        or EVALUATOR.collect_fixed_commands is not _EVALUATOR_COLLECT
        or EVALUATOR.poll_retries is not _EVALUATOR_POLL
        or EVALUATOR.g1_commands is not _EVALUATOR_G1_COMMANDS
        or EVALUATOR.evaluate_g1_samples is not _EVALUATOR_G1
        or EVALUATOR.g2_commands is not _EVALUATOR_G2_COMMANDS
        or EVALUATOR.evaluate_g2_samples is not _EVALUATOR_G2
        or EVALUATOR.evaluate_ping is not _EVALUATOR_PING
        or EVALUATOR.evaluate_cas_postcondition is not _EVALUATOR_CAS
        or EVALUATOR.parse_ovs_rows is not _EVALUATOR_PARSE_OVS
        or EVALUATOR.failed is not _EVALUATOR_FAILED
        or EVALUATOR.Evaluation is not _EVALUATION_TYPE
        or EVALUATOR.PollBudget is not _POLL_BUDGET_TYPE
        or EVALUATOR.IterationReport is not _ITERATION_REPORT_TYPE
        or EVALUATOR.CASBaseline is not _CAS_BASELINE_TYPE
        or EVALUATOR.CASObservation is not _CAS_OBSERVATION_TYPE
        or EVALUATOR.Outcome is not _OUTCOME_TYPE
        or EVALUATOR.CASStage is not _CAS_STAGE_TYPE
        or EVALUATOR.G1Topology is not _G1_TOPOLOGY_TYPE
        or EVALUATOR.G2Topology is not _G2_TOPOLOGY_TYPE
        or APPLY.CAPTURE_POINT_IDS is not _CAPTURE_POINT_IDS
        or APPLY._fsync_directory is not _APPLY_FSYNC_DIRECTORY
        or RUNTIME.BASE_ENV is not _RUNTIME_BASE_ENV_OBJECT
        or RUNTIME.BASE_ENV != dict(_BASE_ENV)
        or RUNTIME.MAX_OUTPUT != _RUNTIME_MAX_OUTPUT
        or EVALUATOR.UUID_RE is not _UUID_RE
        or WINDOW_PLAN is not _FIXED_WINDOW_PLAN
        or _COORDINATOR_STATES is not _FIXED_COORDINATOR_STATES
        or SOURCE_BY_ROLE is not _FIXED_SOURCE_BY_ROLE
        or RECEIVE_BY_ROLE is not _FIXED_RECEIVE_BY_ROLE
        or SENTINEL_IPS is not _FIXED_SENTINEL_IPS
        or _SOURCE_RELATIVE_PATHS is not _FIXED_SOURCE_RELATIVE_PATHS
    ):
        raise CoordinatorSecurityError("canonical X05 module or callable graph changed")


def _poll_gate(
    *,
    name: str,
    runner: Any,
    commands: Mapping[str, Any],
    evaluate: Callable[[Any], Any],
    evidence: _Evidence,
    command_timeout: float,
    source_guard: Callable[[], None],
) -> dict[str, Any]:
    budget = _POLL_BUDGET_TYPE(
        max_attempts=GATE_ATTEMPTS,
        max_io_bytes=GATE_IO_BYTES,
        per_attempt_timeout=min(float(command_timeout), 15.0),
    )
    started = time.monotonic()

    def check(attempt: int, remaining: int, per_attempt: float) -> Any:
        source_guard()
        elapsed = time.monotonic() - started
        remaining_elapsed = GATE_ELAPSED_SECONDS - elapsed
        if remaining_elapsed <= 0:
            return _ITERATION_REPORT_TYPE(
                _EVALUATOR_FAILED(name + " elapsed poll budget exhausted"), 0
            )
        collection = _EVALUATOR_COLLECT(
            runner,
            commands,
            timeout=min(per_attempt, remaining_elapsed),
            io_budget=min(remaining, _RUNTIME_MAX_OUTPUT),
        )
        for query, sample in collection.samples.items():
            prefix = "%s-attempt-%02d-%s" % (
                name.lower(),
                attempt,
                query.replace("_", "-").replace(".", "-"),
            )
            evidence.write(prefix + ".stdout", sample.stdout)
            evidence.write(prefix + ".stderr", sample.stderr)
            evidence.json(
                prefix + ".json",
                {
                    "query": query,
                    "source_id": sample.source_id,
                    "argv": list(sample.argv),
                    "returncode": sample.returncode,
                    "elapsed_seconds": sample.elapsed,
                    "complete": sample.envelope.complete,
                    "origin": sample.envelope.origin.value,
                    "stdout_sha256": _sha256(sample.stdout),
                    "stderr_sha256": _sha256(sample.stderr),
                },
            )
        result = collection.error if collection.error is not None else evaluate(collection)
        evidence.json(
            "%s-attempt-%02d-evaluation.json" % (name.lower(), attempt),
            {"evaluation": _evaluation(result), "io_bytes": collection.io_bytes},
        )
        if (
            result.outcome is EVALUATOR.Outcome.RETRY
            and attempt < budget.max_attempts
            and time.monotonic() - started < GATE_ELAPSED_SECONDS
        ):
            time.sleep(GATE_RETRY_DELAY_SECONDS)
        return _ITERATION_REPORT_TYPE(result, collection.io_bytes)

    report = _EVALUATOR_POLL(check, budget)
    result = {
        "evaluation": _evaluation(report.evaluation),
        "attempts": report.attempts,
        "io_bytes": report.io_bytes,
        "elapsed_seconds": time.monotonic() - started,
        "budget": {
            "max_attempts": budget.max_attempts,
            "max_io_bytes": budget.max_io_bytes,
            "per_attempt_timeout": budget.per_attempt_timeout,
            "max_elapsed_seconds": GATE_ELAPSED_SECONDS,
        },
    }
    evidence.json(name.lower() + "-poll-final.json", result)
    return result


@dataclasses.dataclass(frozen=True)
class _ToolPin:
    name: str
    path: pathlib.Path
    descriptor: int
    identity: tuple[int, ...]
    sha256: str
    version: str


@dataclasses.dataclass(frozen=True)
class _WindowPlan:
    gate: str
    role: str
    destination: str
    expect_reply: bool
    intended_tap: str
    vni: int


@dataclasses.dataclass(frozen=True)
class _ProbeWindow:
    ordinal: int
    gate: str
    role: str
    source: str
    destination: str
    expect_reply: bool
    intended_tap: str
    vni: int
    pattern_hex: str
    started_at_ns: int
    finished_at_ns: int
    started_monotonic_ns: int
    finished_monotonic_ns: int
    started_at_utc: str
    finished_at_utc: str
    source_before: Mapping[str, Any]
    source_after: Mapping[str, Any]
    route_before: Mapping[str, Any]
    ping: Mapping[str, Any]
    route_after: Mapping[str, Any]
    health_before: Mapping[str, Any]
    health_after: Mapping[str, Any]

    def detached(self) -> dict[str, Any]:
        return dataclasses.asdict(self)


WINDOW_PLAN = (
    _WindowPlan("G3", "classic-original", "192.168.100.11", True, "a", 50100),
    _WindowPlan("G3", "classic-created", "192.168.100.12", True, "b", 50200),
    _WindowPlan("G3", "classic-original", "192.168.100.12", False, "b", 50200),
    _WindowPlan("G3", "classic-created", "192.168.100.11", False, "a", 50100),
    _WindowPlan("G3", "evpn-original", "192.168.100.11", True, "a", 50100),
    _WindowPlan("G3", "evpn-created", "192.168.100.12", True, "b", 50200),
    _WindowPlan("G3", "evpn-original", "192.168.100.12", False, "b", 50200),
    _WindowPlan("G3", "evpn-created", "192.168.100.11", False, "a", 50100),
    _WindowPlan("G5", "classic-original", "192.168.100.12", True, "b", 50100),
    _WindowPlan("G5", "classic-created", "192.168.100.12", False, "b", 50200),
    _WindowPlan("G6", "classic-original", "192.168.100.12", False, "b", 50200),
    _WindowPlan("G6", "classic-created", "192.168.100.12", True, "b", 50200),
)
_FIXED_WINDOW_PLAN = WINDOW_PLAN


class _ProbeSession:
    def __init__(
        self,
        *,
        builder: Any,
        capture: Any,
        evidence: _Evidence,
        source_guard: Callable[[], None],
    ) -> None:
        if type(builder) is not _RUNTIME_BUILDER_TYPE or type(capture) is not _CAPTURE_SESSION_TYPE:
            raise CoordinatorSecurityError("probe requires canonical builder and capture")
        if builder._capture_session is not capture or capture._builder is not builder:
            raise CoordinatorSecurityError("probe builder/capture receiver changed")
        self.builder = builder
        self.capture = capture
        self.evidence = evidence
        self.source_guard = source_guard
        self.runner = builder._runner
        self.config = builder._config
        contract = builder._capture_contract
        if not isinstance(contract, dict) or contract is not capture._contract:
            raise CoordinatorSecurityError("probe capture contract is unavailable")
        sources = contract.get("sources")
        if (
            not isinstance(sources, list)
            or [item.get("id") for item in sources] != [
                "classic-original",
                "classic-created",
                "evpn-original",
                "evpn-created",
            ]
            or any(
                item.get("source") != SOURCE_BY_ROLE.get(item.get("id"))
                for item in sources
            )
        ):
            raise CoordinatorSecurityError("probe source inventory changed")
        self.sources = {item["id"]: copy.deepcopy(item) for item in sources}
        self._tools = self._pin_tools()
        self._windows: list[_ProbeWindow] = []

    def _pin_tool(self, name: str, path: pathlib.Path, version_argv: tuple[str, ...]) -> _ToolPin:
        canonical = pathlib.Path(os.path.realpath(path))
        if not self.config.test_only_paths and canonical != path:
            raise CoordinatorSecurityError(name + " path is not canonical")
        ancestor = canonical.parent
        while True:
            directory = ancestor.lstat()
            if (
                stat.S_ISLNK(directory.st_mode)
                or not stat.S_ISDIR(directory.st_mode)
                or directory.st_uid != self.config.required_uid
                or stat.S_IMODE(directory.st_mode) & 0o022
            ):
                raise CoordinatorSecurityError(name + " executable parent is unsafe")
            if ancestor == ancestor.parent:
                break
            ancestor = ancestor.parent
        raw, identity = _read_regular(canonical, maximum=16 * 1024 * 1024, uid=self.config.required_uid)
        if (
            not stat.S_ISREG(identity[5])
            or stat.S_IMODE(identity[5]) & 0o022
            or not stat.S_IMODE(identity[5]) & 0o100
        ):
            raise CoordinatorSecurityError(name + " executable mode is unsafe")
        descriptor = os.open(
            canonical,
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        )
        try:
            if _identity(os.fstat(descriptor)) != identity:
                raise CoordinatorSecurityError(name + " executable changed while pinning")
            result = self.runner.run(
                version_argv,
                env=_BASE_ENV,
                timeout=min(2.0, self.config.command_timeout),
                pass_fds=(),
                max_output_bytes=64 * 1024,
            )
            detail = _result_detail(result, version_argv)
            if result.returncode != 0 or not result.stdout + result.stderr:
                raise CoordinatorSecurityError(name + " version probe failed")
            version = (result.stdout + result.stderr).decode("utf-8", "strict").strip()
            self.evidence.command("probe-tool-" + name, result, version_argv)
        except BaseException:
            os.close(descriptor)
            raise
        return _ToolPin(name, canonical, descriptor, identity, _sha256(raw), version)

    def _pin_tools(self) -> dict[str, _ToolPin]:
        if self.config.test_only_paths:
            raise CoordinatorSecurityError("probe tool pinning has no production test override")
        pins: dict[str, _ToolPin] = {}
        try:
            pins["nsenter"] = self._pin_tool(
                "nsenter", PRODUCTION_NSENTER, (str(PRODUCTION_NSENTER), "--version")
            )
            pins["ping"] = self._pin_tool(
                "ping", PRODUCTION_PING, (str(PRODUCTION_PING), "-V")
            )
            self.evidence.json(
                "probe-tools.json",
                {
                    name: {
                        "path": str(pin.path),
                        "identity": list(pin.identity),
                        "sha256": pin.sha256,
                        "version": pin.version,
                    }
                    for name, pin in sorted(pins.items())
                },
            )
        except BaseException:
            for pin in pins.values():
                with contextlib.suppress(OSError):
                    os.close(pin.descriptor)
            raise
        return pins

    def close(self) -> None:
        failure: BaseException | None = None
        for pin in self._tools.values():
            try:
                current = _identity(os.fstat(pin.descriptor))
            except BaseException as exc:
                if failure is None:
                    failure = exc
                continue
            if current != pin.identity:
                if failure is None:
                    failure = CoordinatorSecurityError(
                        pin.name + " descriptor changed"
                    )
                continue
            try:
                os.close(pin.descriptor)
            except BaseException as exc:
                if failure is None:
                    failure = exc
        self._tools = {}
        if failure is not None:
            raise CoordinatorSecurityError("probe tool descriptor release failed") from failure

    def _verify_tools(self) -> None:
        for pin in self._tools.values():
            raw, identity = _read_regular(
                pin.path, maximum=16 * 1024 * 1024, uid=self.config.required_uid
            )
            if (
                identity != pin.identity
                or _sha256(raw) != pin.sha256
                or _identity(os.fstat(pin.descriptor)) != pin.identity
            ):
                raise CoordinatorSecurityError(pin.name + " tool identity changed")

    @staticmethod
    def _process_start_ticks(raw: bytes) -> int:
        try:
            text = raw.decode("ascii")
            tail = text[text.rindex(")") + 2 :].split()
            value = int(tail[19])
        except (UnicodeError, ValueError, IndexError) as exc:
            raise CoordinatorSecurityError("probe source process stat is malformed") from exc
        if value <= 0:
            raise CoordinatorSecurityError("probe source process start is invalid")
        return value

    def _verify_source(
        self, source: Mapping[str, Any], *, stage: str
    ) -> dict[str, Any]:
        self.source_guard()
        self._verify_tools()
        target = source.get("target")
        if not isinstance(target, dict):
            raise CoordinatorSecurityError("probe source target is missing")
        label = target.get("label")
        retained = self.builder._targets.get(label)
        if retained is None or retained.detached() != target:
            raise CoordinatorSecurityError("probe source target binding changed")
        self.builder._verify_target(retained)
        pid = target.get("pid")
        if type(pid) is not int or pid <= 0:
            raise CoordinatorSecurityError("probe source PID is invalid")
        try:
            stat_raw = pathlib.Path(f"/proc/{pid}/stat").read_bytes()
            netns = pathlib.Path(f"/proc/{pid}/ns/net").stat()
            mntns = pathlib.Path(f"/proc/{pid}/ns/mnt").stat()
        except OSError as exc:
            raise CoordinatorSecurityError("probe source namespace is unavailable") from exc
        if (
            self._process_start_ticks(stat_raw) != target.get("start_ticks")
            or netns.st_ino != target.get("netns_inode")
            or mntns.st_ino != target.get("mntns_inode")
            or retained.descriptor is None
            or os.fstat(retained.descriptor).st_ino != target.get("netns_inode")
        ):
            raise CoordinatorSecurityError("probe source PID or namespace changed")
        frozen_link = source.get("link")
        source_sha256 = source.get("source_sha256")
        if (
            not isinstance(frozen_link, dict)
            or not isinstance(frozen_link.get("name"), str)
            or not isinstance(source_sha256, str)
            or HEX64_RE.fullmatch(source_sha256) is None
        ):
            raise CoordinatorSecurityError("probe source link binding is malformed")
        source_body = copy.deepcopy(dict(source))
        source_body.pop("source_sha256", None)
        if _digest(source_body) != source_sha256:
            raise CoordinatorSecurityError("probe source digest binding changed")
        stage = stage + "-" + str(source.get("id"))
        fresh_link = _BUILDER_LINK_READ(
            self.builder,
            stage,
            retained,
            frozen_link["name"],
        )
        fresh_link["addresses"] = _BUILDER_ADDRESS_READ(
            self.builder,
            stage + "-addresses",
            retained,
            frozen_link["name"],
        )
        fresh_link["lineage"] = copy.deepcopy(frozen_link.get("lineage"))
        if fresh_link != frozen_link:
            raise CoordinatorSecurityError("probe source link identity changed")
        return {
            "container_id": target.get("container_id"),
            "pid": pid,
            "start_ticks": target.get("start_ticks"),
            "netns_inode": target.get("netns_inode"),
            "mntns_inode": target.get("mntns_inode"),
            "link": fresh_link,
            "source_sha256": source_sha256,
        }

    def _route_argv(self, source: Mapping[str, Any], destination: str) -> tuple[str, ...]:
        target = source["target"]
        container_id = target.get("container_id")
        address = source["source"]
        if not isinstance(container_id, str) or HEX64_RE.fullmatch(container_id) is None:
            raise CoordinatorSecurityError("probe source lacks exact container ID")
        command = [
            "docker",
            "exec",
            container_id,
            "ip",
            "-4",
            "route",
            "get",
            destination,
            "from",
            address,
        ]
        vrf = {
            "evpn-original": "vrf-evpn-client",
            "evpn-created": "vrf-x05-peer",
        }.get(source["id"])
        if vrf is not None:
            command.extend(("vrf", vrf))
        return tuple(command)

    @staticmethod
    def _route_proof(result: Any, argv: tuple[str, ...], destination: str, source: str) -> dict[str, Any]:
        detail = _result_detail(result, argv)
        try:
            text = result.stdout.decode("utf-8", "strict")
        except UnicodeError as exc:
            raise PacketError("route-get output is not UTF-8") from exc
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        forbidden = {"unreachable", "prohibit", "blackhole", "throw"}
        tokens = lines[0].split() if len(lines) == 1 else []
        if (
            result.returncode != 0
            or result.stderr
            or not tokens
            or tokens[0] != destination
            or forbidden.intersection(tokens)
            or "src" not in tokens
            or tokens[tokens.index("src") + 1 : tokens.index("src") + 2] != [source]
        ):
            raise GateFailure("probe route is absent, ambiguous, or contradicts its source")
        return {**detail, "route": lines[0], "status": "PASS"}

    def run(self, ordinal: int, plan: _WindowPlan) -> _ProbeWindow:
        if ordinal != len(self._windows) + 1 or plan != WINDOW_PLAN[ordinal - 1]:
            raise CoordinatorSecurityError("probe windows are not the fixed one-shot sequence")
        source = self.sources[plan.role]
        before_identity = self._verify_source(
            source, stage="window-%02d-source-before" % ordinal
        )
        health_before = _CAPTURE_HEALTH(self.capture)
        route_argv = self._route_argv(source, plan.destination)
        route_before_result = self.runner.run(
            route_argv,
            env=_BASE_ENV,
            timeout=self.config.command_timeout,
            pass_fds=(),
            max_output_bytes=_RUNTIME_MAX_OUTPUT,
        )
        self.evidence.command(
            "window-%02d-route-before" % ordinal, route_before_result, route_argv
        )
        route_before = self._route_proof(
            route_before_result, route_argv, plan.destination, source["source"]
        )
        pattern_hex = hashlib.sha256(
            (self.config.run_hex + ":" + str(ordinal) + ":" + plan.role).encode("ascii")
        ).hexdigest()[:32]
        ping_argv = (
            str(self._tools["nsenter"].path),
            "-t",
            str(source["target"]["pid"]),
            "-n",
            "--",
            str(self._tools["ping"].path),
            "-4",
            "-n",
            "-I",
            source["source"],
            "-c",
            "5",
            "-i",
            "0.2",
            "-W",
            "1",
            "-w",
            "7",
            "-s",
            "56",
            "-p",
            pattern_hex,
            plan.destination,
        )
        started_monotonic_ns = time.monotonic_ns()
        started_at_ns = time.time_ns()
        ping_result = self.runner.run(
            ping_argv,
            env=_BASE_ENV,
            timeout=min(self.config.command_timeout, 10.0),
            pass_fds=(),
            max_output_bytes=_RUNTIME_MAX_OUTPUT,
        )
        finished_at_ns = time.time_ns()
        finished_monotonic_ns = time.monotonic_ns()
        ping_detail = self.evidence.command(
            "window-%02d-ping" % ordinal, ping_result, ping_argv
        )
        if ping_result.stderr:
            raise PacketError("canonical ping wrote stderr")
        ping_evaluation = _EVALUATOR_PING(
            ping_result.stdout,
            returncode=ping_result.returncode,
            expect_reply=plan.expect_reply,
        )
        ping_detail = {**ping_detail, "evaluation": _evaluation(ping_evaluation)}
        if ping_evaluation.outcome is EVALUATOR.Outcome.FAIL:
            raise GateFailure("ping contradicted window " + str(ordinal) + ": " + ping_evaluation.reason)
        if ping_evaluation.outcome is not EVALUATOR.Outcome.PASS:
            raise PacketError("ping did not produce a complete window proof: " + ping_evaluation.reason)
        route_after_result = self.runner.run(
            route_argv,
            env=_BASE_ENV,
            timeout=self.config.command_timeout,
            pass_fds=(),
            max_output_bytes=_RUNTIME_MAX_OUTPUT,
        )
        self.evidence.command(
            "window-%02d-route-after" % ordinal, route_after_result, route_argv
        )
        route_after = self._route_proof(
            route_after_result, route_argv, plan.destination, source["source"]
        )
        health_after = _CAPTURE_HEALTH(self.capture)
        after_identity = self._verify_source(
            source, stage="window-%02d-source-after" % ordinal
        )
        if before_identity != after_identity:
            raise CoordinatorSecurityError("probe source identity changed across window")
        if (
            started_at_ns >= finished_at_ns
            or started_monotonic_ns >= finished_monotonic_ns
            or (
                self._windows
                and (
                    started_at_ns <= self._windows[-1].finished_at_ns
                    or started_monotonic_ns
                    <= self._windows[-1].finished_monotonic_ns
                )
            )
        ):
            raise PacketError("probe windows overlap")
        window = _ProbeWindow(
            ordinal=ordinal,
            gate=plan.gate,
            role=plan.role,
            source=source["source"],
            destination=plan.destination,
            expect_reply=plan.expect_reply,
            intended_tap=plan.intended_tap,
            vni=plan.vni,
            pattern_hex=pattern_hex,
            started_at_ns=started_at_ns,
            finished_at_ns=finished_at_ns,
            started_monotonic_ns=started_monotonic_ns,
            finished_monotonic_ns=finished_monotonic_ns,
            started_at_utc=dt.datetime.fromtimestamp(
                started_at_ns / 1_000_000_000, tz=dt.timezone.utc
            ).isoformat().replace("+00:00", "Z"),
            finished_at_utc=dt.datetime.fromtimestamp(
                finished_at_ns / 1_000_000_000, tz=dt.timezone.utc
            ).isoformat().replace("+00:00", "Z"),
            source_before=before_identity,
            source_after=after_identity,
            route_before=route_before,
            ping=ping_detail,
            route_after=route_after,
            health_before=copy.deepcopy(health_before),
            health_after=copy.deepcopy(health_after),
        )
        self.evidence.json("window-%02d.json" % ordinal, window.detached())
        self._windows.append(window)
        return window

    @property
    def windows(self) -> tuple[_ProbeWindow, ...]:
        return tuple(self._windows)


@dataclasses.dataclass(frozen=True)
class _CASMaterial:
    baseline: Any
    forward_snapshot: Mapping[str, Any]
    inverse_snapshot: Mapping[str, Any]
    forward_transaction: tuple[Any, ...]
    inverse_transaction: tuple[Any, ...]


class _ControlSession:
    """Prepare one guarded B->A transaction and its exact inverse."""

    def __init__(
        self,
        *,
        builder: Any,
        evidence: _Evidence,
        source_guard: Callable[[], None],
    ) -> None:
        if type(builder) is not _RUNTIME_BUILDER_TYPE:
            raise CoordinatorSecurityError("CAS control requires the canonical builder")
        self.builder = builder
        self.evidence = evidence
        self.source_guard = source_guard
        self.runner = builder._runner
        self.config = builder._config
        self.central_id = builder._central_id()
        self.central_target = builder._targets.get("ovn-central-az1")
        if self.central_target is None or self.central_target.container_id != self.central_id:
            raise CoordinatorSecurityError("CAS central target binding is unavailable")
        self.helper = self.config.bundle_root / CAS_RELATIVE_PATH
        self._material: _CASMaterial | None = None
        self._forward_intent = False
        self._inverse_dispatched = False
        self._io_bytes = 0

    def _run_read(
        self,
        label: str,
        argv: tuple[str, ...],
        *,
        deadline: float | None = None,
    ) -> bytes:
        self.source_guard()
        self.builder._verify_target(self.central_target)
        remaining = CAS_IO_BYTES - self._io_bytes
        if remaining <= 0:
            raise CoordinatorError("CAS shared I/O budget is exhausted")
        timeout = float(self.config.command_timeout)
        if deadline is not None:
            remaining_time = deadline - time.monotonic()
            if remaining_time <= 0:
                raise CoordinatorError(label + " elapsed before command dispatch")
            timeout = min(timeout, remaining_time)
        result = self.runner.run(
            argv,
            env=_BASE_ENV,
            timeout=timeout,
            pass_fds=(),
            max_output_bytes=min(_RUNTIME_MAX_OUTPUT, remaining),
        )
        self._io_bytes += len(result.stdout) + len(result.stderr)
        self.evidence.command(label, result, argv)
        if result.returncode != 0 or result.stderr:
            raise CoordinatorError(label + " failed")
        return result.stdout

    @staticmethod
    def _uuid(value: Any, context: str) -> str:
        if not isinstance(value, str) or _UUID_RE.fullmatch(value) is None:
            raise CoordinatorError(context + " is not a UUID")
        return value

    @classmethod
    def _port_set(cls, value: Any, context: str) -> frozenset[str]:
        values = value if isinstance(value, list) else [value]
        if values == [[]] or values == [None]:
            values = []
        result = frozenset(cls._uuid(item, context) for item in values)
        if len(result) != len(values):
            raise CoordinatorError(context + " contains duplicate UUIDs")
        return result

    def observe(self, label: str, *, deadline: float | None = None) -> Any:
        self.source_guard()
        self.builder._verify_target(self.central_target)
        commands = {
            "switches": (
                "docker", "exec", self.central_id, "ovn-nbctl",
                "--format=json", "--data=json", "--no-headings",
                "--columns=_uuid,name,ports", "list", "Logical_Switch",
            ),
            "lsp": (
                "docker", "exec", self.central_id, "ovn-nbctl",
                "--format=json", "--data=json", "--no-headings",
                "--columns=_uuid,name", "find", "Logical_Switch_Port",
                "name=x05-tenant-b-vm",
            ),
            "sb_b": (
                "docker", "exec", self.central_id, "ovn-sbctl",
                "--format=json", "--data=json", "--no-headings",
                "--columns=_uuid,logical_port,datapath", "find", "Port_Binding",
                "logical_port=x05-tenant-b-vm",
            ),
            "sb_a": (
                "docker", "exec", self.central_id, "ovn-sbctl",
                "--format=json", "--data=json", "--no-headings",
                "--columns=_uuid,logical_port,datapath", "find", "Port_Binding",
                "logical_port=x05-tenant-a-vm",
            ),
        }
        rows = {
            key: _EVALUATOR_PARSE_OVS(
                self._run_read(
                    "%s-%s" % (label, key.replace("_", "-")),
                    argv,
                    deadline=deadline,
                ),
                context="X05 CAS " + key,
            )
            for key, argv in commands.items()
        }
        selected_switches = [
            row
            for row in rows["switches"]
            if row.get("name") in {"ls-x05-tenant-a", "ls-x05-tenant-b"}
        ]
        switches = {row.get("name"): row for row in selected_switches}
        if (
            len(selected_switches) != 2
            or set(switches) != {"ls-x05-tenant-a", "ls-x05-tenant-b"}
        ):
            raise CoordinatorError("CAS A/B logical switches are not singular")
        if len(rows["lsp"]) != 1:
            raise CoordinatorError("CAS B LSP identity is not singular")
        lsp = rows["lsp"][0]
        if lsp.get("name") != "x05-tenant-b-vm":
            raise CoordinatorError("CAS B LSP name changed")
        lsp_uuid = self._uuid(lsp.get("_uuid"), "CAS B LSP")
        a_row = switches["ls-x05-tenant-a"]
        b_row = switches["ls-x05-tenant-b"]
        a_uuid = self._uuid(a_row.get("_uuid"), "CAS A switch")
        b_uuid = self._uuid(b_row.get("_uuid"), "CAS B switch")
        a_ports = self._port_set(a_row.get("ports"), "CAS A ports")
        b_ports = self._port_set(b_row.get("ports"), "CAS B ports")
        parent_values: set[str] = set()
        for row in rows["switches"]:
            switch_uuid = self._uuid(row.get("_uuid"), "CAS observed switch")
            switch_ports = self._port_set(row.get("ports"), "CAS observed switch ports")
            if lsp_uuid in switch_ports:
                parent_values.add(switch_uuid)
        parents = frozenset(parent_values)
        sb_b = rows["sb_b"]
        if len(sb_b) > 1:
            raise CoordinatorError("CAS B SB binding is not singular")
        sb_row = sb_b[0] if sb_b else None
        return _CAS_OBSERVATION_TYPE(
            a_ls_uuid=a_uuid,
            b_ls_uuid=b_uuid,
            nb_lsp_uuid=lsp_uuid,
            nb_lsp_name="x05-tenant-b-vm",
            a_ports=a_ports,
            b_ports=b_ports,
            parent_ls_uuids=parents,
            sb_logical_port=None if sb_row is None else sb_row.get("logical_port"),
            sb_port_binding_uuid=(
                None if sb_row is None else self._uuid(sb_row.get("_uuid"), "CAS B SB")
            ),
            sb_datapath=(
                None if sb_row is None else self._uuid(sb_row.get("datapath"), "CAS B datapath")
            ),
        ), rows["sb_a"]

    def _build_transaction(self, label: str, snapshot: Mapping[str, Any]) -> tuple[Any, ...]:
        snapshot_binding = self.evidence.json(label + "-snapshot.json", snapshot)
        argv = ("/usr/bin/bash", str(self.helper), "--build", snapshot_binding["path"])
        raw = self._run_read(label + "-build", argv)
        try:
            transaction = json.loads(raw)
        except (UnicodeError, json.JSONDecodeError) as exc:
            raise CoordinatorError("CAS helper returned malformed JSON") from exc
        if not isinstance(transaction, list) or len(transaction) != 5:
            raise CoordinatorError("CAS helper transaction shape changed")
        self.evidence.json(label + "-transaction.json", transaction)
        return tuple(transaction)

    def _a_sentinel_datapath(self, rows: Sequence[Mapping[str, Any]]) -> str:
        if len(rows) != 1 or rows[0].get("logical_port") != "x05-tenant-a-vm":
            raise CoordinatorError("CAS A sentinel SB binding is not singular")
        self._uuid(rows[0].get("_uuid"), "CAS A sentinel SB")
        datapath = self._uuid(
            rows[0].get("datapath"), "CAS A sentinel datapath"
        )
        if (
            self._material is not None
            and datapath != self._material.baseline.a_sentinel_datapath
        ):
            raise CoordinatorError("CAS A sentinel datapath changed")
        return datapath

    def prepare(self) -> _CASMaterial:
        if self._material is not None:
            raise CoordinatorSecurityError("CAS material is one-shot")
        observation, sb_a_rows = self.observe("cas-baseline")
        a_sentinel_datapath = self._a_sentinel_datapath(sb_a_rows)
        baseline = _CAS_BASELINE_TYPE(
            a_ls_uuid=observation.a_ls_uuid,
            b_ls_uuid=observation.b_ls_uuid,
            nb_lsp_uuid=observation.nb_lsp_uuid,
            nb_lsp_name=observation.nb_lsp_name,
            a_ports=observation.a_ports,
            b_ports=observation.b_ports,
            sb_logical_port=observation.sb_logical_port,
            sb_port_binding_uuid=observation.sb_port_binding_uuid,
            a_sentinel_datapath=a_sentinel_datapath,
            b_sentinel_datapath=observation.sb_datapath,
        )
        restored = _EVALUATOR_CAS(baseline, observation, EVALUATOR.CASStage.RESTORED_TO_B)
        if restored.outcome is not EVALUATOR.Outcome.PASS:
            raise GateFailure("CAS baseline is not exact B: " + restored.reason)
        forward = {
            "source": {"uuid": baseline.b_ls_uuid, "ports": sorted(baseline.b_ports)},
            "target": {"uuid": baseline.a_ls_uuid, "ports": sorted(baseline.a_ports)},
            "lsp_uuid": baseline.nb_lsp_uuid,
        }
        moved_a = baseline.a_ports | {baseline.nb_lsp_uuid}
        moved_b = baseline.b_ports - {baseline.nb_lsp_uuid}
        inverse = {
            "source": {"uuid": baseline.a_ls_uuid, "ports": sorted(moved_a)},
            "target": {"uuid": baseline.b_ls_uuid, "ports": sorted(moved_b)},
            "lsp_uuid": baseline.nb_lsp_uuid,
        }
        material = _CASMaterial(
            baseline,
            forward,
            inverse,
            self._build_transaction("cas-forward", forward),
            self._build_transaction("cas-inverse", inverse),
        )
        self._material = material
        return material

    def _position(self, observation: Any) -> str:
        assert self._material is not None
        baseline = self._material.baseline
        if (
            observation.a_ports == baseline.a_ports
            and observation.b_ports == baseline.b_ports
            and observation.parent_ls_uuids == frozenset({baseline.b_ls_uuid})
        ):
            return "B"
        if (
            observation.a_ports == baseline.a_ports | {baseline.nb_lsp_uuid}
            and observation.b_ports == baseline.b_ports - {baseline.nb_lsp_uuid}
            and observation.parent_ls_uuids == frozenset({baseline.a_ls_uuid})
        ):
            return "A"
        return "UNKNOWN"

    def _poll(self, label: str, stage: Any) -> dict[str, Any]:
        assert self._material is not None
        started = time.monotonic()
        deadline = started + CAS_ELAPSED_SECONDS
        last: Any = None
        for attempt in range(1, CAS_ATTEMPTS + 1):
            if time.monotonic() >= deadline:
                break
            observation, sb_a = self.observe(
                "%s-attempt-%02d" % (label, attempt),
                deadline=deadline,
            )
            self._a_sentinel_datapath(sb_a)
            last = _EVALUATOR_CAS(self._material.baseline, observation, stage)
            detail = {
                "attempt": attempt,
                "position": self._position(observation),
                "evaluation": _evaluation(last),
            }
            self.evidence.json("%s-attempt-%02d.json" % (label, attempt), detail)
            if last.outcome is not EVALUATOR.Outcome.RETRY:
                return {
                    **detail,
                    "elapsed_seconds": time.monotonic() - started,
                    "io_bytes": self._io_bytes,
                    "max_io_bytes": CAS_IO_BYTES,
                }
            delay = min(GATE_RETRY_DELAY_SECONDS, max(0.0, deadline - time.monotonic()))
            if delay:
                time.sleep(delay)
        if last is None:
            raise CoordinatorError(label + " elapsed before an observation")
        frozen = _EVALUATOR_FAILED(label + " convergence budget exhausted", last_reason=last.reason)
        return {
            "attempt": min(CAS_ATTEMPTS, attempt),
            "position": detail["position"],
            "evaluation": _evaluation(frozen),
            "elapsed_seconds": time.monotonic() - started,
            "io_bytes": self._io_bytes,
            "max_io_bytes": CAS_IO_BYTES,
        }

    def _dispatch(self, label: str, transaction: tuple[Any, ...]) -> dict[str, Any]:
        self.source_guard()
        self.builder._verify_target(self.central_target)
        transaction_text = json.dumps(
            list(transaction), sort_keys=True, separators=(",", ":"), ensure_ascii=True
        )
        argv = (
            "docker", "exec", self.central_id, "ovsdb-client", "transact",
            "unix:/var/run/ovn/ovnnb_db.sock", transaction_text,
        )
        self.evidence.json(label + "-intent.json", {"argv": list(argv), "transaction_sha256": _sha256(transaction_text.encode("ascii"))})
        remaining = CAS_IO_BYTES - self._io_bytes
        if remaining <= 0:
            raise CoordinatorError("CAS shared I/O budget is exhausted before dispatch")
        result = self.runner.run(
            argv,
            env=_BASE_ENV,
            timeout=self.config.command_timeout,
            pass_fds=(),
            max_output_bytes=min(_RUNTIME_MAX_OUTPUT, remaining),
        )
        self._io_bytes += len(result.stdout) + len(result.stderr)
        command = self.evidence.command(label + "-transact", result, argv)
        if result.returncode != 0 or result.stderr:
            raise CoordinatorAmbiguous(label + " transaction outcome is ambiguous")
        try:
            json.loads(result.stdout)
        except (UnicodeError, json.JSONDecodeError) as exc:
            raise CoordinatorAmbiguous(label + " transaction response is malformed") from exc
        check_argv = (
            "/usr/bin/bash", str(self.helper), "--check-result",
            command["stdout"]["path"],
        )
        remaining = CAS_IO_BYTES - self._io_bytes
        if remaining <= 0:
            raise CoordinatorAmbiguous("CAS I/O budget ended after transaction dispatch")
        check = self.runner.run(
            check_argv,
            env=_BASE_ENV,
            timeout=self.config.command_timeout,
            pass_fds=(),
            max_output_bytes=min(_RUNTIME_MAX_OUTPUT, remaining),
        )
        self._io_bytes += len(check.stdout) + len(check.stderr)
        self.evidence.command(label + "-check", check, check_argv)
        if check.returncode != 0 or check.stderr:
            raise CoordinatorAmbiguous(label + " transaction acknowledgement is incomplete")
        return command

    def move_to_a(self) -> dict[str, Any]:
        if self._material is None or self._forward_intent:
            raise CoordinatorSecurityError("forward CAS is not in its prepared one-shot state")
        self._forward_intent = True
        dispatch_error: str | None = None
        try:
            self._dispatch("cas-forward", self._material.forward_transaction)
        except BaseException as exc:
            dispatch_error = type(exc).__name__ + ":" + str(exc)
        proof = self._poll("cas-forward-post", EVALUATOR.CASStage.MOVED_TO_A)
        if proof["evaluation"]["outcome"] != EVALUATOR.Outcome.PASS.value:
            if dispatch_error is not None:
                raise CoordinatorAmbiguous(dispatch_error + "; forward reconciliation failed")
            raise GateFailure("forward CAS postcondition failed")
        return {**proof, "dispatch_error": dispatch_error}

    def restore_to_b(self) -> dict[str, Any]:
        if self._material is None or not self._forward_intent:
            raise CoordinatorSecurityError("inverse CAS has no forward intent")
        observation, sb_a = self.observe("cas-restore-position")
        self._a_sentinel_datapath(sb_a)
        position = self._position(observation)
        dispatch_error: str | None = None
        dispatched = False
        if position == "A":
            if self._inverse_dispatched:
                raise CoordinatorSecurityError("inverse CAS cannot be replayed")
            self._inverse_dispatched = True
            dispatched = True
            try:
                self._dispatch("cas-inverse", self._material.inverse_transaction)
            except BaseException as exc:
                dispatch_error = type(exc).__name__ + ":" + str(exc)
        elif position != "B":
            raise CoordinatorAmbiguous("CAS position is neither exact A nor exact B")
        proof = self._poll("cas-inverse-post", EVALUATOR.CASStage.RESTORED_TO_B)
        if proof["evaluation"]["outcome"] != EVALUATOR.Outcome.PASS.value:
            raise CoordinatorAmbiguous(
                (dispatch_error + "; " if dispatch_error else "")
                + "inverse CAS reconciliation failed"
            )
        return {
            **proof,
            "position_before": position,
            "dispatched": dispatched,
            "dispatch_error": dispatch_error,
        }


@dataclasses.dataclass(frozen=True)
class _Packet:
    point: str
    interface: str
    timestamp_ns: int
    packet_type: int
    source: str
    destination: str
    icmp_type: int
    icmp_code: int
    identifier: int
    sequence: int
    payload: bytes
    vni: int | None


def _ipv4_icmp(
    raw: bytes, *, context: str
) -> tuple[str, str, int, int, int, int, bytes]:
    if len(raw) < 20 or raw[0] >> 4 != 4:
        raise PacketError(context + " IPv4 header is truncated or malformed")
    header = (raw[0] & 0x0F) * 4
    total = int.from_bytes(raw[2:4], "big")
    fragment = int.from_bytes(raw[6:8], "big")
    if header < 20 or total < header + 8 or total > len(raw):
        raise PacketError(context + " IPv4 length is invalid")
    if fragment & 0x3FFF:
        raise PacketError(context + " relevant IPv4 packet is fragmented")
    if raw[9] != 1:
        raise PacketError(context + " expected ICMP after relevant filtering")
    source = ".".join(str(value) for value in raw[12:16])
    destination = ".".join(str(value) for value in raw[16:20])
    icmp = raw[header:total]
    if len(icmp) < 8:
        raise PacketError(context + " ICMP header is truncated")
    return (
        source,
        destination,
        icmp[0],
        icmp[1],
        int.from_bytes(icmp[4:6], "big"),
        int.from_bytes(icmp[6:8], "big"),
        icmp[8:],
    )


def _validate_relevant_icmp(decoded: tuple[Any, ...], *, context: str) -> None:
    if decoded[2] not in {0, 8}:
        raise PacketError(context + " relevant ICMP type is not echo request/reply")
    if decoded[3] != 0:
        raise PacketError(context + " relevant ICMP code is nonzero")


def _decode_sll2_payload(
    raw: bytes,
    *,
    context: str,
    source_addresses: frozenset[str],
) -> tuple[int, tuple[Any, ...], int | None] | None:
    if len(raw) < 20:
        raise PacketError(context + " SLL2 header is truncated")
    protocol = int.from_bytes(raw[0:2], "big")
    packet_type = raw[10]
    if packet_type > 4:
        raise PacketError(context + " SLL2 direction is invalid")
    payload = raw[20:]
    if protocol != 0x0800:
        return None
    if len(payload) < 20 or payload[0] >> 4 != 4:
        raise PacketError(context + " outer IPv4 header is malformed")
    outer_header = (payload[0] & 0x0F) * 4
    outer_total = int.from_bytes(payload[2:4], "big")
    outer_fragment = int.from_bytes(payload[6:8], "big")
    if outer_header < 20 or outer_total < outer_header or outer_total > len(payload):
        raise PacketError(context + " outer IPv4 length is invalid")
    outer_source = ".".join(str(value) for value in payload[12:16])
    outer_destination = ".".join(str(value) for value in payload[16:20])

    def relevant_pair(source: str, destination: str) -> bool:
        return (
            source in source_addresses and destination in SENTINEL_IPS
        ) or (
            destination in source_addresses and source in SENTINEL_IPS
        )

    outer_relevant = relevant_pair(outer_source, outer_destination)
    if outer_fragment & 0x3FFF:
        if outer_relevant or payload[9] == 17:
            raise PacketError(context + " relevant outer IPv4 packet is fragmented")
        return None
    if payload[9] == 1:
        if not outer_relevant:
            return None
        decoded = _ipv4_icmp(payload[:outer_total], context=context)
        _validate_relevant_icmp(decoded, context=context)
        return packet_type, decoded, None
    if payload[9] != 17:
        return None
    udp = payload[outer_header:outer_total]
    if len(udp) < 8:
        raise PacketError(context + " UDP header is truncated")
    if int.from_bytes(udp[2:4], "big") != 4789:
        return None
    udp_length = int.from_bytes(udp[4:6], "big")
    if (
        len(udp) < 16
        or udp_length != len(udp)
    ):
        raise PacketError(context + " relevant UDP packet is not VXLAN")
    vxlan = udp[8:]
    if len(vxlan) < 22 or vxlan[0] != 0x08 or vxlan[1:4] != b"\0\0\0":
        raise PacketError(context + " VXLAN header is malformed")
    vni = int.from_bytes(vxlan[4:7], "big")
    if vxlan[7] != 0:
        raise PacketError(context + " VXLAN reserved byte is nonzero")
    ethernet = vxlan[8:]
    if len(ethernet) < 14 or int.from_bytes(ethernet[12:14], "big") != 0x0800:
        raise PacketError(context + " VXLAN inner Ethernet frame is malformed")
    decoded = _ipv4_icmp(ethernet[14:], context=context + " inner")
    if not relevant_pair(decoded[0], decoded[1]):
        return None
    _validate_relevant_icmp(decoded, context=context + " inner")
    return packet_type, decoded, vni


def _pcap_packets(
    point: str,
    raw: bytes,
    interfaces: Mapping[int, str],
    source_addresses: frozenset[str],
) -> tuple[tuple[_Packet, ...], int]:
    if len(raw) < 24:
        raise PacketError(point + " PCAP header is truncated")
    magic = raw[:4]
    formats = {
        b"\xd4\xc3\xb2\xa1": ("<", 1000),
        b"\xa1\xb2\xc3\xd4": (">", 1000),
        b"\x4d\x3c\xb2\xa1": ("<", 1),
        b"\xa1\xb2\x3c\x4d": (">", 1),
    }
    if magic not in formats:
        raise PacketError(point + " PCAP magic is unsupported")
    endian, fraction_scale = formats[magic]
    _major, _minor, _zone, _sigfigs, snaplen, network = struct.unpack(
        endian + "HHIIII", raw[4:24]
    )
    if (_major, _minor) != (2, 4) or snaplen < 128 or network != 276:
        raise PacketError(point + " PCAP global header is not canonical SLL2")
    packets: list[_Packet] = []
    offset = 24
    index = 0
    while offset < len(raw):
        index += 1
        if len(raw) - offset < 16:
            raise PacketError(point + " PCAP record header is truncated")
        seconds, fraction, captured, original = struct.unpack(
            endian + "IIII", raw[offset : offset + 16]
        )
        offset += 16
        fraction_limit = 1_000_000 if fraction_scale == 1000 else 1_000_000_000
        if (
            fraction >= fraction_limit
            or captured > original
            or captured > snaplen
            or captured > len(raw) - offset
        ):
            raise PacketError(point + " PCAP record length is invalid")
        frame = raw[offset : offset + captured]
        offset += captured
        if captured != original:
            raise PacketError(point + " relevant packet was snaplen-truncated")
        ifindex = int.from_bytes(frame[4:8], "big") if len(frame) >= 8 else -1
        interface = interfaces.get(ifindex)
        if interface is None:
            raise PacketError(point + " packet has an unadmitted ifindex")
        decoded_payload = _decode_sll2_payload(
            frame,
            context="%s record %d" % (point, index),
            source_addresses=source_addresses,
        )
        if decoded_payload is None:
            continue
        packet_type, decoded, vni = decoded_payload
        (
            source,
            destination,
            icmp_type,
            icmp_code,
            identifier,
            sequence,
            payload,
        ) = decoded
        packets.append(
            _Packet(
                point,
                interface,
                seconds * 1_000_000_000 + fraction * fraction_scale,
                packet_type,
                source,
                destination,
                icmp_type,
                icmp_code,
                identifier,
                sequence,
                payload,
                vni,
            )
        )
    return tuple(packets), index


def _semantic_decode(
    pcaps: Mapping[str, Mapping[str, Any]],
    capture_contract: Mapping[str, Any],
    windows: Sequence[Mapping[str, Any]],
) -> dict[str, Any]:
    points = capture_contract.get("points")
    sources = capture_contract.get("sources")
    if (
        not isinstance(points, list)
        or not all(isinstance(item, Mapping) for item in points)
        or not isinstance(sources, list)
        or not all(isinstance(item, Mapping) for item in sources)
    ):
        raise PacketError("capture contract lacks points or sources")
    if tuple(item.get("id") for item in points) != tuple(_CAPTURE_POINT_IDS):
        raise PacketError("capture point inventory changed")
    if len(windows) != len(WINDOW_PLAN):
        raise PacketError("probe window inventory is incomplete")
    source_map = {item.get("id"): item for item in sources}
    if (
        len(sources) != 4
        or set(source_map) != set(SOURCE_BY_ROLE)
        or any(
            source_map[role].get("source") != address
            for role, address in SOURCE_BY_ROLE.items()
        )
        or {plan.destination for plan in WINDOW_PLAN} != SENTINEL_IPS
    ):
        raise PacketError("capture source inventory changed")
    source_addresses = frozenset(SOURCE_BY_ROLE.values())
    interface_maps: dict[str, dict[int, str]] = {}
    interface_count = 0
    for point in points:
        rows = point.get("interfaces")
        if (
            not isinstance(rows, list)
            or not rows
            or not all(isinstance(row, Mapping) for row in rows)
        ):
            raise PacketError("capture point interfaces are incomplete")
        current: dict[int, str] = {}
        for row in rows:
            ifindex, name = row.get("ifindex"), row.get("name")
            if type(ifindex) is not int or ifindex <= 0 or not isinstance(name, str):
                raise PacketError("capture interface identity is malformed")
            if ifindex in current or name in current.values():
                raise PacketError("capture point repeats an interface identity")
            current[ifindex] = name
            interface_count += 1
        interface_maps[point["id"]] = current
    if interface_count != 11 or set(pcaps) != set(interface_maps):
        raise PacketError("capture PCAP/ifindex inventory is incomplete")
    for role, source in source_map.items():
        rows = source.get("receive")
        if (
            not isinstance(rows, list)
            or not rows
            or not all(isinstance(row, Mapping) for row in rows)
        ):
            raise PacketError("capture source receive inventory is malformed")
        receive = [(row.get("point"), row.get("interface")) for row in rows]
        if len(set(receive)) != len(receive):
            raise PacketError("capture source receive inventory has duplicates")
        if role.startswith("classic-"):
            if tuple(receive) != RECEIVE_BY_ROLE[role]:
                raise PacketError("classic source receive inventory changed")
        else:
            expected_point, _dynamic_interface = RECEIVE_BY_ROLE[role][0]
            if (
                len(receive) != 1
                or receive[0][0] != expected_point
                or receive[0][1] not in interface_maps[expected_point].values()
                or receive[0][1] == "br-ovn"
            ):
                raise PacketError("EVPN source receive inventory changed")
        if any(
            point not in interface_maps
            or interface not in interface_maps[point].values()
            for point, interface in receive
        ):
            raise PacketError("capture source receive interface is unadmitted")
    evpn_receive = {
        source_map[role]["receive"][0]["interface"]
        for role in ("evpn-original", "evpn-created")
    }
    fabric_non_bridge = set(interface_maps["fabric"].values()) - {"br-ovn"}
    if len(evpn_receive) != 2 or evpn_receive != fabric_non_bridge:
        raise PacketError("EVPN source receive interfaces are not exact")
    packets: list[_Packet] = []
    pcap_summary: dict[str, Any] = {}
    for point_id in _CAPTURE_POINT_IDS:
        item = pcaps[point_id]
        if not isinstance(item, Mapping):
            raise PacketError("owned PCAP binding is malformed: " + point_id)
        raw = item.get("raw")
        if type(raw) is not bytes or item.get("sha256") != _sha256(raw):
            raise PacketError("owned PCAP digest changed: " + point_id)
        decoded, record_count = _pcap_packets(
            point_id,
            raw,
            interface_maps[point_id],
            source_addresses,
        )
        packets.extend(decoded)
        pcap_summary[point_id] = {
            "sha256": _sha256(raw),
            "bytes": len(raw),
            "records": record_count,
            "relevant_records": len(decoded),
        }
    results: list[dict[str, Any]] = []
    previous_finished = -1
    previous_monotonic_finished = -1
    for position, (raw_window, plan) in enumerate(zip(windows, WINDOW_PLAN, strict=True), 1):
        if not isinstance(raw_window, Mapping):
            raise PacketError("probe window is not a mapping")
        expected = {
            "ordinal": position,
            "gate": plan.gate,
            "role": plan.role,
            "source": source_map[plan.role].get("source"),
            "destination": plan.destination,
            "expect_reply": plan.expect_reply,
            "intended_tap": plan.intended_tap,
            "vni": plan.vni,
        }
        if any(raw_window.get(key) != value for key, value in expected.items()):
            raise PacketError("probe window metadata changed: " + str(position))
        started = raw_window.get("started_at_ns")
        finished = raw_window.get("finished_at_ns")
        started_monotonic = raw_window.get("started_monotonic_ns")
        finished_monotonic = raw_window.get("finished_monotonic_ns")
        pattern_hex = raw_window.get("pattern_hex")
        if (
            type(started) is not int
            or type(finished) is not int
            or type(started_monotonic) is not int
            or type(finished_monotonic) is not int
            or started >= finished
            or started_monotonic >= finished_monotonic
            or started <= previous_finished
            or started_monotonic <= previous_monotonic_finished
            or not isinstance(pattern_hex, str)
            or re.fullmatch(r"[0-9a-f]{32}", pattern_hex) is None
        ):
            raise PacketError("probe window bounds or nonce are malformed")
        previous_finished = finished
        previous_monotonic_finished = finished_monotonic
        current = [packet for packet in packets if started <= packet.timestamp_ns <= finished]
        source = expected["source"]
        relevant = [
            packet
            for packet in current
            if (
                (packet.source == source and packet.destination == plan.destination and packet.icmp_type == 8)
                or (packet.source == plan.destination and packet.destination == source and packet.icmp_type == 0)
            )
        ]
        receive = {
            (item.get("point"), item.get("interface"))
            for item in source_map[plan.role].get("receive", [])
        }
        source_encapsulated = plan.role.startswith("evpn-")
        tap_name = "x05-tenant-%s-p" % plan.intended_tap
        tap_point = "chassis-1" if plan.intended_tap == "a" else "chassis-2"
        other_tap = ("chassis-2", "x05-tenant-b-p") if plan.intended_tap == "a" else ("chassis-1", "x05-tenant-a-p")
        source_requests = [
            packet for packet in relevant
            if (packet.point, packet.interface) in receive
            and packet.icmp_type == 8
            and (packet.vni is not None) is source_encapsulated
            and packet.packet_type in range(0, 4)
        ]
        if len(source_requests) != 5:
            raise GateFailure("window %d lacks exactly five source requests" % position)
        identifiers = {packet.identifier for packet in source_requests}
        sequences = {packet.sequence for packet in source_requests}
        payloads = {packet.sequence: packet.payload for packet in source_requests}
        expected_tail = (bytes.fromhex(pattern_hex) * 4)[16:56]
        if (
            len(identifiers) != 1
            or sequences != set(range(1, 6))
            or len(payloads) != 5
            or any(len(payload) != 56 or payload[16:] != expected_tail for payload in payloads.values())
        ):
            raise GateFailure("window %d source ICMP ID/sequence/nonce proof failed" % position)
        identifier = next(iter(identifiers))

        def matches(packet: _Packet, kind: int) -> bool:
            return (
                packet.icmp_type == kind
                and packet.identifier == identifier
                and packet.sequence in payloads
                and packet.payload == payloads[packet.sequence]
            )

        source_replies = [
            packet for packet in relevant
            if (packet.point, packet.interface) in receive
            and matches(packet, 0)
            and (packet.vni is not None) is source_encapsulated
            and packet.packet_type == 4
        ]
        tap_requests = [
            packet for packet in relevant
            if (packet.point, packet.interface) == (tap_point, tap_name)
            and packet.vni is None and matches(packet, 8) and packet.packet_type == 4
        ]
        tap_replies = [
            packet for packet in relevant
            if (packet.point, packet.interface) == (tap_point, tap_name)
            and packet.vni is None and matches(packet, 0) and packet.packet_type in range(0, 4)
        ]
        cross_tap = [
            packet for packet in relevant
            if (packet.point, packet.interface) == other_tap
        ]
        vxlan_requests = [
            packet for packet in relevant
            if (packet.point, packet.interface) == (tap_point, "vxlan_sys_4789")
            and packet.vni == plan.vni and matches(packet, 8) and packet.packet_type in range(0, 4)
        ]
        vxlan_replies = [
            packet for packet in relevant
            if (packet.point, packet.interface) == (tap_point, "vxlan_sys_4789")
            and packet.vni == plan.vni and matches(packet, 0) and packet.packet_type == 4
        ]
        wrong = [
            packet for packet in relevant
            if (
                (
                    (packet.point, packet.interface) in receive
                    and (
                        (packet.vni is not None) is not source_encapsulated
                        or packet.packet_type not in ({0, 1, 2, 3} if packet.icmp_type == 8 else {4})
                        or (packet.icmp_type == 0 and not matches(packet, 0))
                    )
                )
                or (
                    (packet.point, packet.interface) == (tap_point, tap_name)
                    and (
                        packet.vni is not None
                        or packet.packet_type not in ({4} if packet.icmp_type == 8 else {0, 1, 2, 3})
                        or not matches(packet, packet.icmp_type)
                    )
                )
                or (
                    (packet.point, packet.interface) == (tap_point, "vxlan_sys_4789")
                    and (
                        packet.vni != plan.vni
                        or packet.packet_type not in ({0, 1, 2, 3} if packet.icmp_type == 8 else {4})
                        or not matches(packet, packet.icmp_type)
                    )
                )
            )
        ]
        counts = {
            "source_requests": len(source_requests),
            "source_replies": len(source_replies),
            "tap_requests": len(tap_requests),
            "tap_replies": len(tap_replies),
            "vxlan_requests": len(vxlan_requests),
            "vxlan_replies": len(vxlan_replies),
            "cross_tap": len(cross_tap),
            "wrong_direction_or_vni": len(wrong),
        }
        desired = {
            "source_requests": 5,
            "source_replies": 5 if plan.expect_reply else 0,
            "tap_requests": 5 if plan.expect_reply else 0,
            "tap_replies": 5 if plan.expect_reply else 0,
            "vxlan_requests": 5 if plan.expect_reply else 0,
            "vxlan_replies": 5 if plan.expect_reply else 0,
            "cross_tap": 0,
            "wrong_direction_or_vni": 0,
        }
        if counts != desired:
            raise GateFailure(
                "window %d semantic counts differ: %s" % (position, json.dumps(counts, sort_keys=True))
            )
        results.append({**expected, "icmp_identifier": identifier, "counts": counts})
    return {
        "schema": DECODE_SCHEMA,
        "status": "PASS",
        "pcaps": pcap_summary,
        "windows": results,
        "window_count": len(results),
        "ifindex_count": interface_count,
    }


def decode_capture_evidence(
    pcaps: Mapping[str, Mapping[str, Any]],
    capture_contract: Mapping[str, Any],
    windows: Sequence[Mapping[str, Any]],
) -> dict[str, Any]:
    """Purely decode the five owned PCAP byte strings against fixed windows."""
    try:
        return _semantic_decode(pcaps, capture_contract, windows)
    except GateFailure as exc:
        return {"schema": DECODE_SCHEMA, "status": "FAIL", "reason": str(exc)}
    except (
        PacketError,
        CoordinatorError,
        KeyError,
        TypeError,
        ValueError,
        AttributeError,
        IndexError,
        struct.error,
    ) as exc:
        return {
            "schema": DECODE_SCHEMA,
            "status": "ERROR",
            "reason": type(exc).__name__ + ":" + str(exc),
        }


def _container_id(builder: Any, label: str) -> str:
    target = builder._targets.get(label)
    value = getattr(target, "container_id", None)
    if not isinstance(value, str) or HEX64_RE.fullmatch(value) is None:
        raise CoordinatorSecurityError("topology lacks exact container ID: " + label)
    return value


def _topologies(builder: Any) -> tuple[Any, Any]:
    return (
        _G1_TOPOLOGY_TYPE(
            client_a=_container_id(builder, "dci-client-1"),
            client_b=_container_id(builder, "dci-client-2"),
            gateway_1=_container_id(builder, "ovn-gw-1"),
            gateway_2=_container_id(builder, "ovn-gw-2"),
        ),
        _G2_TOPOLOGY_TYPE(
            peer_a=_container_id(builder, "dci-evpn-client-1"),
            peer_b=_container_id(builder, "dci-x05-peer-2"),
            chassis_a=_container_id(builder, "ovn-chassis-1"),
            chassis_b=_container_id(builder, "ovn-chassis-2"),
            central_id=_container_id(builder, "ovn-central-az1"),
        ),
    )


def _require_gate(name: str, report: Mapping[str, Any]) -> None:
    evaluation = report.get("evaluation", {})
    outcome = evaluation.get("outcome")
    reason = evaluation.get("reason", "missing evaluation")
    if (
        outcome == EVALUATOR.Outcome.PASS.value
        and evaluation.get("authoritative_x05_pass") is True
    ):
        return
    if outcome == EVALUATOR.Outcome.PASS.value:
        raise CoordinatorError(name + " PASS is not authoritative runtime evidence")
    if outcome == EVALUATOR.Outcome.FAIL.value:
        raise GateFailure(name + " failed: " + str(reason))
    raise CoordinatorError(name + " is not authoritative: " + str(reason))


def _execution_preconditions(prepared: Any) -> tuple[Any, Any]:
    _verify_graph()
    if type(prepared) is not _PREPARED_ADMISSION_TYPE:
        raise CoordinatorSecurityError("execute requires canonical PreparedAdmission")
    session = prepared._session
    if (
        type(session) is not _ADMISSION_SESSION_TYPE
        or session._prepared is not prepared
        or not prepared.active
        or prepared.consumed
        or any(
            name in vars(session)
            for name in ("consume", "close", "verify_execution", "record_execution_event")
        )
    ):
        raise CoordinatorSecurityError("prepared admission is not genuine UNCONSUMED")
    _require_method(session, "consume", _SESSION_CONSUME, "producer consume")
    _require_method(session, "close", _SESSION_CLOSE, "producer close")
    _require_method(session, "verify_execution", _SESSION_VERIFY, "producer verification")
    _require_method(session, "record_execution_event", _SESSION_RECORD, "producer event writer")
    config = session.config
    if type(config) is not _ADMISSION_CONFIG_TYPE or config.test_only_paths:
        raise CoordinatorSecurityError("coordinator execution requires production admission")
    if config.evidence_path != EVIDENCE_ROOT / config.run_hex / "08-x05":
        raise CoordinatorSecurityError("coordinator evidence path is not internally canonical")
    return session, config


def _execute_bound(
    prepared: Any, source_bindings: _CapturedSourceBindings
) -> ExecutionResult:
    """Consume one genuine admission using one immutable captured binding.

    The binding is supplied by the caller that performed the pre-admission
    capture.  Keeping it as an explicit private argument prevents the
    post-prepare handoff from silently adopting a replacement receipt or
    source inode.
    """
    session, config = _execution_preconditions(prepared)
    if type(source_bindings) is not _CapturedSourceBindings:
        raise CoordinatorSecurityError("execution source binding is not canonical")
    # This is deliberately the last check before consume.  All continuing
    # guards below retain this exact object for the whole execution.
    _verify_source_bindings(source_bindings, config)
    consumed = _SESSION_CONSUME(session, prepared)
    if consumed is not prepared or not prepared.consumed:
        raise CoordinatorSecurityError("producer did not consume the same capability")
    _SESSION_VERIFY(session, prepared)
    _verify_source_bindings(source_bindings, config)
    evidence = _Evidence(config.evidence_path, config.required_uid)
    gates: dict[str, Any] = {}
    cleanup: dict[str, Any] = {}
    errors: list[str] = []
    experimental_failed = False
    execution_error = False
    builder: Any | None = None
    capture: Any | None = None
    probe: _ProbeSession | None = None
    control: _ControlSession | None = None
    restored = False
    restore_intent_attempted = False
    restore_intent_recorded = False
    stop_result: dict[str, Any] | None = None
    pcaps: dict[str, dict[str, Any]] | None = None

    def source_guard() -> None:
        _verify_graph()
        _verify_source_bindings(source_bindings, config)
        _SESSION_VERIFY(session, prepared)
        if builder is not None:
            builder._verify_authority()

    def remember(exc: BaseException, phase: str) -> None:
        nonlocal experimental_failed, execution_error
        if isinstance(exc, GateFailure):
            experimental_failed = True
        else:
            execution_error = True
        errors.append(phase + ":" + type(exc).__name__ + ":" + str(exc))

    events = _CoordinatorEvents(
        session=session,
        prepared=prepared,
        evidence=evidence,
        source_guard=source_guard,
    )

    try:
        events.state(
            "INTENT",
            {
                "phase": "before-runtime-build",
                "source_manifest_sha256": RUNTIME.REVIEWED_BUNDLE_MANIFEST_SHA256,
            },
        )
        builder = _BUILDER_FROM_ADMISSION(_RUNTIME_BUILDER_TYPE, prepared)
        gates["build"] = _BUILDER_BUILD(builder)
        source_guard()
        capture = _CAPTURE_FROM_BUILDER(_CAPTURE_SESSION_TYPE, builder)
        runtime_binding = builder._journal.binding()
        events.state(
            "BUILT",
            {
                "build_sha256": _digest(gates["build"]),
                "capture_contract_sha256": _digest(capture._contract),
                "runtime_journal_sha256": runtime_binding["artifact_sha256"],
                "runtime_journal_head_sha256": runtime_binding[
                    "journal_head_sha256"
                ],
            },
        )
        gates["capture_start"] = _CAPTURE_START(capture)
        source_guard()
        g1, g2 = _topologies(builder)
        gates["G1_before"] = _poll_gate(
            name="G1-before",
            runner=builder._runner,
            commands=_EVALUATOR_G1_COMMANDS(g1),
            evaluate=lambda collection: _EVALUATOR_G1(collection, g1),
            evidence=evidence,
            command_timeout=config.command_timeout,
            source_guard=source_guard,
        )
        _require_gate("G1 before", gates["G1_before"])
        gates["G2_before"] = _poll_gate(
            name="G2-before",
            runner=builder._runner,
            commands=_EVALUATOR_G2_COMMANDS(g2),
            evaluate=lambda collection: _EVALUATOR_G2(collection, g2),
            evidence=evidence,
            command_timeout=config.command_timeout,
            source_guard=source_guard,
        )
        _require_gate("G2 before", gates["G2_before"])
        probe = _ProbeSession(
            builder=builder,
            capture=capture,
            evidence=evidence,
            source_guard=source_guard,
        )
        for ordinal in range(1, 9):
            probe.run(ordinal, WINDOW_PLAN[ordinal - 1])
        gates["G3_provisional"] = {
            "status": "PASS",
            "windows": [window.detached() for window in probe.windows],
            "final": False,
        }
        control = _ControlSession(
            builder=builder,
            evidence=evidence,
            source_guard=source_guard,
        )
        material = control.prepare()
        baseline_document = dataclasses.asdict(material.baseline)
        baseline_document["a_ports"] = sorted(baseline_document["a_ports"])
        baseline_document["b_ports"] = sorted(baseline_document["b_ports"])
        gates["cas_baseline"] = {
            "status": "PASS",
            "baseline_sha256": _digest(baseline_document),
            "forward_snapshot_sha256": _digest(material.forward_snapshot),
            "inverse_snapshot_sha256": _digest(material.inverse_snapshot),
        }
        events.state(
            "BASELINE_PROVED",
            {
                "finality": "pending_capture_finalization",
                "g1_sha256": _digest(gates["G1_before"]),
                "g2_sha256": _digest(gates["G2_before"]),
                "g3_windows_sha256": _digest(gates["G3_provisional"]["windows"]),
                "cas_baseline_sha256": _digest(gates["cas_baseline"]),
            },
        )
        events.event(
            "control-forward-intent",
            "x05-coordinator-control-intent",
            {
                "state": "BASELINE_PROVED",
                "operation": "forward-b-to-a",
                "forward_transaction_sha256": _digest(
                    list(material.forward_transaction)
                ),
                "prepared_inverse_sha256": _digest(
                    list(material.inverse_transaction)
                ),
            },
        )
        gates["G5_control"] = control.move_to_a()
        for ordinal in range(9, 11):
            probe.run(ordinal, WINDOW_PLAN[ordinal - 1])
        gates["G5_provisional"] = {
            "status": "PASS",
            "control": copy.deepcopy(gates["G5_control"]),
            "windows": [window.detached() for window in probe.windows[8:10]],
            "final": False,
        }
        events.state(
            "LEAK_PROVED",
            {
                "finality": "pending_capture_finalization",
                "control_sha256": _digest(gates["G5_control"]),
                "windows_sha256": _digest(gates["G5_provisional"]["windows"]),
            },
        )
        restore_intent_attempted = True
        events.event(
            "control-restore-intent",
            "x05-coordinator-restore-intent",
            {
                "state": "LEAK_PROVED",
                "operation": "restore-a-to-b",
                "inverse_transaction_sha256": _digest(
                    list(material.inverse_transaction)
                ),
            },
        )
        restore_intent_recorded = True
        gates["G6_restore"] = control.restore_to_b()
        restored = True
        events.state(
            "RESTORED",
            {
                "finality": "pending_capture_finalization",
                "restore_sha256": _digest(gates["G6_restore"]),
            },
        )
        for ordinal in range(11, 13):
            probe.run(ordinal, WINDOW_PLAN[ordinal - 1])
        gates["G1_after"] = _poll_gate(
            name="G1-after",
            runner=builder._runner,
            commands=_EVALUATOR_G1_COMMANDS(g1),
            evaluate=lambda collection: _EVALUATOR_G1(collection, g1),
            evidence=evidence,
            command_timeout=config.command_timeout,
            source_guard=source_guard,
        )
        _require_gate("G1 after", gates["G1_after"])
        gates["G2_after"] = _poll_gate(
            name="G2-after",
            runner=builder._runner,
            commands=_EVALUATOR_G2_COMMANDS(g2),
            evaluate=lambda collection: _EVALUATOR_G2(collection, g2),
            evidence=evidence,
            command_timeout=config.command_timeout,
            source_guard=source_guard,
        )
        _require_gate("G2 after", gates["G2_after"])
    except BaseException as exc:
        remember(exc, "experiment")
    finally:
        if control is not None and control._forward_intent and not restored:
            material = control._material
            if material is None:
                remember(
                    CoordinatorSecurityError("restore intent lacks prepared inverse"),
                    "restore-intent",
                )
            elif not restore_intent_attempted:
                restore_intent_attempted = True
                try:
                    events.event(
                        "control-restore-intent",
                        "x05-coordinator-restore-intent",
                        {
                            "state": _COORDINATOR_STATES[events._state_index],
                            "operation": "restore-a-to-b-after-failure",
                            "inverse_transaction_sha256": _digest(
                                list(material.inverse_transaction)
                            ),
                        },
                    )
                    restore_intent_recorded = True
                except BaseException as exc:
                    remember(exc, "restore-intent")
            try:
                gates["G6_restore"] = control.restore_to_b()
                restored = True
            except BaseException as exc:
                remember(exc, "restore")
            if restored:
                try:
                    if events._state_index == _COORDINATOR_STATES.index("LEAK_PROVED"):
                        events.state(
                            "RESTORED",
                            {
                                "finality": "pending_capture_finalization",
                                "restore_sha256": _digest(gates["G6_restore"]),
                                "after_failure": True,
                            },
                        )
                    else:
                        events.event(
                            "control-restore-outcome",
                            "x05-coordinator-restore-outcome",
                            {
                                "status": "PASS",
                                "position": "B",
                                "restore_sha256": _digest(gates["G6_restore"]),
                                "intent_recorded": restore_intent_recorded,
                            },
                        )
                except BaseException as exc:
                    remember(exc, "restore-outcome")
        if capture is not None:
            try:
                stop_result = _CAPTURE_STOP(capture)
                cleanup["capture_stop"] = copy.deepcopy(stop_result)
            except BaseException as exc:
                remember(exc, "capture-stop")
        if probe is not None:
            try:
                probe.close()
            except BaseException as exc:
                remember(exc, "probe-close")

    if capture is not None and stop_result is not None:
        if (
            stop_result.get("state") == "STOPPED"
            and stop_result.get("ownership_status") == "PASS"
        ):
            try:
                pcaps = _CAPTURE_READ(capture)
                windows = () if probe is None else tuple(window.detached() for window in probe.windows)
                if len(windows) != len(WINDOW_PLAN) and experimental_failed:
                    gates["G4_capture_semantics"] = {
                        "status": "NOT_RUN",
                        "reason": "an earlier authoritative contradiction ended the fixed window sequence",
                        "completed_windows": len(windows),
                    }
                else:
                    semantic = decode_capture_evidence(pcaps, capture._contract, windows)
                    gates["G4_capture_semantics"] = semantic
                    evidence.json("capture-semantics.json", semantic)
                    if semantic["status"] == "FAIL":
                        experimental_failed = True
                        errors.append("capture-semantics:GateFailure:" + semantic.get("reason", "FAIL"))
                    elif semantic["status"] != "PASS":
                        execution_error = True
                        errors.append("capture-semantics:PacketError:" + semantic.get("reason", "ERROR"))
                    if semantic["status"] in {"PASS", "FAIL"}:
                        capture_finality = {
                            "status": semantic["status"],
                            "state": "STOPPED",
                            "window_count": len(windows),
                            "pcap_sha256": {
                                name: item["sha256"]
                                for name, item in sorted(pcaps.items())
                            },
                            "capture_stop_sha256": _digest(stop_result),
                            "semantic_sha256": _digest(semantic),
                        }
                        events.event(
                            "captures-finalized",
                            "x05-coordinator-captures-finalized",
                            capture_finality,
                        )
                        gates["captures_finalized"] = capture_finality
                        gate_status = (
                            "ERROR"
                            if execution_error
                            else "FAIL"
                            if experimental_failed or semantic["status"] == "FAIL"
                            else "PASS"
                        )
                        finalized = {
                            "status": gate_status,
                            "final": True,
                            "gates": {
                                "G1": gate_status,
                                "G2": gate_status,
                                "G3": gate_status,
                                "G4": gate_status,
                                "G5": gate_status,
                                "G6": gate_status,
                            },
                            "captures_finalized_sha256": _digest(capture_finality),
                        }
                        events.event(
                            "gates-finalized",
                            "x05-coordinator-gates-finalized",
                            finalized,
                        )
                        gates["G1_G6_final"] = finalized
            except BaseException as exc:
                remember(exc, "capture-read-decode")
        else:
            execution_error = True
            errors.append("capture-stop:PacketError:owned STOPPED custody was not proved")
        if stop_result.get("packet_status") != "PASS":
            execution_error = True
            errors.append("capture-stop:PacketError:structural packet finality failed")

    terminal_complete = False
    if (
        builder is not None
        and capture is not None
        and stop_result is not None
        and stop_result.get("state") == "STOPPED"
        and stop_result.get("ownership_status") == "PASS"
        and (control is None or not control._forward_intent or restored)
    ):
        try:
            cleanup["compensation"] = _BUILDER_COMPENSATE(builder)
            cleanup["final_absence"] = _BUILDER_FINAL_ABSENCE(builder)
            if stop_result.get("packet_status") == "PASS":
                cleanup["G7"] = builder._terminal_finalize_call()
                terminal_complete = cleanup["G7"].get("status") == "PASS"
            else:
                cleanup["G7"] = {
                    "status": "ERROR",
                    "reason": "structural capture finality prevents retained terminal release",
                }
        except BaseException as exc:
            remember(exc, "cleanup")

    if terminal_complete:
        try:
            _SESSION_CLOSE(session)
            if not session._closed or session._owned_m03:
                raise CoordinatorError("producer close did not prove G8")
            cleanup["G8"] = {"status": "PASS", "state": "ABSENT"}
        except BaseException as exc:
            remember(exc, "G8")

    gates["coordinator_events"] = events.detached()

    clean_pass = (
        terminal_complete
        and cleanup.get("G8", {}).get("status") == "PASS"
        and cleanup.get("final_absence", {}).get("status") == "PASS"
    )
    semantic_pass = gates.get("G4_capture_semantics", {}).get("status") == "PASS"
    if clean_pass and semantic_pass and not errors:
        status, verdict = "PASS", "PASS"
    elif clean_pass and experimental_failed and not execution_error:
        status, verdict = "FAIL", "FAIL"
    else:
        status, verdict = "ERROR", "ERROR"
    evidence_summary = {
        "run_hex": config.run_hex,
        "run_root": str(config.run_parent),
        "evidence_path": str(config.evidence_path),
        "pcap_sha256": (
            {} if pcaps is None else {name: item["sha256"] for name, item in pcaps.items()}
        ),
        "files": evidence.manifest(),
    }
    result = ExecutionResult(
        status=status,
        verdict=verdict,
        gates=gates,
        cleanup=cleanup,
        evidence=evidence_summary,
        errors=tuple(errors),
    )
    result_binding = evidence.json("execution-result.json", result.detached())
    manifest_binding = evidence.json("evidence-manifest.json", evidence.manifest())
    return ExecutionResult(
        status=result.status,
        verdict=result.verdict,
        gates=result.gates,
        cleanup=result.cleanup,
        evidence={
            **evidence_summary,
            "execution_result": result_binding,
            "manifest": manifest_binding,
        },
        errors=result.errors,
    )


def execute(prepared: Any) -> ExecutionResult:
    """Capture once, then consume one genuine admission through the private handoff."""
    _, config = _execution_preconditions(prepared)
    source_bindings = _capture_source_bindings(config)
    return _execute_bound(prepared, source_bindings)


def _dry_run() -> dict[str, Any]:
    _verify_graph()
    return {
        "schema": SCHEMA,
        "status": "READY",
        "mode": "dry-run",
        "writes": 0,
        "subprocesses": 0,
        "run_generated": False,
        "evidence_root": str(EVIDENCE_ROOT),
        "window_count": len(WINDOW_PLAN),
        "capture_count": len(_CAPTURE_POINT_IDS),
        "source_count": 4,
        "authorizes_mutation": False,
    }


def _required_environment() -> tuple[pathlib.Path, pathlib.Path, pathlib.Path]:
    names = ("M03_PREFLIGHT_RECEIPT", "M03_K01_KUBECONFIG", "M03_P003_KUBECONFIG")
    values: list[pathlib.Path] = []
    for name in names:
        value = os.environ.get(name)
        if not value or not value.strip():
            raise InputNotReady(name + " is required")
        path = pathlib.Path(value)
        if not path.is_absolute():
            raise InputNotReady(name + " must be an absolute path")
        values.append(path)
    return tuple(values)  # type: ignore[return-value]


def _exclusive_run_parent() -> tuple[str, pathlib.Path]:
    info = EVIDENCE_ROOT.lstat()
    if (
        stat.S_ISLNK(info.st_mode)
        or not stat.S_ISDIR(info.st_mode)
        or info.st_uid != 0
        or stat.S_IMODE(info.st_mode) & 0o022
    ):
        raise CoordinatorSecurityError("canonical evidence root is unsafe")
    for _attempt in range(32):
        run_hex = secrets.token_hex(3)
        path = EVIDENCE_ROOT / run_hex
        try:
            os.mkdir(path, 0o700)
        except FileExistsError:
            continue
        created = path.lstat()
        if created.st_uid != 0 or stat.S_IMODE(created.st_mode) != 0o700:
            raise CoordinatorSecurityError("exclusive run root is not private")
        _APPLY_FSYNC_DIRECTORY(EVIDENCE_ROOT)
        return run_hex, path
    raise CoordinatorError("could not allocate a unique six-hex run")


def _execute_cli() -> ExecutionResult:
    receipt, k01, p003 = _required_environment()
    if os.geteuid() != 0 or sys.platform != "linux":
        raise InputNotReady("production X05 execution requires Linux root")
    preflight_run_hex = secrets.token_hex(3)
    preflight_config = _ADMISSION_CONFIG_TYPE(
        run_hex=preflight_run_hex,
        evidence_path=EVIDENCE_ROOT / preflight_run_hex / "08-x05",
        receipt_path=receipt,
        k01_kubeconfig=k01,
        p003_kubeconfig=p003,
    )
    source_bindings = _capture_source_bindings(preflight_config)
    run_hex, run_parent = _exclusive_run_parent()
    config = _ADMISSION_CONFIG_TYPE(
        run_hex=run_hex,
        evidence_path=run_parent / "08-x05",
        receipt_path=receipt,
        k01_kubeconfig=k01,
        p003_kubeconfig=p003,
    )
    _verify_source_bindings(source_bindings, config)
    session = _ADMISSION_SESSION_TYPE(config)
    session.__enter__()
    prepared: Any | None = None
    try:
        prepared = session.prepare()
        _verify_source_bindings(source_bindings, config)
        return _execute_bound(prepared, source_bindings)
    except BaseException:
        consumed_handoff = (
            type(prepared) is _PREPARED_ADMISSION_TYPE
            and prepared._consumed is True
        )
        _close_pre_handoff_failure(session, consumed_handoff)
        raise


def _close_pre_handoff_failure(session: Any, consumed_handoff: bool) -> bool:
    """Use producer cleanup only before execute can enter terminal G7."""
    if consumed_handoff or getattr(session, "_closed", True):
        return False
    with contextlib.suppress(Exception):
        _SESSION_CLOSE(session)
        return True
    return False


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="x05-coordinator.py")
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--dry-run", action="store_true")
    modes.add_argument("--execute", action="store_true")
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        return int(exc.code)
    if args.dry_run:
        print(json.dumps(_dry_run(), sort_keys=True, separators=(",", ":")))
        return 0
    try:
        result = _execute_cli()
    except InputNotReady as exc:
        print("X05 NOT_READY: " + str(exc), file=sys.stderr)
        return 75
    except BaseException as exc:
        print(
            json.dumps(
                {
                    "schema": RESULT_SCHEMA,
                    "status": "ERROR",
                    "verdict": "ERROR",
                    "reason": type(exc).__name__ + ":" + str(exc),
                    "authorizes_mutation": False,
                },
                sort_keys=True,
                separators=(",", ":"),
            )
        )
        return 1
    print(json.dumps(result.detached(), sort_keys=True, separators=(",", ":")))
    return 0 if result.verdict == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
