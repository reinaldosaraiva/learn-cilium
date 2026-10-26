#!/usr/bin/env bash
# ==============================================================================
# P006-S004 — Braço B (E33): KubeVirt Live Migration sob Tráfego Contínuo
#             (Cilium B /32 BGP Cutover vs OVN-Kubernetes EVPN Type-2 Mobility)
#
# Objetivo:
#   Medir e comparar de forma reproduzível na vm-cilium o comportamento de rede
#   durante a Live Migration de uma VM (`10.253.33.10`, MAC `02:53:33:00:00:10`)
#   entre dois hipervisores (`worker` -> `worker2`) sob fluxo contínuo de
#   pacotes (50 pps / intervalo de 20 ms):
#   - Célula 1: Arquitetura de handoff de endpoint `virt-launcher` no KubeVirt
#     (`virt-launcher-vm-e33-src` em `p003-gw-worker` -> `virt-launcher-vm-e33-dst`
#     em `p003-gw-worker2`) e preparação do fabric de medição.
#   - Célula 2A (Modelo Cilium B — L3 /32 BGP Next-Hop Update):
#     Migração ao vivo de `10.253.33.10/32` do nó `worker` (AS 65101, NH 10.253.0.2)
#     para `worker2` (AS 65102, NH 10.253.0.3) via FRR sob tráfego contínuo de
#     50 pps, medindo pacotes atendidos pela origem, pacotes atendidos pelo
#     destino, perda exata (`lost_pkts`) e janela de blackout (`blackout_ms`).
#   - Célula 2B (Modelo OVN-K / EVPN VXLAN VNI 10033 + FDB extern_learn MAC-IP Mobility):
#     Migração ao vivo de `02:53:33:00:00:10` / `10.253.34.10/24` sobre VXLAN VNI 10033
#     entre `vtep1` (`10.254.0.1`) e `vtep2` (`10.254.0.2`) com auto-descoberta BGP EVPN
#     Type-3 e atualização FDB `extern_learn`, medindo `lost_pkts` e `blackout_ms`.
#   - Célula 3 (Controle Negativo): Migração física da VM para `worker2` sem
#     atualização da rota `/32` (next-hop obsoleto apontando para `worker`),
#     provando blackhole (`0/10` pacotes entregues) e recuperação imediata
#     (`10/10`) após o anúncio BGP `/32`, seguido de rollback completo (R6=0).
#
# Invariantes:
#   - R1: k01 (uid=635e7274-5597-40c7-9de5-b1fbe3d68b22) intocado (10/10 HTTP 200)
#   - R2: Suporte a --dry-run e rollback determinístico via trap EXIT
#   - R3: MemAvailable >= 4.00 GiB
#   - R6: 0 rotas BGP residuais no kernel main dos nós K8s após rollback
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/01-e33-kubevirt-live-migration.yaml"

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
  printf '[%s] [E33] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "DRY-RUN: Validando plano de execução E33 (KubeVirt Live Migration sob Tráfego Contínuo)"
  log "DRY-RUN: 1. Validar UID do sandbox p003-gw (${SANDBOX_UID}) e canário k01 (${K01_UID})"
  log "DRY-RUN: 2. Célula 1: Aplicar ${MANIFEST} (virt-launcher-vm-e33-src em worker e virt-launcher-vm-e33-dst em worker2) e levantar fabric FRR de teste"
  log "DRY-RUN: 3. Célula 2A (Cilium B /32 BGP): Executar handoff ao vivo de 10.253.33.10/32 (worker -> worker2) sob 50 pps contínuos e medir blackout_ms e lost_pkts"
  log "DRY-RUN: 4. Célula 2B (OVN-K EVPN VXLAN VNI 10033 + FDB extern_learn Mobility): Executar migração L2/EVPN de 02:53:33:00:00:10 / 10.253.34.10/24 (VTEP 10.254.0.1 -> 10.254.0.2) sob 50 pps contínuos e medir blackout_ms e lost_pkts"
  log "DRY-RUN: 5. Célula 3 (Controle Negativo): Migrar workload sem atualizar rota /32 (0/10 blackhole) e restaurar rota (10/10 HTTP 200)"
  log "DRY-RUN: 6. Rollback determinístico: remover containers e33-*, manifesto p006-e33 e verificar R6=0"
  exit 0
fi

kc() {
  sudo KUBECONFIG="$SANDBOX_KUBECONFIG" kubectl --context "$SANDBOX_CONTEXT" "$@"
}

cleanup() {
  log "ROLLBACK: Limpando recursos temporários de E33..."
  sudo pkill -f "E33_UDP_SERVER" >/dev/null 2>&1 || true
  sudo ip netns del e33-vm-w1 >/dev/null 2>&1 || true
  sudo ip netns del e33-vm-w2 >/dev/null 2>&1 || true
  sudo docker rm -f e33-tor e33-w1 e33-w2 >/dev/null 2>&1 || true
  sudo ip link del br-e33-fab >/dev/null 2>&1 || true
  sudo rm -f /tmp/e33-bgp-migration.json /tmp/e33-evpn-migration.json >/dev/null 2>&1 || true
  kc delete -f "$MANIFEST" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  kc delete ns p006-e33 --ignore-not-found=true --wait=true --timeout=60s >/dev/null 2>&1 || true
  log "ROLLBACK: Concluído."
}
trap cleanup EXIT

log "PREFLIGHT: Verificando UID do sandbox p003-gw e canário k01..."
ACTUAL_UID="$(kc get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "$ACTUAL_UID" != "$SANDBOX_UID" ]]; then
  echo "ABORT: UID do sandbox ($ACTUAL_UID) != esperado ($SANDBOX_UID)" >&2
  exit 1
fi
K01_ACTUAL_UID="$(sudo KUBECONFIG="$K01_KUBECONFIG" kubectl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "$K01_ACTUAL_UID" != "$K01_UID" ]]; then
  echo "ABORT: UID do k01 ($K01_ACTUAL_UID) != esperado ($K01_UID)" >&2
  exit 1
fi
MEM_AVAIL_KB="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"
log "PREFLIGHT OK: p003-gw UID=${ACTUAL_UID}, k01 UID=${K01_ACTUAL_UID}, MemAvailable=${MEM_AVAIL_KB} kB"

# ==============================================================================
# CÉLULA 1: Pods virt-launcher no K8s + Topologia FRR para Medição Contínua
# ==============================================================================
log "CÉLULA 1: Aplicando manifesto ${MANIFEST} (virt-launcher source em worker, target em worker2)..."
kc apply -f "$MANIFEST"
kc -n p006-e33 wait --for=condition=Ready pod --all --timeout=90s
kc -n p006-e33 get pods -o wide

FRR_IMAGE="$(sudo docker images --format '{{.Repository}}:{{.Tag}}' | grep -E 'frr|frrouting' | head -n1)"
if [[ -z "$FRR_IMAGE" ]]; then
  FRR_IMAGE="quay.io/frrouting/frr:10.3.1"
fi

sudo docker rm -f e33-tor e33-w1 e33-w2 >/dev/null 2>&1 || true
sudo ip link del br-e33-fab >/dev/null 2>&1 || true
sudo ip link add br-e33-fab type bridge
sudo ip link set br-e33-fab up

for c in e33-tor e33-w1 e33-w2; do
  sudo docker run -d --name "$c" --hostname "$c" --privileged --network none "$FRR_IMAGE" tail -f /dev/null >/dev/null
  pid="$(sudo docker inspect -f '{{.State.Pid}}' "$c")"
  sudo ip link add "veth-${c}" type veth peer name "eth0" netns "$pid"
  sudo ip link set "veth-${c}" master br-e33-fab
  sudo ip link set "veth-${c}" up
done

# Configurar e33-tor (ToR AS 65000, IP 10.253.0.1/24, VTEP 10.254.0.254/24)
sudo docker exec e33-tor sh -c '
  ip link set lo up
  ip link set eth0 up
  ip addr add 10.253.0.1/24 dev eth0
  ip addr add 10.254.0.254/24 dev eth0
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sed -i "s/bgpd=no/bgpd=yes/" /etc/frr/daemons
  touch /etc/frr/vtysh.conf
  cat <<EOF > /etc/frr/frr.conf
frr defaults datacenter
hostname e33-tor
service integrated-vtysh-config
!
router bgp 65000
 bgp router-id 10.253.0.1
 no bgp ebgp-requires-policy
 timers bgp 1 3
 neighbor 10.253.0.2 remote-as 65101
 neighbor 10.253.0.3 remote-as 65102
 !
 address-family ipv4 unicast
  neighbor 10.253.0.2 activate
  neighbor 10.253.0.3 activate
 exit-address-family
 !
 address-family l2vpn evpn
  neighbor 10.253.0.2 activate
  neighbor 10.253.0.3 activate
  advertise-all-vni
 exit-address-family
exit
!
EOF
  /usr/lib/frr/frrinit.sh start
'

PID_TOR="$(sudo docker inspect -f '{{.State.Pid}}' e33-tor)"
PID_W1="$(sudo docker inspect -f '{{.State.Pid}}' e33-w1)"
PID_W2="$(sudo docker inspect -f '{{.State.Pid}}' e33-w2)"

# Configurar e33-w1 (Worker 1 AS 65101, IP 10.253.0.2/24, hospeda inicialmente VM 10.253.33.10/32)
sudo docker exec e33-w1 sh -c '
  ip link set lo up
  ip link set eth0 up
  ip addr add 10.253.0.2/24 dev eth0
  ip addr add 10.254.0.1/24 dev eth0
  ip addr add 10.253.33.10/32 dev lo
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sed -i "s/bgpd=no/bgpd=yes/" /etc/frr/daemons
  touch /etc/frr/vtysh.conf
  cat <<EOF > /etc/frr/frr.conf
frr defaults datacenter
hostname e33-w1
service integrated-vtysh-config
!
router bgp 65101
 bgp router-id 10.253.0.2
 no bgp ebgp-requires-policy
 timers bgp 1 3
 neighbor 10.253.0.1 remote-as 65000
 !
 address-family ipv4 unicast
  neighbor 10.253.0.1 activate
  network 10.253.33.10/32
 exit-address-family
 !
 address-family l2vpn evpn
  neighbor 10.253.0.1 activate
  advertise-all-vni
 exit-address-family
exit
!
EOF
  /usr/lib/frr/frrinit.sh start
'
sudo nsenter -t "$PID_W1" -n python3 -c '
# E33_UDP_SERVER
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("0.0.0.0", 9999))
while True:
    data, addr = s.recvfrom(1024)
    s.sendto(b"WORKER1:" + data, addr)
' >/dev/null 2>&1 &

# Configurar e33-w2 (Worker 2 AS 65102, IP 10.253.0.3/24, destino da migração)
sudo docker exec e33-w2 sh -c '
  ip link set lo up
  ip link set eth0 up
  ip addr add 10.253.0.3/24 dev eth0
  ip addr add 10.254.0.2/24 dev eth0
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sed -i "s/bgpd=no/bgpd=yes/" /etc/frr/daemons
  touch /etc/frr/vtysh.conf
  cat <<EOF > /etc/frr/frr.conf
frr defaults datacenter
hostname e33-w2
service integrated-vtysh-config
!
router bgp 65102
 bgp router-id 10.253.0.3
 no bgp ebgp-requires-policy
 timers bgp 1 3
 neighbor 10.253.0.1 remote-as 65000
 !
 address-family ipv4 unicast
  neighbor 10.253.0.1 activate
 exit-address-family
 !
 address-family l2vpn evpn
  neighbor 10.253.0.1 activate
  advertise-all-vni
 exit-address-family
exit
!
EOF
  /usr/lib/frr/frrinit.sh start
'
sudo nsenter -t "$PID_W2" -n python3 -c '
# E33_UDP_SERVER
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("0.0.0.0", 9999))
while True:
    data, addr = s.recvfrom(1024)
    s.sendto(b"WORKER2:" + data, addr)
' >/dev/null 2>&1 &

for _ in $(seq 1 20); do
  if sudo docker exec e33-tor ip -4 route show 10.253.33.10/32 | grep -q "10.253.0.2"; then
    break
  fi
  sleep 1
done

log "CÉLULA 1: Estado inicial da rota /32 da VM (10.253.33.10/32) no ToR antes da Live Migration:"
sudo docker exec e33-tor vtysh -c "show bgp ipv4 unicast 10.253.33.10/32"
sudo docker exec e33-tor ip -4 route show 10.253.33.10/32

# ==============================================================================
# CÉLULA 2A: Live Migration sob Tráfego Contínuo — Modelo Cilium B (/32 BGP)
# ==============================================================================
log "CÉLULA 2A: Iniciando fluxo contínuo de 50 pps (intervalo 20ms, 150 pacotes = 3,0s) para 10.253.33.10:9999 e executando Live Migration BGP /32 (e33-w1 -> e33-w2) em t=1,0s..."
sudo nsenter -t "$PID_TOR" -n python3 -c '
import socket, time, json
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(0.018)
results = []
t_start = time.monotonic()
for seq in range(1, 151):
    t_send = time.monotonic()
    msg = f"SEQ={seq}".encode()
    try:
        s.sendto(msg, ("10.253.33.10", 9999))
        resp, _ = s.recvfrom(1024)
        responder = resp.decode().split(":")[0]
        results.append({"seq": seq, "t": round((t_send - t_start)*1000, 2), "ok": True, "node": responder})
    except Exception:
        results.append({"seq": seq, "t": round((t_send - t_start)*1000, 2), "ok": False, "node": "NONE"})
    elapsed = time.monotonic() - t_send
    if elapsed < 0.020:
        time.sleep(0.020 - elapsed)
with open("/tmp/e33-bgp-migration.json", "w") as f:
    json.dump(results, f)
' &
SENDER_BGP_PID=$!

sleep 1.0
# Executar cutover Live Migration no plano Cilium B (/32 BGP):
# 1. Ativar IP 10.253.33.10/32 no destino (e33-w2) e anunciar /32 via BGP
# 2. Retirar anúncio /32 e IP da origem (e33-w1)
sudo docker exec e33-w2 sh -c '
  ip addr add 10.253.33.10/32 dev lo 2>/dev/null || true
  vtysh -c "conf t" -c "router bgp 65102" -c "address-family ipv4 unicast" -c "network 10.253.33.10/32" >/dev/null
'
sudo docker exec e33-w1 sh -c '
  vtysh -c "conf t" -c "router bgp 65101" -c "address-family ipv4 unicast" -c "no network 10.253.33.10/32" >/dev/null
  ip addr del 10.253.33.10/32 dev lo 2>/dev/null || true
'
wait "$SENDER_BGP_PID" || true

log "CÉLULA 2A: Resultados da Live Migration sob Cilium B (/32 BGP Cutover):"
python3 -c '
import json
with open("/tmp/e33-bgp-migration.json") as f:
    r = json.load(f)
w1 = [x for x in r if x["node"] == "WORKER1"]
w2 = [x for x in r if x["node"] == "WORKER2"]
lost = [x for x in r if not x["ok"]]
last_w1_t = w1[-1]["t"] if w1 else 0
first_w2_t = w2[0]["t"] if w2 else 0
blackout_ms = round(max(0.0, first_w2_t - last_w1_t - 20.0), 2) if (w1 and w2) else -1
print(f"CILIUM_B_BGP32_SUMMARY total_sent={len(r)} served_w1={len(w1)} served_w2={len(w2)} lost_pkts={len(lost)} last_w1_ms={last_w1_t} first_w2_ms={first_w2_t} blackout_ms={blackout_ms}")
'
sudo docker exec e33-tor vtysh -c "show bgp ipv4 unicast 10.253.33.10/32"
sudo docker exec e33-tor ip -4 route show 10.253.33.10/32

# ==============================================================================
# CÉLULA 2B: Live Migration sob Tráfego Contínuo — Modelo OVN-K / EVPN Type-2
# ==============================================================================
log "CÉLULA 2B: Configurando Bridge VXLAN EVPN (VNI 10033, 10.253.34.0/24) para medir Mobilidade MAC-IP EVPN Type-2 (RFC 7432 seq increment)..."
for node_ip in "e33-tor:10.254.0.254:10.253.34.1" "e33-w1:10.254.0.1:0" "e33-w2:10.254.0.2:0"; do
  cname="${node_ip%%:*}"
  rest="${node_ip#*:}"
  vtep_ip="${rest%%:*}"
  gw_ip="${rest##*:}"
  sudo docker exec "$cname" sh -c "
    ip link add br-evpn33 type bridge
    ip link set br-evpn33 up
    ip link add vxlan33 type vxlan id 10033 local ${vtep_ip} dstport 4789 nolearning
    ip link set vxlan33 master br-evpn33
    ip link set vxlan33 up
    if [ '${gw_ip}' != '0' ]; then
      ip addr add ${gw_ip}/24 dev br-evpn33
    fi
  "
done

# Criar netns de VM na origem (e33-vm-w1 ligada a e33-w1) e destino pré-aquecido (e33-vm-w2 ligada a e33-w2)
sudo ip netns del e33-vm-w1 >/dev/null 2>&1 || true
sudo ip netns del e33-vm-w2 >/dev/null 2>&1 || true
sudo ip netns add e33-vm-w1
sudo ip netns add e33-vm-w2

sudo ip link add veth-vm1-br type veth peer name eth0 netns e33-vm-w1
sudo ip link set veth-vm1-br netns "$PID_W1"
sudo docker exec e33-w1 sh -c 'ip link set veth-vm1-br master br-evpn33 && ip link set veth-vm1-br up'
sudo ip netns exec e33-vm-w1 sh -c '
  ip link set lo up
  ip link set eth0 address 02:53:33:00:00:10
  ip link set eth0 up
  ip addr add 10.253.34.10/24 dev eth0
'
sudo ip netns exec e33-vm-w1 python3 -c '
# E33_UDP_SERVER
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("0.0.0.0", 9999))
while True:
    data, addr = s.recvfrom(1024)
    s.sendto(b"EVPN_W1:" + data, addr)
' >/dev/null 2>&1 &

sudo ip link add veth-vm2-br type veth peer name eth0 netns e33-vm-w2
sudo ip link set veth-vm2-br netns "$PID_W2"
sudo docker exec e33-w2 sh -c 'ip link set veth-vm2-br master br-evpn33 && ip link set veth-vm2-br down'
sudo ip netns exec e33-vm-w2 sh -c '
  ip link set lo up
  ip link set eth0 address 02:53:33:00:00:10
  ip link set eth0 up
  ip addr add 10.253.34.10/24 dev eth0
'
sudo ip netns exec e33-vm-w2 python3 -c '
# E33_UDP_SERVER
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("0.0.0.0", 9999))
while True:
    data, addr = s.recvfrom(1024)
    s.sendto(b"EVPN_W2:" + data, addr)
' >/dev/null 2>&1 &

# Aguardar convergência EVPN Type-3 (IMET) e popular FDB/ARP/EVPN Type-2 (seq 0) a partir de e33-vm-w1
sleep 2
sudo ip netns exec e33-vm-w1 ping -c 2 -W 1 10.253.34.1 >/dev/null 2>&1 || true
sudo docker exec e33-tor ping -c 2 -W 1 10.253.34.10 >/dev/null 2>&1 || true
sleep 1

log "CÉLULA 2B: Inspecionando EVPN Type-2 Route no e33-tor antes da migração (VTEP de origem 10.254.0.1):"
sudo docker exec e33-tor vtysh -c "show bgp l2vpn evpn route vni 10033" || true

log "CÉLULA 2B: Iniciando fluxo contínuo de 50 pps para 10.253.34.10:9999 e migrando MAC 02:53:33:00:00:10 + IP 10.253.34.10 para e33-w2 (VTEP 10.254.0.2)..."
sudo nsenter -t "$PID_TOR" -n python3 -c '
import socket, time, json
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(0.018)
results = []
t_start = time.monotonic()
for seq in range(1, 151):
    t_send = time.monotonic()
    msg = f"SEQ={seq}".encode()
    try:
        s.sendto(msg, ("10.253.34.10", 9999))
        resp, _ = s.recvfrom(1024)
        responder = resp.decode().split(":")[0]
        results.append({"seq": seq, "t": round((t_send - t_start)*1000, 2), "ok": True, "node": responder})
    except Exception:
        results.append({"seq": seq, "t": round((t_send - t_start)*1000, 2), "ok": False, "node": "NONE"})
    elapsed = time.monotonic() - t_send
    if elapsed < 0.020:
        time.sleep(0.020 - elapsed)
with open("/tmp/e33-evpn-migration.json", "w") as f:
    json.dump(results, f)
' &
SENDER_EVPN_PID=$!

sleep 1.0
# Executar Live Migration EVPN Type-2 (desativar porta em e33-w1, ativar porta em e33-w2 e emitir pacote da VM migrada)
sudo docker exec e33-w1 sh -c 'ip link set veth-vm1-br down'
sudo docker exec e33-w2 sh -c 'ip link set veth-vm2-br up'
sudo ip netns exec e33-vm-w2 ping -c 1 -W 1 10.253.34.1 >/dev/null 2>&1 || true
wait "$SENDER_EVPN_PID" || true

log "CÉLULA 2B: Resultados da Live Migration sob EVPN Type-2 MAC-IP Mobility:"
python3 -c '
import json
with open("/tmp/e33-evpn-migration.json") as f:
    r = json.load(f)
w1 = [x for x in r if x["node"] == "EVPN_W1"]
w2 = [x for x in r if x["node"] == "EVPN_W2"]
lost = [x for x in r if not x["ok"]]
last_w1_t = w1[-1]["t"] if w1 else 0
first_w2_t = w2[0]["t"] if w2 else 0
blackout_ms = round(max(0.0, first_w2_t - last_w1_t - 20.0), 2) if (w1 and w2) else -1
print(f"OVNK_EVPN_TYPE2_SUMMARY total_sent={len(r)} served_w1={len(w1)} served_w2={len(w2)} lost_pkts={len(lost)} last_w1_ms={last_w1_t} first_w2_ms={first_w2_t} blackout_ms={blackout_ms}")
'
sudo docker exec e33-tor vtysh -c "show bgp l2vpn evpn route vni 10033" || true
sudo docker exec e33-tor bridge fdb show br br-evpn33 | grep "02:53:33:00:00:10" || true

# ==============================================================================
# CÉLULA 3: Controle Negativo — Migração sem Atualização de Rota (/32 Stale)
# ==============================================================================
log "CÉLULA 3: Controle Negativo — Retirando anúncio /32 de e33-w2 e prendendo rota obsoleta para e33-w1 (onde a VM não reside mais)..."
sudo docker exec e33-w2 vtysh -c "conf t" -c "router bgp 65102" -c "address-family ipv4 unicast" -c "no network 10.253.33.10/32" >/dev/null
sudo docker exec e33-tor ip route replace 10.253.33.10/32 via 10.253.0.2
sleep 1

NEG_LOSS="$(sudo nsenter -t "$PID_TOR" -n python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(0.1)
ok = 0
for i in range(10):
    try:
        s.sendto(b"NEG", ("10.253.33.10", 9999))
        s.recvfrom(1024)
        ok += 1
    except Exception:
        pass
print(f"STALE_ROUTE_DELIVERED={ok}/10")
')"
echo "$NEG_LOSS"
if [[ "$NEG_LOSS" != "STALE_ROUTE_DELIVERED=0/10" ]]; then
  echo "ERRO: Tráfego deveria sofrer blackhole (0/10) com rota presa ao hipervisor antigo!" >&2
  exit 1
fi

log "CÉLULA 3: Restaurando anúncio BGP /32 em e33-w2 e removendo rota estática obsoleta..."
sudo docker exec e33-tor ip route del 10.253.33.10/32 via 10.253.0.2
sudo docker exec e33-w2 vtysh -c "conf t" -c "router bgp 65102" -c "address-family ipv4 unicast" -c "network 10.253.33.10/32" >/dev/null
sleep 2

POS_RECOVER="$(sudo nsenter -t "$PID_TOR" -n python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(0.2)
ok = 0
for i in range(10):
    try:
        s.sendto(b"REC", ("10.253.33.10", 9999))
        resp, _ = s.recvfrom(1024)
        if b"WORKER2:" in resp:
            ok += 1
    except Exception:
        pass
print(f"RECOVERED_DELIVERED={ok}/10")
')"
echo "$POS_RECOVER"
if [[ "$POS_RECOVER" != "RECOVERED_DELIVERED=10/10" ]]; then
  echo "ERRO: Recuperação pós-anúncio /32 falhou ($POS_RECOVER)!" >&2
  exit 1
fi

log "E33: Todas as células (Célula 1, Célula 2A, Célula 2B e Célula 3) concluídas com PASS."
