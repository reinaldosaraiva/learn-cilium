# E04 — ExternalAuth entre nós, WireGuard e reprodução da issue 46768

S007: native routing. S008: VXLAN. Fontes R09, R13, R14. Dependência: E03 passou
allow/deny/falhas com WireGuard OFF. Esse controle é obrigatório em cada topologia.

## Pergunta e limites

O handshake de transporte Envoy→auth depende de placement ou criptografia?
O relato original é HTTP, Cilium pre.3, VXLAN e nodeEncryption=false. A pesquisa
não provou causa nem persistência em 1.20.2. kind compartilha kernel com host;
uma não reprodução em kind/Ubuntu não refuta comportamento em Talos.

Conexão de auth é nova conexão gerada pelo proxy. Não inferir a identidade,
origem IP ou cobertura WireGuard a partir da requisição original do cliente.
Não confundir com Cilium Mutual Authentication/SPIRE; neste estudo esse recurso
permanece desligado e não há policy authentication.mode=required.

## Componentes e placement

- Worker A: nó de ingresso desejado e Envoy que atende a requisição.
- Worker B: nó remoto; nenhum teste nodeEncryption usa control-plane como par.
- Auth: uma réplica por caso, fixada em A ou B por nodeSelector/afinidade required.
- App: uma réplica por caso em A ou B; portas e protocolo constantes.
- Client: fora de Kubernetes, dentro do fabric experimental.

Direcionar requisição ao NodeIP:nodePort do Service Gateway já criado, mantendo
hostNetwork OFF para não adicionar outra variável ao estudo principal. O datapath
deve levar a Envoy local, mas isso MUST ser provado por access log/captura/counters
com ID. A VIP ECMP é usada só depois de fixar a prova por nó.
Se esse método não seleciona deterministamente o Envoy, parar e revisar a lane;
não declarar same-node/cross-node pelo IP de destino sozinho.

## Matriz principal

Executar em native e VXLAN, com HTTP ExternalAuth primeiro:

| Perfil | encryption.enabled | encryption.type | nodeEncryption |
|---|---|---|---|
| W0 | false | wireguard (inativo) | false |
| W1 | true | wireguard | false |
| W2 | true | wireguard | true |

Para cada W0/W1/W2, quatro posições:

| Posição | Auth | App | Pergunta isolada |
|---|---|---|---|
| P0 | A | A | controle todo local |
| P1 | B | A | somente chamada auth cruza nó |
| P2 | A | B | somente backend cruza nó |
| P3 | B | B | duas etapas cruzam nó |

São 12 células por topologia, 24 ao todo. Cada célula: 30 allow + 30 deny, três
rodadas. Repetir o par W0/W1-P1 com A/B invertidos; se qualquer assimetria aparecer,
ampliar a inversão para todas as posições antes de concluir causa.
Executar também A02/A03/A05/A06 de E03 como canários HTTP/gRPC em cada perfil.
gRPC completo é extensão se o smoke divergir; não afirmar que a issue HTTP prova gRPC.

## Procedimento por célula

1. Reconstituir/validar topologia e values completos. Fixar native ou VXLAN em
   cluster experimental próprio; não alternar o modo do cluster de referência.
2. Aplicar W0, criar placement P0, validar fixture diretamente e via Gateway.
3. Provar A/B com Pod UID/spec.nodeName e Envoy efetivo. Guardar endpoint real
   selecionado; requests observadas no Envoy errado invalidam a célula.
4. Iniciar coleta no cliente, A e B com relógios UTC e correlação de ID/5-tupla.
5. Enviar probes sem retry e sem reuse de conexão; coletar antes/depois de allow
   e deny. Backend app não deve receber IDs denied, em nenhum perfil.
6. Parar só os processos de captura iniciados por esta célula, guardar exit codes.
7. Mudar placement, repetir. Em seguida aplicar W1/W2 com snapshot/revisão.
8. Confirmar WireGuard ativo nos dois workers, chave pública/peer permitido e
   UDP 51871 alcançável; nunca coletar ou imprimir chave privada.
9. Depois de W2, restaurar W0 e repetir baseline. Na mudança para VXLAN, refazer
   W0 e conferir interfaces/MTU/rotas; não atribuir falha inicial a WireGuard.

## Coleta obrigatória

| Ponto | Dado | O que distingue |
|---|---|---|
| Cliente | ID, resposta, duração, exit code | erro HTTP × timeout/reset |
| Envoy A | access log, upstream cluster/endpoint, flags/counters ext_authz | auth negado × transporte falho |
| Auth B | log ID e captura na porta auth | pacote não chegou × serviço recebeu e não respondeu |
| Agent A/B | cilium-dbg monitor drops/traces e ipcache relevante | identidade/rota/policy em cada ponto |
| cilium_wg0 A/B | captura do pacote interno | entrada/saída do túnel |
| Interface de underlay real A/B | UDP 51871 e busca de payload sintético em claro | cifra no fio × pacote interno descriptografado |
| cilium_vxlan (variante) | encapsulamento antes/depois | dependência de overlay |

Não capturar só ens3 da VM: tráfego entre nodes kind pode passar apenas pelas
veths/bridge Docker. Registrar `ip route get AUTH_IP`, interface e namespace.
Em VXLAN, encapsulamento duplo é esperado; MTU deve ser medido, não fixado em 1500
por herança. Captura em cilium_wg0 contendo HTTP claro é normal e não prova vazamento.

## Árvore de diagnóstico

1. W0-P1 falha? Parar: erro de baseline/rota/policy; WireGuard não foi isolado.
2. W0-P1 passa, W1-P1 falha, P0 passa? Candidato ao caso relatado; capturar A/B.
3. SYN sai A, não entra B? Ver underlay/túnel/MTU/AllowedIPs e drops nos dois nós.
4. SYN entra B, auth sem log? Inspecionar socket/porta, TCP handshake e política B.
5. Auth responde e resposta não chega A? Rota reversa/criptografia/conntrack.
6. W2 recupera? Registrar correlação com nodeEncryption; não afirmar causa ou
   recomendar W2 universalmente sem explicar cobertura e repetir controles.
7. P2 também falha? Provável problema mais amplo de proxy→pod; auth não é isolado.
8. Hubble não tem drop? Consultar pcap nos dois lados e métricas; nunca concluir
   “sem log em todo sistema” a partir de um único observador.

## Reprodução e resultado

Para dizer “reproduzido #46768”, casar VXLAN/W1/P1/HTTP e registrar diferenças
de versão, kernel e plataforma. Usar 1.20.0-pre.3 somente como experimento
histórico explicitamente autorizado e isolado; não é necessário para adotar 1.20.2.
Resultado em 1.20.2: CONFIRMED, NOT_REPRODUCED ou INCONCLUSIVE com escopo.
Issue ainda aberta não é prova de defeito local; issue fechada não seria prova de cura.

S007 PASS exige as 12 células native completas, canários HTTP/gRPC, inversão
A/B delimitada acima, captura discriminante e restauração W0 native. Não exige
nenhuma célula VXLAN e não autoriza executar S008 antecipadamente.
S008 PASS exige as 12 células VXLAN completas com os mesmos controles, restauração
W0 VXLAN e síntese comparativa das 24 células usando resultados já fechados de S007.
O gate global G04 usa essa síntese; não é pré-requisito circular do PASS de S007.
Célula INCONCLUSIVE impede conclusão sobre aquela combinação e
exige tarefa diagnóstica dentro da MESMA sessão IN_PROGRESS, não preencher como
sucesso nem criar sucessora. Se houver bypass
de autorização, gate de adoção FAIL mesmo se o objetivo de reproduzir foi atingido.
Sem dado suficiente para a matriz, sessão BLOCKED com última configuração descrita.

## Rollback

Restaurar perfil anterior completo e probes E03; desfazer placement apenas das
fixtures. Não flush global de iptables/conntrack/BPF. Não habilitar criptografia
do control-plane para tentar fazer o teste passar. Guardar custos/estado de
clusters experimentais e não destruir artefatos antes de copiar evidências.
