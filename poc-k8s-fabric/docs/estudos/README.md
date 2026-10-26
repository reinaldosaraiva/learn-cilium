# Estudos P003 — Gateway API, segurança, IPAM e tenants híbridos

> Planejamento revisado em **20/09/2026**; trilha **P003 executada e encerrada em 25/09/2026** (S001–S016, gates G01–G10 atendidos), trilha **P004 (E20 v2 — MGC Connect × INV × Equivalente Aberto) executada e encerrada em 25/10/2026** (S001–S008, gates G00–G09 atendidos) e trilha **P005 (`E09–E19` e `E21–E25`, Ondas Paralelas Braço A eBGP ∥ Braço B Datapath eBPF) executada e encerrada em 25/10/2026** (S001–S004, gates G01–G10 atendidos, fechando `25/25` estudos do roadmap). Esta edição publica os dossiês P003 (`00`–`09`), a síntese E08 (S013/S014), a emenda C5 (S016, VM fora do container), a consolidação integral de E20/P004 em [`20-mgc-estado-parcial.md`](20-mgc-estado-parcial.md) (§1–§8) e os oito dossiês públicos de P005 (`11`, `13`, `15`, `17`, `19`, `21`, `22` e `24`). Os resultados de todas as sessões estão resumidos no [guia do estudante 2.4](../lab-guide-student.md) e nos [resultados do laboratório](../lab-results.md); a evidência bruta permanece privada.

Este índice público transforma o roteiro em uma sequência de 14 sessões pequenas, com fontes, critérios observáveis, controles negativos e rollback. O [resultado histórico do laboratório](../lab-results.md) permanece separado: ele descreve o kit de referência e não comprova nenhum estudo P003.

Gateway API vem primeiro. S002 é apenas um modelo de preflight de leitura; S003–S014 ficam em forecast e só podem ser materializadas uma por vez depois do veredito da predecessora. Os dossiês preservam a matriz experimental completa, mas não concedem acesso à infraestrutura nem autorização de execução.

## Como seguir o processo

1. Leia este índice, o [contrato técnico e de processo](design-contract.md), a [pesquisa](research.md) e o [protocolo de execução](execution-protocol.md).
2. Leia apenas o dossiê da próxima sessão; use o [modelo público de S002](sessions/S002-preflight.md) para uma retomada local e mantenha inventário, resultados e handoffs fora desta documentação.
3. Antes de qualquer mutação, materialize uma sessão local com valores descobertos, UID do cluster, allowlist, dry-run e gate de autorização. A presença de um dossiê não cria essa autorização.
4. Registre esperado e observado separadamente, execute controles positivos e negativos, e encerre a sessão com resultado, revisão e rollback.

Os exemplos de acesso exigem quatro variáveis explícitas. No Mac, defina `REFERENCE_SSH_TARGET` e `REFERENCE_SSH_KEY`; no host remoto, defina `REFERENCE_KUBECONFIG` e `REFERENCE_CONTEXT`. Variáveis do shell Mac não passam automaticamente via SSH. Use `sudo kubectl --kubeconfig "$REFERENCE_KUBECONFIG" --context "$REFERENCE_CONTEXT"` e o mesmo par de flags para `cilium`; nunca dependa do contexto implícito.

## Estado da publicação

- S001 fechou o planejamento em 20/09/2026; esta edição exporta o contrato, a pesquisa, o protocolo e os dossiês.
- S002 está representada por um template de leitura. Sua execução precisa criar evidência local e decidir GO/BLOCKED.
- **Síntese executada E08 (24/09/2026):** a matriz C01–C09 (S013 lado K8s + S014 lado VM) foi executada e consolidada na [síntese didática](08-lifecycle-synthesis.md) — primeira entrega de resultados publicada. As demais sessões seguem como dossiês de planejamento; resultados, credenciais, inventário bruto e estado Reentry permanecem fora do clone público.
- **Emenda C5 executada (25/09/2026):** a VM fora do container (KVM real no host) resolveu a limitação D-S012-13 (RX da VM em KVM aninhado) e provou tráfego **bidirecional pod↔VM** preservando o datapath Neutron — publicada em [C5 — VM fora do container](09-vm-outside-container.md).


## Objective

Transformar os estudos em experimentos pequenos, reproduzíveis e verificáveis por
um executor de menor capacidade, com pesquisa primária, instruções delimitadas,
evidência de tráfego, controles negativos e retomada sem depender de contexto externo.
Gateway API vem primeiro; tenants, IPAM e OpenStack completam a trilha.

## Plan Status

- **Status:** planejamento revisado; execução futura
- **Próxima fatia prevista:** [modelo S002](sessions/S002-preflight.md)
- **Referência didática:** [resultados históricos do laboratório](../lab-results.md); esse registro é separado deste plano.
- **Origem:** revisão aprofundada do roteiro de estudos, registrada em 20/09/2026.
- **Data:** 2026-09-20.
- **Forma pública:** este índice é a entrada portátil; uma execução local pode manter sua própria árvore Reentry e suas evidências.
- **Estado publicado:** planejamento revisado. O preflight e os demais experimentos futuros continuam sem execução nesta edição; as exceções são a [síntese E08](08-lifecycle-synthesis.md) (S013/S014) e a [emenda C5](09-vm-outside-container.md) (S016), publicadas como resultados.

## Assessment

**SCORE:** 7
**LEVEL:** COMPLEX
**ESFORÇO:** completo
**FORMA:** roteiro documental com revisão independente e sessões delimitadas
**FORECAST:** 14-14 sessions

Forecast ajustado ao escopo: 14 sessões Reentry. Até quatro rodadas adicionais de
diagnóstico podem ocorrer DENTRO dessas sessões, sem criar novos IDs ou liberar
cascata; isso não autoriza execução autônoma das sessões.
O escopo ampliado inclui a trilha anterior documentada em [próximos estudos](../proximos-estudos.md); qualquer correção de escopo deve ser registrada como emenda antes da execução.

## Source Material

1. [Contrato](design-contract.md): invariantes e critérios globais.
2. [Pesquisa](research.md): alegações, versões, fontes e limites da pesquisa.
3. [Protocolo de execução](execution-protocol.md): evidências, comandos e delegação.
4. Dossiê do estudo indicado na sessão; não é necessário reler todos.
5. [resultados históricos](../lab-results.md): baseline histórico, não saúde atual.

## Abordagens consideradas

| Opção | Vantagem | Limitação | Decisão |
|---|---|---|---|
| Alterar k01 em sequência | Menor custo de infraestrutura | Host network, WireGuard e IPAM têm efeito no cluster; destrói a referência | Rejeitada |
| Segundo cluster e fabric isolados na mesma VM, se houver capacidade | Reusa o modelo conhecido, permite controles e retorno à referência | Consome RAM/CPU; kernel é compartilhado, não reproduz Talos | Preferida; viabilidade a medir em S002 |
| Host experimental separado | Melhor isolamento de recursos e possibilidade de Talos | Infra e custo ainda não confirmados | Alternativa somente após escolha concreta do dono |

## Proposed Sessions

Somente uma sucessora é materializada após GO/PASS. Os dossiês abaixo detalham
estudos futuros; não são sessões executáveis, nem substituem a atualização de
âncoras e valores observados no momento de criar cada sessão.

| Session | Status | Deliverable | Verdict Expected | Dossiê |
|---|---|---|---|---|
| P003-S001 | PLANEJAMENTO FECHADO | Pesquisa aprofundada, contrato, roteiro e revisão de leitura | GO (20/09) | research + todos |
| P003-S002 | MODELO PÚBLICO | Inventário somente leitura; capacidade, versões, sub-redes e decisão do sandbox | GO | [E00](00-preflight.md) |
| P003-S003 | PLANNED | Sandbox isolado; Gateway HTTP/TCP/UDP exposto por VIP+BGP | PASS | [E01](01-gateway-bgp.md) |
| P003-S004 | PLANNED | Matriz TCPRoute/UDPRoute com LoadBalancer, NodePort e host network | PASS | [E02](02-l4-hostnetwork.md) |
| P003-S005 | PLANNED | Fixtures de auth observáveis; HTTP e gRPC; allow/deny | PASS | [E03](03-externalauth.md) |
| P003-S006 | PLANNED | Auth indisponível/referência inválida, fail-closed e referência 1.20.2 | PASS | [E03](03-externalauth.md) |
| P003-S007 | PLANNED | WireGuard/native: local × remoto, node encryption OFF × ON | PASS | [E04](04-wireguard.md) |
| P003-S008 | PLANNED | WireGuard/VXLAN: reprodução delimitada da issue 46768 | PASS | [E04](04-wireguard.md) |
| P003-S009 | PLANNED | Tenants A/B, policies/RBAC, ListenerSet e TLS do backend | PASS | [E05](05-tenants.md) |
| P003-S010 | PLANNED | Multi-Pool /24 × /32: alocação, anúncios e ciclo de vida | PASS | [E06](06-ipam.md) |
| P003-S011 | PLANNED | Inventário OpenStack e desenho verificável da integração | GO | [E07](07-openstack.md) |
| P003-S012 | PLANNED | Pod A → VM A permitido; tenant B bloqueado nos dois sentidos definidos | PASS | [E07](07-openstack.md) |
| P003-S013 | EXECUTADO | Recriação/reuso de IP com revogação de autorização e rotas observada | PASS | [E08](08-lifecycle.md) · [síntese](08-lifecycle-synthesis.md) |
| P003-S014 | EXECUTADO | Síntese de limites, exercícios, gates de adoção e entrega didática | PASS | [E08](08-lifecycle.md) · [síntese](08-lifecycle-synthesis.md) |
| P003-S016 (C5) | EXECUTADO | VM fora do container (KVM real no host): RX resolvido + pod↔VM bidirecional | PASS | [C5](09-vm-outside-container.md) |
| P004-S001..S008 (E20 v2) | EXECUTADO | Lab MGC Connect (`M01–M03`, `X05`), OVN-K + EVPN (`K01–K04`), Casos Cruzados (`X01–X07`), Braço Cilium A (`V00–V08A`), Braço Cilium B (`H6`, `V09`, `V07-B`, `V08-B`) e Síntese `INV × Equivalente Aberto` (`G00–G09`) | PASS | [E20 (`20-mgc-estado-parcial.md`)](20-mgc-estado-parcial.md) |
| P005-S001 (Onda 1: `E19`+`E09` ∥ `E23`+`E21`) | EXECUTADO | **Braço A:** Idempotência 10x BGP, zero resíduo e reuso de VIP (`E19`) + eBGP TCP MD5 RFC 2385 com ASN 32 bits `4200000001` e rotação (`E09`). **Braço B:** `netkit` vs `veth` no datapath eBPF (`E23`) + Escala de Burst IPAM `kubernetes` vs `multi-pool` frio/aquecido (`E21`). | PASS | [E19/E09 (`19-bgp-idempotency-md5-asn32.md`)](19-bgp-idempotency-md5-asn32.md) · [E23/E21 (`21-netkit-vs-veth-ipam-burst.md`)](21-netkit-vs-veth-ipam-burst.md) |
| P005-S002 (Onda 2: `E11`+`E12`+`E10` ∥ `E22`) | EXECUTADO | **Braço A:** `max-prefix` e filtro de import (`E11`) + Communities `65400:100/200`, `AS-path prepend` e `MED` (`E12`) + Detecção de falha com BFD `< 1 s` (`359 ms`) vs Timers BGP `3/9 s` e `1/3 s` (`E10`). **Braço B:** XLB L7 eBPF (`sockmap`/`bpf_sock_ops`/`sk_msg`) vs `SocketLB L4` vs `Envoy L7` (`E22`). | PASS | [E11/E12/E10 (`11-bgp-maxprefix-communities-bfd.md`)](11-bgp-maxprefix-communities-bfd.md) · [E22 (`22-xlb-ebpf-socket-lb-vs-envoy.md`)](22-xlb-ebpf-socket-lb-vs-envoy.md) |
| P005-S003 (Onda 3: `E13`+`E14` ∥ `E17`+`E25`) | EXECUTADO | **Braço A:** Redundância dual-border (`border1`/`frr-e13-border2`) e failover controlado com e sem Graceful Restart (`E13`: `0` perdas `139/139` c/ GR vs `8879 ms` `78` falhas s/ GR) + Sessão eBGP IPv6 dedicada e VIP `fd14::a/128` fim a fim (`E14`: `30/30` HTTP `200`). **Braço B:** Observabilidade contínua BGP (`ACTIVE`/`DOWN`/`UNKNOWN` por 3 leituras consecutivas, `E17`) + Microsserviços com Hubble (`L3/L4`, `L7 HTTP/DNS`, fronteira `TLS :8443`, Prometheus `:9965` e resiliência do ring buffer local, `E25`). | PASS | [E13/E14 (`13-bgp-dual-border-gr-ipv6.md`)](13-bgp-dual-border-gr-ipv6.md) · [E17/E25 (`17-bgp-hubble-observability.md`)](17-bgp-hubble-observability.md) |
| P005-S004 (Onda 4: `E15`+`E16`+`E18` ∥ `E24`) | EXECUTADO | **Braço A:** VRF por tenant no PE via BGP community (`E15`: `65400:1010/1020`, `30/30` intra-tenant, `0/5` cross-VRF e `65400:9999` rejeitada) + Terminação PE/CE, 3 modos de retorno e `CiliumEgressGatewayPolicy` (`E16`: SNAT determinístico `10.255.216.10` `30/30` vs bloqueio ACL `0/5`, `R6=0`) + Enlace L2 com MTU 9000 Jumbo/PMTU, QinQ `802.1ad` (`0x88a8`+`0x8100`) e MACsec `802.1AE` (`0x88e5`, `gcm-aes-128`) vs WireGuard (`E18`). **Braço B:** Dynamic Resource Allocation (`resource.k8s.io/v1`) no Cilium (`E24`: `ResourceSlice`, `DeviceClass` CEL, `NetworkDeviceData`, idempotência `3x`, coexistência `eth0`+`net1`/`net2` e controles `3A–3D`). | PASS | [E15/E16/E18 (`15-bgp-vrf-return-paths-l2-mtu-qinq-macsec.md`)](15-bgp-vrf-return-paths-l2-mtu-qinq-macsec.md) · [E24 (`24-cilium-dra-network-device.md`)](24-cilium-dra-network-device.md) |
| P006-S001 (Onda 1: `E26` ∥ `E30` ∥ `C1`) | EXECUTADO | **Braço A (`E26`):** LoadBalancer TCX/XDP, anúncio BGP seletivo `ETP=Local` (`100%` preservação de IP `198.19.0.10`) vs `ETP=Cluster` (SNAT cross-node) e Maglev (`M=16381`, `0` rehash colateral). **Braço B (`E30`):** Cilium Cluster Mesh / MCS-API (`EndpointSlice` multi-cluster), failover global sobre BGP (`20/20` E-W e N-S) e controles `3A`/`3B` (`CiliumNetworkPolicy` `egressDeny` e unexport). **Braço C (`C1`):** Resolução de `A4–A8` e `A10–A12` de [`revisao-projeto-2026-09-26.md`](../revisao-projeto-2026-09-26.md). | PASS | [E26/E30 (`26-lb-xdp-dsr-maglev-clustermesh.md`)](26-lb-xdp-dsr-maglev-clustermesh.md) |
| P006-S002 (Onda 2: `E27` ∥ `E31` ∥ `C2`) | EXECUTADO | **Braço A (`E27`):** BIG TCP (`gso_max_size=196608`, super-pacotes de `187.974 B` IPv4 e `187.582 B` IPv6 no `tcpdump` em `veth` e `netkit mode l3`), throughput de `46,31 Gbps` (`big-veth-ipv4`, `+18,1%`) e `46,08 Gbps` (`big-netkit-ipv4`, `+17,6%` vs `39,20 Gbps` em `MTU 1500`), `-59,6%` a `-60,8%` pacotes, `-51,0%` a `-51,6%` `NET_RX` softirqs e prova de PMTU Blackhole (`3A/3B/3C`: `0/5` ping `DF=1` e `TIMEOUT_BLACKHOLE` em `256 KiB` TCP c/ ICMP bloqueado vs `ACK:262144` via RFC 4821 `tcp_mtu_probing=2`). **Braço B (`E31`):** SRv6 L3VPN (`seg6local action End.DT4 vrftable 131/132` + `encap seg6 mode encap` s/ VXLAN), `30/30` HTTP `200` com subnets `10.253.31.0/24` e IPs `10.253.31.10/20` 100% sobrepostos (`leak=0`), `0/5` cross-VRF e revogação/restauração seletiva de SID. **Braço C (`C2`):** Resolução de `A1–A3`, `A9` e `M1–M6`. | PASS | [E27/E31 (`27-big-tcp-netkit-srv6-l3vpn.md`)](27-big-tcp-netkit-srv6-l3vpn.md) |
| P006-S003 (Onda 3: `E28` ∥ `E32` ∥ `C3`) | EXECUTADO | **Braço A (`E28`):** Bandwidth Manager (`enable-bandwidth-manager=true`, `/proc/sys` `rw` em `kind`, `qdisc fq` + pacing `fq maxrate`/`htb`/`tbf` derivado de `kubernetes.io/egress-bandwidth`: `50M` -> `49,70` / `49,62 Mbps`, `100M` -> `97,34` / `97,70 Mbps` vs `8.487,12` / `8.940,35 Mbps` sem limite; anotação inválida `invalid-rate` rejeitada s/ crash; remoção dinâmica de `50M` restaurando `8.396,79` / `8.999,01 Mbps` em `2,00 s` s/ restart) e `TCP BBR` vs `CUBIC` sob WAN degradada (`netem delay 10ms loss 0.5% rate 500mbit`: `163,20 vs 118,71 Mbps` `+37,5%` em `RUN 1` e `237,36 vs 165,01 Mbps` `+43,8%` em `RUN 2`). **Braço B (`E32`):** Runtime Security via CRD `TracingPolicyNamespaced` (`cilium.io/v1alpha1`, `e32-runtime-security-policy`, `podSelector: app=e32-workload`) e sensor/harness local correlacionando `process_exec`/`process_kprobe` (`security_file_permission` `/etc/shadow` e `tcp_connect` `:4444`) com identidade Cilium (`EP_ID`, `CILIUM_IDENTITY`), e enforcement síncrono `Sigkill` (`rc=137`, `0` bytes vazados) preservando `10/10` HTTP `200` legítimo (`:8080`). **Braço C (`C3`):** Resolução de `M7–M15`. | PASS | [E28/E32 (`28-bandwidth-edt-bbr-tetragon.md`)](28-bandwidth-edt-bbr-tetragon.md) |

## Dependências e limites

- S003 depende de inventário positivo e autorização de execução do sandbox.
- S004 muda configuração global somente no sandbox. Um namespace separado não basta.
- S005/S006 validam auth antes de misturar criptografia. HTTP e gRPC têm casos separados.
- S007/S008 comparam configurações explícitas; “same-node” refere-se ao Envoy
  que processou a requisição e ao pod de autorização, comprovados por evidência.
- S009 aproveita Gateway e auth; autorização de usuário, política de pod e
  delegação de configuração são controles diferentes.
- S010 mantém a variável IPAM constante na comparação principal (/24 e /32
  ambos em Multi-Pool); o IPAM Kubernetes atual é apenas referência adicional.
- S011 depende de OpenStack acessível e identificado. Um ambiente gerenciado não é automaticamente um endpoint OpenStack disponível.
- S012/S013 exigem inventário de recursos do experimento e ownership explícito.
  Ausência de OpenStack não autoriza substituir VMs por pods e declarar o caso provado.

## Design Requirements

1. O executor MUST validar contexto, cluster UID e inventário antes de mutar.
2. O executor MUST registrar esperado e observado separadamente, inclusive falhas.
3. O executor MUST NOT concluir sucesso por status Ready/Programmed isolado,
   porque isso não comprova o caminho do pacote nem a aplicação da autorização.
4. Cada hipótese MUST ter controle positivo, controle negativo e coleta externa.
5. A execução MUST preservar k01 e recursos históricos; limpeza é por UID/lista.
6. Mudanças de variável MUST ocorrer uma por vez, com baseline antes/depois.
7. Toda alegação volátil MUST citar versão exata e fonte; issue é relato até reprodução.
8. O modelo executor MUST escalar hipótese nova ou interface ausente, não improvisar arquitetura.

## Non-Goals

Produção, migração do k01, recursos não inventariados, publicação automática, migração de estado, throughput de hardware, framework novo de automação, implementação de IdP ou controlador Kubernetes–Neutron.

## Execution Rules

- Uma pessoa coordenadora delimita cada sessão, fornece seis campos (Objective/Anchors/Steps/Constraints/Acceptance/Out-of-scope) e conserva a decisão de aceite.
- A pessoa que executa uma fatia não altera o índice nem decide o próprio veredito; revisão independente deve reexaminar os dados.
- Cada sessão lê o contrato e somente o dossiê necessário. Evidências e estado de execução ficam locais e fora da edição pública.
- Primeiro materializar manifests/scripts verificáveis; somente depois iniciar o experimento autorizado. Não afirmar que arquivos planejados já existem.

## Acceptance Gates

P003 só será COMPLETE depois da execução e evidências, não pelo tamanho do plano:

1. G01: baseline isolado e VIP+BGP com probes HTTP/TCP/UDP.
2. G02: matriz de portas L4 e host network com provas no cliente e nó.
3. G03: auth permite/nega corretamente e referencia inválida não libera aplicação.
4. G04: pares local/remoto e native/VXLAN classificados com rastreio suficiente.
5. G05: tenants não podem alcançar nem reconfigurar recursos indevidos.
6. G06: /24 × /32 medido com IPAM controlado e reservas separadas dos pods vivos.
7. G07: OpenStack real identificado e acesso híbrido autorizado por tenant.
8. G08: reuso de IP não herda autorização no modelo testado; limites explicitados.
9. G09: roteiro didático permite a outro executor repetir os ensaios.
10. G10: cada sessão tem resultados, revisão e rollback/estado final documentados.

## Overrun Rule

Uma célula inconclusiva mantém a sessão atual IN_PROGRESS e gera tarefa de
diagnóstico dentro dela, com hipótese, escopo e evidência próprios. Não exige
nem cria a próxima sessão. BLOCKED reserva-se ao impedimento externo identificado;
FAIL mantém a cascata parada até redirecionamento explícito do dono.

Orçamento de até quatro rodadas diagnósticas extras, sem novos IDs de sessão,
para: capacidade do sandbox; prova do nó de ingresso; defeito reproduzido;
particularidade do backend OpenStack. Registrar motivo e consumo desse orçamento.
Esgotamento pede checkpoint de planejamento ao dono; não muda automaticamente
verdict para GO/PASS. Qualquer nova sessão S015+ requer emenda explícita do roadmap
e preservação da cascata, depois do aceite legítimo da predecessora.
