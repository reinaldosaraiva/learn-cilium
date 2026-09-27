#!/usr/bin/env bash
# labs/p003-gw.sh — perfil do sandbox Cilium 1.20.2 (P004-S001, contrato §5).
# Sourced pelo labctl. Define as seis funções do contrato.
set -euo pipefail

LAB_NAME="p003-gw"
LAB_KUBECONFIG="${P003_KUBECONFIG:-/root/.kube/p003-gw.config}"
LAB_CONTEXT="kind-p003-gw"
LAB_TOPO="studies/p003/topo/p003-gw.clab.yml"
LAB_PREFIX="clab-p003-gw-fabric-"
LAB_HOST_LINK="p003-ext"
LAB_VIP="10.202.255.10"
# raiz dos studies p003 (diferente da raiz do kit k01)
LAB_ROOT="${P003_ROOT:-/opt/poc-k8s-fabric-studies}"
export LAB_ROOT
# os nós kind do sandbox NÃO levam o prefixo clab (são k8s-kind no topo)
LAB_CP_CONTAINER="p003-gw-control-plane"
LAB_CLIENT="clab-p003-gw-fabric-client"
# rotas de host via p003-ext (contrato §5)
LAB_ROUTES=("10.30.1.0/24" "10.30.2.0/24" "10.202.255.0/24" "10.245.0.0/16" "198.19.0.0/24")
# nós kind (sem prefixo clab) — usados em down (resíduo) e status (up/memória)
LAB_KIND_NODES=("p003-gw-control-plane" "p003-gw-worker" "p003-gw-worker2")
export LAB_KUBECONFIG LAB_CONTEXT

# ---- preflight: capacidade, binários, conflitos, /dev/kvm (sem alterar) ----
lab_preflight() {
  log "preflight ${LAB_NAME}:"
  local mem n
  mem="$(mem_avail_gib)"
  log "  MemAvailable=${mem}GiB (mínimo recomendado 8GiB para up)"
  require_cmd docker clab kind kubectl helm python3
  if command -v cilium >/dev/null 2>&1; then
    log "  cilium: $(cilium version --client-only 2>/dev/null | head -1)"
  else
    log "  cilium: ausente"
  fi
  n="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -c "^${LAB_PREFIX}" || true)"
  log "  containers '${LAB_PREFIX}' já existentes: ${n}"
  log "  clusters kind: $(kind get clusters 2>/dev/null | tr '\n' ' ')"
  if [[ -e /dev/kvm ]]; then log "  /dev/kvm: presente"; else log "  /dev/kvm: ausente"; fi
  log "preflight ${LAB_NAME} OK"
  return 0
}

# ---- up: fabric+kind, cilium 1.20.2, CRDs, BGP, gateway, fixtures, rotas ----
# Ordem crítica (P1-1): exportar o kubeconfig ANTES de esperar a API.
lab_up() {
  require_cmd docker clab kind kubectl helm
  local ev deploy_log api_ip n f
  ev="$(evidence_dir "${LAB_NAME}")"
  deploy_log="${ev}/clab-deploy.log"

  log "1/9 fabric + kind (nohup, log ${deploy_log})"
  # Idempotência (fix S001-06): clab deploy não é idempotente — se o cluster
  # kind já existe (up parcial reexecutado), ele falha com 'node(s) already
  # exist for a cluster'. Reaproveitar o cluster existente; as fases 2+ são
  # idempotentes e completam o up.
  if [[ "${DRY_RUN}" == "1" ]]; then
    clab_deploy_nohup "${LAB_ROOT}/${LAB_TOPO}" "${deploy_log}"
  elif kind get clusters 2>/dev/null | grep -qx "p003-gw"; then
    log "  cluster kind p003-gw já existe — reaproveitando (up idempotente)"
  else
    clab_deploy_nohup "${LAB_ROOT}/${LAB_TOPO}" "${deploy_log}"
  fi

  log "2/9 aguardando o cluster kind aparecer"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: aguardar cluster kind (pulada)"
  else
    for _ in $(seq 1 60); do
      if kind get clusters 2>/dev/null | grep -qx "p003-gw"; then break; fi
      sleep 5
    done
    kind get clusters 2>/dev/null | grep -qx "p003-gw" || die "cluster p003-gw não apareceu em 300s"
  fi

  log "3/9 kubeconfig do cluster (0600) — antes de esperar a API"
  run kind export kubeconfig --name p003-gw --kubeconfig "${LAB_KUBECONFIG}"
  run chmod 0600 "${LAB_KUBECONFIG}"

  log "4/9 aguardando a API do kind (com o kubeconfig novo)"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: aguardar API do kind (pulada)"
  else
    for _ in $(seq 1 60); do
      if kctl get nodes >/dev/null 2>&1; then break; fi
      sleep 5
    done
    kctl get nodes >/dev/null 2>&1 || die "API do kind não respondeu em 300s"
  fi

  log "5/9 CRDs Gateway API (experimental)"
  # Sem 'run' aqui: o run chama die (exit) em falha e o if ! nunca recebe o
  # retorno — o workaround abaixo nunca dispararia (fix S001-06, 3ª tentativa).
  local crd_rc=0
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: kctl apply -f ${LAB_ROOT}/studies/p003/base/crds/experimental-install.yaml"
  else
    kctl apply -f "${LAB_ROOT}/studies/p003/base/crds/experimental-install.yaml" || crd_rc=$?
  fi
  if [[ "${crd_rc}" -ne 0 ]]; then
    # Workaround K8s v1.35 (D-S005, P003-S005): o apply do CRD HTTPRoute
    # experimental falha com 'metadata.annotations: Too long: may not be more
    # than 262144 bytes'. Aplicar o standard (HTTPRoute com as annotations
    # cabíveis) e patchear SÓ o spec do experimental sobre ele.
    log "  apply experimental falhou (rc=${crd_rc}) — workaround: standard + patch spec experimental"
    run kctl apply -f "${LAB_ROOT}/studies/p003/base/crds/standard-install.yaml"
    python3 - "${LAB_ROOT}/studies/p003/base/crds/experimental-install.yaml" \
      "${ev}/httproute-experimental-spec.json" <<'PY'
import json, sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
crd = next(d for d in docs if d.get("kind") == "CustomResourceDefinition"
           and d["metadata"]["name"] == "httproutes.gateway.networking.k8s.io")
json.dump(crd["spec"], open(sys.argv[2], "w"))
PY
    run kctl patch crd httproutes.gateway.networking.k8s.io --type merge \
      --patch-file "${ev}/httproute-experimental-spec.json"
  fi

  log "6/9 Cilium 1.20.2 (chart fixado + k8sServiceHost da rede kind do CP)"
  # o CP só está na rede 'kind' (o IP de fabric é via ip addr, fora do docker)
  api_ip="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' \
    "${LAB_CP_CONTAINER}" 2>/dev/null || true)"
  if [[ -z "${api_ip}" ]]; then
    api_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' \
      "${LAB_CP_CONTAINER}" 2>/dev/null | tr ' ' '\n' | grep -v '^$' | head -1)"
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: helm upgrade --install cilium ... --set k8sServiceHost=${api_ip:-<descoberto>}"
  else
    [[ -n "${api_ip}" ]] || die "não descobri o IP do API no ${LAB_CP_CONTAINER}"
    log "  API server: ${api_ip}"
    run helm upgrade --install cilium "${LAB_ROOT}/studies/p003/base/cilium-1.20.2.tgz" \
      --kubeconfig "${LAB_KUBECONFIG}" --kube-context "${LAB_CONTEXT}" \
      -n kube-system -f "${LAB_ROOT}/studies/p003/base/values-p003.yaml" \
      --set "k8sServiceHost=${api_ip}"
  fi

  log "7/9 aguardando os agentes cilium"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: aguardar agentes cilium (pulada)"
  else
    for _ in $(seq 1 60); do
      n="$(kctl -n kube-system get ds cilium -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
      if [[ "${n}" -ge 3 ]]; then break; fi
      sleep 5
    done
    n="$(kctl -n kube-system get ds cilium -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
    [[ "${n}" -ge 3 ]] || die "agentes cilium não ficaram prontos (numberReady=${n})"
  fi

  log "8/9 BGP + gateway + fixtures (exceto auth/)"
  # Labels de rack PRÉ-requisito dos CiliumBGPClusterConfigs (nodeSelector
  # topology.kubernetes.io/rack) — sem eles nenhum peer BGP é criado
  # (fix S001-06: cluster novo não herda os labels do sandbox anterior).
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: kctl label node p003-gw-control-plane p003-gw-worker topology.kubernetes.io/rack=rack1 --overwrite"
    echo "DRY: kctl label node p003-gw-worker2 topology.kubernetes.io/rack=rack2 --overwrite"
  else
    run kctl label node p003-gw-control-plane p003-gw-worker topology.kubernetes.io/rack=rack1 --overwrite
    run kctl label node p003-gw-worker2 topology.kubernetes.io/rack=rack2 --overwrite
  fi
  shopt -s nullglob
  for f in "${LAB_ROOT}"/studies/p003/base/bgp/*.yaml; do
    run kctl apply -f "$f"
  done
  run kctl apply -f "${LAB_ROOT}/studies/p003/base/gateway.yaml"
  for f in "${LAB_ROOT}"/studies/p003/fixtures/*.yaml; do
    run kctl apply -f "$f"
  done
  shopt -u nullglob

  log "9/9 link p003-ext + rotas de host (criar se ausente)"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: garantir link ${LAB_HOST_LINK} + IP 10.101.0.1/30 + rotas (pulada)"
  else
    # o link é criado pelo clab (veth); se ausente após o deploy, é falha —
    # criar um dummy mascararia a ausência e vira blackhole (L4) (P3-6)
    if ! ip link show "${LAB_HOST_LINK}" >/dev/null 2>&1; then
      die "link ${LAB_HOST_LINK} ausente após clab deploy (esperado: veth do clab)"
    fi
    run ip link set "${LAB_HOST_LINK}" up
    if ! ip -br addr show "${LAB_HOST_LINK}" 2>/dev/null | grep -q 10.101.0.1; then
      run ip addr add 10.101.0.1/30 dev "${LAB_HOST_LINK}"
    fi
    for f in "${LAB_ROUTES[@]}"; do
      if ! ip route show | grep -q "^${f} via 10.101.0.2 dev ${LAB_HOST_LINK}"; then
        run ip route add "${f}" via 10.101.0.2 dev "${LAB_HOST_LINK}"
      fi
    done
  fi

  state_set "${LAB_NAME}" up_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log "lab ${LAB_NAME} up concluído"
  return 0
}

# ---- verify: gates observáveis; grava verify.txt; devolve 0 só se todos passam ----
lab_verify() {
  local ev verify_file ready bgp gw gw01 gw02 gw03 code resp nonce uid prev
  ev="$(evidence_dir "${LAB_NAME}")"
  verify_file="${ev}/verify.txt"

  ready="$(kctl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{c++} END{print c+0}' || true)"
  [[ "${ready}" -eq 3 ]] || die "esperava 3 nós Ready, obtive ${ready}"

  # o CLI cilium não tem --kube-context (só --kubeconfig); o contexto vem do
  # próprio arquivo (gerado pelo kind export). Fix S001-06 (falso FAIL: a flag
  # inexistente falhava em silêncio e a contagem caía para 0).
  bgp="$(KUBECONFIG="${LAB_KUBECONFIG}" cilium bgp peers --kubeconfig "${LAB_KUBECONFIG}" 2>/dev/null | grep -ci established || true)"
  [[ "${bgp}" -ge 3 ]] || die "esperava >=3 sessões BGP established, obtive ${bgp}"

  gw="$(kctl -n p003-gateway get gateway p003-main \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)"
  [[ "${gw}" == "True" ]] || die "Gateway p003-main Programmed != True (${gw:-ausente})"

  # GW01: 30x HTTP 200 com Host echo.p003.study a partir do client do fabric
  gw01=0
  for _ in $(seq 1 30); do
    code="$(docker exec "${LAB_CLIENT}" curl -s -o /dev/null -w '%{http_code}' \
      --max-time 5 --noproxy '*' -H 'Host: echo.p003.study' "http://${LAB_VIP}:8080/hostname" 2>/dev/null || true)"
    if [[ "${code}" == "200" ]]; then gw01=$((gw01 + 1)); fi
  done
  [[ "${gw01}" -eq 30 ]] || die "GW01: esperava 30/30 HTTP 200, obtive ${gw01}/30"

  # GW02: TCP 15432 — nonce enviado e devolvido idêntico (10x)
  gw02=0
  for _ in $(seq 1 10); do
    nonce="P004-gw02-$(date +%s%N)-$$"
    resp="$(docker exec "${LAB_CLIENT}" sh -c "echo ${nonce} | nc -w 3 ${LAB_VIP} 15432" 2>/dev/null || true)"
    if [[ "${resp}" == *"${nonce}"* ]]; then gw02=$((gw02 + 1)); fi
  done
  [[ "${gw02}" -eq 10 ]] || die "GW02: esperava 10/10 nonce devolvido, obtive ${gw02}/10"

  # GW03: UDP 15353 — DNS sintético responde TXT "P003-OK" (10x).
  # -p 15353 é obrigatório (dig usa a porta 53 por padrão) e o nome da query
  # precisa estar na zona study.p003 do Corefile (fix S001-06, gate GW03:
  # alinhado ao probe l401-l402 que passou 30/30 no P003).
  gw03=0
  for _ in $(seq 1 10); do
    resp="$(docker exec "${LAB_CLIENT}" sh -c "dig +short +notcp +ignore +time=3 +tries=1 @${LAB_VIP} -p 15353 study.p003 TXT" 2>/dev/null || true)"
    if [[ "${resp}" == *"P003-OK"* ]]; then gw03=$((gw03 + 1)); fi
  done
  [[ "${gw03}" -eq 10 ]] || die "GW03: esperava 10/10 P003-OK, obtive ${gw03}/10"

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
      echo "gateway_programmed=${gw}"
      echo "gw01_http200=${gw01}/30"
      echo "gw02_tcp_nonce=${gw02}/10"
      echo "gw03_udp_dns=${gw03}/10"
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
  local ev destroy_log f net r
  ev="$(evidence_dir "${LAB_NAME}")"
  destroy_log="${ev}/clab-destroy.log"

  log "1/5 cluster kind (antes do clab destroy, L3)"
  run kind delete cluster --name p003-gw

  log "2/5 fabric (clab destroy -t, nunca --all)"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY: clab destroy -t ${LAB_ROOT}/${LAB_TOPO}"
  else
    log "  clab destroy -t ${LAB_ROOT}/${LAB_TOPO}"
    clab destroy -t "${LAB_ROOT}/${LAB_TOPO}" >"${destroy_log}" 2>&1 \
      || die "clab destroy falhou (log: ${destroy_log})"
  fi

  log "3/5 remover rotas e link ${LAB_HOST_LINK}"
  for f in "${LAB_ROUTES[@]}"; do
    if ip route show | grep -q "^${f} via 10.101.0.2 dev ${LAB_HOST_LINK}"; then
      # iproute2 não faz split: PREFIX, via ADDR e dev NAME precisam vir separados (P2-1)
      run ip route del "${f}" via 10.101.0.2 dev "${LAB_HOST_LINK}"
    fi
  done
  if ip link show "${LAB_HOST_LINK}" >/dev/null 2>&1; then
    run ip link del "${LAB_HOST_LINK}"
  fi

  log "4/5 remover kubeconfig obsoleto (recriado no up)"
  run rm -f "${LAB_KUBECONFIG}"

  log "5/5 provando ausência de resíduo (containers, rede, link, rotas)"
  assert_absent_containers "${LAB_PREFIX}"
  if [[ "${DRY_RUN}" != "1" ]]; then
    # nós kind (sem prefixo) — checar nominalmente, delete parcial pode deixar órfão (P3-1)
    for node in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
      if docker ps -a --format '{{.Names}}' | grep -qx "${node}"; then
        die "resíduo: container kind '${node}' ainda existe"
      fi
    done
    if kind get clusters 2>/dev/null | grep -qx "p003-gw"; then
      die "resíduo: cluster p003-gw ainda existe em kind get clusters"
    fi
    assert_absent_link "${LAB_HOST_LINK}"
    # rotas residuais via 10.101.0.2 (P2-2: o contrato pede provar ausência de rotas)
    r="$(ip route show | grep -c 'via 10.101.0.2' || true)"
    [[ "${r}" -eq 0 ]] || die "resíduo: ${r} rota(s) via 10.101.0.2"
    # rede Docker residual (P3-3: provar ausência, não só avisar)
    net="$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -c "${LAB_PREFIX%-*}" || true)"
    [[ "${net}" -eq 0 ]] || die "resíduo: ${net} rede(s) Docker com prefixo do perfil"
  fi
  log "AVISO: o testbed OpenStack (p003-os) fica sem caminho até os pods enquanto o sandbox estiver fora."
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
  log "  containers fabric: prefixo '${LAB_PREFIX}' (spine1/2, leaf1/2/3, border1, client)"
  log "  containers kind (sem prefixo): ${LAB_KIND_NODES[*]}"
  log "  cluster kind: p003-gw (3 nós)"
  log "  kubeconfig: ${LAB_KUBECONFIG} (contexto ${LAB_CONTEXT})"
  log "  topologia: ${LAB_ROOT}/${LAB_TOPO}"
  log "  link de host: ${LAB_HOST_LINK} (10.101.0.1/30)"
  log "  rotas de host: via 10.101.0.2 (${LAB_ROUTES[*]})"
  log "  VIP: ${LAB_VIP} (anunciado via BGP); hostname echo.p003.study; portas 8080/15432/15353"
  return 0
}
