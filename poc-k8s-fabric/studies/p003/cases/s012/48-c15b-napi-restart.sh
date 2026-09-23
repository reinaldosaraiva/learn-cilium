#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5b t21: restart do nova-api uwsgi (subiu ANTES da
# unificação do vhost do cell1; casts external-event iam para o vhost morto).
# + limpeza de domínios zumbis + recriação da vm-a.
set -uo pipefail

echo "== [1] restart n-api uwsgi =="
APIDS=$(sudo /usr/bin/docker exec p003-os bash -c "ps -eo pid,args | grep '[p]rocname-prefix nova-api' | grep -v grep | awk '{print \$1}' | tr '\n' ' '")
echo "  pids: $APIDS"
for p in $APIDS; do sudo /usr/bin/docker exec p003-os kill -9 "$p" 2>/dev/null; done
sleep 3
sudo /usr/bin/docker exec p003-os bash -c 'sudo -u stack bash -c "nohup /opt/stack/data/venv/bin/uwsgi --procname-prefix nova-api --ini /etc/nova/nova-api-uwsgi.ini --venv /opt/stack/data/venv >/opt/stack/logs/n-api.log 2>&1 &" </dev/null'
echo "  n-api relançado; aguardando 25s"; sleep 25
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack compute service list 2>&1 | head -4' | sed 's/^/  /'

echo
echo "== [2] limpar domínios zumbis e instâncias antigas =="
sudo /usr/bin/docker exec p003-os bash -c 'for d in $(timeout 20 virsh list --all --name 2>/dev/null); do timeout 20 virsh destroy $d 2>/dev/null; timeout 20 virsh undefine $d 2>/dev/null; echo "  undefine $d"; done; source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; timeout 90 openstack server delete vm-a --wait >/dev/null 2>&1 || timeout 30 openstack server delete vm-a --force >/dev/null 2>&1; echo "  delete rc=$?"'

echo
echo "== [3] criar vm-a =="
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; sleep 3; timeout 560 openstack server create vm-a \
  --image cirros-0.6.0 --flavor m1.p003 --network net-a --security-group sg-a \
  --config-drive True --user-data /opt/stack/vm-a-init.sh --wait >/dev/null 2>&1; echo "  create rc=$?"; echo "  status: $(openstack server show vm-a -f value -c status)"; echo "  endereços: $(openstack server show vm-a -f value -c addresses)"' &
for i in $(seq 1 19); do
  sleep 30
  ST=$(sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && openstack server show vm-a -f value -c status 2>/dev/null')
  echo "  t$((i*30))s: ${ST:-?}"
  if [ "$ST" = "ACTIVE" ] || [ "$ST" = "ERROR" ]; then break; fi
done
wait 2>/dev/null
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; echo "  final: $(openstack server show vm-a -f value -c status 2>/dev/null)"; echo "  addr: $(openstack server show vm-a -f value -c addresses 2>/dev/null)"'

echo
echo "== [4] console se ACTIVE =="
sleep 35
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 60 openstack console log show vm-a 2>/dev/null | tail -18' | sed 's/^/  /'

echo
echo "== [5] pós: lab intacto + RAM =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo /usr/bin/docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR==2{print "  host available: "$7" GiB"}'
