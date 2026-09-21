#!/usr/bin/env bash
# S004 diagnostico 11 — L7 host exposure: logs + shared listener + matchLabels.
# Uso: sudo bash s004-diag11.sh <out>
set -u
OUT="${1:?out}"
K() { KUBECONFIG=/root/.kube/p003-gw.config kubectl --context kind-p003-gw "$@"; }
{
  echo "=== logs workerA: host/shared/listener/envoy bind ==="
  K -n kube-system logs cilium-tntn7 --since=20m 2>/dev/null \
    | grep -iE 'host network|hostnetwork|shared listener|host listener|expose|bind.*host|node.*label' | head -30
  echo "=== (fim grep 1) ==="
  echo "=== logs workerA: erros/warns recentes ==="
  K -n kube-system logs cilium-tntn7 --since=20m 2>/dev/null \
    | grep -iE 'level=(error|warn)' | grep -ivE 'config-drift' | head -20
  echo "=== (fim) ==="
  echo "=== labels dos nos ==="
  K get nodes -o json | jq -r '.items[] | .metadata.name + " => " + ((.metadata.labels|to_entries|map(.key+"="+.value))|join(", "))' | grep -E 'p003-gw'
  echo "=== ss workerA: portas >30000 e 8080/8443/9964 ==="
  pid=$(docker inspect -f '{{.State.Pid}}' p003-gw-worker)
  sudo nsenter -t "$pid" -n ss -lntup 2>/dev/null | grep -E ':(8080|8443|9964|30[0-9]{3}|31[0-9]{3}|32[0-9]{3})\b' || echo "(nada)"
} > "$OUT" 2>&1
cat "$OUT"
