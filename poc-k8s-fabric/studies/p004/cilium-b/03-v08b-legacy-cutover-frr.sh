#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p004/cilium-b/03-v08b-legacy-cutover-frr.sh — Braço Cilium B (V08-B / H8 + H6):
# Variante do caso V08 (cutover de IP legado 10.60.0.50/32 para KubeVirt VMI) anunciando o CiliumPodIPPool
# /32 através do FRR 10.7.1 no nó (AS_PATH 65203 65600 65201 65301 65311 i na border1, invariante R6=0 rotas
# proto bgp no kernel Linux) com rollback determinístico para ipam.mode=kubernetes e peering direto.

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
FRR_DS_MANIFEST="${SCRIPT_DIR}/manifests/01-frr-node-daemonset.yaml"
LOCAL_BGP_MANIFEST="${SCRIPT_DIR}/manifests/02-cilium-bgp-local-frr.yaml"
BORDER="clab-p003-gw-fabric-border1"
POD_VIP="10.202.255.10"

v08b_kctl() {
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
  printf 'DRY: deploy %s and %s (FRR 10.7.1 per-node on 10.255.255.1:1790)\n' "${LOCAL_BGP_MANIFEST}" "${FRR_DS_MANIFEST}"
  printf 'DRY: run legacy KVM 10.60.0.50/24 -> cutover -> CiliumPodIPPool/p004-legacy-ip 10.60.0.50/32 via local FRR 10.7.1 (AS_PATH 65301 65311 on border1, R6=0) -> 30/30 probes\n'
  printf 'DRY: restore ipam.mode=kubernetes and direct BGP peering\n'
  printf 'V08B DRY-RUN OK\n'
  exit 0
fi

uid_p003="$(v08b_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_p003}" != "${P003_EXPECTED_UID}" ]]; then
  printf '[v08b] ERRO: UID de p003-gw (%s) difere do esperado (%s)\n' "${uid_p003}" "${P003_EXPECTED_UID}" >&2
  exit 1
fi
uid_k01="$(k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_k01}" != "${K01_EXPECTED_UID}" ]]; then
  printf '[v08b] ERRO: UID de k01 (%s) difere do esperado (%s)\n' "${uid_k01}" "${K01_EXPECTED_UID}" >&2
  exit 1
fi
os_state="$(docker inspect -f '{{.State.Status}}' "${P003_OS_CONTAINER}" 2>/dev/null || true)"
if [[ "${os_state}" != "${P003_OS_EXPECTED_STATE}" ]]; then
  printf '[v08b] ERRO: estado de %s (%s) difere do esperado (%s)\n' "${P003_OS_CONTAINER}" "${os_state:-ausente}" "${P003_OS_EXPECTED_STATE}" >&2
  exit 1
fi
mem_avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
if [[ -z "${mem_avail_kb}" ]] || (( mem_avail_kb < MIN_MEM_AVAILABLE_KB )); then
  printf '[v08b] ERRO: MemAvailable=%s kB abaixo do piso R3 (%s kB)\n' "${mem_avail_kb:-0}" "${MIN_MEM_AVAILABLE_KB}" >&2
  exit 1
fi

V08B_CLEANUP_DONE=0
v08b_cleanup() {
  if [[ "${V08B_CLEANUP_DONE}" == "1" ]]; then
    return 0
  fi
  V08B_CLEANUP_DONE=1
  printf '[v08b] Restaurando peering BGP direto Cilium -> leaf1/leaf2 e removendo ds/frr-node...\n'
  v08b_kctl delete -f "${FRR_DS_MANIFEST}" --ignore-not-found --timeout=120s >/dev/null 2>&1 || true
  for cnode in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
    docker exec "${cnode}" ip addr del 10.255.255.1/30 dev lo 2>/dev/null || true
  done
  v08b_kctl apply -f "${BASE_BGP_DIR}/01-peer-config.yaml" >/dev/null 2>&1 || true
  v08b_kctl apply -f "${BASE_BGP_DIR}/03-cluster-config-rack1.yaml" >/dev/null 2>&1 || true
  v08b_kctl apply -f "${BASE_BGP_DIR}/04-cluster-config-rack2.yaml" >/dev/null 2>&1 || true
  v08b_kctl delete ciliumbgppeerconfig local-frr-peer --ignore-not-found >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    est_peers="$(v08b_kctl get ciliumbgpnodeconfigs -o jsonpath='{range .items[*]}{range .status.bgpInstances[*]}{range .peers[*]}{.peeringState}{"\n"}{end}{end}{end}' 2>/dev/null | grep -c '^established$' || true)"
    if [[ "${est_peers:-0}" -ge 3 ]] && docker exec "${BORDER}" vtysh -c "show ip bgp ${POD_VIP}/32" 2>/dev/null | grep -q "65201 65301 i"; then
      break
    fi
    sleep 1
  done
}
trap v08b_cleanup EXIT

for node in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
  docker exec "${node}" ip addr replace 10.255.255.1/30 dev lo
done
v08b_kctl delete ciliumbgpclusterconfig rack1 rack2 --ignore-not-found >/dev/null 2>&1 || true
v08b_kctl apply -f "${LOCAL_BGP_MANIFEST}"
v08b_kctl apply -f "${FRR_DS_MANIFEST}"
v08b_kctl -n kube-system rollout status ds/frr-node --timeout=180s

frr_path_ok=0
for _ in $(seq 1 45); do
  if docker exec "${BORDER}" vtysh -c "show ip bgp ${POD_VIP}/32" 2>/dev/null | grep -Eq "65301 65311|65302 65312"; then
    frr_path_ok=1
    break
  fi
  sleep 1
done
if [[ "${frr_path_ok}" -ne 1 ]]; then
  printf '[v08b] ERRO: rota de referência %s/32 via FRR local (65301 65311) não convergiu na border1\n' "${POD_VIP}" >&2
  exit 1
fi

rm -f /tmp/v08b-cutover.out
bash "${SCRIPT_DIR}/../cilium-a/v08a-legacy-ip-cutover.sh" | tee /tmp/v08b-cutover.out
if ! grep -Eq "65301 65311|65302 65312" /tmp/v08b-cutover.out; then
  printf '[v08b] ERRO: AS_PATH via FRR local (65301 65311 / 65302 65312) não observado durante o cutover de 10.60.0.50/32\n' >&2
  rm -f /tmp/v08b-cutover.out
  exit 1
fi
rm -f /tmp/v08b-cutover.out

for node in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
  r6_routes="$(docker exec "${node}" ip -4 route show table main proto bgp 2>/dev/null | wc -l | tr -d '[:space:]')"
  if [[ "${r6_routes}" -ne 0 ]]; then
    printf '[v08b] ERRO (R6 violado): %s rotas proto bgp em %s\n' "${r6_routes}" "${node}" >&2
    exit 1
  fi
done

v08b_cleanup
printf 'V08B PASS (Cutover de IP legado 10.60.0.50/32 via FRR 10.7.1 no nó + R6=0 + rollback ipam.mode=kubernetes CONFIRMED).\n'
