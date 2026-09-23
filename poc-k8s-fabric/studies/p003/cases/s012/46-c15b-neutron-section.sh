#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5b t19: vif_plugging_timeout na seção [neutron]
# (a linha existente estava em [DEFAULT] e era ignorada — wait efetivo 300s).
# + restart do q-agt (zera backoffs) e do n-cpu.
set -uo pipefail

echo "== [1] vif_plugging_timeout=600 sob [neutron] =="
sudo /usr/bin/docker exec p003-os bash -c '
if ! awk "/^\[neutron\]/{f=1} f && /^vif_plugging_timeout/{found=1} END{exit !found}" /etc/nova/nova.conf; then
  sed -i "/^\[neutron\]/a vif_plugging_timeout = 600" /etc/nova/nova.conf
  echo "  adicionado sob [neutron]"
fi
awk "/^\[neutron\]/{f=1} f&&/^vif_plugging/{print \"  [neutron]: \" \$0} f&&/^\[/{if(\$0!=\"[neutron]\")f=0}" /etc/nova/nova.conf'

echo
echo "== [2] restart q-agt + n-cpu =="
APIDS=$(sudo /usr/bin/docker exec p003-os bash -c "ps -eo pid,args | grep '[n]eutron-openvswitch-agent' | awk '{print \$1}' | tr '\n' ' '")
for p in $APIDS; do sudo /usr/bin/docker exec p003-os kill -9 "$p" 2>/dev/null; done
sudo /usr/bin/docker exec -d -u stack p003-os /opt/stack/data/venv/bin/neutron-openvswitch-agent \
  --config-file /etc/neutron/neutron.conf \
  --config-file /etc/neutron/plugins/ml2/ml2_conf.ini \
  --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini \
  --log-file /opt/stack/logs/q-agt.log
CPIDS=$(sudo /usr/bin/docker exec p003-os bash -c "ps -eo pid,args | grep '[n]ova-compute' | grep -vE 'grep|uwsgi' | awk '{print \$1}' | tr '\n' ' '")
for p in $CPIDS; do sudo /usr/bin/docker exec p003-os kill -9 "$p" 2>/dev/null; done
sleep 2
sudo /usr/bin/docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-compute --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-cpu.log
echo "  aguardando 75s"; sleep 75

echo
echo "== [3] limpar e criar vm-a =="
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; timeout 90 openstack server delete vm-a --wait >/dev/null 2>&1 || timeout 30 openstack server delete vm-a --force >/dev/null 2>&1; echo "  delete rc=$?"; sleep 3; timeout 560 openstack server create vm-a \
  --image cirros-0.6.0 --flavor m1.p003 --network net-a --security-group sg-a \
  --config-drive True --user-data /opt/stack/vm-a-init.sh --wait >/dev/null 2>&1; echo "  create rc=$?"; echo "  status: $(openstack server show vm-a -f value -c status)"; echo "  endereços: $(openstack server show vm-a -f value -c addresses)"' &
CREATE_PID=$!
# poll em paralelo para não perder por timeout do ssh
for i in $(seq 1 18); do
  sleep 30
  ST=$(sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && openstack server show vm-a -f value -c status 2>/dev/null')
  echo "  t$((i*30))s: ${ST:-?}"
  if [ "$ST" = "ACTIVE" ] || [ "$ST" = "ERROR" ]; then break; fi
done
wait $CREATE_PID 2>/dev/null
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; echo "  final: $(openstack server show vm-a -f value -c status)"; echo "  addr: $(openstack server show vm-a -f value -c addresses)"'

echo
echo "== [4] console se ACTIVE =="
sleep 30
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 60 openstack console log show vm-a 2>/dev/null | tail -18' | sed 's/^/  /'

echo
echo "== [5] pós: lab intacto + RAM =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo /usr/bin/docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR==2{print "  host available: "$7" GiB"}'
