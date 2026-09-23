#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5b t5 (fix definitivo do split-brain):
# stack.sh interrompido deixou [database]=nova_cell0 no nova.conf; o final
# correto é nova_cell1 (nome de cell1 DB do devstack moderno). Ajustar
# nova.conf + cell mapping -> nova_cell1, restart cond/sch/cpu, rediscover,
# recriar vm-a.
set -uo pipefail

echo "== [1] DB atual do cell1 mapping (nome apenas) =="
sudo docker exec p003-os bash -c 'PW=$(grep -m1 "^connection = mysql" /etc/nova/nova.conf | sed -E "s|.*//([^:]+):([^@]+)@.*|\2|"); mysql -uroot -p"$PW" -N -e "select uuid, regexp_replace(database_connection, \"^.*:.*@\", \"\") from nova_api.cell_mappings" 2>/dev/null | sed "s/^/  /"'

echo
echo "== [2] corrigir [database] do nova.conf -> nova_cell1 =="
sudo docker exec p003-os bash -c '
sed -i "0,/^connection = mysql/s|/nova_cell0?|/nova_cell1?|" /etc/nova/nova.conf
grep -E "^connection" /etc/nova/nova.conf | sed -E "s|//[^:]+:[^@]+@|//***:***@|" | sed "s/^/  /"'
echo "  nova_cell1.compute_nodes: $(sudo docker exec p003-os bash -c 'PW=$(grep -m1 "^connection = mysql" /etc/nova/nova.conf | sed -E "s|.*//([^:]+):([^@]+)@.*|\2|"); mysql -uroot -p"$PW" -N -e "select count(*) from nova_cell1.compute_nodes" 2>/dev/null')"

echo
echo "== [3] cell1 mapping -> nova_cell1 (reverter cell0 se meu update mexeu) =="
sudo docker exec p003-os bash -c '
URL=$(grep -m1 "^connection = mysql" /etc/nova/nova.conf | cut -d" " -f3)
CELL=$(sudo -u stack /opt/stack/data/venv/bin/nova-manage cell_v2 list_cells 2>/dev/null | grep " cell1 " | awk "{print \$2}")
sudo -u stack /opt/stack/data/venv/bin/nova-manage cell_v2 update_cell --cell_uuid "$CELL" --database_connection "$URL" 2>&1 | grep -aiE "update|error" | head -1 | sed "s/^/  /"
mysql -uroot -p"$(grep -m1 "^connection = mysql" /etc/nova/nova.conf | cut -d" " -f3 | sed -E "s|.*/([^/?]+)(\?.*)?$|\1|")" -N -e "select 1" >/dev/null 2>&1 || true'

echo
echo "== [4] restart conductor + scheduler + compute =="
for pat in nova-conductor nova-scheduler nova-compute; do
  PIDS=$(sudo docker exec p003-os bash -c "ps -eo pid,args | grep \"[m]aster process.*$pat\" | awk '{print \$1}'; ps -eo pid,args | grep \"$pat\" | grep ServiceWrapper | awk '{print \$1}'")
  for p in $PIDS; do sudo docker exec p003-os kill -9 "$p" 2>/dev/null && echo "  killed $pat $p"; done
done
sleep 2
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-conductor --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-cond.log
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-scheduler --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-sch.log
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-compute --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-cpu.log
echo "  relançados; aguardando 75s (RT + registro)"; sleep 75

echo
echo "== [5] rediscover + list_hosts =="
sudo docker exec p003-os bash -c 'sudo -u stack /opt/stack/data/venv/bin/nova-manage cell_v2 discover_hosts 2>/dev/null | grep -a "Added" | head -2 | sed "s/^/  /"'
sudo docker exec p003-os bash -c 'sudo -u stack /opt/stack/data/venv/bin/nova-manage cell_v2 list_hosts 2>/dev/null | grep -aE "^\|" | sed "s/^/  /"'
sudo docker exec p003-os bash -c 'PW=$(grep -m1 "^connection = mysql" /etc/nova/nova.conf | sed -E "s|.*//([^:]+):([^@]+)@.*|\2|"); mysql -uroot -p"$PW" -N -e "select count(*) from nova_cell1.compute_nodes" 2>/dev/null' | sed 's/^/  nova_cell1.compute_nodes: /'

echo
echo "== [6] recriar vm-a =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 60 openstack server delete vm-a --wait 2>/dev/null; echo "  delete rc=$?"'
sleep 3
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 300 openstack server create vm-a \
  --image cirros-0.6.0 --flavor m1.p003 --network net-a --security-group sg-a \
  --config-drive True --user-data /opt/stack/vm-a-init.sh --wait >/dev/null 2>&1; echo "  create rc=$?"'
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; echo "  status: $(openstack server show vm-a -f value -c status)"; echo "  endereços: $(openstack server show vm-a -f value -c addresses)"; openstack server show vm-a -f value -c fault 2>/dev/null | head -1 | cut -c1-160 | sed "s/^/  fault: /"'

echo
echo "== [7] pós: lab intacto + RAM =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR==2{print "  host available: "$7" GiB"}'
