#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.4 fechamento: gateway da external aponta para o HOST
# (10.40.0.250, o upstream real do caminho cross-netns) + rotas estáticas do
# router para PodCIDR e kind. Nada de SNAT (disable-snat mantido).
set -uo pipefail

echo "== [1] gateway da ext-subnet -> 10.40.0.250 =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack subnet set ext-subnet --gateway 10.40.0.250 2>&1; echo "  rc=$?"; timeout 30 openstack subnet show ext-subnet -f value -c gateway_ip | sed "s/^/  gateway=/""'

echo
echo "== [2] rotas estáticas do r-a (PodCIDR + kind via host) =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 60 openstack router set r-a \
  --route destination=10.245.0.0/16,gateway_ip=10.40.0.250 \
  --route destination=172.19.0.0/16,gateway_ip=10.40.0.250 2>&1; echo "  rc=$?"'
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack router show r-a -f value -c routes' | sed 's/^/  routes: /'

echo
echo "== [3] tabela de rotas do qrouter (netns) =="
sudo docker exec p003-os bash -c 'NS=$(ip netns list | awk "/qrouter/{print \$1}"); ip -n "$NS" route | sed "s/^/  /"'

echo
echo "== [4] L3 proofs finais C1.4 =="
echo "  [4a] host -> router (ICMP):"
ping -c3 -W2 10.40.0.181 2>&1 | tail -2 | sed 's/^/    /'
echo "  [4b] worker2 -> router (TCP rc=7 => ida-e-volta L3):"
sudo docker exec p003-gw-worker2 bash -c 'curl -s --max-time 4 telnet://10.40.0.181:1 >/dev/null 2>&1; echo "    curl rc=$?"'
echo "  [4c] host -> router a partir da FABRIC client (TCP rc=7):"
sudo docker exec clab-p003-gw-fabric-client bash -c 'curl -s --max-time 4 telnet://10.40.0.181:1 >/dev/null 2>&1; echo "    curl rc=$?"' 2>/dev/null || echo "    (client sem curl — pulando)"

echo
echo "== [5] pós: lab intacto =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
