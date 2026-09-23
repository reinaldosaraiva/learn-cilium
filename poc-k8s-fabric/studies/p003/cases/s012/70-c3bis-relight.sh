#!/usr/bin/env bash
# P003-S012 C3-bis — relight completo do testbed no novo container
# (cgroupns=host). Ordem: guard -> mysql/rabbit/memcached/apache -> ovsdb
# (unix+ptcp) -> ovs-vswitchd -> keystone -> neutron api+RPC -> agentes ->
# glance/placement/nova-api -> conductor/scheduler/compute -> libvirt trio.
# Configs corrigidas e DB vieram no snapshot; nada de ovs-ctl JAMAIS.
set -uo pipefail

echo "== [1] C1.0 guard bridge (PRIMEIRO, antes de qualquer OVS) =="
sudo docker exec p003-os bash -c 'ip link add p003-guard type bridge 2>/dev/null; ip link set p003-guard up 2>/dev/null; echo "  guards no netns: $(ip -o -d link show type bridge | wc -l)"'

echo "== [2] mysql =="
sudo docker exec p003-os bash -c 'if ! mysqladmin ping >/dev/null 2>&1; then service mysql start </dev/null >/tmp/m.log 2>&1; fi; for i in $(seq 1 45); do mysqladmin ping >/dev/null 2>&1 && { echo "  mysql UP (${i}x2s)"; break; }; sleep 2; done; mysqladmin ping 2>&1 | head -1 | sed "s/^/  /"'
echo "== [3] rabbitmq =="
sudo docker exec p003-os bash -c 'if ! timeout 20 rabbitmqctl status >/dev/null 2>&1; then service rabbitmq-server start </dev/null >/tmp/r.log 2>&1; fi; for i in $(seq 1 45); do timeout 20 rabbitmqctl status >/dev/null 2>&1 && { echo "  rabbit UP (${i}x2s)"; break; }; sleep 2; done'
echo "== [4] memcached + apache =="
sudo docker exec p003-os bash -c 'pgrep -x memcached >/dev/null || service memcached start </dev/null >/dev/null 2>&1; pgrep -x apache2 >/dev/null || service apache2 start </dev/null >/dev/null 2>&1; sleep 4; echo "  memcached=$(pgrep -cx memcached) apache=$(pgrep -cx apache2)"'

echo "== [5] ovsdb-server (unix + ptcp) + ovs-vswitchd (binários diretos) =="
sudo docker exec p003-os bash -c '
pgrep -x ovsdb-server >/dev/null || {
  ovsdb-server /etc/openvswitch/conf.db \
    --remote=punix:/var/run/openvswitch/db.sock \
    --remote=ptcp:6640:127.0.0.1 \
    -vconsole:emer -vsyslog:err -vfile:info --no-chdir \
    --log-file --pidfile --detach --monitor
}
sleep 3
chmod 666 /var/run/openvswitch/db.sock 2>/dev/null
pgrep -x ovs-vswitchd >/dev/null || {
  ovs-vswitchd unix:/var/run/openvswitch/db.sock \
    -vconsole:emer -vsyslog:err -vfile:info --mlockall --no-chdir \
    --log-file --pidfile --detach --monitor
}
sleep 6
echo "  ovsdb=$(pgrep -xc ovsdb-server) vswitchd=$(pgrep -xc ovs-vswitchd)"
ovs-vsctl list-br | sed "s/^/  br: /"'

echo "== [6] keystone uwsgi =="
sudo docker exec p003-os bash -c 'rm -f /var/run/uwsgi/keystone-api.socket 2>/dev/null; pgrep -f "procname-prefix keystone" >/dev/null || sudo -u stack bash -c "nohup /opt/stack/data/venv/bin/uwsgi --procname-prefix keystone --ini /etc/keystone/keystone-uwsgi-public.ini --venv /opt/stack/data/venv >/opt/stack/logs/keystone.log 2>&1 &" </dev/null; echo "  lançado"'

echo "== [7] neutron: api uwsgi + RPC server =="
sudo docker exec p003-os bash -c 'rm -f /var/run/uwsgi/neutron-api.socket 2>/dev/null; pgrep -f "procname-prefix neutron-server" >/dev/null || sudo -u stack bash -c "nohup /opt/stack/data/venv/bin/uwsgi --procname-prefix neutron-server --ini /etc/neutron/neutron-api-uwsgi.ini --venv /opt/stack/data/venv >/opt/stack/logs/n-api-uwsgi.log 2>&1 &" </dev/null
pgrep -f "neutron-rpc-server" >/dev/null || sudo -u stack bash -c "nohup /opt/stack/data/venv/bin/neutron-rpc-server --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini >/opt/stack/logs/q-rpc.log 2>&1 &" </dev/null
echo "  lançados"'

echo "== [8] agentes neutron (exec -d -u stack, SEM guard pgrep) =="
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/neutron-openvswitch-agent \
  --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini \
  --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini --log-file /opt/stack/logs/q-agt.log
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/neutron-dhcp-agent \
  --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/dhcp_agent.ini \
  --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini --log-file /opt/stack/logs/q-dhcp.log
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/neutron-l3-agent \
  --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/l3_agent.ini \
  --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini --log-file /opt/stack/logs/q-l3.log
echo "  3 agentes lançados"

echo "== [9] glance + placement + nova-api (uwsgi) =="
sudo docker exec p003-os bash -c 'for svc in "glance-api /etc/glance/glance-uwsgi.ini" "placement-api /etc/placement/placement-uwsgi.ini" "nova-api /etc/nova/nova-api-uwsgi.ini"; do
  set -- $svc; NAME=$1; INI=$2
  pgrep -f "procname-prefix $NAME" >/dev/null || sudo -u stack bash -c "nohup /opt/stack/data/venv/bin/uwsgi --procname-prefix $NAME --ini $INI --venv /opt/stack/data/venv >/opt/stack/logs/$NAME.log 2>&1 &" </dev/null
done; echo "  3 APIs lançadas"'

echo "== [10] nova workers + libvirt trio =="
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-conductor --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-cond.log
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-scheduler --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-sch.log
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-compute --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-cpu.log
sudo docker exec p003-os bash -c 'pgrep -x libvirtd >/dev/null || /usr/sbin/libvirtd -d; pgrep -x virtlogd >/dev/null || /usr/sbin/virtlogd -d; pgrep -x virtlockd >/dev/null || /usr/sbin/virtlockd -d; sleep 4; echo "  libvirtd=$(pgrep -cx libvirtd) virtlogd=$(pgrep -cx virtlogd)"'

echo
echo "== [11] aguardando registro (60s) e verificação =="
sleep 60
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1
echo "--- catalogo:"; timeout 40 openstack catalog list -f value -c Name 2>&1 | tr "\n" " "; echo
echo "--- agentes:"; timeout 40 openstack network agent list -f value -c "Agent Type" -c Alive 2>&1 | sed "s/^/    /"
echo "--- compute:"; timeout 40 openstack compute service list -f value -c Binary -c State 2>&1 | grep -E "up|down" | sed "s/^/    /"
echo "--- cloud:"; timeout 40 openstack network list -f value -c Name 2>&1 | sed "s/^/    net: /"; timeout 40 openstack router list -f value -c Name 2>&1 | sed "s/^/    router: /"; timeout 40 openstack image list -f value -c Name 2>&1 | sed "s/^/    img: /"'
echo "--- netns:"
sudo docker exec p003-os bash -c 'ip netns list | sed "s/^/  /"'
echo "--- cgroup vhost/live:"
sudo docker exec p003-os bash -c 'ls /sys/fs/cgroup/machine/ 2>/dev/null | grep -v cgroup | head -3 | sed "s/^/  machine: /"'
echo
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "canário k01: $c"
echo "p003-os mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
