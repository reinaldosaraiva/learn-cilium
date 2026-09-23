#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5c t4: restart do L3 agent (qrouter ns sem IPv4 —
# nem o qg- tinha IP; re-sync re-aplica) + pod de probe persistente + matriz A.
set -uo pipefail
VM=10.30.0.107
POD=10.245.1.16
KC="--kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw"

echo "== [1] restart do L3 agent =="
LP=$(sudo /usr/bin/docker exec p003-os bash -c "ps -eo pid,args | grep '[n]eutron-l3-agent' | awk '{print \$1}' | tr '\n' ' '")
for p in $LP; do sudo /usr/bin/docker exec p003-os kill -9 "$p" 2>/dev/null; done
sleep 2
sudo /usr/bin/docker exec -d -u stack p003-os /opt/stack/data/venv/bin/neutron-l3-agent \
  --config-file /etc/neutron/neutron.conf \
  --config-file /etc/neutron/l3_agent.ini \
  --config-file /etc/neutron/plugins/ml2/openvswitch_agent.ini \
  --log-file /opt/stack/logs/q-l3.log
echo "  l3 relançado; aguardando 35s"; sleep 35
QR=$(sudo /usr/bin/docker exec p003-os bash -c 'ip netns list | awk "/qrouter/{print \$1}" | head -1')
sudo /usr/bin/docker exec p003-os bash -c "ip -n $QR -o addr | grep inet | grep -v 127 | sed 's/^/  /'"
sudo /usr/bin/docker exec p003-os bash -c "ip -n $QR route | sed 's/^/  rota: /'"

echo
echo "== [2] sanity qrouter<->VM =="
sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR ping -c3 -W2 $VM 2>&1 | tail -2 | sed 's/^/  /'"
sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR sshpass -p gocubsgo ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 cirros@$VM 'echo SSH-OK' 2>&1 | tail -1" | sed 's/^/  /'

echo
echo "== [3] pod de probe persistente =="
sudo kubectl $KC -n p003-gateway delete pod p003-probe --force --grace-period=0 >/dev/null 2>&1
sudo kubectl $KC -n p003-gateway run p003-probe --image=curlimages/curl:latest --restart=Never --command -- sh -c 'sleep 900' >/dev/null 2>&1
sleep 20
sudo kubectl $KC -n p003-gateway get pod p003-probe -o wide 2>/dev/null | tail -1 | sed 's/^/  /'

echo
echo "== [4] MATRIZ A =="
sudo /usr/bin/docker exec -d p003-gw-worker2 bash -c 'timeout 150 tcpdump -i any -s0 -nn host 10.30.0.107 > /tmp/a3-worker2.txt 2>&1'
sudo /usr/bin/docker exec -d p003-os bash -c 'timeout 150 tcpdump -i any -s0 -nn "host 10.30.0.107 or (host 10.245.1.16 and port 8080)" > /tmp/a3-container.txt 2>&1'
sudo timeout 150 tcpdump -i p003-ext -s0 -nn -c 250 "host 10.30.0.107 or (host 10.245.1.16 and port 8080)" > /tmp/a3-host.txt 2>&1 &
echo "  --- A1 (3x):"
for i in 1 2 3; do
  R=$(sudo kubectl $KC -n p003-gateway exec p003-probe -c p003-probe -- curl -s -m 8 -o /dev/null -w '%{http_code}' http://$VM:8080/ 2>&1)
  echo "    A1[$i]: code=$R"
done
B=$(sudo kubectl $KC -n p003-gateway exec p003-probe -c p003-probe -- curl -s -m 8 http://$VM:8080/ 2>&1)
echo "    A1 body: $B"
echo "  --- A2 (VM -> pod via SSH):"
sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR sshpass -p gocubsgo ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 cirros@$VM 'wget -T 10 -O - http://$POD:8080/ 2>&1; echo A2-RC=\$?'" 2>&1 | sed 's/^/    /'
echo "  --- negativo host->VM:"
RC=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://$VM:8080/ 2>/dev/null); echo "    neg: code=$RC"

echo
echo "  aguardando capturas"; sleep 55
sudo /usr/bin/docker cp p003-gw-worker2:/tmp/a3-worker2.txt /tmp/a3-worker2.out 2>/dev/null
sudo /usr/bin/docker cp p003-os:/tmp/a3-container.txt /tmp/a3-container.out 2>/dev/null
echo "== worker2 =="; sudo grep -vE "listening|verbose|dropped by kernel" /tmp/a3-worker2.out 2>/dev/null | head -16 | sed 's/^/  /'
echo "== container =="; sudo grep -vE "listening|verbose|dropped by kernel" /tmp/a3-container.out 2>/dev/null | head -12 | sed 's/^/  /'
echo "== host =="; sudo grep -vE "listening|verbose|dropped by kernel" /tmp/a3-host.txt 2>/dev/null | head -10 | sed 's/^/  /'

echo
echo "== [5] pós: lab intacto + RAM =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo /usr/bin/docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR==2{print "  host available: "$7" GiB"}'
