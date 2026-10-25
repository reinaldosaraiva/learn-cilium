# Fixtures do perfil `labctl mgc`

Esta pasta é a fonte canônica dos artefatos reprodutíveis da cápsula S002-02.
O perfil [`labctl/labs/mgc.sh`](../../../labctl/labs/mgc.sh) não recria esses
conteúdos por heredoc: ele copia [`nb-topology.sh`](./nb-topology.sh) para
`ovn-central-az1`, aplica os três arquivos FRR nos containers correspondentes
e usa os valores de [`topology.md`](./topology.md) e
[`evpn-config.md`](./evpn-config.md) para a criação dos veths, VLANs e
identificadores EVPN.

## Arquivos

| arquivo | uso |
|---|---|
| `topology.md` | tabela VRF/VLAN/`/30`/AS/VNI e caminho da VM fake |
| `nb-topology.sh` | comandos NB idempotentes: LR, localnet, espelho BGP/BFD, transit e tenant |
| `frr-gw1.conf`, `frr-gw2.conf` | `bgpd`/`bfdd` AS 100 no VRF de cada gateway |
| `frr-client.conf` | cliente AS 200, anúncio `10.0.0.0/16`, dois peers e ECMP |
| `evpn-config.md` | opções `dynamic-routing-*` e `ovn-evpn-*` exatas do OVN 26.03.3 |
| `client-x05-template.conf` | contrato e parâmetros do segundo cliente X05 |
| `client-x05-template.sh` | gerador funcional da configuração FRR X05 |

O cliente usa duas interfaces criadas por `ovs-runc` no `br-ovn-ext`. A
interface `eth1` é access VLAN 100 e recebe `169.254.254.2/30`; `eth2` é
access VLAN 200 e recebe `169.254.254.6/30`. O mesmo helper pode ser chamado
com outro nome de container, VLANs distintas e os mesmos endereços para o
caso X05.
O cliente canônico recebe `10.0.0.1/32` no loopback antes dos daemons FRR; o
gate de alcance usa esse endereço como origem.

## Limites dos casos posteriores

M01 deve separar a falha do FRR da falha do gateway: o FRR desta réplica roda
dentro de `ovn-gw-1`/`ovn-gw-2`, portanto o controle de FRR deve parar somente
`zebra`, `bgpd` e `bfdd` via `docker exec`, preservando o container do gateway.
O enunciado literal “container FRR parado” da PoC não é representado por um
container FRR separado nesta fixture; essa divergência deve ser registrada no
gate M01 antes da execução.

X05 deve gerar o arquivo FRR com `bash client-x05-template.sh`, informando
`ONPREM_PREFIX`, `TENANT_PREFIX`, `ROUTER_ID`, `PEER_1/2` e
`INTERFACE_1/2`, e instanciar `mgc_start_client_instance` com outro nome, AS e
VLANs. O segundo datapath e seus controles ficam
deliberadamente reservados à cápsula S002-08.

O perfil grava no estado de `labctl` o token da intenção de ownership, os IDs
dos cinco containers OVN, os UUIDs e tokens de `br-ovn`/`br-ovn-ext`, e a
provenance dos IDs das imagens junto aos commits OVN/OVS/fake-multinode. Uma
instalação com nomes genéricos já existentes e sem
esses IDs falha fechado; ela não é adotada pelo perfil.
O conjunto de containers conferido usa o mesmo filtro nominal do
`ovn_cluster.sh stop`, incluindo containers parados, para impedir que um
nome extra seja apagado pelo stop upstream.
Durante o polling do start, IDs já descobertos são persistidos a cada ciclo.
Se o processo for interrompido antes do primeiro ID, o estado permanece sem
prova suficiente e as operações de recuperação falham fechado, exigindo
intervenção explícita; o perfil não adota o cluster apenas pelo nome.

## Suposições que precisam de validação ao vivo

1. `ovn-controller` cria `ovnvrf100`/`ovnvrf200` nos gateways ao processar as
   opções `dynamic-routing-*` antes da criação do peer do veth.
2. A imagem `ovn/ovn-multi-node` expõe `zebra`, `bgpd`, `bfdd`, `vtysh` e
   `pidof`; o perfil resolve os daemons em `/usr/libexec/frr` ou `/usr/lib/frr`.
   O cliente também precisa expor `staticd` em um desses diretórios.
3. O formato `router bgp <asn> vrf <nome>` e o nó FRR 8.4 `bfd`, com
   `peer <ip> vrf <nome>` nos gateways e `peer <ip> interface <if>` no
   cliente, são aceitos pela imagem `ovn/ovn-multi-node`.
4. Os nomes dos dispositivos EVPN (`br-evpn-tenant`, `vxlan-tenant` e
   `evpn-tenant`) são aceitos pelo controller OVN 26.03.3; a presença no NB é
   estrutural e o datapath é gate da cápsula M03.

## Resultados Consolidados ao Vivo (`P004-S002`, **PASS** em 23/10/2026)

| Caso | Script | Descrição | Resultado ao vivo (`vm-cilium`) |
|---|---|---|---|
| `M01` | `m01.sh` | Sessão BGP/BFD (`AS 100` ↔ `AS 200`), ECMP `2` caminhos, withdraw, parada de daemons FRR em `ovn-gw-1` e parada do gateway sob `A5` (`ecmp_symmetric_reply`) | **PASS sob A5** (baseline BGP `2/2`, ECMP `2`, ping `30/30`; failover via `gw2` com `30/30` replies em cada falha e recuperação limpa) |
| `M02` | `m02.sh` | `gateway_mtu` `1500` vs `9000` nas LRPs de saída com `ping -M do -s 8972` (`9000 B` IPv4 / `9014 B` L2) | **PASS sob A6** (em `1500`: `0/30` jumbo c/ `ICMP Frag Needed MTU 1500`; em `9000`: `30/30` jumbo c/ quadros `9018 B` VLAN / `9014 B` cliente; rollback a `1500`) |
| `M03` | `m03.sh` | VPC OVN anunciada como EVPN Type 5 (`192.168.100.0/24`, `VNI 50100`) e controle negativo causal sob `A7` (`dynamic-routing-redistribute=static`) | **PASS sob A7** (`30/30` ping EVPN via VXLAN `4789`; override `static` retira Type 5 e `0/3` ping preservando rotas colaterais; restauração `3/3` e rollback limpo) |
| `X05` | `x05.sh` / `x05-orchestrate.py` | Dois clientes on-prem anunciando **o mesmo CIDR** `192.168.0.0/24` e `/30` (`169.254.254.0/30`) em VRFs/VNIs distintas do MGC Connect | **PASS** (`c9d0e1` `G0→G8 RC=0` + prova de rollback negativo `b8c9d0` `G7+G8 PASS`; `0` pacotes vazados entre tenants) |

Consulte a síntese completa em [`docs/estudos/20-mgc-estado-parcial.md`](../../../docs/estudos/20-mgc-estado-parcial.md) e [`docs/lab-results.md`](../../../docs/lab-results.md).
