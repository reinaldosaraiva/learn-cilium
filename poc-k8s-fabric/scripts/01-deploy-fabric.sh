#!/usr/bin/env bash
# Sobe o fabric (SR Linux + FRR). Para o cluster REAL (poc-fabric), cria antes as bridges.
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

TOPO="${TOPO:-topo/poc-kind.clab.yml}"
if [[ "${TOPO}" == *"poc-kind"* ]]; then
  PFX="${PFX:-clab-poc-k8s-kind}"
else
  PFX="${PFX:-clab-poc-k8s-fabric}"
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "[DRY-RUN] 01-deploy-fabric.sh: TOPO=${TOPO} PFX=${PFX}"
  echo "[DRY-RUN] clab deploy -t ${TOPO}"
  exit 0
fi

if [[ "${TOPO}" == *"poc-fabric"* ]]; then
  for br in br-node1 br-node2 br-node3; do
    if ! ip link show "${br}" >/dev/null 2>&1; then
      echo "[+] criando bridge ${br}"
      ip link add "${br}" type bridge
      ip link set "${br}" mtu 9216
      ip link set "${br}" up
    fi
    # bridges Linux filtram por padrao; deixe passar tudo entre as portas
    echo 0 > "/sys/class/net/${br}/bridge/stp_state" 2>/dev/null || true
  done
fi

clab deploy -t "${TOPO}"
echo
echo "Topologia no ar. Acesso rapido:"
echo "  ssh admin@${PFX}-leaf1     (credencial padrao da imagem SR Linux)"
echo "  docker exec -it ${PFX}-border1 vtysh"
