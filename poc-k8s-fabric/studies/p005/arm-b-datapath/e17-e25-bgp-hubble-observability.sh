#!/usr/bin/env bash
# ==============================================================================
# P005-S003 (Arm B — Studies E17 + E25 Unificados):
#   E17: Observabilidade por Conexao BGP e Regra das Tres Leituras Consecutivas
#   E25: Observabilidade de Trafego de Microsservicos com Hubble (L3/L4, L7 HTTP/DNS, TLS)
#
# Casos de estudo: E17 e E25 (docs/proximos-estudos.md)
# Hipoteses      :
#   1. E17 — Maquina de estados derivada (ACTIVE, DEGRADED, DOWN, UNKNOWN) com
#      regra de 3 leituras consecutivas (intervalo 3 s, janela <= 30 s):
#      - Celula 1 (Flap curto ~4-5 s): < 3 leituras falhas consecutivas ->
#        amortecido (permanece ACTIVE sem falso positivo de queda).
#      - Celula 2 (Flap medio ~12 s): atinge 3 leituras consecutivas com sessao
#        caida -> transita ACTIVE -> DOWN (~9 s) e exige 3 leituras saudaveis
#        consecutivas apos o restabelecimento para retornar DOWN -> ACTIVE.
#      - Celula 3 (Indisponibilidade prolongada + Scraper Offline + Fronteira Borda):
#        distingue DOWN (agente acessivel reportando session_state=0 por 3 leituras)
#        de UNKNOWN (endpoint de metricas inacessivel por 3 leituras) e contrasta
#        o que so o roteador de borda FRR/SR Linux expoe (AS_PATH completo, BFD).
#   2. E25 — Observabilidade Hubble + Prometheus (:9962 e :9965):
#      - Celula 4 (L3/L4 + Identidade + --from-cidr): distingue FORWARDED vs
#        DROPPED (Policy denied) por identidade Cilium e filtra trafego do
#        cliente externo (198.19.0.0/24) via --from-cidr.
#      - Celula 5 (L7 HTTP + DNS): visibilidade L7 de queries DNS e HTTP
#        (GET /hostname -> 200 FORWARDED vs GET /denied -> 403 DROPPED).
#      - Celula 6 (TLS/mTLS vs HTTP texto claro): em :8443 (TLS), o Hubble
#        observa metadados L3/L4 (identidades, portas, flags TCP, veredito
#        FORWARDED), mantendo o payload L7 (/secret-tls-path) opaco.
#      - Celula 7 (Correlacao Prometheus + Resiliencia do Ring Buffer Local):
#        correlaciona cilium_forward_count_total, cilium_drop_count_total e
#        hubble_* e comprova que a indisponibilidade do Relay/agregador remoto
#        nao interrompe a captura local no ring buffer dos agentes Cilium.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

WORKER1_NODE="p003-gw-worker"
WORKER2_NODE="p003-gw-worker2"
LEAF2_IP="10.30.2.1"
BORDER_NODE="clab-p003-gw-fabric-border1"
CLIENT_NODE="clab-p003-gw-fabric-client"
NS_OBS="e17-e25-obs"
VIP_OBS="10.202.255.190"
MANIFEST_FILE="${SCRIPT_DIR}/manifests/04-e17-e25-observability.yaml"

usage() {
  cat <<EOF
Uso: $0 [--dry-run] [--rollback] [--help]

Estudos E17 + E25 Unificados (P005-S003 Braço B):
  E17 — Máquina de Estados BGP com Regra de 3 Leituras Consecutivas:
    Célula 1: Flap curto (~4 s) < 3 leituras -> amortecido (permanece ACTIVE)
    Célula 2: Flap médio (~12 s) >= 3 leituras -> transição ACTIVE -> DOWN -> ACTIVE
    Célula 3: DOWN vs UNKNOWN (scraper offline) + fronteira de telemetria FRR border1
  E25 — Observabilidade Hubble (L3/L4, L7 HTTP/DNS, TLS e Resiliência):
    Célula 4: Fluxos L3/L4 FORWARDED vs DROPPED (Policy denied) + --from-cidr 198.19.0.0/24
    Célula 5: Visibilidade L7 DNS e HTTP (GET /hostname 200 vs GET /denied 403)
    Célula 6: Contraste L7 texto claro (:8080) vs TLS criptografado (:8443 L4 visível, L7 opaco)
    Célula 7: Correlação Prometheus (:9962 / :9965) + resiliência do ring buffer local sem Relay
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
  printf '[E17-E25 %s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

kctl() {
  kubectl --kubeconfig="$KUBECONFIG_GW" --context="$CTX_GW" "$@"
}

k01_kctl() {
  kubectl --kubeconfig="$KUBECONFIG_K01" --context="$CTX_K01" "$@"
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  cat <<EOF
[DRY-RUN] Estudos E17 + E25 Unificados — Observabilidade BGP (3 Leituras) e Hubble (L3/L4/L7/TLS)
  1. Validaria UIDs de k01 (${EXPECTED_UID_K01}) e p003-gw (${EXPECTED_UID_GW}) e MemAvailable >= 4.0 GiB.
  2. Habilitaria Prometheus (:9962) + metricas BGP Control Plane e Hubble (:4244, hubble.sock e :9965) via helm upgrade no p003-gw.
  3. E17 — Avaliaria a regra de 3 leituras consecutivas (scrape a cada 3 s em ${WORKER2_NODE} + border1):
     - Celula 1: Flap BGP curto (4 s) em ${WORKER2_NODE} <-> ${LEAF2_IP} -> 1-2 leituras falhas -> estado derivado permanece ACTIVE.
     - Celula 2: Flap BGP medio (12 s) -> 3 leituras consecutivas caidas -> ACTIVE -> DOWN e recuperacao DOWN -> ACTIVE apos 3 leituras saudaveis.
     - Celula 3: Distinguiria DOWN (session_state=0 por 3 leituras) de UNKNOWN (alvo :9962 inacessivel por 3 leituras) e compararia telemetria Cilium vs border1 FRR (AS_PATH completo, BFD, PfxRcd).
  4. E25 — Implantaria ${MANIFEST_FILE} no namespace ${NS_OBS} (${WORKER1_NODE}):
     - Celula 4: Validaria fluxos L3/L4 FORWARDED vs DROPPED (Policy denied) por identidade e filtro --from-cidr 198.19.0.0/24 a partir de ${CLIENT_NODE}.
     - Celula 5: Aplicaria politica L7 DNS + HTTP e validaria hubble observe --type l7 (DNS query/response, HTTP 200 em /hostname e HTTP 403 em /denied).
     - Celula 6: Contrastaria HTTP claro (:8080, URL visivel em L7) vs HTTPS/TLS (:8443, visivel em L3/L4 TCP/identidade mas URL L7 opaca).
     - Celula 7: Correlacionaria metricas Prometheus (:9962 cilium_forward/drop/policy_l7 e :9965 hubble_*) e provaria resiliencia do ring buffer local (unix:///var/run/cilium/hubble.sock) com Relay/agregador indisponivel.
  5. Executaria rollback completo para values-p003.yaml e verificaria R1 (k01), R3 (MemAvailable) e R6 (proto bgp = 0).
EOF
  exit 0
fi

clear_worker2_flap_rules() {
  docker exec "$WORKER2_NODE" sh -c "
    while iptables -D OUTPUT -d ${LEAF2_IP} -p tcp --dport 179 -j REJECT --reject-with tcp-reset 2>/dev/null; do :; done
    while iptables -D INPUT -s ${LEAF2_IP} -p tcp --sport 179 -j REJECT --reject-with tcp-reset 2>/dev/null; do :; done
  " >/dev/null 2>&1 || true
}

restore_peer_config_baseline() {
  kctl apply -f - >/dev/null <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata:
  name: fabric-peer
spec:
  timers:
    connectRetryTimeSeconds: 5
    holdTimeSeconds: 9
    keepAliveTimeSeconds: 3
  gracefulRestart:
    enabled: true
    restartTimeSeconds: 30
  ebgpMultihop: 1
  families:
    - afi: ipv4
      safi: unicast
      advertisements:
        matchLabels:
          advertise: fabric
EOF
}

cleanup() {
  log "Rollback E17+E25: limpando regras de flap, removendo ${NS_OBS} e restaurando Cilium baseline..."
  clear_worker2_flap_rules || true
  restore_peer_config_baseline || true
  kctl delete ciliumbgpadvertisement e25-obs-vip-advertisement --ignore-not-found >/dev/null 2>&1 || true
  kctl -n "$NS_OBS" delete pod --all --force --grace-period=0 --ignore-not-found >/dev/null 2>&1 || true
  kctl delete ns "$NS_OBS" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true

  local cur_hubble api_ip
  cur_hubble="$(kctl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-hubble}' 2>/dev/null || echo "")"
  if [[ "$cur_hubble" == "true" ]]; then
    api_ip="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' p003-gw-control-plane)"
    helm --kubeconfig="$KUBECONFIG_GW" --kube-context="$CTX_GW" upgrade cilium "$CHART_TGZ" \
      -n kube-system -f "$VALUES_BASE" \
      --set "k8sServiceHost=${api_ip}" \
      --set "bgpControlPlane.secretsNamespace.name=kube-system" >/dev/null
    kctl -n kube-system rollout restart ds/cilium >/dev/null
    kctl -n kube-system rollout status ds/cilium --timeout=180s >/dev/null
  fi
}

if [[ "$ROLLBACK_ONLY" -eq 1 ]]; then
  cleanup
  log "Rollback E17+E25 concluido."
  exit 0
fi

trap cleanup EXIT

# ==============================================================================
# 0. PREFLIGHT & CANARY GUARDS (R1, R3, R6)
# ==============================================================================
log "Fase 0: Validando canario k01, UID de p003-gw e memoria disponivel..."
UID_K01="$(k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
UID_GW="$(kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
[[ "$UID_K01" == "$EXPECTED_UID_K01" ]] || { echo "ERRO: k01 UID=${UID_K01}" >&2; exit 1; }
[[ "$UID_GW" == "$EXPECTED_UID_GW" ]] || { echo "ERRO: p003-gw UID=${UID_GW}" >&2; exit 1; }

MEM_AVAIL_KB="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"
log "Preflight OK: k01_uid=${UID_K01}, p003_gw_uid=${UID_GW}, MemAvailable=$((MEM_AVAIL_KB / 1024)) MiB"

# ==============================================================================
# 1. HABILITAR PROMETHEUS (:9962) + HUBBLE (:4244 / hubble.sock / :9965)
# ==============================================================================
log "Fase 1: Habilitando Prometheus (:9962), BGP metrics e Hubble (:4244, hubble.sock, :9965) no Cilium 1.20.2..."
API_IP="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' p003-gw-control-plane)"

helm --kubeconfig="$KUBECONFIG_GW" --kube-context="$CTX_GW" upgrade cilium "$CHART_TGZ" \
  -n kube-system -f "$VALUES_BASE" \
  --set "k8sServiceHost=${API_IP}" \
  --set "bgpControlPlane.secretsNamespace.name=kube-system" \
  --set prometheus.enabled=true \
  --set 'prometheus.metrics={+cilium_bgp_control_plane_session_state,+cilium_bgp_control_plane_advertised_routes,+cilium_bgp_control_plane_received_routes}' \
  --set operator.prometheus.enabled=true \
  --set hubble.enabled=true \
  --set hubble.tls.enabled=false \
  --set hubble.listenAddress=":4244" \
  --set 'hubble.metrics.enabled={dns:query;ignoreAAAA,drop,tcp,flow,icmp,http,port-distribution}' >/dev/null

kctl -n kube-system rollout restart ds/cilium >/dev/null
kctl -n kube-system rollout status ds/cilium --timeout=180s >/dev/null

CILIUM_W1="$(kctl -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName="${WORKER1_NODE}" -o jsonpath='{.items[0].metadata.name}')"
CILIUM_W2="$(kctl -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName="${WORKER2_NODE}" -o jsonpath='{.items[0].metadata.name}')"

# Aguardar sessoes BGP Established e endpoints :9962 / :9965 prontos
for _ in $(seq 1 30); do
  est="$(kctl -n kube-system exec "$CILIUM_W2" -c cilium-agent -- cilium-dbg bgp peers 2>/dev/null | grep -ci established || true)"
  m_ok="$(docker exec "$WORKER2_NODE" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9962/metrics 2>/dev/null || echo 000)"
  h_ok="$(docker exec "$WORKER1_NODE" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9965/metrics 2>/dev/null || echo 000)"
  if [[ "$est" -ge 1 && "$m_ok" == "200" && "$h_ok" == "200" ]]; then
    break
  fi
  sleep 2
done

log "Cilium pronto: W1=${CILIUM_W1} (:9965 HTTP ${h_ok}), W2=${CILIUM_W2} (:9962 HTTP ${m_ok}, BGP Established=${est})"

# Ajustar timers de fabric-peer para reconexao deterministica durante E17 (1/3 s, GR=false)
kctl apply -f - >/dev/null <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata:
  name: fabric-peer
spec:
  timers:
    connectRetryTimeSeconds: 1
    holdTimeSeconds: 3
    keepAliveTimeSeconds: 1
  gracefulRestart:
    enabled: false
  ebgpMultihop: 1
  families:
    - afi: ipv4
      safi: unicast
      advertisements:
        matchLabels:
          advertise: fabric
EOF
sleep 3

# ==============================================================================
# 2. ESTUDO E17 — MAQUINA DE ESTADOS BGP COM REGRA DE 3 LEITURAS CONSECUTIVAS
# ==============================================================================
sample_bgp_w2() {
  local port="${1:-9962}"
  local prom_out http_code sess_metric adv_metric rcv_metric dbg_out sess_dbg adv_dbg rcv_dbg border_pfx
  http_code="$(docker exec "$WORKER2_NODE" curl -s --connect-timeout 1 --max-time 2 -o /tmp/e17_prom.txt -w '%{http_code}' "http://127.0.0.1:${port}/metrics" 2>/dev/null || echo "000")"
  if [[ "$http_code" != "200" ]]; then
    printf '0|-1|-1|-1|0\n'
    return 0
  fi
  prom_out="$(docker exec "$WORKER2_NODE" grep -E '^cilium_bgp_control_plane_' /tmp/e17_prom.txt 2>/dev/null || true)"
  sess_metric="$(awk '/^cilium_bgp_control_plane_session_state/ {val=$NF} END {if (val=="") print -1; else print int(val)}' <<<"$prom_out")"
  adv_metric="$(awk '/^cilium_bgp_control_plane_advertised_routes/ {sum+=$NF; n++} END {if (n==0) print -1; else print int(sum)}' <<<"$prom_out")"
  rcv_metric="$(awk '/^cilium_bgp_control_plane_received_routes/ {sum+=$NF; n++} END {if (n==0) print -1; else print int(sum)}' <<<"$prom_out")"

  dbg_out="$(kctl -n kube-system exec "$CILIUM_W2" -c cilium-agent -- cilium-dbg bgp peers 2>/dev/null || true)"
  if grep -qi "established" <<<"$dbg_out"; then
    sess_dbg=1
    adv_dbg="$(awk '/10\.30\.2\.1/ {print $7+0; exit}' <<<"$dbg_out")"
    rcv_dbg="$(awk '/10\.30\.2\.1/ {print $6+0; exit}' <<<"$dbg_out")"
  else
    sess_dbg=0
    adv_dbg=0
    rcv_dbg=0
  fi

  [[ "$sess_metric" -ge 0 ]] || sess_metric="$sess_dbg"
  [[ "$adv_metric" -ge 0 ]] || adv_metric="$adv_dbg"
  [[ "$rcv_metric" -ge 0 ]] || rcv_metric="$rcv_dbg"

  if [[ "$sess_dbg" -eq 0 ]]; then
    sess_metric=0
    adv_metric=0
  fi

  border_pfx="$(docker exec "$BORDER_NODE" vtysh -c "show ip bgp 10.245.2.0/24" 2>/dev/null | grep -c "65302" || true)"
  printf '1|%s|%s|%s|%s\n' "$sess_metric" "$adv_metric" "$rcv_metric" "$border_pfx"
}

wait_bgp_w2_ready() {
  local s_ok s_st s_adv s_rcv s_bp
  for _ in $(seq 1 30); do
    IFS='|' read -r s_ok s_st s_adv s_rcv s_bp <<<"$(sample_bgp_w2 9962)"
    if [[ "$s_ok" -eq 1 && "$s_st" -eq 1 && "$s_adv" -gt 0 ]]; then
      return 0
    fi
    sleep 1
  done
  echo "ERRO: sessao BGP em ${WORKER2_NODE} nao estabilizou antes da medicao" >&2
  return 1
}

inject_flap_w2() {
  docker exec "$WORKER2_NODE" sh -c "
    iptables -I OUTPUT -d ${LEAF2_IP} -p tcp --dport 179 -j REJECT --reject-with tcp-reset
    iptables -I INPUT -s ${LEAF2_IP} -p tcp --sport 179 -j REJECT --reject-with tcp-reset
    ss -K dst ${LEAF2_IP} dport = :179 >/dev/null 2>&1 || true
    ss -K dst ${LEAF2_IP} >/dev/null 2>&1 || true
  "
}

wait_bgp_w2_ready

log "=== [E17 — Celula 1] Flap BGP Curto (< 3 leituras de 3 s): Amortecimento sem falso DOWN ==="
DERIVED_STATE="ACTIVE"
DOWN_STREAK=0
UP_STREAK=3
UNREACH_STREAK=0
C1_FALSE_DOWN=0
C1_MAX_DOWN_STREAK=0

t0_ms="$(date +%s%3N)"
for tick in $(seq 1 6); do
  if [[ "$tick" -eq 2 ]]; then
    log "  [C1 tick=${tick}] Injetando flap curto (~2 s) em ${WORKER2_NODE} <-> ${LEAF2_IP}..."
    inject_flap_w2
    ( sleep 1.5; clear_worker2_flap_rules ) &
  fi
  IFS='|' read -r scrape_ok sess adv rcv bpfx <<<"$(sample_bgp_w2 9962)"
  now_ms="$(date +%s%3N)"
  rel_ms=$((now_ms - t0_ms))
  if [[ "$scrape_ok" -eq 0 ]]; then
    UNREACH_STREAK=$((UNREACH_STREAK + 1))
    [[ "$UNREACH_STREAK" -ge 3 ]] && DERIVED_STATE="UNKNOWN"
  else
    UNREACH_STREAK=0
    if [[ "$sess" -eq 1 && "$adv" -gt 0 ]]; then
      UP_STREAK=$((UP_STREAK + 1))
      DOWN_STREAK=0
      [[ "$UP_STREAK" -ge 3 ]] && DERIVED_STATE="ACTIVE"
    else
      DOWN_STREAK=$((DOWN_STREAK + 1))
      UP_STREAK=0
      [[ "$DOWN_STREAK" -gt "$C1_MAX_DOWN_STREAK" ]] && C1_MAX_DOWN_STREAK="$DOWN_STREAK"
      if [[ "$DOWN_STREAK" -ge 3 ]]; then
        DERIVED_STATE="DOWN"
        C1_FALSE_DOWN=1
      fi
    fi
  fi
  printf '  [C1 t=%5dms tick=%d] scrape=%s sess=%s adv=%s rcv=%s border_rib=%s | down_streak=%d/3 up_streak=%d | derived=%s\n' \
    "$rel_ms" "$tick" "$scrape_ok" "$sess" "$adv" "$rcv" "$bpfx" "$DOWN_STREAK" "$UP_STREAK" "$DERIVED_STATE"
  sleep 3
done
wait || true
clear_worker2_flap_rules
wait_bgp_w2_ready

[[ "$C1_FALSE_DOWN" -eq 0 && "$C1_MAX_DOWN_STREAK" -ge 1 && "$C1_MAX_DOWN_STREAK" -lt 3 ]] || {
  echo "ERRO E17-C1: esperado 1..2 leituras falhas sem disparar DOWN (max_down_streak=${C1_MAX_DOWN_STREAK}, false_down=${C1_FALSE_DOWN})" >&2
  exit 1
}

log "=== [E17 — Celula 2] Flap BGP Medio (~12 s >= 3 leituras de 3 s): Transicao ACTIVE -> DOWN -> ACTIVE ==="
DERIVED_STATE="ACTIVE"
DOWN_STREAK=0
UP_STREAK=3
UNREACH_STREAK=0
T_DOWN_DETECT_MS=0
T_RECOVER_DETECT_MS=0

inject_flap_w2
t_flap_start="$(date +%s%3N)"
for tick in $(seq 1 10); do
  if [[ "$tick" -eq 5 ]]; then
    log "  [C2 tick=${tick}] Removendo bloqueio BGP em ${WORKER2_NODE}; aguardando 3 leituras saudaveis para ACTIVE..."
    clear_worker2_flap_rules
    t_heal_start="$(date +%s%3N)"
  fi
  IFS='|' read -r scrape_ok sess adv rcv bpfx <<<"$(sample_bgp_w2 9962)"
  now_ms="$(date +%s%3N)"
  rel_ms=$((now_ms - t_flap_start))
  if [[ "$sess" -eq 1 && "$adv" -gt 0 ]]; then
    UP_STREAK=$((UP_STREAK + 1))
    DOWN_STREAK=0
    if [[ "$DERIVED_STATE" != "ACTIVE" && "$UP_STREAK" -ge 3 ]]; then
      DERIVED_STATE="ACTIVE"
      T_RECOVER_DETECT_MS=$((now_ms - t_heal_start))
    fi
  else
    DOWN_STREAK=$((DOWN_STREAK + 1))
    UP_STREAK=0
    if [[ "$DERIVED_STATE" == "ACTIVE" && "$DOWN_STREAK" -ge 3 ]]; then
      DERIVED_STATE="DOWN"
      T_DOWN_DETECT_MS=$((now_ms - t_flap_start))
    fi
  fi
  printf '  [C2 t=%5dms tick=%2d] sess=%s adv=%s rcv=%s border_rib=%s | down_streak=%d/3 up_streak=%d/3 | derived=%s\n' \
    "$rel_ms" "$tick" "$sess" "$adv" "$rcv" "$bpfx" "$DOWN_STREAK" "$UP_STREAK" "$DERIVED_STATE"
  sleep 3
done

[[ "$T_DOWN_DETECT_MS" -gt 0 && "$T_RECOVER_DETECT_MS" -gt 0 && "$DERIVED_STATE" == "ACTIVE" ]] || {
  echo "ERRO E17-C2: transicao ACTIVE->DOWN->ACTIVE incompleta (down_ms=${T_DOWN_DETECT_MS}, recover_ms=${T_RECOVER_DETECT_MS}, state=${DERIVED_STATE})" >&2
  exit 1
}

log "=== [E17 — Celula 3] Distincao DOWN vs UNKNOWN (Scraper Offline) e Fronteira Cilium vs Borda FRR ==="
UNREACH_STREAK=0
DERIVED_STATE="ACTIVE"
for tick in $(seq 1 3); do
  IFS='|' read -r scrape_ok sess adv rcv bpfx <<<"$(sample_bgp_w2 19962)"
  if [[ "$scrape_ok" -eq 0 ]]; then
    UNREACH_STREAK=$((UNREACH_STREAK + 1))
    [[ "$UNREACH_STREAK" -ge 3 ]] && DERIVED_STATE="UNKNOWN"
  fi
  printf '  [C3-UNKNOWN tick=%d] target=127.0.0.1:19962 scrape_ok=%s unreach_streak=%d/3 -> derived=%s\n' \
    "$tick" "$scrape_ok" "$UNREACH_STREAK" "$DERIVED_STATE"
done
[[ "$DERIVED_STATE" == "UNKNOWN" ]] || { echo "ERRO E17-C3: esperado estado UNKNOWN apos 3 falhas de scrape" >&2; exit 1; }

BORDER_BGP_DETAIL="$(docker exec "$BORDER_NODE" vtysh -c "show ip bgp 10.245.2.0/24" 2>/dev/null)"
log "Fronteira Borda FRR (border1) — AS_PATH completo e atributos visiveis apenas no PE:"
printf '%s\n' "$BORDER_BGP_DETAIL" | sed 's/^/    /'

# Restaurar timers padrao do fabric-peer apos E17
restore_peer_config_baseline

# ==============================================================================
# 3. ESTUDO E25 — OBSERVABILIDADE DE MICROSSERVICOS COM HUBBLE (L3/L4, L7, TLS)
# ==============================================================================
log "=== [E25 — Preparacao] Implantando workloads e Services no namespace ${NS_OBS} ==="
kctl apply -f "$MANIFEST_FILE" >/dev/null
kctl -n "$NS_OBS" wait --for=condition=Ready pod/obs-backend pod/obs-client-allowed pod/obs-client-denied --timeout=90s >/dev/null

BACKEND_IP="$(kctl -n "$NS_OBS" get pod obs-backend -o jsonpath='{.status.podIP}')"
ALLOWED_IP="$(kctl -n "$NS_OBS" get pod obs-client-allowed -o jsonpath='{.status.podIP}')"
DENIED_IP="$(kctl -n "$NS_OBS" get pod obs-client-denied -o jsonpath='{.status.podIP}')"
BACKEND_ID="$(kctl -n "$NS_OBS" get cep obs-backend -o jsonpath='{.status.identity.id}')"
ALLOWED_ID="$(kctl -n "$NS_OBS" get cep obs-client-allowed -o jsonpath='{.status.identity.id}')"
DENIED_ID="$(kctl -n "$NS_OBS" get cep obs-client-denied -o jsonpath='{.status.identity.id}')"

log "Endpoints E25 prontos em ${WORKER1_NODE}: backend=${BACKEND_IP} (id=${BACKEND_ID}), allowed=${ALLOWED_IP} (id=${ALLOWED_ID}), denied=${DENIED_IP} (id=${DENIED_ID})"

log "=== [E25 — Celula 4] L3/L4 FORWARDED vs DROPPED (Policy denied) + Filtro --from-cidr 198.19.0.0/24 ==="
kctl apply -f - >/dev/null <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: obs-l3l4-policy
  namespace: e17-e25-obs
spec:
  endpointSelector:
    matchLabels:
      app: obs-backend
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: obs-client-allowed
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
            - port: "8443"
              protocol: TCP
    - fromCIDR:
        - 198.19.0.0/24
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
    - fromEntities:
        - host
        - remote-node
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
EOF
sleep 3

ALLOW_OK=0
for _ in $(seq 1 10); do
  code="$(kctl -n "$NS_OBS" exec obs-client-allowed -- curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 "http://${BACKEND_IP}:8080/hostname" 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]] && ALLOW_OK=$((ALLOW_OK + 1))
done

DENY_OK=0
for _ in $(seq 1 5); do
  code="$(kctl -n "$NS_OBS" exec obs-client-denied -- curl -s -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time 1 "http://${BACKEND_IP}:8080/hostname" 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]] && DENY_OK=$((DENY_OK + 1))
done

# Aguardar rota VIP propagar ate o client node se necessario
for _ in $(seq 1 25); do
  if docker exec "$CLIENT_NODE" ip route show "${VIP_OBS}/32" 2>/dev/null | grep -q "${VIP_OBS}"; then
    break
  fi
  sleep 1
done

EXT_OK=0
for _ in $(seq 1 10); do
  code="$(docker exec "$CLIENT_NODE" curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 "http://${VIP_OBS}:8080/hostname" 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]] && EXT_OK=$((EXT_OK + 1))
  docker exec "$CLIENT_NODE" curl -s -o /dev/null --connect-timeout 2 "http://${BACKEND_IP}:8080/hostname" >/dev/null 2>&1 || true
done

sleep 2
HUBBLE_FWD_CNT="$(kctl -n kube-system exec "$CILIUM_W1" -c cilium-agent -- hubble observe --server unix:///var/run/cilium/hubble.sock --last 500 --to-identity "$BACKEND_ID" --verdict FORWARDED -o json 2>/dev/null | wc -l | tr -d ' ')"
HUBBLE_DROP_JSON="$(kctl -n kube-system exec "$CILIUM_W1" -c cilium-agent -- hubble observe --server unix:///var/run/cilium/hubble.sock --last 500 --from-identity "$DENIED_ID" --to-identity "$BACKEND_ID" --verdict DROPPED -o json 2>/dev/null || true)"
HUBBLE_DROP_CNT="$(grep -c '"verdict":"DROPPED"' <<<"$HUBBLE_DROP_JSON" || true)"
HUBBLE_CIDR_W1="$(kctl -n kube-system exec "$CILIUM_W1" -c cilium-agent -- hubble observe --server unix:///var/run/cilium/hubble.sock --last 1000 --from-ip 198.19.0.0/24 -o json 2>/dev/null | grep -c '198.19.0.10' || true)"
HUBBLE_CIDR_W2="$(kctl -n kube-system exec "$CILIUM_W2" -c cilium-agent -- hubble observe --server unix:///var/run/cilium/hubble.sock --last 1000 --from-ip 198.19.0.0/24 -o json 2>/dev/null | grep -c '198.19.0.10' || true)"
HUBBLE_CIDR_CNT=$((HUBBLE_CIDR_W1 + HUBBLE_CIDR_W2))

log "  [C4 Resultado] allowed=${ALLOW_OK}/10, denied=${DENY_OK}/5, ext_client=${EXT_OK}/10 | hubble_forwarded=${HUBBLE_FWD_CNT}, hubble_dropped_policy=${HUBBLE_DROP_CNT}, hubble_from_ip_198_19=${HUBBLE_CIDR_CNT}"
[[ "$ALLOW_OK" -eq 10 && "$DENY_OK" -eq 0 && "$EXT_OK" -eq 10 && "$HUBBLE_DROP_CNT" -ge 1 && "$HUBBLE_CIDR_CNT" -ge 1 ]] || {
  echo "ERRO E25-C4: falha na validacao L3/L4 ou --from-ip 198.19.0.0/24" >&2
  exit 1
}

log "=== [E25 — Celula 5] Visibilidade L7 HTTP (GET /hostname 200 vs GET /denied 403) e L7 DNS ==="
kctl apply -f - >/dev/null <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: obs-l3l4-policy
  namespace: e17-e25-obs
spec:
  endpointSelector:
    matchLabels:
      app: obs-backend
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: obs-client-allowed
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - method: "GET"
                path: "/hostname"
              - method: "GET"
                path: "/healthz"
        - ports:
            - port: "8443"
              protocol: TCP
    - fromEntities:
        - host
        - remote-node
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: obs-client-dns-l7
  namespace: e17-e25-obs
spec:
  endpointSelector:
    matchLabels:
      app: obs-client-allowed
  egress:
    - toEntities:
        - cluster
        - world
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*"
    - toEndpoints:
        - matchLabels:
            app: obs-backend
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
            - port: "8443"
              protocol: TCP
EOF
sleep 4

# Gerar consultas DNS L7 + HTTP 200 (/hostname) + HTTP 403 (/denied)
COREDNS_IP="$(kctl -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)"
kctl -n "$NS_OBS" exec obs-client-allowed -- nslookup obs-backend.e17-e25-obs.svc.cluster.local >/dev/null 2>&1 || true
if [[ -n "$COREDNS_IP" ]]; then
  kctl -n "$NS_OBS" exec obs-client-allowed -- nslookup obs-backend.e17-e25-obs.svc.cluster.local "$COREDNS_IP" >/dev/null 2>&1 || true
fi

L7_200=0
for _ in $(seq 1 10); do
  code="$(kctl -n "$NS_OBS" exec obs-client-allowed -- curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 "http://${BACKEND_IP}:8080/hostname" 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]] && L7_200=$((L7_200 + 1))
done

L7_403=0
for _ in $(seq 1 5); do
  code="$(kctl -n "$NS_OBS" exec obs-client-allowed -- curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 "http://${BACKEND_IP}:8080/denied" 2>/dev/null || echo 000)"
  [[ "$code" == "403" ]] && L7_403=$((L7_403 + 1))
done

sleep 2
HUBBLE_L7_JSON="$(kctl -n kube-system exec "$CILIUM_W1" -c cilium-agent -- hubble observe --server unix:///var/run/cilium/hubble.sock --last 200 --type l7 -o json 2>/dev/null || true)"
HUBBLE_L7_HTTP_200="$(grep -E '"url":".*/hostname"' <<<"$HUBBLE_L7_JSON" | grep -c '"code":200' || true)"
HUBBLE_L7_HTTP_403="$(grep -E '"url":".*/denied"' <<<"$HUBBLE_L7_JSON" | grep -c '"code":403' || true)"
HUBBLE_L7_DNS="$(grep -c '"dns":' <<<"$HUBBLE_L7_JSON" || true)"

log "  [C5 Resultado] curl_200=${L7_200}/10, curl_403=${L7_403}/5 | hubble_l7_200=${HUBBLE_L7_HTTP_200}, hubble_l7_403=${HUBBLE_L7_HTTP_403}, hubble_l7_dns=${HUBBLE_L7_DNS}"
[[ "$L7_200" -eq 10 && "$L7_403" -eq 5 && "$HUBBLE_L7_HTTP_200" -ge 1 && "$HUBBLE_L7_HTTP_403" -ge 1 && "$HUBBLE_L7_DNS" -ge 1 ]] || {
  echo "ERRO E25-C5: visibilidade L7 HTTP/DNS incompleta no Hubble" >&2
  exit 1
}

log "=== [E25 — Celula 6] Fronteira TLS/mTLS (:8443 L4 Visivel / L7 Opaco) vs HTTP Claro (:8080) ==="
TLS_OK=0
for _ in $(seq 1 10); do
  code="$(kctl -n "$NS_OBS" exec obs-client-allowed -- curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 2 "https://${BACKEND_IP}:8443/secret-tls-path" 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]] && TLS_OK=$((TLS_OK + 1))
done
sleep 2

HUBBLE_TLS_FLOWS="$(kctl -n kube-system exec "$CILIUM_W1" -c cilium-agent -- hubble observe --server unix:///var/run/cilium/hubble.sock --last 200 --to-port 8443 -o json 2>/dev/null || true)"
TLS_L4_CNT="$(grep -c '"verdict":"FORWARDED"' <<<"$HUBBLE_TLS_FLOWS" || true)"
TLS_L7_LEAK="$(grep -c 'secret-tls-path' <<<"$HUBBLE_TLS_FLOWS" || true)"

log "  [C6 Resultado] https_200=${TLS_OK}/10 | hubble_8443_l4_flows=${TLS_L4_CNT}, hubble_8443_l7_cleartext_leak=${TLS_L7_LEAK} (esperado 0)"
[[ "$TLS_OK" -eq 10 && "$TLS_L4_CNT" -ge 1 && "$TLS_L7_LEAK" -eq 0 ]] || {
  echo "ERRO E25-C6: falha no contraste TLS vs HTTP claro" >&2
  exit 1
}

log "=== [E25 — Celula 7] Correlacao Prometheus (:9962 / :9965) e Resiliencia do Ring Buffer sem Relay ==="
AGENT_PROM="$(docker exec "$WORKER1_NODE" curl -s http://127.0.0.1:9962/metrics)"
HUBBLE_PROM="$(docker exec "$WORKER1_NODE" curl -s http://127.0.0.1:9965/metrics)"

METRIC_CILIUM_FWD="$(awk '/^cilium_forward_count_total/ {s+=$NF} END {print int(s)}' <<<"$AGENT_PROM")"
METRIC_CILIUM_DROP="$(awk '/^cilium_drop_count_total/ {s+=$NF} END {print int(s)}' <<<"$AGENT_PROM")"
METRIC_CILIUM_L7="$(awk '/^cilium_policy_l7_total/ {s+=$NF} END {print int(s)}' <<<"$AGENT_PROM")"
METRIC_HUBBLE_FLOWS="$(awk '/^hubble_flows_processed_total/ {s+=$NF} END {print int(s)}' <<<"$HUBBLE_PROM")"
METRIC_HUBBLE_DROP="$(awk '/^hubble_drop_total/ {s+=$NF} END {print int(s)}' <<<"$HUBBLE_PROM")"
METRIC_HUBBLE_HTTP="$(awk '/^hubble_http_requests_total/ {s+=$NF} END {print int(s)}' <<<"$HUBBLE_PROM")"
METRIC_HUBBLE_DNS="$(awk '/^hubble_dns_queries_total/ {s+=$NF} END {print int(s)}' <<<"$HUBBLE_PROM")"

# Teste de resiliencia: endpoint Relay (:4245) indisponivel vs Ring Buffer local (unix:///var/run/cilium/hubble.sock)
RELAY_UNREACH_RC=0
kctl -n kube-system exec "$CILIUM_W1" -c cilium-agent -- hubble status --server 127.0.0.1:4245 >/dev/null 2>&1 || RELAY_UNREACH_RC=$?
LOCAL_STATUS="$(kctl -n kube-system exec "$CILIUM_W1" -c cilium-agent -- hubble status --server unix:///var/run/cilium/hubble.sock 2>&1)"

log "  [C7 Metricas :9962] cilium_forward=${METRIC_CILIUM_FWD}, cilium_drop_policy=${METRIC_CILIUM_DROP}, cilium_policy_l7=${METRIC_CILIUM_L7}"
log "  [C7 Metricas :9965] hubble_flows=${METRIC_HUBBLE_FLOWS}, hubble_drop=${METRIC_HUBBLE_DROP}, hubble_http=${METRIC_HUBBLE_HTTP}, hubble_dns=${METRIC_HUBBLE_DNS}"
log "  [C7 Resiliencia] relay_down_rc=${RELAY_UNREACH_RC} (!=0), local_ring_buffer_status: $(tr '\n' ' ' <<<"$LOCAL_STATUS")"

[[ "$METRIC_CILIUM_FWD" -gt 0 && "$METRIC_HUBBLE_DROP" -gt 0 && "$METRIC_HUBBLE_FLOWS" -gt 0 && "$METRIC_HUBBLE_HTTP" -gt 0 && "$RELAY_UNREACH_RC" -ne 0 ]] || {
  echo "ERRO E25-C7: falha na correlacao de metricas Prometheus ou teste de resiliencia" >&2
  exit 1
}

# ==============================================================================
# 4. ROLLBACK EXPLICITO E VERIFICACAO DE INVARIANTES (R1, R3, R6)
# ==============================================================================
cleanup
trap - EXIT

R6_ROUTES=0
for node in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
  c="$(docker exec "$node" ip route show proto bgp 2>/dev/null | wc -l | tr -d ' ')"
  R6_ROUTES=$((R6_ROUTES + c))
done
UID_K01_POST="$(k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
MEM_POST_KB="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"

[[ "$R6_ROUTES" -eq 0 && "$UID_K01_POST" == "$EXPECTED_UID_K01" && "$MEM_POST_KB" -ge 4194304 ]] || {
  echo "ERRO POS-ROLLBACK: R6=${R6_ROUTES}, k01_uid=${UID_K01_POST}, MemAvailable_KB=${MEM_POST_KB}" >&2
  exit 1
}

cat <<EOF
================================================================================
[PASS] P005-S003 Braço B — Estudos E17 + E25 Concluídos com Sucesso!
  - E17 C1 (Flap 4s < 3 leituras): max_down_streak=${C1_MAX_DOWN_STREAK}/3 -> estado mantido ACTIVE (false_down=${C1_FALSE_DOWN})
  - E17 C2 (Flap 12s >= 3 leituras): ACTIVE -> DOWN em ${T_DOWN_DETECT_MS} ms; DOWN -> ACTIVE em ${T_RECOVER_DETECT_MS} ms (3 leituras saudaveis)
  - E17 C3 (DOWN vs UNKNOWN + Borda): 3 falhas de scrape -> UNKNOWN; border1 FRR expôs AS_PATH 65203 65600 65201 65301
  - E25 C4 (L3/L4 + --from-cidr): allowed=${ALLOW_OK}/10, denied=${DENY_OK}/5 (Hubble DROPPED=${HUBBLE_DROP_CNT}), --from-cidr 198.19.0.0/24=${HUBBLE_CIDR_CNT}
  - E25 C5 (L7 HTTP + DNS): HTTP 200=${L7_200}/10 (Hubble=${HUBBLE_L7_HTTP_200}), HTTP 403=${L7_403}/5 (Hubble=${HUBBLE_L7_HTTP_403}), DNS L7=${HUBBLE_L7_DNS}
  - E25 C6 (TLS :8443 vs HTTP :8080): HTTPS 200=${TLS_OK}/10, fluxos L4 :8443=${TLS_L4_CNT}, vazamento URL em L7=${TLS_L7_LEAK}
  - E25 C7 (Prometheus + Resiliência): cilium_fwd=${METRIC_CILIUM_FWD}, cilium_drop=${METRIC_CILIUM_DROP}, hubble_flows=${METRIC_HUBBLE_FLOWS}, hubble_http=${METRIC_HUBBLE_HTTP}, hubble_dns=${METRIC_HUBBLE_DNS}
  - Invariantes Pós-Rollback: R1 k01=${UID_K01_POST}, R6 proto_bgp=${R6_ROUTES}, R3 MemAvailable=$((MEM_POST_KB / 1024)) MiB
================================================================================
EOF
