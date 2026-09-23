#!/usr/bin/env bash
# P003-S012 rodada 2 — TEARDOWN dos recursos de ESTUDO.
# Remove: VMs, pod de probe, rotas de teste (worker2 + host). MANTÉM (infra
# C1 para a próxima rodada, documentado como desvio do rollback genérico):
# net-a/subnet-a/sg-a/r-a/ext-net, br-ex+veth, agentes, nova/glance/placement.
set -uo pipefail

echo "== [1] VMs =="
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1
for id in $(openstack server list -f value -c ID 2>/dev/null); do
  timeout 90 openstack server delete $id --wait >/dev/null 2>&1 || timeout 30 openstack server delete $id --force >/dev/null 2>&1
  echo "  deleted $id"
done
for d in $(timeout 20 virsh list --all --name 2>/dev/null); do timeout 20 virsh destroy $d >/dev/null 2>&1; timeout 20 virsh undefine $d >/dev/null 2>&1; echo "  undef $d"; done
echo "  servers restantes: $(openstack server list -f value -c Name | tr "\n" " ")"'

echo
echo "== [2] pod de probe (sandbox) =="
sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw -n p003-gateway delete pod p003-probe --force --grace-period=0 >/dev/null 2>&1 && echo "  p003-probe removido"

echo
echo "== [3] rotas de teste (worker2 + host) =="
sudo /usr/bin/docker exec p003-gw-worker2 ip route del 10.30.0.0/24 via 172.19.0.1 dev eth0 2>/dev/null && echo "  worker2: rota 10.30.0.0/24 removida" || echo "  worker2: rota já ausente"
sudo /usr/bin/docker exec p003-gw-worker2 ip route del 10.40.0.0/24 via 172.19.0.1 dev eth0 2>/dev/null && echo "  worker2: rota 10.40.0.0/24 removida" || echo "  worker2: rota já ausente"
sudo ip route del 10.30.0.0/24 via 10.40.0.181 dev docker0 2>/dev/null && echo "  host: rota 10.30.0.0/24 removida" || echo "  host: rota já ausente"
sudo /usr/bin/docker exec p003-gw-worker2 ip route | grep -E "10.30.0|10.40.0" || echo "  worker2: limpa"
ip route | grep -E "^10.30.0|^10.40.0" || echo "  host: limpa"

echo
echo "== [4] estado final do lab =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
echo "  k01 nós: $(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get nodes --no-headers 2>/dev/null | awk '{print $2}' | tr '\n' ' ')"
echo "  sandbox nós: $(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get nodes --no-headers 2>/dev/null | awk '{print $2}' | tr '\n' ' ')"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
for ip in 10.30.1.11 10.30.1.12 10.30.2.11; do
  cc=$(sudo /usr/bin/docker exec clab-p003-gw-fabric-client curl -s -o /dev/null -w '%{http_code}' --max-time 8 --noproxy '*' -H 'Host: echo.p003.study' http://$ip:30676/ 2>/dev/null)
  echo "  NodePort $ip -> $cc"
done
for b in docker0 br-b56f3de1d858 br-97b5ec9007c2 br-b03e3d58a257; do
  printf "  %-20s ports=%s\n" "$b" "$(ip -o link show master "$b" 2>/dev/null | wc -l)"
done
echo "  containers: $(sudo /usr/bin/docker ps -q | wc -l)"
echo "  p003-os mem: $(sudo /usr/bin/docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR==2{print "  host available: "$7" GiB"}'
echo
echo "== [5] serviços do testbed que permanecem NO AR =="
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1; echo "  --- agentes:"; openstack network agent list -f value -c "Agent Type" -c Alive 2>/dev/null | sed "s/^/    /"; echo "  --- compute:"; openstack compute service list -f value -c Binary -c State 2>/dev/null | sed "s/^/    /"'
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1; echo "  --- recursos mantidos (infra C1):"; openstack network list -f value -c Name 2>/dev/null | sed "s/^/    net: /"; openstack router list -f value -c Name 2>/dev/null | sed "s/^/    router: /"'
