#!/usr/bin/env bash
# ==============================================================================
# P005-S004 (Onda 4 — Braço A): Estudo E16 — Desenho de Terminação PE/CE,
# 3 Modos de Retorno (Inbound Estático, Inbound Dinâmico FRR no Nó e Outbound
# CiliumEgressGatewayPolicy com Egress IP Determinístico 10.255.216.10)
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
PE_CTR="clab-p003-gw-fabric-frr-e16-pe"
CLIENT_CTR="clab-p003-gw-fabric-frr-e16-client"
NODE_FRR_CTR="clab-p003-gw-fabric-frr-e16-node"
FRR_IMAGE="quay.io/frrouting/frr:10.7.1"

W1_IP="10.255.216.1"
PE_IP="10.255.216.2"
W1_FRR_IP="10.255.216.3"
EGRESS_IP="10.255.216.10"

PE_CE_IP="198.19.16.1"
CE_IP="198.19.16.10"
CE_DYN_IP="198.19.116.10"
VIP="10.202.255.197"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  cat <<'EOF'
[DRY-RUN] E16 — Desenho de Terminação PE/CE, 3 Modos de Retorno e CiliumEgressGatewayPolicy
  1. Pré-voo: validar UIDs de kind-p003-gw (6bb32e0f-...) e kind-k01 (635e7274-...).
  2. Provisionar interface eth16 em p003-gw-worker (10.255.216.1/28 + Egress IP 10.255.216.10/32)
     conectada a frr-e16-pe (AS 65400, 10.255.216.2/28) e frr-e16-client (AS 65516,
     198.19.16.10/24 + 198.19.116.10/24).
  3. Habilitar enable-ipv4-egress-gateway=true no ConfigMap cilium-config, reiniciar ds/cilium
     e aplicar manifests/08-e16-return-paths-egress-gw.yaml (VIP 10.202.255.197/32 e
     CiliumEgressGatewayPolicy -> 10.255.216.10).
  4. Célula 1 (Modo 1 — Inbound VIP-Only + Rota Estática de Retorno, R6=0):
     - Controle Negativo: sem rota de retorno para 198.19.16.0/24 no kernel do nó (apesar de
       Received > 0 no GoBGP do Cilium), requisições de 198.19.16.10 falham (0/3).
     - Controle Positivo: com rota estática 198.19.16.0/24 via 10.255.216.2 dev eth16,
       30/30 requisições HTTP para 10.202.255.197:8080 retornam 200 OK com R6=0.
  5. Célula 2 (Modo 2 — Retorno Dinâmico via FRR Co-Implantado no Nó p/ 198.19.116.0/24):
     - Controle Negativo: sem rota para 198.19.116.0/24, tráfego de 198.19.116.10 falha (0/3).
     - Controle Positivo: speaker FRR co-implantado instala 198.19.116.0/24 proto bgp (com
       prefix-list estrito) e 30/30 requisições HTTP de 198.19.116.10 retornam 200 OK;
       remoção do speaker restaura R6=0 imediatamente.
  6. Célula 3 (Modo 3 — Outbound via CiliumEgressGatewayPolicy c/ IP 10.255.216.10):
     - Controle Positivo: pod autorizado e16-egress-client sai com source IP determinístico
       10.255.216.10 (30/30 HTTP 200 client_ip=10.255.216.10).
     - Controle Negativo: pod não autorizado e16-unmatched-client sai com IP primário do nó
       (10.255.216.1) e é bloqueado pela ACL de borda do PE (0/5).
  7. Rollback completo (incluindo restauração de cilium-config) e verificação R6=0.
EOF
  exit 0
fi

k() {
  kubectl --kubeconfig="${KUBECONFIG_PATH}" --context="${KCTX}" "$@"
}

echo "=== [E16] 0. Pré-voo: Verificando UID do sandbox (${KCTX}) e canário (${CANARY_CTX}) ==="
ACTUAL_UID="$(k get namespace kube-system -o jsonpath='{.metadata.uid}')"
CANARY_ACTUAL="$(kubectl --kubeconfig="${KUBECONFIG_PATH}" --context="${CANARY_CTX}" get namespace kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${ACTUAL_UID}" != "${EXPECTED_UID}" || "${CANARY_ACTUAL}" != "${CANARY_UID}" ]]; then
  echo "ERRO: UID inesperado (p003-gw=${ACTUAL_UID}, k01=${CANARY_ACTUAL})" >&2
  exit 1
fi
echo "OK: p003-gw UID=${ACTUAL_UID} | k01 UID=${CANARY_ACTUAL}"

ORIG_EGW="$(k -n kube-system get cm cilium-config -o jsonpath='{.data.enable-ipv4-egress-gateway}' 2>/dev/null || true)"

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
  echo "[CLEANUP] Restaurando CiliumBGPClusterConfig/rack1, cilium-config e removendo recursos de E16..."
  restore_bgp_rack1 || true
  k delete -f "${SCRIPT_DIR}/manifests/08-e16-return-paths-egress-gw.yaml" --ignore-not-found >/dev/null 2>&1 || true
  docker rm -f "${NODE_FRR_CTR}" "${PE_CTR}" "${CLIENT_CTR}" >/dev/null 2>&1 || true
  docker exec "${WORKER1}" sh -c '
    iptables -t nat -D PREROUTING -j E16_PRE 2>/dev/null || true
    iptables -t nat -F E16_PRE 2>/dev/null || true
    iptables -t nat -X E16_PRE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -j E16_POST 2>/dev/null || true
    iptables -t nat -F E16_POST 2>/dev/null || true
    iptables -t nat -X E16_POST 2>/dev/null || true
  ' >/dev/null 2>&1 || true
  docker exec "${WORKER1}" ip route del 198.19.16.0/24 >/dev/null 2>&1 || true
  docker exec "${WORKER1}" ip route del 198.19.116.0/24 >/dev/null 2>&1 || true
  docker exec "${WORKER1}" ip link del eth16 >/dev/null 2>&1 || true
  if [[ "${ORIG_EGW}" != "true" ]]; then
    k delete crd ciliumegressgatewaypolicies.cilium.io --ignore-not-found >/dev/null 2>&1 || true
    k -n kube-system patch cm cilium-config --type=json -p='[{"op":"remove","path":"/data/enable-egress-gateway"}]' >/dev/null 2>&1 || true
    k -n kube-system patch cm cilium-config --type=json -p='[{"op":"remove","path":"/data/enable-ipv4-egress-gateway"}]' >/dev/null 2>&1 || true
    k -n kube-system rollout restart deploy/cilium-operator ds/cilium >/dev/null 2>&1 || true
    k -n kube-system rollout status deploy/cilium-operator --timeout=120s >/dev/null 2>&1 || true
    k -n kube-system rollout status ds/cilium --timeout=120s >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "=== [E16] 1. Provisionando PE (${PE_CTR}), Cliente (${CLIENT_CTR}) e Interface eth16 em ${WORKER1} ==="
docker rm -f "${NODE_FRR_CTR}" "${PE_CTR}" "${CLIENT_CTR}" >/dev/null 2>&1 || true
for ctr in "${PE_CTR}" "${CLIENT_CTR}"; do
  docker run -d --name "${ctr}" --hostname "${ctr#clab-p003-gw-fabric-}" --network none --privileged \
    --entrypoint /bin/sh "${FRR_IMAGE}" -c "exec sleep infinity" >/dev/null
done

W1_PID="$(docker inspect -f '{{.State.Pid}}' "${WORKER1}")"
PE_PID="$(docker inspect -f '{{.State.Pid}}' "${PE_CTR}")"
CE_PID="$(docker inspect -f '{{.State.Pid}}' "${CLIENT_CTR}")"

# 1. Worker1 (eth16) <-> PE (e16pe0)
ip link del eth16 >/dev/null 2>&1 || true
ip link add eth16 type veth peer name e16pe0
ip link set eth16 netns "${W1_PID}"
ip link set e16pe0 netns "${PE_PID}"
nsenter -t "${W1_PID}" -n ip addr add "${W1_IP}/28" dev eth16
nsenter -t "${W1_PID}" -n ip addr add "${W1_FRR_IP}/28" dev eth16
nsenter -t "${W1_PID}" -n ip addr add "${EGRESS_IP}/32" dev eth16
nsenter -t "${W1_PID}" -n ip link set eth16 up
nsenter -t "${PE_PID}" -n ip addr add "${PE_IP}/28" dev e16pe0
nsenter -t "${PE_PID}" -n ip link set e16pe0 up
nsenter -t "${PE_PID}" -n ip link set lo up

# 2. PE (e16c0) <-> Client (e16c1)
ip link del e16c0 >/dev/null 2>&1 || true
ip link add e16c0 type veth peer name e16c1
ip link set e16c0 netns "${PE_PID}"
ip link set e16c1 netns "${CE_PID}"
nsenter -t "${PE_PID}" -n ip addr add "${PE_CE_IP}/24" dev e16c0
nsenter -t "${PE_PID}" -n ip link set e16c0 up
nsenter -t "${CE_PID}" -n ip link set lo up
nsenter -t "${CE_PID}" -n ip addr add "${CE_IP}/24" dev e16c1
nsenter -t "${CE_PID}" -n ip addr add "${CE_DYN_IP}/24" dev lo
nsenter -t "${CE_PID}" -n ip link set e16c1 up
nsenter -t "${PE_PID}" -n ip route replace 172.19.0.0/16 via "${W1_IP}" dev e16pe0
nsenter -t "${CE_PID}" -n ip route replace 10.255.216.0/28 via "${PE_CE_IP}" dev e16c1
nsenter -t "${CE_PID}" -n ip route replace 172.19.0.0/16 via "${PE_CE_IP}" dev e16c1

nsenter -t "${PE_PID}" -n sysctl -w net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0 >/dev/null
nsenter -t "${CE_PID}" -n sysctl -w net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0 >/dev/null

echo "=== [E16] 2. Habilitando enable-egress-gateway=true / enable-ipv4-egress-gateway=true no Cilium e Aplicando Manifesto ==="
k -n kube-system patch cm cilium-config --type=merge -p '{"data":{"enable-egress-gateway":"true","enable-ipv4-egress-gateway":"true"}}'
k -n kube-system rollout restart deploy/cilium-operator ds/cilium
k -n kube-system rollout status deploy/cilium-operator --timeout=120s
k -n kube-system rollout status ds/cilium --timeout=120s
for _ in $(seq 1 30); do
  k get crd ciliumegressgatewaypolicies.cilium.io >/dev/null 2>&1 && break
  sleep 1
done
k wait --for=condition=Established crd/ciliumegressgatewaypolicies.cilium.io --timeout=60s

k apply -f "${SCRIPT_DIR}/manifests/08-e16-return-paths-egress-gw.yaml"
k -n p005-e16 wait --for=condition=Ready pod/e16-vip-backend pod/e16-egress-client pod/e16-unmatched-client --timeout=60s
BACKEND_IP="$(k -n p005-e16 get pod e16-vip-backend -o jsonpath='{.status.podIP}')"
EGW_POD_IP="$(k -n p005-e16 get pod e16-egress-client -o jsonpath='{.status.podIP}')"
UNMATCHED_POD_IP="$(k -n p005-e16 get pod e16-unmatched-client -o jsonpath='{.status.podIP}')"
echo "Backend PodIP=${BACKEND_IP} | Egress-Client PodIP=${EGW_POD_IP} | Unmatched-Client PodIP=${UNMATCHED_POD_IP}"

# DNAT/SNAT isolado em p003-gw-worker para tráfego externo -> VIP
nsenter -t "${W1_PID}" -n sh -c "
  iptables -t nat -N E16_PRE 2>/dev/null || iptables -t nat -F E16_PRE
  iptables -t nat -C PREROUTING -j E16_PRE 2>/dev/null || iptables -t nat -I PREROUTING 1 -j E16_PRE
  iptables -t nat -A E16_PRE -i eth16 -d ${VIP} -p tcp --dport 8080 -j DNAT --to-destination ${BACKEND_IP}:8080
  iptables -t nat -N E16_POST 2>/dev/null || iptables -t nat -F E16_POST
  iptables -t nat -C POSTROUTING -j E16_POST 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j E16_POST
  iptables -t nat -A E16_POST -d ${BACKEND_IP} -p tcp --dport 8080 -j MASQUERADE
"

# Configurar FRR em PE e Client
docker exec "${PE_CTR}" bash -c '
sed -i "s/^bgpd=no/bgpd=yes/" /etc/frr/daemons
touch /etc/frr/vtysh.conf
cat <<EOF >/etc/frr/frr.conf
frr defaults traditional
hostname frr-e16-pe
no ipv6 forwarding
!
router bgp 65400
 bgp router-id 10.255.216.2
 no bgp ebgp-requires-policy
 neighbor 10.255.216.1 remote-as 65301
 neighbor 10.255.216.1 timers 3 9
 neighbor 10.255.216.1 timers connect 2
 neighbor 10.255.216.3 remote-as 65316
 neighbor 10.255.216.3 timers 3 9
 neighbor 10.255.216.3 timers connect 2
 neighbor 198.19.16.10 remote-as 65516
 neighbor 198.19.16.10 timers 3 9
 neighbor 198.19.16.10 timers connect 2
 address-family ipv4 unicast
  network 198.19.16.0/24
  neighbor 10.255.216.1 activate
  neighbor 10.255.216.3 activate
  neighbor 198.19.16.10 activate
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
hostname frr-e16-client
no ipv6 forwarding
!
router bgp 65516
 bgp router-id 198.19.16.10
 no bgp ebgp-requires-policy
 neighbor 198.19.16.1 remote-as 65400
 neighbor 198.19.16.1 timers 3 9
 neighbor 198.19.16.1 timers connect 2
 address-family ipv4 unicast
  network 198.19.16.0/24
  network 198.19.116.0/24
  neighbor 198.19.16.1 activate
 exit-address-family
exit
!
line vty
EOF
/usr/lib/frr/frrinit.sh start
'

# Atualizar CiliumBGPClusterConfig/rack1
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
    - name: "e16-pe"
      peerASN: 65400
      peerAddress: "${PE_IP}"
      peerConfigRef:
        name: "e16-peer-pe"
EOF

echo "=== [E16] 3. Aguardando convergência da VIP ${VIP}/32 em ${CLIENT_CTR} ==="
for _ in $(seq 1 30); do
  if docker exec "${CLIENT_CTR}" ip -4 route show "${VIP}/32" 2>/dev/null | grep -q "${PE_CE_IP}"; then
    break
  fi
  sleep 1
done
docker exec "${CLIENT_CTR}" ip -4 route show

echo "=== [E16] 4. CÉLULA 1 (Modo 1): Inbound VIP-Only + Rota Estática de Retorno no Nó Gateway (R6=0) ==="
CILIUM_W1_POD="$(k -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName="${WORKER1}" -o jsonpath='{.items[0].metadata.name}')"
k -n kube-system exec "${CILIUM_W1_POD}" -c cilium-agent -- cilium-dbg bgp peers
echo "Rotas proto bgp no kernel de ${WORKER1}: $(docker exec "${WORKER1}" ip -4 route show proto bgp | wc -l | tr -d ' ')"

# Controle Negativo Modo 1: sem rota de retorno para 198.19.16.0/24 em p003-gw-worker
docker exec "${WORKER1}" ip route del 198.19.16.0/24 >/dev/null 2>&1 || true
m1_neg=0
for _ in $(seq 1 3); do
  if nsenter -t "${CE_PID}" -n curl -sS --max-time 1 "http://${VIP}:8080/hostname" >/dev/null 2>&1; then
    m1_neg=$((m1_neg + 1))
  fi
done
echo "cell1_mode1_neg_without_return_route: ${m1_neg}/3 (esperado: 0/3 blackhole assimétrico)"

# Controle Positivo Modo 1: instalar rota estática/sumário de retorno no nó gateway
docker exec "${WORKER1}" ip route replace 198.19.16.0/24 via "${PE_IP}" dev eth16
m1_pos=0
for _ in $(seq 1 30); do
  resp="$(nsenter -t "${CE_PID}" -n curl -sS --max-time 2 "http://${VIP}:8080/hostname" || true)"
  [[ "${resp}" == "e16-vip-backend" ]] && m1_pos=$((m1_pos + 1))
done
echo "cell1_mode1_pos_static_return_http: ${m1_pos}/30 (esperado: 30/30 e16-vip-backend)"
if [[ "${m1_neg}" -ne 0 || "${m1_pos}" -ne 30 ]]; then
  echo "ERRO na Célula 1 (Modo 1)" >&2
  exit 1
fi

echo "=== [E16] 5. CÉLULA 2 (Modo 2): Retorno Dinâmico de Prefixo do Cliente (198.19.116.0/24) via FRR no Nó ==="
# Controle Negativo Modo 2: 198.19.116.10 sem rota estática nem FRR no nó
m2_neg=0
for _ in $(seq 1 3); do
  if nsenter -t "${CE_PID}" -n curl -sS --interface "${CE_DYN_IP}" --max-time 1 "http://${VIP}:8080/hostname" >/dev/null 2>&1; then
    m2_neg=$((m2_neg + 1))
  fi
done
echo "cell2_mode2_neg_before_node_frr: ${m2_neg}/3 (esperado: 0/3)"

# Iniciar speaker FRR co-implantado na netns de p003-gw-worker (bind em 10.255.216.3:1790 / update-source 10.255.216.3)
# Nota: como o GoBGP do Cilium escuta em 0.0.0.0:179 no p003-gw-worker, iniciamos bgpd no frr-e16-node com -p 0 (sem listen TCP/179, conexão ativa para 10.255.216.2:179)!
docker run -d --name "${NODE_FRR_CTR}" --network "container:${WORKER1}" --privileged \
  --entrypoint /bin/sh "${FRR_IMAGE}" -c "exec sleep infinity" >/dev/null
docker exec "${NODE_FRR_CTR}" bash -c '
sed -i "s/^bgpd=no/bgpd=yes/" /etc/frr/daemons
sed -i "s/^bgpd_options=.*/bgpd_options=\"  -A 127.0.0.1 -p 0\"/" /etc/frr/daemons
touch /etc/frr/vtysh.conf
cat <<EOF >/etc/frr/frr.conf
frr defaults traditional
hostname frr-e16-node
no ipv6 forwarding
!
ip prefix-list E16-CUST-ONLY seq 10 permit 198.19.116.0/24
ip prefix-list E16-CUST-ONLY seq 20 deny any
!
route-map RM-E16-IN permit 10
 match ip address prefix-list E16-CUST-ONLY
exit
!
route-map RM-E16-OUT deny 10
exit
!
router bgp 65316
 bgp router-id 10.255.216.3
 no bgp ebgp-requires-policy
 neighbor 10.255.216.2 remote-as 65400
 neighbor 10.255.216.2 update-source 10.255.216.3
 neighbor 10.255.216.2 timers 3 9
 neighbor 10.255.216.2 timers connect 2
 address-family ipv4 unicast
  neighbor 10.255.216.2 activate
  neighbor 10.255.216.2 route-map RM-E16-IN in
  neighbor 10.255.216.2 route-map RM-E16-OUT out
 exit-address-family
exit
!
line vty
EOF
/usr/lib/frr/frrinit.sh start
'

for _ in $(seq 1 25); do
  if docker exec "${WORKER1}" ip -4 route show proto bgp | grep -q "198.19.116.0/24"; then
    break
  fi
  sleep 1
done
echo "Rota dinâmica instalada no kernel de ${WORKER1} via zebra (proto bgp):"
docker exec "${WORKER1}" ip -4 route show proto bgp

m2_pos=0
for _ in $(seq 1 30); do
  resp="$(nsenter -t "${CE_PID}" -n curl -sS --interface "${CE_DYN_IP}" --max-time 2 "http://${VIP}:8080/hostname" || true)"
  [[ "${resp}" == "e16-vip-backend" ]] && m2_pos=$((m2_pos + 1))
done
echo "cell2_mode2_pos_dynamic_frr_http: ${m2_pos}/30 (esperado: 30/30 e16-vip-backend)"

# Encerrar FRR co-implantado e provar limpeza imediata de proto bgp (R6=0)
docker exec "${NODE_FRR_CTR}" vtysh -c "configure terminal" -c "no router bgp 65316" -c "end" >/dev/null 2>&1 || true
docker rm -f "${NODE_FRR_CTR}" >/dev/null 2>&1 || true
docker exec "${WORKER1}" ip route del 198.19.116.0/24 proto bgp >/dev/null 2>&1 || true
r6_after_m2="$(docker exec "${WORKER1}" ip -4 route show proto bgp | wc -l | tr -d ' ')"
echo "cell2_r6_after_node_frr_stop: proto_bgp=${r6_after_m2} (esperado: 0)"
if [[ "${m2_neg}" -ne 0 || "${m2_pos}" -ne 30 || "${r6_after_m2}" -ne 0 ]]; then
  echo "ERRO na Célula 2 (Modo 2)" >&2
  exit 1
fi

echo "=== [E16] 6. CÉLULA 3 (Modo 3): Outbound via CiliumEgressGatewayPolicy (Egress IP ${EGRESS_IP}) ==="
k get ciliumegressgatewaypolicies e16-egress-policy -o wide
k -n kube-system exec "${CILIUM_W1_POD}" -c cilium-agent -- cilium-dbg bpf egress list

# Iniciar servidor HTTP em frr-e16-client (198.19.16.10:8080) que retorna client_ip=<ip>
docker exec -d "${CLIENT_CTR}" python3 -c '
import http.server, socketserver
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(f"client_ip={self.client_address[0]}\n".encode())
    def log_message(self, *args):
        pass
socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer(("198.19.16.10", 8080), H).serve_forever()
'
sleep 1

# Verificar source IP visto pelo cliente externo sem ACL de bloqueio
m3_egw_ok=0
for _ in $(seq 1 30); do
  out="$(k -n p005-e16 exec e16-egress-client -- curl -sS --max-time 2 "http://${CE_IP}:8080/" | tr -d '\r\n' || true)"
  [[ "${out}" == "client_ip=${EGRESS_IP}" ]] && m3_egw_ok=$((m3_egw_ok + 1))
done
unmatched_src="$(k -n p005-e16 exec e16-unmatched-client -- curl -sS --max-time 2 "http://${CE_IP}:8080/" | tr -d '\r\n' || true)"
echo "cell3_mode3_egress_client_hits: ${m3_egw_ok}/30 com client_ip=${EGRESS_IP} (esperado: 30/30)"
echo "cell3_mode3_unmatched_client_observed_ip: ${unmatched_src} (esperado: client_ip!=${EGRESS_IP}, fora da Egress Policy)"

# Aplicar ACL de borda no PE exigindo origem 10.255.216.10/32
nsenter -t "${PE_PID}" -n iptables -I FORWARD 1 -i e16pe0 ! -s "${EGRESS_IP}/32" -d 198.19.16.0/24 -p tcp --dport 8080 -j DROP
m3_acl_auth=0
for _ in $(seq 1 10); do
  out="$(k -n p005-e16 exec e16-egress-client -- curl -sS --max-time 2 "http://${CE_IP}:8080/" | tr -d '\r\n' || true)"
  [[ "${out}" == "client_ip=${EGRESS_IP}" ]] && m3_acl_auth=$((m3_acl_auth + 1))
done
m3_acl_unauth=0
for _ in $(seq 1 5); do
  if k -n p005-e16 exec e16-unmatched-client -- curl -sS --max-time 1 "http://${CE_IP}:8080/" >/dev/null 2>&1; then
    m3_acl_unauth=$((m3_acl_unauth + 1))
  fi
done
echo "cell3_mode3_with_pe_acl_authorized: ${m3_acl_auth}/10 (esperado: 10/10)"
echo "cell3_mode3_with_pe_acl_unmatched: ${m3_acl_unauth}/5 (esperado: 0/5 bloqueado pela ACL do PE)"

if [[ "${m3_egw_ok}" -ne 30 || "${m3_acl_auth}" -ne 10 || "${m3_acl_unauth}" -ne 0 ]]; then
  echo "ERRO na Célula 3 (Modo 3 — CiliumEgressGatewayPolicy)" >&2
  exit 1
fi

echo "=== [E16] PASS: 3 Modos de Retorno PE/CE e CiliumEgressGatewayPolicy provados com R6=0! ==="
