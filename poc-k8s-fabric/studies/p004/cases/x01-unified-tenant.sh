#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p004/cases/x01-unified-tenant.sh — Caso X01 (Gate G04):
# Tenant 'a' unificado na mesma L3VNI (10100, RT 65000:10100) entre os 3 planos:
#   1. DCI OVN VPC (ls-dci-tenant, 192.168.100.10/24 em ovn-chassis-1)
#   2. DCI Connect On-Prem (dci-client-1, 10.0.200.1/32 em 10.0.0.0/16 via ovn-gw-1/ovn-gw-2)
#   3. EVPN Fabric Spine (evpnfab-peer, 10.251.0.1/32 em vrf-tenant-a, VNI 10100)
#   4. OVN-Kubernetes + KubeVirt (cudnevpn, VM vm-evpn-a 10.0.0.21/24 e pod-evpn 10.0.0.4/24)

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="${LAB_ROOT:-$(cd "${SCRIPT_DIR}/../../.." && pwd)}"
DRY_RUN="${DRY_RUN:-${LABCTL_DRY_RUN:-0}}"
ACTION="run"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    up|verify|down|run)
      ACTION="$1"
      shift
      ;;
    *)
      printf 'Uso: %s [--dry-run] [up|verify|down|run]\n' "$0" >&2
      exit 2
      ;;
  esac
done

OVNK_KUBECONFIG="${OVNK_KUBECONFIG:-/root/.kube/ovnk.config}"
OVNK_CONTEXT="${OVNK_CONTEXT:-kind-ovnk}"
OVNK_PEER="ovnk-evpn-peer"
FAB_PEER="evpnfab-peer"
FAB_GW2="evpnfab-gw2"
DCI_CENTRAL="ovn-central-az1"
DCI_CHASSIS="ovn-chassis-1"
DCI_GW1="ovn-gw-1"
DCI_GW2="ovn-gw-2"
DCI_CLIENT="dci-client-1"

X_BRIDGE="br-x-fabric"
FAB_XF_IP="10.254.0.1"
OVNK_XF_IP="10.254.0.2"
DCI_XF_IP="10.254.0.3"
L3VNI_A="10100"
RT_A="65000:10100"
COMM_A="65000:101"
COMM_B="65000:102"

DCI_VPC_IP="192.168.100.10"
DCI_ONPREM_IP="10.0.200.1"
FAB_LO_IP="10.251.0.1"
OVNK_VM_IP="10.0.0.21"
OVNK_VM_MAC="02:00:10:00:01:21"

x01_log() {
  printf '[x01] %s\n' "$*"
}

x01_die() {
  printf '[x01] ERRO: %s\n' "$*" >&2
  exit 1
}

x01_kctl() {
  if [[ -f "${OVNK_KUBECONFIG}" ]]; then
    kubectl --kubeconfig "${OVNK_KUBECONFIG}" --context "${OVNK_CONTEXT}" "$@"
  else
    kubectl --context "${OVNK_CONTEXT}" "$@"
  fi
}

x01_assert_invariants() {
  local p003_os_status
  p003_os_status="$(docker inspect -f '{{.State.Status}}' p003-os 2>/dev/null || echo 'absent')"
  if [[ "${p003_os_status}" != "exited" ]]; then
    x01_die "Guardrail violado: container p003-os deve permanecer exited (status=${p003_os_status})"
  fi
  local k01_uid
  k01_uid="$(kubectl --context kind-k01 get ns kube-system -o json 2>/dev/null | jq -r '.metadata.uid // empty' || true)"
  if [[ "${k01_uid}" != "635e7274-5597-40c7-9de5-b1fbe3d68b22" ]]; then
    x01_die "Guardrail violado: UID do cluster canário k01 mudou ou está inacessível (uid=${k01_uid})"
  fi
}

x01_on_err() {
  local rc=$?
  trap - ERR
  printf '[x01] WARN: falha detectada durante setup (rc=%s); executando rollback x01_down...\n' "${rc}" >&2
  x01_down || true
  exit "${rc}"
}

x01_print_dry_run() {
  printf 'DRY: ip link add %s type bridge && ip link set %s up\n' "${X_BRIDGE}" "${X_BRIDGE}"
  printf 'DRY: attach veth pairs to %s: %s (%s/24), %s (%s/24), %s (%s/24)\n' \
    "${X_BRIDGE}" "${FAB_PEER}" "${FAB_XF_IP}" "${OVNK_PEER}" "${OVNK_XF_IP}" "${DCI_CHASSIS}" "${DCI_XF_IP}"
  printf 'DRY: configure %s OVN native EVPN on L3VNI %s (ovnvrf-tenant table 300, br-evpn-tenant, vxlan-tenant, FRR pathspace x01 AS 65100)\n' \
    "${DCI_CHASSIS}" "${L3VNI_A}"
  printf 'DRY: configure %s on-prem loopback %s/32 and routes for 10.0.0.0/24 + 10.251.0.0/24 via %s/%s\n' \
    "${DCI_CLIENT}" "${DCI_ONPREM_IP}" "${DCI_GW1}" "${DCI_GW2}"
  printf 'DRY: configure %s (AS 65002) vrf-tenant-a L3VNI %s RT %s community %s and VXLAN interconnect to %s\n' \
    "${FAB_PEER}" "${L3VNI_A}" "${RT_A}" "${COMM_A}" "${OVNK_PEER}"
  printf 'DRY: deploy KubeVirt VM vm-evpn-a (%s/24, MAC %s) in namespace tenant-evpn (cudnevpn, L3VNI %s)\n' \
    "${OVNK_VM_IP}" "${OVNK_VM_MAC}" "${L3VNI_A}"
  printf 'DRY: verify BGP Established + EVPN Type-5 JSON RIB across %s, %s, %s\n' \
    "${DCI_CHASSIS}" "${FAB_PEER}" "${OVNK_PEER}"
  printf 'DRY: verify 5/5 ICMP probes + tcpdump VXLAN VNI %s across DCI VPC (%s) <-> OVN-K KubeVirt VM (%s) <-> DCI Connect On-Prem (%s) <-> EVPN Spine (%s)\n' \
    "${L3VNI_A}" "${DCI_VPC_IP}" "${OVNK_VM_IP}" "${DCI_ONPREM_IP}" "${FAB_LO_IP}"
  printf 'X01 DRY-RUN OK\n'
}

if [[ "${DRY_RUN}" == "1" ]]; then
  x01_print_dry_run
  exit 0
fi

x01_attach_veth() {
  local container="$1"
  local br_if="$2"
  local c_if="$3"
  local ip_cidr="$4"
  local pid
  pid="$(docker inspect -f '{{.State.Pid}}' "${container}")"
  [[ -n "${pid}" && "${pid}" != "0" ]] || x01_die "Container ${container} não está em execução"

  ip link del "${br_if}" 2>/dev/null || true
  docker exec "${container}" ip link del "${c_if}" 2>/dev/null || true

  ip link add "${br_if}" type veth peer name "${c_if}"
  ip link set "${br_if}" master "${X_BRIDGE}" up
  ip link set "${c_if}" netns "${pid}"
  docker exec "${container}" ip link set "${c_if}" up
  docker exec "${container}" ip addr replace "${ip_cidr}" dev "${c_if}"
}

x01_setup_interconnect() {
  x01_log "Configurando bridge de interconexão cross-plane ${X_BRIDGE} (10.254.0.0/24)..."
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  if ! ip link show "${X_BRIDGE}" >/dev/null 2>&1; then
    ip link add "${X_BRIDGE}" type bridge
  fi
  ip link set "${X_BRIDGE}" up
  iptables -C FORWARD -i "${X_BRIDGE}" -o "${X_BRIDGE}" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -i "${X_BRIDGE}" -o "${X_BRIDGE}" -j ACCEPT

  x01_attach_veth "${FAB_PEER}" "veth-xf-peer-b" "veth-xf-peer" "${FAB_XF_IP}/24"
  x01_attach_veth "${OVNK_PEER}" "veth-xf-ovnk-b" "veth-xf-ovnk" "${OVNK_XF_IP}/24"
  x01_attach_veth "${DCI_CHASSIS}" "veth-xf-dci-b" "veth-xf-dci" "${DCI_XF_IP}/24"
}

x01_setup_dci_plane() {
  x01_log "Configurando plano DCI (${DCI_CENTRAL}, ${DCI_CHASSIS}, ${DCI_GW1}, ${DCI_GW2}, ${DCI_CLIENT}) na L3VNI ${L3VNI_A}..."

  # 1. Configurar OVN NB em ovn-central-az1 para L3VNI 10100 em ls-dci-tenant e maintain-vrf em lrp-dci-tenant
  docker exec "${DCI_CENTRAL}" sh -c "
    set -eu
    ovn-nbctl --wait=sb set logical_switch ls-dci-tenant other_config:dynamic-routing-vni=${L3VNI_A}
    ovn-nbctl --wait=sb set logical_router_port lrp-dci-tenant \
      options:dynamic-routing-maintain-vrf=true \
      options:dynamic-routing-port-name=x01-evpn
    ovn-nbctl --may-exist lr-route-add lr-dci-tenant 10.0.0.1/32 10.100.100.2
    ovn-nbctl --may-exist lr-route-add lr-dci-100 10.0.0.0/24 10.100.100.1
    ovn-nbctl --may-exist lr-route-add lr-dci-100 10.251.0.0/24 10.100.100.1
    ovn-nbctl --may-exist lr-route-add lr-dci-100 10.253.0.0/24 10.100.100.1
    ovn-nbctl --may-exist lr-route-add lr-dci-200 10.0.0.0/24 10.200.100.1
    ovn-nbctl --may-exist lr-route-add lr-dci-200 10.251.0.0/24 10.200.100.1
    ovn-nbctl --may-exist lr-route-add lr-dci-200 10.253.0.0/24 10.200.100.1
  "

  # 2. Configurar OVS external_ids em ovn-chassis-1 e aguardar ovnvrf-tenant
  docker exec "${DCI_CHASSIS}" sh -c "
    set -eu
    ovs-vsctl set Open_vSwitch . \
      external_ids:ovn-evpn-local-ip=\"${L3VNI_A}-${DCI_XF_IP}\" \
      external_ids:dynamic-routing-port-mapping=\"x01-evpn=br-evpn-tenant\"
  "

  local vrf_ok=0
  for _ in $(seq 1 30); do
    if docker exec "${DCI_CHASSIS}" ip link show ovnvrf-tenant >/dev/null 2>&1; then
      vrf_ok=1
      break
    fi
    sleep 1
  done
  [[ "${vrf_ok}" -eq 1 ]] || x01_die "ovnvrf-tenant não apareceu em ${DCI_CHASSIS}"

  # 3. Criar interfaces EVPN e iniciar FRR no pathspace x01 em ovn-chassis-1
  docker exec "${DCI_CHASSIS}" bash -c "
    set -euo pipefail
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null

    for dev in evpn-tenant vxlan-tenant br-evpn-tenant; do
      ip link del \"\${dev}\" 2>/dev/null || true
    done

    ip link add br-evpn-tenant type bridge
    ip link set br-evpn-tenant master ovnvrf-tenant addrgenmode none address 02:00:00:10:00:01 up

    ip link add vxlan-tenant type vxlan dev vxlan_sys_4789 id ${L3VNI_A} dstport 60010 local ${DCI_XF_IP} nolearning
    ip link set vxlan-tenant master br-evpn-tenant up

    ip link add evpn-tenant type dummy
    ip link set evpn-tenant master br-evpn-tenant up

    init=''
    for candidate in /usr/libexec/frr/frrinit.sh /usr/lib/frr/frrinit.sh; do
      if [ -x \"\${candidate}\" ]; then init=\"\${candidate}\"; break; fi
    done
    if [ -n \"\${init}\" ] && [ -d /run/frr/x01 ]; then
      \"\${init}\" stop x01 >/dev/null 2>&1 || true
    fi
    rm -rf /etc/frr/x01 /run/frr/x01
    mkdir -p /etc/frr/x01 /run/frr/x01

    cat >/etc/frr/x01/daemons <<'DAEMONS'
zebra=yes
bgpd=yes
staticd=yes
bfdd=no
ospfd=no
ospf6d=no
ripd=no
ripngd=no
isisd=no
pimd=no
pim6d=no
ldpd=no
nhrpd=no
eigrpd=no
sharpd=no
pbrd=no
fabricd=no
vrrpd=no
vtysh_enable=yes
DAEMONS
    : >/etc/frr/x01/vtysh.conf

    cat >/etc/frr/x01/frr.conf <<'FRR'
frr defaults traditional
hostname ovn-chassis-1-x01
service integrated-vtysh-config
!
ip prefix-list X01-DCI-EXPORT seq 5 permit 192.168.100.0/24
ip prefix-list X01-DCI-EXPORT seq 10 permit 10.0.0.0/16
!
route-map X01-DCI-EXPORT permit 10
 match ip address prefix-list X01-DCI-EXPORT
 set community ${COMM_A}
exit
!
vrf ovnvrf-tenant
 vni ${L3VNI_A}
exit-vrf
!
router bgp 65100
 bgp router-id ${DCI_XF_IP}
 no bgp ebgp-requires-policy
 neighbor ${FAB_XF_IP} remote-as 65002
 !
 address-family ipv4 unicast
  neighbor ${FAB_XF_IP} activate
 exit-address-family
 !
 address-family l2vpn evpn
  neighbor ${FAB_XF_IP} activate
  advertise-all-vni
  vni ${L3VNI_A}
   rd 65100:${L3VNI_A}
   route-target import ${RT_A}
   route-target export ${RT_A}
  exit-vni
 exit-address-family
exit
!
router bgp 65100 vrf ovnvrf-tenant
 bgp router-id ${DCI_XF_IP}
 no bgp ebgp-requires-policy
 !
 address-family ipv4 unicast
  redistribute kernel route-map X01-DCI-EXPORT
  redistribute connected route-map X01-DCI-EXPORT
 exit-address-family
 !
 address-family l2vpn evpn
  rd 65100:${L3VNI_A}
  route-target import ${RT_A}
  route-target export ${RT_A}
  advertise ipv4 unicast
 exit-address-family
exit
!
line vty
!
FRR

    if getent passwd frr >/dev/null 2>&1; then
      chown -R frr:frr /etc/frr/x01 /run/frr/x01
    fi
    vtysh -C -f /etc/frr/x01/frr.conf
    \"\${init}\" start x01
  "

  # 4. Anunciar 10.0.0.0/24 e 10.251.0.0/24 via DCI Connect (ovn-gw-1, ovn-gw-2 -> dci-client-1)
  docker exec "${DCI_GW1}" vtysh \
    -c "configure terminal" \
    -c "ip prefix-list MG-TO-CLIENT seq 20 permit 10.0.0.0/24" \
    -c "ip prefix-list MG-TO-CLIENT seq 30 permit 10.251.0.0/24" \
    -c "ip prefix-list MG-TO-CLIENT seq 40 permit 10.253.0.0/24" \
    -c "router bgp 100 vrf ovnvrf100" \
    -c "address-family ipv4 unicast" \
    -c "network 10.0.0.0/24" \
    -c "network 10.251.0.0/24" \
    -c "network 10.253.0.0/24" \
    -c "end"

  docker exec "${DCI_GW2}" vtysh \
    -c "configure terminal" \
    -c "ip prefix-list MG-TO-CLIENT seq 20 permit 10.0.0.0/24" \
    -c "ip prefix-list MG-TO-CLIENT seq 30 permit 10.251.0.0/24" \
    -c "ip prefix-list MG-TO-CLIENT seq 40 permit 10.253.0.0/24" \
    -c "router bgp 100 vrf ovnvrf200" \
    -c "address-family ipv4 unicast" \
    -c "network 10.0.0.0/24" \
    -c "network 10.251.0.0/24" \
    -c "network 10.253.0.0/24" \
    -c "end"

  docker exec "${DCI_CLIENT}" ip addr replace "${DCI_ONPREM_IP}/32" dev lo
  docker exec "${DCI_CLIENT}" vtysh \
    -c "configure terminal" \
    -c "ip prefix-list MG-TO-TENANT seq 20 permit 10.0.0.0/24" \
    -c "ip prefix-list MG-TO-TENANT seq 30 permit 10.251.0.0/24" \
    -c "ip prefix-list MG-TO-TENANT seq 40 permit 10.253.0.0/24" \
    -c "end"
}

x01_setup_fabric_and_ovnk() {
  x01_log "Configurando interconexão EVPN Type-5 entre ${FAB_PEER} (vrf-tenant-a) e ${OVNK_PEER} (vrf-evpn-k03)..."

  # 1. Configurar evpnfab-peer:
  #    - vxlan-10100 em veth-xf-peer (10.254.0.1) para VTEP EVPN com ovn-chassis-1 (10.254.0.3)
  #    - vxlan-xf-10100 (dstport 4790, VNI 10100) para interligar vrf-tenant-a <-> vrf-evpn-k03 (ovnk-evpn-peer 10.254.0.2)
  #    - preservar vrf-tenant-b (VNI 10200, RT 65000:10200) ativo com evpnfab-gw2 (170.168.0.6)
  docker exec "${FAB_PEER}" bash -c "
    set -euo pipefail
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null

    ip link del vxlan-10100 2>/dev/null || true
    ip link add vxlan-10100 type vxlan id ${L3VNI_A} dstport 4789 local ${FAB_XF_IP} dev veth-xf-peer nolearning
    ip link set vxlan-10100 master br-vxlan-10100 up
    bridge link set dev vxlan-10100 learning off
    ip link set br-vxlan-10100 address 02:00:10:10:00:fe master vrf-tenant-a up

    ip link del vxlan-xf-10100 2>/dev/null || true
    ip link add vxlan-xf-10100 type vxlan id 10199 dstport 4790 local ${FAB_XF_IP} remote ${OVNK_XF_IP} dev veth-xf-peer nolearning
    ip link set vxlan-xf-10100 master vrf-tenant-a up
    ip addr replace 169.254.101.5/30 dev vxlan-xf-10100

    cat >/etc/frr/frr.conf <<FRR
frr defaults traditional
hostname evpnfab-peer
service integrated-vtysh-config
!
bgp community-list standard X03-COMM-TENANT-A permit ${COMM_A}
bgp community-list standard X03-COMM-TENANT-B permit ${COMM_B}
!
route-map X03-TAG-TENANT-A permit 10
 set community ${COMM_A} additive
exit
!
route-map X03-TAG-TENANT-B permit 10
 set community ${COMM_B} additive
exit
!
vrf vrf-tenant-a
 vni ${L3VNI_A}
exit-vrf
!
vrf vrf-tenant-b
 vni 10200
exit-vrf
!
router bgp 65002
 bgp router-id ${FAB_XF_IP}
 no bgp ebgp-requires-policy
 neighbor ${DCI_XF_IP} remote-as 65100
 neighbor 170.168.0.6 remote-as 65001
 neighbor 170.168.0.6 ebgp-multihop 2
 !
 address-family ipv4 unicast
  neighbor ${DCI_XF_IP} activate
  neighbor 170.168.0.6 activate
 exit-address-family
 !
 address-family l2vpn evpn
  neighbor ${DCI_XF_IP} activate
  neighbor 170.168.0.6 activate
  advertise-all-vni
  vni ${L3VNI_A}
   rd 65002:${L3VNI_A}
   route-target import ${RT_A}
   route-target export ${RT_A}
  exit-vni
  vni 10200
   rd 65002:10200
   route-target import 65000:10200
   route-target export 65000:10200
  exit-vni
 exit-address-family
exit
!
router bgp 65002 vrf vrf-tenant-a
 bgp router-id 10.251.0.1
 no bgp ebgp-requires-policy
 neighbor 169.254.101.6 remote-as 65000
 !
 address-family ipv4 unicast
  redistribute connected route-map X03-TAG-TENANT-A
  neighbor 169.254.101.6 activate
  neighbor 169.254.101.6 route-map X03-TAG-TENANT-A in
  neighbor 169.254.101.6 route-map X03-TAG-TENANT-A out
 exit-address-family
 !
 address-family l2vpn evpn
  rd 65002:${L3VNI_A}
  route-target import ${RT_A}
  route-target export ${RT_A}
  advertise ipv4 unicast route-map X03-TAG-TENANT-A
 exit-address-family
exit
!
router bgp 65002 vrf vrf-tenant-b
 bgp router-id 10.252.0.1
 no bgp ebgp-requires-policy
 !
 address-family ipv4 unicast
  redistribute connected route-map X03-TAG-TENANT-B
 exit-address-family
 !
 address-family l2vpn evpn
  rd 65002:10200
  route-target import 65000:10200
  route-target export 65000:10200
  advertise ipv4 unicast route-map X03-TAG-TENANT-B
 exit-address-family
exit
!
line vty
!
FRR
  "
  docker exec "${FAB_PEER}" bash -c '
    set -euo pipefail
    frr_dir=""
    for candidate in /usr/libexec/frr /usr/lib/frr; do
      if [ -x "${candidate}/zebra" ] && [ -x "${candidate}/bgpd" ]; then
        frr_dir="${candidate}"
        break
      fi
    done
    killall -q bgpd zebra bfdd staticd mgmtd 2>/dev/null || true
    sleep 1
    mkdir -p /var/run/frr /run/frr
    chown -R frr:frr /etc/frr /var/run/frr /run/frr 2>/dev/null || true
    for d in mgmtd zebra bgpd bfdd staticd; do
      if [ -x "${frr_dir}/${d}" ]; then
        "${frr_dir}/${d}" -d
      fi
    done
    for _ in $(seq 1 30); do
      if vtysh -c "show version" >/dev/null 2>&1 && vtysh -b >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
  '

  # 2. Marcar community 65000:102 em evpnfab-gw2 (Tenant b) para consistência com X03
  docker exec "${FAB_GW2}" vtysh \
    -c "configure terminal" \
    -c "route-map X03-GW2-TENANT-B permit 10" \
    -c "set community ${COMM_B} additive" \
    -c "exit" \
    -c "router bgp 65001 vrf vrf-tenant-b" \
    -c "address-family ipv4 unicast" \
    -c "redistribute connected route-map X03-GW2-TENANT-B" \
    -c "exit-address-family" \
    -c "address-family l2vpn evpn" \
    -c "advertise ipv4 unicast route-map X03-GW2-TENANT-B" \
    -c "end"

  # 3. Configurar ovnk-evpn-peer: vxlan-xf-10100 em vrf-evpn-k03 e peering eBGP com evpnfab-peer (169.254.101.5)
  docker exec "${OVNK_PEER}" bash -c "
    set -euo pipefail
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null

    ip link del vxlan-xf-10100 2>/dev/null || true
    ip link add vxlan-xf-10100 type vxlan id 10199 dstport 4790 local ${OVNK_XF_IP} remote ${FAB_XF_IP} dev veth-xf-ovnk nolearning
    ip link set vxlan-xf-10100 master vrf-evpn-k03 up
    ip addr replace 169.254.101.6/30 dev vxlan-xf-10100
    ip link set brevpn.100 down && ip link set brevpn.100 master vrf-evpn-k03 up

    vtysh \
      -c 'configure terminal' \
      -c 'route-map X03-OVNK-TENANT-A permit 10' \
      -c 'set community ${COMM_A} additive' \
      -c 'exit' \
      -c 'router bgp 65000 vrf vrf-evpn-k03' \
      -c 'no bgp ebgp-requires-policy' \
      -c 'neighbor 169.254.101.5 remote-as 65002' \
      -c 'address-family ipv4 unicast' \
      -c 'network 10.253.0.0/24' \
      -c 'neighbor 169.254.101.5 activate' \
      -c 'neighbor 169.254.101.5 route-map X03-OVNK-TENANT-A out' \
      -c 'exit-address-family' \
      -c 'address-family l2vpn evpn' \
      -c 'advertise ipv4 unicast route-map X03-OVNK-TENANT-A' \
      -c 'end' \
      -c 'write memory' >/dev/null
  "
  docker exec "${OVNK_PEER}" bash -c '
    set -euo pipefail
    for d in bgpd zebra bfdd staticd mgmtd; do pkill -x "${d}" || true; done
    sleep 1
    for d in mgmtd zebra bgpd bfdd staticd; do
      if [ -x "/usr/libexec/frr/${d}" ]; then
        "/usr/libexec/frr/${d}" -d
      elif [ -x "/usr/lib/frr/${d}" ]; then
        "/usr/lib/frr/${d}" -d
      fi
    done
    for _ in $(seq 1 30); do
      if vtysh -c "show version" >/dev/null 2>&1 && vtysh -b >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
  '
}

x01_deploy_ovnk_vm() {
  x01_log "Implantando KubeVirt VM vm-evpn-a (${OVNK_VM_IP}/24, MAC ${OVNK_VM_MAC}) em tenant-evpn (cudnevpn, L3VNI ${L3VNI_A})..."
  x01_kctl -n tenant-evpn apply -f - <<EOF
apiVersion: k8s.cni.cncf.io/v1alpha1
kind: IPAMClaim
metadata:
  name: vm-evpn-a-udn
  namespace: tenant-evpn
spec:
  network: cluster_udn_cudnevpn
  interface: ovn-udn1
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vm-evpn-a
  namespace: tenant-evpn
  labels:
    app: vm-evpn-a
    tenant: tenant-evpn
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        kubevirt.io/domain: vm-evpn-a
        app: vm-evpn-a
        tenant: tenant-evpn
      annotations:
        k8s.ovn.org/openflow-ports: ""
        v1.multus-cni.io/default-network: '[{"namespace":"ovn-kubernetes","name":"default","ips":["${OVNK_VM_IP}/24"],"mac":"${OVNK_VM_MAC}","ipam-claim-reference":"vm-evpn-a-udn"}]'
    spec:
      domain:
        cpu:
          cores: 1
        resources:
          requests:
            memory: 192Mi
        devices:
          autoattachSerialConsole: true
          logSerialConsole: true
          disks:
            - name: containerdisk
              disk:
                bus: virtio
            - name: cloudinitdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              binding:
                name: l2bridge
              macAddress: "${OVNK_VM_MAC}"
      networks:
        - name: default
          pod: {}
      volumes:
        - name: containerdisk
          containerDisk:
            image: quay.io/kubevirt/cirros-container-disk-demo:v1.9.0
        - name: cloudinitdisk
          cloudInitNoCloud:
            networkData: |
              version: 2
              ethernets:
                eth0:
                  match:
                    macaddress: "${OVNK_VM_MAC}"
                  addresses:
                    - ${OVNK_VM_IP}/24
                  gateway4: 10.0.0.1
            userData: |
              #!/bin/sh
              ip link set eth0 up
              ip addr replace ${OVNK_VM_IP}/24 dev eth0
              ip route replace default via 10.0.0.1 dev eth0 || true
              nohup sh -c 'while true; do ip -4 -o addr show dev eth0 | awk "{print \"GUEST_OS_IP=\" \$4}" > /dev/ttyS0 2>/dev/null || true; sleep 2; done' >/dev/null 2>&1 &
EOF

  for _ in $(seq 1 30); do
    if x01_kctl -n tenant-evpn get vmi vm-evpn-a >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  x01_kctl -n tenant-evpn wait vmi vm-evpn-a --for=condition=Ready --timeout=240s >/dev/null
  # Aguardar guest OS CirrOS configurar 10.0.0.21/24 e responder em tenant-evpn
  local vm_ready=0
  for _ in $(seq 1 45); do
    if x01_kctl -n tenant-evpn exec pod-evpn -- ping -c 1 -W 1 "${OVNK_VM_IP}" >/dev/null 2>&1; then
      vm_ready=1
      break
    fi
    sleep 2
  done
  [[ "${vm_ready}" -eq 1 ]] || x01_die "Guest OS da VM vm-evpn-a (${OVNK_VM_IP}) não respondeu a ping intra-CUDN"
}

x01_verify() {
  x01_log "Verificando convergência BGP/EVPN Type-5 JSON e matriz de conectividade fim-a-fim na L3VNI ${L3VNI_A}..."

  # 1. Aguardar convergência das rotas no spine evpnfab-peer (vrf-tenant-a), ovnk-evpn-peer (vrf-evpn-k03) e ovn-chassis-1 (ovnvrf-tenant)
  local conv_ok=0
  for _ in $(seq 1 40); do
    if docker exec "${FAB_PEER}" python3 -c "
import json, subprocess, sys
rib = json.loads(subprocess.check_output(['vtysh', '-c', 'show ip route vrf vrf-tenant-a json'], text=True))
for pfx in ('192.168.100.0/24', '10.0.0.0/16', '10.0.0.0/24', '10.251.0.1/32', '10.253.0.0/24'):
    if pfx not in rib:
        sys.exit(1)
" 2>/dev/null && \
       docker exec "${OVNK_PEER}" python3 -c "
import json, subprocess, sys
rib = json.loads(subprocess.check_output(['vtysh', '-c', 'show ip route vrf vrf-evpn-k03 json'], text=True))
for pfx in ('192.168.100.0/24', '10.0.0.0/16', '10.0.0.0/24', '10.251.0.1/32'):
    if pfx not in rib:
        sys.exit(1)
" 2>/dev/null && \
       docker exec "${DCI_CHASSIS}" python3 -c "
import json, subprocess, sys
rib = json.loads(subprocess.check_output(['vtysh', '--vty_socket', '/run/frr/x01', '-c', 'show ip route vrf ovnvrf-tenant json'], text=True))
for pfx in ('10.0.0.0/24', '10.251.0.1/32', '10.253.0.0/24'):
    if pfx not in rib:
        sys.exit(1)
" 2>/dev/null; then
      conv_ok=1
      break
    fi
    sleep 2
  done
  [[ "${conv_ok}" -eq 1 ]] || x01_die "RIBs de vrf-tenant-a / vrf-evpn-k03 / ovnvrf-tenant não convergiram na L3VNI ${L3VNI_A}"

  # 2. Aguardar Learned_Route de 10.0.0.0/24 no OVN SB (ovn-central-az1) e rota BGP 10.0.0.0/24 em dci-client-1 via JSON estruturado
  local sb_ok=0
  for _ in $(seq 1 30); do
    if docker exec "${DCI_CENTRAL}" python3 -c '
import json, subprocess, sys
doc = json.loads(subprocess.check_output(["ovn-sbctl", "--format=json", "find", "Learned_Route", "ip_prefix=10.0.0.0/24"], text=True))
headings = doc.get("headings", [])
rows = doc.get("data", [])
if not rows or "ip_prefix" not in headings:
    sys.exit(1)
idx = headings.index("ip_prefix")
sys.exit(0 if any(r[idx] == "10.0.0.0/24" for r in rows) else 1)
' 2>/dev/null && \
       docker exec "${DCI_CLIENT}" python3 -c '
import json, subprocess, sys
routes = json.loads(subprocess.check_output(["ip", "-j", "route", "show", "10.0.0.0/24"], text=True))
if not routes:
    sys.exit(1)
gw_ok = any(
    "169.254.254" in str(r.get("gateway", "")) or
    any("169.254.254" in str(nh.get("gateway", "")) for nh in r.get("nexthops", []) if isinstance(nh, dict))
    for r in routes if isinstance(r, dict)
)
sys.exit(0 if gw_ok else 1)
' 2>/dev/null; then
      sb_ok=1
      break
    fi
    sleep 1
  done
  [[ "${sb_ok}" -eq 1 ]] || x01_die "Learned_Route 10.0.0.0/24 no OVN SB ou rota BGP em ${DCI_CLIENT} não convergiu"

  # 3. Captura externa no fabric (veth-xf-peer em evpnfab-peer) comprovando tráfego VXLAN VNI 10100 + ICMP cruzado
  docker exec "${FAB_PEER}" sh -c "
    rm -f /tmp/x01-fabric.pcap
    timeout 25 tcpdump -ni veth-xf-peer -w /tmp/x01-fabric.pcap 'udp port 4789 or udp port 4790' >/dev/null 2>&1 &
    echo \$! >/tmp/x01-tcpdump.pid
  "
  sleep 1

  # 4. Provas de conectividade fim-a-fim (5/5 pings, 0% perda) entre todos os pares do Tenant 'a' (L3VNI 10100):
  # Par 1: DCI VPC VM (192.168.100.10 em ovn-chassis-1) -> OVN-K KubeVirt VM (vm-evpn-a 10.0.0.21)
  docker exec "${DCI_CHASSIS}" ip netns exec dci-tenant-vm ping -c 5 -W 2 "${OVNK_VM_IP}" >/dev/null \
    || x01_die "Ping DCI VPC (${DCI_VPC_IP}) -> OVN-K KubeVirt VM (${OVNK_VM_IP}) falhou"

  # Par 2: DCI VPC VM (192.168.100.10) -> EVPN Fabric Spine (10.251.0.1)
  docker exec "${DCI_CHASSIS}" ip netns exec dci-tenant-vm ping -c 5 -W 2 "${FAB_LO_IP}" >/dev/null \
    || x01_die "Ping DCI VPC (${DCI_VPC_IP}) -> EVPN Spine (${FAB_LO_IP}) falhou"

  # Par 3: DCI Connect On-Prem (dci-client-1 10.0.200.1) -> OVN-K KubeVirt VM (vm-evpn-a 10.0.0.21)
  docker exec "${DCI_CLIENT}" ping -I "${DCI_ONPREM_IP}" -c 5 -W 2 "${OVNK_VM_IP}" >/dev/null \
    || x01_die "Ping DCI Connect On-Prem (${DCI_ONPREM_IP}) -> OVN-K KubeVirt VM (${OVNK_VM_IP}) falhou"

  # Par 4: DCI Connect On-Prem (dci-client-1 10.0.200.1) -> DCI VPC VM (192.168.100.10)
  docker exec "${DCI_CLIENT}" ping -I "${DCI_ONPREM_IP}" -c 5 -W 2 "${DCI_VPC_IP}" >/dev/null \
    || x01_die "Ping DCI Connect On-Prem (${DCI_ONPREM_IP}) -> DCI VPC (${DCI_VPC_IP}) falhou"

  # Par 5: OVN-K Tenant 'a' (pod-evpn 10.0.0.4) -> DCI VPC VM (192.168.100.10) e DCI Connect On-Prem (10.0.200.1)
  x01_kctl -n tenant-evpn exec pod-evpn -- ping -c 5 -W 2 "${DCI_VPC_IP}" >/dev/null \
    || x01_die "Ping OVN-K (10.0.0.4) -> DCI VPC (${DCI_VPC_IP}) falhou"
  x01_kctl -n tenant-evpn exec pod-evpn -- ping -c 5 -W 2 "${DCI_ONPREM_IP}" >/dev/null \
    || x01_die "Ping OVN-K (10.0.0.4) -> DCI Connect On-Prem (${DCI_ONPREM_IP}) falhou"

  local vxlan_pkts
  vxlan_pkts="$(docker exec "${FAB_PEER}" sh -c '
    if [ -f /tmp/x01-tcpdump.pid ]; then
      kill "$(cat /tmp/x01-tcpdump.pid)" 2>/dev/null || true
      sleep 1
    fi
    tcpdump -nr /tmp/x01-fabric.pcap 2>/dev/null | wc -l | tr -d " "
  ')"
  [[ "${vxlan_pkts:-0}" -ge 20 ]] || x01_die "Captura VXLAN no spine registrou menos pacotes que o esperado (${vxlan_pkts:-0})"

  printf 'X01 PASS (Gate G04): Tenant a unificado na L3VNI %s (RT %s) com RIBs EVPN Type-5 convergidas, Learned_Route OVN SB ativa, 5/5 pings fim-a-fim DCI VPC (%s) <-> OVN-K KubeVirt VM (%s) <-> DCI Connect On-Prem (%s) <-> EVPN Spine (%s) e %s pacotes VXLAN capturados no fabric.\n' \
    "${L3VNI_A}" "${RT_A}" "${DCI_VPC_IP}" "${OVNK_VM_IP}" "${DCI_ONPREM_IP}" "${FAB_LO_IP}" "${vxlan_pkts}"
}

x01_down() {
  x01_log "Executando teardown limpo de X01 e restaurando baseline dos 3 planos..."

  # 1. Remover VM vm-evpn-a e IPAMClaim em tenant-evpn
  x01_kctl -n tenant-evpn delete vm vm-evpn-a --ignore-not-found --wait=false >/dev/null 2>&1 || true
  x01_kctl -n tenant-evpn delete vmi vm-evpn-a --ignore-not-found --wait=false >/dev/null 2>&1 || true
  x01_kctl -n tenant-evpn delete ipamclaim vm-evpn-a-udn --ignore-not-found --wait=false >/dev/null 2>&1 || true

  # 2. Limpar FRR pathspace x01, links EVPN e external_ids em ovn-chassis-1 e ovn-central-az1
  docker exec "${DCI_CHASSIS}" bash -c '
    init=""
    for candidate in /usr/libexec/frr/frrinit.sh /usr/lib/frr/frrinit.sh; do
      if [ -x "${candidate}" ]; then init="${candidate}"; break; fi
    done
    if [ -n "${init}" ] && [ -d /run/frr/x01 ]; then
      "${init}" stop x01 >/dev/null 2>&1 || true
    fi
    rm -rf /etc/frr/x01 /run/frr/x01
    for dev in evpn-tenant vxlan-tenant br-evpn-tenant veth-xf-dci; do
      ip link del "${dev}" 2>/dev/null || true
    done
    ovs-vsctl remove Open_vSwitch . external_ids dynamic-routing-port-mapping 2>/dev/null || true
    ovs-vsctl set Open_vSwitch . external_ids:ovn-evpn-local-ip="50100-170.168.0.5" 2>/dev/null || true
  ' || true

  docker exec "${DCI_CENTRAL}" sh -c '
    ovn-nbctl --wait=sb set logical_switch ls-dci-tenant other_config:dynamic-routing-vni=50100 2>/dev/null || true
    ovn-nbctl --wait=sb clear logical_router_port lrp-dci-tenant options 2>/dev/null || true
    ovn-nbctl lr-route-del lr-dci-tenant 10.0.0.1/32 10.100.100.2 2>/dev/null || true
    ovn-nbctl lr-route-del lr-dci-100 10.0.0.0/24 10.100.100.1 2>/dev/null || true
    ovn-nbctl lr-route-del lr-dci-100 10.251.0.0/24 10.100.100.1 2>/dev/null || true
    ovn-nbctl lr-route-del lr-dci-100 10.253.0.0/24 10.100.100.1 2>/dev/null || true
    ovn-nbctl lr-route-del lr-dci-200 10.0.0.0/24 10.200.100.1 2>/dev/null || true
    ovn-nbctl lr-route-del lr-dci-200 10.251.0.0/24 10.200.100.1 2>/dev/null || true
    ovn-nbctl lr-route-del lr-dci-200 10.253.0.0/24 10.200.100.1 2>/dev/null || true
  ' || true

  for _ in $(seq 1 20); do
    if ! docker exec "${DCI_CHASSIS}" ip link show ovnvrf-tenant >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  docker exec "${DCI_CHASSIS}" ip link del ovnvrf-tenant 2>/dev/null || true

  docker exec "${DCI_CLIENT}" ip addr del "${DCI_ONPREM_IP}/32" dev lo 2>/dev/null || true
  docker exec "${DCI_CLIENT}" vtysh \
    -c "configure terminal" \
    -c "no ip prefix-list MG-TO-TENANT seq 20 permit 10.0.0.0/24" \
    -c "no ip prefix-list MG-TO-TENANT seq 30 permit 10.251.0.0/24" \
    -c "no ip prefix-list MG-TO-TENANT seq 40 permit 10.253.0.0/24" \
    -c "end" >/dev/null 2>&1 || true

  docker exec "${DCI_GW1}" vtysh \
    -c "configure terminal" \
    -c "router bgp 100 vrf ovnvrf100" \
    -c "address-family ipv4 unicast" \
    -c "no network 10.0.0.0/24" \
    -c "no network 10.251.0.0/24" \
    -c "no network 10.253.0.0/24" \
    -c "exit-address-family" \
    -c "exit" \
    -c "no ip prefix-list MG-TO-CLIENT seq 20 permit 10.0.0.0/24" \
    -c "no ip prefix-list MG-TO-CLIENT seq 30 permit 10.251.0.0/24" \
    -c "no ip prefix-list MG-TO-CLIENT seq 40 permit 10.253.0.0/24" \
    -c "end" >/dev/null 2>&1 || true

  docker exec "${DCI_GW2}" vtysh \
    -c "configure terminal" \
    -c "router bgp 100 vrf ovnvrf200" \
    -c "address-family ipv4 unicast" \
    -c "no network 10.0.0.0/24" \
    -c "no network 10.251.0.0/24" \
    -c "no network 10.253.0.0/24" \
    -c "exit-address-family" \
    -c "exit" \
    -c "no ip prefix-list MG-TO-CLIENT seq 20 permit 10.0.0.0/24" \
    -c "no ip prefix-list MG-TO-CLIENT seq 30 permit 10.251.0.0/24" \
    -c "no ip prefix-list MG-TO-CLIENT seq 40 permit 10.253.0.0/24" \
    -c "end" >/dev/null 2>&1 || true

  # 3. Remover interfaces de interconexão em ovnk-evpn-peer e evpnfab-peer e bridge br-x-fabric
  docker exec "${OVNK_PEER}" sh -c '
    ip link del vxlan-xf-10100 2>/dev/null || true
    ip link del veth-xf-ovnk 2>/dev/null || true
  ' || true
  docker exec "${FAB_PEER}" sh -c '
    rm -f /tmp/x01-fabric.pcap /tmp/x01-tcpdump.pid
    ip link del vxlan-xf-10100 2>/dev/null || true
    ip link del vxlan-10100 2>/dev/null || true
    ip link set br-vxlan-10100 addr 02:00:10:00:08:fe 2>/dev/null || true
    ip link del veth-xf-peer 2>/dev/null || true
    killall -q bgpd zebra bfdd staticd mgmtd 2>/dev/null || true
  ' || true
  docker exec "${FAB_GW2}" sh -c '
    killall -q bgpd zebra bfdd staticd mgmtd 2>/dev/null || true
  ' || true
  for br_if in veth-xf-peer-b veth-xf-ovnk-b veth-xf-dci-b; do
    ip link del "${br_if}" 2>/dev/null || true
  done
  iptables -D FORWARD -i "${X_BRIDGE}" -o "${X_BRIDGE}" -j ACCEPT 2>/dev/null || true
  ip link del "${X_BRIDGE}" 2>/dev/null || true

  # 4. Restaurar configuração FRR baseline de evpn-fabric e k03
  local labctl_bin="${LAB_ROOT}/labctl/labctl"
  if [[ ! -x "${labctl_bin}" ]] && [[ -x "${LAB_ROOT}/labctl" ]] && [[ ! -d "${LAB_ROOT}/labctl" ]]; then
    labctl_bin="${LAB_ROOT}/labctl"
  fi
  docker cp "${LAB_ROOT}/studies/p004/evpn-fabric/x05-gw2.conf" "${FAB_GW2}:/etc/frr/frr.conf"
  docker exec "${FAB_GW2}" bash -c '
    set -euo pipefail
    frr_dir=""
    for candidate in /usr/libexec/frr /usr/lib/frr; do
      if [ -x "${candidate}/zebra" ] && [ -x "${candidate}/bgpd" ]; then frr_dir="${candidate}"; break; fi
    done
    chown -R frr:frr /etc/frr /var/run/frr /run/frr 2>/dev/null || true
    for d in mgmtd zebra bgpd bfdd staticd; do
      if [ -x "${frr_dir}/${d}" ]; then pidof "${d}" >/dev/null 2>&1 || "${frr_dir}/${d}" -d; fi
    done
    for _ in $(seq 1 30); do
      if vtysh -c "show version" >/dev/null 2>&1 && vtysh -b >/dev/null 2>&1; then break; fi
      sleep 1
    done
  '
  docker cp "${LAB_ROOT}/studies/p004/evpn-fabric/x05-peer.conf" "${FAB_PEER}:/etc/frr/frr.conf"
  docker exec "${FAB_PEER}" bash -c '
    set -euo pipefail
    ip link set br-vxlan-10100 addr 02:00:10:00:08:fe master vrf-tenant-a up
    ip addr replace 10.251.0.1/32 dev br-vxlan-10100
    ip link show vxlan-10100 >/dev/null 2>&1 || ip link add vxlan-10100 type vxlan id 10100 dstport 4789 local 170.168.0.8 dev eth0 nolearning
    ip link set vxlan-10100 master br-vxlan-10100 up
    bridge link set dev vxlan-10100 learning off
    frr_dir=""
    for candidate in /usr/libexec/frr /usr/lib/frr; do
      if [ -x "${candidate}/zebra" ] && [ -x "${candidate}/bgpd" ]; then frr_dir="${candidate}"; break; fi
    done
    chown -R frr:frr /etc/frr /var/run/frr /run/frr 2>/dev/null || true
    for d in mgmtd zebra bgpd bfdd staticd; do
      if [ -x "${frr_dir}/${d}" ]; then pidof "${d}" >/dev/null 2>&1 || "${frr_dir}/${d}" -d; fi
    done
    for _ in $(seq 1 30); do
      if vtysh -c "show version" >/dev/null 2>&1 && vtysh -b >/dev/null 2>&1; then break; fi
      sleep 1
    done
  '
  bash "${labctl_bin}" evpn-fabric verify >/dev/null
  x01_kctl -n tenant-evpn delete pod pod-evpn --ignore-not-found --wait=true >/dev/null 2>&1 || true
  bash "${LAB_ROOT}/studies/p004/ovnk/k03.sh" >/dev/null
  x01_assert_invariants
  x01_log "Teardown X01 concluído e perfis restaurados ao baseline."
}

case "${ACTION}" in
  up)
    x01_assert_invariants
    trap 'x01_on_err' ERR
    x01_setup_interconnect
    x01_setup_dci_plane
    x01_setup_fabric_and_ovnk
    x01_deploy_ovnk_vm
    x01_verify
    x01_assert_invariants
    trap - ERR
    ;;
  verify)
    x01_assert_invariants
    x01_verify
    x01_assert_invariants
    ;;
  down)
    x01_down
    ;;
  run)
    x01_assert_invariants
    trap 'x01_on_err' ERR
    x01_setup_interconnect
    x01_setup_dci_plane
    x01_setup_fabric_and_ovnk
    x01_deploy_ovnk_vm
    x01_verify
    x01_assert_invariants
    trap - ERR
    ;;
esac
