#!/usr/bin/env bash
# S004 diagnostico 8 — a chave gateway-api-hostnetwork-enabled existe no config-dir?
# Uso: sudo bash s004-diag8.sh <out>
set -u
OUT="${1:?out}"
K() { KUBECONFIG=/root/.kube/p003-gw.config kubectl --context kind-p003-gw "$@"; }
{
  echo "=== ls config-dir | grep gateway ==="
  K -n kube-system exec cilium-tntn7 -- sh -c 'ls /tmp/cilium/config-map/ | grep -i gateway' 2>&1
  echo "=== cat gateway-api-hostnetwork-enabled (se existir) ==="
  K -n kube-system exec cilium-tntn7 -- sh -c 'cat /tmp/cilium/config-map/gateway-api-hostnetwork-enabled 2>&1'
  echo "=== total de arquivos no config-dir ==="
  K -n kube-system exec cilium-tntn7 -- sh -c 'ls /tmp/cilium/config-map/ | wc -l'
  echo "=== config-sources (como o agent sabe de onde ler) ==="
  K -n kube-system exec cilium-tntn7 -- sh -c 'cat /tmp/cilium/config-map/config-sources 2>&1'
  echo "=== cilium config (agent) gateway-api-hostnetwork ==="
  K -n kube-system exec cilium-tntn7 -- cilium config 2>/dev/null | grep -i 'gateway-api-hostnetwork' || echo "(nao aparece em cilium config)"
  echo "=== logs init container config (workerA pod) ==="
  K -n kube-system logs cilium-tntn7 -c config 2>&1 | tail -20
} > "$OUT" 2>&1
cat "$OUT"
