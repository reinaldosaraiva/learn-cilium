#!/usr/bin/env bash
# P003-S012 rodada 2 — reprovisionamento da rede external: o gw do r-a foi
# setado antes dos agentes registrarem (sem RPC) -> port qg- ficou em estado
# não-provisionado (tag 4095, flows drop no patch). Re-trigger: desligar e
# religar o external gateway com agentes saudáveis.
set -uo pipefail

echo "== [1] o que o q-agt decidiu sobre a porta qg-? =="
sudo docker exec p003-os bash -c 'grep -a "fc60cc23" /opt/stack/logs/q-agt.log 2>/dev/null | tail -6 | cut -c1-170 | sed "s/^/  /" || echo "  (nada no log)"'

echo
echo "== [2] re-trigger: gateway off -> on =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack router set r-a --no-snat --external-gateway none 2>&1; echo "  off rc=$?"'
sleep 5
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 60 openstack router set r-a --external-gateway ext-net --disable-snat 2>&1; echo "  on rc=$?"'
echo "  aguardando 20s (wiring + flows)"; sleep 20
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack router show r-a -f value -c external_gateway_info' | sed 's/^/  gw: /'

echo
echo "== [3] estado br-int (tag do qg- e flows do patch) =="
sudo docker exec p003-os ovs-vsctl show | grep -A4 'qg-\|int-br-ex' | sed 's/^/  /'
sudo docker exec p003-os bash -c 'ovs-ofctl dump-flows br-int 2>/dev/null | grep -E "in_port=1 |dl_vlan=" | head -6 | cut -c1-150 | sed "s/^/    /"'

echo
echo "== [4] L3 proofs =="
echo "  [4a] host -> router:"
ping -c3 -W2 10.40.0.181 2>&1 | tail -2 | sed 's/^/    /'
echo "  [4b] container -> router:"
sudo docker exec p003-os ping -c3 -W2 10.40.0.181 2>&1 | tail -2 | sed 's/^/    /'
echo "  [4c] worker2 -> router (TCP rc=7 => L3 OK):"
sudo docker exec p003-gw-worker2 bash -c 'curl -s --max-time 4 telnet://10.40.0.181:1 >/dev/null 2>&1; echo "    curl rc=$?"'

echo
echo "== [5] pós: lab intacto =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
