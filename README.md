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

O [guia do estudante](poc-k8s-fabric/docs/lab-guide-student.md) explica os
locais dos comandos, os exercícios somente leitura e o túnel SSH local. Os
[diagramas](poc-k8s-fabric/docs/diagramas/README.md) mostram a topologia e o
caminho do tráfego. O [resumo de resultados](poc-k8s-fabric/docs/lab-results.md)
separa a reconstrução atual de medições históricas.

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

As propostas de estudo seguintes cobrem `/24` versus blocos `/32` e um tenant
híbrido com pods Kubernetes e VMs OpenStack: [próximos
estudos](poc-k8s-fabric/docs/proximos-estudos.md).
