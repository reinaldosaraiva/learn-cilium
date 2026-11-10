# learn-cilium

Materiais de estudo e laboratório sobre Kubernetes, Cilium, BGP e redes de
datacenter. Há dois livros atuais para estudantes: o guia de Cilium/BGP e o
curso introdutório com a sequência E01–E06. Estudos avançados aparecem como
leitura histórica, com seus limites identificados.

## Acesso rápido

- [Livro Cilium, BGP e tenants](poc-k8s-fabric/docs/lab-guide-student.md) · [PDF](output/pdf/cilium-lab-student-guide.pdf)
- [Livro iniciante e exercícios E01–E06](poc-k8s-fabric/docs/ebpf-cilium-iniciantes.md) · [PDF](output/pdf/ebpf-cilium-iniciantes.pdf)
- [Kit do laboratório](poc-k8s-fabric/README.md) · [Preparação e limpeza próprias](poc-k8s-fabric/docs/lab-guide-student.md#apêndice-a--preparar-verificar-e-encerrar-o-laboratório-próprio)
- [Índice dos estudos E01–E41](poc-k8s-fabric/studies/README.md)
- [Histórico do projeto](poc-k8s-fabric/docs/historico/README.md)

## Roteiro

O fluxo dos perfis próprios começa no livro correspondente. Em uma VM Ubuntu
24.04 amd64 limpa, instale `git` e `make` (`sudo apt-get update && sudo apt-get
install -y git make`), clone o repositório público com
`git clone --branch docs/p010-s001-20261028 https://github.com/reinaldosaraiva/learn-cilium.git`,
entre em `learn-cilium`, execute os gates e use a identidade gerada pelo
laboratório. A cópia precisa ser um clone Git, porque `lab-env` lê o `HEAD`; o
clone traz os livros, Makefiles, manifests e automação da mesma revisão. O
código da composição híbrida permanece bloqueado e sem validação de runtime
nesta edição.

Os módulos 1–10 do guia e E01–E06 do livro iniciante descrevem práticas dos
perfis suportados. M11 híbrido está em validação e não pode ser iniciado pelo
alvo público. Os capítulos avançados são leitura de resultados históricos.

## Verificação e geração

Os PDFs distribuídos são artefatos gerados a partir dos respectivos fontes
Markdown. Para preparar uma cópia para leitura, confira as instruções atuais do
kit; não use um PDF histórico como prova de versão do código ou runtime.

## Organização

- `poc-k8s-fabric/docs/` contém o guia, os dossiês e os diagramas publicados.
- `poc-k8s-fabric/studies/` contém scripts e manifestos associados aos estudos.
- `poc-k8s-fabric/docs/historico/` preserva documentos de evolução do projeto.
- `output/pdf/` recebe o PDF gerado.

O índice de estudos aponta para os arquivos reais de cada trilha. Os dossiês
distinguem resultados medidos, limites e material histórico.
