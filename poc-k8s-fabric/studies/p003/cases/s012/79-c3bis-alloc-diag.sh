#!/usr/bin/env bash
# diag: failed-to-allocate-networks — pool da subnet x portas órfãs.
set -uo pipefail
sudo /usr/bin/docker exec -i p003-os bash -s <<'EOS'
echo "=== fault no n-cond ==="
grep -a "85b32f7f" /opt/stack/logs/n-cond.log 2>/dev/null | grep -aiE "error|failed|neutron|exceed|ip" | tail -5 | cut -c1-180
echo "=== portas net-a ==="
source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1
openstack port list --network net-a -f value -c Status -c "Device Owner" 2>/dev/null | sort | uniq -c | sed 's/^/  /'
echo "=== pool subnet-a ==="
openstack subnet show subnet-a -f value -c allocation_pools 2>/dev/null | sed 's/^/  /'
PW=$(grep -m1 "^connection = mysql" /etc/nova/nova.conf | sed -E 's|.*//([^:]+):([^@]+)@.*|\2|')
echo "=== IPs alocados (neutron) ==="
mysql -uroot -p"$PW" -N -e "select ip_address from neutron.ipallocations" 2>/dev/null | wc -l | sed 's/^/  total: /'
mysql -uroot -p"$PW" -N -e "select ip_address from neutron.ipallocations" 2>/dev/null | tail -5 | sed 's/^/  /'
EOS
