#!/usr/bin/env bash
# =============================================================================
# Preparacao de UM no do cluster k8s existente para a PoC.
# Rode em cada no, como root, ajustando as variaveis do topo.
#
#   node1 -> NODE_IP=10.10.1.11  GW=10.10.1.1  RACK=rack1
#   node2 -> NODE_IP=10.10.1.12  GW=10.10.1.1  RACK=rack1
#   node3 -> NODE_IP=10.10.2.11  GW=10.10.2.1  RACK=rack2
# =============================================================================
set -euo pipefail

IFACE="${IFACE:-eth1}"          # NIC ligada ao leaf SR Linux
NODE_IP="${NODE_IP:-10.10.1.11}"
PREFIX="${PREFIX:-24}"
GW="${GW:-10.10.1.1}"
MTU="${MTU:-1500}"   # VPC da Magalu nao entrega jumbo

echo "[1/4] endereco e MTU em ${IFACE}"
ip link set "${IFACE}" up
ip link set "${IFACE}" mtu "${MTU}"
ip addr replace "${NODE_IP}/${PREFIX}" dev "${IFACE}"

echo "[2/4] rotas para o fabric (NAO troque a default de gerencia)"
# outros racks / nos
ip route replace 10.10.0.0/16 via "${GW}" dev "${IFACE}"
# PodCIDR global: fallback para pods de outros racks (o /24 local e mais especifico)
ip route replace 10.244.0.0/16 via "${GW}" dev "${IFACE}"
# VIPs de LoadBalancer e rede "externa" atras do FRR
ip route replace 10.201.255.0/24 via "${GW}" dev "${IFACE}"
ip route replace 203.0.113.0/24 via "${GW}" dev "${IFACE}"

echo "[3/4] sysctls exigidos pelo Cilium em native routing"
cat >/etc/sysctl.d/99-cilium-poc.conf <<SYSCTL
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv6.conf.all.forwarding = 1
SYSCTL
sysctl --system >/dev/null

echo "[4/4] pronto. Confira:"
ip -br addr show "${IFACE}"
ip route | grep -E '10\.10\.|10\.244\.|172\.31\.255\.|203\.0\.113\.'
echo
echo "Agora rotule o no no cluster, por exemplo:"
echo "  kubectl label node \$(hostname) topology.kubernetes.io/rack=rack1 --overwrite"
