#!/usr/bin/env bash
# labs/openstack.sh — perfil de preservação do testbed OpenStack (P004-S001, §6).
# Sourced pelo labctl. Só status / down(stop) / up(start) — NUNCA rebuild.
set -euo pipefail

LAB_NAME="openstack"
LAB_CONTAINER="p003-os"
export LAB_NAME

# ---- preflight: capacidade e presença do container (sem alterar) ----
lab_preflight() {
  log "preflight ${LAB_NAME}:"
  local mem
  mem="$(mem_avail_gib)"
  log "  MemAvailable=${mem}GiB (testbed tem cap de 8GiB — L7)"
  require_cmd docker
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${LAB_CONTAINER}"; then
    log "  container ${LAB_CONTAINER}: presente"
  else
    log "  container ${LAB_CONTAINER}: ausente"
  fi
  log "preflight ${LAB_NAME} OK"
  return 0
}

# ---- status: container no ar, memória, agentes Neutron ----
lab_status() {
  local up="nao"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${LAB_CONTAINER}"; then
    up="sim"
  fi
  log "lab=${LAB_NAME} container=${LAB_CONTAINER} up=${up}"
  docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' 2>/dev/null \
    | awk -v c="${LAB_CONTAINER}" '$1==c{print "  "$0}'
  if [[ "${up}" == "sim" ]]; then
    log "  agentes Neutron:"
    docker exec "${LAB_CONTAINER}" openstack network agent list 2>/dev/null \
      | awk 'NR>2 && $0 !~ /^\+/{print "    "$0}' || log "    (openstack network agent list indisponível)"
  fi
  return 0
}

# ---- down: docker stop (nunca rm); registra estado ----
lab_down() {
  require_cmd docker
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${LAB_CONTAINER}"; then
    run docker stop "${LAB_CONTAINER}"
  else
    log "  ${LAB_CONTAINER} já está parado"
  fi
  state_set "${LAB_NAME}" stopped_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log "lab ${LAB_NAME} down concluído (container parado, não removido)"
  return 0
}

# ---- up: docker start + passos pós-restart da S012 ----
# A âncora (P003-S012) descreve um restore dependente do estado do testbed
# (guard OVS, ovs-vswitchd manual, neutron-rpc-server após mysql saudável).
# Não é inequívoca para um restore cego: imprime os passos e devolve 3
# (NEEDS_INPUT) para o coordenador executar/verificar manualmente.
lab_up() {
  require_cmd docker
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${LAB_CONTAINER}"; then
    run docker start "${LAB_CONTAINER}"
  else
    log "  ${LAB_CONTAINER} já está no ar"
  fi
  state_set "${LAB_NAME}" started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log "passos pós-restart (âncora P003-S012) — executar/verificar manualmente:"
  log "  1. rearmar o guard OVS (evitar rmmod bridge no kernel do host)"
  log "  2. subir ovs-vswitchd manual (datapath ovs-system)"
  log "  3. subir/reiniciar neutron-rpc-server DEPOIS do mysql saudável"
  log "  4. verificar 3 agentes Neutron Alive"
  return 3
}

# ---- verify: agentes Alive + openstack network list responde ----
lab_verify() {
  local ev verify_file agents net_ok
  ev="$(evidence_dir "${LAB_NAME}")"
  verify_file="${ev}/verify.txt"
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${LAB_CONTAINER}"; then
    die "container ${LAB_CONTAINER} não está no ar"
  fi
  # P3-4: contar só linhas de dado (começam com '|'), excluindo bordas '+' e o
  # cabeçalho (que contém 'Agent Type') — o awk anterior contava a borda final.
  agents="$(docker exec "${LAB_CONTAINER}" openstack network agent list 2>/dev/null \
    | awk '/^\|/ && $0 !~ /Agent Type/{c++} END{print c+0}' || true)"
  # P2-3: usar o rc do comando — a substring 'id' falhava (cabeçalho 'ID' maiúsculo)
  net_ok="nao"
  if docker exec "${LAB_CONTAINER}" openstack network list >/dev/null 2>&1; then
    net_ok="sim"
  fi
  # O2: a escrita do verify.txt é DRY-aware (em dry-run o diretório não existe)
  if [[ "${DRY_RUN}" != "1" ]]; then
    {
      echo "=== labctl ${LAB_NAME} verify $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
      echo "agentes_listados=${agents}"
      echo "network_list_responde=${net_ok}"
    } > "${verify_file}"
  else
    echo "DRY: gravar verify.txt em ${verify_file}"
  fi
  [[ "${net_ok}" == "sim" ]] || die "openstack network list não respondeu"
  # âncora S012: 3 agentes Neutron
  [[ "${agents}" -ge 3 ]] || die "esperava >=3 agentes Neutron, obtive ${agents}"
  log "lab ${LAB_NAME} verify OK (evidência: ${verify_file})"
  return 0
}

# ---- resources: lista nominal ----
lab_resources() {
  log "recursos nominais do perfil ${LAB_NAME}:"
  log "  container: ${LAB_CONTAINER} (cap 8GiB, overlay-only)"
  log "  serviços: keystone, neutron (ml2/ovs), mysql, rabbitmq"
  log "  agentes: ovs, l3, dhcp (3 Alive esperados)"
  log "  rede tenant: 10.30.0.0/24 (VLAN 1); ext-net 10.40.0.0/24; router r-a (sem SNAT)"
  log "  preservação: só status/down(stop)/up(start) — nunca rebuild"
  return 0
}
