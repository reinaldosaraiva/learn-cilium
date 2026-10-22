#!/usr/bin/env bash
# Perfil labctl da réplica MGC Connect (P004-S002).
#
# O cluster OVN é o ovn-fake-multinode v0.4 com uma central, dois gateways e
# dois chassis. Os gateways carregam FRR e o cliente AS 200 é o único
# container adicional criado por este perfil.
set -euo pipefail

LAB_NAME="mgc"
MGC_M03_MODE="${MGC_M03_MODE:-0}"

OVN_TAG="v26.03.3"
OVN_COMMIT="4c5118fc40d54f2f8d52781bc205ba185808d7d0"
# OVN v26.03.3 bumps its OVS submodule to branch-3.7; OVS has no v26.03.3 tag.
OVS_TAG="branch-3.7"
FAKE_MN_TAG="v0.4"
FAKE_MN_COMMIT_PREFIX="653e7b2"
FRR_IMAGE="frrouting/frr:v8.4.1"
RUNC_CMD="docker"

MGC_SRC="${MGC_SRC:-/opt/mgc-src}"
MGC_OVN_SRC="${MGC_SRC}/ovn"
MGC_OVS_SRC="${MGC_SRC}/ovs"
MGC_FAKE_MN="${MGC_SRC}/ovn-fake-multinode"
MGC_FIXTURE_DIR="${LAB_ROOT:-/opt/poc-k8s-fabric}/studies/p004/ovn"

MG_CENTRAL="ovn-central-az1"
MG_GATEWAY_1="ovn-gw-1"
MG_GATEWAY_2="ovn-gw-2"
MG_CHASSIS_1="ovn-chassis-1"
MG_CHASSIS_2="ovn-chassis-2"
MG_CENTRAL_PREFIX="ovn-central-az"
MG_GATEWAY_PREFIX="ovn-gw-"
MG_CHASSIS_PREFIX="ovn-chassis-"
MG_CLIENT_NAME="${MGC_CLIENT_NAME:-mgc-client-1}"
MG_PREFIX="mgc-"

# M03 is an owned, temporary extension of this profile.  The lifecycle keeps
# its names visible and refuses residue whose ownership cannot be proved.
MG_M03_PEER="mgc-evpn-client-1"
MG_M03_OWNER_LABEL="labctl-m03-owner"
MG_M03_CHASSIS="ovn-chassis-1"
MG_M03_CENTRAL="ovn-central-az1"
MG_M03_TENANT_LRP="lrp-mgc-tenant"
MG_M03_TENANT_VRF="ovnvrf-tenant"
MG_M03_TENANT_TABLE=300
MG_M03_TENANT_BR="br-evpn-tenant"
MG_M03_TENANT_VXLAN="vxlan-tenant"
MG_M03_TENANT_ADVERTISE="evpn-tenant"
MG_M03_CLIENT_VRF="vrf-evpn-client"
MG_M03_LEGACY_CLIENT_VRF="ovnvrf-evpn-client"
MG_M03_CLIENT_BR="br-evpn-client"
MG_M03_CLIENT_VXLAN="vxlan-m03-peer"
MG_M03_CLIENT_ADVERTISE="evpn-client"
MG_M03_LOCK_FILE=/var/lock/labctl-mgc-m03.lock
MG_M03_MARKER_FILE="${MG_M03_MARKER_FILE:-/run/labctl/mgc-m03/active}"
MG_X05_MARKER_FILE=/run/labctl/mgc-x05/active

MG_GW_VRF_1=100
MG_GW_VRF_2=200
MG_GW_VLAN_1=100
MG_GW_VLAN_2=200
MG_GW_AS=100
MG_CLIENT_AS=200
MG_CLIENT_CIDR="10.0.0.0/16"
MG_CLIENT_LOOPBACK_IP="${MGC_CLIENT_LOOPBACK_IP:-10.0.0.1/32}"
MG_CLIENT_MTU="${MGC_CLIENT_MTU:-1500}"
MG_GATEWAY_MTU=1500
MG_GW1_P2P="169.254.254.1"
MG_CLI1_P2P="169.254.254.2"
MG_GW2_P2P="169.254.254.5"
MG_CLI2_P2P="169.254.254.6"

MG_TENANT_LS="ls-mgc-tenant"
MG_TENANT_LR="lr-mgc-tenant"
MG_TENANT_CIDR="192.168.100.0/24"
MG_TENANT_LRP_IP="192.168.100.1"
MG_TENANT_VM_IP="192.168.100.10"
MG_TENANT_VM_MAC="02:00:00:10:00:10"
MG_TENANT_VM_LSP="mgc-tenant-vm"
MG_TENANT_VM_NS="mgc-tenant-vm"
MG_TENANT_VM_IF="mgc-tenant-vm"
MG_TENANT_VM_PORT="mgc-tenant-vm-p"
MG_TENANT_VNI=50100

MG_CHASSIS_1_UNDERLAY="170.168.0.5"
MG_CHASSIS_2_UNDERLAY="170.168.0.6"
MG_GATEWAY_1_UNDERLAY="170.168.0.3"
MG_GATEWAY_2_UNDERLAY="170.168.0.4"

MG_NB_FIXTURE="${MGC_FIXTURE_DIR}/nb-topology.sh"
MG_GW1_FRR="${MGC_FIXTURE_DIR}/frr-gw1.conf"
MG_GW2_FRR="${MGC_FIXTURE_DIR}/frr-gw2.conf"
MG_CLIENT_FRR="${MGC_FIXTURE_DIR}/frr-client.conf"

mgc_vrf_package() {
  printf 'linux-modules-extra-%s\n' "$(uname -r)"
}

mgc_count_named() {
  local name="$1" all="${2:-all}"
  if [[ "${all}" == "running" ]]; then
    docker ps --format '{{.Names}}' 2>/dev/null \
      | awk -v wanted="${name}" '$0 == wanted {count++} END {print count + 0}'
  else
    docker ps -a --format '{{.Names}}' 2>/dev/null \
      | awk -v wanted="${name}" '$0 == wanted {count++} END {print count + 0}'
  fi
}

mgc_fixture_file() {
  local fixture="$1"
  echo "${MGC_FIXTURE_DIR}/${fixture}"
}

mgc_image_exists() {
  local image="$1"
  docker image inspect "${image}" >/dev/null 2>&1
}

mgc_image_id() {
  local image="$1"
  docker image inspect -f '{{.Id}}' "${image}" 2>/dev/null || true
}

mgc_images_provenance_matches() {
  local cinc_id multi_id ovn_commit ovs_commit fake_commit current_ovn current_ovs current_fake
  cinc_id="$(mgc_image_id ovn/cinc:latest)"
  multi_id="$(mgc_image_id ovn/ovn-multi-node:latest)"
  [[ -n "${cinc_id}" && -n "${multi_id}" ]] || return 1
  ovn_commit="$(state_get "${LAB_NAME}" image_ovn_commit 2>/dev/null || true)"
  ovs_commit="$(state_get "${LAB_NAME}" image_ovs_commit 2>/dev/null || true)"
  fake_commit="$(state_get "${LAB_NAME}" image_fake_multinode_commit 2>/dev/null || true)"
  current_ovn="$(git -C "${MGC_OVN_SRC}" rev-parse HEAD 2>/dev/null || true)"
  current_ovs="$(git -C "${MGC_OVS_SRC}" rev-parse HEAD 2>/dev/null || true)"
  current_fake="$(git -C "${MGC_FAKE_MN}" rev-parse HEAD 2>/dev/null || true)"
  [[ "${cinc_id}" == "$(state_get "${LAB_NAME}" image_ovn_cinc_id 2>/dev/null || true)" \
    && "${multi_id}" == "$(state_get "${LAB_NAME}" image_ovn_multi_id 2>/dev/null || true)" \
    && -n "${current_ovn}" && "${ovn_commit}" == "${current_ovn}" \
    && -n "${current_ovs}" && "${ovs_commit}" == "${current_ovs}" \
    && -n "${current_fake}" && "${fake_commit}" == "${current_fake}" ]]
}

mgc_record_image_provenance() {
  local cinc_id multi_id ovn_commit ovs_commit fake_commit
  cinc_id="$(mgc_image_id ovn/cinc:latest)"
  multi_id="$(mgc_image_id ovn/ovn-multi-node:latest)"
  ovn_commit="$(git -C "${MGC_OVN_SRC}" rev-parse HEAD)"
  ovs_commit="$(git -C "${MGC_OVS_SRC}" rev-parse HEAD)"
  fake_commit="$(git -C "${MGC_FAKE_MN}" rev-parse HEAD)"
  [[ -n "${cinc_id}" && -n "${multi_id}" ]] \
    || die "build OVN terminou sem as duas imagens esperadas"
  state_set "${LAB_NAME}" image_ovn_cinc_id "${cinc_id}"
  state_set "${LAB_NAME}" image_ovn_multi_id "${multi_id}"
  state_set "${LAB_NAME}" image_ovn_commit "${ovn_commit}"
  state_set "${LAB_NAME}" image_ovs_commit "${ovs_commit}"
  state_set "${LAB_NAME}" image_fake_multinode_commit "${fake_commit}"
  state_set "${LAB_NAME}" image_provenance_state trusted
  state_set "${LAB_NAME}" image_provenance_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

mgc_cluster_count() {
  local mode="${1:-all}"
  local total=0 name
  for name in "${MG_CENTRAL}" "${MG_GATEWAY_1}" "${MG_GATEWAY_2}" \
    "${MG_CHASSIS_1}" "${MG_CHASSIS_2}"; do
    total=$((total + $(mgc_count_named "${name}" "${mode}")))
  done
  echo "${total}"
}

mgc_expected_cluster_names() {
  printf '%s\n' "${MG_CENTRAL}" "${MG_GATEWAY_1}" "${MG_GATEWAY_2}" \
    "${MG_CHASSIS_1}" "${MG_CHASSIS_2}"
}

mgc_assert_no_extra_ovn_containers() {
  local id name expected
  while IFS= read -r id; do
    [[ -n "${id}" ]] || continue
    name="$(docker inspect -f '{{.Name}}' "${id}" 2>/dev/null | sed 's#^/##')"
    case "${name}" in
      "${MG_CENTRAL}"|"${MG_GATEWAY_1}"|"${MG_GATEWAY_2}"|"${MG_CHASSIS_1}"|"${MG_CHASSIS_2}")
        expected="$(state_get "${LAB_NAME}" "$(mgc_owner_key "${name}")" 2>/dev/null || true)"
        [[ -n "${expected}" && "${id}" == "${expected}" ]] \
          || die "container OVN ${name} não corresponde ao ID próprio registrado"
        ;;
      *)
        die "container OVN extra no filtro do stop upstream: ${name:-${id}}"
        ;;
    esac
  done < <(docker ps -qa --no-trunc \
    --filter "name=${MG_CENTRAL_PREFIX}|${MG_GATEWAY_PREFIX}|${MG_CHASSIS_PREFIX}" 2>/dev/null)
}

mgc_bridge_exists() {
  local bridge="$1"
  ovs-vsctl br-exists "${bridge}" >/dev/null 2>&1
}

mgc_bridge_uuid() {
  local bridge="$1"
  ovs-vsctl get Bridge "${bridge}" _uuid 2>/dev/null | tr -d '"'
}

mgc_bridge_owner_token() {
  local bridge="$1"
  ovs-vsctl get Bridge "${bridge}" external_ids:labctl-mgc-owner-token \
    2>/dev/null | tr -d '"'
}

mgc_any_bridge_exists() {
  mgc_bridge_exists br-ovn || mgc_bridge_exists br-ovn-ext
}

mgc_assert_bridges_absent() {
  mgc_bridge_exists br-ovn \
    && die "bridge br-ovn existe onde o perfil exige ausência"
  mgc_bridge_exists br-ovn-ext \
    && die "bridge br-ovn-ext existe onde o perfil exige ausência"
  return 0
}

mgc_assert_bridges_owned() {
  local allow_missing="${1:-no}" token bridge expected_uuid actual_uuid actual_token
  token="$(state_get "${LAB_NAME}" owner_token 2>/dev/null || true)"
  [[ -n "${token}" ]] || die "bridges OVN sem token de ownership no estado"
  for bridge in br-ovn br-ovn-ext; do
    if ! mgc_bridge_exists "${bridge}"; then
      [[ "${allow_missing}" == "yes" ]] \
        || die "bridge ${bridge} ausente; ownership não pode ser provada antes do stop"
      continue
    fi
    case "${bridge}" in
      br-ovn) expected_uuid="$(state_get "${LAB_NAME}" owner_bridge_br_ovn_uuid 2>/dev/null || true)" ;;
      br-ovn-ext) expected_uuid="$(state_get "${LAB_NAME}" owner_bridge_br_ovn_ext_uuid 2>/dev/null || true)" ;;
    esac
    [[ -n "${expected_uuid}" ]] \
      || die "UUID de ownership ausente para ${bridge}"
    actual_uuid="$(mgc_bridge_uuid "${bridge}")"
    actual_token="$(mgc_bridge_owner_token "${bridge}")"
    [[ "${actual_uuid}" == "${expected_uuid}" ]] \
      || die "UUID da bridge ${bridge} não corresponde ao estado do perfil"
    [[ "${actual_token}" == "${token}" ]] \
      || die "token da bridge ${bridge} não corresponde ao perfil"
  done
}

mgc_remove_owned_bridges() {
  mgc_assert_bridges_owned yes
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: ovs-vsctl --if-exists del-br br-ovn"
    echo "DRY: ovs-vsctl --if-exists del-br br-ovn-ext"
    return 0
  fi
  run ovs-vsctl --if-exists del-br br-ovn
  run ovs-vsctl --if-exists del-br br-ovn-ext
  mgc_assert_bridges_absent
}

mgc_create_owned_bridges() {
  local token uuid
  token="$(state_get "${LAB_NAME}" owner_token 2>/dev/null || true)"
  if [[ "${DRY_RUN}" == "1" ]]; then
    token="${token:-DRY-MGC-OWNER}"
  fi
  [[ -n "${token}" ]] || die "não há token de ownership para criar bridges"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: ovs-vsctl add-br br-ovn"
    echo "DRY: ovs-vsctl set Bridge br-ovn external_ids:labctl-mgc-owner-token=${token}"
    echo "DRY: ovs-vsctl add-br br-ovn-ext"
    echo "DRY: ovs-vsctl set Bridge br-ovn-ext external_ids:labctl-mgc-owner-token=${token}"
    return 0
  fi
  mgc_assert_bridges_absent
  run ovs-vsctl add-br br-ovn
  run ovs-vsctl set Bridge br-ovn \
    "external_ids:labctl-mgc-owner-token=${token}"
  run ovs-vsctl add-br br-ovn-ext
  run ovs-vsctl set Bridge br-ovn-ext \
    "external_ids:labctl-mgc-owner-token=${token}"
  uuid="$(mgc_bridge_uuid br-ovn)"
  [[ -n "${uuid}" ]] || die "não foi possível obter UUID da bridge br-ovn"
  state_set "${LAB_NAME}" owner_bridge_br_ovn_uuid "${uuid}"
  uuid="$(mgc_bridge_uuid br-ovn-ext)"
  [[ -n "${uuid}" ]] || die "não foi possível obter UUID da bridge br-ovn-ext"
  state_set "${LAB_NAME}" owner_bridge_br_ovn_ext_uuid "${uuid}"
  mgc_assert_bridges_owned
}

mgc_owner_key() {
  local name="$1"
  name="${name//-/_}"
  echo "owner_id_${name}"
}

mgc_container_id() {
  local name="$1"
  docker inspect -f '{{.Id}}' "${name}" 2>/dev/null || true
}

mgc_client_owner_key() {
  local name="$1"
  name="${name//-/_}"
  echo "client_id_${name}"
}

mgc_assert_client_ownership() {
  local client="$1" token expected actual label
  [[ "$(mgc_count_named "${client}")" -gt 0 ]] \
    || die "cliente ${client} não existe para conferir ownership"
  token="$(state_get "${LAB_NAME}" owner_token 2>/dev/null || true)"
  expected="$(state_get "${LAB_NAME}" "$(mgc_client_owner_key "${client}")" 2>/dev/null || true)"
  actual="$(mgc_container_id "${client}")"
  label="$(docker inspect -f '{{index .Config.Labels "labctl.mgc.owner"}}' "${client}" 2>/dev/null || true)"
  [[ -n "${token}" && -n "${expected}" && "${actual}" == "${expected}" \
    && "${label}" == "${token}" ]] \
    || die "cliente ${client} existe sem ownership comprovada para ${LAB_NAME}"
}

mgc_record_client_ownership() {
  local client="$1" id token
  id="$(mgc_container_id "${client}")"
  token="$(state_get "${LAB_NAME}" owner_token 2>/dev/null || true)"
  [[ -n "${id}" && -n "${token}" ]] \
    || die "não foi possível registrar ownership do cliente ${client}"
  state_set "${LAB_NAME}" "$(mgc_client_owner_key "${client}")" "${id}"
  state_set "${LAB_NAME}" "$(mgc_client_owner_key "${client}")_label" "${token}"
}

mgc_expected_ovs_commit() {
  [[ -d "${MGC_OVN_SRC}/.git" ]] || return 0
  git -C "${MGC_OVN_SRC}" ls-tree HEAD ovs 2>/dev/null \
    | awk '$1 == "160000" && $NF == "ovs" {print $3; exit}'
}

mgc_assert_cluster_ownership() {
  local owner_state owner_token owner_expected name actual expected present=0
  owner_state="$(state_get "${LAB_NAME}" owner_state 2>/dev/null || true)"
  owner_token="$(state_get "${LAB_NAME}" owner_token 2>/dev/null || true)"
  owner_expected="$(state_get "${LAB_NAME}" owner_expected_names 2>/dev/null || true)"
  [[ "${owner_state}" == "starting" || "${owner_state}" == "partial" \
    || "${owner_state}" == "owned" ]] \
    || die "ownership do cluster OVN não comprovada (estado=${owner_state:-ausente})"
  [[ -n "${owner_token}" ]] \
    || die "ownership do cluster OVN sem token no estado do perfil"
  [[ "${owner_expected}" == "${MG_CENTRAL},${MG_GATEWAY_1},${MG_GATEWAY_2},${MG_CHASSIS_1},${MG_CHASSIS_2}" ]] \
    || die "ownership do cluster OVN sem lista esperada de nomes no estado"

  while IFS= read -r name; do
    if [[ "$(mgc_count_named "${name}")" -gt 0 ]]; then
      present=$((present + 1))
      expected="$(state_get "${LAB_NAME}" "$(mgc_owner_key "${name}")" 2>/dev/null || true)"
      [[ -n "${expected}" ]] \
        || die "container ${name} existe, mas seu ID não está registrado para ${LAB_NAME}"
      actual="$(mgc_container_id "${name}")"
      [[ -n "${actual}" && "${actual}" == "${expected}" ]] \
        || die "container ${name} não corresponde ao ID de ownership registrado"
    fi
  done < <(mgc_expected_cluster_names)
  [[ "${present}" -gt 0 ]] \
    || die "ownership consultada sem nenhum container OVN presente"
}

mgc_record_cluster_ids() {
  local owner_state="$1" name id
  while IFS= read -r name; do
    if [[ "$(mgc_count_named "${name}")" -gt 0 ]]; then
      id="$(mgc_container_id "${name}")"
      [[ -n "${id}" ]] || die "não foi possível obter o ID de ${name}"
      state_set "${LAB_NAME}" "$(mgc_owner_key "${name}")" "${id}"
    fi
  done < <(mgc_expected_cluster_names)
  state_set "${LAB_NAME}" owner_state "${owner_state}"
  state_set "${LAB_NAME}" owner_observed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

mgc_record_discovered_cluster_ids() {
  local name id found=0
  while IFS= read -r name; do
    if [[ "$(mgc_count_named "${name}" running)" -gt 0 ]]; then
      id="$(mgc_container_id "${name}")"
      if [[ -n "${id}" ]]; then
        state_set "${LAB_NAME}" "$(mgc_owner_key "${name}")" "${id}"
        found=1
      fi
    fi
  done < <(mgc_expected_cluster_names)
  if [[ "${found}" -eq 1 ]]; then
    state_set "${LAB_NAME}" owner_state partial
    state_set "${LAB_NAME}" owner_observed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    return 0
  fi
  return 1
}

mgc_stop_owned_cluster() {
  local cluster_all ev stop_log
  cluster_all="$(mgc_cluster_count all)"
  [[ "${cluster_all}" -eq 0 ]] && return 0
  mgc_assert_no_extra_ovn_containers
  mgc_assert_cluster_ownership
  mgc_assert_bridges_owned yes
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: (cd ${MGC_FAKE_MN} && RUNC_CMD=${RUNC_CMD} CENTRAL_COUNT=1 CHASSIS_COUNT=2 GW_COUNT=2 CREATE_FAKE_VMS=no ./ovn_cluster.sh stop)"
    return 0
  fi
  ev="$(evidence_dir "${LAB_NAME}")"
  stop_log="${ev}/ovn-stop-recovery.log"
  run env RUNC_CMD="${RUNC_CMD}" CENTRAL_COUNT=1 CHASSIS_COUNT=2 \
    GW_COUNT=2 CREATE_FAKE_VMS=no bash -c \
    "cd '${MGC_FAKE_MN}' && ./ovn_cluster.sh stop" >"${stop_log}" 2>&1
  [[ "$(mgc_cluster_count all)" -eq 0 ]] \
    || die "stop do cluster próprio deixou containers OVN residuais"
  mgc_assert_no_extra_ovn_containers
  mgc_assert_bridges_absent
  state_set "${LAB_NAME}" owner_state stopped
  state_set "${LAB_NAME}" owner_stopped_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

mgc_prepare_cluster_ownership() {
  local cluster_all cluster_running owner_token name
  mgc_assert_no_extra_ovn_containers
  cluster_all="$(mgc_cluster_count all)"
  cluster_running="$(mgc_cluster_count running)"
  if [[ "${cluster_all}" -gt 0 ]]; then
    mgc_assert_cluster_ownership
    if [[ "${cluster_running}" -eq 5 ]]; then
      mgc_assert_bridges_owned
      return 0
    fi
    log "  cluster parcial do próprio perfil; recuperação por stop seguro"
    mgc_stop_owned_cluster
    [[ "${DRY_RUN}" == "1" ]] && return 0
  fi
  if mgc_any_bridge_exists; then
    mgc_remove_owned_bridges
    [[ "${DRY_RUN}" == "1" ]] && return 0
  fi
  [[ "$(mgc_cluster_count all)" -eq 0 ]] \
    || die "não foi possível provar ausência do cluster antes do start"
  mgc_assert_no_extra_ovn_containers
  mgc_assert_bridges_absent

  owner_token="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  while IFS= read -r name; do
    state_set "${LAB_NAME}" "$(mgc_owner_key "${name}")" ""
  done < <(mgc_expected_cluster_names)
  state_set "${LAB_NAME}" owner_state starting
  state_set "${LAB_NAME}" owner_token "${owner_token}"
  state_set "${LAB_NAME}" owner_expected_names \
    "${MG_CENTRAL},${MG_GATEWAY_1},${MG_GATEWAY_2},${MG_CHASSIS_1},${MG_CHASSIS_2}"
  state_set "${LAB_NAME}" owner_ovn_commit "${OVN_COMMIT}"
  state_set "${LAB_NAME}" owner_fake_multinode_commit "${FAKE_MN_COMMIT_PREFIX}"
  state_set "${LAB_NAME}" owner_absent_verified_at \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

mgc_ovs_port() {
  local container="$1" interface="$2"
  ovs-vsctl --data=bare --no-heading --columns=name find interface \
    external_ids:container_id="${container}" \
    external_ids:container_iface="${interface}" 2>/dev/null \
    | awk 'NF {print; exit}'
}

mgc_m03_marker_present() {
  [[ -e "${MG_M03_MARKER_FILE}" ]]
}

mgc_m03_marker_valid() {
  local key count mode resource_count version line_count
  [[ -f "${MG_M03_MARKER_FILE}" && -O "${MG_M03_MARKER_FILE}" \
    && ! -g "${MG_M03_MARKER_FILE}" ]] || return 1
  mode="$(stat -c '%a' "${MG_M03_MARKER_FILE}" 2>/dev/null || true)"
  [[ "${mode}" == 600 ]] || return 1
  version="$(sed -n 's/^version=//p' "${MG_M03_MARKER_FILE}")"
  case "${version}" in
    1) line_count=16 ;;
    2) line_count=18 ;;
    *) return 1 ;;
  esac
  [[ "$(wc -l <"${MG_M03_MARKER_FILE}" 2>/dev/null || true)" -eq "${line_count}" ]] || return 1
  for key in version token run_token central lrp tenant_vrf intent \
    baseline_lrp_maintain_vrf baseline_ls_dynamic_routing_vni; do
    count="$(grep -Ec "^${key}=[^[:space:]]+$" "${MG_M03_MARKER_FILE}" || true)"
    [[ "${count}" -eq 1 ]] || return 1
  done
  grep -Eq '^version=[12]$' "${MG_M03_MARKER_FILE}" || return 1
  if [[ "${version}" == 2 ]]; then
    grep -Fqx 'baseline_lrp_port_name=absent' "${MG_M03_MARKER_FILE}" || return 1
    grep -Fqx 'baseline_chassis_port_mapping=absent' "${MG_M03_MARKER_FILE}" || return 1
  fi
  grep -Eq '^central=ovn-central-az1$' "${MG_M03_MARKER_FILE}" || return 1
  grep -Eq '^lrp=lrp-mgc-tenant$' "${MG_M03_MARKER_FILE}" || return 1
  grep -Eq '^tenant_vrf=ovnvrf-tenant$' "${MG_M03_MARKER_FILE}" || return 1
  grep -Eq '^intent=maintain-vrf$' "${MG_M03_MARKER_FILE}" || return 1
  grep -Eq '^baseline_lrp_maintain_vrf=absent$' "${MG_M03_MARKER_FILE}" || return 1
  grep -Eq '^baseline_ls_dynamic_routing_vni=50100$' "${MG_M03_MARKER_FILE}" || return 1
  grep -Eq '^token=labctl-m03-[^[:space:]]+$' "${MG_M03_MARKER_FILE}" || return 1
  grep -Eq '^run_token=[^[:space:]]+$' "${MG_M03_MARKER_FILE}" || return 1
  for key in \
    "resource=chassis:${MG_M03_TENANT_BR}:bridge" \
    "resource=chassis:${MG_M03_TENANT_VXLAN}:vxlan" \
    "resource=chassis:${MG_M03_TENANT_ADVERTISE}:dummy"; do
    [[ "$(grep -Fxc "${key}" "${MG_M03_MARKER_FILE}" || true)" -eq 1 ]] \
      || return 1
  done
  for key in \
    "resource=peer:${MG_M03_CLIENT_BR}:bridge" \
    "resource=peer:${MG_M03_CLIENT_VXLAN}:vxlan" \
    "resource=peer:${MG_M03_CLIENT_ADVERTISE}:dummy"; do
    [[ "$(grep -Fxc "${key}" "${MG_M03_MARKER_FILE}" || true)" -eq 1 ]] \
      || return 1
  done
  resource_count="$(grep -Ec '^resource=' "${MG_M03_MARKER_FILE}" || true)"
  [[ "${resource_count}" -eq 7 ]] || return 1
  if [[ "$(grep -Fxc "resource=peer:${MG_M03_CLIENT_VRF}:vrf" \
      "${MG_M03_MARKER_FILE}" || true)" -eq 1 ]]; then
    :
  elif [[ "$(grep -Fxc "resource=peer:${MG_M03_LEGACY_CLIENT_VRF}:vrf" \
      "${MG_M03_MARKER_FILE}" || true)" -eq 1 ]]; then
    :
  else
    return 1
  fi
  return 0
}

mgc_m03_port_name() {
  local run_token
  mgc_m03_marker_valid || return 1
  run_token="$(sed -n 's/^run_token=//p' "${MG_M03_MARKER_FILE}")"
  printf 'm03-evpn-%s\n' "$run_token"
}

mgc_m03_lrp_port_name() {
  docker exec "$MG_M03_CENTRAL" ovn-nbctl --if-exists get \
    logical_router_port "$MG_M03_TENANT_LRP" \
    options:dynamic-routing-port-name | tr -d '"'
}

mgc_m03_chassis_port_mapping() {
  docker exec "$MG_M03_CHASSIS" ovs-vsctl --if-exists get \
    Open_vSwitch . external_ids:dynamic-routing-port-mapping | tr -d '"'
}

mgc_m03_validate_return_filter_owned() {
  local port_name expected lrp_value mapping_value
  mgc_m03_marker_valid || die 'marker M03 inválido; filtro de retorno preservado'
  grep -Fqx 'version=2' "$MG_M03_MARKER_FILE" || return 0
  port_name="$(mgc_m03_port_name)"
  expected="${port_name}=${MG_M03_TENANT_BR}"
  lrp_value="$(mgc_m03_lrp_port_name)" \
    || die 'não foi possível ler dynamic-routing-port-name antes do cleanup'
  mapping_value="$(mgc_m03_chassis_port_mapping)" \
    || die 'não foi possível ler dynamic-routing-port-mapping antes do cleanup'
  [[ -z "$lrp_value" || "$lrp_value" == "$port_name" ]] \
    || die "dynamic-routing-port-name divergiu do marker M03: $lrp_value"
  [[ -z "$mapping_value" || "$mapping_value" == "$expected" ]] \
    || die "dynamic-routing-port-mapping divergiu do marker M03: $mapping_value"
}

mgc_m03_restore_return_filter() {
  local port_name expected lrp_value mapping_value
  mgc_m03_validate_return_filter_owned
  grep -Fqx 'version=2' "$MG_M03_MARKER_FILE" || return 0
  port_name="$(mgc_m03_port_name)"
  expected="${port_name}=${MG_M03_TENANT_BR}"
  lrp_value="$(mgc_m03_lrp_port_name)" \
    || die 'não foi possível ler dynamic-routing-port-name antes do cleanup'
  mapping_value="$(mgc_m03_chassis_port_mapping)" \
    || die 'não foi possível ler dynamic-routing-port-mapping antes do cleanup'
  [[ -z "$lrp_value" || "$lrp_value" == "$port_name" ]] \
    || die "dynamic-routing-port-name divergiu do marker M03: $lrp_value"
  [[ -z "$mapping_value" || "$mapping_value" == "$expected" ]] \
    || die "dynamic-routing-port-mapping divergiu do marker M03: $mapping_value"
  if [[ -n "$lrp_value" ]]; then
    run docker exec "$MG_M03_CENTRAL" ovn-nbctl --wait=sb remove \
      logical_router_port "$MG_M03_TENANT_LRP" options \
      dynamic-routing-port-name
  fi
  if [[ -n "$mapping_value" ]]; then
    run docker exec "$MG_M03_CHASSIS" ovs-vsctl remove \
      Open_vSwitch . external_ids dynamic-routing-port-mapping
  fi
  if [[ "$DRY_RUN" != 1 ]]; then
    lrp_value="$(mgc_m03_lrp_port_name)" \
      || die 'não foi possível confirmar remoção de dynamic-routing-port-name'
    mapping_value="$(mgc_m03_chassis_port_mapping)" \
      || die 'não foi possível confirmar remoção de dynamic-routing-port-mapping'
    [[ -z "$lrp_value" && -z "$mapping_value" ]] \
      || die 'filtro de retorno M03 permaneceu após cleanup'
  fi
}

mgc_m03_marker_uses_legacy_vrf() {
  mgc_m03_marker_valid \
    && [[ "$(grep -Fxc "resource=peer:${MG_M03_LEGACY_CLIENT_VRF}:vrf" \
      "${MG_M03_MARKER_FILE}" || true)" -eq 1 ]]
}

mgc_m03_marker_owner() {
  local token run_token
  mgc_m03_marker_valid || return 1
  token="$(sed -n 's/^token=//p' "${MG_M03_MARKER_FILE}")"
  run_token="$(sed -n 's/^run_token=//p' "${MG_M03_MARKER_FILE}")"
  [[ "${token}" == "labctl-m03-${run_token}" ]] || return 1
  printf '%s\n' "${token}"
}

mgc_m03_marker_has_resource() {
  local role="$1" link="$2" kind="$3"
  mgc_m03_marker_valid \
    && grep -Fqx "resource=${role}:${link}:${kind}" "${MG_M03_MARKER_FILE}"
}

mgc_m03_remove_marker() {
  local expected="${1:-}" actual
  [[ -e "${MG_M03_MARKER_FILE}" ]] || return 0
  actual="$(mgc_m03_marker_owner || true)"
  [[ -n "${expected}" && "${actual}" == "${expected}" ]] || return 1
  rm -f -- "${MG_M03_MARKER_FILE}" || return 1
  [[ ! -e "${MG_M03_MARKER_FILE}" ]]
}

mgc_m03_peer_label() {
  docker inspect -f "{{index .Config.Labels \"${MG_M03_OWNER_LABEL}\"}}" \
    "${MG_M03_PEER}" 2>/dev/null || true
}

mgc_m03_peer_profile_owner() {
  docker inspect -f '{{index .Config.Labels "labctl.mgc.owner"}}' \
    "${MG_M03_PEER}" 2>/dev/null || true
}

mgc_m03_ovs_owner() {
  local iface
  iface="$(mgc_ovs_port "${MG_M03_PEER}" eth1 || true)"
  [[ -n "${iface}" ]] || return 0
  ovs-vsctl get Interface "${iface}" external_ids:labctl-m03-owner \
    2>/dev/null | tr -d '"' || true
}

mgc_m03_chassis_owner() {
  local link alias token=""
  for link in "${MG_M03_TENANT_BR}" "${MG_M03_TENANT_VXLAN}" \
    "${MG_M03_TENANT_ADVERTISE}" "${MG_M03_TENANT_VRF}"; do
    alias="$(docker exec "${MG_M03_CHASSIS}" ip -details link show "${link}" \
      2>/dev/null | grep -Eo 'alias labctl-m03-[^[:space:]]+' \
      | awk '{print $2}' | head -n 1 || true)"
    [[ -z "${alias}" ]] && continue
    if [[ -n "${token}" && "${token}" != "${alias}" ]]; then
      return 1
    fi
    token="${alias}"
  done
  [[ -n "${token}" ]] && printf '%s\n' "${token}"
}

mgc_m03_owner_token() {
  local marker_owner peer_label chassis_owner ovs_owner
  marker_owner="$(mgc_m03_marker_owner || true)"
  if mgc_m03_marker_present && [[ -z "${marker_owner}" ]]; then
    return 1
  fi
  peer_label="$(mgc_m03_peer_label)"
  chassis_owner="$(mgc_m03_chassis_owner || true)"
  ovs_owner="$(mgc_m03_ovs_owner)"
  if [[ -n "${marker_owner}" ]]; then
    [[ -z "${peer_label}" || "${peer_label}" == "${marker_owner}" ]] || return 1
    [[ -z "${chassis_owner}" || "${chassis_owner}" == "${marker_owner}" ]] || return 1
    [[ -z "${ovs_owner}" || "${ovs_owner}" == "${marker_owner}" ]] || return 1
    printf '%s\n' "${marker_owner}"
    return 0
  fi
  if [[ -n "${peer_label}" ]]; then
    [[ "${peer_label}" == labctl-m03-* ]] || return 1
    [[ -z "${chassis_owner}" || "${chassis_owner}" == "${peer_label}" ]] \
      || return 1
    [[ -z "${ovs_owner}" || "${ovs_owner}" == "${peer_label}" ]] \
      || return 1
    printf '%s\n' "${peer_label}"
    return 0
  fi
  if [[ -n "${chassis_owner}" && -n "${ovs_owner}" \
    && "${chassis_owner}" != "${ovs_owner}" ]]; then
    return 1
  fi
  [[ -n "${chassis_owner}" ]] && { printf '%s\n' "${chassis_owner}"; return 0; }
  [[ -n "${ovs_owner}" ]] && { printf '%s\n' "${ovs_owner}"; return 0; }
  return 1
}

mgc_m03_pathspace_active() {
  docker exec "${MG_M03_CHASSIS}" sh -c '
    for daemon in zebra bgpd staticd; do
      for pid in $(pidof "${daemon}" 2>/dev/null || true); do
        cmdline="$(tr "\\000" " " <"/proc/${pid}/cmdline" 2>/dev/null || true)"
        case "${cmdline}" in
          *"-N m03"*|*"/run/frr/m03"*) exit 0 ;;
        esac
      done
    done
    exit 1
  ' >/dev/null 2>&1
}

mgc_m03_physical_resource_present() {
  local path link port lrp_options port_mapping
  [[ "$(mgc_count_named "${MG_M03_PEER}")" -gt 0 ]] && return 0
  # ovs-runc may choose a host interface name that does not contain the
  # container name.  The external_ids pair is the ownership identity.
  port="$(mgc_ovs_port "${MG_M03_PEER}" eth1 || true)"
  [[ -n "${port}" ]] && return 0
  for link in "${MG_M03_TENANT_BR}" "${MG_M03_TENANT_VXLAN}" \
    "${MG_M03_TENANT_ADVERTISE}" "${MG_M03_TENANT_VRF}" \
    "${MG_M03_CLIENT_VRF}" \
    "${MG_M03_CLIENT_BR}" "${MG_M03_CLIENT_VXLAN}" "${MG_M03_CLIENT_ADVERTISE}"; do
    if docker exec "${MG_M03_CHASSIS}" ip link show "${link}" >/dev/null 2>&1 \
      || docker exec "${MG_M03_PEER}" ip link show "${link}" >/dev/null 2>&1; then
      return 0
    fi
  done
  for path in /etc/frr/m03 /run/frr/m03; do
    docker exec "${MG_M03_CHASSIS}" test -e "${path}" >/dev/null 2>&1 \
      && return 0
  done
  if mgc_m03_pathspace_active; then
    return 0
  fi
  if [[ "$(mgc_count_named "${MG_M03_CENTRAL}" running)" -gt 0 ]]; then
    if ! lrp_options="$(docker exec "${MG_M03_CENTRAL}" ovn-nbctl \
      get logical_router_port "${MG_M03_TENANT_LRP}" options 2>&1)"; then
      die "não foi possível ler options de ${MG_M03_TENANT_LRP} para detectar M03: ${lrp_options}"
    fi
    if grep -Fq dynamic-routing-maintain-vrf <<<"${lrp_options}" \
      || grep -Fq dynamic-routing-redistribute <<<"${lrp_options}" \
      || grep -Fq dynamic-routing-port-name <<<"${lrp_options}"; then
      return 0
    fi
  fi
  if [[ "$(mgc_count_named "${MG_M03_CHASSIS}" running)" -gt 0 ]]; then
    port_mapping="$(mgc_m03_chassis_port_mapping)" \
      || die 'não foi possível ler dynamic-routing-port-mapping para detectar M03'
    [[ -n "$port_mapping" ]] && return 0
  fi
  if [[ "$(mgc_count_named "${MG_M03_CHASSIS}" running)" -gt 0 ]] \
    && ! docker exec "${MG_M03_CHASSIS}" true >/dev/null 2>&1; then
    die "${MG_M03_CHASSIS} está running mas inacessível; detecção M03 abortada"
  fi
  return 1
}

mgc_m03_resource_present() {
  mgc_m03_physical_resource_present && return 0
  mgc_m03_marker_present && return 0
  return 1
}

mgc_assert_m03_absent() {
  mgc_m03_physical_resource_present \
    && die 'resíduo M03 detectado; execute rollback/cleanup owned antes do ciclo MGC'
  if mgc_m03_marker_present && [[ "${M03_ROLLBACK_ALLOW_MARKER:-0}" != 1 ]]; then
    die 'marker M03 ativo; execute rollback/cleanup owned antes do ciclo MGC'
  fi
  return 0
}

mgc_m03_require_cleanup_nodes() {
  local node state
  for node in "${MG_M03_CENTRAL}" "${MG_M03_CHASSIS}"; do
    state="$(docker inspect -f '{{.State.Status}}' "${node}" \
      2>/dev/null || true)"
    [[ "${state}" == running ]] \
      || die "${node} não está running; cleanup M03 abortado para preservar marker e recursos"
    docker exec "${node}" true >/dev/null 2>&1 \
      || die "${node} está running mas inacessível; cleanup M03 abortado"
  done
}

mgc_m03_assert_active() {
  local token peer_state profile_token port owner bridge link kind details port_name
  [[ "${MGC_M03_MODE}" == 1 ]] \
    || die 'verificação M03 solicitada sem --m03 explícito'
  mgc_m03_marker_valid \
    || die 'M03 sem marker válido de ownership; refusing verify'
  if grep -Fqx 'version=2' "$MG_M03_MARKER_FILE"; then
    port_name="$(mgc_m03_port_name)"
    [[ "$(mgc_m03_lrp_port_name)" == "$port_name" \
      && "$(mgc_m03_chassis_port_mapping)" == "${port_name}=${MG_M03_TENANT_BR}" ]] \
      || die 'filtro de retorno M03 não corresponde ao marker'
  fi
  token="$(mgc_m03_owner_token || true)"
  [[ -n "${token}" && "${token}" == labctl-m03-* ]] \
    || die 'M03 sem token de ownership verificável'
  peer_state="$(docker inspect -f '{{.State.Status}}' "${MG_M03_PEER}" \
    2>/dev/null || true)"
  [[ "${peer_state}" == running ]] \
    || die "peer M03 não está running: ${peer_state:-ausente}"
  [[ "$(mgc_m03_peer_label)" == "${token}" ]] \
    || die 'label de ownership do peer M03 diverge do marker'
  profile_token="$(state_get "${LAB_NAME}" owner_token 2>/dev/null || true)"
  [[ -n "${profile_token}" \
    && "$(mgc_m03_peer_profile_owner)" == "${profile_token}" ]] \
    || die 'peer M03 não carrega o token do perfil MGC'
  port="$(mgc_ovs_port "${MG_M03_PEER}" eth1 || true)"
  [[ -n "${port}" ]] || die 'porta OVS do peer M03 ausente'
  bridge="$(ovs-vsctl port-to-br "${port}" 2>/dev/null || true)"
  [[ "${bridge}" == br-ovn ]] \
    || die "porta M03 está em bridge inesperada: ${bridge}"
  owner="$(mgc_m03_ovs_owner)"
  [[ "${owner}" == "${token}" ]] \
    || die 'porta OVS M03 não carrega o token do marker'
  for link in "${MG_M03_TENANT_BR}" "${MG_M03_TENANT_VXLAN}" \
    "${MG_M03_TENANT_ADVERTISE}"; do
    kind="$(mgc_m03_link_kind_v2 "${MG_M03_CHASSIS}" "${link}")"
    mgc_m03_marker_has_resource chassis "${link}" "${kind}" \
      || die "link M03 não está no intent do marker: chassis:${link}"
    details="$(docker exec "${MG_M03_CHASSIS}" ip -details link show "${link}" \
      2>/dev/null || true)"
    [[ -n "${details}" && "${details}" == *"alias ${token}"* ]] \
      || die "link M03 sem alias de ownership no chassis: ${link}"
    mgc_m03_link_matches_intent_v2 "${MG_M03_CHASSIS}" "${link}" "${kind}" \
      || die "link M03 diverge do intent no chassis: ${link}"
  done
  for link in "${MG_M03_CLIENT_VRF}" "${MG_M03_CLIENT_BR}" \
    "${MG_M03_CLIENT_VXLAN}" "${MG_M03_CLIENT_ADVERTISE}"; do
    kind="$(mgc_m03_link_kind_v2 "${MG_M03_PEER}" "${link}")"
    mgc_m03_marker_has_resource peer "${link}" "${kind}" \
      || die "link M03 não está no intent do marker: peer:${link}"
    details="$(docker exec "${MG_M03_PEER}" ip -details link show "${link}" \
      2>/dev/null || true)"
    [[ -n "${details}" && "${details}" == *"alias ${token}"* ]] \
      || die "link M03 sem alias de ownership no peer: ${link}"
    mgc_m03_link_matches_intent_v2 "${MG_M03_PEER}" "${link}" "${kind}" \
      || die "link M03 diverge do intent no peer: ${link}"
  done
}

mgc_m03_link_kind_v2() {
  local node="$1" link="$2"
  case "$node:$link" in
    "$MG_M03_CHASSIS:$MG_M03_TENANT_BR") printf '%s\n' bridge ;;
    "$MG_M03_CHASSIS:$MG_M03_TENANT_VXLAN") printf '%s\n' vxlan ;;
    "$MG_M03_CHASSIS:$MG_M03_TENANT_ADVERTISE") printf '%s\n' dummy ;;
    "$MG_M03_PEER:$MG_M03_CLIENT_VRF") printf '%s\n' vrf ;;
    "$MG_M03_PEER:$MG_M03_CLIENT_BR") printf '%s\n' bridge ;;
    "$MG_M03_PEER:$MG_M03_CLIENT_VXLAN") printf '%s\n' vxlan ;;
    "$MG_M03_PEER:$MG_M03_CLIENT_ADVERTISE") printf '%s\n' dummy ;;
    *) return 1 ;;
  esac
}

mgc_m03_link_matches_intent_v2() {
  local node="$1" link="$2" kind="$3" details
  details="$(docker exec "$node" ip -details link show "$link" 2>/dev/null || true)"
  [[ -n "$details" ]] || return 1
  case "$kind" in
    bridge) grep -Eiq '(^|[[:space:]])bridge([[:space:]]|$)' <<<"$details" ;;
    vxlan) grep -Fq "vxlan id $MG_TENANT_VNI" <<<"$details" ;;
    dummy) grep -Eiq '(^|[[:space:]])dummy([[:space:]@]|$)' <<<"$details" ;;
    vrf) grep -Fq "vrf table $MG_TENANT_VNI" <<<"$details" ;;
    *) return 1 ;;
  esac
}

mgc_m03_remove_owned_links() {
  local node="$1" token="$2" link kind role alias_name
  shift 2
  if [[ "$node" == "$MG_M03_CHASSIS" ]]; then
    role=chassis
  elif [[ "$node" == "$MG_M03_PEER" ]]; then
    role=peer
  else
    die "node M03 inesperado: $node"
  fi
  for link in "$@"; do
    if docker exec "$node" ip link show "$link" >/dev/null 2>&1; then
      kind="$(mgc_m03_link_kind_v2 "$node" "$link" || true)"
      if [[ -z "$kind" ]] \
        || ! mgc_m03_marker_has_resource "$role" "$link" "$kind" \
        || ! mgc_m03_link_matches_intent_v2 "$node" "$link" "$kind"; then
        die "não removendo $node:$link: tipo/configuração diverge do marker M03"
      fi
      alias_name="$(docker exec "$node" ip -details link show "$link" 2>/dev/null \
        | grep -Eo 'alias [^[:space:]]+' | head -n 1 | awk '{print $2}' || true)"
      [[ "$alias_name" == "$token" ]] \
        || die "não removendo $node:$link: alias M03 ausente ou divergente"
    fi
  done
  for link in "$@"; do
    if docker exec "$node" ip link show "$link" >/dev/null 2>&1; then
      run docker exec "$node" ip link del "$link"
      docker exec "$node" ip link show "$link" >/dev/null 2>&1 \
        && die "$node:$link ainda existe após cleanup"
    fi
  done
}

mgc_m03_stop_pathspace() {
  local init active
  if ! active="$(docker exec "${MG_M03_CHASSIS}" sh -c '
    for daemon in zebra bgpd staticd; do
      for pid in $(pidof "${daemon}" 2>/dev/null || true); do
        cmdline="$(tr "\\000" " " <"/proc/${pid}/cmdline" 2>/dev/null || true)"
        case "${cmdline}" in
          *"-N m03"*|*"/run/frr/m03"*) printf "%s:%s\\n" "${daemon}" "${pid}" ;;
        esac
      done
    done
  ' 2>&1)"; then
    die "não foi possível inspecionar daemons FRR M03: ${active}"
  fi
  # A staged pathspace can exist before a daemon starts.  Remove it only after
  # proving no M03 daemon is alive; an active daemon still requires a verified
  # frrinit stop and remains protected on any failure.
  if [[ -n "${active}" ]]; then
  init="$(docker exec "${MG_M03_CHASSIS}" sh -c \
    'for c in /usr/libexec/frr/frrinit.sh /usr/lib/frr/frrinit.sh; do [ -x "$c" ] && { echo "$c"; exit 0; }; done; exit 1' \
    2>/dev/null || true)"
  [[ -n "${init}" ]] || die 'frrinit.sh ausente para cleanup do pathspace M03'
  run docker exec "${MG_M03_CHASSIS}" "${init}" stop m03
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi
  if ! active="$(docker exec "${MG_M03_CHASSIS}" sh -c '
    for daemon in zebra bgpd staticd; do
      for pid in $(pidof "${daemon}" 2>/dev/null || true); do
        cmdline="$(tr "\\000" " " <"/proc/${pid}/cmdline" 2>/dev/null || true)"
        case "${cmdline}" in *"-N m03"*|*"/run/frr/m03"*) echo "${daemon}:${pid}";; esac
      done
    done
  ' 2>&1)"; then
    die "não foi possível verificar daemons FRR M03 após stop: ${active}"
  fi
  [[ -z "${active}" ]] || die "daemons FRR M03 ainda ativos: ${active}"
  run docker exec "${MG_M03_CHASSIS}" rm -rf /run/frr/m03 /etc/frr/m03
}

mgc_m03_stop_peer_frr() {
  local init active
  if ! active="$(docker exec "${MG_M03_PEER}" sh -c '
    for daemon in zebra bgpd staticd; do
      pids="$(pidof "${daemon}" 2>/dev/null || true)"
      [ -z "${pids}" ] || printf "%s:%s\\n" "${daemon}" "${pids}"
    done
  ' 2>&1)"; then
    die "não foi possível inspecionar FRR do peer M03: ${active}"
  fi
  # The peer may be running while FRR staging failed before daemon start.
  # There is no stop command to issue in that state, but any live daemon must
  # still pass the normal stop and postcondition checks below.
  [[ -z "${active}" ]] && return 0
  init="$(docker exec "${MG_M03_PEER}" sh -c \
    'for c in /usr/libexec/frr/frrinit.sh /usr/lib/frr/frrinit.sh; do [ -x "$c" ] && { echo "$c"; exit 0; }; done; exit 1' \
    2>/dev/null || true)"
  [[ -n "${init}" ]] || die 'frrinit.sh ausente para cleanup FRR do peer M03'
  run docker exec "${MG_M03_PEER}" "${init}" stop
  if ! active="$(docker exec "${MG_M03_PEER}" sh -c '
    for daemon in zebra bgpd staticd; do
      pids="$(pidof "${daemon}" 2>/dev/null || true)"
      [ -z "${pids}" ] || { printf "%s:%s\\n" "${daemon}" "${pids}"; exit 1; }
    done
  ' 2>&1)"; then
    die "não foi possível verificar FRR do peer M03 após stop: ${active}"
  fi
  [[ -z "${active}" ]] || die "daemons FRR ainda ativos no peer M03: ${active}"
}

mgc_m03_remove_ovs_port() {
  local port="$1" peer_state="$2" expected_token="${3:-}" interface_uuid host_iface
  local port_owner current_host current_port
  [[ -n "${port}" ]] || return 0
  [[ -n "${expected_token}" ]] || die 'porta M03 sem token de ownership esperado'
  [[ "$(ovs-vsctl port-to-br "${port}" 2>/dev/null || true)" == br-ovn ]] \
    || die 'porta M03 não está em br-ovn; cleanup abortado'
  interface_uuid="$(ovs-vsctl get Port "${port}" interfaces 2>/dev/null \
    | tr -d '[]"' || true)"
  host_iface="$(ovs-vsctl get Interface "${interface_uuid}" name 2>/dev/null \
    | tr -d '"' || true)"
  port_owner="$(ovs-vsctl get Interface "${host_iface}" \
    external_ids:labctl-m03-owner 2>/dev/null | tr -d '"' || true)"
  [[ -z "${port_owner}" || "${port_owner}" == "${expected_token}" ]] \
    || die 'porta M03 tem owner token divergente; cleanup abortado'
  if [[ -z "${peer_state}" && "${port_owner}" != "${expected_token}" ]]; then
    die 'porta M03 órfã sem owner token verificável; cleanup abortado'
  fi
  if [[ "${peer_state}" == running ]]; then
    run env RUNC_CMD="${RUNC_CMD}" "${MGC_FAKE_MN}/ovs-runc" \
      del-port br-ovn eth1 "${MG_M03_PEER}"
  else
    run ovs-vsctl --if-exists del-port br-ovn "${port}"
  fi
  for _ in $(seq 1 15); do
    current_port="$(mgc_ovs_port "${MG_M03_PEER}" eth1 || true)"
    current_host="${host_iface}"
    if [[ -z "${current_port}" ]] \
      && { [[ -z "${current_host}" ]] \
        || ! ip link show "${current_host}" >/dev/null 2>&1; }; then
      return 0
    fi
    sleep 1
  done
  die "porta OVS M03 ${port} ou interface ${host_iface} ainda existe após cleanup"
}

mgc_m03_assert_chassis_owned_running() {
  local state expected actual
  state="$(docker inspect -f '{{.State.Status}}' "${MG_M03_CHASSIS}" \
    2>/dev/null || true)"
  [[ "${state}" == running ]] \
    || die "${MG_M03_CHASSIS} não está running; remoção explícita do VRF abortada"
  expected="$(state_get "${LAB_NAME}" "$(mgc_owner_key "${MG_M03_CHASSIS}")" \
    2>/dev/null || true)"
  actual="$(mgc_container_id "${MG_M03_CHASSIS}")"
  [[ -n "${expected}" && -n "${actual}" && "${actual}" == "${expected}" ]] \
    || die "${MG_M03_CHASSIS} não corresponde ao ID owned do perfil MGC"
  docker exec "${MG_M03_CHASSIS}" true >/dev/null 2>&1 \
    || die "${MG_M03_CHASSIS} está running mas inacessível; remoção do VRF abortada"
}

mgc_m03_remove_tenant_vrf() {
  local links details slaves
  mgc_m03_marker_valid \
    || die 'marker M03 inválido; não removendo VRF tenant'
  grep -Fqx 'baseline_lrp_maintain_vrf=absent' "${MG_M03_MARKER_FILE}" \
    || die 'marker M03 não prova baseline ausente do maintain-vrf'
  grep -Fqx "tenant_vrf=${MG_M03_TENANT_VRF}" "${MG_M03_MARKER_FILE}" \
    || die 'marker M03 não corresponde ao VRF tenant esperado'
  mgc_m03_assert_chassis_owned_running
  if ! links="$(docker exec "${MG_M03_CHASSIS}" ip -o link show 2>&1)"; then
    die "não foi possível listar links de ${MG_M03_CHASSIS} antes de remover ${MG_M03_TENANT_VRF}: ${links}"
  fi
  if ! awk -v wanted="${MG_M03_TENANT_VRF}" \
    '$2 == wanted ":" {found=1} END {exit(found ? 0 : 1)}' <<<"${links}"; then
    return 0
  fi
  if ! details="$(docker exec "${MG_M03_CHASSIS}" ip -details link show \
    "${MG_M03_TENANT_VRF}" 2>&1)"; then
    die "não foi possível inspecionar ${MG_M03_TENANT_VRF}: ${details}"
  fi
  grep -Eq "vrf table ${MG_M03_TENANT_TABLE}([[:space:]]|$)" <<<"${details}" \
    || die "${MG_M03_TENANT_VRF} não corresponde à tabela ${MG_M03_TENANT_TABLE}"
  if ! slaves="$(docker exec "${MG_M03_CHASSIS}" ip -o link show master \
    "${MG_M03_TENANT_VRF}" 2>&1)"; then
    die "não foi possível verificar slaves de ${MG_M03_TENANT_VRF}: ${slaves}"
  fi
  [[ -z "${slaves}" ]] \
    || die "${MG_M03_TENANT_VRF} ainda tem slaves; remoção abortada"
  run docker exec "${MG_M03_CHASSIS}" ip link del "${MG_M03_TENANT_VRF}"
  if ! links="$(docker exec "${MG_M03_CHASSIS}" ip -o link show 2>&1)"; then
    die "não foi possível confirmar remoção de ${MG_M03_TENANT_VRF}: ${links}"
  fi
  if awk -v wanted="${MG_M03_TENANT_VRF}" \
    '$2 == wanted ":" {found=1} END {exit(found ? 0 : 1)}' <<<"${links}"; then
    die "${MG_M03_TENANT_VRF} ainda existe após remoção explícita"
  fi
}

mgc_m03_validate_dry_cleanup() {
  local token peer_count port peer_label profile_token owner
  if ! mgc_m03_marker_present && ! mgc_m03_physical_resource_present; then
    return 0
  fi
  mgc_m03_require_cleanup_nodes
  token="$(mgc_m03_owner_token || true)"
  [[ -n "${token}" && "${token}" == labctl-m03-* ]] \
    || die 'dry-run encontrou resíduo M03 sem ownership verificável'
  peer_count="$(mgc_count_named "${MG_M03_PEER}")"
  if [[ "${peer_count}" -gt 0 ]]; then
    peer_label="$(mgc_m03_peer_label)"
    profile_token="$(state_get "${LAB_NAME}" owner_token 2>/dev/null || true)"
    [[ "${peer_label}" == "${token}" && -n "${profile_token}" \
      && "$(mgc_m03_peer_profile_owner)" == "${profile_token}" ]] \
      || die 'dry-run encontrou peer M03 sem ownership do marker/perfil'
  fi
  port="$(mgc_ovs_port "${MG_M03_PEER}" eth1 || true)"
  if [[ -n "${port}" ]]; then
    owner="$(mgc_m03_ovs_owner)"
    [[ "${owner}" == "${token}" ]] \
      || die 'dry-run encontrou porta OVS M03 sem ownership do marker'
  fi
  if mgc_m03_marker_uses_legacy_vrf; then
    [[ "${peer_count}" -eq 0 && -z "${port}" ]] \
      || die 'marker M03 legado ainda tem peer/porta; dry-run recusa recuperação'
  fi
}

mgc_m03_restore_tenant_vni() {
  local options restored expected_re
  expected_re="(^|[[:space:],{}])dynamic-routing-vni=\"?${MG_TENANT_VNI}\"?([[:space:],{}]|$)"
  if ! options="$(docker exec "${MG_M03_CENTRAL}" ovn-nbctl \
    get logical_switch "${MG_TENANT_LS}" other_config 2>&1)"; then
    die "não foi possível ler dynamic-routing-vni do tenant: ${options}"
  fi
  if grep -Eq "${expected_re}" <<<"${options}"; then
    return 0
  fi
  grep -Eq 'dynamic-routing-vni' <<<"${options}" \
    && die 'dynamic-routing-vni do tenant divergiu do baseline; cleanup abortado'
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: docker exec ${MG_M03_CENTRAL} ovn-nbctl --wait=sb set logical_switch ${MG_TENANT_LS} other_config:dynamic-routing-vni=${MG_TENANT_VNI}"
  elif ! docker exec "${MG_M03_CENTRAL}" ovn-nbctl --wait=sb set \
    logical_switch "${MG_TENANT_LS}" \
    "other_config:dynamic-routing-vni=${MG_TENANT_VNI}"; then
    die "não foi possível restaurar dynamic-routing-vni=${MG_TENANT_VNI}"
  fi
  if ! restored="$(docker exec "${MG_M03_CENTRAL}" ovn-nbctl \
    get logical_switch "${MG_TENANT_LS}" other_config 2>&1)"; then
    die "não foi possível confirmar dynamic-routing-vni restaurado: ${restored}"
  fi
  grep -Eq "${expected_re}" <<<"${restored}" \
    || die "pós-condição falhou: dynamic-routing-vni=${MG_TENANT_VNI} ausente"
}

mgc_m03_lock_action() {
  local fd_path lock_path fd_stat lock_stat held_fd
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: flock -n ${MG_M03_LOCK_FILE} (labctl mgc lifecycle)"
    return 0
  fi
  held_fd="${M03_LOCK_HELD_FD:-}"
  if [[ -n "${held_fd}" ]]; then
    [[ "${held_fd}" =~ ^[89]$ && -e "/proc/self/fd/${held_fd}" ]] \
      || die 'FD de lock M03 herdado é inválido ou está fechado'
    fd_path="$(readlink -f "/proc/self/fd/${held_fd}" 2>/dev/null || true)"
    lock_path="$(readlink -f "${MG_M03_LOCK_FILE}" 2>/dev/null || true)"
    [[ -n "${fd_path}" && -n "${lock_path}" && "${fd_path}" == "${lock_path}" ]] \
      || die 'FD 9 não corresponde ao caminho canonicalizado do lock M03'
    fd_stat="$(stat -Lc '%d:%i' "/proc/self/fd/${held_fd}" 2>/dev/null || true)"
    lock_stat="$(stat -Lc '%d:%i' "${MG_M03_LOCK_FILE}" 2>/dev/null || true)"
    [[ -n "${fd_stat}" && "${fd_stat}" == "${lock_stat}" ]] \
      || die 'FD 9 não corresponde ao inode aberto do lock M03'
    flock -n "${held_fd}" \
      || die 'M03 lock herdado está inconsistente; ação MGC abortada'
    return 0
  fi
  exec 8>"${MG_M03_LOCK_FILE}" \
    || die "não foi possível abrir lock ${MG_M03_LOCK_FILE}"
  flock -n 8 \
    || die 'M03 está em execução; ação labctl mgc não pode concorrer'
}

# An X05 run owns a temporary extension of this profile.  Once its intent
# marker exists, ordinary reconciliation must not overwrite gateway FRR or
# remove the M03 substrate before the X05 coordinator finishes its rollback.
mgc_x05_guard() {
  local marker="${MG_X05_MARKER_FILE}" token
  [[ -e "${marker}" || -L "${marker}" ]] || return 0
  [[ "${MG_M03_LOCK_FILE}" == /var/lock/labctl-mgc-m03.lock ]] \
    || die 'X05 ativo; caminho do lock M03 diverge do contrato'
  [[ -f "${marker}" && ! -L "${marker}" \
    && "$(stat -c '%u:%a' "${marker}" 2>/dev/null || true)" == '0:600' ]] \
    || die 'X05 marker inválido; ação MGC recusada'
  [[ "$(grep -c '^token=' "${marker}" || true)" == 1 ]] \
    || die 'X05 marker sem token único; ação MGC recusada'
  token="$(sed -n 's/^token=//p' "${marker}")"
  [[ "${token}" =~ ^labctl-x05-[0-9a-f]{6}$ ]] \
    || die 'X05 marker com token inválido; ação MGC recusada'
  [[ "${X05_COORDINATOR_TOKEN:-}" == "${token}" \
    && "${M03_LOCK_HELD_FD:-}" == 9 ]] \
    || die 'X05 ativo; apenas o coordenador sob o lock M03 pode agir no MGC'
}

mgc_m03_cleanup_owned() {
  local token port peer_state profile_token lrp_options
  # The marker names the MGC containers, but names alone do not authorize
  # writes to NB or links if a container was replaced after the M03 run.
  if mgc_m03_marker_present || mgc_m03_physical_resource_present; then
    mgc_assert_cluster_ownership
    mgc_m03_require_cleanup_nodes
  fi
  if mgc_m03_resource_present; then
    # Reject return-filter drift before stopping FRR or removing owned links.
    mgc_m03_validate_return_filter_owned
    if ! lrp_options="$(docker exec "${MG_M03_CENTRAL}" ovn-nbctl \
      get logical_router_port "${MG_M03_TENANT_LRP}" options 2>&1)"; then
      die "não foi possível ler options de ${MG_M03_TENANT_LRP} antes do cleanup: ${lrp_options}"
    fi
    grep -Fq dynamic-routing-redistribute <<<"${lrp_options}" \
      && die "${MG_M03_TENANT_LRP} mantém dynamic-routing-redistribute; chave deve ser restaurada manualmente antes de remover M03"
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    mgc_m03_validate_dry_cleanup
    if mgc_m03_marker_present; then
      mgc_m03_restore_return_filter
    fi
    echo "DRY: cleanup owned M03 peer/links/pathspace/LRP, restore tenant VNI, and remove tenant VRF table ${MG_M03_TENANT_TABLE} only after ownership/slave checks"
    return 0
  fi
  if mgc_m03_resource_present; then
    token="$(mgc_m03_owner_token || true)"
    [[ -n "${token}" && "${token}" == labctl-m03-* ]] \
      || die 'resíduo M03 sem ownership verificável; cleanup abortado'
    if mgc_m03_marker_uses_legacy_vrf; then
      [[ "$(mgc_count_named "${MG_M03_PEER}")" -eq 0 ]] \
        || die 'marker M03 legado ainda tem peer; recuperação recusada'
      [[ -z "$(mgc_ovs_port "${MG_M03_PEER}" eth1 || true)" ]] \
        || die 'marker M03 legado ainda tem porta OVS; recuperação recusada'
    fi

    peer_state="$(docker inspect -f '{{.State.Status}}' "${MG_M03_PEER}" \
      2>/dev/null || true)"
    port="$(mgc_ovs_port "${MG_M03_PEER}" eth1 || true)"
    if [[ -n "${peer_state}" ]]; then
      [[ "$(mgc_m03_peer_label)" == "${token}" ]] \
        || die 'peer M03 sem label de ownership correspondente; cleanup abortado'
      profile_token="$(state_get "${LAB_NAME}" owner_token 2>/dev/null || true)"
      [[ -n "${profile_token}" \
        && "$(mgc_m03_peer_profile_owner)" == "${profile_token}" ]] \
        || die 'peer M03 sem token labctl.mgc.owner do perfil; cleanup abortado'
      case "${peer_state}" in
        running)
          mgc_m03_stop_peer_frr
          mgc_m03_remove_owned_links "${MG_M03_PEER}" "${token}" \
            "${MG_M03_CLIENT_ADVERTISE}" "${MG_M03_CLIENT_VXLAN}" \
            "${MG_M03_CLIENT_BR}" "${MG_M03_CLIENT_VRF}"
          ;;
        created|exited|dead) ;;
        *) die "estado inesperado do peer M03 ${MG_M03_PEER}: ${peer_state}" ;;
      esac
    fi
    if [[ -n "${port}" ]]; then
      mgc_m03_remove_ovs_port "${port}" "${peer_state}" "${token}"
    fi
    if [[ -n "${peer_state}" ]]; then
      run docker rm -f "${MG_M03_PEER}"
      if docker inspect "${MG_M03_PEER}" >/dev/null 2>&1; then
        die "peer M03 ${MG_M03_PEER} ainda existe após remoção"
      fi
    fi

    mgc_m03_restore_tenant_vni
    if docker exec "${MG_M03_CHASSIS}" test -e /run/frr/m03 2>/dev/null \
      || docker exec "${MG_M03_CHASSIS}" test -e /etc/frr/m03 2>/dev/null \
      || mgc_m03_pathspace_active; then
      mgc_m03_stop_pathspace
    fi
    mgc_m03_restore_return_filter
    if ! lrp_options="$(docker exec "${MG_M03_CENTRAL}" ovn-nbctl \
      get logical_router_port "${MG_M03_TENANT_LRP}" options 2>&1)"; then
      die "não foi possível ler options de ${MG_M03_TENANT_LRP} durante cleanup: ${lrp_options}"
    fi
    if grep -Fq dynamic-routing-maintain-vrf <<<"${lrp_options}"; then
      run docker exec "${MG_M03_CENTRAL}" ovn-nbctl --wait=sb remove \
        logical_router_port "${MG_M03_TENANT_LRP}" options dynamic-routing-maintain-vrf
      if ! lrp_options="$(docker exec "${MG_M03_CENTRAL}" ovn-nbctl \
        get logical_router_port "${MG_M03_TENANT_LRP}" options 2>&1)"; then
        die "não foi possível confirmar options restauradas de ${MG_M03_TENANT_LRP}: ${lrp_options}"
      fi
      grep -Fq dynamic-routing-maintain-vrf <<<"${lrp_options}" \
        && die "${MG_M03_TENANT_LRP} ainda tem dynamic-routing-maintain-vrf após cleanup"
    fi
    if docker exec "${MG_M03_CHASSIS}" ip link show "${MG_M03_TENANT_BR}" >/dev/null 2>&1 \
      || docker exec "${MG_M03_CHASSIS}" ip link show "${MG_M03_TENANT_VXLAN}" >/dev/null 2>&1 \
      || docker exec "${MG_M03_CHASSIS}" ip link show "${MG_M03_TENANT_ADVERTISE}" >/dev/null 2>&1; then
      mgc_m03_remove_owned_links "${MG_M03_CHASSIS}" "${token}" \
        "${MG_M03_TENANT_ADVERTISE}" "${MG_M03_TENANT_VXLAN}" \
        "${MG_M03_TENANT_BR}"
    fi
    mgc_m03_remove_tenant_vrf
  fi
  if mgc_m03_physical_resource_present; then
    die 'resíduo físico M03 permanece; marker será mantido para recuperação'
  fi
  if mgc_m03_marker_present; then
    token="$(mgc_m03_owner_token || true)"
    [[ -n "${token}" ]] || die 'marker M03 inválido; não removendo marker'
    mgc_m03_remove_marker "${token}" \
      || die 'remoção do marker M03 falhou'
  fi
  mgc_assert_m03_absent
}

mgc_m03_phase() {
  local phase="$1" verify_phase="${2:-m03-verify}" script evidence
  [[ "${MGC_M03_MODE}" == 1 ]] \
    || die 'fase M03 solicitada sem --m03 explícito'
  case "${phase}" in
    up|verify|down) ;;
    *) die "fase M03 inválida: ${phase}" ;;
  esac
  if [[ "${phase}" == down ]]; then
    mgc_m03_cleanup_owned
    return 0
  fi
  script="${MGC_M03_SCRIPT:-${MGC_FIXTURE_DIR}/m03.sh}"
  [[ -f "${script}" ]] || die "entrypoint M03 ausente: ${script}"
  evidence="${EVIDENCE_DIR:-${M03_EVIDENCE_DIR:-}}"
  if [[ -z "${evidence}" ]]; then
    evidence="$(evidence_dir "${LAB_NAME}")/m03"
  fi
  if [[ "${DRY_RUN}" != "1" ]]; then
    if [[ -e "${evidence}" ]]; then
      [[ -d "${evidence}" && -O "${evidence}" && ! -g "${evidence}" ]] \
        || die "diretório de evidência M03 não é root-only: ${evidence}"
      chmod 700 "${evidence}"
      [[ "$(stat -c '%a' "${evidence}" 2>/dev/null || true)" == 700 ]] \
        || die "não foi possível proteger diretório de evidência M03: ${evidence}"
    else
      mkdir -p "${evidence}"
      chmod 700 "${evidence}"
    fi
  fi
  M03_EVIDENCE_DIR="${evidence}" \
    M03_PREFLIGHT_RECEIPT="${M03_PREFLIGHT_RECEIPT:-}" \
    M03_RUN_TOKEN="${M03_RUN_TOKEN:-}" \
    M03_K01_KUBECONFIG="${M03_K01_KUBECONFIG:-}" \
    M03_P003_KUBECONFIG="${M03_P003_KUBECONFIG:-}" \
    M03_LOCK_FILE="${MG_M03_LOCK_FILE}" \
    M03_VERIFY_PHASE="${verify_phase}" \
    MGC_M03_MODE=1 MGC_M03_PHASE_CHILD=1 \
    bash "${script}" "--phase-${phase}" \
    || die "fase M03 ${phase} falhou"
}

mgc_source_state() {
  local path="$1" ref="$2" label="$3" got expected
  if [[ ! -d "${path}/.git" ]]; then
    log "  fonte ${label}: ausente (up fará clone ${ref})"
    return 0
  fi
  got="$(git -C "${path}" rev-parse HEAD 2>/dev/null || true)"
  if [[ "${label}" == "OVN" ]]; then
    [[ "${got}" == "${OVN_COMMIT}" ]] \
      || die "fonte ${label} divergente: esperado ${OVN_COMMIT}, obtido ${got}"
  elif [[ "${label}" == "OVS" ]]; then
    expected="$(mgc_expected_ovs_commit || true)"
    if [[ -n "${expected}" ]]; then
      [[ "${got}" == "${expected}" ]] \
        || die "fonte ${label} divergente do gitlink OVN: esperado ${expected}, obtido ${got}"
    else
      git -C "${path}" rev-parse "${ref}^{commit}" >/dev/null 2>&1 \
        || die "fonte ${label} não contém a referência ${ref}"
    fi
  elif [[ "${label}" == "ovn-fake-multinode" ]]; then
    [[ "${got}" == "${FAKE_MN_COMMIT_PREFIX}"* ]] \
      || die "fonte ${label} divergente: esperado ${FAKE_MN_COMMIT_PREFIX}*, obtido ${got}"
  elif ! git -C "${path}" rev-parse "${ref}^{commit}" >/dev/null 2>&1; then
    die "fonte ${label} não contém a referência ${ref}"
  fi
  log "  fonte ${label}: ${got}"
}

# ---------------------------------------------------------------------------
# preflight: somente leituras e diagnósticos
# ---------------------------------------------------------------------------
lab_preflight() {
  local mem_kib cpu disk_kib mem_gib disk_gib image_count name fixture
  local vrf_package candidate

  log "preflight ${LAB_NAME}"
  require_cmd docker git python3 awk df nproc ip uname modinfo modprobe apt-cache

  mem_kib="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
  cpu="$(nproc)"
  disk_kib="$(df -Pk / | awk 'NR == 2 {print $4}')"
  mem_gib="$(awk -v kib="${mem_kib}" 'BEGIN {printf "%.2f", kib / 1024 / 1024}')"
  disk_gib="$(awk -v kib="${disk_kib}" 'BEGIN {printf "%.2f", kib / 1024 / 1024}')"
  log "  MemAvailable=${mem_gib}GiB CPU=${cpu} disco_avail=${disk_gib}GiB"
  if [[ "${mem_kib}" -lt 4194304 ]]; then
    [[ "${DRY_RUN}" == "1" ]] \
      || die "MemAvailable abaixo do mínimo de 4 GiB para o perfil mgc"
    log "  DRY: MemAvailable abaixo do piso; preflight não bloqueia dry-run"
  fi
  if [[ "${cpu}" -lt 4 ]]; then
    [[ "${DRY_RUN}" == "1" ]] \
      || die "CPU insuficiente: o perfil mgc exige >=4 vCPU"
    log "  DRY: CPU abaixo do piso; preflight não bloqueia dry-run"
  fi
  if [[ "${disk_kib}" -lt 10485760 ]]; then
    [[ "${DRY_RUN}" == "1" ]] \
      || die "disco insuficiente: o perfil mgc exige >=10 GiB livres"
    log "  DRY: disco abaixo do piso; preflight não bloqueia dry-run"
  fi

  if command -v ovs-vsctl >/dev/null 2>&1; then
    log "  OVS no host: presente"
  else
    log "  OVS no host: ausente; up instalará openvswitch-switch"
  fi
  [[ -e /dev/net/tun ]] || die "/dev/net/tun ausente"
  log "  /dev/net/tun: presente"

  if [[ -d /sys/module/vrf ]]; then
    log "  VRF do kernel: módulo carregado"
  elif modinfo vrf >/dev/null 2>&1; then
    log "  VRF do kernel: módulo disponível; up fará modprobe"
  else
    vrf_package="$(mgc_vrf_package)"
    candidate="$(apt-cache policy "${vrf_package}" | awk '$1 == "Candidate:" {print $2; exit}')"
    [[ -n "${candidate}" && "${candidate}" != "(none)" ]] \
      || die "módulo VRF indisponível e pacote ${vrf_package} sem candidato apt"
    log "  VRF do kernel: ausente; up instalará ${vrf_package} (${candidate})"
  fi

  mgc_source_state "${MGC_OVN_SRC}" "${OVN_TAG}" "OVN"
  mgc_source_state "${MGC_OVS_SRC}" "${OVS_TAG}" "OVS"
  mgc_source_state "${MGC_FAKE_MN}" "${FAKE_MN_TAG}" "ovn-fake-multinode"

  for fixture in nb-topology.sh frr-gw1.conf frr-gw2.conf frr-client.conf; do
    [[ -f "$(mgc_fixture_file "${fixture}")" ]] \
      || die "fixture ausente: $(mgc_fixture_file "${fixture}")"
  done

  if mgc_image_exists "${FRR_IMAGE}"; then
    log "  imagem FRR ${FRR_IMAGE}: presente"
  else
    log "  imagem FRR ${FRR_IMAGE}: ausente; up fará pull"
  fi
  image_count="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | awk '$0 == "ovn/cinc:latest" || $0 == "ovn/ovn-multi-node:latest" {count++} END {print count + 0}')"
  log "  imagens OVN locais: ${image_count}/2"

  for name in "${MG_CENTRAL}" "${MG_GATEWAY_1}" "${MG_GATEWAY_2}" \
    "${MG_CHASSIS_1}" "${MG_CHASSIS_2}" "${MG_CLIENT_NAME}"; do
    if [[ "$(mgc_count_named "${name}")" -gt 0 ]]; then
      log "  conflito/estado existente: container ${name} (up é idempotente)"
    fi
  done
  log "preflight ${LAB_NAME} OK"
}

mgc_require_mem_for_cluster() {
  local mem_kib
  mem_kib="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
  if [[ "${mem_kib}" -lt 4194304 ]]; then
    [[ "${DRY_RUN}" == "1" ]] \
      || die "MemAvailable caiu abaixo de 4 GiB antes do start do cluster OVN"
    log "  DRY: MemAvailable abaixo do piso antes do cluster; seguindo sem mutação"
  fi
}

mgc_ensure_vrf_kernel() {
  local vrf_package apt_plan line package_name found=0
  if [[ -d /sys/module/vrf ]]; then
    log "  módulo VRF já carregado no host"
    return 0
  fi
  if ! modinfo vrf >/dev/null 2>&1; then
    vrf_package="$(mgc_vrf_package)"
    apt_plan="$(env LC_ALL=C apt-get -s install --no-install-recommends \
      --no-remove "${vrf_package}")" \
      || die "simulação apt falhou para ${vrf_package}"
    grep -Eq '^0 upgraded, [0-9]+ newly installed, 0 to remove' <<<"${apt_plan}" \
      || die "simulação apt propôs upgrade ou remoção"
    while IFS= read -r line; do
      [[ "${line}" == Inst\ * ]] || continue
      package_name="${line#Inst }"
      package_name="${package_name%% *}"
      case "${package_name}" in
        "${vrf_package}") found=1 ;;
        wireless-regdb) ;;
        *) die "simulação apt propôs pacote fora do escopo: ${package_name}" ;;
      esac
    done <<<"${apt_plan}"
    [[ "${found}" == "1" ]] \
      || die "simulação apt não instalará ${vrf_package}"
    log "  simulação apt validada: ${vrf_package} e wireless-regdb, sem upgrade/remoção"
    run env DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get install -y \
      --no-remove --no-install-recommends "${vrf_package}"
  fi
  run modprobe vrf
  if [[ "${DRY_RUN}" != "1" ]]; then
    [[ -d /sys/module/vrf ]] || die "modprobe vrf terminou sem carregar o módulo"
  fi
}

# ---------------------------------------------------------------------------
# helpers de mutação
# ---------------------------------------------------------------------------
mgc_ensure_sources() {
  local pinned_ovs got
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: mkdir -p ${MGC_SRC}"
    echo "DRY: git clone --depth 1 --branch ${OVN_TAG} https://github.com/ovn-org/ovn.git ${MGC_OVN_SRC}"
    pinned_ovs="$(mgc_expected_ovs_commit || true)"
    if [[ -n "${pinned_ovs}" ]]; then
      echo "DRY: git clone --no-checkout https://github.com/openvswitch/ovs.git ${MGC_OVS_SRC}"
      echo "DRY: git -C ${MGC_OVS_SRC} fetch --depth 1 origin ${pinned_ovs} && git -C ${MGC_OVS_SRC} checkout --detach ${pinned_ovs}"
    else
      echo "DRY: git clone --depth 1 --branch ${OVS_TAG} https://github.com/openvswitch/ovs.git ${MGC_OVS_SRC}"
    fi
    echo "DRY: git clone --depth 1 --branch ${FAKE_MN_TAG} https://github.com/ovn-org/ovn-fake-multinode.git ${MGC_FAKE_MN}"
    return 0
  fi

  run mkdir -p "${MGC_SRC}"
  if [[ ! -d "${MGC_OVN_SRC}/.git" ]]; then
    [[ ! -e "${MGC_OVN_SRC}" ]] || die "caminho OVN existe e não é um checkout git: ${MGC_OVN_SRC}"
    run git clone --depth 1 --branch "${OVN_TAG}" \
      https://github.com/ovn-org/ovn.git "${MGC_OVN_SRC}"
  fi
  if [[ ! -d "${MGC_OVS_SRC}/.git" ]]; then
    [[ ! -e "${MGC_OVS_SRC}" ]] || die "caminho OVS existe e não é um checkout git: ${MGC_OVS_SRC}"
    pinned_ovs="$(mgc_expected_ovs_commit || true)"
    if [[ -n "${pinned_ovs}" ]]; then
      run git clone --no-checkout https://github.com/openvswitch/ovs.git "${MGC_OVS_SRC}"
    else
      run git clone --depth 1 --branch "${OVS_TAG}" \
        https://github.com/openvswitch/ovs.git "${MGC_OVS_SRC}"
    fi
  fi
  if [[ ! -d "${MGC_FAKE_MN}/.git" ]]; then
    [[ ! -e "${MGC_FAKE_MN}" ]] \
      || die "caminho fake-multinode existe e não é um checkout git: ${MGC_FAKE_MN}"
    run git clone --depth 1 --branch "${FAKE_MN_TAG}" \
      https://github.com/ovn-org/ovn-fake-multinode.git "${MGC_FAKE_MN}"
  fi

  got="$(git -C "${MGC_OVN_SRC}" rev-parse HEAD)"
  [[ "${got}" == "${OVN_COMMIT}" ]] \
    || die "commit OVN divergente: esperado ${OVN_COMMIT}, obtido ${got}"
  pinned_ovs="$(mgc_expected_ovs_commit || true)"
  if [[ -n "${pinned_ovs}" ]]; then
    got="$(git -C "${MGC_OVS_SRC}" rev-parse HEAD)"
    if [[ "${got}" != "${pinned_ovs}" ]]; then
      run git -C "${MGC_OVS_SRC}" fetch --depth 1 origin "${pinned_ovs}"
      run git -C "${MGC_OVS_SRC}" checkout --detach "${pinned_ovs}"
    fi
  else
    git -C "${MGC_OVS_SRC}" rev-parse "${OVS_TAG}^{commit}" >/dev/null 2>&1 \
      || die "checkout OVS não contém a referência ${OVS_TAG}"
  fi
  got="$(git -C "${MGC_FAKE_MN}" rev-parse HEAD)"
  [[ "${got}" == "${FAKE_MN_COMMIT_PREFIX}"* ]] \
    || die "commit fake-multinode divergente: esperado ${FAKE_MN_COMMIT_PREFIX}*, obtido ${got}"
}

mgc_ensure_ovs_underlay() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: garantir openvswitch-switch e o serviço OVS no host"
    return 0
  fi
  if command -v ovs-vsctl >/dev/null 2>&1; then
    run bash -c '
      if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now openvswitch-switch
      elif command -v service >/dev/null 2>&1; then
        service openvswitch-switch start
      else
        /usr/share/openvswitch/scripts/ovs-ctl start
      fi
    '
    return 0
  fi
  run bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq openvswitch-switch
    if command -v systemctl >/dev/null 2>&1; then
      systemctl enable --now openvswitch-switch
    else
      service openvswitch-switch start
    fi
  '
}

mgc_clean_build_stages() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: rm -rf ${MGC_FAKE_MN}/ovn ${MGC_FAKE_MN}/ovs (somente stages gerados pelo build)"
  else
    run rm -rf "${MGC_FAKE_MN}/ovn" "${MGC_FAKE_MN}/ovs"
  fi
}

mgc_build_ovn_images() {
  local have
  have="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | awk '$0 == "ovn/cinc:latest" || $0 == "ovn/ovn-multi-node:latest" {count++} END {print count + 0}')"
  if [[ "${have}" -ge 2 ]] && mgc_images_provenance_matches; then
    log "  imagens OVN reutilizadas: IDs vinculados às fontes fixadas"
    return 0
  fi
  if [[ "${have}" -ge 2 ]]; then
    log "  imagens OVN existentes sem provenance confiável; rebuild obrigatório"
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    mgc_clean_build_stages
    echo "DRY: (cd ${MGC_FAKE_MN} && OVN_SRC_PATH=${MGC_OVN_SRC} OVS_SRC_PATH=${MGC_OVS_SRC} RUNC_CMD=${RUNC_CMD} nohup ./ovn_cluster.sh build; registrar IDs das imagens e commits das fontes)"
    return 0
  fi

  local ev build_log pid waited=0 timeout=2400
  mgc_clean_build_stages
  ev="$(evidence_dir "${LAB_NAME}")"
  build_log="${ev}/ovn-build.log"
  log "  build OVN via nohup (log: ${build_log})"
  run nohup env OVN_SRC_PATH="${MGC_OVN_SRC}" OVS_SRC_PATH="${MGC_OVS_SRC}" \
    RUNC_CMD="${RUNC_CMD}" bash -c "cd '${MGC_FAKE_MN}' && ./ovn_cluster.sh build" \
    >"${build_log}" 2>&1 &
  pid=$!
  while kill -0 "${pid}" 2>/dev/null; do
    sleep 10
    waited=$((waited + 10))
    if [[ "${waited}" -ge "${timeout}" ]]; then
      run kill "${pid}"
      die "build OVN não terminou em ${timeout}s (log: ${build_log})"
    fi
  done
  wait "${pid}" || die "build OVN falhou (log: ${build_log})"
  mgc_record_image_provenance
}

mgc_start_ovn_cluster() {
  local cluster_running ev start_log status_file upstream_rc pid waited=0 timeout=900
  mgc_prepare_cluster_ownership
  cluster_running="$(mgc_cluster_count running)"
  if [[ "${cluster_running}" -eq 5 ]]; then
    log "  cluster OVN já está completo; pulando start"
    return 0
  fi
  mgc_create_owned_bridges
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: (cd ${MGC_FAKE_MN} && RUNC_CMD=docker CENTRAL_COUNT=1 CHASSIS_COUNT=2 GW_COUNT=2 CREATE_FAKE_VMS=no nohup ./ovn_cluster.sh start)"
    return 0
  fi

  ev="$(evidence_dir "${LAB_NAME}")"
  start_log="${ev}/ovn-start.log"
  status_file="${ev}/ovn-start.rc"
  log "  start OVN via nohup (log: ${start_log})"
  run nohup env RUNC_CMD="${RUNC_CMD}" CENTRAL_COUNT=1 CHASSIS_COUNT=2 \
    GW_COUNT=2 CREATE_FAKE_VMS=no MGC_STATUS_FILE="${status_file}" bash -c \
    "cd '${MGC_FAKE_MN}'; ./ovn_cluster.sh start; rc=\$?; printf '%s\\n' \"\$rc\" >\"\$MGC_STATUS_FILE\"; exit 0" \
    >"${start_log}" 2>&1 &
  pid=$!
  while kill -0 "${pid}" 2>/dev/null; do
    mgc_record_discovered_cluster_ids || true
    sleep 5
    waited=$((waited + 5))
    if [[ "${waited}" -ge "${timeout}" ]]; then
      run kill "${pid}"
      die "start OVN não terminou em ${timeout}s (log: ${start_log})"
    fi
  done
  mgc_record_discovered_cluster_ids || true
  wait "${pid}" || die "wrapper do start OVN falhou (log: ${start_log})"
  upstream_rc="$(cat "${status_file}" 2>/dev/null || true)"
  if [[ "${upstream_rc}" == "0" ]]; then
    mgc_record_cluster_ids owned
    [[ "$(mgc_cluster_count running)" -eq 5 ]] \
      || die "start retornou OK, mas o cluster OVN não ficou completo"
    return 0
  fi
  mgc_record_cluster_ids partial
  die "ovn_cluster.sh start falhou (rc=${upstream_rc:-desconhecido}; log: ${start_log})"
}

mgc_apply_nb_fixture() {
  run docker cp "${MG_NB_FIXTURE}" "${MG_CENTRAL}:/tmp/mgc-nb-topology.sh"
  run docker exec "${MG_CENTRAL}" chmod 0755 /tmp/mgc-nb-topology.sh
  run docker exec "${MG_CENTRAL}" /tmp/mgc-nb-topology.sh
}

mgc_apply_evpn_ids() {
  local node ip
  local -a nodes=("${MG_GATEWAY_1}" "${MG_GATEWAY_2}" "${MG_CHASSIS_1}" "${MG_CHASSIS_2}")
  for node in "${nodes[@]}"; do
    case "${node}" in
      "${MG_GATEWAY_1}") ip="${MG_GATEWAY_1_UNDERLAY}" ;;
      "${MG_GATEWAY_2}") ip="${MG_GATEWAY_2_UNDERLAY}" ;;
      "${MG_CHASSIS_1}") ip="${MG_CHASSIS_1_UNDERLAY}" ;;
      "${MG_CHASSIS_2}") ip="${MG_CHASSIS_2_UNDERLAY}" ;;
    esac
    run docker exec "${node}" ovs-vsctl set Open_vSwitch . \
      "external_ids:ovn-evpn-local-ip=${MG_TENANT_VNI}-${ip}" \
      external_ids:ovn-evpn-vxlan-ports=4789
  done
}

mgc_reconcile_gateway_port() {
  local gateway="$1" bridge="$2" interface="$3" address="$4"
  local port actual_bridge
  local -a add_args=()
  port="$(mgc_ovs_port "${gateway}" "${interface}" || true)"
  if [[ -n "${port}" ]]; then
    actual_bridge="$(ovs-vsctl port-to-br "${port}" 2>/dev/null || true)"
    [[ "${actual_bridge}" == "${bridge}" ]] \
      || die "porta ${port} de ${gateway}:${interface} não está em ${bridge}"
  fi
  if [[ -n "${port}" ]] \
    && ! docker exec "${gateway}" ip link show "${interface}" >/dev/null 2>&1; then
    run ovs-vsctl --if-exists del-port "${bridge}" "${port}"
    if ip link show "${port}" >/dev/null 2>&1; then
      run ip link del "${port}"
    fi
    port=""
  fi
  if [[ -z "${port}" ]]; then
    if docker exec "${gateway}" ip link show "${interface}" >/dev/null 2>&1; then
      die "interface ${interface} sem porta OVS própria em ${gateway}"
    fi
    [[ -z "${address}" ]] || add_args=("--ipaddress=${address}")
    run env RUNC_CMD="${RUNC_CMD}" "${MGC_FAKE_MN}/ovs-runc" add-port \
      "${bridge}" "${interface}" "${gateway}" "${add_args[@]}"
    if [[ "${DRY_RUN}" == "1" ]]; then
      return 0
    fi
    port="$(mgc_ovs_port "${gateway}" "${interface}" || true)"
  fi
  [[ -n "${port}" \
    && "$(ovs-vsctl port-to-br "${port}" 2>/dev/null || true)" == "${bridge}" ]] \
    || die "porta OVS ${gateway}:${interface} não foi reconciliada em ${bridge}"
  docker exec "${gateway}" ip link show "${interface}" >/dev/null 2>&1 \
    || die "interface ${interface} ausente em ${gateway} após reconciliação"
  if [[ -n "${address}" ]]; then
    docker exec "${gateway}" ip -4 -o addr show dev "${interface}" \
      | grep -Fq "${address}" \
      || die "endereço de ${gateway}:${interface} difere de ${address}"
  fi
}

mgc_reconcile_gateway_runtime() {
  local gateway underlay attempt controller_status cert
  if [[ "${DRY_RUN}" == "1" \
    && "$(mgc_cluster_count running)" -ne 5 ]]; then
    echo 'DRY: após start do cluster próprio, reconciliar OVS, eth1/eth2 e ovn-controller dos gateways'
    return 0
  fi
  mgc_assert_cluster_ownership
  mgc_assert_bridges_owned
  for gateway in "${MG_GATEWAY_1}" "${MG_GATEWAY_2}"; do
    [[ "$(mgc_count_named "${gateway}" running)" -eq 1 ]] \
      || die "gateway ${gateway} não está rodando para reconciliar OVS/OVN"
    case "${gateway}" in
      "${MG_GATEWAY_1}") underlay="${MG_GATEWAY_1_UNDERLAY}" ;;
      "${MG_GATEWAY_2}") underlay="${MG_GATEWAY_2_UNDERLAY}" ;;
    esac
    if ! docker exec "${gateway}" ovs-vsctl show >/dev/null 2>&1; then
      run docker exec "${gateway}" /usr/share/openvswitch/scripts/ovs-ctl \
        start "--system-id=${gateway}"
      if [[ "${DRY_RUN}" != "1" ]]; then
        for ((attempt = 1; attempt <= 30; attempt++)); do
          docker exec "${gateway}" ovs-vsctl show >/dev/null 2>&1 && break
          sleep 1
        done
        docker exec "${gateway}" ovs-vsctl show >/dev/null 2>&1 \
          || die "OVS não ficou pronto em ${gateway} após ovs-ctl start"
      fi
    fi
    mgc_reconcile_gateway_port "${gateway}" br-ovn eth1 "${underlay}/16"
    mgc_reconcile_gateway_port "${gateway}" br-ovn-ext eth2 ""
    controller_status="$(docker exec "${gateway}" ovn-appctl \
      -t ovn-controller connection-status 2>/dev/null || true)"
    if [[ "${controller_status}" != connected ]]; then
      for cert in /opt/ovn/ovn-privkey.pem /opt/ovn/ovn-cert.pem \
        /opt/ovn/pki/switchca/cacert.pem; do
        docker exec "${gateway}" test -r "${cert}" \
          || die "certificado TLS ausente para ovn-controller em ${gateway}: ${cert}"
      done
      if docker exec "${gateway}" ovn-appctl -t ovn-controller version \
        >/dev/null 2>&1; then
        run docker exec "${gateway}" /usr/share/ovn/scripts/ovn-ctl stop_controller
      fi
      run docker exec "${gateway}" /usr/share/ovn/scripts/ovn-ctl start_controller \
        --ovn-controller-ssl-key=/opt/ovn/ovn-privkey.pem \
        --ovn-controller-ssl-cert=/opt/ovn/ovn-cert.pem \
        --ovn-controller-ssl-ca-cert=/opt/ovn/pki/switchca/cacert.pem
      if [[ "${DRY_RUN}" != "1" ]]; then
        for ((attempt = 1; attempt <= 60; attempt++)); do
          controller_status="$(docker exec "${gateway}" ovn-appctl \
            -t ovn-controller connection-status 2>/dev/null || true)"
          [[ "${controller_status}" == connected ]] && break
          sleep 1
        done
        [[ "${controller_status}" == connected ]] \
          || die "ovn-controller não conectou ao SB em ${gateway} após start_controller"
      fi
    fi
  done
}

mgc_wait_vrf() {
  local gateway="$1" vrf="$2" attempt
  for ((attempt = 1; attempt <= 60; attempt++)); do
    if docker exec "${gateway}" ip link show "${vrf}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  die "VRF ${vrf} não apareceu em ${gateway} após dynamic routing"
}

mgc_configure_mirror() {
  local gateway vrf_id gateway_ip lsp lrp_mac current_mac client_if
  gateway="$1"
  vrf_id="$2"
  gateway_ip="$3"
  lsp="bgpvrf${vrf_id}"
  local ovs_if="${lsp}-ovs" vrf_if="${lsp}"
  case "${vrf_id}" in
    100) client_if=eth1 ;;
    200) client_if=eth2 ;;
    *) die "VRF sem perna de cliente: ${vrf_id}" ;;
  esac
  if [[ "${DRY_RUN}" == "1" ]]; then
    lrp_mac="$(docker exec "${MG_CENTRAL}" ovn-nbctl get logical_router_port \
      "lrp-mgc-${vrf_id}-external" mac 2>/dev/null | tr -d '"' || true)"
    if [[ -n "${lrp_mac}" ]]; then
      [[ "${lrp_mac}" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] \
        || die "MAC da LRP externa inválido para ovnvrf${vrf_id}: ${lrp_mac}"
    else
      lrp_mac="MAC da LRP após aplicar a fixture NB"
    fi
    echo "DRY: aguardar ovnvrf${vrf_id} em ${gateway}, criar veth ${ovs_if}<->${vrf_if} e atribuir ${gateway_ip}/30"
    echo "DRY: ler/validar MAC de lrp-mgc-${vrf_id}-external; garantir MAC ${lrp_mac} em ${gateway}:${vrf_if}"
    echo "DRY: se MAC mudar, invalidar vizinho ${gateway_ip} em ${MG_CLIENT_NAME}:${client_if} (se cliente próprio existir)"
    return 0
  fi
  mgc_wait_vrf "${gateway}" "ovnvrf${vrf_id}"
  lrp_mac="$(docker exec "${MG_CENTRAL}" ovn-nbctl get logical_router_port \
    "lrp-mgc-${vrf_id}-external" mac | tr -d '"')"
  [[ "${lrp_mac}" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] \
    || die "MAC da LRP externa inválido para ovnvrf${vrf_id}: ${lrp_mac}"
  if ! docker exec "${gateway}" ip link show "${vrf_if}" >/dev/null 2>&1; then
    run docker exec "${gateway}" bash -c \
      "set -euo pipefail
       ip link add '${ovs_if}' type veth peer name '${vrf_if}'
       ovs-vsctl --may-exist add-port br-int '${ovs_if}' -- set Interface '${ovs_if}' external_ids:iface-id='${lsp}'
       ip link set '${ovs_if}' up
       ip link set '${vrf_if}' up
       ip link set '${vrf_if}' master 'ovnvrf${vrf_id}'
       ip addr replace '${gateway_ip}/30' dev '${vrf_if}'"
  elif ! docker exec "${gateway}" ip link show "${vrf_if}" \
    | grep -q "master ovnvrf${vrf_id}"; then
    run docker exec "${gateway}" ip link set "${vrf_if}" master "ovnvrf${vrf_id}"
  fi
  current_mac="$(docker exec "${gateway}" cat "/sys/class/net/${vrf_if}/address")"
  if [[ "${current_mac}" != "${lrp_mac}" ]]; then
    run docker exec "${gateway}" ip link set dev "${vrf_if}" address "${lrp_mac}"
    if [[ "$(mgc_count_named "${MG_CLIENT_NAME}" running)" -gt 0 ]]; then
      mgc_assert_client_ownership "${MG_CLIENT_NAME}"
      if docker exec "${MG_CLIENT_NAME}" ip link show "${client_if}" >/dev/null 2>&1; then
        run docker exec "${MG_CLIENT_NAME}" ip neigh flush to "${gateway_ip}" dev "${client_if}"
      fi
    fi
  fi
  if ! docker exec "${gateway}" ip addr show dev "${vrf_if}" \
    | grep -q "${gateway_ip}/30"; then
    run docker exec "${gateway}" ip addr replace "${gateway_ip}/30" dev "${vrf_if}"
  fi
  if [[ -z "$(docker exec "${gateway}" ovs-vsctl port-to-br "${ovs_if}" 2>/dev/null || true)" ]]; then
    run docker exec "${gateway}" ovs-vsctl --may-exist add-port br-int "${ovs_if}"
  elif [[ "$(docker exec "${gateway}" ovs-vsctl port-to-br "${ovs_if}" 2>/dev/null || true)" != "br-int" ]]; then
    die "porta ${ovs_if} do espelho não está em br-int"
  fi
  run docker exec "${gateway}" ovs-vsctl set Interface "${ovs_if}" \
    "external_ids:iface-id=${lsp}"
  run docker exec "${gateway}" ip link set dev "${ovs_if}" up
  run docker exec "${gateway}" ip link set dev "${vrf_if}" up
}

mgc_apply_gateway_frr() {
  local gateway="$1" fixture="$2"
  run docker cp "${fixture}" "${gateway}:/etc/frr/frr.conf"
  run docker exec "${gateway}" bash -c '
    set -euo pipefail
    frr_dir=""
    for candidate in /usr/libexec/frr /usr/lib/frr; do
      if [ -x "${candidate}/zebra" ] && [ -x "${candidate}/bgpd" ] && [ -x "${candidate}/bfdd" ]; then
        frr_dir="${candidate}"
        break
      fi
    done
    [ -n "${frr_dir}" ] || { echo "FRR daemons ausentes em /usr/libexec/frr e /usr/lib/frr" >&2; exit 1; }
    if ! pidof zebra >/dev/null 2>&1; then
      "${frr_dir}/zebra" -d -f /etc/frr/frr.conf
    fi
    if ! pidof bgpd >/dev/null 2>&1; then
      "${frr_dir}/bgpd" -d -f /etc/frr/frr.conf
    fi
    if ! pidof bfdd >/dev/null 2>&1; then
      "${frr_dir}/bfdd" -d -f /etc/frr/frr.conf
    fi
    attempt=1
    while [ "${attempt}" -le 30 ]; do
      if vtysh -c "show version" >/dev/null 2>&1 && vtysh -b >/dev/null 2>&1; then
        exit 0
      fi
      attempt=$((attempt + 1))
      sleep 1
    done
    echo "vtysh sockets não convergiram no gateway" >&2
    exit 1
  '
}

mgc_client_port() {
  [[ "$#" -eq 5 ]] || die "mgc_client_port exige client, interface, endereço, VLAN e MTU"
  local client="$1" interface="$2" address="$3" vlan="$4" mtu="$5"
  local port port_bridge current_mtu
  if [[ "$(mgc_count_named "${client}")" -gt 0 ]]; then
    mgc_assert_client_ownership "${client}"
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: ovs-runc add-port br-ovn-ext ${interface} ${client} --ipaddress=${address} --mtu=${mtu}"
    echo "DRY: ovs-runc set-vlan br-ovn-ext ${interface} ${client} ${vlan}"
    return 0
  fi
  port="$(mgc_ovs_port "${client}" "${interface}" || true)"
  if [[ -z "${port}" ]]; then
    if docker exec "${client}" ip link show "${interface}" >/dev/null 2>&1; then
      run docker exec "${client}" ip link del "${interface}"
    fi
    run env RUNC_CMD="${RUNC_CMD}" "${MGC_FAKE_MN}/ovs-runc" add-port \
      br-ovn-ext "${interface}" "${client}" \
      "--ipaddress=${address}" "--mtu=${mtu}"
  fi
  port="$(mgc_ovs_port "${client}" "${interface}" || true)"
  if [[ -n "${port}" ]] && ! docker exec "${client}" ip link show "${interface}" >/dev/null 2>&1; then
    run env RUNC_CMD="${RUNC_CMD}" "${MGC_FAKE_MN}/ovs-runc" \
      del-port br-ovn-ext "${interface}" "${client}"
    port=""
  fi
  if [[ -z "${port}" ]]; then
    run env RUNC_CMD="${RUNC_CMD}" "${MGC_FAKE_MN}/ovs-runc" add-port \
      br-ovn-ext "${interface}" "${client}" \
      "--ipaddress=${address}" "--mtu=${mtu}"
    port="$(mgc_ovs_port "${client}" "${interface}" || true)"
  fi
  [[ -n "${port}" ]] || die "porta OVS do cliente não apareceu: ${interface}"
  port_bridge="$(ovs-vsctl port-to-br "${port}" 2>/dev/null || true)"
  [[ "${port_bridge}" == "br-ovn-ext" ]] \
    || die "porta ${port} do cliente não está em br-ovn-ext"
  if [[ "$(ovs-vsctl get Port "${port}" tag 2>/dev/null || true)" != "${vlan}" ]]; then
    run env RUNC_CMD="${RUNC_CMD}" "${MGC_FAKE_MN}/ovs-runc" set-vlan \
      br-ovn-ext "${interface}" "${client}" "${vlan}"
  fi
  if ! docker exec "${client}" ip -4 -o addr show dev "${interface}" \
    | grep -q "${address}[[:space:]]"; then
    run docker exec "${client}" ip -4 addr flush dev "${interface}" scope global
    run docker exec "${client}" ip addr add "${address}" dev "${interface}"
  fi
  current_mtu="$(docker exec "${client}" cat "/sys/class/net/${interface}/mtu" 2>/dev/null || true)"
  if [[ "${current_mtu}" != "${mtu}" ]]; then
    run docker exec "${client}" ip link set dev "${interface}" mtu "${mtu}"
  fi
  run docker exec "${client}" ip link set dev "${interface}" up
}

mgc_start_client_instance() {
  [[ "$#" -ge 5 ]] || die "mgc_start_client_instance exige pelo menos uma perna"
  local client="$1" fixture="$2" asn="$3" mtu="$4"
  local client_exists token
  shift 4
  local spec interface address vlan extra
  [[ "${asn}" =~ ^[0-9]+$ && "${mtu}" =~ ^[0-9]+$ ]] \
    || die "AS e MTU inválidos para ${client}"
  [[ "${MG_CLIENT_LOOPBACK_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] \
    || die "loopback inválido para ${client}: ${MG_CLIENT_LOOPBACK_IP}"
  client_exists="$(mgc_count_named "${client}")"
  if [[ "${client_exists}" -eq 0 ]]; then
    token="$(state_get "${LAB_NAME}" owner_token 2>/dev/null || true)"
    if [[ "${DRY_RUN}" == "1" ]]; then
      token="${token:-DRY-MGC-OWNER}"
    else
      [[ -n "${token}" ]] || die "cliente ${client} sem token de ownership do perfil"
    fi
    run docker run -d --name "${client}" --network none --privileged \
      --label "labctl.mgc.owner=${token}" \
      --entrypoint /bin/sh "${FRR_IMAGE}" -c 'while :; do sleep 3600; done'
    if [[ "${DRY_RUN}" != "1" ]]; then
      mgc_record_client_ownership "${client}"
    fi
  else
    mgc_assert_client_ownership "${client}"
    if [[ "$(mgc_count_named "${client}" running)" -eq 0 ]]; then
      run docker start "${client}"
    fi
  fi

  log "  cliente ${client}: AS ${asn}, MTU ${mtu}"
  run docker cp "${fixture}" "${client}:/etc/frr/frr.conf"
  for spec in "$@"; do
    interface=""
    address=""
    vlan=""
    extra=""
    IFS='|' read -r interface address vlan extra <<<"${spec}"
    [[ -n "${interface}" && -n "${address}" && -n "${vlan}" && -z "${extra}" ]] \
      || die "perna inválida para ${client}; use interface|endereço|VLAN"
    mgc_client_port "${client}" "${interface}" "${address}" "${vlan}" "${mtu}"
  done
  run docker exec "${client}" ip addr replace "${MG_CLIENT_LOOPBACK_IP}" dev lo
  run docker exec "${client}" sh -c '
    set -eu
    frr_dir=""
    for candidate in /usr/libexec/frr /usr/lib/frr; do
      if [ -x "${candidate}/zebra" ] && [ -x "${candidate}/bgpd" ] \
        && [ -x "${candidate}/bfdd" ] && [ -x "${candidate}/staticd" ]; then
        frr_dir="${candidate}"
        break
      fi
    done
    [ -n "${frr_dir}" ] || { echo "FRR daemons ausentes no cliente" >&2; exit 1; }
    if ! pidof zebra >/dev/null 2>&1; then
      "${frr_dir}/zebra" -d -f /etc/frr/frr.conf
    fi
    if ! pidof bgpd >/dev/null 2>&1; then
      "${frr_dir}/bgpd" -d -f /etc/frr/frr.conf
    fi
    if ! pidof bfdd >/dev/null 2>&1; then
      "${frr_dir}/bfdd" -d -f /etc/frr/frr.conf
    fi
    if ! pidof staticd >/dev/null 2>&1; then
      "${frr_dir}/staticd" -d -f /etc/frr/frr.conf
    fi
    attempt=1
    while [ "${attempt}" -le 30 ]; do
      if vtysh -c "show version" >/dev/null 2>&1 && vtysh -b >/dev/null 2>&1; then
        exit 0
      fi
      attempt=$((attempt + 1))
      sleep 1
    done
    echo "vtysh sockets não convergiram no cliente" >&2
    exit 1
  '
}

mgc_ensure_frr_image() {
  if mgc_image_exists "${FRR_IMAGE}"; then
    return 0
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: docker pull ${FRR_IMAGE}"
  else
    run docker pull "${FRR_IMAGE}"
  fi
}

mgc_start_client() {
  mgc_start_client_instance "${MG_CLIENT_NAME}" "${MG_CLIENT_FRR}" \
    "${MG_CLIENT_AS}" "${MG_CLIENT_MTU}" \
    "eth1|${MG_CLI1_P2P}/30|${MG_GW_VLAN_1}" \
    "eth2|${MG_CLI2_P2P}/30|${MG_GW_VLAN_2}"
}

mgc_wait_client_neighbors() {
  local vrf_id gateway_ip client_if expected_mac actual_mac attempt
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: provocar ARP do cliente e confirmar MAC da LRP para ${MG_GW1_P2P} em eth1 e ${MG_GW2_P2P} em eth2"
    return 0
  fi
  for vrf_id in 100 200; do
    case "${vrf_id}" in
      100) gateway_ip="${MG_GW1_P2P}"; client_if=eth1 ;;
      200) gateway_ip="${MG_GW2_P2P}"; client_if=eth2 ;;
    esac
    expected_mac="$(docker exec "${MG_CENTRAL}" ovn-nbctl get logical_router_port \
      "lrp-mgc-${vrf_id}-external" mac | tr -d '"')"
    actual_mac=""
    for ((attempt = 1; attempt <= 20; attempt++)); do
      docker exec "${MG_CLIENT_NAME}" ping -I "${client_if}" -c 1 -W 1 \
        "${gateway_ip}" >/dev/null 2>&1 || true
      actual_mac="$(docker exec "${MG_CLIENT_NAME}" ip neigh show to \
        "${gateway_ip}" dev "${client_if}" \
        | awk '{for (i=1; i<NF; i++) if ($i=="lladdr") {print $(i+1); exit}}')"
      [[ "${actual_mac}" == "${expected_mac}" ]] && break
      sleep 1
    done
    [[ "${actual_mac}" == "${expected_mac}" ]] \
      || die "ARP ${gateway_ip} em ${client_if}: MAC esperado ${expected_mac}, obtido ${actual_mac:-ausente}"
  done
}

mgc_create_tenant_vm() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: criar netns ${MG_TENANT_VM_NS}, veth ${MG_TENANT_VM_PORT}<->${MG_TENANT_VM_IF} e LSP ${MG_TENANT_VM_LSP}"
    return 0
  fi
  run docker exec "${MG_CHASSIS_1}" bash -c \
    "set -euo pipefail
     if ! ip netns list | awk -v wanted='${MG_TENANT_VM_NS}' '\$1 == wanted {found=1} END {exit !found}'; then
       ip netns add '${MG_TENANT_VM_NS}'
     fi
     if ip netns exec '${MG_TENANT_VM_NS}' ip link show '${MG_TENANT_VM_IF}' >/dev/null 2>&1 \
       && ! ip link show '${MG_TENANT_VM_PORT}' >/dev/null 2>&1; then
       ip netns del '${MG_TENANT_VM_NS}'
       ip netns add '${MG_TENANT_VM_NS}'
     fi
     if ! ip netns exec '${MG_TENANT_VM_NS}' ip link show '${MG_TENANT_VM_IF}' >/dev/null 2>&1; then
       if ip link show '${MG_TENANT_VM_PORT}' >/dev/null 2>&1; then
         ip link del '${MG_TENANT_VM_PORT}'
       fi
       ip link add '${MG_TENANT_VM_PORT}' type veth peer name '${MG_TENANT_VM_IF}'
       ip link set '${MG_TENANT_VM_IF}' netns '${MG_TENANT_VM_NS}'
     fi
     ovs-vsctl --may-exist add-port br-int '${MG_TENANT_VM_PORT}' -- set Interface '${MG_TENANT_VM_PORT}' external_ids:iface-id='${MG_TENANT_VM_LSP}'
     ip link set dev '${MG_TENANT_VM_PORT}' mtu 1500
     ip link set '${MG_TENANT_VM_PORT}' up
     ip netns exec '${MG_TENANT_VM_NS}' ip link set lo up
     ip netns exec '${MG_TENANT_VM_NS}' ip link set dev '${MG_TENANT_VM_IF}' mtu 1500
     ip netns exec '${MG_TENANT_VM_NS}' ip link set dev '${MG_TENANT_VM_IF}' address '${MG_TENANT_VM_MAC}'
     ip netns exec '${MG_TENANT_VM_NS}' ip link set '${MG_TENANT_VM_IF}' up
     ip netns exec '${MG_TENANT_VM_NS}' ip -4 addr flush dev '${MG_TENANT_VM_IF}' scope global
     ip netns exec '${MG_TENANT_VM_NS}' ip addr add '${MG_TENANT_VM_IP}/24' dev '${MG_TENANT_VM_IF}'
     ip netns exec '${MG_TENANT_VM_NS}' ip route replace default via '${MG_TENANT_LRP_IP}' dev '${MG_TENANT_VM_IF}'"
}

mgc_apply_topology() {
  mgc_apply_nb_fixture
  mgc_reconcile_gateway_runtime
  mgc_apply_evpn_ids
  mgc_configure_mirror "${MG_GATEWAY_1}" "${MG_GW_VRF_1}" "${MG_GW1_P2P}"
  mgc_configure_mirror "${MG_GATEWAY_2}" "${MG_GW_VRF_2}" "${MG_GW2_P2P}"
  mgc_create_tenant_vm
  mgc_apply_gateway_frr "${MG_GATEWAY_1}" "${MG_GW1_FRR}"
  mgc_apply_gateway_frr "${MG_GATEWAY_2}" "${MG_GW2_FRR}"
  mgc_start_client
  mgc_wait_client_neighbors
}

# ---------------------------------------------------------------------------
# up
# ---------------------------------------------------------------------------
lab_up() {
  require_cmd docker git python3 flock readlink stat wc
  mgc_m03_lock_action
  mgc_x05_guard
  lab_preflight
  if [[ "${MGC_M03_MODE}" == 1 ]] && mgc_m03_marker_present; then
    mgc_assert_cluster_ownership
    mgc_assert_bridges_owned
    [[ "$(mgc_count_named "${MG_CLIENT_NAME}" running)" -eq 1 ]] \
      || die "cliente MGC ${MG_CLIENT_NAME} não está running; up M03 idempotente abortado"
    mgc_assert_client_ownership "${MG_CLIENT_NAME}"
    mgc_m03_require_cleanup_nodes
    mgc_m03_assert_active
    if [[ "${DRY_RUN}" == "1" ]]; then
      echo "DRY: M03 marker e ownership/recursos ativos validados; nenhum recurso recriado"
      return 0
    fi
    mgc_m03_phase verify m03-up-idempotent
    log "M03 já estava completo e foi verificado; nenhum recurso foi recriado"
    return 0
  fi
  mgc_assert_m03_absent
  if [[ "${MGC_M03_MODE}" == 1 ]]; then
    [[ -n "${M03_PREFLIGHT_RECEIPT:-}" \
      && -r "${M03_PREFLIGHT_RECEIPT}" ]] \
      || die '--m03 exige M03_PREFLIGHT_RECEIPT legível antes de mutar o lab'
  fi
  log "suporte VRF do kernel no host"
  mgc_ensure_vrf_kernel
  log "1/5 fontes OVN ${OVN_TAG} e fake-multinode ${FAKE_MN_TAG}"
  mgc_ensure_sources
  log "2/5 OVS do underlay no host"
  mgc_ensure_ovs_underlay
  log "3/5 imagens ovn/cinc e ovn/ovn-multi-node"
  mgc_build_ovn_images
  mgc_require_mem_for_cluster
  log "4/5 cluster OVN (central=1 gateways=2 chassis=2; fake VMs=no)"
  mgc_start_ovn_cluster
  log "5/5 topologia MGC, espelhos, FRR, cliente e EVPN"
  mgc_ensure_frr_image
  mgc_apply_topology
  if [[ "${MGC_M03_MODE}" == 1 ]]; then
    log "fase M03 up: peer EVPN, links, pathspace FRR e marker owned"
    mgc_m03_phase up m03-up
  fi
  state_set "${LAB_NAME}" up_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log "lab ${LAB_NAME} up concluído"
}

# ---------------------------------------------------------------------------
# verify: somente gates observáveis e coleta externa ao OVN
# ---------------------------------------------------------------------------
lab_verify() {
  local ev verify_file sessions ecmp mtu evpn remote_vtep ping_result
  local bgp_json route_rib onprem_rib client_source
  local bfd bfd_up bfd_gw1 bfd_gw2 bfd_up_gw1 bfd_up_gw2 tenant_vm_mac
  require_cmd flock readlink stat wc
  mgc_m03_lock_action
  mgc_x05_guard
  ev="$(evidence_dir "${LAB_NAME}")"
  verify_file="${ev}/verify.txt"
  if [[ "${MGC_M03_MODE}" == 1 ]]; then
    if [[ "${DRY_RUN}" == "1" ]]; then
      echo "DRY: verificar ownership/marker M03 e convergência Type5/RIB/FIB/VTEP/route-get"
    else
      mgc_m03_assert_active
    fi
  else
    mgc_assert_m03_absent
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: coletar sessões BGP e ECMP no RIB de ${MG_CLIENT_NAME}"
    echo "DRY: coletar gateway_mtu, configuração EVPN e ping ${MG_TENANT_VM_IP}"
    echo "DRY: gravar verify.txt em ${verify_file}"
    if [[ "${MGC_M03_MODE}" == 1 ]]; then
      mgc_m03_phase verify m03-verify
    fi
    return 0
  fi

  bgp_json="$(docker exec "${MG_CLIENT_NAME}" vtysh \
    -c 'show bgp ipv4 unicast summary established json' 2>/dev/null || true)"
  sessions="$(printf '%s\n' "${bgp_json}" | python3 -c '
import json
import sys

try:
    document = json.load(sys.stdin)
except (json.JSONDecodeError, TypeError):
    print("INVALID_JSON")
    raise SystemExit(0)

def peer_count(value):
    if isinstance(value, dict):
        return len(value)
    if isinstance(value, list):
        return len(value)
    return -1

def displayed_count(value):
    if isinstance(value, bool):
        return -1
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.isdigit():
        return int(value)
    return peer_count(value)

def find_summary(value):
    if isinstance(value, dict):
        if "displayedPeers" in value:
            displayed = displayed_count(value["displayedPeers"])
            available = peer_count(value.get("peers"))
            return displayed if displayed >= 0 and available >= displayed else -1
        for child in value.values():
            result = find_summary(child)
            if result is not None:
                return result
    elif isinstance(value, list):
        for child in value:
            result = find_summary(child)
            if result is not None:
                return result
    return None

result = find_summary(document)
print("INVALID_JSON" if result is None or result < 0 else result)
')"
  [[ "${sessions}" =~ ^[0-9]+$ ]] \
    || die "saída JSON de BGP inválida; coleta=${bgp_json}"
  [[ "${sessions}" -ge 2 ]] \
    || die "esperava >=2 sessões BGP Established no cliente, obtive ${sessions}"

  route_rib="$(docker exec "${MG_CLIENT_NAME}" vtysh \
    -c "show ip route ${MG_TENANT_CIDR}" 2>/dev/null || true)"
  [[ "${route_rib}" == *"Routing entry for ${MG_TENANT_CIDR}"* \
    && "${route_rib}" == *'Known via "bgp"'* ]] \
    || die "RIB do cliente sem rota BGP para ${MG_TENANT_CIDR}: ${route_rib}"
  ecmp="$(printf '%s\n' "${route_rib}" \
    | awk '/^[[:space:]]*\*[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+, via / {
        next_hop=$2
        sub(/,$/, "", next_hop)
        seen[next_hop]=1
      }
      END {for (next_hop in seen) count++; print count+0}')"
  [[ "${ecmp}" -ge 2 ]] \
    || die "esperava >=2 next-hops reais para ${MG_TENANT_CIDR}, obtive ${ecmp}"

  onprem_rib="$(docker exec "${MG_CLIENT_NAME}" vtysh \
    -c "show ip route ${MG_CLIENT_CIDR}" 2>/dev/null || true)"
  [[ "${onprem_rib}" == *"${MG_CLIENT_CIDR}"* ]] \
    || die "prefixo ${MG_CLIENT_CIDR} ausente no RIB do cliente após staticd"

  mtu="$(docker exec "${MG_CENTRAL}" ovn-nbctl \
    get logical_router_port "lrp-mgc-${MG_GW_VRF_1}-external" options \
    2>/dev/null || true)"
  [[ "${mtu}" == *"gateway_mtu"* && "${mtu}" == *"1500"* ]] \
    || die "gateway_mtu=1500 não registrado na LRP externa (${mtu})"

  evpn="$(docker exec "${MG_CENTRAL}" ovn-nbctl \
    get logical_switch "${MG_TENANT_LS}" other_config 2>/dev/null || true)"
  [[ "${evpn}" == *"dynamic-routing-vni"* \
    && "${evpn}" == *"dynamic-routing-bridge-ifname"* \
    && "${evpn}" == *"dynamic-routing-vxlan-ifname"* \
    && "${evpn}" == *"dynamic-routing-advertise-ifname"* ]] \
    || die "configuração EVPN Type 5 incompleta no LS ${MG_TENANT_LS}: ${evpn}"

  remote_vtep="$(docker exec "${MG_CHASSIS_1}" bash -c \
    'if command -v ovn-appctl >/dev/null 2>&1; then ovn-appctl -t ovn-controller evpn/remote-vtep-list 2>/dev/null || true; fi' \
    || true)"
  bfd="$(docker exec "${MG_CLIENT_NAME}" vtysh -c 'show bfd peers' 2>/dev/null || true)"
  bfd_up="$(grep -Eic '(^|[[:space:]])up([[:space:]]|$)' <<<"${bfd}" || true)"
  [[ -n "${bfd_up}" ]] || bfd_up=0
  bfd_gw1="$(docker exec "${MG_GATEWAY_1}" vtysh \
    -c "show bfd vrf ovnvrf${MG_GW_VRF_1} peers" 2>/dev/null || true)"
  bfd_gw2="$(docker exec "${MG_GATEWAY_2}" vtysh \
    -c "show bfd vrf ovnvrf${MG_GW_VRF_2} peers" 2>/dev/null || true)"
  bfd_up_gw1="$(grep -Eic '(^|[[:space:]])up([[:space:]]|$)' <<<"${bfd_gw1}" || true)"
  bfd_up_gw2="$(grep -Eic '(^|[[:space:]])up([[:space:]]|$)' <<<"${bfd_gw2}" || true)"
  [[ -n "${bfd_up_gw1}" ]] || bfd_up_gw1=0
  [[ -n "${bfd_up_gw2}" ]] || bfd_up_gw2=0
  [[ "${bfd_up}" -ge 2 ]] \
    || die "esperava >=2 peers BFD Up no cliente, obtive ${bfd_up}"
  [[ "${bfd_up_gw1}" -ge 1 ]] \
    || die "esperava >=1 peer BFD Up em ${MG_GATEWAY_1}, obtive ${bfd_up_gw1}"
  [[ "${bfd_up_gw2}" -ge 1 ]] \
    || die "esperava >=1 peer BFD Up em ${MG_GATEWAY_2}, obtive ${bfd_up_gw2}"
  tenant_vm_mac="$(docker exec "${MG_CHASSIS_1}" ip netns exec "${MG_TENANT_VM_NS}" \
    ip link show "${MG_TENANT_VM_IF}" 2>/dev/null \
    | awk '/link\/ether/{print $2; exit}' || true)"
  [[ "${tenant_vm_mac}" == "${MG_TENANT_VM_MAC}" ]] \
    || die "MAC da VM fake divergente: esperado ${MG_TENANT_VM_MAC}, obtido ${tenant_vm_mac:-ausente}"
  client_source="${MG_CLIENT_LOOPBACK_IP%%/*}"
  ping_result="$(docker exec "${MG_CLIENT_NAME}" ping -I "${client_source}" -c 3 -W 2 "${MG_TENANT_VM_IP}" 2>&1 || true)"
  grep -q ' 0% packet loss' <<<"${ping_result}" \
    || die "cliente não alcançou a VM fake ${MG_TENANT_VM_IP}"
  log "  EVPN Type 5 ao vivo/RIB externo: gate reservado à cápsula S002-07; verify atual cobre somente a estrutura NB"

  if [[ "${MGC_M03_MODE}" == 1 ]]; then
    log "fase M03 verify: convergência Type5/RIB/FIB/VTEP/route-get"
    mgc_m03_phase verify m03-verify
  fi
  {
    echo "=== labctl ${LAB_NAME} verify $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    echo "bgp_established_cliente=${sessions}"
    echo "bgp_summary_established_json:"
    printf '%s\n' "${bgp_json}"
    echo "ecmp_nexthops=${ecmp}"
    echo "tenant_route_rib:"
    printf '%s\n' "${route_rib}"
    echo "onprem_route_rib:"
    printf '%s\n' "${onprem_rib}"
    echo "bfd_up_cliente=${bfd_up}"
    echo "bfd_up_${MG_GATEWAY_1}=${bfd_up_gw1}"
    echo "bfd_up_${MG_GATEWAY_2}=${bfd_up_gw2}"
    echo "bfd_cliente_output:"
    printf '%s\n' "${bfd}"
    echo "bfd_${MG_GATEWAY_1}_output:"
    printf '%s\n' "${bfd_gw1}"
    echo "bfd_${MG_GATEWAY_2}_output:"
    printf '%s\n' "${bfd_gw2}"
    echo "tenant_vm_mac=${tenant_vm_mac}"
    echo "gateway_mtu=${MG_GATEWAY_MTU}"
    echo "evpn_structural_config=${evpn}"
    echo "evpn_remote_vtep_observed=${remote_vtep:-nenhum_observado}"
    echo "evpn_type5_live_gate=DEFERRED_TO_S002-07"
    echo "evpn_type5_external_rib=DEFERRED_TO_S002-07"
    echo "tenant_vm_ping=0%_loss"
    echo "VERIFY_OK"
  } >"${verify_file}"
  state_set "${LAB_NAME}" verified_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log "lab ${LAB_NAME} verify OK (evidência: ${verify_file})"
}

# ---------------------------------------------------------------------------
# down: remoção nominal e prova de ausência
# ---------------------------------------------------------------------------
mgc_remove_client_port() {
  local client="$1" interface="$2" port
  if [[ "$(mgc_count_named "${client}")" -gt 0 ]]; then
    mgc_assert_client_ownership "${client}"
  fi
  port="$(mgc_ovs_port "${client}" "${interface}" || true)"
  if [[ -n "${port}" ]]; then
    run env RUNC_CMD="${RUNC_CMD}" "${MGC_FAKE_MN}/ovs-runc" \
      del-port br-ovn-ext "${interface}" "${client}"
  fi
}

mgc_remove_mirror() {
  local gateway vrf_id lsp
  gateway="$1"
  vrf_id="$2"
  lsp="bgpvrf${vrf_id}"
  local ovs_if="${lsp}-ovs" vrf_if="${lsp}"
  if [[ "$(mgc_count_named "${gateway}" running)" -eq 0 ]]; then
    return 0
  fi
  if docker exec "${gateway}" ip link show "${ovs_if}" >/dev/null 2>&1; then
    run docker exec "${gateway}" ovs-vsctl --if-exists del-port br-int "${ovs_if}"
  fi
  if docker exec "${gateway}" ip link show "${vrf_if}" >/dev/null 2>&1; then
    run docker exec "${gateway}" ip link del "${vrf_if}"
  fi
}

lab_down() {
  local ev cluster_all
  require_cmd flock readlink stat wc
  mgc_m03_lock_action
  mgc_x05_guard
  ev="$(evidence_dir "${LAB_NAME}")"
  log "evidência: ${ev}"
  if [[ "${MGC_M03_MODE}" == 1 ]]; then
    log "fase M03 down: cleanup owned e restauração do baseline MGC"
    mgc_m03_phase down m03-down
    if [[ "${DRY_RUN}" == "1" ]]; then
      log "DRY: pós-condição de ausência M03 será verificada após execução real"
      return 0
    fi
    mgc_assert_m03_absent
    log "fase M03 down concluída; baseline MGC permanece ativo"
    return 0
  fi
  mgc_m03_cleanup_owned
  mgc_assert_no_extra_ovn_containers
  cluster_all="$(mgc_cluster_count all)"
  if [[ "$(mgc_count_named "${MG_CLIENT_NAME}")" -gt 0 ]]; then
    mgc_assert_client_ownership "${MG_CLIENT_NAME}"
  fi
  if [[ "${cluster_all}" -gt 0 ]]; then
    mgc_assert_cluster_ownership
    mgc_assert_bridges_owned yes
  elif mgc_any_bridge_exists; then
    mgc_assert_bridges_owned yes
  fi
  log "1/4 pernas VLAN e cliente do perfil"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: ovs-runc del-port br-ovn-ext eth1/eth2 ${MG_CLIENT_NAME}"
    echo "DRY: docker rm -f ${MG_CLIENT_NAME}"
  else
    mgc_remove_client_port "${MG_CLIENT_NAME}" eth1
    mgc_remove_client_port "${MG_CLIENT_NAME}" eth2
    if [[ "$(mgc_count_named "${MG_CLIENT_NAME}")" -gt 0 ]]; then
      run docker rm -f "${MG_CLIENT_NAME}"
    fi
  fi

  log "2/4 espelhos BGP e dados específicos dos gateways"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: remover veths bgpvrf${MG_GW_VRF_1}/bgpvrf${MG_GW_VRF_2}"
  else
    mgc_remove_mirror "${MG_GATEWAY_1}" "${MG_GW_VRF_1}"
    mgc_remove_mirror "${MG_GATEWAY_2}" "${MG_GW_VRF_2}"
  fi

  log "3/4 cluster OVN e bancos NB/SB"
  cluster_all="$(mgc_cluster_count all)"
  if [[ "${cluster_all}" -gt 0 ]]; then
    mgc_stop_owned_cluster
  elif mgc_any_bridge_exists; then
    mgc_remove_owned_bridges
  elif [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: nenhum cluster OVN próprio presente; não executar stop upstream"
  fi

  log "4/4 prova de ausência de resíduo"
  assert_absent_containers "${MG_PREFIX}"
  assert_absent_containers "ovn-central"
  assert_absent_containers "ovn-gw"
  assert_absent_containers "ovn-chassis"
  mgc_assert_no_extra_ovn_containers
  assert_absent_link br-ovn
  assert_absent_link br-ovn-ext
  if [[ "${DRY_RUN}" != "1" ]]; then
    if ip netns list | grep -Eq '(^|[[:space:]])mgc-|ovnvrf'; then
      die "resíduo: netns mgc/ovnvrf ainda existe"
    fi
  else
    echo "DRY: provar ausência de netns mgc/ovnvrf"
  fi
  log "lab ${LAB_NAME} down concluído"
}

# ---------------------------------------------------------------------------
# status/resources
# ---------------------------------------------------------------------------
lab_status() {
  local profile client cluster mem owner_state client_owner
  profile="$(docker ps --format '{{.Names}}' 2>/dev/null \
    | grep -Ec "^${MG_PREFIX}" || true)"
  client="$(mgc_count_named "${MG_CLIENT_NAME}" running)"
  cluster="$(mgc_cluster_count running)"
  owner_state="$(state_get "${LAB_NAME}" owner_state 2>/dev/null || true)"
  client_owner="$(state_get "${LAB_NAME}" "$(mgc_client_owner_key "${MG_CLIENT_NAME}")" 2>/dev/null || true)"
  mem="$(docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' 2>/dev/null \
    | grep -E "^(${MG_PREFIX}|ovn-(central|gw|chassis))" || true)"
  log "lab=${LAB_NAME} up=$([[ "${cluster}" -eq 5 && "${client}" -eq 1 ]] && echo sim || echo nao) containers_perfil=${profile} cluster_ovn=${cluster}/5 ownership=${owner_state:-unknown} client_id=${client_owner:-unknown}"
  [[ -z "${mem}" ]] || printf '  %s\n' "${mem//$'\n'/$'\n'  }"
}

lab_resources() {
  log "recursos nominais do perfil ${LAB_NAME}:"
  log "  fontes: ${MGC_OVN_SRC}, ${MGC_OVS_SRC}, ${MGC_FAKE_MN}"
  log "  cluster: ${MG_CENTRAL}, ${MG_GATEWAY_1}/${MG_GATEWAY_2}, ${MG_CHASSIS_1}/${MG_CHASSIS_2}"
  log "  cliente: ${MG_CLIENT_NAME} (AS ${MG_CLIENT_AS}, ${MG_CLIENT_CIDR}, eth1 VLAN ${MG_GW_VLAN_1}, eth2 VLAN ${MG_GW_VLAN_2})"
  log "  gateways: VRF ovnvrf${MG_GW_VRF_1}/ovnvrf${MG_GW_VRF_2}, AS ${MG_GW_AS}, gateway_mtu=${MG_GATEWAY_MTU}"
  log "  tenant: ${MG_TENANT_LS}/${MG_TENANT_LR}, ${MG_TENANT_CIDR}, EVPN VNI ${MG_TENANT_VNI}, VM ${MG_TENANT_VM_IP}"
  log "  fixtures: ${MGC_FIXTURE_DIR}"
}
