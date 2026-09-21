#!/usr/bin/env bash
# S004 diagnostico 6 — args reais do processo + como o chart injeta o config.
# Uso: sudo bash s004-diag6.sh <out>
set -u
OUT="${1:?out}"
K() { KUBECONFIG=/root/.kube/p003-gw.config kubectl --context kind-p003-gw "$@"; }
{
  echo "=== cmdline do processo cilium-agent (workerA) ==="
  K -n kube-system exec cilium-tntn7 -- sh -c 'tr "\0" " " < /proc/1/cmdline' 2>/dev/null | tr ' ' '\n' | grep -iE 'hostnetwork|config-map|configmap' || echo "(nenhum match em cmdline)"
  echo "=== ds: volume configMap + mount ==="
  K -n kube-system get ds cilium -o json | jq '.spec.template.spec.volumes[]? | select(.configMap!=null) | {name, configMap:.configMap.name, items:.configMap.items}'
  echo "=== ds: args completos (primeiros 40) ==="
  K -n kube-system get ds cilium -o json | jq -r '.spec.template.spec.containers[0].args[]?' | head -40
  echo "=== chart: onde gatewayAPI.hostNetwork.enabled aparece ==="
  tar -tzf /opt/poc-k8s-fabric-studies/studies/p003/base/cilium-1.20.2.tgz | grep -E 'templates/' | head -40
} > "$OUT" 2>&1
cat "$OUT"
