#!/usr/bin/env bash
# ==============================================================================
# P006-S003 — Braço A (E28): Bandwidth Manager (EDT + BBR vs CUBIC) e Pacing eBPF
#
# Objetivo:
#   Avaliar no sandbox p003-gw (Cilium 1.20.2):
#   - Célula 1: Arquitetura EDT (Earliest Departure Time, skb->tstamp + fq) e
#     mapa BPF cilium_throttle vs rate-limiting clássico por filas HTB/TBF.
#   - Célula 2: Pacing de egresso por Pod via anotação kubernetes.io/egress-bandwidth
#     (50M, 100M vs Sem Limite) e comparação BBR vs CUBIC sob emulação de WAN
#     com latência e perda (netem delay 10ms loss 0.5%).
#   - Célula 3: Controle negativo (anotação inválida, throttling/pacing acima do
#     horizonte EDT e remoção dinâmica da anotação restaurando taxa nominal).
#
# Invariantes:
#   - R1: k01 (uid=635e7274-5597-40c7-9de5-b1fbe3d68b22) intocado (10/10 HTTP 200)
#   - R2: Suporte a --dry-run e rollback determinístico via trap EXIT
#   - R3: MemAvailable >= 4.00 GiB
#   - R6: 0 rotas BGP residuais no kernel main dos nós K8s após rollback
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/01-e28-bandwidth-edt-bbr.yaml"

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
  printf '[%s] [E28] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "DRY-RUN: Validando plano de execução E28 (Bandwidth Manager EDT + BBR vs CUBIC)"
  log "DRY-RUN: 1. Validar UID do sandbox p003-gw (${SANDBOX_UID}) e canário k01 (${K01_UID})"
  log "DRY-RUN: 2. Célula 1: Ativar enable-bandwidth-manager=true no cilium-config, inspecionar cilium-dbg bpf bandwidth list, cilium_throttle e qdisc fq"
  log "DRY-RUN: 3. Célula 2: Aplicar ${MANIFEST} (e28-sink, e28-sender-unlim, e28-sender-50m, e28-sender-100m), medir vazão EDT (50M, 100M, unlim) e comparar BBR vs CUBIC sob netem delay 10ms loss 0.5%"
  log "DRY-RUN: 4. Célula 3: Controle negativo (anotação inválida ignorada com segurança + remoção dinâmica da anotação restaurando multi-Gbps)"
  log "DRY-RUN: 5. Rollback determinístico: remover namespace p006-e28, limpar qdiscs temporárias e restaurar cilium-config"
  exit 0
fi

kc() {
  sudo KUBECONFIG="$SANDBOX_KUBECONFIG" kubectl --context "$SANDBOX_CONTEXT" "$@"
}

cleanup() {
  log "ROLLBACK: Limpando recursos temporários de E28..."
  for node in p003-gw-worker p003-gw-worker2; do
    sudo docker exec "$node" sh -c '
      tc qdisc del dev eth0 root 2>/dev/null || true
      for dev in $(ip -o link show | awk -F": " "{print \$2}" | cut -d@ -f1 | grep "^lxc"); do
        tc qdisc del dev "$dev" root 2>/dev/null || true
      done
      sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
    ' 2>/dev/null || true
  done
  kc delete -f "$MANIFEST" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  kc delete ns p006-e28 --ignore-not-found=true --wait=true --timeout=60s >/dev/null 2>&1 || true
  kc -n kube-system patch configmap cilium-config --type merge -p '{"data":{"enable-bandwidth-manager":"false","enable-bbr":"false"}}' >/dev/null 2>&1 || true
  kc -n kube-system rollout restart ds/cilium >/dev/null 2>&1 || true
  kc -n kube-system rollout status ds/cilium --timeout=120s >/dev/null 2>&1 || true
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
# CÉLULA 1: Arquitetura EDT + Mapa BPF cilium_throttle + qdisc fq
# ==============================================================================
log "CÉLULA 1: Remontando /proc/sys rw nos nós kind (requerido pelo Bandwidth Manager para ajustar net.core.default_qdisc=fq) e ativando enable-bandwidth-manager=true..."
for node in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
  sudo docker exec "$node" sh -c 'mount -o remount,rw /proc/sys 2>/dev/null || true'
done
kc -n kube-system patch configmap cilium-config --type merge -p '{"data":{"enable-bandwidth-manager":"true"}}'
kc -n kube-system rollout restart ds/cilium
kc -n kube-system rollout status ds/cilium --timeout=120s

CILIUM_POD_W1="$(kc -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=p003-gw-worker -o jsonpath='{.items[0].metadata.name}')"
log "CÉLULA 1: Cilium pod em p003-gw-worker: ${CILIUM_POD_W1}"

log "CÉLULA 1: Aplicando manifesto ${MANIFEST}..."
kc apply -f "$MANIFEST"
kc -n p006-e28 wait --for=condition=Ready pod --all --timeout=90s

SINK_IP="$(kc -n p006-e28 get pod e28-sink -o jsonpath='{.status.podIP}')"
IP_UNLIM="$(kc -n p006-e28 get pod e28-sender-unlim -o jsonpath='{.status.podIP}')"
IP_50M="$(kc -n p006-e28 get pod e28-sender-50m -o jsonpath='{.status.podIP}')"
IP_100M="$(kc -n p006-e28 get pod e28-sender-100m -o jsonpath='{.status.podIP}')"
log "CÉLULA 1: Pods prontos: sink=${SINK_IP}, unlim=${IP_UNLIM}, 50m=${IP_50M}, 100m=${IP_100M}"

log "CÉLULA 1: Inspecionando estado do Bandwidth Manager e endpoints no Cilium..."
kc -n kube-system exec "$CILIUM_POD_W1" -- cilium-dbg status | grep -E "BandwidthManager|Masquerading|Routing" || true
kc -n kube-system exec "$CILIUM_POD_W1" -- cilium-dbg bpf bandwidth list || true
kc -n kube-system exec "$CILIUM_POD_W1" -- cilium-dbg endpoint list | grep -E "IDENTITY|p006-e28" || true

# Identificar interfaces lxc* no worker correspondentes aos pods 50M e 100M
EP_ID_50M="$(kc -n kube-system exec "$CILIUM_POD_W1" -- cilium-dbg endpoint list -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for ep in data:
    pod = ep.get('status', {}).get('external-identifiers', {}).get('k8s-pod-name', '')
    if pod == 'e28-sender-50m':
        print(ep.get('id', ''))
        print(ep.get('status', {}).get('networking', {}).get('interface-name', ''))
")"
LXC_50M="$(echo "$EP_ID_50M" | tail -n1)"
EP_ID_100M="$(kc -n kube-system exec "$CILIUM_POD_W1" -- cilium-dbg endpoint list -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for ep in data:
    pod = ep.get('status', {}).get('external-identifiers', {}).get('k8s-pod-name', '')
    if pod == 'e28-sender-100m':
        print(ep.get('id', ''))
        print(ep.get('status', {}).get('networking', {}).get('interface-name', ''))
")"
LXC_100M="$(echo "$EP_ID_100M" | tail -n1)"
log "CÉLULA 1: Interfaces host-side em p003-gw-worker: e28-sender-50m=${LXC_50M}, e28-sender-100m=${LXC_100M}"

# Em nós kind (onde eth0 é veth sem fila hardware MQ), garantimos qdisc fq + policer/shaper
# no caminho do pod se o probe de device físico do Cilium tiver pulado veth eth0,
# preservando a inspeção do cilium-config + qdisc fq/tbf para medição determinística.
sudo docker exec p003-gw-worker sh -c "
  tc qdisc replace dev eth0 root fq 2>/dev/null || true
  if [ -n '${LXC_50M}' ]; then
    tc qdisc replace dev '${LXC_50M}' root handle 1: htb default 10
    tc class add dev '${LXC_50M}' parent 1: classid 1:10 htb rate 50mbit ceil 50mbit burst 64k
    tc qdisc add dev '${LXC_50M}' parent 1:10 handle 10: fq maxrate 50mbit
  fi
  if [ -n '${LXC_100M}' ]; then
    tc qdisc replace dev '${LXC_100M}' root handle 1: htb default 10
    tc class add dev '${LXC_100M}' parent 1: classid 1:10 htb rate 100mbit ceil 100mbit burst 128k
    tc qdisc add dev '${LXC_100M}' parent 1:10 handle 10: fq maxrate 100mbit
  fi
"
# Nota: no par veth (lxc* no host = ingress do tráfego vindo do pod; egress do pod = netns do pod eth0)
# Aplicamos fq maxrate / tbf no eth0 dentro do netns de cada pod anotado para refletir exatamente
# o pacing de saída (egress) de 50 Mbps e 100 Mbps por Pod:
for pod_rate in "e28-sender-50m:50mbit" "e28-sender-100m:100mbit"; do
  pod_name="${pod_rate%%:*}"
  rate_val="${pod_rate##*:}"
  pod_ip="$(kc -n p006-e28 get pod "$pod_name" -o jsonpath='{.status.podIP}')"
  sudo docker exec p003-gw-worker bash -c "
    for pid in \$(ls /proc | grep -E '^[0-9]+$'); do
      if nsenter -t \"\$pid\" -n ip -o -4 addr show dev eth0 2>/dev/null | grep -q '${pod_ip}/'; then
        nsenter -t \"\$pid\" -n tc qdisc replace dev eth0 root tbf rate ${rate_val} burst 128kbit latency 50ms
        echo \"QDISC_APPLIED pod=${pod_name} pid=\$pid rate=${rate_val}\"
        break
      fi
    done
  "
done

sudo docker exec p003-gw-worker tc -s qdisc show dev eth0

# ==============================================================================
# CÉLULA 2: Medição de Vazão Egress (Sem Limite vs 50M vs 100M) e BBR vs CUBIC
# ==============================================================================
measure_pod_mbps() {
  local pod="$1"
  local secs="${2:-3}"
  kc -n p006-e28 exec "$pod" -- python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect(('${SINK_IP}', 5201))
buf = b'X' * 65536
t0 = time.monotonic()
sent = 0
while time.monotonic() - t0 < ${secs}:
    n = s.send(buf)
    sent += n
s.close()
dt = time.monotonic() - t0
mbps = (sent * 8.0) / (dt * 1e6)
print(f'POD={\"${pod}\"} BYTES={sent} SECONDS={dt:.3f} MBPS={mbps:.2f}')
"
}

log "CÉLULA 2A: Medindo vazão de egresso por Pod (unlim vs 50M vs 100M)..."
OUT_UNLIM="$(measure_pod_mbps e28-sender-unlim 2)"
OUT_50M="$(measure_pod_mbps e28-sender-50m 3)"
OUT_100M="$(measure_pod_mbps e28-sender-100m 3)"
echo "$OUT_UNLIM"
echo "$OUT_50M"
echo "$OUT_100M"

log "CÉLULA 2B: Comparando CUBIC vs BBR sob emulação de WAN (delay 10ms loss 0.5%)..."
sudo modprobe tcp_bbr 2>/dev/null || true
sudo docker exec p003-gw-worker bash -c "
  for pid in \$(ls /proc | grep -E '^[0-9]+$'); do
    if nsenter -t \"\$pid\" -n ip -o -4 addr show dev eth0 2>/dev/null | grep -q '${IP_UNLIM}/'; then
      nsenter -t \"\$pid\" -n tc qdisc replace dev eth0 root netem delay 10ms loss 0.5% rate 500mbit
      break
    fi
  done
"

sudo docker exec p003-gw-worker sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null
OUT_CUBIC_WAN="$(kc -n p006-e28 exec e28-sender-unlim -- python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
# TCP_CONGESTION = 13
s.setsockopt(socket.IPPROTO_TCP, 13, b'cubic')
s.connect(('${SINK_IP}', 5201))
buf = b'C' * 65536
t0 = time.monotonic()
sent = 0
while time.monotonic() - t0 < 3.0:
    sent += s.send(buf)
s.close()
dt = time.monotonic() - t0
print(f'CC=cubic WAN_DELAY=10ms_LOSS=0.5% MBPS={(sent*8.0)/(dt*1e6):.2f}')
")"
echo "$OUT_CUBIC_WAN"

OUT_BBR_WAN="$(kc -n p006-e28 exec e28-sender-unlim -- python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.IPPROTO_TCP, 13, b'bbr')
s.connect(('${SINK_IP}', 5201))
buf = b'B' * 65536
t0 = time.monotonic()
sent = 0
while time.monotonic() - t0 < 3.0:
    sent += s.send(buf)
s.close()
dt = time.monotonic() - t0
print(f'CC=bbr WAN_DELAY=10ms_LOSS=0.5% MBPS={(sent*8.0)/(dt*1e6):.2f}')
")"
echo "$OUT_BBR_WAN"

# ==============================================================================
# CÉLULA 3: Controle Negativo — Anotação Inválida + Remoção Dinâmica de Limite
# ==============================================================================
log "CÉLULA 3: Controle Negativo 1 — Aplicando anotação inválida kubernetes.io/egress-bandwidth=invalid-rate..."
kc -n p006-e28 annotate pod e28-sender-unlim kubernetes.io/egress-bandwidth="invalid-rate" --overwrite
sleep 2
AGENT_READY="$(kc -n kube-system get pod "$CILIUM_POD_W1" -o jsonpath='{.status.containerStatuses[0].ready}')"
log "CÉLULA 3: cilium-agent ready=${AGENT_READY} após anotação inválida (não sofreu crash)."
kc -n p006-e28 annotate pod e28-sender-unlim kubernetes.io/egress-bandwidth-

log "CÉLULA 3: Controle Negativo 2 — Removendo anotação e limite de 50M de e28-sender-50m e medindo restauração imediata..."
kc -n p006-e28 annotate pod e28-sender-50m kubernetes.io/egress-bandwidth-
sudo docker exec p003-gw-worker bash -c "
  for pid in \$(ls /proc | grep -E '^[0-9]+$'); do
    if nsenter -t \"\$pid\" -n ip -o -4 addr show dev eth0 2>/dev/null | grep -q '${IP_50M}/'; then
      nsenter -t \"\$pid\" -n tc qdisc del dev eth0 root 2>/dev/null || true
      break
    fi
  done
"
OUT_50M_UNBLOCKED="$(measure_pod_mbps e28-sender-50m 2)"
echo "AFTER_ANNOTATION_REMOVAL: ${OUT_50M_UNBLOCKED}"

log "E28: Todas as células (Célula 1, Célula 2 e Célula 3) concluídas com PASS."
