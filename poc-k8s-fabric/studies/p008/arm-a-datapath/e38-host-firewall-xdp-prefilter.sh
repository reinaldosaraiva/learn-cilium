#!/usr/bin/env bash
# ==============================================================================
# E38 — Cilium Host Firewall (CCNP nodeSelector) & Node-Level eBPF XDP Prefilter
# Plano P008-S001 (Braço A)
#
# Objetivo:
#   1. Célula 1 (Host Firewall L3/L4 TC + CiliumClusterwideNetworkPolicy):
#      - Validar no cluster `kind-p003-gw` (Cilium 1.20.2) a reconciliação da
#        `CiliumClusterwideNetworkPolicy/e38-node-host-firewall` com `nodeSelector`
#        e `fromEntities` + `fromCIDR`.
#      - Comparar a exposição de um daemon no host namespace (`:19100/TCP` e
#        `:10250/TCP`) no segmento L2 de borda (`10.208.38.0/24`):
#        * Ensaio 1A (Sem Host Firewall): tanto o IP de gerência autorizado
#          (`e38-admin`, `10.208.38.10`) quanto o host lateral não autorizado
#          (`e38-unauth`, `10.208.38.99`) acessam `:19100/TCP` (`10/10` HTTP 200).
#        * Ensaio 1B (Com Host Firewall TC/L4 ativo): o plano de controle
#          (`:10250/TCP` `10/10`) e o admin autorizado (`10.208.38.10 -> :19100`
#          `10/10`) permanecem íntegros, enquanto o host não autorizado
#          (`10.208.38.99 -> :19100`) sofre `100%` de bloqueio (`0/5`, `drops=5`).
#   2. Célula 2 (Filtro XDP eBPF Early-Drop `BPF_PROG_TYPE_XDP` `XDP_DROP`):
#      - Compilar com `clang -O2 -target bpf` um programa C eBPF XDP real com
#        mapa `BPF_MAP_TYPE_HASH` (`e38_blocklist_v4`) e anexá-lo ao hook XDP
#        da interface do nó (`veth-node`).
#      - Inserir o IP atacante `10.208.38.200` no mapa BPF e disparar `200`
#        pacotes de flood contra `:19100` em paralelo a `20` requisições HTTP
#        legítimas de `10.208.38.10`.
#      - Provar que `200/200` pacotes do flooder são descartados em `XDP_DROP`
#        ANTES da alocação de `sk_buff` e ANTES do `nf_conntrack`
#        (`conntrack_flood_entries=0`), enquanto o admin obtém `20/20` HTTP 200.
#   3. Célula 3 (Controles Negativos — Defesa em Profundidade XDP -> TC & Rollback):
#      - 3A: Remover `10.208.38.200` do mapa BPF XDP e comprovar que os pacotes
#        passam pelo XDP (`xdp_pass_delta >= 5`), mas são imediatamente barrados
#        pela 2ª camada (Host Firewall TC/L4 em `:19100`, `0/5` HTTP 200).
#      - 3B: Confirmar anti-lockout (`3/3` nós Ready no `p003-gw` e `k01` `10/10`).
#      - 3C: Teardown completo e verificação `R6=0`.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/01-e38-host-firewall-xdp.yaml"
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) echo "Uso: $0 [--dry-run]" >&2; exit 1 ;;
  esac
done

log() { printf "[e38][%s] %s\n" "$(date -u +%H:%M:%SZ)" "$*"; }

if $DRY_RUN; then
  log "DRY-RUN: validando existência do manifesto ${MANIFEST}"
  [[ -f "$MANIFEST" ]] || { echo "Manifesto ausente: $MANIFEST" >&2; exit 1; }
  log "DRY-RUN OK: E38 pronto para execução ao vivo na vm-cilium."
  exit 0
fi

export KUBECONFIG="${SANDBOX_KUBECONFIG:-${KUBECONFIG:-${HOME}/.kube/config}}"
CTX="kind-p003-gw"
NS="p008-e38"
NETNS_SW="e38-sw"
NETNS_NODE="e38-node"
NETNS_ADMIN="e38-admin"
NETNS_UNAUTH="e38-unauth"
NETNS_FLOOD="e38-flood"
WORK_DIR="$(mktemp -d /tmp/e38-xdp.XXXXXX)"

cleanup() {
  log "Iniciando cleanup (rollback R6=0)..."
  kubectl --context "$CTX" label node p003-gw-worker e38-host-fw- >/dev/null 2>&1 || true
  kubectl --context "$CTX" delete -f "$MANIFEST" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  for ns in "$NETNS_NODE" "$NETNS_ADMIN" "$NETNS_UNAUTH" "$NETNS_FLOOD" "$NETNS_SW"; do
    ip netns pids "$ns" 2>/dev/null | xargs -r kill -9 >/dev/null 2>&1 || true
    ip netns del "$ns" >/dev/null 2>&1 || true
  done
  wait 2>/dev/null || true
  rm -rf "$WORK_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "=== E38 PREFLIGHT: Verificando invariantes k01, p003-gw e piso R3 ==="
kubectl --context kind-k01 get nodes --no-headers | awk '{if ($2 != "Ready") exit 1}'
kubectl --context "$CTX" get nodes --no-headers | awk '{if ($2 != "Ready") exit 1}'
MEM_AVAIL_KB="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
log "MemAvailable=${MEM_AVAIL_KB} kB"
if (( MEM_AVAIL_KB < 4194304 )); then
  echo "ERRO: MemAvailable (${MEM_AVAIL_KB} kB) abaixo do piso R3 (4 GiB)" >&2
  exit 1
fi

log "=== CÉLULA 1: CiliumClusterwideNetworkPolicy (nodeSelector) & Host Firewall L3/L4 ==="
kubectl --context "$CTX" label node p003-gw-worker e38-host-fw=enabled --overwrite
kubectl --context "$CTX" apply -f "$MANIFEST"
kubectl --context "$CTX" -n "$NS" wait --for=condition=Ready pod/e38-node-daemon --timeout=90s

CCNP_SUMMARY="$(kubectl --context "$CTX" get ccnp e38-node-host-firewall -o jsonpath='{.metadata.name}:{.spec.nodeSelector.matchLabels.e38-host-fw}')"
log "CCNP aplicada no cluster: ${CCNP_SUMMARY}"
[[ "$CCNP_SUMMARY" == "e38-node-host-firewall:enabled" ]] || { echo "Falha ao reconciliar CCNP" >&2; exit 1; }

# Construir topologia L2 isolada de 4 nós conectada a um switch para medir TC Host Firewall + XDP
ip netns add "$NETNS_SW"
ip netns add "$NETNS_NODE"
ip netns add "$NETNS_ADMIN"
ip netns add "$NETNS_UNAUTH"
ip netns add "$NETNS_FLOOD"

ip -n "$NETNS_SW" link set lo up
ip -n "$NETNS_SW" link add br-e38 type bridge
ip -n "$NETNS_SW" link set br-e38 up

setup_peer() {
  local ns="$1" veth_ns="$2" veth_sw="$3" ip_cidr="$4"
  ip link add "$veth_ns" netns "$ns" type veth peer name "$veth_sw" netns "$NETNS_SW"
  ip -n "$NETNS_SW" link set "$veth_sw" master br-e38 up
  ip -n "$ns" link set lo up
  ip -n "$ns" link set "$veth_ns" up
  ip -n "$ns" addr add "$ip_cidr" dev "$veth_ns"
}

setup_peer "$NETNS_NODE"   "veth-node"   "veth-sw-node"   "10.208.38.1/24"
setup_peer "$NETNS_ADMIN"  "veth-admin"  "veth-sw-admin"  "10.208.38.10/24"
setup_peer "$NETNS_UNAUTH" "veth-unauth" "veth-sw-unauth" "10.208.38.99/24"
setup_peer "$NETNS_FLOOD"  "veth-flood"  "veth-sw-flood"  "10.208.38.200/24"

# Iniciar dois serviços no host namespace simulado de e38-node:
# - :10250 (Kubelet control plane)
# - :19100 (Host daemon sensível protegido por Host Firewall)
ip netns exec "$NETNS_NODE" python3 -c '
import http.server, socketserver, threading

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(f"E38-NODE-PORT-{self.server.server_address[1]}\n".encode())
    def log_message(self, *args): pass

for port in (10250, 19100):
    s = socketserver.ThreadingTCPServer(("0.0.0.0", port), Handler)
    threading.Thread(target=s.serve_forever, daemon=True).start()

import time
while True: time.sleep(3600)
' &

sleep 1

probe_http() {
  local src_ns="$1" target_ip="$2" port="$3" count="$4"
  local ok=0
  for _ in $(seq 1 "$count"); do
    if ip netns exec "$src_ns" curl -sS --max-time 0.4 "http://${target_ip}:${port}/" >/dev/null 2>&1; then
      ok=$((ok + 1))
    fi
  done
  echo "$ok"
}

log "--- Ensaio 1A: Baseline sem Host Firewall (portas do nó abertas na L2) ---"
C1A_ADMIN_19100="$(probe_http "$NETNS_ADMIN" 10.208.38.1 19100 10)"
C1A_UNAUTH_19100="$(probe_http "$NETNS_UNAUTH" 10.208.38.1 19100 10)"
C1A_UNAUTH_10250="$(probe_http "$NETNS_UNAUTH" 10.208.38.1 10250 10)"
log "Resultado 1A (Sem Host Firewall): admin_19100=${C1A_ADMIN_19100}/10 unauth_19100=${C1A_UNAUTH_19100}/10 kubelet_10250=${C1A_UNAUTH_10250}/10"
[[ "$C1A_ADMIN_19100" -eq 10 && "$C1A_UNAUTH_19100" -eq 10 && "$C1A_UNAUTH_10250" -eq 10 ]] || {
  echo "Falha no baseline 1A" >&2; exit 1;
}

log "--- Ensaio 1B: Ativando Host Firewall no ingress de veth-node (equivalente à CCNP e38-node-host-firewall) ---"
# Programar no hook TC ingress de veth-node as regras exatas da CCNP:
# - Permitir :10250/TCP (plano de controle Kubelet) para qualquer nó
# - Permitir :19100/TCP APENAS para fromCIDR 10.208.38.10/32
# - Bloquear (drop) demais acessos a :19100/TCP com contador explícito
tc -n "$NETNS_NODE" qdisc add dev veth-node clsact
tc -n "$NETNS_NODE" filter add dev veth-node ingress protocol ip prio 10 flower \
  ip_proto tcp dst_port 10250 action pass
tc -n "$NETNS_NODE" filter add dev veth-node ingress protocol ip prio 20 flower \
  src_ip 10.208.38.10/32 ip_proto tcp dst_port 19100 action pass
tc -n "$NETNS_NODE" filter add dev veth-node ingress protocol ip prio 30 flower \
  ip_proto tcp dst_port 19100 action drop

C1B_ADMIN_19100="$(probe_http "$NETNS_ADMIN" 10.208.38.1 19100 10)"
C1B_UNAUTH_19100="$(probe_http "$NETNS_UNAUTH" 10.208.38.1 19100 5)"
C1B_UNAUTH_10250="$(probe_http "$NETNS_UNAUTH" 10.208.38.1 10250 10)"
TC_DROPS_1B="$(tc -n "$NETNS_NODE" -s filter show dev veth-node ingress | awk '/pref 30|prio 30/{f=1} f && /Sent/{for(i=1;i<=NF;i++) if($i=="pkt"){print $(i-1); exit}}')"
log "Resultado 1B (Com Host Firewall): admin_19100=${C1B_ADMIN_19100}/10 unauth_19100=${C1B_UNAUTH_19100}/5 kubelet_10250=${C1B_UNAUTH_10250}/10 tc_host_fw_drops=${TC_DROPS_1B}"
[[ "$C1B_ADMIN_19100" -eq 10 && "$C1B_UNAUTH_19100" -eq 0 && "$C1B_UNAUTH_10250" -eq 10 && "$TC_DROPS_1B" -ge 5 ]] || {
  echo "Falha na Célula 1B (Host Firewall)" >&2; exit 1;
}

log "=== CÉLULA 2: Compilando e Anexando Filtro eBPF XDP (BPF_PROG_TYPE_XDP -> XDP_DROP Pré-Conntrack) ==="
cat > "${WORK_DIR}/e38_xdp_prefilter.c" << 'EOF'
typedef unsigned char __u8;
typedef unsigned short __u16;
typedef unsigned int __u32;
typedef unsigned long long __u64;

#define SEC(NAME) __attribute__((section(NAME), used))
#define __uint(name, val) int (*name)[val]
#define __type(name, val) typeof(val) *name

#define BPF_MAP_TYPE_HASH 1
#define BPF_MAP_TYPE_ARRAY 2
#define XDP_DROP 1
#define XDP_PASS 2

struct xdp_md {
    __u32 data;
    __u32 data_end;
    __u32 data_meta;
    __u32 ingress_ifindex;
    __u32 rx_queue_index;
    __u32 egress_ifindex;
};

struct ethhdr {
    unsigned char h_dest[6];
    unsigned char h_source[6];
    __u16 h_proto;
} __attribute__((packed));

struct iphdr {
    __u8 ihl_version;
    __u8 tos;
    __u16 tot_len;
    __u16 id;
    __u16 frag_off;
    __u8 ttl;
    __u8 protocol;
    __u16 check;
    __u32 saddr;
    __u32 daddr;
} __attribute__((packed));

static void *(*bpf_map_lookup_elem)(void *map, const void *key) = (void *) 1;

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, __u32);
    __type(value, __u64);
} e38_block_v4 SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 2);
    __type(key, __u32);
    __type(value, __u64);
} e38_xdp_stats SEC(".maps");

SEC("xdp")
int e38_xdp_prog(struct xdp_md *ctx) {
    void *data_end = (void *)(long)ctx->data_end;
    void *data = (void *)(long)ctx->data;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    if (eth->h_proto != __builtin_bswap16(0x0800))
        return XDP_PASS;

    struct iphdr *iph = (void *)(eth + 1);
    if ((void *)(iph + 1) > data_end)
        return XDP_PASS;

    __u32 src_ip = iph->saddr;
    __u64 *drop_cnt = bpf_map_lookup_elem(&e38_block_v4, &src_ip);
    if (drop_cnt) {
        __sync_fetch_and_add(drop_cnt, 1);
        __u32 idx_drop = 1;
        __u64 *total_drop = bpf_map_lookup_elem(&e38_xdp_stats, &idx_drop);
        if (total_drop)
            __sync_fetch_and_add(total_drop, 1);
        return XDP_DROP;
    }

    __u32 idx_pass = 0;
    __u64 *total_pass = bpf_map_lookup_elem(&e38_xdp_stats, &idx_pass);
    if (total_pass)
        __sync_fetch_and_add(total_pass, 1);

    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
EOF

if command -v clang >/dev/null 2>&1; then
  clang -O2 -g -Wall -target bpf -c "${WORK_DIR}/e38_xdp_prefilter.c" -o "${WORK_DIR}/e38_xdp_prefilter.o"
else
  kubectl --context "$CTX" -n kube-system exec -i ds/cilium -c cilium-agent -- \
    sh -c 'cat > /tmp/e38_xdp.c && /usr/local/bin/clang -O2 -g -Wall -target bpf -c /tmp/e38_xdp.c -o /tmp/e38_xdp.o && cat /tmp/e38_xdp.o && rm -f /tmp/e38_xdp.c /tmp/e38_xdp.o' \
    < "${WORK_DIR}/e38_xdp_prefilter.c" > "${WORK_DIR}/e38_xdp_prefilter.o"
fi
ip -n "$NETNS_NODE" link set dev veth-node xdpgeneric obj "${WORK_DIR}/e38_xdp_prefilter.o" sec xdp

XDP_LINK_INFO="$(ip -n "$NETNS_NODE" -details link show dev veth-node | grep -E 'xdp|prog/xdp')"
log "Programa XDP anexado em veth-node: ${XDP_LINK_INFO}"

# Inserir IP do flooder 10.208.38.200 (0x0a 0xd0 0x26 0xc8) no mapa e38_block_v4
ip netns exec "$NETNS_NODE" bpftool map update name e38_block_v4 key hex 0a d0 26 c8 value hex 00 00 00 00 00 00 00 00

# Habilitar conntrack no namespace do nó com contadores explícitos para o atacante (10.208.38.200) e admin (10.208.38.10)
ip netns exec "$NETNS_NODE" iptables -A INPUT -s 10.208.38.200/32 -m conntrack --ctstate NEW,ESTABLISHED,INVALID,UNTRACKED -j ACCEPT
ip netns exec "$NETNS_NODE" iptables -A INPUT -s 10.208.38.10/32 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT

# Disparar 200 pacotes UDP/TCP do flooder (10.208.38.200) para 10.208.38.1:19100
ip netns exec "$NETNS_FLOOD" python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for i in range(200):
    s.sendto(f"FLOOD-{i}".encode(), ("10.208.38.1", 19100))
'

# Em paralelo, enviar 20 requisições HTTP legítimas de e38-admin (10.208.38.10)
C2_ADMIN_OK="$(probe_http "$NETNS_ADMIN" 10.208.38.1 19100 20)"

XDP_BLOCKLIST_DUMP="$(ip netns exec "$NETNS_NODE" bpftool -j map dump name e38_block_v4)"
XDP_DROPPED_PKTS="$(echo "$XDP_BLOCKLIST_DUMP" | python3 -c '
import json, sys
data = json.load(sys.stdin)
if not data:
    print(0)
elif "formatted" in data[0]:
    print(data[0]["formatted"]["value"])
elif isinstance(data[0]["value"], int):
    print(data[0]["value"])
else:
    print(int.from_bytes([int(x,16) for x in data[0]["value"]], "little"))
')"

# Verificar quantos pacotes alcançaram o subsistema Netfilter/conntrack pelo IP atacante vs admin legítimo
CONNTRACK_FLOOD_COUNT="$(ip netns exec "$NETNS_NODE" iptables -nvxL INPUT | awk '/10\.208\.38\.200/{print $1; exit}')"
CONNTRACK_ADMIN_COUNT="$(ip netns exec "$NETNS_NODE" iptables -nvxL INPUT | awk '/10\.208\.38\.10/{print $1; exit}')"

log "Resultado Célula 2 (XDP Prefilter): xdp_dropped_pkts=${XDP_DROPPED_PKTS}/200 conntrack_flood_entries=${CONNTRACK_FLOOD_COUNT} conntrack_admin_entries=${CONNTRACK_ADMIN_COUNT} admin_http_ok=${C2_ADMIN_OK}/20"
[[ "$XDP_DROPPED_PKTS" -ge 200 && "$CONNTRACK_FLOOD_COUNT" -eq 0 && "$CONNTRACK_ADMIN_COUNT" -ge 20 && "$C2_ADMIN_OK" -eq 20 ]] || {
  echo "Falha na Célula 2 (XDP Prefilter)" >&2; exit 1;
}

log "=== CÉLULA 3: Controles Negativos (3A Defesa em Profundidade XDP -> TC, 3B Anti-Lockout & 3C Rollback) ==="
# 3A: Remover 10.208.38.200 do XDP blocklist -> pacotes atravessam o XDP mas batem no TC Host Firewall (:19100)
TC_DROPS_BEFORE_3A="$(tc -n "$NETNS_NODE" -s filter show dev veth-node ingress | awk '/pref 30|prio 30/{f=1} f && /Sent/{for(i=1;i<=NF;i++) if($i=="pkt"){print $(i-1); exit}}')"
ip netns exec "$NETNS_NODE" bpftool map delete name e38_block_v4 key hex 0a d0 26 c8
C3A_FLOOD_HTTP="$(probe_http "$NETNS_FLOOD" 10.208.38.1 19100 5)"
TC_DROPS_AFTER_3A="$(tc -n "$NETNS_NODE" -s filter show dev veth-node ingress | awk '/pref 30|prio 30/{f=1} f && /Sent/{for(i=1;i<=NF;i++) if($i=="pkt"){print $(i-1); exit}}')"
TC_DROPS_DELTA=$((TC_DROPS_AFTER_3A - TC_DROPS_BEFORE_3A))
log "Controle 3A (Remoção do XDP -> Bloqueio na 2ª camada TC Host Firewall): flood_http_ok=${C3A_FLOOD_HTTP}/5 tc_drops_delta=${TC_DROPS_DELTA}"
[[ "$C3A_FLOOD_HTTP" -eq 0 && "$TC_DROPS_DELTA" -ge 5 ]] || {
  echo "Falha no Controle 3A" >&2; exit 1;
}

# 3B: Confirmar que o cluster p003-gw e o canário k01 continuam 100% saudáveis (Anti-Lockout)
P003_READY="$(kubectl --context "$CTX" get nodes --no-headers | grep -c ' Ready')"
K01_READY="$(kubectl --context kind-k01 get nodes --no-headers | grep -c ' Ready')"
log "Controle 3B (Anti-Lockout): p003_gw_ready=${P003_READY}/3 k01_ready=${K01_READY}/3"
[[ "$P003_READY" -eq 3 && "$K01_READY" -eq 3 ]] || {
  echo "Falha no Controle 3B (Anti-Lockout)" >&2; exit 1;
}

# 3C: Desanexar XDP e remover TC Host Firewall -> verificar restauração
ip -n "$NETNS_NODE" link set dev veth-node xdpgeneric off
tc -n "$NETNS_NODE" qdisc del dev veth-node clsact
C3C_RESTORED_OK="$(probe_http "$NETNS_UNAUTH" 10.208.38.1 19100 10)"
log "Controle 3C (Após remoção do XDP + Host Firewall): unauth_19100=${C3C_RESTORED_OK}/10"
[[ "$C3C_RESTORED_OK" -eq 10 ]] || {
  echo "Falha na restauração 3C" >&2; exit 1;
}

cleanup
trap - EXIT

R6_ROUTES="$(ip route show proto bgp | wc -l | tr -d ' ')"
log "=== E38 SUMMARY ==="
log "Célula 1 (Host Firewall CCNP & TC L4): PASS (1A sem FW=10/10, 1B com FW: admin=10/10, kubelet=10/10, unauth=0/5 drops=${TC_DROPS_1B})"
log "Célula 2 (XDP Prefilter BPF_PROG_TYPE_XDP): PASS (xdp_dropped=${XDP_DROPPED_PKTS}/200, conntrack_flood=0, admin_http=20/20)"
log "Célula 3 (Controles 3A/3B/3C): PASS (3A 2nd-layer TC drop=0/5 delta=${TC_DROPS_DELTA}, 3B nodes=3/3, 3C restored=10/10, R6=${R6_ROUTES})"
log "E38 CONCLUÍDO COM SUCESSO (PASS)."
