#!/usr/bin/env bash
# Topologia NB canônica da réplica MGC (OVN 26.03.3).
# Executado dentro de ovn-central-az1 pelo perfil labctl mgc.
set -euo pipefail

nbctl() {
  ovn-nbctl --wait=sb "$@"
}

GW1="ovn-gw-1"
GW2="ovn-gw-2"
TENANT_LS="ls-mgc-tenant"
TENANT_LR="lr-mgc-tenant"
TENANT_CIDR="192.168.100.0/24"
TENANT_VNI=50100
TENANT_RETURN_PREFIX="10.0.0.0/16"
TENANT_RETURN_NEXT_HOPS=(10.100.100.2 10.200.100.2)

configure_connection() {
  local vrf="$1" vlan="$2" gateway="$3" gw_ip="$4" lsp_mac="$5" octet="$6"
  local lr="lr-mgc-${vrf}"
  local ls="ls-mgc-${vrf}-external"
  local lrp="lrp-mgc-${vrf}-external"
  local router_lsp="lsp-mgc-${vrf}-router"
  local mirror="bgpvrf${vrf}"
  local localnet="ln-mgc-${vrf}"

  nbctl --may-exist lr-add "${lr}"
  nbctl set logical_router "${lr}" \
    options:dynamic-routing=true \
    options:dynamic-routing-vrf-name="ovnvrf${vrf}" \
    options:dynamic-routing-vrf-id="${vrf}" \
    options:dynamic-routing-redistribute=connected,static

  nbctl --may-exist ls-add "${ls}"
  nbctl --may-exist lrp-add "${lr}" "${lrp}" "${lsp_mac}" "${gw_ip}/30"
  nbctl --may-exist lsp-add "${ls}" "${router_lsp}"
  nbctl lsp-set-type "${router_lsp}" router
  nbctl lsp-set-addresses "${router_lsp}" router
  nbctl lsp-set-options "${router_lsp}" "router-port=${lrp}"

  nbctl --may-exist lsp-add "${ls}" "${localnet}"
  nbctl lsp-set-type "${localnet}" localnet
  nbctl lsp-set-addresses "${localnet}" unknown
  nbctl lsp-set-options "${localnet}" network_name=public
  nbctl set logical_switch_port "${localnet}" tag_request="${vlan}"

  nbctl --may-exist lsp-add "${ls}" "${mirror}"
  nbctl lsp-set-addresses "${mirror}" unknown

  nbctl set logical_router_port "${lrp}" \
    options:routing-protocols=BGP,BFD \
    options:routing-protocol-redirect="${mirror}" \
    options:dynamic-routing-maintain-vrf=true \
    options:gateway_mtu=1500
  nbctl lrp-set-gateway-chassis "${lrp}" "${gateway}" 20

  nbctl --may-exist ls-add "ls-mgc-${vrf}-transit"
  nbctl --may-exist lrp-add "${lr}" "lrp-mgc-${vrf}-tenant" \
    "02:00:${octet}:00:00:02" "10.${vrf}.100.2/30"
  nbctl --may-exist lsp-add "ls-mgc-${vrf}-transit" "lsp-mgc-${vrf}-tenant"
  nbctl lsp-set-type "lsp-mgc-${vrf}-tenant" router
  nbctl lsp-set-addresses "lsp-mgc-${vrf}-tenant" router
  nbctl lsp-set-options "lsp-mgc-${vrf}-tenant" \
    "router-port=lrp-mgc-${vrf}-tenant"
  nbctl --may-exist lr-route-add "${lr}" "${TENANT_CIDR}" "10.${vrf}.100.1"
}

tenant_router_uuid() {
  local candidates uuid count=0

  candidates="$(nbctl --bare --columns=_uuid find logical_router \
    name="${TENANT_LR}")"
  while IFS= read -r uuid; do
    [[ -z "${uuid}" ]] && continue
    [[ "${uuid}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
      || { echo "invalid UUID for ${TENANT_LR}: ${uuid}" >&2; return 1; }
    count=$((count + 1))
  done <<<"${candidates}"

  [[ "${count}" -eq 1 ]] \
    || { echo "expected exactly one ${TENANT_LR}, found ${count}" >&2; return 1; }
  printf '%s\n' "${candidates}"
}

load_tenant_route_refs() {
  local router_uuid="$1" refs route_uuid
  local -a ref_tokens=()
  TENANT_ROUTE_UUIDS=()

  refs="$(nbctl --bare --columns=static_routes list logical_router \
    "${router_uuid}")"
  refs="${refs//$'\n'/ }"
  refs="${refs//,/ }"
  refs="${refs//\[/ }"
  refs="${refs//\]/ }"
  if [[ -n "${refs//[[:space:]]/}" ]]; then
    read -r -a ref_tokens <<<"${refs}"
  fi

  for route_uuid in "${ref_tokens[@]}"; do
    [[ "${route_uuid}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
      || { echo "invalid static route UUID on ${TENANT_LR}: ${route_uuid}" >&2; return 1; }
    TENANT_ROUTE_UUIDS+=("${route_uuid}")
  done
}

tenant_route_field() {
  local route_uuid="$1" column="$2" value
  value="$(nbctl --bare --columns="${column}" list logical_router_static_route \
    "${route_uuid}"
  )"
  value="${value//\"/}"
  printf '%s\n' "${value}"
}

find_tenant_return_routes() {
  local prefix="$1" next_hop="$2" route_uuid route_prefix route_next_hop
  TENANT_MATCHED_ROUTE_UUIDS=()

  for route_uuid in "${TENANT_ROUTE_UUIDS[@]}"; do
    route_prefix="$(tenant_route_field "${route_uuid}" ip_prefix)"
    route_next_hop="$(tenant_route_field "${route_uuid}" nexthop)"
    if [[ "${route_prefix}" == "${prefix}" && "${route_next_hop}" == "${next_hop}" ]]; then
      TENANT_MATCHED_ROUTE_UUIDS+=("${route_uuid}")
    fi
  done
}

reconcile_tenant_return_routes() {
  local router_uuid next_hop route_uuid
  local -a missing_next_hops=()

  router_uuid="$(tenant_router_uuid)"
  load_tenant_route_refs "${router_uuid}"

  # Do not use --ecmp-symmetric-reply as an existence check: with ECMP it
  # creates another row. First scope every lookup to this router's refs and
  # reject ambiguous duplicates before changing any route.
  for next_hop in "${TENANT_RETURN_NEXT_HOPS[@]}"; do
    find_tenant_return_routes "${TENANT_RETURN_PREFIX}" "${next_hop}"
    case "${#TENANT_MATCHED_ROUTE_UUIDS[@]}" in
      0) missing_next_hops+=("${next_hop}") ;;
      1) ;;
      *)
        echo "ambiguous ${TENANT_RETURN_PREFIX} via ${next_hop} on ${TENANT_LR}" >&2
        return 1
        ;;
    esac
  done

  # Add only absent rows. The explicit UUID reconciliation below is still
  # required because lr-route-add does not repair options on an existing row.
  for next_hop in "${missing_next_hops[@]}"; do
    nbctl --may-exist --ecmp-symmetric-reply lr-route-add \
      "${router_uuid}" "${TENANT_RETURN_PREFIX}" "${next_hop}"
  done

  load_tenant_route_refs "${router_uuid}"
  for next_hop in "${TENANT_RETURN_NEXT_HOPS[@]}"; do
    find_tenant_return_routes "${TENANT_RETURN_PREFIX}" "${next_hop}"
    [[ "${#TENANT_MATCHED_ROUTE_UUIDS[@]}" -eq 1 ]] \
      || { echo "expected one reconciled ${TENANT_RETURN_PREFIX} via ${next_hop}" >&2; return 1; }
    route_uuid="${TENANT_MATCHED_ROUTE_UUIDS[0]}"
    nbctl set logical_router_static_route "${route_uuid}" \
      options:ecmp_symmetric_reply=true
  done

  # Setting one map key preserves the dynamic-routing options configured
  # above; the router UUID also avoids accidentally selecting a duplicate name.
  nbctl set logical_router "${router_uuid}" options:chassis=ovn-chassis-1
}

configure_tenant() {
  local vrf octet
  nbctl --may-exist ls-add "${TENANT_LS}"
  nbctl set logical_switch "${TENANT_LS}" \
    other_config:subnet="${TENANT_CIDR}" \
    other_config:dynamic-routing-vni="${TENANT_VNI}" \
    other_config:dynamic-routing-bridge-ifname=br-evpn-tenant \
    other_config:dynamic-routing-vxlan-ifname=vxlan-tenant \
    other_config:dynamic-routing-advertise-ifname=evpn-tenant \
    other_config:dynamic-routing-redistribute=fdb

  nbctl --may-exist lr-add "${TENANT_LR}"
  nbctl set logical_router "${TENANT_LR}" \
    options:dynamic-routing=true \
    options:dynamic-routing-vrf-name=ovnvrf-tenant \
    options:dynamic-routing-vrf-id=300 \
    options:dynamic-routing-redistribute=connected,static
  nbctl --may-exist lrp-add "${TENANT_LR}" lrp-mgc-tenant \
    02:00:00:10:00:01 192.168.100.1/24
  nbctl --may-exist lsp-add "${TENANT_LS}" lsp-mgc-tenant-router
  nbctl lsp-set-type lsp-mgc-tenant-router router
  nbctl lsp-set-addresses lsp-mgc-tenant-router router
  nbctl lsp-set-options lsp-mgc-tenant-router router-port=lrp-mgc-tenant

  nbctl --may-exist lsp-add "${TENANT_LS}" mgc-tenant-vm
  nbctl lsp-set-addresses mgc-tenant-vm \
    "02:00:00:10:00:10 192.168.100.10"

  for vrf in 100 200; do
    octet=64
    [[ "${vrf}" == 200 ]] && octet=c8
    nbctl --may-exist lrp-add "${TENANT_LR}" "lrp-tenant-${vrf}" \
      "02:00:${octet}:00:00:01" "10.${vrf}.100.1/30"
    nbctl --may-exist lsp-add "ls-mgc-${vrf}-transit" \
      "lsp-tenant-${vrf}"
    nbctl lsp-set-type "lsp-tenant-${vrf}" router
    nbctl lsp-set-addresses "lsp-tenant-${vrf}" router
    nbctl lsp-set-options "lsp-tenant-${vrf}" \
      "router-port=lrp-tenant-${vrf}"
  done

  reconcile_tenant_return_routes
}

configure_connection 100 100 "${GW1}" 169.254.254.1 \
  02:00:64:00:00:01 64
configure_connection 200 200 "${GW2}" 169.254.254.5 \
  02:00:c8:00:00:01 c8
configure_tenant
