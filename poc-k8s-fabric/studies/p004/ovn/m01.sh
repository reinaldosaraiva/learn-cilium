#!/usr/bin/env bash
# P004-S002/M01: falhas reversíveis em um dos dois Connect Gateways.
# Executar no host vm-cilium com LAB_ROOT apontando para o labctl staged.
set -euo pipefail

case "${1:-}" in
  --dry-run) mode=dry ;;
  --dry-run-gateway) mode=dry-gateway ;;
  --execute) mode=execute ;;
  --execute-gateway) mode=gateway ;;
  *) echo "uso: LAB_ROOT=... bash m01.sh --dry-run|--dry-run-gateway|--execute|--execute-gateway" >&2; exit 2 ;;
esac
[[ "$#" -eq 1 ]] || { echo "M01 aceita uma única opção" >&2; exit 2; }
: "${LAB_ROOT:?LAB_ROOT é obrigatório}"
export LAB_ROOT

# shellcheck source=../../../labctl/lib/common.sh
source "${LAB_ROOT}/lib/common.sh"
# shellcheck source=../../../labctl/labs/mgc.sh
source "${LAB_ROOT}/labs/mgc.sh"
require_cmd docker jq
if [[ "$mode" == execute || "$mode" == gateway ]]; then
  DRY_RUN=0
else
  DRY_RUN=1
fi
export DRY_RUN

client=mgc-client-1
central=ovn-central-az1
gateway=ovn-gw-1
survivor=ovn-gw-2
prefix=192.168.100.0/24
negative_prefix=192.168.101.0/24
return_prefix=10.0.0.0/16
return_first_hop=10.100.100.2
return_second_hop=10.200.100.2
tenant_router=lr-mgc-tenant
first_hop=169.254.254.1
second_hop=169.254.254.5
labctl="${LAB_ROOT}/labctl"
fault_active=0
capture_dir=""
capture_pids=()
capture_logs=()
capture_ifaces=(eth2 eth1)
capture_timeout=65
capture_expected_replies=30
capture_label=""
capture_preserved=0
ovn_query_timeout=10

say() { printf 'M01 %s\n' "$*"; }
fail() {
  say "FAIL: $*" >&2
  preserve_packet_capture failure
  exit 1
}

assert_owned_running() {
  mgc_assert_no_extra_ovn_containers
  mgc_assert_cluster_ownership
  mgc_assert_bridges_owned
  mgc_assert_client_ownership "$client"
  for name in ovn-central-az1 "$gateway" "$survivor" ovn-chassis-1 ovn-chassis-2 "$client"; do
    [[ "$(docker inspect -f '{{.State.Running}}' "$name")" == true ]] \
      || fail "$name não está rodando no baseline"
  done
  [[ "$(awk '/^MemAvailable:/ {print int($2 / 1024 / 1024)}' /proc/meminfo)" -ge 4 ]] \
    || fail 'MemAvailable abaixo de 4 GiB'
}

route_has() {
  local wanted="$1" route
  route="$(docker exec "$client" ip -4 route show exact "$prefix")"
  [[ "$route" == *"via $wanted "* ]]
}

wait_route() {
  local first="$1" second="$2" attempt
  for ((attempt = 1; attempt <= 45; attempt++)); do
    if [[ "$first" == yes ]]; then
      route_has "$first_hop" || { sleep 2; continue; }
    else
      ! route_has "$first_hop" || { sleep 2; continue; }
    fi
    if [[ "$second" == yes ]]; then
      route_has "$second_hop" || { sleep 2; continue; }
    else
      ! route_has "$second_hop" || { sleep 2; continue; }
    fi
    return 0
  done
  fail "rota $prefix não convergiu para gw1=$first gw2=$second"
}

sessions_match() {
  local expected="$1" summary
  summary="$(docker exec "$client" vtysh \
    -c 'show bgp ipv4 unicast summary established json' 2>/dev/null)" || return 1
  jq -e --argjson expected "$expected" --arg first "$first_hop" \
    --arg second "$second_hop" '
      .displayedPeers == $expected and
      ((.peers | keys) == (if $expected == 2 then [$first, $second] else [$second] end)) and
      ([.peers[] | .state] | all(. == "Established"))
    ' <<<"$summary" >/dev/null 2>&1
}

wait_sessions() {
  local expected="$1" attempt
  for ((attempt = 1; attempt <= 45; attempt++)); do
    sessions_match "$expected" && return 0
    sleep 2
  done
  fail "sessões não convergiram para $expected peer(s) esperado(s)"
}

assert_negative() {
  local bgp kernel
  bgp="$(docker exec "$client" vtysh \
    -c "show bgp ipv4 unicast $negative_prefix json" 2>/dev/null)"
  kernel="$(docker exec "$client" ip -4 route show exact "$negative_prefix")"
  printf 'M01 controle negativo BGP %s: %s\n' "$negative_prefix" "$bgp"
  printf 'M01 controle negativo FIB %s: %s\n' "$negative_prefix" "${kernel:-<ausente>}"
  jq -e 'length == 0' <<<"$bgp" >/dev/null \
    || fail "prefixo negativo $negative_prefix consta no RIB BGP"
  [[ -z "$kernel" ]] || fail "prefixo negativo $negative_prefix consta no FIB"
}

ovn_fault_snapshot() {
  local label="$1" options routes route_options_ok all_flows sb_flow_counts

  require_cmd timeout

  say "OVN NB tenant router options ($label)"
  options="$(ovn_read ovn-nbctl get logical_router \
    "$tenant_router" options)"
  printf '%s\n' "$options"
  [[ "$options" == *'chassis=ovn-chassis-1'* ]] \
    || fail "NB não mostrou chassis=ovn-chassis-1 durante $label"

  say "OVN NB tenant routes/options ($label)"
  routes="$(ovn_read ovn-nbctl lr-route-list "$tenant_router")"
  printf '%s\n' "$routes"
  route_options_ok="$(awk -v prefix="$return_prefix" \
    -v first="$return_first_hop" -v second="$return_second_hop" '
      index($0, prefix) && index($0, first) && index($0, "ecmp-symmetric-reply") { first_ok = 1 }
      index($0, prefix) && index($0, second) && index($0, "ecmp-symmetric-reply") { second_ok = 1 }
      END { print (first_ok && second_ok) ? "yes" : "no" }
    ' <<<"$routes")"
  [[ "$route_options_ok" == yes ]] \
    || fail "NB não mostrou as duas rotas de retorno ECMP simétrico durante $label"

  say "OVN SB symmetric flows ($label)"
  all_flows="$(ovn_read ovn-sbctl lflow-list "$tenant_router" \
    | awk '/lr_in_ecmp_stateful|ecmp_reply|ecmp_symmetric/ {print}')"
  [[ -n "$all_flows" ]] || fail "SB não mostrou fluxos de retorno simétrico durante $label"
  printf '%s\n' "$all_flows"
  sb_flow_counts="$(awk '
    /lr_in_ecmp_stateful/ &&
      index($0, "inport == \"lrp-tenant-100\"") &&
      index($0, "ip4.src == 10.0.0.0/16") &&
      index($0, "ct_mark.ecmp_reply_port = 2") { state100 = 1 }
    /lr_in_ecmp_stateful/ &&
      index($0, "inport == \"lrp-tenant-200\"") &&
      index($0, "ip4.src == 10.0.0.0/16") &&
      index($0, "ct_mark.ecmp_reply_port = 3") { state200 = 1 }
    /lr_in_ip_routing/ &&
      index($0, "ct_mark.ecmp_reply_port == 2") &&
      index($0, "ip4.dst == 10.0.0.0/16") &&
      index($0, "outport = \"lrp-tenant-100\"") { route100 = 1 }
    /lr_in_ip_routing/ &&
      index($0, "ct_mark.ecmp_reply_port == 3") &&
      index($0, "ip4.dst == 10.0.0.0/16") &&
      index($0, "outport = \"lrp-tenant-200\"") { route200 = 1 }
    END { print state100 "/" state200 "/" route100 "/" route200 }
  ' <<<"$all_flows")"
  [[ "$sb_flow_counts" == 1/1/1/1 ]] \
    || fail "SB não mostrou os dois fluxos de retorno específicos (state/route 100/200: $sb_flow_counts) durante $label"
}

ovn_read() {
  timeout --foreground --kill-after=2s "${ovn_query_timeout}s" \
    docker exec "$central" "$@"
}

stop_packet_capture() {
  local pid ticks

  for pid in "${capture_pids[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${capture_pids[@]}"; do
    ticks=0
    while kill -0 "$pid" 2>/dev/null; do
      if [[ "$ticks" -ge 20 ]]; then
        kill -KILL "$pid" 2>/dev/null || true
        break
      fi
      sleep 0.1
      ticks=$((ticks + 1))
    done
    wait "$pid" 2>/dev/null || true
  done
  capture_pids=()
}

preserve_packet_capture() {
  local reason="$1" root destination log index

  [[ -n "$capture_dir" && -d "$capture_dir" ]] || return 0
  stop_packet_capture
  if [[ "$capture_preserved" == 0 ]]; then
    root="${M01_CAPTURE_EVIDENCE_DIR:-${EVIDENCE_DIR:-/var/tmp/labctl/mgc}}"
    destination="${root}/m01-capture-${capture_label:-fault}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    if mkdir -p "$root" 2>/dev/null && mv "$capture_dir" "$destination"; then
      capture_dir="$destination"
      capture_preserved=1
      for index in "${!capture_logs[@]}"; do
        capture_logs[index]="${capture_dir}/${capture_ifaces[index]}.txt"
      done
    else
      say "WARN: não foi possível mover a captura; logs temporários em $capture_dir"
    fi
  fi
  say "captura preservada ($reason): $capture_dir"
  for log in "${capture_logs[@]}"; do
    if [[ -f "$log" ]]; then
      say "log de captura: $log"
      sed -n '1,80p' "$log"
    fi
  done
}

discard_packet_capture() {
  local log

  [[ "$capture_preserved" == 0 ]] || return 0
  for log in "${capture_logs[@]}"; do
    rm -f -- "$log" 2>/dev/null || true
  done
  if [[ -n "$capture_dir" ]]; then
    rmdir "$capture_dir" 2>/dev/null || true
  fi
  capture_logs=()
  capture_dir=""
  capture_label=""
}

start_packet_capture() {
  local label="$1" client_pid iface output pid index
  local filter='icmp and src host 192.168.100.10 and dst host 10.0.0.1'

  [[ "$DRY_RUN" == 0 ]] || fail "captura solicitada em modo dry-run"
  require_cmd mktemp nsenter tcpdump timeout
  client_pid="$(docker inspect -f '{{.State.Pid}}' "$client")"
  [[ "$client_pid" =~ ^[1-9][0-9]*$ ]] \
    || fail "PID do cliente inválido para captura: ${client_pid:-<ausente>}"
  capture_label="$label"
  capture_preserved=0
  capture_dir="$(mktemp -d "${TMPDIR:-/tmp}/m01-capture.XXXXXX")"

  for index in "${!capture_ifaces[@]}"; do
    iface="${capture_ifaces[$index]}"
    output="${capture_dir}/${iface}.txt"
    capture_logs+=("$output")
    say "iniciar captura ($label) no namespace do cliente: $iface"
    timeout --foreground --signal=TERM --kill-after=2s "${capture_timeout}s" \
      nsenter -t "$client_pid" -n tcpdump -nn -l -tt -i "$iface" \
      "$filter" >"$output" 2>&1 &
    capture_pids+=("$!")
  done

  # Give tcpdump a bounded startup window before the ping begins. A missing
  # interface or a failed nsenter must not be reported as captured evidence.
  sleep 1
  for index in "${!capture_pids[@]}"; do
    pid="${capture_pids[$index]}"
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      fail "captura ${capture_ifaces[$index]} encerrou antes do ping"
    fi
  done
}

report_packet_capture() {
  local label="$1" iface log replies index

  for index in "${!capture_logs[@]}"; do
    iface="${capture_ifaces[$index]}"
    log="${capture_logs[$index]}"
    replies="$(awk 'index($0, "192.168.100.10 > 10.0.0.1") && /echo reply/ {count++} END {print count + 0}' "$log")"
    say "ICMP replies ($label) iface=$iface count=$replies"
    sed -n '1,80p' "$log"
    if [[ "$iface" == eth2 ]]; then
      [[ "$replies" -eq "$capture_expected_replies" ]] \
        || fail "captura eth2 registrou $replies/$capture_expected_replies replies durante $label"
    else
      [[ "$replies" -eq 0 ]] \
        || fail "captura eth1 registrou $replies replies durante $label"
    fi
  done
}

observe_fault() {
  local label="$1"

  ovn_fault_snapshot "$label"
  start_packet_capture "$label"
  ping_tenant
  sleep 1
  stop_packet_capture
  report_packet_capture "$label"
  discard_packet_capture
}

capture() {
  local label="$1" expected="$2"
  wait_sessions "$expected"
  say "RIB externo e sessão ($expected peer(s)): $label"
  docker exec "$client" vtysh -c "show bgp ipv4 unicast $prefix"
  docker exec "$client" vtysh -c 'show bgp ipv4 unicast summary established'
  docker exec "$client" ip -4 route show exact "$prefix"
  assert_negative
}

ping_tenant() {
  local result rc=0
  result="$(docker exec "$client" ping -I 10.0.0.1 -c 30 -i 0.1 -W 2 \
    192.168.100.10)" || rc=$?
  printf '%s\n' "$result"
  [[ "$rc" -eq 0 ]] || fail "ping ao tenant falhou (rc=$rc)"
  [[ "$result" == *'30 packets transmitted, 30 packets received, 0% packet loss'* \
    || "$result" == *'30 packets transmitted, 30 received, 0% packet loss'* ]] \
    || fail 'ping ao tenant não fechou 30/30'
}

verify_full() {
  wait_route yes yes
  "$labctl" mgc verify
  capture "$1" 2
  ping_tenant
}

restore() {
  local rc=$?
  trap - EXIT INT TERM
  stop_packet_capture || rc=1
  if [[ "$rc" -ne 0 ]]; then
    preserve_packet_capture failure
  else
    discard_packet_capture
  fi
  if [[ "$fault_active" == 1 ]]; then
    say 'restauração: iniciar gateway próprio se parado; reaplicar fixture e verificar'
    if [[ "$(docker inspect -f '{{.State.Running}}' "$gateway" 2>/dev/null)" == false ]]; then
      docker start "$gateway" || rc=1
    fi
    "$labctl" mgc up || rc=1
    "$labctl" mgc verify || rc=1
  fi
  if [[ "$rc" -ne 0 ]]; then
    say 'falha; conferir estado MGC e evidência antes de nova execução' >&2
  fi
  exit "$rc"
}

assert_owned_running
if [[ "$mode" == dry || "$mode" == dry-gateway ]]; then
  say 'DRY: baseline labctl mgc verify, 2 sessões, rota ECMP e ping tenant 30/30'
  say "DRY: conferir ausência de $negative_prefix no RIB BGP e FIB em todas as fases"
  say 'DRY: após convergência de cada fault, imprimir NB tenant routes/options e SB symmetric flows'
  say 'DRY: em execute, capturar 30 replies ICMP 192.168.100.10 -> 10.0.0.1 em eth2 via nsenter/tcpdump (65s); exigir zero em eth1; preservar logs em falha; nunca capturar no dry-run'
  if [[ "$mode" == dry ]]; then
    say "DRY: em $gateway retirar network $prefix; exigir 2 sessões, somente $second_hop e ping 30/30; restaurar por labctl mgc up/verify"
    say "DRY: parar somente bgpd, bfdd, zebra em $gateway (container ativo); exigir 1 sessão, somente $second_hop e ping 30/30; restaurar por labctl mgc up/verify"
  fi
  say "DRY: docker stop $gateway próprio; exigir 1 sessão, somente $second_hop e ping 30/30; docker start $gateway e labctl mgc up/verify"
  say 'DRY: trap de falha restaura o gateway e reaplica fixture MGC; sem mutações neste modo'
  exit 0
fi

trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
say 'baseline'
verify_full baseline

if [[ "$mode" == execute ]]; then
  say "withdraw $prefix em $gateway"
  fault_active=1
  docker exec "$gateway" vtysh -c 'configure terminal' \
    -c 'router bgp 100 vrf ovnvrf100' -c 'address-family ipv4 unicast' \
    -c "no network $prefix"
  wait_route no yes
  [[ "$(docker inspect -f '{{.State.Running}}' "$gateway")" == true ]] || fail 'gateway caiu no withdraw'
  capture withdraw 2
  observe_fault withdraw
  say 'restaurar withdraw'
  "$labctl" mgc up
  verify_full withdraw-restored
  fault_active=0

  say "parar FRR em $gateway, preservando o container"
  fault_active=1
  docker exec "$gateway" bash -c '
    set -euo pipefail
    for daemon in bgpd bfdd zebra; do
      if pidof "$daemon" >/dev/null 2>&1; then
        kill $(pidof "$daemon")
      fi
    done
  '
  for daemon in bgpd bfdd zebra; do
    for ((attempt = 1; attempt <= 30; attempt++)); do
      ! docker exec "$gateway" pidof "$daemon" >/dev/null 2>&1 && break
      sleep 0.2
    done
    ! docker exec "$gateway" pidof "$daemon" >/dev/null 2>&1 \
      || fail "$daemon segue ativo após parada"
  done
  [[ "$(docker inspect -f '{{.State.Running}}' "$gateway")" == true ]] || fail 'gateway caiu com FRR'
  wait_route no yes
  capture frr-stopped 1
  observe_fault frr-stopped
  say 'restaurar FRR'
  "$labctl" mgc up
  verify_full frr-restored
  fault_active=0
fi

say "parar gateway $gateway"
fault_active=1
docker stop "$gateway"
[[ "$(docker inspect -f '{{.State.Running}}' "$gateway")" == false ]] || fail 'gateway não parou'
wait_route no yes
capture gateway-stopped 1
observe_fault gateway-stopped
say 'restaurar gateway'
docker start "$gateway"
"$labctl" mgc up
verify_full gateway-restored
fault_active=0
if [[ "$mode" == gateway ]]; then
  say 'PASS: fase gateway concluída; dois caminhos restabelecidos'
else
  say 'PASS: M01 completo; dois caminhos restabelecidos'
fi
