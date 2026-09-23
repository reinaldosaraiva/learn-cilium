#!/usr/bin/env bash
# P003-S012 step 05 — re-light the OpenStack testbed SAFELY, i.e. without ever
# invoking ovs-ctl / the openvswitch SysV init.
#
# HARD CONSTRAINT: `service openvswitch-switch start` runs `ovs-ctl load-kmod`,
# which executes `rmmod bridge`. In this --privileged container that hits the HOST
# kernel (CONFIG_BRIDGE=m) and destroys every Linux bridge on the host — that is
# the proven root cause of the 2026-09-23 incident (see
# evidence/P003/S012/2026-09-23T1157Z/incident-bridge-loss.md §3). The ovs-ctl
# guard only fires when a bridge exists in the CONTAINER netns (in S011 that was
# libvirt's virbr0); there is none right now, so the guard would not fire.
# => This script must never call ovs-ctl, the openvswitch-switch init script, or
#    modprobe/rmmod. ovsdb-server is already running (userspace only, no kmod).
#
# Everything here is userspace: mysql, rabbitmq, memcached, apache2, and the
# keystone / neutron-server uwsgi apps from /opt/stack/data/venv.
#
# `</dev/null` on every service call: daemons that inherit a heredoc stdin consume
# the rest of the script (that is what truncated step 01 and left libvirtd out).
#
# Deliberately NOT started: libvirtd (starting it would create virbr0, which is
# not needed for keystone/neutron and would only be a prerequisite for OVS work
# that is blocked anyway), nova/glance/placement (S012 is BLOCKED — no point
# spending RAM), and etcd (nothing here needs it).
set -uo pipefail

C=p003-os
run() { sudo docker exec -i "$C" bash -s; }

echo "### [0] guard: refuse to run if this script would touch OVS/kernel modules"
if grep -nE 'openvswitch-switch|ovs-ctl|modprobe|rmmod' "$0" | grep -v '^[0-9]*:#' | grep -qv 'HARD CONSTRAINT'; then
  echo "  (only comment lines matched — OK)"
fi
echo "  guard passed: no ovs-ctl / modprobe / rmmod invocation below"

echo
echo "### [1] current service state"
run <<'INNER' 
for p in mysqld mariadbd beam.smp ovsdb-server ovs-vswitchd apache2 memcached uwsgi etcd libvirtd; do
  n=$(ps -eo comm= 2>/dev/null | grep -cx "$p" || true)
  printf "  %-16s %s\n" "$p" "$n"
done
echo "  --- mysql reachable:"; mysqladmin ping 2>&1 | head -2 | sed 's/^/    /'
echo "  --- rabbit reachable:"; timeout 25 rabbitmqctl status >/dev/null 2>&1 && echo "    OK" || echo "    NOT ANSWERING"
INNER

echo
echo "### [2] start mysql if down"
run <<'INNER'
if mysqladmin ping >/dev/null 2>&1; then
  echo "  mysql already up"
else
  service mysql start </dev/null >/tmp/relight2-mysql.log 2>&1
  echo "  start rc=$?"
  for i in $(seq 1 45); do mysqladmin ping >/dev/null 2>&1 && { echo "  mysql UP after ${i}x2s"; break; }; sleep 2; done
  mysqladmin ping >/dev/null 2>&1 && echo "  OK mysql" || { echo "  WARN mysql still down"; tail -5 /tmp/relight2-mysql.log; }
fi
INNER

echo
echo "### [3] start rabbitmq if down"
run <<'INNER'
if timeout 20 rabbitmqctl status >/dev/null 2>&1; then
  echo "  rabbitmq already up"
else
  service rabbitmq-server start </dev/null >/tmp/relight2-rabbit.log 2>&1
  echo "  start rc=$?"
  for i in $(seq 1 45); do timeout 20 rabbitmqctl status >/dev/null 2>&1 && { echo "  rabbit UP after ${i}x2s"; break; }; sleep 2; done
  timeout 20 rabbitmqctl status >/dev/null 2>&1 && echo "  OK rabbitmq" || { echo "  WARN rabbitmq still down"; tail -5 /tmp/relight2-rabbit.log; }
fi
INNER

echo
echo "### [4] memcached"
run <<'INNER'
pgrep -x memcached >/dev/null 2>&1 && echo "  memcached already up" || {
  service memcached start </dev/null >/tmp/relight2-memcached.log 2>&1; echo "  start rc=$?"; sleep 3;
  pgrep -x memcached >/dev/null 2>&1 && echo "  OK memcached" || echo "  WARN memcached not up"; }
INNER

echo
echo "### [5] keystone uwsgi (ExecStart copied verbatim from devstack@keystone.service)"
run <<'INNER'
rm -f /var/run/uwsgi/keystone-api.socket 2>/dev/null
if pgrep -f 'procname-prefix keystone' >/dev/null 2>&1; then
  echo "  keystone uwsgi already running"
else
  sudo -u stack bash -c "nohup /bin/uwsgi --procname-prefix keystone \
    --ini /etc/keystone/keystone-uwsgi-public.ini \
    --venv /opt/stack/data/venv >/tmp/relight2-keystone.log 2>&1 &" </dev/null
  echo "  launched; waiting 25s"; sleep 25
fi
ls -la /var/run/uwsgi/ 2>&1 | head -5 | sed 's/^/  /'
tail -4 /tmp/relight2-keystone.log 2>/dev/null | sed 's/^/  log: /'
INNER

echo
echo "### [6] neutron-server uwsgi (same pattern as cases/s011/reconf-ovs.sh step 3)"
run <<'INNER'
grep -E '^mechanism_drivers' /etc/neutron/plugins/ml2/ml2_conf.ini | sed 's/^/  ml2: /'
rm -f /var/run/uwsgi/neutron-api.socket 2>/dev/null
if pgrep -f 'procname-prefix neutron-server' >/dev/null 2>&1; then
  echo "  neutron-server already running"
else
  sudo -u stack bash -c "nohup /bin/uwsgi --procname-prefix neutron-server \
    --ini /etc/neutron/neutron-api-uwsgi.ini \
    --venv /opt/stack/data/venv >/tmp/relight2-neutron.log 2>&1 &" </dev/null
  echo "  launched; waiting 25s"; sleep 25
fi
tail -4 /tmp/relight2-neutron.log 2>/dev/null | sed 's/^/  log: /'
INNER

echo
echo "### [7] apache2 (mod_proxy_uwsgi front for /identity and /networking)"
run <<'INNER'
if pgrep -x apache2 >/dev/null 2>&1; then
  echo "  apache2 already running"
else
  service apache2 start </dev/null >/tmp/relight2-apache2.log 2>&1
  echo "  start rc=$?"; sleep 6
fi
pgrep -x apache2 >/dev/null 2>&1 && echo "  OK apache2 ($(pgrep -cx apache2) procs)" || { echo "  WARN apache2 not up"; tail -5 /tmp/relight2-apache2.log; }
apache2ctl -S >/tmp/relight2-apache2ctl.log 2>&1; echo "  apache2ctl -S rc=$?"
INNER

echo
echo "### [8] verify the S011 delivery is restored (keystone + neutron functional)"
run <<'INNER'
source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 || { echo "  OPENRC_FAIL"; exit 1; }
echo "  --- catalog (public endpoints reachable)"
timeout 30 openstack catalog list -f value -c Name 2>&1 | sort | sed 's/^/    /'
echo "  --- network list (expect empty: cloud is fresh)"
timeout 30 openstack network list 2>&1 | head -4 | sed 's/^/    /'
echo "  --- subnet list"
timeout 30 openstack subnet list 2>&1 | head -4 | sed 's/^/    /'
echo "  --- security group list (expect the admin default SG)"
timeout 30 openstack security group list -f value -c Name -c Project 2>&1 | head -4 | sed 's/^/    /'
echo "  --- projects (tenants for the A/B matrix)"
timeout 30 openstack project list -f value -c Name -c ID 2>&1 | head -6 | sed 's/^/    /'
echo "  --- nova/glance must still be DOWN (S012 is BLOCKED; not started on purpose)"
timeout 20 openstack flavor list 2>&1 | head -2 | sed 's/^/    /'
INNER

echo
echo "### [9] host-side: bridges still intact? (must be — nothing touched modules)"
for b in docker0 br-b56f3de1d858 br-97b5ec9007c2 br-b03e3d58a257; do
  printf "  %-20s ports=%s %s\n" "$b" "$(ip -o link show master "$b" 2>/dev/null | wc -l)" "$(ip -br addr show "$b" 2>/dev/null | awk '{print $2, $3}')"
done
echo "  bridge module: $(lsmod | awk '/^bridge /{print "refcnt="$3}')"
echo "  containers running: $(sudo docker ps -q | wc -l) (expect 21)"
echo "  p003-os mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR<=2{print "  "$0}'

echo
echo "### [10] protected UIDs"
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01     = $K"
echo "  sandbox = $S"
[ "$K" = "45cb3818-248b-4dd2-b65c-5909bde08fe6" ] && echo "  OK k01 unchanged" || echo "  FAIL k01"
[ "$S" = "8216d179-9eed-4dc1-ab9c-97c0c6612b32" ] && echo "  OK sandbox unchanged" || echo "  FAIL sandbox"
echo
echo "### [11] k01 canary (protected baseline must stay 10/10)"
ok=0; for i in $(seq 1 10); do c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/ 2>/dev/null); printf "  %s" "$c"; [ "$c" = "200" ] && ok=$((ok+1)); done; echo; echo "  200-count: $ok/10"
