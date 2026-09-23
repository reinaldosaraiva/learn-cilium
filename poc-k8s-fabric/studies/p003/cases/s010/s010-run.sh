#!/usr/bin/env bash
# S010 — IPAM Multi-Pool /24 x /32 measurement driver (runs on vm-cilium).
# Single observation clock: host epoch seconds (date +%s). Polling: 1s.
# Evidence: $EV (set by caller) with events.csv, allocation.csv, rib.log, probes.tsv
set -uo pipefail

KC=/root/.kube/p003-gw.config
CTX=kind-p003-gw
UID_EXPECT=8216d179-9eed-4dc1-ab9c-97c0c6612b32
BORDER=clab-p003-gw-fabric-border1
CLIENT=clab-p003-gw-fabric-client
CHART=/opt/poc-k8s-fabric-studies/studies/p003/base/cilium-1.20.2.tgz
EV=${EV:?EV required}
ARM=${ARM:?ARM required}   # M24 | M32 | I10
NS=${NS:-p003-ipam}
POOL=${POOL:-p003-m24}
DEPLOY=${DEPLOY:-p003-ipam-pods}
POLL=1
WIN=120

K() { sudo kubectl --kubeconfig "$KC" --context "$CTX" "$@"; }
now() { date +%s; }
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

uid_check() {
  local u; u=$(K get namespace kube-system -o jsonpath='{.metadata.uid}')
  if [ "$u" != "$UID_EXPECT" ]; then echo "UID MISMATCH: $u" >&2; exit 17; fi
}

event() { # case rep type subject detail
  echo -e "$ARM\t$1\t$2\t$3\t$4\t$(now)\t$(ts)\t$5\t${6:-}" >> "$EV/events.csv"
}

# --- allocation snapshot: node|pool|cidr|state --------------------------------
snap_alloc() { # $1 = tag
  K get ciliumnode -o json 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for n in d.get("items",[]):
    name=n["metadata"]["name"]
    ipam=n.get("spec",{}).get("ipam",{})
    pools=ipam.get("pools",{}) or {}
    for a in pools.get("allocated",[]) or []:
        print(name+"|"+str(a.get("pool"))+"|"+",".join(a.get("cidrs") or [])+"|allocated")
    for r in pools.get("requested",[]) or []:
        print(name+"|"+str(r.get("pool"))+"|requested|needed="+str(r.get("needed")))
' | while IFS= read -r line; do
    echo -e "$(now)\t$1\t$line" >> "$EV/allocation.csv"
  done
}
alloc_now() { # current allocation as lines node|pool|cidr|state
  K get ciliumnode -o json 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for n in d.get("items",[]):
    name=n["metadata"]["name"]
    ipam=n.get("spec",{}).get("ipam",{})
    pools=ipam.get("pools",{}) or {}
    for a in pools.get("allocated",[]) or []:
        print(name+"|"+str(a.get("pool"))+"|"+",".join(a.get("cidrs") or [])+"|allocated")
'
}

# --- BGP RIB snapshots ---------------------------------------------------------
rib_snap() { # $1 = tag
  {
    echo "=== $(now) $(ts) $1 ==="
    sudo docker exec "$BORDER" vtysh -c "show ip bgp" 2>/dev/null | grep -E "^\*|^\>" | grep -E "10\.25[012]|10\.245|10\.202" || echo "(no study prefixes)"
  } >> "$EV/rib.log"
}
rib_has() { # $1 = prefix (exact match on prefix field)
  sudo docker exec "$BORDER" vtysh -c "show ip bgp" 2>/dev/null | grep -E "^\*|^\>" | awk '{print $2}' | grep -qx "$1"
}

# --- cilium-side BGP routes for a node -----------------------------------------
cilium_pod_on() { # $1 = node name
  K get pods -n kube-system -l k8s-app=cilium -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for p in d['items']:
    if p['spec'].get('nodeName')=='$1' and 'envoy' not in p['metadata']['name']:
        print(p['metadata']['name']); break
"
}
bgp_routes_node() { # $1 = node name
  local pod; pod=$(cilium_pod_on "$1") || return 1
  [ -n "$pod" ] || return 1
  K exec -n kube-system "$pod" -- cilium-dbg bgp routes 2>/dev/null | grep -E "10\.25[012]|10\.245" | awk '{print $2}'
}

# --- pod helpers ---------------------------------------------------------------
pod_info() { # $1 = ns $2 = name -> "uid node ip ready"
  K get pod -n "$1" "$2" -o json 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
md=d.get("metadata",{}); st=d.get("status",{})
ready="false"
for c in st.get("conditions",[]) or []:
    if c.get("type")=="Ready": ready=c.get("status")
print(str(md.get("uid"))+"\t"+str(md.get("name"))+"\t"+str(d.get("spec",{}).get("nodeName"))+"\t"+str(st.get("podIP"))+"\t"+str(ready)+"\t"+str(st.get("phase")))
'
}

# --- probe from fabric client --------------------------------------------------
probe() { # $1 = dest url $2 = tag
  local code rc
  code=$(sudo docker exec "$CLIENT" curl --noproxy '*' --retry 0 --connect-timeout 3 --max-time 10 \
    -s -o /dev/null -w '%{http_code}' "$1" 2>/dev/null)
  rc=$?
  echo -e "$(now)\t$ARM\t$2\t$1\t${code:-000}\t$rc" >> "$EV/probes.tsv"
  [ "$code" = "200" ]
}

# --- CIDR containment helper (python3; mawk lacks <<) --------------------------
# $1 = ip -> "node|pool|cidr|allocated" for the allocated block containing ip.
# cidr field may be a comma-joined list (multi-pool /32); the specific matching
# CIDR is returned so callers can use it as the exact BGP prefix.
block_of_ip() {
  alloc_now | python3 -c '
import sys
def ip2i(x):
    a = x.split("."); return (int(a[0])<<24)|(int(a[1])<<16)|(int(a[2])<<8)|int(a[3])
def in_cidr(cidr, addr):
    try:
        c, p = cidr.split("/"); p = int(p)
    except Exception:
        return False
    m = (1 << (32 - p)) - 1
    return (ip2i(c) & ~m) == (ip2i(addr) & ~m)
for line in sys.stdin:
    parts = line.strip().split("|")
    if len(parts) != 4 or parts[3] != "allocated":
        continue
    for cidr in parts[2].split(","):
        cidr = cidr.strip()
        if cidr and in_cidr(cidr, sys.argv[1]):
            print(parts[0]+"|"+parts[1]+"|"+cidr+"|"+parts[3]); sys.exit(0)
' "$1" 2>/dev/null
}

# --- allocation event measurement (t0..t5) -------------------------------------
# $1=case $2=rep $3=podname  (pod already created by caller at t0)
measure_alloc() {
  local case_id=$1 rep=$2 pod=$3
  local t0 t1="" t2="" t3="" t4="" t5="" ip="" node="" prefix="" blk=""
  t0=$(now)
  event "$case_id" "$rep" "t0-create" "$pod" "requested"
  for i in $(seq 1 120); do
    sleep "$POLL"
    local info; info=$(pod_info "$NS" "$pod")
    if [ -z "$info" ]; then continue; fi
    IFS=$'\t' read -r _ _ node ip ready phase <<<"$info"
    if [ -z "$t1" ] && [ -n "${ip:-}" ]; then
      t1=$(now)
      event "$case_id" "$rep" "t1-ip" "$pod" "node=$node ip=$ip"
      snap_alloc "t1-$pod"
    fi
    if [ -n "$t1" ] && [ -z "$t2" ]; then
      blk=$(block_of_ip "$ip")
      if [ -n "$blk" ]; then
        t2=$(now); prefix=$(echo "$blk" | cut -d'|' -f3)
        event "$case_id" "$rep" "t2-block" "$pod" "$blk"
        snap_alloc "t2-$pod"
      fi
    fi
    if [ -n "$t2" ] && [ -z "$t3" ] && [ -n "${node:-}" ]; then
      if bgp_routes_node "$node" | grep -qx "$prefix"; then
        t3=$(now); event "$case_id" "$rep" "t3-cilium-route" "$pod" "node=$node prefix=$prefix"
      fi
    fi
    if [ -n "$t2" ] && [ -z "$t4" ]; then
      if rib_has "$prefix"; then
        t4=$(now); event "$case_id" "$rep" "t4-border-rib" "$pod" "prefix=$prefix at $BORDER"
        rib_snap "t4-$pod"
      fi
    fi
    if [ -n "$t1" ] && [ -z "$t5" ]; then
      if probe "http://$ip:8080/" "alloc-$case_id-r$rep-$pod"; then
        t5=$(now); event "$case_id" "$rep" "t5-first-probe" "$pod" "200 from fabric client"
      fi
    fi
    [ -n "$t5" ] && [ -n "$t4" ] && break
  done
  event "$case_id" "$rep" "alloc-summary" "$pod" "t0=$t0 t1=${t1:-NA} t2=${t2:-NA} t3=${t3:-NA} t4=${t4:-NA} t5=${t5:-NA} ip=${ip:-NA} node=${node:-NA} prefix=${prefix:-NA}"
}

# --- withdrawal measurement (t6..t8, 120s window) ------------------------------
# $1=case $2=rep $3=podname $4=ip (pre-deletion ip)
measure_withdraw() {
  local case_id=$1 rep=$2 pod=$3 ip=$4
  local t6 t7="" t8c="" t8b=""
  t6=$(now)
  event "$case_id" "$rep" "t6-delete" "$pod" "ip=$ip requested"
  K delete pod -n "$NS" "$pod" --grace-period=0 --force >/dev/null 2>&1 || true
  local blk; blk=$(block_of_ip "$ip")
  local prefix; prefix=$(echo "$blk" | cut -d'|' -f3)
  snap_alloc "t6-$pod"
  for i in $(seq 1 "$WIN"); do
    sleep "$POLL"
    if [ -z "$t7" ] && [ -n "$prefix" ]; then
      if ! alloc_now | awk -F'|' '{print $3}' | tr ',' '\n' | grep -qx "$prefix"; then
        t7=$(now); event "$case_id" "$rep" "t7-block-released" "$pod" "prefix=$prefix gone from CiliumNode.allocated"
        snap_alloc "t7-$pod"
      fi
    fi
    if [ -z "$t8c" ] && [ -n "$prefix" ]; then
      local node; node=$(echo "$blk" | cut -d'|' -f1)
      if [ -n "$node" ] && ! bgp_routes_node "$node" | grep -qx "$prefix"; then
        t8c=$(now); event "$case_id" "$rep" "t8-cilium-route-gone" "$pod" "prefix=$prefix node=$node"
      fi
    fi
    if [ -z "$t8b" ] && [ -n "$prefix" ]; then
      if ! rib_has "$prefix"; then
        t8b=$(now); event "$case_id" "$rep" "t8-border-route-gone" "$pod" "prefix=$prefix"
        rib_snap "t8-$pod"
      fi
    fi
    [ -n "$t7" ] && [ -n "$t8c" ] && [ -n "$t8b" ] && break
  done
  [ -z "$t7" ] && event "$case_id" "$rep" "t7-held" "$pod" "prefix=$prefix held >= ${WIN}s (still allocated)"
  [ -z "$t8c" ] && event "$case_id" "$rep" "t8c-held" "$pod" "cilium route held >= ${WIN}s"
  [ -z "$t8b" ] && event "$case_id" "$rep" "t8b-held" "$pod" "border route held >= ${WIN}s"
  snap_alloc "t8end-$pod"
  rib_snap "t8end-$pod"
  event "$case_id" "$rep" "withdraw-summary" "$pod" "t6=$t6 t7=${t7:-HELD} t8c=${t8c:-HELD} t8b=${t8b:-HELD} prefix=$prefix"
}

# --- I01 baseline ---------------------------------------------------------------
baseline() {
  local tag=$1
  {
    echo "=== I01 baseline $ARM $tag $(ts) ==="
    echo "--- pools ---"; K get ciliumpodippool -o custom-columns='NAME:.metadata.name,MASK:.spec.ipv4.maskSize,CIDRS:.spec.ipv4.cidrs' 2>/dev/null
    echo "--- allocation (node|pool|cidr) ---"; alloc_now
    echo "--- requested ---"; K get ciliumnode -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
for n in d.get("items",[]):
    pools=n.get("spec",{}).get("ipam",{}).get("pools",{}) or {}
    for r in pools.get("requested",[]) or []:
        print(n["metadata"]["name"]+"|"+str(r.get("pool"))+"|requested|needed="+str(r.get("needed")))
'
    echo "--- border1 RIB (study prefixes) ---"
    sudo docker exec "$BORDER" vtysh -c "show ip bgp" 2>/dev/null | grep -E "^\*|^\>" | grep -E "10\.25[012]|10\.245|10\.202" || echo "(none)"
    echo "--- pods in $NS ---"; K get pods -n "$NS" -o wide 2>/dev/null
    echo "--- gateway ---"; K get gateway -n p003-gateway p003-main -o jsonpath='{.status.conditions}' 2>/dev/null | head -c 400; echo
  } > "$EV/i01-$tag.txt" 2>&1
  rib_snap "i01-$tag"
  snap_alloc "i01-$tag"
}

# --- setup ----------------------------------------------------------------------
setup_m24() {
  local vals=$1
  uid_check
  K apply -f /opt/poc-k8s-fabric-studies/studies/p003/s010/01-m24-setup.yaml
  K apply -f /opt/poc-k8s-fabric-studies/studies/p003/s010/02-bgp-advertisement.yaml
  sudo helm upgrade cilium "$CHART" -n kube-system -f "$vals" > "$EV/helm-upgrade-m24.log" 2>&1
  K rollout status deploy/cilium-operator -n kube-system --timeout=300s >> "$EV/helm-upgrade-m24.log" 2>&1
  K rollout status ds/cilium -n kube-system --timeout=300s >> "$EV/helm-upgrade-m24.log" 2>&1
  # remove podCIDR from nodes (multi-pool: single source of allocation)
  for n in $(K get nodes -o jsonpath='{.items[*].metadata.name}'); do
    K patch node "$n" --type=json -p '[{"op":"remove","path":"/spec/podCIDR"},{"op":"remove","path":"/spec/podCIDRs"}]' 2>>"$EV/helm-upgrade-m24.log" || \
    K patch node "$n" --type=merge -p '{"spec":{"podCIDR":null,"podCIDRs":null}}' 2>>"$EV/helm-upgrade-m24.log"
  done
  sleep 20
  # verify
  {
    echo "=== post-setup verification $(ts) ==="
    echo "--- helm ---"; sudo helm list -n kube-system | grep cilium
    echo "--- cm key ---"; K get cm -n kube-system cilium-config -o jsonpath='{.data.ipam-multi-pool-pre-allocation}'; echo
    echo "--- ipam mode ---"; K get cm -n kube-system cilium-config -o jsonpath='{.data.ipam}'; echo
    echo "--- node podCIDR ---"; K get nodes -o json | python3 -c 'import json,sys; [print(n["metadata"]["name"], n["spec"].get("podCIDR","<none>")) for n in json.load(sys.stdin)["items"]]'
    echo "--- pools ---"; K get ciliumpodippool -o custom-columns='NAME:.metadata.name,MASK:.spec.ipv4.maskSize,CIDRS:.spec.ipv4.cidrs'
    echo "--- pools status ---"; K get ciliumpodippool -o json | python3 -c '
import json,sys
d=json.load(sys.stdin)
for p in d["items"]:
    conds=p.get("status",{}).get("conditions",[]) or []
    print(p["metadata"]["name"], [(c.get("type"),c.get("status"),c.get("message","")[:80]) for c in conds])
'
    echo "--- allocation ---"; alloc_now
    echo "--- pods (all ns, study-relevant) ---"; K get pods -A -o wide | grep -v -E "kube-|etcd|Completed" | head -20
    echo "--- gateway ---"; K get gateway -n p003-gateway p003-main -o wide
    echo "--- border1 RIB ---"; sudo docker exec "$BORDER" vtysh -c "show ip bgp" | grep -E "^\*|^\>" | grep -E "10\.25[012]|10\.245|10\.202" || echo "(none)"
    echo "--- agent status (per node) ---"
    for n in $(K get nodes -o jsonpath='{.items[*].metadata.name}'); do
      pod=$(cilium_pod_on "$n"); [ -n "$pod" ] && K exec -n kube-system "$pod" -- cilium-dbg status 2>/dev/null | head -3 | sed "s/^/$n: /"
    done
  } > "$EV/post-setup-m24.txt" 2>&1
}

setup_m32() {
  local vals=$1
  uid_check
  K apply -f /opt/poc-k8s-fabric-studies/studies/p003/s010/06-m32-setup.yaml
  sudo helm upgrade cilium "$CHART" -n kube-system -f "$vals" > "$EV/helm-upgrade-m32.log" 2>&1
  K rollout status deploy/cilium-operator -n kube-system --timeout=300s >> "$EV/helm-upgrade-m32.log" 2>&1
  K rollout status ds/cilium -n kube-system --timeout=300s >> "$EV/helm-upgrade-m32.log" 2>&1
  sleep 20
  {
    echo "=== post-setup M32 verification $(ts) ==="
    echo "--- helm ---"; sudo helm list -n kube-system | grep cilium
    echo "--- cm key ---"; K get cm -n kube-system cilium-config -o jsonpath='{.data.ipam-multi-pool-pre-allocation}'; echo
    echo "--- pools ---"; K get ciliumpodippool -o custom-columns='NAME:.metadata.name,MASK:.spec.ipv4.maskSize,CIDRS:.spec.ipv4.cidrs'
    echo "--- allocation ---"; alloc_now
    echo "--- border1 RIB ---"; sudo docker exec "$BORDER" vtysh -c "show ip bgp" | grep -E "^\*|^\>" | grep -E "10\.25[012]|10\.245|10\.202" || echo "(none)"
  } > "$EV/post-setup-m32.txt" 2>&1
}

rollback() {
  local vals=$1
  uid_check
  # remove experimental workloads/namespaces/pools (no active test pods expected)
  K delete deploy -n "$NS" "$DEPLOY" --ignore-not-found >/dev/null 2>&1
  K delete pod -n "$NS" -l study=P003 --grace-period=0 --force --ignore-not-found >/dev/null 2>&1
  K delete ns p003-ipam p003-ipam32 --ignore-not-found --timeout=60s >> "$EV/rollback.log" 2>&1
  K delete ciliumpodippool p003-m24 p003-m32 --ignore-not-found >> "$EV/rollback.log" 2>&1
  sudo helm upgrade cilium "$CHART" -n kube-system -f "$vals" > "$EV/helm-rollback.log" 2>&1
  K rollout status deploy/cilium-operator -n kube-system --timeout=300s >> "$EV/helm-rollback.log" 2>&1
  K rollout status ds/cilium -n kube-system --timeout=300s >> "$EV/helm-rollback.log" 2>&1
  # restore node podCIDRs (K24 reference)
  K patch node p003-gw-control-plane --type=merge -p '{"spec":{"podCIDR":"10.245.0.0/24"}}' >> "$EV/rollback.log" 2>&1
  K patch node p003-gw-worker --type=merge -p '{"spec":{"podCIDR":"10.245.2.0/24"}}' >> "$EV/rollback.log" 2>&1
  K patch node p003-gw-worker2 --type=merge -p '{"spec":{"podCIDR":"10.245.1.0/24"}}' >> "$EV/rollback.log" 2>&1
  sleep 30
  {
    echo "=== post-rollback verification $(ts) ==="
    echo "--- helm ---"; sudo helm list -n kube-system | grep cilium
    echo "--- ipam ---"; K get cm -n kube-system cilium-config -o jsonpath='{.data.ipam}'; echo
    echo "--- cm prealloc key (should be gone) ---"; K get cm -n kube-system cilium-config -o jsonpath='{.data.ipam-multi-pool-pre-allocation}'; echo " <empty=ok>"
    echo "--- node podCIDR ---"; K get nodes -o json | python3 -c 'import json,sys; [print(n["metadata"]["name"], n["spec"].get("podCIDR","<none>")) for n in json.load(sys.stdin)["items"]]'
    echo "--- pools ---"; K get ciliumpodippool 2>&1
    echo "--- pods ---"; K get pods -A -o wide | grep -v -E "kube-|etcd|Completed" | head -20
    echo "--- gateway ---"; K get gateway -n p003-gateway p003-main -o wide
    echo "--- border1 RIB ---"; sudo docker exec "$BORDER" vtysh -c "show ip bgp" | grep -E "^\*|^\>" | grep -E "10\.25[012]|10\.245|10\.202" || echo "(none)"
    echo "--- k01 uid ---"; sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get namespace kube-system -o jsonpath='{.metadata.uid}'; echo
  } > "$EV/post-rollback.txt" 2>&1
}

# --- dispatch -------------------------------------------------------------------
case "${1:-}" in
  uid) uid_check; echo "UID OK" ;;
  alloc) shift; measure_alloc "$@" ;;
  withdraw) shift; measure_withdraw "$@" ;;
  baseline) shift; baseline "$@" ;;
  setup-m24) shift; setup_m24 "$@" ;;
  setup-m32) shift; setup_m32 "$@" ;;
  rollback) shift; rollback "$@" ;;
  alloc-snap) snap_alloc "${2:-manual}" ;;
  rib-snap) rib_snap "${2:-manual}" ;;
  alloc-now) alloc_now ;;
  pod-info) pod_info "$2" "$3" ;;
  probe) if probe "$2" "$3"; then echo PROBE_OK; exit 0; else echo PROBE_FAIL; exit 1; fi ;;
  bgp-routes) bgp_routes_node "$2" ;;
  *) echo "usage: $0 {uid|alloc|withdraw|baseline|setup-m24|setup-m32|rollback|alloc-snap|rib-snap|alloc-now|pod-info|probe|bgp-routes} ..." >&2; exit 2 ;;
esac
