#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5b t17: o evento network-vif-plugged CHEGOU e foi
# completado, mas após o timeout de 300s do nova (agent rpc_loop lento com
# backoffs inflados da era sem RPC server). vif_plugging_timeout=600 + destroy
# do domínio zumbi + recriação da vm-a.
set -uo pipefail

echo "== [1] vif_plugging_timeout=600 no nova.conf + restart n-cpu =="
sudo /usr/bin/docker exec p003-os bash -c 'grep -q "^vif_plugging_timeout" /etc/nova/nova.conf || sed -i "/^\[neutron\]/a vif_plugging_timeout = 600" /etc/nova/nova.conf; grep -n "vif_plugging_timeout" /etc/nova/nova.conf | sed "s/^/  /"'
PIDS=$(sudo /usr/bin/docker exec p003-os bash -c "ps -eo pid,args | grep \"[n]ova-compute\" | grep -vE \"grep|uwsgi\" | awk '{print \$1}'")
for p in $PIDS; do sudo /usr/bin/docker exec p003-os kill -9 "$p" 2>/dev/null; done
sleep 2
sudo /usr/bin/docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-compute --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-cpu.log
echo "  n-cpu relançado"

echo
echo "== [2] limpar domínio zumbi e instância =="
sudo /usr/bin/docker exec p003-os bash -c 'timeout 25 virsh destroy instance-00000010 2>/dev/null; timeout 25 virsh undefine instance-00000010 2>/dev/null; echo "  virsh rc=$?"; source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; timeout 90 openstack server delete vm-a --wait >/dev/null 2>&1 || timeout 30 openstack server delete vm-a --force >/dev/null 2>&1; echo "  delete rc=$?"'

echo "== [3] aguardar 75s (registro do n-cpu) e criar =="
sleep 75
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 500 openstack server create vm-a \
  --image cirros-0.6.0 --flavor m1.p003 --network net-a --security-group sg-a \
  --config-drive True --user-data /opt/stack/vm-a-init.sh --wait >/dev/null 2>&1; echo "  create rc=$?"; echo "  status: $(openstack server show vm-a -f value -c status)"; echo "  endereços: $(openstack server show vm-a -f value -c addresses)"'

echo
echo "== [4] console se ACTIVE =="
sleep 30
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 60 openstack console log show vm-a 2>/dev/null | tail -20' | sed 's/^/  /'

echo
echo "== [5] pós: lab intacto + RAM =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo /usr/bin/docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR==2{print "  host available: "$7" GiB"}'
