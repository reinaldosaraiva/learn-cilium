# learn-cilium

Materiais de estudo e laboratório sobre Kubernetes, Cilium, BGP e redes de
datacenter. O guia organiza os exercícios introdutórios e apresenta como leitura
os estudos avançados documentados no repositório.

## Acesso rápido

- [PDF do guia do estudante](output/pdf/cilium-lab-student-guide.pdf)
- [Kit do laboratório](poc-k8s-fabric/README.md) — [Apêndice A](poc-k8s-fabric/docs/lab-guide-student.md#apêndice-a--roteiro-do-instrutor) · [labctl](poc-k8s-fabric/labctl/README.md)
- [Índice dos estudos E01–E41](poc-k8s-fabric/studies/README.md)
- [Histórico do projeto](poc-k8s-fabric/docs/historico/README.md)

## Roteiro

O kit descreve como usar o guia e chegar aos exercícios do laboratório. O
índice separa cada estudo por trilha e aponta aos arquivos versionados e ao
dossiê correspondente. O histórico preserva documentos anteriores para
consulta, sem substituir os índices atuais.

Os módulos introdutórios acompanham atividades do laboratório; os capítulos
avançados servem como leitura dos resultados publicados e de seus limites.

## Verificação e geração

Na raiz do repositório, `make lint` executa as verificações estáticas, `make
test` executa as verificações definidas pelo kit e `make pdf` gera o PDF a
partir do Markdown (requer pandoc e tectonic). Consulte os alvos com `make help`
ou `make -C poc-k8s-fabric help`.

## Organização

- `poc-k8s-fabric/docs/` contém o guia, os dossiês e os diagramas publicados.
- `poc-k8s-fabric/studies/` contém scripts e manifestos associados aos estudos.
- `poc-k8s-fabric/docs/historico/` preserva documentos de evolução do projeto.
- `output/pdf/` recebe o PDF gerado.

O índice de estudos aponta para os arquivos reais de cada trilha. Os dossiês
distinguem resultados medidos, limites e material histórico.
