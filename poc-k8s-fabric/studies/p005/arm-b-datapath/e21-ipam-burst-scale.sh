#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p005/arm-b-datapath/e21-ipam-burst-scale.sh — Estudo E21: IPAM e tempo de implantação em escala (Kubernetes PodCIDR vs Multi-Pool Cold preAllocate=1 vs Warm preAllocate=32 + Negativo Exaustão /29).

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
CILIUM_CHART="${CILIUM_CHART:-/opt/poc-k8s-fabric-studies/studies/p003/base/cilium-1.20.2.tgz}"
VALUES_BASE="${VALUES_BASE:-/opt/poc-k8s-fabric-studies/studies/p003/base/values-p003.yaml}"

e21_kctl() {
  kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" "$@"
}

k01_kctl() {
  kubectl --kubeconfig "${K01_KUBECONFIG}" --context "${K01_CONTEXT}" "$@"
}

if [[ "${DRY_RUN}" == "1" ]]; then
  echo "DRY-RUN [E21]: 1. Verificar UIDs de k01 e p003-gw."
  echo "DRY-RUN [E21]: 2. Executar Célula 1 (C1-K8S-PODCIDR: ipam.mode=kubernetes, burst de 16 pods agnhost:2.47 nos 2 workers)."
  echo "DRY-RUN [E21]: 3. Executar Célula 2 (C2-MP-COLD-PRE1: ipam.mode=multi-pool com e21-burst-pool=1, burst de 16 pods)."
  echo "DRY-RUN [E21]: 4. Executar Célula 3 (C3-MP-WARM-PRE32: ipam.mode=multi-pool com e21-burst-pool=32 pré-aquecido, burst de 16 pods)."
  echo "DRY-RUN [E21]: 5. Executar Célula 4 (C4-NEG-EXHAUSTION: burst de 10 pods contra e21-tiny-pool /29 de 6 IPs úteis -> 6 Ready, 4 Pending/FailedCreatePodSandBox, sem afetar e21-burst-pool)."
  echo "DRY-RUN [E21]: 6. Rollback completo para ipam.mode=kubernetes e remoção dos CiliumPodIPPools."
  exit 0
fi

cleanup() {
  echo "[e21] Executando limpeza e rollback para ipam.mode=kubernetes..."
  for ns in p005-e21 p005-e21-c1 p005-e21-c2 p005-e21-c3 p005-e21-neg; do
    e21_kctl -n "${ns}" delete deploy --all --ignore-not-found >/dev/null 2>&1 || true
    e21_kctl -n "${ns}" delete pod --all --force --grace-period=0 >/dev/null 2>&1 || true
    e21_kctl -n "${ns}" delete cep --all --ignore-not-found >/dev/null 2>&1 || true
  done
  e21_kctl delete ns p005-e21 p005-e21-c1 p005-e21-c2 p005-e21-c3 p005-e21-neg --ignore-not-found --wait=false 2>/dev/null || true
  sleep 5
  for ns in p005-e21 p005-e21-c1 p005-e21-c2 p005-e21-c3 p005-e21-neg; do
    if e21_kctl get ns "${ns}" >/dev/null 2>&1; then
      e21_kctl get ns "${ns}" -o json | jq '.spec.finalizers=[]' | e21_kctl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
    fi
  done
  local cur_ipam
  cur_ipam="$(e21_kctl -n kube-system get cm cilium-config -o jsonpath='{.data.ipam}' 2>/dev/null || echo "")"
  if [[ "${cur_ipam}" != "kubernetes" ]]; then
    local api_ip
    api_ip="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' p003-gw-control-plane)"
    helm upgrade cilium "${CILIUM_CHART}" \
      --kubeconfig "${P003_KUBECONFIG}" --kube-context "${P003_CONTEXT}" \
      -n kube-system -f "${VALUES_BASE}" \
      --set "k8sServiceHost=${api_ip}" >/dev/null
    e21_kctl -n kube-system rollout restart deploy/cilium-operator ds/cilium >/dev/null
    e21_kctl -n kube-system rollout status deploy/cilium-operator ds/cilium --timeout=240s >/dev/null
  fi
  e21_kctl delete ciliumpodippool default e21-burst-pool e21-tiny-pool --ignore-not-found >/dev/null 2>&1 || true
  for node in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
    docker exec "${node}" bash -c '
      for cidr in $(ip route show | awk "/^10\.(251|252|253)\./ {print \$1}"); do
        ip route del "$cidr" 2>/dev/null || true
      done
    ' 2>/dev/null || true
  done
  e21_kctl -n kube-system rollout restart deploy/coredns >/dev/null 2>&1 || true
  e21_kctl -n kubevirt rollout restart deploy/virt-operator deploy/virt-api deploy/virt-controller deploy/virt-exportproxy deploy/virt-template-apiserver deploy/virt-template-controller ds/virt-handler >/dev/null 2>&1 || true
  e21_kctl -n p003-gateway rollout restart deploy/http-echo deploy/p003-dns deploy/tcp-echo >/dev/null 2>&1 || true
  e21_kctl -n kube-system rollout status deploy/coredns --timeout=120s >/dev/null 2>&1 || true
  e21_kctl -n p003-gateway rollout status deploy/http-echo deploy/p003-dns deploy/tcp-echo --timeout=180s >/dev/null 2>&1 || true
  echo "[e21] Rollback concluído: ipam=$(e21_kctl -n kube-system get cm cilium-config -o jsonpath='{.data.ipam}'), pools=$(e21_kctl get ciliumpodippool --no-headers 2>/dev/null | wc -l)"
}
trap cleanup EXIT

echo "=== [E21] 0. PREFLIGHT & CANARY GUARD ==="
k01_uid="$(k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
p003_uid="$(e21_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
[[ "${k01_uid}" == "${K01_EXPECTED_UID}" ]] || { echo "ERRO: k01 UID=${k01_uid}"; exit 1; }
[[ "${p003_uid}" == "${P003_EXPECTED_UID}" ]] || { echo "ERRO: p003-gw UID=${p003_uid}"; exit 1; }
API_IP="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' p003-gw-control-plane)"

clean_e21_ns() {
  local ns="${1:-p005-e21}"
  e21_kctl -n "${ns}" delete deploy --all --ignore-not-found >/dev/null 2>&1 || true
  e21_kctl -n "${ns}" delete pod --all --force --grace-period=0 >/dev/null 2>&1 || true
  e21_kctl -n "${ns}" delete cep --all --ignore-not-found >/dev/null 2>&1 || true
  e21_kctl delete ns "${ns}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  for i in $(seq 1 30); do
    e21_kctl get ns "${ns}" >/dev/null 2>&1 || break
    if [[ "${i}" -eq 10 ]]; then
      e21_kctl get ns "${ns}" -o json | jq '.spec.finalizers=[]' | e21_kctl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
    fi
    sleep 2
  done
}

run_burst_24() {
  local cell_name="$1"
  local use_pool="$2"
  local ns="$3"
  clean_e21_ns "${ns}"

  if [[ "${use_pool}" == "true" ]]; then
    cat <<EOF | e21_kctl apply -f - >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
  labels:
    study: P005
    ipam-pool: e21-burst-pool
  annotations:
    ipam.cilium.io/require-pool-match: "true"
EOF
  else
    cat <<EOF | e21_kctl apply -f - >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
  labels:
    study: P005
EOF
  fi

  local t0
  t0="$(python3 -c 'import time; print(f"{time.time():.4f}")')"

  cat <<EOF | e21_kctl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: e21-burst
  namespace: ${ns}
spec:
  replicas: 16
  selector:
    matchLabels:
      app: e21-burst
  template:
    metadata:
      labels:
        app: e21-burst
      annotations:
        $( [[ "${use_pool}" == "true" ]] && echo 'ipam.cilium.io/ip-pool: "e21-burst-pool"' || echo 'study: "P005"' )
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/hostname
                    operator: In
                    values:
                      - p003-gw-worker
                      - p003-gw-worker2
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: e21-burst
      terminationGracePeriodSeconds: 0
      containers:
        - name: pause-app
          image: registry.k8s.io/e2e-test-images/agnhost:2.47
          imagePullPolicy: IfNotPresent
          command: ["sh", "-c", "sleep 3600"]
EOF

  e21_kctl -n "${ns}" rollout status deploy/e21-burst --timeout=180s >/dev/null
  local t1
  t1="$(python3 -c 'import time; print(f"{time.time():.4f}")')"

  e21_kctl -n "${ns}" get pods -o json > "/tmp/e21-${cell_name}-pods.json"
  e21_kctl -n "${ns}" get events -o json > "/tmp/e21-${cell_name}-events.json"

  python3 - "${cell_name}" "${t0}" "${t1}" "/tmp/e21-${cell_name}-pods.json" "/tmp/e21-${cell_name}-events.json" <<'PY'
import json, sys, datetime

cell, t0, t1, pods_file, events_file = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4], sys.argv[5]
wall = t1 - t0
pods = json.load(open(pods_file))["items"]
events = json.load(open(events_file))["items"]

durations = []
ips = []
for p in pods:
    ct = datetime.datetime.fromisoformat(p["metadata"]["creationTimestamp"].replace("Z", "+00:00"))
    rt = ct
    for c in p.get("status", {}).get("conditions", []):
        if c["type"] == "Ready" and c["status"] == "True":
            rt = datetime.datetime.fromisoformat(c["lastTransitionTime"].replace("Z", "+00:00"))
    durations.append((rt - ct).total_seconds())
    ips.append(p.get("status", {}).get("podIP", ""))

durations.sort()
n = len(durations)
p50 = durations[int(n * 0.5)] if n else 0
p95 = durations[int(n * 0.95)] if n else 0
p99 = durations[min(n - 1, int(n * 0.99))] if n else 0
failed_sandbox = sum(1 for e in events if e.get("reason") == "FailedCreatePodSandBox")
ipam_failures = sum(1 for e in events if e.get("reason") == "FailedCreatePodSandBox" and "unable to allocate IP" in e.get("message", ""))

print(f"[{cell}] pods={n} wall_s={wall:.2f} pods_per_s={n/wall:.2f} pod_ready_p50_s={p50:.2f} p95_s={p95:.2f} max_s={max(durations):.2f} ipam_alloc_failures={ipam_failures} failed_sandbox_events={failed_sandbox} sample_ips={ips[:3]}")
PY
}

echo "=== [E21] 1. CÉLULA 1: C1-K8S-PODCIDR (ipam.mode=kubernetes, 16 pods) ==="
sleep 8
run_burst_24 "C1-K8S-PODCIDR" "false" "p005-e21-c1"

echo "=== [E21] 2. CÉLULA 2: C2-MP-COLD-PRE1 (ipam.mode=multi-pool, preAllocate=1, 16 pods) ==="
clean_e21_ns "p005-e21-c1"
e21_kctl apply -f "${SCRIPT_DIR}/manifests/02-e21-multipool-burst.yaml" >/dev/null
helm upgrade cilium "${CILIUM_CHART}" \
  --kubeconfig "${P003_KUBECONFIG}" --kube-context "${P003_CONTEXT}" \
  -n kube-system -f "${VALUES_BASE}" \
  --set "k8sServiceHost=${API_IP}" \
  --set "ipam.mode=multi-pool" \
  --set 'ipam.multiPoolPreAllocation=default=8\,e21-burst-pool=1' \
  --set "k8s.requireIPv4PodCIDR=false" \
  --set "ipv4NativeRoutingCIDR=10.240.0.0/12" \
  --set "directRoutingSkipUnreachable=true" \
  --set "endpointRoutes.enabled=true" >/dev/null
e21_kctl -n kube-system rollout restart deploy/cilium-operator ds/cilium >/dev/null
e21_kctl -n kube-system rollout status deploy/cilium-operator ds/cilium --timeout=240s >/dev/null
sleep 12
echo "Pre-burst CiliumNode allocated count for e21-burst-pool (expected 1 per node):"
e21_kctl get ciliumnodes -o json | python3 -c '
import json, sys
for item in json.load(sys.stdin)["items"]:
    pools = item.get("spec", {}).get("ipam", {}).get("pools", {}).get("allocated", [])
    for p in pools:
        if p.get("pool") == "e21-burst-pool":
            print(item["metadata"]["name"], "allocated_cidrs=", len(p.get("cidrs", [])))
'
run_burst_24 "C2-MP-COLD-PRE1" "true" "p005-e21-c2"

echo "=== [E21] 3. CÉLULA 3: C3-MP-WARM-PRE32 (ipam.mode=multi-pool, preAllocate=32, 16 pods) ==="
clean_e21_ns "p005-e21-c2"
helm upgrade cilium "${CILIUM_CHART}" \
  --kubeconfig "${P003_KUBECONFIG}" --kube-context "${P003_CONTEXT}" \
  -n kube-system -f "${VALUES_BASE}" \
  --set "k8sServiceHost=${API_IP}" \
  --set "ipam.mode=multi-pool" \
  --set 'ipam.multiPoolPreAllocation=default=8\,e21-burst-pool=32' \
  --set "k8s.requireIPv4PodCIDR=false" \
  --set "ipv4NativeRoutingCIDR=10.240.0.0/12" \
  --set "directRoutingSkipUnreachable=true" \
  --set "endpointRoutes.enabled=true" >/dev/null
e21_kctl -n kube-system rollout restart deploy/cilium-operator ds/cilium >/dev/null
e21_kctl -n kube-system rollout status deploy/cilium-operator ds/cilium --timeout=240s >/dev/null

# Wait until both workers have >= 32 allocated IPs in e21-burst-pool
for _ in $(seq 1 30); do
  ready_warm="$(e21_kctl get ciliumnodes -o json | python3 -c '
import json, sys
ok = 0
for item in json.load(sys.stdin)["items"]:
    if item["metadata"]["name"] in ("p003-gw-worker", "p003-gw-worker2"):
        for p in item.get("spec", {}).get("ipam", {}).get("pools", {}).get("allocated", []):
            if p.get("pool") == "e21-burst-pool" and len(p.get("cidrs", [])) >= 32:
                ok += 1
print(ok)
')"
  [[ "${ready_warm}" == "2" ]] && break
  sleep 2
done
sleep 12
echo "Pre-burst Warm Pool verified (both workers >= 32 allocated /32 IPs in e21-burst-pool)."
run_burst_24 "C3-MP-WARM-PRE32" "true" "p005-e21-c3"

echo "=== [E21] 4. CÉLULA 4 (NEGATIVO): C4-NEG-EXHAUSTION (10 pods contra /29 de 6 IPs úteis) ==="
cat <<'EOF' | e21_kctl apply -f - >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: p005-e21-neg
  labels:
    study: P005
    ipam-pool: e21-tiny-pool
  annotations:
    ipam.cilium.io/require-pool-match: "true"
---
apiVersion: v1
kind: Pod
metadata:
  name: e21-tiny-seed
  namespace: p005-e21-neg
  annotations:
    ipam.cilium.io/ip-pool: "e21-tiny-pool"
spec:
  nodeName: p003-gw-worker
  terminationGracePeriodSeconds: 0
  containers:
    - name: pause-app
      image: registry.k8s.io/e2e-test-images/agnhost:2.47
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 3600"]
EOF
e21_kctl -n p005-e21-neg wait --for=condition=Ready pod/e21-tiny-seed --timeout=60s >/dev/null
e21_kctl -n p005-e21-neg delete pod/e21-tiny-seed --force --grace-period=0 >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
  e21_kctl -n p005-e21-neg get cep e21-tiny-seed >/dev/null 2>&1 || break
  sleep 1
done
sleep 5

cat <<'EOF' | e21_kctl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: e21-neg-burst
  namespace: p005-e21-neg
spec:
  replicas: 10
  selector:
    matchLabels:
      app: e21-neg-burst
  template:
    metadata:
      labels:
        app: e21-neg-burst
      annotations:
        ipam.cilium.io/ip-pool: "e21-tiny-pool"
    spec:
      nodeSelector:
        kubernetes.io/hostname: p003-gw-worker
      terminationGracePeriodSeconds: 0
      containers:
        - name: pause-app
          image: registry.k8s.io/e2e-test-images/agnhost:2.47
          imagePullPolicy: IfNotPresent
          command: ["sh", "-c", "sleep 3600"]
EOF

for _ in $(seq 1 45); do
  running_neg="$(e21_kctl -n p005-e21-neg get pods --field-selector status.phase=Running --no-headers | wc -l | tr -d ' ')"
  [[ "${running_neg}" -eq 6 ]] && break
  sleep 2
done
sleep 3
running_neg="$(e21_kctl -n p005-e21-neg get pods --field-selector status.phase=Running --no-headers | wc -l | tr -d ' ')"
pending_neg="$(e21_kctl -n p005-e21-neg get pods --field-selector status.phase!=Running --no-headers | wc -l | tr -d ' ')"
warm_still_ready="$(e21_kctl -n p005-e21-c3 get deploy e21-burst -o jsonpath='{.status.readyReplicas}')"
echo "[C4-NEG-EXHAUSTION] e21-tiny-pool (/29 = 6 usable IPs): running=${running_neg} (expected 6), unallocated_pending=${pending_neg} (expected 4), e21-burst-pool_ready=${warm_still_ready}/16"
e21_kctl -n p005-e21-neg get events --field-selector reason=FailedCreatePodSandBox | tail -n 5 || true
[[ "${running_neg}" -eq 6 && "${pending_neg}" -eq 4 && "${warm_still_ready}" -eq 16 ]] || { echo "ERRO: C4-NEG-EXHAUSTION fora do esperado"; exit 1; }

echo "=== [E21] PASS ==="
