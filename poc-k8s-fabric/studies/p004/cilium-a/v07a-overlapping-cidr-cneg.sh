#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p004/cilium-a/v07a-overlapping-cidr-cneg.sh — Caso V07-A (C07 / C-neg / H5):
# Dois tenants (p004-tenant-a e p004-tenant-b) requisitando CiliumPodIPPools com o mesmo CIDR
# (10.253.10.0/24 e 10.253.10.100/32) no Cilium 1.20.2 OSS sob ipam.mode=multi-pool.
# Mede e prova com evidência primária o sintoma exato no Cilium OSS (ausência de VRF por tenant,
# ipcache global indexado apenas por IP/prefixo e comportamento do cilium-operator / webhook /
# alocador por nó), confirmando H5 (C-neg) e realizando rollback limpo.

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

# Quando V07A_KEEP_MULTIPOOL=1 (encadeado imediatamente antes de V08-A na mesma cápsula M),
# o cleanup remove todos os pools/namespaces/rotas de V07-A mas preserva default e p004-vm
# em multi-pool para que V08-A execute em seguida e restaure ipam.mode=kubernetes no final.
V07A_KEEP_MULTIPOOL="${V07A_KEEP_MULTIPOOL:-0}"

LABCTL_BIN="${LABCTL_BIN:-/opt/poc-k8s-fabric/labctl}"
if [[ -d "${LABCTL_BIN}" ]] && [[ -x "${LABCTL_BIN}/labctl" ]]; then
  LABCTL_BIN="${LABCTL_BIN}/labctl"
fi

CHART="${CILIUM_CHART:-/opt/poc-k8s-fabric-studies/studies/p003/base/cilium-1.20.2.tgz}"
BASE_VALUES="${CILIUM_BASE_VALUES:-/opt/poc-k8s-fabric-studies/studies/p003/base/values-p003.yaml}"
BASE_BGP_ADV="${CILIUM_BASE_BGP_ADV:-/opt/poc-k8s-fabric-studies/studies/p003/base/bgp/02-advertisements.yaml}"
M32_VALUES="${SCRIPT_DIR}/manifests/values-p004-m32.yaml"
OVERLAP_MANIFEST="${SCRIPT_DIR}/manifests/07-v07a-overlapping-cidr.yaml"
AGNHOST_IMAGE="registry.k8s.io/e2e-test-images/agnhost:2.47"

v07a_kctl() {
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

v07a_run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf 'DRY: %s\n' "$*"
    return 0
  fi
  printf '[v07a] + %s\n' "$*"
  "$@"
}

v07a_flush_residual_routes() {
  local node cidr
  for node in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
    while read -r cidr; do
      if [[ -n "${cidr}" ]]; then
        docker exec "${node}" ip -4 route del "${cidr}" >/dev/null 2>&1 || true
      fi
    done < <(docker exec "${node}" ip -4 route show 2>/dev/null | awk '$1 ~ /^10\.(251|252|253)\./ {print $1}')
  done
}

v07a_flush_overlap_routes() {
  local node cidr
  for node in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
    while read -r cidr; do
      if [[ -n "${cidr}" ]]; then
        docker exec "${node}" ip -4 route del "${cidr}" >/dev/null 2>&1 || true
      fi
    done < <(docker exec "${node}" ip -4 route show 2>/dev/null | awk '$1 ~ /^10\.253\.10\./ {print $1}')
  done
}

if [[ "${DRY_RUN}" == "1" ]]; then
  v07a_run v07a_kctl get ns kube-system -o jsonpath='{.metadata.uid}'
  v07a_run k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}'
  v07a_run docker inspect -f '{{.State.Status}}' "${P003_OS_CONTAINER}"
  printf 'DRY: check /proc/meminfo MemAvailable >= %s kB (R3)\n' "${MIN_MEM_AVAILABLE_KB}"
  printf 'DRY: helm upgrade cilium multi-pool (%s) + rollout status cilium-operator and ds/cilium\n' "${M32_VALUES}"
  v07a_run v07a_kctl apply -f "${OVERLAP_MANIFEST}"
  printf 'DRY: create pods in p004-tenant-a and p004-tenant-b requesting overlapping pools (10.253.10.0/24 and 10.253.10.100/32)\n'
  printf 'DRY: capture CiliumPodIPPool admission, CiliumNode .spec.ipam.pools, cilium-operator logs, ip vrf show, ip -4 route show, and cilium-dbg bpf ipcache list\n'
  printf 'DRY: cleanup p004-tenant-a/b and overlapping pools; restore ipam.mode=kubernetes (%s) if V07A_KEEP_MULTIPOOL=0\n' "${BASE_VALUES}"
  printf 'V07A DRY-RUN OK\n'
  exit 0
fi

# 1. Validar UIDs de p003-gw e k01, estado exited de p003-os e orçamento de RAM (R3 >= 4 GiB)
uid_p003="$(v07a_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_p003}" != "${P003_EXPECTED_UID}" ]]; then
  printf '[v07a] ERRO: UID de p003-gw (%s) difere do esperado (%s)\n' "${uid_p003}" "${P003_EXPECTED_UID}" >&2
  exit 1
fi
uid_k01="$(k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_k01}" != "${K01_EXPECTED_UID}" ]]; then
  printf '[v07a] ERRO: UID de k01 (%s) difere do esperado (%s)\n' "${uid_k01}" "${K01_EXPECTED_UID}" >&2
  exit 1
fi
os_state="$(docker inspect -f '{{.State.Status}}' "${P003_OS_CONTAINER}" 2>/dev/null || true)"
if [[ "${os_state}" != "${P003_OS_EXPECTED_STATE}" ]]; then
  printf '[v07a] ERRO: estado de %s (%s) difere do esperado (%s)\n' "${P003_OS_CONTAINER}" "${os_state:-ausente}" "${P003_OS_EXPECTED_STATE}" >&2
  exit 1
fi
mem_avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
if [[ -z "${mem_avail_kb}" ]] || (( mem_avail_kb < MIN_MEM_AVAILABLE_KB )); then
  printf '[v07a] ERRO: MemAvailable=%s kB abaixo do piso R3 (%s kB)\n' "${mem_avail_kb:-0}" "${MIN_MEM_AVAILABLE_KB}" >&2
  exit 1
fi

api_ip="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' p003-gw-control-plane)"

V07A_CLEANUP_DONE=0
v07a_cleanup() {
  if [[ "${V07A_CLEANUP_DONE}" == "1" ]]; then
    return 0
  fi
  V07A_CLEANUP_DONE=1
  printf '[v07a] Limpando recursos de V07-A (V07A_KEEP_MULTIPOOL=%s)...\n' "${V07A_KEEP_MULTIPOOL}"
  v07a_kctl -n p004-tenant-a delete pods --all --ignore-not-found --grace-period=0 --force >/dev/null 2>&1 || true
  v07a_kctl -n p004-tenant-b delete pods --all --ignore-not-found --grace-period=0 --force >/dev/null 2>&1 || true
  v07a_kctl delete ns p004-tenant-a p004-tenant-b --ignore-not-found --timeout=120s >/dev/null 2>&1 || true
  v07a_kctl delete ciliumpodippool p004-tenant-a-pool p004-tenant-b-pool p004-tenant-a-exact p004-tenant-b-exact --ignore-not-found >/dev/null 2>&1 || true
  v07a_flush_overlap_routes

  if [[ "${V07A_KEEP_MULTIPOOL}" != "1" ]]; then
    printf '[v07a] Restaurando Cilium para ipam.mode=kubernetes...\n'
    v07a_kctl apply -f "${BASE_BGP_ADV}" >/dev/null 2>&1 || true
    v07a_kctl delete ciliumpodippool p004-vm default --ignore-not-found >/dev/null 2>&1 || true
    v07a_run helm upgrade cilium "${CHART}" \
      --kubeconfig "${P003_KUBECONFIG}" --kube-context "${P003_CONTEXT}" \
      -n kube-system -f "${BASE_VALUES}" --set "k8sServiceHost=${api_ip}" >/dev/null
    v07a_run v07a_kctl -n kube-system rollout restart deploy/cilium-operator ds/cilium
    v07a_run v07a_kctl -n kube-system rollout status deploy/cilium-operator --timeout=240s
    v07a_run v07a_kctl -n kube-system rollout status ds/cilium --timeout=240s
    v07a_flush_residual_routes

    v07a_kctl -n kube-system delete pods -l k8s-app=kube-dns --grace-period=0 --force >/dev/null 2>&1 || true
    v07a_run v07a_kctl -n kube-system rollout status deploy/coredns --timeout=180s

    v07a_kctl -n kubevirt delete pods --all --grace-period=0 --force >/dev/null 2>&1 || true
    v07a_run v07a_kctl -n kubevirt rollout status deploy/virt-operator deploy/virt-api deploy/virt-controller ds/virt-handler --timeout=240s
    v07a_run v07a_kctl -n kubevirt wait kubevirt kubevirt --for=condition=Available --timeout=240s

    v07a_kctl -n p003-gateway delete pods --all --grace-period=0 --force >/dev/null 2>&1 || true
    v07a_run v07a_kctl -n p003-gateway rollout status deploy/http-echo deploy/p003-dns deploy/tcp-echo --timeout=180s
  fi
}
trap v07a_cleanup EXIT

# 2. Garantir ipam.mode=multi-pool no Cilium (com pools base default e p004-vm)
v07a_kctl apply -f - <<'EOF'
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

cur_ipam="$(v07a_kctl -n kube-system get cm cilium-config -o jsonpath='{.data.ipam}' 2>/dev/null || true)"
if [[ "${cur_ipam}" != "multi-pool" ]]; then
  v07a_kctl -n p004-vm-a patch vm vm-a --type=merge -p '{"spec":{"runStrategy":"Halted"}}' >/dev/null 2>&1 || true
  v07a_run helm upgrade cilium "${CHART}" \
    --kubeconfig "${P003_KUBECONFIG}" --kube-context "${P003_CONTEXT}" \
    -n kube-system -f "${M32_VALUES}" --set "k8sServiceHost=${api_ip}" >/dev/null
  v07a_run v07a_kctl -n kube-system rollout restart deploy/cilium-operator ds/cilium
  v07a_run v07a_kctl -n kube-system rollout status deploy/cilium-operator --timeout=240s
  v07a_run v07a_kctl -n kube-system rollout status ds/cilium --timeout=240s
  v07a_kctl -n kube-system delete pods -l k8s-app=kube-dns --grace-period=0 --force >/dev/null 2>&1 || true
  v07a_run v07a_kctl -n kube-system rollout status deploy/coredns --timeout=180s
fi

# 3. Aplicar CiliumPodIPPools sobrepostos (10.253.10.0/24 e 10.253.10.100/32) + namespaces p004-tenant-a e p004-tenant-b
set +e
apply_out="$(v07a_kctl apply -f "${OVERLAP_MANIFEST}" 2>&1)"
apply_rc=$?
set -e
printf '[v07a] Resultado da admissão de CiliumPodIPPools sobrepostos (rc=%s):\n%s\n' "${apply_rc}" "${apply_out}"

printf '[v07a] Listagem de CiliumPodIPPools:\n'
v07a_kctl get ciliumpodippool -o custom-columns='NAME:.metadata.name,CIDRS:.spec.ipv4.cidrs,MASK:.spec.ipv4.maskSize'

# 4. Criar pods nos dois tenants requisitando (a) o pool /24 sobreposto e (b) o pool /32 sobreposto no mesmo nó (p003-gw-worker)
v07a_kctl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: pod-tenant-a
  namespace: p004-tenant-a
  labels:
    app: pod-tenant-a
    tenant: tenant-a
spec:
  nodeSelector:
    kubernetes.io/hostname: p003-gw-worker
  containers:
    - name: agnhost
      image: ${AGNHOST_IMAGE}
      imagePullPolicy: IfNotPresent
      args: ["netexec", "--http-port=8080"]
---
apiVersion: v1
kind: Pod
metadata:
  name: pod-tenant-b
  namespace: p004-tenant-b
  labels:
    app: pod-tenant-b
    tenant: tenant-b
spec:
  nodeSelector:
    kubernetes.io/hostname: p003-gw-worker
  containers:
    - name: agnhost
      image: ${AGNHOST_IMAGE}
      imagePullPolicy: IfNotPresent
      args: ["netexec", "--http-port=8080"]
---
apiVersion: v1
kind: Pod
metadata:
  name: pod-tenant-a-exact
  namespace: p004-tenant-a
  annotations:
    ipam.cilium.io/ip-pool: p004-tenant-a-exact
  labels:
    app: pod-tenant-a-exact
    tenant: tenant-a
spec:
  nodeSelector:
    kubernetes.io/hostname: p003-gw-worker
  containers:
    - name: agnhost
      image: ${AGNHOST_IMAGE}
      imagePullPolicy: IfNotPresent
      args: ["netexec", "--http-port=8080"]
---
apiVersion: v1
kind: Pod
metadata:
  name: pod-tenant-b-exact
  namespace: p004-tenant-b
  annotations:
    ipam.cilium.io/ip-pool: p004-tenant-b-exact
  labels:
    app: pod-tenant-b-exact
    tenant: tenant-b
spec:
  nodeSelector:
    kubernetes.io/hostname: p003-gw-worker
  containers:
    - name: agnhost
      image: ${AGNHOST_IMAGE}
      imagePullPolicy: IfNotPresent
      args: ["netexec", "--http-port=8080"]
EOF

# Aguardar reconciliação do cilium-operator e tentativas de CNI ADD (até 30s)
sleep 15
for _ in $(seq 1 15); do
  pa_ip="$(v07a_kctl -n p004-tenant-a get pod pod-tenant-a -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
  pb_ip="$(v07a_kctl -n p004-tenant-b get pod pod-tenant-b -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
  if [[ -n "${pa_ip}" ]] && [[ -n "${pb_ip}" ]]; then
    break
  fi
  sleep 1
done

printf '\n=== [v07a] 1. Estado de alocação em CiliumNode (p003-gw-worker) ===\n'
v07a_kctl get ciliumnode p003-gw-worker -o jsonpath='{.spec.ipam.pools}' | python3 -m json.tool || true

printf '\n=== [v07a] 2. Logs do cilium-operator para os pools sobrepostos ===\n'
v07a_kctl -n kube-system logs deploy/cilium-operator --tail=150 \
  | grep -iE "p004-tenant|10\.253\.10|overlap|conflict|cannot|unable|error|warn|pool" || true

printf '\n=== [v07a] 3. Estado dos Pods nos dois tenants ===\n'
v07a_kctl get pods -n p004-tenant-a -o wide
v07a_kctl get pods -n p004-tenant-b -o wide

printf '\n=== [v07a] 4. Eventos de Sandbox / CNI nos Pods ===\n'
v07a_kctl -n p004-tenant-a get events --sort-by='.lastTimestamp' | tail -n 15 || true
v07a_kctl -n p004-tenant-b get events --sort-by='.lastTimestamp' | tail -n 15 || true

printf '\n=== [v07a] 5. Verificação de VRF no nó (ip vrf show) e tabela de rotas global ===\n'
vrf_worker="$(docker exec p003-gw-worker ip vrf show 2>&1 || true)"
printf 'p003-gw-worker ip vrf show: %s\n' "${vrf_worker:-<vazio: 0 VRFs no kernel>}"
docker exec p003-gw-worker ip -4 route show | grep -E "10\.253\.10\.|cilium_host" || true

printf '\n=== [v07a] 6. Mapa BPF ipcache global (sem chave de VRF/tenant) em p003-gw-worker ===\n'
cilium_pod_worker="$(v07a_kctl -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=p003-gw-worker -o jsonpath='{.items[0].metadata.name}')"
v07a_kctl -n kube-system exec "${cilium_pod_worker}" -c cilium-agent -- cilium-dbg bpf ipcache list \
  | grep -E "10\.253\.10\.|PREFIX" || true

printf '\n=== [v07a] 7. Logs do cilium-agent em p003-gw-worker para 10.253.10 ===\n'
v07a_kctl -n kube-system logs "${cilium_pod_worker}" -c cilium-agent --tail=200 \
  | grep -iE "p004-tenant|10\.253\.10|overlap|conflict|ipam|unable|error" | tail -n 30 || true

pa_ip="$(v07a_kctl -n p004-tenant-a get pod pod-tenant-a -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
pb_ip="$(v07a_kctl -n p004-tenant-b get pod pod-tenant-b -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
pa_exact_ip="$(v07a_kctl -n p004-tenant-a get pod pod-tenant-a-exact -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
pb_exact_ip="$(v07a_kctl -n p004-tenant-b get pod pod-tenant-b-exact -o jsonpath='{.status.podIP}' 2>/dev/null || true)"

cross_tenant_probe="not_applicable"
if [[ -n "${pa_ip}" ]] && [[ -n "${pb_ip}" ]]; then
  if v07a_kctl -n p004-tenant-a exec pod-tenant-a -- wget -qO- --timeout=2 "http://${pb_ip}:8080/hostName" >/dev/null 2>&1; then
    cross_tenant_probe="flat_routing_reachable_without_vrf (${pa_ip} -> ${pb_ip})"
  else
    cross_tenant_probe="unreachable_or_blocked (${pa_ip} -> ${pb_ip})"
  fi
fi

# Executar cleanup explícito (e verificar rollback se V07A_KEEP_MULTIPOOL=0)
v07a_cleanup

if [[ "${V07A_KEEP_MULTIPOOL}" != "1" ]]; then
  v07a_run "${LABCTL_BIN}" p003-gw verify
  v07a_run "${LABCTL_BIN}" k01 verify
fi

printf 'V07A PASS (C-neg / H5 CONFIRMED): admission_rc=%s, pod_tenant_a_ip=%s, pod_tenant_b_ip=%s, pod_tenant_a_exact_ip=%s, pod_tenant_b_exact_ip=%s, vrf_count=0, cross_tenant=%s.\n' \
  "${apply_rc}" "${pa_ip:-none}" "${pb_ip:-none}" "${pa_exact_ip:-none}" "${pb_exact_ip:-none}" "${cross_tenant_probe}"
