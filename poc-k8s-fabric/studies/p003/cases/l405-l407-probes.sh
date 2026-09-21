#!/usr/bin/env bash
# L405-L407 — hostNetwork ON. Subcasos separados por no (workerA -> workerB).
# 30 probes x 3 repeticoes por subcaso.
# Uso: sudo bash l405-l407-probes.sh <run-id> <out-log>
set -u
RUN="${1:?run-id}"; OUT="${2:?out-log}"
C="sudo docker exec clab-p003-gw-fabric-client"
TA=10.30.1.12   # workerA
TB=10.30.2.11   # workerB
MNP_T=30518     # nodePort TCP 15432 (main)
MNP_U=32277     # nodePort UDP 15353 (main)
tcp() { # $1=ip $2=port $3=tag
  for rep in 1 2 3; do
    for i in $(seq 1 30); do
      nonce="P003-$3-r${rep}-${i}-$(date +%s%N)"
      resp=$($C sh -c "echo ${nonce} | nc -w 3 $1 $2" 2>&1)
      if [ "$resp" = "$nonce" ]; then r=OK; else r=FAIL; fi
      echo "r${rep} ${i} ${r}"
    done
  done
}
udp() { # $1=ip $2=port $3=tag
  for rep in 1 2 3; do
    for i in $(seq 1 30); do
      resp=$($C dig @"$1" -p $2 study.p003 TXT +short +notcp +ignore +tries=1 +time=2 2>&1)
      if [ "$resp" = '"P003-OK"' ]; then r=OK; else r=FAIL; fi
      echo "r${rep} ${i} ${r}"
    done
  done
}
http() { # $1=ip $2=port $3=tag
  for rep in 1 2 3; do
    for i in $(seq 1 30); do
      code=$($C sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: echo.p003.study' http://$1:$2/" 2>&1)
      if [ "$code" = "200" ]; then r=OK; else r=FAIL; fi
      echo "r${rep} ${i} ${r}"
    done
  done
}
{
  echo "=== L405 TCP ${TA}:15432 hostNetwork=ON (30x3) run ${RUN} ===";      tcp $TA 15432 l405a1
  echo "=== L405 TCP ${TA}:${MNP_T} hostNetwork=ON (30x3) run ${RUN} ===";    tcp $TA $MNP_T l405a2
  echo "=== L405 TCP ${TB}:15432 hostNetwork=ON (30x3) run ${RUN} ===";       tcp $TB 15432 l405b1
  echo "=== L405 TCP ${TB}:${MNP_T} hostNetwork=ON (30x3) run ${RUN} ===";    tcp $TB $MNP_T l405b2
  echo "=== L406 UDP ${TA}:15353 hostNetwork=ON (30x3) run ${RUN} ===";       udp $TA 15353 l406a1
  echo "=== L406 UDP ${TA}:${MNP_U} hostNetwork=ON (30x3) run ${RUN} ===";    udp $TA $MNP_U l406a2
  echo "=== L406 UDP ${TB}:15353 hostNetwork=ON (30x3) run ${RUN} ===";       udp $TB 15353 l406b1
  echo "=== L406 UDP ${TB}:${MNP_U} hostNetwork=ON (30x3) run ${RUN} ===";    udp $TB $MNP_U l406b2
  echo "=== L407 HTTP ${TA}:8080 hostNetwork=ON (30x3) run ${RUN} ===";       http $TA 8080 l407a
  echo "=== L407 HTTP ${TB}:8080 hostNetwork=ON (30x3) run ${RUN} ===";       http $TB 8080 l407b
} > "$OUT" 2>&1
echo "OKs: $(grep -c ' OK$' "$OUT")  FAILs: $(grep -c ' FAIL$' "$OUT")"
