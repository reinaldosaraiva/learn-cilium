#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5b t4: cell1 aponta para nova_cell1 mas o [database]
# do nova.conf grava em outro DB (compute_nodes=0 em nova_cell1, RT "updated"
# em outro lugar). Repontar o cell1 mapping para o [database] real do nova.conf
# via nova-manage cell_v2 update_cell, rediscover host, recriar vm-a.
set -uo pipefail

echo "== [1] conexões do nova.conf (senha mascarada) =="
sudo docker exec p003-os bash -c 'grep -E "^connection" /etc/nova/nova.conf | sed -E "s|//[^:]+:[^@]+@|//***:***@|" | sed "s/^/  /"'
echo "  nova_cell1.compute_nodes: $(sudo docker exec p003-os bash -c 'PW=$(grep -m1 "^connection = mysql" /etc/nova/nova.conf | sed -E "s|.*//([^:]+):([^@]+)@.*|\2|"); mysql -uroot -p"$PW" -N -e "select count(*) from nova_cell1.compute_nodes" 2>/dev/null')"
DBN=$(sudo docker exec p003-os bash -c 'grep -m1 "^connection = mysql" /etc/nova/nova.conf | sed -E "s|.*/([^/?]+)(\?.*)?$|\1|"')
echo "  [database] aponta para o DB: $DBN"
sudo docker exec p003-os bash -c "PW=\$(grep -m1 '^connection = mysql' /etc/nova/nova.conf | sed -E 's|.*//([^:]+):([^@]+)@.*|\2|'); mysql -uroot -p\"\$PW\" -N -e 'select count(*) from $DBN.compute_nodes' 2>/dev/null" | sed 's/^/  compute_nodes nesse DB: /'

echo
echo "== [2] repontar cell1 para o [database] do nova.conf =="
sudo docker exec p003-os bash -c '
URL=$(grep -m1 "^connection = mysql" /etc/nova/nova.conf | cut -d" " -f3)
CELL=$(sudo -u stack /opt/stack/data/venv/bin/nova-manage cell_v2 list_cells 2>/dev/null | grep " cell1 " | awk "{print \$2}")
if [ -n "$CELL" ] && [ -n "$URL" ]; then
  sudo -u stack /opt/stack/data/venv/bin/nova-manage cell_v2 update_cell --cell_uuid "$CELL" --database_connection "$URL" --transport-url "$(grep -m1 "^transport_url" /etc/nova/nova.conf | cut -d" " -f3)" 2>&1 | grep -aE "updated|error|Error" | head -2 | sed "s/^/  /"
else
  echo "  ERRO: cell=$CELL url=${URL:+presente}"
fi'
sudo docker exec p003-os bash -c 'sudo -u stack /opt/stack/data/venv/bin/nova-manage cell_v2 list_cells 2>/dev/null | grep -aE "^\| (Name|cell1)" | sed -E "s|mysql[^ |]*//[^ |]*|mysql://***|"' | sed 's/^/  /'

echo
echo "== [3] rediscover + list_hosts =="
sudo docker exec p003-os bash -c 'sudo -u stack /opt/stack/data/venv/bin/nova-manage cell_v2 discover_hosts 2>/dev/null | grep -a "Added\|Got" | head -2 | sed "s/^/  /"'
sudo docker exec p003-os bash -c 'sudo -u stack /opt/stack/data/venv/bin/nova-manage cell_v2 list_hosts 2>/dev/null | grep -aE "^\|" | sed "s/^/  /"'

echo
echo "== [4] recriar vm-a =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 60 openstack server delete vm-a --wait 2>/dev/null; echo "  delete rc=$?"'
sleep 3
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 300 openstack server create vm-a \
  --image cirros-0.6.0 --flavor m1.p003 --network net-a --security-group sg-a \
  --config-drive True --user-data /opt/stack/vm-a-init.sh --wait >/dev/null 2>&1; echo "  create rc=$?"'
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; echo "  status: $(openstack server show vm-a -f value -c status)"; echo "  endereços: $(openstack server show vm-a -f value -c addresses)"; openstack server show vm-a -f value -c fault 2>/dev/null | head -1 | cut -c1-160 | sed "s/^/  fault: /"'

echo
echo "== [5] pós: lab intacto + RAM =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR==2{print "  host available: "$7" GiB"}'
