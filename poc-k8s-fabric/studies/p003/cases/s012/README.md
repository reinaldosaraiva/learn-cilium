# `s012/` — Integração Híbrida Kubernetes (`p003-gw`) ↔ OpenStack Neutron (`p003-os`) (`P003-S012`)

Este diretório preserva a trilha completa de engenharia e diagnóstico da sessão **`P003-S012`** ([`07-openstack.md`](../../../../docs/estudos/07-openstack.md)), que conectou o cluster `p003-gw` ao OpenStack Neutron (`p003-os`) via eBGP (`qrouter` ↔ `border1`) e executou a matriz híbrida `C01–C11`.

> **Como navegar neste diretório:**
> Dos **82 scripts** aqui preservados para rastreabilidade histórica da investigação do bug `D-S012-13` (RX morto em KVM aninhado dentro de container Docker), apenas **7 scripts formam a sequência canônica de reprodução**. Os demais são sondas diagnósticas incrementais (marcadas como `Histórico / Diagnóstico`) e **não precisam ser reexecutados** (a solução definitiva de KVM real no host está em [`../s014/04-c5-vm-outside-container.sh`](../s014/04-c5-vm-outside-container.sh) e [`09-vm-outside-container.md`](../../../../docs/estudos/09-vm-outside-container.md)).

## 1. Sequência Canônica de Execução (`7` Scripts Principais)

| Ordem | Script | Função |
|---|---|---|
| **1** | [`01-restart-relight.sh`](01-restart-relight.sh) | Religa os daemons do DevStack (`p003-os`), OVS e MariaDB/RabbitMQ após reinício do container. |
| **2** | [`11-create-tenants-and-vms.sh`](11-create-tenants-and-vms.sh) | Cria os projetos/redes/sub-redes/routers Neutron (`tenant-a` `10.30.0.0/24`, `tenant-b` `10.31.0.0/24`), Security Groups e instâncias Nova (`vm-a`, `vm-b`). |
| **3** | [`15-bgp-connect-and-routes.sh`](15-bgp-connect-and-routes.sh) | Conecta o `br-ex` do OpenStack ao `border1` do fabric (`10.40.0.0/24`) e estabelece o pareamento BGP para troca de PodCIDRs (`10.245.0.0/16`) e sub-redes de VMs. |
| **4** | [`47-deploy-k8s-fixtures.sh`](47-deploy-k8s-fixtures.sh) | Aplica no `p003-gw` os namespaces `p003-hybrid-a` / `p003-hybrid-b`, pods `api-pod-a` / `api-pod-b` e políticas base. |
| **5** | [`59-run-matrix-c01-c11.sh`](59-run-matrix-c01-c11.sh) | Executa a bateria automatizada dos casos `C01` a `C11` (controles `H01–H04` Cilium × Neutron SG e matriz A/B). |
| **6** | [`69-rerun-c01-c06-c07-c11.sh`](69-rerun-c01-c06-c07-c11.sh) | Reexecuta os casos `C01`, `C06`, `C07` e `C11` após estabilização da rota de retorno e consola da VM. |
| **7** | [`70-verify-preserve.sh`](70-verify-preserve.sh) | Verifica integridade pós-execução (`k01` `10/10`, estado do `p003-gw` e preservação das evidências). |

## 2. Catálogo por Fase das Sondas Históricas e Diagnósticas (`03`..`81`)

| Faixa de Scripts | Fase da Investigação (`P003-S012`) | Classificação |
|---|---|---|
| `03-wait-and-finish.sh` .. `10-fix-placement-conf.sh` | Recuperação inicial do Placement/Nova/Neutron no container `p003-os` (`uwsgi`, `nova-cell1`, `ovs-agent`). | Histórico / Setup |
| `12-check-vms.sh` .. `14-fix-cell-and-recreate-vms.sh` | Verificação do agendamento Nova (`cell1` discovery) e criação inicial das VMs CirrOS. | Histórico / Setup |
| `16-fix-bgp-link-and-routes.sh` .. `27-verify-e2e-routing.sh` | Ajuste de MTU/VXLAN/ARP entre `qrouter`, `br-ex`, `p003-os` e `clab-p003-gw-fabric-border1`. | Histórico / Roteamento |
| `28-boot-vms-and-check-console.sh` .. `46-check-vm-userdata-executed.sh` | Investigação de boot CirrOS, DHCP (`qdhcp`) e metadata/userdata sob QEMU/KVM aninhado. | Histórico / Diagnóstico |
| `48-test-pod-to-vm-baseline.sh` .. `58-test-from-vm-console.sh` | Isolamento da assimetria TX vs RX na `tap` da VM (`D-S012-13`: pacotes chegam à `tap`, mas o guest aninhado não recebe). | Histórico / Diagnóstico |
| `60-diag-c01-c06-c07-c11.sh` .. `68-verify-vm-recovery.sh` | Ajustes de conntrack, Security Groups Neutron e testes via console serial da VM. | Histórico / Diagnóstico |
| `71-diag-vm-rx.sh` .. `81-tap-location-diag.sh` | Diagnóstico profundo de `vhost-net`, `offloads`, `ebtables`, OpenFlow `br-int` e localização de `tap` entre netns — que provou que a causa raiz era o KVM aninhado em container e motivou a solução **C5 (VM em KVM real no host)** em `s014/04-c5-vm-outside-container.sh`. | Histórico / Causa Raiz `D-S012-13` |
