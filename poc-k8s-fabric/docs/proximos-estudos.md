# Próximos estudos — Cilium como motor de uma conexão dedicada com eBGP

> Proposta de trilha (P004) escrita em 26/09/2026, depois do encerramento da
> trilha P003. Nada aqui foi executado. Cada estudo nasce de uma lacuna
> registrada no [guia do estudante 2.0](lab-guide-student.md) ou de um
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
| BFD | **não suportado**; a doc de operação diz "currently, Cilium does not support it"; CFP #22394 aberta desde 2022 | [Operação BGP](https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-operation/), [issue 22394](https://github.com/cilium/cilium/issues/22394) |
| Limite de prefixos aprendidos por sessão | **não exposto** na API v2 | ausência na página de recursos |
| Filtro de import (aceitar só prefixos declarados) | **não exposto**; o Cilium não instala rotas recebidas no kernel do nó | ausência na página de recursos |
| Communities standard, large e well-known nos anúncios | suportado por `advertisementType` | página de recursos |
| `localPreference` | só iBGP; ignorado em eBGP | página de recursos |
| AS-path prepend e MED | **não expostos** | ausência na página de recursos |
| Métricas de sessão e rotas | `cilium_bgp_control_plane_session_state`, `advertised_routes`, `received_routes`, `reconcile_*` | [Métricas](https://docs.cilium.io/en/stable/observability/metrics/) |
| CLI de estado | `cilium bgp peers`, `cilium bgp routes advertised/available`, `cilium-dbg bgp route-policies` | Operação BGP |
| Motor BGP | GoBGP 4.6.1 (1.20.0), com novos comandos de shell e reconciliação de route-policy | [Release 1.20.0](https://github.com/cilium/cilium/releases/tag/v1.20.0) |
| Gateway `hostNetwork` para L4 | não expõe listener no nó (medido em S004) | Módulo 6 do guia |
| Dual-homing do nó em duas sessões | design pronto; o simulador SR Linux não estabelece TCP/179 em porta adicionada em runtime | Módulo 4 do guia |

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

Hipótese: o Cilium estabelece eBGP com MD5 e ASN de 32 bits contra FRR e
SR Linux, e uma senha divergente impede a sessão sem afetar as demais.

Ensaio: `CiliumBGPPeerConfig` com `authSecretRef` para um Secret no
namespace do Cilium, timers 3/9, GR on, ASN do peer em 32 bits (`4200000001`).
Três células: senha igual, senha diferente, Secret ausente. Negativo: a
sessão fica em `Active/Connect` e o `cilium bgp peers` mostra o motivo.
Coleta: `show network-instance default protocols bgp neighbor` no SR Linux,
`show bgp neighbors` no FRR, captura de TCP/179 com opção MD5 presente.

Gate: 3/3 células conforme esperado; troca de senha em produção
documentada com janela medida de queda e reestabelecimento.

### E10 — Detecção de falha sem BFD: onde ela deve viver

Hipótese: com hold 9 s, uma falha silenciosa de enlace só é detectada entre
6 e 9 s; BFD abaixo de 1 s só existe se o eBGP do cliente terminar em um
roteador que o suporte (FRR ou SR Linux), com o Cilium na sessão interna.

Ensaio A (Cilium direto): derrubar o enlace do nó com `admin-state disable`
no leaf e medir, com probes de 100 ms, o intervalo entre a falha e a
retirada do prefixo no spine. Ensaio B (borda com BFD): FRR `bfd` habilitado
no peering leaf↔border SR Linux, mesmo trigger, mesma métrica. Ensaio C:
hold reduzido ao mínimo aceito pela API do Cilium, para cronometrar o piso.

Gate: tabela com tempo de detecção por célula e recomendação explícita de
onde terminar a sessão do cliente. Fonte: issue 22394 permanece aberta;
qualquer mudança de status é registrada como emenda.

### E11 — Limite de prefixos e filtro de import

Hipótese: o Cilium aceita qualquer quantidade de prefixos recebidos sem
limite nem filtro, e não os instala no kernel; o controle de "só prefixos
declarados" e o max-prefix têm de ficar no roteador que termina o cliente.

Ensaio: um FRR faz o papel do roteador do cliente e anuncia 50, 200 e 1.100
prefixos ao Cilium (célula 1) e ao FRR de borda com `maximum-prefix 100` e
`prefix-list` de import (célula 2). Medir `received_routes`, o estado da
sessão e o que aparece em `ip route` do nó. Negativo: prefixo fora da lista
declarada não deve aparecer na RIB do border.

Gate: comportamento do Cilium documentado por número (aceita tudo, sem
instalação no kernel) e comprovação de que a borda FRR descarta o excesso e
o não declarado.

### E12 — Communities, prepend e MED: marcar na origem, decidir na borda

Hipótese: o Cilium só consegue **marcar** anúncios (communities); prepend e
MED devem ser aplicados por route-policy no border, disparados pela community.

Ensaio: dois `CiliumBGPAdvertisement` para a mesma VIP, um por rack, com
communities distintas (`65400:100` primário, `65400:200` secundário). No
border SR Linux, route-policy que faz `as-path prepend` e ajusta MED conforme
a community. Medir no FRR "cliente" o caminho preferido e a troca de caminho
ao retirar a community primária. Negativo: sem policy, os dois caminhos
ficam em ECMP.

Gate: preferência de caminho controlada de ponta a ponta com evidência no
"cliente"; matriz do que o Cilium faz e do que a borda faz.

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
limites explícitos (CIDR sobreposto continua impossível no lado Cilium).

### E16 — Onde termina o eBGP do cliente e como o Cilium participa

Hipótese: o roteador de borda termina a sessão do cliente (MD5, BFD,
max-prefix, policies) e o Cilium é o motor do lado interno: anuncia VIPs e
PodCIDRs por tenant e recebe as rotas do cliente pelo fabric.

Ensaio: topologia de referência com FRR "cliente" → border → fabric →
Cilium; três desenhos de retorno para o prefixo do cliente a partir de um
pod: rota default para o fabric (padrão), `CiliumEgressGatewayPolicy` para
fixar o IP de saída por nó, e rota estática no nó. Medir path, IP de origem
visto pelo "cliente" e comportamento sob falha de um nó de egress.

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
cliente→VIP; QinQ entre "cliente" e border no SR Linux; comparação de
overhead de WireGuard já medido em S007/S008.

Gate: matriz de MTU efetivo por segmento; documento de fronteira "switch
versus Cilium" para MACsec e QinQ.

### E19 — Ciclo de vida da configuração BGP: idempotência e resíduo

Hipótese: aplicar o mesmo conjunto de CRDs BGP repetidamente não altera a
RIB; remover os CRDs de uma "conexão" retira todos os prefixos e não deixa
resíduo no nó, no fabric nem no GoBGP.

Ensaio: apply idêntico 10 vezes com snapshot da RIB e de
`cilium-dbg bgp route-policies`; delete e inventário do que resta (rotas no
kernel, sessões TCP/179, policies). Aplicar a mesma metodologia de E08 ao
"reuso" de uma VIP por outro serviço.

Gate: 0 diferenças entre snapshots; 0 resíduos após remoção, com lista de
verificação reutilizável.

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
- [Cilium Egress Gateway](https://docs.cilium.io/en/stable/network/egress-gateway/egress-gateway/)
- [Cilium Multi-Pool IPAM](https://docs.cilium.io/en/stable/network/concepts/ipam/multi-pool/)
- [FRR — BGP (maximum-prefix, prefix-list, route-map, bfd)](https://docs.frrouting.org/en/latest/bgp.html)
- [FRR — BFD](https://docs.frrouting.org/en/latest/bfd.html)
- [Nokia SR Linux — BGP](https://documentation.nokia.com/srlinux/25-3/books/routing-protocols/bgp.html)
- [RFC 2385 — TCP MD5 Signature Option](https://datatracker.ietf.org/doc/html/rfc2385)
- [RFC 5880 — BFD](https://datatracker.ietf.org/doc/html/rfc5880)
- [RFC 7938 — BGP em data centers de grande escala](https://datatracker.ietf.org/doc/html/rfc7938)
