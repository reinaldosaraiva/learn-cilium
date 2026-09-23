#!/usr/bin/env bash
# P003-S007: sequencia master (W0/W1/W2 x P0-P3 + canarios + inversao + restauracao).
# Roda no host vm-cilium via nohup; progresso em $EV/progress.log.
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
  # $@ = flags --set extras
  sudo env KUBECONFIG=/root/.kube/p003-gw.config helm upgrade cilium "$CHART" -n kube-system \
    -f "$USRV" "$@" >>"$EV/helm-upgrade.log" 2>&1 \
    || abort "helm upgrade falhou (ver $EV/helm-upgrade.log)"
  $K rollout status deploy/cilium -n kube-system --timeout=600s >>"$EV/helm-upgrade.log" 2>&1 \
    || abort "rollout cilium falhou"
  $K rollout status deploy/cilium-operator -n kube-system --timeout=300s >>"$EV/helm-upgrade.log" 2>&1 \
    || plog "WARN rollout operator (pode ser esperado)"
  plog "helm upgrade OK: $*"
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
canaries() {
  # $1 = prefixo (ex. CANW0), $2 = ingress node, $3 = ingress ip
  local pre="$1" ing="$2" ip="$3"
  bash "$HERE/s007-probes.sh" "$pre-A02" "http://$ip:$NP" /protected-http allow 10 1 >>"$EV/canaries.log" 2>&1
  bash "$HERE/s007-probes.sh" "$pre-A03" "http://$ip:$NP" /protected-http deny  10 1 >>"$EV/canaries.log" 2>&1
  bash "$HERE/s007-probes.sh" "$pre-A05" "http://$ip:$NP" /protected-grpc allow 10 1 >>"$EV/canaries.log" 2>&1
  bash "$HERE/s007-probes.sh" "$pre-A06" "http://$ip:$NP" /protected-grpc deny  10 1 >>"$EV/canaries.log" 2>&1
  $K -n "$NS" logs deploy/p003-authz > "$EV/auth-logs-$pre.txt" 2>&1
  local s
  for s in A02 A03 A05 A06; do
    local f="$EV/probes/$pre-$s.tsv"
    [ -f "$f" ] || { plog "WARN canary $pre-$s sem TSV"; continue; }
    awk -F'\t' -v c="$pre-$s" '$1==c{n++; if($4==200)ok++; else o++} END{printf "canary %s: %d req, %d x200, %d outros\n", c, n+0, ok+0, o+0}' "$f" | tee -a "$EV/progress.log"
  done
}

# ===================================================================== PHASE 0
plog "=== S007 START ==="
uid_check
k01_check
helm_snap pre
sudo env KUBECONFIG=/root/.kube/p003-gw.config helm get values cilium -n kube-system > "$USRV" 2>&1
cp "$USRV" "$EV/values-user-pre.yaml"
# tcpdump nos workers (coleta wg0); idempotente
for n in "$NODEA" "$NODEB"; do
  sudo docker exec "$n" sh -c "which tcpdump >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq tcpdump)" >>"$EV/setup.log" 2>&1
  plog "tcpdump $n: $(sudo docker exec "$n" which tcpdump 2>&1)"
done
$K get httproute p003-http -n "$NS" -o yaml > "$EV/route-p003-http.yaml" 2>&1

# ===================================================================== PHASE 1: fixture
plog "=== PHASE 1: fixture auth ==="
$K -n "$NS" apply -f "$STUDY/fixtures/auth/auth-deploy.yaml" >>"$EV/setup.log" 2>&1 || abort "apply auth-deploy"
$K -n "$NS" apply -f "$STUDY/fixtures/auth/auth-routes.yaml" >>"$EV/setup.log" 2>&1 || abort "apply auth-routes"
$K -n "$NS" rollout status deploy/p003-authz --timeout=180s >>"$EV/setup.log" 2>&1 || abort "rollout auth"
$K -n "$NS" get httproute -l study=P003 -o name >>"$EV/setup.log" 2>&1
plog "fixture aplicada"

# ===================================================================== PHASE 2: prova de no de ingresso (P0 placement)
plog "=== PHASE 2: ingress proof (workerA) ==="
bash "$HERE/s007-cell.sh" INGRESS-PROOF "$NODEA" "$NODEA" "$NODEA" 10 1 || abort "ingress proof falhou"

# ===================================================================== PHASE 3: W0
plog "=== PHASE 3: W0 (encryption OFF) ==="
canaries CANW0 "$NODEA" "$IP_A"
bash "$HERE/s007-cell.sh" W0P0 "$NODEA" "$NODEA" "$NODEA" || abort "W0P0"
bash "$HERE/s007-cell.sh" W0P1 "$NODEA" "$NODEB" "$NODEA" || abort "W0P1"
bash "$HERE/s007-cell.sh" W0P2 "$NODEA" "$NODEA" "$NODEB" || abort "W0P2"
bash "$HERE/s007-cell.sh" W0P3 "$NODEA" "$NODEB" "$NODEB" || abort "W0P3"
bash "$HERE/s007-cell.sh" W0P1INV "$NODEB" "$NODEA" "$NODEB" || abort "W0P1INV"

# ===================================================================== PHASE 4: W1 (wireguard ON, nodeEncryption OFF)
plog "=== PHASE 4: W1 (encryption=wireguard) ==="
uid_check
helm_snap pre-W1
helm_upgrade --set encryption.enabled=true --set encryption.type=wireguard
wg_verify W1
helm_snap post-W1
canaries CANW1 "$NODEA" "$IP_A"
bash "$HERE/s007-cell.sh" W1P0 "$NODEA" "$NODEA" "$NODEA" || abort "W1P0"
bash "$HERE/s007-cell.sh" W1P1 "$NODEA" "$NODEB" "$NODEA" || abort "W1P1"
bash "$HERE/s007-cell.sh" W1P2 "$NODEA" "$NODEA" "$NODEB" || abort "W1P2"
bash "$HERE/s007-cell.sh" W1P3 "$NODEA" "$NODEB" "$NODEB" || abort "W1P3"
bash "$HERE/s007-cell.sh" W1P1INV "$NODEB" "$NODEA" "$NODEB" || abort "W1P1INV"

# ===================================================================== PHASE 5: W2 (nodeEncryption ON)
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

# ===================================================================== PHASE 6: restauracao W0 + baseline
plog "=== PHASE 6: restauracao W0 + baseline ==="
uid_check
helm_snap pre-restore
helm_upgrade
wg_absent
canaries CANW0R "$NODEA" "$IP_A"
# cleanup fixtures
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
