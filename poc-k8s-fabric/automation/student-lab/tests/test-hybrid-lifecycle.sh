#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
repo_root="$(cd -- "${script_dir}/../../../" && pwd -P)"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-$(command -v ansible-playbook || true)}"
scratch="${P010_HYBRID_TEST_SCRATCH:-/tmp/p010-hybrid-lifecycle-$(date -u +%Y%m%dT%H%M%SZ)}"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'LOG_DIR=%s\n' "${scratch}" >&2
  exit 1
}

[[ -x "${ansible_playbook_bin}" ]] || fail 'ansible-playbook ausente; passe ANSIBLE_PLAYBOOK_BIN.'
command -v jq >/dev/null 2>&1 || fail 'jq ausente; o checker de CIDRs usa o jq já exigido pelo student-lab.'
mkdir -m 0700 -p "${scratch}/positive" "${scratch}/negative" "${scratch}/network-negative" "${scratch}/image-negative" "${scratch}/ansible-local" "${scratch}/fake-bin"
trap 'rm -rf -- "${scratch}/positive" "${scratch}/negative" "${scratch}/network-negative" "${scratch}/image-negative" "${scratch}/ansible-local"' EXIT

cat >"${scratch}/fake-bin/cat" <<'EOF'
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
EOF
chmod 0700 "${scratch}/fake-bin/cat"

cat >"${scratch}/fake-bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

trace="${P010_HYBRID_TEST_DOCKER_TRACE:?}"
state_dir="${P010_HYBRID_TEST_DIR:?}"
objects_file="${state_dir}/docker-allowed-object-names"
networks_file="${state_dir}/docker-allowed-network-names"

printf 'CALL' >>"${trace}"
for argument in "$@"; do
  printf '\t%s' "${argument}" >>"${trace}"
done
printf '\n' >>"${trace}"

reject() {
  printf 'REJECT' >>"${trace}"
  for argument in "$@"; do
    printf '\t%s' "${argument}" >>"${trace}"
  done
  printf '\n' >>"${trace}"
  printf 'fixture fake Docker refused an unexpected request\n' >&2
  exit 70
}

allowed_name() {
  local wanted="$1" names_file="$2" name
  [[ -f "${names_file}" ]] || return 1
  while IFS= read -r name || [[ -n "${name}" ]]; do
    [[ "${name}" == "${wanted}" ]] && return 0
  done <"${names_file}"
  return 1
}

if [[ $# -eq 4 && "$1" == --host && "$2" == unix:///var/run/docker.sock && "$3" == inspect ]]; then
  name="$4"
  allowed_name "${name}" "${objects_file}" || reject "$@"
  printf '[]\n'
  printf 'error: no such object: %s\n' "${name}" >&2
  exit 1
fi

if [[ $# -eq 5 && "$1" == --host && "$2" == unix:///var/run/docker.sock && "$3" == network && "$4" == inspect ]]; then
  name="$5"
  allowed_name "${name}" "${networks_file}" || reject "$@"
  printf '[]\n'
  printf 'Error response from daemon: network %s not found\n' "${name}" >&2
  exit 1
fi

if [[ $# -eq 5 && "$1" == --host && "$2" == unix:///var/run/docker.sock && "$3" == version && "$4" == --format && "$5" == '{{.Server.Version}}' ]]; then
  printf '25.0.0\n'
  exit 0
fi

reject "$@"
EOF
chmod 0700 "${scratch}/fake-bin/docker"

cat >"${scratch}/fake-bin/kind" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

trace="${P010_HYBRID_TEST_KIND_TRACE:?}"
state_dir="${P010_HYBRID_TEST_DIR:?}"
cluster_name_file="${state_dir}/kind-allowed-cluster-name"

printf 'CALL' >>"${trace}"
for argument in "$@"; do
  printf '\t%s' "${argument}" >>"${trace}"
done
printf '\n' >>"${trace}"

reject() {
  printf 'REJECT' >>"${trace}"
  for argument in "$@"; do
    printf '\t%s' "${argument}" >>"${trace}"
  done
  printf '\n' >>"${trace}"
  printf 'fixture fake Kind refused an unexpected request\n' >&2
  exit 70
}

[[ -f "${cluster_name_file}" ]] || reject "$@"
IFS= read -r cluster_name <"${cluster_name_file}" || [[ -n "${cluster_name}" ]] || reject "$@"
if [[ $# -eq 2 && "$1" == get && "$2" == clusters ]]; then
  exit 0
fi
if [[ $# -eq 4 && "$1" == get && "$2" == nodes && "$3" == --name && "$4" == "${cluster_name}" ]]; then
  exit 0
fi
reject "$@"
EOF
chmod 0700 "${scratch}/fake-bin/kind"

export ANSIBLE_CONFIG="${script_dir}/ansible.cfg"
export ANSIBLE_NOCOLOR=1
export ANSIBLE_LOCAL_TEMP="${scratch}/ansible-local"

if ! bash -n "${script_dir}/lab" "${script_dir}/preflight.sh" "${BASH_SOURCE[0]}"; then
  fail 'sintaxe Bash inválida.'
fi
if ! "${ansible_playbook_bin}" --syntax-check -i localhost, "${script_dir}/tests/hybrid-syntax.yml" >"${scratch}/syntax.log" 2>&1; then
  fail 'syntax-check dos helpers Ansible falhou.'
fi
if ! "${ansible_playbook_bin}" --syntax-check -i localhost, "${script_dir}/site.yml" >"${scratch}/site-syntax.log" 2>&1; then
  fail 'syntax-check do site.yml falhou.'
fi

if ! env \
  P010_HYBRID_TEST_REPO_ROOT="${repo_root}" \
  P010_HYBRID_TEST_DIR="${scratch}/positive" \
  P010_HYBRID_TEST_UID="$(id -u)" \
  P010_HYBRID_TEST_UUID_BIN="${scratch}/fake-bin/cat" \
  P010_HYBRID_TEST_DOCKER_BIN="${scratch}/fake-bin/docker" \
  P010_HYBRID_TEST_DOCKER_TRACE="${scratch}/docker-positive.trace" \
  P010_HYBRID_TEST_TOOL_DIR="${scratch}/fake-bin" \
  P010_HYBRID_TEST_KIND_TRACE="${scratch}/kind-positive.trace" \
  "${ansible_playbook_bin}" -i localhost, "${script_dir}/tests/hybrid-lifecycle.yml" >"${scratch}/positive.log" 2>&1; then
  fail 'reserva schema3, render, identidade limpa ou cleanup repetido falhou.'
fi

if [[ ! -s "${scratch}/docker-positive.trace" ]]; then
  fail 'o fixture de ciclo não consultou o fake Docker restrito.'
fi
if rg -n '^REJECT\t|\t(rm|prune|network rm)(\t|$)' "${scratch}/docker-positive.trace"; then
  fail 'o fluxo positivo tentou uma chamada Docker inesperada ou remoção.'
fi
if rg -n '^REJECT\t|\t(delete|create|load)(\t|$)' "${scratch}/kind-positive.trace"; then
  fail 'o fluxo positivo tentou uma chamada Kind inesperada ou mutável.'
fi

if env \
  P010_HYBRID_TEST_DIR="${scratch}/positive" \
  P010_HYBRID_TEST_DOCKER_TRACE="${scratch}/docker-unexpected-name.trace" \
  "${scratch}/fake-bin/docker" --host unix:///var/run/docker.sock inspect p010-hibrido-unexpected >"${scratch}/docker-unexpected-name.log" 2>&1; then
  fail 'o fake Docker aceitou um nome fora do perfil.'
fi
grep -Fq 'REJECT' "${scratch}/docker-unexpected-name.trace" \
  || fail 'a rejeição do nome fora do perfil não foi registrada.'

if env \
  P010_HYBRID_TEST_DIR="${scratch}/positive" \
  P010_HYBRID_TEST_DOCKER_TRACE="${scratch}/docker-remove.trace" \
  "${scratch}/fake-bin/docker" rm p010-hibrido-worker >"${scratch}/docker-remove.log" 2>&1; then
  fail 'o fake Docker aceitou uma operação de remoção.'
fi
grep -Fq 'REJECT' "${scratch}/docker-remove.trace" \
  || fail 'a rejeição de remoção não foi registrada.'

if env \
  P010_HYBRID_TEST_DIR="${scratch}/positive" \
  P010_HYBRID_TEST_KIND_TRACE="${scratch}/kind-unexpected-command.trace" \
  "${scratch}/fake-bin/kind" delete cluster --name p010-hibrido >"${scratch}/kind-unexpected-command.log" 2>&1; then
  fail 'o fake Kind aceitou uma chamada fora do conjunto read-only.'
fi
grep -Fq 'REJECT' "${scratch}/kind-unexpected-command.trace" \
  || fail 'a rejeição da chamada Kind mutável não foi registrada.'

if ! env \
  P010_HYBRID_TEST_DIR="${scratch}/positive" \
  P010_HYBRID_TEST_UID="$(id -u)" \
  P010_HYBRID_RUN_PATH_ACTION=status \
  P010_HYBRID_RUN_PATH_PROFILE=hibrido \
  "${ansible_playbook_bin}" -i localhost, "${script_dir}/tests/hybrid-run-paths.yml" >"${scratch}/status-down.log" 2>&1; then
  fail 'status sobre estado híbrido down não preservou o diretório histórico.'
fi

if ! env \
  P010_HYBRID_TEST_DIR="${scratch}/positive" \
  P010_HYBRID_TEST_UID="$(id -u)" \
  P010_HYBRID_RUN_PATH_ACTION=up \
  P010_HYBRID_RUN_PATH_PROFILE=iniciantes \
  "${ansible_playbook_bin}" -i localhost, "${script_dir}/tests/hybrid-run-paths.yml" >"${scratch}/up-beginner-after-down.log" 2>&1; then
  fail 'up de iniciantes não separou a nova execução do estado híbrido down.'
fi

if env \
  P010_HYBRID_TEST_REPO_ROOT="${repo_root}" \
  P010_HYBRID_TEST_DIR="${scratch}/negative" \
  P010_HYBRID_TEST_UID="$(id -u)" \
  P010_HYBRID_TEST_UUID_BIN="${scratch}/fake-bin/cat" \
  P010_HYBRID_TEST_DOCKER_BIN="${scratch}/fake-bin/docker" \
  P010_HYBRID_TEST_DOCKER_TRACE="${scratch}/docker-negative.trace" \
  P010_HYBRID_TEST_TOOL_DIR="${scratch}/fake-bin" \
  P010_HYBRID_TEST_KIND_TRACE="${scratch}/kind-negative.trace" \
  P010_HYBRID_TEST_NEGATIVE=unrecorded-overlay \
  "${ansible_playbook_bin}" -i localhost, "${script_dir}/tests/hybrid-lifecycle.yml" >"${scratch}/negative.log" 2>&1; then
  fail 'identity checker aceitou um overlay sem inode registrado.'
fi
if grep -Fq '123e4567-e89b-42d3-a456-426614174000' "${scratch}/negative.log"; then
  fail 'um token privado apareceu no log negativo.'
fi

if env \
  P010_HYBRID_TEST_REPO_ROOT="${repo_root}" \
  P010_HYBRID_TEST_DIR="${scratch}/network-negative" \
  P010_HYBRID_TEST_UID="$(id -u)" \
  P010_HYBRID_TEST_UUID_BIN="${scratch}/fake-bin/cat" \
  P010_HYBRID_TEST_DOCKER_BIN="${scratch}/fake-bin/docker" \
  P010_HYBRID_TEST_DOCKER_TRACE="${scratch}/docker-network-negative.trace" \
  P010_HYBRID_TEST_TOOL_DIR="${scratch}/fake-bin" \
  P010_HYBRID_TEST_KIND_TRACE="${scratch}/kind-network-negative.trace" \
  P010_HYBRID_TEST_NEGATIVE=unexpected-network-identity \
  "${ansible_playbook_bin}" -i localhost, "${script_dir}/tests/hybrid-lifecycle.yml" >"${scratch}/network-negative.log" 2>&1; then
  fail 'identity checker aceitou um nome/alias de interface não verificado.'
fi
if grep -Fq '123e4567-e89b-42d3-a456-426614174000' "${scratch}/network-negative.log"; then
  fail 'um token privado apareceu no log de identidade de rede.'
fi

if env \
  P010_HYBRID_TEST_REPO_ROOT="${repo_root}" \
  P010_HYBRID_TEST_DIR="${scratch}/image-negative" \
  P010_HYBRID_TEST_UID="$(id -u)" \
  P010_HYBRID_TEST_UUID_BIN="${scratch}/fake-bin/cat" \
  P010_HYBRID_TEST_DOCKER_BIN="${scratch}/fake-bin/docker" \
  P010_HYBRID_TEST_DOCKER_TRACE="${scratch}/docker-image-negative.trace" \
  P010_HYBRID_TEST_TOOL_DIR="${scratch}/fake-bin" \
  P010_HYBRID_TEST_KIND_TRACE="${scratch}/kind-image-negative.trace" \
  P010_HYBRID_TEST_NEGATIVE=image-replacement \
  "${ansible_playbook_bin}" -i localhost, "${script_dir}/tests/hybrid-lifecycle.yml" >"${scratch}/image-negative.log" 2>&1; then
  fail 'identity checker aceitou uma imagem-base com inode substituído.'
fi
if grep -Fq '123e4567-e89b-42d3-a456-426614174000' "${scratch}/image-negative.log"; then
  fail 'um token privado apareceu no log negativo de imagem.'
fi

set +e
LAB=hibrido make --no-print-directory -C "${repo_root}" lab-up >"${scratch}/public-up.log" 2>&1
public_up_rc=$?
set -e
[[ "${public_up_rc}" == 2 ]] || fail "lab-up LAB=hibrido retornou ${public_up_rc}, esperado 2."
grep -Fq 'recusado antes de qualquer alteração' "${scratch}/public-up.log" \
  || fail 'a recusa pública de M11 não foi visível.'

hybrid_cidrs=( $(jq -r 'to_entries[] | if (.value | type) == "array" then .value[] else .value end' "${scratch}/positive/hybrid-cidrs.json") )
legacy_cidrs=(
  10.223.32.0/24 10.245.0.0/16 10.112.0.0/16 10.1.1.0/24
  10.30.1.0/24 10.30.2.0/24 10.254.0.0/16 10.202.255.0/24
  10.201.255.0/24 10.101.0.0/30 198.19.0.0/24 10.248.0.0/13
)

cidr_range() {
  local cidr="$1" a b c d prefix address mask start end
  IFS='./' read -r a b c d prefix <<<"${cidr}"
  [[ "${prefix}" =~ ^[0-9]+$ ]] || return 1
  (( prefix >= 0 && prefix <= 32 )) || return 1
  address=$(( (a << 24) | (b << 16) | (c << 8) | d ))
  mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
  start=$(( address & mask ))
  end=$(( start | ((~mask) & 0xffffffff) ))
  printf '%s %s\n' "${start}" "${end}"
}

cidrs_overlap() {
  local left_start left_end right_start right_end
  read -r left_start left_end < <(cidr_range "$1") || return 2
  read -r right_start right_end < <(cidr_range "$2") || return 2
  (( left_start <= right_end && right_start <= left_end ))
}

for ((i = 0; i < ${#hybrid_cidrs[@]}; i++)); do
  for legacy in "${legacy_cidrs[@]}"; do
    if cidrs_overlap "${hybrid_cidrs[i]}" "${legacy}"; then
      fail "prefixo híbrido ${hybrid_cidrs[i]} sobrepõe entrada P003 ${legacy}."
    fi
  done
  for ((j = i + 1; j < ${#hybrid_cidrs[@]}; j++)); do
    if cidrs_overlap "${hybrid_cidrs[i]}" "${hybrid_cidrs[j]}"; then
      fail "prefixos híbridos ${hybrid_cidrs[i]} e ${hybrid_cidrs[j]} se sobrepõem."
    fi
  done
done

printf 'PASS: Bash/Ansible syntax, schema3 reservation, seed render, fail-closed identity, repeat-down, public-up gate, and disjoint CIDRs.\n'
printf 'LOG_DIR=%s\n' "${scratch}"
