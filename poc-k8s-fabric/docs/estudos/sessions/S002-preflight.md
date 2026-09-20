# S002 — Modelo público de preflight somente leitura

> O modelo descreve a próxima fatia prevista. O experimento e o inventário ainda não foram executados nesta publicação.

## Estado público

- **Status:** previsão; a sessão só deve ser materializada depois da aceitação da predecessora.
- **Objetivo:** inventário atual verificável e envelope de sandbox sem colisões.
- **Próxima etapa:** S003 continua em forecast até que este preflight tenha evidência e aceite.

## Papel

Leitura de preflight somente leitura; a coordenação conserva as decisões, as
evidências e o aceite. A pessoa que coleta devolve dados e texto, e não decide
o veredito nem altera o estado do laboratório.

## Session Goal

Produzir inventário atual verificável e um envelope de sandbox sem colisões,
com orçamento de recursos, versões fixadas e escopo concreto para S003.

## Bootstrap portátil

1. Ler o [índice público](../README.md), o [contrato](../design-contract.md), o [protocolo](../execution-protocol.md) e este modelo.
2. Confirmar que a edição local está alinhada ao commit que será estudado.
3. Verificar o acesso de referência com as variáveis `REFERENCE_SSH_TARGET` e `REFERENCE_SSH_KEY`; não registrar endpoints ou chaves reais.
4. No host remoto, definir `REFERENCE_KUBECONFIG` e `REFERENCE_CONTEXT`; variáveis do shell Mac não passam automaticamente pela sessão SSH.
5. Materializar uma única sessão privada de execução e manter evidência fora da documentação pública.
6. Nenhuma CLI de agente ou ferramenta externa é necessária para interpretar este roteiro.

## Especificação da tarefa


### Objective

Entregar inventory.md, environment.md, sandbox-envelope.md, versions.lock.md,
baseline-reference.md e open-questions.md com fontes observadas e lacunas explícitas.

### Anchors

- `../../../topo/poc-kind.clab.yml:9` — `name: poc-k8s-kind`.
- `../../../topo/kind-cluster.yaml:5` — `disableDefaultCNI: true`.
- `../../../scripts/02-install-cilium.sh:13` — `CP_CONTAINER="${CP_CONTAINER:-k01-control-plane}"`.
- `../../../k8s/cilium/values-native.yaml:17` — `routingMode: native`.
  Linhas/snippets conferidos na autoria; reler antes de delegar para detectar drift.
- [E00](../00-preflight.md) — `## Envelope candidato — ainda não é alocação`.

### Steps

1. **Mac/local:** git status; conferir predecessor GO e data de research.md.
   Criar pasta de evidência local por UTC run, sem sobrescrever execução antiga.
2. **Mac:** abrir a sessão com `$REFERENCE_SSH_TARGET` e `$REFERENCE_SSH_KEY`, conforme E00. Confirmar hostname antes de prosseguir; erro de SSH não autoriza criar VM ou trocar credencial.
3. **Host remoto, somente leitura:** coletar kernel, RAM/disco, Docker, interfaces, rotas e listeners.
4. **Kubernetes de referência, somente leitura:** usar exclusivamente `$REFERENCE_KUBECONFIG` e `$REFERENCE_CONTEXT`, com flags explícitas em cada comando. Registrar kube-system UID, nós, pods, Cilium versão e BGP.
5. **Canário de referência:** ler comando de acesso em lab-guide-student.md e
   testar VIP 10.201.255.10 do client-ext da referência; 10 requisições sem retry,
   guardando códigos/corpos/hostnames. Erro é estado observado, não conserto automático.
6. **Local/coordenador:** comparar todos os nomes/CIDRs candidatos de E00 com
   inventário e redes alcançáveis relevantes. Documentar cada ausência de colisão.
7. **Local/rede pública:** resolver versões/digests das imagens e chart pelo
   registry/release oficial; confirmar tag→commit pesquisado, schema CRDs e tools.
   Não atualizar binaries no Mac/VM para realizar esse inventário.
8. **Coordenador:** elaborar orçamento de recursos e escolher opção concreta
   de sandbox dentre as três do master. Não escolher novo host pago sem direção do dono.
9. Escrever entregáveis; resolver lacunas independentes. Se descoberta técnica
   requer mais trabalho local, manter IN_PROGRESS e tarefa bounded. Se acesso
   externo/infra falta, BLOCKED com handoff; não cortar gate para criar S003.

### Constraints

- O executor MUST registrar comando/local/UTC junto a cada observação.
- O executor MUST definir as quatro variáveis de referência antes da coleta e distinguir o shell Mac do shell remoto.
- O executor MUST NOT alterar cluster/cloud/host, because esta fatia é somente leitura.
- O executor SHOULD distinguir valores medidos de candidatos não provisionados.
- You MAY use existing read-only tools to resolve image digests without installing new packages.
- Antes de coletar, sanitizar somente a saída necessária; não imprimir env/tokens,
  kubeconfig, Secrets, clouds.yaml ou chaves privadas.
- O UID de k01 é observado aqui. O UID do sandbox só existirá após criação em
  S003: registrá-lo como não criado; não usar UID de k01 como STUDY_CLUSTER_UID.
- Não iniciar S003 nesta rodada de preflight. READY é disponibilidade da fatia,
  não autorização automática para a infraestrutura da próxima.

### Acceptance

Os checks abaixo são executados ao final DESTA sessão futura, contra o diretório
de evidência real, não agora durante autoria do plano:

```bash
test -s "$STUDY_EVIDENCE/inventory.md"
test -s "$STUDY_EVIDENCE/environment.md"
test -s "$STUDY_EVIDENCE/sandbox-envelope.md"
test -s "$STUDY_EVIDENCE/versions.lock.md"
test -s "$STUDY_EVIDENCE/baseline-reference.md"
test -s "$STUDY_EVIDENCE/open-questions.md"
```

Existência de arquivo não atribui GO. O coordenador MUST conferir conteúdo:

1. Inventário traz saídas reais, alvos e UTC, inclusive eventual baseline degradado.
2. Envelope contém cluster/context/namespaces/redes/endereços/portas/bridges e
   checagem de colisão para cada valor; sem variável de execução escolhida por palpite.
3. Orçamento mostra RAM/disco e limites; desconhecidos de consumo têm ensaio
   delimitado antes da criação completa, sem afirmar capacidade já comprovada.
4. Lock traz tags, digests/SHAs e referências para imagens/CRDs/chart; indisponível
   vira gate nomeado que bloqueia a ação dependente em S003.
5. Canário HTTP tem resultado observado separado da expectativa e BGP é corroborado.
6. Próxima fatia tem artefatos e ação concreta para revisão; não resta decisão
   arquitetural básica escondida sob “o executor resolve”.

### Out-of-scope

Deploy Helm/CRDs, docker/clab/kind create/delete, modprobe/instalação, mutação de
rota/guard/SG, IPAM/policy, testes de falha, qualquer outro kubecontext ou ambiente gerenciado não inventariado.

## Success Criteria

GO quando as seis verificações de conteúdo acima têm evidência e o desenho de
sandbox pode ser materializado com limites claros. Se isolamento ou acesso não
é verificável, BLOCKED. Consumo de imagem ainda não medido pode ser condicional
somente se o ensaio inicial de capacidade for explícito e impedir excesso em S003.
Nenhuma alteração remota é necessária para fechar esta sessão.

## Closeout Steps

Escrever results e handoff com verdict. Se GO, materializar apenas S003, incluindo
valores reais, allowlist, comando de dry-run e gate da autorização de execução
quando ela ainda não existir. Atualizar ledger com novas evidências; parent
atualiza o índice local da execução. BLOCKED/FAIL não cria sucessora.

## Rollback

Encerrar somente sessão SSH/coleta iniciada pelo preflight. Não fechar túnel
antigo, não desligar lab e não reparar automaticamente divergência do baseline.
