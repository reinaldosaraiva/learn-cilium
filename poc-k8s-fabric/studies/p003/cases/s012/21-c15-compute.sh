#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5a: pilha de compute.
# libvirtd -> glance-api -> placement-api -> nova (db sync + cell_v2 + api +
# conductor + scheduler + compute) -> verificação (services + hypervisor).
# Padrões: ExecStart exatos dos units devstack (uwsgi p/ APIs), binários diretos
# p/ workers, tudo como stack com </dev/null, virsh SEMPRE com timeout (D-S012-6).
set -uo pipefail

echo "== [1] libvirtd =="
if sudo docker exec p003-os pgrep -x libvirtd >/dev/null 2>&1; then
  echo "  libvirtd já roda"
else
  sudo docker exec -d p003-os /usr/sbin/libvirtd -d
  echo "  lançado; aguardando 10s"; sleep 10
fi
sudo docker exec p003-os bash -c 'pgrep -x libvirtd | head -3 | sed "s/^/  pid: /"'
sudo docker exec p003-os bash -c 'timeout 30 virsh version 2>&1 | tail -3 | sed "s/^/  /"'
sudo docker exec p003-os bash -c 'ip -o link show virbr0 >/dev/null 2>&1 && echo "  virbr0 existe (guard extra do ovs-ctl rearmado de novo)" || echo "  virbr0 ainda não existe"'

echo
echo "== [2] glance-api (uwsgi, ExecStart canônico) =="
sudo docker exec p003-os bash -c 'pgrep -f "[p]rocname-prefix glance-api" >/dev/null || sudo -u stack bash -c "nohup /opt/stack/data/venv/bin/uwsgi --procname-prefix glance-api --ini /etc/glance/glance-uwsgi.ini --venv /opt/stack/data/venv >/opt/stack/logs/g-api.log 2>&1 &" </dev/null; echo "  launched"'
echo "  aguardando 20s"; sleep 20
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack image list 2>&1 | head -4' | sed 's/^/  /'

echo
echo "== [3] placement-api (uwsgi) =="
sudo docker exec p003-os bash -c 'pgrep -f "[p]rocname-prefix placement" >/dev/null || sudo -u stack bash -c "nohup /opt/stack/data/venv/bin/uwsgi --procname-prefix placement-api --ini /etc/placement/placement-uwsgi.ini --venv /opt/stack/data/venv >/opt/stack/logs/placement-api.log 2>&1 &" </dev/null; echo "  launched"'
echo "  aguardando 15s"; sleep 15
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack resource provider list 2>&1 | head -4' | sed 's/^/  /'

echo
echo "== [4] nova: db sync + cell_v2 (nova main tinha 0 tabelas) =="
sudo docker exec p003-os bash -c 'sudo -u stack /opt/stack/data/venv/bin/nova-manage api_db sync 2>&1 | tail -2 | sed "s/^/  api_db: /"'
sudo docker exec p003-os bash -c 'sudo -u stack /opt/stack/data/venv/bin/nova-manage db sync 2>&1 | tail -2 | sed "s/^/  db: /"'
sudo docker exec p003-os bash -c 'sudo -u stack /opt/stack/data/venv/bin/nova-manage cell_v2 simple_cell_setup 2>&1 | tail -3 | sed "s/^/  cell_v2: /"'
sudo docker exec p003-os bash -c 'sudo -u stack /opt/stack/data/venv/bin/nova-manage cell_v2 list_cells 2>&1 | sed "s/^/  /"'
PW=$(sudo docker exec p003-os bash -c 'P=$(sed -n "s/^MYSQL_PASSWORD=//p" /opt/stack/devstack/local.conf | head -1); [ -z "$P" ] && P=$(sed -n "s/^DATABASE_PASSWORD=//p" /opt/stack/devstack/local.conf | head -1); echo "$P"')
sudo docker exec p003-os bash -c "mysql -uroot -p'$PW' -N -e 'select count(*) from information_schema.tables where table_schema=\"nova\"' 2>/dev/null" | sed 's/^/  tabelas nova: /'

echo
echo "== [5] nova-api (uwsgi) + conductor + scheduler =="
sudo docker exec p003-os bash -c 'pgrep -f "[p]rocname-prefix nova-api" >/dev/null || sudo -u stack bash -c "nohup /opt/stack/data/venv/bin/uwsgi --procname-prefix nova-api --ini /etc/nova/nova-api-uwsgi.ini --venv /opt/stack/data/venv >/opt/stack/logs/n-api.log 2>&1 &" </dev/null; echo "  n-api launched"'
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-conductor --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-cond.log
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-scheduler --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-sch.log
echo "  aguardando 25s"; sleep 25
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack catalog list -f value -c Name 2>&1 | tr "\n" " "' | sed 's/^/  catalog: /'; echo

echo
echo "== [6] nova-compute =="
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-compute --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-cpu.log
echo "  aguardando 45s (resource provider + libvirt init)"; sleep 45
sudo docker exec p003-os bash -c 'tail -4 /opt/stack/logs/n-cpu.log 2>/dev/null | cut -c1-160 | sed "s/^/  cpu-log: /"'

echo
echo "== [7] verificação: compute services + hypervisor =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack compute service list 2>&1' | sed 's/^/  /'
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack hypervisor list 2>&1' | sed 's/^/  /'

echo
echo "== [8] pós: lab intacto + RAM =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR==2{print "  host available: "$7" GiB"}'
