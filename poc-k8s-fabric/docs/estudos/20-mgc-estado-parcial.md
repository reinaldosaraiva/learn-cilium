# MGC Connect em P004: estado parcial, evidências e limites

> Síntese pública atualizada em 07/10/2026. Os ensaios descritos ocorreram
> entre 27 e 29/09/2026. P004 continua incompleto; esta página registra
> resultados históricos e não informa o estado atual da VM.

Esta síntese acompanha a réplica didática da PoC MGC Connect com OVN, FRR e
EVPN. Ela separa o que foi medido do que continua pendente e ajuda a ler o
[módulo 13 do guia](../lab-guide-student.md#módulo-13--mgc-ovn-frr-e-evpn-o-que-os-resultados-provam).
Não há comandos aqui para iniciar ou repetir a réplica.

A topologia de referência tinha um central OVN, dois chassis e dois gateways.
Essa descrição é lógica e histórica, não um inventário ativo.

## O que foi medido

| Data | Caso | Evidência histórica | Limite do resultado |
|---|---|---|---|
| 27/09/2026 | P004-S001 — `labctl` | Ciclos de laboratório e verificação foram aprovados; a sessão fechou com PASS. | Esse resultado valida o ciclo comum medido naquela sessão. Não atesta a disponibilidade atual de qualquer laboratório. |
| 29/09/2026 | M01 — BGP, ECMP e falhas | Withdraw e faults controlados deixaram a rota externa somente pelo segundo gateway; o ping passou 30/30 em cada fault aceito. M01 foi aceito com exceção. | O fault FRR parou `bgpd`, `bfdd` e `zebra` dentro de `ovn-gw-1`, sem um container FRR dedicado. Os gateways usaram FRR 10.7.0 e o cliente 8.4.1_git. A falha do chassis `ovn-chassis-1` não foi testada; esse host hospedava a fixture da VM fake e era distinto do plano central OVN. |
| 29/09/2026 | M02 — MTU/PMTU | Com MTU 1500, pacote pequeno passou 30/30; jumbo IPv4 de 9000 B com DF não recebeu resposta em 30 tentativas (0/30), e houve ICMP Frag Needed com MTU 1500. Com MTU 9000, pacotes pequenos e jumbo passaram 30/30. As MTUs foram restauradas a 1500 e a verificação passou. | M02 foi aceito sob o escopo acordado. A reprodução literal do fragmento no tap físico da PoC permaneceu parcial. |
| 29/09/2026 | M03 — EVPN Type 5 | O peer EVPN externo recebeu `192.168.100.0/24` com VNI `50100`; o positivo respondeu 30/30. A7 definiu `dynamic-routing-redistribute=static` na LRP tenant, filtrando anúncios `connected` sem converter a origem da rota. A rota-alvo do SB, a rota tenant, o Type 5 e a FIB saíram; o ping teve 0/3 respostas. Duas rotas colaterais, BGP e VTEP permaneceram. Restaurar a chave ao estado ausente recuperou o caminho e o ping respondeu 3/3. | M03 foi aceito com o controle causal. Controle negativo literal do VNI: NOT_RUN; a remoção do VNI não estabelecia a causa do withdraw da rota exportada pelo router/FRR. |
| Checkpoint 07/10/2026 | X05 — CIDRs sobrepostos | O teste de isolamento entre dois tenants com CIDRs sobrepostos não foi aceito. | Não há prova de isolamento para esse caso. O estado operacional mais recente do laboratório é desconhecido; não se deve inferir que esteja limpo ou ativo. |

M01, M02 e M03 têm resultados delimitados, mas não completam P004. X05 ainda
precisa de evidência aceita para isolamento entre subnets sobrepostas.
P004-S003, com OVN-Kubernetes, UDN, EVPN e KubeVirt, e o braço Cilium com
KubeVirt/FRR continuam planejados. A comparação integral com Isovalent
Networking for Virtualization (INV) não foi feita.

Até 07/10, o backend Linux do launcher e sua qualificação não tinham sido
executados (D1). A preparação local do binding estrito de fontes (D2) também
não equivale a teste Linux, de VM ou do datapath.

## Termos para ler os resultados

| Termo | Significado neste estudo |
|---|---|
| **OVN logical router** | Roteador lógico que conecta a rede tenant às conexões externas; não é uma tabela Linux VRF. |
| **Linux VRF** | Tabela de roteamento separada criada em cada gateway: `ovnvrf100` e `ovnvrf200`. As conexões BGP do MGC usam esses contextos. |
| **FRR no gateway** | `bgpd`, `bfdd` e `zebra` rodam dentro dos próprios containers de gateway. Isso explica a exceção de M01: o teste parou os daemons, não um container FRR separado. |
| **Cliente legado AS 200** | Par BGP dos gateways que anunciou `10.0.0.0/16`; esse é o caminho de M01/M02. |
| **VPC tenant e VM fake** | A rede `192.168.100.0/24` continha a fixture `192.168.100.10`; ela representa o lado OVN do ensaio, não uma VM KubeVirt. |
| **EVPN Type 5** | Anúncio de um prefixo IP do tenant para o peer EVPN externo. O prefixo observado foi `192.168.100.0/24`, associado ao VNI `50100`. |
| **VNI** | Identificador da rede EVPN. O ensaio positivo usou `50100`; isso, por si só, não demonstra isolamento entre dois tenants com o mesmo CIDR. |
| **Controle negativo causal** | Filtro de redistribuição `dynamic-routing-redistribute=static` na LRP tenant. Ele excluiu anúncios de rotas `connected`; não converteu a origem da rota para `static`. A rota-alvo saiu enquanto BGP, VTEP e duas rotas colaterais permaneceram. |

## Três caminhos de estudo

| Caminho | Estado em 07/10/2026 | O que se pode concluir |
|---|---|---|
| MGC + OVN + FRR | Parcialmente medido: M01, M02 e M03 aceitos nos escopos descritos; X05 sem aceite. | A réplica reproduziu comportamentos específicos de BGP, MTU/PMTU e EVPN Type 5. Não demonstrou CIDRs sobrepostos nem a PoC inteira. |
| OVN-Kubernetes + UDN + EVPN + KubeVirt | Planejado, ainda não avaliado. | Nenhuma conclusão sobre isolamento ou migração de VMs nesse braço. |
| Cilium OSS + KubeVirt + FRR | Planejado, ainda não avaliado. | Os resultados MGC não provam que esse braço tenha as mesmas capacidades ou limites. |

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

**5. “M03 prova que dois tenants podem usar o mesmo CIDR?”**

Não. M03 provou o anúncio e o alcance de um prefixo tenant. X05, o ensaio de
isolamento com CIDRs sobrepostos, não foi aceito. A comparação final com INV
também permanece pendente.

**6. “Posso usar este documento para saber se a VM está ligada ou repetir o
ensaio?”**

Não. As datas e contagens são históricas. O estado operacional mais recente é
desconhecido, e este checkout não oferece o perfil MGC executável. O módulo 13
é uma atividade de interpretação dos resultados fornecidos.

## Leituras relacionadas

- [Módulo 13 do guia do estudante](../lab-guide-student.md#módulo-13--mgc-ovn-frr-e-evpn-o-que-os-resultados-provam)
- [Resumo público de resultados](../lab-results.md)
- [Próximos estudos E09–E20](../proximos-estudos.md)
- [Índice de diagramas](../diagramas/README.md)
