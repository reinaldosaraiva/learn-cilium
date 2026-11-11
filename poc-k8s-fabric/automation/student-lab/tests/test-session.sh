#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-ansible-playbook}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT

fail() {
  printf 'test-session: %s\n' "$1" >&2
  exit 1
}

command -v "${ansible_playbook_bin}" >/dev/null 2>&1 \
  || fail 'ansible-playbook ausente; informe ANSIBLE_PLAYBOOK_BIN.'

mkdir -p "${tmp_dir}/bin"
cat >"${tmp_dir}/bin/kubectl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_KUBECTL_LOG}"
namespace=''
previous="${FAKE_PREVIOUS_NAMESPACE:-}"
args=("$@")
for ((i = 0; i < ${#args[@]}; i += 1)); do
  if [[ "${args[i]}" == namespace ]]; then
    namespace="${args[i + 1]:-}"
    break
  fi
done
case "${FAKE_SESSION_SCENARIO}" in
  first|old-removed)
    if [[ "${FAKE_SESSION_SCENARIO}" == old-removed && "${namespace}" == "${previous}" ]]; then
      printf 'Error from server (NotFound): namespaces "%s" not found\n' "${namespace}" >&2
      exit 1
    fi
    printf 'Error from server (NotFound): namespaces "%s" not found\n' "${namespace}" >&2
    exit 1
    ;;
  old-exists)
    if [[ "${namespace}" == "${previous}" ]]; then
      printf '{"kind":"Namespace","metadata":{"name":"%s"}}\n' "${namespace}"
      exit 0
    fi
    printf 'Error from server (NotFound): namespaces "%s" not found\n' "${namespace}" >&2
    exit 1
    ;;
  candidate-exists)
    printf '{"kind":"Namespace","metadata":{"name":"%s"}}\n' "${namespace}"
    exit 0
    ;;
  api-unavailable)
    printf 'The connection to the server 127.0.0.1:32771 was refused\n' >&2
    exit 1
    ;;
  *) printf 'unknown scenario\n' >&2; exit 2 ;;
esac
SH
chmod 0700 "${tmp_dir}/bin/kubectl"
cat >"${tmp_dir}/bin/timeout" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
shift 2
exec "$@"
SH
chmod 0700 "${tmp_dir}/bin/timeout"

cat >"${tmp_dir}/session.yml" <<'YAML'
- hosts: localhost
  gather_facts: true
  connection: local
  vars:
    ansible_become: false
    student_tool_dir: "{{ lookup('env', 'TEST_SCRATCH') }}/bin"
    student_timeout_bin: "{{ lookup('env', 'TEST_SCRATCH') }}/bin/timeout"
    student_state_file: "{{ lookup('env', 'TEST_SCRATCH') }}/state.json"
    student_uid: "{{ lookup('env', 'TEST_UID') | int }}"
    student_state:
      owner_uid: "{{ lookup('env', 'TEST_UID') | int }}"
      owner_token: aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
      profile: iniciantes
      status: up
      cluster_uid: 11111111-1111-4111-8111-111111111111
      context: kind-p010-student
      kubeconfig: /private/run/kubeconfig
      exercise_session: >-
        {{ {'id': lookup('env', 'FAKE_PREVIOUS_ID'),
            'namespace': lookup('env', 'FAKE_PREVIOUS_NAMESPACE'),
            'owner_uid': lookup('env', 'TEST_UID') | int,
            'owner_token': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            'cluster_uid': '11111111-1111-4111-8111-111111111111'}
           if lookup('env', 'FAKE_PREVIOUS_ID') | length > 0 else {} }}
    student_profile_name: iniciantes
    student_new_session_id: 20261029-22222222222222222222222222222222
    student_has_state: true
  tasks:
    - block:
        - ansible.builtin.include_tasks: "{{ lookup('env', 'STUDENT_LAB_ROOT') }}/poc-k8s-fabric/automation/student-lab/tasks/session.yml"
      rescue:
        - ansible.builtin.set_fact:
            student_session_rejected: true
    - name: Check session creation and refusal cases
      ansible.builtin.assert:
        that:
          - (lookup('env', 'FAKE_EXPECT_SUCCESS') == 'true') == (not (student_session_rejected | default(false)))
          - >-
            lookup('env', 'FAKE_EXPECT_SUCCESS') != 'true' or
            ((lookup('file', student_state_file) | from_json).exercise_session.id == student_new_session_id and
             (lookup('file', student_state_file) | from_json).exercise_session.namespace == 'p010-aluno-' ~ student_new_session_id and
             (lookup('file', student_state_file) | from_json).exercise_session.owner_uid | int == student_uid and
             (lookup('file', student_state_file) | from_json).exercise_session.owner_token == student_state.owner_token and
             (lookup('file', student_state_file) | from_json).exercise_session.cluster_uid == student_state.cluster_uid)
          - >-
            lookup('env', 'FAKE_EXPECT_SUCCESS') == 'true' or
            lookup('file', student_state_file) == '{"unchanged":true}'
YAML

export ANSIBLE_CONFIG="${script_dir}/ansible.cfg"
STUDENT_LAB_ROOT="$(cd -- "${script_dir}/../../.." && pwd -P)"
export STUDENT_LAB_ROOT
export TEST_SCRATCH="${tmp_dir}"
TEST_UID="$(id -u)"
export TEST_UID
export FAKE_KUBECTL_LOG="${tmp_dir}/kubectl.log"
export FAKE_PREVIOUS_ID=''
export FAKE_PREVIOUS_NAMESPACE=''

for scenario in first old-removed; do
  if [[ "${scenario}" == old-removed ]]; then
    export FAKE_PREVIOUS_ID=20261028-11111111111111111111111111111111
    export FAKE_PREVIOUS_NAMESPACE="p010-aluno-${FAKE_PREVIOUS_ID}"
  fi
  export FAKE_SESSION_SCENARIO="${scenario}"
  export FAKE_EXPECT_SUCCESS=true
  printf '{"unchanged":true}' >"${tmp_dir}/state.json"
  chmod 0600 "${tmp_dir}/state.json"
  : >"${FAKE_KUBECTL_LOG}"
  if ! "${ansible_playbook_bin}" -i 'localhost,' --connection local "${tmp_dir}/session.yml" >"${tmp_dir}/${scenario}.log" 2>&1; then
    cat "${tmp_dir}/${scenario}.log" >&2
    fail "sessão permitida falhou no cenário ${scenario}."
  fi
  if grep -Eq '(^| )(create|apply|delete)( |$)' "${FAKE_KUBECTL_LOG}"; then
    fail 'lab-session tentou criar, aplicar ou remover namespace/objetos.'
  fi
done

for scenario in old-exists candidate-exists api-unavailable; do
  export FAKE_SESSION_SCENARIO="${scenario}"
  export FAKE_EXPECT_SUCCESS=false
  export FAKE_PREVIOUS_ID=''
  export FAKE_PREVIOUS_NAMESPACE=''
  if [[ "${scenario}" == old-exists ]]; then
    export FAKE_PREVIOUS_ID=20261028-11111111111111111111111111111111
    export FAKE_PREVIOUS_NAMESPACE="p010-aluno-${FAKE_PREVIOUS_ID}"
  fi
  printf '{"unchanged":true}' >"${tmp_dir}/state.json"
  chmod 0600 "${tmp_dir}/state.json"
  : >"${FAKE_KUBECTL_LOG}"
  if ! "${ansible_playbook_bin}" -i 'localhost,' --connection local "${tmp_dir}/session.yml" >"${tmp_dir}/${scenario}.log" 2>&1; then
    cat "${tmp_dir}/${scenario}.log" >&2
    fail "guard de sessão não tratou ${scenario} como rejeição esperada."
  fi
  [[ "$(cat "${tmp_dir}/state.json")" == '{"unchanged":true}' ]] \
    || fail "${scenario} alterou state apesar da rejeição."
  if grep -Eq '(^| )(create|apply|delete)( |$)' "${FAKE_KUBECTL_LOG}"; then
    fail "${scenario} tentou criar, aplicar ou remover namespace/objetos."
  fi
done

printf 'test-session: PASS (nova sessão, anterior ausente, colisão, sessão ativa e API indisponível)\n'
