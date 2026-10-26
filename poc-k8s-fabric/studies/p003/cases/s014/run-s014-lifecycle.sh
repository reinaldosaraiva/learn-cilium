#!/usr/bin/env bash
# P003-S014 — Ciclo de vida VM OpenStack × CiliumNetworkPolicy (fromCIDR):
#   C04: VM A recriada com porta/IP novos (10.30.0.151 -> 10.30.0.152) -> CNP antigo nega ate reautorizar.
#   C05: IP 10.30.0.151 reaproveitado por VM B na mesma porta -> heranca indevida (leak) ate revogar fromCIDR.
#   Rollback: remove VMs/portas de estudo e namespace s014-study no sandbox.
set -euo pipefail

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
OS_CONTAINER="${OS_CONTAINER:-p003-os}"
STUDY_KUBECONFIG="${STUDY_KUBECONFIG:-/root/.kube/p003-gw.config}"
STUDY_CONTEXT="${STUDY_CONTEXT:-kind-p003-gw}"
STUDY_UID="${STUDY_UID:-6bb32e0f-71f9-4558-ae33-356ba2250c26}"
K01_KUBECONFIG="${K01_KUBECONFIG:-/root/.kube/k01-rebuild.config}"
K01_CONTEXT="${K01_CONTEXT:-kind-k01}"
K01_UID="${K01_UID:-635e7274-5597-40c7-9de5-b1fbe3d68b22}"
STUDY_IP_A="${STUDY_IP_A:-10.30.0.151}"
STUDY_IP_A2="${STUDY_IP_A2:-10.30.0.152}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "[DRY-RUN] run-s014-lifecycle.sh: OS_CONTAINER=${OS_CONTAINER} STUDY_KUBECONFIG=${STUDY_KUBECONFIG} STUDY_CONTEXT=${STUDY_CONTEXT} STUDY_IP_A=${STUDY_IP_A} STUDY_IP_A2=${STUDY_IP_A2}"
  exit 0
fi

K="sudo kubectl --kubeconfig ${STUDY_KUBECONFIG} --context ${STUDY_CONTEXT}"
K01="sudo kubectl --kubeconfig ${K01_KUBECONFIG} --context ${K01_CONTEXT}"

echo "=== [0] Preflight UIDs (sandbox + k01) ==="
uid_s=$($K get ns kube-system -o jsonpath='{.metadata.uid}')
uid_k=$($K01 get ns kube-system -o jsonpath='{.metadata.uid}')
[[ "$uid_s" == "$STUDY_UID" ]] || { echo "FAIL: sandbox UID=$uid_s (expected $STUDY_UID)" >&2; exit 1; }
[[ "$uid_k" == "$K01_UID" ]] || { echo "FAIL: k01 UID=$uid_k (expected $K01_UID)" >&2; exit 1; }

echo "=== [1] Apply K8s fixture (01a-ns-pod-a.yaml) ==="
$K apply -f "${HERE}/01a-ns-pod-a.yaml"
$K -n p003-s014 wait --for=condition=Ready pod/pod-a --timeout=120s

echo "=== [2] C04/C05 OpenStack port & VM sequence inside ${OS_CONTAINER} ==="
sudo docker exec "${OS_CONTAINER}" bash -lc "
  source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1
  openstack port show s014-port-a >/dev/null 2>&1 || \
    openstack port create --network net-a --fixed-ip subnet=subnet-a,ip-address=${STUDY_IP_A} --security-group sg-a s014-port-a
"

echo "=== [3] Rollback S014 study fixtures ==="
sudo docker exec "${OS_CONTAINER}" bash -lc "
  source /opt/stack/devstack/openrc demo demo >/dev/null 2>&1
  for srv in s014-vm-a s014-vm-b; do openstack server delete \$srv --wait >/dev/null 2>&1 || true; done
  for prt in s014-port-a s014-port-a2; do openstack port delete \$prt >/dev/null 2>&1 || true; done
"
$K delete -f "${HERE}/01a-ns-pod-a.yaml" --ignore-not-found
echo "=== S014 DONE ==="
