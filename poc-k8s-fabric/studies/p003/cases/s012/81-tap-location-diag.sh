#!/usr/bin/env bash
# P003-S012 D-S012-16 — DIAGNOSTICO AO VIVO: onde o tap da VM aparece?
# Hipótese: o ovs-vswitchd REABRE o netdev quando o tap aparece (provado com
# taptest0002, ofport em 6s). Logo, se a VM falha, o tap NÃO está no netns do
# container. Este script cria a VM em background e, durante o wait, captura:
#   - virsh list (o domínio sobe?)
#   - ip link (taps) no netns do CONTAINER e no netns do HOST
#   - processo qemu
#   - ofport da porta nova em br-int
#   - virsh dumpxml (seção <interface>)
# Uso: rodar NO HOST (vm-cilium). Destrói a VM ao final (teardown).
set -uo pipefail

D=docker
DX() { sudo $D exec p003-os bash -c "$1"; }

echo "== [0] estado pré (sem domínios; taps residuais anotados) =="
echo "  container taps: $(DX 'ip -o link show 2>/dev/null | grep -oiE "tap[a-z0-9-]+" | sort -u | tr "\n" " "') || echo sem"
echo "  host taps:      $(ip -o link show 2>/dev/null | grep -oiE 'tap[a-z0-9-]+' | sort -u | tr '\n' ' ')"
echo "  container netns: $(DX 'readlink /proc/1/ns/net')"
echo "  host netns:      $(readlink /proc/1/ns/net)"

echo
echo "== [1] limpar VMs/domínios residuais =="
DX 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1
for id in $(openstack server list -f value -c ID 2>/dev/null); do timeout 60 openstack server delete $id --wait >/dev/null 2>&1 || timeout 20 openstack server delete $id --force >/dev/null 2>&1; done
for d in $(timeout 20 virsh list --all --name 2>/dev/null); do timeout 15 virsh destroy $d >/dev/null 2>&1; timeout 10 virsh undefine $d >/dev/null 2>&1; done'
sleep 3

echo
echo "== [2] criar VM em background (sem --wait) =="
DX 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1
nohup openstack server create vm-a --image cirros-0.6.0 --flavor m1.p003 \
  --network net-a --security-group sg-a --config-drive True \
  --user-data /opt/stack/vm-a-init.sh >/tmp/diag-vm-create.log 2>&1 &
echo "  create lançado (pid $!)"'
sleep 3
SID=$(DX 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1 && openstack server list -f value -c ID 2>/dev/null | head -1')
echo "  SID=$SID"

echo
echo "== [3] poll durante o wait (18x5s) =="
for i in $(seq 1 18); do
  T=$(date -u +%H:%M:%S)
  CTAPS=$(DX 'ip -o link show 2>/dev/null | grep -oiE "tap[a-z0-9-]+" | sort -u | tr "\n" " "')
  HTAPS=$(ip -o link show 2>/dev/null | grep -oiE 'tap[a-z0-9-]+' | sort -u | tr '\n' ' ')
  DOM=$(DX 'virsh list --name 2>/dev/null | tr "\n" " "')
  QEMU=$(DX 'pgrep -c qemu-system 2>/dev/null || echo 0')
  OFP=$(DX 'ovs-vsctl --timeout=5 find interface external_ids:iface-id --format=pretty name ofport 2>/dev/null | grep -A1 -iE "tapa" | tr "\n" " " | head -c 120')
  echo "  [$T] dom=[$DOM] qemu=$QEMU | ctap=[$CTAPS] htap=[$HTAPS]"
  [ -n "${OFP// /}" ] && echo "        ofport: $OFP"
  sleep 5
done

echo
echo "== [4] virsh dumpxml (interface) se domínio existir =="
DX 'for d in $(virsh list --name 2>/dev/null); do
  echo "  --- dominio: $d ---"
  virsh dumpxml $d 2>/dev/null | sed -n "/<interface/,/<\/interface>/p" | sed "s/^/  /"
done'

echo
echo "== [5] status final da VM =="
DX 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1
openstack server show vm-a -f value -c status -c addresses 2>&1 | sed "s/^/  /"'

echo
echo "== [6] TEARDOWN: destruir VM + domínio + tap residual da VM =="
DX 'source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1
timeout 60 openstack server delete vm-a --wait >/dev/null 2>&1 || timeout 20 openstack server delete vm-a --force >/dev/null 2>&1
for d in $(virsh list --all --name 2>/dev/null); do timeout 15 virsh destroy $d >/dev/null 2>&1; timeout 10 virsh undefine $d >/dev/null 2>&1; done
sleep 2
echo "  pós-teardown container taps: $(ip -o link show 2>/dev/null | grep -oiE "tap[a-z0-9-]+" | sort -u | tr "\n" " ')"
echo "  canário k01: $(curl -s -o /dev/null -w "%{http_code}" --max-time 5 --noproxy "*" http://10.201.255.10:80/)"
