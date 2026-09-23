#!/usr/bin/env bash
# P003-S012 C3-bis — reset limpo das APIs uwsgi (o proctitle reescrito invalida
# guards por 'procname-prefix') + mysql restart. Relançamento ÚNICO de cada.
set -uo pipefail

echo "== [1] mysql restart =="
sudo docker exec p003-os bash -c 'ps -eo pid,stat,args | grep [m]ysqld | head -2 | cut -c1-60
service mysql restart </dev/null >/tmp/mr.log 2>&1
for i in $(seq 1 40); do mysql -e "select 1" >/dev/null 2>&1 && { echo "  mysql OK (${i}x2s)"; break; }; sleep 2; done
mysql -e "select 1" >/dev/null 2>&1 && echo "  sql ok" || { echo "  FALHOU"; tail -3 /tmp/mr.log; }'

echo
echo "== [2] matar TODOS os uwsgi =="
sudo docker exec p003-os bash -c 'PIDS=$(ps -eo pid,args | grep -iE "[u]wsgi" | awk "{print \$1}")
for p in $PIDS; do kill -9 $p 2>/dev/null; done
sleep 2; ps -eo pid,args | grep -iE "[u]wsgi" | wc -l | sed "s/^/  restantes: /"'

echo
echo "== [3] relançamento único (socket dir já existe) =="
sudo docker exec p003-os bash -c '
for svc in "keystone /etc/keystone/keystone-uwsgi-public.ini" \
           "neutron-server /etc/neutron/neutron-api-uwsgi.ini" \
           "glance-api /etc/glance/glance-uwsgi.ini" \
           "placement-api /etc/placement/placement-uwsgi.ini" \
           "nova-api /etc/nova/nova-api-uwsgi.ini"; do
  set -- $svc; NAME=$1; INI=$2
  sudo -u stack bash -c "nohup /opt/stack/data/venv/bin/uwsgi --procname-prefix $NAME --ini $INI --venv /opt/stack/data/venv >/opt/stack/logs/$NAME.log 2>&1 &" </dev/null
  echo "  $NAME lançado"
done
pgrep -f neutron-rpc-server >/dev/null || sudo -u stack bash -c "nohup /opt/stack/data/venv/bin/neutron-rpc-server --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini >/opt/stack/logs/q-rpc.log 2>&1 &" </dev/null
echo "  rpc-server: ok"'
echo "  aguardando 50s"; sleep 50
sudo docker exec p003-os bash -c 'ls /var/run/uwsgi/*.socket 2>/dev/null | sed "s/^/  sock: /"; echo "  uwsgi procs: $(ps -eo args | grep -icE \"uwsgi\" )"; echo "  rpc: $(pgrep -fc neutron-rpc-server)"'

echo
echo "== [4] verificação completa =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1
echo "--- catalogo: $(timeout 40 openstack catalog list -f value -c Name 2>&1 | tr "\n" " ")"
echo "--- agentes:"; timeout 40 openstack network agent list -f value -c "Agent Type" -c Alive 2>&1 | sed "s/^/    /"
echo "--- compute (up):"; timeout 40 openstack compute service list -f value -c Binary -c State 2>&1 | grep up | sed "s/^/    /"
echo "--- cloud:"; timeout 30 openstack network list -f value -c Name 2>&1 | sed "s/^/    net: /"; timeout 30 openstack router list -f value -c Name 2>&1 | sed "s/^/    router: /"; timeout 30 openstack image list -f value -c Name 2>&1 | sed "s/^/    img: /"; timeout 30 openstack server list -f value -c Name 2>&1 | sed "s/^/    server: /"'
echo
echo "== [5] lab =="
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
