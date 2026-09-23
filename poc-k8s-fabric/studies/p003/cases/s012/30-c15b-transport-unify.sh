#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5b t7: unificar o vhost de mensageria do cell1.
# Evidência: 92 conexões stackrabbit no vhost "/" e apenas 2 em nova_cell1 —
# os casts do conductor seguem o cell mapping (nova_cell1) e somem sem
# consumidor. Fix: update_cell com transport_url do próprio nova.conf ("/").
set -uo pipefail

echo "== [1] update_cell: transport do cell1 -> vhost do nova.conf =="
sudo docker exec p003-os bash -c '
TURL=$(grep -m1 "^transport_url" /etc/nova/nova.conf | cut -d" " -f3)
CELL=$(sudo -u stack /opt/stack/data/venv/bin/nova-manage cell_v2 list_cells 2>/dev/null | grep " cell1 " | awk "{print \$2}")
echo "  cell=$CELL transport=${TURL%%@*}@***"
sudo -u stack /opt/stack/data/venv/bin/nova-manage cell_v2 update_cell --cell_uuid "$CELL" --transport-url "$TURL" 2>&1 | grep -aiE "update|error" | head -1 | sed "s/^/  /"'
sudo docker exec p003-os bash -c 'sudo -u stack /opt/stack/data/venv/bin/nova-manage cell_v2 list_cells 2>/dev/null | grep -aE "^\| (Name|cell1)" | sed -E "s|//[^@ ]+@|//***@|" | sed "s/^/  /"'

echo
echo "== [2] restart conductor + scheduler + compute =="
for pat in nova-conductor nova-scheduler nova-compute; do
  PIDS=$(sudo docker exec p003-os bash -c "ps -eo pid,args | grep \"$pat\" | grep -vE \"grep|uwsgi\" | awk '{print \$1}'")
  for p in $PIDS; do sudo docker exec p003-os kill -9 "$p" 2>/dev/null && echo "  killed $pat $p"; done
done
sleep 2
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-conductor --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-cond.log
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-scheduler --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-sch.log
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-compute --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-cpu.log
echo "  trio relançado; aguardando 60s"; sleep 60
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack compute service list 2>&1' | sed 's/^/  /'

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
