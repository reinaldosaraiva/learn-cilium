#!/usr/bin/env bash
# S004 diagnostico — onde o listener hostNetwork esta bindado?
# Uso: sudo bash s004-diag-hostnetwork.sh <out>
set -u
OUT="${1:?out}"
K() { KUBECONFIG=/root/.kube/p003-gw.config kubectl --context kind-p003-gw "$@"; }
ssports() { # $1=node-container
  local pid
  pid=$(docker inspect -f '{{.State.Pid}}' "$1")
  sudo nsenter -t "$pid" -n ss -lntup 2>/dev/null | grep -E ':(15432|15353|30518|32277)\b' \
    || echo "(nenhum socket escutando nestas portas)"
}
{
  echo "=== containers kind ==="
  docker ps --format '{{.Names}}' | grep -E 'p003-gw-(worker|worker2|control-plane)( |$)'
  echo "=== ss em p003-gw-worker (workerA 10.30.1.12) ==="
  ssports p003-gw-worker
  echo "=== ss em p003-gw-worker2 (workerB 10.30.2.11) ==="
  ssports p003-gw-worker2
  echo "=== probe manual workerA:15432 ==="
  nonce="P003-diag-$(date +%s%N)"
  resp=$(sudo docker exec clab-p003-gw-fabric-client sh -c "echo ${nonce} | nc -w 3 10.30.1.12 15432" 2>&1)
  echo "resp: [${resp}]  (nonce esperado: ${nonce})"
  echo "=== probe manual workerA:30518 ==="
  nonce2="P003-diag-np-$(date +%s%N)"
  resp2=$(sudo docker exec clab-p003-gw-fabric-client sh -c "echo ${nonce2} | nc -w 3 10.30.1.12 30518" 2>&1)
  echo "resp: [${resp2}]  (nonce esperado: ${nonce2})"
} > "$OUT" 2>&1
cat "$OUT"
