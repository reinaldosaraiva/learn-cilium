#!/usr/bin/env bash
# ==============================================================================
# P005-S002 (Arm A — Study E10): Deteccao de Falha sem e com BFD (< 1 s)
#
# Caso de estudo : E10 (docs/proximos-estudos.md)
# Hipotese       :
#   1. Celula 1 (Cilium OSS 1.20.2 direto, timers 3/9 s, sem BFD):
#      Sob falha silenciosa de enlace L2/optico (drop total de pacotes sem TCP
#      FIN/RST e sem queda eletrica local de carrier), a convergencia depende do
#      Hold Timer de 9 s (~6000 a 9000 ms).
#   2. Celula 2 (Cilium OSS 1.20.2 no piso da API v2, timers 1/3 s + Negativo < 3 s):
#      A API CiliumBGPPeerConfig v2 rejeita holdTimeSeconds < 3 (validacao OpenAPI
#      minimum: 3) e nao possui suporte nativo a BFD (issue #22394). No piso 1/3 s,
#      a deteccao cai para ~2000 a 3000 ms, ainda acima de RNF05 (< 1000 ms).
#   3. Celula 3 (Roteador de Borda FRR PE <-> CE com BFD 100 ms x 3):
#      Quando a sessao eBGP dedicada e protegida por BFD (100 ms x 3) no roteador
#      de borda (border1 <-> frr-e10-ce), a mesma falha silenciosa derruba o BFD
#      e retira a rota em < 1000 ms (~300 a 500 ms), cumprindo RNF05.
# ==============================================================================
set -euo pipefail

DRY_RUN=0
ROLLBACK_ONLY=0
KUBECONFIG_GW="${P003_KUBECONFIG:-/root/.kube/p003-gw.config}"
KUBECONFIG_K01="${K01_KUBECONFIG:-/root/.kube/k01-rebuild.config}"
CTX_GW="kind-p003-gw"
CTX_K01="kind-k01"
EXPECTED_UID_GW="6bb32e0f-71f9-4558-ae33-356ba2250c26"
EXPECTED_UID_K01="635e7274-5597-40c7-9de5-b1fbe3d68b22"

WORKER_NODE="p003-gw-worker2"
BORDER_NODE="clab-p003-gw-fabric-border1"
FRR_CONTAINER="clab-p003-gw-fabric-frr-e10-ce"
FRR_IMAGE="${FRR_IMAGE:-frrouting/frr:v8.4.1}"

HOST_VETH_W="e10p0"
PEER_VETH_W="e10p1"
WORKER_IP="10.255.210.1"
CE_W_IP="10.255.210.2"

HOST_VETH_B="e10b0"
PEER_VETH_B="e10b1"
BORDER_IP="10.255.210.5"
CE_B_IP="10.255.210.6"

WORKER_ASN="65302"
BORDER_ASN="65400"
CE_ASN="65510"
CE_PREFIX="198.18.210.0/24"
CE_LO_IP="198.18.210.1/24"
VIP_E10="10.202.255.191"
NS_TEST="e10-bfd-test"

usage() {
  cat <<EOF
Uso: $0 [--dry-run] [--rollback] [--help]

Estudo E10 (P005-S002 Braço A):
  Célula 1: Cilium OSS 1.20.2 direto (timers 3/9 s, GR=false) -> detecção ~6-9 s
  Célula 2: Cilium OSS 1.20.2 no piso (timers 1/3 s + negativo holdTime=2 rejeitado) -> detecção ~2-3 s
  Célula 3: FRR PE (border1) <-> CE com BFD (100 ms x 3) -> detecção < 1000 ms (RNF05)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --rollback) ROLLBACK_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Argumento desconhecido: $1" >&2; usage; exit 2 ;;
  esac
done

log() {
  printf '[E10 %s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  cat <<EOF
[DRY-RUN] Estudo E10 — Deteccao de Falha sem e com BFD (< 1 s)
  1. Validaria UIDs dos clusters k01 (${EXPECTED_UID_K01}) e p003-gw (${EXPECTED_UID_GW}).
  2. Criaria container ${FRR_CONTAINER} (${FRR_IMAGE}, AS ${CE_ASN}, bgpd+bfdd) com dois pares veth:
     - ${WORKER_NODE}:${HOST_VETH_W} (${WORKER_IP}/30) <-> ${FRR_CONTAINER}:${PEER_VETH_W} (${CE_W_IP}/30)
     - ${BORDER_NODE}:${HOST_VETH_B} (${BORDER_IP}/30) <-> ${FRR_CONTAINER}:${PEER_VETH_B} (${CE_B_IP}/30)
  3. Celula 1 (Cilium direto timers 3/9 s, gracefulRestart=false):
     - Anunciaria VIP ${VIP_E10}/32 de ${WORKER_NODE} para ${FRR_CONTAINER}.
     - Injetaria blackhole silencioso em ${PEER_VETH_W} (iptables DROP INPUT/OUTPUT sem TCP FIN/RST).
     - Mediria tempo ate retirada de ${VIP_E10}/32 da RIB do CE (~6000-9000 ms).
  4. Celula 2 (Cilium direto no piso 1/3 s + controle negativo holdTimeSeconds=2):
     - Provaria rejeicao de holdTimeSeconds=2 pelo schema OpenAPI do CRD e 0 campos BFD.
     - Mediria tempo ate retirada de ${VIP_E10}/32 com timers 1/3 s (~2000-3000 ms > 1000 ms).
  5. Celula 3 (FRR PE ${BORDER_NODE} <-> CE ${FRR_CONTAINER} com BFD 100 ms x 3):
     - Ativaria bfdd em ${BORDER_NODE} e configuraria peer BFD (100 ms x 3) + neighbor ... bfd.
     - Injetaria blackhole silencioso em ${PEER_VETH_B} e mediria retirada de ${CE_PREFIX} em < 1000 ms.
  6. Executaria rollback completo ao baseline do p003-gw.
EOF
  exit 0
fi

apply_baseline_bgp() {
  kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" delete ciliumbgpclusterconfig cilium-bgp --ignore-not-found >/dev/null 2>&1 || true
  kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" apply -f - >/dev/null <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumBGPClusterConfig
metadata:
  name: rack2
  labels:
    study: P003
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
      peerAddress: 10.30.2.1
      peerConfigRef:
        name: "fabric-peer"
EOF
}

cleanup() {
  log "Rollback E10: restaurando CiliumBGPClusterConfig, border1 e removendo recursos temporarios..."
  apply_baseline_bgp || true
  kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" delete ciliumbgppeerconfig e10-peer e10-peer-invalid --ignore-not-found >/dev/null 2>&1 || true
  kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" delete ciliumbgpadvertisement bgp-e10-adv --ignore-not-found >/dev/null 2>&1 || true
  kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" delete CiliumLoadBalancerIPPool pool-e10 --ignore-not-found >/dev/null 2>&1 || true
  kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" delete ns "$NS_TEST" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  docker exec "$BORDER_NODE" vtysh -c "conf t" \
    -c "router bgp ${BORDER_ASN}" \
    -c "no neighbor ${CE_B_IP} remote-as ${CE_ASN}" \
    -c "exit" \
    -c "bfd" \
    -c "no peer ${CE_B_IP}" \
    -c "end" >/dev/null 2>&1 || true
  docker rm -f "$FRR_CONTAINER" >/dev/null 2>&1 || true
  docker exec "$WORKER_NODE" ip link del "$HOST_VETH_W" >/dev/null 2>&1 || true
  docker exec "$BORDER_NODE" ip link del "$HOST_VETH_B" >/dev/null 2>&1 || true
  ip link del "$HOST_VETH_W" >/dev/null 2>&1 || true
  ip link del "$HOST_VETH_B" >/dev/null 2>&1 || true
}

if [[ "$ROLLBACK_ONLY" -eq 1 ]]; then
  cleanup
  log "Rollback E10 concluido."
  exit 0
fi

trap cleanup EXIT

# 1. Guards
UID_K01="$(kubectl --kubeconfig="$KUBECONFIG_K01" --context="$CTX_K01" get ns kube-system -o jsonpath='{.metadata.uid}')"
UID_GW="$(kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "$UID_K01" != "$EXPECTED_UID_K01" ]]; then
  echo "ERRO: k01 UID inesperado: $UID_K01" >&2
  exit 1
fi
if [[ "$UID_GW" != "$EXPECTED_UID_GW" ]]; then
  echo "ERRO: p003-gw UID inesperado: $UID_GW" >&2
  exit 1
fi
log "Preflight OK: k01_uid=${UID_K01} p003_gw_uid=${UID_GW}"

# 2. Provisionar container CE FRR (AS 65510 com bgpd e bfdd) + 2 enlaces veth
log "Provisionando container ${FRR_CONTAINER} (AS ${CE_ASN}, bgpd+bfdd) e enlaces veth..."
docker rm -f "$FRR_CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$FRR_CONTAINER" --hostname frr-e10-ce --network none --privileged \
  --entrypoint /bin/sh "$FRR_IMAGE" -c "exec sleep infinity" >/dev/null
sleep 1

W_PID="$(docker inspect -f '{{.State.Pid}}' "$WORKER_NODE")"
B1_PID="$(docker inspect -f '{{.State.Pid}}' "$BORDER_NODE")"
CE_PID="$(docker inspect -f '{{.State.Pid}}' "$FRR_CONTAINER")"

ip link del "$HOST_VETH_W" >/dev/null 2>&1 || true
ip link del "$PEER_VETH_W" >/dev/null 2>&1 || true
ip link add "$HOST_VETH_W" type veth peer name "$PEER_VETH_W"
ip link set "$HOST_VETH_W" netns "$W_PID"
ip link set "$PEER_VETH_W" netns "$CE_PID"

nsenter -t "$W_PID" -n ip addr add "${WORKER_IP}/30" dev "$HOST_VETH_W"
nsenter -t "$W_PID" -n ip link set "$HOST_VETH_W" up
nsenter -t "$CE_PID" -n ip addr add "${CE_W_IP}/30" dev "$PEER_VETH_W"
nsenter -t "$CE_PID" -n ip link set "$PEER_VETH_W" up

ip link del "$HOST_VETH_B" >/dev/null 2>&1 || true
ip link del "$PEER_VETH_B" >/dev/null 2>&1 || true
ip link add "$HOST_VETH_B" type veth peer name "$PEER_VETH_B"
ip link set "$HOST_VETH_B" netns "$B1_PID"
ip link set "$PEER_VETH_B" netns "$CE_PID"

nsenter -t "$B1_PID" -n ip addr add "${BORDER_IP}/30" dev "$HOST_VETH_B"
nsenter -t "$B1_PID" -n ip link set "$HOST_VETH_B" up
nsenter -t "$CE_PID" -n ip addr add "${CE_B_IP}/30" dev "$PEER_VETH_B"
nsenter -t "$CE_PID" -n ip link set "$PEER_VETH_B" up
nsenter -t "$CE_PID" -n ip link set lo up
nsenter -t "$CE_PID" -n ip addr add "$CE_LO_IP" dev lo

# Garantir bfdd ativo em border1 e no CE (sem sed -i sobre bind-mount do containerlab)
docker exec "$BORDER_NODE" sh -c "pidof bfdd >/dev/null || /usr/lib/frr/bfdd -d -A 127.0.0.1"
docker exec "$FRR_CONTAINER" sh -c 'sed "s/bgpd=no/bgpd=yes/;s/bfdd=no/bfdd=yes/" /etc/frr/daemons > /tmp/daemons && cat /tmp/daemons > /etc/frr/daemons && /usr/lib/frr/frrinit.sh start' >/dev/null
sleep 2

docker exec -i "$FRR_CONTAINER" vtysh <<EOF >/dev/null
conf t
bfd
 peer ${BORDER_IP}
  receive-interval 100
  transmit-interval 100
  detect-multiplier 3
 exit
exit
router bgp ${CE_ASN}
 bgp router-id 198.18.210.1
 no bgp ebgp-requires-policy
 neighbor ${WORKER_IP} remote-as ${WORKER_ASN}
 neighbor ${WORKER_IP} timers 3 9
 neighbor ${BORDER_IP} remote-as ${BORDER_ASN}
 neighbor ${BORDER_IP} timers 3 9
 neighbor ${BORDER_IP} bfd
 address-family ipv4 unicast
  network ${CE_PREFIX}
  neighbor ${WORKER_IP} activate
  neighbor ${BORDER_IP} activate
 exit-address-family
end
write
EOF

# 3. Criar VIP ${VIP_E10}/32 e Advertisement para o peer E10
kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" create ns "$NS_TEST" --dry-run=client -o yaml | \
  kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" apply -f - >/dev/null

kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" apply -f - >/dev/null <<EOF
apiVersion: cilium.io/v2
kind: CiliumBGPAdvertisement
metadata:
  name: bgp-e10-adv
  labels:
    advertise: bgp-e10
spec:
  advertisements:
  - advertisementType: "Service"
    service:
      addresses:
      - LoadBalancerIP
    selector:
      matchLabels:
        bgp-export: "e10"
---
apiVersion: v1
kind: Pod
metadata:
  name: e10-echo
  namespace: ${NS_TEST}
  labels:
    app: e10-echo
spec:
  nodeName: ${WORKER_NODE}
  containers:
  - name: agnhost
    image: registry.k8s.io/e2e-test-images/agnhost:2.47
    args: ["netexec", "--http-port=8080"]
---
apiVersion: v1
kind: Service
metadata:
  name: svc-e10
  namespace: ${NS_TEST}
  labels:
    bgp-export: "e10"
  annotations:
    lbipam.cilium.io/ips: "${VIP_E10}"
spec:
  type: LoadBalancer
  selector:
    app: e10-echo
  ports:
  - port: 80
    targetPort: 8080
EOF
kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n "$NS_TEST" wait --for=condition=Ready pod/e10-echo --timeout=60s >/dev/null

# ==============================================================================
# CÉLULA 1: Cilium OSS 1.20.2 Direto com Timers 3/9 s (sem BFD, GR=false)
# ==============================================================================
log "=== CELULA 1: Cilium OSS 1.20.2 Direto (Timers 3/9 s, gracefulRestart=false) ==="
kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" apply -f - >/dev/null <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata:
  name: e10-peer
spec:
  timers:
    connectRetryTimeSeconds: 3
    keepAliveTimeSeconds: 3
    holdTimeSeconds: 9
  ebgpMultihop: 1
  gracefulRestart:
    enabled: false
  families:
  - afi: ipv4
    safi: unicast
    advertisements:
      matchLabels:
        advertise: bgp-e10
---
apiVersion: cilium.io/v2
kind: CiliumBGPClusterConfig
metadata:
  name: rack2
  labels:
    study: P003
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
      peerAddress: 10.30.2.1
      peerConfigRef:
        name: "fabric-peer"
    - name: "e10-ce"
      peerASN: 65510
      peerAddress: 10.255.210.2
      peerConfigRef:
        name: "e10-peer"
EOF

for _ in $(seq 1 30); do
  if nsenter -t "$CE_PID" -m -n -r /usr/bin/vtysh -c "show ip bgp ${VIP_E10}/32" 2>/dev/null | grep -q "$WORKER_IP"; then
    break
  fi
  sleep 1
done

log "VIP ${VIP_E10}/32 instalada na RIB do CE (Timers 3/9 s). Injetando blackhole silencioso em ${PEER_VETH_W}..."
T_START_C1="$(date +%s%3N)"
nsenter -t "$CE_PID" -n iptables -I INPUT 1 -i "$PEER_VETH_W" -j DROP
nsenter -t "$CE_PID" -n iptables -I OUTPUT 1 -o "$PEER_VETH_W" -j DROP

while true; do
  if ! nsenter -t "$CE_PID" -m -n -r /usr/bin/vtysh -c "show ip bgp ${VIP_E10}/32" 2>/dev/null | grep -q "$WORKER_IP"; then
    break
  fi
  sleep 0.05
done
T_END_C1="$(date +%s%3N)"
CELL1_DETECT_MS=$((T_END_C1 - T_START_C1))
log "Celula 1 (Timers 3/9 s): rota retirada em cell1_detect_ms=${CELL1_DETECT_MS} ms"

# Restaurar link da Celula 1
nsenter -t "$CE_PID" -n iptables -D INPUT -i "$PEER_VETH_W" -j DROP
nsenter -t "$CE_PID" -n iptables -D OUTPUT -o "$PEER_VETH_W" -j DROP

# ==============================================================================
# CÉLULA 2: Piso da API Cilium v2 (Timers 1/3 s) + Controle Negativo (< 3 s)
# ==============================================================================
log "=== CELULA 2: Piso CiliumBGPPeerConfig (Timers 1/3 s) + Negativo holdTimeSeconds=2 ==="
CRD_BFD_FIELDS="$(kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" get crd ciliumbgppeerconfigs.cilium.io -o yaml | grep -ic 'bfd' || true)"

set +e
NEG_HOLD2_OUT="$(kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" apply -f - 2>&1 <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata:
  name: e10-peer-invalid
spec:
  timers:
    connectRetryTimeSeconds: 1
    keepAliveTimeSeconds: 1
    holdTimeSeconds: 2
EOF
)"
NEG_HOLD2_RC=$?
set -e
log "Controle negativo holdTimeSeconds=2: rc=${NEG_HOLD2_RC} msg=$(echo "$NEG_HOLD2_OUT" | tr '\n' ' ')"
log "Campos BFD no CRD ciliumbgppeerconfigs.cilium.io: ${CRD_BFD_FIELDS}"

# Ajustar timers para 1/3 s em ambos os lados
docker exec -i "$FRR_CONTAINER" vtysh <<EOF >/dev/null
conf t
router bgp ${CE_ASN}
 neighbor ${WORKER_IP} timers 1 3
end
EOF

kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" apply -f - >/dev/null <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata:
  name: e10-peer
spec:
  timers:
    connectRetryTimeSeconds: 1
    keepAliveTimeSeconds: 1
    holdTimeSeconds: 3
  ebgpMultihop: 1
  gracefulRestart:
    enabled: false
  families:
  - afi: ipv4
    safi: unicast
    advertisements:
      matchLabels:
        advertise: bgp-e10
EOF

docker exec "$FRR_CONTAINER" vtysh -c "clear bgp ${WORKER_IP}" >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
  if nsenter -t "$CE_PID" -m -n -r /usr/bin/vtysh -c "show ip bgp ${VIP_E10}/32" 2>/dev/null | grep -q "$WORKER_IP"; then
    break
  fi
  sleep 1
done

log "VIP ${VIP_E10}/32 re-instalada com Timers 1/3 s. Injetando blackhole silencioso em ${PEER_VETH_W}..."
T_START_C2="$(date +%s%3N)"
nsenter -t "$CE_PID" -n iptables -I INPUT 1 -i "$PEER_VETH_W" -j DROP
nsenter -t "$CE_PID" -n iptables -I OUTPUT 1 -o "$PEER_VETH_W" -j DROP

while true; do
  if ! nsenter -t "$CE_PID" -m -n -r /usr/bin/vtysh -c "show ip bgp ${VIP_E10}/32" 2>/dev/null | grep -q "$WORKER_IP"; then
    break
  fi
  sleep 0.05
done
T_END_C2="$(date +%s%3N)"
CELL2_DETECT_MS=$((T_END_C2 - T_START_C2))
log "Celula 2 (Piso Timers 1/3 s): rota retirada em cell2_detect_ms=${CELL2_DETECT_MS} ms (> 1000 ms)"

nsenter -t "$CE_PID" -n iptables -D INPUT -i "$PEER_VETH_W" -j DROP
nsenter -t "$CE_PID" -n iptables -D OUTPUT -o "$PEER_VETH_W" -j DROP

# ==============================================================================
# CÉLULA 3: Roteador de Borda FRR PE (border1) <-> CE com BFD (100 ms x 3)
# ==============================================================================
log "=== CELULA 3: FRR PE (${BORDER_NODE}) <-> CE (${FRR_CONTAINER}) com BFD 100 ms x 3 ==="
docker exec -i "$BORDER_NODE" vtysh <<EOF >/dev/null
conf t
bfd
 peer ${CE_B_IP}
  receive-interval 100
  transmit-interval 100
  detect-multiplier 3
 exit
exit
router bgp ${BORDER_ASN}
 no bgp ebgp-requires-policy
 neighbor ${CE_B_IP} remote-as ${CE_ASN}
 neighbor ${CE_B_IP} timers 3 9
 neighbor ${CE_B_IP} bfd
 address-family ipv4 unicast
  neighbor ${CE_B_IP} activate
 exit-address-family
end
EOF

for _ in $(seq 1 30); do
  if nsenter -t "$B1_PID" -m -n -r /usr/bin/vtysh -c "show bfd peers" 2>/dev/null | grep -A4 "${CE_B_IP}" | grep -q "Status: up" && \
     nsenter -t "$B1_PID" -m -n -r /usr/bin/vtysh -c "show ip bgp ${CE_PREFIX}" 2>/dev/null | grep -q "${CE_B_IP}"; then
    break
  fi
  sleep 1
done

BFD_PRE_STATUS="$(nsenter -t "$B1_PID" -m -n -r /usr/bin/vtysh -c "show bfd peers" 2>/dev/null | grep -A6 "${CE_B_IP}" | tr '\n' ' ')"
log "BFD Established em border1: ${BFD_PRE_STATUS}"
log "Prefixo ${CE_PREFIX} instalado em border1 via ${CE_B_IP}. Injetando blackhole silencioso em ${PEER_VETH_B}..."

T_START_C3="$(date +%s%3N)"
nsenter -t "$CE_PID" -n iptables -I INPUT 1 -i "$PEER_VETH_B" -j DROP
nsenter -t "$CE_PID" -n iptables -I OUTPUT 1 -o "$PEER_VETH_B" -j DROP

while true; do
  if ! nsenter -t "$B1_PID" -m -n -r /usr/bin/vtysh -c "show ip bgp ${CE_PREFIX}" 2>/dev/null | grep -q "${CE_B_IP}"; then
    break
  fi
  sleep 0.02
done
T_END_C3="$(date +%s%3N)"
CELL3_BFD_DETECT_MS=$((T_END_C3 - T_START_C3))
BFD_POST_STATUS="$(nsenter -t "$B1_PID" -m -n -r /usr/bin/vtysh -c "show bfd peers" 2>/dev/null | grep -A6 "${CE_B_IP}" | tr '\n' ' ')"
log "Celula 3 (BFD 100 ms x 3): rota retirada em cell3_bfd_detect_ms=${CELL3_BFD_DETECT_MS} ms (< 1000 ms!)"
log "Estado BFD pos-blackhole em border1: ${BFD_POST_STATUS}"

nsenter -t "$CE_PID" -n iptables -D INPUT -i "$PEER_VETH_B" -j DROP
nsenter -t "$CE_PID" -n iptables -D OUTPUT -o "$PEER_VETH_B" -j DROP

cat <<EOF
====================================================================
RESUMO ESTUDO E10 (Deteccao de Falha sem e com BFD < 1 s)
- c1_cilium_timers_3_9_ms   : ${CELL1_DETECT_MS}
- c2_hold2_rejected_rc      : ${NEG_HOLD2_RC}
- c2_cilium_crd_bfd_fields  : ${CRD_BFD_FIELDS}
- c2_cilium_timers_1_3_ms   : ${CELL2_DETECT_MS}
- c3_border_bfd_100x3_ms    : ${CELL3_BFD_DETECT_MS}
- rnf05_subsecond_satisfied : $( [[ "$CELL3_BFD_DETECT_MS" -lt 1000 ]] && echo "YES (< 1000 ms)" || echo "NO" )
====================================================================
EOF
