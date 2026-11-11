#!/usr/bin/env bash
set -euo pipefail

student_lab_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-ansible-playbook}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT

fail() {
  printf 'test-up-state-guard: %s\n' "$1" >&2
  exit 1
}

command -v "${ansible_playbook_bin}" >/dev/null 2>&1 \
  || fail 'ansible-playbook ausente; informe ANSIBLE_PLAYBOOK_BIN.'

cat >"${tmp_dir}/up-prefix.yml" <<YAML
---
- hosts: localhost
  gather_facts: false
  connection: local
  vars:
    ansible_become: false
    student_has_state: "{{ lookup('env', 'TEST_HAS_STATE') | bool }}"
    student_state: "{{ lookup('env', 'TEST_STATE') | from_json }}"
  tasks:
    - ansible.builtin.import_tasks: ${student_lab_dir}/tasks/up.yml
YAML

run_case() {
  local name="$1" has_state="$2" state="$3" expected="$4"
  export TEST_HAS_STATE="${has_state}" TEST_STATE="${state}"
  if "${ansible_playbook_bin}" --inventory 'localhost,' --connection local \
    --tags student-up-state-guard "${tmp_dir}/up-prefix.yml" >"${tmp_dir}/${name}.log" 2>&1; then
    actual=success
  else
    actual=failure
  fi
  [[ "${actual}" == "${expected}" ]] \
    || { cat "${tmp_dir}/${name}.log" >&2; fail "${name}: esperado ${expected}, obtido ${actual}."; }
  grep -Fq 'TASK [Verify instead of reconciling an already healthy recorded lab]' "${tmp_dir}/${name}.log" \
    || fail "${name}: a primeira guarda do prefixo real não foi executada."
  grep -Fq 'TASK [Leave a recorded up lab unchanged after successful verification]' "${tmp_dir}/${name}.log" \
    || fail "${name}: a segunda guarda do prefixo real não foi executada."
  grep -Fq 'TASK [Require explicit cleanup before retrying a partial run]' "${tmp_dir}/${name}.log" \
    || fail "${name}: o guard real de up.yml não foi executado."
  if grep -Fq 'TASK [Create private run directory and persist state before any host change]' "${tmp_dir}/${name}.log"; then
    fail "${name}: o teste ultrapassou o prefixo anterior a prepare-run."
  fi
  printf 'case: %s (%s) PASS\n' "${name}" "${expected}"
}

run_case first-up-no-state false '{}' success
run_case existing-down true '{"status":"down"}' success
run_case existing-partial true '{"status":"partial"}' failure
grep -Fq 'A execução anterior está partial.' "${tmp_dir}/existing-partial.log" \
  || fail 'estado partial não retornou a mensagem de recusa prevista.'

printf 'test-up-state-guard: PASS (3 estados; prefixo real de up.yml antes de prepare-run)\n'
