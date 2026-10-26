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
OS_IMAGE="${OS_IMAGE:-ubuntu:24.04}"
OS_MEM="${OS_MEM:-8g}"
OS_CPUS="${OS_CPUS:-4}"
STACK_HOME="/opt/stack"
DEVSTACK_DIR="${STACK_HOME}/devstack"
VOLUME_HOST="${VOLUME_HOST:-/opt/p003-os-stack}"
DEVSTACK_PASSWORD="${DEVSTACK_PASSWORD:-$(openssl rand -hex 12)}"

if [[ "${1:-}" == "--dry-run" ]]; then
  echo "[DRY-RUN] 01-devstack-container.sh: container=${OS_CONTAINER} image=${OS_IMAGE} (--init) mem=${OS_MEM} cpus=${OS_CPUS} devstack_dir=${DEVSTACK_DIR}"
  exit 0
fi

echo "### [1/5] create container ${OS_CONTAINER} (image=${OS_IMAGE}, --init, mem=${OS_MEM}, cpus=${OS_CPUS})"
sudo docker rm -f "${OS_CONTAINER}" >/dev/null 2>&1 || true
sudo mkdir -p "${VOLUME_HOST}"
sudo docker run -d \
  --name "${OS_CONTAINER}" \
  --init \
  --privileged \
  --memory="${OS_MEM}" --memory-swap="${OS_MEM}" \
  --cpus="${OS_CPUS}" \
  -v "${VOLUME_HOST}:${STACK_HOME}" \
  -e DEBIAN_FRONTEND=noninteractive \
  "${OS_IMAGE}" sleep infinity
echo "container id: $(sudo docker inspect -f '{{.Id}}' "${OS_CONTAINER}")"
echo "mem limit: $(sudo docker inspect -f '{{.HostConfig.Memory}}' "${OS_CONTAINER}") bytes"

run() { sudo docker exec "${OS_CONTAINER}" bash -lc "$1"; }

echo "### [2/5] apt prerequisites (inside container, including sudo)"
run 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && \
  apt-get install -y -qq sudo git pkg-config libsqlite3-dev python3-dev python3-pip \
  python3-venv python3-wheel python3-setuptools libpcre3-dev libffi-dev curl ca-certificates >/dev/null && \
  echo "prereqs installed"'

echo "### [3/5] create stack user + passwordless sudo + clone devstack"
run 'id stack >/dev/null 2>&1 || useradd -m -d /opt/stack -s /bin/bash stack; \
  echo "stack ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/stack && chmod 0440 /etc/sudoers.d/stack; \
  mkdir -p /opt/stack && chown stack:stack /opt/stack; \
  if [ ! -d /opt/stack/devstack/.git ]; then \
    ( git clone -q https://opendev.org/openstack/devstack /opt/stack/devstack 2>/dev/null \
      || git clone -q https://github.com/openstack/devstack /opt/stack/devstack ); \
  fi; \
  chown -R stack:stack /opt/stack/devstack; \
  echo "devstack at: $(cd /opt/stack/devstack && git rev-parse --short HEAD)"'

echo "### [4/5] write minimal local.conf (keystone+neutron, ML2/OVS overlay-only)"
run "cat > /opt/stack/devstack/local.conf <<EOF
[[local|localrc]]
# P003-S011 minimal discovery cloud: identity + networking only (Nova/Placement/Glance added in S012).
ADMIN_PASSWORD=${DEVSTACK_PASSWORD}
DATABASE_PASSWORD=${DEVSTACK_PASSWORD}
MYSQL_PASSWORD=${DEVSTACK_PASSWORD}
RABBIT_PASSWORD=${DEVSTACK_PASSWORD}
SERVICE_PASSWORD=${DEVSTACK_PASSWORD}

# Valid DevStack service selection (keystone + neutron ML2/OVS agents + mysql + rabbit + etcd3).
ENABLED_SERVICES=key,q-svc,q-agt,q-dhcp,q-l3,q-meta,mysql,rabbit,etcd3

# Neutron ML2 with Open vSwitch agent (note: default DevStack starts OVN unless Q_AGENT=openvswitch is set;
# see cases/s011/reconf-ovs.sh if reconfiguring an already-deployed OVN container).
Q_AGENT=openvswitch
Q_ML2_PLUGIN_MECHANISM_DRIVERS=openvswitch
Q_ML2_PLUGIN_TYPE_DRIVERS=vxlan,flat
Q_ML2_TENANT_NETWORK_TYPE=vxlan
Q_USE_PROVIDERNET_FOR_PUBLIC=False

# Keep it quiet.
LOG_LEVEL=INFO
LOGFILE=/opt/stack/logs/stack.sh.log
EOF
chown stack:stack /opt/stack/devstack/local.conf && chmod 0600 /opt/stack/devstack/local.conf; \
  echo 'local.conf written (passwords redacted):'; grep -v 'PASSWORD=' /opt/stack/devstack/local.conf"

echo "### [5/5] container ready. Next: run stack.sh (02-stack.sh)."
sudo docker ps --filter "name=${OS_CONTAINER}" --format "{{.Names}}\t{{.Status}}"
