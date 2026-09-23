#!/usr/bin/env bash
# P003-S012 C6 — watch + instrumentação na VM VIVA (ad636a8e / 10.30.0.173).
set -uo pipefail
ADDR=10.30.0.173
DOM=instance-00000016
echo "== [0] domínio certo? =="
DOM=$(sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1; SID=$(openstack server show ad636a8e-69cc-4bea-afc0-bd3a1c3f2412 -f value -c id 2>/dev/null); timeout 20 virsh list --all 2>/dev/null | head -4; echo "---"; timeout 15 virsh domstate instance-00000016 2>/dev/null')
echo "$DOM" | sed 's/^/  /'
QR=$(sudo /usr/bin/docker exec p003-os bash -c 'ip netns list | awk "/qrouter/{print \$1}" | head -1')

echo
echo "== [1] watch ping (12x10s) =="
for i in $(seq 1 12); do
  T=$((i*10))
  RC=$(sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR ping -c1 -W2 $ADDR >/dev/null 2>&1 && echo ok || echo dead")
  echo "  t${T}s: $RC"
  [ "$RC" = "dead" ] && [ "$i" -gt 1 ] && break
done

echo
echo "== [2] estado do qemu/tap =="
TAP=$(sudo /usr/bin/docker exec p003-os bash -c 'ovs-vsctl list-ports br-int | grep tap | head -1')
sudo /usr/bin/docker exec p003-os bash -c "ovs-vsctl get interface $TAP statistics | tr ',' '\n' | grep -E 'rx_packets|tx_packets|rx_bytes|tx_bytes' | sed 's/^/  /'"
sudo /usr/bin/docker exec p003-os bash -c "timeout 15 virsh domstate instance-00000016 2>/dev/null | sed 's/^/  dom: /'; pgrep -c qemu-system | sed 's/^/  qemu procs: /'"

echo
echo "== [3] login via pty + comandos in-VM =="
PTY=$(sudo /usr/bin/docker exec p003-os bash -c "timeout 15 virsh dumpxml instance-00000016 2>/dev/null | grep -oE \"path='/dev/pts/[0-9]+'\" | head -1 | grep -oE '/dev/pts/[0-9]+'")
echo "  pty: $PTY"
if [ -n "$PTY" ]; then
  sudo /usr/bin/docker exec p003-os bash -c "
    exec 3>$PTY
    printf '\r\n' >&3; sleep 3
    printf 'cirros\r\n' >&3; sleep 2
    printf 'gocubsgo\r\n' >&3; sleep 3
    printf 'echo P003-MARK; ip link show eth0; ip neigh show\r\n' >&3; sleep 5
    printf 'dmesg | tail -8\r\n' >&3; sleep 4
    printf 'cat /proc/interrupts | grep -iE \"virtio\" | head -5\r\n' >&3; sleep 4
    exec 3<&-
  " 2>&1 | sed 's/^/  inject: /'
  sleep 6
  echo "  --- console:"
  sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 40 openstack console log show ad636a8e-69cc-4bea-afc0-bd3a1c3f2412 2>/dev/null | tail -32' | sed 's/^/  /'
fi

echo
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "canário k01: $c"
