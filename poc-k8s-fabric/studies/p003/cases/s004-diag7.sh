#!/usr/bin/env bash
# S004 diagnostico 7 — o que ha em /tmp/cilium/config-map dentro do pod?
# Uso: sudo bash s004-diag7.sh <out>
set -u
OUT="${1:?out}"
K() { KUBECONFIG=/root/.kube/p003-gw.config kubectl --context kind-p003-gw "$@"; }
{
  echo "=== ls /tmp/cilium/config-map (workerA) ==="
  K -n kube-system exec cilium-tntn7 -- sh -c 'ls -la /tmp/cilium/config-map/ 2>&1 | head -40'
  echo "=== grep hostnetwork em cada arquivo do config-dir ==="
  K -n kube-system exec cilium-tntn7 -- sh -c 'grep -ril hostnetwork /tmp/cilium/config-map/ 2>/dev/null; echo ---; for f in /tmp/cilium/config-map/*; do [ -f "$f" ] && grep -Hi "hostnetwork" "$f"; done 2>&1 | head -20'
  echo "=== ds: initContainers ==="
  K -n kube-system get ds cilium -o json | jq '.spec.template.spec.initContainers[]? | {name, image, command, args}'
  echo "=== ds: volumes (todos) ==="
  K -n kube-system get ds cilium -o json | jq '.spec.template.spec.volumes'
} > "$OUT" 2>&1
cat "$OUT"
