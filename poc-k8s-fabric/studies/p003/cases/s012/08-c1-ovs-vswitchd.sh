#!/usr/bin/env bash
# P003-S012 rodada 2 — Emenda C1, fase C1.2: subir ovs-vswitchd MANUALMENTE.
# Binário direto, NUNCA service/ovs-ctl/init (o ovs-ctl faz rmmod bridge no
# kernel do host — incidente D-S012-1). Guard C1.0 já armado (p003-guard).
# Aceite da fase: ovs-vsctl show responde; ovs-dpctl dump-dps lista ovs-system;
# add-br test / del-br test funciona.
set -uo pipefail

echo "== [C1.2] pré: guard ainda armado? =="
N=$(sudo docker exec p003-os ip -o -d link show type bridge 2>/dev/null | wc -l)
echo "  linux bridges no netns: $N"
[ "$N" -ge 1 ] || { echo "  ABORT: guard desarmado"; exit 1; }

echo
echo "== [C1.2] socket ovsdb + permissões =="
sudo docker exec p003-os bash -c 'ls -la /var/run/openvswitch/db.sock; echo "  ovsdb-server: $(pgrep -xc ovsdb-server)"'
sudo docker exec p003-os chmod 666 /var/run/openvswitch/db.sock 2>/dev/null && echo "  socket chmod 666 (agentes do stack precisam)" || echo "  chmod skip"

echo
echo "== [C1.2] subir ovs-vswitchd (binário direto, --detach --monitor) =="
if sudo docker exec p003-os pgrep -x ovs-vswitchd >/dev/null 2>&1; then
  echo "  ovs-vswitchd já está rodando"
else
  sudo docker exec -d p003-os ovs-vswitchd unix:/var/run/openvswitch/db.sock \
    -vconsole:emer -vsyslog:err -vfile:info --mlockall --no-chdir \
    --log-file --pidfile --detach --monitor
  echo "  lançado; aguardando 8s"; sleep 8
fi
sudo docker exec p003-os bash -c 'pgrep -ax ovs-vswitchd | sed "s/^/  proc: /"'

echo
echo "== [C1.2] aceite 1: ovs-vsctl show =="
sudo docker exec p003-os ovs-vsctl show 2>&1 | sed 's/^/  /'

echo
echo "== [C1.2] aceite 2: datapaths =="
sudo docker exec p003-os ovs-dpctl dump-dps 2>&1 | sed 's/^/  dp: /'

echo
echo "== [C1.2] aceite 3: add-br test / del-br test =="
sudo docker exec p003-os ovs-vsctl --may-exist add-br p003-c12-test && echo "  add-br ok" || echo "  add-br FAIL"
sudo docker exec p003-os ovs-vsctl br-exists p003-c12-test && echo "  br-exists ok" || echo "  br-exists FAIL"
sudo docker exec p003-os ovs-vsctl --if-exists del-br p003-c12-test && echo "  del-br ok" || echo "  del-br FAIL"
echo "  bridges finais: [$(sudo docker exec p003-os ovs-vsctl list-br | tr '\n' ' ')]"

echo
echo "== [C1.2] pós: lab intacto =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
for b in docker0 br-b56f3de1d858 br-97b5ec9007c2 br-b03e3d58a257; do
  printf "  %-20s ports=%s\n" "$b" "$(ip -o link show master "$b" 2>/dev/null | wc -l)"
done
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
