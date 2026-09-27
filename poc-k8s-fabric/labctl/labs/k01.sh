#!/usr/bin/env bash
# labs/k01.sh — perfil do lab de referência (P004-S001, contrato §4).
# Sourced pelo labctl. Define as seis funções do contrato.
set -euo pipefail

LAB_NAME="k01"
LAB_KUBECONFIG="${K01_KUBECONFIG:-/root/.kube/k01-rebuild.config}"
LAB_CONTEXT="kind-k01"
LAB_TOPO="topo/poc-kind.clab.yml"
LAB_PREFIX="clab-poc-k8s-kind-"
LAB_HOST_LINK="clab-ext"
LAB_VIP="10.201.255.10"
# raiz do kit k01 (diferente da raiz dos studies p003)
LAB_ROOT="${K01_ROOT:-/opt/poc-k8s-fabric}"
export LAB_ROOT
# nós kind (sem prefixo clab) — usados em down (resíduo) e status (up/memória)
LAB_KIND_NODES=("k01-control-plane" "k01-worker" "k01-worker2")
export LAB_KUBECONFIG LAB_CONTEXT

# ---- preflight: capacidade, binários, conflitos, /dev/kvm (sem alterar) ----
lab_preflight() {
  log "preflight ${LAB_NAME}:"
  local mem cpu disk fwd n
  mem="$(mem_avail_gib)"
  cpu="$(nproc)"
  disk="$(df -h / | awk 'NR==2{print $4}')"
  log "  MemAvailable=${mem}GiB CPU=${cpu} disco_avail=${disk}"
  require_cmd docker clab kind kubectl helm python3
  if command -v cilium >/dev/null 2>&1; then
    log "  cilium: $(cilium version --client-only 2>/dev/null | head -1)"
  else
    log "  cilium: ausente"
  fi
  fwd="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
  log "  net.ipv4.ip_forward=${fwd}"
  n="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -c "^${LAB_PREFIX}" || true)"
  log "  containers '${LAB_PREFIX}' já existentes: ${n}"
  log "  clusters kind: $(kind get clusters 2>/dev/null | tr '\n' ' ')"
  if [[ -e /dev/kvm ]]; then log "  /dev/kvm: presente"; else log "  /dev/kvm: ausente"; fi
  log "preflight ${LAB_NAME} OK"
  return 0
}

# ---- up: fabric+kind, cilium dual-stack, fix devices, BGP, gate L1 ----
# Ordem crítica (P1-1): exportar o kubeconfig ANTES de esperar a API — o kind
# gera um CA novo a cada create, então o kubeconfig antigo não autentica.
lab_up() {
  require_cmd docker clab kind kubectl helm
  local ev deploy_log devices
  ev="$(evidence_dir "${LAB_NAME}")"
  deploy_log="${ev}/clab-deploy.log"

  log "1/7 fabric + kind (nohup, log ${deploy_log})"
  # Idempotência (fix S001-06): clab deploy não é idempotente — se o cluster
  # kind já existe (up parcial reexecutado), ele falha com 'node(s) already
  # exist for a cluster'. Reaproveitar o cluster existente; as fases 2+ são
  # idempotentes e completam o up.
  if [[ "${DRY_RUN}" == "1" ]]; then
    clab_deploy_nohup "${LAB_ROOT}/${LAB_TOPO}" "${deploy_log}"
  elif kind get clusters 2>/dev/null | grep -qx "k01"; then
    log "  cluster kind k01 já existe — reaproveitando (up idempotente)"
  else
    clab_deploy_nohup "${LAB_ROOT}/${LAB_TOPO}" "${deploy_log}"
  fi

  log "2/7 aguardando o cluster kind aparecer"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: aguardar cluster kind (pulada)"
  else
    for _ in $(seq 1 60); do
      if kind get clusters 2>/dev/null | grep -qx "k01"; then break; fi
      sleep 5
    done
    kind get clusters 2>/dev/null | grep -qx "k01" || die "cluster k01 não apareceu em 300s"
  fi

  log "3/7 kubeconfig do cluster (0600) — antes de esperar a API"
  run kind export kubeconfig --name k01 --kubeconfig "${LAB_KUBECONFIG}"
  run chmod 0600 "${LAB_KUBECONFIG}"

  log "4/7 aguardando a API do kind (com o kubeconfig novo)"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: aguardar API do kind (pulada)"
  else
    for _ in $(seq 1 60); do
      if kctl get nodes >/dev/null 2>&1; then break; fi
      sleep 5
    done
    kctl get nodes >/dev/null 2>&1 || die "API do kind não respondeu em 300s"
  fi

  log "5/7 Cilium dual-stack + BGP CP (script 02 detecta o IP do API no CP)"
  run env KUBECONFIG="${LAB_KUBECONFIG}" VALUES=k8s/cilium/values-dualstack.yaml \
    bash "${LAB_ROOT}/scripts/02-install-cilium.sh"

  log "6/7 fix S09 devices=eth+ (L6: helm regenera o ConfigMap)"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: checar/corrigir devices=eth+ (pulada)"
  else
    devices="$(kctl -n kube-system get cm cilium-config -o jsonpath='{.data.devices}' 2>/dev/null || true)"
    if [[ "${devices}" != "eth+" ]]; then
      run kctl -n kube-system patch cm cilium-config --type merge -p '{"data":{"devices":"eth+"}}'
      run kctl -n kube-system rollout restart ds/cilium
      run kctl -n kube-system rollout status ds/cilium --timeout=5m
    fi
  fi

  log "7/7 BGP (CRDs + pool de VIPs + apps) e gate L1"
  run env KUBECONFIG="${LAB_KUBECONFIG}" \
    RACK1_NODES="k01-control-plane k01-worker" RACK2_NODES="k01-worker2" \
    bash "${LAB_ROOT}/scripts/03-apply-bgp.sh"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: checar/restaurar IPv4 203.0.113.10 do client-ext (pulada)"
  else
    if ! docker exec clab-poc-k8s-kind-client-ext ip -4 addr show dev eth1 2>/dev/null | grep -q 203.0.113.10; then
      log "  GATE L1: restaurando IPv4 203.0.113.10 do client-ext"
      run docker exec clab-poc-k8s-kind-client-ext ip addr add 203.0.113.10/24 dev eth1
    fi
  fi

  state_set "${LAB_NAME}" up_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log "lab ${LAB_NAME} up concluído"
  return 0
}

# ---- verify: gates observáveis; grava verify.txt; devolve 0 só se todos passam ----
lab_verify() {
  local ev verify_file ready bgp nh ok code uid prev
  ev="$(evidence_dir "${LAB_NAME}")"
  verify_file="${ev}/verify.txt"

  ready="$(kctl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{c++} END{print c+0}' || true)"
  [[ "${ready}" -eq 3 ]] || die "esperava 3 nós Ready, obtive ${ready}"

  # o CLI cilium não tem --kube-context (só --kubeconfig); o contexto vem do
  # próprio arquivo (gerado pelo kind export). Fix S001-06 (falso FAIL: a flag
  # inexistente falhava em silêncio e a contagem caía para 0).
  bgp="$(KUBECONFIG="${LAB_KUBECONFIG}" cilium bgp peers --kubeconfig "${LAB_KUBECONFIG}" 2>/dev/null | grep -ci established || true)"
  [[ "${bgp}" -ge 3 ]] || die "esperava >=3 sessões BGP established, obtive ${bgp}"

  # SR Linux v25: a sintaxe antiga 'show router route-table table-name=...'
  # não existe mais (fix S001-06: parsing error em silêncio, contagem=0).
  # Cada next-hop do /32 aparece numa linha com '/31 (' (link /31 da folha).
  nh="$(docker exec clab-poc-k8s-kind-spine1 sr_cli "show network-instance default route-table ipv4-unicast prefix ${LAB_VIP}/32" 2>/dev/null \
    | grep -c '/31 (' || true)"
  [[ "${nh}" -ge 2 ]] || die "esperava >=2 next-hops no VIP ${LAB_VIP}/32, obtive ${nh}"

  ok=0
  for _ in $(seq 1 10); do
    code="$(docker exec clab-poc-k8s-kind-client-ext curl -s -o /dev/null -w '%{http_code}' \
      --max-time 5 --noproxy '*' "http://${LAB_VIP}/hostname" 2>/dev/null || true)"
    if [[ "${code}" == "200" ]]; then ok=$((ok + 1)); fi
  done
  [[ "${ok}" -eq 10 ]] || die "esperava 10/10 HTTP 200 do client-ext, obtive ${ok}/10"

  uid="$(kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
  prev="$(state_get "${LAB_NAME}" uid 2>/dev/null || true)"
  if [[ -n "${prev}" && "${prev}" != "${uid}" ]]; then
    log "  UID mudou após rebuild: ${prev} -> ${uid} (esperado em down->up)"
  fi

  # O2: a escrita do verify.txt é DRY-aware (em dry-run o diretório não existe)
  if [[ "${DRY_RUN}" != "1" ]]; then
    {
      echo "=== labctl ${LAB_NAME} verify $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
      echo "nodes_ready=${ready}/3"
      echo "bgp_established=${bgp}"
      echo "vip_nexthops=${nh}"
      echo "canario_http200=${ok}/10"
      echo "uid=${uid}"
      echo "uid_anterior=${prev:-nenhum}"
      echo "VERIFY_OK"
    } > "${verify_file}"
  else
    echo "DRY: gravar verify.txt em ${verify_file}"
  fi

  state_set "${LAB_NAME}" uid "${uid}"
  state_set "${LAB_NAME}" verified_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log "lab ${LAB_NAME} verify OK (evidência: ${verify_file})"
  return 0
}

# ---- down: remove só os recursos do perfil e prova ausência ----
lab_down() {
  require_cmd docker clab kind
  local ev destroy_log r net
  ev="$(evidence_dir "${LAB_NAME}")"
  destroy_log="${ev}/clab-destroy.log"

  # O3: idempotência — deletar apps só se a API responde (host já limpo não falha)
  log "1/5 apps (por nome, L5)"
  if kctl get nodes >/dev/null 2>&1; then
    run kctl delete deploy echo --ignore-not-found
    run kctl delete svc echo-anycast echo-local --ignore-not-found
    run kctl delete ds netshoot --ignore-not-found
  else
    log "  API ausente — pulando delete de apps (host já limpo)"
  fi

  log "2/5 cluster kind (antes do clab destroy, L3)"
  run kind delete cluster --name k01

  log "3/5 fabric (clab destroy -t, nunca --all)"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: clab destroy -t ${LAB_ROOT}/${LAB_TOPO}"
  else
    log "  clab destroy -t ${LAB_ROOT}/${LAB_TOPO}"
    clab destroy -t "${LAB_ROOT}/${LAB_TOPO}" >"${destroy_log}" 2>&1 \
      || die "clab destroy falhou (log: ${destroy_log})"
  fi

  log "4/5 remover kubeconfig obsoleto (recriado no up)"
  run rm -f "${LAB_KUBECONFIG}"

  log "5/5 provando ausência de resíduo (containers, rede, link, rotas)"
  assert_absent_containers "${LAB_PREFIX}"
  if [[ "${DRY_RUN}" != "1" ]]; then
    # nós kind (sem prefixo) — checar nominalmente, delete parcial pode deixar órfão (P3-1)
    for node in k01-control-plane k01-worker k01-worker2; do
      if docker ps -a --format '{{.Names}}' | grep -qx "${node}"; then
        die "resíduo: container kind '${node}' ainda existe"
      fi
    done
    if kind get clusters 2>/dev/null | grep -qx "k01"; then
      die "resíduo: cluster k01 ainda existe em kind get clusters"
    fi
    assert_absent_link "${LAB_HOST_LINK}"
    r="$(ip route show | grep -c 'via 10.100.0.2' || true)"
    [[ "${r}" -eq 0 ]] || die "resíduo: ${r} rota(s) via 10.100.0.2"
    # rede Docker residual (P3-3: provar ausência, não só avisar)
    net="$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -c "${LAB_PREFIX%-*}" || true)"
    [[ "${net}" -eq 0 ]] || die "resíduo: ${net} rede(s) Docker com prefixo do perfil"
  fi
  log "lab ${LAB_NAME} down concluído"
  return 0
}

# ---- status: no ar ou não, UID, memória dos containers do perfil ----
lab_status() {
  local up="nao" uid n re
  # up = fabric prefix OU qualquer nó kind no ar (P3-2: os nós kind são os mais pesados)
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${LAB_PREFIX}"; then
    up="sim"
  fi
  for n in "${LAB_KIND_NODES[@]}"; do
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${n}"; then
      up="sim"
    fi
  done
  uid="$(state_get "${LAB_NAME}" uid 2>/dev/null || true)"
  if [[ -z "${uid}" ]]; then
    uid="$(kctl get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null || echo ausente)"
  fi
  log "lab=${LAB_NAME} up=${up} uid=${uid:-ausente}"
  # memória: containers do fabric (prefixo) + nós kind (P3-2)
  re="${LAB_PREFIX}"
  for n in "${LAB_KIND_NODES[@]}"; do re="${re}|${n}"; done
  docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' 2>/dev/null \
    | grep -E "^(${re})" | sed 's/^/  /'
  return 0
}

# ---- resources: lista nominal de containers, redes, links, rotas, arquivos ----
lab_resources() {
  log "recursos nominais do perfil ${LAB_NAME}:"
  log "  containers fabric: prefixo '${LAB_PREFIX}' (spine1/2, leaf1/2/3, border1, client-ext)"
  log "  containers kind (sem prefixo): ${LAB_KIND_NODES[*]}"
  log "  cluster kind: k01 (3 nós)"
  log "  kubeconfig: ${LAB_KUBECONFIG} (contexto ${LAB_CONTEXT})"
  log "  topologia: ${LAB_ROOT}/${LAB_TOPO}"
  log "  link de host: ${LAB_HOST_LINK} (10.100.0.1/30)"
  log "  rotas de host: via 10.100.0.2 (10.0.0.0/16, 10.10.0.0/16, 10.201.255.0/24, 10.244.0.0/16, 203.0.113.0/24)"
  log "  VIP: ${LAB_VIP}/32 (anunciado via BGP)"
  return 0
}
