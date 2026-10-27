#!/usr/bin/env python3
"""Run the guarded X05 forward/inverse Northbound transactions.

The command deliberately owns only the OVN Northbound part of X05.  Runtime
resources, probes, captures, and marker removal remain the responsibility of
the eventual X05 coordinator.  The public live modes are deliberately
disabled until the adapter has a complete read-only reconciliation path for a
committed-but-unverified forward transaction; dry-run is the only production
CLI mode.  Internal tests may inject a fake runner to exercise the bounded
orchestration without enabling a live subprocess.

``--dry-run`` is a local description of the sequence.  It does not inspect
the marker or lock, invoke a helper, create an evidence directory, or contact
Docker/OVSDB.
"""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import fcntl
import hashlib
import importlib.util
import json
import math
import os
import pathlib
import re
import stat
import subprocess
import sys
import time
import types
from collections.abc import Callable, Sequence
from typing import Any, Protocol


HERE = pathlib.Path(__file__).resolve().parent
EVALUATOR_PATH = HERE / "x05-evaluator.py"
MARKER_PATH = pathlib.Path("/run/labctl/dci-x05/active")
LOCK_PATH = pathlib.Path("/var/lock/labctl-dci-m03.lock")
CENTRAL_CONTAINER = "ovn-central-az1"
NB_SOCKET = "unix:/var/run/ovn/ovnnb_db.sock"
LOCK_FD = 9
RUN_RE = re.compile(r"[0-9a-f]{6}\Z")
CONTAINER_ID_RE = re.compile(r"[0-9a-f]{64}\Z")
IMAGE_ID_RE = re.compile(r"sha256:[0-9a-f]{64}\Z")
LOADED_ADAPTER_SOURCE = "<loaded-x05-nb-live.py>"


def _load_runtime_contract() -> Any:
    """Use the exact runtime module identity exported by the evaluator."""

    runtime_name = "x05_runtime_live_evaluator_contract"
    existing = sys.modules.get(runtime_name)
    if existing is not None:
        return existing
    evaluator_name = "x05_evaluator_nb_bridge_contract"
    evaluator = sys.modules.get(evaluator_name)
    if evaluator is None:
        spec = importlib.util.spec_from_file_location(evaluator_name, EVALUATOR_PATH)
        if spec is None or spec.loader is None:
            raise RuntimeError("cannot load the reviewed X05 evaluator contract")
        evaluator = importlib.util.module_from_spec(spec)
        sys.modules[evaluator_name] = evaluator
        spec.loader.exec_module(evaluator)
    runtime = evaluator.RUNTIME
    if runtime is not sys.modules.get(runtime_name):
        raise RuntimeError("X05 evaluator returned a non-canonical runtime contract")
    return runtime


RUNTIME = _load_runtime_contract()

# These are the reviewed producer implementations loaded with this adapter.
# Keeping the references prevents a later instance or class replacement from
# becoming execution authority merely because it has the same attribute name.
_ADMISSION_CONFIG_CLASS = RUNTIME.AdmissionConfig
_ADMISSION_SESSION_CLASS = RUNTIME.AdmissionSession
_PREPARED_ADMISSION_CLASS = RUNTIME.PreparedAdmission
_ADMISSION_ORIGIN_CLASS = RUNTIME._AdmissionOrigin
_EVENT_AUTHORITY_CLASS = RUNTIME._EventLogAuthority
_INCIDENT_RUNNER_CLASS = RUNTIME._IncidentTrackingRunner
_PRODUCER_RESULT_CLASS = RUNTIME.CommandResult
_PRODUCER_EVENT_LOG_CLASS = RUNTIME.DurableEventLog
_PRODUCER_COLLECTOR_CLASS = RUNTIME.LiveCollector
_PRODUCER_SUBPROCESS_RUNNER_CLASS = RUNTIME.SubprocessRunner
_PRODUCER_SUBPROCESS_RUN = _PRODUCER_SUBPROCESS_RUNNER_CLASS.run
_PRODUCER_RLOCK_TYPE = type(RUNTIME.threading.RLock())
_PREPARED_EXECUTION_SESSION = _PREPARED_ADMISSION_CLASS.execution_session
_PREPARED_CONSUMED = _PREPARED_ADMISSION_CLASS.consumed
_SESSION_VERIFY_EXECUTION = _ADMISSION_SESSION_CLASS.verify_execution
_SESSION_EXECUTION_CONTEXT = _ADMISSION_SESSION_CLASS.execution_context
_SESSION_RECORD_EXECUTION_EVENT = _ADMISSION_SESSION_CLASS.record_execution_event
_INCIDENT_RUNNER_RUN = _INCIDENT_RUNNER_CLASS.run
_EVENT_LOG_APPEND = _PRODUCER_EVENT_LOG_CLASS.append
_EVENT_LOG_VERIFY = _PRODUCER_EVENT_LOG_CLASS.verify
_PRODUCER_BASE_ENV = RUNTIME.BASE_ENV
_PRODUCER_MAX_OUTPUT = RUNTIME.MAX_OUTPUT

FORWARD_STAGES = (
    "preflight",
    "forward_tx",
    "forward_result",
    "forward_checked",
    "built_snapshot",
    "built_checked",
)
INVERSE_STAGES = (
    "preinverse_snapshot",
    "inverse_tx",
    "inverse_result",
    "inverse_checked",
    "clean_snapshot",
    "clean_checked",
)
ALL_STAGES = FORWARD_STAGES + INVERSE_STAGES

HELPER_DIGESTS = {
    "x05-nb-preflight.sh": "8b9cc7a2131f12874deb73fef34ca71ba638057254e394441a898bda819d3f43",
    "x05-nb-full-snapshot.sh": "c0a6c1c72e388e7b831d1327495701897167bc7647a01d10f6631aab6cb6ba7c",
    "x05-nb-tx.py": "ad32e9225b9c34939b7824252be3e411672aadbb45c895e4ecb89b370ce73d60",
    "x05-nb-postflight.py": "0ab7f273dc0129627c827c2960965d3fadff7e002e8ed655bc8a1073224acc15",
}


class AdapterError(RuntimeError):
    """The adapter cannot prove the requested local or live state."""

    def __init__(
        self,
        message: str,
        *,
        dispatched: bool = False,
        result: CommandResult | None = None,
    ) -> None:
        super().__init__(message)
        self.dispatched = dispatched
        self.result = result


class SecurityError(AdapterError):
    """A marker, lock, journal, or evidence boundary is not trusted."""


class AmbiguousCommit(AdapterError):
    """A mutation may have committed and its marker must be retained."""

    def __init__(self, message: str, *, result: CommandResult | None = None) -> None:
        super().__init__(message, dispatched=True, result=result)


class NotReady(AdapterError):
    """The public live entrypoint is intentionally fail-closed."""


class PostconditionError(AdapterError):
    """A live result or postflight status did not prove the contract."""


@dataclasses.dataclass(frozen=True)
class CommandResult:
    """The bounded result returned by a command runner."""

    returncode: int
    stdout: str
    stderr: str = ""
    raw_stdout: bytes | None = dataclasses.field(default=None, repr=False)
    raw_stderr: bytes | None = dataclasses.field(default=None, repr=False)

    @property
    def stdout_bytes(self) -> bytes:
        return self.stdout.encode() if self.raw_stdout is None else self.raw_stdout

    @property
    def stderr_bytes(self) -> bytes:
        return self.stderr.encode() if self.raw_stderr is None else self.raw_stderr


class CommandRunner(Protocol):
    def run(
        self,
        command: Sequence[str],
        timeout: float,
        *,
        pass_fds: Sequence[int] = (),
    ) -> CommandResult:
        """Run one argv vector without a shell."""


class SubprocessRunner:
    """Production runner with an explicit timeout for every subprocess."""

    def run(
        self,
        command: Sequence[str],
        timeout: float,
        *,
        pass_fds: Sequence[int] = (),
    ) -> CommandResult:
        if pass_fds:
            raise AdapterError("legacy subprocess runner does not accept inherited FDs")
        try:
            result = subprocess.run(
                list(command),
                capture_output=True,
                text=True,
                timeout=timeout,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise TimeoutError("command timed out: " + " ".join(command)) from exc
        except OSError as exc:
            raise AdapterError("command could not start: " + " ".join(command)) from exc
        return CommandResult(result.returncode, result.stdout, result.stderr)


def _require_original_method(
    owner: Any,
    name: str,
    implementation: Any,
    *,
    context: str,
) -> types.MethodType:
    """Return one exact bound method, rejecting instance/class substitution."""

    bound = getattr(owner, name, None)
    if (
        type(bound) is not types.MethodType
        or bound.__self__ is not owner
        or bound.__func__ is not implementation
        or name in vars(owner)
    ):
        raise SecurityError(context + " implementation changed")
    return bound


class _ProducerRunner:
    """Bridge the producer's bounded byte runner to the legacy text result."""

    def __init__(
        self,
        prepared: Any,
        verify_execution: types.MethodType,
        runner_call: types.MethodType,
    ) -> None:
        self.prepared = prepared
        self.verify_execution = verify_execution
        self.runner_call = runner_call

    def run(
        self,
        command: Sequence[str],
        timeout: float,
        *,
        pass_fds: Sequence[int] = (),
        _on_dispatch: Callable[[], None] | None = None,
    ) -> CommandResult:
        argv = tuple(command)
        inherited = tuple(pass_fds)
        if (
            isinstance(command, (str, bytes))
            or not argv
            or any(type(item) is not str or not item or "\x00" in item for item in argv)
            or type(timeout) not in (int, float)
            or not math.isfinite(timeout)
            or timeout <= 0
            or inherited not in {(), (LOCK_FD,)}
        ):
            raise AdapterError("producer command boundary received invalid arguments")
        try:
            self.verify_execution(self.prepared)
        except Exception as exc:
            raise SecurityError(
                "producer authority rejected the command before dispatch"
            ) from exc
        if _on_dispatch is not None:
            _on_dispatch()
        try:
            raw = self.runner_call(
                argv,
                env=_PRODUCER_BASE_ENV,
                timeout=timeout,
                pass_fds=inherited,
                max_output_bytes=_PRODUCER_MAX_OUTPUT,
            )
        except Exception as exc:
            raise AdapterError(
                "producer command outcome is unknown: " + str(exc),
                dispatched=True,
            ) from exc

        result: CommandResult | None = None
        validation_error: str | None = None
        if type(raw) is not _PRODUCER_RESULT_CLASS:
            validation_error = "producer runner returned an incomplete result"
        elif (
            type(raw.argv) is not tuple
            or raw.argv != argv
            or type(raw.returncode) is not int
            or type(raw.stdout) is not bytes
            or type(raw.stderr) is not bytes
            or type(raw.elapsed) not in (int, float)
            or not math.isfinite(raw.elapsed)
            or raw.elapsed < 0
        ):
            validation_error = "producer runner returned invalid result fields"
        elif len(raw.stdout) + len(raw.stderr) > _PRODUCER_MAX_OUTPUT:
            validation_error = "producer runner exceeded the combined output bound"
        elif raw.stderr:
            # Preserve both bounded byte streams without decoding either one.
            # Stderr is itself the rejection reason, including when it is not
            # valid UTF-8, so decoding must never change that classification.
            result = CommandResult(
                raw.returncode,
                "",
                "",
                raw_stdout=raw.stdout,
                raw_stderr=raw.stderr,
            )
            validation_error = "producer command returned stderr"
        else:
            try:
                stdout = raw.stdout.decode("utf-8", "strict")
                stderr = raw.stderr.decode("utf-8", "strict")
            except UnicodeDecodeError:
                result = CommandResult(
                    raw.returncode,
                    "",
                    "",
                    raw_stdout=raw.stdout,
                    raw_stderr=raw.stderr,
                )
                validation_error = "producer runner output is not strict UTF-8"
            else:
                result = CommandResult(
                    raw.returncode,
                    stdout,
                    stderr,
                    raw_stdout=raw.stdout,
                    raw_stderr=raw.stderr,
                )

        try:
            self.verify_execution(self.prepared)
        except Exception as exc:
            raise AdapterError(
                "producer authority changed after command dispatch",
                dispatched=True,
                result=result,
            ) from exc
        if validation_error is not None:
            raise AdapterError(
                validation_error,
                dispatched=True,
                result=result,
            )
        assert result is not None
        return result


_PRODUCER_BRIDGE_RUN = _ProducerRunner.run


@dataclasses.dataclass(frozen=True)
class RuntimePaths:
    """Fixed production paths; tests may inject a separate local instance."""

    helper_dir: pathlib.Path = HERE
    marker: pathlib.Path = MARKER_PATH
    lock: pathlib.Path = LOCK_PATH
    central_container: str = CENTRAL_CONTAINER
    nb_socket: str = NB_SOCKET


@dataclasses.dataclass(frozen=True)
class SecurityPolicy:
    """Filesystem identity policy.

    Production keeps both guards true.  Local mock tests use false so a
    temporary directory owned by the test user can exercise ordering and
    failure handling without pretending to be a remote root session.
    """

    require_root: bool = True
    require_helper_provenance: bool = True


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise AdapterError("duplicate JSON key: " + key)
        result[key] = value
    return result


def parse_json(text: str, *, context: str) -> Any:
    """Parse JSON strictly, including duplicate-key and non-finite checks."""

    if not isinstance(text, str) or not text.strip():
        raise AdapterError(context + ": empty JSON output")
    try:
        return json.loads(
            text,
            object_pairs_hook=_unique_object,
            parse_constant=lambda value: (_ for _ in ()).throw(
                AdapterError(context + ": non-finite JSON number: " + value)
            ),
        )
    except (json.JSONDecodeError, TypeError, AdapterError) as exc:
        if isinstance(exc, AdapterError):
            raise
        raise AdapterError(context + ": malformed JSON: " + str(exc)) from exc


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def _canonical_container_labels(
    value: Any, *, context: str
) -> tuple[tuple[str, str], ...]:
    if value is None:
        return ()
    if not isinstance(value, dict):
        raise SecurityError(context + " labels are malformed")
    if any(type(key) is not str or type(item) is not str for key, item in value.items()):
        raise SecurityError(context + " labels are malformed")
    return tuple(sorted(value.items()))


def _parse_central_container_identity(
    value: Any, *, context: str
) -> tuple[str, str, str, tuple[tuple[str, str], ...]]:
    if (
        not isinstance(value, list)
        or len(value) != 1
        or not isinstance(value[0], dict)
    ):
        raise SecurityError(context + " inspect result is malformed")
    container = value[0]
    state = container.get("State")
    config = container.get("Config")
    if (
        not isinstance(container.get("Id"), str)
        or CONTAINER_ID_RE.fullmatch(container["Id"]) is None
        or not isinstance(container.get("Name"), str)
        or not isinstance(container.get("Image"), str)
        or IMAGE_ID_RE.fullmatch(container["Image"]) is None
        or not isinstance(state, dict)
        or state.get("Status") != "running"
        or not isinstance(config, dict)
        or "Labels" not in config
    ):
        raise SecurityError(context + " identity is malformed or not running")
    labels = _canonical_container_labels(config["Labels"], context=context)
    return container["Id"], container["Name"], container["Image"], labels


def _assert_regular(path: pathlib.Path, *, context: str) -> os.stat_result:
    try:
        info = path.lstat()
    except OSError as exc:
        raise SecurityError(context + " is unavailable: " + str(path)) from exc
    if stat.S_ISLNK(info.st_mode):
        raise SecurityError(context + " must not be a symlink: " + str(path))
    if not stat.S_ISREG(info.st_mode):
        raise SecurityError(context + " must be a regular file: " + str(path))
    return info


def _assert_directory(
    path: pathlib.Path, *, context: str, policy: SecurityPolicy
) -> None:
    try:
        info = path.lstat()
    except OSError as exc:
        raise SecurityError(context + " is unavailable: " + str(path)) from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise SecurityError(context + " must be a non-symlink directory: " + str(path))
    if stat.S_IMODE(info.st_mode) != 0o700:
        raise SecurityError(context + " must have mode 0700: " + str(path))
    if policy.require_root and info.st_uid != 0:
        raise SecurityError(context + " must be root-owned: " + str(path))
    resolved = path.resolve()
    if resolved != path.absolute():
        raise SecurityError(context + " resolves through a symlink: " + str(path))


def _assert_owned_file(
    path: pathlib.Path,
    *,
    context: str,
    policy: SecurityPolicy,
    mode: int = 0o600,
) -> os.stat_result:
    info = _assert_regular(path, context=context)
    if stat.S_IMODE(info.st_mode) != mode:
        raise SecurityError(context + " must have mode %04o: %s" % (mode, path))
    if policy.require_root and info.st_uid != 0:
        raise SecurityError(context + " must be root-owned: " + str(path))
    return info


def _assert_helper_bundle(paths: RuntimePaths, policy: SecurityPolicy) -> None:
    """Verify the reviewed helper bundle before any live subprocess.

    The production bundle is immutable at execution time: its directory and
    every executable input are root-owned and have no write bits.  The four
    helper digests are reviewed values; the adapter itself is checked for
    identity and immutability but is not self-hashed.
    """

    helper_dir = paths.helper_dir.absolute()
    if not policy.require_helper_provenance:
        for filename in HELPER_DIGESTS:
            _assert_regular(helper_dir / filename, context="X05 helper")
        return
    try:
        directory_info = helper_dir.lstat()
    except OSError as exc:
        raise SecurityError(
            "X05 helper directory is unavailable: " + str(helper_dir)
        ) from exc
    if stat.S_ISLNK(directory_info.st_mode) or not stat.S_ISDIR(directory_info.st_mode):
        raise SecurityError("X05 helper directory must be a non-symlink directory")
    if directory_info.st_uid != 0:
        raise SecurityError("X05 helper directory must be root-owned")
    if stat.S_IMODE(directory_info.st_mode) & 0o222:
        raise SecurityError("X05 helper directory must not be writable")
    if helper_dir.resolve() != helper_dir:
        raise SecurityError("X05 helper directory resolves through a symlink")

    for filename, expected_digest in HELPER_DIGESTS.items():
        path = helper_dir / filename
        info = _assert_regular(path, context="X05 helper")
        if info.st_uid != 0:
            raise SecurityError("X05 helper must be root-owned: " + str(path))
        if stat.S_IMODE(info.st_mode) & 0o222:
            raise SecurityError("X05 helper must not be writable: " + str(path))
        actual_digest = hashlib.sha256(
            _read_bytes(path, context="X05 helper")
        ).hexdigest()
        if actual_digest != expected_digest:
            raise SecurityError("X05 helper digest mismatch: " + filename)

    adapter = helper_dir / "x05-nb-live.py"
    info = _assert_regular(adapter, context="X05 NB adapter")
    if info.st_uid != 0:
        raise SecurityError("X05 NB adapter must be root-owned")
    if stat.S_IMODE(info.st_mode) & 0o222:
        raise SecurityError("X05 NB adapter must not be writable")


def _source_identity(path: pathlib.Path) -> tuple[int, ...]:
    info = _assert_regular(path, context="X05 bound source")
    return (
        info.st_dev,
        info.st_ino,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
        info.st_mode,
        info.st_uid,
    )


def _capture_source_bindings(
    paths: RuntimePaths,
) -> dict[str, tuple[tuple[int, ...], str]]:
    bindings: dict[str, tuple[tuple[int, ...], str]] = {}
    sources = {
        **{
            filename: paths.helper_dir / filename
            for filename in (*HELPER_DIGESTS, "x05-nb-live.py")
        },
        LOADED_ADAPTER_SOURCE: pathlib.Path(__file__).resolve(),
    }
    for name, path in sources.items():
        bindings[name] = (
            _source_identity(path),
            hashlib.sha256(_read_bytes(path, context="X05 bound source")).hexdigest(),
        )
    if (
        bindings[LOADED_ADAPTER_SOURCE][1]
        != bindings["x05-nb-live.py"][1]
    ):
        raise SecurityError("loaded X05 NB adapter differs from the bound bundle source")
    return bindings


def _verify_source_bindings(
    paths: RuntimePaths,
    expected: dict[str, tuple[tuple[int, ...], str]],
) -> None:
    sources = {
        **{
            filename: paths.helper_dir / filename
            for filename in (*HELPER_DIGESTS, "x05-nb-live.py")
        },
        LOADED_ADAPTER_SOURCE: pathlib.Path(__file__).resolve(),
    }
    if set(expected) != set(sources):
        raise SecurityError("X05 source binding set changed")
    for name, path in sources.items():
        identity, digest = expected[name]
        if (
            _source_identity(path) != identity
            or hashlib.sha256(
                _read_bytes(path, context="X05 bound source")
            ).hexdigest()
            != digest
        ):
            raise SecurityError("X05 source identity changed: " + name)
    if expected[LOADED_ADAPTER_SOURCE][1] != expected["x05-nb-live.py"][1]:
        raise SecurityError("loaded X05 NB adapter binding changed")


def _atomic_write(path: pathlib.Path, payload: bytes, *, mode: int = 0o600) -> None:
    """Write a file and its containing directory durably without following links."""

    path = path.absolute()
    parent = path.parent
    _assert_directory(
        parent, context="evidence/marker parent", policy=SecurityPolicy(False)
    )
    if path.exists() or path.is_symlink():
        _assert_regular(path, context="existing artifact")
    temporary = parent / ("." + path.name + ".tmp-" + str(os.getpid()))
    if temporary.exists() or temporary.is_symlink():
        raise SecurityError("temporary artifact already exists: " + str(temporary))
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(temporary, flags | nofollow, mode)
    try:
        os.fchmod(fd, mode)
        view = memoryview(payload)
        while view:
            written = os.write(fd, view)
            view = view[written:]
        os.fsync(fd)
    finally:
        os.close(fd)
    try:
        os.replace(temporary, path)
        directory_fd = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            temporary.unlink()
        raise


def _read_text(path: pathlib.Path, *, context: str) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise SecurityError(context + " cannot be read: " + str(path)) from exc


def _read_bytes(path: pathlib.Path, *, context: str) -> bytes:
    try:
        return path.read_bytes()
    except OSError as exc:
        raise SecurityError(context + " cannot be read: " + str(path)) from exc


def validate_run(run_hex: str) -> str:
    if not isinstance(run_hex, str) or RUN_RE.fullmatch(run_hex) is None:
        raise AdapterError("run hex must be exactly six lowercase hexadecimal digits")
    return run_hex


def owner_for(run_hex: str) -> str:
    return "labctl-x05-" + validate_run(run_hex)


class Marker:
    """Validate the fixed X05 marker without changing global state."""

    def __init__(self, path: pathlib.Path, policy: SecurityPolicy) -> None:
        self.path = path
        self.policy = policy

    def _validate_parent(self) -> None:
        _assert_directory(
            self.path.parent, context="X05 marker parent", policy=self.policy
        )

    def read(self, run_hex: str) -> tuple[str, list[str]]:
        self._validate_parent()
        info = _assert_owned_file(self.path, context="X05 marker", policy=self.policy)
        if stat.S_IMODE(info.st_mode) != 0o600:
            raise SecurityError("X05 marker must be mode 0600")
        lines = _read_text(self.path, context="X05 marker").splitlines()
        values: dict[str, str] = {}
        for line in lines:
            if not line or "=" not in line:
                raise SecurityError("X05 marker has malformed line")
            key, value = line.split("=", 1)
            if not key or not value:
                raise SecurityError("X05 marker has empty key/value")
            if key in {"token", "owner", "run_hex", "state"} and key in values:
                raise SecurityError("X05 marker has duplicate " + key)
            if key in {"token", "owner", "run_hex", "state"}:
                values[key] = value
        expected_owner = owner_for(run_hex)
        if values.get("token") != expected_owner:
            raise SecurityError("X05 marker owner/run does not match this invocation")
        if "owner" in values and values["owner"] != expected_owner:
            raise SecurityError("X05 marker owner field does not match token")
        if "run_hex" in values and values["run_hex"] != run_hex:
            raise SecurityError("X05 marker run_hex does not match token")
        if "state" in values and values["state"] not in {
            "M03_ACTIVE",
            "INTENT",
            "BUILT",
            "RESTORE_INTENT",
            "X05_CLEANED",
        }:
            raise SecurityError("X05 marker has an unknown state")
        return expected_owner, lines


class LockValidator:
    """Check that FD 9 is the canonical, already-held DCI lock."""

    def __init__(self, paths: RuntimePaths) -> None:
        self.paths = paths

    @staticmethod
    def _fd_target(fd: int) -> pathlib.Path:
        for prefix in ("/proc/self/fd", "/dev/fd"):
            try:
                return pathlib.Path(os.readlink(f"{prefix}/{fd}")).resolve()
            except OSError:
                continue
        getpath = getattr(fcntl, "F_GETPATH", None)
        if getpath is not None:
            try:
                raw = fcntl.fcntl(fd, getpath, b"\0" * 1024)
                if isinstance(raw, bytes):
                    target = raw.split(b"\0", 1)[0].decode()
                    if target:
                        return pathlib.Path(target).resolve()
            except (OSError, UnicodeError):
                pass
        raise SecurityError("inherited lock FD 9 cannot be inspected")

    def validate(self) -> None:
        try:
            fd_info = os.fstat(LOCK_FD)
        except OSError as exc:
            raise SecurityError("inherited lock FD 9 is not open") from exc
        try:
            lock_info = self.paths.lock.stat()
        except OSError as exc:
            raise SecurityError("canonical DCI lock is unavailable") from exc
        fd_target = self._fd_target(LOCK_FD)
        canonical = self.paths.lock.resolve()
        if canonical != self.paths.lock.absolute():
            raise SecurityError(
                "canonical DCI lock path must not resolve through a symlink"
            )
        if fd_target != canonical:
            raise SecurityError("FD 9 does not resolve to the canonical DCI lock")
        if (fd_info.st_dev, fd_info.st_ino) != (lock_info.st_dev, lock_info.st_ino):
            raise SecurityError("FD 9 inode does not match the canonical DCI lock")
        # A non-blocking flock on FD 9 alone would silently acquire an
        # unlocked descriptor.  Probe through a distinct open descriptor first
        # so an inherited lock is distinguishable from an open-but-unlocked FD.
        probe_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        probe_fd = os.open(self.paths.lock, probe_flags)
        try:
            probe_info = os.fstat(probe_fd)
            if (probe_info.st_dev, probe_info.st_ino) != (
                lock_info.st_dev,
                lock_info.st_ino,
            ):
                raise SecurityError("canonical DCI lock changed during validation")
            try:
                fcntl.flock(probe_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                fcntl.flock(probe_fd, fcntl.LOCK_UN)
                raise SecurityError("FD 9 is open but the DCI lock is not held")
        finally:
            os.close(probe_fd)
        try:
            fcntl.flock(LOCK_FD, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            raise SecurityError("FD 9 does not hold the DCI lock") from exc


class Journal:
    """Durable, owner-bound evidence journal."""

    SCHEMA = "p004-x05-nb-live-journal-v1"
    STATES = frozenset(
        {
            "NB_ABSENT",
            "NB_FORWARD_INTENT",
            "NB_FORWARD_COMMITTED",
            "NB_FORWARD_AMBIGUOUS",
            "NB_FORWARD_VERIFIED",
            "NB_FORWARD_RECOVERY_INTENT",
            "NB_FORWARD_RECOVERY_BLOCKED",
            "NB_FORWARD_RECOVERED_VERIFIED",
            "NB_FORWARD_RECOVERED_CLEAN",
            "NB_INVERSE_INTENT",
            "NB_INVERSE_COMMITTED",
            "NB_INVERSE_AMBIGUOUS",
            "NB_INVERSE_VERIFIED",
        }
    )

    def __init__(
        self,
        path: pathlib.Path,
        *,
        owner: str,
        run_hex: str,
        policy: SecurityPolicy,
        marker_path: pathlib.Path = MARKER_PATH,
    ) -> None:
        self.path = path
        self.owner = owner
        self.run_hex = run_hex
        self.policy = policy
        self.marker_path = marker_path.absolute()
        self.document: dict[str, Any] = {}
        self._persisted_identity: tuple[int, ...] | None = None
        self._persisted_sha256: str | None = None

    @staticmethod
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

    def _remember_persisted(self, expected: bytes) -> None:
        info = _assert_owned_file(
            self.path, context="X05 journal", policy=self.policy
        )
        current = _read_bytes(self.path, context="X05 journal")
        if current != expected:
            raise SecurityError("X05 journal changed during durable publication")
        self._persisted_identity = self._identity(info)
        self._persisted_sha256 = hashlib.sha256(current).hexdigest()

    def verify_current(self) -> bytes:
        """Reject journal drift before any later atomic replacement."""

        if self._persisted_identity is None or self._persisted_sha256 is None:
            raise SecurityError("X05 journal has no trusted durable binding")
        info = _assert_owned_file(
            self.path, context="X05 journal", policy=self.policy
        )
        raw = _read_bytes(self.path, context="X05 journal")
        if (
            self._identity(info) != self._persisted_identity
            or hashlib.sha256(raw).hexdigest() != self._persisted_sha256
            or raw != canonical_json(self.document)
        ):
            raise SecurityError("X05 journal changed outside the bound adapter")
        return raw

    def create(self) -> None:
        if self.path.exists() or self.path.is_symlink():
            info = _assert_owned_file(
                self.path, context="X05 journal", policy=self.policy
            )
            del info
            existing = parse_json(
                _read_text(self.path, context="X05 journal"), context="X05 journal"
            )
            if not isinstance(existing, dict) or existing.get("owner") != self.owner:
                raise SecurityError("foreign X05 journal")
            raise SecurityError("X05 journal already exists; refusing a duplicate run")
        self.document = {
            "schema": self.SCHEMA,
            "owner": self.owner,
            "run_hex": self.run_hex,
            "evidence_dir": str(self.path.parent.absolute()),
            "marker": str(self.marker_path),
            "state": "NB_ABSENT",
            "events": [],
        }
        self.flush()

    def load_for_inverse(
        self,
        expected_prefix: Sequence[str],
        *,
        evidence_dir: pathlib.Path,
        marker_path: pathlib.Path,
    ) -> None:
        _assert_owned_file(self.path, context="X05 journal", policy=self.policy)
        document = parse_json(
            _read_text(self.path, context="X05 journal"), context="X05 journal"
        )
        if not isinstance(document, dict) or document.get("schema") != self.SCHEMA:
            raise SecurityError("invalid X05 journal schema")
        if (
            document.get("owner") != self.owner
            or document.get("run_hex") != self.run_hex
        ):
            raise SecurityError("foreign X05 journal")
        if document.get("state") != "NB_FORWARD_VERIFIED":
            raise SecurityError("X05 journal is not at the verified NB forward state")
        if document.get("evidence_dir") != str(evidence_dir.absolute()):
            raise SecurityError("X05 journal is bound to another evidence directory")
        if document.get("marker") != str(marker_path.absolute()):
            raise SecurityError("X05 journal is bound to another marker")
        events = document.get("events")
        if not isinstance(events, list):
            raise SecurityError("invalid X05 journal events")
        names = [
            event["artifact"]
            for event in events
            if isinstance(event, dict) and "artifact" in event
        ]
        if names != list(expected_prefix):
            raise SecurityError(
                "X05 journal artifact order is not the expected forward prefix"
            )
        self.document = document
        raw = _read_bytes(self.path, context="X05 journal")
        if raw != canonical_json(document):
            raise SecurityError("X05 journal is not canonical")
        self._remember_persisted(raw)

    def verify_artifacts(self, expected: Sequence[str], evidence: "Evidence") -> None:
        self.verify_current()
        events = self.document.get("events")
        if not isinstance(events, list):
            raise SecurityError("invalid X05 journal events")
        artifact_events = [
            event for event in events if isinstance(event, dict) and "artifact" in event
        ]
        if [event.get("artifact") for event in artifact_events] != list(expected):
            raise SecurityError("X05 journal artifact replay order changed")
        seen_paths: set[str] = set()
        for stage, event in zip(expected, artifact_events):
            path = evidence._path(stage)
            expected_name = path.name
            if event.get("path") != expected_name or expected_name in seen_paths:
                raise SecurityError("X05 journal artifact path binding changed")
            seen_paths.add(expected_name)
            _assert_owned_file(
                path, context="X05 evidence", policy=evidence.journal.policy
            )
            payload = _read_bytes(path, context="X05 evidence")
            if event.get("sha256") != hashlib.sha256(payload).hexdigest():
                raise SecurityError("X05 journal artifact hash mismatch: " + stage)

    def binding(self, expected: Sequence[str], evidence: "Evidence") -> dict[str, Any]:
        self.verify_artifacts(expected, evidence)
        raw = self.verify_current()
        return {
            "journal_path": str(self.path.absolute()),
            "journal_sha256": hashlib.sha256(raw).hexdigest(),
            "journal_state": self.document.get("state"),
        }

    def append(self, event: dict[str, Any], *, state: str | None = None) -> None:
        self.verify_current()
        events = self.document.setdefault("events", [])
        if not isinstance(events, list):
            raise SecurityError("invalid X05 journal events")
        events.append(event)
        if state is not None:
            if state not in self.STATES:
                raise SecurityError("invalid X05 NB journal state: " + state)
            if event.get("state") not in {None, state}:
                raise SecurityError("X05 journal state event mismatch")
            self.document["state"] = state
        self._write_document()

    def _write_document(self) -> None:
        payload = canonical_json(self.document)
        _atomic_write(self.path, payload)
        self._remember_persisted(payload)

    def flush(self) -> None:
        if self._persisted_identity is not None:
            self.verify_current()
        elif self.path.exists() or self.path.is_symlink():
            raise SecurityError("unbound X05 journal already exists")
        self._write_document()


class Evidence:
    """Enforce artifact ordering and make each file durable."""

    def __init__(
        self,
        directory: pathlib.Path,
        journal: Journal,
        *,
        next_stage: int = 0,
    ) -> None:
        self.directory = directory
        self.journal = journal
        self.next_stage = next_stage

    def _path(self, stage: str) -> pathlib.Path:
        return (
            self.directory
            / {
                "preflight": "preflight.json",
                "forward_tx": "forward-tx.json",
                "forward_result": "forward-result.raw.json",
                "forward_checked": "forward-checked.json",
                "built_snapshot": "built-snapshot.json",
                "built_checked": "built-checked.json",
                "preinverse_snapshot": "preinverse-snapshot.json",
                "inverse_tx": "inverse-tx.json",
                "inverse_result": "inverse-result.raw.json",
                "inverse_checked": "inverse-checked.json",
                "clean_snapshot": "clean-snapshot.json",
                "clean_checked": "clean-checked.json",
            }[stage]
        )

    def record(self, stage: str, payload: bytes, parsed: Any) -> pathlib.Path:
        if self.next_stage >= len(ALL_STAGES) or ALL_STAGES[self.next_stage] != stage:
            expected = (
                ALL_STAGES[self.next_stage]
                if self.next_stage < len(ALL_STAGES)
                else "<complete>"
            )
            raise AdapterError(f"evidence order expected {expected}, got {stage}")
        self.journal.verify_artifacts(ALL_STAGES[: self.next_stage], self)
        path = self._path(stage)
        if path.exists() or path.is_symlink():
            raise SecurityError("foreign or pre-existing X05 evidence: " + str(path))
        _atomic_write(path, payload)
        self.journal.append(
            {
                "kind": "artifact",
                "artifact": stage,
                "path": path.name,
                "sha256": hashlib.sha256(payload).hexdigest(),
                "status": parsed.get("status") if isinstance(parsed, dict) else None,
                "at_ns": time.time_ns(),
            }
        )
        self.next_stage += 1
        return path

    def record_command(
        self, stage: str, result: CommandResult
    ) -> tuple[pathlib.Path, Any]:
        try:
            parsed = parse_json(result.stdout, context=stage)
        except AdapterError:
            # Preserve the bytes that made the result ambiguous.  The caller
            # will retain the marker and report the parse failure.
            self.record(stage, result.stdout_bytes, None)
            raise
        return self.record(stage, result.stdout_bytes, parsed), parsed


@dataclasses.dataclass
class _OperationState:
    """Track the one serialized NB call without widening producer authority."""

    phase: str
    journal: Journal | None = None
    evidence: Evidence | None = None
    attempted: bool = False
    result: CommandResult | None = None

    def mark_attempted(self) -> None:
        self.attempted = True


def _require_status(value: Any, *, expected: str, context: str) -> dict[str, Any]:
    if not isinstance(value, dict) or value.get("status") != expected:
        status = value.get("status") if isinstance(value, dict) else None
        raise PostconditionError(
            f"{context} status is {status!r}, expected {expected!r}"
        )
    return value


def _require_run_identity(
    value: dict[str, Any], *, owner: str, run_hex: str, context: str
) -> None:
    if value.get("owner") != owner or value.get("run_hex") != run_hex:
        raise PostconditionError(context + " belongs to another X05 run")


def _require_transaction(value: Any, *, context: str) -> list[Any]:
    if not isinstance(value, list) or len(value) < 2 or value[0] != "OVN_Northbound":
        raise PostconditionError(context + " is not an OVN_Northbound transaction")
    return value


class NBAdapter:
    """Bounded X05 NB forward/inverse orchestrator."""

    def __init__(
        self,
        *,
        run_hex: str,
        evidence_dir: pathlib.Path,
        paths: RuntimePaths = RuntimePaths(),
        policy: SecurityPolicy = SecurityPolicy(),
        runner: CommandRunner | None = None,
        lock_validator: LockValidator | None = None,
        command_timeout: float = 30.0,
        _test_enable_live: bool = False,
    ) -> None:
        self.run_hex = validate_run(run_hex)
        self.owner = owner_for(self.run_hex)
        self.evidence_dir = evidence_dir.absolute()
        self.paths = paths
        self.policy = policy
        self.runner = runner or SubprocessRunner()
        self.lock_validator = lock_validator or LockValidator(paths)
        self.command_timeout = command_timeout
        self._test_enable_live = _test_enable_live
        self.marker = Marker(paths.marker, policy)
        self._producer_session: Any | None = None
        self._prepared: Any | None = None
        self._producer_origin: Any | None = None
        self._producer_event_authority: Any | None = None
        self._producer_config: Any | None = None
        self._producer_runner: _ProducerRunner | None = None
        self._producer_bridge_call: types.MethodType | None = None
        self._producer_runner_object: Any | None = None
        self._producer_runner_call: types.MethodType | None = None
        self._producer_delegate: Any | None = None
        self._producer_delegate_type: type[Any] | None = None
        self._producer_delegate_call: types.MethodType | None = None
        self._producer_delegate_run: Any | None = None
        self._producer_collector: Any | None = None
        self._producer_mutex: Any | None = None
        self._producer_event_log: Any | None = None
        self._producer_event_append: types.MethodType | None = None
        self._producer_event_verify: types.MethodType | None = None
        self._producer_verify_execution: types.MethodType | None = None
        self._producer_execution_context: types.MethodType | None = None
        self._producer_publish_event: types.MethodType | None = None
        self._expected_paths: RuntimePaths | None = None
        self._expected_policy: SecurityPolicy | None = None
        self._config_binding: tuple[Any, ...] | None = None
        self._source_bindings: dict[str, tuple[tuple[int, ...], str]] | None = None
        self._central_container_identity: (
            tuple[str, str, str, tuple[tuple[str, str], ...]] | None
        ) = None

    @staticmethod
    def _config_identity(config: Any) -> tuple[Any, ...]:
        return (id(config),) + tuple(
            (field.name, getattr(config, field.name))
            for field in dataclasses.fields(_ADMISSION_CONFIG_CLASS)
        )

    @classmethod
    def from_admission(cls, prepared: Any) -> "NBAdapter":
        """Bind the NB bridge to one original consumed producer capability."""

        if (
            type(prepared) is not _PREPARED_ADMISSION_CLASS
            or _PREPARED_ADMISSION_CLASS.execution_session
            is not _PREPARED_EXECUTION_SESSION
            or _PREPARED_ADMISSION_CLASS.consumed is not _PREPARED_CONSUMED
        ):
            raise SecurityError("NB bridge requires the canonical PreparedAdmission")
        origin = prepared._origin
        event_authority = prepared._event_authority
        if (
            type(origin) is not _ADMISSION_ORIGIN_CLASS
            or type(event_authority) is not _EVENT_AUTHORITY_CLASS
            or origin.session is not prepared._session
        ):
            raise SecurityError("NB bridge admission lacks original provenance")
        try:
            session = _PREPARED_EXECUTION_SESSION.__get__(
                prepared, _PREPARED_ADMISSION_CLASS
            )
            if type(session) is not _ADMISSION_SESSION_CLASS:
                raise SecurityError("NB bridge received a foreign admission producer")
        except SecurityError:
            raise
        except Exception as exc:
            raise SecurityError(
                "NB bridge admission is unconsumed, stale, or invalid"
            ) from exc
        config = origin.config
        if (
            type(config) is not _ADMISSION_CONFIG_CLASS
            or session._origin is not origin
            or session._event_authority is not event_authority
            or session.config is not config
            or not _PREPARED_CONSUMED.__get__(prepared, _PREPARED_ADMISSION_CLASS)
        ):
            raise SecurityError(
                "NB bridge admission is not an active consumed capability"
            )

        verify_execution = _require_original_method(
            session,
            "verify_execution",
            origin.session_verify_execution,
            context="producer verifier",
        )
        execution_context = _require_original_method(
            session,
            "execution_context",
            origin.session_execution_context,
            context="producer context",
        )
        publish_event = _require_original_method(
            session,
            "record_execution_event",
            origin.session_record_execution_event,
            context="producer publisher",
        )
        producer_runner_object = origin.runner
        producer_collector = origin.collector
        producer_event_log = origin.events
        producer_mutex = origin.consume_lock
        if (
            origin.session_verify_execution is not _SESSION_VERIFY_EXECUTION
            or origin.session_execution_context is not _SESSION_EXECUTION_CONTEXT
            or origin.session_record_execution_event
            is not _SESSION_RECORD_EXECUTION_EVENT
            or type(producer_runner_object) is not _INCIDENT_RUNNER_CLASS
            or origin.runner_type is not _INCIDENT_RUNNER_CLASS
            or origin.runner_run is not _INCIDENT_RUNNER_RUN
            or _INCIDENT_RUNNER_CLASS.run is not origin.runner_run
            or producer_runner_object._session is not session
            or type(producer_collector) is not _PRODUCER_COLLECTOR_CLASS
            or origin.collector_type is not _PRODUCER_COLLECTOR_CLASS
            or producer_collector.config is not config
            or producer_collector.runner is not producer_runner_object
            or type(producer_event_log) is not _PRODUCER_EVENT_LOG_CLASS
            or origin.events_type is not _PRODUCER_EVENT_LOG_CLASS
            or origin.event_append is not _EVENT_LOG_APPEND
            or origin.event_verify is not _EVENT_LOG_VERIFY
            or _PRODUCER_EVENT_LOG_CLASS.append is not origin.event_append
            or _PRODUCER_EVENT_LOG_CLASS.verify is not origin.event_verify
            or type(producer_mutex) is not _PRODUCER_RLOCK_TYPE
            or origin.consume_lock_type is not _PRODUCER_RLOCK_TYPE
        ):
            raise SecurityError("NB bridge producer authorities are not canonical")
        producer_runner_call = _require_original_method(
            producer_runner_object,
            "run",
            origin.runner_run,
            context="producer runner",
        )
        producer_delegate = origin.delegate
        producer_delegate_type = origin.delegate_type
        producer_delegate_run = origin.delegate_run
        if (
            type(producer_delegate) is not producer_delegate_type
            or getattr(producer_delegate_type, "run", None) is not producer_delegate_run
            or (
                not config.test_only_paths
                and (
                    producer_delegate_type is not _PRODUCER_SUBPROCESS_RUNNER_CLASS
                    or producer_delegate_run is not _PRODUCER_SUBPROCESS_RUN
                )
            )
        ):
            raise SecurityError("NB bridge producer delegate is not canonical")
        producer_delegate_call = _require_original_method(
            producer_delegate,
            "run",
            producer_delegate_run,
            context="producer delegate",
        )
        producer_event_append = _require_original_method(
            producer_event_log,
            "append",
            origin.event_append,
            context="producer event append",
        )
        producer_event_verify = _require_original_method(
            producer_event_log,
            "verify",
            origin.event_verify,
            context="producer event verifier",
        )
        try:
            context = execution_context(prepared)
        except Exception as exc:
            raise SecurityError(
                "NB bridge admission context is stale or invalid"
            ) from exc
        producer = context.get("producer") if isinstance(context, dict) else None
        context_paths = producer.get("paths") if isinstance(producer, dict) else None
        if (
            context.get("schema") != "p004-x05-execution-context-v1"
            or context.get("authorizes_mutation") is not False
            or not isinstance(producer, dict)
            or producer.get("run_hex") != config.run_hex
            or producer.get("owner") != config.owner
            or not isinstance(context_paths, dict)
            or context_paths.get("evidence") != str(config.evidence_path)
            or context_paths.get("events") != str(config.event_path)
            or context_paths.get("snapshot") != str(prepared.snapshot_path)
        ):
            raise SecurityError(
                "NB bridge execution context does not match its producer"
            )
        snapshot = context.get("snapshot")
        sections = snapshot.get("sections") if isinstance(snapshot, dict) else None
        dci = sections.get("dci") if isinstance(sections, dict) else None
        expected_names = (
            dci.get("expected_cluster_names") if isinstance(dci, dict) else None
        )
        container_ids = dci.get("container_ids") if isinstance(dci, dict) else None
        container_labels = (
            dci.get("container_labels") if isinstance(dci, dict) else None
        )
        central_id = (
            container_ids.get(CENTRAL_CONTAINER)
            if isinstance(container_ids, dict)
            else None
        )
        if (
            not isinstance(expected_names, list)
            or any(type(name) is not str for name in expected_names)
            or len(expected_names) != len(set(expected_names))
            or CENTRAL_CONTAINER not in expected_names
            or not isinstance(central_id, str)
            or CONTAINER_ID_RE.fullmatch(central_id) is None
            or not isinstance(container_labels, dict)
            or CENTRAL_CONTAINER not in container_labels
        ):
            raise SecurityError(
                "NB bridge lacks the captured central container identity"
            )
        central_labels = _canonical_container_labels(
            container_labels[CENTRAL_CONTAINER],
            context="captured central container",
        )

        paths = RuntimePaths(
            helper_dir=config.bundle_root / "studies/p004/ovn",
            marker=config.x05_marker_path,
            lock=config.lock_path,
            central_container=CENTRAL_CONTAINER,
            nb_socket=NB_SOCKET,
        )
        policy = SecurityPolicy(
            require_root=not config.test_only_paths,
            require_helper_provenance=not config.test_only_paths,
        )
        _assert_helper_bundle(paths, policy)
        source_bindings = _capture_source_bindings(paths)
        producer_runner = _ProducerRunner(
            prepared,
            verify_execution,
            producer_runner_call,
        )
        producer_bridge_call = _require_original_method(
            producer_runner,
            "run",
            _PRODUCER_BRIDGE_RUN,
            context="producer bridge",
        )
        adapter = cls(
            run_hex=config.run_hex,
            evidence_dir=config.evidence_path,
            paths=paths,
            policy=policy,
            runner=producer_runner,
            command_timeout=config.command_timeout,
        )
        adapter._producer_session = session
        adapter._prepared = prepared
        adapter._producer_origin = origin
        adapter._producer_event_authority = event_authority
        adapter._producer_config = config
        adapter._producer_runner = producer_runner
        adapter._producer_bridge_call = producer_bridge_call
        adapter._producer_runner_object = producer_runner_object
        adapter._producer_runner_call = producer_runner_call
        adapter._producer_delegate = producer_delegate
        adapter._producer_delegate_type = producer_delegate_type
        adapter._producer_delegate_call = producer_delegate_call
        adapter._producer_delegate_run = producer_delegate_run
        adapter._producer_collector = producer_collector
        adapter._producer_mutex = producer_mutex
        adapter._producer_event_log = producer_event_log
        adapter._producer_event_append = producer_event_append
        adapter._producer_event_verify = producer_event_verify
        adapter._producer_verify_execution = verify_execution
        adapter._producer_execution_context = execution_context
        adapter._producer_publish_event = publish_event
        adapter._expected_paths = paths
        adapter._expected_policy = policy
        adapter._config_binding = cls._config_identity(config)
        adapter._source_bindings = source_bindings
        adapter._verify_factory_binding()
        central_identity = adapter._inspect_central_container()
        if (
            central_identity[0] != central_id
            or central_identity[1] != "/" + CENTRAL_CONTAINER
            or central_identity[3] != central_labels
        ):
            raise SecurityError(
                "central container factory identity differs from the verified snapshot"
            )
        adapter._central_container_identity = central_identity
        adapter._verify_factory_binding()
        return adapter

    @property
    def _producer_bound(self) -> bool:
        return self._producer_session is not None

    def _verify_factory_binding(self) -> None:
        if not self._producer_bound:
            return
        assert self._producer_session is not None
        assert self._prepared is not None
        assert self._producer_origin is not None
        assert self._producer_event_authority is not None
        assert self._producer_config is not None
        assert self._producer_runner is not None
        assert self._producer_bridge_call is not None
        assert self._producer_runner_object is not None
        assert self._producer_runner_call is not None
        assert self._producer_delegate is not None
        assert self._producer_delegate_type is not None
        assert self._producer_delegate_call is not None
        assert self._producer_delegate_run is not None
        assert self._producer_collector is not None
        assert self._producer_mutex is not None
        assert self._producer_event_log is not None
        assert self._producer_event_append is not None
        assert self._producer_event_verify is not None
        assert self._producer_verify_execution is not None
        assert self._producer_execution_context is not None
        assert self._producer_publish_event is not None
        assert self._expected_paths is not None
        assert self._expected_policy is not None
        assert self._config_binding is not None
        assert self._source_bindings is not None
        if (
            type(self._producer_origin) is not _ADMISSION_ORIGIN_CLASS
            or type(self._producer_event_authority) is not _EVENT_AUTHORITY_CLASS
            or self._producer_origin.session is not self._producer_session
            or self._prepared._origin is not self._producer_origin
            or self._prepared._event_authority
            is not self._producer_event_authority
            or self._producer_session._origin is not self._producer_origin
            or self._producer_session._event_authority
            is not self._producer_event_authority
            or self._producer_origin.config is not self._producer_config
            or self._producer_session.config is not self._producer_config
            or type(self._producer_session) is not _ADMISSION_SESSION_CLASS
            or type(self._prepared) is not _PREPARED_ADMISSION_CLASS
            or _PREPARED_ADMISSION_CLASS.execution_session
            is not _PREPARED_EXECUTION_SESSION
            or _PREPARED_ADMISSION_CLASS.consumed is not _PREPARED_CONSUMED
            or _ADMISSION_SESSION_CLASS.verify_execution
            is not self._producer_origin.session_verify_execution
            or _ADMISSION_SESSION_CLASS.execution_context
            is not self._producer_origin.session_execution_context
            or _ADMISSION_SESSION_CLASS.record_execution_event
            is not self._producer_origin.session_record_execution_event
            or self._producer_session.runner is not self._producer_runner_object
            or self._producer_origin.runner is not self._producer_runner_object
            or self._producer_origin.runner_type is not _INCIDENT_RUNNER_CLASS
            or self._producer_origin.runner_run is not _INCIDENT_RUNNER_RUN
            or _ProducerRunner.run is not _PRODUCER_BRIDGE_RUN
            or self._producer_runner.prepared is not self._prepared
            or self._producer_runner.verify_execution
            is not self._producer_verify_execution
            or self._producer_runner.runner_call is not self._producer_runner_call
            or type(self._producer_runner_object) is not _INCIDENT_RUNNER_CLASS
            or _INCIDENT_RUNNER_CLASS.run is not _INCIDENT_RUNNER_RUN
            or self._producer_runner_object._session is not self._producer_session
            or self._producer_runner_object._delegate is not self._producer_delegate
            or self._producer_origin.delegate is not self._producer_delegate
            or self._producer_origin.delegate_type is not self._producer_delegate_type
            or self._producer_origin.delegate_run is not self._producer_delegate_run
            or type(self._producer_delegate) is not self._producer_delegate_type
            or getattr(self._producer_delegate_type, "run", None)
            is not self._producer_delegate_run
            or (
                not self._producer_config.test_only_paths
                and self._producer_delegate_run is not _PRODUCER_SUBPROCESS_RUN
            )
            or self._producer_session.collector is not self._producer_collector
            or self._producer_origin.collector is not self._producer_collector
            or type(self._producer_collector) is not _PRODUCER_COLLECTOR_CLASS
            or self._producer_collector.config is not self._producer_config
            or self._producer_collector.runner is not self._producer_runner_object
            or self._producer_session._consume_lock is not self._producer_mutex
            or self._producer_origin.consume_lock is not self._producer_mutex
            or type(self._producer_mutex) is not _PRODUCER_RLOCK_TYPE
            or self._producer_session.events is not self._producer_event_log
            or self._producer_origin.events is not self._producer_event_log
            or type(self._producer_event_log) is not _PRODUCER_EVENT_LOG_CLASS
            or self._producer_origin.event_append is not _EVENT_LOG_APPEND
            or self._producer_origin.event_verify is not _EVENT_LOG_VERIFY
            or _PRODUCER_EVENT_LOG_CLASS.append
            is not self._producer_origin.event_append
            or _PRODUCER_EVENT_LOG_CLASS.verify
            is not self._producer_origin.event_verify
            or self._config_identity(self._producer_config) != self._config_binding
            or self.run_hex != self._producer_config.run_hex
            or self.owner != self._producer_config.owner
            or self.evidence_dir != self._producer_config.evidence_path.absolute()
            or self.paths != self._expected_paths
            or self.policy != self._expected_policy
            or self.runner is not self._producer_runner
            or self.command_timeout != self._producer_config.command_timeout
            or self.marker.path != self._expected_paths.marker
        ):
            raise SecurityError("NB bridge producer/config/path binding changed")
        for owner, name, implementation, expected in (
            (
                self._producer_runner,
                "run",
                _PRODUCER_BRIDGE_RUN,
                self._producer_bridge_call,
            ),
            (
                self._producer_session,
                "verify_execution",
                self._producer_origin.session_verify_execution,
                self._producer_verify_execution,
            ),
            (
                self._producer_session,
                "execution_context",
                self._producer_origin.session_execution_context,
                self._producer_execution_context,
            ),
            (
                self._producer_session,
                "record_execution_event",
                self._producer_origin.session_record_execution_event,
                self._producer_publish_event,
            ),
            (
                self._producer_runner_object,
                "run",
                self._producer_origin.runner_run,
                self._producer_runner_call,
            ),
            (
                self._producer_delegate,
                "run",
                self._producer_delegate_run,
                self._producer_delegate_call,
            ),
            (
                self._producer_event_log,
                "append",
                self._producer_origin.event_append,
                self._producer_event_append,
            ),
            (
                self._producer_event_log,
                "verify",
                self._producer_origin.event_verify,
                self._producer_event_verify,
            ),
        ):
            current = _require_original_method(
                owner,
                name,
                implementation,
                context="producer " + name,
            )
            if (
                current.__self__ is not expected.__self__
                or current.__func__ is not expected.__func__
            ):
                raise SecurityError("NB bridge captured producer method changed")
        self._producer_verify_execution(self._prepared)
        _verify_source_bindings(self.paths, self._source_bindings)

    def _inspect_central_container(
        self,
    ) -> tuple[str, str, str, tuple[tuple[str, str], ...]]:
        self._verify_factory_binding()
        if self._producer_bound:
            assert self._producer_bridge_call is not None
            result = self._producer_bridge_call(
                ("docker", "container", "inspect", CENTRAL_CONTAINER),
                timeout=self.command_timeout,
            )
        else:
            result = self.runner.run(
                ("docker", "container", "inspect", CENTRAL_CONTAINER),
                timeout=self.command_timeout,
            )
        self._require_command_success(result, context="central container identity")
        value = parse_json(result.stdout, context="central container identity")
        identity = _parse_central_container_identity(
            value, context="central container"
        )
        self._verify_factory_binding()
        return identity

    def _verify_central_container(self) -> None:
        if not self._producer_bound:
            return
        assert self._central_container_identity is not None
        if self._inspect_central_container() != self._central_container_identity:
            raise SecurityError("central container identity changed")

    def _prepare_live(self) -> None:
        if self._producer_bound:
            self._verify_factory_binding()
            _assert_directory(
                self.evidence_dir,
                context="private X05 evidence directory",
                policy=self.policy,
            )
            owner, _ = self.marker.read(self.run_hex)
            if owner != self.owner:
                raise SecurityError("X05 marker owner mismatch")
            _assert_helper_bundle(self.paths, self.policy)
            self._verify_factory_binding()
            self._verify_central_container()
            return
        if not self._test_enable_live or isinstance(self.runner, SubprocessRunner):
            raise NotReady(
                "X05 NB live modes are disabled until committed-forward reconciliation "
                "and ambiguous-timeout recovery are complete; production subprocesses "
                "are unavailable"
            )
        if self.policy.require_root and os.geteuid() != 0:
            raise SecurityError("X05 NB live adapter requires root")
        _assert_directory(
            self.evidence_dir,
            context="private X05 evidence directory",
            policy=self.policy,
        )
        self.lock_validator.validate()
        owner, _ = self.marker.read(self.run_hex)
        if owner != self.owner:
            raise SecurityError("X05 marker owner mismatch")
        _assert_helper_bundle(self.paths, self.policy)

    def _command(
        self,
        command: Sequence[str],
        *,
        context: str,
        pass_fds: Sequence[int] = (),
        central_name_helper: bool = False,
        on_dispatch: Callable[[], None] | None = None,
    ) -> CommandResult:
        if self._producer_bound:
            self._verify_factory_binding()
            if central_name_helper:
                self._verify_central_container()
        try:
            if self._producer_bound:
                assert self._producer_bridge_call is not None
                result = self._producer_bridge_call(
                    command,
                    timeout=self.command_timeout,
                    pass_fds=pass_fds,
                    _on_dispatch=on_dispatch,
                )
            else:
                if on_dispatch is not None:
                    on_dispatch()
                result = self.runner.run(command, timeout=self.command_timeout)
        except TimeoutError as exc:
            raise AdapterError(context + " timed out", dispatched=True) from exc
        except AdapterError:
            raise
        if not isinstance(result, CommandResult):
            raise AdapterError(context + " returned an invalid runner result")
        if self._producer_bound:
            try:
                self._verify_factory_binding()
                if central_name_helper:
                    self._verify_central_container()
            except Exception as exc:
                raise AdapterError(
                    context + " binding changed after dispatch",
                    dispatched=True,
                    result=result,
                ) from exc
        return result

    def _helper_json(
        self, command: Sequence[str], *, context: str
    ) -> tuple[CommandResult, Any]:
        result = self._command(
            command, context=context, central_name_helper=self._producer_bound
        )
        try:
            parsed = parse_json(result.stdout, context=context)
        except AdapterError:
            raise AdapterError(context + " did not return JSON")
        return result, parsed

    @staticmethod
    def _require_command_success(result: CommandResult, *, context: str) -> None:
        if result.returncode != 0:
            raise AdapterError(
                context + " failed with exit status " + str(result.returncode)
            )

    def _ovsdb(
        self,
        transaction: Any,
        *,
        context: str,
        operation: _OperationState | None = None,
    ) -> CommandResult:
        payload = json.dumps(transaction, sort_keys=True, separators=(",", ":"))
        if self._producer_bound:
            self._verify_factory_binding()
            self._verify_central_container()
            assert self._central_container_identity is not None
            central_target = self._central_container_identity[0]
        else:
            central_target = self.paths.central_container
        command = [
            "docker",
            "exec",
            central_target,
            "ovsdb-client",
            "transact",
            self.paths.nb_socket,
            payload,
        ]
        try:
            result = self._command(
                command,
                context=context,
                pass_fds=(LOCK_FD,) if self._producer_bound else (),
                on_dispatch=operation.mark_attempted if operation is not None else None,
            )
        except TimeoutError as exc:
            raise AmbiguousCommit(
                context + " timed out; commit state is unknown"
            ) from exc
        except AdapterError as exc:
            if exc.dispatched:
                if operation is not None:
                    operation.result = exc.result
                raise AmbiguousCommit(
                    context + "; commit state is unknown: " + str(exc),
                    result=exc.result,
                ) from exc
            raise
        if not isinstance(result, CommandResult):
            raise AmbiguousCommit(context + " returned no trustworthy result")
        if self._producer_bound:
            try:
                self._verify_central_container()
            except Exception as exc:
                raise AmbiguousCommit(
                    context + "; central identity changed after dispatch",
                    result=result,
                ) from exc
        try:
            parse_json(result.stdout, context=context + " raw result")
        except AdapterError as exc:
            raise AmbiguousCommit(
                context + " returned malformed JSON; commit state is unknown",
                result=result,
            ) from exc
        if result.returncode != 0:
            raise AmbiguousCommit(
                context + " exited nonzero; commit state is unknown",
                result=result,
            )
        if operation is not None:
            operation.result = result
        return result

    def _producer_chain_binding(self) -> dict[str, Any]:
        assert self._prepared is not None
        assert self._producer_event_verify is not None
        chain = self._producer_event_verify()
        if (
            type(chain) is not dict
            or type(chain.get("count")) is not int
            or chain["count"] < 0
            or type(chain.get("head_sha256")) is not str
            or CONTAINER_ID_RE.fullmatch(chain["head_sha256"]) is None
            or type(chain.get("file_sha256")) is not str
            or CONTAINER_ID_RE.fullmatch(chain["file_sha256"]) is None
            or self._prepared._event_count != chain["count"]
            or self._prepared._event_head != chain["head_sha256"]
        ):
            raise SecurityError("producer durable event binding is invalid")
        return chain

    @staticmethod
    def _verify_published_record(
        record: Any,
        *,
        event: str,
        payload: dict[str, Any],
        before: dict[str, Any],
        after: dict[str, Any],
    ) -> None:
        wrapped = record.get("detail") if type(record) is dict else None
        if (
            type(record) is not dict
            or record.get("sequence") != before["count"] + 1
            or record.get("event") != event
            or record.get("previous_sha256") != before["head_sha256"]
            or record.get("event_sha256") != after["head_sha256"]
            or after["count"] != before["count"] + 1
            or after["head_sha256"] == before["head_sha256"]
            or not isinstance(wrapped, dict)
            or wrapped.get("detail") != payload
        ):
            raise SecurityError(
                "producer publication did not durably append the intended record"
            )

    def _publish_event(
        self,
        event: str,
        detail: dict[str, Any],
        *,
        journal: Journal,
        evidence: Evidence,
        require_central_identity: bool = True,
    ) -> None:
        if not self._producer_bound:
            return
        assert self._prepared is not None
        assert self._producer_mutex is not None
        assert self._producer_publish_event is not None
        with self._producer_mutex:
            self._verify_factory_binding()
            if require_central_identity:
                self._verify_central_container()
            else:
                self._inspect_central_container()
            expected = ALL_STAGES[: evidence.next_stage]
            evidence_before = journal.binding(expected, evidence)
            chain_before = self._producer_chain_binding()
            payload = {**detail, **evidence_before}
            record = self._producer_publish_event(self._prepared, event, payload)
            chain_after = self._producer_chain_binding()
            self._verify_published_record(
                record,
                event=event,
                payload=payload,
                before=chain_before,
                after=chain_after,
            )
            evidence_after = journal.binding(expected, evidence)
            if evidence_after != evidence_before:
                raise SecurityError("NB evidence changed during producer publication")
            self._verify_factory_binding()
            if require_central_identity:
                self._verify_central_container()
            else:
                self._inspect_central_container()

    def _record_artifact(
        self,
        evidence: Evidence,
        stage: str,
        payload: bytes,
        parsed: Any,
        *,
        event: str = "x05-nb-artifact",
    ) -> pathlib.Path:
        path = evidence.record(stage, payload, parsed)
        self._publish_event(
            event,
            {
                "stage": stage,
                "status": parsed.get("status") if isinstance(parsed, dict) else None,
                "artifact_path": str(path.absolute()),
                "artifact_sha256": hashlib.sha256(payload).hexdigest(),
            },
            journal=evidence.journal,
            evidence=evidence,
        )
        return path

    def _record_command_artifact(
        self,
        evidence: Evidence,
        stage: str,
        result: CommandResult,
        *,
        event: str = "x05-nb-artifact",
    ) -> tuple[pathlib.Path, Any]:
        try:
            parsed = parse_json(result.stdout, context=stage)
        except AdapterError:
            self._record_artifact(
                evidence, stage, result.stdout_bytes, None, event=event
            )
            raise
        return (
            self._record_artifact(
                evidence, stage, result.stdout_bytes, parsed, event=event
            ),
            parsed,
        )

    def _record_mutation_prepare(
        self, journal: Journal, evidence: Evidence, *, phase: str, tx: Any
    ) -> None:
        if phase == "forward":
            state = "NB_FORWARD_INTENT"
        elif phase == "inverse":
            state = "NB_INVERSE_INTENT"
        else:
            raise AdapterError("unknown X05 NB mutation phase: " + phase)
        transaction_sha256 = hashlib.sha256(canonical_json(tx)).hexdigest()
        journal.append(
            {
                "kind": "mutation-prepared",
                "phase": phase,
                "owner": self.owner,
                "run_hex": self.run_hex,
                "transaction_sha256": transaction_sha256,
                "at_ns": time.time_ns(),
            },
            state=state,
        )
        self._publish_event(
            "x05-nb-intent",
            {
                "phase": phase,
                "stage": phase + "_tx",
                "status": "INTENT",
                "transaction_sha256": transaction_sha256,
            },
            journal=journal,
            evidence=evidence,
        )

    def _record_mutation_outcome(
        self,
        journal: Journal,
        evidence: Evidence,
        *,
        phase: str,
        result: CommandResult | None,
        ambiguous: bool,
    ) -> None:
        if phase == "forward":
            state = "NB_FORWARD_AMBIGUOUS" if ambiguous else "NB_FORWARD_COMMITTED"
        elif phase == "inverse":
            state = "NB_INVERSE_AMBIGUOUS" if ambiguous else "NB_INVERSE_COMMITTED"
        else:
            raise AdapterError("unknown X05 NB mutation phase: " + phase)
        stdout_sha256 = hashlib.sha256(
            result.stdout_bytes if result is not None else b""
        ).hexdigest()
        stderr_sha256 = hashlib.sha256(
            result.stderr_bytes if result is not None else b""
        ).hexdigest()
        journal.append(
            {
                "kind": "mutation-outcome",
                "phase": phase,
                "returncode": result.returncode if result is not None else None,
                "stdout_sha256": stdout_sha256,
                "ambiguous": ambiguous,
                "at_ns": time.time_ns(),
            },
            state=state,
        )
        self._publish_event(
            "x05-nb-outcome",
            {
                "phase": phase,
                "stage": phase + "_result",
                "status": "AMBIGUOUS" if ambiguous else "COMMITTED",
                "returncode": result.returncode if result is not None else None,
                "stdout_sha256": stdout_sha256,
                "stderr_sha256": stderr_sha256,
            },
            journal=journal,
            evidence=evidence,
        )

    def _retain_ambiguous_outcome(
        self,
        journal: Journal,
        evidence: Evidence,
        *,
        phase: str,
        result: CommandResult | None,
    ) -> None:
        """Best-effort the local outcome without masking AmbiguousCommit.

        Producer authority can become sticky after the transaction was handed
        to the runner.  The NB journal is still allowed to retain its bounded
        raw outcome when its own binding remains intact, while a producer
        publication failure must not replace the transaction ambiguity with a
        different exception.  A failed artifact binding prevents the later
        journal append, so corrupted evidence is never overwritten.
        """

        stage = phase + "_result"
        stage_index = ALL_STAGES.index(stage)
        if evidence.next_stage == stage_index:
            try:
                if result is None:
                    self._record_artifact(
                        evidence,
                        stage,
                        b"",
                        None,
                        event="x05-nb-outcome-artifact",
                    )
                else:
                    self._record_command_artifact(
                        evidence,
                        stage,
                        result,
                        event="x05-nb-outcome-artifact",
                    )
            except Exception:
                pass
        if evidence.next_stage != stage_index + 1:
            return
        expected_intent = (
            "NB_FORWARD_INTENT" if phase == "forward" else "NB_INVERSE_INTENT"
        )
        if journal.document.get("state") != expected_intent:
            return
        try:
            self._record_mutation_outcome(
                journal,
                evidence,
                phase=phase,
                result=result,
                ambiguous=True,
            )
        except Exception:
            pass

    def _qualify_post_attempt_failure(
        self,
        operation: _OperationState,
        failure: Exception,
    ) -> None:
        """Persist a terminal ambiguity after an actual NB dispatch attempt."""

        journal = operation.journal
        evidence = operation.evidence
        if journal is None or evidence is None:
            return
        state = "NB_" + operation.phase.upper() + "_AMBIGUOUS"
        reason = str(failure) or failure.__class__.__name__
        reason_sha256 = hashlib.sha256(reason.encode("utf-8")).hexdigest()
        try:
            if journal.document.get("state") != state:
                journal.append(
                    {
                        "kind": "terminal-qualification",
                        "phase": operation.phase,
                        "status": "AMBIGUOUS",
                        "reason_type": failure.__class__.__name__,
                        "reason_sha256": reason_sha256,
                        "at_ns": time.time_ns(),
                    },
                    state=state,
                )
        except Exception:
            return
        if not self._producer_bound:
            return
        try:
            self._publish_event(
                "x05-nb-ambiguous",
                {
                    "phase": operation.phase,
                    "stage": operation.phase + "_terminal",
                    "status": "AMBIGUOUS",
                    "reason_type": failure.__class__.__name__,
                    "reason_sha256": reason_sha256,
                },
                journal=journal,
                evidence=evidence,
                require_central_identity=False,
            )
        except Exception:
            # The local journal is the durable no-reissue guard.  A producer
            # authority failure must not replace the original ambiguity.
            pass

    def _run_operation(
        self,
        operation: _OperationState,
        implementation: Callable[[_OperationState], dict[str, Any]],
    ) -> dict[str, Any]:
        try:
            with self._execution_scope():
                result = implementation(operation)
                if self._producer_bound:
                    self._verify_factory_binding()
                    self._verify_central_container()
                return result
        except AmbiguousCommit as exc:
            if (
                self._producer_bound
                and operation.attempted
                and operation.journal is not None
                and operation.journal.document.get("state")
                != "NB_" + operation.phase.upper() + "_AMBIGUOUS"
            ):
                self._qualify_post_attempt_failure(operation, exc)
            raise
        except Exception as exc:
            if self._producer_bound and operation.attempted:
                self._qualify_post_attempt_failure(operation, exc)
                raise AmbiguousCommit(
                    "NB "
                    + operation.phase
                    + " verification failed after the transaction attempt; "
                    "state is ambiguous",
                    result=operation.result,
                ) from exc
            raise

    def _forward_paths(self) -> tuple[pathlib.Path, Journal, Evidence]:
        journal = Journal(
            self.evidence_dir / "journal.json",
            owner=self.owner,
            run_hex=self.run_hex,
            policy=self.policy,
            marker_path=self.paths.marker,
        )
        journal.create()
        return self.evidence_dir, journal, Evidence(self.evidence_dir, journal)

    @contextlib.contextmanager
    def _execution_scope(self):
        if not self._producer_bound:
            yield
            return
        assert self._producer_mutex is not None
        self._verify_factory_binding()
        with self._producer_mutex:
            self._verify_factory_binding()
            self._verify_central_container()
            yield

    def forward(self) -> dict[str, Any]:
        """Build, apply, and verify the X05 NB forward transaction."""

        return self._run_operation(_OperationState("forward"), self._forward)

    def _forward(self, operation: _OperationState) -> dict[str, Any]:
        """Execute one serialized forward operation."""

        self._prepare_live()
        _, journal, evidence = self._forward_paths()
        operation.journal = journal
        operation.evidence = evidence
        preflight_command = [
            "bash",
            str(self.paths.helper_dir / "x05-nb-preflight.sh"),
            "--live",
        ]
        preflight_result, preflight = self._helper_json(
            preflight_command, context="NB preflight"
        )
        self._record_artifact(
            evidence,
            "preflight",
            preflight_result.stdout_bytes,
            preflight,
            event="x05-nb-readback",
        )
        self._require_command_success(preflight_result, context="NB preflight")
        _require_status(preflight, expected="PASS", context="NB preflight")

        tx_command = [
            sys.executable,
            str(self.paths.helper_dir / "x05-nb-tx.py"),
            "--build",
            str(evidence._path("preflight")),
            "--owner",
            self.owner,
            "--run-hex",
            self.run_hex,
        ]
        tx_result, transaction = self._helper_json(
            tx_command, context="NB forward transaction build"
        )
        self._require_command_success(tx_result, context="NB forward transaction build")
        transaction = _require_transaction(
            transaction, context="NB forward transaction build"
        )
        self._record_artifact(
            evidence, "forward_tx", tx_result.stdout_bytes, transaction
        )
        self._record_mutation_prepare(
            journal, evidence, phase="forward", tx=transaction
        )

        try:
            raw_result = self._ovsdb(
                transaction,
                context="NB forward transaction",
                operation=operation,
            )
        except AmbiguousCommit as exc:
            self._retain_ambiguous_outcome(
                journal,
                evidence,
                phase="forward",
                result=exc.result,
            )
            raise
        try:
            self._record_command_artifact(
                evidence,
                "forward_result",
                raw_result,
                event="x05-nb-outcome-artifact",
            )
            self._record_mutation_outcome(
                journal,
                evidence,
                phase="forward",
                result=raw_result,
                ambiguous=False,
            )
        except Exception as exc:
            self._retain_ambiguous_outcome(
                journal,
                evidence,
                phase="forward",
                result=raw_result,
            )
            raise AmbiguousCommit(
                "NB forward transaction evidence is incomplete; "
                "commit state is unknown",
                result=raw_result,
            ) from exc

        checked_command = [
            sys.executable,
            str(self.paths.helper_dir / "x05-nb-tx.py"),
            "--check-result",
            str(evidence._path("forward_result")),
            "--preflight",
            str(evidence._path("preflight")),
            "--owner",
            self.owner,
            "--run-hex",
            self.run_hex,
        ]
        checked_result, checked = self._helper_json(
            checked_command, context="NB forward result check"
        )
        self._record_artifact(
            evidence,
            "forward_checked",
            checked_result.stdout_bytes,
            checked,
            event="x05-nb-readback",
        )
        self._require_command_success(checked_result, context="NB forward result check")
        checked = _require_status(
            checked, expected="PASS", context="NB forward result check"
        )
        _require_run_identity(
            checked,
            owner=self.owner,
            run_hex=self.run_hex,
            context="NB forward result check",
        )

        snapshot_command = [
            "bash",
            str(self.paths.helper_dir / "x05-nb-full-snapshot.sh"),
            "--live",
        ]
        built_result, built_snapshot = self._helper_json(
            snapshot_command, context="NB built snapshot"
        )
        self._require_command_success(built_result, context="NB built snapshot")
        self._record_artifact(
            evidence,
            "built_snapshot",
            built_result.stdout_bytes,
            built_snapshot,
            event="x05-nb-readback",
        )

        built_check_command = [
            sys.executable,
            str(self.paths.helper_dir / "x05-nb-postflight.py"),
            "--built",
            "--preflight",
            str(evidence._path("preflight")),
            "--forward",
            str(evidence._path("forward_checked")),
            "--state",
            str(evidence._path("built_snapshot")),
        ]
        built_check_result, built_check = self._helper_json(
            built_check_command, context="NB built postflight"
        )
        self._record_artifact(
            evidence,
            "built_checked",
            built_check_result.stdout_bytes,
            built_check,
            event="x05-nb-readback",
        )
        self._require_command_success(built_check_result, context="NB built postflight")
        built_check = _require_status(
            built_check, expected="PASS", context="NB built postflight"
        )
        _require_run_identity(
            built_check,
            owner=self.owner,
            run_hex=self.run_hex,
            context="NB built postflight",
        )
        journal.append(
            {"kind": "state", "state": "NB_FORWARD_VERIFIED", "at_ns": time.time_ns()},
            state="NB_FORWARD_VERIFIED",
        )
        self._publish_event(
            "x05-nb-state",
            {"phase": "forward", "stage": "built_checked", "status": "VERIFIED"},
            journal=journal,
            evidence=evidence,
        )
        return built_check

    def _inverse_context(
        self,
    ) -> tuple[Journal, Evidence, pathlib.Path, pathlib.Path, pathlib.Path]:
        journal_path = self.evidence_dir / "journal.json"
        journal = Journal(
            journal_path,
            owner=self.owner,
            run_hex=self.run_hex,
            policy=self.policy,
            marker_path=self.paths.marker,
        )
        journal.load_for_inverse(
            FORWARD_STAGES,
            evidence_dir=self.evidence_dir,
            marker_path=self.paths.marker,
        )
        evidence = Evidence(self.evidence_dir, journal, next_stage=len(FORWARD_STAGES))
        journal.verify_artifacts(FORWARD_STAGES, evidence)
        for stage in FORWARD_STAGES:
            path = evidence._path(stage)
            _assert_owned_file(path, context="X05 evidence", policy=self.policy)
            parse_json(_read_text(path, context="X05 evidence"), context=stage)
        stored_preflight = _require_status(
            parse_json(
                _read_text(evidence._path("preflight"), context="preflight"),
                context="preflight",
            ),
            expected="PASS",
            context="stored NB preflight",
        )
        stored_forward = _require_status(
            parse_json(
                _read_text(
                    evidence._path("forward_checked"), context="forward checked"
                ),
                context="forward checked",
            ),
            expected="PASS",
            context="stored NB forward result check",
        )
        stored_built = _require_status(
            parse_json(
                _read_text(evidence._path("built_checked"), context="built checked"),
                context="built checked",
            ),
            expected="PASS",
            context="stored NB built postflight",
        )
        del stored_preflight
        _require_run_identity(
            stored_forward,
            owner=self.owner,
            run_hex=self.run_hex,
            context="stored NB forward result check",
        )
        _require_run_identity(
            stored_built,
            owner=self.owner,
            run_hex=self.run_hex,
            context="stored NB built postflight",
        )
        return (
            journal,
            evidence,
            evidence._path("preflight"),
            evidence._path("forward_checked"),
            evidence._path("built_snapshot"),
        )

    def inverse(self) -> dict[str, Any]:
        """Build, apply, and verify the X05 NB inverse transaction."""

        return self._run_operation(_OperationState("inverse"), self._inverse)

    def _inverse(self, operation: _OperationState) -> dict[str, Any]:
        """Execute one serialized inverse operation."""

        self._prepare_live()
        journal, evidence, preflight, forward, built_snapshot = self._inverse_context()
        operation.journal = journal
        operation.evidence = evidence
        del built_snapshot

        snapshot_command = [
            "bash",
            str(self.paths.helper_dir / "x05-nb-full-snapshot.sh"),
            "--live",
        ]
        preinverse_result, preinverse_snapshot = self._helper_json(
            snapshot_command, context="NB preinverse snapshot"
        )
        self._record_artifact(
            evidence,
            "preinverse_snapshot",
            preinverse_result.stdout_bytes,
            preinverse_snapshot,
            event="x05-nb-readback",
        )
        self._require_command_success(
            preinverse_result, context="NB preinverse snapshot"
        )

        tx_command = [
            sys.executable,
            str(self.paths.helper_dir / "x05-nb-tx.py"),
            "--build-inverse",
            str(preflight),
            str(forward),
            "--owner",
            self.owner,
            "--run-hex",
            self.run_hex,
            "--state",
            str(evidence._path("preinverse_snapshot")),
        ]
        tx_result, transaction = self._helper_json(
            tx_command, context="NB inverse transaction build"
        )
        self._require_command_success(tx_result, context="NB inverse transaction build")
        transaction = _require_transaction(
            transaction, context="NB inverse transaction build"
        )
        self._record_artifact(
            evidence, "inverse_tx", tx_result.stdout_bytes, transaction
        )
        self._record_mutation_prepare(
            journal, evidence, phase="inverse", tx=transaction
        )

        try:
            raw_result = self._ovsdb(
                transaction,
                context="NB inverse transaction",
                operation=operation,
            )
        except AmbiguousCommit as exc:
            self._retain_ambiguous_outcome(
                journal,
                evidence,
                phase="inverse",
                result=exc.result,
            )
            raise
        try:
            self._record_command_artifact(
                evidence,
                "inverse_result",
                raw_result,
                event="x05-nb-outcome-artifact",
            )
            self._record_mutation_outcome(
                journal,
                evidence,
                phase="inverse",
                result=raw_result,
                ambiguous=False,
            )
        except Exception as exc:
            self._retain_ambiguous_outcome(
                journal,
                evidence,
                phase="inverse",
                result=raw_result,
            )
            raise AmbiguousCommit(
                "NB inverse transaction evidence is incomplete; "
                "commit state is unknown",
                result=raw_result,
            ) from exc

        checked_command = [
            sys.executable,
            str(self.paths.helper_dir / "x05-nb-tx.py"),
            "--check-inverse-result",
            str(evidence._path("inverse_result")),
            "--preflight",
            str(preflight),
            "--forward",
            str(forward),
            "--state",
            str(evidence._path("preinverse_snapshot")),
        ]
        checked_result, checked = self._helper_json(
            checked_command, context="NB inverse result check"
        )
        self._record_artifact(
            evidence,
            "inverse_checked",
            checked_result.stdout_bytes,
            checked,
            event="x05-nb-readback",
        )
        self._require_command_success(checked_result, context="NB inverse result check")
        checked = _require_status(
            checked, expected="PASS", context="NB inverse result check"
        )
        _require_run_identity(
            checked,
            owner=self.owner,
            run_hex=self.run_hex,
            context="NB inverse result check",
        )

        clean_result, clean_snapshot = self._helper_json(
            snapshot_command, context="NB clean snapshot"
        )
        self._require_command_success(clean_result, context="NB clean snapshot")
        self._record_artifact(
            evidence,
            "clean_snapshot",
            clean_result.stdout_bytes,
            clean_snapshot,
            event="x05-nb-readback",
        )

        clean_check_command = [
            sys.executable,
            str(self.paths.helper_dir / "x05-nb-postflight.py"),
            "--clean",
            "--preflight",
            str(preflight),
            "--forward",
            str(forward),
            "--state",
            str(evidence._path("clean_snapshot")),
            "--built-receipt",
            str(evidence._path("built_checked")),
            "--inverse",
            str(evidence._path("inverse_checked")),
        ]
        clean_check_result, clean_check = self._helper_json(
            clean_check_command, context="NB clean postflight"
        )
        self._record_artifact(
            evidence,
            "clean_checked",
            clean_check_result.stdout_bytes,
            clean_check,
            event="x05-nb-readback",
        )
        self._require_command_success(clean_check_result, context="NB clean postflight")
        clean_check = _require_status(
            clean_check, expected="PASS", context="NB clean postflight"
        )
        _require_run_identity(
            clean_check,
            owner=self.owner,
            run_hex=self.run_hex,
            context="NB clean postflight",
        )
        journal.append(
            {"kind": "state", "state": "NB_INVERSE_VERIFIED", "at_ns": time.time_ns()},
            state="NB_INVERSE_VERIFIED",
        )
        self._publish_event(
            "x05-nb-state",
            {"phase": "inverse", "stage": "clean_checked", "status": "VERIFIED"},
            journal=journal,
            evidence=evidence,
        )
        return clean_check


def dry_run(run_hex: str) -> dict[str, Any]:
    """Return a local-only plan without touching any path or subprocess."""

    run_hex = validate_run(run_hex)
    return {
        "mode": "dry-run",
        "owner": owner_for(run_hex),
        "scope": "OVN Northbound forward/inverse orchestration only",
        "marker": str(MARKER_PATH),
        "lock": str(LOCK_PATH),
        "central_container": CENTRAL_CONTAINER,
        "nb_socket": NB_SOCKET,
        "forward": list(FORWARD_STAGES),
        "inverse": list(INVERSE_STAGES),
        "mutation": "ovsdb-client transact via fixed central container/socket",
        "external_calls": "none in dry-run",
        "marker_removal": "never performed by this adapter",
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--dry-run", action="store_true")
    modes.add_argument("--forward", action="store_true")
    modes.add_argument("--inverse", action="store_true")
    modes.add_argument("--recover", action="store_true")
    parser.add_argument("--run-hex", required=True, help="six lowercase hex digits")
    parser.add_argument("--evidence-dir", type=pathlib.Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.dry_run:
        print(json.dumps(dry_run(args.run_hex), sort_keys=True, separators=(",", ":")))
        return 0
    if args.evidence_dir is None:
        print("X05 NB live FAIL: --evidence-dir is required", file=sys.stderr)
        return 2
    adapter = NBAdapter(run_hex=args.run_hex, evidence_dir=args.evidence_dir)
    try:
        if args.recover:
            raise NotReady(
                "X05 NB forward recovery is local-only and remains disabled in the "
                "live adapter until integrated review"
            )
        result = adapter.forward() if args.forward else adapter.inverse()
    except NotReady as exc:
        print("X05 NB live NOT READY: " + str(exc), file=sys.stderr)
        return 75
    except AdapterError as exc:
        print("X05 NB live FAIL: " + str(exc), file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
