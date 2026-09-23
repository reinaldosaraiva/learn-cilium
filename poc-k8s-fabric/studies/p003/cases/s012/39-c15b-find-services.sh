#!/usr/bin/env bash
# Onde estão os services do nova? Varredura information_schema.
set -uo pipefail
sudo /usr/bin/docker exec -i p003-os bash -s <<'EOS'
PW=$(grep -m1 "^connection = mysql" /etc/nova/nova.conf | sed -E 's|.*//([^:]+):([^@]+)@.*|\2|')
for db in $(mysql -uroot -p"$PW" -N -e "select table_schema from information_schema.tables where table_name='services'" 2>/dev/null); do
  n=$(mysql -uroot -p"$PW" -N -e "select count(*) from \`$db\`.services" 2>/dev/null)
  echo "  $db.services: $n"
  [ "$n" != "0" ] && mysql -uroot -p"$PW" -N -e "select host,binary,disabled,deleted from \`$db\`.services limit 6" 2>/dev/null | sed 's/^/    /'
done
EOS
