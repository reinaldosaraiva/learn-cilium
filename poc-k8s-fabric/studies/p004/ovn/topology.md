# Réplica MGC Connect — topologia canônica

O perfil `labctl mgc` usa `ovn-fake-multinode` v0.4 com `RUNC_CMD=docker`,
`CENTRAL_COUNT=1`, `GW_COUNT=2`, `CHASSIS_COUNT=2` e
`CREATE_FAKE_VMS=no`. A fonte OVN é a tag `v26.03.3`, commit
`4c5118fc40d54f2f8d52781bc205ba185808d7d0`; o OVS usado na construção é a
branch compatível `branch-3.7` (OVS não possui uma tag `v26.03.3`); quando o
gitlink estiver disponível, o perfil faz checkout detached do commit indicado
pela árvore OVN.
O `ovn-fake-multinode` é a tag `v0.4`, commit iniciado por `653e7b2`.

| conexão | gateway | VRF Linux | VLAN | lado OVN `/30` | cliente `/30` | AS OVN | AS cliente |
|---|---|---:|---:|---|---|---:|---:|
| MGC-100 | `ovn-gw-1` | `ovnvrf100` | 100 | `169.254.254.1/30` | `169.254.254.2/30` | 100 | 200 |
| MGC-200 | `ovn-gw-2` | `ovnvrf200` | 200 | `169.254.254.5/30` | `169.254.254.6/30` | 100 | 200 |

O cliente `mgc-client-1` anuncia `10.0.0.0/16` nas duas sessões. A VPC do
tenant é `192.168.100.0/24`, com VM fake `192.168.100.10` e VNI EVPN
`50100`. O `lr-mgc-100` e o `lr-mgc-200` têm uma rota estática para a VPC;
`lr-mgc-tenant` tem duas rotas ECMP para `10.0.0.0/16`.

Cada conexão tem um LR próprio (`lr-mgc-100` ou `lr-mgc-200`), um LS externo
com porta localnet (`network_name=public`, tag VLAN), uma porta externa
`bgpvrf<VRF>` e uma LRP externa com:

```text
options:routing-protocols=BGP,BFD
options:routing-protocol-redirect=bgpvrf<VRF>
options:gateway_mtu=1500
```

As duas LRPs externas são agendadas em `ovn-gw-1` e `ovn-gw-2`,
respectivamente. O arquivo [`nb-topology.sh`](./nb-topology.sh) é a fonte
canônica dos comandos NB; `mgc.sh` copia-o para o central e o executa dentro
do container.

## Caminho do espelho BGP/BFD

Em cada gateway o perfil cria um par veth. A ponta `bgpvrf<VRF>-ovs` fica no
`br-int` com `external_ids:iface-id=bgpvrf<VRF>`; a ponta
`bgpvrf<VRF>` fica no namespace raiz do gateway e é escravizada ao VRF
`ovnvrf<VRF>`. Isso permite que `bgpd` e `bfdd` rodem dentro do próprio
`ovn-gw-N` e recebam os pacotes redirecionados pela LRP OVN. A suposição a
validar ao vivo é que o `ovn-controller` crie o VRF antes da criação do veth.
O perfil também atribui ao peer do veth o endereço LRP (`.1/30` ou `.5/30`)
para que o `bgpd` tenha uma origem numerada para as sessões BGP.

## VM fake

O `mgc-tenant-vm` é um namespace criado em `ovn-chassis-1`, ligado ao
`br-int` por veth e identificado pelo LSP `mgc-tenant-vm`. A fixture deixa o
default gateway em `192.168.100.1` para o ping externo do cliente.
