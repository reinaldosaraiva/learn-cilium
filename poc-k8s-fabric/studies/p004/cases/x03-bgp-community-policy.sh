#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p004/cases/x03-bgp-community-policy.sh — Caso X03:
# Aproximação aberta de SGT via BGP standard communities por tenant:
#   - Tenant 'a' marcado com community 65000:101
#   - Tenant 'b' marcado com community 65000:102
#   - Política de entrada X03-ENFORCE-TENANT-A-IN no spine evpnfab-peer (bgp community-list standard)
#   - Controle positivo: prefixo 192.168.101.0/24 com 65000:101 aceito na RIB JSON e responde 5/5 pings
#   - Controle negativo: prefixo 192.168.101.0/24 remarcado com 65000:102 bloqueado na RIB JSON,
#     com >= 5 emissões na origem (dci-tenant-vm) e 0 pacotes entregues em ovnk-evpn-peer (rc=124)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN="${DRY_RUN:-${LABCTL_DRY_RUN:-0}}"
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

OVNK_PEER="ovnk-evpn-peer"
FAB_PEER="evpnfab-peer"
DCI_CHASSIS="ovn-chassis-1"

COMM_A="65000:101"
COMM_B="65000:102"
TEST_PFX="192.168.101.0/24"
TEST_IP="192.168.101.1"
OVNK_VM_A_IP="10.0.0.21"

x03_log() {
  printf '[x03] %s\n' "$*"
}

x03_die() {
  printf '[x03] ERRO: %s\n' "$*" >&2
  exit 1
}

if [[ "${DRY_RUN}" == "1" ]]; then
  printf 'DRY: ensure X01 topology is active (%s/x01-unified-tenant.sh)\n' "${SCRIPT_DIR}"
  printf 'DRY: verify BGP JSON RIB communities on %s: Tenant a routes carry %s, Tenant b routes carry %s\n' \
    "${FAB_PEER}" "${COMM_A}" "${COMM_B}"
  printf 'DRY: apply bgp community-list standard X03-COMM-TENANT-A (%s) + route-map X03-ENFORCE-TENANT-A-IN on %s\n' \
    "${COMM_A}" "${FAB_PEER}"
  printf 'DRY: positive control — advertise %s (%s) from %s with community %s -> assert present in JSON RIB + 5/5 pings from %s\n' \
    "${TEST_PFX}" "${TEST_IP}" "${OVNK_PEER}" "${COMM_A}" "${DCI_CHASSIS}"
  printf 'DRY: negative control — re-tag %s with Tenant b community %s -> assert withdrawn from JSON RIB + >= 5 source packets + 0 destination packets on %s\n' \
    "${TEST_PFX}" "${COMM_B}" "${OVNK_PEER}"
  printf 'DRY: cleanup %s test interface and restore %s route-map X03-TAG-TENANT-A\n' "${TEST_PFX}" "${FAB_PEER}"
  printf 'X03 DRY-RUN OK\n'
  exit 0
fi

cleanup_x03() {
  docker exec "${OVNK_PEER}" sh -c '
    vtysh \
      -c "configure terminal" \
      -c "router bgp 65000 vrf vrf-evpn-k03" \
      -c "address-family ipv4 unicast" \
      -c "no network 192.168.101.0/24" \
      -c "exit-address-family" \
      -c "exit" \
      -c "no route-map X03-OVNK-TENANT-A permit 5" \
      -c "no ip prefix-list X03-TEST-PFX seq 5 permit 192.168.101.0/24" \
      -c "end" >/dev/null 2>&1 || true
    vtysh -c "clear bgp vrf vrf-evpn-k03 169.254.101.5 soft out" >/dev/null 2>&1 || true
    ip link del lo-x03 2>/dev/null || true
    rm -f /tmp/x03-dst.log
  ' || true

  docker exec "${FAB_PEER}" sh -c '
    vtysh \
      -c "configure terminal" \
      -c "router bgp 65002 vrf vrf-tenant-a" \
      -c "address-family ipv4 unicast" \
      -c "neighbor 169.254.101.6 route-map X03-TAG-TENANT-A in" \
      -c "exit-address-family" \
      -c "exit" \
      -c "no route-map X03-ENFORCE-TENANT-A-IN" \
      -c "end" >/dev/null 2>&1 || true
    vtysh -c "clear bgp vrf vrf-tenant-a 169.254.101.6 soft in" >/dev/null 2>&1 || true
  ' || true

  docker exec "${DCI_CHASSIS}" rm -f /tmp/x03-src.pcap 2>/dev/null || true
}
trap cleanup_x03 EXIT

# 1. Garantir que a topologia X01 está ativa
if ! docker exec "${FAB_PEER}" ip link show vxlan-xf-10100 >/dev/null 2>&1; then
  x03_log "Topologia X01 ainda não ativa; executando x01-unified-tenant.sh up..."
  bash "${SCRIPT_DIR}/x01-unified-tenant.sh" up
fi

# 2. Aplicar política estrita de filtragem de entrada por community no spine evpnfab-peer
x03_log "Aplicando política BGP community-list X03-COMM-TENANT-A (${COMM_A}) e route-map X03-ENFORCE-TENANT-A-IN em ${FAB_PEER}..."
docker exec "${FAB_PEER}" vtysh \
  -c "configure terminal" \
  -c "bgp community-list standard X03-COMM-TENANT-A permit ${COMM_A}" \
  -c "bgp community-list standard X03-COMM-TENANT-B permit ${COMM_B}" \
  -c "route-map X03-ENFORCE-TENANT-A-IN permit 10" \
  -c "match community X03-COMM-TENANT-A" \
  -c "set community ${COMM_A} additive" \
  -c "exit" \
  -c "route-map X03-ENFORCE-TENANT-A-IN deny 20" \
  -c "exit" \
  -c "router bgp 65002 vrf vrf-tenant-a" \
  -c "address-family ipv4 unicast" \
  -c "neighbor 169.254.101.6 route-map X03-ENFORCE-TENANT-A-IN in" \
  -c "end" >/dev/null

docker exec "${FAB_PEER}" vtysh -c "clear bgp vrf vrf-tenant-a 169.254.101.6 soft in" >/dev/null

# 3. Verificar via JSON estruturado que as rotas do Tenant 'a' carregam 65000:101 e as do Tenant 'b' carregam 65000:102
x03_log "Inspecionando BGP EVPN / VRF JSON RIB em ${FAB_PEER} para comunidades ${COMM_A} (Tenant a) e ${COMM_B} (Tenant b)..."
docker exec "${FAB_PEER}" python3 -c "
import json, subprocess, sys

evpn_doc = json.loads(subprocess.check_output(['vtysh', '-c', 'show bgp l2vpn evpn route detail json'], text=True))
found_evpn_a = False
found_evpn_b = False
for rd_key, rd_val in evpn_doc.items():
    if not isinstance(rd_val, dict):
        continue
    for pfx_key, pfx_val in rd_val.items():
        if not isinstance(pfx_val, dict):
            continue
        for path_entry in pfx_val.get('paths', []):
            for p in (path_entry if isinstance(path_entry, list) else [path_entry]):
                if not isinstance(p, dict):
                    continue
                comm_str = (p.get('community') or {}).get('string', '')
                if '${COMM_A}' in comm_str:
                    found_evpn_a = True
                if '${COMM_B}' in comm_str:
                    found_evpn_b = True

if not found_evpn_a:
    print('Community ${COMM_A} not found in parsed EVPN detail JSON', file=sys.stderr)
    sys.exit(1)
if not found_evpn_b:
    print('Community ${COMM_B} not found in parsed EVPN detail JSON', file=sys.stderr)
    sys.exit(2)

vrf_a = json.loads(subprocess.check_output(['vtysh', '-c', 'show bgp vrf vrf-tenant-a ipv4 unicast 10.0.0.0/24 json'], text=True))
paths_a = vrf_a.get('paths', [])
if not any('${COMM_A}' in (p.get('community') or {}).get('string', '') for p in paths_a if isinstance(p, dict)):
    print('10.0.0.0/24 in vrf-tenant-a missing community ${COMM_A}', file=sys.stderr)
    sys.exit(3)

vrf_b = json.loads(subprocess.check_output(['vtysh', '-c', 'show bgp vrf vrf-tenant-b ipv4 unicast 10.0.0.0/24 json'], text=True))
paths_b = vrf_b.get('paths', [])
if not any('${COMM_B}' in (p.get('community') or {}).get('string', '') for p in paths_b if isinstance(p, dict)):
    print('10.0.0.0/24 in vrf-tenant-b missing community ${COMM_B}', file=sys.stderr)
    sys.exit(4)
" || x03_die "Verificação JSON de communities BGP (${COMM_A} / ${COMM_B}) em ${FAB_PEER} falhou"

# 4. Controle Positivo: anunciar prefixo de teste 192.168.101.0/24 (192.168.101.1/24) com community 65000:101
x03_log "Controle positivo: anunciando ${TEST_PFX} (${TEST_IP}) em ${OVNK_PEER} com community ${COMM_A}..."
docker exec "${OVNK_PEER}" sh -c "
  set -eu
  ip link del lo-x03 2>/dev/null || true
  ip link add lo-x03 type dummy
  ip link set lo-x03 master vrf-evpn-k03 up
  ip addr replace ${TEST_IP}/24 dev lo-x03
  vtysh \
    -c 'configure terminal' \
    -c 'router bgp 65000 vrf vrf-evpn-k03' \
    -c 'address-family ipv4 unicast' \
    -c 'network ${TEST_PFX}' \
    -c 'end' >/dev/null
  vtysh -c 'clear bgp vrf vrf-evpn-k03 169.254.101.5 soft out' >/dev/null
"

pos_ok=0
for _ in $(seq 1 25); do
  if docker exec "${FAB_PEER}" python3 -c "
import json, subprocess, sys
rib = json.loads(subprocess.check_output(['vtysh', '-c', 'show ip route vrf vrf-tenant-a json'], text=True))
sys.exit(0 if '${TEST_PFX}' in rib else 1)
" 2>/dev/null && \
     docker exec "${DCI_CHASSIS}" python3 -c "
import json, subprocess, sys
rib = json.loads(subprocess.check_output(['vtysh', '--vty_socket', '/run/frr/x01', '-c', 'show ip route vrf ovnvrf-tenant json'], text=True))
sys.exit(0 if '${TEST_PFX}' in rib else 1)
" 2>/dev/null; then
    pos_ok=1
    break
  fi
  sleep 1
done
[[ "${pos_ok}" -eq 1 ]] || x03_die "Controle positivo falhou: ${TEST_PFX} com community ${COMM_A} não foi instalado na RIB"

docker exec "${DCI_CHASSIS}" ip netns exec dci-tenant-vm ping -c 5 -W 2 "${TEST_IP}" >/dev/null \
  || x03_die "Controle positivo de dataplane (dci-tenant-vm -> ${TEST_IP}) falhou"

# 5. Controle Negativo: remarcar 192.168.101.0/24 com community do Tenant 'b' (65000:102)
x03_log "Controle negativo: remarcando ${TEST_PFX} com community ${COMM_B} (Tenant b) e verificando bloqueio no route-map X03-ENFORCE-TENANT-A-IN..."
docker exec "${OVNK_PEER}" sh -c "
  set -eu
  vtysh \
    -c 'configure terminal' \
    -c 'ip prefix-list X03-TEST-PFX seq 5 permit ${TEST_PFX}' \
    -c 'route-map X03-OVNK-TENANT-A permit 5' \
    -c 'match ip address prefix-list X03-TEST-PFX' \
    -c 'set community ${COMM_B}' \
    -c 'end' >/dev/null
  vtysh -c 'clear bgp vrf vrf-evpn-k03 169.254.101.5 soft out' >/dev/null
"
docker exec "${FAB_PEER}" vtysh -c "clear bgp vrf vrf-tenant-a 169.254.101.6 soft in" >/dev/null

neg_ok=0
for _ in $(seq 1 25); do
  if docker exec "${FAB_PEER}" python3 -c "
import json, subprocess, sys
rib = json.loads(subprocess.check_output(['vtysh', '-c', 'show ip route vrf vrf-tenant-a json'], text=True))
sys.exit(0 if ('${TEST_PFX}' not in rib and '10.0.0.0/24' in rib) else 1)
" 2>/dev/null && \
     docker exec "${DCI_CHASSIS}" python3 -c "
import json, subprocess, sys
rib = json.loads(subprocess.check_output(['vtysh', '--vty_socket', '/run/frr/x01', '-c', 'show ip route vrf ovnvrf-tenant json'], text=True))
sys.exit(0 if ('${TEST_PFX}' not in rib and '10.0.0.0/24' in rib) else 1)
" 2>/dev/null; then
    neg_ok=1
    break
  fi
  sleep 1
done
[[ "${neg_ok}" -eq 1 ]] || x03_die "Controle negativo falhou: ${TEST_PFX} com community ${COMM_B} não foi removido da RIB de vrf-tenant-a / ovnvrf-tenant"

# Verificar bloqueio também no plano de dados (N2: >= 5 emissões em dci-tenant-vm:dci-tenant-vm e 0 pacotes em ovnk-evpn-peer:vxlan-xf-10100, rc=124)
docker exec "${OVNK_PEER}" sh -c "
  rm -f /tmp/x03-dst.log
  timeout 8 tcpdump -ni vxlan-xf-10100 -c 1 'icmp and dst host ${TEST_IP}' >/tmp/x03-dst.log 2>&1
" >/dev/null 2>&1 &
pid_dst=$!
sleep 1

src_emitted="$(docker exec "${DCI_CHASSIS}" ip netns exec dci-tenant-vm sh -c "
  rm -f /tmp/x03-src.pcap
  timeout 6 tcpdump -ni dci-tenant-vm -w /tmp/x03-src.pcap 'icmp[icmptype] == icmp-echo and dst host ${TEST_IP}' >/dev/null 2>&1 &
  cap_pid=\$!
  sleep 1
  ping -c 5 -i 0.2 -W 1 ${TEST_IP} >/dev/null 2>&1 || true
  wait \"\${cap_pid}\" || true
  tcpdump -nr /tmp/x03-src.pcap 2>/dev/null | wc -l | tr -d ' '
")"

rc_dst=0
wait "${pid_dst}" || rc_dst=$?
dst_log="$(docker exec "${OVNK_PEER}" cat /tmp/x03-dst.log 2>/dev/null || true)"
if [[ "${src_emitted:-0}" -lt 5 ]]; then
  x03_die "Emissão insuficiente na origem dci-tenant-vm durante controle negativo: ${src_emitted:-0}/5 pacotes"
fi
if [[ "${rc_dst}" -ne 124 ]] || ! grep -q "0 packets captured" <<<"${dst_log}"; then
  x03_die "Pacotes para ${TEST_IP} alcançaram ${OVNK_PEER} apesar do filtro de community (rc=${rc_dst}, log=${dst_log})"
fi

# 6. Limpar prefixo de teste, restaurar route-map e revalidar que 10.0.0.0/24 (community 65000:101) segue íntegro (5/5)
cleanup_x03
trap - EXIT

docker exec "${DCI_CHASSIS}" ip netns exec dci-tenant-vm ping -c 5 -W 2 "${OVNK_VM_A_IP}" >/dev/null \
  || x03_die "Conectividade do Tenant a (${OVNK_VM_A_IP}) falhou após limpeza de X03"

printf 'X03 PASS: BGP standard communities por tenant (%s Tenant a, %s Tenant b) validadas em JSON; controle positivo %s PERMIT (5/5 pings) e controle negativo com %s DENY (rota removida da RIB JSON, %s emissões na origem e 0 pacotes entregues, rc=%s).\n' \
  "${COMM_A}" "${COMM_B}" "${TEST_PFX}" "${COMM_B}" "${src_emitted}" "${rc_dst}"
