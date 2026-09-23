#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5b t14: dockerd re-habilita subtree=cpuset,cpu no
# scope (reconcile do --cpus=4) → filhos domain invalid de novo. Remover o
# limite de CPU do container em runtime (docker update) faz dockerd parar de
# reivindicar o controller. Cap de MEMÓRIA 8G permanece (proteção principal).
# Reversível: docker update --cpus=4 (registrado para o teardown).
set -uo pipefail
CPID=$(sudo /usr/bin/docker inspect -f '{{.State.Pid}}' p003-os)
CG=$(awk -F: '/^0::/{print $3}' /proc/$CPID/cgroup)
SCOPE=/sys/fs/cgroup$CG

echo "== [1] remover limite de CPU do p003-os (memória 8G permanece) =="
sudo /usr/bin/docker update --cpu-quota 0 --cpu-period 100000 p003-os 2>&1 | sed 's/^/  /'
sudo /usr/bin/docker update --cpus 0 p003-os 2>&1 | sed 's/^/  (cpus 0: /' | head -1
echo "  espera 45s (reconcile do dockerd)"; sleep 45
echo "  subtree agora: [$(cat $SCOPE/cgroup.subtree_control)]"
echo "  mem limit intacto: $(sudo /usr/bin/docker inspect -f '{{.HostConfig.Memory}}' p003-os)"
echo "  cpus config: $(sudo /usr/bin/docker inspect -f '{{.HostConfig.NanoCpus}}' p003-os)"

echo
echo "== [2] child válido agora? =="
sudo /usr/bin/docker exec p003-os bash -c 'mkdir /sys/fs/cgroup/machine/t7x 2>/dev/null; echo $$ > /sys/fs/cgroup/machine/t7x/cgroup.procs 2>/dev/null; echo "  type=$(cat /sys/fs/cgroup/machine/t7x/cgroup.type) procs=$(wc -l < /sys/fs/cgroup/machine/t7x/cgroup.procs 2>/dev/null)"; echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null; rmdir /sys/fs/cgroup/machine/t7x 2>/dev/null'

echo
echo "== [3] recriar vm-a =="
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; timeout 90 openstack server delete vm-a --wait >/dev/null 2>&1 || timeout 30 openstack server delete vm-a --force >/dev/null 2>&1; echo "  delete rc=$?"; sleep 5; timeout 420 openstack server create vm-a \
  --image cirros-0.6.0 --flavor m1.p003 --network net-a --security-group sg-a \
  --config-drive True --user-data /opt/stack/vm-a-init.sh --wait >/dev/null 2>&1; echo "  create rc=$?"; echo "  status: $(openstack server show vm-a -f value -c status)"; echo "  endereços: $(openstack server show vm-a -f value -c addresses)"'

echo
echo "== [4] console se ACTIVE =="
sleep 25
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 60 openstack console log show vm-a 2>/dev/null | tail -20' | sed 's/^/  /'

echo
echo "== [5] pós: lab intacto + RAM =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo /usr/bin/docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR==2{print "  host available: "$7" GiB"}'
