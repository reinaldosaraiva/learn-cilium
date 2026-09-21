#!/usr/bin/env bash
# S004 diagnostico 10 — discriminante L7 vs L4 no hostNetwork + interface binding.
# Uso: sudo bash s004-diag10.sh <out>
set -u
OUT="${1:?out}"
C="sudo docker exec clab-p003-gw-fabric-client"
{
  echo "=== L7: workerA fabric 10.30.1.12:8080 (Host echo.p003.study) ==="
  for i in 1 2 3; do
    code=$($C sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: echo.p003.study' http://10.30.1.12:8080/" 2>&1)
    echo "try$i http_code=$code"
  done
  echo "=== L7: workerA kind-bridge 172.19.0.6:8080 ==="
  for i in 1 2 3; do
    code=$($C sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: echo.p003.study' http://172.19.0.6:8080/" 2>&1)
    echo "try$i http_code=$code"
  done
  echo "=== L4: workerA kind-bridge 172.19.0.6:15432 ==="
  nonce="P003-d10-bridge-$(date +%s%N)"
  resp=$($C sh -c "echo ${nonce} | nc -w 3 172.19.0.6 15432" 2>&1)
  echo "resp: [${resp}]  (esperado: ${nonce})"
  echo "=== L4: workerA fabric 10.30.1.12:15432 (reconfirm) ==="
  nonce2="P003-d10-fabric-$(date +%s%N)"
  resp2=$($C sh -c "echo ${nonce2} | nc -w 3 10.30.1.12 15432" 2>&1)
  echo "resp: [${resp2}]  (esperado: ${nonce2})"
  echo "=== L4 nodePort: workerA fabric 10.30.1.12:30518 (controle) ==="
  nonce3="P003-d10-np-$(date +%s%N)"
  resp3=$($C sh -c "echo ${nonce3} | nc -w 3 10.30.1.12 30518" 2>&1)
  echo "resp: [${resp3}]  (esperado: ${nonce3})"
  echo "=== UDP: workerA fabric 10.30.1.12:15353 ==="
  r=$($C dig @10.30.1.12 -p 15353 study.p003 TXT +short +notcp +ignore +tries=1 +time=2 2>&1)
  echo "dig: [${r}]  (esperado: \"P003-OK\")"
  echo "=== UDP: workerA kind-bridge 172.19.0.6:15353 ==="
  r2=$($C dig @172.19.0.6 -p 15353 study.p003 TXT +short +notcp +ignore +tries=1 +time=2 2>&1)
  echo "dig: [${r2}]  (esperado: \"P003-OK\")"
} > "$OUT" 2>&1
cat "$OUT"
