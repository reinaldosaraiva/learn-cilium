#!/usr/bin/env bash
# S004 — registra os cinco campos de porta por protocolo para os dois Gateways.
# Uso: sudo bash s004-record-ports.sh [--dry-run] <out>
set -u
KC="${KC:-/root/.kube/p003-gw.config}"
CTX="${CTX:-kind-p003-gw}"
if [[ "${1:-}" == "--dry-run" ]]; then
  echo "[DRY-RUN] s004-record-ports.sh: coletaria gateways, services e endpointslices em p003-gateway via KC=${KC} CTX=${CTX}."
  exit 0
fi
OUT="${1:?out}"
K() { KUBECONFIG="$KC" kubectl --context "$CTX" "$@"; }
{
  echo "=== gateways ==="
  for gw in p003-main p003-ctrl-nodeport; do
    K -n p003-gateway get gateway "$gw" -o json | jq \
      '{gw:.metadata.name, gen:.metadata.generation, obsGen:.status.observedGeneration,
        conds:[.status.conditions[]|{type,status,reason}],
        listeners:[.status.listeners[]|{name,attached}]}'
  done
  echo "=== services ==="
  for svc in cilium-gateway-p003-main cilium-gateway-p003-ctrl-nodeport; do
    K -n p003-gateway get svc "$svc" -o json | jq \
      '{svc:.metadata.name, type:.spec.type,
        ports:[.spec.ports[]|{name,protocol,port,nodePort}],
        ingress:.status.loadBalancer.ingress}'
  done
  echo "=== endpointslices ==="
  for svc in cilium-gateway-p003-main cilium-gateway-p003-ctrl-nodeport; do
    K -n p003-gateway get endpointslice -l "kubernetes.io/service-name=$svc" -o json | jq -r \
      '.items[] | .metadata.name as $n
       | (.ports | map("\(.name):\(.port)\(.protocol // "TCP")") | join(",")) as $p
       | .endpoints[] | select(.conditions.ready==true)
       | $n + " " + .addresses[0] + " " + $p'
  done
} > "$OUT" 2>&1
cat "$OUT"
