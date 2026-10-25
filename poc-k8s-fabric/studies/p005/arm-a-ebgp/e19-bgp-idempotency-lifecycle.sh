#!/usr/bin/env bash
# ==============================================================================
# P005-S001 (Braço A - Estudo E19): Ciclo de Vida da Configuração BGP:
# Idempotência (10x apply), Zero Resíduo no Teardown e Reuso Imediato de VIP
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/manifests"
if [[ -d "${REPO_ROOT}/studies/p003/base/bgp" ]]; then
  BASE_BGP_DIR="${REPO_ROOT}/studies/p003/base/bgp"
else
  BASE_BGP_DIR="/opt/poc-k8s-fabric-studies/studies/p003/base/bgp"
fi

P003_KUBECONFIG="${P003_KUBECONFIG:-/root/.kube/p003-gw.config}"
P003_CONTEXT="${P003_CONTEXT:-kind-p003-gw}"
P003_EXPECTED_UID="6bb32e0f-71f9-4558-ae33-356ba2250c26"

K01_KUBECONFIG="${K01_KUBECONFIG:-/root/.kube/k01-rebuild.config}"
K01_CONTEXT="${K01_CONTEXT:-kind-k01}"
K01_EXPECTED_UID="635e7274-5597-40c7-9de5-b1fbe3d68b22"

BORDER_CONTAINER="${BORDER_CONTAINER:-clab-p003-gw-fabric-border1}"
CLIENT_CONTAINER="${CLIENT_CONTAINER:-clab-p003-gw-fabric-client}"
TARGET_VIP="10.202.255.190"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

log() {
  printf '[E19][%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "DRY-RUN [E19]: 1. Verificar UIDs de k01 (${K01_EXPECTED_UID}) e p003-gw (${P003_EXPECTED_UID}) e estado de border1/client."
  echo "DRY-RUN [E19]: 2. Implantar backends e19-echo-a e e19-echo-b em p005-e19 e aplicar bundle BGP + Service svc-a (VIP ${TARGET_VIP}/32)."
  echo "DRY-RUN [E19]: 3. Reaplicar os CRDs BGP base + bundle E19 10 vezes consecutivas (iter=1..10) e comparar 3 snapshots normalizados (route-policies, advertised routes, border1 RIB JSON) -> diff=0 e 0 flaps."
  echo "DRY-RUN [E19]: 4. Remover bundle svc-a e auditar zero resíduo (0 rotas anunciadas, 0 route-policies órfãs, {} na RIB de border1, R6=0 rotas proto bgp no kernel)."
  echo "DRY-RUN [E19]: 5. Reutilizar imediatamente o mesmo VIP ${TARGET_VIP}/32 no Service svc-b e validar 30/30 respostas HTTP de e19-echo-b a partir de ${CLIENT_CONTAINER}."
  echo "DRY-RUN [E19]: 6. Rollback completo de p005-e19 e e19-vip-advertisement."
  exit 0
fi

SNAP_DIR="$(mktemp -d /tmp/p005-e19-snaps.XXXXXX)"

cleanup() {
  log "Executando limpeza/rollback do estudo E19..."
  kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" \
    delete ciliumbgpadvertisement e19-vip-advertisement --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" \
    delete namespace p005-e19 --wait=true --timeout=90s --ignore-not-found=true >/dev/null 2>&1 || true
  rm -rf "${SNAP_DIR}" || true
}
trap cleanup EXIT

verify_guards() {
  log "Verificando guardas de cluster (k01 e p003-gw)..."
  local k01_uid p003_uid
  k01_uid="$(kubectl --kubeconfig "${K01_KUBECONFIG}" --context "${K01_CONTEXT}" get namespace kube-system -o jsonpath='{.metadata.uid}')"
  p003_uid="$(kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" get namespace kube-system -o jsonpath='{.metadata.uid}')"
  if [[ "${k01_uid}" != "${K01_EXPECTED_UID}" ]]; then
    echo "ERRO: k01 UID=${k01_uid} difere do esperado (${K01_EXPECTED_UID})" >&2
    exit 1
  fi
  if [[ "${p003_uid}" != "${P003_EXPECTED_UID}" ]]; then
    echo "ERRO: p003-gw UID=${p003_uid} difere do esperado (${P003_EXPECTED_UID})" >&2
    exit 1
  fi
  log "Guardas OK: k01=${k01_uid}, p003-gw=${p003_uid}"
}

capture_snapshots() {
  local iter="$1"
  local pol_out="${SNAP_DIR}/route-policies-iter-${iter}.txt"
  local adv_out="${SNAP_DIR}/advertised-routes-iter-${iter}.txt"
  local rib_out="${SNAP_DIR}/border1-bgp-iter-${iter}.json"

  : > "${pol_out}"
  : > "${adv_out}"
  for node in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
    local pod
    pod="$(kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" -n kube-system get pods \
      -l k8s-app=cilium --field-selector spec.nodeName="${node}" -o jsonpath='{.items[0].metadata.name}')"
    printf '=== NODE: %s ===\n' "${node}" >> "${pol_out}"
    kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" -n kube-system exec "${pod}" -c cilium-agent -- \
      cilium-dbg bgp route-policies \
      | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' >> "${pol_out}"

    printf '=== NODE: %s ===\n' "${node}" >> "${adv_out}"
    kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" -n kube-system exec "${pod}" -c cilium-agent -- \
      cilium-dbg bgp routes advertised ipv4 unicast \
      | sed -E 's/[[:space:]]+[0-9]+(d|h|m|s|ms)([0-9]+(d|h|m|s|ms))*([[:space:]]+|$)/ <AGE> /g; s/[[:space:]]+/ /g; s/^ //; s/ $//' >> "${adv_out}"
  done

  docker exec "${BORDER_CONTAINER}" vtysh -c "show bgp ipv4 unicast ${TARGET_VIP}/32 json" 2>/dev/null \
    | python3 -c '
import json, sys
data = json.load(sys.stdin)
for p in data.get("paths", []):
    if "lastUpdate" in p and isinstance(p["lastUpdate"], dict):
        p["lastUpdate"]["epoch"] = "<NORMALIZED_EPOCH>"
        p["lastUpdate"]["string"] = "<NORMALIZED_UPTIME>"
json.dump(data, sys.stdout, indent=2, sort_keys=True)
print()
' > "${rib_out}"
}

verify_guards

log "=== PASSO 1: Implantando workloads e19-echo-a e e19-echo-b ==="
kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" apply -f "${MANIFEST_DIR}/01-e19-workloads.yaml"
kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" -n p005-e19 rollout status deployment/e19-echo-a --timeout=90s
kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" -n p005-e19 rollout status deployment/e19-echo-b --timeout=90s

log "=== PASSO 2: Aplicando bundle inicial (CRDs BGP base + svc-a VIP ${TARGET_VIP}/32) ==="
kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" apply \
  -f "${BASE_BGP_DIR}/" \
  -f "${MANIFEST_DIR}/02-e19-svc-a-bundle.yaml"

log "Aguardando convergência inicial do VIP ${TARGET_VIP}/32 em ${BORDER_CONTAINER}..."
for attempt in $(seq 1 30); do
  if docker exec "${BORDER_CONTAINER}" vtysh -c "show bgp ipv4 unicast ${TARGET_VIP}/32 json" 2>/dev/null | grep -q '"paths"'; then
    log "VIP ${TARGET_VIP}/32 convergido na RIB de ${BORDER_CONTAINER} na tentativa ${attempt}."
    sleep 4
    break
  fi
  sleep 1
done

log "Validando conectividade HTTP inicial para svc-a (${TARGET_VIP}:8080)..."
SVC_A_OK=0
for i in $(seq 1 10); do
  resp="$(docker exec "${CLIENT_CONTAINER}" curl -sS --max-time 2 "http://${TARGET_VIP}:8080/hostname" || true)"
  if [[ "${resp}" == e19-echo-a-* ]]; then
    SVC_A_OK=$((SVC_A_OK + 1))
  fi
done
echo "SVC_A_INITIAL_HTTP_OK=${SVC_A_OK}/10"
if [[ "${SVC_A_OK}" -lt 10 ]]; then
  echo "ERRO: Conectividade inicial para svc-a falhou (${SVC_A_OK}/10)" >&2
  exit 1
fi

log "=== PASSO 3: Executando 10 reaplicações consecutivas (Teste de Idempotência 10x) ==="
DIFF_POL_TOTAL=0
DIFF_ADV_TOTAL=0
DIFF_RIB_TOTAL=0

for iter in $(seq 1 10); do
  kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" apply \
    -f "${BASE_BGP_DIR}/" \
    -f "${MANIFEST_DIR}/02-e19-svc-a-bundle.yaml" >/dev/null
  capture_snapshots "${iter}"

  if [[ "${iter}" -gt 1 ]]; then
    d_pol="$(( $( (diff -u "${SNAP_DIR}/route-policies-iter-1.txt" "${SNAP_DIR}/route-policies-iter-${iter}.txt" || true) | wc -l ) ))"
    d_adv="$(( $( (diff -u "${SNAP_DIR}/advertised-routes-iter-1.txt" "${SNAP_DIR}/advertised-routes-iter-${iter}.txt" || true) | wc -l ) ))"
    d_rib="$(( $( (diff -u "${SNAP_DIR}/border1-bgp-iter-1.json" "${SNAP_DIR}/border1-bgp-iter-${iter}.json" || true) | wc -l ) ))"
    DIFF_POL_TOTAL=$((DIFF_POL_TOTAL + d_pol))
    DIFF_ADV_TOTAL=$((DIFF_ADV_TOTAL + d_adv))
    DIFF_RIB_TOTAL=$((DIFF_RIB_TOTAL + d_rib))
    echo "ITER=${iter} diff_route_policies=${d_pol} diff_advertised=${d_adv} diff_border1_rib=${d_rib}"
    if [[ "${d_pol}" -gt 0 ]]; then diff -u "${SNAP_DIR}/route-policies-iter-1.txt" "${SNAP_DIR}/route-policies-iter-${iter}.txt" || true; fi
    if [[ "${d_adv}" -gt 0 ]]; then diff -u "${SNAP_DIR}/advertised-routes-iter-1.txt" "${SNAP_DIR}/advertised-routes-iter-${iter}.txt" || true; fi
    if [[ "${d_rib}" -gt 0 ]]; then diff -u "${SNAP_DIR}/border1-bgp-iter-1.json" "${SNAP_DIR}/border1-bgp-iter-${iter}.json" || true; fi
  else
    echo "ITER=1 baseline snapshots capturados."
  fi
done

echo "--- Amostra do Snapshot Iter=1 vs Iter=10 (border1 RIB JSON) ---"
cat "${SNAP_DIR}/border1-bgp-iter-10.json"
echo "IDEMPOTENCY_SUMMARY: diff_route_policies_total=${DIFF_POL_TOTAL} diff_advertised_total=${DIFF_ADV_TOTAL} diff_border1_rib_total=${DIFF_RIB_TOTAL}"

if [[ "${DIFF_POL_TOTAL}" -ne 0 || "${DIFF_ADV_TOTAL}" -ne 0 || "${DIFF_RIB_TOTAL}" -ne 0 ]]; then
  echo "ERRO: Divergência detectada durante as 10 reaplicações idempotentes!" >&2
  exit 1
fi

log "=== PASSO 4: Teardown de svc-a e Auditoria de Zero Resíduo ==="
kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" delete service svc-a -n p005-e19 --wait=true
kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" delete ciliumbgpadvertisement e19-vip-advertisement --wait=true

WITHDRAW_SECONDS=0
for w_attempt in $(seq 1 25); do
  if ! docker exec "${BORDER_CONTAINER}" vtysh -c "show bgp ipv4 unicast ${TARGET_VIP}/32 json" 2>/dev/null | grep -q '"paths"'; then
    WITHDRAW_SECONDS="${w_attempt}"
    log "BGP WITHDRAW convergido em ${BORDER_CONTAINER} em ${WITHDRAW_SECONDS}s."
    break
  fi
  sleep 1
done

RESIDUE_ADV=0
RESIDUE_POL=0
RESIDUE_KERNEL_BGP=0
for node in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
  pod="$(kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" -n kube-system get pods \
    -l k8s-app=cilium --field-selector spec.nodeName="${node}" -o jsonpath='{.items[0].metadata.name}')"
  c_adv="$(kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" -n kube-system exec "${pod}" -c cilium-agent -- \
    cilium-dbg bgp routes advertised ipv4 unicast | grep -c "${TARGET_VIP}" || true)"
  c_pol="$(kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" -n kube-system exec "${pod}" -c cilium-agent -- \
    cilium-dbg bgp route-policies | grep -Ec "e19-vip-advertisement|${TARGET_VIP}" || true)"
  c_kbgp="$(docker exec "${node}" ip -4 route show proto bgp | wc -l | tr -d ' ')"
  RESIDUE_ADV=$((RESIDUE_ADV + c_adv))
  RESIDUE_POL=$((RESIDUE_POL + c_pol))
  RESIDUE_KERNEL_BGP=$((RESIDUE_KERNEL_BGP + c_kbgp))
done

BORDER_AFTER_DELETE="$(docker exec "${BORDER_CONTAINER}" vtysh -c "show bgp ipv4 unicast ${TARGET_VIP}/32 json" 2>/dev/null)"
RESIDUE_BORDER=0
if echo "${BORDER_AFTER_DELETE}" | grep -q '"paths"'; then
  RESIDUE_BORDER=1
fi

echo "ZERO_RESIDUE_AUDIT: cilium_advertised=${RESIDUE_ADV} cilium_policies=${RESIDUE_POL} border1_rib=${RESIDUE_BORDER} kernel_proto_bgp_R6=${RESIDUE_KERNEL_BGP}"
echo "border1_json_after_delete=${BORDER_AFTER_DELETE}"

if [[ "${RESIDUE_ADV}" -ne 0 || "${RESIDUE_POL}" -ne 0 || "${RESIDUE_BORDER}" -ne 0 || "${RESIDUE_KERNEL_BGP}" -ne 0 ]]; then
  echo "ERRO: Resíduo BGP detectado após remoção de svc-a!" >&2
  exit 1
fi

log "=== PASSO 5: Reuso imediato do mesmo VIP (${TARGET_VIP}/32) pelo Service svc-b ==="
kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" apply -f "${MANIFEST_DIR}/03-e19-svc-b-bundle.yaml"

for attempt in $(seq 1 30); do
  if docker exec "${BORDER_CONTAINER}" vtysh -c "show bgp ipv4 unicast ${TARGET_VIP}/32 json" 2>/dev/null | grep -q '"paths"'; then
    log "VIP ${TARGET_VIP}/32 reinstalado na RIB de ${BORDER_CONTAINER} para svc-b na tentativa ${attempt}."
    break
  fi
  sleep 1
done

SVC_B_OK=0
SVC_A_STALE=0
for i in $(seq 1 30); do
  resp="$(docker exec "${CLIENT_CONTAINER}" curl -sS --max-time 2 "http://${TARGET_VIP}:8080/hostname" || true)"
  if [[ "${resp}" == e19-echo-b-* ]]; then
    SVC_B_OK=$((SVC_B_OK + 1))
  elif [[ "${resp}" == e19-echo-a-* ]]; then
    SVC_A_STALE=$((SVC_A_STALE + 1))
  fi
done

echo "VIP_REUSE_AUDIT: svc_b_http_ok=${SVC_B_OK}/30 svc_a_stale_responses=${SVC_A_STALE}/30"
if [[ "${SVC_B_OK}" -ne 30 || "${SVC_A_STALE}" -ne 0 ]]; then
  echo "ERRO: Reuso do VIP ${TARGET_VIP}/32 por svc-b falhou!" >&2
  exit 1
fi

log "Estudo E19 concluído com PASS."
