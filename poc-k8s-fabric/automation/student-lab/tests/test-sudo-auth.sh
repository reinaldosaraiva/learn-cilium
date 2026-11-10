#!/usr/bin/env bash
set -euo pipefail

student_lab_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT

fail() {
  printf 'test-sudo-auth: %s\n' "$1" >&2
  exit 1
}

mkdir -p "${tmp_dir}/bin"
cat >"${tmp_dir}/bin/sudo" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SUDO_CALLS}"
case "${SUDO_MODE}:${1:-}:${2:-}" in
  allow:-n:true|fallback:-v:) exit 0 ;;
  fallback:-n:true|deny:-n:true|deny:-v:) exit 1 ;;
  *) exit 42 ;;
esac
SH
chmod 0755 "${tmp_dir}/bin/sudo"

for script in lab preflight.sh; do
  rg -Fq 'student_require_sudo_auth' "${student_lab_dir}/${script}" \
    || fail "${script} não usa a verificação sudo comum."
done
rg -Fq 'sudo -n timeout' "${student_lab_dir}/lab" \
  || fail 'bootstrap deixou operações apt com sudo interativo.'
rg -Fq 'sudo -n "${docker_client}"' "${student_lab_dir}/preflight.sh" \
  || fail 'preflight deixou inspeção Docker sem sudo não interativo.'

run_helper() {
  local mode="$1"
  : >"${tmp_dir}/sudo.calls"
  SUDO_MODE="${mode}" SUDO_CALLS="${tmp_dir}/sudo.calls" PATH="${tmp_dir}/bin:/usr/bin:/bin" \
    bash -c 'source "$1"; student_require_sudo_auth' _ "${student_lab_dir}/sudo-auth.sh"
}

run_helper allow || fail 'sudo -n true autorizado foi recusado.'
[[ "$(cat "${tmp_dir}/sudo.calls")" == '-n true' ]] \
  || fail 'o caminho NOPASSWD chamou uma senha ou um comando adicional.'

run_helper fallback || fail 'fallback com sudo -v autorizado foi recusado.'
[[ "$(cat "${tmp_dir}/sudo.calls")" == $'-n true\n-v' ]] \
  || fail 'o caminho interativo não tentou sudo -n true antes de sudo -v.'

if run_helper deny; then
  fail 'sudo -n true e sudo -v recusados foram tratados como autorização.'
fi
[[ "$(cat "${tmp_dir}/sudo.calls")" == $'-n true\n-v' ]] \
  || fail 'a recusa não parou após a tentativa interativa.'

printf 'test-sudo-auth: PASS (NOPASSWD, fallback interativo e recusa)\n'
