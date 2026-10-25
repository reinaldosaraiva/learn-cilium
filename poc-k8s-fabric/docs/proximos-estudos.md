# Próximos estudos — Cilium como motor de uma conexão dedicada com eBGP

> Proposta de trilha (estudos E09–E25) escrita em 26/09/2026, depois do encerramento da
> trilha P003. O estudo **E20 (`P004`) foi integralmente concluído com PASS (`P004-S001` a `P004-S008`, `G01` a `G08` fechados)** — veja a [síntese pública de P004](estudos/20-mgc-estado-parcial.md) — e o plano **P005 (Ondas Paralelas Braço A eBGP ∥ Braço B Datapath eBPF)** concluiu com **PASS** as **Ondas 1 e 2 (`P005-S001` e `P005-S002`)**:
> - **Onda 1 — Braço A (`E19` + `E09`):** [19 — Idempotência BGP (10x), Zero Resíduo e eBGP Autenticado TCP MD5 com ASN 32 bits (`4200000001`)](estudos/19-bgp-idempotency-md5-asn32.md);
> - **Onda 1 — Braço B (`E23` + `E21`):** [21 — `netkit` vs `veth` no Datapath eBPF & Escala de Burst IPAM com Warm Pool](estudos/21-netkit-vs-veth-ipam-burst.md);
> - **Onda 2 — Braço A (`E11` + `E12` + `E10`):** [11 — Limite de Prefixos (`max-prefix`), Filtro de Import, Communities/Prepend/MED e Detecção de Falha com BFD (`< 1 s`)](estudos/11-bgp-maxprefix-communities-bfd.md);
> - **Onda 2 — Braço B (`E22`):** [22 — XLB: Balanceamento L7 eBPF na Camada de Sockets (`sockmap` / `bpf_sock_ops` / `sk_msg`) vs `SocketLB L4` e `Envoy L7`](estudos/22-xlb-ebpf-socket-lb-vs-envoy.md).
> Os estudos das Ondas 3 e 4 (`E13–E18`, `E24`, `E25`) seguem em execução estruturada sob `P005-S003` e `P005-S004`. Cada estudo nasce de uma lacuna
> registrada no [guia do estudante 2.3](lab-guide-student.md) ou de um
> requisito técnico de um produto de conexão dedicada com eBGP (Direct
> Connect), e cita a fonte primária que sustenta a hipótese. Dados
> comerciais do produto ficam fora desta edição pública.

## 1. Por que esta trilha

As trilhas P001–P003 provaram que o Cilium anuncia PodCIDR e VIPs por eBGP a
um fabric real, sobrevive a falhas com Graceful Restart, expõe Gateways por
VIP anycast e isola tenants por identidade. O que elas **não** exercitaram é
justamente o conjunto de funções que um roteador de borda de provedor precisa
ter para terminar a sessão eBGP de um cliente: autenticação da sessão,
detecção de falha abaixo de um segundo, limite de prefixos aprendidos, filtro
de import, políticas de preferência de caminho (communities, prepend, MED),
redundância entre dois equipamentos com failover automático, sessão IPv6,
VRF por tenant e visibilidade de rotas e estado por conexão.

A pergunta central da trilha é: **em que ponto da arquitetura o Cilium é o
motor certo, e em que ponto o motor certo é o roteador de borda (FRR ou
SR Linux) com o Cilium atrás dele?** As respostas vêm de ensaios com
controle negativo, não de leitura de documentação.

## 2. Estado verificado das capacidades do Cilium 1.20

Verificado em 26/09/2026 na documentação estável e no rastreador do projeto.
Toda alegação volátil deve ser reconferida na versão exata do sandbox antes
de cada sessão.

| Capacidade | Estado no Cilium OSS 1.20 | Fonte |
|---|---|---|
| eBGP IPv4/IPv6 unicast, ASN 16 e 32 bits, eBGP multihop | suportado (`families`, `ebgpMultihop`) | [Recursos BGP v2](https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-configuration/) |
| Autenticação TCP MD5 (RFC 2385) | suportado por `authSecretRef` no `CiliumBGPPeerConfig` | mesma página |
| Timers keepalive/hold e Graceful Restart | suportado (`timers`, `gracefulRestart`); o lab usou 3/9 s e GR 30 s | mesma página; Módulo 4 do guia |
| BFD | **não suportado no OSS**; a doc de operação diz "currently, Cilium does not support it"; CFP #22394 aberta desde 2022; PR #48251 em rascunho (intervalos e multiplicador no `CiliumBGPPeerConfig`, um instance por nó, sem multihop); disponível na Isovalent Enterprise desde 1.16 | [Operação BGP](https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-operation/), [issue 22394](https://github.com/cilium/cilium/issues/22394), [PR 48251](https://github.com/cilium/cilium/pull/48251) |
| Piso dos timers | `holdTimeSeconds=3` e `keepAliveTimeSeconds=1` são os mínimos documentados | Operação BGP |
| Limite de prefixos aprendidos por sessão | **não exposto** na API v2 | ausência na página de recursos |
| Filtro de import e aprendizado de rotas | **não exposto e recusado como CFP**: a doc afirma que o BGP Control Plane "does not program the datapath"; a CFP de route learning (#34841) foi fechada e os mantenedores recomendam FRR ou BIRD co-implantado para BGP bidirecional | [Visão geral BGP](https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane/), [issue 34841](https://github.com/cilium/cilium/issues/34841), [design-cfps 58](https://github.com/cilium/design-cfps/pull/58) |
| Peering unnumbered (RFC 5549) | **não está na 1.20**; `autoDiscovery.mode: DefaultGateway` é o único modo; PR #47394 aberto | [PR 47394](https://github.com/cilium/cilium/pull/47394) |
| VRF, network-instance, route-target | **não existe no OSS** (um GoBGP por nó sobre a tabela do host); Enterprise tem `IsovalentVRF` com SRv6 L3VPN e VPNv4 desde a 1.13 | [Isovalent Enterprise 1.13](https://isovalent.com/blog/post/isovalent-enterprise-1-13/) |
| Egress Gateway | OSS: `CiliumEgressGatewayPolicy` fixa IP de saída por nó; múltiplos gateways por UID de endpoint, sem failover consciente; incompatível com Cluster Mesh. Enterprise: grupos de egress, anúncio do IP de egress por BGP e egress standalone fora do cluster | [Egress Gateway](https://docs.cilium.io/en/stable/network/egress-gateway/egress-gateway/) |
| Cluster Mesh | PodCIDRs únicos entre clusters no OSS; CIDR sobreposto só na Enterprise; MCS-API estável na 1.20 | [Cluster Mesh](https://docs.cilium.io/en/stable/network/clustermesh/setup/) |
| QinQ e VLAN | só passagem de 802.1Q por `bpf.vlanBypass`, em remoção (PR #38954); sem QinQ | [VLAN 802.1Q](https://docs.cilium.io/en/latest/configuration/vlan-802.1q/) |
| MTU jumbo | detecta o MTU do host, incluindo 9000; override por Helm | [Tuning](https://docs.cilium.io/en/latest/operations/performance/tuning/) |
| Communities standard, large e well-known nos anúncios | suportado por `advertisementType` | página de recursos |
| `localPreference` | só iBGP; ignorado em eBGP | página de recursos |
| AS-path prepend e MED | **não expostos** | ausência na página de recursos |
| Métricas de sessão e rotas | `cilium_bgp_control_plane_session_state`, `advertised_routes`, `received_routes`, `reconcile_*` | [Métricas](https://docs.cilium.io/en/stable/observability/metrics/) |
| CLI de estado | `cilium bgp peers`, `cilium bgp routes advertised/available`, `cilium-dbg bgp route-policies` | Operação BGP |
| Motor BGP | GoBGP 4.6.1 na 1.20.0 (3.37 na 1.19); BGPv1 `CiliumBGPPeeringPolicy` removida na 1.19; o BFD do GoBGP é parcial e tem issues abertas de conformidade RFC 5880 (sem jitter, ignora RequiredMinRx do par) | [Release 1.20.0](https://github.com/cilium/cilium/releases/tag/v1.20.0), [1.19.0](https://github.com/cilium/cilium/discussions/44191), [GoBGP 3563](https://github.com/osrg/gobgp/issues/3563) |
| Gateway `hostNetwork` para L4 | não expõe listener no nó (medido em S004) | Módulo 6 do guia |
| Dual-homing do nó em duas sessões | design pronto; o simulador SR Linux não estabelece TCP/179 em porta adicionada em runtime | Módulo 4 do guia |

### 2.1 A fronteira que a pesquisa desenha

O Cilium OSS é um speaker do lado do cliente (CE): anuncia pods, serviços e
pools com communities e MD5, por IPv4 e IPv6, com GR e timers de data center,
e expõe estado e métricas. Ele não aprende rotas, não filtra import, não
limita prefixos, não faz prepend nem MED, não tem BFD, VRF, unnumbered,
MACsec ou QinQ. Os próprios mantenedores apontam FRR ou BIRD ao lado do
GoBGP para qualquer papel bidirecional. O lado provedor (PE) de uma conexão
dedicada, portanto, pertence a um roteador de borda (FRR, SONiC ou vendor)
ou à Isovalent Enterprise (BFD, VRF/SRv6, Egress Gateway HA), com o Cilium
confinado ao lado do tenant. A trilha abaixo testa essa fronteira em vez de
assumi-la.

## 3. Mapa requisito → lacuna → estudo

Requisitos técnicos de um produto de conexão dedicada com eBGP, na forma em
que aparecem no PRD interno (identificadores RF/RNF), sem dados comerciais.

| Requisito | O que o lab já provou | Lacuna | Estudo |
|---|---|---|---|
| RF15 eBGP IPv4 com ASN do cliente | 3 sessões eBGP, ASN de 16 bits (P001, P002-S005) | ASN de 32 bits nunca usado | E09 |
| RF19 autenticação MD5 | nada | `authSecretRef` nunca exercitado; negativo (senha errada) nunca medido | E09 |
| RF17 BFD habilitável, timers 3/9 | timers 3/9 e GR medidos (Módulo 4) | BFD inexistente no Cilium; detecção real com 3/9 nunca cronometrada | E10 |
| RNF05 detecção abaixo de 1 s | nada | idem | E10 |
| RF16 aprender só prefixos declarados | nada | Cilium sem filtro de import | E11 |
| RF20 limite de prefixos por sessão | nada | Cilium sem max-prefix | E11 |
| RF23 communities, prepend e MED | community `65301:100` anunciada em S010 | prepend e MED ausentes; efeito no border nunca medido | E12 |
| RF25–RF30 redundância em dois equipamentos, distribuição, failover automático, teste de failover | anycast ECMP imune a falhas; flap multi-nó com GR (P002) | nó dual-homed bloqueado pelo simulador; failover controlado "por tempo" nunca ensaiado | E13 |
| RF22 sessão BGP IPv6 | sessão dual-stack e VIP v6 na RIB (P002-S001) | alcance IPv6 fim a fim limitado pelo underlay | E14 |
| RF24 rotas em todas as zonas / VRF por tenant sem sobreposição | tenants por identidade (S009), sem VRF | Cilium OSS sem VRF; sobreposição de CIDR impossível | E15 |
| RF49 hub que alcança várias VPCs | nada | onde termina o eBGP do cliente e como o Cilium participa | E16 |
| RF18 rotas aprendidas/anunciadas com next-hop e AS path; RF31 estado operacional; RF33 métricas por conexão | `cilium bgp routes` e RIB do spine lidos manualmente | nenhuma coleta contínua; "três leituras consecutivas" nunca modelada | E17 |
| RF21 MTU 9000 | MTU 1500 versus 1450 medido (Cenário D) | jumbo nunca testado | E18 |
| RF45 MACsec, RF46 QinQ | WireGuard medido (S007/S008) | ambos fora do Cilium; fronteira a documentar | E18 |
| RNF10–RNF12 repetição sem efeito, alteração atômica, nenhum resíduo após remoção | rollback por nome verificado em todas as sessões | idempotência e resíduo dos CRDs BGP nunca medidos como propriedade | E19 |

## 4. Os estudos

Cada estudo segue o [protocolo de execução](estudos/execution-protocol.md):
sandbox `p003-gw` ou reconstituição equivalente, `k01` intocado, uma variável
por vez, esperado e observado separados, controle negativo, coleta externa ao
Cilium (RIB do border e captura) e rollback verificado. O executor não decide
o próprio aceite.

### E09 — Sessão eBGP autenticada com os parâmetros do produto

**Estado:** **CONCLUÍDO (`P005-S001` — PASS em 25/10/2026)** — publicado em [19 — Idempotência BGP e eBGP Autenticado TCP MD5 com ASN 32 bits](estudos/19-bgp-idempotency-md5-asn32.md).

Hipótese: o Cilium estabelece eBGP com MD5 e ASN de 32 bits contra FRR e
SR Linux, e uma senha divergente impede a sessão sem afetar as demais.

Ensaio: `CiliumBGPPeerConfig` com `authSecretRef` para um Secret no
namespace do Cilium, timers 3/9, GR on, ASN do peer em 32 bits (`4200000001`).
Três células: senha igual, senha diferente, Secret ausente. Negativo: a
sessão fica em `Active/Connect` e o `cilium bgp peers` mostra o motivo.
Coleta: `show network-instance default protocols bgp neighbor` no SR Linux,
`show bgp neighbors` no FRR, captura de TCP/179 com opção MD5 presente.

Gate: 4/4 células **PASS** em `vm-cilium` (`03-e09-bgp-md5-asn32.txt`): sessão `65302 <-> 4200000001` `established` em `3 s` com opção TCP 19 (`md5`) no `tcpdump`; senha divergente bloqueada em `active` (`TcpExtTCPMD5Failure=2`, `3/3` sessões do fabric intactas); Secret ausente fail-safe (`restarts=0`, `3/3` fabric intacto); rotação de chave `v1 -> v2` convergida em `9,39 s` com BGP `UPDATE` de 4 bytes (`0xfa56ea01`).

### E10 — Detecção de falha sem BFD: onde ela deve viver

**Estado:** **CONCLUÍDO (`P005-S002` — PASS em 25/10/2026)** — publicado em [11 — Limite de Prefixos, Communities/Prepend/MED e Detecção de Falha com BFD (`< 1 s`)](estudos/11-bgp-maxprefix-communities-bfd.md).

Hipótese: com hold 9 s, uma falha silenciosa de enlace só é detectada entre
6 e 9 s; BFD abaixo de 1 s só existe se o eBGP do cliente terminar em um
roteador que o suporte (FRR ou SR Linux), com o Cilium na sessão interna.

Ensaio A (Cilium direto): derrubar o enlace do nó com `admin-state disable`
no leaf e medir, com probes de 100 ms, o intervalo entre a falha e a
retirada do prefixo no spine. Ensaio B (borda com BFD): FRR `bfd` habilitado
no peering leaf↔border SR Linux, mesmo trigger, mesma métrica. Ensaio C:
hold reduzido ao mínimo aceito pela API do Cilium, para cronometrar o piso.

Ensaio D (opcional, se o PR #48251 for mesclado durante a trilha): BFD do
Cilium contra FRR com intervalos estritos, verificando as não-conformidades
abertas do GoBGP (jitter, RequiredMinRx) contra um PE real.

Gate: **PASS** (`04-e10-failure-detection-bfd.txt`): sob falha silenciosa de enlace (`iptables DROP` sem `TCP RST`/`FIN`), o Cilium com timers `3/9 s` convergiu em **`8901 ms`** (`> 1000 ms`); no piso da API BGP v2 (`1/3 s`, com `holdTimeSeconds=2` rejeitado pelo CRD validation), convergiu em **`3045 ms`** (`> 1000 ms`); já o pareamento `FRR PE <-> FRR CE` protegido por **BFD (`100 ms × 3`)** detectou a falha e retirou a rota `198.18.210.0/24` em **`359 ms < 1000 ms`**, cumprindo `RNF05`.

### E11 — Limite de prefixos e filtro de import

**Estado:** **CONCLUÍDO (`P005-S002` — PASS em 25/10/2026)** — publicado em [11 — Limite de Prefixos, Communities/Prepend/MED e Detecção de Falha com BFD (`< 1 s`)](estudos/11-bgp-maxprefix-communities-bfd.md).

Hipótese: o Cilium aceita qualquer quantidade de prefixos recebidos sem
limite nem filtro, e não os instala no kernel (route learning foi recusado
como CFP); o controle de "só prefixos declarados" e o max-prefix têm de
ficar no roteador que termina o cliente.

Ensaio: um FRR faz o papel do roteador do cliente e anuncia 50, 200 e 1.100
prefixos ao Cilium (célula 1) e ao FRR de borda com `maximum-prefix 100` e
`prefix-list` de import (célula 2). Medir `received_routes`, o estado da
sessão e o que aparece em `ip route` do nó (esperado: nada, porque o BGP
Control Plane não programa o datapath). Negativo: prefixo fora da lista
declarada não deve aparecer na RIB do border.

Gate: **PASS** (`02-e11-maxprefix-import.txt`): o Cilium OSS `1.20.2` manteve a sessão `established` ao receber `50`, `200` e `300` prefixos (`Received: 51 -> 201 -> 301` na `Adj-RIB-In` de `cilium-dbg bgp peers`, sem atributo `max-prefix` nem filtro de import na API BGP v2) e sem instalar nenhuma rota no kernel (`kernel_proto_bgp_routes=0`, `R6=0`); na borda FRR (`border1`) com `ip prefix-list E11-IMPORT-ALLOW` (`permit 198.18.0.0/16 le 32`) e `maximum-prefix 100`, os `50` prefixos `198.18.1.1/32..198.18.1.50/32` foram aceitos (`50` rotas), o prefixo não declarado `198.51.100.99/32` foi descartado (`% Network not in table`, `0` entradas na RIB) e o envio de `200` e `300` prefixos derrubou automaticamente a sessão com `Idle (PfxCt)` (`Maximum-prefix exceeded`).

### E12 — Communities, prepend e MED: marcar na origem, decidir na borda

**Estado:** **CONCLUÍDO (`P005-S002` — PASS em 25/10/2026)** — publicado em [11 — Limite de Prefixos, Communities/Prepend/MED e Detecção de Falha com BFD (`< 1 s`)](estudos/11-bgp-maxprefix-communities-bfd.md).

Hipótese: o Cilium só consegue **marcar** anúncios (communities); prepend e
MED devem ser aplicados por route-policy no border, disparados pela community.

Ensaio: dois `CiliumBGPAdvertisement` para a mesma VIP, um por rack, com
communities distintas (`65400:100` primário, `65400:200` secundário). No
border SR Linux, route-policy que faz `as-path prepend` e ajusta MED conforme
a community. Medir no FRR "cliente" o caminho preferido e a troca de caminho
ao retirar a community primária. Negativo: sem policy, os dois caminhos
ficam em ECMP.

Gate: **PASS** (`03-e12-communities-prepend-med.txt`): a VIP `10.202.255.192/32` marcada pelo Cilium com `65400:100` em `rack1` (`p003-gw-worker`, `AS 65301`) e `65400:200` em `rack2` (`p003-gw-worker2`, `AS 65302`) instalou ambos os next-hops (`10.255.212.1 via e12r1b` e `10.255.212.5 via e12r2b`) em ECMP de 2 vias (`multipath`) sem `route-map` em `border1`; ao ativar `RM-E12-RACK1-IN`, `RM-E12-RACK2-IN` e `RM-E12-TO-CE` em `border1` (`65400:100 -> metric 10`, `65400:200 -> metric 200 + as-path prepend 2x`), `10/10` (`100%`) das requisições de `frr-e12-ce` atingiram `e12-echo-rack1` (`p003-gw-worker`, `AS 65301`); e ao inverter as communities nos `CiliumBGPAdvertisement`s do Kubernetes, `10/10` (`100%`) das requisições migraram em `4 s` para `e12-echo-rack2` (`p003-gw-worker2`, `AS 65302`) sem tocar na CLI do roteador de borda.

### E13 — Redundância em dois equipamentos e teste de failover

Hipótese: com duas sessões eBGP para equipamentos distintos, o tráfego se
distribui por ECMP e a queda de uma sessão converge sem ação, dentro do
tempo de hold; um teste de failover controlado derruba uma sessão por tempo
determinado e a reestabelece sozinho.

Ensaio: dois borders FRR (`border1`, `border2`) com sessão ao mesmo leaf3 e
ao FRR "cliente"; o dual-homing do nó Kubernetes fica para um cluster real
(limitação do simulador registrada no Módulo 4). Trigger de failover por
`neighbor shutdown` temporizado no border. Medir gap entre OKs (lição L4),
distribuição por next-hop antes e depois e tempo até a sessão voltar.
Negativo: failover com GR desligado.

Gate: ambas as topologias (redundante no mesmo local e entre locais,
simuladas por dois borders) medidas com e sem GR.

### E14 — Sessão IPv6 e VIP IPv6 fim a fim

Hipótese: com o cliente e o underlay externo dual-stack, a VIP `fd14::a/128`
é alcançável do cliente, fechando o limite de P002-S001.

Ensaio: cliente do sandbox com IPv6 na interface e rota; border com
`afi-safi ipv6-unicast` para o "cliente"; sessão IPv6 dedicada (não apenas
IPv4 com família v6) no `CiliumBGPClusterConfig`. Medir 30 requisições HTTP
por IPv6 e a RIB IPv6 no FRR "cliente".

Gate: 30/30 por IPv6 do cliente; tabela de quais famílias viajam em qual
sessão.

### E15 — VRF por tenant: fabric com network-instance e Cilium atrás

Hipótese: o Cilium OSS não tem VRF na BGP Control Plane; o isolamento por
tenant com prefixos sem sobreposição pode ser feito com uma
`network-instance` por tenant no fabric (SR Linux) ou VRF no FRR, e o
Cilium anuncia cada tenant com uma community que a borda usa para importar
na VRF correta.

Ensaio: duas VRFs no border, dois `CiliumPodIPPool` (um por tenant) com
communities distintas, route-target por community. Negativo: pod do tenant
A não alcança prefixo do "cliente" B, mesmo com rota existente na VRF A.
Comparar com o isolamento por identidade de S009.

Gate: matriz de alcance entre tenants e "clientes" com 0 vazamentos;
limites explícitos (CIDR sobreposto continua impossível no lado Cilium OSS;
`IsovalentVRF` com SRv6 fica registrado como alternativa Enterprise a
avaliar em ambiente próprio, não neste sandbox).

### E16 — Onde termina o eBGP do cliente e como o Cilium participa

Hipótese: o roteador de borda termina a sessão do cliente (MD5, BFD,
max-prefix, policies) e o Cilium é o motor do lado interno: anuncia VIPs e
PodCIDRs por tenant e recebe as rotas do cliente pelo fabric.

Ensaio: topologia de referência com FRR "cliente" → border → fabric →
Cilium; três desenhos de retorno para o prefixo do cliente a partir de um
pod: rota default para o fabric (padrão), `CiliumEgressGatewayPolicy` para
fixar o IP de saída por nó, e rota estática no nó. Medir path, IP de origem
visto pelo "cliente" e comportamento sob falha de um nó de egress (no OSS os
endpoints são fixados a um gateway por UID e a troca de gateway quebra
conexões existentes). Célula extra: FRR como sidecar no nó, em sessão local
com o GoBGP, o padrão recomendado pelos mantenedores para BGP bidirecional.

Gate: desenho de referência com responsabilidades por camada e o custo de
cada opção de retorno.

### E17 — Observabilidade por conexão e estado operacional

Hipótese: `session_state`, `advertised_routes` e `received_routes` do
Cilium, somados à RIB do border, permitem derivar o estado "ativo,
degradado, desconhecido" com regra de três leituras consecutivas e defasagem
até 30 s.

Ensaio: Prometheus no sandbox raspando os agents; regra de gravação que
implementa as três leituras; gerar flap de sessão de 5 s, 20 s e 90 s e
comparar o estado derivado com o observado. Hubble com `--from-cidr` para
contar fluxos por prefixo de "cliente".

Gate: tabela flap → transição de estado → atraso medido; lista do que só a
borda (FRR/SR Linux) consegue expor (AS path completo, BFD state).

### E18 — MTU 9000, MACsec e QinQ: a fronteira do Cilium

Hipótese: MTU 9000 funciona em native routing quando todo o caminho aceita;
MACsec e QinQ são funções de enlace do switch e não têm contraparte no
Cilium; WireGuard de nó é a única criptografia que o Cilium oferece no
caminho.

Ensaio: MTU 9000 nos veths do containerlab, `ping -M do -s 8972` pod→pod e
cliente→VIP; QinQ entre "cliente" e border no SR Linux (o Cilium só passa
802.1Q por `bpf.vlanBypass`, em remoção); comparação de overhead de
WireGuard já medido em S007/S008.

Gate: matriz de MTU efetivo por segmento; documento de fronteira "switch
versus Cilium" para MACsec e QinQ.

### E19 — Ciclo de vida da configuração BGP: idempotência e resíduo

**Estado:** **CONCLUÍDO (`P005-S001` — PASS em 25/10/2026)** — publicado em [19 — Idempotência BGP e eBGP Autenticado TCP MD5 com ASN 32 bits](estudos/19-bgp-idempotency-md5-asn32.md).

Hipótese: aplicar o mesmo conjunto de CRDs BGP repetidamente não altera a
RIB; remover os CRDs de uma "conexão" retira todos os prefixos e não deixa
resíduo no nó, no fabric nem no GoBGP.

Ensaio: apply idêntico 10 vezes com snapshot da RIB e de
`cilium-dbg bgp route-policies`; delete e inventário do que resta (rotas no
kernel, sessões TCP/179, policies). Aplicar a mesma metodologia de E08 ao
"reuso" de uma VIP por outro serviço.

Gate: **PASS** (`02-e19-bgp-idempotency.txt`): `0` diffs em `10x kubectl apply` (`version: 488` constante em `border1`), `0` resíduos após teardown (`R6=0`) e reuso imediato da VIP `10.202.255.190/32` por `e19-echo-b` (`30/30` HTTP `200` em `/hostname` retornando `e19-echo-b-*`, `0` respostas antigas `e19-echo-a-*`).

### E20 — Cilium OSS + KubeVirt versus Isovalent Networking for Virtualization

Hipótese: com Cilium OSS e KubeVirt, uma VM vira endpoint Cilium com IP,
identidade por label, política e VIP por BGP; live migration não preserva o
IP do virt-launcher; dois tenants com o mesmo CIDR colidem. Com FRR no nó
(braço B, só depois do braço A), o `/32` da VM pode ser anunciado como EVPN
Type 5 numa VRF por tenant, mas o datapath do Cilium continua global.

Ensaio: casos V00 a V09 no sandbox. V00 é o gate de viabilidade: a VM
precisa receber e responder nos dois sentidos antes de qualquer outro caso,
porque KVM aninhado em container já matou a recepção da VM na trilha
OpenStack. Braço A: endpoint, VIP BGP, política por label, reuso de IP,
live migration, Multi-Pool `/32`, CIDR sobreposto e VM legada por pool `/32`.
Braço B: Cilium em sessão local com FRR, FRR com o fabric, EVPN Type 5 por
tenant, L2 estendido por Type 2.

Gate: tabela "Cilium OSS × Cilium + FRR × INV" com evidência por linha. As
linhas que só o INV cobre (CIDR sobreposto, IP preservado em migração,
identidade propagada ao fabric) viram os critérios de aceite de uma PoC do
produto.

#### Estado público do E20 (CONCLUÍDO — `P004-S001` a `P004-S008` PASS)

Todas as oito sessões de `P004` (`P004-S001` a `P004-S008`) foram concluídas com **PASS**, fechando `20-mgc-estado-parcial.md` (§1–§8) e os gates `G01` a `G08`:
- **P004-S001 (27/09/2026, PASS):** aprovou o ciclo comum do `labctl` (`k01` e `p003-gw`) e mediu a capacidade base (`D5 = NÃO`).
- **P004-S002 (23/10/2026, PASS):** publicou o perfil `labctl mgc` (`labctl/labs/mgc.sh`) e o harness auditável de `X05` (`studies/p004/ovn/`); provou `M01` (BGP/ECMP e falhas), `M02` (MTU 1500 vs 9000), `M03` (EVPN Type 5 causal) e **X05** (isolamento de CIDRs sobrepostos `192.168.100.0/24` e `169.254.254.0/30` entre `VNI 50100` e `VNI 50200` com `30/30` intra-tenant, `0/3` cross-tenant e `0` resíduos pós-rollback), além da pegada de memória (`0,539 GiB` para `mgc` + OVS host).
- **P004-S003 (23/10/2026, PASS):** publicou os perfis `labctl evpn-fabric` e `labctl ovnk` (`studies/p004/evpn-fabric/` e `studies/p004/ovnk/`) com OVN-Kubernetes v1.4.0, KubeVirt v1.9.0 em KVM nativo (`/dev/kvm`) e `frr-k8s` v0.0.27; provou o gate **`G03`** (`K01` UDN primária com CIDR sobreposto `10.100.0.0/24`, `K02` live migration preservando IP `.14` e sessão TCP com `0%` de perda, `K03` CUDN exportada via EVPN Type 5 e `K04` lift-and-shift de IP fixo `192.168.50.10/24`).
- **P004-S004 (24/10/2026, PASS):** publicou os casos cruzados `studies/p004/cases/x01..x07` e provou os gates **`G04`** e **`G05`** integrando simultaneamente `mgc`, `evpn-fabric` e `ovnk` + KubeVirt (`X01` tenant unificado nos 3 planos, `X02` isolamento 3 planos com `10.200.0.0/24` sobreposto, `X03` policy por BGP community, `X04` guardrail de Route-Target incorreto, `X06` admissão vs bloqueio de colisão em VRF hub e `X07` extensão L2 em `MAC-VRF` EVPN Type 2).
- **P004-S005 (24/10/2026, PASS):** publicou o Braço Cilium A (`studies/p004/cilium-a/`) com `KubeVirt v1.9.0` no cluster `p003-gw` (`Cilium 1.20.2`) e provou os casos **`V00–V06` (`C01–C06`)**: `V00` datapath KVM nativo bidirecional (`30/30`), `V01` VM como `CiliumEndpoint` (`sec_identity=172890`), `V02` VIP BGP `/32` (`10.202.255.20/32`, withdraw em `8 s`), `V03` `CiliumNetworkPolicy` por label na VM (`30/30` `client-a`, `0/30` `client-b` com `18` drops `Policy denied`), `V04` (Gate `G01`: reuso determinístico do mesmo IP `10.253.0.100/32` entre `vm-a-reuse` `sec_id=163024` e `vm-b-reuse` `sec_id=133690`, provando `0/30 ALLOW` e `25` drops `Policy denied` sob `fromEndpoints` vs `30/30 ALLOW` sob ACL por IP), `V05` (`H3`: live migration altera o IP do `virt-launcher` `10.245.2.190 -> 10.245.1.23`, derruba sessão TCP para o podIP antigo e reconverge a VIP BGP em `~3 s`) e `V06` (`H4`: Multi-Pool `/32` por VM anunciado em `border1` `10.252.0.23/32 -> 10.252.0.4/32` após migração, seguido de rollback limpo a `ipam.mode=kubernetes`).
- **P004-S006 (24/10/2026, PASS):** provou os negativos e limites estruturais do Braço Cilium A (`V07-A` / `C07` / `C-neg` / `H5`: dois namespaces compartilhando `10.253.10.0/24` operam sem VRF `vrf_count=0` com alcance direto entre `10.253.10.67` e `10.253.10.12`, enquanto dois pods exigindo o mesmo IP `10.253.10.100/32` falham com `putEndpointIdInvalid: IP ipv4:10.253.10.100 is already in use`; `V08-A` / `C08` / `H8`: cutover de VM legada QEMU/KVM `10.60.0.50/24` para VMI KubeVirt `10.60.0.50/32` em `pool-legacy-v08a` via BGP LPM em `cutover_total_s=39s`, `30/30` HTTP) e inaugurou o Braço Cilium B (**`H6` / Gate `G06`**: `DaemonSet/frr-node` `FRR 10.7.1` `AS 65301/65302` em peering iBGP `10.255.255.1:1790` com o Cilium `AS 65311/65312` e eBGP com o fabric, mantendo **`r6_kernel_bgp_routes = 0`** sob `table-map RM-NO-KERNEL` e concluindo rollback canônico com `MemAvailable = 4,23 GiB`).
- **P004-S007 (25/10/2026, PASS):** executou ao vivo e provou os casos restantes do Braço Cilium B em `vm-cilium` (`V09`/`H7` EVPN Type 5 por VRF `vrf-tenant-a` `VNI 10100` e `vrf-tenant-b` `VNI 10200` com `30/30` intra-VRF, `0/10` cross-VRF e `R6=0`; `V07-B` CIDR sobreposto `10.253.10.0/24` e IP idêntico `10.253.10.100/24` isolados por VRF/EVPN Type 5 no FRR `30/30` vs limite global `cilium_lxc` na `eth0`; `V08-B` cutover de IP legado `10.60.0.50/32` via `Cilium -> FRR 10.7.1 no nó -> border1` com `AS_PATH 65203 65600 65201 65301 65311`, `rib_em=27s`, `cutover_total=40s`, `30/30` HTTP, `R6=0` e rollback limpo a `ipam.mode=kubernetes` com `MemAvailable = 4,95 GiB >= 4,0 GiB`) e fechou `docs/estudos/20-mgc-estado-parcial.md` (§1–§8) com a matriz comparativa final **Cilium A vs Cilium B vs INV (`V00–V09` / `H1–H8`)** e o blueprint de transição para o Braço **OVN-Kubernetes (`C` / `D`)**.
- **P004-S008 (25/10/2026, PASS):** fechou o gate **`G07`** com a matriz de equivalência `INV × Cilium A × Cilium B × OVN-K (C/D)` e os seis critérios objetivos de aceite para uma PoC comercial do INV (`INV-PoC-01` a `INV-PoC-06` em `20-mgc-estado-parcial.md` §4.2), publicou a Edição 2.3 do Guia do Estudante e dos diagramas `08`/`09`, e aprovou o gate **`G08`** de higiene final dos laboratórios (`mgc`, `evpn-fabric` e `ovnk` desligados com `0` resíduos; `p003-os` preservado `exited`; `p003-gw` em baseline limpo `ipam=kubernetes`, `0` pools, `R6=0`; `k01` `10/10` e `MemAvailable = 4,95 GiB / 4,93 GiB >= 4,00 GiB`). Consulte a [síntese pública de P004](estudos/20-mgc-estado-parcial.md) para os resultados e limites completos.

Fontes: [INV GA](https://isovalent.com/blog/post/isovalent-networking-for-virtualization/),
[INV com Nexus One](https://www.cisco.com/c/en/us/products/collateral/networking/cloud-networking/nx-os/isovalent-net-v12n-int-n-one-fabric-so.html),
[lab Cilium + KubeVirt](https://isovalent.com/labs/cilium-kubevirt/),
[KubeVirt v1.9.0](https://github.com/kubevirt/kubevirt/releases/tag/v1.9.0).

### E21 — IPAM e tempo de implantação: VPC-native versus overlay

**Estado:** **CONCLUÍDO (`P005-S001` — PASS em 25/10/2026)** — publicado em [21 — `netkit` vs `veth` no Datapath eBPF & Escala de Burst IPAM com Warm Pool](estudos/21-netkit-vs-veth-ipam-burst.md).

Fonte: [Fleet-Scale Pod Deployment with VPC-Native Networking in Managed
Kubernetes](https://arxiv.org/pdf/2608.22210). O artigo compara IPs secundários,
pré-alocação de ENIs e delegação de prefixos no EKS, com Cilium e Calico como
baselines overlay. Os warm pools diferem entre modos; os resultados não
isolam apenas a granularidade da alocação.

Hipótese a testar: manter endereços disponíveis antes do burst reduz o tempo
até os pods ficarem Ready e a dependência de chamadas ao provedor.

Ensaio proposto: primeiro revisar metodologia e capacidade; depois comparar
bursts com imagem pré-carregada, recursos e versões fixados. Medir tempo até
Ready, pods/s, latência CNI ADD, consumo de IPs e chamadas de provisionamento,
incluindo throttling. Controle: variar warm pool dentro do mesmo modo; separar
entrada de nós e provisionamento de pods. EKS depende de orçamento e ambiente
dedicado aprovados; um ensaio local caracteriza apenas o braço overlay.

Gate: **PASS** (`05-e21-ipam-burst-scale.txt`): em rajadas de 16 pods (`registry.k8s.io/e2e-test-images/agnhost:2.47` pré-carregada nos nós), `ipam.mode=kubernetes` convergiu em `5,40 s` (`2,96 pods/s`, `0` erros CNI); `multi-pool` frio (`e21-burst-pool` `10.252.0.0/16` `maskSize: 32`, `ipam.multiPoolPreAllocation="default=8,e21-burst-pool=1"`) sofreu `27` falhas `postIpamFailure` (`502`); `multi-pool` pré-aquecido (`ipam.multiPoolPreAllocation="default=8,e21-burst-pool=32"`) **eliminou 100% dos erros `CNI ADD` (`27 -> 0`)**; e o controle negativo `e21-tiny-pool` (`10.253.21.0/29` `maskSize: 29`, `6` IPs utilizáveis para `10` pods) manteve `6 Running` e `4 Pending` sem afetar os `16/16` pods de `e21-burst-pool`.

### E22 — XLB: balanceamento L7 com eBPF na camada de sockets

**Estado:** **CONCLUÍDO (`P005-S002` — PASS em 25/10/2026)** — publicado em [22 — XLB: Balanceamento L7 eBPF na Camada de Sockets (`sockmap` / `bpf_sock_ops` / `sk_msg`) vs `SocketLB L4` e `Envoy L7`](estudos/22-xlb-ebpf-socket-lb-vs-envoy.md).

Fonte: [XLB: A High Performance Layer-7 Load Balancer for Microservices using
eBPF-based In-kernel Interposition](https://arxiv.org/pdf/2602.09473). O artigo
propõe interposição L7 no kernel, redirecionamento de sockets e mapas eBPF
aninhados, comparando com configurações de Istio e Cilium.

Hipótese a testar: reduzir movimentação de dados e escalonamento do proxy
pode melhorar desempenho sem perder a semântica L7 e o isolamento exigidos.

Ensaio proposto: verificar disponibilidade do código e requisitos de kernel;
comparar acesso direto, proxy L7 e XLB em cadeias HTTP equivalentes. Fixar
versões, políticas, conexões e posicionamento; conferir quais funções L7,
TLS e protocolos cada braço realmente oferece. Medir throughput, p50/p95/p99,
CPU, memória, erros e justiça entre serviços. Negativos: backend indisponível,
regra de roteamento divergente e tentativa de acesso entre tenants.

Gate: **PASS** (`05-e22-xlb-socket-lb-vs-envoy.txt`): em `100` requisições HTTP sequenciais em `e22-svc:8080`, comparados `Envoy L7` (`avg=1,014 ms`, `p95=1,418 ms`, `985,9 req/s`, `NET_RX delta=1692`), `SocketLB L4` (`bpf-lb-sock-hostns-only=false`: `avg=0,392 ms`, `p95=0,465 ms`, `2550,9 req/s`, `NET_RX delta=1309`) e `XLB Sockmap/sk_msg L7` (`BPF_MAP_TYPE_SOCKHASH` + `BPF_PROG_TYPE_SOCK_OPS` + `BPF_PROG_TYPE_SK_MSG`: **`avg=0,413 ms`, `p95=0,493 ms`, `2418,9 req/s` (`+145,4%` vs Envoy), `NET_RX delta=1220` (`-27,9%` vs Envoy e `-6,8%` vs SocketLB L4)**, `sk_msg_redirected=160` chamadas `bpf_msg_redirect_hash` concluídas com `SK_PASS` e bloqueio L7 in-kernel `SK_DROP` em `GET /deny` com `curl_rc=55`), além dos controles negativos `403 Forbidden` em `GET /deny` (Envoy L7), `rc=28` (tenant não autorizado) e `rc=7` (`0` réplicas), seguidos de rollback limpo ao baseline.

### E23 — Netkit versus veth no datapath de containers

**Estado:** **CONCLUÍDO (`P005-S001` — PASS em 25/10/2026)** — publicado em [21 — `netkit` vs `veth` no Datapath eBPF & Escala de Burst IPAM com Warm Pool](estudos/21-netkit-vs-veth-ipam-burst.md).

Fonte: [Netkit: Specializing Linux Packet Delivery for Container
Networks](https://arxiv.org/pdf/2609.18633). O artigo especializa a entrega
entre namespaces com eBPF, evitando travessias redundantes de backlog, e
avalia sua integração com Cilium.

Hipótese a testar: netkit reduz o custo da comunicação entre namespaces,
preservando conectividade e políticas das aplicações existentes.

Ensaio proposto: conferir suporte na combinação exata de kernel e Cilium;
comparar veth e netkit em sandbox dedicado, no mesmo nó e entre nós, com
conexões curtas e longas. Usar processos no mesmo namespace como referência.
Fixar MTU, offloads, CPU e configuração do CNI; medir throughput, p50/p95/p99,
CPU, softirq e drops. Negativos: política deny e tentativa de acesso cruzado
entre tenants, com captura externa. Compatibilidade com KubeVirt fica como
subensaio condicionado ao caminho suportado, sem assumir equivalência.

Gate: **PASS** (`04-e23-netkit-vs-veth.txt`): provada a guarda fail-closed do Cilium `1.20.2` na transição `veth -> netkit` com endpoints incompatíveis; em `datapath-mode=netkit` (`mode l3`, `NOARP`), o tráfego TCP bulk `iperf3` eliminou `100%` das retransmissões (`47 -> 0` same-node, `11 -> 0` cross-node) e reduziu softirqs `NET_RX` em `-8,9%` (same-node) e `-20,5%` (cross-node), mantendo `CiliumNetworkPolicy` com `leaked_pkts=0` e rollback limpo para `veth`.

### E24 — DRA no Cilium: alocação de recursos de rede por claim

**Estado:** BACKLOG — adicionado em 30/09/2026; não executado.

Fonte: branch [Cilium `feature/dra-driver`](https://github.com/cilium/cilium/tree/feature/dra-driver),
consultada em 30/09/2026 no commit
[`157b5331c727867fa009d8c6ec6ac8de92800ac9`](https://github.com/cilium/cilium/commit/157b5331c727867fa009d8c6ec6ac8de92800ac9).
O [driver DRA](https://github.com/cilium/cilium/blob/157b5331c727867fa009d8c6ec6ac8de92800ac9/pkg/networkdriver/dra.go)
implementa preparação e liberação de `ResourceClaim`, registro no kubelet e
publicação de interface/IPs em `NetworkDeviceData`. A branch é a referência
do estudo; isso não estabelece disponibilidade em release estável.

Hipótese a testar: Dynamic Resource Allocation (DRA) permite declarar e
acompanhar recursos de rede por claim, com alocação consistente, isolamento
e liberação verificável durante o ciclo de vida do pod.

Ensaio proposto: mapear arquitetura do driver, IPAM, CRDs, exemplos e testes;
fixar commit, imagens e versão/API Kubernetes exigidas. Em cluster dedicado,
exercitar claim válido, recurso indisponível, conflito entre claims e pool
esgotado. Verificar interface/IP no namespace do pod, status do claim,
conectividade e políticas. Testar repetição de prepare/unprepare, reinício
do driver e exclusão de pod/claim, medindo recuperação e resíduos. Não
pressupor suporte a hardware, SR-IOV ou KubeVirt sem confirmação no código.

Gate: claim/status e estado real da rede consistentes, conflitos recusados,
isolamento preservado, retries sem alocação duplicada e teardown sem IPs ou
interfaces órfãos; rollback do cluster experimental comprovado.

### E25 — Cilium/Hubble no RKE2: observabilidade do tráfego de microserviços

**Estado:** BACKLOG — adicionado em 13/10/2026; não executado.

Referência sugerida: [Cilium Hubble on RKE2: Microservice Traffic Observability
(Seeing the Invisible)](https://dev.to/ezejioforog/cilium-hubble-on-rke2-microservice-traffic-observability-seeing-the-invisible-5glb),
de George Ezejiofor. Complementa E17 com foco nos fluxos entre aplicações.
Conferir a configuração nas fontes primárias de
[Hubble](https://docs.cilium.io/en/stable/observability/hubble/setup/),
[métricas](https://docs.cilium.io/en/stable/observability/metrics/) e
[Cilium no RKE2](https://docs.rke2.io/networking/basic_network_options).

Hipótese a testar: correlacionar identidade, verdicts e métricas permite
distinguir falha da aplicação, conectividade e bloqueio por política.

Ensaio proposto: RKE2 dedicado, versões e chart fixados, configuração via
`HelmChartConfig`; habilitar Relay, UI e coleta Prometheus. Gerar tráfego
HTTP/DNS permitido e negado, comparar CLI/mapa/métricas com logs e captura
externa; contrastar L3/L4, HTTP com política L7 e tráfego TLS/mTLS. Medir
custo, retenção/perda de eventos e indisponibilidade do Relay; verificar
compatibilidade com AppArmor/KubeArmor sem copiar exceções de segurança do
relato como solução geral.

Gate: diagnóstico sustentado por evidências correlacionadas, limites de
visibilidade e retenção registrados, isolamento preservado e rollback
comprovado. Preparar acesso e redação de dados dos fluxos antes da coleta.

## 5. Ordem sugerida e ambiente

| Ordem | Estudo | Ambiente | Depende de |
|---|---|---|---|
| 1 | E19 idempotência | sandbox atual | nada |
| 2 | E09 MD5 + ASN 32 bits | sandbox + FRR "cliente" novo | nada |
| 3 | E11 max-prefix e import | E09 | FRR "cliente" |
| 4 | E12 communities/prepend/MED | E11 | route-policy no border |
| 5 | E10 detecção de falha | E09 | BFD no fabric |
| 6 | E13 redundância e failover | E10 | segundo border |
| 7 | E17 observabilidade | E13 | Prometheus no sandbox |
| 8 | E14 IPv6 fim a fim | sandbox dual-stack | reconfiguração do cliente |
| 9 | E15 VRF por tenant | E12 | network-instance no border |
| 10 | E16 desenho de terminação | E15 | todos os anteriores |
| 11 | E18 MTU/MACsec/QinQ | qualquer momento | nada |
| paralelo | E20 KubeVirt × INV | sandbox + KubeVirt | nada; braço B depois do braço A |
| backlog | E21 IPAM e implantação em escala | overlay local; EKS dedicado para braços VPC-native | revisão metodológica, capacidade e orçamento |
| backlog | E22 XLB L7 | sandbox dedicado | código reproduzível e requisitos de kernel |
| backlog | E23 netkit versus veth | sandbox dedicado | kernel/Cilium compatíveis e rollback |
| backlog | E24 DRA no Cilium | cluster experimental dedicado | commit pinado, build reproduzível e API Kubernetes compatível |
| backlog | E25 Hubble no RKE2 | RKE2 dedicado + microserviços de teste | versões/chart fixados, Prometheus e revisão de acesso aos fluxos |

O FRR "cliente" é um container novo no sandbox, fora do cluster, com sessão
ao border. Ele substitui o cliente HTTP nos ensaios de roteamento e permite
os negativos de prefixo, senha e policy sem tocar no fabric de referência.

## 6. Roteamento de execução

| Tarefa | Motor | Justificativa |
|---|---|---|
| Rascunho de manifests, route-policies e scripts de probe | gerador read-only de outro provedor | geração barata; validação obrigatória |
| Validação cruzada dos rascunhos | validador de provedor diferente do gerador | invariante de diversidade |
| Execução no sandbox, gates e aceite | harness principal | grounding e decisão |
| Grounding de versão e issue antes de cada sessão | busca web em fontes primárias | alegação volátil exige fonte datada |

## 7. Fontes

- [Cilium BGP Control Plane — recursos v2](https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-configuration/)
- [Cilium BGP Control Plane — operação](https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-operation/)
- [Cilium — métricas](https://docs.cilium.io/en/stable/observability/metrics/)
- [Cilium — CFP BFD no BGP Control Plane, issue 22394](https://github.com/cilium/cilium/issues/22394)
- [Cilium 1.20.0 — notas de release](https://github.com/cilium/cilium/releases/tag/v1.20.0)
- [Cilium — PR 48251, BFD no BGP Control Plane (rascunho)](https://github.com/cilium/cilium/pull/48251)
- [Cilium — CFP route learning, issue 34841 (fechada)](https://github.com/cilium/cilium/issues/34841) e [design-cfps 58](https://github.com/cilium/design-cfps/pull/58)
- [Cilium — PR 47394, peering unnumbered (aberto)](https://github.com/cilium/cilium/pull/47394)
- [Cilium 1.19.0 — notas de release](https://github.com/cilium/cilium/discussions/44191)
- [Cilium Egress Gateway](https://docs.cilium.io/en/stable/network/egress-gateway/egress-gateway/)
- [Cilium Cluster Mesh](https://docs.cilium.io/en/stable/network/clustermesh/setup/)
- [Cilium — VLAN 802.1Q](https://docs.cilium.io/en/latest/configuration/vlan-802.1q/)
- [Cilium — tuning e MTU](https://docs.cilium.io/en/latest/operations/performance/tuning/)
- [GoBGP — servidor e BFD parcial](https://pkg.go.dev/github.com/osrg/gobgp/v4/pkg/server) e [issue 3563](https://github.com/osrg/gobgp/issues/3563)
- [Isovalent Enterprise 1.13 — VRF e SRv6](https://isovalent.com/blog/post/isovalent-enterprise-1-13/)
- [Isovalent Enterprise 1.16 — BFD para BGP](https://isovalent.com/blog/post/isovalent-enterprise-for-cilium-1-16/)
- [Cilium Multi-Pool IPAM](https://docs.cilium.io/en/stable/network/concepts/ipam/multi-pool/)
- [FRR — BGP (maximum-prefix, prefix-list, route-map, bfd)](https://docs.frrouting.org/en/latest/bgp.html)
- [FRR — BFD](https://docs.frrouting.org/en/latest/bfd.html)
- [Nokia SR Linux — BGP](https://documentation.nokia.com/srlinux/25-3/books/routing-protocols/bgp.html)
- [RFC 2385 — TCP MD5 Signature Option](https://datatracker.ietf.org/doc/html/rfc2385)
- [RFC 5880 — BFD](https://datatracker.ietf.org/doc/html/rfc5880)
- [RFC 7938 — BGP em data centers de grande escala](https://datatracker.ietf.org/doc/html/rfc7938)
