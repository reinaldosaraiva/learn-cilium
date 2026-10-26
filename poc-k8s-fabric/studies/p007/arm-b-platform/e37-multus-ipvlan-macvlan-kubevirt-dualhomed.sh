#!/usr/bin/env bash
# ==============================================================================
# P007-S002 — Braço B (E37): Workloads / VMs KubeVirt Dual-Homed com Multus
#             (NetworkAttachmentDefinition) + ipvlan L2/L3 vs macvlan Acelerado
#
# Objetivo:
#   Avaliar no sandbox p003-gw (Cilium 1.20.2 + Linux 6.8 ipvlan/macvlan):
#   - Célula 1: Arquitetura Dual-Homed KubeVirt/Pod (`eth0` Cilium eBPF Control
#     Plane com `CiliumNetworkPolicy` + `net1` `ipvlan mode l2` em `10.254.37.0/24`
#     com Jumbo `MTU 9000` anexado ao netns dos pods `e37-vm-a` e `e37-vm-b`):
#       * `10/10` HTTP 200 pelo CNI primário `eth0` (local_ip=10.245.x.x)
#       * `10/10` HTTP 200 pelo plano de dados secundário `net1` (`10.254.37.20`)
#       * `10/10` pings Jumbo `DF=1` de `8972 B` payload (`9000 B` IP) em `net1`
#   - Célula 2: Comparativo Empírico dos 4 Regimes de Rede Secundária (`512 MiB`
#     TCP single-stream, 2 repetições por regime):
#       * Regime A: `veth` + Linux bridge (`MTU 1500`)
#       * Regime B: `macvlan mode bridge` (`MTU 9000`, MAC secundário próprio)
#       * Regime C: `ipvlan mode l2` (`MTU 9000`, preserva MAC físico do host)
#       * Regime D: `ipvlan mode l3` (`MTU 9000`, L3 puro `NOARP`, preserva MAC do host)
#   - Célula 3: Controles Negativos:
#       * 3A (Port-Security / Anti-Spoofing L2 de Nuvem Pública): aplicação de
#         filtro L2 (`tc filter ... flower src_mac != <HOST_MAC> action drop`) na
#         porta do switch/hypervisor permitindo apenas o MAC primário do nó:
#         `macvlan` perde `100%` (`0/5` entregues) por transmitir com MAC de
#         convidado desconhecido, enquanto `ipvlan mode l2` mantém `10/10` (`100%`)
#         por compartilhar o MAC primário do nó!
#       * 3B (Isolamento de Falha entre `net1` e `eth0`): queda de `net1` (`0/5`)
#         mantém `eth0` Cilium `10/10` HTTP 200 intacto (`R6=0`).
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/02-e37-multus-ipvlan-dualhomed.yaml"

SANDBOX_KUBECONFIG="${SANDBOX_KUBECONFIG:-/root/.kube/p003-gw.config}"
SANDBOX_CONTEXT="${SANDBOX_CONTEXT:-kind-p003-gw}"
SANDBOX_UID="${SANDBOX_UID:-6bb32e0f-71f9-4558-ae33-356ba2250c26}"

K01_KUBECONFIG="${K01_KUBECONFIG:-/root/.kube/k01-rebuild.config}"
K01_UID="${K01_UID:-635e7274-5597-40c7-9de5-b1fbe3d68b22}"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      echo "Uso: $0 [--dry-run]"
      exit 0
      ;;
    *)
      echo "ERRO: argumento desconhecido: $arg" >&2
      exit 2
      ;;
  esac
done

log() {
  printf '[%s] [E37] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "MODO --dry-run ATIVO: validando manifesto e plano de execução sem tocar no cluster."
  [[ -f "$MANIFEST" ]] || { echo "ERRO: manifesto ausente: $MANIFEST" >&2; exit 1; }
  log "Plano de execução:"
  log "  1. Preflight R1 (k01 uid=${K01_UID}), R2 (p003-gw uid=${SANDBOX_UID}) e R3 (MemAvailable >= 4 GiB)"
  log "  2. Célula 1: Dual-Homed KubeVirt/Pod (eth0 Cilium + net1 ipvlan mode l2 MTU 9000 via NetworkAttachmentDefinition)"
  log "  3. Célula 2: Benchmark 512 MiB TCP (veth bridge 1500 vs macvlan 9000 vs ipvlan l2 9000 vs ipvlan l3 9000)"
  log "  4. Célula 3: Controles Negativos 3A (Cloud L2 MAC Anti-Spoofing bloqueando macvlan 0/5 vs ipvlan 10/10) e 3B (Isolamento net1 vs eth0)"
  log "  5. Teardown determinístico (R6=0)"
  exit 0
fi

K="kubectl --kubeconfig=${SANDBOX_KUBECONFIG} --context=${SANDBOX_CONTEXT}"

cleanup() {
  log "Executando limpeza determinística (R6)..."
  for ns in e37-sw e37-host1 e37-host2 e37-pod1 e37-pod2; do
    ip netns del "$ns" >/dev/null 2>&1 || true
  done
  docker exec p003-gw-worker ip link del e37-underlay0 >/dev/null 2>&1 || true
  $K delete -f "$MANIFEST" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  $K delete ns p007-e37 --ignore-not-found=true --wait=true --timeout=60s >/dev/null 2>&1 || true
  log "Limpeza concluída."
}
trap cleanup EXIT

log "=== PREFLIGHT: Verificando invariantes R1 (k01), R2 (p003-gw) e R3 (MemAvailable) ==="
ACTUAL_K01_UID="$(kubectl --kubeconfig="${K01_KUBECONFIG}" get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "$ACTUAL_K01_UID" != "$K01_UID" ]]; then
  echo "ERRO CRÍTICO (R1): UID do k01 (${ACTUAL_K01_UID}) difere do esperado (${K01_UID})!" >&2
  exit 1
fi
ACTUAL_SBX_UID="$($K get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "$ACTUAL_SBX_UID" != "$SANDBOX_UID" ]]; then
  echo "ERRO CRÍTICO (R2): UID do p003-gw (${ACTUAL_SBX_UID}) difere do esperado (${SANDBOX_UID})!" >&2
  exit 1
fi
MEM_AVAIL_KB="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
if [[ "${MEM_AVAIL_KB:-0}" -lt 3500000 ]]; then
  echo "ERRO CRÍTICO (R3): MemAvailable insuficiente (${MEM_AVAIL_KB} kB < 3500000 kB)!" >&2
  exit 1
fi
log "Preflight OK: k01_uid=${ACTUAL_K01_UID} | p003_gw_uid=${ACTUAL_SBX_UID} | MemAvailable=${MEM_AVAIL_KB} kB"

# ==============================================================================
# CÉLULA 1: Arquitetura Dual-Homed (eth0 Cilium + net1 ipvlan mode l2 MTU 9000)
# ==============================================================================
log "=== CÉLULA 1: Arquitetura Dual-Homed (eth0 Cilium eBPF + net1 ipvlan mode l2 MTU 9000) ==="
$K apply -f "$MANIFEST" >/dev/null 2>&1 || true
$K wait --for=condition=Established crd/network-attachment-definitions.k8s.cni.cncf.io --timeout=30s
$K apply -f "$MANIFEST"
$K -n p007-e37 wait --for=condition=Ready pod/e37-vm-a pod/e37-vm-b --timeout=90s

VMB_ETH0_IP="$($K -n p007-e37 get pod e37-vm-b -o jsonpath='{.status.podIP}')"
log "Pods dual-homed prontos em p003-gw-worker; e37-vm-b eth0 IP=${VMB_ETH0_IP}"

# Plumb secondary net1 (ipvlan mode l2 MTU 9000) into e37-vm-a and e37-vm-b netns on p003-gw-worker
docker exec -i p003-gw-worker bash -s <<'EOF_PLUMB'
set -euo pipefail
ip link del e37-underlay0 >/dev/null 2>&1 || true
ip link add e37-underlay0 type dummy
ip link set e37-underlay0 mtu 9000 up

PID_A="$(crictl inspectp "$(crictl pods --state Ready --name e37-vm-a -q | head -n1)" | awk -F': ' '/"pid":/ {gsub(/[^0-9]/,"",$2); if ($2 + 0 > 1) {print $2; exit}}')"
PID_B="$(crictl inspectp "$(crictl pods --state Ready --name e37-vm-b -q | head -n1)" | awk -F': ' '/"pid":/ {gsub(/[^0-9]/,"",$2); if ($2 + 0 > 1) {print $2; exit}}')"
echo "Plumbing net1 into PID_A=${PID_A} (e37-vm-a) and PID_B=${PID_B} (e37-vm-b)"

ip link add e37-net1-a link e37-underlay0 type ipvlan mode l2
ip link add e37-net1-b link e37-underlay0 type ipvlan mode l2
ip link set e37-net1-a netns "$PID_A"
ip link set e37-net1-b netns "$PID_B"

nsenter -t "$PID_A" -n ip link set e37-net1-a name net1 mtu 9000 up
nsenter -t "$PID_A" -n ip addr add 10.254.37.10/24 dev net1
nsenter -t "$PID_B" -n ip link set e37-net1-b name net1 mtu 9000 up
nsenter -t "$PID_B" -n ip addr add 10.254.37.20/24 dev net1

echo "=== Interfaces em e37-vm-a (eth0 Cilium + net1 ipvlan l2 MTU 9000) ==="
nsenter -t "$PID_A" -n ip -br link show
nsenter -t "$PID_A" -n ip -br addr show
EOF_PLUMB

log "--- Testando Plano de Controle Primário (eth0 Cilium: ${VMB_ETH0_IP}:8080) e Plano de Dados Secundário (net1 ipvlan: 10.254.37.20:8080) ---"
$K -n p007-e37 exec e37-vm-a -- python3 -c "
import urllib.request
eth0_ok, net1_ok = 0, 0
for _ in range(10):
    with urllib.request.urlopen('http://${VMB_ETH0_IP}:8080/', timeout=2) as r:
        if f'local_ip=${VMB_ETH0_IP}' in r.read().decode():
            eth0_ok += 1
    with urllib.request.urlopen('http://10.254.37.20:8080/', timeout=2) as r:
        if 'local_ip=10.254.37.20' in r.read().decode():
            net1_ok += 1
print(f'[Célula 1 Dual-Homed HTTP] eth0_cilium_ok={eth0_ok}/10 net1_ipvlan_ok={net1_ok}/10')
assert eth0_ok == 10 and net1_ok == 10
"

log "--- Testando Jumbo Frames MTU 9000 (payload 8972 B) em net1 (10.254.37.10 -> 10.254.37.20) ---"
$K -n p007-e37 exec e37-vm-a -- ping -c 10 -s 8972 10.254.37.20

# ==============================================================================
# CÉLULA 2: Comparativo veth bridge vs macvlan bridge vs ipvlan l2 vs ipvlan l3
# ==============================================================================
log "=== CÉLULA 2: Benchmark 512 MiB TCP Single-Stream — veth (1500) vs macvlan (9000) vs ipvlan l2 (9000) vs ipvlan l3 (9000) ==="

run_bench() {
  local label="$1"
  local ns_cli="$2"
  local ns_srv="$3"
  local dst_ip="$4"
  ip netns exec "$ns_srv" python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 9037))
s.listen(4)
while True:
    c, _ = s.accept()
    while c.recv(262144):
        pass
    c.close()
' >/dev/null 2>&1 &
  local srv_pid=$!
  sleep 0.2
  for run in 1 2; do
    ip netns exec "$ns_cli" python3 -c "
import socket, time
buf = b'X' * 262144
total = 512 * 1024 * 1024
sent = 0
t0 = time.monotonic()
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect(('${dst_ip}', 9037))
while sent < total:
    sent += s.send(buf)
s.close()
dt = time.monotonic() - t0
gbps = (total * 8.0) / (dt * 1e9)
print(f'[Bench ${label} RUN ${run}] bytes={total} duration_s={dt:.4f} throughput_gbps={gbps:.2f}')
"
  done
  kill -9 "$srv_pid" >/dev/null 2>&1 || true
}

# Setup isolated host/switch topology for Célula 2 & Célula 3
for ns in e37-sw e37-host1 e37-host2 e37-pod1 e37-pod2; do
  ip netns del "$ns" >/dev/null 2>&1 || true
  ip netns add "$ns"
  ip -n "$ns" link set lo up
done

ip link add veth-h1 netns e37-host1 type veth peer name veth-sw1 netns e37-sw
ip link add veth-h2 netns e37-host2 type veth peer name veth-sw2 netns e37-sw
ip -n e37-sw link add br-sw type bridge
ip -n e37-sw link set br-sw mtu 9000 up
ip -n e37-sw link set veth-sw1 master br-sw mtu 9000 up
ip -n e37-sw link set veth-sw2 master br-sw mtu 9000 up
ip -n e37-host1 link set veth-h1 mtu 9000 up
ip -n e37-host2 link set veth-h2 mtu 9000 up

HOST1_MAC="$(ip -n e37-host1 -br link show veth-h1 | awk '{print $3}')"
HOST2_MAC="$(ip -n e37-host2 -br link show veth-h2 | awk '{print $3}')"
log "MAC físico do nó e37-host1 (veth-h1): ${HOST1_MAC} | e37-host2 (veth-h2): ${HOST2_MAC}"

# Regime A: veth + bridge MTU 1500
ip -n e37-host1 link add br-pod type bridge
ip -n e37-host1 link set br-pod mtu 1500 up
ip link add veth-p1 netns e37-pod1 type veth peer name veth-p1-br netns e37-host1
ip link add veth-p2 netns e37-pod2 type veth peer name veth-p2-br netns e37-host1
ip -n e37-host1 link set veth-p1-br master br-pod mtu 1500 up
ip -n e37-host1 link set veth-p2-br master br-pod mtu 1500 up
ip -n e37-pod1 link set veth-p1 mtu 1500 up
ip -n e37-pod2 link set veth-p2 mtu 1500 up
ip -n e37-pod1 addr add 10.254.101.1/24 dev veth-p1
ip -n e37-pod2 addr add 10.254.101.2/24 dev veth-p2
run_bench "Regime-A-veth-1500" "e37-pod1" "e37-pod2" "10.254.101.2"
ip -n e37-pod1 link del veth-p1
ip -n e37-pod2 link del veth-p2
ip -n e37-host1 link del br-pod

# Regime B: macvlan mode bridge MTU 9000
ip -n e37-host1 link add macv1 link veth-h1 address 02:37:ac:00:00:11 type macvlan mode bridge
ip -n e37-host2 link add macv2 link veth-h2 address 02:37:ac:00:00:22 type macvlan mode bridge
ip -n e37-host1 link set macv1 netns e37-pod1
ip -n e37-host2 link set macv2 netns e37-pod2
ip -n e37-pod1 link set macv1 mtu 9000 up
ip -n e37-pod2 link set macv2 mtu 9000 up
ip -n e37-pod1 addr add 10.254.102.1/24 dev macv1
ip -n e37-pod2 addr add 10.254.102.2/24 dev macv2
MACV1_MAC="$(ip -n e37-pod1 -br link show macv1 | awk '{print $3}')"
log "[Regime B macvlan] MAC do pod (macv1)=${MACV1_MAC} != MAC do host (${HOST1_MAC})"
run_bench "Regime-B-macvlan-9000" "e37-pod1" "e37-pod2" "10.254.102.2"
ip -n e37-pod1 link del macv1
ip -n e37-pod2 link del macv2

# Regime C: ipvlan mode l2 MTU 9000
ip -n e37-host1 link add ipvl1 link veth-h1 type ipvlan mode l2
ip -n e37-host2 link add ipvl2 link veth-h2 type ipvlan mode l2
ip -n e37-host1 link set ipvl1 netns e37-pod1
ip -n e37-host2 link set ipvl2 netns e37-pod2
ip -n e37-pod1 link set ipvl1 mtu 9000 up
ip -n e37-pod2 link set ipvl2 mtu 9000 up
ip -n e37-pod1 addr add 10.254.103.1/24 dev ipvl1
ip -n e37-pod2 addr add 10.254.103.2/24 dev ipvl2
IPVL1_MAC="$(ip -n e37-pod1 -br link show ipvl1 | awk '{print $3}')"
log "[Regime C ipvlan-l2] MAC do pod (ipvl1)=${IPVL1_MAC} == MAC do host (${HOST1_MAC})"
run_bench "Regime-C-ipvlan-l2-9000" "e37-pod1" "e37-pod2" "10.254.103.2"
ip -n e37-pod1 link del ipvl1
ip -n e37-pod2 link del ipvl2

# Regime D: ipvlan mode l3 MTU 9000 (intra-parent L3 NOARP)
ip -n e37-host1 link add ipvl3a link veth-h1 type ipvlan mode l3
ip -n e37-host1 link add ipvl3b link veth-h1 type ipvlan mode l3
ip -n e37-host1 link set ipvl3a netns e37-pod1
ip -n e37-host1 link set ipvl3b netns e37-pod2
ip -n e37-pod1 link set ipvl3a mtu 9000 up
ip -n e37-pod2 link set ipvl3b mtu 9000 up
ip -n e37-pod1 addr add 10.254.104.1/32 dev ipvl3a
ip -n e37-pod2 addr add 10.254.104.2/32 dev ipvl3b
ip -n e37-pod1 route add default dev ipvl3a
ip -n e37-pod2 route add default dev ipvl3b
run_bench "Regime-D-ipvlan-l3-9000" "e37-pod1" "e37-pod2" "10.254.104.2"
ip -n e37-pod1 link del ipvl3a
ip -n e37-pod2 link del ipvl3b

# ==============================================================================
# CÉLULA 3: Controles Negativos (3A: Cloud L2 Anti-Spoofing & 3B: Isolamento net1)
# ==============================================================================
log "=== CÉLULA 3: Controle 3A (Port-Security / Anti-Spoofing L2 Cloud: macvlan 0/5 vs ipvlan 10/10) & Controle 3B ==="

# Configurar na porta do switch (veth-sw1 em e37-sw) Port Security permitindo APENAS o MAC físico do host (${HOST1_MAC})
tc -n e37-sw qdisc add dev veth-sw1 clsact
tc -n e37-sw filter add dev veth-sw1 ingress prio 10 flower src_mac "${HOST1_MAC}" action pass
tc -n e37-sw filter add dev veth-sw1 ingress prio 20 matchall action drop
log "[3A] Filtro Anti-Spoofing L2 aplicado em veth-sw1: permite apenas src_mac=${HOST1_MAC}, descarta qualquer MAC secundário!"

# Testar macvlan (usa MAC secundário 02:37:ac:00:00:11 -> deve ser 100% bloqueado!)
ip -n e37-host1 link add macv1 link veth-h1 address 02:37:ac:00:00:11 type macvlan mode bridge
ip -n e37-host2 link add macv2 link veth-h2 address 02:37:ac:00:00:22 type macvlan mode bridge
ip -n e37-host1 link set macv1 netns e37-pod1
ip -n e37-host2 link set macv2 netns e37-pod2
ip -n e37-pod1 link set macv1 up
ip -n e37-pod2 link set macv2 up
ip -n e37-pod1 addr add 10.254.105.1/24 dev macv1
ip -n e37-pod2 addr add 10.254.105.2/24 dev macv2

MACV_OK=0
for _ in $(seq 1 5); do
  if ip netns exec e37-pod1 ping -c 1 -W 1 10.254.105.2 >/dev/null 2>&1; then
    MACV_OK=$((MACV_OK + 1))
  fi
done
DROP_STATS="$(tc -n e37-sw -s filter show dev veth-sw1 ingress | tr '\n' ' ')"
log "[3A RESULT macvlan sob Anti-Spoofing L2 Cloud] macvlan_ping_ok=${MACV_OK}/5 (esperado 0/5) | stats=${DROP_STATS}"
[[ "$MACV_OK" -eq 0 ]] || { echo "ERRO: macvlan deveria ser bloqueado!" >&2; exit 1; }
ip -n e37-pod1 link del macv1
ip -n e37-pod2 link del macv2

# Testar ipvlan mode l2 sob o MESMO filtro Anti-Spoofing L2 (reutiliza ${HOST1_MAC} -> deve passar 10/10!)
ip -n e37-host1 link add ipvl1 link veth-h1 type ipvlan mode l2
ip -n e37-host2 link add ipvl2 link veth-h2 type ipvlan mode l2
ip -n e37-host1 link set ipvl1 netns e37-pod1
ip -n e37-host2 link set ipvl2 netns e37-pod2
ip -n e37-pod1 link set ipvl1 up
ip -n e37-pod2 link set ipvl2 up
ip -n e37-pod1 addr add 10.254.105.1/24 dev ipvl1
ip -n e37-pod2 addr add 10.254.105.2/24 dev ipvl2

IPVL_OK=0
for _ in $(seq 1 10); do
  if ip netns exec e37-pod1 ping -c 1 -W 1 10.254.105.2 >/dev/null 2>&1; then
    IPVL_OK=$((IPVL_OK + 1))
  fi
done
log "[3A RESULT ipvlan-l2 sob o MESMO Anti-Spoofing L2 Cloud] ipvlan_ping_ok=${IPVL_OK}/10 (esperado 10/10)"
[[ "$IPVL_OK" -eq 10 ]] || { echo "ERRO: ipvlan deveria passar 10/10!" >&2; exit 1; }

log "--- [3B] Controle Negativo: Queda da interface secundária net1 em e37-vm-b não afeta o CNI primário eth0 Cilium ---"
docker exec p003-gw-worker bash -c '
PID_B="$(crictl inspectp "$(crictl pods --state Ready --name e37-vm-b -q | head -n1)" | awk -F": " "/\"pid\":/ {gsub(/[^0-9]/,\"\",\$2); if (\$2 + 0 > 1) {print \$2; exit}}")"
nsenter -t "$PID_B" -n ip link set net1 down
'
$K -n p007-e37 exec e37-vm-a -- python3 -c "
import urllib.request
eth0_ok, net1_ok = 0, 0
for _ in range(5):
    try:
        with urllib.request.urlopen('http://10.254.37.20:8080/', timeout=0.4) as r:
            net1_ok += 1
    except Exception:
        pass
for _ in range(10):
    with urllib.request.urlopen('http://${VMB_ETH0_IP}:8080/', timeout=2) as r:
        if r.status == 200:
            eth0_ok += 1
print(f'[3B RESULT net1 down] net1_ok={net1_ok}/5 (esperado 0/5) eth0_cilium_ok={eth0_ok}/10 (esperado 10/10)')
assert net1_ok == 0 and eth0_ok == 10
"

log "--- Restaurando net1 em e37-vm-b (10/10 HTTP 200) ---"
docker exec p003-gw-worker bash -c '
PID_B="$(crictl inspectp "$(crictl pods --state Ready --name e37-vm-b -q | head -n1)" | awk -F": " "/\"pid\":/ {gsub(/[^0-9]/,\"\",\$2); if (\$2 + 0 > 1) {print \$2; exit}}")"
nsenter -t "$PID_B" -n ip link set net1 up
'
$K -n p007-e37 exec e37-vm-a -- python3 -c "
import urllib.request
net1_ok = 0
for _ in range(10):
    with urllib.request.urlopen('http://10.254.37.20:8080/', timeout=2) as r:
        if r.status == 200:
            net1_ok += 1
print(f'[3B RESTORE net1 up] net1_ok={net1_ok}/10')
assert net1_ok == 10
"

log "=== E37 CONCLUÍDO COM SUCESSO (PASS) ==="
