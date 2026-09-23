#!/usr/bin/env bash
# P003-S012 rodada 2 — Emenda C1, fase C1.4: caminho cross-netns.
# 1) kill da probe órfã 9964 (PID explícito).
# 2) br-ex (OVS, netns do container) + veth host<->container (docker0 <-> br-ex).
#    O caminho external fica INTEIRO dentro do netns do container — a NIC do
#    host (ens3) e o k01 não são tocados (restrição herdada de S011).
# 3) relançar q-agt (ele precisa de br-ex existente para não terminar).
# 4) recursos de cloud: rede external flat (physnet public) 10.40.0.0/24 +
#    router demo com gw 10.40.0.1 SEM SNAT.
# 5) prova de L3: ping host<->router, container<->router, worker(com rota de
#    teste)<->router. Rotas de teste no worker são revertidas no teardown.
set -uo pipefail
FAIL=0

echo "== [1] matar probe órfã 9964 (PID explícito) =="
sudo docker exec p003-os kill -9 9964 2>/dev/null && echo "  killed 9964" || echo "  9964 já não existe"
sleep 1
sudo docker exec p003-os bash -c 'ps -eo pid,stat,args | grep -E "[n]eutron-openvswitch" | sed "s/^/  /" || true'

echo
echo "== [2] br-ex + veth cross-netns (idempotente) =="
echo "  [2a] br-ex no netns do container"
sudo docker exec p003-os ovs-vsctl --may-exist add-br br-ex
sudo docker exec p003-os ovs-vsctl br-exists br-ex && echo "  br-ex OK"
CPID=$(sudo docker inspect -f '{{.State.Pid}}' p003-os)
echo "  p003-os pid=$CPID"
echo "  [2b] veth veth-ext0 (host, master docker0) <-> veth-ext1 (container, port br-ex)"
if ! ip link show veth-ext0 >/dev/null 2>&1; then
  sudo ip link add veth-ext0 type veth peer name veth-ext1
  echo "  veth criado"
else
  echo "  veth-ext0 já existe no host"
fi
# peer dentro do container?
IN_C=$(sudo docker exec p003-os ip link show veth-ext1 >/dev/null 2>&1 && echo yes || echo no)
if [ "$IN_C" = "no" ] && ! ip link show veth-ext1 >/dev/null 2>&1; then
  sudo ip link set veth-ext1 netns "$CPID" && echo "  veth-ext1 movido para o netns do container"
elif [ "$IN_C" = "yes" ]; then
  echo "  veth-ext1 já está no container"
fi
sudo ip link set veth-ext0 master docker0 2>/dev/null || true
sudo ip link set veth-ext0 up
sudo docker exec p003-os ip link set veth-ext1 up
sudo docker exec p003-os ovs-vsctl --may-exist add-port br-ex veth-ext1
echo "  portas br-ex: [$(sudo docker exec p003-os ovs-vsctl list-ports br-ex | tr '\n' ' ')]"
echo "  [2c] IPs: container br-ex 10.40.0.2/24; host docker0 10.40.0.250/24"
sudo docker exec p003-os ip addr add 10.40.0.2/24 dev br-ex 2>/dev/null && echo "  10.40.0.2/24 -> br-ex (container)" || echo "  10.40.0.2 já presente"
sudo ip addr add 10.40.0.250/24 dev docker0 2>/dev/null && echo "  10.40.0.250/24 -> docker0 (host)" || echo "  10.40.0.250 já presente"

echo
echo "== [3] relançar q-agt (agora com br-ex existente) =="
QP=$(sudo docker exec p003-os bash -c 'ps -eo pid,stat,args | grep -E "[n]eutron-openvswitch-agent" | awk "{print \$1}" | tr "\n" " "')
for p in $QP; do sudo docker exec p003-os kill -9 "$p" 2>/dev/null; done
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/neutron-openvswitch-agent \
  --config-file /etc/neutron/neutron.conf \
  --config-file /etc/neutron/plugins/ml2/ml2_conf.ini \
  --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini \
  --log-file /opt/stack/logs/q-agt.log
echo "  q-agt relançado; aguardando 45s"; sleep 45
sudo docker exec p003-os bash -c 'ps -eo pid,user,stat,etime,args | grep -E "[n]eutron-openvswitch-agent" | cut -c1-100 | sed "s/^/  /"'
sudo docker exec p003-os bash -c 'tail -3 /opt/stack/logs/q-agt.log | cut -c1-160 | sed "s/^/  log: /"'
echo "  bridges OVS: [$(sudo docker exec p003-os ovs-vsctl list-br | tr '\n' ' ')]"

echo
echo "== [4] agentes registrados no neutron-server? =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack network agent list 2>&1' | sed 's/^/  /'

echo
echo "== [5] rede external + subnet + router demo (sem SNAT) =="
sudo docker exec p003-os bash -c '
source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1
if ! timeout 30 openstack network show ext-net >/dev/null 2>&1; then
  timeout 60 openstack network create ext-net --external --share \
    --provider-physical-network public --provider-network-type flat \
    --description "P003 external net (cross-netns via br-ex)" 2>&1 | tail -2 | sed "s/^/  net: /"
else echo "  ext-net já existe"; fi
if ! timeout 30 openstack subnet show ext-subnet >/dev/null 2>&1; then
  timeout 60 openstack subnet create ext-subnet --network ext-net \
    --subnet-range 10.40.0.0/24 --gateway 10.40.0.1 \
    --allocation-pool start=10.40.0.100,end=10.40.0.200 \
    --no-dhcp --ip-version 4 2>&1 | tail -2 | sed "s/^/  subnet: /"
else echo "  ext-subnet já existe"; fi'
sudo docker exec p003-os bash -c '
source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1
if ! timeout 30 openstack router show r-a >/dev/null 2>&1; then
  timeout 60 openstack router create r-a --project demo 2>&1 | tail -2 | sed "s/^/  router: /"
else echo "  r-a já existe"; fi
timeout 60 openstack router set r-a --external-gateway ext-net --disable-snat \
  --fixed-ip subnet=ext-subnet,ip-address=10.40.0.1 2>&1 | sed "s/^/  gw: /"
echo "  --- router show:"
timeout 40 openstack router show r-a -f yaml 2>&1 | grep -E "name|external_gateway_info|snat|status|routes|id" | head -10 | sed "s/^/    /"'

echo
echo "== [6] provas de L3 (aguardando wiring do L3 agent ~15s) =="
sleep 15
echo "  [6a] host -> 10.40.0.1 (router gw)"
ping -c3 -W2 10.40.0.1 2>&1 | tail -2 | sed 's/^/    /'
echo "  [6b] container (10.40.0.2) -> 10.40.0.1"
sudo docker exec p003-os ping -c3 -W2 10.40.0.1 2>&1 | tail -2 | sed 's/^/    /'
echo "  [6c] rota de teste no worker2 + worker2 -> 10.40.0.1"
sudo docker exec p003-gw-worker2 ip route replace 10.40.0.0/24 via 172.19.0.1 dev eth0
sudo docker exec p003-gw-worker2 ip route show 10.40.0.0/24 | sed 's/^/    rota: /'
sudo docker exec p003-gw-worker2 ping -c3 -W2 10.40.0.1 2>&1 | tail -2 | sed 's/^/    /'

echo
echo "== [7] pós: lab intacto =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
for b in docker0 br-b56f3de1d858 br-97b5ec9007c2 br-b03e3d58a257; do
  printf "  %-20s ports=%s\n" "$b" "$(ip -o link show master "$b" 2>/dev/null | wc -l)"
done
echo "  docker0 ports (esperado 2: p003-os + veth-ext0): $(ip -o link show master docker0 | wc -l)"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"

echo
[ "$FAIL" -eq 0 ] && echo "== C1.4 (plumbing + provas) executado ==" || echo "== C1.4 COM FALHA =="
