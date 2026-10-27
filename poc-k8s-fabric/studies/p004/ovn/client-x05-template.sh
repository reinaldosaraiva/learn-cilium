#!/usr/bin/env bash
# Gera uma configuração FRR funcional para o segundo cliente X05.
set -euo pipefail

CLIENT_NAME="${CLIENT_NAME:-dci-client-2}"
CLIENT_AS="${CLIENT_AS:-201}"
ONPREM_PREFIX="${ONPREM_PREFIX:-10.0.0.0/16}"
TENANT_PREFIX="${TENANT_PREFIX:-192.168.100.0/24}"
ROUTER_ID="${ROUTER_ID:-169.254.254.10}"
PEER_1="${PEER_1:-169.254.254.1}"
PEER_2="${PEER_2:-169.254.254.5}"
PEER_AS="${PEER_AS:-100}"
INTERFACE_1="${INTERFACE_1:-eth1}"
INTERFACE_2="${INTERFACE_2:-eth2}"

for value in "${ONPREM_PREFIX}" "${TENANT_PREFIX}"; do
  [[ "${value}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] \
    || { echo "CIDR inválido: ${value}" >&2; exit 2; }
done
[[ "${CLIENT_AS}" =~ ^[0-9]+$ && "${PEER_AS}" =~ ^[0-9]+$ ]] \
  || { echo "AS inválido" >&2; exit 2; }
[[ "${ROUTER_ID}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "ROUTER_ID inválido: ${ROUTER_ID}" >&2; exit 2; }
for value in "${PEER_1}" "${PEER_2}"; do
  [[ "${value}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "peer inválido: ${value}" >&2; exit 2; }
done
[[ "${ROUTER_ID}" != "${PEER_1}" && "${ROUTER_ID}" != "${PEER_2}" ]] \
  || { echo "ROUTER_ID deve ser distinto dos peers" >&2; exit 2; }
[[ -n "${INTERFACE_1}" && -n "${INTERFACE_2}" ]] \
  || { echo "interfaces BFD ausentes" >&2; exit 2; }

cat <<EOF
!
! Cliente X05 parametrizado. As VLANs e endereços das interfaces são
! entregues separadamente a dci_start_client_instance.
!
frr version 8.4.1
frr defaults traditional
hostname ${CLIENT_NAME}
service integrated-vtysh-config
!
ip prefix-list MG-TO-TENANT seq 10 permit ${TENANT_PREFIX}
ip prefix-list MG-TO-PEER seq 10 permit ${ONPREM_PREFIX}
route-map MG-TO-TENANT permit 10
 match ip address prefix-list MG-TO-TENANT
route-map MG-TO-PEER permit 10
 match ip address prefix-list MG-TO-PEER
!
ip route ${ONPREM_PREFIX} Null0
!
router bgp ${CLIENT_AS}
 bgp router-id ${ROUTER_ID}
 neighbor ${PEER_1} remote-as ${PEER_AS}
 neighbor ${PEER_1} bfd
 neighbor ${PEER_2} remote-as ${PEER_AS}
 neighbor ${PEER_2} bfd
 address-family ipv4 unicast
  network ${ONPREM_PREFIX}
  neighbor ${PEER_1} activate
  neighbor ${PEER_1} route-map MG-TO-TENANT in
  neighbor ${PEER_1} route-map MG-TO-PEER out
  neighbor ${PEER_2} activate
  neighbor ${PEER_2} route-map MG-TO-TENANT in
  neighbor ${PEER_2} route-map MG-TO-PEER out
  maximum-paths 2
 exit-address-family
!
bfd
 peer ${PEER_1} interface ${INTERFACE_1}
  no shutdown
  receive-interval 500
  transmit-interval 500
  detect-multiplier 3
 peer ${PEER_2} interface ${INTERFACE_2}
  no shutdown
  receive-interval 500
  transmit-interval 500
  detect-multiplier 3
!
EOF
