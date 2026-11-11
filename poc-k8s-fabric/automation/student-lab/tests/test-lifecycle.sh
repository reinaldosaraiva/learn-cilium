#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-ansible-playbook}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT

fail() {
  printf 'test-lifecycle: %s\n' "$1" >&2
  exit 1
}

command -v "${ansible_playbook_bin}" >/dev/null 2>&1 \
  || fail 'ansible-playbook ausente; informe ANSIBLE_PLAYBOOK_BIN.'

mkdir -m 0700 "${tmp_dir}/state"
cat >"${tmp_dir}/lifecycle.yml" <<'YAML'
---
- hosts: localhost
  gather_facts: true
  connection: local
  vars:
    student_has_state: "{{ lookup('env', 'TEST_HAS_STATE') | bool }}"
    student_state: "{{ lookup('env', 'TEST_INITIAL_STATE') | from_json }}"
    student_state_dir: "{{ lookup('env', 'TEST_STATE_DIR') }}"
    student_state_file: "{{ student_state_dir }}/state.json"
    student_run_dir: "{{ lookup('env', 'TEST_RUN_DIR') }}"
    student_owner_token_file: "{{ student_run_dir }}/owner-token"
    student_run_id: "{{ lookup('env', 'TEST_RUN_ID') }}"
    student_new_run_id: "{{ student_run_id }}"
    student_new_owner_token: "{{ lookup('env', 'TEST_OWNER_TOKEN') }}"
    student_uid: "{{ lookup('env', 'TEST_UID') | int }}"
    student_profile_name: iniciantes
    student_profile:
      kind_name: p010-student
      context: kind-p010-student
    student_effective_exercise: ''
    student_effective_wireguard_mode: ''
    student_profile_fingerprint: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    student_kubeconfig: "{{ student_run_dir }}/kubeconfig"
  tasks:
    - ansible.builtin.include_tasks: "{{ lookup('env', 'TEST_TASK_DIR') }}/prepare-run.yml"
    - ansible.builtin.include_tasks: "{{ lookup('env', 'TEST_TASK_DIR') }}/verify-state.yml"
    - ansible.builtin.stat:
        path: "{{ student_state_file }}"
        follow: false
      register: state_stat
    - ansible.builtin.stat:
        path: "{{ student_owner_token_file }}"
        follow: false
      register: token_stat
    - ansible.builtin.slurp:
        src: "{{ student_state_file }}"
      register: state_contents
      no_log: true
    - ansible.builtin.slurp:
        src: "{{ student_owner_token_file }}"
      register: token_contents
      no_log: true
    - ansible.builtin.assert:
        that:
          - student_new_run
          - student_has_state
          - student_state.status == 'preparing'
          - student_state.run_id == student_run_id
          - student_state.owner_token == lookup('env', 'TEST_OWNER_TOKEN')
          - student_state.exercise_session == {}
          - state_stat.stat.isreg
          - state_stat.stat.uid | int == student_uid
          - state_stat.stat.mode == '0600'
          - token_stat.stat.isreg
          - token_stat.stat.uid | int == student_uid
          - token_stat.stat.mode == '0400'
          - (state_contents.content | b64decode | from_json).status == 'preparing'
          - (state_contents.content | b64decode | from_json).run_id == student_run_id
          - (state_contents.content | b64decode | from_json).owner_token == lookup('env', 'TEST_OWNER_TOKEN')
          - (token_contents.content | b64decode | trim) == lookup('env', 'TEST_OWNER_TOKEN')
        fail_msg: 'O registro preparing e o token do novo run não foram persistidos antes da verificação.'
      no_log: true
YAML

export ANSIBLE_CONFIG="${script_dir}/ansible.cfg"
export TEST_TASK_DIR="${script_dir}/tasks"
export TEST_STATE_DIR="${tmp_dir}/state"
TEST_UID="$(id -u)"
export TEST_UID

run_case() {
  local name="$1" has_state="$2" initial_state="$3" run_id="$4" token="$5"
  export TEST_HAS_STATE="${has_state}"
  export TEST_INITIAL_STATE="${initial_state}"
  export TEST_RUN_ID="${run_id}"
  export TEST_RUN_DIR="${tmp_dir}/state/runs/${run_id}"
  export TEST_OWNER_TOKEN="${token}"
  if ! "${ansible_playbook_bin}" -i 'localhost,' --connection local \
    "${tmp_dir}/lifecycle.yml" >"${tmp_dir}/${name}.log" 2>&1; then
    cat "${tmp_dir}/${name}.log" >&2
    fail "fluxo ${name} falhou."
  fi
}

run_case first-up false '{}' \
  20261029-11111111111111111111111111111111 \
  11111111-1111-4111-8111-111111111111
run_case re-up-after-down true \
  '{"status":"down","run_id":"20261028-22222222222222222222222222222222","owner_token":"22222222-2222-4222-8222-222222222222"}' \
  20261029-33333333333333333333333333333333 \
  33333333-3333-4333-8333-333333333333

printf 'test-lifecycle: PASS (primeira subida e re-subida persistem state/token e passam o guard de verificação)\n'
