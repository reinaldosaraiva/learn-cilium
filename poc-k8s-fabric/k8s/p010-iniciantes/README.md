# Manifests do laboratório iniciante P010

Este diretório acompanha a edição de trabalho do livro `docs/ebpf-cilium-iniciantes.md`. Use livro, Makefiles, manifests e automação da mesma cópia de revisão; a disponibilidade pública dos mesmos bytes não está garantida. Os comandos Kubernetes rodam na VM Ubuntu própria, usando kubeconfig, contexto e namespace da sessão criada pelo perfil.

## Pré-requisitos e limites

- VM Ubuntu 24.04 amd64, conta não-root com sudo, Internet e cópia completa do projeto. Instale os pré-requisitos: `sudo apt update && sudo apt install -y git make`.
- Antes de criar objetos de prática, execute `make --no-print-directory lab-preflight LAB=iniciantes`, `make --no-print-directory lab-up LAB=iniciantes`, `make --no-print-directory lab-status LAB=iniciantes` e `make --no-print-directory lab-verify LAB=iniciantes`; depois crie uma identidade com `make --no-print-directory lab-session LAB=iniciantes` e capture `make --no-print-directory lab-env LAB=iniciantes`. O fluxo detalhado está em [E01](../../docs/ebpf-cilium-iniciantes.md#e01--reconhecer-o-ambiente-e-preparar-a-rodada).
- Os manifests omitem `metadata.namespace` intencionalmente. Todo comando de aplicação do guia passa `-n "$LAB_NS"` e usa kubeconfig/contexto explícitos.
- Não altere o estado privado, Cilium, Hubble, charts ou políticas globais. Pare se um gate recusar ou uma consulta estiver inconclusiva. O alvo público de M11 híbrido continua bloqueado antes de efeitos.
- Os digests são referências de índice de imagem conferidas em um recibo de origem. Nenhuma imagem foi puxada ou executada por esta edição. O `imageID` e a arquitetura reais só podem ser registrados depois de uma execução admitida.
- As respostas esperadas no guia são ilustrativas. O manifesto não declara que o cluster aceita essas imagens ou que os comandos foram reproduzidos.

## Arquivos e ordem

| Arquivo | Uso |
| --- | --- |
| `00-config.yaml` | ServiceAccount sem token automático; ConfigMaps do backend e NGINX. |
| `10-backend-service.yaml` | Service `backend` porta 80 → targetPort `http`/8080. Aplicar antes de iniciar NGINX. |
| `11-backend-deployment.yaml` | Um Pod BusyBox `httpd` com `/` e `/health`. |
| `20-api-service.yaml` | Service `api` porta 80 → targetPort `http`/8080. |
| `21-api-deployment.yaml` | Um Pod NGINX unprivileged que faz proxy real para `http://backend:80`. `/ready` verifica somente o processo/configuração local. |
| `30-frontend-deployment.yaml` | Um Pod `curl` ocioso, sem probe falsa ou loop de chamadas. |
| `40-policies-ingress.yaml` | Policies de ingresso: frontend → api e api → backend pela porta TCP/8080. Egress não é isolado neste recorte. |
| `41-backend-service-defeito.yaml` | Variação controlada que altera somente o selector do Service backend; aplicar apenas em E05 e restaurar o arquivo saudável. |

Aplicar em ordem descrita em E02: `00-config.yaml`; `10-backend-service.yaml`; `11-backend-deployment.yaml`; `20-api-service.yaml`; `21-api-deployment.yaml`; `30-frontend-deployment.yaml`. A Service backend é criada antes do Pod NGINX para o nome do upstream existir quando a configuração NGINX carregar. As policies são aplicadas somente em E04, e o Service defeituoso somente em E05.

## Modelo de tráfego

`frontend` espera sem gerar tráfego. Um comando manual `kubectl exec ... -- curl ...` testa o caminho `frontend → Service api:80 → NGINX:8080 → Service backend:80 → BusyBox httpd:8080`. A configuração NGINX define o cabeçalho `X-Lab-Route: via-api-proxy`; o acesso direto `frontend → Service backend` não passa pela API e não terá esse cabeçalho. O backend fornece página estática e `/health`. NGINX fornece `/ready`, que não consulta o backend. Probes são verificações locais, não validação da cadeia ponta a ponta.

NetworkPolicies selecionam somente o ingresso dos Pods api e backend. Policies aplicáveis são aditivas; políticas globais e restrições do cluster podem mudar o resultado. Uma falha de `curl` ou timeout sozinho não comprova bloqueio por policy: correlacione horário, destino e fluxo Hubble quando disponível. Egress fica deliberadamente livre nestes dois manifests.

## Segurança e limpeza

Os Pods usam usuário não root, `seccompProfile: RuntimeDefault`, sem escalada de privilégio, capabilities descartadas, filesystem raiz somente leitura quando aplicável e requests/limits. A ServiceAccount não recebe RBAC e não monta token automaticamente. NGINX recebe um `emptyDir` pequeno em `/tmp` para PID e arquivos temporários e a configuração é somente leitura.

Não passe credenciais para Pods ou recibos. Não registre conteúdo de kubeconfig, tokens, certificados ou chaves. Ao terminar, confirme novamente API server, UID da namespace e label de run-id. E06 apaga apenas a namespace nova desta rodada e espera a remoção normal. Se mantiver o cluster para outra rodada, confirme `lab-status` e `lab-verify` antes de criar nova sessão. Se encerrar a infraestrutura, execute `lab-down LAB=iniciantes` e confira `lab-status`; uma rodada posterior exige `lab-up` e verificação antes de `lab-session`. Não use `--force`, remova finalizers, apague objetos globais ou faça limpeza por selector amplo. Se a identidade divergir ou a remoção expirar, pare e preserve o estado.

## Verificação offline desta revisão

YAML e relações entre labels, portas, probes, imagens e guards devem ser verificadas localmente antes do uso. A checagem offline não valida schema contra o servidor, admissão, runtime, disponibilidade de imagem, alcance de rede, policy enforcement ou compatibilidade da versão do cluster. Nenhum `kubectl dry-run=server` foi executado durante a edição.
