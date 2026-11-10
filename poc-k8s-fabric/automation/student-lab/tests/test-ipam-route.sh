#!/usr/bin/env bash
set -euo pipefail

student_lab_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-ansible-playbook}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT

fail() {
  printf 'test-ipam-route: %s\n' "$1" >&2
  exit 1
}

command -v "${ansible_playbook_bin}" >/dev/null 2>&1 \
  || fail 'ansible-playbook ausente; informe ANSIBLE_PLAYBOOK_BIN.'

mkdir -p "${tmp_dir}/bin"
cat >"${tmp_dir}/bin/docker" <<'SH'
#!/usr/bin/env bash
set -u
printf '%q ' "$@" >>"${FAKE_DOCKER_LOG}"
printf '\n' >>"${FAKE_DOCKER_LOG}"
case "${FAKE_ROUTE_CASE}" in
  matching) printf 'BGP table version is 42, local router ID is 10.0.0.1\n*> 10.250.4.0/24 10.223.32.2 0 100 0 65001 i\n' ;;
  wrong-prefix) printf '*> 10.250.5.0/24 10.223.32.2 0 100 0 65001 i\n' ;;
  absent) printf 'BGP table version is 42, local router ID is 10.0.0.1\n' ;;
  daemon) printf 'Cannot connect to the Docker daemon\n' >&2; exit 125 ;;
  *) exit 91 ;;
esac
SH
chmod 0700 "${tmp_dir}/bin/docker"

sed -e "s|/usr/bin/docker|${tmp_dir}/bin/docker|g" \
  -e 's/^  retries: 60$/  retries: 1/' \
  -e 's/^  delay: 5$/  delay: 0/' \
  -e 's|ansible.builtin.include_tasks: verify-ipam-no-match.yml|ansible.builtin.debug: msg="route probe only"|' \
  "${student_lab_dir}/tasks/verify-ipam.yml" >"${tmp_dir}/verify-ipam.yml"

cat >"${tmp_dir}/probe.yml" <<YAML
---
- hosts: localhost
  gather_facts: false
  connection: local
  vars:
    ansible_become: false
    student_state:
      kubeconfig: FAKE-ONLY
    student_tool_dir: "{{ lookup('env', 'TEST_BIN_DIR') }}"
    student_exercise_config:
      ipam: m24
    student_ipam_route_prefix: 10.250.4.0/24
    student_profile:
      context: kind-p003-gw
      fabric_nodes:
        - clab-p003-gw-fabric-spine1
        - clab-p003-gw-fabric-border1
  tasks:
    - ansible.builtin.import_tasks: ${tmp_dir}/verify-ipam.yml
YAML

export ANSIBLE_CONFIG="${student_lab_dir}/ansible.cfg"
export TEST_BIN_DIR="${tmp_dir}/bin"

run_case() {
  local scenario="$1" expected="$2"
  export FAKE_ROUTE_CASE="${scenario}" FAKE_DOCKER_LOG="${tmp_dir}/${scenario}.docker.calls"
  : >"${FAKE_DOCKER_LOG}"
  if "${ansible_playbook_bin}" --inventory 'localhost,' --connection local \
    --start-at-task 'Wait for the actual allocated block to appear in the FRR border RIB' \
    "${tmp_dir}/probe.yml" >"${tmp_dir}/${scenario}.log" 2>&1; then
    actual=success
  else
    actual=failure
  fi
  [[ "${actual}" == "${expected}" ]] \
    || { cat "${tmp_dir}/${scenario}.log" >&2; fail "${scenario}: esperado ${expected}, obtido ${actual}."; }
  grep -Fq 'clab-p003-gw-fabric-border1' "${FAKE_DOCKER_LOG}" \
    || fail "${scenario} não consultou o FRR border1."
  grep -Fq 'vtysh' "${FAKE_DOCKER_LOG}" \
    || fail "${scenario} não consultou o RIB do FRR."
}

run_case matching success
grep -Fq 'show\ ip\ bgp' "${FAKE_DOCKER_LOG}" \
  || fail 'consulta não usou o RIB BGP esperado.'
printf 'case: prefixo alocado exato encontrado no FRR border1 PASS\n'

for scenario in wrong-prefix absent daemon; do
  run_case "${scenario}" failure
  printf 'case: %s não satisfaz evidência de rota FRR PASS\n' "${scenario}"
done

printf 'test-ipam-route: PASS (4 casos; FRR border1, prefixo exato e erros inconclusivos rejeitados)\n'
