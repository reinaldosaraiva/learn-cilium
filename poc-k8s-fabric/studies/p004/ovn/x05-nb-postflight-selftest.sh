#!/usr/bin/env bash
# Local synthetic NB postflight checks. No --live or OVSDB connection.
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
owner = "labctl-x05-a1b2c3"
run_hex = "a1b2c3"


def run(*args, ok=True):
    result = subprocess.run(args, capture_output=True, text=True, timeout=20)
    assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
    return json.loads(result.stdout)


with tempfile.TemporaryDirectory(prefix="x05-nb-postflight-") as temporary:
    directory = pathlib.Path(temporary)

    def save(name, value):
        path = directory / name
        path.write_text(json.dumps(value))
        return path

    proof = run("bash", str(here / "x05-nb-preflight.sh"), "--fixture",
                str(here / "x05-nb-preflight-fixture.json"))
    proof_path = save("proof.json", proof)
    plan = run("bash", str(here / "x05-nb-plan.sh"), "--plan")["objects"]
    transaction = run("python3", str(here / "x05-nb-tx.py"), "--build",
                      str(proof_path), "--owner", owner, "--run-hex", run_hex)
    inserts = [op for op in transaction[1:] if op["op"] == "insert"]
    waits = [op for op in transaction[1:] if op["op"] == "wait"]
    response = [{} for _ in waits] + [
        {"uuid": ["uuid", f"00000000-0000-4000-8000-{index + 100:012x}"]}
        for index in range(1, 35)] + [{"count": 1}]
    journal = run("python3", str(here / "x05-nb-tx.py"), "--check-result",
                  str(save("tx-response.json", {"result": response})),
                  "--preflight", str(proof_path), "--owner", owner,
                  "--run-hex", run_hex)
    journal_path = save("journal.json", journal)
    named = {op["uuid-name"]: journal["inserted"][item["id"]]
             for item, op in zip(plan, inserts)}

    def resolve(value):
        if isinstance(value, list) and len(value) == 2 and value[0] == "named-uuid":
            return ["uuid", named[value[1]]]
        if isinstance(value, list):
            return [resolve(item) for item in value]
        if isinstance(value, dict):
            return {key: resolve(item) for key, item in value.items()}
        return value

    tables = {table: [] for table in ("Logical_Switch", "Logical_Router",
              "Logical_Switch_Port", "Logical_Router_Port", "Gateway_Chassis",
              "Logical_Router_Static_Route", "Network_Function", "Port_Group",
              "Logical_Router_Policy", "NAT")}
    a = proof["a_fingerprint"]
    base = {
        "Logical_Switch": {"_uuid": a["ls_uuid"], "name": "ls-mgc-tenant",
                           "external_ids": ["map", []],
                           "ports": ["set", [["uuid", uid] for uid in a["ls_ports"]]]},
        "Logical_Router": {"_uuid": a["lr_uuid"], "name": "lr-mgc-tenant",
                           "external_ids": ["map", []],
                           "ports": ["set", [["uuid", uid] for uid in a["lr_ports"]]],
                           "static_routes": ["set", []]},
        "Logical_Router_Port": {"_uuid": a["lrp_uuid"], "name": "lrp-mgc-tenant",
                                "external_ids": ["map", []],
                                "gateway_chassis": ["set", []]},
    }
    for table, row in base.items():
        tables[table].append(row)
    clean = {"schema": "p004-x05-nb-full-snapshot-v1", "nb_cfg_before": 43,
             "nb_cfg_after": 43, "tables": tables}
    built = copy.deepcopy(clean)
    built["capture_started_ns"] = journal["checked_at_ns"] + 10
    built["capture_finished_ns"] = journal["checked_at_ns"] + 20
    for item, op in zip(plan, inserts):
        row = {"_uuid": journal["inserted"][item["id"]], **resolve(op["row"])}
        if item["table"] == "Logical_Router_Port":
            row.setdefault("gateway_chassis", ["set", []])
        built["tables"][item["table"]].append(row)
    sentinel = journal["inserted"]["Logical_Switch_Port:x05-tenant-a-vm"]
    built["tables"]["Logical_Switch"][0]["ports"][1].append(["uuid", sentinel])
    checker = here / "x05-nb-postflight.py"

    def check(label, mode, state, ok=True, proof_value=proof, journal_value=journal,
              built_value=None, inverse_value=None):
        command = ["python3", str(checker), "--" + mode,
                   "--preflight", str(save(label + "-proof.json", proof_value)),
                   "--forward", str(save(label + "-journal.json", journal_value)),
                   "--state", str(save(label + "-state.json", state))]
        if mode == "clean":
            command += ["--built-receipt", str(save(label + "-built.json",
                        built_receipt if built_value is None else built_value)),
                        "--inverse", str(save(label + "-inverse.json",
                        inverse_receipt if inverse_value is None else inverse_value))]
        report = run(*command, ok=ok)
        assert report["status"] == ("PASS" if ok else "FAIL"), (label, report)
        if ok:
            assert report["owned_rows"] == (34 if mode == "built" else 0)
        return report

    built_receipt = check("built", "built", built)
    built_path = save("preinverse-state.json", built)
    inverse_tx = run("python3", str(here / "x05-nb-tx.py"), "--build-inverse",
                     str(proof_path), str(journal_path), "--owner", owner,
                     "--run-hex", run_hex, "--state", str(built_path))
    inverse_waits = [op for op in inverse_tx[1:] if op["op"] == "wait"]
    inverse_result = {"result": [{} for _ in inverse_waits] +
                      [{"count": 1} for _ in range(35)]}
    inverse_receipt = run("python3", str(here / "x05-nb-tx.py"),
                          "--check-inverse-result",
                          str(save("inverse-response.json", inverse_result)),
                          "--preflight", str(proof_path), "--forward", str(journal_path),
                          "--state", str(built_path))
    clean["capture_started_ns"] = inverse_receipt["checked_at_ns"] + 10
    clean["capture_finished_ns"] = inverse_receipt["checked_at_ns"] + 20
    check("clean", "clean", clean)
    cases = []
    wrong = copy.deepcopy(built)
    wrong["tables"]["Logical_Router"][1]["options"] = ["map", [["unexpected", "yes"]]]
    cases.append(("planned_column", "built", wrong))
    wrong = copy.deepcopy(built)
    wrong["tables"]["Logical_Switch"][0]["ports"][1].pop()
    cases.append(("a_sentinel_missing", "built", wrong))
    wrong = copy.deepcopy(built)
    wrong["tables"]["Logical_Router"][0]["ports"] = ["set", []]
    cases.append(("a_lr_drift", "built", wrong))
    wrong = copy.deepcopy(built)
    wrong["tables"]["Logical_Switch_Port"][-1]["external_ids"] = ["map", []]
    cases.append(("owner_missing", "built", wrong))
    wrong = copy.deepcopy(built)
    wrong["tables"]["Port_Group"].append({
        "_uuid": "00000000-0000-4000-8000-000000000099", "name": "foreign",
        "ports": ["set", [["uuid", sentinel]]]})
    cases.append(("foreign_reference", "built", wrong))
    wrong = copy.deepcopy(built)
    wrong["tables"]["NAT"].append({"_uuid": "00000000-0000-4000-8000-000000000099",
                                     "gateway_port": ["set", []],
                                     "external_ids": ["map", [["x05-owner", owner]]]})
    cases.append(("extra_owned", "built", wrong))
    wrong = copy.deepcopy(clean)
    wrong["tables"]["Logical_Switch"][0]["ports"][1].append(["uuid", sentinel])
    cases.append(("clean_a_drift", "clean", wrong))
    wrong = copy.deepcopy(clean)
    wrong["tables"]["Port_Group"].append({
        "_uuid": "00000000-0000-4000-8000-000000000099", "name": "foreign",
        "ports": ["set", [["uuid", sentinel]]]})
    cases.append(("clean_reference", "clean", wrong))
    wrong = copy.deepcopy(clean)
    wrong["tables"]["Port_Group"].append({
        "_uuid": "00000000-0000-4000-8000-000000000099", "name": "foreign",
        "ports": ["set", ["garbage"]]})
    cases.append(("clean_malformed_reference", "clean", wrong))
    wrong = copy.deepcopy(clean)
    wrong["capture_started_ns"] = journal["checked_at_ns"] - 10
    wrong["capture_finished_ns"] = journal["checked_at_ns"] - 5
    cases.append(("pre_forward_clean", "clean", wrong))
    wrong = copy.deepcopy(clean)
    wrong["capture_started_ns"] = built_receipt["capture_finished_ns"] + 1
    wrong["capture_finished_ns"] = built_receipt["capture_finished_ns"] + 2
    cases.append(("pre_inverse_clean", "clean", wrong))
    wrong = copy.deepcopy(clean)
    wrong["tables"]["Logical_Switch_Port"].append({
        "_uuid": sentinel, "name": "x05-tenant-a-vm",
        "external_ids": ["map", [["x05-owner", owner]]]})
    cases.append(("clean_owned_residue", "clean", wrong))
    wrong = copy.deepcopy(clean)
    wrong["tables"]["Logical_Switch_Port"].append({
        "_uuid": "00000000-0000-4000-8000-000000000099", "name": "x05-stray",
        "external_ids": ["map", []]})
    cases.append(("clean_name_residue", "clean", wrong))
    wrong = copy.deepcopy(built)
    wrong["nb_cfg_after"] += 1
    cases.append(("drifting_snapshot", "built", wrong))
    wrong = copy.deepcopy(built)
    wrong["tables"]["Logical_Router"].append(copy.deepcopy(wrong["tables"]["Logical_Router"][1]))
    cases.append(("duplicate_uuid", "built", wrong))
    wrong = copy.deepcopy(built)
    wrong["tables"]["Logical_Switch"][1]["external_ids"][1].append(
        ["x05-owner", owner])
    cases.append(("duplicate_owner_key", "built", wrong))
    wrong = copy.deepcopy(built)
    route = next(row for row in wrong["tables"]["Logical_Router_Static_Route"]
                 if row["ip_prefix"] == "192.168.100.0/24")
    duplicate_route = copy.deepcopy(route)
    duplicate_route["_uuid"] = "00000000-0000-4000-8000-000000000099"
    duplicate_route["external_ids"] = ["map", []]
    wrong["tables"]["Logical_Router_Static_Route"].append(duplicate_route)
    parent_uid = journal["inserted"]["Logical_Router:lr-x05-300"]
    parent = next(row for row in wrong["tables"]["Logical_Router"]
                  if row["_uuid"] == parent_uid)
    parent["static_routes"][1].append(["uuid", duplicate_route["_uuid"]])
    cases.append(("duplicate_route_identity", "built", wrong))
    wrong = copy.deepcopy(clean)
    del wrong["tables"]["NAT"]
    cases.append(("missing_table", "clean", wrong))
    wrong = copy.deepcopy(built)
    wrong["nb_cfg_before"] = wrong["nb_cfg_after"] = proof["nb_cfg"] - 1
    cases.append(("stale_snapshot", "built", wrong))
    for label, mode, state in cases:
        check(label, mode, state, ok=False)
    wrong_proof = copy.deepcopy(proof)
    wrong_proof["status"] = "FAIL"
    check("failed_preflight", "built", built, ok=False, proof_value=wrong_proof)
    wrong_journal = copy.deepcopy(journal)
    wrong_journal["status"] = "FAIL"
    check("failed_journal", "built", built, ok=False, journal_value=wrong_journal)
    bad_path = directory / "duplicate-key.json"
    bad_path.write_text('{"status":"PASS","status":"FAIL"}')
    report = run("python3", str(checker), "--clean", "--preflight", str(bad_path),
                 "--forward", str(journal_path), "--state",
                 str(save("valid-clean.json", clean)), "--built-receipt",
                 str(save("valid-built.json", built_receipt)), "--inverse",
                 str(save("valid-inverse.json", inverse_receipt)), ok=False)
    assert report["status"] == "FAIL"

print(f"X05 NB postflight selftest PASS: built/clean and {len(cases) + 3} fail-closed cases")
PY
