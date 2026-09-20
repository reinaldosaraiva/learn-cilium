# Contrato operacional dos estudos P003

Documento de planejamento. Comandos de experimento só serão executados quando
materializados na sessão autorizada. O executor MUST ler este protocolo e seu
dossiê; a coordenação fornece valores reais e âncoras antes da delegação.

## 0. Variáveis de acesso e lados do shell

No Mac, defina as variáveis de acesso antes da conexão:

```bash
export REFERENCE_SSH_TARGET='user@lab.example'
export REFERENCE_SSH_KEY='/secure/path/reference-key'
ssh -i "$REFERENCE_SSH_KEY" "$REFERENCE_SSH_TARGET"
```

No host remoto, defina as variáveis do laboratório de referência. Variáveis do
shell Mac não passam automaticamente pelo SSH:

```bash
export REFERENCE_KUBECONFIG='/secure/path/reference/kubeconfig'
export REFERENCE_CONTEXT='kind-k01'
sudo kubectl --kubeconfig "$REFERENCE_KUBECONFIG" --context "$REFERENCE_CONTEXT" get nodes
sudo cilium --kubeconfig "$REFERENCE_KUBECONFIG" --context "$REFERENCE_CONTEXT" bgp peers
```

`REFERENCE_LAB_ROOT` e `STUDY_LAB_ROOT` são diretórios lógicos definidos no
host depois do inventário; o primeiro aponta para a referência e o segundo para
o sandbox. Eles não são endpoints publicados nem valores a escolher por palpite.

## 1. Fronteiras de execução

| Local | Pode fazer | Não pode inferir |
|---|---|---|
| Mac / checkout | Ler e preparar artefatos locais | Que o kubecontext atual é o lab |
| vm-cilium / host | Inventário e sandbox autorizado | Que Docker/rotas estão exclusivos do experimento |
| container de cliente | Probes e captura escopada | Que é uma VM externa à vm-cilium |
| Kubernetes sandbox | Objetos da sessão | Que namespace protege mudanças Helm/CRD globais |
| OpenStack experimental | Somente projetos/portas inventariados | Que CLI Magalu dá acesso ao Neutron |

k01 e a VIP didática `10.201.255.10` são referência histórica protegida. Recursos de execuções anteriores ficam fora do escopo e não devem ser reutilizados por inferência.
Não usar `scripts/99-destroy.sh` ou `clab destroy --all`. O script de instalação
existente usa contexto implícito e CP k01 por default: não invocá-lo sem adaptação
revisada para contexto e CP explícitos. Preservar devices=eth+ no cenário kind.

## 2. Contrato de entrada para um modelo executor

Cada tarefa delegada MUST conter:

1. **Objective:** um efeito observável, não “implementar o estudo inteiro”.
2. **Anchors:** arquivos existentes + linha/snippet relidos pelo coordenador.
3. **Steps:** lista ordenada; shell/local; valores completos; nenhuma descoberta arquitetural.
4. **Constraints:** contexto, allowlist de escrita, objetos permitidos e limites.
5. **Acceptance:** comando real, resultado esperado, controle negativo e evidência.
6. **Out-of-scope:** nomes e recursos que não pertencem à tarefa.

Se faltar arquivo, endpoint, digest ou opção CLI, retornar NEEDS_INPUT com prova
da lacuna ao coordenador. Isso é estado interno de tarefa, não verdict Reentry.
No máximo duas tentativas justificadas por evidência para o mesmo passo; evitar
loops cegos de restart/reapply. Nova hipótese exige decisão do coordenador.

## 3. Variáveis e identidade do ambiente

S002 escreve `environment.md` em sua evidência. Os nomes seguintes são o contrato,
não valores livres a preencher pelo executor:

| Variável | Origem | Verificação |
|---|---|---|
| STUDY_KUBECONFIG | arquivo dedicado do sandbox | existe; modo 0600; nunca impresso |
| STUDY_CONTEXT | kind-p003-gw (candidato) | cluster + UID kube-system registrado |
| STUDY_CLUSTER_UID | descoberta real | igual ao UID antes de cada mutação |
| STUDY_NS | namespace da célula | prefixo p003- e label study=P003 |
| STUDY_GATEWAY | Gateway concreto da célula | ownership do Service gerado |
| STUDY_REQUEST_ID | gerado por tentativa | ID sintético único; nunca reutilizar |
| STUDY_URL | endereço, porta e path reais da célula | URL completa, sem destino implícito |
| STUDY_GENERATED_SERVICE | Service resolvido por ownerReference UID | nome e UID conferidos antes do probe |
| STUDY_EVIDENCE | diretório por run/case | novo, privado, sem sobrescrever |
| STUDY_CLIENT | container descoberto | inspecionado na topologia do sandbox |
| STUDY_DNS_NAME | zona TXT sintética da fixture | nome completo usado no probe DNS |
| STUDY_GW_IP / STUDY_NODE_IP | JSON observado | IPv4 da lane escolhida, não primeiro IP implícito |
| STUDY_SOURCE_NODE / STUDY_AUTH_NODE | placement observado | prova Envoy e Pod.spec.nodeName |
| STUDY_OS_CLOUD | perfil local OpenStack | perfil autorizado; credenciais nunca impressas |
| STUDY_PROJECT_ID | UUID do projeto autorizado | escopo confirmado antes da consulta |
| STUDY_PORT_ID | UUID da porta própria inventariada | pertence ao projeto e à fixture do estudo |

Nos snippets abaixo, `k` é uma função Bash da sessão, não um binário instalado:

```bash
set -euo pipefail
: "${STUDY_KUBECONFIG:?}" "${STUDY_CONTEXT:?}" "${STUDY_CLUSTER_UID:?}"
k() { kubectl --kubeconfig "$STUDY_KUBECONFIG" --context "$STUDY_CONTEXT" "$@"; }
test "$(k get namespace kube-system -o jsonpath='{.metadata.uid}')" = "$STUDY_CLUSTER_UID"
```

Reexecutar essa identificação ao mudar de terminal. `sudo` não deve perder as
variáveis: passar argumentos explícitos, sem depender de env preservado.

## 4. Modelo de evidência

Destino local privado: `poc-k8s-fabric/evidence/P003/<session>/<UTC-run>/<case>/`.
Esse diretório é evidência de execução e permanece fora da edição pública; não é
um link necessário para ler os dossiês.
Cada caso MUST conter:

- `case.md`: hipótese, variável alterada, controle, pré-condições e resultado.
- `versions.txt`: chart, imagem/digest, CRDs, kernel, tool versions.
- `before.json` / `after.json`: objetos públicos relevantes, sem Secrets.
- `requests.tsv`: run_id, case_id, request_id, UTC, destination, expected,
  observed_code, curl_exit, seconds, backend_marker, outcome.
- `placement.tsv`: node ingresso, Envoy, auth pod UID/IP/node, app pod UID/IP/node.
- `flows.jsonl`, logs por componente e pcaps quando o caso exigir.
- `rollback.md`: alterações feitas, restauração e probes após restaurar.

Não gravar `kubectl get secrets`, kubeconfig --raw, tokens, headers de sessão
reais ou saída de autenticação cloud. Usar credenciais sintéticas de laboratório.
Um sysdump bruto é privado; não anexar/publicar sem revisão e autorização.

## 5. Probes e regras de classificação

HTTP: ao menos 30 conexões novas por célula e três repetições. Usar um request ID
distinto, `--noproxy '*'`, `--retry 0` e `Connection: close`. Caso timeout de auth:
30s de prazo no cliente; o caso MUST distinguir limite do cliente de resposta do
Gateway. Não usar `curl -f`, que esconderia corpos de erro relevantes.

```bash
set +e
curl --noproxy '*' --retry 0 --connect-timeout 3 --max-time 30 \
  -H 'Connection: close' -H "X-Lab-Request-ID: $STUDY_REQUEST_ID" \
  -D "$STUDY_EVIDENCE/headers.txt" -o "$STUDY_EVIDENCE/body.txt" \
  -w '%{http_code}\t%{time_total}\n' "$STUDY_URL" \
  > "$STUDY_EVIDENCE/http-result.tsv" 2> "$STUDY_EVIDENCE/curl.stderr"
STUDY_CURL_RC=$?
set -e
printf '%s\n' "$STUDY_CURL_RC" > "$STUDY_EVIDENCE/curl.exit"
```

Um loop concreto criará subdiretório por request; não reutilizar os arquivos
acima para 30 requisições. Cli echo no teste L4 pode usar HTTP como payload TCP,
mas MUST ir por TCPRoute e backend com marcador, sem HTTPRoute correspondente.
UDP usa requisição/resposta real de DNS ou echo com nonce; `nc -zu` é insuficiente.

Executar sequencialmente por padrão para facilitar correlação. Casos de timeout
podem levar vários turnos: gravar checkpoint a cada request, usar ferramenta com
yield curto e reportar progresso pelo menos a cada 60s. Não reiniciar o lote ao
retomar. Concorrência altera carga e só entra como variante declarada, nunca como
atalho para encerrar a sessão sem a contagem requerida.

| Resultado de célula | Definição |
|---|---|
| CONFIRMED | Hipótese observada com controles válidos e evidência completa |
| NOT_REPRODUCED | Não apareceu no escopo/versionamento/quantidade testados |
| INCONCLUSIVE | Origem, coleta, controle ou configuração não permitem conclusão |
| UNSUPPORTED | Combinação documentada sem suporte, comportamento caracterizado |
| BLOCKED | Pré-requisito externo ausente |

Esses valores são classificação científica, separados de GO/PASS/BLOCKED/FAIL.
PASS de estudo exige matriz completa e conclusão honesta; não significa que o
produto seja seguro para produção. Um bypass observado reprova o gate de adoção.

## 6. Evidência de autorização

HTTP 200 isolado não prova consulta ao autorizador. Correlacionar request_id em
cliente, auth e aplicação. Para negar: auth viu ID e negou, cliente recebeu erro,
app não viu ID; provar observabilidade da app com canário positivo antes/depois.
Para serviço ausente: auth não será chamado; erro deve vir do Gateway e app não
recebe ID. Para timeout: comprovar requisição/parada no auth e retorno finito.

Contadores agregados só servem sem tráfego concorrente; caso contrário correlacionar
IDs. Não limpar tabelas de conntrack/BPF para “arrumar” controle; usar conexão nova
e registrar o estado de conexões existentes em teste separado.

## 7. Diagnóstico e parada

### Logs HTTP do Gateway

S003/S005 devem habilitar explicitamente access logs no GatewayClass experimental:
`CiliumGatewayClassConfig.spec.telemetry.accessLogs`, formato JSON, referenciado
por `GatewayClass.spec.parametersRef`. Campo Hubble ligado não substitui esse
log Envoy. Configuração mínima a materializar conforme CRD real:

```yaml
spec:
  telemetry:
    accessLogs:
      - format: JSON
        json:
          request_id: "%REQUEST_HEADER(X-LAB-REQUEST-ID)%"
          response_code: "%RESPONSE_CODE%"
          response_flags: "%RESPONSE_FLAGS%"
          upstream_host: "%UPSTREAM_HOST%"
          duration: "%DURATION%"
```

Coletar stdout do Envoy por pod/nó e associar metadata Kubernetes no arquivo.
`upstream_host` do access log da requisição principal pode ser a aplicação;
para identificar o endpoint de auth correlacionar log da fixture, xDS/counters
e captura. Não inferir auth chamado apenas pelo upstream_host da app.
Fonte: R14 Access Logs; operators acima conferidos no exemplo tagged 1.20.2.

### Ordem de diagnóstico

Ordem: schema/objeto persistido → conditions com observedGeneration atual →
Service/EndpointSlice → rota ida/volta → policy → Envoy/auth → WireGuard/MTU.
Se faltou SYN no destinatário, capturar ambos os lados antes de culpar a aplicação.
Se há SYN-ACK no destino mas não na origem, investigar retorno.
Um status `FORWARDED` descreve um ponto do caminho, não entrega fim a fim.

Capturar no cliente, interface de entrada, interface de saída real, cilium_wg0 e
destino, conforme hipótese. Kernel compartilhado em kind não equivale a máquinas
físicas distintas. Validar sobre qual rede Docker/fabric o pacote realmente passou.

## 8. Rollback e autorizações

Antes de cada mudança, salvar values/manifests normalizados, UIDs e release revision.
Restaurar o conjunto anterior explícito; não usar upgrade --reuse-values para
misturar modos. IPAM não é rollback simples: usar clusters/pools separados.
Se rollback falha: parar, registrar estado parcial e entregar handoff BLOCKED.

Nesta edição, só está autorizado o planejamento documental. Uma execução futura deve registrar sua autorização no artefato de sessão e seguir somente o escopo concedido. Teardown de recursos históricos e publicações
continuam fora desse escopo. Limpeza experimental só por lista de objetos próprios
que a autorização de execução abarcar; nenhum delete amplo por label genérico.

## 9. Closeout

Coordenador revisa artefatos reais e decide verdict. Um reviewer nativo novo testa
se os dados sustentam a conclusão; registrar independencia por contexto, nao por
provider. Rodada de entrega usa conformance e Goal-check; design usa GO.
BLOCKED/FAIL exige handoff e não materializa sucessora. Legacy 2.x não cria journal.
