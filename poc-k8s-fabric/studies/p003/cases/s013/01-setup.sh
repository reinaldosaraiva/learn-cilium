#!/usr/bin/env bash
# P003-S013 step 01 — setup fixtures (gate rebaixado, Emenda S013-A1)
# Cria: ns p003-lc + CNPs (default-deny egress + allow pod-a), Pod A,
# fixture auth (deploy+svc+3 routes), rotas de teste 10.30.0.0/24
# (worker2 via 172.19.0.1; host via 10.40.0.181 dev docker0 — mesmas de S012).
# Baseline: IP/UID/identity do Pod A, probe L3 (ping 10.30.0.1), probes auth.
set -uo pipefail

RUN=2026-09-24T1145Z
DIR=/opt/poc-k8s-fabric-studies/studies/p003/cases/s013
EV=/opt/poc-k8s-fabric-studies/studies/p003/evidence/P003/S013/$RUN
mkdir -p "$EV"
k() { sudo KUBECONFIG=/root/.kube/p003-gw.config kubectl "$@"; }

echo "### [0] revalidar UIDs (abort se mudou)"
K01_UID=$(sudo KUBECONFIG=/root/.kube/k01-rebuild.config kubectl get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null)
SBX_UID=$(k get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null)
{ echo "k01=$K01_UID"; echo "sandbox=$SBX_UID"; } | tee "$EV/01-uids.txt"
[ "$K01_UID" = "45cb3818-248b-4dd2-b65c-5909bde08fe6" ] || { echo "ABORT: k01 UID mudou"; exit 1; }
[ "$SBX_UID" = "8216d179-9eed-4dc1-ab9c-97c0c6612b32" ] || { echo "ABORT: sandbox UID mudou"; exit 1; }
echo "  UIDs OK"

echo "### [1] ns + CNPs + Pod A + auth"
k apply -f "$DIR/01a-ns-cnps.yaml" 2>&1 | sed 's/^/  /' | tee "$EV/01-apply-ns-cnps.txt"
k apply -f "$DIR/01b-pod-a.yaml" 2>&1 | sed 's/^/  /' | tee -a "$EV/01-apply-ns-cnps.txt"
k apply -f "$DIR/01c-auth.yaml" 2>&1 | sed 's/^/  /' | tee "$EV/01-apply-auth.txt"
k apply -f "$DIR/01d-auth-routes.yaml" 2>&1 | sed 's/^/  /' | tee -a "$EV/01-apply-auth.txt"

echo "### [2] rotas de teste 10.30.0.0/24 (reverter no rollback)"
{
sudo /usr/bin/docker exec p003-gw-worker2 ip route replace 10.30.0.0/24 via 172.19.0.1 dev eth0
echo "worker2: $(sudo /usr/bin/docker exec p003-gw-worker2 ip route show 10.30.0.0/24)"
sudo ip route replace 10.30.0.0/24 via 10.40.0.181 dev docker0
echo "host: $(ip route show 10.30.0.0/24)"
} | tee "$EV/01-rotas.txt"

echo "### [3] aguardar readiness (Pod A + auth)"
k -n p003-lc rollout status deploy/p003-pod-a --timeout=120s 2>&1 | sed 's/^/  /' | tee "$EV/01-readiness.txt"
k -n p003-gateway rollout status deploy/p003-authz --timeout=120s 2>&1 | sed 's/^/  /' | tee -a "$EV/01-readiness.txt"

echo "### [4] baseline Pod A (livro de ownership)"
PA=$(k -n p003-lc get pod -l app=p003-pod-a -o jsonpath='{.items[0].metadata.name}')
{
echo "pod=$PA"
echo "uid=$(k -n p003-lc get pod $PA -o jsonpath='{.metadata.uid}')"
echo "ip=$(k -n p003-lc get pod $PA -o jsonpath='{.status.podIP}')"
echo "node=$(k -n p003-lc get pod $PA -o jsonpath='{.spec.nodeName}')"
echo "created=$(k -n p003-lc get pod $PA -o jsonpath='{.metadata.creationTimestamp}')"
echo "== cilium identity =="
k get ciliumidentities -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for it in d['items']:
    l=it.get('metadata',{}).get('labels',{})
    if l.get('app')=='p003-pod-a' or 'p003-pod-a' in str(l):
        print('id=%s labels=%s' % (it['metadata']['name'], l))
" 2>/dev/null || echo "  (ciliumidentities indisponível)"
} | tee "$EV/01-baseline-pod-a.txt"

echo "### [5] probe L3: Pod A -> 10.30.0.1 (qrouter net-a)"
{
for i in 1 2 3; do
  k -n p003-lc exec $PA -- ping -c 3 -W 2 10.30.0.1 2>&1 | tail -2 | sed 's/^/  try'$i': /'
done
} | tee "$EV/01-probe-l3-pod-a.txt"

echo "### [6] probes auth (baseline C06): allow/deny/ausente via Gateway"
FC="sudo /usr/bin/docker exec clab-p003-gw-fabric-client"
{
echo "allow:   $($FC curl -s -o /dev/null -w '%{http_code}' -H 'Host: echo.p003.study' -H 'X-Lab-Decision: allow' --max-time 8 http://10.30.1.11:30676/protected-http)"
echo "deny:    $($FC curl -s -o /dev/null -w '%{http_code}' -H 'Host: echo.p003.study' -H 'X-Lab-Decision: deny' --max-time 8 http://10.30.1.11:30676/protected-http)"
echo "ausente: $($FC curl -s -o /dev/null -w '%{http_code}' -H 'Host: echo.p003.study' --max-time 8 http://10.30.1.11:30676/protected-http)"
echo "public:  $($FC curl -s -o /dev/null -w '%{http_code}' -H 'Host: echo.p003.study' --max-time 8 http://10.30.1.11:30676/public)"
echo "auth pod: $(k -n p003-gateway get pod -l app=p003-authz -o jsonpath='{.items[0].metadata.name} ip={.items[0].status.podIP} uid={.items[0].metadata.uid}')"
} | tee "$EV/01-probes-auth-baseline.txt"

echo "### [7] plano de controle VM (sem VM viva — limitação de memória)"
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1
echo "== sg-a rules =="; timeout 40 openstack security group rule list --secgroup sg-a 2>&1
echo "== router r-a =="; timeout 40 openstack router show r-a -c name -c external_gateway_info -c routes 2>&1
echo "== subnet-a =="; timeout 40 openstack subnet show subnet-a -c cidr -c gateway_ip -c ip_allocation 2>&1
echo "== servers =="; timeout 40 openstack server list 2>&1' 2>&1 | tee "$EV/01-vm-control-plane.txt"

echo "### setup completo"
