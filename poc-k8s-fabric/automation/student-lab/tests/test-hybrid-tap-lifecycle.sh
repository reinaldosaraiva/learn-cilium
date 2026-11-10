#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
repo_root="$(cd -- "${script_dir}/../../../" && pwd -P)"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-$(command -v ansible-playbook || true)}"
scratch="${P010_HYBRID_TAP_TEST_SCRATCH:-$(mktemp -d /tmp/p010-hybrid-tap-XXXXXX)}"

fail() {
  printf 'FAIL: %s\nLOG_DIR=%s\n' "$1" "$scratch" >&2
  exit 1
}

[[ -x "$ansible_playbook_bin" ]] || fail 'ansible-playbook ausente; passe ANSIBLE_PLAYBOOK_BIN.'
command -v jq >/dev/null 2>&1 || fail 'jq ausente; o harness local depende do jq já exigido pelo student-lab.'
mkdir -m 0700 -p "$scratch/fake-bin" "$scratch/ansible-local"
export ANSIBLE_CONFIG="$script_dir/ansible.cfg"
export ANSIBLE_NOCOLOR=1
export ANSIBLE_LOCAL_TEMP="$scratch/ansible-local"

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
printf '%s\n' "$*" >>"$P010_HYBRID_FAKE_IP_CALLS"
if [[ "$*" == '-j -d link show' ]]; then
  if [[ "${P010_HYBRID_FAKE_IP_QUERY_RC:-0}" != 0 ]]; then
    printf 'fake ip query failure\n' >&2
    exit "$P010_HYBRID_FAKE_IP_QUERY_RC"
  fi
  cat "$P010_HYBRID_FAKE_IP_JSON"
  exit 0
fi
case "$1 $2 $3" in
  'tuntap add dev')
    name="$4"
    [[ "$5 $6 $7" == 'mode tap user' ]] || exit 61
    index="${P010_HYBRID_FAKE_TAP_IFINDEX:-45}"
    entry="$(jq -cn --arg name "$name" --argjson index "$index" '{ifindex:$index,ifname:$name,ifalias:"",linkinfo:{info_kind:"tun",info_data:{type:"tap"}}}')"
    jq --argjson entry "$entry" '. + [$entry]' "$P010_HYBRID_FAKE_IP_JSON" >"$P010_HYBRID_FAKE_IP_JSON.tmp"
    mv -- "$P010_HYBRID_FAKE_IP_JSON.tmp" "$P010_HYBRID_FAKE_IP_JSON"
    ;;
  'link set dev')
    name="$4"
    case "$5" in
      alias)
        alias_value="$6"
        jq --arg name "$name" --arg alias "$alias_value" 'map(if .ifname == $name then .ifalias = $alias else . end)' "$P010_HYBRID_FAKE_IP_JSON" >"$P010_HYBRID_FAKE_IP_JSON.tmp"
        mv -- "$P010_HYBRID_FAKE_IP_JSON.tmp" "$P010_HYBRID_FAKE_IP_JSON"
        ;;
      up) ;;
      *) exit 62 ;;
    esac
    ;;
  'link del dev')
    name="$4"
    jq --arg name "$name" 'map(select(.ifname != $name))' "$P010_HYBRID_FAKE_IP_JSON" >"$P010_HYBRID_FAKE_IP_JSON.tmp"
    mv -- "$P010_HYBRID_FAKE_IP_JSON.tmp" "$P010_HYBRID_FAKE_IP_JSON"
    ;;
  *) exit 63 ;;
esac
EOF
chmod 0700 "$scratch/fake-bin/nsenter" "$scratch/fake-bin/ip"

"$ansible_playbook_bin" --syntax-check -i localhost, "$script_dir/tests/hybrid-tap-lifecycle.yml" \
  >"$scratch/syntax.log" 2>&1 || fail 'syntax-check do lifecycle fake da TAP falhou.'

run_case() {
  local case_name="$1" expected="$2" initial_json="$3" query_rc="$4" case_dir="$scratch/$1" rc
  mkdir -m 0700 -p "$case_dir"
  printf '%s\n' "$initial_json" >"$case_dir/links.json"
  : >"$case_dir/ip-calls.log"
  if env \
    P010_HYBRID_TEST_UID="$(id -u)" \
    P010_HYBRID_TAP_STATE_FILE="$case_dir/state.json" \
    P010_HYBRID_TAP_CHECKPOINT_FILE="$case_dir/after-create.json" \
    P010_HYBRID_FAKE_NSENTER="$scratch/fake-bin/nsenter" \
    P010_HYBRID_FAKE_IP="$scratch/fake-bin/ip" \
    P010_HYBRID_FAKE_IP_JSON="$case_dir/links.json" \
    P010_HYBRID_FAKE_IP_CALLS="$case_dir/ip-calls.log" \
    P010_HYBRID_FAKE_IP_QUERY_RC="$query_rc" \
    P010_HYBRID_TAP_LIFECYCLE_CASE="$case_name" \
    "$ansible_playbook_bin" -i localhost, "$script_dir/tests/hybrid-tap-lifecycle.yml" \
    >"$case_dir/ansible.log" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  if [[ "$expected" == pass && "$rc" != 0 ]]; then
    fail "TAP lifecycle case $case_name unexpectedly failed."
  fi
  if [[ "$expected" == fail && "$rc" == 0 ]]; then
    fail "TAP lifecycle case $case_name accepted a collision or replacement."
  fi
}

run_case positive pass '[]' 0

run_case collision fail '[{"ifindex":7,"ifname":"other0","ifalias":"p010-hyb-'"$(id -u)"'-20261029-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","linkinfo":{"info_kind":"tun","info_data":{"type":"tap"}}}]' 0
run_case replacement fail '[]' 0
run_case query-error fail '[]' 44

positive_dir="$scratch/positive"
jq -e '.hybrid.network.tap.ifindex == 45 and .hybrid.network.tap.alias == .hybrid.network.tap.reserved_alias' "$positive_dir/after-create.json" >/dev/null \
  || fail 'state durável não contém o checkpoint name/index/ifalias da TAP.'
jq -e 'length == 0' "$positive_dir/links.json" >/dev/null \
  || fail 'TAP própria permaneceu no namespace fake após cleanup.'
grep -Fq 'tuntap add dev p10tabcdef01 mode tap user '"$(id -u)" "$positive_dir/ip-calls.log" \
  || fail 'criação não usou a TAP reservada e seu UID.'
grep -Fq 'link set dev p10tabcdef01 alias p010-hyb-'"$(id -u)"-20261029-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$positive_dir/ip-calls.log" \
  || fail 'alias run-specific não foi aplicado.'
grep -Fq 'link del dev p10tabcdef01' "$positive_dir/ip-calls.log" \
  || fail 'cleanup não removeu a TAP depois da validação exata.'
if grep -Fq 'link del dev' "$scratch/replacement/ip-calls.log"; then
  fail 'cleanup tentou remover a TAP substituída por ifindex diferente.'
fi
if grep -Fq 'tuntap add' "$scratch/collision/ip-calls.log"; then
  fail 'colisão existente foi seguida por criação TAP.'
fi
if grep -Fq 'tuntap add' "$scratch/query-error/ip-calls.log"; then
  fail 'erro de consulta TAP foi tratado como ausência.'
fi

printf 'PASS: TAP reserve/create/checkpoint/delete with local fake namespace; collisions and query errors failed closed.\n'
printf 'LOG_DIR=%s\n' "$scratch"
