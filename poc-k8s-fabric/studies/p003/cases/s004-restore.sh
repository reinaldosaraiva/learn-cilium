#!/usr/bin/env bash
# S004 step 9 — verifica OFF aplicado e remove objetos de controle por nome exato.
# Uso: sudo bash s004-restore.sh <out>
set -u
OUT="${1:?out}"
K() { KUBECONFIG=/root/.kube/p003-gw.config kubectl --context kind-p003-gw "$@"; }
{
  echo "=== UID (pre-mutacao) ==="
  uid=$(K get namespace kube-system -o jsonpath='{.metadata.uid}')
  echo "uid=${uid}"
  [ "$uid" = "8216d179-9eed-4dc1-ab9c-97c0c6612b32" ] && echo UID-OK || { echo UID-MISMATCH; exit 1; }
  echo "=== config-dir: gateway-api-hostnetwork-enabled (esperado false/ausente) ==="
  p=$(K -n kube-system get pods -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
  K -n kube-system exec "$p" -- sh -c 'cat /tmp/cilium/config-map/gateway-api-hostnetwork-enabled 2>&1'
  echo "=== agent arg (esperado false) ==="
  K -n kube-system logs "$p" --since=5m 2>/dev/null | grep -i "gateway-api-hostnetwork-enabled=" | head -1
  echo "=== removendo objetos de controle (nome exato) ==="
  K -n p003-gateway delete gateway p003-ctrl-nodeport --wait=false
  K -n p003-gateway delete tcproute p003-ctrl-nodeport-tcp --wait=false
  K -n p003-gateway delete udproute p003-ctrl-nodeport-udp --wait=false
  K -n p003-gateway delete ciliumgatewayclassconfig p003-nodeport --wait=false
  K delete gatewayclass p003-nodeport --wait=false
  echo "=== aguardando Service de controle desaparecer ==="
  for i in $(seq 1 20); do
    if K -n p003-gateway get svc cilium-gateway-p003-ctrl-nodeport >/dev/null 2>&1; then sleep 3; else echo "service de controle removido"; break; fi
  done
  echo "=== objetos p003 restantes no ns ==="
  K -n p003-gateway get gateway,gatewayclass,tcproute,udproute,ciliumgatewayclassconfig 2>&1
  K get gatewayclass 2>&1 | grep -E 'p003|NAME'
  echo "=== gateway main Programmed ==="
  for i in $(seq 1 20); do
    P=$(K -n p003-gateway get gateway p003-main -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
    [ "$P" = "True" ] && break; sleep 3
  done
  echo "main Programmed=$P"
  K -n p003-gateway get gateway p003-main -o json | jq -c '[.status.conditions[]|{type,status,reason}]'
} > "$OUT" 2>&1
cat "$OUT"
