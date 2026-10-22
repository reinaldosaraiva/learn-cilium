#!/usr/bin/env bash
# Read-only full-column OVN NB inventory for the X05 inverse guard.
# --live has bounded docker exec / ovn-nbctl list calls and no OVSDB writes.
set -euo pipefail
exec python3 - "$@" <<'PY'
import json
import pathlib
import re
import subprocess
import sys
import time


TABLES = ("Logical_Switch", "Logical_Router", "Logical_Switch_Port",
          "Logical_Router_Port", "Gateway_Chassis", "Logical_Router_Static_Route",
          "Network_Function", "Port_Group", "Logical_Router_Policy", "NAT")
REFERENCE_COLUMNS = {
    "Logical_Switch": ("ports",),
    "Network_Function": ("outport", "inport"),
    "Port_Group": ("ports",),
    "Logical_Router": ("ports", "static_routes"),
    "Logical_Router_Port": ("gateway_chassis",),
    "Logical_Router_Policy": ("output_port",),
    "NAT": ("gateway_port",),
}
UUID = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z")


class SnapshotError(ValueError):
    """The NB read cannot establish a complete, stable inventory."""


def require(ok, message):
    if not ok:
        raise SnapshotError(message)


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, "duplicate JSON key")
        value[key] = item
    return value


def parse(data):
    return json.loads(data, object_pairs_hook=unique_object,
                      parse_constant=lambda value: (_ for _ in ()).throw(
                          SnapshotError("non-finite JSON number: " + value)))


def read(table):
    command = ["docker", "exec", "ovn-central-az1", "ovn-nbctl", "--timeout=5",
               "--format=json", "list", table]
    result = subprocess.run(command, capture_output=True, text=True,
                            timeout=12, check=False)
    require(result.returncode == 0, "NB read failed: " + table)
    raw = parse(result.stdout)
    require(isinstance(raw, dict) and isinstance(raw.get("headings"), list)
            and isinstance(raw.get("data"), list), "invalid NB list shape")
    headings = raw["headings"]
    require(len(headings) == len(set(headings)) and "_uuid" in headings,
            "invalid NB headings")
    require(set(REFERENCE_COLUMNS.get(table, ())) <= set(headings),
            "missing NB reference columns: " + table)
    rows = []
    for cells in raw["data"]:
        require(isinstance(cells, list) and len(cells) == len(headings),
                "invalid NB row cells")
        row = dict(zip(headings, cells))
        uid = row["_uuid"]
        require(isinstance(uid, list) and len(uid) == 2 and uid[0] == "uuid"
                and isinstance(uid[1], str) and UUID.fullmatch(uid[1]) is not None,
                "invalid NB row UUID")
        row["_uuid"] = uid[1].lower()
        rows.append(row)
    return rows


def live():
    started = time.time_ns()
    before = read("NB_Global")
    require(len(before) == 1 and type(before[0].get("nb_cfg")) is int,
            "invalid NB_Global before inventory")
    tables = {table: read(table) for table in TABLES}
    after = read("NB_Global")
    finished = time.time_ns()
    require(len(after) == 1 and type(after[0].get("nb_cfg")) is int,
            "invalid NB_Global after inventory")
    return {"schema": "p004-x05-nb-full-snapshot-v1",
            "capture_started_ns": started, "capture_finished_ns": finished,
            "nb_cfg_before": before[0]["nb_cfg"],
            "nb_cfg_after": after[0]["nb_cfg"], "tables": tables}


def validate(snapshot):
    require(isinstance(snapshot, dict) and
            snapshot.get("schema") == "p004-x05-nb-full-snapshot-v1" and
            type(snapshot.get("nb_cfg_before")) is int and
            snapshot["nb_cfg_before"] == snapshot.get("nb_cfg_after"),
            "invalid or drifting NB snapshot")
    tables = snapshot.get("tables")
    if "capture_started_ns" in snapshot or "capture_finished_ns" in snapshot:
        require(type(snapshot.get("capture_started_ns")) is int and
                type(snapshot.get("capture_finished_ns")) is int and
                0 < snapshot["capture_started_ns"] <= snapshot["capture_finished_ns"],
                "invalid snapshot capture interval")
    require(isinstance(tables, dict) and set(tables) == set(TABLES),
            "incomplete NB tables")
    uuids = set()
    for table, rows in tables.items():
        require(isinstance(rows, list), "invalid table rows: " + table)
        for row in rows:
            require(isinstance(row, dict) and isinstance(row.get("_uuid"), str)
                    and UUID.fullmatch(row["_uuid"]) is not None,
                    "invalid row UUID: " + table)
            uid = row["_uuid"].lower()
            require(uid not in uuids, "duplicate NB UUID")
            uuids.add(uid)
            require(set(REFERENCE_COLUMNS.get(table, ())) <= set(row),
                    "missing NB reference columns: " + table)
    return snapshot


def main():
    require(len(sys.argv) in (2, 3), "usage: --live | --fixture FILE")
    if sys.argv[1:] == ["--live"]:
        snapshot = live()
    else:
        require(len(sys.argv) == 3 and sys.argv[1] == "--fixture",
                "usage: --live | --fixture FILE")
        snapshot = parse(pathlib.Path(sys.argv[2]).read_text())
    print(json.dumps(validate(snapshot), sort_keys=True, separators=(",", ":")))


try:
    main()
except (SnapshotError, OSError, ValueError, subprocess.TimeoutExpired) as exc:
    print("X05 NB full snapshot FAIL: " + str(exc), file=sys.stderr)
    sys.exit(1)
PY
