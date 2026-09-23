#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5b t13: esvaziar subtree_control do scope docker
# (desliga delegação cpu/cpuset aos filhos; limites do scope permanecem).
# Sem a violação no-internal-process, filhos voltam a ser domain válidos e o
# libvirt consegue criar o cgroup da VM e mover o qemu para dentro.
set -uo pipefail

CPID=$(sudo docker inspect -f '{{.State.Pid}}' p003-os)
CG=$(awk -F: '/^0::/{print $3}' /proc/$CPID/cgroup)
SCOPE=/sys/fs/cgroup$CG

echo "== [1] desligar subtree_control do scope =="
echo "  antes: $(cat $SCOPE/cgroup.subtree_control)"
sudo bash -c "echo '-cpuset -cpu' > $SCOPE/cgroup.subtree_control" 2>&1 | sed 's/^/  err: /'
echo "  depois: [$(cat $SCOPE/cgroup.subtree_control)]"

echo
echo "== [2] validar child dentro do container =="
sudo docker exec p003-os bash -c 'mkdir /sys/fs/cgroup/machine/t4x 2>/dev/null; echo $$ > /sys/fs/cgroup/machine/t4x/cgroup.procs 2>&1; T=$(cat /sys/fs/cgroup/machine/t4x/cgroup.type 2>/dev/null); P=$(wc -l < /sys/fs/cgroup/machine/t4x/cgroup.procs 2>/dev/null); echo "  type=$T procs=$P"; rmdir /sys/fs/cgroup/machine/t4x 2>/dev/null'

echo
echo "== [3] recriar vm-a =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; timeout 90 openstack server delete vm-a --wait >/dev/null 2>&1 || timeout 30 openstack server delete vm-a --force >/dev/null 2>&1; echo "  delete rc=$?"; sleep 5; timeout 420 openstack server create vm-a \
  --image cirros-0.6.0 --flavor m1.p003 --network net-a --security-group sg-a \
  --config-drive True --user-data /opt/stack/vm-a-init.sh --wait >/dev/null 2>&1; echo "  create rc=$?"; echo "  status: $(openstack server show vm-a -f value -c status)"; echo "  endereços: $(openstack server show vm-a -f value -c addresses)"'

echo
echo "== [4] console (user-data + responder) =="
sleep 25
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 60 openstack console log show vm-a 2>/dev/null | tail -22' | sed 's/^/  /'

echo
echo "== [5] pós: lab intacto + RAM =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR==2{print "  host available: "$7" GiB"}'
