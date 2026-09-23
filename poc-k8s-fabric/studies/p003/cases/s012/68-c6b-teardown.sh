#!/usr/bin/env bash
# P003-S012 C6b — teardown: VM deletada, cpu_mode revertido (default), lab ok.
set -uo pipefail
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1
for id in $(openstack server list -f value -c ID 2>/dev/null); do timeout 60 openstack server delete $id --wait >/dev/null 2>&1 || timeout 20 openstack server delete $id --force >/dev/null 2>&1; echo "  deleted $id"; done
for d in $(timeout 20 virsh list --all --name 2>/dev/null); do timeout 15 virsh destroy $d >/dev/null 2>&1; timeout 10 virsh undefine $d >/dev/null 2>&1; done
for p in $(pgrep -f "qemu-system.*instance" 2>/dev/null); do kill -9 $p 2>/dev/null; done
sed -i "/^cpu_mode = host-passthrough$/d" /etc/nova/nova.conf
echo "  cpu_mode: $(grep -c "^cpu_mode" /etc/nova/nova.conf) linha(s) (0=default host-model)"'
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "canário k01: $c"
cc=$(sudo /usr/bin/docker exec clab-p003-gw-fabric-client curl -s -o /dev/null -w '%{http_code}' --max-time 8 --noproxy '*' -H 'Host: echo.p003.study' http://10.30.1.11:30676/ 2>/dev/null); echo "NodePort: $cc"
echo "containers: $(sudo /usr/bin/docker ps -q | wc -l)"
echo "mem: $(sudo /usr/bin/docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
