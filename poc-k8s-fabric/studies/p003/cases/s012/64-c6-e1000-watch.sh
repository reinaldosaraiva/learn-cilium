#!/usr/bin/env bash
# P003-S012 C6 — dedupe (manter a mais nova), NIC model, DHCP e ping-watch.
set -uo pipefail
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1
echo "=== servers:"
openstack server list -f value -c ID -c Name -c Status -c Networks -c "Created At" 2>/dev/null | sed "s/^/  /"'
NEW=$(sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && openstack server list -f value -c ID -c "Created At" 2>/dev/null | sort -k2 -r | head -1 | cut -d" " -f1')
echo "  manter: $NEW"
sudo /usr/bin/docker exec p003-os bash -c "source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1
for id in \$(openstack server list -f value -c ID 2>/dev/null); do
  [ \"\$id\" = \"$NEW\" ] && continue
  timeout 60 openstack server delete \$id --wait >/dev/null 2>&1 || timeout 20 openstack server delete \$id --force >/dev/null 2>&1
  echo \"  deleted \$id\"
done"
sleep 5
ADDR=$(sudo /usr/bin/docker exec p003-os bash -c "source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && openstack server show $NEW -f value -c addresses" | grep -oE '10\.30\.0\.[0-9]+')
DOM=$(sudo /usr/bin/docker exec p003-os bash -c 'timeout 20 virsh list --name --state-running 2>/dev/null | head -1')
echo "  ip=${ADDR:-?} dom=$DOM"
echo "  --- NIC:"
sudo /usr/bin/docker exec p003-os bash -c "timeout 15 virsh dumpxml $DOM 2>/dev/null | grep -oE \"model type='[a-z0-9]+'\"" | sed 's/^/  /'

echo
echo "== DHCP no console =="
sleep 30
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 40 openstack console log show vm-a 2>/dev/null | grep -aE "dhcpcd|lease|IPv4LL" | tail -5' | sed 's/^/  /'

echo
echo "== ping-watch (12x10s) =="
QR=$(sudo /usr/bin/docker exec p003-os bash -c 'ip netns list | awk "/qrouter/{print \$1}" | head -1')
OK=0
for i in $(seq 1 12); do
  RC=$(sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR ping -c1 -W2 $ADDR >/dev/null 2>&1 && echo ok || echo dead")
  echo "  t$((i*10))s: $RC"; [ "$RC" = "ok" ] && OK=$((OK+1))
done
echo "  >>> ok=$OK/12"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "canário k01: $c"
echo "mem: $(sudo /usr/bin/docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
