#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-$(command -v ansible-playbook || true)}"
ansible_python_bin="${ANSIBLE_PYTHON_BIN:-${ansible_playbook_bin%/*}/python}"
scratch="${P010_HYBRID_FOUNDATION_SCRATCH:-$(mktemp -d /tmp/p010-hybrid-foundation-XXXXXX)}"

fail() {
  printf 'FAIL: %s\nLOG_DIR=%s\n' "$1" "$scratch" >&2
  exit 1
}

[[ -x "$ansible_playbook_bin" ]] || fail 'ansible-playbook ausente; passe ANSIBLE_PLAYBOOK_BIN.'
[[ -x "$ansible_python_bin" ]] || fail 'Python do venv Ansible ausente; passe ANSIBLE_PYTHON_BIN.'
command -v jq >/dev/null 2>&1 || fail 'jq ausente.'
mkdir -m 0700 -p "$scratch/ansible-local" "$scratch/fake-bin" "$scratch/boot-guard"
export ANSIBLE_CONFIG="$script_dir/ansible.cfg"
export ANSIBLE_LOCAL_TEMP="$scratch/ansible-local"
export ANSIBLE_NOCOLOR=1

for playbook in \
  hybrid-boot-guard.yml \
  hybrid-download-checkpoint.yml \
  hybrid-overlay-checkpoint.yml \
  hybrid-run-paths.yml \
  hybrid-seed-checkpoint.yml; do
  "$ansible_playbook_bin" --syntax-check -i localhost, "$script_dir/tests/$playbook" \
    >"$scratch/syntax-${playbook%.yml}.log" 2>&1 \
    || fail "syntax-check falhou para $playbook."
done

mkdir -p "$scratch/border-capture"
ANSIBLE_PLAYBOOK_BIN="$ansible_playbook_bin" \
P010_HYBRID_BORDER_TEST_SCRATCH="$scratch/border-capture" \
PYTHONDONTWRITEBYTECODE=1 \
  "$ansible_python_bin" -B "$script_dir/tests/test-hybrid-border-capture.py" >"$scratch/border-capture.log" 2>&1 \
  || fail 'profile-owned border identity capture checks failed.'

"$ansible_playbook_bin" -i localhost, "$script_dir/tests/hybrid-qemu-network-args.yml" \
  >"$scratch/qemu-network-args.log" 2>&1 \
  || fail 'QEMU management, TAP, stream, or guest MAC/PCI argument checks failed.'

"$ansible_playbook_bin" --syntax-check -i localhost, "$script_dir/tests/hybrid-tap-identity.yml" \
  >"$scratch/tap-identity-syntax.log" 2>&1 \
  || fail 'syntax-check do teste de identidade TAP falhou.'

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
if [[ "${P010_HYBRID_FAKE_IP_RC:-0}" != 0 ]]; then
  printf 'fake ip query failure\n' >&2
  exit "$P010_HYBRID_FAKE_IP_RC"
fi
cat "$P010_HYBRID_FAKE_IP_JSON"
EOF
chmod 0700 "$scratch/fake-bin/nsenter" "$scratch/fake-bin/ip"
cat >"$scratch/tap-valid.json" <<'EOF'
[{"ifindex": 45, "ifname": "p10tabcdef01", "ifalias": "p010-hyb-1000-20261029-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "linkinfo": {"info_kind": "tun", "info_data": {"type": "tap"}}}]
EOF
cat >"$scratch/tap-wrong-index.json" <<'EOF'
[{"ifindex": 46, "ifname": "p10tabcdef01", "ifalias": "p010-hyb-1000-20261029-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "linkinfo": {"info_kind": "tun", "info_data": {"type": "tap"}}}]
EOF
cat >"$scratch/tap-wrong-alias.json" <<'EOF'
[{"ifindex": 45, "ifname": "p10tabcdef01", "ifalias": "p010-hyb-other-run", "linkinfo": {"info_kind": "tun", "info_data": {"type": "tap"}}}]
EOF
cat >"$scratch/tap-wrong-type.json" <<'EOF'
[{"ifindex": 45, "ifname": "p10tabcdef01", "ifalias": "p010-hyb-1000-20261029-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "linkinfo": {"info_kind": "tun", "info_data": {"type": "tun"}}}]
EOF
cat >"$scratch/tap-duplicate-alias.json" <<'EOF'
[{"ifindex": 45, "ifname": "p10tabcdef01", "ifalias": "p010-hyb-1000-20261029-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "linkinfo": {"info_kind": "tun", "info_data": {"type": "tap"}}}, {"ifindex": 47, "ifname": "other0", "ifalias": "p010-hyb-1000-20261029-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "linkinfo": {"info_kind": "tun", "info_data": {"type": "tap"}}}]
EOF
printf 'not-json\n' >"$scratch/tap-malformed.json"
printf '[]\n' >"$scratch/tap-absent.json"

tap_check() {
  local case_name="$1" fixture="$2" index="$3" allow_absent="$4" fake_rc="$5" expected="$6" result_rc
  if env \
    P010_HYBRID_FAKE_NSENTER="$scratch/fake-bin/nsenter" \
    P010_HYBRID_FAKE_IP="$scratch/fake-bin/ip" \
    P010_HYBRID_FAKE_IP_JSON="$fixture" \
    P010_HYBRID_FAKE_IP_RC="$fake_rc" \
    P010_HYBRID_TAP_INDEX="$index" \
    P010_HYBRID_TAP_ALLOW_ABSENT="$allow_absent" \
    "$ansible_playbook_bin" -i localhost, "$script_dir/tests/hybrid-tap-identity.yml" \
    >"$scratch/tap-$case_name.log" 2>&1; then
    result_rc=0
  else
    result_rc=$?
  fi
  if [[ "$expected" == pass && "$result_rc" != 0 ]]; then
    fail "TAP identity case $case_name unexpectedly failed."
  fi
  if [[ "$expected" == fail && "$result_rc" == 0 ]]; then
    fail "TAP identity case $case_name accepted an inconclusive or replaced resource."
  fi
}

tap_check positive "$scratch/tap-valid.json" 45 false 0 pass
tap_check wrong-index "$scratch/tap-wrong-index.json" 45 false 0 fail
tap_check wrong-alias "$scratch/tap-wrong-alias.json" 45 false 0 fail
tap_check wrong-type "$scratch/tap-wrong-type.json" 45 false 0 fail
tap_check duplicate-alias "$scratch/tap-duplicate-alias.json" 45 false 0 fail
tap_check malformed "$scratch/tap-malformed.json" 45 false 0 fail
tap_check query-failure "$scratch/tap-valid.json" 45 false 44 fail
tap_check reserved-absent "$scratch/tap-absent.json" 0 false 0 pass
tap_check cleanup-absent "$scratch/tap-absent.json" 45 true 0 pass

"$ansible_playbook_bin" --syntax-check -i localhost, "$script_dir/tests/hybrid-dns-selection.yml" \
  >"$scratch/dns-selection-syntax.log" 2>&1 \
  || fail 'syntax-check do teste de DNS falhou.'
cat >"$scratch/fake-bin/resolvectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'dns --no-pager' ]] || exit 61
if [[ "${P010_HYBRID_DNS_RC:-0}" != 0 ]]; then
  printf 'resolver query failure\n' >&2
  exit "$P010_HYBRID_DNS_RC"
fi
cat "$P010_HYBRID_DNS_OUTPUT"
EOF
chmod 0700 "$scratch/fake-bin/resolvectl"
cat >"$scratch/dns-valid.txt" <<'EOF'
Global: 192.168.50.1 1.1.1.1
Link 2 (lo): 127.0.0.53
Link 3 (docker0): 169.254.4.1 10.0.2.3 224.0.0.1
EOF
cat >"$scratch/dns-no-upstream.txt" <<'EOF'
Global: 127.0.0.53
Link 3 (docker0): 169.254.4.1 10.0.2.3 224.0.0.1
EOF
if ! env \
  P010_HYBRID_FAKE_RESOLVECTL="$scratch/fake-bin/resolvectl" \
  P010_HYBRID_DNS_OUTPUT="$scratch/dns-valid.txt" \
  P010_HYBRID_DNS_RC=0 \
  "$ansible_playbook_bin" -i localhost, "$script_dir/tests/hybrid-dns-selection.yml" \
  >"$scratch/dns-positive.log" 2>&1; then
  fail 'DNS upstreams descobertos e não-loopback não foram selecionados.'
fi
for dns_case in no-upstream resolver-error; do
  dns_rc=0
  dns_fixture="$scratch/dns-no-upstream.txt"
  if [[ "$dns_case" == resolver-error ]]; then
    dns_rc=63
    dns_fixture="$scratch/dns-valid.txt"
  fi
  if env \
    P010_HYBRID_FAKE_RESOLVECTL="$scratch/fake-bin/resolvectl" \
    P010_HYBRID_DNS_OUTPUT="$dns_fixture" \
    P010_HYBRID_DNS_RC="$dns_rc" \
    "$ansible_playbook_bin" -i localhost, "$script_dir/tests/hybrid-dns-selection.yml" \
    >"$scratch/dns-$dns_case.log" 2>&1; then
    fail "DNS selection aceitou o caso $dns_case sem upstream confiável."
  fi
done

PYTHONDONTWRITEBYTECODE=1 python3 -B "$script_dir/tests/test_hybrid_qmp.py" >"$scratch/qmp.log" 2>&1 \
  || fail 'QMP framing, identity, deadline, or shutdown checks failed.'
for test_case in positive replacement qmp-replacement socket-present owner; do
  test_dir="$scratch/boot-guard/$test_case"
  mkdir -m 0700 -p "$test_dir"
  if env \
    P010_HYBRID_TEST_DIR="$test_dir" \
    P010_HYBRID_TEST_UID="$(id -u)" \
    P010_HYBRID_BOOT_GUARD_CASE="$test_case" \
    "$ansible_playbook_bin" -i localhost, "$script_dir/tests/hybrid-boot-guard.yml" \
    >"$scratch/boot-guard-$test_case.log" 2>&1; then
    test_rc=0
  else
    test_rc=$?
  fi
  case "$test_case" in
    positive) [[ "$test_rc" == 0 ]] || fail 'owned overlay was rejected before fake boot.' ;;
    replacement|qmp-replacement|socket-present|owner) [[ "$test_rc" != 0 ]] || fail "boot identity $test_case control was accepted." ;;
  esac
done

cat >"$scratch/fake-bin/qemu-img" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$P010_HYBRID_QEMU_IMG_ARGV_LOG"
case "${1:-}" in
  create)
    if [[ "${!#}" == *ubuntu-overlay.qcow2 || "${8:-}" == *ubuntu-overlay.qcow2 ]]; then
      [[ "$#" == 9 && "$7" == "$P010_HYBRID_TEST_DIR/run/images/ubuntu.img" && "$8" == "$P010_HYBRID_TEST_DIR/run/images/ubuntu-overlay.qcow2" && "$9" == 42949672960 ]] || exit 80
      : >"$8"
      exit 0
    fi
    [[ "$#" == 8 && "$7" == "$P010_HYBRID_TEST_DIR/run/images/cirros.img" && "$8" == "$P010_HYBRID_TEST_DIR/run/images/cirros-overlay.qcow2" ]] || exit 81
    : >"$P010_HYBRID_QEMU_IMG_FAIL_MARKER"
    [[ "$P010_HYBRID_QEMU_IMG_CASE" != second-create ]] || exit 77
    : >"$8"
    ;;
  info)
    [[ "$#" == 3 && "$2" == --output=json ]] || exit 82
    if [[ "$3" == *ubuntu-overlay.qcow2 ]]; then
      guest=ubuntu
      backing="$P010_HYBRID_TEST_DIR/run/images/ubuntu.img"
    elif [[ "$3" == *cirros-overlay.qcow2 ]]; then
      guest=cirros
      backing="$P010_HYBRID_TEST_DIR/run/images/cirros.img"
    else
      exit 83
    fi
    [[ "$3" == "$P010_HYBRID_TEST_DIR/run/images/$guest-overlay.qcow2" ]] || exit 84
    /usr/bin/jq -e --arg guest "$guest" '.hybrid.guests[$guest].overlay_inode > 0' "$P010_HYBRID_TEST_DIR/state.json" >/dev/null
    if [[ "$guest" == ubuntu ]]; then
      case "$P010_HYBRID_QEMU_IMG_CASE" in
        info-rc) printf 'fake qemu-img info failure\n' >&2; exit 63 ;;
        info-json) printf 'not-json\n'; exit 0 ;;
        info-size) printf '{"format":"qcow2","virtual-size":42949672959,"backing-filename":"%s"}\n' "$backing"; exit 0 ;;
        info-backing) printf '{"format":"qcow2","virtual-size":42949672960,"backing-filename":"/tmp/wrong-ubuntu.img"}\n'; exit 0 ;;
      esac
      printf '{"format":"qcow2","virtual-size":42949672960,"backing-filename":"%s"}\n' "$backing"
    else
      printf '{"format":"qcow2","virtual-size":3758096384,"backing-filename":"%s"}\n' "$backing"
    fi
    ;;
  *) exit 85 ;;
esac
EOF
cat >"$scratch/fake-bin/genisoimage" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
destination=''
while (($#)); do
  if [[ "$1" == -output ]]; then
    destination="$2"
    break
  fi
  shift
done
[[ -n "$destination" ]] || exit 78
if [[ "$destination" == *cirros.iso ]]; then
  : >"$P010_HYBRID_GENISOIMAGE_FAIL_MARKER"
  exit 77
fi
: >"$destination"
EOF
chmod 0700 "$scratch/fake-bin/qemu-img" "$scratch/fake-bin/genisoimage"

for disk_case in success info-rc info-json info-size info-backing second-create; do
  test_dir="$scratch/overlays-$disk_case"
  mkdir -m 0700 -p "$test_dir"
  : >"$test_dir/qemu-img-argv.log"
  env \
    P010_HYBRID_TEST_DIR="$test_dir" \
    P010_HYBRID_TEST_UID="$(id -u)" \
    P010_HYBRID_QEMU_IMG_BIN="$scratch/fake-bin/qemu-img" \
    P010_HYBRID_QEMU_IMG_CASE="$disk_case" \
    P010_HYBRID_QEMU_IMG_ARGV_LOG="$test_dir/qemu-img-argv.log" \
    P010_HYBRID_QEMU_IMG_FAIL_MARKER="$test_dir/cirros-create-attempted" \
    "$ansible_playbook_bin" -i localhost, "$script_dir/tests/hybrid-overlay-checkpoint.yml" \
    >"$scratch/overlay-$disk_case.log" 2>&1 \
    || fail "overlay geometry/checkpoint case $disk_case failed."
done

disk_guard_bin="$scratch/disk-guard-bin"
mkdir -m 0700 -p "$disk_guard_bin" "$scratch/disk-guard"
cat >"$disk_guard_bin/df" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == '-B1 --output=avail /' ]] || exit 91
case "$P010_HYBRID_DISK_DF_CASE" in
  below) printf 'Avail\n32212254719\n' ;;
  equal) printf 'Avail\n32212254720\n' ;;
  above) printf 'Avail\n32212254721\n' ;;
  error) printf 'fake df error\n' >&2; exit 42 ;;
  invalid) printf 'Avail\nnot-a-decimal\n' ;;
  empty) : ;;
  oversized) printf 'Avail\n1000000000000000\n' ;;
  *) exit 92 ;;
esac
EOF
cat >"$disk_guard_bin/ip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  '-j link show dev external0') printf '[{"address":"02:00:00:00:00:01"}]\n' ;;
  '-j -4 address show dev external0'|'-j -4 address show dev tenant0') printf '[{"addr_info":[]}]\n' ;;
  '-j route show default') printf '[{"dev":"management0","gateway":"10.0.2.2"}]\n' ;;
  *) exit 93 ;;
esac
EOF
cat >"$disk_guard_bin/jq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
cat >"$disk_guard_bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: >"$P010_HYBRID_DISK_APT_MARKER"
printf '%s\n' "$*" >>"$P010_HYBRID_DISK_APT_MARKER.log"
exit 99
EOF
cat >"$disk_guard_bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: >"$P010_HYBRID_DISK_GIT_MARKER"
if [[ "${1:-}" == init ]]; then
  checkout="${!#}"
  mkdir -m 0700 -p "$checkout"
  cat >"$checkout/stack.sh" <<'STACK'
#!/usr/bin/env bash
: >"$P010_HYBRID_DISK_STACK_MARKER"
exit 98
STACK
  chmod 0700 "$checkout/stack.sh"
fi
exit 98
EOF
chmod 0700 "$disk_guard_bin/df" "$disk_guard_bin/ip" "$disk_guard_bin/jq" "$disk_guard_bin/sudo" "$disk_guard_bin/git"

awk '
  /^- name: Build the guarded DevStack guest script$/ { matches++; target=1 }
  target && /^  no_log: true$/ {
    print
    print "  tags:"
    print "    - p010_hybrid_disk_guard"
    injected++
    target=0
    next
  }
  { print }
  END { if (matches != 1 || injected != 1) exit 91 }
' "$script_dir/tasks/hybrid-m11-devstack.yml" >"$scratch/hybrid-m11-devstack-test.yml" \
  || fail 'could not select the one production script-render task for the local guard fixture.'

env \
  P010_HYBRID_TEST_DIR="$scratch/disk-guard" \
  P010_HYBRID_DISK_GUARD_BIN="$disk_guard_bin" \
  P010_HYBRID_TEST_CHECKOUT="$scratch/disk-guard-checkout" \
  P010_HYBRID_DEVSTACK_TEST_TASK_FILE="$scratch/hybrid-m11-devstack-test.yml" \
  ANSIBLE_PLAYBOOK_BIN="$ansible_playbook_bin" \
  "$ansible_playbook_bin" --tags p010_hybrid_disk_guard -i localhost, "$script_dir/tests/hybrid-overlay-checkpoint.yml" \
  >"$scratch/devstack-disk-guard.log" 2>&1 \
  || fail 'rendered DevStack root-space guard did not reject invalid/low df output or accept the exact threshold.'

env \
  P010_HYBRID_TEST_DIR="$scratch/seeds" \
  P010_HYBRID_TEST_UID="$(id -u)" \
  P010_HYBRID_GENISOIMAGE_BIN="$scratch/fake-bin/genisoimage" \
  P010_HYBRID_GENISOIMAGE_FAIL_MARKER="$scratch/genisoimage-second-failed" \
  "$ansible_playbook_bin" -i localhost, "$script_dir/tests/hybrid-seed-checkpoint.yml" \
  >"$scratch/seed-checkpoint.log" 2>&1 \
  || fail 'second seed failure lost the first durable identity or exact cleanup.'

printf 'ubuntu image\n' >"$scratch/ubuntu.img"
printf 'cirros image\n' >"$scratch/cirros.img"
ubuntu_sha256="$(shasum -a 256 "$scratch/ubuntu.img" | awk '{print $1}')"
bad_sha256='0000000000000000000000000000000000000000000000000000000000000000'
env \
  P010_HYBRID_TEST_DIR="$scratch/downloads" \
  P010_HYBRID_TEST_UID="$(id -u)" \
  P010_HYBRID_IMAGE_ONE="$scratch/ubuntu.img" \
  P010_HYBRID_IMAGE_TWO="$scratch/cirros.img" \
  P010_HYBRID_IMAGE_ONE_SHA256="$ubuntu_sha256" \
  P010_HYBRID_IMAGE_TWO_SHA256="$bad_sha256" \
  "$ansible_playbook_bin" -i localhost, "$script_dir/tests/hybrid-download-checkpoint.yml" \
  >"$scratch/download-checkpoint.log" 2>&1 \
  || fail 'second checksum failure lost the first durable identity or exact cleanup.'

ANSIBLE_PLAYBOOK_BIN="$ansible_playbook_bin" \
P010_HYBRID_TEST_SCRATCH="$scratch/lifecycle" \
  bash "$script_dir/tests/test-hybrid-lifecycle.sh" >"$scratch/lifecycle.log" 2>&1 \
  || fail 'schema, identity, run-path, public-gate, or repeated-down lifecycle checks failed.'

ANSIBLE_PLAYBOOK_BIN="$ansible_playbook_bin" \
P010_HYBRID_TAP_TEST_SCRATCH="$scratch/tap-lifecycle" \
  bash "$script_dir/tests/test-hybrid-tap-lifecycle.sh" >"$scratch/tap-lifecycle.log" 2>&1 \
  || fail 'reserve/create/checkpoint/delete TAP controls failed.'

printf 'PASS: local QMP, path/ownership guards, per-artifact checkpoints, and hybrid lifecycle checks.\n'
printf 'LOG_DIR=%s\n' "$scratch"
