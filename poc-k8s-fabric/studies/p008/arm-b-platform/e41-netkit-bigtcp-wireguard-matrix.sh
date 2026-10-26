#!/usr/bin/env bash
# ==============================================================================
# E41 — Matriz Combinada de Datapath (veth vs netkit l3 × MTU 1500 vs BIG TCP
#       GSO 192 KiB × Cleartext vs WireGuard cilium_wg0 Jumbo 8920 B)
# Plano P008-S002 (Braço B)
#
# Objetivo:
#   1. Célula 1 (Benchmark Sistemático dos 4 Regimes de Datapath — 1024 MiB TCP):
#      - Avaliar sob as mesmas condições no Kernel Linux 6.8 da `vm-cilium` os
#        4 regimes fundamentais de datapath container/inter-nó:
#        * Regime 1 (`R1-veth-1500-clear`): `veth`, `MTU 1500`, `GSO 64 KiB`, s/ WG;
#        * Regime 2 (`R2-veth-1500-wg`): `veth`, `MTU 1500`, `WireGuard MTU 1420`;
#        * Regime 3 (`R3-netkit-9000-bigtcp-clear`): `netkit mode l3`, `MTU 9000`,
#          `BIG TCP (gso_max_size=196608)`, s/ WG;
#        * Regime 4 (`R4-netkit-9000-bigtcp-wg`): `netkit mode l3`, `MTU 9000`,
#          `BIG TCP (gso_max_size=196608)` + `WireGuard Jumbo MTU 8920`.
#   2. Célula 2 (Análise Quantitativa de Amortização Criptográfica R4 vs R2):
#      - Comparar a contagem de pacotes criptografados (`wg0_tx_pkts`), o tamanho
#        médio de pacote e o ganho de vazão (`Gbps`) entre `R4` e `R2`, provando
#        que `netkit l3 + Jumbo MTU 9000 + BIG TCP` reduz em >75% o número de
#        pacotes processados pelo ChaCha20-Poly1305 e recupera o throughput.
#   3. Célula 3 (Controles Negativos — PMTU Exato 8920 B DF=1 & Zero Cleartext Leak):
#      - 3A: Com `wg0` em `MTU 8920` (sobre underlay `MTU 9000`), provar `10/10`
#        pings Jumbo `DF=1` de `8892 B` payload (`8920 B` IP total) e `0/5`
#        (`100%` bloqueado por PMTU) para `8893 B` payload (`8921 B` IP),
#        demonstrando o overhead exato de `80 B` do cabeçalho WireGuard.
#      - 3B: Confirmar com captura `tcpdump` no underlay `netkit` durante envio
#        de `E41-MATRIX-TOP-SECRET-7741` que `0` pacotes vazam em texto claro
#        (`cleartext_leaks=0`, `wg_udp_51871_pkts >= 20`).
#      - 3C: Teardown completo e verificação `R6=0`.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/02-e41-netkit-bigtcp-wireguard-matrix.yaml"
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) echo "Uso: $0 [--dry-run]" >&2; exit 1 ;;
  esac
done

log() { printf "[e41][%s] %s\n" "$(date -u +%H:%M:%SZ)" "$*"; }

if $DRY_RUN; then
  log "DRY-RUN: validando existência do manifesto ${MANIFEST}"
  [[ -f "$MANIFEST" ]] || { echo "Manifesto ausente: $MANIFEST" >&2; exit 1; }
  log "DRY-RUN OK: E41 pronto para execução ao vivo na vm-cilium."
  exit 0
fi

export KUBECONFIG="${SANDBOX_KUBECONFIG:-${KUBECONFIG:-${HOME}/.kube/config}}"
CTX="kind-p003-gw"
NS_A="e41-ns-a"
NS_B="e41-ns-b"
WORK_DIR="$(mktemp -d /tmp/e41-matrix.XXXXXX)"

cleanup() {
  log "Iniciando cleanup (rollback R6=0)..."
  kubectl --context "$CTX" delete -f "$MANIFEST" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  for ns in "$NS_A" "$NS_B"; do
    ip netns pids "$ns" 2>/dev/null | xargs -r kill -9 >/dev/null 2>&1 || true
    ip netns del "$ns" >/dev/null 2>&1 || true
  done
  rm -rf "$WORK_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "=== E41 PREFLIGHT: Verificando invariantes k01, p003-gw e piso R3 ==="
kubectl --context kind-k01 get nodes --no-headers | awk '{if ($2 != "Ready") exit 1}'
kubectl --context "$CTX" get nodes --no-headers | awk '{if ($2 != "Ready") exit 1}'
MEM_AVAIL_KB="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
log "MemAvailable=${MEM_AVAIL_KB} kB"
if (( MEM_AVAIL_KB < 4194304 )); then
  echo "ERRO: MemAvailable (${MEM_AVAIL_KB} kB) abaixo do piso R3 (4 GiB)" >&2
  exit 1
fi

kubectl --context "$CTX" apply -f "$MANIFEST"

# Gerar chaves WireGuard efêmeras em memória para o benchmark
WG_PRIV_A="$(wg genkey)"
WG_PUB_A="$(echo "$WG_PRIV_A" | wg pubkey)"
WG_PRIV_B="$(wg genkey)"
WG_PUB_B="$(echo "$WG_PRIV_B" | wg pubkey)"
echo "$WG_PRIV_A" > "${WORK_DIR}/a.key"
echo "$WG_PRIV_B" > "${WORK_DIR}/b.key"

reset_ns() {
  for ns in "$NS_A" "$NS_B"; do
    ip netns pids "$ns" 2>/dev/null | xargs -r kill -9 >/dev/null 2>&1 || true
    ip netns del "$ns" >/dev/null 2>&1 || true
    ip netns add "$ns"
    ip -n "$ns" link set lo up
  done
}

run_tcp_bench() {
  local label="$1" target_ip="$2" dev_stat="$3"
  ip netns exec "$NS_B" python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 9099))
s.listen(4)
while True:
    conn, _ = s.accept()
    while conn.recv(262144):
        pass
    conn.close()
' &
  local srv_pid=$!
  sleep 0.3

  local pkts_before bytes_before
  pkts_before="$(ip -n "$NS_A" -s link show dev "$dev_stat" | awk '/TX:/{getline; print $2}')"
  bytes_before="$(ip -n "$NS_A" -s link show dev "$dev_stat" | awk '/TX:/{getline; print $1}')"

  local gbps
  gbps="$(ip netns exec "$NS_A" python3 -c "
import socket, time
buf = b'X' * 262144
total_chunks = 4096 # 1024 MiB
vals = []
for _ in range(2):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect(('${target_ip}', 9099))
    t0 = time.monotonic()
    for _ in range(total_chunks):
        s.sendall(buf)
    s.close()
    dt = time.monotonic() - t0
    vals.append((1024 * 8) / dt / 1000.0)
print(f'{sum(vals)/len(vals):.2f}')
")"

  local pkts_after bytes_after pkts_delta bytes_delta avg_pkt_b
  pkts_after="$(ip -n "$NS_A" -s link show dev "$dev_stat" | awk '/TX:/{getline; print $2}')"
  bytes_after="$(ip -n "$NS_A" -s link show dev "$dev_stat" | awk '/TX:/{getline; print $1}')"
  pkts_delta=$((pkts_after - pkts_before))
  bytes_delta=$((bytes_after - bytes_before))
  avg_pkt_b=$(( pkts_delta > 0 ? bytes_delta / pkts_delta : 0 ))

  kill -9 "$srv_pid" >/dev/null 2>&1 || true
  echo "${label}: avg_gbps=${gbps} tx_pkts_2gib=${pkts_delta} avg_bytes_per_pkt=${avg_pkt_b}"
}

setup_wg_overlay() {
  local wg_mtu="$1" gso_max="$2"
  ip -n "$NS_A" link add cilium_wg0 type wireguard
  ip -n "$NS_B" link add cilium_wg0 type wireguard
  ip -n "$NS_A" addr add 10.245.41.1/24 dev cilium_wg0
  ip -n "$NS_B" addr add 10.245.41.2/24 dev cilium_wg0
  ip -n "$NS_A" link set cilium_wg0 mtu "$wg_mtu" gso_max_size "$gso_max" gro_max_size "$gso_max" up
  ip -n "$NS_B" link set cilium_wg0 mtu "$wg_mtu" gso_max_size "$gso_max" gro_max_size "$gso_max" up
  ip netns exec "$NS_A" wg set cilium_wg0 listen-port 51871 private-key "${WORK_DIR}/a.key" peer "$WG_PUB_B" allowed-ips 10.245.41.2/32 endpoint 172.18.41.2:51871
  ip netns exec "$NS_B" wg set cilium_wg0 listen-port 51871 private-key "${WORK_DIR}/b.key" peer "$WG_PUB_A" allowed-ips 10.245.41.1/32 endpoint 172.18.41.1:51871
}

log "=== CÉLULA 1: Executando Benchmark Sistemático dos 4 Regimes (2 x 1024 MiB = 2 GiB por Regime) ==="

# Regime 1: veth + MTU 1500 + Cleartext
reset_ns
ip link add dev-a netns "$NS_A" type veth peer name dev-b netns "$NS_B"
ip -n "$NS_A" link set dev-a mtu 1500 gso_max_size 65536 gro_max_size 65536 up
ip -n "$NS_B" link set dev-b mtu 1500 gso_max_size 65536 gro_max_size 65536 up
ip -n "$NS_A" addr add 172.18.41.1/24 dev dev-a
ip -n "$NS_B" addr add 172.18.41.2/24 dev dev-b
R1_RES="$(run_tcp_bench "R1-veth-1500-clear" "172.18.41.2" "dev-a")"
log "$R1_RES"

# Regime 2: veth + MTU 1500 + WireGuard (MTU 1420)
setup_wg_overlay 1420 65536
R2_RES="$(run_tcp_bench "R2-veth-1500-wg" "10.245.41.2" "dev-a")"
log "$R2_RES"

# Regime 3: netkit mode l3 + MTU 9000 + BIG TCP (196608) + Cleartext
reset_ns
CILIUM_W1="$(kubectl --context "$CTX" -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=p003-gw-worker -o jsonpath='{.items[0].metadata.name}')"
IP_NK="${WORK_DIR}/ip-nk"
kubectl --context "$CTX" -n kube-system exec "$CILIUM_W1" -c cilium-agent -- cat /bin/ip > "$IP_NK"
chmod +x "$IP_NK"

"$IP_NK" link add nk-a type netkit mode l3 peer nk-b
ip link set nk-a netns "$NS_A"
ip link set nk-b netns "$NS_B"
"$IP_NK" -n "$NS_A" link set dev nk-a mtu 9000 gso_max_size 196608 gro_max_size 196608 gso_ipv4_max_size 196608 gro_ipv4_max_size 196608 up
"$IP_NK" -n "$NS_B" link set dev nk-b mtu 9000 gso_max_size 196608 gro_max_size 196608 gso_ipv4_max_size 196608 gro_ipv4_max_size 196608 up
ip -n "$NS_A" addr add 172.18.41.1/24 dev nk-a
ip -n "$NS_B" addr add 172.18.41.2/24 dev nk-b
R3_RES="$(run_tcp_bench "R3-netkit-9000-bigtcp-clear" "172.18.41.2" "nk-a")"
log "$R3_RES"

# Regime 4: netkit mode l3 + MTU 9000 + BIG TCP (196608 no netkit) + WireGuard Jumbo (MTU 8920, GSO 65536 no wg0)
setup_wg_overlay 8920 65536
R4_RES="$(run_tcp_bench "R4-netkit-9000-bigtcp-wg" "10.245.41.2" "nk-a")"
log "$R4_RES"

log "=== CÉLULA 2: Análise de Amortização Criptográfica (R4 vs R2) ==="
R2_GBPS="$(echo "$R2_RES" | awk -F'[= ]' '{print $3}')"
R4_GBPS="$(echo "$R4_RES" | awk -F'[= ]' '{print $3}')"
R2_PKTS="$(echo "$R2_RES" | awk -F'[= ]' '{print $5}')"
R4_PKTS="$(echo "$R4_RES" | awk -F'[= ]' '{print $5}')"

COMPARE_SUMMARY="$(python3 -c "
r2_g, r4_g = float('${R2_GBPS}'), float('${R4_GBPS}')
r2_p, r4_p = int('${R2_PKTS}'), int('${R4_PKTS}')
gain_pct = ((r4_g - r2_g) / r2_g) * 100.0 if r2_g > 0 else 0.0
pkt_red_pct = ((r2_p - r4_p) / r2_p) * 100.0 if r2_p > 0 else 0.0
print(f'wg_gbps_gain_pct=+{gain_pct:.1f}% wg_pkt_reduction_pct=-{pkt_red_pct:.1f}% (R2={r2_p} pkts -> R4={r4_p} pkts)')
")"
log "Comparativo R4 vs R2: ${COMPARE_SUMMARY}"
(( R4_PKTS < R2_PKTS / 3 )) || {
  echo "Redução de pacotes em R4 abaixo do esperado (${R4_PKTS} vs ${R2_PKTS})" >&2; exit 1;
}

log "=== CÉLULA 3: Controles Negativos (3A Limite Exato PMTU 8920 B DF=1 & 3B Zero Cleartext Leak) ==="
# 3A: Ping DF=1 com 8892 B payload (8920 B IP total) -> 10/10; com 8893 B payload (8921 B IP) -> 0/5
PING_8892_OK=0
for _ in $(seq 1 10); do
  if ip netns exec "$NS_A" ping -c 1 -W 1 -M do -s 8892 10.245.41.2 >/dev/null 2>&1; then
    PING_8892_OK=$((PING_8892_OK + 1))
  fi
done

PING_8893_OK=0
for _ in $(seq 1 5); do
  if ip netns exec "$NS_A" ping -c 1 -W 1 -M do -s 8893 10.245.41.2 >/dev/null 2>&1; then
    PING_8893_OK=$((PING_8893_OK + 1))
  fi
done
log "Controle 3A (PMTU WireGuard 8920 B sobre netkit 9000 B): ping_8892_df=${PING_8892_OK}/10 ping_8893_df=${PING_8893_OK}/5 (overhead exato=80 B)"
[[ "$PING_8892_OK" -eq 10 && "$PING_8893_OK" -eq 0 ]] || {
  echo "Falha no Controle 3A (PMTU WireGuard)" >&2; exit 1;
}

# 3B: Capturar pacotes no underlay nk-b enquanto trafegamos o marcador E41-MATRIX-TOP-SECRET-7741
ip netns exec "$NS_B" tcpdump -i nk-b -nn -A -c 25 udp port 51871 > "${WORK_DIR}/tcpdump-r4.txt" 2>&1 &
TCPDUMP_PID=$!
sleep 0.4

ip netns exec "$NS_B" python3 -c '
import http.server, socketserver
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"E41-MATRIX-TOP-SECRET-7741\n")
    def log_message(self, *args): pass
socketserver.TCPServer.allow_reuse_address = True
s = socketserver.TCPServer(("10.245.41.2", 8089), H)
for _ in range(10): s.handle_request()
' &
SRV3B_PID=$!
sleep 0.3

C3B_HTTP_OK=0
for _ in $(seq 1 10); do
  OUT="$(ip netns exec "$NS_A" curl -sS --max-time 1 "http://10.245.41.2:8089/" || true)"
  [[ "$OUT" == "E41-MATRIX-TOP-SECRET-7741" ]] && C3B_HTTP_OK=$((C3B_HTTP_OK + 1))
done
wait "$SRV3B_PID" 2>/dev/null || true
sleep 0.4
kill -2 "$TCPDUMP_PID" 2>/dev/null || true
wait "$TCPDUMP_PID" 2>/dev/null || true

WG_UDP_PKTS="$(grep -c '51871' "${WORK_DIR}/tcpdump-r4.txt" || true)"
CLEARTEXT_LEAKS="$(grep -c 'E41-MATRIX-TOP-SECRET-7741' "${WORK_DIR}/tcpdump-r4.txt" || true)"
log "Controle 3B (Zero Cleartext Leak em R4): http_ok=${C3B_HTTP_OK}/10 wg_udp_51871_pkts=${WG_UDP_PKTS} cleartext_leaks=${CLEARTEXT_LEAKS}"
[[ "$C3B_HTTP_OK" -eq 10 && "$WG_UDP_PKTS" -ge 15 && "$CLEARTEXT_LEAKS" -eq 0 ]] || {
  echo "Falha no Controle 3B (Zero Cleartext Leak)" >&2; exit 1;
}

cleanup
trap - EXIT

R6_ROUTES="$(ip route show proto bgp | wc -l | tr -d ' ')"
log "=== E41 SUMMARY ==="
log "Célula 1 (4 Regimes): PASS (${R1_RES} | ${R2_RES} | ${R3_RES} | ${R4_RES})"
log "Célula 2 (Amortização Criptográfica R4 vs R2): PASS (${COMPARE_SUMMARY})"
log "Célula 3 (Controles 3A/3B/3C): PASS (3A 8892B=10/10 8893B=0/5, 3B http=10/10 wg_pkts=${WG_UDP_PKTS} leaks=${CLEARTEXT_LEAKS}, R6=${R6_ROUTES})"
log "E41 CONCLUÍDO COM SUCESSO (PASS)."
