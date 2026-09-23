#!/usr/bin/env bash
# P003-S012 C3-bis — religar agentes+compute e TESTAR A VM (momento da verdade:
# com cgroupns=host, o rx da VM funciona?)
set -uo pipefail

echo "== [1] religar agentes + nova-compute =="
sudo docker exec p003-os bash -c 'for pat in neutron-openvswitch-agent neutron-dhcp-agent neutron-l3-agent nova-compute; do
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
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-compute --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-cpu.log
echo "  lançados; aguardando 60s"; sleep 60
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1
timeout 40 openstack network agent list -f value -c "Agent Type" -c Alive 2>&1 | sed "s/^/  ag: /"
timeout 40 openstack compute service list -f value -c Binary -c State 2>&1 | grep up | sed "s/^/  nov: /"'
sudo docker exec p003-os bash -c 'ip netns list | sed "s/^/  ns: /"'

echo
echo "== [2] re-plumb cross-netns (veth + IPs) =="
CPID=$(sudo docker inspect -f '{{.State.Pid}}' p003-os)
if ! ip link show veth-ext0 >/dev/null 2>&1; then
  sudo ip link add veth-ext0 type veth peer name veth-ext1 && echo "  veth criado"
fi
if ! sudo docker exec p003-os ip link show veth-ext1 >/dev/null 2>&1; then
  sudo ip link set veth-ext1 netns "$CPID" && echo "  peer movido ao container"
fi
sudo ip link set veth-ext0 master docker0 2>/dev/null; sudo ip link set veth-ext0 up
sudo docker exec p003-os ip link set veth-ext1 up
sudo docker exec p003-os ovs-vsctl --may-exist add-port br-ex veth-ext1
sudo docker exec p003-os ip addr add 10.40.0.2/24 dev br-ex 2>/dev/null || echo "  10.40.0.2 já presente"
sudo ip addr add 10.40.0.250/24 dev docker0 2>/dev/null || echo "  10.40.0.250 já presente"
echo "  br-ex ports: [$(sudo docker exec p003-os ovs-vsctl list-ports br-ex | tr '\n' ' ')]"
echo "  L2: $(ping -c2 -W2 10.40.0.2 >/dev/null 2>&1 && echo host->br-ex OK || echo host->br-ex FAIL)"

echo
echo "== [3] criar VM (teste C3-bis) =="
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

echo
echo "== [4] console DHCP =="
sleep 40
sudo docker exec p003-os bash -c "source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 40 openstack console log show $SID 2>/dev/null | grep -aE 'dhcpcd|lease|IPv4LL|P003' | tail -6" | sed 's/^/  /'

echo
echo "== [5] ping-watch (12x10s) =="
QR=$(sudo docker exec p003-os bash -c 'ip netns list | awk "/qrouter/{print \$1}" | head -1')
OK=0
for i in $(seq 1 12); do
  RC=$(sudo docker exec p003-os bash -c "ip netns exec $QR ping -c1 -W2 $ADDR >/dev/null 2>&1 && echo ok || echo dead")
  echo "  t$((i*10))s: $RC"; [ "$RC" = "ok" ] && OK=$((OK+1))
done
echo "  >>> ok=$OK/12"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "canário k01: $c"
echo "mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
