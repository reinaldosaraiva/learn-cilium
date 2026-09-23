#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5c diag: entrega no tap da VM e estado OVS do port.
set -uo pipefail
VM=10.30.0.107
TAP=$(sudo /usr/bin/docker exec p003-os bash -c 'ovs-vsctl list-ports br-int | grep tap | head -1')
echo "== [1] tap: $TAP =="
sudo /usr/bin/docker exec p003-os bash -c "ovs-vsctl list interface $TAP | grep -E 'name|ofport|status|error|link_state' | sed 's/^/  /'"

echo
echo "== [2] captura no tap durante SSH do qrouter =="
sudo /usr/bin/docker exec -d p003-os bash -c "timeout 30 tcpdump -i $TAP -s0 -nn -c 40 > /tmp/tap-cap.txt 2>&1"
sleep 2
QR=$(sudo /usr/bin/docker exec p003-os bash -c 'ip netns list | awk "/qrouter/{print \$1}" | head -1')
sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR ping -c3 -W2 $VM 2>&1 | tail -2" | sed 's/^/  ping: /'
sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR sshpass -p gocubsgo ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=6 cirros@$VM 'echo SSH-OK' 2>&1 | tail -1" | sed 's/^/  ssh: /'
sleep 25
sudo /usr/bin/docker exec p003-os bash -c 'grep -vE "listening|verbose" /tmp/tap-cap.txt | head -14' | sed 's/^/  /'

echo
echo "== [3] ARP do qrouter para a VM =="
sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR ip neigh | grep -v FAILED | head -4; ip netns exec $QR ip neigh | grep $VM" | sed 's/^/  /'

echo
echo "== [4] flows do br-int para o tap/ofport =="
OF=$(sudo /usr/bin/docker exec p003-os bash -c "ovs-vsctl get interface $TAP ofport")
echo "  ofport=$OF"
sudo /usr/bin/docker exec p003-os bash -c "ovs-ofctl dump-flows br-int 2>/dev/null | grep -E \"in_port=$OF|dl_src.,dl_vlan=$OF|actions=.*$OF\" | head -6 | cut -c1-160" | sed 's/^/  /'
sudo /usr/bin/docker exec p003-os bash -c "ovs-vsctl show | grep -B1 -A3 $TAP" | sed 's/^/  /'
