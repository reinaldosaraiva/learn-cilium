#!/usr/bin/env bash
# S004 diagnostico 3 — por que o agent nao aplicou hostNetwork?
# Uso: sudo bash s004-diag3.sh <out>
set -u
OUT="${1:?out}"
K() { KUBECONFIG=/root/.kube/p003-gw.config kubectl --context kind-p003-gw "$@"; }
{
  echo "=== cilium-config: gateway-api-hostnetwork-enabled ==="
  K -n kube-system get cm cilium-config -o json | jq -r '.data | to_entries[] | select(.key|test("hostnetwork|host_network")) | .key + "=" + .value'
  echo "=== ds cilium: hostNetwork? ==="
  K -n kube-system get ds cilium -o json | jq '{hostNetwork:.spec.template.spec.hostNetwork, containers:[.spec.template.spec.containers[]|{name,image}]}'
  echo "=== config drift em cada pod ==="
  for p in cilium-2fjnw cilium-k9ssl cilium-wdlwk; do
    echo "--- $p ---"
    K -n kube-system logs "$p" --since=40m 2>/dev/null | grep -i 'config-drift' | tail -3
  done
  echo "=== restarts/age pods ==="
  K -n kube-system get pods -l k8s-app=cilium -o wide
} > "$OUT" 2>&1
cat "$OUT"
