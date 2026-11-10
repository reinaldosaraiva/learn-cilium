#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
student_lab="$(cd -- "${script_dir}/.." && pwd -P)"
repo_root="$(cd -- "${student_lab}/../../.." && pwd -P)"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-$(command -v ansible-playbook || true)}"
python_bin="${ANSIBLE_PYTHON_BIN:-$(dirname -- "${ansible_playbook_bin}")/python}"
scratch="${P010_HYBRID_API_TEST_SCRATCH:-$(mktemp -d /tmp/p010-hybrid-api-test.XXXXXX)}"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'LOG_DIR=%s\n' "${scratch}" >&2
  exit 1
}

[[ -x "${ansible_playbook_bin}" ]] || fail 'ansible-playbook ausente; passe ANSIBLE_PLAYBOOK_BIN.'
[[ -x "${python_bin}" ]] || fail 'Python do Ansible ausente; passe ANSIBLE_PYTHON_BIN.'
mkdir -m 0700 -p "${scratch}/ansible-local"
export ANSIBLE_CONFIG="${student_lab}/ansible.cfg"
export ANSIBLE_LOCAL_TEMP="${scratch}/ansible-local"
export ANSIBLE_NOCOLOR=1
export P010_HYBRID_API_TEST_SCRATCH="${scratch}"
export P010_HYBRID_TEST_REPO_ROOT="${repo_root}"
export P010_HYBRID_TEST_DIR="${scratch}/durable-reconcile"
export P010_HYBRID_TEST_UID="$(id -u)"
mkdir -m 0700 -p "${P010_HYBRID_TEST_DIR}"
mkdir -m 0700 -p "${scratch}/hybrid-fake-bin"
cat >"${scratch}/hybrid-fake-bin/cat" <<'UUID_BIN'
#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
counter="${script_dir}/uuid-counter"
current=0
if [[ -f "${counter}" ]]; then
  IFS= read -r current <"${counter}"
fi
current=$((current % 2 + 1))
printf '%s\n' "${current}" >"${counter}"
case "${current}" in
  1) printf 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\n' ;;
  2) printf 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb\n' ;;
esac
UUID_BIN
chmod 0700 "${scratch}/hybrid-fake-bin/cat"
export P010_HYBRID_TEST_UUID_BIN="${scratch}/hybrid-fake-bin/cat"

fake_neutron_port_file="${scratch}/fake-neutron.port"
fake_neutron_calls_file="${scratch}/fake-neutron.calls"
fake_neutron_status_file="${scratch}/fake-neutron.status"
export P010_FAKE_NEUTRON_EXPECTED_PATH='/networks/11111111-2222-4333-8444-555555555555'
export P010_FAKE_NEUTRON_PORT_FILE="${fake_neutron_port_file}"
export P010_FAKE_NEUTRON_CALLS_FILE="${fake_neutron_calls_file}"
export P010_FAKE_NEUTRON_STATUS_FILE="${fake_neutron_status_file}"
printf '200\n' >"${fake_neutron_status_file}"
"${python_bin}" -I "${student_lab}/tests/fake-neutron-delete-server.py" >"${scratch}/fake-neutron-server.log" 2>&1 &
fake_neutron_server_pid=$!
cleanup_fake_neutron_server() {
  kill "${fake_neutron_server_pid}" 2>/dev/null || true
  wait "${fake_neutron_server_pid}" 2>/dev/null || true
}
trap cleanup_fake_neutron_server EXIT
for _ in {1..50}; do
  [[ -s "${fake_neutron_port_file}" ]] && break
  sleep 0.1
done
[[ -s "${fake_neutron_port_file}" ]] || fail 'fake Neutron local não inicializou.'
export P010_FAKE_NEUTRON_PORT="$(<"${fake_neutron_port_file}")"
cat >"${scratch}/reconcile-delete.inventory" <<'INVENTORY'
localhost ansible_connection=local
student_hybrid_ubuntu ansible_connection=local
INVENTORY
if ! "${ansible_playbook_bin}" -i "${scratch}/reconcile-delete.inventory" "${student_lab}/tests/hybrid-m11-api-reconcile-delete.yml" >"${scratch}/api-reconcile-delete.log" 2>&1; then
  fail 'DELETE incerto HTTP 200 não limpou o pending usando o snapshot persistido.'
fi
[[ "$(<"${fake_neutron_calls_file}")" == "GET /networks/11111111-2222-4333-8444-555555555555" ]] || fail 'reconciliação HTTP 200 não consultou somente o ID gravado.'

: >"${fake_neutron_calls_file}"
if ! "${ansible_playbook_bin}" -i "${scratch}/reconcile-delete.inventory" "${student_lab}/tests/hybrid-m11-api-delete-map.yml" >"${scratch}/api-delete-map.log" 2>&1; then
  fail 'DELETE confirmado não limpou exatamente o ID do mapa dinâmico.'
fi
[[ "$(<"${fake_neutron_calls_file}")" == $'GET /networks/11111111-2222-4333-8444-555555555555\nDELETE /networks/11111111-2222-4333-8444-555555555555\nGET /networks/11111111-2222-4333-8444-555555555555' ]] || fail 'DELETE normal não seguiu GET → DELETE único → GET de confirmação.'

printf '404\n' >"${fake_neutron_status_file}"
: >"${fake_neutron_calls_file}"
if ! "${ansible_playbook_bin}" -i "${scratch}/reconcile-delete.inventory" "${student_lab}/tests/hybrid-m11-api-reconcile-delete-absent.yml" >"${scratch}/api-reconcile-delete-absent.log" 2>&1; then
  fail 'DELETE incerto HTTP 404 não limpou somente o ID correto no mapa persistido.'
fi
[[ "$(<"${fake_neutron_calls_file}")" == 'GET /networks/11111111-2222-4333-8444-555555555555' ]] || fail 'reconciliação HTTP 404 consultou uma identidade diferente da persistida.'

printf '503\n' >"${fake_neutron_status_file}"
: >"${fake_neutron_calls_file}"
reconcile_query_error_rc=0
P010_HYBRID_API_QUERY_ERROR=1 "${ansible_playbook_bin}" -i "${scratch}/reconcile-delete.inventory" "${student_lab}/tests/hybrid-m11-api-reconcile-delete-absent.yml" >"${scratch}/api-reconcile-delete-query-error.log" 2>&1 || reconcile_query_error_rc=$?
[[ "${reconcile_query_error_rc}" != 0 ]] || fail 'erro HTTP da consulta DELETE foi tratado como ausência.'
[[ "$(<"${fake_neutron_calls_file}")" == 'GET /networks/11111111-2222-4333-8444-555555555555' ]] || fail 'reconciliação HTTP 503 consultou uma identidade diferente da persistida.'
"${python_bin}" -I - "${P010_HYBRID_TEST_DIR}/state.json" <<'PY'
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
api = state["hybrid"]["m11"]["api"]
assert api["pending"]["method"] == "DELETE"
assert api["pending"]["resource"] == "tenant_network:primary"
assert api["resources"]["tenant_network"]["primary"]["id"] == "11111111-2222-4333-8444-555555555555"
assert api["resources"]["bgp_speaker"]["primary"]["id"] == "22222222-3333-4444-8555-666666666666"
assert set(api["resources"]) == {
    "address_scope", "external_subnetpool", "tenant_subnetpool",
    "external_network", "tenant_network", "external_subnet", "tenant_subnet",
    "router", "router_interface", "router_gateway_port", "security_group",
    "cirros_port", "bgp_speaker", "bgp_peer", "drinstance", "security_group_rules",
}
assert not any("{{" in key or "}}" in key for key in api["resources"])
PY

if ! bash -n "${BASH_SOURCE[0]}"; then
  fail 'sintaxe Bash inválida.'
fi
if ! "${ansible_playbook_bin}" --syntax-check -i localhost, "${student_lab}/tests/hybrid-syntax.yml" >"${scratch}/hybrid-syntax.log" 2>&1; then
  fail 'syntax-check dos helpers M11 falhou.'
fi
if ! "${ansible_playbook_bin}" --syntax-check -i localhost, --extra-vars "{\"student_repo_root\":\"${repo_root}\"}" "${student_lab}/hybrid-m11-api-playbook.yml" >"${scratch}/api-syntax.log" 2>&1; then
  fail 'syntax-check do playbook API falhou.'
fi
if ! "${ansible_playbook_bin}" -i localhost, "${student_lab}/tests/hybrid-m11-api-catalog.yml" >"${scratch}/api-catalog.log" 2>&1; then
  fail 'validação positiva/negativa de catálogo falhou.'
fi
if ! "${ansible_playbook_bin}" -i localhost, "${student_lab}/tests/hybrid-m11-api-verify-rules.yml" >"${scratch}/api-verify-rules.log" 2>&1; then
  fail 'validação positiva/negativa do inventário de regras falhou.'
fi
if ! "${ansible_playbook_bin}" -i localhost, "${student_lab}/tests/hybrid-m11-api-state.yml" >"${scratch}/api-state.log" 2>&1; then
  fail 'tokens, checkpoints, identidade de agentes ou POST incerto falharam.'
fi
if ! "${ansible_playbook_bin}" -i localhost, "${student_lab}/tests/hybrid-m11-api-scheduler.yml" >"${scratch}/api-scheduler.log" 2>&1; then
  fail 'relação NDR por agent/speaker ID ou rejeição de envelope inválido falhou.'
fi
if ! "${ansible_playbook_bin}" -i localhost, --extra-vars "{\"student_repo_root\":\"${repo_root}\"}" "${student_lab}/tests/hybrid-m11-frr-rebind.yml" >"${scratch}/frr-rebind.log" 2>&1; then
  fail 'rebind FRR privado não preservou a referência única nem os filtros finais.'
fi
if ! "${python_bin}" "${student_lab}/tests/test-hybrid-api-placement.py" >"${scratch}/api-placement.log" 2>&1; then
  fail 'controle de posicionamento das chamadas API falhou.'
fi
if ! PYTHONDONTWRITEBYTECODE=1 "${python_bin}" -I "${student_lab}/tests/test-hybrid-api-runtime-contracts.py" >"${scratch}/api-runtime-contracts.log" 2>&1; then
  fail 'reconciliação DELETE por coleção ou pin SSH efetivo falhou.'
fi
if ! PYTHONDONTWRITEBYTECODE=1 "${python_bin}" -I "${student_lab}/tests/test-hybrid-ovs-attach.py" >"${scratch}/ovs-attach-detach.log" 2>&1; then
  fail 'attach/detach OVS não preservou identidade de bridge, port e interface.'
fi

cp "${student_lab}/tests/fake-sudo.sh" "${scratch}/fake-sudo"
chmod 0700 "${scratch}/fake-sudo"
mkdir -m 0700 -p "${scratch}/k8s-bin"
printf '%s\n' '33333333-3333-4333-8333-333333333333' >"${scratch}/fake-kubectl-uid"
printf '0\n' >"${scratch}/fake-kubectl-deletes"
export P010_HYBRID_TEST_BECOME_EXE="${scratch}/fake-sudo"
export P010_HYBRID_FAKE_KUBECTL_OBJECT="${scratch}/fake-kubectl-object"
export P010_HYBRID_FAKE_KUBECTL_UID_FILE="${scratch}/fake-kubectl-uid"
export P010_HYBRID_FAKE_KUBECTL_DELETES="${scratch}/fake-kubectl-deletes"
if ! "${ansible_playbook_bin}" -i localhost, "${student_lab}/tests/hybrid-m11-k8s-lifecycle.yml" >"${scratch}/k8s-lifecycle.log" 2>&1; then
  fail 'Kubernetes create/delete UID checkpoints, replacement refusal, or absent-delete resume failed.'
fi
mkdir -m 0700 -p "${scratch}/k8s-scope-bin" "${scratch}/k8s-scope-run/m11-k8s"
: >"${scratch}/k8s-scope-calls"
: >"${scratch}/k8s-scope-deletes"
printf '0\n' >"${scratch}/k8s-scope-deletes"
printf '\n' >"${scratch}/k8s-scope-object.json"
printf '\n' >"${scratch}/k8s-scope-expected-path"
export P010_HYBRID_FAKE_KUBECTL_OBJECT_JSON="${scratch}/k8s-scope-object.json"
export P010_HYBRID_FAKE_KUBECTL_EXPECTED_PATH_FILE="${scratch}/k8s-scope-expected-path"
export P010_HYBRID_FAKE_KUBECTL_DELETES="${scratch}/k8s-scope-deletes"
export P010_HYBRID_FAKE_KUBECTL_CALLS="${scratch}/k8s-scope-calls"
if ! "${ansible_playbook_bin}" -i localhost, "${student_lab}/tests/hybrid-m11-delete-k8s-scopes.yml" >"${scratch}/k8s-delete-scopes.log" 2>&1; then
  fail 'Kubernetes namespace, Deployment e Cilium CRD não usaram escopo/versionamento correto no raw UID DELETE.'
fi
if ! "${ansible_playbook_bin}" -i localhost, "${student_lab}/tests/hybrid-down-finalize-maps.yml" >"${scratch}/down-finalize-maps.log" 2>&1; then
  fail 'mapas de identidade do cleanup sobreviveram à substituição ou falharam após reload.'
fi
if ! "${ansible_playbook_bin}" -i localhost, "${student_lab}/tests/hybrid-m11-state-map-cleanup.yml" >"${scratch}/capture-map-cleanup.log" 2>&1; then
  fail 'capture cleanup failed to replace and durably reload both exact state maps.'
fi
if ! "${script_dir}/test-hybrid-m11-positive-fixes.sh" >"${scratch}/positive-fixes.log" 2>&1; then
  fail 'ownership Kubernetes, XID DHCP ou parsing de marcadores M11 falhou.'
fi
if ! "${script_dir}/test-hybrid-m11-stop-captures.sh" >"${scratch}/stop-captures.log" 2>&1; then
  fail 'cleanup das capturas tratou consulta /proc como ausência ou sinalizou PID divergente.'
fi
if ! "${script_dir}/test-hybrid-m11-dora-producer.sh" >"${scratch}/dora-producer.log" 2>&1; then
  fail 'producer DHCP não extraiu o XID real da captura nem rejeitou transações misturadas.'
fi
if ! "${script_dir}/test-hybrid-m11-reverify.sh" >"${scratch}/reverify.log" 2>&1; then
  fail 'rechecagem existente não consultou identidades salvas ou abriu caminho com gate incompleto.'
fi
if ! P010_M20_TEST_SCRATCH="${scratch}/positive-composition" PYTHONDONTWRITEBYTECODE=1 "${python_bin}" -I "${script_dir}/test-hybrid-m11-positive-composition.py" >"${scratch}/positive-composition.log" 2>&1; then
  fail 'composição positiva, chamadas up/verify, negativos causais ou cleanup híbrido falhou.'
fi

printf 'PASS: contratos API/SSH, lifecycle Kubernetes/OVS, captura DHCP e composição positiva com revalidação e cleanup híbridos.\n'
printf 'LOG_DIR=%s\n' "${scratch}"
