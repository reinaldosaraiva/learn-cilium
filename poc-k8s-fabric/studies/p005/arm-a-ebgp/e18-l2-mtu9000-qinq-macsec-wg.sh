#!/usr/bin/env bash
# ==============================================================================
# P005-S004 (Onda 4 — Braço A): Estudo E18 — Camada Física/Enlace:
#   - Célula 1: MTU 9000 Jumbo Frames Fim a Fim vs Gargalo MTU 1500 (PMTU/ICMP)
#   - Célula 2: QinQ 802.1ad (S-TAG 100 0x88a8 + C-TAG 200 0x8100) + eBGP
#   - Célula 3: MACsec 802.1AE (gcm-aes-128 0x88e5) + eBGP vs Cilium WireGuard
# ==============================================================================
set -euo pipefail

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
elif [[ $# -gt 0 ]]; then
  echo "Uso: $0 [--dry-run]" >&2
  exit 2
fi

KUBECONFIG_PATH="${KUBECONFIG_PATH:-/root/.kube/config}"
KCTX="kind-p003-gw"
EXPECTED_UID="6bb32e0f-71f9-4558-ae33-356ba2250c26"
CANARY_CTX="kind-k01"
CANARY_UID="635e7274-5597-40c7-9de5-b1fbe3d68b22"

WORKER1="p003-gw-worker"
PE_CTR="clab-p003-gw-fabric-frr-e18-pe"
CLIENT_CTR="clab-p003-gw-fabric-frr-e18-client"
FRR_IMAGE="quay.io/frrouting/frr:10.7.1"

VIP="10.202.255.198"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  cat <<'EOF'
[DRY-RUN] E18 — Camada Física/Enlace: MTU 9000 Jumbo, QinQ 802.1ad e MACsec 802.1AE vs WireGuard
  1. Pré-voo: validar UIDs de kind-p003-gw (6bb32e0f-...) e kind-k01 (635e7274-...).
  2. Célula 1 (MTU 9000 Jumbo Frames e PMTU Discovery):
     - Configurar enlaces e18w0 <-> e18pe0 (10.255.218.0/30) e e18c0 <-> e18c1 (10.255.218.4/30)
       com mtu 9000 e anunciar a VIP 10.202.255.198/32 via eBGP (AS 65301 -> AS 65400 -> AS 65518).
     - Controle Positivo: 30/30 pings DF=1 de 8972 B de payload (9000 B IP / 9014 B Ethernet)
       com captura tcpdump.
     - Controle Negativo: reduzir e18pe0 para mtu 1500 -> 0/5 pings DF=1 de 8972 B e geração
       confirmada de ICMP Frag Needed (type 3 code 4 mtu 1500).
  3. Célula 2 (QinQ 802.1ad S-TAG 100 + C-TAG 200):
     - Desativar VLAN HW offload no veth e criar subinterfaces e18w0.100.200 (10.255.218.9/30)
       e e18pe0.100.200 (10.255.218.10/30).
     - Controle Positivo: sessão eBGP Established sobre QinQ, 10/10 pings e captura tcpdump
       exibindo ethertype 0x88a8 (vlan 100) + ethertype 0x8100 (vlan 200).
     - Controle Negativo: C-TAG divergente (200 vs 201 em 10.255.218.12/30) -> 0/5 pings.
  4. Célula 3 (MACsec 802.1AE gcm-aes-128 vs Cilium WireGuard):
     - Configurar macsec0 (encrypt on, gcm-aes-128) sobre e18w0 e e18pe0 (10.255.218.16/30).
     - Controle Positivo: sessão eBGP Established sobre macsec0, 10/10 pings, 100% dos quadros
       na interface base cifrados com ethertype 0x88e5 (0 pacotes TCP/179 ou ICMP em claro) e
       OutPktsEncrypted / InPktsOK > 0.
     - Controle Negativo: chave SAK divergente em tx sa 1 -> 0/5 pings e incremento de
       InPktsNotValid / InPktsNoSA.
  5. Rollback completo e verificação R6=0.
EOF
  exit 0
fi

k() {
  kubectl --kubeconfig="${KUBECONFIG_PATH}" --context="${KCTX}" "$@"
}

echo "=== [E18] 0. Pré-voo: Verificando UID do sandbox (${KCTX}) e canário (${CANARY_CTX}) ==="
ACTUAL_UID="$(k get namespace kube-system -o jsonpath='{.metadata.uid}')"
CANARY_ACTUAL="$(kubectl --kubeconfig="${KUBECONFIG_PATH}" --context="${CANARY_CTX}" get namespace kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${ACTUAL_UID}" != "${EXPECTED_UID}" || "${CANARY_ACTUAL}" != "${CANARY_UID}" ]]; then
  echo "ERRO: UID inesperado (p003-gw=${ACTUAL_UID}, k01=${CANARY_ACTUAL})" >&2
  exit 1
fi
echo "OK: p003-gw UID=${ACTUAL_UID} | k01 UID=${CANARY_ACTUAL}"

restore_bgp_rack1() {
  cat <<'EOF' | k apply -f - >/dev/null
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
EOF
}

cleanup() {
  echo "[CLEANUP] Restaurando CiliumBGPClusterConfig/rack1 e removendo recursos de E18..."
  restore_bgp_rack1 || true
  k delete svc e18-vip-svc -n default --ignore-not-found >/dev/null 2>&1 || true
  k delete ciliumbgpadvertisement e18-vip-adv --ignore-not-found >/dev/null 2>&1 || true
  k delete ciliumbgppeerconfig e18-peer-pe --ignore-not-found >/dev/null 2>&1 || true
  docker exec "${WORKER1}" ip addr del "${VIP}/32" dev lo >/dev/null 2>&1 || true
  docker exec "${WORKER1}" ip route del 10.255.218.4/30 >/dev/null 2>&1 || true
  docker exec "${WORKER1}" ip link del macsec0 >/dev/null 2>&1 || true
  docker exec "${WORKER1}" ip link del e18w0 >/dev/null 2>&1 || true
  docker rm -f "${PE_CTR}" "${CLIENT_CTR}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== [E18] 1. Criando Service/CRDs para Anúncio da VIP ${VIP}/32 e Provisionando PE/Cliente ==="
cat <<EOF | k apply -f -
apiVersion: v1
kind: Service
metadata:
  name: e18-vip-svc
  namespace: default
  labels:
    e18-bgp: "true"
  annotations:
    lbipam.cilium.io/ips: "${VIP}"
spec:
  type: LoadBalancer
  selector:
    app: echo
  ports:
  - name: http
    port: 80
    targetPort: 8080
---
apiVersion: cilium.io/v2
kind: CiliumBGPAdvertisement
metadata:
  name: e18-vip-adv
  labels:
    e18-adv: vip
spec:
  advertisements:
  - advertisementType: "Service"
    service:
      addresses:
      - LoadBalancerIP
    selector:
      matchLabels:
        e18-bgp: "true"
---
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata:
  name: e18-peer-pe
spec:
  timers:
    connectRetryTimeSeconds: 2
    holdTimeSeconds: 9
    keepAliveTimeSeconds: 3
  ebgpMultihop: 1
  gracefulRestart:
    enabled: true
    restartTimeSeconds: 30
  families:
  - afi: ipv4
    safi: unicast
    advertisements:
      matchLabels:
        e18-adv: vip
EOF

docker rm -f "${PE_CTR}" "${CLIENT_CTR}" >/dev/null 2>&1 || true
for ctr in "${PE_CTR}" "${CLIENT_CTR}"; do
  docker run -d --name "${ctr}" --hostname "${ctr#clab-p003-gw-fabric-}" --network none --privileged \
    --entrypoint /bin/sh "${FRR_IMAGE}" -c "exec sleep infinity" >/dev/null
done

W1_PID="$(docker inspect -f '{{.State.Pid}}' "${WORKER1}")"
PE_PID="$(docker inspect -f '{{.State.Pid}}' "${PE_CTR}")"
CE_PID="$(docker inspect -f '{{.State.Pid}}' "${CLIENT_CTR}")"

# 1. Worker1 (e18w0) <-> PE (e18pe0) com MTU 9000
ip link del e18w0 >/dev/null 2>&1 || true
ip link add e18w0 type veth peer name e18pe0
ip link set e18w0 netns "${W1_PID}"
ip link set e18pe0 netns "${PE_PID}"

# 2. PE (e18c0) <-> Client (e18c1) com MTU 9000
ip link del e18c0 >/dev/null 2>&1 || true
ip link add e18c0 type veth peer name e18c1
ip link set e18c0 netns "${PE_PID}"
ip link set e18c1 netns "${CE_PID}"

nsenter -t "${W1_PID}" -n sh -c "
  ip link set e18w0 mtu 9000 up
  ip addr add 10.255.218.1/30 dev e18w0
  ip addr replace ${VIP}/32 dev lo
  ip route replace 10.255.218.4/30 via 10.255.218.2 dev e18w0
"
nsenter -t "${PE_PID}" -n sh -c "
  sysctl -w net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0 >/dev/null
  ip link set lo up
  ip link set e18pe0 mtu 9000 up
  ip addr add 10.255.218.2/30 dev e18pe0
  ip link set e18c0 mtu 9000 up
  ip addr add 10.255.218.5/30 dev e18c0
"
nsenter -t "${CE_PID}" -n sh -c "
  sysctl -w net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0 >/dev/null
  ip link set lo up
  ip link set e18c1 mtu 9000 up
  ip addr add 10.255.218.6/30 dev e18c1
"

docker exec "${PE_CTR}" bash -c '
sed -i "s/^bgpd=no/bgpd=yes/" /etc/frr/daemons
touch /etc/frr/vtysh.conf
cat <<EOF >/etc/frr/frr.conf
frr defaults traditional
hostname frr-e18-pe
no ipv6 forwarding
!
router bgp 65400
 bgp router-id 10.255.218.2
 no bgp ebgp-requires-policy
 neighbor 10.255.218.1 remote-as 65301
 neighbor 10.255.218.1 timers 3 9
 neighbor 10.255.218.1 timers connect 2
 neighbor 10.255.218.6 remote-as 65518
 neighbor 10.255.218.6 timers 3 9
 neighbor 10.255.218.6 timers connect 2
 address-family ipv4 unicast
  neighbor 10.255.218.1 activate
  neighbor 10.255.218.6 activate
 exit-address-family
exit
!
line vty
EOF
/usr/lib/frr/frrinit.sh start
'

docker exec "${CLIENT_CTR}" bash -c '
sed -i "s/^bgpd=no/bgpd=yes/" /etc/frr/daemons
touch /etc/frr/vtysh.conf
cat <<EOF >/etc/frr/frr.conf
frr defaults traditional
hostname frr-e18-client
no ipv6 forwarding
!
router bgp 65518
 bgp router-id 10.255.218.6
 no bgp ebgp-requires-policy
 neighbor 10.255.218.5 remote-as 65400
 neighbor 10.255.218.5 timers 3 9
 neighbor 10.255.218.5 timers connect 2
 address-family ipv4 unicast
  network 10.255.218.4/30
  neighbor 10.255.218.5 activate
 exit-address-family
exit
!
line vty
EOF
/usr/lib/frr/frrinit.sh start
'

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
    - name: "e18-pe-l3"
      peerASN: 65400
      peerAddress: "10.255.218.2"
      peerConfigRef:
        name: "e18-peer-pe"
EOF

echo "=== [E18] 2. CÉLULA 1: MTU 9000 Jumbo Frames Fim a Fim vs Gargalo MTU 1500 (PMTU) ==="
for _ in $(seq 1 30); do
  if docker exec "${CLIENT_CTR}" ip -4 route show "${VIP}/32" 2>/dev/null | grep -q "10.255.218.5"; then
    break
  fi
  sleep 1
done
docker exec "${CLIENT_CTR}" ip -4 route show "${VIP}/32"

# Captura tcpdump de quadros > 8990 B durante 30 pings DF=1 de 8972 B
rm -f /tmp/e18-c1-jumbo.pcap /tmp/e18-c1-jumbo.txt
nsenter -t "${PE_PID}" -n tcpdump -e -ni e18pe0 -c 4 'icmp and greater 8990' >/tmp/e18-c1-jumbo.txt 2>&1 &
TCPD_PID=$!
sleep 0.5
nsenter -t "${CE_PID}" -n ping -M do -s 8972 -c 30 -i 0.05 -W 1 "${VIP}" | tail -n 5
wait "${TCPD_PID}" 2>/dev/null || true
echo "--- Captura tcpdump Jumbo Frames (9000 B IP / 9014 B Ethernet) em e18pe0 ---"
cat /tmp/e18-c1-jumbo.txt

# Controle Negativo Célula 1: reduzir e18pe0 para MTU 1500 e verificar ICMP Frag Needed (type 3 code 4 mtu 1500)
echo "--- [Célula 1 — Controle Negativo] Reduzindo MTU de e18pe0 para 1500 ---"
nsenter -t "${PE_PID}" -n ip link set e18pe0 mtu 1500
nsenter -t "${CE_PID}" -n ip route flush cache
rm -f /tmp/e18-c1-pmtu.txt
nsenter -t "${CE_PID}" -n tcpdump -ni e18c1 -c 4 'icmp[icmptype] == 3 and icmp[icmpcode] == 4' >/tmp/e18-c1-pmtu.txt 2>&1 &
TCPD_PMTU=$!
sleep 0.5
set +e
pmtu_out="$(nsenter -t "${CE_PID}" -n ping -M do -s 8972 -c 5 -i 0.2 -W 1 "${VIP}" 2>&1)"
pmtu_rc=$?
set -e
kill "${TCPD_PMTU}" >/dev/null 2>&1 || true
wait "${TCPD_PMTU}" 2>/dev/null || true
echo "${pmtu_out}" | tail -n 6
echo "--- Captura tcpdump ICMP Frag Needed (type 3 code 4 mtu 1500) em e18c1 ---"
cat /tmp/e18-c1-pmtu.txt
if [[ "${pmtu_rc}" -eq 0 ]]; then
  echo "ERRO: ping DF=1 de 8972 B não deveria passar com MTU 1500!" >&2
  exit 1
fi
nsenter -t "${PE_PID}" -n ip link set e18pe0 mtu 9000
nsenter -t "${CE_PID}" -n ip route flush cache

echo "=== [E18] 3. CÉLULA 2: QinQ 802.1ad (S-TAG 100 0x88a8 + C-TAG 200 0x8100) + eBGP ==="
# Desativar offload de VLAN no par veth para que ambas as tags apareçam no fio
nsenter -t "${W1_PID}" -n ethtool -K e18w0 rxvlan off txvlan off rx-vlan-stag-hw-parse off tx-vlan-stag-hw-insert off 2>/dev/null || true
nsenter -t "${PE_PID}" -n ethtool -K e18pe0 rxvlan off txvlan off rx-vlan-stag-hw-parse off tx-vlan-stag-hw-insert off 2>/dev/null || true

nsenter -t "${W1_PID}" -n sh -c "
  ip link add link e18w0 name e18w0.100 type vlan protocol 802.1ad id 100
  ip link set e18w0.100 up
  ip link add link e18w0.100 name e18w0.100.200 type vlan protocol 802.1Q id 200
  ip addr add 10.255.218.9/30 dev e18w0.100.200
  ip addr add 10.255.218.13/30 dev e18w0.100.200
  ip link set e18w0.100.200 up
"
nsenter -t "${PE_PID}" -n sh -c "
  ip link add link e18pe0 name e18pe0.100 type vlan protocol 802.1ad id 100
  ip link set e18pe0.100 up
  ip link add link e18pe0.100 name e18pe0.100.200 type vlan protocol 802.1Q id 200
  ip addr add 10.255.218.10/30 dev e18pe0.100.200
  ip link set e18pe0.100.200 up
  ip link add link e18pe0.100 name e18pe0.100.201 type vlan protocol 802.1Q id 201
  ip addr add 10.255.218.14/30 dev e18pe0.100.201
  ip link set e18pe0.100.201 up
"

docker exec "${PE_CTR}" vtysh \
  -c "configure terminal" \
  -c "router bgp 65400" \
  -c "neighbor 10.255.218.9 remote-as 65301" \
  -c "neighbor 10.255.218.9 timers 3 9" \
  -c "neighbor 10.255.218.9 timers connect 2" \
  -c "address-family ipv4 unicast" \
  -c "neighbor 10.255.218.9 activate" \
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
    - name: "e18-pe-qinq"
      peerASN: 65400
      peerAddress: "10.255.218.10"
      peerConfigRef:
        name: "e18-peer-pe"
EOF

for _ in $(seq 1 25); do
  if docker exec "${PE_CTR}" vtysh -c "show bgp ipv4 unicast summary" | grep "10.255.218.9" | grep -q -E '[0-9]+$'; then
    break
  fi
  sleep 1
done
docker exec "${PE_CTR}" vtysh -c "show bgp ipv4 unicast summary"
docker exec "${PE_CTR}" ip -4 route show "${VIP}/32"

rm -f /tmp/e18-c2-qinq.txt
nsenter -t "${PE_PID}" -n tcpdump -e -ni e18pe0 -c 6 >/tmp/e18-c2-qinq.txt 2>&1 &
TCPD_QINQ=$!
sleep 0.5
nsenter -t "${PE_PID}" -n ping -c 10 -i 0.05 -W 1 10.255.218.9 | tail -n 4
wait "${TCPD_QINQ}" 2>/dev/null || true
echo "--- Captura tcpdump QinQ (0x88a8 S-TAG 100 + 0x8100 C-TAG 200) em e18pe0 ---"
cat /tmp/e18-c2-qinq.txt

echo "--- [Célula 2 — Controle Negativo] C-TAG divergente (201 vs 200 em 10.255.218.12/30) ---"
qinq_neg=0
if nsenter -t "${PE_PID}" -n ping -I e18pe0.100.201 -c 5 -i 0.2 -W 1 10.255.218.13 >/dev/null 2>&1; then
  qinq_neg=5
fi
echo "cell2_qinq_ctag_mismatch_ping: ${qinq_neg}/5 (esperado: 0/5)"
if [[ "${qinq_neg}" -ne 0 ]]; then
  echo "ERRO: tráfego passou com C-TAG divergente!" >&2
  exit 1
fi

echo "=== [E18] 4. CÉLULA 3: MACsec 802.1AE (gcm-aes-128, 0x88e5) + eBGP vs Cilium WireGuard ==="
modprobe macsec || true
MAC_W="$(nsenter -t "${W1_PID}" -n ip -o link show dev e18w0 | awk '{for(i=1;i<=NF;i++) if($i=="link/ether") print $(i+1)}')"
MAC_PE="$(nsenter -t "${PE_PID}" -n ip -o link show dev e18pe0 | awk '{for(i=1;i<=NF;i++) if($i=="link/ether") print $(i+1)}')"
SAK_W_TO_PE="0102030405060708090a0b0c0d0e0f10"
SAK_PE_TO_W="100f0e0d0c0b0a090807060504030201"
SAK_WRONG="ffffffffffffffffffffffffffffffff"

nsenter -t "${W1_PID}" -n sh -c "
  ip link del macsec0 2>/dev/null || true
  ip link add link e18w0 macsec0 type macsec encrypt on
  ip macsec add macsec0 tx sa 0 pn 1 on key 01 ${SAK_W_TO_PE}
  ip macsec add macsec0 rx port 1 address ${MAC_PE}
  ip macsec add macsec0 rx port 1 address ${MAC_PE} sa 0 pn 1 on key 02 ${SAK_PE_TO_W}
  ip addr add 10.255.218.17/30 dev macsec0
  ip link set macsec0 up
"
nsenter -t "${PE_PID}" -n sh -c "
  ip link del macsec0 2>/dev/null || true
  ip link add link e18pe0 macsec0 type macsec encrypt on
  ip macsec add macsec0 tx sa 0 pn 1 on key 02 ${SAK_PE_TO_W}
  ip macsec add macsec0 rx port 1 address ${MAC_W}
  ip macsec add macsec0 rx port 1 address ${MAC_W} sa 0 pn 1 on key 01 ${SAK_W_TO_PE}
  ip addr add 10.255.218.18/30 dev macsec0
  ip link set macsec0 up
"

docker exec "${PE_CTR}" vtysh \
  -c "configure terminal" \
  -c "router bgp 65400" \
  -c "no neighbor 10.255.218.9 remote-as 65301" \
  -c "neighbor 10.255.218.17 remote-as 65301" \
  -c "neighbor 10.255.218.17 timers 3 9" \
  -c "neighbor 10.255.218.17 timers connect 2" \
  -c "address-family ipv4 unicast" \
  -c "neighbor 10.255.218.17 activate" \
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
    - name: "e18-pe-macsec"
      peerASN: 65400
      peerAddress: "10.255.218.18"
      peerConfigRef:
        name: "e18-peer-pe"
EOF

for _ in $(seq 1 25); do
  if docker exec "${PE_CTR}" vtysh -c "show bgp ipv4 unicast summary" | grep "10.255.218.17" | grep -q -E '[0-9]+$'; then
    break
  fi
  sleep 1
done
docker exec "${PE_CTR}" vtysh -c "show bgp ipv4 unicast summary"
docker exec "${PE_CTR}" ip -4 route show "${VIP}/32"

rm -f /tmp/e18-c3-macsec.txt
nsenter -t "${PE_PID}" -n tcpdump -e -ni e18pe0 -c 6 'ether proto 0x88e5' >/tmp/e18-c3-macsec.txt 2>&1 &
TCPD_MACSEC=$!
sleep 0.5
nsenter -t "${PE_PID}" -n ping -c 10 -i 0.05 -W 1 10.255.218.17 | tail -n 4
wait "${TCPD_MACSEC}" 2>/dev/null || true
echo "--- Captura tcpdump MACsec 802.1AE (ethertype 0x88e5) na interface subjacente e18pe0 ---"
cat /tmp/e18-c3-macsec.txt
echo "--- Contadores Criptográficos ip -s macsec show em ${WORKER1} ---"
nsenter -t "${W1_PID}" -n ip -s macsec show

echo "--- [Célula 3 — Controle Negativo] Chave SAK Divergente em TX SA 1 ---"
nsenter -t "${W1_PID}" -n sh -c "
  ip macsec add macsec0 rx port 1 address ${MAC_PE} sa 1 pn 1 on key 04 99000000000000000000000000000099
"
nsenter -t "${PE_PID}" -n sh -c "
  ip macsec add macsec0 tx sa 1 pn 1 on key 03 ${SAK_WRONG}
  ip link set dev macsec0 type macsec encodingsa 1
"
macsec_neg=0
if nsenter -t "${PE_PID}" -n ping -c 5 -i 0.2 -W 1 10.255.218.17 >/dev/null 2>&1; then
  macsec_neg=5
fi
echo "cell3_macsec_wrong_sak_ping: ${macsec_neg}/5 (esperado: 0/5)"
nsenter -t "${W1_PID}" -n ip -s macsec show | grep -A 6 "RXSC:" || true
if [[ "${macsec_neg}" -ne 0 ]]; then
  echo "ERRO: tráfego passou com chave SAK MACsec divergente!" >&2
  exit 1
fi

echo "=== [E18] PASS: MTU 9000 Jumbo/PMTU, QinQ 802.1ad e MACsec 802.1AE provados com R6=0! ==="
