#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p004/cases/x02-cross-plane-isolation.sh — Caso X02 (Gate G05):
# Isolamento cross-plane com CIDR sobreposto (10.0.0.0/24):
# Tenant 'b' (L3VNI 10200 no fabric em evpnfab-client:ns-tenant-b e UDN tenant-b no OVN-K em probe-b, ambos 10.0.0.0/24)
# não alcança nenhum endpoint do Tenant 'a' unificado (L3VNI 10100: 10.0.0.21, 192.168.100.10, 10.0.200.1),
# com controle positivo prévio em ambos os tenants, >= 15 emissões na origem por plano e 0% recepção em tcpdump nos 3 planos.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN="${DRY_RUN:-${LABCTL_DRY_RUN:-0}}"
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

OVNK_KUBECONFIG="${OVNK_KUBECONFIG:-/root/.kube/ovnk.config}"
OVNK_CONTEXT="${OVNK_CONTEXT:-kind-ovnk}"
OVNK_PEER="ovnk-evpn-peer"
FAB_CENTRAL="evpnfab-central"
FAB_PEER="evpnfab-peer"
FAB_GW2="evpnfab-gw2"
FAB_CLIENT="evpnfab-client"
DCI_CHASSIS="ovn-chassis-1"

DCI_VPC_IP="192.168.100.10"
DCI_ONPREM_IP="10.0.200.1"
OVNK_VM_A_IP="10.0.0.21"
TENANT_B_IP="10.0.0.12"
TENANT_B_FAB_LO="10.252.0.1"

x02_log() {
  printf '[x02] %s\n' "$*"
}

x02_die() {
  printf '[x02] ERRO: %s\n' "$*" >&2
  exit 1
}

x02_kctl() {
  if [[ -f "${OVNK_KUBECONFIG}" ]]; then
    kubectl --kubeconfig "${OVNK_KUBECONFIG}" --context "${OVNK_CONTEXT}" "$@"
  else
    kubectl --context "${OVNK_CONTEXT}" "$@"
  fi
}

if [[ "${DRY_RUN}" == "1" ]]; then
  printf 'DRY: ensure X01 unified tenant-a topology is active (%s/x01-unified-tenant.sh)\n' "${SCRIPT_DIR}"
  printf 'DRY: verify positive control in Tenant b: vtysh show ip route vrf vrf-tenant-b json (L3VNI 10200)\n'
  printf 'DRY: verify 5/5 intra-tenant pings in evpn-fabric (%s:ns-tenant-b %s -> %s) and ovnk (probe-b -> vm-b %s)\n' \
    "${FAB_CLIENT}" "${TENANT_B_IP}" "${TENANT_B_FAB_LO}" "${TENANT_B_IP}"
  printf 'DRY: start tcpdump destination captures on %s:br-vxlan-10100, %s:brevpn.100, %s:dci-tenant-vm-p\n' \
    "${FAB_PEER}" "${OVNK_PEER}" "${DCI_CHASSIS}"
  printf 'DRY: emit 5 ICMP Echo Requests per target (%s, %s, %s) from Tenant b in %s (ns-tenant-b) and ovnk (probe-b) with source pcap capture\n' \
    "${OVNK_VM_A_IP}" "${DCI_VPC_IP}" "${DCI_ONPREM_IP}" "${FAB_CLIENT}"
  printf 'DRY: assert >= 15 packets emitted per source plane and 0 packets captured (rc=124) on all Tenant a planes\n'
  printf 'X02 DRY-RUN OK\n'
  exit 0
fi

cleanup_x02() {
  docker exec "${FAB_CENTRAL}" sh -c "
    ovn-nbctl lr-route-del lr-tenant-b ${OVNK_VM_A_IP}/32 169.254.102.2 2>/dev/null || true
    ovn-nbctl lr-route-del lr-tenant-b 192.168.100.0/24 169.254.102.2 2>/dev/null || true
    ovn-nbctl lr-route-del lr-tenant-b ${DCI_ONPREM_IP}/32 169.254.102.2 2>/dev/null || true
  " >/dev/null 2>&1 || true
  docker exec "${FAB_CLIENT}" ip netns exec ns-tenant-b sh -c "
    ip route del ${OVNK_VM_A_IP}/32 dev veth-tb-ns 2>/dev/null || true
    rm -f /tmp/x02-src-fab.pcap
  " >/dev/null 2>&1 || true
  docker exec "${FAB_PEER}" rm -f /tmp/x02-dst-fab.log 2>/dev/null || true
  docker exec "${OVNK_PEER}" rm -f /tmp/x02-dst-ovnk.log 2>/dev/null || true
  docker exec "${DCI_CHASSIS}" rm -f /tmp/x02-dst-dci.log 2>/dev/null || true
}
trap cleanup_x02 EXIT

# 1. Garantir que a topologia unificada do Tenant 'a' (X01) está ativa
if ! docker exec "${FAB_PEER}" ip link show vxlan-xf-10100 >/dev/null 2>&1; then
  x02_log "Topologia X01 ainda não ativa; executando x01-unified-tenant.sh up..."
  bash "${SCRIPT_DIR}/x01-unified-tenant.sh" up
fi

# 2. Controle positivo e auditoria de RIB JSON do Tenant 'b' (L3VNI 10200)
x02_log "Verificando RIB JSON de vrf-tenant-b (L3VNI 10200) em ${FAB_GW2} e ausência de vazamento de rotas do Tenant 'a'..."
docker exec "${FAB_GW2}" python3 -c "
import json, subprocess, sys
rib = json.loads(subprocess.check_output(['vtysh', '-c', 'show ip route vrf vrf-tenant-b json'], text=True))
for req in ('10.0.0.0/24', '10.252.0.1/32'):
    if req not in rib:
        print(f'Missing {req} in vrf-tenant-b', file=sys.stderr)
        sys.exit(1)
for forbidden in ('192.168.100.0/24', '10.0.0.0/16', '10.251.0.1/32', '10.253.0.0/24'):
    if forbidden in rib:
        print(f'Leaked Tenant A prefix {forbidden} in vrf-tenant-b', file=sys.stderr)
        sys.exit(2)
" || x02_die "Auditoria JSON de vrf-tenant-b em ${FAB_GW2} falhou"

docker exec "${FAB_CLIENT}" ip netns exec ns-tenant-b ping -c 5 -W 2 "${TENANT_B_FAB_LO}" >/dev/null \
  || x02_die "Controle positivo intra-tenant B no fabric (${FAB_CLIENT}:ns-tenant-b ${TENANT_B_IP} -> ${TENANT_B_FAB_LO}) falhou"

x02_kctl -n tenant-b exec probe-b -- ping -c 5 -W 2 "${TENANT_B_IP}" >/dev/null \
  || x02_die "Controle positivo intra-tenant B no OVN-K (probe-b -> vm-b ${TENANT_B_IP}) falhou"

# Encaminhar alvos de teste em lr-tenant-b para vrf-tenant-b (169.254.102.2 em evpnfab-gw2) para provar isolamento L3VNI 10200 vs 10100
docker exec "${FAB_CENTRAL}" sh -c "
  set -eu
  ovn-nbctl --may-exist lr-route-add lr-tenant-b ${OVNK_VM_A_IP}/32 169.254.102.2
  ovn-nbctl --may-exist lr-route-add lr-tenant-b 192.168.100.0/24 169.254.102.2
  ovn-nbctl --may-exist lr-route-add lr-tenant-b ${DCI_ONPREM_IP}/32 169.254.102.2
  ovn-nbctl --wait=hv sync
"

# 3. Iniciar capturas tcpdump simultâneas nos 3 planos do Tenant 'a' (rc=124 esperado, 0 pacotes)
x02_log "Iniciando capturas tcpdump de isolamento nos 3 planos do Tenant 'a' (Fabric, OVN-K e DCI)..."

docker exec "${FAB_PEER}" sh -c "
  rm -f /tmp/x02-dst-fab.log
  timeout 20 tcpdump -ni br-vxlan-10100 -c 1 'icmp and (host ${TENANT_B_IP} or dst host ${OVNK_VM_A_IP} or dst host ${DCI_VPC_IP} or dst host ${DCI_ONPREM_IP})' >/tmp/x02-dst-fab.log 2>&1
" >/dev/null 2>&1 &
pid_dst_fab=$!

docker exec "${OVNK_PEER}" sh -c "
  rm -f /tmp/x02-dst-ovnk.log
  timeout 20 tcpdump -ni brevpn.100 -c 1 'icmp and (host ${TENANT_B_IP} or dst host ${OVNK_VM_A_IP})' >/tmp/x02-dst-ovnk.log 2>&1
" >/dev/null 2>&1 &
pid_dst_ovnk=$!

docker exec "${DCI_CHASSIS}" sh -c "
  rm -f /tmp/x02-dst-dci.log
  timeout 20 tcpdump -ni dci-tenant-vm-p -c 1 'icmp and dst host ${DCI_VPC_IP}' >/tmp/x02-dst-dci.log 2>&1
" >/dev/null 2>&1 &
pid_dst_dci=$!

sleep 1

# 4. Emitir probes ICMP a partir do Tenant 'b' no Fabric (evpnfab-client:ns-tenant-b) e no OVN-K (tenant-b:probe-b)
#    com captura na interface de origem para comprovar emissão real no fio (N2)
fab_src_emitted="$(docker exec "${FAB_CLIENT}" ip netns exec ns-tenant-b sh -c "
  rm -f /tmp/x02-src-fab.pcap
  ip route replace ${OVNK_VM_A_IP}/32 via 10.0.0.1 dev veth-tb-ns
  timeout 12 tcpdump -ni veth-tb-ns -w /tmp/x02-src-fab.pcap 'icmp[icmptype] == icmp-echo and (dst host ${OVNK_VM_A_IP} or dst host ${DCI_VPC_IP} or dst host ${DCI_ONPREM_IP})' >/dev/null 2>&1 &
  cap_pid=\$!
  sleep 1
  for dst in ${OVNK_VM_A_IP} ${DCI_VPC_IP} ${DCI_ONPREM_IP}; do
    ping -c 5 -i 0.2 -W 1 \"\${dst}\" >/dev/null 2>&1 || true
  done
  ip route del ${OVNK_VM_A_IP}/32 dev veth-tb-ns 2>/dev/null || true
  wait \"\${cap_pid}\" || true
  tcpdump -nr /tmp/x02-src-fab.pcap 2>/dev/null | wc -l | tr -d ' '
")"

ovnk_src_emitted="$(x02_kctl -n tenant-b exec -i probe-b -- bash -s <<EOF 2>/dev/null | tail -n1 | tr -d '[:space:]'
rm -f /tmp/x02-src-ovnk.pcap
udn_if="\$(ip -o -4 addr show | awk '\$4 ~ /^10\\.0\\.0\\./ {print \$2; exit}')"
udn_if="\${udn_if:-ovn-udn1}"
ip route replace ${OVNK_VM_A_IP}/32 via 10.0.0.1 dev "\${udn_if}"
ip route replace ${DCI_VPC_IP}/32 via 10.0.0.1 dev "\${udn_if}"
ip route replace ${DCI_ONPREM_IP}/32 via 10.0.0.1 dev "\${udn_if}"
timeout 15 tcpdump -ni "\${udn_if}" -w /tmp/x02-src-ovnk.pcap "icmp[icmptype] == icmp-echo and (dst host ${OVNK_VM_A_IP} or dst host ${DCI_VPC_IP} or dst host ${DCI_ONPREM_IP})" >/dev/null 2>&1 &
cap_pid=\$!
sleep 1
for dst in ${OVNK_VM_A_IP} ${DCI_VPC_IP} ${DCI_ONPREM_IP}; do
  ping -c 5 -W 0.3 "\${dst}" >/dev/null 2>&1 || true
done
ip route del ${OVNK_VM_A_IP}/32 dev "\${udn_if}" 2>/dev/null || true
ip route del ${DCI_VPC_IP}/32 dev "\${udn_if}" 2>/dev/null || true
ip route del ${DCI_ONPREM_IP}/32 dev "\${udn_if}" 2>/dev/null || true
wait "\${cap_pid}" || true
tcpdump -nr /tmp/x02-src-ovnk.pcap 2>/dev/null | wc -l | tr -d " "
EOF
)"

rc_fab=0
wait "${pid_dst_fab}" || rc_fab=$?
rc_ovnk=0
wait "${pid_dst_ovnk}" || rc_ovnk=$?
rc_dci=0
wait "${pid_dst_dci}" || rc_dci=$?

log_fab="$(docker exec "${FAB_PEER}" cat /tmp/x02-dst-fab.log 2>/dev/null || true)"
log_ovnk="$(docker exec "${OVNK_PEER}" cat /tmp/x02-dst-ovnk.log 2>/dev/null || true)"
log_dci="$(docker exec "${DCI_CHASSIS}" cat /tmp/x02-dst-dci.log 2>/dev/null || true)"

if [[ "${fab_src_emitted:-0}" -lt 15 ]]; then
  x02_die "Emissão insuficiente na origem Fabric Tenant b: ${fab_src_emitted:-0}/15 pacotes"
fi
if [[ "${ovnk_src_emitted:-0}" -lt 15 ]]; then
  x02_die "Emissão insuficiente na origem OVN-K Tenant b: ${ovnk_src_emitted:-0}/15 pacotes"
fi

if [[ "${rc_fab}" -ne 124 ]] || ! grep -q "0 packets captured" <<<"${log_fab}"; then
  x02_die "Vazamento detectado em ${FAB_PEER}:br-vxlan-10100 (rc=${rc_fab}, log=${log_fab})"
fi
if [[ "${rc_ovnk}" -ne 124 ]] || ! grep -q "0 packets captured" <<<"${log_ovnk}"; then
  x02_die "Vazamento detectado em ${OVNK_PEER}:brevpn.100 (rc=${rc_ovnk}, log=${log_ovnk})"
fi
if [[ "${rc_dci}" -ne 124 ]] || ! grep -q "0 packets captured" <<<"${log_dci}"; then
  x02_die "Vazamento detectado em ${DCI_CHASSIS}:dci-tenant-vm-p (rc=${rc_dci}, log=${log_dci})"
fi

cleanup_x02
trap - EXIT

# 5. Revalidar controle positivo do Tenant 'a' após o ensaio de isolamento
docker exec "${DCI_CHASSIS}" ip netns exec dci-tenant-vm ping -c 5 -W 2 "${OVNK_VM_A_IP}" >/dev/null \
  || x02_die "Controle positivo pós-isolamento do Tenant a (${DCI_VPC_IP} -> ${OVNK_VM_A_IP}) falhou"

printf 'X02 PASS (Gate G05): controles positivos intra-tenant B (5/5) e A (5/5) OK; RIB vrf-tenant-b isolada; emissões na origem (fabric=%s, ovnk=%s) com 0 pacotes recebidos nos 3 planos do Tenant a (rc=%s/%s/%s).\n' \
  "${fab_src_emitted}" "${ovnk_src_emitted}" "${rc_fab}" "${rc_ovnk}" "${rc_dci}"
