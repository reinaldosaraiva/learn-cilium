#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
repo_root="$(cd "${script_dir}/../../.." && pwd -P)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
  printf 'test-guards: %s\n' "$1" >&2
  exit 1
}

if LAB=invalid "${script_dir}/lab" up >"${tmp_dir}/invalid.out" 2>&1; then
  fail 'perfil inválido foi aceito.'
fi
grep -Fq 'LAB inválido' "${tmp_dir}/invalid.out" \
  || fail 'perfil inválido não retornou erro explícito.'

if LAB=hibrido "${script_dir}/lab" status >"${tmp_dir}/hybrid.out" 2>&1; then
  fail 'perfil híbrido não implementado foi aceito.'
fi
grep -Fq 'M11 não está implementado' "${tmp_dir}/hybrid.out" \
  || fail 'perfil híbrido não retornou erro explícito.'

marker="${tmp_dir}/make-expanded-lab-value"
injected_lab="\$(shell touch ${marker})"
(cd "${repo_root}" && LAB="${injected_lab}" make -s lab-up) \
  >"${tmp_dir}/make.out" 2>&1 \
  && fail 'make lab-up aceitou conteúdo de LAB fora da allowlist.'
[[ ! -e "${marker}" ]] \
  || fail 'Make avaliou conteúdo de LAB como função shell.'
grep -Fq 'LAB inválido' "${tmp_dir}/make.out" \
  || fail 'make lab-up não retornou erro explícito para LAB injetado.'

if LAB=plataforma EXERCISE=invalid "${script_dir}/lab" preflight >"${tmp_dir}/exercise.out" 2>&1; then
  fail 'EXERCISE inválido passou pela validação local.'
fi
grep -Fq 'EXERCISE inválido' "${tmp_dir}/exercise.out" \
  || fail 'EXERCISE inválido não retornou recusa explícita antes do preflight.'
exercise_injected="\$(shell touch ${marker})"
if (cd "${repo_root}" && LAB=plataforma EXERCISE="${exercise_injected}" make -s lab-up) >"${tmp_dir}/make-exercise-injected.out" 2>&1; then
  fail 'Make aceitou conteúdo EXERCISE fora da allowlist.'
fi
[[ ! -e "${marker}" ]] || fail 'Make avaliou EXERCISE como função shell.'
grep -Fq 'EXERCISE inválido' "${tmp_dir}/make-exercise-injected.out" \
  || fail 'Make não recusou EXERCISE injetado de forma explícita.'

if LAB=plataforma EXERCISE=baseline WG=W0 "${script_dir}/lab" up >"${tmp_dir}/wireguard.out" 2>&1; then
  fail 'WG foi aceito fora de um cenário WireGuard.'
fi
grep -Fq 'WG só se aplica aos cenários WireGuard' "${tmp_dir}/wireguard.out" \
  || fail 'WG fora do cenário correto não retornou recusa explícita.'

if LAB=fundamentos EXERCISE=baseline "${script_dir}/lab" up >"${tmp_dir}/profile-exercise.out" 2>&1; then
  fail 'EXERCISE foi aceito fora de LAB=plataforma.'
fi
grep -Fq 'EXERCISE/WG só se aplicam a LAB=plataforma' "${tmp_dir}/profile-exercise.out" \
  || fail 'EXERCISE fora de plataforma não retornou recusa explícita.'

bash "${script_dir}/tests/test-scenarios.sh"
bash "${script_dir}/tests/test-sudo-auth.sh"

host_os="$(awk -F= '$1 == "ID" {gsub(/"/, "", $2); id=$2} $1 == "VERSION_ID" {gsub(/"/, "", $2); version=$2} END {print id " " version}' /etc/os-release 2>/dev/null || true)"
if [[ "${host_os}" != 'ubuntu 24.04' ]]; then
  if "${script_dir}/preflight.sh" iniciantes "${tmp_dir}/state.json" \
    >"${tmp_dir}/preflight.out" 2>&1; then
    fail 'preflight aceitou sistema operacional fora do suporte.'
  fi
  grep -Fq 'Ubuntu 24.04' "${tmp_dir}/preflight.out" \
    || fail 'preflight não explicou o sistema operacional suportado.'
  [[ ! -e "${tmp_dir}/state.json" ]] \
    || fail 'preflight criou state ao falhar.'
fi

printf 'test-guards: PASS (LAB inválido, M11, injeção Make, allowlist e preflight sem state)\n'
