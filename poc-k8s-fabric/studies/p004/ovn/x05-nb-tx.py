#!/usr/bin/env python3
"""Generate/check the local X05 OVN NB forward transaction; never contact OVSDB."""

import argparse
import json
import pathlib
import re
import subprocess
import sys
import time


HERE = pathlib.Path(__file__).resolve().parent
UUID = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z")
OWNER = re.compile(r"labctl-x05-[0-9a-f]{6}\Z")
HEX6 = re.compile(r"[0-9a-f]{6}\Z")
NAMED_TABLES = frozenset({"Logical_Switch", "Logical_Router",
                          "Logical_Switch_Port", "Logical_Router_Port",
                          "Gateway_Chassis"})
PLAN_TABLES = NAMED_TABLES | {"Logical_Router_Static_Route"}
REFERRER_COLUMNS = {
    "Logical_Switch": ("ports",),
    "Network_Function": ("outport", "inport"),
    "Port_Group": ("ports",),
    "Logical_Router": ("ports", "static_routes"),
    "Logical_Router_Port": ("gateway_chassis",),
    "Logical_Router_Policy": ("output_port",),
    "NAT": ("gateway_port",),
}
SNAPSHOT_TABLES = PLAN_TABLES | set(REFERRER_COLUMNS)


class TransactionError(ValueError):
    """The local input cannot safely describe the intended transaction."""


def require(ok, message):
    if not ok:
        raise TransactionError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key: " + key)
        result[key] = value
    return result


def read_json(path):
    return json.loads(path.read_text(), object_pairs_hook=unique_object,
                      parse_constant=lambda value: (_ for _ in ()).throw(
                          TransactionError("non-finite JSON number: " + value)))


def plan():
    check = subprocess.run(["bash", str(HERE / "x05-nb-plan.sh"), "--check"],
                           capture_output=True, text=True, timeout=10, check=False)
    require(check.returncode == 0, "X05 NB plan check failed")
    result = subprocess.run(["bash", str(HERE / "x05-nb-plan.sh"), "--plan"],
                            capture_output=True, text=True, timeout=10, check=False)
    require(result.returncode == 0, "X05 NB plan unavailable")
    value = json.loads(result.stdout, object_pairs_hook=unique_object)
    require(value.get("schema") == "p004-x05-nb-plan-v1" and
            len(value.get("objects", [])) == 34, "invalid X05 NB plan")
    return value["objects"]


def ovs_set(values):
    return ["set", values]


def ovs_map(values):
    require(isinstance(values, dict) and all(isinstance(k, str) and
            isinstance(v, str) for k, v in values.items()), "invalid OVSDB map")
    return ["map", [[key, value] for key, value in sorted(values.items())]]


def named(ref):
    return ["named-uuid", ref]


def build(preflight, owner, run_hex, objects):
    require(OWNER.fullmatch(owner) is not None, "invalid owner token")
    require(HEX6.fullmatch(run_hex) is not None, "run hex must be six lowercase hex digits")
    require(owner == "labctl-x05-" + run_hex,
            "owner token and run hex must identify the same X05 run")
    require(isinstance(preflight, dict) and
            preflight.get("schema") == "p004-x05-nb-preflight-v1" and
            preflight.get("status") == "PASS" and
            preflight.get("planned_rows_absent") == 34 and
            preflight.get("owner_residue") == 0,
            "PASS preflight with 34 absent rows required")
    fingerprint = preflight.get("a_fingerprint")
    require(isinstance(fingerprint, dict), "missing A fingerprint")
    for key in ("ls_uuid", "lr_uuid", "lrp_uuid"):
        require(isinstance(fingerprint.get(key), str) and
                UUID.fullmatch(fingerprint[key]) is not None,
                "invalid A fingerprint " + key)
    for key, minimum in (("ls_ports", 2), ("lr_ports", 1)):
        ports = fingerprint.get(key)
        require(isinstance(ports, list) and len(ports) >= minimum and
                all(isinstance(port, str) and UUID.fullmatch(port) is not None
                    for port in ports) and len(set(ports)) == len(ports),
                "invalid complete A " + key + " set")
    require(fingerprint["lrp_uuid"] in fingerprint["lr_ports"],
            "A LRP missing from A LR fingerprint")
    ports = fingerprint["ls_ports"]
    ids = {item["id"]: "x05_%02d" % index for index, item in enumerate(objects)}
    require(len(ids) == 34, "duplicate plan IDs")
    by_name = {item["name"]: item for item in objects}
    require(len(by_name) == 34, "duplicate plan names")
    children = {}
    for item in objects:
        if item["parent"] != "ls-dci-tenant":
            children.setdefault(item["parent"], []).append(item)

    tx = ["OVN_Northbound", {
        "op": "wait", "timeout": 0, "table": "Logical_Switch",
        "where": [["_uuid", "==", ["uuid", fingerprint["ls_uuid"]]],
                  ["name", "==", "ls-dci-tenant"]],
        "columns": ["ports"], "until": "==",
        "rows": [{"ports": ovs_set([["uuid", port] for port in sorted(ports)])}],
    }]
    # Named rows have no parent yet. Waiting on their names makes a concurrent
    # creator fail the transaction rather than being silently adopted.
    for item in objects:
        if item["table"] in NAMED_TABLES:
            tx.append({"op": "wait", "timeout": 0, "table": item["table"],
                       "where": [["name", "==", item["name"]]],
                       "columns": ["_uuid"], "until": "==", "rows": []})

    for item in objects:
        table = item["table"]
        values = dict(item["values"])
        require(values.pop("external_ids", None) == {"x05-owner": "<token>"},
                "invalid planned owner placeholder")
        row = {"external_ids": ovs_map({"x05-owner": owner})}
        if table != "Logical_Router_Static_Route":
            row["name"] = item["name"]
        for key, value in values.items():
            if key == "options" and item["name"] == "lrp-x05-tenant-b":
                require(value.get("dynamic-routing-port-name") ==
                        "x05-b-<six-hex-run-token>", "unexpected B routing port placeholder")
                value = dict(value)
                value["dynamic-routing-port-name"] = "x05-b-" + run_hex
            if key in ("options", "other_config"):
                row[key] = ovs_map(value)
            elif key in ("addresses", "networks"):
                row[key] = ovs_set(value)
            else:
                row[key] = value
        if table in ("Logical_Switch", "Logical_Router"):
            row["ports"] = ovs_set([named(ids[child["id"]])
                                    for child in children.get(item["name"], [])
                                    if child["table"] in ("Logical_Switch_Port", "Logical_Router_Port")])
        if table == "Logical_Router":
            row["static_routes"] = ovs_set([named(ids[child["id"]])
                                            for child in children.get(item["name"], [])
                                            if child["table"] == "Logical_Router_Static_Route"])
        if table == "Logical_Router_Port":
            refs = item.get("references", {}).get("gateway_chassis", [])
            if refs:
                require(all(ref in by_name and by_name[ref]["table"] == "Gateway_Chassis"
                            for ref in refs), "invalid Gateway_Chassis reference")
                row["gateway_chassis"] = ovs_set([named(ids[by_name[ref]["id"]])
                                                  for ref in refs])
        tx.append({"op": "insert", "table": table, "row": row,
                   "uuid-name": ids[item["id"]]})
    a_port = by_name["x05-tenant-a-vm"]
    require(a_port["parent"] == "ls-dci-tenant", "invalid A sentinel parent")
    tx.append({"op": "mutate", "table": "Logical_Switch",
               "where": [["_uuid", "==", ["uuid", fingerprint["ls_uuid"]]],
                         ["name", "==", "ls-dci-tenant"]],
               "mutations": [["ports", "insert", ovs_set([named(ids[a_port["id"]])])]]})
    return tx


def check_result(response, objects, preflight, owner, run_hex):
    build(preflight, owner, run_hex, objects)
    if isinstance(response, dict):
        require(response.get("error") is None, "top-level OVSDB error")
        response = response.get("result")
    require(isinstance(response, list), "missing OVSDB result array")
    waits = 1 + sum(item["table"] in NAMED_TABLES for item in objects)
    require(len(response) == waits + len(objects) + 1, "wrong OVSDB operation count")
    for entry in response:
        require(isinstance(entry, dict), "null or malformed OVSDB result entry")
        require(entry.get("error") is None, "OVSDB operation error")
    require(all(entry == {} for entry in response[:waits]),
            "unexpected wait result")
    uuids = {}
    for item, entry in zip(objects, response[waits:waits + len(objects)]):
        require(isinstance(entry, dict) and set(entry) == {"uuid"} and
                isinstance(entry["uuid"], list) and len(entry["uuid"]) == 2 and
                entry["uuid"][0] == "uuid" and
                isinstance(entry["uuid"][1], str) and
                UUID.fullmatch(entry["uuid"][1]) is not None,
                "missing or invalid inserted UUID: " + item["id"])
        uid = entry["uuid"][1].lower()
        require(uid not in uuids.values(), "duplicate inserted UUID")
        uuids[item["id"]] = uid
    require(set(response[-1]) == {"count"} and
            type(response[-1]["count"]) is int and response[-1]["count"] == 1,
            "A LS attach count must equal one")
    return {"schema": "p004-x05-nb-tx-result-v1", "status": "PASS",
            "owner": owner, "run_hex": run_hex,
            "a_fingerprint": preflight["a_fingerprint"],
            "inserted": uuids, "a_ls_attach_count": 1,
            "checked_at_ns": time.time_ns()}


def captured_uuids(result, objects, preflight, owner, run_hex):
    require(isinstance(result, dict) and
            result.get("schema") == "p004-x05-nb-tx-result-v1" and
            result.get("status") == "PASS" and
            type(result.get("a_ls_attach_count")) is int and
            result["a_ls_attach_count"] == 1,
            "verified forward result required for inverse")
    require(result.get("owner") == owner and result.get("run_hex") == run_hex
            and result.get("a_fingerprint") == preflight["a_fingerprint"],
            "forward UUID journal belongs to another run or A fingerprint")
    inserted = result.get("inserted")
    require(isinstance(inserted, dict) and
            set(inserted) == {item["id"] for item in objects},
            "incomplete inserted UUID journal")
    require(all(isinstance(value, str) and UUID.fullmatch(value) is not None
                for value in inserted.values()) and
            len({value.lower() for value in inserted.values()}) == len(objects),
            "invalid or duplicate inserted UUID")
    return {key: value.lower() for key, value in inserted.items()}


def resolve_named(value, names):
    if isinstance(value, list) and len(value) == 2 and value[0] == "named-uuid":
        require(value[1] in names, "unknown named UUID in forward row")
        return ["uuid", names[value[1]]]
    if isinstance(value, list):
        return [resolve_named(child, names) for child in value]
    if isinstance(value, dict):
        return {key: resolve_named(child, names) for key, child in value.items()}
    return value


def canonical(value):
    if isinstance(value, list) and len(value) == 2 and value[0] == "map":
        pairs = value[1]
        require(isinstance(pairs, list) and all(isinstance(pair, list) and
                len(pair) == 2 for pair in pairs), "malformed OVSDB map")
        return ["map", sorted([[canonical(key), canonical(item)]
                               for key, item in pairs], key=lambda pair: json.dumps(pair))]
    if isinstance(value, list) and len(value) == 2 and value[0] == "set":
        require(isinstance(value[1], list), "malformed OVSDB set")
        return ["set", sorted([canonical(item) for item in value[1]],
                              key=lambda item: json.dumps(item))]
    if isinstance(value, list) and len(value) == 2 and value[0] == "uuid":
        require(isinstance(value[1], str) and UUID.fullmatch(value[1]) is not None,
                "malformed OVSDB UUID atom")
        return ["uuid", value[1].lower()]
    if isinstance(value, list):
        return [canonical(item) for item in value]
    if isinstance(value, dict):
        return {key: canonical(item) for key, item in value.items()}
    return value


def empty_default(value):
    return value in (None, False, 0, "", ["set", []], ["map", []])


def equivalent(observed, planned):
    if isinstance(planned, list) and len(planned) == 2 and planned[0] == "set":
        if not (isinstance(observed, list) and len(observed) == 2 and
                observed[0] == "set"):
            observed = ["set", [observed]]
    return canonical(observed) == canonical(planned)


def referenced_uuids(value):
    if isinstance(value, list) and len(value) == 2 and value[0] == "uuid":
        return {value[1].lower()}
    if isinstance(value, (list, tuple)):
        return set().union(*(referenced_uuids(item) for item in value))
    if isinstance(value, dict):
        return set().union(*(referenced_uuids(item) for item in value.values()))
    return set()


def complete_rows(snapshot, objects, inserted, inserts, names, fingerprint):
    require(isinstance(snapshot, dict) and
            snapshot.get("schema") == "p004-x05-nb-full-snapshot-v1" and
            type(snapshot.get("nb_cfg_before")) is int and
            snapshot["nb_cfg_before"] == snapshot.get("nb_cfg_after"),
            "invalid or drifting full NB snapshot")
    tables = snapshot.get("tables")
    require(isinstance(tables, dict) and set(tables) == SNAPSHOT_TABLES,
            "incomplete full NB table snapshot")
    rows_by_uuid = {}
    owned = set(inserted.values())
    for table, rows in tables.items():
        require(isinstance(rows, list), "malformed full NB table: " + table)
        for row in rows:
            require(isinstance(row, dict) and isinstance(row.get("_uuid"), str)
                    and UUID.fullmatch(row["_uuid"]) is not None,
                    "malformed full NB row UUID")
            uid = row["_uuid"].lower()
            require(uid not in rows_by_uuid, "duplicate full NB UUID")
            require(set(REFERRER_COLUMNS.get(table, ())) <= set(row),
                    "missing reference columns in full NB snapshot")
            rows_by_uuid[uid] = (table, row)
            for column, value in row.items():
                if column in ("_uuid", "_version"):
                    continue
                foreign_refs = referenced_uuids(value) & owned
                if foreign_refs and uid not in owned:
                    allowed = (uid == fingerprint["ls_uuid"] and
                               table == "Logical_Switch" and column == "ports" and
                               foreign_refs == {inserted["Logical_Switch_Port:x05-tenant-a-vm"]})
                    require(allowed, "foreign row references X05 owned UUID")
    guarded = {}
    for item, operation in zip(objects, inserts):
        uid = inserted[item["id"]]
        require(uid in rows_by_uuid, "missing owned row in full NB snapshot")
        table, observed = rows_by_uuid[uid]
        require(table == item["table"], "owned UUID moved to wrong NB table")
        planned = resolve_named(operation["row"], names)
        for column, value in planned.items():
            require(column in observed and equivalent(observed[column], value),
                    "owned NB planned column drift: " + item["id"] + ":" + column)
        for column, value in observed.items():
            if column not in planned and column not in ("_uuid", "_version",
                                                        "status", "up", "uptime",
                                                        "nat_addresses", "tag"):
                require(empty_default(value),
                        "unexpected populated NB column: " + item["id"] + ":" + column)
        guarded[item["id"]] = {key: value for key, value in observed.items()
                               if key not in ("_uuid", "_version")}
    return guarded


def referrer_waits(snapshot):
    waits = []
    for table, refs in REFERRER_COLUMNS.items():
        columns = ["_uuid", *refs]
        rows = []
        for observed in snapshot["tables"][table]:
            row = {"_uuid": ["uuid", observed["_uuid"].lower()]}
            row.update({column: observed[column] for column in refs})
            rows.append(row)
        waits.append({"op": "wait", "timeout": 0, "table": table,
                      "where": [], "columns": columns, "until": "==",
                      "rows": rows})
    return waits


def build_inverse(preflight, result, snapshot, owner, run_hex, objects):
    inserted = captured_uuids(result, objects, preflight, owner, run_hex)
    return build_inverse_with_uuids(
        preflight, inserted, snapshot, owner, run_hex, objects
    )


def build_inverse_with_uuids(preflight, inserted, snapshot, owner, run_hex, objects):
    """Build an inverse from a verified UUID map without a tx-result receipt.

    The forward-recovery proof owns the UUID map when the OVSDB commit result
    was ambiguous.  This bridge intentionally accepts that map directly so a
    recovery proof is never recast as ``p004-x05-nb-tx-result-v1``.  Callers
    must revalidate the proof and current built snapshot before entering here.
    """

    forward = build(preflight, owner, run_hex, objects)
    require(isinstance(inserted, dict) and
            set(inserted) == {item["id"] for item in objects} and
            all(isinstance(value, str) and UUID.fullmatch(value) is not None
                for value in inserted.values()) and
            len({value.lower() for value in inserted.values()}) == len(objects),
            "complete bijective inserted UUID map required")
    inserted = {key: value.lower() for key, value in inserted.items()}
    inserts = [operation for operation in forward[1:] if operation["op"] == "insert"]
    require(len(inserts) == len(objects), "forward insert count changed")
    names = {operation["uuid-name"]: inserted[item["id"]]
             for item, operation in zip(objects, inserts)}
    fingerprint = preflight["a_fingerprint"]
    guarded = complete_rows(snapshot, objects, inserted, inserts, names, fingerprint)
    a_port = inserted["Logical_Switch_Port:x05-tenant-a-vm"]
    original = fingerprint["ls_ports"]
    require(a_port not in original, "A sentinel UUID already in original A LS")
    inverse = ["OVN_Northbound", {
        "op": "wait", "timeout": 0, "table": "Logical_Switch",
        "where": [["_uuid", "==", ["uuid", fingerprint["ls_uuid"]]],
                  ["name", "==", "ls-dci-tenant"]],
        "columns": ["ports"], "until": "==",
        "rows": [{"ports": ovs_set([["uuid", port]
                              for port in sorted([*original, a_port])])}],
    }]
    inverse.append({
        "op": "wait", "timeout": 0, "table": "Logical_Router",
        "where": [["_uuid", "==", ["uuid", fingerprint["lr_uuid"]]],
                  ["name", "==", "lr-dci-tenant"]],
        "columns": ["ports"], "until": "==",
        "rows": [{"ports": ovs_set([["uuid", port]
                              for port in sorted(fingerprint["lr_ports"])])}],
    })
    inverse.append({
        "op": "wait", "timeout": 0, "table": "Logical_Router_Port",
        "where": [["_uuid", "==", ["uuid", fingerprint["lrp_uuid"]]],
                  ["name", "==", "lrp-dci-tenant"]],
        "columns": ["name"], "until": "==",
        "rows": [{"name": "lrp-dci-tenant"}],
    })
    for item, operation in zip(objects, inserts):
        row = guarded[item["id"]]
        require(row["external_ids"] == ovs_map({"x05-owner": owner}),
                "inverse row lost X05 owner")
        inverse.append({
            "op": "wait", "timeout": 0, "table": item["table"],
            "where": [["_uuid", "==", ["uuid", inserted[item["id"]]]]],
            "columns": sorted(row), "until": "==", "rows": [row],
        })
    inverse.extend(referrer_waits(snapshot))
    inverse.append({
        "op": "mutate", "table": "Logical_Switch",
        "where": [["_uuid", "==", ["uuid", fingerprint["ls_uuid"]]],
                  ["name", "==", "ls-dci-tenant"]],
        "mutations": [["ports", "delete", ovs_set([["uuid", a_port]])]],
    })
    for item in reversed(objects):
        inverse.append({"op": "delete", "table": item["table"],
                        "where": [["_uuid", "==", ["uuid", inserted[item["id"]]]]]})
    return inverse


def check_inverse_result(response, objects, preflight, forward, state):
    require(isinstance(forward, dict), "forward journal required")
    owner, run_hex = forward.get("owner"), forward.get("run_hex")
    require(isinstance(owner, str) and isinstance(run_hex, str),
            "forward owner and run required")
    build_inverse(preflight, forward, state, owner, run_hex, objects)
    inserted = captured_uuids(forward, objects, preflight, owner, run_hex)
    if isinstance(response, dict):
        require(response.get("error") is None, "top-level OVSDB error")
        response = response.get("result")
    waits = len(objects) + 3 + len(REFERRER_COLUMNS)
    require(isinstance(response, list) and len(response) == waits + len(objects) + 1,
            "wrong inverse operation count")
    for entry in response:
        require(isinstance(entry, dict) and entry.get("error") is None,
                "null or failed inverse operation")
    require(all(entry == {} for entry in response[:waits]),
            "unexpected inverse wait result")
    require(all(set(entry) == {"count"} and type(entry["count"]) is int
                and entry["count"] == 1 for entry in response[waits:]),
            "inverse mutation or delete count must equal one")
    return {"schema": "p004-x05-nb-inverse-result-v1", "status": "PASS",
            "owner": owner, "run_hex": run_hex,
            "a_fingerprint": preflight["a_fingerprint"],
            "inserted": inserted, "preinverse_nb_cfg": state["nb_cfg_after"],
            "checked_at_ns": time.time_ns(),
            "a_ls_detach_count": 1, "deleted_owned_rows": len(objects)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--build", type=pathlib.Path, metavar="PREFLIGHT.json")
    group.add_argument("--check-result", type=pathlib.Path, metavar="RESULT.json")
    group.add_argument("--build-inverse", nargs=2, type=pathlib.Path,
                       metavar=("PREFLIGHT.json", "FORWARD.json"))
    group.add_argument("--check-inverse-result", type=pathlib.Path,
                       metavar="RESULT.json")
    parser.add_argument("--owner", help="X05 row owner token for --build")
    parser.add_argument("--run-hex", help="six lowercase hex digits for B port name")
    parser.add_argument("--preflight", type=pathlib.Path,
                        help="validated A preflight for --check-result")
    parser.add_argument("--state", type=pathlib.Path,
                        help="complete NB snapshot required for --build-inverse")
    parser.add_argument("--forward", type=pathlib.Path,
                        help="checked forward journal for --check-inverse-result")
    args = parser.parse_args()
    objects = plan()
    if args.build or args.build_inverse:
        require(args.preflight is None, "build modes take positional preflight")
        require(args.forward is None, "build modes take positional forward journal")
        require(args.owner is not None and args.run_hex is not None,
                "build requires --owner and --run-hex")
        if args.build:
            require(args.state is None, "forward build takes no full snapshot")
            result = build(read_json(args.build), args.owner, args.run_hex, objects)
        else:
            require(args.state is not None, "inverse needs complete NB snapshot")
            result = build_inverse(read_json(args.build_inverse[0]),
                                   read_json(args.build_inverse[1]),
                                   read_json(args.state), args.owner, args.run_hex, objects)
    else:
        if args.check_result:
            require(args.state is None, "forward result check takes no full snapshot")
            require(args.preflight is not None and args.owner is not None
                    and args.run_hex is not None and args.forward is None,
                    "forward result check needs preflight, owner and run hex")
            result = check_result(read_json(args.check_result), objects,
                                  read_json(args.preflight), args.owner, args.run_hex)
        else:
            require(args.preflight is not None and args.forward is not None
                    and args.state is not None and args.owner is None
                    and args.run_hex is None,
                    "inverse result check needs preflight, forward and preinverse state")
            result = check_inverse_result(read_json(args.check_inverse_result), objects,
                                          read_json(args.preflight), read_json(args.forward),
                                          read_json(args.state))
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except (TransactionError, OSError, ValueError, subprocess.TimeoutExpired) as exc:
        print("X05 NB transaction FAIL: " + str(exc), file=sys.stderr)
        sys.exit(1)
