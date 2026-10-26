#!/usr/bin/env bash
# P006-S001 (Braço A — E26): LoadBalancer XDP + DSR (Direct Server Return) &
# Maglev Consistent Hashing vs SNAT / externalTrafficPolicy: Cluster vs Local
#
# Mede no sandbox p003-gw + clab-p003-gw-fabric:
#   1. Estado do Cilium 1.20.2 kube-proxy-replacement, bpf-lb-mode, bpf-lb-acceleration,
#      bpf-lb-algorithm=maglev (tableSize=16381), bpf-lb-algorithm-annotation=true e
#      mapas eBPF (cilium-dbg bpf lb list e cilium-dbg bpf lb maglev list).
#   2. Comportamento de ETP=Cluster vs ETP=Local (anúncio BGP seletivo /32 no border1
#      e preservação de IP de origem do cliente externo 198.19.0.10 em /clientip).
#   3. Distribuição ECMP + LoadBalancer entre 3 backends (w1, w2a, w2b) para VIPs
#      10.202.255.26 (SNAT/Random annotation), 10.202.255.27 (DSR/Maglev) e
#      10.202.255.28 (ETP=Local exclusivo no worker2).
#   4. Controle negativo: remoção de 1 backend (scale=0 em e26-echo-w2b) e medição de
#      reconvergência da tabela Maglev e redistribuição sem perda HTTP (20/20).
#   5. Rollback determinístico + pós-verificação k01 (10/10) e p003-gw (30/30, R6=0).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/01-e26-lb-xdp-dsr-maglev.yaml"

K01_KC="${K01_KC:-/root/.kube/k01-rebuild.config}"
K01_CTX="${K01_CTX:-kind-k01}"
K01_UID_EXPECTED="635e7274-5597-40c7-9de5-b1fbe3d68b22"

GW_KC="${GW_KC:-/root/.kube/p003-gw.config}"
GW_CTX="${GW_CTX:-kind-p003-gw}"
GW_UID_EXPECTED="6bb32e0f-71f9-4558-ae33-356ba2250c26"

CLIENT_CTN="clab-p003-gw-fabric-client"
BORDER_CTN="clab-p003-gw-fabric-border1"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

log() {
  printf '[%s] [E26] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log "DRY-RUN habilitado: nenhuma mutação será aplicada."
  log "Plano de execução E26:"
  log "  1. Validar UIDs k01 (${K01_UID_EXPECTED}) e p003-gw (${GW_UID_EXPECTED}), MemAvailable >= 4 GiB e R6=0."
  log "  2. Aplicar ${MANIFEST} (Namespace p006-e26, CiliumBGPAdvertisement e26-vip-advertisement, 3 Deployments agnhost e 3 Services LB 10.202.255.26..28)."
  log "  3. Inspecionar ConfigMap cilium-config, cilium-dbg status --verbose, cilium-dbg service list, cilium-dbg bpf lb list e cilium-dbg bpf lb maglev list."
  log "  4. Coletar RIB BGP externa no border1 para 10.202.255.26/32, .27/32 (ETP=Cluster ECMP) e .28/32 (ETP=Local exclusivo worker2)."
  log "  5. Executar bateria de 30 sondas HTTP (/hostname e /clientip) a partir de ${CLIENT_CTN} para cada VIP + captura tcpdump no worker2."
  log "  6. Executar controle negativo/resiliência: escalar e26-echo-w2b para 0 réplicas, inspecionar atualização Maglev e medir 20/20 sondas sem erro HTTP."
  log "  7. Executar cleanup completo (delete ns p006-e26 e CiliumBGPAdvertisement e26-vip-advertisement) e validar canários k01 (10/10) e p003-gw (30/30)."
  exit 0
fi

k_k01() { sudo kubectl --kubeconfig "${K01_KC}" --context "${K01_CTX}" "$@"; }
k_gw()  { sudo kubectl --kubeconfig "${GW_KC}"  --context "${GW_CTX}"  "$@"; }

cleanup() {
  log "Iniciando cleanup idempotente de E26..."
  k_gw delete -f "${MANIFEST}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  k_gw delete ns p006-e26 --ignore-not-found --wait=true >/dev/null 2>&1 || true
  k_gw delete ciliumbgpadvertisement e26-vip-advertisement --ignore-not-found >/dev/null 2>&1 || true
  log "Cleanup E26 concluído."
}
trap cleanup EXIT

log "== [1] Preflight: UIDs, MemAvailable e R6 =="
K01_UID="$(k_k01 get ns kube-system -o jsonpath='{.metadata.uid}')"
GW_UID="$(k_gw get ns kube-system -o jsonpath='{.metadata.uid}')"
MEM_AVAIL_KB="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
log "k01_uid=${K01_UID} gw_uid=${GW_UID} mem_avail_kb=${MEM_AVAIL_KB}"

if [[ "${K01_UID}" != "${K01_UID_EXPECTED}" ]]; then
  log "ERRO: UID de k01 inesperado (${K01_UID} != ${K01_UID_EXPECTED})"
  exit 1
fi
if [[ "${GW_UID}" != "${GW_UID_EXPECTED}" ]]; then
  log "ERRO: UID de p003-gw inesperado (${GW_UID} != ${GW_UID_EXPECTED})"
  exit 1
fi
if (( MEM_AVAIL_KB < 4000000 )); then
  log "ERRO: MemAvailable abaixo de 4 GiB (${MEM_AVAIL_KB} kB)"
  exit 1
fi

for node in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
  r6_count="$(sudo docker exec "${node}" ip route show proto bgp 2>/dev/null | wc -l | tr -d ' ')"
  log "node=${node} R6_bgp_routes=${r6_count}"
  if [[ "${r6_count}" != "0" ]]; then
    log "ERRO: violação R6 em ${node}"
    exit 1
  fi
done

log "== [2] Inspeção da Configuração eBPF LoadBalancer do Cilium 1.20.2 =="
k_gw -n kube-system get cm cilium-config -o json | jq '{
  kube_proxy_replacement: .data["kube-proxy-replacement"],
  bpf_lb_mode: (.data["bpf-lb-mode"] // "snat (default)"),
  bpf_lb_acceleration: (.data["bpf-lb-acceleration"] // "disabled (default)"),
  bpf_lb_algorithm: (.data["bpf-lb-algorithm"] // "random (default)"),
  bpf_lb_algorithm_annotation: (.data["bpf-lb-algorithm-annotation"] // "false"),
  bpf_lb_mode_annotation: (.data["bpf-lb-mode-annotation"] // "false"),
  bpf_lb_maglev_table_size: (.data["bpf-lb-maglev-table-size"] // "16381 (default)"),
  enable_xdp_prefilter: (.data["enable-xdp-prefilter"] // "false")
}'

CIL_W1="$(k_gw -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=p003-gw-worker -o jsonpath='{.items[0].metadata.name}')"
CIL_W2="$(k_gw -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=p003-gw-worker2 -o jsonpath='{.items[0].metadata.name}')"
log "Cilium pods: worker=${CIL_W1} worker2=${CIL_W2}"
k_gw -n kube-system exec "${CIL_W1}" -- cilium-dbg status --verbose | grep -E "KubeProxyReplacement|Host Routing|Masquerading|XDP|Maglev|DSR|SNAT|Backend Selection|Mode" || true

log "== [3] Aplicando manifesto E26 (${MANIFEST}) =="
k_gw apply -f "${MANIFEST}"
for dep in e26-echo-w1 e26-echo-w2a e26-echo-w2b; do
  k_gw -n p006-e26 rollout status "deploy/${dep}" --timeout=120s
done
sleep 6

k_gw -n p006-e26 get pods -o wide
k_gw -n p006-e26 get svc -o wide

log "== [4] Tabelas de Serviço, Mapas eBPF LB e Tabelas Maglev nos Workers =="
echo "--- worker1 cilium-dbg service list (VIPs 10.202.255.26..28) ---"
k_gw -n kube-system exec "${CIL_W1}" -- cilium-dbg service list | grep -E "ID|10\.202\.255\.2[678]" -A 3 || true
echo "--- worker2 cilium-dbg service list (VIPs 10.202.255.26..28) ---"
k_gw -n kube-system exec "${CIL_W2}" -- cilium-dbg service list | grep -E "ID|10\.202\.255\.2[678]" -A 3 || true
echo "--- worker1 cilium-dbg bpf lb list (VIPs 10.202.255.26..28) ---"
k_gw -n kube-system exec "${CIL_W1}" -- cilium-dbg bpf lb list | grep -E "SERVICE|10\.202\.255\.2[678]" -A 3 || true
echo "--- worker1 cilium-dbg bpf lb maglev list (amostra das entradas Maglev truncada a 140 cols) ---"
k_gw -n kube-system exec "${CIL_W1}" -- cilium-dbg bpf lb maglev list | cut -c1-140 | head -n 20 || true

log "== [5] Coleta Externa BGP no border1 (FRR) — ETP=Cluster vs ETP=Local =="
for attempt in $(seq 1 20); do
  if sudo docker exec "${BORDER_CTN}" vtysh -c "show bgp ipv4 unicast 10.202.255.28/32 json" 2>/dev/null | grep -q '"paths"'; then
    log "VIPs 10.202.255.26..28 convergidos na RIB de ${BORDER_CTN} (tentativa ${attempt})."
    break
  fi
  sleep 1
done

sudo docker exec "${BORDER_CTN}" vtysh -c "show ip bgp" 2>/dev/null | grep -E "Network|10\.202\.255\.2[678]" || true
for vip in 10.202.255.26 10.202.255.27 10.202.255.28; do
  echo "--- border1 show ip route ${vip}/32 ---"
  sudo docker exec "${BORDER_CTN}" vtysh -c "show ip route ${vip}/32" 2>/dev/null
done

log "== [6] Sondas HTTP (30x por VIP em /hostname) a partir de ${CLIENT_CTN} (198.19.0.10) =="
for vip in 10.202.255.26 10.202.255.27 10.202.255.28; do
  ok=0
  pods_hit=""
  for i in $(seq 1 30); do
    resp="$(sudo docker exec "${CLIENT_CTN}" curl -sS --max-time 3 "http://${vip}:80/hostname" || true)"
    if [[ "${resp}" == e26-echo-* ]]; then
      ok=$((ok + 1))
      pods_hit="${pods_hit}${resp}"$'\n'
    fi
  done
  log "VIP ${vip}: HTTP_OK=${ok}/30"
  if [[ "${ok}" -ne 30 ]]; then
    log "ERRO: VIP ${vip} obteve ${ok}/30 respostas válidas"
    exit 1
  fi
  printf '%s' "${pods_hit}" | sed '/^$/d' | sort | uniq -c | sed 's/^/  distrib: /'
done

log "== [7] Comparativo de Preservação de IP de Origem (/clientip): ETP=Cluster (10.202.255.26) vs ETP=Local (10.202.255.28) =="
echo "--- 10 sondas /clientip em 10.202.255.26 (ETP=Cluster, cross-node SNAT quando cai fora do worker local) ---"
for i in $(seq 1 10); do
  sudo docker exec "${CLIENT_CTN}" curl -sS --max-time 3 "http://10.202.255.26:80/clientip" || true
  printf '\n'
done | sed '/^$/d' | cut -d: -f1 | sort | uniq -c | sed 's/^/  clientip_etp_cluster: /'

echo "--- 10 sondas /clientip em 10.202.255.28 (ETP=Local, 100% preservação do IP 198.19.0.10) ---"
local_preserved=0
for i in $(seq 1 10); do
  cip="$(sudo docker exec "${CLIENT_CTN}" curl -sS --max-time 3 "http://10.202.255.28:80/clientip" || true)"
  if [[ "${cip}" == 198.19.0.10:* ]]; then
    local_preserved=$((local_preserved + 1))
  fi
done
log "ETP=Local (10.202.255.28) clientip=198.19.0.10 preservado em ${local_preserved}/10 requisições"
if [[ "${local_preserved}" -ne 10 ]]; then
  log "ERRO: ETP=Local não preservou 10/10 o IP do cliente 198.19.0.10"
  exit 1
fi

W2_POD_IP="$(k_gw -n p006-e26 get pod -l instance=w2a -o jsonpath='{.items[0].status.podIP}')"
log "Capturando cilium-dbg monitor (trace) no p003-gw-worker2 para Backend w2a (Pod IP=${W2_POD_IP})..."
k_gw -n kube-system exec "${CIL_W2}" -- sh -c "timeout 5 cilium-dbg monitor --type trace >/tmp/e26-w2-cap.txt 2>&1 &" || true
sleep 1
for i in 1 2 3; do
  sudo docker exec "${CLIENT_CTN}" curl -sS --max-time 3 "http://10.202.255.28:80/hostname" >/dev/null || true
done
sleep 5
echo "--- cilium-dbg monitor trace no p003-gw-worker2 para VIP 10.202.255.28 (ETP=Local) ---"
k_gw -n kube-system exec "${CIL_W2}" -- sh -c "grep -E '198\.19\.0\.10|10\.202\.255\.28|${W2_POD_IP}' /tmp/e26-w2-cap.txt | head -n 20; rm -f /tmp/e26-w2-cap.txt" || true

log "== [8] Controle Negativo / Resiliência Maglev: Remoção de 1 Backend (scale=0 em e26-echo-w2b) =="
echo "--- Maglev table ANTES de scale=0 (amostra 140 cols) ---"
k_gw -n kube-system exec "${CIL_W1}" -- cilium-dbg bpf lb maglev list | cut -c1-140 | head -n 12 || true
k_gw -n p006-e26 scale deploy/e26-echo-w2b --replicas=0
sleep 5
k_gw -n kube-system exec "${CIL_W1}" -- cilium-dbg service list | grep -E "10\.202\.255\.2[67]" -A 3 || true
echo "--- Maglev table DEPOIS de scale=0 (amostra 140 cols — apenas slots do backend removido mudam) ---"
k_gw -n kube-system exec "${CIL_W1}" -- cilium-dbg bpf lb maglev list | cut -c1-140 | head -n 12 || true

ok_after=0
pods_after=""
for i in $(seq 1 20); do
  resp="$(sudo docker exec "${CLIENT_CTN}" curl -sS --max-time 3 "http://10.202.255.27:80/hostname" || true)"
  if [[ "${resp}" == e26-echo-* ]]; then
    ok_after=$((ok_after + 1))
    pods_after="${pods_after}${resp}"$'\n'
  fi
done
log "Pós-scale=0 VIP 10.202.255.27 (Maglev): HTTP_OK=${ok_after}/20"
if [[ "${ok_after}" -ne 20 ]]; then
  log "ERRO: pós-scale=0 obteve ${ok_after}/20 respostas"
  exit 1
fi
printf '%s' "${pods_after}" | sed '/^$/d' | sort | uniq -c | sed 's/^/  distrib_after: /'

log "== [9] Teardown e Verificação Pós-Estudo =="
cleanup
trap - EXIT

K01_OK=0
for i in $(seq 1 10); do
  code="$(sudo docker exec clab-poc-k8s-kind-client-ext curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10/hostname || true)"
  [[ "${code}" == "200" ]] && K01_OK=$((K01_OK + 1))
done
GW_OK=0
for i in $(seq 1 30); do
  code="$(sudo docker exec "${CLIENT_CTN}" curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' -H 'Host: echo.p003.study' http://10.202.255.10:8080/hostname || true)"
  [[ "${code}" == "200" ]] && GW_OK=$((GW_OK + 1))
done
log "Canários finais: k01=${K01_OK}/10 p003-gw=${GW_OK}/30"
if [[ "${K01_OK}" -ne 10 || "${GW_OK}" -ne 30 ]]; then
  log "ERRO: canários finais falharam"
  exit 1
fi
log "PASS: E26 concluído com sucesso."
