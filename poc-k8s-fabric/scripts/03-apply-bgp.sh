#!/usr/bin/env bash
# Aplica as CRDs de BGP, o pool de VIPs e a aplicacao de teste.
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

: "${RACK1_NODES:=k01-control-plane k01-worker}"
: "${RACK2_NODES:=k01-worker2}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "[DRY-RUN] 03-apply-bgp.sh: RACK1_NODES='${RACK1_NODES}' RACK2_NODES='${RACK2_NODES}'"
  echo "[DRY-RUN] kubectl apply -f k8s/bgp/01..05 + k8s/apps/10..13"
  exit 0
fi

echo "[1/3] rotulando os nos por rack (RACK1_NODES='${RACK1_NODES}', RACK2_NODES='${RACK2_NODES}')"
for n in ${RACK1_NODES}; do kubectl label node "$n" topology.kubernetes.io/rack=rack1 --overwrite; done
for n in ${RACK2_NODES}; do kubectl label node "$n" topology.kubernetes.io/rack=rack2 --overwrite; done

echo "[2/3] CRDs de BGP + LB-IPAM"
kubectl apply -f k8s/bgp/01-peer-config.yaml
kubectl apply -f k8s/bgp/02-advertisements.yaml
kubectl apply -f k8s/bgp/03-cluster-config-rack1.yaml
kubectl apply -f k8s/bgp/04-cluster-config-rack2.yaml
kubectl apply -f k8s/bgp/05-lb-ippool.yaml

echo "[3/3] aplicacao de teste"
kubectl apply -f k8s/apps/10-echo-deployment.yaml
kubectl apply -f k8s/apps/11-echo-svc-anycast.yaml
kubectl apply -f k8s/apps/12-echo-svc-local.yaml
kubectl apply -f k8s/apps/13-netshoot-daemonset.yaml

kubectl rollout status deploy/echo --timeout=3m
kubectl get svc echo-anycast echo-local
