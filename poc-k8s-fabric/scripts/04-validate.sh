#!/usr/bin/env bash
# Bateria de validacao fim-a-fim da PoC.
set -uo pipefail
cd "$(dirname "$0")/.."

PFX="${PFX:-clab-poc-k8s-fabric}"
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
for i in $(seq 1 10); do
  docker exec "${PFX}-client-ext" curl -s --max-time 3 http://10.201.255.10/hostname || echo "FALHA"
  echo
done

hr "8. Pod-to-pod entre racks (sem NAT, IP real)"
SRC=$(kubectl get pod -l app=netshoot -o jsonpath='{.items[0].metadata.name}')
DSTIP=$(kubectl get pod -l app=echo -o jsonpath='{.items[-1:].status.podIP}')
kubectl exec "${SRC}" -- ping -c3 -W2 "${DSTIP}"
