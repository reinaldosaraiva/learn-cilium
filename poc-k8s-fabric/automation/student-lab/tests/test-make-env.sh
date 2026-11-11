#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
repo_root="$(cd -- "${script_dir}/../../.." && pwd -P)"
make_bin="${MAKE_BIN:-make}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT

fail() {
  printf 'test-make-env: %s\n' "$1" >&2
  exit 1
}

command -v "${make_bin}" >/dev/null 2>&1 || fail 'make ausente.'

mkdir -p "${tmp_dir}/poc-k8s-fabric/automation/student-lab"
cp "${repo_root}/Makefile" "${tmp_dir}/Makefile"
cp "${repo_root}/poc-k8s-fabric/Makefile" "${tmp_dir}/poc-k8s-fabric/Makefile"
cat >"${tmp_dir}/poc-k8s-fabric/automation/student-lab/lab" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == env ]] || exit 2
printf "export TEST_LAB_ENV='data-only'\n"
SH
chmod 0700 "${tmp_dir}/poc-k8s-fabric/automation/student-lab/lab"

if ! MAKEFLAGS=w "${make_bin}" -w -C "${tmp_dir}" lab-env \
  >"${tmp_dir}/raw.stdout" 2>"${tmp_dir}/raw.stderr"; then
  cat "${tmp_dir}/raw.stderr" >&2
  fail 'make -w lab-env com wrapper fake falhou.'
fi
grep -Fq 'Entering directory' "${tmp_dir}/raw.stdout" \
  || fail 'a chamada bruta não reproduziu o diagnóstico do make raiz.'
grep -Fq 'Leaving directory' "${tmp_dir}/raw.stdout" \
  || fail 'a chamada bruta não reproduziu o diagnóstico final do make raiz.'
grep -Fq "export TEST_LAB_ENV='data-only'" "${tmp_dir}/raw.stdout" \
  || fail 'a chamada bruta não preservou a saída do wrapper.'
if grep -Fq 'directory `'"${tmp_dir}"'/poc-k8s-fabric' "${tmp_dir}/raw.stdout"; then
  fail 'a recursão imprimiu diagnóstico do submake.'
fi
if bash -c 'eval "$1"' _ "$(cat "${tmp_dir}/raw.stdout")" \
  >"${tmp_dir}/raw-eval.log" 2>&1; then
  fail 'a captura bruta deveria falhar ao avaliar os diagnósticos do make raiz.'
else
  eval_status="$?"
fi
[[ "${eval_status}" != 0 ]] \
  || fail 'eval bruto não reportou a saída como inválida.'
[[ -s "${tmp_dir}/raw-eval.log" ]] \
  || fail 'eval bruto não registrou o diagnóstico causado pelo ruído do make raiz.'

MAKEFLAGS=w
export MAKEFLAGS
lab_env="$("${make_bin}" -w --no-print-directory -C "${tmp_dir}" lab-env)" \
  || fail 'make -w --no-print-directory lab-env falhou.'
unset MAKEFLAGS
[[ "${lab_env}" == "export TEST_LAB_ENV='data-only'" ]] \
  || fail 'stdout protegido contém bytes além das atribuições do ambiente.'
eval "${lab_env}"
[[ "${TEST_LAB_ENV:-}" == data-only ]] \
  || fail 'eval do ambiente capturado não definiu o valor esperado.'

printf 'test-make-env: PASS (make -w bruto causa eval rc=%s; --no-print-directory preserva captura/eval com MAKEFLAGS=w)\n' "${eval_status}"
