# `s011/` — Provisionamento do Testbed OpenStack Containerizado (`p003-os` — `P003-S011`)

Este diretório contém os artefatos da sessão **`P003-S011`** ([`07-openstack.md`](../../../../docs/estudos/07-openstack.md)), criada após emenda formal de escopo aprovada pelo dono quando o preflight constatou ausência de endpoint OpenStack externo. Os scripts constroem o container privilegiado `p003-os` rodando DevStack (Keystone, Glance, Placement, Nova e Neutron ML2/OVS + `neutron-dynamic-routing`).

## Inventário de Arquivos e Sequência Canônica

| Arquivo | Papel | Ordem / Uso |
|---|---|---|
| [`01-devstack-container.sh`](01-devstack-container.sh) | Cria o container Docker `p003-os` (`ubuntu:22.04`, cgroups, `/lib/modules`, `/dev/kvm`), instala dependências base e prepara o usuário `stack`. | **Passo 1 (Canônico)** — Criação do container `p003-os`. |
| [`systemctl-shim.sh`](systemctl-shim.sh) | Shim de `systemctl` para permitir que o DevStack gerencie unidades `devstack@*.service` em segundo plano dentro de um container Docker sem `systemd` PID 1. | **Auxiliar** — Injetado em `/usr/local/bin/systemctl` pelo setup. |
| [`patch-mysql-postinst.py`](patch-mysql-postinst.py) | Patch idempotente para o script `mysql-server.postinst` em container Ubuntu 22.04 sem `systemd` ativo. | **Auxiliar** — Invocado antes do `stack.sh`. |
| [`02-stack.sh`](02-stack.sh) | Gera o `local.conf` (com senhas efêmeras randômicas se `OS_PASS` não for informado) e executa `./stack.sh` para subir Keystone, Glance, Nova e Neutron. | **Passo 2 (Canônico)** — Instalação do DevStack dentro de `p003-os`. |
| [`reconf-ovs.sh`](reconf-ovs.sh) | Reconfigura as pontes OVS (`br-int`, `br-ex`, `br-tun`) e o mapeamento `physnet1:br-ex` do Neutron após o término do `stack.sh`. | **Passo 3 (Canônico)** — Alinhamento L2/L3 do OVS interno. |

## Nota Operacional

Para gerenciamento cotidiano do container `p003-os` já construído (sem reinstalar o DevStack do zero), utilize o orquestrador **`labctl openstack {status|up|verify|down}`** ([`poc-k8s-fabric/labctl/labs/openstack.sh`](../../../labctl/labs/openstack.sh)).
