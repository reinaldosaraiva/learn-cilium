#!/usr/bin/env bash
# P003-S012 C6 — purga de linhas fantasma "vm-a" no nova (deleted=0, sem host),
# que poluem lookups por nome. Marca deleted=1 + uuid suffix (padrão nova).
set -uo pipefail
sudo /usr/bin/docker exec -i p003-os bash -s <<'EOS'
PW=$(grep -m1 "^connection = mysql" /etc/nova/nova.conf | sed -E 's|.*//([^:]+):([^@]+)@.*|\2|')
echo "=== instances vm-a (antes) ==="
mysql -uroot -p"$PW" -N -e "select uuid,vm_state,task_state,host,deleted from nova_cell1.instances where hostname='vm-a' or display_name='vm-a'" 2>/dev/null
echo "=== marcando ghosts como deleted ==="
mysql -uroot -p"$PW" -N -e "update nova_cell1.instances set deleted=1, deleted_at=now(), uuid=concat(uuid,'-del') where (hostname='vm-a' or display_name='vm-a') and host is null" 2>/dev/null
echo "=== instance_mappings órfãs ==="
mysql -uroot -p"$PW" -N -e "select count(*) from nova_api.instance_mappings im left join nova_cell1.instances i on i.uuid=im.instance_uuid where i.uuid is null" 2>/dev/null | sed 's/^/  orfãs: /'
mysql -uroot -p"$PW" -N -e "delete im from nova_api.instance_mappings im left join nova_cell1.instances i on i.uuid=im.instance_uuid where i.uuid is null" 2>/dev/null
echo "=== server list (depois) ==="
source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1
openstack server list 2>&1 | head -5
EOS
