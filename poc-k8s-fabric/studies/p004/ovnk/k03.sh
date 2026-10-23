#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p004/ovnk/k03.sh — Caso K03: ClusterUserDefinedNetwork (transport: EVPN) + VTEP + RouteAdvertisements + peer FRR externo (R8).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN="${DRY_RUN:-${LABCTL_DRY_RUN:-0}}"
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

OVNK_KUBECONFIG="${OVNK_KUBECONFIG:-/root/.kube/ovnk.config}"
OVNK_CONTEXT="${OVNK_CONTEXT:-kind-ovnk}"
OVNK_PEER_CONTAINER="${OVNK_PEER_CONTAINER:-ovnk-evpn-peer}"

k03_kctl() {
  if [[ -f "${OVNK_KUBECONFIG}" ]]; then
    kubectl --kubeconfig "${OVNK_KUBECONFIG}" --context "${OVNK_CONTEXT}" "$@"
  else
    kubectl --context "${OVNK_CONTEXT}" "$@"
  fi
}

if [[ "${DRY_RUN}" == "1" ]]; then
  printf 'DRY: k03_kctl apply -f %s/k03-evpn-cudn.yaml\n' "${SCRIPT_DIR}"
  printf 'DRY: k03_kctl -n frr-k8s-system apply FRRConfiguration frr-evpn-peer\n'
  printf 'DRY: docker exec %s vtysh -c "show bgp summary json"\n' "${OVNK_PEER_CONTAINER}"
  printf 'DRY: docker exec %s vtysh -c "show bgp l2vpn evpn route detail json"\n' "${OVNK_PEER_CONTAINER}"
  printf 'DRY: k03_kctl -n tenant-evpn exec pod-evpn -- ping -c 5 -W 2 10.253.0.1\n'
  printf 'K03 DRY-RUN OK\n'
  exit 0
fi

# 1. Descobrir sub-rede IPv4 da bridge kind e IPs dos nós e do peer externo
peer_ip="$(docker inspect -f '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' "${OVNK_PEER_CONTAINER}")"
kind_cidr="$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' | grep -v ':' | head -n1)"
kind_cidr="${kind_cidr:-172.18.0.0/16}"
cp_ip="$(docker inspect -f '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' ovnk-control-plane)"
w1_ip="$(docker inspect -f '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' ovnk-worker)"
w2_ip="$(docker inspect -f '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' ovnk-worker2)"

# 2. Aplicar VTEP (com CIDR real da rede kind), ClusterUserDefinedNetwork (transport: EVPN) e RouteAdvertisements
sed "s|172.18.0.0/16|${kind_cidr}|g" "${SCRIPT_DIR}/k03-evpn-cudn.yaml" | k03_kctl apply -f -

# 3. Aplicar FRRConfiguration em frr-k8s-system apontando para ovnk-evpn-peer (ASN 65000 com disableMP: true conforme upstream test/e2e/evpn.go)
k03_kctl -n frr-k8s-system apply -f - <<EOF
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: frr-evpn-peer
  namespace: frr-k8s-system
  labels:
    evpn-fabric: "true"
spec:
  bgp:
    routers:
      - asn: 65000
        neighbors:
          - address: ${peer_ip}
            asn: 65000
            disableMP: true
EOF

# 4. Configurar ovnk-evpn-peer (AS 65000 RR, SVD bridge brevpn + vxevpn, L2 MAC-VRF VNI 20100 RT 65000:20100, L3 IP-VRF vrf-evpn-k03 VNI 10100 RT 65000:10100, endpoint 10.253.0.1/24)
docker exec "${OVNK_PEER_CONTAINER}" bash -c "
  set -euo pipefail
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null

  for dev in brevpn.100 brevpn.200 vxevpn brevpn dummy-k03 vxlan-10100 vxlan-20100 br-vxlan-10100 br-vxlan-20100 vrf-evpn-k03; do
    ip link del \"\${dev}\" 2>/dev/null || true
  done

  ip link add brevpn type bridge vlan_filtering 1 vlan_default_pvid 0
  ip link set brevpn addrgenmode none up

  ip link add vxevpn type vxlan dstport 4789 local ${peer_ip} nolearning external vnifilter
  ip link set vxevpn addrgenmode none master brevpn up
  bridge link set dev vxevpn vlan_tunnel on neigh_suppress on learning off

  # MAC-VRF (VNI 20100 <-> VID 200)
  bridge vlan add dev brevpn vid 200 self
  bridge vlan add dev vxevpn vid 200
  bridge vni add dev vxevpn vni 20100
  bridge vlan add dev vxevpn vid 200 tunnel_info id 20100
  ip link add brevpn.200 link brevpn type vlan id 200
  ip link set brevpn.200 addrgenmode none up

  # IP-VRF (vrf-evpn-k03 table 10100, VNI 10100 <-> VID 100)
  ip link add vrf-evpn-k03 type vrf table 10100
  ip link set vrf-evpn-k03 up
  bridge vlan add dev brevpn vid 100 self
  bridge vlan add dev vxevpn vid 100
  bridge vni add dev vxevpn vni 10100
  bridge vlan add dev vxevpn vid 100 tunnel_info id 10100
  ip link add brevpn.100 link brevpn type vlan id 100
  ip link set brevpn.100 addrgenmode none master vrf-evpn-k03 up

  # Endpoint norte-sul 10.253.0.1/24 na VRF vrf-evpn-k03
  ip link add dummy-k03 type dummy
  ip link set dummy-k03 master vrf-evpn-k03 up
  ip addr replace 10.253.0.1/24 dev dummy-k03

  cat >/etc/frr/frr.conf <<'FRR'
frr defaults traditional
hostname ovnk-evpn-peer
service integrated-vtysh-config
!
vrf vrf-evpn-k03
 vni 10100
exit-vrf
!
router bgp 65000
 bgp router-id ${peer_ip}
 no bgp ebgp-requires-policy
 no bgp default ipv4-unicast
 neighbor ${cp_ip} remote-as 65000
 neighbor ${w1_ip} remote-as 65000
 neighbor ${w2_ip} remote-as 65000
 !
 address-family ipv4 unicast
  neighbor ${cp_ip} activate
  neighbor ${cp_ip} route-reflector-client
  neighbor ${w1_ip} activate
  neighbor ${w1_ip} route-reflector-client
  neighbor ${w2_ip} activate
  neighbor ${w2_ip} route-reflector-client
 exit-address-family
 !
 address-family l2vpn evpn
  neighbor ${cp_ip} activate
  neighbor ${cp_ip} route-reflector-client
  neighbor ${w1_ip} activate
  neighbor ${w1_ip} route-reflector-client
  neighbor ${w2_ip} activate
  neighbor ${w2_ip} route-reflector-client
  advertise-all-vni
  vni 20100
   rd 65000:20100
   route-target import 65000:20100
   route-target export 65000:20100
  exit-vni
 exit-address-family
exit
!
router bgp 65000 vrf vrf-evpn-k03
 bgp router-id ${peer_ip}
 no bgp ebgp-requires-policy
 !
 address-family ipv4 unicast
  network 10.253.0.0/24
 exit-address-family
 !
 address-family l2vpn evpn
  rd 65000:10100
  route-target import 65000:10100
  route-target export 65000:10100
  advertise ipv4 unicast
 exit-address-family
exit
!
line vty
!
FRR
  mkdir -p /var/run/frr /run/frr
  chown -R frr:frr /etc/frr /var/run/frr /run/frr 2>/dev/null || true
  for d in bgpd zebra bfdd staticd mgmtd; do
    pkill -x \"\${d}\" || true
  done
  sleep 1
  for d in mgmtd zebra bgpd bfdd staticd; do
    if [ -x \"/usr/libexec/frr/\${d}\" ]; then
      \"/usr/libexec/frr/\${d}\" -d
    elif [ -x \"/usr/lib/frr/\${d}\" ]; then
      \"/usr/lib/frr/\${d}\" -d
    fi
  done
  for _ in \$(seq 1 30); do
    if vtysh -c 'show version' >/dev/null 2>&1 && vtysh -b >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
"

# 5. Criar pod workload na UDN EVPN (tenant-evpn)
k03_kctl -n tenant-evpn apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: pod-evpn
  namespace: tenant-evpn
spec:
  containers:
    - name: net
      image: ghcr.io/ovn-kubernetes/ovn-kubernetes/ovn-kube-ubuntu:release-1.4
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      securityContext:
        privileged: true
EOF
k03_kctl -n tenant-evpn wait pod pod-evpn --for=condition=Ready --timeout=180s
k03_kctl -n tenant-evpn exec -i pod-evpn -- bash -s <<'PYEOF'
if ! command -v ping >/dev/null 2>&1; then
  cat >/usr/local/bin/ping <<'PY'
#!/usr/bin/env python3
import os, select, socket, struct, sys, time
def csum(d):
    if len(d) % 2: d += b"\x00"
    s = sum(struct.unpack("!%dH" % (len(d) // 2), d))
    s = (s >> 16) + (s & 0xffff)
    return (~(s + (s >> 16))) & 0xffff
cnt, to, tgt, a, i = 4, 2.0, None, sys.argv[1:], 0
while i < len(a):
    if a[i] == "-c": cnt = int(a[i+1]); i += 2
    elif a[i] == "-W": to = float(a[i+1]); i += 2
    elif a[i].startswith("-"): i += 1
    else: tgt = a[i]; i += 1
dst, ident, rx = socket.gethostbyname(tgt), os.getpid() & 0xffff, 0
for seq in range(1, cnt + 1):
    with socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP) as s:
        pl = struct.pack("!d", time.time()) + b"OVNK-PING-PROBE"
        pkt = struct.pack("!BBHHH", 8, 0, csum(struct.pack("!BBHHH", 8, 0, 0, ident, seq) + pl), ident, seq) + pl
        t0 = time.monotonic(); s.sendto(pkt, (dst, 0)); dl = t0 + to
        while time.monotonic() < dl:
            r, _, _ = select.select([s], [], [], max(0.0, dl - time.monotonic()))
            if not r: break
            b, ad = s.recvfrom(1024)
            if ad[0] == dst and len(b) >= 28:
                ihl = (b[0] & 0x0f) * 4
                t, c, _, rid, rseq = struct.unpack("!BBHHH", b[ihl:ihl+8])
                if t == 0 and c == 0 and rid == ident and rseq == seq:
                    rx += 1; break
        if seq < cnt: time.sleep(0.2)
sys.exit(0 if rx == cnt else 1)
PY
  chmod +x /usr/local/bin/ping
fi
PYEOF

# 6. Verificar Critério 1: RouteAdvertisements Accepted=True
ra_ok=0
for _ in $(seq 1 30); do
  ra_status="$(k03_kctl get routeadvertisements ra-evpn -o json 2>/dev/null | jq -r '.status.conditions[]? | select(.type=="Accepted") | .status' || true)"
  if [[ "${ra_status}" == "True" ]]; then
    ra_ok=1
    break
  fi
  sleep 2
done
if [[ "${ra_ok}" -ne 1 ]]; then
  printf '[k03] ERRO: RouteAdvertisements ra-evpn não atingiu Accepted=True\n' >&2
  exit 1
fi

# 7. Verificar Critérios 2 e 3: BGP Established com os 3 nós + rotas EVPN Type-2 (VNI 20100) e Type-5 (10.0.0.0/24, VNI 10100) via JSON estruturado (R8)
bgp_evpn_ok=0
for _ in $(seq 1 35); do
  if docker exec "${OVNK_PEER_CONTAINER}" python3 -c "
import json, subprocess, sys

expected_peers = {'${cp_ip}', '${w1_ip}', '${w2_ip}'}
s = json.loads(subprocess.check_output(['vtysh', '-c', 'show bgp summary json'], text=True))
peers = {}
for af in s.values():
    if isinstance(af, dict) and 'peers' in af:
        for p, d in af['peers'].items():
            if d.get('state') == 'Established':
                peers[p] = d
if not expected_peers.issubset(set(peers.keys())):
    sys.exit(1)

evpn = json.loads(subprocess.check_output(['vtysh', '-c', 'show bgp l2vpn evpn route detail json'], text=True))
has_type2 = False
has_type5 = False
for rd_key, rd_val in evpn.items():
    if not isinstance(rd_val, dict):
        continue
    for pfx_key, pfx_val in rd_val.items():
        if not isinstance(pfx_val, dict):
            continue
        paths = pfx_val.get('paths', [])
        if str(pfx_key).startswith('[2]:'):
            for path_entry in paths:
                for p in (path_entry if isinstance(path_entry, list) else [path_entry]):
                    if isinstance(p, dict):
                        ext = (p.get('extendedCommunity') or {}).get('string', '')
                        if '65000:20100' in ext or p.get('vni') == 20100 or '20100' in str(rd_key):
                            has_type2 = True
        if str(pfx_key).startswith('[5]:') and pfx_val.get('ip') == '10.0.0.0' and int(pfx_val.get('ipLen', pfx_val.get('prefixLen', 0))) == 24:
            for path_entry in paths:
                for p in (path_entry if isinstance(path_entry, list) else [path_entry]):
                    if isinstance(p, dict):
                        ext = (p.get('extendedCommunity') or {}).get('string', '')
                        if '65000:10100' in ext or p.get('vni') == 10100 or '10100' in str(rd_key):
                            has_type5 = True
if not (has_type2 and has_type5):
    sys.exit(2)
" 2>/dev/null; then
    bgp_evpn_ok=1
    break
  fi
  sleep 2
done
if [[ "${bgp_evpn_ok}" -ne 1 ]]; then
  printf '[k03] ERRO: BGP não Established com os 3 nós (%s, %s, %s) ou rotas EVPN Type-2 (VNI 20100) / Type-5 (10.0.0.0/24, VNI 10100) ausentes em %s\n' \
    "${cp_ip}" "${w1_ip}" "${w2_ip}" "${OVNK_PEER_CONTAINER}" >&2
  exit 1
fi

# 8. Verificar Critério 4: Conectividade norte-sul entre pod-evpn (10.0.0.0/24) e loopback 10.253.0.1 em ovnk-evpn-peer
if ! k03_kctl -n tenant-evpn exec pod-evpn -- ping -c 5 -W 2 10.253.0.1 >/dev/null; then
  printf '[k03] ERRO: ping norte-sul (pod-evpn -> 10.253.0.1 em %s) falhou\n' "${OVNK_PEER_CONTAINER}" >&2
  exit 1
fi

printf 'K03 PASS: RouteAdvertisements Accepted=True, BGP Established com 3 nós (%s, %s, %s), rotas EVPN Type-2 (VNI 20100) e Type-5 (10.0.0.0/24, VNI 10100) presentes em %s e ping norte-sul 5/5 OK.\n' \
  "${cp_ip}" "${w1_ip}" "${w2_ip}" "${OVNK_PEER_CONTAINER}"
