#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-ansible-playbook}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT

fail() {
  printf 'test-security-guards: %s\n' "$1" >&2
  exit 1
}

if ! command -v "${ansible_playbook_bin}" >/dev/null 2>&1; then
  fail 'ansible-playbook ausente; informe ANSIBLE_PLAYBOOK_BIN.'
fi

export TEST_SCRATCH="${tmp_dir}"
export TEST_OWNER_TOKEN='22222222-2222-4222-8222-222222222222'
export TEST_NETWORK_ID='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
export TEST_NODE_ID='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
TEST_UID="$(id -u)"
STUDENT_LAB_ROOT="$(cd -- "${script_dir}/../../.." && pwd -P)"
export TEST_UID STUDENT_LAB_ROOT
export FAKE_DOCKER_LOG="${tmp_dir}/docker.log"
export FAKE_KUBECTL_LOG="${tmp_dir}/kubectl.log"
export FAKE_CANARY_COUNTER="${tmp_dir}/namespace-gets"

mkdir -p "${tmp_dir}/bin" "${tmp_dir}/runtime"
printf '%s\n' "${TEST_OWNER_TOKEN}" >"${tmp_dir}/owner-token"
chmod 0400 "${tmp_dir}/owner-token"
: >"${tmp_dir}/owner-token-empty"
chmod 0400 "${tmp_dir}/owner-token-empty"
printf 'chart fixture\n' >"${tmp_dir}/fixture-chart.tgz"

cat >"${tmp_dir}/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_DOCKER_LOG}"
if [[ "${1:-}" == --host ]]; then
  shift 2
fi
if [[ "${1:-}" == ps ]]; then
  if [[ "${FAKE_DOCKER_SCENARIO:-}" == precreate ]]; then
    printf 'kind-p010-student-control-plane\n'
  fi
  if [[ "${FAKE_DOCKER_SCENARIO:-}" == collision-list-error ]]; then
    printf 'permission denied while listing containers\n' >&2
    exit 1
  fi
  exit 0
fi
if [[ "${1:-}" == inspect ]]; then
  case "${FAKE_DOCKER_SCENARIO:-}" in
    collision-present)
      printf '[{"Id":"%s","Name":"/p010-student-control-plane","Config":{"Labels":{"io.x-k8s.kind.cluster":"p010-student"}},"Mounts":[]} ]\n' "${TEST_NODE_ID}"
      exit 0
      ;;
    collision-upper-absent)
      printf '[]\n'
      printf 'Error: No such object: %s\n' "${2:-unknown}" >&2
      exit 1
      ;;
    collision-lower-absent|collision-network-absent|collision-network-wrong-stdout)
      printf '[]\n'
      printf 'error: no such object: %s\n' "${2:-unknown}" >&2
      exit 1
      ;;
    collision-permission)
      printf 'permission denied while inspecting %s\n' "${2:-unknown}" >&2
      exit 1
      ;;
    collision-daemon-unavailable)
      printf 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock\n' >&2
      exit 1
      ;;
    collision-generic)
      printf 'rpc error: inspect failed for %s\n' "${2:-unknown}" >&2
      exit 1
      ;;
    collision-wrong-name)
      printf '[]\n'
      printf 'error: no such object: unrelated-name\n' >&2
      exit 1
      ;;
    collision-wrong-stdout)
      printf '[{"Name":"unrelated"}]\n'
      printf 'error: no such object: %s\n' "${2:-unknown}" >&2
      exit 1
      ;;
    collision-multiline)
      printf '[]\n'
      printf 'error: no such object: %s\nadditional diagnostic\n' "${2:-unknown}" >&2
      exit 1
      ;;
    collision-wrong-rc)
      printf '[]\n'
      printf 'error: no such object: %s\n' "${2:-unknown}" >&2
      exit 2
      ;;
  esac
  if [[ "${FAKE_DOCKER_SCENARIO:-}" == foreign-kind ]]; then
    printf '[{"Id":"%s","Name":"/p010-student-control-plane","Config":{"Labels":{"io.x-k8s.kind.cluster":"p010-student"}},"Mounts":[]}]\n' "${TEST_NODE_ID}"
    exit 0
  fi
  if [[ "${FAKE_DOCKER_SCENARIO:-}" == owned-kind ]]; then
    printf '[{"Id":"%s","Name":"/p010-student-control-plane","Config":{"Labels":{"io.x-k8s.kind.cluster":"p010-student"}},"Mounts":[{"Source":"%s/owner-token","Destination":"/etc/p010-student/owner-token","RW":false}]}]\n' "${TEST_NODE_ID}" "${TEST_SCRATCH}"
    exit 0
  fi
  if [[ "${FAKE_DOCKER_SCENARIO:-}" == owned-fabric ]]; then
    printf '[{"Id":"%s","Name":"/clab-test-fabric-node","Config":{"Labels":{"p010-student-owner":"%s"}},"Mounts":[]}]\n' "${TEST_NODE_ID}" "${TEST_OWNER_TOKEN}"
    exit 0
  fi
  printf 'Error: No such object: %s\n' "${2:-unknown}" >&2
  exit 1
fi
if [[ "${1:-}" == network && "${2:-}" == inspect ]]; then
  if [[ "${FAKE_DOCKER_SCENARIO:-}" == collision-network-absent ]]; then
    printf '[]\n'
    printf 'Error response from daemon: network p010-net not found\n' >&2
    exit 1
  fi
  if [[ "${FAKE_DOCKER_SCENARIO:-}" == collision-network-wrong-stdout ]]; then
    printf '[{"Name":"unrelated"}]\n'
    printf 'Error response from daemon: network p010-net not found\n' >&2
    exit 1
  fi
  label="${TEST_OWNER_TOKEN}"
  [[ "${FAKE_DOCKER_SCENARIO:-}" == foreign-network ]] && label='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
  printf '[{"Id":"%s","Name":"student-net","Labels":{"containerlab":"","p010-student-owner":"%s"},"IPAM":{"Config":[{"Subnet":"10.1.0.0/24"}]}}]\n' "${TEST_NETWORK_ID}" "${label}"
  exit 0
fi
printf 'unexpected fake docker command\n' >&2
exit 2
SH
chmod 0700 "${tmp_dir}/bin/docker"

cat >"${tmp_dir}/bin/kubectl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"${FAKE_KUBECTL_LOG}"
args=("$@")
command_name=''
command_index=-1
for ((i = 0; i < ${#args[@]}; i += 1)); do
  case "${args[i]}" in
    get|create|apply|rollout|wait|logs|delete)
      command_name="${args[i]}"
      command_index="${i}"
      break
      ;;
  esac
done
object_name="${args[command_index + 1]:-}"
second_name="${args[command_index + 2]:-}"

if [[ "${FAKE_KUBECTL_SCENARIO:-}" == owner-* && "${command_name}" == get && "${object_name}" == nodes ]]; then
  case "${FAKE_KUBECTL_SCENARIO}" in
    owner-owned) printf '%s\n' 'p010-student-control-plane' ;;
    owner-drift) exit 0 ;;
    owner-unavailable) printf 'The connection to the server 127.0.0.1:32771 was refused - did you specify the right host or port?\n' >&2; exit 1 ;;
  esac
  exit 0
fi

if [[ "${FAKE_KUBECTL_SCENARIO:-}" == canary-* ]]; then
  case "${command_name}:${object_name}:${second_name}" in
    rollout:status:deployment/hubble-relay) exit 0 ;;
    get:service:hubble-relay) printf 'ClusterIP 80 grpc\n'; exit 0 ;;
    get:endpoints:hubble-relay) printf '10.1.0.10\n'; exit 0 ;;
    get:deployment:hubble-relay) printf '4245\n'; exit 0 ;;
    get:deployments:--namespace)
      if [[ "${args[*]}" == *kube-system* ]]; then printf 'deployment.apps/cilium-operator\n'; exit 0; fi
      ;;
    get:namespace:*)
      count=0
      [[ -f "${FAKE_CANARY_COUNTER}" ]] && read -r count <"${FAKE_CANARY_COUNTER}"
      count=$((count + 1))
      printf '%s\n' "${count}" >"${FAKE_CANARY_COUNTER}"
      case "${FAKE_KUBECTL_SCENARIO}:${count}" in
        canary-foreign:1)
          printf '{"kind":"Namespace","metadata":{"name":"%s","uid":"22222222-2222-4222-8222-222222222222","labels":{"p010-student-owner":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"},"annotations":{"p010-student-owner-token":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}}}\n' "${FAKE_CANARY_NAMESPACE}"
          exit 0
          ;;
        canary-positive:1|canary-apply-foreign:1)
          printf 'Error from server (NotFound): namespaces "%s" not found\n' "${FAKE_CANARY_NAMESPACE}" >&2
          exit 1
          ;;
        canary-positive:2|canary-positive:3|canary-apply-foreign:2)
          printf '{"kind":"Namespace","metadata":{"name":"%s","uid":"11111111-1111-4111-8111-111111111111","labels":{"p010-student-owner":"%s"},"annotations":{"p010-student-owner-token":"%s"}}}\n' "${FAKE_CANARY_NAMESPACE}" "${TEST_OWNER_TOKEN}" "${TEST_OWNER_TOKEN}"
          exit 0
          ;;
        canary-positive:4)
          printf 'Error from server (NotFound): namespaces "%s" not found\n' "${FAKE_CANARY_NAMESPACE}" >&2
          exit 1
          ;;
        canary-apply-foreign:3)
          printf '{"kind":"Namespace","metadata":{"name":"%s","uid":"22222222-2222-4222-8222-222222222222","labels":{"p010-student-owner":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"},"annotations":{"p010-student-owner-token":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}}}\n' "${FAKE_CANARY_NAMESPACE}"
          exit 0
          ;;
      esac
      printf 'unexpected namespace lookup\n' >&2
      exit 2
      ;;
    create:-f:*)
      printf '{"kind":"Namespace","metadata":{"name":"%s","uid":"11111111-1111-4111-8111-111111111111","labels":{"p010-student-owner":"%s"},"annotations":{"p010-student-owner-token":"%s"}}}\n' "${FAKE_CANARY_NAMESPACE}" "${TEST_OWNER_TOKEN}" "${TEST_OWNER_TOKEN}"
      exit 0
      ;;
    apply:-f:*)
      if [[ "${FAKE_KUBECTL_SCENARIO}" == canary-apply-foreign ]]; then
        printf 'simulated apply error after namespace identity changed\n' >&2
        exit 1
      fi
      exit 0
      ;;
    rollout:status:deployment/http-canary) exit 0 ;;
    wait:--for=condition=complete:job/relay-dns-and-http) exit 0 ;;
    logs:job/relay-dns-and-http:*) printf 'hubble-relay.kube-system.svc.cluster.local\nstudent-canary-ok\n'; exit 0 ;;
    delete:namespace:*) printf 'namespace %s deleted\n' "${object_name}"; exit 0 ;;
  esac
fi

printf 'unexpected fake kubectl command: %s\n' "${args[*]}" >&2
exit 2
SH
chmod 0700 "${tmp_dir}/bin/kubectl"

cat >"${tmp_dir}/save-state.yml" <<'YAML'
- hosts: localhost
  gather_facts: false
  connection: local
  vars:
    ansible_become: false
    student_docker_bin: "{{ lookup('env', 'TEST_SCRATCH') }}/bin/docker"
    student_repo_root: "{{ lookup('env', 'TEST_SCRATCH') }}"
    student_state_file: "{{ lookup('env', 'TEST_SCRATCH') }}/state.json"
    student_owner_token_file: "{{ lookup('env', 'TEST_SCRATCH') }}/owner-token"
    student_uid: "{{ lookup('env', 'TEST_UID') | int }}"
    student_has_state: true
    student_save_status: partial
    student_save_phase: fake-test
    student_state:
      owner_token: "{{ lookup('env', 'TEST_OWNER_TOKEN') }}"
      status: preparing
      kind_node_ids: {}
      fabric_node_ids: {}
      network_ids: {}
      kubeconfig_sha256: ''
      api_server: ''
      cluster_uid: ''
      chart_sha256: ''
      values_sha256: ''
      topology_sha256: ''
      topology_file: ''
      helm_revision: 0
    student_profile:
      kind_name: p010-student
      kind_nodes: "{{ ['p010-student-control-plane'] if lookup('env', 'FAKE_DOCKER_SCENARIO') in ['foreign-kind', 'owned-kind'] else [] }}"
      fabric_nodes: "{{ ['clab-test-fabric-node'] if lookup('env', 'FAKE_DOCKER_SCENARIO') == 'owned-fabric' else [] }}"
      topology_network: "{{ 'student-net' if lookup('env', 'FAKE_DOCKER_SCENARIO') in ['owned-network', 'foreign-network'] else none }}"
      topology_subnet: 10.1.0.0/24
      topology_source: null
      chart: fixture-chart.tgz
  tasks:
    - block:
        - ansible.builtin.include_tasks: "{{ lookup('env', 'STUDENT_LAB_ROOT') }}/poc-k8s-fabric/automation/student-lab/tasks/save-state.yml"
      rescue:
        - ansible.builtin.set_fact:
            student_save_rejected: true
    - name: Require a proven ID only for resources carrying this run's ownership proof
      ansible.builtin.assert:
        that:
          - (lookup('env', 'FAKE_DOCKER_SCENARIO') != 'foreign-kind') or (student_save_rejected | default(false) and student_kind_node_ids | length == 0)
          - (lookup('env', 'FAKE_DOCKER_SCENARIO') != 'owned-kind') or student_kind_node_ids['p010-student-control-plane'] == lookup('env', 'TEST_NODE_ID')
          - (lookup('env', 'FAKE_DOCKER_SCENARIO') != 'owned-fabric') or student_fabric_node_ids['clab-test-fabric-node'] == lookup('env', 'TEST_NODE_ID')
          - (lookup('env', 'FAKE_DOCKER_SCENARIO') != 'foreign-network') or (student_save_rejected | default(false) and student_network_ids | length == 0)
          - (lookup('env', 'FAKE_DOCKER_SCENARIO') != 'owned-network') or student_network_ids['student-net'] == lookup('env', 'TEST_NETWORK_ID')
YAML

cat >"${tmp_dir}/owner-token.yml" <<'YAML'
- hosts: localhost
  gather_facts: false
  connection: local
  vars:
    ansible_become: false
    student_owner_token_file: "{{ lookup('env', 'TEST_OWNER_TOKEN_FILE') }}"
    student_uid: "{{ lookup('env', 'TEST_UID') | int }}"
    student_state:
      owner_token: "{{ lookup('env', 'TEST_STATE_OWNER_TOKEN') }}"
  tasks:
    - block:
        - ansible.builtin.include_tasks: "{{ lookup('env', 'STUDENT_LAB_ROOT') }}/poc-k8s-fabric/automation/student-lab/tasks/validate-owner-token.yml"
      rescue:
        - ansible.builtin.set_fact:
            owner_token_rejected: true
    - ansible.builtin.assert:
        that:
          - (lookup('env', 'FAKE_TOKEN_SCENARIO') == 'valid') == (not (owner_token_rejected | default(false)))
YAML

cat >"${tmp_dir}/collision.yml" <<'YAML'
- hosts: localhost
  gather_facts: false
  connection: local
  vars:
    ansible_become: false
    student_docker_bin: "{{ lookup('env', 'TEST_SCRATCH') }}/bin/docker"
    student_tool_dir: "{{ lookup('env', 'TEST_SCRATCH') }}/missing-tools"
    student_profile:
      kind_name: p010-student
      kind_nodes: [p010-student-control-plane]
      fabric_nodes: []
      topology_source: null
      topology_network: "{{ 'p010-net' if lookup('env', 'FAKE_DOCKER_SCENARIO') in ['collision-network-absent', 'collision-network-wrong-stdout'] else none }}"
      topology_subnet: 10.223.33.0/24
  tasks:
    - block:
        - ansible.builtin.include_tasks: "{{ lookup('env', 'STUDENT_LAB_ROOT') }}/poc-k8s-fabric/automation/student-lab/tasks/check-collisions.yml"
      rescue:
        - ansible.builtin.set_fact:
            collision_rejected: true
    - ansible.builtin.assert:
        that:
          - (lookup('env', 'FAKE_EXPECT_REJECTION') == 'true') == (collision_rejected | default(false))
          - student_kind_label_collision.rc == lookup('env', 'FAKE_EXPECT_LABEL_RC') | int
          - student_kind_label_collision.stdout_lines | length == lookup('env', 'FAKE_EXPECT_LABEL_LINES') | int
          - lookup('env', 'FAKE_EXPECT_REJECTION') == 'true' or (student_kind_collision_results.results | default([]) | length == 1 and student_kind_collision_results.results[0].rc == 1 and student_kind_collision_results.results[0].stdout == '[]')
          - lookup('env', 'FAKE_DOCKER_SCENARIO') != 'collision-network-absent' or (student_network_collision.rc == 1 and student_network_collision.stdout == '[]')
YAML

cat >"${tmp_dir}/owner-labels.yml" <<'YAML'
- hosts: localhost
  gather_facts: false
  connection: local
  vars:
    ansible_become: false
    student_tool_dir: "{{ lookup('env', 'TEST_SCRATCH') }}/bin"
    student_action: "{{ lookup('env', 'FAKE_KUBECTL_ACTION') }}"
    student_state:
      kubeconfig: fake-kubeconfig
      context: kind-p010-student
      owner_token: "{{ lookup('env', 'TEST_OWNER_TOKEN') }}"
    student_profile:
      kind_nodes: [p010-student-control-plane]
  tasks:
    - block:
        - ansible.builtin.include_tasks: "{{ lookup('env', 'STUDENT_LAB_ROOT') }}/poc-k8s-fabric/automation/student-lab/tasks/validate-kube-owner.yml"
      rescue:
        - ansible.builtin.set_fact:
            owner_guard_rejected: true
    - ansible.builtin.assert:
        that:
          - (lookup('env', 'FAKE_KUBECTL_SCENARIO') != 'owner-drift') or (owner_guard_rejected | default(false) and student_live_owner_nodes.rc == 0 and student_live_owner_nodes.stdout_lines | length == 0)
          - (lookup('env', 'FAKE_KUBECTL_SCENARIO') != 'owner-owned') or student_live_owner_nodes.stdout_lines == ['p010-student-control-plane']
          - (lookup('env', 'FAKE_KUBECTL_SCENARIO') != 'owner-unavailable') or (student_kube_owner_api_unavailable and student_live_owner_nodes.rc != 0)
YAML

cat >"${tmp_dir}/canary.yml" <<'YAML'
- hosts: localhost
  gather_facts: false
  connection: local
  vars:
    ansible_become: false
    student_tool_dir: "{{ lookup('env', 'TEST_SCRATCH') }}/bin"
    student_repo_root: "{{ lookup('env', 'STUDENT_LAB_ROOT') }}"
    student_run_dir: "{{ lookup('env', 'TEST_SCRATCH') }}/runtime"
    student_uid: "{{ lookup('env', 'TEST_UID') | int }}"
    student_state:
      kubeconfig: fake-kubeconfig
      context: kind-p010-student
      run_id: 20261029-11111111111111111111111111111111
      owner_token: "{{ lookup('env', 'TEST_OWNER_TOKEN') }}"
  tasks:
    - block:
        - ansible.builtin.include_tasks: "{{ lookup('env', 'STUDENT_LAB_ROOT') }}/poc-k8s-fabric/automation/student-lab/tasks/verify-beginner.yml"
      rescue:
        - ansible.builtin.set_fact:
            canary_guard_rejected: true
    - name: Require canary failure to leave any foreign namespace untouched
      ansible.builtin.assert:
        that:
          - (lookup('env', 'FAKE_KUBECTL_SCENARIO') != 'canary-foreign') or canary_guard_rejected | default(false)
          - (lookup('env', 'FAKE_KUBECTL_SCENARIO') != 'canary-apply-foreign') or canary_guard_rejected | default(false)
          - (lookup('env', 'FAKE_KUBECTL_SCENARIO') != 'canary-positive') or not (canary_guard_rejected | default(false))
YAML

export ANSIBLE_CONFIG="${script_dir}/ansible.cfg"

run_playbook() {
  local playbook="$1"
  local log_file="$2"
  "${ansible_playbook_bin}" -i 'localhost,' --connection local "${playbook}" >"${log_file}" 2>&1
}

run_collision_case() {
  local scenario="$1" expected_rejection="$2" label_rc="${3:-0}" label_lines="${4:-0}"
  export FAKE_DOCKER_SCENARIO="${scenario}"
  export FAKE_EXPECT_REJECTION="${expected_rejection}"
  export FAKE_EXPECT_LABEL_RC="${label_rc}"
  export FAKE_EXPECT_LABEL_LINES="${label_lines}"
  : >"${FAKE_DOCKER_LOG}"
  run_playbook "${tmp_dir}/collision.yml" "${tmp_dir}/${scenario}.log" \
    || { cat "${tmp_dir}/${scenario}.log" >&2; fail "collision fake ${scenario} não respeitou o resultado esperado."; }
}

for scenario in valid empty-file empty-state; do
  export FAKE_TOKEN_SCENARIO="${scenario}"
  export TEST_OWNER_TOKEN_FILE="${tmp_dir}/owner-token"
  export TEST_STATE_OWNER_TOKEN="${TEST_OWNER_TOKEN}"
  case "${scenario}" in
    empty-file) export TEST_OWNER_TOKEN_FILE="${tmp_dir}/owner-token-empty" ;;
    empty-state) export TEST_STATE_OWNER_TOKEN='' ;;
  esac
  run_playbook "${tmp_dir}/owner-token.yml" "${tmp_dir}/owner-token-${scenario}.log" \
    || { cat "${tmp_dir}/owner-token-${scenario}.log" >&2; fail "owner token guard falhou no cenário ${scenario}."; }
done

run_collision_case precreate true 0 1
[[ "$(wc -l <"${FAKE_DOCKER_LOG}")" -eq 1 ]] \
  || fail 'check-collisions prosseguiu depois de detectar nome Kind ocupado.'

for scenario in collision-upper-absent collision-lower-absent; do
  run_collision_case "${scenario}" false
done
run_collision_case collision-network-absent false
run_collision_case collision-network-wrong-stdout true
for scenario in collision-present collision-permission collision-daemon-unavailable \
  collision-generic collision-wrong-name collision-wrong-stdout collision-multiline collision-wrong-rc; do
  run_collision_case "${scenario}" true
done
run_collision_case collision-list-error true 1 0

for scenario in foreign-kind foreign-network; do
  export FAKE_DOCKER_SCENARIO="${scenario}"
  if ! run_playbook "${tmp_dir}/save-state.yml" "${tmp_dir}/${scenario}.log"; then
    cat "${tmp_dir}/${scenario}.log" >&2
    fail "rescue fake ${scenario} não demonstrou rejeição sem adoção."
  fi
done

for scenario in owned-kind owned-fabric owned-network; do
  export FAKE_DOCKER_SCENARIO="${scenario}"
  run_playbook "${tmp_dir}/save-state.yml" "${tmp_dir}/${scenario}.log" \
    || { cat "${tmp_dir}/${scenario}.log" >&2; fail "salvamento de ID próprio falhou para ${scenario}."; }
done

export FAKE_KUBECTL_SCENARIO=owner-drift
export FAKE_KUBECTL_ACTION=down
run_playbook "${tmp_dir}/owner-labels.yml" "${tmp_dir}/owner-drift.log" \
  || { cat "${tmp_dir}/owner-drift.log" >&2; fail 'down aceitou conjunto vazio de labels com rc 0.'; }
export FAKE_KUBECTL_SCENARIO=owner-unavailable
run_playbook "${tmp_dir}/owner-labels.yml" "${tmp_dir}/owner-unavailable.log" \
  || { cat "${tmp_dir}/owner-unavailable.log" >&2; fail 'API indisponível não foi distinguida de drift em down.'; }
export FAKE_KUBECTL_SCENARIO=owner-owned
run_playbook "${tmp_dir}/owner-labels.yml" "${tmp_dir}/owner-owned.log" \
  || { cat "${tmp_dir}/owner-owned.log" >&2; fail 'token correto não passou no guard de owner labels.'; }

for scenario in canary-foreign canary-apply-foreign canary-positive; do
  export FAKE_KUBECTL_SCENARIO="${scenario}"
  export FAKE_CANARY_NAMESPACE="student-verify-11111111111111111111111111111111"
  rm -f -- "${FAKE_CANARY_COUNTER}"
  : >"${FAKE_KUBECTL_LOG}"
  run_playbook "${tmp_dir}/canary.yml" "${tmp_dir}/${scenario}.log" \
    || { cat "${tmp_dir}/${scenario}.log" >&2; fail "canary fake ${scenario} não completou."; }
  if [[ "${scenario}" == canary-positive ]]; then
    grep -Fq 'jsonpath={.spec.template.spec.containers[0].ports[?(@.name == "grpc")].containerPort}' "${FAKE_KUBECTL_LOG}" \
      || fail 'JSONPath do port grpc perdeu o filtro válido ou recebeu barras de escape.'
    grep -Fq 'student-canary-ok' "${STUDENT_LAB_ROOT}/poc-k8s-fabric/automation/student-lab/templates/beginner-canary.yml.j2" \
      || fail 'manifest canário não emite o marcador depois de validar HTTP.'
    grep -Fq "test \"\$body\" = student-canary-ok" "${STUDENT_LAB_ROOT}/poc-k8s-fabric/automation/student-lab/templates/beginner-canary.yml.j2" \
      || fail 'canário não valida a resposta HTTP antes de emitir o marcador.'
    grep -Fq 'delete' "${FAKE_KUBECTL_LOG}" \
      || fail 'canário próprio não foi removido após o sucesso.'
  else
    if grep -Fq 'delete' "${FAKE_KUBECTL_LOG}"; then
      fail "${scenario} tentou remover namespace sem identidade própria."
    fi
  fi
done

printf 'test-security-guards: PASS (tokens, colisões Docker exatas, IDs Kind/fabric/rede, drift/API, canário, JSONPath/marcador)\n'
