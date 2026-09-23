#!/usr/bin/env bash
# P003-S012 C3-bis — FINAL: agentes alive + VM + ping-watch (cgroupns=host).
set -uo pipefail
sleep 55
echo "== [1] agentes =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1
timeout 40 openstack network agent list -f value -c "Agent Type" -c Alive 2>&1 | sed "s/^/  ag: /"'
sudo docker exec p003-os bash -c 'ip netns list 2>/dev/null | sed "s/^/  ns: /"'

echo
echo "== [2] VM =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1
for id in $(openstack server list -f value -c ID 2>/dev/null); do timeout 60 openstack server delete $id --wait >/dev/null 2>&1 || timeout 20 openstack server delete $id --force >/dev/null 2>&1; done
for d in $(timeout 20 virsh list --all --name 2>/dev/null); do timeout 15 virsh destroy $d >/dev/null 2>&1; timeout 10 virsh undefine $d >/dev/null 2>&1; done
sleep 2
timeout 540 openstack server create vm-a --image cirros-0.6.0 --flavor m1.p003 \
  --network net-a --security-group sg-a --config-drive True --user-data /opt/stack/vm-a-init.sh --wait >/dev/null 2>&1
echo "  rc=$?"'
SID=$(sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && openstack server list -f value -c ID 2>/dev/null | head -1')
ADDR=$(sudo docker exec p003-os bash -c "source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && openstack server show $SID -f value -c addresses" | grep -oE '10\.30\.0\.[0-9]+')
ST=$(sudo docker exec p003-os bash -c "source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && openstack server show $SID -f value -c status")
echo "  id=$SID status=$ST ip=${ADDR:-?}"

echo
echo "== [3] console DHCP =="
sleep 40
sudo docker exec p003-os bash -c "source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 40 openstack console log show $SID 2>/dev/null | grep -aE 'dhcpcd|lease|IPv4LL|P003|login' | tail -6" | sed 's/^/  /'

echo
echo "== [4] ping-watch =="
QR=$(sudo docker exec p003-os bash -c 'ip netns list | awk "/qrouter/{print \$1}" | head -1')
echo "  qrouter: ${QR:-AUSENTE}"
if [ -n "$QR" ] && [ -n "$ADDR" ]; then
  OK=0
  for i in $(seq 1 12); do
    RC=$(sudo docker exec p003-os bash -c "ip netns exec $QR ping -c1 -W2 $ADDR >/dev/null 2>&1 && echo ok || echo dead")
    echo "  t$((i*10))s: $RC"; [ "$RC" = "ok" ] && OK=$((OK+1))
  done
  echo "  >>> ok=$OK/12"
fi
echo "  cgroup machine/: $(sudo docker exec p003-os bash -c 'ls /sys/fs/cgroup/machine/ 2>/dev/null | grep -cE "qemu|instance"')"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "canário k01: $c"
echo "mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
