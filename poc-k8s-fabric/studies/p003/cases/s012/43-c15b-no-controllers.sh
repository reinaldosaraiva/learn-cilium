#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5b t16 (última): qemu.conf cgroup_controllers = []
# → libvirt não re-habilita subtree_control na raiz do namespace cgroup.
set -uo pipefail
CPID=$(sudo /usr/bin/docker inspect -f '{{.State.Pid}}' p003-os)
CG=$(awk -F: '/^0::/{print $3}' /proc/$CPID/cgroup)
SCOPE=/sys/fs/cgroup$CG

echo "== [1] qemu.conf sem controllers =="
sudo /usr/bin/docker exec p003-os bash -c 'grep -q "^cgroup_controllers" /etc/libvirt/qemu.conf || printf "\ncgroup_controllers = [ ]\n" >> /etc/libvirt/qemu.conf; tail -3 /etc/libvirt/qemu.conf | sed "s/^/  /"'

echo "== [2] restart libvirtd + limpar subtree =="
sudo /usr/bin/docker exec p003-os bash -c 'for p in $(pgrep -x libvirtd); do kill -9 $p 2>/dev/null; done; sleep 2; /usr/sbin/libvirtd -d; sleep 6; pgrep -cx libvirtd' | sed 's/^/  libvirtd: /'
sudo bash -c "echo '-cpuset -cpu' > $SCOPE/cgroup.subtree_control" 2>/dev/null || true
echo "  subtree: [$(cat $SCOPE/cgroup.subtree_control)]"

echo
echo "== [3] criar vm-a =="
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; timeout 90 openstack server delete vm-a --wait >/dev/null 2>&1 || timeout 30 openstack server delete vm-a --force >/dev/null 2>&1; echo "  delete rc=$?"; sleep 3; timeout 420 openstack server create vm-a \
  --image cirros-0.6.0 --flavor m1.p003 --network net-a --security-group sg-a \
  --config-drive True --user-data /opt/stack/vm-a-init.sh --wait >/dev/null 2>&1; echo "  create rc=$?"; echo "  status: $(openstack server show vm-a -f value -c status)"; echo "  endereços: $(openstack server show vm-a -f value -c addresses)"'
echo "  subtree pós: [$(cat $SCOPE/cgroup.subtree_control)]"

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
