#!/usr/bin/env bash
set -euo pipefail

student_lab_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
repo_root="$(cd -- "${student_lab_dir}/../../.." && pwd -P)"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-ansible-playbook}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT

fail() {
  printf 'test-ipam-frr-private: %s\n' "$1" >&2
  exit 1
}

command -v "${ansible_playbook_bin}" >/dev/null 2>&1 \
  || fail 'ansible-playbook ausente; informe ANSIBLE_PLAYBOOK_BIN.'

cat >"${tmp_dir}/probe.yml" <<YAML
---
- hosts: localhost
  gather_facts: false
  connection: local
  vars:
    ansible_become: false
    student_repo_root: ${repo_root}
    student_run_dir: "{{ lookup('env', 'TEST_RUN_DIR') }}"
    student_topology_file: "{{ lookup('env', 'TEST_TOPOLOGY_FILE') }}"
    student_uid: $(id -u)
    student_exercise_config:
      ipam: "{{ lookup('env', 'TEST_IPAM_MODE') }}"
  tasks:
    - ansible.builtin.file:
        path: "{{ student_run_dir }}"
        state: directory
        mode: '0700'
    - ansible.builtin.copy:
        src: "{{ student_repo_root }}/poc-k8s-fabric/studies/p003/topo/p003-gw.clab.yml"
        dest: "{{ student_topology_file }}"
        remote_src: true
        owner: "{{ student_uid }}"
        mode: '0600'
    - ansible.builtin.replace:
        path: "{{ student_topology_file }}"
        regexp: '\\.\\./configs/'
        replace: "{{ student_repo_root }}/poc-k8s-fabric/studies/p003/configs/"
    - ansible.builtin.stat:
        path: "{{ student_repo_root }}/poc-k8s-fabric/studies/p003/configs/frr/p003-frr.conf"
        checksum_algorithm: sha256
      register: source_before
    - ansible.builtin.include_tasks: ${student_lab_dir}/tasks/prepare-ipam-frr.yml
    - ansible.builtin.stat:
        path: "{{ student_ipam_frr_private_file }}"
      register: private_config
    - ansible.builtin.stat:
        path: "{{ student_run_dir }}"
      register: private_run_dir
    - ansible.builtin.stat:
        path: "{{ student_repo_root }}/poc-k8s-fabric/studies/p003/configs/frr/p003-frr.conf"
        checksum_algorithm: sha256
      register: source_after
    - ansible.builtin.assert:
        that:
          - private_config.stat.uid | int == student_uid | int
          - private_config.stat.mode == '0644'
          - private_run_dir.stat.mode == '0700'
          - source_before.stat.checksum == source_after.stat.checksum
        fail_msg: 'A cópia FRR não é privada ou a fixture versionada mudou.'
YAML

export ANSIBLE_CONFIG="${student_lab_dir}/ansible.cfg"

run_case() {
  local ipam_mode="$1" run_dir="${tmp_dir}/run-${1}"
  export TEST_IPAM_MODE="${ipam_mode}"
  export TEST_RUN_DIR="${run_dir}"
  export TEST_TOPOLOGY_FILE="${run_dir}/topology.clab.yml"
  mkdir -p "${run_dir}"
  if ! "${ansible_playbook_bin}" --inventory 'localhost,' --connection local \
    "${tmp_dir}/probe.yml" >"${tmp_dir}/${ipam_mode}.log" 2>&1; then
    sed -E 's#'"${repo_root}"'#<REPO>#g' "${tmp_dir}/${ipam_mode}.log" >&2
    fail "preparação privada FRR ${ipam_mode} falhou."
  fi
  local config_file="${run_dir}/p003-frr-ipam.conf"
  grep -Fqx 'route-map RM-FROM-FABRIC permit 10' "${config_file}" \
    || fail "${ipam_mode}: route-map inbound ausente."
  grep -Fqx ' match ip address prefix-list PL-FROM-FABRIC' "${config_file}" \
    || fail "${ipam_mode}: prefix-list não está associada à route-map."
  grep -Fqx '  neighbor 10.254.0.0 route-map RM-FROM-FABRIC in' "${config_file}" \
    || fail "${ipam_mode}: neighbor FRR não usa a route-map inbound."
  grep -Fq "${config_file}" "${TEST_TOPOLOGY_FILE}" \
    || fail "${ipam_mode}: topologia não aponta para a cópia privada."
  if grep -Fq "${repo_root}/poc-k8s-fabric/studies/p003/configs/frr/p003-frr.conf" "${TEST_TOPOLOGY_FILE}"; then
    fail "${ipam_mode}: topologia ainda aponta para o asset versionado."
  fi
  grep -Fqx 'ip prefix-list PL-FROM-FABRIC seq 50 permit 10.251.0.0/16 le 32' "${config_file}" \
    || fail "${ipam_mode}: pool default não está permitido."
  grep -Fqx 'ip prefix-list PL-FROM-FABRIC seq 60 permit 10.250.0.0/16 le 32' "${config_file}" \
    || fail "${ipam_mode}: pool M24/background não está permitido."
  if [[ "${ipam_mode}" == m32 ]]; then
    grep -Fqx 'ip prefix-list PL-FROM-FABRIC seq 70 permit 10.252.0.0/16 le 32' "${config_file}" \
      || fail 'm32: pool M32 não está permitido.'
  elif grep -Fq '10.252.0.0/16' "${config_file}"; then
    fail 'm24: pool M32 foi adicionado sem ser declarado no cenário.'
  fi
  if grep -Eq '^ip prefix-list PL-FROM-FABRIC seq [0-9]+ permit (0\.0\.0\.0/0|10\.0\.0\.0/8|10\.248\.0\.0/13|10\.248\.0\.0/14)( |$)' "${config_file}"; then
    fail "${ipam_mode}: filtro recebeu permissão ampla."
  fi
  printf 'case: %s aplica pools declarados somente em FRR privado e verifica o caminho border inbound PASS\n' "${ipam_mode}"
}

run_case m24
run_case m32

printf 'test-ipam-frr-private: PASS (2 cenários; fixtures intocadas, pools exatos e filtro completo)\n'
