# E03 — ExternalAuth: funcionamento, rejeição e falhas

Sessões S005 (fixtures/smoke/decisão) e S006 (falhas/referências/patch).
Fontes R05, R09–R13. Pré-condições: Gateway HTTP funciona; WireGuard desligado;
sem política restritiva nova. HTTPRoute é a rota protegida nos dois protocolos:
GRPC aqui é o protocolo entre Envoy e autorizador, não exige GRPCRoute da aplicação.

## Arquitetura e hipóteses

Cliente → VIP/Envoy → subrequisição ext_authz → allow/deny → aplicação.
O código HTTP do autorizador e o código final da aplicação são evidências distintas.
Uma resposta 200 do backend não prova que houve consulta de autorização.
ExternalAuth não é um IdP pronto; este estudo usa credenciais/decisões sintéticas.

## Fixture controlada — requisito de S005

Reusar o demo oficial v1.20.2 para o primeiro smoke. Antes de afirmar segurança,
adaptar a fixture em diretório do estudo, preservando licença e commit de origem.
Âncoras upstream conferidas: `main.go`, `func newHTTPMux(logger *slog.Logger)` e
`func (s *server) Check(ctx context.Context, req *authv3.CheckRequest)`.
O coordenador materializa cópia local, relê as linhas e só então delega mudança.

| Entrada X-Lab-Decision | HTTP ext_authz | gRPC ext_authz | Prova |
|---|---|---|---|
| allow | 200 e X-Test-Authz=allowed-http | CheckResponse OK + header allowed-grpc | ID/decisão no log + header na app |
| deny | 403 | CheckResponse PERMISSION_DENIED + DeniedHttpResponse 403 | ID no auth, zero ID na app |
| ausente/valor desconhecido | 401 | UNAUTHENTICATED + DeniedHttpResponse 401 | default deny observável |
| delay | esperar 15s, respeitando cancelamento | esperar 15s, respeitando contexto | registro início/fim/cancel e prazo do Gateway |

`/healthz` não depende de decisão. A fixture MUST registrar somente ID, decisão,
protocolo, instante, duração e pod; não todos os headers como faz o demo.
Nas duas respostas allow, a fixture também define `X-Lab-User: lab-user-a`,
valor sintético fixo, para tornar A08 determinístico. Deny não entrega esse header à app.
Não usar log de token/cookie real. O backend da aplicação precisa registrar
X-Lab-Request-ID e marcador; habilitar/validar isso antes dos controles negativos.
Fixture é simulador, não sistema de autenticação para uso real.

Testes diretos da fixture precedem Gateway: allow, deny, ausência e delay nos
dois protocolos. gRPC testa o método Check com cliente tipado ou descriptor fixado;
não depender de reflection não implementada. O resultado valida fixture e captura,
não o Gateway. Fixar imagem por digest/hash de build.

## Preparação do filtro

1. Confirmar schema experimental 1.6.1. `kubectl explain`/CRD schema deve conter
   externalAuth; após apply, reler o HTTPRoute e conferir filtro persistido.
2. Começar auth e app no mesmo worker de ingresso comprovado. Usar só uma réplica
   do auth nessa fase para eliminar distribuição de endpoints.
3. Criar rotas protegidas `/protected-http` e `/protected-grpc`; rota `/public`
   sem filtro serve como controle de conectividade e de isolamento por rota.
4. Allowlist de request headers inclui X-Lab-Request-ID e X-Lab-Decision; response
   headers incluem só X-Test-Authz e X-Lab-User. Não confiar em header fornecido
   pelo cliente como identidade final sem provar substituição/sanitização.
5. Inspecionar CEC e config carregada no Envoy. Extrair nomes de clusters, endpoints,
   configuração de ext_authz e erros xDS; não salvar Secrets/TLS privadas.
6. Confirmar que duas rotas com settings diferentes para o mesmo auth Service
   não contaminam a configuração uma da outra. Path prefix não é exact match:
   registrar o path realmente recebido pelo autorizador.

## S005 — matriz funcional

| Caso | Entrada | Esperado no cliente | Esperado no auth/app |
|---|---|---|---|
| A01 | /public | 200 + marcador | auth ausente; app presente |
| A02 | HTTP + allow | 200 + marcador | auth allow; app presente com header do auth |
| A03 | HTTP + deny | 403 | auth deny; app ausente |
| A04 | HTTP sem decisão | 401 | auth deny; app ausente |
| A05 | GRPC + allow | 200 + marcador | Check OK; app presente |
| A06 | GRPC + deny | 403 | Check negou; app ausente |
| A07 | GRPC sem decisão | 401 | Check não autenticado; app ausente |
| A08 | Cliente forja X-Lab-User | conforme auth | valor final vem do auth ou é removido; nunca confiar no forjado |
| A09 | Duas rotas mesmo auth, allowlists/paths distintos | cada rota aplica sua configuração | logs e headers sem vazamento entre rotas |
| A10 | Body pequeno e maior que maxSize escolhido | comportamento schema medido | bytes recebidos no auth e app registrados |

A08 exige primeiro definir sanitização por filtro/fixture e validar ordenação
real; falha não se resolve afirmando que ExternalAuth protege todos os headers.
A10 não presume que truncar corpo no auth trunque também o corpo da aplicação.
Em S005, 30 requisições por decisão, três rodadas; testes de body usam ao menos
os limites maxSize−1, maxSize e maxSize+1, com conteúdo sintético e byte count.

## S006 — matriz de falhas e cross-namespace

| Caso | Mudança única | Expectativa de segurança | Diagnóstico |
|---|---|---|---|
| A11 | auth Deployment escalado a 0 | erro finito; app não recebe | EndpointSlice vazio e Envoy upstream error |
| A12 | auth atende mas demora 15s | Gateway termina com erro antes do cliente 30s | timeout real do auth no Envoy, sem app |
| A13 | backendRef aponta Service inexistente | erro; nunca omitir filtro e liberar app | HTTPRoute/CEC + response |
| A14 | Service existe, backendRef.port não | erro; app não recebe | porta ausente confirmada |
| A15 | auth em outro namespace, sem ReferenceGrant | erro; app não recebe | RefNotPermitted/ResolvedRefs e HTTP 500 quando aplicável |
| A16 | adicionar Grant mínimo válido | auth consultado e decisão respeitada | repetir allow e deny |
| A17 | remover Grant durante probes novos | parar autorização após reconciliação | medir janela; não ocultar transientes |
| A18 | restaurar auth/ref/Grant | allow e deny recuperados | canários A02/A03/A05/A06 |

Repetir A11–A18 nos protocolos HTTP e gRPC. Timeout HTTP de 10s é detalhe da tag
pesquisada; verificar xDS real. Não afirmar timeout igual em gRPC sem medição.
`curl` exit 28 antes de resposta é timeout do cliente: resultado INCONCLUSIVE
quanto a fail-closed observável, até ampliar coleta/prazo com justificativa.

## Comparação de patch

Baseline positivo deve ser 1.20.2. Para caracterizar 1.20.1, usar outro sandbox
ou reconstituição autorizada, mantendo CRDs, fixtures, manifests e kernel iguais.
Não fazer downgrade do k01 nem alterar CRD storage versions em cluster vivo.
Registrar digest/release em cada linha. A13–A15 comparam potencial regressão;
não requerem reproduzir bypass para considerar 1.20.2 testado corretamente.
Um bypass em 1.20.1 serve como evidência histórica e bloqueia adoção dessa configuração.

## Observabilidade, diagnóstico e aceite

Para cada ID: decisão cliente, evento auth, evento app e nó. Antes/depois de um
negativo, o canário positivo deve aparecer nos mesmos logs. “Não achei no log”
sem canário e janela temporal completa é INCONCLUSIVE.

- Sem chamada auth, app recebeu → investigar filtro/schema/rota selecionada;
  tratar como bypass, não sucesso de disponibilidade.
- Auth negou, app recebeu → falha de autorização; parar ampliação do experimento.
- Auth não recebe, Envoy tem endpoint válido → investigar transporte/rota/policy.
- Auth permite, app indisponível → erro de backend, não defeito do autorizador.
- Rota pública consulta auth → possível contaminação de filter/route config.

S005 PASS: fixture comprovada e A01–A10 completos. S006 PASS: A11–A18 completos,
nenhum acesso indevido no alvo corrigido e patch comparison explicitamente
executado ou retirado do aceite por emenda do coordenador/dono. Não declarar
segurança global do cluster: acesso direto ao backend será testado em E05.

Rollback: repor replicas/ref/Grant/values; remover somente fixture de falha própria.
Nunca apagar namespace do auth compartilhado, CRDs ou policies globais como limpeza.
