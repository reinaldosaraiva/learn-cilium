# Resultados públicos do laboratório

Este resumo separa a reconstrução datada de 19/09/2026 dos resultados históricos de outros cenários. Ele dá contexto ao guia sem expor evidência privada nem afirmar o estado atual da VM.

## Estado observado na reconstrução de 19/09/2026

Em 19 de setembro de 2026, o laboratório `poc-kind.clab.yml` foi reconstruído dentro de uma única `vm-cilium`:

| Verificação | Observação |
|---|---|
| Topologia | cinco SR Linux `25.3.2`, `border1` FRR `8.4.1`, `client-ext` e três nós kind |
| Cluster | `k01`, Kubernetes `v1.35.0`, três nós `Ready` |
| Cilium | `1.20.1`, agents saudáveis nos três nós |
| Aplicação | seis réplicas `echo`, todas prontas |
| BGP Cilium | três sessões IPv4/IPv6 estabelecidas |
| VIP | `10.201.255.10/32`, ativa no spine com dois próximos saltos ECMP observados |
| Acesso interno | `client-ext` alcançou a VIP por HTTP |
| Acesso pelo computador | túnel SSH local em `127.0.0.1:18081` respondeu `10/10` vezes com HTTP 200 |
| Backends no túnel | cinco hostnames distintos apareceram nas dez respostas |
| Escopo | o laboratório ficou no ar; nenhum cluster MKE foi usado nessa validação |

O `client-ext` é externo ao cluster Kubernetes, mas fica dentro da mesma VM. O túnel SSH termina no host da VM e encaminha a porta local para a VIP; ele não publica a VIP na Internet.

## Resultados históricos do kit

Em uma rodada de escala anterior, o deployment `echo` foi ampliado de seis para quarenta pods. Os PodCIDRs por nó continuaram agregados e a tabela do fabric não cresceu na mesma proporção que a quantidade de pods. Essa é a observação que motiva o exercício `/24` versus `/32`; ela não transforma quarenta pods em quarenta anúncios independentes.

Também foi observado native routing com o IP real do pod no tráfego do fabric e ausência de UDP/8472 nessa variante. A variante IPv6 provou o plano de controle e rotas internas, mas o alcance da VIP IPv6 a partir do `client-ext` permaneceu limitado pelo underlay externo IPv4. Os números de throughput do laboratório em containers não são uma previsão de hardware de produção.

## P004 — resultados completos de S001 a S008 (PASS)

O ciclo comum do `labctl` foi aprovado em 27/09/2026 (`P004-S001`). Na réplica
MGC (`P004-S002`, **PASS** em 23/10/2026), no plano OVN-Kubernetes + UDN/EVPN +
KubeVirt (`P004-S003`, **PASS** em 23/10/2026), nos casos cruzados entre planos
(`P004-S004`, **PASS** em 24/10/2026), no Braço Cilium A (`P004-S005` e
`P004-S006`, **PASS** em 24/10/2026), no Braço Cilium B (`P004-S006` e
consolidação `P004-S007`, **PASS** em 24–25/10/2026) e na síntese final `INV × Aberto` e higiene dos laboratórios (`P004-S008`, **PASS** em 25/10/2026), os ensaios abaixo foram aceitos com
escopo e limites explícitos:

### 1. Plano MGC Connect (`P004-S002` — OVN 26.03.3 + FRR multi-VRF)

| Caso | Estado documentado | Resultado e limite |
|---|---|---|
| M01 — sessão, ECMP e falhas | PASS com exceção (29/09) | Os daemons FRR foram parados dentro do gateway, sem container FRR dedicado; as versões medidas também diferiram das planejadas. A falha do chassis `ovn-chassis-1` não foi testada; esse host hospedava a fixture da VM fake e era distinto do plano central OVN. |
| M02 — MTU/PMTU | PASS sob o escopo aceito (29/09) | Com MTU 1500, pacotes pequenos passaram 30/30 e o jumbo IPv4 9000 B/DF não recebeu resposta em 30 tentativas (0/30); houve ICMP Frag Needed. Com MTU 9000, ambos passaram 30/30; as MTUs foram restauradas a 1500. A reprodução literal do fragmento no tap físico permaneceu parcial. |
| M03 — EVPN Type 5 | PASS com controle causal (29/09) | O peer externo recebeu `192.168.100.0/24` no VNI `50100`; o positivo respondeu 30/30. O override `dynamic-routing-redistribute=static` na LRP tenant filtrou anúncios de rotas `connected`, sem mudar a origem da rota. Isso retirou a rota-alvo do SB, a rota tenant, o Type 5 e a FIB, e o ping teve 0/3 respostas; BGP, VTEP e duas rotas colaterais permaneceram. Restaurar a chave ao estado ausente recuperou o caminho e o ping respondeu 3/3. Controle negativo literal do VNI: NOT_RUN. |
| X05 — CIDRs sobrepostos (MGC) | **PASS** (23/10/2026) | Dois tenants com `192.168.100.0/24` e `169.254.254.0/30` sobrepostos em `ovnvrf100` (VNI `50100`) e `ovnvrf50200` (VNI `50200`, RT `65000:50200`): alcance intra-tenant 30/30 nos dois domínios, 0/3 nas quatro direções cross-tenant com 0 pacotes capturados no destino (`tcpdump`) e rollback canônico (`G7+G8`) com 0 resíduos (`run c9d0e1` + prova negativa `b8c9d0`). Exige alinhamento do `Router MAC` Type 5 com a bridge VXLAN do peer (`02:00:00:20:00:01`). |
| Capacidade S002 | **PASS** (23/10/2026) | `mgc` (5 containers: `244,77 MiB`) + OVS host (`306,8 MiB`) = `0,539 GiB` (`13,5%` da estimativa de `4 GiB`); `MemAvailable = 6,38 GiB` com `k01` + `p003-gw` + `mgc` simultâneos (`D5 = NÃO`). |

### 2. Plano OVN-Kubernetes + UDN/EVPN + KubeVirt e Casos Cruzados (`P004-S003` e `P004-S004`)

| Caso | Estado documentado | Resultado e limite |
|---|---|---|
| K01 — UDN com CIDR sobreposto | **PASS** (23/10/2026) | Duas `UserDefinedNetwork` primárias (`tenant-a` e `tenant-b`) com o mesmo CIDR `10.100.0.0/24` e VMs KubeVirt em KVM nativo (`/dev/kvm`) com o mesmo IP `10.100.0.14`: alcance intra-tenant `30/30` e bloqueio cross-tenant `0/30`. |
| K02 — Live Migration em UDN | **PASS** (23/10/2026) | `virtctl migrate vm-a` entre `ovnk-worker` e `ovnk-worker2` (~16 s) preservou o IP `10.100.0.14/24`, com `0%` de perda de pacotes ICMP (`60/60`) e sobrevivência da sessão TCP longa. |
| K03 / K04 — CUDN EVPN Type 5 e Lift-and-Shift | **PASS** (23/10/2026) | `K03`: `ClusterUserDefinedNetwork` (`10.200.0.0/24`) anunciada via `RouteAdvertisements` + `frr-k8s` (`v0.0.27`) ao `evpn-fabric` (VNI `10100`, `30/30` positivo, `0/10` negativo). `K04`: VM legada com IP fixo `192.168.50.10/24` preservado sem reendereçamento (`30/30` positivo, `0/10` negativo). |
| X01 (`G04`) — Tenant unificado nos 3 planos | **PASS** (24/10/2026) | Conectividade fim a fim (`30/30`) entre `mgc` (`192.168.100.10`), `evpn-fabric` (`10.0.0.10`) e VM KubeVirt no `ovnk` (`10.200.0.x`), com withdraw negativo (`0/5`). |
| X02 / X03 / X04 / X06 / X07 (`G05`) | **PASS** (24/10/2026) | `X02`: isolamento 3 planos com `10.200.0.0/24` e `10.0.0.0/24` sobrepostos (`30/30` intra-tenant, `0/5` cruzado, `0` pacotes vazados). `X03`: policy por community (`65000:100` aceita, `65000:999` bloqueada). `X04`: guardrail de Route-Target incorreto (`0/30`). `X06`: admissão vs bloqueio de colisão de CIDR em VRF hub. `X07`: isolamento L2 em `MAC-VRF` EVPN Type 2 (VNIs `20100`/`20200` com `172.16.50.0/24`, `30/30` intra-VNI e `0` frames ARP/ICMP entre VNIs). |

### 3. Braço Cilium A: `Cilium 1.20.2` + `KubeVirt v1.9.0` no `p003-gw` (`P004-S005`)

| Caso | Estado documentado | Resultado e limite |
|---|---|---|
| V00 / V01 (`C01`) — Datapath KVM e `CiliumEndpoint` | **PASS** (24/10/2026) | `vmi/vm-a` (CirrOS `0.6.3`, `masquerade` sobre `/dev/kvm`) em `p003-gw-worker`: `pod <-> VM` `30/30` nos dois sentidos (`Halted` `0/30`); `cep/virt-launcher-vm-a-95bwl` (`cep_id=242`, `sec_identity=172890`, `ip=10.245.2.231` no `PodCIDR` `10.245.2.0/24`, guest interno `10.0.2.2/24`). |
| V02 / V03 (`C02`/`C03`) — VIP BGP `/32` e `CiliumNetworkPolicy` | **PASS** (24/10/2026) | `V02`: `svc/vm-a-vip` (`10.202.255.20/32`, `bgp-advertise=true`) instalada em `border1` (`30/30` HTTP 200 de `198.19.0.10`; withdraw em `8 s` -> `0/30`). `V03`: `fromEndpoints: app=p004-client-a` permitiu `30/30` de `client-a` e bloqueou `0/30` de `client-b` (`18` drops `Policy denied` no `cilium-dbg monitor`). |
| V04 (`C04` / Gate `G01`) — Reuso de IP vs Identidade | **PASS** (24/10/2026) | No `CiliumPodIPPool p004-single-ip` (`10.253.0.100/32`), `vm-a-reuse` (`sec_id=163024`, `ip=10.253.0.100`) obteve `30/30 ALLOW` em `target-srv:8080`; após deleção, `vm-b-reuse` herdou o **mesmo IP `10.253.0.100`**, recebeu `sec_id=133690 != 163024` e obteve **`0/30 ALLOW`** sob `fromEndpoints(app=p004-vm-a)` (`25` drops `Policy denied`). Sob ACL por IP (`-s 10.253.0.100/32`), `vm-b-reuse` herdou `30/30 ALLOW`. |
| V05 (`C05` / `H3`) — Live Migration no Cilium OSS | **PASS** (24/10/2026) | Migração de `p003-gw-worker` (`10.245.2.190`) para `p003-gw-worker2` (`10.245.1.23`) em `22 s` (`passt=absent_in_crd`): o podIP mudou, a sessão TCP longa para o podIP antigo caiu (`tcp_long_survived=no`), o novo podIP respondeu `10/10` e a VIP BGP `10.202.255.20` reconvergiu automaticamente (`10/10`, `max_gap_ms=3000.0ms`). |
| V06 (`C06` / `H4`) — Multi-Pool `/32` BGP + Migração + Rollback | **PASS** (24/10/2026) | Em `ipam.mode=multi-pool` (`p004-vm`, `maskSize: 32`), `vmi/vm-a` recebeu `10.252.0.23/32` (`30/30` probes diretos de `198.19.0.10` via `border1`); após migração (`20 s` para `worker2`), recebeu `10.252.0.4/32` (`30/30` probes diretos, `/32` antigo retido no `CiliumNode` pelo piso `multiPoolPreAllocation`, `vip_gap_ms=3000.0ms`). Rollback limpo a `ipam.mode=kubernetes` (`0` pools) + `labctl p003-gw verify` e `labctl k01 verify` **OK** (`MemAvailable = 4,97 GiB`). |
| V07-A (`C07` / `C-neg` / `H5`) — Limite Estrutural de CIDR Sobreposto no Cilium OSS | **PASS** (24/10/2026) | Dois namespaces (`p004-tenant-a` e `p004-tenant-b`) compartilhando `10.253.10.0/24` operam na mesma tabela flat (`vrf_count=0`, alcance direto entre `10.253.10.67` e `10.253.10.12` sem VRF); dois pods exigindo o mesmo pool `/32` (`10.253.10.100/32`) colidem deterministicamente no mapa global `cilium_lxc` (`[PUT /endpoint/{id}][400] putEndpointIdInvalid "IP ipv4:10.253.10.100 is already in use"`). |
| V08-A (`C08` / `H8`) — Cutover Legado para KubeVirt via BGP `/32` (`10.60.0.50/32`) | **PASS** (24/10/2026) | VM legada QEMU/KVM (`p003-vm` `10.60.0.50/24` na `leaf1`, `30/30` HTTP `LEGACY_KVM_OK`) desligada (`0/5`) -> `CiliumPodIPPool/pool-legacy-v08a` (`10.60.0.50/32`) anunciado via BGP (`bgp_rib_s=25s`, `cutover_total_s=39s`) -> `vmi/vm-legacy-cutover` assumindo `10.60.0.50` com `30/30` HTTP `KUBEVIRT_VMI_OK` a partir de `198.19.0.10`. |
| C-neg (`G02` / `H5` / `H8`) — Fronteira do Cilium BGP Control Plane | **PASS** (24/10/2026) | `CiliumBGPAdvertisement` e `CiliumBGPPeerConfig` suportam apenas AFI/SAFI `ipv4/unicast` e `ipv6/unicast` (sem `vrf`/`l2vpn/evpn`), o GoBGP embarcado não instala rotas aprendidas na FIB do kernel (`proto bgp` = `0`) e a identidade eBPF permanece local ao cluster (não viaja no pacote BGP/IP externo). |

### 4. Braço Cilium B: `Cilium 1.20.2` + `FRR 10.7.1` no nó + VRF/EVPN (`P004-S006` e `P004-S007`)

| Caso | Estado documentado | Resultado e limite |
|---|---|---|
| H6 (`G06`) — Sessão BGP local Cilium -> FRR no nó -> Fabric sob `R6` | **PASS** (24/10/2026) | `DaemonSet/frr-node` (`FRR 10.7.1`, `AS 65301/65302`) em `hostNetwork` pareando localmente com o GoBGP do Cilium (`10.255.255.1:1790`, `AS 65311/65312`) e via eBGP com `leaf1`/`leaf2` (`AS 65201/65202 -> border1`, `AS_PATH 65203 65600 65201 65301 65311 i`, convergência `10s`, withdraw `12s`, `30/30` HTTP para Pod VIP `.10` e VM VIP `.20`), mantendo **`r6_kernel_bgp_routes = 0`** (`table-map RM-NO-KERNEL`, `0` rotas `proto bgp` na tabela `main`) e concluindo rollback limpo (`MemAvailable = 4,23 GiB`). |
| V09 (`H7`) / V07-B / V08-B — EVPN Type 5 por VRF, Overlap e Cutover FRR | **PASS** (25/10/2026) | `V09`: `vrf-tenant-a` (`VNI 10100`, `RT 65000:10100`) e `vrf-tenant-b` (`VNI 10200`, `RT 65000:10200`) anunciam EVPN Type 5 (`[5]`: `10.253.10.0/24`, `10.253.20.0/24`, `10.253.11.0/24`, `10.253.21.0/24`) entre `p003-gw-worker` e `p003-gw-worker2` (`30/30` intra-VRF, `0/10` cross-VRF, `RT 65000:99900` rejeitado, `R6=0`). `V07-B`: CIDR sobreposto `10.253.10.0/24` e IP `10.253.10.100/24` isolados por VRF/EVPN Type 5 no FRR (`30/30` intra-VRF, `0/10` cross-VRF, `R6=0`), mantendo o limite de colisão no endpoint map eBPF global do Cilium OSS (`eth0`). `V08-B`: cutover `10.60.0.50/32` via `Cilium -> FRR 10.7.1 no nó -> border1` (`AS_PATH 65203 65600 65201 65301 65311`, `rib_em=27s`, `cutover_total=40s`, `30/30` HTTP, `R6=0`) + rollback limpo (`MemAvailable = 4,95 GiB`). |
| G07 / G08 (`P004-S008`) — Síntese `INV × Aberto` e Higiene Final | **PASS** (25/10/2026) | `G07`: Matriz comparativa `INV × Cilium A × Cilium B × OVN-K (C/D)` e 6 critérios objetivos de aceite (`INV-PoC-01` a `INV-PoC-06`) publicados em `20-mgc-estado-parcial.md` §4.2 e no Guia do Estudante (Ed. 2.3). `G08`: `mgc`, `evpn-fabric` e `ovnk` desligados (`up=nao`, `0` resíduos), `p003-os` preservado (`exited`), `p003-gw` em baseline (`ipam=kubernetes`, `0` pools, `R6=0`, `verify OK`), `k01` `10/10` (`verify OK`) e `MemAvailable = 4,95 GiB` (baseline S008) / `4,93 GiB` (pós-verify final `G08`, `>= 4,00 GiB`). |

Consulte
[MGC, OVN-K e Cilium + KubeVirt em P004: consolidação completa de S001–S008 (§1–§8, G07 e G08)](estudos/20-mgc-estado-parcial.md)
para a matriz comparativa completa **Cilium A vs Cilium B vs INV (`V00–V09` / `H1–H8`)**, os critérios **`INV-PoC-01` a `INV-PoC-06` (`G07`)**, o blueprint de transição para o Braço **OVN-Kubernetes (`C` / `D`)** e as perguntas de estudo.

## Proveniência e limites

O roteiro e as configurações públicas neste diretório são a fonte de reprodução. Os resultados acima são um resumo editorial de execuções datadas; para uma nova aula, a coluna “observado” deve vir da saída atual do cluster. Não se deve inferir disponibilidade de produção, round-robin perfeito, persistência de sessão durante recriação de pod ou isolamento de tenant a partir de uma rota BGP.

Identificadores de sessão e nomes de diretórios que aparecem em comentários do kit referem-se a logs internos não publicados; eles não são necessários para reproduzir o roteiro público.
