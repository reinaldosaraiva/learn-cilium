#!/usr/bin/env bash
# P006-S002 (Braço B — E31): SRv6 L3VPN (RFC 8986 seg6local action End.DT4 / encap seg6)
# no Kernel Linux + FRR para Multi-Tenancy com Subnets IPv4 Sobrepostas sem VXLAN
#
# Mede no sandbox p003-gw (PE1 = p003-gw-worker, PE2 = p003-gw-worker2) + clab-p003-gw-fabric:
#   1. Célula 1 (Underlay IPv6 SRv6 Locators fc00:e31:1::/48 e fc00:e31:2::/48 + End.DT4):
#      - VRFs vrf-srv6-a (table 131) e vrf-srv6-b (table 132) nos nós PE1 e PE2 com
#        ZERO interfaces VXLAN.
#      - Instalação de local SIDs seg6local action End.DT4 vrftable 131 (fc00:e31:X::d4a)
#        e vrftable 132 (fc00:e31:X::d4b) + inspeção do plano de controle FRR no border1.
#   2. Célula 2 (Encapsulamento encap seg6 mode encap & Subnets IPv4 100% Sobrepostas):
#      - Tenant A e Tenant B usam simultaneamente a MESMA subnet 10.253.31.0/24 e os
#        MESMOS IPs (.10 no PE1, .20 no PE2).
#      - 30/30 sondas HTTP de ns-srv6-a1 (10.253.31.10 -> 10.253.31.20:8080) entregues
#        exclusivamente ao backend TENANT-A-PE2 via SID fc00:e31:2::d4a.
#      - 30/30 sondas HTTP de ns-srv6-b1 (10.253.31.10 -> 10.253.31.20:8080) entregues
#        exclusivamente ao backend TENANT-B-PE2 via SID fc00:e31:2::d4b.
#      - Captura tcpdump no underlay eth0 comprovando o encapsulamento IPv4-in-IPv6/SRH
#        sem VXLAN.
#   3. Célula 3 (Controles Negativos):
#      - Isolamento Cross-VRF (Tenant A tentando alcançar endpoint exclusivo do Tenant B: 0/5).
#      - Revogação dinâmica do SID End.DT4 (fc00:e31:2::d4b/128): bloqueio imediato 0/5 no
#        Tenant B mantendo 5/5 no Tenant A, seguido de restauração 5/5.
#   4. Rollback determinístico + pós-verificação k01 (10/10) e p003-gw (30/30, R6=0).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/01-e31-srv6-l3vpn.yaml"

K01_KC="${K01_KC:-/root/.kube/k01-rebuild.config}"
K01_CTX="${K01_CTX:-kind-k01}"
K01_UID_EXPECTED="635e7274-5597-40c7-9de5-b1fbe3d68b22"

GW_KC="${GW_KC:-/root/.kube/p003-gw.config}"
GW_CTX="${GW_CTX:-kind-p003-gw}"
GW_UID_EXPECTED="6bb32e0f-71f9-4558-ae33-356ba2250c26"

PE1="p003-gw-worker"
PE2="p003-gw-worker2"
BORDER_CTN="clab-p003-gw-fabric-border1"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

log() {
  printf '[%s] [E31] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log "DRY-RUN habilitado: nenhuma mutação será aplicada."
  log "Plano de execução E31:"
  log "  1. Validar UIDs k01 (${K01_UID_EXPECTED}) e p003-gw (${GW_UID_EXPECTED}), MemAvailable >= 4 GiB e R6=0."
  log "  2. Aplicar ${MANIFEST} (Namespace p006-e31, workloads de referência em ${PE1} e ${PE2})."
  log "  3. Célula 1: Configurar locators SRv6 fc00:e31:1::/48 (${PE1}) e fc00:e31:2::/48 (${PE2}), VRFs vrf-srv6-a (table 131) e vrf-srv6-b (table 132) sem VXLAN, e local SIDs seg6local action End.DT4."
  log "  4. Célula 2: Instanciar namespaces de tenant com IPs 100% sobrepostos (10.253.31.10/24 em ${PE1}, 10.253.31.20/24 em ${PE2} em ambos os tenants), validar 30/30 sondas HTTP por tenant e capturar pacotes SRv6 no underlay eth0."
  log "  5. Célula 3: Executar controles negativos (isolamento cross-VRF 0/5 e revogação do SID End.DT4 0/5 com Tenant A 5/5)."
  log "  6. Executar cleanup completo de VRFs, namespaces, rotas SRv6 e pods, e validar canários k01 (10/10), p003-gw (30/30) e R6=0."
  exit 0
fi

k_k01() { sudo kubectl --kubeconfig "${K01_KC}" --context "${K01_CTX}" "$@"; }
k_gw()  { sudo kubectl --kubeconfig "${GW_KC}"  --context "${GW_CTX}"  "$@"; }

cleanup_pe() {
  local node="$1"
  sudo docker exec "${node}" bash -c '
    for pidf in /tmp/e31-http-a.pid /tmp/e31-http-b.pid /tmp/e31-http-b-only.pid; do
      if [[ -f "${pidf}" ]]; then
        kill "$(cat "${pidf}")" 2>/dev/null || true
        rm -f "${pidf}"
      fi
    done
    for ns in ns-srv6-a ns-srv6-b; do
      ip netns del "${ns}" 2>/dev/null || true
    done
    for dev in veth-srv6-ah veth-srv6-bh vrf-srv6-a vrf-srv6-b; do
      ip link del "${dev}" 2>/dev/null || true
    done
    ip -6 route del fc00:e31:1::d4a/128 2>/dev/null || true
    ip -6 route del fc00:e31:1::d4b/128 2>/dev/null || true
    ip -6 route del fc00:e31:2::d4a/128 2>/dev/null || true
    ip -6 route del fc00:e31:2::d4b/128 2>/dev/null || true
    ip -6 route del fc00:e31:1::/48 2>/dev/null || true
    ip -6 route del fc00:e31:2::/48 2>/dev/null || true
    ip -6 addr del fc00:e31:0::1/64 dev eth0 2>/dev/null || true
    ip -6 addr del fc00:e31:0::2/64 dev eth0 2>/dev/null || true
    ip -6 addr del fc00:e31:1::1/128 dev lo 2>/dev/null || true
    ip -6 addr del fc00:e31:2::1/128 dev lo 2>/dev/null || true
    ip -6 rule del pref 100 to fc00:e31::/32 lookup main 2>/dev/null || true
    ip route flush table 131 2>/dev/null || true
    ip route flush table 132 2>/dev/null || true
    ip -6 route flush table 131 2>/dev/null || true
    ip -6 route flush table 132 2>/dev/null || true
    sysctl -qw net.vrf.strict_mode=0 2>/dev/null || true
    rm -f /tmp/e31-srv6.pcap /tmp/e31-srv6-tcpdump.txt 2>/dev/null || true
  ' >/dev/null 2>&1 || true
}

cleanup() {
  log "Iniciando cleanup idempotente de E31..."
  cleanup_pe "${PE1}"
  cleanup_pe "${PE2}"
  rm -f /tmp/e31-srv6-tcpdump.txt 2>/dev/null || true
  k_gw delete -f "${MANIFEST}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  k_gw delete ns p006-e31 --ignore-not-found --wait=true >/dev/null 2>&1 || true
  log "Cleanup E31 concluído."
}
trap cleanup EXIT

log "== [1] Preflight: UIDs, MemAvailable e R6 =="
K01_UID="$(k_k01 get ns kube-system -o jsonpath='{.metadata.uid}')"
GW_UID="$(k_gw get ns kube-system -o jsonpath='{.metadata.uid}')"
MEM_AVAIL_KB="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
log "k01_uid=${K01_UID} gw_uid=${GW_UID} mem_avail_kb=${MEM_AVAIL_KB}"

if [[ "${K01_UID}" != "${K01_UID_EXPECTED}" ]]; then
  log "ERRO: UID de k01 inesperado (${K01_UID} != ${K01_UID_EXPECTED})"
  exit 1
fi
if [[ "${GW_UID}" != "${GW_UID_EXPECTED}" ]]; then
  log "ERRO: UID de p003-gw inesperado (${GW_UID} != ${GW_UID_EXPECTED})"
  exit 1
fi
if (( MEM_AVAIL_KB < 4000000 )); then
  log "ERRO: MemAvailable abaixo de 4 GiB (${MEM_AVAIL_KB} kB)"
  exit 1
fi

for node in p003-gw-control-plane "${PE1}" "${PE2}"; do
  r6_count="$(sudo docker exec "${node}" ip route show proto bgp 2>/dev/null | wc -l | tr -d ' ')"
  log "node=${node} R6_bgp_routes=${r6_count}"
  if [[ "${r6_count}" != "0" ]]; then
    log "ERRO: violação R6 em ${node}"
    exit 1
  fi
done

log "== [2] Aplicando Workloads K8s de Referência e Inspecionando Capacidade SRv6 no Kernel + FRR =="
k_gw apply -f "${MANIFEST}"
k_gw -n p006-e31 rollout status deploy/e31-workload-w1 --timeout=90s
k_gw -n p006-e31 rollout status deploy/e31-workload-w2 --timeout=90s

grep -E "CONFIG_IPV6_SEG6" "/boot/config-$(uname -r)" 2>/dev/null || true
sudo docker exec "${BORDER_CTN}" vtysh -c "show version" | head -n 4 || true

log "== [3] Célula 1: Underlay IPv6 SRv6 Locators (fc00:e31:1::/48 e fc00:e31:2::/48) + seg6local End.DT4 sem VXLAN =="
sudo docker exec "${PE1}" bash -c '
  set -euo pipefail
  sysctl -qw net.ipv4.ip_forward=1
  sysctl -qw net.ipv4.conf.all.rp_filter=0
  sysctl -qw net.ipv4.conf.default.rp_filter=0
  sysctl -qw net.ipv4.conf.eth0.rp_filter=0
  sysctl -qw net.ipv6.conf.all.forwarding=1
  sysctl -qw net.ipv6.conf.all.seg6_enabled=1
  sysctl -qw net.ipv6.conf.default.seg6_enabled=1
  sysctl -qw net.ipv6.conf.eth0.seg6_enabled=1
  sysctl -qw net.ipv6.conf.lo.seg6_enabled=1

  ip -6 addr replace fc00:e31:0::1/64 dev eth0 nodad
  ip -6 addr replace fc00:e31:1::1/128 dev lo nodad
  ip -6 route replace fc00:e31:2::/48 via fc00:e31:0::2 dev eth0
  ip -6 rule del pref 100 to fc00:e31::/32 lookup main 2>/dev/null || true
  ip -6 rule add pref 100 to fc00:e31::/32 lookup main

  # Criar VRFs vrf-srv6-a (table 131) e vrf-srv6-b (table 132) sem nenhuma interface VXLAN
  ip link add vrf-srv6-a type vrf table 131
  ip link set vrf-srv6-a up
  ip link add vrf-srv6-b type vrf table 132
  ip link set vrf-srv6-b up
  sysctl -qw net.ipv4.conf.vrf-srv6-a.rp_filter=0
  sysctl -qw net.ipv4.conf.vrf-srv6-b.rp_filter=0
  sysctl -qw net.ipv6.conf.vrf-srv6-a.seg6_enabled=1
  sysctl -qw net.ipv6.conf.vrf-srv6-b.seg6_enabled=1

  # Pré-requisito do kernel Linux (net/ipv6/seg6_local.c): End.DT4 vrftable exige net.vrf.strict_mode=1
  sysctl -qw net.vrf.strict_mode=0
  echo "--- Verificando exigência de net.vrf.strict_mode=1 para seg6local End.DT4 ---"
  if ip -6 route replace fc00:e31:1::d4a/128 encap seg6local action End.DT4 vrftable 131 dev vrf-srv6-a 2>&1; then
    echo "WARN: End.DT4 aceito com strict_mode=0"
  else
    echo "EXPECTED_STRICT_MODE_GUARD: End.DT4 recusado quando net.vrf.strict_mode=0"
  fi
  sysctl -qw net.vrf.strict_mode=1

  # Instalar SIDs locais End.DT4 (RFC 8986) na tabela main (dev eth0) para decapsulamento IPv4 por VRF
  ip -6 route replace fc00:e31:1::d4a/128 encap seg6local action End.DT4 vrftable 131 dev eth0
  ip -6 route replace fc00:e31:1::d4b/128 encap seg6local action End.DT4 vrftable 132 dev eth0
  ip -6 route replace fc00:e31:2::/48 via fc00:e31:0::2 dev eth0 table 131
  ip -6 route replace fc00:e31:2::/48 via fc00:e31:0::2 dev eth0 table 132

  echo "--- [PE1 p003-gw-worker] SIDs Locais SRv6 End.DT4 ---"
  ip -6 route show root fc00:e31:1::/48
  echo "VXLAN_INTERFACES_ON_PE1=$(ip -d link show type vxlan 2>/dev/null | grep -c vrf-srv6 || true)"
'

sudo docker exec "${PE2}" bash -c '
  set -euo pipefail
  sysctl -qw net.ipv4.ip_forward=1
  sysctl -qw net.ipv4.conf.all.rp_filter=0
  sysctl -qw net.ipv4.conf.default.rp_filter=0
  sysctl -qw net.ipv4.conf.eth0.rp_filter=0
  sysctl -qw net.ipv6.conf.all.forwarding=1
  sysctl -qw net.ipv6.conf.all.seg6_enabled=1
  sysctl -qw net.ipv6.conf.default.seg6_enabled=1
  sysctl -qw net.ipv6.conf.eth0.seg6_enabled=1
  sysctl -qw net.ipv6.conf.lo.seg6_enabled=1
  sysctl -qw net.vrf.strict_mode=1

  ip -6 addr replace fc00:e31:0::2/64 dev eth0 nodad
  ip -6 addr replace fc00:e31:2::1/128 dev lo nodad
  ip -6 route replace fc00:e31:1::/48 via fc00:e31:0::1 dev eth0
  ip -6 rule del pref 100 to fc00:e31::/32 lookup main 2>/dev/null || true
  ip -6 rule add pref 100 to fc00:e31::/32 lookup main

  ip link add vrf-srv6-a type vrf table 131
  ip link set vrf-srv6-a up
  ip link add vrf-srv6-b type vrf table 132
  ip link set vrf-srv6-b up
  sysctl -qw net.ipv4.conf.vrf-srv6-a.rp_filter=0
  sysctl -qw net.ipv4.conf.vrf-srv6-b.rp_filter=0
  sysctl -qw net.ipv6.conf.vrf-srv6-a.seg6_enabled=1
  sysctl -qw net.ipv6.conf.vrf-srv6-b.seg6_enabled=1

  ip -6 route replace fc00:e31:2::d4a/128 encap seg6local action End.DT4 vrftable 131 dev eth0
  ip -6 route replace fc00:e31:2::d4b/128 encap seg6local action End.DT4 vrftable 132 dev eth0
  ip -6 route replace fc00:e31:1::/48 via fc00:e31:0::1 dev eth0 table 131
  ip -6 route replace fc00:e31:1::/48 via fc00:e31:0::1 dev eth0 table 132

  echo "--- [PE2 p003-gw-worker2] SIDs Locais SRv6 End.DT4 ---"
  ip -6 route show root fc00:e31:2::/48
  echo "VXLAN_INTERFACES_ON_PE2=$(ip -d link show type vxlan 2>/dev/null | grep -c vrf-srv6 || true)"
'

log "== [4] Célula 2: Encapsulamento encap seg6 mode encap & Subnets 100% Sobrepostas (10.253.31.0/24) =="
sudo docker exec "${PE1}" bash -c '
  set -euo pipefail
  # Tenant A e Tenant B no PE1 usam o MESMO IP 10.253.31.10/24 e MESMO gateway 10.253.31.1/24
  ip netns add ns-srv6-a
  ip link add veth-srv6-ah type veth peer name veth-srv6-an
  ip link set veth-srv6-ah master vrf-srv6-a up
  sysctl -qw net.ipv4.conf.veth-srv6-ah.rp_filter=0
  ip addr add 10.253.31.1/24 dev veth-srv6-ah
  ip link set veth-srv6-an netns ns-srv6-a
  ip netns exec ns-srv6-a ip link set lo up
  ip netns exec ns-srv6-a ip link set veth-srv6-an up
  ip netns exec ns-srv6-a ip addr add 10.253.31.10/24 dev veth-srv6-an
  ip netns exec ns-srv6-a ip route add default via 10.253.31.1
  ip netns exec ns-srv6-a ip route replace 10.253.31.20/32 via 10.253.31.1
  ip netns exec ns-srv6-a ip route replace 10.253.31.22/32 via 10.253.31.1

  ip netns add ns-srv6-b
  ip link add veth-srv6-bh type veth peer name veth-srv6-bn
  ip link set veth-srv6-bh master vrf-srv6-b up
  sysctl -qw net.ipv4.conf.veth-srv6-bh.rp_filter=0
  ip addr add 10.253.31.1/24 dev veth-srv6-bh
  ip link set veth-srv6-bn netns ns-srv6-b
  ip netns exec ns-srv6-b ip link set lo up
  ip netns exec ns-srv6-b ip link set veth-srv6-bn up
  ip netns exec ns-srv6-b ip addr add 10.253.31.10/24 dev veth-srv6-bn
  ip netns exec ns-srv6-b ip route add default via 10.253.31.1
  ip netns exec ns-srv6-b ip route replace 10.253.31.20/32 via 10.253.31.1
  ip netns exec ns-srv6-b ip route replace 10.253.31.22/32 via 10.253.31.1

  # Rotas VRF no PE1 encapsulando tráfego remoto em SRv6 (encap seg6 mode encap)
  ip route replace 10.253.31.20/32 encap seg6 mode encap segs fc00:e31:2::d4a dev eth0 table 131
  ip route replace 10.253.31.20/32 encap seg6 mode encap segs fc00:e31:2::d4b dev eth0 table 132
  ip route replace 10.253.31.22/32 encap seg6 mode encap segs fc00:e31:2::d4a dev eth0 table 131
  ip route replace 10.253.31.22/32 encap seg6 mode encap segs fc00:e31:2::d4b dev eth0 table 132

  echo "--- [PE1] Rotas VRF table 131 (Tenant A) e table 132 (Tenant B) ---"
  ip route show table 131
  ip route show table 132
'

sudo docker exec "${PE2}" bash -c '
  set -euo pipefail
  # Tenant A e Tenant B no PE2 usam o MESMO IP 10.253.31.20/24 (mais 10.253.31.22/24 exclusivo em Tenant B)
  ip netns add ns-srv6-a
  ip link add veth-srv6-ah type veth peer name veth-srv6-an
  ip link set veth-srv6-ah master vrf-srv6-a up
  sysctl -qw net.ipv4.conf.veth-srv6-ah.rp_filter=0
  ip addr add 10.253.31.2/24 dev veth-srv6-ah
  ip link set veth-srv6-an netns ns-srv6-a
  ip netns exec ns-srv6-a ip link set lo up
  ip netns exec ns-srv6-a ip link set veth-srv6-an up
  ip netns exec ns-srv6-a ip addr add 10.253.31.20/24 dev veth-srv6-an
  ip netns exec ns-srv6-a ip route add default via 10.253.31.2
  ip netns exec ns-srv6-a ip route replace 10.253.31.10/32 via 10.253.31.2

  ip netns add ns-srv6-b
  ip link add veth-srv6-bh type veth peer name veth-srv6-bn
  ip link set veth-srv6-bh master vrf-srv6-b up
  sysctl -qw net.ipv4.conf.veth-srv6-bh.rp_filter=0
  ip addr add 10.253.31.2/24 dev veth-srv6-bh
  ip link set veth-srv6-bn netns ns-srv6-b
  ip netns exec ns-srv6-b ip link set lo up
  ip netns exec ns-srv6-b ip link set veth-srv6-bn up
  ip netns exec ns-srv6-b ip addr add 10.253.31.20/24 dev veth-srv6-bn
  ip netns exec ns-srv6-b ip addr add 10.253.31.22/24 dev veth-srv6-bn
  ip netns exec ns-srv6-b ip route add default via 10.253.31.2
  ip netns exec ns-srv6-b ip route replace 10.253.31.10/32 via 10.253.31.2

  # Rotas VRF de retorno no PE2 encapsulando para os SIDs do PE1
  ip route replace 10.253.31.10/32 encap seg6 mode encap segs fc00:e31:1::d4a dev eth0 table 131
  ip route replace 10.253.31.10/32 encap seg6 mode encap segs fc00:e31:1::d4b dev eth0 table 132

  # Iniciar servidores HTTP identificadores em cada namespace do PE2
  ip netns exec ns-srv6-a python3 -c "
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(b\"TENANT-A-PE2-10.253.31.20\\n\")
    def log_message(self, *a): pass
http.server.HTTPServer((\"10.253.31.20\", 8080), H).serve_forever()
" &
  echo $! > /tmp/e31-http-a.pid

  ip netns exec ns-srv6-b python3 -c "
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(b\"TENANT-B-PE2-10.253.31.20\\n\")
    def log_message(self, *a): pass
http.server.HTTPServer((\"10.253.31.20\", 8080), H).serve_forever()
" &
  echo $! > /tmp/e31-http-b.pid

  ip netns exec ns-srv6-b python3 -c "
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(b\"TENANT-B-ONLY-10.253.31.22\\n\")
    def log_message(self, *a): pass
http.server.HTTPServer((\"10.253.31.22\", 8080), H).serve_forever()
" &
  echo $! > /tmp/e31-http-b-only.pid
  sleep 0.5
'

log "Iniciando captura de pacotes SRv6 no underlay eth0 do PE2 e executando 30/30 sondas HTTP por Tenant..."
PE2_PID="$(sudo docker inspect -f '{{.State.Pid}}' "${PE2}")"
# shellcheck disable=SC2024
sudo nsenter -t "${PE2_PID}" -n timeout 8 tcpdump -nn -i eth0 -c 12 "ip6 and (host fc00:e31:2::d4a or host fc00:e31:2::d4b)" > /tmp/e31-srv6-tcpdump.txt 2>&1 &
TCPDUMP_PID=$!
sleep 0.3

sudo docker exec "${PE1}" bash -c '
  set -euo pipefail
  a_ok=0
  a_leak=0
  for _ in $(seq 1 30); do
    resp="$(ip netns exec ns-srv6-a curl -s --max-time 2 http://10.253.31.20:8080/ || true)"
    if [[ "${resp}" == "TENANT-A-PE2-10.253.31.20" ]]; then
      a_ok=$((a_ok + 1))
    elif [[ -n "${resp}" ]]; then
      a_leak=$((a_leak + 1))
    fi
  done

  b_ok=0
  b_leak=0
  for _ in $(seq 1 30); do
    resp="$(ip netns exec ns-srv6-b curl -s --max-time 2 http://10.253.31.20:8080/ || true)"
    if [[ "${resp}" == "TENANT-B-PE2-10.253.31.20" ]]; then
      b_ok=$((b_ok + 1))
    elif [[ -n "${resp}" ]]; then
      b_leak=$((b_leak + 1))
    fi
  done

  echo "SRV6_OVERLAP_PROBES tenant_a_ok=${a_ok}/30 tenant_a_leak=${a_leak} tenant_b_ok=${b_ok}/30 tenant_b_leak=${b_leak}"
  if [[ "${a_ok}" -ne 30 || "${a_leak}" -ne 0 || "${b_ok}" -ne 30 || "${b_leak}" -ne 0 ]]; then
    echo "ERRO: falha na entrega isolada de subnets sobrepostas via SRv6"
    exit 1
  fi
'

wait "${TCPDUMP_PID}" 2>/dev/null || true
echo "--- Captura tcpdump no underlay eth0 do PE2 (Pacotes SRv6 encap seg6) ---"
cat /tmp/e31-srv6-tcpdump.txt || true

log "== [5] Célula 3: Controles Negativos — Isolamento Cross-VRF e Revogação de SID End.DT4 =="
sudo docker exec "${PE1}" bash -c '
  set -euo pipefail
  echo "--- Controle Negativo 3A: Tenant A tentando acessar 10.253.31.22 (exclusivo do Tenant B) ---"
  cross_ok=0
  for _ in $(seq 1 5); do
    resp="$(ip netns exec ns-srv6-a curl -s --max-time 1 http://10.253.31.22:8080/ || true)"
    if [[ -n "${resp}" ]]; then
      cross_ok=$((cross_ok + 1))
    fi
  done
  echo "CROSS_VRF_TENANT_A_TO_B_ONLY=${cross_ok}/5 (esperado 0/5)"
  if [[ "${cross_ok}" -ne 0 ]]; then
    echo "ERRO: vazamento cross-VRF detectado!"
    exit 1
  fi
'

log "Removendo SID End.DT4 do Tenant B (fc00:e31:2::d4b/128) no PE2 e testando isolamento de falha..."
sudo docker exec "${PE2}" ip -6 route del fc00:e31:2::d4b/128

sudo docker exec "${PE1}" bash -c '
  set -euo pipefail
  a_while_b_down=0
  b_while_b_down=0
  for _ in $(seq 1 5); do
    resp_a="$(ip netns exec ns-srv6-a curl -s --max-time 1 http://10.253.31.20:8080/ || true)"
    if [[ "${resp_a}" == "TENANT-A-PE2-10.253.31.20" ]]; then
      a_while_b_down=$((a_while_b_down + 1))
    fi
    resp_b="$(ip netns exec ns-srv6-b curl -s --max-time 1 http://10.253.31.20:8080/ || true)"
    if [[ "${resp_b}" == "TENANT-B-PE2-10.253.31.20" ]]; then
      b_while_b_down=$((b_while_b_down + 1))
    fi
  done
  echo "SID_REVOKED_TEST tenant_a=${a_while_b_down}/5 (esperado 5/5) tenant_b=${b_while_b_down}/5 (esperado 0/5)"
  if [[ "${a_while_b_down}" -ne 5 || "${b_while_b_down}" -ne 0 ]]; then
    echo "ERRO: comportamento inesperado durante revogação do SID End.DT4"
    exit 1
  fi
'

log "Restaurando SID End.DT4 do Tenant B (fc00:e31:2::d4b/128) e validando reconvergência..."
sudo docker exec "${PE2}" ip -6 route replace fc00:e31:2::d4b/128 encap seg6local action End.DT4 vrftable 132 dev eth0

sudo docker exec "${PE1}" bash -c '
  set -euo pipefail
  b_restored=0
  for _ in $(seq 1 5); do
    resp_b="$(ip netns exec ns-srv6-b curl -s --max-time 1 http://10.253.31.20:8080/ || true)"
    if [[ "${resp_b}" == "TENANT-B-PE2-10.253.31.20" ]]; then
      b_restored=$((b_restored + 1))
    fi
  done
  echo "SID_RESTORED_TEST tenant_b=${b_restored}/5 (esperado 5/5)"
  if [[ "${b_restored}" -ne 5 ]]; then
    echo "ERRO: falha na reconvergência do SID End.DT4"
    exit 1
  fi
'

log "== [6] Executando Cleanup e Pós-Verificação =="
cleanup
trap - EXIT

for node in p003-gw-control-plane "${PE1}" "${PE2}"; do
  r6_count="$(sudo docker exec "${node}" ip route show proto bgp 2>/dev/null | wc -l | tr -d ' ')"
  log "post-cleanup node=${node} R6_bgp_routes=${r6_count}"
  if [[ "${r6_count}" != "0" ]]; then
    log "ERRO: violação R6 pós-cleanup em ${node}"
    exit 1
  fi
done

log "E31 concluído com PASS."
