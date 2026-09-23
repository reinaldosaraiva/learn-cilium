#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5b t20: captura ao vivo da janela de espera.
# create em bg; aos ~70s inspecionar: tap no br-int? porta bound? q-agt
# processando? rpc get_devices chegando?
set -uo pipefail

echo "== [1] dispara create em background =="
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; timeout 90 openstack server delete vm-a --wait >/dev/null 2>&1 || timeout 30 openstack server delete vm-a --force >/dev/null 2>&1; sleep 3; nohup timeout 700 openstack server create vm-a \
  --image cirros-0.6.0 --flavor m1.p003 --network net-a --security-group sg-a \
  --config-drive True --user-data /opt/stack/vm-a-init.sh --wait >/dev/null 2>&1 &' </dev/null
echo "  create disparado; aguardando 70s (spawn+plug os_vif)"; sleep 70

echo
echo "== [2] estado vivo =="
echo "  --- virsh:"
sudo /usr/bin/docker exec p003-os bash -c 'timeout 20 virsh list 2>/dev/null | head -4' | sed 's/^/  /'
echo "  --- taps no br-int:"
sudo /usr/bin/docker exec p003-os bash -c 'ovs-vsctl show | grep -E "Port \"tap" | sed "s/^/    /" || echo "    (nenhum tap)"'
echo "  --- portas net-a (admin):"
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1; openstack port list --network net-a 2>&1 | head -6' | sed 's/^/  /'
echo "  --- q-agt: 12 linhas recentes:"
sudo /usr/bin/docker exec p003-os bash -c 'tail -12 /opt/stack/logs/q-agt.log | grep -avE "DEBUG oslo|dbcounter" | cut -c1-170' | sed 's/^/  /'
echo "  --- q-agt: processing desde o create:"
sudo /usr/bin/docker exec p003-os bash -c 'grep -a "Processing port\|treat_devices\|Devices (updated\|process_updated" /opt/stack/logs/q-agt.log | tail -4 | cut -c1-170' | sed 's/^/  /'
echo "  --- q-rpc: get_device da porta (últimas chamadas):"
sudo /usr/bin/docker exec p003-os bash -c 'grep -a "get_devices_details_list\|update_device_up\|device_details" /opt/stack/logs/q-rpc.log 2>/dev/null | tail -4 | cut -c1-170' | sed 's/^/  /'

echo
echo "== [3] seguir até desfecho (poll 25s x 20) =="
for i in $(seq 1 20); do
  sleep 25
  ST=$(sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && openstack server show vm-a -f value -c status 2>/dev/null')
  echo "  t$((i*25+70))s: ${ST:-?}"
  [ "$ST" = "ACTIVE" ] && break
  [ "$ST" = "ERROR" ] && break
done
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; echo "  final: $(openstack server show vm-a -f value -c status)"; echo "  addr: $(openstack server show vm-a -f value -c addresses)"'
