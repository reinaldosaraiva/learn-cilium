#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p004/cilium-a/00-prep-kubevirt-p003gw.sh — Higiene de RAM (R3: down de ovnk/evpn-fabric/mgc) + instalação KubeVirt v1.9.0 no p003-gw.

set -euo pipefail

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

LABCTL_BIN="${LABCTL_BIN:-/opt/poc-k8s-fabric/labctl}"
if [[ -d "${LABCTL_BIN}" ]] && [[ -x "${LABCTL_BIN}/labctl" ]]; then
  LABCTL_BIN="${LABCTL_BIN}/labctl"
fi

KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-v1.9.0}"
P003_NODES=("p003-gw-control-plane" "p003-gw-worker" "p003-gw-worker2")

p003_kctl() {
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

prep_run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf 'DRY: %s\n' "$*"
    return 0
  fi
  printf '[prep] + %s\n' "$*"
  "$@"
}

if [[ "${DRY_RUN}" == "1" ]]; then
  prep_run p003_kctl get ns kube-system -o jsonpath='{.metadata.uid}'
  prep_run k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}'
  prep_run docker inspect -f '{{.State.Status}}' "${P003_OS_CONTAINER}"
  prep_run "${LABCTL_BIN}" --dry-run ovnk down
  prep_run "${LABCTL_BIN}" --dry-run evpn-fabric down
  prep_run "${LABCTL_BIN}" --dry-run mgc down
  prep_run p003_kctl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
  prep_run p003_kctl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"
  prep_run p003_kctl -n kubevirt patch kubevirt kubevirt --type=merge -p '{"spec":{"configuration":{"developerConfiguration":{"disabledFeatureGates":["ImageVolume"]}}}}'
  prep_run p003_kctl -n kubevirt wait kubevirt kubevirt --for=condition=Available --timeout=360s
  printf '00-PREP-KUBEVIRT DRY-RUN OK\n'
  exit 0
fi

# 1. Validar UIDs dos clusters p003-gw e k01 e estado exited de p003-os (regra de escopo)
uid_p003="$(p003_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_p003}" != "${P003_EXPECTED_UID}" ]]; then
  printf '[prep] ERRO: UID de p003-gw (%s) difere do esperado (%s)\n' "${uid_p003}" "${P003_EXPECTED_UID}" >&2
  exit 1
fi
uid_k01="$(k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_k01}" != "${K01_EXPECTED_UID}" ]]; then
  printf '[prep] ERRO: UID de k01 (%s) difere do esperado (%s)\n' "${uid_k01}" "${K01_EXPECTED_UID}" >&2
  exit 1
fi
os_state="$(docker inspect -f '{{.State.Status}}' "${P003_OS_CONTAINER}" 2>/dev/null || true)"
if [[ "${os_state}" != "${P003_OS_EXPECTED_STATE}" ]]; then
  printf '[prep] ERRO: estado de %s (%s) difere do esperado (%s)\n' "${P003_OS_CONTAINER}" "${os_state:-ausente}" "${P003_OS_EXPECTED_STATE}" >&2
  exit 1
fi

# 2. Exportar imagens KubeVirt/CirrOS v1.9.0 já em cache no cluster ovnk (antes do down) para os nós do p003-gw
kv_imgs=(
  "quay.io/kubevirt/virt-operator:${KUBEVIRT_VERSION}"
  "quay.io/kubevirt/virt-api:${KUBEVIRT_VERSION}"
  "quay.io/kubevirt/virt-controller:${KUBEVIRT_VERSION}"
  "quay.io/kubevirt/virt-handler:${KUBEVIRT_VERSION}"
  "quay.io/kubevirt/virt-launcher:${KUBEVIRT_VERSION}"
  "quay.io/kubevirt/cirros-container-disk-demo:${KUBEVIRT_VERSION}"
)
for img in "${kv_imgs[@]}"; do
  src_node=""
  for cand in ovnk-control-plane ovnk-worker ovnk-worker2; do
    if docker ps --format '{{.Names}}' | grep -qx "${cand}"; then
      if docker exec "${cand}" ctr -n k8s.io images ls -q 2>/dev/null | grep -qx "${img}"; then
        src_node="${cand}"
        break
      fi
    fi
  done
  if [[ -n "${src_node}" ]]; then
    for dst_node in "${P003_NODES[@]}"; do
      if ! docker exec "${dst_node}" ctr -n k8s.io images ls -q 2>/dev/null | grep -qx "${img}"; then
        printf '[prep] Transferindo imagem em cache %s (%s -> %s)\n' "${img}" "${src_node}" "${dst_node}"
        docker exec "${src_node}" ctr -n k8s.io images export --platform linux/amd64 - "${img}" 2>/dev/null | docker exec -i "${dst_node}" ctr -n k8s.io images import --platform linux/amd64 - >/dev/null 2>&1 || true
      fi
    done
  fi
done

# 3. Limpar eventual bridge residual br-x-fabric de S004 e descer perfis ovnk, evpn-fabric e mgc para liberar RAM (R3)
if ip link show br-x-fabric >/dev/null 2>&1; then
  prep_run ip link del br-x-fabric
fi

for prof in ovnk evpn-fabric mgc; do
  prep_run "${LABCTL_BIN}" "${prof}" down
done

# 4. Gate de capacidade R3: exigir MemAvailable >= 4.0 GiB (4194304 kB) antes de instalar KubeVirt
mem_avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
mem_avail_gib="$(awk -v kb="${mem_avail_kb}" 'BEGIN {printf "%.2f", kb / 1048576.0}')"
printf '[prep] MemAvailable pós-down: %s kB (%s GiB)\n' "${mem_avail_kb}" "${mem_avail_gib}"
if [[ "${mem_avail_kb}" -lt 4194304 ]]; then
  printf '[prep] ERRO (R3): MemAvailable (%s GiB) abaixo do gate mínimo de 4.00 GiB\n' "${mem_avail_gib}" >&2
  exit 1
fi

# 5. Verificar /dev/kvm nos 3 nós do p003-gw (R2)
for n in "${P003_NODES[@]}"; do
  prep_run docker exec "${n}" bash -c "test -c /dev/kvm && test -r /dev/kvm && test -w /dev/kvm"
done

# 6. Instalar KubeVirt v1.9.0 no p003-gw e desabilitar featureGate ImageVolume (compatibilidade K8s v1.35)
prep_run p003_kctl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
prep_run p003_kctl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"
prep_run p003_kctl -n kubevirt patch kubevirt kubevirt --type=merge -p '{
  "spec": {
    "configuration": {
      "developerConfiguration": {
        "disabledFeatureGates": ["ImageVolume"]
      }
    }
  }
}'
prep_run p003_kctl -n kubevirt wait kubevirt kubevirt --for=condition=Available --timeout=360s

# 7. Re-verificar p003-gw e k01 após instalação do KubeVirt
prep_run "${LABCTL_BIN}" p003-gw verify
prep_run "${LABCTL_BIN}" k01 verify

printf '00-PREP-KUBEVIRT PASS: MemAvailable=%sGiB, KubeVirt %s Available no p003-gw (uid=%s), k01 intocado (uid=%s).\n' \
  "${mem_avail_gib}" "${KUBEVIRT_VERSION}" "${uid_p003}" "${uid_k01}"
