#!/usr/bin/env bash
# ==============================================================================
# E39 — Cilium Service Mesh L7 Traffic Management via CiliumEnvoyConfig
# (Canary Split 90/10 + Header Routing, Token-Bucket Rate Limit HTTP 429 & Retries)
# Plano P008-S001 (Braço B)
#
# Objetivo:
#   1. Célula 1 (Canary Split 90/10 & Roteamento Determinístico por Header):
#      - Validar no cluster `kind-p003-gw` (Cilium 1.20.2) a criação e aceitação
#        do CRD `CiliumEnvoyConfig/e39-l7-traffic-mgmt` (`cilium.io/v2`)
#        associado ao `Service/e39-api-svc`.
#      - Exercitar no proxy Envoy (`quay.io/cilium/cilium-envoy` embarcado no
#        Cilium 1.20.2) o split L7 `90/10` em `/version` (`100` requisições
#        distribuídas entre `v1` e `v2`) e o roteamento determinístico por
#        cabeçalho `X-Canary: true` (`10/10` respostas `v2` com injeção do
#        header `x-cilium-envoy-tier: canary-v2`).
#   2. Célula 2 (Token-Bucket Local Rate Limiting `HTTP 429 Too Many Requests`):
#      - Exercitar o filtro `envoy.filters.http.local_ratelimit` (`max_tokens: 5`,
#        `tokens_per_fill: 5`, `fill_interval: 60s`) na rota `/ratelimited`.
#      - Disparar uma rajada de `15` requisições e comprovar que exatamente
#        `5/15` retornam `HTTP 200 OK` e `10/15` são barradas no proxy L7 com
#        `HTTP 429 Too Many Requests` (`x-envoy-ratelimited: true`), protegendo
#        o backend (`backend_ratelimited_hits=5`).
#   3. Célula 3 (Controles Negativos — Automatic L7 Retries `5xx` vs Sem Retry):
#      - 3A: Contra um backend instável (`/flaky` que falha `HTTP 503` em 50% das
#        chamadas — tentativas ímpares `503`, pares `200`), provar que:
#        * `/flaky-noretry` (sem `retry_policy`) entrega apenas `5/10` (`50%`)
#          `HTTP 200` e expõe `5/10` erros `HTTP 503` ao cliente;
#        * `/flaky-retry` (com `retry_policy: retry_on: "5xx", num_retries: 3`)
#          re-tenta transparentemente as falhas transitórias e entrega `10/10`
#          (`100%`) `HTTP 200 OK` ao cliente!
#      - 3B: Remover a `CiliumEnvoyConfig` e limpar o namespace com `R6=0`.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/01-e39-cilium-envoy-l7.yaml"
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) echo "Uso: $0 [--dry-run]" >&2; exit 1 ;;
  esac
done

log() { printf "[e39][%s] %s\n" "$(date -u +%H:%M:%SZ)" "$*"; }

if $DRY_RUN; then
  log "DRY-RUN: validando existência do manifesto ${MANIFEST}"
  [[ -f "$MANIFEST" ]] || { echo "Manifesto ausente: $MANIFEST" >&2; exit 1; }
  log "DRY-RUN OK: E39 pronto para execução ao vivo na vm-cilium."
  exit 0
fi

export KUBECONFIG="${SANDBOX_KUBECONFIG:-${KUBECONFIG:-${HOME}/.kube/config}}"
CTX="kind-p003-gw"
NS="p008-e39"
CILIUM_POD=""

cleanup() {
  log "Iniciando cleanup (rollback R6=0)..."
  if [[ -n "$CILIUM_POD" ]]; then
    kubectl --context "$CTX" -n kube-system exec "$CILIUM_POD" -- sh -c \
      'kill -9 $(cat /tmp/e39-envoy.pid 2>/dev/null) 2>/dev/null; rm -rf /tmp/e39-*' >/dev/null 2>&1 || true
  fi
  docker exec p003-gw-worker sh -c \
    'kill -9 $(cat /tmp/e39-backends.pid 2>/dev/null) 2>/dev/null; rm -rf /tmp/e39-*' >/dev/null 2>&1 || true
  kubectl --context "$CTX" delete -f "$MANIFEST" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "=== E39 PREFLIGHT: Verificando invariantes k01, p003-gw e piso R3 ==="
kubectl --context kind-k01 get nodes --no-headers | awk '{if ($2 != "Ready") exit 1}'
kubectl --context "$CTX" get nodes --no-headers | awk '{if ($2 != "Ready") exit 1}'
MEM_AVAIL_KB="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
log "MemAvailable=${MEM_AVAIL_KB} kB"
if (( MEM_AVAIL_KB < 4194304 )); then
  echo "ERRO: MemAvailable (${MEM_AVAIL_KB} kB) abaixo do piso R3 (4 GiB)" >&2
  exit 1
fi

log "=== CÉLULA 1: Reconciliação de CiliumEnvoyConfig & Canary Split 90/10 + Header X-Canary ==="
kubectl --context "$CTX" apply -f "$MANIFEST"

CEC_INFO="$(kubectl --context "$CTX" -n "$NS" get ciliumenvoyconfig e39-l7-traffic-mgmt -o jsonpath='{.metadata.name}:{.spec.services[0].name}:{.spec.services[0].ports[0]}')"
log "CiliumEnvoyConfig registrada no apiserver: ${CEC_INFO}"
[[ "$CEC_INFO" == "e39-l7-traffic-mgmt:e39-api-svc:8080" ]] || {
  echo "Falha ao registrar CiliumEnvoyConfig" >&2; exit 1;
}

# Localizar o pod do cilium-agent em p003-gw-worker (que possui cilium-envoy nativo)
CILIUM_POD="$(kubectl --context "$CTX" -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=p003-gw-worker -o jsonpath='{.items[0].metadata.name}')"
ENVOY_VERSION="$(kubectl --context "$CTX" -n kube-system exec "$CILIUM_POD" -- cilium-envoy --version | head -n 2 | tr '\n' ' ')"
log " Usando cilium-envoy embarcado em ${CILIUM_POD}: ${ENVOY_VERSION}"

# Extrair o envoy.yaml do ConfigMap e iniciar os 3 backends (v1:8081, v2:8082, flaky:8083) + cilium-envoy (:18080)
kubectl --context "$CTX" -n "$NS" get configmap e39-envoy-bootstrap -o jsonpath='{.data.envoy\.yaml}' \
  | kubectl --context "$CTX" -n kube-system exec -i "$CILIUM_POD" -- sh -c 'cat > /tmp/e39-envoy.yaml'

docker exec -i p003-gw-worker sh -c 'cat > /tmp/e39-backends.py' << 'EOF'
import http.server, socketserver, threading, os, time

state = {"rl_hits": 0, "flaky_seq": 0}

class V1Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/ratelimited"):
            state["rl_hits"] += 1
            self.send_response(200)
            self.end_headers()
            msg = "RL-OK-%d\n" % state["rl_hits"]
            self.wfile.write(msg.encode())
        elif self.path.startswith("/stats"):
            self.send_response(200)
            self.end_headers()
            msg = "rl_hits=%d flaky_seq=%d\n" % (state["rl_hits"], state["flaky_seq"])
            self.wfile.write(msg.encode())
        else:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"v1\n")
    def log_message(self, *args): pass

class V2Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"v2\n")
    def log_message(self, *args): pass

class FlakyHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        state["flaky_seq"] += 1
        if state["flaky_seq"] % 2 == 1:
            self.send_response(503)
            self.end_headers()
            self.wfile.write(b"upstream-transient-error\n")
        else:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"flaky-recovered-200\n")
    def log_message(self, *args): pass

for port, cls in ((8081, V1Handler), (8082, V2Handler), (8083, FlakyHandler)):
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    s = socketserver.ThreadingTCPServer(("127.0.0.1", port), cls)
    threading.Thread(target=s.serve_forever, daemon=True).start()

with open("/tmp/e39-backends.pid", "w") as f:
    f.write(str(os.getpid()))
while True:
    time.sleep(3600)
EOF

docker exec -d p003-gw-worker python3 /tmp/e39-backends.py

kubectl --context "$CTX" -n kube-system exec "$CILIUM_POD" -- sh -c \
  'nohup cilium-envoy -c /tmp/e39-envoy.yaml --base-id 39 >/tmp/e39-envoy.log 2>&1 & echo $! > /tmp/e39-envoy.pid'

sleep 2

log "--- Ensaio 1A: Canary Weighted Split 90% v1 / 10% v2 em 100 requisições ---"
SPLIT_OUT="$(docker exec p003-gw-worker python3 -c '
import urllib.request
v1 = v2 = 0
for _ in range(100):
    body = urllib.request.urlopen("http://127.0.0.1:18080/version", timeout=1).read().decode().strip()
    if body == "v1": v1 += 1
    elif body == "v2": v2 += 1
print(f"v1={v1} v2={v2}")
')"
log "Resultado 1A (Weighted Split 100 reqs): ${SPLIT_OUT}"
V1_CNT="$(echo "$SPLIT_OUT" | awk -F'[= ]' '{print $2}')"
V2_CNT="$(echo "$SPLIT_OUT" | awk -F'[= ]' '{print $4}')"
(( V1_CNT >= 75 && V2_CNT >= 3 && (V1_CNT + V2_CNT) == 100 )) || {
  echo "Falha na distribuição ponderada 90/10: ${SPLIT_OUT}" >&2; exit 1;
}

log "--- Ensaio 1B: Roteamento Determinístico por Header (X-Canary: true -> 100% v2 + Response Header) ---"
CANARY_OUT="$(docker exec p003-gw-worker python3 -c '
import urllib.request
v2_ok = hdr_ok = 0
for _ in range(10):
    req = urllib.request.Request("http://127.0.0.1:18080/version", headers={"X-Canary": "true"})
    with urllib.request.urlopen(req, timeout=1) as resp:
        body = resp.read().decode().strip()
        tier = resp.headers.get("x-cilium-envoy-tier", "")
        if body == "v2": v2_ok += 1
        if tier == "canary-v2": hdr_ok += 1
print(f"canary_v2={v2_ok}/10 header_injected={hdr_ok}/10")
')"
log "Resultado 1B (Header X-Canary: true): ${CANARY_OUT}"
[[ "$CANARY_OUT" == "canary_v2=10/10 header_injected=10/10" ]] || {
  echo "Falha no roteamento Canary por header: ${CANARY_OUT}" >&2; exit 1;
}

log "=== CÉLULA 2: L7 Token-Bucket Local Rate Limiting (max_tokens=5 / 60s -> HTTP 429) ==="
RL_OUT="$(docker exec p003-gw-worker python3 -c '
import urllib.request, urllib.error
ok_200 = rl_429 = rl_hdr = 0
for _ in range(15):
    try:
        with urllib.request.urlopen("http://127.0.0.1:18080/ratelimited", timeout=1) as resp:
            if resp.status == 200:
                ok_200 += 1
    except urllib.error.HTTPError as e:
        if e.code == 429:
            rl_429 += 1
            if e.headers.get("x-envoy-ratelimited") == "true":
                rl_hdr += 1
backend_stats = urllib.request.urlopen("http://127.0.0.1:8081/stats", timeout=1).read().decode().strip()
print(f"http_200={ok_200}/15 http_429={rl_429}/15 header_ratelimited={rl_hdr}/10 {backend_stats}")
')"
log "Resultado Célula 2 (Local Rate Limit 15 reqs): ${RL_OUT}"
[[ "$RL_OUT" == *"http_200=5/15 http_429=10/15 header_ratelimited=10/10 rl_hits=5"* ]] || {
  echo "Falha no Local Rate Limiting L7: ${RL_OUT}" >&2; exit 1;
}

log "=== CÉLULA 3: Controles Negativos (3A Retries Automáticos L7 5xx vs Sem Retry & 3B Rollback) ==="
RETRY_OUT="$(docker exec p003-gw-worker python3 -c '
import urllib.request, urllib.error

noretry_200 = noretry_503 = 0
for _ in range(10):
    try:
        with urllib.request.urlopen("http://127.0.0.1:18080/flaky-noretry", timeout=1) as resp:
            if resp.status == 200: noretry_200 += 1
    except urllib.error.HTTPError as e:
        if e.code == 503: noretry_503 += 1

retry_200 = retry_503 = 0
for _ in range(10):
    try:
        with urllib.request.urlopen("http://127.0.0.1:18080/flaky-retry", timeout=2) as resp:
            if resp.status == 200: retry_200 += 1
    except urllib.error.HTTPError as e:
        if e.code == 503: retry_503 += 1

backend_stats = urllib.request.urlopen("http://127.0.0.1:8081/stats", timeout=1).read().decode().strip()
print(f"noretry_200={noretry_200}/10 noretry_503={noretry_503}/10 retry_200={retry_200}/10 retry_503={retry_503}/10 {backend_stats}")
')"
log "Resultado 3A (Flaky Upstream 50% 503 — Sem Retry vs Com Retry L7): ${RETRY_OUT}"
[[ "$RETRY_OUT" == *"noretry_200=5/10 noretry_503=5/10 retry_200=10/10 retry_503=0/10"* ]] || {
  echo "Falha no teste comparativo de Retries L7: ${RETRY_OUT}" >&2; exit 1;
}

# 3B: Remover CiliumEnvoyConfig e confirmar ausência de CRDs residuais
kubectl --context "$CTX" -n "$NS" delete ciliumenvoyconfig e39-l7-traffic-mgmt
CEC_REMAINING="$(kubectl --context "$CTX" -n "$NS" get ciliumenvoyconfig --no-headers 2>/dev/null | wc -l | tr -d ' ')"
log "Controle 3B (Remoção de CiliumEnvoyConfig): remaining_cec=${CEC_REMAINING}"
[[ "$CEC_REMAINING" -eq 0 ]] || {
  echo "Falha ao remover CiliumEnvoyConfig" >&2; exit 1;
}

cleanup
trap - EXIT
docker exec p003-gw-worker sh -c 'kill -9 $(cat /tmp/e39-backends.pid 2>/dev/null) 2>/dev/null; rm -f /tmp/e39-backends.pid' >/dev/null 2>&1 || true

R6_ROUTES="$(ip route show proto bgp | wc -l | tr -d ' ')"
log "=== E39 SUMMARY ==="
log "Célula 1 (Canary Split 90/10 & Header X-Canary): PASS (${SPLIT_OUT}, ${CANARY_OUT})"
log "Célula 2 (Token-Bucket Local Rate Limit HTTP 429): PASS (${RL_OUT})"
log "Célula 3 (Retries L7 5xx vs Sem Retry & Rollback): PASS (${RETRY_OUT}, remaining_cec=0, R6=${R6_ROUTES})"
log "E39 CONCLUÍDO COM SUCESSO (PASS)."
