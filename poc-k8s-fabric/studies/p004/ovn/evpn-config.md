# Configuração estrutural EVPN do logical switch

O OVN 26.03.3 considera o logical switch um domínio EVPN L2 quando o VNI
e os nomes dos três dispositivos estão presentes. A fixture NB aplica esses
campos ao `ls-dci-tenant`:

```text
other_config:dynamic-routing-vni=50100
other_config:dynamic-routing-bridge-ifname=br-evpn-tenant
other_config:dynamic-routing-vxlan-ifname=vxlan-tenant
other_config:dynamic-routing-advertise-ifname=evpn-tenant
other_config:dynamic-routing-redistribute=fdb
```

As LRPs externas também usam `options:dynamic-routing-maintain-vrf=true`,
para que o controller faça o ciclo de vida de `ovnvrf100` e `ovnvrf200`.

O perfil aplica os identificadores do controller no OVS de cada gateway e
chassis. Os endereços abaixo são os endereços de underlay atribuídos pelo
`ovn-fake-multinode` a partir de `170.168.0.2`:

| OVS | `external_ids:ovn-evpn-local-ip` | `external_ids:ovn-evpn-vxlan-ports` |
|---|---|---:|
| `ovn-gw-1` | `50100-170.168.0.3` | 4789 |
| `ovn-gw-2` | `50100-170.168.0.4` | 4789 |
| `ovn-chassis-1` | `50100-170.168.0.5` | 4789 |
| `ovn-chassis-2` | `50100-170.168.0.6` | 4789 |

`dynamic-routing-redistribute=fdb` anuncia MACs locais (Type 2); ele não
prova a exportação de `192.168.100.0/24` como rota EVPN Type 5. O Type 5
depende da rota anunciada pelo logical router, de dispositivos Linux
EVPN/VRF provisionados e de FRR com BGP `l2vpn evpn` e exportação IPv4.
Os nomes acima instruem o controller a monitorar dispositivos; a fixture
atual não os cria. Em 29/09/2026, os três dispositivos não existiam em
`ovn-chassis-1`, e `evpn/remote-vtep-list` estava vazio.

O perfil verifica a presença dos campos no NB e tenta coletar
`ovn-appctl -t ovn-controller evpn/remote-vtep-list` dentro de
`ovn-chassis-1`. A coleta de remotos pode ficar vazia enquanto o fabric
externo ainda não estiver conectado. A cápsula M03 deve prover o par e os
dispositivos, validar o datapath e o anúncio Type 5 ao vivo. O `verify` da
cápsula 02 registra essa etapa como estrutural e marca o gate real de Type
5/RIB externo como `DEFERRED_TO_S002-07`.

Fonte pinada: `ovn-nb.xml` (EVPN Options e dynamic routing),
`controller/neighbor.c` e `tests/multinode.at` (teste "ovn multinode bgp L3
EVPN") no commit OVN `4c5118fc40d54f2f8d52781bc205ba185808d7d0`.
