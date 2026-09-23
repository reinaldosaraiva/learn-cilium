#!/usr/bin/env bash
# diag services nova_cell1 (via arquivo — sem quoting aninhado)
set -uo pipefail
sudo /usr/bin/docker exec -i p003-os bash -s <<'EOS'
PW=$(grep -m1 "^connection = mysql" /etc/nova/nova.conf | sed -E 's|.*//([^:]+):([^@]+)@.*|\2|')
echo "=== nova_cell1.services (todas) ==="
mysql -uroot -p"$PW" -N -e 'select host,binary,disabled,deleted from nova_cell1.services' 2>/dev/null
echo "=== nova_cell0.services (todas) ==="
mysql -uroot -p"$PW" -N -e 'select host,binary,disabled,deleted from nova_cell0.services' 2>/dev/null
echo "=== nova_cell1.compute_nodes: count ==="
mysql -uroot -p"$PW" -N -e 'select count(*) from nova_cell1.compute_nodes' 2>/dev/null
EOS
