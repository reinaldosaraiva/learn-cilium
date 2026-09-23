#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5c: MATRIZ A (permitido).
# A1: pod do sandbox -> VM A (tcp/8080) esperado 200 (fonte será o IP do nó
#     por causa do masquerade BPF do Cilium — desvio documentado).
# A2: VM A -> pod http-echo (10.245.1.16:8080) via SSH do qrouter, com
#     tcpdump no worker2 (e no host p003-ext) para localizar onde para.
# Negativo: host -> VM A 8080 (fora do PodCIDR — SG deve bloquear).
# tcpdump no lado da VM: tap3b0cbe94-6f no container.
set -uo pipefail
VM=10.30.0.107
POD=10.245.1.16
KC="--kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw"

echo "== [0] ferramentas: pod de probe + sshpass =="
IMG=$(sudo kubectl $KC -n p003-gateway get pod p003-dns-65c6585c75-4pzw4 -o jsonpath='{.spec.containers[0].image}' 2>/dev/null)
echo "  p003-dns image: $IMG"
if ! sudo /usr/bin/docker exec p003-os bash -c 'command -v sshpass >/dev/null' 2>/dev/null; then
  sudo /usr/bin/docker exec p003-os bash -c 'apt-get install -y sshpass >/dev/null 2>&1' && echo "  sshpass instalado" || echo "  sshpass FALHOU (apt)"
fi

echo
echo "== [1] tcpdumps de fundo =="
sudo /usr/bin/docker exec -d p003-gw-worker2 bash -c 'timeout 240 tcpdump -i any -s0 -nn host 10.30.0.107 > /tmp/a-matrix-worker2.txt 2>&1'
sudo /usr/bin/docker exec -d p003-os bash -c 'timeout 240 tcpdump -i any -s0 -nn host 10.30.0.107 > /tmp/a-matrix-container.txt 2>&1'
sudo timeout 240 tcpdump -i p003-ext -s0 -nn -c 400 host 10.30.0.107 > /tmp/a-matrix-host-p003ext.txt 2>&1 &
echo "  3 capturas ativas (240s)"

echo
echo "== [2] A1: pod -> VM A (tcp/8080) =="
if sudo kubectl $KC -n p003-gateway exec p003-dns-65c6585c75-4pzw4 -- sh -c 'command -v wget' >/dev/null 2>&1; then
  PROBE="p003-dns-65c6585c75-4pzw4:wget"
  for i in 1 2 3; do
    R=$(sudo kubectl $KC -n p003-gateway exec p003-dns-65c6585c75-4pzw4 -- wget -q -T 8 -O - http://$VM:8080/ 2>&1)
    echo "  A1[$i] via dns-pod wget: ${R:-vazio}"
  done
else
  echo "  dns-pod sem wget; usando curl pod"
  sudo kubectl $KC -n p003-gateway run p003-probe --image=curlimages/curl:latest --restart=Never --command -- sleep 300 >/dev/null 2>&1
  sleep 25
  for i in 1 2 3; do
    R=$(sudo kubectl $KC -n p003-gateway exec p003-probe -- curl -s -m 8 http://$VM:8080/ 2>&1)
    echo "  A1[$i] via curl-pod: ${R:-vazio}"
  done
fi

echo
echo "== [3] A2: VM A -> pod (ssh via qrouter) =="
QR=$(sudo /usr/bin/docker exec p003-os bash -c 'ip netns list | awk "/qrouter/{print \$1}" | head -1')
echo "  qrouter=$QR"
A2=$(sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR sshpass -p gocubsgo ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 cirros@$VM 'wget -T 8 -O - http://$POD:8080/ 2>&1; echo RC=\$?'" 2>&1)
echo "$A2" | sed 's/^/  A2: /'

echo
echo "== [4] negativo: host (10.40.0.250) -> VM A 8080 (SG deve bloquear) =="
for i in 1 2; do
  RC=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://$VM:8080/ 2>/dev/null)
  echo "  neg[$i]: code=$RC (000/timeout esperado)"
done

echo
echo "== [5] evidência de estado =="
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1; echo "--- router r-a:"; openstack router show r-a -f value -c routes; openstack router show r-a -f json 2>/dev/null | grep -o "\"enable_snat\": [a-z]*"; echo "--- sg-a:"; openstack security group rule list sg-a -f value -c Direction -c Protocol -c Port_Range -c Remote_IP_Prefix 2>/dev/null' | sed 's/^/  /'
echo "  aguardando tcpdumps encerrarem"; sleep 65
sudo /usr/bin/docker cp p003-gw-worker2:/tmp/a-matrix-worker2.txt /tmp/a-matrix-worker2.txt 2>/dev/null
sudo /usr/bin/docker cp p003-os:/tmp/a-matrix-container.txt /tmp/a-matrix-container.txt 2>/dev/null
sudo cp /tmp/a-matrix-host-p003ext.txt /tmp/a-matrix-host-p003ext.keep.txt 2>/dev/null
echo "== worker2 (amostra) =="; sudo grep -vE "listening|packets captured|packets received|dropped by kernel" /tmp/a-matrix-worker2.txt 2>/dev/null | head -25 | sed 's/^/  /'
echo "== container (amostra) =="; sudo grep -vE "listening|packets captured|packets received|dropped by kernel" /tmp/a-matrix-container.txt 2>/dev/null | head -20 | sed 's/^/  /'
echo "== host p003-ext (amostra) =="; sudo grep -vE "listening|packets captured|packets received|dropped by kernel" /tmp/a-matrix-host-p003ext.txt 2>/dev/null | head -15 | sed 's/^/  /'

echo
echo "== [6] pós: lab intacto + RAM =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo /usr/bin/docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR==2{print "  host available: "$7" GiB"}'
