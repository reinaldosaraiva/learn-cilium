#!/usr/bin/env bash
set -euo pipefail

student_lab_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
repo_root="$(cd -- "${student_lab_dir}/../../.." && pwd -P)"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-ansible-playbook}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT
run_id='20261029-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
owner_token='11111111-2222-4333-8444-555555555555'
test_uid="$(id -u)"
state_dir="${tmp_dir}/state"
fixtures_dir="${tmp_dir}/fixtures"

fail() {
  printf 'test-down-idempotency: %s\n' "$1" >&2
  exit 1
}

command -v "${ansible_playbook_bin}" >/dev/null 2>&1 \
  || fail 'ansible-playbook ausente; informe ANSIBLE_PLAYBOOK_BIN.'
command -v python3 >/dev/null 2>&1 || fail 'python3 ausente para comparar fixtures JSON.'

mkdir -m 0700 -p "${state_dir}/runs/${run_id}" "${tmp_dir}/bin" "${fixtures_dir}"
chmod 0700 "${state_dir}" "${state_dir}/runs" "${state_dir}/runs/${run_id}" "${fixtures_dir}"
cat >"${tmp_dir}/bin/docker" <<'SH'
#!/usr/bin/env bash
set -u
printf '%q ' "$@" >>"${FAKE_DOCKER_LOG}"
printf '\n' >>"${FAKE_DOCKER_LOG}"
printf 'unexpected Docker call during state=down: %s\n' "$*" >&2
exit 99
SH
chmod 0700 "${tmp_dir}/bin/docker"

export ANSIBLE_CONFIG="${student_lab_dir}/ansible.cfg"
export P010_LAB_ACTION=down
export P010_LAB_REPO_ROOT="${repo_root}"
export P010_LAB_STATE_DIR="${state_dir}"
export P010_LAB_TOOL_DIR="${tmp_dir}/bin"
export P010_LAB_UID="${test_uid}"
export P010_LAB_NEW_RUN_ID="${run_id}"
export P010_LAB_NEW_OWNER_TOKEN="${owner_token}"
export P010_LAB_EXERCISE=''
export P010_LAB_WG=''
export P010_LAB_NEW_SESSION_ID=''
export P010_LAB_GUEST=''
export P010_LAB_SHELL_CONSOLE_ID=''
export P010_LAB_SHELL_PHASE=''
export P010_HYBRID_API_TEST_SCRATCH="${fixtures_dir}"
export FAKE_DOCKER_LOG="${tmp_dir}/docker.calls"

run_fixture() {
  local profile="$1"
  local finalizer_tasks="${2:-}"
  export P010_LAB_PROFILE="${profile}"
  export P010_DOWN_FINALIZER_TASKS="${finalizer_tasks}"
  "${ansible_playbook_bin}" --inventory 'localhost,' --connection local \
    "${student_lab_dir}/tests/hybrid-down-finalize-maps.yml" \
    >"${tmp_dir}/fixture-${profile}.log" 2>&1 \
    || { cat "${tmp_dir}/fixture-${profile}.log" >&2; fail "finalizer real falhou para ${profile}."; }
}

run_site() {
  local log_file="$1"
  local site_file="${2:-${student_lab_dir}/site.yml}"
  local source_root="${3:-${repo_root}}"
  export P010_LAB_REPO_ROOT="${source_root}"
  "${ansible_playbook_bin}" --inventory 'localhost,' --connection local \
    --extra-vars "student_docker_bin=${tmp_dir}/bin/docker" "${site_file}" \
    >"${log_file}" 2>&1
}

require_no_docker_calls() {
  [[ ! -s "${FAKE_DOCKER_LOG}" ]] \
    || { cat "${FAKE_DOCKER_LOG}" >&2; fail 'down de estado concluído chamou Docker.'; }
}

check_generated_state() {
  local profile="$1"
  local state_file="${state_dir}/state.json"
  local fixture="${fixtures_dir}/generated-${profile}.json"
  python3 - "${fixture}" "${state_file}" "${profile}" <<'PY'
import json
import os
import stat
import sys

expected_path, actual_path, profile = sys.argv[1:]
with open(expected_path, encoding="utf-8") as stream:
    expected = json.load(stream)
with open(actual_path, encoding="utf-8") as stream:
    actual = json.load(stream)
if actual != expected:
    raise SystemExit(f"estado persistido divergiu do finalizer: {profile}")
if profile != "hibrido" and ("hybrid" in actual or len(actual) != 29):
    raise SystemExit(f"estado schema2 não é canônico: {profile}")
if stat.S_IMODE(os.stat(actual_path).st_mode) != 0o600:
    raise SystemExit("estado persistido perdeu modo 0600")
PY
}

for profile in iniciantes fundamentos plataforma; do
  run_fixture "${profile}"
  cp "${fixtures_dir}/generated-${profile}.json" "${state_dir}/state.json"
  chmod 0600 "${state_dir}/state.json"
  export P010_LAB_PROFILE="${profile}"
  for invocation in 1 2; do
    : >"${FAKE_DOCKER_LOG}"
    run_site "${tmp_dir}/${profile}-down-${invocation}.log" \
      || { cat "${tmp_dir}/${profile}-down-${invocation}.log" >&2; fail "down ${profile} #${invocation} falhou."; }
    grep -Fq 'Nenhum laboratório ativo registrado; nenhum recurso foi removido.' \
      "${tmp_dir}/${profile}-down-${invocation}.log" \
      || fail "down ${profile} #${invocation} não seguiu o ramo de estado down."
    require_no_docker_calls
    check_generated_state "${profile}"
  done
  printf 'finalizer real → site.yml down/down (%s): schema canônico, campos preservados, zero Docker PASS\n' "${profile}"
done

run_fixture hibrido
printf 'finalizer real → JSON privado → reload (hibrido): schema3 e registros guest/M11 preservados, fases removed PASS\n'

run_fixture iniciantes
cp "${fixtures_dir}/generated-iniciantes.json" "${fixtures_dir}/canonical-iniciantes.json"

frozen_root="${P010_FROZEN_35B_PRODUCT_ROOT:-}"
if [[ -n "${frozen_root}" ]]; then
  frozen_finalizer="${frozen_root}/poc-k8s-fabric/automation/student-lab/tasks/down-finalize-state.yml"
  frozen_site="${frozen_root}/poc-k8s-fabric/automation/student-lab/site.yml"
  [[ -f "${frozen_finalizer}" && -f "${frozen_site}" ]] \
    || fail 'raiz frozen35b informada sem finalizer/site imutáveis.'
  run_fixture iniciantes "${frozen_finalizer}"
  cp "${fixtures_dir}/generated-iniciantes.json" "${fixtures_dir}/legacy-hybrid-empty.json"
  python3 - "${fixtures_dir}/legacy-hybrid-empty.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    state = json.load(stream)
if state.get("hybrid") != {} or len(state) != 30:
    raise SystemExit("finalizer frozen35b não produziu a chave legacy esperada")
PY
  cp "${fixtures_dir}/legacy-hybrid-empty.json" "${state_dir}/state.json"
  chmod 0600 "${state_dir}/state.json"
  : >"${FAKE_DOCKER_LOG}"
  before="$(shasum -a 256 "${state_dir}/state.json" | awk '{print $1}')"
  if run_site "${tmp_dir}/frozen35b-reject.log" "${frozen_site}" "${frozen_root}"; then
    fail 'entrypoint frozen35b aceitou a chave hybrid extra.'
  fi
  grep -Fq 'Versão ou campos do estado privado não são reconhecidos.' "${tmp_dir}/frozen35b-reject.log" \
    || fail 'entrypoint frozen35b falhou por motivo diferente do exact-key set.'
  after="$(shasum -a 256 "${state_dir}/state.json" | awk '{print $1}')"
  [[ "${before}" == "${after}" ]] || fail 'contrafactual frozen35b alterou o estado rejeitado.'
  require_no_docker_calls
  printf 'contrafactual frozen35b finalizer → entrypoint: chave hybrid extra rejeitada, estado intacto PASS\n'
else
  python3 - "${fixtures_dir}/canonical-iniciantes.json" "${fixtures_dir}/legacy-hybrid-empty.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    state = json.load(stream)
state["hybrid"] = {}
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(state, stream)
    stream.write("\n")
PY
  chmod 0600 "${fixtures_dir}/legacy-hybrid-empty.json"
fi

cp "${fixtures_dir}/legacy-hybrid-empty.json" "${fixtures_dir}/legacy-source.json"
cp "${fixtures_dir}/legacy-source.json" "${state_dir}/state.json"
chmod 0600 "${state_dir}/state.json"
export P010_LAB_PROFILE=iniciantes
: >"${FAKE_DOCKER_LOG}"
run_site "${tmp_dir}/legacy-migration.log" \
  || { cat "${tmp_dir}/legacy-migration.log" >&2; fail 'compatibilidade legada exata não foi aceita pelo down público.'; }
require_no_docker_calls
python3 - "${fixtures_dir}/legacy-source.json" "${state_dir}/state.json" <<'PY'
import json
import os
import stat
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    expected = json.load(stream)
with open(sys.argv[2], encoding="utf-8") as stream:
    actual = json.load(stream)
expected.pop("hybrid")
if actual != expected:
    raise SystemExit("migração removeu ou alterou campo além do hybrid vazio")
if stat.S_IMODE(os.stat(sys.argv[2]).st_mode) != 0o600:
    raise SystemExit("migração não preservou o modo privado 0600")
PY
: >"${FAKE_DOCKER_LOG}"
run_site "${tmp_dir}/legacy-migration-repeat.log" \
  || { cat "${tmp_dir}/legacy-migration-repeat.log" >&2; fail 'down repetido após migração falhou.'; }
require_no_docker_calls
python3 - "${state_dir}/state.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    state = json.load(stream)
if "hybrid" in state or len(state) != 29 or state["status"] != "down":
    raise SystemExit("down repetido não manteve schema2 canônico")
PY
printf 'legacy hybrid:{} → down público canônico + segundo processo: campos/modo preservados, zero Docker PASS\n'

python3 - "${fixtures_dir}/canonical-iniciantes.json" "${fixtures_dir}/schema1.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    state = json.load(stream)
state["schema"] = 1
for key in ("exercise", "wireguard_mode", "exercise_session"):
    state.pop(key)
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(state, stream)
    stream.write("\n")
PY
cp "${fixtures_dir}/schema1.json" "${state_dir}/state.json"
chmod 0600 "${state_dir}/state.json"
: >"${FAKE_DOCKER_LOG}"
run_site "${tmp_dir}/schema1-migration.log" \
  || { cat "${tmp_dir}/schema1-migration.log" >&2; fail 'migração schema1 existente mudou.'; }
require_no_docker_calls
python3 - "${state_dir}/state.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    state = json.load(stream)
if state["schema"] != 2 or len(state) != 29 or "hybrid" in state:
    raise SystemExit("migração schema1 não produziu schema2 canônico")
PY
printf 'schema1 válido → schema2: migração existente preservada PASS\n'

mutate_fixture() {
  local case_name="$1"
  local destination="$2"
  python3 - "${fixtures_dir}/legacy-source.json" "${destination}" "${case_name}" "${test_uid}" <<'PY'
import json
import sys

source, destination, case, uid_text = sys.argv[1:]
uid = int(uid_text)
with open(source, encoding="utf-8") as stream:
    state = json.load(stream)
if case == "hybrid-nonempty":
    state["hybrid"] = {"phase": "partial"}
elif case == "hybrid-null":
    state["hybrid"] = None
elif case == "hybrid-list":
    state["hybrid"] = []
elif case == "hybrid-string":
    state["hybrid"] = ""
elif case == "hybrid-false":
    state["hybrid"] = False
elif case == "extra-key":
    state["unexpected"] = "fixture"
elif case == "missing-key":
    state.pop("api_server")
elif case == "schema-three":
    state["schema"] = 3
elif case == "schema-string":
    state["schema"] = "2"
elif case == "schema-bool":
    state["schema"] = True
elif case == "schema-float":
    state["schema"] = 2.0
elif case == "unknown-profile":
    state["profile"] = "unknown"
elif case == "hybrid-profile":
    state["profile"] = "hibrido"
elif case == "wrong-owner":
    state["owner_uid"] = uid + 1
elif case == "owner-string":
    state["owner_uid"] = str(uid)
elif case in {"status-preparing", "status-partial", "status-up"}:
    state["status"] = case.removeprefix("status-")
elif case == "wrong-phase":
    state["phase"] = "down-start"
elif case == "revision-nonzero":
    state["helm_revision"] = 1
elif case == "revision-string":
    state["helm_revision"] = "0"
elif case.startswith("map-nonempty-"):
    state[case.removeprefix("map-nonempty-") + "_ids"] = {"fixture": "id"}
elif case.startswith("map-malformed-"):
    state[case.removeprefix("map-malformed-") + "_ids"] = []
elif case == "bad-token":
    state["owner_token"] = "invalid"
elif case == "bad-run-id":
    state["run_id"] = "invalid"
elif case == "bad-kubeconfig":
    state["kubeconfig"] = "/tmp/outside-run/kubeconfig"
elif case == "bad-context":
    state["context"] = "other-context"
else:
    raise SystemExit(f"mutação desconhecida: {case}")
with open(destination, "w", encoding="utf-8") as stream:
    json.dump(state, stream)
    stream.write("\n")
PY
  chmod 0600 "${destination}"
}

expect_reject_unchanged() {
  local case_name="$1"
  local case_file="${tmp_dir}/cases/${case_name}.json"
  local log_file="${tmp_dir}/cases/${case_name}.log"
  mkdir -p "${tmp_dir}/cases"
  mutate_fixture "${case_name}" "${case_file}"
  cp "${case_file}" "${state_dir}/state.json"
  chmod 0600 "${state_dir}/state.json"
  local before after
  before="$(shasum -a 256 "${state_dir}/state.json" | awk '{print $1}')"
  : >"${FAKE_DOCKER_LOG}"
  if run_site "${log_file}"; then
    fail "fixture inválida ${case_name} foi aceita."
  fi
  grep -Eq 'Versão ou campos do estado privado não são reconhecidos\.|Estado inválido ou divergente' "${log_file}" \
    || fail "fixture ${case_name} falhou sem erro de validação reconhecido."
  after="$(shasum -a 256 "${state_dir}/state.json" | awk '{print $1}')"
  [[ "${before}" == "${after}" ]] || fail "fixture inválida ${case_name} foi persistida/alterada."
  require_no_docker_calls
}

for case_name in \
  hybrid-nonempty hybrid-null hybrid-list hybrid-string hybrid-false \
  extra-key missing-key schema-three schema-string schema-bool schema-float \
  unknown-profile hybrid-profile wrong-owner owner-string \
  status-preparing status-partial status-up wrong-phase revision-nonzero revision-string \
  map-nonempty-kind_node map-malformed-kind_node \
  map-nonempty-fabric_node map-malformed-fabric_node \
  map-nonempty-network map-malformed-network \
  bad-token bad-run-id bad-kubeconfig bad-context; do
  expect_reject_unchanged "${case_name}"
done
printf 'compatibilidade causal: híbrido/keys/schema/owner/perfil/fase/revision/maps/token/run-id/path/context inválidos rejeitados sem escrita/recurso PASS\n'

printf 'test-down-idempotency: PASS (finalizer real, três perfis, migração estrita, negativos sem efeitos)\n'
