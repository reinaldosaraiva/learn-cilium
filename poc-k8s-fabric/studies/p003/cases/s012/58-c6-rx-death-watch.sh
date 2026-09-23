#!/usr/bin/env bash
# P003-S012 C6 — E1/E2: cronometrar a morte do rx da VM e instrumentar DENTRO
# da VM via pty do console serial (login cirros; saídas voltam no console log).
set -uo pipefail

echo "== [1] limpar e criar vm-a =="
sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1
for id in $(openstack server list --name vm-a -f value -c ID 2>/dev/null); do
  timeout 60 openstack server delete $id --wait >/dev/null 2>&1 || timeout 30 openstack server delete $id --force >/dev/null 2>&1
done
for d in $(timeout 20 virsh list --all --name 2>/dev/null); do timeout 20 virsh destroy $d >/dev/null 2>&1; timeout 20 virsh undefine $d >/dev/null 2>&1; done
sleep 2
timeout 540 openstack server create vm-a --image cirros-0.6.0 --flavor m1.p003 \
  --network net-a --security-group sg-a --config-drive True --user-data /opt/stack/vm-a-init.sh --wait >/dev/null 2>&1
echo "  status: $(openstack server show vm-a -f value -c status)"' &
for i in $(seq 1 18); do
  sleep 30
  ST=$(sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && openstack server list --name vm-a -f value -c Status 2>/dev/null | head -1')
  echo "  t$((i*30))s: ${ST:-?}"
  [ "$ST" = "ACTIVE" ] && break
  [ "$ST" = "ERROR" ] && break
done
if [ "$ST" != "ACTIVE" ]; then echo "ABORT ($ST)"; exit 3; fi
ADDR=$(sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && openstack server list --name vm-a -f value -c Networks | grep -oE "10\.30\.0\.[0-9]+')
echo "  IP: $ADDR"
QR=$(sudo /usr/bin/docker exec p003-os bash -c 'ip netns list | awk "/qrouter/{print \$1}" | head -1')

echo
echo "== [2] watch: ping qrouter->VM a cada 10s + estado do domínio =="
DOM=$(sudo /usr/bin/docker exec p003-os bash -c 'timeout 20 virsh list --name --state-running 2>/dev/null | head -1')
echo "  dominio: $DOM"
LAST_OK=-1; DEATH_T=""
for i in $(seq 1 36); do
  T=$((i*10))
  RC=$(sudo /usr/bin/docker exec p003-os bash -c "ip netns exec $QR ping -c1 -W2 $ADDR >/dev/null 2>&1 && echo ok || echo dead")
  DS=$(sudo /usr/bin/docker exec p003-os bash -c "timeout 15 virsh domstate $DOM 2>/dev/null")
  echo "  t${T}s ping=$RC dom=$DS"
  if [ "$RC" = "ok" ]; then LAST_OK=$T; fi
  if [ "$RC" = "dead" ] && [ "$LAST_OK" != "-1" ] && [ -z "$DEATH_T" ]; then
    DEATH_T=$T
    echo "  >>> TRANSIÇÃO ok->dead entre t${LAST_OK}s e t${T}s"
    break
  fi
  [ "$i" = "36" ] && echo "  (fim da janela: last_ok=${LAST_OK}s)"
done

echo
echo "== [3] captura no instante =="
TAP=$(sudo /usr/bin/docker exec p003-os bash -c 'ovs-vsctl list-ports br-int | grep tap | head -1')
sudo /usr/bin/docker exec p003-os bash -c "ovs-vsctl get interface $TAP statistics | tr ',' '\n' | grep -E 'rx_|tx_' | sed 's/^/  tap /'" | head -8
sudo /usr/bin/docker exec p003-os bash -c "timeout 15 virsh domstate $DOM 2>/dev/null | sed 's/^/  domstate: /'; pgrep -af qemu-system | head -1 | cut -c1-80 | sed 's/^/  qemu: /'"
sudo /usr/bin/docker exec p003-os bash -c 'dmesg 2>/dev/null | tail -6 | cut -c1-150 | sed "s/^/  dmesg: /"' || true

echo
echo "== [4] instrumentação DENTRO da VM (pty do console) =="
PTY=$(sudo /usr/bin/docker exec p003-os bash -c "timeout 15 virsh dumpxml $DOM 2>/dev/null | grep -oE \"path='/dev/pts/[0-9]+'\" | head -1 | grep -oE '/dev/pts/[0-9]+'")
echo "  pty: $PTY"
if [ -n "$PTY" ]; then
  sudo /usr/bin/docker exec p003-os bash -c "
    exec 3>\$PTY || exit 1
    printf '\r\n' >&3; sleep 3
    printf 'cirros\r\n' >&3; sleep 2
    printf 'gocubsgo\r\n' >&3; sleep 3
    printf 'echo P003-IN-VM-MARK; ip link show eth0; ip neigh; ip addr show eth0 | grep inet\r\n' >&3; sleep 4
    printf 'dmesg | tail -6\r\n' >&3; sleep 4
    printf 'cat /proc/interrupts | grep -iE \"virtio|eth0\" | head -4\r\n' >&3; sleep 4
    exec 3<&-
  " 2>&1 | sed 's/^/  inject: /'
  sleep 6
  echo "  --- console log (rodapé):"
  sudo /usr/bin/docker exec p003-os bash -c 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && timeout 40 openstack console log show vm-a 2>/dev/null | tail -30' | sed 's/^/  /'
fi

echo
echo "== [5] lab =="
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo /usr/bin/docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
