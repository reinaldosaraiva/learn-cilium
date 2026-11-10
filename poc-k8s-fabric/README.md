# Kit do laboratório Cilium + BGP

Este diretório reúne o guia, os exercícios introdutórios, os dossiês dos
estudos e as ferramentas para validar ou gerar a documentação.

## Comece por aqui

- [Livro Cilium, BGP e tenants](docs/lab-guide-student.md): fonte Markdown dos 17 módulos.
- [PDF do guia](../output/pdf/cilium-lab-student-guide.pdf): versão para leitura.
- [Livro iniciante E01–E06](docs/ebpf-cilium-iniciantes.md): Linux, rede, Kubernetes e práticas próprias.
- [PDF iniciante](../output/pdf/ebpf-cilium-iniciantes.pdf): versão para leitura.
- [Índice E01–E41](studies/README.md): trilhas, scripts, manifestos e dossiês.
- [Dossiês e resultados](docs/estudos/README.md): fotografias de planejamento e
  links para material publicado.
- [Histórico do projeto](docs/historico/README.md): documentos históricos
  preservados fora do caminho de navegação atual.

Os módulos 1–10 usam perfis suportados pela automação de estudante. O M11
híbrido ainda está em validação: o alvo público recusa início antes de efeitos.
Os módulos 12–17 são leitura de resultados históricos; não exigem acesso às
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
| `labctl/` | interface e registros de estudos históricos |

## Como preparar o laboratório próprio

Use Ubuntu 24.04 amd64, uma conta não-root com sudo e a cópia completa de
revisão que contém livros, Makefiles, manifests e `automation/student-lab`.
Instale os pré-requisitos com `sudo apt update && sudo apt install -y git make`.
Depois, siga [Preparar, verificar e encerrar o laboratório próprio](docs/lab-guide-student.md#apêndice-a--preparar-verificar-e-encerrar-o-laboratório-próprio)
ou [E01 do livro iniciante](docs/ebpf-cilium-iniciantes.md#e01--reconhecer-o-ambiente-e-preparar-a-rodada).

Para iniciar um perfil suportado, execute `lab-preflight` e `lab-up`; o primeiro
inspeciona dependências, capacidade e colisões, e o segundo instala o perfil.
Depois, consulte `lab-status` e `lab-verify` e capture `lab-env` para carregar
no shell. Em `plataforma`, `EXERCISE` e `WG` valem somente para preflight/up;
status, verify, env e down recebem apenas `LAB=plataforma` e leem o cenário do
estado persistido. `lab-session` aplica-se somente a `iniciantes`. Capture
`lab-env` na raiz do projeto e use `--no-print-directory` no Make raiz. Para
trocar de perfil ou cenário, encerre o perfil ativo com `lab-down` e confirme
`lab-status` antes do novo preflight/up. Se o perfil permanece ativo, consulte
status/verify e capture env no novo shell sem repetir preflight. O down encerra
somente o ambiente próprio.

## Comandos

Na raiz do repositório, consulte `make -C poc-k8s-fabric help` para os alvos do
kit. Os alvos de documentação e de laboratório têm escopos diferentes:

```bash
make lint
make test
python3 poc-k8s-fabric/tools/build_latex.py \
  --source poc-k8s-fabric/docs/lab-guide-student.md \
  --tex poc-k8s-fabric/docs/latex/lab-guide-student.tex \
  --pdf output/pdf/cilium-lab-student-guide.pdf
python3 poc-k8s-fabric/tools/build_latex.py \
  --source poc-k8s-fabric/docs/ebpf-cilium-iniciantes.md \
  --tex poc-k8s-fabric/docs/latex/ebpf-cilium-iniciantes.tex \
  --pdf output/pdf/ebpf-cilium-iniciantes.pdf
```

`make lint` e `make test` verificam o kit conforme o Makefile. Os PDFs desta
edição dependem dos fontes Markdown e da revisão coerente do builder. O alvo
público híbrido continua guardado e não equivale a uma execução validada.

O [índice de estudos](studies/README.md) aponta para arquivos existentes. O
[registro histórico do laboratório](docs/lab-results.md) conserva medições e
contexto de execução, enquanto os dossiês explicam o escopo de cada estudo.
