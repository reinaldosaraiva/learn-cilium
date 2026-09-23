#!/usr/bin/env bash
# P003-S012 C6b t2 — dedupe cpu_mode, n-cpu vivo, ghosts purgados, UMA VM.
set -uo pipefail

echo "== [1] dedupe cpu_mode + restart n-cpu =="
sudo /usr/bin/docker exec p003-os bash -c '
awk "/^cpu_mode = host-passthrough$/{if(!s++)print; next} /^cpu_mode/{next} {print}" /etc/nova/nova.conf > /tmp/nova.conf.new && cp /tmp/nova.conf.new /etc/nova/nova.conf
grep -n "^cpu_mode" /etc/nova/nova.conf | sed "s/^/  /"'
CP=$(sudo /usr/bin/docker exec p003-os bash -c "ps -eo pid,args | grep '[n]ova-compute' | grep -vE 'grep|uwsgi' | awk '{print \$1}' | tr '\n' ' '")
for p in $CP; do sudo /usr/bin/docker exec p003-os kill -9 "$p" 2>/dev/null; done
sleep 2
sudo /usr/bin/docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-compute --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-cpu.log
echo "  aguardando 70s"; sleep 70
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack compute service list -f value -c Binary -c State 2>/dev/null | grep compute | sed "s/^/  /"'

echo
echo "== [2] purgar ghosts + criar UMA VM =="
sudo /usr/bin/docker exec -i p003-os bash -s <<'EOS'
source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1
for id in $(openstack server list -f value -c ID 2>/dev/null); do timeout 60 openstack server delete $id --wait >/dev/null 2>&1 || timeout 20 openstack server delete $id --force >/dev/null 2>&1; done
PW=$(grep -m1 "^connection = mysql" /etc/nova/nova.conf | sed -E 's|.*//([^:]+):([^@]+)@.*|\2|')
mysql -uroot -p"$PW" -N -e "update nova_cell1.instances set deleted=id, deleted_at=now() where display_name='vm-a' and deleted=0" 2>/dev/null
mysql -uroot -p"$PW" -N -e "delete im from nova_api.instance_mappings im left join nova_cell1.instances i on i.uuid=im.instance_uuid and i.deleted=0 where i.uuid is null" 2>/dev/null
for d in $(timeout 20 virsh list --all --name 2>/dev/null); do timeout 15 virsh destroy $d >/dev/null 2>&1; timeout 10 virsh undefine $d >/dev/null 2>&1; done
for p in $(pgrep -f "qemu-system.*instance" 2>/dev/null); do kill -9 $p 2>/dev/null; done
sleep 2
timeout 540 openstack server create vm-a --image cirros-0.6.0 --flavor m1.p003 \
  --network net-a --security-group sg-a --config-drive True --user-data /opt/stack/vm-a-init.sh --wait >/dev/null 2>&1
echo "  create rc=$?"
EOS
SID=$(sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && openstack server list -f value -c ID 2>/dev/null | head -1')
ADDR=$(sudo /usr/bin/docker exec p003-os bash -c "source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && openstack server show $SID -f value -c addresses" | grep -oE '10\.30\.0\.[0-9]+')
DOM=$(sudo /usr/bin/docker exec p003-os bash -c 'timeout 20 virsh list --name --state-running 2>/dev/null | head -1')
echo "  id=$SID ip=${ADDR:-?} dom=$DOM"
sudo /usr/bin/docker exec p003-os bash -c "timeout 15 virsh dumpxml $DOM 2>/dev/null | grep -oE \"cpu mode='[a-z-]+'|model type='[a-z0-9]+'\" | head -2" | sed 's/^/  xml: /'
echo "  vhost: $(lsmod | grep -c '^vhost_net' || true) (0=off)"

echo
echo "== [3] console DHCP (45s) =="
sleep 45
sudo /usr/bin/docker exec p003-os bash -c "source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 40 openstack console log show $SID 2>/dev/null | grep -aE 'dhcpcd|lease|IPv4LL' | tail -5" | sed 's/^/  /'

echo
echo "== [4] ping-watch =="
QR=$(sudo /usr/bin/docker exec p003-os bash -c 'ip netns list | awk "/qrouter/{print \$1}" | head -1')
OK=0
for i in $(seq 1 10); do
  RC=$(sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR ping -c1 -W2 $ADDR >/dev/null 2>&1 && echo ok || echo dead")
  echo "  t$((i*10))s: $RC"; [ "$RC" = "ok" ] && OK=$((OK+1))
done
echo "  >>> ok=$OK/10"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "canário k01: $c"
