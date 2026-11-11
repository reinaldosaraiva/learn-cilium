#!/usr/bin/env bash
set -euo pipefail

student_lab_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
project_root="$(cd -- "${student_lab_dir}/../../.." && pwd -P)"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-ansible-playbook}"
if [[ -n "${P010_DOWN35_ARTIFACT_DIR:-}" ]]; then
  tmp_dir="${P010_DOWN35_ARTIFACT_DIR}"
  mkdir -p -- "${tmp_dir}"
  cleanup_tmp=false
else
  tmp_dir="$(mktemp -d)"
  cleanup_tmp=true
fi
cleanup() {
  if [[ "${cleanup_tmp}" == true ]]; then rm -rf -- "${tmp_dir}"; fi
}
trap cleanup EXIT

fail() {
  printf 'test-down-owned-volumes: %s\n' "$1" >&2
  exit 1
}

command -v "${ansible_playbook_bin}" >/dev/null 2>&1 \
  || fail 'ansible-playbook ausente; informe ANSIBLE_PLAYBOOK_BIN.'

export ANSIBLE_CONFIG="${student_lab_dir}/ansible.cfg"
export STUDENT_LAB_ROOT="${project_root}"
export TEST_KIND_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export TEST_FABRIC_ID=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export TEST_OWNER_TOKEN=22222222-2222-4222-8222-222222222222
export TEST_KIND_NAME=p010-student-control-plane
export TEST_FABRIC_NAME=fabric-node

[[ "${TEST_KIND_ID}" =~ ^[0-9a-f]{64}$ ]] || fail 'fixture Kind ID is not a full Docker ID.'
[[ "${TEST_FABRIC_ID}" =~ ^[0-9a-f]{64}$ ]] || fail 'fixture fabric ID is not a full Docker ID.'

mkdir -p -- "${tmp_dir}/bin"
cat >"${tmp_dir}/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
if [[ "${args[0]:-}" == --host ]]; then args=("${args[@]:2}"); fi
{
  printf '%s' "${args[0]:-}"
  for ((i = 1; i < ${#args[@]}; i++)); do printf ' %s' "${args[i]}"; done
  printf '\n'
} >>"${FAKE_DOCKER_LOG}"

not_found() {
  printf '[]\n'
  printf 'Error: No such object: %s\n' "$1" >&2
  exit 1
}

kind_json() {
  printf '[{"Id":"%s","Name":"/%s","Config":{"Labels":{"io.x-k8s.kind.cluster":"p010-student"}},"Mounts":[{"Source":"%s","Destination":"/etc/p010-student/owner-token","RW":false}]}]\n' \
    "${TEST_KIND_ID}" "${TEST_KIND_NAME}" "${TEST_OWNER_TOKEN_FILE}"
}
fabric_json() {
  printf '[{"Id":"%s","Name":"/%s","Config":{"Labels":{"p010-student-owner":"%s"}},"Mounts":[]}]\n' \
    "${TEST_FABRIC_ID}" "${TEST_FABRIC_NAME}" "${TEST_OWNER_TOKEN}"
}

case "${args[0]:-}" in
  version)
    printf '29.8.1\n'
    ;;
  inspect)
    target="${args[1]:-}"
    kind_present="$(cat "${TEST_SCRATCH}/kind-present")"
    fabric_present="$(cat "${TEST_SCRATCH}/fabric-present")"
    if [[ "${kind_present}" == true && ( "${target}" == "${TEST_KIND_ID}" || "${target}" == "${TEST_KIND_NAME}" ) ]]; then
      kind_json
      exit 0
    fi
    if [[ "${fabric_present}" == true && ( "${target}" == "${TEST_FABRIC_ID}" || "${target}" == "${TEST_FABRIC_NAME}" ) ]]; then
      fabric_json
      exit 0
    fi
    not_found "${target}"
    ;;
  rm)
    [[ "${args[1]:-}" == --force ]] || { printf 'unexpected rm flags\n' >&2; exit 2; }
    kind_present="$(cat "${TEST_SCRATCH}/kind-present")"
    fabric_present="$(cat "${TEST_SCRATCH}/fabric-present")"
    use_volumes=false
    target_index=2
    if [[ "${args[2]:-}" == --volumes ]]; then use_volumes=true; target_index=3; fi
    target="${args[${target_index}]:-}"
    [[ ${#args[@]} -eq $((target_index + 1)) ]] || { printf 'unexpected rm argv\n' >&2; exit 2; }
    if [[ "${target}" == "${TEST_KIND_ID}" && "${kind_present}" == true ]]; then
      printf 'false\n' >"${TEST_SCRATCH}/kind-present"
    elif [[ "${target}" == "${TEST_FABRIC_ID}" && "${fabric_present}" == true ]]; then
      printf 'false\n' >"${TEST_SCRATCH}/fabric-present"
    else
      printf 'refusing unknown or absent Docker ID\n' >&2
      exit 2
    fi
    if [[ "${use_volumes}" == true ]]; then
      awk -F '\t' -v id="${target}" '!($1 == id && $2 == "anonymous")' "${FAKE_VOLUME_FILE}" >"${FAKE_VOLUME_FILE}.new"
      cat "${FAKE_VOLUME_FILE}.new" >"${FAKE_VOLUME_FILE}"
    fi
    ;;
  network)
    printf 'unexpected network command\n' >&2
    exit 2
    ;;
  *)
    printf 'unexpected fake Docker command\n' >&2
    exit 2
    ;;
esac
SH
chmod 0700 "${tmp_dir}/bin/docker"

cat >"${tmp_dir}/bin/kind" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_KIND_LOG}"
if [[ "${1:-}" == get && "${2:-}" == clusters ]]; then
  if [[ "$(cat "${TEST_SCRATCH}/kind-present")" == true ]]; then printf 'p010-student\n'; fi
  exit 0
fi
if [[ "${1:-}" == get && "${2:-}" == nodes && "${3:-}" == --name && "${4:-}" == p010-student ]]; then
  if [[ "$(cat "${TEST_SCRATCH}/kind-present")" == true ]]; then printf 'node/%s\n' "${TEST_KIND_NAME}"; fi
  exit 0
fi
printf 'unexpected fake kind command\n' >&2
exit 2
SH
chmod 0700 "${tmp_dir}/bin/kind"

cat >"${tmp_dir}/cleanup.yml" <<'YAML'
- hosts: localhost
  gather_facts: true
  connection: local
  vars:
    ansible_become: false
    student_docker_bin: "{{ lookup('env', 'P010_DOWN35_BIN_DIR') }}/docker"
    student_tool_dir: "{{ lookup('env', 'P010_DOWN35_BIN_DIR') }}"
    student_state_dir: "{{ lookup('env', 'TEST_SCRATCH') }}"
    student_state_file: "{{ lookup('env', 'TEST_SCRATCH') }}/state.json"
    student_env_file: "{{ lookup('env', 'TEST_SCRATCH') }}/lab-env.sh"
    student_owner_token_file: "{{ lookup('env', 'TEST_SCRATCH') }}/owner-token"
    student_uid: "{{ lookup('env', 'TEST_UID') | int }}"
    student_has_state: true
    student_action: down
    student_profile_name: iniciantes
    student_profile:
      kind_name: p010-student
      context: kind-p010-student
      kind_nodes: [p010-student-control-plane]
      fabric_nodes: [fabric-node]
      topology_network: null
    student_state:
      schema: 2
      owner_uid: "{{ lookup('env', 'TEST_UID') | int }}"
      owner_token: 22222222-2222-4222-8222-222222222222
      profile: iniciantes
      run_id: 20261030-11111111111111111111111111111111
      status: "{{ lookup('env', 'FAKE_STATE_STATUS') }}"
      phase: failed
      kind_name: p010-student
      context: kind-p010-student
      kubeconfig: "{{ lookup('env', 'TEST_SCRATCH') }}/missing-kubeconfig"
      kubeconfig_sha256: ''
      api_server: ''
      cluster_uid: ''
      kind_node_ids: "{{ {'p010-student-control-plane': lookup('env', 'TEST_KIND_ID')} if lookup('env', 'FAKE_STATE_STATUS') != 'down' else {} }}"
      fabric_node_ids: "{{ {'fabric-node': lookup('env', 'TEST_FABRIC_ID')} if lookup('env', 'FAKE_STATE_STATUS') != 'down' else {} }}"
      network_ids: {}
      profile_fingerprint: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      chart_sha256: ''
      values_sha256: ''
      topology_sha256: ''
      topology_file: ''
      helm_revision: 0
      clab_up_log: ''
      clab_down_log: ''
      started_utc: '2026-10-30T00:00:00Z'
      updated_utc: '2026-10-30T00:00:00Z'
      exercise: ''
      wireguard_mode: ''
      exercise_session: {}
  tasks:
    - name: Reuse the existing ownership identity gate for active state
      ansible.builtin.include_tasks: "{{ lookup('env', 'STUDENT_LAB_ROOT') }}/poc-k8s-fabric/automation/student-lab/tasks/validate-identities.yml"
      when: student_state.status != 'down'
    - name: Execute the real down task file
      ansible.builtin.include_tasks: "{{ lookup('env', 'STUDENT_DOWN_TASK_FILE') }}"
    - name: Require cleanup to persist down state and clear recorded IDs
      ansible.builtin.assert:
        that:
          - student_state.status == 'down'
          - student_state.kind_node_ids | length == 0
          - student_state.fabric_node_ids | length == 0
    - name: Repeat down tasks against the finalized state
      ansible.builtin.include_tasks: "{{ lookup('env', 'STUDENT_DOWN_TASK_FILE') }}"
YAML

baseline_tasks="${tmp_dir}/baseline/down.yml"
mkdir -p -- "${tmp_dir}/baseline"
if [[ -n "${P010_DOWN35_BASELINE_TASKS:-}" ]]; then
  cp -- "${P010_DOWN35_BASELINE_TASKS}" "${baseline_tasks}"
else
  sed '/^      - --volumes$/d' "${student_lab_dir}/tasks/down.yml" >"${baseline_tasks}"
fi
cp -- "${student_lab_dir}/tasks/down-finalize-state.yml" "${tmp_dir}/baseline/down-finalize-state.yml"

syntax_dir="${tmp_dir}/syntax"
mkdir -p -- "${syntax_dir}"
export TEST_UID="$(id -u)"
export TEST_SCRATCH="${syntax_dir}"
export TEST_OWNER_TOKEN_FILE="${syntax_dir}/owner-token"
export P010_DOWN35_BIN_DIR="${tmp_dir}/bin"
export STUDENT_DOWN_TASK_FILE="${student_lab_dir}/tasks/down.yml"
{
  printf 'start_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'cwd=%s\n' "$PWD"
  printf 'argv='
  printf '%q ' "${ansible_playbook_bin}" --syntax-check -i 'localhost,' --connection local "${tmp_dir}/cleanup.yml"
  printf '\n'
} >"${syntax_dir}/run.meta"
if "${ansible_playbook_bin}" --syntax-check -i 'localhost,' --connection local "${tmp_dir}/cleanup.yml" >"${syntax_dir}/ansible.log" 2>&1; then
  rc=0
else
  rc=$?
  cat "${syntax_dir}/ansible.log" >&2
  fail 'focused Ansible syntax check failed.'
fi
printf 'end_utc=%s\nrc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${rc}" >>"${syntax_dir}/run.meta"
printf 'PASS Ansible syntax-check.\n'

recorded_run() {
  local label="$1" task_file="$2" case_dir="$3" rc
  export STUDENT_DOWN_TASK_FILE="${task_file}"
  export TEST_SCRATCH="${case_dir}"
  export TEST_OWNER_TOKEN_FILE="${case_dir}/owner-token"
  export TEST_UID="$(id -u)"
  export FAKE_DOCKER_LOG="${case_dir}/docker.log"
  export FAKE_KIND_LOG="${case_dir}/kind.log"
  export FAKE_VOLUME_FILE="${case_dir}/volumes.tsv"
  export P010_DOWN35_BIN_DIR="${tmp_dir}/bin"
  mkdir -p -- "${case_dir}"
  : >"${FAKE_DOCKER_LOG}"
  : >"${FAKE_KIND_LOG}"
  printf '%s\n' "${TEST_OWNER_TOKEN}" >"${TEST_OWNER_TOKEN_FILE}"
  chmod 0400 "${TEST_OWNER_TOKEN_FILE}"
  {
    printf 'label=%s\n' "${label}"
    printf 'start_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'cwd=%s\n' "$PWD"
    printf 'argv='
    printf '%q ' "${ansible_playbook_bin}" -i 'localhost,' --connection local "${tmp_dir}/cleanup.yml"
    printf '\n'
  } >>"${case_dir}/run.meta"
  if "${ansible_playbook_bin}" -i 'localhost,' --connection local "${tmp_dir}/cleanup.yml" >"${case_dir}/ansible.log" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  {
    printf 'end_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'rc=%s\n' "${rc}"
  } >>"${case_dir}/run.meta"
  return "${rc}"
}

new_model() {
  local name="$1" kind_present="$2" fabric_present="$3" case_dir="${tmp_dir}/$1"
  mkdir -p -- "${case_dir}"
  printf '%s\n' "${kind_present}" >"${case_dir}/kind-present"
  printf '%s\n' "${fabric_present}" >"${case_dir}/fabric-present"
  : >"${case_dir}/volumes.tsv"
  if [[ "${kind_present}" == true ]]; then
    printf '%s\tanonymous\tkind-anonymous\n%s\tnamed\tkind-named\n' "${TEST_KIND_ID}" "${TEST_KIND_ID}" >>"${case_dir}/volumes.tsv"
  fi
  if [[ "${fabric_present}" == true ]]; then
    printf '%s\tanonymous\tfabric-anonymous\n%s\tnamed\tfabric-named\n' "${TEST_FABRIC_ID}" "${TEST_FABRIC_ID}" >>"${case_dir}/volumes.tsv"
  fi
  printf 'unrelated\tanonymous\tunrelated-anonymous\nunrelated\tnamed\tunrelated-named\n' >>"${case_dir}/volumes.tsv"
  printf '%s' "${case_dir}"
}

assert_no_owned_anonymous_volumes() {
  local volume_file="$1"
  if grep -Eq "^(${TEST_KIND_ID}|${TEST_FABRIC_ID})[[:space:]]+anonymous[[:space:]]" "${volume_file}"; then
    return 1
  fi
}

has_owned_anonymous_volume() {
  local volume_file="$1" id="$2"
  awk -F '\t' -v id="${id}" '$1 == id && $2 == "anonymous" { found = 1 } END { exit !found }' "${volume_file}"
}

assert_active_volumes() {
  local actual="$1" expected="${tmp_dir}/active-expected.tsv"
  printf '%s\tnamed\tkind-named\n%s\tnamed\tfabric-named\nunrelated\tanonymous\tunrelated-anonymous\nunrelated\tnamed\tunrelated-named\n' \
    "${TEST_KIND_ID}" "${TEST_FABRIC_ID}" >"${expected}"
  diff -u "${expected}" "${actual}"
}

case_count=0
baseline_dir="$(new_model counterfactual true true)"
export FAKE_STATE_STATUS=partial
if ! recorded_run counterfactual "${baseline_tasks}" "${baseline_dir}"; then
  cat "${baseline_dir}/ansible.log" >&2
  fail '32e counterfactual Ansible flow did not complete; inspect its preserved log.'
fi
has_owned_anonymous_volume "${baseline_dir}/volumes.tsv" "${TEST_KIND_ID}" \
  || fail 'counterfactual did not retain the kind anonymous volume as expected.'
has_owned_anonymous_volume "${baseline_dir}/volumes.tsv" "${TEST_FABRIC_ID}" \
  || fail 'counterfactual did not retain the fabric anonymous volume as expected.'
printf 'COUNTERFACTUAL FAIL reproduced: original down tasks leave owned anonymous volumes.\n'

active_dir="$(new_model corrected true true)"
export FAKE_STATE_STATUS=partial
if ! recorded_run corrected "${student_lab_dir}/tasks/down.yml" "${active_dir}"; then
  cat "${active_dir}/ansible.log" >&2
  fail 'corrected down task flow failed; inspect its preserved log.'
fi
assert_no_owned_anonymous_volumes "${active_dir}/volumes.tsv" \
  || fail 'corrected cleanup retained an owned anonymous volume.'
assert_active_volumes "${active_dir}/volumes.tsv" \
  || fail 'cleanup did not preserve named and unrelated volumes exactly.'
[[ "$(grep -c '^rm ' "${active_dir}/docker.log" || true)" -eq 2 ]] \
  || fail 'expected exactly two Docker container removals.'
grep -Fq "rm --force --volumes ${TEST_KIND_ID}" "${active_dir}/docker.log" \
  || fail 'Kind removal did not use --volumes and its full saved ID.'
grep -Fq "rm --force --volumes ${TEST_FABRIC_ID}" "${active_dir}/docker.log" \
  || fail 'fabric removal did not use --volumes and its full saved ID.'
if grep -Fq "rm --force ${TEST_KIND_NAME}" "${active_dir}/docker.log" \
  || grep -Fq "rm --force ${TEST_FABRIC_NAME}" "${active_dir}/docker.log" \
  || grep -Fq 'volume rm' "${active_dir}/docker.log"; then
  fail 'cleanup removed by name or issued a volume-name removal.'
fi
case_count=$((case_count + 1))
printf 'case %02d: active owned Kind/fabric full IDs; anonymous volumes removed, named/unrelated retained.\n' "${case_count}"

missing_dir="$(new_model missing false true)"
export FAKE_STATE_STATUS=partial
if ! recorded_run missing "${student_lab_dir}/tasks/down.yml" "${missing_dir}"; then
  cat "${missing_dir}/ansible.log" >&2
  fail 'missing-object flow failed instead of completing from exact NotFound evidence.'
fi
[[ "$(grep -c '^rm ' "${missing_dir}/docker.log" || true)" -eq 1 ]] \
  || fail 'missing saved kind object created an unexpected remove target.'
grep -Fq "rm --force --volumes ${TEST_FABRIC_ID}" "${missing_dir}/docker.log" \
  || fail 'present fabric node was not removed by its saved full ID.'
if grep -Fq "rm --force ${TEST_KIND_ID}" "${missing_dir}/docker.log" \
  || grep -Fq "rm --force ${TEST_KIND_NAME}" "${missing_dir}/docker.log"; then
  fail 'missing Kind object was targeted by a saved ID or guessed name.'
fi
assert_no_owned_anonymous_volumes "${missing_dir}/volumes.tsv" \
  || fail 'missing-object cleanup retained an anonymous volume for the present fabric node.'
case_count=$((case_count + 1))
printf 'case %02d: missing Kind inspect result caused no guessed-ID/name removal.\n' "${case_count}"

already_down_dir="$(new_model already-down false false)"
export FAKE_STATE_STATUS=down
if ! recorded_run already-down "${student_lab_dir}/tasks/down.yml" "${already_down_dir}"; then
  cat "${already_down_dir}/ansible.log" >&2
  fail 'already-down flow failed.'
fi
if grep -q '^rm ' "${already_down_dir}/docker.log"; then
  fail 'already-down call emitted a Docker rm.'
fi
[[ "$(wc -l <"${already_down_dir}/volumes.tsv" | tr -d ' ')" -eq 2 ]] \
  || fail 'already-down call changed unrelated volumes.'
case_count=$((case_count + 1))
printf 'case %02d: repeated already-down call emitted no rm and preserved unrelated volumes.\n' "${case_count}"

printf 'test-down-owned-volumes: PASS (%d corrected-flow cases; counterfactual leak reproduced)\n' "${case_count}"
