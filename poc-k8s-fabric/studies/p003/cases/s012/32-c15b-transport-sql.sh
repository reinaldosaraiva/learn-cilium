#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5b t8 (unificação definitiva via SQL):
# vhost nova_cell1 não tem NENHUMA fila → casts do conductor (build_and_run)
# são dropados; instância presa em scheduling/host=NULL. update_cell falhou
# silenciosamente 2x; aplicar transport_url do vhost "/" direto no
# nova_api.cell_mappings, restart do trio, recriar vm-a.
set -uo pipefail

echo "== [1] SQL: cell1 transport -> vhost / =="
sudo docker exec p003-os bash -c '
APW=$(grep -m1 "^connection = mysql" /etc/nova/nova.conf | sed -E "s|.*//([^:]+):([^@]+)@.*|\2|")
TPW=$(grep -m1 "^transport_url" /etc/nova/nova.conf | sed -E "s|.*:([^:]+)@.*|\1|")
mysql -uroot -p"$APW" -N -e "update nova_api.cell_mappings set transport_url=concat(\"rabbit://stackrabbit:\",\"$TPW\",\"@172.17.0.2:5672//\") where uuid=\"a546a054-fc4b-4bac-a84b-6046810048a5\"" 2>/dev/null && echo "  update ok"
mysql -uroot -p"$APW" -N -e "select uuid, regexp_replace(transport_url, \".*(@|:).*@\", \"***@\") from nova_api.cell_mappings" 2>/dev/null | sed -E "s|//[^@]+@|//***@|" | sed "s/^/  /"'

echo
echo "== [2] restart trio nova =="
for pat in nova-conductor nova-scheduler nova-compute; do
  PIDS=$(sudo docker exec p003-os bash -c "ps -eo pid,args | grep \"$pat\" | grep -vE \"grep|uwsgi\" | awk '{print \$1}'")
  for p in $PIDS; do sudo docker exec p003-os kill -9 "$p" 2>/dev/null; done
done
sleep 2
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-conductor --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-cond.log
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-scheduler --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-sch.log
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-compute --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-cpu.log
echo "  trio relançado; aguardando 55s"; sleep 55

echo
echo "== [3] filas do vhost / com consumidor (esperado nova-*) =="
sudo docker exec p003-os bash -c 'timeout 60 rabbitmqctl list_queues name consumers 2>/dev/null | grep -E "nova" | head -8 | sed "s/^/  /"'

echo
echo "== [4] limpar vm-a presa e recriar =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1
timeout 90 openstack server delete vm-a --wait >/dev/null 2>&1 && echo "  delete ok" || { timeout 30 openstack server delete vm-a --force >/dev/null 2>&1; echo "  delete force rc=$?"; sleep 8; }'
sleep 5
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 420 openstack server create vm-a \
  --image cirros-0.6.0 --flavor m1.p003 --network net-a --security-group sg-a \
  --config-drive True --user-data /opt/stack/vm-a-init.sh --wait >/dev/null 2>&1; echo "  create rc=$?"'
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; echo "  status: $(openstack server show vm-a -f value -c status)"; echo "  endereços: $(openstack server show vm-a -f value -c addresses)"'

echo
echo "== [5] pós: lab intacto + RAM =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR==2{print "  host available: "$7" GiB"}'
