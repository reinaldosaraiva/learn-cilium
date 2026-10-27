#!/usr/bin/env python3
"""Verify an X05 NB snapshot locally after forward or inverse transaction."""

import argparse
import importlib.util
import json
import pathlib
import subprocess
import sys


HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("x05_nb_tx", HERE / "x05-nb-tx.py")
TX = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TX)


class PostflightError(ValueError):
    """The snapshot cannot prove the requested X05 state."""


def require(ok, message):
    if not ok:
        raise PostflightError(message)


def read_json(path):
    return TX.read_json(path)


def uuid(value, context):
    require(isinstance(value, str) and TX.UUID.fullmatch(value) is not None,
            "invalid UUID: " + context)
    return value.lower()


def uuid_set(value, context):
    if isinstance(value, list) and len(value) == 2 and value[0] == "set":
        atoms = value[1]
    else:
        atoms = [value]
    require(isinstance(atoms, list), "malformed UUID set: " + context)
    result = []
    for atom in atoms:
        require(isinstance(atom, list) and len(atom) == 2 and atom[0] == "uuid",
                "malformed UUID atom: " + context)
        result.append(uuid(atom[1], context))
    require(len(result) == len(set(result)), "duplicate UUID reference: " + context)
    return set(result)


def ovs_map(value, context):
    require(isinstance(value, list) and len(value) == 2 and value[0] == "map"
            and isinstance(value[1], list), "malformed map: " + context)
    result = {}
    for pair in value[1]:
        require(isinstance(pair, list) and len(pair) == 2 and
                all(isinstance(item, str) for item in pair),
                "malformed map pair: " + context)
        require(pair[0] not in result, "duplicate map key: " + context)
        result[pair[0]] = pair[1]
    return result


def validate_ovs(value, context):
    if isinstance(value, dict):
        for key, item in value.items():
            validate_ovs(item, context + ":" + key)
    elif isinstance(value, list):
        if len(value) == 2 and value[0] == "uuid":
            uuid(value[1], context)
        elif len(value) == 2 and value[0] == "set":
            require(isinstance(value[1], list), "malformed OVSDB set: " + context)
            values = [json.dumps(item, sort_keys=True) for item in value[1]]
            require(len(values) == len(set(values)), "duplicate OVSDB set atom: " + context)
            for item in value[1]:
                validate_ovs(item, context)
        elif len(value) == 2 and value[0] == "map":
            require(isinstance(value[1], list), "malformed OVSDB map: " + context)
            keys = []
            for pair in value[1]:
                require(isinstance(pair, list) and len(pair) == 2,
                        "malformed OVSDB map pair: " + context)
                keys.append(json.dumps(pair[0], sort_keys=True))
                validate_ovs(pair[0], context)
                validate_ovs(pair[1], context)
            require(len(keys) == len(set(keys)), "duplicate OVSDB map key: " + context)
        else:
            for item in value:
                validate_ovs(item, context)


def validated_inputs(preflight, forward, objects):
    require(isinstance(preflight, dict) and
            preflight.get("schema") == "p004-x05-nb-preflight-v1" and
            preflight.get("status") == "PASS" and
            type(preflight.get("planned_rows_absent")) is int and
            preflight["planned_rows_absent"] == 34 and
            type(preflight.get("owner_residue")) is int and
            preflight["owner_residue"] == 0 and
            type(preflight.get("nb_cfg")) is int and preflight["nb_cfg"] >= 0,
            "PASS preflight with 34 absent rows required")
    require(isinstance(forward, dict), "verified forward journal required")
    owner, run_hex = forward.get("owner"), forward.get("run_hex")
    require(isinstance(owner, str) and TX.OWNER.fullmatch(owner) is not None and
            isinstance(run_hex, str) and owner == "labctl-x05-" + run_hex,
            "invalid forward owner/run identity")
    # The transaction helper validates the proof, journal, and all 34 UUIDs.
    TX.build(preflight, owner, run_hex, objects)
    inserted = TX.captured_uuids(forward, objects, preflight, owner, run_hex)
    fingerprint = preflight["a_fingerprint"]
    for key in ("ls_uuid", "lr_uuid", "lrp_uuid"):
        uuid(fingerprint[key], "A " + key)
    for key in ("ls_ports", "lr_ports"):
        ports = fingerprint[key]
        require(isinstance(ports, list) and len(ports) == len(set(ports)) and
                all(isinstance(port, str) and TX.UUID.fullmatch(port)
                    for port in ports), "malformed A " + key)
    require(fingerprint["lrp_uuid"] in fingerprint["lr_ports"],
            "A LRP absent from original router ports")
    return owner, inserted, fingerprint


def validate_snapshot(snapshot, objects, inserted, owner):
    require(isinstance(snapshot, dict) and
            snapshot.get("schema") == "p004-x05-nb-full-snapshot-v1" and
            type(snapshot.get("nb_cfg_before")) is int and
            snapshot["nb_cfg_before"] >= 0 and
            snapshot["nb_cfg_before"] == snapshot.get("nb_cfg_after"),
            "invalid or drifting full NB snapshot")
    tables = snapshot.get("tables")
    require(isinstance(tables, dict) and set(tables) == TX.SNAPSHOT_TABLES,
            "incomplete ten-table NB snapshot")
    all_rows = {}
    owner_rows = set()
    planned_names = {(item["table"], item["name"]) for item in objects
                     if item["table"] != "Logical_Router_Static_Route"}
    names = set()
    for table, rows in tables.items():
        require(isinstance(rows, list), "malformed rows: " + table)
        for row in rows:
            require(isinstance(row, dict), "malformed row: " + table)
            uid = uuid(row.get("_uuid"), table)
            require(uid not in all_rows, "duplicate NB UUID")
            all_rows[uid] = (table, row)
            for column, value in row.items():
                if column != "_uuid":
                    validate_ovs(value, table + ":" + column)
            require(set(TX.REFERRER_COLUMNS.get(table, ())) <= set(row),
                    "missing reference columns: " + table)
            for column in TX.REFERRER_COLUMNS.get(table, ()):
                uuid_set(row[column], table + ":" + column)
            if table in TX.NAMED_TABLES:
                name = row.get("name")
                require(isinstance(name, str) and bool(name),
                        "malformed NB name: " + table)
                require((table, name) not in names, "duplicate NB name: " + name)
                names.add((table, name))
                if name.startswith("x05-") or "-x05-" in name or \
                        (table, name) in planned_names:
                    require(uid in inserted.values(), "unowned X05 name: " + name)
            if "external_ids" in row:
                ids = ovs_map(row["external_ids"], table + ":external_ids")
                if "x05-owner" in ids:
                    require(ids["x05-owner"] == owner and uid in inserted.values(),
                            "foreign X05 owner residue")
                    owner_rows.add(uid)
            if table in TX.PLAN_TABLES:
                require("external_ids" in row,
                        "missing external_ids in planned table: " + table)
    return all_rows, owner_rows


def check_route_identity(all_rows, objects, inserted, built):
    route_parent = {}
    for uid, (table, row) in all_rows.items():
        if table != "Logical_Router":
            continue
        for route_uid in uuid_set(row["static_routes"], "LR static_routes"):
            require(route_uid in all_rows and
                    all_rows[route_uid][0] == "Logical_Router_Static_Route",
                    "LR references missing route")
            require(route_uid not in route_parent,
                    "static route has multiple parents")
            route_parent[route_uid] = uid
    identities = set()
    for uid, parent in route_parent.items():
        row = all_rows[uid][1]
        identity = (parent, row.get("ip_prefix"), row.get("nexthop"))
        require(all(isinstance(value, str) for value in identity[1:]),
                "malformed static route identity")
        require(identity not in identities, "duplicate static route identity")
        identities.add(identity)
    if built:
        for item in objects:
            if item["table"] == "Logical_Router_Static_Route":
                uid = inserted[item["id"]]
                parent = inserted["Logical_Router:" + item["parent"]]
                require(route_parent.get(uid) == parent,
                        "planned static route parent drift: " + item["id"])


def check_a(all_rows, fingerprint, sentinel, built):
    for key, table, name in (("ls_uuid", "Logical_Switch", "ls-dci-tenant"),
                             ("lr_uuid", "Logical_Router", "lr-dci-tenant"),
                             ("lrp_uuid", "Logical_Router_Port", "lrp-dci-tenant")):
        uid = uuid(fingerprint[key], "A " + key)
        require(uid in all_rows and all_rows[uid][0] == table and
                all_rows[uid][1].get("name") == name,
                "A identity drift: " + name)
        require("x05-owner" not in ovs_map(all_rows[uid][1]["external_ids"], name),
                "A owner drift: " + name)
    ls = all_rows[fingerprint["ls_uuid"]][1]
    lr = all_rows[fingerprint["lr_uuid"]][1]
    expected_ls = set(fingerprint["ls_ports"])
    if built:
        require(sentinel not in expected_ls, "A sentinel in original LS set")
        expected_ls.add(sentinel)
    require(uuid_set(ls.get("ports"), "A LS ports") == expected_ls,
            "A LS ports drift")
    require(uuid_set(lr.get("ports"), "A LR ports") ==
            set(fingerprint["lr_ports"]), "A LR ports drift")


def verify(mode, preflight, forward, snapshot, built_receipt=None, inverse=None):
    objects = TX.plan()
    owner, inserted, fingerprint = validated_inputs(preflight, forward, objects)
    all_rows, owner_rows = validate_snapshot(snapshot, objects, inserted, owner)
    require(snapshot["nb_cfg_before"] >= preflight["nb_cfg"],
            "NB snapshot predates PASS preflight")
    owned = set(inserted.values())
    sentinel = inserted["Logical_Switch_Port:x05-tenant-a-vm"]
    check_a(all_rows, fingerprint, sentinel, mode == "built")
    check_route_identity(all_rows, objects, inserted, mode == "built")
    if mode == "built":
        require(built_receipt is None and inverse is None,
                "built mode takes no rollback receipts")
        require(type(forward.get("checked_at_ns")) is int and
                type(snapshot.get("capture_started_ns")) is int and
                type(snapshot.get("capture_finished_ns")) is int and
                forward["checked_at_ns"] < snapshot["capture_started_ns"] <=
                snapshot["capture_finished_ns"],
                "built snapshot was not collected after forward result check")
        require(owner_rows == owned, "owned row count/UUID/owner mismatch")
        transaction = TX.build(preflight, owner, forward["run_hex"], objects)
        inserts = [op for op in transaction[1:] if op["op"] == "insert"]
        names = {op["uuid-name"]: inserted[item["id"]]
                 for item, op in zip(objects, inserts)}
        TX.complete_rows(snapshot, objects, inserted, inserts, names, fingerprint)
    else:
        require(isinstance(built_receipt, dict) and isinstance(inverse, dict),
                "clean mode requires built and checked inverse receipts")
        require(built_receipt.get("schema") == "p004-x05-nb-postflight-v1" and
                built_receipt.get("status") == "PASS" and
                built_receipt.get("mode") == "built" and
                built_receipt.get("owner") == owner and
                built_receipt.get("run_hex") == forward["run_hex"] and
                built_receipt.get("a_fingerprint") == fingerprint and
                built_receipt.get("inserted") == inserted,
                "built receipt does not match this run")
        require(inverse.get("schema") == "p004-x05-nb-inverse-result-v1" and
                inverse.get("status") == "PASS" and
                inverse.get("owner") == owner and
                inverse.get("run_hex") == forward["run_hex"] and
                inverse.get("a_fingerprint") == fingerprint and
                inverse.get("inserted") == inserted and
                type(inverse.get("a_ls_detach_count")) is int and
                inverse["a_ls_detach_count"] == 1 and
                type(inverse.get("deleted_owned_rows")) is int and
                inverse["deleted_owned_rows"] == 34,
                "checked inverse receipt does not match this run")
        require(type(built_receipt.get("capture_finished_ns")) is int and
                type(inverse.get("checked_at_ns")) is int and
                type(snapshot.get("capture_started_ns")) is int and
                type(snapshot.get("capture_finished_ns")) is int and
                built_receipt["capture_finished_ns"] < inverse["checked_at_ns"] <
                snapshot["capture_started_ns"] <= snapshot["capture_finished_ns"],
                "clean snapshot was not collected after checked inverse")
        require(type(inverse.get("preinverse_nb_cfg")) is int and
                snapshot["nb_cfg_before"] >= inverse["preinverse_nb_cfg"],
                "clean snapshot predates inverse NB state")
        require(not owner_rows and not (owned & set(all_rows)),
                "X05 owner or UUID residue after inverse")
        for table, rows in snapshot["tables"].items():
            for row in rows:
                for column, value in row.items():
                    if column not in ("_uuid", "_version"):
                        require(not (TX.referenced_uuids(value) & owned),
                                "reference to deleted X05 UUID: " + table + ":" + column)
    return {"schema": "p004-x05-nb-postflight-v1", "status": "PASS",
            "mode": mode, "owner": owner, "run_hex": forward["run_hex"],
            "a_fingerprint": fingerprint, "inserted": inserted,
            "capture_finished_ns": snapshot.get("capture_finished_ns"),
            "nb_cfg": snapshot["nb_cfg_after"],
            "owned_rows": 34 if mode == "built" else 0,
            "a_port_state": "original-plus-sentinel" if mode == "built" else "original"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--built", action="store_true")
    modes.add_argument("--clean", action="store_true")
    for name in ("preflight", "forward", "state"):
        parser.add_argument("--" + name, type=pathlib.Path, required=True)
    parser.add_argument("--built-receipt", type=pathlib.Path)
    parser.add_argument("--inverse", type=pathlib.Path)
    args = parser.parse_args()
    mode = "built" if args.built else "clean"
    try:
        report = verify(mode, read_json(args.preflight), read_json(args.forward),
                        read_json(args.state),
                        read_json(args.built_receipt) if args.built_receipt else None,
                        read_json(args.inverse) if args.inverse else None)
    except (PostflightError, TX.TransactionError, OSError, ValueError,
            KeyError, TypeError, subprocess.TimeoutExpired) as exc:
        report = {"schema": "p004-x05-nb-postflight-v1", "status": "FAIL",
                  "mode": mode, "reason": str(exc)}
    print(json.dumps(report, sort_keys=True, separators=(",", ":")))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
