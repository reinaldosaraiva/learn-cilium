#!/usr/bin/env bash
# L403/L404 — hostNetwork OFF, NodePort (controle). 30 probes x 3 repeticoes.
# workerA (10.30.1.12) primeiro, depois workerB (10.30.2.11).
# Uso: sudo bash l403-l404-probes.sh <run-id> <out-log>
set -u
RUN="${1:?run-id}"; OUT="${2:?out-log}"
C="sudo docker exec clab-p003-gw-fabric-client"
TA=10.30.1.12   # workerA
TB=10.30.2.11   # workerB
TNP=30921       # nodePort TCP 15432
UNP=31036       # nodePort UDP 15353
{
  echo "=== L403 TCP ${TA}:${TNP} hostNetwork=OFF NodePort (30x3) run ${RUN} ==="
  for rep in 1 2 3; do
    for i in $(seq 1 30); do
      nonce="P003-l403a-r${rep}-${i}-$(date +%s%N)"
      resp=$($C sh -c "echo ${nonce} | nc -w 3 ${TA} ${TNP}" 2>&1)
      if [ "$resp" = "$nonce" ]; then r=OK; else r=FAIL; fi
      echo "r${rep} ${i} ${r}"
    done
  done
  echo "=== L403 TCP ${TB}:${TNP} hostNetwork=OFF NodePort (30x3) run ${RUN} ==="
  for rep in 1 2 3; do
    for i in $(seq 1 30); do
      nonce="P003-l403b-r${rep}-${i}-$(date +%s%N)"
      resp=$($C sh -c "echo ${nonce} | nc -w 3 ${TB} ${TNP}" 2>&1)
      if [ "$resp" = "$nonce" ]; then r=OK; else r=FAIL; fi
      echo "r${rep} ${i} ${r}"
    done
  done
  echo "=== L404 UDP ${TA}:${UNP} hostNetwork=OFF NodePort (30x3) run ${RUN} ==="
  for rep in 1 2 3; do
    for i in $(seq 1 30); do
      resp=$($C dig @"${TA}" -p ${UNP} study.p003 TXT +short +notcp +ignore +tries=1 +time=2 2>&1)
      if [ "$resp" = '"P003-OK"' ]; then r=OK; else r=FAIL; fi
      echo "r${rep} ${i} ${r}"
    done
  done
  echo "=== L404 UDP ${TB}:${UNP} hostNetwork=OFF NodePort (30x3) run ${RUN} ==="
  for rep in 1 2 3; do
    for i in $(seq 1 30); do
      resp=$($C dig @"${TB}" -p ${UNP} study.p003 TXT +short +notcp +ignore +tries=1 +time=2 2>&1)
      if [ "$resp" = '"P003-OK"' ]; then r=OK; else r=FAIL; fi
      echo "r${rep} ${i} ${r}"
    done
  done
} > "$OUT" 2>&1
echo "OKs: $(grep -c ' OK$' "$OUT")  FAILs: $(grep -c ' FAIL$' "$OUT")"
