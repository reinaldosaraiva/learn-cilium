#!/usr/bin/env bash
set -euo pipefail

student_lab_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
repo_root="$(cd -- "${student_lab_dir}/../../.." && pwd -P)"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-ansible-playbook}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT

fail() {
  printf 'test-ansible-scenarios: %s\n' "$1" >&2
  exit 1
}

command -v "${ansible_playbook_bin}" >/dev/null 2>&1 \
  || fail 'ansible-playbook ausente; informe ANSIBLE_PLAYBOOK_BIN.'

cat >"${tmp_dir}/syntax.yml" <<YAML
---
- hosts: localhost
  gather_facts: false
  connection: local
  tasks:
    - ansible.builtin.import_tasks: ${student_lab_dir}/tasks/up.yml
    - ansible.builtin.import_tasks: ${student_lab_dir}/tasks/save-state.yml
    - ansible.builtin.import_tasks: ${student_lab_dir}/tasks/rescue-up.yml
    - ansible.builtin.import_tasks: ${student_lab_dir}/tasks/validate-identities.yml
    - ansible.builtin.import_tasks: ${student_lab_dir}/tasks/down.yml
    - ansible.builtin.import_tasks: ${student_lab_dir}/tasks/select-scenario.yml
    - ansible.builtin.import_tasks: ${student_lab_dir}/tasks/verify.yml
    - ansible.builtin.import_tasks: ${student_lab_dir}/tasks/apply-scenario.yml
    - ansible.builtin.import_tasks: ${student_lab_dir}/tasks/apply-auth.yml
    - ansible.builtin.import_tasks: ${student_lab_dir}/tasks/apply-tenants.yml
    - ansible.builtin.import_tasks: ${student_lab_dir}/tasks/apply-ipam.yml
    - ansible.builtin.import_tasks: ${student_lab_dir}/tasks/prepare-ipam-frr.yml
    - ansible.builtin.import_tasks: ${student_lab_dir}/tasks/verify-auth.yml
    - ansible.builtin.import_tasks: ${student_lab_dir}/tasks/verify-wireguard.yml
    - ansible.builtin.import_tasks: ${student_lab_dir}/tasks/verify-tenants.yml
    - ansible.builtin.import_tasks: ${student_lab_dir}/tasks/verify-ipam.yml
    - ansible.builtin.import_tasks: ${student_lab_dir}/tasks/verify-ipam-no-match.yml
YAML

ANSIBLE_CONFIG="${student_lab_dir}/ansible.cfg" "${ansible_playbook_bin}" \
  --syntax-check --inventory 'localhost,' --connection local "${tmp_dir}/syntax.yml" \
  >/dev/null || fail 'Ansible não conseguiu analisar todas as tarefas dos cenários.'

cat >"${tmp_dir}/assets.yml" <<YAML
---
- hosts: localhost
  gather_facts: false
  connection: local
  vars:
    student_repo_root: ${repo_root}
  tasks:
    - ansible.builtin.include_vars:
        file: ${student_lab_dir}/vars.yml
    - ansible.builtin.set_fact:
        student_ipam_fixture_nodes:
          items:
            - spec:
                ipam:
                  pools:
                    allocated:
                      - pool: p003-m24
                        cidrs: [10.250.4.0/24]
                      - pool: p003-m32
                        cidrs: [10.252.0.17/32]
            - spec: {}
    - ansible.builtin.set_fact:
        student_ipam_fixture_allocations: >-
          {{ (student_ipam_fixture_nodes['items']
              | map(attribute='spec.ipam.pools.allocated') | select('defined') | list | flatten
              | selectattr('pool', 'equalto', 'p003-m32')
              | map(attribute='cidrs') | list | flatten) }}
    - ansible.builtin.assert:
        that:
          - student_ipam_fixture_allocations == ['10.252.0.17/32']
    - ansible.builtin.set_fact:
        student_tenant_namespace_documents: >-
          {{ lookup('file', student_repo_root ~ '/poc-k8s-fabric/studies/p003/cases/s009/01-namespaces.yaml')
             | from_yaml_all | list
             | selectattr('metadata.name', 'defined')
             | selectattr('metadata.name', 'in', ['p003-tenant-a', 'p003-tenant-b']) | list }}
        student_tenant_serviceaccount_documents: >-
          {{ lookup('file', student_repo_root ~ '/poc-k8s-fabric/studies/p003/cases/s009/03-rbac.yaml')
             | from_yaml_all | list
             | selectattr('kind', 'defined') | selectattr('kind', 'equalto', 'ServiceAccount')
             | selectattr('metadata.name', 'in', ['p003-tenant-a-app', 'p003-tenant-b-app']) | list }}
        student_ipam_m24_documents: >-
          {{ lookup('file', student_repo_root ~ '/poc-k8s-fabric/studies/p003/cases/s010/01-m24-setup.yaml')
             | from_yaml_all | list }}
        student_ipam_m32_documents: >-
          {{ (lookup('file', student_repo_root ~ '/poc-k8s-fabric/studies/p003/cases/s010/06-m32-setup.yaml')
              | from_yaml_all | list)
             + (lookup('file', student_repo_root ~ '/poc-k8s-fabric/studies/p003/cases/s010/01-m24-setup.yaml')
                | from_yaml_all | list
                | selectattr('kind', 'defined') | selectattr('kind', 'equalto', 'CiliumPodIPPool')
                | selectattr('metadata.name', 'equalto', 'p003-m24') | list) }}
    - ansible.builtin.assert:
        that:
          - student_tenant_namespace_documents | map(attribute='metadata.name') | sort == ['p003-tenant-a', 'p003-tenant-b']
          - student_tenant_serviceaccount_documents | map(attribute='metadata.name') | sort == ['p003-tenant-a-app', 'p003-tenant-b-app']
          - student_ipam_m24_documents | map(attribute='metadata.name') | list == ['p003-ipam', 'default', 'p003-m24']
          - student_ipam_m32_documents | map(attribute='metadata.name') | list == ['p003-ipam32', 'p003-m32', 'p003-m24']
    - ansible.builtin.template:
        src: ${student_lab_dir}/templates/selected-documents.yml.j2
        dest: "{{ lookup('env', 'TEST_OUTPUT') }}"
      vars:
        student_selected_documents: "{{ student_ipam_m32_documents }}"
    - ansible.builtin.set_fact:
        rendered_ipam_manifest: "{{ lookup('file', lookup('env', 'TEST_OUTPUT')) | from_yaml_all | list }}"
    - ansible.builtin.assert:
        that:
          - rendered_ipam_manifest | map(attribute='metadata.name') | list == ['p003-ipam32', 'p003-m32', 'p003-m24']
YAML

TEST_OUTPUT="${tmp_dir}/selected-ipam.yaml" ANSIBLE_CONFIG="${student_lab_dir}/ansible.cfg" \
  "${ansible_playbook_bin}" --inventory 'localhost,' --connection local "${tmp_dir}/assets.yml" \
  >"${tmp_dir}/assets.log" 2>&1 \
  || { cat "${tmp_dir}/assets.log" >&2; fail 'falha ao filtrar e renderizar assets S009/S010 privados.'; }

cat >"${tmp_dir}/render.yml" <<YAML
---
- hosts: localhost
  gather_facts: false
  connection: local
  tasks:
    - ansible.builtin.include_vars:
        file: ${student_lab_dir}/vars.yml
    - ansible.builtin.set_fact:
        student_exercise_config: "{{ student_exercises[lookup('env', 'TEST_EXERCISE')] }}"
        student_effective_wireguard_mode: "{{ lookup('env', 'TEST_WG') }}"
    - ansible.builtin.template:
        src: ${student_lab_dir}/templates/scenario-values.yml.j2
        dest: "{{ lookup('env', 'TEST_OUTPUT') }}"
    - ansible.builtin.set_fact:
        rendered_scenario_values: "{{ lookup('file', lookup('env', 'TEST_OUTPUT')) | from_yaml }}"
    - ansible.builtin.assert:
        that:
          - >-
            ('ipam' in student_exercise_config and
             rendered_scenario_values.ipv4NativeRoutingCIDR == '10.248.0.0/13' and
             rendered_scenario_values.ipam.mode == 'multi-pool' and
             rendered_scenario_values.ipam.multiPoolPreAllocation ==
             ('default=8,p003-m24=8' if student_exercise_config.ipam == 'm24' else 'default=8,p003-m24=8,p003-m32=8') and
             'default' in rendered_scenario_values.ipam.operator.autoCreateCiliumPodIPPools and
             'p003-m24' in rendered_scenario_values.ipam.operator.autoCreateCiliumPodIPPools and
             ('p003-m32' in rendered_scenario_values.ipam.operator.autoCreateCiliumPodIPPools if student_exercise_config.ipam == 'm32' else 'p003-m32' not in rendered_scenario_values.ipam.operator.autoCreateCiliumPodIPPools)) or
            ('routing_mode' in student_exercise_config and
             rendered_scenario_values.routingMode == student_exercise_config.routing_mode and
             rendered_scenario_values.encryption.enabled == (lookup('env', 'TEST_WG') in ['W1', 'W2']) and
             rendered_scenario_values.encryption.nodeEncryption == (lookup('env', 'TEST_WG') == 'W2') and
             (rendered_scenario_values.autoDirectNodeRoutes == false if student_exercise_config.routing_mode == 'tunnel' else 'autoDirectNodeRoutes' not in rendered_scenario_values) and
             (rendered_scenario_values.tunnelProtocol == 'vxlan' if student_exercise_config.routing_mode == 'tunnel' else 'tunnelProtocol' not in rendered_scenario_values))
        fail_msg: 'Valores de cenário renderizados diferem do contrato WireGuard/IPAM.'
YAML

render_scenario() {
  local exercise="$1" wg="$2"
  TEST_EXERCISE="${exercise}" TEST_WG="${wg}" TEST_OUTPUT="${tmp_dir}/values.yml" \
    ANSIBLE_CONFIG="${student_lab_dir}/ansible.cfg" "${ansible_playbook_bin}" \
      --inventory 'localhost,' --connection local "${tmp_dir}/render.yml" >"${tmp_dir}/render.log" 2>&1 \
      || { cat "${tmp_dir}/render.log" >&2; cat "${tmp_dir}/values.yml" >&2; fail "falha ao renderizar EXERCISE=${exercise} WG=${wg:-default}"; }
}

render_scenario ipam24 ''
cp "${tmp_dir}/values.yml" "${tmp_dir}/ipam24-values.yml"
render_scenario ipam32 ''
cp "${tmp_dir}/values.yml" "${tmp_dir}/ipam32-values.yml"
for exercise in wireguard-native wireguard-vxlan; do
  for mode in W0 W1 W2; do
    render_scenario "${exercise}" "${mode}"
  done
done

ipv4_to_integer() {
  local first second third fourth
  IFS=. read -r first second third fourth <<<"$1"
  printf '%u' "$(( (first << 24) | (second << 16) | (third << 8) | fourth ))"
}

cidr_contains_ip() {
  local network="${1%/*}" prefix="${1#*/}" ip_number network_number mask
  ip_number="$(ipv4_to_integer "$2")"
  network_number="$(ipv4_to_integer "${network}")"
  mask="$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))"
  (( (ip_number & mask) == (network_number & mask) ))
}

check_ipam_pool_coverage() {
  local values_file="$1" native_cidr pool_cidr pool_start pool_end first second third fourth
  native_cidr="$(awk -F': ' '/^ipv4NativeRoutingCIDR:/ {gsub(/\"/, "", $2); print $2}' "${values_file}")"
  [[ "${native_cidr}" == '10.248.0.0/13' ]] \
    || fail "${values_file} não declarou o native CIDR aprovado."
  local pool_count=0
  while IFS= read -r pool_cidr; do
    pool_count=$((pool_count + 1))
    pool_start="${pool_cidr%/*}"
    IFS=. read -r first second third fourth <<<"${pool_start}"
    pool_end="${first}.${second}.255.255"
    [[ "${pool_cidr#*/}" == 16 ]] \
      || fail "CIDR de pool inesperado: ${pool_cidr}."
    cidr_contains_ip "${native_cidr}" "${pool_start}" \
      && cidr_contains_ip "${native_cidr}" "${pool_end}" \
      || fail "${native_cidr} não contém todo o pool ${pool_cidr}."
  done < <(rg --no-filename -o '10\.(250|251|252)\.0\.0/16' \
    "${repo_root}/poc-k8s-fabric/studies/p003/cases/s010/01-m24-setup.yaml" \
    "${repo_root}/poc-k8s-fabric/studies/p003/cases/s010/06-m32-setup.yaml" | sort -u)
  [[ "${pool_count}" == 3 ]] \
    || fail "esperava três pools declarados, encontrei ${pool_count}."
  ! cidr_contains_ip '10.248.0.0/14' '10.252.0.0' \
    || fail '/14 ainda cobre indevidamente a pool boundary que motivou a errata.'
  printf 'case: %s contém os intervalos completos dos três pools S010 PASS\n' "${values_file##*/}"
}

check_ipam_pool_coverage "${tmp_dir}/ipam24-values.yml"
check_ipam_pool_coverage "${tmp_dir}/ipam32-values.yml"

cat >"${tmp_dir}/selection.yml" <<YAML
---
- hosts: localhost
  gather_facts: false
  connection: local
  vars:
    student_profile_name: plataforma
    student_action: "{{ lookup('env', 'TEST_ACTION') }}"
    student_has_state: "{{ lookup('env', 'TEST_HAS_STATE') | bool }}"
    student_state: "{{ lookup('env', 'TEST_STATE') | from_json }}"
    student_exercise_input: "{{ lookup('env', 'TEST_EXERCISE') }}"
    student_wireguard_input: "{{ lookup('env', 'TEST_WG') }}"
  tasks:
    - ansible.builtin.include_vars:
        file: ${student_lab_dir}/vars.yml
    - ansible.builtin.include_tasks: ${student_lab_dir}/tasks/select-scenario.yml
    - ansible.builtin.assert:
        that:
          - student_effective_exercise == lookup('env', 'TEST_EXPECT_EXERCISE')
          - student_effective_wireguard_mode == lookup('env', 'TEST_EXPECT_WG')
YAML

run_selection_case() {
  local name="$1" action="$2" has_state="$3" state="$4" exercise="$5" wg="$6" expected_exercise="$7" expected_wg="$8"
  TEST_ACTION="${action}" TEST_HAS_STATE="${has_state}" TEST_STATE="${state}" \
    TEST_EXERCISE="${exercise}" TEST_WG="${wg}" \
    TEST_EXPECT_EXERCISE="${expected_exercise}" TEST_EXPECT_WG="${expected_wg}" \
    ANSIBLE_CONFIG="${student_lab_dir}/ansible.cfg" \
    "${ansible_playbook_bin}" --inventory 'localhost,' --connection local "${tmp_dir}/selection.yml" \
      >"${tmp_dir}/selection-${name}.log" 2>&1 \
      || { cat "${tmp_dir}/selection-${name}.log" >&2; fail "seleção de cenário incorreta: ${name}"; }
}

run_selection_case reup-after-wg-down up true \
  '{"profile":"plataforma","status":"down","exercise":"wireguard-native","wireguard_mode":"W1"}' \
  auth '' auth ''
run_selection_case status-retains-wg status true \
  '{"profile":"plataforma","status":"up","exercise":"wireguard-native","wireguard_mode":"W1"}' \
  '' '' wireguard-native W1
run_selection_case new-vxlan-wg up false '{}' wireguard-vxlan W2 wireguard-vxlan W2
run_selection_case preflight-ipam-after-down preflight true \
  '{"profile":"plataforma","status":"down","exercise":"wireguard-vxlan","wireguard_mode":"W2"}' \
  ipam32 '' ipam32 ''

bash "${student_lab_dir}/tests/test-ipam-probe.sh"
bash "${student_lab_dir}/tests/test-ipam-frr-private.sh"
bash "${student_lab_dir}/tests/test-ipam-route.sh"
bash "${student_lab_dir}/tests/test-auth-placement.sh"
bash "${student_lab_dir}/tests/test-wireguard-guards.sh"
bash "${student_lab_dir}/tests/test-tenant-causality.sh"
bash "${student_lab_dir}/tests/test-save-state-guards.sh"
bash "${student_lab_dir}/tests/test-down-idempotency.sh"

printf 'test-ansible-scenarios: PASS (syntax, seleção de ciclo, overlays, Auth/WireGuard, tenants e IPAM)\n'
