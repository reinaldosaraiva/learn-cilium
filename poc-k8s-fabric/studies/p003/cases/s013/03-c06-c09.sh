#!/usr/bin/env bash
# P003-S013 step 03 — C06/C07/C08/C09 (sandbox, lado K8s completo)
# C06: auth pod recriado -> allow/deny continuam corretos no caminho novo.
# C07: rota removida -> novos requests deixam de alcançar o backend (convergência medida).
# C08: conexão longa antes da revogação -> comportamento documentado (não inferir encerramento).
# C09: regra stale proposital -> teste identifica vazamento; regra removida -> caso negativo.
set -uo pipefail

RUN=2026-09-24T1145Z
EV=/opt/poc-k8s-fabric-studies/studies/p003/evidence/P003/S013/$RUN
mkdir -p "$EV"
k() { sudo KUBECONFIG=/root/.kube/p003-gw.config kubectl "$@"; }
GWNS=p003-gateway
FC="sudo /usr/bin/docker exec clab-p003-gw-fabric-client"
BASE="http://10.30.1.11:30676"
HOST_HDR="Host: echo.p003.study"

auth_probes() { # imprime allow/deny/ausente/public
  {
    echo "allow:   $($FC curl -s -o /dev/null -w '%{http_code}' -H "$HOST_HDR" -H 'X-Lab-Decision: allow' --max-time 8 $BASE/protected-http)"
    echo "deny:    $($FC curl -s -o /dev/null -w '%{http_code}' -H "$HOST_HDR" -H 'X-Lab-Decision: deny' --max-time 8 $BASE/protected-http)"
    echo "ausente: $($FC curl -s -o /dev/null -w '%{http_code}' -H "$HOST_HDR" --max-time 8 $BASE/protected-http)"
    echo "public:  $($FC curl -s -o /dev/null -w '%{http_code}' -H "$HOST_HDR" --max-time 8 $BASE/public)"
  }
}

echo "### [C06] recriar auth pod -> allow/deny no caminho novo"
A0=$(k -n $GWNS get pod -l app=p003-authz -o jsonpath='{.items[0].metadata.uid}')
echo "auth uid antes: $A0" | tee "$EV/03-c06.txt"
k -n $GWNS delete pod -l app=p003-authz --wait=true --timeout=60s 2>&1 | sed 's/^/  /' | tee -a "$EV/03-c06.txt"
k -n $GWNS rollout status deploy/p003-authz --timeout=90s 2>&1 | sed 's/^/  /' | tee -a "$EV/03-c06.txt"
A1=$(k -n $GWNS get pod -l app=p003-authz -o jsonpath='{.items[0].metadata.uid}')
echo "auth uid depois: $A1 (novo=$([ "$A0" != "$A1" ] && echo sim || echo nao))" | tee -a "$EV/03-c06.txt"
sleep 3
echo "== probes pós-recriação (esperado 200/403/401/200) ==" | tee -a "$EV/03-c06.txt"
auth_probes | tee -a "$EV/03-c06.txt"

echo "### [C07] remover rota /protected-http -> convergência p/ não-200"
echo "antes: $($FC curl -s -o /dev/null -w '%{http_code}' -H "$HOST_HDR" -H 'X-Lab-Decision: allow' --max-time 8 $BASE/protected-http)" | tee "$EV/03-c07.txt"
T0=$(date +%s)
k -n $GWNS delete httproute p003-protected-http 2>&1 | sed 's/^/  /' | tee -a "$EV/03-c07.txt"
echo "rota removida em t=0" | tee -a "$EV/03-c07.txt"
for i in 1 2 3 4 5 6; do
  sleep 5
  CODE=$($FC curl -s -o /dev/null -w '%{http_code}' -H "$HOST_HDR" -H 'X-Lab-Decision: allow' --max-time 8 $BASE/protected-http)
  EL=$(( $(date +%s) - T0 ))
  echo "t=${EL}s code=$CODE" | tee -a "$EV/03-c07.txt"
  [ "$CODE" != "200" ] && { echo "convergência em ~${EL}s (code=$CODE)"; break; }
done
# restaurar a rota (rollback parcial do caso)
k -n $GWNS apply -f /opt/poc-k8s-fabric-studies/studies/p003/cases/s013/01d-auth-routes.yaml 2>&1 | grep protected-http | sed 's/^/  /' | tee -a "$EV/03-c07.txt"
sleep 3
echo "pós-restauração: $($FC curl -s -o /dev/null -w '%{http_code}' -H "$HOST_HDR" -H 'X-Lab-Decision: allow' --max-time 8 $BASE/protected-http)" | tee -a "$EV/03-c07.txt"

echo "### [C08] conexão longa antes da revogação (recriação do auth pod)"
# abre uma conexão HTTP keep-alive longa contra /public (backend http-echo, estável)
# e, em paralelo, recria o AUTH pod; documenta se a conexão existente sobrevive.
echo "abrindo conexão longa (curl keep-alive, 25s) contra /public..." | tee "$EV/03-c08.txt"
( $FC curl -s -o /dev/null -w 'longa: http_code=%{http_code} time=%{time_total}\n' -H "$HOST_HDR" --max-time 25 $BASE/public > "$EV/03-c08-longa.txt" 2>&1 & )
sleep 2
echo "recriando auth pod durante a conexão longa..." | tee -a "$EV/03-c08.txt"
k -n $GWNS delete pod -l app=p003-authz --wait=true --timeout=60s 2>&1 | sed 's/^/  /' | tee -a "$EV/03-c08.txt"
k -n $GWNS rollout status deploy/p003-authz --timeout=90s 2>&1 | sed 's/^/  /' | tee -a "$EV/03-c08.txt"
sleep 25
echo "== resultado da conexão longa ==" | tee -a "$EV/03-c08.txt"
cat "$EV/03-c08-longa.txt" 2>/dev/null | tee -a "$EV/03-c08.txt"
echo "nota: conexão longa era contra /public (http-echo, NÃO recriado) -> controle de estabilidade." | tee -a "$EV/03-c08.txt"
echo "      para o caso híbrido pod<->VM (C08), o RX da VM (D-S012-13) impede a prova bidirecional." | tee -a "$EV/03-c08.txt"

echo "### [C09] regra stale proposital -> vazamento detectado -> removida -> negativo"
# regra stale: allow de egress para um label que NÃO existe mais (pod removido),
# mas que ainda selecionaria um pod se reaparecesse com o mesmo label + IP.
# Aqui: criar allow para app=p003-stale (inexistente) com toCIDR 10.30.0.0/24,
# criar um pod com esse label, mostrar que o allow CONCEDE (vazamento),
# remover a regra stale, mostrar que o pod fica negado (negativo).
cat <<'EOF' | k apply -f - 2>&1 | sed 's/^/  /' | tee "$EV/03-c09-apply.txt"
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: p003-lc-stale-allow
  namespace: p003-lc
  labels: { study: P003 }
spec:
  endpointSelector:
    matchLabels:
      app: p003-stale
  egress:
    - toCIDR:
        - 10.30.0.0/24
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: p003-stale
  namespace: p003-lc
  labels: { app: p003-stale, study: P003 }
spec:
  replicas: 1
  selector:
    matchLabels: { app: p003-stale }
  template:
    metadata:
      labels: { app: p003-stale, study: P003 }
    spec:
      nodeSelector:
        kubernetes.io/hostname: p003-gw-worker2
      containers:
        - name: probe
          image: curlimages/curl:latest
          imagePullPolicy: IfNotPresent
          command: ["sleep", "infinity"]
          resources:
            requests: { cpu: 10m, memory: 16Mi }
EOF
k -n p003-lc rollout status deploy/p003-stale --timeout=90s 2>&1 | sed 's/^/  /' | tee -a "$EV/03-c09-apply.txt"
sleep 3
PS=$(k -n p003-lc get pod -l app=p003-stale -o jsonpath='{.items[0].metadata.name}')
PS_LOSS=$($FC true; k -n p003-lc exec "$PS" -- ping -c 2 -W 2 10.30.0.1 2>&1 | grep -oE '[0-9]+% packet loss' | grep -oE '^[0-9]+' || echo ERR)
echo "COM regra stale: pod p003-stale ping_loss=$PS_LOSS (esperado 0 = vazamento: allow concede)" | tee "$EV/03-c09.txt"
# remover a regra stale
k -n p003-lc delete cnp p003-lc-stale-allow 2>&1 | sed 's/^/  /' | tee -a "$EV/03-c09.txt"
sleep 3
PS_LOSS2=$(k -n p003-lc exec "$PS" -- ping -c 2 -W 2 10.30.0.1 2>&1 | grep -oE '[0-9]+% packet loss' | grep -oE '^[0-9]+' || echo ERR)
echo "SEM regra stale: pod p003-stale ping_loss=$PS_LOSS2 (esperado 100 = negativo: default-deny)" | tee -a "$EV/03-c09.txt"
# cleanup do pod stale
k -n p003-lc delete deploy p003-stale --wait=true --timeout=60s 2>&1 | sed 's/^/  /' | tee -a "$EV/03-c09.txt"

echo "### C06-C09 completo"
