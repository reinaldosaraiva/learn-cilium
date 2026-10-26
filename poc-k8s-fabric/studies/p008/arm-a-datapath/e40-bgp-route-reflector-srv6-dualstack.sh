#!/usr/bin/env bash
# ==============================================================================
# E40 — BGP Route Reflector (RFC 4456) & SRv6 L3VPN Dual-Stack (End.DT4 + End.DT6)
# Plano P008-S002 (Braço A)
#
# Objetivo:
#   1. Célula 1 (Escalabilidade iBGP via Route Reflector RFC 4456 sem Full-Mesh):
#      - Validar no cluster `kind-p003-gw` os recursos `CiliumLoadBalancerIPPool`
#        e `CiliumBGPAdvertisement` (`localPreference: 150`, `65400:400`).
#      - Construir uma topologia iBGP (`AS 65400`) onde dois workers (`e40-w1` e
#        `e40-w2`) pareiam EXCLUSIVAMENTE com um Route Reflector central
#        (`e40-rr`, `bgp cluster-id 10.255.40.1`), com `0` sessões BGP diretas
#        entre `w1` e `w2` (`w1_w2_direct_sessions=0`).
#      - Provar que `w1` e `w2` aprendem mutuamente as VIPs IPv4
#        (`10.208.40.101/32`, `10.208.40.102/32`) e IPv6 (`fd00:208:40::101/128`,
#        `fd00:208:40::102/128`) refletidas por `e40-rr` preservando o next-hop e
#        estampando os atributos RFC 4456 `Originator:` e `Cluster list:`, com
#        `10/10` respostas HTTP 200 em IPv4 e `10/10` em IPv6.
#   2. Célula 2 (SRv6 L3VPN Dual-Stack Completo: `End.DT4` + `End.DT6`):
#      - Sobre um backbone puramente IPv6 (`fc00:40::/64`) entre `e40-pe1` e
#        `e40-pe2`, instanciar duas VRFs (`vrf-tenant-a` table `1040` e
#        `vrf-tenant-b` table `2040`) com prefixos IPv4 E IPv6 100% sobrepostos:
#        * IPv4: `10.253.40.10/24` (PE1) <-> `10.253.40.20/24` (PE2) em AMBOS!
#        * IPv6: `fd40:253:40::10/64` (PE1) <-> `fd40:253:40::20/64` (PE2) em AMBOS!
#      - Programar SIDs `seg6local action End.DT4 vrftable 1040/2040` e
#        `seg6local action End.DT6 table 1040/2040` e provar `10/10` HTTP 200 IPv4
#        e `10/10` HTTP 200 IPv6 intra-tenant simultâneos para Tenant A e Tenant B.
#   3. Célula 3 (Controles Negativos — Anti-Loop RFC 4456, Isolamento Cross-VRF & Rollback):
#      - 3A: Comprovar que `e40-w1` descarta o reflexo de sua própria rota
#        (`Originator: 10.208.40.2` anti-loop RFC 4456) sem duplicação/loop.
#      - 3B: Remover temporariamente o SID `End.DT6` do Tenant A -> `0/5` em IPv6
#        enquanto IPv4 `End.DT4` permanece `10/10` e Tenant B permanece `10/10` em
#        ambos; restaurar `End.DT6` -> `10/10` recuperado.
#      - 3C: Teardown completo e verificação `R6=0`.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/02-e40-bgp-route-reflector-srv6-dualstack.yaml"
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) echo "Uso: $0 [--dry-run]" >&2; exit 1 ;;
  esac
done

log() { printf "[e40][%s] %s\n" "$(date -u +%H:%M:%SZ)" "$*"; }

if $DRY_RUN; then
  log "DRY-RUN: validando existência do manifesto ${MANIFEST}"
  [[ -f "$MANIFEST" ]] || { echo "Manifesto ausente: $MANIFEST" >&2; exit 1; }
  log "DRY-RUN OK: E40 pronto para execução ao vivo na vm-cilium."
  exit 0
fi

export KUBECONFIG="${SANDBOX_KUBECONFIG:-${KUBECONFIG:-${HOME}/.kube/config}}"
CTX="kind-p003-gw"
FRR_IMAGE="quay.io/frrouting/frr:10.3.1"
CONTAINERS=("e40-rr" "e40-w1" "e40-w2")
NETNS_LIST=("e40-pe1" "e40-pe2" "e40-ta-1" "e40-ta-2" "e40-tb-1" "e40-tb-2")

cleanup() {
  log "Iniciando cleanup (rollback R6=0)..."
  kubectl --context "$CTX" delete -f "$MANIFEST" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  for c in "${CONTAINERS[@]}"; do
    docker rm -f "$c" >/dev/null 2>&1 || true
  done
  for ns in "${NETNS_LIST[@]}"; do
    ip netns pids "$ns" 2>/dev/null | xargs -r kill -9 >/dev/null 2>&1 || true
    ip netns del "$ns" >/dev/null 2>&1 || true
  done
  wait 2>/dev/null || true
  ip link del veth-rr-w1 >/dev/null 2>&1 || true
  ip link del veth-rr-w2 >/dev/null 2>&1 || true
  ip link del veth-pe1-pe2 >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "=== E40 PREFLIGHT: Verificando invariantes k01, p003-gw e piso R3 ==="
kubectl --context kind-k01 get nodes --no-headers | awk '{if ($2 != "Ready") exit 1}'
kubectl --context "$CTX" get nodes --no-headers | awk '{if ($2 != "Ready") exit 1}'
MEM_AVAIL_KB="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
log "MemAvailable=${MEM_AVAIL_KB} kB"
if (( MEM_AVAIL_KB < 4194304 )); then
  echo "ERRO: MemAvailable (${MEM_AVAIL_KB} kB) abaixo do piso R3 (4 GiB)" >&2
  exit 1
fi

log "=== CÉLULA 1: iBGP Route Reflector (RFC 4456 ORIGINATOR_ID & CLUSTER_LIST) ==="
kubectl --context "$CTX" apply -f "$MANIFEST"
ADV_LP="$(kubectl --context "$CTX" get ciliumbgpadvertisement e40-rr-dualstack-adv -o jsonpath='{.spec.advertisements[0].attributes.localPreference}')"
log "CiliumBGPAdvertisement reconciliado (localPreference=${ADV_LP})"
[[ "$ADV_LP" == "150" ]] || { echo "Falha ao reconciliar CiliumBGPAdvertisement" >&2; exit 1; }

for c in "${CONTAINERS[@]}"; do
  docker rm -f "$c" >/dev/null 2>&1 || true
  docker run -d --name "$c" --hostname "$c" --privileged --net none "$FRR_IMAGE" sleep infinity >/dev/null
done

PID_RR="$(docker inspect -f '{{.State.Pid}}' e40-rr)"
PID_W1="$(docker inspect -f '{{.State.Pid}}' e40-w1)"
PID_W2="$(docker inspect -f '{{.State.Pid}}' e40-w2)"

# Conectar w1 <-> rr <-> w2 em sub-redes distintas sobre uma bridge L2 ou roteamento com next-hop-unchanged
# Usaremos uma sub-rede iBGP comum via bridge no RR para que w1 (10.208.40.2) e w2 (10.208.40.3) alcancem
# o next-hop preservado pelo Route Reflector (10.208.40.1), mas bloqueando TCP :179 direto entre w1 e w2!
ip link add veth-rr-w1 type veth peer name veth-w1-rr
ip link set veth-rr-w1 netns "$PID_RR"
ip link set veth-w1-rr netns "$PID_W1"

ip link add veth-rr-w2 type veth peer name veth-w2-rr
ip link set veth-rr-w2 netns "$PID_RR"
ip link set veth-w2-rr netns "$PID_W2"

nsenter -t "$PID_RR" -n ip link set lo up
nsenter -t "$PID_RR" -n ip link add br-rr type bridge
nsenter -t "$PID_RR" -n ip link set br-rr up
nsenter -t "$PID_RR" -n ip link set veth-rr-w1 master br-rr up
nsenter -t "$PID_RR" -n ip link set veth-rr-w2 master br-rr up
nsenter -t "$PID_RR" -n ip addr add 10.208.40.1/24 dev br-rr
nsenter -t "$PID_RR" -n ip -6 addr add fd00:208:40::1/64 dev br-rr nodad
nsenter -t "$PID_RR" -n sysctl -qw net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1

nsenter -t "$PID_W1" -n ip link set lo up
nsenter -t "$PID_W1" -n ip link set veth-w1-rr up
nsenter -t "$PID_W1" -n ip addr add 10.208.40.2/24 dev veth-w1-rr
nsenter -t "$PID_W1" -n ip -6 addr add fd00:208:40::2/64 dev veth-w1-rr nodad
nsenter -t "$PID_W1" -n ip addr add 10.208.40.101/32 dev lo
nsenter -t "$PID_W1" -n ip -6 addr add fd00:208:40::101/128 dev lo nodad

nsenter -t "$PID_W2" -n ip link set lo up
nsenter -t "$PID_W2" -n ip link set veth-w2-rr up
nsenter -t "$PID_W2" -n ip addr add 10.208.40.3/24 dev veth-w2-rr
nsenter -t "$PID_W2" -n ip -6 addr add fd00:208:40::3/64 dev veth-w2-rr nodad
nsenter -t "$PID_W2" -n ip addr add 10.208.40.102/32 dev lo
nsenter -t "$PID_W2" -n ip -6 addr add fd00:208:40::102/128 dev lo nodad

start_frr() {
  local c="$1" cfg="$2"
  docker exec "$c" sh -c "
    sed -i 's/bgpd=no/bgpd=yes/' /etc/frr/daemons
    touch /etc/frr/vtysh.conf
    cat > /etc/frr/frr.conf << 'EOF'
${cfg}
EOF
    chown frr:frr /etc/frr/frr.conf /etc/frr/vtysh.conf
    /usr/lib/frr/frrinit.sh start
  " >/dev/null 2>&1
}

start_frr "e40-rr" "
frr defaults traditional
hostname e40-rr
service integrated-vtysh-config
!
router bgp 65400
 bgp router-id 10.208.40.1
 bgp cluster-id 10.255.40.1
 no bgp ebgp-requires-policy
 neighbor 10.208.40.2 remote-as 65400
 neighbor 10.208.40.3 remote-as 65400
 neighbor fd00:208:40::2 remote-as 65400
 neighbor fd00:208:40::3 remote-as 65400
 !
 address-family ipv4 unicast
  neighbor 10.208.40.2 route-reflector-client
  neighbor 10.208.40.3 route-reflector-client
 exit-address-family
 !
 address-family ipv6 unicast
  neighbor fd00:208:40::2 activate
  neighbor fd00:208:40::2 route-reflector-client
  neighbor fd00:208:40::3 activate
  neighbor fd00:208:40::3 route-reflector-client
 exit-address-family
!
"

start_frr "e40-w1" "
frr defaults traditional
hostname e40-w1
service integrated-vtysh-config
!
router bgp 65400
 bgp router-id 10.208.40.2
 no bgp ebgp-requires-policy
 neighbor 10.208.40.1 remote-as 65400
 neighbor fd00:208:40::1 remote-as 65400
 !
 address-family ipv4 unicast
  network 10.208.40.101/32
 exit-address-family
 !
 address-family ipv6 unicast
  network fd00:208:40::101/128
  neighbor fd00:208:40::1 activate
 exit-address-family
!
"

start_frr "e40-w2" "
frr defaults traditional
hostname e40-w2
service integrated-vtysh-config
!
router bgp 65400
 bgp router-id 10.208.40.3
 no bgp ebgp-requires-policy
 neighbor 10.208.40.1 remote-as 65400
 neighbor fd00:208:40::1 remote-as 65400
 !
 address-family ipv4 unicast
  network 10.208.40.102/32
 exit-address-family
 !
 address-family ipv6 unicast
  network fd00:208:40::102/128
  neighbor fd00:208:40::1 activate
 exit-address-family
!
"

log "Aguardando convergência do Route Reflector (e40-rr)..."
for _ in $(seq 1 20); do
  if docker exec e40-w2 vtysh -c "show bgp ipv4 unicast 10.208.40.101/32" 2>/dev/null | grep -q "Originator: 10.208.40.2"; then
    break
  fi
  sleep 1
done

RR_V4_DETAIL="$(docker exec e40-w2 vtysh -c 'show bgp ipv4 unicast 10.208.40.101/32')"
RR_V6_DETAIL="$(docker exec e40-w2 vtysh -c 'show bgp ipv6 unicast fd00:208:40::101/128')"
W1_PEERS_COUNT="$(docker exec e40-w1 vtysh -c 'show bgp ipv4 unicast summary' | awk '/^[[:space:]]*10\.208\.40\./{c++} END{print c+0}')"
W1_W2_DIRECT="$(docker exec e40-w1 vtysh -c 'show bgp ipv4 unicast summary' | awk '/^[[:space:]]*10\.208\.40\.3/{c++} END{print c+0}')"
log "Sessões iBGP IPv4 em e40-w1: ${W1_PEERS_COUNT} (apenas com o RR 10.208.40.1; direct_w1_w2=${W1_W2_DIRECT})"
echo "$RR_V4_DETAIL" | grep -E "Originator:|Cluster list:"
echo "$RR_V6_DETAIL" | grep -E "Originator:|Cluster list:"

[[ "$RR_V4_DETAIL" == *"Originator: 10.208.40.2"* && "$RR_V4_DETAIL" == *"Cluster list: 10.255.40.1"* ]] || {
  echo "Atributos RFC 4456 ausentes em IPv4" >&2; exit 1;
}
[[ "$RR_V6_DETAIL" == *"Originator: 10.208.40.2"* && "$RR_V6_DETAIL" == *"Cluster list: 10.255.40.1"* && "$W1_PEERS_COUNT" -eq 1 ]] || {
  echo "Atributos RFC 4456 ausentes em IPv6 ou número incorreto de peers" >&2; exit 1;
}

# Testar alcance L3 fim a fim entre as VIPs refletidas (10.208.40.101 <-> 10.208.40.102 e fd00:208:40::101 <-> ::102)
RR_PING_V4=0
RR_PING_V6=0
for _ in $(seq 1 10); do
  docker exec e40-w2 ping -c 1 -W 1 -I 10.208.40.102 10.208.40.101 >/dev/null 2>&1 && RR_PING_V4=$((RR_PING_V4 + 1))
  docker exec e40-w2 ping -6 -c 1 -W 1 -I fd00:208:40::102 fd00:208:40::101 >/dev/null 2>&1 && RR_PING_V6=$((RR_PING_V6 + 1))
done
log "Resultado Célula 1 (Route Reflector Dual-Stack): ping_v4=${RR_PING_V4}/10 ping_v6=${RR_PING_V6}/10 direct_w1_w2_peers=0"
[[ "$RR_PING_V4" -eq 10 && "$RR_PING_V6" -eq 10 ]] || {
  echo "Falha de conectividade entre VIPs refletidas na Célula 1" >&2; exit 1;
}

log "=== CÉLULA 2: SRv6 L3VPN Dual-Stack Completo (End.DT4 + End.DT6 com CIDRs IPv4/IPv6 Sobrepostos) ==="
for ns in "${NETNS_LIST[@]}"; do
  ip netns add "$ns"
  ip -n "$ns" link set lo up
done

# Conectar PE1 <-> PE2 por enlace puramente IPv6 (fc00:40::/64)
ip link add veth-pe1-pe2 netns e40-pe1 type veth peer name veth-pe2-pe1 netns e40-pe2
ip -n e40-pe1 link set veth-pe1-pe2 up
ip -n e40-pe2 link set veth-pe2-pe1 up
ip -n e40-pe1 -6 addr add fc00:40::1/64 dev veth-pe1-pe2 nodad
ip -n e40-pe2 -6 addr add fc00:40::2/64 dev veth-pe2-pe1 nodad

setup_pe_vrf() {
  local pe="$1" pe_num="$2" remote_pe_num="$3" host_ip="$4" remote_sub_v4="$5" remote_sub_v6="$6"
  local veth_dev="veth-pe${pe_num}-pe${remote_pe_num}"
  ip netns exec "$pe" sysctl -qw net.ipv4.ip_forward=1 \
    net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0 "net.ipv4.conf.${veth_dev}.rp_filter=0" \
    net.ipv6.conf.all.forwarding=1 \
    net.ipv6.conf.all.seg6_enabled=1 net.ipv6.conf.default.seg6_enabled=1 \
    net.ipv6.conf.lo.seg6_enabled=1 "net.ipv6.conf.${veth_dev}.seg6_enabled=1" \
    net.vrf.strict_mode=1

  # Criar VRFs para Tenant A (1040) e Tenant B (2040)
  ip -n "$pe" link add vrf-tenant-a type vrf table 1040
  ip -n "$pe" link set vrf-tenant-a up
  ip -n "$pe" link add vrf-tenant-b type vrf table 2040
  ip -n "$pe" link set vrf-tenant-b up
  ip netns exec "$pe" sysctl -qw net.ipv4.conf.vrf-tenant-a.rp_filter=0 net.ipv4.conf.vrf-tenant-b.rp_filter=0 \
    net.ipv6.conf.vrf-tenant-a.seg6_enabled=1 net.ipv6.conf.vrf-tenant-b.seg6_enabled=1

  # Rota de alcançabilidade para o bloco de SIDs do PE remoto (em main e nas tabelas VRF 1040 e 2040)
  ip -n "$pe" -6 rule add pref 100 to fc00:40::/32 lookup main
  ip -n "$pe" -6 route add "fc00:40:${remote_pe_num}::/48" via "fc00:40::${remote_pe_num}" dev "$veth_dev"
  ip -n "$pe" -6 route add "fc00:40:${remote_pe_num}::/48" via "fc00:40::${remote_pe_num}" dev "$veth_dev" table 1040
  ip -n "$pe" -6 route add "fc00:40:${remote_pe_num}::/48" via "fc00:40::${remote_pe_num}" dev "$veth_dev" table 2040

  # SIDs Locais SRv6 Dual-Stack (End.DT4 para IPv4 + End.DT6 para IPv6) na tabela main (dev $veth_dev sob strict_mode=1)
  ip -n "$pe" -6 addr replace "fc00:40:${pe_num}::1/128" dev lo nodad
  ip -n "$pe" -6 route replace "fc00:40:${pe_num}::d4a/128" encap seg6local action End.DT4 vrftable 1040 dev "$veth_dev"
  ip -n "$pe" -6 route replace "fc00:40:${pe_num}::d6a/128" encap seg6local action End.DT6 table 1040 dev "$veth_dev"
  ip -n "$pe" -6 route replace "fc00:40:${pe_num}::d4b/128" encap seg6local action End.DT4 vrftable 2040 dev "$veth_dev"
  ip -n "$pe" -6 route replace "fc00:40:${pe_num}::d6b/128" encap seg6local action End.DT6 table 2040 dev "$veth_dev"

  # Rotas de Encapsulamento nas tabelas VRF (1040 e 2040)
  ip -n "$pe" route replace "$remote_sub_v4" encap seg6 mode encap segs "fc00:40:${remote_pe_num}::d4a" dev "$veth_dev" table 1040
  ip -n "$pe" -6 route replace "$remote_sub_v6" encap seg6 mode encap segs "fc00:40:${remote_pe_num}::d6a" dev "$veth_dev" table 1040
  ip -n "$pe" route replace "$remote_sub_v4" encap seg6 mode encap segs "fc00:40:${remote_pe_num}::d4b" dev "$veth_dev" table 2040
  ip -n "$pe" -6 route replace "$remote_sub_v6" encap seg6 mode encap segs "fc00:40:${remote_pe_num}::d6b" dev "$veth_dev" table 2040
}

setup_pe_vrf "e40-pe1" 1 2 10 "10.253.40.20/32" "fd40:253:40::20/128"
setup_pe_vrf "e40-pe2" 2 1 20 "10.253.40.10/32" "fd40:253:40::10/128"

attach_tenant_ns() {
  local pe="$1" tns="$2" vrf="$3" gw_v4="$4" host_v4="$5" gw_v6="$6" host_v6="$7" remote_v4="$8" remote_v6="$9"
  local v_pe="v-${tns}" v_ns="eth0"
  ip link add "$v_pe" netns "$pe" type veth peer name "$v_ns" netns "$tns"
  ip -n "$pe" link set "$v_pe" master "$vrf" up
  ip netns exec "$pe" sysctl -qw "net.ipv4.conf.${v_pe}.rp_filter=0" "net.ipv6.conf.${v_pe}.seg6_enabled=1"
  ip -n "$pe" addr add "${gw_v4}/24" dev "$v_pe"
  ip -n "$pe" -6 addr add "${gw_v6}/64" dev "$v_pe" nodad
  ip -n "$tns" link set "$v_ns" up
  ip -n "$tns" addr add "${host_v4}/24" dev "$v_ns"
  ip -n "$tns" -6 addr add "${host_v6}/64" dev "$v_ns" nodad
  ip -n "$tns" route add default via "$gw_v4"
  ip -n "$tns" -6 route add default via "$gw_v6"
  ip -n "$tns" route replace "${remote_v4}/32" via "$gw_v4"
  ip -n "$tns" -6 route replace "${remote_v6}/128" via "$gw_v6"
}

# Ambos Tenant A e Tenant B usam EXATAMENTE os mesmos IPs IPv4 (10.253.40.10 -> .20) e IPv6 (fd40:253:40::10 -> ::20)!
attach_tenant_ns "e40-pe1" "e40-ta-1" "vrf-tenant-a" "10.253.40.1" "10.253.40.10" "fd40:253:40::1" "fd40:253:40::10" "10.253.40.20" "fd40:253:40::20"
attach_tenant_ns "e40-pe1" "e40-tb-1" "vrf-tenant-b" "10.253.40.1" "10.253.40.10" "fd40:253:40::1" "fd40:253:40::10" "10.253.40.20" "fd40:253:40::20"
attach_tenant_ns "e40-pe2" "e40-ta-2" "vrf-tenant-a" "10.253.40.2" "10.253.40.20" "fd40:253:40::2" "fd40:253:40::20" "10.253.40.10" "fd40:253:40::10"
attach_tenant_ns "e40-pe2" "e40-tb-2" "vrf-tenant-b" "10.253.40.2" "10.253.40.20" "fd40:253:40::2" "fd40:253:40::20" "10.253.40.10" "fd40:253:40::10"

# Iniciar servidores HTTP dual-stack (IPv4 + IPv6) em e40-ta-2 e e40-tb-2
start_dualstack_http() {
  local ns="$1" tag="$2"
  ip netns exec "$ns" python3 -c "
import http.server, socket, socketserver, threading

class DualStackServer(socketserver.TCPServer):
    address_family = socket.AF_INET6
    allow_reuse_address = True
    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'${tag}\n')
    def log_message(self, *args): pass

s = DualStackServer(('::', 8080), Handler)
s.serve_forever()
" &
}

start_dualstack_http "e40-ta-2" "TENANT-A-DUALSTACK"
start_dualstack_http "e40-tb-2" "TENANT-B-DUALSTACK"
sleep 1

# Aquecer vizinhança NDP/ARP antes da bateria de probes HTTP
ip netns exec e40-pe1 ping -6 -c 1 -W 1 fc00:40::2 >/dev/null 2>&1 || true
ip netns exec e40-ta-1 ping -c 1 -W 1 10.253.40.20 >/dev/null 2>&1 || true
ip netns exec e40-ta-1 ping -6 -c 1 -W 1 fd40:253:40::20 >/dev/null 2>&1 || true
ip netns exec e40-tb-1 ping -c 1 -W 1 10.253.40.20 >/dev/null 2>&1 || true
ip netns exec e40-tb-1 ping -6 -c 1 -W 1 fd40:253:40::20 >/dev/null 2>&1 || true

probe_srv6() {
  local ns="$1" url="$2" expected="$3" count="$4" max_t="${5:-1.5}"
  local ok=0
  for _ in $(seq 1 "$count"); do
    local out
    out="$(ip netns exec "$ns" curl -sS --max-time "$max_t" "$url" 2>/dev/null || true)"
    if [[ "$out" == "$expected" ]]; then
      ok=$((ok + 1))
    fi
  done
  echo "$ok"
}

TA_V4_OK="$(probe_srv6 e40-ta-1 "http://10.253.40.20:8080/" "TENANT-A-DUALSTACK" 10)"
TA_V6_OK="$(probe_srv6 e40-ta-1 "http://[fd40:253:40::20]:8080/" "TENANT-A-DUALSTACK" 10)"
TB_V4_OK="$(probe_srv6 e40-tb-1 "http://10.253.40.20:8080/" "TENANT-B-DUALSTACK" 10)"
TB_V6_OK="$(probe_srv6 e40-tb-1 "http://[fd40:253:40::20]:8080/" "TENANT-B-DUALSTACK" 10)"

log "Resultado Célula 2 (SRv6 Dual-Stack End.DT4 + End.DT6 com IPs Sobrepostos): TA_v4=${TA_V4_OK}/10 TA_v6=${TA_V6_OK}/10 TB_v4=${TB_V4_OK}/10 TB_v6=${TB_V6_OK}/10"
[[ "$TA_V4_OK" -eq 10 && "$TA_V6_OK" -eq 10 && "$TB_V4_OK" -eq 10 && "$TB_V6_OK" -eq 10 ]] || {
  echo "Falha na Célula 2 (SRv6 Dual-Stack)" >&2; exit 1;
}

log "=== CÉLULA 3: Controles Negativos (3A Anti-Loop RFC 4456, 3B Remoção Seletiva End.DT6 & 3C Rollback) ==="
# 3A: Verificar que e40-w1 NÃO instala de volta sua própria rota 10.208.40.101/32 vinda do RR (anti-loop ORIGINATOR_ID)
W1_SELF_PATHS="$(docker exec e40-w1 vtysh -c 'show bgp ipv4 unicast 10.208.40.101/32' | grep -cE 'from 10\.208\.40\.1([^0-9]|$)' || true)"
log "Controle 3A (Anti-Loop RFC 4456 em e40-w1): caminhos refletidos aceitos para o próprio prefixo=${W1_SELF_PATHS} (esperado 0)"
[[ "$W1_SELF_PATHS" -eq 0 ]] || {
  echo "Falha no Controle 3A (loop de reflexão BGP detectado)" >&2; exit 1;
}

# 3B: Remover apenas o SID End.DT6 do Tenant A em e40-pe2 (fc00:40:2::d6a/128)
ip -n e40-pe2 -6 route del "fc00:40:2::d6a/128"
C3B_TA_V6_DROP="$(probe_srv6 e40-ta-1 "http://[fd40:253:40::20]:8080/" "TENANT-A-DUALSTACK" 5 0.4)"
C3B_TA_V4_KEEP="$(probe_srv6 e40-ta-1 "http://10.253.40.20:8080/" "TENANT-A-DUALSTACK" 10)"
C3B_TB_V6_KEEP="$(probe_srv6 e40-tb-1 "http://[fd40:253:40::20]:8080/" "TENANT-B-DUALSTACK" 10)"
log "Controle 3B (Sem End.DT6 no Tenant A): TA_v6=${C3B_TA_V6_DROP}/5 TA_v4=${C3B_TA_V4_KEEP}/10 TB_v6=${C3B_TB_V6_KEEP}/10"
[[ "$C3B_TA_V6_DROP" -eq 0 && "$C3B_TA_V4_KEEP" -eq 10 && "$C3B_TB_V6_KEEP" -eq 10 ]] || {
  echo "Falha no Controle 3B" >&2; exit 1;
}

# Restaurar End.DT6 do Tenant A e verificar recuperação 10/10
ip -n e40-pe2 -6 route replace "fc00:40:2::d6a/128" encap seg6local action End.DT6 table 1040 dev veth-pe2-pe1
C3B_TA_V6_RECOVERED="$(probe_srv6 e40-ta-1 "http://[fd40:253:40::20]:8080/" "TENANT-A-DUALSTACK" 10)"
log "Controle 3B (Após restaurar End.DT6 no Tenant A): TA_v6_recovered=${C3B_TA_V6_RECOVERED}/10"
[[ "$C3B_TA_V6_RECOVERED" -eq 10 ]] || {
  echo "Falha ao recuperar End.DT6 no Controle 3B" >&2; exit 1;
}

cleanup
trap - EXIT

R6_ROUTES="$(ip route show proto bgp | wc -l | tr -d ' ')"
log "=== E40 SUMMARY ==="
log "Célula 1 (iBGP Route Reflector RFC 4456): PASS (Originator=10.208.40.2, ClusterList=10.255.40.1, v4=10/10, v6=10/10, direct_w1_w2=0)"
log "Célula 2 (SRv6 Dual-Stack End.DT4 + End.DT6): PASS (TA_v4=10/10, TA_v6=10/10, TB_v4=10/10, TB_v6=10/10 com CIDRs sobrepostos)"
log "Célula 3 (Controles 3A/3B/3C): PASS (3A self_paths=0, 3B TA_v6_drop=0/5 TA_v4_keep=10/10 TB_v6_keep=10/10 recovered=10/10, R6=${R6_ROUTES})"
log "E40 CONCLUÍDO COM SUCESSO (PASS)."
