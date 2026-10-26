#!/usr/bin/env bash
# =============================================================================
# CAMINHO B+ — torna o VIP do lab alcançável de outras VMs da VPC
#
# Sem isto, tudo o que o lab faz morre dentro da vm-cilium. Com isto, um cliente
# de verdade na VPC alcança 10.201.255.10, que é servido por pods rodando dentro
# do lab, atravessando: VPC -> vm-cilium (host) -> FRR -> leaf3 -> spine ->
# leaf -> nó kind -> pod.
#
# Por que funciona apesar do filtro de MAC da VPC: o pacote sai da vm-cilium
# pelo netns do HOST, ou seja, com o MAC da própria VNIC. O que não é registrado
# é o IP de origem das respostas (10.201.255.10) — e esse filtro TEM toggle.
#
# Rode na vm-cilium, como root, DEPOIS do clab deploy:
#   sudo ./scripts/06-expor-vip-na-vpc.sh
# =============================================================================
set -euo pipefail

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

IFACE_HOST="${IFACE_HOST:-clab-ext}"    # ponta do veth criada pelo containerlab
HOST_IP="${HOST_IP:-10.100.0.1/30}"
FRR_IP="${FRR_IP:-10.100.0.2}"
VIP_CIDR="${VIP_CIDR:-10.201.255.0/24}"
LAB_CIDRS="${LAB_CIDRS:-10.0.0.0/16 10.10.0.0/16 10.244.0.0/16 203.0.113.0/24}"
DEFAULT_UPLINK="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}' || true)"
UPLINK="${UPLINK:-${DEFAULT_UPLINK:-ens3}}" # VNIC da vm-cilium na VPC
MASQ="${MASQ:-no}"                      # yes = plano B, mascara a origem

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "[DRY-RUN] 06-expor-vip-na-vpc.sh: IFACE_HOST=${IFACE_HOST} HOST_IP=${HOST_IP} FRR_IP=${FRR_IP} VIP_CIDR=${VIP_CIDR} UPLINK=${UPLINK} MASQ=${MASQ}"
  exit 0
fi

[[ $EUID -eq 0 ]] || { echo "rode como root (sudo)"; exit 1; }

hr(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

hr "1/4 lado do host"
ip link show "${IFACE_HOST}" >/dev/null 2>&1 || {
  echo "ERRO: ${IFACE_HOST} não existe. Suba a topologia primeiro:"
  echo "  sudo clab deploy -t topo/poc-kind.clab.yml"
  exit 1
}
ip link set "${IFACE_HOST}" up
ip link set "${IFACE_HOST}" mtu 1500
ip addr replace "${HOST_IP}" dev "${IFACE_HOST}"
sysctl -qw net.ipv4.ip_forward=1
sysctl -qw "net.ipv4.conf.${IFACE_HOST}.rp_filter=0"
sysctl -qw "net.ipv4.conf.${UPLINK}.rp_filter=0"

hr "2/4 rotas para dentro do lab"
for c in ${VIP_CIDR} ${LAB_CIDRS}; do
  ip route replace "${c}" via "${FRR_IP}" dev "${IFACE_HOST}"
  echo "  ${c} via ${FRR_IP}"
done

if [[ "${MASQ}" == "yes" ]]; then
  hr "2b/4 SNAT (plano B — quando a VPC descarta origem fora do CIDR da VNIC)"
  iptables -t nat -C POSTROUTING -s "${VIP_CIDR}" -o "${UPLINK}" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s "${VIP_CIDR}" -o "${UPLINK}" -j MASQUERADE
  echo "  origem mascarada como $(ip -4 -br addr show "${UPLINK}" | awk '{print $3}')"
  echo "  ATENÇÃO: isto mascara o IP de origem na saída da VM."
fi

hr "3/4 o que falta fazer FORA desta VM"
MYIP=$(ip -4 -br addr show "${UPLINK}" | awk '{print $3}' | cut -d/ -f1)
cat <<EOF
  a) Encaminhamento L3 na VPC:
       Em nuvens cujo anti-spoofing da VNIC descarta pacotes com origem fora da
       sub-rede da VM (${VIP_CIDR}), mantenha o guard ativo e utilize um par de
       roteamento dedicado (GRE/VXLAN/BGP sobre Connect Gateway) ou MASQ=yes
       apenas para testes funcionais de bancada. Nunca desative o anti-spoofing
       em portas compartilhadas sem avaliação de segurança.

  b) No cliente (outra VM da VPC):
       ip route replace ${VIP_CIDR} via ${MYIP}

  c) Security Group da vm-cilium: permitir o tráfego do cliente (ICMP/TCP 80).
EOF

hr "4/4 validação daqui"
printf '%-40s' "FRR responde em ${FRR_IP}"; ping -c1 -W2 "${FRR_IP}" >/dev/null 2>&1 && echo OK || echo FALHOU
printf '%-40s' "rota para ${VIP_CIDR}";    ip route get "${VIP_CIDR%/*}" >/dev/null 2>&1 && echo OK || echo FALHOU
printf '%-40s' "VIP responde do host";     curl -s -m3 -o /dev/null "http://${VIP_CIDR%.0/24}.10/" && echo OK || echo "FALHOU (o Service já subiu?)"

cat <<EOF

Teste final, a partir do cliente na VPC:
  curl http://${VIP_CIDR%.0/24}.10/hostname        # deve variar entre pods
  for i in \$(seq 20); do curl -s http://${VIP_CIDR%.0/24}.10/hostname; echo; done | sort | uniq -c

Para desfazer:
  sudo ip addr flush dev ${IFACE_HOST}
  sudo iptables -t nat -D POSTROUTING -s ${VIP_CIDR} -o ${UPLINK} -j MASQUERADE 2>/dev/null || true
EOF
