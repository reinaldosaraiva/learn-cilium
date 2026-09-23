#!/usr/bin/env bash
# P003-S012 rodada 2 — Emenda C1, fase C1.3: agentes Neutron.
# Desvio D-S012-8: dhcp_agent.ini / l3_agent.ini / openvswitch_agent.ini
# AUSENTES (stack.sh interrompido antes da fase de agentes) → criados aqui com
# o layout mínimo canônico do DevStack (bridge_mappings public:br-ex, fw OVS).
# Agentes sobem como usuário stack, nohup + log + </dev/null (lição D-S012-5).
# NUNCA invocar ovs-ctl / openvswitch-switch init.
set -uo pipefail

echo "== [C1.3] binários dos agentes presentes? =="
for b in neutron-openvswitch-agent neutron-dhcp-agent neutron-l3-agent; do
  if sudo docker exec p003-os test -x /opt/stack/data/venv/bin/$b; then echo "  PRESENT $b"; else echo "  ABSENT  $b"; fi
done

echo
echo "== [C1.3] criar configs mínimos (idempotente) =="
sudo docker exec p003-os bash -c '
if [ ! -f /etc/neutron/plugins/ml2/openvswitch_agent.ini ]; then
  printf "%s\n" \
    "[ovs]" \
    "integration_bridge = br-int" \
    "tunnel_bridge = br-tun" \
    "bridge_mappings = public:br-ex" \
    "[agent]" \
    "tunnel_types =" \
    "[securitygroup]" \
    "firewall_driver = openvswitch" \
    "enable_security_group = True" \
    > /etc/neutron/plugins/ml2/openvswitch_agent.ini
  chown stack:stack /etc/neutron/plugins/ml2/openvswitch_agent.ini
  echo "  criado openvswitch_agent.ini"
else
  echo "  openvswitch_agent.ini já existe"
fi
if [ ! -f /etc/neutron/dhcp_agent.ini ]; then
  printf "%s\n" \
    "[DEFAULT]" \
    "interface_driver = openvswitch" \
    "enable_isolated_metadata = False" \
    > /etc/neutron/dhcp_agent.ini
  chown stack:stack /etc/neutron/dhcp_agent.ini
  echo "  criado dhcp_agent.ini"
else
  echo "  dhcp_agent.ini já existe"
fi
if [ ! -f /etc/neutron/l3_agent.ini ]; then
  printf "%s\n" \
    "[DEFAULT]" \
    "interface_driver = openvswitch" \
    "agent_mode = legacy" \
    > /etc/neutron/l3_agent.ini
  chown stack:stack /etc/neutron/l3_agent.ini
  echo "  criado l3_agent.ini"
else
  echo "  l3_agent.ini já existe"
fi
echo "  --- conteúdo:"
for f in /etc/neutron/plugins/ml2/openvswitch_agent.ini /etc/neutron/dhcp_agent.ini /etc/neutron/l3_agent.ini; do
  echo "  [$f]"; grep -vE "^\s*(#|$)" "$f" | sed "s/^/    /"
done'

echo
echo "== [C1.3] subir agentes (stack, nohup, </dev/null) =="
sudo docker exec p003-os bash -c 'pgrep -f neutron-openvswitch-agent >/dev/null || sudo -u stack bash -c "nohup /opt/stack/data/venv/bin/neutron-openvswitch-agent --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini >/opt/stack/logs/q-agt.log 2>&1 &" </dev/null; echo "  q-agt lançado"'
sudo docker exec p003-os bash -c 'pgrep -f neutron-dhcp-agent >/dev/null || sudo -u stack bash -c "nohup /opt/stack/data/venv/bin/neutron-dhcp-agent --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/dhcp_agent.ini --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini >/opt/stack/logs/q-dhcp.log 2>&1 &" </dev/null; echo "  q-dhcp lançado"'
sudo docker exec p003-os bash -c 'pgrep -f neutron-l3-agent >/dev/null || sudo -u stack bash -c "nohup /opt/stack/data/venv/bin/neutron-l3-agent --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/l3_agent.ini --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini >/opt/stack/logs/q-l3.log 2>&1 &" </dev/null; echo "  q-l3 lançado"'
echo "  aguardando 30s pelos heartbeats"; sleep 30
sudo docker exec p003-os bash -c 'for a in neutron-openvswitch-agent neutron-dhcp-agent neutron-l3-agent; do printf "  %-28s procs=%s\n" "$a" "$(pgrep -fc $a)"; done'

echo
echo "== [C1.3] aceite: openstack network agent list =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack network agent list 2>&1' | sed 's/^/  /'

echo
echo "== [C1.3] aceite: br-int criado =="
sudo docker exec p003-os bash -c 'ovs-vsctl list-br | sed "s/^/  br: /"; echo "  total: $(ovs-vsctl list-br | wc -l)"'

echo
echo "== [C1.3] logs (tails) =="
sudo docker exec p003-os bash -c 'for l in q-agt q-dhcp q-l3; do echo "  --- $l"; tail -4 /opt/stack/logs/$l.log 2>/dev/null | sed "s/^/    /"; done'

echo
echo "== [C1.3] pós: lab intacto =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
for b in docker0 br-b56f3de1d858 br-97b5ec9007c2 br-b03e3d58a257; do
  printf "  %-20s ports=%s\n" "$b" "$(ip -o link show master "$b" 2>/dev/null | wc -l)"
done
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
