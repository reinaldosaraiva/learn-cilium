#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p004/ovnk/k01.sh — Caso K01: UDN Layer2 same-CIDR (10.0.0.0/24) + boot de VMs KubeVirt + prova de isolamento (R4 + N2).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN="${DRY_RUN:-${LABCTL_DRY_RUN:-0}}"
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

OVNK_KUBECONFIG="${OVNK_KUBECONFIG:-/root/.kube/ovnk.config}"
OVNK_CONTEXT="${OVNK_CONTEXT:-kind-ovnk}"

k01_kctl() {
  if [[ -f "${OVNK_KUBECONFIG}" ]]; then
    kubectl --kubeconfig "${OVNK_KUBECONFIG}" --context "${OVNK_CONTEXT}" "$@"
  else
    kubectl --context "${OVNK_CONTEXT}" "$@"
  fi
}

k01_run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf 'DRY: %s\n' "$*"
    return 0
  fi
  printf '[k01] + %s\n' "$*"
  "$@"
}

if [[ "${DRY_RUN}" == "1" ]]; then
  k01_run k01_kctl apply -f "${SCRIPT_DIR}/udn-net-a.yaml"
  k01_run k01_kctl apply -f "${SCRIPT_DIR}/udn-net-b.yaml"
  k01_run k01_kctl apply -f "${SCRIPT_DIR}/vm-a-udn.yaml"
  k01_run k01_kctl apply -f "${SCRIPT_DIR}/vm-b-udn.yaml"
  k01_run k01_kctl -n tenant-a wait vmi vm-a --for=condition=Ready --timeout=240s
  k01_run k01_kctl -n tenant-b wait vmi vm-b --for=condition=Ready --timeout=240s
  printf 'K01 DRY-RUN OK\n'
  exit 0
fi

# 1. Aplicar UDNs primárias Layer2 (10.0.0.0/24 em tenant-a e tenant-b) e aguardar NADs antes das VMs KubeVirt
k01_run k01_kctl apply -f "${SCRIPT_DIR}/udn-net-a.yaml"
k01_run k01_kctl apply -f "${SCRIPT_DIR}/udn-net-b.yaml"
for _ in $(seq 1 30); do
  if k01_kctl -n tenant-a get network-attachment-definitions udn-net-a >/dev/null 2>&1 && \
     k01_kctl -n tenant-b get network-attachment-definitions udn-net-b >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
k01_run k01_kctl apply -f "${SCRIPT_DIR}/vm-a-udn.yaml"
k01_run k01_kctl apply -f "${SCRIPT_DIR}/vm-b-udn.yaml"

# Pods auxiliares por tenant para controle positivo e geração/captura determinística na UDN primária
k01_kctl -n tenant-a apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: probe-a
  namespace: tenant-a
  labels:
    app: probe-a
spec:
  containers:
    - name: net
      image: ghcr.io/ovn-kubernetes/ovn-kubernetes/ovn-kube-ubuntu:release-1.4
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      securityContext:
        privileged: true
EOF

k01_kctl -n tenant-b apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: probe-b
  namespace: tenant-b
  labels:
    app: probe-b
spec:
  containers:
    - name: net
      image: ghcr.io/ovn-kubernetes/ovn-kubernetes/ovn-kube-ubuntu:release-1.4
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      securityContext:
        privileged: true
EOF

k01_run k01_kctl -n tenant-a wait vmi vm-a --for=condition=Ready --timeout=240s
k01_run k01_kctl -n tenant-b wait vmi vm-b --for=condition=Ready --timeout=240s
k01_run k01_kctl -n tenant-a wait pod probe-a --for=condition=Ready --timeout=180s
k01_run k01_kctl -n tenant-b wait pod probe-b --for=condition=Ready --timeout=180s

k01_ensure_ping() {
  local ns="$1"
  local pod="$2"
  k01_kctl -n "${ns}" exec -i "${pod}" -- bash -s <<'PYEOF'
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
}
k01_ensure_ping tenant-a probe-a
k01_ensure_ping tenant-b probe-b

# 2. Verificar фаse Running nas duas VMIs
phase_a="$(k01_kctl -n tenant-a get vmi vm-a -o json | jq -r '.status.phase')"
phase_b="$(k01_kctl -n tenant-b get vmi vm-b -o json | jq -r '.status.phase')"
if [[ "${phase_a}" != "Running" ]] || [[ "${phase_b}" != "Running" ]]; then
  printf '[k01] ERRO: VMIs fora de Running (vm-a=%s, vm-b=%s)\n' "${phase_a}" "${phase_b}" >&2
  exit 1
fi

# 3. Controle positivo intra-tenant (R4): aguardar boot do guest OS CirrOS e validar 5/5 pings dentro de cada UDN antes do teste cruzado
for _ in $(seq 1 45); do
  if k01_kctl -n tenant-a exec probe-a -- ping -c 1 -W 1 10.0.0.11 >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
if ! k01_kctl -n tenant-a exec probe-a -- ping -c 5 -W 2 10.0.0.11 >/dev/null; then
  printf '[k01] ERRO: controle positivo intra-tenant A falhou (probe-a -> vm-a 10.0.0.11)\n' >&2
  exit 1
fi
for _ in $(seq 1 45); do
  if k01_kctl -n tenant-b exec probe-b -- ping -c 1 -W 1 10.0.0.12 >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
if ! k01_kctl -n tenant-b exec probe-b -- ping -c 5 -W 2 10.0.0.12 >/dev/null; then
  printf '[k01] ERRO: controle positivo intra-tenant B falhou (probe-b -> vm-b 10.0.0.12)\n' >&2
  exit 1
fi

# 4. Prova de isolamento same-CIDR 10.0.0.0/24 (R4 + N2):
#    - Captura de 12s na porta UDN de vm-b (10.0.0.12) no nó de destino em tenant-b (rc=124 e 0 pacotes vindos de tenant-a)
#    - Captura de 12s com -w /tmp/k01-src.pcap na interface UDN de origem em tenant-a (>= 5 echo requests emitidos)
node_b="$(k01_kctl -n tenant-b get vmi vm-b -o jsonpath='{.status.nodeName}')"
pod_b="$(k01_kctl -n tenant-b get pods -l kubevirt.io=virt-launcher,kubevirt.io/domain=vm-b --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
ovnk_pod_b="$(k01_kctl -n ovn-kubernetes get pods -l app=ovnkube-node --field-selector="spec.nodeName=${node_b}" -o jsonpath='{.items[0].metadata.name}')"

k01_kctl -n ovn-kubernetes exec "${ovnk_pod_b}" -c ovnkube-controller -- bash -c "
  rm -f /tmp/k01-dst.log
  dst_if=\"\$(python3 -c '
import json, subprocess
data = json.loads(subprocess.check_output([\"ovs-vsctl\", \"--format=json\", \"--columns=name,external_ids\", \"list\", \"interface\"], text=True))
for row in data.get(\"data\", []):
    name = row[0]
    ext = dict(row[1][1]) if isinstance(row[1], list) and len(row[1]) > 1 else {}
    iface_id = ext.get(\"iface-id\", \"\")
    pod_if = ext.get(\"pod-if-name\", \"\")
    if \"${pod_b}\" in iface_id and (\"udn\" in iface_id or pod_if == \"ovn-udn1\"):
        print(name)
        break
')\"
  if [[ -z \"\${dst_if}\" ]]; then
    echo 'ERRO: interface OVS da UDN de vm-b nao encontrada' >&2
    exit 2
  fi
  timeout 12 tcpdump -ni \"\${dst_if}\" -c 1 'icmp and dst host 10.0.0.12' >/tmp/k01-dst.log 2>&1
" >/tmp/k01-dst-rc.out 2>&1 &
pid_dst=$!

k01_kctl -n tenant-a exec -i probe-a -- bash -s <<'EOF' >/tmp/k01-src-count.out 2>/dev/null
rm -f /tmp/k01-src.pcap
udn_if="$(ip -o -4 addr show | awk '$4 ~ /^10\.0\.0\./ {print $2; exit}')"
udn_if="${udn_if:-ovn-udn1}"
ip neigh replace 10.0.0.12 lladdr 02:00:10:00:02:12 dev "${udn_if}" nud permanent
timeout 12 tcpdump -ni "${udn_if}" -w /tmp/k01-src.pcap "icmp[icmptype] == icmp-echo and dst host 10.0.0.12" >/dev/null 2>&1 &
pid_cap=$!
sleep 1
ping -c 5 -W 1 10.0.0.12 >/dev/null 2>&1 || true
ip neigh del 10.0.0.12 dev "${udn_if}" 2>/dev/null || true
wait "${pid_cap}" || true
tcpdump -nr /tmp/k01-src.pcap 2>/dev/null | wc -l | tr -d " "
EOF

dst_rc=0
wait "${pid_dst}" || dst_rc=$?
dst_log="$(k01_kctl -n ovn-kubernetes exec "${ovnk_pod_b}" -c ovnkube-controller -- cat /tmp/k01-dst.log 2>/dev/null || true)"
src_emitted="$(tail -n1 /tmp/k01-src-count.out | tr -d '[:space:]')"
rm -f /tmp/k01-dst-rc.out /tmp/k01-src-count.out

if [[ "${dst_rc}" -ne 124 ]] || ! grep -q "0 packets captured" <<<"${dst_log}"; then
  printf '[k01] ERRO: violação de isolamento same-CIDR em tenant-b (rc=%s, log=%s)\n' "${dst_rc}" "${dst_log}" >&2
  exit 1
fi
if [[ "${src_emitted:-0}" -lt 5 ]]; then
  printf '[k01] ERRO: prova de isolamento inválida (N2) — origem emitiu apenas %s/5 ICMP echo requests\n' "${src_emitted:-0}" >&2
  exit 1
fi

printf 'K01 PASS: vm-a (10.0.0.11/24) e vm-b (10.0.0.12/24) Running; controles positivos 5/5 OK; isolamento same-CIDR provado (%s emissões na origem, 0 recepções no destino, rc=%s).\n' "${src_emitted}" "${dst_rc}"
