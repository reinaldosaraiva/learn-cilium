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

O [guia do estudante 2.7](poc-k8s-fabric/docs/lab-guide-student.md) organiza os
módulos 1–11 como exercícios guiados apoiados nos estudos P001–P003. O módulo
12 é leitura histórica do estudo com nós reais na nuvem, cuja infraestrutura
fica fora da aula; o módulo 13 sintetiza os resultados empíricos completos da trilha P004
(sessões S001–S008 concluídas com **PASS**):
- **13.1** — Réplica DCI/OVN/FRR (`M01–M03`), CIDRs sobrepostos em EVPN Type 5 (`X05`) e capacidade (`S001–S002`);
- **13.2** — OVN-Kubernetes `v1.4.0` + KubeVirt `v1.9.0` (`K01–K04`) e cenários híbridos (`X01–X04`, `X06`, `X07` em `S003–S004`);
- **13.3** — Braço Cilium A: Cilium `1.20.2` + KubeVirt `v1.9.0` no `p003-gw` (`C01–C06` / `V00–V06`: `CiliumEndpoint`, VIP BGP `/32`, `CiliumNetworkPolicy` por label, Gate `G01` de reuso de IP `10.253.0.100/32` vs identidade, live migration com mudança de podIP e Multi-Pool `/32` BGP em `S005`);
- **13.4** — Negativos do Braço Cilium A (`V07-A`, `V08-A`, `C-neg` / `G02`), Braço Cilium B (`FRR 10.7.1` no nó sob `R6=0`, `H6`/`G06`, EVPN Type 5 `V09`/`H7`, `V07-B`, `V08-B`), blueprint de transição para a Fase 2 (`Braços C/D`), síntese `INV × equivalente aberto` (`G07`: critérios `INV-PoC-01` a `INV-PoC-06`) e higiene final dos laboratórios (`G08`, em `S006–S008`).

O módulo 14 consolida os **16 estudos avançados da trilha P005** (`P005-S001` a `P005-S004`, todos concluídos com **PASS** em `v2.4.0`):
- **14.1** — Onda 1 (`P005-S001`): Idempotência BGP `10x` e reuso de VIP (`E19`), TCP MD5 RFC 2385 + ASN de 32 bits `4200000001` (`E09`), `netkit` vs `veth` (`E23`) e Burst IPAM com Warm Pool (`E21`);
- **14.2** — Onda 2 (`P005-S002`): Limite de prefixos `maximum-prefix 100` e filtro de import (`E11`), Communities `65400:100/200` + `AS-path prepend` + `MED` (`E12`), BFD sub-segundo `< 1 s` (`E10`) e XLB L7 eBPF (`sockmap`/`sk_msg`) vs `SocketLB L4` e `Envoy L7` (`E22`);
- **14.3** — Onda 3 (`P005-S003`): Redundância Dual-Border ECMP + failover com/sem Graceful Restart (`E13`), sessão eBGP IPv6 dedicada servindo `fd14::a/128` (`E14`), e observabilidade contínua BGP por 3 leituras consecutivas (`E17`) + Hubble `L3/L4`, `L7 HTTP/DNS`, `TLS :8443` e Prometheus (`E25`);
- **14.4** — Onda 4 (`P005-S004`): Isolamento de VRF por tenant via BGP community (`E15`), 3 modos de retorno PE/CE + `CiliumEgressGatewayPolicy` (`E16`), enlace L2 (`MTU 9000` Jumbo, `QinQ 802.1ad` e `MACsec 802.1AE` vs `WireGuard`, `E18`) e Dynamic Resource Allocation (`resource.k8s.io/v1` `NetworkDeviceData`, `E24`).

O módulo 15 consolida os **8 estudos avançados de Fase 2 e o saneamento integral da trilha P006** (`P006-S001` a `P006-S004`, todos concluídos com **PASS** em `v2.5.0`, fechando `33/33` estudos `E01–E33` e `100%` de [`revisao-projeto-2026-09-26.md`](poc-k8s-fabric/docs/revisao-projeto-2026-09-26.md)):
- **15.1** — Onda 1 (`P006-S001`): LoadBalancer TCX/XDP + DSR (`ETP=Local`) & Maglev Consistent Hashing (`M=16381`, `E26`), Cilium Cluster Mesh / MCS-API sobre BGP (`E30`) e Saneamento `Bloco C1` (`A4–A8`, `A10–A12`);
- **15.2** — Onda 2 (`P006-S002`): BIG TCP (`gso_max_size=196608`, super-pacotes `188 KiB`) + `netkit` + Jumbo MTU 9000 (`E27`), SRv6 L3VPN (`seg6local action End.DT4`) sem VXLAN (`E31`) e Saneamento `Bloco C2` (`A1–A3`, `A9`, `M1–M6`);
- **15.3** — Onda 3 (`P006-S003`): Bandwidth Manager (`EDT` + `qdisc fq`), Pacing eBPF por Pod & `TCP BBR` vs `CUBIC` (`E28`), Tetragon Runtime eBPF Security (`TracingPolicyNamespaced`, `E32`) e Saneamento `Bloco C3` (`M7–M15`);
- **15.4** — Onda 4 (`P006-S004`): BGP Unnumbered (`RFC 5549`/`8950` Extended Next-Hop) & L2 Announcements (`CiliumL2AnnouncementPolicy`, `E29`), KubeVirt Live Migration sob Tráfego Contínuo (`Cilium B /32 BGP` `100,45 ms` vs `OVN-K EVPN Type-2` `60,25 ms`, `E33`) e Saneamento `Bloco C4` (`Makefile` `make lint`/`test`/`pdf`, índices `s011/s012` e fechamento `100%`).

O módulo 16 consolida os **4 estudos avançados de Fase 3 da trilha P007** (`P007-S001` e `P007-S002`, todos concluídos com **PASS** em `v2.6.0`, fechando `37/37` estudos entre `E01` e `E37`):
- **16.1** — Onda 1 (`P007-S001`): BGP Graceful Shutdown (`RFC 8326` community `65535:0`, `LOCAL_PREF=0` e dreno zero-loss `0/150` pacotes perdidos vs `8/150` / `662,15 ms` no dreno abrupto, `E34`) e Cilium Mutual Authentication (`SPIFFE` X.509 SVID mTLS `spiffe://spiffe.cilium/ns/p007-e35/sa/...` + `CiliumNetworkPolicy` + `cilium_wg0` WireGuard `:51871` com `0` vazamentos em texto claro, `E35`);
- **16.2** — Onda 2 (`P007-S002`): Cilium Local Redirect Policy (`CiliumLocalRedirectPolicy` `serviceMatcher` `[LocalRedirect]` `20/20` local + `addressMatcher` `169.254.20.10:8080/TCP` Node-Local Cache Bypass, `E36`) e Workloads Dual-Homed com Multus (`NetworkAttachmentDefinition`) + `ipvlan L2/L3` vs `macvlan` (`MTU 9000`, `ipvlan-l3` `36,76 Gbps` `+11,4%` vs `veth 1500` e bypass de Cloud L2 MAC Anti-Spoofing `tc flower` onde `macvlan` cai em `0/5`, `E37`).

O módulo 17 consolida os **4 estudos avançados de Fase 4 da trilha P008** (`P008-S001` e `P008-S002`, todos concluídos com **PASS** em `v2.7.0`, fechando **`41/41` estudos totais do repositório entre `E01` e `E41`**):
- **17.1** — Onda 1 (`P008-S001`): Cilium Host Firewall (`enable-host-firewall=true` + `CiliumClusterwideNetworkPolicy` `nodeSelector` bloqueando `0/5` em `:19100` e preservando `:10250` `10/10` anti-lockout) & XDP Early DDoS Prefilter (`BPF_PROG_TYPE_XDP` `e38_xdp_prog` JIT `101 B` descartando `200/200` SYN flood em `XDP_DROP` com `conntrack_flood_entries=0`, `E38`), e `CiliumEnvoyConfig` (`cilium.io/v2`) L7 Traffic Management & Resilience (`cilium-envoy 1.37.6`: Weighted Canary `90/10` -> `v1=86, v2=14`, Header `X-Canary: true` -> `10/10` `v2`, Token-Bucket Local Rate Limit `5/15` `200 OK` + `10/15` `429` e Automatic Retries `retry_on: 5xx` recuperando `50%` `503` de `5/10` para `10/10` HTTP `200`, `E39`);
- **17.2** — Onda 2 (`P008-S002`): Escalabilidade iBGP Route Reflector (`RFC 4456` `cluster-id 10.255.40.1`, `Originator: 10.208.40.2`, `direct_w1_w2=0`, `10/10` IPv4/IPv6) & SRv6 L3VPN Dual-Stack (`seg6local action End.DT4` + `End.DT6` sem VXLAN isolando CIDRs `10.253.40.0/24` + `fd40:253:40::/64` 100% sobrepostos com `10/10` HTTP `200` v4/v6 e revogação seletiva `End.DT6` `0/5` preservando `End.DT4` `10/10`, `E40`), e Matriz 2×2 de Sinergia no Datapath (`veth MTU 1500` vs `netkit L3 MTU 9000 + BIG TCP 192 KiB` × `Cleartext` vs `WireGuard cilium_wg0 MTU 8920`, elevando o throughput WireGuard de `1,56 Gbps` em `R2` para **`8,72 Gbps` em `R4` (`+459,0%` / `5,59x`)** com **`-84,5%` invocações ChaCha20-Poly1305**, `E41`).

Os
[diagramas](poc-k8s-fabric/docs/diagramas/README.md) mostram a topologia, o
quadro de conclusão de P004 e a comparação visual dos planos de rede para VMs.
O [resumo de resultados](poc-k8s-fabric/docs/lab-results.md) e o
[CHANGELOG](CHANGELOG.md) registram as entregas por versão; veja também a
[síntese pública completa de P004](poc-k8s-fabric/docs/estudos/20-dci-estado-parcial.md).

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

Para gerar o PDF do guia em um ambiente limpo e rodar a suíte de lint/testes (`v2.7.0`):

~~~bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r poc-k8s-fabric/tools/requirements-guide.txt
make pdf
make lint
make test
~~~

O resultado fica em [cilium-lab-student-guide.pdf](output/pdf/cilium-lab-student-guide.pdf). O builder (`poc-k8s-fabric/tools/build_guide.py`) também aceita `--source`,
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

As trilhas seguintes (**P005**, **P006**, **P007** e **P008**), orientadas pelos requisitos de um produto de conexão
dedicada com eBGP (BFD, autenticação de sessão, limite de prefixos,
communities, redundância entre dois equipamentos, VRF por tenant, modos de retorno PE/CE,
MTU 9000/QinQ/MACsec, BGP Unnumbered `RFC 5549`/`8950`, L2 Announcements, BGP Graceful Shutdown `RFC 8326` `65535:0`, iBGP Route Reflector `RFC 4456` e observabilidade por conexão) em paralelo com estudos avançados de datapath eBPF, XDP, Envoy L7, multi-cluster, SRv6 Dual-Stack, runtime security, Zero-Trust mTLS e virtualização
(`netkit` vs `veth`, escala de burst IPAM, XLB L7 eBPF, DRA `resource.k8s.io/v1`, Hubble, LoadBalancer TCX/XDP + Maglev, Cilium Cluster Mesh, BIG TCP, SRv6 L3VPN `End.DT4`/`End.DT6`, Bandwidth Manager EDT + BBR, Tetragon `TracingPolicyNamespaced`, KubeVirt Live Migration sob tráfego contínuo, SPIFFE mTLS + WireGuard `cilium_wg0`, `CiliumLocalRedirectPolicy`, Multus + `ipvlan L2/L3` vs `macvlan` com `MTU 9000`, Cilium Host Firewall + XDP Early DDoS Prefilter, `CiliumEnvoyConfig` L7 Resilience e Matriz 2×2 `netkit` + BIG TCP + `WireGuard`),
estão em [próximos estudos](poc-k8s-fabric/docs/proximos-estudos.md). Todas as **4 Ondas de `P005` (`P005-S001` a `P005-S004`), 4 Ondas de `P006` (`P006-S001` a `P006-S004`), 2 Ondas de `P007` (`P007-S001` e `P007-S002`) e 2 Ondas de `P008` (`P008-S001` e `P008-S002`, somando `41/41` estudos `E01–E41` e `100%` de saneamento do repositório)**
encontram-se **concluídas com PASS (`v2.7.0`)** e documentadas em:
- [19 — Ciclo de Vida e Idempotência BGP (`E19`) & Sessão eBGP Autenticada TCP MD5 com ASN 32 bits (`E09`)](poc-k8s-fabric/docs/estudos/19-bgp-idempotency-md5-asn32.md)
- [21 — `netkit` vs `veth` no Datapath eBPF (`E23`) & Escala de Burst IPAM com Warm Pool (`E21`)](poc-k8s-fabric/docs/estudos/21-netkit-vs-veth-ipam-burst.md)
- [11 — Limite de Prefixos (`E11`), Communities/Prepend/MED (`E12`) & Detecção de Falha com BFD `< 1 s` (`E10`)](poc-k8s-fabric/docs/estudos/11-bgp-maxprefix-communities-bfd.md)
- [22 — XLB: Balanceamento L7 eBPF na Camada de Sockets (`sockmap`/`sk_msg`) vs `SocketLB L4` e `Envoy L7` (`E22`)](poc-k8s-fabric/docs/estudos/22-xlb-ebpf-socket-lb-vs-envoy.md)
- [13 — Redundância Dual-Border, Failover Controlado com/sem Graceful Restart (`E13`) & Sessão eBGP IPv6 Nativa Fim a Fim (`E14`)](poc-k8s-fabric/docs/estudos/13-bgp-dual-border-gr-ipv6.md)
- [17 — Observabilidade Contínua BGP (`ACTIVE`/`DOWN`/`UNKNOWN` por 3 Leituras, `E17`) & Microsserviços com Hubble (`L3/L4`, `L7 HTTP/DNS`, `TLS` e Prometheus, `E25`)](poc-k8s-fabric/docs/estudos/17-bgp-hubble-observability.md)
- [15 — Isolamento de VRF por Tenant via BGP Community (`E15`), 3 Modos de Retorno PE/CE & `CiliumEgressGatewayPolicy` (`E16`) e Enlace L2: MTU 9000 Jumbo, QinQ `802.1ad` & MACsec `802.1AE` vs WireGuard (`E18`)](poc-k8s-fabric/docs/estudos/15-bgp-vrf-return-paths-l2-mtu-qinq-macsec.md)
- [24 — Dynamic Resource Allocation (DRA `resource.k8s.io/v1`) para Dispositivos de Rede no Cilium (`NetworkDeviceData`, `E24`)](poc-k8s-fabric/docs/estudos/24-cilium-dra-network-device.md)
- [26 — LoadBalancer XDP/TCX + DSR & Maglev Consistent Hashing (`E26`) e Cilium Cluster Mesh / MCS-API sobre Fabric BGP (`E30`) (`P006-S001`)](poc-k8s-fabric/docs/estudos/26-lb-xdp-dsr-maglev-clustermesh.md)
- [27 — BIG TCP (`enable-ipv4-big-tcp` / `enable-ipv6-big-tcp`) + `netkit` + Jumbo MTU 9000 (`E27`) e SRv6 L3VPN (`seg6local End.DT4`) sem VXLAN (`E31`) (`P006-S002`)](poc-k8s-fabric/docs/estudos/27-big-tcp-netkit-srv6-l3vpn.md)
- [28 — Bandwidth Manager (EDT + `fq`), Pacing eBPF por Pod & `TCP BBR` vs `CUBIC` (`E28`) e Tetragon Runtime eBPF Security (`TracingPolicyNamespaced`, `E32`) (`P006-S003`)](poc-k8s-fabric/docs/estudos/28-bandwidth-edt-bbr-tetragon.md)
- [29 — BGP Unnumbered (`RFC 5549`/`8950` Extended Next-Hop) & L2 Announcements (`E29`) e KubeVirt Live Migration sob Tráfego Contínuo (`Cilium B /32 BGP` vs `OVN-K EVPN Type-2`, `E33`) (`P006-S004`)](poc-k8s-fabric/docs/estudos/29-bgp-unnumbered-l2-live-migration.md)
- [30 — BGP Graceful Shutdown (`RFC 8326` `65535:0`) & Dreno Zero-Loss de Nó K8s (`E34`) e Cilium Mutual Authentication (`SPIFFE` X.509 mTLS) + `WireGuard` (`E35`) (`P007-S001`)](poc-k8s-fabric/docs/estudos/30-bgp-gshut-spiffe-mtls-wireguard.md)
- [31 — Cilium Local Redirect Policy (`CiliumLocalRedirectPolicy` Node-Local Bypass, `E36`) e Workloads Dual-Homed com Multus + `ipvlan L2/L3` vs `macvlan` (`MTU 9000` & Cloud L2 Anti-Spoofing, `E37`) (`P007-S002`)](poc-k8s-fabric/docs/estudos/31-local-redirect-multus-ipvlan-dualhomed.md)
- [32 — Cilium Host Firewall (`CiliumClusterwideNetworkPolicy`) & XDP Early DDoS Prefilter (`E38`) e `CiliumEnvoyConfig` L7 Traffic Management & Resilience (`E39`) (`P008-S001`)](poc-k8s-fabric/docs/estudos/32-host-firewall-xdp-envoy-l7-resilience.md)
- [33 — Escalabilidade iBGP Route Reflector (`RFC 4456`) & SRv6 L3VPN Dual-Stack (`End.DT4` + `End.DT6`, `E40`) e Matriz 2×2 `netkit` + BIG TCP + `WireGuard` (`E41`) (`P008-S002`)](poc-k8s-fabric/docs/estudos/33-bgp-rr-srv6-dualstack-netkit-wg-matrix.md)
