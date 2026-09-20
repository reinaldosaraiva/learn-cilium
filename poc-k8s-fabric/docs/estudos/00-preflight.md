# E00 — Inventário público e viabilidade do sandbox

> Este é um roteiro de preflight. A edição pública não afirma que a leitura foi executada.

Sessão prevista: S002. Natureza: descoberta somente leitura. Saída é uma decisão
GO/BLOCKED de viabilidade, não a criação do laboratório.

## Perguntas que precisam de resposta

1. Qual é a saúde atual de k01 e quanto recurso sobra na vm-cilium?
2. Quais nomes, redes Docker, interfaces e rotas já existem?
3. Um segundo fabric de cinco SR Linux e três nós kind cabe sem degradar k01?
4. Qual conjunto exato de versões, imagens e CRDs será usado?
5. Onde cada comando será executado e qual é a identidade do cluster?

## Entradas e âncoras

- `../../topo/poc-kind.clab.yml`: `name: poc-k8s-kind`.
- `../../topo/kind-cluster.yaml`: `disableDefaultCNI: true`.
- `../../scripts/02-install-cilium.sh`: default `k01-control-plane`.
- `../../k8s/cilium/values-native.yaml`: `routingMode: native`.
- `../lab-results.md`: último estado datado.

## Passos

| Passo | Local e ação | Esperado | Se divergir |
|---|---|---|---|
| P01 | Mac: git status e ler o índice público, contrato, protocolo e modelo de sessão | plano público disponível, escopo de leitura | Parar antes de usar contexto antigo |
| P02 | Mac: SSH para vm-cilium com identidade conhecida | Shell no host esperado | Registrar erro; não criar VM ou trocar chaves |
| P03 | Host: hostname, uname, recursos, Docker e rotas | Inventário completo | Falta de permissão vira lacuna explícita |
| P04 | Host: consultar k01 pelo kubeconfig dedicado | UID/nós/pods/versões observados | Lab degradado: registrar; não reparar nesta sessão |
| P05 | Host: probes existentes VIP e BGP | Canário de referência | Distinguir falha nova de limitação histórica |
| P06 | Mac: resolver releases/CRDs/imagens por fontes primárias | Lista de pinning sem latest | Não inventar digest indisponível |
| P07 | Coordenador: collision/resource review | sandbox-envelope.md completo | BLOCKED se isolamento/capacidade não demonstrados |

Leitura remota planejada, não executada nesta rodada. No Mac, preencha o alvo e
a chave antes de abrir a sessão; `user@lab.example` é apenas um valor reservado
para a documentação:

```bash
export REFERENCE_SSH_TARGET='user@lab.example'
export REFERENCE_SSH_KEY='/secure/path/reference-key'
ssh -i "$REFERENCE_SSH_KEY" "$REFERENCE_SSH_TARGET"
```

Depois de entrar no host remoto, defina o kubeconfig e o contexto localmente.
As variáveis do shell Mac não passam automaticamente pelo SSH:

```bash
export REFERENCE_KUBECONFIG='/secure/path/reference/kubeconfig'
export REFERENCE_CONTEXT='kind-k01'
hostname
uname -r
free -h
df -h / /var/lib/docker
sudo docker ps --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}'
sudo docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'
sudo docker network ls
ip -j address show
ip -j route show table all
sudo ss -lntup
sudo kubectl --kubeconfig "$REFERENCE_KUBECONFIG" --context "$REFERENCE_CONTEXT" get nodes -o wide
sudo kubectl --kubeconfig "$REFERENCE_KUBECONFIG" --context "$REFERENCE_CONTEXT" get namespace kube-system -o jsonpath='{.metadata.uid}'
sudo kubectl --kubeconfig "$REFERENCE_KUBECONFIG" --context "$REFERENCE_CONTEXT" get pods -A -o wide
sudo cilium --kubeconfig "$REFERENCE_KUBECONFIG" --context "$REFERENCE_CONTEXT" bgp peers
```

Inspecionar redes Docker por nome/ID exato após listar, sem dump de env dos
containers. Não usar `kubectl config view --raw` nem ler Secrets.
Saída de usuário sem permissão em um comando não deve virar conclusão de ausência.

## Envelope candidato — ainda não é alocação

| Item | Referência protegida | Candidato experimental |
|---|---|---|
| Diretório remoto | `REFERENCE_LAB_ROOT` definido no host de referência | `STUDY_LAB_ROOT` definido no host experimental |
| Cluster/context | k01 / kind-k01 | p003-gw / kind-p003-gw |
| Containerlab | poc-k8s-kind | p003-gw-fabric |
| Management Docker | clab-poc-kind | p003-gw-mgmt; CIDR a validar |
| Racks | 10.10.1/2.0/24 | 10.30.1.0/24 e 10.30.2.0/24 |
| Pods | 10.244.0.0/16 | 10.245.0.0/16 |
| Services | 10.96.0.0/12 | 10.112.0.0/16 |
| VIP | 10.201.255.0/24 | 10.202.255.0/24; Gateway .10 |
| Cliente | 203.0.113.0/24 | 198.19.0.0/24 |
| Bridges/host links | incluindo clab-ext | nomes p003-* exclusivos; sem exposição VPC |

Comparar também redes privadas, rotas do Mac e infraestrutura acessível; nenhum CIDR
é seguro só porque está nesta tabela. Preferir não criar link ao host da VPC:
cliente interno ao fabric basta para os primeiros estudos.

## Critérios de capacidade e compatibilidade

- Registrar medição e requests/limits propostos; três nós K8s, fabric e fixtures.
- Proposta de margem operacional do estudo: após orçamento de memória do sandbox,
  manter pelo menos 20% da RAM do host livre e 20 GiB de disco. Esses números são
  orçamento conservador do experimento, não requisitos oficiais do Cilium.
- Se consumo das imagens não for conhecido, S002 entrega envelope condicionado
  ao ensaio de capacidade S003; não chama simultaneidade garantida de GO.
- Kernel precisa suportar WireGuard; verificar módulo/config sem carregar módulo
  ou instalar pacote nesta fase. Falta de prova é pendência de bootstrap, não bug.
- Registrar CRDs Standard/experimental e storage versions. O alvo principal usa
  bundle experimental 1.6.1 em cluster novo, sem downgrade de CRD do k01.
- Resolver tag→commit e comparar com research.md. Depois usar commit fixo nos
  downloads de manifests/fontes; checksum do chart e digest das imagens no lock.
  Se uma tag mudar de alvo, parar e registrar divergência, sem atualizar silenciosamente.

## Artefatos obrigatórios

`inventory.md`, `environment.md`, `sandbox-envelope.md`, `versions.lock.md`,
`baseline-reference.md`, `open-questions.md`, todos sob a evidência da S002.
Perguntas obrigatórias para execução: disponibilidade do sandbox e autorização
do pacote de testes. Não pedir credenciais na conversa; usar configuração local.

## Aceite e rollback

GO quando todos os nomes/endereços têm checagem de colisão, baseline é datado,
recursos têm orçamento explícito e pendências são encaminhadas a um gate antes
da ação dependente. Se o alvo não pode ser identificado ou não há isolamento
viável, BLOCKED. Como é leitura, rollback é encerrar somente a sessão SSH aberta;
não matar túneis ou processos antigos.
