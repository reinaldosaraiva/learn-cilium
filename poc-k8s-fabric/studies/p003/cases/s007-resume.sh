#!/usr/bin/env bash
# P003-S007: resume apos ABORT em PHASE 4 (bug do driver: deploy/cilium inexistente;
# agent e DaemonSet; encryption entra via ConfigMap e exige rollout restart).
# Estado atual: REVISION 6 deployed com encryption=true no cilium-config,
# agentes AINDA sem WG (drift checker actual=false expected=true).
# Continua: W1 (restart + verify + celulas) -> W2 -> restauracao W0 + baseline.
set -u

EV="/opt/poc-k8s-fabric-studies/studies/p003/evidence/S007-2026-09-22T0048Z"
STUDY="/opt/poc-k8s-fabric-studies/studies/p003"
CHART="$STUDY/base/cilium-1.20.2.tgz"
K="sudo env KUBECONFIG=/root/.kube/p003-gw.config kubectl"
K01="sudo env KUBECONFIG=/root/.kube/k01-rebuild.config kubectl"
NS=p003-gateway
NODEA=p003-gw-worker
NODEB=p003-gw-worker2
IP_A=10.30.1.12
IP_B=10.30.2.11
NP=30676
VIP=10.202.255.10
UID_SANDBOX=8216d179-9eed-4dc1-ab9c-97c0c6612b32
UID_K01=45cb3818-248b-4dd2-b65c-5909bde08fe6
CLIENT=clab-p003-gw-fabric-client
HERE="$(cd "$(dirname "$0")" && pwd)"
USRV=/tmp/s007-user-values.yaml

mkdir -p "$EV"
plog() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$EV/progress.log"; }
abort() { plog "ABORT: $*"; exit 1; }

uid_check() {
  local uid
  uid=$($K get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
  [ "$uid" = "$UID_SANDBOX" ] || abort "sandbox UID mismatch: $uid (esperado $UID_SANDBOX)"
  plog "uid_check sandbox OK"
}
k01_check() {
  local uid
  uid=$($K01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
  [ "$uid" = "$UID_K01" ] || abort "k01 UID mismatch: $uid (esperado $UID_K01)"
  plog "uid_check k01 OK"
}
vip_canary() {
  local ok=0 code
  for i in $(seq 1 10); do
    code=$(sudo docker exec "$CLIENT" curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --retry 0 --max-time 5 -H "Host: echo.p003.study" "http://$VIP:8080/" 2>&1)
    [ "$code" = "200" ] && ok=$((ok+1))
  done
  plog "vip_canary $ok/10 HTTP 200"
  [ "$ok" -eq 10 ] || abort "VIP canary falhou: $ok/10"
}
k01_canary() {
  local ok=0 code
  for i in $(seq 1 10); do
    code=$(sudo docker exec "$CLIENT" curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --retry 0 --max-time 5 "http://10.201.255.10:80/" 2>&1)
    [ "$code" = "200" ] && ok=$((ok+1))
  done
  plog "k01_canary $ok/10 HTTP 200"
  [ "$ok" -eq 10 ] || abort "k01 canary falhou: $ok/10"
}
helm_snap() {
  local tag="$1"
  sudo env KUBECONFIG=/root/.kube/p003-gw.config helm get values cilium -n kube-system > "$EV/values-$tag.yaml" 2>&1
  plog "helm snapshot $tag ($(wc -l < "$EV/values-$tag.yaml") linhas)"
}
helm_upgrade() {
  # $@ = flags --set extras; encryption entra via ConfigMap -> restart explicit
  sudo env KUBECONFIG=/root/.kube/p003-gw.config helm upgrade cilium "$CHART" -n kube-system \
    -f "$USRV" "$@" >>"$EV/helm-upgrade.log" 2>&1 \
    || abort "helm upgrade falhou (ver $EV/helm-upgrade.log)"
  $K rollout restart ds/cilium -n kube-system >>"$EV/helm-upgrade.log" 2>&1 || abort "rollout restart ds/cilium"
  $K rollout status ds/cilium -n kube-system --timeout=600s >>"$EV/helm-upgrade.log" 2>&1 \
    || abort "rollout ds/cilium falhou"
  $K rollout status deploy/cilium-operator -n kube-system --timeout=300s >>"$EV/helm-upgrade.log" 2>&1 \
    || plog "WARN rollout operator (pode ser esperado)"
  dataplane_wait
  plog "helm upgrade + restart OK: $*"
}
wg_verify() {
  local tag="$1" n link
  for n in "$NODEA" "$NODEB"; do
    link=$(sudo docker exec "$n" ip -d link show cilium_wg0 2>&1)
    echo "$link" > "$EV/wg0-$tag-$n.txt"
    echo "$link" | grep -q "cilium_wg0" || abort "cilium_wg0 ausente em $n ($tag)"
  done
  plog "wg_verify $tag: cilium_wg0 presente nos dois workers"
}
wg_absent() {
  local n
  for n in "$NODEA" "$NODEB"; do
    sudo docker exec "$n" ip link show cilium_wg0 >/dev/null 2>&1 \
      && abort "cilium_wg0 ainda presente em $n apos restauracao"
  done
  plog "wg_absent OK (W0 restaurado)"
}
dataplane_wait() {
  # pod Ready != dataplane convergido; sonde nodePort nos dois workers
  local i codeA codeB ok=0
  for i in $(seq 1 24); do
    codeA=$(sudo docker exec "$CLIENT" curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --retry 0 --connect-timeout 2 --max-time 5 -H "Host: echo.p003.study" "http://$IP_A:$NP/" 2>&1)
    codeB=$(sudo docker exec "$CLIENT" curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --retry 0 --connect-timeout 2 --max-time 5 -H "Host: echo.p003.study" "http://$IP_B:$NP/" 2>&1)
    if [ "$codeA" = "200" ] && [ "$codeB" = "200" ]; then ok=1; break; fi
    sleep 5
  done
  plog "dataplane_wait: A=$codeA B=$codeB (tentativa $i)"
  [ "$ok" = "1" ] || abort "dataplane nao convergiu apos rollout (A=$codeA B=$codeB)"
}
canaries() {
  local pre="$1" ip="$3"
  bash "$HERE/s007-probes.sh" "$pre-A02" "http://$ip:$NP" /protected-http allow 10 1 >>"$EV/canaries.log" 2>&1
  bash "$HERE/s007-probes.sh" "$pre-A03" "http://$ip:$NP" /protected-http deny  10 1 >>"$EV/canaries.log" 2>&1
  bash "$HERE/s007-probes.sh" "$pre-A05" "http://$ip:$NP" /protected-grpc allow 10 1 >>"$EV/canaries.log" 2>&1
  bash "$HERE/s007-probes.sh" "$pre-A06" "http://$ip:$NP" /protected-grpc deny  10 1 >>"$EV/canaries.log" 2>&1
  $K -n "$NS" logs deploy/p003-authz > "$EV/auth-logs-$pre.txt" 2>&1
  local s f
  for s in A02 A03 A05 A06; do
    f="$EV/probes/$pre-$s.tsv"
    [ -f "$f" ] || { plog "WARN canary $pre-$s sem TSV"; continue; }
    awk -F'\t' -v c="$pre-$s" '$1==c{n++; if($4==200)ok++; else if($4==403)d++; else o++} END{printf "canary %s: %d req, %d x200, %d x403, %d outros\n", c, n+0, ok+0, d+0, o+0}' "$f" | tee -a "$EV/progress.log"
  done
}

# ===================================================================== W1 (upgrade + restart ja concluidos)
plog "=== RESUME: W1 (encryption=wireguard; upgrade REVISION 6 + restart ja feitos) ==="
uid_check
# limpa evidencias parciais do W1P0 interrompido e canarios CANW1 com 000
rm -rf "$EV/cells/W1P0" "$EV/probes/W1P0"* "$EV/probes/CANW1-"* "$EV/auth-logs-CANW1.txt"
wg_verify W1
dataplane_wait
canaries CANW1 "$NODEA" "$IP_A"
bash "$HERE/s007-cell.sh" W1P0 "$NODEA" "$NODEA" "$NODEA" || abort "W1P0"
bash "$HERE/s007-cell.sh" W1P1 "$NODEA" "$NODEB" "$NODEA" || abort "W1P1"
bash "$HERE/s007-cell.sh" W1P2 "$NODEA" "$NODEA" "$NODEB" || abort "W1P2"
bash "$HERE/s007-cell.sh" W1P3 "$NODEA" "$NODEB" "$NODEB" || abort "W1P3"
bash "$HERE/s007-cell.sh" W1P1INV "$NODEB" "$NODEA" "$NODEB" || abort "W1P1INV"

# ===================================================================== W2
plog "=== PHASE 5: W2 (nodeEncryption ON) ==="
uid_check
helm_snap pre-W2
helm_upgrade --set encryption.enabled=true --set encryption.type=wireguard --set nodeEncryption.enabled=true
wg_verify W2
helm_snap post-W2
canaries CANW2 "$NODEA" "$IP_A"
bash "$HERE/s007-cell.sh" W2P0 "$NODEA" "$NODEA" "$NODEA" || abort "W2P0"
bash "$HERE/s007-cell.sh" W2P1 "$NODEA" "$NODEB" "$NODEA" || abort "W2P1"
bash "$HERE/s007-cell.sh" W2P2 "$NODEA" "$NODEA" "$NODEB" || abort "W2P2"
bash "$HERE/s007-cell.sh" W2P3 "$NODEA" "$NODEB" "$NODEB" || abort "W2P3"

# ===================================================================== restauracao W0 + baseline
plog "=== PHASE 6: restauracao W0 + baseline ==="
uid_check
helm_snap pre-restore
helm_upgrade
wg_absent
canaries CANW0R "$NODEA" "$IP_A"
$K -n "$NS" delete deploy p003-authz --wait=false >>"$EV/setup.log" 2>&1
$K -n "$NS" delete svc p003-authz --wait=false >>"$EV/setup.log" 2>&1
$K -n "$NS" delete httproute p003-protected-http p003-protected-grpc p003-public --wait=false >>"$EV/setup.log" 2>&1
$K -n "$NS" patch deploy http-echo --type merge -p '{"spec":{"template":{"spec":{"nodeSelector":null}}}}' >>"$EV/setup.log" 2>&1
$K -n "$NS" scale deploy http-echo --replicas=3 >>"$EV/setup.log" 2>&1
$K -n "$NS" rollout status deploy/http-echo --timeout=180s >>"$EV/setup.log" 2>&1 || plog "WARN rollout http-echo restore"
$K get gateway p003-main -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].reason}' > "$EV/gateway-final.txt" 2>&1
grep -q Programmed "$EV/gateway-final.txt" || abort "Gateway nao Programmed apos restauracao"
vip_canary
k01_check
k01_canary
plog "=== S007 DONE ==="
