#!/usr/bin/env bash
# P003-S012 rodada 2 (Emenda C1) — preflight somente leitura.
# ZERO mutações: nada aqui altera host, containers, kernel ou cloud.
# Executado no host vm-cilium como ubuntu (usa sudo internamente).
set -uo pipefail

echo "== [A] host base =="
date -u
echo "  containers running: $(sudo docker ps -q | wc -l) (expect 21)"
free -g | sed -n '1,2p' | sed 's/^/  /'
df -h / | tail -1 | sed 's/^/  /'
echo "  ip_forward: $(cat /proc/sys/net/ipv4/ip_forward)"

echo
echo "== [B] host bridges (expect docker0=1, br-b56f3de1d858=6, br-97b5ec9007c2=7, br-b03e3d58a257=7) =="
for b in docker0 br-b56f3de1d858 br-97b5ec9007c2 br-b03e3d58a257; do
  printf "  %-20s ports=%s %s\n" "$b" "$(ip -o link show master "$b" 2>/dev/null | wc -l)" "$(ip -br addr show "$b" 2>/dev/null | awk '{print $2,$3}')"
done

echo
echo "== [C] kernel modules (pre-C1.1: bridge loaded refcnt>=0; openvswitch absent) =="
lsmod | grep -E '^(bridge|openvswitch) ' | sed 's/^/  /' || echo "  (neither bridge nor openvswitch loaded)"
modinfo -n openvswitch 2>/dev/null | sed 's/^/  modinfo: /' || echo "  modinfo openvswitch: NOT FOUND"

echo
echo "== [D] protected UIDs =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01     = $K"
echo "  sandbox = $S"
[ "$K" = "45cb3818-248b-4dd2-b65c-5909bde08fe6" ] && echo "  OK k01 unchanged" || echo "  FAIL k01"
[ "$S" = "8216d179-9eed-4dc1-ab9c-97c0c6612b32" ] && echo "  OK sandbox unchanged" || echo "  FAIL sandbox"

echo
echo "== [E] k01 canary VIP 10.201.255.10:80 (expect 10/10) =="
ok=0; for i in $(seq 1 10); do c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/ 2>/dev/null); printf " %s" "$c"; [ "$c" = 200 ] && ok=$((ok+1)); done; echo; echo "  200-count: $ok/10"

echo
echo "== [F] sandbox NodePort from fabric client (expect 200 x3) =="
for ip in 10.30.1.11 10.30.1.12 10.30.2.11; do
  c=$(sudo docker exec clab-p003-gw-fabric-client curl -s -o /dev/null -w '%{http_code}' --max-time 8 --noproxy '*' -H 'Host: echo.p003.study' http://$ip:30676/ 2>/dev/null)
  echo "  $ip:30676 -> $c"
done

echo
echo "== [G] sandbox backends + services =="
sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get pods -A -o wide 2>/dev/null | grep -E 'http-echo|p003-dns|tcp-echo|NAME' | sed 's/^/  /'
sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get svc -A 2>/dev/null | grep -Ei 'echo|dns|NAME' | sed 's/^/  /'

echo
echo "== [H] cilium masquerade + routing (sandbox) =="
sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw -n kube-system exec ds/cilium -- cilium config view 2>/dev/null | grep -iE 'masquerade|native-routing|forward-k8s' | sed 's/^/  /'

echo
echo "== [I] p003-os process state =="
sudo docker exec p003-os bash -c 'for p in mysqld beam.smp memcached apache2 ovsdb-server ovs-vswitchd libvirtd; do printf "  %-14s %s\n" "$p" "$(pgrep -xc $p 2>/dev/null || echo 0)"; done; echo "  mem: $(free -m | awk "/Mem:/{print \$3\" MiB used / \"\$2\" MiB\"}")"'

echo
echo "== [J] p003-os OVS state (expect: no datapath before C1.1/C1.2) =="
sudo docker exec p003-os bash -c 'ovs-vsctl show 2>&1 | head -6 | sed "s/^/  /"; echo "  ovs bridges: $(ovs-vsctl list-br 2>/dev/null | wc -l)"; echo "  linux bridges in netns: $(ip -o -d link show type bridge 2>/dev/null | wc -l)"'

echo
echo "== [K] neutron/agent configs (C1.3 pre-check, read-only) =="
sudo docker exec p003-os bash -c '
for f in /etc/neutron/neutron.conf /etc/neutron/dhcp_agent.ini /etc/neutron/l3_agent.ini /etc/neutron/metadata_agent.ini /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugins/ml2/openvswitch_agent.ini; do
  if [ -f "$f" ]; then echo "  PRESENT $f"; else echo "  ABSENT  $f"; fi
done
echo "  --- ml2_conf.ini:"
grep -E "^(mechanism_drivers|type_drivers|tenant_network_types|flat_networks|network_vlan_ranges)" /etc/neutron/plugins/ml2/ml2_conf.ini 2>/dev/null | sed "s/^/    /"
echo "  --- openvswitch_agent.ini:"
grep -E "^(bridge_mappings|integration_bridge|tunnel_bridge|local_ip|firewall_driver)" /etc/neutron/plugins/ml2/openvswitch_agent.ini 2>/dev/null | sed "s/^/    /"
echo "  --- dhcp_agent.ini:"
grep -E "^(interface_driver|enable_isolated_metadata|force_metadata|enable_metadata_network)" /etc/neutron/dhcp_agent.ini 2>/dev/null | sed "s/^/    /"
echo "  --- l3_agent.ini:"
grep -E "^(interface_driver|external_network_bridge|agent_mode)" /etc/neutron/l3_agent.ini 2>/dev/null | sed "s/^/    /"
echo "  --- neutron.conf:"
grep -E "^(core_plugin|service_plugins|allow_overlapping_ips)" /etc/neutron/neutron.conf 2>/dev/null | sed "s/^/    /"
'

echo
echo "== [L] devstack unit files (C1.5 targets) =="
sudo docker exec p003-os bash -c 'ls /etc/systemd/system/ 2>/dev/null | grep devstack | sed "s/^/  unit: /"'
sudo docker exec p003-os bash -c '
for u in q-agt q-dhcp q-l3 q-meta g-api g-reg n-api n-cpu n-cond n-sch placement-api n-api-meta n-novnc; do
  f=/etc/systemd/system/devstack@$u.service
  if [ -f "$f" ]; then echo "  --- devstack@$u"; grep -E "^(ExecStart|User)=" "$f" | sed "s/^/    /"; fi
done'

echo
echo "== [M] databases synced? (nova/glance/placement) =="
sudo docker exec p003-os bash -c '
PW=$(sed -n "s/^MYSQL_PASSWORD=//p" /opt/stack/devstack/local.conf 2>/dev/null | head -1)
[ -z "$PW" ] && PW=$(sed -n "s/^DATABASE_PASSWORD=//p" /opt/stack/devstack/local.conf 2>/dev/null | head -1)
for db in nova nova_api nova_cell0 glance placement neutron keystone; do
  n=$(mysql -uroot -p"$PW" -N -e "select count(*) from information_schema.tables where table_schema=\"$db\"" 2>/dev/null)
  echo "  $db: ${n:-UNREACHABLE} tables"
done'

echo
echo "== [N] host routes (must stay intact) =="
ip route | grep -E '10\.30\.|10\.202\.|10\.245\.|10\.101\.|172\.1[79]\.|198\.19\.' | sed 's/^/  /'
echo "  docker0 extra addrs: $(ip -o addr show docker0 | grep -c 10.40 || echo 0) (expect 0)"
echo
echo "== PREFLIGHT DONE (read-only) =="
