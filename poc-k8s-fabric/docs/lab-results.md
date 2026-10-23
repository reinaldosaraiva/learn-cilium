# Resultados públicos do laboratório

Este resumo separa a reconstrução datada de 19/09/2026 dos resultados históricos de outros cenários. Ele dá contexto ao guia sem expor evidência privada nem afirmar o estado atual da VM.

## Estado observado na reconstrução de 19/09/2026

Em 19 de setembro de 2026, o laboratório `poc-kind.clab.yml` foi reconstruído dentro de uma única `vm-cilium`:

| Verificação | Observação |
|---|---|
| Topologia | cinco SR Linux `25.3.2`, `border1` FRR `8.4.1`, `client-ext` e três nós kind |
| Cluster | `k01`, Kubernetes `v1.35.0`, três nós `Ready` |
| Cilium | `1.20.1`, agents saudáveis nos três nós |
| Aplicação | seis réplicas `echo`, todas prontas |
| BGP Cilium | três sessões IPv4/IPv6 estabelecidas |
| VIP | `10.201.255.10/32`, ativa no spine com dois próximos saltos ECMP observados |
| Acesso interno | `client-ext` alcançou a VIP por HTTP |
| Acesso pelo computador | túnel SSH local em `127.0.0.1:18081` respondeu `10/10` vezes com HTTP 200 |
| Backends no túnel | cinco hostnames distintos apareceram nas dez respostas |
| Escopo | o laboratório ficou no ar; nenhum cluster MKE foi usado nessa validação |

O `client-ext` é externo ao cluster Kubernetes, mas fica dentro da mesma VM. O túnel SSH termina no host da VM e encaminha a porta local para a VIP; ele não publica a VIP na Internet.

## Resultados históricos do kit

Em uma rodada de escala anterior, o deployment `echo` foi ampliado de seis para quarenta pods. Os PodCIDRs por nó continuaram agregados e a tabela do fabric não cresceu na mesma proporção que a quantidade de pods. Essa é a observação que motiva o exercício `/24` versus `/32`; ela não transforma quarenta pods em quarenta anúncios independentes.

Também foi observado native routing com o IP real do pod no tráfego do fabric e ausência de UDP/8472 nessa variante. A variante IPv6 provou o plano de controle e rotas internas, mas o alcance da VIP IPv6 a partir do `client-ext` permaneceu limitado pelo underlay externo IPv4. Os números de throughput do laboratório em containers não são uma previsão de hardware de produção.

## P004 — resultados históricos da réplica MGC (P004-S002 PASS)

O ciclo comum do `labctl` foi aprovado em 27/09/2026 (`P004-S001`). Na réplica
MGC (`P004-S002`, concluída com **PASS** em 23/10/2026), os casos M01, M02, M03,
X05 e a medição de capacidade foram aceitos com escopo e limites explícitos:

| Caso | Estado documentado | Resultado e limite |
|---|---|---|
| M01 — sessão, ECMP e falhas | PASS com exceção (29/09) | Os daemons FRR foram parados dentro do gateway, sem container FRR dedicado; as versões medidas também diferiram das planejadas. A falha do chassis `ovn-chassis-1` não foi testada; esse host hospedava a fixture da VM fake e era distinto do plano central OVN. |
| M02 — MTU/PMTU | PASS sob o escopo aceito (29/09) | Com MTU 1500, pacotes pequenos passaram 30/30 e o jumbo IPv4 9000 B/DF não recebeu resposta em 30 tentativas (0/30); houve ICMP Frag Needed. Com MTU 9000, ambos passaram 30/30; as MTUs foram restauradas a 1500. A reprodução literal do fragmento no tap físico permaneceu parcial. |
| M03 — EVPN Type 5 | PASS com controle causal (29/09) | O peer externo recebeu `192.168.100.0/24` no VNI `50100`; o positivo respondeu 30/30. O override `dynamic-routing-redistribute=static` na LRP tenant filtrou anúncios de rotas `connected`, sem mudar a origem da rota. Isso retirou a rota-alvo do SB, a rota tenant, o Type 5 e a FIB, e o ping teve 0/3 respostas; BGP, VTEP e duas rotas colaterais permaneceram. Restaurar a chave ao estado ausente recuperou o caminho e o ping respondeu 3/3. Controle negativo literal do VNI: NOT_RUN. |
| X05 — CIDRs sobrepostos | **PASS** (23/10/2026) | Dois tenants com `192.168.100.0/24` e `169.254.254.0/30` sobrepostos em `ovnvrf100` (VNI `50100`) e `ovnvrf50200` (VNI `50200`, RT `65000:50200`): alcance intra-tenant 30/30 nos dois domínios, 0/3 nas quatro direções cross-tenant com 0 pacotes capturados no destino (`tcpdump`) e rollback canônico (`G7+G8`) com 0 resíduos (`run c9d0e1` + prova negativa `b8c9d0`). Exige alinhamento do `Router MAC` Type 5 com a bridge VXLAN do peer (`02:00:00:20:00:01`). |
| 09-capacidade — memória | **PASS** (23/10/2026) | `mgc` (5 containers: `244,77 MiB`) + OVS host (`306,8 MiB`) = `0,539 GiB` (`13,5%` da estimativa de `4 GiB`); `MemAvailable = 6,38 GiB` com `k01` + `p003-gw` + `mgc` simultâneos (`D5 = NÃO`). |

Os braços OVN-Kubernetes + KubeVirt (`P004-S003`), Cilium + KubeVirt/FRR
(`P004-S004`) e a comparação integral com INV (`P004-S005`) seguem nas próximas
sessões. Esta tabela resume resultados históricos; ela não informa
disponibilidade atual da VM ou do laboratório. Consulte
[MGC: resultados de S002, evidências e limites](estudos/20-mgc-estado-parcial.md)
para a terminologia, os caminhos medidos e as perguntas de estudo.

## Proveniência e limites

O roteiro e as configurações públicas neste diretório são a fonte de reprodução. Os resultados acima são um resumo editorial de execuções datadas; para uma nova aula, a coluna “observado” deve vir da saída atual do cluster. Não se deve inferir disponibilidade de produção, round-robin perfeito, persistência de sessão durante recriação de pod ou isolamento de tenant a partir de uma rota BGP.

Identificadores de sessão e nomes de diretórios que aparecem em comentários do kit referem-se a logs internos não publicados; eles não são necessários para reproduzir o roteiro público.
