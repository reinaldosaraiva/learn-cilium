#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p004/cilium-b/02-v07b-overlapping-vrf-evpn.sh — Braço Cilium B (V07-B / H5 vs H7):
# Contrasta V07-A (colisão de IP idêntico 10.253.10.100/32 no mapa eBPF global cilium_lxc do Cilium OSS)
# com V07-B (sub-redes sobrepostas 10.253.10.0/24 e IP idêntico 10.253.10.100/24 isolados em VRFs Linux
# vrf-tenant-a VNI 10100 e vrf-tenant-b VNI 10200 gerenciadas por FRR 10.7.1 no nó fora do datapath primário
# eth0 do Cilium, preservando R6).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN="${DRY_RUN:-${LABCTL_DRY_RUN:-0}}"
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

P003_KUBECONFIG="${P003_KUBECONFIG:-/root/.kube/p003-gw.config}"
P003_CONTEXT="${P003_CONTEXT:-kind-p003-gw}"
P003_EXPECTED_UID="${P003_EXPECTED_UID:-6bb32e0f-71f9-4558-ae33-356ba2250c26}"
K01_KUBECONFIG="${K01_KUBECONFIG:-/root/.kube/k01-rebuild.config}"
K01_CONTEXT="${K01_CONTEXT:-kind-k01}"
K01_EXPECTED_UID="${K01_EXPECTED_UID:-635e7274-5597-40c7-9de5-b1fbe3d68b22}"
P003_OS_CONTAINER="${P003_OS_CONTAINER:-p003-os}"
P003_OS_EXPECTED_STATE="${P003_OS_EXPECTED_STATE:-exited}"
MIN_MEM_AVAILABLE_KB="${MIN_MEM_AVAILABLE_KB:-4194304}"
BASE_BGP_DIR="${CILIUM_BASE_BGP_DIR:-/opt/poc-k8s-fabric-studies/studies/p003/base/bgp}"
EVPN_DS_MANIFEST="${SCRIPT_DIR}/manifests/03-frr-evpn-type5-vrf.yaml"
BORDER="clab-p003-gw-fabric-border1"
POD_VIP="10.202.255.10"

v07b_kctl() {
  if [[ -f "${P003_KUBECONFIG}" ]]; then
    kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" "$@"
  else
    kubectl --context "${P003_CONTEXT}" "$@"
  fi
}

k01_kctl() {
  if [[ -f "${K01_KUBECONFIG}" ]]; then
    kubectl --kubeconfig "${K01_KUBECONFIG}" --context "${K01_CONTEXT}" "$@"
  else
    kubectl --context "${K01_CONTEXT}" "$@"
  fi
}

if [[ "${DRY_RUN}" == "1" ]]; then
  printf 'DRY: verify p003-gw UID=%s, k01 UID=%s, p003-os=%s, MemAvailable >= %s kB\n' \
    "${P003_EXPECTED_UID}" "${K01_EXPECTED_UID}" "${P003_OS_EXPECTED_STATE}" "${MIN_MEM_AVAILABLE_KB}"
  printf 'DRY: instantiate overlapping CIDR 10.253.10.0/24 and identical IP 10.253.10.100/24 in vrf-tenant-a (VNI 10100, RT 65000:10100) and vrf-tenant-b (VNI 10200, RT 65000:10200)\n'
  printf 'DRY: verify 30/30 intra-VRF probes to 10.253.10.100 in both tenants and 0/10 cross-VRF leakage, while Cilium eth0 global map remains conflict-free (R6=0)\n'
  printf 'DRY: cleanup VRFs and verify baseline\n'
  printf 'V07B DRY-RUN OK\n'
  exit 0
fi

uid_p003="$(v07b_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_p003}" != "${P003_EXPECTED_UID}" ]]; then
  printf '[v07b] ERRO: UID de p003-gw (%s) difere do esperado (%s)\n' "${uid_p003}" "${P003_EXPECTED_UID}" >&2
  exit 1
fi
uid_k01="$(k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_k01}" != "${K01_EXPECTED_UID}" ]]; then
  printf '[v07b] ERRO: UID de k01 (%s) difere do esperado (%s)\n' "${uid_k01}" "${K01_EXPECTED_UID}" >&2
  exit 1
fi
os_state="$(docker inspect -f '{{.State.Status}}' "${P003_OS_CONTAINER}" 2>/dev/null || true)"
if [[ "${os_state}" != "${P003_OS_EXPECTED_STATE}" ]]; then
  printf '[v07b] ERRO: estado de %s (%s) difere do esperado (%s)\n' "${P003_OS_CONTAINER}" "${os_state:-ausente}" "${P003_OS_EXPECTED_STATE}" >&2
  exit 1
fi
mem_avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
if [[ -z "${mem_avail_kb}" ]] || (( mem_avail_kb < MIN_MEM_AVAILABLE_KB )); then
  printf '[v07b] ERRO: MemAvailable=%s kB abaixo do piso R3 (%s kB)\n' "${mem_avail_kb:-0}" "${MIN_MEM_AVAILABLE_KB}" >&2
  exit 1
fi

V07B_CLEANUP_DONE=0
v07b_cleanup() {
  if [[ "${V07B_CLEANUP_DONE}" == "1" ]]; then
    return 0
  fi
  V07B_CLEANUP_DONE=1
  printf '[v07b] Restaurando baseline de p003-gw (removendo VRFs/VXLAN de tenant e ds/frr-node)...\n'
  v07b_kctl delete -f "${EVPN_DS_MANIFEST}" --ignore-not-found --timeout=120s >/dev/null 2>&1 || true
  v07b_kctl -n kube-system delete cm frr-node-config frr-node-evpn-config --ignore-not-found >/dev/null 2>&1 || true
  for cnode in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
    docker exec "${cnode}" sh -c '
      ip addr del 10.255.255.1/30 dev lo 2>/dev/null || true
      for dev in dummy-ta dummy-tb br-vni-10100 vxlan-10100 vrf-tenant-a br-vni-10200 vxlan-10200 vrf-tenant-b; do
        ip link del "${dev}" 2>/dev/null || true
      done
    ' >/dev/null 2>&1 || true
  done
  v07b_kctl apply -f "${BASE_BGP_DIR}/01-peer-config.yaml" >/dev/null 2>&1 || true
  v07b_kctl apply -f "${BASE_BGP_DIR}/03-cluster-config-rack1.yaml" >/dev/null 2>&1 || true
  v07b_kctl apply -f "${BASE_BGP_DIR}/04-cluster-config-rack2.yaml" >/dev/null 2>&1 || true
  v07b_kctl delete ciliumbgppeerconfig local-frr-peer --ignore-not-found >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    est_peers="$(v07b_kctl get ciliumbgpnodeconfigs -o jsonpath='{range .items[*]}{range .status.bgpInstances[*]}{range .peers[*]}{.peeringState}{"\n"}{end}{end}{end}' 2>/dev/null | grep -c '^established$' || true)"
    if [[ "${est_peers:-0}" -ge 3 ]] && docker exec "${BORDER}" vtysh -c "show ip bgp ${POD_VIP}/32" 2>/dev/null | grep -q "65201 65301 i"; then
      break
    fi
    sleep 1
  done
}
trap v07b_cleanup EXIT

V09_KEEP_EVPN=1 bash "${SCRIPT_DIR}/01-v09-evpn-type5-tenant-h7.sh"

# Instanciar o mesmo CIDR 10.253.10.0/24 e o mesmo IP 10.253.10.100/24 em ambos os tenants nas respectivas VRFs
# (vrf-tenant-a VNI 10100 e vrf-tenant-b VNI 10200) em worker1 (mais IPs testemunha exclusivos 10.253.10.101/24 em ta
# e 10.253.10.102/24 em tb para prova negativa 0/10 cross-VRF na mesma sub-rede) e 10.253.11.200/24 em worker2
docker exec p003-gw-worker sh -c '
  ip addr flush dev dummy-ta
  ip addr add 10.253.10.100/24 dev dummy-ta
  ip addr add 10.253.10.101/24 dev dummy-ta
  ip addr flush dev dummy-tb
  ip addr add 10.253.10.100/24 dev dummy-tb
  ip addr add 10.253.10.102/24 dev dummy-tb
'
docker exec p003-gw-worker2 sh -c '
  ip addr flush dev dummy-ta
  ip addr add 10.253.11.200/24 dev dummy-ta
  ip addr flush dev dummy-tb
  ip addr add 10.253.11.200/24 dev dummy-tb
'

f_w1="$(v07b_kctl -n kube-system get pods -l app=frr-node --field-selector spec.nodeName=p003-gw-worker -o jsonpath='{.items[0].metadata.name}')"
ovl_conv_ok=0
for _ in $(seq 1 30); do
  if docker exec p003-gw-worker2 ip -4 route show vrf vrf-tenant-a 2>/dev/null | grep -q "10.253.10.0/24" \
    && docker exec p003-gw-worker2 ip -4 route show vrf vrf-tenant-b 2>/dev/null | grep -q "10.253.10.0/24" \
    && docker exec p003-gw-worker ip -4 route show vrf vrf-tenant-a 2>/dev/null | grep -q "10.253.11.0/24" \
    && docker exec p003-gw-worker ip -4 route show vrf vrf-tenant-b 2>/dev/null | grep -q "10.253.11.0/24"; then
    ovl_conv_ok=1
    break
  fi
  sleep 1
done

if [[ "${ovl_conv_ok}" -ne 1 ]]; then
  printf '[v07b] ERRO: rotas sobrepostas 10.253.10.0/24 e 10.253.11.0/24 não convergiram nas duas VRFs\n' >&2
  exit 1
fi

printf '\n=== [v07b] Rotas sobrepostas 10.253.10.0/24 isoladas em vrf-tenant-a (VNI 10100) e vrf-tenant-b (VNI 10200) ===\n'
v07b_kctl -n kube-system exec "${f_w1}" -- vtysh \
  -c "show bgp l2vpn evpn route type prefix" \
  -c "show ip route vrf vrf-tenant-a" \
  -c "show ip route vrf vrf-tenant-b"

for node in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
  r6_routes="$(docker exec "${node}" ip -4 route show table main proto bgp 2>/dev/null | wc -l | tr -d '[:space:]')"
  if [[ "${r6_routes}" -ne 0 ]]; then
    printf '[v07b] ERRO (R6 violado): %s rotas proto bgp na tabela main de %s\n' "${r6_routes}" "${node}" >&2
    exit 1
  fi
done

w2_pid="$(docker inspect -f '{{.State.Pid}}' p003-gw-worker2)"
ta_ovl_ok=0
tb_ovl_ok=0
for _ in $(seq 1 30); do
  if nsenter -t "${w2_pid}" -n ip vrf exec vrf-tenant-a ping -c 1 -W 1 -I 10.253.11.200 10.253.10.100 >/dev/null 2>&1; then
    ta_ovl_ok=$((ta_ovl_ok + 1))
  fi
  if nsenter -t "${w2_pid}" -n ip vrf exec vrf-tenant-b ping -c 1 -W 1 -I 10.253.11.200 10.253.10.100 >/dev/null 2>&1; then
    tb_ovl_ok=$((tb_ovl_ok + 1))
  fi
done

if [[ "${ta_ovl_ok}" -ne 30 ]] || [[ "${tb_ovl_ok}" -ne 30 ]]; then
  printf '[v07b] ERRO: falha no alcance para 10.253.10.100 sobreposto (ta=%s/30, tb=%s/30)\n' "${ta_ovl_ok}" "${tb_ovl_ok}" >&2
  exit 1
fi

cross_ovl_ab=0
cross_ovl_ba=0
for _ in $(seq 1 10); do
  if nsenter -t "${w2_pid}" -n ip vrf exec vrf-tenant-a ping -c 1 -W 1 -I 10.253.11.200 10.253.10.102 >/dev/null 2>&1; then
    cross_ovl_ab=$((cross_ovl_ab + 1))
  fi
  if nsenter -t "${w2_pid}" -n ip vrf exec vrf-tenant-b ping -c 1 -W 1 -I 10.253.11.200 10.253.10.101 >/dev/null 2>&1; then
    cross_ovl_ba=$((cross_ovl_ba + 1))
  fi
done
printf '[v07b] Alcance intra-VRF sobreposto (10.253.10.100): ta=%s/30, tb=%s/30 | Isolamento cross-VRF (10.253.10.101/102): a->b=%s/10, b->a=%s/10\n' \
  "${ta_ovl_ok}" "${tb_ovl_ok}" "${cross_ovl_ab}" "${cross_ovl_ba}"
if [[ "${cross_ovl_ab}" -ne 0 ]] || [[ "${cross_ovl_ba}" -ne 0 ]]; then
  printf '[v07b] ERRO: vazamento cross-VRF detectado no CIDR sobreposto 10.253.10.0/24 (a->b=%s/10, b->a=%s/10)\n' "${cross_ovl_ab}" "${cross_ovl_ba}" >&2
  exit 1
fi

# Verificar que o mapa eBPF global cilium_lxc do Cilium continua único por nó (sem chave de VRF)
cilium_pod_w1="$(v07b_kctl -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=p003-gw-worker -o jsonpath='{.items[0].metadata.name}')"
printf '\n=== [v07b] Estado do ipcache eBPF global do Cilium em p003-gw-worker (sem coluna VRF/VNI) ===\n'
v07b_kctl -n kube-system exec "${cilium_pod_w1}" -c cilium-agent -- cilium-dbg bpf ipcache list | sed -n '1,15p'

v07b_cleanup
printf 'V07B PASS (Overlapping CIDR 10.253.10.0/24 & identical IP 10.253.10.100/24 isolated per-VRF/EVPN Type 5 in FRR: ta=%s/30, tb=%s/30; primary Cilium eth0 global cilium_lxc/ipcache map still requires secondary interface or OVN-K UDN).\n' \
  "${ta_ovl_ok}" "${tb_ovl_ok}"
