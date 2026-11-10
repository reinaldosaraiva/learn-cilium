#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
student_lab="$(cd -- "${script_dir}/.." && pwd -P)"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-$(command -v ansible-playbook || true)}"
scratch="${P010_HYBRID_TAP_INTENT_SCRATCH:-$(mktemp -d /tmp/p010-hybrid-tap-intent.XXXXXX)}"

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
[[ "$*" == '-j -d link show' ]] || exit 53
if [[ "${P010_HYBRID_INTENT_RC:-0}" != 0 ]]; then
  printf 'query unavailable\n' >&2
  exit "$P010_HYBRID_INTENT_RC"
fi
cat "$P010_HYBRID_INTENT_JSON"
EOF
chmod 0700 "$scratch/fake-bin/nsenter" "$scratch/fake-bin/ip"

printf '[]\n' >"$scratch/absent.json"
cat >"$scratch/present.json" <<'EOF'
[{"ifindex":45,"ifname":"p10tabcdef01","ifalias":"","linkinfo":{"info_kind":"tun","info_data":{"type":"tap"}}}]
EOF
printf '[{"ifindex":46,"ifname":"other0","ifalias":"p010-hyb-%s-20261029-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","linkinfo":{"info_kind":"tun","info_data":{"type":"tap"}}}]\n' "$(id -u)" >"$scratch/alias-collision.json"
printf 'not-json\n' >"$scratch/malformed.json"

"$ansible_playbook_bin" --syntax-check -i localhost, "$script_dir/hybrid-tap-create-intent.yml" \
  >"$scratch/syntax.log" 2>&1 || fail 'syntax-check do teste de TAP create intent falhou.'

run_case() {
  local case_name="$1" fixture="$2" rc="$3" expected="$4" result_rc
  if env \
    P010_HYBRID_INTENT_NSENTER="$scratch/fake-bin/nsenter" \
    P010_HYBRID_INTENT_IP="$scratch/fake-bin/ip" \
    P010_HYBRID_INTENT_JSON="$fixture" \
    P010_HYBRID_INTENT_RC="$rc" \
    P010_HYBRID_INTENT_CASE="$case_name" \
    P010_HYBRID_INTENT_UID="$(id -u)" \
    P010_HYBRID_INTENT_STATE="$scratch/$case_name/state.json" \
    "$ansible_playbook_bin" -i localhost, "$script_dir/hybrid-tap-create-intent.yml" \
    >"$scratch/$case_name.log" 2>&1; then
    result_rc=0
  else
    result_rc=$?
  fi
  [[ "$expected" == pass && "$result_rc" == 0 ]] || [[ "$expected" == fail && "$result_rc" != 0 ]] \
    || fail "TAP intent case $case_name returned rc=$result_rc; expected $expected."
}

run_case absent "$scratch/absent.json" 0 pass
run_case present "$scratch/present.json" 0 pass
run_case alias-collision "$scratch/alias-collision.json" 0 pass
run_case query-error "$scratch/absent.json" 44 pass
run_case malformed "$scratch/malformed.json" 0 pass

printf 'PASS: unresolved TAP create stays partial; only a successful empty namespace query is accepted.\n'
printf 'LOG_DIR=%s\n' "$scratch"
