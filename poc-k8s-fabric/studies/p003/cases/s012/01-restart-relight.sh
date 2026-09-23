#!/usr/bin/env bash
# P003-S012 step 01 — restart the p003-os testbed container, then re-light the
# base stack (mysql, rabbitmq, OVS, memcached, etcd, apache2, keystone,
# neutron-server, libvirtd).
#
# WHY restart: PID 1 of p003-os is `sleep` (created without --init by
# cases/s011/01-devstack-container.sh), so nothing reaps children. 2556 of 2619
# processes were zombies, growing ~3.3/min from a RabbitMQ inet_gethost spawn
# loop. Owner decision D3 (2026-09-23) = `docker restart`, NOT recreate.
#
# WHY restart is safe: the image is bare ubuntu:24.04 and all 887 packages plus
# every /etc config live in the WRITABLE LAYER (docker diff = 59353 entries),
# which `docker restart` PRESERVES. /opt/stack is a bind mount and also survives.
# Only running processes are lost. `docker rm`+`run` would have destroyed all of
# it — do not substitute that here.
#
# Authorized: evidence/P003/S012/2026-09-23T1157Z/authorization.md (D1 full
# execution, D3 docker restart). Does NOT touch k01, the p003-gw sandbox, the
# host NIC, or the container memory cap.
set -uo pipefail

C="${C:-p003-os}"
SANDBOX_KCFG=/root/.kube/p003-gw.config
SANDBOX_CTX=kind-p003-gw
SANDBOX_UID=8216d179-9eed-4dc1-ab9c-97c0c6612b32
K01_KCFG=/root/.kube/k01-rebuild.config
K01_CTX=kind-k01
K01_UID=45cb3818-248b-4dd2-b65c-5909bde08fe6

fail() { echo "FAIL: $*"; exit 1; }

echo "### [0] revalidate protected UIDs BEFORE any mutation"
S_UID=$(sudo kubectl --kubeconfig "$SANDBOX_KCFG" --context "$SANDBOX_CTX" \
  get ns kube-system -o jsonpath='{.metadata.uid}') || fail "cannot read sandbox UID"
K_UID=$(sudo kubectl --kubeconfig "$K01_KCFG" --context "$K01_CTX" \
  get ns kube-system -o jsonpath='{.metadata.uid}') || fail "cannot read k01 UID"
echo "sandbox kube-system uid = $S_UID"
echo "k01     kube-system uid = $K_UID"
[ "$S_UID" = "$SANDBOX_UID" ] || fail "sandbox UID changed: $S_UID != $SANDBOX_UID"
[ "$K_UID" = "$K01_UID" ]     || fail "k01 UID changed: $K_UID != $K01_UID"
echo "OK: both protected baselines unchanged"

echo
echo "### [1] BEFORE state (zombies / pids / memory)"
sudo docker exec -i "$C" bash -s <<'INNER'
echo "procs_total=$(ps -e --no-headers | wc -l)"
echo "zombies=$(ps -eo stat= | grep -c Z || true)"
echo "pids_current=$(cat /sys/fs/cgroup/pids.current)"
echo "pids_max=$(cat /sys/fs/cgroup/pids.max)"
echo "memory_current_bytes=$(cat /sys/fs/cgroup/memory.current)"
INNER
sudo docker stats --no-stream --format 'dockerstats={{.Name}} mem={{.MemUsage}} cpu={{.CPUPerc}}' "$C"
echo "--- host free -g ---"; free -g | awk 'NR<=2'

echo
echo "### [2] docker restart $C (preserves writable layer)"
sudo docker restart "$C" || fail "docker restart failed"
echo "waiting 15s for the container to settle"
sleep 15
sudo docker ps --filter "name=$C" --format '{{.Names}} {{.Status}}'
sudo docker exec -i "$C" bash -s <<'INNER'
echo "procs_total_after_restart=$(ps -e --no-headers | wc -l)"
echo "zombies_after_restart=$(ps -eo stat= | grep -c Z || true)"
echo "pid1=$(cat /proc/1/comm)"
INNER

echo
echo "### [3] re-light infrastructure services (SysV, in order)"
sudo docker exec -i "$C" bash -s <<'INNER'
set -uo pipefail
for s in openvswitch-switch memcached mysql rabbitmq-server; do
  echo "--- starting $s"
  service "$s" start >/tmp/relight-$s.log 2>&1
  echo "    rc=$? ; log tail:"; tail -3 /tmp/relight-$s.log 2>/dev/null | sed 's/^/      /'
done

echo "--- waiting for mysql to accept connections (up to 120s)"
for i in $(seq 1 60); do
  if mysqladmin ping >/dev/null 2>&1; then echo "    mysql UP after ${i}x2s"; break; fi
  sleep 2
done
mysqladmin ping >/dev/null 2>&1 && echo "OK mysql" || echo "WARN mysql not answering ping"

echo "--- waiting for rabbitmq (up to 120s)"
for i in $(seq 1 60); do
  if rabbitmqctl status >/dev/null 2>&1; then echo "    rabbit UP after ${i}x2s"; break; fi
  sleep 2
done
rabbitmqctl status >/dev/null 2>&1 && echo "OK rabbitmq" || echo "WARN rabbitmq not answering"

echo "--- ovs state"
ovs-vsctl show 2>&1 | head -12

echo "--- etcd (restart-safe: --initial-cluster-state existing)"
if pgrep -x etcd >/dev/null 2>&1; then
  echo "    etcd already running"
else
  nohup /opt/stack/bin/etcd --name aaa1593bb5e1 --data-dir /opt/stack/data/etcd \
    --initial-cluster-state existing --initial-cluster-token etcd-cluster-01 \
    --initial-cluster aaa1593bb5e1=http://172.17.0.2:2380 \
    --initial-advertise-peer-urls http://172.17.0.2:2380 \
    --advertise-client-urls http://172.17.0.2:2379 \
    --listen-peer-urls http://0.0.0.0:2380 \
    --listen-client-urls http://172.17.0.2:2379 \
    >/tmp/relight-etcd.log 2>&1 &
  sleep 5
  pgrep -x etcd >/dev/null 2>&1 && echo "OK etcd" || { echo "WARN etcd not up (non-fatal)"; tail -5 /tmp/relight-etcd.log; }
fi

echo "--- libvirtd"
if pgrep -x libvirtd >/dev/null 2>&1; then
  echo "    libvirtd already running"
else
  nohup /usr/sbin/libvirtd >/tmp/relight-libvirtd.log 2>&1 &
  sleep 8
fi
pgrep -x libvirtd >/dev/null 2>&1 && echo "OK libvirtd pid=$(pgrep -x libvirtd | head -1)" || echo "WARN libvirtd not up"
timeout 25 virsh version 2>&1 | head -4

echo "--- stale uwsgi sockets"
rm -f /var/run/uwsgi/*.socket 2>/dev/null; ls -la /var/run/uwsgi/ 2>&1 | head -5

echo "--- keystone uwsgi (ExecStart from devstack@keystone.service)"
sudo -u stack bash -c "nohup /bin/uwsgi --procname-prefix keystone \
  --ini /etc/keystone/keystone-uwsgi-public.ini \
  --venv /opt/stack/data/venv >/tmp/relight-keystone.log 2>&1 &"
sleep 20

echo "--- neutron-server uwsgi (same pattern as cases/s011/reconf-ovs.sh)"
sudo -u stack bash -c "nohup /bin/uwsgi --procname-prefix neutron-server \
  --ini /etc/neutron/neutron-api-uwsgi.ini \
  --venv /opt/stack/data/venv >/tmp/relight-neutron.log 2>&1 &"
sleep 20

echo "--- apache2 (mod_proxy_uwsgi front for /identity /networking /compute /placement /image)"
service apache2 start >/tmp/relight-apache2.log 2>&1
sleep 5
apache2ctl -S >/tmp/apache2ctl-S.log 2>&1; echo "    apache2ctl -S rc=$?"
tail -3 /tmp/relight-apache2.log 2>/dev/null | sed 's/^/      /'

echo "--- sockets present?"
ls -la /var/run/uwsgi/ 2>&1 | head -8
INNER

echo
echo "### [4] verify keystone + neutron are functional again"
sudo docker exec -i "$C" bash -s <<'INNER'
source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1 || { echo "OPENRC_FAIL"; exit 1; }
echo "--- token / catalog reachability"
timeout 30 openstack endpoint list --interface public -f value -c Service 2>&1 | sort | head -10
echo "--- network list (expect empty, cloud still fresh)"
timeout 30 openstack network list 2>&1 | head -5
echo "--- subnet list"
timeout 30 openstack subnet list 2>&1 | head -5
echo "--- security group list"
timeout 30 openstack security group list 2>&1 | head -5
echo "--- project list (tenants for the A/B matrix)"
timeout 30 openstack project list -f value -c Name -c ID 2>&1 | head -8
INNER

echo
echo "### [5] AFTER state"
sudo docker exec -i "$C" bash -s <<'INNER'
echo "procs_total=$(ps -e --no-headers | wc -l)"
echo "zombies=$(ps -eo stat= | grep -c Z || true)"
echo "pids_current=$(cat /sys/fs/cgroup/pids.current)"
echo "memory_current_bytes=$(cat /sys/fs/cgroup/memory.current)"
INNER
sudo docker stats --no-stream --format 'dockerstats={{.Name}} mem={{.MemUsage}} cpu={{.CPUPerc}}' "$C"
echo "--- host free -g ---"; free -g | awk 'NR<=2'

echo
echo "### [6] revalidate protected UIDs AFTER restart (must be unchanged)"
S_UID2=$(sudo kubectl --kubeconfig "$SANDBOX_KCFG" --context "$SANDBOX_CTX" get ns kube-system -o jsonpath='{.metadata.uid}')
K_UID2=$(sudo kubectl --kubeconfig "$K01_KCFG" --context "$K01_CTX" get ns kube-system -o jsonpath='{.metadata.uid}')
echo "sandbox uid = $S_UID2"; echo "k01 uid = $K_UID2"
[ "$S_UID2" = "$SANDBOX_UID" ] || fail "sandbox UID changed during restart"
[ "$K_UID2" = "$K01_UID" ]     || fail "k01 UID changed during restart"
echo "OK: protected baselines intact — step 01 complete"
