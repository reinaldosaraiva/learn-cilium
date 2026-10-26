#!/usr/bin/env bash
# ==============================================================================
# P005-S003 (Onda 3 — Braço A): E13 — Redundância em Dois Borders (border1 /
# frr-e13-border2) e Failover Controlado com e sem Graceful Restart
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

P003_KUBECONFIG="${P003_KUBECONFIG:-/root/.kube/p003-gw.config}"
P003_CONTEXT="${P003_CONTEXT:-kind-p003-gw}"
EXPECTED_UID="6bb32e0f-71f9-4558-ae33-356ba2250c26"
K01_KUBECONFIG="${K01_KUBECONFIG:-/root/.kube/k01-rebuild.config}"
K01_CONTEXT="${K01_CONTEXT:-kind-k01}"
K01_EXPECTED_UID="635e7274-5597-40c7-9de5-b1fbe3d68b22"

NS="p005-e13"
VIP="10.202.255.193"
RACK1_NODE="p003-gw-worker"
RACK1_ASN="65301"
RACK2_NODE="p003-gw-worker2"
RACK2_ASN="65302"

BORDER1_CTR="clab-p003-gw-fabric-border1"
BORDER1_ASN="65400"
BORDER2_CTR="clab-p003-gw-fabric-frr-e13-border2"
BORDER2_ASN="65401"
CLIENT_CTR="clab-p003-gw-fabric-frr-e13-client"
CLIENT_ASN="65513"
FRR_IMAGE="${FRR_IMAGE:-frrouting/frr:v8.4.1}"

# Enlaces dedicados (10.255.213.0/24):
# 1. Rack 1 (e13r1b1 10.255.213.1/30) <-> Border 1 (e13b1r1 10.255.213.2/30)
R1_B1_IP="10.255.213.1"
B1_R1_IP="10.255.213.2"
# 2. Rack 2 (e13r2b2 10.255.213.5/30) <-> Border 2 (e13b2r2 10.255.213.6/30)
R2_B2_IP="10.255.213.5"
B2_R2_IP="10.255.213.6"
# 3. Border 1 (e13b1ce 10.255.213.9/30) <-> Client (e13ceb1 10.255.213.10/30)
B1_CE_IP="10.255.213.9"
CE_B1_IP="10.255.213.10"
# 4. Border 2 (e13b2ce 10.255.213.13/30) <-> Client (e13ceb2 10.255.213.14/30)
B2_CE_IP="10.255.213.13"
CE_B2_IP="10.255.213.14"

if $DRY_RUN; then
  cat <<EOF
[DRY-RUN] E13 — Redundância em Dois Borders (${BORDER1_CTR} / ${BORDER2_CTR}) e Failover c/ e s/ Graceful Restart
  Cluster: ${P003_CONTEXT} (expected UID: ${EXPECTED_UID})
  VIP dedicada: ${VIP}/32 (Service/e13-vip-svc em ${NS})
  Topologia:
    - Rack 1 (${RACK1_NODE}, AS ${RACK1_ASN}, ${R1_B1_IP}/30) <-> Border 1 (${BORDER1_CTR}, AS ${BORDER1_ASN}, ${B1_R1_IP}/30) <-> Client (${CLIENT_CTR}, AS ${CLIENT_ASN}, ${CE_B1_IP}/30)
    - Rack 2 (${RACK2_NODE}, AS ${RACK2_ASN}, ${R2_B2_IP}/30) <-> Border 2 (${BORDER2_CTR}, AS ${BORDER2_ASN}, ${B2_R2_IP}/30) <-> Client (${CLIENT_CTR}, AS ${CLIENT_ASN}, ${CE_B2_IP}/30)
  Células planejadas:
    1. Célula 1 (Dual-Border ECMP + Failover Controlado via neighbor ${CE_B1_IP} shutdown em border1):
       - Medir distribuição antes (ECMP 2 vias), durante (100% via Border 2 / Rack 2) e depois do shutdown, além do max_gap_ms (L4 a cada 100 ms).
    2. Célula 2 (Restart do Agente Cilium em ${RACK2_NODE} sobre caminho único via Border 2):
       - Subcélula 2A (Positivo — gracefulRestart.enabled: true, restartTimeSeconds: 30 + FRR bgp graceful-restart preserve-fw-state): rota [S] stale e datapath eBPF preservados durante restart do cilium-agent.
       - Subcélula 2B (Controle Negativo — gracefulRestart.enabled: false + FRR no bgp graceful-restart): retirada imediata da rota no fechamento TCP e blackhole L4 (max_gap_ms >> GR=on).
    3. Rollback completo de CRDs, containers FRR e enlaces.
EOF
  exit 0
fi

k() {
  kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" "$@"
}

ACTUAL_K01_UID="$(kubectl --kubeconfig "${K01_KUBECONFIG}" --context "${K01_CONTEXT}" get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${ACTUAL_K01_UID}" != "${K01_EXPECTED_UID}" ]]; then
  echo "FATAL: UID de k01 (${ACTUAL_K01_UID}) != esperado (${K01_EXPECTED_UID})" >&2
  exit 1
fi
ACTUAL_UID="$(k get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${ACTUAL_UID}" != "${EXPECTED_UID}" ]]; then
  echo "FATAL: UID de kube-system (${ACTUAL_UID}) != esperado (${EXPECTED_UID})" >&2
  exit 1
fi

restore_bgp_baseline() {
  cat <<'EOF' | k apply -f - >/dev/null 2>&1 || true
apiVersion: cilium.io/v2
kind: CiliumBGPClusterConfig
metadata:
  name: rack1
  labels:
    study: P003
spec:
  nodeSelector:
    matchLabels:
      topology.kubernetes.io/rack: rack1
  bgpInstances:
  - name: "rack1"
    localASN: 65301
    peers:
    - name: "leaf1"
      peerASN: 65201
      peerAddress: 10.30.1.1
      peerConfigRef:
        name: "fabric-peer"
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
EOF
}

PROBE_PID=""

cleanup() {
  echo "[CLEANUP] Restaurando baseline BGP (rack1/rack2), border1 e removendo recursos de E13..."
  if [[ -n "${PROBE_PID}" ]]; then
    kill "${PROBE_PID}" >/dev/null 2>&1 || true
  fi
  restore_bgp_baseline
  k delete -f "${SCRIPT_DIR}/manifests/05-e13-dual-border-failover.yaml" --ignore-not-found >/dev/null 2>&1 || true
  for node in "${RACK1_NODE}" "${RACK2_NODE}"; do
    docker exec "${node}" sh -c '
      iptables -t nat -D PREROUTING -j E13_PRE 2>/dev/null || true
      iptables -t nat -F E13_PRE 2>/dev/null || true
      iptables -t nat -X E13_PRE 2>/dev/null || true
      iptables -t nat -D POSTROUTING -j E13_POST 2>/dev/null || true
      iptables -t nat -F E13_POST 2>/dev/null || true
      iptables -t nat -X E13_POST 2>/dev/null || true
    ' >/dev/null 2>&1 || true
  done
  docker exec "${RACK1_NODE}" ip route del 10.255.213.8/30 >/dev/null 2>&1 || true
  docker exec "${RACK1_NODE}" ip route del 10.255.213.12/30 >/dev/null 2>&1 || true
  docker exec "${RACK2_NODE}" ip route del 10.255.213.8/30 >/dev/null 2>&1 || true
  docker exec "${RACK2_NODE}" ip route del 10.255.213.12/30 >/dev/null 2>&1 || true
  docker exec "${BORDER1_CTR}" vtysh \
    -c "configure terminal" \
    -c "router bgp ${BORDER1_ASN}" \
    -c "no neighbor ${R1_B1_IP} remote-as ${RACK1_ASN}" \
    -c "no neighbor ${CE_B1_IP} remote-as ${CLIENT_ASN}" \
    -c "no bgp graceful-restart" \
    -c "no bgp graceful-restart preserve-fw-state" \
    -c "exit" \
    -c "end" >/dev/null 2>&1 || true
  docker rm -f "${BORDER2_CTR}" "${CLIENT_CTR}" >/dev/null 2>&1 || true
  docker exec "${RACK1_NODE}" ip link del e13r1b1 >/dev/null 2>&1 || true
  docker exec "${RACK2_NODE}" ip link del e13r2b2 >/dev/null 2>&1 || true
  docker exec "${BORDER1_CTR}" ip link del e13b1r1 >/dev/null 2>&1 || true
  docker exec "${BORDER1_CTR}" ip link del e13b1ce >/dev/null 2>&1 || true
  rm -f /tmp/e13-cell1-probes.log /tmp/e13-cell2a-probes.log /tmp/e13-cell2b-probes.log
}
trap cleanup EXIT

analyze_probe_log() {
  local logfile="$1"
  python3 - "$logfile" <<'PY'
import sys
path = sys.argv[1]
rows = []
with open(path) as f:
    for line in f:
        parts = line.strip().split()
        if len(parts) >= 3:
            rows.append((int(parts[0]), parts[1], parts[2]))
total = len(rows)
oks = [r for r in rows if r[1] == "OK"]
fails = total - len(oks)
max_gap = 0
for i in range(1, len(oks)):
    gap = oks[i][0] - oks[i-1][0]
    if gap > max_gap:
        max_gap = gap
if fails > 0 and len(oks) >= 1 and rows[-1][1] == "FAIL":
    tail_gap = rows[-1][0] - oks[-1][0]
    if tail_gap > max_gap:
        max_gap = tail_gap
r1 = sum(1 for r in oks if "rack1" in r[2])
r2 = sum(1 for r in oks if "rack2" in r[2])
print(f"total={total} ok={len(oks)} fail={fails} max_gap_ms={max_gap} rack1={r1} rack2={r2}")
PY
}

start_probe_loop() {
  local logfile="$1"
  local ce_pid="$2"
  rm -f "$logfile"
  (
    while true; do
      ts="$(date +%s%3N)"
      body="$(nsenter -t "${ce_pid}" -n curl -sS --connect-timeout 0.4 --max-time 0.5 "http://${VIP}:8080/hostname" 2>/dev/null || true)"
      if [[ "${body}" == e13-echo-* ]]; then
        printf '%s OK %s\n' "${ts}" "${body}" >> "${logfile}"
      else
        printf '%s FAIL none\n' "${ts}" >> "${logfile}"
      fi
      sleep 0.1
    done
  ) &
  PROBE_PID=$!
}

stop_probe_loop() {
  if [[ -n "${PROBE_PID}" ]]; then
    kill "${PROBE_PID}" >/dev/null 2>&1 || true
    wait "${PROBE_PID}" 2>/dev/null || true
    PROBE_PID=""
  fi
}

echo "=== [E13] 1. Aplicando Manifesto ${NS} (Pods e13-echo-rack1/rack2, Service ${VIP}/32 e CRDs BGP) ==="
k apply -f "${SCRIPT_DIR}/manifests/05-e13-dual-border-failover.yaml"
k -n "${NS}" wait --for=condition=Ready pod/e13-echo-rack1 pod/e13-echo-rack2 --timeout=60s
R1_POD_IP="$(k -n "${NS}" get pod e13-echo-rack1 -o jsonpath='{.status.podIP}')"
R2_POD_IP="$(k -n "${NS}" get pod e13-echo-rack2 -o jsonpath='{.status.podIP}')"
echo "e13-echo-rack1 PodIP=${R1_POD_IP} (${RACK1_NODE})"
echo "e13-echo-rack2 PodIP=${R2_POD_IP} (${RACK2_NODE})"

echo "=== [E13] 2. Provisionando ${BORDER2_CTR}, ${CLIENT_CTR} e Enlaces veth Dedicados ==="
docker rm -f "${BORDER2_CTR}" "${CLIENT_CTR}" >/dev/null 2>&1 || true
docker run -d --name "${BORDER2_CTR}" --hostname frr-e13-border2 --network none --privileged \
  --entrypoint /bin/sh "${FRR_IMAGE}" -c "exec sleep infinity" >/dev/null
docker run -d --name "${CLIENT_CTR}" --hostname frr-e13-client --network none --privileged \
  --entrypoint /bin/sh "${FRR_IMAGE}" -c "exec sleep infinity" >/dev/null

R1_PID="$(docker inspect -f '{{.State.Pid}}' "${RACK1_NODE}")"
R2_PID="$(docker inspect -f '{{.State.Pid}}' "${RACK2_NODE}")"
B1_PID="$(docker inspect -f '{{.State.Pid}}' "${BORDER1_CTR}")"
B2_PID="$(docker inspect -f '{{.State.Pid}}' "${BORDER2_CTR}")"
CE_PID="$(docker inspect -f '{{.State.Pid}}' "${CLIENT_CTR}")"

# 1. Rack 1 <-> Border 1
ip link del e13r1b1 >/dev/null 2>&1 || true
ip link add e13r1b1 type veth peer name e13b1r1
ip link set e13r1b1 netns "${R1_PID}"
ip link set e13b1r1 netns "${B1_PID}"
nsenter -t "${R1_PID}" -n ip addr add "${R1_B1_IP}/30" dev e13r1b1
nsenter -t "${R1_PID}" -n ip link set e13r1b1 up
nsenter -t "${B1_PID}" -n ip addr add "${B1_R1_IP}/30" dev e13b1r1
nsenter -t "${B1_PID}" -n ip link set e13b1r1 up

# 2. Rack 2 <-> Border 2
ip link del e13r2b2 >/dev/null 2>&1 || true
ip link add e13r2b2 type veth peer name e13b2r2
ip link set e13r2b2 netns "${R2_PID}"
ip link set e13b2r2 netns "${B2_PID}"
nsenter -t "${R2_PID}" -n ip addr add "${R2_B2_IP}/30" dev e13r2b2
nsenter -t "${R2_PID}" -n ip link set e13r2b2 up
nsenter -t "${B2_PID}" -n ip addr add "${B2_R2_IP}/30" dev e13b2r2
nsenter -t "${B2_PID}" -n ip link set e13b2r2 up
nsenter -t "${B2_PID}" -n ip link set lo up

# 3. Border 1 <-> Client
ip link del e13b1ce >/dev/null 2>&1 || true
ip link add e13b1ce type veth peer name e13ceb1
ip link set e13b1ce netns "${B1_PID}"
ip link set e13ceb1 netns "${CE_PID}"
nsenter -t "${B1_PID}" -n ip addr add "${B1_CE_IP}/30" dev e13b1ce
nsenter -t "${B1_PID}" -n ip link set e13b1ce up
nsenter -t "${CE_PID}" -n ip addr add "${CE_B1_IP}/30" dev e13ceb1
nsenter -t "${CE_PID}" -n ip link set e13ceb1 up

# 4. Border 2 <-> Client
ip link del e13b2ce >/dev/null 2>&1 || true
ip link add e13b2ce type veth peer name e13ceb2
ip link set e13b2ce netns "${B2_PID}"
ip link set e13ceb2 netns "${CE_PID}"
nsenter -t "${B2_PID}" -n ip addr add "${B2_CE_IP}/30" dev e13b2ce
nsenter -t "${B2_PID}" -n ip link set e13b2ce up
nsenter -t "${CE_PID}" -n ip addr add "${CE_B2_IP}/30" dev e13ceb2
nsenter -t "${CE_PID}" -n ip link set e13ceb2 up
nsenter -t "${CE_PID}" -n ip link set lo up

# Habilitar encaminhamento e hash ECMP L4 no cliente e no border2
nsenter -t "${B2_PID}" -n sysctl -w net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0 >/dev/null
nsenter -t "${CE_PID}" -n sysctl -w net.ipv4.ip_forward=1 net.ipv4.fib_multipath_hash_policy=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0 >/dev/null

# Rotas de retorno e DNAT/SNAT isolado (chains E13_PRE/E13_POST)
nsenter -t "${R1_PID}" -n ip route replace 10.255.213.8/30 via "${B1_R1_IP}" dev e13r1b1
nsenter -t "${R1_PID}" -n ip route replace 10.255.213.12/30 via "${B1_R1_IP}" dev e13r1b1
nsenter -t "${R2_PID}" -n ip route replace 10.255.213.8/30 via "${B2_R2_IP}" dev e13r2b2
nsenter -t "${R2_PID}" -n ip route replace 10.255.213.12/30 via "${B2_R2_IP}" dev e13r2b2
nsenter -t "${B1_PID}" -n ip route replace 10.255.213.12/30 via "${CE_B1_IP}" dev e13b1ce
nsenter -t "${B2_PID}" -n ip route replace 10.255.213.8/30 via "${CE_B2_IP}" dev e13b2ce

nsenter -t "${R1_PID}" -n sh -c "
  iptables -t nat -N E13_PRE 2>/dev/null || iptables -t nat -F E13_PRE
  iptables -t nat -C PREROUTING -j E13_PRE 2>/dev/null || iptables -t nat -I PREROUTING 1 -j E13_PRE
  iptables -t nat -A E13_PRE -i e13r1b1 -d ${VIP} -p tcp --dport 8080 -j DNAT --to-destination ${R1_POD_IP}:8080
  iptables -t nat -N E13_POST 2>/dev/null || iptables -t nat -F E13_POST
  iptables -t nat -C POSTROUTING -j E13_POST 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j E13_POST
  iptables -t nat -A E13_POST -d ${R1_POD_IP} -p tcp --dport 8080 -j MASQUERADE
"
nsenter -t "${R2_PID}" -n sh -c "
  iptables -t nat -N E13_PRE 2>/dev/null || iptables -t nat -F E13_PRE
  iptables -t nat -C PREROUTING -j E13_PRE 2>/dev/null || iptables -t nat -I PREROUTING 1 -j E13_PRE
  iptables -t nat -A E13_PRE -i e13r2b2 -d ${VIP} -p tcp --dport 8080 -j DNAT --to-destination ${R2_POD_IP}:8080
  iptables -t nat -N E13_POST 2>/dev/null || iptables -t nat -F E13_POST
  iptables -t nat -C POSTROUTING -j E13_POST 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j E13_POST
  iptables -t nat -A E13_POST -d ${R2_POD_IP} -p tcp --dport 8080 -j MASQUERADE
"

# Configurar FRR em Border 2 (AS 65401) com Graceful Restart preserve-fw-state
docker exec "${BORDER2_CTR}" bash -c '
sed -i "s/^bgpd=no/bgpd=yes/" /etc/frr/daemons
cat <<EOF >/etc/frr/frr.conf
frr defaults traditional
hostname frr-e13-border2
no ipv6 forwarding
!
router bgp 65401
 bgp router-id 10.255.213.6
 no bgp ebgp-requires-policy
 bgp graceful-restart
 bgp graceful-restart preserve-fw-state
 neighbor 10.255.213.5 remote-as 65302
 neighbor 10.255.213.5 timers 3 9
 neighbor 10.255.213.5 timers connect 2
 neighbor 10.255.213.14 remote-as 65513
 neighbor 10.255.213.14 timers 3 9
 neighbor 10.255.213.14 timers connect 2
 address-family ipv4 unicast
  neighbor 10.255.213.5 activate
  neighbor 10.255.213.14 activate
 exit-address-family
exit
!
line vty
EOF
/usr/lib/frr/frrinit.sh start
'

# Configurar FRR em Client (AS 65513) com multipath-relax
docker exec "${CLIENT_CTR}" bash -c '
sed -i "s/^bgpd=no/bgpd=yes/" /etc/frr/daemons
cat <<EOF >/etc/frr/frr.conf
frr defaults traditional
hostname frr-e13-client
no ipv6 forwarding
!
router bgp 65513
 bgp router-id 10.255.213.10
 no bgp ebgp-requires-policy
 bgp bestpath as-path multipath-relax
 bgp graceful-restart
 neighbor 10.255.213.9 remote-as 65400
 neighbor 10.255.213.9 timers 3 9
 neighbor 10.255.213.9 timers connect 2
 neighbor 10.255.213.13 remote-as 65401
 neighbor 10.255.213.13 timers 3 9
 neighbor 10.255.213.13 timers connect 2
 address-family ipv4 unicast
  maximum-paths 16
  neighbor 10.255.213.9 activate
  neighbor 10.255.213.13 activate
 exit-address-family
exit
!
line vty
EOF
/usr/lib/frr/frrinit.sh start
'

# Configurar Border 1 (AS 65400) e CiliumBGPClusterConfig rack1/rack2
docker exec "${BORDER1_CTR}" vtysh \
  -c "configure terminal" \
  -c "router bgp ${BORDER1_ASN}" \
  -c "bgp graceful-restart" \
  -c "bgp graceful-restart preserve-fw-state" \
  -c "neighbor ${R1_B1_IP} remote-as ${RACK1_ASN}" \
  -c "neighbor ${R1_B1_IP} timers 3 9" \
  -c "neighbor ${R1_B1_IP} timers connect 2" \
  -c "neighbor ${CE_B1_IP} remote-as ${CLIENT_ASN}" \
  -c "neighbor ${CE_B1_IP} timers 3 9" \
  -c "neighbor ${CE_B1_IP} timers connect 2" \
  -c "address-family ipv4 unicast" \
  -c "neighbor ${R1_B1_IP} activate" \
  -c "neighbor ${CE_B1_IP} activate" \
  -c "exit-address-family" \
  -c "end"

cat <<EOF | k apply -f -
apiVersion: cilium.io/v2
kind: CiliumBGPClusterConfig
metadata:
  name: rack1
  labels:
    study: P003
spec:
  nodeSelector:
    matchLabels:
      topology.kubernetes.io/rack: rack1
  bgpInstances:
  - name: "rack1"
    localASN: 65301
    peers:
    - name: "leaf1"
      peerASN: 65201
      peerAddress: 10.30.1.1
      peerConfigRef:
        name: "fabric-peer"
    - name: "border1-e13"
      peerASN: ${BORDER1_ASN}
      peerAddress: "${B1_R1_IP}"
      peerConfigRef:
        name: "e13-peer-rack1"
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
    - name: "border2-e13"
      peerASN: ${BORDER2_ASN}
      peerAddress: "${B2_R2_IP}"
      peerConfigRef:
        name: "e13-peer-rack2"
EOF

echo "=== [E13] 3. Célula 1: Dual-Border ECMP Baseline + Failover Controlado (neighbor ${CE_B1_IP} shutdown em ${BORDER1_CTR}) ==="
for attempt in $(seq 1 30); do
  if docker exec "${CLIENT_CTR}" vtysh -c "show bgp ipv4 unicast ${VIP}/32" | grep -q "${B1_CE_IP}" && \
     docker exec "${CLIENT_CTR}" vtysh -c "show bgp ipv4 unicast ${VIP}/32" | grep -q "${B2_CE_IP}"; then
    echo "Célula 1: ECMP de 2 vias (${B1_CE_IP} e ${B2_CE_IP}) convergiu em ${CLIENT_CTR} na tentativa ${attempt}"
    break
  fi
  sleep 1
done
sleep 2

echo "[Célula 1 — Antes do Shutdown] RIB e FIB de ${CLIENT_CTR} para ${VIP}/32:"
docker exec "${CLIENT_CTR}" vtysh -c "show bgp ipv4 unicast ${VIP}/32"
nsenter -t "${CE_PID}" -n ip route show "${VIP}/32"

PRE_R1=0
PRE_R2=0
for i in $(seq 1 30); do
  resp="$(nsenter -t "${CE_PID}" -n curl -sS --max-time 2 "http://${VIP}:8080/hostname" || true)"
  [[ "${resp}" == "e13-echo-rack1" ]] && PRE_R1=$((PRE_R1 + 1))
  [[ "${resp}" == "e13-echo-rack2" ]] && PRE_R2=$((PRE_R2 + 1))
done
echo "cell1_pre_shutdown_hits: rack1=${PRE_R1}/30 rack2=${PRE_R2}/30"

# Iniciar sonda contínua L4 (100 ms) e aplicar neighbor shutdown em border1
start_probe_loop /tmp/e13-cell1-probes.log "${CE_PID}"
sleep 1.5
echo "[Célula 1] Executando neighbor ${CE_B1_IP} shutdown em ${BORDER1_CTR}..."
docker exec "${BORDER1_CTR}" vtysh \
  -c "configure terminal" \
  -c "router bgp ${BORDER1_ASN}" \
  -c "neighbor ${CE_B1_IP} shutdown" \
  -c "end"
sleep 2

echo "[Célula 1 — Durante Shutdown de border1] FIB de ${CLIENT_CTR} para ${VIP}/32:"
nsenter -t "${CE_PID}" -n ip route show "${VIP}/32"

DUR_R1=0
DUR_R2=0
for i in $(seq 1 20); do
  resp="$(nsenter -t "${CE_PID}" -n curl -sS --max-time 2 "http://${VIP}:8080/hostname" || true)"
  [[ "${resp}" == "e13-echo-rack1" ]] && DUR_R1=$((DUR_R1 + 1))
  [[ "${resp}" == "e13-echo-rack2" ]] && DUR_R2=$((DUR_R2 + 1))
done
echo "cell1_during_shutdown_hits: rack1=${DUR_R1}/20 rack2=${DUR_R2}/20"

echo "[Célula 1] Restaurando sessão em ${BORDER1_CTR} (no neighbor ${CE_B1_IP} shutdown)..."
docker exec "${BORDER1_CTR}" vtysh \
  -c "configure terminal" \
  -c "router bgp ${BORDER1_ASN}" \
  -c "no neighbor ${CE_B1_IP} shutdown" \
  -c "end"

for attempt in $(seq 1 20); do
  if nsenter -t "${CE_PID}" -n ip route show "${VIP}/32" | grep -q "${B1_CE_IP}"; then
    break
  fi
  sleep 0.5
done
sleep 1.5
stop_probe_loop

echo "[Célula 1 — Depois do Shutdown] FIB de ${CLIENT_CTR} para ${VIP}/32:"
nsenter -t "${CE_PID}" -n ip route show "${VIP}/32"

POST_R1=0
POST_R2=0
for i in $(seq 1 30); do
  resp="$(nsenter -t "${CE_PID}" -n curl -sS --max-time 2 "http://${VIP}:8080/hostname" || true)"
  [[ "${resp}" == "e13-echo-rack1" ]] && POST_R1=$((POST_R1 + 1))
  [[ "${resp}" == "e13-echo-rack2" ]] && POST_R2=$((POST_R2 + 1))
done
echo "cell1_post_shutdown_hits: rack1=${POST_R1}/30 rack2=${POST_R2}/30"
CELL1_SUMMARY="$(analyze_probe_log /tmp/e13-cell1-probes.log)"
echo "cell1_l4_probe_summary: ${CELL1_SUMMARY}"

echo "=== [E13] 4. Célula 2: Restart do Agente Cilium em ${RACK2_NODE} Com vs Sem Graceful Restart ==="
# Isolar caminho único via Border 2 (desligando neighbor de Border 1) para medir o efeito puro do GR
docker exec "${BORDER1_CTR}" vtysh \
  -c "configure terminal" \
  -c "router bgp ${BORDER1_ASN}" \
  -c "neighbor ${CE_B1_IP} shutdown" \
  -c "end"
sleep 2

echo "--- [Subcélula 2A: Com Graceful Restart (enabled: true, restartTimeSeconds: 30)] ---"
docker exec "${BORDER2_CTR}" vtysh -c "show bgp ipv4 unicast neighbors ${R2_B2_IP}" | grep -iE "Graceful Restart|BGP state" || true

start_probe_loop /tmp/e13-cell2a-probes.log "${CE_PID}"
sleep 1
CILIUM_W2="$(k -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName="${RACK2_NODE}" -o jsonpath='{.items[0].metadata.name}')"
echo "[Subcélula 2A] Reiniciando pod ${CILIUM_W2} em ${RACK2_NODE} com GR=true..."
k -n kube-system delete pod "${CILIUM_W2}" --grace-period=0 --force >/dev/null
sleep 3
echo "[Subcélula 2A — 3 s após delete do cilium-agent] RIB de ${BORDER2_CTR} e FIB de ${CLIENT_CTR}:"
docker exec "${BORDER2_CTR}" vtysh -c "show bgp ipv4 unicast ${VIP}/32" || true
nsenter -t "${CE_PID}" -n ip route show "${VIP}/32" || true

k -n kube-system wait --for=condition=Ready pod -l k8s-app=cilium --field-selector spec.nodeName="${RACK2_NODE}" --timeout=90s >/dev/null
for attempt in $(seq 1 30); do
  if docker exec "${BORDER2_CTR}" vtysh -c "show bgp ipv4 unicast summary" | grep "${R2_B2_IP}" | grep -vE "Idle|Active|Connect" >/dev/null; then
    break
  fi
  sleep 1
done
sleep 2
stop_probe_loop
CELL2A_SUMMARY="$(analyze_probe_log /tmp/e13-cell2a-probes.log)"
echo "cell2a_gr_enabled_l4_summary: ${CELL2A_SUMMARY}"

echo "--- [Subcélula 2B (Controle Negativo): Sem Graceful Restart (enabled: false)] ---"
cat <<'EOF' | k apply -f -
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata:
  name: e13-peer-rack2
spec:
  timers:
    connectRetryTimeSeconds: 2
    holdTimeSeconds: 9
    keepAliveTimeSeconds: 3
  ebgpMultihop: 1
  gracefulRestart:
    enabled: false
  families:
  - afi: ipv4
    safi: unicast
    advertisements:
      matchLabels:
        advertise: e13-bgp
EOF

docker exec "${BORDER2_CTR}" vtysh \
  -c "configure terminal" \
  -c "router bgp ${BORDER2_ASN}" \
  -c "no bgp graceful-restart" \
  -c "no bgp graceful-restart preserve-fw-state" \
  -c "end" \
  -c "clear bgp ipv4 unicast ${R2_B2_IP}" >/dev/null 2>&1 || true

for attempt in $(seq 1 30); do
  if nsenter -t "${CE_PID}" -n ip route show "${VIP}/32" | grep -q "${B2_CE_IP}"; then
    break
  fi
  sleep 1
done
sleep 2

start_probe_loop /tmp/e13-cell2b-probes.log "${CE_PID}"
sleep 1
CILIUM_W2="$(k -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName="${RACK2_NODE}" -o jsonpath='{.items[0].metadata.name}')"
echo "[Subcélula 2B] Reiniciando pod ${CILIUM_W2} em ${RACK2_NODE} com GR=false..."
k -n kube-system delete pod "${CILIUM_W2}" --grace-period=0 --force >/dev/null
sleep 3
echo "[Subcélula 2B — 3 s após delete do cilium-agent] RIB de ${BORDER2_CTR} e FIB de ${CLIENT_CTR} (esperado: rota retirada!):"
docker exec "${BORDER2_CTR}" vtysh -c "show bgp ipv4 unicast ${VIP}/32" || true
nsenter -t "${CE_PID}" -n ip route show "${VIP}/32" || true

k -n kube-system wait --for=condition=Ready pod -l k8s-app=cilium --field-selector spec.nodeName="${RACK2_NODE}" --timeout=90s >/dev/null
for attempt in $(seq 1 40); do
  if nsenter -t "${CE_PID}" -n ip route show "${VIP}/32" | grep -q "${B2_CE_IP}"; then
    break
  fi
  sleep 1
done
sleep 2
stop_probe_loop
CELL2B_SUMMARY="$(analyze_probe_log /tmp/e13-cell2b-probes.log)"
echo "cell2b_gr_disabled_l4_summary: ${CELL2B_SUMMARY}"

echo "=== [E13] CONCLUÍDO COM SUCESSO ==="
