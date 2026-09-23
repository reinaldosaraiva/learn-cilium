#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5c t2: o masquerade BPF do Cilium reescreve a fonte
# do pod para o IP fabric do nó (10.30.1.12) — fora do PodCIDR permitido pela
# SG-A. Teste decisivo: regras adicionais para os IPs fabric dos workers do
# sandbox (10.30.1.0/24 e 10.30.2.0/24) + reprobe A1/SSH.
set -uo pipefail
VM=10.30.0.107
KC="--kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw"

echo "== [1] SG-A: ingress 8080+icmp dos IPs fabric dos nós =="
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1
timeout 60 openstack security group rule create sg-a --ingress --protocol tcp --dst-port 8080 --remote-ip 10.30.1.0/24 --project demo >/dev/null 2>&1 && echo "  rule 10.30.1.0/24 ok"
timeout 60 openstack security group rule create sg-a --ingress --protocol tcp --dst-port 8080 --remote-ip 10.30.2.0/24 --project demo >/dev/null 2>&1 && echo "  rule 10.30.2.0/24 ok"
timeout 60 openstack security group rule create sg-a --ingress --protocol tcp --dst-port 22 --remote-ip 10.30.1.0/24 --project demo >/dev/null 2>&1 && echo "  rule ssh 10.30.1.0/24 ok"'

echo
echo "== [2] A1 re-probe: curl-pod -> VM 8080 (3x) =="
for i in 1 2 3; do
  R=$(sudo kubectl $KC -n p003-gateway exec p003-probe -- curl -s -m 8 -o /dev/null -w '%{http_code}' http://$VM:8080/ 2>&1)
  echo "  A1[$i]: http_code=$R"
done
sudo kubectl $KC -n p003-gateway exec p003-probe -- curl -s -m 8 http://$VM:8080/ 2>&1 | sed 's/^/  body: /'

echo
echo "== [3] A2 re-probe: VM -> pod via SSH (tcpdump no tap) =="
TAP=$(sudo /usr/bin/docker exec p003-os bash -c 'ovs-vsctl list-ports br-int | grep tap | head -1')
sudo /usr/bin/docker exec -d p003-os bash -c "timeout 45 tcpdump -i $TAP -s0 -nn -c 60 > /tmp/tap-a2.txt 2>&1"
sleep 2
QR=$(sudo /usr/bin/docker exec p003-os bash -c 'ip netns list | awk "/qrouter/{print \$1}" | head -1')
A2=$(sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR sshpass -p gocubsgo ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 cirros@$VM 'wget -T 8 -O - http://10.245.1.16:8080/ 2>&1; echo A2-RC=\$?'" 2>&1)
echo "$A2" | sed 's/^/  /'
sleep 35
echo "  --- tap (amostra):"
sudo /usr/bin/docker exec p003-os bash -c 'grep -vE "listening|verbose" /tmp/tap-a2.txt | head -12' | sed 's/^/  /'

echo
echo "== [4] pós: lab intacto + RAM =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo /usr/bin/docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR==2{print "  host available: "$7" GiB"}'
