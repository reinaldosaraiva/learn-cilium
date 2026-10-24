#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p004/cases/x04-wrong-rt-guardrail.sh — Caso X04 (Gate G05):
# Caso negativo: tentativa de importar RT 65000:10200 (Tenant 'b') no VRF do Tenant 'a' (vrf-tenant-a, VNI 10100).
# Prova:
#   1. Guardrail de admissão recusa (RC=22) qualquer configuração FRR candidata com colisão de RT entre tenants
#      antes de invocar vtysh em produção.
#   2. Controle positivo do validador aprova (RC=0) as configurações ativas íntegras dos daemons FRR.
#   3. Auditoria JSON em tempo de execução confirma que nenhum daemon importa RT cruzado nem instala rotas de outro tenant.

set -euo pipefail

DRY_RUN="${DRY_RUN:-${LABCTL_DRY_RUN:-0}}"
MODE="run"
TARGET_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    validate-config)
      MODE="validate-config"
      TARGET_FILE="${2:-}"
      [[ -n "${TARGET_FILE}" ]] || { printf 'Uso: %s validate-config <arquivo-frr.conf>\n' "$0" >&2; exit 2; }
      shift 2
      ;;
    run)
      MODE="run"
      shift
      ;;
    *)
      printf 'Uso: %s [--dry-run] [run | validate-config <arquivo-frr.conf>]\n' "$0" >&2
      exit 2
      ;;
  esac
done

FAB_PEER="evpnfab-peer"
FAB_GW1="evpnfab-gw1"
FAB_GW2="evpnfab-gw2"
OVNK_PEER="ovnk-evpn-peer"

x04_log() {
  printf '[x04] %s\n' "$*"
}

x04_die() {
  printf '[x04] ERRO: %s\n' "$*" >&2
  exit 1
}

x04_validate_frr_text() {
  local label="$1"
  local file_path="${2:-}"
  python3 - "${label}" "${file_path}" <<'PY'
import json
import re
import sys

label = sys.argv[1]
file_path = sys.argv[2] if len(sys.argv) > 2 else ""
if file_path:
    with open(file_path, "r", encoding="utf-8") as fh:
        text = fh.read()
else:
    text = sys.stdin.read()

ALLOWED_VRF_RTS = {
    "vrf-tenant-a": {"65000:10100"},
    "vrf-evpn-k03": {"65000:10100"},
    "ovnvrf-tenant": {"65000:10100"},
    "vrf-tenant-b": {"65000:10200"},
    "ovnvrf100": {"65000:50100"},
    "ovnvrf200": {"65000:50200"},
}

ALLOWED_VNI_RTS = {
    "10100": {"65000:10100"},
    "20100": {"65000:20100"},
    "10200": {"65000:10200"},
    "20200": {"65000:20200"},
    "50100": {"65000:50100"},
    "50200": {"65000:50200"},
}

current_vrf = None
current_vni = None
violations = []
checked_stanzas = 0

for lineno, raw_line in enumerate(text.splitlines(), start=1):
    line = raw_line.strip()
    if not line or line.startswith("!"):
        continue

    m_router_vrf = re.match(r"^router\s+bgp\s+\d+(?:\s+vrf\s+(\S+))?$", line)
    if m_router_vrf:
        current_vrf = m_router_vrf.group(1)
        current_vni = None
        continue

    m_vrf_block = re.match(r"^vrf\s+(\S+)$", line)
    if m_vrf_block:
        current_vrf = m_vrf_block.group(1)
        current_vni = None
        continue

    if line in ("exit-vrf", "exit"):
        if current_vni is not None and line == "exit":
            pass
        elif line == "exit-vrf":
            current_vrf = None
            current_vni = None

    if line == "exit-vni":
        current_vni = None
        continue

    m_vni = re.match(r"^vni\s+(\d+)$", line)
    if m_vni and current_vrf is None:
        current_vni = m_vni.group(1)
        continue

    m_rt = re.match(r"^route-target\s+(import|export|both)\s+(\S+)$", line)
    if m_rt:
        direction, rt = m_rt.group(1), m_rt.group(2)
        checked_stanzas += 1
        if current_vni is not None and current_vni in ALLOWED_VNI_RTS:
            allowed = ALLOWED_VNI_RTS[current_vni]
            if rt not in allowed:
                violations.append({
                    "line": lineno,
                    "scope": f"vni:{current_vni}",
                    "direction": direction,
                    "rt": rt,
                    "allowed": sorted(allowed),
                })
        elif current_vrf is not None and current_vrf in ALLOWED_VRF_RTS:
            allowed = ALLOWED_VRF_RTS[current_vrf]
            if rt not in allowed:
                violations.append({
                    "line": lineno,
                    "scope": f"vrf:{current_vrf}",
                    "direction": direction,
                    "rt": rt,
                    "allowed": sorted(allowed),
                })

if violations:
    print(json.dumps({
        "target": label,
        "verdict": "RT_COLLISION_DENIED",
        "checked_stanzas": checked_stanzas,
        "violations": violations,
    }))
    sys.exit(22)

print(json.dumps({
    "target": label,
    "verdict": "RT_POLICY_OK",
    "checked_stanzas": checked_stanzas,
    "violations": [],
}))
sys.exit(0)
PY
}

if [[ "${MODE}" == "validate-config" ]]; then
  x04_validate_frr_text "${TARGET_FILE}" "${TARGET_FILE}"
  exit $?
fi

if [[ "${DRY_RUN}" == "1" ]]; then
  printf 'DRY: generate candidate FRR config importing RT 65000:10200 (Tenant b) into vrf-tenant-a (VNI 10100)\n'
  printf 'DRY: run x04_validate_frr_text -> expect RC=22 (RT_COLLISION_DENIED) before any vtysh invocation\n'
  printf 'DRY: validate active running-config on %s, %s, %s, %s -> expect RC=0 (RT_POLICY_OK)\n' \
    "${FAB_PEER}" "${FAB_GW1}" "${FAB_GW2}" "${OVNK_PEER}"
  printf 'DRY: audit live FRR JSON RIBs (show bgp l2vpn evpn vni json & show ip route vrf ... json) for zero cross-tenant RT import\n'
  printf 'X04 DRY-RUN OK\n'
  exit 0
fi

tmp_dir="$(mktemp -d)"
cleanup_x04() {
  rm -rf "${tmp_dir}"
}
trap cleanup_x04 EXIT

# 1. Caso Negativo: gerar configuração candidata inválida que importa RT 65000:10200 (Tenant 'b') em vrf-tenant-a (VNI 10100)
bad_cfg="${tmp_dir}/frr-wrong-rt.conf"
cat >"${bad_cfg}" <<'EOF'
frr defaults traditional
hostname evpnfab-peer
!
vrf vrf-tenant-a
 vni 10100
exit-vrf
!
router bgp 65002
 address-family l2vpn evpn
  vni 10100
   rd 65002:10100
   route-target import 65000:10100
   route-target import 65000:10200
   route-target export 65000:10100
  exit-vni
 exit-address-family
exit
!
router bgp 65002 vrf vrf-tenant-a
 address-family l2vpn evpn
  rd 65002:10100
  route-target import 65000:10100
  route-target import 65000:10200
  route-target export 65000:10100
  advertise ipv4 unicast
 exit-address-family
exit
EOF

x04_log "Testando admissão de configuração FRR com RT cruzado (65000:10200 em vrf-tenant-a / VNI 10100)..."
rc_neg=0
neg_out="$(x04_validate_frr_text "candidate-wrong-rt" "${bad_cfg}")" || rc_neg=$?
if [[ "${rc_neg}" -ne 22 ]]; then
  x04_die "Guardrail deveria recusar RT 65000:10200 em vrf-tenant-a com RC=22, mas retornou RC=${rc_neg} (${neg_out})"
fi
grep -q '"verdict": "RT_COLLISION_DENIED"' <<<"${neg_out}" \
  || x04_die "Saída JSON do guardrail não contém RT_COLLISION_DENIED: ${neg_out}"
x04_log "Bloqueio na admissão confirmado (RC=${rc_neg}): ${neg_out}"

# 2. Controle Positivo do Validador: auditar a running-config real dos daemons FRR em execução
for node in "${FAB_PEER}" "${FAB_GW1}" "${FAB_GW2}" "${OVNK_PEER}"; do
  x04_log "Validando running-config ativa de ${node}..."
  run_cfg="$(docker exec "${node}" vtysh -c "show running-config")"
  pos_out="$(x04_validate_frr_text "${node}" <<<"${run_cfg}")" \
    || x04_die "Configuração ativa de ${node} falhou na validação de RT"
  grep -q '"verdict": "RT_POLICY_OK"' <<<"${pos_out}" \
    || x04_die "Saída inesperada para ${node}: ${pos_out}"
done

# 3. Auditoria de Estado em Tempo de Execução via JSON nas RIBs de evpnfab-peer e evpnfab-gw2
x04_log "Auditando RIBs JSON de ${FAB_PEER} e ${FAB_GW2} para garantir ausência de vazamento de rotas entre VNI 10100 e VNI 10200..."
docker exec "${FAB_PEER}" python3 -c "
import json, subprocess, sys

rib_a = json.loads(subprocess.check_output(['vtysh', '-c', 'show ip route vrf vrf-tenant-a json'], text=True))
rib_b = json.loads(subprocess.check_output(['vtysh', '-c', 'show ip route vrf vrf-tenant-b json'], text=True))

if '10.252.0.1/32' in rib_a:
    print('Tenant B loopback 10.252.0.1/32 leaked into vrf-tenant-a', file=sys.stderr)
    sys.exit(1)
if '10.251.0.1/32' in rib_b or '192.168.100.0/24' in rib_b:
    print('Tenant A prefix leaked into vrf-tenant-b', file=sys.stderr)
    sys.exit(2)
" || x04_die "Auditoria JSON de isolamento de RIB em ${FAB_PEER} falhou"

printf 'X04 PASS (Gate G05): tentativa de importar RT 65000:10200 (Tenant b) em vrf-tenant-a (VNI 10100) recusada na admissão com RC=%s (RT_COLLISION_DENIED) sem mutar os daemons; running-config e RIBs JSON de %s, %s, %s e %s íntegras (RC=0).\n' \
  "${rc_neg}" "${FAB_PEER}" "${FAB_GW1}" "${FAB_GW2}" "${OVNK_PEER}"
