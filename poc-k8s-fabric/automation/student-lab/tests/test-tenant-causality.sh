#!/usr/bin/env bash
set -euo pipefail

student_lab_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
repo_root="$(cd -- "${student_lab_dir}/../../.." && pwd -P)"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-ansible-playbook}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT

fail() {
  printf 'test-tenant-causality: %s\n' "$1" >&2
  exit 1
}

command -v "${ansible_playbook_bin}" >/dev/null 2>&1 \
  || fail 'ansible-playbook ausente; informe ANSIBLE_PLAYBOOK_BIN.'

mkdir -p "${tmp_dir}/bin" "${tmp_dir}/async"
cat >"${tmp_dir}/bin/kubectl" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
printf '%q ' "${args[@]}" >>"${FAKE_KUBECTL_LOG}"
printf '\n' >>"${FAKE_KUBECTL_LOG}"

has_arg() {
  local expected="$1" arg
  for arg in "${args[@]}"; do
    [[ "${arg}" == "${expected}" ]] && return 0
  done
  return 1
}

arg_after() {
  local expected="$1" index
  for ((index = 0; index < ${#args[@]} - 1; index++)); do
    if [[ "${args[index]}" == "${expected}" ]]; then
      printf '%s' "${args[index + 1]}"
      return 0
    fi
  done
  return 1
}

arg_after_offset() {
  local expected="$1" offset="$2" index
  for ((index = 0; index < ${#args[@]} - offset; index++)); do
    if [[ "${args[index]}" == "${expected}" ]]; then
      printf '%s' "${args[index + offset]}"
      return 0
    fi
  done
  return 1
}

if has_arg serviceaccount; then
  printf 'serviceaccount/%s\n' "$(arg_after serviceaccount)"
elif has_arg rollout; then
  :
elif has_arg ciliumnetworkpolicy; then
  case "$(arg_after --namespace)" in
    p003-tenant-a) printf 'ciliumnetworkpolicy/p003-a-client-policy\nciliumnetworkpolicy/p003-a-backend-policy\n' ;;
    p003-tenant-b) printf 'ciliumnetworkpolicy/p003-b-client-policy\nciliumnetworkpolicy/p003-b-backend-policy\n' ;;
    *) exit 91 ;;
  esac
elif has_arg get && has_arg pods && has_arg --selector; then
  case "$(arg_after --selector)" in
    app=p003-a-client) printf 'p003-a-client-abc123-def45\t10.10.0.11\tp003-gw-worker\tRunning\tp003-tenant-a-app\n' ;;
    app=p003-a-backend) printf 'p003-a-backend-abc123-def45\t10.10.0.21\tp003-gw-worker2\tRunning\tp003-tenant-a-app\n' ;;
    app=p003-b-client) printf 'p003-b-client-abc123-def45\t10.20.0.12\tp003-gw-worker2\tRunning\tp003-tenant-b-app\n' ;;
    app=p003-b-backend) printf 'p003-b-backend-abc123-def45\t10.20.0.22\tp003-gw-worker2\tRunning\tp003-tenant-b-app\n' ;;
    k8s-app=cilium)
      case "$(arg_after --field-selector)" in
        spec.nodeName=p003-gw-worker) printf 'cilium-agent-worker' ;;
        spec.nodeName=p003-gw-worker2) printf 'cilium-agent-worker2' ;;
        *) exit 92 ;;
      esac
      ;;
    *) exit 93 ;;
  esac
elif has_arg cilium-dbg && has_arg monitor; then
  agent=''
  for arg in "${args[@]}"; do
    [[ "${arg}" == cilium-agent-* ]] && agent="${arg}"
  done
  case "${FAKE_TENANT_CASE}" in
    policy)
      monitor_event_prefix='xx drop (Policy denied) flow 0x0000000000001234 to endpoint 321, ifindex 4, file bpf_lxc.c:88, identity 1234: '
      case "${agent}" in
        cilium-agent-worker)
          printf '%s10.10.0.11:33445 -> 10.20.0.22:8080 tcp SYN\n' "${monitor_event_prefix}" ;;
        cilium-agent-worker2)
          printf '%s10.20.0.12:33445 -> 10.10.0.21:8080 tcp SYN\n' "${monitor_event_prefix}" ;;
      esac
      ;;
    source-suffix)
      monitor_event_prefix='xx drop (Policy denied) flow 0x0000000000001234 to endpoint 321, ifindex 4, file bpf_lxc.c:88, identity 1234: '
      case "${agent}" in
        cilium-agent-worker)
          printf '%s110.10.0.11:33445 -> 10.20.0.22:8080 tcp SYN\n' "${monitor_event_prefix}" ;;
        cilium-agent-worker2)
          printf '%s110.20.0.12:33445 -> 10.10.0.21:8080 tcp SYN\n' "${monitor_event_prefix}" ;;
      esac
      ;;
    wrong-flow)
      case "${agent}" in
        cilium-agent-worker)
          printf 'xx drop (Policy denied) flow 10.10.0.11:33445 -> 10.20.0.21:8080 tcp SYN\n' ;;
        cilium-agent-worker2)
          printf 'xx drop (Policy denied) flow 10.20.0.12:33445 -> 10.10.0.22:8080 tcp SYN\n' ;;
      esac
      ;;
    split-flow)
      case "${agent}" in
        cilium-agent-worker)
          printf 'xx drop (Policy denied) flow 10.10.0.11:33445 -> 10.99.0.99:8080 tcp SYN\n'
          printf 'xx drop (Policy denied) flow 10.99.0.98:33445 -> 10.20.0.22:8080 tcp SYN\n' ;;
        cilium-agent-worker2)
          printf 'xx drop (Policy denied) flow 10.20.0.12:33445 -> 10.99.0.99:8080 tcp SYN\n'
          printf 'xx drop (Policy denied) flow 10.99.0.98:33445 -> 10.10.0.21:8080 tcp SYN\n' ;;
      esac
      ;;
    wrong-port)
      case "${agent}" in
        cilium-agent-worker)
          printf 'xx drop (Policy denied) flow 10.10.0.11:33445 -> 10.20.0.22:9090 tcp SYN\n' ;;
        cilium-agent-worker2)
          printf 'xx drop (Policy denied) flow 10.20.0.12:33445 -> 10.10.0.21:9090 tcp SYN\n' ;;
      esac
      ;;
    wrong-protocol)
      case "${agent}" in
        cilium-agent-worker)
          printf 'xx drop (Policy denied) flow 10.10.0.11:33445 -> 10.20.0.22:8080 udp\n' ;;
        cilium-agent-worker2)
          printf 'xx drop (Policy denied) flow 10.20.0.12:33445 -> 10.10.0.21:8080 udp\n' ;;
      esac
      ;;
    dns|route|refused) : ;;
  esac
  exit 124
elif has_arg curl; then
  target=''
  for arg in "${args[@]}"; do
    [[ "${arg}" == http://* ]] && target="${arg}" && break
  done
  source="$(arg_after_offset --namespace 2)"
  if [[ "${source}" == p003-a-client-abc123-def45 && "${target}" == http://10.10.0.21:8080/hostname \
    || "${source}" == p003-b-client-abc123-def45 && "${target}" == http://10.20.0.22:8080/hostname ]]; then
    printf '200'
    exit 0
  fi
  case "${FAKE_TENANT_CASE}" in
    dns) printf '000'; printf 'Could not resolve host\n' >&2; exit 6 ;;
    route) printf '000'; printf 'Connection timed out\n' >&2; exit 28 ;;
    refused) printf '000'; printf 'Connection refused\n' >&2; exit 7 ;;
    policy|source-suffix|wrong-flow|split-flow|wrong-port|wrong-protocol) printf '000'; printf 'Connection timed out\n' >&2; exit 28 ;;
    *) exit 94 ;;
  esac
else
  printf 'unexpected kubectl invocation: %s\n' "${args[*]}" >&2
  exit 95
fi
SH
chmod 0700 "${tmp_dir}/bin/kubectl"

cat >"${tmp_dir}/bin/timeout" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == --signal=INT && "$2" == 15s ]] || exit 96
shift 2
exec "$@"
SH
chmod 0700 "${tmp_dir}/bin/timeout"

cat >"${tmp_dir}/probe.yml" <<YAML
---
- hosts: localhost
  gather_facts: false
  connection: local
  vars:
    ansible_become: false
    student_tool_dir: "{{ lookup('env', 'TEST_BIN_DIR') }}"
    student_timeout_bin: "{{ lookup('env', 'TEST_TIMEOUT_BIN') }}"
    student_state:
      kubeconfig: FAKE-ONLY
    student_profile:
      context: kind-p003-gw
      kind_nodes: [p003-gw-control-plane, p003-gw-worker, p003-gw-worker2]
  tasks:
    - ansible.builtin.include_tasks: ${student_lab_dir}/tasks/verify-tenants.yml
YAML

export ANSIBLE_CONFIG="${student_lab_dir}/ansible.cfg"
export ANSIBLE_ASYNC_DIR="${tmp_dir}/async"
export TEST_BIN_DIR="${tmp_dir}/bin"
export TEST_TIMEOUT_BIN="${tmp_dir}/bin/timeout"

run_case() {
  local scenario="$1" expected="$2"
  export FAKE_TENANT_CASE="${scenario}"
  export FAKE_KUBECTL_LOG="${tmp_dir}/${scenario}.calls"
  : >"${FAKE_KUBECTL_LOG}"
  if "${ansible_playbook_bin}" --inventory 'localhost,' --connection local \
    "${tmp_dir}/probe.yml" >"${tmp_dir}/${scenario}.log" 2>&1; then
    actual=success
  else
    actual=failure
  fi
  [[ "${actual}" == "${expected}" ]] \
    || { cat "${tmp_dir}/${scenario}.log" >&2; fail "${scenario}: esperado ${expected}, obtido ${actual}."; }
}

run_case policy success
grep -Fq 'http://10.10.0.21:8080/hostname' "${FAKE_KUBECTL_LOG}" \
  || fail 'probe positiva não usou IP direto do backend A.'
grep -Fq 'http://10.20.0.22:8080/hostname' "${FAKE_KUBECTL_LOG}" \
  || fail 'probe positiva não usou IP direto do backend B.'
printf 'case: same-tenant HTTP 200 e duas negações com evento policy/IP correlacionado PASS\n'

for scenario in dns route refused source-suffix wrong-flow split-flow wrong-port wrong-protocol; do
  run_case "${scenario}" failure
  grep -Fq 'one Cilium Policy denied TCP event for the same flow to port 8080' "${tmp_dir}/${scenario}.log" \
    || { cat "${tmp_dir}/${scenario}.log" >&2; fail "${scenario} não falhou na asserção causal esperada."; }
  printf 'case: %s sem evidência causal correlacionada é rejeitado PASS\n' "${scenario}"
done

printf 'test-tenant-causality: PASS (9 casos; DNS/rota/recusa, IP de origem por sufixo, split-flow, porta/protocolo incorretos e fluxo divergente rejeitados)\n'
