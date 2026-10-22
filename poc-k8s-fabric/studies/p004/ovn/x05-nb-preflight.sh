#!/usr/bin/env bash
# Read-only X05 NB preflight. Usage: --fixture FILE | --live.
# --fixture reads normalized JSON. --live only runs bounded ovn-nbctl JSON
# list calls through docker exec ovn-central-az1 (12 seconds per call).
# Neither mode has an OVSDB write operation; --live requires M03 A to exist.
set -euo pipefail
exec python3 - "${BASH_SOURCE[0]}" "$@" <<'PY'
import json
import pathlib
import re
import subprocess
import sys

TABLES = {
    "Logical_Switch": ("_uuid", "name", "external_ids", "ports"),
    "Logical_Router": ("_uuid", "name", "external_ids", "ports", "static_routes"),
    "Logical_Switch_Port": ("_uuid", "name", "external_ids", "type", "options"),
    "Logical_Router_Port": ("_uuid", "name", "external_ids"),
    "Gateway_Chassis": ("_uuid", "name", "external_ids"),
    "Logical_Router_Static_Route":
        ("_uuid", "ip_prefix", "nexthop", "external_ids"),
}
UUID = re.compile(r"^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$")


class PreflightError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise PreflightError(message)


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, "duplicate JSON key: " + key)
        value[key] = item
    return value


def load_json(data):
    try:
        return json.loads(data, object_pairs_hook=unique_object,
                          parse_constant=lambda value: (_ for _ in ()).throw(
                              PreflightError("non-finite JSON number: " + value)))
    except (ValueError, TypeError) as exc:
        raise PreflightError("malformed JSON: " + str(exc)) from exc


def uuid(value, context):
    require(isinstance(value, str) and UUID.fullmatch(value) is not None,
            "invalid UUID in " + context)
    return value.lower()


def ovs_atom(value):
    if isinstance(value, list) and len(value) == 2 and value[0] == "uuid":
        return uuid(value[1], "OVSDB atom")
    return value


def ovs_set(value):
    if isinstance(value, list) and len(value) == 2 and value[0] == "set":
        require(isinstance(value[1], list), "malformed OVSDB set")
        return [ovs_atom(item) for item in value[1]]
    return [ovs_atom(value)]


def ovs_map(value):
    require(isinstance(value, list) and len(value) == 2
            and value[0] == "map" and isinstance(value[1], list),
            "malformed OVSDB map")
    result = {}
    for pair in value[1]:
        require(isinstance(pair, list) and len(pair) == 2
                and isinstance(pair[0], str) and isinstance(pair[1], str),
                "malformed OVSDB map entry")
        require(pair[0] not in result, "duplicate OVSDB map key")
        result[pair[0]] = pair[1]
    return result


def decode_table(raw, columns):
    require(isinstance(raw, dict) and isinstance(raw.get("headings"), list)
            and isinstance(raw.get("data"), list), "unexpected ovn-nbctl JSON shape")
    headings = raw["headings"]
    require(len(headings) == len(columns)
            and all(isinstance(heading, str) for heading in headings)
            and set(headings) == set(columns), "unexpected ovn-nbctl headings")
    rows = []
    for cells in raw["data"]:
        require(isinstance(cells, list) and len(cells) == len(columns),
                "malformed ovn-nbctl row")
        row = dict(zip(headings, cells))
        if "_uuid" in row:
            row["_uuid"] = ovs_atom(row["_uuid"])
        if "external_ids" in row:
            row["external_ids"] = ovs_map(row["external_ids"])
        if "ports" in row:
            row["ports"] = ovs_set(row["ports"])
        if "static_routes" in row:
            row["static_routes"] = ovs_set(row["static_routes"])
        if "options" in row:
            row["options"] = ovs_map(row["options"])
        rows.append(row)
    return rows


def nbctl(columns, table):
    command = ["docker", "exec", "ovn-central-az1", "ovn-nbctl",
               "--timeout=5", "--format=json", "--columns=" + ",".join(columns),
               "list", table]
    try:
        result = subprocess.run(command, capture_output=True, text=True,
                                timeout=12, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise PreflightError("bounded NB read failed: " + type(exc).__name__) from exc
    require(result.returncode == 0, "NB read failed for " + table)
    return decode_table(load_json(result.stdout), columns)


def live_snapshot():
    before = nbctl(("nb_cfg",), "NB_Global")
    require(len(before) == 1, "expected one NB_Global before inventory")
    tables = {table: nbctl(columns, table) for table, columns in TABLES.items()}
    after = nbctl(("nb_cfg",), "NB_Global")
    require(len(after) == 1, "expected one NB_Global after inventory")
    return {"schema": "p004-x05-nb-snapshot-v1",
            "nb_cfg_before": before[0]["nb_cfg"],
            "nb_cfg_after": after[0]["nb_cfg"], "tables": tables}


def plan():
    script = pathlib.Path(sys.argv[1]).resolve().parent / "x05-nb-plan.sh"
    try:
        result = subprocess.run(["bash", str(script), "--plan"],
                                capture_output=True, text=True, timeout=10,
                                check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise PreflightError("local NB plan unavailable") from exc
    require(result.returncode == 0, "local NB plan failed")
    value = load_json(result.stdout)
    require(isinstance(value, dict) and value.get("schema") == "p004-x05-nb-plan-v1"
            and isinstance(value.get("objects"), list)
            and len(value["objects"]) == 34, "invalid local NB plan")
    return value["objects"]


def validate(snapshot, objects):
    require(isinstance(snapshot, dict) and snapshot.get("schema") ==
            "p004-x05-nb-snapshot-v1", "invalid snapshot schema")
    before, after = snapshot.get("nb_cfg_before"), snapshot.get("nb_cfg_after")
    require(type(before) is int and type(after) is int and before >= 0,
            "invalid nb_cfg")
    require(before == after, "nb_cfg changed during inventory")
    tables = snapshot.get("tables")
    require(isinstance(tables, dict) and set(tables) == set(TABLES),
            "incomplete NB table inventory")
    names = {table: set() for table in TABLES}
    planned_names = {table: {item["name"] for item in objects
                             if item["table"] == table}
                     for table in TABLES}
    route_rows = {}
    route_keys = set()
    all_uuids = set()
    by_name = {table: {} for table in TABLES}
    for table, rows in tables.items():
        require(isinstance(rows, list), "invalid rows for " + table)
        for row in rows:
            require(isinstance(row, dict), "invalid row for " + table)
            row_uuid = uuid(row.get("_uuid"), table)
            require(row_uuid not in all_uuids, "duplicate NB UUID")
            all_uuids.add(row_uuid)
            external_ids = row.get("external_ids")
            require(isinstance(external_ids, dict) and all(
                isinstance(k, str) and isinstance(v, str)
                for k, v in external_ids.items()), "malformed external_ids in " + table)
            require("x05-owner" not in external_ids,
                    "x05-owner residue in " + table + ":" + row_uuid)
            if table == "Logical_Router_Static_Route":
                prefix, hop = row.get("ip_prefix"), row.get("nexthop")
                require(isinstance(prefix, str) and isinstance(hop, str),
                        "malformed static route")
                route_rows[row_uuid] = (prefix, hop)
            else:
                name = row.get("name")
                require(isinstance(name, str) and bool(name),
                        "malformed name in " + table)
                require(name not in names[table], "duplicate name in " + table + ":" + name)
                require(not ((name.startswith("x05-") or "-x05-" in name)
                             and name not in planned_names[table]),
                        "unexpected X05 name residue in " + table + ":" + name)
                names[table].add(name)
                by_name[table][name] = row
                if table == "Logical_Switch_Port":
                    require(isinstance(row.get("type"), str)
                            and isinstance(row.get("options"), dict),
                            "malformed LSP type/options")
            if table in ("Logical_Switch", "Logical_Router"):
                ports = row.get("ports")
                require(isinstance(ports, list), "malformed ports in " + table)
                normalized = [uuid(port, table + " ports") for port in ports]
                require(len(normalized) == len(set(normalized)),
                        "duplicate port reference in " + table)
                row["ports"] = normalized
            if table == "Logical_Router":
                refs = row.get("static_routes")
                require(isinstance(refs, list), "malformed static_routes")
                normalized = [uuid(ref, "Logical_Router static_routes") for ref in refs]
                require(len(normalized) == len(set(normalized)),
                        "duplicate static route reference")
                row["static_routes"] = normalized
    route_parent = {}
    for router in tables["Logical_Router"]:
        router_uuid = router["_uuid"].lower()
        for route_uuid in router["static_routes"]:
            require(route_uuid in route_rows, "router references missing static route")
            require(route_uuid not in route_parent,
                    "static route belongs to multiple routers")
            route_parent[route_uuid] = router_uuid
            key = (router_uuid, *route_rows[route_uuid])
            require(key not in route_keys, "ambiguous static route identity")
            route_keys.add(key)
    collisions = []
    for item in objects:
        require(isinstance(item, dict) and item.get("table") in TABLES,
                "malformed NB plan object")
        table = item["table"]
        if table == "Logical_Router_Static_Route":
            values = item.get("values")
            require(isinstance(values, dict), "malformed planned route")
            parent = by_name["Logical_Router"].get(item.get("parent"))
            if parent is not None and (parent["_uuid"].lower(),
                                       values.get("ip_prefix"),
                                       values.get("nexthop")) in route_keys:
                collisions.append(item["id"])
        elif item.get("name") in names[table]:
            collisions.append(item["id"])
    require(not collisions, "planned NB collision: " + ",".join(sorted(collisions)))
    ls = by_name["Logical_Switch"].get("ls-mgc-tenant")
    lr = by_name["Logical_Router"].get("lr-mgc-tenant")
    lrp = by_name["Logical_Router_Port"].get("lrp-mgc-tenant")
    require(ls is not None and lr is not None and lrp is not None,
            "missing M03 A LS/LR/LRP")
    router_lsp = by_name["Logical_Switch_Port"].get("lsp-mgc-tenant-router")
    vm_lsp = by_name["Logical_Switch_Port"].get("mgc-tenant-vm")
    require(router_lsp is not None and vm_lsp is not None,
            "A tenant LSP identity is missing")
    require(router_lsp["type"] == "router" and
            router_lsp["options"].get("router-port") == "lrp-mgc-tenant",
            "A tenant router LSP linkage is invalid")
    required_ls_ports = {router_lsp["_uuid"].lower(), vm_lsp["_uuid"].lower()}
    require(required_ls_ports <= set(ls["ports"]) and
            uuid(lrp["_uuid"], "A LRP") in lr["ports"],
            "A topology is incomplete")
    require(all(not (required_ls_ports & set(other["ports"]))
                for other in tables["Logical_Switch"] if other is not ls),
            "A tenant LSP has another parent")
    lsp_uuids = {row["_uuid"].lower() for row in tables["Logical_Switch_Port"]}
    require(set(ls["ports"]) <= lsp_uuids,
            "A LS references missing LSP")
    return {"schema": "p004-x05-nb-preflight-v1", "status": "PASS",
            "nb_cfg": before, "planned_rows_absent": len(objects),
            "owner_residue": 0,
            "a_fingerprint": {"ls_uuid": ls["_uuid"].lower(),
                              "lr_uuid": lr["_uuid"].lower(),
                              "lrp_uuid": lrp["_uuid"].lower(),
                              "ls_ports": sorted(ls["ports"]),
                              "lr_ports": sorted(lr["ports"])}}


def main():
    require(len(sys.argv) in (3, 4), "usage: x05-nb-preflight.sh --fixture FILE | --live")
    wrapper = sys.argv[1]
    mode = sys.argv[2]
    require((mode == "--live" and len(sys.argv) == 3) or
            (mode == "--fixture" and len(sys.argv) == 4),
            "usage: x05-nb-preflight.sh --fixture FILE | --live")
    objects = plan()
    if mode == "--live":
        snapshot = live_snapshot()
    else:
        try:
            snapshot = load_json(pathlib.Path(sys.argv[3]).read_text())
        except (OSError, UnicodeError) as exc:
            raise PreflightError("fixture unavailable") from exc
    return validate(snapshot, objects)


try:
    print(json.dumps(main(), sort_keys=True, separators=(",", ":")))
except PreflightError as exc:
    print(json.dumps({"schema": "p004-x05-nb-preflight-v1", "status": "FAIL",
                      "reason": str(exc)}, sort_keys=True, separators=(",", ":")))
    sys.exit(1)
PY
