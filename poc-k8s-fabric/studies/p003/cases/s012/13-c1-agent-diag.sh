#!/usr/bin/env bash
# P003-S012 rodada 2 — diagnóstico por que os agentes não registram no server.
# Somente leitura + listagens; nenhuma mutação.
set -uo pipefail

echo "== [1] processos uwsgi/neutron (case-insensitive, proctitle reescrito) =="
sudo docker exec p003-os bash -c 'ps -eo pid,user,etime,args | grep -iE "uwsgi|neutron" | grep -v grep | cut -c1-120 | sed "s/^/  /"'

echo
echo "== [2] logs dos agentes: estado do RPC/registro =="
sudo docker exec p003-os bash -c 'for l in q-agt q-dhcp q-l3; do echo "  --- $l"; grep -aiE "AMQP|report_state|agent.*(start|register)|rpc" /opt/stack/logs/$l.log 2>/dev/null | grep -av "logging_exception\|rate_limit_except\|DEBUG oslo_messaging" | tail -8 | cut -c1-165 | sed "s/^/    /"; done'

echo
echo "== [3] filas rabbit (consumidores) =="
sudo docker exec p003-os bash -c 'timeout 25 rabbitmqctl list_queues name messages consumers 2>/dev/null | grep -E "^(q-|l3_agent|dhcp_agent|q_agent|neutron)" | head -12 | sed "s/^/  /"'

echo
echo "== [4] agent list via API raw =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 30 openstack network agent list -f json 2>&1' | sed 's/^/  /'

echo
echo "== [5] última linha INFO de cada agente =="
sudo docker exec p003-os bash -c 'for l in q-agt q-dhcp q-l3; do printf "  %-8s " "$l"; grep -a "INFO" /opt/stack/logs/$l.log 2>/dev/null | tail -1 | cut -c1-150; done'

echo
echo "== [6] nova tentativa de registro? (restart dos agentes é a hipótese a testar) =="
sudo docker exec p003-os bash -c 'grep -ac "Synchronizing state" /opt/stack/logs/q-dhcp.log /opt/stack/logs/q-l3.log 2>/dev/null | sed "s/^/    /"'
