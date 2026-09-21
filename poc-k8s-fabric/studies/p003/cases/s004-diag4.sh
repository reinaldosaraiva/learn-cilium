#!/usr/bin/env bash
# S004 diagnostico 4 — o agent tenta aplicar/reload do config?
# Uso: sudo bash s004-diag4.sh <out>
set -u
OUT="${1:?out}"
K() { KUBECONFIG=/root/.kube/p003-gw.config kubectl --context kind-p003-gw "$@"; }
{
  echo "=== logs cilium-k9ssl desde 16:55 (config/restart/drift) ==="
  K -n kube-system logs cilium-k9ssl --since=30m 2>/dev/null | grep -iE 'config|restart|drift|reload' | head -40
  echo "=== fim ==="
} > "$OUT" 2>&1
cat "$OUT"
