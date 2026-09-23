#!/usr/bin/env bash
# P003-S012 C6 — teardown final da experiência: VM deletada, propriedade
# hw_vif_model revertida, qemus mortos, lab verificado.
set -uo pipefail
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1
timeout 40 openstack image unset --property hw_vif_model cirros-0.6.0 2>/dev/null || timeout 40 openstack image set --property hw_vif_model="" cirros-0.6.0 2>/dev/null; echo "  hw_vif_model revertida"
source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1
for id in $(openstack server list -f value -c ID 2>/dev/null); do timeout 60 openstack server delete $id --wait >/dev/null 2>&1 || timeout 20 openstack server delete $id --force >/dev/null 2>&1; echo "  deleted $id"; done
for d in $(timeout 20 virsh list --all --name 2>/dev/null); do timeout 15 virsh destroy $d >/dev/null 2>&1; timeout 10 virsh undefine $d >/dev/null 2>&1; done
for p in $(pgrep qemu-system); do kill -9 $p 2>/dev/null; done
echo "  servers: $(openstack server list -f value -c ID 2>/dev/null | wc -l)"'
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "canário k01: $c"
for ip in 10.30.1.11 10.30.2.11; do cc=$(sudo /usr/bin/docker exec clab-p003-gw-fabric-client curl -s -o /dev/null -w '%{http_code}' --max-time 8 --noproxy '*' -H 'Host: echo.p003.study' http://$ip:30676/ 2>/dev/null); echo "NodePort $ip -> $cc"; done
echo "containers: $(sudo /usr/bin/docker ps -q | wc -l)"
echo "p003-os mem: $(sudo /usr/bin/docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR==2{print "host available: "$7" GiB"}'
