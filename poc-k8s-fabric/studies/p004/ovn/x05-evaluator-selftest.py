#!/usr/bin/env python3
"""Deterministic local tests for the disabled X05 evaluator.

The A-side cases read recorded FRR formats from P004 evidence. Full A/B
collections use the typed FIXTURE origin, so their predicate success can
never be reported as an authoritative X05 gate.
"""

from __future__ import annotations

import contextlib
import copy
import importlib.util
import io
import json
import pathlib
import sys
from collections.abc import Mapping


sys.dont_write_bytecode = True
HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("x05_evaluator", HERE / "x05-evaluator.py")
assert SPEC and SPEC.loader
EVAL = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = EVAL
SPEC.loader.exec_module(EVAL)


EVIDENCE = (
    HERE.parents[2]
    / "evidence/P004/S002/2026-09-27T142620Z"
)
M03_PASS = EVIDENCE / "07-m03/causal-filter-pass-raw"


def peer(local_as: int, remote_as: int, *, gateway: bool = False) -> dict[str, object]:
    value: dict[str, object] = {
        "hostname": "synthetic-peer",
        "remoteAs": remote_as,
        "localAs": local_as,
        "version": 4,
        "msgRcvd": 10,
        "msgSent": 11,
        "tableVersion": 2,
        "outq": 0,
        "inq": 0,
        "peerUptime": "00:00:10",
        "peerUptimeMsec": 10000,
        "peerUptimeEstablishedEpoch": 1,
        "pfxRcd": 1,
        "pfxSnt": 1,
        "state": "Established",
        "peerState": "OK",
        "connectionsEstablished": 1,
        "connectionsDropped": 0,
        "idType": "ipv4",
    }
    if gateway:
        value["softwareVersion"] = "n/a"
    return value


def summary(
    local_as: int,
    vrf: str,
    peers: dict[str, int],
    *,
    gateway: bool = False,
) -> dict[str, object]:
    return {
        "routerId": next(iter(peers)),
        "as": local_as,
        "vrfId": 8 if gateway else 0,
        "vrfName": vrf,
        "tableVersion": 2,
        "ribCount": 2,
        "ribMemory": 320,
        "peerCount": len(peers),
        "peerMemory": 30696,
        "peers": {
            address: peer(local_as, remote_as, gateway=gateway)
            for address, remote_as in peers.items()
        },
        "failedPeers": 0,
        "displayedPeers": len(peers),
        "totalPeers": len(peers),
        "dynamicPeers": 0,
        "bestPath": {"multiPathRelax": "false"},
    }


def encoded(value: object) -> bytes:
    return json.dumps(value, separators=(",", ":")).encode()


def ovs_json(headings: list[str], rows: list[list[object]]) -> bytes:
    return encoded({"headings": headings, "data": rows})


def ovs_uuid(value: str) -> list[str]:
    return ["uuid", value]


CLIENT_A = summary(
    200,
    "default",
    {"169.254.254.1": 100, "169.254.254.5": 100},
)
CLIENT_B_SYNTHETIC = summary(
    201,
    "default",
    {"169.254.254.1": 100, "169.254.254.5": 100},
)
GATEWAY_300_SYNTHETIC = summary(
    100, "ovnvrf300", {"169.254.254.2": 201}, gateway=True
)
GATEWAY_400_SYNTHETIC = summary(
    100, "ovnvrf400", {"169.254.254.6": 201}, gateway=True
)


def assert_outcome(result: EVAL.Evaluation, expected: EVAL.Outcome) -> None:
    assert result.outcome is expected, result


def fixture_sample(
    command: EVAL.CommandSpec,
    stdout: bytes,
    *,
    returncode: int = 0,
    stderr: bytes = b"",
    complete: bool = True,
) -> EVAL.CommandSample:
    return EVAL.CommandSample(
        EVAL.ObservationEnvelope(command, EVAL.ObservationOrigin.FIXTURE, complete),
        returncode,
        stdout,
        stderr,
        0.01,
    )


def fixture_collection(
    commands: Mapping[str, EVAL.CommandSpec], outputs: Mapping[str, bytes]
) -> EVAL.Collection:
    samples = {
        query: fixture_sample(command, outputs[query])
        for query, command in commands.items()
    }
    return EVAL.Collection(
        EVAL.ObservationOrigin.FIXTURE,
        samples,
        sum(len(sample.stdout) + len(sample.stderr) for sample in samples.values()),
    )


def test_strict_bgp_parsing() -> None:
    assert_outcome(
        EVAL.evaluate_bgp_summary(encoded(CLIENT_A), EVAL.G1_CLIENT_EXPECTATIONS["client_a"]),
        EVAL.Outcome.PASS,
    )
    assert_outcome(
        EVAL.evaluate_bgp_summary(
            encoded(CLIENT_B_SYNTHETIC),
            EVAL.G1_CLIENT_EXPECTATIONS["client_b"],
        ),
        EVAL.Outcome.PASS,
    )

    duplicate = encoded(CLIENT_A).decode().replace('"as":200', '"as":200,"as":200', 1)
    assert_outcome(
        EVAL.evaluate_bgp_summary(duplicate, EVAL.G1_CLIENT_EXPECTATIONS["client_a"]),
        EVAL.Outcome.ERROR,
    )
    nonfinite = encoded(CLIENT_A).decode().replace('"ribMemory":320', '"ribMemory":NaN')
    assert_outcome(
        EVAL.evaluate_bgp_summary(nonfinite, EVAL.G1_CLIENT_EXPECTATIONS["client_a"]),
        EVAL.Outcome.ERROR,
    )
    bool_count = copy.deepcopy(CLIENT_A)
    bool_count["peerCount"] = True
    assert_outcome(
        EVAL.evaluate_bgp_summary(encoded(bool_count), EVAL.G1_CLIENT_EXPECTATIONS["client_a"]),
        EVAL.Outcome.ERROR,
    )
    wrong_as = copy.deepcopy(CLIENT_A)
    wrong_as["peers"]["169.254.254.1"]["remoteAs"] = 64512
    assert_outcome(
        EVAL.evaluate_bgp_summary(encoded(wrong_as), EVAL.G1_CLIENT_EXPECTATIONS["client_a"]),
        EVAL.Outcome.FAIL,
    )
    extra_peer = copy.deepcopy(CLIENT_A)
    extra_peer["peers"]["169.254.254.9"] = peer(200, 100)
    extra_peer["peerCount"] = 3
    extra_peer["displayedPeers"] = 3
    extra_peer["totalPeers"] = 3
    assert_outcome(
        EVAL.evaluate_bgp_summary(encoded(extra_peer), EVAL.G1_CLIENT_EXPECTATIONS["client_a"]),
        EVAL.Outcome.FAIL,
    )
    converging = copy.deepcopy(CLIENT_A)
    converging["peers"]["169.254.254.1"]["state"] = "Active"
    converging["peers"]["169.254.254.1"]["peerState"] = "Active"
    assert_outcome(
        EVAL.evaluate_bgp_summary(
            encoded(converging), EVAL.G1_CLIENT_EXPECTATIONS["client_a"]
        ),
        EVAL.Outcome.RETRY,
    )
    unknown_state = copy.deepcopy(CLIENT_A)
    unknown_state["peers"]["169.254.254.1"]["state"] = (
        "future-garbage-state"
    )
    assert_outcome(
        EVAL.evaluate_bgp_summary(
            encoded(unknown_state), EVAL.G1_CLIENT_EXPECTATIONS["client_a"]
        ),
        EVAL.Outcome.ERROR,
    )
    contradictory_state = copy.deepcopy(CLIENT_A)
    contradictory_state["peers"]["169.254.254.1"]["state"] = "Active"
    assert_outcome(
        EVAL.evaluate_bgp_summary(
            encoded(contradictory_state),
            EVAL.G1_CLIENT_EXPECTATIONS["client_a"],
        ),
        EVAL.Outcome.FAIL,
    )
    contradictory_convergence = copy.deepcopy(converging)
    contradictory_convergence["peers"]["169.254.254.1"]["peerState"] = (
        "OpenSent"
    )
    assert_outcome(
        EVAL.evaluate_bgp_summary(
            encoded(contradictory_convergence),
            EVAL.G1_CLIENT_EXPECTATIONS["client_a"],
        ),
        EVAL.Outcome.FAIL,
    )


def test_actual_gateway_json() -> None:
    for vrf, name in ((100, "gateway_100"), (200, "gateway_200")):
        raw = (EVIDENCE / f"08-x05/gateway-vrf{vrf}-readonly-20260930.json").read_bytes()
        assert_outcome(
            EVAL.evaluate_bgp_summary(raw, EVAL.G1_GATEWAY_EXPECTATIONS[name]),
            EVAL.Outcome.PASS,
        )
    for fixture, name in (
        (GATEWAY_300_SYNTHETIC, "gateway_300"),
        (GATEWAY_400_SYNTHETIC, "gateway_400"),
    ):
        assert_outcome(
            EVAL.evaluate_bgp_summary(
                encoded(fixture), EVAL.G1_GATEWAY_EXPECTATIONS[name]
            ),
            EVAL.Outcome.PASS,
        )


def actual_a_routes() -> tuple[str, str]:
    text = (EVIDENCE / "04-a2-rib-readonly.txt").read_text()
    rib = text.split("=== client routes targeted ===\n", 1)[1].split(
        "\n\nBGP routing table entry", 1
    )[0]
    fib_table = text.split("=== client kernel ===\n", 1)[1].split(
        "=== gateway1 VRF RIB and BGP ===", 1
    )[0].strip()
    fib_lines = fib_table.splitlines()
    target_index = next(
        index
        for index, line in enumerate(fib_lines)
        if line.startswith(EVAL.PREFIX + " ")
    )
    target_end = target_index + 1
    while target_end < len(fib_lines) and fib_lines[target_end][:1].isspace():
        target_end += 1
    fib = "\n".join(fib_lines[target_index:target_end])
    return rib, fib


def move_known_after_selected(raw: bytes) -> bytes:
    lines = raw.splitlines()
    known = [line for line in lines if b"Known via " in line]
    assert len(known) == 1
    return b"\n".join([line for line in lines if line != known[0]] + known) + b"\n"


def move_paths_before_footer(raw: bytes) -> bytes:
    lines = raw.splitlines()
    paths = [line for line in lines if line.startswith(b"Paths:")]
    assert len(paths) == 1
    without_paths = [line for line in lines if line != paths[0]]
    footer_index = next(
        index
        for index, line in enumerate(without_paths)
        if line.startswith(b"Displayed ")
    )
    without_paths.insert(footer_index, paths[0])
    return b"\n".join(without_paths) + b"\n"


def test_actual_g1_routes_and_known_bad() -> None:
    rib, fib = actual_a_routes()
    hops = frozenset({("169.254.254.1", "eth1"), ("169.254.254.5", "eth2")})
    assert_outcome(
        EVAL.evaluate_frr_ecmp_route(rib, prefix=EVAL.PREFIX, expected_hops=hops),
        EVAL.Outcome.PASS,
    )
    assert_outcome(
        EVAL.evaluate_frr_ecmp_route(
            move_known_after_selected(rib.encode()),
            prefix=EVAL.PREFIX,
            expected_hops=hops,
        ),
        EVAL.Outcome.ERROR,
    )
    assert_outcome(
        EVAL.evaluate_linux_ecmp_route(fib, prefix=EVAL.PREFIX, expected_hops=hops),
        EVAL.Outcome.PASS,
    )
    unequal_weights = fib.replace("weight 1", "weight 256", 1)
    assert_outcome(
        EVAL.evaluate_linux_ecmp_route(
            unequal_weights, prefix=EVAL.PREFIX, expected_hops=hops
        ),
        EVAL.Outcome.PASS,
    )
    for invalid_weights in (
        fib.replace(" weight 1", ""),
        fib.replace("weight 1", "weight 0"),
        fib.replace("weight 1", "weight 257"),
        fib.replace("weight 1", "weight 4294967296"),
        fib.replace("weight 1", "weight " + "9" * 5000),
    ):
        assert_outcome(
            EVAL.evaluate_linux_ecmp_route(
                invalid_weights, prefix=EVAL.PREFIX, expected_hops=hops
            ),
            EVAL.Outcome.ERROR,
        )
    extra_hop = rib + "\n  * 169.254.254.9, via eth9, weight 1\n"
    assert_outcome(
        EVAL.evaluate_frr_ecmp_route(extra_hop, prefix=EVAL.PREFIX, expected_hops=hops),
        EVAL.Outcome.FAIL,
    )
    expected_onlink = rib.replace(
        "169.254.254.1, via eth1, weight 1",
        "169.254.254.1, via eth1 onlink, weight 1",
    )
    assert_outcome(
        EVAL.evaluate_frr_ecmp_route(
            expected_onlink, prefix=EVAL.PREFIX, expected_hops=hops
        ),
        EVAL.Outcome.PASS,
    )
    for extra_selected in (
        "  * 203.0.113.1, via eth9 onlink, weight 1",
        "  * unreachable (blackhole), weight 1",
        "  * 169.254.254.1, via eth1, weight 1",
    ):
        assert_outcome(
            EVAL.evaluate_frr_ecmp_route(
                rib.rstrip() + "\n" + extra_selected + "\n",
                prefix=EVAL.PREFIX,
                expected_hops=hops,
            ),
            EVAL.Outcome.FAIL,
        )
    without_selected = "\n".join(
        line for line in rib.splitlines() if not line.lstrip().startswith("* ")
    )
    assert_outcome(
        EVAL.evaluate_frr_ecmp_route(
            without_selected + "\n  * unreachable (blackhole), weight 1\n",
            prefix=EVAL.PREFIX,
            expected_hops=hops,
        ),
        EVAL.Outcome.FAIL,
    )
    for bad_weight in ("not-a-number", "0", "65536", "4294967296"):
        assert_outcome(
            EVAL.evaluate_frr_ecmp_route(
                rib.replace("weight 1", f"weight {bad_weight}", 1),
                prefix=EVAL.PREFIX,
                expected_hops=hops,
            ),
            EVAL.Outcome.ERROR,
        )
    rib_without_fib = EVAL.combine_results(
        {
            "rib": EVAL.evaluate_frr_ecmp_route(rib, prefix=EVAL.PREFIX, expected_hops=hops),
            "fib": EVAL.evaluate_linux_ecmp_route("", prefix=EVAL.PREFIX, expected_hops=hops),
        }
    )
    assert_outcome(rib_without_fib, EVAL.Outcome.RETRY)
    foreign_block = f"""{EVAL.PREFIX} proto bgp metric 20
    nexthop via 169.254.254.1 dev eth1 weight 1
    nexthop via 169.254.254.5 dev eth2 weight 1
203.0.113.0/24 proto bgp metric 20
    nexthop via 203.0.113.1 dev eth9 weight 1
"""
    assert_outcome(
        EVAL.evaluate_linux_ecmp_route(
            foreign_block, prefix=EVAL.PREFIX, expected_hops=hops
        ),
        EVAL.Outcome.FAIL,
    )
    for route_type in ("unreachable", "blackhole", "prohibit", "throw"):
        drop_route = f"""{route_type} {EVAL.PREFIX} proto bgp metric 20
    nexthop via 169.254.254.1 dev eth1 weight 1
    nexthop via 169.254.254.5 dev eth2 weight 1
"""
        assert_outcome(
            EVAL.evaluate_linux_ecmp_route(
                drop_route, prefix=EVAL.PREFIX, expected_hops=hops
            ),
            EVAL.Outcome.FAIL,
        )
    linkdown = f"""{EVAL.PREFIX} proto bgp metric 20
    nexthop via 169.254.254.1 dev eth1 weight 1 linkdown
    nexthop via 169.254.254.5 dev eth2 weight 1
"""
    assert_outcome(
        EVAL.evaluate_linux_ecmp_route(
            linkdown, prefix=EVAL.PREFIX, expected_hops=hops
        ),
        EVAL.Outcome.FAIL,
    )
    reordered_flags = f"""{EVAL.PREFIX} metric 20 proto bgp nhid 18
    nexthop via 169.254.254.1 dev eth1 weight 1 onlink
    nexthop via 169.254.254.5 dev eth2 onlink weight 1
"""
    assert_outcome(
        EVAL.evaluate_linux_ecmp_route(
            reordered_flags, prefix=EVAL.PREFIX, expected_hops=hops
        ),
        EVAL.Outcome.PASS,
    )
    wrong_partial = f"""{EVAL.PREFIX} proto bgp metric 20
    nexthop via 169.254.254.9 dev eth9 weight 1
"""
    assert_outcome(
        EVAL.evaluate_linux_ecmp_route(
            wrong_partial, prefix=EVAL.PREFIX, expected_hops=hops
        ),
        EVAL.Outcome.FAIL,
    )
    assert_outcome(
        EVAL.evaluate_frr_ecmp_route(
            "arbitrary nonempty garbage", prefix=EVAL.PREFIX, expected_hops=hops
        ),
        EVAL.Outcome.ERROR,
    )


def test_actual_g2_formats_and_known_bad() -> None:
    route_dir = M03_PASS / "positive-pre-negative"
    type5 = (route_dir / "m03-verify-type5-rib.txt").read_bytes()
    vni = (route_dir / "m03-verify-client-vni.txt").read_bytes()
    remote = (route_dir / "m03-verify-remote-vtep.txt").read_bytes()
    client_rib = (route_dir / "m03-verify-client-vrf-route.txt").read_bytes()
    client_fib = (route_dir / "m03-verify-client-kernel-route.txt").read_bytes()
    peer_get = (route_dir / "m03-verify-peer-route-get.txt").read_bytes()
    tenant_local = (route_dir / "m03-verify-tenant-vrf-route.txt").read_bytes()
    tenant_return = (route_dir / "m03-verify-tenant-return-route.txt").read_bytes()
    tenant_get = (route_dir / "m03-verify-tenant-route-get.txt").read_bytes()
    assert_outcome(
        EVAL.evaluate_type5_route(type5, prefix=EVAL.PREFIX, vni=50100, next_hop="170.168.0.5"),
        EVAL.Outcome.PASS,
    )
    assert_outcome(
        EVAL.evaluate_type5_route(
            move_paths_before_footer(type5),
            prefix=EVAL.PREFIX,
            vni=50100,
            next_hop="170.168.0.5",
        ),
        EVAL.Outcome.ERROR,
    )
    header_only = b"  Route [5]:[0]:[24]:[192.168.100.0] VNI 50100\n"
    assert EVAL.evaluate_type5_route(
        header_only, prefix=EVAL.PREFIX, vni=50100, next_hop="170.168.0.5"
    ).outcome is not EVAL.Outcome.PASS
    assert_outcome(
        EVAL.evaluate_type5_route(type5, prefix=EVAL.PREFIX, vni=50200, next_hop="170.168.0.5"),
        EVAL.Outcome.FAIL,
    )
    assert_outcome(
        EVAL.evaluate_vni(
            vni, vni=50100, vrf="vrf-evpn-client", bridge="br-evpn-client", local_vtep="170.168.0.7"
        ),
        EVAL.Outcome.PASS,
    )
    assert_outcome(
        EVAL.evaluate_vni(
            vni, vni=50100, vrf="vrf-evpn-client", bridge="br-evpn-client", local_vtep="170.168.0.8"
        ),
        EVAL.Outcome.FAIL,
    )
    assert_outcome(
        EVAL.evaluate_remote_vtep(remote, remote_vtep="170.168.0.7", vni=50100),
        EVAL.Outcome.PASS,
    )
    assert_outcome(
        EVAL.evaluate_remote_vtep(remote, remote_vtep="170.168.0.8", vni=50100),
        EVAL.Outcome.FAIL,
    )
    borrowed_path = """Route Distinguisher: 170.168.0.5:2
BGP routing table entry for 170.168.0.5:2:[5]:[0]:[24]:[192.168.100.0]
Paths: (1 available, best #1)
  Route [5]:[0]:[24]:[192.168.100.0] VNI 50100
BGP routing table entry for 170.168.0.9:2:[5]:[0]:[24]:[203.0.113.0]
Paths: (1 available, best #1)
  Route [5]:[0]:[24]:[203.0.113.0] VNI 50999
    170.168.0.5 from 170.168.0.5 (170.168.0.5)
Displayed 2 prefixes (2 paths)
"""
    assert_outcome(
        EVAL.evaluate_type5_route(
            borrowed_path,
            prefix=EVAL.PREFIX,
            vni=50100,
            next_hop="170.168.0.5",
        ),
        EVAL.Outcome.FAIL,
    )
    assert_outcome(
        EVAL.evaluate_frr_single_route(
            client_rib,
            prefix=EVAL.PREFIX,
            next_hop="170.168.0.5",
            interface="br-evpn-client",
        ),
        EVAL.Outcome.PASS,
    )
    assert_outcome(
        EVAL.evaluate_frr_single_route(
            move_known_after_selected(client_rib),
            prefix=EVAL.PREFIX,
            next_hop="170.168.0.5",
            interface="br-evpn-client",
        ),
        EVAL.Outcome.ERROR,
    )
    extra_blackhole = (
        client_rib.rstrip() + b"\n  * unreachable (blackhole), weight 1\n"
    )
    assert_outcome(
        EVAL.evaluate_frr_single_route(
            extra_blackhole,
            prefix=EVAL.PREFIX,
            next_hop="170.168.0.5",
            interface="br-evpn-client",
        ),
        EVAL.Outcome.FAIL,
    )
    without_selected = b"\n".join(
        line
        for line in client_rib.splitlines()
        if not line.lstrip().startswith(b"* ")
    )
    assert_outcome(
        EVAL.evaluate_frr_single_route(
            without_selected + b"\n  * unreachable (blackhole), weight 1\n",
            prefix=EVAL.PREFIX,
            next_hop="170.168.0.5",
            interface="br-evpn-client",
        ),
        EVAL.Outcome.FAIL,
    )
    for old, new in (
        (b"Status: Installed", b"Status: Not installed"),
        (b"Status: Installed", b"Status: Removed"),
        (b"Flags: Selected", b"Flags: Invalid"),
    ):
        assert old in client_rib
        assert_outcome(
            EVAL.evaluate_frr_single_route(
                client_rib.replace(old, new),
                prefix=EVAL.PREFIX,
                next_hop="170.168.0.5",
                interface="br-evpn-client",
            ),
            EVAL.Outcome.FAIL,
        )
    known_line = next(
        line for line in client_rib.splitlines() if b"Known via " in line
    )
    canonical_known = (
        b'  Known via "bgp", distance 20, metric 1000, tag 42(realm), '
        b"mtu 1500, vrf vrf-evpn-client, best"
    )
    assert_outcome(
        EVAL.evaluate_frr_single_route(
            client_rib.replace(known_line, canonical_known),
            prefix=EVAL.PREFIX,
            next_hop="170.168.0.5",
            interface="br-evpn-client",
        ),
        EVAL.Outcome.PASS,
    )
    assert_outcome(
        EVAL.evaluate_frr_single_route(
            client_rib.replace(
                known_line,
                canonical_known.replace(b"tag 42(realm)", b"tag 300"),
            ),
            prefix=EVAL.PREFIX,
            next_hop="170.168.0.5",
            interface="br-evpn-client",
        ),
        EVAL.Outcome.PASS,
    )
    for replacement in (
        known_line + b", removed",
        known_line.replace(b", best", b", removed, best"),
        known_line.replace(b", best", b", best, best"),
        known_line.replace(b"distance 20", b"distance 020"),
        known_line.replace(b"distance 20", b"distance 4294967296"),
        known_line.replace(b", vrf", b", tag 0, vrf"),
        known_line.replace(b", vrf", b", tag 256(realm), vrf"),
        known_line.replace(b", vrf", b", mtu 0, vrf"),
    ):
        assert_outcome(
            EVAL.evaluate_frr_single_route(
                client_rib.replace(known_line, replacement),
                prefix=EVAL.PREFIX,
                next_hop="170.168.0.5",
                interface="br-evpn-client",
            ),
            EVAL.Outcome.FAIL,
        )
    assert_outcome(
        EVAL.evaluate_linux_single_route(
            client_fib,
            prefix=EVAL.PREFIX,
            next_hop="170.168.0.5",
            interface="br-evpn-client",
        ),
        EVAL.Outcome.PASS,
    )
    assert_outcome(
        EVAL.evaluate_linux_single_route(
            client_fib.rstrip() + b" linkdown\n",
            prefix=EVAL.PREFIX,
            next_hop="170.168.0.5",
            interface="br-evpn-client",
        ),
        EVAL.Outcome.FAIL,
    )
    assert_outcome(
        EVAL.evaluate_route_get(
            peer_get,
            destination="192.168.100.10",
            source="10.250.0.1",
            next_hop="170.168.0.5",
            interface="br-evpn-client",
            table=50100,
        ),
        EVAL.Outcome.PASS,
    )
    assert_outcome(
        EVAL.evaluate_blackhole_route(tenant_local, prefix=EVAL.PREFIX),
        EVAL.Outcome.PASS,
    )
    assert_outcome(
        EVAL.evaluate_blackhole_route(
            f"blackhole {EVAL.PREFIX} nhid 12 metric 1000 proto ovn\n",
            prefix=EVAL.PREFIX,
        ),
        EVAL.Outcome.PASS,
    )
    for duplicate in (
        f"blackhole {EVAL.PREFIX} proto ovn metric 10 metric 20\n",
        f"blackhole {EVAL.PREFIX} proto ovn nhid 1 nhid 2\n",
    ):
        assert_outcome(
            EVAL.evaluate_blackhole_route(duplicate, prefix=EVAL.PREFIX),
            EVAL.Outcome.ERROR,
        )
    for malformed in (
        f"blackhole {EVAL.PREFIX} proto ovn expires 10\n",
        f"blackhole {EVAL.PREFIX} proto ovn metric\n",
    ):
        assert_outcome(
            EVAL.evaluate_blackhole_route(malformed, prefix=EVAL.PREFIX),
            EVAL.Outcome.ERROR,
        )
    assert_outcome(
        EVAL.evaluate_linux_single_route(
            tenant_return,
            prefix="10.250.0.1/32",
            next_hop="170.168.0.7",
            interface="br-evpn-tenant",
        ),
        EVAL.Outcome.PASS,
    )
    assert_outcome(
        EVAL.evaluate_route_get(
            tenant_get,
            destination="10.250.0.1",
            source=None,
            next_hop="170.168.0.7",
            interface="br-evpn-tenant",
            table=300,
        ),
        EVAL.Outcome.PASS,
    )
    assert_outcome(
        EVAL.evaluate_type5_route(
            "arbitrary nonempty garbage",
            prefix=EVAL.PREFIX,
            vni=50100,
            next_hop="170.168.0.5",
        ),
        EVAL.Outcome.ERROR,
    )
    duplicated_paths = type5.replace(
        b"Paths: (1 available, best #1)\n",
        b"Paths: (1 available, best #1)\nPaths: (1 available, best #1)\n",
    )
    assert_outcome(
        EVAL.evaluate_type5_route(
            duplicated_paths,
            prefix=EVAL.PREFIX,
            vni=50100,
            next_hop="170.168.0.5",
        ),
        EVAL.Outcome.ERROR,
    )
    contradictory_count = type5.replace(
        b"Paths: (1 available, best #1)", b"Paths: (2 available, best #1)"
    )
    assert_outcome(
        EVAL.evaluate_type5_route(
            contradictory_count,
            prefix=EVAL.PREFIX,
            vni=50100,
            next_hop="170.168.0.5",
        ),
        EVAL.Outcome.FAIL,
    )
    contradictory_best = type5.replace(b"best #1", b"best #99")
    assert_outcome(
        EVAL.evaluate_type5_route(
            contradictory_best,
            prefix=EVAL.PREFIX,
            vni=50100,
            next_hop="170.168.0.5",
        ),
        EVAL.Outcome.FAIL,
    )
    origin_line = (
        b"Origin incomplete, metric 1000, valid, external, "
        b"best (First path received)"
    )
    for replacement in (
        b"Origin invalid, metric 1000, valid, external, best",
        b"Origin incomplete, metric 1000, valid, external, removed, best",
        b"Origin incomplete, metric 1000, valid, external, not best",
        b"Origin incomplete, metric 1000, valid, external, best (Removed)",
        b"Origin incomplete, metric 1000, valid, external, best (not best)",
        b"Origin incomplete, metric 1000, valid, external, best (future reason)",
        b"Origin incomplete, metric 1000, valid, external, best (Invalid (internal error))",
    ):
        assert origin_line in type5
        assert_outcome(
            EVAL.evaluate_type5_route(
                type5.replace(origin_line, replacement),
                prefix=EVAL.PREFIX,
                vni=50100,
                next_hop="170.168.0.5",
            ),
            EVAL.Outcome.FAIL,
        )
    reordered_origin = type5.replace(
        origin_line,
        b"Origin incomplete, valid, best (First path received), "
        b"metric 1000, external",
    )
    assert_outcome(
        EVAL.evaluate_type5_route(
            reordered_origin,
            prefix=EVAL.PREFIX,
            vni=50100,
            next_hop="170.168.0.5",
        ),
        EVAL.Outcome.PASS,
    )
    for reason in ("Older Path", "Weight", "Local Pref", "AS Path"):
        rendered_reason = origin_line.replace(
            b"best (First path received)", f"best ({reason})".encode()
        )
        assert_outcome(
            EVAL.evaluate_type5_route(
                type5.replace(origin_line, rendered_reason),
                prefix=EVAL.PREFIX,
                vni=50100,
                next_hop="170.168.0.5",
            ),
            EVAL.Outcome.PASS,
        )
    bare_best = origin_line.replace(b"best (First path received)", b"best")
    assert_outcome(
        EVAL.evaluate_type5_route(
            type5.replace(origin_line, bare_best),
            prefix=EVAL.PREFIX,
            vni=50100,
            next_hop="170.168.0.5",
        ),
        EVAL.Outcome.PASS,
    )
    assert_outcome(
        EVAL.evaluate_vni(
            "arbitrary nonempty garbage",
            vni=50100,
            vrf="vrf-evpn-client",
            bridge="br-evpn-client",
            local_vtep="170.168.0.7",
        ),
        EVAL.Outcome.ERROR,
    )


def test_route_get_rejects_contradictory_or_unknown_extra_rows() -> None:
    valid = (
        "192.168.100.11 from 10.250.0.1 via 170.168.0.5 "
        "dev br-evpn-client table 50100 uid 0\n"
    )
    assert_outcome(
        EVAL.evaluate_route_get(
            valid,
            destination="192.168.100.11",
            source="10.250.0.1",
            next_hop="170.168.0.5",
            interface="br-evpn-client",
            table=50100,
        ),
        EVAL.Outcome.PASS,
    )
    assert_outcome(
        EVAL.evaluate_route_get(
            valid + "203.0.113.1 via 203.0.113.254 dev eth9 table 999\n",
            destination="192.168.100.11",
            source="10.250.0.1",
            next_hop="170.168.0.5",
            interface="br-evpn-client",
            table=50100,
        ),
        EVAL.Outcome.FAIL,
    )
    assert_outcome(
        EVAL.evaluate_route_get(
            valid + "unexpected footer\n",
            destination="192.168.100.11",
            source="10.250.0.1",
            next_hop="170.168.0.5",
            interface="br-evpn-client",
            table=50100,
        ),
        EVAL.Outcome.ERROR,
    )


def sb_fixture() -> tuple[bytes, bytes, dict[str, str]]:
    values = {
        "a_pb": "10000000-0000-4000-8000-000000000001",
        "b_pb": "20000000-0000-4000-8000-000000000001",
        "a_dp": "10000000-0000-4000-8000-000000000002",
        "b_dp": "20000000-0000-4000-8000-000000000002",
    }
    bindings = ovs_json(
        ["_uuid", "logical_port", "datapath"],
        [
            [ovs_uuid(values["a_pb"]), "lrp-mgc-tenant", ovs_uuid(values["a_dp"])],
            [ovs_uuid(values["b_pb"]), "lrp-x05-tenant-b", ovs_uuid(values["b_dp"])],
        ],
    )
    routes = ovs_json(
        ["_uuid", "ip_prefix", "nexthop", "logical_port"],
        [
            [ovs_uuid("10000000-0000-4000-8000-000000000003"), "10.250.0.1", "170.168.0.7", ovs_uuid(values["a_pb"])],
            [ovs_uuid("20000000-0000-4000-8000-000000000003"), "10.251.0.1/32", "170.168.0.8", ovs_uuid(values["b_pb"])],
        ],
    )
    return bindings, routes, values


def test_sb_scope_and_learned_routes() -> None:
    bindings, routes, values = sb_fixture()
    binding_result, proofs = EVAL.evaluate_port_bindings(
        bindings, expected_ports=frozenset({"lrp-mgc-tenant", "lrp-x05-tenant-b"})
    )
    assert_outcome(binding_result, EVAL.Outcome.PASS)
    assert_outcome(
        EVAL.evaluate_learned_routes(
            routes,
            expected={
                "10.250.0.1": ("170.168.0.7", values["a_pb"]),
                "10.251.0.1": ("170.168.0.8", values["b_pb"]),
            },
        ),
        EVAL.Outcome.PASS,
    )
    assert proofs["lrp-mgc-tenant"].datapath != proofs["lrp-x05-tenant-b"].datapath
    duplicated = json.loads(routes)
    duplicated["data"].append(copy.deepcopy(duplicated["data"][0]))
    duplicated["data"][-1][0] = ovs_uuid(
        "30000000-0000-4000-8000-000000000003"
    )
    assert_outcome(
        EVAL.evaluate_learned_routes(
            encoded(duplicated),
            expected={
                "10.250.0.1": ("170.168.0.7", values["a_pb"]),
                "10.251.0.1": ("170.168.0.8", values["b_pb"]),
            },
        ),
        EVAL.Outcome.FAIL,
    )
    duplicate_uuid = json.loads(routes)
    duplicate_uuid["data"][1][0] = copy.deepcopy(duplicate_uuid["data"][0][0])
    assert_outcome(
        EVAL.evaluate_learned_routes(
            encoded(duplicate_uuid),
            expected={
                "10.250.0.1": ("170.168.0.7", values["a_pb"]),
                "10.251.0.1": ("170.168.0.8", values["b_pb"]),
            },
        ),
        EVAL.Outcome.ERROR,
    )
    missing_a_wrong_b = ovs_json(
        ["_uuid", "ip_prefix", "nexthop", "logical_port"],
        [[
            ovs_uuid("20000000-0000-4000-8000-000000000003"),
            "10.251.0.1",
            "170.168.0.99",
            ovs_uuid(values["b_pb"]),
        ]],
    )
    assert_outcome(
        EVAL.evaluate_learned_routes(
            missing_a_wrong_b,
            expected={
                "10.250.0.1": ("170.168.0.7", values["a_pb"]),
                "10.251.0.1": ("170.168.0.8", values["b_pb"]),
            },
        ),
        EVAL.Outcome.FAIL,
    )


def test_ping_parsing() -> None:
    iputils = "PING target\n" + "".join(
        f"64 bytes from 192.168.100.11: icmp_seq={sequence} "
        "ttl=62 time=0.100 ms\n"
        for sequence in range(1, 6)
    ) + "5 packets transmitted, 5 received, 0% packet loss, time 4000ms\n"
    busybox = "PING target\n" + "".join(
        f"64 bytes from 192.168.100.12: seq={sequence} "
        "ttl=62 time=0.100 ms\n"
        for sequence in range(5)
    ) + "5 packets transmitted, 5 packets received, 0% packet loss\n"
    assert_outcome(EVAL.evaluate_ping(iputils, returncode=0, expect_reply=True), EVAL.Outcome.PASS)
    assert_outcome(EVAL.evaluate_ping(busybox, returncode=0, expect_reply=True), EVAL.Outcome.PASS)
    patterned_iputils = iputils.replace(
        "PING target\n", "PATTERN: 0x5a\nPING target\n"
    )
    assert_outcome(
        EVAL.evaluate_ping(
            patterned_iputils, returncode=0, expect_reply=True
        ),
        EVAL.Outcome.PASS,
    )
    mislabeled_busybox = busybox.replace("seq=", "icmp_seq=")
    assert_outcome(
        EVAL.evaluate_ping(
            mislabeled_busybox, returncode=0, expect_reply=True
        ),
        EVAL.Outcome.FAIL,
    )
    mixed = busybox.replace("seq=4", "icmp_seq=4")
    assert_outcome(
        EVAL.evaluate_ping(mixed, returncode=0, expect_reply=True),
        EVAL.Outcome.FAIL,
    )
    duplicate = busybox.replace("seq=4", "seq=3")
    assert_outcome(
        EVAL.evaluate_ping(duplicate, returncode=0, expect_reply=True),
        EVAL.Outcome.FAIL,
    )
    missing = busybox.replace(
        "64 bytes from 192.168.100.12: seq=4 ttl=62 time=0.100 ms\n",
        "",
    )
    assert_outcome(
        EVAL.evaluate_ping(missing, returncode=0, expect_reply=True),
        EVAL.Outcome.FAIL,
    )
    quiet_positive = "5 packets transmitted, 5 packets received, 0% packet loss\n"
    assert_outcome(
        EVAL.evaluate_ping(quiet_positive, returncode=0, expect_reply=True),
        EVAL.Outcome.FAIL,
    )
    negative = "5 packets transmitted, 0 received, 100% packet loss\n"
    assert_outcome(EVAL.evaluate_ping(negative, returncode=1, expect_reply=False), EVAL.Outcome.PASS)
    busybox_negative = (
        "5 packets transmitted, 0 packets received, 100% packet loss\n"
    )
    assert_outcome(
        EVAL.evaluate_ping(
            busybox_negative, returncode=1, expect_reply=False
        ),
        EVAL.Outcome.PASS,
    )
    for contradictory in (
        busybox.replace("0% packet loss", "100% packet loss"),
        iputils.replace("0% packet loss", "100% packet loss"),
    ):
        assert_outcome(
            EVAL.evaluate_ping(
                contradictory, returncode=0, expect_reply=True
            ),
            EVAL.Outcome.FAIL,
        )
    for contradictory in (
        busybox_negative.replace("100% packet loss", "0% packet loss"),
        negative.replace("100% packet loss", "0% packet loss"),
    ):
        assert_outcome(
            EVAL.evaluate_ping(
                contradictory, returncode=1, expect_reply=False
            ),
            EVAL.Outcome.FAIL,
        )
    noninteger_loss = busybox.replace("0% packet loss", "0.0% packet loss")
    assert_outcome(
        EVAL.evaluate_ping(
            noninteger_loss, returncode=0, expect_reply=True
        ),
        EVAL.Outcome.ERROR,
    )
    out_of_range_loss = iputils.replace("0% packet loss", "101% packet loss")
    assert_outcome(
        EVAL.evaluate_ping(
            out_of_range_loss, returncode=0, expect_reply=True
        ),
        EVAL.Outcome.FAIL,
    )
    busybox_summary = busybox.rsplit("\n", 2)[-2]
    duplicated_summary = busybox + busybox_summary + "\n"
    assert_outcome(
        EVAL.evaluate_ping(
            duplicated_summary, returncode=0, expect_reply=True
        ),
        EVAL.Outcome.ERROR,
    )
    malformed_duplicate = (
        busybox + busybox_summary.replace("0% packet loss", "0.0% packet loss") + "\n"
    )
    assert_outcome(
        EVAL.evaluate_ping(
            malformed_duplicate, returncode=0, expect_reply=True
        ),
        EVAL.Outcome.ERROR,
    )
    iputils_summary = iputils.rsplit("\n", 2)[-2]
    mixed_summaries = busybox + iputils_summary + "\n"
    assert_outcome(
        EVAL.evaluate_ping(
            mixed_summaries, returncode=0, expect_reply=True
        ),
        EVAL.Outcome.ERROR,
    )
    unreachable = "ping: sendmsg: Network is unreachable\n5 packets transmitted, 0 received\n"
    assert_outcome(EVAL.evaluate_ping(unreachable, returncode=1, expect_reply=False), EVAL.Outcome.FAIL)
    zero_emission = "0 packets transmitted, 0 received, 100% packet loss\n"
    assert_outcome(EVAL.evaluate_ping(zero_emission, returncode=1, expect_reply=False), EVAL.Outcome.FAIL)


def test_cas_postconditions() -> None:
    baseline = EVAL.CASBaseline(
        a_ls_uuid="00000000-0000-4000-8000-000000000001",
        b_ls_uuid="00000000-0000-4000-8000-000000000002",
        nb_lsp_uuid="00000000-0000-4000-8000-000000000003",
        nb_lsp_name="x05-tenant-b-vm",
        a_ports=frozenset({"00000000-0000-4000-8000-000000000004"}),
        b_ports=frozenset({"00000000-0000-4000-8000-000000000003", "00000000-0000-4000-8000-000000000005"}),
        sb_logical_port="x05-tenant-b-vm",
        sb_port_binding_uuid="90000000-0000-4000-8000-000000000003",
        a_sentinel_datapath="00000000-0000-4000-8000-000000000006",
        b_sentinel_datapath="00000000-0000-4000-8000-000000000007",
    )
    moved = EVAL.CASObservation(
        baseline.a_ls_uuid,
        baseline.b_ls_uuid,
        baseline.nb_lsp_uuid,
        baseline.nb_lsp_name,
        baseline.a_ports | {baseline.nb_lsp_uuid},
        baseline.b_ports - {baseline.nb_lsp_uuid},
        frozenset({baseline.a_ls_uuid}),
        baseline.sb_logical_port,
        baseline.sb_port_binding_uuid,
        baseline.a_sentinel_datapath,
    )
    assert_outcome(
        EVAL.evaluate_cas_postcondition(baseline, moved, EVAL.CASStage.MOVED_TO_A),
        EVAL.Outcome.PASS,
    )
    sb_lag = EVAL.CASObservation(
        *dataclasses_astuple(moved)[:-1], baseline.b_sentinel_datapath
    )
    assert_outcome(
        EVAL.evaluate_cas_postcondition(baseline, sb_lag, EVAL.CASStage.MOVED_TO_A),
        EVAL.Outcome.RETRY,
    )
    third_datapath = EVAL.CASObservation(
        *dataclasses_astuple(moved)[:-1],
        "f0000000-0000-4000-8000-000000000001",
    )
    assert_outcome(
        EVAL.evaluate_cas_postcondition(
            baseline, third_datapath, EVAL.CASStage.MOVED_TO_A
        ),
        EVAL.Outcome.FAIL,
    )
    restored = EVAL.CASObservation(
        baseline.a_ls_uuid,
        baseline.b_ls_uuid,
        baseline.nb_lsp_uuid,
        baseline.nb_lsp_name,
        baseline.a_ports,
        baseline.b_ports,
        frozenset({baseline.b_ls_uuid}),
        baseline.sb_logical_port,
        baseline.sb_port_binding_uuid,
        baseline.b_sentinel_datapath,
    )
    assert_outcome(
        EVAL.evaluate_cas_postcondition(
            baseline, restored, EVAL.CASStage.RESTORED_TO_B
        ),
        EVAL.Outcome.PASS,
    )
    restoring = EVAL.CASObservation(
        *dataclasses_astuple(restored)[:-1], baseline.a_sentinel_datapath
    )
    assert_outcome(
        EVAL.evaluate_cas_postcondition(
            baseline, restoring, EVAL.CASStage.RESTORED_TO_B
        ),
        EVAL.Outcome.RETRY,
    )
    replaced = EVAL.CASObservation(
        moved.a_ls_uuid,
        moved.b_ls_uuid,
        "90000000-0000-4000-8000-000000000003",
        moved.nb_lsp_name,
        moved.a_ports,
        moved.b_ports,
        moved.parent_ls_uuids,
        moved.sb_logical_port,
        moved.sb_port_binding_uuid,
        moved.sb_datapath,
    )
    assert_outcome(
        EVAL.evaluate_cas_postcondition(baseline, replaced, EVAL.CASStage.MOVED_TO_A),
        EVAL.Outcome.FAIL,
    )
    replaced_sb = EVAL.CASObservation(
        moved.a_ls_uuid,
        moved.b_ls_uuid,
        moved.nb_lsp_uuid,
        moved.nb_lsp_name,
        moved.a_ports,
        moved.b_ports,
        moved.parent_ls_uuids,
        moved.sb_logical_port,
        "80000000-0000-4000-8000-000000000003",
        moved.sb_datapath,
    )
    assert_outcome(
        EVAL.evaluate_cas_postcondition(
            baseline, replaced_sb, EVAL.CASStage.MOVED_TO_A
        ),
        EVAL.Outcome.FAIL,
    )
    # NB and SB UUIDs are separate realms. Coincidental equality is not rejected.
    same_realm_value = dataclasses_replace(
        baseline, sb_port_binding_uuid=baseline.nb_lsp_uuid
    )
    same_realm_observation = dataclasses_replace(
        moved, sb_port_binding_uuid=baseline.nb_lsp_uuid
    )
    assert_outcome(
        EVAL.evaluate_cas_postcondition(
            same_realm_value, same_realm_observation, EVAL.CASStage.MOVED_TO_A
        ),
        EVAL.Outcome.PASS,
    )
    try:
        dataclasses_replace(moved, sb_datapath=None)
    except ValueError:
        pass
    else:
        raise AssertionError("partially populated SB observation was accepted")
    try:
        dataclasses_replace(
            baseline,
            b_sentinel_datapath=baseline.a_sentinel_datapath,
        )
    except ValueError:
        pass
    else:
        raise AssertionError("CAS baseline accepted one datapath for both tenants")


def dataclasses_astuple(value: object) -> tuple[object, ...]:
    return tuple(getattr(value, field.name) for field in EVAL.dataclasses.fields(value))


def dataclasses_replace(value: object, **changes: object) -> object:
    return EVAL.dataclasses.replace(value, **changes)


def test_polling_budgets() -> None:
    outcomes = [EVAL.retry("wait"), EVAL.passed("ready")]
    seen: list[tuple[int, int, float]] = []

    def check(attempt: int, remaining: int, timeout: float) -> EVAL.IterationReport:
        assert remaining > 0
        seen.append((attempt, remaining, timeout))
        return EVAL.IterationReport(outcomes[attempt - 1], 10)

    report = EVAL.poll_retries(check, EVAL.PollBudget(3, 100, 2.5))
    assert report.evaluation.outcome is EVAL.Outcome.PASS and report.attempts == 2
    assert seen == [(1, 100, 2.5), (2, 90, 2.5)]

    terminal_calls = 0

    def terminal(
        _attempt: int, _remaining: int, _timeout: float
    ) -> EVAL.IterationReport:
        nonlocal terminal_calls
        terminal_calls += 1
        return EVAL.IterationReport(EVAL.failed("contradiction"), 1)

    report = EVAL.poll_retries(terminal, EVAL.PollBudget(3, 100, 1.0))
    assert report.evaluation.outcome is EVAL.Outcome.FAIL and terminal_calls == 1
    exhausted = EVAL.poll_retries(
        lambda _attempt, _remaining, _timeout: EVAL.IterationReport(
            EVAL.retry("wait"), 6
        ),
        EVAL.PollBudget(5, 10, 1.0),
    )
    assert exhausted.evaluation.outcome is EVAL.Outcome.FAIL
    wrong = EVAL.poll_retries(
        lambda _attempt, _remaining, _timeout: object(),
        EVAL.PollBudget(1, 10, 1.0),
    )
    assert_outcome(wrong.evaluation, EVAL.Outcome.ERROR)


def test_closed_outcomes_and_result_types() -> None:
    try:
        EVAL.Evaluation("PASS", "forged")
    except TypeError:
        pass
    else:
        raise AssertionError("plain-string outcome was accepted")
    combined = EVAL.combine_results({"forged": object()})
    assert_outcome(combined, EVAL.Outcome.ERROR)


class FakeResult:
    def __init__(
        self,
        argv: tuple[str, ...],
        stdout: bytes,
        *,
        returncode: int = 0,
        stderr: bytes = b"",
        truncated: bool = False,
        elapsed: float = 0.01,
    ) -> None:
        self.argv = argv
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr
        self.elapsed = elapsed
        self.truncated = truncated


class FakeRunner:
    def __init__(self, responses: dict[tuple[str, ...], bytes]) -> None:
        self.responses = responses
        self.calls: list[tuple[tuple[str, ...], int]] = []
        self.timeouts: list[float] = []

    def run(
        self,
        argv,
        *,
        env,
        timeout,
        pass_fds=(),
        max_output_bytes=EVAL.SHARED_MAX_OUTPUT,
    ):
        command = tuple(argv)
        assert env == EVAL.BASE_ENV and 0 < timeout <= 1.0
        assert tuple(pass_fds) == ()
        self.calls.append((command, max_output_bytes))
        self.timeouts.append(timeout)
        return FakeResult(command, self.responses[command])


class OversizedRunner:
    def __init__(self, *, truncated: bool = False) -> None:
        self.truncated = truncated
        self.caps: list[int] = []

    def run(
        self,
        argv,
        *,
        env,
        timeout,
        pass_fds=(),
        max_output_bytes=EVAL.SHARED_MAX_OUTPUT,
    ):
        assert env == EVAL.BASE_ENV and 0 < timeout <= 1.0
        assert tuple(pass_fds) == ()
        self.caps.append(max_output_bytes)
        size = 1 if self.truncated else max_output_bytes + 1
        return FakeResult(tuple(argv), b"x" * size, truncated=self.truncated)


def test_shared_runner_budget_is_prebuffer_and_fail_closed() -> None:
    source = "a" * 64
    command = EVAL.CommandSpec(
        "one", source, ("docker", "exec", source, "printf", "x")
    )
    oversized = OversizedRunner()
    collection = EVAL.collect_fixed_commands(
        oversized, {"one": command}, timeout=1.0, io_budget=16
    )
    assert collection.error is not None
    assert_outcome(collection.error, EVAL.Outcome.ERROR)

    assert oversized.caps == [16]

    truncated = OversizedRunner(truncated=True)
    collection = EVAL.collect_fixed_commands(
        truncated, {"one": command}, timeout=1.0, io_budget=16
    )
    assert collection.error is not None
    assert_outcome(collection.error, EVAL.Outcome.ERROR)
    assert truncated.caps == [16]

    second = EVAL.CommandSpec(
        "two", source, ("docker", "exec", source, "printf", "y")
    )
    exhausted_runner = FakeRunner({command.argv: b"x", second.argv: b"y"})
    collection = EVAL.collect_fixed_commands(
        exhausted_runner,
        {"one": command, "two": second},
        timeout=1.0,
        io_budget=1,
    )
    assert collection.error is not None
    assert_outcome(collection.error, EVAL.Outcome.ERROR)
    assert exhausted_runner.calls == [(command.argv, 1)]


def test_collection_uses_one_monotonic_deadline() -> None:
    source = "a" * 64
    commands = {
        name: EVAL.CommandSpec(
            name, source, ("docker", "exec", source, "printf", name)
        )
        for name in ("one", "two")
    }

    class Clock:
        def __init__(self) -> None:
            self.value = 100.0

        def __call__(self) -> float:
            return self.value

    class ElapsedRunner:
        def __init__(self, elapsed: float) -> None:
            self.elapsed = elapsed
            self.timeouts: list[float] = []

        def run(
            self,
            argv,
            *,
            env,
            timeout,
            pass_fds=(),
            max_output_bytes=EVAL.SHARED_MAX_OUTPUT,
        ):
            assert env == EVAL.BASE_ENV and tuple(pass_fds) == ()
            assert max_output_bytes > 0
            self.timeouts.append(timeout)
            return FakeResult(tuple(argv), b"x", elapsed=self.elapsed)

    runner = ElapsedRunner(0.6)
    collection = EVAL.collect_fixed_commands(
        runner,
        commands,
        timeout=1.0,
        io_budget=16,
        clock=Clock(),
    )
    assert collection.error is not None
    assert_outcome(collection.error, EVAL.Outcome.ERROR)
    assert len(runner.timeouts) == 2
    assert runner.timeouts[0] == 1.0
    assert abs(runner.timeouts[1] - 0.4) < 1e-9
    assert "deadline" in collection.error.reason

    within_budget = ElapsedRunner(0.4)
    collection = EVAL.collect_fixed_commands(
        within_budget,
        commands,
        timeout=1.0,
        io_budget=16,
        clock=Clock(),
    )
    assert collection.error is None
    assert within_budget.timeouts[0] == 1.0
    assert abs(within_budget.timeouts[1] - 0.6) < 1e-9

    exactly_exhausted = ElapsedRunner(1.0)
    collection = EVAL.collect_fixed_commands(
        exactly_exhausted,
        {"one": commands["one"]},
        timeout=1.0,
        io_budget=16,
        clock=Clock(),
    )
    assert collection.error is not None
    assert_outcome(collection.error, EVAL.Outcome.ERROR)

    class ScriptedClock:
        def __init__(self, values: list[float]) -> None:
            self.values = iter(values)

        def __call__(self) -> float:
            return next(self.values)

    wall_limited = ElapsedRunner(0.1)
    collection = EVAL.collect_fixed_commands(
        wall_limited,
        commands,
        timeout=1.0,
        io_budget=16,
        clock=ScriptedClock([100.0, 100.0, 100.7, 100.7, 100.9]),
    )
    assert collection.error is None
    assert abs(wall_limited.timeouts[1] - 0.3) < 1e-9

    regressing = ElapsedRunner(0.1)
    collection = EVAL.collect_fixed_commands(
        regressing,
        {"one": commands["one"]},
        timeout=1.0,
        io_budget=16,
        clock=ScriptedClock([100.0, 100.0, 99.0]),
    )
    assert collection.error is not None
    assert_outcome(collection.error, EVAL.Outcome.ERROR)
    assert "regressed" in collection.error.reason


def test_collection_types_result_extraction_errors() -> None:
    source = "a" * 64
    command = EVAL.CommandSpec(
        "one", source, ("docker", "exec", source, "printf", "one")
    )

    class ExplodingArgv:
        def __iter__(self):
            raise RuntimeError("argv exploded")

    class ShapeRunner:
        def __init__(self, argv: object) -> None:
            self.argv = argv

        def run(
            self,
            argv,
            *,
            env,
            timeout,
            pass_fds=(),
            max_output_bytes=EVAL.SHARED_MAX_OUTPUT,
        ):
            del argv, env, timeout, pass_fds, max_output_bytes
            return FakeResult(self.argv, b"x")

    collection = EVAL.collect_fixed_commands(
        ShapeRunner(ExplodingArgv()),
        {"one": command},
        timeout=1.0,
        io_budget=16,
    )
    assert collection.error is not None
    assert_outcome(collection.error, EVAL.Outcome.ERROR)
    assert "RuntimeError" in collection.error.reason

    class InterruptingArgv:
        def __iter__(self):
            raise KeyboardInterrupt

    try:
        EVAL.collect_fixed_commands(
            ShapeRunner(InterruptingArgv()),
            {"one": command},
            timeout=1.0,
            io_budget=16,
        )
    except KeyboardInterrupt:
        pass
    else:
        raise AssertionError("collector swallowed a BaseException interruption")


def test_g1_full_iteration_uses_captured_ids() -> None:
    topology = EVAL.G1Topology(*(character * 64 for character in "abcd"))
    commands = EVAL.g1_commands(topology)
    assert commands["gateway_100.bgp"].source_id == topology.gateway_1
    assert commands["gateway_300.bgp"].source_id == topology.gateway_1
    assert commands["gateway_200.bgp"].source_id == topology.gateway_2
    assert commands["gateway_400.bgp"].source_id == topology.gateway_2
    rib, fib = actual_a_routes()
    outputs: dict[str, bytes] = {}
    for key, command in commands.items():
        if key.endswith(".rib"):
            outputs[key] = rib.encode()
        elif key.endswith(".fib"):
            outputs[key] = fib.encode()
        elif key == "client_a.bgp":
            outputs[key] = encoded(CLIENT_A)
        elif key == "client_b.bgp":
            outputs[key] = encoded(CLIENT_B_SYNTHETIC)
        elif key == "gateway_100.bgp":
            outputs[key] = (EVIDENCE / "08-x05/gateway-vrf100-readonly-20260930.json").read_bytes()
        elif key == "gateway_200.bgp":
            outputs[key] = (EVIDENCE / "08-x05/gateway-vrf200-readonly-20260930.json").read_bytes()
        elif key == "gateway_300.bgp":
            outputs[key] = encoded(GATEWAY_300_SYNTHETIC)
        elif key == "gateway_400.bgp":
            outputs[key] = encoded(GATEWAY_400_SYNTHETIC)
    fixture = fixture_collection(commands, outputs)
    fixture_result = EVAL.evaluate_g1_samples(fixture, topology)
    assert_outcome(fixture_result, EVAL.Outcome.PASS)
    assert fixture_result.proof_kind is EVAL.ProofKind.FIXTURE_COLLECTION
    assert fixture_result.facts["authoritative_x05_pass"] is False
    unequal_weights = dict(outputs)
    for client in ("client_a", "client_b"):
        unequal_weights[f"{client}.fib"] = outputs[f"{client}.fib"].replace(
            b"weight 1", b"weight 256", 1
        )
    assert_outcome(
        EVAL.evaluate_g1_samples(
            fixture_collection(commands, unequal_weights), topology
        ),
        EVAL.Outcome.PASS,
    )
    for client in ("client_a", "client_b"):
        known_after_selected = dict(outputs)
        known_after_selected[f"{client}.rib"] = move_known_after_selected(
            outputs[f"{client}.rib"]
        )
        assert_outcome(
            EVAL.evaluate_g1_samples(
                fixture_collection(commands, known_after_selected), topology
            ),
            EVAL.Outcome.ERROR,
        )
        for invalid_fib in (
            outputs[f"{client}.fib"].replace(b" weight 1", b""),
            outputs[f"{client}.fib"].replace(b"weight 1", b"weight 0"),
            outputs[f"{client}.fib"].replace(
                b"weight 1", b"weight 4294967296"
            ),
        ):
            invalid_weight = dict(outputs)
            invalid_weight[f"{client}.fib"] = invalid_fib
            assert_outcome(
                EVAL.evaluate_g1_samples(
                    fixture_collection(commands, invalid_weight), topology
                ),
                EVAL.Outcome.ERROR,
            )
    for extra_selected in (
        b"  * 203.0.113.1, via eth9 onlink, weight 1\n",
        b"  * unreachable (blackhole), weight 1\n",
    ):
        unexpected = dict(outputs)
        unexpected["client_a.rib"] = (
            outputs["client_a.rib"].rstrip() + b"\n" + extra_selected
        )
        assert_outcome(
            EVAL.evaluate_g1_samples(
                fixture_collection(commands, unexpected), topology
            ),
            EVAL.Outcome.FAIL,
        )

    responses = {commands[key].argv: output for key, output in outputs.items()}
    runner = FakeRunner(responses)
    result, io_bytes = EVAL.collect_g1_iteration(runner, topology, timeout=1.0, io_budget=100_000)
    assert_outcome(result, EVAL.Outcome.PASS)
    assert result.proof_kind is EVAL.ProofKind.CAPTURED_OBSERVATION
    assert result.facts["authoritative_x05_pass"] is False
    assert [call for call, _cap in runner.calls] == [
        command.argv for command in commands.values()
    ]
    assert io_bytes > 0
    assert all(
        call[2] in {field for field in dataclasses_astuple(topology)}
        for call, _cap in runner.calls
    )
    expected_caps: list[int] = []
    remaining = 100_000
    for command in commands.values():
        expected_caps.append(remaining)
        remaining -= len(responses[command.argv])
    assert [cap for _call, cap in runner.calls] == expected_caps

    tampered_samples = dict(fixture.samples)
    original = tampered_samples["client_b.bgp"]
    forged_spec = EVAL.CommandSpec(
        "client_b.bgp",
        topology.client_a,
        commands["client_a.bgp"].argv,
    )
    tampered_samples["client_b.bgp"] = EVAL.CommandSample(
        EVAL.ObservationEnvelope(
            forged_spec, EVAL.ObservationOrigin.FIXTURE
        ),
        0,
        original.stdout,
        b"",
        original.elapsed,
    )
    tampered = EVAL.Collection(
        EVAL.ObservationOrigin.FIXTURE, tampered_samples, fixture.io_bytes
    )
    assert_outcome(
        EVAL.evaluate_g1_samples(tampered, topology), EVAL.Outcome.ERROR
    )

    stderr_samples = dict(fixture.samples)
    original = stderr_samples["client_a.bgp"]
    stderr_samples["client_a.bgp"] = EVAL.CommandSample(
        original.envelope, 0, original.stdout, b"warning\n", original.elapsed
    )
    stderr_collection = EVAL.Collection(
        EVAL.ObservationOrigin.FIXTURE,
        stderr_samples,
        fixture.io_bytes + len(b"warning\n"),
    )
    assert_outcome(
        EVAL.evaluate_g1_samples(stderr_collection, topology), EVAL.Outcome.ERROR
    )
    failed_samples = dict(fixture.samples)
    original = failed_samples["client_a.bgp"]
    failed_samples["client_a.bgp"] = EVAL.CommandSample(
        original.envelope, 1, original.stdout, b"", original.elapsed
    )
    failed_collection = EVAL.Collection(
        EVAL.ObservationOrigin.FIXTURE, failed_samples, fixture.io_bytes
    )
    assert_outcome(
        EVAL.evaluate_g1_samples(failed_collection, topology), EVAL.Outcome.ERROR
    )
    incomplete_samples = dict(fixture.samples)
    incomplete_samples["client_a.bgp"] = fixture_sample(
        commands["client_a.bgp"], original.stdout, complete=False
    )
    incomplete_collection = EVAL.Collection(
        EVAL.ObservationOrigin.FIXTURE, incomplete_samples, fixture.io_bytes
    )
    assert_outcome(
        EVAL.evaluate_g1_samples(incomplete_collection, topology),
        EVAL.Outcome.ERROR,
    )


def test_g1_rejects_shared_role_ids() -> None:
    ids = [character * 64 for character in "abcd"]
    try:
        EVAL.G1Topology(ids[0], ids[1], ids[2], ids[2])
    except ValueError:
        pass
    else:
        raise AssertionError("G1 accepted one container for both gateways")


def tenant_specs() -> EVAL.G2Topology:
    return EVAL.G2Topology(*("%x" % number * 64 for number in range(1, 6)))


def g2_fixture_outputs(topology: EVAL.G2Topology) -> dict[str, bytes]:
    """Build parser fixtures; the B-side values are synthetic and NOT OBSERVED."""

    bindings, learned, values = sb_fixture()
    outputs: dict[str, bytes] = {}
    for label, spec in (("a", topology.tenant_a), ("b", topology.tenant_b)):
        outputs[label + ".type5"] = f"""Route Distinguisher: {spec.chassis_vtep}:2
BGP routing table entry for {spec.chassis_vtep}:2:[5]:[0]:[24]:[192.168.100.0]
Paths: (1 available, best #1)
  Not advertised to any peer
  Route [5]:[0]:[24]:[192.168.100.0] VNI {spec.vni}
  65100
    {spec.chassis_vtep} from {spec.chassis_vtep} ({spec.chassis_vtep})
      Origin incomplete, metric 1000, valid, external, best (First path received)
      Extended Community: RT:65100:{spec.vni} ET:8 Rmac:02:00:00:10:00:01
      Last update: Tue Sep 29 13:41:03 2026

Displayed 1 prefixes (1 paths)
""".encode()
        outputs[label + ".rib"] = f"""Routing entry for {EVAL.PREFIX}
  Known via "bgp", distance 20, metric 1000, vrf {spec.client_vrf}, best
  * {spec.chassis_vtep}, via {spec.client_bridge} onlink, weight 1
""".encode()
        outputs[label + ".fib"] = f"{EVAL.PREFIX} nhid 12 via {spec.chassis_vtep} dev {spec.client_bridge} proto bgp metric 20 onlink\n".encode()
        outputs[label + ".vni"] = f"""VNI: {spec.vni}
  Type: L3
  Tenant VRF: {spec.client_vrf}
  Vlan: 1
  Bridge: {spec.client_bridge}
  Local Vtep Ip: {spec.peer_vtep}
  Vxlan-Intf: {spec.client_vxlan}
  SVI-If: {spec.client_bridge}
  State: Up
  VNI Filter: none
  System MAC: 02:00:00:50:10:02
  Router MAC: 02:00:00:50:10:02
  Number of MACs (local and remote) known for this VNI: 1
  Number of ARPs (IPv4 and IPv6, local and remote) known for this VNI: 1
  L2 VNIs:
""".encode()
        outputs[label + ".remote_vtep"] = f"IP: {spec.peer_vtep}, port: 4789, vni: {spec.vni}\n".encode()
        outputs[label + ".peer_get"] = f"{spec.sentinel_ip} from {spec.peer_source} via {spec.chassis_vtep} dev {spec.client_bridge} table {spec.client_table} uid 0\n".encode()
        outputs[label + ".tenant_local"] = f"blackhole {EVAL.PREFIX} proto ovn metric 1000\n".encode()
        outputs[label + ".tenant_return"] = f"{spec.peer_source} nhid 24 via {spec.peer_vtep} dev {spec.tenant_bridge} proto bgp metric 20 onlink\n".encode()
        outputs[label + ".tenant_get"] = f"{spec.peer_source} via {spec.peer_vtep} dev {spec.tenant_bridge} table {spec.tenant_table} uid 0\n".encode()
    port_headings = ["_uuid", "logical_port", "datapath"]
    outputs["sb.port_a"] = ovs_json(port_headings, [[ovs_uuid(values["a_pb"]), topology.tenant_a.lrp, ovs_uuid(values["a_dp"])]] )
    outputs["sb.port_b"] = ovs_json(port_headings, [[ovs_uuid(values["b_pb"]), topology.tenant_b.lrp, ovs_uuid(values["b_dp"])]] )
    outputs["sb.learned_routes"] = learned
    return outputs


def test_g2_decision_table_and_b_pathspace() -> None:
    topology = tenant_specs()
    assert topology.tenant_a.tenant_vrf == "ovnvrf-tenant"
    assert topology.tenant_a.lrp == "lrp-mgc-tenant"
    assert topology.tenant_b.tenant_vrf == "ovnvrf-x05-b"
    assert topology.tenant_b.lrp == "lrp-x05-tenant-b"
    commands = EVAL.g2_commands(topology)
    assert commands["b.type5"].argv[4:6] == ("--vty_socket", "/run/frr/x05")
    assert "ovnvrf-tenant" in commands["a.tenant_get"].argv
    outputs = g2_fixture_outputs(topology)
    fixture = fixture_collection(commands, outputs)
    fixture_result = EVAL.evaluate_g2_samples(fixture, topology)
    assert_outcome(fixture_result, EVAL.Outcome.PASS)
    assert fixture_result.proof_kind is EVAL.ProofKind.FIXTURE_COLLECTION
    for tenant in ("a", "b"):
        known_after_selected = dict(outputs)
        known_after_selected[f"{tenant}.rib"] = move_known_after_selected(
            outputs[f"{tenant}.rib"]
        )
        assert_outcome(
            EVAL.evaluate_g2_samples(
                fixture_collection(commands, known_after_selected), topology
            ),
            EVAL.Outcome.ERROR,
        )
        paths_before_footer = dict(outputs)
        paths_before_footer[f"{tenant}.type5"] = move_paths_before_footer(
            outputs[f"{tenant}.type5"]
        )
        assert_outcome(
            EVAL.evaluate_g2_samples(
                fixture_collection(commands, paths_before_footer), topology
            ),
            EVAL.Outcome.ERROR,
        )
    reordered_attributes = dict(outputs)
    reordered_attributes["a.tenant_local"] = (
        f"blackhole {EVAL.PREFIX} nhid 12 metric 1000 proto ovn\n".encode()
    )
    assert_outcome(
        EVAL.evaluate_g2_samples(
            fixture_collection(commands, reordered_attributes), topology
        ),
        EVAL.Outcome.PASS,
    )
    extra_blackhole = dict(outputs)
    extra_blackhole["a.rib"] = (
        outputs["a.rib"].rstrip()
        + b"\n  * unreachable (blackhole), weight 1\n"
    )
    assert_outcome(
        EVAL.evaluate_g2_samples(
            fixture_collection(commands, extra_blackhole), topology
        ),
        EVAL.Outcome.FAIL,
    )
    for duplicated_attributes in (
        f"blackhole {EVAL.PREFIX} proto ovn metric 10 metric 20\n".encode(),
        f"blackhole {EVAL.PREFIX} proto ovn nhid 1 nhid 2\n".encode(),
    ):
        duplicated = dict(outputs)
        duplicated["a.tenant_local"] = duplicated_attributes
        assert_outcome(
            EVAL.evaluate_g2_samples(
                fixture_collection(commands, duplicated), topology
            ),
            EVAL.Outcome.ERROR,
        )
    runner = FakeRunner(
        {commands[key].argv: output for key, output in outputs.items()}
    )
    collected, io_bytes = EVAL.collect_g2_iteration(
        runner, topology, timeout=1.0, io_budget=100_000
    )
    assert_outcome(collected, EVAL.Outcome.PASS)
    assert collected.proof_kind is EVAL.ProofKind.CAPTURED_OBSERVATION
    assert [call for call, _cap in runner.calls] == [
        command.argv for command in commands.values()
    ]
    assert io_bytes > 0

    broken = dict(fixture.samples)
    sample = broken["b.vni"]
    broken["b.vni"] = fixture_sample(
        commands["b.vni"], sample.stdout.replace(b"VNI: 50200", b"VNI: 50100")
    )
    broken_collection = EVAL.Collection(
        EVAL.ObservationOrigin.FIXTURE, broken, fixture.io_bytes
    )
    assert_outcome(
        EVAL.evaluate_g2_samples(broken_collection, topology), EVAL.Outcome.FAIL
    )
    no_fib = dict(fixture.samples)
    sample = no_fib["a.fib"]
    no_fib["a.fib"] = fixture_sample(commands["a.fib"], b"")
    no_fib_collection = EVAL.Collection(
        EVAL.ObservationOrigin.FIXTURE, no_fib, fixture.io_bytes - len(sample.stdout)
    )
    assert_outcome(
        EVAL.evaluate_g2_samples(no_fib_collection, topology), EVAL.Outcome.RETRY
    )

    # The two Port_Binding queries are independent. Their union cannot hide
    # an overbroad A query and an empty B query.
    bindings, _learned, values = sb_fixture()
    union_bug = dict(fixture.samples)
    union_bug["sb.port_a"] = fixture_sample(commands["sb.port_a"], bindings)
    union_bug["sb.port_b"] = fixture_sample(
        commands["sb.port_b"],
        ovs_json(["_uuid", "logical_port", "datapath"], []),
    )
    union_collection = EVAL.Collection(
        EVAL.ObservationOrigin.FIXTURE, union_bug, fixture.io_bytes
    )
    assert EVAL.evaluate_g2_samples(
        union_collection, topology
    ).outcome is not EVAL.Outcome.PASS

    forged_learned_spec = EVAL.CommandSpec(
        "sb.learned_routes", topology.peer_a, commands["a.type5"].argv
    )
    forged_learned = dict(union_bug)
    forged_learned["sb.learned_routes"] = fixture_sample(
        forged_learned_spec, outputs["sb.learned_routes"]
    )
    forged_learned_collection = EVAL.Collection(
        EVAL.ObservationOrigin.FIXTURE,
        forged_learned,
        fixture.io_bytes,
    )
    assert_outcome(
        EVAL.evaluate_g2_samples(forged_learned_collection, topology),
        EVAL.Outcome.ERROR,
    )

    forged_spec = EVAL.CommandSpec(
        "b.type5", topology.peer_a, commands["a.type5"].argv
    )
    forged = dict(fixture.samples)
    forged["b.type5"] = fixture_sample(forged_spec, outputs["b.type5"])
    forged_collection = EVAL.Collection(
        EVAL.ObservationOrigin.FIXTURE, forged, fixture.io_bytes
    )
    assert_outcome(
        EVAL.evaluate_g2_samples(forged_collection, topology), EVAL.Outcome.ERROR
    )

    assert values["a_pb"] != values["b_pb"]


def test_g2_rejects_shared_role_ids() -> None:
    ids = [character * 64 for character in "1234"]
    try:
        EVAL.G2Topology(ids[0], ids[0], ids[1], ids[2], ids[3])
    except ValueError:
        pass
    else:
        raise AssertionError("G2 accepted shared peer IDs")
    try:
        EVAL.EVPNTenantSpec("A", ids[0], ids[1])
    except TypeError:
        pass
    else:
        raise AssertionError("tenant spec accepted a non-enum role")


def test_cli_stays_disabled() -> None:
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        assert EVAL.main(["--dry-run"]) == 0
    report = json.loads(output.getvalue())
    assert report["mutation"] is False
    assert report["authoritative_x05_gate"] is False
    assert report["runner"] == "x05-runtime-live.py:Runner"
    with contextlib.redirect_stderr(io.StringIO()):
        assert EVAL.main(["--execute"]) == 75


def main() -> int:
    tests = [
        value
        for name, value in sorted(globals().items())
        if name.startswith("test_") and callable(value)
    ]
    for test in tests:
        test()
    print(f"x05 evaluator selftest PASS ({len(tests)} tests)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
