#!/bin/bash
# P003-S005: Probe matrix A01-A10
# Run from: clab-p003-gw-fabric-client container
# Output: /tmp/s005-probes/ (inside the container)
set -euo pipefail

VIP="10.202.255.10"
PORT="8080"
HOST="echo.p003.study"
BASE="http://${VIP}:${PORT}"
OUT="/tmp/s005-probes"
ROUNDS=3
N=30

mkdir -p "$OUT"

probe() {
  local case_id="$1" path="$2" decision="$3" extra_headers="$4"
  local round req_id code time_total body_file

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

      local result
      result=$("${cmd[@]}" 2>"$OUT/${case_id}-r${round}-${i}.stderr") || true
      echo -e "$case_id\tr${round}\t$req_id\t$result" >> "$OUT/${case_id}.tsv"
    done
  done
}

echo "[$(date -u +%FT%TZ)] Starting S005 probe matrix"

# A01: /public (no auth)
echo "[$(date -u +%FT%TZ)] A01: /public"
probe "A01" "/public" "" ""

# A02: /protected-http + allow
echo "[$(date -u +%FT%TZ)] A02: /protected-http + allow"
probe "A02" "/protected-http" "allow" ""

# A03: /protected-http + deny
echo "[$(date -u +%FT%TZ)] A03: /protected-http + deny"
probe "A03" "/protected-http" "deny" ""

# A04: /protected-http + no decision
echo "[$(date -u +%FT%TZ)] A04: /protected-http + absent"
probe "A04" "/protected-http" "" ""

# A05: /protected-grpc + allow
echo "[$(date -u +%FT%TZ)] A05: /protected-grpc + allow"
probe "A05" "/protected-grpc" "allow" ""

# A06: /protected-grpc + deny
echo "[$(date -u +%FT%TZ)] A06: /protected-grpc + deny"
probe "A06" "/protected-grpc" "deny" ""

# A07: /protected-grpc + no decision
echo "[$(date -u +%FT%TZ)] A07: /protected-grpc + absent"
probe "A07" "/protected-grpc" "" ""

# A08: /protected-http + allow + forged X-Lab-User
echo "[$(date -u +%FT%TZ)] A08: /protected-http + forged X-Lab-User"
probe "A08" "/protected-http" "allow" "-H X-Lab-User:forger-attempt"

# A09: /protected-http + allow (isolation check - same auth, different route)
echo "[$(date -u +%FT%TZ)] A09: isolation (reusing A02 path with different ID prefix)"
probe "A09" "/protected-http" "allow" ""

# A10: /protected-http + allow + body (small)
echo "[$(date -u +%FT%TZ)] A10: /protected-http + body"
# A10 uses POST with body
for round in $(seq 1 $ROUNDS); do
  for i in $(seq 1 $N); do
    req_id="A10-r${round}-${i}"
    body_file="$OUT/A10-r${round}-${i}.body"
    # 100-byte synthetic body
    small_body=$(python3 -c "print('A'*100, end='')")
    result=$(curl -s -o "$body_file" -w '%{http_code}\t%{time_total}' \
      --noproxy '*' --retry 0 --connect-timeout 3 --max-time 30 \
      -H 'Connection: close' -H "Host: $HOST" \
      -H "X-Lab-Request-ID: $req_id" -H "X-Lab-Decision: allow" \
      -X POST -d "$small_body" \
      "$BASE/protected-http" 2>"$OUT/A10-r${round}-${i}.stderr") || true
    echo -e "A10\tr${round}\t$req_id\t$result" >> "$OUT/A10.tsv"
  done
done

echo "[$(date -u +%FT%TZ)] Probe matrix complete"
echo "Results in $OUT/"
ls -la "$OUT"/*.tsv 2>/dev/null | wc -l
echo "TSV files written"
