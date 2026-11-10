#!/usr/bin/env bash
set -euo pipefail

student_lab_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-ansible-playbook}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT

fail() {
  printf 'test-wireguard-guards: %s\n' "$1" >&2
  exit 1
}

command -v "${ansible_playbook_bin}" >/dev/null 2>&1 \
  || fail 'ansible-playbook ausente; informe ANSIBLE_PLAYBOOK_BIN.'

mkdir -p "${tmp_dir}/bin"
cat >"${tmp_dir}/bin/kubectl" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
printf '%q ' "${args[@]}" >>"${FAKE_KUBECTL_LOG}"
printf '\n' >>"${FAKE_KUBECTL_LOG}"

if [[ " ${args[*]} " == *' get configmap '* ]]; then
  key=''
  for arg in "${args[@]}"; do
    case "${arg}" in
      jsonpath=*)
        key="${arg#jsonpath=}"
        key="${key#\{.data.}"
        key="${key%\}}"
        ;;
    esac
  done
  case "${key}" in
    routing-mode) printf '%s' "${TEST_ROUTING}" ;;
    tunnel-protocol) printf 'vxlan' ;;
    enable-wireguard) [[ "${TEST_WG}" == W0 ]] || printf 'true' ;;
    encrypt-node) [[ "${TEST_WG}" == W2 ]] && printf 'true' || true ;;
    *) exit 81 ;;
  esac
elif [[ " ${args[*]} " == *' get pods '* && " ${args[*]} " == *' k8s-app=cilium '* ]]; then
  printf '%s\n' \
    'p003-gw-control-plane Running' \
    'p003-gw-worker Running' \
    'p003-gw-worker2 Running'
elif [[ " ${args[*]} " == *' get pods '* && " ${args[*]} " == *' app=http-echo '* ]]; then
  if [[ "${FAKE_APP_PLACEMENT}" == wrong ]]; then
    printf 'p003-gw-worker2 Running\n'
  else
    printf 'p003-gw-worker Running\n'
  fi
else
  printf 'unexpected kubectl invocation: %s\n' "${args[*]}" >&2
  exit 82
fi
SH
chmod 0700 "${tmp_dir}/bin/kubectl"

cat >"${tmp_dir}/bin/docker" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
printf '%q ' "${args[@]}" >>"${FAKE_DOCKER_LOG}"
printf '\n' >>"${FAKE_DOCKER_LOG}"
interface=''
for ((index = 0; index < ${#args[@]} - 1; index++)); do
  [[ "${args[index]}" == dev ]] && interface="${args[index + 1]}"
done
case "${interface}" in
  cilium_wg0) result="${FAKE_WG_RESULT}" ;;
  cilium_vxlan) result="${FAKE_VXLAN_RESULT}" ;;
  *) exit 83 ;;
esac
case "${result}" in
  present) printf '9: %s: <UP> mtu 1420\n' "${interface}" ;;
  missing) printf 'Device "%s" does not exist.' "${interface}" >&2; exit 1 ;;
  daemon) printf 'Cannot connect to the Docker daemon\n' >&2; exit 125 ;;
  generic) printf 'ip: operation failed\n' >&2; exit 1 ;;
  noisy-missing) printf 'diagnostic output\n'; printf 'Device "%s" does not exist.' "${interface}" >&2; exit 1 ;;
  *) exit 84 ;;
esac
SH
chmod 0700 "${tmp_dir}/bin/docker"

sed "s|/usr/bin/docker|${tmp_dir}/bin/docker|g" \
  "${student_lab_dir}/tasks/verify-wireguard.yml" >"${tmp_dir}/verify-wireguard.yml"

cat >"${tmp_dir}/probe.yml" <<YAML
---
- hosts: localhost
  gather_facts: false
  connection: local
  vars:
    ansible_become: false
    student_tool_dir: "{{ lookup('env', 'TEST_BIN_DIR') }}"
    student_state:
      kubeconfig: FAKE-ONLY
    student_profile:
      context: kind-p003-gw
      kind_nodes: [p003-gw-control-plane, p003-gw-worker, p003-gw-worker2]
    student_exercise_config:
      routing_mode: "{{ lookup('env', 'TEST_ROUTING') }}"
      tunnel_protocol: vxlan
    student_effective_wireguard_mode: "{{ lookup('env', 'TEST_WG') }}"
  tasks:
    - ansible.builtin.include_tasks: ${tmp_dir}/verify-wireguard.yml
YAML

export ANSIBLE_CONFIG="${student_lab_dir}/ansible.cfg"
export TEST_BIN_DIR="${tmp_dir}/bin"

run_case() {
  local name="$1" expected="$2" routing="$3" wg="$4" wg_result="$5" vxlan_result="$6" app="$7"
  export TEST_ROUTING="${routing}" TEST_WG="${wg}"
  export FAKE_WG_RESULT="${wg_result}" FAKE_VXLAN_RESULT="${vxlan_result}" FAKE_APP_PLACEMENT="${app}"
  export FAKE_KUBECTL_LOG="${tmp_dir}/${name}.kubectl.calls" FAKE_DOCKER_LOG="${tmp_dir}/${name}.docker.calls"
  : >"${FAKE_KUBECTL_LOG}"
  : >"${FAKE_DOCKER_LOG}"
  if "${ansible_playbook_bin}" --inventory 'localhost,' --connection local \
    "${tmp_dir}/probe.yml" >"${tmp_dir}/${name}.log" 2>&1; then
    actual=success
  else
    actual=failure
  fi
  [[ "${actual}" == "${expected}" ]] \
    || { cat "${tmp_dir}/${name}.log" >&2; fail "${name}: esperado ${expected}, obtido ${actual}."; }
  if [[ "${expected}" == failure ]]; then
    case "${name}" in
      *wg*) grep -Fq 'A presença de cilium_wg0 não corresponde' "${tmp_dir}/${name}.log" \
        || fail "${name} não falhou na guarda WireGuard."
        ;;
      *vxlan*) grep -Fq 'A interface cilium_vxlan não corresponde' "${tmp_dir}/${name}.log" \
        || fail "${name} não falhou na guarda VXLAN."
        ;;
      *app*) grep -Fq 'A aplicação HTTP não está fixada' "${tmp_dir}/${name}.log" \
        || fail "${name} não falhou na guarda de placement."
        ;;
    esac
  fi
}

run_case native-w0 success native W0 missing missing correct
run_case native-w1 success native W1 present missing correct
run_case native-w2 success native W2 present missing correct
run_case vxlan-w0 success tunnel W0 missing present correct
run_case vxlan-w1 success tunnel W1 present present correct
run_case vxlan-w2 success tunnel W2 present present correct
printf 'cases: W0/W1/W2 × native/VXLAN conformam presença esperada PASS\n'

run_case wg-daemon failure native W0 daemon missing correct
run_case wg-generic failure native W0 generic missing correct
run_case wg-noisy-absence failure native W0 noisy-missing missing correct
run_case wg-unexpected-present failure native W0 present missing correct
run_case wg-missing-when-enabled failure native W1 missing missing correct
run_case vxlan-daemon failure native W0 missing daemon correct
run_case vxlan-generic failure native W0 missing generic correct
run_case vxlan-missing-in-tunnel failure tunnel W0 missing missing correct
run_case app-wrong-worker failure tunnel W1 present present wrong
printf 'cases: erro daemon, erro genérico, stdout inesperado, presença incorreta e placement são rejeitados PASS\n'
printf 'test-wireguard-guards: PASS (15 casos positivos/negativos; Docker e kubectl fakes locais)\n'
