#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5b: recursos tenant A + VM A.
# Imagem glance -> net-a/subnet-a (demo) -> SG-A (ingress 8080 do PodCIDR, egress
# p/ PodCIDR, ssh intra-subnet) -> rotas de teste (host + worker2) -> VM A com
# config-drive + user-data (responder nc na 8080 + probe VM->pod no console).
set -uo pipefail

echo "== [0] guard de RAM =="
AV=$(free -m | awk '/Mem:/{print $7}')
echo "  host available: ${AV} MiB"
[ "$AV" -lt 1500 ] && { echo "  ABORT: < 1.5GiB available"; exit 1; }

echo
echo "== [1] imagem no glance =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 120 openstack image create --file /opt/stack/cirros-0.6.0-x86_64-disk.img --disk-format qcow2 --container-format bare --public cirros-0.6.0 2>&1 | grep -E "^\| (id|name|status)" ' | sed 's/^/  /'
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 && timeout 40 openstack image list 2>&1' | sed 's/^/  /'

echo
echo "== [2] net-a + subnet-a (projeto demo) =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1
openstack network show net-a >/dev/null 2>&1 || timeout 60 openstack network create net-a --project demo >/dev/null 2>&1
openstack subnet show subnet-a >/dev/null 2>&1 || timeout 60 openstack subnet create subnet-a --network net-a --project demo \
  --subnet-range 10.30.0.0/24 --gateway 10.30.0.1 --dhcp >/dev/null 2>&1
echo "  net-a: $(openstack network show net-a -f value -c id)"
echo "  subnet-a: $(openstack subnet show subnet-a -f value -c id) $(openstack subnet show subnet-a -f value -c cidr)"'

echo
echo "== [3] SG-A + regras =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1
openstack security group show sg-a >/dev/null 2>&1 || timeout 60 openstack security group create sg-a --project demo >/dev/null 2>&1
SG=$(openstack security group show sg-a -f value -c id)
openstack security group rule list -f value -c Security_Group -c Protocol -c Port_Range -c Remote_IP_Prefix 2>/dev/null | grep -q "^$SG" || true
timeout 60 openstack security group rule create sg-a --ingress --protocol tcp --dst-port 8080 --remote-ip 10.245.0.0/16 --project demo >/dev/null 2>&1
timeout 60 openstack security group rule create sg-a --ingress --protocol tcp --dst-port 22 --remote-ip 10.30.0.0/24 --project demo >/dev/null 2>&1
timeout 60 openstack security group rule create sg-a --ingress --protocol icmp --remote-ip 10.245.0.0/16 --project demo >/dev/null 2>&1
timeout 60 openstack security group rule create sg-a --egress --protocol tcp --dst-port 8080 --remote-ip 10.245.0.0/16 --project demo >/dev/null 2>&1
timeout 60 openstack security group rule create sg-a --egress --protocol icmp --remote-ip 10.245.0.0/16 --project demo >/dev/null 2>&1
echo "  regras sg-a:"
openstack security group rule list sg-a -f value -c Direction -c Protocol -c Port_Range -c Remote_IP_Prefix 2>/dev/null | sed "s/^/    /"'

echo
echo "== [4] rotas de teste (host + worker2), revertidas no teardown =="
sudo ip route replace 10.30.0.0/24 via 10.40.0.181 dev docker0
ip route show 10.30.0.0/24 | sed 's/^/  host: /'
sudo docker exec p003-gw-worker2 ip route replace 10.30.0.0/24 via 172.19.0.1 dev eth0
sudo docker exec p003-gw-worker2 ip route show 10.30.0.0/24 | sed 's/^/  worker2: /'

echo
echo "== [5] user-data da VM A =="
sudo docker exec p003-os bash -c 'cat > /opt/stack/vm-a-init.sh <<"UD"
#!/bin/sh
exec >/dev/ttyS0 2>&1
echo "=== p003 vm-a user-data start $(date) ==="
(while true; do printf "HTTP/1.0 200 OK\r\nContent-Length: 9\r\nConnection: close\r\n\r\nvm-a-ok\n" | nc -l -p 8080; done) &
echo "=== responder 8080 iniciado ==="
sleep 55
echo "=== vm->pod probe A2: wget http://10.245.1.16:8080/ ==="
wget -T 8 -O /tmp/a2.out http://10.245.1.16:8080/ 2>/tmp/a2.err
echo "=== A2 rc=$? ==="
head -3 /tmp/a2.err
cat /tmp/a2.out 2>/dev/null
echo "=== p003 vm-a user-data done ==="
UD
echo "  user-data:"; sed "s/^/    /" /opt/stack/vm-a-init.sh'

echo
echo "== [6] VM A =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1
openstack server show vm-a >/dev/null 2>&1 || timeout 180 openstack server create vm-a \
  --image cirros-0.6.0 --flavor m1.p003 --network net-a --security-group sg-a \
  --project demo --config-drive True --user-data /opt/stack/vm-a-init.sh --wait >/dev/null 2>&1
echo "  estado: $(openstack server show vm-a -f value -c status)"
openstack server show vm-a -f value -c addresses | sed "s/^/  endereços: /"
openstack server show vm-a -f value -c id | sed "s/^/  id: /"'

echo
echo "== [7] pós: lab intacto + RAM =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR==2{print "  host available: "$7" GiB"}'
