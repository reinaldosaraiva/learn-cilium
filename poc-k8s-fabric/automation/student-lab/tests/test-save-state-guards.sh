#!/usr/bin/env bash
set -euo pipefail

student_lab_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
repo_root="$(cd -- "${student_lab_dir}/../../.." && pwd -P)"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-ansible-playbook}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT
owner_token='11111111-2222-4333-8444-555555555555'

fail() {
  printf 'test-save-state-guards: %s\n' "$1" >&2
  exit 1
}

command -v "${ansible_playbook_bin}" >/dev/null 2>&1 \
  || fail 'ansible-playbook ausente; informe ANSIBLE_PLAYBOOK_BIN.'

mkdir -p "${tmp_dir}/bin"
printf '%s\n' "${owner_token}" >"${tmp_dir}/owner-token"
chmod 0400 "${tmp_dir}/owner-token"

cat >"${tmp_dir}/bin/docker" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
printf '%q ' "${args[@]}" >>"${FAKE_DOCKER_LOG}"
printf '\n' >>"${FAKE_DOCKER_LOG}"
last="${args[${#args[@]} - 1]}"
if [[ " ${args[*]} " == *' network inspect '* ]]; then
  case "${FAKE_SAVE_CASE}" in
    exact-errors)
      printf '[]\n'
      printf 'Error response from daemon: network p010-student-net not found\n' >&2
      exit 1
      ;;
    exact-errors-empty-network)
      printf 'Error response from daemon: network p010-student-net not found\n' >&2
      exit 1
      ;;
    network-generic)
      printf '[]\n'
      printf 'Cannot connect to the Docker daemon\n' >&2
      exit 1
      ;;
    network-wrong-name)
      printf '[]\n'
      printf 'Error response from daemon: network other-net not found\n' >&2
      exit 1
      ;;
    network-wrong-rc)
      printf '[]\n'
      printf 'Error response from daemon: network p010-student-net not found\n' >&2
      exit 2
      ;;
    network-noisy)
      printf 'diagnostic output\n'
      printf 'Error response from daemon: network p010-student-net not found\n' >&2
      exit 1
      ;;
    *) exit 96 ;;
  esac
fi
case "${FAKE_SAVE_CASE}:${last}" in
  exact-errors:p010-student-control-plane)
    printf '[]\n'
    printf 'Error: No such object: p010-student-control-plane\n' >&2
    exit 1
    ;;
  exact-errors:clab-p010-border1)
    printf 'error: no such object: clab-p010-border1\n' >&2
    exit 1
    ;;
  exact-errors-empty-network:p010-student-control-plane|exact-errors-empty-network:clab-p010-border1|network-*:*p010-student-control-plane|network-*:*clab-p010-border1)
    printf '[]\n'
    printf 'error: no such object: %s\n' "${last}" >&2
    exit 1
    ;;
  fabric-generic:p010-student-control-plane)
    printf '[]\n'
    printf 'Error: No such object: p010-student-control-plane\n' >&2
    exit 1
    ;;
  kind-generic:p010-student-control-plane)
    printf '[]\n'
    printf 'Cannot connect to the Docker daemon\n' >&2
    exit 1
    ;;
  kind-wrong-name:p010-student-control-plane)
    printf '[]\n'
    printf 'Error: No such object: p010-student-other\n' >&2
    exit 1
    ;;
  kind-wrong-rc:p010-student-control-plane)
    printf '[]\n'
    printf 'Error: No such object: p010-student-control-plane\n' >&2
    exit 2
    ;;
  kind-noisy:p010-student-control-plane)
    printf 'diagnostic output\n'
    printf 'Error: No such object: p010-student-control-plane\n' >&2
    exit 1
    ;;
  fabric-generic:clab-p010-border1)
    printf '[]\n'
    printf 'permission denied while connecting to Docker\n' >&2
    exit 1
    ;;
  network-generic:*)
    printf 'error: no such object: %s\n' "${last}" >&2
    exit 1
    ;;
  *)
    printf 'unexpected docker invocation: %s\n' "${args[*]}" >&2
    exit 97
    ;;
esac
SH
chmod 0700 "${tmp_dir}/bin/docker"

cat >"${tmp_dir}/save-state.yml" <<YAML
---
- hosts: localhost
  gather_facts: false
  connection: local
  vars:
    ansible_become: false
    ansible_date_time:
      iso8601: '2026-10-29T20:00:00Z'
    student_repo_root: ${repo_root}
    student_docker_bin: "{{ lookup('env', 'TEST_DOCKER_BIN') }}"
    student_owner_token_file: "{{ lookup('env', 'TEST_OWNER_TOKEN_FILE') }}"
    student_state_file: "{{ lookup('env', 'TEST_STATE_FILE') }}"
    student_uid: $(id -u)
    student_run_dir: "{{ lookup('env', 'TEST_RUN_DIR') }}"
    student_state: "{{ lookup('env', 'TEST_STATE') | from_json }}"
    student_has_state: true
    student_save_status: partial
    student_save_phase: failed
    student_profile:
      name: plataforma
      kind_name: p010-student
      context: kind-p010-student
      kind_nodes: [p010-student-control-plane]
      fabric_nodes: [clab-p010-border1]
      topology_network: p010-student-net
      topology_subnet: 10.223.40.0/24
      topology_source: null
      chart: poc-k8s-fabric/studies/p003/base/cilium-1.20.2.tgz
    ansible_failed_task:
      no_log: "{{ lookup('env', 'TEST_TASK_NO_LOG') | bool }}"
      name: Synthetic startup failure
    ansible_failed_result:
      _ansible_no_log: "{{ lookup('env', 'TEST_RESULT_NO_LOG') | bool }}"
      stderr: "{{ lookup('env', 'TEST_ORIGINAL_SENTINEL') if lookup('env', 'TEST_ORIGINAL_STYLE') == 'stderr' else '' }}"
      msg: "{{ lookup('env', 'TEST_ORIGINAL_SENTINEL') if lookup('env', 'TEST_ORIGINAL_STYLE') == 'msg' else 'safe fallback' }}"
  tasks:
    - name: Exercise rescue with an injected prior result for focused redaction coverage
      ansible.builtin.include_tasks: ${student_lab_dir}/tasks/rescue-up.yml
      when: lookup('env', 'TEST_INJECT_FAILURE_CONTEXT') | bool
    - block:
        - name: Simulate an original startup failure in stderr
          ansible.builtin.command:
            argv: [/bin/sh, -c, 'printf "%s" "\$TEST_ORIGINAL_SENTINEL" >&2; exit 7']
          failed_when: true
          no_log: "{{ lookup('env', 'TEST_ORIGINAL_NO_LOG') | bool }}"
          when: lookup('env', 'TEST_ORIGINAL_STYLE') == 'stderr'
        - name: Simulate an original startup failure whose detail is only a module message
          ansible.builtin.command:
            argv: ["{{ lookup('env', 'TEST_ORIGINAL_SENTINEL') }}"]
          no_log: "{{ lookup('env', 'TEST_ORIGINAL_NO_LOG') | bool }}"
          when: lookup('env', 'TEST_ORIGINAL_STYLE') == 'msg'
      rescue:
        - ansible.builtin.include_tasks: ${student_lab_dir}/tasks/rescue-up.yml
      when: not (lookup('env', 'TEST_INJECT_FAILURE_CONTEXT') | bool)
YAML

export ANSIBLE_CONFIG="${student_lab_dir}/ansible.cfg"
export TEST_DOCKER_BIN="${tmp_dir}/bin/docker"
export TEST_OWNER_TOKEN_FILE="${tmp_dir}/owner-token"
export TEST_RUN_DIR="${tmp_dir}"
export TEST_ORIGINAL_STYLE=stderr
export TEST_ORIGINAL_NO_LOG=false
export TEST_ORIGINAL_SENTINEL='original bootstrap failure'
export TEST_INJECT_FAILURE_CONTEXT=false
export TEST_TASK_NO_LOG=false
export TEST_RESULT_NO_LOG=false

initial_state() {
  printf '{"profile":"plataforma","status":"preparing","phase":"kind-created","owner_token":"%s","kind_node_ids":{},"fabric_node_ids":{},"network_ids":{},"cluster_uid":"","api_server":"","kubeconfig_sha256":"","chart_sha256":"","values_sha256":"","topology_sha256":"","helm_revision":0}\n' "${owner_token}"
}

run_save_case() {
  local scenario="$1" expected="$2"
  export FAKE_SAVE_CASE="${scenario}"
  export TEST_STATE_FILE="${tmp_dir}/${scenario}.json"
  export FAKE_DOCKER_LOG="${tmp_dir}/${scenario}.docker.calls"
  initial_state >"${TEST_STATE_FILE}"
  export TEST_STATE="$(cat "${TEST_STATE_FILE}")"
  : >"${FAKE_DOCKER_LOG}"
  if "${ansible_playbook_bin}" --inventory 'localhost,' --connection local \
    "${tmp_dir}/save-state.yml" >"${tmp_dir}/${scenario}.log" 2>&1; then
    actual=success
  else
    actual=failure
  fi
  [[ "${actual}" == "${expected}" ]] \
    || { cat "${tmp_dir}/${scenario}.log" >&2; fail "${scenario}: esperado ${expected}, obtido ${actual}."; }
  grep -Fq 'original bootstrap failure' "${tmp_dir}/${scenario}.log" \
    || { cat "${tmp_dir}/${scenario}.log" >&2; fail "${scenario} ocultou a falha original."; }
}

run_privacy_case() {
  local style="$1" capture="$2" private="$3" sentinel="REVIEW12_PRIVATE_${1}_${2}_SENTINEL_6a91"
  export FAKE_SAVE_CASE=exact-errors
  export TEST_STATE_FILE="${tmp_dir}/privacy-${style}-${capture}.json"
  export TEST_RUN_DIR="${tmp_dir}/privacy-${style}-${capture}"
  export FAKE_DOCKER_LOG="${tmp_dir}/privacy-${style}-${capture}.docker.calls"
  export TEST_STATE="$(initial_state)"
  export TEST_ORIGINAL_STYLE="${style}"
  export TEST_ORIGINAL_NO_LOG="${private}"
  export TEST_ORIGINAL_SENTINEL="${sentinel}"
  export TEST_INJECT_FAILURE_CONTEXT=true
  if [[ "${style}" == stderr && "${private}" == true ]]; then
    export TEST_TASK_NO_LOG=true TEST_RESULT_NO_LOG=false
  elif [[ "${style}" == msg && "${private}" == true ]]; then
    export TEST_TASK_NO_LOG=false TEST_RESULT_NO_LOG=true
  else
    export TEST_TASK_NO_LOG=false TEST_RESULT_NO_LOG=false
  fi
  mkdir -p "${TEST_RUN_DIR}"
  initial_state >"${TEST_STATE_FILE}"
  : >"${FAKE_DOCKER_LOG}"
  if [[ "${capture}" == failure ]]; then
    export TEST_OWNER_TOKEN_FILE="${tmp_dir}/missing-owner-token"
  else
    export TEST_OWNER_TOKEN_FILE="${tmp_dir}/owner-token"
  fi
  if "${ansible_playbook_bin}" --inventory 'localhost,' --connection local \
    "${tmp_dir}/save-state.yml" >"${tmp_dir}/privacy-${style}-${capture}.log" 2>&1; then
    fail "privacy ${style}/${capture} inesperadamente declarou sucesso."
  fi
  if [[ "${private}" == true ]]; then
    if grep -Fq "${sentinel}" "${tmp_dir}/privacy-${style}-${capture}.log"; then
      sed "s/${sentinel}/[REDACTED-SENTINEL]/g" "${tmp_dir}/privacy-${style}-${capture}.log" >&2
      fail "privacy ${style}/${capture} publicou conteúdo protegido."
    fi
    grep -Fq 'falha original protegida por no_log; detalhes suprimidos' \
      "${tmp_dir}/privacy-${style}-${capture}.log" \
      || fail "privacy ${style}/${capture} não redigiu a causa original."
  else
    grep -Fq "${sentinel}" "${tmp_dir}/privacy-${style}-${capture}.log" \
      || fail 'controle público não preservou o detalhe original.'
  fi
  if [[ "${capture}" == failure ]]; then
    grep -Fq 'falha de captura protegida por no_log; detalhes suprimidos' \
      "${tmp_dir}/privacy-${style}-${capture}.log" \
      || fail 'falha de captura protegida não foi distinguida/redigida.'
  else
    grep -Fq '"status": "partial"' "${TEST_STATE_FILE}" \
      || fail "privacy ${style}/${capture} não concluiu a captura parcial positiva."
  fi
  printf 'case: rescue privacy %s/%s (private=%s) PASS\n' "${style}" "${capture}" "${private}"
}

run_actual_private_stderr_case() {
  local capture="$1" sentinel="REVIEW12_ACTUAL_NO_LOG_${1}_SENTINEL_81bc"
  export FAKE_SAVE_CASE=exact-errors
  export TEST_STATE_FILE="${tmp_dir}/actual-private-${capture}.json"
  export TEST_RUN_DIR="${tmp_dir}/actual-private-${capture}"
  export FAKE_DOCKER_LOG="${tmp_dir}/actual-private-${capture}.docker.calls"
  export TEST_STATE="$(initial_state)"
  export TEST_ORIGINAL_STYLE=stderr TEST_ORIGINAL_NO_LOG=true
  export TEST_ORIGINAL_SENTINEL="${sentinel}"
  export TEST_INJECT_FAILURE_CONTEXT=false TEST_TASK_NO_LOG=false TEST_RESULT_NO_LOG=false
  mkdir -p "${TEST_RUN_DIR}"
  initial_state >"${TEST_STATE_FILE}"
  : >"${FAKE_DOCKER_LOG}"
  if [[ "${capture}" == failure ]]; then
    export TEST_OWNER_TOKEN_FILE="${tmp_dir}/missing-owner-token"
  else
    export TEST_OWNER_TOKEN_FILE="${tmp_dir}/owner-token"
  fi
  if "${ansible_playbook_bin}" --inventory 'localhost,' --connection local \
    "${tmp_dir}/save-state.yml" >"${tmp_dir}/actual-private-${capture}.log" 2>&1; then
    fail "actual no_log/${capture} inesperadamente declarou sucesso."
  fi
  if grep -Fq "${sentinel}" "${tmp_dir}/actual-private-${capture}.log"; then
    sed "s/${sentinel}/[REDACTED-SENTINEL]/g" "${tmp_dir}/actual-private-${capture}.log" >&2
    fail "actual no_log/${capture} publicou conteúdo protegido."
  fi
  grep -Fq 'falha original protegida por no_log; detalhes suprimidos' \
    "${tmp_dir}/actual-private-${capture}.log" \
    || fail "actual no_log/${capture} não redigiu a causa original."
  if [[ "${capture}" == failure ]]; then
    grep -Fq 'falha de captura protegida por no_log; detalhes suprimidos' \
      "${tmp_dir}/actual-private-${capture}.log" \
      || fail 'actual no_log/capture failure não distinguiu a captura protegida.'
  else
    grep -Fq '"status": "partial"' "${TEST_STATE_FILE}" \
      || fail 'actual no_log/capture success não salvou o status parcial.'
  fi
  printf 'case: tarefa Ansible real no_log/stderr com captura %s sem vazamento PASS\n' "${capture}"
}

run_save_case exact-errors failure
grep -Fq 'IDs observados foram salvos com status parcial' "${tmp_dir}/exact-errors.log" \
  || { cat "${tmp_dir}/exact-errors.log" >&2; fail 'rescue não salvou e declarou estado partial.'; }
grep -Fq '"status": "partial"' "${TEST_STATE_FILE}" \
  || fail 'state não ficou em status partial.'
grep -Fq '"phase": "failed"' "${TEST_STATE_FILE}" \
  || fail 'state partial não registrou fase failed.'
grep -Fq '"kind_node_ids": {}' "${TEST_STATE_FILE}" \
  || fail 'state registrou ID Kind sem resposta JSON de inspect.'
grep -Fq '"fabric_node_ids": {}' "${TEST_STATE_FILE}" \
  || fail 'state registrou ID fabric sem resposta JSON de inspect.'
grep -Fq '"network_ids": {}' "${TEST_STATE_FILE}" \
  || fail 'state registrou ID de rede sem resposta JSON de inspect.'
grep -Fq '"cluster_uid": ""' "${TEST_STATE_FILE}" \
  || fail 'state fabricou UID de cluster sem resposta da API.'
grep -Fq 'p010-student-control-plane' "${FAKE_DOCKER_LOG}" \
  && grep -Fq 'clab-p010-border1' "${FAKE_DOCKER_LOG}" \
  && grep -Fq 'network' "${FAKE_DOCKER_LOG}" \
  || fail 'teste positivo não exercitou Kind, fabric e rede.'
printf 'case: ausências Docker exatas salvam partial, IDs vazios e UID vazio; causa original preservada PASS\n'

run_save_case exact-errors-empty-network failure
grep -Fq '"status": "partial"' "${TEST_STATE_FILE}" \
  || fail 'stdout vazio e NotFound exato de rede não salvaram o estado parcial.'
printf 'case: stdout vazio + NotFound exato de rede também salva partial PASS\n'

for scenario in kind-generic kind-wrong-name kind-wrong-rc kind-noisy fabric-generic network-generic network-wrong-name network-wrong-rc network-noisy; do
  run_save_case "${scenario}" failure
  grep -Fq 'captura de state parcial também falhou' "${tmp_dir}/${scenario}.log" \
    || { cat "${tmp_dir}/${scenario}.log" >&2; fail "${scenario} não deixou visível a falha ao salvar partial."; }
  grep -Fq '"status":"preparing"' "${TEST_STATE_FILE}" \
    || fail "${scenario} persistiu um state parcial sem prova confiável de ausência."
  printf 'case: %s não é interpretado como ausência; erro de captura permanece visível PASS\n' "${scenario}"
done

run_privacy_case stderr success true
run_privacy_case msg success true
run_privacy_case stderr failure true
run_privacy_case msg failure true
run_privacy_case stderr success false
run_actual_private_stderr_case success
run_actual_private_stderr_case failure
export TEST_INJECT_FAILURE_CONTEXT=false

cat >"${tmp_dir}/identity-network.yml" <<YAML
---
- hosts: localhost
  gather_facts: false
  connection: local
  vars:
    ansible_become: false
    student_docker_bin: "{{ lookup('env', 'TEST_DOCKER_BIN') }}"
    student_has_state: true
    student_action: down
    student_state:
      status: partial
      owner_token: ${owner_token}
      network_ids: {}
    student_profile:
      topology_network: p010-student-net
      topology_subnet: 10.223.40.0/24
  tasks:
    - ansible.builtin.import_tasks: ${student_lab_dir}/tasks/validate-identities.yml
YAML

run_network_case() {
  local scenario="$1" expected="$2"
  export FAKE_SAVE_CASE="${scenario}" FAKE_DOCKER_LOG="${tmp_dir}/identity-${scenario}.docker.calls"
  : >"${FAKE_DOCKER_LOG}"
  if "${ansible_playbook_bin}" --inventory 'localhost,' --connection local --tags student-identity-network \
    "${tmp_dir}/identity-network.yml" >"${tmp_dir}/identity-${scenario}.log" 2>&1; then
    actual=success
  else
    actual=failure
  fi
  [[ "${actual}" == "${expected}" ]] \
    || { cat "${tmp_dir}/identity-${scenario}.log" >&2; fail "identity ${scenario}: esperado ${expected}, obtido ${actual}."; }
}

run_network_case exact-errors success
run_network_case exact-errors-empty-network success
run_network_case network-generic failure
run_network_case network-wrong-name failure
run_network_case network-wrong-rc failure
run_network_case network-noisy failure
printf 'case: validate-identities aceita NotFound exato com stdout vazio/[] e recusa erros inconclusivos PASS\n'

printf 'test-save-state-guards: PASS (11 save-state/rescue, 6 network identity, 5 context tests e 2 tarefas reais no_log)\n'
