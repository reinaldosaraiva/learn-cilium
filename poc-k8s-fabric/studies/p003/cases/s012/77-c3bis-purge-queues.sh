#!/usr/bin/env bash
# P003-S012 C3-bis — purgar filas neutron com backlog antigo (mnesia do rabbit
# sobreviveu ao commit), restart agentes, verificar alive, testar VM.
set -uo pipefail

echo "== [1] profundidade das filas =="
sudo docker exec p003-os bash -c 'timeout 60 rabbitmqctl list_queues name messages 2>/dev/null | grep -E "^(q-plugin|dhcp_agent|l3_agent|q-agent)" | head -8 | sed "s/^/  /"'

echo
echo "== [2] purge =="
sudo docker exec p003-os bash -c 'for q in q-plugin q-plugin.aaa1593bb5e1 dhcp_agent dhcp_agent.aaa1593bb5e1 l3_agent l3_agent.aaa1593bb5e1; do
  timeout 20 rabbitmqctl purge_queue $q >/dev/null 2>&1 && echo "  purge $q ok"
done'

echo
echo "== [3] restart agentes =="
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
echo "  aguardando 60s"; sleep 60
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1
timeout 40 openstack network agent list -f value -c "Agent Type" -c Alive 2>&1 | sed "s/^/  ag: /"'
sudo docker exec p003-os bash -c 'ip netns list 2>/dev/null | sed "s/^/  ns: /"'

echo
echo "== [4] se 3 alive: criar VM =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1
for id in $(openstack server list -f value -c ID 2>/dev/null); do timeout 60 openstack server delete $id --wait >/dev/null 2>&1 || timeout 20 openstack server delete $id --force >/dev/null 2>&1; done
for d in $(timeout 20 virsh list --all --name 2>/dev/null); do timeout 15 virsh destroy $d >/dev/null 2>&1; timeout 10 virsh undefine $d >/dev/null 2>&1; done
sleep 2
timeout 540 openstack server create vm-a --image cirros-0.6.0 --flavor m1.p003 \
  --network net-a --security-group sg-a --config-drive True --user-data /opt/stack/vm-a-init.sh --wait >/dev/null 2>&1
echo "  rc=$?"'
SID=$(sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && openstack server list -f value -c ID 2>/dev/null | head -1')
ADDR=$(sudo docker exec p003-os bash -c "source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && openstack server show $SID -f value -c addresses" | grep -oE '10\.30\.0\.[0-9]+')
echo "  id=$SID ip=${ADDR:-?}"
sleep 40
sudo docker exec p003-os bash -c "source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 40 openstack console log show $SID 2>/dev/null | grep -aE 'dhcpcd|lease|IPv4LL|login' | tail -5" | sed 's/^/  cons: /'
QR=$(sudo docker exec p003-os bash -c 'ip netns list | awk "/qrouter/{print \$1}" | head -1')
if [ -n "$QR" ] && [ -n "$ADDR" ]; then
  OK=0
  for i in $(seq 1 12); do
    RC=$(sudo docker exec p003-os bash -c "ip netns exec $QR ping -c1 -W2 $ADDR >/dev/null 2>&1 && echo ok || echo dead")
    echo "  t$((i*10))s: $RC"; [ "$RC" = "ok" ] && OK=$((OK+1))
  done
  echo "  >>> ok=$OK/12"
fi
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "canário k01: $c"
echo "mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
