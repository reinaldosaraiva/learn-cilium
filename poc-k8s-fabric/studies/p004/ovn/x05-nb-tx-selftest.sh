#!/usr/bin/env bash
# Synthetic, local-only checks for the X05 forward NB transaction.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$here" <<'PY'
import copy
import json
import pathlib
import subprocess
import sys
import tempfile

here = pathlib.Path(sys.argv[1])
tx_tool = here / "x05-nb-tx.py"
preflight_tool = here / "x05-nb-preflight.sh"
fixture = here / "x05-nb-preflight-fixture.json"


def run(*args, ok=True):
    result = subprocess.run(args, capture_output=True, text=True, timeout=20)
    assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
    return result


def saved(directory, name, value):
    path = directory / name
    path.write_text(json.dumps(value))
    return path


with tempfile.TemporaryDirectory() as temporary:
    directory = pathlib.Path(temporary)
    proof = json.loads(run("bash", str(preflight_tool), "--fixture", str(fixture)).stdout)
    proof_path = saved(directory, "preflight.json", proof)
    transaction = json.loads(run("python3", str(tx_tool), "--build", str(proof_path),
                                 "--owner", "labctl-x05-a1b2c3", "--run-hex", "a1b2c3").stdout)
    assert transaction[0] == "OVN_Northbound"
    operations = transaction[1:]
    waits = [operation for operation in operations if operation["op"] == "wait"]
    inserts = [operation for operation in operations if operation["op"] == "insert"]
    assert len(waits) == 31 and len(inserts) == 34 and len(operations) == 66
    assert len({operation["uuid-name"] for operation in inserts}) == 34
    assert waits[0]["rows"] == [{"ports": ["set", [["uuid", port]
                                         for port in proof["a_fingerprint"]["ls_ports"]]]}]
    assert ["name", "==", "ls-mgc-tenant"] in waits[0]["where"]
    assert len({(wait["table"], wait["where"][0][2]) for wait in waits[1:]}) == 30
    assert all(wait["rows"] == [] and wait["timeout"] == 0 for wait in waits[1:])
    assert all(operation["row"]["external_ids"] ==
               ["map", [["x05-owner", "labctl-x05-a1b2c3"]]] for operation in inserts)
    by_name = {operation["row"].get("name"): operation for operation in inserts
               if "name" in operation["row"]}
    assert len(by_name) == 30
    assert by_name["lrp-x05-tenant-b"]["row"]["options"] == (
        ["map", [["dynamic-routing-maintain-vrf", "true"],
                  ["dynamic-routing-port-name", "x05-b-a1b2c3"]]])
    assert ["named-uuid", by_name["gc-x05-300"]["uuid-name"]] in \
        by_name["lrp-x05-300-external"]["row"]["gateway_chassis"][1]
    assert ["named-uuid", by_name["gc-x05-400"]["uuid-name"]] in \
        by_name["lrp-x05-400-external"]["row"]["gateway_chassis"][1]
    for parent in ("ls-x05-tenant-b", "lr-x05-tenant-b", "lr-x05-300", "lr-x05-400"):
        assert by_name[parent]["row"]["ports"][1]
    assert len(by_name["lr-x05-tenant-b"]["row"]["static_routes"][1]) == 2
    assert operations[-1]["op"] == "mutate" and operations[-1]["mutations"][0][1] == "insert"
    assert operations[-1]["where"] == waits[0]["where"]
    assert all("NB_Global" != operation["table"] for operation in operations)

    # The real preflight rejects absent A, duplicate names and foreign owners.
    snapshot = json.loads(fixture.read_text())
    missing = copy.deepcopy(snapshot)
    missing["tables"]["Logical_Switch"] = []
    run("bash", str(preflight_tool), "--fixture",
        str(saved(directory, "missing-a.json", missing)), ok=False)
    duplicate = copy.deepcopy(snapshot)
    duplicate["tables"]["Logical_Switch"].append(
        copy.deepcopy(duplicate["tables"]["Logical_Switch"][0]))
    duplicate["tables"]["Logical_Switch"][-1]["_uuid"] = "00000000-0000-4000-8000-000000000099"
    run("bash", str(preflight_tool), "--fixture",
        str(saved(directory, "duplicate.json", duplicate)), ok=False)
    foreign = copy.deepcopy(snapshot)
    foreign["tables"]["Logical_Switch"][0]["external_ids"] = {"x05-owner": "foreign"}
    run("bash", str(preflight_tool), "--fixture",
        str(saved(directory, "foreign.json", foreign)), ok=False)
    fail_proof = copy.deepcopy(proof)
    fail_proof["status"] = "FAIL"
    run("python3", str(tx_tool), "--build",
        str(saved(directory, "fail-proof.json", fail_proof)), "--owner", "labctl-x05-a1b2c3",
        "--run-hex", "a1b2c3", ok=False)
    run("python3", str(tx_tool), "--build", str(proof_path),
        "--owner", "labctl-x05-deadbe", "--run-hex", "a1b2c3", ok=False)

    response = [{} for _ in waits]
    response += [{"uuid": ["uuid", f"00000000-0000-4000-8000-{index + 100:012x}"]}
                 for index in range(1, 35)]
    response.append({"count": 1})
    good = saved(directory, "result.json", {"result": response, "error": None})
    check_args = ("--preflight", str(proof_path), "--owner", "labctl-x05-a1b2c3",
                  "--run-hex", "a1b2c3")
    checked = json.loads(run("python3", str(tx_tool), "--check-result",
                             str(good), *check_args).stdout)
    assert checked["status"] == "PASS" and len(checked["inserted"]) == 34
    assert checked["owner"] == "labctl-x05-a1b2c3"
    assert checked["a_fingerprint"] == proof["a_fingerprint"]
    journal = saved(directory, "forward-checked.json", checked)
    objects = json.loads(run("bash", str(here / "x05-nb-plan.sh"), "--plan").stdout)["objects"]
    named = {operation["uuid-name"]: checked["inserted"][item["id"]]
             for item, operation in zip(objects, inserts)}

    def resolve(value):
        if isinstance(value, list) and len(value) == 2 and value[0] == "named-uuid":
            return ["uuid", named[value[1]]]
        if isinstance(value, list):
            return [resolve(child) for child in value]
        if isinstance(value, dict):
            return {key: resolve(child) for key, child in value.items()}
        return value

    state = {"schema": "p004-x05-nb-full-snapshot-v1", "nb_cfg_before": 7,
             "nb_cfg_after": 7,
             "tables": {table: [] for table in ("Logical_Switch", "Logical_Router",
                 "Logical_Switch_Port", "Logical_Router_Port", "Gateway_Chassis",
                 "Logical_Router_Static_Route", "Network_Function", "Port_Group",
                 "Logical_Router_Policy", "NAT")}}
    for item, operation in zip(objects, inserts):
        row = {"_uuid": checked["inserted"][item["id"]],
               **resolve(operation["row"])}
        if item["table"] == "Logical_Router_Port":
            row.setdefault("gateway_chassis", ["set", []])
        state["tables"][item["table"]].append(row)
    state["tables"]["Logical_Switch"].append({
        "_uuid": proof["a_fingerprint"]["ls_uuid"], "name": "ls-mgc-tenant",
        "ports": ["set", [["uuid", port] for port in
                          proof["a_fingerprint"]["ls_ports"] +
                          [checked["inserted"]["Logical_Switch_Port:x05-tenant-a-vm"]]]]})
    state_path = saved(directory, "full-state.json", state)
    assert json.loads(run("bash", str(here / "x05-nb-full-snapshot.sh"),
                          "--fixture", str(state_path)).stdout)["nb_cfg_after"] == 7
    inverse = json.loads(run("python3", str(tx_tool), "--build-inverse",
                             str(proof_path), str(journal), "--owner", "labctl-x05-a1b2c3",
                             "--run-hex", "a1b2c3", "--state", str(state_path)).stdout)
    assert inverse[0] == "OVN_Northbound" and len(inverse) == 80
    inverse_waits = inverse[1:45]
    assert len(inverse_waits) == 44 and all(op["op"] == "wait" for op in inverse_waits)
    assert ["name", "==", "ls-mgc-tenant"] in inverse_waits[0]["where"]
    assert ["name", "==", "lr-mgc-tenant"] in inverse_waits[1]["where"]
    assert ["name", "==", "lrp-mgc-tenant"] in inverse_waits[2]["where"]
    assert inverse_waits[1]["rows"] == [{"ports": ["set", [["uuid", port]
        for port in proof["a_fingerprint"]["lr_ports"]]]}]
    assert len(inverse_waits[0]["rows"][0]["ports"][1]) == len(
        proof["a_fingerprint"]["ls_ports"]) + 1
    assert all(wait["rows"][0]["external_ids"] ==
               ["map", [["x05-owner", "labctl-x05-a1b2c3"]]]
               for wait in inverse_waits[3:37])
    assert {wait["table"] for wait in inverse_waits[37:]} == {
        "Logical_Switch", "Network_Function", "Port_Group", "Logical_Router",
        "Logical_Router_Port", "Logical_Router_Policy", "NAT"}
    assert all(wait["where"] == [] and "_uuid" in wait["columns"]
               for wait in inverse_waits[37:])
    assert inverse[45]["op"] == "mutate" and inverse[45]["mutations"][0][1] == "delete"
    deletes = inverse[46:]
    assert len(deletes) == 34 and all(op["op"] == "delete" for op in deletes)
    assert len({op["where"][0][2][1] for op in deletes}) == 34
    inverse_response = [{} for _ in inverse_waits] + [{"count": 1} for _ in range(35)]
    inverse_good = saved(directory, "inverse-result.json", {"result": inverse_response})
    inverse_check_args = ("--preflight", str(proof_path), "--forward", str(journal),
                          "--state", str(state_path))
    assert json.loads(run("python3", str(tx_tool), "--check-inverse-result",
                          str(inverse_good), *inverse_check_args).stdout)["deleted_owned_rows"] == 34
    for bad_entry in (None, {"count": 0}, {"count": True}, {"error": "constraint"}):
        bad = copy.deepcopy(inverse_response)
        bad[-1] = bad_entry
        run("python3", str(tx_tool), "--check-inverse-result",
            str(saved(directory, "bad-inverse.json", {"result": bad})),
            *inverse_check_args, ok=False)
    moved = copy.deepcopy(checked)
    moved["inserted"]["Logical_Switch_Port:x05-tenant-a-vm"] = proof["a_fingerprint"]["ls_ports"][0]
    run("python3", str(tx_tool), "--build-inverse", str(proof_path),
        str(saved(directory, "bad-journal.json", moved)), "--owner", "labctl-x05-a1b2c3",
        "--run-hex", "a1b2c3", "--state", str(state_path), ok=False)
    wrong_run = copy.deepcopy(checked)
    wrong_run["owner"] = "labctl-x05-deadbe"
    run("python3", str(tx_tool), "--build-inverse", str(proof_path),
        str(saved(directory, "wrong-run.json", wrong_run)), "--owner", "labctl-x05-a1b2c3",
        "--run-hex", "a1b2c3", "--state", str(state_path), ok=False)
    wrong_fingerprint = copy.deepcopy(checked)
    wrong_fingerprint["a_fingerprint"]["lr_uuid"] = "00000000-0000-4000-8000-000000009999"
    run("python3", str(tx_tool), "--build-inverse", str(proof_path),
        str(saved(directory, "wrong-fingerprint.json", wrong_fingerprint)),
        "--owner", "labctl-x05-a1b2c3", "--run-hex", "a1b2c3",
        "--state", str(state_path), ok=False)
    for name, change in (
        ("foreign-column", lambda s: s["tables"]["Logical_Switch"][0].update(
            {"acls": ["set", [["uuid", "00000000-0000-4000-8000-000000000099"]]]})),
        ("owner-drift", lambda s: s["tables"]["Logical_Switch"][0].update(
            {"external_ids": ["map", [["x05-owner", "labctl-x05-deadbe"]]]})),
        ("parent-drift", lambda s: s["tables"]["Logical_Switch"][0].update(
            {"ports": ["set", []]})),
        ("foreign-ref", lambda s: s["tables"]["Logical_Switch"].append({
            "_uuid": "00000000-0000-4000-8000-000000000099", "name": "foreign",
            "ports": ["set", [["uuid", checked["inserted"]["Logical_Switch_Port:x05-tenant-b-vm"]]]]})),
        ("port-group-ref", lambda s: s["tables"]["Port_Group"].append({
            "_uuid": "00000000-0000-4000-8000-000000000099", "name": "foreign-pg",
            "ports": ["set", [["uuid", checked["inserted"]["Logical_Switch_Port:x05-tenant-b-vm"]]]]})),
    ):
        wrong = copy.deepcopy(state)
        change(wrong)
        run("python3", str(tx_tool), "--build-inverse", str(proof_path), str(journal),
            "--owner", "labctl-x05-a1b2c3", "--run-hex", "a1b2c3",
            "--state", str(saved(directory, name + ".json", wrong)), ok=False)
    cases = []
    cases.append({"result": response, "error": "failed"})
    for change in (lambda r: r.__setitem__(0, {"error": "timed out"}),
                   lambda r: r.__setitem__(0, None),
                   lambda r: r.pop(),
                   lambda r: r.__setitem__(-1, {"count": 0}),
                   lambda r: r.__setitem__(-1, {"count": True}),
                   lambda r: r.__setitem__(len(waits), {"uuid": ["uuid", "invalid"]}),
                   lambda r: r.__setitem__(len(waits) + 1, r[len(waits)])):
        bad = copy.deepcopy(response)
        change(bad)
        cases.append({"result": bad})
    for index, case in enumerate(cases):
        run("python3", str(tx_tool), "--check-result",
            str(saved(directory, f"bad-{index}.json", case)), *check_args, ok=False)

print("X05 NB transaction selftest PASS: forward/inverse shape, guards, result errors/counts/UUIDs")
PY
