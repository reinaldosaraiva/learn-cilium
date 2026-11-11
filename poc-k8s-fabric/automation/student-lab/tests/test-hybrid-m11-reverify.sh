#!/usr/bin/env bash
set -euo pipefail
umask 077

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
student_lab_dir="$(cd -- "${test_dir}/.." && pwd -P)"
scratch="${P010_HYBRID_API_TEST_SCRATCH:?}"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-ansible-playbook}"

fail() {
  printf 'test-hybrid-m11-reverify: %s\nLOG_DIR=%s\n' "$1" "${scratch}" >&2
  exit 1
}

mkdir -m 0700 -p "${scratch}/k8s-verify-bin"
cp "${test_dir}/fake-kubectl-m11-verify.sh" "${scratch}/k8s-verify-bin/kubectl"
chmod 0700 "${scratch}/k8s-verify-bin/kubectl"
calls="${scratch}/k8s-verify-calls.log"
: >"${calls}"
export P010_HYBRID_K8S_VERIFY_CALLS="${calls}"
export P010_HYBRID_K8S_VERIFY_OWNER='11111111111141118111111111111111'
export P010_HYBRID_K8S_VERIFY_RUN='20261030-0123456789abcdef0123456789abcdef'
export P010_HYBRID_K8S_VERIFY_MODE=owned
if ! "${ansible_playbook_bin}" -i localhost, "${student_lab_dir}/tests/hybrid-m11-verify-k8s-saved-objects.yml" >"${scratch}/reverify-k8s-positive.log" 2>&1; then
  fail 'a rechecagem dos sete UIDs Kubernetes salvos falhou.'
fi

for action in up verify; do
  export P010_HYBRID_GATE_ACTION="${action}"
  : >"${calls}"
  rc=0
  "${ansible_playbook_bin}" -i localhost, "${student_lab_dir}/tests/hybrid-m11-existing-verification-gate.yml" >"${scratch}/reverify-gate-${action}.log" 2>&1 || rc=$?
  [[ "${rc}" != 0 ]] || fail "${action}: registro sem gate de origem passou como saudável."
  [[ ! -s "${calls}" ]] || fail "${action}: execução atingiu kubectl antes do gate positivo."
  grep -Fq 'Require an up M11 state with every saved positive gate before rechecking it' "${scratch}/reverify-gate-${action}.log" || fail "${action}: dispatch não atingiu a guarda comum da rechecagem."
done

export P010_HYBRID_K8S_VERIFY_MODE=wrong-uid
: >"${calls}"
rc=0
"${ansible_playbook_bin}" -i localhost, "${student_lab_dir}/tests/hybrid-m11-verify-k8s-saved-objects.yml" >"${scratch}/reverify-k8s-wrong-uid.log" 2>&1 || rc=$?
[[ "${rc}" != 0 ]] || fail 'UID Kubernetes substituído foi aceito pela rechecagem.'
[[ "$(wc -l <"${calls}" | tr -d ' ')" == 2 ]] || fail 'UID errado não foi recusado no objeto Kubernetes substituído.'

printf 'PASS: rechecagem consulta apenas objetos/UIDs salvos; up repetido e verify recusam gate incompleto antes de comandos; UID substituído falha fechado.\n'
