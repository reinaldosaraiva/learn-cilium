#!/bin/bash
# P003-S011 — switch the deployed neutron from the (unusable, OVN DBs not
# installed) OVN mechanism driver to OVS, then restart neutron-server so the
# API + DB migrations come up. ovsdb is already running on the UNIX socket.
set -uo pipefail

echo "### [1] mechanism_drivers -> openvswitch"
sed -i 's/^mechanism_drivers = .*/mechanism_drivers = openvswitch/' \
  /etc/neutron/plugins/ml2/ml2_conf.ini
grep -E '^mechanism_drivers' /etc/neutron/plugins/ml2/ml2_conf.ini

echo "### [2] stop the existing neutron-server uwsgi (by /proc, no self-match)"
for p in /proc/[0-9]*/cmdline; do
  cl=$(tr '\0' ' ' < "$p" 2>/dev/null)
  case "$cl" in
    /bin/uwsgi*neutron-api-uwsgi.ini*)
      pid=$(basename "$(dirname "$p")")
      echo "killing neutron uwsgi PID $pid"
      kill -9 "$pid" 2>/dev/null || true
      ;;
  esac
done
sleep 2
rm -f /var/run/uwsgi/neutron-api.socket

echo "### [3] restart neutron-server uwsgi"
sudo -u stack bash -c \
  "nohup /bin/uwsgi --procname-prefix neutron-server \
   --ini /etc/neutron/neutron-api-uwsgi.ini \
   --venv /opt/stack/data/venv >/tmp/neutron-server-uwsgi.log 2>&1 &"
sleep 15

echo "### [4] verify"
ls -la /var/run/uwsgi/neutron-api.socket 2>&1 | head -1
echo "--- uwsgi log tail ---"
tail -6 /tmp/neutron-server-uwsgi.log 2>/dev/null
echo "--- DB tables now ---"
mysql -uroot -pp003s011dbpass -e "USE neutron; SHOW TABLES;" 2>/dev/null \
  | grep -icE "network|subnet|security_group|quota" | sed 's/^/table-count: /'
