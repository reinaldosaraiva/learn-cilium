# Resultados públicos do laboratório

Este resumo separa o estado observado na reconstrução mais recente dos resultados históricos de cenários anteriores. Ele existe para dar contexto ao guia do estudante sem exigir acesso a logs de uma execução privada.

## Estado observado na reconstrução

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

## Proveniência e limites

O roteiro e as configurações públicas neste diretório são a fonte de reprodução. Os resultados acima são um resumo editorial de execuções datadas; para uma nova aula, a coluna “observado” deve vir da saída atual do cluster. Não se deve inferir disponibilidade de produção, round-robin perfeito, persistência de sessão durante recriação de pod ou isolamento de tenant a partir de uma rota BGP.

Identificadores de sessão e nomes de diretórios que aparecem em comentários do kit referem-se a logs internos não publicados; eles não são necessários para reproduzir o roteiro público.
