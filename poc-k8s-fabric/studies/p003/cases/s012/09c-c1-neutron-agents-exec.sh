#!/usr/bin/env bash
# P003-S012 rodada 2 — Emenda C1, C1.3 lançamento final dos agentes.
# Causa raiz das tentativas 1 e 2 (ambas wrapper-level, agentes jamais lançados):
# o pgrep de guard casava com o PRÓPRIO cmdline do wrapper, que continha o
# caminho do binário sem bracket (".../venv/bin/neutron-dhcp-agent ...") →
# `||` short-circuitava antes de lançar. Correção: sem shell, sem guard, sem
# nohup: `docker exec -d -u stack <binário> ... --log-file <path>`.
set -uo pipefail

echo "== [C1.3-t3] limpar qualquer agente remanescente (exec separado) =="
sudo docker exec p003-os bash -c 'pkill -9 -f neutron-openvswitch-agent 2>/dev/null; pkill -9 -f neutron-dhcp-agent 2>/dev/null; pkill -9 -f neutron-l3-agent 2>/dev/null; sleep 1; ps -eo pid,user,args | grep -E "[n]eutron-(openvswitch|dhcp|l3)" || echo "  limpo: nenhum agente rodando"'

echo
echo "== [C1.3-t3] lançar os 3 agentes (docker exec -d -u stack, --log-file) =="
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/neutron-openvswitch-agent \
  --config-file /etc/neutron/neutron.conf \
  --config-file /etc/neutron/plugins/ml2/ml2_conf.ini \
  --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini \
  --log-file /opt/stack/logs/q-agt.log
echo "  q-agt exec rc=$?"
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/neutron-dhcp-agent \
  --config-file /etc/neutron/neutron.conf \
  --config-file /etc/neutron/dhcp_agent.ini \
  --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini \
  --log-file /opt/stack/logs/q-dhcp.log
echo "  q-dhcp exec rc=$?"
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/neutron-l3-agent \
  --config-file /etc/neutron/neutron.conf \
  --config-file /etc/neutron/l3_agent.ini \
  --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini \
  --log-file /opt/stack/logs/q-l3.log
echo "  q-l3 exec rc=$?"

echo "  aguardando 40s"; sleep 40

echo
echo "== [C1.3-t3] processos reais =="
sudo docker exec p003-os bash -c 'ps -eo pid,user,etime,comm | grep -E "neutron" | grep -vE "grep|server" | sed "s/^/  /"'

echo
echo "== [C1.3-t3] logs =="
sudo docker exec p003-os bash -c 'for l in q-agt q-dhcp q-l3; do echo "  --- $l"; grep -cE "." /opt/stack/logs/$l.log 2>/dev/null | sed "s/^/    linhas: /"; grep -E "ERROR|Traceback|CRITICAL" /opt/stack/logs/$l.log 2>/dev/null | head -5 | cut -c1-170 | sed "s/^/    ERR: /"; tail -2 /opt/stack/logs/$l.log 2>/dev/null | cut -c1-170 | sed "s/^/    /"; done'

echo
echo "== [C1.3-t3] aceite: network agent list =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack network agent list 2>&1' | sed 's/^/  /'

echo
echo "== [C1.3-t3] aceite: br-int / br-ex =="
sudo docker exec p003-os bash -c 'ovs-vsctl list-br | sed "s/^/  br: /"; echo "  total: $(ovs-vsctl list-br | wc -l)"'

echo
echo "== [C1.3-t3] pós: lab intacto =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
for b in docker0 br-b56f3de1d858 br-97b5ec9007c2 br-b03e3d58a257; do
  printf "  %-20s ports=%s\n" "$b" "$(ip -o link show master "$b" 2>/dev/null | wc -l)"
done
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
