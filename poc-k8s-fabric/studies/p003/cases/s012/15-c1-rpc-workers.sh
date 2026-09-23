#!/usr/bin/env bash
# P003-S012 rodada 2 — fix RPC: o neutron-server uwsgi (bring-up manual de S011)
# não sobe workers RPC — não há consumidor na fila q-plugin; todos os
# report_state/RPC dos agentes dão MessagingTimeout (API REST funciona, RPC não;
# S011 só verificou API). Solução determinística: neutron-server standalone
# clássico do DevStack (bind :9696 + rpc_workers), coexistindo com o uwsgi que
# só serve a API via apache. Sem disputa de filas (uwsgi não consome RPC).
set -uo pipefail

echo "== [1] diagnóstico rápido (read-only) =="
sudo docker exec p003-os bash -c 'echo "--- uwsgi ini:"; cat /etc/neutron/neutron-api-uwsgi.ini | grep -vE "^\s*(#|$)" | head -15; echo "--- workers em neutron.conf:"; grep -nE "^(api_workers|rpc_workers)" /etc/neutron/neutron.conf || echo "  (não setados)"; echo "--- porta 9696:"; ss -ltn 2>/dev/null | grep 9696 || echo "  9696 livre"'
echo "  --- filas com consumidores (todas):"
sudo docker exec p003-os bash -c 'timeout 25 rabbitmqctl list_queues name consumers 2>/dev/null | grep -v " 0$" | head -20' | sed 's/^/  /'

echo
echo "== [2] lançar neutron-server standalone (stack, nohup, log) =="
sudo docker exec p003-os bash -c 'sudo -u stack bash -c "nohup /opt/stack/data/venv/bin/neutron-server --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini >/opt/stack/logs/q-svc-standalone.log 2>&1 &" </dev/null'
echo "  aguardando 25s"; sleep 25
sudo docker exec p003-os bash -c 'ps -eo pid,user,etime,args | grep -E "[n]eutron-server --config" | cut -c1-100 | sed "s/^/  proc: /"'
sudo docker exec p003-os bash -c 'ss -ltn 2>/dev/null | grep 9696 | sed "s/^/  bind: /"'
sudo docker exec p003-os bash -c 'tail -5 /opt/stack/logs/q-svc-standalone.log | cut -c1-150 | sed "s/^/  log: /"'

echo
echo "== [3] fila q-plugin agora tem consumidor? =="
sudo docker exec p003-os bash -c 'timeout 25 rabbitmqctl list_queues name consumers 2>/dev/null | grep -E "q-plugin|q-agent|l3_agent"' | sed 's/^/  /'

echo
echo "== [4] restart dos agentes (zera timeouts inflacionados pós-consumidor) =="
for pat in neutron-openvswitch-agent neutron-dhcp-agent neutron-l3-agent; do
  PIDS=$(sudo docker exec p003-os bash -c "ps -eo pid,args | grep \"$pat\" | grep -vE \"grep|uwsgi\" | awk '{print \$1}'")
  for p in $PIDS; do sudo docker exec p003-os kill -9 "$p" 2>/dev/null && echo "  killed $pat $p"; done
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
echo "  agentes relançados; aguardando 60s"; sleep 60

echo
echo "== [5] aceite: agent list =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack network agent list 2>&1' | sed 's/^/  /'

echo
echo "== [6] wiring do r-a =="
sudo docker exec p003-os ip netns list | sed 's/^/  netns: /'
sudo docker exec p003-os ovs-vsctl list-ports br-ex | sed 's/^/  br-ex port: /'

echo
echo "== [7] L3 proofs (10.40.0.181) =="
echo "  [7a] host:"
ping -c3 -W2 10.40.0.181 2>&1 | tail -2 | sed 's/^/    /'
echo "  [7b] container:"
sudo docker exec p003-os ping -c3 -W2 10.40.0.181 2>&1 | tail -2 | sed 's/^/    /'
echo "  [7c] worker2 (TCP rc=7 => L3 OK):"
sudo docker exec p003-gw-worker2 bash -c 'curl -s --max-time 4 telnet://10.40.0.181:1 >/dev/null 2>&1; echo "    curl rc=$?"'

echo
echo "== [8] pós: lab intacto =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
for b in docker0 br-b56f3de1d858 br-97b5ec9007c2 br-b03e3d58a257; do
  printf "  %-20s ports=%s\n" "$b" "$(ip -o link show master "$b" 2>/dev/null | wc -l)"
done
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
