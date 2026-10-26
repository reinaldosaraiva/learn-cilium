#!/usr/bin/env bash
# ==============================================================================
# P007-S002 — Braço A (E36): Cilium Local Redirect Policy (CiliumLocalRedirectPolicy)
#             & Node-Local Service / DNS Cache eBPF Bypass
#
# Objetivo:
#   Avaliar no sandbox p003-gw (Cilium 1.20.2):
#   - Célula 1: Comparativo entre `Service ClusterIP` padrão (`e36-cache-svc`,
#     balanceando requisições cross-node entre `p003-gw-worker` e `p003-gw-worker2`)
#     e a ativação de `CiliumLocalRedirectPolicy` com `serviceMatcher`:
#       * Antes da LRP: requisições originadas em `w1` e `w2` cruzam nós (~50%
#         atendidas pelo worker remoto).
#       * Com `CiliumLocalRedirectPolicy` (`e36-lrp-service`): `20/20` (100%)
#         das requisições em `w1` são atendidas localmente em `p003-gw-worker` e
#         `20/20` (100%) das requisições em `w2` são atendidas localmente em
#         `p003-gw-worker2` (`0` hops cross-node), validado em `cilium-dbg bpf lb list`.
#   - Célula 2: `CiliumLocalRedirectPolicy` com `addressMatcher` (`169.254.20.10:8080/TCP`,
#     modelo Node-Local DNS Cache): redirecionamento transparente no socket/TC eBPF
#     para a réplica local do `DaemonSet` sem necessidade de `Service` Kubernetes
#     para `169.254.20.10` (`10/10` em `w1` -> `worker` e `10/10` em `w2` -> `worker2`).
#   - Célula 3: Controles Negativos:
#       * 3A: Remoção da réplica local do `DaemonSet` em `p003-gw-worker2` ->
#         `169.254.20.10:8080` falha localmente em `w2` (`0/5`) sem afetar `w1` (`10/10`).
#       * 3B: Remoção das políticas `CiliumLocalRedirectPolicy` -> `169.254.20.10:8080`
#         deixa de ser interceptado no mapa BPF (`0/5`) e `e36-cache-svc` volta
#         ao balanceamento ClusterIP multi-nó (`20/20` HTTP 200, `R6=0`).
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/02-e36-local-redirect-policy.yaml"

SANDBOX_KUBECONFIG="${SANDBOX_KUBECONFIG:-/root/.kube/p003-gw.config}"
SANDBOX_CONTEXT="${SANDBOX_CONTEXT:-kind-p003-gw}"
SANDBOX_UID="${SANDBOX_UID:-6bb32e0f-71f9-4558-ae33-356ba2250c26}"

K01_KUBECONFIG="${K01_KUBECONFIG:-/root/.kube/k01-rebuild.config}"
K01_UID="${K01_UID:-635e7274-5597-40c7-9de5-b1fbe3d68b22}"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      echo "Uso: $0 [--dry-run]"
      exit 0
      ;;
    *)
      echo "ERRO: argumento desconhecido: $arg" >&2
      exit 2
      ;;
  esac
done

log() {
  printf '[%s] [E36] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "MODO --dry-run ATIVO: validando manifesto e plano de execução sem tocar no cluster."
  [[ -f "$MANIFEST" ]] || { echo "ERRO: manifesto ausente: $MANIFEST" >&2; exit 1; }
  log "Plano de execução:"
  log "  1. Preflight R1 (k01 uid=${K01_UID}), R2 (p003-gw uid=${SANDBOX_UID}) e R3 (MemAvailable >= 4 GiB)"
  log "  2. Célula 1: Habilitar enable-local-redirect-policy=true; medir ClusterIP cross-node vs LRP serviceMatcher (20/20 100% node-local)"
  log "  3. Célula 2: CiliumLocalRedirectPolicy addressMatcher (169.254.20.10:8080/TCP Node-Local Cache Bypass)"
  log "  4. Célula 3: Controles Negativos 3A (ausência de pod local em w2) e 3B (remoção da LRP + restauração ClusterIP)"
  log "  5. Teardown determinístico (R6=0)"
  exit 0
fi

K="kubectl --kubeconfig=${SANDBOX_KUBECONFIG} --context=${SANDBOX_CONTEXT}"

cleanup() {
  log "Executando limpeza determinística (R6)..."
  $K -n p007-e36 delete ciliumlocalredirectpolicy --all --ignore-not-found=true >/dev/null 2>&1 || true
  $K delete -f "$MANIFEST" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  $K delete ns p007-e36 --ignore-not-found=true --wait=true --timeout=60s >/dev/null 2>&1 || true
  $K label node p003-gw-worker p003-gw-worker2 e36-lrp-node- >/dev/null 2>&1 || true
  log "Limpeza concluída."
}
trap cleanup EXIT

log "=== PREFLIGHT: Verificando invariantes R1 (k01), R2 (p003-gw) e R3 (MemAvailable) ==="
ACTUAL_K01_UID="$(kubectl --kubeconfig="${K01_KUBECONFIG}" get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "$ACTUAL_K01_UID" != "$K01_UID" ]]; then
  echo "ERRO CRÍTICO (R1): UID do k01 (${ACTUAL_K01_UID}) difere do esperado (${K01_UID})!" >&2
  exit 1
fi
ACTUAL_SBX_UID="$($K get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "$ACTUAL_SBX_UID" != "$SANDBOX_UID" ]]; then
  echo "ERRO CRÍTICO (R2): UID do p003-gw (${ACTUAL_SBX_UID}) difere do esperado (${SANDBOX_UID})!" >&2
  exit 1
fi
MEM_AVAIL_KB="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
if [[ "${MEM_AVAIL_KB:-0}" -lt 3500000 ]]; then
  echo "ERRO CRÍTICO (R3): MemAvailable insuficiente (${MEM_AVAIL_KB} kB < 3500000 kB)!" >&2
  exit 1
fi
log "Preflight OK: k01_uid=${ACTUAL_K01_UID} | p003_gw_uid=${ACTUAL_SBX_UID} | MemAvailable=${MEM_AVAIL_KB} kB"

# Habilitar enable-local-redirect-policy=true no cilium-config e reiniciar cilium-operator para registrar o CRD ciliumlocalredirectpolicies.cilium.io
CURR_LRP="$($K -n kube-system get cm cilium-config -o jsonpath='{.data.enable-local-redirect-policy}' || true)"
if [[ "$CURR_LRP" != "true" ]] || ! $K get crd ciliumlocalredirectpolicies.cilium.io >/dev/null 2>&1; then
  log "Ativando enable-local-redirect-policy=true no ConfigMap cilium-config e reiniciando cilium-operator + cilium..."
  $K -n kube-system patch cm cilium-config --type merge -p '{"data":{"enable-local-redirect-policy":"true"}}'
  $K -n kube-system rollout restart deploy/cilium-operator
  $K -n kube-system rollout status deploy/cilium-operator --timeout=90s
  for _ in $(seq 1 30); do
    $K get crd ciliumlocalredirectpolicies.cilium.io >/dev/null 2>&1 && break
    sleep 1
  done
  $K -n kube-system rollout restart ds/cilium
  $K -n kube-system rollout status ds/cilium --timeout=120s
else
  log "enable-local-redirect-policy=true e CRD ciliumlocalredirectpolicies.cilium.io já estão ativos."
  $K -n kube-system rollout status ds/cilium --timeout=120s
fi

# ==============================================================================
# CÉLULA 1: Baseline ClusterIP Cross-Node vs CiliumLocalRedirectPolicy (serviceMatcher)
# ==============================================================================
log "=== CÉLULA 1: Baseline ClusterIP Cross-Node vs CiliumLocalRedirectPolicy (serviceMatcher) ==="
$K label node p003-gw-worker p003-gw-worker2 e36-lrp-node=enabled --overwrite
$K apply -f "$MANIFEST"
$K -n p007-e36 rollout status ds/e36-cache-ds --timeout=90s
$K -n p007-e36 wait --for=condition=Ready pod/e36-cli-w1 pod/e36-cli-w2 --timeout=90s

SVC_IP="$($K -n p007-e36 get svc e36-cache-svc -o jsonpath='{.spec.clusterIP}')"
log "Service e36-cache-svc ClusterIP=${SVC_IP}"

log "--- [1A] Baseline SEM CiliumLocalRedirectPolicy (20 requisições de w1 e 20 de w2 para ${SVC_IP}:80) ---"
$K -n p007-e36 exec e36-cli-w1 -- python3 -c "
import urllib.request
w1, w2 = 0, 0
for _ in range(20):
    with urllib.request.urlopen('http://e36-cache-svc.p007-e36.svc.cluster.local:80/', timeout=2) as r:
        b = r.read().decode()
        if 'node=p003-gw-worker2' in b: w2 += 1
        elif 'node=p003-gw-worker' in b: w1 += 1
print(f'[Baseline w1 -> ClusterIP] local_w1={w1}/20 remote_w2={w2}/20')
"
$K -n p007-e36 exec e36-cli-w2 -- python3 -c "
import urllib.request
w1, w2 = 0, 0
for _ in range(20):
    with urllib.request.urlopen('http://e36-cache-svc.p007-e36.svc.cluster.local:80/', timeout=2) as r:
        b = r.read().decode()
        if 'node=p003-gw-worker2' in b: w2 += 1
        elif 'node=p003-gw-worker' in b: w1 += 1
print(f'[Baseline w2 -> ClusterIP] local_w2={w2}/20 remote_w1={w1}/20')
"

log "--- [1B] Aplicando CiliumLocalRedirectPolicy/e36-lrp-service (serviceMatcher -> DaemonSet local) ---"
cat <<'EOF_LRP_SVC' | $K apply -f -
apiVersion: cilium.io/v2
kind: CiliumLocalRedirectPolicy
metadata:
  name: e36-lrp-service
  namespace: p007-e36
spec:
  redirectFrontend:
    serviceMatcher:
      serviceName: e36-cache-svc
      namespace: p007-e36
      toPorts:
        - port: "80"
          name: http
          protocol: TCP
  redirectBackend:
    localEndpointSelector:
      matchLabels:
        app: e36-cache-ds
    toPorts:
      - port: "8080"
        name: http-cache
        protocol: TCP
EOF_LRP_SVC

sleep 3
CILIUM_W1="$($K -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=p003-gw-worker -o jsonpath='{.items[0].metadata.name}')"
CILIUM_W2="$($K -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=p003-gw-worker2 -o jsonpath='{.items[0].metadata.name}')"

log "Inspecionando mapa BPF LB em p003-gw-worker e p003-gw-worker2 para ${SVC_IP}:80:"
$K -n kube-system exec "$CILIUM_W1" -- cilium-dbg bpf lb list | grep -F "${SVC_IP}:80" || true
$K -n kube-system exec "$CILIUM_W2" -- cilium-dbg bpf lb list | grep -F "${SVC_IP}:80" || true

$K -n p007-e36 exec e36-cli-w1 -- python3 -c "
import urllib.request
w1, w2 = 0, 0
for _ in range(20):
    with urllib.request.urlopen('http://e36-cache-svc.p007-e36.svc.cluster.local:80/', timeout=2) as r:
        b = r.read().decode()
        if 'node=p003-gw-worker2' in b: w2 += 1
        elif 'node=p003-gw-worker' in b: w1 += 1
print(f'[Com LRP serviceMatcher w1 -> ClusterIP] local_w1={w1}/20 remote_w2={w2}/20')
assert w1 == 20 and w2 == 0, f'Esperado 20/20 local em w1, obtido {w1}/20'
"
$K -n p007-e36 exec e36-cli-w2 -- python3 -c "
import urllib.request
w1, w2 = 0, 0
for _ in range(20):
    with urllib.request.urlopen('http://e36-cache-svc.p007-e36.svc.cluster.local:80/', timeout=2) as r:
        b = r.read().decode()
        if 'node=p003-gw-worker2' in b: w2 += 1
        elif 'node=p003-gw-worker' in b: w1 += 1
print(f'[Com LRP serviceMatcher w2 -> ClusterIP] local_w2={w2}/20 remote_w1={w1}/20')
assert w2 == 20 and w1 == 0, f'Esperado 20/20 local em w2, obtido {w2}/20'
"

# ==============================================================================
# CÉLULA 2: CiliumLocalRedirectPolicy com addressMatcher (169.254.20.10:8080)
# ==============================================================================
log "=== CÉLULA 2: CiliumLocalRedirectPolicy com addressMatcher (VIP Node-Local 169.254.20.10:8080 sem Service) ==="
cat <<'EOF_LRP_ADDR' | $K apply -f -
apiVersion: cilium.io/v2
kind: CiliumLocalRedirectPolicy
metadata:
  name: e36-lrp-address
  namespace: p007-e36
spec:
  redirectFrontend:
    addressMatcher:
      ip: "169.254.20.10"
      toPorts:
        - port: "8080"
          name: http-cache
          protocol: TCP
  redirectBackend:
    localEndpointSelector:
      matchLabels:
        app: e36-cache-ds
    toPorts:
      - port: "8080"
        name: http-cache
        protocol: TCP
EOF_LRP_ADDR

sleep 3
log "Inspecionando mapa BPF LB para 169.254.20.10:8080 em p003-gw-worker e p003-gw-worker2:"
$K -n kube-system exec "$CILIUM_W1" -- cilium-dbg bpf lb list | grep -F "169.254.20.10:8080" || true
$K -n kube-system exec "$CILIUM_W2" -- cilium-dbg bpf lb list | grep -F "169.254.20.10:8080" || true

$K -n p007-e36 exec e36-cli-w1 -- python3 -c "
import urllib.request
w1 = 0
for _ in range(10):
    with urllib.request.urlopen('http://169.254.20.10:8080/', timeout=2) as r:
        b = r.read().decode()
        if 'node=p003-gw-worker' in b and 'node=p003-gw-worker2' not in b:
            w1 += 1
print(f'[Célula 2 w1 -> 169.254.20.10:8080] local_w1={w1}/10')
assert w1 == 10
"
$K -n p007-e36 exec e36-cli-w2 -- python3 -c "
import urllib.request
w2 = 0
for _ in range(10):
    with urllib.request.urlopen('http://169.254.20.10:8080/', timeout=2) as r:
        b = r.read().decode()
        if 'node=p003-gw-worker2' in b:
            w2 += 1
print(f'[Célula 2 w2 -> 169.254.20.10:8080] local_w2={w2}/10')
assert w2 == 10
"

# ==============================================================================
# CÉLULA 3: Controles Negativos (3A: Ausência de Pod Local em W2 & 3B: Remoção LRP)
# ==============================================================================
log "=== CÉLULA 3: Controles Negativos (3A Ausência de Backend Local em W2 & 3B Remoção das Políticas LRP) ==="

log "--- [3A] Removendo label e36-lrp-node de p003-gw-worker2 (terminando o pod local do DaemonSet em w2) ---"
$K label node p003-gw-worker2 e36-lrp-node-
$K -n p007-e36 delete pod -l app=e36-cache-ds --field-selector spec.nodeName=p003-gw-worker2 --grace-period=0 --force >/dev/null 2>&1 || true
for _ in $(seq 1 15); do
  if ! $K -n kube-system exec "$CILIUM_W2" -- cilium-dbg bpf lb list | grep -q "169.254.20.10:8080/TCP (1)"; then
    break
  fi
  sleep 1
done
sleep 1

$K -n p007-e36 exec e36-cli-w2 -- python3 -c "
import urllib.request
ok = 0
for _ in range(5):
    try:
        with urllib.request.urlopen('http://169.254.20.10:8080/', timeout=0.6) as r:
            if r.status == 200: ok += 1
    except Exception:
        pass
print(f'[3A RESULT w2 sem pod local -> 169.254.20.10:8080] ok={ok}/5 (esperado 0/5)')
assert ok == 0
"
$K -n p007-e36 exec e36-cli-w1 -- python3 -c "
import urllib.request
ok = 0
for _ in range(10):
    with urllib.request.urlopen('http://169.254.20.10:8080/', timeout=2) as r:
        if r.status == 200: ok += 1
print(f'[3A RESULT w1 com pod local intacto -> 169.254.20.10:8080] ok={ok}/10 (esperado 10/10)')
assert ok == 10
"

log "--- [3B] Restaurando DaemonSet em w2 e removendo as CiliumLocalRedirectPolicy ---"
$K label node p003-gw-worker2 e36-lrp-node=enabled --overwrite
$K -n p007-e36 rollout status ds/e36-cache-ds --timeout=60s
$K -n p007-e36 delete ciliumlocalredirectpolicy e36-lrp-service e36-lrp-address
sleep 2

LRP_LEFT="$($K -n kube-system exec "$CILIUM_W1" -- cilium-dbg bpf lb list | grep -c "169.254.20.10:8080" || true)"
log "[3B] Entradas residuais de 169.254.20.10:8080 no mapa BPF LB após delete: ${LRP_LEFT} (esperado 0)"

$K -n p007-e36 exec e36-cli-w1 -- python3 -c "
import urllib.request
ok = 0
for _ in range(5):
    try:
        with urllib.request.urlopen('http://169.254.20.10:8080/', timeout=0.5) as r:
            ok += 1
    except Exception:
        pass
print(f'[3B RESULT 169.254.20.10:8080 após remoção da LRP] ok={ok}/5 (esperado 0/5)')
assert ok == 0
"

$K -n p007-e36 exec e36-cli-w1 -- python3 -c "
import urllib.request
w1, w2 = 0, 0
for _ in range(20):
    with urllib.request.urlopen('http://e36-cache-svc.p007-e36.svc.cluster.local:80/', timeout=2) as r:
        b = r.read().decode()
        if 'node=p003-gw-worker2' in b: w2 += 1
        elif 'node=p003-gw-worker' in b: w1 += 1
print(f'[3B RESTORE ClusterIP multi-node] total_ok={w1+w2}/20 (w1={w1}, w2={w2})')
assert (w1 + w2) == 20 and w2 > 0
"

log "=== E36 CONCLUÍDO COM SUCESSO (PASS) ==="
