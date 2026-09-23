#!/usr/bin/env bash
# P003-S012 C6 — teste de hipótese FINAL: NIC e1000 (virtio/vhost é o suspeito
# em KVM aninhado). hw_vif_model=e1000 na imagem -> recriar VM -> DHCP/ping.
set -uo pipefail

echo "== [1] imagem com hw_vif_model=e1000 =="
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack image set --property hw_vif_model=e1000 cirros-0.6.0 && echo "  set ok"; openstack image show cirros-0.6.0 -f value -c properties | sed "s/^/  /"'

echo
echo "== [2] recriar vm-a =="
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1
for id in $(openstack server list -f value -c ID 2>/dev/null); do timeout 60 openstack server delete $id --wait >/dev/null 2>&1 || timeout 20 openstack server delete $id --force >/dev/null 2>&1; done
for d in $(timeout 20 virsh list --all --name 2>/dev/null); do timeout 15 virsh destroy $d >/dev/null 2>&1; timeout 10 virsh undefine $d >/dev/null 2>&1; done
sleep 2
timeout 540 openstack server create vm-a --image cirros-0.6.0 --flavor m1.p003 \
  --network net-a --security-group sg-a --config-drive True --user-data /opt/stack/vm-a-init.sh --wait >/dev/null 2>&1
echo "  rc=$? status=$(openstack server show vm-a -f value -c status)"'
ADDR=$(sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && openstack server show vm-a -f value -c addresses | grep -oE "10\.30\.0\.[0-9]+"')
DOM=$(sudo /usr/bin/docker exec p003-os bash -c 'timeout 20 virsh list --name --state-running 2>/dev/null | head -1')
echo "  ip=${ADDR:-?} dom=$DOM"
echo "  --- modelo de NIC do domínio:"
sudo /usr/bin/docker exec p003-os bash -c "timeout 15 virsh dumpxml $DOM 2>/dev/null | grep -oE \"model type='[a-z0-9]+'\" | head -2" | sed 's/^/  /'

echo
echo "== [3] console: DHCP com e1000? =="
sleep 45
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 40 openstack console log show vm-a 2>/dev/null | grep -aE "dhcpcd|lease|carrier" | tail -6' | sed 's/^/  /'

echo
echo "== [4] ping-watch (12x10s) =="
QR=$(sudo /usr/bin/docker exec p003-os bash -c 'ip netns list | awk "/qrouter/{print \$1}" | head -1')
OK=0
for i in $(seq 1 12); do
  RC=$(sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR ping -c1 -W2 $ADDR >/dev/null 2>&1 && echo ok || echo dead")
  echo "  t$((i*10))s: $RC"; [ "$RC" = "ok" ] && OK=$((OK+1))
done
echo "  >>> ok=$OK/12"

echo
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "canário k01: $c"
echo "p003-os mem: $(sudo /usr/bin/docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
