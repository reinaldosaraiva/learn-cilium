#!/usr/bin/env bash
# P003-S012 C3-bis — fix keystone 503 (socket dir) e estado mysql.
set -uo pipefail

echo "== [1] mysql real =="
sudo docker exec p003-os bash -c 'mysqladmin ping 2>&1 | head -1; pgrep -xc mysqld; tail -3 /var/log/mysql/error.log 2>/dev/null | cut -c1-140'

echo
echo "== [2] uwsgi socket dir + logs =="
sudo docker exec p003-os bash -c 'ls -ld /var/run/uwsgi 2>&1; tail -4 /opt/stack/logs/keystone.log 2>/dev/null | cut -c1-150'

echo
echo "== [3] corrigir: criar /var/run/uwsgi + religar keystone =="
sudo docker exec p003-os bash -c 'mkdir -p /var/run/uwsgi && chown stack:stack /var/run/uwsgi && echo "  dir ok"
PIDS=$(ps -eo pid,args | grep "[p]rocname-prefix keystone" | awk "{print \$1}")
for p in $PIDS; do kill -9 $p 2>/dev/null; done; sleep 1
sudo -u stack bash -c "nohup /opt/stack/data/venv/bin/uwsgi --procname-prefix keystone --ini /etc/keystone/keystone-uwsgi-public.ini --venv /opt/stack/data/venv >/opt/stack/logs/keystone.log 2>&1 &" </dev/null
echo "  keystone relançado"'

echo
echo "== [4] checar os outros uwsgi (sockets ok?) =="
sudo docker exec p003-os bash -c 'for n in neutron-server glance-api placement-api nova-api; do
  if ! ls /var/run/uwsgi/*.socket >/dev/null 2>&1 || ! pgrep -f "procname-prefix $n" >/dev/null; then
    echo "  $n: relançando (socket dir foi criado depois)"
    PIDS=$(ps -eo pid,args | grep "[p]rocname-prefix $n" | awk "{print \$1}")
    for p in $PIDS; do kill -9 $p 2>/dev/null; done
  fi
done
for svc in "neutron-server /etc/neutron/neutron-api-uwsgi.ini" "glance-api /etc/glance/glance-uwsgi.ini" "placement-api /etc/placement/placement-uwsgi.ini" "nova-api /etc/nova/nova-api-uwsgi.ini"; do
  set -- $svc; NAME=$1; INI=$2
  pgrep -f "procname-prefix $NAME" >/dev/null || sudo -u stack bash -c "nohup /opt/stack/data/venv/bin/uwsgi --procname-prefix $NAME --ini $INI --venv /opt/stack/data/venv >/opt/stack/logs/$NAME.log 2>&1 &" </dev/null
done
echo "  aguardando 40s"; sleep 40
ls -la /var/run/uwsgi/ | grep socket | sed "s/^/  sock: /"'

echo
echo "== [5] verificação =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1
echo "--- catalogo:"; timeout 40 openstack catalog list -f value -c Name 2>&1 | tr "\n" " "; echo
echo "--- agentes:"; timeout 40 openstack network agent list -f value -c "Agent Type" -c Alive 2>&1 | sed "s/^/    /"
echo "--- compute:"; timeout 40 openstack compute service list -f value -c Binary -c State 2>&1 | grep up | sed "s/^/    /"
echo "--- cloud:"; timeout 30 openstack network list -f value -c Name 2>&1 | sed "s/^/    net: /"; timeout 30 openstack router list -f value -c Name 2>&1 | sed "s/^/    router: /"; timeout 30 openstack image list -f value -c Name 2>&1 | sed "s/^/    img: /"; timeout 30 openstack flavor list -f value -c Name 2>&1 | sed "s/^/    flavor: /"'
