#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5b t15 (última tentativa deste passo):
# com --cpus=0 aplicado, desligar subtree_control e verificar se o dockerd
# ainda re-habilita. Se permanecer vazio por 60s, criar a VM na sequência.
set -uo pipefail
CPID=$(sudo /usr/bin/docker inspect -f '{{.State.Pid}}' p003-os)
CG=$(awk -F: '/^0::/{print $3}' /proc/$CPID/cgroup)
SCOPE=/sys/fs/cgroup$CG

echo "== [1] desligar subtree e observar 60s =="
sudo bash -c "echo '-cpuset -cpu' > $SCOPE/cgroup.subtree_control"
echo "  t0:  [$(cat $SCOPE/cgroup.subtree_control)]"
sleep 60
ST=$(cat $SCOPE/cgroup.subtree_control)
echo "  t60: [$ST]"
if [ -n "$ST" ]; then
  echo "  dockerd re-habilitou — caminho bloqueado sem recriar container"
  exit 3
fi

echo
echo "== [2] child válido =="
sudo /usr/bin/docker exec p003-os bash -c 'mkdir /sys/fs/cgroup/machine/t8x 2>/dev/null; echo $$ > /sys/fs/cgroup/machine/t8x/cgroup.procs 2>/dev/null; echo "  type=$(cat /sys/fs/cgroup/machine/t8x/cgroup.type) procs=$(wc -l < /sys/fs/cgroup/machine/t8x/cgroup.procs 2>/dev/null)"; echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null; rmdir /sys/fs/cgroup/machine/t8x 2>/dev/null'

echo
echo "== [3] criar vm-a imediatamente =="
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; timeout 90 openstack server delete vm-a --wait >/dev/null 2>&1 || timeout 30 openstack server delete vm-a --force >/dev/null 2>&1; echo "  delete rc=$?"; sleep 3; timeout 420 openstack server create vm-a \
  --image cirros-0.6.0 --flavor m1.p003 --network net-a --security-group sg-a \
  --config-drive True --user-data /opt/stack/vm-a-init.sh --wait >/dev/null 2>&1; echo "  create rc=$?"; echo "  status: $(openstack server show vm-a -f value -c status)"; echo "  endereços: $(openstack server show vm-a -f value -c addresses)"'
echo "  subtree pós-create: [$(cat $SCOPE/cgroup.subtree_control)]"

echo
echo "== [4] console se ACTIVE =="
sleep 30
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 60 openstack console log show vm-a 2>/dev/null | tail -20' | sed 's/^/  /'

echo
echo "== [5] pós: lab intacto + RAM =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo /usr/bin/docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR==2{print "  host available: "$7" GiB"}'
