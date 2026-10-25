#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p004/cilium-a/v00-datapath-baseline.sh — Caso V00 (Gate): Viabilidade RX/TX bidirecional da VM CirrOS <-> pod http-echo (30/30) + controle negativo com VM parada (0/30).

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
NS="p004-vm-a"

v00_kctl() {
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

v00_run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf 'DRY: %s\n' "$*"
    return 0
  fi
  printf '[v00] + %s\n' "$*"
  "$@"
}

v00_read_guest_os_ip() {
  local pod="$1"
  local guest_ip=""
  for _ in $(seq 1 15); do
    guest_ip="$(v00_kctl -n "${NS}" logs "${pod}" -c guest-console-log --tail=50 2>/dev/null | awk -F= '/GUEST_OS_IP=/{print $2}' | tail -n1 | tr -d '\r[:space:]' || true)"
    if [[ -z "${guest_ip}" ]]; then
      guest_ip="$(v00_kctl -n "${NS}" logs "${pod}" -c compute --tail=50 2>/dev/null | awk -F= '/GUEST_OS_IP=/{print $2}' | tail -n1 | tr -d '\r[:space:]' || true)"
    fi
    if [[ -n "${guest_ip}" ]]; then
      break
    fi
    sleep 2
  done
  if [[ -z "${guest_ip}" ]]; then
    guest_ip="$(v00_guest_exec "${pod}" "ip -4 -o addr show dev eth0" 2>/dev/null | awk '/inet / {print $4; exit}' | tr -d '\r[:space:]' || true)"
  fi
  printf '%s\n' "${guest_ip}"
}

v00_guest_exec() {
  local pod="$1"
  local cmd="$2"
  # shellcheck disable=SC2016
  v00_kctl -n "${NS}" exec "${pod}" -c compute -- bash -c '
    connected=0
    for _ in $(seq 1 15); do
      if exec 3<>/dev/tcp/10.0.2.2/7777 2>/dev/null; then
        connected=1
        break
      fi
      sleep 0.2
    done
    if [[ "${connected}" -ne 1 ]]; then
      exit 1
    fi
    printf "%s; echo __V00_DONE:\$?__\n" "$1" >&3
    while IFS= read -r -t 45 line <&3; do
      printf "%s\n" "${line}"
      if [[ "${line}" == *__V00_DONE:* ]]; then
        break
      fi
    done
    exec 3<&- 3>&-
  ' _ "${cmd}"
}

if [[ "${DRY_RUN}" == "1" ]]; then
  v00_run v00_kctl get ns kube-system -o jsonpath='{.metadata.uid}'
  v00_run k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}'
  v00_run docker inspect -f '{{.State.Status}}' "${P003_OS_CONTAINER}"
  v00_run v00_kctl apply -f "${SCRIPT_DIR}/manifests/01-namespace-clients.yaml"
  v00_run v00_kctl apply -f "${SCRIPT_DIR}/manifests/02-vm-a.yaml"
  v00_run v00_kctl -n "${NS}" wait vmi vm-a --for=condition=Ready --timeout=240s
  v00_run v00_kctl -n "${NS}" wait pod client-a client-b target-srv --for=condition=Ready --timeout=180s
  printf 'DRY: ping 30/30 http-echo -> vm-a (podIP) and 30/30 vm-a (guest OS) -> http-echo\n'
  printf 'DRY: patch vm-a runStrategy=Halted, verify 0/30 pings (100%% loss), restore runStrategy=Always\n'
  printf 'V00 DRY-RUN OK\n'
  exit 0
fi

# 1. Validar UIDs de p003-gw e k01, estado exited de p003-os e gate de memória R3 (>= 4 GiB)
uid_p003="$(v00_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_p003}" != "${P003_EXPECTED_UID}" ]]; then
  printf '[v00] ERRO: UID de p003-gw (%s) difere do esperado (%s)\n' "${uid_p003}" "${P003_EXPECTED_UID}" >&2
  exit 1
fi
uid_k01="$(k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_k01}" != "${K01_EXPECTED_UID}" ]]; then
  printf '[v00] ERRO: UID de k01 (%s) difere do esperado (%s)\n' "${uid_k01}" "${K01_EXPECTED_UID}" >&2
  exit 1
fi
os_state="$(docker inspect -f '{{.State.Status}}' "${P003_OS_CONTAINER}" 2>/dev/null || true)"
if [[ "${os_state}" != "${P003_OS_EXPECTED_STATE}" ]]; then
  printf '[v00] ERRO: estado de %s (%s) difere do esperado (%s)\n' "${P003_OS_CONTAINER}" "${os_state:-ausente}" "${P003_OS_EXPECTED_STATE}" >&2
  exit 1
fi
mem_avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
if [[ "${mem_avail_kb}" -lt 4194304 ]]; then
  printf '[v00] ERRO (R3): MemAvailable (%s kB) abaixo de 4 GiB antes do spawn de vm-a\n' "${mem_avail_kb}" >&2
  exit 1
fi

# Permitir ICMP ping não-privilegiado nos nós do p003-gw (para o pod http-echo agnhost)
for n in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
  docker exec "${n}" sysctl -w net.ipv4.ping_group_range="0 2147483647" >/dev/null 2>&1 || true
done

# 2. Aplicar namespace, pods clientes e VirtualMachine vm-a
v00_run v00_kctl apply -f "${SCRIPT_DIR}/manifests/01-namespace-clients.yaml"
v00_run v00_kctl apply -f "${SCRIPT_DIR}/manifests/02-vm-a.yaml"
v00_run v00_kctl -n "${NS}" wait pod client-a client-b target-srv --for=condition=Ready --timeout=180s
v00_run v00_kctl -n "${NS}" wait vmi vm-a --for=condition=Ready --timeout=240s

vm_pod="$(v00_kctl -n "${NS}" get pods -l kubevirt.io=virt-launcher,kubevirt.io/domain=vm-a --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
vm_ip="$(v00_kctl -n "${NS}" get vmi vm-a -o jsonpath='{.status.interfaces[0].ipAddress}')"
vm_node="$(v00_kctl -n "${NS}" get vmi vm-a -o jsonpath='{.status.nodeName}')"
http_echo_pod="$(v00_kctl -n p003-gateway get pods -l app=http-echo --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
http_echo_ip="$(v00_kctl -n p003-gateway get pod "${http_echo_pod}" -o jsonpath='{.status.podIP}')"

# Aguardar cloud-init do guest CirrOS levantar listeners (8080, 9999, 7777) e /dev/ttyS0
for _ in $(seq 1 45); do
  if v00_kctl -n "${NS}" exec client-a -- curl -s --max-time 2 "http://${vm_ip}:8080/" 2>/dev/null | grep -q "VM_OK"; then
    break
  fi
  sleep 2
done

guest_ip="$(v00_read_guest_os_ip "${vm_pod}")"
printf '[v00] vm-a Running em %s: pod=%s, vmi_ip=%s, guest_os_ip=%s, http_echo=%s (%s)\n' \
  "${vm_node}" "${vm_pod}" "${vm_ip}" "${guest_ip:-desconhecido}" "${http_echo_pod}" "${http_echo_ip}"

# 3. Teste positivo bidirecional (30/30 pings pod http-echo -> VM e 30/30 pings VM guest OS -> pod http-echo + 30/30 HTTP 200 ao guest)
pod_to_vm_out="$(v00_kctl -n p003-gateway exec "${http_echo_pod}" -- ping -c 30 -i 0.1 -W 1 "${vm_ip}" 2>&1 || true)"
pod_to_vm_rx="$(awk -F',' '/packets transmitted/ {gsub(/[^0-9]/,"",$2); print $2}' <<<"${pod_to_vm_out}")"

vm_to_pod_out="$(v00_guest_exec "${vm_pod}" "ping -c 30 -W 1 ${http_echo_ip}" || true)"
vm_to_pod_rx="$(awk -F',' '/packets transmitted/ {gsub(/[^0-9]/,"",$2); print $2}' <<<"${vm_to_pod_out}")"

http_to_guest_ok=0
for _ in $(seq 1 30); do
  if v00_kctl -n "${NS}" exec client-a -- curl -s --max-time 2 "http://${vm_ip}:8080/" 2>/dev/null | grep -q "VM_OK"; then
    http_to_guest_ok=$((http_to_guest_ok + 1))
  fi
done

printf '[v00] Positivo: pod->VM=%s/30, VM(guest)->pod=%s/30, HTTP->guest(8080)=%s/30\n' \
  "${pod_to_vm_rx:-0}" "${vm_to_pod_rx:-0}" "${http_to_guest_ok}"

if [[ "${pod_to_vm_rx:-0}" -ne 30 ]] || [[ "${vm_to_pod_rx:-0}" -ne 30 ]] || [[ "${http_to_guest_ok}" -ne 30 ]]; then
  printf '[v00] ERRO (R1): datapath bidirecional incompleto (pod->VM=%s/30, VM->pod=%s/30, HTTP=%s/30)\n' \
    "${pod_to_vm_rx:-0}" "${vm_to_pod_rx:-0}" "${http_to_guest_ok}" >&2
  exit 1
fi

# 4. Controle negativo: parar VM (runStrategy=Halted) -> 0/30 pings pod http-echo -> VM (100% perda)
v00_run v00_kctl -n "${NS}" patch vm vm-a --type=merge -p '{"spec":{"runStrategy":"Halted"}}'
for _ in $(seq 1 60); do
  if ! v00_kctl -n "${NS}" get vmi vm-a >/dev/null 2>&1 && \
     [[ -z "$(v00_kctl -n "${NS}" get pods -l kubevirt.io=virt-launcher,kubevirt.io/domain=vm-a -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)" ]]; then
    break
  fi
  sleep 2
done

neg_out="$(v00_kctl -n p003-gateway exec "${http_echo_pod}" -- ping -c 30 -i 0.1 -W 1 "${vm_ip}" 2>&1 || true)"
neg_rx="$(awk -F',' '/packets transmitted/ {gsub(/[^0-9]/,"",$2); print $2}' <<<"${neg_out}")"
printf '[v00] Negativo (VM Halted): pod->VM(%s)=%s/30 recebidos (esperado 0/30)\n' "${vm_ip}" "${neg_rx:-0}"
if [[ "${neg_rx:-0}" -ne 0 ]]; then
  printf '[v00] ERRO: controle negativo com VM parada recebeu %s/30 respostas\n' "${neg_rx}" >&2
  exit 1
fi

# 5. Restaurar VM para runStrategy=Always e aguardar prontidão para V01..V06
v00_run v00_kctl -n "${NS}" patch vm vm-a --type=merge -p '{"spec":{"runStrategy":"Always"}}'
v00_run v00_kctl -n "${NS}" wait vmi vm-a --for=condition=Ready --timeout=240s
vm_ip_restored="$(v00_kctl -n "${NS}" get vmi vm-a -o jsonpath='{.status.interfaces[0].ipAddress}')"
for _ in $(seq 1 45); do
  if v00_kctl -n "${NS}" exec client-a -- curl -s --max-time 2 "http://${vm_ip_restored}:8080/" 2>/dev/null | grep -q "VM_OK"; then
    break
  fi
  sleep 2
done

printf 'V00 PASS: pod->VM=30/30 (0%% loss), VM(guest %s)->pod=30/30 (0%% loss), HTTP guest=30/30, negativo VM parada=0/30 (100%% loss), VM restaurada (ip=%s).\n' \
  "${guest_ip:-10.0.2.2/24}" "${vm_ip_restored}"
