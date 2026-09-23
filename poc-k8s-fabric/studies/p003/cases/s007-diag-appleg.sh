#!/usr/bin/env bash
# P003-S007: diagnostico empirico da perna pod A->B (misterio W0P2/W0P3).
# Pergunta: por qual interface (bridge docker eth0 vs fabric eth1) trafega
# conexao hostNetwork(A) -> pod(B)? Envia marcador TCP ao pod tcp-echo em B
# com captura simultanea na bridge (host) e em eth1 (no A).
# Uso: sudo bash s007-diag-appleg.sh <target_ip> <port> [extra_ip_para_filtro] [tag]
#   target_ip: pod IP direto OU Service ClusterIP
#   extra_ip:  IP extra no filtro (ex.: pod IP quando o alvo e Service)
#   tag:       sufixo dos artefatos (podip | svc)
set -u
APP_IP="${1:?target_ip}"
APP_PORT="${2:?port}"
EXTRA_IP="${3:-}"
TAG="${4:-run}"
NODEA=p003-gw-worker
BRIDGE=br-b56f3de1d858
EV="/opt/poc-k8s-fabric-studies/studies/p003/evidence/S007-2026-09-22T0048Z/diag-appleg"
MARKER="S007DIAG-$(date +%s)"
mkdir -p "$EV"

echo "[$(date -u +%FT%TZ)] marker=$MARKER target=$APP_IP:$APP_PORT"

# capturas (30s): bridge no host + eth1 no no A
FILTER="host $APP_IP"
[ -n "$EXTRA_IP" ] && FILTER="$FILTER or host $EXTRA_IP"
timeout 30 tcpdump -i "$BRIDGE" -A -w "$EV/$TAG-bridge.pcap" "$FILTER" >"$EV/$TAG-bridge.log" 2>&1 &
BPID=$!
sudo docker exec -d "$NODEA" timeout 30 tcpdump -i eth1 -A -w /tmp/diag-eth1.pcap "$FILTER"

sleep 1
# conexao TCP com marcador, de DENTRO do no A (mesmo hostNetwork do Envoy)
resp=$(sudo docker exec "$NODEA" bash -c "echo $MARKER | timeout 5 bash -c 'exec 3<>/dev/tcp/$APP_IP/$APP_PORT; cat >&3; cat <&3'" 2>&1)
echo "[$(date -u +%FT%TZ)] resposta: ${resp:-<vazia>}"

# segunda conexao para garantir volume
sleep 1
sudo docker exec "$NODEA" bash -c "echo $MARKER | timeout 5 bash -c 'exec 3<>/dev/tcp/$APP_IP/$APP_PORT; cat >&3; cat <&3'" >/dev/null 2>&1 || true

wait "$BPID" 2>/dev/null
sudo docker cp "$NODEA:/tmp/diag-eth1.pcap" "$EV/$TAG-eth1.pcap" >/dev/null 2>&1
sudo docker exec "$NODEA" rm -f /tmp/diag-eth1.pcap

{
  echo "marker=$MARKER target=$APP_IP:$APP_PORT ts=$(date -u +%FT%TZ)"
  echo "bridge: pkts=$(tcpdump -r "$EV/$TAG-bridge.pcap" 2>/dev/null | wc -l) marker_hits=$(tcpdump -r "$EV/$TAG-bridge.pcap" -A 2>/dev/null | grep -c "$MARKER" || true)"
  echo "eth1  : pkts=$(tcpdump -r "$EV/$TAG-eth1.pcap" 2>/dev/null | wc -l) marker_hits=$(tcpdump -r "$EV/$TAG-eth1.pcap" -A 2>/dev/null | grep -c "$MARKER" || true)"
} | tee "$EV/$TAG-diag-summary.txt"
