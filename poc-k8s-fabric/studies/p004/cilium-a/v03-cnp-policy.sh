#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p004/cilium-a/v03-cnp-policy.sh — Caso V03 (C03): CiliumNetworkPolicy por label na VM (client-a 30/30 PERMIT, client-b 0/30 DENY com Policy denied no cilium-dbg monitor).

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

v03_kctl() {
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

v03_run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf 'DRY: %s\n' "$*"
    return 0
  fi
  printf '[v03] + %s\n' "$*"
  "$@"
}

if [[ "${DRY_RUN}" == "1" ]]; then
  v03_run v03_kctl get ns kube-system -o jsonpath='{.metadata.uid}'
  v03_run k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}'
  v03_run docker inspect -f '{{.State.Status}}' "${P003_OS_CONTAINER}"
  v03_run v03_kctl apply -f "${SCRIPT_DIR}/manifests/04-v03-cnp.yaml"
  printf 'DRY: test client-a -> vm-a:8080 (30/30 PERMIT)\n'
  printf 'DRY: test client-b -> vm-a:8080 (0/30 DENY) + capture Policy denied in cilium-dbg monitor\n'
  v03_run v03_kctl delete -f "${SCRIPT_DIR}/manifests/04-v03-cnp.yaml" --ignore-not-found
  printf 'V03 DRY-RUN OK\n'
  exit 0
fi

# 1. Validar UIDs de p003-gw e k01 e estado exited de p003-os
uid_p003="$(v03_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_p003}" != "${P003_EXPECTED_UID}" ]]; then
  printf '[v03] ERRO: UID de p003-gw (%s) difere do esperado (%s)\n' "${uid_p003}" "${P003_EXPECTED_UID}" >&2
  exit 1
fi
uid_k01="$(k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_k01}" != "${K01_EXPECTED_UID}" ]]; then
  printf '[v03] ERRO: UID de k01 (%s) difere do esperado (%s)\n' "${uid_k01}" "${K01_EXPECTED_UID}" >&2
  exit 1
fi
os_state="$(docker inspect -f '{{.State.Status}}' "${P003_OS_CONTAINER}" 2>/dev/null || true)"
if [[ "${os_state}" != "${P003_OS_EXPECTED_STATE}" ]]; then
  printf '[v03] ERRO: estado de %s (%s) difere do esperado (%s)\n' "${P003_OS_CONTAINER}" "${os_state:-ausente}" "${P003_OS_EXPECTED_STATE}" >&2
  exit 1
fi

vm_pod="$(v03_kctl -n "${NS}" get pods -l kubevirt.io=virt-launcher,kubevirt.io/domain=vm-a --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
vm_cep_id="$(v03_kctl -n "${NS}" get cep "${vm_pod}" -o jsonpath='{.status.id}')"
vm_ip="$(v03_kctl -n "${NS}" get vmi vm-a -o jsonpath='{.status.interfaces[0].ipAddress}')"
vm_node="$(v03_kctl -n "${NS}" get vmi vm-a -o jsonpath='{.status.nodeName}')"
cilium_pod="$(v03_kctl -n kube-system get pods -l k8s-app=cilium --field-selector="spec.nodeName=${vm_node}" -o jsonpath='{.items[0].metadata.name}')"

# 2. Aplicar CiliumNetworkPolicy v03-allow-only-client-a
v03_run v03_kctl apply -f "${SCRIPT_DIR}/manifests/04-v03-cnp.yaml"
sleep 3

# 3. Controle positivo: client-a (app=p004-client-a) -> vm-a:8080 (30/30 PERMIT)
a_ok=0
for _ in $(seq 1 30); do
  if v03_kctl -n "${NS}" exec client-a -- curl -s --connect-timeout 2 --max-time 3 "http://${vm_ip}:8080/" 2>/dev/null | grep -q "VM_OK"; then
    a_ok=$((a_ok + 1))
  fi
done
printf '[v03] client-a -> vm-a (%s:8080): %s/30 PERMIT\n' "${vm_ip}" "${a_ok}"
if [[ "${a_ok}" -ne 30 ]]; then
  printf '[v03] ERRO: client-a obteve %s/30 (esperado 30/30)\n' "${a_ok}" >&2
  exit 1
fi

# 4. Controle negativo: client-b (app=p004-client-b) -> vm-a:8080 (0/30 DENY) + captura de drop no cilium-dbg monitor filtrado por --related-to
mon_file="/tmp/v03-cilium-monitor-$$.log"
rm -f "${mon_file}"
v03_kctl -n kube-system exec "${cilium_pod}" -- timeout 20 cilium-dbg monitor --type drop --type policy-verdict --related-to "${vm_cep_id}" >"${mon_file}" 2>&1 &
mon_pid=$!
sleep 1

b_ok=0
for _ in $(seq 1 30); do
  if v03_kctl -n "${NS}" exec client-b -- curl -s --connect-timeout 1 --max-time 1 "http://${vm_ip}:8080/" 2>/dev/null | grep -q "VM_OK"; then
    b_ok=$((b_ok + 1))
  fi
done
wait "${mon_pid}" || true

drop_lines="$(grep -iE "Policy denied|verdict denied" "${mon_file}" || true)"
drop_count="$(grep -ciE "Policy denied|verdict denied" "${mon_file}" || true)"
printf '[v03] client-b -> vm-a (%s:8080): %s/30 PERMIT (esperado 0/30), drops Policy denied capturados=%s\n' \
  "${vm_ip}" "${b_ok}" "${drop_count}"
printf '[v03] Amostra cilium-dbg monitor:\n%s\n' "$(head -n 5 <<<"${drop_lines}")"
rm -f "${mon_file}"

if [[ "${b_ok}" -ne 0 ]] || [[ "${drop_count}" -lt 1 ]]; then
  printf '[v03] ERRO: falha no controle negativo (b_ok=%s/30, drop_count=%s)\n' "${b_ok}" "${drop_count}" >&2
  exit 1
fi

# 5. Rollback da CNP de V03 e validação de retorno de alcance para client-b
v03_run v03_kctl delete -f "${SCRIPT_DIR}/manifests/04-v03-cnp.yaml" --ignore-not-found
sleep 2
b_post=0
for _ in $(seq 1 5); do
  if v03_kctl -n "${NS}" exec client-b -- curl -s --connect-timeout 2 --max-time 3 "http://${vm_ip}:8080/" 2>/dev/null | grep -q "VM_OK"; then
    b_post=$((b_post + 1))
  fi
done
if [[ "${b_post}" -ne 5 ]]; then
  printf '[v03] ERRO: pós-rollback client-b obteve %s/5\n' "${b_post}" >&2
  exit 1
fi

printf 'V03 PASS: CNP por label em vm-a permitiu client-a=30/30, bloqueou client-b=0/30 (Policy denied=%s eventos no cilium-dbg monitor), rollback 5/5 OK.\n' \
  "${drop_count}"
