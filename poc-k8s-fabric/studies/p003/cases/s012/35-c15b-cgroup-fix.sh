#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5b t12 (fix cgroup, host-side, reversível):
# scope docker do p003-os tem subtree_control=cpuset,cpu (efeito do --cpus=4)
# + 84 procs no próprio scope -> filhos "domain invalid" -> libvirt/qemu
# ENOTSUP. Mover os procs para <scope>/init/ esvazia o scope, torna os filhos
# válidos e não altera limites (herdados). Escopo: apenas o cgroup do p003-os.
set -uo pipefail

echo "== [1] localizar scope e mover procs =="
CPID=$(sudo docker inspect -f '{{.State.Pid}}' p003-os)
CG=$(awk -F: '/^0::/{print $3}' /proc/$CPID/cgroup)
SCOPE=/sys/fs/cgroup$CG
echo "  scope=$SCOPE"
echo "  antes: subtree=$(cat $SCOPE/cgroup.subtree_control) procs=$(wc -l < $SCOPE/cgroup.procs)"
sudo mkdir -p "$SCOPE/init"
MOVED=0
for p in $(cat "$SCOPE/cgroup.procs"); do
  echo "$p" | sudo tee "$SCOPE/init/cgroup.procs" >/dev/null 2>&1 && MOVED=$((MOVED+1))
done
echo "  movidos: $MOVED"
echo "  depois: procs no scope=$(wc -l < $SCOPE/cgroup.procs) procs em init=$(wc -l < $SCOPE/init/cgroup.procs)"

echo
echo "== [2] validar dentro do container: child agora é 'domain'? =="
sudo docker exec p003-os bash -c 'mkdir /sys/fs/cgroup/machine/t3x 2>/dev/null; echo $$ > /sys/fs/cgroup/machine/t3x/cgroup.procs 2>&1; T=$(cat /sys/fs/cgroup/machine/t3x/cgroup.type 2>/dev/null); P=$(wc -l < /sys/fs/cgroup/machine/t3x/cgroup.procs 2>/dev/null); echo "  type=$T procs=$P"; rmdir /sys/fs/cgroup/machine/t3x 2>/dev/null; echo "  (esperado: type=domain procs>=1)"'

echo
echo "== [3] recriar vm-a =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; timeout 90 openstack server delete vm-a --wait >/dev/null 2>&1 || timeout 30 openstack server delete vm-a --force >/dev/null 2>&1; echo "  delete rc=$?"; sleep 5; timeout 420 openstack server create vm-a \
  --image cirros-0.6.0 --flavor m1.p003 --network net-a --security-group sg-a \
  --config-drive True --user-data /opt/stack/vm-a-init.sh --wait >/dev/null 2>&1; echo "  create rc=$?"; echo "  status: $(openstack server show vm-a -f value -c status)"; echo "  endereços: $(openstack server show vm-a -f value -c addresses)"'

echo
echo "== [4] se ACTIVE: console (user-data + responder) =="
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
