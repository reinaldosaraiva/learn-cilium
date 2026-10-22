#!/usr/bin/env python3
"""Focused, lab-free tests for the canonical X05 coordinator."""

from __future__ import annotations

import importlib.util
import ipaddress
import contextlib
import copy
import datetime as dt
import io
import json
import os
import pathlib
import struct
import sys
import tempfile
import types
from typing import Any


sys.dont_write_bytecode = True
HERE = pathlib.Path(__file__).resolve().parent
SOURCE = HERE / "x05-coordinator.py"
MODULE_NAME = "x05_final_coordinator_selftest_contract"


def load() -> Any:
    spec = importlib.util.spec_from_file_location(MODULE_NAME, SOURCE)
    if spec is None or spec.loader is None:
        raise AssertionError("coordinator import spec is unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[MODULE_NAME] = module
    spec.loader.exec_module(module)
    return module


C = load()
ASSERTIONS = 0
G5_MOVED_TO_A = {
    "ordinal": 9,
    "gate": "G5",
    "role": "classic-original",
    "source": "10.0.0.1",
    "destination": "192.168.100.12",
    "expect_reply": True,
    "intended_tap": "b",
    "vni": 50100,
    "point": "chassis-2",
    "tap_interface": "x05-tenant-b-p",
    "vxlan_interface": "vxlan_sys_4789",
    "tap_ifindex": 6,
    "vxlan_ifindex": 7,
}


def check(value: bool, message: str) -> None:
    global ASSERTIONS
    ASSERTIONS += 1
    if not value:
        raise AssertionError(message)


def expect(error: type[BaseException], function: Any, message: str) -> None:
    global ASSERTIONS
    ASSERTIONS += 1
    try:
        function()
    except error:
        return
    raise AssertionError(message)


def expect_message(
    error: type[BaseException], function: Any, fragment: str, message: str
) -> None:
    try:
        function()
    except error as exc:
        check(fragment in str(exc), message + ": wrong failure cause")
        return
    raise AssertionError(message)


def ipv4(source: str, destination: str, protocol: int, payload: bytes, *, fragment: int = 0) -> bytes:
    total = 20 + len(payload)
    return (
        b"\x45\x00"
        + total.to_bytes(2, "big")
        + b"\x00\x01"
        + fragment.to_bytes(2, "big")
        + b"\x40"
        + bytes([protocol])
        + b"\x00\x00"
        + ipaddress.ip_address(source).packed
        + ipaddress.ip_address(destination).packed
        + payload
    )


def icmp(
    source: str,
    destination: str,
    kind: int,
    identifier: int,
    sequence: int,
    payload: bytes,
    *,
    fragment: int = 0,
) -> bytes:
    body = bytes([kind, 0, 0, 0]) + identifier.to_bytes(2, "big") + sequence.to_bytes(2, "big") + payload
    return ipv4(source, destination, 1, body, fragment=fragment)


def vxlan(inner: bytes, vni: int) -> bytes:
    ethernet = b"\x02" * 6 + b"\x04" * 6 + b"\x08\x00" + inner
    tunnel = b"\x08\x00\x00\x00" + vni.to_bytes(3, "big") + b"\x00" + ethernet
    udp_length = 8 + len(tunnel)
    udp = b"\x12\x34\x12\xb5" + udp_length.to_bytes(2, "big") + b"\x00\x00" + tunnel
    return ipv4("170.168.0.5", "170.168.0.6", 17, udp)


def sll2(
    ifindex: int,
    packet_type: int,
    payload: bytes,
    *,
    protocol: int = 0x0800,
) -> bytes:
    return (
        protocol.to_bytes(2, "big") + b"\x00\x00"
        + ifindex.to_bytes(4, "big")
        + b"\x00\x01"
        + bytes([packet_type, 6])
        + b"\x02\x00\x00\x00\x00\x01\x00\x00"
        + payload
    )


def pcap(records: list[tuple[int, bytes]]) -> bytes:
    raw = bytearray(b"\xd4\xc3\xb2\xa1" + struct.pack("<HHIIII", 2, 4, 0, 0, 65535, 276))
    for timestamp_ns, frame in sorted(records, key=lambda item: item[0]):
        seconds, remainder = divmod(timestamp_ns, 1_000_000_000)
        raw.extend(struct.pack("<IIII", seconds, remainder // 1000, len(frame), len(frame)))
        raw.extend(frame)
    return bytes(raw)


def semantic_fixture() -> tuple[dict[str, Any], dict[str, Any], list[dict[str, Any]]]:
    point_rows = {
        "fabric": [(1, "br-ovn"), (2, "m03p"), (3, "x05p")],
        "chassis-1": [(4, "x05-tenant-a-p"), (5, "vxlan_sys_4789")],
        "chassis-2": [(6, "x05-tenant-b-p"), (7, "vxlan_sys_4789")],
        "gateway-300": [(8, "bgpvrf100"), (9, "bgpvrf300")],
        "gateway-400": [(10, "bgpvrf200"), (11, "bgpvrf400")],
    }
    contract = {
        "points": [
            {
                "id": point,
                "interfaces": [
                    {"ifindex": ifindex, "name": name}
                    for ifindex, name in rows
                ],
            }
            for point, rows in point_rows.items()
        ],
        "sources": [
            {"id": "classic-original", "source": "10.0.0.1", "receive": [{"point": "gateway-300", "interface": "bgpvrf100"}, {"point": "gateway-400", "interface": "bgpvrf200"}]},
            {"id": "classic-created", "source": "10.0.0.1", "receive": [{"point": "gateway-300", "interface": "bgpvrf300"}, {"point": "gateway-400", "interface": "bgpvrf400"}]},
            {"id": "evpn-original", "source": "10.250.0.1", "receive": [{"point": "fabric", "interface": "m03p"}]},
            {"id": "evpn-created", "source": "10.251.0.1", "receive": [{"point": "fabric", "interface": "x05p"}]},
        ],
    }
    locations = {
        (point, name): (point, ifindex)
        for point, rows in point_rows.items()
        for ifindex, name in rows
    }
    records: dict[str, list[tuple[int, bytes]]] = {point: [] for point in point_rows}
    windows: list[dict[str, Any]] = []

    def add(location: tuple[str, str], timestamp: int, packet_type: int, payload: bytes) -> None:
        point, ifindex = locations[location]
        records[point].append((timestamp, sll2(ifindex, packet_type, payload)))

    source_location = {
        "classic-original": ("gateway-300", "bgpvrf100"),
        "classic-created": ("gateway-300", "bgpvrf300"),
        "evpn-original": ("fabric", "m03p"),
        "evpn-created": ("fabric", "x05p"),
    }
    for ordinal, plan in enumerate(C.WINDOW_PLAN, 1):
        started = 1_800_000_000_000_000_000 + ordinal * 2_000_000_000
        finished = started + 1_000_000_000
        started_monotonic = 9_000_000_000 + ordinal * 2_000_000_000
        finished_monotonic = started_monotonic + 1_000_000_000
        nonce = ("%032x" % ordinal)[-32:]
        window = {
            "ordinal": ordinal,
            "gate": plan.gate,
            "role": plan.role,
            "source": next(item["source"] for item in contract["sources"] if item["id"] == plan.role),
            "destination": plan.destination,
            "expect_reply": plan.expect_reply,
            "intended_tap": plan.intended_tap,
            "vni": plan.vni,
            "pattern_hex": nonce,
            "started_at_ns": started,
            "finished_at_ns": finished,
            "started_monotonic_ns": started_monotonic,
            "finished_monotonic_ns": finished_monotonic,
        }
        windows.append(window)
        identifier = 1000 + ordinal
        tap_point = "chassis-1" if plan.intended_tap == "a" else "chassis-2"
        tap_name = "x05-tenant-%s-p" % plan.intended_tap
        source = window["source"]
        for sequence in range(1, 6):
            timestamp = started + sequence * 10_000_000
            payload = bytes([sequence]) * 16 + (bytes.fromhex(nonce) * 4)[16:56]
            request = icmp(source, plan.destination, 8, identifier, sequence, payload)
            reply = icmp(plan.destination, source, 0, identifier, sequence, payload)
            source_request = vxlan(request, plan.vni) if plan.role.startswith("evpn-") else request
            add(source_location[plan.role], timestamp, 0, source_request)
            if plan.expect_reply:
                source_reply = vxlan(reply, plan.vni) if plan.role.startswith("evpn-") else reply
                add(source_location[plan.role], timestamp + 5_000_000, 4, source_reply)
                add((tap_point, tap_name), timestamp + 1_000_000, 4, request)
                add((tap_point, tap_name), timestamp + 2_000_000, 0, reply)
                add((tap_point, "vxlan_sys_4789"), timestamp + 500_000, 0, vxlan(request, plan.vni))
                add((tap_point, "vxlan_sys_4789"), timestamp + 3_000_000, 4, vxlan(reply, plan.vni))
    records["fabric"].append(
        (
            windows[0]["started_at_ns"] + 4_000_000,
            sll2(1, 0, b"\x00" * 28, protocol=0x0806),
        )
    )
    records["fabric"].append(
        (
            windows[0]["started_at_ns"] + 6_000_000,
            sll2(
                1,
                0,
                ipv4("203.0.113.1", "203.0.113.2", 6, b"\x00" * 20),
            ),
        )
    )
    pcaps = {}
    for point, rows in records.items():
        raw = pcap(rows)
        pcaps[point] = {"raw": raw, "sha256": C._sha256(raw)}
    return pcaps, contract, windows


def g5_topology_fixture(
    vni: int,
) -> tuple[dict[str, Any], dict[str, Any], list[dict[str, Any]], dict[int, int]]:
    """Build the moved-to-A window from the topology oracle, not WINDOW_PLAN."""
    pcaps, contract, windows = semantic_fixture()
    oracle = G5_MOVED_TO_A
    window = windows[oracle["ordinal"] - 1]
    window.update({key: oracle[key] for key in (
        "ordinal", "gate", "role", "source", "destination",
        "expect_reply", "intended_tap", "vni",
    )})
    point = next(item for item in contract["points"] if item["id"] == oracle["point"])
    check(
        point["interfaces"] == [
            {"ifindex": oracle["tap_ifindex"], "name": oracle["tap_interface"]},
            {"ifindex": oracle["vxlan_ifindex"], "name": oracle["vxlan_interface"]},
        ],
        "moved-to-A G5 corpus is not bound to the original B physical tap",
    )

    raw = bytearray(pcaps[oracle["point"]]["raw"])
    offset = 24
    directions: dict[int, int] = {}
    selected = 0
    while offset < len(raw):
        seconds, micros, captured, original = struct.unpack("<IIII", raw[offset : offset + 16])
        frame_start = offset + 16
        frame_end = frame_start + captured
        if captured != original or frame_end > len(raw):
            raise AssertionError("synthetic moved-to-A G5 PCAP record is malformed")
        timestamp_ns = seconds * 1_000_000_000 + micros * 1_000
        ifindex = int.from_bytes(raw[frame_start + 4 : frame_start + 8], "big")
        if (
            window["started_at_ns"] <= timestamp_ns <= window["finished_at_ns"]
            and ifindex == oracle["vxlan_ifindex"]
        ):
            if (
                captured < 55
                or raw[frame_start + 29] != 17
                or int.from_bytes(raw[frame_start + 42 : frame_start + 44], "big") != 4789
                or raw[frame_start + 48] != 8
            ):
                raise AssertionError("synthetic moved-to-A G5 VXLAN record is malformed")
            packet_type = raw[frame_start + 10]
            directions[packet_type] = directions.get(packet_type, 0) + 1
            raw[frame_start + 52 : frame_start + 55] = vni.to_bytes(3, "big")
            selected += 1
        offset = frame_end
    check(
        offset == len(raw) and selected == 10,
        "moved-to-A G5 corpus did not retain five VXLAN requests and replies",
    )
    pcaps[oracle["point"]] = {"raw": bytes(raw), "sha256": C._sha256(bytes(raw))}
    return pcaps, contract, windows, directions


def decoder_checks() -> dict[str, Any]:
    pcaps, contract, windows = semantic_fixture()
    passed = C.decode_capture_evidence(pcaps, contract, windows)
    check(passed["status"] == "PASS", "canonical synthetic semantic corpus did not pass")
    check(passed["window_count"] == 12, "semantic corpus lost a fixed window")
    check(passed["ifindex_count"] == 11, "semantic corpus lost an ifindex")
    check(all(item["counts"]["source_requests"] == 5 for item in passed["windows"]), "source request counts changed")
    check(
        passed["pcaps"]["fabric"]["records"]
        > passed["pcaps"]["fabric"]["relevant_records"],
        "ifindex-only capture did not retain and ignore unrelated traffic",
    )

    topology_pcaps, topology_contract, topology_windows, directions = g5_topology_fixture(50100)
    topology = C.decode_capture_evidence(topology_pcaps, topology_contract, topology_windows)
    check(topology["status"] == "PASS", "moved-to-A G5 corpus did not accept VNI 50100")
    topology_g5 = topology["windows"][G5_MOVED_TO_A["ordinal"] - 1]
    check(
        {key: topology_g5[key] for key in (
            "ordinal", "gate", "role", "source", "destination",
            "expect_reply", "intended_tap", "vni",
        )} == {key: G5_MOVED_TO_A[key] for key in (
            "ordinal", "gate", "role", "source", "destination",
            "expect_reply", "intended_tap", "vni",
        )},
        "moved-to-A G5 window differs from the independent topology oracle",
    )
    check(
        topology_g5["counts"] == {
            "source_requests": 5,
            "source_replies": 5,
            "tap_requests": 5,
            "tap_replies": 5,
            "vxlan_requests": 5,
            "vxlan_replies": 5,
            "cross_tap": 0,
            "wrong_direction_or_vni": 0,
        },
        "moved-to-A G5 lost the five request/reply observations on tap B",
    )
    check(directions == {0: 5, 4: 5}, "moved-to-A G5 VXLAN directions changed")

    rejected_pcaps, rejected_contract, rejected_windows, rejected_directions = g5_topology_fixture(50200)
    rejected = C.decode_capture_evidence(rejected_pcaps, rejected_contract, rejected_windows)
    check(
        rejected["status"] == "FAIL" and '"wrong_direction_or_vni": 10' in rejected["reason"],
        "rejected G5 VNI 50200 corpus did not fail with ten wrong-VNI observations",
    )
    check(rejected_directions == {0: 5, 4: 5}, "rejected G5 corpus lost request/reply directions")

    duplicate = {key: dict(value) for key, value in pcaps.items()}
    raw = bytearray(duplicate["gateway-300"]["raw"])
    first_record = bytes(raw[24:])
    raw.extend(first_record[: 16 + int.from_bytes(first_record[8:12], "little")])
    duplicate["gateway-300"] = {"raw": bytes(raw), "sha256": C._sha256(bytes(raw))}
    check(C.decode_capture_evidence(duplicate, contract, windows)["status"] == "FAIL", "duplicate relevant packet passed")

    bad_nonce = json.loads(json.dumps(windows))
    bad_nonce[0]["pattern_hex"] = "ff" * 16
    check(C.decode_capture_evidence(pcaps, contract, bad_nonce)["status"] == "FAIL", "wrong nonce passed")

    wrong_direction = {key: dict(value) for key, value in pcaps.items()}
    gateway = bytearray(wrong_direction["gateway-300"]["raw"])
    gateway[24 + 16 + 10] = 4
    wrong_direction["gateway-300"] = {"raw": bytes(gateway), "sha256": C._sha256(bytes(gateway))}
    check(C.decode_capture_evidence(wrong_direction, contract, windows)["status"] == "FAIL", "wrong SLL2 direction passed")

    bad_vni_pcaps, bad_vni_contract, bad_vni_windows = semantic_fixture()
    chassis = bytearray(bad_vni_pcaps["chassis-1"]["raw"])
    marker = (50100).to_bytes(3, "big")
    index = chassis.find(marker, 24)
    check(index >= 0, "synthetic VNI marker is missing")
    chassis[index:index + 3] = (50999).to_bytes(3, "big")
    bad_vni_pcaps["chassis-1"] = {"raw": bytes(chassis), "sha256": C._sha256(bytes(chassis))}
    check(C.decode_capture_evidence(bad_vni_pcaps, bad_vni_contract, bad_vni_windows)["status"] == "FAIL", "wrong VNI passed")

    truncated = {key: dict(value) for key, value in pcaps.items()}
    raw = truncated["fabric"]["raw"][:-1]
    truncated["fabric"] = {"raw": raw, "sha256": C._sha256(raw)}
    check(C.decode_capture_evidence(truncated, contract, windows)["status"] == "ERROR", "truncated PCAP was not ERROR")

    fragmented = {key: dict(value) for key, value in pcaps.items()}
    gateway = bytearray(fragmented["gateway-300"]["raw"])
    gateway[24 + 16 + 20 + 7] = 1
    fragmented["gateway-300"] = {"raw": bytes(gateway), "sha256": C._sha256(bytes(gateway))}
    check(C.decode_capture_evidence(fragmented, contract, windows)["status"] == "ERROR", "fragmented relevant packet was not ERROR")

    bad_code = {key: dict(value) for key, value in pcaps.items()}
    gateway = bytearray(bad_code["gateway-300"]["raw"])
    gateway[24 + 16 + 20 + 21] = 1
    bad_code["gateway-300"] = {"raw": bytes(gateway), "sha256": C._sha256(bytes(gateway))}
    check(C.decode_capture_evidence(bad_code, contract, windows)["status"] == "ERROR", "nonzero relevant ICMP code was not ERROR")

    unreachable = {key: dict(value) for key, value in pcaps.items()}
    gateway = bytearray(unreachable["gateway-300"]["raw"])
    gateway[24 + 16 + 20 + 20] = 3
    unreachable["gateway-300"] = {"raw": bytes(gateway), "sha256": C._sha256(bytes(gateway))}
    check(C.decode_capture_evidence(unreachable, contract, windows)["status"] == "ERROR", "relevant ICMP unreachable was not ERROR")

    overlapping = copy.deepcopy(windows)
    overlapping[1]["started_monotonic_ns"] = overlapping[0]["finished_monotonic_ns"]
    check(
        C.decode_capture_evidence(pcaps, contract, overlapping)["status"] == "ERROR",
        "overlapping monotonic windows were accepted",
    )

    duplicate_receive = copy.deepcopy(contract)
    duplicate_receive["sources"][0]["receive"][1] = copy.deepcopy(
        duplicate_receive["sources"][0]["receive"][0]
    )
    check(
        C.decode_capture_evidence(pcaps, duplicate_receive, windows)["status"]
        == "ERROR",
        "duplicate source receive interface was accepted",
    )
    return {"status": "PASS", "pcaps": len(pcaps), "windows": len(windows)}


def bounded_poll_checks(root: pathlib.Path) -> dict[str, Any]:
    evidence_dir = root / "poll"
    evidence_dir.mkdir(mode=0o700)
    evidence = C._Evidence(evidence_dir, os.getuid())
    original_collect = C._EVALUATOR_COLLECT
    original_delay = C.GATE_RETRY_DELAY_SECONDS
    outcomes = [C.EVALUATOR.retry("wait"), C.EVALUATOR.passed("ready")]

    def collect(_runner: Any, _commands: Any, **_kwargs: Any) -> Any:
        return C.EVALUATOR.Collection(C.EVALUATOR.ObservationOrigin.RUNTIME_CAPTURE, {}, 0)

    try:
        C._EVALUATOR_COLLECT = collect
        C.GATE_RETRY_DELAY_SECONDS = 0.0
        report = C._poll_gate(
            name="selftest-retry",
            runner=object(),
            commands={},
            evaluate=lambda _collection: outcomes.pop(0),
            evidence=evidence,
            command_timeout=1.0,
            source_guard=lambda: None,
        )
        check(report["evaluation"]["outcome"] == "PASS", "bounded RETRY did not converge")
        check(report["attempts"] == 2, "bounded RETRY attempt count changed")
        failed = C._poll_gate(
            name="selftest-fail",
            runner=object(),
            commands={},
            evaluate=lambda _collection: C.EVALUATOR.failed("contradiction"),
            evidence=evidence,
            command_timeout=1.0,
            source_guard=lambda: None,
        )
        check(failed["evaluation"]["outcome"] == "FAIL", "non-RETRY outcome was retried")
        check(failed["attempts"] == 1, "terminal poll did not stop immediately")
        expect(
            C.CoordinatorError,
            lambda: C._require_gate(
                "synthetic",
                {
                    "evaluation": {
                        "outcome": "PASS",
                        "reason": "predicate only",
                        "authoritative_x05_pass": False,
                    }
                },
            ),
            "non-authoritative PASS was accepted",
        )
    finally:
        C._EVALUATOR_COLLECT = original_collect
        C.GATE_RETRY_DELAY_SECONDS = original_delay
    return {"status": "PASS", "retry_attempts": report["attempts"]}


def cas_checks() -> dict[str, Any]:
    uuids = ["%08d-0000-0000-0000-%012d" % (number, number) for number in range(1, 9)]
    baseline = C.EVALUATOR.CASBaseline(
        a_ls_uuid=uuids[0], b_ls_uuid=uuids[1], nb_lsp_uuid=uuids[2],
        nb_lsp_name="x05-tenant-b-vm", a_ports=frozenset({uuids[3]}),
        b_ports=frozenset({uuids[2], uuids[4]}), sb_logical_port="x05-tenant-b-vm",
        sb_port_binding_uuid=uuids[5], a_sentinel_datapath=uuids[6],
        b_sentinel_datapath=uuids[7],
    )
    moved = C.EVALUATOR.CASObservation(
        a_ls_uuid=uuids[0], b_ls_uuid=uuids[1], nb_lsp_uuid=uuids[2],
        nb_lsp_name="x05-tenant-b-vm", a_ports=frozenset({uuids[2], uuids[3]}),
        b_ports=frozenset({uuids[4]}), parent_ls_uuids=frozenset({uuids[0]}),
        sb_logical_port="x05-tenant-b-vm", sb_port_binding_uuid=uuids[5],
        sb_datapath=uuids[6],
    )
    restored = C.EVALUATOR.CASObservation(
        a_ls_uuid=uuids[0], b_ls_uuid=uuids[1], nb_lsp_uuid=uuids[2],
        nb_lsp_name="x05-tenant-b-vm", a_ports=frozenset({uuids[3]}),
        b_ports=frozenset({uuids[2], uuids[4]}), parent_ls_uuids=frozenset({uuids[1]}),
        sb_logical_port="x05-tenant-b-vm", sb_port_binding_uuid=uuids[5],
        sb_datapath=uuids[7],
    )
    unknown = C.EVALUATOR.CASObservation(
        a_ls_uuid=uuids[0], b_ls_uuid=uuids[1], nb_lsp_uuid=uuids[2],
        nb_lsp_name="x05-tenant-b-vm", a_ports=frozenset({uuids[3]}),
        b_ports=frozenset({uuids[4]}), parent_ls_uuids=frozenset(),
        sb_logical_port="x05-tenant-b-vm", sb_port_binding_uuid=uuids[5],
        sb_datapath=uuids[7],
    )
    check(C._EVALUATOR_CAS(baseline, moved, C.EVALUATOR.CASStage.MOVED_TO_A).outcome.value == "PASS", "exact A CAS failed")
    check(C._EVALUATOR_CAS(baseline, restored, C.EVALUATOR.CASStage.RESTORED_TO_B).outcome.value == "PASS", "exact B CAS failed")
    check(C._EVALUATOR_CAS(baseline, unknown, C.EVALUATOR.CASStage.RESTORED_TO_B).outcome.value == "FAIL", "unknown parent CAS passed")
    return {"status": "PASS", "positions": ["A", "B", "UNKNOWN"]}


def event_chain_checks(root: pathlib.Path) -> dict[str, Any]:
    evidence_dir = root / "events"
    evidence_dir.mkdir(mode=0o700)
    evidence = C._Evidence(evidence_dir, os.getuid())
    prepared = type(
        "Prepared",
        (),
        {"_event_head": "0" * 64, "_event_count": 0},
    )()
    session = object()
    original_record = C._SESSION_RECORD
    original_verify = C._SESSION_VERIFY

    def record(_session: Any, current: Any, event: str, detail: dict[str, Any]) -> dict[str, Any]:
        sequence = current._event_count + 1
        value = {
            "sequence": sequence,
            "event": event,
            "previous_sha256": current._event_head,
            "detail": {"detail": copy.deepcopy(detail)},
        }
        value["event_sha256"] = C._digest(value)
        current._event_count = sequence
        current._event_head = value["event_sha256"]
        return value

    try:
        C._SESSION_RECORD = record
        C._SESSION_VERIFY = lambda _session, _prepared: None
        chain = C._CoordinatorEvents(
            session=session,
            prepared=prepared,
            evidence=evidence,
            source_guard=lambda: None,
        )
        for state in C._COORDINATOR_STATES:
            chain.state(state, {"proof_sha256": C._sha256(state.encode("ascii"))})
        check(
            [item["label"] for item in chain.detached()]
            == ["state-" + state.lower().replace("_", "-") for state in C._COORDINATOR_STATES],
            "coordinator state sequence changed",
        )
        expect(
            C.CoordinatorSecurityError,
            lambda: chain.state("RESTORED", {}),
            "coordinator terminal state replay was accepted",
        )
        shadow_prepared = type(
            "Prepared",
            (),
            {"_event_head": "0" * 64, "_event_count": 0},
        )()
        shadow = C._CoordinatorEvents(
            session=session,
            prepared=shadow_prepared,
            evidence=evidence,
            source_guard=lambda: None,
        )
        expect(
            C.CoordinatorSecurityError,
            lambda: shadow.state("INTENT", {"state": "RESTORED"}),
            "coordinator state detail shadowed the canonical state",
        )
        check(
            shadow_prepared._event_count == 0 and shadow.detached() == [],
            "rejected state shadow changed the original event chain",
        )

        failed_prepared = type(
            "Prepared",
            (),
            {"_event_head": "0" * 64, "_event_count": 0},
        )()
        failed_dir = root / "events-failed"
        failed_dir.mkdir(mode=0o700)
        failed = C._CoordinatorEvents(
            session=session,
            prepared=failed_prepared,
            evidence=C._Evidence(failed_dir, os.getuid()),
            source_guard=lambda: None,
        )
        C._SESSION_RECORD = lambda *_args, **_kwargs: (_ for _ in ()).throw(
            RuntimeError("synthetic append failure")
        )
        expect(
            RuntimeError,
            lambda: failed.state("INTENT", {}),
            "coordinator append failure was hidden",
        )
        expect(
            C.CoordinatorSecurityError,
            lambda: failed.state("INTENT", {}),
            "coordinator append failure was not sticky",
        )
    finally:
        C._SESSION_RECORD = original_record
        C._SESSION_VERIFY = original_verify
    return {"status": "PASS", "states": list(C._COORDINATOR_STATES)}


def source_binding_checks(root: pathlib.Path) -> dict[str, Any]:
    bundle_root = C.HERE.parents[2]
    receipt_path = root / "source-pin-receipt.txt"
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    runtime_path = pathlib.Path(C.RUNTIME.__file__)
    runtime_sha256 = C._sha256(runtime_path.read_bytes())
    config = C._ADMISSION_CONFIG_TYPE(
        run_hex="a1b2c3",
        evidence_path=root / "evidence" / "P004" / "S002" / "a1b2c3" / "08-x05",
        receipt_path=receipt_path,
        k01_kubeconfig=root / "k01.config",
        p003_kubeconfig=root / "p003.config",
        bundle_root=bundle_root,
        required_uid=os.getuid(),
        test_only_paths=True,
        hostname=lambda: "source-pin-test-host",
        now=lambda: now,
    )

    def write_receipt(
        *,
        include_runtime_pin: bool = True,
        runtime_pin: str | None = None,
        k01_uid: str = "uid-k01-source-test",
    ) -> bytes:
        fields = [
            "k01_uid=" + k01_uid,
            "p003_gw_uid=uid-p003-source-test",
            "k01_canary=10/10",
            "p003_gw_canary=10/10",
            "timestamp=" + now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "host=source-pin-test-host",
        ]
        if include_runtime_pin:
            fields.append(
                "runtime_source_sha256="
                + (runtime_sha256 if runtime_pin is None else runtime_pin)
            )
        receipt_path.write_text("\n".join(fields) + "\n", encoding="utf-8")
        receipt_path.chmod(0o600)
        return receipt_path.read_bytes()

    def expect_message(
        error: type[BaseException], function: Any, fragment: str, message: str
    ) -> None:
        try:
            function()
        except error as exc:
            check(fragment in str(exc), message + ": wrong failure cause")
            return
        raise AssertionError(message)

    def capture() -> Any:
        return C._capture_source_bindings(config)

    write_receipt()
    bindings = capture()
    check(
        set(bindings.sources) == set(C._SOURCE_RELATIVE_PATHS)
        and bindings.receipt.path == receipt_path,
        "capture omitted a source or the receipt binding",
    )
    C._verify_source_bindings(bindings, config)

    write_receipt(include_runtime_pin=False)
    expect_message(
        C.RUNTIME.AdmissionError,
        capture,
        "preflight receipt keys are incomplete",
        "missing runtime receipt pin was accepted",
    )
    write_receipt(runtime_pin="A" * 64)
    expect_message(
        C.CoordinatorSecurityError,
        capture,
        "runtime source pin is invalid",
        "malformed runtime receipt pin was accepted",
    )
    write_receipt(runtime_pin="0" * 64)
    expect_message(
        C.CoordinatorSecurityError,
        capture,
        "coordinator source differs from reviewed pin: "
        + C._RUNTIME_SOURCE_RELATIVE_PATH,
        "runtime receipt pin mismatch was accepted",
    )

    write_receipt()
    original_pins = C.RUNTIME.REVIEWED_BUNDLE_FILES
    try:
        for relative in C._SOURCE_RELATIVE_PATHS:
            if relative == C._RUNTIME_SOURCE_RELATIVE_PATH:
                continue
            C.RUNTIME.REVIEWED_BUNDLE_FILES = {
                key: value for key, value in original_pins.items() if key != relative
            }
            expect_message(
                C.CoordinatorSecurityError,
                capture,
                "coordinator source lacks reviewed pin: " + relative,
                "missing subordinate source pin was accepted: " + relative,
            )
    finally:
        C.RUNTIME.REVIEWED_BUNDLE_FILES = original_pins

    original_loaded_path = C.EVALUATOR.__file__
    try:
        C.EVALUATOR.__file__ = str(root / "wrong-loaded-module.py")
        expect_message(
            C.CoordinatorSecurityError,
            capture,
            "loaded coordinator module path changed:",
            "loaded module path drift was accepted",
        )
    finally:
        C.EVALUATOR.__file__ = original_loaded_path

    original_validator = C.RUNTIME.LiveCollector.validate_receipt
    try:
        C.RUNTIME.LiveCollector.validate_receipt = lambda _self: {}
        expect_message(
            C.CoordinatorSecurityError,
            C._verify_graph,
            "canonical X05 module or callable graph changed",
            "receipt validator substitution was accepted",
        )
    finally:
        C.RUNTIME.LiveCollector.validate_receipt = original_validator
    C._verify_graph()

    write_receipt()
    runner = C._SUBPROCESS_RUNNER_TYPE()
    collector = C._LIVE_COLLECTOR_TYPE(config, runner)
    redirected_config = C._ADMISSION_CONFIG_TYPE(
        run_hex="a1b2c3",
        evidence_path=root / "evidence" / "P004" / "S002" / "a1b2c3" / "08-x05",
        receipt_path=root / "redirected-receipt.txt",
        k01_kubeconfig=root / "k01.config",
        p003_kubeconfig=root / "p003.config",
        bundle_root=bundle_root,
        required_uid=os.getuid(),
        test_only_paths=True,
        hostname=lambda: "source-pin-test-host",
        now=lambda: now,
    )
    object.__setattr__(collector, "config", redirected_config)
    expect_message(
        C.CoordinatorSecurityError,
        lambda: C._assert_receipt_collector_binding(config, runner, collector),
        "preflight receipt collector configuration was redirected",
        "collector configuration redirection was accepted",
    )
    object.__setattr__(collector, "config", config)
    redirected_runner = C._SUBPROCESS_RUNNER_TYPE()
    object.__setattr__(collector, "runner", redirected_runner)
    expect_message(
        C.CoordinatorSecurityError,
        lambda: C._assert_receipt_collector_binding(config, runner, collector),
        "preflight receipt collector runner was redirected",
        "collector runner redirection was accepted",
    )

    receipt_path.chmod(0o640)
    expect_message(
        C.CoordinatorSecurityError,
        capture,
        "required source identity is unsafe",
        "unsafe receipt mode was accepted",
    )
    receipt_path.chmod(0o600)

    original_read = C._read_regular
    receipt_mutated = False

    def mutate_during_receipt_capture(path: pathlib.Path, **kwargs: Any) -> Any:
        nonlocal receipt_mutated
        result = original_read(path, **kwargs)
        if path == receipt_path and not receipt_mutated:
            receipt_mutated = True
            write_receipt(k01_uid="uid-k01-mutated-test")
        return result

    try:
        C._read_regular = mutate_during_receipt_capture
        expect_message(
            C.CoordinatorSecurityError,
            capture,
            "preflight receipt changed while being captured",
            "receipt mutation during capture was accepted",
        )
    finally:
        C._read_regular = original_read

    write_receipt()
    bindings = capture()
    original_receipt_bytes = receipt_path.read_bytes()
    replacement = root / "source-pin-receipt-replacement.txt"
    replacement.write_bytes(original_receipt_bytes)
    replacement.chmod(0o600)
    os.replace(replacement, receipt_path)
    expect_message(
        C.CoordinatorSecurityError,
        lambda: C._verify_source_bindings(bindings, config),
        "preflight receipt source binding changed",
        "receipt inode drift was accepted",
    )

    bindings = capture()
    runtime_source_path = bundle_root / C._RUNTIME_SOURCE_RELATIVE_PATH

    def changed_source_identity(path: pathlib.Path, **kwargs: Any) -> Any:
        raw, identity = original_read(path, **kwargs)
        if path == runtime_source_path:
            identity = (identity[0] + 1, *identity[1:])
        return raw, identity

    try:
        C._read_regular = changed_source_identity
        expect_message(
            C.CoordinatorSecurityError,
            lambda: C._verify_source_bindings(bindings, config),
            "reviewed coordinator source changed: " + C._RUNTIME_SOURCE_RELATIVE_PATH,
            "source inode drift was accepted",
        )
    finally:
        C._read_regular = original_read

    def changed_source_bytes(path: pathlib.Path, **kwargs: Any) -> Any:
        raw, identity = original_read(path, **kwargs)
        if path == bundle_root / C.CAS_RELATIVE_PATH:
            raw += b"drift"
        return raw, identity

    try:
        C._read_regular = changed_source_bytes
        expect_message(
            C.CoordinatorSecurityError,
            lambda: C._verify_source_bindings(bindings, config),
            "reviewed coordinator source changed: " + C.CAS_RELATIVE_PATH,
            "source bytes drift was accepted",
        )
    finally:
        C._read_regular = original_read

    return {"status": "PASS", "sources": len(bindings.sources), "receipt": True}


def execute_cli_boundary_checks(root: pathlib.Path) -> dict[str, Any]:
    bundle_root = C.HERE.parents[2]
    receipt_path = root / "execute-cli-receipt.txt"
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    runtime_sha256 = C._sha256(pathlib.Path(C.RUNTIME.__file__).read_bytes())
    test_host = "source-pin-cli-test-host"

    def write_receipt(
        runtime_pin: str | None = runtime_sha256,
    ) -> None:
        fields = (
            "k01_uid=uid-k01-cli-test\n"
            "p003_gw_uid=uid-p003-cli-test\n"
            "k01_canary=10/10\n"
            "p003_gw_canary=10/10\n"
            "timestamp=" + now.strftime("%Y-%m-%dT%H:%M:%SZ") + "\n"
            "host=" + test_host + "\n"
        )
        if runtime_pin is not None:
            fields += "runtime_source_sha256=" + runtime_pin + "\n"
        receipt_path.write_text(fields, encoding="utf-8")
        receipt_path.chmod(0o600)

    events: list[str] = []
    captured_bindings: list[Any] = []
    prepared = object()
    result = object()

    originals = {
        "required_environment": C._required_environment,
        "exclusive_run_parent": C._exclusive_run_parent,
        "execute_bound": C._execute_bound,
        "capture_source_bindings": C._capture_source_bindings,
        "evidence_root": C.EVIDENCE_ROOT,
        "geteuid": C.os.geteuid,
        "platform": C.sys.platform,
        "config_post_init": C._ADMISSION_CONFIG_TYPE.__dict__["__post_init__"],
        "session_init": C._ADMISSION_SESSION_TYPE.__dict__["__init__"],
        "session_enter": C._ADMISSION_SESSION_TYPE.__dict__["__enter__"],
        "session_prepare": C._ADMISSION_SESSION_TYPE.__dict__["prepare"],
        "collector_init": C._LIVE_COLLECTOR_TYPE.__dict__["__init__"],
        "runner_init": C._SUBPROCESS_RUNNER_TYPE.__dict__["__init__"],
    }
    original_pins = C.RUNTIME.REVIEWED_BUNDLE_FILES
    next_run = iter(("a1b2c3",))

    def configure_test_admission(config: Any) -> None:
        originals["config_post_init"](config)
        object.__setattr__(config, "bundle_root", bundle_root)
        object.__setattr__(config, "required_uid", os.getuid())
        object.__setattr__(config, "hostname", lambda: test_host)
        object.__setattr__(config, "now", lambda: now)

    def allocate_fake_run() -> tuple[str, pathlib.Path]:
        run_hex = next(next_run)
        events.append("allocate")
        return run_hex, C.EVIDENCE_ROOT / run_hex

    try:
        C.EVIDENCE_ROOT = root / "evidence" / "P004" / "S002"
        C.os.geteuid = lambda: 0
        C.sys.platform = "linux"
        C._ADMISSION_CONFIG_TYPE.__post_init__ = configure_test_admission
        C._required_environment = lambda: (
            receipt_path,
            root / "k01.config",
            root / "p003.config",
        )
        C._exclusive_run_parent = allocate_fake_run
        def capture_source_bindings(config: Any) -> Any:
            binding = originals["capture_source_bindings"](config)
            captured_bindings.append(binding)
            return binding

        C._capture_source_bindings = capture_source_bindings
        C._ADMISSION_SESSION_TYPE.__init__ = lambda _self, _config: events.append("construct")
        C._ADMISSION_SESSION_TYPE.__enter__ = lambda _self: events.append("enter")
        C._ADMISSION_SESSION_TYPE.prepare = lambda _self: (events.append("prepare"), prepared)[1]

        def execute_bound(current: Any, binding: Any) -> Any:
            check(current is prepared, "CLI handed a different prepared admission")
            check(captured_bindings and binding is captured_bindings[0], "CLI adopted a new source binding")
            events.append("execute")
            return result

        C._execute_bound = execute_bound

        write_receipt(None)
        expect_message(
            C.RUNTIME.AdmissionError,
            C._execute_cli,
            "preflight receipt keys are incomplete",
            "missing runtime receipt pin reached session construction",
        )
        check(events == [], "missing receipt pin caused a session or run allocation")

        write_receipt("bad-runtime-pin")
        expect_message(
            C.CoordinatorSecurityError,
            C._execute_cli,
            "runtime source pin is invalid",
            "malformed runtime receipt pin reached session construction",
        )
        check(events == [], "malformed receipt pin caused a session or run allocation")

        write_receipt("0" * 64)
        expect_message(
            C.CoordinatorSecurityError,
            C._execute_cli,
            "coordinator source differs from reviewed pin: "
            + C._RUNTIME_SOURCE_RELATIVE_PATH,
            "runtime source hash mismatch reached session construction",
        )
        check(events == [], "runtime source mismatch caused a session or run allocation")

        collector_init_calls: list[str] = []

        def redirect_collector_init(current: Any, config: Any, runner: Any) -> None:
            collector_init_calls.append("called")
            originals["collector_init"](current, config, runner)
            object.__setattr__(current, "config", object())

        C.RUNTIME.LiveCollector.__init__ = redirect_collector_init
        write_receipt()
        expect_message(
            C.CoordinatorSecurityError,
            C._execute_cli,
            "canonical X05 module or callable graph changed",
            "collector constructor replacement reached receipt validation",
        )
        check(
            events == [] and collector_init_calls == [],
            "collector constructor substitution allocated or admitted a run",
        )
        C.RUNTIME.LiveCollector.__init__ = originals["collector_init"]

        runner_init_calls: list[str] = []

        def redirect_runner_init(current: Any, *, terminate_grace: float = 0.25) -> None:
            runner_init_calls.append("called")
            originals["runner_init"](current, terminate_grace=terminate_grace)

        C.RUNTIME.SubprocessRunner.__init__ = redirect_runner_init
        expect_message(
            C.CoordinatorSecurityError,
            C._execute_cli,
            "canonical X05 module or callable graph changed",
            "runner constructor replacement reached receipt validation",
        )
        check(
            events == [] and runner_init_calls == [],
            "runner constructor substitution allocated or admitted a run",
        )
        C.RUNTIME.SubprocessRunner.__init__ = originals["runner_init"]

        missing_pin = C.CAS_RELATIVE_PATH
        C.RUNTIME.REVIEWED_BUNDLE_FILES = {
            key: value for key, value in original_pins.items() if key != missing_pin
        }
        write_receipt()
        expect_message(
            C.CoordinatorSecurityError,
            C._execute_cli,
            "coordinator source lacks reviewed pin: " + missing_pin,
            "missing subordinate source pin reached session construction",
        )
        check(events == [], "subordinate source pin failure caused a session or run allocation")
        C.RUNTIME.REVIEWED_BUNDLE_FILES = original_pins

        events.clear()
        write_receipt()
        check(C._execute_cli() is result, "valid preflight did not reach the fixed execute boundary")
        check(
            events == ["allocate", "construct", "enter", "prepare", "execute"],
            "source capture did not precede session construction and prepare",
        )
        check(len(captured_bindings) == 1, "CLI recaptured source bindings at the execution seam")
    finally:
        C._required_environment = originals["required_environment"]
        C._exclusive_run_parent = originals["exclusive_run_parent"]
        C._execute_bound = originals["execute_bound"]
        C._capture_source_bindings = originals["capture_source_bindings"]
        C.RUNTIME.REVIEWED_BUNDLE_FILES = original_pins
        C.EVIDENCE_ROOT = originals["evidence_root"]
        C.os.geteuid = originals["geteuid"]
        C.sys.platform = originals["platform"]
        C._ADMISSION_CONFIG_TYPE.__post_init__ = originals["config_post_init"]
        C._ADMISSION_SESSION_TYPE.__init__ = originals["session_init"]
        C._ADMISSION_SESSION_TYPE.__enter__ = originals["session_enter"]
        C._ADMISSION_SESSION_TYPE.prepare = originals["session_prepare"]
        C.RUNTIME.LiveCollector.__init__ = originals["collector_init"]
        C.RUNTIME.SubprocessRunner.__init__ = originals["runner_init"]
    return {"status": "PASS", "events": events}


def execute_preconsume_source_failure_check(root: pathlib.Path) -> dict[str, Any]:
    bundle_root = C.HERE.parents[2]
    receipt_path = root / "execute-preconsume-receipt.txt"
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    run_hex = "f1e2d3"
    original_evidence_root = C.EVIDENCE_ROOT
    C.EVIDENCE_ROOT = root / "evidence" / "P004" / "S002"
    evidence_path = C.EVIDENCE_ROOT / run_hex / "08-x05"
    evidence_path.parent.mkdir(parents=True, mode=0o700)
    evidence_path.parent.chmod(0o700)
    config = C._ADMISSION_CONFIG_TYPE(
        run_hex=run_hex,
        evidence_path=evidence_path,
        receipt_path=receipt_path,
        k01_kubeconfig=root / "k01.config",
        p003_kubeconfig=root / "p003.config",
    )
    object.__setattr__(config, "bundle_root", bundle_root)
    object.__setattr__(config, "required_uid", os.getuid())
    object.__setattr__(config, "hostname", lambda: "execute-preconsume-host")
    object.__setattr__(config, "now", lambda: now)
    receipt_path.write_text(
        "k01_uid=uid-k01-execute-test\n"
        "p003_gw_uid=uid-p003-execute-test\n"
        "k01_canary=10/10\n"
        "p003_gw_canary=10/10\n"
        "timestamp=" + now.strftime("%Y-%m-%dT%H:%M:%SZ") + "\n"
        "host=execute-preconsume-host\n"
        "runtime_source_sha256=" + "0" * 64 + "\n",
        encoding="utf-8",
    )
    receipt_path.chmod(0o600)

    session = C._ADMISSION_SESSION_TYPE(config)
    event_authority = C.RUNTIME._EventLogAuthority(
        descriptor=0,
        identity=(0, 0),
        mode=0o600,
        uid=os.getuid(),
        status_flags=0,
        descriptor_flags=0,
    )
    session._entered = True
    session._event_authority = event_authority
    prepared = C._PREPARED_ADMISSION_TYPE(
        session,
        snapshot_path=root / "snapshot.json",
        snapshot_sha256="1" * 64,
        snapshot_file_sha256="2" * 64,
        inputs_sha256="3" * 64,
        anchors_sha256="4" * 64,
        bundle_manifest_sha256="5" * 64,
        event_head="6" * 64,
        event_count=0,
    )
    session._prepared = prepared

    capture_calls: list[int] = []
    original_capture = C._capture_source_bindings

    def capture_once(config: Any) -> Any:
        capture_calls.append(1)
        return original_capture(config)

    try:
        C._capture_source_bindings = capture_once
        try:
            C.execute(prepared)
        except C.CoordinatorSecurityError as exc:
            check(
                "coordinator source differs from reviewed pin: "
                + C._RUNTIME_SOURCE_RELATIVE_PATH
                in str(exc),
                "execute source failure had the wrong cause",
            )
        else:
            raise AssertionError("execute accepted a mismatched runtime source pin")
        check(not prepared.consumed, "execute consumed admission before source capture passed")
        check(
            session._prepared is prepared and session._execution_failure is None,
            "preconsume source failure changed producer execution state",
        )
        check(capture_calls == [1], "public execute recaptured source bindings")
    finally:
        C._capture_source_bindings = original_capture
        session.events.close()
        prepared._invalidate()
        C.EVIDENCE_ROOT = original_evidence_root
    return {"status": "PASS", "consumed": prepared.consumed}


def execute_handoff_replacement_check(root: pathlib.Path) -> dict[str, Any]:
    """Reject a receipt replacement between capture A and private execution."""
    bundle_root = C.HERE.parents[2]
    receipt_path = root / "execute-handoff-receipt.txt"
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    run_hex = "a4b5c6"
    original_evidence_root = C.EVIDENCE_ROOT
    C.EVIDENCE_ROOT = root / "evidence" / "P004" / "S002"
    evidence_path = C.EVIDENCE_ROOT / run_hex / "08-x05"
    evidence_path.parent.mkdir(parents=True, mode=0o700)
    evidence_path.parent.chmod(0o700)
    config = C._ADMISSION_CONFIG_TYPE(
        run_hex=run_hex,
        evidence_path=evidence_path,
        receipt_path=receipt_path,
        k01_kubeconfig=root / "k01.config",
        p003_kubeconfig=root / "p003.config",
    )
    object.__setattr__(config, "bundle_root", bundle_root)
    object.__setattr__(config, "required_uid", os.getuid())
    object.__setattr__(config, "hostname", lambda: "execute-handoff-host")
    object.__setattr__(config, "now", lambda: now)
    receipt = (
        "k01_uid=uid-k01-handoff-test\n"
        "p003_gw_uid=uid-p003-handoff-test\n"
        "k01_canary=10/10\n"
        "p003_gw_canary=10/10\n"
        "timestamp=" + now.strftime("%Y-%m-%dT%H:%M:%SZ") + "\n"
        "host=execute-handoff-host\n"
        "runtime_source_sha256="
        + C._sha256(pathlib.Path(C.RUNTIME.__file__).read_bytes())
        + "\n"
    ).encode()
    receipt_path.write_bytes(receipt)
    receipt_path.chmod(0o600)

    session = C._ADMISSION_SESSION_TYPE(config)
    event_authority = C.RUNTIME._EventLogAuthority(
        descriptor=0,
        identity=(0, 0),
        mode=0o600,
        uid=os.getuid(),
        status_flags=0,
        descriptor_flags=0,
    )
    session._entered = True
    session._event_authority = event_authority
    prepared = C._PREPARED_ADMISSION_TYPE(
        session,
        snapshot_path=root / "handoff-snapshot.json",
        snapshot_sha256="1" * 64,
        snapshot_file_sha256="2" * 64,
        inputs_sha256="3" * 64,
        anchors_sha256="4" * 64,
        bundle_manifest_sha256="5" * 64,
        event_head="6" * 64,
        event_count=0,
    )
    session._prepared = prepared
    try:
        captured = C._capture_source_bindings(config)
        replacement = root / "handoff-receipt-replacement.txt"
        replacement.write_bytes(receipt)
        replacement.chmod(0o600)
        os.replace(replacement, receipt_path)
        try:
            C._execute_bound(prepared, captured)
        except C.CoordinatorSecurityError as exc:
            check(
                "preflight receipt source binding changed" in str(exc),
                "postprepare receipt replacement had the wrong refusal cause",
            )
        else:
            raise AssertionError("private execution adopted a replacement receipt")
        check(not prepared.consumed, "handoff replacement reached producer consume")
        check(
            session._execution_failure is None,
            "handoff replacement changed producer execution state",
        )
        check(getattr(session, "_event_count", 0) == 0, "handoff replacement emitted an execution event")
    finally:
        session.events.close()
        prepared._invalidate()
        C.EVIDENCE_ROOT = original_evidence_root
    return {"status": "PASS", "consumed": prepared.consumed}


def boundary_checks(root: pathlib.Path) -> dict[str, Any]:
    evidence_dir = root / "exclusive"
    evidence_dir.mkdir(mode=0o700)
    evidence = C._Evidence(evidence_dir, os.getuid())
    evidence.write("one.bin", b"one")
    expect(C.CoordinatorSecurityError, lambda: evidence.write("one.bin", b"two"), "evidence overwrite was accepted")
    expect(C.CoordinatorSecurityError, lambda: C._execution_preconditions(object()), "opaque admission was accepted")
    original_ping = C.EVALUATOR.evaluate_ping
    try:
        C.EVALUATOR.evaluate_ping = lambda *_args, **_kwargs: None
        expect(C.CoordinatorSecurityError, C._verify_graph, "evaluator callable drift was accepted")
    finally:
        C.EVALUATOR.evaluate_ping = original_ping
    C._verify_graph()
    dry = C._dry_run()
    check(dry["status"] == "READY" and dry["writes"] == 0 and dry["subprocesses"] == 0, "dry-run is not zero effect")

    original_close = C._SESSION_CLOSE
    close_calls: list[Any] = []

    class OpenSession:
        _closed = False
        marker_absent_after_unlink = True
        terminal_completion_unknown = True

    try:
        C._SESSION_CLOSE = lambda session: close_calls.append(session)
        check(not C._close_pre_handoff_failure(OpenSession(), True), "post-handoff failure attempted producer close")
        check(close_calls == [], "post-handoff marker-absence path closed the producer")
        check(C._close_pre_handoff_failure(OpenSession(), False), "pre-handoff failure did not use producer close")
        check(len(close_calls) == 1, "pre-handoff producer close count changed")
    finally:
        C._SESSION_CLOSE = original_close

    original_execute = C._execute_cli
    try:
        C._execute_cli = lambda: (_ for _ in ()).throw(C.InputNotReady("missing fixed input"))
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            check(C.main(["--execute"]) == 75, "explicit pre-admission input failure did not return 75")
        C._execute_cli = lambda: (_ for _ in ()).throw(ValueError("post-effect synthetic"))
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            check(C.main(["--execute"]) == 1, "post-admission ValueError was mislabeled 75")
        parsed = json.loads(output.getvalue())
        check(parsed["status"] == "ERROR" and "post-effect synthetic" in parsed["reason"], "post-admission error output is not honest")
    finally:
        C._execute_cli = original_execute
    return {"status": "PASS", "dry_run": dry}


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="p004-x05-coordinator-selftest.") as temporary:
        root = pathlib.Path(temporary)
        os.chmod(root, 0o700)
        result = {
            "schema": "p004-x05-coordinator-selftest-v1",
            "status": "PASS",
            "decoder": decoder_checks(),
            "poll": bounded_poll_checks(root),
            "cas": cas_checks(),
            "events": event_chain_checks(root),
            "source_bindings": source_binding_checks(root),
            "execute_preconsume_source_failure": execute_preconsume_source_failure_check(root),
            "execute_handoff_replacement": execute_handoff_replacement_check(root),
            "execute_cli_boundary": execute_cli_boundary_checks(root),
            "boundaries": boundary_checks(root),
        }
    result["assertions"] = ASSERTIONS
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
