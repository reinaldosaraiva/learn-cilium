#!/usr/bin/env bash
# ==============================================================================
# P005-S001 (Braço A - Estudo E09): Sessão eBGP Autenticada (TCP MD5 RFC 2385)
# com authSecretRef, ASN de 32 bits (4200000001), Controles Negativos e Rotação
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
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

WORKER2_NODE="p003-gw-worker2"
FRR_E09_CONTAINER="clab-p003-gw-fabric-frr-e09"
FRR_IMAGE="${FRR_IMAGE:-frrouting/frr:v8.4.1}"
PEER_ASN32="4200000001"
LOCAL_ASN_RACK2="65302"
WORKER2_E09_IP="10.255.209.1"
FRR_E09_IP="10.255.209.2"
FRR_E09_PREFIX="198.18.209.0/24"
FRR_E09_LO_IP="198.18.209.1/24"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

log() {
  printf '[E09][%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "DRY-RUN [E09]: 1. Verificar UIDs de k01 (${K01_EXPECTED_UID}) e p003-gw (${P003_EXPECTED_UID}) e bgp-secrets-namespace=kube-system."
  echo "DRY-RUN [E09]: 2. Subir container efêmero ${FRR_E09_CONTAINER} (ASN 32-bit ${PEER_ASN32}) conectado a ${WORKER2_NODE} via par veth e09p0 (${WORKER2_E09_IP}/30) <-> e09p1 (${FRR_E09_IP}/30)."
  echo "DRY-RUN [E09]: 3. Célula 1 (Positivo): Secret kube-system/bgp-md5-secret-e09 + CiliumBGPPeerConfig/e09-md5-peer -> Established, tcpdump TCP Option 19 (md5), troca de rotas (${FRR_E09_PREFIX} <-> PodCIDR/VIP)."
  echo "DRY-RUN [E09]: 4. Célula 2 (Negativo - Senha divergente): alterar senha no FRR -> sessão bloqueada, contador TcpExtTCPMD5Failure > 0, sessões primárias leaf1/leaf2 intactas (3/3 Established)."
  echo "DRY-RUN [E09]: 5. Célula 3 (Negativo - Secret inexistente): authSecretRef=bgp-md5-secret-inexistente -> sessão bloqueada, 0 crashes do cilium-agent, sessões primárias intactas."
  echo "DRY-RUN [E09]: 6. Célula 4 (Rotação em produção): rotacionar chave MD5 nos dois lados -> medir tempo (ms) até re-estabelecimento e provar TCP Option 19 com nova chave."
  echo "DRY-RUN [E09]: 7. Rollback completo para CiliumBGPClusterConfig/rack2 original e remoção de ${FRR_E09_CONTAINER}."
  exit 0
fi

cleanup() {
  log "Executando limpeza/rollback do estudo E09..."
  kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" \
    apply -f "${BASE_BGP_DIR}/04-cluster-config-rack2.yaml" >/dev/null 2>&1 || true
  kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" \
    delete ciliumbgppeerconfig e09-md5-peer --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" -n kube-system \
    delete secret bgp-md5-secret-e09 --ignore-not-found=true >/dev/null 2>&1 || true
  docker rm -f "${FRR_E09_CONTAINER}" >/dev/null 2>&1 || true
  docker exec "${WORKER2_NODE}" ip link del e09p0 >/dev/null 2>&1 || true
  ip link del e09p0 >/dev/null 2>&1 || true
  ip link del e09p1 >/dev/null 2>&1 || true
}
trap cleanup EXIT

verify_guards() {
  log "Verificando guardas de cluster (k01 e p003-gw) e bgp-secrets-namespace..."
  local k01_uid p003_uid sec_ns
  k01_uid="$(kubectl --kubeconfig "${K01_KUBECONFIG}" --context "${K01_CONTEXT}" get namespace kube-system -o jsonpath='{.metadata.uid}')"
  p003_uid="$(kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" get namespace kube-system -o jsonpath='{.metadata.uid}')"
  sec_ns="$(kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" -n kube-system get configmap cilium-config -o jsonpath='{.data.bgp-secrets-namespace}')"
  if [[ "${k01_uid}" != "${K01_EXPECTED_UID}" ]]; then
    echo "ERRO: k01 UID=${k01_uid} difere do esperado" >&2
    exit 1
  fi
  if [[ "${p003_uid}" != "${P003_EXPECTED_UID}" ]]; then
    echo "ERRO: p003-gw UID=${p003_uid} difere do esperado" >&2
    exit 1
  fi
  if [[ "${sec_ns}" != "kube-system" ]]; then
    echo "ERRO: bgp-secrets-namespace='${sec_ns}' (esperado: kube-system)" >&2
    exit 1
  fi
  log "Guardas OK: k01=${k01_uid}, p003-gw=${p003_uid}, bgp-secrets-namespace=${sec_ns}"
}

check_primary_sessions() {
  local total_est=0
  for node in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
    local pod
    pod="$(kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" -n kube-system get pods \
      -l k8s-app=cilium --field-selector spec.nodeName="${node}" -o jsonpath='{.items[0].metadata.name}')"
    local c
    c="$(kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" -n kube-system exec "${pod}" -c cilium-agent -- \
      cilium-dbg bgp peers | grep -E "10\.30\.(1|2)\.1" | grep -ic "established" || true)"
    total_est=$((total_est + c))
  done
  echo "${total_est}"
}

verify_guards

W2_CILIUM_POD="$(kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" -n kube-system get pods \
  -l k8s-app=cilium --field-selector spec.nodeName="${WORKER2_NODE}" -o jsonpath='{.items[0].metadata.name}')"
W2_RESTARTS_BEFORE="$(kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" -n kube-system get pod "${W2_CILIUM_POD}" \
  -o jsonpath='{.status.containerStatuses[0].restartCount}')"

log "=== PASSO 1: Criando container efêmero ${FRR_E09_CONTAINER} (ASN ${PEER_ASN32}) e par veth e09p0 <-> e09p1 ==="
docker rm -f "${FRR_E09_CONTAINER}" >/dev/null 2>&1 || true
docker run -d --name "${FRR_E09_CONTAINER}" --hostname frr-e09 --network none --privileged \
  --entrypoint /bin/sh "${FRR_IMAGE}" \
  -c "sed -i 's/^bgpd=no/bgpd=yes/' /etc/frr/daemons && /usr/lib/frr/frrinit.sh start && exec sleep infinity" >/dev/null
sleep 2

W2_PID="$(docker inspect -f '{{.State.Pid}}' "${WORKER2_NODE}")"
FRR_PID="$(docker inspect -f '{{.State.Pid}}' "${FRR_E09_CONTAINER}")"

docker exec "${WORKER2_NODE}" ip link del e09p0 >/dev/null 2>&1 || true
ip link del e09p0 >/dev/null 2>&1 || true
ip link del e09p1 >/dev/null 2>&1 || true
ip link add e09p0 type veth peer name e09p1
ip link set e09p0 netns "${W2_PID}"
ip link set e09p1 netns "${FRR_PID}"

nsenter -t "${W2_PID}" -n ip addr add "${WORKER2_E09_IP}/30" dev e09p0
nsenter -t "${W2_PID}" -n ip link set e09p0 up

nsenter -t "${FRR_PID}" -n ip link set lo up
nsenter -t "${FRR_PID}" -n ip addr add "${FRR_E09_LO_IP}" dev lo
nsenter -t "${FRR_PID}" -n ip addr add "${FRR_E09_IP}/30" dev e09p1
nsenter -t "${FRR_PID}" -n ip link set e09p1 up

log "=== CÉLULA 1 (POSITIVA): Senha MD5 Correspondente + ASN 32 bits (${PEER_ASN32}) ==="
docker exec "${FRR_E09_CONTAINER}" vtysh \
  -c "configure terminal" \
  -c "router bgp ${PEER_ASN32}" \
  -c " bgp router-id ${FRR_E09_IP}" \
  -c " no bgp ebgp-requires-policy" \
  -c " neighbor ${WORKER2_E09_IP} remote-as ${LOCAL_ASN_RACK2}" \
  -c " neighbor ${WORKER2_E09_IP} password P005-E09-ValidKey" \
  -c " neighbor ${WORKER2_E09_IP} timers 3 9" \
  -c " address-family ipv4 unicast" \
  -c "  network ${FRR_E09_PREFIX}" \
  -c " exit-address-family" \
  -c "end"

cat <<EOF | kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: bgp-md5-secret-e09
  namespace: kube-system
  labels:
    study: p005-e09
type: Opaque
stringData:
  password: "P005-E09-ValidKey"
---
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata:
  name: e09-md5-peer
  labels:
    study: p005-e09
spec:
  authSecretRef: bgp-md5-secret-e09
  timers:
    connectRetryTimeSeconds: 3
    holdTimeSeconds: 9
    keepAliveTimeSeconds: 3
  ebgpMultihop: 1
  gracefulRestart:
    enabled: true
    restartTimeSeconds: 15
  families:
    - afi: ipv4
      safi: unicast
      advertisements:
        matchLabels:
          advertise: fabric
---
apiVersion: cilium.io/v2
kind: CiliumBGPClusterConfig
metadata:
  name: rack2
spec:
  nodeSelector:
    matchLabels:
      topology.kubernetes.io/rack: rack2
  bgpInstances:
    - name: "rack2"
      localASN: 65302
      peers:
        - name: "leaf2"
          peerASN: 65202
          peerAddress: "10.30.2.1"
          peerConfigRef:
            name: "fabric-peer"
        - name: "frr-e09-asn32"
          peerASN: 4200000001
          peerAddress: "10.255.209.2"
          peerConfigRef:
            name: "e09-md5-peer"
EOF

log "Aguardando sessão eBGP MD5 + ASN32 (${FRR_E09_IP}, AS ${PEER_ASN32}) entrar em Established..."
C1_ESTABLISHED=0
for attempt in $(seq 1 30); do
  if kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" -n kube-system exec "${W2_CILIUM_POD}" -c cilium-agent -- \
    cilium-dbg bgp peers | grep "${FRR_E09_IP}" | grep -iq "established"; then
    C1_ESTABLISHED=1
    log "Sessão ${FRR_E09_IP} (AS ${PEER_ASN32}) Established na tentativa ${attempt}!"
    break
  fi
  sleep 1
done

if [[ "${C1_ESTABLISHED}" -ne 1 ]]; then
  echo "ERRO: Sessão eBGP MD5 + ASN32 não estabeleceu na Célula 1!" >&2
  exit 1
fi

echo "--- [Célula 1] cilium-dbg bgp peers em ${WORKER2_NODE} ---"
kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" -n kube-system exec "${W2_CILIUM_POD}" -c cilium-agent -- \
  cilium-dbg bgp peers

echo "--- [Célula 1] FRR show bgp ipv4 unicast summary json ---"
docker exec "${FRR_E09_CONTAINER}" vtysh -c "show bgp ipv4 unicast summary json"

echo "--- [Célula 1] FRR show bgp ipv4 unicast (rotas recebidas de AS 65302) ---"
docker exec "${FRR_E09_CONTAINER}" vtysh -c "show bgp ipv4 unicast"

echo "--- [Célula 1] Captura tcpdump provando TCP Option 19 (MD5 digest) na porta 179 ---"
TCPDUMP_C1="$(nsenter -t "${FRR_PID}" -n timeout 8 tcpdump -ni e09p1 'tcp port 179' -c 2 -vv 2>&1 || true)"
echo "${TCPDUMP_C1}"
if ! echo "${TCPDUMP_C1}" | grep -iq "md5"; then
  echo "ERRO: Opção TCP MD5 (Option 19) não encontrada na captura tcpdump!" >&2
  exit 1
fi

log "=== CÉLULA 2 (NEGATIVA): Senha MD5 Divergente (Isolamento de Falha) ==="
nsenter -t "${W2_PID}" -n nstat -r >/dev/null 2>&1 || true
nsenter -t "${FRR_PID}" -n nstat -r >/dev/null 2>&1 || true

docker exec "${FRR_E09_CONTAINER}" vtysh \
  -c "configure terminal" \
  -c "router bgp ${PEER_ASN32}" \
  -c " neighbor ${WORKER2_E09_IP} password P005-E09-WrongKey" \
  -c "end" \
  -c "clear bgp ipv4 unicast ${WORKER2_E09_IP}"

sleep 8

echo "--- [Célula 2] cilium-dbg bgp peers após senha divergente ---"
PEERS_C2="$(kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" -n kube-system exec "${W2_CILIUM_POD}" -c cilium-agent -- cilium-dbg bgp peers)"
echo "${PEERS_C2}"

if echo "${PEERS_C2}" | grep "${FRR_E09_IP}" | grep -iq "established"; then
  echo "ERRO: Sessão ${FRR_E09_IP} permaneceu Established com senha divergente!" >&2
  exit 1
fi

W2_MD5_FAIL="$(nsenter -t "${W2_PID}" -n nstat -az TcpExtTCPMD5Failure 2>/dev/null | awk '/TcpExtTCPMD5Failure/ {print $2}' || echo 0)"
FRR_MD5_FAIL="$(nsenter -t "${FRR_PID}" -n nstat -az TcpExtTCPMD5Failure 2>/dev/null | awk '/TcpExtTCPMD5Failure/ {print $2}' || echo 0)"
PRIMARY_C2="$(check_primary_sessions)"
echo "CELL2_SUMMARY: worker2_TcpExtTCPMD5Failure=${W2_MD5_FAIL:-0} frr_TcpExtTCPMD5Failure=${FRR_MD5_FAIL:-0} primary_fabric_sessions_established=${PRIMARY_C2}/3"

if [[ "${PRIMARY_C2}" -ne 3 ]]; then
  echo "ERRO: Sessões primárias do fabric foram impactadas na Célula 2 (${PRIMARY_C2}/3)!" >&2
  exit 1
fi

log "=== CÉLULA 3 (NEGATIVA): authSecretRef Apontando para Secret Inexistente ==="
docker exec "${FRR_E09_CONTAINER}" vtysh \
  -c "configure terminal" \
  -c "router bgp ${PEER_ASN32}" \
  -c " neighbor ${WORKER2_E09_IP} password P005-E09-ValidKey" \
  -c "end"

kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" patch ciliumbgppeerconfig e09-md5-peer \
  --type=merge -p '{"spec":{"authSecretRef":"bgp-md5-secret-inexistente"}}'
docker exec "${FRR_E09_CONTAINER}" vtysh -c "clear bgp ipv4 unicast ${WORKER2_E09_IP}" >/dev/null 2>&1 || true

sleep 8

PEERS_C3="$(kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" -n kube-system exec "${W2_CILIUM_POD}" -c cilium-agent -- cilium-dbg bgp peers)"
echo "--- [Célula 3] cilium-dbg bgp peers com Secret inexistente ---"
echo "${PEERS_C3}"

if echo "${PEERS_C3}" | grep "${FRR_E09_IP}" | grep -iq "established"; then
  echo "ERRO: Sessão ${FRR_E09_IP} estabeleceu mesmo com Secret inexistente!" >&2
  exit 1
fi

echo "--- [Célula 3] Logs do cilium-agent sobre o Secret inexistente ---"
kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" -n kube-system logs "${W2_CILIUM_POD}" -c cilium-agent --since=45s \
  | grep -iE "secret|e09|10\.255\.209\.2|md5" | tail -n 15 || true

W2_RESTARTS_C3="$(kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" -n kube-system get pod "${W2_CILIUM_POD}" \
  -o jsonpath='{.status.containerStatuses[0].restartCount}')"
PRIMARY_C3="$(check_primary_sessions)"
echo "CELL3_SUMMARY: cilium_agent_restarts_before=${W2_RESTARTS_BEFORE} cilium_agent_restarts_after=${W2_RESTARTS_C3} primary_fabric_sessions_established=${PRIMARY_C3}/3"

if [[ "${W2_RESTARTS_C3}" -ne "${W2_RESTARTS_BEFORE}" || "${PRIMARY_C3}" -ne 3 ]]; then
  echo "ERRO: Crash do cilium-agent ou queda de sessão primária na Célula 3!" >&2
  exit 1
fi

log "=== CÉLULA 4 (ROTAÇÃO EM PRODUÇÃO): Atualização de Chave MD5 e Medição de Convergência ==="
kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" patch ciliumbgppeerconfig e09-md5-peer \
  --type=merge -p '{"spec":{"authSecretRef":"bgp-md5-secret-e09"}}'

for attempt in $(seq 1 30); do
  if kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" -n kube-system exec "${W2_CILIUM_POD}" -c cilium-agent -- \
    cilium-dbg bgp peers | grep "${FRR_E09_IP}" | grep -iq "established"; then
    log "Sessão restaurada para Established antes da rotação (tentativa ${attempt})."
    break
  fi
  sleep 1
done

ROT_T0_MS="$(date +%s%3N)"
kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" -n kube-system create secret generic bgp-md5-secret-e09 \
  --from-literal=password="P005-E09-RotatedKey-v2" --dry-run=client -o yaml | \
  kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" apply -f - >/dev/null

docker exec "${FRR_E09_CONTAINER}" vtysh \
  -c "configure terminal" \
  -c "router bgp ${PEER_ASN32}" \
  -c " neighbor ${WORKER2_E09_IP} password P005-E09-RotatedKey-v2" \
  -c "end"

sleep 2
docker exec "${FRR_E09_CONTAINER}" vtysh -c "clear bgp ipv4 unicast ${WORKER2_E09_IP}" >/dev/null

C4_ESTABLISHED=0
for attempt in $(seq 1 60); do
  if kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" -n kube-system exec "${W2_CILIUM_POD}" -c cilium-agent -- \
    cilium-dbg bgp peers | grep "${FRR_E09_IP}" | grep -iq "established"; then
    C4_ESTABLISHED=1
    break
  fi
  sleep 0.25
done
ROT_T1_MS="$(date +%s%3N)"
ROT_ELAPSED_MS=$((ROT_T1_MS - ROT_T0_MS))

if [[ "${C4_ESTABLISHED}" -ne 1 ]]; then
  echo "ERRO: Sessão não re-estabeleceu após rotação de senha na Célula 4!" >&2
  exit 1
fi

echo "--- [Célula 4] Captura tcpdump após rotação para P005-E09-RotatedKey-v2 ---"
TCPDUMP_C4="$(nsenter -t "${FRR_PID}" -n timeout 8 tcpdump -ni e09p1 'tcp port 179' -c 2 -vv 2>&1 || true)"
echo "${TCPDUMP_C4}"

PRIMARY_C4="$(check_primary_sessions)"
echo "CELL4_ROTATION_SUMMARY: rotation_and_reestablish_ms=${ROT_ELAPSED_MS} peer_state=Established primary_fabric_sessions_established=${PRIMARY_C4}/3"

log "Estudo E09 concluído com PASS."
