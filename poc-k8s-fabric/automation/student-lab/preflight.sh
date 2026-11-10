#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${script_dir}/sudo-auth.sh"

profile="${1:-}"
state_file="${2:-}"
exercise="${3:-}"
wireguard_mode="${4:-}"

fail() {
  printf 'lab-preflight: %s\n' "$1" >&2
  exit 1
}

case "${profile}" in
  iniciantes)
    readonly min_cpus=4 min_disk_mib=25600 recommended_mib=8192 peak_mib=2560
    readonly kind_name=p010-student
    readonly kind_nodes=(p010-student-control-plane)
    readonly fabric_nodes=() network_name=''
    readonly needs_ipv6=0
    ;;
  fundamentos)
    readonly min_cpus=8 min_disk_mib=40960 recommended_mib=16384 peak_mib=6144
    readonly kind_name=k01
    readonly kind_nodes=(k01-control-plane k01-worker k01-worker2)
    readonly fabric_nodes=(
      clab-poc-k8s-kind-spine1 clab-poc-k8s-kind-spine2
      clab-poc-k8s-kind-leaf1 clab-poc-k8s-kind-leaf2
      clab-poc-k8s-kind-leaf3 clab-poc-k8s-kind-border1
      clab-poc-k8s-kind-client-ext
    )
    readonly network_name=clab-poc-kind needs_ipv6=1
    ;;
  plataforma)
    readonly min_cpus=8 min_disk_mib=40960 recommended_mib=16384 peak_mib=6144
    readonly kind_name=p003-gw
    readonly kind_nodes=(p003-gw-control-plane p003-gw-worker p003-gw-worker2)
    readonly fabric_nodes=(
      clab-p003-gw-fabric-spine1 clab-p003-gw-fabric-spine2
      clab-p003-gw-fabric-leaf1 clab-p003-gw-fabric-leaf2
      clab-p003-gw-fabric-leaf3 clab-p003-gw-fabric-border1
      clab-p003-gw-fabric-client
    )
    readonly network_name=p003-gw-mgmt needs_ipv6=1
    ;;
  hibrido)
    readonly min_cpus=12 min_disk_mib=81920 recommended_mib=24576 peak_mib=15360
    readonly kind_name=p010-hibrido
    readonly kind_nodes=(p010-hibrido-control-plane p010-hibrido-worker p010-hibrido-worker2)
    readonly fabric_nodes=(
      clab-p010-hibrido-fabric-spine1 clab-p010-hibrido-fabric-spine2
      clab-p010-hibrido-fabric-leaf1 clab-p010-hibrido-fabric-leaf2
      clab-p010-hibrido-fabric-leaf3 clab-p010-hibrido-fabric-border1
      clab-p010-hibrido-fabric-client
    )
    readonly network_name=p010-hibrido-mgmt needs_ipv6=1
    ;;
  *)
    fail 'perfil ausente ou inválido; use iniciantes, fundamentos ou plataforma.'
    ;;
esac

if [[ "${profile}" == plataforma ]]; then
  exercise="${exercise:-baseline}"
  case "${exercise}" in
    baseline|auth|tenants|ipam24|ipam32) ;;
    wireguard-native|wireguard-vxlan)
      wireguard_mode="${wireguard_mode:-W1}"
      case "${wireguard_mode}" in
        W0|W1|W2) ;;
        *) fail 'WG inválido; use W0, W1 ou W2.' ;;
      esac
      ;;
    *) fail 'EXERCISE inválido para LAB=plataforma.' ;;
  esac
  if [[ "${exercise}" != wireguard-native && "${exercise}" != wireguard-vxlan ]]; then
    [[ -z "${wireguard_mode}" ]] || fail 'WG só se aplica aos cenários WireGuard.'
  fi
else
  [[ -z "${exercise}" && -z "${wireguard_mode}" ]] || fail 'EXERCISE/WG só se aplicam a LAB=plataforma.'
fi
readonly profile state_file exercise wireguard_mode

if [[ -e /etc/os-release ]]; then
  os_id="$(awk -F= '$1 == "ID" { gsub(/"/, "", $2); print $2 }' /etc/os-release)"
  os_version="$(awk -F= '$1 == "VERSION_ID" { gsub(/"/, "", $2); print $2 }' /etc/os-release)"
else
  fail '/etc/os-release ausente; alvo suportado: Ubuntu 24.04 amd64.'
fi
[[ "${os_id}" == ubuntu && "${os_version}" == 24.04 ]] \
  || fail "suporta Ubuntu 24.04; detectado ${os_id:-desconhecido} ${os_version:-desconhecida}."
[[ "$(uname -m)" == x86_64 ]] \
  || fail "suporta amd64; detectado $(uname -m)."

cpus="$(nproc)"
(( cpus >= min_cpus )) \
  || fail "${profile} requer ${min_cpus} vCPU; detectado ${cpus}."

mem_total_kib="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
mem_available_kib="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
[[ -n "${mem_total_kib}" && -n "${mem_available_kib}" ]] \
  || fail 'não foi possível ler MemTotal e MemAvailable.'
mem_total_mib=$((mem_total_kib / 1024))
mem_available_mib=$((mem_available_kib / 1024))
disk_available_kib="$(df -Pk / | awk 'NR == 2 {print $4}')"
[[ -n "${disk_available_kib}" ]] || fail 'não foi possível ler espaço livre em /.'
disk_available_mib=$((disk_available_kib / 1024))
state_dir="${state_file%/*}"
if [[ -e "${state_dir}" ]]; then
  [[ -d "${state_dir}" && ! -L "${state_dir}" ]] \
    || fail 'diretório de estado existente não é um diretório real.'
  state_dir_owner_mode="$(stat -c '%u:%a' "${state_dir}")"
  [[ "${state_dir_owner_mode}" == "$(id -u):700" ]] \
    || fail "diretório de estado inseguro (${state_dir_owner_mode}); não será corrigido automaticamente."
fi
if [[ -e "${state_file}" ]]; then
  [[ -f "${state_file}" && ! -L "${state_file}" ]] \
    || fail 'arquivo de estado existente não é regular.'
  state_file_owner_mode="$(stat -c '%u:%a' "${state_file}")"
  [[ "${state_file_owner_mode}" == "$(id -u):600" ]] \
    || fail "arquivo de estado inseguro (${state_file_owner_mode}); não será corrigido automaticamente."
  [[ -x /usr/bin/jq ]] \
    || fail 'jq ausente; não vou instalar dependências em lab-preflight para ler state existente.'
  state_status="$(/usr/bin/jq -er '.status | strings' "${state_file}")" \
    || fail 'state.json não contém um status JSON válido.'
  case "${state_status}" in
    down) ;;
    preparing|partial|up)
      fail "state está ${state_status}; use lab-status e lab-down antes de uma nova admissão."
      ;;
    *) fail 'state contém um status não suportado.' ;;
  esac
fi

printf 'Perfil: %s | cenário: %s%s | CPU: %s/%s vCPU | RAM total: %s MiB (recomendado: %s MiB)\n' \
  "${profile}" "${exercise:-baseline}" "${wireguard_mode:+/${wireguard_mode}}" \
  "${cpus}" "${min_cpus}" "${mem_total_mib}" "${recommended_mib}"
printf 'MemAvailable: %s MiB | pico estimado: %s MiB | reserva preservada: 4096 MiB\n' \
  "${mem_available_mib}" "${peak_mib}"
printf 'Disco livre em /: %s/%s MiB | cgroup: %s\n' \
  "${disk_available_mib}" "${min_disk_mib}" "$(stat -fc '%T' /sys/fs/cgroup)"

(( mem_available_kib >= (peak_mib + 4096) * 1024 )) \
  || fail "MemAvailable abaixo de $((peak_mib + 4096)) MiB; nenhum pacote ou recurso foi alterado."
(( disk_available_mib >= min_disk_mib )) \
  || fail "requer ${min_disk_mib} MiB livres no filesystem raiz."
[[ "$(stat -fc '%T' /sys/fs/cgroup)" == cgroup2fs ]] \
  || fail 'kind/containerlab exigem cgroup v2.'
if (( needs_ipv6 == 1 )); then
  [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" == 0 ]] \
    || fail 'o perfil de fabric requer IPv6 ativo; NICs e rotas não serão alteradas.'
fi

if [[ "${profile}" == hibrido ]]; then
  [[ -c /dev/kvm ]] \
    || fail '/dev/kvm precisa existir como dispositivo de caracteres; nenhuma permissão será alterada.'
  # QEMU host-forward ports are scoped to the saved border namespace and are
  # checked there immediately before launch, never against host listeners.
fi

docker_client=/usr/bin/docker
docker_socket=/var/run/docker.sock
if [[ -e "${docker_client}" || -S "${docker_socket}" ]]; then
  [[ -x "${docker_client}" && -S "${docker_socket}" ]] \
    || fail 'Docker ou seu socket existe, mas o engine local não pode ser inspecionado sem mutação; corrija o serviço e repita.'
  command -v sudo >/dev/null 2>&1 || fail 'sudo é necessário para inspeção local do Docker.'
  student_require_sudo_auth || fail 'autenticação sudo necessária para a inspeção somente leitura do Docker.'
  docker_version="$(sudo -n "${docker_client}" --host unix:///var/run/docker.sock version --format '{{.Server.Version}}')" \
    || fail 'Docker local não responde; inicie/corrija o serviço e execute lab-preflight novamente.'
  docker_major="${docker_version%%.*}"
  docker_minor="${docker_version#*.}"
  docker_minor="${docker_minor%%.*}"
  if (( docker_major < 20 || (docker_major == 20 && docker_minor < 10) )); then
    fail "Docker ${docker_version} incompatível; mínimo 20.10. Um engine existente não será atualizado."
  fi

  container_names="$(sudo -n "${docker_client}" --host unix:///var/run/docker.sock ps -a --format '{{.Names}}')" \
    || fail 'não foi possível listar containers no Docker local.'
  for name in "${kind_nodes[@]}" "${fabric_nodes[@]}"; do
    if [[ -n "${name}" ]] && grep -Fxq -- "${name}" <<<"${container_names}"; then
      fail "container ${name} já existe sem state desta automação; não será adotado."
    fi
  done

  kind_labeled_containers="$(sudo -n "${docker_client}" --host unix:///var/run/docker.sock ps -a \
    --filter "label=io.x-k8s.kind.cluster=${kind_name}" --format '{{.Names}}')" \
    || fail 'não foi possível inspecionar labels de clusters kind no Docker local.'
  [[ -z "${kind_labeled_containers}" ]] \
    || fail "cluster kind ${kind_name} já possui containers no Docker; não será adotado."

  network_names="$(sudo -n "${docker_client}" --host unix:///var/run/docker.sock network ls --format '{{.Name}}')" \
    || fail 'não foi possível listar redes no Docker local.'
  if [[ -n "${network_name}" ]] && grep -Fxq -- "${network_name}" <<<"${network_names}"; then
    fail "rede ${network_name} já existe sem state desta automação; não será adotada."
  fi

  kind_bin=''
  if [[ -x "${HOME}/.local/state/p010-student-lab/tools/bin/kind" ]]; then
    kind_bin="${HOME}/.local/state/p010-student-lab/tools/bin/kind"
  elif command -v kind >/dev/null 2>&1; then
    kind_bin="$(command -v kind)"
  fi
  if [[ -n "${kind_bin}" ]]; then
    clusters="$(sudo -n env -u DOCKER_CONTEXT DOCKER_HOST=unix:///var/run/docker.sock "${kind_bin}" get clusters)" \
      || fail 'kind não conseguiu inspecionar clusters no Docker local.'
    if grep -Fxq -- "${kind_name}" <<<"${clusters}"; then
      fail "cluster kind ${kind_name} já existe sem state desta automação; não será adotado."
    fi
  fi
  printf 'Docker local: %s | colisões: nenhuma nos nomes declarados.\n' "${docker_version}"
else
  if [[ "${profile}" == hibrido ]]; then
    printf 'Docker Engine ausente; o caminho público de lab-up hibrido continua bloqueado.\n'
  else
    printf 'Docker Engine ausente; lab-up pode instalar docker.io após esta admissão.\n'
  fi
fi

if [[ "${profile}" == hibrido ]]; then
  printf 'PRECHECK_OK_CAPACITY_ONLY: capacidade e colisões conferidas; o perfil hibrido continua incompleto e lab-up LAB=hibrido recusa antes de qualquer alteração.\n'
  exit 0
fi
printf 'PRECHECK_OK: nenhuma dependência ou infraestrutura foi alterada.\n'
