#!/usr/bin/env bash
# CENARIO C - aplica o overlay EVPN/VXLAN por cima do fabric ja rodando.
# ATENCAO: move os peerings eBGP do Cilium e do border1 da network-instance
# default para a ip-vrf "k8s" (VNI 1000). Para reverter, recrie a topologia ou
# reaplique configs/srl/leaf*.cfg.
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=0
CONFIRM="${CONFIRM:-0}"
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y)  CONFIRM=1 ;;
  esac
done

PFX="${PFX:-clab-poc-k8s-kind}"
if [[ "${DRY_RUN}" -eq 0 ]] && ! docker inspect "${PFX}-leaf1" >/dev/null 2>&1; then
  if docker inspect "clab-poc-k8s-fabric-leaf1" >/dev/null 2>&1; then
    PFX="clab-poc-k8s-fabric"
  fi
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "[DRY-RUN] 05-evpn-scenario.sh: PFX=${PFX}"
  echo "[DRY-RUN] Aplicaria configs/srl/evpn/{spine1-rr,spine2-rr,leaf1-evpn,leaf2-evpn,leaf3-border-evpn}.cfg"
  exit 0
fi

for node in spine1 spine2 leaf1 leaf2 leaf3; do
  if ! docker inspect "${PFX}-${node}" >/dev/null 2>&1; then
    echo "ERRO: container ${PFX}-${node} nao encontrado. Suba a topologia primeiro (./scripts/01-deploy-fabric.sh)." >&2
    exit 1
  fi
done

if [[ "${CONFIRM}" != "1" ]]; then
  echo "ATENCAO: 05-evpn-scenario.sh remove os peerings eBGP da network-instance default nos leaves (${PFX}) e os recria na ip-vrf 'k8s' (VNI 1000)."
  if [[ -t 0 ]]; then
    read -r -p "Deseja prosseguir? [y/N] " ans
    if [[ ! "${ans}" =~ ^[Yy]$ ]]; then
      echo "Operacao cancelada."
      exit 1
    fi
  else
    echo "ERRO: execucao nao-interativa requer --yes ou CONFIRM=1." >&2
    exit 1
  fi
fi

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
