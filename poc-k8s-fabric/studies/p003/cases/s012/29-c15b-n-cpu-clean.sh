#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5b t6: limpar TODOS os nova-compute (o awk escapado
# do comando inline não matou nada e relancei duplicado), subir exatamente UM
# (agora com host mapping presente), recriar vm-a.
set -uo pipefail

echo "== [1] matar todos os nova-compute =="
sudo docker cp - 2>/dev/null || true
PIDS=$(sudo docker exec p003-os bash -c 'ps -eo pid,args | grep -E "[n]ova-compute" | grep -vE "grep|uwsgi" | awk "{print \$1}" | tr "\n" " "')
echo "  pids: $PIDS"
for p in $PIDS; do sudo docker exec p003-os kill -9 "$p" 2>/dev/null && echo "  killed $p"; done
sleep 2
sudo docker exec p003-os bash -c 'ps -eo pid,args | grep -E "[n]ova-compute" | grep -vE "grep|uwsgi" || echo "  limpo"'

echo
echo "== [2] subir UM nova-compute (host mapping existe) =="
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-compute --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-cpu.log
echo "  lançado; aguardando 60s"; sleep 60
sudo docker exec p003-os bash -c 'ps -eo pid,etime,args | grep -E "[n]ova-compute" | grep -vE "grep|uwsgi" | cut -c1-80 | sed "s/^/  /"'
sudo docker exec p003-os bash -c 'grep -a "Host mapping" /opt/stack/logs/n-cpu.log | tail -2 | cut -c1-170 | sed "s/^/  hm: /" || echo "  hm: (sem erros de host mapping)"'

echo
echo "== [3] recriar vm-a (delete --force se presa em BUILD) =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; openstack server show vm-a -f value -c status 2>/dev/null | sed "s/^/  estado antes: /"; timeout 90 openstack server delete vm-a --wait >/dev/null 2>&1 || timeout 30 openstack server delete vm-a --force >/dev/null 2>&1; echo "  delete rc=$?"'
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
