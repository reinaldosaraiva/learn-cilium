#!/usr/bin/env bash
# Canario k01 — preservacao. 10x HTTP 200 em 10.201.255.10:80 + UID k01.
# Uso: sudo bash k01-canary.sh [--dry-run] <out>
set -u
if [ "${1:-}" = "--dry-run" ]; then
  echo "[DRY-RUN] k01-canary.sh: K01_KUBECONFIG=${K01_KUBECONFIG:-/root/.kube/k01-rebuild.config} K01_VIP=${K01_VIP:-10.201.255.10} K01_UID=${K01_UID:-635e7274-5597-40c7-9de5-b1fbe3d68b22}"
  exit 0
fi
OUT="${1:?out}"
C="sudo docker exec clab-p003-gw-fabric-client"
K01_VIP="${K01_VIP:-10.201.255.10}"
K01_UID="${K01_UID:-635e7274-5597-40c7-9de5-b1fbe3d68b22}"
K01_KUBECONFIG="${K01_KUBECONFIG:-/root/.kube/k01-rebuild.config}"
if [ ! -f "$K01_KUBECONFIG" ] && [ -f /root/.kube/k01.config ]; then
  K01_KUBECONFIG="/root/.kube/k01.config"
fi
{
  echo "=== canario k01 ${K01_VIP}:80 (10x HTTP 200) ==="
  ok=0
  for i in $(seq 1 10); do
    code=$($C sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://${K01_VIP}:80/" 2>&1)
    if [ "$code" = "200" ]; then ok=$((ok+1)); r=OK; else r=FAIL; fi
    echo "$i ${r} (http ${code})"
  done
  echo "canario: ${ok}/10 HTTP 200"
  echo "=== UID k01 (context kind-k01, kubeconfig ${K01_KUBECONFIG}) ==="
  uid=$(sudo env KUBECONFIG="$K01_KUBECONFIG" kubectl --context kind-k01 get namespace kube-system -o jsonpath='{.metadata.uid}' 2>&1)
  echo "uid=${uid}"
  if [ "$uid" = "$K01_UID" ]; then echo "UID-K01-OK"; else echo "UID-K01-MISMATCH (esperado ${K01_UID})"; fi
  echo "=== BGP k01 (cilium established) ==="
  sudo env KUBECONFIG="$K01_KUBECONFIG" kubectl --context kind-k01 -n kube-system get pods -l k8s-app=cilium -o name 2>/dev/null | head -1 | while read -r p; do
    sudo env KUBECONFIG="$K01_KUBECONFIG" kubectl --context kind-k01 -n kube-system exec "${p#pod/}" -- cilium bgp peer list 2>/dev/null | grep -iE 'established|state' | head -5
  done
} > "$OUT" 2>&1
cat "$OUT"
