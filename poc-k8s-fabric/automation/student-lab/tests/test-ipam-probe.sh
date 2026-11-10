#!/usr/bin/env bash
set -euo pipefail

student_lab_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
repo_root="$(cd -- "${student_lab_dir}/../../.." && pwd -P)"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-ansible-playbook}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT

fail() {
  printf 'test-ipam-probe: %s\n' "$1" >&2
  exit 1
}

command -v "${ansible_playbook_bin}" >/dev/null 2>&1 \
  || fail 'ansible-playbook ausente; informe ANSIBLE_PLAYBOOK_BIN.'

mkdir -p "${tmp_dir}/bin"
cat >"${tmp_dir}/bin/kubectl" <<'SH'
#!/usr/bin/env bash
set -u
printf '%q ' "$@" >>"${FAKE_KUBECTL_LOG}"
printf '\n' >>"${FAKE_KUBECTL_LOG}"
args=("$@")
arg_after() {
  local expected="$1" index
  for ((index = 0; index < ${#args[@]} - 1; index++)); do
    if [[ "${args[index]}" == "${expected}" ]]; then
      printf '%s' "${args[index + 1]}"
      return 0
    fi
  done
  return 1
}
case " ${args[*]} " in
  *' create --filename '*ipam-no-match-namespace.yaml*)
    if [[ "${FAKE_IPAM_CASE}" == collision ]]; then
      printf 'Error from server (AlreadyExists): namespaces "p003-ipam-no-match" already exists\n' >&2
      exit 1
    fi
    printf '{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"p003-ipam-no-match","uid":"01234567-89ab-4cde-8fab-0123456789ab","labels":{"p010-student-owner-token":"11111111-2222-4333-8444-555555555555"}}}\n'
    ;;
  *' create --filename '*ipam-no-match-pod.yaml*)
    printf 'pod/p003-ipam-no-match-check created\n'
    ;;
  *' get events '*)
    printf 'no matching IP pool found for this namespace\n'
    ;;
  *' get pod p003-ipam-no-match-check '*)
    ;;
  *' get namespace p003-ipam-no-match '*)
    if [[ "$(arg_after -o)" == name && -e "${FAKE_DELETE_CALLED_FILE}" ]]; then
      if [[ "${FAKE_IPAM_CASE}" == delete-still-present ]]; then
        printf 'namespace/p003-ipam-no-match\n'
        exit 0
      fi
      printf '[]\n'
      printf 'Error from server (NotFound): namespaces "p003-ipam-no-match" not found\n' >&2
      exit 1
    fi
    case "${FAKE_IPAM_CASE}" in
      api-error)
        printf 'Unable to connect to the server\n' >&2
        exit 1
        ;;
      owner-mismatch)
        printf '{"metadata":{"name":"p003-ipam-no-match","uid":"01234567-89ab-4cde-8fab-0123456789ab","labels":{"p010-student-owner-token":"99999999-2222-4333-8444-555555555555"}}}\n'
        ;;
      *)
        printf '{"metadata":{"name":"p003-ipam-no-match","uid":"01234567-89ab-4cde-8fab-0123456789ab","labels":{"p010-student-owner-token":"11111111-2222-4333-8444-555555555555"}}}\n'
        ;;
    esac
    ;;
  *' delete --raw=/api/v1/namespaces/p003-ipam-no-match --filename '*)
    delete_options="$(arg_after --filename)"
    [[ -f "${delete_options}" ]] || { printf 'DeleteOptions file missing\n' >&2; exit 98; }
    grep -Fq '"kind": "DeleteOptions"' "${delete_options}" \
      && grep -Fq '"uid": "01234567-89ab-4cde-8fab-0123456789ab"' "${delete_options}" \
      || { printf 'DeleteOptions did not bind the created UID\n' >&2; exit 98; }
    if [[ "${FAKE_IPAM_CASE}" == cleanup-error ]]; then
      printf 'forbidden: namespace cleanup denied\n' >&2
      exit 9
    fi
    if [[ "${FAKE_IPAM_CASE}" == precondition-conflict ]]; then
      printf 'Error from server (Conflict): UID precondition failed\n' >&2
      exit 1
    fi
    : >"${FAKE_DELETE_CALLED_FILE}"
    printf 'namespace/p003-ipam-no-match deleted\n'
    ;;
  *)
    printf 'unexpected kubectl invocation: %s\n' "${args[*]}" >&2
    exit 99
    ;;
esac
SH
chmod 0700 "${tmp_dir}/bin/kubectl"

cat >"${tmp_dir}/probe.yml" <<YAML
---
- hosts: localhost
  gather_facts: false
  connection: local
  vars:
    ansible_become: false
    student_repo_root: ${repo_root}
    student_run_dir: "{{ lookup('env', 'TEST_RUN_DIR') }}"
    student_tool_dir: "{{ lookup('env', 'TEST_BIN_DIR') }}"
    student_uid: "{{ lookup('env', 'TEST_UID') | int }}"
    student_state:
      kubeconfig: FAKE-ONLY
      owner_token: 11111111-2222-4333-8444-555555555555
    student_profile:
      context: kind-p003-gw
      kind_nodes: [p003-gw-control-plane, p003-gw-worker, p003-gw-worker2]
    student_ipam_cleanup_retries: 1
    student_ipam_cleanup_delay: 0
  tasks:
    - ansible.builtin.file:
        path: "{{ student_run_dir }}"
        state: directory
        mode: '0700'
    - ansible.builtin.include_tasks: ${student_lab_dir}/tasks/verify-ipam-no-match.yml
YAML

export ANSIBLE_CONFIG="${student_lab_dir}/ansible.cfg"
export TEST_BIN_DIR="${tmp_dir}/bin"
TEST_UID="$(id -u)"
export TEST_UID

run_case() {
  local scenario="$1" expected="$2"
  export FAKE_IPAM_CASE="${scenario}"
  export TEST_RUN_DIR="${tmp_dir}/run-${scenario}"
  export FAKE_KUBECTL_LOG="${tmp_dir}/${scenario}.calls"
  export FAKE_DELETE_CALLED_FILE="${tmp_dir}/${scenario}.delete-called"
  : >"${FAKE_KUBECTL_LOG}"
  if "${ansible_playbook_bin}" --inventory 'localhost,' --connection local \
    "${tmp_dir}/probe.yml" >"${tmp_dir}/${scenario}.log" 2>&1; then
    actual=success
  else
    actual=failure
  fi
  [[ "${actual}" == "${expected}" ]] \
    || { cat "${tmp_dir}/${scenario}.log" >&2; fail "${scenario}: esperado ${expected}, obtido ${actual}."; }
}

run_case success success
grep -Fq 'p010-student-owner-token: 11111111-2222-4333-8444-555555555555' \
  "${TEST_RUN_DIR}/ipam-no-match-namespace.yaml" \
  || fail 'namespace privado não recebeu o token de ownership.'
grep -Fq 'create --filename' "${FAKE_KUBECTL_LOG}" \
  || fail 'probe positivo não usou kubectl create.'
grep -Fq -- '--raw=/api/v1/namespaces/p003-ipam-no-match' "${FAKE_KUBECTL_LOG}" \
  || fail 'cleanup não usou a operação raw DELETE suportada.'
grep -Fq 'ipam-no-match-delete-options.json' "${FAKE_KUBECTL_LOG}" \
  || fail 'cleanup não enviou DeleteOptions privado.'
grep -Fq 'get namespace p003-ipam-no-match -o name' "${FAKE_KUBECTL_LOG}" \
  || fail 'cleanup não consultou a ausência após DELETE.'
delete_options_mode="$(stat -f '%Lp' "${TEST_RUN_DIR}/ipam-no-match-delete-options.json" 2>/dev/null || stat -c '%a' "${TEST_RUN_DIR}/ipam-no-match-delete-options.json")"
[[ "${delete_options_mode}" == 600 ]] \
  || fail 'DeleteOptions não ficou privado em modo 0600.'
if grep -Fq -- '--preconditions=uid=' "${FAKE_KUBECTL_LOG}"; then
  fail 'cleanup ainda usa a flag kubectl inexistente.'
fi
if grep -Fq ' apply ' "${FAKE_KUBECTL_LOG}"; then
  fail 'probe usou apply e poderia adotar namespace existente.'
fi
printf 'case: create-only, token/UID e cleanup condicionado PASS\n'

run_case collision failure
grep -Fq 'create --filename' "${FAKE_KUBECTL_LOG}" \
  || fail 'collision não tentou create-only.'
if grep -Eq 'create .*ipam-no-match-pod| delete --raw=' "${FAKE_KUBECTL_LOG}"; then
  fail 'collision tocou Pod ou apagou o namespace preexistente.'
fi
printf 'case: colisão preexistente não é adotada nem apagada PASS\n'

run_case owner-mismatch failure
grep -Fq 'get namespace p003-ipam-no-match' "${FAKE_KUBECTL_LOG}" \
  || fail 'cleanup não conferiu identidade live.'
if grep -Fq ' delete --raw=' "${FAKE_KUBECTL_LOG}"; then
  fail 'cleanup apagou namespace cujo token live divergiu.'
fi
printf 'case: token live divergente recusa cleanup PASS\n'

run_case api-error failure
if grep -Fq ' delete --raw=' "${FAKE_KUBECTL_LOG}"; then
  fail 'falha de API foi tratada como autorização para apagar.'
fi
printf 'case: erro de API não vira ausência nem permite delete PASS\n'

run_case cleanup-error failure
grep -Fq -- '--raw=/api/v1/namespaces/p003-ipam-no-match' "${FAKE_KUBECTL_LOG}" \
  || fail 'cleanup-error não tentou remover o UID próprio.'
grep -Fq 'forbidden: namespace cleanup denied' "${tmp_dir}/cleanup-error.log" \
  || fail 'erro de cleanup não propagou ao chamador.'
printf 'case: falha de cleanup é propagada PASS\n'

run_case precondition-conflict failure
grep -Fq 'UID precondition failed' "${tmp_dir}/precondition-conflict.log" \
  || fail 'conflito de UID não foi propagado.'
if grep -Fq 'get namespace p003-ipam-no-match -o name' "${FAKE_KUBECTL_LOG}"; then
  fail 'prova de ausência rodou após DELETE recusado por UID.'
fi
printf 'case: conflito da precondição UID não é tratado como sucesso PASS\n'

run_case delete-still-present failure
grep -Fq 'namespace/p003-ipam-no-match' "${tmp_dir}/delete-still-present.log" \
  || fail 'namespace ainda presente após raw DELETE não bloqueou limpeza.'
printf 'case: raw DELETE sem ausência observável não passa PASS\n'

printf 'test-ipam-probe: PASS (7 casos; collision, token, UID, raw DELETE, ausência observável e erros propagados)\n'
