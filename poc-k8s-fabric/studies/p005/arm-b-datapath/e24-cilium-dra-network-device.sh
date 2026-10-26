#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# P005-S004 (Braço B — Estudo E24): Dynamic Resource Allocation (DRA) no Cilium
#   (`resource.k8s.io/v1` DeviceClass, ResourceSlice, ResourceClaim,
#    ResourceClaimTemplate, NetworkDeviceData, Coexistência CNI Primária eth0 +
#    Interface Secundária DRA net1/net2 e Controles Negativos de Ciclo de Vida)
#
# Caso de estudo : E24 (docs/proximos-estudos.md)
# Referência     : Cilium branch feature/dra-driver
#                  commit 157b5331c727867fa009d8c6ec6ac8de92800ac9 (pkg/networkdriver/dra.go)
#
# Hipóteses testadas:
#   1. Célula 1 (Descoberta da API DRA resource.k8s.io/v1 e Inventário):
#      No Kubernetes v1.35.0 (p003-gw), a API resource.k8s.io/v1 expõe nativamente
#      DeviceClass, ResourceSlice, ResourceClaim e ResourceClaimTemplate. O chart
#      estável cilium-1.20.2.tgz não inclui pkg/networkdriver/dra.go (restrito à
#      branch experimental feature/dra-driver). Publicamos ResourceSlice do driver
#      network.cilium.io em p003-gw-worker2 com 2 dispositivos (cilium-netdev-0:
#      ifName=net1, mtu=1500, vfIndex=0, rdma=false; cilium-netdev-1: ifName=net2,
#      mtu=9000, vfIndex=1, rdma=false) e DeviceClasses com seletores CEL.
#   2. Célula 2 (Alocação pelo kube-scheduler, NetworkDeviceData, Idempotência e
#      Coexistência com CNI Primária Cilium eth0):
#      - kube-scheduler (plugin DynamicResources) avalia CEL em ResourceClaim
#        (e24-net-claim-a -> cilium-netdev-0) e ResourceClaimTemplate
#        (e24-net-claim-tmpl-b -> cilium-netdev-1), popula status.allocation,
#        status.reservedFor e finalizer resource.k8s.io/delete-protection.
#      - O reconciliador DRA (modelado em pkg/networkdriver/dra.go) prepara a
#        interface secundária netkit/veth no netns dos pods (net1 10.254.24.10/24
#        mtu 1500 e net2 10.254.24.11/24 mtu 9000), gera CDI spec em
#        /var/run/cdi/network.cilium.io-e24.json e publica NetworkDeviceData
#        (interfaceName, ips, hardwareAddress) em ResourceClaim.status.devices[].
#      - 3 execuções repetidas de Prepare provam idempotência (sem duplicar IPs/links).
#      - Coexistência: tráfego L3/HTTP pela interface secundária DRA (10.254.24.10 ->
#        10.254.24.11) funciona em paralelo à interface primária Cilium eth0
#        (10.245.x.y), CiliumNetworkPolicy (allow app-a, deny untrusted) e BGP VIP
#        (10.202.255.24 acessível desde clab-p003-gw-fabric-client).
#   3. Célula 3 (Conflitos de Ciclo de Vida e Controles Negativos):
#      - 3A (Filtro CEL incompatível / RDMA ausente + CEL inválido na admissão):
#           Claim exigindo cilium-netdev-rdma (rdma == true) mantém o Pod em
#           Pending (Unschedulable: cannot allocate all claims); expressão CEL com
#           atributo/sintaxe inválida é rejeitada sincronamente pelo kube-apiserver.
#      - 3B (Exaustão do Pool / Conflito entre Claims):
#           Com os 2 dispositivos de p003-gw-worker2-netpool alocados, um 3º claim
#           simultâneo fica não alocado e o 3º Pod permanece Pending.
#      - 3C (Proteção de Exclusão — Finalizer resource.k8s.io/delete-protection):
#           Deletar e24-net-claim-a com Pod consumidor ativo grava deletionTimestamp
#           mas retém o objeto e preserva 100% da conectividade eth0/VIP e net1.
#      - 3D (Liberação, Desalocação Automática e Recuperação do 3º Claim):
#           Encerrar o Pod consumidor + executar Unprepare remove net1 sem órfãos,
#           libera a exclusão de e24-net-claim-a e faz o kube-scheduler alocar
#           automaticamente cilium-netdev-0 para o 3º claim que aguardava vaga!
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_E24="${SCRIPT_DIR}/manifests/05-e24-dra-network-device.yaml"

DRY_RUN="${DRY_RUN:-${LABCTL_DRY_RUN:-0}}"
ROLLBACK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --rollback) ROLLBACK_ONLY=1 ;;
  esac
done

KUBECONFIG_GW="${P003_KUBECONFIG:-/root/.kube/p003-gw.config}"
CTX_GW="${P003_CONTEXT:-kind-p003-gw}"
EXPECTED_GW_UID="${P003_EXPECTED_UID:-6bb32e0f-71f9-4558-ae33-356ba2250c26}"

KUBECONFIG_K01="${K01_KUBECONFIG:-/root/.kube/k01-rebuild.config}"
CTX_K01="${K01_CONTEXT:-kind-k01}"
EXPECTED_K01_UID="${K01_EXPECTED_UID:-635e7274-5597-40c7-9de5-b1fbe3d68b22}"

CHART_TGZ="${CILIUM_CHART:-/opt/poc-k8s-fabric-studies/studies/p003/base/cilium-1.20.2.tgz}"
CLIENT_CTR="${LAB_CLIENT:-clab-p003-gw-fabric-client}"
BORDER_CTR="${LAB_BORDER:-clab-p003-gw-fabric-border1}"
WORKER_NODE="p003-gw-worker2"
CP_NODE="p003-gw-control-plane"
NS_TEST="p005-e24"
VIP_E24="10.202.255.24"

log() { printf '[e24 %s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
die() { printf '[e24 ERRO] %s\n' "$*" >&2; exit 1; }

e24_kctl() {
  kubectl --kubeconfig="${KUBECONFIG_GW}" --context="${CTX_GW}" "$@"
}

k01_kctl() {
  kubectl --kubeconfig="${KUBECONFIG_K01}" --context="${CTX_K01}" "$@"
}

if [[ "${DRY_RUN}" -eq 1 ]]; then
  cat <<'EOF'
[DRY-RUN] E24 — Dynamic Resource Allocation (resource.k8s.io/v1 DRA) no Cilium
  1. Preflight & Guardas (R1..R6): validar UID de k01 e p003-gw, MemAvailable >= 4 GiB, proto bgp = 0.
  2. Célula 1 (Descoberta da API resource.k8s.io/v1, DeviceClass e ResourceSlice):
     - Confirmar ausência de pkg/networkdriver/dra.go no chart estável cilium-1.20.2.tgz.
     - Verificar recursos API resource.k8s.io/v1 (DeviceClass, ResourceSlice, ResourceClaim, ResourceClaimTemplate).
     - Publicar ResourceSlice p003-gw-worker2-cilium-netpool-slice-0 (driver network.cilium.io, 2 devices) e DeviceClasses cilium-netdev / cilium-netdev-rdma.
  3. Célula 2 (Alocação pelo kube-scheduler, NetworkDeviceData, Idempotência 3x e Coexistência eth0 + net1/net2):
     - Criar Pods consumidores (ResourceClaim explícito e ResourceClaimTemplate) e validar alocação CEL pelo kube-scheduler.
     - Executar reconciliador DRA (Prepare 3x idempotente) injetando net1 (10.254.24.10/24, mtu 1500) e net2 (10.254.24.11/24, mtu 9000), CDI spec e NetworkDeviceData em status.devices[].
     - Validar tráfego L3/HTTP secundário (10.254.24.10 <-> 10.254.24.11) + datapath primário Cilium eth0 + CNP + BGP VIP 10.202.255.24.
  4. Célula 3 (Conflitos de Ciclo de Vida e Controles Negativos):
     - 3A: Filtro CEL rdma==true (Pending/Unschedulable) + CEL inválido rejeitado na admissão.
     - 3B: 3º Claim contra pool de 2 dispositivos (Exaustão -> Pending/Unschedulable).
     - 3C: Tentativa de delete do ResourceClaim com Pod ativo retida pelo finalizer resource.k8s.io/delete-protection.
     - 3D: Remoção do Pod consumidor + Unprepare -> liberação sem órfãos, deleção do claim concluída e alocação automática do 3º claim.
  5. Rollback completo (0 ResourceClaim, 0 ResourceClaimTemplate, 0 DeviceClass, 0 ResourceSlice, 0 interfaces DRA residuais).
EOF
  exit 0
fi

APISERVER_PATCHED=0

cleanup_host_dra_dataplane() {
  docker exec "${WORKER_NODE}" bash -c '
    ip link del br-cilium-dra 2>/dev/null || true
    ip link del dra-h-net1 2>/dev/null || true
    ip link del dra-h-net2 2>/dev/null || true
    rm -f /var/run/cdi/network.cilium.io-e24.json 2>/dev/null || true
  ' >/dev/null 2>&1 || true
}

cleanup() {
  log "Rollback E24: limpando pods, claims, slices, classes e interfaces DRA..."
  cleanup_host_dra_dataplane || true

  e24_kctl -n "${NS_TEST}" delete pod --all --force --grace-period=0 --ignore-not-found >/dev/null 2>&1 || true
  sleep 2

  for rc in $(e24_kctl -n "${NS_TEST}" get resourceclaim -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
    e24_kctl -n "${NS_TEST}" patch resourceclaim "${rc}" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    e24_kctl -n "${NS_TEST}" delete resourceclaim "${rc}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
  e24_kctl -n "${NS_TEST}" delete resourceclaimtemplate --all --ignore-not-found >/dev/null 2>&1 || true
  e24_kctl delete ciliumbgpadvertisement e24-vip-advertisement --ignore-not-found >/dev/null 2>&1 || true
  e24_kctl delete deviceclass cilium-netdev cilium-netdev-rdma --ignore-not-found >/dev/null 2>&1 || true
  e24_kctl delete resourceslice p003-gw-worker2-cilium-netpool-slice-0 --ignore-not-found >/dev/null 2>&1 || true
  e24_kctl delete ns "${NS_TEST}" --ignore-not-found --wait=false >/dev/null 2>&1 || true

  for i in $(seq 1 25); do
    e24_kctl get ns "${NS_TEST}" >/dev/null 2>&1 || break
    if [[ "${i}" -eq 10 ]]; then
      e24_kctl get ns "${NS_TEST}" -o json 2>/dev/null | jq '.spec.finalizers=[]' \
        | e24_kctl replace --raw "/api/v1/namespaces/${NS_TEST}/finalize" -f - >/dev/null 2>&1 || true
    fi
    sleep 1
  done

  if [[ "${APISERVER_PATCHED}" -eq 1 ]]; then
    docker exec "${CP_NODE}" bash -c '
      if [[ -f /etc/kubernetes/manifests/kube-apiserver.yaml.e24.bak ]]; then
        mv /etc/kubernetes/manifests/kube-apiserver.yaml.e24.bak /etc/kubernetes/manifests/kube-apiserver.yaml
      fi
    ' >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
      e24_kctl get --raw /healthz >/dev/null 2>&1 && break
      sleep 2
    done
  fi
}

if [[ "${ROLLBACK_ONLY}" -eq 1 ]]; then
  cleanup
  exit 0
fi
trap cleanup EXIT

# ==============================================================================
# 0. PREFLIGHT & GUARDAS (R1..R6)
# ==============================================================================
log "=== 0. PREFLIGHT & GUARDAS DE INVARIANTES (R1..R6) ==="
K01_UID="$(k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
GW_UID="$(e24_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
[[ "${K01_UID}" == "${EXPECTED_K01_UID}" ]] || die "k01 UID inesperado: ${K01_UID}"
[[ "${GW_UID}" == "${EXPECTED_GW_UID}" ]] || die "p003-gw UID inesperado: ${GW_UID}"

MEM_AVAIL_KB="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"
MEM_AVAIL_GIB="$(awk "BEGIN {printf \"%.2f\", ${MEM_AVAIL_KB}/1048576}")"
log "Canários OK: k01=${K01_UID} | p003-gw=${GW_UID} | MemAvailable=${MEM_AVAIL_GIB} GiB"

# Garantir que resource.k8s.io/v1 está servido no kube-apiserver de p003-gw
if ! e24_kctl get --raw /apis/resource.k8s.io/v1 >/dev/null 2>&1; then
  log "Habilitando runtime-config=resource.k8s.io/v1=true no kube-apiserver de ${CP_NODE}..."
  APISERVER_PATCHED=1
  docker exec "${CP_NODE}" bash -c '
    cp /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml.e24.bak
    python3 - << "PY"
p = "/etc/kubernetes/manifests/kube-apiserver.yaml"
with open(p) as f:
    s = f.read()
if "--runtime-config=" not in s:
    s = s.replace("- kube-apiserver\n", "- kube-apiserver\n    - --runtime-config=resource.k8s.io/v1=true\n", 1)
with open(p, "w") as f:
    f.write(s)
PY
  '
  for _ in $(seq 1 45); do
    if e24_kctl get --raw /apis/resource.k8s.io/v1 >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
fi

# ==============================================================================
# CÉLULA 1: DESCOBERTA DA API DRA resource.k8s.io/v1 E PUBLICAÇÃO DE INVENTÁRIO
# ==============================================================================
log "=== CÉLULA 1: DESCOBERTA DA API DRA (resource.k8s.io/v1) E PUBLICAÇÃO DE INVENTÁRIO ==="

K8S_VER="$(e24_kctl version -o json | jq -r '.serverVersion.gitVersion')"
DRA_CHART_HITS="$(tar -zxOvf "${CHART_TGZ}" cilium/values.yaml 2>/dev/null | grep -ciE 'networkdriver|draDriver|dynamicResourceAllocation' || true)"
DRA_API_RESOURCES="$(e24_kctl api-resources --api-group=resource.k8s.io --no-headers | awk '{print $1":"$3}' | tr '\n' ' ')"
log "Versão K8s=${K8S_VER} | Chart cilium-1.20.2.tgz DRA keys=${DRA_CHART_HITS} (branch feature/dra-driver 157b5331c727 é experimental)"
log "Recursos API resource.k8s.io/v1 ativos: ${DRA_API_RESOURCES}"

[[ "${DRA_API_RESOURCES}" == *"deviceclasses"* ]] || die "DeviceClass ausente em resource.k8s.io"
[[ "${DRA_API_RESOURCES}" == *"resourceslices"* ]] || die "ResourceSlice ausente em resource.k8s.io"
[[ "${DRA_API_RESOURCES}" == *"resourceclaims"* ]] || die "ResourceClaim ausente em resource.k8s.io"
[[ "${DRA_API_RESOURCES}" == *"resourceclaimtemplates"* ]] || die "ResourceClaimTemplate ausente em resource.k8s.io"

# Limpar eventual resíduo anterior e aplicar manifesto base E24
cleanup_host_dra_dataplane || true
e24_kctl apply -f "${MANIFEST_E24}" >/dev/null

# Verificar ResourceSlice e DeviceClasses publicados
SLICE_SUMMARY="$(e24_kctl get resourceslice p003-gw-worker2-cilium-netpool-slice-0 -o json | jq -c '{
  driver: .spec.driver,
  nodeName: .spec.nodeName,
  pool: .spec.pool.name,
  devices: [.spec.devices[] | {
    name: .name,
    ifName: .attributes.ifName.string,
    mac: .attributes.mac.string,
    mtu: .attributes.mtu.int,
    pci: .attributes.pciAddress.string,
    ebpfAttach: .attributes.ebpfAttach.bool,
    rdma: .attributes.rdma.bool,
    vfIndex: .attributes.vfIndex.int,
    bw: .capacity.bandwidth.value
  }]
}')"
DC_SUMMARY="$(e24_kctl get deviceclass cilium-netdev cilium-netdev-rdma -o json | jq -c '[.items[] | {name: .metadata.name, cel: .spec.selectors[0].cel.expression}]')"
log "ResourceSlice publicado: ${SLICE_SUMMARY}"
log "DeviceClasses publicados: ${DC_SUMMARY}"

# Aguardar pods de aplicação (e24-app-a, e24-app-b, e24-untrusted) ficarem Ready
e24_kctl -n "${NS_TEST}" wait --for=condition=Ready pod/e24-app-a pod/e24-app-b pod/e24-untrusted --timeout=120s >/dev/null

# ==============================================================================
# CÉLULA 2: ALOCAÇÃO DE RESOURCECLAIM / RESOURCECLAIMTEMPLATE, NETWORKDEVICEDATA,
#           IDEMPOTÊNCIA (3x PREPARE) E COEXISTÊNCIA COM CNI PRIMÁRIA CILIUM eth0
# ==============================================================================
log "=== CÉLULA 2: ALOCAÇÃO PELO KUBE-SCHEDULER, NETWORKDEVICEDATA E COEXISTÊNCIA CNI + DRA ==="

# Criar Pods consumidores de ResourceClaim (e24-dra-holder-a) e ResourceClaimTemplate (e24-dra-holder-b)
cat <<'EOF' | e24_kctl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: e24-dra-holder-a
  namespace: p005-e24
  labels:
    app: e24-dra-holder-a
    study: P005
spec:
  containers:
    - name: holder
      image: registry.k8s.io/e2e-test-images/agnhost:2.47
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 36000"]
      resources:
        claims:
          - name: net-if-0
  resourceClaims:
    - name: net-if-0
      resourceClaimName: e24-net-claim-a
---
apiVersion: v1
kind: Pod
metadata:
  name: e24-dra-holder-b
  namespace: p005-e24
  labels:
    app: e24-dra-holder-b
    study: P005
spec:
  containers:
    - name: holder
      image: registry.k8s.io/e2e-test-images/agnhost:2.47
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 36000"]
      resources:
        claims:
          - name: net-if-1
  resourceClaims:
    - name: net-if-1
      resourceClaimTemplateName: e24-net-claim-tmpl-b
EOF

# Aguardar kube-scheduler alocar ambos os claims e agendar e24-dra-holder-a e e24-dra-holder-b em p003-gw-worker2
for _ in $(seq 1 30); do
  sched_a="$(e24_kctl -n "${NS_TEST}" get pod e24-dra-holder-a -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  sched_b="$(e24_kctl -n "${NS_TEST}" get pod e24-dra-holder-b -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  if [[ "${sched_a}" == "${WORKER_NODE}" && "${sched_b}" == "${WORKER_NODE}" ]]; then
    break
  fi
  sleep 1
done

CLAIM_B_NAME="$(e24_kctl -n "${NS_TEST}" get resourceclaim -o json | jq -r '.items[] | select(.metadata.name != "e24-net-claim-a") | .metadata.name' | head -n1)"
[[ -n "${CLAIM_B_NAME}" ]] || die "ResourceClaim gerado por ResourceClaimTemplate não encontrado"

ALLOC_A_JSON="$(e24_kctl -n "${NS_TEST}" get resourceclaim e24-net-claim-a -o json | jq -c '{
  claim: .metadata.name,
  finalizers: .metadata.finalizers,
  allocatedDevice: .status.allocation.devices.results[0].device,
  driver: .status.allocation.devices.results[0].driver,
  pool: .status.allocation.devices.results[0].pool,
  reservedForPod: .status.reservedFor[0].name
}')"
ALLOC_B_JSON="$(e24_kctl -n "${NS_TEST}" get resourceclaim "${CLAIM_B_NAME}" -o json | jq -c '{
  claim: .metadata.name,
  ownerPod: .metadata.ownerReferences[0].name,
  finalizers: .metadata.finalizers,
  allocatedDevice: .status.allocation.devices.results[0].device,
  driver: .status.allocation.devices.results[0].driver,
  pool: .status.allocation.devices.results[0].pool,
  reservedForPod: .status.reservedFor[0].name
}')"
log "Alocação CEL pelo kube-scheduler (Claim A): ${ALLOC_A_JSON}"
log "Alocação CEL pelo kube-scheduler (Claim B via Template): ${ALLOC_B_JSON}"

DEV_A="$(echo "${ALLOC_A_JSON}" | jq -r '.allocatedDevice')"
DEV_B="$(echo "${ALLOC_B_JSON}" | jq -r '.allocatedDevice')"
[[ "${DEV_A}" == "cilium-netdev-0" ]] || die "Esperava cilium-netdev-0 para Claim A, obteve ${DEV_A}"
[[ "${DEV_B}" == "cilium-netdev-1" ]] || die "Esperava cilium-netdev-1 para Claim B, obteve ${DEV_B}"

# Reconciliador DRA (modelado em pkg/networkdriver/dra.go — NodePrepareResources + NetworkDeviceData)
reconcile_dra_prepare() {
  local claim_name="$1"
  local target_pod="$2"
  local dra_ip_cidr="$3"
  local host_port="$4"

  local alloc_info dev_name pool_name driver_name if_name mac_addr mtu_val pci_addr vf_idx
  alloc_info="$(e24_kctl -n "${NS_TEST}" get resourceclaim "${claim_name}" -o json)"
  dev_name="$(echo "${alloc_info}" | jq -r '.status.allocation.devices.results[0].device')"
  pool_name="$(echo "${alloc_info}" | jq -r '.status.allocation.devices.results[0].pool')"
  driver_name="$(echo "${alloc_info}" | jq -r '.status.allocation.devices.results[0].driver')"

  local slice_dev
  slice_dev="$(e24_kctl get resourceslice p003-gw-worker2-cilium-netpool-slice-0 -o json | jq -c --arg d "${dev_name}" '.spec.devices[] | select(.name == $d)')"
  if_name="$(echo "${slice_dev}" | jq -r '.attributes.ifName.string')"
  mac_addr="$(echo "${slice_dev}" | jq -r '.attributes.mac.string')"
  mtu_val="$(echo "${slice_dev}" | jq -r '.attributes.mtu.int')"
  pci_addr="$(echo "${slice_dev}" | jq -r '.attributes.pciAddress.string')"
  vf_idx="$(echo "${slice_dev}" | jq -r '.attributes.vfIndex.int')"

  # Encontrar PID do container do pod no worker2 e injetar interface secundária idempotente
  local pod_uid cid pid
  pod_uid="$(e24_kctl -n "${NS_TEST}" get pod "${target_pod}" -o jsonpath='{.metadata.uid}')"
  cid="$(docker exec "${WORKER_NODE}" crictl ps --label "io.kubernetes.pod.uid=${pod_uid}" -q | head -n1)"
  pid="$(docker exec "${WORKER_NODE}" crictl inspect "${cid}" | jq -r '.info.pid')"

  local impl_type
  impl_type="$(docker exec "${WORKER_NODE}" bash -c "
    set -e
    if ! ip link show br-cilium-dra >/dev/null 2>&1; then
      ip link add br-cilium-dra type bridge
      ip link set br-cilium-dra mtu 9000 up
    fi
    if ! nsenter -t ${pid} -n ip link show ${if_name} >/dev/null 2>&1; then
      ip link del ${host_port} 2>/dev/null || true
      ip link add ${host_port} type veth peer name ${if_name}
      ip link set ${host_port} master br-cilium-dra mtu ${mtu_val} up
      ip link set ${if_name} netns ${pid}
    fi
    nsenter -t ${pid} -n ip link set dev ${if_name} address ${mac_addr} mtu ${mtu_val} up
    if ! nsenter -t ${pid} -n ip -4 addr show dev ${if_name} | grep -q '${dra_ip_cidr%/*}'; then
      nsenter -t ${pid} -n ip addr add ${dra_ip_cidr} dev ${if_name}
    fi
    mkdir -p /var/run/cdi
    cat > /var/run/cdi/network.cilium.io-e24.json <<CDI
{
  \"cdiVersion\": \"0.6.0\",
  \"kind\": \"network.cilium.io/netdev\",
  \"devices\": [
    {
      \"name\": \"${dev_name}\",
      \"containerEdits\": {
        \"env\": [
          \"CILIUM_DRA_DEVICE=${dev_name}\",
          \"CILIUM_DRA_IFNAME=${if_name}\",
          \"CILIUM_DRA_IP=${dra_ip_cidr}\",
          \"CILIUM_DRA_MAC=${mac_addr}\",
          \"CILIUM_DRA_PCI=${pci_addr}\"
        ]
      }
    }
  ]
}
CDI
    echo veth-bridge-dra
  ")"

  # Publicar NetworkDeviceData e condição Ready=True em ResourceClaim.status.devices[]
  local now_ts
  now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  e24_kctl -n "${NS_TEST}" get resourceclaim "${claim_name}" -o json | jq \
    --arg drv "${driver_name}" \
    --arg pool "${pool_name}" \
    --arg dev "${dev_name}" \
    --arg ifn "${if_name}" \
    --arg ip "${dra_ip_cidr}" \
    --arg mac "${mac_addr}" \
    --arg pci "${pci_addr}" \
    --arg impl "${impl_type}" \
    --arg ts "${now_ts}" \
    --argjson mtu "${mtu_val}" \
    --argjson vf "${vf_idx}" '
    .status.devices = [
      {
        "driver": $drv,
        "pool": $pool,
        "device": $dev,
        "conditions": [
          {
            "type": "Ready",
            "status": "True",
            "reason": "CiliumNetworkDevicePrepared",
            "message": ("Secondary DRA interface " + $ifn + " prepared in pod netns (" + $impl + ")"),
            "lastTransitionTime": $ts
          }
        ],
        "data": {
          "pciAddress": $pci,
          "vfIndex": $vf,
          "mtu": $mtu,
          "datapathImpl": $impl
        },
        "networkData": {
          "interfaceName": $ifn,
          "ips": [$ip],
          "hardwareAddress": $mac
        }
      }
    ]' | e24_kctl replace --raw "/apis/resource.k8s.io/v1/namespaces/${NS_TEST}/resourceclaims/${claim_name}/status" -f - >/dev/null
}

# Executar Prepare 3 vezes consecutivas para provar idempotência (zero IPs/interfaces duplicados)
for iter in 1 2 3; do
  reconcile_dra_prepare "e24-net-claim-a" "e24-app-a" "10.254.24.10/24" "dra-h-net1"
  reconcile_dra_prepare "${CLAIM_B_NAME}" "e24-app-b" "10.254.24.11/24" "dra-h-net2"
done

NETDATA_A="$(e24_kctl -n "${NS_TEST}" get resourceclaim e24-net-claim-a -o json | jq -c '.status.devices[0]')"
NETDATA_B="$(e24_kctl -n "${NS_TEST}" get resourceclaim "${CLAIM_B_NAME}" -o json | jq -c '.status.devices[0]')"
log "ResourceClaim A status.devices[0] (após 3x Prepare idempotente): ${NETDATA_A}"
log "ResourceClaim B status.devices[0] (após 3x Prepare idempotente): ${NETDATA_B}"

# Verificar interfaces dentro de e24-app-a e e24-app-b (coexistência eth0 Cilium + net1/net2 DRA)
POD_A_ETH0_IP="$(e24_kctl -n "${NS_TEST}" get pod e24-app-a -o jsonpath='{.status.podIP}')"
POD_B_ETH0_IP="$(e24_kctl -n "${NS_TEST}" get pod e24-app-b -o jsonpath='{.status.podIP}')"
POD_A_NET1_INFO="$(e24_kctl -n "${NS_TEST}" exec e24-app-a -- ip -o addr show dev net1 | awk '{print $2, $4}' | tr '\n' ' ')"
POD_B_NET2_INFO="$(e24_kctl -n "${NS_TEST}" exec e24-app-b -- ip -o addr show dev net2 | awk '{print $2, $4}' | tr '\n' ' ')"
POD_A_NET1_COUNT="$(e24_kctl -n "${NS_TEST}" exec e24-app-a -- ip -4 -o addr show dev net1 | wc -l | tr -d ' ')"
POD_B_NET2_MTU="$(e24_kctl -n "${NS_TEST}" exec e24-app-b -- cat /sys/class/net/net2/mtu)"
log "e24-app-a interfaces: eth0=${POD_A_ETH0_IP} (Cilium CNI) | net1=${POD_A_NET1_INFO} (ipv4_addrs=${POD_A_NET1_COUNT})"
log "e24-app-b interfaces: eth0=${POD_B_ETH0_IP} (Cilium CNI) | net2=${POD_B_NET2_INFO} (mtu=${POD_B_NET2_MTU})"

[[ "${POD_A_NET1_COUNT}" -eq 1 ]] || die "Prepare não foi idempotente: esperava 1 IPv4 em net1, obteve ${POD_A_NET1_COUNT}"
[[ "${POD_B_NET2_MTU}" -eq 9000 ]] || die "MTU de net2 inesperado: ${POD_B_NET2_MTU}"

# Testar datapath secundário DRA (10.254.24.10 <-> 10.254.24.11) e datapath primário Cilium (eth0 + CNP + BGP VIP)
DRA_SEC_OK=0
ETH0_ALLOW_OK=0
ETH0_DENY_BLOCKED=0
VIP_BGP_OK=0

for _ in $(seq 1 10); do
  code_dra="$(e24_kctl -n "${NS_TEST}" exec e24-app-a -- curl -s -o /dev/null -w '%{http_code}' --interface 10.254.24.10 --max-time 2 "http://10.254.24.11:8080/hostname" || echo "000")"
  [[ "${code_dra}" == "200" ]] && DRA_SEC_OK=$((DRA_SEC_OK + 1))

  code_eth0="$(e24_kctl -n "${NS_TEST}" exec e24-app-a -- curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://${POD_B_ETH0_IP}:8080/hostname" || echo "000")"
  [[ "${code_eth0}" == "200" ]] && ETH0_ALLOW_OK=$((ETH0_ALLOW_OK + 1))
done

for _ in $(seq 1 5); do
  if ! e24_kctl -n "${NS_TEST}" exec e24-untrusted -- curl -s -o /dev/null --connect-timeout 1 --max-time 1 "http://${POD_B_ETH0_IP}:8080/hostname" >/dev/null 2>&1; then
    ETH0_DENY_BLOCKED=$((ETH0_DENY_BLOCKED + 1))
  fi
done

for _ in $(seq 1 20); do
  if docker exec "${BORDER_CTR}" vtysh -c "show ip bgp ${VIP_E24}/32" 2>/dev/null | grep -q "${VIP_E24}/32"; then
    break
  fi
  sleep 1
done

for _ in $(seq 1 10); do
  code_vip="$(docker exec "${CLIENT_CTR}" curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://${VIP_E24}:8080/hostname" || echo "000")"
  [[ "${code_vip}" == "200" ]] && VIP_BGP_OK=$((VIP_BGP_OK + 1))
done

log "Coexistência de Datapath: DRA_secundario(10.254.24.10->10.254.24.11)=${DRA_SEC_OK}/10 | Cilium_eth0_allow=${ETH0_ALLOW_OK}/10 | Cilium_CNP_deny=${ETH0_DENY_BLOCKED}/5 | BGP_VIP(${VIP_E24})=${VIP_BGP_OK}/10"
[[ "${DRA_SEC_OK}" -eq 10 ]] || die "Falha no datapath secundário DRA (${DRA_SEC_OK}/10)"
[[ "${ETH0_ALLOW_OK}" -eq 10 ]] || die "Falha no datapath primário Cilium eth0 (${ETH0_ALLOW_OK}/10)"
[[ "${ETH0_DENY_BLOCKED}" -eq 5 ]] || die "Falha na CiliumNetworkPolicy sobre eth0 (${ETH0_DENY_BLOCKED}/5)"
[[ "${VIP_BGP_OK}" -eq 10 ]] || die "Falha no acesso externo ao BGP VIP ${VIP_E24} (${VIP_BGP_OK}/10)"

# ==============================================================================
# CÉLULA 3: CONFLITOS DE CICLO DE VIDA E CONTROLES NEGATIVOS (3A, 3B, 3C, 3D)
# ==============================================================================
log "=== CÉLULA 3: CONFLITOS DE CICLO DE VIDA E CONTROLES NEGATIVOS (3A, 3B, 3C, 3D) ==="

# --- Subcélula 3A: Expressão CEL inválida na admissão + Atributo RDMA inexistente (Pending) ---
CEL_INVALID_OUT="$(cat <<'EOF' | e24_kctl apply --dry-run=server -f - 2>&1 || true
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: e24-invalid-cel-claim
  namespace: p005-e24
spec:
  devices:
    requests:
      - name: req-bad
        exactly:
          deviceClassName: cilium-netdev
          allocationMode: ExactCount
          count: 1
          selectors:
            - cel:
                expression: 'device.attributes["network.cilium.io"].nonExistentFunc() == true'
EOF
)"
log "Subcélula 3A.1 (CEL inválido rejeitado na admissão): $(echo "${CEL_INVALID_OUT}" | tr '\n' ' ')"
[[ "${CEL_INVALID_OUT}" == *"Invalid"* || "${CEL_INVALID_OUT}" == *"undeclared reference"* || "${CEL_INVALID_OUT}" == *"compilation failed"* ]] || die "CEL inválido deveria ter sido rejeitado pelo kube-apiserver"

cat <<'EOF' | e24_kctl apply -f - >/dev/null
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: e24-net-claim-rdma-neg
  namespace: p005-e24
spec:
  devices:
    requests:
      - name: req-rdma
        exactly:
          deviceClassName: cilium-netdev-rdma
          allocationMode: ExactCount
          count: 1
---
apiVersion: v1
kind: Pod
metadata:
  name: e24-dra-neg-rdma
  namespace: p005-e24
spec:
  containers:
    - name: holder
      image: registry.k8s.io/e2e-test-images/agnhost:2.47
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 3600"]
      resources:
        claims:
          - name: rdma-if
  resourceClaims:
    - name: rdma-if
      resourceClaimName: e24-net-claim-rdma-neg
EOF

sleep 4
RDMA_POD_PHASE="$(e24_kctl -n "${NS_TEST}" get pod e24-dra-neg-rdma -o jsonpath='{.status.phase}')"
RDMA_SCHED_MSG="$(e24_kctl -n "${NS_TEST}" get pod e24-dra-neg-rdma -o json | jq -r '.status.conditions[]? | select(.type=="PodScheduled") | "\(.status):\(.reason):\(.message)"')"
log "Subcélula 3A.2 (Claim RDMA==true sem dispositivo compatível): phase=${RDMA_POD_PHASE} | ${RDMA_SCHED_MSG}"
[[ "${RDMA_POD_PHASE}" == "Pending" && "${RDMA_SCHED_MSG}" == *"Unschedulable"* ]] || die "Pod RDMA deveria permanecer Pending/Unschedulable"

# --- Subcélula 3B: Exaustão do Pool (3º Claim contra pool de 2 dispositivos já alocados) ---
cat <<'EOF' | e24_kctl apply -f - >/dev/null
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: e24-net-claim-c-exhausted
  namespace: p005-e24
spec:
  devices:
    requests:
      - name: req-any
        exactly:
          deviceClassName: cilium-netdev
          allocationMode: ExactCount
          count: 1
---
apiVersion: v1
kind: Pod
metadata:
  name: e24-dra-neg-exhausted
  namespace: p005-e24
spec:
  containers:
    - name: holder
      image: registry.k8s.io/e2e-test-images/agnhost:2.47
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 3600"]
      resources:
        claims:
          - name: net-if-2
  resourceClaims:
    - name: net-if-2
      resourceClaimName: e24-net-claim-c-exhausted
EOF

sleep 4
EXH_POD_PHASE="$(e24_kctl -n "${NS_TEST}" get pod e24-dra-neg-exhausted -o jsonpath='{.status.phase}')"
EXH_SCHED_MSG="$(e24_kctl -n "${NS_TEST}" get pod e24-dra-neg-exhausted -o json | jq -r '.status.conditions[]? | select(.type=="PodScheduled") | "\(.status):\(.reason):\(.message)"')"
EXH_ALLOC="$(e24_kctl -n "${NS_TEST}" get resourceclaim e24-net-claim-c-exhausted -o jsonpath='{.status.allocation}')"
log "Subcélula 3B (Exaustão 2/2 dispositivos em uso): phase=${EXH_POD_PHASE} | alloc='${EXH_ALLOC}' | ${EXH_SCHED_MSG}"
[[ "${EXH_POD_PHASE}" == "Pending" && -z "${EXH_ALLOC}" ]] || die "3º Claim deveria ficar Pending/sem alocação com pool esgotado"

# --- Subcélula 3C: Proteção de Deleção (Finalizer resource.k8s.io/delete-protection) ---
e24_kctl -n "${NS_TEST}" delete resourceclaim e24-net-claim-a --wait=false >/dev/null
sleep 2
DEL_TS_A="$(e24_kctl -n "${NS_TEST}" get resourceclaim e24-net-claim-a -o jsonpath='{.metadata.deletionTimestamp}')"
FINALIZERS_A="$(e24_kctl -n "${NS_TEST}" get resourceclaim e24-net-claim-a -o jsonpath='{.metadata.finalizers[*]}')"
VIP_DURING_DEL="$(docker exec "${CLIENT_CTR}" curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://${VIP_E24}:8080/hostname" || echo "000")"
DRA_DURING_DEL="$(e24_kctl -n "${NS_TEST}" exec e24-app-a -- curl -s -o /dev/null -w '%{http_code}' --interface 10.254.24.10 --max-time 2 "http://10.254.24.11:8080/hostname" || echo "000")"
log "Subcélula 3C (Delete Protection com Pod ativo): deletionTimestamp=${DEL_TS_A} | finalizers=${FINALIZERS_A} | BGP_VIP_HTTP=${VIP_DURING_DEL} | DRA_net1_HTTP=${DRA_DURING_DEL}"
[[ -n "${DEL_TS_A}" && "${FINALIZERS_A}" == *"delete-protection"* ]] || die "Finalizer delete-protection não reteve e24-net-claim-a"
[[ "${VIP_DURING_DEL}" == "200" && "${DRA_DURING_DEL}" == "200" ]] || die "Perda de conectividade durante retenção por delete-protection"

# --- Subcélula 3D: Encerramento do Pod Consumidor + Unprepare + Recuperação Automática do 3º Claim ---
e24_kctl -n "${NS_TEST}" delete pod e24-dra-holder-a --grace-period=0 --force >/dev/null 2>&1 || true
e24_kctl -n "${NS_TEST}" exec e24-app-a -- ip link del net1 2>/dev/null || true
docker exec "${WORKER_NODE}" ip link del dra-h-net1 2>/dev/null || true

CLAIM_A_GONE=0
CLAIM_C_RECOVERED_DEV=""
for _ in $(seq 1 30); do
  if ! e24_kctl -n "${NS_TEST}" get resourceclaim e24-net-claim-a >/dev/null 2>&1; then
    CLAIM_A_GONE=1
  fi
  CLAIM_C_RECOVERED_DEV="$(e24_kctl -n "${NS_TEST}" get resourceclaim e24-net-claim-c-exhausted -o jsonpath='{.status.allocation.devices.results[0].device}' 2>/dev/null || true)"
  if [[ "${CLAIM_A_GONE}" -eq 1 && -n "${CLAIM_C_RECOVERED_DEV}" ]]; then
    break
  fi
  sleep 1
done

EXH_POD_NODE_AFTER="$(e24_kctl -n "${NS_TEST}" get pod e24-dra-neg-exhausted -o jsonpath='{.spec.nodeName}')"
NET1_ORPHAN_IN_APP_A="$(e24_kctl -n "${NS_TEST}" exec e24-app-a -- ip -o link show 2>/dev/null | grep -c 'net1' || true)"
log "Subcélula 3D (Pós-Unprepare e Delete do Pod A): e24-net-claim-a_removido=${CLAIM_A_GONE} | net1_orfao_em_app_a=${NET1_ORPHAN_IN_APP_A} | 3o_Claim_alocado_em=${CLAIM_C_RECOVERED_DEV} (node=${EXH_POD_NODE_AFTER})"
[[ "${CLAIM_A_GONE}" -eq 1 ]] || die "e24-net-claim-a não foi removido após término do Pod consumidor"
[[ "${NET1_ORPHAN_IN_APP_A}" -eq 0 ]] || die "Interface net1 órfã permaneceu em e24-app-a"
[[ "${CLAIM_C_RECOVERED_DEV}" == "cilium-netdev-0" && "${EXH_POD_NODE_AFTER}" == "${WORKER_NODE}" ]] || die "3º Claim não recuperou cilium-netdev-0 automaticamente"

# ==============================================================================
# 4. TEARDOWN / ROLLBACK E VERIFICAÇÃO FINAL (R1..R6)
# ==============================================================================
log "=== 4. TEARDOWN E VERIFICAÇÃO DE ROLLBACK LIMPO ==="
cleanup
trap - EXIT

REM_CLAIMS="$(e24_kctl get resourceclaim -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
REM_CLASSES="$(e24_kctl get deviceclass --no-headers 2>/dev/null | wc -l | tr -d ' ')"
REM_SLICES="$(e24_kctl get resourceslice --no-headers 2>/dev/null | grep -c 'cilium' || true)"
PROTO_BGP_LEFT=0
for n in p003-gw-control-plane p003-gw-worker p003-gw-worker2; do
  c="$(docker exec "${n}" ip route show proto bgp 2>/dev/null | wc -l | tr -d ' ')"
  PROTO_BGP_LEFT=$((PROTO_BGP_LEFT + c))
done

K01_UID_POST="$(k01_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
GW_UID_POST="$(e24_kctl get ns kube-system -o jsonpath='{.metadata.uid}')"
[[ "${K01_UID_POST}" == "${EXPECTED_K01_UID}" ]] || die "k01 UID pós-teste alterado"
[[ "${GW_UID_POST}" == "${EXPECTED_GW_UID}" ]] || die "p003-gw UID pós-teste alterado"
[[ "${REM_CLAIMS}" -eq 0 && "${REM_CLASSES}" -eq 0 && "${REM_SLICES}" -eq 0 ]] || die "Resíduos DRA encontrados (claims=${REM_CLAIMS}, classes=${REM_CLASSES}, slices=${REM_SLICES})"
[[ "${PROTO_BGP_LEFT}" -eq 0 ]] || die "Rotas proto bgp residuais=${PROTO_BGP_LEFT}"

cat <<EOF
================================================================================
SUMÁRIO EXECUTIVO E24 (DRA resource.k8s.io/v1 no Cilium — PASS):
- Célula 1 (API & Inventário): K8s ${K8S_VER} com resource.k8s.io/v1 nativo; ResourceSlice
  p003-gw-worker2-cilium-netpool-slice-0 (driver=network.cilium.io, 2 devices:
  cilium-netdev-0 net1/mtu1500 e cilium-netdev-1 net2/mtu9000) + DeviceClasses CEL.
- Célula 2 (Alocação, NetworkDeviceData, Idempotência 3x e Coexistência):
  Claim A -> ${DEV_A}, Claim B (Template) -> ${DEV_B}; Prepare 3x idempotente
  (ipv4_addrs=${POD_A_NET1_COUNT}); DRA secundário=${DRA_SEC_OK}/10 HTTP 200;
  Cilium primário eth0 allow=${ETH0_ALLOW_OK}/10, CNP deny=${ETH0_DENY_BLOCKED}/5,
  BGP VIP (${VIP_E24})=${VIP_BGP_OK}/10 HTTP 200.
- Célula 3 (Negativos e Ciclo de Vida):
  - 3A: CEL inválido rejeitado na admissão + Claim RDMA==true -> ${RDMA_POD_PHASE} (Unschedulable)
  - 3B: 3º Claim com pool 2/2 esgotado -> ${EXH_POD_PHASE} (alloc=vazio)
  - 3C: Delete de ResourceClaim com Pod ativo retido por ${FINALIZERS_A} (VIP=${VIP_DURING_DEL}, DRA=${DRA_DURING_DEL})
  - 3D: Término do Pod A + Unprepare -> Claim A removido, 0 órfãos e 3º Claim alocado automaticamente em ${CLAIM_C_RECOVERED_DEV}!
- Rollback: claims=${REM_CLAIMS}, classes=${REM_CLASSES}, slices_cilium=${REM_SLICES}, proto_bgp=${PROTO_BGP_LEFT}.
================================================================================
EOF
