#!/usr/bin/env bash
# ==============================================================================
# P005-S002 (Onda 2 — Braço A): E11 — Limite de Prefixos (max-prefix) e
# Filtro de Import (prefix-list) na Sessão eBGP
# ==============================================================================
set -euo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

P003_KUBECONFIG="${P003_KUBECONFIG:-/root/.kube/p003-gw.config}"
P003_CONTEXT="${P003_CONTEXT:-kind-p003-gw}"
EXPECTED_UID="6bb32e0f-71f9-4558-ae33-356ba2250c26"
K01_KUBECONFIG="${K01_KUBECONFIG:-/root/.kube/k01-rebuild.config}"
K01_CONTEXT="${K01_CONTEXT:-kind-k01}"
K01_EXPECTED_UID="635e7274-5597-40c7-9de5-b1fbe3d68b22"

WORKER_NODE="p003-gw-worker2"
WORKER_ASN="65302"
BORDER_CTR="clab-p003-gw-fabric-border1"
BORDER_ASN="65400"
FRR_CE_CTR="clab-p003-gw-fabric-frr-e11-ce"
FRR_IMAGE="${FRR_IMAGE:-frrouting/frr:v8.4.1}"
CE_ASN="65511"

# Enlace Célula 1 (Cilium direto <-> FRR CE): 10.255.211.0/30
CILIUM_LINK_IP="10.255.211.1"
CE_CILIUM_IP="10.255.211.2"
# Enlace Célula 2 (Border1 FRR PE <-> FRR CE): 10.255.211.4/30
BORDER_LINK_IP="10.255.211.5"
CE_BORDER_IP="10.255.211.6"

if $DRY_RUN; then
  cat <<EOF
[DRY-RUN] E11 — Limite de Prefixos (max-prefix) e Filtro de Import (prefix-list)
  Cluster: ${P003_CONTEXT} (expected UID: ${EXPECTED_UID})
  Worker Cilium: ${WORKER_NODE} (AS ${WORKER_ASN}, ${CILIUM_LINK_IP}/30)
  Border PE: ${BORDER_CTR} (AS ${BORDER_ASN}, ${BORDER_LINK_IP}/30)
  FRR CE: ${FRR_CE_CTR} (AS ${CE_ASN}, ${CE_CILIUM_IP}/30 e ${CE_BORDER_IP}/30)
  Passos planejados:
    1. Auditar schema CRD CiliumBGPPeerConfig (ausência de maxPrefix/importPolicy/prefixList) e confirmar R6=0.
    2. Célula 1 (Cilium direto): parear ${WORKER_NODE} <-> ${FRR_CE_CTR}, injetar degraus de 50, 200 e 300 prefixos /32 + 1 prefixo não declarado (198.51.100.99/32); comprovar que a sessão não corta (sem max-prefix), aceita o prefixo não declarado no GoBGP e instala 0 rotas no kernel (R6=0, CFP #34841).
    3. Célula 2 (Border PE FRR): parear ${BORDER_CTR} <-> ${FRR_CE_CTR} com ip prefix-list E11-IMPORT-ALLOW (198.18.0.0/16 le 32) e maximum-prefix 100:
       - Subcélula 2A (50 declarados + 1 não declarado 198.51.100.99/32): comprovar que 198.18.1.1/32 entra na RIB (pfxRcd=50) e 198.51.100.99/32 é descartado pelo filtro de import.
       - Subcélula 2B (escalada para 200 e 300 prefixos): comprovar corte automático da sessão em 100 prefixos (State=Idle (PfxCt)) sem afetar as sessões primárias do fabric.
    4. Rollback completo para baseline do rack2 e do border1.
EOF
  exit 0
fi

k() {
  kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" "$@"
}

ACTUAL_K01_UID="$(kubectl --kubeconfig "${K01_KUBECONFIG}" --context "${K01_CONTEXT}" get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${ACTUAL_K01_UID}" != "${K01_EXPECTED_UID}" ]]; then
  echo "FATAL: UID de k01 (${ACTUAL_K01_UID}) != esperado (${K01_EXPECTED_UID})" >&2
  exit 1
fi
ACTUAL_UID="$(k get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${ACTUAL_UID}" != "${EXPECTED_UID}" ]]; then
  echo "FATAL: UID de kube-system (${ACTUAL_UID}) != esperado (${EXPECTED_UID})" >&2
  exit 1
fi

restore_rack2_baseline() {
  cat <<'EOF' | k apply -f - >/dev/null 2>&1 || true
apiVersion: cilium.io/v2
kind: CiliumBGPClusterConfig
metadata:
  name: rack2
  labels:
    study: P003
spec:
  nodeSelector:
    matchLabels:
      topology.kubernetes.io/rack: rack2
  bgpInstances:
  - name: "rack2"
    localASN: 65302
    peers:
    - name: "leaf2"
      peerASN: 65202
      peerAddress: 10.30.2.1
      peerConfigRef:
        name: "fabric-peer"
EOF
}

cleanup() {
  echo "[CLEANUP] Restaurando baseline do rack2, border1 e removendo ${FRR_CE_CTR}..."
  restore_rack2_baseline
  k delete ciliumbgppeerconfig e11-direct-peer --ignore-not-found >/dev/null 2>&1 || true
  docker exec "${BORDER_CTR}" vtysh \
    -c "configure terminal" \
    -c "router bgp ${BORDER_ASN}" \
    -c "no neighbor ${CE_BORDER_IP} remote-as ${CE_ASN}" \
    -c "exit" \
    -c "no route-map RM-E11-IMPORT" \
    -c "no ip prefix-list E11-IMPORT-ALLOW" \
    -c "end" >/dev/null 2>&1 || true
  docker rm -f "${FRR_CE_CTR}" >/dev/null 2>&1 || true
  docker exec "${WORKER_NODE}" ip link del e11c0 >/dev/null 2>&1 || true
  docker exec "${BORDER_CTR}" ip link del e11b0 >/dev/null 2>&1 || true
  ip link del e11c0 >/dev/null 2>&1 || true
  ip link del e11b0 >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== [E11] 1. Auditoria do Schema CRD CiliumBGPPeerConfig (Cilium 1.20.2) ==="
CRD_IMPORT_FIELDS="$(k get crd ciliumbgppeerconfigs.cilium.io -o json | grep -iEc 'maxPrefix|maximumPrefix|importPolicy|prefixList' || true)"
echo "ciliumbgppeerconfigs_import_or_maxprefix_fields=${CRD_IMPORT_FIELDS}"

echo "=== [E11] 2. Provisionando Container Efêmero ${FRR_CE_CTR} (AS ${CE_ASN}) e Enlaces veth ==="
docker rm -f "${FRR_CE_CTR}" >/dev/null 2>&1 || true
docker run -d --name "${FRR_CE_CTR}" --hostname frr-e11-ce --network none --privileged \
  --entrypoint /bin/sh "${FRR_IMAGE}" -c "exec sleep infinity" >/dev/null

WORKER_PID="$(docker inspect -f '{{.State.Pid}}' "${WORKER_NODE}")"
BORDER_PID="$(docker inspect -f '{{.State.Pid}}' "${BORDER_CTR}")"
CE_PID="$(docker inspect -f '{{.State.Pid}}' "${FRR_CE_CTR}")"

# Enlace 1: worker2 (e11c0) <-> frr-e11-ce (e11c1)
ip link del e11c0 >/dev/null 2>&1 || true
ip link add e11c0 type veth peer name e11c1
ip link set e11c0 netns "${WORKER_PID}"
ip link set e11c1 netns "${CE_PID}"
nsenter -t "${WORKER_PID}" -n ip addr add "${CILIUM_LINK_IP}/30" dev e11c0
nsenter -t "${WORKER_PID}" -n ip link set e11c0 up
nsenter -t "${CE_PID}" -n ip addr add "${CE_CILIUM_IP}/30" dev e11c1
nsenter -t "${CE_PID}" -n ip link set e11c1 up
nsenter -t "${CE_PID}" -n ip link set lo up

# Enlace 2: border1 (e11b0) <-> frr-e11-ce (e11b1)
ip link del e11b0 >/dev/null 2>&1 || true
ip link add e11b0 type veth peer name e11b1
ip link set e11b0 netns "${BORDER_PID}"
ip link set e11b1 netns "${CE_PID}"
nsenter -t "${BORDER_PID}" -n ip addr add "${BORDER_LINK_IP}/30" dev e11b0
nsenter -t "${BORDER_PID}" -n ip link set e11b0 up
nsenter -t "${CE_PID}" -n ip addr add "${CE_BORDER_IP}/30" dev e11b1
nsenter -t "${CE_PID}" -n ip link set e11b1 up

docker exec "${FRR_CE_CTR}" bash -c '
sed -i "s/^bgpd=no/bgpd=yes/" /etc/frr/daemons
cat <<EOF >/etc/frr/frr.conf
frr defaults traditional
hostname frr-e11-ce
no ipv6 forwarding
!
ip prefix-list PL-CE-ORIGIN seq 10 permit 198.18.0.0/16 le 32
ip prefix-list PL-CE-ORIGIN seq 20 permit 198.51.100.99/32
!
route-map RM-CE-ORIGIN permit 10
 match ip address prefix-list PL-CE-ORIGIN
exit
!
router bgp 65511
 bgp router-id 10.255.211.2
 no bgp ebgp-requires-policy
 neighbor 10.255.211.1 remote-as 65302
 neighbor 10.255.211.1 timers 3 9
 neighbor 10.255.211.5 remote-as 65400
 neighbor 10.255.211.5 timers 3 9
 !
 address-family ipv4 unicast
  redistribute connected route-map RM-CE-ORIGIN
  neighbor 10.255.211.1 activate
  neighbor 10.255.211.5 activate
 exit-address-family
exit
!
line vty
EOF
/usr/lib/frr/frrinit.sh start
'

inject_prefixes_step() {
  local step="$1"
  local batch_file="/tmp/e11-ip-batch.txt"
  : > "${batch_file}"
  if [[ "${step}" == "50" ]]; then
    echo "addr add 198.51.100.99/32 dev lo" >> "${batch_file}"
    for i in $(seq 1 50); do
      echo "addr add 198.18.1.${i}/32 dev lo" >> "${batch_file}"
    done
  elif [[ "${step}" == "200" ]]; then
    for i in $(seq 51 200); do
      echo "addr add 198.18.1.${i}/32 dev lo" >> "${batch_file}"
    done
  elif [[ "${step}" == "300" ]]; then
    for i in $(seq 1 100); do
      echo "addr add 198.18.2.${i}/32 dev lo" >> "${batch_file}"
    done
  fi
  nsenter -t "${CE_PID}" -n ip -batch "${batch_file}"
  rm -f "${batch_file}"
}

reset_ce_lo_prefixes() {
  local batch_file="/tmp/e11-ip-del.txt"
  : > "${batch_file}"
  echo "addr del 198.51.100.99/32 dev lo" >> "${batch_file}"
  for i in $(seq 1 200); do
    echo "addr del 198.18.1.${i}/32 dev lo" >> "${batch_file}"
  done
  for i in $(seq 1 100); do
    echo "addr del 198.18.2.${i}/32 dev lo" >> "${batch_file}"
  done
  nsenter -t "${CE_PID}" -n ip -batch "${batch_file}" >/dev/null 2>&1 || true
  rm -f "${batch_file}"
}

CILIUM_POD="$(k -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName="${WORKER_NODE}" -o jsonpath='{.items[0].metadata.name}')"

echo "=== [E11] 3. Célula 1: Cilium Direto (${WORKER_NODE} AS ${WORKER_ASN} <-> ${FRR_CE_CTR} AS ${CE_ASN}) ==="
cat <<EOF | k apply -f -
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata:
  name: e11-direct-peer
spec:
  timers:
    connectRetryTimeSeconds: 3
    holdTimeSeconds: 9
    keepAliveTimeSeconds: 3
  families:
    - afi: ipv4
      safi: unicast
      advertisements:
        matchLabels:
          advertise: bgp
---
apiVersion: cilium.io/v2
kind: CiliumBGPClusterConfig
metadata:
  name: rack2
  labels:
    study: P003
spec:
  nodeSelector:
    matchLabels:
      topology.kubernetes.io/rack: rack2
  bgpInstances:
  - name: "rack2"
    localASN: 65302
    peers:
    - name: "leaf2"
      peerASN: 65202
      peerAddress: 10.30.2.1
      peerConfigRef:
        name: "fabric-peer"
    - name: "frr-e11-ce"
      peerASN: ${CE_ASN}
      peerAddress: "${CE_CILIUM_IP}"
      peerConfigRef:
        name: "e11-direct-peer"
EOF

for attempt in $(seq 1 30); do
  if k -n kube-system exec "${CILIUM_POD}" -- cilium-dbg bgp peers 2>/dev/null | grep "${CE_CILIUM_IP}" | grep -q "established"; then
    echo "Célula 1 BGP Established na tentativa ${attempt}"
    break
  fi
  sleep 1
done

for step in 50 200 300; do
  echo "--- [Célula 1] Injetando degrau ${step} prefixos declarados (+1 não declarado 198.51.100.99/32) ---"
  inject_prefixes_step "${step}"
  sleep 3
  echo "[Célula 1 — Degrau ${step}] cilium-dbg bgp peers:"
  k -n kube-system exec "${CILIUM_POD}" -- cilium-dbg bgp peers
  echo "[Célula 1 — Degrau ${step}] FRR CE neighbor ${CILIUM_LINK_IP} summary:"
  docker exec "${FRR_CE_CTR}" vtysh -c "show bgp ipv4 unicast summary" | grep -E "Neighbor|${CILIUM_LINK_IP}" || true
  KERNEL_BGP_ROUTES="$(docker exec "${WORKER_NODE}" ip -4 route show proto bgp | wc -l | tr -d ' ')"
  echo "cell1_step_${step}_kernel_proto_bgp_routes=${KERNEL_BGP_ROUTES}"
done

# Remover peer do Cilium e resetar prefixos na lo antes da Célula 2
restore_rack2_baseline
k delete ciliumbgppeerconfig e11-direct-peer --ignore-not-found >/dev/null 2>&1 || true
reset_ce_lo_prefixes
sleep 2

echo "=== [E11] 4. Célula 2: FRR Border PE (${BORDER_CTR} AS ${BORDER_ASN}) com prefix-list E11-IMPORT-ALLOW e maximum-prefix 100 ==="
inject_prefixes_step "50"

docker exec "${BORDER_CTR}" vtysh \
  -c "configure terminal" \
  -c "ip prefix-list E11-IMPORT-ALLOW seq 10 permit 198.18.0.0/16 le 32" \
  -c "ip prefix-list E11-IMPORT-ALLOW seq 20 deny any" \
  -c "route-map RM-E11-IMPORT permit 10" \
  -c "match ip address prefix-list E11-IMPORT-ALLOW" \
  -c "exit" \
  -c "router bgp ${BORDER_ASN}" \
  -c "neighbor ${CE_BORDER_IP} remote-as ${CE_ASN}" \
  -c "neighbor ${CE_BORDER_IP} description e11-frr-ce" \
  -c "neighbor ${CE_BORDER_IP} timers 3 9" \
  -c "address-family ipv4 unicast" \
  -c "neighbor ${CE_BORDER_IP} activate" \
  -c "neighbor ${CE_BORDER_IP} route-map RM-E11-IMPORT in" \
  -c "neighbor ${CE_BORDER_IP} maximum-prefix 100" \
  -c "exit-address-family" \
  -c "end"

for attempt in $(seq 1 30); do
  if docker exec "${BORDER_CTR}" vtysh -c "show bgp ipv4 unicast summary json" | grep -A15 "\"${CE_BORDER_IP}\"" | grep -q '"state":"Established"'; then
    echo "Célula 2A BGP Established em border1 na tentativa ${attempt}"
    break
  fi
  sleep 1
done
sleep 2

echo "--- [Subcélula 2A] 50 declarados (198.18.1.1..50/32) + 1 não declarado (198.51.100.99/32) sob RM-E11-IMPORT e maximum-prefix 100 ---"
docker exec "${BORDER_CTR}" vtysh -c "show bgp ipv4 unicast summary"
echo "[Subcélula 2A — Controle Positivo] Prefixo declarado 198.18.1.1/32 em border1:"
docker exec "${BORDER_CTR}" vtysh -c "show bgp ipv4 unicast 198.18.1.1/32"
echo "[Subcélula 2A — Controle Negativo] Prefixo NÃO declarado 198.51.100.99/32 em border1 (esperado: Network not in table):"
docker exec "${BORDER_CTR}" vtysh -c "show bgp ipv4 unicast 198.51.100.99/32" || true

echo "--- [Subcélula 2B] Escalando anúncio em ${FRR_CE_CTR} para 200 e 300 prefixos (> maximum-prefix 100) ---"
inject_prefixes_step "200"
inject_prefixes_step "300"
sleep 3

echo "[Subcélula 2B] Estado do neighbor ${CE_BORDER_IP} em ${BORDER_CTR} após exceder maximum-prefix 100:"
docker exec "${BORDER_CTR}" vtysh -c "show bgp ipv4 unicast summary"
docker exec "${BORDER_CTR}" vtysh -c "show bgp ipv4 unicast neighbors ${CE_BORDER_IP}" | grep -E "BGP state|Maximum-prefix|Last reset|Notification" || true
echo "[Subcélula 2B] Sessões primárias do Cilium intactas:"
k -n kube-system exec "${CILIUM_POD}" -- cilium-dbg bgp peers

echo "=== [E11] CONCLUÍDO COM SUCESSO ==="
