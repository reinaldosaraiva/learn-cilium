#!/usr/bin/env bash
# Synthetic local checks only. Never invokes --live.
set -euo pipefail
fixture_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
python3 - "${fixture_dir}" <<'PY'
import copy
import json
import pathlib
import subprocess
import sys
import tempfile

directory = pathlib.Path(sys.argv[1])
checker = directory / "x05-nb-preflight.sh"
source = json.loads((directory / "x05-nb-preflight-fixture.json").read_text())


def check(label, mutation, expected_status, reason=None):
    data = copy.deepcopy(source)
    mutation(data)
    with tempfile.TemporaryDirectory(prefix="x05-nb-preflight-") as temp:
        path = pathlib.Path(temp) / "snapshot.json"
        path.write_text(json.dumps(data))
        result = subprocess.run(["bash", str(checker), "--fixture", str(path)],
                                capture_output=True, text=True, check=False)
    try:
        report = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise AssertionError(label + ": invalid report: " + result.stdout) from exc
    assert report["status"] == expected_status, (label, report)
    assert (result.returncode == 0) == (expected_status == "PASS"), (label, result)
    if reason:
        assert reason in report["reason"], (label, report)
    if expected_status == "PASS":
        assert report["planned_rows_absent"] == 34, report
        assert len(report["a_fingerprint"]["ls_ports"]) == 2, report
    print(label + " PASS")


check("clean", lambda data: None, "PASS")
check("name_collision", lambda data: data["tables"]["Logical_Switch_Port"].append({
    "_uuid": "00000000-0000-4000-8000-000000000006",
    "name": "x05-tenant-b-vm", "external_ids": {}, "type": "",
    "options": {}}), "FAIL", "planned NB collision")
check("unrelated_route", lambda data: data["tables"]["Logical_Router_Static_Route"].append({
    "_uuid": "00000000-0000-4000-8000-000000000006",
    "ip_prefix": "192.168.100.0/24", "nexthop": "10.31.100.1",
    "external_ids": {}}), "PASS")


def same_route_in_two_routers(data):
    route_a = "00000000-0000-4000-8000-000000000006"
    route_other = "00000000-0000-4000-8000-000000000008"
    data["tables"]["Logical_Router"][0]["static_routes"] = [route_a]
    data["tables"]["Logical_Router"].append({
        "_uuid": "00000000-0000-4000-8000-000000000007",
        "name": "lr-unrelated", "external_ids": {}, "ports": [],
        "static_routes": [route_other]})
    for route_uuid in (route_a, route_other):
        data["tables"]["Logical_Router_Static_Route"].append({
            "_uuid": route_uuid, "ip_prefix": "192.168.100.0/24",
            "nexthop": "10.31.100.1", "external_ids": {}})


check("same_route_two_routers", same_route_in_two_routers, "PASS")


def ambiguous_route(data):
    data["tables"]["Logical_Router"][0]["static_routes"] = [
        "00000000-0000-4000-8000-000000000006",
        "00000000-0000-4000-8000-000000000007"]
    data["tables"]["Logical_Router_Static_Route"].extend([
    {"_uuid": "00000000-0000-4000-8000-000000000006",
     "ip_prefix": "203.0.113.0/24", "nexthop": "203.0.113.1", "external_ids": {}},
    {"_uuid": "00000000-0000-4000-8000-000000000007",
     "ip_prefix": "203.0.113.0/24", "nexthop": "203.0.113.1", "external_ids": {}}])


check("ambiguous_route", ambiguous_route, "FAIL", "ambiguous static route")
check("stray_x05_name", lambda data: data["tables"]["Logical_Switch"].append({
    "_uuid": "00000000-0000-4000-8000-000000000006",
    "name": "ls-x05-stray", "external_ids": {}, "ports": []}),
    "FAIL", "unexpected X05 name residue")
check("a_router_lsp_renamed", lambda data: data["tables"]["Logical_Switch_Port"][0]
      .__setitem__("name", "unrelated-lsp"), "FAIL", "A tenant LSP identity")
check("a_router_lsp_mislinked", lambda data: data["tables"]["Logical_Switch_Port"][0]
      ["options"].__setitem__("router-port", "wrong"),
      "FAIL", "A tenant router LSP linkage")
check("owner_residue", lambda data: data["tables"]["Gateway_Chassis"].append({
    "_uuid": "00000000-0000-4000-8000-000000000006",
    "name": "unrelated", "external_ids": {"x05-owner": "old"}}),
    "FAIL", "x05-owner residue")
check("nb_cfg_drift", lambda data: data.__setitem__("nb_cfg_after", 43),
    "FAIL", "nb_cfg changed")
check("malformed_ports", lambda data: data["tables"]["Logical_Switch"][0].__setitem__(
    "ports", ["bad"]), "FAIL", "invalid UUID")
check("missing_a", lambda data: data["tables"]["Logical_Router_Port"].clear(),
    "FAIL", "missing M03 A")

with tempfile.TemporaryDirectory(prefix="x05-nb-preflight-") as temp:
    path = pathlib.Path(temp) / "invalid.json"
    path.write_text('{"schema": "bad",')
    result = subprocess.run(["bash", str(checker), "--fixture", str(path)],
                            capture_output=True, text=True, check=False)
    assert result.returncode != 0
    assert json.loads(result.stdout)["status"] == "FAIL"
    assert "malformed JSON" in result.stdout
print("malformed_json PASS")
PY
