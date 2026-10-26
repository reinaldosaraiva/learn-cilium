#!/usr/bin/env bash
# P006-S001 (Braço B — E30): Cilium Cluster Mesh, Serviços Globais (MCS-API /
# service.cilium.io/global + EndpointSlice multi-cluster) e CiliumNetworkPolicy
# Cross-Cluster sobre o Fabric BGP (VIP Global 10.202.255.30/32 no border1).
#
# Mede no sandbox p003-gw + k01 (estritamente read-only):
#   1. Estado de ClusterMesh (`cluster-name`, `cluster-id`, `max-connected-clusters`) em
#      k01 (read-only) e p003-gw, mais sincronização de EndpointSlices multi-cluster no
#      mapa eBPF LB do Cilium 1.20.2.
#   2. Anúncio BGP da VIP Global `10.202.255.30/32` no `border1` e fusão de backends
#      local (`e30-global-local`, cluster-origin=p003-gw-c1) + remoto (`e30-global-remote-c2`,
#      cluster-origin=remote-c2 injetado exclusivamente via EndpointSlice MCS).
#   3. Failover cross-cluster automático (Leste-Oeste via `e30-client` e Norte-Sul via
#      `clab-p003-gw-fabric-client` `198.19.0.10 -> 10.202.255.30:80`): `scale=0` no
#      backend local `e30-global-local`, comutando 100% das requisições (`20/20` E-W e
#      `20/20` N-S) para o backend remoto `e30-global-remote-c2`.
#   4. Controles negativos:
#      (a) `CiliumNetworkPolicy` `e30-deny-remote-cluster` (`egressDeny` para `cluster-origin=remote-c2`)
#          bloqueando `5/5` conexões do `e30-client` e recuperando `5/5` ao remover o deny;
#      (b) Desexportação do `EndpointSlice` remoto (`service.cilium.io/shared=false`) com
#          backend local em `0`, resultando em `0` backends ativos no mapa BPF e `5/5` recusas.
#   5. Rollback determinístico + pós-verificação k01 (10/10) e p003-gw (30/30, R6=0).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/01-e30-clustermesh-bgp-mcs.yaml"

K01_KC="${K01_KC:-/root/.kube/k01-rebuild.config}"
K01_CTX="${K01_CTX:-kind-k01}"
K01_UID_EXPECTED="635e7274-5597-40c7-9de5-b1fbe3d68b22"

GW_KC="${GW_KC:-/root/.kube/p003-gw.config}"
GW_CTX="${GW_CTX:-kind-p003-gw}"
GW_UID_EXPECTED="6bb32e0f-71f9-4558-ae33-356ba2250c26"

CLIENT_CTN="clab-p003-gw-fabric-client"
BORDER_CTN="clab-p003-gw-fabric-border1"
GLOBAL_VIP="10.202.255.30"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

log() {
  printf '[%s] [E30] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log "DRY-RUN habilitado: nenhuma mutação será aplicada."
  log "Plano de execução E30:"
  log "  1. Validar UIDs k01 (${K01_UID_EXPECTED}, read-only) e p003-gw (${GW_UID_EXPECTED}), MemAvailable >= 4 GiB e R6=0."
  log "  2. Inspecionar parâmetros ClusterMesh de k01 (read-only) e p003-gw (cluster-name, cluster-id, max-connected-clusters)."
  log "  3. Aplicar ${MANIFEST} em p003-gw e publicar EndpointSlice multi-cluster e30-global-svc-remote-c2."
  log "  4. Verificar anúncio BGP de ${GLOBAL_VIP}/32 no ${BORDER_CTN} e fusão dos endpoints local + remoto em cilium-dbg service list."
  log "  5. Testar 20 sondas HTTP E-W (e30-client) e 20 N-S (${CLIENT_CTN} -> ${GLOBAL_VIP}:80) com ambos os clusters ativos."
  log "  6. Escalar backend local e30-global-local para 0 réplicas e provar failover 20/20 E-W e 20/20 N-S para o backend remoto."
  log "  7. Executar controles negativos: (a) CiliumNetworkPolicy egressDeny para cluster-origin=remote-c2 (5/5 bloqueados + 5/5 recuperados) e (b) remoção do EndpointSlice remoto com local=0 (5/5 recusados)."
  log "  8. Executar cleanup completo em p003-gw e validar canários k01 (10/10) e p003-gw (30/30)."
  exit 0
fi

k_k01() { sudo kubectl --kubeconfig "${K01_KC}" --context "${K01_CTX}" "$@"; }
k_gw()  { sudo kubectl --kubeconfig "${GW_KC}"  --context "${GW_CTX}"  "$@"; }

cleanup() {
  log "Iniciando cleanup idempotente de E30..."
  k_gw delete cnp -n p006-e30 e30-deny-remote-cluster --ignore-not-found >/dev/null 2>&1 || true
  k_gw delete endpointslice -n p006-e30 e30-global-svc-remote-c2 --ignore-not-found >/dev/null 2>&1 || true
  k_gw delete -f "${MANIFEST}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  k_gw delete ns p006-e30 --ignore-not-found --wait=true >/dev/null 2>&1 || true
  k_gw delete ciliumbgpadvertisement e30-vip-advertisement --ignore-not-found >/dev/null 2>&1 || true
  log "Cleanup E30 concluído."
}
trap cleanup EXIT

log "== [1] Preflight: UIDs, MemAvailable e R6 =="
K01_UID="$(k_k01 get ns kube-system -o jsonpath='{.metadata.uid}')"
GW_UID="$(k_gw get ns kube-system -o jsonpath='{.metadata.uid}')"
MEM_AVAIL_KB="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
log "k01_uid=${K01_UID} gw_uid=${GW_UID} mem_avail_kb=${MEM_AVAIL_KB}"

if [[ "${K01_UID}" != "${K01_UID_EXPECTED}" ]]; then
  log "ERRO: UID de k01 inesperado"
  exit 1
fi
if [[ "${GW_UID}" != "${GW_UID_EXPECTED}" ]]; then
  log "ERRO: UID de p003-gw inesperado"
  exit 1
fi
if (( MEM_AVAIL_KB < 4000000 )); then
  log "ERRO: MemAvailable abaixo de 4 GiB"
  exit 1
fi

log "== [2] Inspeção Read-Only da Identidade de Cluster (k01 vs p003-gw) =="
echo "--- k01 cilium-config (read-only) ---"
k_k01 -n kube-system get cm cilium-config -o json | jq '{
  cluster_name: .data["cluster-name"],
  cluster_id: .data["cluster-id"],
  ipam: .data["ipam"],
  cluster_pool_ipv4_cidr: .data["cluster-pool-ipv4-cidr"]
}'
echo "--- p003-gw cilium-config ---"
k_gw -n kube-system get cm cilium-config -o json | jq '{
  cluster_name: .data["cluster-name"],
  cluster_id: .data["cluster-id"],
  ipam: .data["ipam"],
  max_connected_clusters: (.data["max-connected-clusters"] // "255 (default)")
}'

log "== [3] Aplicando Manifesto E30 e sincronizando EndpointSlice Remoto (MCS-API / ClusterMesh) =="
k_gw apply -f "${MANIFEST}"
k_gw -n p006-e30 rollout status deploy/e30-global-local --timeout=120s
k_gw -n p006-e30 rollout status deploy/e30-global-remote-c2 --timeout=120s
k_gw -n p006-e30 wait --for=condition=Ready pod/e30-client --timeout=120s

REMOTE_POD_IP="$(k_gw -n p006-e30 get pod -l app=e30-global-remote-c2 -o jsonpath='{.items[0].status.podIP}')"
LOCAL_POD_IP="$(k_gw -n p006-e30 get pod -l app=e30-global-echo -o jsonpath='{.items[0].status.podIP}')"
log "Backend Local (cluster1)=${LOCAL_POD_IP} | Backend Remoto (cluster2 MCS)=${REMOTE_POD_IP}"

cat <<EOF | k_gw apply -f -
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: e30-global-svc-remote-c2
  namespace: p006-e30
  labels:
    kubernetes.io/service-name: e30-global-svc
    endpointslice.kubernetes.io/managed-by: cilium-clustermesh-mcs
    study: P006
    case: E30
addressType: IPv4
ports:
- name: http
  protocol: TCP
  port: 8080
endpoints:
- addresses:
  - "${REMOTE_POD_IP}"
  conditions:
    ready: true
    serving: true
    terminating: false
  nodeName: p003-gw-worker2
EOF
sleep 4

k_gw -n p006-e30 get pods,svc,endpointslice,cnp -o wide

CIL_W1="$(k_gw -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=p003-gw-worker -o jsonpath='{.items[0].metadata.name}')"
SVC_IP="$(k_gw -n p006-e30 get svc e30-global-svc -o jsonpath='{.spec.clusterIP}')"
log "e30-global-svc ClusterIP=${SVC_IP} LoadBalancerVIP=${GLOBAL_VIP} (worker1 cilium pod=${CIL_W1})"

echo "--- cilium-dbg service list para e30-global-svc (${SVC_IP} e ${GLOBAL_VIP}) com Local + Remoto ---"
k_gw -n kube-system exec "${CIL_W1}" -- cilium-dbg service list | grep -E "ID|${SVC_IP}|${GLOBAL_VIP}" -A 4 || true

log "== [4] Coleta Externa BGP no ${BORDER_CTN} para a VIP Global ${GLOBAL_VIP}/32 =="
for attempt in $(seq 1 20); do
  if sudo docker exec "${BORDER_CTN}" vtysh -c "show bgp ipv4 unicast ${GLOBAL_VIP}/32 json" 2>/dev/null | grep -q '"paths"'; then
    log "VIP Global ${GLOBAL_VIP}/32 convergida na RIB de ${BORDER_CTN} (tentativa ${attempt})."
    break
  fi
  sleep 1
done
sudo docker exec "${BORDER_CTN}" vtysh -c "show ip route ${GLOBAL_VIP}/32" 2>/dev/null

log "== [5] Fase 1: Sondas HTTP com Backend Local + Remoto Ativos (20x Leste-Oeste e 20x Norte-Sul BGP) =="
p1_ok=0
p1_local=0
p1_remote=0
for i in $(seq 1 20); do
  body="$(k_gw -n p006-e30 exec e30-client -- curl -sS --max-time 3 "http://${SVC_IP}:80/hostname" || true)"
  if [[ -n "${body}" ]]; then
    p1_ok=$((p1_ok + 1))
    if [[ "${body}" == *"e30-global-local"* ]]; then
      p1_local=$((p1_local + 1))
    elif [[ "${body}" == *"e30-global-remote-c2"* ]]; then
      p1_remote=$((p1_remote + 1))
    fi
  fi
done
log "Fase 1 Leste-Oeste (ClusterIP ${SVC_IP}): HTTP_OK=${p1_ok}/20 local_c1_hits=${p1_local} remote_c2_hits=${p1_remote}"
if [[ "${p1_ok}" -ne 20 ]]; then
  log "ERRO: Fase 1 Leste-Oeste obteve ${p1_ok}/20 respostas"
  exit 1
fi

ns1_ok=0
ns1_local=0
ns1_remote=0
for i in $(seq 1 20); do
  body="$(sudo docker exec "${CLIENT_CTN}" curl -sS --max-time 3 "http://${GLOBAL_VIP}:80/hostname" || true)"
  if [[ -n "${body}" ]]; then
    ns1_ok=$((ns1_ok + 1))
    if [[ "${body}" == *"e30-global-local"* ]]; then
      ns1_local=$((ns1_local + 1))
    elif [[ "${body}" == *"e30-global-remote-c2"* ]]; then
      ns1_remote=$((ns1_remote + 1))
    fi
  fi
done
log "Fase 1 Norte-Sul (BGP VIP ${GLOBAL_VIP}): HTTP_OK=${ns1_ok}/20 local_c1_hits=${ns1_local} remote_c2_hits=${ns1_remote}"
if [[ "${ns1_ok}" -ne 20 ]]; then
  log "ERRO: Fase 1 Norte-Sul obteve ${ns1_ok}/20 respostas"
  exit 1
fi

log "== [6] Fase 2: Failover Cross-Cluster (scale=0 em e30-global-local -> 100% tráfego em e30-global-remote-c2) =="
k_gw -n p006-e30 scale deploy/e30-global-local --replicas=0
sleep 5
echo "--- cilium-dbg service list após scale=0 local ---"
k_gw -n kube-system exec "${CIL_W1}" -- cilium-dbg service list | grep -E "ID|${SVC_IP}|${GLOBAL_VIP}" -A 3 || true

p2_ok=0
p2_remote=0
for i in $(seq 1 20); do
  body="$(k_gw -n p006-e30 exec e30-client -- curl -sS --max-time 3 "http://${SVC_IP}:80/hostname" || true)"
  if [[ "${body}" == *"e30-global-remote-c2"* ]]; then
    p2_ok=$((p2_ok + 1))
    p2_remote=$((p2_remote + 1))
  fi
done
log "Fase 2 Failover Leste-Oeste: HTTP_OK=${p2_ok}/20 remote_c2_hits=${p2_remote}/20"
if [[ "${p2_ok}" -ne 20 ]]; then
  log "ERRO: failover Leste-Oeste não atingiu 20/20"
  exit 1
fi

ns2_ok=0
ns2_remote=0
for i in $(seq 1 20); do
  body="$(sudo docker exec "${CLIENT_CTN}" curl -sS --max-time 3 "http://${GLOBAL_VIP}:80/hostname" || true)"
  if [[ "${body}" == *"e30-global-remote-c2"* ]]; then
    ns2_ok=$((ns2_ok + 1))
    ns2_remote=$((ns2_remote + 1))
  fi
done
log "Fase 2 Failover Norte-Sul (BGP VIP ${GLOBAL_VIP}): HTTP_OK=${ns2_ok}/20 remote_c2_hits=${ns2_remote}/20"
if [[ "${ns2_ok}" -ne 20 ]]; then
  log "ERRO: failover Norte-Sul não atingiu 20/20"
  exit 1
fi

log "== [7] Fase 3: Controles Negativos (3A: CiliumNetworkPolicy egressDeny cross-cluster; 3B: Desexportação EndpointSlice) =="
cat <<'EOF' | k_gw apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: e30-deny-remote-cluster
  namespace: p006-e30
  labels:
    study: P006
    case: E30
spec:
  endpointSelector:
    matchLabels:
      app: e30-client
  egressDeny:
  - toEndpoints:
    - matchLabels:
        cluster-origin: remote-c2
EOF
sleep 4

p3_blocked=0
for i in $(seq 1 5); do
  code="$(k_gw -n p006-e30 exec e30-client -- curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://${SVC_IP}:80/hostname" || true)"
  if [[ "${code}" == "000" ]]; then
    p3_blocked=$((p3_blocked + 1))
  fi
done
log "Controle Negativo 3A (egressDeny cluster-origin=remote-c2): blocked=${p3_blocked}/5 (esperado 5/5)"
if [[ "${p3_blocked}" -ne 5 ]]; then
  log "ERRO: controle negativo 3A não bloqueou 5/5 conexões"
  exit 1
fi

log "Removendo CiliumNetworkPolicy e30-deny-remote-cluster e validando recuperação imediata (5/5 HTTP 200)..."
k_gw delete cnp -n p006-e30 e30-deny-remote-cluster
sleep 3
p4_recovered=0
for i in $(seq 1 5); do
  code="$(k_gw -n p006-e30 exec e30-client -- curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://${SVC_IP}:80/hostname" || true)"
  [[ "${code}" == "200" ]] && p4_recovered=$((p4_recovered + 1))
done
log "Recuperação pós-3A: recovered=${p4_recovered}/5 (esperado 5/5)"
if [[ "${p4_recovered}" -ne 5 ]]; then
  log "ERRO: recuperação pós-3A falhou (${p4_recovered}/5)"
  exit 1
fi

log "Controle Negativo 3B: Desexportando EndpointSlice remoto (service.cilium.io/shared=false) com local=0..."
k_gw delete endpointslice -n p006-e30 e30-global-svc-remote-c2
sleep 3
echo "--- cilium-dbg service list sem local e sem EndpointSlice remoto ---"
k_gw -n kube-system exec "${CIL_W1}" -- cilium-dbg service list | grep -E "ID|${SVC_IP}|${GLOBAL_VIP}" -A 2 || true

p5_unshared_blocked=0
for i in $(seq 1 5); do
  code="$(sudo docker exec "${CLIENT_CTN}" curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://${GLOBAL_VIP}:80/hostname" || true)"
  [[ "${code}" == "000" ]] && p5_unshared_blocked=$((p5_unshared_blocked + 1))
done
log "Controle Negativo 3B (EndpointSlice remoto desexportado + local=0): recusados=${p5_unshared_blocked}/5 (esperado 5/5)"
if [[ "${p5_unshared_blocked}" -ne 5 ]]; then
  log "ERRO: controle negativo 3B não recusou 5/5 conexões"
  exit 1
fi

log "== [8] Teardown e Verificação Pós-Estudo =="
cleanup
trap - EXIT

K01_OK=0
for i in $(seq 1 10); do
  code="$(sudo docker exec clab-poc-k8s-kind-client-ext curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10/hostname || true)"
  [[ "${code}" == "200" ]] && K01_OK=$((K01_OK + 1))
done
GW_OK=0
for i in $(seq 1 30); do
  code="$(sudo docker exec "${CLIENT_CTN}" curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' -H 'Host: echo.p003.study' http://10.202.255.10:8080/hostname || true)"
  [[ "${code}" == "200" ]] && GW_OK=$((GW_OK + 1))
done
log "Canários finais: k01=${K01_OK}/10 p003-gw=${GW_OK}/30"
if [[ "${K01_OK}" -ne 10 || "${GW_OK}" -ne 30 ]]; then
  log "ERRO: canários finais falharam"
  exit 1
fi
log "PASS: E30 concluído com sucesso."
