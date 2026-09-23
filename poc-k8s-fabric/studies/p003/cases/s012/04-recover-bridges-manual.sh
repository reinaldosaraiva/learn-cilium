#!/usr/bin/env bash
# P003-S012 step 04 — R2: recreate the four destroyed host Docker bridges by
# hand and re-attach the 21 orphaned veths. NO container is restarted, so every
# containerlab-injected interface and all Cilium state is preserved.
#
# Why R2 and not R1: verified empirically — libnetwork does NOT recreate the
# bridge of an already-existing network when a container joins it. `docker run
# --network kind` fails with "adding interface vethXXXX to bridge
# br-b56f3de1d858 failed: Device does not exist" (dockerd log 14:30:21). Only
# `docker network create` builds a bridge, and `docker network rm --force` on the
# real networks would disconnect the running containers — which is exactly what
# we must not do. So the bridges are created with `ip link` and matched to the
# parameters Docker itself uses.
#
# Docker bridge parameters, measured from a throwaway `docker network create`
# probe on this host (2026-09-23):
#   mtu 1500, qdisc noqueue, stp_state 0, priority 32768, forward_delay 1500,
#   hello_time 200, max_age 2000, ageing_time 30000, vlan_filtering 0,
#   vlan_protocol 802.1Q, vlan_default_pvid 1, mcast_snooping 1,
#   nf_call_iptables 0, nf_call_ip6tables 0, nf_call_arptables 0,
#   addrgenmode eui64
# `ip link add type bridge` defaults match these, so only mtu is set explicitly.
#
# Docker's iptables rules for these networks key off the BRIDGE NAME and were
# never deleted, e.g.:
#   -A DOCKER ! -i br-X -o br-X -j DROP
#   -A DOCKER-BRIDGE -o br-X -j DOCKER
#   -A DOCKER-CT -o br-X -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
#   -A DOCKER-FORWARD -i br-X -j ACCEPT
#   -A POSTROUTING -s <subnet> ! -o br-X -j MASQUERADE
#   -A DOCKER -d 127.0.0.1/32 ! -i br-b56f3de1d858 -p tcp --dport 46403 -j DNAT
#     --to-destination 172.19.0.3:6443
# Recreating the interfaces under the same names therefore restores the data
# path without touching iptables.
#
# Fully reversible: `ip link del <bridge>` (and `ip link set <veth> nomaster`).
#
# Does not touch: any container, clab-ext/p003-ext, host routes, iptables, k01,
# the sandbox, or the p003-os memory cap.
set -uo pipefail

FAILURES=0
note() { echo "  $*"; }
bad()  { echo "  MISMATCH: $*"; FAILURES=$((FAILURES+1)); }

# net|bridge|v4|v6|mtu
NETWORKS=(
  "bridge|docker0|172.17.0.1/16||1500"
  "kind|br-b56f3de1d858|172.19.0.1/16|fc00:f853:ccd:e793::1/64|1500"
  "clab-poc-kind|br-97b5ec9007c2|10.223.31.1/24||1500"
  "p003-gw-mgmt|br-b03e3d58a257|10.223.32.1/24||1500"
)

# veth|host_ifindex|bridge|container|container_ip
VETHS=(
  "vethdfc7774|394|docker0|p003-os|172.17.0.2"
  "veth05bf324|292|br-b56f3de1d858|k01-worker|172.19.0.2"
  "veth071e3ce|293|br-b56f3de1d858|k01-control-plane|172.19.0.3"
  "veth97af946|294|br-b56f3de1d858|k01-worker2|172.19.0.4"
  "vethaf18009|371|br-b56f3de1d858|p003-gw-control-plane|172.19.0.5"
  "vethe5dfe12|372|br-b56f3de1d858|p003-gw-worker|172.19.0.6"
  "vethd652128|373|br-b56f3de1d858|p003-gw-worker2|172.19.0.7"
  "vethb0b7335|261|br-97b5ec9007c2|clab-poc-k8s-kind-leaf2|10.223.31.x"
  "veth5744630|262|br-97b5ec9007c2|clab-poc-k8s-kind-border1|10.223.31.3"
  "veth625b85a|263|br-97b5ec9007c2|clab-poc-k8s-kind-client-ext|10.223.31.x"
  "veth0e8d8fc|264|br-97b5ec9007c2|clab-poc-k8s-kind-leaf3|10.223.31.x"
  "vethde72fd6|265|br-97b5ec9007c2|clab-poc-k8s-kind-leaf1|10.223.31.x"
  "veth257beee|266|br-97b5ec9007c2|clab-poc-k8s-kind-spine2|10.223.31.x"
  "veth03baab7|267|br-97b5ec9007c2|clab-poc-k8s-kind-spine1|10.223.31.x"
  "veth2f109ff|340|br-b03e3d58a257|clab-p003-gw-fabric-spine1|10.223.32.x"
  "veth46dc7b5|341|br-b03e3d58a257|clab-p003-gw-fabric-leaf2|10.223.32.x"
  "vethe5f7bfa|342|br-b03e3d58a257|clab-p003-gw-fabric-client|10.223.32.4"
  "veth8691ce3|343|br-b03e3d58a257|clab-p003-gw-fabric-leaf3|10.223.32.x"
  "veth5a73376|344|br-b03e3d58a257|clab-p003-gw-fabric-spine2|10.223.32.x"
  "veth11ae7e8|345|br-b03e3d58a257|clab-p003-gw-fabric-border1|10.223.32.7"
  "vethf934520|346|br-b03e3d58a257|clab-p003-gw-fabric-leaf1|10.223.32.x"
)

echo "### [0] preconditions"
echo "  running containers: $(sudo docker ps -q | wc -l) (expect 21; must not change)"
BEFORE=$(sudo docker ps -q | sort | tr '\n' ' ')
echo "  bridges present:    $(ip -d link show type bridge 2>/dev/null | grep -c '^[0-9]*:' || true)"
echo "  veths present:      $(ip -br link show type veth 2>/dev/null | wc -l)"

echo
echo "### [1] create the four bridges"
for row in "${NETWORKS[@]}"; do
  IFS='|' read -r net br v4 v6 mtu <<<"$row"
  if ip link show "$br" >/dev/null 2>&1; then
    note "$br already exists — leaving it alone"
    continue
  fi
  if sudo ip link add name "$br" type bridge 2>&1; then
    sudo ip link set "$br" mtu "$mtu"
    sudo ip link set "$br" type bridge stp_state 0 vlan_filtering 0 2>/dev/null || true
    sudo ip addr add "$v4" dev "$br" 2>&1 | grep -v "File exists" || true
    if [ -n "$v6" ]; then
      sudo sysctl -qw "net.ipv6.conf.$br.disable_ipv6=0" 2>/dev/null || true
      sudo ip addr add "$v6" dev "$br" 2>&1 | grep -v "File exists" || true
    fi
    sudo ip link set "$br" up
    note "OK created $br  v4=$v4 ${v6:+v6=$v6} mtu=$mtu"
  else
    bad "could not create $br"
  fi
done

echo
echo "### [2] bridge state"
for row in "${NETWORKS[@]}"; do
  IFS='|' read -r net br v4 v6 mtu <<<"$row"
  printf "  %-20s " "$br"
  ip -br addr show "$br" 2>/dev/null | head -1 || echo "MISSING"
done
[ "$FAILURES" -eq 0 ] || { echo "ABORT: $FAILURES bridge(s) missing — not attaching veths"; exit 1; }

echo
echo "### [3] re-attach the 21 orphaned veths (guarded)"
for row in "${VETHS[@]}"; do
  IFS='|' read -r veth idx br cname cip <<<"$row"
  actual=$(ip -o link show "$veth" 2>/dev/null | sed -E 's/^([0-9]+):.*/\1/')
  if [ -z "$actual" ]; then bad "$veth for $cname no longer exists"; continue; fi
  if [ "$actual" != "$idx" ]; then bad "$veth ifindex=$actual expected=$idx — stale map"; continue; fi
  if ! sudo docker ps --format '{{.Names}}' | grep -qx "$cname"; then bad "$cname not running"; continue; fi
  peer=$(sudo docker exec "$cname" sh -c 'ip -o link show 2>/dev/null | grep -E "^[0-9]+: (eth0|mgmt0)@if" | head -1' 2>/dev/null | sed -E 's/^[0-9]+: [^@]+@if([0-9]+).*/\1/')
  if [ "$peer" != "$idx" ]; then bad "$cname peer ifindex='$peer' expected=$idx"; continue; fi
  if ip -o link show "$veth" | grep -q ' master '; then
    note "$veth already has a master — leaving as is ($cname)"
    continue
  fi
  if sudo ip link set "$veth" master "$br" && sudo ip link set "$veth" up; then
    note "OK $veth (if$idx) -> $br   [$cname $cip]"
  else
    bad "failed attaching $veth to $br"
  fi
done
echo "  guard failures: $FAILURES"

echo
echo "### [4] membership per bridge"
for row in "${NETWORKS[@]}"; do
  IFS='|' read -r net br v4 v6 mtu <<<"$row"
  n=$(ip -o link show master "$br" 2>/dev/null | wc -l)
  echo "  $br: $n port(s)"
  ip -o link show master "$br" 2>/dev/null | sed -E 's/^[0-9]+: ([^@]+)@.*/      \1/'
done

echo
echo "### [5] routes restored"
ip route | grep -E '172\.17\.|172\.19\.|10\.223\.3[12]\.' | sed 's/^/  /'

echo
echo "### [6] iptables rules still keyed to the bridge names"
for row in "${NETWORKS[@]}"; do
  IFS='|' read -r net br v4 v6 mtu <<<"$row"
  c=$(sudo iptables -S 2>/dev/null | grep -cF "$br")
  n=$(sudo iptables -t nat -S 2>/dev/null | grep -cF "$br")
  echo "  $br: filter=$c nat=$n rule(s)"
done
sudo iptables -t nat -S POSTROUTING 2>/dev/null | grep -E '172\.17\.|172\.19\.|10\.223\.3[12]\.' | sed 's/^/  /'

echo
echo "### [7] L3 reachability from the host"
for t in 172.17.0.2 172.19.0.2 172.19.0.3 172.19.0.4 172.19.0.5 172.19.0.6 172.19.0.7 10.223.31.3 10.223.32.7; do
  printf "  ping %-12s " "$t"
  ping -c1 -W2 "$t" >/dev/null 2>&1 && echo OK || echo FAIL
done
printf "  k01 API healthz   : "; curl -sk --max-time 10 https://172.19.0.3:6443/healthz; echo " (rc=$?)"
printf "  sandbox API healthz: "; curl -sk --max-time 10 https://172.19.0.5:6443/healthz; echo " (rc=$?)"
printf "  published k01 46403: "; curl -sk --max-time 10 https://127.0.0.1:46403/healthz; echo " (rc=$?)"
printf "  published sbx 34615: "; curl -sk --max-time 10 https://127.0.0.1:34615/healthz; echo " (rc=$?)"

echo
echo "### [8] protected UIDs — must be UNCHANGED (no container restarted)"
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  sandbox = $S"
echo "  k01     = $K"
[ "$S" = "8216d179-9eed-4dc1-ab9c-97c0c6612b32" ] && echo "  OK sandbox UID unchanged" || bad "sandbox UID mismatch/unreachable"
[ "$K" = "45cb3818-248b-4dd2-b65c-5909bde08fe6" ] && echo "  OK k01 UID unchanged"     || bad "k01 UID mismatch/unreachable"

echo
echo "### [9] nodes"
echo "  --- k01";     sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get nodes 2>&1 | sed 's/^/    /'
echo "  --- sandbox"; sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get nodes 2>&1 | sed 's/^/    /'

echo
echo "### [10] untouched interfaces + container set unchanged"
ip -br link show clab-ext 2>&1 | sed 's/^/  /'
ip -br link show p003-ext 2>&1 | sed 's/^/  /'
AFTER=$(sudo docker ps -q | sort | tr '\n' ' ')
echo "  containers before: $BEFORE"
echo "  containers after : $AFTER"
[ "$BEFORE" = "$AFTER" ] && echo "  OK no container was restarted" || bad "container set changed"

echo
echo "### RESULT: failures = $FAILURES"
[ "$FAILURES" -eq 0 ] && echo "RECOVERY OK" || echo "RECOVERY INCOMPLETE — see MISMATCH lines"
exit 0
