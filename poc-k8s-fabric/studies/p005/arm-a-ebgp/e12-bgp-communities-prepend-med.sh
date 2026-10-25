#!/usr/bin/env bash
# ==============================================================================
# P005-S002 (Onda 2 — Braço A): E12 — Communities BGP (65400:100 / 65400:200),
# AS-Path Prepend e MED
# ==============================================================================
set -euo pipefail

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

NS="p005-e12"
VIP="10.202.255.192"
RACK1_NODE="p003-gw-worker"
RACK1_ASN="65301"
RACK2_NODE="p003-gw-worker2"
RACK2_ASN="65302"
BORDER_CTR="clab-p003-gw-fabric-border1"
BORDER_ASN="65400"
FRR_CE_CTR="clab-p003-gw-fabric-frr-e12-ce"
FRR_IMAGE="${FRR_IMAGE:-frrouting/frr:v8.4.1}"
CE_ASN="65512"

# Enlaces:
# Rack 1 (p003-gw-worker e12r1c 10.255.212.1/30) <-> Border1 (e12r1b 10.255.212.2/30)
RACK1_IP="10.255.212.1"
BORDER_R1_IP="10.255.212.2"
# Rack 2 (p003-gw-worker2 e12r2c 10.255.212.5/30) <-> Border1 (e12r2b 10.255.212.6/30)
RACK2_IP="10.255.212.5"
BORDER_R2_IP="10.255.212.6"
# Border1 (e12ce0 10.255.212.9/30) <-> FRR CE (e12ce1 10.255.212.10/30)
BORDER_CE_IP="10.255.212.9"
CE_IP="10.255.212.10"

if $DRY_RUN; then
  cat <<EOF
[DRY-RUN] E12 — Communities BGP (65400:100 / 65400:200), AS-Path Prepend e MED
  Cluster: ${P003_CONTEXT} (expected UID: ${EXPECTED_UID})
  VIP dedicada: ${VIP}/32 (Service/e12-vip-svc em ${NS})
  Rack 1: ${RACK1_NODE} (AS ${RACK1_ASN}, ${RACK1_IP}/30) <-> ${BORDER_CTR} (${BORDER_R1_IP}/30)
  Rack 2: ${RACK2_NODE} (AS ${RACK2_ASN}, ${RACK2_IP}/30) <-> ${BORDER_CTR} (${BORDER_R2_IP}/30)
  CE externo: ${FRR_CE_CTR} (AS ${CE_ASN}, ${CE_IP}/30) <-> ${BORDER_CTR} (${BORDER_CE_IP}/30)
  Passos planejados:
    1. Auditar CRD CiliumBGPAdvertisement (suporte nativo a communities standard/large/wellKnown; ausência de AS-path prepend e MED no Cilium OSS 1.20.2).
    2. Célula 1 (Negativo — Sem Route-Policy em border1):
       - Rack 1 anuncia ${VIP}/32 com community 65400:100; Rack 2 anuncia ${VIP}/32 com 65400:200.
       - Comprovar que sem route-map em border1 ambos os caminhos entram em ECMP (multipath=true, 2 nexthops ativos).
    3. Célula 2 (Positivo — Route-Policy em border1 traduzindo 65400:100 -> MED 10 e 65400:200 -> MED 200 + AS-path prepend 2x):
       - Comprovar que border1 e frr-e12-ce elegem deterministicamente Rack 1 (AS 65301, MED 10) e 10/10 requisições HTTP a ${VIP}:8080/hostname respondem e12-echo-rack1.
    4. Célula 3 (Inversão de Preferência na Origem Cilium — Swap 65400:200 em Rack 1 e 65400:100 em Rack 2):
       - Sem tocar no border1, atualizar apenas os CRDs CiliumBGPAdvertisement e comprovar inversão automática da RIB/FIB para Rack 2 (AS 65302) e 10/10 respostas HTTP de e12-echo-rack2.
    5. Rollback completo de CRDs, enlaces e FRR.
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

cleanup() {
  echo "[CLEANUP] Restaurando baseline BGP (rack1/rack2), border1 e removendo recursos de E12..."
  restore_bgp_baseline
  k delete ciliumbgpadvertisement e12-adv-rack1 e12-adv-rack2 --ignore-not-found >/dev/null 2>&1 || true
  k delete ciliumbgppeerconfig e12-peer-rack1 e12-peer-rack2 --ignore-not-found >/dev/null 2>&1 || true
  k delete ns "${NS}" --ignore-not-found >/dev/null 2>&1 || true
  for node in "${RACK1_NODE}" "${RACK2_NODE}"; do
    docker exec "${node}" sh -c '
      iptables -t nat -D PREROUTING -j E12_PRE 2>/dev/null || true
      iptables -t nat -F E12_PRE 2>/dev/null || true
      iptables -t nat -X E12_PRE 2>/dev/null || true
      iptables -t nat -D POSTROUTING -j E12_POST 2>/dev/null || true
      iptables -t nat -F E12_POST 2>/dev/null || true
      iptables -t nat -X E12_POST 2>/dev/null || true
    ' >/dev/null 2>&1 || true
  done
  docker exec "${RACK1_NODE}" ip route del 10.255.212.8/30 >/dev/null 2>&1 || true
  docker exec "${RACK2_NODE}" ip route del 10.255.212.8/30 >/dev/null 2>&1 || true
  docker exec "${BORDER_CTR}" vtysh \
    -c "configure terminal" \
    -c "router bgp ${BORDER_ASN}" \
    -c "no neighbor ${RACK1_IP} remote-as ${RACK1_ASN}" \
    -c "no neighbor ${RACK2_IP} remote-as ${RACK2_ASN}" \
    -c "no neighbor ${CE_IP} remote-as ${CE_ASN}" \
    -c "no bgp always-compare-med" \
    -c "no bgp deterministic-med" \
    -c "exit" \
    -c "no route-map RM-E12-RACK1-IN" \
    -c "no route-map RM-E12-RACK2-IN" \
    -c "no route-map RM-E12-TO-CE" \
    -c "no bgp community-list standard E12-PRIMARY" \
    -c "no bgp community-list standard E12-SECONDARY" \
    -c "end" >/dev/null 2>&1 || true
  docker rm -f "${FRR_CE_CTR}" >/dev/null 2>&1 || true
  docker exec "${RACK1_NODE}" ip link del e12r1c >/dev/null 2>&1 || true
  docker exec "${RACK2_NODE}" ip link del e12r2c >/dev/null 2>&1 || true
  docker exec "${BORDER_CTR}" ip link del e12r1b >/dev/null 2>&1 || true
  docker exec "${BORDER_CTR}" ip link del e12r2b >/dev/null 2>&1 || true
  docker exec "${BORDER_CTR}" ip link del e12ce0 >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== [E12] 1. Auditoria de Schema CRD CiliumBGPAdvertisement (Cilium 1.20.2) ==="
COMM_FIELDS="$(k get crd ciliumbgpadvertisements.cilium.io -o json | grep -iEc 'communities|localPreference' || true)"
PREPEND_MED_FIELDS="$(k get crd ciliumbgpadvertisements.cilium.io -o json | grep -iEc 'prepend|asPath|med|multiExitDisc' || true)"
echo "ciliumbgpadvertisements_communities_localpref_mentions=${COMM_FIELDS}"
echo "ciliumbgpadvertisements_prepend_or_med_mentions=${PREPEND_MED_FIELDS}"

echo "=== [E12] 2. Criando Workloads e Service VIP ${VIP}/32 em ${NS} ==="
cat <<EOF | k apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
---
apiVersion: v1
kind: Pod
metadata:
  name: e12-echo-rack1
  namespace: ${NS}
  labels:
    app: e12-echo
    rack: rack1
spec:
  nodeName: ${RACK1_NODE}
  containers:
  - name: agnhost
    image: registry.k8s.io/e2e-test-images/agnhost:2.47
    imagePullPolicy: IfNotPresent
    args: ["netexec", "--http-port=8080"]
    ports:
    - containerPort: 8080
---
apiVersion: v1
kind: Pod
metadata:
  name: e12-echo-rack2
  namespace: ${NS}
  labels:
    app: e12-echo
    rack: rack2
spec:
  nodeName: ${RACK2_NODE}
  containers:
  - name: agnhost
    image: registry.k8s.io/e2e-test-images/agnhost:2.47
    imagePullPolicy: IfNotPresent
    args: ["netexec", "--http-port=8080"]
    ports:
    - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: e12-vip-svc
  namespace: ${NS}
  labels:
    e12-bgp-advertise: "true"
  annotations:
    lbipam.cilium.io/ips: "${VIP}"
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  selector:
    app: e12-echo
  ports:
  - name: http
    port: 8080
    targetPort: 8080
EOF

k -n "${NS}" wait --for=condition=Ready pod/e12-echo-rack1 pod/e12-echo-rack2 --timeout=60s
RACK1_POD_IP="$(k -n "${NS}" get pod e12-echo-rack1 -o jsonpath='{.status.podIP}')"
RACK2_POD_IP="$(k -n "${NS}" get pod e12-echo-rack2 -o jsonpath='{.status.podIP}')"
echo "e12-echo-rack1 PodIP=${RACK1_POD_IP} (${RACK1_NODE})"
echo "e12-echo-rack2 PodIP=${RACK2_POD_IP} (${RACK2_NODE})"

echo "=== [E12] 3. Provisionando ${FRR_CE_CTR} e Enlaces Dedicados para ${BORDER_CTR} ==="
docker rm -f "${FRR_CE_CTR}" >/dev/null 2>&1 || true
docker run -d --name "${FRR_CE_CTR}" --hostname frr-e12-ce --network none --privileged \
  --entrypoint /bin/sh "${FRR_IMAGE}" -c "exec sleep infinity" >/dev/null

R1_PID="$(docker inspect -f '{{.State.Pid}}' "${RACK1_NODE}")"
R2_PID="$(docker inspect -f '{{.State.Pid}}' "${RACK2_NODE}")"
BORDER_PID="$(docker inspect -f '{{.State.Pid}}' "${BORDER_CTR}")"
CE_PID="$(docker inspect -f '{{.State.Pid}}' "${FRR_CE_CTR}")"

# Rack 1 <-> Border1
ip link del e12r1c >/dev/null 2>&1 || true
ip link add e12r1c type veth peer name e12r1b
ip link set e12r1c netns "${R1_PID}"
ip link set e12r1b netns "${BORDER_PID}"
nsenter -t "${R1_PID}" -n ip addr add "${RACK1_IP}/30" dev e12r1c
nsenter -t "${R1_PID}" -n ip link set e12r1c up
nsenter -t "${BORDER_PID}" -n ip addr add "${BORDER_R1_IP}/30" dev e12r1b
nsenter -t "${BORDER_PID}" -n ip link set e12r1b up

# Rack 2 <-> Border1
ip link del e12r2c >/dev/null 2>&1 || true
ip link add e12r2c type veth peer name e12r2b
ip link set e12r2c netns "${R2_PID}"
ip link set e12r2b netns "${BORDER_PID}"
nsenter -t "${R2_PID}" -n ip addr add "${RACK2_IP}/30" dev e12r2c
nsenter -t "${R2_PID}" -n ip link set e12r2c up
nsenter -t "${BORDER_PID}" -n ip addr add "${BORDER_R2_IP}/30" dev e12r2b
nsenter -t "${BORDER_PID}" -n ip link set e12r2b up

# Border1 <-> FRR CE
ip link del e12ce0 >/dev/null 2>&1 || true
ip link add e12ce0 type veth peer name e12ce1
ip link set e12ce0 netns "${BORDER_PID}"
ip link set e12ce1 netns "${CE_PID}"
nsenter -t "${BORDER_PID}" -n ip addr add "${BORDER_CE_IP}/30" dev e12ce0
nsenter -t "${BORDER_PID}" -n ip link set e12ce0 up
nsenter -t "${CE_PID}" -n ip addr add "${CE_IP}/30" dev e12ce1
nsenter -t "${CE_PID}" -n ip link set e12ce1 up
nsenter -t "${CE_PID}" -n ip link set lo up

# Rotas de retorno e DNAT/SNAT isolado (chains E12_PRE/E12_POST) nas interfaces dedicadas e12r1c/e12r2c
nsenter -t "${R1_PID}" -n ip route replace 10.255.212.8/30 via "${BORDER_R1_IP}" dev e12r1c
nsenter -t "${R2_PID}" -n ip route replace 10.255.212.8/30 via "${BORDER_R2_IP}" dev e12r2c
nsenter -t "${R1_PID}" -n sh -c "
  iptables -t nat -N E12_PRE 2>/dev/null || iptables -t nat -F E12_PRE
  iptables -t nat -C PREROUTING -j E12_PRE 2>/dev/null || iptables -t nat -I PREROUTING 1 -j E12_PRE
  iptables -t nat -A E12_PRE -i e12r1c -d ${VIP} -p tcp --dport 8080 -j DNAT --to-destination ${RACK1_POD_IP}:8080
  iptables -t nat -N E12_POST 2>/dev/null || iptables -t nat -F E12_POST
  iptables -t nat -C POSTROUTING -j E12_POST 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j E12_POST
  iptables -t nat -A E12_POST -d ${RACK1_POD_IP} -p tcp --dport 8080 -j MASQUERADE
"
nsenter -t "${R2_PID}" -n sh -c "
  iptables -t nat -N E12_PRE 2>/dev/null || iptables -t nat -F E12_PRE
  iptables -t nat -C PREROUTING -j E12_PRE 2>/dev/null || iptables -t nat -I PREROUTING 1 -j E12_PRE
  iptables -t nat -A E12_PRE -i e12r2c -d ${VIP} -p tcp --dport 8080 -j DNAT --to-destination ${RACK2_POD_IP}:8080
  iptables -t nat -N E12_POST 2>/dev/null || iptables -t nat -F E12_POST
  iptables -t nat -C POSTROUTING -j E12_POST 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j E12_POST
  iptables -t nat -A E12_POST -d ${RACK2_POD_IP} -p tcp --dport 8080 -j MASQUERADE
"

docker exec "${FRR_CE_CTR}" bash -c '
sed -i "s/^bgpd=no/bgpd=yes/" /etc/frr/daemons
cat <<EOF >/etc/frr/frr.conf
frr defaults traditional
hostname frr-e12-ce
no ipv6 forwarding
!
router bgp 65512
 bgp router-id 10.255.212.10
 no bgp ebgp-requires-policy
 neighbor 10.255.212.9 remote-as 65400
 neighbor 10.255.212.9 timers 3 9
 address-family ipv4 unicast
  neighbor 10.255.212.9 activate
 exit-address-family
exit
!
line vty
EOF
/usr/lib/frr/frrinit.sh start
'

echo "=== [E12] 4. Célula 1 (Controle Negativo): Sem Route-Map em ${BORDER_CTR} (Communities ignoradas -> ECMP) ==="
cat <<EOF | k apply -f -
apiVersion: cilium.io/v2
kind: CiliumBGPAdvertisement
metadata:
  name: e12-adv-rack1
  labels:
    advertise: e12-rack1
spec:
  advertisements:
    - advertisementType: "Service"
      service:
        addresses:
          - LoadBalancerIP
      selector:
        matchLabels:
          e12-bgp-advertise: "true"
      attributes:
        communities:
          standard:
            - "65400:100"
---
apiVersion: cilium.io/v2
kind: CiliumBGPAdvertisement
metadata:
  name: e12-adv-rack2
  labels:
    advertise: e12-rack2
spec:
  advertisements:
    - advertisementType: "Service"
      service:
        addresses:
          - LoadBalancerIP
      selector:
        matchLabels:
          e12-bgp-advertise: "true"
      attributes:
        communities:
          standard:
            - "65400:200"
---
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata:
  name: e12-peer-rack1
spec:
  timers:
    connectRetryTimeSeconds: 3
    holdTimeSeconds: 9
    keepAliveTimeSeconds: 3
  families:
    - afi: ipv4
      safi: unicast
      advertisements:
        matchLabels:
          advertise: e12-rack1
---
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata:
  name: e12-peer-rack2
spec:
  timers:
    connectRetryTimeSeconds: 3
    holdTimeSeconds: 9
    keepAliveTimeSeconds: 3
  families:
    - afi: ipv4
      safi: unicast
      advertisements:
        matchLabels:
          advertise: e12-rack2
---
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
    - name: "border1-e12"
      peerASN: ${BORDER_ASN}
      peerAddress: "${BORDER_R1_IP}"
      peerConfigRef:
        name: "e12-peer-rack1"
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
    - name: "border1-e12"
      peerASN: ${BORDER_ASN}
      peerAddress: "${BORDER_R2_IP}"
      peerConfigRef:
        name: "e12-peer-rack2"
EOF

docker exec "${BORDER_CTR}" vtysh \
  -c "configure terminal" \
  -c "router bgp ${BORDER_ASN}" \
  -c "neighbor ${RACK1_IP} remote-as ${RACK1_ASN}" \
  -c "neighbor ${RACK1_IP} timers 3 9" \
  -c "neighbor ${RACK2_IP} remote-as ${RACK2_ASN}" \
  -c "neighbor ${RACK2_IP} timers 3 9" \
  -c "neighbor ${CE_IP} remote-as ${CE_ASN}" \
  -c "neighbor ${CE_IP} timers 3 9" \
  -c "address-family ipv4 unicast" \
  -c "neighbor ${RACK1_IP} activate" \
  -c "neighbor ${RACK2_IP} activate" \
  -c "neighbor ${CE_IP} activate" \
  -c "exit-address-family" \
  -c "end"

for attempt in $(seq 1 30); do
  if docker exec "${BORDER_CTR}" vtysh -c "show bgp ipv4 unicast ${VIP}/32" | grep -q "${RACK1_IP}" && \
     docker exec "${BORDER_CTR}" vtysh -c "show bgp ipv4 unicast ${VIP}/32" | grep -q "${RACK2_IP}"; then
    echo "Célula 1: ambos os caminhos (${RACK1_IP} e ${RACK2_IP}) recebidos em border1 na tentativa ${attempt}"
    break
  fi
  sleep 1
done
sleep 2

echo "[Célula 1 — Sem Policy] RIB BGP de ${BORDER_CTR} para ${VIP}/32:"
docker exec "${BORDER_CTR}" vtysh -c "show bgp ipv4 unicast ${VIP}/32"
echo "[Célula 1 — Sem Policy] FIB de ${BORDER_CTR} para ${VIP}/32 (esperado: 2 nexthops em ECMP):"
docker exec "${BORDER_CTR}" vtysh -c "show ip route ${VIP}/32"

echo "=== [E12] 5. Célula 2 (Positiva): Aplicando Route-Map em ${BORDER_CTR} (65400:100 -> MED 10 primário; 65400:200 -> MED 200 + AS-Path Prepend 2x) ==="
docker exec "${BORDER_CTR}" vtysh \
  -c "configure terminal" \
  -c "bgp community-list standard E12-PRIMARY permit 65400:100" \
  -c "bgp community-list standard E12-SECONDARY permit 65400:200" \
  -c "route-map RM-E12-RACK1-IN permit 10" \
  -c "match community E12-PRIMARY" \
  -c "set metric 10" \
  -c "exit" \
  -c "route-map RM-E12-RACK1-IN permit 20" \
  -c "match community E12-SECONDARY" \
  -c "set metric 200" \
  -c "set as-path prepend ${RACK1_ASN} ${RACK1_ASN}" \
  -c "exit" \
  -c "route-map RM-E12-RACK2-IN permit 10" \
  -c "match community E12-PRIMARY" \
  -c "set metric 10" \
  -c "exit" \
  -c "route-map RM-E12-RACK2-IN permit 20" \
  -c "match community E12-SECONDARY" \
  -c "set metric 200" \
  -c "set as-path prepend ${RACK2_ASN} ${RACK2_ASN}" \
  -c "exit" \
  -c "route-map RM-E12-TO-CE permit 10" \
  -c "match community E12-PRIMARY" \
  -c "set metric 10" \
  -c "exit" \
  -c "route-map RM-E12-TO-CE permit 20" \
  -c "match community E12-SECONDARY" \
  -c "set metric 200" \
  -c "set as-path prepend ${BORDER_ASN} ${BORDER_ASN}" \
  -c "exit" \
  -c "router bgp ${BORDER_ASN}" \
  -c "bgp always-compare-med" \
  -c "bgp deterministic-med" \
  -c "address-family ipv4 unicast" \
  -c "neighbor ${RACK1_IP} route-map RM-E12-RACK1-IN in" \
  -c "neighbor ${RACK2_IP} route-map RM-E12-RACK2-IN in" \
  -c "neighbor ${CE_IP} route-map RM-E12-TO-CE out" \
  -c "exit-address-family" \
  -c "end"

docker exec "${BORDER_CTR}" vtysh \
  -c "clear bgp ipv4 unicast ${RACK1_IP} soft in" \
  -c "clear bgp ipv4 unicast ${RACK2_IP} soft in" \
  -c "clear bgp ipv4 unicast ${CE_IP} soft out"
sleep 3

echo "[Célula 2 — Com Policy] RIB BGP de ${BORDER_CTR} para ${VIP}/32:"
docker exec "${BORDER_CTR}" vtysh -c "show bgp ipv4 unicast ${VIP}/32"
echo "[Célula 2 — Com Policy] FIB de ${BORDER_CTR} para ${VIP}/32 (esperado: nexthop único ${RACK1_IP}):"
docker exec "${BORDER_CTR}" vtysh -c "show ip route ${VIP}/32"
echo "[Célula 2 — Com Policy] RIB BGP de ${FRR_CE_CTR} (AS ${CE_ASN}) para ${VIP}/32:"
docker exec "${FRR_CE_CTR}" vtysh -c "show bgp ipv4 unicast ${VIP}/32"

R1_HITS_C2=0
R2_HITS_C2=0
for i in $(seq 1 10); do
  RESP="$(nsenter -t "${CE_PID}" -n curl -sS --max-time 2 "http://${VIP}:8080/hostname" || true)"
  if [[ "${RESP}" == "e12-echo-rack1" ]]; then
    R1_HITS_C2=$((R1_HITS_C2 + 1))
  elif [[ "${RESP}" == "e12-echo-rack2" ]]; then
    R2_HITS_C2=$((R2_HITS_C2 + 1))
  fi
done
echo "cell2_http_hits: e12-echo-rack1=${R1_HITS_C2}/10 e12-echo-rack2=${R2_HITS_C2}/10"

echo "=== [E12] 6. Célula 3 (Inversão de Preferência na Origem Cilium): Swap 65400:200 em Rack 1 e 65400:100 em Rack 2 ==="
cat <<EOF | k apply -f -
apiVersion: cilium.io/v2
kind: CiliumBGPAdvertisement
metadata:
  name: e12-adv-rack1
  labels:
    advertise: e12-rack1
spec:
  advertisements:
    - advertisementType: "Service"
      service:
        addresses:
          - LoadBalancerIP
      selector:
        matchLabels:
          e12-bgp-advertise: "true"
      attributes:
        communities:
          standard:
            - "65400:200"
---
apiVersion: cilium.io/v2
kind: CiliumBGPAdvertisement
metadata:
  name: e12-adv-rack2
  labels:
    advertise: e12-rack2
spec:
  advertisements:
    - advertisementType: "Service"
      service:
        addresses:
          - LoadBalancerIP
      selector:
        matchLabels:
          e12-bgp-advertise: "true"
      attributes:
        communities:
          standard:
            - "65400:100"
EOF

sleep 4

echo "[Célula 3 — Após Swap de Communities no Cilium] RIB BGP de ${BORDER_CTR} para ${VIP}/32:"
docker exec "${BORDER_CTR}" vtysh -c "show bgp ipv4 unicast ${VIP}/32"
echo "[Célula 3 — Após Swap de Communities no Cilium] FIB de ${BORDER_CTR} para ${VIP}/32 (esperado: nexthop único ${RACK2_IP}):"
docker exec "${BORDER_CTR}" vtysh -c "show ip route ${VIP}/32"
echo "[Célula 3 — Após Swap de Communities no Cilium] RIB BGP de ${FRR_CE_CTR} (AS ${CE_ASN}) para ${VIP}/32:"
docker exec "${FRR_CE_CTR}" vtysh -c "show bgp ipv4 unicast ${VIP}/32"

R1_HITS_C3=0
R2_HITS_C3=0
for i in $(seq 1 10); do
  RESP="$(nsenter -t "${CE_PID}" -n curl -sS --max-time 2 "http://${VIP}:8080/hostname" || true)"
  if [[ "${RESP}" == "e12-echo-rack1" ]]; then
    R1_HITS_C3=$((R1_HITS_C3 + 1))
  elif [[ "${RESP}" == "e12-echo-rack2" ]]; then
    R2_HITS_C3=$((R2_HITS_C3 + 1))
  fi
done
echo "cell3_http_hits: e12-echo-rack1=${R1_HITS_C3}/10 e12-echo-rack2=${R2_HITS_C3}/10"

echo "=== [E12] CONCLUÍDO COM SUCESSO ==="
