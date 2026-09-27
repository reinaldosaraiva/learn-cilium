#!/usr/bin/env bash
# lib/common.sh — funções comuns do labctl (P004-S001).
# Sourced pelo labctl ANTES do perfil. Não executa nada ao ser carregado.
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
EVIDENCE_DIR="${EVIDENCE_DIR:-}"
LABCTL_STATE_DIR="${LABCTL_STATE_DIR:-/var/lib/labctl}"

log() { echo "[labctl] $*"; }

# die <mensagem> [código]: encerra com erro.
die() {
  local msg="$1" code="${2:-1}"
  echo "[labctl] ERRO: ${msg}" >&2
  exit "${code}"
}

# run <cmd...>: executa a mutação, ou imprime "DRY: <cmd>" quando DRY_RUN=1.
# TODA mutação passa por aqui. Leituras podem rodar direto (não mudam estado).
# Em modo real, uma mutação que falha ENCERRA a ação (die) — o corpo da função
# roda com errexit suprimido pelo despacho (|| rc=$?), então sem este die uma
# falha intermediária viria "OK" falso na linha final (P1-1 da revisão v2).
run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: $*"
    return 0
  fi
  log "+ $*"
  "$@" || die "comando falhou: $*"
}

# require_cmd <cmd...>: falha se faltar qualquer um.
require_cmd() {
  local c
  for c in "$@"; do
    command -v "${c}" >/dev/null 2>&1 || die "comando ausente: ${c}"
  done
}

# mem_avail_gib: MemAvailable do host em GiB (2 casas).
mem_avail_gib() {
  awk '/^MemAvailable:/{printf "%.2f", $2/1024/1024}' /proc/meminfo
}

state_file() { echo "${LABCTL_STATE_DIR}/$1.json"; }

# state_set <lab> <chave> <valor>: grava no JSON do lab (via python3, sem jq).
state_set() {
  local lab="$1" key="$2" val="$3"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: state_set ${lab} ${key}=${val}"
    return 0
  fi
  local f
  f="$(state_file "${lab}")"
  mkdir -p "$(dirname "${f}")"
  python3 - "${f}" "${key}" "${val}" <<'PY'
import json, os, sys
f, k, v = sys.argv[1], sys.argv[2], sys.argv[3]
d = {}
if os.path.exists(f):
    try:
        d = json.load(open(f))
    except Exception:
        d = {}
d[k] = v
json.dump(d, open(f, "w"), indent=2, sort_keys=True)
PY
}

# state_get <lab> <chave>: imprime o valor (vazio se ausente).
state_get() {
  local lab="$1" key="$2"
  local f
  f="$(state_file "${lab}")"
  [[ -f "${f}" ]] || { echo ""; return 0; }
  python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
    print(d.get(sys.argv[2],""))
except Exception:
    print("")' "${f}" "${key}"
}

# kctl <args>: kubectl com kubeconfig e contexto EXPLÍCITOS do perfil.
# Nunca usa contexto implícito (contrato §3.3).
kctl() {
  : "${LAB_KUBECONFIG:?LAB_KUBECONFIG não definido no perfil}"
  : "${LAB_CONTEXT:?LAB_CONTEXT não definido no perfil}"
  kubectl --kubeconfig "${LAB_KUBECONFIG}" --context "${LAB_CONTEXT}" "$@"
}

# evidence_dir <lab>: diretório de evidência desta ação (cria e imprime).
# Em dry-run não cria o diretório (mutação) — só declara (P3-5 da revisão v2).
evidence_dir() {
  local lab="$1"
  local d="${EVIDENCE_DIR:-/var/tmp/labctl/${lab}/$(date -u +%Y-%m-%dT%H%M%SZ)}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: mkdir -p ${d}" >&2
  else
    mkdir -p "${d}"
  fi
  echo "${d}"
}

# assert_absent_containers <prefixo>: falha se houver container (até parado)
# com o prefixo. Em dry-run só declara a checagem.
assert_absent_containers() {
  local prefix="$1"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: assert_absent_containers ${prefix}"
    return 0
  fi
  local n
  n="$(docker ps -a --format '{{.Names}}' | grep -c "^${prefix}" || true)"
  [[ "${n}" -eq 0 ]] || die "resíduo: ${n} container(es) com prefixo '${prefix}'"
}

# assert_absent_link <nome>: falha se o link de host existir.
assert_absent_link() {
  local name="$1"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: assert_absent_link ${name}"
    return 0
  fi
  if ip link show "${name}" >/dev/null 2>&1; then
    die "resíduo: link '${name}' ainda existe"
  fi
  return 0
}

# clab_deploy_nohup <topologia> <log>: clab deploy em segundo plano (nohup) e
# espera o fim lendo o log (lição D-1 da P003-S003: nunca foreground c/ timeout
# de canal SSH). Timeout 20 min.
clab_deploy_nohup() {
  local topo="$1" logfile="$2"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: clab deploy -t ${topo} (nohup; log ${logfile})"
    return 0
  fi
  require_cmd clab
  log "clab deploy -t ${topo} via nohup (log: ${logfile})"
  nohup clab deploy -t "${topo}" >"${logfile}" 2>&1 &
  local pid=$!
  local waited=0 timeout=1200 rc=0
  while kill -0 "${pid}" 2>/dev/null; do
    sleep 5
    waited=$((waited + 5))
    if [[ "${waited}" -ge "${timeout}" ]]; then
      kill "${pid}" 2>/dev/null || true
      die "clab deploy não terminou em ${timeout}s (log: ${logfile})"
    fi
  done
  wait "${pid}" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    die "clab deploy falhou (rc=${rc}; log: ${logfile})"
  fi
  log "clab deploy concluído (log: ${logfile})"
}
