#!/usr/bin/env bash
set -euo pipefail
umask 077

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
student_lab_dir="$(cd -- "${test_dir}/.." && pwd -P)"
scratch="${P010_HYBRID_API_TEST_SCRATCH:?}"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-ansible-playbook}"
bin_dir="${scratch}/dora-bin"
mkdir -m 0700 -p "${bin_dir}"

fail() {
  printf 'test-hybrid-m11-dora-producer: %s\nLOG_DIR=%s\n' "$1" "${scratch}" >&2
  exit 1
}

cat >"${bin_dir}/stat" <<'STAT'
#!/bin/sh
set -eu
[ "$1" = -c ] || exit 64
format=$2
path=$3
case "$format" in
  '%d|%i|%u|%a') exec /usr/bin/stat -f '%d|%i|%u|%Lp' "$path" ;;
  '%u|%a') exec /usr/bin/stat -f '%u|%Lp' "$path" ;;
  *) exit 65 ;;
esac
STAT
cat >"${bin_dir}/sha256sum" <<'SHA256'
#!/bin/sh
set -eu
/usr/bin/shasum -a 256 "$1"
SHA256
cat >"${bin_dir}/base64" <<'BASE64'
#!/bin/sh
set -eu
[ "$1" = -w0 ] || exit 66
/usr/bin/base64 "$2" | tr -d '\n'
BASE64
chmod 0700 "${bin_dir}/stat" "${bin_dir}/sha256sum" "${bin_dir}/base64"

record_attempt() {
  local name="$1" started="$2" rc="$3" argv_json="$4" log="$5"
  cat >"${scratch}/${name}.receipt.json" <<EOF
{
  "started_utc": "${started}",
  "argv": ${argv_json},
  "rc": ${rc},
  "log": "${log}"
}
EOF
}

append_packet() {
  local stamp="$1" ethernet_source="$2" xid="$3" message="$4" server_id="$5" your_ip="$6" requested="$7"
  local client_mac='02:00:00:00:00:02' ethernet_destination='ff:ff:ff:ff:ff:ff'
  if [ "$message" = OFFER ] || [ "$message" = ACK ]; then ethernet_source='02:00:00:00:00:01'; fi
  printf '%s %s > %s, ethertype IPv4 (0x0800), length 330: (tos 0x0, ttl 64, id 1, offset 0, flags [none], proto UDP (17), length 316)\n' \
    "$stamp" "$ethernet_source" "$ethernet_destination" >>"${capture}"
  printf '    0.0.0.0.68 > 255.255.255.255.67: BOOTP/DHCP, Request from %s, xid %s, length 300\n' \
    "$client_mac" "$xid" >>"${capture}"
  printf '          Client-Ethernet-Address %s\n' "$client_mac" >>"${capture}"
  printf '          DHCP-Message (53), length 1: %s\n' "$message" >>"${capture}"
  [ -z "$server_id" ] || printf '          Server-ID (54), length 4: %s\n' "$server_id" >>"${capture}"
  [ -z "$your_ip" ] || printf '          Your-IP %s\n' "$your_ip" >>"${capture}"
  [ -z "$requested" ] || printf '          Requested-IP (50), length 4: %s\n' "$requested" >>"${capture}"
  if [ "$message" = OFFER ] || [ "$message" = ACK ]; then
    printf '          Default-Gateway (3), length 4: 198.18.49.1\n' >>"${capture}"
  fi
}

write_capture() {
  local variant="$1"
  local ack_xid='0x1234abcd' ack_server='198.18.49.2' request_ip='198.18.49.4' dropped='0'
  : >"${capture}"
  case "$variant" in
    wrong_ack_xid) ack_xid='0x87654321' ;;
    wrong_server) ack_server='198.18.49.99' ;;
    missing_requested_ip) request_ip='' ;;
    dropped) dropped='1' ;;
  esac
  if [ "$variant" = renewal ]; then
    append_packet '12:00:00.000000' '02:00:00:00:00:02' '0x1234abcd' REQUEST "$ack_server" '' 198.18.49.4
    append_packet '12:00:00.010000' '02:00:00:00:00:01' '0x1234abcd' ACK "$ack_server" 198.18.49.4 ''
    captured=2
  else
    append_packet '12:00:00.000000' '02:00:00:00:00:02' '0x1234abcd' DISCOVER '' '' ''
    append_packet '12:00:00.010000' '02:00:00:00:00:02' '0x1234abcd' DISCOVER '' '' ''
    append_packet '12:00:00.020000' '02:00:00:00:00:01' '0x1234abcd' OFFER 198.18.49.2 198.18.49.4 ''
    append_packet '12:00:00.030000' '02:00:00:00:00:02' '0x1234abcd' REQUEST 198.18.49.2 '' "$request_ip"
    append_packet '12:00:00.040000' '02:00:00:00:00:02' '0x1234abcd' REQUEST 198.18.49.2 '' "$request_ip"
    append_packet '12:00:00.050000' '02:00:00:00:00:01' "$ack_xid" ACK "$ack_server" 198.18.49.4 ''
    captured=6
  fi
  printf '\n%d packets captured\n%d packets received by filter\n%d packets dropped by kernel\n' \
    "$captured" "$((captured + 2))" "$dropped" >>"${capture}"
  chmod 0600 "${capture}"
}

run_case() {
  local name="$1" variant="$2" command_rc="$3" expected="$4"
  local started capture_rc stat_capture stat_result script render_log shell_log argv_json result rc render_rc
  started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  capture="${scratch}/dora-${name}.log"
  result="${scratch}/dora-${name}.result"
  script="${scratch}/dora-${name}.sh"
  render_log="${scratch}/dora-${name}-render.log"
  shell_log="${scratch}/dora-${name}-run.log"
  write_capture "$variant"
  : >"${result}"
  chmod 0600 "${result}"
  stat_capture="$(stat -f '%d|%i|%u|%Lp' "${capture}")"
  stat_result="$(stat -f '%d|%i|%u|%Lp' "${result}")"
  capture_rc="$command_rc"
  {
    printf 'P010_DHCP_READY=1\n'
    printf 'P010_DHCP_PID=321\nP010_DHCP_STARTTIME=111111\nP010_DHCP_UID=0\nP010_DHCP_NETNS=net:[4026531840]\nP010_DHCP_IFINDEX=5\n'
    printf 'P010_DHCP_TCPDUMP_PID=322\nP010_DHCP_TCPDUMP_STARTTIME=222222\nP010_DHCP_TCPDUMP_UID=0\nP010_DHCP_TCPDUMP_NETNS=net:[4026531840]\n'
    printf 'P010_DHCP_STARTED_UTC=2026-10-30T12:00:00Z\nP010_DHCP_COMPLETED_UTC=2026-10-30T12:00:01Z\n'
    printf 'P010_DHCP_EXIT_RC=%s\n' "$capture_rc"
    if [ "$capture_rc" = 130 ]; then printf 'P010_DHCP_STOP_REQUESTED_UTC=2026-10-30T12:00:01Z\n'; fi
  } >"${result}"
  export P010_HYBRID_DORA_CAPTURE="${capture}"
  export P010_HYBRID_DORA_RESULT="${result}"
  export P010_HYBRID_DORA_CAPTURE_STAT="${stat_capture}"
  export P010_HYBRID_DORA_RESULT_STAT="${stat_result}"
  export P010_HYBRID_DORA_COUNT="${captured}"
  export P010_HYBRID_DORA_SCRIPT="${script}"
  export P010_HYBRID_DORA_CAPTURE_RC="${capture_rc}"
  if [ "$capture_rc" = 130 ]; then export P010_HYBRID_DORA_STOP_REQUESTED=true; else export P010_HYBRID_DORA_STOP_REQUESTED=false; fi
  set +e
  env ANSIBLE_CONFIG="${student_lab_dir}/ansible.cfg" PYTHONDONTWRITEBYTECODE=1 \
    "${ansible_playbook_bin}" -i localhost, "${student_lab_dir}/tests/hybrid-m11-render-dora-script.yml" >"${render_log}" 2>&1
  render_rc=$?
  set -e
  record_attempt "dora-${name}-render" "$started" "$render_rc" "[\"${ansible_playbook_bin}\", \"-i\", \"localhost,\", \"${student_lab_dir}/tests/hybrid-m11-render-dora-script.yml\"]" "$render_log"
  if [ "$render_rc" -ne 0 ]; then
    fail "não renderizou o parser DORA para ${name}."
  fi
  argv_json="[\"bash\", \"${script}\"]"
  set +e
  PATH="${bin_dir}:$PATH" bash "${script}" >"${shell_log}" 2>&1
  rc=$?
  set -e
  record_attempt "dora-${name}" "$started" "$rc" "$argv_json" "$shell_log"
  if [ "$expected" = accept ] && [ "$rc" -ne 0 ]; then fail "parser rejeitou ${name}; rc=${rc}."; fi
  if [ "$expected" = reject ] && [ "$rc" -eq 0 ]; then fail "parser aceitou ${name} inesperadamente."; fi
  if [ "$name" = retries-positive ]; then
    grep -Fxq 'P010_DORA_XID=0x1234abcd' "${shell_log}" || fail 'resultado perdeu o XID de 32 bits.'
    grep -Fxq 'P010_DORA_EVENT_INDEXES=1,3,4,6' "${shell_log}" || fail 'parser não selecionou a sequência DORA após as retransmissões.'
    grep -Fxq 'P010_DORA_CAPTURED_COUNT=6' "${shell_log}" || fail 'contador de captura não foi preservado.'
    grep -Fxq 'P010_DORA_DROPPED_COUNT=0' "${shell_log}" || fail 'contador de perdas não foi preservado.'
  fi
  if [ "$name" = controlled-stop ]; then
    grep -Fxq 'P010_DORA_CAPTURE_RC=130' "${shell_log}" || fail 'rc de encerramento controlado não foi preservado.'
    grep -Fxq 'P010_DORA_DROPPED_COUNT=0' "${shell_log}" || fail 'contador de perdas não foi preservado no encerramento controlado.'
  fi
}

run_case retries-positive positive 0 accept
run_case controlled-stop positive 130 accept
run_case mixed-xid wrong_ack_xid 0 reject
run_case wrong-server wrong_server 0 reject
run_case missing-requested-ip missing_requested_ip 0 reject
run_case renewal-only renewal 0 reject
run_case kernel-drop dropped 0 reject
run_case command-timeout positive 124 reject

printf 'PASS: DORA real render/reader seleciona retransmissões ordenadas por chaddr/XID, confere endpoints e rejeita transações incompletas ou perda/timeout.\n'
