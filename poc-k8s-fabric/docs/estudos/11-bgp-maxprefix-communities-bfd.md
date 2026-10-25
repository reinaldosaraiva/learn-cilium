# 11 — Proteção de Borda (`maximum-prefix` e Filtro de Import `E11`), Engenharia de Tráfego por Communities/Prepend/MED (`E12`) e Detecção Sub-Segundo com BFD (`E10`)

**Plano / Sessão:** `P005-S002` (Onda 2 Paralela — Braço A: Conexão Dedicada eBGP)  
**Cluster Alvo:** `p003-gw` (`kind-p003-gw`, UID `6bb32e0f-71f9-4558-ae33-356ba2250c26`, Cilium `1.20.2`)  
**Canário Protegido:** `k01` (`kind-k01`, UID `635e7274-5597-40c7-9de5-b1fbe3d68b22`, `10/10` HTTP `200`)  
**Scripts Reprodutíveis:**
- [`poc-k8s-fabric/studies/p005/arm-a-ebgp/e11-bgp-maxprefix-import-filter.sh`](../../studies/p005/arm-a-ebgp/e11-bgp-maxprefix-import-filter.sh)
- [`poc-k8s-fabric/studies/p005/arm-a-ebgp/e12-bgp-communities-prepend-med.sh`](../../studies/p005/arm-a-ebgp/e12-bgp-communities-prepend-med.sh)
- [`poc-k8s-fabric/studies/p005/arm-a-ebgp/e10-bgp-failure-detection-bfd.sh`](../../studies/p005/arm-a-ebgp/e10-bgp-failure-detection-bfd.sh)
- [`poc-k8s-fabric/studies/p005/arm-a-ebgp/manifests/04-e12-communities-workloads.yaml`](../../studies/p005/arm-a-ebgp/manifests/04-e12-communities-workloads.yaml)

---

## 1. Contexto e Perguntas de Engenharia

Ao conectar um cliente corporativo via **Conexão Dedicada (Direct Connect / Interconnect)** usando eBGP, três garantias de plano de controle são exigidas pelos requisitos funcionais e não funcionais (`RF05`, `RF07`, `RNF03`, `RNF05` de [`docs/proximos-estudos.md`](../proximos-estudos.md)):

1. **Proteção de Borda — `maximum-prefix` e Filtro de Import (`E11`):**
   - *O Cilium BGP Control Plane v2 (`CiliumBGPPeerConfig`) possui campos para `maximum-prefix` ou filtro de importação de rotas recebidas?*
   - *O que acontece quando um Customer Edge (CE) anuncia `50`, `200` ou `300` prefixos diretamente para o Cilium OSS `1.20.2` vs. para um Provider Edge (PE) FRR (`border1`) protegido por `ip prefix-list` e `neighbor maximum-prefix 100`?*
2. **Engenharia de Tráfego — Communities (`65400:100` / `65400:200`), `AS-path prepend` e `MED` (`E12`):**
   - *Quais atributos BGP o CRD `CiliumBGPAdvertisement` consegue emitir nativamente na origem e quais exigem tradução por `route-map` na borda?*
   - *É possível inverter dinamicamente o rack preferencial (`rack1` ↔ `rack2`) alterando apenas as communities no Kubernetes, sem tocar na configuração do roteador de borda?*
3. **Detecção de Falha Sub-Segundo — Timers BGP (`3/9 s` e `1/3 s`) vs. BFD `100 ms × 3` (`E10`):**
   - *Qual o limite físico de detecção de queda silenciosa (blackhole L2 sem `TCP RST`/`FIN`) usando apenas timers BGP no Cilium OSS `1.20.2`?*
   - *Onde o BFD (`Bidirectional Forwarding Detection`, RFC 5880) deve residir para cumprir o requisito `RNF05` de detecção e convergência em `< 1 s` (`< 1000 ms`)?*

---

## 2. Estudo `E11` — Limite de Prefixos (`maximum-prefix`) e Filtro de Import (`prefix-list`)

### 2.1 Auditoria do Schema CRD (`CiliumBGPPeerConfig` v2) e Invariante `R6`

A inspeção direta do schema OpenAPI v3 instalado no cluster (`kubectl get crd ciliumbgppeerconfigs.cilium.io -o json`) comprovou:
- **`ciliumbgppeerconfigs_import_or_maxprefix_fields = 0`**: O CRD `CiliumBGPPeerConfig` no Cilium `1.20.2` **não expõe** campos para `maximum-prefix`, `prefixLimit` ou políticas de importação (`importPolicy` / `prefix-list` de entrada).
- **Razão Arquitetural (CFP #34841):** O Cilium BGP Control Plane (baseado em GoBGP embarcado) foi projetado exclusivamente como **anunciador de rotas do cluster** (`PodCIDR`, VIPs `Service LoadBalancer`). Ele aceita updates na `Adj-RIB-In` em memória quando a AFI/SAFI é negociada, mas **nunca programa rotas BGP recebidas na FIB do kernel Linux** (`ip route show proto bgp` = `0` rotas, invariante `R6=0`).

### 2.2 Matriz Experimental: Cilium Direto (Célula 1) vs. FRR Border PE (Célula 2)

O script [`e11-bgp-maxprefix-import-filter.sh`](../../studies/p005/arm-a-ebgp/e11-bgp-maxprefix-import-filter.sh) executou duas baterias comparativas contra o roteador de cliente `frr-e11-ce` (`AS 65511`):
- **Célula 1 (`p003-gw-worker2` `AS 65302` ↔ `frr-e11-ce` `AS 65511` em `10.255.211.0/30`):** Envio progressivo de `50`, `200` e `300` prefixos `198.18.x.y/32` + prefixo não declarado `198.51.100.99/32`.
- **Célula 2 (`border1` `AS 65400` ↔ `frr-e11-ce` `AS 65511` em `10.255.211.4/30`):** Protegido no `border1` por:
  - `ip prefix-list E11-IMPORT-ALLOW seq 10 permit 198.18.0.0/16 le 32`
  - `ip prefix-list E11-IMPORT-ALLOW seq 20 deny any`
  - `neighbor 10.255.211.6 maximum-prefix 100`

| Célula / Etapa | Esperado (Hipótese) | Observado ao Vivo (`vm-cilium`, `02-e11-maxprefix-import.txt`) | Veredito |
|---|---|---|---|
| **Célula 1 — Cilium Direto (`50`, `200`, `300` prefixos + `198.51.100.99/32`)** | Sessão permanece `established`; GoBGP armazena `51`, `201` e `301` rotas em `Adj-RIB-In`, mas instala **`0` rotas** no kernel Linux (`R6=0`). Sem `max-prefix` nativo. | `cell1_step_50/200/300_state=established`; `gobgp_rib_in_routes = 51 -> 201 -> 301` (incluindo `198.51.100.99/32`); **`kernel_proto_bgp_routes = 0`** em todas as etapas. Sessão primária `10.30.2.1:179` (`leaf2`) intacta. | **PASS** |
| **Célula 2A — FRR Border PE com `50` prefixos + `198.51.100.99/32`** | Sessão `Established`; `50` prefixos `198.18.1.1..50/32` aceitos na RIB/FIB; prefixo não declarado `198.51.100.99/32` rejeitado pela `prefix-list`. | `State/PfxRcd = 50`; `cell2a_border1_accepted_198_18 = 50`; consulta a `198.51.100.99/32` retornou **`% Network not in table`** (`rejected_198_51_100_99 = 0`). | **PASS** |
| **Célula 2B — FRR Border PE com `200` e `300` prefixos (`> max-prefix 100`)** | Ao cruzar o limiar de `100` prefixos, `border1` derruba automaticamente a sessão com estado **`Idle (PfxCt)`** e retira todas as rotas do CE. | Com `200` e `300` prefixos, `show bgp ipv4 unicast summary` em `border1` cravou **`State/PfxRcd = Idle (PfxCt)`** (`PfxSnt = 0`), protegendo integralmente a RIB do fabric. | **PASS** |

---

## 3. Estudo `E12` — Communities (`65400:100` / `65400:200`), `AS-path prepend` e `MED`: Marcar na Origem, Decidir na Borda

### 3.1 Capacidades Nativas de `CiliumBGPAdvertisement` vs. Tradução no PE

A auditoria do CRD `ciliumbgpadvertisements.cilium.io` (`03-e12-communities-prepend-med.txt`) confirmou:
- **`communities` e `localPreference` suportados (`mentions=20`):** O Cilium permite anexar communities padrão (`attributes.communities.standard`) e `localPreference` (útil apenas em iBGP) por anúncio selecionando serviços por `matchLabels` ou `matchExpressions`.
- **Sem suporte nativo a `AS-path prepend` ou `MED` (`mentions=0`):** O CRD v2 não possui campos para repetir o ASN local (`prepend`) nem para definir `Multi-Exit Discriminator (MED)`.
- **Padrão de Arquitetura ("Marcar na Origem, Decidir na Borda"):** O Cilium marca a intenção de engenharia de tráfego via **BGP Communities** na origem (`65400:100` = caminho primário; `65400:200` = caminho secundário/backup), e o roteador de borda (`border1`) traduz essas communities em `MED`, `AS-Path Prepend` ou `Local-Preference`.

### 3.2 Topologia e Resultados das 3 Células (`E12`)

Para o serviço `svc-e12` (VIP dedicado **`10.202.255.192/32`** com pods `e12-echo-rack1` no `p003-gw-worker` `AS 65301` e `e12-echo-rack2` no `p003-gw-worker2` `AS 65302`), duas sessões eBGP dedicadas foram estabelecidas entre os workers e `border1` (`AS 65400`), que por sua vez anuncia o VIP ao CE `frr-e12-ce` (`AS 65512`):

| Célula | Configuração | Esperado | Observado ao Vivo (`vm-cilium`, `03-e12-communities-prepend-med.txt`) | Veredito |
|---|---|---|---|---|
| **Célula 1 — Negativa (Sem `route-map` em `border1`)** | `rack1` anuncia `10.202.255.192/32` com `65400:100`; `rack2` anuncia com `65400:200`; `border1` sem `route-map` de entrada. | As communities chegam a `border1`, mas como comprimentos de AS-Path são iguais (`65301` vs `65302`), `border1` instala **ECMP de 2 vias** (`multipath`). | `border1` recebeu `Community: 65400:100` (`10.255.212.1`) e `Community: 65400:200` (`10.255.212.5`) e instalou ambos na FIB (`* 10.255.212.1 via e12r1b weight 1` e `* 10.255.212.5 via e12r2b weight 1`). | **PASS** |
| **Célula 2 — Positiva (`route-map` em `border1`: `65400:100` Primário / `65400:200` Secundário)** | `border1` aplica `RM-E12-RACK1-IN`, `RM-E12-RACK2-IN` e `RM-E12-TO-CE`: `65400:100` → `metric 10`; `65400:200` → `metric 200` + `as-path prepend 65302 65302`. | `border1` seleciona `rack1` (`10.255.212.1`) como único `best (AS Path)`; `10/10` requisições HTTP de `frr-e12-ce` caem em `e12-echo-rack1`. | `border1` FIB: único next-hop `10.255.212.1 via e12r1b`. `frr-e12-ce` recebeu `AS_PATH 65400 65301`. Tráfego real: **`e12-echo-rack1=10/10`, `e12-echo-rack2=0/10`**. | **PASS** |
| **Célula 3 — Inversão Dinâmica via CRD (Sem tocar em `border1`)** | `CiliumBGPAdvertisement`s atualizados no K8s: `rack1` passa a emitir `65400:200` e `rack2` passa a emitir `65400:100`. | Sem nenhuma alteração no FRR, `border1` rebaixa `rack1` (`65301 65301 65301`, `metric 200`) e promove `rack2` (`65302`, `metric 10`); `10/10` requisições vão para `e12-echo-rack2`. | `border1` FIB virou automaticamente para **`10.255.212.5 via e12r2b`**. `frr-e12-ce` passou a receber `AS_PATH 65400 65302`. Tráfego real: **`e12-echo-rack1=0/10`, `e12-echo-rack2=10/10`**. | **PASS** |

---

## 4. Estudo `E10` — Detecção de Falha sem e com BFD (`< 1 s`): Onde Ela Deve Viver

### 4.1 Metodologia e Injeção de Blackhole Silencioso L2/L3

Quando uma interface física cai com perda de portadora (link down), o kernel derruba a sessão imediatamente via fast-external-failover. Porém, em **conexões dedicadas mediadas por circuitos ópticos DWDM, túneis VLAN/QinQ ou switches L2 intermediários**, a falha típica é um **blackhole silencioso** (os pacotes passam a ser descartados no meio do caminho sem `TCP RST`, `TCP FIN` ou `ICMP Unreachable`).

O script [`e10-bgp-failure-detection-bfd.sh`](../../studies/p005/arm-a-ebgp/e10-bgp-failure-detection-bfd.sh) injeta esse blackhole silencioso aplicando `iptables -I INPUT -s <peer> -j DROP` e `iptables -I OUTPUT -d <peer> -j DROP` no enlace estudado e mede, com resolução de `20 ms` (`nsenter -t $PID -m -n -r /usr/bin/vtysh`), o tempo exato em milissegundos até a retirada da rota da RIB:

### 4.2 Comparativo Quantitativo das 3 Células (`E10`)

| Célula | Arquitetura e Timers | Esperado (Hipótese) | Observado ao Vivo (`vm-cilium`, `04-e10-failure-detection-bfd.txt`) | Atende `RNF05 (< 1 s)`? | Veredito |
|---|---|---|---|---|---|
| **Célula 1 — Cilium Direto (`3/9 s`)** | `p003-gw-worker2` (`AS 65302`) ↔ `frr-e10-ce` (`AS 65510`) com `keepAliveTimeSeconds: 3`, `holdTimeSeconds: 9`, `gracefulRestart: false`. | Retirada da rota `10.202.255.191/32` governada pela expiração do Hold Timer (`~8–9 s`). | **`c1_cilium_timers_3_9_ms = 8901 ms`** (`8,901 s`). | **NÃO (`8,90 s > 1,00 s`)** | **PASS** |
| **Célula 2 — Cilium no Piso da API (`1/3 s`) + Negativo (`hold=2 s`)** | Tentativa de `holdTimeSeconds: 2` seguida do mínimo permitido pela API (`keepAliveTimeSeconds: 1`, `holdTimeSeconds: 3`). Auditoria de BFD no CRD. | `holdTimeSeconds: 2` rejeitado pelo webhook/schema OpenAPI (`>= 3`); `0` campos BFD nos CRDs Cilium; convergência em `~3 s`. | `holdTimeSeconds: 2` rejeitado (`rc=1`: `should be greater than or equal to 3`); `c2_cilium_crd_bfd_fields = 0`; retirada da rota em **`c2_cilium_timers_1_3_ms = 3045 ms`** (`3,045 s`). | **NÃO (`3,05 s > 1,00 s`)** | **PASS** |
| **Célula 3 — FRR Border PE ↔ CE com BFD (`100 ms × 3`)** | `border1` (`AS 65400`) ↔ `frr-e10-ce` (`AS 65510`) com `bfdd` ativo (`receive-interval 100`, `transmit-interval 100`, `detect-multiplier 3`) + `neighbor bfd`. | BFD detecta o blackhole em `~300 ms`, notifica o `bgpd` via Zebra/IPC e retira `198.18.210.0/24` da RIB em **`< 1000 ms`**. | BFD comutou para `Status: down` (`Diagnostics: control detection time expired`) e retirou a rota da RIB em **`c3_border_bfd_100x3_ms = 359 ms`** (`0,359 s`). | **SIM (`359 ms < 1000 ms`)** | **PASS** |

### 4.3 Evidência Externa do `bfdd` (`border1`, `359 ms`)

```text
BFD Peers:
	peer 10.255.210.6 vrf default
		ID: 772634453
		Remote ID: 0 (3539377552 while Status: up)
		Active mode
		Status: down
		Downtime: 0 second(s)
		Diagnostics: control detection time expired
		Remote diagnostics: ok
		Peer Type: configured
		Local timers:
			Detect-multiplier: 3
			Receive interval: 100ms
			Transmission interval: 100ms
```

---

## 5. Síntese Arquitetural: Onde Cada Função BGP Deve Viver

| Função de Plano de Controle | Cilium OSS `1.20.2` (CRDs BGP v2 no Nó) | Roteador de Borda / PE FRR (`border1` / FRR no Nó) | Recomendação de Engenharia |
|---|---|---|---|
| **Anúncio de VIPs `LoadBalancer` e `PodCIDR`** | **Nativo** (`CiliumBGPAdvertisement`) | Repassa para CEs externos | Originar no Cilium com marcação por **BGP Communities**. |
| **Marcação de Preferência por Rack/Serviço (`Communities`)** | **Nativo** (`65400:100` primário, `65400:200` backup) | Traduz via `route-map` em `MED` / `AS-Path Prepend` / `Local-Pref` | Permite failover/drain controlado via GitOps no K8s (`E12` Célula 3) sem reconfigurar os roteadores de borda. |
| **Proteção `maximum-prefix` e Filtro `prefix-list` de Import (`E11`)** | **Ausente** (porém protegido contra poluição da FIB porque `R6=0`) | **Nativo** (`ip prefix-list` + `neighbor maximum-prefix N`) | Aplicar obrigatoriamente na borda PE (`border1`) para derrubar sessões abusivas (`Idle (PfxCt)`) antes que atinjam o fabric. |
| **Detecção de Falha Sub-Segundo (`< 1 s`, `RNF05` — `E10`)** | Limitado ao piso do Hold Timer BGP (**`3045 ms`** com `1/3 s`; **`8901 ms`** com `3/9 s`) | **Nativo via BFD** (**`359 ms`** com `100 ms × 3`) | Terminar o enlace dedicado do cliente (CE) no PE/Border FRR (ou em daemon FRR/bird no nó) com **BFD `100 ms × 3`** habilitado. |
