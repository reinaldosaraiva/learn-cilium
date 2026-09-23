#!/usr/bin/env bash
# P003-S012 rodada 2 — fix: eliminar neutron-server DUPLICADO (pid 5732, do
# relight de S011, sem router plugin) que dividia as filas rabbit com o server
# novo (12573) e fazia os RPCs dos agentes alternarem saudável/doente ->
# report_state timeout -> agentes nunca registravam. Restart dos agentes para
# zerar timeouts inflacionados (q-l3 chegou a 480s).
set -uo pipefail

echo "== [1] matar o master antigo 5732 + seus workers 5734-5737 (PIDs exatos) =="
for p in 5732 5734 5735 5736 5737; do
  sudo docker exec p003-os kill -9 "$p" 2>/dev/null && echo "  killed $p"
done
sleep 3
echo "  --- restantes:"
sudo docker exec p003-os bash -c 'ps -eo pid,etime,args | grep -i "neutron-serveruwsgi" | grep -v grep | cut -c1-70 | sed "s/^/    /"'

echo
echo "== [2] restart limpo dos 3 agentes (kill por pid + relançar) =="
for pat in neutron-openvswitch-agent neutron-dhcp-agent neutron-l3-agent; do
  PIDS=$(sudo docker exec p003-os bash -c "ps -eo pid,args | grep \"[m]aster process.*$pat\" | awk '{print \$1}'")
  WPIDS=$(sudo docker exec p003-os bash -c "ps -eo pid,args | grep \"$pat\" | grep -E \"ServiceWrapper|venv/bin/$pat\" | awk '{print \$1}'")
  for p in $PIDS $WPIDS; do sudo docker exec p003-os kill -9 "$p" 2>/dev/null && echo "  killed $pat pid $p"; done
done
sleep 2
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/neutron-openvswitch-agent \
  --config-file /etc/neutron/neutron.conf \
  --config-file /etc/neutron/plugins/ml2/ml2_conf.ini \
  --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini \
  --log-file /opt/stack/logs/q-agt.log
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/neutron-dhcp-agent \
  --config-file /etc/neutron/neutron.conf \
  --config-file /etc/neutron/dhcp_agent.ini \
  --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini \
  --log-file /opt/stack/logs/q-dhcp.log
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/neutron-l3-agent \
  --config-file /etc/neutron/neutron.conf \
  --config-file /etc/neutron/l3_agent.ini \
  --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini \
  --log-file /opt/stack/logs/q-l3.log
echo "  3 agentes relançados; aguardando 50s"; sleep 50

echo
echo "== [3] aceite: agent list (esperado 3 alive) =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack network agent list 2>&1' | sed 's/^/  /'

echo
echo "== [4] wiring do r-a (qrouter ns + qg- port no br-ex) =="
sudo docker exec p003-os ip netns list | sed 's/^/  netns: /'
sudo docker exec p003-os ovs-vsctl list-ports br-ex | sed 's/^/  br-ex port: /'
echo "  --- ARP/IP do qrouter:"
sudo docker exec p003-os bash -c 'for ns in $(ip netns list | awk "{print \$1}" | grep qrouter); do echo "    ns=$ns"; ip -n "$ns" -o addr show | grep -v " lo " | sed "s/^/      /"; done'

echo
echo "== [5] L3 proofs (alvo correto: 10.40.0.181 = IP externo do router) =="
echo "  [5a] host -> 10.40.0.181"
ping -c3 -W2 10.40.0.181 2>&1 | tail -2 | sed 's/^/    /'
echo "  [5b] container 10.40.0.2 -> 10.40.0.181"
sudo docker exec p003-os ping -c3 -W2 10.40.0.181 2>&1 | tail -2 | sed 's/^/    /'
echo "  [5c] worker2 -> 10.40.0.181 (TCP rc=7 => L3 OK)"
sudo docker exec p003-gw-worker2 bash -c 'curl -s --max-time 4 telnet://10.40.0.181:1 >/dev/null 2>&1; echo "    curl rc=$?"'

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
