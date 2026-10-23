#!/usr/bin/env bash
# shellcheck shell=bash
# labs/ovnk.sh — Perfil labctl para Kind (3 nós) + OVN-Kubernetes v1.4.0 + KubeVirt v1.9.0 + frr-k8s v0.0.27 (P004-S003).
# Sourced pelo labctl. Define lab_preflight, lab_up, lab_verify, lab_down, lab_status, lab_resources.

set -euo pipefail

LAB_NAME="ovnk"
DRY_RUN="${DRY_RUN:-${LABCTL_DRY_RUN:-0}}"

OVNK_CLUSTER_NAME="${OVNK_CLUSTER_NAME:-ovnk}"
LAB_KUBECONFIG="${OVNK_KUBECONFIG:-/root/.kube/ovnk.config}"
LAB_CONTEXT="kind-${OVNK_CLUSTER_NAME}"
export LAB_KUBECONFIG LAB_CONTEXT

OVNK_VERSION="${OVNK_VERSION:-v1.4.0}"
OVNK_IMAGE="${OVNK_IMAGE:-ghcr.io/ovn-kubernetes/ovn-kubernetes/ovn-kube-ubuntu:release-1.4}"
OVNK_IMAGE_DIGEST="${OVNK_IMAGE_DIGEST:-sha256:fe68c334f7d4ed6d2ce59a02d65296c9133a450e896bac79a2d7558031629062}"
MULTUS_VERSION="${MULTUS_VERSION:-v4.1.4}"
FRR_K8S_VERSION="${FRR_K8S_VERSION:-v0.0.27}"
KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-v1.9.0}"

OVNK_PEER_CONTAINER="ovnk-evpn-peer"
OVNK_PEER_IMAGE="${OVNK_PEER_IMAGE:-ovn/ovn-multi-node:latest}"
OVNK_PEER_IMAGE_ID="${OVNK_PEER_IMAGE_ID:-sha256:eda2364d9cfbec6dd26f54b335c37efa9dade64ffdccbff374b5c50ae64ce52a}"

OVNK_RAM_ESTIMATE_GIB="6.0"
OVNK_REPO_ROOT="${LAB_ROOT:-/opt/poc-k8s-fabric}"
if [[ ! -d "${OVNK_REPO_ROOT}/studies/p004/ovnk" ]] && [[ -n "${LABCTL_DIR:-}" ]]; then
  OVNK_REPO_ROOT="$(cd "${LABCTL_DIR}/.." && pwd)"
fi
OVNK_STUDIES_DIR="${OVNK_REPO_ROOT}/studies/p004/ovnk"
OVNK_CACHE_DIR="${LABCTL_STATE_DIR:-/var/lib/labctl}/ovnk-cache"

OVNK_NODES=(
  "${OVNK_CLUSTER_NAME}-control-plane"
  "${OVNK_CLUSTER_NAME}-worker"
  "${OVNK_CLUSTER_NAME}-worker2"
)

# R2: Idempotência por primitiva para o container peer externo
ovnk_ensure_peer_container() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    run docker run -d --name "${OVNK_PEER_CONTAINER}" --hostname "${OVNK_PEER_CONTAINER}" \
      --privileged --network kind "${OVNK_PEER_IMAGE}" sleep infinity
    return 0
  fi

  if ! docker inspect "${OVNK_PEER_CONTAINER}" >/dev/null 2>&1; then
    run docker run -d --name "${OVNK_PEER_CONTAINER}" --hostname "${OVNK_PEER_CONTAINER}" \
      --privileged --network kind "${OVNK_PEER_IMAGE}" sleep infinity
  else
    local running
    running="$(docker inspect -f '{{.State.Running}}' "${OVNK_PEER_CONTAINER}" 2>/dev/null || echo false)"
    if [[ "${running}" != "true" ]]; then
      run docker start "${OVNK_PEER_CONTAINER}"
    fi
    local net_ip
    net_ip="$(docker inspect -f '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' "${OVNK_PEER_CONTAINER}" 2>/dev/null || true)"
    if [[ -z "${net_ip}" ]]; then
      run docker network connect kind "${OVNK_PEER_CONTAINER}"
    fi
  fi
}

lab_preflight() {
  log "preflight ${LAB_NAME}: validando ferramentas, gate KVM aninhado (D1/R5) e manifestos base"
  require_cmd docker kind kubectl helm jq python3 timeout ip bridge curl git

  # R5: Gate KVM aninhado obrigatório (consistente em execução real e --dry-run)
  if [[ ! -c /dev/kvm ]] || [[ ! -r /dev/kvm ]] || [[ ! -w /dev/kvm ]]; then
    die "Gate D1/R5 falhou: /dev/kvm ausente ou sem permissão de leitura/escrita (test -c/-r/-w /dev/kvm)" 75
  fi
  if [[ ! -r /proc/cpuinfo ]] || ! grep -Eq '(vmx|svm)' /proc/cpuinfo; then
    die "Gate D1/R5 falhou: extensões de virtualização (vmx|svm) ausentes em /proc/cpuinfo" 75
  fi

  local f
  for f in kind-3nodes.yaml values-udn-evpn.yaml udn-net-a.yaml udn-net-b.yaml vm-a-udn.yaml vm-b-udn.yaml evpn-nad-fabric.yaml; do
    if [[ ! -f "${OVNK_STUDIES_DIR}/${f}" ]]; then
      die "Manifesto obrigatório ausente: ${OVNK_STUDIES_DIR}/${f}" 75
    fi
  done

  # N3: Garantir que kind-3nodes.yaml contém a montagem de /dev/kvm
  if ! grep -q "containerPath: /dev/kvm" "${OVNK_STUDIES_DIR}/kind-3nodes.yaml"; then
    die "kind-3nodes.yaml não contém extraMounts para /dev/kvm (N3/R5)" 75
  fi

  # R5 / N5 / P2-2: Validar imagem do peer externo pelo digest SHA256 e, se presente localmente, a imagem do OVN-K
  if ! docker image inspect "${OVNK_PEER_IMAGE}" >/dev/null 2>&1; then
    die "Imagem ${OVNK_PEER_IMAGE} ausente no host" 75
  fi
  local actual_peer_id
  actual_peer_id="$(docker image inspect -f '{{.Id}}' "${OVNK_PEER_IMAGE}" 2>/dev/null || true)"
  if [[ -n "${OVNK_PEER_IMAGE_ID}" ]] && [[ "${actual_peer_id}" != "${OVNK_PEER_IMAGE_ID}" ]]; then
    die "Digest SHA256 de ${OVNK_PEER_IMAGE} (${actual_peer_id}) difere do esperado (${OVNK_PEER_IMAGE_ID})" 75
  fi
  if docker image inspect "${OVNK_IMAGE}" >/dev/null 2>&1; then
    local ovnk_digests
    ovnk_digests="$(docker image inspect -f '{{json .RepoDigests}}' "${OVNK_IMAGE}" 2>/dev/null || true)"
    if [[ -n "${OVNK_IMAGE_DIGEST}" ]] && [[ "${ovnk_digests}" != *"${OVNK_IMAGE_DIGEST}"* ]]; then
      die "Digest SHA256 de ${OVNK_IMAGE} (${ovnk_digests}) difere do esperado (${OVNK_IMAGE_DIGEST})" 75
    fi
  fi

  local mem
  mem="$(mem_avail_gib 2>/dev/null || echo 10.00)"
  local req_mem="${OVNK_RAM_ESTIMATE_GIB}"
  if [[ "${DRY_RUN}" != "1" ]] && kind get clusters 2>/dev/null | grep -qx "${OVNK_CLUSTER_NAME}"; then
    req_mem="1.5"
  fi
  log "  MemAvailable=${mem}GiB (mínimo requerido=${req_mem}GiB, estimado total ~${OVNK_RAM_ESTIMATE_GIB}GiB para ${LAB_NAME})"
  if ! python3 -c "import sys; sys.exit(0 if float('${mem:-0}') >= float('${req_mem}') else 1)"; then
    die "MemAvailable insuficiente (${mem}GiB < ${req_mem}GiB)" 75
  fi

  log "preflight ${LAB_NAME} OK (KVM real disponível, digests verificados e permissões validadas)"
}

lab_up() {
  lab_preflight

  log "Subindo perfil ${LAB_NAME} (Kind 3 nós + OVN-K ${OVNK_VERSION} + KubeVirt ${KUBEVIRT_VERSION} + frr-k8s ${FRR_K8S_VERSION})..."

  # 1. Garantir sysctls de bridge no host para tráfego de containers Kind (upstream kind-common.sh)
  if [[ "${DRY_RUN}" != "1" ]]; then
    modprobe br_netfilter 2>/dev/null || true
    sysctl -w net.bridge.bridge-nf-call-iptables=0 net.bridge.bridge-nf-call-ip6tables=0 >/dev/null 2>&1 || true
  fi

  # 2. Criar cluster Kind condicionalmente (R2)
  if [[ "${DRY_RUN}" == "1" ]] || ! kind get clusters 2>/dev/null | grep -qx "${OVNK_CLUSTER_NAME}"; then
    run kind create cluster \
      --name "${OVNK_CLUSTER_NAME}" \
      --config "${OVNK_STUDIES_DIR}/kind-3nodes.yaml"
  else
    log "Cluster Kind ${OVNK_CLUSTER_NAME} já existe; reutilizando."
  fi

  run kind export kubeconfig --name "${OVNK_CLUSTER_NAME}" --kubeconfig "${LAB_KUBECONFIG}"
  run chmod 0600 "${LAB_KUBECONFIG}"
  run kctl -n kube-system delete ds kube-proxy --ignore-not-found

  # 3. R5 / N3: Re-verificar /dev/kvm e configurar sysctls DENTRO de cada nó Kind
  local n
  for n in "${OVNK_NODES[@]}"; do
    run docker exec "${n}" bash -c "test -c /dev/kvm && test -r /dev/kvm && test -w /dev/kvm"
    run docker exec "${n}" bash -c "sysctl --ignore net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.all.forwarding=1 net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=0 fs.inotify.max_user_watches=1048576 fs.inotify.max_user_instances=512 >/dev/null"
  done

  # 4. Rotular nós para o chart OVN-Kubernetes v1.4.0 (single-node-zone + ovnkube-db + worker)
  run kctl label node "${OVNK_CLUSTER_NAME}-control-plane" k8s.ovn.org/ovnkube-db=true --overwrite
  if [[ "${DRY_RUN}" == "1" ]] || kctl get node "${OVNK_CLUSTER_NAME}-control-plane" -o jsonpath='{.spec.taints[*].key}' 2>/dev/null | grep -q 'node-role.kubernetes.io/control-plane'; then
    run kctl taint node "${OVNK_CLUSTER_NAME}-control-plane" node-role.kubernetes.io/control-plane:NoSchedule-
  fi
  run kctl label node "${OVNK_CLUSTER_NAME}-worker" "${OVNK_CLUSTER_NAME}-worker2" node-role.kubernetes.io/worker="" --overwrite
  for n in "${OVNK_NODES[@]}"; do
    run kctl label node "${n}" "k8s.ovn.org/zone-name=${n}" --overwrite
  done

  # 5. Instalar Multus CNI + MultiNetworkPolicy CRD + IPAMClaim CRD + frr-k8s + OVN-Kubernetes v1.4.0 via Helm
  if [[ "${DRY_RUN}" == "1" ]] || ! kctl -n kube-system get daemonset kube-multus-ds >/dev/null 2>&1; then
    run kctl apply -f "https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/${MULTUS_VERSION}/deployments/multus-daemonset-thick.yml"
  fi
  run kctl -n kube-system patch daemonset kube-multus-ds --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"512Mi"},{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/cpu","value":"500m"}]'
  run kctl apply -f "https://raw.githubusercontent.com/k8snetworkplumbingwg/multi-networkpolicy/refs/tags/v1.0.1/scheme.yml"
  run kctl apply -f "https://raw.githubusercontent.com/k8snetworkplumbingwg/ipamclaims/v0.5.1-alpha/artifacts/k8s.cni.cncf.io_ipamclaims.yaml"
  run kctl apply -f "https://raw.githubusercontent.com/metallb/frr-k8s/${FRR_K8S_VERSION}/config/all-in-one/frr-k8s.yaml"
  run kctl -n frr-k8s-system patch deployment frr-k8s-statuscleaner --type=merge -p '{"spec":{"template":{"spec":{"hostNetwork":false}}}}'

  if [[ "${DRY_RUN}" == "1" ]]; then
    run helm upgrade --install ovn-kubernetes "${OVNK_CACHE_DIR}/ovn-kubernetes-${OVNK_VERSION}/helm/ovn-kubernetes" \
      --kubeconfig "${LAB_KUBECONFIG}" --kube-context "${LAB_CONTEXT}" \
      -f "${OVNK_CACHE_DIR}/ovn-kubernetes-${OVNK_VERSION}/helm/ovn-kubernetes/values-single-node-zone.yaml" \
      -f "${OVNK_STUDIES_DIR}/values-udn-evpn.yaml"
  else
    mkdir -p "${OVNK_CACHE_DIR}"
    if [[ ! -d "${OVNK_CACHE_DIR}/ovn-kubernetes-${OVNK_VERSION}" ]]; then
      run git clone --branch "${OVNK_VERSION}" --depth 1 \
        https://github.com/ovn-kubernetes/ovn-kubernetes.git \
        "${OVNK_CACHE_DIR}/ovn-kubernetes-${OVNK_VERSION}"
    fi
    local cached_digests
    cached_digests="$(docker image inspect -f '{{json .RepoDigests}}' "${OVNK_IMAGE}" 2>/dev/null || true)"
    if [[ "${cached_digests}" != *"${OVNK_IMAGE_DIGEST}"* ]]; then
      run docker pull "${OVNK_IMAGE}@${OVNK_IMAGE_DIGEST}"
      run docker tag "${OVNK_IMAGE}@${OVNK_IMAGE_DIGEST}" "${OVNK_IMAGE}"
    fi
    run kind load docker-image "${OVNK_IMAGE}" --name "${OVNK_CLUSTER_NAME}"

    local chart_path="${OVNK_CACHE_DIR}/ovn-kubernetes-${OVNK_VERSION}/helm/ovn-kubernetes"
    if [[ ! -d "${chart_path}" ]]; then
      chart_path="${OVNK_CACHE_DIR}/ovn-kubernetes-${OVNK_VERSION}/charts/ovn-kubernetes"
    fi
    local crd_dir="${OVNK_CACHE_DIR}/ovn-kubernetes-${OVNK_VERSION}/dist/templates"
    if [[ -d "${crd_dir}" ]]; then
      local crd_file
      for crd_file in "${crd_dir}"/*crd*.yaml "${chart_path}"/crds/*.yaml; do
        [[ -f "${crd_file}" ]] && kctl apply -f "${crd_file}"
      done
    fi
    local ns_adopt
    for ns_adopt in ovn-kubernetes ovn-host-network; do
      if kctl get ns "${ns_adopt}" >/dev/null 2>&1; then
        kctl label ns "${ns_adopt}" app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true
        kctl annotate ns "${ns_adopt}" meta.helm.sh/release-name=ovn-kubernetes meta.helm.sh/release-namespace=default --overwrite >/dev/null 2>&1 || true
      fi
    done
    local api_ip
    api_ip="$(docker inspect -f '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' "${OVNK_CLUSTER_NAME}-control-plane")"
    run helm upgrade --install ovn-kubernetes "${chart_path}" \
      --kubeconfig "${LAB_KUBECONFIG}" --kube-context "${LAB_CONTEXT}" \
      -f "${chart_path}/values-single-node-zone.yaml" \
      -f "${OVNK_STUDIES_DIR}/values-udn-evpn.yaml" \
      --set "k8sAPIServer=https://${api_ip}:6443"
  fi

  run kctl -n ovn-kubernetes rollout status deployment/ovnkube-control-plane --timeout=300s
  run kctl -n ovn-kubernetes rollout status daemonset/ovs-node --timeout=300s
  run kctl -n ovn-kubernetes rollout status daemonset/ovnkube-node --timeout=300s
  run kctl -n kube-system rollout status daemonset/kube-multus-ds --timeout=240s
  if [[ "${DRY_RUN}" != "1" ]]; then
    local n_ipt
    for n_ipt in "${OVNK_NODES[@]}"; do
      docker exec "${n_ipt}" iptables -F KUBE-SERVICES >/dev/null 2>&1 || true
    done
    if [[ "$(kctl -n frr-k8s-system get deploy frr-k8s-statuscleaner -o jsonpath='{.spec.template.spec.hostNetwork}' 2>/dev/null || true)" == "true" ]]; then
      kctl -n frr-k8s-system patch deploy frr-k8s-statuscleaner --type=merge -p '{"spec":{"template":{"spec":{"hostNetwork":false}}}}'
    fi
  fi
  run kctl -n frr-k8s-system rollout status deployment/frr-k8s-statuscleaner --timeout=240s
  run kctl -n frr-k8s-system rollout status daemonset/frr-k8s-daemon --timeout=240s

  # 5. Instalar KubeVirt v1.9.0 (com KVM nativo, sem useEmulation) e registrar binding l2bridge para Primary UDN (P1-1)
  run kctl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
  run kctl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"
  run kctl -n kubevirt wait kubevirt kubevirt --for=condition=Available --timeout=360s
  run kctl -n kubevirt patch kubevirt kubevirt --type=merge -p '{
    "spec": {
      "configuration": {
        "developerConfiguration": {
          "disabledFeatureGates": ["ImageVolume"],
          "featureGates": ["NetworkBindingPlugins", "DynamicPodInterfaceNaming"]
        },
        "network": {
          "binding": {
            "l2bridge": {
              "domainAttachmentType": "managedTap",
              "migration": {}
            }
          }
        }
      }
    }
  }'

  # 6. Iniciar peer EVPN/BGP externo na rede kind (R2)
  ovnk_ensure_peer_container
  run docker exec "${OVNK_PEER_CONTAINER}" bash -c '
    set -euo pipefail
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
    frr_dir=""
    for candidate in /usr/libexec/frr /usr/lib/frr; do
      if [ -x "${candidate}/zebra" ] && [ -x "${candidate}/bgpd" ] && [ -x "${candidate}/bfdd" ]; then
        frr_dir="${candidate}"
        break
      fi
    done
    [ -n "${frr_dir}" ] || { echo "FRR daemons ausentes" >&2; exit 1; }
    mkdir -p /var/run/frr /run/frr
    touch /etc/frr/frr.conf
    chown -R frr:frr /etc/frr /var/run/frr /run/frr 2>/dev/null || true
    for d in mgmtd zebra bgpd bfdd staticd; do
      if [ -x "${frr_dir}/${d}" ]; then
        pidof "${d}" >/dev/null 2>&1 || "${frr_dir}/${d}" -d
      fi
    done
  '

  if [[ "${DRY_RUN}" != "1" ]]; then
    local uid
    uid="$(kctl get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")"
    [[ -n "${uid}" ]] && state_set "${LAB_NAME}" "uid" "${uid}"
    state_set "${LAB_NAME}" "up_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  log "${LAB_NAME} up concluído."
}

lab_verify() {
  log "Verificando saúde e invariantes do perfil ${LAB_NAME} (R8)..."
  local ev_dir
  ev_dir="$(evidence_dir "${LAB_NAME}")"
  if [[ "${DRY_RUN}" == "1" ]]; then
    run kctl get nodes
    run kctl -n ovn-kubernetes get pods
    run kctl -n frr-k8s-system get pods
    run kctl get crd userdefinednetworks.k8s.ovn.org clusteruserdefinednetworks.k8s.ovn.org routeadvertisements.k8s.ovn.org vteps.k8s.ovn.org
    run kctl -n kubevirt get kubevirt kubevirt -o json
    run docker inspect -f '{{.State.Running}}' "${OVNK_PEER_CONTAINER}"
    log "[dry-run] verify ${LAB_NAME} concluído -> ${ev_dir}"
    return 0
  fi

  local out="${ev_dir}/verify.txt"
  : > "${out}"

  # 1. Todos os 3 nós Ready
  local ready_nodes
  ready_nodes="$(kctl get nodes -o json | jq '[.items[] | select(any(.status.conditions[]; .type=="Ready" and .status=="True"))] | length')"
  if [[ "${ready_nodes}" -lt 3 ]]; then
    die "Menos de 3 nós Ready no cluster ${OVNK_CLUSTER_NAME} (Ready=${ready_nodes})"
  fi

  # 2. Pods em ovn-kubernetes Running/Ready
  local bad_ovnk
  bad_ovnk="$(kctl -n ovn-kubernetes get pods -o json | jq '[.items[] | select(.status.phase != "Running" and .status.phase != "Succeeded")] | length')"
  if [[ "${bad_ovnk}" -ne 0 ]]; then
    die "Há ${bad_ovnk} pods fora de Running/Succeeded em ovn-kubernetes"
  fi

  # 3. Pods em frr-k8s-system Running
  local bad_frr
  bad_frr="$(kctl -n frr-k8s-system get pods -o json | jq '[.items[] | select(.status.phase != "Running")] | length')"
  if [[ "${bad_frr}" -ne 0 ]]; then
    die "Há ${bad_frr} pods fora de Running em frr-k8s-system"
  fi

  # 4. CRDs UDN/EVPN instaladas
  local crd
  for crd in userdefinednetworks.k8s.ovn.org clusteruserdefinednetworks.k8s.ovn.org routeadvertisements.k8s.ovn.org vteps.k8s.ovn.org; do
    if ! kctl get crd "${crd}" >/dev/null 2>&1; then
      die "CRD obrigatória ausente no cluster ovnk: ${crd}"
    fi
  done

  # 5. KubeVirt Deployed (JSON check - R8) e /dev/kvm acessível nos nós (R5)
  local kv_phase
  kv_phase="$(kctl -n kubevirt get kubevirt kubevirt -o json | jq -r '.status.phase // empty')"
  if [[ "${kv_phase}" != "Deployed" ]]; then
    die "KubeVirt não está em fase Deployed (phase=${kv_phase})"
  fi
  local n
  for n in "${OVNK_NODES[@]}"; do
    if ! docker exec "${n}" bash -c "test -c /dev/kvm && test -r /dev/kvm && test -w /dev/kvm"; then
      die "Nó ${n} perdeu acesso de leitura/escrita a /dev/kvm"
    fi
  done

  # 6. Peer EVPN externo running
  if [[ "$(docker inspect -f '{{.State.Running}}' "${OVNK_PEER_CONTAINER}" 2>/dev/null || echo false)" != "true" ]]; then
    die "Container ${OVNK_PEER_CONTAINER} não está running"
  fi

  local uid
  uid="$(kctl get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")"
  [[ -n "${uid}" ]] && state_set "${LAB_NAME}" "uid" "${uid}"
  state_set "${LAB_NAME}" "verified_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  {
    echo "=== Verify ${LAB_NAME} ($(date -u +%Y-%m-%dT%H:%M:%SZ)) ==="
    echo "uid=${uid}"
    echo "ready_nodes=${ready_nodes} bad_ovnk=${bad_ovnk} bad_frr=${bad_frr} kubevirt_phase=${kv_phase}"
    kctl get nodes -o wide
    kctl -n ovn-kubernetes get pods -o wide
    kctl -n frr-k8s-system get pods -o wide
    kctl -n kubevirt get kubevirt kubevirt -o wide
  } >> "${out}"

  log "${LAB_NAME} verify: PASS (3 nós Ready, OVN-K v1.4.0 + frr-k8s + KubeVirt Deployed com KVM real, CRDs UDN/EVPN ativas). Evidência: ${out}"
}

lab_down() {
  log "Executando teardown cleanup-then-proof do perfil ${LAB_NAME} (R7 + N1 + N4)..."
  if [[ "${DRY_RUN}" == "1" ]]; then
    run kctl delete vm,vmi --all -A --wait=false
    run kctl delete routeadvertisements,clusteruserdefinednetworks,vteps --all --wait=false
    run docker exec "${OVNK_PEER_CONTAINER}" vtysh -c "configure terminal" -c "no router bgp 65000" -c "end"
    run docker rm -f "${OVNK_PEER_CONTAINER}"
    run kind delete cluster --name "${OVNK_CLUSTER_NAME}"
    run rm -f "${LAB_KUBECONFIG}"
    return 0
  fi

  if kind get clusters 2>/dev/null | grep -qx "${OVNK_CLUSTER_NAME}"; then
    # 1. N4: Remover VMs/VMIs com poll de espera e patch condicional de finalizers apenas se expirar timeout
    kctl delete vm,vmi --all -A --wait=false >/dev/null 2>&1 || true
    local rem_vmi=0
    for _ in $(seq 1 15); do
      rem_vmi="$(kctl get vm,vmi -A -o json 2>/dev/null | jq '.items | length' 2>/dev/null || echo 0)"
      [[ "${rem_vmi}" -eq 0 ]] && break
      sleep 2
    done
    if [[ "${rem_vmi}" -gt 0 ]]; then
      log "WARN: VMs/VMIs ainda presentes após 30s (${rem_vmi}); aplicando patch condicional de finalizers (N4)"
      kctl get vm,vmi -A -o json 2>/dev/null | jq -r '.items[] | "\(.kind) \(.metadata.namespace) \(.metadata.name)"' | \
      while read -r kind ns name; do
        [[ -n "${name}" ]] && kctl -n "${ns}" patch "${kind}" "${name}" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
      done
    fi

    # 2. Remover CRs de rede e aguardar reconciliação
    kctl delete routeadvertisements --all --wait=false >/dev/null 2>&1 || true
    kctl delete ipamclaims --all -A --wait=false >/dev/null 2>&1 || true
    kctl delete userdefinednetworks --all -A --wait=false >/dev/null 2>&1 || true
    kctl delete clusteruserdefinednetworks --all --wait=false >/dev/null 2>&1 || true
    kctl delete vteps --all --wait=false >/dev/null 2>&1 || true
    kctl -n frr-k8s-system delete frrconfigurations --all --wait=false >/dev/null 2>&1 || true
  fi

  # 3. N1 / R7: Retirada explícita de rotas BGP no peer externo e limpeza/prova de resíduo interno antes de remover containers
  if docker inspect -f '{{.State.Running}}' "${OVNK_PEER_CONTAINER}" 2>/dev/null | grep -qx "true"; then
    docker exec "${OVNK_PEER_CONTAINER}" vtysh \
      -c "configure terminal" \
      -c "no router bgp 65000 vrf vrf-evpn-k03" \
      -c "no router bgp 65000" \
      -c "no router bgp 65002 vrf vrf-evpn-k03" \
      -c "no router bgp 65002" \
      -c "end" >/dev/null 2>&1 || true
    docker exec -i "${OVNK_PEER_CONTAINER}" bash -s <<'EOF'
for dev in brevpn.100 brevpn.200 vxevpn brevpn dummy-k03 vxlan-10100 vxlan-20100 vxlan-20101 vxlan-20400 br-vxlan-10100 br-vxlan-20100 br-vxlan-20101 br-legacy vrf-evpn-k03; do
  ip link del "${dev}" 2>/dev/null || true
done
EOF
    if [[ -n "$(docker exec "${OVNK_PEER_CONTAINER}" ip -d link show type vxlan 2>/dev/null | grep -E 'vxevpn|vxlan-(1010|2010|2040)' || true)" ]]; then
      die "Resíduo VXLAN interno detectado em ${OVNK_PEER_CONTAINER} antes da remoção"
    fi
  fi

  local n
  for n in "${OVNK_NODES[@]}"; do
    if docker inspect -f '{{.State.Running}}' "${n}" 2>/dev/null | grep -qx "true"; then
      docker exec -i "${n}" bash -s <<'EOF' || true
for dev in $(ip -o link show type vxlan 2>/dev/null | awk -F": " '{print $2}' | cut -d@ -f1); do
  [[ "${dev}" == "vxlan_sys_4789" ]] && continue
  ip link del "${dev}" 2>/dev/null || true
done
ip link del br-legacy 2>/dev/null || true
EOF
    fi
  done

  # 4. Remover peer externo, cluster Kind ovnk e kubeconfig dedicado
  if docker inspect "${OVNK_PEER_CONTAINER}" >/dev/null 2>&1; then
    run docker rm -f "${OVNK_PEER_CONTAINER}"
  fi
  if kind get clusters 2>/dev/null | grep -qx "${OVNK_CLUSTER_NAME}"; then
    run kind delete cluster --name "${OVNK_CLUSTER_NAME}"
  fi
  run rm -f "${LAB_KUBECONFIG}"

  # 5. R7: Prova de zero resíduo no host após remoção do cluster
  assert_absent_containers "ovnk-"
  if [[ -f "${LAB_KUBECONFIG}" ]]; then
    die "Kubeconfig residual ainda presente após down: ${LAB_KUBECONFIG}"
  fi
  local host_routes
  if ! host_routes="$(ip route show 2>&1)"; then
    die "Falha ao executar 'ip route show' na verificação pós-down: ${host_routes}"
  fi
  if ip -d link show type vxlan 2>/dev/null | grep -q "ovnk"; then
    die "Interface VXLAN residual com prefixo ovnk detectada no host"
  fi
  if ip -d link show type vrf 2>/dev/null | grep -q "ovnk"; then
    die "Interface VRF residual com prefixo ovnk detectada no host"
  fi
  if grep -q "ovnk" <<<"${host_routes}"; then
    die "Rota residual com prefixo ovnk detectada no host"
  fi

  rm -f "$(state_file "${LAB_NAME}")"
  log "${LAB_NAME} down concluído com zero resíduo."
}

lab_status() {
  local up="nao"
  if kind get clusters 2>/dev/null | grep -qx "${OVNK_CLUSTER_NAME}"; then
    up="sim"
  fi
  local uid
  uid="$(state_get "${LAB_NAME}" "uid" || true)"
  log "lab=${LAB_NAME} up=${up} uid=${uid:-ausente}"
  if [[ "${up}" == "sim" ]]; then
    kctl get nodes -o wide 2>/dev/null || true
  fi
  docker ps -a --filter "name=^${OVNK_PEER_CONTAINER}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' || true
  lab_resources
}

lab_resources() {
  log "Recursos estimados/consumidos pelo perfil ${LAB_NAME} (~${OVNK_RAM_ESTIMATE_GIB}GiB RAM):"
  local running=()
  local c
  for c in "${OVNK_NODES[@]}" "${OVNK_PEER_CONTAINER}"; do
    if docker inspect -f '{{.State.Running}}' "${c}" 2>/dev/null | grep -qx "true"; then
      running+=("${c}")
    fi
  done
  if [[ "${#running[@]}" -gt 0 ]]; then
    docker stats --no-stream "${running[@]}" || true
  else
    printf '  Nenhum container ovnk-* em execução no momento.\n'
  fi
}

preflight() { lab_preflight "$@"; }
up() { lab_up "$@"; }
verify() { lab_verify "$@"; }
down() { lab_down "$@"; }
status() { lab_status "$@"; }
resources() { lab_resources "$@"; }
