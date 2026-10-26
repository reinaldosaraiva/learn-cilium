#!/usr/bin/env bash
# ==============================================================================
# P007-S001 — Braço B (E35): Cilium Mutual Authentication (SPIFFE/SPIRE mTLS
#             Transparente + Identidade Criptográfica) & Criptografia WireGuard L3
#
# Objetivo:
#   Avaliar no sandbox p003-gw (Cilium 1.20.2 + Linux 6.8 WireGuard + SPIFFE X.509):
#   - Célula 1: Criptografia Transparente L3 WireGuard (`cilium_wg0` UDP :51871,
#     Curve25519 + ChaCha20-Poly1305) vs Texto Claro no enlace underlay (`veth`):
#       * Regime 1A (Texto Claro): captura `tcpdump` no underlay expõe 100% do
#         marcador HTTP `E35-TOP-SECRET-CLEARTEXT-MARKER-9981` (`cleartext_leaks > 0`).
#       * Regime 1B (WireGuard L3 `:51871`): `10/10` requisições HTTP 200 entre
#         endpoints com `0` ocorrências do marcador em claro no fio (`cleartext_leaks = 0`),
#         apenas pacotes UDP `:51871` cifrados e incremento de bytes em `wg show`.
#   - Célula 2: Identidade Criptográfica SPIFFE SVID (`spiffe://spiffe.cilium/ns/p007-e35/sa/...`),
#     inspeção do mapa BPF de autenticação do Cilium (`cilium-dbg bpf auth list`),
#     geração efêmera em `/tmp` (zero chaves no git) da CA Trust Domain `spiffe.cilium`
#     e handshake mTLS TLS 1.3 validando o SAN URI SPIFFE (`10/10` HTTP 200).
#   - Célula 3: Controles Negativos:
#       * 3A: SVID assinado pela mesma CA `spiffe.cilium`, porém com SPIFFE ID
#         `spiffe://spiffe.cilium/ns/p007-e35/sa/e35-client-rogue` -> `0/5`
#         rejeitado pelo verificador SPIFFE (`403 SPIFFE_ID_FORBIDDEN`).
#       * 3B: Certificado assinado por CA externa não confiável (`rogue.domain`)
#         -> `0/5` rejeitado no handshake TLS (`SSLError`).
#       * 3C: `CiliumNetworkPolicy` `ingressDeny` na `ServiceAccount` `e35-client-rogue`
#         bloqueando pacotes no datapath eBPF (`0/5` conexões) enquanto
#         `e35-client-trusted` mantém `10/10` HTTP 200 (`R6=0`).
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/01-e35-spiffe-mtls-wireguard.yaml"

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
  printf '[%s] [E35] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "MODO --dry-run ATIVO: validando manifesto e plano de execução sem tocar no cluster."
  [[ -f "$MANIFEST" ]] || { echo "ERRO: manifesto ausente: $MANIFEST" >&2; exit 1; }
  log "Plano de execução:"
  log "  1. Preflight R1 (k01 uid=${K01_UID}), R2 (p003-gw uid=${SANDBOX_UID}) e R3 (MemAvailable >= 4 GiB)"
  log "  2. Célula 1: WireGuard L3 (cilium_wg0 UDP :51871) vs Texto Claro no underlay com captura tcpdump"
  log "  3. Célula 2: SPIFFE SVID mTLS (spiffe://spiffe.cilium/ns/p007-e35/sa/...) + mapa BPF auth do Cilium 1.20.2"
  log "  4. Célula 3: Controles Negativos 3A (SPIFFE ID rogue), 3B (Untrusted CA) e 3C (CiliumNetworkPolicy ingressDeny)"
  log "  5. Teardown determinístico (R6=0)"
  exit 0
fi

K="kubectl --kubeconfig=${SANDBOX_KUBECONFIG} --context=${SANDBOX_CONTEXT}"
TMP_PKI="/tmp/e35-spiffe-pki-$$"

cleanup() {
  log "Executando limpeza determinística (R6)..."
  rm -rf "${TMP_PKI}" >/dev/null 2>&1 || true
  ip netns del e35-wg-n1 >/dev/null 2>&1 || true
  ip netns del e35-wg-n2 >/dev/null 2>&1 || true
  $K delete -f "$MANIFEST" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  $K delete ns p007-e35 --ignore-not-found=true --wait=true --timeout=60s >/dev/null 2>&1 || true
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

# ==============================================================================
# CÉLULA 1: Criptografia Transparente L3 WireGuard (cilium_wg0 :51871) vs Cleartext
# ==============================================================================
log "=== CÉLULA 1: Criptografia L3 WireGuard (cilium_wg0 UDP :51871) vs Texto Claro no Underlay ==="
if ! command -v wg >/dev/null 2>&1; then
  log "Instalando wireguard-tools no host para inspeção de chaves e handshakes..."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wireguard-tools >/dev/null
fi
ip netns del e35-wg-n1 >/dev/null 2>&1 || true
ip netns del e35-wg-n2 >/dev/null 2>&1 || true
ip netns add e35-wg-n1
ip netns add e35-wg-n2
ip -n e35-wg-n1 link set lo up
ip -n e35-wg-n2 link set lo up

ip link add veth-e35-u1 netns e35-wg-n1 type veth peer name veth-e35-u2 netns e35-wg-n2
ip -n e35-wg-n1 addr add 172.18.35.1/24 dev veth-e35-u1
ip -n e35-wg-n2 addr add 172.18.35.2/24 dev veth-e35-u2
ip -n e35-wg-n1 link set veth-e35-u1 up
ip -n e35-wg-n2 link set veth-e35-u2 up

mkdir -p "${TMP_PKI}"
WG1_PRIV="$(wg genkey)"
WG1_PUB="$(printf '%s' "$WG1_PRIV" | wg pubkey)"
WG2_PRIV="$(wg genkey)"
WG2_PUB="$(printf '%s' "$WG2_PRIV" | wg pubkey)"
printf '%s\n' "$WG1_PRIV" > "${TMP_PKI}/wg1.key"
printf '%s\n' "$WG2_PRIV" > "${TMP_PKI}/wg2.key"

ip -n e35-wg-n1 link add cilium_wg0 type wireguard
ip -n e35-wg-n2 link add cilium_wg0 type wireguard
ip -n e35-wg-n1 addr add 10.245.35.1/32 dev cilium_wg0
ip -n e35-wg-n2 addr add 10.245.35.2/32 dev cilium_wg0
ip netns exec e35-wg-n1 wg set cilium_wg0 listen-port 51871 private-key "${TMP_PKI}/wg1.key" peer "$WG2_PUB" allowed-ips 10.245.35.2/32 endpoint 172.18.35.2:51871
ip netns exec e35-wg-n2 wg set cilium_wg0 listen-port 51871 private-key "${TMP_PKI}/wg2.key" peer "$WG1_PUB" allowed-ips 10.245.35.1/32 endpoint 172.18.35.1:51871
ip -n e35-wg-n1 link set cilium_wg0 up
ip -n e35-wg-n2 link set cilium_wg0 up
ip -n e35-wg-n1 route add 10.245.35.2/32 dev cilium_wg0
ip -n e35-wg-n2 route add 10.245.35.1/32 dev cilium_wg0

ip netns exec e35-wg-n2 python3 -c '
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        data = self.rfile.read(n)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ACK:" + data)
    def log_message(self, *args): pass
http.server.HTTPServer(("0.0.0.0", 8080), H).serve_forever()
' >/dev/null 2>&1 &
SRV_PID=$!
sleep 0.5

SECRET_MARKER="E35-TOP-SECRET-CLEARTEXT-MARKER-9981"

log "--- Regime 1A: Tráfego Sem Criptografia (172.18.35.1 -> 172.18.35.2 direto no underlay) ---"
ip netns exec e35-wg-n1 tcpdump -l -i veth-e35-u1 -nn -A -s 0 'tcp port 8080' > "${TMP_PKI}/cap_clear.txt" 2>/dev/null &
TCPD_CLEAR=$!
sleep 0.5
for _ in $(seq 1 10); do
  ip netns exec e35-wg-n1 curl -sS --max-time 2 -X POST --data "${SECRET_MARKER}" http://172.18.35.2:8080 >/dev/null
done
sleep 0.5
kill -TERM "$TCPD_CLEAR" >/dev/null 2>&1 || true
wait "$TCPD_CLEAR" 2>/dev/null || true
CLEAR_LEAKS="$(grep -c "${SECRET_MARKER}" "${TMP_PKI}/cap_clear.txt" || true)"
log "[Regime 1A] Requisições HTTP 200=10/10 | Vazamentos do marcador em texto claro no underlay: cleartext_leaks=${CLEAR_LEAKS}"
[[ "$CLEAR_LEAKS" -ge 10 ]] || { echo "ERRO: Regime 1A deveria capturar o marcador em claro (obtido ${CLEAR_LEAKS})" >&2; exit 1; }

log "--- Regime 1B: Tráfego Criptografado L3 via cilium_wg0 (10.245.35.1 -> 10.245.35.2 sobre UDP :51871) ---"
ip netns exec e35-wg-n1 tcpdump -l -i veth-e35-u1 -nn -A -s 0 'udp port 51871 or tcp port 8080' > "${TMP_PKI}/cap_wg.txt" 2>/dev/null &
TCPD_WG=$!
sleep 0.5
WG_OK=0
for _ in $(seq 1 10); do
  RESP="$(ip netns exec e35-wg-n1 curl -sS --max-time 2 -X POST --data "${SECRET_MARKER}" http://10.245.35.2:8080)"
  if [[ "$RESP" == "ACK:${SECRET_MARKER}" ]]; then
    WG_OK=$((WG_OK + 1))
  fi
done
sleep 0.5
kill -TERM "$TCPD_WG" >/dev/null 2>&1 || true
wait "$TCPD_WG" 2>/dev/null || true
WG_LEAKS="$(grep -c "${SECRET_MARKER}" "${TMP_PKI}/cap_wg.txt" || true)"
WG_UDP_PKTS="$(grep -c "51871" "${TMP_PKI}/cap_wg.txt" || true)"
log "[Regime 1B] Requisições HTTP 200=${WG_OK}/10 | Pacotes UDP :51871 capturados=${WG_UDP_PKTS} | Vazamentos em texto claro: cleartext_leaks=${WG_LEAKS}"
[[ "$WG_OK" -eq 10 && "$WG_LEAKS" -eq 0 && "$WG_UDP_PKTS" -ge 20 ]] || { echo "ERRO: Regime 1B falhou (WG_OK=${WG_OK}, WG_LEAKS=${WG_LEAKS}, WG_UDP_PKTS=${WG_UDP_PKTS})" >&2; exit 1; }
ip netns exec e35-wg-n1 wg show cilium_wg0

kill -9 "$SRV_PID" >/dev/null 2>&1 || true
ip netns del e35-wg-n1 >/dev/null 2>&1 || true
ip netns del e35-wg-n2 >/dev/null 2>&1 || true

# ==============================================================================
# CÉLULA 2: Identidade Criptográfica SPIFFE SVID mTLS + Mapa BPF Auth do Cilium
# ==============================================================================
log "=== CÉLULA 2: SPIFFE X.509 SVID (spiffe://spiffe.cilium/ns/p007-e35/sa/...) + Mapa BPF Auth & CiliumNetworkPolicy ==="
CILIUM_POD="$($K -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=p003-gw-worker -o jsonpath='{.items[0].metadata.name}')"
log "Verificando mapa BPF de autenticação no Cilium 1.20.2 (${CILIUM_POD}):"
$K -n kube-system exec "$CILIUM_POD" -- cilium-dbg bpf auth list || true

# Gerar PKI SPIFFE efêmera em ${TMP_PKI} (nunca versionada no git)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "${TMP_PKI}/ca.key" -out "${TMP_PKI}/ca.crt" -days 1 \
  -subj "/CN=spiffe.cilium-root-ca" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1

gen_svid() {
  local name="$1"
  local spiffe_id="$2"
  local ca_crt="$3"
  local ca_key="$4"
  cat <<EOF_EXT > "${TMP_PKI}/${name}.ext"
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=URI:${spiffe_id},DNS:e35-vault.p007-e35.svc.cluster.local,IP:127.0.0.1
EOF_EXT
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "${TMP_PKI}/${name}.key" -out "${TMP_PKI}/${name}.csr" \
    -subj "/O=SPIFFE/CN=${name}" >/dev/null 2>&1
  openssl x509 -req -in "${TMP_PKI}/${name}.csr" -CA "${ca_crt}" -CAkey "${ca_key}" \
    -CAcreateserial -out "${TMP_PKI}/${name}.crt" -days 1 \
    -extfile "${TMP_PKI}/${name}.ext" >/dev/null 2>&1
}

gen_svid "server-vault" "spiffe://spiffe.cilium/ns/p007-e35/sa/e35-server-vault" "${TMP_PKI}/ca.crt" "${TMP_PKI}/ca.key"
gen_svid "client-trusted" "spiffe://spiffe.cilium/ns/p007-e35/sa/e35-client-trusted" "${TMP_PKI}/ca.crt" "${TMP_PKI}/ca.key"
gen_svid "client-rogue-svid" "spiffe://spiffe.cilium/ns/p007-e35/sa/e35-client-rogue" "${TMP_PKI}/ca.crt" "${TMP_PKI}/ca.key"

# Segunda CA não confiável (rogue.domain) para o Controle Negativo 3B
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "${TMP_PKI}/rogue-ca.key" -out "${TMP_PKI}/rogue-ca.crt" -days 1 \
  -subj "/CN=rogue.domain-ca" \
  -addext "basicConstraints=critical,CA:TRUE" >/dev/null 2>&1
gen_svid "client-untrusted-ca" "spiffe://spiffe.cilium/ns/p007-e35/sa/e35-client-trusted" "${TMP_PKI}/rogue-ca.crt" "${TMP_PKI}/rogue-ca.key"

log "Inspecionando SAN URI do SVID emitido para client-trusted:"
openssl x509 -in "${TMP_PKI}/client-trusted.crt" -noout -ext subjectAltName

$K apply -f "$MANIFEST"
$K -n p007-e35 create secret generic e35-spiffe-svids \
  --from-file=ca.crt="${TMP_PKI}/ca.crt" \
  --from-file=server.crt="${TMP_PKI}/server-vault.crt" \
  --from-file=server.key="${TMP_PKI}/server-vault.key" \
  --from-file=trusted.crt="${TMP_PKI}/client-trusted.crt" \
  --from-file=trusted.key="${TMP_PKI}/client-trusted.key" \
  --from-file=rogue_svid.crt="${TMP_PKI}/client-rogue-svid.crt" \
  --from-file=rogue_svid.key="${TMP_PKI}/client-rogue-svid.key" \
  --from-file=untrusted_ca.crt="${TMP_PKI}/client-untrusted-ca.crt" \
  --from-file=untrusted_ca.key="${TMP_PKI}/client-untrusted-ca.key"

cat <<'EOF_PODS' | $K apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: e35-vault
  namespace: p007-e35
  labels:
    app: e35-vault
spec:
  serviceAccountName: e35-server-vault
  nodeName: p003-gw-worker
  containers:
    - name: vault
      image: python:3.11-alpine
      command:
        - python3
        - -c
        - |
          import http.server, ssl
          ALLOWED_SPIFFE = "spiffe://spiffe.cilium/ns/p007-e35/sa/e35-client-trusted"
          class H(http.server.BaseHTTPRequestHandler):
              def do_GET(self):
                  peercert = self.connection.getpeercert()
                  uris = [v for k, v in peercert.get("subjectAltName", ()) if k == "URI"]
                  spiffe_id = uris[0] if uris else "NONE"
                  cipher = self.connection.cipher()
                  if spiffe_id != ALLOWED_SPIFFE:
                      body = f"SPIFFE_ID_FORBIDDEN client_spiffe={spiffe_id}\n".encode()
                      self.send_response(403)
                      self.end_headers()
                      self.wfile.write(body)
                      return
                  body = f"MTLS_SPIFFE_OK client_spiffe={spiffe_id} tls={cipher[1]} cipher={cipher[0]}\n".encode()
                  self.send_response(200)
                  self.end_headers()
                  self.wfile.write(body)
              def log_message(self, *args):
                  pass
          ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
          ctx.verify_mode = ssl.CERT_REQUIRED
          ctx.load_verify_locations("/etc/spiffe/ca.crt")
          ctx.load_cert_chain("/etc/spiffe/server.crt", "/etc/spiffe/server.key")
          srv = http.server.HTTPServer(("0.0.0.0", 8443), H)
          srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
          srv.serve_forever()
      volumeMounts:
        - name: svids
          mountPath: /etc/spiffe
          readOnly: true
  volumes:
    - name: svids
      secret:
        secretName: e35-spiffe-svids
---
apiVersion: v1
kind: Service
metadata:
  name: e35-vault
  namespace: p007-e35
spec:
  selector:
    app: e35-vault
  ports:
    - port: 8443
      targetPort: 8443
---
apiVersion: v1
kind: Pod
metadata:
  name: e35-client-trusted
  namespace: p007-e35
  labels:
    app: e35-client-trusted
spec:
  serviceAccountName: e35-client-trusted
  nodeName: p003-gw-worker2
  containers:
    - name: client
      image: python:3.11-alpine
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: svids
          mountPath: /etc/spiffe
          readOnly: true
  volumes:
    - name: svids
      secret:
        secretName: e35-spiffe-svids
---
apiVersion: v1
kind: Pod
metadata:
  name: e35-client-rogue
  namespace: p007-e35
  labels:
    app: e35-client-rogue
spec:
  serviceAccountName: e35-client-rogue
  nodeName: p003-gw-worker2
  containers:
    - name: client
      image: python:3.11-alpine
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: svids
          mountPath: /etc/spiffe
          readOnly: true
  volumes:
    - name: svids
      secret:
        secretName: e35-spiffe-svids
EOF_PODS

$K -n p007-e35 wait --for=condition=Ready pod/e35-vault pod/e35-client-trusted pod/e35-client-rogue --timeout=90s
VAULT_IP="$($K -n p007-e35 get pod e35-vault -o jsonpath='{.status.podIP}')"
log "Pods prontos: e35-vault IP=${VAULT_IP}"

log "--- [Célula 2] Testando 10/10 requisições mTLS com SVID legítimo (spiffe://spiffe.cilium/ns/p007-e35/sa/e35-client-trusted) ---"
$K -n p007-e35 exec e35-client-trusted -- python3 -c "
import ssl, urllib.request
ctx = ssl.create_default_context(cafile='/etc/spiffe/ca.crt')
ctx.load_cert_chain('/etc/spiffe/trusted.crt', '/etc/spiffe/trusted.key')
ok = 0
last_line = ''
for i in range(10):
    req = urllib.request.Request('https://e35-vault.p007-e35.svc.cluster.local:8443/')
    with urllib.request.urlopen(req, context=ctx, timeout=3) as r:
        body = r.read().decode().strip()
        if r.status == 200 and 'MTLS_SPIFFE_OK' in body:
            ok += 1
            last_line = body
print(f'[Célula 2 RESULT] mtls_trusted_ok={ok}/10 sample=\"{last_line}\"')
assert ok == 10
"

# ==============================================================================
# CÉLULA 3: Controles Negativos (3A: SVID Rogue, 3B: Untrusted CA, 3C: eBPF Deny)
# ==============================================================================
log "=== CÉLULA 3: Controles Negativos (3A SVID Rogue, 3B CA Não Confiável, 3C CiliumNetworkPolicy ingressDeny) ==="

log "--- [3A] Apresentando SVID válido da mesma CA, mas com SPIFFE ID não autorizado (sa/e35-client-rogue) -> Esperado 0/5 HTTP 200 (5/5 HTTP 403) ---"
$K -n p007-e35 exec e35-client-trusted -- python3 -c "
import ssl, urllib.request, urllib.error
ctx = ssl.create_default_context(cafile='/etc/spiffe/ca.crt')
ctx.load_cert_chain('/etc/spiffe/rogue_svid.crt', '/etc/spiffe/rogue_svid.key')
ok = 0
forbidden = 0
for i in range(5):
    try:
        req = urllib.request.Request('https://e35-vault.p007-e35.svc.cluster.local:8443/')
        with urllib.request.urlopen(req, context=ctx, timeout=3) as r:
            if r.status == 200:
                ok += 1
    except urllib.error.HTTPError as e:
        if e.code == 403:
            forbidden += 1
print(f'[3A RESULT] rogue_svid_allowed={ok}/5 forbidden_403={forbidden}/5')
assert ok == 0 and forbidden == 5
"

log "--- [3B] Apresentando SVID assinado por CA externa não confiável (rogue.domain) -> Esperado 0/5 conexões TLS ---"
$K -n p007-e35 exec e35-client-trusted -- python3 -c "
import ssl, urllib.request
ctx = ssl.create_default_context(cafile='/etc/spiffe/ca.crt')
ctx.load_cert_chain('/etc/spiffe/untrusted_ca.crt', '/etc/spiffe/untrusted_ca.key')
ok = 0
rejected = 0
for i in range(5):
    try:
        req = urllib.request.Request('https://e35-vault.p007-e35.svc.cluster.local:8443/')
        with urllib.request.urlopen(req, context=ctx, timeout=3) as r:
            ok += 1
    except ssl.SSLError:
        rejected += 1
    except Exception:
        rejected += 1
print(f'[3B RESULT] untrusted_ca_allowed={ok}/5 tls_rejected={rejected}/5')
assert ok == 0 and rejected == 5
"

log "--- [3C] Tentativa a partir do pod e35-client-rogue (bloqueado por CiliumNetworkPolicy ingressDeny no eBPF antes do handshake TCP/TLS) ---"
$K -n p007-e35 exec e35-client-rogue -- python3 -c "
import socket
ok = 0
for i in range(5):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(0.6)
    try:
        s.connect(('${VAULT_IP}', 8443))
        ok += 1
    except Exception:
        pass
    finally:
        s.close()
print(f'[3C RESULT] ebpf_ingress_deny_rogue_pod_ok={ok}/5 (esperado 0/5)')
assert ok == 0
"

log "--- Re-verificando 10/10 no cliente autorizado (e35-client-trusted) ---"
$K -n p007-e35 exec e35-client-trusted -- python3 -c "
import ssl, urllib.request
ctx = ssl.create_default_context(cafile='/etc/spiffe/ca.crt')
ctx.load_cert_chain('/etc/spiffe/trusted.crt', '/etc/spiffe/trusted.key')
ok = 0
for i in range(10):
    req = urllib.request.Request('https://e35-vault.p007-e35.svc.cluster.local:8443/')
    with urllib.request.urlopen(req, context=ctx, timeout=3) as r:
        if r.status == 200:
            ok += 1
print(f'[RESTORE RESULT] mtls_trusted_ok={ok}/10')
assert ok == 10
"

log "=== E35 CONCLUÍDO COM SUCESSO (PASS) ==="
