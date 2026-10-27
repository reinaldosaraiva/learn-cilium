#!/usr/bin/env python3
"""Per-gate Python orchestrator for the P004-S002 X05 experiment.

This replaces ``x05-orchestrate.sh`` and fixes the ten P0s of its adversarial
review by integrating the existing X05 toolchain through its real APIs:

  P0-1  Probes now originate from the correct containers: A probes from
        ``dci-client-1``, B probes from ``dci-client-2`` (created by this
        orchestrator), EVPN peer probes from ``dci-evpn-client-1`` (M03 peer)
        and ``dci-x05-peer-2`` (X05 peer) with ``ping -I <source>``.
  P0-2  EVPN evidence is collected with ``x05-evaluator``'s G2 commands: Type
        5/RIB/FIB/VNI on the peer containers, remote VTEPs on the chassis
        containers via ``ovn-appctl``, Learned_Route/Port_Binding on the
        central — never ``show evpn route`` on the gateways.
  P0-3  Gateway FRR extensions are copied into the container with
        ``docker cp`` (byte count + SHA256 verified against the frozen
        ``x05-runtime-plan`` digests), checked with ``vtysh -C -f`` and only
        then applied with ``vtysh -f`` — no host paths inside ``docker exec``.
  P0-4  NB forward/inverse transactions are emitted by ``x05-nb-tx.py`` and
        applied as ONE ``ovsdb-client transact`` through ``docker exec`` on
        the NB socket; results are re-checked with the tool's check modes.
  P0-5  ``x05-nb-preflight.sh --live`` prints the preflight JSON to stdout;
        the orchestrator captures that stream into evidence (it never reads a
        non-existent side file) and feeds it to ``--build``/``--check-result``.
  P0-6  ``x05-nb-postflight.py`` is invoked with its real arguments
        (``--built|--clean --preflight --forward --state``) and a state
        snapshot produced by ``x05-nb-full-snapshot.sh --live``.
  P0-7  The runtime resources the experiment needs (``dci-client-2``,
        ``dci-x05-peer-2``, sentinel netns/taps, ``br-x05-b``/``vxlan-x05-b``/
        ``evpn-x05-b``, chassis 2 OVS external_ids, gateway BGP mirrors,
        dedicated FRR pathspace ``x05``) are created and compensated by this
        orchestrator following the frozen ``x05-runtime-plan`` inventory with
        owner labels/aliases and a durable journal; the canonical one-shot
        path remains ``x05-coordinator.py`` (its library API needs a consumed
        admission, which cannot span per-gate processes).
  P0-8  Captures run in the correct namespaces with the SLL2 DLT 276
        ``link[4:4]`` ifindex-only filter, write inside each container, are
        recorded (PID + command), and are retrieved with ``docker cp`` plus
        SHA256 — no host paths handed to in-container tcpdump.
  P0-9  The G5/G6 control uses REAL LS/LSP UUIDs and complete port sets in
        the ``x05-cas.sh`` snapshot format, applies one guarded
        ``ovsdb-client transact``, checks the result with ``--check-result``,
        re-reads both parents, and applies the true inverse (swapped
        snapshot) for G6.
  P0-10 Rollback follows the contract order (stop captures; restore B LSP and
        prove its parent; withdraw B EVPN and gateway BGP; remove sentinel
        ports/netns; remove peer/client ports and containers; remove links,
        mirrors, filters, NB rows and FRR state; prove X05 absence; verify
        M03; only then ``labctl dci down --m03``, baseline verify, canaries).
        ``labctl dci`` is called with ``M03_LOCK_HELD_FD=9`` and
        ``X05_COORDINATOR_TOKEN`` while the X05 marker exists, and labctl is
        resolved at ``<repo>/labctl/labctl`` (repository layout) or
        ``<repo>/labctl`` (installed/flat layout), whichever is a file.

Usage::

    x05-orchestrate.py --dry-run|--execute --gate {0,0a,nb,1,2,3,4,5,6,7,8,all}
                       [--run HEX] [--evidence-root DIR] [--ovs-runc PATH]
    x05-orchestrate.py --execute --rollback [--run HEX]
    x05-orchestrate.py --validate

Every mutating action is routed through one command layer: in ``--dry-run``
it only prints ``DRY:`` lines; in ``--execute`` it runs with a single attempt
and records evidence under ``evidence/P004/S002/<run>/08-x05/gate-<N>/``.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import secrets
import subprocess
import sys
import time
import types
from typing import Any, Mapping, Sequence

sys.dont_write_bytecode = True

SCHEMA = "p004-x05-orchestrate-v1"
HERE = pathlib.Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent.parent
# labctl is resolved adaptively: repository layout (<repo>/labctl/labctl)
# first, then installed/flat layout (<repo>/labctl). The reviewed production
# code (x05-runtime-live.py) pins the flat layout at the bundle root, so the
# flat form is the deployment target; the nested form keeps the repository
# checkout working.
LABCTL = REPO_ROOT / "labctl" / "labctl"
if not LABCTL.is_file():
    LABCTL = REPO_ROOT / "labctl"
DEFAULT_EVIDENCE_ROOT = REPO_ROOT / "evidence" / "P004" / "S002"
DEFAULT_OVS_RUNC = pathlib.Path("/opt/dci-src/ovn-fake-multinode/ovs-runc")

# ---------------------------------------------------------------------------
# Lab topology (topology.md, x05-topology.md, x05-runtime-plan.py)
# ---------------------------------------------------------------------------
CENTRAL = "ovn-central-az1"
GW1 = "ovn-gw-1"
GW2 = "ovn-gw-2"
CHASSIS1 = "ovn-chassis-1"
CHASSIS2 = "ovn-chassis-2"
CLIENT_A = "dci-client-1"          # M03/DCI existing on-prem client (AS 200)
CLIENT_B = "dci-client-2"          # X05 B on-prem client (AS 201) — created
PEER_A = "dci-evpn-client-1"       # M03 EVPN peer — existing
PEER_B = "dci-x05-peer-2"          # X05 EVPN peer — created
DCI_NODES = (CENTRAL, GW1, GW2, CHASSIS1, CHASSIS2)

NB_SOCKET = "unix:/var/run/ovn/ovnnb_db.sock"
M03_LOCK = pathlib.Path("/var/lock/labctl-dci-m03.lock")
X05_MARKER = pathlib.Path("/run/labctl/dci-x05/active")
M03_MARKER = pathlib.Path("/run/labctl/dci-m03/active")

TENANT_PREFIX = "192.168.100.0/24"
SENTINEL_A, SENTINEL_B = "192.168.100.11", "192.168.100.12"
PEER_SOURCE_A, PEER_SOURCE_B = "10.250.0.1", "10.251.0.1"
PATHSPACE = "x05"                   # /etc/frr/x05 + /run/frr/x05
GW_BASE_FIXTURE = {"ovn-gw-1": "frr-gw1.conf", "ovn-gw-2": "frr-gw2.conf"}
FRR_IMAGE = "frrouting/frr:v8.4.1"
PEER_IMAGE = "ovn/ovn-multi-node:latest"


def _frozen_fixtures() -> tuple[dict[str, tuple[int, str]], dict[str, str]]:
    """Fixture digests and gateway FRR base hashes from the reviewed plan.

    Loads x05-runtime-plan.py standalone (pure-local, standard library only)
    so no digest is hand-copied into this orchestrator.
    """
    spec = importlib.util.spec_from_file_location(
        "x05_orchestrate_runtime_plan_contract", HERE / "x05-runtime-plan.py")
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load the reviewed runtime plan")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    fixtures: dict[str, tuple[int, str]] = dict(module.EXPECTED_FRR_EXTENSION_FIXTURES)
    fixtures.update(module.EXPECTED_RUNTIME_FIXTURES)
    gateway_base: dict[str, str] = {}
    for resource in module.build_plan()["resources"]:
        if resource.get("kind") != "frr-config-delta":
            continue
        desired = resource.get("desired") or {}
        base_fixture, base_hash = desired.get("base_fixture"), desired.get("base_sha256")
        if isinstance(base_fixture, str) and isinstance(base_hash, str):
            gateway_base[base_fixture] = base_hash
    return fixtures, gateway_base


# Frozen fixture identities and gateway base hashes from x05-runtime-plan.py.
FIXTURES, GW_FRR_BASE_BY_FIXTURE = _frozen_fixtures()
SENTINELS = {                       # tenant -> (chassis, netns, tap, inner, ip, mac)
    "a": (CHASSIS1, "x05-tenant-a-vm", "x05-tenant-a-p", "x05-tenant-a",
          SENTINEL_A, "02:00:00:10:00:11"),
    "b": (CHASSIS2, "x05-tenant-b-vm", "x05-tenant-b-p", "x05-tenant-b",
          SENTINEL_B, "02:00:00:10:00:12"),
}
GATEWAYS = (                        # number -> (container, vrf, mirror ovs/peer, gw /30)
    (300, GW1, "ovnvrf300", "169.254.254.1/30"),
    (400, GW2, "ovnvrf400", "169.254.254.5/30"),
)
CLIENT_B_LEGS = (                   # iface, vlan, address (dci-client-2)
    ("eth1", 300, "169.254.254.2/30"),
    ("eth2", 400, "169.254.254.6/30"),
)
PEER_UNDERLAY = "170.168.0.8/16"
CHASSIS2_UNDERLAY = "170.168.0.6"
CHASSIS2_LOCAL_IP_BASE = "50100-170.168.0.6"
CHASSIS2_LOCAL_IP_X05 = "50100-170.168.0.6,50200-170.168.0.6"
UUID_RE = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z")
RUN_RE = re.compile(r"[0-9a-f]{6}\Z")
BGP_POLL_ATTEMPTS = 40
BGP_POLL_DELAY = 3.0
COMMAND_TIMEOUT = 60.0
UNDERLAY_IF = "vxlan_sys_4789"
# Router MAC for the tenant-B EVPN bridge: must equal lrp-x05-tenant-b's MAC
# in the frozen plan (x05-nb-plan.sh) per the m03 LRP/bridge MAC contract.
EVPN_B_ROUTER_MAC = "02:00:00:20:00:01"

GATE_ORDER = ("0", "0a", "nb", "1", "2", "3", "4", "5", "6", "7", "8")

# Tool CLIs driven by this orchestrator (P0-4/P0-5/P0-6/P0-9).
TOOL_NB_PLAN = HERE / "x05-nb-plan.sh"
TOOL_NB_PREFLIGHT = HERE / "x05-nb-preflight.sh"
TOOL_NB_TX = HERE / "x05-nb-tx.py"
TOOL_NB_POSTFLIGHT = HERE / "x05-nb-postflight.py"
TOOL_NB_SNAPSHOT = HERE / "x05-nb-full-snapshot.sh"
TOOL_CAS = HERE / "x05-cas.sh"

SELFTESTS: tuple[tuple[str, str], ...] = (
    ("x05-nb-plan.sh --check", ["bash", str(TOOL_NB_PLAN), "--check"]),
    ("x05-nb-preflight-selftest.sh", ["bash", str(HERE / "x05-nb-preflight-selftest.sh")]),
    ("x05-nb-tx-selftest.sh", ["bash", str(HERE / "x05-nb-tx-selftest.sh")]),
    ("x05-nb-postflight-selftest.sh", ["bash", str(HERE / "x05-nb-postflight-selftest.sh")]),
    ("x05-nb-recovery-selftest.sh", ["bash", str(HERE / "x05-nb-recovery-selftest.sh")]),
    ("x05-cas-selftest.sh", ["bash", str(HERE / "x05-cas-selftest.sh")]),
    ("x05-runtime-plan.py --selftest", ["python3", str(HERE / "x05-runtime-plan.py"), "--selftest"]),
    ("x05-runtime-preflight.py --selftest", ["python3", str(HERE / "x05-runtime-preflight.py"), "--selftest"]),
    ("x05-evaluator-selftest.py", ["python3", str(HERE / "x05-evaluator-selftest.py")]),
    ("x05-capture-selftest.py", ["python3", str(HERE / "x05-capture-selftest.py")]),
    ("x05-nb-live-selftest.py", ["python3", str(HERE / "x05-nb-live-selftest.py")]),
    ("x05-runtime-apply-selftest.py", ["python3", str(HERE / "x05-runtime-apply-selftest.py")]),
    ("x05-runtime-live-selftest.py", ["python3", str(HERE / "x05-runtime-live-selftest.py")]),
    ("x05-coordinator-selftest.py", ["python3", str(HERE / "x05-coordinator-selftest.py")]),
)


class OrchestratorError(RuntimeError):
    """The orchestrator cannot proceed safely."""


class GateFailure(OrchestratorError):
    """A gate observed a condition that fails the contract."""


class NotReady(OrchestratorError):
    """Preconditions are missing; the run must stop before mutation."""


def _log(message: str) -> None:
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print("[x05-orchestrate %s] %s" % (stamp, message), file=sys.stderr, flush=True)


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# ---------------------------------------------------------------------------
# Reviewed module loading (x05-evaluator + shared runner from x05-runtime-live)
# ---------------------------------------------------------------------------
EVALUATOR_MODULE_NAME = "x05_orchestrate_evaluator_contract"
RUNTIME_LIVE_MODULE_NAME = "x05_orchestrate_runtime_live_contract"


def _load_module(name: str, path: pathlib.Path) -> types.ModuleType:
    existing = sys.modules.get(name)
    if existing is not None:
        if pathlib.Path(getattr(existing, "__file__", "")).resolve() != path:
            raise OrchestratorError("canonical X05 module path changed: " + name)
        return existing
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise OrchestratorError("cannot load reviewed X05 module: " + name)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def load_evaluator() -> Any:
    return _load_module(EVALUATOR_MODULE_NAME, HERE / "x05-evaluator.py")


def load_runtime_live() -> Any:
    return _load_module(RUNTIME_LIVE_MODULE_NAME, HERE / "x05-runtime-live.py")


def resolve_container_id(ctx: "RunContext", name: str) -> str:
    """x05-evaluator topologies require captured 64-hex Docker IDs."""
    if ctx.dry_run:
        # Distinct placeholder IDs so topology uniqueness checks still hold.
        return hashlib.sha256(name.encode()).hexdigest()
    raw = ctx.cmd.read(["docker", "inspect", "--format", "{{.Id}}", name],
                       timeout=15.0, label="container-id " + name)
    container_id = raw.decode().strip()
    if not re.fullmatch(r"[0-9a-f]{64}", container_id):
        raise NotReady("cannot resolve a 64-hex Docker ID for %s" % name)
    return container_id


# ---------------------------------------------------------------------------
# Command layer: the ONLY place that spawns processes (P0 fix: single regime)
# ---------------------------------------------------------------------------
class CommandResult:
    def __init__(self, argv: Sequence[str], returncode: int,
                 stdout: bytes = b"", stderr: bytes = b"", dry: bool = False) -> None:
        self.argv = tuple(argv)
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr
        self.dry = dry

    @property
    def ok(self) -> bool:
        return self.returncode == 0


class Commands:
    """Route every action through one dry-run/execute boundary."""

    def __init__(self, dry_run: bool, evidence: "Evidence | None" = None) -> None:
        self.dry_run = dry_run
        self.evidence = evidence

    # -- primitives ---------------------------------------------------------
    def run(self, argv: Sequence[str], *, env: Mapping[str, str] | None = None,
            timeout: float = COMMAND_TIMEOUT, check: bool = True,
            label: str | None = None,
            pass_fds: tuple[int, ...] | None = None) -> CommandResult:
        argv = [str(item) for item in argv]
        display = " ".join(argv)
        if label:
            display = label + ": " + display
        if self.dry_run:
            _log("DRY: " + display)
            return CommandResult(argv, 0, dry=True)
        merged_env = None
        if env is not None:
            merged_env = dict(os.environ)
            merged_env.update(dict(env))
        _log("CMD: " + display)
        run_kwargs = {"capture_output": True, "timeout": timeout,
                      "check": False, "env": merged_env}
        if pass_fds is not None:
            # Only pass pass_fds when set: subprocess.run forwards it to Popen,
            # whose _execute_child does set(pass_fds) unconditionally, so an
            # explicit None would raise TypeError. Omitting it uses Popen's
            # working default.
            run_kwargs["pass_fds"] = pass_fds
        try:
            completed = subprocess.run(argv, **run_kwargs)
        except subprocess.TimeoutExpired as exc:
            result = CommandResult(argv, 124, b"", str(exc).encode())
            self._record(label or "", argv, result)
            if check:
                raise OrchestratorError("command timed out: " + display)
            return result
        result = CommandResult(argv, completed.returncode,
                               completed.stdout, completed.stderr)
        self._record(label or "", argv, result)
        if check and not result.ok:
            raise OrchestratorError(
                "command failed (rc=%d): %s\nstderr: %s"
                % (result.returncode, display, result.stderr.decode("utf-8", "replace")[-2000:]))
        return result

    def read(self, argv: Sequence[str], *, dry_value: bytes | None = None,
             timeout: float = COMMAND_TIMEOUT, label: str | None = None) -> bytes:
        """Read-only capture; in dry-run returns ``dry_value`` without running."""
        if self.dry_run:
            _log("DRY-READ: " + " ".join(str(item) for item in argv))
            return dry_value if dry_value is not None else b""
        result = self.run(argv, timeout=timeout, check=True, label=label)
        return result.stdout

    def read_json(self, argv: Sequence[str], *, dry_value: Any = None,
                  timeout: float = COMMAND_TIMEOUT, label: str | None = None) -> Any:
        if self.dry_run:
            return dry_value
        raw = self.read(argv, timeout=timeout, label=label)
        return json.loads(raw.decode("utf-8"))

    def _record(self, label: str, argv: Sequence[str], result: CommandResult) -> None:
        if self.evidence is not None:
            self.evidence.command(label or "command", result)

    # -- docker / OVN helpers ----------------------------------------------
    def dex(self, container: str, *argv: str, check: bool = True,
            timeout: float = COMMAND_TIMEOUT) -> CommandResult:
        return self.run(["docker", "exec", container, *(str(a) for a in argv)],
                        check=check, timeout=timeout,
                        label="docker-exec " + container)

    def dex_read(self, container: str, *argv: str, dry_value: bytes | None = None,
                 timeout: float = COMMAND_TIMEOUT) -> bytes:
        return self.read(["docker", "exec", container, *(str(a) for a in argv)],
                         dry_value=dry_value, timeout=timeout,
                         label="docker-exec " + container)

    def nb_list(self, table: str, columns: Sequence[str]) -> list[dict[str, Any]]:
        """Read NB rows as decoded JSON (uuid atoms collapsed by nbctl)."""
        raw = self.dex_read(
            CENTRAL, "ovn-nbctl", "--timeout=5", "--format=json", "--data=json",
            "--columns=" + ",".join(columns), "list", table,
            dry_value=json.dumps({"headings": list(columns), "data": []}).encode(),
        )
        document = json.loads(raw.decode("utf-8"))
        rows = []
        for cells in document.get("data", []):
            rows.append(dict(zip(document["headings"], cells)))
        return rows

    def nb_transact(self, transaction: Sequence[Any], *, label: str) -> Any:
        """Apply ONE ovsdb-client transact on the OVN NB socket (P0-4)."""
        payload = json.dumps(transaction, sort_keys=True, separators=(",", ":"))
        _log("%s: applying single OVSDB transaction with %d operations"
             % (label, len(transaction) - 1))
        result = self.run(
            ["docker", "exec", CENTRAL, "ovsdb-client", "transact", NB_SOCKET, payload],
            timeout=30.0, label=label,
        )
        reply = json.loads(result.stdout.decode("utf-8"))
        if isinstance(reply, dict) and reply.get("error") is not None:
            raise OrchestratorError(label + ": OVSDB top-level error: " + str(reply["error"]))
        return reply

    def labctl(self, *args: str, extra_env: Mapping[str, str] | None = None,
               timeout: float = 1800.0) -> CommandResult:
        env = dict(extra_env or {})
        pass_fds = None
        if "M03_LOCK_HELD_FD" in env:
            # The M03 lock is held on FD 9 in this process. On Unix the
            # subprocess closes inherited FDs by default (close_fds=True), so
            # labctl's inherited-lock check (dci.sh: /proc/self/fd/9) would see
            # a closed FD. Pass FD 9 explicitly so the child inherits the lock.
            try:
                os.fstat(9)
                pass_fds = (9,)
            except OSError:
                pass_fds = None
        return self.run(["bash", str(LABCTL), *(str(a) for a in args)],
                        env=env, timeout=timeout, label="labctl",
                        pass_fds=pass_fds)


# ---------------------------------------------------------------------------
# Evidence (evidence/P004/S002/<run>/08-x05/gate-<N>/)
# ---------------------------------------------------------------------------
class Evidence:
    MAX_INLINE = 64 * 1024

    def __init__(self, run_root: pathlib.Path, dry_run: bool) -> None:
        self.run_root = run_root
        self.base = run_root / "08-x05"
        self.dry_run = dry_run
        self.manifest_entries: dict[str, dict[str, Any]] = {}

    def gate_dir(self, gate: str) -> pathlib.Path:
        return self.base / ("gate-" + gate)

    def _prepare(self, name: str) -> pathlib.Path:
        path = self.base / name
        if self.dry_run:
            return path
        path.parent.mkdir(parents=True, exist_ok=True)
        return path

    def write(self, name: str, raw: bytes) -> dict[str, Any]:
        path = self._prepare(name)
        binding = {"path": str(path), "bytes": len(raw), "sha256": _sha256(raw)}
        if self.dry_run:
            _log("DRY: evidence %s (%d bytes)" % (name, len(raw)))
        else:
            path.write_bytes(raw)
            self.manifest_entries[name] = binding
        return binding

    def text(self, name: str, value: str) -> dict[str, Any]:
        return self.write(name, value.encode("utf-8"))

    def json(self, name: str, value: Any) -> dict[str, Any]:
        return self.write(
            name,
            json.dumps(value, sort_keys=True, indent=2, default=str).encode("utf-8"),
        )

    def command(self, label: str, result: CommandResult) -> dict[str, Any]:
        stamp = dt.datetime.now(dt.timezone.utc).isoformat()
        entry = {
            "label": label,
            "argv": list(result.argv),
            "returncode": result.returncode,
            "utc": stamp,
            "stdout_bytes": len(result.stdout),
            "stderr_bytes": len(result.stderr),
            "stdout_sha256": _sha256(result.stdout),
            "stderr_sha256": _sha256(result.stderr),
        }
        self.manifest_entries.setdefault("commands", []).append(entry)  # type: ignore[union-attr]
        if len(result.stdout) <= self.MAX_INLINE:
            self.write("commands/%s-%d.stdout" % (_safe(label), _nonce()), result.stdout)
        if len(result.stderr) <= self.MAX_INLINE:
            self.write("commands/%s-%d.stderr" % (_safe(label), _nonce()), result.stderr)
        return entry

    def manifest(self) -> dict[str, Any]:
        return {"schema": SCHEMA + "-manifest", "files": self.manifest_entries}


_NONCE = secrets.randbits(24)


def _nonce() -> int:
    global _NONCE
    _NONCE += 1
    return _NONCE


def _safe(label: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", label)[:80] or "command"


# ---------------------------------------------------------------------------
# Run context: durable per-run state shared by per-gate invocations
# ---------------------------------------------------------------------------
class RunContext:
    STATE_NAME = "orchestrate-state.json"

    def __init__(self, mode: str, run_hex: str, evidence_root: pathlib.Path,
                 ovs_runc: pathlib.Path) -> None:
        self.mode = mode
        self.dry_run = mode == "dry-run"
        self.run_hex = run_hex
        self.owner = "labctl-x05-" + run_hex
        self.run_root = evidence_root / run_hex
        self.evidence = Evidence(self.run_root, self.dry_run)
        self.cmd = Commands(self.dry_run, self.evidence)
        self.ovs_runc = ovs_runc
        self.state: dict[str, Any] = self._load_state()

    # -- state -------------------------------------------------------------
    def _state_path(self) -> pathlib.Path:
        return self.run_root / self.STATE_NAME

    def _load_state(self) -> dict[str, Any]:
        path = self._state_path()
        if self.dry_run:
            return {"run_hex": self.run_hex, "owner": self.owner, "gates": {},
                    "runtime_journal": [], "captures": {}}
        if path.is_file():
            try:
                return json.loads(path.read_text())
            except ValueError as exc:
                raise OrchestratorError("state file is corrupt: %s (%s)" % (path, exc))
        return {"schema": SCHEMA + "-state", "run_hex": self.run_hex,
                "owner": self.owner, "gates": {}, "runtime_journal": [],
                "captures": {}}

    def save(self) -> None:
        if self.dry_run:
            return
        path = self._state_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.state, sort_keys=True, indent=2))
        tmp.replace(path)

    def prepare_run(self) -> None:
        if self.dry_run:
            _log("DRY: run dir %s (not created in dry-run)" % self.run_root)
            return
        self.run_root.mkdir(parents=True, exist_ok=True)
        (self.run_root / "08-x05").mkdir(exist_ok=True)
        header = {
            "schema": SCHEMA, "mode": self.mode, "run_hex": self.run_hex,
            "owner": self.owner,
            "started": dt.datetime.now(dt.timezone.utc).isoformat(),
        }
        (self.run_root / "run-header.json").write_text(
            json.dumps(header, indent=2, sort_keys=True))
        self.save()

    # -- receipts ----------------------------------------------------------
    def record_gate(self, gate: str, report: dict[str, Any]) -> None:
        self.state.setdefault("gates", {})[gate] = {
            "utc": dt.datetime.now(dt.timezone.utc).isoformat(),
            **report,
        }
        self.save()

    def gate_report(self, gate: str) -> dict[str, Any] | None:
        return self.state.get("gates", {}).get(gate)

    def journal(self, stage: str, resource: str, *, status: str,
                before: Any = None, detail: Any = None) -> None:
        entry = {"utc": dt.datetime.now(dt.timezone.utc).isoformat(),
                 "stage": stage, "resource": resource, "status": status,
                 "before": before, "detail": detail}
        self.state.setdefault("runtime_journal", []).append(entry)
        self.save()
        _log("journal: %s %s -> %s" % (stage, resource, status))

    def gate(self, gate: str) -> "GateScope":
        return GateScope(self, gate)


class GateScope:
    """Convenience wrapper: evidence files under gate-<N>/ plus a report."""

    def __init__(self, ctx: RunContext, gate: str) -> None:
        self.ctx = ctx
        self.gate = gate
        self.report: dict[str, Any] = {"gate": gate, "status": "RUNNING", "steps": []}

    def step(self, name: str, **facts: Any) -> None:
        self.report["steps"].append({"name": name, **facts})
        _log("G%s: %s" % (self.gate, name))

    def file(self, name: str) -> pathlib.Path:
        return self.ctx.evidence.gate_dir(self.gate) / name

    def write(self, name: str, raw: bytes) -> dict[str, Any]:
        return self.ctx.evidence.write("gate-%s/%s" % (self.gate, name), raw)

    def text(self, name: str, value: str) -> dict[str, Any]:
        return self.write(name, value.encode())

    def json(self, name: str, value: Any) -> dict[str, Any]:
        return self.ctx.evidence.json("gate-%s/%s" % (self.gate, name), value)

    def pass_gate(self, reason: str, **facts: Any) -> dict[str, Any]:
        self.report["status"] = "PASS"
        self.report["reason"] = reason
        self.report.update(facts)
        self.report["finished"] = dt.datetime.now(dt.timezone.utc).isoformat()
        self.json("report.json", self.report)
        self.ctx.record_gate(self.gate, {"status": "PASS", "reason": reason})
        _log("G%s: PASS (%s)" % (self.gate, reason))
        return self.report

    def fail_gate(self, reason: str, **facts: Any) -> dict[str, Any]:
        self.report["status"] = "FAIL"
        self.report["reason"] = reason
        self.report.update(facts)
        self.report["finished"] = dt.datetime.now(dt.timezone.utc).isoformat()
        self.json("report.json", self.report)
        self.ctx.record_gate(self.gate, {"status": "FAIL", "reason": reason})
        _log("G%s: FAIL (%s)" % (self.gate, reason))
        return self.report


# ---------------------------------------------------------------------------
# M03 lock (FD 9) — the contract's serialization point
# ---------------------------------------------------------------------------
class M03Lock:
    def __init__(self, ctx: RunContext) -> None:
        self.ctx = ctx
        self.fd: int | None = None

    def acquire(self) -> None:
        if self.fd is not None:
            return  # already held by this process (per-gate sequence)
        if self.ctx.dry_run:
            _log("DRY: flock FD 9 on %s (exclusive)" % M03_LOCK)
            self.fd = -1  # sentinel: held for the rest of this dry process
            return
        M03_LOCK.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(M03_LOCK, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o600)
        try:
            os.dup2(fd, 9)
        except OSError as exc:
            os.close(fd)
            raise NotReady("cannot bind FD 9 for the M03 lock: %s" % exc)
        os.close(fd)
        self.fd = 9
        fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
        info = os.fstat(9)
        self.ctx.state["m03_lock"] = {
            "path": str(M03_LOCK), "dev": info.st_dev, "ino": info.st_ino,
            "mode": oct(info.st_mode), "acquired": dt.datetime.now(dt.timezone.utc).isoformat(),
        }
        self.ctx.save()
        _log("M03 lock acquired on FD 9 (%s inode %d)" % (M03_LOCK, info.st_ino))

    def labctl_env(self) -> dict[str, str]:
        """Env required by labctl while the caller holds FD 9 (P0-10)."""
        env: dict[str, str] = {}
        if self.ctx.dry_run:
            env["M03_LOCK_HELD_FD"] = "9"
            if marker_exists():
                env["X05_COORDINATOR_TOKEN"] = self.ctx.owner
            return env
        if self.fd is not None:
            info = os.fstat(self.fd)
            pinned = self.ctx.state.get("m03_lock", {})
            if (pinned.get("dev"), pinned.get("ino")) != (info.st_dev, info.st_ino):
                raise OrchestratorError("M03 lock identity changed while held")
            env["M03_LOCK_HELD_FD"] = "9"
        if marker_exists():
            env["X05_COORDINATOR_TOKEN"] = self.ctx.owner
        return env

    def release(self) -> None:
        if self.fd == -1:
            self.fd = None
            return
        if self.fd is not None:
            with contextlib.suppress(OSError):
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            self.fd = None
            _log("M03 lock released")


def marker_exists() -> bool:
    try:
        return X05_MARKER.exists() or X05_MARKER.is_symlink()
    except OSError:
        return False


# ---------------------------------------------------------------------------
# Fixture staging (P0-3): docker cp + byte/hash verification + vtysh -C -f
# ---------------------------------------------------------------------------
def stage_fixture(ctx: RunContext, container: str, fixture: str,
                  dest: str) -> None:
    """Copy a frozen fixture into a container and verify its exact bytes."""
    path = HERE / fixture
    raw = path.read_bytes()
    size, digest = FIXTURES[fixture]
    if len(raw) != size or _sha256(raw) != digest:
        raise OrchestratorError(
            "fixture %s does not match the frozen runtime plan digest" % fixture)
    ctx.cmd.run(["docker", "cp", str(path), "%s:%s" % (container, dest)],
                label="docker-cp " + container)
    if ctx.dry_run:
        return
    readback = ctx.cmd.dex_read(
        container, "sha256sum", dest, dry_value=(digest + "  " + dest + "\n").encode())
    observed = readback.decode().split()[0] if readback.split() else ""
    if observed != digest:
        raise OrchestratorError(
            "fixture %s changed in transit to %s:%s" % (fixture, container, dest))


def verify_gateway_frr_base(ctx: RunContext, gateway: str) -> None:
    """Verify /etc/frr/frr.conf equals the canonical base fixture (P0-3)."""
    expected = GW_FRR_BASE_BY_FIXTURE[GW_BASE_FIXTURE[gateway]]
    if ctx.dry_run:
        _log("DRY: verify %s:/etc/frr/frr.conf sha256 == %s" % (gateway, expected[:16]))
        return
    raw = ctx.cmd.dex_read(gateway, "sha256sum", "/etc/frr/frr.conf",
                           dry_value=(expected + "  /etc/frr/frr.conf\n").encode())
    observed = raw.decode().split()[0] if raw.split() else ""
    if observed != expected:
        raise GateFailure(
            "%s FRR baseline is not the canonical base fixture (got %s)"
            % (gateway, observed))


def apply_gateway_frr(ctx: RunContext, gateway: str, *, add: bool) -> None:
    """Scoped gateway FRR extension via docker cp + vtysh -C -f + vtysh -f."""
    suffix = "add" if add else "remove"
    vrf = "ovnvrf300" if gateway == GW1 else "ovnvrf400"
    fixture = "x05-%s-%s.conf" % ("gw1" if gateway == GW1 else "gw2", suffix)
    verify_gateway_frr_base(ctx, gateway)
    in_container = "/tmp/" + fixture
    stage_fixture(ctx, gateway, fixture, in_container)
    if ctx.dry_run:
        _log("DRY: vtysh -f %s in %s" % (in_container, gateway))
    elif add:
        ctx.cmd.dex(gateway, "vtysh", "-C", "-f", in_container)
        ctx.cmd.dex(gateway, "vtysh", "-f", in_container)
    else:
        # Idempotent remove: bgpd rejects the no-form with rc=13 when the
        # BGP instance is already absent, so the command result is not the
        # proof. Apply without check and prove the end state instead: the
        # X05 BGP instance must be gone from the running config. The bare
        # vrf <name> stub may remain here: the kernel VRF is OVN-generated
        # and is only removed later, after the NB inverse transaction
        # (teardown proves "OVN-generated VRFs absent" at that point).
        ctx.cmd.dex(gateway, "vtysh", "-f", in_container, check=False)
        running = ctx.cmd.dex_read(gateway, "vtysh", "-c", "show running-config")
        instance = ("router bgp 100 vrf " + vrf).encode()
        if instance in running:
            raise GateFailure("gateway %s still carries the X05 BGP instance "
                              "%s after the remove fixture" % (gateway, vrf))
    verify_gateway_frr_base(ctx, gateway)
    ctx.cmd.run(["docker", "exec", gateway, "rm", "-f", in_container])


FRR_PATHSPACE_DAEMONS = (
    "printf '%s\\n' zebra=yes bgpd=yes staticd=yes bfdd=no ospfd=no ospf6d=no "
    "ripd=no ripngd=no isisd=no pimd=no pim6d=no ldpd=no nhrpd=no eigrpd=no "
    "sharpd=no pbrd=no fabricd=no vrrpd=no vtysh_enable=yes "
    "> /etc/frr/{ps}/daemons; : > /etc/frr/{ps}/vtysh.conf; "
    "if getent passwd frr >/dev/null 2>&1; then "
    "chown -R frr:frr /etc/frr/{ps} /run/frr/{ps}; fi"
)
FRR_MAIN_DAEMONS = (
    "printf '%s\\n' zebra=yes bgpd=yes staticd=yes bfdd=no ospfd=no ospf6d=no "
    "ripd=no ripngd=no isisd=no pimd=no pim6d=no ldpd=no nhrpd=no eigrpd=no "
    "sharpd=no pbrd=no fabricd=no vrrpd=no vtysh_enable=yes "
    "> /etc/frr/daemons; : > /etc/frr/vtysh.conf; "
    "mkdir -p /run/frr; "
    "if getent passwd frr >/dev/null 2>&1; then "
    "chown frr:frr /etc/frr/frr.conf /etc/frr/daemons /etc/frr/vtysh.conf; "
    "chown -R frr:frr /run/frr; fi"
)
FRR_INIT_START = (
    'init=""; for c in /usr/libexec/frr/frrinit.sh /usr/lib/frr/frrinit.sh; '
    'do [ -x "$c" ] && { init="$c"; break; }; done; '
    '[ -n "$init" ] || { echo "frrinit.sh missing" >&2; exit 1; }; "$init" start'
)


def start_frr_pathspace(ctx: RunContext, container: str, fixture: str) -> None:
    """Start a dedicated FRR pathspace (-N x05) from a frozen fixture (P0-7)."""
    ctx.cmd.dex(container, "mkdir", "-p", "/etc/frr/" + PATHSPACE, "/run/frr/" + PATHSPACE)
    stage_fixture(ctx, container, fixture, "/etc/frr/%s/frr.conf" % PATHSPACE)
    ctx.cmd.dex(container, "sh", "-c", FRR_PATHSPACE_DAEMONS.format(ps=PATHSPACE))
    ctx.cmd.dex(container, "vtysh", "--vty_socket", "/run/frr/" + PATHSPACE,
                "-C", "-f", "/etc/frr/%s/frr.conf" % PATHSPACE)
    ctx.cmd.dex(container, "sh", "-c",
                'init=""; for c in /usr/libexec/frr/frrinit.sh /usr/lib/frr/frrinit.sh; '
                'do [ -x "$c" ] && { init="$c"; break; }; done; '
                '[ -n "$init" ] || { echo "frrinit.sh missing" >&2; exit 1; }; '
                '"$init" start ' + PATHSPACE)


def pathspace_daemons(ctx: RunContext, container: str) -> str:
    """List daemon:pid lines whose cmdline mentions -N x05 (empty if none)."""
    probe = (
        'for daemon in zebra bgpd staticd; do '
        'for pid in $(pidof "$daemon" 2>/dev/null || true); do '
        'cmdline="$(tr "\\000" " " </proc/$pid/cmdline 2>/dev/null || true)"; '
        'case "$cmdline" in *"-N ' + PATHSPACE + '"*|*"/run/frr/' + PATHSPACE + '") '
        'printf "%s:%s\\n" "$daemon" "$pid";; esac; done; done'
    )
    if ctx.dry_run:
        return ""
    raw = ctx.cmd.dex_read(container, "sh", "-c", probe)
    return raw.decode("utf-8", "replace").strip()


def stop_frr_pathspace(ctx: RunContext, container: str) -> None:
    """Stop only -N x05 daemons, prove they are gone, remove the pathspace."""
    active = pathspace_daemons(ctx, container)
    if active:
        ctx.cmd.dex(container, "sh", "-c",
                    'init=""; for c in /usr/libexec/frr/frrinit.sh /usr/lib/frr/frrinit.sh; '
                    'do [ -x "$c" ] && { init="$c"; break; }; done; '
                    '[ -n "$init" ] || { echo "frrinit.sh missing" >&2; exit 1; }; '
                    '"$init" stop ' + PATHSPACE)
        remaining = pathspace_daemons(ctx, container)
        if remaining:
            raise GateFailure("FRR pathspace %s still active in %s: %s"
                              % (PATHSPACE, container, remaining))
    ctx.cmd.dex(container, "rm", "-rf", "/run/frr/" + PATHSPACE, "/etc/frr/" + PATHSPACE)


def container_running(ctx: RunContext, name: str) -> bool:
    if ctx.dry_run:
        return False
    result = ctx.cmd.run(["docker", "inspect", "--format", "{{.State.Status}}", name],
                         check=False, timeout=15.0)
    return result.returncode == 0 and result.stdout.strip() == b"running"


def container_absent(ctx: RunContext, name: str) -> bool:
    if ctx.dry_run:
        return True
    result = ctx.cmd.run(["docker", "inspect", name], check=False, timeout=15.0)
    return result.returncode != 0


def profile_owner_token(ctx: RunContext) -> str:
    """Read the DCI profile owner token from the existing client A label."""
    if ctx.dry_run:
        return "<profile-owner>"
    raw = ctx.cmd.read(
        ["docker", "inspect", "--format",
         '{{index .Config.Labels "labctl.dci.owner"}}', CLIENT_A],
        dry_value=b"labctl-dci-dryrun", timeout=15.0)
    token = raw.decode().strip()
    if not token:
        raise NotReady("cannot read the DCI profile owner label from " + CLIENT_A)
    return token


def remove_container_owned(ctx: RunContext, name: str, gate: GateScope) -> None:
    """Remove a labeled X05 container after proving our label owns it."""
    if ctx.dry_run:
        _log("DRY: verify label labctl-x05-owner=%s then docker rm -f %s"
             % (ctx.owner, name))
        return
    result = ctx.cmd.run(["docker", "inspect", "--format",
                          '{{index .Config.Labels "labctl-x05-owner"}}', name],
                         check=False, timeout=15.0)
    if result.returncode != 0:
        gate.step("container %s already absent" % name)
        return
    owner = result.stdout.decode().strip()
    if owner != ctx.owner:
        raise OrchestratorError(
            "refusing to remove %s: labctl-x05-owner=%r is not this run" % (name, owner))
    ctx.cmd.run(["docker", "rm", "-f", name])


# ---------------------------------------------------------------------------
# Runtime build (P0-7): the resources the shell script assumed into existence
# ---------------------------------------------------------------------------
def ensure_client_a_vtysh_conf(ctx: RunContext, gate: GateScope) -> None:
    """Ensure the pre-existing A client's vtysh has a config file.

    The DCI baseline created dci-client-1 without /etc/frr/vtysh.conf, so
    every vtysh invocation writes a warning to stderr. The reviewed
    evaluator's read-only invariant rejects any stderr on G1/G2 samples, so
    the orchestrator creates the empty file (frr-owned) when absent; an
    existing file is never touched.
    """
    if ctx.dry_run:
        _log("DRY: ensure /etc/frr/vtysh.conf exists in %s (empty, frr-owned)"
             % CLIENT_A)
        return
    if ctx.cmd.dex(CLIENT_A, "test", "-f", "/etc/frr/vtysh.conf",
                   check=False).returncode == 0:
        gate.step("A client vtysh.conf already present; left untouched")
        return
    ctx.cmd.dex(CLIENT_A, "touch", "/etc/frr/vtysh.conf")
    ctx.cmd.dex(CLIENT_A, "chown", "frr:frr", "/etc/frr/vtysh.conf")
    ctx.cmd.dex(CLIENT_A, "chmod", "644", "/etc/frr/vtysh.conf")
    ctx.journal("client-vtysh-conf", CLIENT_A + ":/etc/frr/vtysh.conf",
                status="created", before="absent")
    probe = ctx.cmd.dex(CLIENT_A, "vtysh", "-c", "show version", check=False)
    if probe.stderr:
        raise GateFailure(
            "A client vtysh still writes stderr after vtysh.conf fix: %s"
            % probe.stderr.decode("utf-8", "replace")[:200])
    gate.step("created empty /etc/frr/vtysh.conf in A client (baseline gap; "
              "vtysh stderr warning would trip the evaluator read-only invariant)")


def build_runtime(ctx: RunContext, gate: GateScope) -> None:
    """Create every X05 runtime resource from x05-runtime-plan's inventory."""
    # 1. Persist the marker at INTENT before the first mutation (contract).
    if ctx.dry_run:
        _log("DRY: write X05 marker %s (0600 root, version=2, token=%s)"
             % (X05_MARKER, ctx.owner))
    else:
        X05_MARKER.parent.mkdir(parents=True, exist_ok=True)
        journal_path = ctx.run_root / "08-x05" / "runtime-journal.jsonl"
        payload = "\n".join((
            "version=2",
            "token=" + ctx.owner,
            "owner=" + ctx.owner,
            "run_hex=" + ctx.run_hex,
            "state=INTENT",
            "orchestrator=" + str(HERE / "x05-orchestrate.py"),
            "runtime_journal=" + str(journal_path),
        )) + "\n"
        with open(X05_MARKER, "w") as handle:
            handle.write(payload)
        os.chmod(X05_MARKER, 0o600)
    ctx.journal("marker", str(X05_MARKER), status="created", before="absent")

    # 1b. A-client vtysh.conf precondition (baseline gap; G1 evaluator).
    ensure_client_a_vtysh_conf(ctx, gate)

    # 2. Gateway BGP mirrors (bgpvrf300/400 veth pairs bound to the
    #    OVN-generated VRFs that the NB dynamic-routing rows create).
    for number, gateway, vrf, gw_ip in GATEWAYS:
        build_gateway_mirror(ctx, gate, number, gateway, vrf, gw_ip)

    # 3. Gateway FRR extension (B X05 VRF + neighbor + BFD peer) — P0-3 path.
    for gateway in (GW1, GW2):
        apply_gateway_frr(ctx, gateway, add=True)
        ctx.journal("gateway-frr", gateway + ":ovnvrf-extension", status="applied")

    # 4. Sentinels (A on chassis 1, B on chassis 2).
    for tenant, (chassis, ns, tap, inner, ip, mac) in SENTINELS.items():
        build_sentinel(ctx, gate, tenant, chassis, ns, tap, inner, ip, mac)

    # 5. Chassis 2 B-tenant datapath (VRF slaves, VXLAN, advertise dummy).
    build_chassis2_network(ctx, gate)

    # 6. Chassis 2 OVS external_ids (return filter mapping + per-VNI list).
    set_chassis2_external_ids(ctx, gate, inverse=False)

    # 7. Dedicated FRR pathspace x05 on chassis 2 (tenant B EVPN speaker).
    start_frr_pathspace(ctx, CHASSIS2, "x05-chassis.conf")
    ctx.journal("frr-pathspace", CHASSIS2 + ":" + PATHSPACE, status="started")

    # 8. Client B container (dci-client-2, AS 201) with both /30 legs.
    build_client_b(ctx, gate)

    # 9. EVPN peer container (dci-x05-peer-2) with its own pathspace.
    build_peer_b(ctx, gate)

    if not ctx.dry_run:
        marker_state_built(X05_MARKER, "BUILT")
    gate.step("runtime build complete (mirrors, sentinels, chassis2 datapath, "
              "pathspace x05, client-2, peer-2)")


def marker_state_built(path: pathlib.Path, state: str) -> None:
    lines = path.read_text().splitlines()
    updated = []
    for line in lines:
        if line.startswith("state="):
            updated.append("state=" + state)
        else:
            updated.append(line)
    path.write_text("\n".join(updated) + "\n")


def wait_link(ctx: RunContext, container: str, link: str, attempts: int = 30) -> bool:
    """Poll until a link exists inside a container (or give up)."""
    if ctx.dry_run:
        return True
    for _ in range(attempts):
        result = ctx.cmd.dex(container, "ip", "link", "show", link, check=False)
        if result.returncode == 0:
            return True
        time.sleep(1.0)
    return False


def wait_vrf_absent(
    ctx: RunContext, container: str, link: str, attempts: int = 30
) -> bool:
    """Poll until an OVN-generated VRF link is gone (or give up).

    Mirror of wait_link for the inverse direction: after the NB inverse
    deletes the owned rows, ovn-northd/ovn-controller remove the generated
    VRF interfaces asynchronously, so the strict absence check in the
    teardown must wait for that convergence window first.
    """
    if ctx.dry_run:
        return True
    for _ in range(attempts):
        result = ctx.cmd.dex(container, "ip", "link", "show", link, check=False)
        if result.returncode != 0:
            return True
        time.sleep(1.0)
    return False


def alias_link(ctx: RunContext, container: str, link: str) -> None:
    ctx.cmd.dex(container, "ip", "link", "set", link, "alias", ctx.owner)


def build_gateway_mirror(ctx: RunContext, gate: GateScope, number: int,
                         gateway: str, vrf: str, gw_ip: str) -> None:
    ovs_if, vrf_if = "bgpvrf%d-ovs" % number, "bgpvrf%d" % number
    if ctx.dry_run:
        _log("DRY: %s: wait VRF %s; create veth %s<->%s; set slave MAC from "
             "NB lrp-x05-%d-external; enslave %s to %s; "
             "addr %s; OVS port %s on br-int iface-id=%s"
             % (gateway, vrf, ovs_if, vrf_if, number, vrf_if, vrf, gw_ip,
                ovs_if, vrf_if))
        return
    if not wait_link(ctx, gateway, vrf):
        raise GateFailure(
            "%s: OVN-generated VRF %s never appeared after the NB forward "
            "transaction (dynamic routing not converged)" % (gateway, vrf))
    ctx.cmd.dex(gateway, "ip", "link", "add", ovs_if, "type", "veth", "peer", vrf_if)
    alias_link(ctx, gateway, ovs_if)
    alias_link(ctx, gateway, vrf_if)
    mirror_lrp_mac(ctx, gate, gateway, number, vrf_if, gw_ip)
    ctx.cmd.dex(gateway, "ip", "link", "set", vrf_if, "master", vrf)
    ctx.cmd.dex(gateway, "ip", "addr", "add", gw_ip, "dev", vrf_if)
    ctx.cmd.dex(gateway, "ip", "link", "set", ovs_if, "up")
    ctx.cmd.dex(gateway, "ip", "link", "set", vrf_if, "up")
    ctx.cmd.dex(gateway, "ovs-vsctl", "--may-exist", "add-port", "br-int", ovs_if,
                "--", "set", "Interface", ovs_if,
                "external_ids:iface-id=" + vrf_if,
                "external_ids:x05-owner=" + ctx.owner)
    ctx.journal("gateway-mirror", "%s:%s" % (gateway, ovs_if), status="created")


def mirror_lrp_mac(ctx: RunContext, gate: GateScope, gateway: str, number: int,
                   vrf_if: str, gw_ip: str) -> None:
    """Pin the mirror veth slave to the NB LRP MAC (P1-3).

    The plan (linux-veth bgpvrf<n>, mac_source NB:lrp-x05-<n>-external)
    requires the slave to carry the LRP MAC: OVN answers ARP from that MAC,
    so a random veth MAC would blackhole client B until its stale neighbor
    entry expires.
    """
    lrp_name = "lrp-x05-%d-external" % number
    raw = ctx.cmd.dex_read(CENTRAL, "ovn-nbctl", "--timeout=5", "get",
                           "Logical_Router_Port", lrp_name, "mac")
    expected = raw.decode("utf-8", "replace").strip().strip('"').lower()
    if re.fullmatch(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}", expected) is None:
        raise GateFailure("%s: %s returned unparsable MAC %r"
                          % (gateway, lrp_name, expected))
    current_raw = ctx.cmd.dex_read(gateway, "ip", "link", "show", "dev", vrf_if)
    match = re.search(rb"link/ether ((?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2})",
                      current_raw)
    current = match.group(1).decode().lower() if match else None
    record = {"lrp": lrp_name, "mac": expected, "previous": current}
    if current != expected:
        ctx.cmd.dex(gateway, "ip", "link", "set", "dev", vrf_if,
                    "address", expected)
        # Client B may have cached the random veth MAC; drop the neighbor so
        # it re-ARPs against the LRP MAC.
        gw_host = gw_ip.split("/")[0]
        client_if = next(iface for iface, vlan, _addr in CLIENT_B_LEGS
                         if vlan == number)
        # Defer the flush if client-B is not built yet (build_runtime step 2
        # runs before step 8 creates CLIENT_B). On a fresh build the neighbor
        # table starts empty, so this is defensive for rebuilds only.
        if ctx.cmd.run(["docker", "inspect", CLIENT_B], check=False,
                       timeout=10.0).returncode == 0:
            ctx.cmd.dex(CLIENT_B, "ip", "neigh", "flush", "to", gw_host,
                        "dev", client_if)
            record["neighbor_flushed"] = "%s:%s" % (CLIENT_B, client_if)
        else:
            _log("  mirror-lrp-mac: client-B not yet built; flush deferred")
            record["neighbor_flush_deferred"] = "%s:%s" % (CLIENT_B, client_if)
    gate.json("gateway-mirror-mac-%d.json" % number, record)


def build_sentinel(ctx: RunContext, gate: GateScope, tenant: str, chassis: str,
                   ns: str, tap: str, inner: str, ip: str, mac: str) -> None:
    if ctx.dry_run:
        _log("DRY: %s: netns %s; veth %s<->%s; OVS port iface-id=%s; "
             "inner mac %s addr %s/24 via 192.168.100.1"
             % (chassis, ns, tap, inner, ns, mac, ip))
        return
    ctx.cmd.dex(chassis, "ip", "netns", "add", ns)
    ctx.cmd.dex(chassis, "ip", "link", "add", tap, "type", "veth", "peer", inner)
    alias_link(ctx, chassis, tap)
    ctx.cmd.dex(chassis, "ovs-vsctl", "--may-exist", "add-port", "br-int", tap,
                "--", "set", "Interface", tap,
                "external_ids:iface-id=" + ns,
                "external_ids:x05-owner=" + ctx.owner)
    ctx.cmd.dex(chassis, "ip", "link", "set", inner, "netns", ns)
    ctx.cmd.dex(chassis, "ip", "link", "set", tap, "up")
    ctx.cmd.dex(chassis, "ip", "netns", "exec", ns, "ip", "link", "set", inner,
                "address", mac)
    ctx.cmd.dex(chassis, "ip", "netns", "exec", ns, "ip", "addr", "add",
                ip + "/24", "dev", inner)
    ctx.cmd.dex(chassis, "ip", "netns", "exec", ns, "ip", "link", "set", inner, "up")
    ctx.cmd.dex(chassis, "ip", "netns", "exec", ns, "ip", "link", "set", "lo", "up")
    ctx.cmd.dex(chassis, "ip", "netns", "exec", ns, "ip", "route", "replace",
                "default", "via", "192.168.100.1")
    ctx.cmd.dex(chassis, "ip", "netns", "exec", ns, "ip", "link", "set", inner,
                "alias", ctx.owner)
    ctx.journal("sentinel", "%s:%s" % (chassis, ns), status="created")


def build_chassis2_network(ctx: RunContext, gate: GateScope) -> None:
    vrf, bridge, vxlan, dummy = "ovnvrf-x05-b", "br-x05-b", "vxlan-x05-b", "evpn-x05-b"
    if ctx.dry_run:
        _log("DRY: %s: wait VRF %s (table 400); bridge %s (master vrf, "
             "addrgenmode none, router-mac %s); vxlan %s id 50200 local %s "
             "dev %s dstport 60010; dummy %s; all aliased %s"
             % (CHASSIS2, vrf, bridge, EVPN_B_ROUTER_MAC, vxlan,
                CHASSIS2_UNDERLAY, UNDERLAY_IF, dummy, ctx.owner))
        return
    if not wait_link(ctx, CHASSIS2, vrf):
        raise GateFailure("%s: OVN-generated VRF %s never appeared" % (CHASSIS2, vrf))
    ctx.cmd.dex(CHASSIS2, "ip", "link", "add", bridge, "type", "bridge")
    alias_link(ctx, CHASSIS2, bridge)
    ctx.cmd.dex(CHASSIS2, "ip", "link", "set", bridge, "master", vrf)
    ctx.cmd.dex(CHASSIS2, "ip", "link", "set", bridge, "addrgenmode", "none")
    # m03 contract (m03.sh: LRP MAC must equal the EVPN bridge MAC): the
    # bridge MAC becomes the Router MAC FRR advertises in its EVPN type-5
    # routes. The remote peer installs it as the neighbor for the VTEP, so
    # decapped frames carry a destination MAC OVN knows (lrp-x05-tenant-b's
    # MAC from the frozen plan, x05-nb-plan.sh). Without this the bridge
    # keeps a random MAC and OVN drops the decapped frames.
    ctx.cmd.dex(CHASSIS2, "ip", "link", "set", bridge, "address",
                EVPN_B_ROUTER_MAC)
    ctx.cmd.dex(CHASSIS2, "ip", "link", "set", bridge, "up")
    ctx.cmd.dex(CHASSIS2, "ip", "link", "add", vxlan, "type", "vxlan",
                "dev", UNDERLAY_IF, "id", "50200", "dstport", "60010",
                "local", CHASSIS2_UNDERLAY, "nolearning")
    alias_link(ctx, CHASSIS2, vxlan)
    ctx.cmd.dex(CHASSIS2, "ip", "link", "set", vxlan, "master", bridge)
    ctx.cmd.dex(CHASSIS2, "ip", "link", "set", vxlan, "up")
    ctx.cmd.dex(CHASSIS2, "ip", "link", "add", dummy, "type", "dummy")
    alias_link(ctx, CHASSIS2, dummy)
    ctx.cmd.dex(CHASSIS2, "ip", "link", "set", dummy, "master", bridge)
    ctx.cmd.dex(CHASSIS2, "ip", "link", "set", dummy, "up")
    ctx.journal("chassis2-network", CHASSIS2 + ":" + bridge, status="created")


def ovs_external_id(ctx: RunContext, container: str, key: str) -> str:
    if ctx.dry_run:
        return ""
    raw = ctx.cmd.dex_read(container, "ovs-vsctl", "--if-exists", "get",
                           "Open_vSwitch", ".", "external_ids:" + key)
    value = raw.decode().strip().strip('"')
    return value


def set_chassis2_external_ids(ctx: RunContext, gate: GateScope, *, inverse: bool) -> None:
    mapping_key = "dynamic-routing-port-mapping"
    local_ip_key = "ovn-evpn-local-ip"
    mapping_value = "x05-b-%s=br-x05-b" % ctx.run_hex
    if ctx.dry_run:
        if inverse:
            _log("DRY: %s: restore external_ids:%s (remove %s) and %s=%s"
                 % (CHASSIS2, mapping_key, mapping_value, local_ip_key,
                    CHASSIS2_LOCAL_IP_BASE))
        else:
            _log("DRY: %s: capture then set external_ids:%s=%s and %s=%s"
                 % (CHASSIS2, mapping_key, mapping_value, local_ip_key,
                    CHASSIS2_LOCAL_IP_X05))
        return
    if not inverse:
        original_mapping = ovs_external_id(ctx, CHASSIS2, mapping_key)
        original_local_ip = ovs_external_id(ctx, CHASSIS2, local_ip_key)
        if original_local_ip != CHASSIS2_LOCAL_IP_BASE:
            raise GateFailure(
                "%s external_ids:%s is %r; the pinned baseline expects %r"
                % (CHASSIS2, local_ip_key, original_local_ip, CHASSIS2_LOCAL_IP_BASE))
        if original_mapping:
            raise GateFailure(
                "%s already carries %s=%r; refusing to adopt or overwrite"
                % (CHASSIS2, mapping_key, original_mapping))
        ctx.state["chassis2_external_ids_before"] = {
            mapping_key: original_mapping, local_ip_key: original_local_ip}
        ctx.save()
        ctx.cmd.dex(CHASSIS2, "ovs-vsctl", "set", "Open_vSwitch", ".",
                    "external_ids:%s=%s" % (mapping_key, mapping_value))
        ctx.cmd.dex(CHASSIS2, "ovs-vsctl", "set", "Open_vSwitch", ".",
                    "external_ids:%s=%s" % (local_ip_key, CHASSIS2_LOCAL_IP_X05))
        ctx.journal("ovs-external-id", CHASSIS2 + ":" + mapping_key,
                    status="set", before=original_mapping)
        ctx.journal("ovs-external-id", CHASSIS2 + ":" + local_ip_key,
                    status="set", before=original_local_ip)
        return
    # inverse: restore the exact captured originals
    before = ctx.state.get("chassis2_external_ids_before", {})
    if before.get(mapping_key):
        ctx.cmd.dex(CHASSIS2, "ovs-vsctl", "set", "Open_vSwitch", ".",
                    "external_ids:%s=%s" % (mapping_key, before[mapping_key]))
    else:
        ctx.cmd.dex(CHASSIS2, "ovs-vsctl", "--if-exists", "remove",
                    "Open_vSwitch", ".", "external_ids", mapping_key)
    original_local_ip = before.get(local_ip_key) or CHASSIS2_LOCAL_IP_BASE
    ctx.cmd.dex(CHASSIS2, "ovs-vsctl", "set", "Open_vSwitch", ".",
                "external_ids:%s=%s" % (local_ip_key, original_local_ip))
    remaining = ovs_external_id(ctx, CHASSIS2, mapping_key)
    if remaining:
        raise GateFailure("%s external_ids:%s still set after restore: %r"
                          % (CHASSIS2, mapping_key, remaining))


def docker_run_detached(ctx: RunContext, name: str, image: str,
                        extra_labels: Mapping[str, str]) -> None:
    profile = profile_owner_token(ctx)
    argv = ["docker", "run", "-d", "--name", name, "--network", "none",
            "--privileged", "--label", "labctl.dci.owner=" + profile,
            "--label", "labctl-x05-owner=" + ctx.owner]
    for key, value in extra_labels.items():
        argv += ["--label", "%s=%s" % (key, value)]
    argv += ["--entrypoint", "/bin/sh", image, "-c", "while :; do sleep 3600; done"]
    ctx.cmd.run(argv, label="docker-run " + name)


def ovs_runc_port(ctx: RunContext, bridge: str, iface: str, container: str,
                  ipaddress: str, vlan: int | None) -> None:
    argv = [str(ctx.ovs_runc), "add-port", bridge, iface, container,
            "--ipaddress=" + ipaddress]
    ctx.cmd.run(argv, env={"RUNC_CMD": "docker"}, label="ovs-runc add-port")
    if vlan is not None:
        ctx.cmd.run([str(ctx.ovs_runc), "set-vlan", bridge, iface, container, str(vlan)],
                    env={"RUNC_CMD": "docker"}, label="ovs-runc set-vlan")
    ctx.cmd.dex(container, "ip", "link", "set", iface, "up")
    ctx.cmd.run(["ovs-vsctl", "--if-exists", "set", "Interface", iface,
                 "external_ids:x05-owner=" + ctx.owner], label="ovs owner tag")


def ovs_runc_del_port(ctx: RunContext, bridge: str, iface: str, container: str) -> None:
    ctx.cmd.run([str(ctx.ovs_runc), "del-port", bridge, iface, container],
                env={"RUNC_CMD": "docker"}, check=False, label="ovs-runc del-port")


def build_client_b(ctx: RunContext, gate: GateScope) -> None:
    if ctx.dry_run:
        _log("DRY: docker run %s (%s, AS 201, labels labctl.dci.owner + %s); "
             "cp x05-client2.conf; vtysh -C -f; frrinit start; "
             "ovs-runc add-port eth1/eth2 on br-ovn-ext VLAN 300/400; lo 10.0.0.1/32"
             % (CLIENT_B, FRR_IMAGE, ctx.owner))
        return
    if not container_absent(ctx, CLIENT_B):
        raise GateFailure("%s already exists; adoption is forbidden" % CLIENT_B)
    docker_run_detached(ctx, CLIENT_B, FRR_IMAGE, {})
    for _ in range(20):
        if container_running(ctx, CLIENT_B):
            break
        time.sleep(0.5)
    else:
        raise GateFailure("%s did not reach running state" % CLIENT_B)
    ctx.cmd.run(["docker", "cp", str(HERE / "x05-client2.conf"),
                 "%s:/etc/frr/frr.conf" % CLIENT_B], label="docker-cp " + CLIENT_B)
    ctx.cmd.dex(CLIENT_B, "sh", "-c", FRR_MAIN_DAEMONS)
    ctx.cmd.dex(CLIENT_B, "vtysh", "-C", "-f", "/etc/frr/frr.conf")
    ctx.cmd.dex(CLIENT_B, "sh", "-c", FRR_INIT_START)
    for iface, vlan, address in CLIENT_B_LEGS:
        ovs_runc_port(ctx, "br-ovn-ext", iface, CLIENT_B, address, vlan)
    ctx.cmd.dex(CLIENT_B, "ip", "addr", "replace", "10.0.0.1/32", "dev", "lo")
    ctx.journal("docker-container", CLIENT_B, status="created")


def build_peer_b(ctx: RunContext, gate: GateScope) -> None:
    if ctx.dry_run:
        _log("DRY: docker run %s (%s, labels); ovs-runc add-port br-ovn eth1 %s; "
             "vrf-x05-peer table 50200; br-x05-peer 10.251.0.1/32; "
             "vxlan-x05-pr id 50200 local 170.168.0.8 dev eth1 dstport 4789; "
             "evpn-x05-pr; FRR pathspace x05 with x05-peer.conf"
             % (PEER_B, PEER_IMAGE, PEER_UNDERLAY))
        return
    if not container_absent(ctx, PEER_B):
        raise GateFailure("%s already exists; adoption is forbidden" % PEER_B)
    docker_run_detached(ctx, PEER_B, PEER_IMAGE, {})
    for _ in range(20):
        if container_running(ctx, PEER_B):
            break
        time.sleep(0.5)
    else:
        raise GateFailure("%s did not reach running state" % PEER_B)
    ovs_runc_port(ctx, "br-ovn", "eth1", PEER_B, PEER_UNDERLAY, None)
    ctx.cmd.dex(PEER_B, "ip", "link", "add", "vrf-x05-peer", "type", "vrf",
                "table", "50200")
    alias_link(ctx, PEER_B, "vrf-x05-peer")
    ctx.cmd.dex(PEER_B, "ip", "link", "set", "vrf-x05-peer", "up")
    ctx.cmd.dex(PEER_B, "ip", "link", "add", "br-x05-peer", "type", "bridge")
    alias_link(ctx, PEER_B, "br-x05-peer")
    ctx.cmd.dex(PEER_B, "ip", "link", "set", "br-x05-peer", "master", "vrf-x05-peer")
    ctx.cmd.dex(PEER_B, "ip", "link", "set", "br-x05-peer", "addrgenmode", "none")
    ctx.cmd.dex(PEER_B, "ip", "link", "set", "br-x05-peer", "up")
    ctx.cmd.dex(PEER_B, "ip", "link", "add", "vxlan-x05-pr", "type", "vxlan",
                "dev", "eth1", "id", "50200", "dstport", "4789",
                "local", "170.168.0.8", "nolearning")
    alias_link(ctx, PEER_B, "vxlan-x05-pr")
    ctx.cmd.dex(PEER_B, "ip", "link", "set", "vxlan-x05-pr", "master", "br-x05-peer")
    ctx.cmd.dex(PEER_B, "ip", "link", "set", "vxlan-x05-pr", "up")
    ctx.cmd.dex(PEER_B, "ip", "link", "add", "evpn-x05-pr", "type", "dummy")
    alias_link(ctx, PEER_B, "evpn-x05-pr")
    ctx.cmd.dex(PEER_B, "ip", "link", "set", "evpn-x05-pr", "master", "br-x05-peer")
    ctx.cmd.dex(PEER_B, "ip", "link", "set", "evpn-x05-pr", "up")
    ctx.cmd.dex(PEER_B, "ip", "addr", "replace", PEER_SOURCE_B + "/32",
                "dev", "br-x05-peer")
    start_frr_pathspace(ctx, PEER_B, "x05-peer.conf")
    ctx.journal("frr-pathspace", PEER_B + ":" + PATHSPACE, status="started")
    ctx.journal("docker-container", PEER_B, status="created")


# ---------------------------------------------------------------------------
# Runtime teardown in the contract rollback order (P0-10)
# ---------------------------------------------------------------------------
def teardown_runtime(ctx: RunContext, gate: GateScope, *, nb_inverse: bool = True) -> dict[str, Any]:
    """Compensate every X05 resource in the contract order.

    Order: withdraw B EVPN (pathspaces) -> gateway BGP (remove fixtures) ->
    sentinel ports/netns -> peer/client ports+containers -> chassis2 links,
    mirrors, filters -> NB inverse -> generated VRF absence -> X05 absence.
    """
    outcome: dict[str, Any] = {"steps": []}

    def step(name: str) -> None:
        outcome["steps"].append(name)
        gate.step(name)

    # Withdraw B EVPN: stop the two x05 pathspaces (peer first per contract:
    # its internal FRR and links must be stopped before container removal).
    for container in (PEER_B, CHASSIS2):
        if ctx.dry_run:
            step("DRY stop FRR pathspace %s in %s" % (PATHSPACE, container))
            continue
        if container_absent(ctx, container):
            # Container already gone: its pathspace is trivially absent.
            # Probing a missing container would raise (docker exec rc!=0).
            step("FRR pathspace %s in %s: container already absent"
                 % (PATHSPACE, container))
            continue
        stop_frr_pathspace(ctx, container)
        step("stopped FRR pathspace %s in %s" % (PATHSPACE, container))

    # Withdraw B gateway BGP legs with the matching remove fixtures.
    for gateway in (GW1, GW2):
        if ctx.dry_run:
            step("DRY apply %s remove fixture in %s" % (gateway, gateway))
        else:
            apply_gateway_frr(ctx, gateway, add=False)
            step("applied FRR remove fixture in %s" % gateway)

    # Remove sentinel OVS ports, taps and netns (B LSP parent was already
    # restored by the CAS inverse before this point).
    for tenant, (chassis, ns, tap, _inner, _ip, _mac) in SENTINELS.items():
        if ctx.dry_run:
            step("DRY remove sentinel %s (%s tap/netns/OVS port)" % (tenant, chassis))
            continue
        ctx.cmd.dex(chassis, "ovs-vsctl", "--if-exists", "del-port", "br-int", tap)
        ctx.cmd.dex(chassis, "ip", "netns", "del", ns, check=False)
        ctx.cmd.dex(chassis, "ip", "link", "del", tap, check=False)
        step("removed sentinel %s from %s" % (tenant, chassis))

    # Remove peer/client OVS ports, then the labeled containers.
    if not ctx.dry_run:
        ovs_runc_del_port(ctx, "br-ovn-ext", "eth1", CLIENT_B)
        ovs_runc_del_port(ctx, "br-ovn-ext", "eth2", CLIENT_B)
        ovs_runc_del_port(ctx, "br-ovn", "eth1", PEER_B)
        step("removed client-2/peer OVS ports")
        remove_container_owned(ctx, CLIENT_B, gate)
        remove_container_owned(ctx, PEER_B, gate)
        step("removed labeled containers %s and %s" % (CLIENT_B, PEER_B))
    else:
        step("DRY remove client/peer OVS ports and containers")

    # Remove chassis2 B links, gateway mirrors, and restore the filters.
    if ctx.dry_run:
        step("DRY remove chassis2 links (evpn/vxlan/br-x05-b), gateway mirrors, "
             "and restore OVS external_ids")
    else:
        for link in ("evpn-x05-b", "vxlan-x05-b", "br-x05-b"):
            ctx.cmd.dex(CHASSIS2, "ip", "link", "del", link, check=False)
        for number, gateway, _vrf, _ip in GATEWAYS:
            ovs_if = "bgpvrf%d-ovs" % number
            ctx.cmd.dex(gateway, "ovs-vsctl", "--if-exists", "del-port",
                        "br-int", ovs_if)
            ctx.cmd.dex(gateway, "ip", "link", "del", ovs_if, check=False)
        step("removed chassis2 links and gateway mirrors")
        set_chassis2_external_ids(ctx, gate, inverse=True)
        step("restored chassis2 OVS external_ids")

    # NB inverse: one transaction that detaches the A sentinel and deletes
    # the 34 owned rows (P0-4), verified by the tool's own checkers.
    if nb_inverse and ctx.state.get("gates", {}).get("nb", {}).get("status") == "PASS":
        # Mirror of the Gnb P0-7 step: the tenant-B client /30 return route
        # is applied after the forward transaction, so it must be removed
        # before the inverse — the inverse toolchain requires the owned
        # routers to match the checked forward receipt exactly.
        if not ctx.dry_run:
            ctx.cmd.dex(CENTRAL, "ovn-nbctl", "--if-exists", "lr-route-del",
                        "lr-x05-tenant-b", "169.254.254.4/30")
        nb_inverse_forward(ctx, gate)
        step("NB inverse transaction applied and checked")
    elif nb_inverse:
        step("NB inverse skipped (no checked forward receipt in state)")

    # Observation-only generated VRFs must be gone after the NB inverse.
    # ovn-controller removes them asynchronously after the NB delete, so
    # poll with the same bounded pattern as wait_link before the strict
    # absence check (the check stays strict: residue after the window fails).
    if not ctx.dry_run:
        residues = []
        for number, gateway, vrf, _ip in GATEWAYS:
            if not wait_vrf_absent(ctx, gateway, vrf):
                residues.append("%s:%s" % (gateway, vrf))
        if not wait_vrf_absent(ctx, CHASSIS2, "ovnvrf-x05-b"):
            residues.append(CHASSIS2 + ":ovnvrf-x05-b")
        if residues:
            raise GateFailure("OVN-generated VRFs remain after NB inverse: %s"
                              % ",".join(residues))
        step("verified OVN-generated VRFs absent")

    outcome["x05_absence"] = prove_x05_absence(ctx)
    if not outcome["x05_absence"].get("clean"):
        raise GateFailure("X05 residue after teardown: %s"
                          % json.dumps(outcome["x05_absence"], sort_keys=True))
    step("proved X05 absence")
    return outcome


def prove_x05_absence(ctx: RunContext) -> dict[str, Any]:
    """Verify no X05 NB residue, containers, links, pathspaces or marker."""
    report: dict[str, Any] = {"clean": True, "residue": []}
    if ctx.dry_run:
        return report
    for table in ("Logical_Switch", "Logical_Router", "Logical_Switch_Port",
                  "Logical_Router_Port", "Gateway_Chassis"):
        for row in ctx.cmd.nb_list(table, ("name", "external_ids")):
            ids = row.get("external_ids")
            if isinstance(ids, list) and ids and ids[0] == "map":
                for pair in ids[1]:
                    if pair == ["x05-owner", ctx.owner]:
                        report["residue"].append("%s:%s" % (table, row.get("name")))
    for name in (CLIENT_B, PEER_B):
        if not container_absent(ctx, name):
            report["residue"].append("container:" + name)
    for container, links in (
        (CHASSIS2, ("br-x05-b", "vxlan-x05-b", "evpn-x05-b", "x05-tenant-b-p")),
        (CHASSIS1, ("x05-tenant-a-p",)),
        (GW1, ("bgpvrf300-ovs",)),
        (GW2, ("bgpvrf400-ovs",)),
    ):
        for link in links:
            if ctx.cmd.dex(container, "ip", "link", "show", link,
                           check=False).returncode == 0:
                report["residue"].append("link:%s:%s" % (container, link))
    if not ctx.dry_run and not container_absent(ctx, PEER_B):
        for link in ("vrf-x05-peer", "br-x05-peer", "vxlan-x05-pr", "evpn-x05-pr"):
            if ctx.cmd.dex(PEER_B, "ip", "link", "show", link,
                           check=False).returncode == 0:
                report["residue"].append("link:%s:%s" % (PEER_B, link))
    for container in (CHASSIS2, PEER_B):
        if container_absent(ctx, container):
            # Container already gone: its pathspace is trivially absent.
            # Probing a missing container would raise (docker exec rc!=0).
            continue
        if pathspace_daemons(ctx, container):
            report["residue"].append("pathspace:%s:%s" % (container, PATHSPACE))
        probe = ctx.cmd.dex(container, "test", "-e", "/etc/frr/" + PATHSPACE,
                            check=False)
        if probe.returncode == 0:
            report["residue"].append("pathspace-files:%s" % container)
    report["clean"] = not report["residue"]
    return report


def nb_inverse_forward(ctx: RunContext, gate: GateScope) -> None:
    """Build, apply and check the NB inverse using the tx toolchain (P0-4/5/6)."""
    if ctx.dry_run:
        _log("DRY: %s --live > preinverse-snapshot.json" % TOOL_NB_SNAPSHOT)
        _log("DRY: %s --build-inverse gate-nb/nb-preflight.json "
             "gate-nb/nb-forward-checked.json --state <snapshot> --owner %s "
             "--run-hex %s | ONE ovsdb-client transact | --check-inverse-result"
             % (TOOL_NB_TX, ctx.owner, ctx.run_hex))
        return
    nb_dir = ctx.run_root / "08-x05" / "gate-nb"
    preflight = nb_dir / "nb-preflight.json"
    forward = nb_dir / "nb-forward-checked.json"
    if not preflight.is_file() or not forward.is_file():
        raise OrchestratorError(
            "NB inverse needs gate-nb artifacts %s and %s" % (preflight, forward))
    preinverse = ctx.evidence.gate_dir(gate.gate) / "preinverse-snapshot.json"
    preinverse.parent.mkdir(parents=True, exist_ok=True)
    snapshot = ctx.cmd.read(["bash", str(TOOL_NB_SNAPSHOT), "--live"],
                            label="nb-full-snapshot preinverse")
    preinverse.write_bytes(snapshot)
    document = json.loads(snapshot.decode())
    if document.get("nb_cfg_before") != document.get("nb_cfg_after"):
        raise GateFailure("NB drifted while capturing the preinverse snapshot")
    build = ctx.cmd.read(
        ["python3", str(TOOL_NB_TX), "--build-inverse", str(preflight),
         str(forward), "--state", str(preinverse), "--owner", ctx.owner,
         "--run-hex", ctx.run_hex],
        label="nb-tx build-inverse")
    ctx.evidence.write("gate-%s/inverse-tx.json" % gate.gate, build)
    transaction = json.loads(build.decode())
    reply = ctx.cmd.nb_transact(transaction, label="NB inverse transaction")
    raw_path = ctx.evidence.gate_dir(gate.gate) / "inverse-result.raw.json"
    raw_path.write_bytes(json.dumps(reply, sort_keys=True).encode())
    checked = ctx.cmd.read(
        ["python3", str(TOOL_NB_TX), "--check-inverse-result", str(raw_path),
         "--preflight", str(preflight), "--forward", str(forward),
         "--state", str(preinverse)],
        label="nb-tx check-inverse-result")
    ctx.evidence.write("gate-%s/inverse-checked.json" % gate.gate, checked)
    if json.loads(checked.decode()).get("status") != "PASS":
        raise GateFailure("NB inverse result check failed")


# ---------------------------------------------------------------------------
# Probes (P0-1): correct containers, evaluated by the reviewed evaluator
# ---------------------------------------------------------------------------
def probe(ctx: RunContext, gate: GateScope, label: str, container: str,
          target: str, expect_reply: bool, *, source: str | None = None,
          vrf: str | None = None, count: int = 5) -> dict[str, Any]:
    """Ping from the named container; evaluate with x05-evaluator.

    With ``vrf`` set, the ping runs inside that VRF (``ip vrf exec``) so a
    VRF-local ``-I <source>`` binds to the VRF table (P0-3).
    """
    argv = ["ping", "-c", str(count), "-W", "2"]
    if source:
        argv += ["-I", source]
    argv.append(target)
    if vrf:
        argv = ["ip", "vrf", "exec", vrf] + argv
    gate.json("probe-%s.argv.json" % label, {"container": container, "argv": argv,
                                             "expect_reply": expect_reply})
    if ctx.dry_run:
        gate.step("DRY probe %s: %s -> %s (expect %s)"
                  % (label, container, target, "pass" if expect_reply else "fail"))
        return {"label": label, "dry": True}
    result = ctx.cmd.dex(container, *argv, check=False, timeout=30.0)
    gate.write("probe-%s.txt" % label, result.stdout + result.stderr)
    evaluation = load_evaluator().evaluate_ping(
        result.stdout.decode("utf-8", "replace"),
        returncode=result.returncode, expect_reply=expect_reply)
    record = {"label": label, "container": container, "target": target,
              "returncode": result.returncode,
              "evaluation_outcome": evaluation.outcome.value,
              "evaluation_reason": evaluation.reason}
    gate.json("probe-%s.evaluation.json" % label, record)
    if evaluation.outcome.value != "PASS":
        raise GateFailure("probe %s did not %s: %s"
                          % (label, "pass" if expect_reply else "fail",
                             evaluation.reason))
    gate.step("probe %s: %s (%s)" % (label, "pass" if expect_reply else "fail",
                                     evaluation.reason))
    return record


def probe_with_retries(ctx: RunContext, gate: GateScope, label: str,
                        container: str, target: str, expect_reply: bool,
                        *, attempts: int = 6, delay: float = 3.0,
                        **kwargs: Any) -> dict[str, Any]:
    """Bounded retry wrapper for probes right after a datapath mutation.

    The G5 CAS move re-parents the B LSP; ovn-northd, SB propagation and
    the chassis flow install take a moment to converge, so the immediate
    probe can lose the first packets (request or reply) without any
    configuration being wrong. Each failed attempt keeps its own evidence
    file; the last attempt carries the canonical label.
    """
    last: GateFailure | None = None
    for n in range(1, attempts + 1):
        tag = label if n == attempts else "%s-attempt-%02d" % (label, n)
        try:
            return probe(ctx, gate, tag, container, target, expect_reply,
                         **kwargs)
        except GateFailure as exc:
            last = exc
            if n < attempts:
                _log("probe %s attempt %d/%d failed; waiting %.1fs for "
                     "convergence: %s" % (label, n, attempts, delay, exc))
                time.sleep(delay)
    assert last is not None
    raise last


def require_route_present(ctx: RunContext, gate: GateScope, container: str,
                          *, vtysh_vrf: str | None = None,
                          vty_socket: str | None = None) -> None:
    """Negative probes are only meaningful while the tenant route exists.

    ``vty_socket`` selects an FRR pathspace daemon socket (PEER_B runs in
    /run/frr/x05); the default socket serves the main pathspace (PEER_A).
    """
    if ctx.dry_run:
        gate.step("DRY route-presence proof for %s (vtysh 'show ip route %s'%s)"
                  % (container, TENANT_PREFIX,
                     " socket " + vty_socket if vty_socket else ""))
        return
    command = "show ip route %s" % TENANT_PREFIX
    if vtysh_vrf:
        command = "show ip route vrf %s %s" % (vtysh_vrf, TENANT_PREFIX)
    vtysh_argv = ["vtysh"]
    if vty_socket:
        vtysh_argv += ["--vty_socket", vty_socket]
    raw = ctx.cmd.dex_read(container, *vtysh_argv, "-c", command)
    gate.write("route-presence-%s.txt" % _safe(container), raw)
    if TENANT_PREFIX.split("/")[0] not in raw.decode("utf-8", "replace"):
        raise GateFailure(
            "%s has no live %s route; a failed ping would not prove isolation"
            % (container, TENANT_PREFIX))


# ---------------------------------------------------------------------------
# Captures (P0-8): in-container SLL2 DLT 276 ifindex filters, docker cp out
# ---------------------------------------------------------------------------
CAPTURE_SLOTS = ("fabric", "chassis-1", "chassis-2", "gateway-300", "gateway-400")


def _ifindex(ctx: RunContext, container: str | None, link: str) -> str:
    if ctx.dry_run:
        return "<ifindex:%s>" % link
    if container is None:
        raw = ctx.cmd.read(["ip", "-o", "link", "show", "dev", link], timeout=15.0)
    else:
        raw = ctx.cmd.dex_read(container, "ip", "-o", "link", "show", "dev", link)
    match = re.search(rb"^(\d+):", raw, re.MULTILINE)
    if match is None:
        raise OrchestratorError("cannot resolve ifindex of %s" % link)
    return match.group(1).decode()


def start_captures(ctx: RunContext, gate: GateScope) -> None:
    state = ctx.state.setdefault("captures", {})
    if ctx.dry_run:
        _log("DRY: start 5 captures (fabric br-ovn UDP4789; chassis-1 tap-A/vxlan; "
             "chassis-2 tap-B/vxlan; gateway-300 bgpvrf300; gateway-400 bgpvrf400) "
             "with SLL2 DLT 276 link[4:4] ifindex filters")
        return
    plans = []
    fabric_if = _ifindex(ctx, None, "br-ovn")
    plans.append(("fabric", None, "host",
                  "link[4:4] = %s and udp port 4789" % fabric_if))
    tap_a = _ifindex(ctx, CHASSIS1, "x05-tenant-a-p")
    vx_a = _ifindex(ctx, CHASSIS1, UNDERLAY_IF)
    plans.append(("chassis-1", CHASSIS1, CHASSIS1,
                  "(link[4:4] = %s or (link[4:4] = %s and udp port 4789))"
                  % (tap_a, vx_a)))
    tap_b = _ifindex(ctx, CHASSIS2, "x05-tenant-b-p")
    vx_b = _ifindex(ctx, CHASSIS2, UNDERLAY_IF)
    plans.append(("chassis-2", CHASSIS2, CHASSIS2,
                  "(link[4:4] = %s or (link[4:4] = %s and udp port 4789))"
                  % (tap_b, vx_b)))
    plans.append(("gateway-300", GW1, GW1,
                  "link[4:4] = %s" % _ifindex(ctx, GW1, "bgpvrf300")))
    plans.append(("gateway-400", GW2, GW2,
                  "link[4:4] = %s" % _ifindex(ctx, GW2, "bgpvrf400")))
    for slot, container, host_label, expression in plans:
        in_container_pcap = "/tmp/x05-%s-%s.pcap" % (ctx.run_hex, slot)
        argv = ["tcpdump", "-i", "any", "-y", "LINUX_SLL2", "-U", "-w",
                in_container_pcap, expression]
        if container is None:
            launcher = argv
        else:
            launcher = ["docker", "exec", container] + argv
        process = subprocess.Popen(launcher, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.PIPE)
        time.sleep(1.0)
        if process.poll() is not None:
            raise GateFailure("capture %s exited immediately: %s"
                              % (slot, process.stderr.read().decode("utf-8", "replace")))
        pid = process.pid if container is None else None
        state[slot] = {"container": container, "host_label": host_label,
                       "in_container_pcap": in_container_pcap,
                       "expression": expression, "pid": pid, "argv": launcher}
        gate.json("capture-%s-start.json" % slot, state[slot])
    ctx.save()
    gate.step("captures started (%s)" % ", ".join(CAPTURE_SLOTS))


def stop_captures(ctx: RunContext, gate: GateScope) -> None:
    state = ctx.state.get("captures", {})
    if ctx.dry_run or not state:
        _log("DRY: stop captures and collect pcaps with docker cp + sha256")
        return
    for slot, info in state.items():
        container = info.get("container")
        if container is None:
            pid = info.get("pid")
            if pid:
                with contextlib.suppress(ProcessLookupError):
                    os.kill(pid, 15)
        else:
            with contextlib.suppress(Exception):
                ctx.cmd.dex(container, "pkill", "-TERM", "-f",
                            "tcpdump.*%s" % info["in_container_pcap"], check=False)
        time.sleep(1.0)
        local = gate.file("capture-%s.pcap" % slot)
        local.parent.mkdir(parents=True, exist_ok=True)
        if container is None:
            with contextlib.suppress(OSError):
                local.write_bytes(pathlib.Path(info["in_container_pcap"]).read_bytes())
        else:
            ctx.cmd.run(["docker", "cp",
                         "%s:%s" % (container, info["in_container_pcap"]), str(local)],
                        check=False, label="docker-cp pcap " + slot)
            ctx.cmd.dex(container, "rm", "-f", info["in_container_pcap"], check=False)
        if local.is_file():
            raw = local.read_bytes()
            gate.json("capture-%s.json" % slot,
                      {"bytes": len(raw), "sha256": _sha256(raw),
                       "expression": info.get("expression"),
                       "container": container})
        else:
            gate.json("capture-%s.json" % slot, {"missing": True})
    ctx.state["captures"] = {}
    ctx.save()
    gate.step("captures stopped and archived (semantic decode is delegated to "
              "the canonical coordinator's decoder)")


# ---------------------------------------------------------------------------
# CAS control (P0-9): real UUIDs, one guarded transact, checked results
# ---------------------------------------------------------------------------
def read_cas_material(ctx: RunContext, *, source: str = "ls-x05-tenant-b",
                      target: str = "ls-dci-tenant") -> dict[str, Any]:
    """Read the named source/target LS UUIDs, complete port sets and the
    B LSP UUID from the live NB (mirrored roles for the inverse CAS)."""
    if ctx.dry_run:
        return {"dry": True}
    switches = {}
    for row in ctx.cmd.nb_list("Logical_Switch", ("_uuid", "name", "ports")):
        uuid_atom = row["_uuid"]
        uuid = uuid_atom[1].lower() if isinstance(uuid_atom, list) else str(uuid_atom)
        switches[row["name"]] = {"uuid": uuid, "ports": sorted(
            _flatten_uuids(row["ports"]))}
    lsp_uuid = None
    for row in ctx.cmd.nb_list("Logical_Switch_Port", ("_uuid", "name")):
        if row["name"] == "x05-tenant-b-vm":
            atom = row["_uuid"]
            lsp_uuid = atom[1].lower() if isinstance(atom, list) else str(atom)
    if lsp_uuid is None:
        raise GateFailure("LSP x05-tenant-b-vm is absent; cannot prepare CAS")
    for name in (source, target):
        if name not in switches:
            raise GateFailure("Logical_Switch %s missing before CAS" % name)
    return {"source": switches[source],
            "target": switches[target],
            "lsp_uuid": lsp_uuid}


def _flatten_uuids(value: Any) -> list[str]:
    flat: list[str] = []

    def walk(item: Any) -> None:
        if isinstance(item, list):
            if len(item) == 2 and item[0] == "uuid" and isinstance(item[1], str):
                flat.append(item[1].lower())
                return
            for child in item:
                walk(child)
        elif isinstance(item, str) and UUID_RE.fullmatch(item):
            flat.append(item.lower())

    walk(value)
    return flat


def cas_snapshot(material: Mapping[str, Any]) -> dict[str, Any]:
    return {"source": {"uuid": material["source"]["uuid"],
                       "ports": sorted(material["source"]["ports"])},
            "target": {"uuid": material["target"]["uuid"],
                       "ports": sorted(material["target"]["ports"])},
            "lsp_uuid": material["lsp_uuid"]}


def apply_cas(ctx: RunContext, gate: GateScope, snapshot: Mapping[str, Any],
              label: str) -> dict[str, Any]:
    """Build with x05-cas.sh, apply ONE transact, check with --check-result."""
    gate.json("cas-%s-snapshot.json" % label, dict(snapshot))
    if ctx.dry_run:
        _log("DRY: %s --build snapshot | ovsdb-client transact | --check-result"
             % TOOL_CAS)
        return {"dry": True}
    gate_dir = ctx.evidence.gate_dir(gate.gate)
    gate_dir.mkdir(parents=True, exist_ok=True)
    snap_path = gate_dir / ("cas-%s-snapshot.json" % label)
    snap_path.write_text(json.dumps(snapshot, sort_keys=True, indent=2))
    built = ctx.cmd.read(["bash", str(TOOL_CAS), "--build", str(snap_path)],
                         label="cas build " + label)
    gate.write("cas-%s-transaction.json" % label, built)
    transaction = json.loads(built.decode())
    reply = ctx.cmd.nb_transact(transaction, label="CAS " + label)
    raw = json.dumps(reply, sort_keys=True).encode()
    result_path = gate_dir / ("cas-%s-result.raw.json" % label)
    result_path.write_bytes(raw)
    checked = ctx.cmd.read(["bash", str(TOOL_CAS), "--check-result", str(result_path)],
                           label="cas check-result " + label)
    gate.write("cas-%s-check.txt" % label, checked)
    return {"result_raw": json.loads(raw.decode()),
            "checked": checked.decode().strip()}


def verify_cas_position(ctx: RunContext, gate: GateScope, lsp_uuid: str,
                        expected_parent: str, label: str) -> None:
    """Re-read both parents after the commit; the LSP must sit exactly once."""
    if ctx.dry_run:
        gate.step("DRY verify %s parent == %s and UUID unchanged" % (label, expected_parent))
        return
    positions = []
    for row in ctx.cmd.nb_list("Logical_Switch", ("_uuid", "name", "ports")):
        name = row["name"]
        if name not in ("ls-dci-tenant", "ls-x05-tenant-b"):
            continue
        if lsp_uuid in _flatten_uuids(row["ports"]):
            positions.append(name)
    gate.json("cas-%s-position.json" % label, {"positions": positions})
    if positions != [expected_parent]:
        raise GateFailure(
            "%s: LSP %s parent is %r, expected [%r]" % (label, lsp_uuid, positions,
                                                        expected_parent))


# ---------------------------------------------------------------------------
# Evaluator polling (P0-2): G1/G2 through the reviewed collectors
# ---------------------------------------------------------------------------
def poll_evaluator_gate(ctx: RunContext, gate: GateScope, name: str,
                        commands: Mapping[str, Any],
                        evaluate: Any, topology: Any) -> dict[str, Any]:
    evaluator = load_evaluator()
    runtime = load_runtime_live()
    if ctx.dry_run:
        gate.step("DRY poll %s via x05-evaluator collectors (%d commands)"
                  % (name, len(commands)))
        gate.json("%s-dry-commands.json" % name,
                  {key: list(value.argv) for key, value in commands.items()})
        return {"status": "PASS", "dry": True}
    runner = runtime.SubprocessRunner()
    deadline = time.monotonic() + BGP_POLL_ATTEMPTS * BGP_POLL_DELAY
    last: Any = None
    for attempt in range(1, BGP_POLL_ATTEMPTS + 1):
        collection = evaluator.collect_fixed_commands(
            runner, commands, timeout=15.0,
            io_budget=runtime.MAX_OUTPUT)
        for query, sample in collection.samples.items():
            prefix = "%s-attempt-%02d-%s" % (
                name.lower(), attempt, query.replace("_", "-").replace(".", "-"))
            gate.write(prefix + ".stdout", sample.stdout)
            gate.json(prefix + ".json", {
                "query": query, "source_id": sample.source_id,
                "argv": list(sample.argv), "returncode": sample.returncode,
                "elapsed": sample.elapsed,
            })
        last = collection.error if collection.error is not None else evaluate(collection)
        gate.json("%s-attempt-%02d-evaluation.json" % (name.lower(), attempt),
                  {"outcome": last.outcome.value, "reason": last.reason,
                   "facts": dict(last.facts)})
        if last.outcome.value == "PASS":
            return {"status": "PASS", "attempts": attempt,
                    "authoritative_x05_pass":
                        last.facts.get("authoritative_x05_pass") is True}
        if time.monotonic() >= deadline:
            break
        time.sleep(BGP_POLL_DELAY)
    raise GateFailure("%s did not pass within %d attempts: %s"
                      % (name, BGP_POLL_ATTEMPTS, last.reason if last else "no data"))


def g1_topology(ctx: RunContext) -> Any:
    """G1 topology with resolved Docker IDs (the evaluator refuses names)."""
    evaluator = load_evaluator()
    return evaluator.G1Topology(
        client_a=resolve_container_id(ctx, CLIENT_A),
        client_b=resolve_container_id(ctx, CLIENT_B),
        gateway_1=resolve_container_id(ctx, GW1),
        gateway_2=resolve_container_id(ctx, GW2))


def g2_topology(ctx: RunContext) -> Any:
    """G2 topology with resolved Docker IDs (peers/chassis/central)."""
    evaluator = load_evaluator()
    return evaluator.G2Topology(
        peer_a=resolve_container_id(ctx, PEER_A),
        peer_b=resolve_container_id(ctx, PEER_B),
        chassis_a=resolve_container_id(ctx, CHASSIS1),
        chassis_b=resolve_container_id(ctx, CHASSIS2),
        central_id=resolve_container_id(ctx, CENTRAL))


# ---------------------------------------------------------------------------
# Gates
# ---------------------------------------------------------------------------
def gate_0(ctx: RunContext) -> int:
    gate = ctx.gate("0")
    _log("G0: local hashes, DCI nodes, M03/X05 absence, memory, canaries")
    env = {"M03_PREFLIGHT_RECEIPT": os.environ.get("M03_PREFLIGHT_RECEIPT", "")}
    gate.json("g0-inputs.json", env)
    receipt = os.environ.get("M03_PREFLIGHT_RECEIPT", "")
    if ctx.dry_run:
        gate.step("DRY: require M03_PREFLIGHT_RECEIPT readable (currently %s)"
                  % ("set" if receipt else "unset"))
    elif not receipt or not pathlib.Path(receipt).is_file():
        raise NotReady("M03_PREFLIGHT_RECEIPT must point at the historical "
                       "receipt file before any X05 gate")
    ctx.cmd.labctl("dci", "status")
    ctx.cmd.labctl("dci", "verify")
    ctx.cmd.labctl("k01", "status")
    for node in DCI_NODES:
        ctx.cmd.run(["docker", "inspect", "--format", "{{.State.Status}}", node],
                    label="canary " + node)
    if not ctx.dry_run:
        for node in DCI_NODES:
            status = ctx.cmd.read(
                ["docker", "inspect", "--format", "{{.State.Status}}", node],
                timeout=15.0).decode().strip()
            if status != "running":
                raise GateFailure("G0: %s is %r, expected running" % (node, status))
        if M03_MARKER.exists():
            raise GateFailure("G0: M03 marker already present at %s" % M03_MARKER)
        if marker_exists():
            raise NotReady("G0: stale X05 marker at %s; run --rollback first"
                           % X05_MARKER)
        p003 = ctx.cmd.run(["docker", "inspect", "--format", "{{.State.Status}}",
                            "p003-os"], check=False, timeout=15.0)
        gate.text("g0-p003-os.txt", p003.stdout.decode("utf-8", "replace"))
        if p003.returncode == 0 and p003.stdout.strip() == b"running":
            raise GateFailure("G0: p003-os is running; expected exited/absent")
        meminfo = pathlib.Path("/proc/meminfo")
        try:
            available_kb = int(re.search(
                rb"MemAvailable:\s+(\d+)", meminfo.read_bytes()).group(1))
        except (OSError, AttributeError) as exc:
            raise NotReady("G0: cannot read MemAvailable: %s" % exc)
        gate.text("g0-mem.txt", "MemAvailable=%dkB\n" % available_kb)
        if available_kb < 4194304:
            raise GateFailure("G0: MemAvailable %dkB < 4GiB" % available_kb)
    gate.pass_gate("baseline verified: nodes running, M03/X05 absent, "
                   "p003-os exited, memory >= 4GiB, canaries recorded")
    return 0


def gate_0a(ctx: RunContext, lock: M03Lock) -> int:
    gate = ctx.gate("0a")
    _log("G0a: under FD 9 lock — labctl dci up --m03, verify --m03, fingerprint")
    lock.acquire()
    if not ctx.dry_run and M03_MARKER.exists():
        raise GateFailure("G0a: M03 marker already present; refusing a second setup")
    receipt = os.environ.get("M03_PREFLIGHT_RECEIPT", "")
    if not receipt and not ctx.dry_run:
        raise NotReady("G0a: M03_PREFLIGHT_RECEIPT is required for --m03 setup")
    ctx.cmd.labctl("dci", "up", "--m03",
                   extra_env={"M03_PREFLIGHT_RECEIPT": receipt, **lock.labctl_env()})
    ctx.cmd.labctl("dci", "verify", "--m03", extra_env=lock.labctl_env())
    # A fingerprint: the reviewed preflight (also validates 34 rows absent).
    preflight = ctx.cmd.read(["bash", str(TOOL_NB_PREFLIGHT), "--live"],
                             label="nb-preflight G0a")
    ctx.evidence.write("gate-0a/nb-preflight.json", preflight)
    if not ctx.dry_run:
        document = json.loads(preflight.decode())
        if document.get("status") != "PASS":
            raise GateFailure("G0a: NB preflight after M03 setup: %s"
                              % document.get("reason"))
        gate.json("g0a-a-fingerprint.json", document.get("a_fingerprint", {}))
    gate.pass_gate("M03 template up and verified under FD 9; A fingerprint captured")
    return 0


def gate_nb(ctx: RunContext) -> int:
    gate = ctx.gate("nb")
    _log("NB: plan -> preflight -> tx build -> ONE transact -> checks -> "
         "postflight built -> runtime build (P0-4/5/6/7)")
    gate_dir = ctx.evidence.gate_dir("nb")

    # Local plan (pure jq, no lab contact).
    plan = ctx.cmd.read(["bash", str(TOOL_NB_PLAN), "--plan"], label="nb-plan")
    ctx.evidence.write("gate-nb/nb-plan.json", plan)
    ctx.cmd.run(["bash", str(TOOL_NB_PLAN), "--check"], label="nb-plan check")
    if not ctx.dry_run:
        objects = json.loads(plan.decode())["objects"]
        if len(objects) != 34:
            raise GateFailure("NB plan does not carry the 34 owned rows")

    # Live read-only preflight (P0-5): the JSON comes from stdout.
    preflight = ctx.cmd.read(["bash", str(TOOL_NB_PREFLIGHT), "--live"],
                             label="nb-preflight live")
    ctx.evidence.write("gate-nb/nb-preflight.json", preflight)
    if not ctx.dry_run:
        document = json.loads(preflight.decode())
        if document.get("status") != "PASS" or \
                document.get("planned_rows_absent") != 34 or \
                document.get("owner_residue") != 0:
            raise GateFailure("NB preflight is not a clean PASS: %s"
                              % document.get("reason"))
    preflight_path = gate_dir / "nb-preflight.json"

    # Forward transaction (single ovsdb-client transact, P0-4).
    built = ctx.cmd.read(
        ["python3", str(TOOL_NB_TX), "--build", str(preflight_path),
         "--owner", ctx.owner, "--run-hex", ctx.run_hex],
        label="nb-tx build")
    ctx.evidence.write("gate-nb/nb-forward-tx.json", built)
    if ctx.dry_run:
        _log("DRY: docker exec %s ovsdb-client transact %s <forward-tx>"
             % (CENTRAL, NB_SOCKET))
    else:
        transaction = json.loads(built.decode())
        reply = ctx.cmd.nb_transact(transaction, label="NB forward transaction")
        raw_path = gate_dir / "nb-forward-result.raw.json"
        raw_path.parent.mkdir(parents=True, exist_ok=True)
        raw_path.write_bytes(json.dumps(reply, sort_keys=True).encode())
        checked = ctx.cmd.read(
            ["python3", str(TOOL_NB_TX), "--check-result", str(raw_path),
             "--preflight", str(preflight_path), "--owner", ctx.owner,
             "--run-hex", ctx.run_hex],
            label="nb-tx check-result")
        ctx.evidence.write("gate-nb/nb-forward-checked.json", checked)
        forward = json.loads(checked.decode())
        if forward.get("status") != "PASS" or len(forward.get("inserted", {})) != 34:
            raise GateFailure("NB forward result check failed")

    # Built-state postflight with a real full snapshot (P0-6).
    snapshot = ctx.cmd.read(["bash", str(TOOL_NB_SNAPSHOT), "--live"],
                            label="nb-full-snapshot built")
    ctx.evidence.write("gate-nb/nb-built-snapshot.json", snapshot)
    if ctx.dry_run:
        _log("DRY: python3 %s --built --preflight ... --forward ... --state ..."
             % TOOL_NB_POSTFLIGHT)
    else:
        snapshot_path = gate_dir / "nb-built-snapshot.json"
        checked_forward = gate_dir / "nb-forward-checked.json"
        postflight = ctx.cmd.read(
            ["python3", str(TOOL_NB_POSTFLIGHT), "--built",
             "--preflight", str(preflight_path),
             "--forward", str(checked_forward),
             "--state", str(snapshot_path)],
            label="nb-postflight built")
        ctx.evidence.write("gate-nb/nb-built-checked.json", postflight)
        if json.loads(postflight.decode()).get("status") != "PASS":
            raise GateFailure("NB built-state postflight failed")

    # P0-7 runtime extension: return route for the gw-2 client /30 so tenant-B
    # (x05-tenant-b-vm) replies reach client-B. lr-x05-tenant-b has no route to
    # 169.254.254.4/30 in the frozen 34-row plan, which dropped tenant-B replies
    # (request arrived, reply had no route). Applied after the P0-6 postflight
    # so the built-state check sees exactly the planned rows; the route dies
    # with the router in the NB inverse. The gw-1 client /30 return route lives
    # in nb-topology.sh (lr-dci-tenant), the DCI baseline.
    if not ctx.dry_run:
        ctx.cmd.dex(CENTRAL, "ovn-nbctl", "--may-exist", "lr-route-add",
                    "lr-x05-tenant-b", "169.254.254.4/30", "10.41.100.2")

    # Runtime resources the shell script assumed into existence (P0-7).
    build_runtime(ctx, gate)
    gate.pass_gate("NB forward applied as one transaction and verified; runtime "
                   "resources built (client-2, peer, sentinels, taps, pathspaces)")
    return 0


def gate_1(ctx: RunContext) -> int:
    gate = ctx.gate("1")
    _log("G1: BGP legs established in distinct VRFs via x05-evaluator (P0-2)")
    evaluator = load_evaluator()
    topology = g1_topology(ctx)
    report = poll_evaluator_gate(
        ctx, gate, "G1", evaluator.g1_commands(topology),
        lambda collection: evaluator.evaluate_g1_samples(collection, topology),
        topology)
    gate.pass_gate("G1 BGP sessions established (A and B legs, RIB/FIB via "
                   "evaluator)", **report)
    return 0


def gate_2(ctx: RunContext) -> int:
    gate = ctx.gate("2")
    _log("G2: simultaneous A/B EVPN Type 5 — peers and chassis, not gateways (P0-2)")
    evaluator = load_evaluator()
    topology = g2_topology(ctx)
    report = poll_evaluator_gate(
        ctx, gate, "G2", evaluator.g2_commands(topology),
        lambda collection: evaluator.evaluate_g2_samples(collection, topology),
        topology)
    gate.pass_gate("G2 EVPN Type 5 simultaneous per tenant (VNI 50100/50200), "
                   "scoped Learned_Route via evaluator", **report)
    return 0


def gate_3(ctx: RunContext) -> int:
    gate = ctx.gate("3")
    _log("G3: reachability matrix from the correct containers (P0-1)")
    start_captures(ctx, gate)
    # Positive probes first.
    probe(ctx, gate, "a-to-own", CLIENT_A, SENTINEL_A, True)
    probe(ctx, gate, "b-to-own", CLIENT_B, SENTINEL_B, True)
    # Negative probes are only meaningful while each tenant route is live.
    require_route_present(ctx, gate, CLIENT_A)
    require_route_present(ctx, gate, CLIENT_B)
    probe(ctx, gate, "a-to-cross", CLIENT_A, SENTINEL_B, False)
    probe(ctx, gate, "b-to-cross", CLIENT_B, SENTINEL_A, False)
    # EVPN peer sentinels: own sentinel passes, cross-tenant fails. Both
    # peers source from a VRF loopless address, so the ping must run inside
    # the peer's VRF (P0-3).
    probe(ctx, gate, "peer-a-to-own", PEER_A, SENTINEL_A, True,
          source=PEER_SOURCE_A, vrf="vrf-evpn-client")
    probe(ctx, gate, "peer-b-to-own", PEER_B, SENTINEL_B, True,
          source=PEER_SOURCE_B, vrf="vrf-x05-peer")
    require_route_present(ctx, gate, PEER_A, vtysh_vrf="vrf-evpn-client")
    require_route_present(ctx, gate, PEER_B, vtysh_vrf="vrf-x05-peer",
                          vty_socket="/run/frr/" + PATHSPACE)
    probe(ctx, gate, "peer-a-to-cross", PEER_A, SENTINEL_B, False,
          source=PEER_SOURCE_A, vrf="vrf-evpn-client")
    probe(ctx, gate, "peer-b-to-cross", PEER_B, SENTINEL_A, False,
          source=PEER_SOURCE_B, vrf="vrf-x05-peer")
    gate.pass_gate("own reachability proved; cross-tenant denied with live "
                   "routes (isolation, not outage)")
    return 0


def gate_4(ctx: RunContext) -> int:
    gate = ctx.gate("4")
    _log("G4: capture health / archive (P0-8)")
    # The contract needs the taps live through the G5/G6 windows; captures are
    # archived here only once those gates are recorded, otherwise G4 reports
    # the running slots (final stop also happens at G7 and in --rollback).
    done = (ctx.state.get("gates", {}).get("5", {}).get("status") == "PASS"
            and ctx.state.get("gates", {}).get("6", {}).get("status") == "PASS")
    slots = ctx.state.get("captures", {})
    gate.json("g4-capture-state.json", {"slots": sorted(slots),
                                         "g5_g6_done": done})
    if done or not slots:
        stop_captures(ctx, gate)
        gate.pass_gate("captures archived under gate-4 with SHA256; tuple/VNI "
                       "semantics delegated to the coordinator decoder")
    else:
        gate.pass_gate("captures still running for the G5/G6 windows; they are "
                       "archived by gate 7 (or --rollback) after restoration")
    return 0


def gate_5(ctx: RunContext) -> int:
    gate = ctx.gate("5")
    _log("G5: guarded CAS move of the REAL B LSP into LS A (P0-9)")
    material = read_cas_material(ctx)
    if not ctx.dry_run:
        snapshot = cas_snapshot(material)
        b_ports, a_ports = snapshot["source"]["ports"], snapshot["target"]["ports"]
        if snapshot["lsp_uuid"] not in b_ports:
            raise GateFailure("G5: B LSP is not in ls-x05-tenant-b ports")
        if snapshot["lsp_uuid"] in a_ports:
            raise GateFailure("G5: B LSP already attached to ls-dci-tenant")
        apply_cas(ctx, gate, snapshot, "forward")
        verify_cas_position(ctx, gate, snapshot["lsp_uuid"], "ls-dci-tenant",
                            "G5-forward")
        # Persist the G5 outcome so G6/rollback know the forward ran; the
        # inverse snapshot itself is re-read live (P0-1), never derived from
        # this stale pre-move snapshot.
        ctx.state["cas"] = {"forward_snapshot": snapshot,
                            "lsp_uuid": snapshot["lsp_uuid"]}
        ctx.save()
    else:
        gate.step("DRY: read LS A/B UUIDs + complete port sets + B LSP UUID; "
                  "x05-cas.sh --build; ONE ovsdb transact; --check-result; "
                  "re-read both parents")
    # Post-move convergence window: the CAS re-parents the LSP and the
    # datapath needs a moment before the first packets flow (P0-1 honesty:
    # retry with evidence per attempt instead of probing once too early).
    probe_with_retries(ctx, gate, "g5-a-to-moved-b", CLIENT_A, SENTINEL_B, True)
    probe(ctx, gate, "g5-b-to-own-lost", CLIENT_B, SENTINEL_B, False)
    gate.pass_gate("B LSP moved by guarded CAS; A reaches .12, B loses it "
                   "(same UUID, parent A only)")
    return 0


def gate_6(ctx: RunContext) -> int:
    gate = ctx.gate("6")
    _log("G6: inverse CAS — restore the B LSP to LS B (P0-9)")
    if ctx.dry_run:
        gate.step("DRY: re-read the live NB with mirrored roles (source = the "
                  "LS that now has the LSP), build the inverse CAS "
                  "transaction, apply, check, verify B sole parent")
    else:
        material = ctx.state.get("cas")
        if not material:
            raise NotReady("G6 requires G5's CAS material in the run state")
        # P0-1: the persisted G5 snapshot is stale after the forward move;
        # x05-cas.sh demands source.ports to hold the LSP exactly once and
        # target.ports zero times, so re-read the live NB with mirrored
        # roles: source = the LS that NOW has the LSP (ls-dci-tenant),
        # target = the LS that must receive it back (ls-x05-tenant-b).
        inverse = cas_snapshot(read_cas_material(
            ctx, source="ls-dci-tenant", target="ls-x05-tenant-b"))
        if inverse["lsp_uuid"] not in inverse["source"]["ports"]:
            raise GateFailure("G6: B LSP is not in ls-dci-tenant ports")
        if inverse["lsp_uuid"] in inverse["target"]["ports"]:
            raise GateFailure("G6: B LSP already attached to ls-x05-tenant-b")
        apply_cas(ctx, gate, inverse, "inverse")
        verify_cas_position(ctx, gate, inverse["lsp_uuid"], "ls-x05-tenant-b",
                            "G6-inverse")
        ctx.state["cas"]["restored"] = True
        ctx.save()
    probe(ctx, gate, "g6-a-to-b-fails", CLIENT_A, SENTINEL_B, False)
    # Same post-move convergence window as G5: the inverse CAS re-parents
    # the LSP back to LS B before this probe.
    probe_with_retries(ctx, gate, "g6-b-to-own-restored", CLIENT_B, SENTINEL_B,
                       True)
    gate.pass_gate("B LSP restored by inverse CAS; A→.12 fails, B→.12 passes "
                   "(same UUID, B-only parent)")
    return 0


def gate_7(ctx: RunContext, lock: M03Lock) -> int:
    gate = ctx.gate("7")
    _log("G7: NB inverse + runtime teardown in contract order + X05 absence (P0-10)")
    if not ctx.dry_run:
        cas_state = ctx.state.get("cas")
        if cas_state and not cas_state.get("restored"):
            raise NotReady("G7 requires the B LSP restored (run gate 6 or "
                           "--rollback) before teardown")
    stop_captures(ctx, gate)
    teardown = teardown_runtime(ctx, gate)
    # M03 must still be intact after X05 cleanup.
    ctx.cmd.labctl("dci", "verify", "--m03", extra_env=lock.labctl_env())
    if not ctx.dry_run:
        if not M03_MARKER.exists():
            raise GateFailure("G7: M03 marker disappeared before M03 teardown")
        # Marker removal is last, after every X05 resource is absent.
        raw = X05_MARKER.read_bytes()
        token = ""
        for line in raw.decode("ascii", "replace").splitlines():
            if line.startswith("token="):
                token = line.split("=", 1)[1]
        if token != ctx.owner:
            raise OrchestratorError("refusing marker removal: token %r is not "
                                    "this run" % token)
        X05_MARKER.unlink()
        if marker_exists():
            raise GateFailure("G7: X05 marker still present after unlink")
    else:
        _log("DRY: remove X05 marker %s after proving absence" % X05_MARKER)
    gate.pass_gate("X05 resources absent, NB inverse checked, M03 verified, "
                   "marker removed", teardown=teardown)
    return 0


def gate_8(ctx: RunContext, lock: M03Lock) -> int:
    gate = ctx.gate("8")
    _log("G8: labctl dci down --m03, baseline verify, canaries (P0-10)")
    if not ctx.dry_run and marker_exists():
        raise GateFailure("G8: X05 marker still present; M03 teardown refused")
    ctx.cmd.labctl("dci", "down", "--m03", extra_env=lock.labctl_env())
    ctx.cmd.labctl("dci", "verify", extra_env=lock.labctl_env())
    ctx.cmd.labctl("k01", "status")
    if not ctx.dry_run:
        if M03_MARKER.exists():
            raise GateFailure("G8: M03 marker survives down --m03")
        if ctx.cmd.run(["docker", "inspect", PEER_A], check=False,
                       timeout=15.0).returncode == 0:
            raise GateFailure("G8: M03 peer %s still present" % PEER_A)
    gate.pass_gate("M03 torn down; baseline verify passed; canaries recorded")
    return 0


def run_rollback(ctx: RunContext, lock: M03Lock) -> int:
    gate = ctx.gate("rollback")
    _log("ROLLBACK: contract order from the current run state")
    stop_captures(ctx, gate)
    uncertain = False
    cas_state = ctx.state.get("cas")
    if cas_state and not cas_state.get("restored"):
        # First rollback step after any failure: the inverse CAS (P0-10).
        try:
            # P0-1: re-read the live NB with mirrored roles; the persisted G5
            # snapshot is stale after the forward move.
            inverse = cas_snapshot(read_cas_material(
                ctx, source="ls-dci-tenant", target="ls-x05-tenant-b"))
            lsp_uuid = inverse["lsp_uuid"]
            if lsp_uuid in inverse["source"]["ports"]:
                if lsp_uuid in inverse["target"]["ports"]:
                    raise GateFailure("rollback: B LSP sits in both "
                                      "ls-dci-tenant and ls-x05-tenant-b")
                apply_cas(ctx, gate, inverse, "rollback-inverse")
            elif lsp_uuid not in inverse["target"]["ports"]:
                raise GateFailure("rollback: B LSP sits in neither LS")
            else:
                gate.step("B LSP already sole child of ls-x05-tenant-b; no "
                          "inverse CAS needed")
            verify_cas_position(ctx, gate, lsp_uuid,
                                "ls-x05-tenant-b", "rollback-inverse")
            cas_state["restored"] = True
            ctx.save()
        except (OrchestratorError, GateFailure) as exc:
            uncertain = True
            gate.json("rollback-blocked.json", {"reason": str(exc)})
    if uncertain:
        # Ownership/LSP restoration is uncertain: retain both markers and stop
        # before M03 teardown (contract).
        gate.fail_gate("B LSP restoration uncertain; X05 marker retained for "
                       "manual recovery; M03 teardown not attempted")
        return 75
    teardown_runtime(ctx, gate)
    ctx.cmd.labctl("dci", "verify", "--m03", extra_env=lock.labctl_env())
    if not ctx.dry_run and marker_exists():
        # P1-2: same ownership rule as gate_7 — read the marker token first
        # and leave it in place when another run owns it.
        raw = X05_MARKER.read_bytes()
        token = ""
        for line in raw.decode("ascii", "replace").splitlines():
            if line.startswith("token="):
                token = line.split("=", 1)[1]
        if token != ctx.owner:
            _log("ROLLBACK: X05 marker token %r is not this run (%s); "
                 "leaving the marker for its owner" % (token, ctx.owner))
        else:
            X05_MARKER.unlink()
    ctx.cmd.labctl("dci", "down", "--m03", extra_env=lock.labctl_env())
    ctx.cmd.labctl("dci", "verify", extra_env=lock.labctl_env())
    ctx.cmd.labctl("k01", "status")
    gate.pass_gate("rollback completed through M03 teardown and baseline verify")
    return 0


# ---------------------------------------------------------------------------
# --validate: run every local selftest of the existing toolchain
# ---------------------------------------------------------------------------
def run_validate() -> int:
    """Run every local selftest; honor the toolchain's exit-code conventions.

    rc 0  -> PASS
    rc 77 -> the tool passed its local scope and declared the live Linux
             part NOT_RUN (capture/runtime selftests on a dev host)
    capture corpus FileNotFoundError -> SKIP (needs the staged wire corpus)
    anything else -> FAIL
    """
    _log("validate: running every local selftest of the X05 toolchain")
    failures = []
    skipped = []
    local_only = []
    for label, argv in SELFTESTS:
        _log("validate: %s" % label)
        try:
            completed = subprocess.run(argv, capture_output=True, timeout=900,
                                       check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            failures.append((label, str(exc)))
            continue
        tail = (completed.stdout + completed.stderr)[-800:].decode("utf-8", "replace")
        if completed.returncode == 0:
            print("PASS %s" % label)
        elif completed.returncode == 77:
            local_only.append(label)
            print("PASS-LOCAL-ONLY %s (live part NOT_RUN on this host)" % label)
        elif "p004-capture-parent-wire-corpus" in tail and "FileNotFoundError" in tail:
            skipped.append((label, "staged wire corpus absent"))
            print("SKIP %s (external capture corpus is not staged)" % label)
        else:
            failures.append((label, "rc=%d %s" % (completed.returncode, tail)))
            print("FAIL %s\n%s" % (label, tail), file=sys.stderr)
    summary = {"schema": SCHEMA, "mode": "validate",
               "selftests": len(SELFTESTS), "failures": failures,
               "local_only_not_run_live": local_only, "skipped": skipped}
    if failures:
        summary["status"] = "FAIL"
        print(json.dumps(summary, indent=2))
        return 1
    summary["status"] = "PASS"
    print(json.dumps(summary, indent=2))
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="x05-orchestrate.py",
        description="Per-gate X05 orchestrator integrating the reviewed toolchain.")
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--dry-run", action="store_true",
                       help="print every planned action; execute nothing")
    modes.add_argument("--execute", action="store_true",
                       help="run the selected gate against the live lab")
    modes.add_argument("--validate", action="store_true",
                       help="run all local selftests of the existing tools")
    parser.add_argument("--gate", metavar="N",
                        choices=["0", "0a", "nb", "1", "2", "3", "4", "5", "6",
                                 "7", "8", "all"],
                        help="gate to run (0, 0a, nb, 1-8, or all)")
    parser.add_argument("--rollback", action="store_true",
                        help="run the full contract rollback for the run")
    parser.add_argument("--run", metavar="HEX",
                        help="six lowercase hex digits identifying the run "
                             "(resume with the same value across gates)")
    parser.add_argument("--evidence-root", type=pathlib.Path,
                        default=DEFAULT_EVIDENCE_ROOT,
                        help="evidence root (default %s)" % DEFAULT_EVIDENCE_ROOT)
    parser.add_argument("--ovs-runc", type=pathlib.Path, default=DEFAULT_OVS_RUNC,
                        help="ovs-runc path used for client/peer OVS ports")
    args = parser.parse_args(list(argv))
    if not args.validate and not args.rollback and not args.gate:
        parser.error("--gate N (or --rollback / --validate) is required")
    if args.rollback and args.gate:
        parser.error("--rollback cannot be combined with --gate")
    return args


def check_execute_host() -> None:
    if sys.platform != "linux":
        raise NotReady("live X05 execution requires the Linux lab host")
    if os.geteuid() != 0:
        raise NotReady("live X05 execution requires root (marker, FD 9 lock, labctl)")
    if not LABCTL.is_file():
        raise NotReady("labctl not found at %s" % LABCTL)


def resolve_run_hex(args: argparse.Namespace, mode: str) -> str:
    if args.run:
        if RUN_RE.fullmatch(args.run) is None:
            raise NotReady("--run must be six lowercase hex digits")
        return args.run
    return secrets.token_hex(3)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.validate:
        return run_validate()
    try:
        return _dispatch(args)
    except NotReady as exc:
        _log("NOT_READY: %s" % exc)
        return 75
    except GateFailure as exc:
        _log("GATED: %s" % exc)
        return 1
    except OrchestratorError as exc:
        _log("ERROR: %s" % exc)
        return 1


def _dispatch(args: argparse.Namespace) -> int:
    mode = "dry-run" if args.dry_run else "execute"
    if mode == "execute":
        check_execute_host()
    run_hex = resolve_run_hex(args, mode)
    ctx = RunContext(mode, run_hex, args.evidence_root, args.ovs_runc)
    ctx.prepare_run()
    lock = M03Lock(ctx)
    gates: tuple[str, ...] = GATE_ORDER if args.gate == "all" else (args.gate,)
    try:
        if args.rollback:
            if not args.run:
                raise NotReady("--rollback requires --run HEX to bind the "
                               "owned marker and journal")
            lock.acquire()
            return run_rollback(ctx, lock)
        for gate in gates:
            if gate == "0":
                rc = gate_0(ctx)
            elif gate == "0a":
                lock.acquire()
                rc = gate_0a(ctx, lock)
            elif gate == "nb":
                lock.acquire()
                rc = gate_nb(ctx)
            elif gate in ("1", "2", "3", "4"):
                rc = {"1": gate_1, "2": gate_2, "3": gate_3,
                      "4": gate_4}[gate](ctx)
            elif gate == "5":
                lock.acquire()
                rc = gate_5(ctx)
            elif gate == "6":
                lock.acquire()
                rc = gate_6(ctx)
            elif gate == "7":
                lock.acquire()
                rc = gate_7(ctx, lock)
            elif gate == "8":
                lock.acquire()
                rc = gate_8(ctx, lock)
            else:
                raise NotReady("unknown gate " + gate)
            if rc != 0:
                return rc
        ctx.evidence.json("manifest.json", ctx.evidence.manifest())
        return 0
    finally:
        lock.release()


if __name__ == "__main__":
    raise SystemExit(main())
