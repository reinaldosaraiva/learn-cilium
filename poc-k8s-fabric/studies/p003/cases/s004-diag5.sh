#!/usr/bin/env bash
# S004 diagnostico 5 — como o agent recebe gateway-api-hostnetwork-enabled?
# Uso: sudo bash s004-diag5.sh <out>
set -u
OUT="${1:?out}"
K() { KUBECONFIG=/root/.kube/p003-gw.config kubectl --context kind-p003-gw "$@"; }
{
  echo "=== ds cilium spec.template.spec.hostNetwork (agora) ==="
  K -n kube-system get ds cilium -o json | jq '.spec.template.spec.hostNetwork'
  echo "=== args cilium-agent (grep hostnetwork) ==="
  K -n kube-system get ds cilium -o json | jq -r '.spec.template.spec.containers[0].args[]? ' | grep -i 'hostnetwork' || echo "(nenhum arg hostnetwork)"
  echo "=== env cilium-agent (grep -i host/gateway) ==="
  K -n kube-system get ds cilium -o json | jq -r '.spec.template.spec.containers[0].env[]? | "\(.name)=\(.value)"' | grep -iE 'host|gateway' || echo "(nenhum env host/gateway)"
  echo "=== config real do agent (cilium config) ==="
  K -n kube-system exec cilium-tntn7 -- cilium config 2>/dev/null | grep -iE 'hostnetwork|host_network' || echo "(nada)"
  echo "=== IPs dos nos kind ==="
  for n in p003-gw-worker p003-gw-worker2 p003-gw-control-plane; do
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$n")
    echo "$n kind-ip=$ip"
  done
} > "$OUT" 2>&1
cat "$OUT"
