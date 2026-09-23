#!/usr/bin/env bash
# P003-S012 C6 — reset limpo do compute: matar todos os qemus/domínios wedge,
# purgar TODAS as instâncias vm-a (API + SQL), restart q-dhcp (qdhcp ns sumiu)
# e n-cpu; criar UMA VM e vigiar; se rx sobreviver, MATRIX A imediata.
set -uo pipefail
KC="--kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw"

echo "== [1] zerar domínios/qemus =="
sudo /usr/bin/docker exec p003-os bash -c 'for d in $(timeout 20 virsh list --all --name 2>/dev/null); do timeout 15 virsh destroy $d >/dev/null 2>&1; timeout 10 virsh undefine $d --nvram >/dev/null 2>&1 || timeout 10 virsh undefine $d >/dev/null 2>&1; echo "  undef $d"; done; for p in $(pgrep qemu-system); do kill -9 $p 2>/dev/null; done; sleep 2; echo "  qemus vivos: $(pgrep -c qemu-system || echo 0)"; echo "  domínios: $(timeout 15 virsh list --all --name 2>/dev/null | wc -l)"'

echo
echo "== [2] purgar TODAS as instâncias (API + SQL) =="
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1
for id in $(openstack server list --all-projects -f value -c ID 2>/dev/null); do
  timeout 60 openstack server delete $id --wait >/dev/null 2>&1 || timeout 20 openstack server delete $id --force >/dev/null 2>&1
done
echo "  via API ok"'
sudo /usr/bin/docker exec -i p003-os bash -s <<'EOS'
PW=$(grep -m1 "^connection = mysql" /etc/nova/nova.conf | sed -E 's|.*//([^:]+):([^@]+)@.*|\2|')
mysql -uroot -p"$PW" -N -e "update nova_cell1.instances set deleted=id, deleted_at=now() where (display_name='vm-a') and deleted=0" 2>/dev/null
mysql -uroot -p"$PW" -N -e "delete im from nova_api.instance_mappings im left join nova_cell1.instances i on i.uuid=im.instance_uuid and i.deleted=0 where i.uuid is null" 2>/dev/null
echo "  SQL: $(mysql -uroot -p"$PW" -N -e "select count(*) from nova_cell1.instances where display_name='vm-a' and deleted=0" 2>/dev/null) instância(s) ativa(s)"
EOS

echo
echo "== [3] restart q-dhcp (qdhcp ns) + n-cpu =="
DP=$(sudo /usr/bin/docker exec p003-os bash -c "ps -eo pid,args | grep '[n]eutron-dhcp-agent' | awk '{print \$1}' | tr '\n' ' '")
for p in $DP; do sudo /usr/bin/docker exec p003-os kill -9 "$p" 2>/dev/null; done
sudo /usr/bin/docker exec -d -u stack p003-os /opt/stack/data/venv/bin/neutron-dhcp-agent \
  --config-file /etc/neutron/neutron.conf \
  --config-file /etc/neutron/dhcp_agent.ini \
  --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini \
  --log-file /opt/stack/logs/q-dhcp.log
CP=$(sudo /usr/bin/docker exec p003-os bash -c "ps -eo pid,args | grep '[n]ova-compute' | grep -vE 'grep|uwsgi' | awk '{print \$1}' | tr '\n' ' '")
for p in $CP; do sudo /usr/bin/docker exec p003-os kill -9 "$p" 2>/dev/null; done
sudo /usr/bin/docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-compute --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-cpu.log
echo "  aguardando 50s"; sleep 50
sudo /usr/bin/docker exec p003-os bash -c 'ip netns list | sed "s/^/  ns: /"'
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1; openstack network agent list -f value -c "Agent Type" -c Alive 2>/dev/null | sed "s/^/  ag: /"'

echo
echo "== [4] criar UMA vm-a =="
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; timeout 540 openstack server create vm-a --image cirros-0.6.0 --flavor m1.p003 \
  --network net-a --security-group sg-a --config-drive True --user-data /opt/stack/vm-a-init.sh --wait >/dev/null 2>&1; echo "  rc=$?"'
ST=$(sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && openstack server list -f value -c Status 2>/dev/null | head -1')
ADDR=$(sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && openstack server list -f value -c Networks | grep -oE "10\.30\.0\.[0-9]+"')
echo "  status=$ST ip=${ADDR:-?}"

echo
echo "== [5] vigiar rx (16x10s) =="
QR=$(sudo /usr/bin/docker exec p003-os bash -c 'ip netns list | awk "/qrouter/{print \$1}" | head -1')
OK=0
for i in $(seq 1 16); do
  T=$((i*10))
  RC=$(sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR ping -c1 -W2 $ADDR >/dev/null 2>&1 && echo ok || echo dead")
  echo "  t${T}s: $RC"
  [ "$RC" = "ok" ] && OK=$((OK+1))
done
echo "  >>> total ok: $OK/16"

echo
echo "== [6] lab + RAM =="
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo /usr/bin/docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR==2{print "  host available: "$7" GiB"}'
