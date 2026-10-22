#!/usr/bin/env bash
# P004-S002/M02: prova reversível de gateway_mtu no lab MGC próprio.
# Executar como root no host vm-cilium com LAB_ROOT apontando ao labctl staged.
set -euo pipefail

case "${1:-}" in
  --dry-run) mode=dry ;;
  --execute) mode=execute ;;
  *) echo 'uso: LAB_ROOT=... bash m02.sh --dry-run|--execute' >&2; exit 2 ;;
esac
[[ "$#" -eq 1 ]] || { echo 'M02 aceita uma única opção' >&2; exit 2; }
: "${LAB_ROOT:?LAB_ROOT é obrigatório}"
export LAB_ROOT

# shellcheck source=../../../labctl/lib/common.sh
source "${LAB_ROOT}/lib/common.sh"
# shellcheck source=../../../labctl/labs/mgc.sh
source "${LAB_ROOT}/labs/mgc.sh"
require_cmd docker ip jq timeout nsenter tcpdump
[[ "$(id -u)" -eq 0 ]] || { echo 'M02 exige root' >&2; exit 1; }

labctl="${LAB_ROOT}/labctl"
central=ovn-central-az1
tenant_chassis=ovn-chassis-1
tenant_ns=mgc-tenant-vm
tenant_if=mgc-tenant-vm
tenant_tap=mgc-tenant-vm-p
client=mgc-client-1
destination=10.0.0.1
gateway_ports=(lrp-mgc-100-external lrp-mgc-200-external)
containers=(mgc-client-1 ovn-gw-1 ovn-gw-2 ovn-chassis-1 ovn-chassis-2)
interfaces=(eth1 eth2)
declare -a links=() capture_pids=() capture_logs=()
capture_dir=""
changed=0
capture_timeout=35

say() { printf 'M02 %s\n' "$*"; }
fail() { say "FAIL: $*" >&2; exit 1; }

assert_owned_running() {
  mgc_assert_no_extra_ovn_containers
  mgc_assert_cluster_ownership
  mgc_assert_bridges_owned
  mgc_assert_client_ownership "$client"
  for name in "$central" "${containers[@]}"; do
    [[ "$(docker inspect -f '{{.State.Running}}' "$name")" == true ]] \
      || fail "$name não está ativo"
  done
  [[ "$(awk '/^MemAvailable:/ {print int($2 / 1024 / 1024)}' /proc/meminfo)" -ge 4 ]] \
    || fail 'MemAvailable abaixo de 4 GiB'
  for port in "${gateway_ports[@]}"; do
    local options
    options="$(timeout --kill-after=2s 15s docker exec "$central" \
      ovn-nbctl get logical_router_port "$port" options)"
    [[ "$options" == *'gateway_mtu="1500"'* ]] \
      || fail "$port não está no baseline gateway_mtu=1500: $options"
  done
}

host_peer_for() {
  local container="$1" iface="$2" index peer
  index="$(docker exec "$container" cat "/sys/class/net/${iface}/iflink")"
  [[ "$index" =~ ^[1-9][0-9]*$ ]] || fail "iflink inválido: $container/$iface"
  peer="$(ip -j -d link show | jq -er --argjson idx "$index" '
    [.[] | select(.ifindex == $idx and .master == "ovs-system" and
      .linkinfo.info_kind == "veth") | .ifname] |
    if length == 1 then .[0] else error("peer MGC não único") end')" \
    || fail "peer host-side não identificado: $container/$iface"
  [[ "$peer" == *_l ]] || fail "peer sem formato esperado: $container/$iface -> $peer"
  printf '%s\n' "$peer"
}

collect_links() {
  local container iface peer inside_mtu host_mtu
  for container in "${containers[@]}"; do
    for iface in "${interfaces[@]}"; do
      peer="$(host_peer_for "$container" "$iface")"
      inside_mtu="$(docker exec "$container" cat "/sys/class/net/${iface}/mtu")"
      host_mtu="$(cat "/sys/class/net/${peer}/mtu")"
      [[ "$inside_mtu" == 1500 && "$host_mtu" == 1500 ]] \
        || fail "MTU baseline inesperado: $container/$iface=$inside_mtu host/$peer=$host_mtu"
      links+=("$container|$iface|$peer")
      say "baseline $container/$iface <-> host/$peer: MTU 1500"
    done
  done
  inside_mtu="$(docker exec "$tenant_chassis" ip netns exec "$tenant_ns" \
    cat "/sys/class/net/${tenant_if}/mtu")"
  host_mtu="$(docker exec "$tenant_chassis" cat "/sys/class/net/${tenant_tap}/mtu")"
  [[ "$inside_mtu" == 1500 && "$host_mtu" == 1500 ]] \
    || fail "MTU baseline VM tenant inesperado: $inside_mtu/$host_mtu"
  say "baseline VM tenant $tenant_if/$tenant_tap: MTU 1500"
}

set_links_mtu() {
  local phase="$1" spec container iface peer mtu rc=0
  for spec in "${links[@]}"; do
    IFS='|' read -r container iface peer <<<"$spec"
    mtu=1500
    if [[ "$phase" == jumbo ]]; then
      mtu=9000
      if [[ "$container" != "$client" && "$iface" == eth1 ]]; then
        mtu=9200
      fi
    fi
    ip link set dev "$peer" mtu "$mtu" || rc=1
    docker exec "$container" ip link set dev "$iface" mtu "$mtu" || rc=1
  done
  mtu=1500
  [[ "$phase" == jumbo ]] && mtu=9000
  docker exec "$tenant_chassis" ip link set dev "$tenant_tap" mtu "$mtu" || rc=1
  docker exec "$tenant_chassis" ip netns exec "$tenant_ns" \
    ip link set dev "$tenant_if" mtu "$mtu" || rc=1
  return "$rc"
}

assert_links_mtu() {
  local phase="$1" spec container iface peer actual mtu
  for spec in "${links[@]}"; do
    IFS='|' read -r container iface peer <<<"$spec"
    mtu=1500
    if [[ "$phase" == jumbo ]]; then
      mtu=9000
      if [[ "$container" != "$client" && "$iface" == eth1 ]]; then
        mtu=9200
      fi
    fi
    actual="$(cat "/sys/class/net/${peer}/mtu")"
    [[ "$actual" == "$mtu" ]] || fail "host/$peer MTU=$actual, esperado $mtu"
    actual="$(docker exec "$container" cat "/sys/class/net/${iface}/mtu")"
    [[ "$actual" == "$mtu" ]] || fail "$container/$iface MTU=$actual, esperado $mtu"
  done
  mtu=1500
  [[ "$phase" == jumbo ]] && mtu=9000
  actual="$(docker exec "$tenant_chassis" cat "/sys/class/net/${tenant_tap}/mtu")"
  [[ "$actual" == "$mtu" ]] || fail "$tenant_tap MTU=$actual, esperado $mtu"
  actual="$(docker exec "$tenant_chassis" ip netns exec "$tenant_ns" \
    cat "/sys/class/net/${tenant_if}/mtu")"
  [[ "$actual" == "$mtu" ]] || fail "$tenant_if MTU=$actual, esperado $mtu"
  say "pernas MGC selecionadas: fase $phase, MTU interno/externo $mtu"
}

set_gateway_mtu() {
  local mtu="$1" port rc=0
  for port in "${gateway_ports[@]}"; do
    timeout --kill-after=2s 20s docker exec "$central" ovn-nbctl --wait=sb \
      set logical_router_port "$port" "options:gateway_mtu=$mtu" || rc=1
    say "$port gateway_mtu=$mtu"
  done
  return "$rc"
}

assert_gateway_flows() {
  local mtu="$1" threshold port router flows file
  threshold=$((mtu + 18))
  for port in "${gateway_ports[@]}"; do
    router="${port%-external}"
    router="${router/lrp-/lr-}"
    file="${capture_dir}/flows-${mtu}-${router}.txt"
    flows="$(timeout --kill-after=2s 15s docker exec "$central" \
      ovn-sbctl lflow-list "$router")"
    printf '%s\n' "$flows" >"$file"
    grep -Fq "check_pkt_larger(${threshold})" "$file" \
      || fail "$router sem check_pkt_larger(${threshold})"
    grep -Fq "icmp4.frag_mtu = ${mtu}" "$file" \
      || fail "$router sem ICMP Frag Needed MTU ${mtu}"
    say "SB $router: check_pkt_larger(${threshold}), ICMP Frag Needed ${mtu}"
  done
}

stop_capture() {
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

start_capture() {
  local label="$1" spec name container iface pid logfile filter
  local -a points=(
    "tenant-tap|ovn-chassis-1|mgc-tenant-vm-p"
    "gw1-underlay|ovn-gw-1|eth1"
    "gw2-underlay|ovn-gw-2|eth1"
    "gw1-external|ovn-gw-1|eth2"
    "gw2-external|ovn-gw-2|eth2"
    "client-eth1|mgc-client-1|eth1"
    "client-eth2|mgc-client-1|eth2"
  )
  capture_logs=()
  for spec in "${points[@]}"; do
    IFS='|' read -r name container iface <<<"$spec"
    pid="$(docker inspect -f '{{.State.Pid}}' "$container")"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || fail "PID inválido: $container"
    logfile="${capture_dir}/${label}-${name}.txt"
    capture_logs+=("$logfile")
    filter=icmp
    [[ "$name" == *underlay ]] && filter='icmp or udp port 6081'
    timeout --foreground --signal=TERM --kill-after=2s "${capture_timeout}s" \
      nsenter -t "$pid" -n tcpdump -nn -e -vv -l -s 0 -i "$iface" "$filter" \
      >"$logfile" 2>&1 &
    capture_pids+=("$!")
  done
  sleep 1
  for pid in "${capture_pids[@]}"; do
    kill -0 "$pid" 2>/dev/null || fail "captura $label encerrou antes do probe"
  done
}

show_capture() {
  local logfile
  for logfile in "${capture_logs[@]}"; do
    say "captura $(basename "$logfile")"
    sed -n '1,120p' "$logfile"
  done
}

probe() {
  local label="$1" payload="$2" expected="$3" output rc=0
  say "probe $label: ping -M do -s $payload, destino $destination"
  start_capture "$label"
  output="$(docker exec "$tenant_chassis" ip netns exec "$tenant_ns" \
    ping -M 'do' -s "$payload" -c 30 -i 0.1 -W 2 "$destination" 2>&1)" || rc=$?
  sleep 1
  stop_capture
  printf '%s\n' "$output"
  show_capture
  if [[ "$payload" == 8972 ]]; then
    grep -Fq 'length 9014:' "${capture_dir}/${label}-tenant-tap.txt" \
      || fail "$label sem quadro de 9014 B no tap tenant"
    grep -Fq 'length 9000' "${capture_dir}/${label}-tenant-tap.txt" \
      || fail "$label sem pacote IPv4 de 9000 B no tap tenant"
  fi
  if [[ "$expected" == pass ]]; then
    [[ "$rc" -eq 0 && ( "$output" == *'30 packets transmitted, 30 packets received, 0% packet loss'* \
      || "$output" == *'30 packets transmitted, 30 received, 0% packet loss'* ) ]] \
      || fail "$label não passou 30/30 (rc=$rc)"
    if [[ "$payload" == 8972 ]]; then
      grep -Fq 'length 9014:' \
        "${capture_dir}/${label}-client-eth1.txt" \
        "${capture_dir}/${label}-client-eth2.txt" \
        || fail "$label sem quadro de 9014 B no cliente"
      grep -Fq 'length 9000' \
        "${capture_dir}/${label}-client-eth1.txt" \
        "${capture_dir}/${label}-client-eth2.txt" \
        || fail "$label sem IPv4 9000 B no cliente"
      grep -Eq 'length 9014:|length 9018:' \
        "${capture_dir}/${label}-gw1-external.txt" \
        "${capture_dir}/${label}-gw2-external.txt" \
        || fail "$label sem quadro jumbo na saída externa do gateway"
      grep -Fq 'length 9000' \
        "${capture_dir}/${label}-gw1-external.txt" \
        "${capture_dir}/${label}-gw2-external.txt" \
        || fail "$label sem IPv4 9000 B na saída externa do gateway"
    fi
  else
    [[ "$rc" -ne 0 ]] || fail "$label passou, mas era esperado bloqueio PMTU"
    [[ -f "${capture_dir}/${label}-tenant-tap.txt" ]] \
      || fail "$label sem captura no tap tenant"
    grep -Eiq 'need to frag|fragmentation needed|packet too big' \
      "${capture_dir}/${label}-tenant-tap.txt" \
      || fail "$label falhou sem ICMP PMTU observado no tap tenant"
    grep -Eq '10\.(100|200)\.100\.2' \
      "${capture_dir}/${label}-tenant-tap.txt" \
      || fail "$label sem ICMP PMTU originado no router de conexão"
    if grep -Fq 'length 9000' \
      "${capture_dir}/${label}-gw1-external.txt" \
      "${capture_dir}/${label}-gw2-external.txt" \
      "${capture_dir}/${label}-client-eth1.txt" \
      "${capture_dir}/${label}-client-eth2.txt"; then
      fail "$label escapou da decisão de gateway_mtu=1500"
    fi
    say "$label: PMTU gerado no pipeline lógico antes do underlay; jumbo ausente em gateway/cliente"
  fi
  say "probe $label $expected confirmado"
}

restore() {
  local rc=$?
  trap - EXIT INT TERM
  stop_capture
  if [[ "$changed" == 1 ]]; then
    say 'restauração: gateway_mtu e MTUs do MGC para 1500'
    set_gateway_mtu 1500 || rc=1
    set_links_mtu baseline || rc=1
    "$labctl" mgc up || rc=1
    "$labctl" mgc verify || rc=1
    assert_links_mtu baseline || rc=1
  fi
  if [[ "$rc" -ne 0 ]]; then
    say "falha; capturas preservadas em $capture_dir" >&2
  else
    say "PASS: M02 concluído e MGC restaurado; capturas em $capture_dir"
  fi
  exit "$rc"
}

assert_owned_running
collect_links
if [[ "$mode" == dry ]]; then
  say 'DRY: labctl mgc verify; nenhuma alteração neste modo'
  say 'DRY: elevar somente os peers veth MGC identificados; MTU 9000 nas pernas internas/externas e 9200 no underlay Geneve eth1 de gw/chassis'
  say 'DRY: capturar ICMP no tap tenant, saídas gw1/gw2 e cliente; Geneve/ICMP no underlay gw1/gw2'
  say 'DRY: com gateway_mtu=1500, controle pequeno passa e IPv4 9000 B/DF recebe ICMP Frag Needed no tap'
  say 'DRY: com gateway_mtu=9000, controle pequeno e IPv4 9000 B/DF passam'
  say 'DRY: trap restaura gateway_mtu/MTUs 1500, labctl mgc up/verify; capturas preservadas'
  exit 0
fi

"$labctl" mgc verify
capture_dir="${M02_CAPTURE_EVIDENCE_DIR:-/var/tmp/labctl/mgc/m02-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
mkdir -p "$(dirname "$capture_dir")"
mkdir -m 700 "$capture_dir" || fail "diretório de captura já existe: $capture_dir"
trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

changed=1
set_links_mtu jumbo
assert_links_mtu jumbo
assert_gateway_flows 1500
probe small-1500 1400 pass
probe jumbo-1500 8972 fail
set_gateway_mtu 9000
docker exec "$tenant_chassis" ip netns exec "$tenant_ns" ip route flush cache
assert_gateway_flows 9000
probe small-9000 1400 pass
probe jumbo-9000 8972 pass
