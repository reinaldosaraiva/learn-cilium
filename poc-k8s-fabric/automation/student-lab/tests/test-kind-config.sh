#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-ansible-playbook}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT

fail() {
  printf 'test-kind-config: %s\n' "$1" >&2
  exit 1
}

command -v "${ansible_playbook_bin}" >/dev/null 2>&1 \
  || fail 'ansible-playbook ausente; informe ANSIBLE_PLAYBOOK_BIN.'

cat >"${tmp_dir}/book-source.yml" <<'YAML'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  kubeProxyMode: none
nodes:
  - role: control-plane
    image: kindest/node:v1.35.0@sha256:fixture
  - role: worker
    image: kindest/node:v1.35.0@sha256:fixture
  - role: worker
    image: kindest/node:v1.35.0@sha256:fixture
YAML

cat >"${tmp_dir}/kind-config.yml" <<'YAML'
- hosts: localhost
  gather_facts: false
  connection: local
  vars:
    ansible_become: false
    student_repo_root: "{{ lookup('env', 'STUDENT_LAB_ROOT') }}"
    student_uid: "{{ lookup('env', 'TEST_UID') | int }}"
    student_owner_token_file: "{{ lookup('env', 'TEST_SCRATCH') }}/owner-token"
    student_tool_versions:
      kind_node_image: kindest/node:v1.35.0@sha256:fixture
    student_state:
      owner_token: 22222222-2222-4222-8222-222222222222
    student_kind_config_file: "{{ lookup('env', 'TEST_SCRATCH') }}/beginner-kind.yml"
    student_profile_name: iniciantes
    student_profile:
      kind_nodes: [p010-student-control-plane]
  tasks:
    - ansible.builtin.template:
        src: "{{ student_repo_root }}/poc-k8s-fabric/automation/student-lab/templates/kind-iniciantes.yml.j2"
        dest: "{{ student_kind_config_file }}"
        mode: '0600'
    - ansible.builtin.include_tasks: "{{ student_repo_root }}/poc-k8s-fabric/automation/student-lab/tasks/configure-kind-ownership.yml"

- hosts: localhost
  gather_facts: false
  connection: local
  vars:
    ansible_become: false
    student_repo_root: "{{ lookup('env', 'STUDENT_LAB_ROOT') }}"
    student_uid: "{{ lookup('env', 'TEST_UID') | int }}"
    student_owner_token_file: "{{ lookup('env', 'TEST_SCRATCH') }}/owner-token"
    student_state:
      owner_token: 33333333-3333-4333-8333-333333333333
    student_kind_config_file: "{{ lookup('env', 'TEST_SCRATCH') }}/book-kind.yml"
    student_profile_name: fundamentos
    student_profile:
      kind_nodes: [k01-control-plane, k01-worker, k01-worker2]
  tasks:
    - ansible.builtin.copy:
        src: "{{ lookup('env', 'TEST_SCRATCH') }}/book-source.yml"
        dest: "{{ student_kind_config_file }}"
        mode: '0600'
    - ansible.builtin.include_tasks: "{{ student_repo_root }}/poc-k8s-fabric/automation/student-lab/tasks/configure-kind-ownership.yml"
YAML

export ANSIBLE_CONFIG="${script_dir}/ansible.cfg"
STUDENT_LAB_ROOT="$(cd -- "${script_dir}/../../.." && pwd -P)"
export STUDENT_LAB_ROOT
export TEST_SCRATCH="${tmp_dir}"
TEST_UID="$(id -u)"
export TEST_UID
printf 'fixture owner token\n' >"${tmp_dir}/owner-token"
chmod 0400 "${tmp_dir}/owner-token"

if ! "${ansible_playbook_bin}" -i 'localhost,' --connection local "${tmp_dir}/kind-config.yml" >"${tmp_dir}/run.log" 2>&1; then
  cat "${tmp_dir}/run.log" >&2
  fail 'parse/render estrutural da config Kind falhou.'
fi

grep -Fq 'containerPath: /etc/p010-student/owner-token' "${tmp_dir}/beginner-kind.yml" \
  || fail 'config iniciante não manteve o mount readonly.'
grep -Fq 'p010-student-owner=22222222-2222-4222-8222-222222222222' "${tmp_dir}/beginner-kind.yml" \
  || fail 'config iniciante não manteve o label do owner.'
grep -Fq 'image: kindest/node:v1.35.0@sha256:fixture' "${tmp_dir}/book-kind.yml" \
  || fail 'serialização removeu a imagem Kind original.'
[[ "$(grep -c 'containerPath: /etc/p010-student/owner-token' "${tmp_dir}/book-kind.yml")" -eq 3 ]] \
  || fail 'config de livro não montou o token nos três nós.'
[[ "$(grep -c 'p010-student-owner=33333333-3333-4333-8333-333333333333' "${tmp_dir}/book-kind.yml")" -eq 3 ]] \
  || { cat "${tmp_dir}/book-kind.yml" >&2; fail 'config de livro não serializou o label nos três patches.'; }
if grep -Fq 'when:' "${tmp_dir}/book-kind.yml"; then
  fail 'config Kind incluiu uma chave de tarefa Ansible no YAML do cluster.'
fi

printf 'test-kind-config: PASS (Kind beginner e livro parseados, alterados e reparseados como YAML)\n'
