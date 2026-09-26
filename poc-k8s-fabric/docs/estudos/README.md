# Estudos P003 — Gateway API, segurança, IPAM e tenants híbridos

> Planejamento revisado em **20/09/2026**. Os experimentos ainda não foram executados por esta publicação, com exceção da síntese E08 (S013/S014) e da emenda C5 (S016, VM fora do container), publicadas como resultados.

Este índice público transforma o roteiro em uma sequência de 14 sessões pequenas, com fontes, critérios observáveis, controles negativos e rollback. O [resultado histórico do laboratório](../lab-results.md) permanece separado: ele descreve o kit de referência e não comprova nenhum estudo P003.

Gateway API vem primeiro. S002 é apenas um modelo de preflight de leitura; S003–S014 ficam em forecast e só podem ser materializadas uma por vez depois do veredito da predecessora. Os dossiês preservam a matriz experimental completa, mas não concedem acesso à infraestrutura nem autorização de execução.

## Como seguir o processo

1. Leia este índice, o [contrato técnico e de processo](design-contract.md), a [pesquisa](research.md) e o [protocolo de execução](execution-protocol.md).
2. Leia apenas o dossiê da próxima sessão; use o [modelo público de S002](sessions/S002-preflight.md) para uma retomada local e mantenha inventário, resultados e handoffs fora desta documentação.
3. Antes de qualquer mutação, materialize uma sessão local com valores descobertos, UID do cluster, allowlist, dry-run e gate de autorização. A presença de um dossiê não cria essa autorização.
4. Registre esperado e observado separadamente, execute controles positivos e negativos, e encerre a sessão com resultado, revisão e rollback.

Os exemplos de acesso exigem quatro variáveis explícitas. No Mac, defina `REFERENCE_SSH_TARGET` e `REFERENCE_SSH_KEY`; no host remoto, defina `REFERENCE_KUBECONFIG` e `REFERENCE_CONTEXT`. Variáveis do shell Mac não passam automaticamente via SSH. Use `sudo kubectl --kubeconfig "$REFERENCE_KUBECONFIG" --context "$REFERENCE_CONTEXT"` e o mesmo par de flags para `cilium`; nunca dependa do contexto implícito.

## Estado da publicação

- S001 fechou o planejamento em 20/09/2026; esta edição exporta o contrato, a pesquisa, o protocolo e os dossiês.
- S002 está representada por um template de leitura. Sua execução precisa criar evidência local e decidir GO/BLOCKED.
- **Síntese executada E08 (24/09/2026):** a matriz C01–C09 (S013 lado K8s + S014 lado VM) foi executada e consolidada na [síntese didática](08-lifecycle-synthesis.md) — primeira entrega de resultados publicada. As demais sessões seguem como dossiês de planejamento; resultados, credenciais, inventário bruto e estado Reentry permanecem fora do clone público.
- **Emenda C5 executada (25/09/2026):** a VM fora do container (KVM real no host) resolveu a limitação D-S012-13 (RX da VM em KVM aninhado) e provou tráfego **bidirecional pod↔VM** preservando o datapath Neutron — publicada em [C5 — VM fora do container](09-vm-outside-container.md).


## Objective

Transformar os estudos em experimentos pequenos, reproduzíveis e verificáveis por
um executor de menor capacidade, com pesquisa primária, instruções delimitadas,
evidência de tráfego, controles negativos e retomada sem depender de contexto externo.
Gateway API vem primeiro; tenants, IPAM e OpenStack completam a trilha.

## Plan Status

- **Status:** planejamento revisado; execução futura
- **Próxima fatia prevista:** [modelo S002](sessions/S002-preflight.md)
- **Referência didática:** [resultados históricos do laboratório](../lab-results.md); esse registro é separado deste plano.
- **Origem:** revisão aprofundada do roteiro de estudos, registrada em 20/09/2026.
- **Data:** 2026-09-20.
- **Forma pública:** este índice é a entrada portátil; uma execução local pode manter sua própria árvore Reentry e suas evidências.
- **Estado publicado:** planejamento revisado. O preflight e os demais experimentos futuros continuam sem execução nesta edição; as exceções são a [síntese E08](08-lifecycle-synthesis.md) (S013/S014) e a [emenda C5](09-vm-outside-container.md) (S016), publicadas como resultados.

## Assessment

**SCORE:** 7
**LEVEL:** COMPLEX
**ESFORÇO:** completo
**FORMA:** roteiro documental com revisão independente e sessões delimitadas
**FORECAST:** 14-14 sessions

Forecast ajustado ao escopo: 14 sessões Reentry. Até quatro rodadas adicionais de
diagnóstico podem ocorrer DENTRO dessas sessões, sem criar novos IDs ou liberar
cascata; isso não autoriza execução autônoma das sessões.
O escopo ampliado inclui a trilha anterior documentada em [próximos estudos](../proximos-estudos.md); qualquer correção de escopo deve ser registrada como emenda antes da execução.

## Source Material

1. [Contrato](design-contract.md): invariantes e critérios globais.
2. [Pesquisa](research.md): alegações, versões, fontes e limites da pesquisa.
3. [Protocolo de execução](execution-protocol.md): evidências, comandos e delegação.
4. Dossiê do estudo indicado na sessão; não é necessário reler todos.
5. [resultados históricos](../lab-results.md): baseline histórico, não saúde atual.

## Abordagens consideradas

| Opção | Vantagem | Limitação | Decisão |
|---|---|---|---|
| Alterar k01 em sequência | Menor custo de infraestrutura | Host network, WireGuard e IPAM têm efeito no cluster; destrói a referência | Rejeitada |
| Segundo cluster e fabric isolados na mesma VM, se houver capacidade | Reusa o modelo conhecido, permite controles e retorno à referência | Consome RAM/CPU; kernel é compartilhado, não reproduz Talos | Preferida; viabilidade a medir em S002 |
| Host experimental separado | Melhor isolamento de recursos e possibilidade de Talos | Infra e custo ainda não confirmados | Alternativa somente após escolha concreta do dono |

## Proposed Sessions

Somente uma sucessora é materializada após GO/PASS. Os dossiês abaixo detalham
estudos futuros; não são sessões executáveis, nem substituem a atualização de
âncoras e valores observados no momento de criar cada sessão.

| Session | Status | Deliverable | Verdict Expected | Dossiê |
|---|---|---|---|---|
| P003-S001 | PLANEJAMENTO FECHADO | Pesquisa aprofundada, contrato, roteiro e revisão de leitura | GO (20/09) | research + todos |
| P003-S002 | MODELO PÚBLICO | Inventário somente leitura; capacidade, versões, sub-redes e decisão do sandbox | GO | [E00](00-preflight.md) |
| P003-S003 | PLANNED | Sandbox isolado; Gateway HTTP/TCP/UDP exposto por VIP+BGP | PASS | [E01](01-gateway-bgp.md) |
| P003-S004 | PLANNED | Matriz TCPRoute/UDPRoute com LoadBalancer, NodePort e host network | PASS | [E02](02-l4-hostnetwork.md) |
| P003-S005 | PLANNED | Fixtures de auth observáveis; HTTP e gRPC; allow/deny | PASS | [E03](03-externalauth.md) |
| P003-S006 | PLANNED | Auth indisponível/referência inválida, fail-closed e referência 1.20.2 | PASS | [E03](03-externalauth.md) |
| P003-S007 | PLANNED | WireGuard/native: local × remoto, node encryption OFF × ON | PASS | [E04](04-wireguard.md) |
| P003-S008 | PLANNED | WireGuard/VXLAN: reprodução delimitada da issue 46768 | PASS | [E04](04-wireguard.md) |
| P003-S009 | PLANNED | Tenants A/B, policies/RBAC, ListenerSet e TLS do backend | PASS | [E05](05-tenants.md) |
| P003-S010 | PLANNED | Multi-Pool /24 × /32: alocação, anúncios e ciclo de vida | PASS | [E06](06-ipam.md) |
| P003-S011 | PLANNED | Inventário OpenStack e desenho verificável da integração | GO | [E07](07-openstack.md) |
| P003-S012 | PLANNED | Pod A → VM A permitido; tenant B bloqueado nos dois sentidos definidos | PASS | [E07](07-openstack.md) |
| P003-S013 | EXECUTADO | Recriação/reuso de IP com revogação de autorização e rotas observada | PASS | [E08](08-lifecycle.md) · [síntese](08-lifecycle-synthesis.md) |
| P003-S014 | EXECUTADO | Síntese de limites, exercícios, gates de adoção e entrega didática | PASS | [E08](08-lifecycle.md) · [síntese](08-lifecycle-synthesis.md) |
| P003-S016 (C5) | EXECUTADO | VM fora do container (KVM real no host): RX resolvido + pod↔VM bidirecional | PASS | [C5](09-vm-outside-container.md) |

## Dependências e limites

- S003 depende de inventário positivo e autorização de execução do sandbox.
- S004 muda configuração global somente no sandbox. Um namespace separado não basta.
- S005/S006 validam auth antes de misturar criptografia. HTTP e gRPC têm casos separados.
- S007/S008 comparam configurações explícitas; “same-node” refere-se ao Envoy
  que processou a requisição e ao pod de autorização, comprovados por evidência.
- S009 aproveita Gateway e auth; autorização de usuário, política de pod e
  delegação de configuração são controles diferentes.
- S010 mantém a variável IPAM constante na comparação principal (/24 e /32
  ambos em Multi-Pool); o IPAM Kubernetes atual é apenas referência adicional.
- S011 depende de OpenStack acessível e identificado. Um ambiente gerenciado não é automaticamente um endpoint OpenStack disponível.
- S012/S013 exigem inventário de recursos do experimento e ownership explícito.
  Ausência de OpenStack não autoriza substituir VMs por pods e declarar o caso provado.

## Design Requirements

1. O executor MUST validar contexto, cluster UID e inventário antes de mutar.
2. O executor MUST registrar esperado e observado separadamente, inclusive falhas.
3. O executor MUST NOT concluir sucesso por status Ready/Programmed isolado,
   porque isso não comprova o caminho do pacote nem a aplicação da autorização.
4. Cada hipótese MUST ter controle positivo, controle negativo e coleta externa.
5. A execução MUST preservar k01 e recursos históricos; limpeza é por UID/lista.
6. Mudanças de variável MUST ocorrer uma por vez, com baseline antes/depois.
7. Toda alegação volátil MUST citar versão exata e fonte; issue é relato até reprodução.
8. O modelo executor MUST escalar hipótese nova ou interface ausente, não improvisar arquitetura.

## Non-Goals

Produção, migração do k01, recursos não inventariados, publicação automática, migração de estado, throughput de hardware, framework novo de automação, implementação de IdP ou controlador Kubernetes–Neutron.

## Execution Rules

- Uma pessoa coordenadora delimita cada sessão, fornece seis campos (Objective/Anchors/Steps/Constraints/Acceptance/Out-of-scope) e conserva a decisão de aceite.
- A pessoa que executa uma fatia não altera o índice nem decide o próprio veredito; revisão independente deve reexaminar os dados.
- Cada sessão lê o contrato e somente o dossiê necessário. Evidências e estado de execução ficam locais e fora da edição pública.
- Primeiro materializar manifests/scripts verificáveis; somente depois iniciar o experimento autorizado. Não afirmar que arquivos planejados já existem.

## Acceptance Gates

P003 só será COMPLETE depois da execução e evidências, não pelo tamanho do plano:

1. G01: baseline isolado e VIP+BGP com probes HTTP/TCP/UDP.
2. G02: matriz de portas L4 e host network com provas no cliente e nó.
3. G03: auth permite/nega corretamente e referencia inválida não libera aplicação.
4. G04: pares local/remoto e native/VXLAN classificados com rastreio suficiente.
5. G05: tenants não podem alcançar nem reconfigurar recursos indevidos.
6. G06: /24 × /32 medido com IPAM controlado e reservas separadas dos pods vivos.
7. G07: OpenStack real identificado e acesso híbrido autorizado por tenant.
8. G08: reuso de IP não herda autorização no modelo testado; limites explicitados.
9. G09: roteiro didático permite a outro executor repetir os ensaios.
10. G10: cada sessão tem resultados, revisão e rollback/estado final documentados.

## Overrun Rule

Uma célula inconclusiva mantém a sessão atual IN_PROGRESS e gera tarefa de
diagnóstico dentro dela, com hipótese, escopo e evidência próprios. Não exige
nem cria a próxima sessão. BLOCKED reserva-se ao impedimento externo identificado;
FAIL mantém a cascata parada até redirecionamento explícito do dono.

Orçamento de até quatro rodadas diagnósticas extras, sem novos IDs de sessão,
para: capacidade do sandbox; prova do nó de ingresso; defeito reproduzido;
particularidade do backend OpenStack. Registrar motivo e consumo desse orçamento.
Esgotamento pede checkpoint de planejamento ao dono; não muda automaticamente
verdict para GO/PASS. Qualquer nova sessão S015+ requer emenda explícita do roadmap
e preservação da cascata, depois do aceite legítimo da predecessora.
