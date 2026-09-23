#!/usr/bin/env bash
# P003-S012 rodada 2 — triagem do datapath L3 (por que ARP/ping não chegam ao qg-).
# Somente leitura + captura transitória de 6 pacotes.
set -uo pipefail

echo "== [1] interfaces do qrouter =="
sudo docker exec p003-os bash -c 'NS=$(ip netns list | awk "/qrouter/{print \$1}"); echo "  ns=$NS"; ip -n "$NS" -o addr | sed "s/^/  /"; ip -n "$NS" -o link | sed "s/^/  /"; echo "  --- neigh do qrouter:"; ip -n "$NS" neigh | sed "s/^/  /"'

echo
echo "== [2] ovs-vsctl show (patch + qg- no br-int) =="
sudo docker exec p003-os ovs-vsctl show | sed 's/^/  /'

echo
echo "== [3] flows =="
sudo docker exec p003-os bash -c 'echo "  br-int flows: $(ovs-ofctl dump-flows br-int 2>/dev/null | wc -l)"; ovs-ofctl dump-flows br-int 2>/dev/null | head -8 | cut -c1-140 | sed "s/^/    /"; echo "  br-ex flows: $(ovs-ofctl dump-flows br-ex 2>/dev/null | wc -l)"; ovs-ofctl dump-flows br-ex 2>/dev/null | head -5 | cut -c1-140 | sed "s/^/    /"'

echo
echo "== [4] captura ARP no veth-ext0 durante ping =="
sudo timeout 8 tcpdump -i veth-ext0 -c 6 -n arp or icmp 2>&1 | sed 's/^/  /' &
TPID=$!
sleep 1
ping -c3 -W1 10.40.0.181 >/dev/null 2>&1
wait $TPID 2>/dev/null || true

echo
echo "== [5] conectividade L2 host<->br-ex ainda OK? (10.40.0.2) =="
ping -c2 -W1 10.40.0.2 >/dev/null 2>&1 && echo "  host->10.40.0.2 OK" || echo "  host->10.40.0.2 FAIL"

echo
echo "== [6] q-agt: conexão OF e br-int =="
sudo docker exec p003-os bash -c 'grep -aE "br-int|ofctl|osken|openflow" /opt/stack/logs/q-agt.log 2>/dev/null | grep -av "Subscribe\|DEBUG oslo" | tail -6 | cut -c1-160 | sed "s/^/  /"'
