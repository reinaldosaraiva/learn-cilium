#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5a conclusão: restart do nova-compute (nasceu antes do
# conductor), download da imagem cirros, flavor 1vCPU/2GiB/10GiB, verificação
# de hypervisor + resource provider.
set -uo pipefail

echo "== [1] restart do nova-compute =="
CP=$(sudo docker exec p003-os bash -c 'ps -eo pid,args | grep -E "[n]ova-compute" | grep -vE "grep|uwsgi" | awk "{print \$1}" | tr "\n" " "')
for p in $CP; do sudo docker exec p003-os kill -9 "$p" 2>/dev/null && echo "  killed $p"; done
sleep 2
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-compute --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-cpu.log
echo "  n-cpu relançado; aguardando 50s"; sleep 50
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack compute service list 2>&1' | sed 's/^/  /'
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack hypervisor list 2>&1' | sed 's/^/  /'

echo
echo "== [2] imagem cirros (download + glance) =="
if sudo docker exec p003-os test -f /opt/stack/cirros-0.6.0-x86_64-disk.img; then
  echo "  imagem já baixada"
else
  sudo docker exec p003-os bash -c 'curl -sS --max-time 240 -o /opt/stack/cirros-0.6.0-x86_64-disk.img http://download.cirros-cloud.net/0.6.0/cirros-0.6.0-x86_64-disk.img && ls -la /opt/stack/cirros-0.6.0-x86_64-disk.img | sed "s/^/  /"' || { echo "  FALHOU download"; exit 1; }
fi
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 90 openstack image create --project demo --file /opt/stack/cirros-0.6.0-x86_64-disk.img --disk-format qcow2 --container-format bare --public cirros-0.6.0 2>&1 | grep -E "id|name|status" | head -4' | sed 's/^/  /'
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack image list 2>&1' | sed 's/^/  /'

echo
echo "== [3] flavor m1.p003 (1 vCPU / 2 GiB / 10 GiB) =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack flavor create m1.p003 --id auto --ram 2048 --disk 10 --vcpus 1 --public 2>&1 | grep -E "id|name|ram|disk|vcpus" | head -6' | sed 's/^/  /'
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack flavor list 2>&1' | sed 's/^/  /'

echo
echo "== [4] resource provider (placement) =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack resource provider list 2>&1' | sed 's/^/  /'

echo
echo "== [5] pós: lab intacto + RAM =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR==2{print "  host available: "$7" GiB"}'
