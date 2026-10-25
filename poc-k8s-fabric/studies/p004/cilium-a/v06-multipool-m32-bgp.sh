#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p004/cilium-a/v06-multipool-m32-bgp.sh — Caso V06 (C06 / H4): Multi-Pool /32 por VM + anúncio BGP na border1 + Live Migration + Rollback limpo para ipam.mode=kubernetes.

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

LABCTL_BIN="${LABCTL_BIN:-/opt/poc-k8s-fabric/labctl}"
if [[ -d "${LABCTL_BIN}" ]] && [[ -x "${LABCTL_BIN}/labctl" ]]; then
  LABCTL_BIN="${LABCTL_BIN}/labctl"
fi

CHART="${CILIUM_CHART:-/opt/poc-k8s-fabric-studies/studies/p003/base/cilium-1.20.2.tgz}"
BASE_VALUES="${CILIUM_BASE_VALUES:-/opt/poc-k8s-fabric-studies/studies/p003/base/values-p003.yaml}"
BASE_BGP_ADV="${CILIUM_BASE_BGP_ADV:-/opt/poc-k8s-fabric-studies/studies/p003/base/bgp/02-advertisements.yaml}"
M32_VALUES="${SCRIPT_DIR}/manifests/values-p004-m32.yaml"
NS="p004-vm-a"
VIP="10.202.255.20"
BORDER="clab-p003-gw-fabric-border1"
CLIENT="clab-p003-gw-fabric-client"

v06_kctl() {
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

v06_run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf 'DRY: %s\n' "$*"
    return 0
  fi
  printf '[v06] + %s\n' "$*"
  "$@"
}

if [[ "${DRY_RUN}" == "1" ]]; then
  v06_run v06_kctl get ns kube-system -o jsonpath='{.metadata.uid}'
  v06_run k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}'
  v06_run docker inspect -f '{{.State.Status}}' "${P003_OS_CONTAINER}"
  v06_run v06_kctl apply -f "${SCRIPT_DIR}/manifests/06-v06-multipool.yaml"
  printf 'DRY: configure PL-FROM-FABRIC seq 50/60 on %s (10.251.0.0/16, 10.252.0.0/16 le 32)\n' "${BORDER}"
  printf 'DRY: helm upgrade cilium multi-pool (%s) + rollout restart deploy/cilium-operator ds/cilium\n' "${M32_VALUES}"
  printf 'DRY: recreate vm-a in %s (pool p004-vm maskSize 32) -> verify /32 BGP route on %s and 30/30 probes from %s\n' "${NS}" "${BORDER}" "${CLIENT}"
  printf 'DRY: live-migrate vm-a -> measure new /32 route on %s, old /32 retention/withdrawal, and 30/30 probes to new /32\n' "${BORDER}"
  printf 'DRY: rollback to ipam.mode=kubernetes (%s), remove pools/namespaces/prefix-list seq 50-60, verify p003-gw and k01\n' "${BASE_VALUES}"
  printf 'V06 DRY-RUN OK\n'
  exit 0
fi

# 1. Validar UIDs de p003-gw e k01 e estado exited de p003-os
uid_p003="$(v06_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_p003}" != "${P003_EXPECTED_UID}" ]]; then
  printf '[v06] ERRO: UID de p003-gw (%s) difere do esperado (%s)\n' "${uid_p003}" "${P003_EXPECTED_UID}" >&2
  exit 1
fi
uid_k01="$(k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_k01}" != "${K01_EXPECTED_UID}" ]]; then
  printf '[v06] ERRO: UID de k01 (%s) difere do esperado (%s)\n' "${uid_k01}" "${K01_EXPECTED_UID}" >&2
  exit 1
fi
os_state="$(docker inspect -f '{{.State.Status}}' "${P003_OS_CONTAINER}" 2>/dev/null || true)"
if [[ "${os_state}" != "${P003_OS_EXPECTED_STATE}" ]]; then
  printf '[v06] ERRO: estado de %s (%s) difere do esperado (%s)\n' "${P003_OS_CONTAINER}" "${os_state:-ausente}" "${P003_OS_EXPECTED_STATE}" >&2
  exit 1
fi

api_ip="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' p003-gw-control-plane)"

V06_CLEANUP_DONE=0
v06_cleanup() {
  if [[ "${V06_CLEANUP_DONE}" == "1" ]]; then
    return 0
  fi
  V06_CLEANUP_DONE=1
  printf '[v06] Iniciando rollback limpo para ipam.mode=kubernetes...\n'
  docker exec "${CLIENT}" touch /tmp/v06-stop >/dev/null 2>&1 || true
  v06_kctl -n "${NS}" delete vmim migrate-vm-a-v06 --ignore-not-found >/dev/null 2>&1 || true
  v06_kctl -n "${NS}" delete vm --all --ignore-not-found >/dev/null 2>&1 || true
  v06_kctl -n p004-vm-reuse delete vm --all --ignore-not-found >/dev/null 2>&1 || true
  v06_kctl -n "${NS}" delete pods --all --ignore-not-found --grace-period=0 --force >/dev/null 2>&1 || true
  v06_kctl -n p004-vm-reuse delete pods --all --ignore-not-found --grace-period=0 --force >/dev/null 2>&1 || true
  v06_run v06_kctl delete ns "${NS}" p004-vm-reuse --ignore-not-found --timeout=180s || true
  v06_run v06_kctl apply -f "${BASE_BGP_ADV}"
  v06_run v06_kctl delete ciliumpodippool p004-vm p004-single-ip default --ignore-not-found || true

  docker exec "${BORDER}" vtysh \
    -c "conf t" \
    -c "no ip prefix-list PL-FROM-FABRIC seq 50 permit 10.251.0.0/16 le 32" \
    -c "no ip prefix-list PL-FROM-FABRIC seq 60 permit 10.252.0.0/16 le 32" \
    -c "end" \
    -c "clear ip bgp 10.254.0.0 soft in" >/dev/null 2>&1 || true

  v06_run helm upgrade cilium "${CHART}" \
    --kubeconfig "${P003_KUBECONFIG}" --kube-context "${P003_CONTEXT}" \
    -n kube-system -f "${BASE_VALUES}" --set "k8sServiceHost=${api_ip}" >/dev/null
  v06_run v06_kctl -n kube-system rollout restart deploy/cilium-operator ds/cilium
  v06_run v06_kctl -n kube-system rollout status deploy/cilium-operator --timeout=240s
  v06_run v06_kctl -n kube-system rollout status ds/cilium --timeout=240s
  v06_kctl -n kube-system delete pods -l k8s-app=kube-dns --grace-period=0 --force >/dev/null 2>&1 || true
  v06_run v06_kctl -n kube-system rollout status deploy/coredns --timeout=180s

  v06_kctl -n kubevirt delete pods --all --grace-period=0 --force >/dev/null 2>&1 || true
  v06_run v06_kctl -n kubevirt rollout status deploy/virt-operator deploy/virt-api deploy/virt-controller ds/virt-handler --timeout=240s
  v06_run v06_kctl -n kubevirt wait kubevirt kubevirt --for=condition=Available --timeout=240s

  v06_kctl -n p003-gateway delete pods --all --grace-period=0 --force >/dev/null 2>&1 || true
  v06_run v06_kctl -n p003-gateway rollout status deploy/http-echo deploy/p003-dns deploy/tcp-echo --timeout=180s
}
trap v06_cleanup EXIT

# 2. Aplicar CiliumPodIPPools (default /24, p004-vm /32), CiliumBGPAdvertisement (CiliumPodIPPool) e prefix-list na border1 (D-S010-2 / D-S010-5)
v06_run v06_kctl apply -f "${SCRIPT_DIR}/manifests/06-v06-multipool.yaml"
docker exec "${BORDER}" vtysh \
  -c "conf t" \
  -c "ip prefix-list PL-FROM-FABRIC seq 50 permit 10.251.0.0/16 le 32" \
  -c "ip prefix-list PL-FROM-FABRIC seq 60 permit 10.252.0.0/16 le 32" \
  -c "end" \
  -c "clear ip bgp 10.254.0.0 soft in" >/dev/null

# 3. Trocar Cilium para ipam.mode=multi-pool e rolar operator + agent + KubeVirt control-plane (D-S010-3 / D-S010-4)
cur_ipam="$(v06_kctl -n kube-system get cm cilium-config -o jsonpath='{.data.ipam}' 2>/dev/null || true)"
if [[ "${cur_ipam}" != "multi-pool" ]]; then
  v06_kctl -n "${NS}" patch vm vm-a --type=merge -p '{"spec":{"runStrategy":"Halted"}}' >/dev/null 2>&1 || true
  for _ in $(seq 1 45); do
    if [[ -z "$(v06_kctl -n "${NS}" get pods -l kubevirt.io=virt-launcher,kubevirt.io/domain=vm-a -o name 2>/dev/null)" ]]; then
      break
    fi
    sleep 1
  done
  v06_run helm upgrade cilium "${CHART}" \
    --kubeconfig "${P003_KUBECONFIG}" --kube-context "${P003_CONTEXT}" \
    -n kube-system -f "${M32_VALUES}" --set "k8sServiceHost=${api_ip}" >/dev/null
  v06_run v06_kctl -n kube-system rollout restart deploy/cilium-operator ds/cilium
  v06_run v06_kctl -n kube-system rollout status deploy/cilium-operator --timeout=240s
  v06_run v06_kctl -n kube-system rollout status ds/cilium --timeout=240s
  v06_kctl -n kube-system delete pods -l k8s-app=kube-dns --grace-period=0 --force >/dev/null 2>&1 || true
  v06_run v06_kctl -n kube-system rollout status deploy/coredns --timeout=180s

  v06_kctl -n kubevirt delete pods --all --grace-period=0 --force >/dev/null 2>&1 || true
  v06_run v06_kctl -n kubevirt rollout status deploy/virt-operator deploy/virt-api deploy/virt-controller ds/virt-handler --timeout=240s
  v06_run v06_kctl -n kubevirt wait kubevirt kubevirt --for=condition=Available --timeout=240s
fi

# 4. Anotar p004-vm-a com require-pool-match=true e recriar vm-a para alocar /32 do pool p004-vm (10.252.0.0/16)
v06_run v06_kctl annotate ns "${NS}" ipam.cilium.io/require-pool-match=true --overwrite
v06_run v06_kctl -n "${NS}" delete vm vm-a --ignore-not-found --wait=true
v06_kctl -n "${NS}" delete pod client-a client-b target-srv --ignore-not-found --grace-period=0 --force >/dev/null 2>&1 || true
sleep 2

t_spawn="$(date +%s)"
v06_run v06_kctl apply -f "${SCRIPT_DIR}/manifests/01-namespace-clients.yaml"
v06_run v06_kctl apply -f "${SCRIPT_DIR}/manifests/02-vm-a.yaml"
v06_run v06_kctl apply -f "${SCRIPT_DIR}/manifests/03-v02-bgp-vip-service.yaml"
v06_run v06_kctl -n "${NS}" wait vmi vm-a --for=condition=Ready --timeout=240s
v06_run v06_kctl -n "${NS}" wait pod client-a --for=condition=Ready --timeout=180s

node_before="$(v06_kctl -n "${NS}" get vmi vm-a -o jsonpath='{.status.nodeName}')"
ip_before="$(v06_kctl -n "${NS}" get vmi vm-a -o jsonpath='{.status.interfaces[0].ipAddress}')"

if [[ "${ip_before}" != 10.252.* ]]; then
  printf '[v06] ERRO: vm-a recebeu IP %s fora do pool p004-vm (10.252.0.0/16)\n' "${ip_before}" >&2
  exit 1
fi

t_rib_before=""
for _ in $(seq 1 30); do
  if docker exec "${BORDER}" vtysh -c "show ip bgp ${ip_before}/32" 2>/dev/null | grep -q "${ip_before}/32"; then
    t_rib_before="$(( $(date +%s) - t_spawn ))"
    break
  fi
  sleep 1
done
rib_before_out="$(docker exec "${BORDER}" vtysh -c "show ip bgp ${ip_before}/32" 2>/dev/null || true)"
printf '[v06] Pré-migração Multi-Pool /32: node=%s, vm_ip=%s/32 (anunciado na border1 em %ss)\n%s\n' \
  "${node_before}" "${ip_before}" "${t_rib_before:-NA}" "${rib_before_out}"

if [[ -z "${t_rib_before}" ]]; then
  printf '[v06] ERRO: prefixo %s/32 não apareceu na border1\n' "${ip_before}" >&2
  exit 1
fi

for _ in $(seq 1 45); do
  if docker exec "${CLIENT}" curl -s --noproxy '*' --max-time 2 "http://${ip_before}:8080/" 2>/dev/null | grep -q "VM_OK"; then
    break
  fi
  sleep 2
done

# 5. Validar 30/30 conexões diretas do fabric client (198.19.0.10) para o /32 da VM (ip_before:8080)
pre_direct_ok=0
for _ in $(seq 1 30); do
  if docker exec "${CLIENT}" curl -s --noproxy '*' --connect-timeout 2 --max-time 3 "http://${ip_before}:8080/" 2>/dev/null | grep -q "VM_OK"; then
    pre_direct_ok=$((pre_direct_ok + 1))
  fi
done
printf '[v06] Alcance direto pré-migração (%s -> %s:8080): %s/30 OK\n' "${CLIENT}" "${ip_before}" "${pre_direct_ok}"
if [[ "${pre_direct_ok}" -ne 30 ]]; then
  printf '[v06] ERRO: alcance direto ao /32 pré-migração obteve %s/30\n' "${pre_direct_ok}" >&2
  exit 1
fi

# 6. Iniciar probe contínuo de 100ms à VIP durante Live Migration em Multi-Pool /32 e migrar vm-a
docker exec "${CLIENT}" sh -c "
  rm -f /tmp/v06-vip.tsv /tmp/v06-stop
  nohup sh -c '
    while [ ! -f /tmp/v06-stop ]; do
      ts=\$(date +%s.%N)
      code=\$(curl -s -o /dev/null -w \"%{http_code}\" --noproxy \"*\" --connect-timeout 1 --max-time 1 http://${VIP}:8080/ 2>/dev/null || echo 000)
      echo \"\${ts} \${code}\" >> /tmp/v06-vip.tsv
      sleep 0.1
    done
  ' >/dev/null 2>&1 &
"
sleep 1

t_mig0="$(date +%s)"
v06_kctl -n "${NS}" delete vmim migrate-vm-a-v06 --ignore-not-found >/dev/null 2>&1 || true
v06_kctl -n "${NS}" apply -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  name: migrate-vm-a-v06
  namespace: ${NS}
spec:
  vmiName: vm-a
EOF

mig_phase=""
for _ in $(seq 1 90); do
  mig_phase="$(v06_kctl -n "${NS}" get vmim migrate-vm-a-v06 -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${mig_phase}" == "Succeeded" ]] || [[ "${mig_phase}" == "Failed" ]]; then
    break
  fi
  sleep 1
done
t_mig1="$(date +%s)"
mig_dur_s="$(( t_mig1 - t_mig0 ))"

sleep 3
docker exec "${CLIENT}" touch /tmp/v06-stop

if [[ "${mig_phase}" != "Succeeded" ]]; then
  printf '[v06] ERRO: migração Multi-Pool terminou em phase=%s\n' "${mig_phase}" >&2
  exit 1
fi

node_after="$(v06_kctl -n "${NS}" get vmi vm-a -o jsonpath='{.status.nodeName}')"
ip_after="$(v06_kctl -n "${NS}" get vmi vm-a -o jsonpath='{.status.interfaces[0].ipAddress}')"

t_rib_after=""
for _ in $(seq 1 30); do
  if docker exec "${BORDER}" vtysh -c "show ip bgp ${ip_after}/32" 2>/dev/null | grep -q "${ip_after}/32"; then
    t_rib_after="$(( $(date +%s) - t_mig0 ))"
    break
  fi
  sleep 1
done
rib_after_out="$(docker exec "${BORDER}" vtysh -c "show ip bgp ${ip_after}/32" 2>/dev/null || true)"
old_rib_state="withdrawn"
if docker exec "${BORDER}" vtysh -c "show ip bgp ${ip_before}/32" 2>/dev/null | grep -q "${ip_before}/32"; then
  old_rib_state="held_by_prealloc_floor"
fi

post_direct_ok=0
for _ in $(seq 1 30); do
  if docker exec "${CLIENT}" curl -s --noproxy '*' --connect-timeout 2 --max-time 3 "http://${ip_after}:8080/" 2>/dev/null | grep -q "VM_OK"; then
    post_direct_ok=$((post_direct_ok + 1))
  fi
done

vip_gap_ms="$(docker exec "${CLIENT}" cat /tmp/v06-vip.tsv | python3 -c '
import sys
rows = [line.strip().split() for line in sys.stdin if len(line.strip().split()) == 2]
ok_ts = [float(ts) for ts, code in rows if code == "200"]
print(f"{max(((b - a) * 1000.0 for a, b in zip(ok_ts, ok_ts[1:])), default=0.0):.1f}")
')"

printf '[v06] Pós-migração Multi-Pool (%ss): node=%s->%s, ip=%s/32->%s/32 (RIB em %ss, old_prefix=%s), post_direct=%s/30, vip_gap_ms=%sms\n%s\n' \
  "${mig_dur_s}" "${node_before}" "${node_after}" "${ip_before}" "${ip_after}" "${t_rib_after:-NA}" "${old_rib_state}" "${post_direct_ok}" "${vip_gap_ms}" "${rib_after_out}"

if [[ "${node_before}" == "${node_after}" ]] || [[ "${ip_after}" != 10.252.* ]] || [[ "${post_direct_ok}" -ne 30 ]]; then
  printf '[v06] ERRO: falha na verificação pós-migração Multi-Pool /32\n' >&2
  exit 1
fi

# 7. Rollback completo para ipam.mode=kubernetes no mesmo run (P004-S005 Outcome 3 + D-S010-3/D-S010-4)
v06_cleanup

# Verificar que ipam voltou a kubernetes, zero pools restantes e labctl verify OK em p003-gw e k01
ipam_post="$(v06_kctl -n kube-system get cm cilium-config -o jsonpath='{.data.ipam}')"
pools_post="$(v06_kctl get ciliumpodippool -o name 2>/dev/null | wc -l | tr -d '[:space:]')"
if [[ "${ipam_post}" != "kubernetes" ]] || [[ "${pools_post}" -ne 0 ]]; then
  printf '[v06] ERRO no rollback: ipam=%s (esperado kubernetes), pools_restantes=%s (esperado 0)\n' "${ipam_post}" "${pools_post}" >&2
  exit 1
fi

v06_run "${LABCTL_BIN}" p003-gw verify
v06_run "${LABCTL_BIN}" k01 verify

printf 'V06 PASS: Multi-Pool /32 por VM anunciado na border1 (%s/32 -> %s/32 após migração %s->%s em %ss, 30/30 probes diretos pré e pós, old_prefix=%s, vip_gap_ms=%sms) e rollback para ipam.mode=kubernetes verificado (p003-gw + k01 VERIFY_OK).\n' \
  "${ip_before}" "${ip_after}" "${node_before}" "${node_after}" "${mig_dur_s}" "${old_rib_state}" "${vip_gap_ms}"
