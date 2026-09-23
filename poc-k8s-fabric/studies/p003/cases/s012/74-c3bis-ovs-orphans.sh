#!/usr/bin/env bash
# P003-S012 C3-bis — limpar portas OVS órfãs do netns antigo (qr-/qg-/tap/sg-)
# e netns velhos; restart dos agentes; verificação.
set -uo pipefail

echo "== [1] portas órfãs no ovsdb =="
sudo docker exec p003-os bash -c '
for br in br-int br-ex; do
  for p in $(ovs-vsctl list-ports $br 2>/dev/null); do
    case "$p" in
      qr-*|qg-*|tap*|sg-*|spoof-*) ovs-vsctl --if-exists del-port $br $p 2>/dev/null && echo "  del $br/$p" ;;
    esac
  done
done
echo "  br-int: [$(ovs-vsctl list-ports br-int | tr "\n" " ")]"
echo "  br-ex:  [$(ovs-vsctl list-ports br-ex | tr "\n" " ")]"
ip netns del qrouter-a77bae40-64db-4d0d-a185-0874ed826414 2>/dev/null && echo "  qrouter ns del"
ip netns del qdhcp-53fbc2f6-b2de-427e-8145-5bb48bc895be 2>/dev/null && echo "  qdhcp ns del"'

echo
echo "== [2] restart agentes =="
sudo docker exec p003-os bash -c 'for pat in neutron-openvswitch-agent neutron-dhcp-agent neutron-l3-agent; do
  PIDS=$(ps -eo pid,args | grep "$pat" | grep -vE "grep|uwsgi" | awk "{print \$1}")
  for p in $PIDS; do kill -9 $p 2>/dev/null; done
done; sleep 2'
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/neutron-openvswitch-agent \
  --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini \
  --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini --log-file /opt/stack/logs/q-agt.log
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/neutron-dhcp-agent \
  --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/dhcp_agent.ini \
  --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini --log-file /opt/stack/logs/q-dhcp.log
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/neutron-l3-agent \
  --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/l3_agent.ini \
  --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini --log-file /opt/stack/logs/q-l3.log
echo "  aguardando 55s"; sleep 55
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1
timeout 40 openstack network agent list -f value -c "Agent Type" -c Alive 2>&1 | sed "s/^/  ag: /"'
sudo docker exec p003-os bash -c 'ip netns list 2>/dev/null | sed "s/^/  ns: /"; echo "  (vazio = L3/DHCP recriam ao syncar)"'

echo
echo "== [3] logs se ainda mortos =="
sudo docker exec p003-os bash -c 'for l in q-agt q-dhcp q-l3; do echo "--- $l:"; grep -aE "ERROR|Traceback|Connection" /opt/stack/logs/$l.log 2>/dev/null | grep -av "logging_exception\|rate_limit" | tail -3 | cut -c1-150; done' | sed 's/^/  /'
