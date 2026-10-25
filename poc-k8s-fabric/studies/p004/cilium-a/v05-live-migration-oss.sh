#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p004/cilium-a/v05-live-migration-oss.sh — Caso V05 (C05 / H3): Live Migration no Cilium OSS (mudança de IP do virt-launcher, queda de sessão TCP longa para o podIP e reconvergência da VIP BGP).

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
VIP="10.202.255.20"
CLIENT="clab-p003-gw-fabric-client"

v05_kctl() {
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

v05_run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf 'DRY: %s\n' "$*"
    return 0
  fi
  printf '[v05] + %s\n' "$*"
  "$@"
}

if [[ "${DRY_RUN}" == "1" ]]; then
  v05_run v05_kctl get ns kube-system -o jsonpath='{.metadata.uid}'
  v05_run k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}'
  v05_run docker inspect -f '{{.State.Status}}' "${P003_OS_CONTAINER}"
  printf 'DRY: capture node_before, pod_before, ip_before, guest_ip_before of vmi/vm-a\n'
  printf 'DRY: start persistent TCP session to <ip_before>:9999 and 100ms HTTP probes from %s to VIP %s:8080 and <ip_before>:8080\n' "${CLIENT}" "${VIP}"
  printf 'DRY: apply VirtualMachineInstanceMigration migrate-vm-a-v05 and wait for Succeeded\n'
  printf 'DRY: verify node_before != node_after, ip_before != ip_after (H3), TCP session to old podIP dropped, and VIP %s reconverged\n' "${VIP}"
  printf 'V05 DRY-RUN OK\n'
  exit 0
fi

# 1. Validar UIDs de p003-gw e k01, estado exited de p003-os e modo IPAM=kubernetes
uid_p003="$(v05_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_p003}" != "${P003_EXPECTED_UID}" ]]; then
  printf '[v05] ERRO: UID de p003-gw (%s) difere do esperado (%s)\n' "${uid_p003}" "${P003_EXPECTED_UID}" >&2
  exit 1
fi
uid_k01="$(k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "${uid_k01}" != "${K01_EXPECTED_UID}" ]]; then
  printf '[v05] ERRO: UID de k01 (%s) difere do esperado (%s)\n' "${uid_k01}" "${K01_EXPECTED_UID}" >&2
  exit 1
fi
os_state="$(docker inspect -f '{{.State.Status}}' "${P003_OS_CONTAINER}" 2>/dev/null || true)"
if [[ "${os_state}" != "${P003_OS_EXPECTED_STATE}" ]]; then
  printf '[v05] ERRO: estado de %s (%s) difere do esperado (%s)\n' "${P003_OS_CONTAINER}" "${os_state:-ausente}" "${P003_OS_EXPECTED_STATE}" >&2
  exit 1
fi
ipam_mode="$(v05_kctl -n kube-system get cm cilium-config -o jsonpath='{.data.ipam}')"
if [[ "${ipam_mode}" != "kubernetes" ]]; then
  printf '[v05] ERRO: esperava ipam=kubernetes em V05, obtido=%s\n' "${ipam_mode}" >&2
  exit 1
fi

v05_cleanup() {
  docker exec "${CLIENT}" touch /tmp/v05-stop >/dev/null 2>&1 || true
  v05_kctl -n "${NS}" exec client-a -- touch /tmp/v05-mig-done >/dev/null 2>&1 || true
  v05_kctl -n "${NS}" delete vmim migrate-vm-a-v05 --ignore-not-found >/dev/null 2>&1 || true
}
trap v05_cleanup EXIT

# 2. Capturar estado pré-migração
node_before="$(v05_kctl -n "${NS}" get vmi vm-a -o jsonpath='{.status.nodeName}')"
ip_before="$(v05_kctl -n "${NS}" get vmi vm-a -o jsonpath='{.status.interfaces[0].ipAddress}')"
pod_before="$(v05_kctl -n "${NS}" get pods -l kubevirt.io=virt-launcher,kubevirt.io/domain=vm-a --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
guest_ip_before="$(v05_kctl -n "${NS}" logs "${pod_before}" -c guest-console-log --tail=20 2>/dev/null | awk -F= '/GUEST_OS_IP=/{print $2}' | tail -n1 | tr -d '\r[:space:]' || true)"

# Registrar suporte a binding passt no KubeVirt v1.9.0 (20-kubevirt-inv.md §4 V05)
passt_schema="absent_in_crd"
if v05_kctl get crd virtualmachines.kubevirt.io -o json 2>/dev/null | grep -q '"passt"'; then
  passt_schema="present_in_crd"
fi

for _ in $(seq 1 45); do
  if v05_kctl -n "${NS}" exec client-a -- curl -s --max-time 2 "http://${ip_before}:8080/" 2>/dev/null | grep -q "VM_OK"; then
    break
  fi
  sleep 2
done

printf '[v05] Pré-migração: node=%s, pod=%s, pod_ip=%s, guest_ip=%s, passt_crd=%s\n' \
  "${node_before}" "${pod_before}" "${ip_before}" "${guest_ip_before:-10.0.2.2/24}" "${passt_schema}"

# 3. Iniciar sessão TCP longa de client-a para ip_before:9999 e probes contínuos de 100ms de clab-p003-gw-fabric-client para VIP (10.202.255.20:8080) e ip_before:8080
v05_kctl -n "${NS}" exec client-a -- sh -c "
  rm -f /tmp/v05-tcp-ready /tmp/v05-mig-done /tmp/v05-tcp.out
  nohup sh -c '
    (
      echo PRE_MIG_V05
      while [ ! -f /tmp/v05-mig-done ]; do
        sleep 0.5
        echo HEARTBEAT_V05
      done
      echo POST_MIG_V05
    ) | nc -w 4 ${ip_before} 9999 >/tmp/v05-tcp.out 2>&1
    echo NC_RC=\$? >>/tmp/v05-tcp.out
  ' >/dev/null 2>&1 &
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -q PRE_MIG_V05 /tmp/v05-tcp.out 2>/dev/null; then
      touch /tmp/v05-tcp-ready
      break
    fi
    sleep 0.3
  done
"

if ! v05_kctl -n "${NS}" exec client-a -- test -f /tmp/v05-tcp-ready 2>/dev/null; then
  printf '[v05] ERRO: sessão TCP longa pré-migração para %s:9999 não estabeleceu\n' "${ip_before}" >&2
  exit 1
fi

docker exec "${CLIENT}" sh -c "
  rm -f /tmp/v05-vip.tsv /tmp/v05-podip.tsv /tmp/v05-stop
  nohup sh -c '
    while [ ! -f /tmp/v05-stop ]; do
      ts=\$(date +%s.%N)
      code=\$(curl -s -o /dev/null -w \"%{http_code}\" --noproxy \"*\" --connect-timeout 1 --max-time 1 http://${VIP}:8080/ 2>/dev/null || echo 000)
      echo \"\${ts} \${code}\" >> /tmp/v05-vip.tsv
      sleep 0.1
    done
  ' >/dev/null 2>&1 &
  nohup sh -c '
    while [ ! -f /tmp/v05-stop ]; do
      ts=\$(date +%s.%N)
      code=\$(curl -s -o /dev/null -w \"%{http_code}\" --noproxy \"*\" --connect-timeout 1 --max-time 1 http://${ip_before}:8080/ 2>/dev/null || echo 000)
      echo \"\${ts} \${code}\" >> /tmp/v05-podip.tsv
      sleep 0.1
    done
  ' >/dev/null 2>&1 &
"
sleep 1

# 4. Disparar VirtualMachineInstanceMigration migrate-vm-a-v05
t_mig_start="$(date +%s)"
v05_kctl -n "${NS}" delete vmim migrate-vm-a-v05 --ignore-not-found >/dev/null 2>&1 || true
v05_kctl -n "${NS}" apply -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  name: migrate-vm-a-v05
  namespace: ${NS}
spec:
  vmiName: vm-a
EOF

mig_phase=""
for _ in $(seq 1 90); do
  mig_phase="$(v05_kctl -n "${NS}" get vmim migrate-vm-a-v05 -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${mig_phase}" == "Succeeded" ]] || [[ "${mig_phase}" == "Failed" ]]; then
    break
  fi
  sleep 1
done
t_mig_end="$(date +%s)"
mig_dur_s="$(( t_mig_end - t_mig_start ))"

if [[ "${mig_phase}" != "Succeeded" ]]; then
  docker exec "${CLIENT}" touch /tmp/v05-stop >/dev/null 2>&1 || true
  printf '[v05] ERRO: VirtualMachineInstanceMigration terminou em phase=%s\n' "${mig_phase}" >&2
  exit 1
fi

# Aguardar 3s de probes pós-migração para registrar reconvergência da VIP e queda do podIP antigo
sleep 3
docker exec "${CLIENT}" touch /tmp/v05-stop
v05_kctl -n "${NS}" exec client-a -- touch /tmp/v05-mig-done
sleep 2

# 5. Coletar estado pós-migração e validar H3
node_after="$(v05_kctl -n "${NS}" get vmi vm-a -o jsonpath='{.status.nodeName}')"
ip_after="$(v05_kctl -n "${NS}" get vmi vm-a -o jsonpath='{.status.interfaces[0].ipAddress}')"
pod_after="$(v05_kctl -n "${NS}" get pods -l kubevirt.io=virt-launcher,kubevirt.io/domain=vm-a --field-selector="status.phase=Running,spec.nodeName=${node_after}" -o jsonpath='{.items[0].metadata.name}')"
guest_ip_after="$(v05_kctl -n "${NS}" logs "${pod_after}" -c guest-console-log --tail=20 2>/dev/null | awk -F= '/GUEST_OS_IP=/{print $2}' | tail -n1 | tr -d '\r[:space:]' || true)"

if [[ "${node_before}" == "${node_after}" ]]; then
  printf '[v05] ERRO: VMI permaneceu no mesmo nó (%s)\n' "${node_after}" >&2
  exit 1
fi
if [[ "${ip_before}" == "${ip_after}" ]]; then
  printf '[v05] ERRO: esperava mudança de podIP em Cilium OSS (H3), mas ip_before == ip_after (%s)\n' "${ip_after}" >&2
  exit 1
fi

tcp_out="$(v05_kctl -n "${NS}" exec client-a -- cat /tmp/v05-tcp.out 2>/dev/null || true)"
tcp_survived="no"
if grep -q "POST_MIG_V05" <<<"${tcp_out}"; then
  tcp_survived="yes"
fi

# Verificar que o podIP antigo parou de responder após a migração e que a VIP BGP reconvergiu
vip_stats="$(docker exec "${CLIENT}" cat /tmp/v05-vip.tsv | python3 -c '
import sys
rows = [line.strip().split() for line in sys.stdin if len(line.strip().split()) == 2]
ok_ts = [float(ts) for ts, code in rows if code == "200"]
fail_cnt = sum(1 for _, code in rows if code != "200")
max_gap_ms = max(((b - a) * 1000.0 for a, b in zip(ok_ts, ok_ts[1:])), default=0.0)
last5_ok = sum(1 for _, code in rows[-5:] if code == "200")
print(f"{len(rows)}|{len(ok_ts)}|{fail_cnt}|{max_gap_ms:.1f}|{last5_ok}")
')"
IFS='|' read -r vip_total vip_ok vip_fail vip_gap_ms vip_last5 <<<"${vip_stats}"

old_ip_post_ok=0
for _ in $(seq 1 5); do
  if docker exec "${CLIENT}" curl -s --noproxy '*' --connect-timeout 1 --max-time 1 "http://${ip_before}:8080/" 2>/dev/null | grep -q "VM_OK"; then
    old_ip_post_ok=$((old_ip_post_ok + 1))
  fi
done

new_ip_post_ok=0
for _ in $(seq 1 10); do
  if v05_kctl -n "${NS}" exec client-a -- curl -s --connect-timeout 2 --max-time 2 "http://${ip_after}:8080/" 2>/dev/null | grep -q "VM_OK"; then
    new_ip_post_ok=$((new_ip_post_ok + 1))
  fi
done

vip_post_ok=0
for _ in $(seq 1 10); do
  if docker exec "${CLIENT}" curl -s --noproxy '*' --connect-timeout 2 --max-time 2 "http://${VIP}:8080/" 2>/dev/null | grep -q "VM_OK"; then
    vip_post_ok=$((vip_post_ok + 1))
  fi
done

printf '[v05] Pós-migração (%ss): node=%s->%s, pod_ip=%s->%s, guest_ip=%s->%s\n' \
  "${mig_dur_s}" "${node_before}" "${node_after}" "${ip_before}" "${ip_after}" "${guest_ip_before:-10.0.2.2/24}" "${guest_ip_after:-10.0.2.2/24}"
printf '[v05] H3: tcp_long_survived=%s (esperado no), old_ip_post_ok=%s/5 (esperado 0/5), new_ip_post_ok=%s/10, vip_post_ok=%s/10\n' \
  "${tcp_survived}" "${old_ip_post_ok}" "${new_ip_post_ok}" "${vip_post_ok}"
printf '[v05] VIP BGP stream: total=%s, ok=%s, fail=%s, max_gap_ms=%sms, last5_ok=%s/5\n' \
  "${vip_total}" "${vip_ok}" "${vip_fail}" "${vip_gap_ms}" "${vip_last5}"

if [[ "${tcp_survived}" != "no" ]] || [[ "${old_ip_post_ok}" -ne 0 ]] || [[ "${new_ip_post_ok}" -ne 10 ]] || [[ "${vip_post_ok}" -ne 10 ]]; then
  printf '[v05] ERRO: resultados fora do esperado para H3\n' >&2
  exit 1
fi

printf 'V05 PASS (H3 confirmado): migração %s->%s (%ss) mudou podIP (%s -> %s), sessão TCP longa para o IP de pod caiu (tcp_survived=%s, old_ip=%s/5), novo podIP=%s/10 OK e VIP BGP %s reconvergiu (%s/10 OK, max_gap_ms=%sms, passt=%s).\n' \
  "${node_before}" "${node_after}" "${mig_dur_s}" "${ip_before}" "${ip_after}" "${tcp_survived}" "${old_ip_post_ok}" "${new_ip_post_ok}" "${VIP}" "${vip_post_ok}" "${vip_gap_ms}" "${passt_schema}"
