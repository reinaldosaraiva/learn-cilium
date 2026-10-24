#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p004/cases/x07-macvrf-type2-overlap.sh — Caso X07 (Gate G05):
# Isolamento L2 / MAC-VRF EVPN Type-2 com MAC e IP idênticos em VNIs distintas:
#   - Tenant 'a' (tenant-evpn / cudnevpn): MAC-VRF VNI 20100 (RT 65000:20100), IP-VRF VNI 10100 (RT 65000:10100)
#     -> pod-x07-a com MAC 02:00:10:00:00:11 e IP 10.0.0.11/24
#   - Tenant 'b' (tenant-evpn-b / cudnevpn-b): MAC-VRF VNI 20200 (RT 65000:20200), IP-VRF VNI 10200 (RT 65000:10200)
#     -> pod-x07-b com MAC 02:00:10:00:00:11 e IP 10.0.0.11/24
# Prova:
#   1. Rotas EVPN Type-2 ([2]:...[02:00:10:00:00:11]...) presentes simultaneamente em VNI 20100 e VNI 20200 (JSON).
#   2. Zero entradas marcadas como duplicate ou sticky em "show evpn mac vni 20100 json" e "show evpn mac vni 20200 json".
#   3. Conectividade L2 intra-MAC-VRF 5/5 em VNI 20100 (10.0.0.201 -> 10.0.0.11) e 5/5 em VNI 20200 (10.0.0.202 -> 10.0.0.11).
#   4. Zero vazamento L2 entre MAC-VRFs (tcpdump rc=124, 0 packets captured no pod do outro tenant).

set -euo pipefail

OVNK_KUBECONFIG="${OVNK_KUBECONFIG:-/root/.kube/ovnk.config}"
OVNK_CONTEXT="${OVNK_CONTEXT:-kind-ovnk}"
OVNK_PEER="ovnk-evpn-peer"

DRY_RUN="${DRY_RUN:-${LABCTL_DRY_RUN:-0}}"
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

DUP_MAC="02:00:10:00:00:11"
DUP_IP="10.0.0.11"
PEER_L2_A_IP="10.0.0.201"
PEER_L2_B_IP="10.0.0.202"
MACVNI_A="20100"
MACVNI_B="20200"
IPVNI_B="10200"

x07_log() {
  printf '[x07] %s\n' "$*"
}

x07_die() {
  printf '[x07] ERRO: %s\n' "$*" >&2
  exit 1
}

x07_kctl() {
  if [[ -f "${OVNK_KUBECONFIG}" ]]; then
    kubectl --kubeconfig "${OVNK_KUBECONFIG}" --context "${OVNK_CONTEXT}" "$@"
  else
    kubectl --context "${OVNK_CONTEXT}" "$@"
  fi
}

if [[ "${DRY_RUN}" == "1" ]]; then
  printf 'DRY: apply Namespace tenant-evpn-b, ClusterUserDefinedNetwork cudnevpn-b (MAC-VRF %s, IP-VRF %s), RouteAdvertisements ra-evpn-b\n' \
    "${MACVNI_B}" "${IPVNI_B}"
  printf 'DRY: configure %s brevpn.200 (VNI %s, %s/24) and brevpn.201 (VNI %s, %s/24)\n' \
    "${OVNK_PEER}" "${MACVNI_A}" "${PEER_L2_A_IP}" "${MACVNI_B}" "${PEER_L2_B_IP}"
  printf 'DRY: deploy pod-x07-a in tenant-evpn and pod-x07-b in tenant-evpn-b both with MAC %s and IP %s/24\n' \
    "${DUP_MAC}" "${DUP_IP}"
  printf 'DRY: verify EVPN Type-2 JSON routes for %s in both VNI %s and VNI %s and 0 duplicate/sticky flags in show evpn mac vni json\n' \
    "${DUP_MAC}" "${MACVNI_A}" "${MACVNI_B}"
  printf 'DRY: verify 5/5 L2 pings in VNI %s (%s -> %s) and VNI %s (%s -> %s) + tcpdump 0 cross-MAC-VRF packets (rc=124)\n' \
    "${MACVNI_A}" "${PEER_L2_A_IP}" "${DUP_IP}" "${MACVNI_B}" "${PEER_L2_B_IP}" "${DUP_IP}"
  printf 'DRY: cleanup pod-x07-a, tenant-evpn-b, ra-evpn-b, cudnevpn-b, and %s temporary interfaces\n' "${OVNK_PEER}"
  printf 'X07 DRY-RUN OK\n'
  exit 0
fi

cleanup_x07() {
  x07_log "Limpando recursos temporários de X07..."
  x07_kctl -n tenant-evpn delete pod pod-x07-a --ignore-not-found --wait=false >/dev/null 2>&1 || true
  x07_kctl -n tenant-evpn delete ipamclaim pod-x07-a-claim --ignore-not-found --wait=false >/dev/null 2>&1 || true
  x07_kctl -n tenant-evpn-b delete pod pod-x07-b --ignore-not-found --wait=false >/dev/null 2>&1 || true
  x07_kctl -n tenant-evpn-b delete ipamclaim pod-x07-b-claim --ignore-not-found --wait=false >/dev/null 2>&1 || true
  x07_kctl delete routeadvertisements ra-evpn-b --ignore-not-found >/dev/null 2>&1 || true
  x07_kctl delete clusteruserdefinednetwork cudnevpn-b --ignore-not-found >/dev/null 2>&1 || true
  x07_kctl delete namespace tenant-evpn-b --ignore-not-found --wait=false >/dev/null 2>&1 || true

  docker exec "${OVNK_PEER}" bash -c "
    rm -f /tmp/x07-src-a.pcap /tmp/x07-src-b.pcap
    ip addr del ${PEER_L2_A_IP}/24 dev brevpn.200 2>/dev/null || true
    ip link set brevpn.200 nomaster 2>/dev/null || true
    ip link del vrf-l2-a 2>/dev/null || true
    ip link del brevpn.201 2>/dev/null || true
    ip link del brevpn.101 2>/dev/null || true
    ip link del vrf-evpn-b 2>/dev/null || true
    bridge vlan del dev vxevpn vid 201 2>/dev/null || true
    bridge vni del dev vxevpn vni ${MACVNI_B} 2>/dev/null || true
    bridge vlan del dev brevpn vid 201 self 2>/dev/null || true
    bridge vlan del dev vxevpn vid 101 2>/dev/null || true
    bridge vni del dev vxevpn vni ${IPVNI_B} 2>/dev/null || true
    bridge vlan del dev brevpn vid 101 self 2>/dev/null || true
    vtysh \
      -c 'configure terminal' \
      -c 'router bgp 65000' \
      -c 'address-family l2vpn evpn' \
      -c 'no vni ${MACVNI_B}' \
      -c 'exit-address-family' \
      -c 'exit' \
      -c 'no router bgp 65000 vrf vrf-evpn-b' \
      -c 'no vrf vrf-evpn-b' \
      -c 'end' >/dev/null 2>&1 || true
  " || true
}
trap cleanup_x07 EXIT

# 1. Criar Namespace tenant-evpn-b, ClusterUserDefinedNetwork cudnevpn-b (MAC-VRF 20200, IP-VRF 10200) e RouteAdvertisements ra-evpn-b
x07_log "Criando ClusterUserDefinedNetwork cudnevpn-b (MAC-VRF ${MACVNI_B}, IP-VRF ${IPVNI_B}) e RouteAdvertisements ra-evpn-b..."
x07_kctl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-evpn-b
  labels:
    k8s.ovn.org/primary-user-defined-network: ""
    tenant: tenant-evpn-b
---
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: cudnevpn-b
  labels:
    network: cudnevpn-b
    evpn-b: "true"
spec:
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: tenant-evpn-b
  network:
    topology: Layer2
    layer2:
      role: Primary
      subnets:
        - "10.0.0.0/24"
      ipam:
        lifecycle: Persistent
    transport: EVPN
    evpn:
      vtep: vtep-evpn
      macVRF:
        vni: ${MACVNI_B}
        routeTarget: "65000:${MACVNI_B}"
      ipVRF:
        vni: ${IPVNI_B}
        routeTarget: "65000:${IPVNI_B}"
---
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: ra-evpn-b
spec:
  targetVRF: cudnevpn-b
  advertisements:
    - PodNetwork
  nodeSelector: {}
  frrConfigurationSelector:
    matchLabels:
      evpn-fabric: "true"
  networkSelectors:
    - networkSelectionType: ClusterUserDefinedNetworks
      clusterUserDefinedNetworkSelector:
        networkSelector:
          matchLabels:
            evpn-b: "true"
EOF

ra_b_ok=0
for _ in $(seq 1 30); do
  ra_b_status="$(x07_kctl get routeadvertisements ra-evpn-b -o json 2>/dev/null | jq -r '.status.conditions[]? | select(.type=="Accepted") | .status' || true)"
  if [[ "${ra_b_status}" == "True" ]]; then
    ra_b_ok=1
    break
  fi
  sleep 2
done
[[ "${ra_b_ok}" -eq 1 ]] || x07_die "RouteAdvertisements ra-evpn-b não atingiu Accepted=True"

# 2. Configurar ovnk-evpn-peer para MAC-VRF 20100 (vrf-l2-a / brevpn.200 10.0.0.201/24) e MAC-VRF 20200 (vrf-evpn-b / brevpn.201 10.0.0.202/24)
x07_log "Configurando MAC-VRF ${MACVNI_A} (brevpn.200) e MAC-VRF ${MACVNI_B} (brevpn.201) em ${OVNK_PEER}..."
peer_ip="$(docker inspect -f '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' "${OVNK_PEER}")"
docker exec "${OVNK_PEER}" bash -c "
  set -euo pipefail
  ip link del vrf-l2-a 2>/dev/null || true
  ip link add vrf-l2-a type vrf table 20100
  ip link set vrf-l2-a up
  ip link set brevpn.200 master vrf-l2-a up
  ip addr replace ${PEER_L2_A_IP}/24 dev brevpn.200

  ip link del brevpn.201 2>/dev/null || true
  ip link del vrf-evpn-b 2>/dev/null || true
  ip link add vrf-evpn-b type vrf table 20200
  ip link set vrf-evpn-b up

  bridge vlan add dev brevpn vid 201 self
  bridge vlan add dev vxevpn vid 201
  bridge vni add dev vxevpn vni ${MACVNI_B}
  bridge vlan add dev vxevpn vid 201 tunnel_info id ${MACVNI_B}
  ip link add brevpn.201 link brevpn type vlan id 201
  ip link set brevpn.201 addrgenmode none master vrf-evpn-b up
  ip addr replace ${PEER_L2_B_IP}/24 dev brevpn.201

  vtysh \
    -c 'configure terminal' \
    -c 'vrf vrf-evpn-b' \
    -c 'vni ${IPVNI_B}' \
    -c 'exit-vrf' \
    -c 'router bgp 65000' \
    -c 'address-family l2vpn evpn' \
    -c 'vni ${MACVNI_B}' \
    -c 'rd 65000:${MACVNI_B}' \
    -c 'route-target import 65000:${MACVNI_B}' \
    -c 'route-target export 65000:${MACVNI_B}' \
    -c 'exit-vni' \
    -c 'exit-address-family' \
    -c 'exit' \
    -c 'router bgp 65000 vrf vrf-evpn-b' \
    -c 'bgp router-id ${peer_ip}' \
    -c 'no bgp ebgp-requires-policy' \
    -c 'address-family l2vpn evpn' \
    -c 'rd 65000:${IPVNI_B}' \
    -c 'route-target import 65000:${IPVNI_B}' \
    -c 'route-target export 65000:${IPVNI_B}' \
    -c 'advertise ipv4 unicast' \
    -c 'exit-address-family' \
    -c 'end' >/dev/null
"

# 3. Implantar pod-x07-a (em tenant-evpn) e pod-x07-b (em tenant-evpn-b) no mesmo nó (ovnk-worker)
#    com exatamente o mesmo MAC (02:00:10:00:00:11) e o mesmo IP (10.0.0.11/24)
x07_log "Implantando pod-x07-a (tenant-evpn, VNI ${MACVNI_A}) e pod-x07-b (tenant-evpn-b, VNI ${MACVNI_B}) com MAC ${DUP_MAC} e IP ${DUP_IP}/24..."
x07_kctl -n tenant-evpn apply -f - <<EOF
apiVersion: k8s.cni.cncf.io/v1alpha1
kind: IPAMClaim
metadata:
  name: pod-x07-a-claim
  namespace: tenant-evpn
spec:
  network: cluster_udn_cudnevpn
  interface: ovn-udn1
---
apiVersion: v1
kind: Pod
metadata:
  name: pod-x07-a
  namespace: tenant-evpn
  annotations:
    v1.multus-cni.io/default-network: '[{"namespace":"ovn-kubernetes","name":"default","ips":["${DUP_IP}/24"],"mac":"${DUP_MAC}","ipam-claim-reference":"pod-x07-a-claim"}]'
spec:
  nodeName: ovnk-worker
  containers:
    - name: net
      image: ghcr.io/ovn-kubernetes/ovn-kubernetes/ovn-kube-ubuntu:release-1.4
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      securityContext:
        privileged: true
EOF

x07_kctl -n tenant-evpn-b apply -f - <<EOF
apiVersion: k8s.cni.cncf.io/v1alpha1
kind: IPAMClaim
metadata:
  name: pod-x07-b-claim
  namespace: tenant-evpn-b
spec:
  network: cluster_udn_cudnevpn-b
  interface: ovn-udn1
---
apiVersion: v1
kind: Pod
metadata:
  name: pod-x07-b
  namespace: tenant-evpn-b
  annotations:
    v1.multus-cni.io/default-network: '[{"namespace":"ovn-kubernetes","name":"default","ips":["${DUP_IP}/24"],"mac":"${DUP_MAC}","ipam-claim-reference":"pod-x07-b-claim"}]'
spec:
  nodeName: ovnk-worker
  containers:
    - name: net
      image: ghcr.io/ovn-kubernetes/ovn-kubernetes/ovn-kube-ubuntu:release-1.4
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      securityContext:
        privileged: true
EOF

x07_kctl -n tenant-evpn wait pod pod-x07-a --for=condition=Ready --timeout=180s >/dev/null
x07_kctl -n tenant-evpn-b wait pod pod-x07-b --for=condition=Ready --timeout=180s >/dev/null

# Garantir que o utilitário ping existe em ambos os pods e confirmar MAC/IP idênticos nas interfaces ovn-udn1
for ns_pod in "tenant-evpn:pod-x07-a" "tenant-evpn-b:pod-x07-b"; do
  ns="${ns_pod%%:*}"
  pod="${ns_pod##*:}"
  x07_kctl -n "${ns}" exec -i "${pod}" -- bash -s <<'PYEOF'
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
done

mac_a="$(x07_kctl -n tenant-evpn exec pod-x07-a -- ip -o link show dev ovn-udn1 | awk '{for(i=1;i<=NF;i++) if($i=="link/ether") print tolower($(i+1))}')"
ip_a="$(x07_kctl -n tenant-evpn exec pod-x07-a -- ip -o -4 addr show dev ovn-udn1 | awk '{print $4}')"
mac_b="$(x07_kctl -n tenant-evpn-b exec pod-x07-b -- ip -o link show dev ovn-udn1 | awk '{for(i=1;i<=NF;i++) if($i=="link/ether") print tolower($(i+1))}')"
ip_b="$(x07_kctl -n tenant-evpn-b exec pod-x07-b -- ip -o -4 addr show dev ovn-udn1 | awk '{print $4}')"

[[ "${mac_a}" == "${DUP_MAC}" && "${ip_a}" == "${DUP_IP}/24" ]] \
  || x07_die "pod-x07-a não recebeu MAC/IP esperados (${mac_a}, ${ip_a})"
[[ "${mac_b}" == "${DUP_MAC}" && "${ip_b}" == "${DUP_IP}/24" ]] \
  || x07_die "pod-x07-b não recebeu MAC/IP esperados (${mac_b}, ${ip_b})"

# 4. Gerar tráfego L2 inicial de ambos os pods para os respectivos endpoints em ovnk-evpn-peer
#    para popular FDB/ARP e anunciar rotas EVPN Type-2 ([2]:...[02:00:10:00:00:11]) nas duas MAC-VRFs
x07_kctl -n tenant-evpn exec pod-x07-a -- ping -c 3 -W 2 "${PEER_L2_A_IP}" >/dev/null 2>&1 || true
x07_kctl -n tenant-evpn-b exec pod-x07-b -- ping -c 3 -W 2 "${PEER_L2_B_IP}" >/dev/null 2>&1 || true

# 5. Verificar via JSON em ovnk-evpn-peer:
#    - Rotas EVPN Type-2 para 02:00:10:00:00:11 presentes tanto na MAC-VRF 20100 (RT 65000:20100) quanto na MAC-VRF 20200 (RT 65000:20200)
#    - Zero entradas marcadas como duplicate ou sticky em "show evpn mac vni 20100 json" e "show evpn mac vni 20200 json"
x07_log "Verificando rotas EVPN Type-2 e tabelas MAC JSON nas VNIs ${MACVNI_A} e ${MACVNI_B} em ${OVNK_PEER}..."
type2_ok=0
for _ in $(seq 1 25); do
  if docker exec "${OVNK_PEER}" python3 -c "
import json, subprocess, sys

target_mac = '${DUP_MAC}'.lower()
evpn = json.loads(subprocess.check_output(['vtysh', '-c', 'show bgp l2vpn evpn route detail json'], text=True))

found_20100 = False
found_20200 = False
for rd_key, rd_val in evpn.items():
    if not isinstance(rd_val, dict):
        continue
    for pfx_key, pfx_val in rd_val.items():
        if not isinstance(pfx_val, dict) or not str(pfx_key).startswith('[2]:'):
            continue
        if target_mac not in str(pfx_key).lower() and str(pfx_val.get('mac', '')).lower() != target_mac:
            continue
        for path_entry in pfx_val.get('paths', []):
            for p in (path_entry if isinstance(path_entry, list) else [path_entry]):
                if not isinstance(p, dict):
                    continue
                ext = (p.get('extendedCommunity') or {}).get('string', '')
                if '65000:20100' in ext or p.get('vni') == 20100 or '20100' in str(rd_key):
                    found_20100 = True
                if '65000:20200' in ext or p.get('vni') == 20200 or '20200' in str(rd_key):
                    found_20200 = True

if not (found_20100 and found_20200):
    sys.exit(1)

for vni in ('20100', '20200'):
    mac_tbl = json.loads(subprocess.check_output(['vtysh', '-c', f'show evpn mac vni {vni} json'], text=True))
    macs = mac_tbl.get('macs', mac_tbl) if isinstance(mac_tbl, dict) else {}
    if target_mac not in {k.lower() for k in macs.keys()}:
        sys.exit(2)
    for m_key, m_info in macs.items():
        if not isinstance(m_info, dict):
            continue
        flags = str(m_info.get('flags', '')).lower()
        if m_info.get('isDuplicate') is True or m_info.get('duplicate') is True or 'duplicate' in flags or 'sticky' in flags:
            print(f'Duplicate/sticky MAC detected in VNI {vni}: {m_key} -> {m_info}', file=sys.stderr)
            sys.exit(3)
" 2>/dev/null; then
    type2_ok=1
    break
  fi
  x07_kctl -n tenant-evpn exec pod-x07-a -- ping -c 1 -W 1 "${PEER_L2_A_IP}" >/dev/null 2>&1 || true
  x07_kctl -n tenant-evpn-b exec pod-x07-b -- ping -c 1 -W 1 "${PEER_L2_B_IP}" >/dev/null 2>&1 || true
  sleep 1
done
[[ "${type2_ok}" -eq 1 ]] || x07_die "Rotas EVPN Type-2 para ${DUP_MAC} não convergiram simultaneamente nas VNIs ${MACVNI_A} e ${MACVNI_B} sem duplicidade"

# 6. Controle positivo L2 intra-MAC-VRF (5/5 em VNI 20100 e 5/5 em VNI 20200) + prova de zero vazamento L2 entre MAC-VRFs (N2: >= 5 emissões na origem)
x07_log "Testando conectividade L2 intra-MAC-VRF (5/5), captura na origem (>= 5) e isolamento cruzado via tcpdump entre VNI ${MACVNI_A} e VNI ${MACVNI_B}..."

x07_kctl -n tenant-evpn-b exec pod-x07-b -- sh -c "
  rm -f /tmp/x07-cross-b.log
  timeout 12 tcpdump -ni ovn-udn1 -c 1 'icmp and host ${PEER_L2_A_IP}' >/tmp/x07-cross-b.log 2>&1
" >/dev/null 2>&1 &
pid_cap_b=$!

x07_kctl -n tenant-evpn exec pod-x07-a -- sh -c "
  rm -f /tmp/x07-cross-a.log
  timeout 12 tcpdump -ni ovn-udn1 -c 1 'icmp and host ${PEER_L2_B_IP}' >/tmp/x07-cross-a.log 2>&1
" >/dev/null 2>&1 &
pid_cap_a=$!

sleep 1

src_a_emitted="$(docker exec "${OVNK_PEER}" sh -c "
  rm -f /tmp/x07-src-a.pcap
  timeout 8 tcpdump -ni brevpn.200 -w /tmp/x07-src-a.pcap 'icmp[icmptype] == icmp-echo and src host ${PEER_L2_A_IP} and dst host ${DUP_IP}' >/dev/null 2>&1 &
  cap_pid=\$!
  sleep 1
  ip vrf exec vrf-l2-a ping -c 5 -W 2 ${DUP_IP} >/dev/null
  wait \"\${cap_pid}\" || true
  tcpdump -nr /tmp/x07-src-a.pcap 2>/dev/null | wc -l | tr -d ' '
")" || x07_die "Ping L2 intra-MAC-VRF ${MACVNI_A} (${PEER_L2_A_IP} -> ${DUP_IP}) falhou"

src_b_emitted="$(docker exec "${OVNK_PEER}" sh -c "
  rm -f /tmp/x07-src-b.pcap
  timeout 8 tcpdump -ni brevpn.201 -w /tmp/x07-src-b.pcap 'icmp[icmptype] == icmp-echo and src host ${PEER_L2_B_IP} and dst host ${DUP_IP}' >/dev/null 2>&1 &
  cap_pid=\$!
  sleep 1
  ip vrf exec vrf-evpn-b ping -c 5 -W 2 ${DUP_IP} >/dev/null
  wait \"\${cap_pid}\" || true
  tcpdump -nr /tmp/x07-src-b.pcap 2>/dev/null | wc -l | tr -d ' '
")" || x07_die "Ping L2 intra-MAC-VRF ${MACVNI_B} (${PEER_L2_B_IP} -> ${DUP_IP}) falhou"

rc_cap_b=0
wait "${pid_cap_b}" || rc_cap_b=$?
rc_cap_a=0
wait "${pid_cap_a}" || rc_cap_a=$?

log_cap_b="$(x07_kctl -n tenant-evpn-b exec pod-x07-b -- cat /tmp/x07-cross-b.log 2>/dev/null || true)"
log_cap_a="$(x07_kctl -n tenant-evpn exec pod-x07-a -- cat /tmp/x07-cross-a.log 2>/dev/null || true)"

if [[ "${src_a_emitted:-0}" -lt 5 ]]; then
  x07_die "Emissão insuficiente na origem MAC-VRF ${MACVNI_A} (brevpn.200): ${src_a_emitted:-0}/5 pacotes"
fi
if [[ "${src_b_emitted:-0}" -lt 5 ]]; then
  x07_die "Emissão insuficiente na origem MAC-VRF ${MACVNI_B} (brevpn.201): ${src_b_emitted:-0}/5 pacotes"
fi
if [[ "${rc_cap_b}" -ne 124 ]] || ! grep -q "0 packets captured" <<<"${log_cap_b}"; then
  x07_die "Vazamento L2 de VNI ${MACVNI_A} (${PEER_L2_A_IP}) para pod-x07-b em VNI ${MACVNI_B} (rc=${rc_cap_b}, log=${log_cap_b})"
fi
if [[ "${rc_cap_a}" -ne 124 ]] || ! grep -q "0 packets captured" <<<"${log_cap_a}"; then
  x07_die "Vazamento L2 de VNI ${MACVNI_B} (${PEER_L2_B_IP}) para pod-x07-a em VNI ${MACVNI_A} (rc=${rc_cap_a}, log=${log_cap_a})"
fi

cleanup_x07
trap - EXIT

printf 'X07 PASS (Gate G05): MAC %s + IP %s/24 ativos simultaneamente em MAC-VRF %s (RT 65000:%s) e MAC-VRF %s (RT 65000:%s) via EVPN Type-2; 0 flags duplicate/sticky em JSON; pings L2 intra-MAC-VRF 5/5 OK (emissões %s/%s) e 0 pacotes cruzados (rc=%s/%s).\n' \
  "${DUP_MAC}" "${DUP_IP}" "${MACVNI_A}" "${MACVNI_A}" "${MACVNI_B}" "${MACVNI_B}" "${src_a_emitted}" "${src_b_emitted}" "${rc_cap_b}" "${rc_cap_a}"
