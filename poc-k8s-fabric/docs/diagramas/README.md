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
| `05-laboratorio-vm-cilium-quadro-branco-v2.png` | Topologia atual do laboratório inteiro dentro da `vm-cilium`; versão com rodapé corrigido |
| `06-laboratorio-explicado-iniciantes.png` | Explicação visual para iniciantes: pods, rotas, VIP e caminho do tráfego |

Para regenerar depois de mudar o desenho, reexporte a página e substitua os arquivos.

Os dois PNGs acima são usados pelo [guia do estudante](../lab-guide-student.md). Uma versão anterior do quadro permanece apenas como artefato local histórico; o guia usa a variante `-v2`.
