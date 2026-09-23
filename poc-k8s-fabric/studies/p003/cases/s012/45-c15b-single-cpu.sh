#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5b t18: garantir UM n-cpu com vif_plugging_timeout=600
# e criar a vm-a.
set -uo pipefail
echo "== [1] limpar todos os nova-compute =="
PIDS=$(sudo /usr/bin/docker exec p003-os bash -c "ps -eo pid,args | grep '[n]ova-compute' | grep -vE 'grep|uwsgi' | awk '{print \$1}' | tr '\n' ' '")
echo "  pids: ${PIDS:-nenhum}"
for p in $PIDS; do sudo /usr/bin/docker exec p003-os kill -9 "$p" 2>/dev/null && echo "  killed $p"; done
sleep 2
sudo /usr/bin/docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-compute --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-cpu.log
echo "  um n-cpu relançado; aguardando 75s"; sleep 75
sudo /usr/bin/docker exec p003-os bash -c "ps -eo pid,args | grep '[n]ova-compute' | grep -vE 'grep|uwsgi' | awk '{print \$1}' | wc -l" | sed 's/^/  processo(s): /'

echo
echo "== [2] criar vm-a =="
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; timeout 90 openstack server delete vm-a --wait >/dev/null 2>&1 || timeout 30 openstack server delete vm-a --force >/dev/null 2>&1; echo "  delete rc=$?"; sleep 3; timeout 540 openstack server create vm-a \
  --image cirros-0.6.0 --flavor m1.p003 --network net-a --security-group sg-a \
  --config-drive True --user-data /opt/stack/vm-a-init.sh --wait >/dev/null 2>&1; echo "  create rc=$?"; echo "  status: $(openstack server show vm-a -f value -c status)"; echo "  endereços: $(openstack server show vm-a -f value -c addresses)"'

echo
echo "== [3] console se ACTIVE =="
sleep 30
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 60 openstack console log show vm-a 2>/dev/null | tail -20' | sed 's/^/  /'

echo
echo "== [4] pós: lab intacto + RAM =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo /usr/bin/docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR==2{print "  host available: "$7" GiB"}'
