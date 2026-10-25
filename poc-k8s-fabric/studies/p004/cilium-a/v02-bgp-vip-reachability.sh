#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p004/cilium-a/v02-bgp-vip-reachability.sh — Caso V02 (C02): Alcance externo por VIP BGP (10.202.255.20/32) com 30/30 conexões de clab-p003-gw-fabric-client + negativo sem label (0/30).

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
VIP="10.202.255.20"
BORDER="clab-p003-gw-fabric-border1"
CLIENT="clab-p003-gw-fabric-client"

v02_kctl() {
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

v02_run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf 'DRY: %s\n' "$*"
    return 0
  fi
  printf '[v02] + %s\n' "$*"
  "$@"
}

if [[ "${DRY_RUN}" == "1" ]]; then
  v02_run v02_kctl get ns kube-system -o jsonpath='{.metadata.uid}'
  v02_run k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}'
  v02_run docker inspect -f '{{.State.Status}}' "${P003_OS_CONTAINER}"
  v02_run v02_kctl apply -f "${SCRIPT_DIR}/manifests/03-v02-bgp-vip-service.yaml"
  printf 'DRY: docker exec %s vtysh -c "show ip bgp %s/32"\n' "${BORDER}" "${VIP}"
  printf 'DRY: 30/30 HTTP 200 probes from %s (198.19.0.10) to http://%s:8080/\n' "${CLIENT}" "${VIP}"
  printf 'DRY: remove label bgp-advertise from svc/vm-a-vip, measure withdraw time on %s, verify 0/30 probes\n' "${BORDER}"
  printf 'DRY: restore label bgp-advertise=true on svc/vm-a-vip\n'
  printf 'V02 DRY-RUN OK\n'
  exit 0
fi

# 1. Validar UIDs de p003-gw e k01 e estado exited de p003-os
uid_p003="$(v02_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_p003}" != "${P003_EXPECTED_UID}" ]]; then
  printf '[v02] ERRO: UID de p003-gw (%s) difere do esperado (%s)\n' "${uid_p003}" "${P003_EXPECTED_UID}" >&2
  exit 1
fi
uid_k01="$(k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_k01}" != "${K01_EXPECTED_UID}" ]]; then
  printf '[v02] ERRO: UID de k01 (%s) difere do esperado (%s)\n' "${uid_k01}" "${K01_EXPECTED_UID}" >&2
  exit 1
fi
os_state="$(docker inspect -f '{{.State.Status}}' "${P003_OS_CONTAINER}" 2>/dev/null || true)"
if [[ "${os_state}" != "${P003_OS_EXPECTED_STATE}" ]]; then
  printf '[v02] ERRO: estado de %s (%s) difere do esperado (%s)\n' "${P003_OS_CONTAINER}" "${os_state:-ausente}" "${P003_OS_EXPECTED_STATE}" >&2
  exit 1
fi

# 2. Aplicar Service LoadBalancer vm-a-vip (10.202.255.20, bgp-advertise=true)
v02_run v02_kctl apply -f "${SCRIPT_DIR}/manifests/03-v02-bgp-vip-service.yaml"

for _ in $(seq 1 30); do
  lb_ip="$(v02_kctl -n "${NS}" get svc vm-a-vip -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [[ "${lb_ip}" == "${VIP}" ]]; then
    break
  fi
  sleep 1
done
if [[ "${lb_ip:-}" != "${VIP}" ]]; then
  printf '[v02] ERRO: LB-IPAM não alocou %s para svc/vm-a-vip (obtido: %s)\n' "${VIP}" "${lb_ip:-vazio}" >&2
  exit 1
fi

# 3. Aguardar rota /32 na border1 e verificar caminhos BGP
for _ in $(seq 1 30); do
  if docker exec "${BORDER}" vtysh -c "show ip bgp ${VIP}/32" 2>/dev/null | grep -q "${VIP}/32"; then
    break
  fi
  sleep 1
done
bgp_vip_out="$(docker exec "${BORDER}" vtysh -c "show ip bgp ${VIP}/32" 2>/dev/null || true)"
printf '[v02] Rota BGP em %s:\n%s\n' "${BORDER}" "${bgp_vip_out}"
if ! grep -q "${VIP}/32" <<<"${bgp_vip_out}"; then
  printf '[v02] ERRO: rota %s/32 ausente em %s\n' "${VIP}" "${BORDER}" >&2
  exit 1
fi

# 4. Controle positivo: 30/30 conexões de clab-p003-gw-fabric-client (198.19.0.10) para http://10.202.255.20:8080/
pos_ok=0
for _ in $(seq 1 30); do
  resp="$(docker exec "${CLIENT}" curl -s --noproxy '*' --connect-timeout 2 --max-time 4 "http://${VIP}:8080/" 2>/dev/null || true)"
  if [[ "${resp}" == *"VM_OK"* ]]; then
    pos_ok=$((pos_ok + 1))
  fi
done
printf '[v02] Positivo (%s -> %s:8080): %s/30 conexões OK\n' "${CLIENT}" "${VIP}" "${pos_ok}"
if [[ "${pos_ok}" -ne 30 ]]; then
  printf '[v02] ERRO: controle positivo obteve %s/30 (esperado 30/30)\n' "${pos_ok}" >&2
  exit 1
fi

# 5. Controle negativo: remover label bgp-advertise -> withdraw da rota /32 em border1 e 0/30 conexões
t_rm="$(date +%s)"
v02_run v02_kctl -n "${NS}" label svc vm-a-vip bgp-advertise-
t_withdraw=""
for _ in $(seq 1 30); do
  if docker exec "${BORDER}" vtysh -c "show ip bgp ${VIP}/32" 2>/dev/null | grep -q "Network not in table"; then
    t_withdraw="$(( $(date +%s) - t_rm ))"
    break
  fi
  sleep 1
done
if [[ -z "${t_withdraw}" ]]; then
  printf '[v02] ERRO: rota %s/32 não foi retirada de %s em 30s após remover bgp-advertise\n' "${VIP}" "${BORDER}" >&2
  exit 1
fi

neg_ok=0
for _ in $(seq 1 30); do
  if docker exec "${CLIENT}" curl -s --noproxy '*' --connect-timeout 1 --max-time 1 "http://${VIP}:8080/" 2>/dev/null | grep -q "VM_OK"; then
    neg_ok=$((neg_ok + 1))
  fi
done
printf '[v02] Negativo (sem bgp-advertise): withdraw_s=%ss, conexões OK=%s/30 (esperado 0/30)\n' "${t_withdraw}" "${neg_ok}"
if [[ "${neg_ok}" -ne 0 ]]; then
  printf '[v02] ERRO: controle negativo obteve %s/30 conexões após withdraw\n' "${neg_ok}" >&2
  exit 1
fi

# 6. Restaurar label bgp-advertise=true para os casos subsequentes (V05)
v02_run v02_kctl -n "${NS}" label svc vm-a-vip bgp-advertise=true --overwrite
for _ in $(seq 1 30); do
  if docker exec "${BORDER}" vtysh -c "show ip bgp ${VIP}/32" 2>/dev/null | grep -q "${VIP}/32"; then
    break
  fi
  sleep 1
done

printf 'V02 PASS: VIP %s/32 anunciada via BGP em %s, positivo=%s/30 de %s (198.19.0.10), withdraw em %ss após remoção da label, negativo=%s/30, VIP restaurada.\n' \
  "${VIP}" "${BORDER}" "${pos_ok}" "${CLIENT}" "${t_withdraw}" "${neg_ok}"
