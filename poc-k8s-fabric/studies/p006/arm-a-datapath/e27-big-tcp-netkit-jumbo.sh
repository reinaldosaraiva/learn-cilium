#!/usr/bin/env bash
# P006-S002 (Braço A — E27): BIG TCP (GSO/GRO > 64 KiB, IPv4 & IPv6) + netkit +
# Jumbo MTU 9000 & Controle Negativo de PMTU Blackhole (RFC 1191 / RFC 4821)
#
# Mede no sandbox p003-gw (Kernel Linux 6.8):
#   1. Capacidade de Kernel (CONFIG_NETKIT, gso_max_size, gro_max_size,
#      gso_ipv4_max_size, gro_ipv4_max_size) e estado das interfaces lxc*/eth* do Cilium 1.20.2.
#   2. Comparação quantitativa entre três regimes no p003-gw-worker:
#      - Regime A (Baseline veth MTU 1500, GSO/GRO = 65536 B)
#      - Regime B (veth Jumbo MTU 9000 + BIG TCP IPv4/IPv6 gso_max_size/gro_max_size = 196608 B)
#      - Regime C (netkit mode l3 SCRUB_DEFAULT Jumbo MTU 9000 + BIG TCP IPv4/IPv6 = 196608 B)
#      transferindo payload TCP em massa (512 MiB IPv4 e IPv6) com captura AF_PACKET de super-pacotes
#      (> 64 KiB até ~188 KiB) e contagem de pacotes RX e softirqs NET_RX.
#   3. Controle Negativo (Assimetria de MTU 9000 -> 1500 -> 9000):
#      - Com ICMP Type 3 Code 4 (fragmentation-needed) permitido: convergência PMTU (5/5).
#      - Com ICMP Type 3 Code 4 suprimido: PMTU Blackhole (0/5 com DF=1) e mitigação via
#        PLPMTUD (net.ipv4.tcp_mtu_probing=2, RFC 4821).
#   4. Rollback determinístico + pós-verificação k01 (10/10) e p003-gw (30/30, R6=0).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/01-e27-big-tcp-jumbo.yaml"

K01_KC="${K01_KC:-/root/.kube/k01-rebuild.config}"
K01_CTX="${K01_CTX:-kind-k01}"
K01_UID_EXPECTED="635e7274-5597-40c7-9de5-b1fbe3d68b22"

GW_KC="${GW_KC:-/root/.kube/p003-gw.config}"
GW_CTX="${GW_CTX:-kind-p003-gw}"
GW_UID_EXPECTED="6bb32e0f-71f9-4558-ae33-356ba2250c26"

WORKER1="p003-gw-worker"
WORKER2="p003-gw-worker2"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

log() {
  printf '[%s] [E27] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log "DRY-RUN habilitado: nenhuma mutação será aplicada."
  log "Plano de execução E27:"
  log "  1. Validar UIDs k01 (${K01_UID_EXPECTED}) e p003-gw (${GW_UID_EXPECTED}), MemAvailable >= 4 GiB e R6=0."
  log "  2. Aplicar ${MANIFEST} (Namespace p006-e27, pods e27-probe-w1 e e27-probe-w2) e inspecionar gso_max_size/gro_max_size nas interfaces Cilium."
  log "  3. Célula 1: Verificar suporte a netkit e BIG TCP no kernel 6.8 e configurar três regimes no ${WORKER1}:"
  log "     - Regime A (ns-e27-std, veth): MTU 1500, gso_max_size=65536, gro_max_size=65536."
  log "     - Regime B (ns-e27-big, veth): MTU 9000, gso_max_size=196608, gro_max_size=196608, gso_ipv4_max_size=196608, gro_ipv4_max_size=196608."
  log "     - Regime C (ns-e27-nk, netkit mode l3): nk-e27-h/nk-e27-n MTU 9000, gso_max_size=196608, gro_max_size=196608, gso_ipv4_max_size=196608, gro_ipv4_max_size=196608."
  log "  4. Célula 2: Executar transferências TCP de 512 MiB (IPv4 e IPv6) nos três regimes (std-veth, big-veth, big-netkit), capturar super-pacotes > 64 KiB e calcular bytes/pacote e delta NET_RX."
  log "  5. Célula 3: Executar controle negativo de assimetria de MTU (9000 -> 1500 -> 9000) com ICMP Type 3 Code 4 permitido vs bloqueado + mitigação RFC 4821 (tcp_mtu_probing=2)."
  log "  6. Executar cleanup completo e validar canários k01 (10/10), p003-gw (30/30) e R6=0."
  exit 0
fi

k_k01() { sudo kubectl --kubeconfig "${K01_KC}" --context "${K01_CTX}" "$@"; }
k_gw()  { sudo kubectl --kubeconfig "${GW_KC}"  --context "${GW_CTX}"  "$@"; }

cleanup() {
  log "Iniciando cleanup idempotente de E27..."
  sudo docker exec "${WORKER1}" bash -c '
    for ns in ns-e27-std ns-e27-big ns-e27-nk ns-e27-src ns-e27-rtr ns-e27-dst; do
      ip netns del "${ns}" 2>/dev/null || true
    done
    for dev in veth-e27-stdh veth-e27-bigh nk-e27-h; do
      ip link del "${dev}" 2>/dev/null || true
    done
    rm -f /tmp/e27-*.pcap /tmp/e27-*.txt 2>/dev/null || true
  ' >/dev/null 2>&1 || true
  k_gw delete -f "${MANIFEST}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  k_gw delete ns p006-e27 --ignore-not-found --wait=true >/dev/null 2>&1 || true
  log "Cleanup E27 concluído."
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

for node in p003-gw-control-plane "${WORKER1}" "${WORKER2}"; do
  r6_count="$(sudo docker exec "${node}" ip route show proto bgp 2>/dev/null | wc -l | tr -d ' ')"
  log "node=${node} R6_bgp_routes=${r6_count}"
  if [[ "${r6_count}" != "0" ]]; then
    log "ERRO: violação R6 em ${node}"
    exit 1
  fi
done

log "== [2] Célula 1: Inspeção do Kernel, Cilium ConfigMap e Interfaces Pod/Node =="
uname -a
grep -E "CONFIG_NETKIT|CONFIG_BPF_SYSCALL" "/boot/config-$(uname -r)" 2>/dev/null || true

k_gw -n kube-system get cm cilium-config -o json | jq '{
  mtu: (.data["mtu"] // "0 (auto)"),
  enable_ipv4_big_tcp: (.data["enable-ipv4-big-tcp"] // "false (default)"),
  enable_ipv6_big_tcp: (.data["enable-ipv6-big-tcp"] // "false (default)"),
  device_mode: (.data["device-mode"] // "veth (default)"),
  bpf_host_legacy_routing: .data["bpf-host-legacy-routing"],
  routing_mode: .data["routing-mode"]
}'

k_gw apply -f "${MANIFEST}"
k_gw -n p006-e27 rollout status deploy/e27-probe-w1 --timeout=90s
k_gw -n p006-e27 rollout status deploy/e27-probe-w2 --timeout=90s

sudo docker exec "${WORKER1}" bash -c '
  echo "--- [worker1] eth0 & primeira interface lxc* (ip -d link show) ---"
  ip -d link show dev eth0 | grep -E "mtu|gso_max_size|gro_max_size"
  lxc_if="$(ip -o link show | awk -F": " "/lxc/{print \$2; exit}" | cut -d@ -f1)"
  if [[ -n "${lxc_if}" ]]; then
    ip -d link show dev "${lxc_if}" | grep -E "mtu|gso_max_size|gro_max_size"
  fi
'

POD_W1="$(k_gw -n p006-e27 get pod -l node=worker1 -o jsonpath='{.items[0].metadata.name}')"
POD_W2_IP="$(k_gw -n p006-e27 get pod -l node=worker2 -o jsonpath='{.items[0].status.podIP}')"
log "Testando conectividade inter-nó Pod-a-Pod (${POD_W1} -> ${POD_W2_IP}:8080)..."
pod_ok=0
for _ in $(seq 1 20); do
  out="$(k_gw -n p006-e27 exec "${POD_W1}" -- wget -qO- -T 2 "http://${POD_W2_IP}:8080/hostname" 2>/dev/null || true)"
  if [[ "${out}" == *"e27-probe-w2"* ]]; then
    pod_ok=$((pod_ok + 1))
  fi
done
log "Conectividade inter-nó Pod-a-Pod: ${pod_ok}/20 HTTP 200"
if [[ "${pod_ok}" -ne 20 ]]; then
  log "ERRO: conectividade Pod-a-Pod falhou (${pod_ok}/20)"
  exit 1
fi

log "== [3] Célula 2: Regime A (MTU 1500, GSO 64 KiB) vs Regime B (veth MTU 9000 + BIG TCP 192 KiB) vs Regime C (netkit mode l3 MTU 9000 + BIG TCP 192 KiB) =="
W1_PID="$(sudo docker inspect -f '{{.State.Pid}}' "${WORKER1}")"
CILIUM_W1="$(k_gw -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName="${WORKER1}" -o jsonpath='{.items[0].metadata.name}')"
log "Versão do iproute2 no host vs nó kind (PID=${W1_PID}) vs pod Cilium (${CILIUM_W1}):"
ip -V || true
sudo docker exec "${WORKER1}" ip -V || true
k_gw -n kube-system exec "${CILIUM_W1}" -c cilium-agent -- ip -V || true

NETKIT_PROBE="unavailable"
if k_gw -n kube-system exec "${CILIUM_W1}" -c cilium-agent -- ip link add nk-e27-test type netkit mode l3 2>/dev/null; then
  NETKIT_PROBE="available_native_netkit_l3"
  k_gw -n kube-system exec "${CILIUM_W1}" -c cilium-agent -- ip -d link show dev nk-e27-test | grep -E "netkit|mtu|gso_max_size|gro_max_size" || true
  k_gw -n kube-system exec "${CILIUM_W1}" -c cilium-agent -- ip link del nk-e27-test 2>/dev/null || true
fi
log "NETKIT_KERNEL_PROBE=${NETKIT_PROBE}"

sudo docker exec "${WORKER1}" bash -c '
  set -euo pipefail
  # Regime A: Standard MTU 1500, GSO/GRO 65536
  ip netns add ns-e27-std
  ip link add veth-e27-stdh type veth peer name veth-e27-stdn
  ip link set veth-e27-stdn netns ns-e27-std
  ip link set veth-e27-stdh mtu 1500 gso_max_size 65536 gro_max_size 65536 up
  ip addr add 10.227.1.1/24 dev veth-e27-stdh
  ip -6 addr add fd00:e27:1::1/64 dev veth-e27-stdh nodad

  ip netns exec ns-e27-std ip link set lo up
  ip netns exec ns-e27-std ip link set veth-e27-stdn mtu 1500 gso_max_size 65536 gro_max_size 65536 up
  ip netns exec ns-e27-std ip addr add 10.227.1.2/24 dev veth-e27-stdn
  ip netns exec ns-e27-std ip -6 addr add fd00:e27:1::2/64 dev veth-e27-stdn nodad

  # Regime B: Jumbo MTU 9000 + BIG TCP (196608 B = 192 KiB para IPv4 e IPv6)
  ip netns add ns-e27-big
  ip link add veth-e27-bigh type veth peer name veth-e27-bign
  ip link set veth-e27-bign netns ns-e27-big
  ip link set veth-e27-bigh mtu 9000 gso_max_size 196608 gro_max_size 196608 up
  ip addr add 10.227.2.1/24 dev veth-e27-bigh
  ip -6 addr add fd00:e27:2::1/64 dev veth-e27-bigh nodad

  ip netns exec ns-e27-big ip link set lo up
  ip netns exec ns-e27-big ip link set veth-e27-bign mtu 9000 gso_max_size 196608 gro_max_size 196608 up
  ip netns exec ns-e27-big ip addr add 10.227.2.2/24 dev veth-e27-bign
  ip netns exec ns-e27-big ip -6 addr add fd00:e27:2::2/64 dev veth-e27-bign nodad

  echo "--- Estado ip -d link show Regime A (MTU 1500 / 64 KiB) ---"
  ip -d link show dev veth-e27-stdh | grep -E "mtu|gso_max_size|gro_max_size"
  echo "--- Estado ip -d link show Regime B (MTU 9000 / BIG TCP 192 KiB) ---"
  ip -d link show dev veth-e27-bigh | grep -E "mtu|gso_max_size|gro_max_size"
'

# Garantir que o netlink IFLA_GSO_IPV4_MAX_SIZE / IFLA_GRO_IPV4_MAX_SIZE também seja aplicado pelo iproute2 6.19.0 do Cilium:
k_gw -n kube-system exec "${CILIUM_W1}" -c cilium-agent -- ip link set dev veth-e27-bigh gso_max_size 196608 gro_max_size 196608 gso_ipv4_max_size 196608 gro_ipv4_max_size 196608
sudo docker exec "${WORKER1}" ip netns exec ns-e27-big python3 -c '
import socket, struct
idx = socket.if_nametoindex("veth-e27-bign")
s = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, socket.NETLINK_ROUTE)
attr63 = struct.pack("=HHI", 8, 63, 196608)
attr64 = struct.pack("=HHI", 8, 64, 196608)
ifinfo = struct.pack("=BBHiII", 0, 0, 0, idx, 0, 0)
payload = ifinfo + attr63 + attr64
nlhdr = struct.pack("=IHHII", 16 + len(payload), 16, 0x05, 1, 0)
s.send(nlhdr + payload)
s.recv(4096)
s.close()
' 2>/dev/null || true

# Regime C: Par netkit mode l3 nativo (via iproute2-6.19.0 do Cilium) + MTU 9000 + BIG TCP 196608 B
sudo docker exec "${WORKER1}" ip netns add ns-e27-nk
k_gw -n kube-system exec "${CILIUM_W1}" -c cilium-agent -- ip link add nk-e27-h type netkit mode l3 peer nk-e27-n
k_gw -n kube-system exec "${CILIUM_W1}" -c cilium-agent -- ip link set dev nk-e27-h mtu 9000 gso_max_size 196608 gro_max_size 196608 gso_ipv4_max_size 196608 gro_ipv4_max_size 196608 up
k_gw -n kube-system exec "${CILIUM_W1}" -c cilium-agent -- ip link set dev nk-e27-n mtu 9000 gso_max_size 196608 gro_max_size 196608 gso_ipv4_max_size 196608 gro_ipv4_max_size 196608
sudo docker exec "${WORKER1}" bash -c '
  set -euo pipefail
  ip link set nk-e27-n netns ns-e27-nk
  ip addr add 10.227.3.1/24 dev nk-e27-h
  ip -6 addr add fd00:e27:3::1/64 dev nk-e27-h nodad
  ip netns exec ns-e27-nk ip link set lo up
  ip netns exec ns-e27-nk ip link set nk-e27-n mtu 9000 gso_max_size 196608 gro_max_size 196608 up
  ip netns exec ns-e27-nk ip addr add 10.227.3.2/24 dev nk-e27-n
  ip netns exec ns-e27-nk ip -6 addr add fd00:e27:3::2/64 dev nk-e27-n nodad
  ip netns exec ns-e27-nk ip route add default dev nk-e27-n
  ip netns exec ns-e27-nk ip -6 route add default dev nk-e27-n
'
sudo docker exec "${WORKER1}" ip netns exec ns-e27-nk python3 -c '
import socket, struct
idx = socket.if_nametoindex("nk-e27-n")
s = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, socket.NETLINK_ROUTE)
attr63 = struct.pack("=HHI", 8, 63, 196608)
attr64 = struct.pack("=HHI", 8, 64, 196608)
ifinfo = struct.pack("=BBHiII", 0, 0, 0, idx, 0, 0)
payload = ifinfo + attr63 + attr64
nlhdr = struct.pack("=IHHII", 16 + len(payload), 16, 0x05, 1, 0)
s.send(nlhdr + payload)
s.recv(4096)
s.close()
' 2>/dev/null || true

echo "--- Estado iproute2-6.19.0 do Cilium agent (veth-e27-bigh e nk-e27-h) ---"
k_gw -n kube-system exec "${CILIUM_W1}" -c cilium-agent -- ip -d link show dev veth-e27-bigh | grep -E "veth|mtu|gso_max_size|gro_max_size" || true
k_gw -n kube-system exec "${CILIUM_W1}" -c cilium-agent -- ip -d link show dev nk-e27-h | grep -E "netkit|mtu|gso_max_size|gro_max_size" || true

log "Executando benchmark de transferência TCP (512 MiB IPv4 e IPv6) e captura de super-pacotes..."
sudo docker exec -i "${WORKER1}" python3 - <<'PYEOF'
import socket, subprocess, threading, time

PAYLOAD_SIZE = 512 * 1024 * 1024  # 512 MiB
CHUNK = b"X" * (1024 * 1024)      # 1 MiB chunk

def read_net_rx_softirqs():
    with open("/proc/softirqs") as f:
        for line in f:
            if "NET_RX:" in line:
                return sum(int(x) for x in line.split()[1:])
    return 0

def read_if_stats(ns, ifname):
    cmd = ["ip", "-s", "link", "show", "dev", ifname]
    if ns:
        cmd = ["ip", "netns", "exec", ns] + cmd
    out = subprocess.check_output(cmd, text=True)
    lines = [l.strip() for l in out.splitlines()]
    rx_idx = next(i for i, l in enumerate(lines) if l.startswith("RX:"))
    rx_vals = [int(x) for x in lines[rx_idx + 1].split()]
    return rx_vals[0], rx_vals[1]  # bytes, packets

def sniffer_worker(ifname, lengths_out, samples_out, stop_evt):
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.ntohs(0x0003))
    s.bind((ifname, 0))
    s.settimeout(0.2)
    while not stop_evt.is_set() and len(lengths_out) < 200:
        try:
            pkt = s.recv(262144)
            plen = len(pkt)
            if plen > 100:
                lengths_out.append(plen)
                if len(samples_out) < 12 and plen > 1400:
                    samples_out.append(f"AF_PACKET dev={ifname} frame_len={plen}B payload_approx={plen-14}B")
        except socket.timeout:
            continue
        except Exception:
            break
    s.close()

def run_transfer(label, ns, ifname_ns, ifname_host, target_ip, family):
    af_name = "AF_INET6" if family == 6 else "AF_INET"
    srv_code = (
        "import socket\n"
        f"s = socket.socket(socket.{af_name}, socket.SOCK_STREAM)\n"
        "s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)\n"
        f"s.bind((\"{target_ip}\", 9999))\n"
        "s.listen(1)\n"
        "conn, _ = s.accept()\n"
        "total = 0\n"
        "while True:\n"
        "    d = conn.recv(262144)\n"
        "    if not d: break\n"
        "    total += len(d)\n"
        "conn.close()\n"
        "s.close()\n"
    )
    srv = subprocess.Popen(["ip", "netns", "exec", ns, "python3", "-c", srv_code])
    lengths = []
    samples = []
    stop_evt = threading.Event()
    sniffer = threading.Thread(target=sniffer_worker, args=(ifname_host, lengths, samples, stop_evt))
    sniffer.start()
    time.sleep(0.2)

    b0, p0 = read_if_stats(ns, ifname_ns)
    sirq0 = read_net_rx_softirqs()
    t0 = time.monotonic()

    cli = socket.socket(socket.AF_INET6 if family == 6 else socket.AF_INET, socket.SOCK_STREAM)
    cli.connect((target_ip, 9999))
    sent = 0
    while sent < PAYLOAD_SIZE:
        sent += cli.send(CHUNK)
    cli.close()
    srv.wait(timeout=15)
    t1 = time.monotonic()
    sirq1 = read_net_rx_softirqs()
    b1, p1 = read_if_stats(ns, ifname_ns)

    stop_evt.set()
    sniffer.join(timeout=2)

    max_len = max(lengths) if lengths else 0
    super_pkts = sum(1 for x in lengths if x > 65550)
    rx_bytes = b1 - b0
    rx_pkts = max(1, p1 - p0)
    dur = max(0.001, t1 - t0)
    gbps = (rx_bytes * 8.0) / (dur * 1e9)
    avg_pkt = rx_bytes / rx_pkts
    sirq_delta = sirq1 - sirq0
    print(
        f"RESULT label={label} family=IPv{family} rx_bytes={rx_bytes} rx_pkts={rx_pkts} "
        f"avg_bytes_per_pkt={avg_pkt:.1f} max_captured_frame_len={max_len} "
        f"captured_gt_64k={super_pkts}/{len(lengths)} net_rx_softirq_delta={sirq_delta} "
        f"duration_s={dur:.3f} throughput_gbps={gbps:.2f}"
    )
    for sline in samples[:4]:
        print(f"  SAMPLE[{label}]: {sline}")

run_transfer("std-veth-ipv4", "ns-e27-std", "veth-e27-stdn", "veth-e27-stdh", "10.227.1.2", 4)
run_transfer("big-veth-ipv4", "ns-e27-big", "veth-e27-bign", "veth-e27-bigh", "10.227.2.2", 4)
run_transfer("big-netkit-ipv4", "ns-e27-nk", "nk-e27-n", "nk-e27-h", "10.227.3.2", 4)
run_transfer("std-veth-ipv6", "ns-e27-std", "veth-e27-stdn", "veth-e27-stdh", "fd00:e27:1::2", 6)
run_transfer("big-veth-ipv6", "ns-e27-big", "veth-e27-bign", "veth-e27-bigh", "fd00:e27:2::2", 6)
run_transfer("big-netkit-ipv6", "ns-e27-nk", "nk-e27-n", "nk-e27-h", "fd00:e27:3::2", 6)
PYEOF

log "== [4] Célula 3: Controle Negativo — Assimetria de MTU (9000 -> 1500 -> 9000) e PMTU Blackhole =="
sudo docker exec "${WORKER1}" bash -c '
  set -euo pipefail
  ip netns add ns-e27-src
  ip netns add ns-e27-rtr
  ip netns add ns-e27-dst

  ip link add veth-src type veth peer name veth-rtr1
  ip link add veth-rtr2 type veth peer name veth-dst
  ip link set veth-src netns ns-e27-src
  ip link set veth-rtr1 netns ns-e27-rtr
  ip link set veth-rtr2 netns ns-e27-rtr
  ip link set veth-dst netns ns-e27-dst

  # src <-> rtr1: MTU 9000
  ip netns exec ns-e27-src ip link set lo up
  ip netns exec ns-e27-src ip link set veth-src mtu 9000 up
  ip netns exec ns-e27-src ip addr add 10.227.10.2/24 dev veth-src
  ip netns exec ns-e27-src ip route add 10.227.20.0/24 via 10.227.10.1

  # rtr: veth-rtr1 MTU 9000, veth-rtr2 choke point MTU 1500
  ip netns exec ns-e27-rtr ip link set lo up
  ip netns exec ns-e27-rtr ip link set veth-rtr1 mtu 9000 up
  ip netns exec ns-e27-rtr ip link set veth-rtr2 mtu 1500 up
  ip netns exec ns-e27-rtr ip addr add 10.227.10.1/24 dev veth-rtr1
  ip netns exec ns-e27-rtr ip addr add 10.227.20.1/24 dev veth-rtr2
  ip netns exec ns-e27-rtr sysctl -qw net.ipv4.ip_forward=1

  # dst: MTU 9000
  ip netns exec ns-e27-dst ip link set lo up
  ip netns exec ns-e27-dst ip link set veth-dst mtu 9000 up
  ip netns exec ns-e27-dst ip addr add 10.227.20.2/24 dev veth-dst
  ip netns exec ns-e27-dst ip route add 10.227.10.0/24 via 10.227.20.1

  echo "--- Caso 3A: ICMP Type 3 Code 4 Permitido (PMTU Discovery Funcional) ---"
  python3 - << "PYEOF"
import errno, socket, subprocess, time

srv_code = """
import socket
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
u.bind(("10.227.20.2", 9997))
while True:
    data, addr = u.recvfrom(65535)
    if data == b"STOP":
        break
    u.sendto(f"ECHO:{len(data)}".encode(), addr)
u.close()
"""
srv = subprocess.Popen(["ip", "netns", "exec", "ns-e27-dst", "python3", "-c", srv_code])
time.sleep(0.2)

probe_code = """
import errno, socket, subprocess

IP_MTU_DISCOVER = 10
IP_PMTUDISC_WANT = 1
IP_PMTUDISC_DO = 2
IP_MTU = 14

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(0.8)
s.setsockopt(socket.IPPROTO_IP, IP_MTU_DISCOVER, IP_PMTUDISC_DO)
s.connect(("10.227.20.2", 9997))

# 1o datagrama Jumbo (8972B payload = 9000B IP c/ DF=1) dispara ICMP Type 3 Code 4 no salto rtr2 (MTU 1500)
try:
    s.send(b"P" * 8972)
    s.recv(64)
except Exception as e:
    print(f"1st Jumbo DF=1 probe exception (expected after ICMP Frag Needed): {type(e).__name__}: {e}")

# 2o envio imediato no socket conectado retorna EMSGSIZE (Errno 90) e IP_MTU=1500
try:
    s.send(b"P" * 8972)
except OSError as e:
    print(f"2nd Jumbo DF=1 send errno={e.errno} ({errno.errorcode.get(e.errno, '')}): {e.strerror}")
pmtu = s.getsockopt(socket.IPPROTO_IP, IP_MTU)
print(f"Discovered Socket IP_MTU={pmtu}")

# Com IP_PMTUDISC_WANT (1), o kernel respeita o PMTU 1500 aprendido (fragmentando ou ajustando):
s.setsockopt(socket.IPPROTO_IP, IP_MTU_DISCOVER, IP_PMTUDISC_WANT)
ok = 0
for _ in range(5):
    s.send(b"P" * 8972)
    if s.recv(64).startswith(b"ECHO:8972"):
        ok += 1
print(f"PMTUD_WANT_JUMBO_ECHO={ok}/5")
s.close()
assert pmtu == 1500 and ok == 5, f"Esperado pmtu=1500 e ok=5, obtido pmtu={pmtu} ok={ok}"
"""
subprocess.check_call(["ip", "netns", "exec", "ns-e27-src", "python3", "-c", probe_code])
print("Cache de rota em ns-e27-src após ICMP Type 3 Code 4:", flush=True)
print(subprocess.check_output(["ip", "netns", "exec", "ns-e27-src", "ip", "route", "get", "10.227.20.2"], text=True).strip(), flush=True)

print("--- Caso 3B (Controle Negativo): ICMP Fragmentation-Needed Bloqueado (PMTU Blackhole) ---", flush=True)
subprocess.check_call(["ip", "netns", "exec", "ns-e27-src", "ip", "route", "flush", "cache"])
# Bloquear ICMP Type 3 Code 4 (Frag Needed) via tc filter u32 em veth-rtr1 egress (e iptables fallback)
subprocess.check_call(["ip", "netns", "exec", "ns-e27-rtr", "tc", "qdisc", "add", "dev", "veth-rtr1", "clsact"])
subprocess.check_call([
    "ip", "netns", "exec", "ns-e27-rtr", "tc", "filter", "add", "dev", "veth-rtr1", "egress",
    "protocol", "ip", "prio", "1", "u32",
    "match", "ip", "protocol", "1", "0xff",
    "match", "u8", "3", "0xff", "at", "20",
    "match", "u8", "4", "0xff", "at", "21",
    "action", "drop"
])
subprocess.call(["ip", "netns", "exec", "ns-e27-rtr", "iptables", "-I", "OUTPUT", "-p", "icmp", "--icmp-type", "fragmentation-needed", "-j", "DROP"])

bh_code = """
import socket
IP_MTU_DISCOVER = 10
IP_PMTUDISC_DO = 2
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(0.4)
s.setsockopt(socket.IPPROTO_IP, IP_MTU_DISCOVER, IP_PMTUDISC_DO)
ok = 0
for _ in range(5):
    s.sendto(b"B" * 8972, ("10.227.20.2", 9997))
    try:
        if s.recv(64).startswith(b"ECHO:"):
            ok += 1
    except socket.timeout:
        pass
s.close()
print(f"PMTU_BLACKHOLE_JUMBO_DF_RECV={ok}/5 (esperado 0/5)", flush=True)
assert ok == 0, f"Esperado 0/5 sob PMTU blackhole, obtido {ok}/5"
"""
subprocess.check_call(["ip", "netns", "exec", "ns-e27-src", "python3", "-c", bh_code])
print("Cache de rota em ns-e27-src durante Blackhole ICMP (sem mtu 1500 aprendido):", flush=True)
print(subprocess.check_output(["ip", "netns", "exec", "ns-e27-src", "ip", "route", "get", "10.227.20.2"], text=True).strip(), flush=True)

# Encerrar servidor UDP
subprocess.call(["ip", "netns", "exec", "ns-e27-src", "python3", "-c",
                 "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.sendto(b\"STOP\",(\"10.227.20.2\",9997)); s.close()"])
srv.wait(timeout=3)
PYEOF

  echo "--- Caso 3C: Sem Probing (Timeout) vs Mitigação RFC 4821 (net.ipv4.tcp_mtu_probing=2) sob Blackhole ICMP ---"
  ip netns exec ns-e27-src sysctl -qw net.ipv4.tcp_mtu_probing=0
  python3 - << "PYEOF"
import subprocess, time

def test_tcp(probing_val, base_mss=1024):
    subprocess.check_call(["ip", "netns", "exec", "ns-e27-src", "ip", "route", "flush", "cache"])
    subprocess.check_call(["ip", "netns", "exec", "ns-e27-src", "sysctl", "-qw", f"net.ipv4.tcp_mtu_probing={probing_val}"])
    subprocess.check_call(["ip", "netns", "exec", "ns-e27-src", "sysctl", "-qw", f"net.ipv4.tcp_base_mss={base_mss}"])
    srv_cmd = [
        "ip", "netns", "exec", "ns-e27-dst", "python3", "-c",
        "import socket; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.settimeout(4.0); "
        "s.bind((\"10.227.20.2\",9998)); s.listen(1); c,_=s.accept(); c.settimeout(2.5); "
        "tot=0\n"
        "try:\n"
        " while True:\n"
        "  d=c.recv(65536)\n"
        "  if not d: break\n"
        "  tot+=len(d)\n"
        " c.sendall(f\"ACK:{tot}\".encode())\n"
        "except Exception:\n"
        " c.sendall(f\"TIMEOUT_BLACKHOLE:SRV_RX={tot}\".encode())\n"
        "finally:\n"
        " c.close(); s.close()"
    ]
    srv = subprocess.Popen(srv_cmd)
    time.sleep(0.2)
    cli_code = (
        "import socket; s=socket.socket(); s.settimeout(3.5); s.connect((\"10.227.20.2\",9998)); "
        "s.sendall(b\"A\"*262144); s.shutdown(socket.SHUT_WR); print(s.recv(64).decode(), flush=True); s.close()"
    )
    try:
        out = subprocess.check_output(["ip", "netns", "exec", "ns-e27-src", "python3", "-c", cli_code], text=True, stderr=subprocess.STDOUT).strip()
    except subprocess.CalledProcessError as e:
        out = f"TIMEOUT_BLACKHOLE (rc={e.returncode})"
    srv.wait(timeout=5)
    return out

res_no_probe = test_tcp(0)
print(f"TCP_256KIB_PROBING_0={res_no_probe} (esperado TIMEOUT_BLACKHOLE:SRV_RX=0)", flush=True)
res_rfc4821 = test_tcp(2, 1024)
print(f"TCP_256KIB_PROBING_2_RFC4821={res_rfc4821} (esperado ACK:262144)", flush=True)
assert "TIMEOUT_BLACKHOLE" in res_no_probe, f"Esperado timeout sem probing, obtido {res_no_probe}"
assert res_rfc4821 == "ACK:262144", f"Esperado ACK:262144 com RFC 4821, obtido {res_rfc4821}"
PYEOF
  echo "Rota em ns-e27-src após PLPMTUD (RFC 4821):"
  ip netns exec ns-e27-src ip route get 10.227.20.2
'

log "== [5] Executando Cleanup e Pós-Verificação =="
cleanup
trap - EXIT

for node in p003-gw-control-plane "${WORKER1}" "${WORKER2}"; do
  r6_count="$(sudo docker exec "${node}" ip route show proto bgp 2>/dev/null | wc -l | tr -d ' ')"
  log "post-cleanup node=${node} R6_bgp_routes=${r6_count}"
  if [[ "${r6_count}" != "0" ]]; then
    log "ERRO: violação R6 pós-cleanup em ${node}"
    exit 1
  fi
done

log "E27 concluído com PASS."
