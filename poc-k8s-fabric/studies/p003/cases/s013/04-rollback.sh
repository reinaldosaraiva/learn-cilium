#!/usr/bin/env bash
# P003-S013 step 04 — rollback (remover recursos da sessão, restaurar estado)
# Remove: ns p003-lc (pods+CNPs), fixture auth (deploy+svc), HTTPRoutes da sessão,
# rotas de teste (worker2+host), regra ACCEPT D-S013-1, neighbor PERMANENT.
# NÃO remove: p003-http (S005, pré-existente), k01, testbed p003-os.
set -uo pipefail

RUN=2026-09-24T1145Z
EV=/opt/poc-k8s-fabric-studies/studies/p003/evidence/P003/S013/$RUN
mkdir -p "$EV"
k() { sudo KUBECONFIG=/root/.kube/p003-gw.config kubectl "$@"; }

echo "### [0] revalidar UIDs (abort se mudou)"
K01_UID=$(sudo KUBECONFIG=/root/.kube/k01-rebuild.config kubectl get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null)
SBX_UID=$(k get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null)
{ echo "k01=$K01_UID"; echo "sandbox=$SBX_UID"; } | tee "$EV/04-uids.txt"
[ "$K01_UID" = "45cb3818-248b-4dd2-b65c-5909bde08fe6" ] || { echo "ABORT: k01 UID mudou"; exit 1; }
[ "$SBX_UID" = "8216d179-9eed-4dc1-ab9c-97c0c6612b32" ] || { echo "ABORT: sandbox UID mudou"; exit 1; }
echo "  UIDs OK"

echo "### [1] remover regra ACCEPT D-S013-1 + LOG rules residuais"
sudo iptables -D FORWARD -i br-b56f3de1d858 -o docker0 -d 10.30.0.0/24 -j ACCEPT 2>&1 | sed 's/^/  /' | tee "$EV/04-iptables.txt"
# remover qualquer LOG rule residual de diagnostico
while sudo iptables -S FORWARD 2>/dev/null | grep -q "LOG --log-prefix"; do
  RULE=$(sudo iptables -S FORWARD | grep "LOG --log-prefix" | head -1 | sed 's/^-A FORWARD //')
  sudo iptables -D FORWARD $RULE 2>&1 | sed 's/^/  /' | tee -a "$EV/04-iptables.txt"
done
echo "FORWARD final: $(sudo iptables -S FORWARD | tr '\n' ' ')" | tee -a "$EV/04-iptables.txt"

echo "### [2] remover ns p003-lc (pods + CNPs)"
k delete ns p003-lc --wait=true --timeout=120s 2>&1 | sed 's/^/  /' | tee "$EV/04-ns-lc.txt"

echo "### [3] remover fixture auth (deploy + svc) da sessão"
k -n p003-gateway delete deploy p003-authz --wait=true --timeout=60s 2>&1 | sed 's/^/  /' | tee "$EV/04-auth.txt"
k -n p003-gateway delete svc p003-authz --wait=true --timeout=60s 2>&1 | sed 's/^/  /' | tee -a "$EV/04-auth.txt"

echo "### [4] remover HTTPRoutes da sessão (NÃO p003-http)"
for r in p003-protected-http p003-protected-grpc p003-public; do
  k -n p003-gateway delete httproute $r 2>&1 | sed 's/^/  /' | tee -a "$EV/04-routes.txt"
done
echo "rotas restantes: $(k -n p003-gateway get httproute -o jsonpath='{.items[*].metadata.name}' | tr '\n' ' ')" | tee -a "$EV/04-routes.txt"

echo "### [5] reverter rotas de teste 10.30.0.0/24 (worker2 + host)"
sudo /usr/bin/docker exec p003-gw-worker2 ip route del 10.30.0.0/24 2>&1 | sed 's/^/  /' | tee "$EV/04-rotas.txt"
sudo ip route del 10.30.0.0/24 2>&1 | sed 's/^/  /' | tee -a "$EV/04-rotas.txt"
echo "worker2: $(sudo /usr/bin/docker exec p003-gw-worker2 ip route show 10.30.0.0/24 2>&1)" | tee -a "$EV/04-rotas.txt"
echo "host: $(ip route show 10.30.0.0/24 2>&1)" | tee -a "$EV/04-rotas.txt"

echo "### [6] remover neighbor PERMANENT 10.40.0.181 (artefato de teste)"
sudo ip neigh del 10.40.0.181 dev docker0 2>&1 | sed 's/^/  /' | tee "$EV/04-neigh.txt"
echo "neigh 10.40.0.181: $(ip neigh show 10.40.0.181 2>&1)" | tee -a "$EV/04-neigh.txt"

echo "### [7] verificação final"
{
echo "== ns p003-lc (deve estar ausente) =="; k get ns p003-lc 2>&1
echo "== auth (deve estar ausente) =="; k -n p003-gateway get deploy,svc 2>&1 | grep -E "p003-authz|NAME" || echo "  (ausente)"
echo "== HTTPRoutes (só p003-http deve restar) =="; k -n p003-gateway get httproute 2>&1
echo "== Gateway status =="; k -n p003-gateway get gateway p003-main -o jsonpath='{.status.conditions[*].type}={.status.conditions[*].status}' 2>&1; echo ""
echo "== canário NodePort :80 (http-echo via p003-http) =="
sudo /usr/bin/docker exec clab-p003-gw-fabric-client curl -s -o /dev/null -w 'public=%{http_code}\n' -H 'Host: echo.p003.study' --max-time 8 http://10.30.1.11:30676/public 2>&1
} | tee "$EV/04-verify.txt"

echo "### rollback completo"
