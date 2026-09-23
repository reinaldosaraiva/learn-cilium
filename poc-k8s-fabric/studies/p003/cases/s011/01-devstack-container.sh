#!/usr/bin/env bash
# P003-S011 — provision a minimal OpenStack (DevStack: keystone+neutron, no
# compute) inside a memory-capped Docker container on vm-cilium.
#
# Rationale: vm-cilium has 10Gi RAM available and NO swap, and runs the
# PROTECTED k01 cluster + the p003-gw study sandbox. A bare-metal full DevStack
# would risk OOM-killing k01 and Neutron provider networking would touch the
# host NIC. So: minimal service list (keystone+neutron — S011 is discovery-only,
# Nova/compute is S012), overlay-only Neutron (no provider/flat nets on the
# physical NIC), and an 8Gi cgroup memory cap so a runaway deploy cannot reach
# k01.
#
# Idempotent-ish: re-running recreates the container fresh.
set -euo pipefail

OS_CONTAINER="${OS_CONTAINER:-p003-os}"
OS_MEM="${OS_MEM:-8g}"
OS_CPUS="${OS_CPUS:-4}"
STACK_HOME="/opt/stack"
DEVSTACK_DIR="${STACK_HOME}/devstack"
VOLUME_HOST="${VOLUME_HOST:-/opt/p003-os-stack}"

echo "### [1/5] create container ${OS_CONTAINER} (mem=${OS_MEM}, cpus=${OS_CPUS})"
sudo docker rm -f "${OS_CONTAINER}" >/dev/null 2>&1 || true
sudo mkdir -p "${VOLUME_HOST}"
sudo docker run -d \
  --name "${OS_CONTAINER}" \
  --privileged \
  --memory="${OS_MEM}" --memory-swap="${OS_MEM}" \
  --cpus="${OS_CPUS}" \
  -v "${VOLUME_HOST}:${STACK_HOME}" \
  -e DEBIAN_FRONTEND=noninteractive \
  ubuntu:22.04 sleep infinity
echo "container id: $(sudo docker inspect -f '{{.Id}}' "${OS_CONTAINER}")"
echo "mem limit: $(sudo docker inspect -f '{{.HostConfig.Memory}}' "${OS_CONTAINER}") bytes"

run() { sudo docker exec "${OS_CONTAINER}" bash -lc "$1"; }

echo "### [2/5] apt prerequisites (inside container)"
run 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && \
  apt-get install -y -qq git pkg-config libsqlite3-dev python3-dev python3-pip \
  python3-venv python3-wheel python3-setuptools libpcre3-dev libffi-dev curl ca-certificates >/dev/null && \
  echo "prereqs installed"'

echo "### [3/5] create stack user + clone devstack"
run 'id stack >/dev/null 2>&1 || useradd -m -d /opt/stack -s /bin/bash stack; \
  mkdir -p /opt/stack && chown stack:stack /opt/stack; \
  if [ ! -d /opt/stack/devstack/.git ]; then \
    ( git clone -q https://opendev.org/openstack/devstack /opt/stack/devstack 2>/dev/null \
      || git clone -q https://github.com/openstack/devstack /opt/stack/devstack ); \
  fi; \
  chown -R stack:stack /opt/stack/devstack; \
  echo "devstack at: $(cd /opt/stack/devstack && git rev-parse --short HEAD)"'

echo "### [4/5] write minimal local.conf (keystone+neutron, overlay-only)"
run 'cat > /opt/stack/devstack/local.conf <<EOF
[[local|localrc]]
# P003-S011 minimal discovery cloud: identity + networking only.
# No compute/storage/dashboard (Nova is S012, not S011).
SERVICE_LIST=keystone,neutron
# Neutron with OVS data path.
Q_PLUGIN_ml2_drivers=open_vswitch
# Overlay-only: do NOT create provider/flat/VLAN networks on any physical NIC
# (protects the host NIC that the kind clusters + SR Linux fabric use).
FLAT_NETWORKS=
VLAN_RANGES=
# Keep it quiet.
LOG_LEVEL=INFO
LOGFILE=/opt/stack/logs/stack.sh.log
# No extra extensions by default.
ENABLED_EXTENSIONS=
EOF
chown stack:stack /opt/stack/devstack/local.conf; \
  echo "local.conf written"; cat /opt/stack/devstack/local.conf'

echo "### [5/5] container ready. Next: run stack.sh (02-stack.sh)."
sudo docker ps --filter "name=${OS_CONTAINER}" --format "{{.Names}}\t{{.Status}}"
