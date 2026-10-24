#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p004/cases/x06-hub-overlap-admission.sh — Caso X06 (Gate G05):
# Caso negativo: tentativa de anexar 2ª VPC (ls-mgc-tenant-dup) com CIDR sobreposto (192.168.100.0/24 ou 192.168.100.128/25)
# ao mesmo hub/router MGC (lr-mgc-tenant em ovn-central-az1).
# Prova a recusa na admissão (RC=22, HUB_CIDR_OVERLAP_DENIED) sem criar recurso no OVN Northbound DB,
# além de controle positivo de admissão (--check-only) para prefixo disjunto (192.168.200.0/24, RC=0).

set -euo pipefail

DRY_RUN="${DRY_RUN:-${LABCTL_DRY_RUN:-0}}"
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

MGC_CENTRAL="ovn-central-az1"
HUB_ROUTER="lr-mgc-tenant"

x06_log() {
  printf '[x06] %s\n' "$*"
}

x06_die() {
  printf '[x06] ERRO: %s\n' "$*" >&2
  exit 1
}

if [[ "${DRY_RUN}" == "1" ]]; then
  printf 'DRY: snapshot Logical_Switch and Logical_Router_Port tables in %s via ovn-nbctl --format=json\n' "${MGC_CENTRAL}"
  printf 'DRY: attempt admission of ls-mgc-tenant-dup (192.168.100.1/24) onto %s -> expect RC=22 (HUB_CIDR_OVERLAP_DENIED)\n' "${HUB_ROUTER}"
  printf 'DRY: attempt admission of ls-mgc-tenant-sub (192.168.100.129/25) onto %s -> expect RC=22 (HUB_CIDR_OVERLAP_DENIED)\n' "${HUB_ROUTER}"
  printf 'DRY: validate disjoint VPC candidate ls-mgc-tenant-200 (192.168.200.1/24) onto %s (--check-only) -> expect RC=0\n' "${HUB_ROUTER}"
  printf 'DRY: verify OVN NB DB snapshot is unchanged and ls-mgc-tenant-dup count == 0\n'
  printf 'X06 DRY-RUN OK\n'
  exit 0
fi

x06_admit_vpc() {
  local hub_router="$1"
  local ls_name="$2"
  local lrp_name="$3"
  local gw_cidr="$4"
  local mode="${5:-apply}"

  docker exec -i "${MGC_CENTRAL}" python3 - "${hub_router}" "${ls_name}" "${lrp_name}" "${gw_cidr}" "${mode}" <<'PY'
import ipaddress
import json
import subprocess
import sys

hub_router, ls_name, lrp_name, gw_cidr, mode = sys.argv[1:6]
cand_iface = ipaddress.ip_interface(gw_cidr)
cand_net = cand_iface.network

lr_json = json.loads(subprocess.check_output(
    ["ovn-nbctl", "--format=json", "find", "Logical_Router", f"name={hub_router}"],
    text=True,
))
lr_headings = lr_json.get("headings", [])
lr_rows = lr_json.get("data", [])
if not lr_rows:
    print(json.dumps({"verdict": "HUB_NOT_FOUND", "hub": hub_router}))
    sys.exit(2)

ports_idx = lr_headings.index("ports")
port_uuids = set()
for row in lr_rows:
    cell = row[ports_idx]
    if isinstance(cell, list) and len(cell) == 2 and cell[0] == "set":
        for item in cell[1]:
            if isinstance(item, list) and len(item) == 2 and item[0] == "uuid":
                port_uuids.add(item[1])
    elif isinstance(cell, list) and len(cell) == 2 and cell[0] == "uuid":
        port_uuids.add(cell[1])

lrp_json = json.loads(subprocess.check_output(
    ["ovn-nbctl", "--format=json", "list", "Logical_Router_Port"],
    text=True,
))
h = lrp_json.get("headings", [])
u_idx = h.index("_uuid")
n_idx = h.index("name")
net_idx = h.index("networks")

conflicts = []
existing_ports = []
for row in lrp_json.get("data", []):
    u_cell = row[u_idx]
    uuid_val = u_cell[1] if isinstance(u_cell, list) and len(u_cell) == 2 else str(u_cell)
    if uuid_val not in port_uuids:
        continue
    pname = row[n_idx]
    net_cell = row[net_idx]
    nets = []
    if isinstance(net_cell, list) and len(net_cell) == 2 and net_cell[0] == "set":
        nets = list(net_cell[1])
    elif isinstance(net_cell, str):
        nets = [net_cell]
    for net_str in nets:
        try:
            ex_iface = ipaddress.ip_interface(net_str)
        except ValueError:
            continue
        if ex_iface.version != cand_iface.version:
            continue
        existing_ports.append({"port": pname, "cidr": str(ex_iface.network)})
        if cand_net.overlaps(ex_iface.network):
            conflicts.append({
                "existing_port": pname,
                "existing_network": str(ex_iface.network),
                "candidate_switch": ls_name,
                "candidate_port": lrp_name,
                "candidate_network": str(cand_net),
            })

if conflicts:
    print(json.dumps({
        "verdict": "HUB_CIDR_OVERLAP_DENIED",
        "hub": hub_router,
        "candidate_switch": ls_name,
        "candidate_network": str(cand_net),
        "conflicts": conflicts,
    }))
    sys.exit(22)

if mode == "--check-only":
    print(json.dumps({
        "verdict": "HUB_CIDR_ADMISSION_PERMITTED_DRY",
        "hub": hub_router,
        "candidate_switch": ls_name,
        "candidate_network": str(cand_net),
        "existing_ports": existing_ports,
    }))
    sys.exit(0)
PY
}

x06_snapshot_nb() {
  docker exec "${MGC_CENTRAL}" python3 -c '
import json, subprocess
ls = json.loads(subprocess.check_output(["ovn-nbctl", "--format=json", "list", "Logical_Switch"], text=True))
lrp = json.loads(subprocess.check_output(["ovn-nbctl", "--format=json", "list", "Logical_Router_Port"], text=True))
ls_h = ls.get("headings", [])
lrp_h = lrp.get("headings", [])
ls_rows = sorted((str(r[ls_h.index("_uuid")]), str(r[ls_h.index("name")])) for r in ls.get("data", []))
lrp_rows = sorted((str(r[lrp_h.index("_uuid")]), str(r[lrp_h.index("name")]), str(r[lrp_h.index("networks")])) for r in lrp.get("data", []))
print(json.dumps({"ls": ls_rows, "lrp": lrp_rows}, sort_keys=True))
'
}

x06_log "Capturando snapshot inicial do OVN Northbound DB em ${MGC_CENTRAL}..."
snap_before="$(x06_snapshot_nb)"

# 1. Caso Negativo 1: tentativa de anexar ls-mgc-tenant-dup com CIDR idêntico (192.168.100.1/24) em lr-mgc-tenant
x06_log "Testando admissão de ls-mgc-tenant-dup (192.168.100.1/24) no hub ${HUB_ROUTER}..."
rc_dup=0
out_dup="$(x06_admit_vpc "${HUB_ROUTER}" "ls-mgc-tenant-dup" "lrp-mgc-tenant-dup" "192.168.100.1/24")" || rc_dup=$?
if [[ "${rc_dup}" -ne 22 ]]; then
  x06_die "Admissão de CIDR duplicado 192.168.100.1/24 deveria falhar com RC=22, mas retornou RC=${rc_dup} (${out_dup})"
fi
grep -q '"verdict": "HUB_CIDR_OVERLAP_DENIED"' <<<"${out_dup}" \
  || x06_die "Saída JSON inesperada para CIDR duplicado: ${out_dup}"
x06_log "Recusa de CIDR idêntico confirmada (RC=${rc_dup}): ${out_dup}"

# 2. Caso Negativo 2: tentativa de anexar ls-mgc-tenant-sub com sub-rede contida (192.168.100.129/25) em lr-mgc-tenant
x06_log "Testando admissão de ls-mgc-tenant-sub (192.168.100.129/25) no hub ${HUB_ROUTER}..."
rc_sub=0
out_sub="$(x06_admit_vpc "${HUB_ROUTER}" "ls-mgc-tenant-sub" "lrp-mgc-tenant-sub" "192.168.100.129/25")" || rc_sub=$?
if [[ "${rc_sub}" -ne 22 ]]; then
  x06_die "Admissão de sub-rede sobreposta 192.168.100.129/25 deveria falhar com RC=22, mas retornou RC=${rc_sub} (${out_sub})"
fi
grep -q '"verdict": "HUB_CIDR_OVERLAP_DENIED"' <<<"${out_sub}" \
  || x06_die "Saída JSON inesperada para sub-rede sobreposta: ${out_sub}"
x06_log "Recusa de sub-rede contida confirmada (RC=${rc_sub}): ${out_sub}"

# 3. Controle Positivo (--check-only): prefixo disjunto 192.168.200.1/24 aprovado sem mutar o NB DB
x06_log "Testando controle positivo (--check-only) para prefixo disjunto 192.168.200.1/24..."
out_pos="$(x06_admit_vpc "${HUB_ROUTER}" "ls-mgc-tenant-200" "lrp-mgc-tenant-200" "192.168.200.1/24" "--check-only")" \
  || x06_die "Controle positivo para prefixo disjunto 192.168.200.1/24 falhou"
grep -q '"verdict": "HUB_CIDR_ADMISSION_PERMITTED_DRY"' <<<"${out_pos}" \
  || x06_die "Saída JSON inesperada no controle positivo: ${out_pos}"

# 4. Verificar que zero recursos foram criados no OVN NB DB
snap_after="$(x06_snapshot_nb)"
if [[ "${snap_before}" != "${snap_after}" ]]; then
  x06_die "OVN NB DB sofreu mutação indevida durante o teste de admissão X06"
fi

dup_count="$(docker exec "${MGC_CENTRAL}" python3 -c '
import json, subprocess
doc = json.loads(subprocess.check_output(["ovn-nbctl", "--format=json", "find", "Logical_Switch", "name=ls-mgc-tenant-dup"], text=True))
print(len(doc.get("data", [])))
')"
if [[ "${dup_count}" -ne 0 ]]; then
  x06_die "Logical_Switch ls-mgc-tenant-dup foi criado indevidamente no OVN NB DB"
fi

printf 'X06 PASS (Gate G05): tentativa de anexar 2ª VPC (ls-mgc-tenant-dup 192.168.100.0/24 e ls-mgc-tenant-sub 192.168.100.128/25) ao hub %s recusada na admissão com RC=%s/%s (HUB_CIDR_OVERLAP_DENIED); 0 recursos criados no OVN NB DB (snapshot idêntico).\n' \
  "${HUB_ROUTER}" "${rc_dup}" "${rc_sub}"
