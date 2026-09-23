#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5b t9 (bind): net-a = segmento GENEVE (tenant type
# default) e o agente estava com tunnel_types vazio e sem local_ip -> o agente
# rejeitava o bind (PortBindingFailed). Fix: tunnel_types=geneve + local_ip,
# restart q-agt, recriar vm-a.
set -uo pipefail

echo "== [1] ajustar openvswitch_agent.ini (tunnel_types + local_ip) =="
sudo docker exec p003-os bash -c '
sed -i "s/^tunnel_types =$/tunnel_types = geneve/" /etc/neutron/plugins/ml2/openvswitch_agent.ini
grep -q "^local_ip" /etc/neutron/plugins/ml2/openvswitch_agent.ini || sed -i "/^ovsdb_connection/a local_ip = 172.17.0.2" /etc/neutron/plugins/ml2/openvswitch_agent.ini
grep -vE "^\s*(#|$)" /etc/neutron/plugins/ml2/openvswitch_agent.ini | sed "s/^/  /"'

echo
echo "== [2] restart do q-agt =="
PIDS=$(sudo docker exec p003-os bash -c "ps -eo pid,args | grep \"[n]eutron-openvswitch-agent\" | awk '{print \$1}'")
for p in $PIDS; do sudo docker exec p003-os kill -9 "$p" 2>/dev/null && echo "  killed $p"; done
sleep 2
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/neutron-openvswitch-agent \
  --config-file /etc/neutron/neutron.conf \
  --config-file /etc/neutron/plugins/ml2/ml2_conf.ini \
  --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini \
  --log-file /opt/stack/logs/q-agt.log
echo "  q-agt relançado; aguardando 40s"; sleep 40
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack network agent list 2>&1' | sed 's/^/  /'

echo
echo "== [3] recriar vm-a =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; timeout 90 openstack server delete vm-a --wait >/dev/null 2>&1 || timeout 30 openstack server delete vm-a --force >/dev/null 2>&1; echo "  delete rc=$?"'
sleep 5
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 420 openstack server create vm-a \
  --image cirros-0.6.0 --flavor m1.p003 --network net-a --security-group sg-a \
  --config-drive True --user-data /opt/stack/vm-a-init.sh --wait >/dev/null 2>&1; echo "  create rc=$?"'
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; echo "  status: $(openstack server show vm-a -f value -c status)"; echo "  endereços: $(openstack server show vm-a -f value -c addresses)"'

echo
echo "== [4] pós: lab intacto + RAM =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR==2{print "  host available: "$7" GiB"}'
