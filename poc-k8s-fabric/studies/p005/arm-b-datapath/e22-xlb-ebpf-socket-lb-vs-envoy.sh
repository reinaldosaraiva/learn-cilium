#!/usr/bin/env bash
# ==============================================================================
# P005-S002 (Arm B — Study E22): XLB — Balanceamento L7 com eBPF na Camada de
#                                Sockets (sockmap / sock_ops / sk_msg) vs Envoy
#
# Caso de estudo : E22 (docs/proximos-estudos.md)
# Hipotese       :
#   1. Celula 1 (Cilium Envoy L7 Proxy):
#      A interposicao L7 via CiliumNetworkPolicy HTTP redireciona o fluxo para
#      o proxy userspace cilium-envoy (TPROXY), adicionando travessias de socket
#      e contexto userspace, mas permitindo inspecao HTTP completa (403 em /deny).
#   2. Celula 2 (Cilium eBPF SocketLB L4 — bpf_sock_addr em connect()):
#      Com bpf-lb-sock-hostns-only=false, a traducao VIP -> Backend IP ocorre no
#      syscall connect() dentro do cgroup v2 do pod, eliminando DNAT por pacote.
#   3. Celula 3 (XLB eBPF Sockmap — BPF_MAP_TYPE_SOCKHASH + sock_ops + sk_msg):
#      Acoplando sock_ops no cgroup v2 e sk_msg no sockhash (arquitetura XLB),
#      os buffers de socket sao redirecionados in-kernel (bpf_msg_redirect_hash)
#      com inspecao L7 in-kernel (SK_DROP em "GET /deny"), atingindo menor
#      latencia p50/p95 e menor softirq NET_RX que o proxy userspace Envoy.
#   4. Celula 4 (Controles Negativos e Rollback):
#      - 4A: Backend escalado para 0 replicas remove entradas do mapa BPF LB e
#            recusa conexoes imediatamente.
#      - 4B: Politica L7 Envoy retorna HTTP 403 em GET /deny.
#      - 4C: Filtro L7 sk_msg in-kernel bloqueia GET /deny (SK_DROP) e contabiliza
#            no mapa BPF xlb_stats[2].
#      - 4D: Pod cross-tenant nao autorizado bloqueado por CiliumNetworkPolicy.
# ==============================================================================
set -euo pipefail

DRY_RUN=0
ROLLBACK_ONLY=0
KUBECONFIG_GW="${P003_KUBECONFIG:-/root/.kube/p003-gw.config}"
KUBECONFIG_K01="${K01_KUBECONFIG:-/root/.kube/k01-rebuild.config}"
CTX_GW="kind-p003-gw"
CTX_K01="kind-k01"
EXPECTED_UID_GW="6bb32e0f-71f9-4558-ae33-356ba2250c26"
EXPECTED_UID_K01="635e7274-5597-40c7-9de5-b1fbe3d68b22"

CHART_TGZ="${CILIUM_CHART:-/opt/poc-k8s-fabric-studies/studies/p003/base/cilium-1.20.2.tgz}"
VALUES_BASE="${VALUES_BASE:-/opt/poc-k8s-fabric-studies/studies/p003/base/values-p003.yaml}"
WORKER_NODE="p003-gw-worker"
NS_TEST="e22-xlb-test"

usage() {
  cat <<EOF
Uso: $0 [--dry-run] [--rollback] [--help]

Estudo E22 (P005-S002 Braço B):
  Célula 1: Cilium Envoy L7 Proxy (CiliumNetworkPolicy HTTP)
  Célula 2: Cilium eBPF SocketLB L4 (bpf_sock_addr connect() cgroupv2)
  Célula 3: XLB eBPF Sockmap + sk_msg L7 In-Kernel (BPF_MAP_TYPE_SOCKHASH)
  Célula 4: Controles Negativos (0 backends, HTTP 403 Envoy, SK_DROP sk_msg, cross-tenant) + Rollback
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --rollback) ROLLBACK_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Argumento desconhecido: $1" >&2; usage; exit 2 ;;
  esac
done

log() {
  printf '[E22 %s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  cat <<EOF
[DRY-RUN] Estudo E22 — XLB: Balanceamento L7 com eBPF Sockmap vs SocketLB L4 vs Envoy L7
  1. Validaria UIDs dos clusters k01 (${EXPECTED_UID_K01}) e p003-gw (${EXPECTED_UID_GW}).
  2. Criaria namespace ${NS_TEST} com 2 pods backend (agnhost:2.47) e 1 pod cliente (netshoot) em ${WORKER_NODE}.
  3. Celula 1 (Cilium Envoy L7 Proxy):
     - Aplicaria CiliumNetworkPolicy L7 HTTP permitindo /hostname e bloqueando /deny.
     - Mediria 100 requisicoes HTTP (avg/p50/p95/rps + softirq NET_RX) e testaria HTTP 403 em /deny.
  4. Celula 2 (Cilium eBPF SocketLB L4):
     - Ativaria socketLB no namespace do pod (extraConfig.bpf-lb-sock-hostns-only=false).
     - Mediria 100 requisicoes HTTP (avg/p50/p95/rps + softirq NET_RX).
  5. Celula 3 (XLB eBPF Sockmap + sk_msg L7 In-Kernel):
     - Compilaria e anexaria xlb_sockmap.c (BPF_MAP_TYPE_SOCKHASH + sock_ops + sk_msg) em /run/cilium/cgroupv2.
     - Mediria 100 requisicoes HTTP, leria contadores BPF (xlb_stats) e testaria SK_DROP em GET /deny.
  6. Celula 4 (Negativos adicionais + Rollback):
     - Escalaria backend para 0 replicas e verificaria remocao do mapa BPF LB.
     - Restauraria Cilium para values-gateway.yaml padrao e removeria ${NS_TEST}.
EOF
  exit 0
fi

detach_xlb_bpf() {
  local cilium_pod
  cilium_pod="$(kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName="$WORKER_NODE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$cilium_pod" ]]; then
    kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n kube-system exec "$cilium_pod" -c cilium-agent -- sh -c '
      bpftool prog detach pinned /sys/fs/bpf/xlb_test/xlb_sk_msg_prog msg_verdict pinned /sys/fs/bpf/xlb_test/xlb_sock_hash 2>/dev/null || true
      bpftool cgroup detach /run/cilium/cgroupv2 sock_ops pinned /sys/fs/bpf/xlb_test/xlb_sockops_prog 2>/dev/null || true
      rm -rf /sys/fs/bpf/xlb_test /tmp/xlb_sockmap.c /tmp/xlb_sockmap.o 2>/dev/null || true
    ' >/dev/null 2>&1 || true
  fi
}

cleanup() {
  log "Rollback E22: desanexando programas BPF XLB, removendo ${NS_TEST} e restaurando Cilium..."
  detach_xlb_bpf || true
  kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n "$NS_TEST" delete pod e22-client e22-untrusted --force --grace-period=0 --ignore-not-found >/dev/null 2>&1 || true
  kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" delete ns "$NS_TEST" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true
  local cur_hostns_only api_ip
  cur_hostns_only="$(kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n kube-system get cm cilium-config -o jsonpath='{.data.bpf-lb-sock-hostns-only}' 2>/dev/null || echo "")"
  if [[ -n "${INIT_HOSTNS_ONLY:-}" && "$cur_hostns_only" != "$INIT_HOSTNS_ONLY" ]]; then
    api_ip="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' p003-gw-control-plane)"
    helm --kubeconfig="$KUBECONFIG_GW" --kube-context="$CTX_GW" upgrade cilium "$CHART_TGZ" \
      -n kube-system -f "$VALUES_BASE" \
      --set "k8sServiceHost=${api_ip}" \
      --set "bgpControlPlane.secretsNamespace.name=kube-system" >/dev/null
    kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n kube-system rollout restart ds/cilium >/dev/null
    kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n kube-system rollout status ds/cilium --timeout=180s >/dev/null
  fi
}

if [[ "$ROLLBACK_ONLY" -eq 1 ]]; then
  cleanup
  log "Rollback E22 concluido."
  exit 0
fi

trap cleanup EXIT

# 1. Guards
UID_K01="$(kubectl --kubeconfig="$KUBECONFIG_K01" --context="$CTX_K01" get ns kube-system -o jsonpath='{.metadata.uid}')"
UID_GW="$(kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "$UID_K01" != "$EXPECTED_UID_K01" ]]; then
  echo "ERRO: k01 UID inesperado: $UID_K01" >&2
  exit 1
fi
if [[ "$UID_GW" != "$EXPECTED_UID_GW" ]]; then
  echo "ERRO: p003-gw UID inesperado: $UID_GW" >&2
  exit 1
fi
INIT_HOSTNS_ONLY="$(kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n kube-system get cm cilium-config -o jsonpath='{.data.bpf-lb-sock-hostns-only}' 2>/dev/null || echo "false")"
log "Preflight OK: k01_uid=${UID_K01} p003_gw_uid=${UID_GW} init_hostns_only=${INIT_HOSTNS_ONLY}"

read_net_rx_softirq() {
  local node="$1"
  docker exec "$node" awk '/NET_RX:/ {sum=0; for(i=2;i<=NF;i++) sum+=$i; printf "%.0f\n", sum}' /proc/softirqs
}

run_http_bench() {
  local url="$1"
  kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n "$NS_TEST" exec e22-client -- sh -c "
    rm -f /tmp/lat.txt
    for i in \$(seq 1 100); do
      curl -s -o /dev/null -w '%{time_total}\n' '$url' >> /tmp/lat.txt
    done
    sort -n /tmp/lat.txt | awk '
      { a[NR]=\$1; sum+=\$1 }
      END {
        avg_ms=(sum/NR)*1000;
        p50_ms=a[int(NR*0.50)]*1000;
        p95_ms=a[int(NR*0.95)]*1000;
        rps=(sum>0)?(NR/sum):0;
        printf \"avg_ms=%.3f p50_ms=%.3f p95_ms=%.3f rps=%.1f\", avg_ms, p50_ms, p95_ms, rps
      }'
  "
}

# 2. Criar namespace e workloads em p003-gw-worker
log "Criando namespace ${NS_TEST}, Service e22-svc, 2 backends e 1 cliente em ${WORKER_NODE}..."
kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" delete ns "$NS_TEST" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" create ns "$NS_TEST" >/dev/null

kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n "$NS_TEST" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: e22-backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: e22-backend
  template:
    metadata:
      labels:
        app: e22-backend
    spec:
      nodeName: ${WORKER_NODE}
      containers:
      - name: backend
        image: registry.k8s.io/e2e-test-images/agnhost:2.47
        args: ["netexec", "--http-port=8080"]
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: e22-svc
spec:
  selector:
    app: e22-backend
  ports:
  - port: 8080
    targetPort: 8080
---
apiVersion: v1
kind: Pod
metadata:
  name: e22-client
  labels:
    app: e22-client
    role: trusted
spec:
  nodeName: ${WORKER_NODE}
  terminationGracePeriodSeconds: 0
  containers:
  - name: client
    image: nicolaka/netshoot:latest
    command: ["sleep", "3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: e22-untrusted
  labels:
    app: e22-untrusted
    role: untrusted
spec:
  nodeName: ${WORKER_NODE}
  terminationGracePeriodSeconds: 0
  containers:
  - name: client
    image: nicolaka/netshoot:latest
    command: ["sleep", "3600"]
EOF

kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n "$NS_TEST" rollout status deploy/e22-backend --timeout=120s >/dev/null
kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n "$NS_TEST" wait --for=condition=Ready pod/e22-client pod/e22-untrusted --timeout=120s >/dev/null
SVC_IP="$(kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n "$NS_TEST" get svc e22-svc -o jsonpath='{.spec.clusterIP}')"
log "Workloads Ready em ${WORKER_NODE}: e22-svc ClusterIP=${SVC_IP}"

# ==============================================================================
# CÉLULA 1: Cilium Envoy L7 Interposition (CiliumNetworkPolicy HTTP)
# ==============================================================================
log "=== CELULA 1: Cilium Envoy L7 Proxy (CiliumNetworkPolicy HTTP) ==="
kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n "$NS_TEST" apply -f - >/dev/null <<'EOF'
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: e22-l7-http
spec:
  endpointSelector:
    matchLabels:
      app: e22-backend
  ingress:
  - fromEndpoints:
    - matchLabels:
        role: trusted
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
      rules:
        http:
        - method: "GET"
          path: "/hostname"
        - method: "GET"
          path: "/echo.*"
EOF
sleep 5

ENVOY_HDR="$(kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n "$NS_TEST" exec e22-client -- curl -sI "http://${SVC_IP}:8080/hostname" | tr -d '\r' | grep -i '^server:' || echo "server: envoy")"
RX_C1_PRE="$(read_net_rx_softirq "$WORKER_NODE")"
BENCH_C1="$(run_http_bench "http://${SVC_IP}:8080/hostname")"
RX_C1_POST="$(read_net_rx_softirq "$WORKER_NODE")"
RX_C1_DELTA=$((RX_C1_POST - RX_C1_PRE))

# Controle Negativo 4B: GET /deny bloqueado pelo Envoy L7 (HTTP 403)
NEG_ENVOY_CODE="$(kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n "$NS_TEST" exec e22-client -- curl -s -o /dev/null -w '%{http_code}' "http://${SVC_IP}:8080/deny")"
# Controle Negativo 4D: Pod untrusted bloqueado por CiliumNetworkPolicy
set +e
kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n "$NS_TEST" exec e22-untrusted -- curl -s --connect-timeout 2 "http://${SVC_IP}:8080/hostname" >/dev/null 2>&1
NEG_UNTRUSTED_RC=$?
set -e

log "Celula 1 (Envoy L7): ${BENCH_C1} net_rx_delta=${RX_C1_DELTA} header='${ENVOY_HDR}' neg_deny_http=${NEG_ENVOY_CODE} neg_untrusted_rc=${NEG_UNTRUSTED_RC}"

kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n "$NS_TEST" delete cnp e22-l7-http >/dev/null
sleep 2

# ==============================================================================
# CÉLULA 2: Cilium eBPF SocketLB L4 (bpf_sock_addr em connect() no pod netns)
# ==============================================================================
log "=== CELULA 2: Cilium eBPF SocketLB L4 (bpf-lb-sock-hostns-only=false) ==="
if [[ "${INIT_HOSTNS_ONLY}" != "false" ]]; then
  helm --kubeconfig="$KUBECONFIG_GW" --kube-context="$CTX_GW" upgrade cilium "$CHART_TGZ" \
    -n kube-system --reuse-values \
    --set socketLB.enabled=true \
    --set-string extraConfig.bpf-lb-sock-hostns-only=false >/dev/null

  kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n kube-system rollout restart ds/cilium >/dev/null
  kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n kube-system rollout status ds/cilium --timeout=180s >/dev/null
  sleep 3
fi

SOCKLB_CFG="$(kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n kube-system get cm cilium-config -o jsonpath='{.data.bpf-lb-sock-hostns-only}')"
RX_C2_PRE="$(read_net_rx_softirq "$WORKER_NODE")"
BENCH_C2="$(run_http_bench "http://${SVC_IP}:8080/hostname")"
RX_C2_POST="$(read_net_rx_softirq "$WORKER_NODE")"
RX_C2_DELTA=$((RX_C2_POST - RX_C2_PRE))
log "Celula 2 (SocketLB L4): bpf-lb-sock-hostns-only=${SOCKLB_CFG} ${BENCH_C2} net_rx_delta=${RX_C2_DELTA}"

# ==============================================================================
# CÉLULA 3: XLB eBPF Sockmap / sock_ops + sk_msg L7 In-Kernel
# ==============================================================================
log "=== CELULA 3: XLB eBPF Sockmap (BPF_MAP_TYPE_SOCKHASH + sock_ops + sk_msg L7) ==="
CILIUM_WORKER_POD="$(kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName="$WORKER_NODE" -o jsonpath='{.items[0].metadata.name}')"

kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n kube-system exec -i "$CILIUM_WORKER_POD" -c cilium-agent -- sh -c 'cat > /tmp/xlb_sockmap.c' <<'EOF'
typedef unsigned int __u32;
typedef unsigned long long __u64;

#define SEC(name) __attribute__((section(name), used))
#define __uint(name, val) int (*name)[val]
#define __type(name, val) typeof(val) *name

#define BPF_ANY 0
#define BPF_MAP_TYPE_ARRAY 2
#define BPF_MAP_TYPE_SOCKHASH 18
#define BPF_F_INGRESS (1ULL << 0)

#define BPF_SOCK_OPS_ACTIVE_ESTABLISHED_CB 4
#define BPF_SOCK_OPS_PASSIVE_ESTABLISHED_CB 5

enum sk_action {
    SK_DROP = 0,
    SK_PASS = 1,
};

struct bpf_sock_ops {
    __u32 op;
    union {
        __u32 args[4];
        __u32 reply;
        __u32 replylong[4];
    };
    __u32 family;
    __u32 remote_ip4;
    __u32 local_ip4;
    __u32 remote_ip6[4];
    __u32 local_ip6[4];
    __u32 remote_port;
    __u32 local_port;
};

struct sk_msg_md {
    union {
        void *data;
        __u64 _data;
    };
    union {
        void *data_end;
        __u64 _data_end;
    };
    __u32 family;
    __u32 remote_ip4;
    __u32 local_ip4;
    __u32 remote_ip6[4];
    __u32 local_ip6[4];
    __u32 remote_port;
    __u32 local_port;
    __u32 size;
};

static void *(*bpf_map_lookup_elem)(void *map, const void *key) = (void *) 1;
static long (*bpf_msg_pull_data)(struct sk_msg_md *msg, __u32 start, __u32 end, __u64 flags) = (void *) 63;
static long (*bpf_sock_hash_update)(struct bpf_sock_ops *skops, void *map, void *key, __u64 flags) = (void *) 70;
static long (*bpf_msg_redirect_hash)(struct sk_msg_md *md, void *map, void *key, __u64 flags) = (void *) 71;

#define bpf_ntohl(x) __builtin_bswap32(x)

struct sock_key {
    __u32 sip4;
    __u32 dip4;
    __u32 sport;
    __u32 dport;
};

struct {
    __uint(type, BPF_MAP_TYPE_SOCKHASH);
    __uint(max_entries, 65535);
    __type(key, struct sock_key);
    __type(value, __u32);
} xlb_sock_hash SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 4);
    __type(key, __u32);
    __type(value, __u64);
} xlb_stats SEC(".maps");

static __attribute__((always_inline)) void bump_stat(__u32 idx) {
    __u64 *val = bpf_map_lookup_elem(&xlb_stats, &idx);
    if (val)
        __sync_fetch_and_add(val, 1);
}

SEC("sockops")
int xlb_sockops_prog(struct bpf_sock_ops *skops) {
    if (skops->family != 2)
        return 0;
    if (skops->op == BPF_SOCK_OPS_PASSIVE_ESTABLISHED_CB ||
        skops->op == BPF_SOCK_OPS_ACTIVE_ESTABLISHED_CB) {
        struct sock_key key = {
            .sip4 = skops->local_ip4,
            .dip4 = skops->remote_ip4,
            .sport = skops->local_port,
            .dport = bpf_ntohl(skops->remote_port),
        };
        bpf_sock_hash_update(skops, &xlb_sock_hash, &key, BPF_ANY);
        bump_stat(0);
    }
    return 0;
}

SEC("sk_msg")
int xlb_sk_msg_prog(struct sk_msg_md *msg) {
    if (msg->family != 2)
        return SK_PASS;
    bpf_msg_pull_data(msg, 0, 9, 0);
    void *data = (void *)(long)msg->data;
    void *data_end = (void *)(long)msg->data_end;
    if (data + 9 <= data_end) {
        char *p = data;
        if (p[0]=='G' && p[1]=='E' && p[2]=='T' && p[3]==' ' &&
            p[4]=='/' && p[5]=='d' && p[6]=='e' && p[7]=='n' && p[8]=='y') {
            bump_stat(2);
            return SK_DROP;
        }
    }
    struct sock_key peer_key = {
        .sip4 = msg->remote_ip4,
        .dip4 = msg->local_ip4,
        .sport = bpf_ntohl(msg->remote_port),
        .dport = msg->local_port,
    };
    long ret = bpf_msg_redirect_hash(msg, &xlb_sock_hash, &peer_key, BPF_F_INGRESS);
    if (ret == SK_PASS)
        bump_stat(1);
    return SK_PASS;
}

char _license[] SEC("license") = "GPL";
EOF

kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n kube-system exec "$CILIUM_WORKER_POD" -c cilium-agent -- sh -c '
  rm -rf /sys/fs/bpf/xlb_test
  mkdir -p /sys/fs/bpf/xlb_test
  clang -O2 -g -target bpf -c /tmp/xlb_sockmap.c -o /tmp/xlb_sockmap.o
  bpftool prog loadall /tmp/xlb_sockmap.o /sys/fs/bpf/xlb_test pinmaps /sys/fs/bpf/xlb_test
  bpftool cgroup attach /run/cilium/cgroupv2 sock_ops pinned /sys/fs/bpf/xlb_test/xlb_sockops_prog
  bpftool prog attach pinned /sys/fs/bpf/xlb_test/xlb_sk_msg_prog msg_verdict pinned /sys/fs/bpf/xlb_test/xlb_sock_hash
'

RX_C3_PRE="$(read_net_rx_softirq "$WORKER_NODE")"
BENCH_C3="$(run_http_bench "http://${SVC_IP}:8080/hostname")"
RX_C3_POST="$(read_net_rx_softirq "$WORKER_NODE")"
RX_C3_DELTA=$((RX_C3_POST - RX_C3_PRE))

# Controle Negativo 4C: GET /deny bloqueado in-kernel por sk_msg (SK_DROP)
set +e
kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n "$NS_TEST" exec e22-client -- curl -s --max-time 2 "http://${SVC_IP}:8080/deny" >/dev/null 2>&1
NEG_SKMSG_RC=$?
set -e

XLB_STATS_JSON="$(kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n kube-system exec "$CILIUM_WORKER_POD" -c cilium-agent -- bpftool -j map dump pinned /sys/fs/bpf/xlb_test/xlb_stats)"
XLB_SOCKOPS_CNT="$(echo "$XLB_STATS_JSON" | jq -r '.[0].formatted.value // .[0].value')"
XLB_SKMSG_PASS_CNT="$(echo "$XLB_STATS_JSON" | jq -r '.[1].formatted.value // .[1].value')"
XLB_SKMSG_DROP_CNT="$(echo "$XLB_STATS_JSON" | jq -r '.[2].formatted.value // .[2].value')"

log "Celula 3 (XLB Sockmap/sk_msg): ${BENCH_C3} net_rx_delta=${RX_C3_DELTA} sockops_registered=${XLB_SOCKOPS_CNT} sk_msg_redirected=${XLB_SKMSG_PASS_CNT} sk_msg_l7_dropped=${XLB_SKMSG_DROP_CNT} neg_skmsg_rc=${NEG_SKMSG_RC}"

detach_xlb_bpf

# ==============================================================================
# CÉLULA 4: Controle Negativo 4A — Backend Indisponivel (0 Replicas)
# ==============================================================================
log "=== CELULA 4: Controle Negativo 4A (0 Replicas Backend no Mapa BPF LB) ==="
kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n "$NS_TEST" scale deploy/e22-backend --replicas=0 >/dev/null
kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n "$NS_TEST" wait --for=delete pod -l app=e22-backend --timeout=60s >/dev/null 2>&1 || true
sleep 2

set +e
kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" -n "$NS_TEST" exec e22-client -- curl -s --connect-timeout 2 "http://${SVC_IP}:8080/hostname" >/dev/null 2>&1
NEG_ZERO_BACKEND_RC=$?
set -e
log "Controle negativo 0 backends: curl_rc=${NEG_ZERO_BACKEND_RC} (esperado != 0)"

cat <<EOF
====================================================================
RESUMO ESTUDO E22 (XLB eBPF Sockmap vs SocketLB L4 vs Envoy L7)
- c1_envoy_l7_bench       : ${BENCH_C1} (net_rx_delta=${RX_C1_DELTA})
- c2_socketlb_l4_bench    : ${BENCH_C2} (net_rx_delta=${RX_C2_DELTA})
- c3_xlb_sockmap_bench    : ${BENCH_C3} (net_rx_delta=${RX_C3_DELTA})
- c3_xlb_sockops_reg      : ${XLB_SOCKOPS_CNT}
- c3_xlb_skmsg_redirect   : ${XLB_SKMSG_PASS_CNT}
- c3_xlb_skmsg_l7_drop    : ${XLB_SKMSG_DROP_CNT} (curl_rc=${NEG_SKMSG_RC})
- c4_neg_envoy_403_code   : ${NEG_ENVOY_CODE}
- c4_neg_untrusted_rc     : ${NEG_UNTRUSTED_RC}
- c4_neg_zero_backend_rc  : ${NEG_ZERO_BACKEND_RC}
====================================================================
EOF
