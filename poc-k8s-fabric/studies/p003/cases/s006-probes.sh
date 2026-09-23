#!/bin/bash
# P003-S006: Probe matrix A11-A18 (failure modes + cross-namespace)
# Run from: clab-p003-gw-fabric-client container
# Output: /tmp/s006-probes/ (inside the container)
# Usage: bash s006-probes.sh <case_id> <path> <decision> [extra_headers]
#        bash s006-probes.sh A17 <path> <decision> [extra_headers]  (90s continuous loop)
#        bash s006-probes.sh control <path> <decision> [extra_headers]
set -u

VIP="10.202.255.10"
PORT="8080"
HOST="echo.p003.study"
BASE="http://${VIP}:${PORT}"
OUT="/tmp/s006-probes"
ROUNDS=3
N=30

mkdir -p "$OUT"

now() { date -u +%FT%TZ; }

probe() {
  local case_id="$1" path="$2" decision="$3" extra_headers="$4"
  local round req_id code time_total body_file result

  echo "[$(now)] START $case_id path=$path decision=${decision:-none}"
  for round in $(seq 1 $ROUNDS); do
    for i in $(seq 1 $N); do
      req_id="${case_id}-r${round}-${i}"
      body_file="$OUT/${case_id}-r${round}-${i}.body"

      local cmd=(curl -s -o "$body_file" -w '%{http_code}\t%{time_total}'
        --noproxy '*' --retry 0 --connect-timeout 3 --max-time 30
        -H 'Connection: close'
        -H "Host: $HOST"
        -H "X-Lab-Request-ID: $req_id")

      if [ -n "$decision" ]; then
        cmd+=(-H "X-Lab-Decision: $decision")
      fi
      if [ -n "$extra_headers" ]; then
        # shellcheck disable=SC2206
        local hdrs=($extra_headers)
        cmd+=("${hdrs[@]}")
      fi

      cmd+=("$BASE$path")

      result=$("${cmd[@]}" 2>"$OUT/${case_id}-r${round}-${i}.stderr") || true
      echo -e "$case_id\tr${round}\t$req_id\t$result" >> "$OUT/${case_id}.tsv"
    done
  done
  echo "[$(now)] END $case_id"
}

# A17: continuous loop for 90s, one request every 2s, with wall-clock timestamp
probe_a17() {
  local case_id="$1" path="$2" decision="$3" extra_headers="$4"
  local i req_id result
  echo "[$(now)] START $case_id (continuous 90s) path=$path decision=${decision:-none}"
  for i in $(seq 1 45); do
    req_id="${case_id}-c${i}"
    local cmd=(curl -s -o "$OUT/${case_id}-c${i}.body" -w '%{http_code}\t%{time_total}'
      --noproxy '*' --retry 0 --connect-timeout 3 --max-time 10
      -H 'Connection: close'
      -H "Host: $HOST"
      -H "X-Lab-Request-ID: $req_id")
    if [ -n "$decision" ]; then
      cmd+=(-H "X-Lab-Decision: $decision")
    fi
    if [ -n "$extra_headers" ]; then
      # shellcheck disable=SC2206
      local hdrs=($extra_headers)
      cmd+=("${hdrs[@]}")
    fi
    cmd+=("$BASE$path")
    result=$("${cmd[@]}" 2>"$OUT/${case_id}-c${i}.stderr") || true
    echo -e "$case_id\tc${i}\t$req_id\t$(date -u +%s)\t$result" >> "$OUT/${case_id}.tsv"
    sleep 2
  done
  echo "[$(now)] END $case_id"
}

case_id="${1:?case_id required}"
path="${2:?path required}"
decision="${3:-}"
extra="${4:-}"

case "$case_id" in
  A17*) probe_a17 "$case_id" "$path" "$decision" "$extra" ;;
  *)    probe "$case_id" "$path" "$decision" "$extra" ;;
esac

echo "[$(now)] done $case_id"
