#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p004/cilium-a/v01-cilium-endpoint.sh — Caso V01 (C01): VM como CiliumEndpoint (identidade por labels da VMI, IP no PodCIDR do nó e binding masquerade).

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
NS="p004-vm-a"

v01_kctl() {
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

if [[ "${DRY_RUN}" == "1" ]]; then
  printf 'DRY: v01_kctl get ns kube-system -o jsonpath={.metadata.uid}\n'
  printf 'DRY: k01_kctl get ns kube-system -o jsonpath={.metadata.uid}\n'
  printf 'DRY: docker inspect -f {{.State.Status}} %s\n' "${P003_OS_CONTAINER}"
  printf 'DRY: v01_kctl -n %s get cep -l kubevirt.io/domain=vm-a -o json\n' "${NS}"
  printf 'DRY: v01_kctl -n %s get vmi vm-a -o json\n' "${NS}"
  printf 'DRY: v01_kctl -n kube-system exec <cilium-pod> -- cilium-dbg endpoint list\n'
  printf 'V01 DRY-RUN OK\n'
  exit 0
fi

# 1. Validar UIDs de p003-gw e k01 e estado exited de p003-os
uid_p003="$(v01_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_p003}" != "${P003_EXPECTED_UID}" ]]; then
  printf '[v01] ERRO: UID de p003-gw (%s) difere do esperado (%s)\n' "${uid_p003}" "${P003_EXPECTED_UID}" >&2
  exit 1
fi
uid_k01="$(k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_k01}" != "${K01_EXPECTED_UID}" ]]; then
  printf '[v01] ERRO: UID de k01 (%s) difere do esperado (%s)\n' "${uid_k01}" "${K01_EXPECTED_UID}" >&2
  exit 1
fi
os_state="$(docker inspect -f '{{.State.Status}}' "${P003_OS_CONTAINER}" 2>/dev/null || true)"
if [[ "${os_state}" != "${P003_OS_EXPECTED_STATE}" ]]; then
  printf '[v01] ERRO: estado de %s (%s) difere do esperado (%s)\n' "${P003_OS_CONTAINER}" "${os_state:-ausente}" "${P003_OS_EXPECTED_STATE}" >&2
  exit 1
fi

# 2. Obter pod virt-launcher, VMI, CiliumEndpoint e PodCIDR do nó
vm_pod="$(v01_kctl -n "${NS}" get pods -l kubevirt.io=virt-launcher,kubevirt.io/domain=vm-a --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
pod_ip="$(v01_kctl -n "${NS}" get pod "${vm_pod}" -o jsonpath='{.status.podIP}')"
vmi_ip="$(v01_kctl -n "${NS}" get vmi vm-a -o jsonpath='{.status.interfaces[0].ipAddress}')"
vm_node="$(v01_kctl -n "${NS}" get vmi vm-a -o jsonpath='{.status.nodeName}')"
node_pod_cidr="$(v01_kctl get node "${vm_node}" -o jsonpath='{.spec.podCIDR}')"
binding_mode="$(v01_kctl -n "${NS}" get vmi vm-a -o json | python3 -c '
import json, sys
d = json.load(sys.stdin)
iface = d["spec"]["domain"]["devices"]["interfaces"][0]
for k in ("masquerade", "bridge", "passt", "binding"):
    if k in iface:
        print(k)
        break
')"

cep_info="$(v01_kctl -n "${NS}" get cep "${vm_pod}" -o json | python3 -c '
import json, sys
d = json.load(sys.stdin)
st = d.get("status", {})
ident = st.get("identity", {})
net = st.get("networking", {})
addrs = net.get("addressing", [])
ipv4 = addrs[0].get("ipv4", "") if addrs else ""
labels = ",".join(ident.get("labels", []))
print("|".join([str(st.get("id", "")), str(ident.get("id", "")), ipv4, str(st.get("state", "")), labels]))
')"

IFS='|' read -r cep_id sec_id cep_ipv4 cep_state cep_labels <<<"${cep_info}"

# 3. Verificar pertença do IP ao PodCIDR do nó (ipam.mode=kubernetes) e igualdade cep_ipv4 == pod_ip == vmi_ip
in_cidr="$(python3 - "${cep_ipv4}" "${node_pod_cidr}" <<'PY'
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
net = ipaddress.ip_network(sys.argv[2], strict=False)
print("yes" if ip in net else "no")
PY
)"

if [[ "${cep_ipv4}" != "${pod_ip}" ]] || [[ "${cep_ipv4}" != "${vmi_ip}" ]] || [[ "${in_cidr}" != "yes" ]]; then
  printf '[v01] ERRO: divergência de IP (cep=%s, pod=%s, vmi=%s, node_cidr=%s, in_cidr=%s)\n' \
    "${cep_ipv4}" "${pod_ip}" "${vmi_ip}" "${node_pod_cidr}" "${in_cidr}" >&2
  exit 1
fi

if [[ "${cep_labels}" != *"k8s:app=p004-vm-a"* ]] || [[ "${cep_labels}" != *"k8s:kubevirt.io/domain=vm-a"* ]]; then
  printf '[v01] ERRO: CiliumEndpoint não herdou labels esperadas da VMI (%s)\n' "${cep_labels}" >&2
  exit 1
fi

# 4. Consultar cilium-dbg endpoint list no nó onde vm-a está rodando e ler IP interno do guest via serial
cilium_pod="$(v01_kctl -n kube-system get pods -l k8s-app=cilium --field-selector="spec.nodeName=${vm_node}" -o jsonpath='{.items[0].metadata.name}')"
ep_line="$(v01_kctl -n kube-system exec "${cilium_pod}" -- cilium-dbg endpoint list 2>/dev/null | grep -F "${cep_ipv4}" || true)"
if [[ -z "${ep_line}" ]]; then
  printf '[v01] ERRO: IP %s não encontrado em cilium-dbg endpoint list no nó %s\n' "${cep_ipv4}" "${vm_node}" >&2
  exit 1
fi

guest_ip="$(v01_kctl -n "${NS}" logs "${vm_pod}" -c guest-console-log --tail=30 2>/dev/null | awk -F= '/GUEST_OS_IP=/{print $2}' | tail -n1 | tr -d '\r[:space:]' || true)"
if [[ -z "${guest_ip}" ]]; then
  guest_ip="$(v01_kctl -n "${NS}" logs "${vm_pod}" -c compute --tail=30 2>/dev/null | awk -F= '/GUEST_OS_IP=/{print $2}' | tail -n1 | tr -d '\r[:space:]' || true)"
fi

printf '[v01] cep=%s cep_id=%s sec_identity=%s state=%s ip=%s node=%s podCIDR=%s binding=%s guest_os_ip=%s\n' \
  "${vm_pod}" "${cep_id}" "${sec_id}" "${cep_state}" "${cep_ipv4}" "${vm_node}" "${node_pod_cidr}" "${binding_mode}" "${guest_ip:-10.0.2.2/24}"
printf '[v01] cilium-dbg: %s\n' "${ep_line}"
printf 'V01 PASS: CiliumEndpoint %s ativo (id=%s, identity=%s, ip=%s in %s, binding=%s, guest_ip=%s).\n' \
  "${vm_pod}" "${cep_id}" "${sec_id}" "${cep_ipv4}" "${node_pod_cidr}" "${binding_mode}" "${guest_ip:-10.0.2.2/24}"
