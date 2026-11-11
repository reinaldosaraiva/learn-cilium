#!/usr/bin/env bash
set -euo pipefail

student_lab_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
repo_root="$(cd -- "${student_lab_dir}/../../.." && pwd -P)"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-ansible-playbook}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT

fail() {
  printf 'test-auth-placement: %s\n' "$1" >&2
  exit 1
}

command -v "${ansible_playbook_bin}" >/dev/null 2>&1 \
  || fail 'ansible-playbook ausente; informe ANSIBLE_PLAYBOOK_BIN.'

mkdir -p "${tmp_dir}/bin" "${tmp_dir}/run-auth" "${tmp_dir}/run-wireguard"
cat >"${tmp_dir}/bin/kubectl" <<'SH'
#!/usr/bin/env bash
set -u
printf '%q ' "$@" >>"${FAKE_KUBECTL_LOG}"
printf '\n' >>"${FAKE_KUBECTL_LOG}"
args=("$@")
case " ${args[*]} " in
  *' apply '*'-f '*auth-deploy.yaml*)
    manifest=''
    for ((index = 0; index < ${#args[@]} - 1; index++)); do
      [[ "${args[index]}" == -f ]] && manifest="${args[index + 1]}"
    done
    cp -- "${manifest}" "${FAKE_AUTH_DEPLOY_CAPTURE}"
    printf 'deployment.apps/p003-authz configured\n'
    ;;
  *' patch deployment/http-echo '*)
    printf '%s\n' "${args[*]}" >"${FAKE_AUTH_PATCH_CAPTURE}"
    printf 'deployment.apps/http-echo patched\n'
    ;;
  *' rollout status '*) : ;;
  *' apply '*'-f '*auth-routes.yaml*) printf 'httproute configured\n' ;;
  *) printf 'unexpected kubectl invocation: %s\n' "${args[*]}" >&2; exit 91 ;;
esac
SH
chmod 0700 "${tmp_dir}/bin/kubectl"

cat >"${tmp_dir}/probe.yml" <<YAML
---
- hosts: localhost
  gather_facts: false
  connection: local
  vars:
    ansible_become: false
    student_repo_root: ${repo_root}
    student_run_dir: "{{ lookup('env', 'TEST_RUN_DIR') }}"
    student_uid: $(id -u)
    student_tool_dir: "{{ lookup('env', 'TEST_BIN_DIR') }}"
    student_effective_exercise: "{{ lookup('env', 'TEST_EXERCISE') }}"
    student_state:
      kubeconfig: FAKE-ONLY
      run_id: 11111111-2222-4333-8444-555555555555
    student_profile:
      context: kind-p003-gw
      kind_name: p003-gw
      kind_nodes: [p003-gw-control-plane, p003-gw-worker, p003-gw-worker2]
  tasks:
    - ansible.builtin.import_tasks: ${student_lab_dir}/tasks/apply-auth.yml
YAML

export ANSIBLE_CONFIG="${student_lab_dir}/ansible.cfg"
export TEST_BIN_DIR="${tmp_dir}/bin"
export TEST_RUN_DIR="${tmp_dir}/run-auth"
export FAKE_KUBECTL_LOG="${tmp_dir}/kubectl.calls"
export FAKE_AUTH_DEPLOY_CAPTURE="${tmp_dir}/auth-deploy-applied.yaml"
export FAKE_AUTH_PATCH_CAPTURE="${tmp_dir}/auth-app-patch.txt"
auth_fixture="${repo_root}/poc-k8s-fabric/studies/p003/fixtures/auth/auth-deploy.yaml"
auth_fixture_before="$(shasum -a 256 "${auth_fixture}" | awk '{print $1}')"

run_case() {
  local exercise="$1" run_dir="$2"
  export TEST_EXERCISE="${exercise}" TEST_RUN_DIR="${run_dir}"
  export FAKE_AUTH_DEPLOY_CAPTURE="${tmp_dir}/${exercise}-deploy.yaml"
  export FAKE_AUTH_PATCH_CAPTURE="${tmp_dir}/${exercise}-patch.txt"
  : >"${FAKE_KUBECTL_LOG}"
  "${ansible_playbook_bin}" --inventory 'localhost,' --connection local \
    --start-at-task 'Copy the reviewed Auth Deployment and Service into private run state' \
    "${tmp_dir}/probe.yml" >"${tmp_dir}/${exercise}.log" 2>&1 \
    || { cat "${tmp_dir}/${exercise}.log" >&2; fail "falha ao aplicar fixture privada para ${exercise}."; }
  grep -Fq 'image: p010-student-authz:11111111-2222-4333-8444-555555555555' \
    "${FAKE_AUTH_DEPLOY_CAPTURE}" \
    || fail "${exercise} não vinculou a imagem ao run privado."
}

run_case auth "${tmp_dir}/run-auth"
grep -Fq 'kubernetes.io/hostname: p003-gw-worker' "${FAKE_AUTH_DEPLOY_CAPTURE}" \
  || fail 'Auth comum deixou de usar o worker conhecido de ingresso.'
if grep -Fq 'deployment/http-echo' "${FAKE_KUBECTL_LOG}"; then
  fail 'Auth comum alterou o placement da aplicação HTTP.'
fi
printf 'case: Auth comum permanece no worker conhecido de ingresso PASS\n'

run_case wireguard-native "${tmp_dir}/run-wireguard"
grep -Fq 'kubernetes.io/hostname: p003-gw-worker2' "${FAKE_AUTH_DEPLOY_CAPTURE}" \
  || fail 'Auth WireGuard não foi afastado do worker de ingresso.'
grep -Fq 'deployment/http-echo' "${FAKE_KUBECTL_LOG}" \
  || fail 'WireGuard não fixou a aplicação no worker de ingresso.'
grep -Fq '"kubernetes.io/hostname":"p003-gw-worker"' "${FAKE_AUTH_PATCH_CAPTURE}" \
  || fail 'patch WireGuard não selecionou o worker de ingresso conhecido.'
printf 'case: Auth WireGuard remoto e aplicação no worker de ingresso PASS\n'

auth_fixture_after="$(shasum -a 256 "${auth_fixture}" | awk '{print $1}')"
[[ "${auth_fixture_before}" == "${auth_fixture_after}" ]] \
  || fail 'fixture versionada foi modificada pelo teste.'
printf 'test-auth-placement: PASS (2 fluxos; fixture fonte preservada)\n'
