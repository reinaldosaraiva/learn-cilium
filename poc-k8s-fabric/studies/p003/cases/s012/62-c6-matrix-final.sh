#!/usr/bin/env bash
# P003-S012 C6 — VM limpa (10.30.0.75, qemu 91875 vivo): ping-watch e, se ok,
# MATRIZ A imediata (probe pod recriado) com capturas.
set -uo pipefail
ADDR=10.30.0.75
POD=10.245.1.16
KC="--kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw"
QR=$(sudo /usr/bin/docker exec p003-os bash -c 'ip netns list | awk "/qrouter/{print \$1}" | head -1')

echo "== [1] ping-watch (12x10s) =="
OK=0
for i in $(seq 1 12); do
  RC=$(sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR ping -c1 -W2 $ADDR >/dev/null 2>&1 && echo ok || echo dead")
  echo "  t$((i*10))s: $RC"; [ "$RC" = "ok" ] && OK=$((OK+1))
  [ "$i" = "12" ] || [ "$OK" -ge 3 ] && true
done
echo "  >>> ok=$OK/12"

if [ "$OK" -lt 2 ]; then
  echo "== rx morto desde o início — capturando estado p/ C6 =="
  sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 40 openstack console log show vm-a 2>/dev/null | grep -aE "dhcpcd|lease|carrier" | tail -8' | sed 's/^/  /'
  exit 4
fi

echo
echo "== [2] probe pod =="
sudo kubectl $KC -n p003-gateway run p003-probe --image=curlimages/curl:latest --restart=Never --command -- sh -c 'sleep 900' >/dev/null 2>&1
sleep 20
sudo kubectl $KC -n p003-gateway get pod p003-probe --no-headers 2>/dev/null | sed 's/^/  /'

echo
echo "== [3] MATRIZ A =="
sudo /usr/bin/docker exec -d p003-gw-worker2 bash -c "timeout 110 tcpdump -i any -s0 -nn host $ADDR > /tmp/b1-worker2.txt 2>&1"
sudo /usr/bin/docker exec -d p003-os bash -c "timeout 110 tcpdump -i any -s0 -nn \"host $ADDR or (host $POD and port 8080)\" > /tmp/b1-container.txt 2>&1"
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
RC=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://$ADDR:8080/ 2>/dev/null); echo "  neg host->VM: code=$RC"
echo "  --- re-ping pós-matriz (rx ainda vivo?):"
sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR ping -c2 -W2 $ADDR 2>&1 | tail -1 | sed 's/^/    /'"

echo
sleep 40
sudo /usr/bin/docker cp p003-gw-worker2:/tmp/b1-worker2.txt /tmp/b1-worker2.out 2>/dev/null
sudo /usr/bin/docker cp p003-os:/tmp/b1-container.txt /tmp/b1-container.out 2>/dev/null
echo "== worker2 =="; sudo grep -vE "listening|verbose|dropped" /tmp/b1-worker2.out 2>/dev/null | head -12 | sed 's/^/  /'
echo "== container =="; sudo grep -vE "listening|verbose|dropped" /tmp/b1-container.out 2>/dev/null | head -10 | sed 's/^/  /'

echo
echo "== [4] rotas de teste REMOVIDAS =="
sudo ip route del 10.30.0.0/24 via 10.40.0.181 dev docker0 2>/dev/null && echo "  host: removida"
sudo /usr/bin/docker exec p003-gw-worker2 ip route del 10.30.0.0/24 via 172.19.0.1 dev eth0 2>/dev/null && echo "  worker2: removida"
sudo kubectl $KC -n p003-gateway delete pod p003-probe --force --grace-period=0 >/dev/null 2>&1 && echo "  probe pod removido"

echo
echo "== [5] lab =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo /usr/bin/docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
