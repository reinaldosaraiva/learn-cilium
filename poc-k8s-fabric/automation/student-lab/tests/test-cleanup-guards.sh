#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-ansible-playbook}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT
case_count=0

fail() {
  printf 'test-cleanup-guards: %s\n' "$1" >&2
  exit 1
}

command -v "${ansible_playbook_bin}" >/dev/null 2>&1 \
  || fail 'ansible-playbook ausente; informe ANSIBLE_PLAYBOOK_BIN.'

mkdir -p "${tmp_dir}/bin"
cat >"${tmp_dir}/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_DOCKER_LOG}"
args=("$@")
if [[ "${args[0]:-}" == --host ]]; then args=("${args[@]:2}"); fi
case "${args[0]:-}" in
  version)
    printf '29.8.1\n'
    exit 0
    ;;
  inspect)
    target="${args[1]:-}"
    case "${FAKE_CLEANUP_SCENARIO}" in
      kind-absent-lower)
        printf '[]\n'
        printf 'error: no such object: %s\n' "${target}" >&2
        exit 1
        ;;
      kind-permission)
        printf 'permission denied while inspecting %s\n' "${target}" >&2
        exit 1
        ;;
      kind-daemon-unavailable)
        printf 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock\n' >&2
        exit 1
        ;;
      kind-generic)
        printf 'rpc error: inspect failed for %s\n' "${target}" >&2
        exit 1
        ;;
      kind-wrong-name)
        printf '[]\n'
        printf 'error: no such object: unrelated-name\n' >&2
        exit 1
        ;;
      kind-wrong-stdout)
        printf '[{"Name":"unrelated"}]\n'
        printf 'error: no such object: %s\n' "${target}" >&2
        exit 1
        ;;
      kind-multiline)
        printf '[]\n'
        printf 'error: no such object: %s\nadditional diagnostic\n' "${target}" >&2
        exit 1
        ;;
      kind-wrong-rc)
        printf '[]\n'
        printf 'error: no such object: %s\n' "${target}" >&2
        exit 2
        ;;
    esac
    if [[ "${FAKE_CLEANUP_SCENARIO}" == kind-error && "${target}" == p010-student-control-plane ]]; then
      printf 'Error response from daemon: No such object: %s\n' "${target}" >&2
      exit 2
    fi
    if [[ "${FAKE_CLEANUP_SCENARIO}" == fabric-error && "${target}" == fabric-node ]]; then
      printf 'Error response from daemon: No such object: %s\n' "${target}" >&2
      exit 2
    fi
    if [[ "${FAKE_CLEANUP_SCENARIO}" == kind-absent || ("${target}" == "${TEST_NODE_ID}" || "${target}" == p010-student-control-plane) && -e "${FAKE_REMOVED_MARKER}" ]]; then
      printf '[]\n'
      printf 'Error: No such object: %s\n' "${target}" >&2
      exit 1
    fi
    if [[ "${target}" == p010-student-control-plane || "${target}" == "${TEST_NODE_ID}" ]]; then
      printf '[{"Id":"%s","Name":"/p010-student-control-plane","Config":{"Labels":{"io.x-k8s.kind.cluster":"p010-student"}},"Mounts":[{"Source":"%s/owner-token","Destination":"/etc/p010-student/owner-token","RW":false}]}]\n' "${TEST_NODE_ID}" "${TEST_SCRATCH}"
      exit 0
    fi
    printf 'Error: No such object: %s\n' "${target}" >&2
    exit 1
    ;;
  rm)
    target="${args[2]:-}"
    if [[ "${target}" == p010-student-control-plane ]]; then
      if [[ "${FAKE_CLEANUP_SCENARIO}" == kind-still-present ]]; then exit 0; fi
      printf 'name-delete\n' >"${FAKE_REMOVED_MARKER}"
      exit 0
    fi
    if [[ "${target}" == "${TEST_NODE_ID}" ]]; then
      if [[ "${FAKE_CLEANUP_SCENARIO}" == kind-still-present ]]; then exit 0; fi
      : >"${FAKE_REMOVED_MARKER}"
      exit 0
    fi
    printf 'unexpected remove target\n' >&2
    exit 2
    ;;
  network)
    if [[ "${args[1]:-}" == inspect ]]; then
      target="${args[2]:-}"
      if [[ "${FAKE_CLEANUP_SCENARIO}" == network-owned && ! -e "${FAKE_REMOVED_MARKER}" ]]; then
        printf '[{"Id":"%s","Name":"p010-net","Labels":{"containerlab":"","p010-student-owner":"22222222-2222-4222-8222-222222222222"},"IPAM":{"Config":[{"Subnet":"10.223.33.0/24"}]}}]\n' "${TEST_NETWORK_ID}"
        exit 0
      fi
      if [[ "${FAKE_CLEANUP_SCENARIO}" == network-error ]]; then
        printf '[]\n'
        printf 'Error response from daemon: network %s not found\n' "${target}" >&2
        exit 2
      fi
      printf '[]\n'
      printf 'Error response from daemon: network %s not found\n' "${target}" >&2
      exit 1
    fi
    if [[ "${args[1]:-}" == rm ]]; then
      target="${args[2]:-}"
      [[ "${target}" == "${TEST_NETWORK_ID}" ]] || exit 2
      : >"${FAKE_REMOVED_MARKER}"
      exit 0
    fi
    ;;
esac
printf 'unexpected fake docker command: %s\n' "$*" >&2
exit 2
SH
chmod 0700 "${tmp_dir}/bin/docker"

cat >"${tmp_dir}/bin/kind" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_KIND_LOG}"
if [[ "${1:-}" == get && "${2:-}" == clusters ]]; then
  if [[ "${FAKE_CLEANUP_SCENARIO}" == owned-kind && ! -e "${FAKE_REMOVED_MARKER}" ]]; then
    printf 'p010-student\n'
  fi
  exit 0
fi
if [[ "${1:-}" == get && "${2:-}" == nodes ]]; then
  if [[ "${FAKE_CLEANUP_SCENARIO}" == owned-kind && ! -e "${FAKE_REMOVED_MARKER}" ]]; then
    printf 'node/p010-student-control-plane\n'
    exit 0
  fi
  exit 1
fi
exit 2
SH
chmod 0700 "${tmp_dir}/bin/kind"

cat >"${tmp_dir}/cleanup.yml" <<'YAML'
- hosts: localhost
  gather_facts: true
  connection: local
  vars:
    ansible_become: false
    student_docker_bin: "{{ lookup('env', 'TEST_SCRATCH') }}/bin/docker"
    student_tool_dir: "{{ lookup('env', 'TEST_SCRATCH') }}/bin"
    student_state_dir: "{{ lookup('env', 'TEST_SCRATCH') }}"
    student_state_file: "{{ lookup('env', 'TEST_SCRATCH') }}/state.json"
    student_env_file: "{{ lookup('env', 'TEST_SCRATCH') }}/lab-env.sh"
    student_owner_token_file: "{{ lookup('env', 'TEST_SCRATCH') }}/owner-token"
    student_uid: "{{ lookup('env', 'TEST_UID') | int }}"
    student_has_state: true
    student_action: down
    student_profile_name: "{{ lookup('env', 'FAKE_PROFILE') }}"
    student_profile:
      kind_name: p010-student
      context: kind-p010-student
      kind_nodes: "{{ ['p010-student-control-plane'] if lookup('env', 'FAKE_CLEANUP_SCENARIO') in ['kind-error', 'kind-absent', 'kind-absent-lower', 'kind-permission', 'kind-daemon-unavailable', 'kind-generic', 'kind-wrong-name', 'kind-wrong-stdout', 'kind-multiline', 'kind-wrong-rc', 'kind-still-present', 'owned-kind'] else [] }}"
      fabric_nodes: "{{ ['fabric-node'] if lookup('env', 'FAKE_CLEANUP_SCENARIO') == 'fabric-error' else [] }}"
      topology_network: "{{ 'p010-net' if lookup('env', 'FAKE_CLEANUP_SCENARIO') in ['network-error', 'network-absent', 'network-owned'] else none }}"
      topology_subnet: 10.223.33.0/24
    student_state:
      schema: 2
      owner_uid: "{{ lookup('env', 'TEST_UID') | int }}"
      owner_token: 22222222-2222-4222-8222-222222222222
      profile: "{{ lookup('env', 'FAKE_PROFILE') }}"
      run_id: 20261029-11111111111111111111111111111111
      status: partial
      phase: failed
      kind_name: p010-student
      context: kind-p010-student
      kubeconfig: "{{ lookup('env', 'TEST_SCRATCH') }}/missing-kubeconfig"
      kubeconfig_sha256: ''
      api_server: ''
      cluster_uid: ''
      kind_node_ids: "{{ {'p010-student-control-plane': lookup('env', 'TEST_NODE_ID')} if lookup('env', 'FAKE_CLEANUP_SCENARIO') in ['kind-error', 'kind-absent', 'kind-absent-lower', 'kind-permission', 'kind-daemon-unavailable', 'kind-generic', 'kind-wrong-name', 'kind-wrong-stdout', 'kind-multiline', 'kind-wrong-rc', 'kind-still-present', 'owned-kind'] else {} }}"
      fabric_node_ids: "{{ {'fabric-node': lookup('env', 'TEST_NODE_ID')} if lookup('env', 'FAKE_CLEANUP_SCENARIO') == 'fabric-error' else {} }}"
      network_ids: "{{ {'p010-net': lookup('env', 'TEST_NETWORK_ID')} if lookup('env', 'FAKE_CLEANUP_SCENARIO') in ['network-error', 'network-absent', 'network-owned'] else {} }}"
      profile_fingerprint: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      chart_sha256: ''
      values_sha256: ''
      topology_sha256: ''
      topology_file: ''
      helm_revision: 0
      clab_up_log: "{{ lookup('env', 'TEST_SCRATCH') }}/containerlab-up.log"
      clab_down_log: "{{ lookup('env', 'TEST_SCRATCH') }}/containerlab-down.log"
      started_utc: 2026-10-29T00:00:00Z
      updated_utc: 2026-10-29T00:00:00Z
      exercise: ''
      wireguard_mode: ''
      exercise_session: {}
  tasks:
    - block:
        - ansible.builtin.include_tasks: "{{ lookup('env', 'STUDENT_LAB_ROOT') }}/poc-k8s-fabric/automation/student-lab/tasks/validate-identities.yml"
        - ansible.builtin.include_tasks: "{{ lookup('env', 'STUDENT_LAB_ROOT') }}/poc-k8s-fabric/automation/student-lab/tasks/down.yml"
      rescue:
        - ansible.builtin.set_fact:
            cleanup_rejected: true
    - name: Require the intended cleanup guard result
      ansible.builtin.assert:
        that:
          - (lookup('env', 'FAKE_EXPECT_REJECTION') == 'true') == (cleanup_rejected | default(false))
          - lookup('env', 'FAKE_CLEANUP_SCENARIO') not in ['owned-kind', 'kind-absent', 'kind-absent-lower'] or student_state.status == 'down'
YAML

export ANSIBLE_CONFIG="${script_dir}/ansible.cfg"
STUDENT_LAB_ROOT="$(cd -- "${script_dir}/../../.." && pwd -P)"
export STUDENT_LAB_ROOT
export TEST_SCRATCH="${tmp_dir}"
TEST_UID="$(id -u)"
export TEST_UID
export TEST_NODE_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export TEST_NETWORK_ID=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export FAKE_DOCKER_LOG="${tmp_dir}/docker.log"
export FAKE_KIND_LOG="${tmp_dir}/kind.log"
export FAKE_REMOVED_MARKER="${tmp_dir}/removed"
printf '%s\n' '22222222-2222-4222-8222-222222222222' >"${tmp_dir}/owner-token"
chmod 0400 "${tmp_dir}/owner-token"

run_case() {
  local scenario="$1" profile="$2" expected_rejection="$3"
  export FAKE_CLEANUP_SCENARIO="${scenario}" FAKE_PROFILE="${profile}" FAKE_EXPECT_REJECTION="${expected_rejection}"
  rm -f -- "${FAKE_REMOVED_MARKER}" "${tmp_dir}/state.json"
  if [[ -e "${tmp_dir}/owner-token" ]]; then chmod 0600 "${tmp_dir}/owner-token"; fi
  printf '%s\n' '22222222-2222-4222-8222-222222222222' >"${tmp_dir}/owner-token"
  chmod 0400 "${tmp_dir}/owner-token"
  : >"${FAKE_DOCKER_LOG}"
  : >"${FAKE_KIND_LOG}"
  if ! "${ansible_playbook_bin}" -i 'localhost,' --connection local "${tmp_dir}/cleanup.yml" >"${tmp_dir}/${scenario}.log" 2>&1; then
    cat "${tmp_dir}/${scenario}.log" >&2
    fail "playbook de cleanup não concluiu a expectativa ${scenario}."
  fi
  case_count=$((case_count + 1))
  printf 'case %02d: %s (rejeição esperada: %s) PASS\n' "${case_count}" "${scenario}" "${expected_rejection}"
}

run_case owned-kind iniciantes false
grep -Fq "rm --force ${TEST_NODE_ID}" "${FAKE_DOCKER_LOG}" \
  || fail 'cleanup do Kind não removeu pelo ID salvo.'
if grep -Fq 'rm --force p010-student-control-plane' "${FAKE_DOCKER_LOG}"; then
  fail 'cleanup do Kind tentou remover pelo nome.'
fi

run_case kind-error iniciantes true
if grep -Fq 'rm ' "${FAKE_DOCKER_LOG}"; then
  fail 'erro de inspect Kind foi tratado como ausência e removeu recurso.'
fi

run_case kind-absent iniciantes false
[[ "$(grep -c 'rm ' "${FAKE_DOCKER_LOG}" || true)" -eq 0 ]] \
  || fail 'cleanup tentou remover um objeto já ausente na forma capitalizada.'

run_case kind-absent-lower iniciantes false
[[ "$(grep -c 'rm ' "${FAKE_DOCKER_LOG}" || true)" -eq 0 ]] \
  || fail 'cleanup tentou remover um objeto já ausente na forma minúscula.'

for scenario in kind-permission kind-daemon-unavailable kind-generic \
  kind-wrong-name kind-wrong-stdout kind-multiline kind-wrong-rc; do
  run_case "${scenario}" iniciantes true
  if grep -Fq 'rm ' "${FAKE_DOCKER_LOG}"; then
    fail "${scenario} foi tratado como ausência e removeu recurso."
  fi
done

run_case kind-still-present iniciantes true

run_case fabric-error plataforma true
if grep -Fq 'rm ' "${FAKE_DOCKER_LOG}"; then
  fail 'erro de inspect containerlab foi tratado como ausência e removeu recurso.'
fi

run_case network-error plataforma true
if grep -Fq 'network rm' "${FAKE_DOCKER_LOG}"; then
  fail 'erro de inspect da rede foi tratado como ausência e removeu rede.'
fi

run_case network-owned plataforma false
grep -Fq "network rm ${TEST_NETWORK_ID}" "${FAKE_DOCKER_LOG}" \
  || fail 'cleanup da rede não removeu pelo ID salvo.'
if grep -Fq 'network rm p010-net' "${FAKE_DOCKER_LOG}"; then
  fail 'cleanup da rede tentou remover pelo nome.'
fi

printf 'test-cleanup-guards: PASS (%d casos; NotFound exato, stdout [] válido e inspect Kind/fabric/rede fail-closed)\n' "${case_count}"
