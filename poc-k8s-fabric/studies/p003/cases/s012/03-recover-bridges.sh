#!/usr/bin/env bash
# P003-S012 step 03 — recreate the four host Docker bridges that were destroyed,
# WITHOUT restarting any existing container.
#
# Why this shape: `systemctl restart docker` (Live Restore=false) would recreate
# every container netns and restore only Docker-managed eth0, permanently
# destroying the containerlab-injected links (eth1/eth2/eth3 on the clab nodes,
# eth1@if368 on p003-gw-control-plane) — those need `containerlab destroy`+`deploy`
# of both fabrics to come back. It would also leave 18 of 21 containers stopped
# (policies: no / on-failure). So we keep every netns untouched.
#
# Method (owner decision R1, 2026-09-23): a throwaway endpoint on each network
# makes libnetwork create the missing bridge with the correct name, IPAM, IPv6
# and iptables rules; then the 21 orphaned host veths are re-attached by hand.
#
# The throwaway endpoints are LOAD-BEARING ANCHORS: from Docker's point of view
# they are the only endpoints on those networks (Docker does not know about the
# manually attached veths), so removing them can make libnetwork tear the bridge
# down again. They are named p003-netfix-* and must be left running.
#
# Does not touch: k01, the p003-gw sandbox, clab-ext/p003-ext, host routes,
# iptables, or the p003-os memory cap.
set -uo pipefail

IMG="${IMG:-ubuntu:24.04}"
FAILURES=0
note() { echo "  $*"; }
bad()  { echo "  MISMATCH: $*"; FAILURES=$((FAILURES+1)); }

# net|bridge|v4addr[/prefix]|v6addr (empty if none)|mtu
NETWORKS=(
  "bridge|docker0|172.17.0.1/16||1500"
  "kind|br-b56f3de1d858|172.19.0.1/16|fc00:f853:ccd:e793::1/64|1500"
  "clab-poc-kind|br-97b5ec9007c2|10.223.31.1/24||1500"
  "p003-gw-mgmt|br-b03e3d58a257|10.223.32.1/24||1500"
)

# veth|host_ifindex|bridge|container  (map verified against the dmesg teardown)
VETHS=(
  "vethdfc7774|394|docker0|p003-os"
  "veth05bf324|292|br-b56f3de1d858|k01-worker"
  "veth071e3ce|293|br-b56f3de1d858|k01-control-plane"
  "veth97af946|294|br-b56f3de1d858|k01-worker2"
  "vethaf18009|371|br-b56f3de1d858|p003-gw-control-plane"
  "vethe5dfe12|372|br-b56f3de1d858|p003-gw-worker"
  "vethd652128|373|br-b56f3de1d858|p003-gw-worker2"
  "vethb0b7335|261|br-97b5ec9007c2|clab-poc-k8s-kind-leaf2"
  "veth5744630|262|br-97b5ec9007c2|clab-poc-k8s-kind-border1"
  "veth625b85a|263|br-97b5ec9007c2|clab-poc-k8s-kind-client-ext"
  "veth0e8d8fc|264|br-97b5ec9007c2|clab-poc-k8s-kind-leaf3"
  "vethde72fd6|265|br-97b5ec9007c2|clab-poc-k8s-kind-leaf1"
  "veth257beee|266|br-97b5ec9007c2|clab-poc-k8s-kind-spine2"
  "veth03baab7|267|br-97b5ec9007c2|clab-poc-k8s-kind-spine1"
  "veth2f109ff|340|br-b03e3d58a257|clab-p003-gw-fabric-spine1"
  "veth46dc7b5|341|br-b03e3d58a257|clab-p003-gw-fabric-leaf2"
  "vethe5f7bfa|342|br-b03e3d58a257|clab-p003-gw-fabric-client"
  "veth8691ce3|343|br-b03e3d58a257|clab-p003-gw-fabric-leaf3"
  "veth5a73376|344|br-b03e3d58a257|clab-p003-gw-fabric-spine2"
  "veth11ae7e8|345|br-b03e3d58a257|clab-p003-gw-fabric-border1"
  "vethf934520|346|br-b03e3d58a257|clab-p003-gw-fabric-leaf1"
)

echo "### [0] preconditions"
sudo docker image inspect "$IMG" >/dev/null 2>&1 || { echo "FAIL: image $IMG not present locally"; exit 1; }
echo "  image $IMG present"
echo "  bridges currently present: $(ip -d link show type bridge 2>/dev/null | grep -c '^[0-9]*:' || true)"
echo "  veths currently present:   $(ip -br link show type veth 2>/dev/null | wc -l)"
echo "  running containers:        $(sudo docker ps -q | wc -l)"

echo
echo "### [1] create the missing bridges via throwaway endpoints"
for row in "${NETWORKS[@]}"; do
  IFS='|' read -r net br v4 v6 mtu <<<"$row"
  helper="p003-netfix-${net//[^a-z0-9]/}"
  if ip link show "$br" >/dev/null 2>&1; then
    note "$br already exists — skipping helper for network '$net'"
    continue
  fi
  note "network '$net' -> creating via helper '$helper'"
  sudo docker rm -f "$helper" >/dev/null 2>&1 || true
  if sudo docker run -d --name "$helper" --network "$net" --restart no "$IMG" sleep infinity >/dev/null 2>&1; then
    sleep 4
    if ip link show "$br" >/dev/null 2>&1; then
      note "  OK $br created"
    else
      bad "helper started but bridge $br still missing"
    fi
  else
    bad "docker run failed for network '$net'"
  fi
done

echo
echo "### [2] bridges now present, with addresses"
for row in "${NETWORKS[@]}"; do
  IFS='|' read -r net br v4 v6 mtu <<<"$row"
  printf "  %-20s " "$br"
  if ip link show "$br" >/dev/null 2>&1; then
    ip -br addr show "$br" 2>/dev/null | head -1
  else
    echo "MISSING"
  fi
done
[ "$FAILURES" -eq 0 ] || { echo "ABORT: $FAILURES bridge(s) could not be created — not attaching veths"; exit 1; }

echo
echo "### [3] verify each expected address is on its bridge (fill gaps only if absent)"
for row in "${NETWORKS[@]}"; do
  IFS='|' read -r net br v4 v6 mtu <<<"$row"
  ip addr show "$br" 2>/dev/null | grep -q " ${v4%%/*}/" || { note "adding missing $v4 to $br"; sudo ip addr add "$v4" dev "$br"; }
  if [ -n "$v6" ]; then
    ip addr show "$br" 2>/dev/null | grep -q " ${v6%%/*}/" || { note "adding missing $v6 to $br"; sudo ip addr add "$v6" dev "$br"; }
  fi
  state=$(ip -br link show "$br" | awk '{print $2}')
  [ "$state" = "UP" ] || { note "bringing $br up"; sudo ip link set "$br" up; }
done

echo
echo "### [4] re-attach the 21 orphaned veths (with runtime map verification)"
for row in "${VETHS[@]}"; do
  IFS='|' read -r veth idx br cname <<<"$row"
  # guard 1: the veth must still exist and still hold the expected ifindex
  actual=$(ip -o link show "$veth" 2>/dev/null | sed -E 's/^([0-9]+):.*/\1/')
  if [ -z "$actual" ]; then bad "$veth (expected for $cname) no longer exists"; continue; fi
  if [ "$actual" != "$idx" ]; then bad "$veth ifindex is $actual, expected $idx — map is stale"; continue; fi
  # guard 2: the container must still be running and still point at this ifindex
  if ! sudo docker ps --format '{{.Names}}' | grep -qx "$cname"; then
    bad "container $cname is not running"; continue
  fi
  peer=$(sudo docker exec "$cname" sh -c 'ip -o link show 2>/dev/null | grep -E "^[0-9]+: (eth0|mgmt0)@if" | head -1' 2>/dev/null | sed -E 's/^[0-9]+: [^@]+@if([0-9]+).*/\1/')
  if [ "$peer" != "$idx" ]; then
    bad "$cname reports peer ifindex '$peer', expected $idx"; continue
  fi
  # guard 3: not already attached somewhere
  cur=$(ip -o link show "$veth" | sed -E 's/.*master ([^ ]+).*/\1/')
  if ip -o link show "$veth" | grep -q master; then
    note "$veth already has master '$cur' — leaving as is ($cname)"
    continue
  fi
  if sudo ip link set "$veth" master "$br" 2>/dev/null && sudo ip link set "$veth" up 2>/dev/null; then
    note "OK $veth (if$idx) -> $br   [$cname]"
  else
    bad "failed to attach $veth to $br"
  fi
done
echo "  verification failures: $FAILURES"

echo
echo "### [5] bridge membership after attach"
for row in "${NETWORKS[@]}"; do
  IFS='|' read -r net br v4 v6 mtu <<<"$row"
  n=$(ip -o link show master "$br" 2>/dev/null | wc -l)
  echo "  $br: $n port(s)"
  ip -o link show master "$br" 2>/dev/null | sed -E 's/^[0-9]+: ([^@]+)@.*/    \1/'
done

echo
echo "### [6] host routes"
ip route | grep -E '172\.17\.|172\.19\.|10\.223\.3[12]\.' | sed 's/^/  /'

echo
echo "### [7] reachability from the host"
for target in 172.17.0.2 172.19.0.3 172.19.0.5 10.223.31.3; do
  printf "  ping %-12s " "$target"
  ping -c1 -W2 "$target" >/dev/null 2>&1 && echo "OK" || echo "FAIL"
done
printf "  k01 API healthz  "; curl -sk --max-time 10 https://172.19.0.3:6443/healthz; echo " (rc=$?)"
printf "  sandbox API      "; curl -sk --max-time 10 https://172.19.0.5:6443/healthz; echo " (rc=$?)"

echo
echo "### [8] protected UIDs (must be unchanged — no container was restarted)"
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  sandbox = $S  (expect 8216d179-9eed-4dc1-ab9c-97c0c6612b32)"
echo "  k01     = $K  (expect 45cb3818-248b-4dd2-b65c-5909bde08fe6)"
[ "$S" = "8216d179-9eed-4dc1-ab9c-97c0c6612b32" ] && echo "  OK sandbox UID unchanged" || bad "sandbox UID mismatch/unreachable"
[ "$K" = "45cb3818-248b-4dd2-b65c-5909bde08fe6" ] && echo "  OK k01 UID unchanged"     || bad "k01 UID mismatch/unreachable"

echo
echo "### [9] node readiness"
echo "  --- k01"; sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get nodes 2>&1 | sed 's/^/    /'
echo "  --- sandbox"; sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get nodes 2>&1 | sed 's/^/    /'

echo
echo "### [10] preserved interfaces and helper anchors"
ip -br link show clab-ext 2>&1 | sed 's/^/  /'
ip -br link show p003-ext 2>&1 | sed 's/^/  /'
echo "  helper anchors (leave running — they keep the bridges alive for libnetwork):"
sudo docker ps --filter "name=p003-netfix-" --format '    {{.Names}} {{.Status}} {{.Networks}}'

echo
echo "### RESULT: verification failures = $FAILURES"
[ "$FAILURES" -eq 0 ] && echo "RECOVERY OK" || echo "RECOVERY INCOMPLETE — inspect the MISMATCH lines above"
exit 0
