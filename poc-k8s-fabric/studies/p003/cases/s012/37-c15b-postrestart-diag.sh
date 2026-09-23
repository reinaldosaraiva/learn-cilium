#!/usr/bin/env bash
# P003-S012 rodada 2 — diag pós-restart libvirtd: por que ComputeFilter=0?
set -uo pipefail
sudo docker exec p003-os bash -c '
echo "=== list_hosts ==="
sudo -u stack /opt/stack/data/venv/bin/nova-manage cell_v2 list_hosts 2>/dev/null | grep -aE "^\|"
PW=$(grep -m1 "^connection = mysql" /etc/nova/nova.conf | sed -E "s|.*//([^:]+):([^@]+)@.*|\2|")
echo "=== nova_cell1.compute_nodes ==="
mysql -uroot -p"$PW" -N -e "select hypervisor_hostname,host,deleted from nova_cell1.compute_nodes" 2>/dev/null
echo "=== nova_cell1.services (nova-compute) ==="
mysql -uroot -p"$PW" -N -e "select host,binary,disabled,deleted from nova_cell1.services where binary=\"nova-compute\"" 2>/dev/null
echo "=== nova_api.host_mappings ==="
mysql -uroot -p"$PW" -N -e "select host from nova_api.host_mappings" 2>/dev/null
'
echo "=== scheduler: últimas linhas com timestamp ==="
ssh_self=1
sudo docker exec p003-os bash -c 'grep -a "returned 0 hosts" /opt/stack/logs/n-sch.log | tail -3 | cut -c1-120' | sed 's/^/  /'
