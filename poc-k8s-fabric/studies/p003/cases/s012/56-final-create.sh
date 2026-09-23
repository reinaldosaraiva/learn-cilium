#!/usr/bin/env bash
# P003-S012 rodada 2 — FINAL: dedupe vm-a por ID, criar UMA, matriz imediata.
set -uo pipefail
POD=10.245.1.16
KC="--kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw"

echo "== [1] dedupe: deletar TODOS os servers com nome vm-a =="
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1
for id in $(openstack server list --name vm-a -f value -c ID 2>/dev/null); do
  timeout 90 openstack server delete $id --wait >/dev/null 2>&1 || timeout 30 openstack server delete $id --force >/dev/null 2>&1
  echo "  deleted $id"
done
for d in $(timeout 20 virsh list --all --name 2>/dev/null); do timeout 20 virsh destroy $d >/dev/null 2>&1; timeout 20 virsh undefine $d >/dev/null 2>&1; echo "  undef $d"; done
echo "  restantes: $(openstack server list -f value -c Name | tr "\n" " ")"'

echo
echo "== [2] criar UMA vm-a =="
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; sleep 2; timeout 540 openstack server create vm-a \
  --image cirros-0.6.0 --flavor m1.p003 --network net-a --security-group sg-a \
  --config-drive True --user-data /opt/stack/vm-a-init.sh --wait >/dev/null 2>&1; echo "  create rc=$?"'
SID=$(sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && openstack server list --name vm-a -f value -c ID | head -1')
ST=$(sudo /usr/bin/docker exec p003-os bash -c "source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && openstack server show $SID -f value -c status")
ADDR=$(sudo /usr/bin/docker exec p003-os bash -c "source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && openstack server show $SID -f value -c addresses" | grep -oE '10\.30\.0\.[0-9]+')
echo "  id=$SID status=$ST ip=${ADDR:-?}"
if [ "$ST" != "ACTIVE" ]; then echo "== ABORT ($ST) =="; exit 3; fi

echo
echo "== [3] settle + sanity =="
sleep 40
QR=$(sudo /usr/bin/docker exec p003-os bash -c 'ip netns list | awk "/qrouter/{print \$1}" | head -1')
sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR ping -c3 -W2 $ADDR 2>&1 | tail -1 | sed 's/^/  ping: /'"

echo
echo "== [4] MATRIZ A =="
sudo /usr/bin/docker exec -d p003-gw-worker2 bash -c "timeout 120 tcpdump -i any -s0 -nn host $ADDR > /tmp/a6-worker2.txt 2>&1"
sudo /usr/bin/docker exec -d p003-os bash -c "timeout 120 tcpdump -i any -s0 -nn \"host $ADDR or (host $POD and port 8080)\" > /tmp/a6-container.txt 2>&1"
for i in 1 2 3; do
  R=$(sudo kubectl $KC -n p003-gateway exec p003-probe -c p003-probe -- curl -s -m 8 -o /dev/null -w '%{http_code}' http://$ADDR:8080/ 2>&1)
  echo "  A1[$i]: code=$R"
done
B=$(sudo kubectl $KC -n p003-gateway exec p003-probe -c p003-probe -- curl -s -m 8 http://$ADDR:8080/ 2>&1)
echo "  A1 body: $B"
sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR sshpass -p gocubsgo ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 cirros@$ADDR 'wget -T 10 -O - http://$POD:8080/ 2>&1; echo A2-RC=\$?'" 2>&1 | sed 's/^/  A2: /'
RC=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://$ADDR:8080/ 2>/dev/null); echo "  neg host->VM: code=$RC"

echo
sleep 40
sudo /usr/bin/docker cp p003-gw-worker2:/tmp/a6-worker2.txt /tmp/a6-worker2.out 2>/dev/null
sudo /usr/bin/docker cp p003-os:/tmp/a6-container.txt /tmp/a6-container.out 2>/dev/null
echo "== worker2 =="; sudo grep -vE "listening|verbose|dropped" /tmp/a6-worker2.out 2>/dev/null | head -12 | sed 's/^/  /'
echo "== container =="; sudo grep -vE "listening|verbose|dropped" /tmp/a6-container.out 2>/dev/null | head -12 | sed 's/^/  /'
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 40 openstack console log show vm-a 2>/dev/null | grep -aE "p003|login" | tail -4' | sed 's/^/  console: /'

echo
echo "== [5] lab + RAM =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo /usr/bin/docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
