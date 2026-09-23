#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.4 conclusão: gateway do router (sem pin de IP — o 400
# anterior foi pinned fixed-ip == gateway_ip; sem --fixed-ip o router assume o
# gateway 10.40.0.1), provas L3, agentes, e higiene do neutron-server.
set -uo pipefail

echo "== [1] r-a: external gateway sem SNAT (sem pin) =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 60 openstack router set r-a --external-gateway ext-net --disable-snat 2>&1; echo "  rc=$?"'
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack router show r-a 2>&1' | grep -E "external_gateway_info|snat|network_id|status" | sed 's/^/  /'

echo
echo "== [2] wiring: portas br-ex + netns do router =="
sudo docker exec p003-os ovs-vsctl list-ports br-ex | sed 's/^/  port: /'
sudo docker exec p003-os ip netns list | sed 's/^/  netns: /'
sudo docker exec p003-os bash -c 'ip -n qrouter-* -o addr 2>/dev/null || for ns in $(ip netns list | awk "{print \$1}"); do echo "  --- $ns"; ip -n "$ns" -o addr | grep -v "lo " | sed "s/^/    /"; done'

echo
echo "== [3] L3 proofs =="
echo "  [3a] host -> 10.40.0.1 (ICMP)"
ping -c3 -W2 10.40.0.1 2>&1 | tail -2 | sed 's/^/    /'
echo "  [3b] container (10.40.0.2) -> 10.40.0.1 (ICMP)"
sudo docker exec p003-os ping -c3 -W2 10.40.0.1 2>&1 | tail -2 | sed 's/^/    /'
echo "  [3c] worker2 -> 10.40.0.1 (TCP: rc=7 refused => L3 ida-e-volta OK)"
sudo docker exec p003-gw-worker2 bash -c 'curl -s --max-time 4 telnet://10.40.0.1:1 >/dev/null 2>&1; echo "    curl rc=$?"'

echo
echo "== [4] agentes registrados =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack network agent list 2>&1' | sed 's/^/  /'

echo
echo "== [5] higiene: processos neutron-server (esperado 1 master uwsgi) =="
sudo docker exec p003-os bash -c 'ps -eo pid,user,etime,args | grep -E "uwsgi.*(neutron|keystone)" | grep -v grep | cut -c1-110 | sed "s/^/  /"'
sudo docker exec p003-os bash -c 'tail -3 /tmp/neutron-restart.log 2>/dev/null | cut -c1-140 | sed "s/^/  newlog: /"'

echo
echo "== [6] pós: lab intacto =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
for b in docker0 br-b56f3de1d858 br-97b5ec9007c2 br-b03e3d58a257; do
  printf "  %-20s ports=%s\n" "$b" "$(ip -o link show master "$b" 2>/dev/null | wc -l)"
done
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
