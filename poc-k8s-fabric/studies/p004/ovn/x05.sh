#!/usr/bin/env bash
# P004-S002/X05: fixed dry-run and admitted one-shot coordinator entrypoint.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash studies/p004/ovn/x05.sh --dry-run|--execute

--dry-run validates local fixtures and the coordinator without lab effects.
--execute dispatches the fixed coordinator; it still refuses before admission
unless all reviewed production inputs and host gates pass.
EOF
}

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi
case "$1" in
  --dry-run|--execute) mode="$1" ;;
  *) usage >&2; exit 2 ;;
esac

fixture_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fixtures=(x05-client2.conf x05-chassis.conf x05-peer.conf x05-topology.md
  x05-execution-contract.md x05-cas.sh x05-cas-fixture.json
  x05-cas-selftest.sh x05-nb-plan.sh x05-nb-preflight.sh
  x05-nb-preflight-fixture.json x05-nb-preflight-selftest.sh
  x05-nb-full-snapshot.sh x05-nb-tx.py x05-nb-tx-selftest.sh
  x05-nb-postflight.py x05-nb-postflight-selftest.sh
  x05-runtime-plan.py x05-runtime-preflight.py x05-runtime-live.py
  x05-runtime-live-selftest.py x05-runtime-apply.py
  x05-runtime-apply-selftest.py x05-capture.py x05-capture-selftest.py
  x05-evaluator.py x05-nb-live.py x05-coordinator.py
  x05-coordinator-selftest.py
  frr-client.conf frr-gw1.conf frr-gw2.conf
  x05-gw1.conf x05-gw2.conf x05-gw1-add.conf x05-gw1-remove.conf
  x05-gw2-add.conf x05-gw2-remove.conf)

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

snapshot() {
  local file
  for file in x05.sh "${fixtures[@]}"; do
    printf '%s %s\n' "$file" "$(hash_file "${fixture_dir}/$file")"
  done
}

validate() {
  local file
  for file in x05.sh "${fixtures[@]}"; do
    [[ -f "${fixture_dir}/$file" && -r "${fixture_dir}/$file" ]] || {
      printf 'X05 FAIL: missing fixture %s\n' "$file" >&2
      exit 1
    }
  done
  grep -Fqx 'hostname dci-client-2' "${fixture_dir}/x05-client2.conf"
  grep -Fqx 'router bgp 201' "${fixture_dir}/x05-client2.conf"
  grep -Fqx 'router bgp 200' "${fixture_dir}/frr-client.conf"
  grep -Fqx '  network 10.0.0.0/16' "${fixture_dir}/x05-client2.conf"
  grep -Fq 'neighbor 169.254.254.1 remote-as 100' "${fixture_dir}/x05-client2.conf"
  grep -Fq 'neighbor 169.254.254.5 remote-as 100' "${fixture_dir}/x05-client2.conf"
  grep -Fqx ' vni 50200' "${fixture_dir}/x05-chassis.conf"
  grep -Fqx ' vni 50200' "${fixture_dir}/x05-peer.conf"
  grep -Fq '10.251.0.1/32' "${fixture_dir}/x05-peer.conf"
  grep -Fq 'LSP **real**' "${fixture_dir}/x05-topology.md"
  grep -Fq '/var/lock/labctl-dci-m03.lock' "${fixture_dir}/x05-execution-contract.md"
  grep -Fq 'ABSENT -> M03_ACTIVE -> INTENT -> BUILT' "${fixture_dir}/x05-execution-contract.md"
  grep -Fq '10.31.100.1/30' "${fixture_dir}/x05-execution-contract.md"
  grep -Fq '10.41.100.1/30' "${fixture_dir}/x05-execution-contract.md"
  grep -Fq 'ovsdb-client transact' "${fixture_dir}/x05-execution-contract.md"
  grep -Fq 'G7 |' "${fixture_dir}/x05-execution-contract.md"
  grep -Fq 'G8 |' "${fixture_dir}/x05-execution-contract.md"
  diff -u "${fixture_dir}/frr-gw1.conf" \
    <(sed '/^! X05 extension$/,$d' "${fixture_dir}/x05-gw1.conf")
  diff -u "${fixture_dir}/frr-gw2.conf" \
    <(sed '/^! X05 extension$/,$d' "${fixture_dir}/x05-gw2.conf")
  grep -Fqx 'router bgp 100 vrf ovnvrf300' "${fixture_dir}/x05-gw1.conf"
  grep -Fqx 'router bgp 100 vrf ovnvrf400' "${fixture_dir}/x05-gw2.conf"
  grep -Fqx ' neighbor 169.254.254.2 remote-as 201' "${fixture_dir}/x05-gw1.conf"
  grep -Fqx ' neighbor 169.254.254.6 remote-as 201' "${fixture_dir}/x05-gw2.conf"
  grep -Fqx 'router bgp 100 vrf ovnvrf300' "${fixture_dir}/x05-gw1-add.conf"
  grep -Fqx 'router bgp 100 vrf ovnvrf400' "${fixture_dir}/x05-gw2-add.conf"
  grep -Fqx 'no router bgp 100 vrf ovnvrf300' "${fixture_dir}/x05-gw1-remove.conf"
  grep -Fqx 'no router bgp 100 vrf ovnvrf400' "${fixture_dir}/x05-gw2-remove.conf"
  if grep -Eq '^(frr version|hostname |service |write memory|vtysh -b)' \
    "${fixture_dir}/x05-gw1-add.conf" "${fixture_dir}/x05-gw1-remove.conf" \
    "${fixture_dir}/x05-gw2-add.conf" "${fixture_dir}/x05-gw2-remove.conf"; then
    printf 'X05 FAIL: extension fixture contains a forbidden whole-config command\n' >&2
    exit 1
  fi
  bash -n "${fixture_dir}/x05-cas.sh"
  bash -n "${fixture_dir}/x05-nb-plan.sh"
  bash -n "${fixture_dir}/x05-nb-preflight.sh"
  bash -n "${fixture_dir}/x05-nb-preflight-selftest.sh"
  bash -n "${fixture_dir}/x05-nb-full-snapshot.sh"
  bash -n "${fixture_dir}/x05-nb-tx-selftest.sh"
  bash -n "${fixture_dir}/x05-nb-postflight-selftest.sh"
  bash "${fixture_dir}/x05-nb-plan.sh" --check >/dev/null
  bash "${fixture_dir}/x05-nb-preflight-selftest.sh" >/dev/null
  bash "${fixture_dir}/x05-nb-tx-selftest.sh" >/dev/null
  bash "${fixture_dir}/x05-nb-postflight-selftest.sh" >/dev/null
  PYTHONDONTWRITEBYTECODE=1 \
    python3 "${fixture_dir}/x05-runtime-plan.py" --check >/dev/null
  PYTHONDONTWRITEBYTECODE=1 \
    python3 "${fixture_dir}/x05-runtime-preflight.py" --selftest >/dev/null
  PYTHONDONTWRITEBYTECODE=1 \
    python3 "${fixture_dir}/x05-runtime-live-selftest.py" >/dev/null
  PYTHONDONTWRITEBYTECODE=1 \
    python3 "${fixture_dir}/x05-runtime-live.py" --dry-run \
    | jq -e '.status == "DISABLED" and .live_cli == false
      and .writes == 0 and .subprocesses == 0 and .resource_count == 43' >/dev/null
  PYTHONDONTWRITEBYTECODE=1 \
    python3 "${fixture_dir}/x05-coordinator.py" --dry-run \
    | jq -e '.status == "READY" and .writes == 0 and .subprocesses == 0
      and .capture_count == 5 and .source_count == 4
      and .window_count == 12 and .authorizes_mutation == false' >/dev/null
  PYTHONDONTWRITEBYTECODE=1 \
    python3 "${fixture_dir}/x05-coordinator-selftest.py" >/dev/null
  bash "${fixture_dir}/x05-cas.sh" --build "${fixture_dir}/x05-cas-fixture.json" \
    | jq -e 'length == 5 and .[0] == "OVN_Northbound"
      and (.[1].op == "wait" and .[2].op == "wait")
      and (.[3].op == "mutate" and .[4].op == "mutate")' >/dev/null
}

validate
if [[ "$mode" == --execute ]]; then
  exec /usr/bin/python3 "${fixture_dir}/x05-coordinator.py" --execute
fi

before="$(snapshot)"
printf 'mode=dry-run\n'
printf 'scope=local fixtures only; no lab state was read or changed\n'
printf 'client_a=dci-client-1 AS200 VLAN100/200\n'
printf 'client_b=dci-client-2 AS201 VLAN300/400\n'
printf 'same_p2p=169.254.254.0/30,169.254.254.4/30\n'
printf 'same_onprem=10.0.0.0/16\n'
printf 'same_vpc=192.168.100.0/24\n'
printf 'tenant_a=ovn-chassis-1 VRF300 VNI50100 sentinel:192.168.100.11\n'
printf 'tenant_b=ovn-chassis-2 VRF400 VNI50200 sentinel:192.168.100.12\n'
printf 'negative=move tenant B real LSP atomically to A datapath, then restore\n'
printf 'cas_builder=local JSON only; zero OVSDB connections\n'
printf 'nb_inventory=34 X05-owned NB rows plus M03 exceptions; local plan and inverse order validated\n'
printf 'nb_preflight=read-only checker fixture selftest PASS; live mode not invoked\n'
printf 'nb_tx=local forward/inverse 34-row atomic JSON generators, full-row guard and result selftest PASS; no OVSDB connection\n'
printf 'nb_postflight=local built/clean 34-row, A fingerprint and foreign-reference selftest PASS; no OVSDB connection\n'
printf 'runtime_inventory=43 non-NB resources, owner/before/parent/rollback locally checked; no Docker or network calls\n'
printf 'runtime_preflight=schema-only evidence check, never mutation authority; complete M03/OVS/FRR selftest PASS; live mode not invoked\n'
printf 'runtime_admission=session-bound PreparedAdmission/consume API and FD9 lifecycle fake-runner selftest PASS; standalone producer CLI disabled, coordinator owns handoff\n'
printf 'coordinator=fixed one-shot execute(prepared), 12 windows, semantic PCAP decoder, exact CAS inverse and G7/G8 ordering\n'
printf 'lock=/var/lock/labctl-dci-m03.lock (shared with M03 and labctl dci)\n'
printf 'state=ABSENT>M03_ACTIVE>INTENT>BUILT>BASELINE_PROVED>LEAK_PROVED>RESTORED>X05_CLEANED>ABSENT\n'
printf 'gates=G0 preflight; G0a M03 setup; G1 BGP; G2 simultaneous EVPN; G3 traffic; G4 captures; G5 leak; G6 restore; G7 X05 cleanup; G8 M03 baseline\n'
printf 'rollback=restore LSP; withdraw B routes; remove only X05-owned resources; verify M03; down M03; baseline verify and canaries\n'
printf 'required_missing=production admission inputs and all live host gates; actual X05 remains separately Go-controlled\n'
printf 'execute_status=READY_FOR_ADMISSION\n'
after="$(snapshot)"
[[ "$before" == "$after" ]] || {
  printf 'X05 FAIL: local fixture snapshot changed during dry-run\n' >&2
  exit 1
}
printf 'snapshot_sha256=%s\n' "$(printf '%s' "$before" | hash_file /dev/stdin)"
