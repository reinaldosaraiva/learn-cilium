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
| `07-dci-caminhos.svg` / `.png` | Caminhos históricos da réplica DCI: cliente legado e peer EVPN separados |
| `08-p004-estado.svg` / `.png` | Estado final de P004 (`P004-S001` a `P004-S008` concluídas com PASS): `labctl`, DCI (`M01–M03`, `X05`), OVN-K (`K01–K04`), Cruzados (`X01–X07`), Braços Cilium A e B + KubeVirt (`V00–V09`, `H1–H8`, `R6=0`), Síntese `INV × Aberto` (`G07`) e Higiene Final (`G08`) |
| `09-p004-tres-planos-kubevirt.svg` / `.png` | Arquitetura comparada de P004 (`S002–S008`): OVN-Kubernetes + UDN/KubeVirt (`Braço C/D`, `K01–K04`), Fabric EVPN / DCI (`X01–X07`) e Braços Cilium A & B + KubeVirt (`V00–V09`, `FRR 10.7.1`, `R6=0`, `G01/G02/G06/G07`) |
| `m01-whiteboard-entregavel.png` | Quadro-resumo do entregável do Módulo 1: Baseline BGP (`k01`), 3 `PodCIDRs /24`, VIP `/32` e Native Routing sem VXLAN |
| `m02-whiteboard-entregavel.png` | Quadro-resumo do entregável do Módulo 2: VIP Anycast ECMP + eBPF/Maglev (`20/20 HTTP 200`), `ETP=Cluster` vs `ETP=Local` e túnel SSH |
| `m03-whiteboard-entregavel.png` | Quadro-resumo do entregável do Módulo 3: Dual-Stack IPv6 no plano de controle BGP (`/64` + `fd14::a/128`) e fronteira do underlay L3 |
| `m04-whiteboard-entregavel.png` | Quadro-resumo do entregável do Módulo 4: Resiliência a falhas de fabric, BGP Graceful Restart (`0 s` blackhole) e convergência ECMP |
| `m05-whiteboard-entregavel.png` | Quadro-resumo do entregável do Módulo 5: Escala `6 -> 40` pods sem crescer a RIB (`26 = 26`), burst de `+30 VIPs /32` e throughput Native vs VXLAN |
| `m06-whiteboard-entregavel.png` | Quadro-resumo do entregável do Módulo 6: Gateway API (`HTTPRoute :8080`, `TCPRoute :15432`, `UDPRoute :15353`) sobre VIP BGP `10.202.255.10/32` |
| `m07-whiteboard-entregavel.png` | Quadro-resumo do entregável do Módulo 7: `ExternalAuth` HTTP/gRPC (`allow=200`, `deny=403`, `absent=401`) e garantia `100%` Fail-Closed |
| `m08-whiteboard-entregavel.png` | Quadro-resumo do entregável do Módulo 8: Criptografia `WireGuard` (`W0`, `W1`, `W2` em `UDP/51871`) e fronteira do `hostns` no Native Routing |
| `m09-whiteboard-entregavel.png` | Quadro-resumo do entregável do Módulo 9: Isolamento Multi-Tenant (`T01–T17`) em 3 camadas (`CiliumNetworkPolicy`, `ExternalAuth`/`BackendTLSPolicy` e `RBAC`/`PSA`) |
| `m10-whiteboard-entregavel.png` | Quadro-resumo do entregável do Módulo 10: Multi-Pool IPAM (`M24 /24` vs `M32 /32`), BGP Communities e piso de retenção `preAllocate: 8` |
| `m11-whiteboard-entregavel.png` | Quadro-resumo do entregável do Módulo 11: Tenant Híbrido (`Pod K8s <-> VM OpenStack/KVM`) e segurança por identidade (`fromEndpoints`) vs endereço (`fromCIDR`) |
| `m12-whiteboard-entregavel.png` | Quadro-resumo do entregável do Módulo 12: Nós reais na nuvem (`kubeadm` + Cilium + FRR) e impacto do IP Spoofing Guard da NIC da VPC |
| `m13-whiteboard-entregavel.png` | Quadro-resumo do entregável do Módulo 13: Síntese de `P004` (`DCI Connect`, `OVN-Kubernetes + EVPN`, `Cilium A/B + KubeVirt`, `R6=0` e `INV-PoC-01..06`) |
| `m14-whiteboard-entregavel.png` | Quadro-resumo do entregável do Módulo 14: Síntese de `P005` (`16/16 PASS` — Borda eBGP Dedicada `E09–E19` ∥ Datapath eBPF, Hubble e DRA `E17, E21–E25`) |
| `m15-whiteboard-entregavel.png` | Quadro-resumo do entregável do Módulo 15: Síntese de `P006` (`E26–E33` + `C1–C4` — Maglev, BIG TCP, EDT/BBR, Unnumbered, Cluster Mesh, SRv6, Tetragon e Live Migration) |
| `m16-whiteboard-entregavel.png` | Quadro-resumo do entregável do Módulo 16: Síntese de `P007` (`E34–E37` — BGP Graceful Shutdown `0%` loss, SPIFFE mTLS + WireGuard, LRP e Multus `ipvlan L2/L3`) |
| `m17-whiteboard-entregavel.png` | Quadro-resumo do entregável do Módulo 17: Síntese de `P008` (`E38–E41` — Host Firewall + `XDP_DROP`, `CiliumEnvoyConfig` L7, iBGP RR + SRv6 Dual-Stack e Matriz `netkit + BIG TCP + WireGuard 5,59x`) |

Para regenerar depois de mudar os diagramas técnicos, reexporte a página e
substitua os arquivos. Os diagramas de código `07`, `08` e `09` usam SVG standalone;
gere as imagens PNG de apoio no diretório `docs/diagramas/` com:

~~~bash
rsvg-convert -w 2240 -o 07-dci-caminhos.png 07-dci-caminhos.svg
rsvg-convert -w 2240 -o 08-p004-estado.png 08-p004-estado.svg
rsvg-convert -w 2240 -o 09-p004-tres-planos-kubevirt.png 09-p004-tres-planos-kubevirt.svg
~~~

Os PNGs `05` e `06` e os diagramas `07`, `08` e `09` são usados pelo [guia do
estudante](../lab-guide-student.md). As imagens `07`, `08` e `09` mostram resultados
históricos, não disponibilidade atual. Uma versão anterior do quadro permanece
apenas como artefato local histórico; o guia usa a variante `-v2`.
