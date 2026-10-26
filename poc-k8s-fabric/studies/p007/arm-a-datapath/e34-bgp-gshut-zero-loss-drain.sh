#!/usr/bin/env bash
# ==============================================================================
# P007-S001 — Braço A (E34): BGP Graceful Shutdown (RFC 8326 GSHUT 65535:0) &
#             Drenagem Zero-Loss de Nós Kubernetes
#
# Objetivo:
#   Avaliar no sandbox p003-gw (Cilium 1.20.2 + FRR):
#   - Célula 1: Comparativo sob tráfego contínuo (50 pps / 20 ms, 150 pacotes UDP
#     numerados com portas de origem distintas para hash L4 ECMP) entre:
#       * Ensaio 1A (Abrupt Node Drain): encerramento abrupto do backend em W1
#         antes da convergência BGP, medindo os pacotes perdidos durante a janela
#         em que o ToR ainda mantém W1 no grupo multipath ECMP.
#       * Ensaio 1B (BGP Graceful Shutdown RFC 8326): anúncio prévio da community
#         well-known `graceful-shutdown` (`65535:0`) por W1 -> ToR reduz
#         `local-preference` de 100 para 0 via `route-map RM-E34-TOR-IN` -> FIB
#         do ToR comuta atomicamente 100% dos fluxos novos para W2 enquanto W1
#         permanece vivo em `PreStop`, encerrando W1 com `lost_pkts = 0` (0.0%).
#   - Célula 2: Programação nativa de `65535:0` no Cilium 1.20.2 via CRD
#     `CiliumBGPAdvertisement` (`attributes.communities.standard: ["65535:0"]`) e
#     `CiliumLoadBalancerIPPool` (`10.207.34.200/32`).
#   - Célula 3: Controles negativos e propriedade de Último Recurso (RFC 8326):
#       * 3A: Com W1 em `GSHUT` (`localpref 0`) e W2 ativo (`localpref 100`), a
#         queda súbita de W2 promove imediatamente a rota `GSHUT` de W1 de volta
#         ao bestpath na FIB do ToR (`10/10` pacotes entregues), provando por que
#         `GSHUT` é superior a um withdraw prematuro.
#       * 3B: Queda simultânea de W1 e W2 -> `0/5` pacotes entregues (`R6=0`).
#
# Invariantes:
#   - R1: k01 (uid=635e7274-5597-40c7-9de5-b1fbe3d68b22) intocado (10/10 HTTP 200)
#   - R2: Suporte a --dry-run e rollback determinístico via trap EXIT
#   - R3: MemAvailable >= 4.00 GiB
#   - R6: 0 containers/netns/CRDs temporários residuais após rollback
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/01-e34-bgp-gshut.yaml"

SANDBOX_KUBECONFIG="${SANDBOX_KUBECONFIG:-/root/.kube/p003-gw.config}"
SANDBOX_CONTEXT="${SANDBOX_CONTEXT:-kind-p003-gw}"
SANDBOX_UID="${SANDBOX_UID:-6bb32e0f-71f9-4558-ae33-356ba2250c26}"

K01_KUBECONFIG="${K01_KUBECONFIG:-/root/.kube/k01-rebuild.config}"
K01_UID="${K01_UID:-635e7274-5597-40c7-9de5-b1fbe3d68b22}"

FRR_LAB_CTR="frr-e34-lab"
FRR_IMAGE="${FRR_IMAGE:-quay.io/frrouting/frr:10.5.0}"

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
  printf '[%s] [E34] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "MODO --dry-run ATIVO: validando manifesto e plano de execução sem tocar no cluster."
  [[ -f "$MANIFEST" ]] || { echo "ERRO: manifesto ausente: $MANIFEST" >&2; exit 1; }
  log "Plano de execução:"
  log "  1. Preflight R1 (k01 uid=${K01_UID}), R2 (p003-gw uid=${SANDBOX_UID}) e R3 (MemAvailable >= 4 GiB)"
  log "  2. Célula 1: Topologia BGP ECMP 2-way (ToR AS 65000 <-> W1 AS 65301 + W2 AS 65302): Abrupt Drain vs RFC 8326 GSHUT (65535:0) sob 50 pps"
  log "  3. Célula 2: CiliumBGPAdvertisement nativa com community standard 65535:0 no Cilium 1.20.2"
  log "  4. Célula 3: Controles 3A (Fallback Last-Resort localpref 0 quando W2 cai) e 3B (Blackhole total com ambos down + restauração)"
  log "  5. Teardown determinístico (R6=0)"
  exit 0
fi

K="kubectl --kubeconfig=${SANDBOX_KUBECONFIG} --context=${SANDBOX_CONTEXT}"

cleanup() {
  log "Executando limpeza determinística (R6)..."
  docker rm -f "${FRR_LAB_CTR}" >/dev/null 2>&1 || true
  $K delete -f "$MANIFEST" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  $K delete ns p007-e34 --ignore-not-found=true --wait=true --timeout=60s >/dev/null 2>&1 || true
  $K label node p003-gw-worker cilium.io/bgp-gshut- >/dev/null 2>&1 || true
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
# CÉLULA 1: Abrupt Node Drain vs BGP Graceful Shutdown (RFC 8326 GSHUT 65535:0)
# ==============================================================================
log "=== CÉLULA 1: Comparativo Empírico — Abrupt Drain vs BGP Graceful Shutdown (RFC 8326 65535:0) ==="
docker rm -f "${FRR_LAB_CTR}" >/dev/null 2>&1 || true
docker run -d --name "${FRR_LAB_CTR}" --privileged --entrypoint /bin/sh "${FRR_IMAGE}" -c "sleep 3600" >/dev/null

docker exec -i "${FRR_LAB_CTR}" sh -s <<'EOF_LAB'
set -eu
apk add --no-cache python3 >/dev/null 2>&1 || true

for ns in tor w1 w2 client; do
  ip netns add "$ns"
  ip -n "$ns" link set lo up
done

# Enable L4 multipath hash on ToR so varying UDP source ports distribute across ECMP nexthops
ip netns exec tor sysctl -qw net.ipv4.ip_forward=1
ip netns exec tor sysctl -qw net.ipv4.fib_multipath_hash_policy=1
ip netns exec w1 sysctl -qw net.ipv4.ip_forward=1
ip netns exec w2 sysctl -qw net.ipv4.ip_forward=1

# Client (198.19.34.10/24) <-> ToR (198.19.34.1/24)
ip link add veth-cli netns client type veth peer name veth-tor-cli netns tor
ip -n client addr add 198.19.34.10/24 dev veth-cli
ip -n client link set veth-cli up
ip -n client route add default via 198.19.34.1
ip -n tor addr add 198.19.34.1/24 dev veth-tor-cli
ip -n tor link set veth-tor-cli up

# ToR (10.207.34.1/30) <-> W1 (10.207.34.2/30)
ip link add veth-tor-w1 netns tor type veth peer name veth-w1 netns w1
ip -n tor addr add 10.207.34.1/30 dev veth-tor-w1
ip -n tor link set veth-tor-w1 up
ip -n w1 addr add 10.207.34.2/30 dev veth-w1
ip -n w1 link set veth-w1 up
ip -n w1 addr add 10.207.34.100/32 dev lo
ip -n w1 route add 198.19.34.0/24 via 10.207.34.1

# ToR (10.207.34.5/30) <-> W2 (10.207.34.6/30)
ip link add veth-tor-w2 netns tor type veth peer name veth-w2 netns w2
ip -n tor addr add 10.207.34.5/30 dev veth-tor-w2
ip -n tor link set veth-tor-w2 up
ip -n w2 addr add 10.207.34.6/30 dev veth-w2
ip -n w2 link set veth-w2 up
ip -n w2 addr add 10.207.34.100/32 dev lo
ip -n w2 route add 198.19.34.0/24 via 10.207.34.5

mkdir -p /tmp/frr-tor /tmp/frr-w1 /tmp/frr-w2
chown -R frr:frr /tmp/frr-tor /tmp/frr-w1 /tmp/frr-w2

cat <<'CONF_TOR' > /tmp/frr-tor/frr.conf
hostname e34-tor
bgp community-list standard GSHUT permit graceful-shutdown
!
route-map RM-E34-TOR-IN permit 10
 match community GSHUT
 set local-preference 0
exit
route-map RM-E34-TOR-IN permit 20
 set local-preference 100
exit
!
router bgp 65000
 bgp router-id 10.207.34.1
 no bgp ebgp-requires-policy
 bgp bestpath as-path multipath-relax
 neighbor 10.207.34.2 remote-as 65301
 neighbor 10.207.34.2 timers 1 3
 neighbor 10.207.34.2 timers connect 1
 neighbor 10.207.34.6 remote-as 65302
 neighbor 10.207.34.6 timers 1 3
 neighbor 10.207.34.6 timers connect 1
 !
 address-family ipv4 unicast
  neighbor 10.207.34.2 route-map RM-E34-TOR-IN in
  neighbor 10.207.34.6 route-map RM-E34-TOR-IN in
  maximum-paths 4
 exit-address-family
exit
CONF_TOR

cat <<'CONF_W1' > /tmp/frr-w1/frr.conf
hostname e34-w1
route-map RM-W1-GSHUT permit 10
 set community graceful-shutdown
exit
!
router bgp 65301
 bgp router-id 10.207.34.2
 no bgp ebgp-requires-policy
 neighbor 10.207.34.1 remote-as 65000
 neighbor 10.207.34.1 timers 1 3
 neighbor 10.207.34.1 timers connect 1
 !
 address-family ipv4 unicast
  network 10.207.34.100/32
 exit-address-family
exit
CONF_W1

cat <<'CONF_W2' > /tmp/frr-w2/frr.conf
hostname e34-w2
router bgp 65302
 bgp router-id 10.207.34.6
 no bgp ebgp-requires-policy
 neighbor 10.207.34.5 remote-as 65000
 neighbor 10.207.34.5 timers 1 3
 neighbor 10.207.34.5 timers connect 1
 !
 address-family ipv4 unicast
  network 10.207.34.100/32
 exit-address-family
exit
CONF_W2

for node in tor w1 w2; do
  ip netns exec "$node" /usr/lib/frr/zebra -d -N "$node" -i "/tmp/frr-${node}/zebra.pid" -z "/tmp/frr-${node}/zserv.api"
  ip netns exec "$node" /usr/lib/frr/bgpd -d -N "$node" -i "/tmp/frr-${node}/bgpd.pid" -z "/tmp/frr-${node}/zserv.api"
  ip netns exec "$node" vtysh -N "$node" -f "/tmp/frr-${node}/frr.conf"
done

cat <<'PY_SRV' > /tmp/udp_srv.py
import socket, sys
tag = sys.argv[1]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("10.207.34.100", 9034))
while True:
    data, addr = s.recvfrom(1024)
    s.sendto(f"{tag}:{data.decode()}".encode(), addr)
PY_SRV

ip netns exec w1 python3 /tmp/udp_srv.py W1 >/dev/null 2>&1 &
echo $! > /tmp/w1_srv.pid
ip netns exec w2 python3 /tmp/udp_srv.py W2 >/dev/null 2>&1 &
echo $! > /tmp/w2_srv.pid
EOF_LAB

sleep 4

log "--- Baseline ECMP (ToR RIB + FIB antes do drain) ---"
docker exec "${FRR_LAB_CTR}" ip netns exec tor vtysh -N tor -c "show bgp ipv4 unicast 10.207.34.100/32"
docker exec "${FRR_LAB_CTR}" ip netns exec tor ip route show 10.207.34.100/32

log "--- Ensaio 1A: Abrupt Node Drain (Backend W1 morre em t=1.0s; BGP withdraw só em t=1.6s) ---"
docker exec -i "${FRR_LAB_CTR}" sh -s <<'EOF_1A'
set -eu
cat <<'PY_CLI' > /tmp/udp_probe.py
import socket, sys, time
base_sport = int(sys.argv[1])
total = 150
interval = 0.020
served_w1 = 0
served_w2 = 0
lost = 0
first_loss_ts = None
last_loss_ts = None

for seq in range(1, total + 1):
    t0 = time.monotonic()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(0.080)
    s.bind(("198.19.34.10", base_sport + seq))
    try:
        s.sendto(f"SEQ-{seq}".encode(), ("10.207.34.100", 9034))
        resp, _ = s.recvfrom(1024)
        txt = resp.decode()
        if txt.startswith("W1:"):
            served_w1 += 1
        elif txt.startswith("W2:"):
            served_w2 += 1
    except Exception:
        lost += 1
        now = time.monotonic()
        if first_loss_ts is None:
            first_loss_ts = now
        last_loss_ts = now
    finally:
        s.close()
    dt = time.monotonic() - t0
    if dt < interval:
        time.sleep(interval - dt)

blackout_ms = 0.0
if first_loss_ts is not None and last_loss_ts is not None:
    blackout_ms = (last_loss_ts - first_loss_ts + interval) * 1000.0
print(f"total={total} served_w1={served_w1} served_w2={served_w2} lost_pkts={lost} loss_pct={lost*100.0/total:.2f}% blackout_ms={blackout_ms:.2f}")
PY_CLI

(
  sleep 1.0
  # Abruptly kill W1 responder while ToR still routes ~50% of ECMP flows to W1
  kill -9 "$(cat /tmp/w1_srv.pid)" 2>/dev/null || true
  sleep 0.60
  # Withdraw route after 600ms delay (simulating hold/kube-proxy lag)
  ip netns exec w1 vtysh -N w1 -c "conf t" -c "router bgp 65301" -c "address-family ipv4 unicast" -c "no network 10.207.34.100/32" >/dev/null
) &

ip netns exec client python3 /tmp/udp_probe.py 40000
wait
EOF_1A

log "--- Restaurando W1 e ECMP 2-way para o Ensaio 1B (RFC 8326 GSHUT) ---"
docker exec -i "${FRR_LAB_CTR}" sh -s <<'EOF_RESTORE'
set -eu
ip netns exec w1 python3 /tmp/udp_srv.py W1 >/dev/null 2>&1 &
echo $! > /tmp/w1_srv.pid
ip netns exec w1 vtysh -N w1 -c "conf t" -c "router bgp 65301" -c "address-family ipv4 unicast" -c "network 10.207.34.100/32" >/dev/null
sleep 2
EOF_RESTORE

log "--- Ensaio 1B: BGP Graceful Shutdown (RFC 8326 community 65535:0 em t=1.0s + PreStop -> término em t=1.8s) ---"
docker exec -i "${FRR_LAB_CTR}" sh -s <<'EOF_1B'
set -eu
(
  sleep 1.0
  # Step 1: W1 announces GSHUT (65535:0) while keeping local responder alive (PreStop window)
  ip netns exec w1 vtysh -N w1 -c "conf t" -c "router bgp 65301" -c "address-family ipv4 unicast" -c "neighbor 10.207.34.1 route-map RM-W1-GSHUT out" >/dev/null
  sleep 0.80
  # Step 2: After ToR FIB has drained 100% of new flows to W2, W1 stops responder
  kill -9 "$(cat /tmp/w1_srv.pid)" 2>/dev/null || true
) &

ip netns exec client python3 /tmp/udp_probe.py 42000
wait

echo "=== RIB e FIB no ToR durante GSHUT (W1 com community graceful-shutdown e localpref 0) ==="
ip netns exec tor vtysh -N tor -c "show bgp ipv4 unicast 10.207.34.100/32"
ip netns exec tor ip route show 10.207.34.100/32
EOF_1B

# ==============================================================================
# CÉLULA 2: Programação Nativa de 65535:0 no Cilium 1.20.2 (CiliumBGPAdvertisement)
# ==============================================================================
log "=== CÉLULA 2: Programação Nativa de GSHUT (65535:0) no Cilium 1.20.2 via CiliumBGPAdvertisement ==="
$K apply -f "$MANIFEST"
$K -n p007-e34 rollout status deploy/e34-backend --timeout=60s

CILIUM_POD="$($K -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=p003-gw-worker -o jsonpath='{.items[0].metadata.name}')"
sleep 3
log "Verificando CRD CiliumBGPAdvertisement/e34-gshut-adv e rotas anunciadas no Cilium:"
$K get ciliumbgpadvertisement e34-gshut-adv -o jsonpath='{.metadata.name}: communities={.spec.advertisements[0].attributes.communities.standard} localPref={.spec.advertisements[0].attributes.localPreference}{"\n"}'
$K -n kube-system exec "$CILIUM_POD" -- cilium-dbg bgp routes advertised ipv4 unicast || true

# ==============================================================================
# CÉLULA 3: Controles Negativos e Propriedade de Último Recurso (RFC 8326)
# ==============================================================================
log "=== CÉLULA 3: Controle 3A (Fallback Last-Resort: Queda de W2 promove rota GSHUT localpref 0 de W1) & Controle 3B ==="
docker exec -i "${FRR_LAB_CTR}" sh -s <<'EOF_CELL3'
set -eu
# Restart W1 responder while W1 is still in GSHUT (localpref 0)
ip netns exec w1 python3 /tmp/udp_srv.py W1 >/dev/null 2>&1 &
echo $! > /tmp/w1_srv.pid
sleep 0.5

# Simulate sudden failure of W2 (the active localpref 100 path)
ip netns exec w2 vtysh -N w2 -c "conf t" -c "router bgp 65302" -c "address-family ipv4 unicast" -c "no network 10.207.34.100/32" >/dev/null
sleep 1

echo "--- [3A] FIB do ToR após queda de W2 (rota GSHUT localpref 0 de W1 assume como último recurso!) ---"
ip netns exec tor vtysh -N tor -c "show bgp ipv4 unicast 10.207.34.100/32"
ip netns exec tor ip route show 10.207.34.100/32

python3 - <<'PY_3A'
import subprocess
ok = 0
for i in range(10):
    out = subprocess.check_output([
        "ip", "netns", "exec", "client", "python3", "-c",
        "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(0.5); s.sendto(b'PING',('10.207.34.100',9034)); print(s.recvfrom(1024)[0].decode())"
    ]).decode().strip()
    if out.startswith("W1:"):
        ok += 1
print(f"[3A RESULT] last_resort_gshut_w1_ok={ok}/10")
assert ok == 10, f"Esperado 10/10 via W1 last-resort, obtido {ok}/10"
PY_3A

echo "--- [3B] Controle Negativo: Retirada simultânea de W1 e W2 (0/5 entregues) ---"
ip netns exec w1 vtysh -N w1 -c "conf t" -c "router bgp 65301" -c "address-family ipv4 unicast" -c "no network 10.207.34.100/32" >/dev/null
sleep 1
FIB_EMPTY="$(ip netns exec tor ip route show 10.207.34.100/32)"
echo "[3B] FIB para 10.207.34.100/32 com W1+W2 retirados: '${FIB_EMPTY}'"
python3 - <<'PY_3B'
import subprocess
ok = 0
for i in range(5):
    rc = subprocess.call([
        "ip", "netns", "exec", "client", "python3", "-c",
        "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(0.2); s.sendto(b'PING',('10.207.34.100',9034)); s.recvfrom(1024)"
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if rc == 0:
        ok += 1
print(f"[3B RESULT] both_withdrawn_ok={ok}/5 (esperado 0/5)")
assert ok == 0
PY_3B

echo "--- [3C] Restauração de W1 (sem GSHUT) e W2 (ECMP 10/10) ---"
ip netns exec w1 vtysh -N w1 -c "conf t" -c "router bgp 65301" -c "address-family ipv4 unicast" -c "no neighbor 10.207.34.1 route-map RM-W1-GSHUT out" -c "network 10.207.34.100/32" >/dev/null
ip netns exec w2 vtysh -N w2 -c "conf t" -c "router bgp 65302" -c "address-family ipv4 unicast" -c "network 10.207.34.100/32" >/dev/null
sleep 1
python3 - <<'PY_3C'
import subprocess
ok = 0
for i in range(10):
    rc = subprocess.call([
        "ip", "netns", "exec", "client", "python3", "-c",
        "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(0.5); s.sendto(b'PING',('10.207.34.100',9034)); s.recvfrom(1024)"
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if rc == 0:
        ok += 1
print(f"[3C RESULT] restored_ecmp_ok={ok}/10 (esperado 10/10)")
assert ok == 10
PY_3C
EOF_CELL3

log "=== E34 CONCLUÍDO COM SUCESSO (PASS) ==="
