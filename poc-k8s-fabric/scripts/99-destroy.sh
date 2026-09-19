#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TOPO="${TOPO:-topo/poc-fabric.clab.yml}"
clab destroy -t "${TOPO}" --cleanup
for br in br-node1 br-node2 br-node3; do
  ip link del "${br}" 2>/dev/null || true
done
echo "lab removido."
