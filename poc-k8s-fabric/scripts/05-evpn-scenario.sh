#!/usr/bin/env bash
# CENARIO C - aplica o overlay EVPN/VXLAN por cima do fabric ja rodando.
set -euo pipefail
cd "$(dirname "$0")/.."
PFX="${PFX:-clab-poc-k8s-fabric}"

docker exec -i "${PFX}-spine1" sr_cli < configs/srl/evpn/spine1-rr.cfg
docker exec -i "${PFX}-spine2" sr_cli < configs/srl/evpn/spine2-rr.cfg
docker exec -i "${PFX}-leaf1"  sr_cli < configs/srl/evpn/leaf1-evpn.cfg
docker exec -i "${PFX}-leaf2"  sr_cli < configs/srl/evpn/leaf2-evpn.cfg
docker exec -i "${PFX}-leaf3"  sr_cli < configs/srl/evpn/leaf3-border-evpn.cfg

echo
echo "Validacao rapida:"
docker exec "${PFX}-leaf1" sr_cli -- 'show network-instance default protocols bgp neighbor'
docker exec "${PFX}-leaf1" sr_cli -- 'show tunnel-interface vxlan-interface brief'
docker exec "${PFX}-leaf1" sr_cli -- 'show network-instance k8s protocols bgp neighbor'
docker exec "${PFX}-leaf1" sr_cli -- 'show network-instance k8s route-table ipv4-unicast summary'
