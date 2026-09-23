#!/usr/bin/env bash
# P003-S007: driver por celula (placement + coleta discriminante + probes).
# Roda no host vm-cilium (root).
# Uso: s007-cell.sh <cell_id> <ingress_node> <auth_node> <app_node> [N] [ROUNDS]
#   ingress_node/auth_node/app_node: p003-gw-worker | p003-gw-worker2
set -u
CELL="${1:?cell_id}"
ING="${2:?ingress_node}"
AUTHN="${3:?auth_node}"
APPN="${4:?app_node}"
N="${5:-30}"
ROUNDS="${6:-3}"

EV="/opt/poc-k8s-fabric-studies/studies/p003/evidence/S007-2026-09-22T0048Z"
K="sudo env KUBECONFIG=/root/.kube/p003-gw.config kubectl"
NS=p003-gateway
NODEA=p003-gw-worker
NODEB=p003-gw-worker2
IP_A=10.30.1.12
IP_B=10.30.2.11
NP=30676
BRIDGE=br-b56f3de1d858
CAPDUR=60
HERE="$(cd "$(dirname "$0")" && pwd)"

C="$EV/cells/$CELL"
mkdir -p "$C"
log() { echo "[$(date -u +%FT%TZ)] [$CELL] $*" | tee -a "$C/cell.log"; }

node_ip() { if [ "$1" = "$NODEA" ]; then echo "$IP_A"; else echo "$IP_B"; fi; }
cilium_pod() {
  $K get pod -n kube-system --field-selector "spec.nodeName=$1" -o name 2>/dev/null \
    | grep -E '^pod/cilium-[a-z0-9]+$' | head -1 | cut -d/ -f2
}

ING_IP=$(node_ip "$ING")
AUTH_IP_POD=""
APP_IP_POD=""

# ------------------------------------------------------------- 1. placement
log "placement: ingress=$ING auth=$AUTHN app=$APPN"
$K -n "$NS" patch deploy p003-authz --type merge \
  -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"$AUTHN\"}}}}}" >>"$C/cell.log" 2>&1 || log "WARN patch auth"
$K -n "$NS" patch deploy http-echo --type merge \
  -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"$APPN\"}}}}}" >>"$C/cell.log" 2>&1 || log "WARN patch app"
$K -n "$NS" scale deploy http-echo --replicas=1 >>"$C/cell.log" 2>&1
$K -n "$NS" rollout status deploy/p003-authz --timeout=180s >>"$C/cell.log" 2>&1 || { log "FAIL rollout auth"; exit 1; }
$K -n "$NS" rollout status deploy/http-echo --timeout=180s >>"$C/cell.log" 2>&1 || { log "FAIL rollout app"; exit 1; }
# aguarda pods antigos (terminating) sumirem para o estado ser univoco
for w in $(seq 1 20); do
  na=$($K -n "$NS" get pods -l app=p003-authz --no-headers 2>/dev/null | wc -l)
  ne=$($K -n "$NS" get pods -l app=http-echo --no-headers 2>/dev/null | wc -l)
  [ "$na" = "1" ] && [ "$ne" = "1" ] && break
  sleep 3
done
log "pods estaveis: auth=$na app=$ne"

# ------------------------------------------------------------- 2. pod state
{
  echo "# cell=$CELL ingress=$ING auth_node=$AUTHN app_node=$APPN ts=$(date -u +%FT%TZ)"
  echo "# obj uid name nodeName podIP"
  $K -n "$NS" get pods -l app=p003-authz --field-selector status.phase=Running -o jsonpath='{range .items[*]}auth {.metadata.uid} {.metadata.name} {.spec.nodeName} {.status.podIP}{"\n"}{end}'
  $K -n "$NS" get pods -l app=http-echo --field-selector status.phase=Running -o jsonpath='{range .items[*]}app {.metadata.uid} {.metadata.name} {.spec.nodeName} {.status.podIP}{"\n"}{end}'
} > "$C/pods.tsv"
AUTH_IP_POD=$(awk '$1=="auth"{print $5}' "$C/pods.tsv" | head -1)
APP_IP_POD=$(awk '$1=="app"{print $5}' "$C/pods.tsv" | head -1)
log "pods: auth=$AUTH_IP_POD app=$APP_IP_POD"
[ -n "$AUTH_IP_POD" ] || { log "FAIL no auth pod IP"; exit 1; }

# ------------------------------------------------------------- 3. routes
{
  echo "# ip route get (netns do no = netns do pod cilium, hostNetwork)"
  for n in "$NODEA" "$NODEB"; do
    echo "# from $n:"
    echo -n "  auth($AUTH_IP_POD): "; sudo docker exec "$n" ip route get "$AUTH_IP_POD" 2>&1 | head -1
    echo -n "  app ($APP_IP_POD): "; sudo docker exec "$n" ip route get "$APP_IP_POD" 2>&1 | head -1
  done
} > "$C/routes.txt"
log "routes recorded"

# ------------------------------------------------------------- 4. coleta sample
POD_ING=$(cilium_pod "$ING")
POD_A=$(cilium_pod "$NODEA")
POD_B=$(cilium_pod "$NODEB")
log "cilium pods: A=$POD_A B=$POD_B ingress=$POD_ING"

t0=$(date +%s)
# underlay: bridge docker (perna inter-nos 172.19.0.x)
timeout "$CAPDUR" tcpdump -i "$BRIDGE" -w "$C/underlay-sample.pcap" \
  "host 172.19.0.6 or host 172.19.0.7" >"$C/tcpdump-underlay.log" 2>&1 &
TDPID=$!
# cilium_wg0 (so W1/W2)
for n in "$NODEA" "$NODEB"; do
  if sudo docker exec "$n" ip link show cilium_wg0 >/dev/null 2>&1; then
    sudo docker exec -d "$n" timeout "$CAPDUR" tcpdump -i cilium_wg0 -w /tmp/wg0-$n.pcap
    log "wg0 capture started on $n"
  fi
done
# monitor drops + trace related-to auth
for n in "$NODEA" "$NODEB"; do
  p=$(cilium_pod "$n")
  [ -n "$p" ] || continue
  $K exec -n kube-system "$p" -- timeout "$CAPDUR" cilium-dbg monitor --type drop \
    >"$C/monitor-drop-$n.log" 2>&1 &
  $K exec -n kube-system "$p" -- timeout "$CAPDUR" cilium-dbg monitor --type trace \
    --related-to-ip "$AUTH_IP_POD" >"$C/monitor-trace-$n.log" 2>&1 &
done

# sample probes (10 allow + 10 deny) com IDs unicos
bash "$HERE/s007-probes.sh" "${CELL}-SAMP" "http://$ING_IP:$NP" /protected-http allow 10 1 >>"$C/cell.log" 2>&1
bash "$HERE/s007-probes.sh" "${CELL}-SAMP" "http://$ING_IP:$NP" /protected-http deny 10 1 >>"$C/cell.log" 2>&1

# aguarda fim das janelas de captura
elapsed=$(( $(date +%s) - t0 ))
if [ "$elapsed" -lt "$CAPDUR" ]; then sleep $(( CAPDUR - elapsed )); fi
wait "$TDPID" 2>/dev/null
sleep 5  # margem para os execs de monitor terminarem de escrever
for n in "$NODEA" "$NODEB"; do
  if sudo docker exec "$n" test -f "/tmp/wg0-$n.pcap" 2>/dev/null; then
    sudo docker cp "$n:/tmp/wg0-$n.pcap" "$C/wg0-$n.pcap" >/dev/null 2>&1
    sudo docker exec "$n" rm -f "/tmp/wg0-$n.pcap"
  fi
done
log "captures done"

# ------------------------------------------------------------- 5. probes completos
bash "$HERE/s007-probes.sh" "${CELL}-allow" "http://$ING_IP:$NP" /protected-http allow "$N" "$ROUNDS" >>"$C/cell.log" 2>&1
bash "$HERE/s007-probes.sh" "${CELL}-deny"  "http://$ING_IP:$NP" /protected-http deny  "$N" "$ROUNDS" >>"$C/cell.log" 2>&1
log "full probes done"

# ------------------------------------------------------------- 6. auth logs + ipcache
$K -n "$NS" logs deploy/p003-authz > "$C/auth-logs.txt" 2>&1
for n in "$NODEA" "$NODEB"; do
  p=$(cilium_pod "$n")
  [ -n "$p" ] || continue
  $K exec -n kube-system "$p" -- cilium-dbg ipcache list 2>/dev/null \
    | grep -E "$AUTH_IP_POD|$APP_IP_POD" > "$C/ipcache-$n.txt"
done

# ------------------------------------------------------------- 7. summary
PDIR="$EV/probes"
sum_case() {
  local f="$PDIR/$1.tsv"
  [ -f "$f" ] || { echo "0 0 0 0"; return; }
  awk -F'\t' -v c="$1" '
    $1==c {n++; if ($4==200) ok++; else if ($4==403) d403++; else other++}
    END{printf "%d %d %d %d", n+0, ok+0, d403+0, other+0}' "$f"
}
auth_count() { local c; c=$(grep -c "$1" "$C/auth-logs.txt" 2>/dev/null); echo "${c:-0}"; }

allow_sum=$(sum_case "${CELL}-allow")
deny_sum=$(sum_case "${CELL}-deny")
samp_sum=$(sum_case "${CELL}-SAMP")
if [ -f "$C/underlay-sample.pcap" ]; then
  CLEARTEXT=$(tcpdump -r "$C/underlay-sample.pcap" -A 2>/dev/null | grep -c "$CELL-SAMP" || true)
  WGPKTS=$(tcpdump -r "$C/underlay-sample.pcap" "udp port 51871" 2>/dev/null | wc -l)
  UPKTS=$(tcpdump -r "$C/underlay-sample.pcap" 2>/dev/null | wc -l)
else
  CLEARTEXT=n/a; WGPKTS=n/a; UPKTS=n/a
fi
{
  echo "cell=$CELL ingress=$ING auth=$AUTHN app=$APPN"
  echo "pods: $(grep -v '^#' "$C/pods.tsv" | tr '\n' '; ')"
  echo "allow : total/200/403/other = $allow_sum"
  echo "deny  : total/200/403/other = $deny_sum"
  echo "samp  : total/200/403/other = $samp_sum"
  echo "auth-log events: allow=$(auth_count "$CELL-allow") deny=$(auth_count "$CELL-deny") samp=$(auth_count "$CELL-SAMP")"
  echo "underlay: packets=$UPKTS udp51871=$WGPKTS cleartext_sample_ids=$CLEARTEXT"
  if [ -f "$C/wg0-$NODEA.pcap" ]; then echo "wg0-A packets=$(tcpdump -r "$C/wg0-$NODEA.pcap" 2>/dev/null | wc -l)"; fi
  if [ -f "$C/wg0-$NODEB.pcap" ]; then echo "wg0-B packets=$(tcpdump -r "$C/wg0-$NODEB.pcap" 2>/dev/null | wc -l)"; fi
  da=$(grep -c 'DROP' "$C/monitor-drop-$NODEA.log" 2>/dev/null); da=${da:-0}
  db=$(grep -c 'DROP' "$C/monitor-drop-$NODEB.log" 2>/dev/null); db=${db:-0}
  echo "monitor drops: A=$da B=$db"
  echo "ts_end=$(date -u +%FT%TZ)"
} > "$C/summary.txt"
cat "$C/summary.txt" | tee -a "$EV/progress.log"
log "cell complete"
