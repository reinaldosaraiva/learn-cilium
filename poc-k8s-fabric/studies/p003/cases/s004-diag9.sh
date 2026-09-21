#!/usr/bin/env bash
# S004 diagnostico 9 — logs do agent sobre gateway hostNetwork + ss completo.
# Uso: sudo bash s004-diag9.sh <out>
set -u
OUT="${1:?out}"
K() { KUBECONFIG=/root/.kube/p003-gw.config kubectl --context kind-p003-gw "$@"; }
{
  echo "=== logs cilium-tntn7 (workerA) gateway/hostnetwork/listener ==="
  K -n kube-system logs cilium-tntn7 --since=15m 2>/dev/null | grep -iE 'gateway|hostnetwork|listener|15432|15353' | head -40
  echo "=== fim logs ==="
  echo "=== ss completo workerA (todas as portas LISTEN) ==="
  pid=$(docker inspect -f '{{.State.Pid}}' p003-gw-worker)
  sudo nsenter -t "$pid" -n ss -lntup 2>/dev/null | head -40
  echo "=== probe workerA:15432 de novo ==="
  nonce="P003-d9-$(date +%s%N)"
  resp=$(sudo docker exec clab-p003-gw-fabric-client sh -c "echo ${nonce} | nc -w 3 10.30.1.12 15432" 2>&1)
  echo "resp: [${resp}]  (esperado: ${nonce})"
} > "$OUT" 2>&1
cat "$OUT"
