#!/usr/bin/env bash
# S004 diagnostico 2 — listener hostNetwork: status, sockets ampliado, logs.
# Uso: sudo bash s004-diag2.sh <out>
set -u
OUT="${1:?out}"
K() { KUBECONFIG=/root/.kube/p003-gw.config kubectl --context kind-p003-gw "$@"; }
{
  echo "=== status listeners p003-main (detalhe) ==="
  K -n p003-gateway get gateway p003-main -o json | jq '.status.listeners'
  echo "=== ss ampliado workerA (15432/15353 em qualquer addr) ==="
  pid=$(docker inspect -f '{{.State.Pid}}' p003-gw-worker)
  sudo nsenter -t "$pid" -n ss -lntup 2>/dev/null | grep -E '15432|15353' || echo "(nada em 15432/15353)"
  echo "=== ss ampliado workerA (172.19.0.6 = podIP cilium) ==="
  sudo nsenter -t "$pid" -n ss -lntup 2>/dev/null | grep '172.19.0.6' || echo "(nada em 172.19.0.6)"
  echo "=== probe client -> podIP cilium workerA 172.19.0.6:15432 ==="
  nonce="P003-diag2-$(date +%s%N)"
  resp=$(sudo docker exec clab-p003-gw-fabric-client sh -c "echo ${nonce} | nc -w 3 172.19.0.6 15432" 2>&1)
  echo "resp: [${resp}]  (esperado: ${nonce})"
  echo "=== rotas do client para 172.19.0.0/16 ==="
  sudo docker exec clab-p003-gw-fabric-client ip route get 172.19.0.6 2>&1
  echo "=== logs cilium workerA (hostNetwork/gateway) ==="
  K -n kube-system logs cilium-k9ssl --since=40m 2>/dev/null | grep -iE 'hostnetwork|host_network|listener' | tail -30
  echo "=== fim logs ==="
} > "$OUT" 2>&1
cat "$OUT"
