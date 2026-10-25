# Diagramas da PoC

Os diagramas técnicos `01`–`04` foram exportados da página publicada e mantêm
PNG em 2x e SVG standalone. Os quadros didáticos `05` e `06` são imagens
geradas para esta edição do laboratório; o `05` original é preservado como
histórico e o guia usa a variante `-v2` com o rodapé corrigido.

| Arquivo | O que mostra |
|---|---|
| `01-topologia` | Topologia física, ASNs, endereçamento e onde cada sessão BGP vive |
| `02-vip-anycast` | Fan-in do ECMP: quantos next-hops o VIP tem em cada camada |
| `03-evpn-vrf` | O que muda no leaf1 quando o cluster vai para a `ip-vrf k8s` |
| `04-underlay-vs-overlay` | Os dois formatos de pacote e o que o leaf consegue enxergar |
| `05-laboratorio-vm-cilium-quadro-branco-v2.png` | Visão de referência histórica dos ambientes P001–P003 documentados na `vm-cilium`; não é inventário do estado atual; variante com rodapé corrigido |
| `06-laboratorio-explicado-iniciantes.png` | Explicação visual para iniciantes: pods, rotas, VIP e caminho do tráfego |
| `07-mgc-caminhos.svg` / `.png` | Caminhos históricos da réplica MGC: cliente legado e peer EVPN separados |
| `08-p004-estado.svg` / `.png` | Estado final de P004 (`P004-S001` a `P004-S008` concluídas com PASS): `labctl`, MGC (`M01–M03`, `X05`), OVN-K (`K01–K04`), Cruzados (`X01–X07`), Braços Cilium A e B + KubeVirt (`V00–V09`, `H1–H8`, `R6=0`), Síntese `INV × Aberto` (`G07`) e Higiene Final (`G08`) |
| `09-p004-tres-planos-kubevirt.svg` / `.png` | Arquitetura comparada de P004 (`S002–S008`): OVN-Kubernetes + UDN/KubeVirt (`Braço C/D`, `K01–K04`), Fabric EVPN / MGC (`X01–X07`) e Braços Cilium A & B + KubeVirt (`V00–V09`, `FRR 10.7.1`, `R6=0`, `G01/G02/G06/G07`) |

Para regenerar depois de mudar os diagramas técnicos, reexporte a página e
substitua os arquivos. Os diagramas de código `07`, `08` e `09` usam SVG standalone;
gere as imagens PNG de apoio no diretório `docs/diagramas/` com:

~~~bash
rsvg-convert -w 2240 -o 07-mgc-caminhos.png 07-mgc-caminhos.svg
rsvg-convert -w 2240 -o 08-p004-estado.png 08-p004-estado.svg
rsvg-convert -w 2240 -o 09-p004-tres-planos-kubevirt.png 09-p004-tres-planos-kubevirt.svg
~~~

Os PNGs `05` e `06` e os diagramas `07`, `08` e `09` são usados pelo [guia do
estudante](../lab-guide-student.md). As imagens `07`, `08` e `09` mostram resultados
históricos, não disponibilidade atual. Uma versão anterior do quadro permanece
apenas como artefato local histórico; o guia usa a variante `-v2`.
