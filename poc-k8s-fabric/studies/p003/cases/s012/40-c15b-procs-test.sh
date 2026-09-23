#!/usr/bin/env bash
# Diferencial: escrever pid de OUTRO processo no cgroup filho (fluxo libvirt).
set -uo pipefail
sudo /usr/bin/docker exec -i p003-os bash -s <<'EOS'
mkdir -p /sys/fs/cgroup/machine/t5x
sleep 300 &
SP=$!
echo "teste A: root escreve pid $SP (outro processo)"
echo "$SP" > /sys/fs/cgroup/machine/t5x/cgroup.procs 2>&1 | head -1
echo "  procs no filho: $(wc -l < /sys/fs/cgroup/machine/t5x/cgroup.procs 2>/dev/null)"
echo "  type: $(cat /sys/fs/cgroup/machine/t5x/cgroup.type)"
if [ "$(wc -l < /sys/fs/cgroup/machine/t5x/cgroup.procs 2>/dev/null)" -gt 0 ]; then
  echo "teste A OK — movendo de volta"
  echo "$SP" > /sys/fs/cgroup/cgroup.procs 2>&1 | head -1
  echo "  procs de volta no root: presente"
fi
kill $SP 2>/dev/null
rmdir /sys/fs/cgroup/machine/t5x 2>/dev/null || echo "  (t5x não removido — tem procs?)"
echo "teste B: cgroup.threads write (threaded)?"
mkdir -p /sys/fs/cgroup/machine/t6x
echo $$ > /sys/fs/cgroup/machine/t6x/cgroup.threads 2>&1 | head -1
echo "  threads-write rc acima (vazio=ok)"
cat /sys/fs/cgroup/machine/t6x/cgroup.type
echo $$ > /sys/fs/cgroup/cgroup.threads 2>/dev/null
rmdir /sys/fs/cgroup/machine/t6x 2>/dev/null && echo "  t6x removido"
EOS
