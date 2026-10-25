#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p004/cilium-b/00-deploy-frr-node-h6.sh — Braço Cilium B (H6 / Q3 / Q7 / R6):
# Implanta FRR 10.7.1 por nó (DaemonSet frr-node em hostNetwork com bgpd na porta 1790 e
# route-map RM-NO-KERNEL impedindo instalação de rotas BGP no kernel Linux para proteger o datapath
# do Cilium conforme R6) e comuta o Cilium BGP Control Plane v2 para parear localmente em
# 127.0.0.1:1790 (AS 65311/65312 -> FRR AS 65301/65302 -> leaf1/leaf2 AS 65201/65202 -> border1).
# Valida AS_PATH (65301 65311 e 65302 65312) na border1, 30/30 probes HTTP para Pod VIP e KubeVirt
# VM VIP, controle negativo (shutdown do peer local 127.0.0.1 retira rotas na border1) e rollback
# determinístico quando H6_KEEP_FRR=0 (padrão).

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

# Quando H6_KEEP_FRR=0 (padrão na S006), restaura o peering direto Cilium -> leaf1/leaf2 ao final
# para deixar p003-gw limpo no baseline; quando H6_KEEP_FRR=1 (ex.: na S007 para V09 EVPN Type 5),
# mantém o DaemonSet frr-node e o peering local ativos.
H6_KEEP_FRR="${H6_KEEP_FRR:-0}"

LABCTL_BIN="${LABCTL_BIN:-/opt/poc-k8s-fabric/labctl}"
if [[ -d "${LABCTL_BIN}" ]] && [[ -x "${LABCTL_BIN}/labctl" ]]; then
  LABCTL_BIN="${LABCTL_BIN}/labctl"
fi

BASE_BGP_DIR="${CILIUM_BASE_BGP_DIR:-/opt/poc-k8s-fabric-studies/studies/p003/base/bgp}"
FRR_DS_MANIFEST="${SCRIPT_DIR}/manifests/01-frr-node-daemonset.yaml"
LOCAL_BGP_MANIFEST="${SCRIPT_DIR}/manifests/02-cilium-bgp-local-frr.yaml"
FRR_IMAGE_PINNED="quay.io/frrouting/frr:10.7.1@sha256:9aeb1c4947207a3d405674c4de06451d8b7e0d00e6f7d1f8e61e7354273efc63"
FRR_IMAGE_TAG="quay.io/frrouting/frr:10.7.1"

BORDER="clab-p003-gw-fabric-border1"
CLIENT="clab-p003-gw-fabric-client"
POD_VIP="10.202.255.10"
VM_VIP="10.202.255.20"
NS_VM="p004-vm-a"

h6_kctl() {
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

h6_run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf 'DRY: %s\n' "$*"
    return 0
  fi
  printf '[h6] + %s\n' "$*"
  "$@"
}

if [[ "${DRY_RUN}" == "1" ]]; then
  h6_run h6_kctl get ns kube-system -o jsonpath='{.metadata.uid}'
  h6_run k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}'
  h6_run docker inspect -f '{{.State.Status}}' "${P003_OS_CONTAINER}"
  printf 'DRY: check /proc/meminfo MemAvailable >= %s kB (R3)\n' "${MIN_MEM_AVAILABLE_KB}"
  printf 'DRY: verify/load pinned image %s into p003-gw Kind nodes (Q3)\n' "${FRR_IMAGE_PINNED}"
  h6_run h6_kctl apply -f "${LOCAL_BGP_MANIFEST}"
  h6_run h6_kctl apply -f "${FRR_DS_MANIFEST}"
  printf 'DRY: verify Cilium GoBGP <-> FRR local (127.0.0.1:1790) and FRR local <-> leaf1/leaf2 (10.30.x.1:179)\n'
  printf 'DRY: verify R6 invariant (0 proto bgp routes installed in node kernel tables)\n'
  printf 'DRY: verify AS_PATH (65301 65311 / 65302 65312) on %s and 30/30 HTTP probes from %s to %s and %s\n' \
    "${BORDER}" "${CLIENT}" "${POD_VIP}" "${VM_VIP}"
  printf 'DRY: run negative control (shutdown neighbor 127.0.0.1 on node FRRs -> 0/10 probes -> re-enable -> 10/10 probes)\n'
  printf 'DRY: rollback to %s and remove ds/frr-node if H6_KEEP_FRR=0\n' "${BASE_BGP_DIR}"
  printf 'H6 DRY-RUN OK\n'
  exit 0
fi

# 1. Validar UIDs de p003-gw e k01, estado exited de p003-os e orçamento de RAM (R3 >= 4 GiB)
uid_p003="$(h6_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_p003}" != "${P003_EXPECTED_UID}" ]]; then
  printf '[h6] ERRO: UID de p003-gw (%s) difere do esperado (%s)\n' "${uid_p003}" "${P003_EXPECTED_UID}" >&2
  exit 1
fi
uid_k01="$(k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_k01}" != "${K01_EXPECTED_UID}" ]]; then
  printf '[h6] ERRO: UID de k01 (%s) difere do esperado (%s)\n' "${uid_k01}" "${K01_EXPECTED_UID}" >&2
  exit 1
fi
os_state="$(docker inspect -f '{{.State.Status}}' "${P003_OS_CONTAINER}" 2>/dev/null || true)"
if [[ "${os_state}" != "${P003_OS_EXPECTED_STATE}" ]]; then
  printf '[h6] ERRO: estado de %s (%s) difere do esperado (%s)\n' "${P003_OS_CONTAINER}" "${os_state:-ausente}" "${P003_OS_EXPECTED_STATE}" >&2
  exit 1
fi
mem_avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
if [[ -z "${mem_avail_kb}" ]] || (( mem_avail_kb < MIN_MEM_AVAILABLE_KB )); then
  printf '[h6] ERRO: MemAvailable=%s kB abaixo do piso R3 (%s kB)\n' "${mem_avail_kb:-0}" "${MIN_MEM_AVAILABLE_KB}" >&2
  exit 1
fi

H6_CLEANUP_DONE=0
h6_cleanup() {
  if [[ "${H6_CLEANUP_DONE}" == "1" ]]; then
    return 0
  fi
  H6_CLEANUP_DONE=1
  if [[ "${H6_KEEP_FRR}" == "1" ]]; then
    printf '[h6] H6_KEEP_FRR=1: mantendo ds/frr-node e CiliumBGPPeerConfig/local-frr-peer ativos.\n'
    return 0
  fi
  printf '[h6] Restaurando peering BGP direto Cilium -> leaf1/leaf2 e removendo ds/frr-node...\n'
  h6_kctl delete ns "${NS_VM}" p004-clients --ignore-not-found --timeout=120s >/dev/null 2>&1 || true
  h6_kctl delete -f "${FRR_DS_MANIFEST}" --ignore-not-found --timeout=120s >/dev/null 2>&1 || true
  for cnode in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
    docker exec "${cnode}" ip addr del 10.255.255.1/30 dev lo 2>/dev/null || true
  done
  h6_run h6_kctl apply -f "${BASE_BGP_DIR}/01-peer-config.yaml"
  h6_run h6_kctl apply -f "${BASE_BGP_DIR}/03-cluster-config-rack1.yaml"
  h6_run h6_kctl apply -f "${BASE_BGP_DIR}/04-cluster-config-rack2.yaml"
  h6_kctl delete ciliumbgppeerconfig local-frr-peer --ignore-not-found >/dev/null 2>&1 || true

  for _ in $(seq 1 30); do
    est_peers="$(h6_kctl get ciliumbgpnodeconfigs -o jsonpath='{range .items[*]}{range .status.bgpInstances[*]}{range .peers[*]}{.peeringState}{"\n"}{end}{end}{end}' 2>/dev/null | grep -c '^established$' || true)"
    if [[ "${est_peers:-0}" -ge 3 ]] && docker exec "${BORDER}" vtysh -c "show ip bgp ${POD_VIP}/32" 2>/dev/null | grep -q "65201 65301 i"; then
      break
    fi
    sleep 1
  done
}
trap h6_cleanup EXIT

# 2. Garantir imagem FRR 10.7.1 pinada por digest (Q3) nos 3 nós Kind de p003-gw
if ! docker image inspect "${FRR_IMAGE_PINNED}" >/dev/null 2>&1; then
  printf '[h6] Baixando imagem pinada %s no host...\n' "${FRR_IMAGE_PINNED}"
  docker pull "${FRR_IMAGE_PINNED}" >/dev/null
  docker tag "${FRR_IMAGE_PINNED}" "${FRR_IMAGE_TAG}"
fi

for node in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
  if ! docker exec "${node}" ctr -n k8s.io images ls 2>/dev/null | grep "frrouting/frr" >/dev/null; then
    printf '[h6] Carregando %s no nó Kind %s...\n' "${FRR_IMAGE_PINNED}" "${node}"
    docker save "${FRR_IMAGE_TAG}" | docker exec -i "${node}" ctr -n k8s.io images import --digests - >/dev/null
  fi
  docker exec "${node}" ip addr replace 10.255.255.1/30 dev lo
done

# 3. Garantir que vmi/vm-a e svc/vm-a-vip (10.202.255.20/32) estejam ativos para validar Pod VIP e VM VIP via FRR
if ! h6_kctl -n "${NS_VM}" get vmi vm-a >/dev/null 2>&1; then
  h6_kctl apply -f "${SCRIPT_DIR}/../cilium-a/manifests/01-namespace-clients.yaml" >/dev/null
  h6_kctl apply -f "${SCRIPT_DIR}/../cilium-a/manifests/02-vm-a.yaml" >/dev/null
  h6_kctl apply -f "${SCRIPT_DIR}/../cilium-a/manifests/03-v02-bgp-vip-service.yaml" >/dev/null
else
  h6_kctl -n "${NS_VM}" patch vm vm-a --type=merge -p '{"spec":{"runStrategy":"Always"}}' >/dev/null 2>&1 || true
  h6_kctl apply -f "${SCRIPT_DIR}/../cilium-a/manifests/03-v02-bgp-vip-service.yaml" >/dev/null
fi
h6_run h6_kctl -n "${NS_VM}" wait vmi vm-a --for=condition=Ready --timeout=240s

# 4. Comutar Cilium BGP para 10.255.255.1:1790 e implantar DaemonSet frr-node (porta 1790 local + porta 179 para leaf1/leaf2)
# Remover CiliumBGPClusterConfig anteriores primeiro envia Cease/Peer De-configured ao leaf1/leaf2,
# evitando retenção temporária por Graceful Restart das rotas diretas (65301 i / 65302 i).
h6_kctl delete ciliumbgpclusterconfig rack1 rack2 --ignore-not-found >/dev/null 2>&1 || true
h6_run h6_kctl apply -f "${LOCAL_BGP_MANIFEST}"
h6_run h6_kctl apply -f "${FRR_DS_MANIFEST}"
h6_run h6_kctl -n kube-system rollout status ds/frr-node --timeout=180s

# Aguardar convergência Cilium GoBGP (65311/65312) -> FRR local (65301/65302) -> leaf1/leaf2 -> border1
t_conv0="$(date +%s)"
t_conv=""
for _ in $(seq 1 45); do
  b_out="$(docker exec "${BORDER}" vtysh -c "show ip bgp" 2>/dev/null || true)"
  if printf '%s\n' "${b_out}" | grep "10.202.255.10/32" >/dev/null \
    && printf '%s\n' "${b_out}" | grep "10.202.255.20/32" >/dev/null \
    && printf '%s\n' "${b_out}" | grep "65301 65311 i" >/dev/null \
    && printf '%s\n' "${b_out}" | grep "65302 65312 i" >/dev/null \
    && ! printf '%s\n' "${b_out}" | grep -E "65201 65301 i|65202 65302 i" >/dev/null; then
    t_conv="$(( $(date +%s) - t_conv0 ))"
    break
  fi
  sleep 1
done

if [[ -z "${t_conv}" ]]; then
  printf '[h6] ERRO: AS_PATH via FRR no nó (65301 65311 / 65302 65312) não convergiu na %s\n' "${BORDER}" >&2
  docker exec "${BORDER}" vtysh -c "show ip bgp" >&2 || true
  for dnode in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
    dc_pod="$(h6_kctl -n kube-system get pods -l k8s-app=cilium --field-selector "spec.nodeName=${dnode}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    df_pod="$(h6_kctl -n kube-system get pods -l app=frr-node --field-selector "spec.nodeName=${dnode}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    printf '=== DIAG %s ===\n' "${dnode}" >&2
    [[ -n "${dc_pod}" ]] && h6_kctl -n kube-system exec "${dc_pod}" -c cilium-agent -- cilium-dbg bgp peers >&2 || true
    [[ -n "${df_pod}" ]] && h6_kctl -n kube-system exec "${df_pod}" -- vtysh -c "show bgp ipv4 unicast summary" -c "show bgp ipv4 unicast" >&2 || true
    [[ -n "${df_pod}" ]] && h6_kctl -n kube-system exec "${df_pod}" -- cat /var/log/frr/frr.log >&2 || true
  done
  exit 1
fi
printf '[h6] Convergência Cilium GoBGP -> FRR local -> Fabric -> %s concluída em %ss\n' "${BORDER}" "${t_conv}"

# 5. Evidência nos nós: cilium-dbg bgp peers, vtysh do frr-node e invariante R6 (zero rotas proto bgp no kernel)
for node in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
  printf '\n=== [h6] Nó %s: cilium-dbg bgp peers & route-policies ===\n' "${node}"
  c_pod="$(h6_kctl -n kube-system get pods -l k8s-app=cilium --field-selector "spec.nodeName=${node}" -o jsonpath='{.items[0].metadata.name}')"
  h6_kctl -n kube-system exec "${c_pod}" -c cilium-agent -- cilium-dbg bgp peers

  printf '\n=== [h6] Nó %s: frr-node vtysh show bgp ipv4 unicast summary & RIB ===\n' "${node}"
  f_pod="$(h6_kctl -n kube-system get pods -l app=frr-node --field-selector "spec.nodeName=${node}" -o jsonpath='{.items[0].metadata.name}')"
  h6_kctl -n kube-system exec "${f_pod}" -- vtysh -c "show bgp ipv4 unicast summary" -c "show bgp ipv4 unicast"

  bgp_kernel_routes="$(docker exec "${node}" ip -4 route show proto bgp 2>/dev/null | wc -l | tr -d '[:space:]')"
  printf '[h6] Nó %s: rotas proto bgp instaladas no kernel Linux (invariante R6): %s (esperado 0)\n' "${node}" "${bgp_kernel_routes}"
  if [[ "${bgp_kernel_routes}" -ne 0 ]]; then
    printf '[h6] ERRO (R6 violado): FRR instalou %s rotas BGP no kernel de %s\n' "${bgp_kernel_routes}" "${node}" >&2
    exit 1
  fi
done

printf '\n=== [h6] Border1 (%s): show ip bgp e ECMP via FRR no nó ===\n' "${BORDER}"
docker exec "${BORDER}" vtysh -c "show ip bgp" -c "show ip route ${POD_VIP}" -c "show ip route ${VM_VIP}"

# 6. Validar 30/30 conexões HTTP a partir de clab-p003-gw-fabric-client (198.19.0.10) para Pod VIP e VM VIP
for _ in $(seq 1 30); do
  if docker exec "${CLIENT}" curl -s --noproxy '*' --max-time 2 "http://${VM_VIP}:8080/" 2>/dev/null | grep -q "VM_OK"; then
    break
  fi
  sleep 1
done

pod_vip_ok=0
vm_vip_ok=0
for _ in $(seq 1 30); do
  p_hit=0
  for _ in 1 2 3; do
    if docker exec "${CLIENT}" curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --connect-timeout 2 --max-time 3 -H 'Host: echo.p003.study' "http://${POD_VIP}:8080/" 2>/dev/null | grep -q '^200$'; then
      p_hit=1
      break
    fi
    sleep 0.2
  done
  if [[ "${p_hit}" -eq 1 ]]; then
    pod_vip_ok=$((pod_vip_ok + 1))
  fi

  v_hit=0
  for _ in 1 2 3; do
    if docker exec "${CLIENT}" curl -s --noproxy '*' --connect-timeout 2 --max-time 3 "http://${VM_VIP}:8080/" 2>/dev/null | grep -q "VM_OK"; then
      v_hit=1
      break
    fi
    sleep 0.2
  done
  if [[ "${v_hit}" -eq 1 ]]; then
    vm_vip_ok=$((vm_vip_ok + 1))
  fi
done
printf '[h6] Alcance via FRR no nó (%s): Pod VIP (%s:8080)=%s/30 OK, KubeVirt VM VIP (%s:8080)=%s/30 OK\n' \
  "${CLIENT}" "${POD_VIP}" "${pod_vip_ok}" "${VM_VIP}" "${vm_vip_ok}"
if [[ "${pod_vip_ok}" -ne 30 ]] || [[ "${vm_vip_ok}" -ne 30 ]]; then
  printf '[h6] ERRO: falha no alcance externo via FRR no nó (pod_vip=%s/30, vm_vip=%s/30)\n' "${pod_vip_ok}" "${vm_vip_ok}" >&2
  exit 1
fi

# 7. Controle negativo: shutdown do peer local CILIUM (10.255.255.1) nos nós retira 10.202.255.20/32 da border1
printf '\n=== [h6] Controle negativo: shutdown de neighbor CILIUM (10.255.255.1) nos nós ===\n'
t_neg0="$(date +%s)"
for node in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
  f_pod="$(h6_kctl -n kube-system get pods -l app=frr-node --field-selector "spec.nodeName=${node}" -o jsonpath='{.items[0].metadata.name}')"
  e_ip="$(docker exec "${node}" ip -4 -o addr show dev eth1 | awk '{split($4,a,"/"); print a[1]}' | head -n 1)"
  f_asn=65301
  if [[ "${e_ip}" == 10.30.2.* ]]; then
    f_asn=65302
  fi
  h6_kctl -n kube-system exec "${f_pod}" -- vtysh \
    -c "conf t" \
    -c "router bgp ${f_asn}" \
    -c "neighbor CILIUM shutdown" \
    -c "end" >/dev/null
done

t_withdraw=""
for _ in $(seq 1 30); do
  if ! docker exec "${BORDER}" vtysh -c "show ip bgp ${VM_VIP}/32" 2>/dev/null | grep -q "${VM_VIP}/32"; then
    t_withdraw="$(( $(date +%s) - t_neg0 ))"
    break
  fi
  sleep 1
done

neg_ok=0
for _ in $(seq 1 10); do
  if docker exec "${CLIENT}" curl -s --noproxy '*' --connect-timeout 1 --max-time 1 "http://${VM_VIP}:8080/" 2>/dev/null | grep -q "VM_OK"; then
    neg_ok=$((neg_ok + 1))
  fi
done
printf '[h6] Controle negativo (peer CILIUM 10.255.255.1 em shutdown nos nós): withdraw_s=%ss, probes=%s/10 (esperado 0/10)\n' \
  "${t_withdraw:-NA}" "${neg_ok}"
if [[ -z "${t_withdraw}" ]] || [[ "${neg_ok}" -ne 0 ]]; then
  printf '[h6] ERRO no controle negativo: withdraw_s=%s, probes=%s/10\n' "${t_withdraw:-NA}" "${neg_ok}" >&2
  exit 1
fi

# Reabilitar neighbor 127.0.0.1 nos nós e confirmar reconvergência
for node in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
  f_pod="$(h6_kctl -n kube-system get pods -l app=frr-node --field-selector "spec.nodeName=${node}" -o jsonpath='{.items[0].metadata.name}')"
  e_ip="$(docker exec "${node}" ip -4 -o addr show dev eth1 | awk '{split($4,a,"/"); print a[1]}' | head -n 1)"
  f_asn=65301
  if [[ "${e_ip}" == 10.30.2.* ]]; then
    f_asn=65302
  fi
  h6_kctl -n kube-system exec "${f_pod}" -- vtysh \
    -c "conf t" \
    -c "router bgp ${f_asn}" \
    -c "no neighbor CILIUM shutdown" \
    -c "end" >/dev/null
done

for _ in $(seq 1 30); do
  if docker exec "${BORDER}" vtysh -c "show ip bgp ${VM_VIP}/32" 2>/dev/null | grep -q "${VM_VIP}/32"; then
    break
  fi
  sleep 1
done

reconv_ok=0
for _ in $(seq 1 10); do
  r_hit=0
  for _ in 1 2 3; do
    if docker exec "${CLIENT}" curl -s --noproxy '*' --connect-timeout 2 --max-time 3 "http://${VM_VIP}:8080/" 2>/dev/null | grep -q "VM_OK"; then
      r_hit=1
      break
    fi
    sleep 0.2
  done
  if [[ "${r_hit}" -eq 1 ]]; then
    reconv_ok=$((reconv_ok + 1))
  fi
done
printf '[h6] Reconvergência pós-controle negativo (%s -> %s:8080): %s/10 OK\n' "${CLIENT}" "${VM_VIP}" "${reconv_ok}"
if [[ "${reconv_ok}" -ne 10 ]]; then
  printf '[h6] ERRO na reconvergência pós-controle negativo: %s/10\n' "${reconv_ok}" >&2
  exit 1
fi

# 8. Rollback determinístico (se H6_KEEP_FRR=0) e verificação de saúde dos clusters
h6_cleanup

if [[ "${H6_KEEP_FRR}" != "1" ]]; then
  h6_run "${LABCTL_BIN}" p003-gw verify
  h6_run "${LABCTL_BIN}" k01 verify
fi

printf 'H6 PASS (Braço Cilium B FRR no nó CONFIRMED): conv_s=%ss, r6_kernel_bgp_routes=0, pod_vip=%s/30, vm_vip=%s/30, neg_withdraw_s=%ss (0/10 -> 10/10), keep_frr=%s.\n' \
  "${t_conv}" "${pod_vip_ok}" "${vm_vip_ok}" "${t_withdraw}" "${H6_KEEP_FRR}"
