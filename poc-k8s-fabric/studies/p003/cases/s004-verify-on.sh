#!/usr/bin/env bash
# S004 — verifica que hostNetwork esta realmente ativo apos rollout.
# Uso: sudo bash s004-verify-on.sh <out>
set -u
OUT="${1:?out}"
K() { KUBECONFIG=/root/.kube/p003-gw.config kubectl --context kind-p003-gw "$@"; }
{
  echo "=== pods (IP deve ser o IP do no) ==="
  K -n kube-system get pods -l k8s-app=cilium -o wide
  echo "=== drift checker apos restart (esperado: vazio) ==="
  for p in $(K -n kube-system get pods -l k8s-app=cilium -o name | sed 's|pod/||'); do
    echo "--- $p ---"
    K -n kube-system logs "$p" --since=10m 2>/dev/null | grep -i 'config-drift' | tail -3
  done
  echo "=== ss workerA (15432/15353) ==="
  pid=$(docker inspect -f '{{.State.Pid}}' p003-gw-worker)
  sudo nsenter -t "$pid" -n ss -lntup 2>/dev/null | grep -E ':(15432|15353)\b' || echo "(nada)"
  echo "=== ss workerB (15432/15353) ==="
  pidb=$(docker inspect -f '{{.State.Pid}}' p003-gw-worker2)
  sudo nsenter -t "$pidb" -n ss -lntup 2>/dev/null | grep -E ':(15432|15353)\b' || echo "(nada)"
  echo "=== gateway main Programmed ==="
  K -n p003-gateway get gateway p003-main -o json | jq -c '[.status.conditions[]|{type,status,reason}]'
  echo "=== probe manual workerA:15432 ==="
  nonce="P003-verify-$(date +%s%N)"
  resp=$(sudo docker exec clab-p003-gw-fabric-client sh -c "echo ${nonce} | nc -w 3 10.30.1.12 15432" 2>&1)
  echo "resp: [${resp}]  (esperado: ${nonce})"
} > "$OUT" 2>&1
cat "$OUT"
