#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5c t5: reboot duro da VM (rx morreu pós-boot; DHCP
# funcionou no boot original) e re-execução da matriz A.
set -uo pipefail
VMIP=10.30.0.107
POD=10.245.1.16
KC="--kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw"
VMIP_NEW=""

echo "== [1] hard reboot =="
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 120 openstack server reboot --hard vm-a --wait >/dev/null 2>&1; echo "  reboot rc=$?"; sleep 20; echo "  status: $(openstack server show vm-a -f value -c status)"; openstack server show vm-a -f value -c addresses | sed "s/^/  addr: /"'
sleep 45

echo
echo "== [2] novo IP (DHCP pode realocar) =="
ADDR=$(sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && openstack server show vm-a -f value -c addresses' | grep -oE '10\.30\.0\.[0-9]+')
echo "  VM IP: $ADDR"
QR=$(sudo /usr/bin/docker exec p003-os bash -c 'ip netns list | awk "/qrouter/{print \$1}" | head -1')
echo "== [3] sanity qrouter->VM =="
sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR ping -c3 -W2 $ADDR 2>&1 | tail -2 | sed 's/^/  /'"

echo
echo "== [4] MATRIZ A (novo IP) =="
sudo /usr/bin/docker exec -d p003-gw-worker2 bash -c "timeout 140 tcpdump -i any -s0 -nn host $ADDR > /tmp/a4-worker2.txt 2>&1"
sudo /usr/bin/docker exec -d p003-os bash -c "timeout 140 tcpdump -i any -s0 -nn \"host $ADDR or (host $POD and port 8080)\" > /tmp/a4-container.txt 2>&1"
echo "  --- A1 (3x):"
for i in 1 2 3; do
  R=$(sudo kubectl $KC -n p003-gateway exec p003-probe -c p003-probe -- curl -s -m 8 -o /dev/null -w '%{http_code}' http://$ADDR:8080/ 2>&1)
  echo "    A1[$i]: code=$R"
done
B=$(sudo kubectl $KC -n p003-gateway exec p003-probe -c p003-probe -- curl -s -m 8 http://$ADDR:8080/ 2>&1)
echo "    A1 body: $B"
echo "  --- A2 (VM -> pod):"
sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR sshpass -p gocubsgo ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 cirros@$ADDR 'wget -T 10 -O - http://$POD:8080/ 2>&1; echo A2-RC=\$?'" 2>&1 | sed 's/^/    /'
echo "  --- negativo host->VM:"
RC=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://$ADDR:8080/ 2>/dev/null); echo "    neg: code=$RC"

echo
echo "  aguardando capturas"; sleep 50
sudo /usr/bin/docker cp p003-gw-worker2:/tmp/a4-worker2.txt /tmp/a4-worker2.out 2>/dev/null
sudo /usr/bin/docker cp p003-os:/tmp/a4-container.txt /tmp/a4-container.out 2>/dev/null
echo "== worker2 =="; sudo grep -vE "listening|verbose|dropped by kernel" /tmp/a4-worker2.out 2>/dev/null | head -14 | sed 's/^/  /'
echo "== container =="; sudo grep -vE "listening|verbose|dropped by kernel" /tmp/a4-container.out 2>/dev/null | head -14 | sed 's/^/  /'

echo
echo "== [5] pós: lab intacto + RAM =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo /usr/bin/docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR==2{print "  host available: "$7" GiB"}'
