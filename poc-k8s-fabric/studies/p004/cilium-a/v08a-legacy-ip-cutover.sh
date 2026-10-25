#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p004/cilium-a/v08a-legacy-ip-cutover.sh — Caso V08-A (C08 / H8):
# VM legada QEMU/KVM em 10.60.0.50/24 acessível via border1 (198.19.0.10 -> 10.60.0.50:8080, 30/30 OK),
# seguida de desligamento da instância legada (cutover com corte, sem coexistência L2), ativação de
# CiliumPodIPPool /32 (p004-legacy-ip: 10.60.0.50/32) anunciado via BGP na border1 e subida de VMI
# KubeVirt (vm-legacy-cutover) assumindo o IP original 10.60.0.50/32 (30/30 OK), com rollback limpo
# para ipam.mode=kubernetes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN="${DRY_RUN:-${LABCTL_DRY_RUN:-0}}"
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

P003_KUBECONFIG="${P003_KUBECONFIG:-/root/.kube/p003-gw.config}"
P003_CONTEXT="${P003_CONTEXT:-kind-p003-gw}"
P003_EXPECTED_UID="${P003_EXPECTED_UID:-6bb32e0f-71f9-4558-ae33-356ba2250c26}"

K01_KUBECONFIG="${K01_KUBECONFIG:-/root/.kube/k01-rebuild.config}"
K01_CONTEXT="${K01_CONTEXT:-kind-k01}"
K01_EXPECTED_UID="${K01_EXPECTED_UID:-635e7274-5597-40c7-9de5-b1fbe3d68b22}"
P003_OS_CONTAINER="${P003_OS_CONTAINER:-p003-os}"
P003_OS_EXPECTED_STATE="${P003_OS_EXPECTED_STATE:-exited}"
MIN_MEM_AVAILABLE_KB="${MIN_MEM_AVAILABLE_KB:-4194304}"

LABCTL_BIN="${LABCTL_BIN:-/opt/poc-k8s-fabric/labctl}"
if [[ -d "${LABCTL_BIN}" ]] && [[ -x "${LABCTL_BIN}/labctl" ]]; then
  LABCTL_BIN="${LABCTL_BIN}/labctl"
fi

CHART="${CILIUM_CHART:-/opt/poc-k8s-fabric-studies/studies/p003/base/cilium-1.20.2.tgz}"
BASE_VALUES="${CILIUM_BASE_VALUES:-/opt/poc-k8s-fabric-studies/studies/p003/base/values-p003.yaml}"
BASE_BGP_ADV="${CILIUM_BASE_BGP_ADV:-/opt/poc-k8s-fabric-studies/studies/p003/base/bgp/02-advertisements.yaml}"
M32_VALUES="${SCRIPT_DIR}/manifests/values-p004-m32.yaml"
CUTOVER_MANIFEST="${SCRIPT_DIR}/manifests/08-v08a-legacy-cutover.yaml"

NS_LEGACY="p004-vm-legacy"
LEGACY_IP="10.60.0.50"
LEGACY_GW="10.60.0.1"
LEGACY_SUBNET="10.60.0.0/24"
LEGACY_BR="br-v08-legacy"
LEGACY_TAP="tap-v08-legacy"
LEGACY_WORKDIR="/tmp/v08a-legacy"
CIRROS_IMAGE="quay.io/kubevirt/cirros-container-disk-demo:v1.9.0"
BORDER="clab-p003-gw-fabric-border1"
CLIENT="clab-p003-gw-fabric-client"

v08a_kctl() {
  if [[ -f "${P003_KUBECONFIG}" ]]; then
    kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" "$@"
  else
    kubectl --context "${P003_CONTEXT}" "$@"
  fi
}

k01_kctl() {
  if [[ -f "${K01_KUBECONFIG}" ]]; then
    kubectl --kubeconfig "${K01_KUBECONFIG}" --context "${K01_CONTEXT}" "$@"
  else
    kubectl --context "${K01_CONTEXT}" "$@"
  fi
}

v08a_run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf 'DRY: %s\n' "$*"
    return 0
  fi
  printf '[v08a] + %s\n' "$*"
  "$@"
}

v08a_stop_legacy_kvm() {
  if [[ -f "${LEGACY_WORKDIR}/qemu.pid" ]]; then
    kill -9 "$(cat "${LEGACY_WORKDIR}/qemu.pid")" >/dev/null 2>&1 || true
    rm -f "${LEGACY_WORKDIR}/qemu.pid"
  fi
  if [[ -f "${LEGACY_WORKDIR}/dhcpd.pid" ]]; then
    kill -9 "$(cat "${LEGACY_WORKDIR}/dhcpd.pid")" >/dev/null 2>&1 || true
    rm -f "${LEGACY_WORKDIR}/dhcpd.pid"
  fi
  ip link del "${LEGACY_TAP}" >/dev/null 2>&1 || true
  ip link del "${LEGACY_BR}" >/dev/null 2>&1 || true
  ip route del 198.19.0.0/24 >/dev/null 2>&1 || true
  iptables -D FORWARD -s "${LEGACY_SUBNET}" -j ACCEPT >/dev/null 2>&1 || true
  iptables -D FORWARD -d "${LEGACY_SUBNET}" -j ACCEPT >/dev/null 2>&1 || true
  docker exec "${BORDER}" vtysh \
    -c "conf t" \
    -c "no ip route ${LEGACY_SUBNET} 10.101.0.1" \
    -c "end" >/dev/null 2>&1 || true
  rm -rf "${LEGACY_WORKDIR}"
}

v08a_flush_residual_routes() {
  local node cidr
  for node in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
    while read -r cidr; do
      if [[ -n "${cidr}" ]]; then
        docker exec "${node}" ip -4 route del "${cidr}" >/dev/null 2>&1 || true
      fi
    done < <(docker exec "${node}" ip -4 route show 2>/dev/null | awk '$1 ~ /^10\.(60\.0|251|252|253)\./ {print $1}')
  done
}

if [[ "${DRY_RUN}" == "1" ]]; then
  v08a_run v08a_kctl get ns kube-system -o jsonpath='{.metadata.uid}'
  v08a_run k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}'
  v08a_run docker inspect -f '{{.State.Status}}' "${P003_OS_CONTAINER}"
  printf 'DRY: check /proc/meminfo MemAvailable >= %s kB (R3)\n' "${MIN_MEM_AVAILABLE_KB}"
  printf 'DRY: boot legacy QEMU/KVM VM (%s/24 on %s) + route %s via 10.101.0.1 on %s -> 30/30 HTTP probes from %s\n' \
    "${LEGACY_IP}" "${LEGACY_BR}" "${LEGACY_SUBNET}" "${BORDER}" "${CLIENT}"
  printf 'DRY: shut down legacy QEMU/KVM VM (cutover window, 0/5 probes during outage)\n'
  printf 'DRY: helm upgrade cilium multi-pool (%s) + apply %s (CiliumPodIPPool/p004-legacy-ip %s/32 + vm-legacy-cutover)\n' \
    "${M32_VALUES}" "${CUTOVER_MANIFEST}" "${LEGACY_IP}"
  printf 'DRY: configure PL-FROM-FABRIC seq 70 permit %s le 32 on %s -> verify %s/32 in BGP RIB and 30/30 HTTP probes from %s\n' \
    "${LEGACY_SUBNET}" "${BORDER}" "${LEGACY_IP}" "${CLIENT}"
  printf 'DRY: rollback to ipam.mode=kubernetes (%s), remove pools/namespaces/prefix-list seq 50-70, verify p003-gw and k01\n' \
    "${BASE_VALUES}"
  printf 'V08A DRY-RUN OK\n'
  exit 0
fi

# 1. Validar UIDs de p003-gw e k01, estado exited de p003-os e orçamento de RAM (R3 >= 4 GiB)
uid_p003="$(v08a_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_p003}" != "${P003_EXPECTED_UID}" ]]; then
  printf '[v08a] ERRO: UID de p003-gw (%s) difere do esperado (%s)\n' "${uid_p003}" "${P003_EXPECTED_UID}" >&2
  exit 1
fi
uid_k01="$(k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_k01}" != "${K01_EXPECTED_UID}" ]]; then
  printf '[v08a] ERRO: UID de k01 (%s) difere do esperado (%s)\n' "${uid_k01}" "${K01_EXPECTED_UID}" >&2
  exit 1
fi
os_state="$(docker inspect -f '{{.State.Status}}' "${P003_OS_CONTAINER}" 2>/dev/null || true)"
if [[ "${os_state}" != "${P003_OS_EXPECTED_STATE}" ]]; then
  printf '[v08a] ERRO: estado de %s (%s) difere do esperado (%s)\n' "${P003_OS_CONTAINER}" "${os_state:-ausente}" "${P003_OS_EXPECTED_STATE}" >&2
  exit 1
fi
mem_avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
if [[ -z "${mem_avail_kb}" ]] || (( mem_avail_kb < MIN_MEM_AVAILABLE_KB )); then
  printf '[v08a] ERRO: MemAvailable=%s kB abaixo do piso R3 (%s kB)\n' "${mem_avail_kb:-0}" "${MIN_MEM_AVAILABLE_KB}" >&2
  exit 1
fi

api_ip="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' p003-gw-control-plane)"

V08A_CLEANUP_DONE=0
V08A_CILIUM_TOUCHED=0
v08a_cleanup() {
  if [[ "${V08A_CLEANUP_DONE}" == "1" ]]; then
    return 0
  fi
  V08A_CLEANUP_DONE=1
  printf '[v08a] Iniciando rollback limpo para ipam.mode=kubernetes...\n'
  v08a_stop_legacy_kvm

  if [[ "${V08A_CILIUM_TOUCHED}" == "0" ]]; then
    return 0
  fi

  v08a_kctl -n "${NS_LEGACY}" delete vm --all --ignore-not-found >/dev/null 2>&1 || true
  v08a_kctl -n "${NS_LEGACY}" delete pods --all --ignore-not-found --grace-period=0 --force >/dev/null 2>&1 || true
  v08a_kctl delete ns "${NS_LEGACY}" --ignore-not-found --timeout=180s >/dev/null 2>&1 || true

  v08a_run v08a_kctl apply -f "${BASE_BGP_ADV}"
  v08a_kctl delete ciliumpodippool p004-legacy-ip p004-vm default --ignore-not-found >/dev/null 2>&1 || true

  docker exec "${BORDER}" vtysh \
    -c "conf t" \
    -c "no ip prefix-list PL-FROM-FABRIC seq 50 permit 10.251.0.0/16 le 32" \
    -c "no ip prefix-list PL-FROM-FABRIC seq 60 permit 10.252.0.0/16 le 32" \
    -c "no ip prefix-list PL-FROM-FABRIC seq 70 permit 10.60.0.0/24 le 32" \
    -c "end" \
    -c "clear ip bgp 10.254.0.0 soft in" >/dev/null 2>&1 || true

  v08a_run helm upgrade cilium "${CHART}" \
    --kubeconfig "${P003_KUBECONFIG}" --kube-context "${P003_CONTEXT}" \
    -n kube-system -f "${BASE_VALUES}" --set "k8sServiceHost=${api_ip}" >/dev/null
  v08a_run v08a_kctl -n kube-system rollout restart deploy/cilium-operator ds/cilium
  v08a_run v08a_kctl -n kube-system rollout status deploy/cilium-operator --timeout=240s
  v08a_run v08a_kctl -n kube-system rollout status ds/cilium --timeout=240s
  v08a_flush_residual_routes

  v08a_kctl -n kube-system delete pods -l k8s-app=kube-dns --grace-period=0 --force >/dev/null 2>&1 || true
  v08a_run v08a_kctl -n kube-system rollout status deploy/coredns --timeout=180s

  v08a_kctl -n kubevirt delete pods --all --grace-period=0 --force >/dev/null 2>&1 || true
  v08a_run v08a_kctl -n kubevirt rollout status deploy/virt-operator deploy/virt-api deploy/virt-controller ds/virt-handler --timeout=240s
  v08a_run v08a_kctl -n kubevirt wait kubevirt kubevirt --for=condition=Available --timeout=240s

  v08a_kctl -n p003-gateway delete pods --all --grace-period=0 --force >/dev/null 2>&1 || true
  v08a_run v08a_kctl -n p003-gateway rollout status deploy/http-echo deploy/p003-dns deploy/tcp-echo --timeout=180s
}
trap v08a_cleanup EXIT

# 2. Fase 1: Instanciar VM legada QEMU/KVM em 10.60.0.50/24 no segmento 10.60.0.0/24 conectado à border1 via p003-ext
printf '[v08a] Fase 1: preparando VM legada QEMU/KVM em %s/24...\n' "${LEGACY_IP}"
v08a_stop_legacy_kvm
mkdir -p "${LEGACY_WORKDIR}/cidata"

if ! docker image inspect "${CIRROS_IMAGE}" >/dev/null 2>&1; then
  docker exec p003-gw-worker crictl pull "${CIRROS_IMAGE}" >/dev/null 2>&1 || true
  docker pull "${CIRROS_IMAGE}" >/dev/null
fi
cid_tmp="$(docker create "${CIRROS_IMAGE}" /true)"
docker cp "${cid_tmp}:/disk/downloaded" "${LEGACY_WORKDIR}/base-cirros.img"
docker rm -f "${cid_tmp}" >/dev/null
qemu-img create -f qcow2 -F qcow2 -b "${LEGACY_WORKDIR}/base-cirros.img" "${LEGACY_WORKDIR}/legacy.qcow2" >/dev/null

cat >"${LEGACY_WORKDIR}/cidata/meta-data" <<'EOF'
{"instance-id":"legacy-vm-01","local-hostname":"legacy-kvm-vm"}
EOF

cat >"${LEGACY_WORKDIR}/cidata/user-data" <<'EOF'
#!/bin/sh
ip link set eth0 up
if ! ip -4 -o addr show dev eth0 2>/dev/null | grep -q "10.60.0.50/"; then
  ip addr add 10.60.0.50/24 dev eth0 2>/dev/null || true
fi
cat >/tmp/http8080.sh <<'INNER'
#!/bin/sh
rm -f /tmp/httpfifo
mkfifo /tmp/httpfifo
body="LEGACY_KVM_OK host=$(hostname) vm=legacy-kvm-vm orig_ip=10.60.0.50 guest_ip=$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}')"
len=$(( ${#body} + 1 ))
while true; do
  (
    dd if=/tmp/httpfifo bs=4096 count=1 >/dev/null 2>&1
    printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s\n' "$len" "$body"
    sleep 0.02
  ) | nc -l -p 8080 >/tmp/httpfifo 2>/dev/null || sleep 0.02
done
INNER
chmod +x /tmp/http8080.sh
nohup /tmp/http8080.sh >/dev/null 2>&1 &
EOF

mkfs.ext2 -q -F -L cidata -d "${LEGACY_WORKDIR}/cidata" "${LEGACY_WORKDIR}/cidata.img" 4M

ip link add "${LEGACY_BR}" type bridge stp_state 0 forward_delay 0
ip addr add "${LEGACY_GW}/24" dev "${LEGACY_BR}"
ip addr add "${LEGACY_IP}/24" dev "${LEGACY_BR}"
ip link set "${LEGACY_BR}" up
ip tuntap add dev "${LEGACY_TAP}" mode tap
ip link set "${LEGACY_TAP}" master "${LEGACY_BR}"
ip link set "${LEGACY_TAP}" up
iptables -I FORWARD 1 -s "${LEGACY_SUBNET}" -j ACCEPT
iptables -I FORWARD 1 -d "${LEGACY_SUBNET}" -j ACCEPT
border_ext_ip="$(docker exec "${BORDER}" ip -4 -o addr show | awk '$4 ~ /^10\.101\.0\./ {sub(/\/.*/, "", $4); print $4; exit}')"
if [[ -n "${border_ext_ip}" ]]; then
  ip route replace 198.19.0.0/24 via "${border_ext_ip}"
fi

cat >"${LEGACY_WORKDIR}/dhcpd.py" <<'EOF'
#!/usr/bin/env python3
"""Minimal BOOTP/DHCPv4 responder and lease verifier for the legacy QEMU/KVM VM."""

from __future__ import annotations

from dataclasses import dataclass
import socket
import struct
import sys


@dataclass(frozen=True)
class DhcpLeaseConfig:
    iface: str
    server_ip: str
    yiaddr: str
    netmask: str
    router: str
    lease_seconds: int = 3600


def build_dhcp_reply(packet: bytes, cfg: DhcpLeaseConfig) -> bytes | None:
    if len(packet) < 240 or packet[0] != 1:
        return None
    xid = packet[4:8]
    chaddr = packet[28:44]
    magic = packet[236:240]
    if magic != b"\x63\x82\x53\x63":
        return None

    msg_type = 1
    idx = 240
    while idx < len(packet):
        opt = packet[idx]
        if opt == 255:
            break
        if opt == 0:
            idx += 1
            continue
        length = packet[idx + 1]
        if opt == 53 and length >= 1:
            msg_type = packet[idx + 2]
        idx += 2 + length

    reply_type = 2 if msg_type == 1 else 5
    srv_bytes = socket.inet_aton(cfg.server_ip)
    yi_bytes = socket.inet_aton(cfg.yiaddr)
    mask_bytes = socket.inet_aton(cfg.netmask)
    gw_bytes = socket.inet_aton(cfg.router)

    header = bytearray(236)
    header[0] = 2
    header[1] = 1
    header[2] = 6
    header[4:8] = xid
    header[16:20] = yi_bytes
    header[20:24] = srv_bytes
    header[28:44] = chaddr

    options = (
        magic
        + bytes([53, 1, reply_type])
        + bytes([54, 4])
        + srv_bytes
        + bytes([1, 4])
        + mask_bytes
        + bytes([3, 4])
        + gw_bytes
        + bytes([51, 4])
        + struct.pack("!I", cfg.lease_seconds)
        + bytes([255])
    )
    return bytes(header) + options


def self_test(cfg: DhcpLeaseConfig) -> None:
    discover = bytearray(244)
    discover[0] = 1
    discover[1] = 1
    discover[2] = 6
    discover[4:8] = b"\x12\x34\x56\x78"
    discover[236:240] = b"\x63\x82\x53\x63"
    discover[240:244] = bytes([53, 1, 1, 255])
    offer = build_dhcp_reply(bytes(discover), cfg)
    if offer is None or offer[16:20] != socket.inet_aton(cfg.yiaddr):
        raise SystemExit("DHCP self-test failed")


if __name__ == "__main__":
    default_cfg = DhcpLeaseConfig(
        iface="br-v08-legacy",
        server_ip="10.60.0.1",
        yiaddr="10.60.0.50",
        netmask="255.255.255.0",
        router="10.60.0.1",
    )
    if "--self-test" in sys.argv:
        self_test(default_cfg)
EOF
python3 "${LEGACY_WORKDIR}/dhcpd.py" --self-test

qemu-system-x86_64 \
  -enable-kvm \
  -name v08a-legacy-vm \
  -m 192 \
  -smp 1 \
  -display none \
  -serial "file:${LEGACY_WORKDIR}/serial.log" \
  -pidfile "${LEGACY_WORKDIR}/qemu.pid" \
  -daemonize \
  -drive "file=${LEGACY_WORKDIR}/legacy.qcow2,if=virtio,format=qcow2" \
  -drive "file=${LEGACY_WORKDIR}/cidata.img,if=virtio,format=raw" \
  -netdev "user,id=net0,net=10.60.0.0/24,dhcpstart=${LEGACY_IP},hostfwd=tcp:${LEGACY_IP}:8080-${LEGACY_IP}:8080" \
  -device "virtio-net-pci,netdev=net0,mac=52:54:00:60:00:50"

docker exec "${BORDER}" vtysh \
  -c "conf t" \
  -c "ip route ${LEGACY_SUBNET} 10.101.0.1" \
  -c "end" >/dev/null

for _ in $(seq 1 45); do
  if docker exec "${CLIENT}" curl -s --noproxy '*' --connect-timeout 1 --max-time 2 "http://${LEGACY_IP}:8080/" 2>/dev/null | grep -q "LEGACY_KVM_OK"; then
    break
  fi
  sleep 1
done

printf '[v08a] Rota para %s na %s antes do cutover (instância legada QEMU/KVM):\n' "${LEGACY_IP}" "${BORDER}"
docker exec "${BORDER}" vtysh -c "show ip route ${LEGACY_IP}"

legacy_ok=0
legacy_sample=""
for _ in $(seq 1 30); do
  out=""
  for _ in 1 2 3; do
    out="$(docker exec "${CLIENT}" curl -s --noproxy '*' --connect-timeout 2 --max-time 3 "http://${LEGACY_IP}:8080/" 2>/dev/null || true)"
    if [[ "${out}" == *"LEGACY_KVM_OK"* ]]; then
      break
    fi
    sleep 0.1
  done
  if [[ "${out}" == *"LEGACY_KVM_OK"* ]]; then
    legacy_ok=$((legacy_ok + 1))
    legacy_sample="${out}"
  fi
  sleep 0.05
done
printf '[v08a] Fase 1 (VM legada QEMU/KVM %s -> %s:8080): %s/30 OK (amostra: %s)\n' \
  "${CLIENT}" "${LEGACY_IP}" "${legacy_ok}" "${legacy_sample}"
if [[ "${legacy_ok}" -ne 30 ]]; then
  printf '[v08a] ERRO: VM legada QEMU/KVM não atingiu 30/30 probes (%s/30)\n' "${legacy_ok}" >&2
  exit 1
fi

# 3. Preparar Cilium em ipam.mode=multi-pool enquanto a VM legada continua ativa (para medir cutover puro de workload)
V08A_CILIUM_TOUCHED=1
v08a_kctl apply -f - <<'EOF'
apiVersion: cilium.io/v2alpha1
kind: CiliumPodIPPool
metadata:
  name: default
  labels:
    study: P004
spec:
  ipv4:
    cidrs:
      - 10.251.0.0/16
    maskSize: 24
---
apiVersion: cilium.io/v2alpha1
kind: CiliumPodIPPool
metadata:
  name: p004-vm
  labels:
    study: P004
spec:
  ipv4:
    cidrs:
      - 10.252.0.0/16
    maskSize: 32
EOF

cur_ipam="$(v08a_kctl -n kube-system get cm cilium-config -o jsonpath='{.data.ipam}' 2>/dev/null || true)"
if [[ "${cur_ipam}" != "multi-pool" ]]; then
  v08a_kctl -n p004-vm-a patch vm vm-a --type=merge -p '{"spec":{"runStrategy":"Halted"}}' >/dev/null 2>&1 || true
  v08a_run helm upgrade cilium "${CHART}" \
    --kubeconfig "${P003_KUBECONFIG}" --kube-context "${P003_CONTEXT}" \
    -n kube-system -f "${M32_VALUES}" --set "k8sServiceHost=${api_ip}" >/dev/null
  v08a_run v08a_kctl -n kube-system rollout restart deploy/cilium-operator ds/cilium
  v08a_run v08a_kctl -n kube-system rollout status deploy/cilium-operator --timeout=240s
  v08a_run v08a_kctl -n kube-system rollout status ds/cilium --timeout=240s
  v08a_kctl -n kube-system delete pods -l k8s-app=kube-dns --grace-period=0 --force >/dev/null 2>&1 || true
  v08a_run v08a_kctl -n kube-system rollout status deploy/coredns --timeout=180s

  v08a_kctl -n kubevirt delete pods --all --grace-period=0 --force >/dev/null 2>&1 || true
  v08a_run v08a_kctl -n kubevirt rollout status deploy/virt-operator deploy/virt-api deploy/virt-controller ds/virt-handler --timeout=240s
  v08a_run v08a_kctl -n kubevirt wait kubevirt kubevirt --for=condition=Available --timeout=240s
fi

# 4. Fase 2: Cutover com corte (desligar VM legada -> ativar CiliumPodIPPool /32 + BGP -> subir VMI KubeVirt assumindo 10.60.0.50/32)
printf '[v08a] Fase 2: iniciando cutover com corte para KubeVirt VM (%s/32)...\n' "${LEGACY_IP}"
t_cutover0="$(date +%s)"
v08a_stop_legacy_kvm

outage_ok=0
for _ in $(seq 1 5); do
  if docker exec "${CLIENT}" curl -s --noproxy '*' --connect-timeout 1 --max-time 1 "http://${LEGACY_IP}:8080/" 2>/dev/null | grep -q "OK"; then
    outage_ok=$((outage_ok + 1))
  fi
done
printf '[v08a] Janela de corte verificada (VM legada desligada): %s/5 respostas durante corte (esperado 0/5)\n' "${outage_ok}"
if [[ "${outage_ok}" -ne 0 ]]; then
  printf '[v08a] ERRO: tráfego inesperado durante corte (%s/5)\n' "${outage_ok}" >&2
  exit 1
fi

docker exec "${BORDER}" vtysh \
  -c "conf t" \
  -c "ip prefix-list PL-FROM-FABRIC seq 50 permit 10.251.0.0/16 le 32" \
  -c "ip prefix-list PL-FROM-FABRIC seq 60 permit 10.252.0.0/16 le 32" \
  -c "ip prefix-list PL-FROM-FABRIC seq 70 permit 10.60.0.0/24 le 32" \
  -c "end" \
  -c "clear ip bgp 10.254.0.0 soft in" >/dev/null

v08a_run v08a_kctl apply -f "${CUTOVER_MANIFEST}"
v08a_run v08a_kctl -n "${NS_LEGACY}" wait vmi vm-legacy-cutover --for=condition=Ready --timeout=240s

vmi_node="$(v08a_kctl -n "${NS_LEGACY}" get vmi vm-legacy-cutover -o jsonpath='{.status.nodeName}')"
vmi_ip="$(v08a_kctl -n "${NS_LEGACY}" get vmi vm-legacy-cutover -o jsonpath='{.status.interfaces[0].ipAddress}')"
if [[ "${vmi_ip}" != "${LEGACY_IP}" ]]; then
  printf '[v08a] ERRO: vm-legacy-cutover recebeu IP %s em vez do IP legado %s\n' "${vmi_ip}" "${LEGACY_IP}" >&2
  exit 1
fi

t_rib_cutover=""
for _ in $(seq 1 30); do
  if docker exec "${BORDER}" vtysh -c "show ip bgp ${LEGACY_IP}/32" 2>/dev/null | grep -q "${LEGACY_IP}/32"; then
    t_rib_cutover="$(( $(date +%s) - t_cutover0 ))"
    break
  fi
  sleep 1
done

if [[ -z "${t_rib_cutover}" ]]; then
  printf '[v08a] ERRO: prefixo %s/32 não foi anunciado na %s após cutover\n' "${LEGACY_IP}" "${BORDER}" >&2
  exit 1
fi

for _ in $(seq 1 45); do
  if docker exec "${CLIENT}" curl -s --noproxy '*' --connect-timeout 1 --max-time 2 "http://${LEGACY_IP}:8080/" 2>/dev/null | grep -q "VM_LEGACY_KUBEVIRT_OK"; then
    break
  fi
  sleep 1
done
t_cutover1="$(date +%s)"
cutover_total_s="$(( t_cutover1 - t_cutover0 ))"

printf '[v08a] BGP RIB e tabela de roteamento na %s após cutover para %s/32 (node=%s, rib_em=%ss, cutover_total=%ss):\n' \
  "${BORDER}" "${LEGACY_IP}" "${vmi_node}" "${t_rib_cutover}" "${cutover_total_s}"
docker exec "${BORDER}" vtysh -c "show ip bgp ${LEGACY_IP}/32"
docker exec "${BORDER}" vtysh -c "show ip route ${LEGACY_IP}"

cutover_ok=0
cutover_sample=""
for _ in $(seq 1 30); do
  out=""
  for _ in 1 2 3; do
    out="$(docker exec "${CLIENT}" curl -s --noproxy '*' --connect-timeout 2 --max-time 3 "http://${LEGACY_IP}:8080/" 2>/dev/null || true)"
    if [[ "${out}" == *"VM_LEGACY_KUBEVIRT_OK"* ]]; then
      break
    fi
    sleep 0.1
  done
  if [[ "${out}" == *"VM_LEGACY_KUBEVIRT_OK"* ]]; then
    cutover_ok=$((cutover_ok + 1))
    cutover_sample="${out}"
  fi
  sleep 0.05
done
printf '[v08a] Fase 2 (KubeVirt VMI pós-cutover %s -> %s:8080): %s/30 OK (amostra: %s)\n' \
  "${CLIENT}" "${LEGACY_IP}" "${cutover_ok}" "${cutover_sample}"
if [[ "${cutover_ok}" -ne 30 ]]; then
  printf '[v08a] ERRO: KubeVirt VMI pós-cutover obteve %s/30 probes\n' "${cutover_ok}" >&2
  exit 1
fi

# 5. Rollback completo para ipam.mode=kubernetes e verificação final
v08a_cleanup

ipam_post="$(v08a_kctl -n kube-system get cm cilium-config -o jsonpath='{.data.ipam}')"
pools_post="$(v08a_kctl get ciliumpodippool -o name 2>/dev/null | wc -l | tr -d '[:space:]')"
if [[ "${ipam_post}" != "kubernetes" ]] || [[ "${pools_post}" -ne 0 ]]; then
  printf '[v08a] ERRO no rollback: ipam=%s (esperado kubernetes), pools_restantes=%s (esperado 0)\n' "${ipam_post}" "${pools_post}" >&2
  exit 1
fi

v08a_run "${LABCTL_BIN}" p003-gw verify
v08a_run "${LABCTL_BIN}" k01 verify

printf 'V08A PASS (H8 CONFIRMED): legacy_kvm=%s/30 -> outage=0/5 -> kubevirt_vmi=%s/32 on %s (%s/30 OK, bgp_rib_s=%ss, cutover_total_s=%ss) + rollback ipam.mode=kubernetes verificado.\n' \
  "${legacy_ok}" "${vmi_ip}" "${vmi_node}" "${cutover_ok}" "${t_rib_cutover}" "${cutover_total_s}"
