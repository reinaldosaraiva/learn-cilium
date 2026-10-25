# Changelog

Todas as mudanças relevantes deste repositório de estudos e laboratório
(`learn-cilium` / `poc-k8s-fabric`) são documentadas neste arquivo.

---

## [v2.4.0-dev] — 2026-10-25 (Em andamento — Plano `P005`)

### Adicionado
- **P005-S001 — Onda 1 Paralela (`Braço A: E19 + E09` ∥ `Braço B: E23 + E21`) (`Verdict: PASS`):**
  - **Braço A (`poc-k8s-fabric/studies/p005/arm-a-ebgp/`, dossiê [`19-bgp-idempotency-md5-asn32.md`](poc-k8s-fabric/docs/estudos/19-bgp-idempotency-md5-asn32.md)):**
    - `E19`: prova de idempotência declarativa (`10x kubectl apply` consecutivos com `0` diffs em `route-policies`, `advertised routes` e na RIB de `border1` com `version: 488` constante), auditoria de zero resíduo após remoção (`R6=0` rotas `proto bgp` no kernel) e reuso imediato da VIP `10.202.255.190/32` por `e19-echo-b` (`30/30` HTTP `200` em `/hostname` retornando `e19-echo-b-*`, `0` respostas antigas `e19-echo-a-*`).
    - `E09`: sessão eBGP autenticada com TCP MD5 (`RFC 2385`, `authSecretRef` em `kube-system`) e ASN privado de 32 bits (`4200000001`, `RFC 6793`) contra `frr-e09` (`established` em `3 s`, opção TCP 19 comprovada via `tcpdump`), controles negativos de senha divergente (`TcpExtTCPMD5Failure=2`, `3/3` sessões do fabric intactas) e Secret ausente (`restarts=0`), e rotação de senha em produção (`v1 -> v2` convergida em `9,39 s`).
  - **Braço B (`poc-k8s-fabric/studies/p005/arm-b-datapath/`, dossiê [`21-netkit-vs-veth-ipam-burst.md`](poc-k8s-fabric/docs/estudos/21-netkit-vs-veth-ipam-burst.md)):**
    - `E23`: benchmark comparativo `netkit` (`mode l3`, `NOARP`) vs `veth` (`tcx`) no Cilium `1.20.2` (Kernel `6.8.0-139-generic`, `CONFIG_NETKIT=y`), comprovando a guarda fail-closed de migração `veth -> netkit` com endpoints incompatíveis, eliminação de `100%` das retransmissões TCP em `iperf3` (`47 -> 0` same-node, `11 -> 0` cross-node), redução de softirqs `NET_RX` (`-8,9%` same-node, `-20,5%` cross-node), controle negativo com `CiliumNetworkPolicy` (`leaked_pkts=0`) e rollback limpo para `veth`.
    - `E21`: escala de burst IPAM (`16` pods simultâneos com imagem local `registry.k8s.io/e2e-test-images/agnhost:2.47`) comparando `ipam.mode=kubernetes` (`5,40 s`, `2,96 pods/s`, `0` falhas CNI), `multi-pool` frio (`e21-burst-pool` `10.252.0.0/16` `maskSize: 32`, `ipam.multiPoolPreAllocation="default=8,e21-burst-pool=1"` -> `27` falhas `postIpamFailure` `502` / `FailedCreatePodSandBox`), `multi-pool` pré-aquecido (`ipam.multiPoolPreAllocation="default=8,e21-burst-pool=32"` -> **`0` falhas `postIpamFailure`**, eliminando `100%` dos erros de `CNI ADD`) e controle negativo de exaustão de `e21-tiny-pool` (`10.253.21.0/29`, `6 Running`, `4 Pending`, sem impacto em outros pools).

---

## [v2.3.0] — 2026-10-25

### Adicionado
- **P004-S008 — Síntese `INV × Equivalente Aberto` (`G07`), Guia do Estudante Ed. 2.3 e Higiene Final (`G08`) (`Verdict: PASS`, Encerramento de `P004`):**
  - Seção **`§4.2 Síntese INV × Equivalente Aberto e Critérios de Aceite para uma PoC Comercial do INV (Gate G07)`** em [`poc-k8s-fabric/docs/estudos/20-mgc-estado-parcial.md`](poc-k8s-fabric/docs/estudos/20-mgc-estado-parcial.md), definindo os 6 critérios objetivos de aceite (`INV-PoC-01` a `INV-PoC-06`) e contrastando Cilium OSS (`Braço A`), Cilium + FRR (`Braço B`), OVN-Kubernetes (`Braço C/D`) e INV.
  - Atualização do [Guia do Estudante para a Edição 2.3](poc-k8s-fabric/docs/lab-guide-student.md) (nova seção `13.4` cobrindo `S006–S008`, exercícios de interpretação e limites), regeneração dos diagramas [`08-p004-estado.svg`](poc-k8s-fabric/docs/diagramas/08-p004-estado.svg) (`.png`) e [`09-p004-tres-planos-kubevirt.svg`](poc-k8s-fabric/docs/diagramas/09-p004-tres-planos-kubevirt.svg) (`.png`) e do PDF [`output/pdf/cilium-lab-student-guide.pdf`](output/pdf/cilium-lab-student-guide.pdf).
  - Gate **`G08`** de higiene final comprovado em `vm-cilium` ([`poc-k8s-fabric/evidence/P004/S008/`](poc-k8s-fabric/evidence/P004/S008/)): `mgc`, `evpn-fabric` e `ovnk` desligados (`up=nao`, `0` resíduos), `p003-os` preservado (`exited`), `p003-gw` limpo em `ipam.mode=kubernetes` (`0` pools, `R6=0`, `verify OK`), canário `k01` `10/10` (`verify OK`) e `MemAvailable = 4,95 GiB` (baseline S008) / `4,93 GiB` (pós-verify final `G08`, `>= 4,00 GiB`).
- **P004-S007 — Braço Cilium B (`V09`/`H7`, `V07-B`, `V08-B`), Matriz Final Cilium A vs B e Blueprint Fase 2 OVN-K (`C/D`) (`Verdict: PASS`):**
  - Execução ao vivo em `vm-cilium` dos scripts do Braço Cilium B ([`poc-k8s-fabric/studies/p004/cilium-b/`](poc-k8s-fabric/studies/p004/cilium-b/), evidências em [`poc-k8s-fabric/evidence/P004/S007/`](poc-k8s-fabric/evidence/P004/S007/)):
    - `V09 (H7)`: EVPN Type 5 (`[5]`) por VRF Linux (`vrf-tenant-a` `VNI 10100` `RT 65000:10100` e `vrf-tenant-b` `VNI 10200` `RT 65000:10200`) via `DaemonSet/frr-node` (`FRR 10.7.1`) com `30/30` intra-VRF, `0/10` cross-VRF, `RT 65000:99900` rejeitado e `R6=0`.
    - `V07-B`: isolamento de CIDR sobreposto `10.253.10.0/24` e IP idêntico `10.253.10.100/24` nas VRFs do FRR (`30/30` intra-VRF, `0/10` cross-VRF, `R6=0`), demonstrando a fronteira estrutural da interface primária `eth0` global do Cilium (`cilium_lxc`).
    - `V08-B`: cutover de IP legado `10.60.0.50/32` via `Cilium GoBGP -> FRR 10.7.1 no nó -> border1` (`AS_PATH 65203 65600 65201 65301 65311`, `Community 65301:100`, `rib_em=27s`, `cutover_total=40s`, `30/30` HTTP, `R6=0`) + rollback completo para `ipam.mode=kubernetes`.
  - Fechamento de `20-mgc-estado-parcial.md` (§1–§8) com a matriz comparativa `Cilium A vs Cilium B vs INV` e o blueprint de transição para o Braço OVN-Kubernetes (`C/D`).
- **P004-S006 — Negativos do Braço Cilium A (`V07-A`, `V08-A`, `C-neg` / `G02`) e Fundação do Braço Cilium B (`H6` / `G06`) (`Verdict: PASS`):**
  - `V07-A (C07 / H5)`: prova de não-isolamento flat e colisão de IP duplicado (`putEndpointIdInvalid "IP ipv4:10.253.10.100 is already in use"`) no Cilium OSS.
  - `V08-A (C08 / H8)`: cutover de VM legada `10.60.0.50/24` para VMI KubeVirt `/32` BGP (`cutover_total_s=39s`, `30/30` HTTP) e prova de `PoolExhausted`.
  - `C-neg (G02)` e `H6 (G06)`: rejeição de `vrf`/`evpn` na API BGP v2 do Cilium e pareamento local `Cilium GoBGP (:1790) <-> FRR 10.7.1 no nó` com invariante `R6` (`table-map RM-NO-KERNEL` -> `0` rotas `proto bgp` na tabela `main`).

---

## [v2.2.0] — 2026-10-24

### Adicionado
- **P004-S005 — Braço Cilium A: KubeVirt `v1.9.0` sobre Cilium `1.20.2` (`p003-gw`) (`Verdict: PASS`):**
  - Scripts idempotentes (`00-prep-kubevirt-p003gw.sh`, `v00` a `v06` com `--dry-run`) e manifests em [`poc-k8s-fabric/studies/p004/cilium-a/`](poc-k8s-fabric/studies/p004/cilium-a/).
  - `V00` e `V01 (C01 / H1)`: Gate de datapath KVM nativo (`/dev/kvm`) com `vmi/vm-a` (CirrOS `0.6.3`, `binding: masquerade`, `30/30` RX/TX e `0/30` com `runStrategy=Halted`) e inspeção como `CiliumEndpoint` (`cep_id=242`, `sec_identity=172890`, `podIP=10.245.2.231` no `PodCIDR` `10.245.2.0/24`, guest `eth0=10.0.2.2/24`).
  - `V02 (C02 / H1)` e `V03 (C03 / H1)`: Exposição externa via `Service LoadBalancer vm-a-vip` (`10.202.255.20/32` em `border1`, `30/30` HTTP 200 de `198.19.0.10`, withdraw em `8 s` → `0/30`) e `CiliumNetworkPolicy` por label (`fromEndpoints: app=p004-client-a` `30/30` vs `client-b` `0/30` com `18` drops `Policy denied`).
  - `V04 (C04 / Gate G01 / H2)`: Prova experimental de reuso determinístico de IP (`CiliumPodIPPool p004-single-ip` `10.253.0.100/32`) entre duas VMs sucessivas (`vm-a-reuse` `sec_id=163024` → `30/30 ALLOW`; `vm-b-reuse` herda `10.253.0.100` com `sec_id=133690 != 163024` → **`0/30 ALLOW`** e `25` drops sob `fromEndpoints`, em contraste com `30/30 ALLOW` sob ACL ancorada em IP `-s 10.253.0.100/32`).
  - `V05 (C05 / H3)`: Live Migration no Cilium OSS (`p003-gw-worker` `10.245.2.190` → `p003-gw-worker2` `10.245.1.23` em `22 s`), comprovando troca do IP do `virt-launcher`, queda da sessão TCP direta para o podIP antigo e reconvergência automática da VIP BGP `10.202.255.20/32` (`max_gap_ms=3000.0ms`).
  - `V06 (C06 / H4)`: Multi-Pool `/32` BGP por VM (`CiliumPodIPPool p004-vm`, `10.252.0.23/32` → `10.252.0.4/32` em `border1` após migração de `20 s`, retenção do `/32` antigo no `CiliumNode` pelo piso `multiPoolPreAllocation` `D-S010-1`), registro de `D-S010-4` estendido aos pods do control-plane KubeVirt e rollback completo a `ipam.mode=kubernetes` (`0` pools residuais, `labctl p003-gw verify` e `labctl k01 verify` `OK`, `MemAvailable = 4,97 GiB`).
- **P004-S004 — Casos Cruzados entre Planos `X01–X04`, `X06`, `X07` (`Verdict: PASS`):**
  - Scripts e manifests em `poc-k8s-fabric/studies/p004/cases/` provando os gates **`G04`** e **`G05`**.
  - `X01 (G04)`: Tenant unificado fim a fim entre o plano MGC (`192.168.100.10`), o fabric EVPN (`10.0.0.10`) e a VM KubeVirt no OVN-K (`10.200.0.x`, `30/30`).
  - `X02`, `X03`, `X04`, `X06`, `X07 (G05)`: Isolamento em 3 planos com `10.200.0.0/24` e `10.0.0.0/24` sobrepostos (`0` pacotes vazados), filtro por BGP community (`65000:100` vs `65000:999`), bloqueio de Route-Target incorreto (`0/30`), guarda de colisão de CIDR em VRF hub e isolamento L2 em `MAC-VRF` EVPN Type 2 (`VNIs 20100/20200` com `172.16.50.0/24`).
- **P004-S003 — Braço OVN-Kubernetes `v1.4.0` + KubeVirt `v1.9.0` + EVPN (`Verdict: PASS`):**
  - Perfis `labctl evpn-fabric` e `labctl ovnk` e matriz `K01–K04` em `poc-k8s-fabric/studies/p004/evpn-fabric/` e `poc-k8s-fabric/studies/p004/ovnk/` (`K01` UDN com CIDR sobreposto `10.100.0.0/24` e mesmo IP `.14` isolado; `K02` live migration preservando IP `.14` e sessão TCP com `0%` packet loss; `K03` `CUDN` + `EVPN Type 5` via `frr-k8s` `v0.0.27`; `K04` lift-and-shift de IP fixo `192.168.50.10/24`).
- **Diagramas e Guia do Estudante (Edição 2.2):**
  - Novo diagrama arquitetural [`09-p004-tres-planos-kubevirt.svg`](poc-k8s-fabric/docs/diagramas/09-p004-tres-planos-kubevirt.svg) (`.png`) comparando lado a lado os três planos de rede para VMs (OVN-K `K01–K04`, MGC + Fabric EVPN Cruzado `X01–X07` e Braço Cilium A + KubeVirt `V00–V06`).
  - Atualização de [`08-p004-estado.svg`](poc-k8s-fabric/docs/diagramas/08-p004-estado.svg) (`.png`) com o progresso consolidado `S001–S005 PASS`.
  - Atualização do [Guia do Estudante para a Edição 2.2](poc-k8s-fabric/docs/lab-guide-student.md) (seções `13.1`, `13.2` e `13.3`) e regeneração de [`output/pdf/cilium-lab-student-guide.pdf`](output/pdf/cilium-lab-student-guide.pdf).

---

## [v2.1.0] — 2026-10-23

### Adicionado
- **P004-S001 & P004-S002 — `labctl` e Réplica MGC Connect (`OVN 26.03.3` + `OVS 3.7` + `FRR`) (`Verdict: PASS`):**
  - CLI [`poc-k8s-fabric/labctl/labctl`](poc-k8s-fabric/labctl/labctl) idempotente com `--dry-run`, `--evidence` e medição de memória antes/depois.
  - Réplica em miniatura da PoC MGC Connect (`labctl mgc`): cenários `M01` (BGP/ECMP e falhas), `M02` (MTU `1500` vs `9000` / PMTU) e `M03` (EVPN Type 5 VNI `50100` com controle causal).
  - Caso `X05`: dois tenants com `192.168.100.0/24` e `169.254.254.0/30` sobrepostos em `ovnvrf100` (VNI `50100`) e `ovnvrf50200` (VNI `50200`, RT `65000:50200`) isolados simultaneamente (`30/30` intra-tenant, `0/3` cross-tenant, `0` resíduos pós-rollback).
  - Medição de capacidade pós-MGC (`0,539 GiB` somando containers `mgc` + OVS host; `MemAvailable = 6,38 GiB` com `k01`, `p003-gw` e `mgc` ativos simultaneamente).
  - Edição 2.1 do [Guia do Estudante](poc-k8s-fabric/docs/lab-guide-student.md) com o Módulo 13 inicial e diagrama `08-p004-estado`.

---

## [v2.0.0] — 2026-09-25

### Adicionado
- **Trilha P003 concluída (`S001–S006`, `E01–E09`):**
  - `E01` (Gateway API L7 + `CiliumNetworkPolicy` Envoy HTTP + falha/recuperação de link SR Linux via `sr_cli`), `E02` (WireGuard transparent encryption), `E03` (multi-tenant A/B), `E04` (comparação IPAM `kubernetes` vs `cluster-pool` vs `multi-pool`), `E05` (LoadBalancer `/32` dedicado vs compartilhado).
  - `E06/E07` (OpenStack 2024.1 + OVN no testbed `p003-os` e tenant híbrido Pod Cilium ↔ VM OpenStack pelo fabric BGP, `C1–C5` e estudo dedicado [`09-vm-outside-container.md`](poc-k8s-fabric/docs/estudos/09-vm-outside-container.md)).
  - `E08` ([`08-lifecycle-synthesis.md`](poc-k8s-fabric/docs/estudos/08-lifecycle-synthesis.md)) e `E09` (revisão didática e publicação da Edição 2.0 do Guia do Estudante com Módulos 1–12).

---

## [v1.0.0] — 2026-09-19

### Adicionado
- **Trilhas P001 e P002 concluídas:**
  - Laboratório base `k01` dentro da `vm-cilium`: Containerlab (2 spines e 3 leaves Nokia SR Linux `25.3.2`, `border1` FRR `8.4.1`, `client-ext`), cluster Kind de 3 nós (`v1.35.0`) e Cilium `1.20.1` em native routing dual-stack com BGP Control Plane.
  - Demonstração de anúncio de PodCIDR `/24` por nó e VIP `/32` ECMP (`10.201.255.10/32`) para Service `LoadBalancer`.
  - Primeira edição do Guia do Estudante e builder determinístico em ReportLab (`poc-k8s-fabric/tools/build_guide.py`).
