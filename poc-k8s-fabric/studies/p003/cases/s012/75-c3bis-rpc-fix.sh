#!/usr/bin/env bash
# P003-S012 C3-bis — reviver a cadeia RPC: rabbit real, neutron-rpc-server,
# consumidores q-plugin, então agentes.
set -uo pipefail

echo "== [1] rabbit real =="
sudo docker exec p003-os bash -c 'pgrep -xc beam.smp; timeout 25 rabbitmqctl status >/dev/null 2>&1 && echo "  rabbit OK" || { echo "  rabbit morto — restart"; service rabbitmq-server restart </dev/null >/tmp/rr.log 2>&1; for i in $(seq 1 40); do timeout 20 rabbitmqctl status >/dev/null 2>&1 && { echo "  rabbit UP (${i}x2s)"; break; }; sleep 2; done; }'

echo
echo "== [2] neutron-rpc-server vivo? =="
sudo docker exec p003-os bash -c 'pgrep -fc neutron-rpc-server; tail -4 /opt/stack/logs/q-rpc.log 2>/dev/null | grep -avE "DEBUG oslo|dbcounter" | cut -c1-150'

echo
echo "== [3] restart rpc-server + nova workers =="
sudo docker exec p003-os bash -c 'PIDS=$(ps -eo pid,args | grep "[n]eutron-rpc-server" | awk "{print \$1}")
for p in $PIDS; do kill -9 $p 2>/dev/null; done
sleep 2
sudo -u stack bash -c "nohup /opt/stack/data/venv/bin/neutron-rpc-server --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini >/opt/stack/logs/q-rpc.log 2>&1 &" </dev/null
for pat in nova-conductor nova-scheduler nova-compute; do
  PIDS=$(ps -eo pid,args | grep "$pat" | grep -vE "grep|uwsgi" | awk "{print \$1}")
  for p in $PIDS; do kill -9 $p 2>/dev/null; done
done
sleep 2; echo "  rpc + nova workers: relançando"'
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-conductor --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-cond.log
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-scheduler --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-sch.log
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-compute --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-cpu.log
echo "  aguardando 45s"; sleep 45
sudo docker exec p003-os bash -c 'timeout 25 rabbitmqctl list_queues name consumers 2>/dev/null | grep -E "q-plugin|nova-" | head -5 | sed "s/^/  q: /"'

echo
echo "== [4] restart agentes (timeouts inflados) =="
sudo docker exec p003-os bash -c 'for pat in neutron-openvswitch-agent neutron-dhcp-agent neutron-l3-agent; do
  PIDS=$(ps -eo pid,args | grep "$pat" | grep -vE "grep|uwsgi" | awk "{print \$1}")
  for p in $PIDS; do kill -9 $p 2>/dev/null; done
done; sleep 2'
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/neutron-openvswitch-agent \
  --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini \
  --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini --log-file /opt/stack/logs/q-agt.log
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/neutron-dhcp-agent \
  --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/dhcp_agent.ini \
  --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini --log-file /opt/stack/logs/q-dhcp.log
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/neutron-l3-agent \
  --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/l3_agent.ini \
  --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini --log-file /opt/stack/logs/q-l3.log
echo "  aguardando 55s"; sleep 55
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1
timeout 40 openstack network agent list -f value -c "Agent Type" -c Alive 2>&1 | sed "s/^/  ag: /"
timeout 40 openstack compute service list -f value -c Binary -c State 2>&1 | grep up | sed "s/^/  nov: /"'
sudo docker exec p003-os bash -c 'ip netns list 2>/dev/null | sed "s/^/  ns: /"'
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "canário k01: $c"
echo "mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
