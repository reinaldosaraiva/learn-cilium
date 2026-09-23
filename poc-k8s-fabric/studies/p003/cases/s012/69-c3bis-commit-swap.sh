#!/usr/bin/env bash
# P003-S012 C3-bis (autorizado) — snapshot + swap do testbed:
# docker commit do p003-os (preserva writable layer inteira: 887 pacotes,
# configs corrigidas, mysql, conf.db do OVS) e novo container do snapshot com
# --cgroupns=host (mata a classe cgroup), --hostname e --ip idênticos
# (aaa1593bb5e1 / 172.17.0.2 => agentes e DB seguem válidos) e --init (reaper).
# O container antigo é PRESERVADO (renomeado) como rollback. Lab k01/sandbox
# intocado; nada além do p003-os muda no host.
set -uo pipefail

echo "== [0] pré: lab íntegro + espaço =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
df -h / | tail -1 | sed 's/^/  disco: /'
echo "  docker: $(sudo docker version --format '{{.Server.Version}}' 2>/dev/null)"
echo "  p003-os IP atual: $(sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' p003-os) hostname: $(sudo docker inspect -f '{{.Config.Hostname}}' p003-os)"

echo
echo "== [1] docker commit (snapshot da writable layer) =="
sudo docker commit p003-os p003-os:c3bis 2>&1 | tail -1 | sed 's/^/  /'
sudo docker images p003-os:c3bis --format '{{.Size}}' | sed 's/^/  tamanho imagem: /'

echo
echo "== [2] swap: stop + rename antigo + run novo =="
sudo docker stop -t 20 p003-os
sudo docker rename p003-os p003-os-v2-rollback
sudo docker run -d --name p003-os \
  --privileged --cgroupns=host --init \
  --memory=8g --memory-swap=8g --cpus=4 \
  --hostname aaa1593bb5e1 --ip 172.17.0.2 \
  -v /opt/p003-os-stack:/opt/stack \
  p003-os:c3bis sleep infinity 2>&1 | tail -1 | sed 's/^/  novo: /'
sleep 5

echo
echo "== [3] verificar novo container =="
sudo docker inspect -f 'IP={{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}} hostname={{.Config.Hostname}} cgroupns={{.HostConfig.CgroupMode}} init={{.HostConfig.Init}}' p003-os | sed 's/^/  /'
sudo docker exec p003-os bash -c 'echo "  hostname: $(hostname)"; ip -o addr show eth0 | sed "s/^/  /"; echo "  cgroup view: $(cat /proc/self/cgroup | head -2 | tr "\n" " ")"; ls /sys/fs/cgroup/ | head -5 | tr "\n" " " | sed "s/^/  cgroupfs: /"; echo; echo "  machine/ criável:"; mkdir /sys/fs/cgroup/machine 2>/dev/null && echo "    sim (host ns)" || echo "    já existe ou erro"; ls -ld /opt/stack/devstack | sed "s/^/  /"; ls /etc/neutron/plugins/ml2/ 2>/dev/null | head -3 | sed "s/^/  /"; ls -la /etc/openvswitch/conf.db 2>/dev/null | sed "s/^/  /"'
echo "  mysql data: $(sudo docker exec p003-os bash -c 'ls /var/lib/mysql 2>/dev/null | wc -l') entradas"

echo
echo "== [4] estado dos serviços (esperado: tudo morto — relight a seguir) =="
sudo docker exec p003-os bash -c 'for p in mysqld beam.smp memcached apache2 ovsdb-server ovs-vswitchd libvirtd; do printf "  %-14s %s\n" "$p" "$(pgrep -xc $p 2>/dev/null || echo 0)"; done'

echo
echo "== [5] lab pós-swap =="
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  containers: $(sudo docker ps -q | wc -l) (esperado 22 — antigo parado + novo)"
for b in docker0 br-b56f3de1d858 br-97b5ec9007c2 br-b03e3d58a257; do
  printf "  %-20s ports=%s\n" "$b" "$(ip -o link show master "$b" 2>/dev/null | wc -l)"
done
