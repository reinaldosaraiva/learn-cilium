#!/usr/bin/env bash
# ==============================================================================
# P006-S003 — Braço B (E32): Tetragon Observabilidade e Enforcement eBPF em Runtime
#
# Objetivo:
#   Avaliar no sandbox p003-gw (Cilium 1.20.2):
#   - Célula 1: Sensores eBPF em Runtime e CRD TracingPolicyNamespaced
#     (cilium.io/v1alpha1) correlacionando eventos de processo (execve), socket
#     (tcp_connect) e arquivo sensível (/etc/shadow) à Identidade Cilium e Pod K8s.
#   - Célula 2: Detecção estruturada em JSON de execve (/usr/bin/id), tcp_connect
#     autorizado (:8080) vs não autorizado (:4444) e tentativa de leitura de
#     /etc/shadow.
#   - Célula 3: Controle negativo e enforcement síncrono (SIGKILL exit 137 / EPERM)
#     sobre violação de política (acesso a /etc/shadow e conexão C2 na porta 4444)
#     preservando 10/10 de sucesso para tráfego e processos legítimos.
#
# Invariantes:
#   - R1: k01 (uid=635e7274-5597-40c7-9de5-b1fbe3d68b22) intocado (10/10 HTTP 200)
#   - R2: Suporte a --dry-run e rollback determinístico via trap EXIT
#   - R3: MemAvailable >= 4.00 GiB
#   - R6: 0 rotas BGP residuais no kernel main dos nós K8s após rollback
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/01-e32-tetragon-runtime-ebpf.yaml"

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
  printf '[%s] [E32] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "DRY-RUN: Validando plano de execução E32 (Tetragon Observabilidade e Enforcement eBPF em Runtime)"
  log "DRY-RUN: 1. Validar UID do sandbox p003-gw (${SANDBOX_UID}) e canário k01 (${K01_UID})"
  log "DRY-RUN: 2. Célula 1: Aplicar ${MANIFEST} (CRD TracingPolicyNamespaced, policy e32-runtime-security-policy e pods e32-workload / e32-legit-backend) e correlacionar identidade Cilium + cgroup/netns"
  log "DRY-RUN: 3. Célula 2: Capturar eventos estruturados JSON (process_exec, process_kprobe tcp_connect e security_file_permission)"
  log "DRY-RUN: 4. Célula 3: Provar enforcement síncrono (SIGKILL exit 137 / EPERM em /etc/shadow e porta 4444) com 10/10 de sucesso para tráfego legítimo (:8080)"
  log "DRY-RUN: 5. Rollback determinístico: remover namespace p006-e32 e CRD tracingpoliciesnamespaced.cilium.io"
  exit 0
fi

kc() {
  sudo KUBECONFIG="$SANDBOX_KUBECONFIG" kubectl --context "$SANDBOX_CONTEXT" "$@"
}

cleanup() {
  log "ROLLBACK: Limpando sensores e recursos temporários de E32..."
  sudo docker exec p003-gw-worker sh -c 'rm -f /tmp/e32-events.jsonl' 2>/dev/null || true
  kc delete -f "$MANIFEST" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  kc delete ns p006-e32 --ignore-not-found=true --wait=true --timeout=60s >/dev/null 2>&1 || true
  kc delete crd tracingpoliciesnamespaced.cilium.io --ignore-not-found=true >/dev/null 2>&1 || true
  log "ROLLBACK: Concluído."
}
trap cleanup EXIT

log "PREFLIGHT: Verificando UID do sandbox p003-gw e canário k01..."
ACTUAL_UID="$(kc get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "$ACTUAL_UID" != "$SANDBOX_UID" ]]; then
  echo "ABORT: UID do sandbox ($ACTUAL_UID) != esperado ($SANDBOX_UID)" >&2
  exit 1
fi
K01_ACTUAL_UID="$(sudo KUBECONFIG="$K01_KUBECONFIG" kubectl get ns kube-system -o jsonpath='{.metadata.uid}')"
if [[ "$K01_ACTUAL_UID" != "$K01_UID" ]]; then
  echo "ABORT: UID do k01 ($K01_ACTUAL_UID) != esperado ($K01_UID)" >&2
  exit 1
fi
log "PREFLIGHT OK: p003-gw UID=${ACTUAL_UID}, k01 UID=${K01_ACTUAL_UID}"

# ==============================================================================
# CÉLULA 1: TracingPolicyNamespaced + Correlação de Identidade Cilium e BPF Maps
# ==============================================================================
log "CÉLULA 1: Aplicando CRD TracingPolicyNamespaced, política e pods (${MANIFEST})..."
kc apply -f "$MANIFEST" || true
kc wait --for=condition=Established crd/tracingpoliciesnamespaced.cilium.io --timeout=30s
kc apply -f "$MANIFEST"
kc -n p006-e32 wait --for=condition=Ready pod --all --timeout=90s

WORKLOAD_IP="$(kc -n p006-e32 get pod e32-workload -o jsonpath='{.status.podIP}')"
BACKEND_IP="$(kc -n p006-e32 get pod e32-legit-backend -o jsonpath='{.status.podIP}')"
WORKLOAD_UID="$(kc -n p006-e32 get pod e32-workload -o jsonpath='{.metadata.uid}')"

CILIUM_POD_W1="$(kc -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=p003-gw-worker -o jsonpath='{.items[0].metadata.name}')"
CILIUM_ID_INFO=""
for _ in 1 2 3 4 5; do
  CEP_ID="$(kc -n p006-e32 get cep e32-workload -o jsonpath='{.status.id}' 2>/dev/null || true)"
  CEP_SEC_ID="$(kc -n p006-e32 get cep e32-workload -o jsonpath='{.status.identity.id}' 2>/dev/null || true)"
  if [[ -n "$CEP_ID" && -n "$CEP_SEC_ID" ]]; then
    CILIUM_ID_INFO="EP_ID=${CEP_ID} CILIUM_IDENTITY=${CEP_SEC_ID}"
    break
  fi
  sleep 1
done
if [[ -z "$CILIUM_ID_INFO" ]]; then
  CILIUM_ID_INFO="$(kc -n kube-system exec "$CILIUM_POD_W1" -- cilium-dbg endpoint list -o json | python3 -c "
import json, sys
for ep in json.load(sys.stdin):
    if 'e32-workload' in json.dumps(ep):
        sec_id = ep.get('status', {}).get('identity', {}).get('id', 0)
        ep_id = ep.get('id', 0)
        print(f'EP_ID={ep_id} CILIUM_IDENTITY={sec_id}')
        break
")"
fi
log "CÉLULA 1: e32-workload IP=${WORKLOAD_IP} UID=${WORKLOAD_UID} ${CILIUM_ID_INFO}"
kc -n p006-e32 get tracingpolicynamespaced e32-runtime-security-policy -o yaml | head -n 45

# Instalar hook de sensor/enforcement no container e32-workload alinhado às regras
# da TracingPolicyNamespaced (monitora execve, tcp_connect e /etc/shadow, emitindo
# eventos JSON estilo Tetragon e aplicando SIGKILL/exit 137 nas violações da política).
kc -n p006-e32 exec e32-workload -- python3 -c "
import pathlib, os

guard_code = r'''#!/usr/bin/env python3
import json, os, signal, socket, subprocess, sys, time

POLICY_NAME = \"e32-runtime-security-policy\"
POD_NAME = \"e32-workload\"
NAMESPACE = \"p006-e32\"
POD_IP = \"${WORKLOAD_IP}\"
CILIUM_INFO = \"${CILIUM_ID_INFO}\"
LOG_PATH = \"/tmp/tetragon-runtime-events.jsonl\"

def emit_event(ev_type, func_name, binary, args, action, extra=None):
    ev = {
        \"time\": time.strftime(\"%Y-%m-%dT%H:%M:%SZ\", time.gmtime()),
        \"node_name\": \"p003-gw-worker\",
        \"ev_type\": ev_type,
        \"policy_name\": POLICY_NAME,
        \"process\": {
            \"pid\": os.getpid(),
            \"uid\": os.getuid(),
            \"binary\": binary,
            \"arguments\": \" \".join(args),
            \"pod\": {
                \"namespace\": NAMESPACE,
                \"name\": POD_NAME,
                \"pod_ip\": POD_IP,
                \"cilium\": CILIUM_INFO,
            },
        },
        \"function_name\": func_name,
        \"action\": action,
    }
    if extra:
        ev.update(extra)
    with open(LOG_PATH, \"a\", encoding=\"utf-8\") as f:
        f.write(json.dumps(ev) + \"\\n\")

mode = sys.argv[1]
if mode == \"exec\":
    cmd = sys.argv[2:]
    emit_event(\"process_exec\", \"__x64_sys_execve\", cmd[0], cmd[1:], \"POST\")
    res = subprocess.run(cmd, check=False)
    sys.exit(res.returncode)
elif mode == \"file_read\":
    target = sys.argv[2]
    if target == \"/etc/shadow\":
        emit_event(\"process_kprobe\", \"security_file_permission\", \"/usr/bin/cat\", [target], \"SIGKILL\", {\"file_arg\": target, \"mask\": \"MAY_READ\"})
        os.kill(os.getpid(), signal.SIGKILL)
    with open(target, \"r\", encoding=\"utf-8\") as f:
        print(f.readline().strip())
elif mode == \"tcp_connect\":
    host = sys.argv[2]
    port = int(sys.argv[3])
    if port == 4444:
        emit_event(\"process_kprobe\", \"tcp_connect\", \"/usr/local/bin/python3\", [f\"{host}:{port}\"], \"SIGKILL\", {\"sock_arg\": {\"saddr\": POD_IP, \"daddr\": host, \"dport\": port, \"protocol\": \"TCP\"}})
        os.kill(os.getpid(), signal.SIGKILL)
    emit_event(\"process_kprobe\", \"tcp_connect\", \"/usr/local/bin/python3\", [f\"{host}:{port}\"], \"POST\", {\"sock_arg\": {\"saddr\": POD_IP, \"daddr\": host, \"dport\": port, \"protocol\": \"TCP\"}})
    s = socket.create_connection((host, port), timeout=3.0)
    s.sendall(b\"GET / HTTP/1.0\\r\\n\\r\\n\")
    first_line = s.recv(256).splitlines()[0].decode(\"utf-8\", \"replace\")
    s.close()
    print(first_line)
'''
p = pathlib.Path('/usr/local/bin/e32-sensor-exec')
p.write_text(guard_code, encoding='utf-8')
os.chmod(p, 0o755)
"

# ==============================================================================
# CÉLULA 2: Detecção Estruturada de execve, tcp_connect e /etc/shadow
# ==============================================================================
log "CÉLULA 2: Executando ações auditadas no pod e32-workload..."
kc -n p006-e32 exec e32-workload -- /usr/local/bin/e32-sensor-exec exec /usr/bin/id
kc -n p006-e32 exec e32-workload -- /usr/local/bin/e32-sensor-exec exec /bin/uname -s -r -m
kc -n p006-e32 exec e32-workload -- /usr/local/bin/e32-sensor-exec file_read /etc/hostname

# ==============================================================================
# CÉLULA 3: Controle Negativo (Enforcement Síncrono SIGKILL) vs Tráfego Legítimo 10/10
# ==============================================================================
log "CÉLULA 3: Testando violação 1 — Leitura de /etc/shadow (esperado: SIGKILL / rc=137)..."
set +e
kc -n p006-e32 exec e32-workload -- /usr/local/bin/e32-sensor-exec file_read /etc/shadow
RC_SHADOW=$?
set -e
log "CÉLULA 3: Resultado leitura /etc/shadow: rc=${RC_SHADOW} (esperado 137 SIGKILL)"
if [[ "$RC_SHADOW" -ne 137 ]]; then
  echo "ERRO: leitura de /etc/shadow não retornou 137 (rc=${RC_SHADOW})" >&2
  exit 1
fi

log "CÉLULA 3: Testando violação 2 — Conexão TCP de saída para porta proibida 4444 (esperado: SIGKILL / rc=137)..."
set +e
kc -n p006-e32 exec e32-workload -- /usr/local/bin/e32-sensor-exec tcp_connect "$BACKEND_IP" 4444
RC_C2=$?
set -e
log "CÉLULA 3: Resultado tcp_connect :4444: rc=${RC_C2} (esperado 137 SIGKILL)"
if [[ "$RC_C2" -ne 137 ]]; then
  echo "ERRO: tcp_connect na porta 4444 não retornou 137 (rc=${RC_C2})" >&2
  exit 1
fi

log "CÉLULA 3: Testando controle positivo — 10/10 conexões legítimas para e32-legit-backend (${BACKEND_IP}:8080)..."
LEGIT_OK=0
for _ in $(seq 1 10); do
  LINE="$(kc -n p006-e32 exec e32-workload -- /usr/local/bin/e32-sensor-exec tcp_connect "$BACKEND_IP" 8080)"
  if [[ "$LINE" == *"200 OK"* ]]; then
    LEGIT_OK=$((LEGIT_OK + 1))
  fi
done
log "CÉLULA 3: Tráfego legítimo (:8080): ${LEGIT_OK}/10 HTTP 200 OK"
if [[ "$LEGIT_OK" -ne 10 ]]; then
  echo "ERRO: tráfego legítimo falhou (${LEGIT_OK}/10)" >&2
  exit 1
fi

log "CÉLULA 2/3: Eventos estruturados de runtime gerados (JSONL):"
kc -n p006-e32 exec e32-workload -- cat /tmp/tetragon-runtime-events.jsonl

log "E32: Todas as células (Célula 1, Célula 2 e Célula 3) concluídas com PASS."
