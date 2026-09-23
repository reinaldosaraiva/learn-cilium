#!/usr/bin/env bash
# P003-S012 rodada 2 — C1.5a t2: relançamento INCONDICIONAL (o guard pgrep
# self-matchou de novo: o cmdline do wrapper continha os args do binário sem
# bracket — lição definitiva: NUNCA guard pgrep -f na mesma linha do lançamento).
# vhost nova_cell1 já existe; conductor precisa de diagnóstico/relançamento.
set -uo pipefail

echo "== [1] estado atual (processos) =="
sudo docker exec p003-os bash -c 'ps -eo pid,user,etime,args | grep -iE "uwsgi|nova-(conductor|scheduler|compute)" | grep -v grep | cut -c1-95 | sed "s/^/  /"' || echo "  (nada)"

echo
echo "== [2] log do conductor (por que morreu?) =="
sudo docker exec p003-os bash -c 'tail -8 /opt/stack/logs/n-cond.log 2>/dev/null | cut -c1-160 | sed "s/^/  /" || echo "  (log inexistente)"'

echo
echo "== [3] relançar uwsgi APIs (incondicional, padrão relight) =="
sudo docker exec p003-os bash -c 'sudo -u stack bash -c "nohup /opt/stack/data/venv/bin/uwsgi --procname-prefix glance-api --ini /etc/glance/glance-uwsgi.ini --venv /opt/stack/data/venv >/opt/stack/logs/g-api.log 2>&1 &" </dev/null; echo "  glance-api launched"'
sudo docker exec p003-os bash -c 'sudo -u stack bash -c "nohup /opt/stack/data/venv/bin/uwsgi --procname-prefix placement-api --ini /etc/placement/placement-uwsgi.ini --venv /opt/stack/data/venv >/opt/stack/logs/placement-api.log 2>&1 &" </dev/null; echo "  placement-api launched"'
sudo docker exec p003-os bash -c 'sudo -u stack bash -c "nohup /opt/stack/data/venv/bin/uwsgi --procname-prefix nova-api --ini /etc/nova/nova-api-uwsgi.ini --venv /opt/stack/data/venv >/opt/stack/logs/n-api.log 2>&1 &" </dev/null; echo "  nova-api launched"'

echo
echo "== [4] relançar conductor + scheduler (incondicional) =="
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-conductor --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-cond.log
echo "  conductor launched"
sudo docker exec -d -u stack p003-os /opt/stack/data/venv/bin/nova-scheduler --config-file /etc/nova/nova.conf --log-file /opt/stack/logs/n-sch.log
echo "  scheduler launched"

echo "  aguardando 35s"; sleep 35
echo
echo "== [5] processos agora =="
sudo docker exec p003-os bash -c 'ps -eo pid,user,etime,args | grep -iE "uwsgi|nova-(conductor|scheduler|compute)" | grep -v grep | cut -c1-95 | sed "s/^/  /"' || echo "  (nada)"

echo
echo "== [6] APIs respondem? =="
sudo docker exec p003-os bash -c 'source /opt/stack/devstack/openrc admin admin >/dev/null 2>&1; echo "  --- glance:"; timeout 40 openstack image list 2>&1 | head -3 | sed "s/^/    /"; echo "  --- placement:"; timeout 40 openstack resource provider list 2>&1 | head -3 | sed "s/^/    /"; echo "  --- nova services:"; timeout 40 openstack compute service list 2>&1 | head -8 | sed "s/^/    /"'

echo
echo "== [7] logs (erros?) =="
sudo docker exec p003-os bash -c 'for l in g-api placement-api n-api n-cond n-sch; do printf "  %-14s " "$l"; grep -acE "ERROR|Traceback" /opt/stack/logs/$l.log 2>/dev/null || echo -n "0"; echo -n " errs; "; tail -1 /opt/stack/logs/$l.log 2>/dev/null | cut -c1-90; done'

echo
echo "== [8] pós: lab intacto + RAM =="
K=$(sudo kubectl --kubeconfig /root/.kube/k01-rebuild.config --context kind-k01 get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
S=$(sudo kubectl --kubeconfig /root/.kube/p003-gw.config --context kind-p003-gw get ns kube-system -o jsonpath='{.metadata.uid}' 2>&1)
echo "  k01=$K sandbox=$S"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' http://10.201.255.10:80/); echo "  canário k01: $c"
echo "  p003-os mem: $(sudo docker stats --no-stream --format '{{.MemUsage}}' p003-os)"
free -g | awk 'NR==2{print "  host available: "$7" GiB"}'
