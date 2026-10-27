#!/usr/bin/env bash
# P004-S002-A4: provar o efeito da rota estática de retorno via gw1.
# Executar no host vm-cilium com LAB_ROOT apontando para o labctl staged.
set -euo pipefail

case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  --execute) DRY_RUN=0 ;;
  *) echo 'uso: LAB_ROOT=... bash m01-return-diagnostic.sh --dry-run|--execute' >&2; exit 2 ;;
esac
[[ "$#" -eq 1 ]] || { echo 'uma única opção é permitida' >&2; exit 2; }
: "${LAB_ROOT:?LAB_ROOT é obrigatório}"
export LAB_ROOT DRY_RUN

# shellcheck source=../../../labctl/lib/common.sh
source "${LAB_ROOT}/lib/common.sh"
# shellcheck source=../../../labctl/labs/dci.sh
source "${LAB_ROOT}/labs/dci.sh"
require_cmd docker jq

client=dci-client-1
gateway=ovn-gw-1
central=ovn-central-az1
prefix=10.0.0.0/16
failed_nexthop=10.100.100.2
survivor_nexthop=10.200.100.2
fault_active=0

say() { printf 'M01-A4 %s\n' "$*"; }
fail() { say "FAIL: $*" >&2; exit 1; }

assert_baseline() {
  dci_assert_no_extra_ovn_containers
  dci_assert_cluster_ownership
  dci_assert_bridges_owned
  dci_assert_client_ownership "$client"
  for name in "$central" "$gateway" ovn-gw-2 ovn-chassis-1 ovn-chassis-2 "$client"; do
    [[ "$(docker inspect -f '{{.State.Running}}' "$name")" == true ]] \
      || fail "$name não está rodando"
  done
  [[ "$(awk '/^MemAvailable:/ {print int($2 / 1024 / 1024)}' /proc/meminfo)" -ge 4 ]] \
    || fail 'MemAvailable abaixo de 4 GiB'
  local routes
  routes="$(docker exec "$central" ovn-nbctl lr-route-list lr-dci-tenant)"
  [[ "$routes" == *"$prefix"*"$failed_nexthop"* \
    && "$routes" == *"$prefix"*"$survivor_nexthop"* ]] \
    || fail 'duas rotas de retorno esperadas não estão presentes'
}

wait_one_peer() {
  local attempt summary route
  for ((attempt = 1; attempt <= 45; attempt++)); do
    summary="$(docker exec "$client" vtysh \
      -c 'show bgp ipv4 unicast summary established json' 2>/dev/null || true)"
    route="$(docker exec "$client" ip -4 route show exact 192.168.100.0/24)"
    if jq -e '.displayedPeers == 1 and (.peers | keys) == ["169.254.254.5"]' \
      <<<"$summary" >/dev/null 2>&1 \
      && [[ "$route" == *'via 169.254.254.5 '* \
        && "$route" != *'via 169.254.254.1 '* ]]; then
      return 0
    fi
    sleep 2
  done
  fail 'BGP/FIB não convergiram para gw2 após fault FRR'
}

ping_result() {
  local label="$1" result rc=0
  result="$(docker exec "$client" ping -I 10.0.0.1 -c 30 -i 0.1 -W 2 \
    192.168.100.10)" || rc=$?
  say "$label ping_rc=$rc"
  printf '%s\n' "$result" | tail -4
  [[ "$result" == *'30 packets transmitted, 30 packets received, 0% packet loss'* \
    || "$result" == *'30 packets transmitted, 30 received, 0% packet loss'* ]]
}

restore() {
  local rc=$?
  trap - EXIT INT TERM
  if [[ "$fault_active" == 1 ]]; then
    say 'restaurar FRR e as duas rotas somente via labctl dci up/verify'
    "${LAB_ROOT}/labctl" dci up || rc=1
    "${LAB_ROOT}/labctl" dci verify || rc=1
  fi
  exit "$rc"
}

assert_baseline
if [[ "$DRY_RUN" == 1 ]]; then
  say 'DRY: verificar dci e ping baseline 30/30'
  say 'DRY: parar somente bgpd/bfdd/zebra em ovn-gw-1 próprio; exigir BGP 1/2 e FIB via gw2'
  say 'DRY: medir ping com as duas rotas estáticas de retorno; esperar perda'
  say "DRY: ovn-nbctl --wait=sb lr-route-del lr-dci-tenant $prefix $failed_nexthop"
  say 'DRY: confirmar rota de retorno só via gw2 e medir ping 30/30'
  say 'DRY: trap reaplica labctl dci up/verify e restaura FRR e ECMP'
  exit 0
fi

trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"${LAB_ROOT}/labctl" dci verify
ping_result baseline || fail 'baseline não fechou 30/30'
say 'parar daemons FRR de gw1'
fault_active=1
docker exec "$gateway" bash -c '
  set -euo pipefail
  for daemon in bgpd bfdd zebra; do
    if pidof "$daemon" >/dev/null 2>&1; then
      kill $(pidof "$daemon")
    fi
  done
'
wait_one_peer
say 'rotas de retorno antes da remoção'
docker exec "$central" ovn-nbctl lr-route-list lr-dci-tenant
if ping_result with_failed_return; then
  fail 'falha de tráfego não se reproduziu; não alterar a rota'
fi
say "remover temporariamente somente retorno via $failed_nexthop"
docker exec "$central" ovn-nbctl --wait=sb lr-route-del \
  lr-dci-tenant "$prefix" "$failed_nexthop"
routes="$(docker exec "$central" ovn-nbctl lr-route-list lr-dci-tenant)"
printf '%s\n' "$routes"
[[ "$routes" != *"$failed_nexthop"* && "$routes" == *"$survivor_nexthop"* ]] \
  || fail 'retorno não convergiu exclusivamente para gw2'
ping_result without_failed_return \
  || fail 'remover retorno via gw1 não restaurou 30/30'
say 'diagnóstico confirma dependência da rota de retorno'
