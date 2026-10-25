# learn-cilium

Um laboratório didático para entender Cilium, Kubernetes e BGP por meio de um
fabric leaf–spine reproduzível. O cenário principal coloca tudo dentro de uma
única `vm-cilium`: Containerlab executa cinco nós SR Linux, FRR faz a borda,
`client-ext` gera tráfego e um cluster kind de três nós executa o Cilium e os
pods de teste.

![Topologia do laboratório dentro da vm-cilium](poc-k8s-fabric/docs/diagramas/05-laboratorio-vm-cilium-quadro-branco-v2.png)

![Explicação visual para iniciantes](poc-k8s-fabric/docs/diagramas/06-laboratorio-explicado-iniciantes.png)

O laboratório responde duas perguntas simples:

- como um nó Cilium anuncia seu PodCIDR agregado por BGP;
- como um Service LoadBalancer recebe um VIP `/32` e pode ser alcançado por
  múltiplos caminhos ECMP.

O [guia do estudante 2.3](poc-k8s-fabric/docs/lab-guide-student.md) organiza os
módulos 1–11 como exercícios guiados apoiados nos estudos P001–P003. O módulo
12 é leitura histórica do estudo com nós reais na nuvem, cuja infraestrutura
fica fora da aula; o módulo 13 sintetiza os resultados empíricos completos da trilha P004
(sessões S001–S008 concluídas com **PASS**):
- **13.1** — Réplica MGC/OVN/FRR (`M01–M03`), CIDRs sobrepostos em EVPN Type 5 (`X05`) e capacidade (`S001–S002`);
- **13.2** — OVN-Kubernetes `v1.4.0` + KubeVirt `v1.9.0` (`K01–K04`) e cenários híbridos (`X01–X04`, `X06`, `X07` em `S003–S004`);
- **13.3** — Braço Cilium A: Cilium `1.20.2` + KubeVirt `v1.9.0` no `p003-gw` (`C01–C06` / `V00–V06`: `CiliumEndpoint`, VIP BGP `/32`, `CiliumNetworkPolicy` por label, Gate `G01` de reuso de IP `10.253.0.100/32` vs identidade, live migration com mudança de podIP e Multi-Pool `/32` BGP em `S005`);
- **13.4** — Negativos do Braço Cilium A (`V07-A`, `V08-A`, `C-neg` / `G02`), Braço Cilium B (`FRR 10.7.1` no nó sob `R6=0`, `H6`/`G06`, EVPN Type 5 `V09`/`H7`, `V07-B`, `V08-B`), blueprint de transição para a Fase 2 (`Braços C/D`), síntese `INV × equivalente aberto` (`G07`: critérios `INV-PoC-01` a `INV-PoC-06`) e higiene final dos laboratórios (`G08`, em `S006–S008`).

Os
[diagramas](poc-k8s-fabric/docs/diagramas/README.md) mostram a topologia, o
quadro de conclusão de P004 e a comparação visual dos planos de rede para VMs.
O [resumo de resultados](poc-k8s-fabric/docs/lab-results.md) e o
[CHANGELOG](CHANGELOG.md) registram as entregas por versão; veja também a
[síntese pública completa de P004](poc-k8s-fabric/docs/estudos/20-mgc-estado-parcial.md).

O [índice de estudos P003](poc-k8s-fabric/docs/estudos/README.md) conserva o
planejamento, as matrizes e o processo. Os resultados publicados incluem a
[E08](poc-k8s-fabric/docs/estudos/08-lifecycle-synthesis.md), o [caso
C5](poc-k8s-fabric/docs/estudos/09-vm-outside-container.md) e os demais
achados resumidos no guia.

## Começar

O checkout é portátil:

~~~bash
git clone https://github.com/reinaldosaraiva/learn-cilium.git
cd learn-cilium
~~~

Para gerar o PDF do guia em um ambiente limpo:

~~~bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r poc-k8s-fabric/tools/requirements-guide.txt
python3 poc-k8s-fabric/tools/build_guide.py
~~~

O resultado fica em [cilium-lab-student-guide.pdf](output/pdf/cilium-lab-student-guide.pdf). O builder aceita `--source`,
`--output` e `--scaffold`; imagens Markdown são resolvidas em relação ao
diretório do documento e uma imagem ausente interrompe a geração com erro claro.

O laboratório em execução é responsabilidade do instrutor. A [documentação do
kit](poc-k8s-fabric/README.md) contém topologia, scripts e configurações
publicáveis; a reconstrução destrutiva e a integração com ambientes gerenciados
ficam fora dos exercícios básicos.

## O que este lab demonstra

O cenário usa native routing, Cilium BGP Control Plane, um PodCIDR `/24` por nó
e o VIP `10.201.255.10/32` para um Service `externalTrafficPolicy: Cluster`.
Ele ensina a separar anúncio de rota, seleção ECMP e encaminhamento do datapath.
Não é uma promessa de desempenho de hardware, alta disponibilidade de produção,
round-robin perfeito ou isolamento de tenant equivalente a uma rede virtual
completa.

A trilha seguinte, orientada pelos requisitos de um produto de conexão
dedicada com eBGP (BFD, autenticação de sessão, limite de prefixos,
communities, redundância entre dois equipamentos, VRF por tenant e
observabilidade por conexão), está em [próximos
estudos](poc-k8s-fabric/docs/proximos-estudos.md).
