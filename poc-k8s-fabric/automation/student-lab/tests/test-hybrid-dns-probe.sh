#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
student_lab="$(cd -- "${script_dir}/.." && pwd -P)"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-$(command -v ansible-playbook || true)}"
scratch="${P010_HYBRID_DNS_PROBE_SCRATCH:-$(mktemp -d /tmp/p010-hybrid-dns-probe.XXXXXX)}"

fail() {
  printf 'FAIL: %s\nLOG_DIR=%s\n' "$1" "$scratch" >&2
  exit 1
}

[[ -x "$ansible_playbook_bin" ]] || fail 'ansible-playbook ausente; passe ANSIBLE_PLAYBOOK_BIN.'
mkdir -m 0700 -p "$scratch/ansible-local" "$scratch/fake-bin"
export ANSIBLE_CONFIG="$student_lab/ansible.cfg"
export ANSIBLE_LOCAL_TEMP="$scratch/ansible-local"
export ANSIBLE_NOCOLOR=1

cat >"$scratch/fake-bin/nsenter" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == --net=* ]] || exit 51
shift
[[ "${1:-}" == -- ]] || exit 52
shift
exec "$@"
EOF
cat >"$scratch/fake-bin/ip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == route && "$2" == get && $# == 3 ]] || exit 53
if [[ "${P010_HYBRID_DNS_FAIL:-}" == route:"$3" ]]; then
  printf 'unreachable\n'
  exit 1
fi
printf '8.8.4.4 via 10.0.2.2 dev eth0 src 10.0.2.15\n'
EOF
cat >"$scratch/fake-bin/dig" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == '+time=2 +tries=1 +short A @'*' cloud-images.ubuntu.com' ]] || exit 54
resolver="${5#@}"
if [[ "${P010_HYBRID_DNS_FAIL:-}" == dig:"$resolver" ]]; then
  exit 9
fi
case "${P010_HYBRID_DNS_FAIL:-}" in
  empty) exit 0 ;;
  invalid) printf '999.2.3.4\n'; exit 0 ;;
esac
printf '93.184.216.34\n'
EOF
chmod 0700 "$scratch/fake-bin/nsenter" "$scratch/fake-bin/ip" "$scratch/fake-bin/dig"

"$ansible_playbook_bin" --syntax-check -i localhost, "$script_dir/hybrid-dns-probe.yml" \
  >"$scratch/syntax.log" 2>&1 || fail 'syntax-check do teste DNS direto falhou.'

run_case() {
  local case_name="$1" failure="$2" result_rc
  if env \
    P010_HYBRID_DNS_NSENTER="$scratch/fake-bin/nsenter" \
    P010_HYBRID_DNS_IP="$scratch/fake-bin/ip" \
    P010_HYBRID_DNS_DIG="$scratch/fake-bin/dig" \
    P010_HYBRID_DNS_CASE="$case_name" \
    P010_HYBRID_DNS_FAIL="$failure" \
    "$ansible_playbook_bin" -i localhost, "$script_dir/hybrid-dns-probe.yml" \
    >"$scratch/$case_name.log" 2>&1; then
    result_rc=0
  else
    result_rc=$?
  fi
  [[ "$result_rc" == 0 ]] || fail "DNS case $case_name was not handled as expected; rc=$result_rc."
}

run_case positive ''
run_case route-failure 'route:1.1.1.1'
run_case server-failure 'dig:192.168.50.1'
run_case no-answer empty
run_case invalid-answer invalid

printf 'PASS: direct DNS queries ran through the saved network namespace; route, timeout, empty, and invalid answers fail closed.\n'
printf 'LOG_DIR=%s\n' "$scratch"
