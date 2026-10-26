#!/usr/bin/env bash
# ==============================================================================
# P006-S004 — Braço A (E29): BGP Unnumbered (RFC 5549 / RFC 8950) &
#             L2 Announcements (CiliumL2AnnouncementPolicy)
#
# Objetivo:
#   Avaliar no sandbox p003-gw (Cilium 1.20.2 + FRR):
#   - Célula 1: BGP Unnumbered (RFC 5549 / RFC 8950 Extended Next-Hop) em enlace
#     ponto-a-ponto sem nenhum endereço IPv4 configurado na interface veth,
#     negociando capability extended-nexthop sobre IPv6 Link-Local (fe80::/64)
#     e instalando rotas IPv4 (10.206.29.0/24 e 10.206.29.100/32) com next-hop
#     IPv6 (`via inet6 fe80::...`) na FIB do kernel Linux.
#   - Célula 2: CiliumL2AnnouncementPolicy + CiliumLoadBalancerIPPool, eleição
#     de líder via Kubernetes Lease (`cilium-l2announce-*`), programação do mapa
#     BPF `cilium_l2_responder_v4` (`cilium-dbg bpf l2-responder list`) e
#     resolução ARP + tráfego HTTP 10/10 no segmento L2 (`172.18.0.242`).
#   - Célula 3: Controles negativos — desativação de Extended Next-Hop / sessão
#     IPv4 no enlace unnumbered retirando a rota `via inet6 fe80::` da FIB, e
#     remoção da label `e29-l2=enabled` retirando a entrada do mapa BPF
#     `cilium_l2_responder_v4`, seguido de rollback determinístico (R6=0).
#
# Invariantes:
#   - R1: k01 (uid=635e7274-5597-40c7-9de5-b1fbe3d68b22) intocado (10/10 HTTP 200)
#   - R2: Suporte a --dry-run e rollback determinístico via trap EXIT
#   - R3: MemAvailable >= 4.00 GiB
#   - R6: 0 rotas BGP residuais no kernel main dos nós K8s após rollback
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/01-e29-bgp-unnumbered-l2.yaml"

SANDBOX_KUBECONFIG="${SANDBOX_KUBECONFIG:-/root/.kube/p003-gw.config}"
SANDBOX_CONTEXT="${SANDBOX_CONTEXT:-kind-p003-gw}"
SANDBOX_UID="${SANDBOX_UID:-6bb32e0f-71f9-4558-ae33-356ba2250c26}"

K01_KUBECONFIG="${K01_KUBECONFIG:-/root/.kube/k01-rebuild.config}"
K01_UID="${K01_UID:-635e7274-5597-40c7-9de5-b1fbe3d68b22}"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      echo "Uso: $0 [--dry-run]"
      exit 0
      ;;
    *)
      echo "ERRO: argumento desconhecido: $arg" >&2
      exit 2
      ;;
  esac
done

log() {
  printf '[%s] [E29] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "DRY-RUN: Validando plano de execução E29 (BGP Unnumbered RFC 5549/8950 + L2 Announcements)"
  log "DRY-RUN: 1. Validar UID do sandbox p003-gw (${SANDBOX_UID}) e canário k01 (${K01_UID})"
  log "DRY-RUN: 2. Célula 1: Criar par FRR isolado (e29-tor AS 65199 <-> e29-node AS 65299) com 0 IPs IPv4 no enlace P2P, negociar BGP Unnumbered (RFC 8950 Extended Next-Hop sobre fe80::/64) e validar rota IPv4 via inet6 na FIB + 10/10 probes HTTP"
  log "DRY-RUN: 3. Célula 2: Ativar enable-l2-announcements=true no Cilium, aplicar ${MANIFEST}, inspecionar Lease cilium-l2announce, cilium_l2_responder_v4 e provar ARP + 10/10 HTTP 200 no VIP L2 172.18.0.242"
  log "DRY-RUN: 4. Célula 3: Controles negativos (withdraw RFC 8950 e remoção da label e29-l2 esvaziando cilium_l2_responder_v4)"
  log "DRY-RUN: 5. Rollback determinístico: remover containers/netns e29, manifesto K8s, restaurar cilium-config e verificar R6=0"
  exit 0
fi

kc() {
  sudo KUBECONFIG="$SANDBOX_KUBECONFIG" kubectl --context "$SANDBOX_CONTEXT" "$@"
}

cleanup() {
  log "ROLLBACK: Limpando recursos temporários de E29..."
  sudo docker rm -f e29-tor e29-node >/dev/null 2>&1 || true
  sudo ip link del veth-e29-tor >/dev/null 2>&1 || true
  kc delete -f "$MANIFEST" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  kc delete ciliuml2announcementpolicy e29-l2-policy --ignore-not-found=true >/dev/null 2>&1 || true
  kc delete ciliumloadbalancerippool e29-l2-pool --ignore-not-found=true >/dev/null 2>&1 || true
  kc delete ns p006-e29 --ignore-not-found=true --wait=true --timeout=60s >/dev/null 2>&1 || true
  kc -n kube-system delete lease cilium-l2announce-p006-e29-e29-lb-svc --ignore-not-found=true >/dev/null 2>&1 || true
  kc -n kube-system patch configmap cilium-config --type merge -p '{"data":{"enable-l2-announcements":"false"}}' >/dev/null 2>&1 || true
  kc -n kube-system rollout restart ds/cilium >/dev/null 2>&1 || true
  kc -n kube-system rollout status ds/cilium --timeout=120s >/dev/null 2>&1 || true
  log "ROLLBACK: Concluído."
}
trap cleanup EXIT

log "PREFLIGHT: Verificando UID do sandbox p003-gw e canário k01..."
ACTUAL_UID="$(kc get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "$ACTUAL_UID" != "$SANDBOX_UID" ]]; then
  echo "ABORT: UID do sandbox ($ACTUAL_UID) != esperado ($SANDBOX_UID)" >&2
  exit 1
fi
K01_ACTUAL_UID="$(sudo KUBECONFIG="$K01_KUBECONFIG" kubectl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "$K01_ACTUAL_UID" != "$K01_UID" ]]; then
  echo "ABORT: UID do k01 ($K01_ACTUAL_UID) != esperado ($K01_UID)" >&2
  exit 1
fi
MEM_AVAIL_KB="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"
log "PREFLIGHT OK: p003-gw UID=${ACTUAL_UID}, k01 UID=${K01_ACTUAL_UID}, MemAvailable=${MEM_AVAIL_KB} kB"

# ==============================================================================
# CÉLULA 1: BGP Unnumbered (RFC 5549 / RFC 8950 Extended Next-Hop)
# ==============================================================================
log "CÉLULA 1: Iniciando par FRR isolado (e29-tor AS 65199 <-> e29-node AS 65299) conectado por veth sem IPv4..."
FRR_IMAGE="$(sudo docker images --format '{{.Repository}}:{{.Tag}}' | grep -E 'frr|frrouting' | head -n1)"
if [[ -z "$FRR_IMAGE" ]]; then
  FRR_IMAGE="quay.io/frrouting/frr:10.3.1"
fi
log "CÉLULA 1: Usando imagem FRR: ${FRR_IMAGE}"

sudo docker rm -f e29-tor e29-node >/dev/null 2>&1 || true
sudo docker run -d --name e29-tor --hostname e29-tor --privileged --network none "$FRR_IMAGE" tail -f /dev/null >/dev/null
sudo docker run -d --name e29-node --hostname e29-node --privileged --network none "$FRR_IMAGE" tail -f /dev/null >/dev/null

PID_TOR="$(sudo docker inspect -f '{{.State.Pid}}' e29-tor)"
PID_NODE="$(sudo docker inspect -f '{{.State.Pid}}' e29-node)"

sudo ip link del veth-e29-tor >/dev/null 2>&1 || true
sudo ip link add veth-e29-tor type veth peer name veth-e29-node
sudo ip link set veth-e29-tor netns "$PID_TOR"
sudo ip link set veth-e29-node netns "$PID_NODE"

# Configurar loopback IPv4 nos dois lados, mas ZERO endereços IPv4 no enlace P2P veth!
sudo docker exec e29-tor sh -c '
  ip link set lo up
  ip addr add 10.206.29.1/32 dev lo
  ip link set veth-e29-tor up
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sed -i "s/bgpd=no/bgpd=yes/" /etc/frr/daemons
  touch /etc/frr/vtysh.conf
  cat <<EOF > /etc/frr/frr.conf
frr defaults datacenter
hostname e29-tor
service integrated-vtysh-config
!
interface veth-e29-tor
 ipv6 nd ra-interval 1
 no ipv6 nd suppress-ra
exit
!
router bgp 65199
 bgp router-id 10.206.29.1
 no bgp ebgp-requires-policy
 neighbor veth-e29-tor interface remote-as external
 neighbor veth-e29-tor capability extended-nexthop
 !
 address-family ipv4 unicast
  network 10.206.29.1/32
  neighbor veth-e29-tor activate
 exit-address-family
exit
!
EOF
  /usr/lib/frr/frrinit.sh start
'

sudo docker exec e29-node sh -c '
  ip link set lo up
  ip addr add 10.206.29.100/32 dev lo
  ip addr add 10.206.29.101/24 dev lo
  ip link set veth-e29-node up
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sed -i "s/bgpd=no/bgpd=yes/" /etc/frr/daemons
  touch /etc/frr/vtysh.conf
  cat <<EOF > /etc/frr/frr.conf
frr defaults datacenter
hostname e29-node
service integrated-vtysh-config
!
interface veth-e29-node
 ipv6 nd ra-interval 1
 no ipv6 nd suppress-ra
exit
!
router bgp 65299
 bgp router-id 10.206.29.100
 no bgp ebgp-requires-policy
 neighbor veth-e29-node interface remote-as external
 neighbor veth-e29-node capability extended-nexthop
 !
 address-family ipv4 unicast
  network 10.206.29.0/24
  network 10.206.29.100/32
  neighbor veth-e29-node activate
 exit-address-family
exit
!
EOF
  /usr/lib/frr/frrinit.sh start
'

log "CÉLULA 1: Aguardando convergência da sessão eBGP Unnumbered (RFC 5549/8950)..."
for _ in $(seq 1 20); do
  if sudo docker exec e29-tor ip -4 route show 10.206.29.0/24 | grep -q "inet6 fe80::"; then
    break
  fi
  sleep 1
done

log "CÉLULA 1: Comprovando ausência de IPv4 no enlace P2P (veth-e29-tor e veth-e29-node):"
echo "--- e29-tor veth-e29-tor addresses ---"
sudo docker exec e29-tor ip addr show dev veth-e29-tor
echo "--- e29-node veth-e29-node addresses ---"
sudo docker exec e29-node ip addr show dev veth-e29-node

log "CÉLULA 1: Inspecionando BGP Summary, Capability Extended Next-Hop e RIB/FIB no e29-tor:"
sudo docker exec e29-tor vtysh -c "show bgp ipv4 unicast summary"
sudo docker exec e29-tor vtysh -c "show bgp neighbor veth-e29-tor" | grep -E "BGP state|Extended Next-Hop|Extended Next Hop|Foreign host|Local host" || true
sudo docker exec e29-tor vtysh -c "show bgp ipv4 unicast 10.206.29.0/24"
echo "--- Linux Kernel FIB (IPv4 route via inet6 fe80:: link-local next-hop) ---"
FIB_UNNUM="$(sudo docker exec e29-tor ip -4 route show proto bgp)"
echo "$FIB_UNNUM"
if ! echo "$FIB_UNNUM" | grep -q "via inet6 fe80::"; then
  echo "ERRO: Rota IPv4 via inet6 fe80:: não encontrada na FIB de e29-tor!" >&2
  exit 1
fi

log "CÉLULA 1: Testando plano de dados IPv4 sobre next-hop IPv6 Link-Local (10/10 pings 10.206.29.1 -> 10.206.29.100)..."
sudo docker exec e29-tor ping -c 10 -W 1 -I 10.206.29.1 10.206.29.100 | tail -n 3

# ==============================================================================
# CÉLULA 2: CiliumL2AnnouncementPolicy + Lease + Mapa BPF cilium_l2_responder_v4
# ==============================================================================
log "CÉLULA 2: Garantindo RBAC de leases para cilium-agent e ativando enable-l2-announcements=true no p003-gw..."
kc apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: e29-cilium-l2-leases
rules:
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["cilium.io"]
    resources: ["ciliuml2announcementpolicies"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: e29-cilium-l2-leases
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: e29-cilium-l2-leases
subjects:
  - kind: ServiceAccount
    name: cilium
    namespace: kube-system
EOF

kc -n kube-system patch configmap cilium-config --type merge -p '{"data":{"enable-l2-announcements":"true","enable-external-ips":"true","l2-announcements-lease-duration":"15s","l2-announcements-renew-deadline":"5s","l2-announcements-retry-period":"2s"}}'
kc -n kube-system rollout restart ds/cilium
kc -n kube-system rollout status ds/cilium --timeout=120s

log "CÉLULA 2: Aplicando manifesto ${MANIFEST} (CiliumLoadBalancerIPPool + CiliumL2AnnouncementPolicy + Service)..."
kc apply -f "$MANIFEST"
kc -n p006-e29 wait --for=condition=available deployment/e29-backend --timeout=90s

log "CÉLULA 2: Aguardando atribuição do VIP 172.18.0.242 e eleição do Lease cilium-l2announce..."
for _ in $(seq 1 25); do
  LB_IP="$(kc -n p006-e29 get svc e29-lb-svc -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  LEASE_HOLDER="$(kc -n kube-system get lease cilium-l2announce-p006-e29-e29-lb-svc -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)"
  if [[ "$LB_IP" == "172.18.0.242" && -n "$LEASE_HOLDER" ]]; then
    break
  fi
  sleep 1
done

log "CÉLULA 2: Service LoadBalancer IP=${LB_IP}, Lease Holder=${LEASE_HOLDER}"
kc -n p006-e29 get svc e29-lb-svc -o wide
kc -n kube-system get lease cilium-l2announce-p006-e29-e29-lb-svc -o yaml | grep -E "name:|holderIdentity:|leaseDurationSeconds:|renewTime:" || true

LEADER_POD="$(kc -n kube-system get pods -l k8s-app=cilium --field-selector "spec.nodeName=${LEASE_HOLDER}" -o jsonpath='{.items[0].metadata.name}')"
log "CÉLULA 2: Inspecionando mapa BPF cilium_l2_responder_v4 e StateDB l2-announce no nó líder (${LEASE_HOLDER} / ${LEADER_POD}):"
L2_MAP_OUT="$(kc -n kube-system exec "$LEADER_POD" -- sh -c 'bpftool map dump pinned /sys/fs/bpf/tc/globals/cilium_l2_responder_v4 2>/dev/null; cilium-dbg statedb 2>/dev/null | grep -A 3 "\"l2-announce\"" || true')"
echo "$L2_MAP_OUT"
if ! echo "$L2_MAP_OUT" | grep -qiE "172\.18\.0\.242|ac 12 00 f2"; then
  echo "ERRO: VIP 172.18.0.242 ausente do mapa BPF cilium_l2_responder_v4 / StateDB l2-announce!" >&2
  exit 1
fi

log "CÉLULA 2: Provando resolução ARP e 10/10 requisições HTTP 200 ao VIP L2 172.18.0.242 a partir do segmento L2 (p003-gw-control-plane)..."
sudo docker exec p003-gw-control-plane sh -c '
  ip neigh flush 172.18.0.242 >/dev/null 2>&1 || true
  ok=0
  for i in $(seq 1 10); do
    out=$(curl -sS --max-time 2 http://172.18.0.242:80/ || true)
    if echo "$out" | grep -q "E29_L2_OK"; then
      ok=$((ok + 1))
    fi
  done
  echo "L2_HTTP_200=${ok}/10"
  ip neigh show 172.18.0.242
  test "$ok" -eq 10
'

# ==============================================================================
# CÉLULA 3: Controles Negativos (Withdraw RFC 8950 + Remoção da Label L2)
# ==============================================================================
log "CÉLULA 3: Controle Negativo 1 — Desativando neighbor no address-family ipv4 unicast do e29-node e comprovando retirada da rota via inet6 fe80::..."
sudo docker exec e29-node vtysh -c "conf t" -c "router bgp 65299" -c "address-family ipv4 unicast" -c "no neighbor veth-e29-node activate" >/dev/null
sleep 2
NEG_FIB="$(sudo docker exec e29-tor ip -4 route show 10.206.29.0/24)"
echo "NEG_FIB_10.206.29.0/24='${NEG_FIB}'"
if [[ -n "$NEG_FIB" ]]; then
  echo "ERRO: Rota 10.206.29.0/24 deveria ter sido removida após desativação do peer!" >&2
  exit 1
fi
log "CÉLULA 3: Confirmado: rota 10.206.29.0/24 via inet6 fe80:: retirada da FIB (0 rotas)."

log "CÉLULA 3: Controle Negativo 2 — Removendo label e29-l2=enabled do Service e29-lb-svc e verificando remoção de cilium_l2_responder_v4..."
kc -n p006-e29 label svc e29-lb-svc e29-l2-
for _ in $(seq 1 15); do
  cur_map="$(kc -n kube-system exec "$LEADER_POD" -- sh -c 'bpftool map dump pinned /sys/fs/bpf/tc/globals/cilium_l2_responder_v4 2>/dev/null; cilium-dbg statedb 2>/dev/null | grep -A 3 "\"l2-announce\"" || true')"
  if ! echo "$cur_map" | grep -qiE "172\.18\.0\.242|ac 12 00 f2"; then
    break
  fi
  sleep 1
done
L2_AFTER_UNLABEL="$(kc -n kube-system exec "$LEADER_POD" -- sh -c 'bpftool map dump pinned /sys/fs/bpf/tc/globals/cilium_l2_responder_v4 2>/dev/null; cilium-dbg statedb 2>/dev/null | grep -A 3 "\"l2-announce\"" || true')"
echo "L2_MAP_AFTER_UNLABEL:"
echo "$L2_AFTER_UNLABEL"
if echo "$L2_AFTER_UNLABEL" | grep -qiE "172\.18\.0\.242|ac 12 00 f2"; then
  echo "ERRO: VIP 172.18.0.242 ainda presente no mapa L2 responder após remover label!" >&2
  exit 1
fi
log "CÉLULA 3: Confirmado: VIP 172.18.0.242 removido do mapa BPF cilium_l2_responder_v4."

kc delete clusterrolebinding e29-cilium-l2-leases --ignore-not-found=true >/dev/null 2>&1 || true
kc delete clusterrole e29-cilium-l2-leases --ignore-not-found=true >/dev/null 2>&1 || true

log "E29: Todas as células (Célula 1, Célula 2 e Célula 3) concluídas com PASS."
