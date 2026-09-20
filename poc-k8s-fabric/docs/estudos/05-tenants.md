# E05 — Tenants, delegação de Gateway e TLS do backend

Sessão S009; dividir em tarefas pequenas: rede, autoridade de configuração,
depois TLS. Fontes R08/R15/R18. WireGuard volta ao baseline escolhido; esta sessão
não mistura nova política com diagnóstico inconclusivo de criptografia.

## Três controles distintos

1. Identidade de usuário na borda: ExternalAuth HTTPRoute.
2. Identidade de workload/rede: CiliumNetworkPolicy/Kubernetes NetworkPolicy.
3. Quem pode configurar a borda: RBAC, allowedListeners/allowedRoutes e ReferenceGrant.

ExternalAuth de HTTPRoute MUST NOT ser apresentado como proteção de TCPRoute ou
UDPRoute, porque L4 não passa pelo mesmo filtro Envoy. Uma VIP compartilhada não
estende autenticação a todos os protocolos. Tampouco namespace cria VRF ou aceita
CIDRs de pod sobrepostos.

## Topologia lógica e ownership

| Recurso | Dono | Regra |
|---|---|---|
| p003-edge: Gateway/rotas protegidas/auth | plataforma | tenants não alteram/removem filtro |
| p003-tenant-a: app/db fictício/ServiceAccount | tenant A | somente seu namespace e recursos permitidos |
| p003-tenant-b: app/db fictício/ServiceAccount | tenant B | idem |
| Labels de namespace/identidade de tenant | plataforma | tenant não pode se promover para A |
| CNP/default deny e Grants | plataforma | tenant não reabre fronteira sozinho |
| p003-delegated-a/b: ListenerSets didáticos | equipe autorizada | prova de delegação separada da borda protegida |

Rotas protegidas ficam sob autoridade da plataforma neste experimento mínimo.
Permitir ao tenant editar livremente HTTPRoute protegida exigiria admissão que
impedisse remoção/contorno do auth; isso é extensão, não proteção presumida por RBAC.
ServiceAccount namespace/name identifica workload; rótulo arbitrário editável
pelo próprio tenant não deve ser o único autenticador da fronteira.

RBAC mínimo congelado: tenants A/B podem gerir somente workloads e Services
explicitamente listados no próprio namespace; não podem criar/editar/apagar
NetworkPolicy, CiliumNetworkPolicy, CiliumClusterwideNetworkPolicy, Role,
RoleBinding, Gateway, GatewayClass, ReferenceGrant ou rotas protegidas.
Esse limite cobre CREATE, UPDATE, PATCH e DELETE, não apenas editar a policy existente.
Gateway protegido usa `allowedRoutes.namespaces.from: Same` em p003-edge.
O papel separado de delegação pode criar ListenerSet/HTTPRoute somente em
p003-delegated-a/b e só se anexa ao Gateway didático; não recebe autoridade no edge.

Namespaces de workloads A/B MUST aplicar Pod Security Admission `restricted`,
com enforce-version fixada à minor Kubernetes do sandbox (v1.35 no candidato).
Fixtures de tenant devem cumprir runAsNonRoot, seccomp, capabilities e portas
não privilegiadas pertinentes ao perfil; incompatibilidade da imagem pede ajuste
da fixture, não desativação de admission. Captura privilegiada fica no papel
de infraestrutura e fora desses namespaces, sem permissão para o tenant.

Plataforma define ValidatingAdmissionPolicy/Binding com failurePolicy=Fail e
validationActions Deny (ou webhook equivalente identificado) que exige tenant
label de pod coerente com label imutável do namespace e limita serviceAccountName
ao conjunto autorizado para aquele namespace. Validar CREATE e UPDATE; Deployment
e outros controllers não podem produzir Pod que contorne essa condição. O tenant
não edita namespace labels, admission policy/binding ou ServiceAccounts de plataforma.
S009 materializa expressões CEL contra o schema real, com controles válidos e
inválidos; o coordenador MUST revisá-las antes de entregar ao executor.

## Passos — rede

1. Criar namespaces A/B e ServiceAccounts, com labels geridas pela plataforma.
   Aplicar PSA/admission e validar um Pod legítimo antes de criar workloads.
2. Criar clientes e backends em nós distintos, com marcadores A/B e logs por ID.
3. Registrar baseline A↔A, B↔B, A↔B antes da policy; isso valida o teste negativo.
4. Aplicar default deny ingress/egress para workloads alvo; adicionar allows
   explícitos A→A e B→B na porta necessária, DNS e dependências enumeradas.
5. Revisar TODAS as policies que selecionam endpoints. Regras aditivas podem
   reabrir fluxo; não avaliar somente o YAML recém-criado.
6. Para tráfego Gateway HTTP, tratar world→ingress e ingress→backend, verificando
   identidade efetiva em Hubble. Uma identidade ingress compartilhada não carrega
   automaticamente tenant A/B: autorização HTTP ainda cabe à rota/auth.
7. Recriar cliente e backend A, repetir matriz; identidade é independente de IP.

## Passos — RBAC e delegação

1. Definir dois papéis de teste com permissions explícitas; não usar cluster-admin
   nos probes de tenant. Checar `kubectl auth can-i --as=system:serviceaccount:...`
   E executar chamadas de API reais impersonadas; ambos os controles têm evidência.
2. Testar A lendo Secret de B, alterando label de namespace e alterando policy
   da plataforma: Forbidden. Identificar e registrar o verbo/recurso exato.
   Testar também criar uma NOVA policy allow-all no namespace próprio e nova
   RoleBinding que conceda esses verbos; ambas devem receber Forbidden.
3. Confirmar CRD ListenerSet detectada; Gateway de demonstração conserva ao menos
   um listener válido próprio. Configurar allowedListeners por namespace selecionado.
4. ListenerSet A autorizado deve funcionar; B não autorizado deve ser recusado.
5. Route aponta explicitamente kind=ListenerSet e sectionName; omitindo kind,
   verificar que não anexou por coincidência ao Gateway de mesmo nome.
6. Conflito de listener: Gateway vs ListenerSet e dois ListenerSets; registrar
   conditions de CADA listener e tráfego vencedor, não só top-level Accepted.
7. Referência a Service/Secret fora do namespace: nenhum acesso sem Grant mínimo.
   Grant do Gateway pai não é herdado automaticamente pelo ListenerSet.
8. Com os papéis A/B e de delegação, tentar criar HTTPRoute alternativa sem auth
   apontando ao listener protegido. A API deve recusar por RBAC ou o controlador
   deve recusar anexação por allowedRoutes; em ambos, probe não chega à app.
   Tentar ainda novo Gateway/ListenerSet que contorne edge; registrar a negação.
9. Tentar Pods com hostNetwork, privileged, hostPID e hostPath, um campo por caso;
   todos rejeitados pela API. Tentar tenant label ausente/forjado, UPDATE que muda
   identidade e serviceAccountName não autorizado. Repetir tentativa via Deployment:
   o Pod inválido deve ser recusado, mesmo se a API aceitar o template do controller.

## Passos — TLS ao backend

1. Gerar CA/certificados sintéticos locais; não instalar CA no trust store global.
2. Habilitar TLS na fixture da aplicação, separado do TLS cliente→Gateway.
3. BackendTLSPolicy aponta Service/porta nomeada, CA e hostname/SAN coerentes.
4. Cliente valida certificado da borda com --cacert; não usar -k como aceite.
5. Confirmar TLS Gateway→app via logs/handshake; alterar CA, hostname e validade
   em casos separados. Cada negativo deve falhar antes de entregar request HTTP.
6. Restaurar CA/nome válidos e repetir canário. Se auth também usa TLS, replicar
   matriz para auth como extensão identificada; não inferir da app.

## Matriz de aceite

| Caso | Ação | Resultado obrigatório |
|---|---|---|
| T01 | A→A porta permitida / B→B | sucesso com marcador certo |
| T02 | A→B e B→A, conexões novas | bloqueio + evidência policy, sem log app |
| T03 | A→A porta não autorizada | bloqueio |
| T04 | DNS necessário | resolve e app continua funcional |
| T05 | usuário sem auth na borda | erro; app não recebe |
| T06 | acesso direto ao pod/Service que contorne borda | bloqueado quando origem não autorizada |
| T07 | TCP/UDP sob a mesma VIP | política L4 definida e testada; não atribuir proteção a ExternalAuth |
| T08 | tenant B tenta editar A, policy ou label de identidade | Forbidden na API real |
| T09 | ListenerSet permitido/negado e conflitos | tráfego/conditions seguem delegação observada |
| T10 | backend cross-namespace sem/com Grant | rejeita/funciona; menor permissão |
| T11 | backend TLS CA/nome válidos | sucesso + TLS comprovado |
| T12 | CA errada / SAN errado / expirado | falha sem request na app |
| T13 | recriação de pods e remoção de Grant | restrições permanecem após reconciliação |
| T14 | tenant cria policy allow-all nova ou RoleBinding de escalada | Forbidden; T02 segue negado |
| T15 | tenant/delegado cria rota sem auth ou novo Gateway para contornar edge | Forbidden/NotAccepted; zero request na app |
| T16 | tenant tenta hostNetwork/privileged/hostPID/hostPath | admission rejeita Pod; zero execução privilegiada |
| T17 | label de tenant ausente/forjado/alterado ou SA indevida, direto e via controller | nenhum Pod inválido executa; controle legítimo continua aceito |

30 tentativas novas por par de rede/HTTP, três rodadas. Chamadas RBAC negativas:
ao menos uma por verbo/recurso enumerado; guardar status e corpo sanitizado.
Sem prova de deny no componente esperado, timeout sozinho é inconclusivo.

## Diagnóstico e rollback

DNS quebrou após deny → allow DNS mínimo; não remover todas as policies.
200 inesperado cross-tenant → auditar policy aditiva, identidade e rota; tratar
como falha de isolamento. Namespace labels mutáveis → corrigir autoridade antes
de repetir. Listener Accepted com um listener inválido → avaliar item individual.
TLS só na borda → não contar T11. Nunca fazer curl -k para “resolver” T12.

Antes de S009, inventariar por nome/UID e owner: namespace/labels PSA, policies,
ValidatingAdmissionPolicy/Binding (cluster-scoped), RBAC/ServiceAccounts, Grants,
GatewayClass/Gateway/ListenerSets/Routes, fixtures e certificados sintéticos.
Guardar baseline/diff. Admission deve casar somente namespaces study=P003;
nem mesmo uma VAP experimental pode selecionar todo o cluster por acidente.

Rollback em ordem: retirar rotas/grants/fixtures de falha; restaurar configurações
funcionais da borda e policies mínimas; restaurar RBAC e admission/Bindings do
baseline ou remover somente os criados pelo estudo; repor labels de namespace
anteriores por inventário. Restaurar/retirar certs sintéticos e fechar coletores
próprios. Não aplicar grants antigos se a identidade de destino mudou.
Canários A→A/B→B, A↔B negados e allow/deny HTTP precisam passar no estado final.
Se a base anterior não tinha isolamento, conservar o estado seguro documentado
até decisão do coordenador em vez de reabrir comunicação inadvertidamente.
Qualquer restauração inconclusiva gera handoff BLOCKED com objetos remanescentes.

PASS exige todos os negativos eficazes, estado final explícito e declaração:
separação lógica testada, não isolamento de kernel/VRF.
