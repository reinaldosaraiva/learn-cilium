# MGC Connect em P004: resultados de S002, evidências e limites

> Síntese pública atualizada em 23/10/2026. Os ensaios de P004-S002 (perfil
> `labctl mgc`, M01–M03, X05 e capacidade) foram concluídos com **PASS** em
> 23/10/2026; os braços OVN-Kubernetes e Cilium+KubeVirt seguem em S003–S005.
> Esta página registra resultados históricos datados e não informa o estado
> atual da VM.

Esta síntese acompanha a réplica didática da PoC MGC Connect com OVN, FRR e
EVPN. Ela documenta o que foi medido em P004-S002, explicita os limites de cada
caso e apoia a leitura do [módulo 13 do guia](../lab-guide-student.md#módulo-13--mgc-ovn-frr-e-evpn-o-que-os-resultados-provam).
O perfil `labctl/labs/mgc.sh` e os artefatos de `studies/p004/ovn/` estão
incluídos no checkout como referência de instrutor; o módulo 13 permanece como
exercício de interpretação dos resultados publicados.

A topologia de referência tem um central OVN, dois chassis e dois gateways.
Essa descrição é lógica e histórica, não um inventário ativo.

## O que foi medido

| Data | Caso | Evidência histórica | Limite do resultado |
|---|---|---|---|
| 27/09/2026 | P004-S001 — `labctl` | Ciclos de laboratório e verificação foram aprovados; a sessão fechou com PASS. | Esse resultado valida o ciclo comum medido naquela sessão. Não atesta a disponibilidade atual de qualquer laboratório. |
| 29/09/2026 | M01 — BGP, ECMP e falhas | Withdraw e faults controlados deixaram a rota externa somente pelo segundo gateway; o ping passou 30/30 em cada fault aceito. M01 foi aceito com exceção. | O fault FRR parou `bgpd`, `bfdd` e `zebra` dentro de `ovn-gw-1`, sem um container FRR dedicado. Os gateways usaram FRR 10.7.0 e o cliente 8.4.1_git. A falha do chassis `ovn-chassis-1` não foi testada; esse host hospedava a fixture da VM fake e era distinto do plano central OVN. |
| 29/09/2026 | M02 — MTU/PMTU | Com MTU 1500, pacote pequeno passou 30/30; jumbo IPv4 de 9000 B com DF não recebeu resposta em 30 tentativas (0/30), e houve ICMP Frag Needed com MTU 1500. Com MTU 9000, pacotes pequenos e jumbo passaram 30/30. As MTUs foram restauradas a 1500 e a verificação passou. | M02 foi aceito sob o escopo acordado. A reprodução literal do fragmento no tap físico da PoC permaneceu parcial. |
| 29/09/2026 | M03 — EVPN Type 5 | O peer EVPN externo recebeu `192.168.100.0/24` com VNI `50100`; o positivo respondeu 30/30. A7 definiu `dynamic-routing-redistribute=static` na LRP tenant, filtrando anúncios `connected` sem converter a origem da rota. A rota-alvo do SB, a rota tenant, o Type 5 e a FIB saíram; o ping teve 0/3 respostas. Duas rotas colaterais, BGP e VTEP permaneceram. Restaurar a chave ao estado ausente recuperou o caminho e o ping respondeu 3/3. | M03 foi aceito com o controle causal. Controle negativo literal do VNI: NOT_RUN; a remoção do VNI não estabelecia a causa do withdraw da rota exportada pelo router/FRR. |
| 23/10/2026 | X05 — CIDRs sobrepostos | **PASS** (`run c9d0e1` `G0→G8 RC=0` + prova negativa de rollback `b8c9d0` `G7+G8 PASS`). Dois tenants com a mesma sub-rede (`192.168.100.0/24`) e o mesmo `/30` de trânsito (`169.254.254.0/30`) em VRFs e VNIs distintos (`ovnvrf100`/VNI `50100` e `ovnvrf50200`/VNI `50200`, RT `65000:50200`) mantiveram alcance intra-tenant 30/30, 0/3 cross-tenant nos quatro sentidos com 0 pacotes no `tcpdump` do destino, e 0 resíduos após rollback canônico. | O isolamento foi provado no braço MGC/OVN+FRR com VXLAN bridge no peer EVPN (`Router MAC` da rota Type 5 alinhado ao MAC de `br-vxlan50200`: `02:00:00:20:00:01`). Não se transfere por inferência para OVN-K nem para Cilium OSS. |
| 23/10/2026 | 09-capacidade — Pegada de memória | **PASS**. Os 5 containers `mgc` (`ovn-central`, `ovn-chassis-1/2`, `ovn-gw-1/2`) somaram `244,77 MiB` + OVS host `306,8 MiB` = `0,539 GiB` (`13,5%` da estimativa de `4 GiB`), com `MemAvailable = 6,38 GiB` enquanto `k01` + `p003-gw` + `mgc` estavam ativos simultaneamente (`D5 = NÃO`). | Medição em containers com sentinelas `netns`/processos leves, não VMs KVM completas; o perfil `ovnk` com KubeVirt tem gate próprio de memória (`>= 8 GiB`). |

Com `M01–M03`, `X05` e a medição de capacidade aceitos, **P004-S002 fechou com
PASS em 23/10/2026**, incluindo a qualificação progressiva `Q0–Q4` do backend
Linux `D1` e o manifesto de fontes pinado (`D2`). Os braços OVN-Kubernetes +
UDN + EVPN + KubeVirt (`P004-S003`), Cilium + KubeVirt/FRR (`P004-S004`) e a
comparação integral com Isovalent Networking for Virtualization (`P004-S005`)
seguem nas próximas sessões de P004.

## Termos para ler os resultados

| Termo | Significado neste estudo |
|---|---|
| **OVN logical router** | Roteador lógico que conecta a rede tenant às conexões externas; não é uma tabela Linux VRF. |
| **Linux VRF** | Tabela de roteamento separada criada em cada gateway: `ovnvrf100` e `ovnvrf200`. As conexões BGP do MGC usam esses contextos. |
| **FRR no gateway** | `bgpd`, `bfdd` e `zebra` rodam dentro dos próprios containers de gateway. Isso explica a exceção de M01: o teste parou os daemons, não um container FRR separado. |
| **Cliente legado AS 200** | Par BGP dos gateways que anunciou `10.0.0.0/16`; esse é o caminho de M01/M02. |
| **VPC tenant e VM fake** | A rede `192.168.100.0/24` continha a fixture `192.168.100.10`; ela representa o lado OVN do ensaio, não uma VM KubeVirt. |
| **EVPN Type 5** | Anúncio de um prefixo IP do tenant para o peer EVPN externo. O prefixo observado foi `192.168.100.0/24`, associado ao VNI `50100`. |
| **VNI** | Identificador da rede EVPN. O tenant A usou `50100` (`ovnvrf100`) e o tenant B usou `50200` (`ovnvrf50200`, RT `65000:50200`), isolando o mesmo CIDR `192.168.100.0/24` em domínios de roteamento distintos. |
| **Router MAC em EVPN Type 5** | Em VXLAN anexado a bridge Linux, o pacote desencapsulado precisa trazer no destino Ethernet interno o MAC da bridge local do VRF (`br-vxlan50200`, `02:00:00:20:00:01`) para que o kernel eleve o quadro como `PACKET_HOST` ao roteamento L3 do VRF. |
| **Controle negativo causal** | Filtro de redistribuição `dynamic-routing-redistribute=static` na LRP tenant. Ele excluiu anúncios de rotas `connected`; não converteu a origem da rota para `static`. A rota-alvo saiu enquanto BGP, VTEP e duas rotas colaterais permaneceram. |

## Três caminhos de estudo

| Caminho | Estado em 23/10/2026 | O que se pode concluir |
|---|---|---|
| MGC + OVN + FRR | **Completo em P004-S002 (PASS)**: `labctl mgc`, M01, M02, M03, X05 e capacidade aceitos. | A réplica reproduziu BGP/ECMP, MTU/PMTU, EVPN Type 5 e isolamento de CIDRs sobrepostos (`192.168.100.0/24` e `/30` `169.254.254.0/30`) entre VRFs/VNIs distintos (`50100`/`50200`), com `0` resíduos pós-rollback. |
| OVN-Kubernetes + UDN + EVPN + KubeVirt | Em andamento em P004-S003. | Avalia UDN primária com CIDR sobreposto, live migration de VM KubeVirt e integração EVPN Type 5 (`K01–K04`). |
| Cilium OSS + KubeVirt + FRR | Planejado para P004-S004. | Os resultados MGC não provam que esse braço tenha as mesmas capacidades ou limites. |

## Perguntas e respostas para a pessoa estudante

**1. “O guia diz que não há VRF. Isso contradiz a réplica MGC?”**

Não. A limitação de “sem VRF” descreve os estudos Cilium OSS de P001–P003.
O braço MGC é uma arquitetura separada: os gateways usaram Linux VRFs. Isso
também não quer dizer que todos os braços de P004 tenham VRF ou isolamento
equivalente.

**2. “M01 passou mesmo que o FRR não estivesse em container próprio?”**

Sim, dentro da exceção aceita para a réplica: o controle parou os daemons FRR
dentro de um gateway e o tráfego medido continuou pela outra conexão. O
resultado não equivale ao teste literal de parar um container FRR separado,
nem cobre a falha de `ovn-chassis-1`.

**3. “M02 provou que o jumbo atravessa um caminho com MTU 1500?”**

Não. Com MTU 1500, o jumbo com DF não recebeu resposta em 30 tentativas
(0/30), e o roteador informou MTU 1500;
com MTU 9000, os testes de pacote pequeno e jumbo passaram 30/30. O caso
validou o comportamento PMTU dentro do escopo aceito, enquanto a reprodução
literal do fragmento no tap físico permaneceu parcial.

**4. “Por que M03 usou uma mudança causal em vez de remover o VNI?”**

A7 definiu `dynamic-routing-redistribute=static` na LRP tenant. Esse filtro
selecionou rotas `static` para redistribuição e excluiu a rota `connected`;
a origem da rota não foi alterada. A rota-alvo, o Type 5 e a FIB saíram,
enquanto BGP, VTEP e duas rotas colaterais permaneceram. O ping teve 0/3
respostas; ao restaurar a chave ao estado ausente, respondeu 3/3. O controle
negativo literal do VNI ficou NOT_RUN porque sua remoção não tinha causalidade
estabelecida com o anúncio Type 5 do router/FRR.

**5. “M03 prova sozinho que dois tenants podem usar o mesmo CIDR? E o que X05 acrescentou?”**

M03 provou apenas o anúncio e o alcance de um único prefixo tenant no VNI
`50100`. A prova de CIDRs sobrepostos veio em **X05** (aceito com PASS em
23/10/2026): um segundo tenant B foi instanciado com os mesmos prefixos
`192.168.100.0/24` e `169.254.254.0/30` no VRF `ovnvrf50200` (VNI `50200`, RT
`65000:50200`), mantendo 30/30 de alcance intra-tenant nos dois domínios, 0/3
nas quatro direções cross-tenant com 0 pacotes capturados no destino e rollback
canônico (`G7+G8`) com 0 resíduos. A comparação com OVN-Kubernetes (`S003`),
Cilium+KubeVirt (`S004`) e INV (`S005`) segue nas próximas sessões.

**6. “Posso usar este documento para saber se a VM está ligada?”**

Não. As datas e contagens são registros históricos de execuções fechadas.
Embora o perfil `labctl/labs/mgc.sh` e o harness `studies/p004/ovn/` façam
parte deste checkout para inspeção e uso pelo instrutor, o módulo 13 do guia é
uma atividade de interpretação das evidências documentadas.

## Leituras relacionadas

- [Módulo 13 do guia do estudante](../lab-guide-student.md#módulo-13--mgc-ovn-frr-e-evpn-o-que-os-resultados-provam)
- [Resumo público de resultados](../lab-results.md)
- [Próximos estudos E09–E20](../proximos-estudos.md)
- [Índice de diagramas](../diagramas/README.md)
