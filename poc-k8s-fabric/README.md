# Kit do laboratório Cilium + BGP

Este diretório reúne o guia, os exercícios introdutórios, os dossiês dos
estudos e as ferramentas para validar ou gerar a documentação.

## Comece por aqui

- [Guia do estudante](docs/lab-guide-student.md): fonte Markdown dos 17 módulos.
- [PDF do guia](../output/pdf/cilium-lab-student-guide.pdf): versão para leitura.
- [Índice E01–E41](studies/README.md): trilhas, scripts, manifestos e dossiês.
- [Dossiês e resultados](docs/estudos/README.md): fotografias de planejamento e
  links para material publicado.
- [Histórico do projeto](docs/historico/README.md): documentos históricos
  preservados fora do caminho de navegação atual.

Os módulos 1–11 acompanham exercícios do laboratório. Os módulos 12–17 são
leitura de resultados e limites documentados; não exigem acesso às
infraestruturas descritas.

## Estrutura

| Caminho | Conteúdo |
|---|---|
| `topo/` e `configs/` | topologia Containerlab e configurações dos nós de rede |
| `k8s/` | recursos do cluster kind usados pelos exercícios |
| `scripts/` | preparação, deploy, validação e limpeza do laboratório |
| `studies/` | arquivos ligados às trilhas E01–E41 |
| `docs/estudos/` | dossiês públicos e sínteses de resultados |
| `docs/diagramas/` | diagramas usados no guia |
| `tools/` | verificações e geração do guia |
| `labctl/` | comandos documentados para o ciclo de vida dos labs |

## Como subir o laboratório

Para o roteiro de reconstrução e validação do laboratório, consulte o
[Apêndice A – Roteiro do instrutor](docs/lab-guide-student.md#apêndice-a--roteiro-do-instrutor)
e o [README do labctl](labctl/README.md). Esses documentos registram os
parâmetros e comandos usados pelo kit.

## Comandos

Na raiz do repositório, consulte `make -C poc-k8s-fabric help` para os alvos do
kit. Os alvos principais são:

```bash
make lint
make test
make pdf
```

`make lint` executa validações estáticas, incluindo referências relativas nos
Markdown públicos. `make test` executa as verificações definidas no Makefile;
`make pdf` gera o guia em `output/pdf/cilium-lab-student-guide.pdf` e requer
`pandoc` e `tectonic`.

O [índice de estudos](studies/README.md) aponta para arquivos existentes. O
[registro histórico do laboratório](docs/lab-results.md) conserva medições e
contexto de execução, enquanto os dossiês explicam o escopo de cada estudo.
