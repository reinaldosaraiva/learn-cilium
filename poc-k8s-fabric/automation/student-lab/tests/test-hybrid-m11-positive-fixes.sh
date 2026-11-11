#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
student_lab="$(cd -- "${script_dir}/.." && pwd -P)"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-$(command -v ansible-playbook || true)}"
scratch="${P010_M11_POSITIVE_TEST_SCRATCH:-$(mktemp -d /tmp/p010-m11-positive-fixes.XXXXXX)}"

fail() {
  printf 'FAIL: %s\nLOG_DIR=%s\n' "$1" "${scratch}" >&2
  exit 1
}

[[ -x "${ansible_playbook_bin}" ]] || fail 'ansible-playbook ausente; passe ANSIBLE_PLAYBOOK_BIN.'
mkdir -m 0700 -p "${scratch}/ansible-local" "${scratch}/bin"
export ANSIBLE_CONFIG="${student_lab}/ansible.cfg"
export ANSIBLE_LOCAL_TEMP="${scratch}/ansible-local"
export ANSIBLE_NOCOLOR=1
export P010_HYBRID_POD_TEST_SCRATCH="${scratch}"
export P010_HYBRID_TEST_BECOME_EXE="${scratch}/fake-sudo"
cp "${student_lab}/tests/fake-sudo.sh" "${P010_HYBRID_TEST_BECOME_EXE}"
chmod 0700 "${P010_HYBRID_TEST_BECOME_EXE}"

cat >"${scratch}/client-pods.json" <<'JSON'
{"apiVersion":"v1","kind":"List","metadata":{"resourceVersion":"1"},"items":[{"apiVersion":"v1","kind":"Pod","metadata":{"name":"client-pod","namespace":"p010-hyb-0123456789ab","uid":"33333333-3333-4333-8333-333333333333","labels":{"p010-student-owner":"11111111111141118111111111111111","p010-student-run":"20261030-0123456789abcdef0123456789abcdef","app":"p010-hyb-client"},"ownerReferences":[{"apiVersion":"apps/v1","kind":"ReplicaSet","name":"p010-hyb-0123456789ab-client-1234567890","uid":"55555555-5555-4555-8555-555555555555","controller":true,"blockOwnerDeletion":true}]},"spec":{"nodeName":"rack1-node"},"status":{"phase":"Running","podIP":"10.246.1.10","conditions":[{"type":"Ready","status":"True"}]}}]}
JSON
cat >"${scratch}/server-pods.json" <<'JSON'
{"apiVersion":"v1","kind":"List","metadata":{"resourceVersion":"1"},"items":[{"apiVersion":"v1","kind":"Pod","metadata":{"name":"server-pod","namespace":"p010-hyb-0123456789ab","uid":"44444444-4444-4444-8444-444444444444","labels":{"p010-student-owner":"11111111111141118111111111111111","p010-student-run":"20261030-0123456789abcdef0123456789abcdef","app":"p010-hyb-server"},"ownerReferences":[{"apiVersion":"apps/v1","kind":"ReplicaSet","name":"p010-hyb-0123456789ab-server-0987654321","uid":"66666666-6666-4666-8666-666666666666","controller":true,"blockOwnerDeletion":true}]},"spec":{"nodeName":"rack2-node"},"status":{"phase":"Running","podIP":"10.246.2.10","conditions":[{"type":"Ready","status":"True"}]}}]}
JSON
cat >"${scratch}/rs-client.json" <<'JSON'
{"apiVersion":"apps/v1","kind":"ReplicaSet","metadata":{"name":"p010-hyb-0123456789ab-client-1234567890","namespace":"p010-hyb-0123456789ab","uid":"55555555-5555-4555-8555-555555555555","labels":{"p010-student-owner":"11111111111141118111111111111111","p010-student-run":"20261030-0123456789abcdef0123456789abcdef","app":"p010-hyb-client"},"ownerReferences":[{"apiVersion":"apps/v1","kind":"Deployment","name":"p010-hyb-0123456789ab-client","uid":"11111111-1111-4111-8111-111111111111","controller":true,"blockOwnerDeletion":true}]}}
JSON
cat >"${scratch}/rs-server.json" <<'JSON'
{"apiVersion":"apps/v1","kind":"ReplicaSet","metadata":{"name":"p010-hyb-0123456789ab-server-0987654321","namespace":"p010-hyb-0123456789ab","uid":"66666666-6666-4666-8666-666666666666","labels":{"p010-student-owner":"11111111111141118111111111111111","p010-student-run":"20261030-0123456789abcdef0123456789abcdef","app":"p010-hyb-server"},"ownerReferences":[{"apiVersion":"apps/v1","kind":"Deployment","name":"p010-hyb-0123456789ab-server","uid":"22222222-2222-4222-8222-222222222222","controller":true,"blockOwnerDeletion":true}]}}
JSON
sed 's/11111111-1111-4111-8111-111111111111/99999999-9999-4999-8999-999999999999/' "${scratch}/rs-client.json" >"${scratch}/rs-client-foreign.json"
cat >"${scratch}/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
name=''
expect_name=0
for arg in "$@"; do
  if [[ "${expect_name}" == 1 ]]; then
    name="${arg}"
    break
  fi
  [[ "${arg}" != replicaset ]] || expect_name=1
done
case "${name}" in
  p010-hyb-0123456789ab-client-1234567890)
    if [[ "${P010_HYBRID_POD_TEST_MODE}" == foreign ]]; then
      cat "${P010_HYBRID_POD_TEST_SCRATCH}/rs-client-foreign.json"
    else
      cat "${P010_HYBRID_POD_TEST_SCRATCH}/rs-client.json"
    fi
    ;;
  p010-hyb-0123456789ab-server-0987654321)
    cat "${P010_HYBRID_POD_TEST_SCRATCH}/rs-server.json"
    ;;
  *) exit 44 ;;
esac
KUBECTL
chmod 0700 "${scratch}/bin/kubectl"

run_case() {
  local mode="$1" rc=0
  export P010_HYBRID_POD_TEST_MODE="${mode}"
  if "${ansible_playbook_bin}" -i localhost, "${student_lab}/tests/hybrid-m11-pod-ownerrefs.yml" >"${scratch}/pod-owner-${mode}.log" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  [[ "${rc}" == 0 ]] || fail "caso Pod/ReplicaSet ${mode} retornou rc${rc}."
}

run_case owned
run_case foreign

if "${ansible_playbook_bin}" -i localhost, "${student_lab}/tests/hybrid-m11-marker-parse.yml" >"${scratch}/marker-parse.log" 2>&1; then
  rc=0
else
  rc=$?
fi
[[ "${rc}" == 0 ]] || fail "parser de marcadores stdout retornou rc${rc}."

run_dora_case() {
  local xid="$1" expected="$2" name="$3" rc=0
  export P010_HYBRID_DORA_XID="${xid}"
  export P010_HYBRID_DORA_EXPECT="${expected}"
  if "${ansible_playbook_bin}" -i localhost, "${student_lab}/tests/hybrid-m11-dora-xid.yml" >"${scratch}/dora-xid-${name}.log" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  [[ "${rc}" == 0 ]] || fail "caso XID ${name} retornou rc${rc}."
}

run_dora_case 0x1234abcd accept tcpdump-lower
run_dora_case 0xABCDEF09 accept tcpdump-upper
run_dora_case 0x1234abxz reject non-hex
run_dora_case 0x1234abcd9 reject too-long

printf 'PASS: kubectl List → ReplicaSet → Deployment por UID, recusa de owner alheio e XID tcpdump de 32 bits.\n'
printf 'LOG_DIR=%s\n' "${scratch}"
