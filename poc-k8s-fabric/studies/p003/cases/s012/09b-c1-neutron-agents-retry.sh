#!/usr/bin/env bash
# P003-S012 rodada 2 — Emenda C1, C1.3 tentativa 2/2.
# Causa raiz da tentativa 1: pgrep -f casava com o cmdline do próprio wrapper
# bash ("pgrep -f neutron-openvswitch-agent" contém o padrão) → || short-circuit
# → agente nunca lançado. Correção: padrão com bracket [n]eutron-... .
# A probe em foreground já provou que o agente inicia sem erro.
set -uo pipefail

echo "== [C1.3-t2] limpar possível sobrevivente da probe =="
sudo docker exec p003-os bash -c 'pkill -f "[n]eutron-openvswitch-agent" 2>/dev/null; sleep 1; ps -eo pid,user,args | grep -E "[n]eutron-(openvswitch|dhcp|l3)" || echo "  nenhum agente rodando (limpo)"'

echo
echo "== [C1.3-t2] lançar agentes (stack, nohup, </dev/null) =="
sudo docker exec p003-os bash -c 'pgrep -f "[n]eutron-openvswitch-agent" >/dev/null || sudo -u stack bash -c "nohup /opt/stack/data/venv/bin/neutron-openvswitch-agent --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini >/opt/stack/logs/q-agt.log 2>&1 &" </dev/null; echo launched-q-agt'
sudo docker exec p003-os bash -c 'pgrep -f "[n]eutron-dhcp-agent" >/dev/null || sudo -u stack bash -c "nohup /opt/stack/data/venv/bin/neutron-dhcp-agent --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/dhcp_agent.ini --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini >/opt/stack/logs/q-dhcp.log 2>&1 &" </dev/null; echo launched-q-dhcp'
sudo docker exec p003-os bash -c 'pgrep -f "[n]eutron-l3-agent" >/dev/null || sudo -u stack bash -c "nohup /opt/stack/data/venv/bin/neutron-l3-agent --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/l3_agent.ini --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini >/opt/stack/logs/q-l3.log 2>&1 &" </dev/null; echo launched-q-l3'
echo "  aguardando 35s"; sleep 35

echo
echo "== [C1.3-t2] processos reais (ps, sem self-match) =="
sudo docker exec p003-os bash -c 'ps -eo pid,user,etime,args | grep -E "[n]eutron-(openvswitch|dhcp|l3)-agent" | sed -E "s/(--[a-z-]+ [^ ]+){0,0}/  /" | cut -c1-120'

echo
echo "== [C1.3-t2] logs =="
sudo docker exec p003-os bash -c 'for l in q-agt q-dhcp q-l3; do echo "  --- $l ($(wc -l < /opt/stack/logs/$l.log 2>/dev/null || echo 0) linhas)"; tail -3 /opt/stack/logs/$l.log 2>/dev/null | cut -c1-160 | sed "s/^/    /"; done'

echo
echo "== [C1.3-t2] aceite: network agent list =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack network agent list -f table 2>&1' | sed 's/^/  /'

echo
echo "== [C1.3-t2] aceite: br-int =="
sudo docker exec p003-os bash -c 'ovs-vsctl list-br | sed "s/^/  br: /"; echo "  total: $(ovs-vsctl list-br | wc -l)"'

echo
echo "== [C1.3-t2] pós: lab intacto =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
for b in docker0 br-b56f3de1d858 br-97b5ec9007c2 br-b03e3d58a257; do
  printf "  %-20s ports=%s\n" "$b" "$(ip -o link show master "$b" 2>/dev/null | wc -l)"
done
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
