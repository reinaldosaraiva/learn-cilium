#!/usr/bin/env bash
# Sobe o fabric (SR Linux + FRR). Para o cluster REAL, cria antes as bridges.
set -euo pipefail
cd "$(dirname "$0")/.."

TOPO="${TOPO:-topo/poc-fabric.clab.yml}"

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
echo "  ssh admin@clab-poc-k8s-fabric-leaf1     (senha: NokiaSrl1!)"
echo "  docker exec -it clab-poc-k8s-fabric-border1 vtysh"
