#!/usr/bin/env python3
"""Reconcile an X05 forward commit using only local NB artifacts.

This helper never talks to OVSDB, Docker, SSH, or the laboratory.  It proves
whether two ordered Northbound snapshots currently show the planned ``BUILT``
state or the original ``CLEAN`` state after an ambiguous commit.  The proof is
deliberately a different artifact from the ordinary transaction receipt
because an ambiguous commit has no trustworthy commit result.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import stat
import sys
import time
from collections.abc import Iterable
from typing import Any


HERE = pathlib.Path(__file__).resolve().parent
TX_SPEC = importlib.util.spec_from_file_location("x05_nb_tx", HERE / "x05-nb-tx.py")
if TX_SPEC is None or TX_SPEC.loader is None:  # pragma: no cover - import failure
    raise RuntimeError("cannot load x05-nb-tx.py")
TX = importlib.util.module_from_spec(TX_SPEC)
TX_SPEC.loader.exec_module(TX)

POST_SPEC = importlib.util.spec_from_file_location(
    "x05_nb_postflight", HERE / "x05-nb-postflight.py"
)
if POST_SPEC is None or POST_SPEC.loader is None:  # pragma: no cover
    raise RuntimeError("cannot load x05-nb-postflight.py")
POST = importlib.util.module_from_spec(POST_SPEC)
POST_SPEC.loader.exec_module(POST)


SCHEMA = "p004-x05-nb-forward-recovery-v1"
JOURNAL_SCHEMA = "p004-x05-nb-live-journal-v1"
SNAPSHOT_SCHEMA = "p004-x05-nb-full-snapshot-v1"
OWNER = TX.OWNER
UUID = TX.UUID
HEX6 = TX.HEX6
PLAN_TABLES = TX.PLAN_TABLES
SNAPSHOT_TABLES = TX.SNAPSHOT_TABLES

RECOVERABLE_STATES = frozenset(
    {
        "NB_FORWARD_INTENT",
        "NB_FORWARD_AMBIGUOUS",
        "NB_FORWARD_COMMITTED",
        "NB_FORWARD_RECOVERY_INTENT",
        "NB_FORWARD_RECOVERY_BLOCKED",
    }
)
RECOVERED_STATES = frozenset(
    {"NB_FORWARD_RECOVERED_VERIFIED", "NB_FORWARD_RECOVERED_CLEAN"}
)
ATTEMPT_PREFIX = "recovery-attempt-"
ATTEMPT_RE = re.compile(r"recovery-attempt-(\d+)-(source|revalidate|proof)\.json\Z")
X05_NAME = re.compile(r"(?:^|[-_])x05(?:[-_]|$)", re.IGNORECASE)
MARKER_STATES = frozenset(
    {"M03_ACTIVE", "INTENT", "BUILT", "RESTORE_INTENT", "X05_CLEANED"}
)


class RecoveryError(ValueError):
    """The local evidence cannot prove a safe recovery outcome."""


class RecoveryBlocked(RecoveryError):
    """The evidence is valid enough to inspect but does not prove one state."""


def require(ok: bool, message: str, *, blocked: bool = False) -> None:
    if not ok:
        raise RecoveryBlocked(message) if blocked else RecoveryError(message)


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key: " + key)
        result[key] = value
    return result


def read_json(path: pathlib.Path) -> tuple[Any, bytes]:
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise RecoveryError("cannot read local artifact: " + str(path)) from exc
    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=unique_object,
            parse_constant=lambda item: (_ for _ in ()).throw(
                RecoveryError("non-finite JSON number: " + item)
            ),
        )
    except (UnicodeError, json.JSONDecodeError, RecoveryError) as exc:
        if isinstance(exc, RecoveryError):
            raise
        raise RecoveryError("malformed JSON artifact: " + str(path)) from exc
    return value, raw


def canonical(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def sha256(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def owner_for(run_hex: str) -> str:
    require(isinstance(run_hex, str) and HEX6.fullmatch(run_hex) is not None,
            "run hex must be six lowercase hexadecimal digits")
    return "labctl-x05-" + run_hex


def _as_uuid(value: Any, context: str) -> str:
    require(isinstance(value, str) and UUID.fullmatch(value) is not None,
            "invalid UUID: " + context)
    return value.lower()


def _map(value: Any, context: str) -> dict[str, str]:
    require(isinstance(value, list) and len(value) == 2 and value[0] == "map"
            and isinstance(value[1], list), "malformed OVSDB map: " + context)
    result: dict[str, str] = {}
    for pair in value[1]:
        require(isinstance(pair, list) and len(pair) == 2 and
                all(isinstance(item, str) for item in pair),
                "malformed OVSDB map entry: " + context)
        require(pair[0] not in result, "duplicate OVSDB map key: " + context)
        result[pair[0]] = pair[1]
    return result


def _uuid_set(value: Any, context: str) -> set[str]:
    if isinstance(value, list) and len(value) == 2 and value[0] == "set":
        values = value[1]
    else:
        values = [value]
    require(isinstance(values, list), "malformed UUID set: " + context)
    result = {_as_uuid(item[1], context) for item in values if
              isinstance(item, list) and len(item) == 2 and item[0] == "uuid"}
    require(len(result) == len(values), "malformed or duplicate UUID set: " + context)
    return result


def _validate_ovs(value: Any, context: str) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            _validate_ovs(child, context + ":" + str(key))
        return
    if not isinstance(value, list):
        return
    if len(value) == 2 and value[0] == "uuid":
        _as_uuid(value[1], context)
    elif len(value) == 2 and value[0] in {"set", "map"}:
        require(isinstance(value[1], list), "malformed OVSDB value: " + context)
        if value[0] == "map":
            keys: list[str] = []
            for pair in value[1]:
                require(isinstance(pair, list) and len(pair) == 2,
                        "malformed OVSDB map pair: " + context)
                keys.append(json.dumps(pair[0], sort_keys=True))
                _validate_ovs(pair[0], context)
                _validate_ovs(pair[1], context)
            require(len(keys) == len(set(keys)), "duplicate OVSDB map key: " + context)
        else:
            atoms = [json.dumps(item, sort_keys=True) for item in value[1]]
            require(len(atoms) == len(set(atoms)), "duplicate OVSDB set atom: " + context)
            for item in value[1]:
                _validate_ovs(item, context)
    else:
        for child in value:
            _validate_ovs(child, context)


def _snapshot_tables(snapshot: Any) -> dict[str, list[dict[str, Any]]]:
    require(isinstance(snapshot, dict) and snapshot.get("schema") == SNAPSHOT_SCHEMA,
            "full ten-table snapshot schema required", blocked=True)
    before, after = snapshot.get("nb_cfg_before"), snapshot.get("nb_cfg_after")
    require(type(before) is int and type(after) is int and before >= 0 and before == after,
            "NB snapshot is not stable", blocked=True)
    started, finished = snapshot.get("capture_started_ns"), snapshot.get("capture_finished_ns")
    require(type(started) is int and type(finished) is int and 0 < started <= finished,
            "NB snapshot lacks a stable capture interval", blocked=True)
    tables = snapshot.get("tables")
    require(isinstance(tables, dict) and set(tables) == SNAPSHOT_TABLES,
            "complete ten-table NB snapshot required", blocked=True)
    all_uuids: set[str] = set()
    for table, rows in tables.items():
        require(isinstance(rows, list), "malformed NB table: " + table, blocked=True)
        for row in rows:
            require(isinstance(row, dict), "malformed NB row: " + table, blocked=True)
            uid = _as_uuid(row.get("_uuid"), table)
            require(uid not in all_uuids, "duplicate NB UUID: " + uid, blocked=True)
            all_uuids.add(uid)
            for column, value in row.items():
                if column != "_uuid":
                    _validate_ovs(value, table + ":" + column)
            require(set(TX.REFERRER_COLUMNS.get(table, ())) <= set(row),
                    "missing reference column: " + table, blocked=True)
            for column in TX.REFERRER_COLUMNS.get(table, ()):
                _uuid_set(row[column], table + ":" + column)
            if table in TX.NAMED_TABLES:
                require(isinstance(row.get("name"), str) and row["name"],
                        "malformed NB name: " + table, blocked=True)
            if table in PLAN_TABLES:
                require("external_ids" in row, "missing external_ids: " + table,
                        blocked=True)
                _map(row["external_ids"], table + ":external_ids")
    return tables


def _row_indexes(
    tables: dict[str, list[dict[str, Any]]],
) -> tuple[dict[str, tuple[str, dict[str, Any]]], dict[tuple[str, str], dict[str, Any]]]:
    rows: dict[str, tuple[str, dict[str, Any]]] = {}
    names: dict[tuple[str, str], dict[str, Any]] = {}
    for table, entries in tables.items():
        for row in entries:
            uid = _as_uuid(row["_uuid"], table)
            rows[uid] = (table, row)
            if table in TX.NAMED_TABLES:
                key = (table, row["name"])
                require(key not in names, "duplicate NB identity: %s:%s" % key,
                        blocked=True)
                names[key] = row
    return rows, names


def _route_indexes(
    tables: dict[str, list[dict[str, Any]]], rows: dict[str, tuple[str, dict[str, Any]]]
) -> tuple[dict[tuple[str, str, str], list[dict[str, Any]]], dict[str, str]]:
    route_parent: dict[str, str] = {}
    route_rows = {
        _as_uuid(row["_uuid"], "route"): row
        for row in tables["Logical_Router_Static_Route"]
    }
    for router in tables["Logical_Router"]:
        router_uid = _as_uuid(router["_uuid"], "router")
        for route_uid in _uuid_set(router["static_routes"], "router static_routes"):
            require(route_uid in route_rows, "router references missing route", blocked=True)
            require(route_uid not in route_parent, "route has multiple parents", blocked=True)
            route_parent[route_uid] = router_uid
    identities: dict[tuple[str, str, str], list[dict[str, Any]]] = {}
    for route_uid, row in route_rows.items():
        require(route_uid in route_parent, "unparented static route", blocked=True)
        parent_uid = route_parent[route_uid]
        prefix, nexthop = row.get("ip_prefix"), row.get("nexthop")
        require(isinstance(prefix, str) and isinstance(nexthop, str),
                "malformed static route identity", blocked=True)
        identities.setdefault((parent_uid, prefix, nexthop), []).append(row)
    return identities, route_parent


def _plan_route_identities(
    objects: list[dict[str, Any]], names: dict[tuple[str, str], dict[str, Any]]
) -> dict[tuple[str, str, str], dict[str, Any]]:
    planned: dict[tuple[str, str, str], dict[str, Any]] = {}
    for item in objects:
        if item["table"] != "Logical_Router_Static_Route":
            continue
        parent = names.get(("Logical_Router", item["parent"]))
        require(parent is not None, "planned route parent is absent", blocked=True)
        parent_uid = _as_uuid(parent["_uuid"], "planned route parent")
        values = item["values"]
        key = (parent_uid, values["ip_prefix"], values["nexthop"])
        require(key not in planned, "duplicate planned route identity", blocked=True)
        planned[key] = item
    return planned


def _validate_owner_and_names(
    tables: dict[str, list[dict[str, Any]]],
    names: dict[tuple[str, str], dict[str, Any]],
    objects: list[dict[str, Any]],
    owner: str,
    *,
    built: bool,
) -> None:
    planned_names = {
        (item["table"], item["name"])
        for item in objects
        if item["table"] != "Logical_Router_Static_Route"
    }
    owner_uids: set[str] = set()
    for table, entries in tables.items():
        for row in entries:
            uid = _as_uuid(row["_uuid"], table)
            external = _map(row["external_ids"], table + ":external_ids") \
                if "external_ids" in row else {}
            if "x05-owner" in external:
                is_planned = table == "Logical_Router_Static_Route" or \
                    (table, row.get("name")) in planned_names
                require(external["x05-owner"] == owner and is_planned,
                        "foreign X05 owner row: " + uid, blocked=True)
                owner_uids.add(uid)
            if table in TX.NAMED_TABLES and X05_NAME.search(row["name"]):
                require((table, row["name"]) in planned_names,
                        "foreign X05 name: " + row["name"], blocked=True)
    if built:
        require(len(owner_uids) == 34, "BUILT requires exactly 34 owned rows", blocked=True)
    else:
        require(not owner_uids, "CLEAN contains owned X05 rows", blocked=True)


def _a_fingerprint(
    rows: dict[str, tuple[str, dict[str, Any]]], preflight: dict[str, Any], *, built: bool,
    inserted: dict[str, str] | None,
) -> None:
    fingerprint = preflight.get("a_fingerprint")
    require(isinstance(fingerprint, dict), "missing A fingerprint", blocked=True)
    for key, table, name in (
        ("ls_uuid", "Logical_Switch", "ls-mgc-tenant"),
        ("lr_uuid", "Logical_Router", "lr-mgc-tenant"),
        ("lrp_uuid", "Logical_Router_Port", "lrp-mgc-tenant"),
    ):
        uid = _as_uuid(fingerprint.get(key), "A " + key)
        require(uid in rows and rows[uid][0] == table and rows[uid][1].get("name") == name,
                "A identity drift: " + name, blocked=True)
        require("x05-owner" not in _map(rows[uid][1]["external_ids"], name),
                "A owner drift: " + name, blocked=True)
    ls = rows[_as_uuid(fingerprint["ls_uuid"], "A LS")][1]
    lr = rows[_as_uuid(fingerprint["lr_uuid"], "A LR")][1]
    expected_ls = {_as_uuid(port, "original A LS port") for port in fingerprint["ls_ports"]}
    expected_lr = {_as_uuid(port, "original A LR port") for port in fingerprint["lr_ports"]}
    if built:
        require(inserted is not None and "Logical_Switch_Port:x05-tenant-a-vm" in inserted,
                "BUILT sentinel mapping is missing", blocked=True)
        sentinel = inserted["Logical_Switch_Port:x05-tenant-a-vm"]
        require(sentinel not in expected_ls, "sentinel was present in original A LS",
                blocked=True)
        expected_ls.add(sentinel)
    require(POST.uuid_set(ls.get("ports"), "A LS ports") == expected_ls,
            "A LS ports drift", blocked=True)
    require(POST.uuid_set(lr.get("ports"), "A LR ports") == expected_lr,
            "A LR ports drift", blocked=True)


def _built_mapping(
    tables: dict[str, list[dict[str, Any]]],
    names: dict[tuple[str, str], dict[str, Any]],
    objects: list[dict[str, Any]],
    owner: str,
) -> dict[str, str]:
    routes, route_parent = _route_indexes(tables, {
        _as_uuid(row["_uuid"], table): (table, row)
        for table, entries in tables.items()
        for row in entries
    })
    route_plan = _plan_route_identities(objects, names)
    mapping: dict[str, str] = {}
    for item in objects:
        if item["table"] == "Logical_Router_Static_Route":
            parent = names[("Logical_Router", item["parent"])]
            key = (
                _as_uuid(parent["_uuid"], "route parent"),
                item["values"]["ip_prefix"],
                item["values"]["nexthop"],
            )
            matched = routes.get(key, [])
            require(len(matched) == 1 and key in route_plan,
                    "planned route is absent or ambiguous", blocked=True)
            row = matched[0]
        else:
            matched = names.get((item["table"], item["name"]))
            require(matched is not None, "planned NB row is absent: " + item["name"],
                    blocked=True)
            row = matched
        uid = _as_uuid(row["_uuid"], item["id"])
        external = _map(row["external_ids"], item["id"] + ":external_ids")
        require(external.get("x05-owner") == owner,
                "planned row owner drift: " + item["id"], blocked=True)
        require(item["id"] not in mapping, "duplicate plan mapping: " + item["id"],
                blocked=True)
        mapping[item["id"]] = uid
    require(len(mapping) == 34 and len(set(mapping.values())) == 34,
            "BUILT plan mapping is not bijective", blocked=True)
    del route_parent
    return mapping


def _clean_route_and_identity_check(
    tables: dict[str, list[dict[str, Any]]],
    names: dict[tuple[str, str], dict[str, Any]],
    objects: list[dict[str, Any]],
) -> None:
    planned_names = {
        (item["table"], item["name"])
        for item in objects
        if item["table"] != "Logical_Router_Static_Route"
    }
    require(not planned_names.intersection(names), "CLEAN has a planned NB name", blocked=True)
    routes, _ = _route_indexes(
        tables,
        {
            _as_uuid(row["_uuid"], table): (table, row)
            for table, entries in tables.items()
            for row in entries
        },
    )
    planned_route_keys = {
        (item["parent"], item["values"]["ip_prefix"], item["values"]["nexthop"])
        for item in objects
        if item["table"] == "Logical_Router_Static_Route"
    }
    actual_route_keys = set()
    for (parent_uid, prefix, nexthop), route_rows in routes.items():
        del route_rows
        parent = next(
            row for row in tables["Logical_Router"]
            if _as_uuid(row["_uuid"], "route parent") == parent_uid
        )
        actual_route_keys.add((parent["name"], prefix, nexthop))
    require(not actual_route_keys.intersection(planned_route_keys),
            "CLEAN has a planned route identity", blocked=True)


def _verify_full_rows(
    snapshot: dict[str, Any],
    preflight: dict[str, Any],
    objects: list[dict[str, Any]],
    mapping: dict[str, str],
    owner: str,
    run_hex: str,
) -> None:
    transaction = TX.build(preflight, owner, run_hex, objects)
    inserts = [operation for operation in transaction[1:] if operation["op"] == "insert"]
    names = {
        operation["uuid-name"]: mapping[item["id"]]
        for item, operation in zip(objects, inserts)
    }
    TX.complete_rows(
        snapshot,
        objects,
        mapping,
        inserts,
        names,
        preflight["a_fingerprint"],
    )


def _validate_state(
    snapshot: dict[str, Any],
    preflight: dict[str, Any],
    transaction: list[Any],
    owner: str,
    run_hex: str,
    *,
    outcome: str | None = None,
) -> tuple[str, dict[str, str] | None]:
    tables = _snapshot_tables(snapshot)
    rows, names = _row_indexes(tables)
    objects = TX.plan()
    rebuilt = TX.build(preflight, owner, run_hex, objects)
    require(TX.canonical(transaction) == TX.canonical(rebuilt),
            "stored forward transaction differs from rebuilt transaction", blocked=True)
    _validate_owner_and_names(tables, names, objects, owner, built=outcome != "CLEAN")
    if outcome == "CLEAN":
        _clean_route_and_identity_check(tables, names, objects)
        _a_fingerprint(rows, preflight, built=False, inserted=None)
        return "CLEAN", None
    mapping = _built_mapping(tables, names, objects, owner)
    _a_fingerprint(rows, preflight, built=True, inserted=mapping)
    _verify_full_rows(snapshot, preflight, objects, mapping, owner, run_hex)
    return "BUILT", mapping


def validate_state(
    snapshot: dict[str, Any],
    preflight: dict[str, Any],
    transaction: list[Any],
    owner: str,
    run_hex: str,
) -> tuple[str, dict[str, str] | None]:
    """Return the only state proved by one stable full NB snapshot."""

    try:
        return _validate_state(snapshot, preflight, transaction, owner, run_hex)
    except RecoveryBlocked as built_error:
        try:
            return _validate_state(
                snapshot, preflight, transaction, owner, run_hex, outcome="CLEAN"
            )
        except RecoveryBlocked as clean_error:
            raise RecoveryBlocked(
                "neither BUILT nor CLEAN is proved: %s; %s"
                % (built_error, clean_error)
            ) from clean_error
    except (KeyError, TypeError, TX.TransactionError, POST.PostflightError) as exc:
        raise RecoveryBlocked(str(exc)) from exc


def _validate_preflight(preflight: dict[str, Any], owner: str, run_hex: str) -> None:
    require(preflight.get("schema") == "p004-x05-nb-preflight-v1" and
            preflight.get("status") == "PASS" and
            preflight.get("planned_rows_absent") == 34 and
            preflight.get("owner_residue") == 0,
            "PASS preflight with 34 absent rows required", blocked=True)
    require(isinstance(preflight.get("a_fingerprint"), dict),
            "preflight A fingerprint is missing", blocked=True)
    TX.build(preflight, owner, run_hex, TX.plan())


def _artifact_path(evidence_dir: pathlib.Path, name: str) -> pathlib.Path:
    require(name in {"preflight.json", "forward-tx.json", "forward-result.raw.json",
                      "forward-checked.json", "built-snapshot.json", "built-checked.json"},
            "journal references an unexpected forward artifact", blocked=True)
    path = (evidence_dir / name).absolute()
    require(path.parent == evidence_dir.absolute(), "artifact escapes evidence directory",
            blocked=True)
    require(not path.is_symlink() and path.is_file(),
            "forward artifact is not a regular file: " + name, blocked=True)
    try:
        require(path.stat().st_mode & 0o077 == 0,
                "forward artifact permissions are too broad: " + name, blocked=True)
    except OSError as exc:
        raise RecoveryBlocked("cannot stat forward artifact: " + name) from exc
    return path


def _recovery_artifact_path(evidence_dir: pathlib.Path, name: str) -> pathlib.Path:
    require(isinstance(name, str) and ATTEMPT_RE.fullmatch(name) is not None,
            "journal references an invalid recovery artifact", blocked=True)
    path = (evidence_dir / name).absolute()
    require(path.parent == evidence_dir.absolute() and not path.is_symlink() and
            path.is_file(), "recovery artifact is not a regular file: " + name,
            blocked=True)
    try:
        require(path.stat().st_mode & 0o077 == 0,
                "recovery artifact permissions are too broad: " + name,
                blocked=True)
    except OSError as exc:
        raise RecoveryBlocked("cannot stat recovery artifact: " + name) from exc
    return path


def _load_context(
    evidence_dir: pathlib.Path,
    owner: str,
    run_hex: str,
) -> tuple[
    dict[str, Any], pathlib.Path, dict[str, Any], bytes,
    pathlib.Path, list[Any], bytes, str,
]:
    journal_path = evidence_dir / "journal.json"
    require(not journal_path.is_symlink() and journal_path.is_file(),
            "X05 journal is not a regular file", blocked=True)
    journal, _ = read_json(journal_path)
    require(isinstance(journal, dict) and journal.get("schema") == JOURNAL_SCHEMA,
            "invalid X05 NB journal", blocked=True)
    require(journal.get("owner") == owner and journal.get("run_hex") == run_hex,
            "journal belongs to another X05 run", blocked=True)
    require(journal.get("evidence_dir") == str(evidence_dir.absolute()),
            "journal is bound to another evidence directory", blocked=True)
    state = journal.get("state")
    require(state in RECOVERABLE_STATES,
            "journal state is not recoverable: " + str(state), blocked=True)
    events = journal.get("events")
    require(isinstance(events, list), "invalid journal events", blocked=True)
    artifacts = [event for event in events if isinstance(event, dict) and "artifact" in event]
    require([event.get("artifact") for event in artifacts][:2] == ["preflight", "forward_tx"],
            "journal lacks immutable preflight/forward artifacts", blocked=True)
    for event in artifacts:
        stage = event.get("artifact")
        filename = {
            "preflight": "preflight.json",
            "forward_tx": "forward-tx.json",
            "forward_result": "forward-result.raw.json",
            "forward_checked": "forward-checked.json",
            "built_snapshot": "built-snapshot.json",
            "built_checked": "built-checked.json",
        }.get(stage)
        require(filename is not None, "unknown journal artifact: " + str(stage), blocked=True)
        path = _artifact_path(evidence_dir, filename)
        if stage in {"preflight", "forward_tx", "forward_checked", "built_snapshot",
                     "built_checked"}:
            _, raw = read_json(path)
        else:
            try:
                raw = path.read_bytes()
            except OSError as exc:
                raise RecoveryBlocked("cannot read journal artifact: " + filename) from exc
        require(event.get("path") == filename and event.get("sha256") == sha256(raw),
                "journal artifact hash mismatch: " + str(stage), blocked=True)
    preflight_path = _artifact_path(evidence_dir, "preflight.json")
    transaction_path = _artifact_path(evidence_dir, "forward-tx.json")
    preflight, preflight_raw = read_json(preflight_path)
    transaction, transaction_raw = read_json(transaction_path)
    require(isinstance(preflight, dict) and isinstance(transaction, list),
            "forward artifacts have invalid shapes", blocked=True)
    _validate_preflight(preflight, owner, run_hex)
    rebuilt = TX.build(preflight, owner, run_hex, TX.plan())
    require(TX.canonical(transaction) == TX.canonical(rebuilt),
            "stored forward transaction differs from rebuilt transaction", blocked=True)
    prepared = [
        event for event in events
        if isinstance(event, dict) and event.get("kind") == "mutation-prepared"
        and event.get("phase") == "forward"
    ]
    require(prepared, "forward mutation intent is missing", blocked=True)
    require(prepared[-1].get("owner") == owner and
            prepared[-1].get("run_hex") == run_hex and
            prepared[-1].get("transaction_sha256") == sha256(canonical(transaction)),
            "journal forward transaction hash is not bound", blocked=True)
    return (
        journal, preflight_path, preflight, preflight_raw,
        transaction_path, transaction, transaction_raw, state,
    )


def _attempt_number(
    evidence_dir: pathlib.Path,
    events: list[dict[str, Any]] | None = None,
) -> int:
    numbers = []
    for path in evidence_dir.iterdir():
        match = ATTEMPT_RE.fullmatch(path.name)
        if match:
            numbers.append(int(match.group(1)))
    for event in events or []:
        if not isinstance(event, dict) or event.get("kind") != "recovery-attempt":
            continue
        attempt = event.get("attempt")
        if type(attempt) is int and attempt > 0:
            numbers.append(attempt)
    return max(numbers, default=0) + 1


def _reconcile_interrupted_attempt(
    evidence_dir: pathlib.Path,
    journal: dict[str, Any],
    events: list[dict[str, Any]],
    owner: str,
    run_hex: str,
) -> None:
    """Durably close an attempt stranded after its recovery INTENT append."""
    attempts = [event for event in events
                if isinstance(event, dict) and event.get("kind") == "recovery-attempt"]
    require(attempts, "recovery INTENT has no attempt event", blocked=True)
    previous = attempts[-1]
    require(previous.get("state") == "NB_FORWARD_RECOVERY_INTENT"
            and previous.get("owner") == owner
            and previous.get("run_hex") == run_hex,
            "recovery INTENT is not owned by this run", blocked=True)
    attempt = previous.get("attempt")
    require(type(attempt) is int and attempt > 0,
            "recovery INTENT attempt number is invalid", blocked=True)
    previous["state"] = "NB_FORWARD_RECOVERY_RECONCILED"
    previous["reconciled_at_ns"] = time.time_ns()
    events.append({
        "kind": "recovery-attempt-reconciled",
        "attempt": attempt,
        "owner": owner,
        "run_hex": run_hex,
        "reason": "retry after crash following recovery INTENT journal append",
        "at_ns": time.time_ns(),
    })
    # Keep the global state recoverable if the process crashes during this
    # reconciliation write; the attempt event itself records the closure.
    journal["state"] = "NB_FORWARD_RECOVERY_INTENT"
    _journal_append(evidence_dir / "journal.json", journal)


def _write_new(path: pathlib.Path, raw: bytes) -> None:
    require(not path.exists() and not path.is_symlink(),
            "recovery artifact already exists: " + path.name)
    try:
        with path.open("xb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        path.chmod(0o600)
    except OSError as exc:
        raise RecoveryError("cannot write recovery artifact: " + str(path)) from exc


def _journal_append(path: pathlib.Path, journal: dict[str, Any]) -> None:
    raw = canonical(journal)
    require(not path.is_symlink() and path.is_file(),
            "X05 journal is not a regular file", blocked=True)
    temporary = path.with_name("." + path.name + ".recovery-tmp")
    require(not temporary.exists() and not temporary.is_symlink(),
            "recovery journal temporary file already exists")
    try:
        with temporary.open("xb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.chmod(0o600)
        os.replace(temporary, path)
    except OSError as exc:
        try:
            temporary.unlink()
        except OSError:
            pass
        raise RecoveryError("cannot append recovery journal: " + str(path)) from exc


def _marker_identity(
    marker: pathlib.Path | None,
    owner: str,
    run_hex: str,
) -> dict[str, Any] | None:
    """Read the marker using the same token/optional-field contract as X05."""
    if marker is None:
        return None
    require(not marker.is_symlink() and marker.is_file(),
            "X05 marker is not a regular file")
    try:
        info = marker.stat()
        require(stat.S_IMODE(info.st_mode) == 0o600,
                "X05 marker must be mode 0600")
        raw = marker.read_bytes()
    except OSError as exc:
        raise RecoveryError("cannot read marker for unchanged-state guard") from exc
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeDecodeError as exc:
        raise RecoveryError("X05 marker is not UTF-8") from exc
    values: dict[str, str] = {}
    for line in lines:
        require(bool(line) and "=" in line, "X05 marker has malformed line")
        key, value = line.split("=", 1)
        require(bool(key) and bool(value), "X05 marker has empty key/value")
        if key in {"token", "owner", "run_hex", "state"}:
            require(key not in values, "X05 marker has duplicate " + key)
            values[key] = value
    expected_owner = owner_for(run_hex)
    require(owner == expected_owner and values.get("token") == expected_owner,
            "X05 marker owner/run does not match this invocation")
    if "owner" in values:
        require(values["owner"] == expected_owner,
                "X05 marker owner field does not match token")
    if "run_hex" in values:
        require(values["run_hex"] == run_hex,
                "X05 marker run_hex does not match token")
    if "state" in values:
        require(values["state"] in MARKER_STATES,
                "X05 marker has an unknown state")
    return {
        "raw": raw,
        "sha256": sha256(raw),
        "token": values["token"],
        "owner": values.get("owner"),
        "run_hex": values.get("run_hex"),
        "state": values.get("state"),
    }


def _marker_bytes(marker: pathlib.Path | None) -> bytes | None:
    """Compatibility accessor for local callers that only need raw bytes."""
    if marker is None:
        return None
    require(not marker.is_symlink() and marker.is_file(),
            "X05 marker is not a regular file")
    try:
        require(stat.S_IMODE(marker.stat().st_mode) == 0o600,
                "X05 marker must be mode 0600")
        return marker.read_bytes()
    except OSError as exc:
        raise RecoveryError("cannot read marker for unchanged-state guard") from exc


def _same_marker(
    marker: pathlib.Path | None,
    before: dict[str, Any] | None,
    owner: str,
    run_hex: str,
) -> None:
    if marker is None:
        return
    current = _marker_identity(marker, owner, run_hex)
    if current != before:
        raise RecoveryError("X05 marker changed during local recovery")


def _marker_binding(identity: dict[str, Any] | None) -> dict[str, Any]:
    if identity is None:
        return {"marker_sha256": None, "marker_token": None,
                "marker_owner": None, "marker_run_hex": None,
                "marker_state": None}
    return {"marker_sha256": identity["sha256"],
            "marker_token": identity["token"],
            "marker_owner": identity.get("owner"),
            "marker_run_hex": identity.get("run_hex"),
            "marker_state": identity.get("state")}


def _recovery_proof(
    *,
    owner: str,
    run_hex: str,
    source_state: str,
    outcome: str,
    mapping: dict[str, str] | None,
    preflight_raw: bytes,
    transaction_raw: bytes,
    source_raw: bytes,
    revalidate_raw: bytes,
    source_name: str,
    revalidate_name: str,
    attempt: int,
    marker_identity: dict[str, Any] | None,
) -> dict[str, Any]:
    proof: dict[str, Any] = {
        "schema": SCHEMA,
        "status": "PASS",
        "outcome": outcome,
        "commit_outcome": "UNKNOWN",
        "owner": owner,
        "run_hex": run_hex,
        "source_state": source_state,
        "attempt": attempt,
        "transaction_sha256": sha256(transaction_raw),
        "owner_sha256": sha256(owner.encode("utf-8")),
        "run_sha256": sha256(run_hex.encode("utf-8")),
        "transaction_canonical_sha256": sha256(canonical(json.loads(
            transaction_raw.decode("utf-8"), object_pairs_hook=unique_object
        ))),
        "preflight_sha256": sha256(preflight_raw),
        "preflight_canonical_sha256": sha256(canonical(json.loads(
            preflight_raw.decode("utf-8"), object_pairs_hook=unique_object
        ))),
        "snapshot_sha256": sha256(source_raw),
        "source_snapshot_sha256": sha256(source_raw),
        "revalidation_snapshot_sha256": sha256(revalidate_raw),
        "source_snapshot": source_name,
        "revalidation_snapshot": revalidate_name,
        "created_at_ns": time.time_ns(),
    }
    proof.update(_marker_binding(marker_identity))
    if mapping is not None:
        proof["inserted"] = dict(sorted(mapping.items()))
    proof["proof_sha256"] = sha256(canonical(proof))
    return proof


def _proof_digest(proof: dict[str, Any]) -> str:
    unsigned = dict(proof)
    unsigned.pop("proof_sha256", None)
    return sha256(canonical(unsigned))


def _recovery_publish_recheck(
    *,
    evidence_dir: pathlib.Path,
    preflight_path: pathlib.Path,
    preflight_raw: bytes,
    transaction_path: pathlib.Path,
    transaction_raw: bytes,
    source_snapshot_path: pathlib.Path,
    source_raw: bytes,
    revalidation_snapshot_path: pathlib.Path,
    revalidation_raw: bytes,
    source_artifact: pathlib.Path,
    revalidate_artifact: pathlib.Path,
    proof_artifact: pathlib.Path,
    proof_raw: bytes,
    expected_journal_raw: bytes,
    phase: str,
    marker: pathlib.Path | None,
    marker_identity: dict[str, Any] | None,
    owner: str,
    run_hex: str,
) -> None:
    """Recheck every input immediately before or after recovery publication.

    The forward files are parsed into a local capsule before the recovery
    INTENT append.  Matching byte checks on both sides of the final journal
    append detect changes made in its publication window.  A normal mismatch
    therefore leaves the attempt BLOCKED instead of returning a proof whose
    hashes describe an earlier read.
    """

    require(phase in {"before", "after"}, "invalid recovery publication phase")
    suffix = phase + " recovery publish"
    paths = (
        (preflight_path, preflight_raw, "bound preflight changed " + suffix),
        (transaction_path, transaction_raw,
         "bound forward transaction changed " + suffix),
        (source_snapshot_path, source_raw,
         "source snapshot changed " + suffix),
        (revalidation_snapshot_path, revalidation_raw,
         "revalidation snapshot changed " + suffix),
        (source_artifact, source_raw,
         "source recovery artifact changed " + suffix),
        (revalidate_artifact, revalidation_raw,
         "revalidation recovery artifact changed " + suffix),
        (proof_artifact, proof_raw,
         "recovery proof changed " + suffix),
    )
    for path, expected, message in paths:
        try:
            require(not path.is_symlink() and path.is_file(), message, blocked=True)
            current = path.read_bytes()
        except OSError as exc:
            raise RecoveryBlocked(message) from exc
        require(current == expected, message, blocked=True)
    journal_path = evidence_dir / "journal.json"
    journal_message = "recovery journal changed " + suffix
    try:
        require(not journal_path.is_symlink() and journal_path.is_file(),
                journal_message, blocked=True)
        current_journal = journal_path.read_bytes()
    except OSError as exc:
        raise RecoveryBlocked("recovery journal disappeared " + suffix) from exc
    require(current_journal == expected_journal_raw, journal_message, blocked=True)
    _same_marker(marker, marker_identity, owner, run_hex)


def recover(
    evidence_dir: pathlib.Path,
    run_hex: str,
    source_snapshot_path: pathlib.Path,
    revalidation_snapshot_path: pathlib.Path,
    *,
    marker: pathlib.Path | None = None,
) -> dict[str, Any]:
    """Create and verify one immutable local forward-recovery proof."""

    evidence_dir = evidence_dir.absolute()
    owner = owner_for(run_hex)
    (
        journal, preflight_path, preflight, preflight_raw,
        transaction_path, transaction, transaction_raw, source_state,
    ) = _load_context(evidence_dir, owner, run_hex)
    marker_before = _marker_identity(marker, owner, run_hex)
    require(marker is not None or journal.get("marker") is None,
            "journal-bound X05 marker is required for recovery", blocked=True)
    if marker is not None:
        require(journal.get("marker") == str(marker.absolute()),
                "journal is bound to another X05 marker", blocked=True)
    # A recovery attempt is append-only.  Existing attempt files and their
    # journal hashes are checked before adding a new attempt, so a tampered
    # proof cannot be silently superseded.
    evidence_events = journal.get("events")
    require(isinstance(evidence_events, list), "invalid journal events", blocked=True)
    for event in evidence_events:
        if not isinstance(event, dict) or event.get("kind") != "recovery-attempt":
            continue
        artifacts = event.get("artifacts")
        require(isinstance(artifacts, list),
                "recovery attempt artifact list is malformed", blocked=True)
        for artifact in artifacts:
            require(isinstance(artifact, dict),
                    "recovery attempt artifact is malformed", blocked=True)
            path = _recovery_artifact_path(evidence_dir, artifact.get("path"))
            _, raw = read_json(path)
            require(artifact.get("sha256") == sha256(raw),
                    "recovery artifact hash mismatch", blocked=True)

    if source_state == "NB_FORWARD_RECOVERY_INTENT":
        prior_attempts = [event for event in evidence_events
                          if isinstance(event, dict)
                          and event.get("kind") == "recovery-attempt"]
        require(prior_attempts, "recovery INTENT has no attempt event", blocked=True)
        latest = prior_attempts[-1]
        if latest.get("state") == "NB_FORWARD_RECOVERY_INTENT":
            _reconcile_interrupted_attempt(
                evidence_dir, journal, evidence_events, owner, run_hex
            )
        else:
            require(latest.get("state") == "NB_FORWARD_RECOVERY_RECONCILED",
                    "recovery INTENT has an unresolved attempt", blocked=True)
    attempt = _attempt_number(evidence_dir, evidence_events)
    attempt_event: dict[str, Any] = {
        "kind": "recovery-attempt",
        "attempt": attempt,
        "source_state": source_state,
        "state": "NB_FORWARD_RECOVERY_INTENT",
        "owner": owner,
        "run_hex": run_hex,
        "started_at_ns": time.time_ns(),
        "artifacts": [],
    }
    attempt_event.update(_marker_binding(marker_before))
    journal.setdefault("events", []).append(attempt_event)
    journal["state"] = "NB_FORWARD_RECOVERY_INTENT"
    _journal_append(evidence_dir / "journal.json", journal)
    try:
        try:
            intent_journal_raw = (evidence_dir / "journal.json").read_bytes()
        except OSError as exc:
            raise RecoveryError("cannot read recovery INTENT journal") from exc
        source_snapshot, source_raw = read_json(source_snapshot_path)
        revalidate_snapshot, revalidate_raw = read_json(revalidation_snapshot_path)
        require(isinstance(source_snapshot, dict) and isinstance(revalidate_snapshot, dict),
                "recovery snapshots must be JSON objects", blocked=True)
        source_tables = _snapshot_tables(source_snapshot)
        revalidate_tables = _snapshot_tables(revalidate_snapshot)
        del source_tables, revalidate_tables
        require(source_snapshot["capture_finished_ns"] < revalidate_snapshot["capture_started_ns"],
                "recovery snapshots are not ordered and non-overlapping", blocked=True)
        require(revalidate_snapshot["nb_cfg_before"] >= source_snapshot["nb_cfg_after"],
                "NB cfg moved backwards between recovery snapshots", blocked=True)
        # The parsed forward capsule was validated before INTENT.  Re-read
        # only for an exact byte check; do not validate a newer parse and then
        # emit hashes for the older capsule.
        try:
            current_preflight_raw = preflight_path.read_bytes()
            current_transaction_raw = transaction_path.read_bytes()
        except OSError as exc:
            raise RecoveryBlocked("forward artifact disappeared after recovery INTENT") from exc
        require(current_preflight_raw == preflight_raw,
                "bound preflight changed after recovery INTENT", blocked=True)
        require(current_transaction_raw == transaction_raw,
                "bound forward transaction changed after recovery INTENT", blocked=True)
        require(isinstance(preflight, dict) and isinstance(transaction, list),
                "forward artifacts have invalid shapes", blocked=True)
        # Validate both outcomes independently.  A source state that is not
        # stable is BLOCKED even when the second snapshot looks clean.
        source_outcome, source_mapping = validate_state(
            source_snapshot, dict(preflight), transaction, owner, run_hex
        )
        second_outcome, second_mapping = validate_state(
            revalidate_snapshot, dict(preflight), transaction, owner, run_hex
        )
        require(source_outcome == second_outcome,
                "recovery outcome changed between stable snapshots", blocked=True)
        require(source_mapping == second_mapping,
                "BUILT UUID mapping changed between recovery snapshots", blocked=True)
        source_name = f"{ATTEMPT_PREFIX}{attempt}-source.json"
        revalidate_name = f"{ATTEMPT_PREFIX}{attempt}-revalidate.json"
        proof_name = f"{ATTEMPT_PREFIX}{attempt}-proof.json"
        proof = _recovery_proof(
            owner=owner,
            run_hex=run_hex,
            source_state=source_state,
            outcome=source_outcome,
            mapping=source_mapping,
            preflight_raw=preflight_raw,
            transaction_raw=transaction_raw,
            source_raw=source_raw,
            revalidate_raw=revalidate_raw,
            source_name=source_name,
            revalidate_name=revalidate_name,
            attempt=attempt,
            marker_identity=marker_before,
        )
        proof_raw = canonical(proof)
        source_artifact = evidence_dir / source_name
        revalidate_artifact = evidence_dir / revalidate_name
        proof_artifact = evidence_dir / proof_name
        _write_new(source_artifact, source_raw)
        _write_new(revalidate_artifact, revalidate_raw)
        _write_new(proof_artifact, proof_raw)
        _recovery_publish_recheck(
            evidence_dir=evidence_dir,
            preflight_path=preflight_path,
            preflight_raw=preflight_raw,
            transaction_path=transaction_path,
            transaction_raw=transaction_raw,
            source_snapshot_path=source_snapshot_path,
            source_raw=source_raw,
            revalidation_snapshot_path=revalidation_snapshot_path,
            revalidation_raw=revalidate_raw,
            source_artifact=source_artifact,
            revalidate_artifact=revalidate_artifact,
            proof_artifact=proof_artifact,
            proof_raw=proof_raw,
            expected_journal_raw=intent_journal_raw,
            phase="before",
            marker=marker,
            marker_identity=marker_before,
            owner=owner,
            run_hex=run_hex,
        )
        attempt_event["artifacts"] = [
            {"path": source_name, "sha256": sha256(source_raw)},
            {"path": revalidate_name, "sha256": sha256(revalidate_raw)},
            {"path": proof_name, "sha256": sha256(proof_raw)},
        ]
        attempt_event["outcome"] = source_outcome
        attempt_event["state"] = (
            "NB_FORWARD_RECOVERED_VERIFIED"
            if source_outcome == "BUILT"
            else "NB_FORWARD_RECOVERED_CLEAN"
        )
        attempt_event["finished_at_ns"] = time.time_ns()
        journal["state"] = attempt_event["state"]
        published_journal_raw = canonical(journal)
        _journal_append(evidence_dir / "journal.json", journal)
        published_proof = revalidate_proof(
            proof_artifact, evidence_dir, marker=marker
        )
        _recovery_publish_recheck(
            evidence_dir=evidence_dir,
            preflight_path=preflight_path,
            preflight_raw=preflight_raw,
            transaction_path=transaction_path,
            transaction_raw=transaction_raw,
            source_snapshot_path=source_snapshot_path,
            source_raw=source_raw,
            revalidation_snapshot_path=revalidation_snapshot_path,
            revalidation_raw=revalidate_raw,
            source_artifact=source_artifact,
            revalidate_artifact=revalidate_artifact,
            proof_artifact=proof_artifact,
            proof_raw=proof_raw,
            expected_journal_raw=published_journal_raw,
            phase="after",
            marker=marker,
            marker_identity=marker_before,
            owner=owner,
            run_hex=run_hex,
        )
        require(canonical(published_proof) == proof_raw,
                "published recovery proof changed before return", blocked=True)
        return published_proof
    except RecoveryError as exc:
        attempt_event["state"] = "NB_FORWARD_RECOVERY_BLOCKED"
        attempt_event["outcome"] = "BLOCKED"
        attempt_event["reason"] = str(exc)
        attempt_event["finished_at_ns"] = time.time_ns()
        journal["state"] = "NB_FORWARD_RECOVERY_BLOCKED"
        _journal_append(evidence_dir / "journal.json", journal)
        _same_marker(marker, marker_before, owner, run_hex)
        raise
    except BaseException:
        _same_marker(marker, marker_before, owner, run_hex)
        raise


def _revalidate_proof_capsule(
    proof_path: pathlib.Path,
    evidence_dir: pathlib.Path,
    *,
    marker: pathlib.Path | None = None,
) -> dict[str, Any]:
    """Revalidate a recovery proof from both bound snapshots before inverse use."""

    evidence_dir = evidence_dir.absolute()
    proof_path = proof_path.absolute()
    require(proof_path.parent == evidence_dir,
            "recovery proof is outside its evidence directory")
    proof_path = _recovery_artifact_path(evidence_dir, proof_path.name)
    proof, proof_raw = read_json(proof_path)
    require(isinstance(proof, dict) and proof.get("schema") == SCHEMA and
            proof.get("status") == "PASS" and proof.get("commit_outcome") == "UNKNOWN",
            "invalid forward-recovery proof")
    owner, run_hex = proof.get("owner"), proof.get("run_hex")
    require(isinstance(owner, str) and OWNER.fullmatch(owner) is not None and
            isinstance(run_hex, str) and owner == owner_for(run_hex),
            "invalid recovery owner/run")
    marker_before = _marker_identity(marker, owner, run_hex)
    require(proof.get("owner_sha256") == sha256(owner.encode("utf-8")) and
            proof.get("run_sha256") == sha256(run_hex.encode("utf-8")),
            "recovery owner/run hash binding is invalid")
    journal_path = evidence_dir / "journal.json"
    require(not journal_path.is_symlink() and journal_path.is_file(),
            "X05 journal is not a regular file")
    journal, journal_raw = read_json(journal_path)
    require(isinstance(journal, dict) and journal.get("schema") == JOURNAL_SCHEMA,
            "invalid X05 NB journal for proof revalidation")
    require(journal.get("owner") == owner and journal.get("run_hex") == run_hex and
            journal.get("evidence_dir") == str(evidence_dir.absolute()),
            "journal is bound to another X05 run or evidence directory")
    require(marker is not None or journal.get("marker") is None,
            "journal-bound X05 marker is required for proof revalidation")
    if marker is not None:
        require(journal.get("marker") == str(marker.absolute()),
                "journal is bound to another X05 marker")
    journal_events = journal.get("events")
    require(isinstance(journal_events, list), "invalid X05 NB journal events")
    require(proof.get("proof_sha256") == _proof_digest(proof),
            "recovery proof self-hash mismatch")
    marker_binding = _marker_binding(marker_before)
    for key, expected in marker_binding.items():
        require(proof.get(key) == expected,
                "recovery proof marker binding is invalid: " + key)
    proof_events = [
        artifact
        for event in journal_events
        if isinstance(event, dict) and event.get("kind") == "recovery-attempt"
        for artifact in (event.get("artifacts") if isinstance(event.get("artifacts"), list)
                         else [])
        if isinstance(artifact, dict) and artifact.get("path") == proof_path.name
    ]
    expected_state = (
        "NB_FORWARD_RECOVERED_VERIFIED"
        if proof.get("outcome") == "BUILT"
        else "NB_FORWARD_RECOVERED_CLEAN"
    )
    recovery_events = [
        event for event in journal_events
        if isinstance(event, dict) and event.get("kind") == "recovery-attempt"
    ]
    latest_recovery = recovery_events[-1] if recovery_events else {}
    latest_artifacts = latest_recovery.get("artifacts")
    require(recovery_events and latest_recovery.get("state") == expected_state and
            latest_recovery.get("owner") == owner and
            latest_recovery.get("run_hex") == run_hex and
            latest_recovery.get("attempt") == proof.get("attempt") and
            isinstance(latest_artifacts, list) and any(
                isinstance(artifact, dict) and artifact.get("path") == proof_path.name
                and artifact.get("sha256") == sha256(proof_raw)
                for artifact in latest_artifacts
            ),
            "recovery proof is not the latest journal attempt")
    for key, expected in marker_binding.items():
        require(latest_recovery.get(key) == expected,
                "journal recovery marker binding is invalid: " + key)
    require(len(proof_events) == 1 and proof_events[0].get("sha256") == sha256(proof_raw),
            "recovery proof is not bound by the journal")
    require(journal.get("state") == expected_state,
            "journal does not record the recovered proof state")
    preflight_path = _artifact_path(evidence_dir, "preflight.json")
    transaction_path = _artifact_path(evidence_dir, "forward-tx.json")
    preflight, preflight_raw = read_json(preflight_path)
    transaction, transaction_raw = read_json(transaction_path)
    require(_proof_digest(proof) == proof.get("proof_sha256"),
            "recovery proof hash mismatch")
    require(sha256(preflight_raw) == proof.get("preflight_sha256"),
            "bound preflight changed")
    require(sha256(transaction_raw) == proof.get("transaction_sha256"),
            "bound forward transaction changed")
    source_name, second_name = proof.get("source_snapshot"), proof.get("revalidation_snapshot")
    require(isinstance(source_name, str) and isinstance(second_name, str),
            "recovery proof snapshot bindings are missing")
    require(source_name.endswith("-source.json") and
            second_name.endswith("-revalidate.json"),
            "recovery proof snapshot bindings are invalid")
    source_path = _recovery_artifact_path(evidence_dir, source_name)
    second_path = _recovery_artifact_path(evidence_dir, second_name)
    source, source_raw = read_json(source_path)
    second, second_raw = read_json(second_path)
    require(isinstance(source, dict) and isinstance(second, dict),
            "bound recovery snapshots have invalid shapes")
    require(sha256(source_raw) == proof.get("snapshot_sha256") ==
            proof.get("source_snapshot_sha256"),
            "bound source snapshot changed")
    require(sha256(second_raw) == proof.get("revalidation_snapshot_sha256"),
            "bound revalidation snapshot changed")
    require(source["capture_finished_ns"] < second["capture_started_ns"],
            "bound recovery snapshots are no longer ordered")
    require(second.get("nb_cfg_before") >= source.get("nb_cfg_after"),
            "bound recovery snapshots move NB cfg backwards")
    source_outcome, source_mapping = validate_state(
        source, dict(preflight), transaction, owner, run_hex
    )
    second_outcome, second_mapping = validate_state(
        second, dict(preflight), transaction, owner, run_hex
    )
    require(source_outcome == proof.get("outcome") == second_outcome,
            "recovery proof outcome no longer holds")
    require(source_mapping == second_mapping == proof.get("inserted"),
            "recovery proof UUID mapping no longer holds")
    require(proof.get("outcome") in {"BUILT", "CLEAN"},
            "recovery proof has an unsupported outcome")
    _same_marker(marker, marker_before, owner, run_hex)
    return {
        "proof": proof,
        "proof_path": proof_path,
        "proof_raw": proof_raw,
        "journal_raw": journal_raw,
        "preflight_path": preflight_path,
        "preflight": preflight,
        "preflight_raw": preflight_raw,
        "transaction_path": transaction_path,
        "transaction": transaction,
        "transaction_raw": transaction_raw,
        "source_path": source_path,
        "source": source,
        "source_raw": source_raw,
        "second_path": second_path,
        "second": second,
        "second_raw": second_raw,
        "marker": marker_before,
    }


def revalidate_proof(
    proof_path: pathlib.Path,
    evidence_dir: pathlib.Path,
    *,
    marker: pathlib.Path | None = None,
) -> dict[str, Any]:
    """Revalidate and return the immutable proof view for ordinary callers."""
    return _revalidate_proof_capsule(proof_path, evidence_dir, marker=marker)["proof"]


def revalidate_built_for_inverse(
    proof_path: pathlib.Path,
    evidence_dir: pathlib.Path,
    *,
    marker: pathlib.Path | None = None,
) -> dict[str, str]:
    """Return recovered UUIDs for inverse construction after full revalidation.

    The caller receives a UUID map only for a revalidated ``BUILT`` proof.
    A ``CLEAN`` proof deliberately has no inverse input, and a normal
    ``p004-x05-nb-tx-result-v1`` receipt is never synthesized here.
    """

    capsule = _revalidate_proof_capsule(proof_path, evidence_dir, marker=marker)
    proof = capsule["proof"]
    require(proof.get("outcome") == "BUILT",
            "recovered CLEAN state cannot be used to build an inverse")
    inserted = proof.get("inserted")
    require(isinstance(inserted, dict) and set(inserted) ==
            {item["id"] for item in TX.plan()} and
            len(set(inserted.values())) == 34,
            "recovered BUILT proof has no bijective UUID map")
    return dict(inserted)


def _read_external_snapshot(path: pathlib.Path) -> tuple[dict[str, Any], bytes]:
    path = path.absolute()
    require(not path.is_symlink() and path.is_file(),
            "preinverse snapshot is not a regular file", blocked=True)
    try:
        require(stat.S_IMODE(path.stat().st_mode) & 0o077 == 0,
                "preinverse snapshot permissions are too broad", blocked=True)
    except OSError as exc:
        raise RecoveryBlocked("cannot stat preinverse snapshot") from exc
    value, raw = read_json(path)
    require(isinstance(value, dict), "preinverse snapshot is not an object", blocked=True)
    return value, raw


def _final_recheck_capsule(
    capsule: dict[str, Any],
    marker: pathlib.Path | None,
    preinverse_path: pathlib.Path,
    preinverse_raw: bytes,
) -> None:
    """Close the read/build window with hashes, journal, and marker checks."""
    for path, expected in (
        (capsule["proof_path"], capsule["proof_raw"]),
        (capsule["preflight_path"], capsule["preflight_raw"]),
        (capsule["transaction_path"], capsule["transaction_raw"]),
        (capsule["source_path"], capsule["source_raw"]),
        (capsule["second_path"], capsule["second_raw"]),
    ):
        try:
            current = path.read_bytes()
        except OSError as exc:
            raise RecoveryBlocked("bound recovery artifact disappeared") from exc
        require(current == expected, "bound recovery artifact changed before inverse return",
                blocked=True)
    journal_path = capsule["preflight_path"].parent / "journal.json"
    try:
        current_journal = journal_path.read_bytes()
    except OSError as exc:
        raise RecoveryBlocked("recovery journal disappeared before inverse return") from exc
    require(current_journal == capsule["journal_raw"],
            "recovery journal changed before inverse return", blocked=True)
    try:
        current_preinverse = preinverse_path.absolute().read_bytes()
    except OSError as exc:
        raise RecoveryBlocked("preinverse snapshot disappeared before inverse return") from exc
    require(current_preinverse == preinverse_raw,
            "preinverse snapshot changed before inverse return", blocked=True)
    proof = capsule["proof"]
    _same_marker(marker, capsule["marker"], proof["owner"], proof["run_hex"])


def build_recovered_inverse(
    proof_path: pathlib.Path,
    evidence_dir: pathlib.Path,
    preinverse_snapshot_path: pathlib.Path,
    *,
    marker: pathlib.Path | None = None,
) -> list[Any]:
    """Build the existing CAS inverse bridge from a revalidated BUILT proof.

    The preinverse snapshot is independently checked and must be later than
    the proof's bound revalidation snapshot.  The returned value is the raw
    ``OVN_Northbound`` transaction array; no ordinary forward-result receipt is
    manufactured.
    """

    capsule = _revalidate_proof_capsule(proof_path, evidence_dir, marker=marker)
    proof = capsule["proof"]
    require(proof.get("outcome") == "BUILT",
            "recovered CLEAN state cannot be used to build an inverse")
    inserted = proof.get("inserted")
    require(isinstance(inserted, dict) and set(inserted) ==
            {item["id"] for item in TX.plan()} and
            len(set(inserted.values())) == 34,
            "recovered BUILT proof has no bijective UUID map")
    preflight = capsule["preflight"]
    transaction = capsule["transaction"]
    preinverse, preinverse_raw = _read_external_snapshot(preinverse_snapshot_path)
    second = capsule["second"]
    require(isinstance(preflight, dict) and isinstance(transaction, list),
            "recovered inverse inputs are malformed")
    require(preinverse.get("capture_started_ns", 0) > second.get("capture_finished_ns", 0),
            "preinverse snapshot is not later than the recovered proof")
    require(preinverse.get("nb_cfg_before", -1) >= second.get("nb_cfg_after", 0),
            "preinverse NB cfg predates the recovered proof")
    outcome, current_mapping = validate_state(
        preinverse, dict(preflight), transaction, proof["owner"], proof["run_hex"]
    )
    require(outcome == "BUILT" and current_mapping == inserted,
            "preinverse snapshot no longer proves the recovered BUILT mapping",
            blocked=True)
    inverse = TX.build_inverse_with_uuids(
        preflight,
        inserted,
        preinverse,
        proof["owner"],
        proof["run_hex"],
        TX.plan(),
    )
    _final_recheck_capsule(capsule, marker, preinverse_snapshot_path, preinverse_raw)
    return inverse


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--recover", action="store_true")
    modes.add_argument("--revalidate", action="store_true")
    parser.add_argument("--run-hex", required=True)
    parser.add_argument("--evidence-dir", type=pathlib.Path, required=True)
    parser.add_argument("--source-snapshot", type=pathlib.Path)
    parser.add_argument("--revalidation-snapshot", type=pathlib.Path)
    parser.add_argument("--proof", type=pathlib.Path)
    parser.add_argument("--marker", type=pathlib.Path)
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.recover:
            require(args.source_snapshot is not None and args.revalidation_snapshot is not None,
                    "--recover requires --source-snapshot and --revalidation-snapshot")
            result = recover(
                args.evidence_dir,
                args.run_hex,
                args.source_snapshot,
                args.revalidation_snapshot,
                marker=args.marker,
            )
        else:
            require(args.proof is not None, "--revalidate requires --proof")
            result = revalidate_proof(args.proof, args.evidence_dir, marker=args.marker)
    except (RecoveryError, OSError, ValueError, KeyError, TypeError) as exc:
        print("X05 NB recovery FAIL: " + str(exc), file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
