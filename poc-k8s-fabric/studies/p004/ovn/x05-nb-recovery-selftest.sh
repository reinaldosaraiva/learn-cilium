#!/usr/bin/env bash
# Synthetic, local-only X05 forward-recovery checks.  No OVSDB or lab access.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$here" <<'PY'
import copy
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile


here = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("recovery", here / "x05-nb-recovery.py")
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)
owner = "labctl-x05-a1b2c3"
run_hex = "a1b2c3"
tables = tuple(sorted(recovery.SNAPSHOT_TABLES))


def save(path, value):
    path.write_bytes(json.dumps(value, sort_keys=True, separators=(",", ":")).encode() + b"\n")
    path.chmod(0o600)


def fixture_bundle(root, *, state="NB_FORWARD_AMBIGUOUS"):
    evidence = root / "evidence"
    evidence.mkdir(mode=0o700)
    marker = root / "marker"
    marker.write_text("token=" + owner + "\n", encoding="utf-8")
    marker.chmod(0o600)
    preflight_result = subprocess.run(
        ["bash", str(here / "x05-nb-preflight.sh"), "--fixture",
         str(here / "x05-nb-preflight-fixture.json")],
        check=True, capture_output=True, text=True,
    )
    preflight = json.loads(preflight_result.stdout)
    objects = recovery.TX.plan()
    transaction = recovery.TX.build(preflight, owner, run_hex, objects)
    inserts = [op for op in transaction[1:] if op["op"] == "insert"]
    inserted = {
        item["id"]: "00000000-0000-4000-8000-%012x" % (100 + index)
        for index, item in enumerate(objects)
    }
    named = {
        operation["uuid-name"]: inserted[item["id"]]
        for item, operation in zip(objects, inserts)
    }

    def resolve(value):
        if isinstance(value, list) and len(value) == 2 and value[0] == "named-uuid":
            return ["uuid", named[value[1]]]
        if isinstance(value, list):
            return [resolve(item) for item in value]
        if isinstance(value, dict):
            return {key: resolve(item) for key, item in value.items()}
        return value

    snapshot_tables = {table: [] for table in tables}
    a = preflight["a_fingerprint"]
    snapshot_tables["Logical_Switch"].append({
        "_uuid": a["ls_uuid"], "name": "ls-mgc-tenant",
        "external_ids": ["map", []],
        "ports": ["set", [["uuid", uid] for uid in a["ls_ports"] +
                            [inserted["Logical_Switch_Port:x05-tenant-a-vm"]]]],
    })
    snapshot_tables["Logical_Router"].append({
        "_uuid": a["lr_uuid"], "name": "lr-mgc-tenant",
        "external_ids": ["map", []],
        "ports": ["set", [["uuid", uid] for uid in a["lr_ports"]]],
        "static_routes": ["set", []],
    })
    snapshot_tables["Logical_Router_Port"].append({
        "_uuid": a["lrp_uuid"], "name": "lrp-mgc-tenant",
        "external_ids": ["map", []], "gateway_chassis": ["set", []],
    })
    for item, operation in zip(objects, inserts):
        row = {"_uuid": inserted[item["id"]], **resolve(operation["row"])}
        if item["table"] == "Logical_Router_Port":
            row.setdefault("gateway_chassis", ["set", []])
        snapshot_tables[item["table"]].append(row)
    built = {
        "schema": "p004-x05-nb-full-snapshot-v1",
        "capture_started_ns": 100,
        "capture_finished_ns": 200,
        "nb_cfg_before": 42,
        "nb_cfg_after": 42,
        "tables": snapshot_tables,
    }
    clean = copy.deepcopy(built)
    owned = set(inserted.values())
    for table in clean["tables"]:
        clean["tables"][table] = [
            row for row in clean["tables"][table]
            if row["_uuid"] not in owned
        ]
    clean["tables"]["Logical_Switch"][0]["ports"][1].remove(
        ["uuid", inserted["Logical_Switch_Port:x05-tenant-a-vm"]]
    )
    clean["capture_started_ns"] = 300
    clean["capture_finished_ns"] = 400
    save(evidence / "preflight.json", preflight)
    save(evidence / "forward-tx.json", transaction)
    save(evidence / "forward-result.raw.json", {"result": []})
    artifact_events = []
    for stage, name in (
        ("preflight", "preflight.json"),
        ("forward_tx", "forward-tx.json"),
        ("forward_result", "forward-result.raw.json"),
    ):
        raw = (evidence / name).read_bytes()
        artifact_events.append({"kind": "artifact", "artifact": stage,
                                "path": name, "sha256": recovery.sha256(raw)})
    artifact_events.append({"kind": "mutation-prepared", "phase": "forward",
                            "owner": owner, "run_hex": run_hex,
                            "transaction_sha256": recovery.sha256(recovery.canonical(transaction))})
    journal = {
        "schema": "p004-x05-nb-live-journal-v1", "owner": owner,
        "run_hex": run_hex, "evidence_dir": str(evidence),
        "marker": str(marker), "state": state, "events": artifact_events,
    }
    save(evidence / "journal.json", journal)
    return evidence, marker, built, clean


def expect_blocked(call):
    try:
        call()
    except recovery.RecoveryError:
        return
    raise AssertionError("expected BLOCKED recovery")


with tempfile.TemporaryDirectory(prefix="x05-recovery-selftest-") as temporary:
    root = pathlib.Path(temporary)
    evidence, marker, built, clean = fixture_bundle(root)
    source = root / "built-source.json"
    second = root / "built-second.json"
    save(source, built)
    built["capture_started_ns"] = 300
    built["capture_finished_ns"] = 400
    save(second, built)
    proof = recovery.recover(evidence, run_hex, source, second, marker=marker)
    assert proof["schema"] == "p004-x05-nb-forward-recovery-v1"
    assert proof["commit_outcome"] == "UNKNOWN"
    assert proof["outcome"] == "BUILT"
    assert len(proof["inserted"]) == 34
    assert recovery.revalidate_proof(
        evidence / "recovery-attempt-1-proof.json", evidence, marker=marker
    )["outcome"] == "BUILT"
    assert len(recovery.revalidate_built_for_inverse(
        evidence / "recovery-attempt-1-proof.json", evidence, marker=marker
    )) == 34
    preinverse = root / "preinverse.json"
    built["capture_started_ns"] = 500
    built["capture_finished_ns"] = 600
    save(preinverse, built)
    inverse = recovery.build_recovered_inverse(
        evidence / "recovery-attempt-1-proof.json", evidence, preinverse,
        marker=marker,
    )
    assert inverse[0] == "OVN_Northbound"
    assert sum(operation.get("op") == "delete" for operation in inverse[1:]) == 34

    # The inverse bridge keeps the validated proof capsule and performs a
    # final byte/marker check after transaction construction.  A mutation in
    # that window must block the inverse instead of returning stale deletes.
    for target in ("preinverse", "forward-tx", "marker"):
        with tempfile.TemporaryDirectory(prefix="x05-recovery-toctou-") as toctou_dir:
            toctou_root = pathlib.Path(toctou_dir)
            toctou_evidence, toctou_marker, toctou_built, _ = fixture_bundle(
                toctou_root
            )
            toctou_source = toctou_root / "source.json"
            toctou_second = toctou_root / "second.json"
            toctou_preinverse = toctou_root / "preinverse.json"
            save(toctou_source, toctou_built)
            toctou_built["capture_started_ns"] = 300
            toctou_built["capture_finished_ns"] = 400
            save(toctou_second, toctou_built)
            toctou_built["capture_started_ns"] = 500
            toctou_built["capture_finished_ns"] = 600
            save(toctou_preinverse, toctou_built)
            toctou_proof = recovery.recover(
                toctou_evidence, run_hex, toctou_source, toctou_second,
                marker=toctou_marker,
            )
            original_builder = recovery.TX.build_inverse_with_uuids

            def mutate_after_build(*args, **kwargs):
                result = original_builder(*args, **kwargs)
                if target == "preinverse":
                    toctou_preinverse.write_bytes(toctou_preinverse.read_bytes() + b" ")
                elif target == "forward-tx":
                    tx_path = toctou_evidence / "forward-tx.json"
                    tx_path.write_bytes(tx_path.read_bytes() + b" ")
                else:
                    toctou_marker.write_bytes(
                        toctou_marker.read_bytes() + b"state=BUILT\n"
                    )
                return result

            recovery.TX.build_inverse_with_uuids = mutate_after_build
            try:
                expect_blocked(lambda: recovery.build_recovered_inverse(
                    toctou_evidence / toctou_proof["source_snapshot"].replace(
                        "-source.json", "-proof.json"
                    ),
                    toctou_evidence,
                    toctou_preinverse,
                    marker=toctou_marker,
                ))
            finally:
                recovery.TX.build_inverse_with_uuids = original_builder

    assert marker.read_text(encoding="utf-8") == "token=" + owner + "\n"
    journal = json.loads((evidence / "journal.json").read_text())
    assert journal["state"] == "NB_FORWARD_RECOVERED_VERIFIED"
    assert [event["state"] for event in journal["events"]
            if event.get("kind") == "recovery-attempt"] == [
                "NB_FORWARD_RECOVERED_VERIFIED"
            ]

    # All three forward mutation states are recoverable, including an INTENT
    # left by a crash before the OVSDB client returned.
    for state in ("NB_FORWARD_INTENT", "NB_FORWARD_AMBIGUOUS", "NB_FORWARD_COMMITTED"):
        with tempfile.TemporaryDirectory(prefix="x05-recovery-state-") as state_dir:
            state_root = pathlib.Path(state_dir)
            state_evidence, state_marker, state_built, _ = fixture_bundle(
                state_root, state=state
            )
            state_source = state_root / "built-source.json"
            state_second = state_root / "built-second.json"
            save(state_source, state_built)
            state_built["capture_started_ns"] = 300
            state_built["capture_finished_ns"] = 400
            save(state_second, state_built)
            assert recovery.recover(
                state_evidence, run_hex, state_source, state_second, marker=state_marker
            )["outcome"] == "BUILT"

    # A crash immediately after the recovery INTENT journal append leaves no
    # proof files.  The retry reconciles that event and allocates attempt 2.
    with tempfile.TemporaryDirectory(prefix="x05-recovery-intent-retry-") as retry_dir:
        retry_root = pathlib.Path(retry_dir)
        retry_evidence, retry_marker, retry_built, _ = fixture_bundle(
            retry_root, state="NB_FORWARD_RECOVERY_INTENT"
        )
        retry_journal_path = retry_evidence / "journal.json"
        retry_journal = json.loads(retry_journal_path.read_text())
        retry_journal["events"].append({
            "kind": "recovery-attempt", "attempt": 1,
            "source_state": "NB_FORWARD_AMBIGUOUS",
            "state": "NB_FORWARD_RECOVERY_INTENT", "owner": owner,
            "run_hex": run_hex, "started_at_ns": 1, "artifacts": [],
        })
        save(retry_journal_path, retry_journal)
        retry_source = retry_root / "source.json"
        retry_second = retry_root / "second.json"
        save(retry_source, retry_built)
        retry_built["capture_started_ns"] = 300
        retry_built["capture_finished_ns"] = 400
        save(retry_second, retry_built)
        retry_proof = recovery.recover(
            retry_evidence, run_hex, retry_source, retry_second, marker=retry_marker
        )
        assert retry_proof["attempt"] == 2
        retry_document = json.loads(retry_journal_path.read_text())
        retry_attempts = [event for event in retry_document["events"]
                          if event.get("kind") == "recovery-attempt"]
    assert [event["state"] for event in retry_attempts] == [
        "NB_FORWARD_RECOVERY_RECONCILED", "NB_FORWARD_RECOVERED_VERIFIED"
    ]

    # A forward artifact changed immediately after the recovery INTENT append
    # must block before the proof can be published with stale hashes.
    for target in ("preflight", "forward-tx"):
        with tempfile.TemporaryDirectory(prefix="x05-recovery-intent-tamper-") as tamper_dir:
            tamper_root = pathlib.Path(tamper_dir)
            tamper_evidence, tamper_marker, tamper_built, _ = fixture_bundle(tamper_root)
            tamper_source = tamper_root / "source.json"
            tamper_second = tamper_root / "second.json"
            save(tamper_source, tamper_built)
            tamper_built["capture_started_ns"] = 300
            tamper_built["capture_finished_ns"] = 400
            save(tamper_second, tamper_built)
            original_append = recovery._journal_append
            mutated = {"value": False}

            def append_then_mutate(path, journal):
                original_append(path, journal)
                if (not mutated["value"] and
                        journal.get("state") == "NB_FORWARD_RECOVERY_INTENT"):
                    artifact_path = tamper_evidence / (target + ".json")
                    artifact_path.write_bytes(artifact_path.read_bytes() + b" ")
                    mutated["value"] = True

            recovery._journal_append = append_then_mutate
            try:
                expect_blocked(lambda: recovery.recover(
                    tamper_evidence, run_hex, tamper_source, tamper_second,
                    marker=tamper_marker,
                ))
            finally:
                recovery._journal_append = original_append
            assert mutated["value"]
            tamper_journal = json.loads((tamper_evidence / "journal.json").read_text())
            assert tamper_journal["state"] == "NB_FORWARD_RECOVERY_BLOCKED"

    # The final recovered-state append is a publication boundary.  Mutating
    # any bound input after the pre-publication recheck, but before the append
    # itself, must prevent recover() from returning success.  Exercise both
    # outcomes and the original, copied, proof, journal-bound, and marker
    # inputs that participate in publication.
    publication_targets = (
        "preflight",
        "forward-tx",
        "source-input",
        "revalidation-input",
        "source-copy",
        "revalidation-copy",
        "proof",
        "marker",
    )
    for expected_outcome in ("BUILT", "CLEAN"):
        expected_state = (
            "NB_FORWARD_RECOVERED_VERIFIED"
            if expected_outcome == "BUILT"
            else "NB_FORWARD_RECOVERED_CLEAN"
        )
        for target in publication_targets:
            with tempfile.TemporaryDirectory(
                prefix="x05-recovery-publication-tamper-"
            ) as publication_dir:
                publication_root = pathlib.Path(publication_dir)
                (
                    publication_evidence,
                    publication_marker,
                    publication_built,
                    publication_clean,
                ) = fixture_bundle(publication_root)
                publication_snapshot = copy.deepcopy(
                    publication_built
                    if expected_outcome == "BUILT"
                    else publication_clean
                )
                publication_snapshot["capture_started_ns"] = 1000
                publication_snapshot["capture_finished_ns"] = 1100
                publication_source = publication_root / "source.json"
                save(publication_source, publication_snapshot)
                publication_second_snapshot = copy.deepcopy(publication_snapshot)
                publication_second_snapshot["capture_started_ns"] = 1200
                publication_second_snapshot["capture_finished_ns"] = 1300
                publication_second = publication_root / "second.json"
                save(publication_second, publication_second_snapshot)
                original_append = recovery._journal_append
                original_marker = publication_marker.read_bytes()
                mutated = {"value": False}

                def mutate_before_recovered_append(path, journal):
                    if not mutated["value"] and journal.get("state") == expected_state:
                        target_paths = {
                            "preflight": publication_evidence / "preflight.json",
                            "forward-tx": publication_evidence / "forward-tx.json",
                            "source-input": publication_source,
                            "revalidation-input": publication_second,
                            "source-copy": publication_evidence
                            / "recovery-attempt-1-source.json",
                            "revalidation-copy": publication_evidence
                            / "recovery-attempt-1-revalidate.json",
                            "proof": publication_evidence
                            / "recovery-attempt-1-proof.json",
                        }
                        if target == "marker":
                            publication_marker.write_bytes(
                                publication_marker.read_bytes() + b"state=INTENT\n"
                            )
                        else:
                            target_path = target_paths[target]
                            target_path.write_bytes(target_path.read_bytes() + b" ")
                        mutated["value"] = True
                    original_append(path, journal)

                recovery._journal_append = mutate_before_recovered_append
                try:
                    expect_blocked(lambda: recovery.recover(
                        publication_evidence,
                        run_hex,
                        publication_source,
                        publication_second,
                        marker=publication_marker,
                    ))
                finally:
                    recovery._journal_append = original_append
                assert mutated["value"], (expected_outcome, target)
                publication_journal = json.loads(
                    (publication_evidence / "journal.json").read_text()
                )
                assert publication_journal["state"] == "NB_FORWARD_RECOVERY_BLOCKED"
                publication_attempts = [
                    event for event in publication_journal["events"]
                    if event.get("kind") == "recovery-attempt"
                ]
                assert publication_attempts[-1]["state"] == "NB_FORWARD_RECOVERY_BLOCKED"
                assert publication_attempts[-1]["outcome"] == "BLOCKED"
                assert publication_marker.is_file()
                if target != "marker":
                    assert publication_marker.read_bytes() == original_marker
                publication_proof = (
                    publication_evidence / "recovery-attempt-1-proof.json"
                )
                expect_blocked(lambda: recovery.revalidate_proof(
                    publication_proof,
                    publication_evidence,
                    marker=publication_marker,
                ))
                if expected_outcome == "BUILT":
                    expect_blocked(lambda: recovery.revalidate_built_for_inverse(
                        publication_proof,
                        publication_evidence,
                        marker=publication_marker,
                    ))

    # A process death after the recovered-state bytes reach the journal can
    # leave that state durable.  The proof consumer must still reject the
    # changed evidence, so a stale VERIFIED record cannot authorize inverse
    # construction after restart.
    with tempfile.TemporaryDirectory(prefix="x05-recovery-publication-crash-") as crash_dir:
        crash_root = pathlib.Path(crash_dir)
        crash_evidence, crash_marker, crash_built, _ = fixture_bundle(crash_root)
        crash_source = crash_root / "source.json"
        crash_second = crash_root / "second.json"
        save(crash_source, crash_built)
        crash_built["capture_started_ns"] = 300
        crash_built["capture_finished_ns"] = 400
        save(crash_second, crash_built)
        original_append = recovery._journal_append
        original_marker = crash_marker.read_bytes()

        class SimulatedPublicationCrash(BaseException):
            pass

        def mutate_append_then_crash(path, journal):
            if journal.get("state") == "NB_FORWARD_RECOVERED_VERIFIED":
                copied_source = crash_evidence / "recovery-attempt-1-source.json"
                copied_source.write_bytes(copied_source.read_bytes() + b" ")
                original_append(path, journal)
                raise SimulatedPublicationCrash
            original_append(path, journal)

        recovery._journal_append = mutate_append_then_crash
        try:
            try:
                recovery.recover(
                    crash_evidence,
                    run_hex,
                    crash_source,
                    crash_second,
                    marker=crash_marker,
                )
            except SimulatedPublicationCrash:
                pass
            else:
                raise AssertionError("simulated publication crash was not raised")
        finally:
            recovery._journal_append = original_append
        crash_journal = json.loads((crash_evidence / "journal.json").read_text())
        assert crash_journal["state"] == "NB_FORWARD_RECOVERED_VERIFIED"
        assert crash_marker.read_bytes() == original_marker
        crash_proof = crash_evidence / "recovery-attempt-1-proof.json"
        expect_blocked(lambda: recovery.revalidate_proof(
            crash_proof, crash_evidence, marker=crash_marker,
        ))
        expect_blocked(lambda: recovery.revalidate_built_for_inverse(
            crash_proof, crash_evidence, marker=crash_marker,
        ))

    # A byte-stable marker with a foreign owner, run, or state is not a valid
    # invocation binding.
    for marker_text in (
        "token=labctl-x05-deadbe\n",
        "token=" + owner + "\nowner=labctl-x05-deadbe\n",
        "token=" + owner + "\nrun_hex=deadbe\n",
        "token=" + owner + "\nstate=FOREIGN\n",
    ):
        with tempfile.TemporaryDirectory(prefix="x05-recovery-marker-") as marker_dir:
            marker_root = pathlib.Path(marker_dir)
            marker_evidence, marker_path, marker_built, _ = fixture_bundle(marker_root)
            marker_path.write_text(marker_text, encoding="utf-8")
            marker_source = marker_root / "source.json"
            marker_second = marker_root / "second.json"
            save(marker_source, marker_built)
            marker_built["capture_started_ns"] = 300
            marker_built["capture_finished_ns"] = 400
            save(marker_second, marker_built)
            expect_blocked(lambda: recovery.recover(
                marker_evidence, run_hex, marker_source, marker_second,
                marker=marker_path,
            ))

    # A stable CLEAN pair proves rollback completed and cannot be used as an
    # inverse input because it has no owned UUID mapping.
    with tempfile.TemporaryDirectory(prefix="x05-recovery-clean-") as clean_dir:
        clean_root = pathlib.Path(clean_dir)
        clean_evidence, clean_marker, _, clean_snapshot = fixture_bundle(clean_root)
        clean_source = clean_root / "clean-source.json"
        clean_second = clean_root / "clean-second.json"
        save(clean_source, clean_snapshot)
        clean_snapshot["capture_started_ns"] = 500
        clean_snapshot["capture_finished_ns"] = 600
        save(clean_second, clean_snapshot)
        clean_proof = recovery.recover(
            clean_evidence, run_hex, clean_source, clean_second, marker=clean_marker
        )
        assert clean_proof["outcome"] == "CLEAN"
        assert "inserted" not in clean_proof
        assert recovery.revalidate_proof(
            clean_evidence / "recovery-attempt-1-proof.json", clean_evidence,
            marker=clean_marker,
        )["outcome"] == "CLEAN"
        expect_blocked(lambda: recovery.revalidate_built_for_inverse(
            clean_evidence / "recovery-attempt-1-proof.json", clean_evidence,
            marker=clean_marker,
        ))

    # Partial, foreign, reference, name, parent, and populated-column drift
    # all fail closed.  Each mutation is tested against a fresh bundle.
    cases = []
    partial = copy.deepcopy(built)
    partial["tables"]["Logical_Switch_Port"].pop()
    cases.append(partial)
    extra = copy.deepcopy(built)
    extra["tables"]["NAT"].append({
        "_uuid": "00000000-0000-4000-8000-000000009999",
        "external_ids": ["map", [["x05-owner", owner]]],
        "gateway_port": ["set", []],
    })
    cases.append(extra)
    foreign = copy.deepcopy(built)
    foreign["tables"]["Logical_Switch_Port"][-1]["external_ids"] = [
        "map", [["x05-owner", "labctl-x05-deadbe"]]
    ]
    cases.append(foreign)
    reference = copy.deepcopy(built)
    reference["tables"]["Port_Group"].append({
        "_uuid": "00000000-0000-4000-8000-000000009998",
        "external_ids": ["map", []],
        "name": "foreign-pg",
        "ports": ["set", [["uuid", "00000000-0000-4000-8000-000000000065"]]],
    })
    cases.append(reference)
    name_drift = copy.deepcopy(built)
    name_drift["tables"]["Logical_Switch"][-1]["name"] = "x05-foreign"
    cases.append(name_drift)
    parent_drift = copy.deepcopy(built)
    parent_drift["tables"]["Logical_Switch"][1]["ports"] = ["set", []]
    cases.append(parent_drift)
    column_drift = copy.deepcopy(built)
    column_drift["tables"]["Logical_Router"][-1]["unexpected"] = "populated"
    cases.append(column_drift)
    for index, bad_snapshot in enumerate(cases):
        with tempfile.TemporaryDirectory(prefix="x05-recovery-bad-") as bad_dir:
            bad_root = pathlib.Path(bad_dir)
            bad_evidence, bad_marker, _, _ = fixture_bundle(bad_root)
            bad_source = bad_root / "bad-source.json"
            bad_second = bad_root / "bad-second.json"
            bad_snapshot["capture_started_ns"] = 700 + index * 10
            bad_snapshot["capture_finished_ns"] = 701 + index * 10
            later = copy.deepcopy(bad_snapshot)
            later["capture_started_ns"] += 10
            later["capture_finished_ns"] += 10
            save(bad_source, bad_snapshot)
            save(bad_second, later)
            expect_blocked(lambda: recovery.recover(
                bad_evidence, run_hex, bad_source, bad_second, marker=bad_marker
            ))

    with tempfile.TemporaryDirectory(prefix="x05-recovery-unstable-") as unstable_dir:
        unstable_root = pathlib.Path(unstable_dir)
        unstable_evidence, unstable_marker, unstable_built, _ = fixture_bundle(unstable_root)
        unstable_built["nb_cfg_after"] += 1
        first = unstable_root / "first.json"
        later = unstable_root / "later.json"
        save(first, unstable_built)
        save(later, unstable_built)
        expect_blocked(lambda: recovery.recover(
            unstable_evidence, run_hex, first, later, marker=unstable_marker
        ))
        unstable_journal = json.loads(
            (unstable_evidence / "journal.json").read_text()
        )
        assert unstable_journal["state"] == "NB_FORWARD_RECOVERY_BLOCKED"
        assert [event["state"] for event in unstable_journal["events"]
                if event.get("kind") == "recovery-attempt"] == [
                    "NB_FORWARD_RECOVERY_BLOCKED"
                ]

    # Forward artifact tampering is rejected before a recovery attempt can
    # supersede the original journal binding.
    with tempfile.TemporaryDirectory(prefix="x05-recovery-artifact-") as artifact_dir:
        artifact_root = pathlib.Path(artifact_dir)
        artifact_evidence, artifact_marker, artifact_built, _ = fixture_bundle(
            artifact_root
        )
        artifact_source = artifact_root / "source.json"
        artifact_second = artifact_root / "second.json"
        save(artifact_source, artifact_built)
        artifact_built["capture_started_ns"] = 300
        artifact_built["capture_finished_ns"] = 400
        save(artifact_second, artifact_built)
        tx_path = artifact_evidence / "forward-tx.json"
        tx_path.write_bytes(tx_path.read_bytes() + b" ")
        expect_blocked(lambda: recovery.recover(
            artifact_evidence, run_hex, artifact_source, artifact_second,
            marker=artifact_marker,
        ))

    # A copied immutable recovery snapshot is also bound by the recovery
    # journal and proof hashes.
    with tempfile.TemporaryDirectory(prefix="x05-recovery-snapshot-tamper-") as snapshot_dir:
        snapshot_root = pathlib.Path(snapshot_dir)
        snapshot_evidence, snapshot_marker, snapshot_built, _ = fixture_bundle(
            snapshot_root
        )
        snapshot_source = snapshot_root / "source.json"
        snapshot_second = snapshot_root / "second.json"
        save(snapshot_source, snapshot_built)
        snapshot_built["capture_started_ns"] = 300
        snapshot_built["capture_finished_ns"] = 400
        save(snapshot_second, snapshot_built)
        snapshot_proof = recovery.recover(
            snapshot_evidence, run_hex, snapshot_source, snapshot_second,
            marker=snapshot_marker,
        )
        snapshot_proof_path = snapshot_evidence / "recovery-attempt-1-proof.json"
        snapshot_path = snapshot_evidence / snapshot_proof["source_snapshot"]
        snapshot_path.write_bytes(snapshot_path.read_bytes() + b" ")
        expect_blocked(lambda: recovery.revalidate_proof(
            snapshot_proof_path, snapshot_evidence, marker=snapshot_marker,
        ))

    # Tampering with an immutable proof is detected before it can be used by
    # the inverse bridge.
    proof_path = evidence / "recovery-attempt-1-proof.json"
    proof_path.write_bytes(proof_path.read_bytes() + b" ")
    expect_blocked(lambda: recovery.revalidate_proof(proof_path, evidence, marker=marker))

print("X05 NB recovery selftest PASS: built/clean recovery, publication race/crash, drift guards, proof tamper")
PY
