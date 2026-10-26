#!/usr/bin/env bash
# Bateria de validacao fim-a-fim da PoC.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

PFX="${PFX:-clab-poc-k8s-kind}"
if [[ "${DRY_RUN}" -eq 0 ]] && ! docker inspect "${PFX}-leaf1" >/dev/null 2>&1; then
  if docker inspect "clab-poc-k8s-fabric-leaf1" >/dev/null 2>&1; then
    PFX="clab-poc-k8s-fabric"
  fi
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "[DRY-RUN] 04-validate.sh: PFX=${PFX} (validacao BGP/SR Linux/FRR/HTTP/ping)"
  exit 0
fi

hr(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

hr "1. Sessoes BGP no cluster (Cilium)"
cilium bgp peers

hr "2. Prefixos que o Cilium esta anunciando"
cilium bgp routes advertised ipv4 unicast

hr "3. Vizinhos BGP no leaf1"
docker exec "${PFX}-leaf1" sr_cli -- 'show network-instance default protocols bgp neighbor'

hr "4. PodCIDRs e VIPs aprendidos no leaf1"
docker exec "${PFX}-leaf1" sr_cli -- 'show network-instance default route-table ipv4-unicast prefix 10.244.0.0/16 longer'
docker exec "${PFX}-leaf1" sr_cli -- 'show network-instance default route-table ipv4-unicast prefix 10.201.255.0/24 longer'

hr "5. ECMP do VIP anycast visto do spine1"
docker exec "${PFX}-spine1" sr_cli -- 'show network-instance default route-table ipv4-unicast prefix 10.201.255.10/32 detail'

hr "6. Tabela BGP no border FRR"
docker exec "${PFX}-border1" vtysh -c 'show bgp ipv4 unicast summary'
docker exec "${PFX}-border1" vtysh -c 'show bgp ipv4 unicast 10.201.255.10/32'

hr "7. Acesso externo ao servico (10 requisicoes)"
for _ in $(seq 1 10); do
  docker exec "${PFX}-client-ext" curl -s --max-time 3 http://10.201.255.10/hostname || echo "FALHA"
  echo
done

hr "8. Pod-to-pod entre racks (sem NAT, IP real)"
SRC=$(kubectl get pod -l app=netshoot -o jsonpath='{.items[0].metadata.name}')
DSTIP=$(kubectl get pod -l app=echo -o jsonpath='{.items[-1:].status.podIP}')
kubectl exec "${SRC}" -- ping -c3 -W2 "${DSTIP}"
