#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p004/ovnk/k04.sh — Caso K04: Coexistência com legado via NetworkAttachmentDefinition secundária (evpn-nad-fabric).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN="${DRY_RUN:-${LABCTL_DRY_RUN:-0}}"
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

OVNK_KUBECONFIG="${OVNK_KUBECONFIG:-/root/.kube/ovnk.config}"
OVNK_CONTEXT="${OVNK_CONTEXT:-kind-ovnk}"
OVNK_PEER_CONTAINER="${OVNK_PEER_CONTAINER:-ovnk-evpn-peer}"

k04_kctl() {
  if [[ -f "${OVNK_KUBECONFIG}" ]]; then
    kubectl --kubeconfig "${OVNK_KUBECONFIG}" --context "${OVNK_CONTEXT}" "$@"
  else
    kubectl --context "${OVNK_CONTEXT}" "$@"
  fi
}

if [[ "${DRY_RUN}" == "1" ]]; then
  printf 'DRY: configure OVS bridge-mappings evpn-nad-fabric:br-legacy on ovnkube-node pods\n'
  printf 'DRY: k04_kctl apply -f %s/evpn-nad-fabric.yaml\n' "${SCRIPT_DIR}"
  printf 'DRY: k04_kctl apply -f %s/k04-legacy-vm.yaml\n' "${SCRIPT_DIR}"
  printf 'DRY: k04_kctl -n tenant-a wait vmi vm-legacy --for=condition=Ready --timeout=240s\n'
  printf 'DRY: k04_kctl -n tenant-a exec probe-a -- ping -c 5 -W 2 10.0.0.99 (Primary UDN preconfigured IP coexistence)\n'
  printf 'DRY: docker exec %s ping -c 5 -W 2 192.168.100.11 (localnet NAD secondary interface)\n' "${OVNK_PEER_CONTAINER}"
  printf 'K04 DRY-RUN OK\n'
  exit 0
fi

# 1. Configurar OVS bridge br-legacy e ovn-bridge-mappings="evpn-nad-fabric:br-legacy" em todos os nós do cluster (P1-4)
for ovnk_pod in $(k04_kctl -n ovn-kubernetes get pods -l app=ovnkube-node -o jsonpath='{.items[*].metadata.name}'); do
  k04_kctl -n ovn-kubernetes exec -i "${ovnk_pod}" -c ovnkube-controller -- bash -s <<'EOF'
set -euo pipefail
ovs-vsctl --may-exist add-br br-legacy
ip link set br-legacy up
cur="$(ovs-vsctl --if-exists get Open_vSwitch . external_ids:ovn-bridge-mappings | tr -d '"' || true)"
if [[ -z "${cur}" ]]; then
  ovs-vsctl set Open_vSwitch . external_ids:ovn-bridge-mappings="evpn-nad-fabric:br-legacy"
elif [[ ",${cur}," != *",evpn-nad-fabric:br-legacy,"* ]]; then
  ovs-vsctl set Open_vSwitch . external_ids:ovn-bridge-mappings="${cur},evpn-nad-fabric:br-legacy"
fi
EOF
done

# 2. Aplicar NAD secundária localnet evpn-nad-fabric (192.168.100.0/24) e VM legada dual-homed com IP pré-configurado 10.0.0.99/24 (vm-legacy)
k04_kctl apply -f "${SCRIPT_DIR}/evpn-nad-fabric.yaml"
k04_kctl apply -f "${SCRIPT_DIR}/k04-legacy-vm.yaml"
for _ in $(seq 1 30); do
  if k04_kctl -n tenant-a get vmi vm-legacy >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
k04_kctl -n tenant-a wait vmi vm-legacy --for=condition=Ready --timeout=240s

# 3. Verificar que a VMI vm-legacy está Running com 2 interfaces (default + legacy-net)
if_count="$(k04_kctl -n tenant-a get vmi vm-legacy -o json | jq '.status.interfaces | length')"
if [[ "${if_count}" -lt 2 ]]; then
  printf '[k04] ERRO: vmi/vm-legacy possui menos de 2 interfaces (count=%s)\n' "${if_count}" >&2
  exit 1
fi

# 4. Validar coexistência na UDN primária (IP pré-configurado 10.0.0.99/24 sem conflito de IPAM com vm-a 10.0.0.11/24 + verificação via /dev/ttyS0)
for _ in $(seq 1 45); do
  if k04_kctl -n tenant-a exec probe-a -- ping -c 1 -W 1 10.0.0.99 >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
legacy_pod="$(k04_kctl -n tenant-a get pods -l kubevirt.io=virt-launcher,kubevirt.io/domain=vm-legacy --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
guest_legacy_ip="$(k04_kctl -n tenant-a logs "${legacy_pod}" -c guest-console-log --tail=50 2>/dev/null | awk -F= '/GUEST_OS_IP=/{print $2}' | tail -n1 | tr -d '\r[:space:]')"
if [[ -z "${guest_legacy_ip}" ]]; then
  guest_legacy_ip="$(k04_kctl -n tenant-a logs "${legacy_pod}" -c compute --tail=50 2>/dev/null | awk -F= '/GUEST_OS_IP=/{print $2}' | tail -n1 | tr -d '\r[:space:]')"
fi
if [[ -n "${guest_legacy_ip}" ]] && [[ "${guest_legacy_ip}" != "10.0.0.99/24" ]]; then
  printf '[k04] ERRO: IP primário no guest OS de vm-legacy (%s) difere de 10.0.0.99/24\n' "${guest_legacy_ip}" >&2
  exit 1
fi
if ! k04_kctl -n tenant-a exec probe-a -- ping -c 5 -W 2 10.0.0.99 >/dev/null; then
  printf '[k04] ERRO: ping na UDN primária para o IP pré-configurado de vm-legacy (probe-a -> 10.0.0.99) falhou\n' >&2
  exit 1
fi
if ! k04_kctl -n tenant-a exec probe-a -- ping -c 5 -W 2 10.0.0.11 >/dev/null; then
  printf '[k04] ERRO: coexistência na UDN primária falhou (probe-a -> vm-a 10.0.0.11)\n' >&2
  exit 1
fi

# 5. Interligar br-legacy (OVS localnet) do nó onde vm-legacy roda ao ovnk-evpn-peer (192.168.100.254/24) via VXLAN VNI 20400
vm_node="$(k04_kctl -n tenant-a get vmi vm-legacy -o jsonpath='{.status.nodeName}')"
ovnk_vm_pod="$(k04_kctl -n ovn-kubernetes get pods -l app=ovnkube-node --field-selector="spec.nodeName=${vm_node}" -o jsonpath='{.items[0].metadata.name}')"
node_ip="$(docker inspect -f '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' "${vm_node}")"
peer_ip="$(docker inspect -f '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' "${OVNK_PEER_CONTAINER}")"

k04_kctl -n ovn-kubernetes exec "${ovnk_vm_pod}" -c ovnkube-controller -- bash -c "
  set -euo pipefail
  ip link del vxlan-20400 2>/dev/null || true
  ip link add vxlan-20400 type vxlan id 20400 dstport 4790 local ${node_ip} remote ${peer_ip} dev breth0
  ip link set vxlan-20400 up
  ovs-vsctl --may-exist add-port br-legacy vxlan-20400
"

docker exec "${OVNK_PEER_CONTAINER}" bash -c "
  set -euo pipefail
  ip link show br-legacy >/dev/null 2>&1 || ip link add br-legacy type bridge
  ip link set br-legacy up
  ip addr replace 192.168.100.254/24 dev br-legacy
  ip link del vxlan-20400 2>/dev/null || true
  ip link add vxlan-20400 type vxlan id 20400 dstport 4790 local ${peer_ip} remote ${node_ip} dev eth0
  ip link set vxlan-20400 master br-legacy up
"

# 6. Validar 5/5 pings entre ovnk-evpn-peer (192.168.100.254) e a interface secundária localnet da VM (192.168.100.11)
if ! docker exec "${OVNK_PEER_CONTAINER}" ping -c 5 -W 2 192.168.100.11 >/dev/null; then
  printf '[k04] ERRO: ping pela NAD secundária localnet (192.168.100.254 -> 192.168.100.11) falhou\n' >&2
  exit 1
fi

printf 'K04 PASS: vmi/vm-legacy Running em %s com %s interfaces; coexistência UDN primária 10.0.0.99/24 + 10.0.0.11/24 (5/5 pings) e NAD localnet evpn-nad-fabric 192.168.100.254 <-> 192.168.100.11 (5/5 pings) OK.\n' \
  "${vm_node}" "${if_count}"
