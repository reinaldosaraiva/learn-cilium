#!/usr/bin/env bash
# P003-S012 rodada 2 — diagnóstico read-only do build preso: onde o fluxo para?
# (n-cond, n-sch, instances/host, build_requests, filas nova_cell1)
set -uo pipefail

echo "== [1] n-cond: atividade recente do build =="
sudo docker exec p003-os bash -c 'tail -60 /opt/stack/logs/n-cond.log | grep -aE "INFO|WARNING|ERROR" | grep -avE "dbcounter|loopingcall" | tail -8 | cut -c1-170 | sed "s/^/  /"'

echo
echo "== [2] n-sch: filtros da última tentativa =="
sudo docker exec p003-os bash -c 'grep -a "returned [0-9]* hosts\|Select\|select_destinations" /opt/stack/logs/n-sch.log 2>/dev/null | tail -4 | cut -c1-170 | sed "s/^/  /"'

echo
echo "== [3] instância no cell1: host atribuído? =="
sudo docker exec p003-os bash -c 'PW=$(grep -m1 "^connection = mysql" /etc/nova/nova.conf | sed -E "s|.*//([^:]+):([^@]+)@.*|\2|"); mysql -uroot -p"$PW" -N -e "select uuid,host,node,vm_state,task_state from nova_cell1.instances where hostname=\"vm-a\"" 2>/dev/null | sed "s/^/  /"'
sudo docker exec p003-os bash -c 'PW=$(grep -m1 "^connection = mysql" /etc/nova/nova.conf | sed -E "s|.*//([^:]+):([^@]+)@.*|\2|"); mysql -uroot -p"$PW" -N -e "select count(*) from nova_api.build_requests" 2>/dev/null | sed "s/^/  build_requests: /"'

echo
echo "== [4] n-cpu: recebeu build_and_run_instance? =="
sudo docker exec p003-os bash -c 'grep -a "build_and_run\|Building instance\|Spawn" /opt/stack/logs/n-cpu.log 2>/dev/null | tail -4 | cut -c1-170 | sed "s/^/  /" || echo "  (nada)"'

echo
echo "== [5] filas no vhost nova_cell1 (com consumidores) =="
sudo docker exec p003-os bash -c 'timeout 90 rabbitmqctl -p nova_cell1 list_queues name messages consumers 2>/dev/null | grep -v "^Timeout" | head -15 | sed "s/^/  /"'
