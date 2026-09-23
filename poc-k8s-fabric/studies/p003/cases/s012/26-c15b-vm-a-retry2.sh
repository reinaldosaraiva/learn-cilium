#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5b t3: RT já gravou o compute_node (log confirma);
# re-executar discover_hosts -> list_hosts -> recriar vm-a.
set -uo pipefail

echo "== [1] discover_hosts (t2) =="
sudo docker exec p003-os bash -c 'sudo -u stack /opt/stack/data/venv/bin/nova-manage cell_v2 discover_hosts 2>&1 | grep -aE "Added|Found|ERROR|error" | head -3 | sed "s/^/  /"'
sudo docker exec p003-os bash -c 'sudo -u stack /opt/stack/data/venv/bin/nova-manage cell_v2 list_hosts 2>&1 | grep -aE "^\|" | sed "s/^/  /"'

echo
echo "== [2] recriar vm-a =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 60 openstack server delete vm-a --wait 2>/dev/null; echo "  delete rc=$?"'
sleep 3
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 300 openstack server create vm-a \
  --image cirros-0.6.0 --flavor m1.p003 --network net-a --security-group sg-a \
  --config-drive True --user-data /opt/stack/vm-a-init.sh --wait >/dev/null 2>&1; echo "  create rc=$?"'
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; echo "  status: $(openstack server show vm-a -f value -c status)"; echo "  endereços: $(openstack server show vm-a -f value -c addresses)"; openstack server show vm-a -f value -c fault 2>/dev/null | head -1 | sed "s/^/  fault: /"'

echo
echo "== [3] se ACTIVE: porta/IP da VM =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack port list --server vm-a -f value -c Name -c "Fixed IP Addresses" -c MAC_Address 2>&1' | sed 's/^/  /'

echo
echo "== [4] pós: lab intacto + RAM =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR==2{print "  host available: "$7" GiB"}'
