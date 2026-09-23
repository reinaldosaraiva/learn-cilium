#!/usr/bin/env bash
# P003-S012 rodada 2 — Emenda C1, C1.3 fix final: agentes -> ovsdb via SOCKET UNIX.
# Causa raiz: default do neutron é ovsdb_connection=tcp:127.0.0.1:6640, mas este
# ovsdb-server escuta SOMENTE em unix:/var/run/openvswitch/db.sock (log do q-agt:
# "Unable to open stream to tcp:127.0.0.1:6640 ... Connection refused").
# Correção: [ovs] ovsdb_connection = unix:... no openvswitch_agent.ini (carregado
# pelos 3 agentes) + restart dos agentes. Kill de sobras POR PID (não por padrão).
set -uo pipefail

echo "== [fix-1] matar agentes atuais por PID (kill -9 <pid> explícito) =="
PIDS=$(sudo docker exec p003-os bash -c 'ps -eo pid,args | grep -E "[n]eutron-(openvswitch|dhcp|l3)-agent" | awk "{print \$1}" | tr "\n" " "')
echo "  pids: $PIDS"
for p in $PIDS; do sudo docker exec p003-os kill -9 "$p" 2>/dev/null && echo "  killed $p"; done
sleep 2
sudo docker exec p003-os bash -c 'ps -eo pid,args | grep -E "[n]eutron-(openvswitch|dhcp|l3)-agent" || echo "  limpo"'

echo
echo "== [fix-2] ovsdb_connection atual no neutron.conf? (read-only) =="
sudo docker exec p003-os bash -c 'grep -rn "ovsdb_connection" /etc/neutron/ 2>/dev/null | sed "s/^/  /" || echo "  (nenhuma ocorrência — confirma default tcp:127.0.0.1:6640)"'

echo
echo "== [fix-3] adicionar ovsdb_connection unix no [ovs] do openvswitch_agent.ini =="
sudo docker exec p003-os bash -c '
sed -i "/^bridge_mappings = public:br-ex/a ovsdb_connection = unix:/var/run/openvswitch/db.sock" /etc/neutron/plugins/ml2/openvswitch_agent.ini
echo "  conteúdo final:"
grep -vE "^\s*(#|$)" /etc/neutron/plugins/ml2/openvswitch_agent.ini | sed "s/^/    /"'

echo
echo "== [fix-4] relançar os 3 agentes (docker exec -d -u stack) =="
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/neutron-openvswitch-agent \
  --config-file /etc/neutron/neutron.conf \
  --config-file /etc/neutron/plugins/ml2/ml2_conf.ini \
  --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini \
  --log-file /opt/stack/logs/q-agt.log
echo "  q-agt rc=$?"
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/neutron-dhcp-agent \
  --config-file /etc/neutron/neutron.conf \
  --config-file /etc/neutron/dhcp_agent.ini \
  --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini \
  --log-file /opt/stack/logs/q-dhcp.log
echo "  q-dhcp rc=$?"
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/neutron-l3-agent \
  --config-file /etc/neutron/neutron.conf \
  --config-file /etc/neutron/l3_agent.ini \
  --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini \
  --log-file /opt/stack/logs/q-l3.log
echo "  q-l3 rc=$?"

echo "  aguardando 45s"; sleep 45

echo
echo "== [fix-5] processos =="
sudo docker exec p003-os bash -c 'ps -eo pid,user,etime,comm | grep -E "neutron" | grep -v grep | sed "s/^/  /"'

echo
echo "== [fix-6] logs: erros de ovsdb? =="
sudo docker exec p003-os bash -c 'for l in q-agt q-dhcp q-l3; do echo "  --- $l"; grep -E "Unable to open stream|Connection refused|Traceback|CRITICAL" /opt/stack/logs/$l.log 2>/dev/null | tail -3 | cut -c1-150 | sed "s/^/    ERR: /"; tail -2 /opt/stack/logs/$l.log 2>/dev/null | cut -c1-150 | sed "s/^/    /"; done'

echo
echo "== [fix-7] aceite: network agent list =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack network agent list 2>&1' | sed 's/^/  /'

echo
echo "== [fix-8] aceite: br-int =="
sudo docker exec p003-os bash -c 'ovs-vsctl list-br | sed "s/^/  br: /"; echo "  total: $(ovs-vsctl list-br | wc -l)"'

echo
echo "== [fix-9] pós: lab intacto =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
for b in docker0 br-b56f3de1d858 br-97b5ec9007c2 br-b03e3d58a257; do
  printf "  %-20s ports=%s\n" "$b" "$(ip -o link show master "$b" 2>/dev/null | wc -l)"
done
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
