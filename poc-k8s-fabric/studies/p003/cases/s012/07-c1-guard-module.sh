#!/usr/bin/env bash
# P003-S012 rodada 2 — Emenda C1, fases C1.0 e C1.1.
# C1.0: rearmar o guard do ovs-ctl criando uma bridge dummy NO NETNS DO CONTAINER
#       (o guard "bridges exist" volta a disparar se alguém invocar ovs-ctl).
# C1.1: carregar o módulo openvswitch NO HOST (gate autorizado pelo dono).
# Ordem obrigatória: C1.0 SEMPRE antes de qualquer binário de OVS.
# NUNCA invocar ovs-ctl / openvswitch-switch init / modprobe dentro do container.
set -uo pipefail
FAIL=0

echo "== [C1.0] rearmar guard: bridge dummy no netns do container =="
if sudo docker exec p003-os ip link show p003-guard >/dev/null 2>&1; then
  echo "  p003-guard já existe — guard já armado"
else
  sudo docker exec p003-os ip link add p003-guard type bridge && \
  sudo docker exec p003-os ip link set p003-guard up
fi
N=$(sudo docker exec p003-os ip -o -d link show type bridge 2>/dev/null | wc -l)
echo "  linux bridges no netns do container: $N (precisa >= 1)"
if [ "$N" -lt 1 ]; then echo "  ABORT: guard não armado — NÃO carregar módulo"; exit 1; fi
echo "  OK guard armado (ovs-ctl acidental voltaria a disparar o guard)"

echo
echo "== [C1.1] carregar módulo openvswitch NO HOST =="
if lsmod | grep -q '^openvswitch '; then
  echo "  openvswitch já carregado:"
  lsmod | grep '^openvswitch ' | sed 's/^/    /'
else
  sudo modprobe openvswitch
  echo "  modprobe rc=$?"
fi
lsmod | grep -E '^(openvswitch|bridge) ' | sed 's/^/  /' || { echo "  FAIL: openvswitch não listado"; exit 1; }

echo
echo "== [C1.1] pós-checagem: UIDs protegidos =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01     = $K"
echo "  sandbox = $S"
[ "$K" = "45cb3818-248b-4dd2-b65c-5909bde08fe6" ] && echo "  OK k01" || { echo "  FAIL k01"; FAIL=1; }
[ "$S" = "8216d179-9eed-4dc1-ab9c-97c0c6612b32" ] && echo "  OK sandbox" || { echo "  FAIL sandbox"; FAIL=1; }

echo
echo "== [C1.1] pós-checagem: bridges do host intactas =="
for b in docker0 br-b56f3de1d858 br-97b5ec9007c2 br-b03e3d58a257; do
  printf "  %-20s ports=%s %s\n" "$b" "$(ip -o link show master "$b" 2>/dev/null | wc -l)" "$(ip -br addr show "$b" 2>/dev/null | awk '{print $2,$3}')"
done
echo "  containers: $(sudo docker ps -q | wc -l) (expect 21)"

echo
echo "== [C1.1] pós-checagem: canário k01 (expect 10/10) =="
ok=0; for i in $(seq 1 10); do c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/ 2>/dev/null); printf " %s" "$c"; [ "$c" = 200 ] && ok=$((ok+1)); done; echo; echo "  200-count: $ok/10"

echo
echo "== [extra] cilium masquerade via ConfigMap (sandbox, read-only) =="
sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw -n kube-system get cm cilium-config -o yaml 2>/dev/null | grep -iE 'masquerade|native-routing|tunnel' | sed 's/^/  /'

echo
[ "$FAIL" -eq 0 ] && echo "== C1.0 + C1.1 OK ==" || { echo "== C1.0/C1.1 COM FALHA =="; exit 1; }
