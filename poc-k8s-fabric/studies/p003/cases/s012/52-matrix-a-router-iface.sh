#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5c t3: o r-a nunca recebeu a subnet-a (passo pulado!)
# -> sem qr- no br-int, sem gateway 10.30.0.1, qdhcp ns sumiu. Adicionar a
# interface e rodar a MATRIZ A completa.
set -uo pipefail
VM=10.30.0.107
POD=10.245.1.16
KC="--kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw"

echo "== [1] router add subnet r-a subnet-a =="
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 60 openstack router add subnet r-a subnet-a 2>&1; echo "  rc=$?"'
echo "  aguardando 20s (L3/DHCP agents wiring)"; sleep 20
sudo /usr/bin/docker exec p003-os bash -c 'ovs-vsctl show | grep -A1 "qr-" | head -4; ip netns list | sed "s/^/  ns: /"'
QR=$(sudo /usr/bin/docker exec p003-os bash -c 'ip netns list | awk "/qrouter/{print \$1}" | head -1')
sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR ip -o addr | grep -v lo | sed 's/^/  qr: /'"

echo
echo "== [2] L2/L3 sanity: qrouter -> VM =="
sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR ping -c3 -W2 $VM 2>&1 | tail -2 | sed 's/^/  ping: /'"
sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR sshpass -p gocubsgo ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 cirros@$VM 'echo SSH-OK; ip route | head -3' 2>&1 | tail -4" | sed 's/^/  /'

echo
echo "== [3] tcpdumps de fundo (worker2 + container + host) =="
sudo /usr/bin/docker exec -d p003-gw-worker2 bash -c 'timeout 180 tcpdump -i any -s0 -nn host 10.30.0.107 > /tmp/a2-worker2.txt 2>&1'
sudo /usr/bin/docker exec -d p003-os bash -c 'timeout 180 tcpdump -i any -s0 -nn "host 10.30.0.107 or (host 10.245.1.16 and port 8080)" > /tmp/a2-container.txt 2>&1'
sudo timeout 180 tcpdump -i p003-ext -s0 -nn -c 300 "host 10.30.0.107 or (host 10.245.1.16 and port 8080)" > /tmp/a2-host.txt 2>&1 &
echo "  capturas ativas"

echo
echo "== [4] MATRIZ A =="
echo "  --- A1: curl-pod -> VM 8080 (3x):"
for i in 1 2 3; do
  R=$(sudo kubectl $KC -n p003-gateway exec p003-probe -- curl -s -m 8 -o /dev/null -w '%{http_code}' http://$VM:8080/ 2>&1)
  echo "    A1[$i]: code=$R"
done
B=$(sudo kubectl $KC -n p003-gateway exec p003-probe -- curl -s -m 8 http://$VM:8080/ 2>&1)
echo "    A1 body: $B"
echo "  --- A2: VM -> pod (SSH qrouter):"
sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR sshpass -p gocubsgo ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 cirros@$VM 'wget -T 10 -O - http://$POD:8080/ 2>&1; echo A2-RC=\$?'" 2>&1 | sed 's/^/    /'
echo "  --- negativo: host -> VM 8080 (fora das fontes permitidas):"
RC=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://$VM:8080/ 2>/dev/null); echo "    neg: code=$RC"

echo
echo "  aguardando capturas (60s)"; sleep 60
sudo /usr/bin/docker cp p003-gw-worker2:/tmp/a2-worker2.txt /tmp/a2-worker2.out 2>/dev/null
sudo /usr/bin/docker cp p003-os:/tmp/a2-container.txt /tmp/a2-container.out 2>/dev/null
echo "== worker2 (até 18 linhas) =="; sudo grep -vE "listening|verbose|0 packets dropped" /tmp/a2-worker2.out 2>/dev/null | head -18 | sed 's/^/  /'
echo "== container (até 14) =="; sudo grep -vE "listening|verbose|0 packets dropped" /tmp/a2-container.out 2>/dev/null | head -14 | sed 's/^/  /'
echo "== host p003-ext (até 10) =="; sudo grep -vE "listening|verbose|0 packets dropped" /tmp/a2-host.txt 2>/dev/null | head -10 | sed 's/^/  /'

echo
echo "== [5] pós: lab intacto + RAM =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo /usr/bin/docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR==2{print "  host available: "$7" GiB"}'
