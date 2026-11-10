#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT

fail() {
  printf 'test-scenarios: %s\n' "$1" >&2
  exit 1
}

mkdir -p "${tmp_dir}/bin" "${tmp_dir}/home"
cp "${script_dir}/lab" "${tmp_dir}/lab"
cp "${script_dir}/sudo-auth.sh" "${tmp_dir}/sudo-auth.sh"
cat >"${tmp_dir}/preflight.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${SCENARIO_ARGS_FILE}"
SH
cat >"${tmp_dir}/bin/id" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -u) printf '4242\n' ;;
  -un) printf 'student\n' ;;
  *) exit 2 ;;
esac
SH
cat >"${tmp_dir}/bin/getent" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == passwd ]] || exit 2
printf 'student:x:4242:4242::%s:/bin/bash\n' "${HOME}"
SH
chmod 0755 "${tmp_dir}/lab" "${tmp_dir}/preflight.sh" "${tmp_dir}/bin/id" "${tmp_dir}/bin/getent"

run_preflight() {
  local expected_exercise="$1" expected_wg="$2"
  : >"${tmp_dir}/args"
  HOME="${tmp_dir}/home" PATH="${tmp_dir}/bin:/usr/bin:/bin" \
    SCENARIO_ARGS_FILE="${tmp_dir}/args" LAB=plataforma EXERCISE="${expected_exercise}" \
    WG="${expected_wg}" "${tmp_dir}/lab" preflight >/dev/null
  args=()
  while IFS= read -r line; do
    args+=("${line}")
  done <"${tmp_dir}/args"
  [[ "${args[0]:-}" == plataforma ]] || fail 'perfil não chegou ao preflight.'
  [[ "${args[2]:-}" == "${expected_exercise}" ]] || fail 'EXERCISE não chegou ao preflight.'
  [[ "${args[3]:-}" == "${expected_wg}" ]] || fail 'WG não chegou ao preflight.'
}

run_preflight auth ''
run_preflight wireguard-native W1
run_preflight wireguard-vxlan W2
run_preflight ipam24 ''
run_preflight ipam32 ''

: >"${tmp_dir}/args"
env -u WG HOME="${tmp_dir}/home" PATH="${tmp_dir}/bin:/usr/bin:/bin" \
  SCENARIO_ARGS_FILE="${tmp_dir}/args" LAB=plataforma EXERCISE=wireguard-native \
  "${tmp_dir}/lab" preflight >/dev/null
args=()
while IFS= read -r line; do
  args+=("${line}")
done <"${tmp_dir}/args"
[[ "${args[3]:-}" == W1 ]] || fail 'WG omitido não assumiu W1.'

: >"${tmp_dir}/args"
if HOME="${tmp_dir}/home" PATH="${tmp_dir}/bin:/usr/bin:/bin" \
  SCENARIO_ARGS_FILE="${tmp_dir}/args" LAB=plataforma EXERCISE=auth WG=W0 \
  "${tmp_dir}/lab" preflight >"${tmp_dir}/bad-wg.out" 2>&1; then
  fail 'WG passou para um exercício que não usa WireGuard.'
fi
grep -Fq 'WG só se aplica aos cenários WireGuard' "${tmp_dir}/bad-wg.out" \
  || fail 'WG incompatível não retornou a mensagem esperada.'
[[ ! -s "${tmp_dir}/args" ]] || fail 'preflight foi chamado antes de validar WG.'

if LAB=plataforma EXERCISE=wireguard-native WG=W3 "${script_dir}/lab" preflight \
  >"${tmp_dir}/invalid-mode.out" 2>&1; then
  fail 'modo WG desconhecido foi aceito.'
fi
grep -Fq 'WG inválido' "${tmp_dir}/invalid-mode.out" \
  || fail 'modo WG inválido não retornou erro explícito.'

if "${script_dir}/preflight.sh" plataforma "${tmp_dir}/state.json" wireguard-native W3 \
  >"${tmp_dir}/preflight-invalid-mode.out" 2>&1; then
  fail 'preflight aceitou modo WG desconhecido.'
fi
grep -Fq 'WG inválido' "${tmp_dir}/preflight-invalid-mode.out" \
  || fail 'preflight não validou WG antes do gate de host.'

printf 'test-scenarios: PASS (allowlist, default WG, forwarding e rejeições antes do preflight)\n'
