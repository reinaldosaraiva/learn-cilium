#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p004/cilium-a/v04-ip-reuse-policy.sh — Caso V04 (C04 / Gate G01): Reuso determinístico de IP entre VMs (vm-a -> vm-b) via CiliumPodIPPool /32 único vs fromEndpoints (identidade) e controle por IP/CIDR (C05).

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
CHART="${CILIUM_CHART:-/opt/poc-k8s-fabric-studies/studies/p003/base/cilium-1.20.2.tgz}"
BASE_VALUES="${CILIUM_BASE_VALUES:-/opt/poc-k8s-fabric-studies/studies/p003/base/values-p003.yaml}"
M32_VALUES="${SCRIPT_DIR}/manifests/values-p004-m32.yaml"
NS_MAIN="p004-vm-a"
NS_REUSE="p004-vm-reuse"
SINGLE_IP="10.253.0.100"

v04_kctl() {
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

v04_run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf 'DRY: %s\n' "$*"
    return 0
  fi
  printf '[v04] + %s\n' "$*"
  "$@"
}

v04_guest_exec() {
  local ns="$1"
  local pod="$2"
  local cmd="$3"
  # shellcheck disable=SC2016
  v04_kctl -n "${ns}" exec "${pod}" -c compute -- bash -c '
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
    printf "%s; echo __V04_DONE:\$?__\n" "$1" >&3
    while IFS= read -r -t 45 line <&3; do
      printf "%s\n" "${line}"
      if [[ "${line}" == *__V04_DONE:* ]]; then
        break
      fi
    done
    exec 3<&- 3>&-
  ' _ "${cmd}"
}

v04_spawn_reuse_vm() {
  local vm_name="$1"
  local app_label="$2"
  v04_kctl -n "${NS_REUSE}" apply -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${vm_name}
  namespace: ${NS_REUSE}
  labels:
    app: ${app_label}
    kubevirt.io/domain: ${vm_name}
    study: P004
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        app: ${app_label}
        kubevirt.io/domain: ${vm_name}
        study: P004
      annotations:
        ipam.cilium.io/ip-pool: p004-single-ip
    spec:
      nodeSelector:
        kubernetes.io/hostname: p003-gw-worker
      domain:
        cpu:
          cores: 1
        resources:
          requests:
            memory: 192Mi
        devices:
          autoattachSerialConsole: true
          logSerialConsole: true
          disks:
            - name: containerdisk
              disk:
                bus: virtio
            - name: cloudinitdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: containerdisk
          containerDisk:
            image: quay.io/kubevirt/cirros-container-disk-demo:v1.9.0
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #!/bin/sh
              ip link set eth0 up
              if ! ip -4 addr show dev eth0 | grep -q '10\.0\.2\.'; then
                udhcpc -i eth0 -n -q >/dev/null 2>&1 || true
              fi
              cat >/tmp/http8080.sh <<'INNER'
              #!/bin/sh
              rm -f /tmp/httpfifo
              mkfifo /tmp/httpfifo
              while true; do
                body="VM_OK host=\$(hostname) vm=${vm_name} app=${app_label}"
                len=\$(( \${#body} + 1 ))
                (
                  head -n 1 /tmp/httpfifo >/dev/null 2>&1
                  printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s\n' "\$len" "\$body"
                ) | nc -l -p 8080 >/tmp/httpfifo 2>/dev/null || sleep 0.1
              done
              INNER
              chmod +x /tmp/http8080.sh
              nohup /tmp/http8080.sh >/dev/null 2>&1 &
              cat >/tmp/cmd7777.sh <<'INNER2'
              #!/bin/sh
              rm -f /tmp/cmdfifo
              mkfifo /tmp/cmdfifo
              while true; do
                (
                  cmd_line="\$(head -n 1 /tmp/cmdfifo 2>/dev/null)"
                  if [ -n "\$cmd_line" ]; then
                    sh -c "\$cmd_line" 2>&1
                  fi
                ) | nc -l -p 7777 >/tmp/cmdfifo 2>/dev/null || sleep 0.1
              done
              INNER2
              chmod +x /tmp/cmd7777.sh
              nohup /tmp/cmd7777.sh >/dev/null 2>&1 &
EOF
}

if [[ "${DRY_RUN}" == "1" ]]; then
  v04_run v04_kctl get ns kube-system -o jsonpath='{.metadata.uid}'
  v04_run k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}'
  v04_run docker inspect -f '{{.State.Status}}' "${P003_OS_CONTAINER}"
  v04_run v04_kctl apply -f "${SCRIPT_DIR}/manifests/05-v04-ip-reuse.yaml"
  printf 'DRY: helm upgrade cilium multi-pool (%s) + rollout restart cilium-operator & ds/cilium\n' "${M32_VALUES}"
  printf 'DRY: spawn vm-a-reuse (app=p004-vm-a) in %s -> receives %s/32 -> verify 30/30 ALLOW to target-srv under fromEndpoints(app=p004-vm-a)\n' "${NS_REUSE}" "${SINGLE_IP}"
  printf 'DRY: delete vm-a-reuse, spawn vm-b-reuse (app=p004-vm-b) in %s -> receives EXACT SAME IP %s/32\n' "${NS_REUSE}" "${SINGLE_IP}"
  printf 'DRY: verify vm-b-reuse (%s) -> target-srv is 0/30 DENIED under fromEndpoints(app=p004-vm-a) with Policy denied in cilium-dbg monitor\n' "${SINGLE_IP}"
  printf 'DRY: verify CNP fromCIDR (%s/32) vs IP-anchored ACL (-s %s/32 on target-srv:8080: vm-b-reuse 30/30 ALLOW vs client-a 0/30 DENY)\n' "${SINGLE_IP}" "${SINGLE_IP}"
  printf 'DRY: rollback to ipam.mode=kubernetes (%s) and restore baseline workloads\n' "${BASE_VALUES}"
  printf 'V04 DRY-RUN OK\n'
  exit 0
fi

# 1. Validar UIDs de p003-gw e k01, estado exited de p003-os e gate de memória R3
uid_p003="$(v04_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_p003}" != "${P003_EXPECTED_UID}" ]]; then
  printf '[v04] ERRO: UID de p003-gw (%s) difere do esperado (%s)\n' "${uid_p003}" "${P003_EXPECTED_UID}" >&2
  exit 1
fi
uid_k01="$(k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_k01}" != "${K01_EXPECTED_UID}" ]]; then
  printf '[v04] ERRO: UID de k01 (%s) difere do esperado (%s)\n' "${uid_k01}" "${K01_EXPECTED_UID}" >&2
  exit 1
fi
os_state="$(docker inspect -f '{{.State.Status}}' "${P003_OS_CONTAINER}" 2>/dev/null || true)"
if [[ "${os_state}" != "${P003_OS_EXPECTED_STATE}" ]]; then
  printf '[v04] ERRO: estado de %s (%s) difere do esperado (%s)\n' "${P003_OS_CONTAINER}" "${os_state:-ausente}" "${P003_OS_EXPECTED_STATE}" >&2
  exit 1
fi
mem_avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
if [[ "${mem_avail_kb}" -lt 4194304 ]]; then
  printf '[v04] ERRO (R3): MemAvailable (%s kB) abaixo de 4 GiB\n' "${mem_avail_kb}" >&2
  exit 1
fi

api_ip="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' p003-gw-control-plane)"

v04_target_iptables() {
  if v04_kctl -n "${NS_MAIN}" exec target-srv -- iptables "$@" >/dev/null 2>&1; then
    return 0
  fi
  local t_node t_cid t_pid
  t_node="$(v04_kctl -n "${NS_MAIN}" get pod target-srv -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  t_cid="$(v04_kctl -n "${NS_MAIN}" get pod target-srv -o jsonpath='{.status.containerStatuses[0].containerID}' 2>/dev/null | sed 's#^containerd://##' || true)"
  if [[ -n "${t_node}" ]] && [[ -n "${t_cid}" ]]; then
    t_pid="$(docker exec "${t_node}" crictl inspect "${t_cid}" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["pid"])' 2>/dev/null || true)"
    if [[ -n "${t_pid}" ]]; then
      docker exec "${t_node}" nsenter -t "${t_pid}" -n iptables "$@" >/dev/null 2>&1
      return $?
    fi
  fi
  return 1
}

V04_CLEANUP_DONE=0
v04_cleanup() {
  if [[ "${V04_CLEANUP_DONE}" == "1" ]]; then
    return 0
  fi
  V04_CLEANUP_DONE=1
  printf '[v04] Executando cleanup/rollback de V04...\n'
  v04_target_iptables -F INPUT || true
  v04_kctl -n "${NS_MAIN}" delete cnp v04-target-allow-vma-identity v04-target-allow-ip-cidr --ignore-not-found >/dev/null 2>&1 || true
  v04_kctl -n "${NS_REUSE}" delete vm --all --ignore-not-found >/dev/null 2>&1 || true
  v04_kctl -n "${NS_REUSE}" delete pods --all --ignore-not-found --grace-period=0 --force >/dev/null 2>&1 || true
  v04_run v04_kctl delete ns "${NS_REUSE}" --ignore-not-found --timeout=120s || true
  v04_run v04_kctl delete ciliumpodippool p004-single-ip --ignore-not-found || true

  if [[ "${V04_KEEP_MULTIPOOL:-0}" != "1" ]]; then
    v04_run v04_kctl delete ciliumpodippool p004-vm default --ignore-not-found || true
    v04_run helm upgrade cilium "${CHART}" \
      --kubeconfig "${P003_KUBECONFIG}" --kube-context "${P003_CONTEXT}" \
      -n kube-system -f "${BASE_VALUES}" --set "k8sServiceHost=${api_ip}" >/dev/null
    v04_run v04_kctl -n kube-system rollout restart deploy/cilium-operator ds/cilium
    v04_run v04_kctl -n kube-system rollout status deploy/cilium-operator --timeout=240s
    v04_run v04_kctl -n kube-system rollout status ds/cilium --timeout=240s
    v04_kctl -n kube-system delete pods -l k8s-app=kube-dns --grace-period=0 --force >/dev/null 2>&1 || true
    v04_run v04_kctl -n kube-system rollout status deploy/coredns --timeout=180s

    v04_kctl -n kubevirt delete pods --all --grace-period=0 --force >/dev/null 2>&1 || true
    v04_run v04_kctl -n kubevirt rollout status deploy/virt-operator deploy/virt-api deploy/virt-controller ds/virt-handler --timeout=240s
    v04_run v04_kctl -n kubevirt wait kubevirt kubevirt --for=condition=Available --timeout=240s

    v04_kctl -n p003-gateway delete pods --all --grace-period=0 --force >/dev/null 2>&1 || true
    v04_run v04_kctl -n p003-gateway rollout status deploy/http-echo deploy/p003-dns deploy/tcp-echo --timeout=180s

    v04_kctl -n "${NS_MAIN}" delete pod target-srv client-a client-b --ignore-not-found --grace-period=0 --force >/dev/null 2>&1 || true
    v04_run v04_kctl apply -f "${SCRIPT_DIR}/manifests/01-namespace-clients.yaml"
    v04_run v04_kctl -n "${NS_MAIN}" patch vm vm-a --type=merge -p '{"spec":{"runStrategy":"Always"}}'
    v04_run v04_kctl -n "${NS_MAIN}" wait pod target-srv client-a client-b --for=condition=Ready --timeout=180s
    v04_run v04_kctl -n "${NS_MAIN}" wait vmi vm-a --for=condition=Ready --timeout=240s
    local vm_ip_restored
    vm_ip_restored="$(v04_kctl -n "${NS_MAIN}" get vmi vm-a -o jsonpath='{.status.interfaces[0].ipAddress}')"
    for _ in $(seq 1 45); do
      if v04_kctl -n "${NS_MAIN}" exec client-a -- curl -s --max-time 2 "http://${vm_ip_restored}:8080/" 2>/dev/null | grep -q "VM_OK"; then
        break
      fi
      sleep 2
    done
  fi
}
trap v04_cleanup EXIT

# 2. Aplicar CiliumPodIPPools (default, p004-vm, p004-single-ip 10.253.0.100/32) + CNP v04-target-allow-vma-identity e ativar multi-pool
# Pausar vm-a em p004-vm-a durante V04 para economizar RAM e evitar duas VMs simultâneas desnecessárias
v04_kctl -n "${NS_MAIN}" patch vm vm-a --type=merge -p '{"spec":{"runStrategy":"Halted"}}' >/dev/null 2>&1 || true
for _ in $(seq 1 45); do
  if [[ -z "$(v04_kctl -n "${NS_MAIN}" get pods -l kubevirt.io=virt-launcher,kubevirt.io/domain=vm-a -o name 2>/dev/null)" ]]; then
    break
  fi
  sleep 1
done
v04_run v04_kctl apply -f "${SCRIPT_DIR}/manifests/05-v04-ip-reuse.yaml"

v04_run helm upgrade cilium "${CHART}" \
  --kubeconfig "${P003_KUBECONFIG}" --kube-context "${P003_CONTEXT}" \
  -n kube-system -f "${M32_VALUES}" --set "k8sServiceHost=${api_ip}" >/dev/null
v04_run v04_kctl -n kube-system rollout restart deploy/cilium-operator ds/cilium
v04_run v04_kctl -n kube-system rollout status deploy/cilium-operator --timeout=240s
v04_run v04_kctl -n kube-system rollout status ds/cilium --timeout=240s
v04_kctl -n kube-system delete pods -l k8s-app=kube-dns --grace-period=0 --force >/dev/null 2>&1 || true
v04_run v04_kctl -n kube-system rollout status deploy/coredns --timeout=180s

# Recriar pods do control-plane KubeVirt e virt-handler para adquirirem IPs e rotas lxc do pool default Multi-Pool (D-S010-4)
v04_kctl -n kubevirt delete pods --all --grace-period=0 --force >/dev/null 2>&1 || true
v04_run v04_kctl -n kubevirt rollout status deploy/virt-operator deploy/virt-api deploy/virt-controller ds/virt-handler --timeout=240s
v04_run v04_kctl -n kubevirt wait kubevirt kubevirt --for=condition=Available --timeout=240s

# Recriar target-srv e client-a em p004-vm-a para adquirirem IPs do pool Multi-Pool (D-S010-4)
v04_kctl -n "${NS_MAIN}" delete pod target-srv client-a client-b --ignore-not-found --grace-period=0 --force >/dev/null 2>&1 || true
v04_run v04_kctl apply -f "${SCRIPT_DIR}/manifests/01-namespace-clients.yaml"
v04_run v04_kctl -n "${NS_MAIN}" wait pod target-srv client-a --for=condition=Ready --timeout=180s
target_ip="$(v04_kctl -n "${NS_MAIN}" get pod target-srv -o jsonpath='{.status.podIP}')"
target_node="$(v04_kctl -n "${NS_MAIN}" get pod target-srv -o jsonpath='{.spec.nodeName}')"
target_cep_id="$(v04_kctl -n "${NS_MAIN}" get cep target-srv -o jsonpath='{.status.id}')"
cilium_target_pod="$(v04_kctl -n kube-system get pods -l k8s-app=cilium --field-selector="spec.nodeName=${target_node}" -o jsonpath='{.items[0].metadata.name}')"

# 3. Criar vm-a-reuse (app=p004-vm-a) no pool p004-single-ip (10.253.0.100/32)
v04_spawn_reuse_vm "vm-a-reuse" "p004-vm-a"
v04_run v04_kctl -n "${NS_REUSE}" wait vmi vm-a-reuse --for=condition=Ready --timeout=240s
vma_pod="$(v04_kctl -n "${NS_REUSE}" get pods -l kubevirt.io=virt-launcher,kubevirt.io/domain=vm-a-reuse --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
vma_ip="$(v04_kctl -n "${NS_REUSE}" get vmi vm-a-reuse -o jsonpath='{.status.interfaces[0].ipAddress}')"
vma_uid="$(v04_kctl -n "${NS_REUSE}" get vmi vm-a-reuse -o jsonpath='{.metadata.uid}')"
vma_sec_id="$(v04_kctl -n "${NS_REUSE}" get cep "${vma_pod}" -o jsonpath='{.status.identity.id}')"

if [[ "${vma_ip}" != "${SINGLE_IP}" ]]; then
  printf '[v04] ERRO: vm-a-reuse recebeu IP %s em vez de %s\n' "${vma_ip}" "${SINGLE_IP}" >&2
  exit 1
fi

for _ in $(seq 1 45); do
  if v04_kctl -n "${NS_MAIN}" exec client-a -- curl -s --max-time 2 "http://${vma_ip}:8080/" 2>/dev/null | grep -q "VM_OK"; then
    break
  fi
  sleep 2
done

# 4. Provar que vm-a-reuse (app=p004-vm-a, IP 10.253.0.100) alcança target-srv:8080 (30/30 ALLOW sob fromEndpoints app=p004-vm-a)
vma_allow_out="$(v04_guest_exec "${NS_REUSE}" "${vma_pod}" "i=1; ok=0; while [ \$i -le 30 ]; do if nc -w 2 ${target_ip} 8080 </dev/null >/dev/null 2>&1; then ok=\$((ok+1)); fi; i=\$((i+1)); done; echo VMA_OK=\$ok")"
vma_ok="$(awk -F= '/VMA_OK=/{print $2}' <<<"${vma_allow_out}" | tr -d '\r[:space:]')"
printf '[v04] Fase 1 (vm-a-reuse, uid=%s, ip=%s, sec_id=%s -> target-srv %s:8080): %s/30 ALLOW\n' \
  "${vma_uid}" "${vma_ip}" "${vma_sec_id}" "${target_ip}" "${vma_ok:-0}"
if [[ "${vma_ok:-0}" -ne 30 ]]; then
  printf '[v04] ERRO: vm-a-reuse obteve %s/30 (esperado 30/30)\n' "${vma_ok:-0}" >&2
  exit 1
fi

# 5. Deletar vm-a-reuse e aguardar liberação do único IP 10.253.0.100 no pool p004-single-ip
v04_run v04_kctl -n "${NS_REUSE}" delete vm vm-a-reuse --wait=true
for _ in $(seq 1 45); do
  if [[ -z "$(v04_kctl -n "${NS_REUSE}" get pods,cep -o name 2>/dev/null)" ]]; then
    break
  fi
  sleep 1
done
sleep 2

# 6. Criar vm-b-reuse (app=p004-vm-b, identidade diferente) no mesmo nó e pool p004-single-ip -> DEVE receber o MESMO IP 10.253.0.100
v04_spawn_reuse_vm "vm-b-reuse" "p004-vm-b"
v04_run v04_kctl -n "${NS_REUSE}" wait vmi vm-b-reuse --for=condition=Ready --timeout=240s
vmb_pod="$(v04_kctl -n "${NS_REUSE}" get pods -l kubevirt.io=virt-launcher,kubevirt.io/domain=vm-b-reuse --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
vmb_ip="$(v04_kctl -n "${NS_REUSE}" get vmi vm-b-reuse -o jsonpath='{.status.interfaces[0].ipAddress}')"
vmb_uid="$(v04_kctl -n "${NS_REUSE}" get vmi vm-b-reuse -o jsonpath='{.metadata.uid}')"
vmb_sec_id="$(v04_kctl -n "${NS_REUSE}" get cep "${vmb_pod}" -o jsonpath='{.status.identity.id}')"

if [[ "${vmb_ip}" != "${vma_ip}" ]]; then
  printf '[v04] ERRO: reuso determinístico falhou (vma_ip=%s != vmb_ip=%s)\n' "${vma_ip}" "${vmb_ip}" >&2
  exit 1
fi

for _ in $(seq 1 45); do
  if v04_kctl -n "${NS_MAIN}" exec client-a -- curl -s --max-time 2 "http://${vmb_ip}:8080/" 2>/dev/null | grep -q "VM_OK"; then
    break
  fi
  sleep 2
done

# 7. Provar que vm-b-reuse (MESMO IP 10.253.0.100, mas app=p004-vm-b) é NEGADA (0/30) pela CNP fromEndpoints(app=p004-vm-a)
mon_file="/tmp/v04-cilium-monitor-$$.log"
rm -f "${mon_file}"
v04_kctl -n kube-system exec "${cilium_target_pod}" -- timeout 25 cilium-dbg monitor --type drop --type policy-verdict --related-to "${target_cep_id}" >"${mon_file}" 2>&1 &
mon_pid=$!
sleep 1

vmb_deny_out="$(v04_guest_exec "${NS_REUSE}" "${vmb_pod}" "i=1; ok=0; while [ \$i -le 30 ]; do if nc -w 1 ${target_ip} 8080 </dev/null >/dev/null 2>&1; then ok=\$((ok+1)); fi; i=\$((i+1)); done; echo VMB_IDENTITY_OK=\$ok")"
wait "${mon_pid}" || true
vmb_id_ok="$(awk -F= '/VMB_IDENTITY_OK=/{print $2}' <<<"${vmb_deny_out}" | tr -d '\r[:space:]')"
drop_count="$(grep -ciE "Policy denied|verdict denied" "${mon_file}" || true)"
rm -f "${mon_file}"

printf '[v04] Fase 2 (vm-b-reuse REUSO IP=%s, uid=%s, sec_id=%s != %s sob fromEndpoints): %s/30 ALLOW (esperado 0/30, drops=%s)\n' \
  "${vmb_ip}" "${vmb_uid}" "${vmb_sec_id}" "${vma_sec_id}" "${vmb_id_ok:-0}" "${drop_count}"
if [[ "${vmb_id_ok:-0}" -ne 0 ]] || [[ "${drop_count}" -lt 1 ]]; then
  printf '[v04] ERRO: vm-b-reuse herdou autorização por identidade indevidamente (ok=%s/30, drops=%s)\n' "${vmb_id_ok:-0}" "${drop_count}" >&2
  exit 1
fi

# 8. Controle de contraste (E08 C05 — autorização ancorada em IP/CIDR 10.253.0.100/32 vs identidade):
#    Fase 3a: Em CNP Cilium pura, fromCIDR: [10.253.0.100/32] aplica-se à identidade world; endpoints intra-cluster
#             mapeados no ipcache usam sua identidade de segurança e portanto permanecem bloqueados (0/30 ALLOW).
v04_kctl -n "${NS_MAIN}" delete cnp v04-target-allow-vma-identity --ignore-not-found >/dev/null
v04_kctl -n "${NS_MAIN}" apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: v04-target-allow-ip-cidr
  namespace: ${NS_MAIN}
  labels:
    study: P004
spec:
  endpointSelector:
    matchLabels:
      app: p004-target-srv
  ingress:
    - fromCIDR:
        - ${SINGLE_IP}/32
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
EOF
sleep 2
vmb_fromcidr_out="$(v04_guest_exec "${NS_REUSE}" "${vmb_pod}" "i=1; ok=0; while [ \$i -le 10 ]; do if nc -w 1 ${target_ip} 8080 </dev/null >/dev/null 2>&1; then ok=\$((ok+1)); fi; i=\$((i+1)); done; echo VMB_FROMCIDR_OK=\$ok")"
vmb_fromcidr_ok="$(awk -F= '/VMB_FROMCIDR_OK=/{print $2}' <<<"${vmb_fromcidr_out}" | tr -d '\r[:space:]')"
printf '[v04] Fase 3a (CNP fromCIDR %s/32 intra-cluster via ipcache): vm-b-reuse=%s/10 ALLOW (semântica Cilium: fromCIDR exige identidade world)\n' \
  "${vmb_ip}" "${vmb_fromcidr_ok:-0}"
v04_kctl -n "${NS_MAIN}" delete cnp v04-target-allow-ip-cidr --ignore-not-found >/dev/null
sleep 2

#    Fase 3b: Aplicar ACL ancorada exclusivamente no endereço IP de origem (-s 10.253.0.100/32 em target-srv:8080,
#             bloqueando todas as demais origens):
#             - vm-b-reuse (10.253.0.100) HERDA 30/30 ALLOW do IP reutilizado de vm-a-reuse;
#             - client-a (IP distinto) recebe 0/30 ALLOW (provando que a ACL por IP está ativa e não em default-allow).
v04_target_iptables -F INPUT
v04_target_iptables -A INPUT -p tcp --dport 8080 -s "${SINGLE_IP}/32" -j ACCEPT
v04_target_iptables -A INPUT -p tcp --dport 8080 -j REJECT --reject-with tcp-reset

vmb_cidr_out="$(v04_guest_exec "${NS_REUSE}" "${vmb_pod}" "i=1; ok=0; while [ \$i -le 30 ]; do if nc -w 2 ${target_ip} 8080 </dev/null >/dev/null 2>&1; then ok=\$((ok+1)); fi; i=\$((i+1)); done; echo VMB_CIDR_OK=\$ok")"
vmb_cidr_ok="$(awk -F= '/VMB_CIDR_OK=/{print $2}' <<<"${vmb_cidr_out}" | tr -d '\r[:space:]')"

client_a_acl_ok=0
for _ in $(seq 1 30); do
  if v04_kctl -n "${NS_MAIN}" exec client-a -- curl -s --connect-timeout 1 --max-time 1 "http://${target_ip}:8080/healthz" >/dev/null 2>&1; then
    client_a_acl_ok=$((client_a_acl_ok + 1))
  fi
done
v04_target_iptables -F INPUT

printf '[v04] Fase 3b (ACL ancorada em IP -s %s/32 sem filtro de label): vm-b-reuse=%s/30 ALLOW (esperado 30/30), client-a(outro IP)=%s/30 ALLOW (esperado 0/30)\n' \
  "${vmb_ip}" "${vmb_cidr_ok:-0}" "${client_a_acl_ok}"
if [[ "${vmb_cidr_ok:-0}" -ne 30 ]] || [[ "${client_a_acl_ok}" -ne 0 ]]; then
  printf '[v04] ERRO: falha na Fase 3b de ACL por IP (vm-b-reuse=%s/30, client-a=%s/30)\n' "${vmb_cidr_ok:-0}" "${client_a_acl_ok}" >&2
  exit 1
fi

# 9. Limpeza de V04 e restauração a ipam.mode=kubernetes via v04_cleanup
v04_cleanup

printf 'V04 PASS: reuso determinístico do IP %s provado (vm-a uid=%s sec_id=%s -> 30/30 ALLOW; vm-b uid=%s sec_id=%s no MESMO IP %s -> 0/30 DENY sob fromEndpoints com %s drops Policy denied; CNP fromCIDR=%s/10; ACL por IP -s %s/32 -> vm-b=30/30 ALLOW vs client-a=0/30 DENY).\n' \
  "${SINGLE_IP}" "${vma_uid}" "${vma_sec_id}" "${vmb_uid}" "${vmb_sec_id}" "${vmb_ip}" "${drop_count}" "${vmb_fromcidr_ok:-0}" "${SINGLE_IP}"
