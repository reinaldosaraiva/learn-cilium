#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.4 fixes: (a) mover veth-ext1 ao netns do container
# (condição invertida no script anterior pulou o move); (b) service_plugins=router
# no neutron.conf + restart do neutron-server (sem isso /v2.0/routers 404 —
# router é SERVICE plugin, não core); (c) provas L3 do worker via TCP (kind node
# não tem ping); (d) diagnóstico do registro dos agentes.
set -uo pipefail

echo "== [a] consertar veth cross-netns =="
CPID=$(sudo docker inspect -f '{{.State.Pid}}' p003-os)
if ip link show veth-ext1 >/dev/null 2>&1; then
  sudo ip link set veth-ext1 netns "$CPID" && echo "  veth-ext1 movido para netns $CPID"
elif sudo docker exec p003-os ip link show veth-ext1 >/dev/null 2>&1; then
  echo "  veth-ext1 já está no container"
else
  echo "  ERRO: veth-ext1 em lugar nenhum"; exit 1
fi
sudo docker exec p003-os ip link set veth-ext1 up
sudo docker exec p003-os ovs-vsctl --if-exists del-port br-ex veth-ext1
sudo docker exec p003-os ovs-vsctl --may-exist add-port br-ex veth-ext1
sudo docker exec p003-os ovs-vsctl list-ports br-ex | sed 's/^/  port: /'
echo "  [L2 proof] host -> 10.40.0.2 (br-ex do container, via docker0/veth)"
ping -c3 -W2 10.40.0.2 2>&1 | tail -2 | sed 's/^/    /'

echo
echo "== [b] service_plugins=router + restart neutron-server =="
sudo docker exec p003-os bash -c 'grep -n "^service_plugins" /etc/neutron/neutron.conf || echo "  (ausente — confirmando hipótese)"'
sudo docker exec p003-os bash -c '
if ! grep -q "^service_plugins" /etc/neutron/neutron.conf; then
  sed -i "/^core_plugin = ml2/a service_plugins = router" /etc/neutron/neutron.conf
  echo "  service_plugins=router adicionado"
fi
grep -E "^(core_plugin|service_plugins)" /etc/neutron/neutron.conf | sed "s/^/    /"'
echo "  --- matar neutron-server uwsgi atual (por pid)"
NP=$(sudo docker exec p003-os bash -c 'ps -eo pid,args | grep -E "[p]rocname-prefix neutron-server" | awk "{print \$1}" | tr "\n" " "')
echo "  pids: $NP"
for p in $NP; do sudo docker exec p003-os kill -9 "$p" 2>/dev/null; done
sleep 2
echo "  --- religar neutron-server uwsgi (padrão do relight seguro de S012)"
sudo docker exec p003-os bash -c 'sudo -u stack bash -c "nohup /bin/uwsgi --procname-prefix neutron-server --ini /etc/neutron/neutron-api-uwsgi.ini --venv /opt/stack/data/venv >/tmp/neutron-restart.log 2>&1 &" </dev/null'
echo "  aguardando 30s"; sleep 30
sudo docker exec p003-os bash -c 'ps -eo pid,user,etime,args | grep -E "[p]rocname-prefix neutron-server" | cut -c1-90 | sed "s/^/  proc: /"'
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 30 openstack catalog list -f value -c Name 2>&1 | tr "\n" " " | sed "s/^/  catalog: /"; echo'

echo
echo "== [c] router demo com gw 10.40.0.1 sem SNAT =="
sudo docker exec p003-os bash -c '
source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1
if ! timeout 30 openstack router show r-a >/dev/null 2>&1; then
  timeout 60 openstack router create r-a --project demo 2>&1 | tail -1 | sed "s/^/  create: /"
fi
timeout 60 openstack router set r-a --external-gateway ext-net --disable-snat \
  --fixed-ip subnet=ext-subnet,ip-address=10.40.0.1 2>&1 | sed "s/^/  gw-set: /" || true
echo "  --- router show:"
timeout 40 openstack router show r-a 2>&1 | grep -E "external_gateway_info|name|status|routes" | head -6 | sed "s/^/    /"'
echo "  --- portas do router (qg- no br-ex):"
timeout 40 openstack port list --router r-a -f value -c Name -c "Fixed IP Addresses" 2>&1 | sed "s/^/    /"'
sudo docker exec p003-os ovs-vsctl list-ports br-ex | sed 's/^/  br-ex port: /'
sudo docker exec p003-os ip -o link | grep -E 'qg-|qr-' | sed 's/^/  iface: /' || true
sudo docker exec p003-os ip netns list | sed 's/^/  netns: /'

echo
echo "== [d] L3 proofs =="
echo "  [d1] host -> 10.40.0.1 (ICMP)"
ping -c3 -W2 10.40.0.1 2>&1 | tail -2 | sed 's/^/    /'
echo "  [d2] container 10.40.0.2 -> 10.40.0.1 (ICMP)"
sudo docker exec p003-os ping -c3 -W2 10.40.0.1 2>&1 | tail -2 | sed 's/^/    /'
echo "  [d3] worker2 -> 10.40.0.1 (TCP refused = L3 ida-e-volta)"
sudo docker exec p003-gw-worker2 bash -c 'curl -s --max-time 4 telnet://10.40.0.1:1 >/dev/null 2>&1; echo "    curl rc=$? (7=refused=L3 OK, 28=timeout=L3 quebrado)"'

echo
echo "== [e] agentes registrados? (após restart do server) =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack network agent list 2>&1' | sed 's/^/  /'
echo "  --- diagnóstico q-agt:"
sudo docker exec p003-os bash -c 'grep -E "ERROR|Traceback|Agent initialized|report_state" /opt/stack/logs/q-agt.log 2>/dev/null | grep -v "logging_exception\|rate_limit" | tail -6 | cut -c1-160 | sed "s/^/    /"'

echo
echo "== [f] pós: lab intacto =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
for b in docker0 br-b56f3de1d858 br-97b5ec9007c2 br-b03e3d58a257; do
  printf "  %-20s ports=%s\n" "$b" "$(ip -o link show master "$b" 2>/dev/null | wc -l)"
done
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
