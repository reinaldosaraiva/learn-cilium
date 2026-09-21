#!/usr/bin/env bash
# L408 — baseline recuperado (hostNetwork OFF, LoadBalancer VIP). 30x3 por porta.
# VIP:15432 (TCP), VIP:15353 (UDP), VIP:8080 (HTTP).
# Uso: sudo bash l408-probes.sh <run-id> <out-log>
set -u
RUN="${1:?run-id}"; OUT="${2:?out-log}"
C="sudo docker exec clab-p003-gw-fabric-client"
VIP=10.202.255.10
{
  echo "=== L408 TCP ${VIP}:15432 hostNetwork=OFF LoadBalancer (30x3) run ${RUN} ==="
  for rep in 1 2 3; do
    for i in $(seq 1 30); do
      nonce="P003-l408t-r${rep}-${i}-$(date +%s%N)"
      resp=$($C sh -c "echo ${nonce} | nc -w 3 ${VIP} 15432" 2>&1)
      if [ "$resp" = "$nonce" ]; then r=OK; else r=FAIL; fi
      echo "r${rep} ${i} ${r}"
    done
  done
  echo "=== L408 UDP ${VIP}:15353 hostNetwork=OFF LoadBalancer (30x3) run ${RUN} ==="
  for rep in 1 2 3; do
    for i in $(seq 1 30); do
      resp=$($C dig @"${VIP}" -p 15353 study.p003 TXT +short +notcp +ignore +tries=1 +time=2 2>&1)
      if [ "$resp" = '"P003-OK"' ]; then r=OK; else r=FAIL; fi
      echo "r${rep} ${i} ${r}"
    done
  done
  echo "=== L408 HTTP ${VIP}:8080 hostNetwork=OFF LoadBalancer (30x3) run ${RUN} ==="
  for rep in 1 2 3; do
    for i in $(seq 1 30); do
      code=$($C sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: echo.p003.study' http://${VIP}:8080/" 2>&1)
      if [ "$code" = "200" ]; then r=OK; else r=FAIL; fi
      echo "r${rep} ${i} ${r}"
    done
  done
} > "$OUT" 2>&1
echo "OKs: $(grep -c ' OK$' "$OUT")  FAILs: $(grep -c ' FAIL$' "$OUT")"
