#!/usr/bin/env bash
# Canario k01 — preservacao. 10x HTTP 200 em 10.201.255.10:80 + UID k01.
# Uso: sudo bash k01-canary.sh <out>
set -u
OUT="${1:?out}"
C="sudo docker exec clab-p003-gw-fabric-client"
K01_VIP=10.201.255.10
K01_UID=45cb3818-248b-4dd2-b65c-5909bde08fe6
{
  echo "=== canario k01 ${K01_VIP}:80 (10x HTTP 200) ==="
  ok=0
  for i in $(seq 1 10); do
    code=$($C sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://${K01_VIP}:80/" 2>&1)
    if [ "$code" = "200" ]; then ok=$((ok+1)); r=OK; else r=FAIL; fi
    echo "$i ${r} (http ${code})"
  done
  echo "canario: ${ok}/10 HTTP 200"
  echo "=== UID k01 (context kind-k01) ==="
  uid=$(KUBECONFIG=/root/.kube/k01.config kubectl --context kind-k01 get namespace kube-system -o jsonpath='{.metadata.uid}' 2>&1)
  echo "uid=${uid}"
  if [ "$uid" = "$K01_UID" ]; then echo "UID-K01-OK"; else echo "UID-K01-MISMATCH (esperado ${K01_UID})"; fi
  echo "=== BGP k01 (cilium established) ==="
  KUBECONFIG=/root/.kube/k01.config kubectl --context kind-k01 -n kube-system get pods -l k8s-app=cilium -o name 2>/dev/null | head -1 | while read p; do
    KUBECONFIG=/root/.kube/k01.config kubectl --context kind-k01 -n kube-system exec "${p#pod/}" -- cilium bgp peer list 2>/dev/null | grep -iE 'established|state' | head -5
  done
} > "$OUT" 2>&1
cat "$OUT"
