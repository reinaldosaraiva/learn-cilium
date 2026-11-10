#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
student_lab_dir="$(cd -- "${test_dir}/.." && pwd -P)"
scratch="${P010_HYBRID_API_TEST_SCRATCH:?}"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-ansible-playbook}"
test_uid="$(id -u)"

fail() {
  printf 'test-hybrid-m11-stop-captures: %s\n' "$1" >&2
  exit 1
}

mkdir -m 0700 -p "${scratch}/stop-capture-bin"
origin_capture="${scratch}/origin-capture.log"
test_run_id="stop-${test_uid}-$$"
dhcp_capture="/tmp/p010-${test_run_id}-dhcp.log"
dhcp_result="/tmp/p010-${test_run_id}-dhcp.result"
origin_script="${scratch}/origin-stop.sh"
dhcp_script="${scratch}/dhcp-stop.sh"
: >"${origin_capture}"
: >"${dhcp_capture}"
: >"${dhcp_result}"
chmod 0600 "${origin_capture}" "${dhcp_capture}"
chmod 0600 "${dhcp_result}"
export P010_HYBRID_TEST_RUN_ID="${test_run_id}"
export P010_HYBRID_ORIGIN_CAPTURE="${origin_capture}"
export P010_HYBRID_DHCP_CAPTURE="${dhcp_capture}"
export P010_HYBRID_DHCP_RESULT="${dhcp_result}"
export P010_HYBRID_ORIGIN_SCRIPT="${origin_script}"
export P010_HYBRID_DHCP_SCRIPT="${dhcp_script}"

if ! "${ansible_playbook_bin}" -i localhost, "${student_lab_dir}/tests/hybrid-m11-render-stop-capture-scripts.yml" >"${scratch}/stop-capture-render.log" 2>&1; then
  cat "${scratch}/stop-capture-render.log" >&2
  fail 'scripts Bash de produção não renderizaram com as identidades registradas.'
fi

fake_bin="${scratch}/stop-capture-bin"
cat >"${fake_bin}/sudo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -n ]] && shift
exec "$@"
SH
cat >"${fake_bin}/awk" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FAKE_PROC_AWK_FAIL:-0}" == 1 ]]; then
  exit 69
fi
exec /usr/bin/awk "$@"
SH
cat >"${fake_bin}/stat" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${2:-}" in
  %u) printf '%s\n' "${FAKE_PROC_UID:?}" ;;
  *) printf '%s\n' "${FAKE_CAPTURE_STAT:?}" ;;
esac
SH
cat >"${fake_bin}/cat" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
proc_pid="${1%/cmdline}"
proc_pid="${proc_pid##*/}"
if [[ -n "${FAKE_TCPDUMP_PID:-}" && "${proc_pid}" == "${FAKE_TCPDUMP_PID}" ]]; then
  printf '%s' "${FAKE_TCPDUMP_CMDLINE:?}"
elif [[ -n "${FAKE_SUPERVISOR_PID:-}" && "${proc_pid}" == "${FAKE_SUPERVISOR_PID}" ]]; then
  printf '%s' "${FAKE_SUPERVISOR_CMDLINE:-fake supervisor}"
else
  printf '%s' "${FAKE_PROC_CMDLINE:?}"
fi
SH
cat >"${fake_bin}/kill" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_KILL_LOG:?}"
for proc_pid in "$2"; do
  rm -f -- "${FAKE_PROC_ROOT:?}/${proc_pid}/stat" "${FAKE_PROC_ROOT}/${proc_pid}/cmdline"
done
if [[ -n "${FAKE_TCPDUMP_PID:-}" && "${2:-}" == "${FAKE_TCPDUMP_PID}" ]]; then
  for proc_pid in "${FAKE_LAUNCHER_PID:?}" "${FAKE_SUPERVISOR_PID:?}"; do
    rm -f -- "${FAKE_PROC_ROOT}/${proc_pid}/stat" "${FAKE_PROC_ROOT}/${proc_pid}/cmdline"
  done
fi
SH
cat >"${fake_bin}/readlink" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${FAKE_PROC_NETNS:?}"
SH
chmod 0700 "${fake_bin}/sudo" "${fake_bin}/awk" "${fake_bin}/stat" "${fake_bin}/cat" "${fake_bin}/kill" "${fake_bin}/readlink"

rewrite_for_local_process_fakes() {
  local source="$1" destination="$2"
  sed \
    -e 's|proc_root=/proc|proc_root="$FAKE_PROC_ROOT"|' \
    -e "s|/usr/bin/sudo|${fake_bin}/sudo|g" \
    -e "s|/usr/bin/awk|${fake_bin}/awk|g" \
    -e "s|/usr/bin/stat|${fake_bin}/stat|g" \
    -e "s|/usr/bin/cat|${fake_bin}/cat|g" \
    -e "s|/usr/bin/kill|${fake_bin}/kill|g" \
    -e "s|/usr/bin/readlink|${fake_bin}/readlink|g" \
    "${source}" >"${destination}"
  chmod 0700 "${destination}"
  bash -n "${destination}"
}

run_case() {
  local guest="$1" mode="$2" source_script="$3" capture="$4" pid="$5" expected_start="$6" actual_start="$7"
  local proc_root="${scratch}/proc-${guest}-${mode}" script="${scratch}/run-${guest}-${mode}.sh" output="${scratch}/run-${guest}-${mode}.out"
  local tcpdump_pid='' supervisor_pid='' signal_pid="${pid}" process_id actual_for_pid proc_stat expected_query_rc=69
  local -a process_ids=("${pid}")
  if [[ "${guest}" == dhcp ]]; then
    tcpdump_pid=4344
    supervisor_pid=4345
    signal_pid="${tcpdump_pid}"
    process_ids+=("${tcpdump_pid}" "${supervisor_pid}")
    expected_query_rc=92
  fi
  rm -rf -- "${proc_root}"
  for process_id in "${process_ids[@]}"; do
    mkdir -m 0700 -p "${proc_root}/${process_id}"
  done
  : >"${capture}"
  chmod 0600 "${capture}"
  if [[ "${guest}" == dhcp ]]; then
    printf 'P010_DHCP_EXIT_RC=130\nP010_DHCP_COMPLETED_UTC=2026-10-30T12:00:01Z\n' >"${dhcp_result}"
    chmod 0600 "${dhcp_result}"
  fi
  if [[ "${mode}" == absent ]]; then
    for process_id in "${process_ids[@]}"; do
      rm -rf -- "${proc_root}/${process_id}"
    done
  else
    for process_id in "${process_ids[@]}"; do
      case "${process_id}" in
        "${pid}") actual_for_pid="${actual_start}" ;;
        "${tcpdump_pid}") actual_for_pid=23457 ;;
        "${supervisor_pid}") actual_for_pid=23458 ;;
      esac
      if [[ "${mode}" == mismatch && "${guest}" == dhcp && "${process_id}" != "${pid}" ]]; then
        actual_for_pid=22222
      fi
      proc_stat="${process_id} (tcpdump (worker)) S"
      for _ in {1..16}; do
        proc_stat+=" 0"
      done
      proc_stat+=" 1 0 ${actual_for_pid}"
      printf '%s\n' "${proc_stat}" >"${proc_root}/${process_id}/stat"
      printf 'fake cmdline\n' >"${proc_root}/${process_id}/cmdline"
    done
  fi
  export FAKE_PROC_ROOT="${proc_root}"
  export FAKE_PROC_UID="${test_uid}"
  export FAKE_LAUNCHER_PID="${pid}"
  export FAKE_TCPDUMP_PID="${tcpdump_pid}"
  export FAKE_SUPERVISOR_PID="${supervisor_pid}"
  export FAKE_PROC_NETNS='net:[205:600]'
  export FAKE_CAPTURE_STAT="$(sed -n "s/^expected_file='\(.*\)'$/\1/p" "${source_script}")"
  export FAKE_KILL_LOG="${scratch}/kill-${guest}-${mode}.log"
  : >"${FAKE_KILL_LOG}"
  export FAKE_PROC_AWK_FAIL=0
  case "${guest}" in
    origin)
      export FAKE_PROC_CMDLINE='/usr/bin/timeout --foreground 60 /usr/sbin/tcpdump -n -l -vv -c 1 -i tenant0 src host 198.18.49.3 and dst host 10.246.1.20 and tcp dst port 8080'
      ;;
    dhcp)
      export FAKE_PROC_CMDLINE='/usr/bin/timeout 120 /usr/sbin/tcpdump -n -e -vv -l -c 32 -i tenant0 udp and (port 67 or port 68)'
      export FAKE_TCPDUMP_CMDLINE='/usr/sbin/tcpdump -n -e -vv -l -c 32 -i tenant0 udp and (port 67 or port 68)'
      export FAKE_SUPERVISOR_CMDLINE='fake DHCP capture supervisor'
      ;;
  esac
  rewrite_for_local_process_fakes "${source_script}" "${script}"
  if [[ "${mode}" == query-fail ]]; then
    export FAKE_PROC_AWK_FAIL=1
    set +e
    PATH="${fake_bin}:${PATH}" bash "${script}" >"${output}" 2>&1
    local result=$?
    set -e
    [[ "${result}" == "${expected_query_rc}" ]] || fail "${guest}: consulta /proc inconclusiva retornou ${result}, esperava rc${expected_query_rc}."
    [[ -f "${capture}" ]] || fail "${guest}: falha de leitura removeu a captura registrada."
    [[ "${guest}" != dhcp || -f "${dhcp_result}" ]] || fail "dhcp: falha de leitura removeu o resultado registrado."
    [[ ! -s "${FAKE_KILL_LOG}" ]] || fail "${guest}: consulta falha sinalizou processo."
    return 0
  fi
  PATH="${fake_bin}:${PATH}" bash "${script}" >"${output}" 2>&1 \
    || { cat "${output}" >&2; fail "${guest}/${mode}: script renderizado falhou."; }
  grep -Fq 'P010_M11_' "${output}" || fail "${guest}/${mode}: marcador de ausência não foi emitido."
  [[ ! -e "${capture}" ]] || fail "${guest}/${mode}: captura própria não foi removida."
  [[ "${guest}" != dhcp || ! -e "${dhcp_result}" ]] || fail "dhcp/${mode}: arquivo de resultado próprio não foi removido."
  if [[ "${mode}" == matching ]]; then
    grep -Fq -- "-INT ${signal_pid}" "${FAKE_KILL_LOG}" || fail "${guest}: PID/starttime próprios não receberam SIGINT."
  else
    [[ ! -s "${FAKE_KILL_LOG}" ]] || fail "${guest}/${mode}: PID divergente ou ausente foi sinalizado."
  fi
}

run_case origin query-fail "${origin_script}" "${origin_capture}" 4242 12345 12345
run_case origin absent "${origin_script}" "${origin_capture}" 4242 12345 12345
run_case origin mismatch "${origin_script}" "${origin_capture}" 4242 1 22222
run_case origin matching "${origin_script}" "${origin_capture}" 4242 12345 12345
run_case dhcp query-fail "${dhcp_script}" "${dhcp_capture}" 4343 23456 23456
run_case dhcp absent "${dhcp_script}" "${dhcp_capture}" 4343 23456 23456
run_case dhcp mismatch "${dhcp_script}" "${dhcp_capture}" 4343 1 22222
run_case dhcp matching "${dhcp_script}" "${dhcp_capture}" 4343 23456 23456

printf 'PASS: scripts Bash renderizados preservam intenção em falha de consulta, aceitam apenas ausência comprovada e sinalizam somente PID/starttime próprios.\n'
