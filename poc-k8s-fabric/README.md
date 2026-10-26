# Kit do laboratório Cilium + BGP

Este diretório reúne materiais para os exercícios guiados dos módulos 1–11 do
[guia do estudante 2.4](docs/lab-guide-student.md), baseados nos ambientes
documentados em P001–P003. O módulo 12 é leitura histórica do estudo com nós
reais na nuvem; essa infraestrutura fica fora da aula. O módulo 13 sintetiza os
resultados empíricos completos da trilha P004 (sessões S001–S008 concluídas com **PASS**:
réplica MGC/OVN/FRR `M01–M03` + `X05`, OVN-Kubernetes + KubeVirt `K01–K04`,
cenários híbridos `X01–X07`, Braço Cilium A `V00–V08-A` / `C-neg`, Braço Cilium B
`FRR 10.7.1` no nó `H6` / `V09` / `V07-B` / `V08-B` com `R6=0`, blueprint OVN-K `C/D` e
síntese `INV × equivalente aberto` `G07`/`G08`;
os perfis `labctl/labs/` e os artefatos de `studies/p004/` acompanham o checkout
como referência de instrutor). O módulo 14 sintetiza os 16 estudos avançados da trilha P005
(`P005-S001` a `P005-S004`, concluídos com **PASS** em `v2.4.0`, com scripts reproduzíveis em `studies/p005/`).

O objetivo didático começa por
observar um cluster Kubernetes kind ligado a um fabric leaf–spine e entender a
diferença entre o PodCIDR que o Cilium anuncia e a VIP `/32` de um Service; os
módulos seguintes cobrem Gateway API, autorização, criptografia, tenants, IPAM
e o tenant híbrido com VMs OpenStack, executados no sandbox `studies/p003/`.

![Topologia inteira dentro da vm-cilium](docs/diagramas/05-laboratorio-vm-cilium-quadro-branco-v2.png)

![Explicação visual para iniciantes](docs/diagramas/06-laboratorio-explicado-iniciantes.png)

## Ambiente de referência

Tudo roda dentro de uma única `vm-cilium` Linux:

- Containerlab: dois spines e três leaves SR Linux `25.3.2`;
- `border1`: FRR `8.4.1`, ligado ao `client-ext`;
- kind `k01`: Kubernetes `v1.35.0`, três nós;
- Cilium `1.20.1`, native routing, BGP Control Plane e IPv6 no plano de controle;
- seis réplicas `echo` e VIP IPv4 `10.201.255.10`;
- enlaces spine–leaf numerados em IPv4 `/31`.

O `client-ext` é externo ao cluster Kubernetes, mas está dentro da VM. O
computador da pessoa estudante acessa a VIP pelo túnel SSH local descrito no
guia. O caminho MKE/gerenciado é uma investigação separada e não é requisito
para este laboratório.

## Estrutura

| Caminho | Conteúdo |
|---|---|
| `topo/` | topologia Containerlab `poc-kind.clab.yml` e cluster kind |
| `configs/srl/` | configurações dos spines e leaves SR Linux |
| `configs/frr/` | daemon e configuração do `border1` |
| `k8s/cilium/` | values do Helm para native routing e dual-stack |
| `k8s/bgp/` | peers, anúncios, racks e pool de VIPs |
| `k8s/apps/` | deployment `echo`, Services e `netshoot` |
| `scripts/` | preparação, deploy, Cilium, BGP, validação e exposição opcional |
| `docs/diagramas/` | imagens da topologia e do fluxo para a aula |

O builder do PDF fica em [`tools/build_guide.py`](tools/build_guide.py), no
diretório `poc-k8s-fabric/tools`, mas é executado a partir da raiz do projeto:

~~~bash
python3 poc-k8s-fabric/tools/build_guide.py
~~~

O PDF sai em `output/pdf/cilium-lab-student-guide.pdf`. Para usar uma cópia do
molde:

~~~bash
python3 poc-k8s-fabric/tools/build_guide.py \
  --scaffold /tmp/meu-guia.md \
  --title "Meu laboratório Cilium"
~~~

O builder depende somente de ReportLab. Consulte
[`tools/requirements-guide.txt`](tools/requirements-guide.txt) se precisar
preparar um ambiente virtual.

## Modelo de anúncios

Cada agente Cilium mantém sua sessão BGP com o leaf do rack e anuncia o
PodCIDR IPv4 `/24` do próprio nó. O Service `echo-anycast`, com
`externalTrafficPolicy: Cluster`, é anunciado como `10.201.255.10/32` por
todos os três nós elegíveis. BGP troca prefixos; ele não executa HTTP nem
instala automaticamente no kernel dos nós as rotas que aprende.

## Estado operacional

O guia pressupõe que o laboratório já esteja no ar. A reconstrução é um
apêndice de instrutor e requer dois terminais: o deploy da topologia aguarda a
API kind, enquanto o kubeconfig dedicado é exportado e o Cilium é instalado no
segundo terminal. Não trate `scripts/99-destroy.sh` como exercício de aluno.

Veja o [resumo público dos resultados](docs/lab-results.md) e as propostas de
[próximos estudos](docs/proximos-estudos.md), agora orientadas aos requisitos
de um produto de conexão dedicada com eBGP. A comparação `/24` × `/32` e o
tenant híbrido com VMs OpenStack já foram executados e estão no guia.

O [índice público dos estudos P003](docs/estudos/README.md) reúne planejamento,
pesquisa, contrato, protocolo e dossiês. A trilha P003 foi encerrada em
25/09/2026; seus resultados estão resumidos no guia e nas sínteses publicadas
da [E08](docs/estudos/08-lifecycle-synthesis.md) e do [caso
C5](docs/estudos/09-vm-outside-container.md). O modelo S002 de preflight é
somente documental e não descreve o estado atual de uma VM. P004 é uma trilha
separada: o `labctl` comum foi validado em S001, a réplica MGC/OVN+FRR fechou
com **PASS** em S002 (23/10/2026, com M01–M03 e X05 aceitos e perfil `labctl mgc`
publicado), o braço OVN-Kubernetes + KubeVirt + EVPN fechou com **PASS** em
S003 (23/10/2026, com perfis `labctl evpn-fabric` e `labctl ovnk` e matriz
`K01–K04` em `studies/p004/evpn-fabric/` e `studies/p004/ovnk/`), os casos
cruzados (`X01–X04`, `X06`, `X07`) fecharam com **PASS** em S004 (24/10/2026,
em `studies/p004/cases/`), e o braço Cilium A (`1.20.2` + KubeVirt `v1.9.0` no
`p003-gw`, casos `C01–C06` / `V00–V06`) fechou com **PASS** em S005 (24/10/2026,
em `studies/p004/cilium-a/`). Em S006 e S007 (**PASS**), foram provados os
negativos e limites estruturais do Braço Cilium A (`V07-A`, `V08-A`, `C-neg` / `G02`)
e o Braço Cilium B completo com `FRR 10.7.1` no nó sob o invariante `R6=0`
(`H6`/`G06`, `V09`/`H7` EVPN Type 5, `V07-B` e `V08-B`, em `studies/p004/cilium-b/`),
além do blueprint de transição para o Braço OVN-Kubernetes (`C/D`). Em S008 (**PASS**),
fecharam-se a síntese `INV × equivalente aberto` com os seis critérios de aceite
para uma PoC comercial do INV (`G07`) e a higiene final dos laboratórios (`G08`).
Consulte a [síntese pública completa de P004](docs/estudos/20-mgc-estado-parcial.md)
e os oito dossiês publicados da trilha **P005** (`P005-S001` a `P005-S004`, todos concluídos com **PASS** em `v2.4.0`:
[Onda 1 Braço A `E19`+`E09`](docs/estudos/19-bgp-idempotency-md5-asn32.md),
[Onda 1 Braço B `E23`+`E21`](docs/estudos/21-netkit-vs-veth-ipam-burst.md),
[Onda 2 Braço A `E11`+`E12`+`E10`](docs/estudos/11-bgp-maxprefix-communities-bfd.md),
[Onda 2 Braço B `E22`](docs/estudos/22-xlb-ebpf-socket-lb-vs-envoy.md),
[Onda 3 Braço A `E13`+`E14`](docs/estudos/13-bgp-dual-border-gr-ipv6.md),
[Onda 3 Braço B `E17`+`E25`](docs/estudos/17-bgp-hubble-observability.md),
[Onda 4 Braço A `E15`+`E16`+`E18`](docs/estudos/15-bgp-vrf-return-paths-l2-mtu-qinq-macsec.md) e
[Onda 4 Braço B `E24`](docs/estudos/24-cilium-dra-network-device.md), com scripts em `studies/p005/`), bem como a trilha **P006** ([Onda 1 `E26`+`E30`+`Bloco C1`](docs/estudos/26-lb-xdp-dsr-maglev-clustermesh.md), com scripts em `studies/p006/`).
