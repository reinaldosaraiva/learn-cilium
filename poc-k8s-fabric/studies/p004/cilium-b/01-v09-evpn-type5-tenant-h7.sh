#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p004/cilium-b/01-v09-evpn-type5-tenant-h7.sh — Braço Cilium B (V09 / H7 / R6 / R8):
# Valida EVPN Type 5 (IP Prefix Route [5]) por tenant no Braço Cilium B via FRR 10.7.1 no nó:
# - VRF vrf-tenant-a (table 10100, L3VNI 10100, RT 65000:10100) e VRF vrf-tenant-b (table 10200, L3VNI 10200, RT 65000:10200)
# - Pareamento L2VPN EVPN entre p003-gw-worker (AS 65301) e p003-gw-worker2 (AS 65302)
# - Invariante R6 preservado: 0 rotas proto bgp na tabela default (main) do kernel Linux onde o Cilium eBPF opera
# - Validação JSON estruturada (R8) de rotas EVPN Type 5 ([5]), alcance inter-nó 30/30 por VRF com captura
#   tcpdump VXLAN (UDP 4789, VNI 10100/10200) no fio, isolamento cross-VRF (0/10 em ambas as direções) +
#   guardrail RT incorreto (65000:99900) e rollback determinístico.

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
V09_KEEP_EVPN="${V09_KEEP_EVPN:-0}"

LABCTL_BIN="${LABCTL_BIN:-/opt/poc-k8s-fabric/labctl}"
if [[ -d "${LABCTL_BIN}" ]] && [[ -x "${LABCTL_BIN}/labctl" ]]; then
  LABCTL_BIN="${LABCTL_BIN}/labctl"
fi

BASE_BGP_DIR="${CILIUM_BASE_BGP_DIR:-/opt/poc-k8s-fabric-studies/studies/p003/base/bgp}"
EVPN_DS_MANIFEST="${SCRIPT_DIR}/manifests/03-frr-evpn-type5-vrf.yaml"
LOCAL_BGP_MANIFEST="${SCRIPT_DIR}/manifests/02-cilium-bgp-local-frr.yaml"
BORDER="clab-p003-gw-fabric-border1"
POD_VIP="10.202.255.10"

v09_kctl() {
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

v09_run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf 'DRY: %s\n' "$*"
    return 0
  fi
  printf '[v09] + %s\n' "$*"
  "$@"
}

if [[ "${DRY_RUN}" == "1" ]]; then
  v09_run v09_kctl get ns kube-system -o jsonpath='{.metadata.uid}'
  v09_run k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}'
  v09_run docker inspect -f '{{.State.Status}}' "${P003_OS_CONTAINER}"
  printf 'DRY: check /proc/meminfo MemAvailable >= %s kB (R3)\n' "${MIN_MEM_AVAILABLE_KB}"
  v09_run v09_kctl apply -f "${LOCAL_BGP_MANIFEST}"
  v09_run v09_kctl apply -f "${EVPN_DS_MANIFEST}"
  printf 'DRY: configure L2VPN EVPN peering between p003-gw-worker (AS 65301) and p003-gw-worker2 (AS 65302) for VNI 10100 (RT 65000:10100) and VNI 10200 (RT 65000:10200)\n'
  printf 'DRY: verify show bgp l2vpn evpn route detail json with jq -e (R8) for Type 5 [5]:[0]:[24]:[10.253.10.0], [10.253.11.0], [10.253.20.0], [10.253.21.0]\n'
  printf 'DRY: verify R6 invariant (0 proto bgp routes in default kernel table), 30/30 VRF tenant reachability + tcpdump VXLAN UDP 4789 + cross-VRF 0/10 + RT guardrail 65000:99900\n'
  printf 'DRY: rollback to %s if V09_KEEP_EVPN=0\n' "${BASE_BGP_DIR}"
  printf 'V09 DRY-RUN OK\n'
  exit 0
fi

# 1. Guardas de baseline (p003-gw UID, k01 UID, p003-os exited, R3 MemAvailable >= 4 GiB)
uid_p003="$(v09_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_p003}" != "${P003_EXPECTED_UID}" ]]; then
  printf '[v09] ERRO: UID de p003-gw (%s) difere do esperado (%s)\n' "${uid_p003}" "${P003_EXPECTED_UID}" >&2
  exit 1
fi
uid_k01="$(k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_k01}" != "${K01_EXPECTED_UID}" ]]; then
  printf '[v09] ERRO: UID de k01 (%s) difere do esperado (%s)\n' "${uid_k01}" "${K01_EXPECTED_UID}" >&2
  exit 1
fi
os_state="$(docker inspect -f '{{.State.Status}}' "${P003_OS_CONTAINER}" 2>/dev/null || true)"
if [[ "${os_state}" != "${P003_OS_EXPECTED_STATE}" ]]; then
  printf '[v09] ERRO: estado de %s (%s) difere do esperado (%s)\n' "${P003_OS_CONTAINER}" "${os_state:-ausente}" "${P003_OS_EXPECTED_STATE}" >&2
  exit 1
fi
mem_avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
if [[ -z "${mem_avail_kb}" ]] || (( mem_avail_kb < MIN_MEM_AVAILABLE_KB )); then
  printf '[v09] ERRO: MemAvailable=%s kB abaixo do piso R3 (%s kB)\n' "${mem_avail_kb:-0}" "${MIN_MEM_AVAILABLE_KB}" >&2
  exit 1
fi

V09_CLEANUP_DONE=0
v09_cleanup() {
  if [[ "${V09_CLEANUP_DONE}" == "1" ]]; then
    return 0
  fi
  V09_CLEANUP_DONE=1
  if [[ "${V09_KEEP_EVPN}" == "1" ]]; then
    printf '[v09] V09_KEEP_EVPN=1: mantendo ds/frr-node (EVPN Type 5) e VRFs de tenant ativos.\n'
    return 0
  fi
  printf '[v09] Restaurando estado baseline de p003-gw (removendo VRFs/VXLAN de tenant e ds/frr-node)...\n'
  v09_kctl delete -f "${EVPN_DS_MANIFEST}" --ignore-not-found --timeout=120s >/dev/null 2>&1 || true
  v09_kctl -n kube-system delete cm frr-node-config frr-node-evpn-config --ignore-not-found >/dev/null 2>&1 || true
  for cnode in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
    docker exec "${cnode}" sh -c '
      ip addr del 10.255.255.1/30 dev lo 2>/dev/null || true
      for dev in dummy-ta dummy-tb br-vni-10100 vxlan-10100 vrf-tenant-a br-vni-10200 vxlan-10200 vrf-tenant-b; do
        ip link del "${dev}" 2>/dev/null || true
      done
    ' >/dev/null 2>&1 || true
  done
  v09_run v09_kctl apply -f "${BASE_BGP_DIR}/01-peer-config.yaml"
  v09_run v09_kctl apply -f "${BASE_BGP_DIR}/03-cluster-config-rack1.yaml"
  v09_run v09_kctl apply -f "${BASE_BGP_DIR}/04-cluster-config-rack2.yaml"
  v09_kctl delete ciliumbgppeerconfig local-frr-peer --ignore-not-found >/dev/null 2>&1 || true

  for _ in $(seq 1 30); do
    est_peers="$(v09_kctl get ciliumbgpnodeconfigs -o jsonpath='{range .items[*]}{range .status.bgpInstances[*]}{range .peers[*]}{.peeringState}{"\n"}{end}{end}{end}' 2>/dev/null | grep -c '^established$' || true)"
    if [[ "${est_peers:-0}" -ge 3 ]] && docker exec "${BORDER}" vtysh -c "show ip bgp ${POD_VIP}/32" 2>/dev/null | grep -q "65201 65301 i"; then
      break
    fi
    sleep 1
  done
}
trap v09_cleanup EXIT

# 2. Aplicar CiliumBGPPeerConfig local e DaemonSet frr-node com suporte EVPN Type 5
v09_kctl delete ciliumbgpclusterconfig rack1 rack2 --ignore-not-found >/dev/null 2>&1 || true
v09_kctl -n kube-system delete ds frr-node --ignore-not-found --timeout=60s >/dev/null 2>&1 || true
v09_run v09_kctl apply -f "${LOCAL_BGP_MANIFEST}"
v09_run v09_kctl apply -f "${EVPN_DS_MANIFEST}"
if ! v09_run v09_kctl -n kube-system rollout status ds/frr-node --timeout=60s; then
  v09_kctl -n kube-system get pods -l app=frr-node -o wide >&2 || true
  for p in $(v09_kctl -n kube-system get pods -l app=frr-node -o jsonpath='{.items[*].metadata.name}'); do
    printf '=== LOGS %s ===\n' "${p}" >&2
    v09_kctl -n kube-system logs "${p}" >&2 || true
    v09_kctl -n kube-system logs "${p}" --previous >&2 || true
  done
  exit 1
fi

w1_eth0="$(docker exec p003-gw-worker ip -4 -o addr show dev eth0 | awk '{split($4,a,"/"); print a[1]}' | head -n 1)"
w2_eth0="$(docker exec p003-gw-worker2 ip -4 -o addr show dev eth0 | awk '{split($4,a,"/"); print a[1]}' | head -n 1)"

# 3. Configurar VTEP FDB e endpoints de tenant nas VRFs vrf-tenant-a (VNI 10100) e vrf-tenant-b (VNI 10200)
docker exec p003-gw-worker sh -c "
  set -eu
  bridge fdb append 00:00:00:00:00:00 dev vxlan-10100 dst ${w2_eth0}
  bridge fdb append 00:00:00:00:00:00 dev vxlan-10200 dst ${w2_eth0}
  ip link del dummy-ta 2>/dev/null || true
  ip link add dummy-ta type dummy
  ip link set dummy-ta master vrf-tenant-a up
  ip addr replace 10.253.10.11/24 dev dummy-ta
  ip link del dummy-tb 2>/dev/null || true
  ip link add dummy-tb type dummy
  ip link set dummy-tb master vrf-tenant-b up
  ip addr replace 10.253.20.11/24 dev dummy-tb
"

docker exec p003-gw-worker2 sh -c "
  set -eu
  bridge fdb append 00:00:00:00:00:00 dev vxlan-10100 dst ${w1_eth0}
  bridge fdb append 00:00:00:00:00:00 dev vxlan-10200 dst ${w1_eth0}
  ip link del dummy-ta 2>/dev/null || true
  ip link add dummy-ta type dummy
  ip link set dummy-ta master vrf-tenant-a up
  ip addr replace 10.253.11.12/24 dev dummy-ta
  ip link del dummy-tb 2>/dev/null || true
  ip link add dummy-tb type dummy
  ip link set dummy-tb master vrf-tenant-b up
  ip addr replace 10.253.21.12/24 dev dummy-tb
"

f_w1="$(v09_kctl -n kube-system get pods -l app=frr-node --field-selector spec.nodeName=p003-gw-worker -o jsonpath='{.items[0].metadata.name}')"
f_w2="$(v09_kctl -n kube-system get pods -l app=frr-node --field-selector spec.nodeName=p003-gw-worker2 -o jsonpath='{.items[0].metadata.name}')"

v09_kctl -n kube-system exec "${f_w1}" -- vtysh \
  -c "conf t" \
  -c "router bgp 65301" \
  -c "neighbor ${w2_eth0} remote-as 65302" \
  -c "neighbor ${w2_eth0} port 1790" \
  -c "neighbor ${w2_eth0} update-source ${w1_eth0}" \
  -c "address-family l2vpn evpn" \
  -c "neighbor ${w2_eth0} activate" \
  -c "exit-address-family" \
  -c "end" >/dev/null

v09_kctl -n kube-system exec "${f_w2}" -- vtysh \
  -c "conf t" \
  -c "router bgp 65302" \
  -c "neighbor ${w1_eth0} remote-as 65301" \
  -c "neighbor ${w1_eth0} port 1790" \
  -c "neighbor ${w1_eth0} update-source ${w2_eth0}" \
  -c "address-family l2vpn evpn" \
  -c "neighbor ${w1_eth0} activate" \
  -c "exit-address-family" \
  -c "end" >/dev/null

# 4. Validar JSON estruturado com jq -e (R8) de rotas EVPN Type 5 ([5]) para VNI 10100 (RT 65000:10100) e VNI 10200 (RT 65000:10200)
evpn_ok=0
for _ in $(seq 1 30); do
  evpn_json="$(v09_kctl -n kube-system exec "${f_w1}" -- vtysh -c "show bgp l2vpn evpn route detail json" 2>/dev/null || true)"
  if printf '%s\n' "${evpn_json}" | jq -e '
      [ to_entries[] | select(.value | type == "object") | .value | keys[] | select(startswith("[5]:")) ] as $r
      | ($r | any(contains("10.253.10.0")))
      and ($r | any(contains("10.253.11.0")))
      and ($r | any(contains("10.253.20.0")))
      and ($r | any(contains("10.253.21.0")))
    ' >/dev/null 2>&1 \
    && docker exec p003-gw-worker ip -4 route show vrf vrf-tenant-a 2>/dev/null | grep -q "10.253.11.0/24" \
    && docker exec p003-gw-worker ip -4 route show vrf vrf-tenant-b 2>/dev/null | grep -q "10.253.21.0/24" \
    && docker exec p003-gw-worker2 ip -4 route show vrf vrf-tenant-a 2>/dev/null | grep -q "10.253.10.0/24" \
    && docker exec p003-gw-worker2 ip -4 route show vrf vrf-tenant-b 2>/dev/null | grep -q "10.253.20.0/24"; then
    evpn_ok=1
    break
  fi
  sleep 1
done

if [[ "${evpn_ok}" -ne 1 ]]; then
  printf '[v09] ERRO: rotas EVPN Type 5 ([5]) para 10.253.11.0/24 e 10.253.21.0/24 não convergiram\n' >&2
  v09_kctl -n kube-system exec "${f_w1}" -- vtysh -c "show bgp l2vpn evpn summary" -c "show bgp l2vpn evpn route" -c "show evpn vni detail" >&2 || true
  docker exec p003-gw-worker ip -4 route show vrf vrf-tenant-a >&2 || true
  docker exec p003-gw-worker ip -4 route show vrf vrf-tenant-b >&2 || true
  exit 1
fi

v09_kctl -n kube-system exec "${f_w1}" -- vtysh \
  -c "show bgp l2vpn evpn summary" \
  -c "show bgp l2vpn evpn route type prefix" \
  -c "show evpn vni" \
  -c "show ip route vrf vrf-tenant-a" \
  -c "show ip route vrf vrf-tenant-b"

# 5. Validar invariante R6 (0 rotas proto bgp na tabela default do kernel Linux)
for node in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
  r6_default="$(docker exec "${node}" ip -4 route show table main proto bgp 2>/dev/null | wc -l | tr -d '[:space:]')"
  printf '[v09] Nó %s: rotas proto bgp na tabela main (invariante R6): %s (esperado 0)\n' "${node}" "${r6_default}"
  if [[ "${r6_default}" -ne 0 ]]; then
    printf '[v09] ERRO (R6 violado): %s rotas proto bgp na tabela main de %s\n' "${r6_default}" "${node}" >&2
    exit 1
  fi
done

# 6. Validar alcance inter-nó 30/30 nas VRFs com captura tcpdump VXLAN (UDP 4789, VNI 10100/10200) e isolamento cross-VRF (0/10)
w1_pid="$(docker inspect -f '{{.State.Pid}}' p003-gw-worker)"
rm -f /tmp/v09-vxlan-capture.txt
nsenter -t "${w1_pid}" -n timeout 20 tcpdump -ni eth0 -c 20 'udp port 4789' >/tmp/v09-vxlan-capture.txt 2>&1 &
tcpdump_pid=$!
sleep 0.5

ta_ok=0
tb_ok=0
for _ in $(seq 1 30); do
  if nsenter -t "${w1_pid}" -n ip vrf exec vrf-tenant-a ping -c 1 -W 1 -I 10.253.10.11 10.253.11.12 >/dev/null 2>&1; then
    ta_ok=$((ta_ok + 1))
  fi
  if nsenter -t "${w1_pid}" -n ip vrf exec vrf-tenant-b ping -c 1 -W 1 -I 10.253.20.11 10.253.21.12 >/dev/null 2>&1; then
    tb_ok=$((tb_ok + 1))
  fi
done

wait "${tcpdump_pid}" 2>/dev/null || true
printf '\n=== [v09] Captura tcpdump VXLAN (UDP 4789) em p003-gw-worker eth0 ===\n'
cat /tmp/v09-vxlan-capture.txt || true

if ! grep -qi "vxlan" /tmp/v09-vxlan-capture.txt || ! grep -q "10100" /tmp/v09-vxlan-capture.txt || ! grep -q "10200" /tmp/v09-vxlan-capture.txt; then
  printf '[v09] ERRO: captura tcpdump não registrou pacotes VXLAN para VNI 10100 e VNI 10200\n' >&2
  exit 1
fi
rm -f /tmp/v09-vxlan-capture.txt

if [[ "${ta_ok}" -ne 30 ]] || [[ "${tb_ok}" -ne 30 ]]; then
  printf '[v09] ERRO: alcance intra-VRF abaixo de 30/30 (ta_ok=%s/30, tb_ok=%s/30)\n' "${ta_ok}" "${tb_ok}" >&2
  exit 1
fi

# Controle negativo cross-VRF: 0/10 em ambas as direções (vrf-tenant-a -> tenant-b e vrf-tenant-b -> tenant-a)
cross_ab=0
cross_ba=0
for _ in $(seq 1 10); do
  if nsenter -t "${w1_pid}" -n ip vrf exec vrf-tenant-a ping -c 1 -W 1 -I 10.253.10.11 10.253.21.12 >/dev/null 2>&1; then
    cross_ab=$((cross_ab + 1))
  fi
  if nsenter -t "${w1_pid}" -n ip vrf exec vrf-tenant-b ping -c 1 -W 1 -I 10.253.20.11 10.253.11.12 >/dev/null 2>&1; then
    cross_ba=$((cross_ba + 1))
  fi
done
printf '[v09] Alcance intra-tenant: vrf-tenant-a=%s/30, vrf-tenant-b=%s/30 | Isolamento cross-VRF: a->b=%s/10, b->a=%s/10\n' \
  "${ta_ok}" "${tb_ok}" "${cross_ab}" "${cross_ba}"
if [[ "${cross_ab}" -ne 0 ]] || [[ "${cross_ba}" -ne 0 ]]; then
  printf '[v09] ERRO: vazamento cross-VRF detectado (a->b=%s/10, b->a=%s/10)\n' "${cross_ab}" "${cross_ba}" >&2
  exit 1
fi

# 7. Guardrail RT incorreto (65000:99900) em vrf-tenant-b de worker2 deve retirar 10.253.21.0/24 da vrf-tenant-b de worker1
v09_kctl -n kube-system exec "${f_w2}" -- vtysh \
  -c "conf t" \
  -c "router bgp 65302 vrf vrf-tenant-b" \
  -c "address-family l2vpn evpn" \
  -c "no route-target export 65000:10200" \
  -c "route-target export 65000:99900" \
  -c "exit-address-family" \
  -c "end" >/dev/null
sleep 2
if docker exec p003-gw-worker ip -4 route show vrf vrf-tenant-b | grep -q "10.253.21.0/24"; then
  printf '[v09] ERRO: rota 10.253.21.0/24 permaneceu na vrf-tenant-b apesar de RT incorreto 65000:99900\n' >&2
  exit 1
fi
v09_kctl -n kube-system exec "${f_w2}" -- vtysh \
  -c "conf t" \
  -c "router bgp 65302 vrf vrf-tenant-b" \
  -c "address-family l2vpn evpn" \
  -c "no route-target export 65000:99900" \
  -c "route-target export 65000:10200" \
  -c "exit-address-family" \
  -c "end" >/dev/null

v09_cleanup
printf 'V09 PASS (H7 EVPN Type 5 por tenant via FRR no nó CONFIRMED): vni_a=10100 (RT 65000:10100 %s/30 OK), vni_b=10200 (RT 65000:10200 %s/30 OK), vxlan_udp_4789=verified, cross_vrf_leak=%s/10_%s/10, rt_guardrail_65000_99900=blocked, r6_main_bgp_routes=0.\n' \
  "${ta_ok}" "${tb_ok}" "${cross_ab}" "${cross_ba}"
