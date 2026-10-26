#!/usr/bin/env bash
# ==============================================================================
# P005-S004 (Onda 4 — Braço A): Estudo E15 — Isolamento de VRF por Tenant no
# Border via BGP Community (65400:1010 -> vrf-e15-a, 65400:1020 -> vrf-e15-b,
# 65400:9999 -> não importado)
# ==============================================================================
set -euo pipefail

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
elif [[ $# -gt 0 ]]; then
  echo "Uso: $0 [--dry-run]" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/root/.kube/config}"
KCTX="kind-p003-gw"
EXPECTED_UID="6bb32e0f-71f9-4558-ae33-356ba2250c26"
CANARY_CTX="kind-k01"
CANARY_UID="635e7274-5597-40c7-9de5-b1fbe3d68b22"

WORKER1="p003-gw-worker"
PE_CTR="clab-p003-gw-fabric-frr-e15-pe"
CLIENT_A_CTR="clab-p003-gw-fabric-frr-e15-client-a"
CLIENT_B_CTR="clab-p003-gw-fabric-frr-e15-client-b"
FRR_IMAGE="quay.io/frrouting/frr:10.7.1"

W1_IP="10.255.215.1"
PE_IP="10.255.215.2"
PE_CA_IP="198.19.151.1"
CA_IP="198.19.151.10"
PE_CB_IP="198.19.152.1"
CB_IP="198.19.152.10"

VIP_A="10.202.255.195"
VIP_B="10.202.255.196"
VIP_UNAUTH="10.202.255.199"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  cat <<'EOF'
[DRY-RUN] E15 — Isolamento de VRF por Tenant no Border via BGP Community
  1. Pré-voo: validar UIDs de kind-p003-gw (6bb32e0f-...) e kind-k01 (635e7274-...).
  2. Aplicar manifests/07-e15-vrf-per-tenant.yaml (Namespaces p005-e15-a/b, Services
     10.202.255.195 c/ 65400:1010, 10.202.255.196 c/ 65400:1020 e 10.202.255.199 c/ 65400:9999).
  3. Provisionar PE frr-e15-pe (AS 65400) com VRFs Linux vrf-e15-a (table 1510) e
     vrf-e15-b (table 1520) + clientes frr-e15-client-a (AS 65515, 198.19.151.10) e
     frr-e15-client-b (AS 65516, 198.19.152.10).
  4. Célula 1 (RIB/FIB Global vs VRFs): comprovar que vrf-e15-a importa apenas
     10.202.255.195/32 e vrf-e15-b importa apenas 10.202.255.196/32 via dynamic VRF
     route-leaking filtrado por BGP community.
  5. Célula 2 (Controle Positivo Intra-Tenant):
     - frr-e15-client-a -> http://10.202.255.195:8080/hostname (30/30 HTTP 200 e15-echo-a)
     - frr-e15-client-b -> http://10.202.255.196:8080/hostname (30/30 HTTP 200 e15-echo-b)
  6. Célula 3 (Controles Negativos Cross-Tenant e Community Não Autorizada 65400:9999):
     - Negativo 3A: Client A -> VIP B (0/5) e Client B -> VIP A (0/5), inclusive sob
       rota default injetada contra a tabela da VRF.
     - Negativo 3B: Client A -> Client B (198.19.152.10) bloqueado entre VRFs (0/5).
     - Negativo 3C: VIP 10.202.255.199/32 (65400:9999) bloqueada em ambas as VRFs (0/5).
  7. Rollback completo e verificação R6=0.
EOF
  exit 0
fi

k() {
  kubectl --kubeconfig="${KUBECONFIG_PATH}" --context="${KCTX}" "$@"
}

echo "=== [E15] 0. Pré-voo: Verificando UID do sandbox (${KCTX}) e canário (${CANARY_CTX}) ==="
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
  echo "[CLEANUP] Restaurando CiliumBGPClusterConfig/rack1 e removendo recursos de E15..."
  restore_bgp_rack1 || true
  k delete -f "${SCRIPT_DIR}/manifests/07-e15-vrf-per-tenant.yaml" --ignore-not-found >/dev/null 2>&1 || true
  docker exec "${WORKER1}" sh -c '
    iptables -t nat -D PREROUTING -j E15_PRE 2>/dev/null || true
    iptables -t nat -F E15_PRE 2>/dev/null || true
    iptables -t nat -X E15_PRE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -j E15_POST 2>/dev/null || true
    iptables -t nat -F E15_POST 2>/dev/null || true
    iptables -t nat -X E15_POST 2>/dev/null || true
  ' >/dev/null 2>&1 || true
  docker exec "${WORKER1}" ip route del 198.19.151.0/24 >/dev/null 2>&1 || true
  docker exec "${WORKER1}" ip route del 198.19.152.0/24 >/dev/null 2>&1 || true
  docker exec "${WORKER1}" ip link del e15w0 >/dev/null 2>&1 || true
  docker rm -f "${PE_CTR}" "${CLIENT_A_CTR}" "${CLIENT_B_CTR}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== [E15] 1. Aplicando Manifesto 07-e15-vrf-per-tenant.yaml ==="
k apply -f "${SCRIPT_DIR}/manifests/07-e15-vrf-per-tenant.yaml"
k -n p005-e15-a wait --for=condition=Ready pod/e15-echo-a --timeout=60s
k -n p005-e15-b wait --for=condition=Ready pod/e15-echo-b --timeout=60s
PODA_IP="$(k -n p005-e15-a get pod e15-echo-a -o jsonpath='{.status.podIP}')"
PODB_IP="$(k -n p005-e15-b get pod e15-echo-b -o jsonpath='{.status.podIP}')"
echo "Pod Tenant A: ${PODA_IP} | Pod Tenant B: ${PODB_IP}"

echo "=== [E15] 2. Provisionando PE (${PE_CTR}) com VRFs table 1510/1520 e Clientes A/B ==="
docker rm -f "${PE_CTR}" "${CLIENT_A_CTR}" "${CLIENT_B_CTR}" >/dev/null 2>&1 || true
for ctr in "${PE_CTR}" "${CLIENT_A_CTR}" "${CLIENT_B_CTR}"; do
  docker run -d --name "${ctr}" --hostname "${ctr#clab-p003-gw-fabric-}" --network none --privileged \
    --entrypoint /bin/sh "${FRR_IMAGE}" -c "exec sleep infinity" >/dev/null
done

W1_PID="$(docker inspect -f '{{.State.Pid}}' "${WORKER1}")"
PE_PID="$(docker inspect -f '{{.State.Pid}}' "${PE_CTR}")"
CA_PID="$(docker inspect -f '{{.State.Pid}}' "${CLIENT_A_CTR}")"
CB_PID="$(docker inspect -f '{{.State.Pid}}' "${CLIENT_B_CTR}")"

# 1. Worker1 <-> PE
ip link del e15w0 >/dev/null 2>&1 || true
ip link add e15w0 type veth peer name e15pe0
ip link set e15w0 netns "${W1_PID}"
ip link set e15pe0 netns "${PE_PID}"
nsenter -t "${W1_PID}" -n ip addr add "${W1_IP}/30" dev e15w0
nsenter -t "${W1_PID}" -n ip link set e15w0 up
nsenter -t "${PE_PID}" -n ip addr add "${PE_IP}/30" dev e15pe0
nsenter -t "${PE_PID}" -n ip link set e15pe0 up
nsenter -t "${PE_PID}" -n ip link set lo up

# 2. PE (vrf-e15-a table 1510) <-> Client A
ip link del e15ca0 >/dev/null 2>&1 || true
ip link add e15ca0 type veth peer name e15ca1
ip link set e15ca0 netns "${PE_PID}"
ip link set e15ca1 netns "${CA_PID}"

# 3. PE (vrf-e15-b table 1520) <-> Client B
ip link del e15cb0 >/dev/null 2>&1 || true
ip link add e15cb0 type veth peer name e15cb1
ip link set e15cb0 netns "${PE_PID}"
ip link set e15cb1 netns "${CB_PID}"

nsenter -t "${PE_PID}" -n sh -c "
  sysctl -w net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0 net.vrf.strict_mode=1 >/dev/null
  ip link add vrf-e15-a type vrf table 1510
  ip link set vrf-e15-a up
  ip link add vrf-e15-b type vrf table 1520
  ip link set vrf-e15-b up
  ip link set e15ca0 master vrf-e15-a
  ip addr add ${PE_CA_IP}/24 dev e15ca0
  ip link set e15ca0 up
  ip link set e15cb0 master vrf-e15-b
  ip addr add ${PE_CB_IP}/24 dev e15cb0
  ip link set e15cb0 up
  ip route replace table 1510 unreachable default metric 4278198272
  ip route replace table 1520 unreachable default metric 4278198272
  ip route replace 198.19.151.0/24 via ${CA_IP} dev e15ca0
  ip route replace 198.19.152.0/24 via ${CB_IP} dev e15cb0
"

nsenter -t "${CA_PID}" -n sh -c "
  ip link set lo up
  ip addr add ${CA_IP}/24 dev e15ca1
  ip link set e15ca1 up
"
nsenter -t "${CB_PID}" -n sh -c "
  ip link set lo up
  ip addr add ${CB_IP}/24 dev e15cb1
  ip link set e15cb1 up
"

# Rotas de retorno e DNAT/SNAT isolado em p003-gw-worker
nsenter -t "${W1_PID}" -n ip route replace 198.19.151.0/24 via "${PE_IP}" dev e15w0
nsenter -t "${W1_PID}" -n ip route replace 198.19.152.0/24 via "${PE_IP}" dev e15w0
nsenter -t "${W1_PID}" -n sh -c "
  iptables -t nat -N E15_PRE 2>/dev/null || iptables -t nat -F E15_PRE
  iptables -t nat -C PREROUTING -j E15_PRE 2>/dev/null || iptables -t nat -I PREROUTING 1 -j E15_PRE
  iptables -t nat -A E15_PRE -i e15w0 -d ${VIP_A} -p tcp --dport 8080 -j DNAT --to-destination ${PODA_IP}:8080
  iptables -t nat -A E15_PRE -i e15w0 -d ${VIP_B} -p tcp --dport 8080 -j DNAT --to-destination ${PODB_IP}:8080
  iptables -t nat -A E15_PRE -i e15w0 -d ${VIP_UNAUTH} -p tcp --dport 8080 -j DNAT --to-destination ${PODA_IP}:8080
  iptables -t nat -N E15_POST 2>/dev/null || iptables -t nat -F E15_POST
  iptables -t nat -C POSTROUTING -j E15_POST 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j E15_POST
  iptables -t nat -A E15_POST -d ${PODA_IP} -p tcp --dport 8080 -j MASQUERADE
  iptables -t nat -A E15_POST -d ${PODB_IP} -p tcp --dport 8080 -j MASQUERADE
"

# Configurar FRR no PE e nos Clientes A e B
docker exec "${PE_CTR}" bash -c '
sed -i "s/^bgpd=no/bgpd=yes/" /etc/frr/daemons
touch /etc/frr/vtysh.conf
cat <<EOF >/etc/frr/frr.conf
frr defaults traditional
hostname frr-e15-pe
no ipv6 forwarding
!
bgp community-list standard E15-COMM-A permit 65400:1010
bgp community-list standard E15-COMM-B permit 65400:1020
!
route-map RM-E15-IMPORT-A permit 10
 match community E15-COMM-A
exit
route-map RM-E15-IMPORT-A deny 20
exit
!
route-map RM-E15-IMPORT-B permit 10
 match community E15-COMM-B
exit
route-map RM-E15-IMPORT-B deny 20
exit
!
router bgp 65400
 bgp router-id 10.255.215.2
 no bgp ebgp-requires-policy
 neighbor 10.255.215.1 remote-as 65301
 neighbor 10.255.215.1 timers 3 9
 neighbor 10.255.215.1 timers connect 2
 address-family ipv4 unicast
  neighbor 10.255.215.1 activate
 exit-address-family
exit
!
router bgp 65400 vrf vrf-e15-a
 bgp router-id 198.19.151.1
 no bgp ebgp-requires-policy
 neighbor 198.19.151.10 remote-as 65515
 neighbor 198.19.151.10 timers 3 9
 neighbor 198.19.151.10 timers connect 2
 address-family ipv4 unicast
  neighbor 198.19.151.10 activate
  import vrf route-map RM-E15-IMPORT-A
  import vrf default
 exit-address-family
exit
!
router bgp 65400 vrf vrf-e15-b
 bgp router-id 198.19.152.1
 no bgp ebgp-requires-policy
 neighbor 198.19.152.10 remote-as 65516
 neighbor 198.19.152.10 timers 3 9
 neighbor 198.19.152.10 timers connect 2
 address-family ipv4 unicast
  neighbor 198.19.152.10 activate
  import vrf route-map RM-E15-IMPORT-B
  import vrf default
 exit-address-family
exit
!
line vty
EOF
/usr/lib/frr/frrinit.sh start
'

docker exec "${CLIENT_A_CTR}" bash -c '
sed -i "s/^bgpd=no/bgpd=yes/" /etc/frr/daemons
touch /etc/frr/vtysh.conf
cat <<EOF >/etc/frr/frr.conf
frr defaults traditional
hostname frr-e15-client-a
no ipv6 forwarding
!
router bgp 65515
 bgp router-id 198.19.151.10
 no bgp ebgp-requires-policy
 neighbor 198.19.151.1 remote-as 65400
 neighbor 198.19.151.1 timers 3 9
 neighbor 198.19.151.1 timers connect 2
 address-family ipv4 unicast
  network 198.19.151.0/24
  neighbor 198.19.151.1 activate
 exit-address-family
exit
!
line vty
EOF
/usr/lib/frr/frrinit.sh start
'

docker exec "${CLIENT_B_CTR}" bash -c '
sed -i "s/^bgpd=no/bgpd=yes/" /etc/frr/daemons
touch /etc/frr/vtysh.conf
cat <<EOF >/etc/frr/frr.conf
frr defaults traditional
hostname frr-e15-client-b
no ipv6 forwarding
!
router bgp 65516
 bgp router-id 198.19.152.10
 no bgp ebgp-requires-policy
 neighbor 198.19.152.1 remote-as 65400
 neighbor 198.19.152.1 timers 3 9
 neighbor 198.19.152.1 timers connect 2
 address-family ipv4 unicast
  network 198.19.152.0/24
  neighbor 198.19.152.1 activate
 exit-address-family
exit
!
line vty
EOF
/usr/lib/frr/frrinit.sh start
'

# Adicionar peer frr-e15-pe em CiliumBGPClusterConfig/rack1
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
    - name: "e15-pe"
      peerASN: 65400
      peerAddress: "${PE_IP}"
      peerConfigRef:
        name: "e15-peer-pe"
EOF

echo "=== [E15] 3. Aguardando convergência BGP e importação seletiva nas VRFs ==="
for _ in $(seq 1 30); do
  a_ok="$(docker exec "${CLIENT_A_CTR}" ip -4 route show "${VIP_A}/32" 2>/dev/null || true)"
  b_ok="$(docker exec "${CLIENT_B_CTR}" ip -4 route show "${VIP_B}/32" 2>/dev/null || true)"
  if [[ -n "${a_ok}" && -n "${b_ok}" ]]; then
    break
  fi
  sleep 1
done

echo "--- [CÉLULA 1] RIB Global (default) vs RIB/FIB de vrf-e15-a (1510) e vrf-e15-b (1520) em ${PE_CTR} ---"
docker exec "${PE_CTR}" vtysh -c "show bgp ipv4 unicast"
docker exec "${PE_CTR}" vtysh -c "show bgp ipv4 unicast ${VIP_A}/32"
docker exec "${PE_CTR}" vtysh -c "show bgp ipv4 unicast ${VIP_B}/32"
docker exec "${PE_CTR}" vtysh -c "show bgp ipv4 unicast ${VIP_UNAUTH}/32"
echo "--- RIB/FIB VRF Tenant A (vrf-e15-a, table 1510) ---"
docker exec "${PE_CTR}" vtysh -c "show bgp vrf vrf-e15-a ipv4 unicast"
docker exec "${PE_CTR}" ip -4 route show vrf vrf-e15-a
echo "--- RIB/FIB VRF Tenant B (vrf-e15-b, table 1520) ---"
docker exec "${PE_CTR}" vtysh -c "show bgp vrf vrf-e15-b ipv4 unicast"
docker exec "${PE_CTR}" ip -4 route show vrf vrf-e15-b
echo "--- Rotas nos Clientes Externos A e B ---"
docker exec "${CLIENT_A_CTR}" ip -4 route show
docker exec "${CLIENT_B_CTR}" ip -4 route show

echo "=== [E15] 4. CÉLULA 2: Controle Positivo Intra-Tenant (30/30 HTTP 200 por VRF) ==="
ok_a=0
ok_b=0
for _ in $(seq 1 30); do
  resp_a="$(nsenter -t "${CA_PID}" -n curl -sS --max-time 2 "http://${VIP_A}:8080/hostname" || true)"
  [[ "${resp_a}" == "e15-echo-a" ]] && ok_a=$((ok_a + 1))
  resp_b="$(nsenter -t "${CB_PID}" -n curl -sS --max-time 2 "http://${VIP_B}:8080/hostname" || true)"
  [[ "${resp_b}" == "e15-echo-b" ]] && ok_b=$((ok_b + 1))
done
echo "cell2_intra_tenant_a_http: ${ok_a}/30 (esperado: 30/30 e15-echo-a)"
echo "cell2_intra_tenant_b_http: ${ok_b}/30 (esperado: 30/30 e15-echo-b)"
if [[ "${ok_a}" -ne 30 || "${ok_b}" -ne 30 ]]; then
  echo "ERRO: falha no tráfego intra-tenant!" >&2
  exit 1
fi

echo "=== [E15] 5. CÉLULA 3: Controles Negativos Cross-Tenant e Community Não Autorizada (65400:9999) ==="
cross_ab=0
cross_ba=0
for _ in $(seq 1 5); do
  if nsenter -t "${CA_PID}" -n curl -sS --max-time 1 "http://${VIP_B}:8080/hostname" >/dev/null 2>&1; then
    cross_ab=$((cross_ab + 1))
  fi
  if nsenter -t "${CB_PID}" -n curl -sS --max-time 1 "http://${VIP_A}:8080/hostname" >/dev/null 2>&1; then
    cross_ba=$((cross_ba + 1))
  fi
done
echo "cell3a_cross_vrf_a_to_vip_b: ${cross_ab}/5 (esperado: 0/5)"
echo "cell3a_cross_vrf_b_to_vip_a: ${cross_ba}/5 (esperado: 0/5)"

# Mesmo com rota default apontando para o PE, a VRF table 1510 bloqueia pacotes para VIP B
nsenter -t "${CA_PID}" -n ip route replace default via "${PE_CA_IP}" dev e15ca1
forced_ab=0
for _ in $(seq 1 5); do
  if nsenter -t "${CA_PID}" -n curl -sS --max-time 1 "http://${VIP_B}:8080/hostname" >/dev/null 2>&1; then
    forced_ab=$((forced_ab + 1))
  fi
done
echo "cell3a_forced_default_route_a_to_vip_b: ${forced_ab}/5 (esperado: 0/5)"

# Negativo 3B: Client A -> Client B (198.19.152.10)
ping_ab=0
if nsenter -t "${CA_PID}" -n ping -c 5 -W 1 "${CB_IP}" >/dev/null 2>&1; then
  ping_ab=5
fi
echo "cell3b_client_a_to_client_b_ping: ${ping_ab}/5 (esperado: 0/5)"

# Negativo 3C: VIP Não Autorizada (10.202.255.199 com 65400:9999)
unauth_a=0
unauth_b=0
for _ in $(seq 1 5); do
  if nsenter -t "${CA_PID}" -n curl -sS --max-time 1 "http://${VIP_UNAUTH}:8080/hostname" >/dev/null 2>&1; then
    unauth_a=$((unauth_a + 1))
  fi
  if nsenter -t "${CB_PID}" -n curl -sS --max-time 1 "http://${VIP_UNAUTH}:8080/hostname" >/dev/null 2>&1; then
    unauth_b=$((unauth_b + 1))
  fi
done
nsenter -t "${CA_PID}" -n ip route del default >/dev/null 2>&1 || true
echo "cell3c_unauth_vip_from_a: ${unauth_a}/5 | from_b: ${unauth_b}/5 (esperado: 0/5 em ambos)"

if [[ "${cross_ab}" -ne 0 || "${cross_ba}" -ne 0 || "${forced_ab}" -ne 0 || "${ping_ab}" -ne 0 || "${unauth_a}" -ne 0 || "${unauth_b}" -ne 0 ]]; then
  echo "ERRO: violação de isolamento nos controles negativos de E15!" >&2
  exit 1
fi

echo "=== [E15] 6. Verificando Invariante R6=0 nos Nós Kind ==="
for n in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
  cnt="$(docker exec "${n}" ip -4 route show proto bgp | wc -l | tr -d ' ')"
  echo "node=${n} proto_bgp_routes=${cnt}"
  if [[ "${cnt}" -ne 0 ]]; then
    echo "ERRO: R6 violado em ${n}" >&2
    exit 1
  fi
done

echo "=== [E15] PASS: Isolamento de VRF por Tenant no Border via BGP Community concluído com sucesso! ==="
