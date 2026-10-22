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
