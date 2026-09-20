# E06 — PodCIDR /24 versus blocos /32

Sessão S010. Fontes R16/R17. O objetivo é granularidade, reservas, anúncio,
retirada e recriação; tamanho/custo da FIB fica fora da decisão deste estudo.
Contagem de rotas continua sendo um instrumento para entender o mecanismo.

## Controle da comparação

Comparar Kubernetes IPAM /24 com Multi-Pool /32 altera DUAS variáveis.
A comparação causal principal MUST usar Multi-Pool nos dois braços:

| Braço | IPAM | máscara do pool | Finalidade |
|---|---|---|---|
| K24 | kubernetes | /24 por nó | referência histórica adicional |
| M24 | multi-pool | 24 | controle principal |
| M32 | multi-pool | 32 | tratamento |

Mesmas versões, três nós, imagens, afinidades, probes, BGP timers e subnet total.
Ensaios separados por cluster/reconstituição experimental. maskSize é imutável;
não alterar pool em uso, não migrar o IPAM de k01.

## Perguntas

- Quando o bloco é solicitado, alocado, anunciado e utilizável externamente?
- Quantas rotas correspondem a pods vivos, reservas e endereços de infraestrutura?
- Quais eventos retiram rotas: pod delete, liberação de bloco, remoção do nó?
- Readiness afeta o anúncio de bloco ou só EndpointSlice/Service?
- O IP reaparece em outro pod/UID? O que acontece com conexão TCP anterior?

## Preparação

1. Registrar CiliumPodIPPool served/storage da CRD real. Exemplos móveis podem
   dizer v2alpha1; gerar manifesto pela versão instalada e dry-run server-side.
2. Definir pool de teste com namespace exclusivo e annotation/selector explícito.
   Usar require-pool-match quando suportado para evitar fallback silencioso default.
3. Criar anúncio `CiliumPodIPPool` com selector do pool; remover `PodCIDR` apenas
   no sandbox Multi-Pool para evitar duas fontes confundindo o experimento.
4. Fixar preallocation igual nos braços via Helm `ipam.multiPoolPreAllocation`,
   confirmado no values v1.20.2; string no formato `pool-name=8`, usando o nome
   real do pool. Conferir `ConfigMap/kube-system/cilium-config`, chave
   `.data["ipam-multi-pool-pre-allocation"]`, não um ConfigMap com o nome da chave.
   Começar 8 por nó/pool e registrar valor
   efetivo; repetir sensibilidade com 1, se suportado. Não presumir exatamente
   oito rotas: há pedidos, arredondamento e IPs internos a contabilizar.
5. Aplicar seis réplicas, com duas por nó por afinidade definida; depois quarenta,
   mantendo distribuição conhecida. Operador/nós podem consumir outros blocos.
6. Estabelecer relógio de observação único no host para streams da API/BGP/probes.
   Guardar precisão e intervalo de polling; não declarar latência subintervalo.

## Medições por evento

| Instante | Evento | Fonte |
|---|---|---|
| t0 | solicitação aceita para criar pod | resposta API/watch |
| t1 | Pod UID/node/IP conhecidos | watch pod |
| t2 | bloco em CiliumNode.spec.ipam.pools.allocated | watch CiliumNode |
| t3 | anúncio na saída do Cilium | CLI/debug BGP com timestamp do coletor |
| t4 | prefixo no roteador externo | FRR/SRL polling |
| t5 | primeiro request direto bem-sucedido | cliente externo |
| t6 | delete/NotReady/eviction solicitado | API |
| t7 | bloco liberado ou ainda reservado | CiliumNode |
| t8 | rota retirada ou retida | Cilium + roteador |

Não impor t1<t2: alocação de bloco pode preceder criação do pod (preallocation).
Relatar intervalos de observação, não timestamps inventados do evento interno.

## Matriz

| Caso | Operação | Resultado a classificar |
|---|---|---|
| I01 | pool sem pods de teste | reservas/rotas base, explicadas |
| I02 | 0→6 pods | tempo IP/anúncio/probe; caminho por nó |
| I03 | 6→40 pods | latências/distribuição e reservas |
| I04 | pod fica NotReady, sem delete | distinguir bloco e VIP/EndpointSlice |
| I05 | apagar um pod próprio | rota retirada ou reserva persiste |
| I06 | recriar em mesmo nó | UID/IP antigos e novos; TCP não presumido preservado |
| I07 | recriar em outro nó | origem do anúncio/next-hop e alcance |
| I08 | voltar a zero pods | blocos retidos/liberados e tempo observado |
| I09 | interromper um peer BGP experimental | impacto direto pod vs VIP |
| I10 | preallocation 8→1 em ensaio separado | sensibilidade do comportamento de reserva |

Cada operação repetida três vezes por braço. A janela de observação de retirada
é 120s por evento, com polling de 1s ou melhor se os comandos suportarem.
Se não retira, registrar “retida por pelo menos 120s”, não “nunca retira”.
Extensão da janela exige hipótese e registro, não loop infinito.

## Instrumentos e entregáveis

- Snapshots `CiliumNode`, pools, pods UID/IP/node/readiness, BGP RIB/FIB.
- CSV `events.csv` por braço/repetição e `allocation.csv` separando reservado/usado.
- Probes diretos ao pod e à VIP: pelo menos 30 por checkpoint.
- Sessão TCP longa de controle e novas conexões; não confundir persistência de
  VIP com persistência do processo/pod original.
- `comparison.md` com gráficos opcionais e limites de resolução do relógio.

## Aceite

S010 PASS exige que M24 e M32 tenham configuração equivalente exceto máscara no contraste principal;
preallocation tem ensaio próprio. Cada rota de teste está explicada por bloco/nó,
e cada reivindicação de retirada tem evidência de alocação E de roteamento.
NOT_REPRODUCED para retirada imediata é resultado válido: /32 não cria sessão
BGP por pod nem garantia de IP estável. Não inventar CiliumPodIPPool /32 “um pod
um anúncio ativo” quando o nó retém reservas.

Rollback: manter k01/K24 de referência intacto, desfazer somente pools/recursos
experimentais sem uso, ou reconstituir cluster experimental autorizado. Pools
ativos não são deletados para liberar teste. Guards VPC permanecem fora deste caso.
