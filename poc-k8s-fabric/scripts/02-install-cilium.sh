#!/usr/bin/env bash
# Instala/atualiza o Cilium em modo native routing + BGP Control Plane.
#
# Sem kube-proxy, o Cilium precisa saber alcancar o API server por IP. Num
# cluster kind gerenciado pelo containerlab esse IP e o do container do
# control-plane na rede de gerencia do clab - por isso a deteccao abaixo.
# Para um cluster em nos reais, exporte K8S_SERVICE_HOST manualmente.
set -euo pipefail
cd "$(dirname "$0")/.."

CILIUM_VERSION="${CILIUM_VERSION:-1.20.1}"
VALUES="${VALUES:-k8s/cilium/values-native.yaml}"
CP_CONTAINER="${CP_CONTAINER:-k01-control-plane}"

if [[ -z "${K8S_SERVICE_HOST:-}" ]]; then
  if docker inspect "${CP_CONTAINER}" >/dev/null 2>&1; then
    K8S_SERVICE_HOST=$(docker inspect -f \
      '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "${CP_CONTAINER}" \
      | tr ' ' '\n' | grep -v '^$' | head -1)
    echo "[i] API server detectado no container ${CP_CONTAINER}: ${K8S_SERVICE_HOST}"
  else
    K8S_SERVICE_HOST=$(grep -E '^k8sServiceHost' "${VALUES}" | awk -F'"' '{print $2}')
    echo "[i] usando k8sServiceHost do values: ${K8S_SERVICE_HOST}"
  fi
fi
K8S_SERVICE_PORT="${K8S_SERVICE_PORT:-6443}"

helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update cilium >/dev/null

helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --version "${CILIUM_VERSION}" \
  -f "${VALUES}" \
  --set k8sServiceHost="${K8S_SERVICE_HOST}" \
  --set k8sServicePort="${K8S_SERVICE_PORT}" \
  --wait

kubectl -n kube-system rollout status ds/cilium --timeout=5m
cilium status --wait || true
