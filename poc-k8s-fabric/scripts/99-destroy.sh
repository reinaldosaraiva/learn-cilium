#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

TOPO="${TOPO:-topo/poc-kind.clab.yml}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "[DRY-RUN] 99-destroy.sh: clab destroy -t ${TOPO} --cleanup"
  exit 0
fi

clab destroy -t "${TOPO}" --cleanup
for br in br-node1 br-node2 br-node3; do
  ip link del "${br}" 2>/dev/null || true
done
echo "lab removido."
