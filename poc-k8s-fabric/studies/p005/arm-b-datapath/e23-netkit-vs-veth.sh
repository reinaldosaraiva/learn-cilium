#!/usr/bin/env bash
# shellcheck shell=bash
# studies/p005/arm-b-datapath/e23-netkit-vs-veth.sh — Estudo E23: Netkit versus veth no datapath de containers (Microbenchmark Kernel + Cluster Cilium 1.20.2 + Controle Negativo CNP + Rollback).

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
NS="p005-e23"

e23_kctl() {
  kubectl --kubeconfig "${P003_KUBECONFIG}" --context "${P003_CONTEXT}" "$@"
}

k01_kctl() {
  kubectl --kubeconfig "${K01_KUBECONFIG}" --context "${K01_CONTEXT}" "$@"
}

if [[ "${DRY_RUN}" == "1" ]]; then
  echo "DRY-RUN [E23]: 1. Verificar UIDs de k01 (${K01_EXPECTED_UID}) e p003-gw (${P003_EXPECTED_UID}) e suporte CONFIG_NETKIT=y."
  echo "DRY-RUN [E23]: 2. Executar Parte A (Microbenchmark Kernel): par veth vs par netkit (via iproute2 do container cilium) medindo RTT ICMP p50/p95/p99, TCP RR e throughput."
  echo "DRY-RUN [E23]: 3. Executar Parte B1 (Cilium datapathMode=veth): criar pods em ${NS}, verificar info_kind=veth, medir latência/throughput same-node e cross-node."
  echo "DRY-RUN [E23]: 4. Executar Parte B2 (Cilium bpf.datapathMode=netkit): helm upgrade cilium, recriar pods em ${NS}, verificar info_kind=netkit, medir latência/throughput same-node e cross-node."
  echo "DRY-RUN [E23]: 5. Executar Controle Negativo (CiliumNetworkPolicy e23-allow-only-allowed-role sob netkit): allowed=30/30 vs denied=0/30."
  echo "DRY-RUN [E23]: 6. Rollback completo para bpf.datapathMode=veth e remoção de ${NS}."
  exit 0
fi

scale_down_bg_workloads() {
  echo "[e23] Pausando workloads CNI de background para transição limpa de datapath-mode..."
  e23_kctl -n kubevirt scale deploy/virt-operator --replicas=0 >/dev/null 2>&1 || true
  e23_kctl -n kubevirt scale deploy/virt-api deploy/virt-controller deploy/virt-exportproxy deploy/virt-template-apiserver deploy/virt-template-controller --replicas=0 >/dev/null 2>&1 || true
  e23_kctl -n kubevirt patch ds virt-handler -p '{"spec":{"template":{"spec":{"nodeSelector":{"e23-pause":"true"}}}}}' >/dev/null 2>&1 || true
  e23_kctl -n kube-system scale deploy/coredns --replicas=0 >/dev/null 2>&1 || true
  e23_kctl -n local-path-storage scale deploy/local-path-provisioner --replicas=0 >/dev/null 2>&1 || true
  e23_kctl -n p003-gateway scale deploy/http-echo deploy/p003-dns deploy/tcp-echo --replicas=0 >/dev/null 2>&1 || true
  for ns in kubevirt p003-gateway local-path-storage; do
    e23_kctl -n "${ns}" wait --for=delete pod --all --timeout=60s >/dev/null 2>&1 || true
  done
  e23_kctl -n kube-system wait --for=delete pod -l k8s-app=kube-dns --timeout=60s >/dev/null 2>&1 || true
}

restore_bg_workloads() {
  echo "[e23] Restaurando workloads CNI de background sob datapath-mode=veth..."
  e23_kctl -n kube-system scale deploy/coredns --replicas=2 >/dev/null 2>&1 || true
  e23_kctl -n local-path-storage scale deploy/local-path-provisioner --replicas=1 >/dev/null 2>&1 || true
  e23_kctl -n p003-gateway scale deploy/http-echo --replicas=3 >/dev/null 2>&1 || true
  e23_kctl -n p003-gateway scale deploy/p003-dns --replicas=1 >/dev/null 2>&1 || true
  e23_kctl -n p003-gateway scale deploy/tcp-echo --replicas=1 >/dev/null 2>&1 || true
  e23_kctl -n kubevirt patch ds virt-handler --type=json -p='[{"op":"remove","path":"/spec/template/spec/nodeSelector/e23-pause"}]' >/dev/null 2>&1 || true
  e23_kctl -n kubevirt scale deploy/virt-api deploy/virt-controller deploy/virt-exportproxy --replicas=2 >/dev/null 2>&1 || true
  e23_kctl -n kubevirt scale deploy/virt-template-apiserver deploy/virt-template-controller --replicas=1 >/dev/null 2>&1 || true
  e23_kctl -n kubevirt scale deploy/virt-operator --replicas=2 >/dev/null 2>&1 || true
  e23_kctl -n kubevirt rollout restart deploy/virt-api deploy/virt-controller deploy/virt-exportproxy deploy/virt-template-apiserver deploy/virt-template-controller >/dev/null 2>&1 || true
  e23_kctl -n kube-system rollout status deploy/coredns --timeout=180s >/dev/null 2>&1 || true
  e23_kctl -n kubevirt rollout status deploy/virt-api deploy/virt-template-apiserver --timeout=180s >/dev/null 2>&1 || true
  e23_kctl -n p003-gateway rollout status deploy/http-echo --timeout=180s >/dev/null 2>&1 || true
  e23_kctl -n p003-gateway rollout status deploy/p003-dns --timeout=180s >/dev/null 2>&1 || true
  e23_kctl -n p003-gateway rollout status deploy/tcp-echo --timeout=180s >/dev/null 2>&1 || true
}

cleanup() {
  echo "[e23] Executando limpeza e rollback para bpf.datapathMode=veth..."
  ip netns del e23-ns-a 2>/dev/null || true
  ip netns del e23-ns-b 2>/dev/null || true
  ip netns del e23-nk-a 2>/dev/null || true
  ip netns del e23-nk-b 2>/dev/null || true
  e23_kctl delete pod e23-veth-guard-canary -n default --ignore-not-found --force --grace-period=0 >/dev/null 2>&1 || true
  e23_kctl delete ns "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  sleep 3
  e23_kctl -n "${NS}" delete pod --all --force --grace-period=0 >/dev/null 2>&1 || true
  e23_kctl delete ns "${NS}" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true

  local cur_dp
  cur_dp="$(e23_kctl -n kube-system get cm cilium-config -o jsonpath='{.data.datapath-mode}' 2>/dev/null || echo "")"
  if [[ "${cur_dp}" != "veth" ]]; then
    local api_ip
    api_ip="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' p003-gw-control-plane)"
    helm upgrade cilium "${CILIUM_CHART}" \
      --kubeconfig "${P003_KUBECONFIG}" --kube-context "${P003_CONTEXT}" \
      -n kube-system -f "${VALUES_BASE}" \
      --set "k8sServiceHost=${api_ip}" \
      --set "bpf.datapathMode=veth" >/dev/null
    for n in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
      docker exec "${n}" sh -c 'rm -rf /var/run/cilium/state/[0-9]*' 2>/dev/null || true
    done
    e23_kctl -n kube-system delete pod -l k8s-app=cilium --wait=true >/dev/null 2>&1 || true
    e23_kctl -n kube-system wait --for=condition=Ready pod -l k8s-app=cilium --timeout=240s >/dev/null
  fi
  restore_bg_workloads
  echo "[e23] Rollback concluído: datapath-mode=$(e23_kctl -n kube-system get cm cilium-config -o jsonpath='{.data.datapath-mode}')"
}
trap cleanup EXIT

echo "=== [E23] 0. PREFLIGHT & CANARY GUARD ==="
k01_uid="$(k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
p003_uid="$(e23_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
[[ "${k01_uid}" == "${K01_EXPECTED_UID}" ]] || { echo "ERRO: k01 UID=${k01_uid}"; exit 1; }
[[ "${p003_uid}" == "${P003_EXPECTED_UID}" ]] || { echo "ERRO: p003-gw UID=${p003_uid}"; exit 1; }
echo "Canaries OK: k01=${k01_uid} p003-gw=${p003_uid}"
init_dp="$(e23_kctl -n kube-system get cm cilium-config -o jsonpath='{.data.datapath-mode}' 2>/dev/null || echo "")"
if [[ "${init_dp}" != "veth" ]]; then
  echo "[e23] Estado inicial datapath-mode=${init_dp}; normalizando para veth antes do inicio..."
  cleanup
fi

echo "=== [E23] 1. PARTE A — MICROBENCHMARK ISOLADO NO KERNEL (VETH VS NETKIT) ==="
CILIUM_W1_POD="$(e23_kctl -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=p003-gw-worker -o jsonpath='{.items[0].metadata.name}')"
host_ip_nk() {
  # Usa iproute2 moderno do container cilium no netns do host (ou worker)
  docker exec --privileged p003-gw-worker "$@"
}

# Microbenchmark dentro de p003-gw-worker usando o iproute2 do cilium-agent (que suporta type netkit nativamente)
tar -chf - /usr/bin/ping /lib/x86_64-linux-gnu/libidn2.so.0 /lib/x86_64-linux-gnu/libunistring.so.5 /lib/x86_64-linux-gnu/libcap.so.2 2>/dev/null \
  | e23_kctl -n kube-system exec -i "${CILIUM_W1_POD}" -c cilium-agent -- tar -xf - -C /

# shellcheck disable=SC2016
e23_kctl -n kube-system exec "${CILIUM_W1_POD}" -c cilium-agent -- bash -ce '
  ip netns del e23-ns-a 2>/dev/null || true
  ip netns del e23-ns-b 2>/dev/null || true
  ip netns del e23-nk-a 2>/dev/null || true
  ip netns del e23-nk-b 2>/dev/null || true

  # 1. VETH pair
  ip netns add e23-ns-a
  ip netns add e23-ns-b
  ip link add e23-veth0 netns e23-ns-a type veth peer name e23-veth1 netns e23-ns-b
  ip -n e23-ns-a addr add 10.233.1.1/24 dev e23-veth0
  ip -n e23-ns-b addr add 10.233.1.2/24 dev e23-veth1
  ip -n e23-ns-a link set lo up && ip -n e23-ns-a link set e23-veth0 mtu 1500 up
  ip -n e23-ns-b link set lo up && ip -n e23-ns-b link set e23-veth1 mtu 1500 up

  # 2. NETKIT L3 pair
  ip netns add e23-nk-a
  ip netns add e23-nk-b
  ip link add e23-nk0 type netkit mode l3 peer name e23-nk1
  ip link set e23-nk1 netns e23-nk-b
  ip link set e23-nk0 netns e23-nk-a
  ip -n e23-nk-a addr add 10.233.2.1/24 dev e23-nk0
  ip -n e23-nk-b addr add 10.233.2.2/24 dev e23-nk1
  ip -n e23-nk-a link set lo up && ip -n e23-nk-a link set e23-nk0 mtu 1500 up
  ip -n e23-nk-b link set lo up && ip -n e23-nk-b link set e23-nk1 mtu 1500 up

  echo "--- MB Link Info ---"
  ip -n e23-ns-a -d link show e23-veth0
  ip -n e23-nk-a -d link show e23-nk0

  echo "--- MB Ping 100 samples VETH ---"
  ip netns exec e23-ns-a /usr/bin/ping -c 100 -i 0.005 10.233.1.2 | tee /tmp/mb-veth.txt | tail -n 3
  grep "time=" /tmp/mb-veth.txt | sed -E "s/.*time=([0-9.]+).*/\1/" | sort -n | awk "{a[NR]=\$1; sum+=\$1} END {printf \"mb_icmp_veth count=%d avg_ms=%.3f p50_ms=%.3f p95_ms=%.3f p99_ms=%.3f\n\", NR, sum/NR, a[int(NR*0.5)], a[int(NR*0.95)], a[int(NR*0.99)]}"

  echo "--- MB Ping 100 samples NETKIT ---"
  ip netns exec e23-nk-a /usr/bin/ping -c 100 -i 0.005 10.233.2.2 | tee /tmp/mb-nk.txt | tail -n 3
  grep "time=" /tmp/mb-nk.txt | sed -E "s/.*time=([0-9.]+).*/\1/" | sort -n | awk "{a[NR]=\$1; sum+=\$1} END {printf \"mb_icmp_netkit count=%d avg_ms=%.3f p50_ms=%.3f p95_ms=%.3f p99_ms=%.3f\n\", NR, sum/NR, a[int(NR*0.5)], a[int(NR*0.95)], a[int(NR*0.99)]}"

  ip netns del e23-ns-a
  ip netns del e23-ns-b
  ip netns del e23-nk-a
  ip netns del e23-nk-b
'

run_cluster_cell() {
  local mode_label="$1"
  echo "=== [E23] CLUSTER CELL: ${mode_label} ==="
  e23_kctl delete ns "${NS}" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
  e23_kctl apply -f "${SCRIPT_DIR}/manifests/01-e23-pods-and-cnp.yaml"
  e23_kctl -n "${NS}" wait --for=condition=Ready pod/e23-srv-w1 pod/e23-cli-same-w1 pod/e23-cli-cross-w2 pod/e23-cli-denied-w1 --timeout=120s

  local srv_ip
  srv_ip="$(e23_kctl -n "${NS}" get pod e23-srv-w1 -o jsonpath='{.status.podIP}')"
  echo "[${mode_label}] e23-srv-w1 IP=${srv_ip}"
  echo "[${mode_label}] Interface eth0 details inside e23-srv-w1:"
  e23_kctl -n "${NS}" exec e23-srv-w1 -- ip -d link show eth0
  local w1_cilium
  w1_cilium="$(e23_kctl -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=p003-gw-worker -o jsonpath='{.items[0].metadata.name}')"
  echo "[${mode_label}] Cilium datapath loader attachment logs on p003-gw-worker:"
  e23_kctl -n kube-system logs "${w1_cilium}" -c cilium-agent --tail=200 | grep "Program attached to device" | tail -n 6 || true

  echo "[${mode_label}] Same-Node Ping (50 samples):"
  e23_kctl -n "${NS}" exec e23-cli-same-w1 -- ping -c 50 -i 0.02 -q "${srv_ip}"

  echo "[${mode_label}] Cross-Node Ping (50 samples):"
  e23_kctl -n "${NS}" exec e23-cli-cross-w2 -- ping -c 50 -i 0.02 -q "${srv_ip}"

  echo "[${mode_label}] Same-Node HTTP RR (50 sequential requests):"
  e23_kctl -n "${NS}" exec e23-cli-same-w1 -- sh -c "
    for i in \$(seq 1 50); do
      curl -s -o /dev/null -w '%{time_total}\n' http://${srv_ip}:80/
    done | sort -n | awk '{a[NR]=\$1; sum+=\$1} END {printf \"http_rr_same count=%d avg_ms=%.3f p50_ms=%.3f p95_ms=%.3f p99_ms=%.3f\n\", NR, (sum/NR)*1000, a[int(NR*0.5)]*1000, a[int(NR*0.95)]*1000, a[int(NR*0.99)]*1000}'
  "

  echo "[${mode_label}] Cross-Node HTTP RR (50 sequential requests):"
  e23_kctl -n "${NS}" exec e23-cli-cross-w2 -- sh -c "
    for i in \$(seq 1 50); do
      curl -s -o /dev/null -w '%{time_total}\n' http://${srv_ip}:80/
    done | sort -n | awk '{a[NR]=\$1; sum+=\$1} END {printf \"http_rr_cross count=%d avg_ms=%.3f p50_ms=%.3f p95_ms=%.3f p99_ms=%.3f\n\", NR, (sum/NR)*1000, a[int(NR*0.5)]*1000, a[int(NR*0.95)]*1000, a[int(NR*0.99)]*1000}'
  "

  echo "[${mode_label}] Same-Node iperf3 TCP (5s) + softirq delta:"
  local rx_before tx_before rx_after tx_after
  rx_before="$(awk '/NET_RX:/ {for(i=2;i<=NF;i++) s+=$i; print s}' /proc/softirqs)"
  tx_before="$(awk '/NET_TX:/ {for(i=2;i<=NF;i++) s+=$i; print s}' /proc/softirqs)"
  e23_kctl -n "${NS}" exec e23-cli-same-w1 -- iperf3 -c "${srv_ip}" -t 5 | tail -n 5
  rx_after="$(awk '/NET_RX:/ {for(i=2;i<=NF;i++) s+=$i; print s}' /proc/softirqs)"
  tx_after="$(awk '/NET_TX:/ {for(i=2;i<=NF;i++) s+=$i; print s}' /proc/softirqs)"
  echo "[${mode_label}] Same-Node iperf3 softirq_delta: NET_RX=$((rx_after - rx_before)) NET_TX=$((tx_after - tx_before))"

  echo "[${mode_label}] Cross-Node iperf3 TCP (5s) + softirq delta:"
  rx_before="$(awk '/NET_RX:/ {for(i=2;i<=NF;i++) s+=$i; print s}' /proc/softirqs)"
  tx_before="$(awk '/NET_TX:/ {for(i=2;i<=NF;i++) s+=$i; print s}' /proc/softirqs)"
  e23_kctl -n "${NS}" exec e23-cli-cross-w2 -- iperf3 -c "${srv_ip}" -t 5 | tail -n 5
  rx_after="$(awk '/NET_RX:/ {for(i=2;i<=NF;i++) s+=$i; print s}' /proc/softirqs)"
  tx_after="$(awk '/NET_TX:/ {for(i=2;i<=NF;i++) s+=$i; print s}' /proc/softirqs)"
  echo "[${mode_label}] Cross-Node iperf3 softirq_delta: NET_RX=$((rx_after - rx_before)) NET_TX=$((tx_after - tx_before))"
}

echo "=== [E23] 2. PARTE B1 — CLUSTER CILIUM EM DATAPATH-MODE=VETH ==="
run_cluster_cell "VETH"

echo "=== [E23] 3. PARTE B2 — UPGRADE CILIUM PARA BPF.DATAPATHMODE=NETKIT ==="
echo "--- [E23] 3a. Drenagem limpa dos workers em modo veth + Prova do Guard Fail-Closed (endpoint-restore no control-plane) ---"
e23_kctl delete ns "${NS}" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
scale_down_bg_workloads

# Cria 1 pod canário veth exclusivamente no control-plane para provar o guard fail-closed sem sujar os workers
cat <<'EOF' | e23_kctl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: e23-veth-guard-canary
  namespace: default
spec:
  nodeName: p003-gw-control-plane
  tolerations:
    - operator: Exists
  containers:
    - name: pause
      image: alpine:3.20
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 3600"]
EOF
e23_kctl -n default wait --for=condition=Ready pod/e23-veth-guard-canary --timeout=60s

API_IP="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' p003-gw-control-plane)"
helm upgrade cilium "${CILIUM_CHART}" \
  --kubeconfig "${P003_KUBECONFIG}" --kube-context "${P003_CONTEXT}" \
  -n kube-system -f "${VALUES_BASE}" \
  --set "k8sServiceHost=${API_IP}" \
  --set "bpf.datapathMode=netkit" \
  --set "bpf.enableTCX=true" >/dev/null

e23_kctl -n kube-system delete pod -l k8s-app=cilium --wait=true >/dev/null
sleep 14
CP_CILIUM_POD="$(e23_kctl -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=p003-gw-control-plane -o jsonpath='{.items[0].metadata.name}')"
e23_kctl -n kube-system logs "${CP_CILIUM_POD}" --previous -c cilium-agent 2>/dev/null | grep -E "endpoint-restore|incompatible datapath-modes" || \
  e23_kctl -n kube-system logs "${CP_CILIUM_POD}" -c cilium-agent 2>/dev/null | grep -E "endpoint-restore|incompatible datapath-modes" || true

echo "--- [E23] 3b. Remoção do canário veth no control-plane e Rollout Completo em NETKIT ---"
e23_kctl -n default delete pod e23-veth-guard-canary --force --grace-period=0 >/dev/null 2>&1 || true
for n in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
  docker exec "${n}" sh -c 'rm -rf /var/run/cilium/state/[0-9]*'
done
e23_kctl -n kube-system delete pod -l k8s-app=cilium --field-selector spec.nodeName=p003-gw-control-plane --wait=true >/dev/null
e23_kctl -n kube-system wait --for=condition=Ready pod -l k8s-app=cilium --timeout=240s
echo "cilium-config datapath-mode=$(e23_kctl -n kube-system get cm cilium-config -o jsonpath='{.data.datapath-mode}')"

run_cluster_cell "NETKIT"

echo "=== [E23] 4. CONTROLE NEGATIVO: CILIUMNETWORKPOLICY SOB NETKIT ==="
SRV_IP="$(e23_kctl -n "${NS}" get pod e23-srv-w1 -o jsonpath='{.status.podIP}')"
DENIED_IP="$(e23_kctl -n "${NS}" get pod e23-cli-denied-w1 -o jsonpath='{.status.podIP}')"
cat <<'EOF' | e23_kctl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: e23-allow-only-allowed-role
  namespace: p005-e23
spec:
  endpointSelector:
    matchLabels:
      app: e23-srv
  ingress:
    - fromEndpoints:
        - matchLabels:
            role: allowed
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
            - port: "5201"
              protocol: TCP
EOF
sleep 4

allowed_ok=0
for _ in $(seq 1 30); do
  code="$(e23_kctl -n "${NS}" exec e23-cli-same-w1 -- curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://${SRV_IP}:80/" || echo "000")"
  [[ "${code}" == "200" ]] && allowed_ok=$((allowed_ok + 1))
done

# Inicia captura tcpdump na eth0 do servidor para provar 0 pacotes vazados do pod bloqueado
e23_kctl -n "${NS}" exec e23-srv-w1 -- sh -c "rm -f /tmp/cnp-denied.pcap && timeout 40 tcpdump -ni eth0 src host ${DENIED_IP} and tcp dst port 80 -w /tmp/cnp-denied.pcap >/dev/null 2>&1 &"
sleep 1

denied_ok=0
for _ in $(seq 1 30); do
  code="$(e23_kctl -n "${NS}" exec e23-cli-denied-w1 -- curl -s -o /dev/null -w '%{http_code}' --max-time 1 "http://${SRV_IP}:80/" || echo "000")"
  [[ "${code}" == "200" ]] && denied_ok=$((denied_ok + 1))
done

sleep 1
e23_kctl -n "${NS}" exec e23-srv-w1 -- pkill -INT tcpdump 2>/dev/null || true
sleep 1
leaked_pkts="$(e23_kctl -n "${NS}" exec e23-srv-w1 -- tcpdump -nr /tmp/cnp-denied.pcap 2>/dev/null | wc -l | tr -d ' ')"

echo "CNP Verdict under NETKIT: allowed_same_w1=${allowed_ok}/30 (expected 30/30), denied_same_w1=${denied_ok}/30 (expected 0/30), leaked_pkts_on_srv_eth0=${leaked_pkts} (expected 0)"
[[ "${allowed_ok}" -eq 30 && "${denied_ok}" -eq 0 && "${leaked_pkts}" -eq 0 ]] || { echo "ERRO: CNP verdict falhou sob netkit"; exit 1; }

echo "=== [E23] PASS ==="
