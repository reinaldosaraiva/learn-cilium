#!/usr/bin/env bash
# =============================================================================
# Preparacao da VM do lab (vm-cilium, DP16-32-150, Ubuntu 24.04) - CAMINHO B
#
# Instala Docker, Containerlab, kind, kubectl, helm e cilium-cli, ajusta sysctls
# e valida o ambiente. Rode UMA vez, como root:
#
#   sudo ./scripts/00-prep-vm.sh
#
# Baseado no veredito de checagem de 2026-09-16 (docs/11-veredito-ambiente.md):
# kernel 6.8, cgroup v2, IPv6 habilitado e egress OK ja confirmados; faltavam
# Docker e ip_forward.
# =============================================================================
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "rode como root (sudo)"; exit 1; }

CILIUM_CLI_VERSION="${CILIUM_CLI_VERSION:-v0.18.8}"
KIND_VERSION="${KIND_VERSION:-v0.30.0}"
K8S_VERSION="${K8S_VERSION:-v1.34}"

hr(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

hr "1/7 pre-requisitos do sistema"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg jq tcpdump iproute2 bridge-utils

hr "2/7 sysctls"
cat >/etc/sysctl.d/99-clab-poc.conf <<'SYSCTL'
# containerlab + kind precisam rotear entre os namespaces do lab
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
# rp_filter estrito derruba o trafego assimetrico do ECMP
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
# containerlab EXIGE IPv6 habilitado no kernel
net.ipv6.conf.all.disable_ipv6 = 0
# o lab cria muitos namespaces, veths e watches
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
net.core.somaxconn = 4096
SYSCTL
sysctl --system >/dev/null
echo "ip_forward = $(sysctl -n net.ipv4.ip_forward)"

hr "3/7 Docker Engine"
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin
  systemctl enable --now docker
else
  echo "docker ja instalado"
fi
docker --version

hr "4/7 Containerlab"
command -v containerlab >/dev/null || bash -c "$(curl -sL https://get.containerlab.dev)"
containerlab version | head -3

hr "5/7 kind, kubectl, helm, cilium-cli"
ARCH=$(dpkg --print-architecture)   # amd64 | arm64

if ! command -v kind >/dev/null; then
  curl -fsSLo /usr/local/bin/kind \
    "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
  chmod +x /usr/local/bin/kind
fi

if ! command -v kubectl >/dev/null; then
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list
  apt-get update -qq && apt-get install -y -qq kubectl
fi

command -v helm >/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

if ! command -v cilium >/dev/null; then
  curl -fsSL --remote-name-all \
    "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${ARCH}.tar.gz"
  tar xzf "cilium-linux-${ARCH}.tar.gz" -C /usr/local/bin
  rm -f "cilium-linux-${ARCH}.tar.gz"
fi

for b in kind kubectl helm cilium; do printf '%-9s %s\n' "$b" "$($b version --client 2>/dev/null | head -1 || $b version 2>/dev/null | head -1)"; done

hr "6/7 imagens do lab (pre-pull)"
docker pull -q ghcr.io/nokia/srlinux:25.3.2
docker pull -q frrouting/frr:v8.4.1
docker pull -q ghcr.io/hellt/network-multitool
docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' | grep -E 'srlinux|frr|multitool'

hr "7/7 validacao"
fail=0
check(){ printf '%-34s' "$1"; if eval "$2" >/dev/null 2>&1; then echo "OK"; else echo "FALHOU"; fail=1; fi; }
check "docker funcional"          "docker run --rm hello-world"
check "ip_forward = 1"            "[ \$(sysctl -n net.ipv4.ip_forward) -eq 1 ]"
check "IPv6 habilitado no kernel" "[ \$(sysctl -n net.ipv6.conf.all.disable_ipv6) -eq 0 ]"
check "cgroup v2"                 "[ \$(stat -fc %T /sys/fs/cgroup) = cgroup2fs ]"
check "modulo veth"               "modinfo veth"
check "modulo vxlan"              "modinfo vxlan"
check "vCPU >= 8"                 "[ \$(nproc) -ge 8 ]"
check "RAM >= 16 GB"              "[ \$(free -g | awk '/^Mem:/{print \$2}') -ge 15 ]"
check "disco livre >= 40 GB"      "[ \$(df -BG --output=avail / | tail -1 | tr -dc 0-9) -ge 40 ]"

echo
if [[ $fail -eq 0 ]]; then
  echo "VM pronta. Proximo passo:  sudo clab deploy -t topo/poc-kind.clab.yml"
else
  echo "Algum item falhou - resolva antes de subir o lab."
  exit 1
fi
