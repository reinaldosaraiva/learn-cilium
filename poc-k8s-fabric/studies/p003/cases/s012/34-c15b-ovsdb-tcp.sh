#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5b t10: o os_vif do nova-compute fala ovsdb por
# TCP 127.0.0.1:6640 (default) e o ovsdb-server só escutava no socket unix.
# Adicionar o remote TCP em runtime (loopback) e recriar a vm-a.
set -uo pipefail

echo "== [1] ovsdb-server: add-remote tcp:127.0.0.1:6640 =="
sudo docker exec p003-os ovs-appctl -t /var/run/openvswitch/ovsdb-server.ctl ovsdb-server/add-remote "tcp:127.0.0.1:6640" 2>&1 | sed 's/^/  /'
sudo docker exec p003-os bash -c 'ss -ltn 2>/dev/null | grep 6640 | sed "s/^/  /"'
sudo docker exec p003-os bash -c 'timeout 10 ovsdb-client -t 5 dump tcp:127.0.0.1:6640 Open_vSwitch 2>&1 | head -2 | sed "s/^/  client: /"'

echo
echo "== [2] recriar vm-a =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; timeout 90 openstack server delete vm-a --wait >/dev/null 2>&1 || timeout 30 openstack server delete vm-a --force >/dev/null 2>&1; echo "  delete rc=$?"'
sleep 5
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 420 openstack server create vm-a \
  --image cirros-0.6.0 --flavor m1.p003 --network net-a --security-group sg-a \
  --config-drive True --user-data /opt/stack/vm-a-init.sh --wait >/dev/null 2>&1; echo "  create rc=$?"'
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; echo "  status: $(openstack server show vm-a -f value -c status)"; echo "  endereços: $(openstack server show vm-a -f value -c addresses)"'

echo
echo "== [3] se ACTIVE: console (user-data) =="
sleep 20
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 60 openstack console log show vm-a 2>/dev/null | tail -25' | sed 's/^/  /'

echo
echo "== [4] pós: lab intacto + RAM =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR==2{print "  host available: "$7" GiB"}'
