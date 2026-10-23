#!/usr/bin/env bash
# shellcheck shell=bash
# labs/evpn-fabric.sh — Perfil labctl para OVN 26.03 + FRR EVPN/BGP standalone (Fase 3 / P004-S003).
# Sourced pelo labctl. Define lab_preflight, lab_up, lab_verify, lab_down, lab_status, lab_resources.
#
# Topologia:
#   Rede Docker: evpnfab-mgmt (170.168.0.0/24, gateway 170.168.0.1)
#   Containers (imagem combinada OVN 26.03 + FRR 10.7: ovn/ovn-multi-node:latest):
#     - evpnfab-central (170.168.0.4) — OVN NB/SB + ovn-northd
#     - evpnfab-gw1     (170.168.0.5) — Chassis gateway OVN + FRR (bgpd/zebra/bfdd) VTEP VNI 10100
#     - evpnfab-gw2     (170.168.0.6) — Chassis gateway OVN + FRR (bgpd/zebra/bfdd) VTEP VNI 10200
#     - evpnfab-client  (170.168.0.7) — Chassis workload (ns-tenant-a 10.0.0.11/24, ns-tenant-b 10.0.0.12/24)
#     - evpnfab-peer    (170.168.0.8) — Peer EVPN/BGP externo (FRR VRF tenant-a VNI 10100, tenant-b VNI 10200)

set -euo pipefail

LAB_NAME="evpn-fabric"
DRY_RUN="${DRY_RUN:-${LABCTL_DRY_RUN:-0}}"

# Imagem combinada OVN 26.03 + FRR 10.7 com digest SHA256 pinado (R3)
EVPN_FABRIC_IMAGE="${EVPN_FABRIC_IMAGE:-ovn/ovn-multi-node:latest}"
EVPN_FABRIC_IMAGE_ID="${EVPN_FABRIC_IMAGE_ID:-sha256:eda2364d9cfbec6dd26f54b335c37efa9dade64ffdccbff374b5c50ae64ce52a}"

EVPN_FABRIC_NET="${EVPN_FABRIC_NET:-evpnfab-mgmt}"
EVPN_FABRIC_SUBNET="${EVPN_FABRIC_SUBNET:-170.168.0.0/24}"
EVPN_FABRIC_GW="${EVPN_FABRIC_GW:-170.168.0.1}"

EVPN_FABRIC_CENTRAL="evpnfab-central"
EVPN_FABRIC_GW1="evpnfab-gw1"
EVPN_FABRIC_GW2="evpnfab-gw2"
EVPN_FABRIC_CLIENT="evpnfab-client"
EVPN_FABRIC_PEER="evpnfab-peer"

EVPN_FABRIC_CONTAINERS=(
  "${EVPN_FABRIC_CENTRAL}"
  "${EVPN_FABRIC_GW1}"
  "${EVPN_FABRIC_GW2}"
  "${EVPN_FABRIC_CLIENT}"
  "${EVPN_FABRIC_PEER}"
)

EVPN_FABRIC_RAM_ESTIMATE_GIB="2.5"
EVPN_FABRIC_REPO_ROOT="${LAB_ROOT:-/opt/poc-k8s-fabric}"
if [[ ! -d "${EVPN_FABRIC_REPO_ROOT}/studies/p004/evpn-fabric" ]] && [[ -n "${LABCTL_DIR:-}" ]]; then
  EVPN_FABRIC_REPO_ROOT="$(cd "${LABCTL_DIR}/.." && pwd)"
fi
EVPN_FABRIC_STUDIES_DIR="${EVPN_FABRIC_REPO_ROOT}/studies/p004/evpn-fabric"

evpn_fabric_ip_for() {
  case "$1" in
    "${EVPN_FABRIC_CENTRAL}") printf '170.168.0.4\n' ;;
    "${EVPN_FABRIC_GW1}")     printf '170.168.0.5\n' ;;
    "${EVPN_FABRIC_GW2}")     printf '170.168.0.6\n' ;;
    "${EVPN_FABRIC_CLIENT}")  printf '170.168.0.7\n' ;;
    "${EVPN_FABRIC_PEER}")    printf '170.168.0.8\n' ;;
    *) return 1 ;;
  esac
}

# R2: Idempotência por primitiva (absent -> create, stopped -> start, wrong IP -> reconnect)
evpn_fabric_ensure_container() {
  local name="$1"
  local ip="$2"

  if [[ "${DRY_RUN}" == "1" ]]; then
    run docker run -d --name "${name}" --hostname "${name}" --privileged \
      --network "${EVPN_FABRIC_NET}" --ip "${ip}" \
      "${EVPN_FABRIC_IMAGE}" sleep infinity
    return 0
  fi

  if ! docker inspect "${name}" >/dev/null 2>&1; then
    run docker run -d --name "${name}" --hostname "${name}" --privileged \
      --network "${EVPN_FABRIC_NET}" --ip "${ip}" \
      "${EVPN_FABRIC_IMAGE}" sleep infinity
  else
    local running
    running="$(docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null || echo false)"
    if [[ "${running}" != "true" ]]; then
      run docker start "${name}"
    fi
    local cur_ip
    cur_ip="$(docker inspect -f "{{with index .NetworkSettings.Networks \"${EVPN_FABRIC_NET}\"}}{{.IPAddress}}{{end}}" "${name}" 2>/dev/null || true)"
    if [[ "${cur_ip}" != "${ip}" ]]; then
      run docker network disconnect -f "${EVPN_FABRIC_NET}" "${name}" || true
      run docker network connect --ip "${ip}" "${EVPN_FABRIC_NET}" "${name}"
    fi
  fi
}

lab_preflight() {
  log "preflight ${LAB_NAME}: validando ferramentas, módulos de kernel, imagem combinada e templates"
  require_cmd docker ip bridge python3 timeout tcpdump nsenter

  local mod
  for mod in openvswitch vxlan vrf; do
    if ! lsmod 2>/dev/null | awk '{print $1}' | grep -qx "${mod}" && [[ ! -d "/sys/module/${mod}" ]]; then
      if [[ "${DRY_RUN}" == "1" ]]; then
        log "WARN (dry-run): módulo '${mod}' não carregado neste host"
      else
        die "Módulo de kernel obrigatório ausente para evpn-fabric: ${mod}" 75
      fi
    fi
  done

  if [[ "${DRY_RUN}" != "1" ]]; then
    local actual_id
    actual_id="$(docker image inspect "${EVPN_FABRIC_IMAGE}" --format '{{.Id}}' 2>/dev/null || true)"
    if [[ -z "${actual_id}" ]]; then
      die "Imagem combinada OVN+FRR (${EVPN_FABRIC_IMAGE}) ausente localmente no Docker" 75
    fi
    if [[ "${actual_id}" != "${EVPN_FABRIC_IMAGE_ID}" ]]; then
      die "Digest da imagem ${EVPN_FABRIC_IMAGE} (${actual_id}) diverge do pinado (${EVPN_FABRIC_IMAGE_ID})" 75
    fi
  else
    log "[dry-run] Validaria imagem ${EVPN_FABRIC_IMAGE} (${EVPN_FABRIC_IMAGE_ID})"
  fi

  local f
  for f in x05-gw1.conf x05-gw2.conf x05-peer.conf x05-client.conf x05-withdraw.conf; do
    if [[ ! -f "${EVPN_FABRIC_STUDIES_DIR}/${f}" ]]; then
      die "Template FRR obrigatório ausente: ${EVPN_FABRIC_STUDIES_DIR}/${f}" 75
    fi
  done

  local mem
  mem="$(mem_avail_gib 2>/dev/null || echo 10.00)"
  log "  MemAvailable=${mem}GiB (estimado ~${EVPN_FABRIC_RAM_ESTIMATE_GIB}GiB para ${LAB_NAME})"
  if ! python3 -c "import sys; sys.exit(0 if float('${mem:-0}') >= float('${EVPN_FABRIC_RAM_ESTIMATE_GIB}') else 1)"; then
    die "MemAvailable insuficiente (${mem}GiB < ${EVPN_FABRIC_RAM_ESTIMATE_GIB}GiB)" 75
  fi

  log "preflight ${LAB_NAME} OK"
}

lab_up() {
  lab_preflight

  log "Subindo perfil ${LAB_NAME} (OVN 26.03 + FRR EVPN/BGP multi-VRF)..."

  if [[ "${DRY_RUN}" == "1" ]] || ! docker network inspect "${EVPN_FABRIC_NET}" >/dev/null 2>&1; then
    run docker network create \
      --driver bridge \
      --subnet "${EVPN_FABRIC_SUBNET}" \
      --gateway "${EVPN_FABRIC_GW}" \
      "${EVPN_FABRIC_NET}"
  else
    log "Rede Docker ${EVPN_FABRIC_NET} já existe; reutilizando."
  fi

  local c ip
  for c in "${EVPN_FABRIC_CONTAINERS[@]}"; do
    ip="$(evpn_fabric_ip_for "${c}")"
    evpn_fabric_ensure_container "${c}" "${ip}"
  done

  # 1. Inicializar OVS + OVN Central (NB/SB + ovn-northd)
  run docker exec "${EVPN_FABRIC_CENTRAL}" bash -c "
    set -euo pipefail
    /usr/share/openvswitch/scripts/ovs-ctl start --system-id=${EVPN_FABRIC_CENTRAL}
    /usr/share/ovn/scripts/ovn-ctl start_northd
    ovn-nbctl set-connection ptcp:6641:0.0.0.0 -- set connection . inactivity_probe=60000
    ovn-sbctl set-connection ptcp:6642:0.0.0.0 -- set connection . inactivity_probe=60000
  "

  # 2. Inicializar OVS + ovn-controller explícitos nos gateways e no client (R3)
  # Usa ovn-encap-type=geneve para manter UDP 4789 livre para as interfaces Linux VXLAN do FRR EVPN
  for c in "${EVPN_FABRIC_GW1}" "${EVPN_FABRIC_GW2}" "${EVPN_FABRIC_CLIENT}"; do
    ip="$(evpn_fabric_ip_for "${c}")"
    run docker exec "${c}" bash -c "
      set -euo pipefail
      sysctl -w net.ipv4.ip_forward=1 >/dev/null
      sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
      sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null
      /usr/share/openvswitch/scripts/ovs-ctl start --system-id=${c}
      ovs-vsctl --may-exist add-br br-int
      ovs-vsctl set open . external-ids:ovn-bridge=br-int
      ovs-vsctl set open . external-ids:ovn-remote=tcp:170.168.0.4:6642
      ovs-vsctl set open . external-ids:ovn-encap-type=geneve
      ovs-vsctl set open . external-ids:ovn-encap-ip=${ip}
      ovs-vsctl set open . external-ids:hostname=${c}
      pidof ovn-controller >/dev/null 2>&1 || /usr/share/ovn/scripts/ovn-ctl start_controller
      ovs-vsctl --if-exists del-port br-int vxlan_sys_4789 || true
      ovs-vsctl --if-exists del-port br-ovn vxlan_sys_4789 || true
      ip link del vxlan_sys_4789 2>/dev/null || true
    "
  done

  # 3. Provisionar topologia lógica OVN com dynamic-routing e same-CIDR 10.0.0.0/24 (R3: lsp-add antes do OVS)
  run docker exec "${EVPN_FABRIC_CENTRAL}" bash -c '
    set -euo pipefail
    for gw in evpnfab-gw1 evpnfab-gw2 evpnfab-client; do
      for _ in $(seq 1 30); do
        ovn-sbctl --bare --columns=name find chassis name="${gw}" | grep -qx "${gw}" && break
        sleep 1
      done
    done

    # Tenant A (10.0.0.0/24, VRF 10100, gateway evpnfab-gw1)
    ovn-nbctl --may-exist ls-add ls-tenant-a \
      -- set Logical_Switch ls-tenant-a other_config:subnet="10.0.0.0/24" other_config:vni="10100"
    ovn-nbctl --may-exist lr-add lr-tenant-a \
      -- set Logical_Router lr-tenant-a options:chassis=evpnfab-gw1
    ovn-nbctl --may-exist lrp-add lr-tenant-a lrp-tenant-a-gw 02:00:10:00:01:01 10.0.0.1/24
    ovn-nbctl --may-exist lsp-add ls-tenant-a lsp-tenant-a-gw \
      -- lsp-set-type lsp-tenant-a-gw router \
      -- lsp-set-addresses lsp-tenant-a-gw router \
      -- lsp-set-options lsp-tenant-a-gw router-port=lrp-tenant-a-gw
    ovn-nbctl --may-exist lsp-add ls-tenant-a lsp-tenant-a-vm1 \
      -- lsp-set-addresses lsp-tenant-a-vm1 "02:00:10:00:01:11 10.0.0.11"

    # Transit switch para interligar lr-tenant-a ao VRF Linux vrf-tenant-a em evpnfab-gw1 (P0-2: sem import Learned_Route /32 conflitante)
    ovn-nbctl --may-exist ls-add ls-ext-tenant-a
    ovn-nbctl --may-exist lrp-add lr-tenant-a lrp-tenant-a-ext 02:00:10:01:00:01 169.254.101.1/30
    ovn-nbctl --may-exist lsp-add ls-ext-tenant-a lsp-ext-tenant-a-lr \
      -- lsp-set-type lsp-ext-tenant-a-lr router \
      -- lsp-set-addresses lsp-ext-tenant-a-lr router \
      -- lsp-set-options lsp-ext-tenant-a-lr router-port=lrp-tenant-a-ext
    ovn-nbctl --may-exist lsp-add ls-ext-tenant-a lsp-ext-tenant-a-vrf \
      -- lsp-set-addresses lsp-ext-tenant-a-vrf "02:00:10:01:00:02 169.254.101.2"
    ovn-nbctl --may-exist lr-route-add lr-tenant-a 10.251.0.0/24 169.254.101.2

    # Tenant B (mesmo CIDR 10.0.0.0/24, VRF 10200, gateway evpnfab-gw2)
    ovn-nbctl --may-exist ls-add ls-tenant-b \
      -- set Logical_Switch ls-tenant-b other_config:subnet="10.0.0.0/24" other_config:vni="10200"
    ovn-nbctl --may-exist lr-add lr-tenant-b \
      -- set Logical_Router lr-tenant-b options:chassis=evpnfab-gw2
    ovn-nbctl --may-exist lrp-add lr-tenant-b lrp-tenant-b-gw 02:00:10:00:02:01 10.0.0.1/24
    ovn-nbctl --may-exist lsp-add ls-tenant-b lsp-tenant-b-gw \
      -- lsp-set-type lsp-tenant-b-gw router \
      -- lsp-set-addresses lsp-tenant-b-gw router \
      -- lsp-set-options lsp-tenant-b-gw router-port=lrp-tenant-b-gw
    ovn-nbctl --may-exist lsp-add ls-tenant-b lsp-tenant-b-vm1 \
      -- lsp-set-addresses lsp-tenant-b-vm1 "02:00:10:00:02:12 10.0.0.12"

    # Transit switch para interligar lr-tenant-b ao VRF Linux vrf-tenant-b em evpnfab-gw2 (P0-2: sem import Learned_Route /32 conflitante)
    ovn-nbctl --may-exist ls-add ls-ext-tenant-b
    ovn-nbctl --may-exist lrp-add lr-tenant-b lrp-tenant-b-ext 02:00:10:02:00:01 169.254.102.1/30
    ovn-nbctl --may-exist lsp-add ls-ext-tenant-b lsp-ext-tenant-b-lr \
      -- lsp-set-type lsp-ext-tenant-b-lr router \
      -- lsp-set-addresses lsp-ext-tenant-b-lr router \
      -- lsp-set-options lsp-ext-tenant-b-lr router-port=lrp-tenant-b-ext
    ovn-nbctl --may-exist lsp-add ls-ext-tenant-b lsp-ext-tenant-b-vrf \
      -- lsp-set-addresses lsp-ext-tenant-b-vrf "02:00:10:02:00:02 169.254.102.2"
    ovn-nbctl --may-exist lr-route-add lr-tenant-b 10.252.0.0/24 169.254.102.2

    ovn-nbctl --wait=hv sync
  '

  # 4. Criar netns de clientes em evpnfab-client APÓS lsp-add existir no NB DB (R3)
  run docker exec "${EVPN_FABRIC_CLIENT}" bash -c '
    set -euo pipefail
    ip netns list | grep -qw ns-tenant-a || ip netns add ns-tenant-a
    if ! ip link show veth-ta-ovs >/dev/null 2>&1; then
      ip link add veth-ta-ns type veth peer name veth-ta-ovs
      ip link set veth-ta-ns netns ns-tenant-a
    fi
    ip netns exec ns-tenant-a ip link set lo up
    ip netns exec ns-tenant-a ip link set veth-ta-ns address 02:00:10:00:01:11 up
    ip netns exec ns-tenant-a ip addr replace 10.0.0.11/24 dev veth-ta-ns
    ip netns exec ns-tenant-a ip route replace default via 10.0.0.1
    ip link set veth-ta-ovs up
    ovs-vsctl --may-exist add-port br-int veth-ta-ovs \
      -- set Interface veth-ta-ovs external-ids:iface-id=lsp-tenant-a-vm1

    ip netns list | grep -qw ns-tenant-b || ip netns add ns-tenant-b
    if ! ip link show veth-tb-ovs >/dev/null 2>&1; then
      ip link add veth-tb-ns type veth peer name veth-tb-ovs
      ip link set veth-tb-ns netns ns-tenant-b
    fi
    ip netns exec ns-tenant-b ip link set lo up
    ip netns exec ns-tenant-b ip link set veth-tb-ns address 02:00:10:00:02:12 up
    ip netns exec ns-tenant-b ip addr replace 10.0.0.12/24 dev veth-tb-ns
    ip netns exec ns-tenant-b ip route replace default via 10.0.0.1
    ip link set veth-tb-ovs up
    ovs-vsctl --may-exist add-port br-int veth-tb-ovs \
      -- set Interface veth-tb-ovs external-ids:iface-id=lsp-tenant-b-vm1
  '

  # 5. Configurar VRFs, bridges VXLAN e FRR em evpnfab-gw1, evpnfab-gw2 e evpnfab-peer
  run docker cp "${EVPN_FABRIC_STUDIES_DIR}/x05-gw1.conf" "${EVPN_FABRIC_GW1}:/etc/frr/frr.conf"
  run docker exec "${EVPN_FABRIC_GW1}" bash -c '
    set -euo pipefail
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
    sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null

    ip link show vrf-tenant-a >/dev/null 2>&1 || ip link add vrf-tenant-a type vrf table 10100
    ip link set vrf-tenant-a up
    ip link show br-vxlan-10100 >/dev/null 2>&1 || ip link add br-vxlan-10100 type bridge stp_state 0
    ip link set br-vxlan-10100 addr 02:00:10:00:01:fe master vrf-tenant-a up
    ip link show vxlan-10100 >/dev/null 2>&1 || ip link add vxlan-10100 type vxlan id 10100 dstport 4789 local 170.168.0.5 dev eth0 nolearning
    ip link set vxlan-10100 master br-vxlan-10100 up
    bridge link set dev vxlan-10100 learning off

    ovs-vsctl --may-exist add-port br-int vrfp-ta \
      -- set Interface vrfp-ta type=internal mac="\"02:00:10:01:00:02\"" external-ids:iface-id=lsp-ext-tenant-a-vrf
    ip link set vrfp-ta master vrf-tenant-a address 02:00:10:01:00:02 up
    ip addr replace 169.254.101.2/30 dev vrfp-ta
    ip route replace vrf vrf-tenant-a 10.0.0.0/24 via 169.254.101.1 dev vrfp-ta

    frr_dir=""
    for candidate in /usr/libexec/frr /usr/lib/frr; do
      if [ -x "${candidate}/zebra" ] && [ -x "${candidate}/bgpd" ] && [ -x "${candidate}/bfdd" ]; then
        frr_dir="${candidate}"
        break
      fi
    done
    [ -n "${frr_dir}" ] || { echo "FRR daemons ausentes" >&2; exit 1; }
    mkdir -p /var/run/frr /run/frr
    chown -R frr:frr /etc/frr /var/run/frr /run/frr 2>/dev/null || true
    for d in mgmtd zebra bgpd bfdd staticd; do
      if [ -x "${frr_dir}/${d}" ]; then
        pidof "${d}" >/dev/null 2>&1 || "${frr_dir}/${d}" -d
      fi
    done
    for _ in $(seq 1 30); do
      if vtysh -c "show version" >/dev/null 2>&1 && vtysh -b >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
  '

  run docker cp "${EVPN_FABRIC_STUDIES_DIR}/x05-gw2.conf" "${EVPN_FABRIC_GW2}:/etc/frr/frr.conf"
  run docker exec "${EVPN_FABRIC_GW2}" bash -c '
    set -euo pipefail
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
    sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null

    ip link show vrf-tenant-b >/dev/null 2>&1 || ip link add vrf-tenant-b type vrf table 10200
    ip link set vrf-tenant-b up
    ip link show br-vxlan-10200 >/dev/null 2>&1 || ip link add br-vxlan-10200 type bridge stp_state 0
    ip link set br-vxlan-10200 addr 02:00:10:00:02:fe master vrf-tenant-b up
    ip link show vxlan-10200 >/dev/null 2>&1 || ip link add vxlan-10200 type vxlan id 10200 dstport 4789 local 170.168.0.6 dev eth0 nolearning
    ip link set vxlan-10200 master br-vxlan-10200 up
    bridge link set dev vxlan-10200 learning off

    ovs-vsctl --may-exist add-port br-int vrfp-tb \
      -- set Interface vrfp-tb type=internal mac="\"02:00:10:02:00:02\"" external-ids:iface-id=lsp-ext-tenant-b-vrf
    ip link set vrfp-tb master vrf-tenant-b address 02:00:10:02:00:02 up
    ip addr replace 169.254.102.2/30 dev vrfp-tb
    ip route replace vrf vrf-tenant-b 10.0.0.0/24 via 169.254.102.1 dev vrfp-tb

    frr_dir=""
    for candidate in /usr/libexec/frr /usr/lib/frr; do
      if [ -x "${candidate}/zebra" ] && [ -x "${candidate}/bgpd" ] && [ -x "${candidate}/bfdd" ]; then
        frr_dir="${candidate}"
        break
      fi
    done
    [ -n "${frr_dir}" ] || { echo "FRR daemons ausentes" >&2; exit 1; }
    mkdir -p /var/run/frr /run/frr
    chown -R frr:frr /etc/frr /var/run/frr /run/frr 2>/dev/null || true
    for d in mgmtd zebra bgpd bfdd staticd; do
      if [ -x "${frr_dir}/${d}" ]; then
        pidof "${d}" >/dev/null 2>&1 || "${frr_dir}/${d}" -d
      fi
    done
    for _ in $(seq 1 30); do
      if vtysh -c "show version" >/dev/null 2>&1 && vtysh -b >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
  '

  run docker cp "${EVPN_FABRIC_STUDIES_DIR}/x05-peer.conf" "${EVPN_FABRIC_PEER}:/etc/frr/frr.conf"
  run docker exec "${EVPN_FABRIC_PEER}" bash -c '
    set -euo pipefail
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
    sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null

    ip link show vrf-tenant-a >/dev/null 2>&1 || ip link add vrf-tenant-a type vrf table 10100
    ip link set vrf-tenant-a up
    ip link show br-vxlan-10100 >/dev/null 2>&1 || ip link add br-vxlan-10100 type bridge stp_state 0
    ip link set br-vxlan-10100 addr 02:00:10:00:08:fe master vrf-tenant-a up
    ip addr replace 10.251.0.1/32 dev br-vxlan-10100
    ip link show vxlan-10100 >/dev/null 2>&1 || ip link add vxlan-10100 type vxlan id 10100 dstport 4789 local 170.168.0.8 dev eth0 nolearning
    ip link set vxlan-10100 master br-vxlan-10100 up
    bridge link set dev vxlan-10100 learning off

    ip link show vrf-tenant-b >/dev/null 2>&1 || ip link add vrf-tenant-b type vrf table 10200
    ip link set vrf-tenant-b up
    ip link show br-vxlan-10200 >/dev/null 2>&1 || ip link add br-vxlan-10200 type bridge stp_state 0
    ip link set br-vxlan-10200 addr 02:00:10:00:08:fd master vrf-tenant-b up
    ip addr replace 10.252.0.1/32 dev br-vxlan-10200
    ip link show vxlan-10200 >/dev/null 2>&1 || ip link add vxlan-10200 type vxlan id 10200 dstport 4789 local 170.168.0.8 dev eth0 nolearning
    ip link set vxlan-10200 master br-vxlan-10200 up
    bridge link set dev vxlan-10200 learning off

    frr_dir=""
    for candidate in /usr/libexec/frr /usr/lib/frr; do
      if [ -x "${candidate}/zebra" ] && [ -x "${candidate}/bgpd" ] && [ -x "${candidate}/bfdd" ]; then
        frr_dir="${candidate}"
        break
      fi
    done
    [ -n "${frr_dir}" ] || { echo "FRR daemons ausentes" >&2; exit 1; }
    mkdir -p /var/run/frr /run/frr
    chown -R frr:frr /etc/frr /var/run/frr /run/frr 2>/dev/null || true
    for d in mgmtd zebra bgpd bfdd staticd; do
      if [ -x "${frr_dir}/${d}" ]; then
        pidof "${d}" >/dev/null 2>&1 || "${frr_dir}/${d}" -d
      fi
    done
    for _ in $(seq 1 30); do
      if vtysh -c "show version" >/dev/null 2>&1 && vtysh -b >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
  '

  run docker exec "${EVPN_FABRIC_CENTRAL}" ovn-nbctl --wait=hv sync

  if [[ "${DRY_RUN}" != "1" ]]; then
    state_set "${LAB_NAME}" "up_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  log "${LAB_NAME} up concluído."
}

lab_verify() {
  log "Verificando saúde e invariantes do perfil ${LAB_NAME}..."
  if [[ "${DRY_RUN}" == "1" ]]; then
    run docker inspect -f '{{.State.Running}}' "${EVPN_FABRIC_CONTAINERS[@]}"
    run docker exec "${EVPN_FABRIC_CENTRAL}" ovn-sbctl show
    run docker exec "${EVPN_FABRIC_CENTRAL}" ovn-nbctl ls-list
    run docker exec "${EVPN_FABRIC_PEER}" vtysh -c "show bgp summary json"
    run docker exec "${EVPN_FABRIC_PEER}" vtysh -c "show bgp l2vpn evpn route detail json"
    run docker exec "${EVPN_FABRIC_CLIENT}" ip netns exec ns-tenant-a ping -c 5 -W 2 10.0.0.1
    run docker exec "${EVPN_FABRIC_CLIENT}" ip netns exec ns-tenant-b ping -c 5 -W 2 10.0.0.1
    run docker exec "${EVPN_FABRIC_CLIENT}" ip netns exec ns-tenant-a ping -c 5 -W 2 10.251.0.1
    run nsenter -t "<evpnfab-client-pid>" -n timeout 12 tcpdump -ni veth-tb-ovs -c 1 icmp
    run nsenter -t "<evpnfab-client-pid>" -n timeout 12 tcpdump -ni veth-ta-ovs -c 5 'icmp[icmptype] == icmp-echo'
    return 0
  fi

  # 1. Todos os 5 containers running
  local c
  for c in "${EVPN_FABRIC_CONTAINERS[@]}"; do
    if [[ "$(docker inspect -f '{{.State.Running}}' "${c}" 2>/dev/null || echo false)" != "true" ]]; then
      die "Container ${c} não está running"
    fi
  done

  # 2. Chassis gateways registrados no SB DB
  local sb_out
  sb_out="$(docker exec "${EVPN_FABRIC_CENTRAL}" ovn-sbctl show)"
  if ! grep -q "evpnfab-gw1" <<<"${sb_out}" || ! grep -q "evpnfab-gw2" <<<"${sb_out}"; then
    die "Chassis evpnfab-gw1/evpnfab-gw2 não encontrados em ovn-sbctl show"
  fi

  # 3. Logical switches ls-tenant-a e ls-tenant-b presentes
  local ls_out
  ls_out="$(docker exec "${EVPN_FABRIC_CENTRAL}" ovn-nbctl ls-list)"
  if ! grep -q "ls-tenant-a" <<<"${ls_out}" || ! grep -q "ls-tenant-b" <<<"${ls_out}"; then
    die "Logical switches ls-tenant-a/ls-tenant-b ausentes no NB DB"
  fi

  # 4 & 5. BGP Established, rotas EVPN Type-5 estruturadas e tabelas VRF isoladas via JSON (R8 / P1-3)
  local bgp_ok=0
  for _ in $(seq 1 20); do
    if docker exec "${EVPN_FABRIC_PEER}" python3 -c '
import json, subprocess, sys

sum_j = json.loads(subprocess.check_output(["vtysh", "-c", "show bgp summary json"], text=True))
peers = {}
for af in sum_j.values():
    if isinstance(af, dict) and "peers" in af:
        peers.update(af["peers"])
for p in ("170.168.0.5", "170.168.0.6"):
    if peers.get(p, {}).get("state") != "Established":
        sys.exit(1)

evpn_j = json.loads(subprocess.check_output(["vtysh", "-c", "show bgp l2vpn evpn route detail json"], text=True))

def check_evpn_rd(evpn_doc, expected_rd_suffix, expected_nh, expected_rt):
    for rd_key, rd_val in evpn_doc.items():
        if not isinstance(rd_val, dict) or not str(rd_key).endswith(expected_rd_suffix):
            continue
        for pfx_key, pfx_val in rd_val.items():
            if not isinstance(pfx_val, dict) or "10.0.0.0" not in str(pfx_key):
                continue
            paths = pfx_val.get("paths", [])
            for path_entry in paths:
                for path in (path_entry if isinstance(path_entry, list) else [path_entry]):
                    if not isinstance(path, dict):
                        continue
                    nhs = [nh.get("ip") for nh in path.get("nexthops", []) if isinstance(nh, dict)]
                    ext_comm = path.get("extendedCommunity", {}).get("string", "") if isinstance(path.get("extendedCommunity"), dict) else ""
                    if expected_nh in nhs and expected_rt in ext_comm:
                        return True
    return False

if not check_evpn_rd(evpn_j, ":10100", "170.168.0.5", "65000:10100"):
    sys.exit(2)
if not check_evpn_rd(evpn_j, ":10200", "170.168.0.6", "65000:10200"):
    sys.exit(3)

vrf_a = json.loads(subprocess.check_output(["vtysh", "-c", "show ip route vrf vrf-tenant-a 10.0.0.0/24 json"], text=True))
nhs_a = {
    nh.get("ip")
    for entry in vrf_a.get("10.0.0.0/24", []) if isinstance(entry, dict)
    for nh in entry.get("nexthops", []) if isinstance(nh, dict) and nh.get("ip")
}
if nhs_a != {"170.168.0.5"}:
    sys.exit(4)

vrf_b = json.loads(subprocess.check_output(["vtysh", "-c", "show ip route vrf vrf-tenant-b 10.0.0.0/24 json"], text=True))
nhs_b = {
    nh.get("ip")
    for entry in vrf_b.get("10.0.0.0/24", []) if isinstance(entry, dict)
    for nh in entry.get("nexthops", []) if isinstance(nh, dict) and nh.get("ip")
}
if nhs_b != {"170.168.0.6"}:
    sys.exit(5)
' 2>/dev/null; then
      bgp_ok=1
      break
    fi
    sleep 2
  done

  if [[ "${bgp_ok}" -ne 1 ]]; then
    die "Sessões BGP não Established ou rotas EVPN Type-5 / tabelas VRF (VNI 10100->170.168.0.5, VNI 10200->170.168.0.6) inválidas em evpnfab-peer"
  fi

  # 6a. Controle positivo intra-tenant (R4): 5/5 pings para o próprio gateway e para o loopback remoto EVPN
  if ! docker exec "${EVPN_FABRIC_CLIENT}" ip netns exec ns-tenant-a ping -c 5 -W 2 10.0.0.1 >/dev/null; then
    die "Controle positivo falhou: ns-tenant-a não alcançou seu gateway 10.0.0.1"
  fi
  if ! docker exec "${EVPN_FABRIC_CLIENT}" ip netns exec ns-tenant-b ping -c 5 -W 2 10.0.0.1 >/dev/null; then
    die "Controle positivo falhou: ns-tenant-b não alcançou seu gateway 10.0.0.1"
  fi
  if ! docker exec "${EVPN_FABRIC_CLIENT}" ip netns exec ns-tenant-a ping -c 5 -W 2 10.251.0.1 >/dev/null; then
    die "Ping norte-sul EVPN falhou: ns-tenant-a (10.0.0.11) -> evpnfab-peer (10.251.0.1)"
  fi

  # 6b. Prova de isolamento same-CIDR (R4 + N2 + P0-1): rota /32 via gateway 10.0.0.1 garante emissão real de 5 pacotes L3 ICMP na origem e 0 no destino
  local client_pid=""
  client_pid="$(docker inspect -f '{{.State.Pid}}' "${EVPN_FABRIC_CLIENT}")"
  if [[ -z "${client_pid}" || "${client_pid}" == "0" ]]; then
    die "Não foi possível obter PID do container ${EVPN_FABRIC_CLIENT}"
  fi
  local -a ns_exec=(nsenter -t "${client_pid}" -n)
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    ns_exec=(sudo -n nsenter -t "${client_pid}" -n)
  fi

  local iso_dir=""
  iso_dir="$(mktemp -d /tmp/evpnfab-iso.XXXXXX)"
  local dst_rc=0
  local src_rc=0
  local src_count=0
  local dst_log=""

  docker exec "${EVPN_FABRIC_CLIENT}" ip netns exec ns-tenant-a ip route replace 10.0.0.12/32 via 10.0.0.1 dev veth-ta-ns
  "${ns_exec[@]}" timeout 12 tcpdump -ni veth-tb-ovs -c 1 icmp >"${iso_dir}/tb-dst.log" 2>&1 &
  local pid_dst=$!
  "${ns_exec[@]}" timeout 12 tcpdump -ni veth-ta-ovs -c 5 'icmp[icmptype] == icmp-echo' >"${iso_dir}/ta-src.log" 2>&1 &
  local pid_src=$!
  sleep 1
  docker exec "${EVPN_FABRIC_CLIENT}" ip netns exec ns-tenant-a ping -c 5 -W 1 10.0.0.12 >/dev/null 2>&1 || true
  wait "${pid_dst}" || dst_rc=$?
  wait "${pid_src}" || src_rc=$?
  docker exec "${EVPN_FABRIC_CLIENT}" ip netns exec ns-tenant-a ip route del 10.0.0.12/32 dev veth-ta-ns 2>/dev/null || true

  dst_log="$(cat "${iso_dir}/tb-dst.log" 2>/dev/null || true)"
  src_count="$(awk '/packets captured/{print $1}' "${iso_dir}/ta-src.log" 2>/dev/null | tail -n1)"
  rm -rf "${iso_dir}"

  if [[ "${dst_rc}" != "124" ]] || ! grep -q "0 packets captured" <<<"${dst_log}"; then
    die "Violação de isolamento same-CIDR: porta destino veth-tb-ovs recebeu pacotes ou tcpdump não expirou com rc=124 (rc=${dst_rc})"
  fi
  if [[ "${src_rc}" != "0" ]] || [[ "${src_count:-0}" -lt 5 ]]; then
    die "Prova de isolamento inválida (N2): origem veth-ta-ovs emitiu apenas ${src_count:-0}/5 ICMP echo requests (rc=${src_rc})"
  fi

  # ovn-trace no plano lógico
  if ! docker exec "${EVPN_FABRIC_CENTRAL}" ovn-trace ls-tenant-a \
    'inport == "lsp-tenant-a-vm1" && eth.src == 02:00:10:00:01:11 && eth.dst == 02:00:10:00:01:01 && ip4.src == 10.0.0.11 && ip4.dst == 10.0.0.12 && ip.ttl == 64 && icmp4.type == 8' >/dev/null; then
    die "ovn-trace falhou para ls-tenant-a"
  fi

  local ev_dir
  ev_dir="$(evidence_dir "${LAB_NAME}")"
  {
    printf '=== %s verify (%s) ===\n' "${LAB_NAME}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'containers_running=5/5\n'
    printf 'bgp_peers_established=170.168.0.5,170.168.0.6\n'
    printf 'vrf_tenant_a_nh=170.168.0.5\n'
    printf 'vrf_tenant_b_nh=170.168.0.6\n'
    printf 'iso_src_emitted=%s\n' "${src_count}"
    printf 'iso_dst_rc=%s\n' "${dst_rc}"
  } > "${ev_dir}/verify.txt"
  state_set "${LAB_NAME}" "verified_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  log "${LAB_NAME} verify: PASS (5 containers running, BGP Established, EVPN Type-5 estruturadas, isolamento same-CIDR provado com ${src_count} emissões e 0 recepções; evidência: ${ev_dir}/verify.txt)."
}

lab_down() {
  log "Executando teardown cleanup-then-proof do perfil ${LAB_NAME} (R7 + N1)..."
  if [[ "${DRY_RUN}" == "1" ]]; then
    run docker exec "${EVPN_FABRIC_GW1}" vtysh -c "configure terminal" -c "no router bgp 65001 vrf vrf-tenant-a" -c "no router bgp 65001" -c "end"
    run docker exec "${EVPN_FABRIC_GW2}" vtysh -c "configure terminal" -c "no router bgp 65001 vrf vrf-tenant-b" -c "no router bgp 65001" -c "end"
    run docker exec "${EVPN_FABRIC_PEER}" vtysh -c "configure terminal" -c "no router bgp 65002 vrf vrf-tenant-a" -c "no router bgp 65002 vrf vrf-tenant-b" -c "no router bgp 65002" -c "end"
    run docker exec "${EVPN_FABRIC_CENTRAL}" ovn-nbctl --if-exists lsp-del lsp-tenant-a-vm1 -- --if-exists lsp-del lsp-tenant-b-vm1
    run docker rm -f "${EVPN_FABRIC_CONTAINERS[@]}"
    run docker network rm "${EVPN_FABRIC_NET}"
    return 0
  fi

  # 1. Retirada explícita de rotas BGP EVPN em cada speaker antes da remoção (N1 / R7)
  if docker inspect -f '{{.State.Running}}' "${EVPN_FABRIC_GW1}" 2>/dev/null | grep -qx "true"; then
    docker exec "${EVPN_FABRIC_GW1}" vtysh \
      -c "configure terminal" \
      -c "no router bgp 65001 vrf vrf-tenant-a" \
      -c "no router bgp 65001" \
      -c "end" >/dev/null 2>&1 || true
  fi
  if docker inspect -f '{{.State.Running}}' "${EVPN_FABRIC_GW2}" 2>/dev/null | grep -qx "true"; then
    docker exec "${EVPN_FABRIC_GW2}" vtysh \
      -c "configure terminal" \
      -c "no router bgp 65001 vrf vrf-tenant-b" \
      -c "no router bgp 65001" \
      -c "end" >/dev/null 2>&1 || true
  fi
  if docker inspect -f '{{.State.Running}}' "${EVPN_FABRIC_PEER}" 2>/dev/null | grep -qx "true"; then
    docker exec "${EVPN_FABRIC_PEER}" vtysh \
      -c "configure terminal" \
      -c "no router bgp 65002 vrf vrf-tenant-a" \
      -c "no router bgp 65002 vrf vrf-tenant-b" \
      -c "no router bgp 65002" \
      -c "end" >/dev/null 2>&1 || true
  fi

  # 2. Remoção explícita de Logical_Switch_Port e objetos lógicos no OVN NB DB (R7)
  if docker inspect -f '{{.State.Running}}' "${EVPN_FABRIC_CENTRAL}" 2>/dev/null | grep -qx "true"; then
    docker exec "${EVPN_FABRIC_CENTRAL}" bash -c '
      ovn-nbctl --if-exists lsp-del lsp-tenant-a-vm1 \
        -- --if-exists lsp-del lsp-tenant-b-vm1 \
        -- --if-exists lr-del lr-tenant-a \
        -- --if-exists lr-del lr-tenant-b \
        -- --if-exists ls-del ls-tenant-a \
        -- --if-exists ls-del ls-tenant-b \
        -- --if-exists ls-del ls-ext-tenant-a \
        -- --if-exists ls-del ls-ext-tenant-b
      ovn-nbctl --wait=hv sync || true
    ' >/dev/null 2>&1 || true
  fi

  # 3. Limpeza e verificação de resíduo DENTRO dos namespaces dos containers ANTES de docker rm -f (R7)
  local gw
  for gw in "${EVPN_FABRIC_GW1}" "${EVPN_FABRIC_GW2}" "${EVPN_FABRIC_PEER}"; do
    if docker inspect -f '{{.State.Running}}' "${gw}" 2>/dev/null | grep -qx "true"; then
      docker exec "${gw}" bash -c '
        for dev in vxlan-10100 vxlan-10200 br-vxlan-10100 br-vxlan-10200 vrf-tenant-a vrf-tenant-b; do
          ip link del "${dev}" 2>/dev/null || true
        done
      '
      if [[ -n "$(docker exec "${gw}" ip -d link show type vxlan 2>/dev/null | grep -E 'vxlan-10100|vxlan-10200' || true)" ]]; then
        die "Resíduo VXLAN interno detectado em ${gw} antes da remoção"
      fi
      if [[ -n "$(docker exec "${gw}" ip -d link show type vrf 2>/dev/null | grep -E 'vrf-tenant-a|vrf-tenant-b' || true)" ]]; then
        die "Resíduo VRF interno detectado em ${gw} antes da remoção"
      fi
    fi
  done

  # 4. Remover apenas os 5 containers com nome exato (nunca prune / --all)
  local c
  for c in "${EVPN_FABRIC_CONTAINERS[@]}"; do
    if docker inspect "${c}" >/dev/null 2>&1; then
      run docker rm -f "${c}"
    fi
  done

  # 5. Remover rede Docker evpnfab-mgmt
  if docker network inspect "${EVPN_FABRIC_NET}" >/dev/null 2>&1; then
    run docker network rm "${EVPN_FABRIC_NET}"
  fi

  # 6. Verificação de resíduo no host APÓS remoção de containers e rede (R7)
  assert_absent_containers "evpnfab-"
  local host_routes
  if ! host_routes="$(ip route show 2>&1)"; then
    die "Falha ao executar 'ip route show' na verificação pós-down: ${host_routes}"
  fi
  if grep -qE '(^|[[:space:]])170\.168\.0\.0/24([[:space:]]|$)' <<<"${host_routes}"; then
    die "Rota residual para 170.168.0.0/24 permaneceu no host após down"
  fi
  if ip -d link show type vxlan 2>/dev/null | grep -q "evpnfab"; then
    die "Interface VXLAN residual com prefixo evpnfab detectada no host"
  fi
  if ip -d link show type vrf 2>/dev/null | grep -q "evpnfab"; then
    die "Interface VRF residual com prefixo evpnfab detectada no host"
  fi

  rm -f "$(state_file "${LAB_NAME}")"
  log "${LAB_NAME} down concluído com zero resíduo."
}

lab_status() {
  local running_count=0 up="nao" c
  for c in "${EVPN_FABRIC_CONTAINERS[@]}"; do
    if docker inspect -f '{{.State.Running}}' "${c}" 2>/dev/null | grep -qx "true"; then
      running_count=$((running_count + 1))
    fi
  done
  if [[ "${running_count}" -eq 5 ]]; then
    up="sim"
  fi
  log "lab=${LAB_NAME} up=${up} containers=${running_count}/5 net=${EVPN_FABRIC_NET}"
  docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' 2>/dev/null \
    | grep -E '^evpnfab-' | sed 's/^/  /' || true
  return 0
}

lab_resources() {
  log "Recursos estimados/consumidos pelo perfil ${LAB_NAME} (~${EVPN_FABRIC_RAM_ESTIMATE_GIB}GiB RAM):"
  local running=()
  local c
  for c in "${EVPN_FABRIC_CONTAINERS[@]}"; do
    if docker inspect -f '{{.State.Running}}' "${c}" 2>/dev/null | grep -qx "true"; then
      running+=("${c}")
    fi
  done
  if [[ "${#running[@]}" -gt 0 ]]; then
    docker stats --no-stream "${running[@]}" || true
  else
    printf '  Nenhum container evpnfab-* em execução no momento.\n'
  fi
}

preflight() { lab_preflight "$@"; }
up() { lab_up "$@"; }
verify() { lab_verify "$@"; }
down() { lab_down "$@"; }
status() { lab_status "$@"; }
resources() { lab_resources "$@"; }
