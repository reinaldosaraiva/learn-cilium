#!/usr/bin/env bash
# P004-S002/M03: prova reversível de EVPN Type 5 no tenant MGC.
#
# Este ensaio é deliberadamente separado do perfil labctl mgc. Ele só pode
# usar recursos que o preflight provou como pertencentes ao MGC e não adota
# sobras de uma tentativa anterior. Um --execute que falha entra no trap e
# tenta voltar ao estado MGC por nome/ID, seguido de labctl mgc up/verify.
# shellcheck disable=SC2329  # cleanup helpers are reached from the EXIT trap.
set -euo pipefail

usage() {
  cat <<'EOF'
Uso:
  LAB_ROOT=/opt/poc-k8s-fabric \
  M03_PREFLIGHT_RECEIPT=/caminho/para/preflight.txt \
  bash studies/p004/ovn/m03.sh --dry-run|--execute

O recibo de preflight deve conter, em linhas únicas:
  k01_uid=<uid>
  p003_gw_uid=<uid>
  k01_canary=10/10
  p003_gw_canary=10/10
  timestamp=<UTC RFC3339 timestamp>
  host=<hostname of the preflight host>

--dry-run só lê o MGC e imprime o plano. --execute é obrigatório para
qualquer mutação e sempre tenta restaurar o baseline na saída.
EOF
}

[[ "$#" -eq 1 ]] || { usage >&2; exit 2; }
M03_INTERNAL_PHASE=""
case "$1" in
  --dry-run) DRY_RUN=1 ;;
  --execute) DRY_RUN=0 ;;
  --phase-up|--phase-verify)
    M03_INTERNAL_PHASE="${1#--phase-}"
    DRY_RUN="${DRY_RUN:-0}"
    [[ "${MGC_M03_PHASE_CHILD:-0}" == 1 ]] \
      || { usage >&2; exit 2; }
    ;;
  *) usage >&2; exit 2 ;;
esac

: "${LAB_ROOT:?LAB_ROOT é obrigatório}"
export LAB_ROOT DRY_RUN

# shellcheck source=../../../labctl/lib/common.sh
# shellcheck disable=SC1091
source "${LAB_ROOT}/lib/common.sh"
# shellcheck source=../../../labctl/labs/mgc.sh
# shellcheck disable=SC1091
source "${LAB_ROOT}/labs/mgc.sh"

require_cmd docker git ip awk grep timeout nsenter tcpdump date hostname cmp flock \
  ovs-vsctl env sed tr seq sleep python3 kubectl stat cp wc sort
[[ "$(id -u)" -eq 0 ]] || die 'M03 exige root no host vm-cilium'

M03_PEER="mgc-evpn-client-1"
M03_IMAGE="ovn/ovn-multi-node:latest"
# This digest was read from the pinned MGC image before M03 was authored.  A
# moving :latest tag is never accepted as sufficient provenance for execute.
M03_IMAGE_DIGEST="sha256:eda2364d9cfbec6dd26f54b335c37efa9dade64ffdccbff374b5c50ae64ce52a"
M03_CHASSIS="ovn-chassis-1"
M03_CENTRAL="ovn-central-az1"
M03_PEER_IP="170.168.0.7"
M03_CHASSIS_IP="170.168.0.5"
M03_PEER_CIDR="${M03_PEER_IP}/16"
M03_PEER_SOURCE="10.250.0.1"
M03_TENANT_IP="192.168.100.10"
M03_POSITIVE_ICMP_FILTER="icmp and ((src host ${M03_PEER_SOURCE} and dst host ${M03_TENANT_IP}) or (src host ${M03_TENANT_IP} and dst host ${M03_PEER_SOURCE}))"
M03_TENANT_CIDR="192.168.100.0/24"
M03_VNI=50100
M03_TENANT_TABLE=300
M03_CLIENT_TABLE=50100
M03_AUX_DSTPORT=60010
M03_LRP="lrp-mgc-tenant"
M03_TENANT_LR="lr-mgc-tenant"
M03_TENANT_LS="ls-mgc-tenant"
M03_TENANT_VRF="ovnvrf-tenant"
M03_CLIENT_VRF="vrf-evpn-client"
M03_TENANT_BR="br-evpn-tenant"
M03_TENANT_VXLAN="vxlan-tenant"
M03_TENANT_ADVERTISE="evpn-tenant"
M03_TENANT_TAP="mgc-tenant-vm-p"
M03_CLIENT_BR="br-evpn-client"
M03_CLIENT_VXLAN="vxlan-m03-peer"
M03_CLIENT_ADVERTISE="evpn-client"
M03_TENANT_BR_MAC="02:00:00:10:00:01"
M03_CLIENT_BR_MAC="02:00:00:50:10:02"
M03_LRP_REDISTRIBUTE_KEY="dynamic-routing-redistribute"
M03_NEGATIVE_POLL_ATTEMPTS=30
M03_NEGATIVE_POLL_INTERVAL=2
M03_COMMAND_TIMEOUT=8
M03_OWNER_LABEL="labctl-m03-owner"
M03_PREFLIGHT_RECEIPT="${M03_PREFLIGHT_RECEIPT:-}"
M03_LOCK_FILE="${M03_LOCK_FILE:-${MG_M03_LOCK_FILE}}"
M03_MARKER_FILE="${MG_M03_MARKER_FILE}"
M03_MARKER_DIR="$(dirname "${M03_MARKER_FILE}")"
export MG_M03_LOCK_FILE
export MG_M03_MARKER_FILE
M03_K01_KUBECONFIG="${M03_K01_KUBECONFIG:-${K01_KUBECONFIG:-/root/.kube/k01-rebuild.config}}"
M03_K01_CONTEXT="kind-k01"
M03_K01_CLIENT="clab-poc-k8s-kind-client-ext"
M03_K01_VIP="10.201.255.10"
M03_P003_KUBECONFIG="${M03_P003_KUBECONFIG:-${P003_KUBECONFIG:-/root/.kube/p003-gw.config}}"
M03_P003_CONTEXT="kind-p003-gw"
M03_P003_CLIENT="clab-p003-gw-fabric-client"
M03_P003_VIP="10.202.255.10"
M03_VERIFY_PHASE="${M03_VERIFY_PHASE:-m03-verify}"
export M03_PREFLIGHT_RECEIPT M03_K01_KUBECONFIG M03_P003_KUBECONFIG M03_VERIFY_PHASE
M03_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
M03_CHASSIS_CONF="${M03_SCRIPT_DIR}/frr-m03-chassis.conf"
M03_CLIENT_CONF="${M03_SCRIPT_DIR}/frr-m03-client.conf"

M03_RUN_TOKEN="${M03_RUN_TOKEN:-}"
M03_MARKER_TOKEN=""
M03_EVIDENCE_DIR="${M03_EVIDENCE_DIR:-}"
export M03_EVIDENCE_DIR M03_RUN_TOKEN
M03_CLIENT_ID=""
M03_CLIENT_CREATED=0
M03_OWNER_TOKEN=""
M03_RECEIPT_K01_UID=""
M03_RECEIPT_P003_UID=""
M03_K01_UID_PRE=""
M03_P003_UID_PRE=""
M03_K01_CANARY_PRE=""
M03_P003_CANARY_PRE=""
M03_K01_UID_POST=""
M03_P003_UID_POST=""
M03_K01_CANARY_POST=""
M03_P003_CANARY_POST=""
M03_OLD_LRP_OPTIONS=""
M03_OLD_CLIENT_PORT_1=""
M03_OLD_CLIENT_PORT_2=""
M03_CLIENT_PORT_NAME=""
M03_CLIENT_PORT_UUID=""
M03_CLIENT_INTERFACE_UUID=""
M03_CLIENT_HOST_IFACE=""
M03_CHASSIS_FRR_STARTED=0
M03_CLIENT_FRR_STARTED=0
M03_LRP_CHANGED=0
M03_CHASSIS_LINKS_CREATED=0
M03_CLIENT_LINKS_CREATED=0
M03_CLIENT_PORT_CREATED=0
M03_EXECUTION_STARTED=0
M03_POSITIVE_GATES_COMPLETE=0
M03_ALL_GATES_COMPLETE=0
M03_LRP_REDISTRIBUTE_CHANGED=0
M03_LRP_REDISTRIBUTE_CONFIRMED=0
M03_CAUSAL_SET_ATTEMPTED=0
M03_NORMAL_RECOVERY_COMPLETE=0
M03_CLEANUP_RECOVERY_RESULT="NOT_NEEDED"
M03_CAUSAL_BASE_OPTIONS=""
M03_CAUSAL_LRP_UUID=""
M03_TARGET_PB_UUID=""
M03_TARGET_DATAPATH=""
M03_INITIAL_TARGET_PB_UUID=""
M03_INITIAL_TARGET_DATAPATH=""
M03_SB_COLLATERAL_BASELINE_CAPTURED=0
M03_NEGATIVE_CAUSAL_RESULT="NOT_RUN"
M03_NEGATIVE_CONTROL_STATUS="NOT_RUN"
M03_CHASSIS_BR_CREATED=0
M03_CHASSIS_BR_ALIAS=0
M03_TENANT_VXLAN_CREATED=0
M03_TENANT_VXLAN_ALIAS=0
M03_TENANT_ADVERTISE_CREATED=0
M03_TENANT_ADVERTISE_ALIAS=0
M03_CLIENT_VRF_CREATED=0
M03_CLIENT_VRF_ALIAS=0
M03_CLIENT_BR_CREATED=0
M03_CLIENT_BR_ALIAS=0
M03_CLIENT_VXLAN_CREATED=0
M03_CLIENT_VXLAN_ALIAS=0
M03_CLIENT_ADVERTISE_CREATED=0
M03_CLIENT_ADVERTISE_ALIAS=0
declare -a M03_CAPTURE_PIDS=()
declare -a M03_CAPTURE_LOGS=()

say() { printf 'M03 %s\n' "$*"; }
fail() { say "FAIL: $*" >&2; exit 1; }

m03_signal() {
  local signal="$1" rc=130
  [[ "${signal}" == TERM ]] && rc=143
  say "sinal ${signal} recebido; rollback obrigatório" >&2
  trap - INT TERM
  exit "${rc}"
}

exact_ip_present() {
  local ipaddr="$1" output="$2"
  grep -Fq "${ipaddr}/" <<<"${output}"
}

assert_preflight_receipt() {
  local key count receipt_timestamp receipt_host receipt_epoch now age
  [[ -n "${M03_PREFLIGHT_RECEIPT}" ]] \
    || fail 'M03_PREFLIGHT_RECEIPT é obrigatório; UID/canários não podem ser inferidos'
  [[ -f "${M03_PREFLIGHT_RECEIPT}" && -r "${M03_PREFLIGHT_RECEIPT}" ]] \
    || fail "recibo de preflight ausente ou ilegível: ${M03_PREFLIGHT_RECEIPT}"
  for key in k01_uid p003_gw_uid k01_canary p003_gw_canary timestamp host; do
    count="$(grep -Ec "^${key}=[^[:space:]]+$" "${M03_PREFLIGHT_RECEIPT}" || true)"
    [[ "${count}" -eq 1 ]] || fail "recibo deve conter exatamente uma chave ${key}"
  done
  grep -Eq '^k01_canary=10/10$' "${M03_PREFLIGHT_RECEIPT}" \
    || fail 'recibo sem k01_canary=10/10'
  grep -Eq '^p003_gw_canary=10/10$' "${M03_PREFLIGHT_RECEIPT}" \
    || fail 'recibo sem p003_gw_canary=10/10'
  M03_RECEIPT_K01_UID="$(sed -n 's/^k01_uid=//p' "${M03_PREFLIGHT_RECEIPT}")"
  M03_RECEIPT_P003_UID="$(sed -n 's/^p003_gw_uid=//p' "${M03_PREFLIGHT_RECEIPT}")"
  [[ "${M03_RECEIPT_K01_UID}" != "${M03_RECEIPT_P003_UID}" ]] \
    || fail 'UIDs históricos de k01 e p003-gw não podem ser iguais'
  receipt_timestamp="$(sed -n 's/^timestamp=//p' "${M03_PREFLIGHT_RECEIPT}")"
  receipt_host="$(sed -n 's/^host=//p' "${M03_PREFLIGHT_RECEIPT}")"
  [[ "${receipt_timestamp}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || fail 'timestamp do recibo não está em UTC RFC3339'
  [[ "${receipt_host}" == "$(hostname)" || "${receipt_host}" == "$(hostname -s)" ]] \
    || fail "recibo pertence a outro host: ${receipt_host}"
  receipt_epoch="$(date -u -d "${receipt_timestamp}" +%s 2>/dev/null || true)"
  [[ -n "${receipt_epoch}" ]] || fail 'timestamp do recibo não pôde ser convertido'
  now="$(date -u +%s)"
  age=$((now - receipt_epoch))
  (( age >= 0 && age <= 86400 )) \
    || fail "recibo de preflight fora da janela de 24h (idade=${age}s)"
}

check_historical_canaries() {
  local phase="$1" k_uid p_uid k_ok=0 p_ok=0 code
  [[ -r "${M03_K01_KUBECONFIG}" ]] \
    || { say "kubeconfig k01 ausente: ${M03_K01_KUBECONFIG}" >&2; return 1; }
  [[ -r "${M03_P003_KUBECONFIG}" ]] \
    || { say "kubeconfig p003-gw ausente: ${M03_P003_KUBECONFIG}" >&2; return 1; }
  if ! k_uid="$(kubectl --kubeconfig "${M03_K01_KUBECONFIG}" \
    --context "${M03_K01_CONTEXT}" get ns kube-system \
    -o jsonpath='{.metadata.uid}' 2>&1)"; then
    say "UID k01 não pôde ser lido com kubeconfig/contexto explícitos: ${k_uid}" >&2
    return 1
  fi
  if ! p_uid="$(kubectl --kubeconfig "${M03_P003_KUBECONFIG}" \
    --context "${M03_P003_CONTEXT}" get ns kube-system \
    -o jsonpath='{.metadata.uid}' 2>&1)"; then
    say "UID p003-gw não pôde ser lido com kubeconfig/contexto explícitos: ${p_uid}" >&2
    return 1
  fi
  [[ "${k_uid}" =~ ^[[:alnum:]-]+$ && "${p_uid}" =~ ^[[:alnum:]-]+$ ]] \
    || { say 'UID histórico vazio ou inválido' >&2; return 1; }

  for _ in $(seq 1 10); do
    code="$(docker exec "${M03_K01_CLIENT}" curl -s -o /dev/null -w '%{http_code}' \
      --max-time 5 --noproxy '*' "http://${M03_K01_VIP}/hostname" \
      2>/dev/null || true)"
    [[ "${code}" == 200 ]] && k_ok=$((k_ok + 1))
  done
  for _ in $(seq 1 10); do
    code="$(docker exec "${M03_P003_CLIENT}" curl -s -o /dev/null -w '%{http_code}' \
      --max-time 5 --noproxy '*' -H 'Host: echo.p003.study' \
      "http://${M03_P003_VIP}:8080/hostname" 2>/dev/null || true)"
    [[ "${code}" == 200 ]] && p_ok=$((p_ok + 1))
  done
  if [[ "${k_uid}" != "${M03_RECEIPT_K01_UID}" \
    || "${p_uid}" != "${M03_RECEIPT_P003_UID}" ]]; then
    say "UID histórico ao vivo diverge do recibo: k01=${k_uid}/${M03_RECEIPT_K01_UID} p003=${p_uid}/${M03_RECEIPT_P003_UID}" >&2
    return 1
  fi
  if [[ "${phase}" == pre ]]; then
    M03_K01_UID_PRE="${k_uid}"
    M03_P003_UID_PRE="${p_uid}"
    M03_K01_CANARY_PRE="${k_ok}/10"
    M03_P003_CANARY_PRE="${p_ok}/10"
  else
    [[ "${k_uid}" == "${M03_K01_UID_PRE}" \
      && "${p_uid}" == "${M03_P003_UID_PRE}" ]] \
      || { say 'UID histórico mudou entre preflight e postflight' >&2; return 1; }
    M03_K01_UID_POST="${k_uid}"
    M03_P003_UID_POST="${p_uid}"
    M03_K01_CANARY_POST="${k_ok}/10"
    M03_P003_CANARY_POST="${p_ok}/10"
  fi
  [[ "${k_ok}" -eq 10 && "${p_ok}" -eq 10 ]] \
    || { say "canários históricos ${phase} falharam: k01=${k_ok}/10 p003-gw=${p_ok}/10" >&2; return 1; }
  if [[ "${DRY_RUN}" != "1" && -n "${M03_EVIDENCE_DIR}" ]]; then
    {
      echo "phase=${phase}"
      echo "k01_uid=${k_uid}"
      echo "p003_gw_uid=${p_uid}"
      echo "k01_canary=${k_ok}/10"
      echo "p003_gw_canary=${p_ok}/10"
      echo "k01_kubeconfig=${M03_K01_KUBECONFIG}"
      echo "k01_context=${M03_K01_CONTEXT}"
      echo "p003_gw_kubeconfig=${M03_P003_KUBECONFIG}"
      echo "p003_gw_context=${M03_P003_CONTEXT}"
    } >"${M03_EVIDENCE_DIR}/historical-${phase}-canaries.txt"
  fi
}

assert_static_inputs() {
  local link_name
  [[ "${MG_CLIENT_NAME}" == 'mgc-client-1' ]] \
    || fail "M03 exige o cliente canônico mgc-client-1 (obtido ${MG_CLIENT_NAME})"
  for link_name in "${M03_TENANT_VRF}" "${M03_TENANT_BR}" \
    "${M03_TENANT_VXLAN}" "${M03_TENANT_ADVERTISE}" \
    "${M03_CLIENT_VRF}" "${M03_CLIENT_BR}" \
    "${M03_CLIENT_VXLAN}" "${M03_CLIENT_ADVERTISE}"; do
    [[ "${#link_name}" -le 15 ]] \
      || fail "nome de link/VRF Linux excede IFNAMSIZ-1 (15): ${link_name}"
    [[ "${link_name}" =~ ^[[:alnum:]_.-]+$ ]] \
      || fail "nome de link/VRF Linux contém caractere inválido: ${link_name}"
  done
  [[ -f "${M03_CHASSIS_CONF}" && -f "${M03_CLIENT_CONF}" ]] \
    || fail 'fixtures FRR do M03 ausentes'
  [[ -x "${MGC_FAKE_MN}/ovs-runc" ]] \
    || fail "ovs-runc ausente ou não executável: ${MGC_FAKE_MN}/ovs-runc"

  [[ -f "${MGC_OVN_SRC}/tests/multinode.at" ]] \
    || fail "referência OVN ausente: ${MGC_OVN_SRC}/tests/multinode.at"
  [[ -f "${MGC_OVN_SRC}/tests/multinode-bgp-macros.at" ]] \
    || fail "referência OVN ausente: ${MGC_OVN_SRC}/tests/multinode-bgp-macros.at"
  [[ "$(git -C "${MGC_OVN_SRC}" rev-parse HEAD 2>/dev/null || true)" == "${OVN_COMMIT}" ]] \
    || fail "fonte OVN não está no commit fixado ${OVN_COMMIT}"
  grep -Fq 'AT_SETUP([ovn multinode bgp L3 EVPN])' \
    "${MGC_OVN_SRC}/tests/multinode.at" \
    || fail 'teste oficial L3 EVPN não encontrado na fonte fixada'
  grep -Fq 'm_setup_host_frr_vrf' \
    "${MGC_OVN_SRC}/tests/multinode-bgp-macros.at" \
    || fail 'macro oficial de VRF FRR não encontrada na fonte fixada'
  grep -Fq 'advertise ipv4 unicast' \
    "${MGC_OVN_SRC}/tests/multinode-bgp-macros.at" \
    || fail 'macro oficial de Type 5 não encontrada na fonte fixada'
  grep -Fq "dstport=\$((60000 + \$vni))" \
    "${MGC_OVN_SRC}/tests/multinode-bgp-macros.at" \
    || fail 'regra de dstport auxiliar não encontrada na fonte fixada'
}

assert_p003_stopped() {
  local state
  state="$(docker inspect -f '{{.State.Status}}' p003-os 2>/dev/null || true)"
  [[ "${state}" == exited ]] \
    || fail "p003-os precisa estar exited (estado=${state:-ausente})"
}

assert_mgc_owned_running() {
  local name state
  mgc_assert_no_extra_ovn_containers
  mgc_assert_cluster_ownership
  mgc_assert_bridges_owned
  mgc_assert_client_ownership "${MG_CLIENT_NAME}"
  [[ "$(mgc_cluster_count running)" -eq 5 ]] \
    || fail 'MGC não tem exatamente 5 containers OVN rodando'
  [[ "$(mgc_count_named "${MG_CLIENT_NAME}" running)" -eq 1 ]] \
    || fail 'cliente canônico MGC não está rodando'
  for name in "${M03_CENTRAL}" "${MG_GATEWAY_1}" "${MG_GATEWAY_2}" \
    "${MG_CHASSIS_1}" "${MG_CHASSIS_2}" "${MG_CLIENT_NAME}"; do
    state="$(docker inspect -f '{{.State.Status}}' "${name}" 2>/dev/null || true)"
    [[ "${state}" == running ]] || fail "${name} não está running"
  done
  [[ "$(awk '/^MemAvailable:/{print int($2 / 1024 / 1024)}' /proc/meminfo)" -ge 4 ]] \
    || fail 'MemAvailable abaixo de 4 GiB'
  [[ "$(mgc_images_provenance_matches && echo yes || echo no)" == yes ]] \
    || fail "provenance das imagens OVN não corresponde às fontes fixadas"
  [[ "$(mgc_image_id "${M03_IMAGE}")" == "${M03_IMAGE_DIGEST}" ]] \
    || fail "digest da imagem do peer não é ${M03_IMAGE_DIGEST}"
}

assert_baseline_network() {
  local lrp_options lrp_mac router_options ls_options route host_addrs container_addrs chassis_ok=0 port_mapping
  lrp_options="$(docker exec "${M03_CENTRAL}" ovn-nbctl \
    get logical_router_port "${M03_LRP}" options 2>/dev/null || true)"
  M03_OLD_LRP_OPTIONS="${lrp_options}"
  [[ "${lrp_options}" != *dynamic-routing-maintain-vrf* ]] \
    || fail "${M03_LRP} já tem dynamic-routing-maintain-vrf; recusar adoção"
  [[ "${lrp_options}" != *"${M03_LRP_REDISTRIBUTE_KEY}"* ]] \
    || fail "${M03_LRP} já tem ${M03_LRP_REDISTRIBUTE_KEY}; recusar adoção"
  [[ "${lrp_options}" != *dynamic-routing-port-name* ]] \
    || fail "${M03_LRP} já tem filtro de porta de retorno; recusar adoção"
  port_mapping="$(mgc_m03_chassis_port_mapping)" \
    || fail "não foi possível ler mapping de roteamento em ${M03_CHASSIS}"
  [[ -z "$port_mapping" ]] \
    || fail "${M03_CHASSIS} já tem dynamic-routing-port-mapping: $port_mapping"
  lrp_mac="$(docker exec "${M03_CENTRAL}" ovn-nbctl \
    get logical_router_port "${M03_LRP}" mac 2>/dev/null | tr -d '"' || true)"
  [[ "${lrp_mac}" == "${M03_TENANT_BR_MAC}" ]] \
    || fail "MAC da bridge EVPN deve coincidir com ${M03_LRP}: ${lrp_mac}"

  router_options="$(docker exec "${M03_CENTRAL}" ovn-nbctl \
    get logical_router "${M03_TENANT_LR}" options 2>/dev/null || true)"
  if grep -Eq '(^|[[:space:],{}])chassis=ovn-chassis-1([[:space:],{}]|$)' \
    <<<"${router_options}" \
    || grep -Eq '(^|[[:space:],{}])chassis="ovn-chassis-1"([[:space:],{}]|$)' \
      <<<"${router_options}"; then
    chassis_ok=1
  fi
  [[ "${router_options}" == *'dynamic-routing-vrf-id="300"'* \
    && "${router_options}" == *'dynamic-routing-redistribute="connected,static"'* \
    && "${chassis_ok}" -eq 1 ]] \
    || fail "LR do tenant não está fixado em ovn-chassis-1/table300 com redistribuição connected,static: ${router_options}"
  ls_options="$(docker exec "${M03_CENTRAL}" ovn-nbctl \
    get logical_switch "${M03_TENANT_LS}" other_config 2>/dev/null || true)"
  grep -Eq 'dynamic-routing-vni="?50100"?' <<<"${ls_options}" \
    || fail "LS tenant sem dynamic-routing-vni=50100: ${ls_options}"
  grep -Eq 'dynamic-routing-bridge-ifname="?br-evpn-tenant"?' <<<"${ls_options}" \
    || fail "LS tenant sem bridge EVPN esperada: ${ls_options}"
  grep -Eq 'dynamic-routing-vxlan-ifname="?vxlan-tenant"?' <<<"${ls_options}" \
    || fail "LS tenant sem VXLAN esperada: ${ls_options}"
  grep -Eq 'dynamic-routing-advertise-ifname="?evpn-tenant"?' <<<"${ls_options}" \
    || fail "LS tenant sem interface advertise esperada: ${ls_options}"

  [[ -z "$(ip -4 -o addr show dev br-ovn 2>/dev/null || true)" ]] \
    || fail 'br-ovn do host tem endereço L3 inesperado'
  host_addrs="$(ip -4 -o addr show 2>/dev/null || true)"
  exact_ip_present "${M03_PEER_IP}" "${host_addrs}" \
    && fail "IP ${M03_PEER_IP} já existe no host"
  for name in "${M03_CENTRAL}" "${MG_GATEWAY_1}" "${MG_GATEWAY_2}" \
    "${MG_CHASSIS_1}" "${MG_CHASSIS_2}" "${MG_CLIENT_NAME}"; do
    container_addrs="$(docker exec "${name}" ip -4 -o addr show 2>/dev/null || true)"
    exact_ip_present "${M03_PEER_IP}" "${container_addrs}" \
      && fail "IP ${M03_PEER_IP} já existe em ${name}"
  done
  route="$(docker exec "${M03_CHASSIS}" ip route get "${M03_PEER_IP}" 2>/dev/null || true)"
  [[ "${route}" == *'dev eth1'* ]] \
    || fail "underlay para ${M03_PEER_IP} não usa eth1 em ${M03_CHASSIS}: ${route}"

  M03_OLD_CLIENT_PORT_1="$(mgc_ovs_port "${MG_CLIENT_NAME}" eth1 || true)"
  M03_OLD_CLIENT_PORT_2="$(mgc_ovs_port "${MG_CLIENT_NAME}" eth2 || true)"
  [[ -n "${M03_OLD_CLIENT_PORT_1}" && -n "${M03_OLD_CLIENT_PORT_2}" ]] \
    || fail 'portas legadas eth1/eth2 do cliente não foram identificadas'
  [[ "$(ovs-vsctl port-to-br "${M03_OLD_CLIENT_PORT_1}" 2>/dev/null || true)" == br-ovn-ext \
    && "$(ovs-vsctl port-to-br "${M03_OLD_CLIENT_PORT_2}" 2>/dev/null || true)" == br-ovn-ext ]] \
    || fail 'portas legadas do cliente não estão em br-ovn-ext'
  [[ "$(ovs-vsctl get Port "${M03_OLD_CLIENT_PORT_1}" tag 2>/dev/null || true)" == 100 \
    && "$(ovs-vsctl get Port "${M03_OLD_CLIENT_PORT_2}" tag 2>/dev/null || true)" == 200 ]] \
    || fail 'VLANs legadas do cliente não são 100/200'
  [[ -z "$(mgc_ovs_port "${M03_PEER}" eth1 || true)" ]] \
    || fail "porta OVS residual do peer ${M03_PEER} já existe"

  for link in "${M03_TENANT_BR}" "${M03_TENANT_VXLAN}" \
    "${M03_TENANT_ADVERTISE}" "${M03_TENANT_VRF}"; do
    docker exec "${M03_CHASSIS}" ip link show "${link}" >/dev/null 2>&1 \
      && fail "dispositivo ${link} já existe em ${M03_CHASSIS}"
  done
  docker exec "${M03_CHASSIS}" ip link show vxlan_sys_4789 >/dev/null 2>&1 \
    || fail 'vxlan_sys_4789 não existe no chassis'
  docker exec "${M03_CHASSIS}" ip link show "${M03_TENANT_TAP}" >/dev/null 2>&1 \
    || fail "tap do tenant ${M03_TENANT_TAP} não existe no chassis"
  for path in /etc/frr/m03 /run/frr/m03; do
    docker exec "${M03_CHASSIS}" test ! -e "${path}" \
      || fail "estado FRR M03 residual no chassis: ${path}"
  done
  for daemon in zebra bgpd staticd; do
    [[ -z "$(docker exec "${M03_CHASSIS}" pidof "${daemon}" 2>/dev/null || true)" ]] \
      || fail "daemon FRR ${daemon} já roda no chassis; recusar mistura de pathspaces"
  done
  ovs-vsctl br-exists br-ovn >/dev/null 2>&1 \
    || fail 'br-ovn do MGC está ausente'
}

assert_no_peer_name() {
  [[ ! -e "$M03_MARKER_FILE" ]] \
    || fail "marker M03 residual presente; exigir mgc down/cleanup antes de nova execução"
  [[ "$(mgc_count_named "${M03_PEER}")" -eq 0 ]] \
    || fail "container ${M03_PEER} já existe; não adotar recurso"
  [[ "$(docker ps -a --format '{{.Names}}' | awk -v n="${M03_PEER}" '$0 == n {print}')" == '' ]] \
    || fail "nome Docker ${M03_PEER} ainda está ocupado"
}

preflight() {
  say 'preflight somente leitura'
  assert_preflight_receipt
  assert_static_inputs
  assert_p003_stopped
  assert_mgc_owned_running
  M03_OWNER_TOKEN="$(state_get "${LAB_NAME}" owner_token 2>/dev/null || true)"
  [[ -n "${M03_OWNER_TOKEN}" ]] || fail 'token de ownership MGC ausente'
  assert_no_peer_name
  assert_baseline_network
  check_historical_canaries pre \
    || fail 'UIDs/canários históricos ao vivo não passaram 10/10'
  say 'preflight MGC/ownership/capacidade/provenance/ausência OK'
}

print_plan() {
  cat <<EOF
M03 DRY-RUN plano (nenhuma evidência ou mutação será criada)
  fonte OVN: ${MGC_OVN_SRC} @ ${OVN_COMMIT}
  tenant: ${M03_TENANT_LR}/${M03_TENANT_LS} -> ${M03_CHASSIS}, VRF ${M03_TENANT_VRF}, tabela ${M03_TENANT_TABLE}
  NB temporário: ${M03_LRP} options:dynamic-routing-maintain-vrf=true
  filtro temporário de retorno: ${M03_LRP} options:dynamic-routing-port-name=m03-evpn-<run>, ${M03_CHASSIS} OVS external_ids:dynamic-routing-port-mapping=m03-evpn-<run>=${M03_TENANT_BR}
  chassis: ${M03_TENANT_BR}, ${M03_TENANT_VXLAN} VNI ${M03_VNI} dev vxlan_sys_4789 dstport ${M03_AUX_DSTPORT}, ${M03_TENANT_ADVERTISE}
  FRR chassis: AS65100, pathspace m03, Type5 redistribute kernel/connected + advertise ipv4 unicast
  peer: ${M03_PEER} (${M03_IMAGE}), AS65200, ${M03_PEER_IP}/16 em br-ovn sem VLAN, VRF ${M03_CLIENT_VRF}/VNI ${M03_VNI}
  nomes Linux: VRF/link peer e tenant limitados a 15 caracteres (IFNAMSIZ-1)
  source peer: ${M03_PEER_SOURCE}; alvo: ${M03_TENANT_CIDR} (${M03_TENANT_IP})
  prova: uma Learned_Route de retorno no Port_Binding tenant, RIB EVPN Type5 exacta + VNI, rota VRF, VTEP remoto OVN, ping 30/30, UDP/4789, zero tráfego nas VLANs 100/200
  controle negativo causal: localizar o Port_Binding de ${M03_LRP} por nome, escopar prefixo por UUID/datapath e preservar as duas rotas colaterais
  negativo: confirmar withdraw em SB, VRF tenant, Type5 e FIB/route-get do peer; BGP Established e VTEP ativo; probe ICMP limitado falha
  recuperação: remover somente options:${M03_LRP_REDISTRIBUTE_KEY} após validar identidade/options; confirmar rota SB, Type5/FIB/route-get e ping 3/3
  rollback: remover a chave temporária no trap, validar filtro antes do teardown, parar FRR pathspaces, restaurar filtro, remover somente IDs/dispositivos criados, labctl mgc up/verify
  gate de aceitação: controle causal e limpeza precisam passar; chave e VNI devem voltar ao estado inicial
EOF
}

prepare_evidence() {
  local parent
  M03_RUN_TOKEN="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  M03_EVIDENCE_DIR="${M03_EVIDENCE_DIR:-/var/tmp/labctl/mgc/m03-${M03_RUN_TOKEN}}"
  [[ ! -e "${M03_EVIDENCE_DIR}" ]] \
    || fail "diretório de evidência já existe: ${M03_EVIDENCE_DIR}"
  parent="$(dirname "${M03_EVIDENCE_DIR}")"
  mkdir -p "${parent}"
  mkdir -m 700 "${M03_EVIDENCE_DIR}"
  cp -- "${M03_PREFLIGHT_RECEIPT}" "${M03_EVIDENCE_DIR}/preflight-receipt.txt"
  {
    echo "run=${M03_RUN_TOKEN}"
    echo "source=${MGC_OVN_SRC}@${OVN_COMMIT}"
    echo "peer=${M03_PEER} image=${M03_IMAGE}"
    echo "tenant=${M03_TENANT_CIDR} vni=${M03_VNI}"
    echo "owner_token=${M03_OWNER_TOKEN}"
    echo "k01_uid_pre=${M03_K01_UID_PRE}"
    echo "p003_gw_uid_pre=${M03_P003_UID_PRE}"
    echo "k01_canary_pre=${M03_K01_CANARY_PRE}"
    echo "p003_gw_canary_pre=${M03_P003_CANARY_PRE}"
  } >"${M03_EVIDENCE_DIR}/run.txt"
}

prepare_phase_evidence() {
  local parent mode
  [[ -n "${M03_PREFLIGHT_RECEIPT}" ]] \
    || fail 'fase M03 sem M03_PREFLIGHT_RECEIPT'
  M03_RUN_TOKEN="${M03_RUN_TOKEN:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
  [[ "${M03_RUN_TOKEN}" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] \
    || fail 'run token M03 fornecido pela fase não tem formato interno válido'
  M03_EVIDENCE_DIR="${M03_EVIDENCE_DIR:-${EVIDENCE_DIR:-/var/tmp/labctl/mgc/m03-${M03_RUN_TOKEN}}}"
  parent="$(dirname "${M03_EVIDENCE_DIR}")"
  if [[ -e "${M03_EVIDENCE_DIR}" ]]; then
    [[ -d "${M03_EVIDENCE_DIR}" && -O "${M03_EVIDENCE_DIR}" \
      && ! -g "${M03_EVIDENCE_DIR}" ]] \
      || fail "diretório de evidência da fase não é root-only: ${M03_EVIDENCE_DIR}"
    mode="$(stat -c '%a' "${M03_EVIDENCE_DIR}" 2>/dev/null || true)"
    [[ "${mode}" == 700 ]] \
      || fail "diretório de evidência da fase precisa de modo 700: ${M03_EVIDENCE_DIR}"
  else
    mkdir -p "${parent}"
    mkdir -m 700 "${M03_EVIDENCE_DIR}"
  fi
  if [[ -e "${M03_EVIDENCE_DIR}/preflight-receipt.txt" ]]; then
    cmp -s "${M03_PREFLIGHT_RECEIPT}" \
      "${M03_EVIDENCE_DIR}/preflight-receipt.txt" \
      || fail 'recibo de preflight existente diverge do recibo fornecido'
  else
    cp -- "${M03_PREFLIGHT_RECEIPT}" \
      "${M03_EVIDENCE_DIR}/preflight-receipt.txt"
  fi
  if [[ -f "${M03_EVIDENCE_DIR}/run.txt" ]]; then
    grep -Fqx "run=${M03_RUN_TOKEN}" "${M03_EVIDENCE_DIR}/run.txt" \
      || fail 'run.txt existente diverge do token M03 desta fase'
    grep -Fqx "owner_token=${M03_OWNER_TOKEN}" \
      "${M03_EVIDENCE_DIR}/run.txt" \
      || fail 'run.txt existente diverge do token MGC desta fase'
    export M03_EVIDENCE_DIR M03_RUN_TOKEN
    return 0
  fi
  {
    echo "run=${M03_RUN_TOKEN}"
    echo "source=${MGC_OVN_SRC}@${OVN_COMMIT}"
    echo "peer=${M03_PEER} image=${M03_IMAGE}"
    echo "tenant=${M03_TENANT_CIDR} vni=${M03_VNI}"
    echo "owner_token=${M03_OWNER_TOKEN}"
    echo "k01_uid_pre=${M03_K01_UID_PRE}"
    echo "p003_gw_uid_pre=${M03_P003_UID_PRE}"
    echo "k01_canary_pre=${M03_K01_CANARY_PRE}"
    echo "p003_gw_canary_pre=${M03_P003_CANARY_PRE}"
  } >"${M03_EVIDENCE_DIR}/run.txt"
  export M03_EVIDENCE_DIR M03_RUN_TOKEN
}

persist_m03_marker() {
  local temp mode
  M03_MARKER_TOKEN="labctl-m03-$M03_RUN_TOKEN"
  [[ ! -e "$M03_MARKER_FILE" ]] \
    || fail "marker M03 já existe: $M03_MARKER_FILE"
  if [[ -e "$M03_MARKER_DIR" ]]; then
    [[ -d "$M03_MARKER_DIR" && -O "$M03_MARKER_DIR" \
      && ! -g "$M03_MARKER_DIR" ]] \
      || fail "diretório do marker M03 não é root-only: $M03_MARKER_DIR"
    mode="$(stat -c '%a' "$M03_MARKER_DIR" 2>/dev/null || true)"
    [[ "$mode" == 700 ]] \
      || fail "diretório do marker M03 precisa de modo 700: $M03_MARKER_DIR"
  else
    mkdir -p "$M03_MARKER_DIR" \
      || fail "não foi possível criar diretório do marker M03"
    chmod 700 "$M03_MARKER_DIR" \
      || fail "não foi possível proteger diretório do marker M03"
  fi
  temp="$M03_MARKER_FILE.tmp.$$"
  umask 077
  if ! {
    printf '%s\n' \
      version=2 \
      "token=$M03_MARKER_TOKEN" \
      "run_token=$M03_RUN_TOKEN" \
      "central=$M03_CENTRAL" \
      "lrp=$M03_LRP" \
      "tenant_vrf=$M03_TENANT_VRF" \
      intent=maintain-vrf \
      baseline_lrp_maintain_vrf=absent \
      baseline_lrp_port_name=absent \
      baseline_chassis_port_mapping=absent \
      "baseline_ls_dynamic_routing_vni=$M03_VNI" \
      "resource=chassis:$M03_TENANT_BR:bridge" \
      "resource=chassis:$M03_TENANT_VXLAN:vxlan" \
      "resource=chassis:$M03_TENANT_ADVERTISE:dummy" \
      "resource=peer:$M03_CLIENT_VRF:vrf" \
      "resource=peer:$M03_CLIENT_BR:bridge" \
      "resource=peer:$M03_CLIENT_VXLAN:vxlan" \
      "resource=peer:$M03_CLIENT_ADVERTISE:dummy"
  } >"$temp"; then
    rm -f -- "$temp"
    fail "não foi possível gravar marker M03 temporário"
  fi
  chmod 600 "$temp" \
    || { rm -f -- "$temp"; fail "não foi possível proteger marker M03 temporário"; }
  mv -f -- "$temp" "$M03_MARKER_FILE" \
    || { rm -f -- "$temp"; fail "não foi possível publicar marker M03"; }
}

client_vtysh() {
  docker exec "${M03_PEER}" vtysh "$@"
}

chassis_vtysh() {
  docker exec "${M03_CHASSIS}" vtysh --vty_socket /run/frr/m03 "$@"
}

wait_for_bgp() {
  local attempt=0 chassis_state client_state
  while (( attempt < 60 )); do
    attempt=$((attempt + 1))
    chassis_state="$(chassis_vtysh -c "show bgp neighbors ${M03_PEER_IP}" 2>/dev/null || true)"
    client_state="$(client_vtysh -c "show bgp neighbors ${M03_CHASSIS_IP}" 2>/dev/null || true)"
    if [[ "${chassis_state}" == *'BGP state = Established'* \
      && "${client_state}" == *'BGP state = Established'* ]]; then
      printf '%s\n' "${chassis_state}" >"${M03_EVIDENCE_DIR}/bgp-chassis.txt"
      printf '%s\n' "${client_state}" >"${M03_EVIDENCE_DIR}/bgp-client.txt"
      return 0
    fi
    sleep 2
  done
  printf '%s\n' "${chassis_state}" >"${M03_EVIDENCE_DIR}/bgp-chassis.txt"
  printf '%s\n' "${client_state}" >"${M03_EVIDENCE_DIR}/bgp-client.txt"
  fail 'sessão BGP EVPN não chegou a Established nos dois lados'
}

create_owned_link() {
  local node="$1" link="$2"; shift 2
  run docker exec "${node}" sh -c '
    set -euo pipefail
    link="$1"
    alias_name="$2"
    shift 2
    created=0
    cleanup_link() {
      if [ "${created}" -eq 1 ]; then
        ip link del "${link}" 2>/dev/null || true
      fi
    }
    trap cleanup_link EXIT
    ip link add "${link}" "$@"
    created=1
    ip link set "${link}" alias "${alias_name}"
    trap - EXIT
  ' sh "${link}" "labctl-m03-${M03_RUN_TOKEN}" "$@"
}

create_chassis_links() {
  M03_CHASSIS_LINKS_CREATED=1
  # Set each guard before the mutating helper.  If a signal or a partial
  # command interrupts the helper, cleanup still checks this resource's alias
  # before attempting removal.
  M03_CHASSIS_BR_CREATED=1
  M03_CHASSIS_BR_ALIAS=1
  create_owned_link "${M03_CHASSIS}" "${M03_TENANT_BR}" type bridge
  run docker exec "${M03_CHASSIS}" ip link set "${M03_TENANT_BR}" \
    master "${M03_TENANT_VRF}"
  run docker exec "${M03_CHASSIS}" ip link set dev "${M03_TENANT_BR}" \
    addrgenmode none
  run docker exec "${M03_CHASSIS}" ip link set dev "${M03_TENANT_BR}" \
    address "${M03_TENANT_BR_MAC}"
  run docker exec "${M03_CHASSIS}" ip link set dev "${M03_TENANT_BR}" up

  M03_TENANT_VXLAN_CREATED=1
  M03_TENANT_VXLAN_ALIAS=1
  create_owned_link "${M03_CHASSIS}" "${M03_TENANT_VXLAN}" \
    type vxlan dev vxlan_sys_4789 id "${M03_VNI}" dstport "${M03_AUX_DSTPORT}" \
    local "${MG_CHASSIS_1_UNDERLAY}" nolearning
  run docker exec "${M03_CHASSIS}" ip link set "${M03_TENANT_VXLAN}" \
    master "${M03_TENANT_BR}"
  run docker exec "${M03_CHASSIS}" ip link set dev "${M03_TENANT_VXLAN}" up

  M03_TENANT_ADVERTISE_CREATED=1
  M03_TENANT_ADVERTISE_ALIAS=1
  create_owned_link "${M03_CHASSIS}" "${M03_TENANT_ADVERTISE}" type dummy
  run docker exec "${M03_CHASSIS}" ip link set "${M03_TENANT_ADVERTISE}" \
    master "${M03_TENANT_BR}"
  run docker exec "${M03_CHASSIS}" ip link set dev "${M03_TENANT_ADVERTISE}" up
}

set_return_route_filter() {
  local port_name expected lrp_value mapping_value
  port_name="m03-evpn-${M03_RUN_TOKEN}"
  expected="${port_name}=${M03_TENANT_BR}"
  mgc_m03_marker_valid \
    || fail 'marker M03 inválido antes de configurar filtro de retorno'
  grep -Fqx 'version=2' "$M03_MARKER_FILE" \
    || fail 'marker M03 não declara baseline do filtro de retorno'
  lrp_value="$(mgc_m03_lrp_port_name)" \
    || fail 'não foi possível ler dynamic-routing-port-name antes de configurar o filtro'
  mapping_value="$(mgc_m03_chassis_port_mapping)" \
    || fail 'não foi possível ler dynamic-routing-port-mapping antes de configurar o filtro'
  [[ -z "$lrp_value" && -z "$mapping_value" ]] \
    || fail 'filtro de retorno apareceu após preflight; não sobrescrever'
  run docker exec "$M03_CHASSIS" ovs-vsctl set Open_vSwitch . \
    "external_ids:dynamic-routing-port-mapping=${expected}"
  [[ "$(mgc_m03_chassis_port_mapping)" == "$expected" ]] \
    || fail 'mapping M03 não foi instalado como esperado'
  run docker exec "$M03_CENTRAL" ovn-nbctl --wait=sb set \
    logical_router_port "$M03_LRP" \
    "options:dynamic-routing-port-name=${port_name}"
  [[ "$(mgc_m03_lrp_port_name)" == "$port_name" ]] \
    || fail 'dynamic-routing-port-name M03 não foi instalado como esperado'
  printf 'port_name=%s\nport_mapping=%s\n' "$port_name" "$expected" \
    >"${M03_EVIDENCE_DIR}/return-route-filter.txt"
}

create_peer_container() {
  [[ -n "${M03_OWNER_TOKEN}" ]] || fail 'token de ownership MGC ausente'
  M03_CLIENT_CREATED=1
  run docker run -d --name "${M03_PEER}" --network none --privileged \
    --label "labctl.mgc.owner=${M03_OWNER_TOKEN}" \
    --label "${M03_OWNER_LABEL}=labctl-m03-${M03_RUN_TOKEN}" \
    --entrypoint /bin/sh "${M03_IMAGE}" -c 'while :; do sleep 3600; done'
  M03_CLIENT_ID="$(docker inspect -f '{{.Id}}' "${M03_PEER}")"
  [[ -n "${M03_CLIENT_ID}" ]] || fail 'ID do peer não foi obtido após docker run'
  M03_CLIENT_PORT_CREATED=1
  local add_rc=0 add_output port tag bridge addr
  if add_output="$(env RUNC_CMD="${RUNC_CMD}" "${MGC_FAKE_MN}/ovs-runc" \
    add-port br-ovn eth1 "${M03_PEER}" "--ipaddress=${M03_PEER_CIDR}" 2>&1)"; then
    add_rc=0
  else
    add_rc=$?
  fi
  printf '%s\n' "${add_output}" >"${M03_EVIDENCE_DIR}/peer-ovs-add-port.txt"
  # Inspect the OVS identity even after a failed add-port: ovs-runc can leave
  # a partial Port/Interface behind, and cleanup may remove it only when every
  # recorded UUID and host interface still proves this run owns it.
  port="$(mgc_ovs_port "${M03_PEER}" eth1 || true)"
  [[ -n "${port}" ]] || fail "ovs-runc não deixou uma porta identificável após add-port (rc=${add_rc})"
  M03_CLIENT_PORT_NAME="${port}"
  M03_CLIENT_PORT_UUID="$(ovs-vsctl get Port "${port}" _uuid 2>/dev/null \
    | tr -d '"' || true)"
  M03_CLIENT_INTERFACE_UUID="$(ovs-vsctl get Port "${port}" interfaces 2>/dev/null \
    | tr -d '[]"' || true)"
  M03_CLIENT_HOST_IFACE="$(ovs-vsctl get Interface "${M03_CLIENT_INTERFACE_UUID}" name \
    2>/dev/null | tr -d '"' || true)"
  [[ -n "${M03_CLIENT_PORT_UUID}" && -n "${M03_CLIENT_INTERFACE_UUID}" \
    && -n "${M03_CLIENT_HOST_IFACE}" ]] \
    || fail "identidade OVS parcial não pôde ser registrada (rc=${add_rc})"
  run ovs-vsctl set Interface "${M03_CLIENT_HOST_IFACE}" \
    "external_ids:labctl-m03-owner=labctl-m03-${M03_RUN_TOKEN}"
  [[ "${add_rc}" -eq 0 ]] \
    || fail "ovs-runc add-port falhou após criar identidade ${M03_CLIENT_PORT_NAME}"
  run docker exec "${M03_PEER}" ip link set dev eth1 up
  bridge="$(ovs-vsctl port-to-br "${port}" 2>/dev/null || true)"
  tag="$(ovs-vsctl get Port "${port}" tag 2>/dev/null || true)"
  addr="$(docker exec "${M03_PEER}" ip -4 -o addr show dev eth1 2>/dev/null || true)"
  [[ -n "${port}" && "${bridge}" == br-ovn && "${tag}" == '[]' ]] \
    || fail "porta temporária não ficou sem VLAN em br-ovn: port=${port} bridge=${bridge} tag=${tag}"
  {
    echo "port=${M03_CLIENT_PORT_NAME}"
    echo "port_uuid=${M03_CLIENT_PORT_UUID}"
    echo "interface_uuid=${M03_CLIENT_INTERFACE_UUID}"
    echo "host_interface=${M03_CLIENT_HOST_IFACE}"
    echo "owner=labctl-m03-${M03_RUN_TOKEN}"
  } >"${M03_EVIDENCE_DIR}/peer-ovs-port.txt"
  exact_ip_present "${M03_PEER_IP}" "${addr}" \
    || fail "${M03_PEER_IP} não apareceu em ${M03_PEER}:eth1"
}

create_peer_links() {
  M03_CLIENT_LINKS_CREATED=1
  M03_CLIENT_VRF_CREATED=1
  M03_CLIENT_VRF_ALIAS=1
  create_owned_link "${M03_PEER}" "${M03_CLIENT_VRF}" \
    type vrf table "${M03_CLIENT_TABLE}"
  run docker exec "${M03_PEER}" ip link set dev "${M03_CLIENT_VRF}" up

  M03_CLIENT_BR_CREATED=1
  M03_CLIENT_BR_ALIAS=1
  create_owned_link "${M03_PEER}" "${M03_CLIENT_BR}" type bridge
  run docker exec "${M03_PEER}" ip link set "${M03_CLIENT_BR}" \
    master "${M03_CLIENT_VRF}"
  run docker exec "${M03_PEER}" ip link set dev "${M03_CLIENT_BR}" \
    addrgenmode none
  run docker exec "${M03_PEER}" ip link set dev "${M03_CLIENT_BR}" \
    address "${M03_CLIENT_BR_MAC}"
  run docker exec "${M03_PEER}" ip link set dev "${M03_CLIENT_BR}" up

  M03_CLIENT_VXLAN_CREATED=1
  M03_CLIENT_VXLAN_ALIAS=1
  create_owned_link "${M03_PEER}" "${M03_CLIENT_VXLAN}" \
    type vxlan dev eth1 id "${M03_VNI}" dstport 4789 local "${M03_PEER_IP}" nolearning
  run docker exec "${M03_PEER}" ip link set "${M03_CLIENT_VXLAN}" \
    master "${M03_CLIENT_BR}"
  run docker exec "${M03_PEER}" ip link set dev "${M03_CLIENT_VXLAN}" up

  M03_CLIENT_ADVERTISE_CREATED=1
  M03_CLIENT_ADVERTISE_ALIAS=1
  create_owned_link "${M03_PEER}" "${M03_CLIENT_ADVERTISE}" type dummy
  run docker exec "${M03_PEER}" ip link set "${M03_CLIENT_ADVERTISE}" \
    master "${M03_CLIENT_BR}"
  run docker exec "${M03_PEER}" ip link set dev "${M03_CLIENT_ADVERTISE}" up
  run docker exec "${M03_PEER}" ip addr replace \
    "${M03_PEER_SOURCE}/32" dev "${M03_CLIENT_BR}"
}

start_chassis_frr() {
  M03_CHASSIS_FRR_STARTED=1
  run docker exec "${M03_CHASSIS}" mkdir -p /etc/frr/m03 /run/frr/m03
  run docker cp "${M03_CHASSIS_CONF}" "${M03_CHASSIS}:/etc/frr/m03/frr.conf"
  run docker exec "${M03_CHASSIS}" bash -c '
    set -euo pipefail
    printf "%s\n" \
      zebra=yes bgpd=yes staticd=yes bfdd=no ospfd=no ospf6d=no ripd=no \
      ripngd=no isisd=no pimd=no pim6d=no ldpd=no nhrpd=no eigrpd=no \
      sharpd=no pbrd=no fabricd=no vrrpd=no vtysh_enable=yes \
      > /etc/frr/m03/daemons
    : > /etc/frr/m03/vtysh.conf
    if getent passwd frr >/dev/null 2>&1; then
      chown -R frr:frr /etc/frr/m03 /run/frr/m03
    fi
    init=""
    for candidate in /usr/libexec/frr/frrinit.sh /usr/lib/frr/frrinit.sh; do
      if [ -x "${candidate}" ]; then init="${candidate}"; break; fi
    done
    [ -n "${init}" ] || { echo "frrinit.sh ausente" >&2; exit 1; }
  '
  run docker exec "${M03_CHASSIS}" vtysh -C -f /etc/frr/m03/frr.conf
  # Set the guard before invoking the init script so a partial start is also
  # stopped by the EXIT trap.
  run docker exec "${M03_CHASSIS}" bash -c '
    set -euo pipefail
    init=""
    for candidate in /usr/libexec/frr/frrinit.sh /usr/lib/frr/frrinit.sh; do
      if [ -x "${candidate}" ]; then init="${candidate}"; break; fi
    done
    [ -n "${init}" ] || { echo "frrinit.sh ausente" >&2; exit 1; }
    "${init}" start m03
  '
}

start_client_frr() {
  M03_CLIENT_FRR_STARTED=1
  run docker cp "${M03_CLIENT_CONF}" "${M03_PEER}:/etc/frr/frr.conf"
  run docker exec "${M03_PEER}" bash -c '
    set -euo pipefail
    mkdir -p /run/frr
    printf "%s\n" \
      zebra=yes bgpd=yes staticd=yes bfdd=no ospfd=no ospf6d=no ripd=no \
      ripngd=no isisd=no pimd=no pim6d=no ldpd=no nhrpd=no eigrpd=no \
      sharpd=no pbrd=no fabricd=no vrrpd=no vtysh_enable=yes \
      > /etc/frr/daemons
    : > /etc/frr/vtysh.conf
    if getent passwd frr >/dev/null 2>&1; then
      chown frr:frr /etc/frr/frr.conf /etc/frr/daemons /etc/frr/vtysh.conf
      chown -R frr:frr /run/frr
    fi
    init=""
    for candidate in /usr/libexec/frr/frrinit.sh /usr/lib/frr/frrinit.sh; do
      if [ -x "${candidate}" ]; then init="${candidate}"; break; fi
    done
    [ -n "${init}" ] || { echo "frrinit.sh ausente" >&2; exit 1; }
  '
  run docker exec "${M03_PEER}" vtysh -C -f /etc/frr/frr.conf
  run docker exec "${M03_PEER}" bash -c '
    set -euo pipefail
    init=""
    for candidate in /usr/libexec/frr/frrinit.sh /usr/lib/frr/frrinit.sh; do
      if [ -x "${candidate}" ]; then init="${candidate}"; break; fi
    done
    [ -n "${init}" ] || { echo "frrinit.sh ausente" >&2; exit 1; }
    "${init}" start
  '
}

set_lrp_maintain_vrf() {
  M03_LRP_CHANGED=1
  run docker exec "${M03_CENTRAL}" ovn-nbctl --wait=sb set \
    logical_router_port "${M03_LRP}" options:dynamic-routing-maintain-vrf=true
  local attempt=0
  while (( attempt < 60 )); do
    attempt=$((attempt + 1))
    if docker exec "${M03_CHASSIS}" ip link show "${M03_TENANT_VRF}" \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  fail "VRF ${M03_TENANT_VRF} não apareceu após ${M03_LRP}=true"
}

collect_route_evidence() {
  local phase="${1:-positive}" prefix
  local type5 vrf_route kernel_route vni_route remote_vtep
  local tenant_route peer_route peer_route_get tenant_route_get type5_count
  prefix="${M03_EVIDENCE_DIR}/${phase}"
  if ! type5="$(client_vtysh -c \
    "show bgp l2vpn evpn route rd all prefix ${M03_TENANT_CIDR}" 2>&1)"; then
    fail 'CLI FRR Type5 falhou no peer'
  fi
  if ! vrf_route="$(client_vtysh -c \
    "show ip route vrf ${M03_CLIENT_VRF} ${M03_TENANT_CIDR}" 2>&1)"; then
    fail 'CLI FRR VRF falhou no peer'
  fi
  if ! kernel_route="$(docker exec "${M03_PEER}" ip route show table "${M03_CLIENT_TABLE}" \
    "${M03_TENANT_CIDR}" 2>&1)"; then
    fail 'FIB Linux do VRF externo não pôde ser consultada'
  fi
  if ! vni_route="$(client_vtysh -c "show evpn vni ${M03_VNI}" 2>&1)"; then
    fail 'CLI FRR VNI falhou no peer'
  fi
  if ! remote_vtep="$(docker exec "${M03_CHASSIS}" ovn-appctl \
    -t ovn-controller evpn/remote-vtep-list 2>&1)"; then
    fail 'ovn-appctl remote-vtep-list falhou no chassis'
  fi
  if ! tenant_route="$(docker exec "${M03_CHASSIS}" ip route show table "${M03_TENANT_TABLE}" \
    "${M03_TENANT_CIDR}" 2>&1)"; then
    fail 'FIB Linux do VRF tenant não pôde ser consultada'
  fi
  if ! peer_route="$(docker exec "${M03_CHASSIS}" ip route show table "${M03_TENANT_TABLE}" \
    "${M03_PEER_SOURCE}/32" 2>&1)"; then
    fail 'rota de retorno do peer não pôde ser consultada'
  fi
  if ! peer_route_get="$(docker exec "${M03_PEER}" ip route get \
    "${M03_TENANT_IP}" from "${M03_PEER_SOURCE}" vrf "${M03_CLIENT_VRF}" 2>&1)"; then
    fail 'route-get peer→tenant falhou'
  fi
  if ! tenant_route_get="$(docker exec "${M03_CHASSIS}" ip route get \
    "${M03_PEER_SOURCE}" vrf "${M03_TENANT_VRF}" 2>&1)"; then
    fail 'route-get tenant→peer falhou'
  fi
  printf '%s\n' "${type5}" >"${prefix}-type5-rib.txt"
  printf '%s\n' "${vrf_route}" >"${prefix}-client-vrf-route.txt"
  printf '%s\n' "${kernel_route}" >"${prefix}-client-kernel-route.txt"
  printf '%s\n' "${vni_route}" >"${prefix}-client-vni.txt"
  printf '%s\n' "${remote_vtep}" >"${prefix}-remote-vtep.txt"
  printf '%s\n' "${tenant_route}" >"${prefix}-tenant-vrf-route.txt"
  printf '%s\n' "${peer_route}" >"${prefix}-tenant-return-route.txt"
  printf '%s\n' "${peer_route_get}" >"${prefix}-peer-route-get.txt"
  printf '%s\n' "${tenant_route_get}" >"${prefix}-tenant-route-get.txt"

  type5_count="$(grep -Ec '^[[:space:]]+Route \[5\]:\[0\]:\[24\]:\[192\.168\.100\.0\] VNI [0-9]+' <<<"${type5}" || true)"
  [[ "${type5_count}" -eq 1 ]] \
    || fail "RIB externo não contém exatamente uma Type 5 para ${M03_TENANT_CIDR} (count=${type5_count})"
  [[ "${type5}" == *"VNI ${M03_VNI}"* && "${type5}" == *"${M03_CHASSIS_IP}"* ]] \
    || fail "RIB Type 5 sem VNI ${M03_VNI} e next-hop ${M03_CHASSIS_IP}"
  [[ "${vrf_route}" == *"${M03_TENANT_CIDR}"* \
    && "${vrf_route}" == *'Known via "bgp"'* ]] \
    || fail 'rota Type 5 não foi instalada no VRF do peer'
  [[ "${kernel_route}" == *"${M03_TENANT_CIDR}"* \
    && "${kernel_route}" == *'proto bgp'* ]] \
    || fail 'FIB Linux do VRF externo não contém rota BGP exata'
  [[ "${vni_route}" == *"VNI: ${M03_VNI}"* \
    && "${vni_route}" == *"Local Vtep Ip: ${M03_PEER_IP}"* \
    && "${vni_route}" == *'State: Up'* ]] \
    || fail "peer FRR não mostra VNI ${M03_VNI} ativo com VTEP local ${M03_PEER_IP}"
  [[ "${remote_vtep}" == *"IP: ${M03_PEER_IP}"* \
    && "${remote_vtep}" == *"port: 4789"* \
    && "${remote_vtep}" == *"vni: ${M03_VNI}"* ]] \
    || fail 'ovn-appctl não mostrou o VTEP remoto do peer'
  [[ "${tenant_route}" == *"blackhole ${M03_TENANT_CIDR} proto ovn"* ]] \
    || fail "VRF tenant/tabela ${M03_TENANT_TABLE} sem rota local OVN ${M03_TENANT_CIDR}"
  [[ "${peer_route}" == *"${M03_PEER_SOURCE}"* \
    && "${peer_route}" == *'proto bgp'* ]] \
    || fail 'retorno para 10.250.0.1 não apareceu na tabela tenant'
  [[ "${peer_route_get}" == *"${M03_TENANT_IP}"* \
    && "${peer_route_get}" == *"dev ${M03_CLIENT_BR}"* ]] \
    || fail 'route-get peer→tenant não usa a bridge EVPN com rota BGP'
  [[ "${tenant_route_get}" == *"${M03_PEER_SOURCE}"* \
    && "${tenant_route_get}" == *"dev ${M03_TENANT_BR}"* ]] \
    || fail 'route-get tenant→peer não usa a bridge EVPN do tenant'
}

route_evidence_retryable_failure() {
  local output="${1}"
  [[ "${output}" == *'Network is unreachable'* \
    || "${output}" == *'No route to host'* \
    || "${output}" == *'No matching route'* \
    || "${output}" == *'Cannot find device'* \
    || "${output}" == *'No such device'* \
    || "${output}" == *'Invalid VRF'* \
    || "${output}" == *'route not found'* ]]
}

copy_route_evidence() {
  local from="${1}" to="${2}" suffix
  for suffix in type5-rib client-vrf-route client-kernel-route client-vni \
    remote-vtep tenant-vrf-route tenant-return-route peer-route-get tenant-route-get; do
    cp -- "${M03_EVIDENCE_DIR}/${from}-${suffix}.txt" \
      "${M03_EVIDENCE_DIR}/${to}-${suffix}.txt"
  done
}

collect_route_evidence_convergent() {
  local phase="${1}" prefix
  local type5="" vrf_route="" kernel_route="" vni_route="" remote_vtep=""
  local tenant_route="" peer_route="" peer_route_get="" tenant_route_get=""
  local type5_count query_error=0 retryable_error=0
  prefix="${M03_EVIDENCE_DIR}/${phase}"

  if ! type5="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_PEER" vtysh -c \
    "show bgp l2vpn evpn route rd all prefix ${M03_TENANT_CIDR}" 2>&1)"; then
    if route_evidence_retryable_failure "${type5}"; then retryable_error=1; else query_error=1; fi
  fi
  if ! vrf_route="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_PEER" vtysh -c \
    "show ip route vrf ${M03_CLIENT_VRF} ${M03_TENANT_CIDR}" 2>&1)"; then
    if route_evidence_retryable_failure "${vrf_route}"; then retryable_error=1; else query_error=1; fi
  fi
  if ! kernel_route="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "${M03_PEER}" ip route show table "${M03_CLIENT_TABLE}" \
    "${M03_TENANT_CIDR}" 2>&1)"; then
    if route_evidence_retryable_failure "${kernel_route}"; then retryable_error=1; else query_error=1; fi
  fi
  if ! vni_route="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_PEER" vtysh -c "show evpn vni ${M03_VNI}" 2>&1)"; then
    if route_evidence_retryable_failure "${vni_route}"; then retryable_error=1; else query_error=1; fi
  fi
  if ! remote_vtep="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "${M03_CHASSIS}" ovn-appctl \
    -t ovn-controller evpn/remote-vtep-list 2>&1)"; then
    if route_evidence_retryable_failure "${remote_vtep}"; then retryable_error=1; else query_error=1; fi
  fi
  if ! tenant_route="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "${M03_CHASSIS}" ip route show table "${M03_TENANT_TABLE}" \
    "${M03_TENANT_CIDR}" 2>&1)"; then
    if route_evidence_retryable_failure "${tenant_route}"; then retryable_error=1; else query_error=1; fi
  fi
  if ! peer_route="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "${M03_CHASSIS}" ip route show table "${M03_TENANT_TABLE}" \
    "${M03_PEER_SOURCE}/32" 2>&1)"; then
    if route_evidence_retryable_failure "${peer_route}"; then retryable_error=1; else query_error=1; fi
  fi
  if ! peer_route_get="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "${M03_PEER}" ip route get \
    "${M03_TENANT_IP}" from "${M03_PEER_SOURCE}" vrf "${M03_CLIENT_VRF}" 2>&1)"; then
    if route_evidence_retryable_failure "${peer_route_get}"; then retryable_error=1; else query_error=1; fi
  fi
  if ! tenant_route_get="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "${M03_CHASSIS}" ip route get \
    "${M03_PEER_SOURCE}" vrf "${M03_TENANT_VRF}" 2>&1)"; then
    if route_evidence_retryable_failure "${tenant_route_get}"; then retryable_error=1; else query_error=1; fi
  fi

  printf '%s\n' "${type5}" >"${prefix}-type5-rib.txt"
  printf '%s\n' "${vrf_route}" >"${prefix}-client-vrf-route.txt"
  printf '%s\n' "${kernel_route}" >"${prefix}-client-kernel-route.txt"
  printf '%s\n' "${vni_route}" >"${prefix}-client-vni.txt"
  printf '%s\n' "${remote_vtep}" >"${prefix}-remote-vtep.txt"
  printf '%s\n' "${tenant_route}" >"${prefix}-tenant-vrf-route.txt"
  printf '%s\n' "${peer_route}" >"${prefix}-tenant-return-route.txt"
  printf '%s\n' "${peer_route_get}" >"${prefix}-peer-route-get.txt"
  printf '%s\n' "${tenant_route_get}" >"${prefix}-tenant-route-get.txt"

  [[ "${query_error}" -eq 0 ]] || return 2
  [[ "${retryable_error}" -eq 0 ]] || return 1
  type5_count="$(grep -Ec '^[[:space:]]+Route \[5\]:\[0\]:\[24\]:\[192\.168\.100\.0\] VNI [0-9]+' <<<"${type5}" || true)"
  if [[ "${type5_count}" -eq 1 \
    && "${type5}" == *"VNI ${M03_VNI}"* \
    && "${type5}" == *"${M03_CHASSIS_IP}"* \
    && "${vrf_route}" == *"${M03_TENANT_CIDR}"* \
    && "${vrf_route}" == *'Known via "bgp"'* \
    && "${kernel_route}" == *"${M03_TENANT_CIDR}"* \
    && "${kernel_route}" == *'proto bgp'* \
    && "${vni_route}" == *"VNI: ${M03_VNI}"* \
    && "${vni_route}" == *"Local Vtep Ip: ${M03_PEER_IP}"* \
    && "${vni_route}" == *'State: Up'* \
    && "${remote_vtep}" == *"IP: ${M03_PEER_IP}"* \
    && "${remote_vtep}" == *"port: 4789"* \
    && "${remote_vtep}" == *"vni: ${M03_VNI}"* \
    && "${tenant_route}" == *"${M03_TENANT_CIDR}"* \
    && "${tenant_route}" == *"blackhole ${M03_TENANT_CIDR} proto ovn"* \
    && "${peer_route}" == *"${M03_PEER_SOURCE}"* \
    && "${peer_route}" == *'proto bgp'* \
    && "${peer_route_get}" == *"${M03_TENANT_IP}"* \
    && "${peer_route_get}" == *"dev ${M03_CLIENT_BR}"* \
    && "${tenant_route_get}" == *"${M03_PEER_SOURCE}"* \
    && "${tenant_route_get}" == *"dev ${M03_TENANT_BR}"* ]]; then
    return 0
  fi
  return 1
}

wait_for_route_convergence() {
  local phase="${1}" attempt=0 rc poll_phase
  while (( attempt < 60 )); do
    attempt=$((attempt + 1))
    poll_phase="${phase}-poll-${attempt}"
    if collect_route_evidence_convergent "${poll_phase}"; then
      copy_route_evidence "${poll_phase}" "${phase}"
      printf 'phase=%s\nattempt=%s\nstatus=converged\n' \
        "${phase}" "${attempt}" >"${M03_EVIDENCE_DIR}/${phase}-convergence.txt"
      return 0
    else
      rc=$?
    fi
    if [[ "${rc}" -eq 2 ]]; then
      fail "CLI de evidência de rota falhou de modo não transitório durante ${phase}; consulte ${M03_EVIDENCE_DIR}/${poll_phase}-*.txt"
    fi
    sleep 2
  done
  printf 'phase=%s\nattempts=%s\nstatus=timeout\n' \
    "${phase}" "${attempt}" >"${M03_EVIDENCE_DIR}/${phase}-convergence.txt"
  fail "convergência completa Type5/RIB/FIB/VTEP/route-get não ocorreu em ${phase}"
}

snapshot_type5() {
  local phase="$1" output count
  if ! output="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_PEER" \
    vtysh -c "show bgp l2vpn evpn route rd all prefix $M03_TENANT_CIDR" 2>&1)"; then
    printf '%s\n' "$output" >"$M03_EVIDENCE_DIR/negative-$phase-type5-rib.txt"
    return 2
  fi
  count="$(grep -Ec '^[[:space:]]+Route \[5\]:\[0\]:\[24\]:\[192\.168\.100\.0\] VNI [0-9]+' <<<"$output" || true)"
  printf '%s\n' "$output" >"$M03_EVIDENCE_DIR/negative-$phase-type5-rib.txt"
  printf 'phase=%s\nroute_type5_count=%s\n' "$phase" "$count" \
    >>"$M03_EVIDENCE_DIR/negative-result.txt"
  if [[ "$count" -eq 0 ]]; then
    [[ "$output" == '% Network not in table' ]] && return 0
    return 2
  fi
  [[ "$count" -eq 1 ]] && return 1
  return 3
}

normalize_uuid_list() {
  local raw="$1" line
  M03_NORMALIZED_UUIDS=""
  [[ -z "$raw" ]] && return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$line")"
    [[ -n "$line" ]] || continue
    [[ "$line" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
      || return 1
    M03_NORMALIZED_UUIDS+="${line}"$'\n'
  done <<<"$raw"
  M03_NORMALIZED_UUIDS="${M03_NORMALIZED_UUIDS%$'\n'}"
}

read_sb_field() {
  local table="$1" uuid="$2" field="$3" output
  if ! output="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_CENTRAL" \
    ovn-sbctl get "$table" "$uuid" "$field" 2>&1)"; then
    return 1
  fi
  output="$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^"//; s/"$//' <<<"$output")"
  [[ -n "$output" && "$output" != *$'\n'* ]] || return 1
  M03_SB_FIELD="$output"
}

resolve_target_binding() {
  local raw ids count binding_name binding_datapath
  if ! raw="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_CENTRAL" \
    ovn-sbctl --bare --columns=_uuid find Port_Binding \
    "logical_port=$M03_LRP" 2>&1)"; then
    printf '%s\n' "$raw" >"$M03_EVIDENCE_DIR/negative-target-port-binding.txt"
    return 1
  fi
  if ! normalize_uuid_list "$raw"; then
    printf '%s\n' "$raw" >"$M03_EVIDENCE_DIR/negative-target-port-binding.txt"
    return 1
  fi
  ids="$M03_NORMALIZED_UUIDS"
  count="$(awk 'NF { n++ } END { print n + 0 }' <<<"$ids")"
  [[ "$count" -eq 1 ]] || {
    printf '%s\n' "$raw" >"$M03_EVIDENCE_DIR/negative-target-port-binding.txt"
    return 1
  }
  M03_TARGET_PB_UUID="$ids"
  if [[ -n "$M03_INITIAL_TARGET_PB_UUID" \
    && "$M03_TARGET_PB_UUID" != "$M03_INITIAL_TARGET_PB_UUID" ]]; then
    return 1
  fi
  if ! read_sb_field Port_Binding "$M03_TARGET_PB_UUID" logical_port; then
    return 1
  fi
  binding_name="$M03_SB_FIELD"
  if ! read_sb_field Port_Binding "$M03_TARGET_PB_UUID" datapath; then
    return 1
  fi
  binding_datapath="$(tr -d '<>' <<<"$M03_SB_FIELD")"
  [[ "$binding_name" == "$M03_LRP" \
    && "$binding_datapath" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || return 1
  if [[ -n "$M03_TARGET_DATAPATH" \
    && "$binding_datapath" != "$M03_TARGET_DATAPATH" ]]; then
    return 1
  fi
  if [[ -n "$M03_INITIAL_TARGET_DATAPATH" \
    && "$binding_datapath" != "$M03_INITIAL_TARGET_DATAPATH" ]]; then
    return 1
  fi
  M03_TARGET_DATAPATH="$binding_datapath"
}

record_field() {
  local output="$1" field="$2" count
  count="$(awk -F: -v wanted="$field" \
    '$1 ~ "^[[:space:]]*" wanted "[[:space:]]*$" { n++ } END { print n + 0 }' \
    <<<"$output")"
  [[ "$count" -eq 1 ]] || return 1
  M03_RECORD_FIELD="$(awk -F: -v wanted="$field" \
    '$1 ~ "^[[:space:]]*" wanted "[[:space:]]*$" {
      sub(/^[^:]*:[[:space:]]*/, "")
      sub(/[[:space:]]*$/, "")
      print
    }' <<<"$output")"
  [[ -n "$M03_RECORD_FIELD" && "$M03_RECORD_FIELD" != *$'\n'* ]]
}

snapshot_advertised_routes() {
  local phase="$1" expected_target="$2" all_ids target_ids target_count
  local route_uuid row row_uuid datapath prefix binding_uuid binding_name
  local binding_datapath target_count_seen=0 collateral_count=0
  local collateral_100_count=0 collateral_200_count=0 target_route_uuid
  local target_rows_file="$M03_EVIDENCE_DIR/negative-$phase-target-route.txt"
  local collateral_file="$M03_EVIDENCE_DIR/negative-$phase-collateral-routes.txt"
  local rows_file="$M03_EVIDENCE_DIR/negative-$phase-sb-advertised-routes.txt"

  if ! resolve_target_binding; then
    printf 'target Port_Binding lookup failed\n' >"$rows_file"
    return 2
  fi
  if ! all_ids="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_CENTRAL" \
    ovn-sbctl --bare --columns=_uuid find Advertised_Route \
    "ip_prefix=$M03_TENANT_CIDR" 2>&1)"; then
    printf '%s\n' "$all_ids" >"$rows_file"
    return 2
  fi
  if ! normalize_uuid_list "$all_ids"; then
    printf '%s\n' "$all_ids" >"$rows_file"
    return 2
  fi
  all_ids="$M03_NORMALIZED_UUIDS"
  if [[ -n "$all_ids" ]]; then
    all_ids="$(sort <<<"$all_ids")"
  fi

  if ! target_ids="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_CENTRAL" \
    ovn-sbctl --bare --columns=_uuid find Advertised_Route \
    "ip_prefix=$M03_TENANT_CIDR" "logical_port=$M03_TARGET_PB_UUID" 2>&1)"; then
    printf '%s\n' "$target_ids" >"$rows_file"
    return 2
  fi
  if ! normalize_uuid_list "$target_ids"; then
    printf '%s\n' "$target_ids" >"$rows_file"
    return 2
  fi
  target_ids="$M03_NORMALIZED_UUIDS"
  target_count="$(awk 'NF { n++ } END { print n + 0 }' <<<"$target_ids")"
  [[ "$target_count" -le 1 ]] || return 3

  : >"$target_rows_file"
  : >"$collateral_file"
  : >"$rows_file"
  while IFS= read -r route_uuid || [[ -n "$route_uuid" ]]; do
    [[ -n "$route_uuid" ]] || continue
    if ! row="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_CENTRAL" \
      ovn-sbctl list Advertised_Route "$route_uuid" 2>&1)"; then
      printf '%s\n' "$row" >>"$rows_file"
      return 2
    fi
    if ! record_field "$row" _uuid; then return 2; fi
    row_uuid="$(tr -d '<>' <<<"$M03_RECORD_FIELD")"
    if ! record_field "$row" datapath; then return 2; fi
    datapath="$(tr -d '<>' <<<"$M03_RECORD_FIELD")"
    if ! record_field "$row" ip_prefix; then return 2; fi
    prefix="$(sed -E 's/^"([^"]*)"$/\1/' <<<"$M03_RECORD_FIELD")"
    if ! record_field "$row" logical_port; then return 2; fi
    binding_uuid="$(tr -d '<>' <<<"$M03_RECORD_FIELD")"
    [[ "$row_uuid" == "$route_uuid" \
      && "$datapath" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ \
      && "$prefix" == "$M03_TENANT_CIDR" \
      && "$binding_uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
      || return 3
    if ! read_sb_field Port_Binding "$binding_uuid" logical_port; then
      return 2
    fi
    binding_name="$M03_SB_FIELD"
    if ! read_sb_field Port_Binding "$binding_uuid" datapath; then
      return 2
    fi
    binding_datapath="$(tr -d '<>' <<<"$M03_SB_FIELD")"
    [[ "$binding_datapath" == "$datapath" ]] || return 3
    printf 'route_uuid=%s datapath=%s prefix=%s port_binding=%s logical_port=%s\n%s\n' \
      "$route_uuid" "$datapath" "$prefix" "$binding_uuid" "$binding_name" \
      "$row" >>"$rows_file"
    if [[ "$binding_uuid" == "$M03_TARGET_PB_UUID" ]]; then
      [[ "$binding_name" == "$M03_LRP" \
        && "$datapath" == "$M03_TARGET_DATAPATH" ]] || return 3
      target_count_seen=$((target_count_seen + 1))
      printf 'route_uuid=%s datapath=%s port_binding=%s\n%s\n' \
        "$route_uuid" "$datapath" "$binding_uuid" "$row" >>"$target_rows_file"
    elif [[ "$binding_name" == lrp-mgc-100-tenant ]]; then
      collateral_count=$((collateral_count + 1))
      collateral_100_count=$((collateral_100_count + 1))
      printf 'route_uuid=%s datapath=%s prefix=%s port_binding=%s logical_port=%s\n%s\n' \
        "$route_uuid" "$datapath" "$prefix" "$binding_uuid" "$binding_name" \
        "$row" >>"$collateral_file"
    elif [[ "$binding_name" == lrp-mgc-200-tenant ]]; then
      collateral_count=$((collateral_count + 1))
      collateral_200_count=$((collateral_200_count + 1))
      printf 'route_uuid=%s datapath=%s prefix=%s port_binding=%s logical_port=%s\n%s\n' \
        "$route_uuid" "$datapath" "$prefix" "$binding_uuid" "$binding_name" \
        "$row" >>"$collateral_file"
    else
      return 3
    fi
  done <<<"$all_ids"

  [[ "$target_count_seen" -eq "$target_count" \
    && "$collateral_count" -eq 2 \
    && "$collateral_100_count" -eq 1 \
    && "$collateral_200_count" -eq 1 ]] || return 3
  if [[ "$target_count_seen" -eq 1 ]]; then
    target_route_uuid="$(awk -F'[ =]' '/^route_uuid=/{print $2; exit}' "$target_rows_file")"
    if [[ -n "$target_ids" && "$target_ids" != "$target_route_uuid" ]]; then
      return 3
    fi
  fi
  if [[ "$M03_SB_COLLATERAL_BASELINE_CAPTURED" -eq 0 ]]; then
    [[ "$target_count_seen" -eq 1 ]] || return 3
    cp "$collateral_file" \
      "$M03_EVIDENCE_DIR/negative-collateral-baseline.txt" || return 2
    M03_SB_COLLATERAL_BASELINE_CAPTURED=1
  elif ! cmp -s "$collateral_file" \
    "$M03_EVIDENCE_DIR/negative-collateral-baseline.txt"; then
    return 3
  fi
  [[ "$target_count_seen" -eq 1 ]] || target_route_uuid="absent"
  printf 'phase=%s\nsb_target_route_count=%s\nsb_target_route_uuid=%s\nsb_collateral_route_count=%s\n' \
    "$phase" "$target_count_seen" "$target_route_uuid" "$collateral_count" \
    >>"$M03_EVIDENCE_DIR/negative-result.txt"
  [[ "$expected_target" == any || "$target_count_seen" -eq "$expected_target" ]] \
    || return 1
  return 0
}

snapshot_tenant_route() {
  local phase="$1" output count
  if ! output="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_CHASSIS" \
    ip -4 route show table "$M03_TENANT_TABLE" exact "$M03_TENANT_CIDR" 2>&1)"; then
    printf '%s\n' "$output" >"$M03_EVIDENCE_DIR/negative-$phase-tenant-vrf-route.txt"
    return 2
  fi
  printf '%s\n' "$output" >"$M03_EVIDENCE_DIR/negative-$phase-tenant-vrf-route.txt"
  count="$(awk 'NF { n++ } END { print n + 0 }' <<<"$output")"
  printf 'phase=%s\ntenant_vrf_route_count=%s\n' "$phase" "$count" \
    >>"$M03_EVIDENCE_DIR/negative-result.txt"
  [[ "$count" -eq 0 ]] && return 0
  if [[ "$count" -eq 1 \
    && "$output" == *"blackhole $M03_TENANT_CIDR proto ovn"* ]]; then
    return 1
  fi
  return 3
}

snapshot_peer_fib() {
  local phase="$1" output count
  if ! output="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_PEER" \
    ip -4 route show table "$M03_CLIENT_TABLE" exact "$M03_TENANT_CIDR" 2>&1)"; then
    printf '%s\n' "$output" >"$M03_EVIDENCE_DIR/negative-$phase-peer-fib.txt"
    return 2
  fi
  printf '%s\n' "$output" >"$M03_EVIDENCE_DIR/negative-$phase-peer-fib.txt"
  count="$(awk 'NF { n++ } END { print n + 0 }' <<<"$output")"
  printf 'phase=%s\npeer_fib_route_count=%s\n' "$phase" "$count" \
    >>"$M03_EVIDENCE_DIR/negative-result.txt"
  [[ "$count" -eq 0 ]] && return 0
  if [[ "$count" -eq 1 \
    && "$output" == *"$M03_TENANT_CIDR"* \
    && "$output" == *"dev $M03_CLIENT_BR"* \
    && "$output" == *'proto bgp'* ]]; then
    return 1
  fi
  return 3
}

snapshot_peer_route_get() {
  local phase="$1" output rc
  if output="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_PEER" \
    ip route get "$M03_TENANT_IP" from "$M03_PEER_SOURCE" \
    vrf "$M03_CLIENT_VRF" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  printf '%s\n' "$output" >"$M03_EVIDENCE_DIR/negative-$phase-peer-route-get.txt"
  printf 'phase=%s\npeer_route_get_rc=%s\n' "$phase" "$rc" \
    >>"$M03_EVIDENCE_DIR/negative-result.txt"
  [[ "$rc" -ne 124 && "$rc" -ne 125 && "$rc" -ne 126 && "$rc" -ne 127 ]] \
    || return 2
  [[ "$rc" -ne 0 ]] || return 1
  [[ "$output" == *'Network is unreachable'* \
    || "$output" == *'No route to host'* \
    || "$output" == *'No route'* ]] && return 0
  return 2
}

assert_causal_control_plane() {
  local phase="$1" chassis_state client_state vni_route remote_vtep
  if ! chassis_state="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_CHASSIS" \
    vtysh --vty_socket /run/frr/m03 -c "show bgp neighbors $M03_PEER_IP" 2>&1)"; then
    printf '%s\n' "$chassis_state" >"$M03_EVIDENCE_DIR/negative-$phase-bgp-chassis.txt"
    fail "consulta BGP do chassis falhou durante o controle causal ($phase)"
  fi
  if ! client_state="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_PEER" \
    vtysh -c "show bgp neighbors $M03_CHASSIS_IP" 2>&1)"; then
    printf '%s\n' "$client_state" >"$M03_EVIDENCE_DIR/negative-$phase-bgp-peer.txt"
    fail "consulta BGP do peer falhou durante o controle causal ($phase)"
  fi
  if ! vni_route="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_PEER" \
    vtysh -c "show evpn vni $M03_VNI" 2>&1)"; then
    printf '%s\n' "$vni_route" >"$M03_EVIDENCE_DIR/negative-$phase-peer-vni.txt"
    fail "consulta do VNI no peer falhou durante o controle causal ($phase)"
  fi
  if ! remote_vtep="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_CHASSIS" \
    ovn-appctl -t ovn-controller evpn/remote-vtep-list 2>&1)"; then
    printf '%s\n' "$remote_vtep" >"$M03_EVIDENCE_DIR/negative-$phase-remote-vtep.txt"
    fail "consulta VTEP do chassis falhou durante o controle causal ($phase)"
  fi
  printf '%s\n' "$chassis_state" >"$M03_EVIDENCE_DIR/negative-$phase-bgp-chassis.txt"
  printf '%s\n' "$client_state" >"$M03_EVIDENCE_DIR/negative-$phase-bgp-peer.txt"
  printf '%s\n' "$vni_route" >"$M03_EVIDENCE_DIR/negative-$phase-peer-vni.txt"
  printf '%s\n' "$remote_vtep" >"$M03_EVIDENCE_DIR/negative-$phase-remote-vtep.txt"
  [[ "$chassis_state" == *'BGP state = Established'* \
    && "$client_state" == *'BGP state = Established'* ]] \
    || fail "sessão BGP caiu durante o controle causal ($phase)"
  [[ "$vni_route" == *"VNI: $M03_VNI"* \
    && "$vni_route" == *"Local Vtep Ip: $M03_PEER_IP"* \
    && "$vni_route" == *'State: Up'* ]] \
    || fail "VNI $M03_VNI deixou de estar ativo no peer durante o controle causal ($phase)"
  [[ "$remote_vtep" == *"IP: $M03_PEER_IP"* \
    && "$remote_vtep" == *'port: 4789'* \
    && "$remote_vtep" == *"vni: $M03_VNI"* ]] \
    || fail "VTEP remoto desapareceu durante o controle causal ($phase)"
}

assert_causal_negative_preconditions() {
  local lrp_options ls_options router_options rc lrp_uuid
  lrp_options="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_CENTRAL" \
    ovn-nbctl get logical_router_port "$M03_LRP" options 2>&1)" \
    || fail "não foi possível ler options de $M03_LRP antes do negativo"
  [[ "$lrp_options" == *'dynamic-routing-maintain-vrf="true"'* \
    && "$lrp_options" != *"$M03_LRP_REDISTRIBUTE_KEY"* ]] \
    || fail "estado inicial das options de $M03_LRP diverge do esperado: $lrp_options"
  router_options="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_CENTRAL" \
    ovn-nbctl get logical_router "$M03_TENANT_LR" options 2>&1)" \
    || fail "não foi possível ler options de $M03_TENANT_LR antes do negativo"
  [[ "$router_options" == *'dynamic-routing-redistribute="connected,static"'* ]] \
    || fail "LR do tenant não oferece baseline connected,static: $router_options"
  ls_options="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_CENTRAL" \
    ovn-nbctl get logical_switch "$M03_TENANT_LS" other_config 2>&1)" \
    || fail "não foi possível ler other_config de $M03_TENANT_LS antes do negativo"
  grep -Eq 'dynamic-routing-vni="?50100"?' <<<"$ls_options" \
    || fail "VNI $M03_VNI não está preservado antes do negativo"

  M03_CAUSAL_BASE_OPTIONS="$lrp_options"
  lrp_uuid="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_CENTRAL" \
    ovn-nbctl get logical_router_port "$M03_LRP" _uuid 2>&1)" \
    || fail "não foi possível capturar UUID de $M03_LRP antes do negativo"
  M03_CAUSAL_LRP_UUID="$(tr -d '<>\"[:space:]' <<<"$lrp_uuid")"
  [[ "$M03_CAUSAL_LRP_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
    || fail "UUID inválido para $M03_LRP: $M03_CAUSAL_LRP_UUID"
  if snapshot_advertised_routes pre 1; then
    :
  else
    rc=$?
    fail "Advertised_Route inicial precisa ter origem única $M03_LRP e duas rotas colaterais estáveis (rc=$rc)"
  fi
  if snapshot_tenant_route pre; then rc=0; else rc=$?; fi
  [[ "$rc" -eq 1 ]] \
    || fail "rota tenant proto ovn precisa existir antes do negativo (rc=$rc)"
  if snapshot_peer_fib pre; then rc=0; else rc=$?; fi
  [[ "$rc" -eq 1 ]] \
    || fail "rota BGP exata na FIB peer precisa existir antes do negativo (rc=$rc)"
  if snapshot_type5 pre; then rc=0; else rc=$?; fi
  [[ "$rc" -eq 1 ]] \
    || fail "RIB peer precisa conter uma única Type 5 exata antes do negativo (rc=$rc)"
  assert_causal_control_plane pre
}

wait_for_causal_withdrawal() {
  local attempt=0 phase sb_rc tenant_rc peer_fib_rc peer_get_rc type5_rc
  while (( attempt < M03_NEGATIVE_POLL_ATTEMPTS )); do
    attempt=$((attempt + 1))
    phase="withdraw-poll-$attempt"
    if snapshot_advertised_routes "$phase" 0; then sb_rc=0; else sb_rc=$?; fi
    if snapshot_tenant_route "$phase"; then tenant_rc=0; else tenant_rc=$?; fi
    if snapshot_type5 "$phase"; then type5_rc=0; else type5_rc=$?; fi
    if snapshot_peer_fib "$phase"; then peer_fib_rc=0; else peer_fib_rc=$?; fi
    if snapshot_peer_route_get "$phase"; then peer_get_rc=0; else peer_get_rc=$?; fi
    [[ "$sb_rc" -lt 2 && "$tenant_rc" -lt 2 \
      && "$type5_rc" -lt 2 && "$peer_fib_rc" -lt 2 \
      && "$peer_get_rc" -lt 2 ]] \
      || fail "consulta falhou ou encontrou origem duplicada durante withdraw (poll=$attempt; SB=$sb_rc, tenant=$tenant_rc, Type5=$type5_rc, FIB=$peer_fib_rc, route-get=$peer_get_rc)"
    assert_causal_control_plane "$phase"
    if [[ "$sb_rc" -eq 0 && "$tenant_rc" -eq 0 \
      && "$type5_rc" -eq 0 && "$peer_fib_rc" -eq 0 \
      && "$peer_get_rc" -eq 0 ]]; then
      printf 'phase=withdraw\nattempt=%s\nstatus=withdrawn\n' "$attempt" \
        >"$M03_EVIDENCE_DIR/negative-withdraw-convergence.txt"
      return 0
    fi
    sleep "$M03_NEGATIVE_POLL_INTERVAL"
  done
  printf 'phase=withdraw\nattempts=%s\nstatus=timeout\n' "$attempt" \
    >"$M03_EVIDENCE_DIR/negative-withdraw-convergence.txt"
  fail "withdraw causal não convergiu em $M03_NEGATIVE_POLL_ATTEMPTS polls"
}

run_causal_negative_probe() {
  local output rc
  if output="$(timeout 10 docker exec "$M03_PEER" ip vrf exec "$M03_CLIENT_VRF" \
    ping -I "$M03_PEER_SOURCE" -c 3 -i 0.2 -W 1 "$M03_TENANT_IP" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  printf '%s\n' "$output" >"$M03_EVIDENCE_DIR/negative-ping.txt"
  printf 'negative_ping_rc=%s\n' "$rc" >>"$M03_EVIDENCE_DIR/negative-result.txt"
  [[ "$rc" -eq 1 || "$rc" -eq 2 ]] \
    || fail "probe negativo teve timeout ou falha da ferramenta (rc=$rc)"
  if [[ "$output" == 'ping: connect: Network is unreachable' ]]; then
    return 0
  fi
  if [[ "$rc" -eq 1 && "$output" == *"PING $M03_TENANT_IP"* ]] \
    && grep -Eq '3 packets transmitted,[[:space:]]+0[[:space:]]+(packets[[:space:]]+)?received,[[:space:]]+100%[[:space:]]+packet[[:space:]]+loss' \
      <<<"$output"; then
    return 0
  fi
  fail 'probe negativo não registrou perda total nem diagnóstico Network is unreachable válido'
}

attempt_cleanup_recovery() {
  local attempt=0 phase sb_rc type5_rc fib_rc route_get_rc converged=0
  : >"$M03_EVIDENCE_DIR/negative-cleanup-recovery.txt"
  M03_CLEANUP_RECOVERY_RESULT="IN_PROGRESS"
  while (( attempt < M03_NEGATIVE_POLL_ATTEMPTS )); do
    attempt=$((attempt + 1))
    phase="cleanup-recovery-poll-$attempt"
    if snapshot_advertised_routes "$phase" 1; then sb_rc=0; else sb_rc=$?; fi
    if snapshot_type5 "$phase"; then type5_rc=0; else type5_rc=$?; fi
    if snapshot_peer_fib "$phase"; then fib_rc=0; else fib_rc=$?; fi
    if snapshot_peer_route_get "$phase"; then route_get_rc=0; else route_get_rc=$?; fi
    printf 'attempt=%s sb_rc=%s type5_rc=%s fib_rc=%s route_get_rc=%s\n' \
      "$attempt" "$sb_rc" "$type5_rc" "$fib_rc" "$route_get_rc" \
      >>"$M03_EVIDENCE_DIR/negative-cleanup-recovery.txt"
    if [[ "$sb_rc" -ge 2 || "$type5_rc" -ge 2 \
      || "$fib_rc" -ge 2 || "$route_get_rc" -ge 2 ]]; then
      M03_CLEANUP_RECOVERY_RESULT="QUERY_FAILED"
      printf 'status=%s\n' "$M03_CLEANUP_RECOVERY_RESULT" \
        >>"$M03_EVIDENCE_DIR/negative-cleanup-recovery.txt"
      return 1
    fi
    if [[ "$sb_rc" -eq 0 && "$type5_rc" -eq 1 \
      && "$fib_rc" -eq 1 && "$route_get_rc" -eq 1 ]]; then
      converged=1
      break
    fi
    sleep "$M03_NEGATIVE_POLL_INTERVAL"
  done
  if [[ "$converged" -ne 1 ]]; then
    M03_CLEANUP_RECOVERY_RESULT="ROUTE_TIMEOUT"
    printf 'attempts=%s\nstatus=%s\n' "$attempt" \
      "$M03_CLEANUP_RECOVERY_RESULT" \
      >>"$M03_EVIDENCE_DIR/negative-cleanup-recovery.txt"
    return 1
  fi
  if ! run_restoration_probe cleanup-recovery; then
    M03_CLEANUP_RECOVERY_RESULT="PING_FAILED"
    printf 'status=%s\n' "$M03_CLEANUP_RECOVERY_RESULT" \
      >>"$M03_EVIDENCE_DIR/negative-cleanup-recovery.txt"
    return 1
  fi
  M03_CLEANUP_RECOVERY_RESULT="RECOVERED"
  printf 'status=%s\n' "$M03_CLEANUP_RECOVERY_RESULT" \
    >>"$M03_EVIDENCE_DIR/negative-cleanup-recovery.txt"
  return 0
}

run_restoration_probe() {
  local phase="${1:-restored}" output rc evidence_file
  if output="$(timeout 10 docker exec "$M03_PEER" ip vrf exec "$M03_CLIENT_VRF" \
    ping -I "$M03_PEER_SOURCE" -c 3 -i 0.2 -W 2 "$M03_TENANT_IP" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  evidence_file="negative-$phase-ping.txt"
  printf '%s\n' "$output" >"$M03_EVIDENCE_DIR/$evidence_file"
  printf '%s_ping_rc=%s\n' "$phase" "$rc" >>"$M03_EVIDENCE_DIR/negative-result.txt"
  if [[ "$rc" -ne 0 ]] \
    || ! grep -Eq '3 packets transmitted,[[:space:]]+3[[:space:]]+(packets[[:space:]]+)?received,[[:space:]]+0%[[:space:]]+packet[[:space:]]+loss' \
      <<<"$output"; then
    return 1
  fi
  return 0
}

restore_lrp_redistribute() {
  local options restore_state
  [[ "$M03_LRP_REDISTRIBUTE_CHANGED" -eq 1 ]] || return 0
  if assert_lrp_restore_safe; then
    restore_state=0
  else
    restore_state=$?
  fi
  if [[ "$restore_state" -eq 2 ]]; then
    M03_LRP_REDISTRIBUTE_CHANGED=0
    say "$M03_LRP já está no baseline; nenhuma remoção adicional necessária"
    return 0
  fi
  if [[ "$restore_state" -ne 0 ]]; then
    say "drift detectado em $M03_LRP; não remover $M03_LRP_REDISTRIBUTE_KEY" >&2
    return 1
  fi
  if ! timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_CENTRAL" ovn-nbctl \
    --wait=sb remove logical_router_port "$M03_LRP" options \
    "$M03_LRP_REDISTRIBUTE_KEY" >/dev/null 2>&1; then
    say "não foi possível remover a chave temporária $M03_LRP_REDISTRIBUTE_KEY de $M03_LRP" >&2
    return 1
  fi
  if ! options="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_CENTRAL" \
    ovn-nbctl get logical_router_port "$M03_LRP" options 2>&1)"; then
    say "não foi possível confirmar options de $M03_LRP após restauração: $options" >&2
    return 1
  fi
  if [[ "$options" != "$M03_CAUSAL_BASE_OPTIONS" ]]; then
    say "options de $M03_LRP divergiram do baseline após remover a chave: $options" >&2
    return 1
  fi
  M03_LRP_REDISTRIBUTE_CHANGED=0
}

assert_lrp_restore_safe() {
  local current_uuid current_options normalized_options key_count
  local lrp_uuid_output
  if ! lrp_uuid_output="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_CENTRAL" \
    ovn-nbctl get logical_router_port "$M03_LRP" _uuid 2>&1)"; then
    return 1
  fi
  current_uuid="$(tr -d '<>"[:space:]' <<<"$lrp_uuid_output")"
  [[ "$current_uuid" == "$M03_CAUSAL_LRP_UUID" ]] || return 1
  if ! current_options="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_CENTRAL" \
    ovn-nbctl get logical_router_port "$M03_LRP" options 2>&1)"; then
    return 1
  fi
  if [[ "$current_options" == "$M03_CAUSAL_BASE_OPTIONS" ]]; then
    return 2
  fi
  key_matches="$(grep -oE 'dynamic-routing-redistribute="?static"?' \
    <<<"$current_options" || true)"
  key_count="$(awk 'NF { n++ } END { print n + 0 }' <<<"$key_matches")"
  [[ "$key_count" -eq 1 ]] || return 1
  normalized_options="$(sed -E \
    's/,[[:space:]]*dynamic-routing-redistribute="?static"?//; s/dynamic-routing-redistribute="?static"?,[[:space:]]*//' \
    <<<"$current_options")"
  [[ "$normalized_options" == "$M03_CAUSAL_BASE_OPTIONS" ]] || return 1
  M03_LRP_REDISTRIBUTE_CONFIRMED=1
  return 0
}

wait_for_advertised_route_restoration() {
  local attempt=0 phase rc
  while (( attempt < M03_NEGATIVE_POLL_ATTEMPTS )); do
    attempt=$((attempt + 1))
    phase="restore-sb-poll-$attempt"
    if snapshot_advertised_routes "$phase" 1; then
      printf 'phase=restore-sb\nattempt=%s\nstatus=restored\n' "$attempt" \
        >"$M03_EVIDENCE_DIR/negative-sb-restoration.txt"
      return 0
    else
      rc=$?
    fi
    [[ "$rc" -eq 1 ]] || return 1
    sleep "$M03_NEGATIVE_POLL_INTERVAL"
  done
  printf 'phase=restore-sb\nattempts=%s\nstatus=timeout\n' "$attempt" \
    >"$M03_EVIDENCE_DIR/negative-sb-restoration.txt"
  return 1
}

run_negative_causal() {
  local options rc
  M03_NEGATIVE_CONTROL_STATUS="FAIL"
  M03_NEGATIVE_CAUSAL_RESULT="IN_PROGRESS"
  : >"$M03_EVIDENCE_DIR/negative-result.txt"
  assert_causal_negative_preconditions
  M03_INITIAL_TARGET_PB_UUID="$M03_TARGET_PB_UUID"
  M03_INITIAL_TARGET_DATAPATH="$M03_TARGET_DATAPATH"

  M03_LRP_REDISTRIBUTE_CHANGED=1
  M03_CAUSAL_SET_ATTEMPTED=1
  run timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_CENTRAL" ovn-nbctl --wait=sb set \
    logical_router_port "$M03_LRP" \
    "options:$M03_LRP_REDISTRIBUTE_KEY=static"
  if ! options="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_CENTRAL" \
    ovn-nbctl get logical_router_port "$M03_LRP" options 2>&1)"; then
    fail "não foi possível confirmar override temporário em $M03_LRP: $options"
  fi
  printf '%s\n' "$options" >"$M03_EVIDENCE_DIR/negative-lrp-options-static.txt"
  [[ "$options" == *'dynamic-routing-maintain-vrf="true"'* \
    && "$options" =~ dynamic-routing-redistribute=\"?static\"? ]] \
    || fail "override static não preservou maintain-vrf ou diverge do esperado: $options"
  assert_lrp_restore_safe \
    || fail "override temporário de $M03_LRP contém drift de identidade/options"
  M03_LRP_REDISTRIBUTE_CONFIRMED=1
  wait_for_causal_withdrawal
  run_causal_negative_probe
  assert_causal_control_plane after-negative-probe

  restore_lrp_redistribute \
    || fail 'não foi possível restaurar a option de redistribuição da LRP'
  wait_for_advertised_route_restoration \
    || fail 'Advertised_Route do alvo não retornou após restaurar a LRP'
  wait_for_route_convergence negative-restored
  snapshot_advertised_routes restored 1 \
    || fail 'Advertised_Route do alvo não foi restaurada sem alterar origens colaterais'
  if snapshot_type5 restored; then rc=0; else rc=$?; fi
  [[ "$rc" -eq 1 ]] || fail "Type 5 peer não foi restaurado (rc=$rc)"
  if snapshot_peer_fib restored; then rc=0; else rc=$?; fi
  [[ "$rc" -eq 1 ]] || fail "FIB do peer não foi restaurada (rc=$rc)"
  if snapshot_peer_route_get restored; then rc=0; else rc=$?; fi
  [[ "$rc" -eq 1 ]] || fail "route-get do peer não foi restaurado (rc=$rc)"
  assert_causal_control_plane restored
  run_restoration_probe || fail 'ping 3/3 não retornou após restaurar a LRP'
  printf 'restored=yes\n' >>"$M03_EVIDENCE_DIR/negative-result.txt"
  M03_NORMAL_RECOVERY_COMPLETE=1
  M03_NEGATIVE_CAUSAL_RESULT="WITHDRAWN_AND_RESTORED"
  M03_NEGATIVE_CONTROL_STATUS="PASS"
}

M03_REQUEST_RE='(^|[[:space:]])10\.250\.0\.1[[:space:]]*>[[:space:]]*192\.168\.100\.10[[:space:]]*:[[:space:]]*ICMP[[:space:]]+echo[[:space:]]+request'
M03_REPLY_RE='(^|[[:space:]])192\.168\.100\.10[[:space:]]*>[[:space:]]*10\.250\.0\.1[[:space:]]*:[[:space:]]*ICMP[[:space:]]+echo[[:space:]]+reply'

assert_probe_capture() {
  local logfile="$1" label="$2" requests replies
  [[ -s "${logfile}" ]] || fail "captura ${label} ausente ou vazia"
  requests="$(grep -Eio "${M03_REQUEST_RE}" "${logfile}" || true)"
  replies="$(grep -Eio "${M03_REPLY_RE}" "${logfile}" || true)"
  printf '%s\n' "${requests}" >"${M03_EVIDENCE_DIR}/${label}-requests.txt"
  printf '%s\n' "${replies}" >"${M03_EVIDENCE_DIR}/${label}-replies.txt"
  [[ -n "${requests}" ]] \
    || fail "captura ${label} sem ICMP echo request do tuple de prova"
  [[ -n "${replies}" ]] \
    || fail "captura ${label} sem ICMP echo reply do tuple de prova"
}

assert_underlay_capture() {
  local logfile="$1" label="$2"
  assert_probe_capture "${logfile}" "${label}"
  grep -Eiq \
    '170\.168\.0\.7\.[0-9]+[[:space:]]*>[[:space:]]*170\.168\.0\.5\.4789|170\.168\.0\.5\.4789[[:space:]]*>[[:space:]]*170\.168\.0\.7\.[0-9]+' \
    "${logfile}" \
    || fail "captura ${label} sem pacote UDP/4789 entre os VTEPs esperados"
  grep -Eiq 'vni[[:space:]=:]+50100' "${logfile}" \
    || fail "captura ${label} sem VNI 50100 decodificada"
}

assert_no_probe_packets() {
  local logfile="$1" label="$2" packets
  [[ -f "${logfile}" ]] || fail "captura ${label} ausente"
  packets="$(grep -Ein "${M03_REQUEST_RE}|${M03_REPLY_RE}" "${logfile}" || true)"
  if [[ -n "${packets}" ]]; then
    printf '%s\n' "${packets}" >"${M03_EVIDENCE_DIR}/${label}-unexpected.txt"
    fail "captura ${label} contém pacote ICMP do tuple de prova"
  fi
}

start_capture() {
  local label="$1" pid iface logfile filter
  logfile="${M03_EVIDENCE_DIR}/capture-${label}.txt"
  case "${label}" in
    chassis-underlay)
      pid="$(docker inspect -f '{{.State.Pid}}' "${M03_CHASSIS}")"
      timeout --foreground --signal=TERM --kill-after=2s 50s \
        nsenter -t "${pid}" -n tcpdump -nn -e -vvv -U -l -s 0 -i eth1 \
          'udp port 4789 and (host 170.168.0.5 or host 170.168.0.7)' \
        >"${logfile}" 2>&1 &
      ;;
    peer-underlay)
      pid="$(docker inspect -f '{{.State.Pid}}' "${M03_PEER}")"
      timeout --foreground --signal=TERM --kill-after=2s 50s \
        nsenter -t "${pid}" -n tcpdump -nn -e -vvv -U -l -s 0 -i eth1 \
          'udp port 4789 and (host 170.168.0.5 or host 170.168.0.7)' \
        >"${logfile}" 2>&1 &
      ;;
    peer-tenant)
      pid="$(docker inspect -f '{{.State.Pid}}' "${M03_PEER}")"
      filter='icmp and (host 10.250.0.1 or host 192.168.100.10)'
      timeout --foreground --signal=TERM --kill-after=2s 50s \
        nsenter -t "${pid}" -n tcpdump -nn -e -vvv -U -l -s 0 -i br-evpn-client \
          "${filter}" >"${logfile}" 2>&1 &
      ;;
    tenant-tap)
      pid="$(docker inspect -f '{{.State.Pid}}' "${M03_CHASSIS}")"
      filter='icmp and (host 10.250.0.1 or host 192.168.100.10)'
      timeout --foreground --signal=TERM --kill-after=2s 50s \
        nsenter -t "${pid}" -n tcpdump -nn -e -vvv -U -l -s 0 \
          -i "${M03_TENANT_TAP}" "${filter}" >"${logfile}" 2>&1 &
      ;;
    old-client-eth1)
      iface="${M03_OLD_CLIENT_PORT_1}"
      filter='icmp and (host 192.168.100.10 or host 10.250.0.1)'
      timeout --foreground --signal=TERM --kill-after=2s 50s \
        tcpdump -nn -e -vvv -U -l -s 0 -i "${iface}" "${filter}" \
        >"${logfile}" 2>&1 &
      ;;
    old-client-eth2)
      iface="${M03_OLD_CLIENT_PORT_2}"
      filter='icmp and (host 192.168.100.10 or host 10.250.0.1)'
      timeout --foreground --signal=TERM --kill-after=2s 50s \
        tcpdump -nn -e -vvv -U -l -s 0 -i "${iface}" "${filter}" \
        >"${logfile}" 2>&1 &
      ;;
    *)
      fail "rótulo de captura desconhecido: ${label}"
      ;;
  esac
  M03_CAPTURE_PIDS+=("$!")
  M03_CAPTURE_LOGS+=("${logfile}")
}

start_positive_diagnostic_capture() {
  local label="$1" iface="$2" pid logfile
  logfile="${M03_EVIDENCE_DIR}/capture-${label}.txt"
  if ! pid="$(docker inspect -f '{{.State.Pid}}' "${M03_CHASSIS}" 2>&1)"; then
    printf 'capture=%s status=INSPECT_FAILED detail=%s\n' "$label" "$pid" \
      >>"${M03_EVIDENCE_DIR}/positive-diagnostic-status.txt"
    return 1
  fi
  timeout --foreground --signal=TERM --kill-after=2s 50s \
    nsenter -t "${pid}" -n tcpdump -nn -e -vvv -U -l -s 0 \
      -i "${iface}" "${M03_POSITIVE_ICMP_FILTER}" \
    >"${logfile}" 2>&1 &
  M03_CAPTURE_PIDS+=("$!")
  M03_CAPTURE_LOGS+=("${logfile}")
}

start_captures() {
  start_capture chassis-underlay
  start_capture peer-underlay
  start_capture peer-tenant
  start_capture tenant-tap
  start_capture old-client-eth1
  start_capture old-client-eth2
  sleep 1
  local pid
  for pid in "${M03_CAPTURE_PIDS[@]}"; do
    kill -0 "${pid}" 2>/dev/null || fail 'captura tcpdump encerrou antes do probe'
  done
  start_positive_diagnostic_capture chassis-tenant-bridge "$M03_TENANT_BR" || true
  start_positive_diagnostic_capture chassis-tenant-vxlan "$M03_TENANT_VXLAN" || true
}

stop_captures() {
  local i pid alive_before wait_rc logfile label bytes
  local -a alive_after_probe=()
  [[ "${#M03_CAPTURE_PIDS[@]}" -gt 0 ]] || return 0
  for pid in "${M03_CAPTURE_PIDS[@]}"; do
    if kill -0 "${pid}" 2>/dev/null; then
      alive_after_probe+=(1)
    else
      alive_after_probe+=(0)
    fi
    kill -TERM "${pid}" 2>/dev/null || true
  done
  : >"${M03_EVIDENCE_DIR}/capture-status.txt"
  for i in "${!M03_CAPTURE_PIDS[@]}"; do
    pid="${M03_CAPTURE_PIDS[${i}]}"
    alive_before="${alive_after_probe[${i}]}"
    wait_rc=0
    wait "${pid}" 2>/dev/null || wait_rc=$?
    logfile="${M03_CAPTURE_LOGS[${i}]}"
    label="${logfile##*/capture-}"
    label="${label%.txt}"
    bytes="$(wc -c <"${logfile}" 2>/dev/null || true)"
    printf 'label=%s pid=%s alive_after_probe=%s wait_rc=%s bytes=%s\n' \
      "${label}" "${pid}" "${alive_before}" "${wait_rc}" "${bytes:-0}" \
      >>"${M03_EVIDENCE_DIR}/capture-status.txt"
  done
  M03_CAPTURE_PIDS=()
  M03_CAPTURE_LOGS=()
}

assert_capture_lifecycle() {
  local label line count wait_rc
  for label in chassis-underlay peer-underlay peer-tenant tenant-tap \
    old-client-eth1 old-client-eth2; do
    count="$(grep -Ec "^label=${label}[[:space:]]" \
      "${M03_EVIDENCE_DIR}/capture-status.txt" || true)"
    [[ "${count}" -eq 1 ]] \
      || fail "estado da captura ${label} ausente ou duplicado"
    line="$(grep -E "^label=${label}[[:space:]]" \
      "${M03_EVIDENCE_DIR}/capture-status.txt")"
    [[ "${line}" == *'alive_after_probe=1'* ]] \
      || fail "captura ${label} não permaneceu viva durante o probe"
    wait_rc="$(sed -n "s/.*wait_rc=\\([0-9][0-9]*\\).*/\\1/p" <<<"${line}")"
    case "${wait_rc}" in
      0|124|130|143) ;;
      *) fail "captura ${label} terminou com rc inesperado: ${wait_rc:-ausente}" ;;
    esac
  done
}

capture_positive_path_snapshot() {
  local phase="$1" neigh_file fdb_file bridge_link_file vxlan_link_file
  local status_file failed=0
  case "${phase}" in
    before|after) ;;
    *) fail "fase de snapshot diagnóstico inválida: ${phase}" ;;
  esac

  status_file="${M03_EVIDENCE_DIR}/positive-diagnostic-snapshots.txt"
  neigh_file="${M03_EVIDENCE_DIR}/positive-diagnostic-ip-neigh-${phase}.txt"
  fdb_file="${M03_EVIDENCE_DIR}/positive-diagnostic-bridge-fdb-${phase}.txt"
  bridge_link_file="${M03_EVIDENCE_DIR}/positive-diagnostic-link-bridge-${phase}.txt"
  vxlan_link_file="${M03_EVIDENCE_DIR}/positive-diagnostic-link-vxlan-${phase}.txt"

  if ! timeout "${M03_COMMAND_TIMEOUT}" docker exec "${M03_CHASSIS}" \
    ip neigh show dev "${M03_TENANT_BR}" >"${neigh_file}" 2>&1; then
    printf 'phase=%s ip_neigh=ERROR\n' "$phase" >>"$status_file"
    failed=1
  fi
  if ! timeout "${M03_COMMAND_TIMEOUT}" docker exec "${M03_CHASSIS}" \
    bridge fdb show dev "${M03_TENANT_VXLAN}" >"${fdb_file}" 2>&1; then
    printf 'phase=%s bridge_fdb=ERROR\n' "$phase" >>"$status_file"
    failed=1
  fi
  if ! timeout "${M03_COMMAND_TIMEOUT}" docker exec "${M03_CHASSIS}" \
    ip -d link show dev "${M03_TENANT_BR}" >"${bridge_link_file}" 2>&1; then
    printf 'phase=%s bridge_link=ERROR\n' "$phase" >>"$status_file"
    failed=1
  fi
  if ! timeout "${M03_COMMAND_TIMEOUT}" docker exec "${M03_CHASSIS}" \
    ip -d link show dev "${M03_TENANT_VXLAN}" >"${vxlan_link_file}" 2>&1; then
    printf 'phase=%s vxlan_link=ERROR\n' "$phase" >>"$status_file"
    failed=1
  fi
  printf 'phase=%s snapshot_status=%s\n' "$phase" "$([[ "$failed" -eq 0 ]] && echo PASS || echo PARTIAL)" \
    >>"$status_file"
  return 0
}

summarize_positive_path_diagnostics() {
  local bridge_capture vxlan_capture bridge_replies vxlan_replies classification
  bridge_capture="${M03_EVIDENCE_DIR}/capture-chassis-tenant-bridge.txt"
  vxlan_capture="${M03_EVIDENCE_DIR}/capture-chassis-tenant-vxlan.txt"
  if ! grep -Fq "listening on ${M03_TENANT_BR}" "$bridge_capture" 2>/dev/null \
    || ! grep -Fq "listening on ${M03_TENANT_VXLAN}" "$vxlan_capture" 2>/dev/null; then
    printf 'classification=DIAGNOSTIC_UNAVAILABLE\n' \
      >"${M03_EVIDENCE_DIR}/positive-path-diagnostic-summary.txt"
    return 0
  fi
  bridge_replies="$(grep -Ec "${M03_REPLY_RE}" "${bridge_capture}" || true)"
  vxlan_replies="$(grep -Ec "${M03_REPLY_RE}" "${vxlan_capture}" || true)"
  if [[ "${bridge_replies}" -eq 0 ]]; then
    classification='no-reply-on-bridge'
  elif [[ "${vxlan_replies}" -eq 0 ]]; then
    classification='reply-on-bridge-missing-on-vxlan'
  else
    classification='reply-observed-on-bridge-and-vxlan'
  fi
  printf 'bridge_reply_lines=%s\nvxlan_reply_lines=%s\nclassification=%s\n' \
    "${bridge_replies}" "${vxlan_replies}" "${classification}" \
    >"${M03_EVIDENCE_DIR}/positive-path-diagnostic-summary.txt"
}

run_ping() {
  local output rc=0
  capture_positive_path_snapshot before || true
  start_captures
  output="$(docker exec "${M03_PEER}" ip vrf exec "${M03_CLIENT_VRF}" \
    ping -I "${M03_PEER_SOURCE}" -c 30 -i 0.1 -W 2 "${M03_TENANT_IP}" 2>&1)" || rc=$?
  printf '%s\n' "${output}" >"${M03_EVIDENCE_DIR}/ping.txt"
  if ! stop_captures; then cleanup_rc=1; fi
  if [[ "${rc}" -ne 0 \
    || ! "${output}" =~ 30[[:space:]]+packets[[:space:]]+transmitted,[[:space:]]+30[[:space:]]+(packets[[:space:]]+)?received,[[:space:]]+0%[[:space:]]+packet[[:space:]]+loss ]]; then
    capture_positive_path_snapshot after || true
    assert_capture_lifecycle
    summarize_positive_path_diagnostics
    fail 'peer-client não obteve ping 30/30 para a VM tenant'
  fi
  assert_capture_lifecycle

  local chassis_capture peer_capture peer_tenant_capture tenant_tap_capture
  local old1_capture old2_capture
  chassis_capture="${M03_EVIDENCE_DIR}/capture-chassis-underlay.txt"
  peer_capture="${M03_EVIDENCE_DIR}/capture-peer-underlay.txt"
  peer_tenant_capture="${M03_EVIDENCE_DIR}/capture-peer-tenant.txt"
  tenant_tap_capture="${M03_EVIDENCE_DIR}/capture-tenant-tap.txt"
  old1_capture="${M03_EVIDENCE_DIR}/capture-old-client-eth1.txt"
  old2_capture="${M03_EVIDENCE_DIR}/capture-old-client-eth2.txt"
  assert_underlay_capture "${chassis_capture}" chassis-underlay
  assert_underlay_capture "${peer_capture}" peer-underlay
  assert_probe_capture "${peer_tenant_capture}" peer-tenant
  assert_probe_capture "${tenant_tap_capture}" tenant-tap
  assert_no_probe_packets "${old1_capture}" old-client-eth1
  assert_no_probe_packets "${old2_capture}" old-client-eth2
}

assert_frr_pathspace_stopped() {
  local node="$1" pathspace="$2" active
  if ! active="$(docker exec "${node}" sh -c '
    set -eu
    pathspace="$1"
    for daemon in zebra bgpd staticd; do
      for pid in $(pidof "${daemon}" 2>/dev/null || true); do
        cmdline="$(tr "\\000" " " <"/proc/${pid}/cmdline" 2>/dev/null || true)"
        case "${cmdline}" in
          *"-N ${pathspace}"*|*"/run/frr/${pathspace}"*)
            printf "%s:%s\\n" "${daemon}" "${pid}"
            exit 1
            ;;
        esac
      done
    done
    for pidfile in "/run/frr/${pathspace}"/*.pid; do
      [ -e "${pidfile}" ] || continue
      pid="$(cat "${pidfile}" 2>/dev/null || true)"
      if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
        printf "%s:%s\\n" "${pidfile}" "${pid}"
        exit 1
      fi
    done
  ' sh "${pathspace}" 2>&1)"; then
    say "não foi possível verificar FRR pathspace ${pathspace} em ${node}: ${active}" >&2
    return 1
  fi
  [[ -z "${active}" ]] || {
    say "daemons FRR ainda ativos no pathspace ${pathspace}: ${active}" >&2
    return 1
  }
}

stop_frr_pathspace() {
  local node="$1" socket_dir="$2" pathspace="$3" init
  local active
  if ! active="$(docker exec "${node}" sh -c '
    for daemon in zebra bgpd staticd; do
      for pid in $(pidof "${daemon}" 2>/dev/null || true); do
        cmdline="$(tr "\\000" " " <"/proc/${pid}/cmdline" 2>/dev/null || true)"
        case "${cmdline}" in
          *"-N $1"*|*"/run/frr/$1"*) printf "%s:%s\\n" "${daemon}" "${pid}" ;;
        esac
      done
    done
  ' sh "${pathspace}" 2>&1)"; then
    say "não foi possível inspecionar FRR pathspace ${pathspace} em ${node}: ${active}" >&2
    return 1
  fi
  # A failed or partial prepare may leave the directory without starting a
  # daemon.  In that case it is safe to remove the directory without calling
  # frrinit; if a daemon exists, stop must succeed before any deletion.
  if [[ -n "${active}" ]]; then
  init="$(docker exec "${node}" sh -c \
    'for c in /usr/libexec/frr/frrinit.sh /usr/lib/frr/frrinit.sh; do [ -x "$c" ] && { echo "$c"; exit 0; }; done; exit 1' \
    2>/dev/null || true)"
  [[ -n "${init}" ]] || {
    say "frrinit.sh ausente ao parar ${pathspace} em ${node}" >&2
    return 1
  }
  docker exec "${node}" "${init}" stop "${pathspace}" >/dev/null 2>&1 \
    || { say "frrinit stop ${pathspace} falhou em ${node}" >&2; return 1; }
  fi
  assert_frr_pathspace_stopped "${node}" "${pathspace}" || return 1
  docker exec "${node}" rm -rf "${socket_dir}" "/etc/frr/${pathspace}" \
    || { say "remoção dos arquivos FRR ${pathspace} falhou em ${node}" >&2; return 1; }
  if docker exec "${node}" test -e "${socket_dir}" 2>/dev/null \
    || docker exec "${node}" test -e "/etc/frr/${pathspace}" 2>/dev/null; then
    say "arquivos FRR ${pathspace} ainda existem em ${node}" >&2
    return 1
  fi
}

stop_client_frr() {
  local init active
  if ! active="$(docker exec "${M03_PEER}" sh -c '
    for daemon in zebra bgpd staticd; do
      pids="$(pidof "${daemon}" 2>/dev/null || true)"
      [ -z "${pids}" ] || printf "%s:%s\\n" "${daemon}" "${pids}"
    done
  ' 2>&1)"; then
    say "não foi possível inspecionar FRR do peer: ${active}" >&2
    return 1
  fi
  # start_client_frr sets its guard before staging.  No daemon means there is
  # nothing to stop when staging failed before the init script was invoked.
  [[ -z "${active}" ]] && return 0
  init="$(docker exec "${M03_PEER}" sh -c \
    'for c in /usr/libexec/frr/frrinit.sh /usr/lib/frr/frrinit.sh; do [ -x "$c" ] && { echo "$c"; exit 0; }; done; exit 1' \
    2>/dev/null || true)"
  [[ -n "${init}" ]] || {
    say "frrinit.sh ausente ao parar FRR do peer" >&2
    return 1
  }
  docker exec "${M03_PEER}" "${init}" stop >/dev/null 2>&1 \
    || { say 'frrinit stop falhou no peer' >&2; return 1; }
  if ! active="$(docker exec "${M03_PEER}" sh -c '
    for daemon in zebra bgpd staticd; do
      pids="$(pidof "${daemon}" 2>/dev/null || true)"
      [ -z "${pids}" ] || { printf "%s:%s\\n" "${daemon}" "${pids}"; exit 1; }
    done
  ' 2>&1)"; then
    say "daemons FRR ainda ativos no peer: ${active}" >&2
    return 1
  fi
  [[ -z "${active}" ]] || {
    say "verificação FRR do peer retornou estado inesperado: ${active}" >&2
    return 1
  }
}

restore_lrp() {
  local options
  [[ "${M03_LRP_CHANGED}" -eq 1 ]] || return 0
  if [[ "${M03_OLD_LRP_OPTIONS}" == *dynamic-routing-maintain-vrf* ]]; then
    cleanup_rc=1
    say 'não restaurando options do LRP: baseline continha chave inesperada' >&2
    return 1
  fi
  if docker exec "${M03_CENTRAL}" ovn-nbctl --wait=sb remove \
    logical_router_port "${M03_LRP}" options dynamic-routing-maintain-vrf \
    >/dev/null 2>&1; then
    if ! options="$(docker exec "${M03_CENTRAL}" ovn-nbctl \
      get logical_router_port "${M03_LRP}" options 2>&1)"; then
      cleanup_rc=1
      say "não foi possível confirmar options restauradas de ${M03_LRP}: ${options}" >&2
      return 1
    fi
    if grep -Fq dynamic-routing-maintain-vrf <<<"${options}"; then
      cleanup_rc=1
      say "${M03_LRP} ainda tem dynamic-routing-maintain-vrf após cleanup" >&2
      return 1
    fi
    M03_LRP_CHANGED=0
    return 0
  fi
  cleanup_rc=1
  say "não foi possível restaurar options de ${M03_LRP}" >&2
  return 1
}

remove_owned_link() {
  local node="$1" link="$2" created="$3" alias_set="$4" actual_alias
  [[ "${created}" -eq 1 ]] || return 0
  if ! docker exec "${node}" ip link show "${link}" >/dev/null 2>&1; then
    return 0
  fi
  actual_alias="$(docker exec "${node}" ip -details link show "${link}" 2>/dev/null \
    | grep -Eo 'alias [^[:space:]]+' | head -n 1 | awk '{print $2}' || true)"
  if [[ "${alias_set}" -ne 1 \
    || "${actual_alias}" != "labctl-m03-${M03_RUN_TOKEN}" ]]; then
    say "não removendo ${node}:${link}: alias não pertence a esta execução" >&2
    return 1
  fi
  if ! docker exec "${node}" ip link del "${link}" >/dev/null 2>&1; then
    say "remoção de ${node}:${link} falhou" >&2
    return 1
  fi
  if docker exec "${node}" ip link show "${link}" >/dev/null 2>&1; then
    say "${node}:${link} ainda existe após remoção" >&2
    return 1
  fi
}

remove_links() {
  local client_links_rc=0 chassis_links_rc=0
  if [[ "${M03_CLIENT_LINKS_CREATED}" -eq 1 ]] \
    && { [[ -z "${M03_CLIENT_ID}" ]] \
      || [[ "$(docker inspect -f '{{.Id}}' "${M03_PEER}" 2>/dev/null || true)" != "${M03_CLIENT_ID}" ]]; }; then
    client_links_rc=1
    cleanup_rc=1
    say 'peer M03 mudou de ID; links e container serão preservados' >&2
  fi
  if [[ "${M03_CLIENT_LINKS_CREATED}" -eq 1 ]] \
    && [[ -n "${M03_CLIENT_ID}" ]] \
    && [[ "$(docker inspect -f '{{.Id}}' "${M03_PEER}" 2>/dev/null || true)" == "${M03_CLIENT_ID}" ]]; then
    remove_owned_link "${M03_PEER}" "${M03_CLIENT_ADVERTISE}" \
      "${M03_CLIENT_ADVERTISE_CREATED}" "${M03_CLIENT_ADVERTISE_ALIAS}" \
      || client_links_rc=1
    remove_owned_link "${M03_PEER}" "${M03_CLIENT_VXLAN}" \
      "${M03_CLIENT_VXLAN_CREATED}" "${M03_CLIENT_VXLAN_ALIAS}" \
      || client_links_rc=1
    remove_owned_link "${M03_PEER}" "${M03_CLIENT_BR}" \
      "${M03_CLIENT_BR_CREATED}" "${M03_CLIENT_BR_ALIAS}" \
      || client_links_rc=1
    remove_owned_link "${M03_PEER}" "${M03_CLIENT_VRF}" \
      "${M03_CLIENT_VRF_CREATED}" "${M03_CLIENT_VRF_ALIAS}" \
      || client_links_rc=1
    if [[ "${client_links_rc}" -eq 0 ]]; then
      M03_CLIENT_LINKS_CREATED=0
    else
      cleanup_rc=1
    fi
  fi
  if [[ "${M03_CHASSIS_LINKS_CREATED}" -eq 1 ]]; then
    remove_owned_link "${M03_CHASSIS}" "${M03_TENANT_ADVERTISE}" \
      "${M03_TENANT_ADVERTISE_CREATED}" "${M03_TENANT_ADVERTISE_ALIAS}" \
      || chassis_links_rc=1
    remove_owned_link "${M03_CHASSIS}" "${M03_TENANT_VXLAN}" \
      "${M03_TENANT_VXLAN_CREATED}" "${M03_TENANT_VXLAN_ALIAS}" \
      || chassis_links_rc=1
    remove_owned_link "${M03_CHASSIS}" "${M03_TENANT_BR}" \
      "${M03_CHASSIS_BR_CREATED}" "${M03_CHASSIS_BR_ALIAS}" \
      || chassis_links_rc=1
    if [[ "${chassis_links_rc}" -eq 0 ]]; then
      M03_CHASSIS_LINKS_CREATED=0
    else
      cleanup_rc=1
    fi
  fi
  [[ "${client_links_rc}" -eq 0 && "${chassis_links_rc}" -eq 0 ]]
}

remove_client_port() {
  [[ "${M03_CLIENT_PORT_CREATED}" -eq 1 ]] || return 0
  local id label profile_owner port bridge port_uuid interface_uuid host_iface owner attempt
  local identity_recorded=1
  [[ -n "${M03_CLIENT_PORT_UUID}" && -n "${M03_CLIENT_INTERFACE_UUID}" \
    && -n "${M03_CLIENT_HOST_IFACE}" ]] || identity_recorded=0
  id="$(docker inspect -f '{{.Id}}' "${M03_PEER}" 2>/dev/null || true)"
  label="$(docker inspect -f "{{index .Config.Labels \"${M03_OWNER_LABEL}\"}}" \
    "${M03_PEER}" 2>/dev/null || true)"
  profile_owner="$(docker inspect -f '{{index .Config.Labels "labctl.mgc.owner"}}' \
    "${M03_PEER}" 2>/dev/null || true)"
  port="${M03_CLIENT_PORT_NAME:-}"
  [[ -n "${port}" ]] || port="$(mgc_ovs_port "${M03_PEER}" eth1 || true)"
  if [[ -z "${port}" ]]; then
    if [[ -n "${M03_CLIENT_HOST_IFACE}" ]] \
      && ip link show "${M03_CLIENT_HOST_IFACE}" >/dev/null 2>&1; then
      cleanup_rc=1
      say "porta OVS ausente mas interface host ${M03_CLIENT_HOST_IFACE} ainda existe" >&2
      return 1
    fi
    M03_CLIENT_PORT_CREATED=0
    return 0
  fi
  bridge="$(ovs-vsctl port-to-br "${port}" 2>/dev/null || true)"
  port_uuid="$(ovs-vsctl get Port "${port}" _uuid 2>/dev/null | tr -d '"' || true)"
  interface_uuid="$(ovs-vsctl get Port "${port}" interfaces 2>/dev/null \
    | tr -d '[]"' || true)"
  host_iface="$(ovs-vsctl get Interface "${interface_uuid}" name 2>/dev/null \
    | tr -d '"' || true)"
  owner="$(ovs-vsctl get Interface "${host_iface}" \
    external_ids:labctl-m03-owner 2>/dev/null | tr -d '"' || true)"
  if [[ "${label}" != "labctl-m03-${M03_RUN_TOKEN}" \
    || "${profile_owner}" != "${M03_OWNER_TOKEN}" \
    || ( -n "${M03_CLIENT_ID}" && "${id}" != "${M03_CLIENT_ID}" ) \
    || "${bridge}" != br-ovn \
    || -z "${port_uuid}" || -z "${interface_uuid}" || -z "${host_iface}" \
    || ( "${identity_recorded}" -eq 1 \
      && ( "${port_uuid}" != "${M03_CLIENT_PORT_UUID}" \
        || "${interface_uuid}" != "${M03_CLIENT_INTERFACE_UUID}" \
        || "${host_iface}" != "${M03_CLIENT_HOST_IFACE}" ) ) \
    || ( -n "${owner}" && "${owner}" != "labctl-m03-${M03_RUN_TOKEN}" ) ]]; then
    cleanup_rc=1
    say 'peer/porta não correspondem ao ID e label criados; não removendo' >&2
    return 1
  fi
  # A signal can interrupt immediately after ovs-runc creates the Port and
  # before the UUID fields are copied into shell state.  The exact container
  # label/ID, br-ovn membership, and container/interface lookup above still
  # prove ownership; record the observed identity before deleting it.
  M03_CLIENT_PORT_NAME="${port}"
  M03_CLIENT_PORT_UUID="${port_uuid}"
  M03_CLIENT_INTERFACE_UUID="${interface_uuid}"
  M03_CLIENT_HOST_IFACE="${host_iface}"
  env RUNC_CMD="${RUNC_CMD}" "${MGC_FAKE_MN}/ovs-runc" \
    del-port br-ovn eth1 "${M03_PEER}" >/dev/null 2>&1 || cleanup_rc=1
  for attempt in $(seq 1 15); do
    if ! ovs-vsctl port-to-br "${port}" >/dev/null 2>&1; then
      if [[ -z "${M03_CLIENT_HOST_IFACE}" ]] \
        || ! ip link show "${M03_CLIENT_HOST_IFACE}" >/dev/null 2>&1; then
        M03_CLIENT_PORT_CREATED=0
        return 0
      fi
    fi
    sleep 1
  done
  cleanup_rc=1
  say "porta OVS ${port}/${M03_CLIENT_PORT_UUID} ou interface ${M03_CLIENT_HOST_IFACE} ainda existe" >&2
  return 1
}

remove_client_container() {
  [[ "${M03_CLIENT_CREATED}" -eq 1 ]] || return 0
  local id label profile_owner
  id="$(docker inspect -f '{{.Id}}' "${M03_PEER}" 2>/dev/null || true)"
  [[ -z "${id}" ]] && return 0
  label="$(docker inspect -f "{{index .Config.Labels \"${M03_OWNER_LABEL}\"}}" \
    "${M03_PEER}" 2>/dev/null || true)"
  profile_owner="$(docker inspect -f '{{index .Config.Labels "labctl.mgc.owner"}}' \
    "${M03_PEER}" 2>/dev/null || true)"
  if [[ "${label}" != "labctl-m03-${M03_RUN_TOKEN}" \
    || "${profile_owner}" != "${M03_OWNER_TOKEN}" \
    || ( -n "${M03_CLIENT_ID}" && "${id}" != "${M03_CLIENT_ID}" ) ]]; then
    cleanup_rc=1
    say 'não removendo peer: ID/label não correspondem ao recurso criado' >&2
    return 1
  fi
  if docker rm -f "${M03_PEER}" >/dev/null 2>&1; then
    M03_CLIENT_CREATED=0
  else
    cleanup_rc=1
    say "remoção do peer ${M03_PEER} falhou" >&2
    return 1
  fi
}

assert_post_rollback() {
  local lrp_options ls_options link state port_mapping
  lrp_options="$(docker exec "${M03_CENTRAL}" ovn-nbctl \
    get logical_router_port "${M03_LRP}" options 2>/dev/null || true)"
  [[ "$lrp_options" != *dynamic-routing-maintain-vrf* \
    && "$lrp_options" != *"$M03_LRP_REDISTRIBUTE_KEY"* \
    && "$lrp_options" != *dynamic-routing-port-name* ]] \
    || { cleanup_rc=1; say 'LRP ainda tem uma option temporária após rollback' >&2; }
  if ! port_mapping="$(mgc_m03_chassis_port_mapping)"; then
    cleanup_rc=1
    say 'não foi possível ler mapping após rollback' >&2
  elif [[ -n "$port_mapping" ]]; then
    cleanup_rc=1
    say 'chassis ainda tem mapping temporário após rollback' >&2
  fi
  ls_options="$(docker exec "${M03_CENTRAL}" ovn-nbctl \
    get logical_switch "${M03_TENANT_LS}" other_config 2>/dev/null || true)"
  grep -Eq 'dynamic-routing-vni="?50100"?' <<<"${ls_options}" \
    || { cleanup_rc=1; say 'dynamic-routing-vni=50100 não foi restaurado' >&2; }
  if [[ "${M03_INTERNAL_PHASE}" != up ]]; then
    [[ ! -e "${M03_MARKER_FILE}" ]] \
      || { cleanup_rc=1; say 'marker M03 ainda existe após rollback' >&2; }
  fi
  [[ "$(mgc_count_named "${M03_PEER}")" -eq 0 ]] \
    || { cleanup_rc=1; say 'peer M03 ainda existe após rollback' >&2; }
  if [[ -n "${M03_CLIENT_HOST_IFACE}" ]] \
    && ip link show "${M03_CLIENT_HOST_IFACE}" >/dev/null 2>&1; then
    cleanup_rc=1
    say "interface host ${M03_CLIENT_HOST_IFACE} ainda existe após rollback" >&2
  fi
  for link in "${M03_TENANT_BR}" "${M03_TENANT_VXLAN}" \
    "${M03_TENANT_ADVERTISE}" "${M03_TENANT_VRF}"; do
    if docker exec "${M03_CHASSIS}" ip link show "${link}" >/dev/null 2>&1; then
      cleanup_rc=1
      say "dispositivo ${link} ainda existe após rollback" >&2
    fi
  done
  state="$(docker inspect -f '{{.State.Status}}' p003-os 2>/dev/null || true)"
  [[ "${state}" == exited ]] \
    || { cleanup_rc=1; say "p003-os deixou de estar exited: ${state}" >&2; }
  if ! cmp -s "${M03_PREFLIGHT_RECEIPT}" \
    "${M03_EVIDENCE_DIR}/preflight-receipt.txt"; then
    cleanup_rc=1
    say 'recibo de preflight mudou durante o ensaio' >&2
  fi
}

load_marker_context() {
  local marker_run marker_owner
  mgc_m03_marker_valid \
    || fail 'marker M03 ausente ou inválido durante a fase lifecycle'
  marker_run="$(sed -n 's/^run_token=//p' "${M03_MARKER_FILE}")"
  marker_owner="$(sed -n 's/^token=//p' "${M03_MARKER_FILE}")"
  [[ -n "${marker_run}" && "${marker_owner}" == "labctl-m03-${marker_run}" ]] \
    || fail 'token do marker M03 não corresponde ao run_token'
  M03_RUN_TOKEN="${marker_run}"
  M03_MARKER_TOKEN="${marker_owner}"
  M03_OWNER_TOKEN="$(state_get "${LAB_NAME}" owner_token 2>/dev/null || true)"
  [[ -n "${M03_OWNER_TOKEN}" ]] \
    || fail 'token de ownership MGC ausente durante a fase M03'
  export M03_RUN_TOKEN
}

phase_up_entrypoint() {
  preflight
  if [[ "${DRY_RUN}" == "1" ]]; then
    print_plan
    return 0
  fi
  prepare_phase_evidence
  persist_m03_marker
  M03_EXECUTION_STARTED=1
  trap cleanup EXIT
  trap 'm03_signal INT' INT
  trap 'm03_signal TERM' TERM
  say 'fase up: registrar baseline e habilitar maintain-vrf temporário'
  docker exec "${M03_CENTRAL}" ovn-nbctl get logical_router_port "${M03_LRP}" options \
    >"${M03_EVIDENCE_DIR}/nb-lrp-before.txt" 2>&1
  set_lrp_maintain_vrf
  create_chassis_links
  set_return_route_filter
  create_peer_container
  create_peer_links
  start_chassis_frr
  start_client_frr
  wait_for_bgp
  printf 'phase=up\nstatus=ready-for-verify\n' \
    >"${M03_EVIDENCE_DIR}/phase-up.txt"
  M03_EXECUTION_STARTED=0
  trap - EXIT INT TERM
  say 'fase M03 up concluída; recursos owned permanecem para verify/ping'
}

wait_for_return_route_scope() {
  local target_pb ids id nexthop logical_port attempt count matched evidence
  local -a route_ids=()
  evidence="${M03_EVIDENCE_DIR}/${M03_VERIFY_PHASE}-return-learned-routes.txt"
  target_pb="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_CENTRAL" \
    ovn-sbctl --bare --no-headings --columns=_uuid find Port_Binding \
    "logical_port=${M03_LRP}")" \
    || fail 'Port_Binding da LRP tenant não pôde ser consultado'
  target_pb="$(tr -d '[:space:]' <<<"$target_pb")"
  [[ "$target_pb" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
    || fail 'Port_Binding da LRP tenant não é único/válido'
  : >"$evidence"
  for attempt in $(seq 1 30); do
    ids="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_CENTRAL" \
      ovn-sbctl --bare --no-headings --columns=_uuid find Learned_Route \
      "ip_prefix=${M03_PEER_SOURCE}")" \
      || fail 'Learned_Route do peer não pôde ser consultada'
    route_ids=()
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      [[ "$id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
        || fail "UUID Learned_Route inválido: $id"
      route_ids+=("$id")
    done <<<"$ids"
    count="${#route_ids[@]}"
    matched=0
    printf 'attempt=%s count=%s\n' "$attempt" "$count" >>"$evidence"
    for id in "${route_ids[@]}"; do
      nexthop="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_CENTRAL" \
        ovn-sbctl get Learned_Route "$id" nexthop)" \
        || fail "nexthop Learned_Route $id não pôde ser lido"
      logical_port="$(timeout "$M03_COMMAND_TIMEOUT" docker exec "$M03_CENTRAL" \
        ovn-sbctl get Learned_Route "$id" logical_port)" \
        || fail "logical_port Learned_Route $id não pôde ser lido"
      nexthop="$(tr -d '"[:space:]' <<<"$nexthop")"
      logical_port="$(tr -d '"[:space:]' <<<"$logical_port")"
      printf 'route=%s nexthop=%s logical_port=%s\n' \
        "$id" "$nexthop" "$logical_port" >>"$evidence"
      if [[ "$nexthop" == "$M03_PEER_IP" \
        && "$logical_port" == "$target_pb" ]]; then
        matched=$((matched + 1))
      fi
    done
    if [[ "$count" -eq 1 && "$matched" -eq 1 ]]; then
      printf 'result=PASS\n' >>"$evidence"
      return 0
    fi
    sleep 2
  done
  printf 'result=FAIL\n' >>"$evidence"
  fail "Learned_Route de ${M03_PEER_SOURCE} não ficou exclusiva de ${M03_LRP}"
}

phase_verify_entrypoint() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    print_plan
    return 0
  fi
  load_marker_context
  mgc_m03_assert_active
  [[ -d "${M03_EVIDENCE_DIR}" ]] \
    || fail "diretório de evidência da fase ausente: ${M03_EVIDENCE_DIR}"
  wait_for_route_convergence "${M03_VERIFY_PHASE}"
  wait_for_return_route_scope
  printf 'phase=%s\nstatus=verified\n' "${M03_VERIFY_PHASE}" \
    >"${M03_EVIDENCE_DIR}/${M03_VERIFY_PHASE}-status.txt"
}

normal_entrypoint() {
  preflight
  if [[ "${DRY_RUN}" == "1" ]]; then
    print_plan
    return 0
  fi

  prepare_evidence
  M03_MARKER_TOKEN="labctl-m03-${M03_RUN_TOKEN}"
  export M03_EVIDENCE_DIR M03_RUN_TOKEN
  M03_EXECUTION_STARTED=1
  trap cleanup EXIT
  trap 'm03_signal INT' INT
  trap 'm03_signal TERM' TERM

  say 'labctl mgc up --m03: baseline e fase M03 owned'
  "${LAB_ROOT}/labctl" mgc up --m03 \
    --evidence "${M03_EVIDENCE_DIR}/lifecycle-up" \
    || fail 'labctl mgc up --m03 falhou'
  say 'labctl mgc verify --m03: gate positivo antes do controle negativo'
  "${LAB_ROOT}/labctl" mgc verify --m03 \
    --evidence "${M03_EVIDENCE_DIR}/positive-pre-negative" \
    || fail 'labctl mgc verify --m03 falhou antes do controle negativo'

  run_ping
  say 'labctl mgc verify --m03: gate após o probe ICMP'
  "$LAB_ROOT/labctl" mgc verify --m03 \
    --evidence "$M03_EVIDENCE_DIR/positive-post-ping" \
    || fail 'labctl mgc verify --m03 falhou após o probe ICMP'

  M03_POSITIVE_GATES_COMPLETE=1
  say 'controle negativo causal: remover connected somente em lrp-mgc-tenant'
  run_negative_causal
  [[ "$M03_NEGATIVE_CONTROL_STATUS" == PASS ]] \
    || fail 'controle negativo causal não passou'
  M03_ALL_GATES_COMPLETE=1
  return 0
}

cleanup_phase_up_direct() {
  local lrp_restored=0 frr_stopped=1
  if ! (mgc_m03_validate_return_filter_owned); then
    cleanup_rc=1
    say 'filtro de retorno divergiu; recursos M03 e marker preservados' >&2
    check_historical_canaries post || cleanup_rc=1
    return 1
  fi
  if [[ "${M03_CHASSIS_FRR_STARTED}" -eq 1 ]]; then
    if stop_frr_pathspace "${M03_CHASSIS}" /run/frr/m03 m03; then
      M03_CHASSIS_FRR_STARTED=0
    else
      cleanup_rc=1
      frr_stopped=0
    fi
  fi
  if [[ "${M03_CLIENT_FRR_STARTED}" -eq 1 ]]; then
    if stop_client_frr; then
      M03_CLIENT_FRR_STARTED=0
    else
      cleanup_rc=1
      frr_stopped=0
    fi
  fi
  if [[ "${frr_stopped}" -eq 0 ]]; then
    say 'FRR M03 ainda pode estar ativo; links, VRF, porta, peer e marker preservados' >&2
    check_historical_canaries post || cleanup_rc=1
    return 1
  fi
  if ! (mgc_m03_restore_return_filter); then
    cleanup_rc=1
    say 'filtro de retorno não foi restaurado; recursos M03 e marker preservados' >&2
    check_historical_canaries post || cleanup_rc=1
    return 1
  fi
  if restore_lrp; then
    lrp_restored=1
  else
    cleanup_rc=1
  fi
  if ! remove_links; then
    cleanup_rc=1
    say 'links M03 não foram removidos com segurança; VRF, porta, peer e marker preservados' >&2
    check_historical_canaries post || cleanup_rc=1
    return 1
  fi
  if [[ "${lrp_restored}" -eq 1 ]]; then
    mgc_m03_remove_tenant_vrf || cleanup_rc=1
  else
    cleanup_rc=1
    say 'VRF tenant preservado: LRP não foi restaurado com sucesso' >&2
  fi
  remove_client_port || cleanup_rc=1
  if [[ "${M03_CLIENT_PORT_CREATED}" -eq 0 ]]; then
    remove_client_container || cleanup_rc=1
  else
    cleanup_rc=1
    say 'peer não será removido enquanto a porta OVS não for verificada como ausente' >&2
  fi
  check_historical_canaries post || cleanup_rc=1
  assert_post_rollback || cleanup_rc=1
  if [[ "${cleanup_rc}" -eq 0 && -e "${M03_MARKER_FILE}" ]] \
    && ! mgc_m03_physical_resource_present; then
    mgc_m03_remove_marker "${M03_MARKER_TOKEN}" || {
      cleanup_rc=1
      say 'marker M03 não foi removido após rollback da fase up' >&2
    }
  fi
}

cleanup() {
  local original_rc=$? cleanup_rc=0 lrp_restore_ok=1
  trap - EXIT INT TERM
  if ! stop_captures; then cleanup_rc=1; fi
  if ! restore_lrp_redistribute; then
    lrp_restore_ok=0
    cleanup_rc=1
    say 'não foi possível restaurar a chave temporária da LRP no trap' >&2
  fi
  if [[ "${M03_EXECUTION_STARTED}" -eq 1 \
    && "${lrp_restore_ok}" -eq 1 \
    && "${M03_CAUSAL_SET_ATTEMPTED}" -eq 1 \
    && "${M03_NORMAL_RECOVERY_COMPLETE}" -eq 0 ]]; then
    say 'rollback: verificando recuperação EVPN limitada antes do teardown'
    if ! attempt_cleanup_recovery; then
      cleanup_rc=1
      say 'recuperação EVPN do trap falhou; teardown M03 seguirá porque a option da LRP foi restaurada' >&2
    fi
  fi
  if [[ "${M03_EXECUTION_STARTED}" -eq 1 \
    && "${lrp_restore_ok}" -eq 0 ]]; then
    say 'recuperação manual necessária: LRP não confirmada; recursos M03 e marker foram preservados' >&2
    check_historical_canaries post || cleanup_rc=1
  elif [[ "${M03_EXECUTION_STARTED}" -eq 1 ]]; then
    if [[ "${M03_INTERNAL_PHASE}" == up ]]; then
      say 'rollback da fase up: FRR temporário, links e peer'
      cleanup_phase_up_direct || cleanup_rc=1
    else
      if mgc_m03_resource_present; then
        say 'rollback: labctl mgc down --m03 e restauração do baseline'
        "${LAB_ROOT}/labctl" mgc down --m03 \
          --evidence "${M03_EVIDENCE_DIR}/rollback-down" \
          >/dev/null 2>&1 || cleanup_rc=1
      else
        say 'rollback M03 omitido: fase up não deixou marker ou recurso owned'
      fi
      # The M03 marker must be gone before ordinary MGC reconciliation.  Do
      # not invoke default up/verify while any owned or marker residue remains.
      if mgc_m03_resource_present; then
        cleanup_rc=1
        say 'baseline up/verify omitidos: marker ou resíduo M03 ainda presente' >&2
      else
        "${LAB_ROOT}/labctl" mgc up \
          --evidence "${M03_EVIDENCE_DIR}/rollback-up" \
          >/dev/null 2>&1 || cleanup_rc=1
        "${LAB_ROOT}/labctl" mgc verify \
          --evidence "${M03_EVIDENCE_DIR}/rollback-verify" \
          >/dev/null 2>&1 || cleanup_rc=1
        check_historical_canaries post || cleanup_rc=1
      fi
      assert_post_rollback || cleanup_rc=1
      if mgc_m03_resource_present; then
        cleanup_rc=1
        say 'resíduo M03 ainda detectado após labctl mgc down --m03' >&2
      fi
    fi
  fi
  if [[ -n "${M03_EVIDENCE_DIR}" ]]; then
    {
      echo "original_rc=${original_rc}"
      echo "cleanup_rc=${cleanup_rc}"
      echo "positive_gates_complete=${M03_POSITIVE_GATES_COMPLETE}"
      echo "all_gates_complete=${M03_ALL_GATES_COMPLETE}"
      echo "negative_control_status=${M03_NEGATIVE_CONTROL_STATUS}"
      echo "negative_causal_result=$M03_NEGATIVE_CAUSAL_RESULT"
      echo "lrp_redistribute_confirmed=${M03_LRP_REDISTRIBUTE_CONFIRMED}"
      echo "normal_recovery_complete=${M03_NORMAL_RECOVERY_COMPLETE}"
      echo "cleanup_recovery_result=${M03_CLEANUP_RECOVERY_RESULT}"
      echo "m03_run_token=${M03_RUN_TOKEN}"
      echo "m03_marker_token=${M03_MARKER_TOKEN}"
      echo "mgc_owner_token=${M03_OWNER_TOKEN}"
      echo "k01_uid_pre=${M03_K01_UID_PRE}"
      echo "k01_uid_post=${M03_K01_UID_POST}"
      echo "p003_gw_uid_pre=${M03_P003_UID_PRE}"
      echo "p003_gw_uid_post=${M03_P003_UID_POST}"
      echo "k01_canary_pre=${M03_K01_CANARY_PRE}"
      echo "k01_canary_post=${M03_K01_CANARY_POST}"
      echo "p003_gw_canary_pre=${M03_P003_CANARY_PRE}"
      echo "p003_gw_canary_post=${M03_P003_CANARY_POST}"
    } >"${M03_EVIDENCE_DIR}/result-ledger.txt"
  fi
  if [[ "${original_rc}" -eq 0 && "${M03_ALL_GATES_COMPLETE}" -eq 1 \
    && "${cleanup_rc}" -eq 0 ]]; then
    say "PASS: M03 provado e baseline MGC restaurado; evidência=${M03_EVIDENCE_DIR}"
    exit 0
  fi
  if [[ "${original_rc}" -ne 0 || "${cleanup_rc}" -ne 0 \
    || "${M03_ALL_GATES_COMPLETE}" -ne 1 ]]; then
    say "rollback terminou com falha (original=${original_rc}, cleanup=${cleanup_rc}); evidência=${M03_EVIDENCE_DIR}" >&2
    exit 1
  fi
}


if [[ "${DRY_RUN}" == 0 && "${MGC_M03_PHASE_CHILD:-0}" != 1 ]]; then
  exec 9>"${M03_LOCK_FILE}" || fail "não foi possível abrir lock ${M03_LOCK_FILE}"
  flock -n 9 || fail "outra execução M03 já detém ${M03_LOCK_FILE}"
  export M03_LOCK_HELD_FD=9 M03_LOCK_FILE
fi

case "${M03_INTERNAL_PHASE}" in
  up) phase_up_entrypoint; exit 0 ;;
  verify) phase_verify_entrypoint; exit 0 ;;
  '') normal_entrypoint; exit $? ;;
  *) fail "fase M03 desconhecida: ${M03_INTERNAL_PHASE}" ;;
esac
