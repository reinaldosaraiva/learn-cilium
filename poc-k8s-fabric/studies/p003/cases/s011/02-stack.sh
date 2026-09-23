#!/usr/bin/env bash
# P003-S011 — run DevStack stack.sh inside the memory-capped container.
# Run in the background and monitor /tmp/s011-stack.log. The container's 8GiB
# cgroup cap protects the host (and the protected k01 cluster) from a runaway.
set -euo pipefail
OS_CONTAINER="${OS_CONTAINER:-p003-os}"
LOG="${LOG:-/tmp/s011-stack.log}"

echo "### launching stack.sh in ${OS_CONTAINER} (log: ${LOG})"
sudo docker exec -u stack "${OS_CONTAINER}" bash -lc \
  'cd /opt/stack/devstack && ./stack.sh' > "${LOG}" 2>&1
echo "### stack.sh exited rc=$? (see ${LOG})"
