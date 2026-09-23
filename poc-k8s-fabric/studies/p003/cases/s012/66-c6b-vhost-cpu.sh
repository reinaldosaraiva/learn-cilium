#!/usr/bin/env bash
# P003-S012 C6b — variantes finais: vhost-net OFF (rmmod no host) +
# cpu_mode=host-passthrough (nova.conf). Se a VM receber -> MATRIZ A imediata.
set -uo pipefail
POD=10.245.1.16
KC="--kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw"

echo "== [1] vhost_net OFF no host =="
lsmod | grep -E "^vhost_net" | sed 's/^/  antes: /' || echo "  antes: não carregado"
sudo rmmod vhost_net 2>&1 | sed 's/^/  rmmod: /' || true
lsmod | grep -E "^vhost_net" | sed 's/^/  depois: /' || echo "  depois: REMOVIDO"

echo
echo "== [2] cpu_mode=host-passthrough (nova.conf [libvirt]) =="
sudo /usr/bin/docker exec p003-os bash -c '
if grep -q "^cpu_mode" /etc/nova/nova.conf; then
  sed -i "s/^cpu_mode.*/cpu_mode = host-passthrough/" /etc/nova/nova.conf
else
  sed -i "/^\[libvirt\]/a cpu_mode = host-passthrough" /etc/nova/nova.conf
fi
grep -n "^cpu_mode\|^\[libvirt\]" /etc/nova/nova.conf | head -3 | sed "s/^/  /"'
CP=$(sudo /usr/bin/docker exec p003-os bash -c "ps -eo pid,args | grep '[n]ova-compute' | grep -vE 'grep|uwsgi' | awk '{print \$1}' | tr '\n' ' '")
for p in $CP; do sudo /usr/bin/docker exec p003-os kill -9 "$p" 2>/dev/null; done
sleep 2
sudo /usr/bin/docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-compute --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-cpu.log
echo "  n-cpu restartado; aguardando 75s"; sleep 75

echo
echo "== [3] limpar e criar vm-a (virtio default) =="
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1
for id in $(openstack server list -f value -c ID 2>/dev/null); do timeout 60 openstack server delete $id --wait >/dev/null 2>&1 || timeout 20 openstack server delete $id --force >/dev/null 2>&1; done
for d in $(timeout 20 virsh list --all --name 2>/dev/null); do timeout 15 virsh destroy $d >/dev/null 2>&1; timeout 10 virsh undefine $d >/dev/null 2>&1; done
for p in $(pgrep -f "qemu-system.*instance" 2>/dev/null); do kill -9 $p 2>/dev/null; done
sleep 2
timeout 540 openstack server create vm-a --image cirros-0.6.0 --flavor m1.p003 \
  --network net-a --security-group sg-a --config-drive True --user-data /opt/stack/vm-a-init.sh --wait >/dev/null 2>&1
echo "  rc=$?"'
SID=$(sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && openstack server list -f value -c ID 2>/dev/null | head -1')
ADDR=$(sudo /usr/bin/docker exec p003-os bash -c "source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && openstack server show $SID -f value -c addresses" | grep -oE '10\.30\.0\.[0-9]+')
DOM=$(sudo /usr/bin/docker exec p003-os bash -c 'timeout 20 virsh list --name --state-running 2>/dev/null | head -1')
echo "  id=$SID ip=${ADDR:-?} dom=$DOM"
echo "  --- cpu/nic do domínio:"
sudo /usr/bin/docker exec p003-os bash -c "timeout 15 virsh dumpxml $DOM 2>/dev/null | grep -oE \"cpu mode='[a-z-]+'|model type='[a-z0-9]+'\" | head -3" | sed 's/^/  /'

echo
echo "== [4] console DHCP =="
sleep 45
sudo /usr/bin/docker exec p003-os bash -c "source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 40 openstack console log show $SID 2>/dev/null | grep -aE 'dhcpcd|lease|IPv4LL' | tail -5" | sed 's/^/  /'

echo
echo "== [5] ping-watch (12x10s) =="
QR=$(sudo /usr/bin/docker exec p003-os bash -c 'ip netns list | awk "/qrouter/{print \$1}" | head -1')
OK=0
for i in $(seq 1 12); do
  RC=$(sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR ping -c1 -W2 $ADDR >/dev/null 2>&1 && echo ok || echo dead")
  echo "  t$((i*10))s: $RC"; [ "$RC" = "ok" ] && OK=$((OK+1))
done
echo "  >>> ok=$OK/12"

if [ "$OK" -lt 2 ]; then
  echo "== variante também falhou — C6b encerra aqui (docs) =="
  exit 4
fi

echo
echo "== [6] MATRIZ A (rx VIVO!) =="
sudo kubectl $KC -n p003-gateway run p003-probe --image=curlimages/curl:latest --restart=Never --command -- sh -c 'sleep 600' >/dev/null 2>&1
sleep 20
sudo /usr/bin/docker exec -d p003-gw-worker2 bash -c "timeout 100 tcpdump -i any -s0 -nn host $ADDR > /tmp/c1-worker2.txt 2>&1"
sudo /usr/bin/docker exec -d p003-os bash -c "timeout 100 tcpdump -i any -s0 -nn \"host $ADDR or (host $POD and port 8080)\" > /tmp/c1-container.txt 2>&1"
sudo ip route replace 10.30.0.0/24 via 10.40.0.181 dev docker0
sudo /usr/bin/docker exec p003-gw-worker2 ip route replace 10.30.0.0/24 via 172.19.0.1 dev eth0
for i in 1 2 3; do
  R=$(sudo kubectl $KC -n p003-gateway exec p003-probe -c p003-probe -- curl -s -m 8 -o /dev/null -w '%{http_code}' http://$ADDR:8080/ 2>&1)
  echo "  A1[$i]: code=$R"
done
B=$(sudo kubectl $KC -n p003-gateway exec p003-probe -c p003-probe -- curl -s -m 8 http://$ADDR:8080/ 2>&1)
echo "  A1 body: $B"
echo "  --- A2 (VM -> pod):"
sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR sshpass -p gocubsgo ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 cirros@$ADDR 'wget -T 10 -O - http://$POD:8080/ 2>&1; echo A2-RC=\$?'" 2>&1 | sed 's/^/    /'
RCN=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://$ADDR:8080/ 2>/dev/null); echo "  neg host->VM: code=$RCN"
echo "  --- ping pós-matriz:"
sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR ping -c2 -W2 $ADDR 2>&1 | tail -1 | sed 's/^/    /'"
sleep 35
sudo /usr/bin/docker cp p003-gw-worker2:/tmp/c1-worker2.txt /tmp/c1-worker2.out 2>/dev/null
sudo /usr/bin/docker cp p003-os:/tmp/c1-container.txt /tmp/c1-container.out 2>/dev/null
echo "== worker2 =="; sudo grep -vE "listening|verbose|dropped" /tmp/c1-worker2.out 2>/dev/null | head -10 | sed 's/^/  /'
echo "== container =="; sudo grep -vE "listening|verbose|dropped" /tmp/c1-container.out 2>/dev/null | head -8 | sed 's/^/  /'
sudo ip route del 10.30.0.0/24 via 10.40.0.181 dev docker0 2>/dev/null && echo "  rota host removida"
sudo /usr/bin/docker exec p003-gw-worker2 ip route del 10.30.0.0/24 via 172.19.0.1 dev eth0 2>/dev/null && echo "  rota worker2 removida"
sudo kubectl $KC -n p003-gateway delete pod p003-probe --force --grace-period=0 >/dev/null 2>&1 && echo "  probe pod removido"

echo
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "canário k01: $c"
echo "mem: $(sudo /usr/bin/docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
