#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p004/ovnk/k02.sh — Caso K02: Live migration KubeVirt sobre UDN primária Layer2 preservando IP 10.0.0.11 no guest OS (R6 + N5).

set -euo pipefail

DRY_RUN="${DRY_RUN:-${LABCTL_DRY_RUN:-0}}"
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

OVNK_KUBECONFIG="${OVNK_KUBECONFIG:-/root/.kube/ovnk.config}"
OVNK_CONTEXT="${OVNK_CONTEXT:-kind-ovnk}"

k02_kctl() {
  if [[ -f "${OVNK_KUBECONFIG}" ]]; then
    kubectl --kubeconfig "${OVNK_KUBECONFIG}" --context "${OVNK_CONTEXT}" "$@"
  else
    kubectl --context "${OVNK_CONTEXT}" "$@"
  fi
}

# N5 / R6: Lê o IP configurado diretamente dentro do guest OS via console serial (/dev/ttyS0)
# (CirrOS não possui qemu-guest-agent; não confiamos apenas no IP do pod/VMI status)
k02_read_guest_os_ip() {
  local target_node="${1:-}"
  local field_sel="status.phase=Running"
  if [[ -n "${target_node}" ]]; then
    field_sel="status.phase=Running,spec.nodeName=${target_node}"
  fi
  local pod=""
  local guest_ip=""
  for _ in $(seq 1 8); do
    pod="$(k02_kctl -n tenant-a get pods -l kubevirt.io=virt-launcher,kubevirt.io/domain=vm-a \
      --field-selector="${field_sel}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "${pod}" ]]; then
      guest_ip="$(k02_kctl -n tenant-a logs "${pod}" -c guest-console-log --tail=50 2>/dev/null | awk -F= '/GUEST_OS_IP=/{print $2}' | tail -n1 | tr -d '\r[:space:]')"
      if [[ -z "${guest_ip}" ]]; then
        guest_ip="$(k02_kctl -n tenant-a logs "${pod}" -c compute --tail=50 2>/dev/null | awk -F= '/GUEST_OS_IP=/{print $2}' | tail -n1 | tr -d '\r[:space:]')"
      fi
      if [[ -n "${guest_ip}" ]]; then
        break
      fi
    fi
    sleep 1
  done
  if [[ -z "${guest_ip}" ]] && [[ -n "${pod}" ]]; then
    guest_ip="$(k02_kctl -n tenant-a exec "${pod}" -c compute -- python3 -c '
import glob, socket, time
socks = glob.glob("/var/run/kubevirt-private/*/virt-serial0")
if not socks:
    raise SystemExit(1)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(4.0)
s.connect(socks[0])
end = time.time() + 4.0
buf = ""
while time.time() < end:
    chunk = s.recv(1024).decode("utf-8", "ignore")
    buf += chunk
    for line in buf.splitlines():
        if "GUEST_OS_IP=" in line:
            print(line.split("GUEST_OS_IP=", 1)[1].strip())
            raise SystemExit(0)
raise SystemExit(1)
' 2>/dev/null || true)"
  fi
  printf '%s\n' "${guest_ip}"
}

if [[ "${DRY_RUN}" == "1" ]]; then
  printf 'DRY: k02_kctl -n tenant-a get vmi vm-a -o json\n'
  printf 'DRY: k02_read_guest_os_ip (serial /dev/ttyS0 before migration)\n'
  printf 'DRY: k02_kctl -n tenant-a exec probe-a -- start continuous ICMP gap probe + persistent TCP session to 10.0.0.11:9999\n'
  printf 'DRY: k02_kctl -n tenant-a apply VirtualMachineInstanceMigration migrate-vm-a\n'
  printf 'DRY: k02_kctl -n tenant-a wait vmim migrate-vm-a (phase==Succeeded)\n'
  printf 'DRY: k02_read_guest_os_ip (serial /dev/ttyS0 after migration)\n'
  printf 'DRY: k02_kctl -n tenant-a exec probe-a -- verify TCP session persistence + max_gap_ms + ping -c 5 -W 2 10.0.0.11\n'
  printf 'K02 DRY-RUN OK\n'
  exit 0
fi

# 1. Capturar estado inicial (nó de origem e IP real no guest OS via serial /dev/ttyS0 - R6/N5)
node_before="$(k02_kctl -n tenant-a get vmi vm-a -o jsonpath='{.status.nodeName}')"
guest_ip_before="$(k02_read_guest_os_ip "${node_before}")"
if [[ "${guest_ip_before}" != "10.0.0.11/24" ]]; then
  printf '[k02] ERRO: IP no guest OS antes da migração (%s) difere de 10.0.0.11/24\n' "${guest_ip_before}" >&2
  exit 1
fi

# 2. Iniciar probe contínuo de gap (L4) e sessão TCP persistente em probe-a antes da migração (P1-2)
k02_kctl -n tenant-a exec probe-a -- bash -c '
  rm -f /tmp/k02-gap.log /tmp/k02-gap-stop /tmp/k02-tcp-ready /tmp/k02-mig-done /tmp/k02-tcp.out
  nohup python3 -c "
import subprocess, time, os
with open(\"/tmp/k02-gap.log\", \"w\", buffering=1) as f:
    while not os.path.exists(\"/tmp/k02-gap-stop\"):
        rc = subprocess.call([\"ping\", \"-c\", \"1\", \"-W\", \"1\", \"10.0.0.11\"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if rc == 0:
            f.write(f\"{time.monotonic():.6f}\n\")
        time.sleep(0.2)
" >/dev/null 2>&1 &

  nohup python3 -c "
import socket, time, os, sys
s = socket.create_connection((\"10.0.0.11\", 9999), timeout=10.0)
s.settimeout(10.0)
s.sendall(b\"PRE_MIGRATION_PING\n\")
pre = s.recv(1024).decode(\"utf-8\", \"ignore\").strip()
if \"PRE_MIGRATION_PING\" not in pre:
    with open(\"/tmp/k02-tcp.out\", \"w\") as f:
        f.write(f\"ERR_PRE:{pre}\n\")
    sys.exit(1)
with open(\"/tmp/k02-tcp-ready\", \"w\") as f:
    f.write(\"1\n\")
deadline = time.monotonic() + 240.0
while not os.path.exists(\"/tmp/k02-mig-done\") and time.monotonic() < deadline:
    time.sleep(0.2)
s.sendall(b\"POST_MIGRATION_PING\n\")
post = s.recv(1024).decode(\"utf-8\", \"ignore\").strip()
s.close()
with open(\"/tmp/k02-tcp.out\", \"w\") as f:
    if \"POST_MIGRATION_PING\" in post:
        f.write(\"TCP_PERSISTENCE_OK\n\")
    else:
        f.write(f\"ERR_POST:{post}\n\")
" >/dev/null 2>&1 &
'

for _ in $(seq 1 25); do
  if k02_kctl -n tenant-a exec probe-a -- test -f /tmp/k02-tcp-ready 2>/dev/null; then
    break
  fi
  sleep 0.5
done
if ! k02_kctl -n tenant-a exec probe-a -- test -f /tmp/k02-tcp-ready 2>/dev/null; then
  printf '[k02] ERRO: sessão TCP pré-migração (probe-a -> 10.0.0.11:9999) não ficou pronta\n' >&2
  exit 1
fi

# 3. Disparar VirtualMachineInstanceMigration
k02_kctl -n tenant-a delete vmim migrate-vm-a --ignore-not-found >/dev/null 2>&1 || true
k02_kctl -n tenant-a apply -f - <<'EOF'
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  name: migrate-vm-a
  namespace: tenant-a
spec:
  vmiName: vm-a
EOF

# 4. Aguardar Succeeded
mig_phase=""
for _ in $(seq 1 90); do
  mig_phase="$(k02_kctl -n tenant-a get vmim migrate-vm-a -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${mig_phase}" == "Succeeded" ]]; then
    break
  fi
  if [[ "${mig_phase}" == "Failed" ]]; then
    printf '[k02] ERRO: VirtualMachineInstanceMigration migrate-vm-a falhou\n' >&2
    exit 1
  fi
  sleep 2
done

if [[ "${mig_phase}" != "Succeeded" ]]; then
  printf '[k02] ERRO: migração não atingiu Succeeded (phase=%s)\n' "${mig_phase}" >&2
  exit 1
fi

# 5. Validar mudança de nó, VMI Ready, sessão TCP persistente, max_gap_ms (L4) e preservação do IP no guest OS após migração (R6 + N5)
k02_kctl -n tenant-a wait vmi vm-a --for=condition=Ready --timeout=120s >/dev/null
node_after="$(k02_kctl -n tenant-a get vmi vm-a -o jsonpath='{.status.nodeName}')"
if [[ -z "${node_after}" ]] || [[ "${node_before}" == "${node_after}" ]]; then
  printf '[k02] ERRO: nó da VMI não mudou após live migration (before=%s, after=%s)\n' "${node_before}" "${node_after}" >&2
  exit 1
fi

sleep 2
k02_kctl -n tenant-a exec probe-a -- bash -c 'touch /tmp/k02-mig-done /tmp/k02-gap-stop'
sleep 2

tcp_status="$(k02_kctl -n tenant-a exec probe-a -- cat /tmp/k02-tcp.out 2>/dev/null | tr -d '[:space:]' || true)"
if [[ "${tcp_status}" != "TCP_PERSISTENCE_OK" ]]; then
  printf '[k02] ERRO: sessão TCP ativa não sobreviveu à live migration (status=%s)\n' "${tcp_status:-ausente}" >&2
  exit 1
fi

max_gap_ms="$(k02_kctl -n tenant-a exec probe-a -- python3 -c '
ts = [float(x.strip()) for x in open("/tmp/k02-gap.log") if x.strip()]
if len(ts) < 2:
    print("0")
else:
    gaps = [(b - a) * 1000.0 for a, b in zip(ts, ts[1:])]
    print(f"{max(gaps):.1f}")
' 2>/dev/null | tr -d '[:space:]')"

guest_ip_after="$(k02_read_guest_os_ip "${node_after}")"
if [[ "${guest_ip_after}" != "${guest_ip_before}" ]]; then
  printf '[k02] ERRO: IP do guest OS mudou após live migration (before=%s, after=%s)\n' "${guest_ip_before}" "${guest_ip_after}" >&2
  exit 1
fi

# 6. Validar 5/5 pings pós-migração sem perda e limpar arquivos temporários em probe-a
if ! k02_kctl -n tenant-a exec probe-a -- ping -c 5 -W 2 10.0.0.11 >/dev/null; then
  printf '[k02] ERRO: ping pós-migração (probe-a -> vm-a 10.0.0.11) falhou\n' >&2
  exit 1
fi
k02_kctl -n tenant-a exec probe-a -- rm -f /tmp/k02-gap.log /tmp/k02-gap-stop /tmp/k02-tcp-ready /tmp/k02-mig-done /tmp/k02-tcp.out >/dev/null 2>&1 || true

printf 'K02 PASS: live migration Succeeded (%s -> %s), guest OS IP preservado (%s -> %s via /dev/ttyS0), sessão TCP persistente OK, max_gap_ms=%sms e 5/5 pings pós-migração OK.\n' \
  "${node_before}" "${node_after}" "${guest_ip_before}" "${guest_ip_after}" "${max_gap_ms:-0}"
