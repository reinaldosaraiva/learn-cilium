#!/usr/bin/env python3
"""Pure X05 G1/G2 evaluators and bounded read-only collectors.

The module deliberately contains no lab mutation or NB transaction executor.
Its collectors accept the byte-oriented ``Runner`` boundary used by
``x05-runtime-live.py`` and issue only fixed read commands against container
IDs captured during admission.  The command-line live path remains disabled;
the future coordinator must compose these APIs under the existing lock and
journal.
"""

from __future__ import annotations

import argparse
import dataclasses
import enum
import importlib.util
import ipaddress
import json
import math
import pathlib
import re
import sys
import time
from collections.abc import Callable, Mapping, Sequence
from typing import Any


sys.dont_write_bytecode = True


HERE = pathlib.Path(__file__).resolve().parent
RUNTIME_PATH = HERE / "x05-runtime-live.py"


def _load_runtime_contract() -> Any:
    """Load the reviewed shared runner boundary without loading test helpers."""

    module_name = "x05_runtime_live_evaluator_contract"
    existing = sys.modules.get(module_name)
    if existing is not None:
        return existing
    spec = importlib.util.spec_from_file_location(module_name, RUNTIME_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load the shared X05 runtime runner contract")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


RUNTIME = _load_runtime_contract()
RuntimeRunner = RUNTIME.Runner
SHARED_MAX_OUTPUT = RUNTIME.MAX_OUTPUT


BASE_ENV = {
    "HOME": "/root",
    "LANG": "C",
    "LC_ALL": "C",
    "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
}
PREFIX = "192.168.100.0/24"
UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"
)
CONTAINER_ID_RE = re.compile(r"^[0-9a-f]{64}$")
MAC_RE = re.compile(r"^(?:[0-9a-f]{2}:){5}[0-9a-f]{2}$", re.IGNORECASE)
DOCUMENTED_ABSENCE_LINES = (
    re.compile(r"^%?\s*Network not in table(?:\s+.*)?$", re.IGNORECASE),
    re.compile(r"^%?\s*No matching route(?:\s+.*)?$", re.IGNORECASE),
    re.compile(r"^%?\s*Route not found(?:\s+.*)?$", re.IGNORECASE),
    re.compile(r"^%?\s*No EVPN prefixes found\s*$", re.IGNORECASE),
    re.compile(r"^%?\s*VNI\s+\d+\s+not found\s*$", re.IGNORECASE),
)
LINUX_ROUTE_TYPES = frozenset(
    {
        "blackhole",
        "unreachable",
        "prohibit",
        "throw",
        "local",
        "broadcast",
        "nat",
    }
)
BGP_CONVERGENCE_STATES = frozenset(
    {"Idle", "Connect", "Active", "OpenSent", "OpenConfirm"}
)
# Closed text emitted by the pinned FRR 8.4.1/10.7 detail renderers.
FRR_KNOWN_VIA_RE = re.compile(
    r'^Known via "(?P<protocol>[^"]+)", distance '
    r"(?P<distance>0|[1-9][0-9]{0,9}), metric "
    r"(?P<metric>0|[1-9][0-9]{0,9})"
    r"(?:, tag (?P<tag>[1-9][0-9]{0,9})(?P<realm>\(realm\))?)?"
    r"(?:, mtu (?P<mtu>[1-9][0-9]{0,9}))?"
    r"(?:, vrf (?P<vrf>[^,\s]+))?, best$"
)
FRR_BGP_SELECTION_REASONS = frozenset(
    {
        "Nothing to Select",
        "First path received",
        "EVPN Sticky Mac",
        "EVPN sequence number",
        "EVPN lower IP",
        "EVPN local ES path",
        "EVPN non proxy",
        "Admin Distance",
        "Weight",
        "Local Pref",
        "Accept Own",
        "Local Route",
        "AIGP",
        "Confederation based AS Path",
        "AS Path",
        "Origin",
        "MED",
        "Peer Type",
        "Confed Peer Type",
        "IGP Metric",
        "Older Path",
        "Router ID",
        "Cluster length",
        "Path Staleness",
        "Locally configured route",
        "Neighbor IP",
        "Nothing left to compare",
    }
)


class Outcome(enum.StrEnum):
    """Frozen result vocabulary for every X05 proof predicate."""

    PASS = "PASS"
    RETRY = "RETRY"
    FAIL = "FAIL"
    ERROR = "ERROR"


class ProofKind(enum.StrEnum):
    """How far a PASS may be carried by its consumer."""

    PREDICATE = "PREDICATE"
    FIXTURE_COLLECTION = "FIXTURE_COLLECTION"
    CAPTURED_OBSERVATION = "CAPTURED_OBSERVATION"
    AUTHORITATIVE_X05_GATE = "AUTHORITATIVE_X05_GATE"


@dataclasses.dataclass(frozen=True)
class Evaluation:
    outcome: Outcome
    reason: str
    facts: Mapping[str, Any] = dataclasses.field(default_factory=dict)
    proof_kind: ProofKind = ProofKind.PREDICATE

    def __post_init__(self) -> None:
        if not isinstance(self.outcome, Outcome):
            raise TypeError("outcome must be an Outcome member")
        if not isinstance(self.reason, str) or not self.reason.strip():
            raise TypeError("reason must be nonempty text")
        if not isinstance(self.facts, Mapping):
            raise TypeError("facts must be a mapping")
        if not isinstance(self.proof_kind, ProofKind):
            raise TypeError("proof_kind must be a ProofKind member")


def passed(reason: str, **facts: Any) -> Evaluation:
    return Evaluation(Outcome.PASS, reason, facts)


def retry(reason: str, **facts: Any) -> Evaluation:
    return Evaluation(Outcome.RETRY, reason, facts)


def failed(reason: str, **facts: Any) -> Evaluation:
    return Evaluation(Outcome.FAIL, reason, facts)


def errored(reason: str, **facts: Any) -> Evaluation:
    return Evaluation(Outcome.ERROR, reason, facts)


def combine_results(
    results: Mapping[str, Evaluation],
    *,
    proof_kind: ProofKind = ProofKind.PREDICATE,
) -> Evaluation:
    """Require every named predicate, preserving terminal error semantics."""

    if not isinstance(proof_kind, ProofKind):
        raise TypeError("proof_kind must be a ProofKind member")
    if not results:
        return Evaluation(
            Outcome.ERROR,
            "decision table has no predicates",
            {"authoritative_x05_pass": False},
            proof_kind,
        )
    invalid = sorted(
        name for name, result in results.items() if not isinstance(result, Evaluation)
    )
    if invalid:
        return Evaluation(
            Outcome.ERROR,
            "decision table contains invalid result objects",
            {"invalid": invalid, "authoritative_x05_pass": False},
            proof_kind,
        )
    for outcome in (Outcome.ERROR, Outcome.FAIL, Outcome.RETRY):
        selected = {
            name: result.reason
            for name, result in results.items()
            if result.outcome is outcome
        }
        if selected:
            return Evaluation(
                outcome,
                f"{outcome.value} predicates: " + ", ".join(sorted(selected)),
                {
                    "predicates": selected,
                    "authoritative_x05_pass": False,
                },
                proof_kind,
            )
    if any(result.outcome is not Outcome.PASS for result in results.values()):
        return errored("decision table contains an unknown outcome")
    if proof_kind is ProofKind.FIXTURE_COLLECTION:
        reason = "fixture predicates passed; this is not an authoritative X05 gate"
    elif proof_kind is ProofKind.CAPTURED_OBSERVATION:
        reason = "captured predicates passed; coordinator ratification is still required"
    elif proof_kind is ProofKind.AUTHORITATIVE_X05_GATE:
        reason = "authoritative X05 gate predicates passed"
    else:
        reason = "every required proof predicate passed"
    return Evaluation(
        Outcome.PASS,
        reason,
        {
            "predicates": sorted(results),
            "authoritative_x05_pass": proof_kind
            is ProofKind.AUTHORITATIVE_X05_GATE,
        },
        proof_kind,
    )


class ParseError(ValueError):
    """An observation is malformed and cannot be evidence of absence."""


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ParseError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _reject_constant(value: str) -> Any:
    raise ParseError(f"non-finite JSON number: {value}")


def parse_json(raw: bytes | str, *, context: str) -> Any:
    """Decode strict UTF-8 JSON with duplicate/non-finite rejection."""

    if isinstance(raw, bytes):
        try:
            text = raw.decode("utf-8", "strict")
        except UnicodeDecodeError as exc:
            raise ParseError(f"{context}: output is not UTF-8") from exc
    elif isinstance(raw, str):
        text = raw
    else:
        raise ParseError(f"{context}: JSON input must be bytes or text")
    try:
        return json.loads(
            text,
            object_pairs_hook=_unique_object,
            parse_constant=_reject_constant,
        )
    except ParseError:
        raise
    except (json.JSONDecodeError, TypeError, ValueError) as exc:
        raise ParseError(f"{context}: invalid JSON: {exc}") from exc


def _exact_keys(value: Mapping[str, Any], expected: frozenset[str], context: str) -> None:
    actual = frozenset(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise ParseError(f"{context}: key set mismatch missing={missing} extra={extra}")


def _integer(value: Any, context: str, *, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ParseError(f"{context}: expected an integer, not {type(value).__name__}")
    if value < minimum:
        raise ParseError(f"{context}: integer is below {minimum}")
    return value


def _string(value: Any, context: str) -> str:
    if not isinstance(value, str) or not value:
        raise ParseError(f"{context}: expected nonempty text")
    return value


def _ip(value: Any, context: str) -> str:
    text = _string(value, context)
    try:
        parsed = ipaddress.ip_address(text)
    except ValueError as exc:
        raise ParseError(f"{context}: invalid IP address") from exc
    if parsed.version != 4:
        raise ParseError(f"{context}: expected IPv4")
    return text


FRR_SUMMARY_KEYS = frozenset(
    {
        "routerId",
        "as",
        "vrfId",
        "vrfName",
        "tableVersion",
        "ribCount",
        "ribMemory",
        "peerCount",
        "peerMemory",
        "peers",
        "failedPeers",
        "displayedPeers",
        "totalPeers",
        "dynamicPeers",
        "bestPath",
    }
)
FRR_CLIENT_PEER_KEYS = frozenset(
    {
        "hostname",
        "remoteAs",
        "localAs",
        "version",
        "msgRcvd",
        "msgSent",
        "tableVersion",
        "outq",
        "inq",
        "peerUptime",
        "peerUptimeMsec",
        "peerUptimeEstablishedEpoch",
        "pfxRcd",
        "pfxSnt",
        "state",
        "peerState",
        "connectionsEstablished",
        "connectionsDropped",
        "idType",
    }
)
FRR_GATEWAY_PEER_KEYS = FRR_CLIENT_PEER_KEYS | {"softwareVersion"}


@dataclasses.dataclass(frozen=True)
class BGPSummaryExpectation:
    label: str
    local_as: int
    vrf_name: str
    peers: Mapping[str, int]
    peer_kind: str

    def __post_init__(self) -> None:
        _integer(self.local_as, f"{self.label}.local_as", minimum=1)
        if self.peer_kind not in {"client", "gateway"}:
            raise ValueError("peer_kind must be client or gateway")
        if not self.peers:
            raise ValueError("at least one peer is required")
        for address, remote_as in self.peers.items():
            _ip(address, f"{self.label}.peer")
            _integer(remote_as, f"{self.label}.remote_as", minimum=1)


def evaluate_bgp_summary(
    raw: bytes | str, expectation: BGPSummaryExpectation
) -> Evaluation:
    """Validate the exact configured peer set while allowing convergence lag."""

    try:
        value = parse_json(raw, context=expectation.label)
        if not isinstance(value, dict):
            raise ParseError(f"{expectation.label}: top level is not an object")
        _exact_keys(value, FRR_SUMMARY_KEYS, expectation.label)
        for key in (
            "as",
            "vrfId",
            "tableVersion",
            "ribCount",
            "ribMemory",
            "peerCount",
            "peerMemory",
            "failedPeers",
            "displayedPeers",
            "totalPeers",
            "dynamicPeers",
        ):
            _integer(value[key], f"{expectation.label}.{key}")
        _ip(value["routerId"], f"{expectation.label}.routerId")
        if value["as"] != expectation.local_as:
            return failed(
                f"{expectation.label}: wrong local AS",
                expected=expectation.local_as,
                observed=value["as"],
            )
        if value["vrfName"] != expectation.vrf_name:
            return failed(
                f"{expectation.label}: wrong VRF name",
                expected=expectation.vrf_name,
                observed=value["vrfName"],
            )
        expected_peers = frozenset(expectation.peers)
        peer_count = len(expected_peers)
        if value["peerCount"] != peer_count or value["totalPeers"] != peer_count:
            return failed(
                f"{expectation.label}: configured peer count changed",
                expected=peer_count,
                peerCount=value["peerCount"],
                totalPeers=value["totalPeers"],
            )
        if value["dynamicPeers"] != 0:
            return failed(f"{expectation.label}: dynamic peer appeared")
        best_path = value["bestPath"]
        if not isinstance(best_path, dict):
            raise ParseError(f"{expectation.label}.bestPath: expected object")
        _exact_keys(best_path, frozenset({"multiPathRelax"}), "bestPath")
        if not isinstance(best_path["multiPathRelax"], str):
            raise ParseError("bestPath.multiPathRelax: expected text")
        peers = value["peers"]
        if not isinstance(peers, dict):
            raise ParseError(f"{expectation.label}.peers: expected object")
        observed_peers = frozenset(peers)
        extra = observed_peers - expected_peers
        if extra:
            return failed(
                f"{expectation.label}: unexpected peer present", extra=sorted(extra)
            )
        expected_peer_keys = (
            FRR_CLIENT_PEER_KEYS
            if expectation.peer_kind == "client"
            else FRR_GATEWAY_PEER_KEYS
        )
        for address, peer in peers.items():
            if not isinstance(peer, dict):
                raise ParseError(f"{expectation.label}.{address}: expected object")
            _exact_keys(peer, expected_peer_keys, f"{expectation.label}.{address}")
            for key in expected_peer_keys - {
                "hostname",
                "peerUptime",
                "state",
                "peerState",
                "idType",
                "softwareVersion",
            }:
                _integer(peer[key], f"{expectation.label}.{address}.{key}")
            for key in (
                expected_peer_keys
                & {
                    "hostname",
                    "peerUptime",
                    "state",
                    "peerState",
                    "idType",
                    "softwareVersion",
                }
            ):
                _string(peer[key], f"{expectation.label}.{address}.{key}")
            if peer["localAs"] != expectation.local_as:
                return failed(f"{expectation.label}: peer {address} has wrong local AS")
            if peer["remoteAs"] != expectation.peers[address]:
                return failed(f"{expectation.label}: peer {address} has wrong remote AS")
            if peer["version"] != 4 or peer["idType"] != "ipv4":
                return failed(f"{expectation.label}: peer {address} is not IPv4 BGP")
            state = peer["state"]
            peer_state = peer["peerState"]
            if state == "Established":
                if peer_state != "OK":
                    if peer_state in BGP_CONVERGENCE_STATES:
                        return failed(
                            f"{expectation.label}: peer {address} has contradictory states",
                            state=state,
                            peer_state=peer_state,
                        )
                    return errored(
                        f"{expectation.label}: peer {address} has unknown peerState",
                        peer_state=peer_state,
                    )
            elif state in BGP_CONVERGENCE_STATES:
                if peer_state == "OK":
                    return failed(
                        f"{expectation.label}: peer {address} has contradictory states",
                        state=state,
                        peer_state=peer_state,
                    )
                if peer_state not in BGP_CONVERGENCE_STATES:
                    return errored(
                        f"{expectation.label}: peer {address} has unknown peerState",
                        peer_state=peer_state,
                    )
                if peer_state != state:
                    return failed(
                        f"{expectation.label}: peer {address} has contradictory convergence states",
                        state=state,
                        peer_state=peer_state,
                    )
                return retry(
                    f"{expectation.label}: peer {address} is in documented convergence",
                    state=state,
                    peer_state=peer_state,
                )
            else:
                return errored(
                    f"{expectation.label}: peer {address} has unknown BGP state",
                    state=state,
                )
        missing = expected_peers - observed_peers
        if missing:
            return retry(
                f"{expectation.label}: configured peers are not all established",
                missing=sorted(missing),
            )
        if (
            value["displayedPeers"] != peer_count
            or value["failedPeers"] != 0
        ):
            return retry(f"{expectation.label}: summary counters are converging")
        return passed(
            f"{expectation.label}: exact peers established",
            peers=sorted(expected_peers),
            local_as=expectation.local_as,
        )
    except ParseError as exc:
        return errored(str(exc))


def _text(raw: bytes | str, context: str) -> str:
    if isinstance(raw, bytes):
        try:
            return raw.decode("utf-8", "strict").replace("\r\n", "\n")
        except UnicodeDecodeError as exc:
            raise ParseError(f"{context}: output is not UTF-8") from exc
    if isinstance(raw, str):
        return raw.replace("\r\n", "\n")
    raise ParseError(f"{context}: expected bytes or text")


def _documented_convergence_absence(text: str) -> bool:
    """Recognize only complete, documented absence messages."""

    lines = [line.strip() for line in text.splitlines() if line.strip()]
    return bool(lines) and all(
        any(pattern.fullmatch(line) is not None for pattern in DOCUMENTED_ABSENCE_LINES)
        for line in lines
    )


def _linux_route_row_prefix(line: str) -> str | None:
    parts = line.split()
    if not parts:
        return None
    index = 1 if parts[0] in LINUX_ROUTE_TYPES else 0
    if index >= len(parts):
        return None
    token = parts[index]
    if token == "default":
        return token
    try:
        ipaddress.ip_network(token, strict=False)
    except ValueError:
        return None
    return token


def _looks_like_route_row(line: str) -> bool:
    return _linux_route_row_prefix(line) is not None


def _linux_attributes(
    tokens: Sequence[str],
    *,
    allowed_pairs: frozenset[str],
    allowed_flags: frozenset[str],
    context: str,
) -> tuple[dict[str, str], frozenset[str]]:
    """Parse known ``ip route`` attributes without depending on their order."""

    pairs: dict[str, str] = {}
    flags: set[str] = set()
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token in allowed_flags:
            if token in flags:
                raise ParseError(f"{context}: duplicate {token} flag")
            flags.add(token)
            index += 1
            continue
        if token not in allowed_pairs or index + 1 >= len(tokens):
            raise ParseError(f"{context}: unknown or incomplete attribute {token!r}")
        if token in pairs:
            raise ParseError(f"{context}: duplicate {token} attribute")
        value = tokens[index + 1]
        if token in {"nhid", "metric", "table", "weight"}:
            if re.fullmatch(r"\d+", value) is None:
                raise ParseError(f"{context}: {token} is not an integer")
        elif token in {"via", "src"}:
            _ip(value, f"{context}.{token}")
        elif token == "proto":
            if re.fullmatch(r"[A-Za-z0-9_.-]+", value) is None:
                raise ParseError(f"{context}: malformed protocol")
        elif token == "dev" and re.fullmatch(r"\S+", value) is None:
            raise ParseError(f"{context}: malformed interface")
        pairs[token] = value
        index += 2
    return pairs, frozenset(flags)


def _linux_ecmp_nexthop(
    line: str, *, context: str
) -> tuple[str, str, frozenset[str]]:
    tokens = line.split()
    if not tokens or tokens[0] != "nexthop":
        raise ParseError(f"{context}: malformed nexthop row")
    pairs, flags = _linux_attributes(
        tokens[1:],
        allowed_pairs=frozenset({"via", "dev", "weight"}),
        allowed_flags=frozenset({"onlink", "linkdown"}),
        context=context,
    )
    if frozenset(pairs) != frozenset({"via", "dev", "weight"}):
        raise ParseError(f"{context}: nexthop lacks the exact via/dev/weight shape")
    try:
        weight = int(pairs["weight"])
    except ValueError as exc:
        raise ParseError(f"{context}: weight is outside the iproute2 range") from exc
    if not 1 <= weight <= 256:
        raise ParseError(f"{context}: weight is outside the iproute2 range")
    return pairs["via"], pairs["dev"], flags


class _FRRSelectedPathKind(enum.StrEnum):
    FORWARDING = "FORWARDING"
    BLACKHOLE = "BLACKHOLE"


@dataclasses.dataclass(frozen=True)
class _FRRSelectedPath:
    kind: _FRRSelectedPathKind
    address: str | None
    interface: str | None
    flags: frozenset[str]
    weight: int


@dataclasses.dataclass(frozen=True)
class _FRRRouteBlock:
    lines: tuple[str, ...]
    selected_paths: tuple[_FRRSelectedPath, ...]


_FRR_FORWARDING_PATH_RE = re.compile(
    r"^\s*\*\s+(?P<address>\d+\.\d+\.\d+\.\d+),"
    r"\s+via\s+(?P<interface>\S+)(?P<onlink>\s+onlink)?,"
    r"\s+weight\s+(?P<weight>0|[1-9][0-9]{0,9})\s*$"
)
_FRR_BLACKHOLE_PATH_RE = re.compile(
    r"^\s*\*\s+unreachable \(blackhole\),"
    r"\s+weight\s+(?P<weight>0|[1-9][0-9]{0,9})\s*$"
)


def _frr_path_weight(value: str, *, context: str) -> int:
    weight = int(value)
    if not 1 <= weight <= 0xFFFF:
        raise ParseError(f"{context}: weight is outside the FRR renderer range")
    return weight


def _frr_selected_path(line: str, *, context: str) -> _FRRSelectedPath:
    forwarding = _FRR_FORWARDING_PATH_RE.fullmatch(line)
    if forwarding is not None:
        address = _ip(forwarding.group("address"), f"{context}.address")
        weight = _frr_path_weight(forwarding.group("weight"), context=context)
        flags = (
            frozenset({"onlink"})
            if forwarding.group("onlink") is not None
            else frozenset()
        )
        return _FRRSelectedPath(
            _FRRSelectedPathKind.FORWARDING,
            address,
            forwarding.group("interface"),
            flags,
            weight,
        )

    blackhole = _FRR_BLACKHOLE_PATH_RE.fullmatch(line)
    if blackhole is not None:
        weight = _frr_path_weight(blackhole.group("weight"), context=context)
        return _FRRSelectedPath(
            _FRRSelectedPathKind.BLACKHOLE,
            None,
            None,
            frozenset(),
            weight,
        )
    raise ParseError(f"{context}: malformed selected path: {line!r}")


def _frr_route_block(text: str, *, context: str) -> _FRRRouteBlock:
    """Parse one FRR route block and retain every admitted selected path."""

    lines = [line.rstrip() for line in text.splitlines() if line.strip()]
    headers = [line for line in lines if line.startswith("Routing entry for ")]
    if not headers:
        raise ParseError(f"{context}: nonempty output has no route header")
    if len(headers) != 1:
        raise ParseError(f"{context}: output has duplicate route headers")
    if headers[0] != lines[0]:
        raise ParseError(f"{context}: route header is not the first line")
    allowed = (
        re.compile(r"^Routing entry for \S+$"),
        re.compile(r'^\s+Known via "[^"]+"(?:,.*)?$'),
        re.compile(r"^\s+Last update .+$"),
        re.compile(r"^\s+Flags: .+$"),
        re.compile(r"^\s+Status: .+$"),
    )
    selected_paths: list[_FRRSelectedPath] = []
    for line in lines:
        if line.lstrip().startswith("*"):
            selected_paths.append(
                _frr_selected_path(line, context=f"{context}.selected_path")
            )
        elif not any(pattern.fullmatch(line) is not None for pattern in allowed):
            raise ParseError(f"{context}: unknown route output line: {line!r}")
    return _FRRRouteBlock(tuple(lines), tuple(selected_paths))


def _frr_route_metadata(
    lines: Sequence[str], *, context: str
) -> Evaluation | None:
    """Validate optional version-specific metadata within one route block."""

    known_rows = [
        (index, line.strip())
        for index, line in enumerate(lines)
        if line.lstrip().startswith("Known via ")
    ]
    if len(known_rows) != 1:
        raise ParseError(f"{context}: Known via line is missing or duplicated")
    first_path = next(
        (index for index, line in enumerate(lines) if line.lstrip().startswith("*")),
        len(lines),
    )
    known_index, known = known_rows[0]
    if known_index >= first_path:
        raise ParseError(f"{context}: Known via line follows a selected path")
    known_match = FRR_KNOWN_VIA_RE.fullmatch(known)
    if known_match is None:
        return failed(
            f"{context}: route has unsupported or contradictory Known via qualifiers"
        )
    for field in ("distance", "metric", "tag", "mtu"):
        value = known_match.group(field)
        if value is not None and int(value) > 0xFFFFFFFF:
            return failed(f"{context}: {field} exceeds the FRR renderer range")
    if known_match.group("realm") is not None:
        tag = int(known_match.group("tag"))
        if not 1 <= tag <= 255:
            return failed(f"{context}: tag realm is outside the supported range")

    metadata: dict[str, str] = {}
    for index, line in enumerate(lines):
        stripped = line.strip()
        for label in ("Last update", "Flags:", "Status:"):
            if not stripped.startswith(label):
                continue
            if index >= first_path:
                raise ParseError(f"{context}: metadata follows a selected path")
            if label in metadata:
                raise ParseError(f"{context}: duplicate {label.rstrip(':')} metadata")
            metadata[label] = stripped.removeprefix(label).strip()
            break

    if "Flags:" in metadata and metadata["Flags:"] != "Selected":
        return failed(
            f"{context}: route flags are not Selected",
            flags=metadata["Flags:"],
        )
    if "Status:" in metadata and metadata["Status:"] != "Installed":
        return failed(
            f"{context}: route status is not Installed",
            status=metadata["Status:"],
        )
    return None


def evaluate_frr_ecmp_route(
    raw: bytes | str,
    *,
    prefix: str,
    expected_hops: frozenset[tuple[str, str]],
) -> Evaluation:
    """Check one FRR route; uptime, metric and weight values are normalized."""

    try:
        text = _text(raw, "FRR ECMP route")
        if not text.strip() or _documented_convergence_absence(text):
            return retry("FRR ECMP route is not installed yet")
        block = _frr_route_block(text, context="FRR ECMP route")
        lines = block.lines
        metadata_problem = _frr_route_metadata(lines, context="FRR ECMP route")
        if metadata_problem is not None:
            return metadata_problem
        entries = [line.removeprefix("Routing entry for ") for line in lines if line.startswith("Routing entry for ")]
        if entries != [prefix]:
            return failed("FRR ECMP route returned a different prefix", entries=entries)
        protocols = re.findall(r'^\s*Known via "([^"]+)"', "\n".join(lines), re.MULTILINE)
        if protocols != ["bgp"]:
            return failed("FRR ECMP route is not exactly one BGP route", protocols=protocols)
        if any(
            path.kind is _FRRSelectedPathKind.BLACKHOLE
            for path in block.selected_paths
        ):
            return failed("FRR ECMP route contains a selected non-forwarding path")
        hops: list[tuple[str, str]] = []
        for path in block.selected_paths:
            if path.address is None or path.interface is None:
                raise ParseError("FRR ECMP route: incomplete forwarding path")
            hop = (path.address, path.interface)
            if hop in hops:
                return failed(
                    "FRR ECMP route repeats a next hop",
                    observed=hops + [hop],
                )
            hops.append(hop)
        unexpected = [hop for hop in hops if hop not in expected_hops]
        if unexpected:
            return failed(
                "FRR ECMP route has an unexpected next hop",
                expected=sorted(expected_hops),
                observed=hops,
            )
        if len(hops) < len(expected_hops):
            return retry("FRR ECMP next hops are still converging", observed=hops)
        if len(hops) > len(expected_hops):
            return failed(
                "FRR ECMP route has extra selected next hops",
                expected=sorted(expected_hops),
                observed=hops,
            )
        return passed("FRR RIB has the exact ECMP route", hops=sorted(hops))
    except ParseError as exc:
        return errored(str(exc))


def evaluate_linux_ecmp_route(
    raw: bytes | str,
    *,
    prefix: str,
    expected_hops: frozenset[tuple[str, str]],
) -> Evaluation:
    """Check one Linux multipath FIB route while ignoring nhid/metric churn."""

    try:
        text = _text(raw, "Linux ECMP route")
        lines = [line.rstrip() for line in text.splitlines() if line.strip()]
        if not lines or _documented_convergence_absence(text):
            return retry("Linux ECMP route is not installed yet")
        blocks: list[tuple[str, list[str]]] = []
        for line in lines:
            if not line[0].isspace():
                if not _looks_like_route_row(line):
                    raise ParseError("Linux ECMP route: malformed route row")
                blocks.append((line, []))
            elif not blocks:
                raise ParseError("Linux ECMP route: continuation precedes a route row")
            else:
                blocks[-1][1].append(line.strip())
        target_blocks = [
            block for block in blocks if _linux_route_row_prefix(block[0]) == prefix
        ]
        if not target_blocks:
            return failed("Linux FIB did not return the target prefix")
        if len(target_blocks) != 1:
            return failed("Linux FIB returned the target prefix more than once")
        if len(blocks) != 1:
            return failed(
                "Linux ECMP query returned extra route rows",
                rows=[row for row, _continuation in blocks],
            )
        first, continuation = target_blocks[0]
        first_tokens = first.split()
        if first_tokens[0] in LINUX_ROUTE_TYPES:
            return failed("Linux ECMP target is a non-forwarding route type")
        if "linkdown" in first_tokens:
            return failed("Linux ECMP target route is linkdown")
        first_fields, _first_flags = _linux_attributes(
            first_tokens[1:],
            allowed_pairs=frozenset({"nhid", "proto", "metric"}),
            allowed_flags=frozenset(),
            context="Linux ECMP route",
        )
        if first_fields.get("proto") != "bgp":
            return failed("Linux ECMP route is not proto bgp")
        parsed_hops = [
            _linux_ecmp_nexthop(line, context="Linux ECMP route")
            for line in continuation
        ]
        if any("linkdown" in flags for _address, _interface, flags in parsed_hops):
            return failed("Linux ECMP route contains a linkdown next hop")
        hops = [(address, interface) for address, interface, _flags in parsed_hops]
        if not hops:
            return failed("Linux ECMP target route has no next hops")
        if len(hops) != len(set(hops)):
            return failed("Linux ECMP route repeats a next hop")
        if not set(hops) <= expected_hops:
            return failed(
                "Linux ECMP route has an unexpected next hop",
                expected=sorted(expected_hops),
                observed=sorted(hops),
            )
        if len(hops) < len(expected_hops):
            return retry("Linux ECMP next hops are still converging", observed=hops)
        if set(hops) != expected_hops:
            return failed(
                "Linux ECMP route has the wrong next-hop set",
                expected=sorted(expected_hops),
                observed=sorted(hops),
            )
        return passed("Linux FIB has the exact ECMP route", hops=sorted(hops))
    except ParseError as exc:
        return errored(str(exc))


def evaluate_type5_route(
    raw: bytes | str, *, prefix: str, vni: int, next_hop: str
) -> Evaluation:
    try:
        text = _text(raw, "EVPN Type 5 route")
        if not text.strip() or _documented_convergence_absence(text):
            return retry("EVPN Type 5 route is absent during convergence")
        ipaddress.ip_network(prefix, strict=True)  # validate the expected prefix
        lines = [line.rstrip() for line in text.splitlines()]
        entry_indexes = [
            index
            for index, line in enumerate(lines)
            if line.startswith("BGP routing table entry")
        ]
        if not entry_indexes:
            raise ParseError("EVPN Type 5 route: nonempty output has no BGP entry")
        if len(entry_indexes) != 1:
            return failed("EVPN Type 5 query returned extra BGP entries")
        entry_index = entry_indexes[0]
        prefix_re = re.compile(
            r"^BGP routing table entry(?: for \S*:)?\[5\]:\[0\]:\[(\d+)\]:\[([^]]+)\]$"
        )
        entry_match = prefix_re.fullmatch(lines[entry_index])
        if entry_match is None:
            raise ParseError("EVPN Type 5 route: malformed BGP entry header")
        observed_prefix = f"{entry_match.group(2)}/{entry_match.group(1)}"
        if observed_prefix != prefix:
            return failed("EVPN Type 5 query returned a different prefix", observed=observed_prefix)
        footer_indexes = [
            index
            for index, line in enumerate(lines)
            if line.strip().startswith("Displayed ")
        ]
        if len(footer_indexes) != 1 or footer_indexes[0] <= entry_index:
            raise ParseError("EVPN Type 5 route: missing or duplicate Displayed footer")
        footer_index = footer_indexes[0]
        if any(line.strip() for line in lines[footer_index + 1 :]):
            raise ParseError("EVPN Type 5 route: output follows the Displayed footer")
        footer = lines[footer_index].strip()
        footer_match = re.fullmatch(r"Displayed\s+(\d+) prefixes \((\d+) paths\)", footer)
        if footer_match is None:
            raise ParseError("EVPN Type 5 route: malformed Displayed footer")
        if footer_match.groups() != ("1", "1"):
            return failed("EVPN Type 5 footer reports an unexpected route/path count")
        if entry_index != 1 or not re.fullmatch(r"Route Distinguisher: \S+", lines[0]):
            raise ParseError("EVPN Type 5 route: unexpected preamble")
        body = lines[entry_index:footer_index]
        allowed_body = (
            prefix_re,
            re.compile(r"^Paths: \(\d+ available, best #\d+\)$"),
            re.compile(r"^\s+Advertised to peers:$"),
            re.compile(r"^\s+Not advertised to any peer$"),
            re.compile(r"^\s+\d+\.\d+\.\d+\.\d+$"),
            re.compile(r"^\s+Route \[5\]:\[0\]:\[\d+\]:\[[^]]+\] VNI \d+$"),
            re.compile(r"^\s+[0-9 ]+$"),
            re.compile(r"^\s+\d+\.\d+\.\d+\.\d+ from \d+\.\d+\.\d+\.\d+ \([^)]*\)$"),
            re.compile(r"^\s+Origin .+$"),
            re.compile(r"^\s+Extended Community: .+$"),
            re.compile(r"^\s+Last update: .+$"),
        )
        for line in body:
            if not line.strip():
                continue
            if not any(pattern.fullmatch(line) is not None for pattern in allowed_body):
                raise ParseError(f"EVPN Type 5 route: unknown line {line!r}")
        route_re = re.compile(
            r"^\s+Route \[5\]:\[0\]:\[(\d+)\]:\[([^]]+)\] VNI (\d+)\s*$"
        )
        route_rows = [
            (index, match.groups())
            for index, line in enumerate(body)
            if (match := route_re.fullmatch(line))
        ]
        if len(route_rows) != 1:
            raise ParseError("EVPN Type 5 route: target route row is missing or duplicated")
        route_index, route_fields = route_rows[0]
        route_prefix = f"{route_fields[1]}/{route_fields[0]}"
        if route_prefix != prefix:
            return failed("EVPN Type 5 route row has a different prefix", observed=route_prefix)
        if int(route_fields[2]) != vni:
            return failed("EVPN Type 5 route has the wrong VNI", observed=int(route_fields[2]))
        paths_rows = [
            (
                index,
                re.fullmatch(r"Paths: \((\d+) available, best #(\d+)\)", line),
            )
            for index, line in enumerate(body)
            if line.startswith("Paths:")
        ]
        if len(paths_rows) != 1:
            raise ParseError("EVPN Type 5 route: Paths line is missing, duplicated or malformed")
        paths_index, paths_match = paths_rows[0]
        if paths_match is None:
            raise ParseError("EVPN Type 5 route: Paths line is missing, duplicated or malformed")
        if paths_match.groups() != ("1", "1"):
            return failed(
                "EVPN Type 5 route does not identify its sole path as best",
                available=paths_match.group(1),
                best_index=paths_match.group(2),
            )
        origin_rows = [line for line in body if line.strip().startswith("Origin ")]
        community_rows = [
            line for line in body if line.strip().startswith("Extended Community: ")
        ]
        update_rows = [
            line for line in body if line.strip().startswith("Last update: ")
        ]
        if len(origin_rows) != 1 or len(community_rows) != 1 or len(update_rows) != 1:
            raise ParseError(
                "EVPN Type 5 route: path metadata is missing or duplicated"
            )
        origin_match = re.fullmatch(
            r"\s+Origin (IGP|EGP|incomplete),\s*(.+)", origin_rows[0]
        )
        if origin_match is None:
            return failed(
                "EVPN Type 5 route has an invalid Origin classification",
                origin=origin_rows[0].strip(),
            )
        attributes = [
            attribute.strip() for attribute in origin_match.group(2).split(",")
        ]
        metric_attributes = [
            attribute
            for attribute in attributes
            if re.fullmatch(r"metric \d+", attribute) is not None
        ]
        best_attributes = [
            attribute
            for attribute in attributes
            if attribute == "best"
            or (
                (match := re.fullmatch(r"best \(([^()]*)\)", attribute))
                is not None
                and match.group(1) in FRR_BGP_SELECTION_REASONS
            )
        ]
        allowed_attributes = set(metric_attributes) | set(best_attributes) | {
            "valid",
            "external",
        }
        if (
            len(attributes) != len(set(attributes))
            or len(metric_attributes) != 1
            or len(best_attributes) != 1
            or "valid" not in attributes
            or "external" not in attributes
            or any(attribute not in allowed_attributes for attribute in attributes)
        ):
            return failed(
                "EVPN Type 5 route has contradictory path metadata",
                attributes=attributes,
            )
        path_hops = re.findall(
            r"^\s+(\d+\.\d+\.\d+\.\d+) from (\d+\.\d+\.\d+\.\d+) \([^)]*\)$",
            "\n".join(body),
            re.MULTILINE,
        )
        if not path_hops:
            raise ParseError("EVPN Type 5 route: advertised path row is missing")
        if set(path_hops) != {(next_hop, next_hop)} or len(path_hops) != 1:
            return failed("EVPN Type 5 route has the wrong or duplicate next hop", observed=path_hops)
        path_index = next(
            index
            for index, line in enumerate(body)
            if re.fullmatch(
                r"\s+\d+\.\d+\.\d+\.\d+ from \d+\.\d+\.\d+\.\d+ \([^)]*\)",
                line,
            )
            is not None
        )
        metadata_indexes = [
            body.index(origin_rows[0]),
            body.index(community_rows[0]),
            body.index(update_rows[0]),
        ]
        as_path_indexes = [
            index
            for index, line in enumerate(body)
            if re.fullmatch(r"\s+\d+(?:\s+\d+)*\s*", line) is not None
        ]
        if len(as_path_indexes) != 1:
            raise ParseError("EVPN Type 5 route: AS path is missing or duplicated")
        if not (
            paths_index
            < route_index
            < as_path_indexes[0]
            < path_index
            < metadata_indexes[0]
            < metadata_indexes[1]
            < metadata_indexes[2]
        ):
            raise ParseError(
                "EVPN Type 5 route: path metadata is outside its selected path"
            )
        return passed("exact EVPN Type 5 route is installed", vni=vni, next_hop=next_hop)
    except (ParseError, ValueError) as exc:
        return errored(f"EVPN Type 5 route: {exc}")


def evaluate_frr_single_route(
    raw: bytes | str, *, prefix: str, next_hop: str, interface: str
) -> Evaluation:
    try:
        text = _text(raw, "FRR single route")
        if not text.strip() or _documented_convergence_absence(text):
            return retry("FRR route is not installed yet")
        block = _frr_route_block(text, context="FRR single route")
        lines = block.lines
        metadata_problem = _frr_route_metadata(lines, context="FRR single route")
        if metadata_problem is not None:
            return metadata_problem
        entries = [line.removeprefix("Routing entry for ") for line in lines if line.startswith("Routing entry for ")]
        if entries != [prefix]:
            return failed("FRR route contains a different prefix", entries=entries)
        rendered = "\n".join(lines)
        if re.findall(r'^\s*Known via "([^"]+)"', rendered, re.MULTILINE) != ["bgp"]:
            return failed("FRR route is not exactly one BGP route")
        if any(
            path.kind is _FRRSelectedPathKind.BLACKHOLE
            for path in block.selected_paths
        ):
            return failed("FRR route contains a selected non-forwarding path")
        hops: list[tuple[str, str]] = []
        for path in block.selected_paths:
            if path.address is None or path.interface is None:
                raise ParseError("FRR single route: incomplete forwarding path")
            hops.append((path.address, path.interface))
        if not hops:
            return retry("FRR route has no selected next hop yet")
        if hops != [(next_hop, interface)]:
            return failed("FRR route has the wrong or extra next hop", observed=hops)
        return passed("FRR RIB has the exact BGP route")
    except ParseError as exc:
        return errored(str(exc))


def evaluate_linux_single_route(
    raw: bytes | str,
    *,
    prefix: str,
    next_hop: str,
    interface: str,
    protocol: str = "bgp",
) -> Evaluation:
    try:
        text = _text(raw, "Linux single route")
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        if not lines or _documented_convergence_absence(text):
            return retry("Linux route is not installed yet")
        if len(lines) != 1:
            if all(_looks_like_route_row(line) for line in lines):
                return failed("Linux route query returned extra rows", rows=lines)
            raise ParseError("Linux single route: output contains unknown rows")
        line = lines[0]
        rendered_prefix = prefix.removesuffix("/32") if prefix.endswith("/32") else prefix
        if not _looks_like_route_row(line):
            raise ParseError("Linux single route: malformed route row")
        tokens = line.split()
        if tokens[0] != rendered_prefix:
            return failed("Linux route has the wrong prefix")
        if "linkdown" in tokens:
            return failed("Linux route is linkdown")
        fields, _flags = _linux_attributes(
            tokens[1:],
            allowed_pairs=frozenset(
                {"nhid", "via", "dev", "proto", "metric"}
            ),
            allowed_flags=frozenset({"onlink"}),
            context="Linux single route",
        )
        if "via" not in fields or "dev" not in fields:
            return failed("Linux route has no expected next-hop form")
        observed_path = (fields["via"], fields["dev"])
        if observed_path != (next_hop, interface):
            return failed(
                "Linux route has the wrong next hop/interface",
                observed=observed_path,
            )
        if fields.get("proto") != protocol:
            return failed("Linux route has the wrong protocol")
        return passed("Linux FIB has the exact route")
    except ParseError as exc:
        return errored(str(exc))


def evaluate_vni(
    raw: bytes | str,
    *,
    vni: int,
    vrf: str,
    bridge: str,
    local_vtep: str,
    vxlan_interface: str | None = None,
) -> Evaluation:
    try:
        text = _text(raw, "FRR VNI")
        if not text.strip() or _documented_convergence_absence(text):
            return retry("FRR VNI is absent during convergence")
        fields: dict[str, str] = {}
        for line in text.splitlines():
            if not line.strip():
                continue
            match = re.match(r"^\s*([^:]+):\s*(.*?)\s*$", line)
            if match is None:
                raise ParseError(f"FRR VNI: unknown line {line!r}")
            key, value = match.groups()
            if key in fields:
                raise ParseError(f"FRR VNI: duplicate field {key}")
            fields[key] = value
        expected_fields = {
            "VNI",
            "Type",
            "Tenant VRF",
            "Vlan",
            "Bridge",
            "Local Vtep Ip",
            "Vxlan-Intf",
            "SVI-If",
            "State",
            "VNI Filter",
            "System MAC",
            "Router MAC",
            "Number of MACs (local and remote) known for this VNI",
            "Number of ARPs (IPv4 and IPv6, local and remote) known for this VNI",
            "L2 VNIs",
        }
        if set(fields) != expected_fields:
            raise ParseError(
                "FRR VNI: field set mismatch "
                f"missing={sorted(expected_fields - fields.keys())} "
                f"extra={sorted(fields.keys() - expected_fields)}"
            )
        expected = {
            "VNI": str(vni),
            "Type": "L3",
            "Tenant VRF": vrf,
            "Bridge": bridge,
            "Local Vtep Ip": local_vtep,
            "SVI-If": bridge,
            "State": "Up",
        }
        if vxlan_interface is not None:
            expected["Vxlan-Intf"] = vxlan_interface
        wrong = {key: fields[key] for key, value in expected.items() if fields[key] != value}
        if wrong:
            return failed("FRR VNI fields do not match", observed=wrong)
        for key in (
            "Vlan",
            "Number of MACs (local and remote) known for this VNI",
            "Number of ARPs (IPv4 and IPv6, local and remote) known for this VNI",
        ):
            if re.fullmatch(r"\d+", fields[key]) is None:
                raise ParseError(f"FRR VNI: {key} is not an integer")
        for key in ("System MAC", "Router MAC"):
            if MAC_RE.fullmatch(fields[key]) is None:
                raise ParseError(f"FRR VNI: {key} is malformed")
        return passed("FRR VNI is Up with the exact identity", vni=vni)
    except ParseError as exc:
        return errored(str(exc))


def evaluate_remote_vtep(
    raw: bytes | str, *, remote_vtep: str, vni: int
) -> Evaluation:
    try:
        text = _text(raw, "OVN remote VTEP")
        if not text.strip() or _documented_convergence_absence(text):
            return retry("OVN remote VTEP is absent during convergence")
        row_re = re.compile(
            r"^IP:\s*(\d+\.\d+\.\d+\.\d+),\s*port:\s*(\d+),\s*vni:\s*(\d+)\s*$"
        )
        lines = [line for line in text.splitlines() if line.strip()]
        matches = [row_re.fullmatch(line) for line in lines]
        if any(match is None for match in matches):
            raise ParseError("OVN remote VTEP: unknown or malformed row")
        rows = [match.groups() for match in matches if match is not None]
        matching_vni = [row for row in rows if int(row[2]) == vni]
        if not matching_vni:
            return retry("OVN remote VTEP has not converged for the VNI")
        if matching_vni != [(remote_vtep, "4789", str(vni))]:
            return failed("OVN remote VTEP has the wrong or duplicate identity", rows=matching_vni)
        return passed("OVN remote VTEP matches peer and UDP port", vni=vni)
    except ParseError as exc:
        return errored(str(exc))


def evaluate_blackhole_route(raw: bytes | str, *, prefix: str) -> Evaluation:
    try:
        text = _text(raw, "tenant local route")
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        if not lines or _documented_convergence_absence(text):
            return retry("tenant local route is absent")
        if any(not _looks_like_route_row(line) for line in lines):
            raise ParseError("tenant local route: unknown or malformed row")
        if len(lines) != 1:
            return failed(
                "tenant local route returned extra route rows", rows=lines
            )
        tokens = lines[0].split()
        if tokens[:2] != ["blackhole", prefix]:
            return failed(
                "tenant local route is not the exact OVN blackhole", rows=lines
            )
        pairs, flags = _linux_attributes(
            tokens[2:],
            allowed_pairs=frozenset({"proto", "metric", "nhid"}),
            allowed_flags=frozenset(),
            context="tenant local route",
        )
        if flags or pairs.get("proto") != "ovn":
            return failed(
                "tenant local route is not the exact OVN blackhole", rows=lines
            )
        return passed("tenant table has the exact local OVN route")
    except ParseError as exc:
        return errored(str(exc))


def evaluate_route_get(
    raw: bytes | str,
    *,
    destination: str,
    source: str | None,
    next_hop: str,
    interface: str,
    table: int,
) -> Evaluation:
    try:
        text = _text(raw, "route-get")
        if not text.strip() or _documented_convergence_absence(text):
            return retry("route-get has not converged")
        raw_lines = [line.rstrip() for line in text.splitlines() if line.strip()]
        first = raw_lines[0].strip()
        extras = raw_lines[1:]
        for extra in extras:
            if extra[:1].isspace() and re.fullmatch(
                r"\s+cache(?:\s+mtu\s+\d+)?\s*", extra
            ):
                continue
            if _looks_like_route_row(extra.strip()):
                return failed("route-get returned an extra route row", row=extra.strip())
            raise ParseError(f"route-get: unknown extra row {extra!r}")
        if not _looks_like_route_row(first):
            raise ParseError("route-get: malformed route row")
        if not first.startswith(destination + " "):
            return failed("route-get returned the wrong destination", row=first)
        source_clause = "" if source is None else rf" from {re.escape(source)}"
        row_re = re.compile(
            rf"^{re.escape(destination)}{source_clause}"
            rf" via ({re.escape(next_hop)}) dev ({re.escape(interface)})"
            rf" table ({table})(?: src \d+\.\d+\.\d+\.\d+)?(?: uid \d+)?$"
        )
        if row_re.fullmatch(first) is None:
            known_path_tokens = {"from", "via", "dev", "table"}
            if any(token in first.split() for token in known_path_tokens):
                return failed("route-get returned the wrong source/path/table", row=first)
            raise ParseError("route-get: malformed route path")
        return passed("route-get uses the exact source/path/table")
    except ParseError as exc:
        return errored(str(exc))


def _decode_ovs(value: Any, context: str) -> Any:
    if not isinstance(value, list) or len(value) != 2 or not isinstance(value[0], str):
        return value
    kind, payload = value
    if kind in {"uuid", "named-uuid"}:
        if not isinstance(payload, str) or UUID_RE.fullmatch(payload) is None:
            raise ParseError(f"{context}: invalid OVS UUID")
        return payload.lower()
    if kind == "set":
        if not isinstance(payload, list):
            raise ParseError(f"{context}: malformed OVS set")
        return [_decode_ovs(item, context) for item in payload]
    if kind == "map":
        if not isinstance(payload, list):
            raise ParseError(f"{context}: malformed OVS map")
        result: dict[Any, Any] = {}
        for pair in payload:
            if not isinstance(pair, list) or len(pair) != 2:
                raise ParseError(f"{context}: malformed OVS map entry")
            key = _decode_ovs(pair[0], context)
            if key in result:
                raise ParseError(f"{context}: duplicate OVS map key")
            result[key] = _decode_ovs(pair[1], context)
        return result
    raise ParseError(f"{context}: unknown OVS tagged value {kind}")


def parse_ovs_rows(raw: bytes | str, *, context: str) -> list[dict[str, Any]]:
    value = parse_json(raw, context=context)
    if not isinstance(value, dict):
        raise ParseError(f"{context}: expected OVS JSON object")
    _exact_keys(value, frozenset({"headings", "data"}), context)
    headings = value["headings"]
    data = value["data"]
    if (
        not isinstance(headings, list)
        or not headings
        or any(not isinstance(item, str) or not item for item in headings)
        or len(set(headings)) != len(headings)
        or not isinstance(data, list)
    ):
        raise ParseError(f"{context}: malformed headings/data")
    rows: list[dict[str, Any]] = []
    for index, raw_row in enumerate(data):
        if not isinstance(raw_row, list) or len(raw_row) != len(headings):
            raise ParseError(f"{context}: malformed row {index}")
        rows.append(
            {
                heading: _decode_ovs(cell, f"{context}.{heading}")
                for heading, cell in zip(headings, raw_row, strict=True)
            }
        )
    return rows


@dataclasses.dataclass(frozen=True)
class PortBindingProof:
    logical_port: str
    uuid: str
    datapath: str


def evaluate_port_bindings(
    raw: bytes | str, *, expected_ports: frozenset[str]
) -> tuple[Evaluation, dict[str, PortBindingProof]]:
    try:
        rows = parse_ovs_rows(raw, context="SB Port_Binding")
        return _evaluate_port_binding_rows(rows, expected_ports=expected_ports)
    except ParseError as exc:
        return errored(str(exc)), {}


def _evaluate_port_binding_rows(
    rows: Sequence[Mapping[str, Any]], *, expected_ports: frozenset[str]
) -> tuple[Evaluation, dict[str, PortBindingProof]]:
    try:
        proofs: dict[str, PortBindingProof] = {}
        for row in rows:
            _exact_keys(row, frozenset({"_uuid", "logical_port", "datapath"}), "Port_Binding row")
            logical_port = _string(row["logical_port"], "Port_Binding.logical_port")
            uuid = _string(row["_uuid"], "Port_Binding._uuid")
            datapath = _string(row["datapath"], "Port_Binding.datapath")
            if UUID_RE.fullmatch(uuid) is None or UUID_RE.fullmatch(datapath) is None:
                raise ParseError("Port_Binding: malformed UUID/datapath")
            if logical_port in proofs:
                raise ParseError("Port_Binding: duplicate logical_port")
            proofs[logical_port] = PortBindingProof(logical_port, uuid.lower(), datapath.lower())
        observed = frozenset(proofs)
        if observed != expected_ports:
            if observed < expected_ports:
                return retry("SB LRP Port_Bindings are still converging", missing=sorted(expected_ports - observed)), proofs
            return failed("SB LRP Port_Binding scope contains extras", observed=sorted(observed)), proofs
        if len({proof.datapath for proof in proofs.values()}) != len(proofs):
            return failed("A/B LRP Port_Bindings share a datapath"), proofs
        if len({proof.uuid for proof in proofs.values()}) != len(proofs):
            return errored("SB returned duplicate Port_Binding UUIDs"), proofs
        return passed("SB LRP Port_Bindings have distinct UUIDs/datapaths"), proofs
    except ParseError as exc:
        return errored(str(exc)), {}


def evaluate_learned_routes(
    raw: bytes | str,
    *,
    expected: Mapping[tuple[str, str], str],
    scope: frozenset[str],
) -> Evaluation:
    """Require the exact expected Learned_Route set within the study LRP scope.

    ``expected`` maps ``(ip_prefix, port_binding_uuid)`` to the required
    nexthop. Rows bound to Port_Bindings outside ``scope`` (baseline lab
    routes, e.g. lrp-mgc-100/200-external) are out of scope and ignored;
    rows inside the scope must match the expected set exactly (no extras,
    no duplicates, exact nexthop).
    """

    try:
        rows = parse_ovs_rows(raw, context="SB Learned_Route")
        observed: dict[tuple[str, str], list[tuple[str, str]]] = {
            key: [] for key in expected
        }
        extra: list[tuple[str, str]] = []
        observed_uuids: set[str] = set()
        for row in rows:
            _exact_keys(
                row,
                frozenset({"_uuid", "ip_prefix", "nexthop", "logical_port"}),
                "Learned_Route row",
            )
            route_uuid = _string(row["_uuid"], "Learned_Route._uuid")
            if UUID_RE.fullmatch(route_uuid) is None:
                raise ParseError("Learned_Route: malformed row UUID")
            route_uuid = route_uuid.lower()
            if route_uuid in observed_uuids:
                raise ParseError("Learned_Route: duplicate row UUID in observed table")
            observed_uuids.add(route_uuid)
            source = _string(row["ip_prefix"], "Learned_Route.ip_prefix").removesuffix("/32")
            logical_port = _string(row["logical_port"], "Learned_Route.logical_port").lower()
            if UUID_RE.fullmatch(logical_port) is None:
                raise ParseError("Learned_Route: malformed logical_port UUID")
            if logical_port not in scope:
                continue
            key = (source, logical_port)
            if key not in observed:
                extra.append(key)
                continue
            nexthop = _string(row["nexthop"], "Learned_Route.nexthop")
            observed[key].append((route_uuid, nexthop))
        if extra:
            return failed(
                "Learned_Route scope contains unexpected sources",
                sources=sorted("%s via %s" % (source, binding)
                               for source, binding in extra),
            )
        missing: list[str] = []
        for key, wanted_nexthop in expected.items():
            source, binding = key
            routes = observed[key]
            if not routes:
                missing.append("%s via %s" % (source, binding))
                continue
            if len(routes) != 1:
                return failed(f"Learned_Route for {source} is not unique", routes=routes)
            _route_uuid, nexthop = routes[0]
            if nexthop != wanted_nexthop:
                return failed(
                    f"Learned_Route for {source} has wrong nexthop/binding",
                    observed=(nexthop, binding), expected=(wanted_nexthop, binding),
                )
        if missing:
            return retry(
                "Learned_Route rows have not all converged",
                missing=missing,
            )
        return passed("each expected route has one correctly bound Learned_Route within study scope")
    except ParseError as exc:
        return errored(str(exc))


@dataclasses.dataclass(frozen=True)
class PingProof:
    flavor: str
    transmitted: int
    received: int
    sequences: tuple[int, ...]


def evaluate_ping(raw: bytes | str, *, returncode: int, expect_reply: bool) -> Evaluation:
    """Parse the admitted BusyBox/iputils five-packet result exactly."""

    try:
        text = _text(raw, "ping")
        lowered = text.casefold()
        if any(
            message in lowered
            for message in (
                "network is unreachable",
                "no route to host",
                "destination host unreachable",
            )
        ):
            return failed("ping failed because the source route/endpoint is unavailable")
        if returncode not in {0, 1}:
            return errored("ping returned an operational error", returncode=returncode)
        summary_patterns = {
            "busybox": re.compile(
                r"^\s*(0|[1-9][0-9]{0,9}) packets transmitted,\s*"
                r"(0|[1-9][0-9]{0,9}) packets received,\s*"
                r"(0|[1-9][0-9]{0,9})% packet loss\s*$"
            ),
            "iputils": re.compile(
                r"^\s*(0|[1-9][0-9]{0,9}) packets transmitted,\s*"
                r"(0|[1-9][0-9]{0,9}) received,\s*"
                r"(0|[1-9][0-9]{0,9})% packet loss"
                r"(?:,\s*time\s+(?:0|[1-9][0-9]*)ms)?\s*$"
            ),
        }
        summary_lines = [
            line
            for line in text.splitlines()
            if "packets transmitted" in line.casefold()
        ]
        if not summary_lines:
            return errored("ping summary is missing")
        if len(summary_lines) != 1:
            return errored("ping summary is duplicated or mixes flavors")
        summaries = [
            (flavor, match)
            for flavor, pattern in summary_patterns.items()
            if (match := pattern.fullmatch(summary_lines[0])) is not None
        ]
        if not summaries:
            return errored("ping summary is unsupported")
        flavor, summary = summaries[0]
        transmitted = int(summary.group(1))
        received = int(summary.group(2))
        loss_percent = int(summary.group(3))
        if transmitted != 5:
            return failed("ping did not emit exactly five packets", transmitted=transmitted)
        if received > transmitted:
            return failed(
                "ping summary received count exceeds transmitted count",
                transmitted=transmitted,
                received=received,
            )
        if loss_percent > 100:
            return failed(
                "ping summary loss percentage is outside 0..100",
                loss_percent=loss_percent,
            )
        expected_loss = (transmitted - received) * 100 // transmitted
        if loss_percent != expected_loss:
            return failed(
                "ping summary loss percentage contradicts its counters",
                expected_loss=expected_loss,
                observed_loss=loss_percent,
            )
        reply_patterns = {
            "busybox": re.compile(
                r"^\d+ bytes from .+:\s+seq=(0|[1-9][0-9]{0,9})\s+ttl=\d+\s+"
                r"time(?:=|<)\S+\s+ms\s*$"
            ),
            "iputils": re.compile(
                r"^\d+ bytes from .+:\s+icmp_seq=(0|[1-9][0-9]{0,9})\s+ttl=\d+\s+"
                r"time(?:=|<)\S+\s+ms\s*$"
            ),
        }
        replies: dict[str, list[int]] = {"busybox": [], "iputils": []}
        malformed_reply_lines: list[str] = []
        for line in text.splitlines():
            matched_flavor: str | None = None
            for candidate, pattern in reply_patterns.items():
                match = pattern.fullmatch(line)
                if match is not None:
                    replies[candidate].append(int(match.group(1)))
                    matched_flavor = candidate
                    break
            if matched_flavor is None and (
                re.match(r"^\s*[0-9]+ bytes from ", line)
                or re.search(r"(?:icmp_)?seq=[0-9]+", line)
            ):
                malformed_reply_lines.append(line)
        if malformed_reply_lines:
            return failed(
                "ping contains unsupported or malformed reply lines",
                lines=malformed_reply_lines,
            )
        other_flavor = "iputils" if flavor == "busybox" else "busybox"
        if replies[other_flavor]:
            return failed(
                "ping reply lines do not match the summary flavor",
                summary_flavor=flavor,
                reply_flavors={
                    name: values for name, values in replies.items() if values
                },
            )
        sequences = tuple(replies[flavor])
        if len(sequences) != received:
            return failed(
                "ping summary received count contradicts its reply lines",
                received=received,
                replies=len(sequences),
            )
        expected_sequences = tuple(range(0, 5)) if flavor == "busybox" else tuple(range(1, 6))
        if expect_reply:
            if returncode != 0 or received != 5:
                return failed("positive ping was not rc0 with five replies", received=received)
            if sequences != expected_sequences:
                return failed(
                    "positive ping does not contain five consecutive flavor-specific sequences",
                    flavor=flavor,
                    observed=sequences,
                )
        else:
            if returncode != 1 or received != 0:
                return failed("negative ping was not rc1 with zero replies", received=received)
            if sequences:
                return failed("negative ping printed unexpected echo replies", sequences=sequences)
        proof = PingProof(flavor, transmitted, received, sequences)
        return passed("ping summary matches the five-packet contract", proof=dataclasses.asdict(proof))
    except ParseError as exc:
        return errored(str(exc))


@dataclasses.dataclass(frozen=True)
class CommandSpec:
    query: str
    source_id: str
    argv: tuple[str, ...]

    def __post_init__(self) -> None:
        if not isinstance(self.query, str) or not self.query:
            raise TypeError("command query must be nonempty text")
        _container_id(self.source_id, self.query + ".source_id")
        if (
            not isinstance(self.argv, tuple)
            or not self.argv
            or any(
                not isinstance(item, str) or not item or "\x00" in item
                for item in self.argv
            )
        ):
            raise TypeError("command argv must be a fixed nonempty text tuple")
        if len(self.argv) < 3 or self.argv[:2] != ("docker", "exec"):
            raise ValueError("X05 evaluator commands must use docker exec")
        if self.argv[2] != self.source_id:
            raise ValueError("command source_id must match docker exec target")


class ObservationOrigin(enum.StrEnum):
    FIXTURE = "FIXTURE"
    RUNTIME_CAPTURE = "RUNTIME_CAPTURE"


@dataclasses.dataclass(frozen=True)
class ObservationEnvelope:
    command: CommandSpec
    origin: ObservationOrigin
    complete: bool = True

    def __post_init__(self) -> None:
        if not isinstance(self.command, CommandSpec):
            raise TypeError("envelope command must be a CommandSpec")
        if not isinstance(self.origin, ObservationOrigin):
            raise TypeError("envelope origin must be an ObservationOrigin")
        if not isinstance(self.complete, bool):
            raise TypeError("envelope completeness must be boolean")


@dataclasses.dataclass(frozen=True)
class CommandSample:
    envelope: ObservationEnvelope
    returncode: int
    stdout: bytes
    stderr: bytes
    elapsed: float

    def __post_init__(self) -> None:
        if not isinstance(self.envelope, ObservationEnvelope):
            raise TypeError("sample envelope must be an ObservationEnvelope")
        if isinstance(self.returncode, bool) or not isinstance(self.returncode, int):
            raise TypeError("sample returncode must be an integer")
        if not isinstance(self.stdout, bytes) or not isinstance(self.stderr, bytes):
            raise TypeError("sample output must be bytes")
        if (
            isinstance(self.elapsed, bool)
            or not isinstance(self.elapsed, (int, float))
            or not math.isfinite(self.elapsed)
            or self.elapsed < 0
        ):
            raise TypeError("sample elapsed time must be finite and nonnegative")

    @property
    def argv(self) -> tuple[str, ...]:
        return self.envelope.command.argv

    @property
    def source_id(self) -> str:
        return self.envelope.command.source_id

    @property
    def query(self) -> str:
        return self.envelope.command.query


@dataclasses.dataclass(frozen=True)
class Collection:
    origin: ObservationOrigin
    samples: Mapping[str, CommandSample]
    io_bytes: int
    error: Evaluation | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.origin, ObservationOrigin):
            raise TypeError("collection origin must be an ObservationOrigin")
        if not isinstance(self.samples, Mapping):
            raise TypeError("collection samples must be a mapping")
        if isinstance(self.io_bytes, bool) or not isinstance(self.io_bytes, int) or self.io_bytes < 0:
            raise TypeError("collection io_bytes must be a nonnegative integer")
        if self.error is not None and not isinstance(self.error, Evaluation):
            raise TypeError("collection error must be an Evaluation")
        if self.error is not None and self.error.outcome is not Outcome.ERROR:
            raise ValueError("collection error must have the ERROR outcome")
        for query, sample in self.samples.items():
            if not isinstance(query, str) or not isinstance(sample, CommandSample):
                raise TypeError("collection contains an invalid sample")
            if sample.query != query:
                raise ValueError("collection key does not match sample query")
            if sample.envelope.origin is not self.origin:
                raise ValueError("collection and sample origins differ")


def _container_id(value: str, context: str) -> str:
    if not isinstance(value, str) or CONTAINER_ID_RE.fullmatch(value) is None:
        raise ValueError(f"{context} must be a captured 64-character Docker ID")
    return value


def collect_fixed_commands(
    runner: RuntimeRunner,
    commands: Mapping[str, CommandSpec],
    *,
    timeout: float,
    io_budget: int,
    clock: Callable[[], float] = time.monotonic,
) -> Collection:
    """Run one observation iteration under a shared time and I/O deadline."""

    origin = ObservationOrigin.RUNTIME_CAPTURE
    if (
        isinstance(timeout, bool)
        or not isinstance(timeout, (int, float))
        or not math.isfinite(timeout)
        or timeout <= 0
        or isinstance(io_budget, bool)
        or not isinstance(io_budget, int)
        or io_budget <= 0
        or io_budget > SHARED_MAX_OUTPUT
    ):
        return Collection(
            origin,
            {},
            0,
            errored("collector budgets must be positive and within the shared output cap"),
        )

    def read_clock(context: str) -> float:
        try:
            value = clock()
        except Exception as exc:
            raise ParseError(
                f"collector clock failed at {context}: {type(exc).__name__}: {exc}"
            ) from exc
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(value)
        ):
            raise ParseError(f"collector clock is invalid at {context}")
        return float(value)

    try:
        started = read_clock("iteration start")
    except ParseError as exc:
        return Collection(origin, {}, 0, errored(str(exc)))

    timeout_value = float(timeout)
    last_clock = started
    reported_elapsed = 0.0
    samples: dict[str, CommandSample] = {}
    total = 0
    for name, command in commands.items():
        if not isinstance(command, CommandSpec) or command.query != name:
            return Collection(origin, samples, total, errored(f"{name}: invalid command spec"))
        remaining = io_budget - total
        if remaining <= 0:
            return Collection(origin, samples, total, errored("observation iteration exhausted its I/O budget"))
        try:
            now = read_clock(f"{name} pre-call")
        except ParseError as exc:
            return Collection(origin, samples, total, errored(str(exc)))
        if now < last_clock:
            return Collection(
                origin,
                samples,
                total,
                errored(f"{name}: monotonic clock regressed before runner call"),
            )
        last_clock = now
        consumed_time = max(now - started, reported_elapsed)
        remaining_time = timeout_value - consumed_time
        if remaining_time <= 0:
            return Collection(
                origin,
                samples,
                total,
                errored(f"{name}: observation iteration deadline exhausted before runner call"),
            )
        try:
            result = runner.run(
                command.argv,
                env=BASE_ENV,
                timeout=remaining_time,
                pass_fds=(),
                max_output_bytes=remaining,
            )
        except Exception as exc:  # runner failures are boundary errors, never absence
            return Collection(
                origin,
                samples,
                total,
                errored(f"{name}: runner failed: {type(exc).__name__}: {exc}"),
            )
        try:
            observed_argv = tuple(result.argv)
            returncode = result.returncode
            stdout = result.stdout
            stderr = result.stderr
            elapsed = result.elapsed
            truncated = getattr(result, "truncated", False)
        except Exception as exc:
            return Collection(
                origin,
                samples,
                total,
                errored(
                    f"{name}: runner result extraction failed: "
                    f"{type(exc).__name__}: {exc}"
                ),
            )
        if observed_argv != command.argv:
            return Collection(origin, samples, total, errored(f"{name}: runner returned different argv"))
        if isinstance(returncode, bool) or not isinstance(returncode, int):
            return Collection(origin, samples, total, errored(f"{name}: invalid return code"))
        if not isinstance(stdout, bytes) or not isinstance(stderr, bytes):
            return Collection(origin, samples, total, errored(f"{name}: runner output must be bytes"))
        if isinstance(elapsed, bool) or not isinstance(elapsed, (int, float)) or not math.isfinite(elapsed) or elapsed < 0:
            return Collection(origin, samples, total, errored(f"{name}: invalid elapsed time"))
        if not isinstance(truncated, bool):
            return Collection(origin, samples, total, errored(f"{name}: invalid truncation marker"))
        observed_bytes = len(stdout) + len(stderr)
        if truncated or observed_bytes > remaining:
            return Collection(
                origin,
                samples,
                total + observed_bytes,
                errored(f"{name}: runner returned truncated or oversized output"),
            )
        total += observed_bytes
        samples[name] = CommandSample(
            ObservationEnvelope(command, origin, complete=True),
            returncode,
            stdout,
            stderr,
            float(elapsed),
        )
        reported_elapsed += float(elapsed)
        try:
            after = read_clock(f"{name} post-call")
        except ParseError as exc:
            return Collection(origin, samples, total, errored(str(exc)))
        if after < last_clock:
            return Collection(
                origin,
                samples,
                total,
                errored(f"{name}: monotonic clock regressed after runner call"),
            )
        last_clock = after
        consumed_time = max(after - started, reported_elapsed)
        if consumed_time >= timeout_value:
            return Collection(
                origin,
                samples,
                total,
                errored(
                    f"{name}: observation iteration deadline exhausted after runner result",
                    elapsed=consumed_time,
                    timeout=timeout_value,
                ),
            )
    return Collection(origin, samples, total)


def _command_result(
    sample: CommandSample,
    expected: CommandSpec,
    parser: Callable[[bytes], Evaluation],
) -> Evaluation:
    if not isinstance(sample, CommandSample):
        return errored("command sample has the wrong type")
    if sample.envelope.command != expected:
        return errored(
            "command sample envelope does not match its expected query/source/argv",
            query=expected.query,
        )
    if not sample.envelope.complete:
        return errored("command sample is truncated or incomplete", query=expected.query)
    if sample.returncode != 0:
        return errored(
            "read-only command failed",
            returncode=sample.returncode,
            query=expected.query,
        )
    if sample.stderr:
        return errored("read-only command wrote stderr", query=expected.query)
    try:
        result = parser(sample.stdout)
    except Exception as exc:
        return errored(
            f"predicate raised {type(exc).__name__}: {exc}", query=expected.query
        )
    if not isinstance(result, Evaluation):
        return errored("predicate returned the wrong result type", query=expected.query)
    return result


def _collection_proof_kind(collection: Collection) -> ProofKind:
    if collection.origin is ObservationOrigin.FIXTURE:
        return ProofKind.FIXTURE_COLLECTION
    return ProofKind.CAPTURED_OBSERVATION


def _collection_ready(
    collection: Collection, commands: Mapping[str, CommandSpec], gate: str
) -> Evaluation | None:
    if not isinstance(collection, Collection):
        return errored(f"{gate}: collection has the wrong type")
    if collection.error is not None:
        return collection.error
    required = frozenset(commands)
    observed = frozenset(collection.samples)
    if observed != required:
        return errored(
            f"{gate} sample key set mismatch",
            missing=sorted(required - observed),
            extra=sorted(observed - required),
        )
    return None


@dataclasses.dataclass(frozen=True)
class G1Topology:
    client_a: str
    client_b: str
    gateway_1: str
    gateway_2: str

    def __post_init__(self) -> None:
        for field in dataclasses.fields(self):
            _container_id(getattr(self, field.name), field.name)
        if len({getattr(self, field.name) for field in dataclasses.fields(self)}) != 4:
            raise ValueError("G1 clients and the two gateways must have distinct IDs")


G1_CLIENT_EXPECTATIONS = {
    "client_a": BGPSummaryExpectation(
        "client A", 200, "default", {"169.254.254.1": 100, "169.254.254.5": 100}, "client"
    ),
    "client_b": BGPSummaryExpectation(
        "client B", 201, "default", {"169.254.254.1": 100, "169.254.254.5": 100}, "client"
    ),
}
G1_GATEWAY_EXPECTATIONS = {
    "gateway_100": BGPSummaryExpectation("gateway VRF 100", 100, "ovnvrf100", {"169.254.254.2": 200}, "gateway"),
    "gateway_200": BGPSummaryExpectation("gateway VRF 200", 100, "ovnvrf200", {"169.254.254.6": 200}, "gateway"),
    "gateway_300": BGPSummaryExpectation("gateway VRF 300", 100, "ovnvrf300", {"169.254.254.2": 201}, "gateway"),
    "gateway_400": BGPSummaryExpectation("gateway VRF 400", 100, "ovnvrf400", {"169.254.254.6": 201}, "gateway"),
}


G1_GATEWAY_ROLES = {
    "gateway_100": ("gateway_1", "ovnvrf100"),
    "gateway_200": ("gateway_2", "ovnvrf200"),
    "gateway_300": ("gateway_1", "ovnvrf300"),
    "gateway_400": ("gateway_2", "ovnvrf400"),
}


def _command_spec(query: str, source_id: str, *argv: str) -> CommandSpec:
    return CommandSpec(query, source_id, ("docker", "exec", source_id, *argv))


def g1_commands(topology: G1Topology) -> dict[str, CommandSpec]:
    commands: dict[str, CommandSpec] = {}
    for name in ("client_a", "client_b"):
        container = getattr(topology, name)
        query = name + ".bgp"
        commands[query] = _command_spec(
            query, container, "vtysh", "-c",
            "show bgp ipv4 unicast summary established json",
        )
        query = name + ".rib"
        commands[query] = _command_spec(
            query, container, "vtysh", "-c", f"show ip route {PREFIX}",
        )
        query = name + ".fib"
        commands[query] = _command_spec(
            query, container, "ip", "-4", "route", "show", "exact", PREFIX,
        )
    for name, (container_field, vrf) in G1_GATEWAY_ROLES.items():
        query = name + ".bgp"
        container = getattr(topology, container_field)
        commands[query] = _command_spec(
            query, container, "vtysh", "-c",
            f"show bgp vrf {vrf} ipv4 unicast summary established json",
        )
    return commands


def evaluate_g1_samples(collection: Collection, topology: G1Topology) -> Evaluation:
    commands = g1_commands(topology)
    problem = _collection_ready(collection, commands, "G1")
    if problem is not None:
        return problem
    samples = collection.samples
    results: dict[str, Evaluation] = {}
    for name, expectation in G1_CLIENT_EXPECTATIONS.items():
        query = name + ".bgp"
        results[name + ".bgp"] = _command_result(
            samples[query], commands[query],
            lambda raw, exp=expectation: evaluate_bgp_summary(raw, exp),
        )
        hops = frozenset({("169.254.254.1", "eth1"), ("169.254.254.5", "eth2")})
        query = name + ".rib"
        results[name + ".rib"] = _command_result(
            samples[query], commands[query],
            lambda raw, expected=hops: evaluate_frr_ecmp_route(raw, prefix=PREFIX, expected_hops=expected),
        )
        query = name + ".fib"
        results[name + ".fib"] = _command_result(
            samples[query], commands[query],
            lambda raw, expected=hops: evaluate_linux_ecmp_route(raw, prefix=PREFIX, expected_hops=expected),
        )
    for name, expectation in G1_GATEWAY_EXPECTATIONS.items():
        query = name + ".bgp"
        results[name + ".bgp"] = _command_result(
            samples[query], commands[query],
            lambda raw, exp=expectation: evaluate_bgp_summary(raw, exp),
        )
    return combine_results(results, proof_kind=_collection_proof_kind(collection))


def collect_g1_iteration(
    runner: RuntimeRunner,
    topology: G1Topology,
    *,
    timeout: float,
    io_budget: int,
) -> tuple[Evaluation, int]:
    collection = collect_fixed_commands(
        runner, g1_commands(topology), timeout=timeout, io_budget=io_budget
    )
    if collection.error is not None:
        return collection.error, collection.io_bytes
    return evaluate_g1_samples(collection, topology), collection.io_bytes


@dataclasses.dataclass(frozen=True)
class EVPNTenantSpec:
    role: "TenantRole"
    peer_id: str
    chassis_id: str

    def __post_init__(self) -> None:
        if not isinstance(self.role, TenantRole):
            raise TypeError("tenant role must be a TenantRole member")
        _container_id(self.peer_id, self.label + ".peer_id")
        _container_id(self.chassis_id, self.label + ".chassis_id")
        if self.peer_id == self.chassis_id:
            raise ValueError("a tenant peer and chassis must have distinct IDs")

    @property
    def label(self) -> str:
        return "tenant A" if self.role is TenantRole.A else "tenant B"

    @property
    def peer_vty_socket(self) -> str | None:
        return None if self.role is TenantRole.A else "/run/frr/x05"

    @property
    def vni(self) -> int:
        return 50100 if self.role is TenantRole.A else 50200

    @property
    def peer_vtep(self) -> str:
        return "170.168.0.7" if self.role is TenantRole.A else "170.168.0.8"

    @property
    def chassis_vtep(self) -> str:
        return "170.168.0.5" if self.role is TenantRole.A else "170.168.0.6"

    @property
    def client_vrf(self) -> str:
        return "vrf-evpn-client" if self.role is TenantRole.A else "vrf-x05-peer"

    @property
    def client_bridge(self) -> str:
        return "br-evpn-client" if self.role is TenantRole.A else "br-x05-peer"

    @property
    def client_vxlan(self) -> str:
        return "vxlan-m03-peer" if self.role is TenantRole.A else "vxlan-x05-pr"

    @property
    def client_table(self) -> int:
        return 50100 if self.role is TenantRole.A else 50200

    @property
    def peer_source(self) -> str:
        return "10.250.0.1" if self.role is TenantRole.A else "10.251.0.1"

    @property
    def sentinel_ip(self) -> str:
        return "192.168.100.11" if self.role is TenantRole.A else "192.168.100.12"

    @property
    def tenant_vrf(self) -> str:
        return "ovnvrf-tenant" if self.role is TenantRole.A else "ovnvrf-x05-b"

    @property
    def tenant_bridge(self) -> str:
        return "br-evpn-tenant" if self.role is TenantRole.A else "br-x05-b"

    @property
    def tenant_table(self) -> int:
        return 300 if self.role is TenantRole.A else 400

    @property
    def lrp(self) -> str:
        return "lrp-mgc-tenant" if self.role is TenantRole.A else "lrp-x05-tenant-b"

    @property
    def external_lrp(self) -> str:
        return "lrp-x05-300-external" if self.role is TenantRole.A else "lrp-x05-400-external"

    @property
    def external_nexthop(self) -> str:
        return "169.254.254.2" if self.role is TenantRole.A else "169.254.254.6"

    @property
    def public_prefix(self) -> str:
        return "10.0.0.0/16"


class TenantRole(enum.StrEnum):
    A = "A"
    B = "B"


@dataclasses.dataclass(frozen=True)
class G2Topology:
    peer_a: str
    peer_b: str
    chassis_a: str
    chassis_b: str
    central_id: str

    def __post_init__(self) -> None:
        for field in dataclasses.fields(self):
            _container_id(getattr(self, field.name), field.name)
        if len({getattr(self, field.name) for field in dataclasses.fields(self)}) != 5:
            raise ValueError("G2 peer, chassis and central IDs must all be distinct")

    @property
    def tenant_a(self) -> EVPNTenantSpec:
        return EVPNTenantSpec(TenantRole.A, self.peer_a, self.chassis_a)

    @property
    def tenant_b(self) -> EVPNTenantSpec:
        return EVPNTenantSpec(TenantRole.B, self.peer_b, self.chassis_b)


def _peer_vtysh(query: str, spec: EVPNTenantSpec, command: str) -> CommandSpec:
    argv = ["vtysh"]
    if spec.peer_vty_socket is not None:
        argv.extend(("--vty_socket", spec.peer_vty_socket))
    argv.extend(("-c", command))
    return _command_spec(query, spec.peer_id, *argv)


def g2_commands(topology: G2Topology) -> dict[str, CommandSpec]:
    commands: dict[str, CommandSpec] = {}
    for label, spec in (("a", topology.tenant_a), ("b", topology.tenant_b)):
        query = label + ".type5"
        commands[query] = _peer_vtysh(
            query, spec, f"show bgp l2vpn evpn route rd all prefix {PREFIX}"
        )
        query = label + ".rib"
        commands[query] = _peer_vtysh(
            query, spec, f"show ip route vrf {spec.client_vrf} {PREFIX}"
        )
        query = label + ".fib"
        commands[query] = _command_spec(
            query, spec.peer_id, "ip", "-4", "route", "show",
            "table", str(spec.client_table), "exact", PREFIX,
        )
        query = label + ".vni"
        commands[query] = _peer_vtysh(query, spec, f"show evpn vni {spec.vni}")
        query = label + ".remote_vtep"
        commands[query] = _command_spec(
            query, spec.chassis_id, "ovn-appctl", "-t",
            "ovn-controller", "evpn/remote-vtep-list",
        )
        query = label + ".peer_get"
        commands[query] = _command_spec(
            query, spec.peer_id, "ip", "-4", "route", "get",
            spec.sentinel_ip, "from", spec.peer_source, "vrf", spec.client_vrf,
        )
        query = label + ".tenant_local"
        commands[query] = _command_spec(
            query, spec.chassis_id, "ip", "-4", "route", "show",
            "table", str(spec.tenant_table), "exact", PREFIX,
        )
        query = label + ".tenant_return"
        commands[query] = _command_spec(
            query, spec.chassis_id, "ip", "-4", "route", "show",
            "table", str(spec.tenant_table), "exact", spec.peer_source + "/32",
        )
        query = label + ".tenant_get"
        commands[query] = _command_spec(
            query, spec.chassis_id, "ip", "-4", "route", "get",
            spec.peer_source, "vrf", spec.tenant_vrf,
        )
    query = "sb.port_a"
    commands[query] = _command_spec(
        query, topology.central_id, "ovn-sbctl", "--format=json",
        "--data=json", "--no-headings", "--columns=_uuid,logical_port,datapath",
        "find", "Port_Binding", "logical_port=" + topology.tenant_a.lrp,
    )
    query = "sb.port_b"
    commands[query] = _command_spec(
        query, topology.central_id, "ovn-sbctl", "--format=json",
        "--data=json", "--no-headings", "--columns=_uuid,logical_port,datapath",
        "find", "Port_Binding", "logical_port=" + topology.tenant_b.lrp,
    )
    query = "sb.port_300"
    commands[query] = _command_spec(
        query, topology.central_id, "ovn-sbctl", "--format=json",
        "--data=json", "--no-headings", "--columns=_uuid,logical_port,datapath",
        "find", "Port_Binding", "logical_port=" + topology.tenant_a.external_lrp,
    )
    query = "sb.port_400"
    commands[query] = _command_spec(
        query, topology.central_id, "ovn-sbctl", "--format=json",
        "--data=json", "--no-headings", "--columns=_uuid,logical_port,datapath",
        "find", "Port_Binding", "logical_port=" + topology.tenant_b.external_lrp,
    )
    query = "sb.learned_routes"
    commands[query] = _command_spec(
        query, topology.central_id, "ovn-sbctl", "--format=json",
        "--data=json", "--no-headings",
        "--columns=_uuid,ip_prefix,nexthop,logical_port", "list", "Learned_Route",
    )
    return commands


def evaluate_g2_samples(
    collection: Collection, topology: G2Topology
) -> Evaluation:
    commands = g2_commands(topology)
    problem = _collection_ready(collection, commands, "G2")
    if problem is not None:
        return problem
    samples = collection.samples
    results: dict[str, Evaluation] = {}
    tenant_bindings: dict[str, PortBindingProof] = {}
    external_bindings: dict[str, PortBindingProof] = {}
    for query, expected_port, target in (
        ("sb.port_a", topology.tenant_a.lrp, tenant_bindings),
        ("sb.port_b", topology.tenant_b.lrp, tenant_bindings),
        ("sb.port_300", topology.tenant_a.external_lrp, external_bindings),
        ("sb.port_400", topology.tenant_b.external_lrp, external_bindings),
    ):
        def parse_binding(
            raw: bytes, *, port: str = expected_port, sink: dict = target
        ) -> Evaluation:
            result, proof = evaluate_port_bindings(
                raw, expected_ports=frozenset({port})
            )
            if result.outcome is Outcome.PASS:
                sink.update(proof)
            return result

        results[query] = _command_result(
            samples[query], commands[query], parse_binding
        )
    binding_result = combine_results(
        {name: results[name] for name in ("sb.port_a", "sb.port_b")}
    )
    if binding_result.outcome is Outcome.PASS:
        if len({proof.uuid for proof in tenant_bindings.values()}) != 2:
            binding_result = errored("A/B SB queries returned a duplicate Port_Binding UUID")
        elif len({proof.datapath for proof in tenant_bindings.values()}) != 2:
            binding_result = failed("A/B LRP Port_Bindings share a datapath")
    results["sb.port_bindings"] = binding_result
    for label, spec in (("a", topology.tenant_a), ("b", topology.tenant_b)):
        query = label + ".type5"
        results[label + ".type5"] = _command_result(
            samples[query], commands[query],
            lambda raw, item=spec: evaluate_type5_route(raw, prefix=PREFIX, vni=item.vni, next_hop=item.chassis_vtep),
        )
        query = label + ".rib"
        results[label + ".rib"] = _command_result(
            samples[query], commands[query],
            lambda raw, item=spec: evaluate_frr_single_route(raw, prefix=PREFIX, next_hop=item.chassis_vtep, interface=item.client_bridge),
        )
        query = label + ".fib"
        results[label + ".fib"] = _command_result(
            samples[query], commands[query],
            lambda raw, item=spec: evaluate_linux_single_route(raw, prefix=PREFIX, next_hop=item.chassis_vtep, interface=item.client_bridge),
        )
        query = label + ".vni"
        results[label + ".vni"] = _command_result(
            samples[query], commands[query],
            lambda raw, item=spec: evaluate_vni(
                raw,
                vni=item.vni,
                vrf=item.client_vrf,
                bridge=item.client_bridge,
                local_vtep=item.peer_vtep,
                vxlan_interface=item.client_vxlan,
            ),
        )
        query = label + ".remote_vtep"
        results[label + ".remote_vtep"] = _command_result(
            samples[query], commands[query],
            lambda raw, item=spec: evaluate_remote_vtep(raw, remote_vtep=item.peer_vtep, vni=item.vni),
        )
        query = label + ".peer_get"
        results[label + ".peer_get"] = _command_result(
            samples[query], commands[query],
            lambda raw, item=spec: evaluate_route_get(raw, destination=item.sentinel_ip, source=item.peer_source, next_hop=item.chassis_vtep, interface=item.client_bridge, table=item.client_table),
        )
        query = label + ".tenant_local"
        results[label + ".tenant_local"] = _command_result(
            samples[query], commands[query],
            lambda raw: evaluate_blackhole_route(raw, prefix=PREFIX),
        )
        query = label + ".tenant_return"
        results[label + ".tenant_return"] = _command_result(
            samples[query], commands[query],
            lambda raw, item=spec: evaluate_linux_single_route(raw, prefix=item.peer_source + "/32", next_hop=item.peer_vtep, interface=item.tenant_bridge),
        )
        query = label + ".tenant_get"
        results[label + ".tenant_get"] = _command_result(
            samples[query], commands[query],
            lambda raw, item=spec: evaluate_route_get(raw, destination=item.peer_source, source=None, next_hop=item.peer_vtep, interface=item.tenant_bridge, table=item.tenant_table),
        )
    query = "sb.learned_routes"
    if (
        binding_result.outcome is Outcome.PASS
        and len(tenant_bindings) == 2
        and len(external_bindings) == 2
    ):
        scope = frozenset(
            {proof.uuid for proof in tenant_bindings.values()}
            | {proof.uuid for proof in external_bindings.values()}
        )
        expected_routes = {
            (topology.tenant_a.peer_source, tenant_bindings[topology.tenant_a.lrp].uuid):
                topology.tenant_a.peer_vtep,
            (topology.tenant_b.peer_source, tenant_bindings[topology.tenant_b.lrp].uuid):
                topology.tenant_b.peer_vtep,
            (topology.tenant_a.public_prefix,
             external_bindings[topology.tenant_a.external_lrp].uuid):
                topology.tenant_a.external_nexthop,
            (topology.tenant_b.public_prefix,
             external_bindings[topology.tenant_b.external_lrp].uuid):
                topology.tenant_b.external_nexthop,
        }
        results["sb.learned_routes"] = _command_result(
            samples[query], commands[query],
            lambda raw: evaluate_learned_routes(raw, expected=expected_routes, scope=scope),
        )
    else:
        results["sb.learned_routes"] = _command_result(
            samples[query],
            commands[query],
            lambda _raw: retry(
                "Learned_Route binding waits for valid Port_Bindings"
            ),
        )
    return combine_results(results, proof_kind=_collection_proof_kind(collection))


def collect_g2_iteration(
    runner: RuntimeRunner,
    topology: G2Topology,
    *,
    timeout: float,
    io_budget: int,
) -> tuple[Evaluation, int]:
    collection = collect_fixed_commands(
        runner, g2_commands(topology), timeout=timeout, io_budget=io_budget
    )
    if collection.error is not None:
        return collection.error, collection.io_bytes
    return evaluate_g2_samples(collection, topology), collection.io_bytes


@dataclasses.dataclass(frozen=True)
class CASBaseline:
    a_ls_uuid: str
    b_ls_uuid: str
    nb_lsp_uuid: str
    nb_lsp_name: str
    a_ports: frozenset[str]
    b_ports: frozenset[str]
    sb_logical_port: str
    sb_port_binding_uuid: str
    a_sentinel_datapath: str
    b_sentinel_datapath: str

    def __post_init__(self) -> None:
        if not isinstance(self.a_ports, frozenset) or not isinstance(
            self.b_ports, frozenset
        ):
            raise TypeError("CAS port sets must be frozensets")
        for field in (
            "a_ls_uuid",
            "b_ls_uuid",
            "nb_lsp_uuid",
            "sb_port_binding_uuid",
            "a_sentinel_datapath",
            "b_sentinel_datapath",
        ):
            if UUID_RE.fullmatch(getattr(self, field)) is None:
                raise ValueError(f"{field} is not a UUID")
        if (
            not isinstance(self.nb_lsp_name, str)
            or not isinstance(self.sb_logical_port, str)
            or not self.nb_lsp_name
            or self.nb_lsp_name != self.sb_logical_port
        ):
            raise ValueError("NB LSP name must identify the captured SB logical_port")
        for value in self.a_ports | self.b_ports:
            if UUID_RE.fullmatch(value) is None:
                raise ValueError("CAS port set contains a non-UUID")
        if self.nb_lsp_uuid in self.a_ports or self.nb_lsp_uuid not in self.b_ports:
            raise ValueError("CAS baseline must have the LSP solely in B")
        if self.a_ls_uuid == self.b_ls_uuid:
            raise ValueError("A/B logical switches must be distinct")
        if self.a_sentinel_datapath == self.b_sentinel_datapath:
            raise ValueError("A/B tenant sentinel datapaths must be distinct")


@dataclasses.dataclass(frozen=True)
class CASObservation:
    a_ls_uuid: str
    b_ls_uuid: str
    nb_lsp_uuid: str
    nb_lsp_name: str
    a_ports: frozenset[str]
    b_ports: frozenset[str]
    parent_ls_uuids: frozenset[str]
    sb_logical_port: str | None
    sb_port_binding_uuid: str | None
    sb_datapath: str | None

    def __post_init__(self) -> None:
        for field in ("a_ls_uuid", "b_ls_uuid", "nb_lsp_uuid"):
            if UUID_RE.fullmatch(getattr(self, field)) is None:
                raise ValueError(f"{field} is not a UUID")
        if not isinstance(self.nb_lsp_name, str) or not self.nb_lsp_name:
            raise ValueError("nb_lsp_name must be nonempty")
        for field in ("a_ports", "b_ports", "parent_ls_uuids"):
            values = getattr(self, field)
            if not isinstance(values, frozenset) or any(
                UUID_RE.fullmatch(value) is None for value in values
            ):
                raise ValueError(f"{field} must be a frozenset of UUIDs")
        if self.sb_logical_port is not None and not self.sb_logical_port:
            raise ValueError("sb_logical_port must be nonempty when present")
        for field in ("sb_port_binding_uuid", "sb_datapath"):
            value = getattr(self, field)
            if value is not None and UUID_RE.fullmatch(value) is None:
                raise ValueError(f"{field} must be a UUID when present")
        sb_values = (
            self.sb_logical_port,
            self.sb_port_binding_uuid,
            self.sb_datapath,
        )
        if any(value is not None for value in sb_values) and not all(
            value is not None for value in sb_values
        ):
            raise ValueError("SB observation fields must be all present or all absent")


class CASStage(enum.StrEnum):
    MOVED_TO_A = "MOVED_TO_A"
    RESTORED_TO_B = "RESTORED_TO_B"


def evaluate_cas_postcondition(
    baseline: CASBaseline, observation: CASObservation, stage: CASStage
) -> Evaluation:
    """Evaluate exact complete NB sets, UUID continuity, sole parent and SB."""

    if (
        observation.a_ls_uuid != baseline.a_ls_uuid
        or observation.b_ls_uuid != baseline.b_ls_uuid
    ):
        return failed("CAS logical-switch UUID changed")
    if (
        observation.nb_lsp_uuid != baseline.nb_lsp_uuid
        or observation.nb_lsp_name != baseline.nb_lsp_name
    ):
        return failed("CAS moved or replaced the captured NB LSP identity")
    if stage is CASStage.MOVED_TO_A:
        expected_a = baseline.a_ports | {baseline.nb_lsp_uuid}
        expected_b = baseline.b_ports - {baseline.nb_lsp_uuid}
        expected_parent = frozenset({baseline.a_ls_uuid})
        expected_datapath = baseline.a_sentinel_datapath
    elif stage is CASStage.RESTORED_TO_B:
        expected_a = baseline.a_ports
        expected_b = baseline.b_ports
        expected_parent = frozenset({baseline.b_ls_uuid})
        expected_datapath = baseline.b_sentinel_datapath
    else:
        return errored("unknown CAS postcondition stage")
    if observation.a_ports != expected_a or observation.b_ports != expected_b:
        return failed(
            "CAS complete parent port sets do not match",
            expected_a=sorted(expected_a),
            observed_a=sorted(observation.a_ports),
            expected_b=sorted(expected_b),
            observed_b=sorted(observation.b_ports),
        )
    if observation.parent_ls_uuids != expected_parent:
        return failed("CAS LSP does not have the sole expected parent", parents=sorted(observation.parent_ls_uuids))
    if observation.sb_logical_port is None:
        return retry("SB Port_Binding has not appeared for the unchanged LSP")
    if observation.sb_logical_port != baseline.sb_logical_port:
        return failed("SB logical_port changed or a different row was queried")
    if observation.sb_port_binding_uuid != baseline.sb_port_binding_uuid:
        return failed("SB Port_Binding UUID was replaced")
    if observation.sb_datapath != expected_datapath:
        previous_datapath = (
            baseline.b_sentinel_datapath
            if stage is CASStage.MOVED_TO_A
            else baseline.a_sentinel_datapath
        )
        if observation.sb_datapath == previous_datapath:
            return retry(
                "NB CAS is exact but SB remains on the known previous datapath",
                expected=expected_datapath,
                observed=observation.sb_datapath,
            )
        return failed(
            "SB Port_Binding moved to an unknown tenant datapath",
            expected=expected_datapath,
            previous=previous_datapath,
            observed=observation.sb_datapath,
        )
    return passed("CAS NB sets, UUID, sole parent and SB datapath all match")


@dataclasses.dataclass(frozen=True)
class IterationReport:
    evaluation: Evaluation
    io_bytes: int

    def __post_init__(self) -> None:
        if not isinstance(self.evaluation, Evaluation):
            raise TypeError("iteration evaluation must be an Evaluation")
        if isinstance(self.io_bytes, bool) or not isinstance(self.io_bytes, int) or self.io_bytes < 0:
            raise TypeError("iteration io_bytes must be a nonnegative integer")


@dataclasses.dataclass(frozen=True)
class PollBudget:
    max_attempts: int
    max_io_bytes: int
    per_attempt_timeout: float

    def __post_init__(self) -> None:
        if (
            isinstance(self.max_attempts, bool)
            or not isinstance(self.max_attempts, int)
            or self.max_attempts <= 0
        ):
            raise ValueError("max_attempts must be positive")
        if (
            isinstance(self.max_io_bytes, bool)
            or not isinstance(self.max_io_bytes, int)
            or self.max_io_bytes <= 0
        ):
            raise ValueError("max_io_bytes must be positive")
        if (
            isinstance(self.per_attempt_timeout, bool)
            or not isinstance(self.per_attempt_timeout, (int, float))
            or not math.isfinite(self.per_attempt_timeout)
            or self.per_attempt_timeout <= 0
        ):
            raise ValueError("per_attempt_timeout must be finite and positive")


@dataclasses.dataclass(frozen=True)
class PollReport:
    evaluation: Evaluation
    attempts: int
    io_bytes: int


def poll_retries(
    check: Callable[[int, int, float], IterationReport], budget: PollBudget
) -> PollReport:
    """Poll RETRY only; FAIL/ERROR are terminal and exhaustion is FAIL."""

    consumed = 0
    for attempt in range(1, budget.max_attempts + 1):
        remaining = budget.max_io_bytes - consumed
        if remaining <= 0:
            return PollReport(failed("poll I/O budget exhausted"), attempt - 1, consumed)
        try:
            report = check(attempt, remaining, float(budget.per_attempt_timeout))
        except Exception as exc:
            return PollReport(
                errored(f"poll callback raised {type(exc).__name__}: {exc}"),
                attempt,
                consumed,
            )
        if not isinstance(report, IterationReport):
            return PollReport(errored("poll callback returned the wrong type"), attempt, consumed)
        if not isinstance(report.evaluation, Evaluation):
            return PollReport(errored("poll callback returned an invalid evaluation"), attempt, consumed)
        consumed += report.io_bytes
        if consumed > budget.max_io_bytes:
            return PollReport(failed("poll I/O budget exhausted"), attempt, consumed)
        if report.evaluation.outcome is not Outcome.RETRY:
            return PollReport(report.evaluation, attempt, consumed)
    return PollReport(
        failed("poll attempt budget exhausted while observations remained RETRY"),
        budget.max_attempts,
        consumed,
    )


def dry_run_report() -> dict[str, Any]:
    return {
        "schema": "p004-x05-evaluator-dry-run-v1",
        "status": "DISABLED",
        "live_returncode": 75,
        "outcomes": [item.value for item in Outcome],
        "proof_kinds": [item.value for item in ProofKind],
        "collectors": ["G1", "G2"],
        "runner": "x05-runtime-live.py:Runner",
        "authoritative_x05_gate": False,
        "mutation": False,
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--execute", action="store_true")
    args = parser.parse_args(argv)
    if args.dry_run:
        print(json.dumps(dry_run_report(), sort_keys=True, separators=(",", ":")))
        return 0
    print("x05 evaluator live integration is disabled", file=sys.stderr)
    return 75


if __name__ == "__main__":
    raise SystemExit(main())
