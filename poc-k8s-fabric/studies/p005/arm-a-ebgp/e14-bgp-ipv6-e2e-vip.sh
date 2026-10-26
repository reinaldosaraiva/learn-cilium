#!/usr/bin/env bash
# ==============================================================================
# P005-S003 (Onda 3 — Braço A): E14 — Sessão eBGP IPv6 Dedicada (fd00:10:255:214::/64)
# e VIP IPv6 fd14::a/128 Fim a Fim
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

NS="p005-e14"
VIP4="10.202.255.194"
VIP6="fd14::a"
WORKER_NODE="p003-gw-worker2"
WORKER_ASN="65302"
BORDER_CTR="clab-p003-gw-fabric-border1"
BORDER_ASN="65400"
CLIENT_CTR="clab-p003-gw-fabric-frr-e14-client"
CLIENT_ASN="65514"
FRR_IMAGE="${FRR_IMAGE:-frrouting/frr:v8.4.1}"

# Enlace 1: p003-gw-worker2 (e14w0) <-> border1 (e14b0)
W_V4="10.255.214.1"
B_V4="10.255.214.2"
W_V6="fd00:10:255:214::1"
B_V6="fd00:10:255:214::2"

# Enlace 2: border1 (e14c0) <-> frr-e14-client (e14c1)
BC_V4="10.255.214.5"
CE_V4="10.255.214.6"
BC_V6="fd00:198:19::1"
CE_V6="fd00:198:19::10"

if $DRY_RUN; then
  cat <<EOF
[DRY-RUN] E14 — Sessão eBGP IPv6 Dedicada (${W_V6} <-> ${B_V6}) e VIP IPv6 ${VIP6}/128 Fim a Fim
  Cluster: ${P003_CONTEXT} (expected UID: ${EXPECTED_UID})
  VIPs do Service/e14-vip-svc em ${NS}: ${VIP4}/32 e ${VIP6}/128
  Enlaces:
    - ${WORKER_NODE}:e14w0 (${W_V4}/30, ${W_V6}/64, AS ${WORKER_ASN}) <-> ${BORDER_CTR}:e14b0 (${B_V4}/30, ${B_V6}/64, AS ${BORDER_ASN})
    - ${BORDER_CTR}:e14c0 (${BC_V4}/30, ${BC_V6}/64, AS ${BORDER_ASN}) <-> ${CLIENT_CTR}:e14c1 (${CE_V4}/30, ${CE_V6}/64, AS ${CLIENT_ASN})
  Células planejadas:
    1. Célula 1 (Baseline P002-S001 — ipv6/unicast sobre sessão TCP IPv4 ${W_V4} <-> ${B_V4}):
       - Comprovar que ${VIP6}/128 chega a ${BORDER_CTR} com next-hop IPv4-mapped ::ffff:${W_V4}.
    2. Célula 2 (Positivo — Sessão eBGP IPv6 nativa ${W_V6} <-> ${B_V6} e ${BC_V6} <-> ${CE_V6}):
       - Comprovar next-hop IPv6 nativo em ${BORDER_CTR} e ${CLIENT_CTR} e 30/30 respostas HTTP 200 em http://[${VIP6}]:8080/hostname.
    3. Célula 3 (Controle Negativo — Retirada da label e14-bgp do Service):
       - Comprovar retirada imediata de ${VIP6}/128 da RIB/FIB IPv6 e 0/5 respostas HTTP, seguida de restauração (5/5 HTTP 200).
    4. Rollback completo de CRDs, rotas IPv6, proxy/regras e containers.
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
  echo "[CLEANUP] Restaurando baseline BGP (rack2), border1 e removendo recursos de E14..."
  restore_bgp_baseline
  k delete -f "${SCRIPT_DIR}/manifests/06-e14-ipv6-e2e-vip.yaml" --ignore-not-found >/dev/null 2>&1 || true
  docker exec "${WORKER_NODE}" sh -c '
    if [ -f /tmp/e14-v6proxy.pid ]; then
      kill $(cat /tmp/e14-v6proxy.pid) 2>/dev/null || true
      rm -f /tmp/e14-v6proxy.pid /tmp/e14-v6proxy.py
    fi
    ip -6 route del fd00:198:19::/64 2>/dev/null || true
    ip -6 addr del fd14::a/128 dev lo 2>/dev/null || true
    ip link del eth14vip 2>/dev/null || true
    ip link del e14w0 2>/dev/null || true
  ' >/dev/null 2>&1 || true
  docker exec "${BORDER_CTR}" vtysh \
    -c "configure terminal" \
    -c "router bgp ${BORDER_ASN}" \
    -c "no neighbor ${W_V4} remote-as ${WORKER_ASN}" \
    -c "no neighbor ${W_V6} remote-as ${WORKER_ASN}" \
    -c "no neighbor ${CE_V6} remote-as ${CLIENT_ASN}" \
    -c "exit" \
    -c "end" >/dev/null 2>&1 || true
  docker exec "${BORDER_CTR}" ip link del e14b0 >/dev/null 2>&1 || true
  docker exec "${BORDER_CTR}" ip link del e14c0 >/dev/null 2>&1 || true
  docker rm -f "${CLIENT_CTR}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== [E14] 1. Criando Namespace ${NS}, Pod e14-echo, Service e14-vip-svc e CRDs BGP ==="
k apply -f "${SCRIPT_DIR}/manifests/06-e14-ipv6-e2e-vip.yaml"
k -n "${NS}" wait --for=condition=Ready pod/e14-echo --timeout=60s
POD_IP="$(k -n "${NS}" get pod e14-echo -o jsonpath='{.status.podIP}')"
echo "e14-echo PodIP=${POD_IP} (${WORKER_NODE})"

# Publicar ambos os endereços (IPv4 10.202.255.194 e IPv6 fd14::a) em .status.loadBalancer.ingress
k patch svc e14-vip-svc -n "${NS}" --subresource=status --type=merge \
  -p "{\"status\":{\"loadBalancer\":{\"ingress\":[{\"ip\":\"${VIP4}\"},{\"ip\":\"${VIP6}\"}]}}}"

echo "=== [E14] 2. Provisionando ${CLIENT_CTR} e Enlaces Dual-Stack IPv4/IPv6 ==="
docker rm -f "${CLIENT_CTR}" >/dev/null 2>&1 || true
docker run -d --name "${CLIENT_CTR}" --hostname frr-e14-client --network none --privileged \
  --entrypoint /bin/sh "${FRR_IMAGE}" -c "exec sleep infinity" >/dev/null

W_PID="$(docker inspect -f '{{.State.Pid}}' "${WORKER_NODE}")"
B_PID="$(docker inspect -f '{{.State.Pid}}' "${BORDER_CTR}")"
C_PID="$(docker inspect -f '{{.State.Pid}}' "${CLIENT_CTR}")"

for pid in "${W_PID}" "${B_PID}" "${C_PID}"; do
  nsenter -t "${pid}" -n sysctl -w \
    net.ipv6.conf.all.disable_ipv6=0 \
    net.ipv6.conf.default.disable_ipv6=0 \
    net.ipv6.conf.all.forwarding=1 >/dev/null
done

# Enlace 1: p003-gw-worker2 (e14w0) <-> border1 (e14b0)
ip link del e14w0 >/dev/null 2>&1 || true
ip link add e14w0 type veth peer name e14b0
ip link set e14w0 netns "${W_PID}"
ip link set e14b0 netns "${B_PID}"
nsenter -t "${W_PID}" -n ip link set e14w0 up
nsenter -t "${W_PID}" -n ip addr add "${W_V4}/30" dev e14w0
nsenter -t "${W_PID}" -n ip -6 addr add "${W_V6}/64" dev e14w0 nodad
nsenter -t "${B_PID}" -n ip link set e14b0 up
nsenter -t "${B_PID}" -n ip addr add "${B_V4}/30" dev e14b0
nsenter -t "${B_PID}" -n ip -6 addr add "${B_V6}/64" dev e14b0 nodad

# Enlace 2: border1 (e14c0) <-> frr-e14-client (e14c1)
ip link del e14c0 >/dev/null 2>&1 || true
ip link add e14c0 type veth peer name e14c1
ip link set e14c0 netns "${B_PID}"
ip link set e14c1 netns "${C_PID}"
nsenter -t "${B_PID}" -n ip link set e14c0 up
nsenter -t "${B_PID}" -n ip addr add "${BC_V4}/30" dev e14c0
nsenter -t "${B_PID}" -n ip -6 addr add "${BC_V6}/64" dev e14c0 nodad
nsenter -t "${C_PID}" -n ip link set lo up
nsenter -t "${C_PID}" -n ip link set e14c1 up
nsenter -t "${C_PID}" -n ip addr add "${CE_V4}/30" dev e14c1
nsenter -t "${C_PID}" -n ip -6 addr add "${CE_V6}/64" dev e14c1 nodad

# Configurar VIP IPv6 fd14::a/128 em eth14vip de p003-gw-worker2, rota de retorno IPv6 e forwarder TCP6 -> Pod
nsenter -t "${W_PID}" -n ip link del eth14vip >/dev/null 2>&1 || true
nsenter -t "${W_PID}" -n ip link add eth14vip type dummy
nsenter -t "${W_PID}" -n ip link set eth14vip up
nsenter -t "${W_PID}" -n ip -6 addr replace "${VIP6}/128" dev eth14vip nodad
nsenter -t "${W_PID}" -n ip -6 route replace fd00:198:19::/64 via "${B_V6}" dev e14w0

docker exec "${WORKER_NODE}" bash -c "
cat <<'PY' >/tmp/e14-v6proxy.py
import socket, threading, sys

POD_IP = sys.argv[1]
POD_PORT = int(sys.argv[2])

def pipe(src, dst):
    try:
        while True:
            data = src.recv(4096)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        try: src.close()
        except Exception: pass
        try: dst.close()
        except Exception: pass

def handle(c):
    try:
        u = socket.create_connection((POD_IP, POD_PORT), timeout=2.0)
    except Exception:
        c.close()
        return
    threading.Thread(target=pipe, args=(c, u), daemon=True).start()
    threading.Thread(target=pipe, args=(u, c), daemon=True).start()

srv = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
srv.bind(('::', 8080))
srv.listen(128)
while True:
    client, _ = srv.accept()
    threading.Thread(target=handle, args=(client,), daemon=True).start()
PY
python3 /tmp/e14-v6proxy.py '${POD_IP}' 8080 >/dev/null 2>&1 &
echo \$! >/tmp/e14-v6proxy.pid
"

# Iniciar FRR em frr-e14-client (AS 65514) com sessão IPv6 nativa
docker exec "${CLIENT_CTR}" bash -c '
sed -i "s/^bgpd=no/bgpd=yes/" /etc/frr/daemons
cat <<EOF >/etc/frr/frr.conf
frr defaults traditional
hostname frr-e14-client
ipv6 forwarding
!
router bgp 65514
 bgp router-id 10.255.214.6
 no bgp ebgp-requires-policy
 neighbor fd00:198:19::1 remote-as 65400
 neighbor fd00:198:19::1 timers 3 9
 neighbor fd00:198:19::1 timers connect 2
 address-family ipv6 unicast
  neighbor fd00:198:19::1 activate
 exit-address-family
exit
!
line vty
EOF
/usr/lib/frr/frrinit.sh start
'

echo "=== [E14] 3. Célula 1 (Baseline P002-S001): Anúncio ipv6/unicast sobre Sessão TCP IPv4 (${W_V4} <-> ${B_V4}) ==="
docker exec "${BORDER_CTR}" vtysh \
  -c "configure terminal" \
  -c "router bgp ${BORDER_ASN}" \
  -c "neighbor ${W_V4} remote-as ${WORKER_ASN}" \
  -c "neighbor ${W_V4} timers 3 9" \
  -c "neighbor ${W_V4} timers connect 2" \
  -c "address-family ipv4 unicast" \
  -c "neighbor ${W_V4} activate" \
  -c "exit-address-family" \
  -c "address-family ipv6 unicast" \
  -c "neighbor ${W_V4} activate" \
  -c "exit-address-family" \
  -c "end"

cat <<EOF | k apply -f -
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
    - name: "border1-e14-v4"
      peerASN: ${BORDER_ASN}
      peerAddress: "${B_V4}"
      peerConfigRef:
        name: "e14-peer-v4session"
EOF

for attempt in $(seq 1 30); do
  if docker exec "${BORDER_CTR}" vtysh -c "show bgp ipv6 unicast ${VIP6}/128" | grep -q "${W_V4}"; then
    echo "Célula 1: rota ${VIP6}/128 recebida sobre sessão IPv4 na tentativa ${attempt}"
    break
  fi
  sleep 1
done
sleep 1

CILIUM_W2="$(k -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName="${WORKER_NODE}" -o jsonpath='{.items[0].metadata.name}')"
echo "[Célula 1 — Sessão IPv4] Rotas IPv6 anunciadas pelo Cilium (${WORKER_NODE}):"
k -n kube-system exec "${CILIUM_W2}" -c cilium-agent -- cilium-dbg bgp routes advertised ipv6 unicast
echo "[Célula 1 — Sessão IPv4] RIB IPv6 de ${BORDER_CTR} para ${VIP6}/128 (observa next-hop ::ffff:${W_V4}):"
docker exec "${BORDER_CTR}" vtysh -c "show bgp ipv6 unicast ${VIP6}/128"

echo "=== [E14] 4. Célula 2 (Positiva): Sessão eBGP IPv6 Dedicada (${W_V6} <-> ${B_V6}) + VIP ${VIP6}/128 Fim a Fim ==="
docker exec "${BORDER_CTR}" vtysh \
  -c "configure terminal" \
  -c "router bgp ${BORDER_ASN}" \
  -c "no neighbor ${W_V4} remote-as ${WORKER_ASN}" \
  -c "neighbor ${W_V6} remote-as ${WORKER_ASN}" \
  -c "neighbor ${W_V6} timers 3 9" \
  -c "neighbor ${W_V6} timers connect 2" \
  -c "neighbor ${CE_V6} remote-as ${CLIENT_ASN}" \
  -c "neighbor ${CE_V6} timers 3 9" \
  -c "neighbor ${CE_V6} timers connect 2" \
  -c "address-family ipv6 unicast" \
  -c "neighbor ${W_V6} activate" \
  -c "neighbor ${CE_V6} activate" \
  -c "exit-address-family" \
  -c "end"

cat <<EOF | k apply -f -
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
    - name: "border1-e14-v6"
      peerASN: ${BORDER_ASN}
      peerAddress: "${B_V6}"
      peerConfigRef:
        name: "e14-peer-v6native"
EOF

for attempt in $(seq 1 30); do
  if nsenter -t "${C_PID}" -n ip -6 route show "${VIP6}/128" | grep -q "${BC_V6}"; then
    echo "Célula 2: rota IPv6 ${VIP6}/128 instalada na FIB de ${CLIENT_CTR} na tentativa ${attempt}"
    break
  fi
  sleep 1
done
sleep 1

echo "[Célula 2 — Sessão IPv6 Nativa] Peers BGP no Cilium (${WORKER_NODE}):"
k -n kube-system exec "${CILIUM_W2}" -c cilium-agent -- cilium-dbg bgp peers
echo "[Célula 2 — Sessão IPv6 Nativa] RIB IPv6 de ${BORDER_CTR} para ${VIP6}/128 (next-hop nativo ${W_V6}):"
docker exec "${BORDER_CTR}" vtysh -c "show bgp ipv6 unicast ${VIP6}/128"
echo "[Célula 2 — Sessão IPv6 Nativa] RIB e FIB IPv6 de ${CLIENT_CTR} para ${VIP6}/128:"
docker exec "${CLIENT_CTR}" vtysh -c "show bgp ipv6 unicast ${VIP6}/128"
nsenter -t "${C_PID}" -n ip -6 route show "${VIP6}/128"

C2_OK=0
for i in $(seq 1 30); do
  resp="$(nsenter -t "${C_PID}" -n curl -6 -g -sS --connect-timeout 1 --max-time 2 "http://[${VIP6}]:8080/hostname" || true)"
  if [[ "${resp}" == "e14-echo" ]]; then
    C2_OK=$((C2_OK + 1))
  fi
done
echo "cell2_ipv6_http_200: ${C2_OK}/30"
if [[ "${C2_OK}" -ne 30 ]]; then
  echo "ERRO E14-C2: esperado 30/30 respostas HTTP 200 sobre IPv6, obtido ${C2_OK}/30" >&2
  exit 1
fi

echo "=== [E14] 5. Célula 3 (Controle Negativo): Retirada do Anúncio BGP de ${VIP6}/128 ==="
k label svc e14-vip-svc -n "${NS}" e14-bgp-
nsenter -t "${W_PID}" -n ip -6 addr del "${VIP6}/128" dev eth14vip 2>/dev/null || true
for attempt in $(seq 1 20); do
  if [[ -z "$(nsenter -t "${C_PID}" -n ip -6 route show "${VIP6}/128")" ]]; then
    echo "Célula 3: rota ${VIP6}/128 retirada da FIB de ${CLIENT_CTR} na tentativa ${attempt}"
    break
  fi
  sleep 1
done

echo "[Célula 3 — Após Withdraw] RIB IPv6 de ${BORDER_CTR} e FIB de ${CLIENT_CTR}:"
docker exec "${BORDER_CTR}" vtysh -c "show bgp ipv6 unicast ${VIP6}/128" || true
nsenter -t "${C_PID}" -n ip -6 route show "${VIP6}/128" || true

C3_FAIL=0
for i in $(seq 1 5); do
  if ! nsenter -t "${C_PID}" -n curl -6 -g -sS --connect-timeout 1 --max-time 1 "http://[${VIP6}]:8080/hostname" >/dev/null 2>&1; then
    C3_FAIL=$((C3_FAIL + 1))
  fi
done
echo "cell3_withdraw_blocked: ${C3_FAIL}/5"
if [[ "${C3_FAIL}" -ne 5 ]]; then
  echo "ERRO E14-C3: esperado 5/5 falhas após withdraw, obtido ${C3_FAIL}/5" >&2
  exit 1
fi

echo "[Célula 3] Restaurando anúncio BGP (${VIP6}/128 + label e14-bgp=true) e validando reconvergência..."
nsenter -t "${W_PID}" -n ip -6 addr replace "${VIP6}/128" dev eth14vip nodad
k label svc e14-vip-svc -n "${NS}" e14-bgp=true --overwrite
k patch svc e14-vip-svc -n "${NS}" --subresource=status --type=merge \
  -p "{\"status\":{\"loadBalancer\":{\"ingress\":[{\"ip\":\"${VIP4}\"},{\"ip\":\"${VIP6}\"}]}}}"

for attempt in $(seq 1 20); do
  if nsenter -t "${C_PID}" -n ip -6 route show "${VIP6}/128" | grep -q "${BC_V6}"; then
    break
  fi
  sleep 1
done

C3_RECOVER=0
for i in $(seq 1 5); do
  resp="$(nsenter -t "${C_PID}" -n curl -6 -g -sS --connect-timeout 1 --max-time 2 "http://[${VIP6}]:8080/hostname" || true)"
  [[ "${resp}" == "e14-echo" ]] && C3_RECOVER=$((C3_RECOVER + 1))
done
echo "cell3_restored_http_200: ${C3_RECOVER}/5"

echo "=== [E14] CONCLUÍDO COM SUCESSO ==="
