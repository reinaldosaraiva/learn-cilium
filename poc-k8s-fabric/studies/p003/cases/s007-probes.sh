#!/usr/bin/env bash
# P003-S007: probe runner. Roda no host vm-cilium; probes do container client.
# Sem retry, sem reuse de conexao (Connection: close, --retry 0).
# Body via stdout (docker exec nao escreve -o no host): ultima linha = metricas.
# Uso: s007-probes.sh <case_id> <base_url> <path> <decision> [N] [ROUNDS]
set -u
CASE_ID="${1:?case_id}"
BASE="${2:?base_url}"
P="${3:?path}"
DECISION="${4:-}"
N="${5:-30}"
ROUNDS="${6:-3}"
CLIENT="clab-p003-gw-fabric-client"
HOST="echo.p003.study"
OUT="/opt/poc-k8s-fabric-studies/studies/p003/evidence/S007-2026-09-22T0048Z/probes"
mkdir -p "$OUT"
now() { date -u +%FT%TZ; }

echo "[$(now)] START $CASE_ID base=$BASE path=$P decision=${DECISION:-none} N=$N ROUNDS=$ROUNDS"
for round in $(seq 1 "$ROUNDS"); do
  for i in $(seq 1 "$N"); do
    req_id="${CASE_ID}-r${round}-${i}"
    cmd=(curl -s -w $'\n%{http_code}\t%{time_total}'
      --noproxy '*' --retry 0 --connect-timeout 3 --max-time 30
      -H 'Connection: close'
      -H "Host: $HOST"
      -H "X-Lab-Request-ID: $req_id")
    if [ -n "$DECISION" ]; then
      cmd+=(-H "X-Lab-Decision: $DECISION")
    fi
    cmd+=("$BASE$P")
    out=$(sudo docker exec "$CLIENT" "${cmd[@]}" 2>"$OUT/${req_id}.stderr") || true
    metrics=$(printf '%s\n' "$out" | tail -n 1)
    printf '%s\n' "$out" | head -n -1 > "$OUT/${req_id}.body"
    echo -e "$CASE_ID\tr${round}\t$req_id\t$metrics" >> "$OUT/${CASE_ID}.tsv"
  done
done
echo "[$(now)] END $CASE_ID"
