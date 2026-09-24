#!/usr/bin/env bash
# P003-S013 step 02 — C01/C02/C03 (recriação/reuso de IP, authz por label)
# C01: Pod A recriado, IP diferente -> novo dono autorizado, IP velho sem concessão.
# C02: Pod A recriado, IP igual/UID diferente (churn <=50) -> permissão segue o dono (label).
# C03: IP de A passa a Pod B (label diferente) -> B negado (default-deny, sem allow).
# Evidência: ping (allow) / ping falha + drop cilium (deny). Authz é por LABEL, não IP/UID.
set -uo pipefail

RUN=2026-09-24T1145Z
EV=/opt/poc-k8s-fabric-studies/studies/p003/evidence/P003/S013/$RUN
mkdir -p "$EV"
k() { sudo KUBECONFIG=/root/.kube/p003-gw.config kubectl "$@"; }
NS=p003-lc
DEST=10.30.0.1
HIST="$EV/02-pod-a-history.tsv"   # ts name uid ip

pod_a() {
  local PA
  PA=$(k -n "$NS" get pod -l app=p003-pod-a -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -z "$PA" ] && { echo "NONE - -"; return; }
  echo "$PA $(k -n "$NS" get pod "$PA" -o jsonpath='{.status.podIP}') $(k -n "$NS" get pod "$PA" -o jsonpath='{.metadata.uid}')"
}
ping_loss() { # $1=pod ; imprime "% packet loss" ou "ERR"
  k -n "$NS" exec "$1" -- ping -c 2 -W 2 "$DEST" 2>&1 | grep -oE '[0-9]+% packet loss' | grep -oE '^[0-9]+' || echo ERR
}
record() { # $1=name $2=ip $3=uid $4=nota
  echo "$(date -u +%H:%M:%S) $1 $3 $2 $4" >> "$HIST"
}

echo "### [0] baseline Pod A"
read -r N I U <<<"$(pod_a)"
echo "$(date -u +%H:%M:%S) $N $U $I baseline" | tee "$HIST"
echo "baseline: name=$N ip=$I uid=$U" | tee "$EV/02-baseline.txt"

echo "### [C01] recriar Pod A (1x) — observar IP"
k -n "$NS" delete pod -l app=p003-pod-a --wait=false 2>&1 | sed 's/^/  /' | tee "$EV/02-c01.txt"
k -n "$NS" rollout status deploy/p003-pod-a --timeout=90s 2>&1 | sed 's/^/  /' | tee -a "$EV/02-c01.txt"
read -r N I U <<<"$(pod_a)"
record "$N" "$I" "$U" "C01"
LOSS=$(ping_loss "$N")
echo "C01: name=$N ip=$I uid=$U ping_loss=$LOSS" | tee -a "$EV/02-c01.txt"
if [ "$I" != "$(awk 'NR==2{print $4}' "$HIST")" ]; then
  echo "C01=IP-DIFERENTE (novo IP $I; antigo $(awk 'NR==2{print $4}' "$HIST"))" | tee -a "$EV/02-c01.txt"
else
  echo "C01=IP-IGUAL (ver C02)" | tee -a "$EV/02-c01.txt"
fi

echo "### [C02] churn Pod A (até 50) — procurar reuso de IP com UID novo"
BASE_IP=$(awk 'NR==2{print $4}' "$HIST")
SAME_IP_TRIAL=""
for t in $(seq 1 50); do
  k -n "$NS" delete pod -l app=p003-pod-a --wait=false >/dev/null 2>&1
  k -n "$NS" rollout status deploy/p003-pod-a --timeout=90s >/dev/null 2>&1
  read -r N I U <<<"$(pod_a)"
  record "$N" "$I" "$U" "C02-t$t"
  if [ "$I" = "$BASE_IP" ]; then
    LOSS=$(ping_loss "$N")
    SAME_IP_TRIAL="t$t name=$N ip=$I uid=$U ping_loss=$LOSS"
    echo "C02 t$t: REUSO-IP ip=$I uid=$U (base uid=$(awk 'NR==2{print $3}' "$HIST")) ping_loss=$LOSS" | tee -a "$EV/02-c02.txt"
    break
  fi
  echo "C02 t$t: ip=$I uid=$U (sem reuso)" | tee -a "$EV/02-c02.txt"
done
[ -z "$SAME_IP_TRIAL" ] && echo "C02: sem reuso de IP em 50 recriações (IPAM não reaproveitou $BASE_IP)" | tee -a "$EV/02-c02.txt"

echo "### [C03] Pod B (label diferente) — herda IP de A? é negado?"
cat <<'EOF' | k apply -f - 2>&1 | sed 's/^/  /' | tee "$EV/02-c03-apply.txt"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: p003-pod-b
  namespace: p003-lc
  labels: { app: p003-pod-b, study: P003 }
spec:
  replicas: 1
  selector:
    matchLabels: { app: p003-pod-b }
  template:
    metadata:
      labels: { app: p003-pod-b, study: P003 }
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
k -n "$NS" rollout status deploy/p003-pod-b --timeout=90s 2>&1 | sed 's/^/  /' | tee -a "$EV/02-c03-apply.txt"
PB=$(k -n "$NS" get pod -l app=p003-pod-b -o jsonpath='{.items[0].metadata.name}')
PB_IP=$(k -n "$NS" get pod "$PB" -o jsonpath='{.status.podIP}')
PB_UID=$(k -n "$NS" get pod "$PB" -o jsonpath='{.metadata.uid}')
echo "$(date -u +%H:%M:%S) $PB $PB_UID $PB_IP C03-pod-b" >> "$HIST"
# o IP do B já foi de algum A?
PREV=$(awk -v ip="$PB_IP" '$4==ip && $5!~/C03/ {print $2"("$5")"}' "$HIST" | head -1)
PB_LOSS=$(ping_loss "$PB")
{
  echo "pod-b: name=$PB ip=$PB_IP uid=$PB_UID"
  echo "ip-ja-foi-de-A: ${PREV:-nao}"
  echo "ping_loss=$PB_LOSS (esperado 100 = negado pelo default-deny)"
} | tee "$EV/02-c03-pod-b.txt"
# evidência de drop no cilium (janela curta durante ping do B)
( sudo /usr/bin/docker exec p003-gw-worker2 cilium monitor --type drop --type policy-verdict 2>&1 | grep -m3 -E "10\.30\.0\.1|policy" > "$EV/02-c03-cilium-drop.txt" & )
k -n "$NS" exec "$PB" -- ping -c 2 -W 2 "$DEST" >/dev/null 2>&1
sleep 3
echo "== drop/verdict cilium (pod-b) ==" | tee -a "$EV/02-c03-pod-b.txt"
cat "$EV/02-c03-cilium-drop.txt" 2>/dev/null | tee -a "$EV/02-c03-pod-b.txt"

echo "### [resumo] histórico de IPs/UIDs"
cat "$HIST" | tee "$EV/02-history.txt"
echo "### C01-C03 completo"
