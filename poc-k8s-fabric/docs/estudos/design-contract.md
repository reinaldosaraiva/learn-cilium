# Contrato público P003 — estudo e processo

**Congelado pela revisão:** planejamento fechado em 20/09/2026.
**Autoridade:** contrato do estudo; alterações posteriores seguem §16.
O planejamento é completo no nível de hipóteses/gates; valores dependentes do
ambiente só congelam após descoberta indicada. Não fingir que um TBD é executável.

## 1. File Naming

A edição pública usa `README.md`, `design-contract.md`, `research.md`,
`execution-protocol.md`, os dossiês `00`–`08` e `sessions/S002-preflight.md`.
Uma execução local pode manter sessões, resultados, handoffs e evidências sob
uma árvore privada; esses artefatos não são dependências deste clone.
Implementação futura do kit fica em `poc-k8s-fabric/studies/p003/`, nunca
confundida com artefato já entregue.

## 2. Story Status Enum

Sem extensão: o plano usa ACTIVE/BLOCKED/FAILED/COMPLETE; sessões materializadas
READY/IN_PROGRESS/BLOCKED/FAILED/COMPLETE. PLANNED é previsão sem arquivo.
Sessões antigas DONE permanecem registro legado; P003 usa vocabulário canônico.

## 3. Verdict Enum

GO/PASS/BLOCKED/FAIL; verdict separado de status. GO fecha design/descoberta;
PASS fecha entrega verificada; BLOCKED/FAIL interrompe cascata. Resultados
MUST registrar **Verdict:** nos primeiros cinco itens/linhas.
Classificação experimental CONFIRMED/NOT_REPRODUCED/INCONCLUSIVE/UNSUPPORTED
não substitui verdict da sessão nem gate de adoção da solução.

## 4. MasterPlan Schema

Consome o schema existente, sem novos parsers ou automação de estado.
Uma tabela de roadmap prevê todas as sessões; somente a próxima é materializada.

## 5. Cascading Authorship Rule

P003-S00(N+1).md só nasce após resultados GO/PASS da anterior. Dossiês detalhados
são material de pesquisa/planejamento, não sessões disfarçadas: não dão permissão
para ignorar pré-requisitos, valores descobertos ou atualização de âncoras.
Resultados históricos permanecem separados; a edição pública não cria sucessoras fora da cascata.

Diagnóstico de critério ainda não atendido ocorre como tarefa/rodada dentro da
sessão IN_PROGRESS, nunca como sucessora antecipada. O orçamento adicional do
master conta rodadas, não novos IDs. GO de planejamento não pode ser usado para
contornar aceite de uma sessão de experimento previamente definida como PASS.

### 5.1 Interface Ledger (Consumes/Provides)

Âncoras conferidas em 20/09. Interfaces aqui são contratos de documentos, manifests
existentes e dados; não há flags inventadas de scripts ainda não escritos.
O coordenador MUST reler a linha/snippet no momento da fatia executável.

| Session | Consumes | Provides |
|---|---|---|
| S001 | `research.md` — `## Classificação das alegações` | contrato e dossiês revisados |
| S002 | S001: contrato; `00-preflight.md` — `## Artefatos obrigatórios` | inventário/environment/envelope/versions.lock documentados |
| S003 | S002: inventário; `../../topo/kind-cluster.yaml` — `kind: Cluster`; `../../k8s/bgp/02-advertisements.yaml` — `kind: CiliumBGPAdvertisement`; `01-gateway-bgp.md` — `## Matriz mínima` | sandbox, manifests e probes identificados por versão/UID |
| S004 | S003: sandbox; `02-l4-hostnetwork.md` — `## Matriz` | tabela de portas/protocolos por caso |
| S005 | S003: Gateway; `03-externalauth.md` — `## Fixture controlada — requisito de S005` | fixture HTTP/gRPC comprovada e logs por request ID |
| S006 | S005: fixture; `03-externalauth.md` — `## S006 — matriz de falhas e cross-namespace` | matriz fail-closed e limites do patch |
| S007 | S006: baseline auth; `04-wireguard.md` — `## Matriz principal` | matriz native com placement provado |
| S008 | S007: controles; `04-wireguard.md` — `## Reprodução e resultado` | matriz VXLAN e conclusão delimitada da issue |
| S009 | S006: auth; `05-tenants.md` — `## Matriz de aceite` | isolamento, autoridade e TLS medidos |
| S010 | S003: BGP; `06-ipam.md` — `## Controle da comparação` | M24/M32 com variáveis controladas e timestamps |
| S011 | S009: fronteiras; `07-openstack.md` — `## S011 — descoberta somente leitura` | mapa OpenStack/tenant/rotas e plano de recursos concreto |
| S012 | S011: desenho; `07-openstack.md` — `## Matriz` | matriz híbrida com VM Nova real |
| S013 | S012: ownership; `08-lifecycle.md` — `## Matriz` | revogação/reuso de IP comprovados ou limite explícito |
| S014 | S013: lifecycle; `08-lifecycle.md` — `## S014 — entrega didática e mapa de decisão` | guia reproduzível e síntese por combinação |

Arquivos concretos de implementação/evidence de S003+ entram na linha pertinente
quando existirem; até lá o ledger promete o conteúdo, não a existência do arquivo.

## 6. Kickoff Prompt

```text
Continue from `poc-k8s-fabric/docs/estudos/README.md`. If using a private Reentry
tree, create its local state yourself and keep it outside this public clone.
```

O kickoff recupera escopo e autorização vigente. Não transforma planejamento em
permissão de executar mutações. Próxima sessão é preflight somente leitura.

## 7. Authority Order

Instruções do responsável pelo estudo precedem convenções locais. Nesta edição,
o índice público orienta a leitura, a sessão local delimita a ação, o contrato
congela invariantes e as evidências sustentam conclusões. Uma árvore Reentry
local é opcional e não deve ser exigida para ler os documentos públicos.

## 8. Review Output Contract

A revisão aconselha; a coordenação decide o ciclo de vida. A saída registra
severidade, arquivo/linha, efeito e correção, separando bloqueio de execução de
lacuna que a sessão futura deve descobrir. A revisão deve usar contexto novo e
declarar `independencia por contexto, nao por provider`. Não executar uma CLI de
agente aninhada nem alterar configuração global.

## 9. Schema Migrations

Sem migrações de dados do repositório. CRDs do Gateway são instaladas somente no
sandbox futuro. IPAM em ambiente novo; não migrar k01 nesta trilha.

## 10. Skill Layouts

Sem instalação ou alteração de ferramentas para interpretar o plano. O clone público não copia automação externa ou estado de outra árvore.

## 11. Skill Outputs

Consome o schema documental existente; nenhuma alteração de formato é necessária para ler o plano.

## 12. Skill Inputs

Consome o schema documental existente. Cada execução recebe os seis campos do
protocolo; o plano não exige uma ferramenta ou linguagem específica.

## 13. Consistency Checker

Validar manualmente links internos/âncoras, snippets shell, fences YAML/Bash e disciplina RFC-2119 no clone público. A verificação documental não executa os snippets nem acessa o laboratório.

## 14. Legacy Migration

Nenhuma migração de árvore ou estado é necessária. Uma execução local atualiza seu próprio índice após evidência e revisão; resultados privados não são forçados para o clone público.

## 15. Out of Scope

Produção, upgrade/destruição k01, recursos não inventariados, ambientes
gerenciados não identificados, serviços de IdP reais, VRFs/CIDRs sobrepostos,
controlador Kubernetes–Neutron, garantia de desempenho ou segurança universal,
publicação automática. Reprodução exata de uma plataforma externa é extensão
condicionada ao ambiente; não é pré-requisito para medir a configuração local e
relatar não reprodução delimitada.

## 16. Amendment Process

Mudanças de escopo/autoridade/requisito MUST registrar responsável, motivo,
impacto e gates afetados no resultado da sessão e no índice local. Descoberta de valor
marcado como pendente não é mudança de requisito; preencher com evidência.
Correção técnica que muda expectativa experimental exige atualização explícita
do contrato antes da execução dependente. Não reclassificar FAIL como PASS por edição.

## 17. Resolved decisions and acceptance gates

| Decisão | Resolução congelada | Gate |
|---|---|---|
| Q01 Escopo | Gateway/BGP, L4 host network, ExternalAuth, WireGuard, tenants, IPAM, híbrido/lifecycle | G01–G10 |
| Q02 Execução atual | somente planejamento local; próximo passo preflight de leitura | G00 |
| Q03 Ambiente | sandbox isolado; mesma VM só se inventário aprovar; k01 preservado | G00/G01 |
| Q04 Versões | 1.20.2 + Gateway 1.6.1; digest/schema confirmados antes de apply | G00/G03 |
| Q05 Maturidade | ExternalAuth experimental; L4 hostNetwork sem suporte documentado | G02/G03 |
| Q06 Auth | HTTP e gRPC distintos, allow/deny/ausência/timeout/refs; fixture não IdP | G03 |
| Q07 WireGuard | native/VXLAN separados, W0/W1/W2 e placements; workers como pares | G04 |
| Q08 Tenants | usuário/rede/configuração separados; PSA/admission e anti-bypass de policy/Route | G05 |
| Q09 /32 | M24 vs M32 controla IPAM; medir reserva/retirada, ignorar custo FIB na decisão | G06 |
| Q10 Híbrido | OpenStack real; matriz bidirecional e contraste Cilium×SG antes de atribuir deny | G07 |
| Q11 IP reuse | nenhuma autorização herdada sem dono atual; regra stale é controle negativo | G08 |
| Q12 Veredito | pesquisa não equivale a ensaio; status não equivale a efeito | todos |

### Gates da rodada de planejamento S001

- G00.1 MUST existir fonte primária datada para cada alegação de versão/bug.
- G00.2 MUST existir dossiê com passos, entradas, saídas, negativo e rollback por estudo.
- G00.3 MUST existir limite claro entre dado pesquisado, hipótese e medição futura.
- G00.4 MUST existir protocolo de tarefa para modelo simples e parada por lacuna.
- G00.5 MUST ocorrer blind roadmap check e reader test em contexto fresco.
- G00.6 MUST passar checker/lint ou corrigir achado antes do GO.
- G00.7 MUST preservar resultados históricos separados e não criar sessão fora da cascata.
- G00.8 SHOULD manter bootstraps curtos por sessão, lendo somente o dossiê necessário.
- G00.9 You MAY include bounded diagnostic rounds within the current session under the overrun rule.

### Invariantes negativas

- MUST NOT trocar CRDs, WireGuard ou hostNetwork no k01, because namespace não isola
  essas configurações de cluster.
- MUST NOT marcar auth segura com o demo always-allow, because ele não exercita rejeição.
- MUST NOT inferir entrega pela ausência de drop no Hubble, because a observação é local.
- MUST NOT aplicar ExternalAuth HTTP como segurança de TCP/UDP, because são caminhos distintos.
- MUST NOT declarar OpenStack validado usando um pod, because o datapath/ownership Neutron não existiu.
- MUST NOT publicar evidência bruta, because pode conter endereços privados ou credenciais.

## Amendments

### A1 — edição pública sanitizada (2026-09-20)

A edição pública é sanitizada e portátil. Evidências brutas e material
operacional privado continuam fora do clone. Experimentos e o preflight S002 não
são executados por esta emenda; os demais gates permanecem.

## Publicação e portabilidade

Este contrato é legível sem uma árvore privada, ponteiros gerados, handoffs ou
resultados locais. O leitor que quiser usar Reentry pode criar uma árvore própria
e apontar o kickoff para este índice; os dossiês não exigem que ela exista.

Os comandos de referência usam quatro variáveis obrigatórias: no Mac, `REFERENCE_SSH_TARGET` e `REFERENCE_SSH_KEY`; no host remoto, `REFERENCE_KUBECONFIG` e `REFERENCE_CONTEXT`. Elas devem ser definidas no lado em que serão expandidas, porque variáveis do Mac não passam automaticamente via SSH. O sandbox acrescenta `REFERENCE_LAB_ROOT` e `STUDY_LAB_ROOT` apenas como diretórios lógicos descobertos no inventário; não são endpoints publicados.
