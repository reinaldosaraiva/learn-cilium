# Estudo 26 (`E26` + `E30` + `Bloco C1`) — LoadBalancer eBPF (TCX/XDP, DSR vs SNAT & Maglev Consistent Hashing) e Cilium Cluster Mesh / MCS-API sobre Fabric BGP (`P006-S001`)

> **Status:** CONCLUÍDO (`PASS` em `P006-S001`, 26/10/2026)  
> **Ambiente de Execução:** `vm-cilium` (`p003-gw` Cilium `1.20.2` + `k01` canário read-only + `clab-p003-gw-fabric-border1` FRR)  
> **Artefatos Reprodutíveis:**
> - **Braço A (`E26`):** [`studies/p006/arm-a-datapath/01-e26-lb-xdp-dsr-maglev.yaml`](../../studies/p006/arm-a-datapath/01-e26-lb-xdp-dsr-maglev.yaml) e [`studies/p006/arm-a-datapath/e26-lb-xdp-dsr-maglev.sh`](../../studies/p006/arm-a-datapath/e26-lb-xdp-dsr-maglev.sh)
> - **Braço B (`E30`):** [`studies/p006/arm-b-platform/01-e30-clustermesh-bgp-mcs.yaml`](../../studies/p006/arm-b-platform/01-e30-clustermesh-bgp-mcs.yaml) e [`studies/p006/arm-b-platform/e30-clustermesh-bgp-mcs.sh`](../../studies/p006/arm-b-platform/e30-clustermesh-bgp-mcs.sh)
> - **Braço C (`Bloco C1`):** Correções críticas `A4–A8` e `A10–A12` de [`docs/revisao-projeto-2026-09-26.md`](../revisao-projeto-2026-09-26.md) (incluindo [`studies/p003/cases/s009/gen-tls.sh`](../../studies/p003/cases/s009/gen-tls.sh))

---

## 1. Fundamentação Científica, Papers de Referência e RFCs

A Onda 1 do plano `P006` conecta três pilares da literatura de redes de datacenters modernos e sistemas distribuídos ao plano de dados eBPF do Cilium `1.20.2`:

| Estudo | Paper / Especificação de Referência | Conceito Matemático / Arquitetural Testado no Lab |
|---|---|---|
| **`E26` (Maglev Consistent Hashing)** | **Eisenbud et al. (Google, USENIX NSDI 2016)** — *"Maglev: A Fast and Reliable Software Network Load Balancer"* | Anel de permutação primo de tamanho $M = 16381$ (ou $65537$) gerado por duas funções de hash independentes $(h_1, h_2)$ por backend, garantindo complexidade de busca $O(1)$ no mapa BPF e **zero rehash colateral** nos backends sobreviventes quando um pod é removido. |
| **`E26` (XDP / TCX & DSR vs SNAT)** | **Høiland-Jørgensen et al. (ACM CoNEXT 2018)** — *"The eXpress Data Path: Fast Programmable Packet Processing in the Operating System Kernel"* | Processamento de pacotes Norte-Sul em `TCX` / `XDP` (`kube-proxy-replacement=true`), contrastando o custo de estado de conntrack e perda de IP de origem em `SNAT` cross-node (`externalTrafficPolicy: Cluster`) com o anúncio BGP seletivo e preservação integral de IP de origem em `externalTrafficPolicy: Local` / `DSR`. |
| **`E30` (Cluster Mesh & MCS-API)** | **Kubernetes KEP-1645 (Multi-Cluster Services API)** & **Cilium ClusterMesh Specification** | Particionamento do espaço de identidades de 24 bits (`cluster-id: 1..255` + 16 bits locais) e reconciliação de objetos `EndpointSlice` multi-cluster (`service.cilium.io/global: "true"`, `service.cilium.io/shared: "true"`) diretamente nos mapas eBPF de LoadBalancing (`ClusterIP` e `LoadBalancer` BGP), com failover Leste-Oeste e Norte-Sul sem DNS TTL. |

```mermaid
flowchart LR
  subgraph Client["Fabric BGP Externo (AS 65500 / 65203)"]
    C["clab-p003-gw-fabric-client<br/>198.19.0.10"]
    B1["border1 (FRR)<br/>ECMP / BGP Best-Path"]
    C --> B1
  end

  subgraph E26["Braço A — E26: Maglev (M=16381) & ETP=Cluster vs ETP=Local"]
    VIP26["VIP .26/32 (ETP=Cluster, random)<br/>AS 65301 + AS 65302"]
    VIP27["VIP .27/32 (ETP=Cluster, Maglev)<br/>Tabela [146..148]/v4: 185, 186, 187"]
    VIP28["VIP .28/32 (ETP=Local)<br/>Apenas AS 65302 (worker2)<br/>100% Client IP 198.19.0.10"]
  end

  subgraph E30["Braço B — E30: Cluster Mesh & MCS-API sobre BGP"]
    VIP30["VIP Global .30/32 + ClusterIP<br/>service.cilium.io/global=true"]
    ES1["EndpointSlice Local (cluster-id=2)<br/>10.245.2.19:8080"]
    ES2["EndpointSlice Remoto (MCS c2)<br/>10.245.1.180:8080"]
    VIP30 --> ES1
    VIP30 --> ES2
  end

  B1 --> VIP26
  B1 --> VIP27
  B1 --> VIP28
  B1 --> VIP30
```

---

## 2. Braço A (`E26`) — LoadBalancer eBPF (`TCX`/`XDP`), Preservação de IP de Origem (`Cluster` vs `Local`/`DSR`) e Resiliência Maglev

### 2.1 Hipóteses e Comportamento Esperado

1. **Configuração do Datapath (`cilium-config` e `cilium-dbg status`):**
   - **Esperado:** Com `kube-proxy-replacement=true` e `bpf-lb-algorithm=maglev` (`bpf-lb-maglev-table-size=16381`, `bpf-lb-algorithm-annotation=true`), o Cilium `1.20.2` anexa programas eBPF via `TCX` nas interfaces de dados (`eth0`, `eth1`) e programa a tabela de permutação Maglev de $16381$ slots para cada frontend.
2. **Anúncio BGP e Preservação de IP de Origem (`ETP=Cluster` vs `ETP=Local`):**
   - **Esperado:**
     - Nas VIPs `10.202.255.26/32` e `10.202.255.27/32` (`externalTrafficPolicy: Cluster`), todos os workers anunciam o `/32` via BGP; quando o pacote entra por `p003-gw-worker` e o backend sorteado está em `p003-gw-worker2`, o modo `snat` reescreve o IP de origem `198.19.0.10` para o IP do nó intermediário (`172.19.0.5` / `172.19.0.6`).
     - Na VIP `10.202.255.28/32` (`externalTrafficPolicy: Local`, selecionando apenas `e26-echo-w2a` em `p003-gw-worker2`), o Cilium BGP Control Plane suprime o anúncio no `worker1` (`AS 65301`) e anuncia `10.202.255.28/32` exclusivamente a partir do `worker2` (`AS 65302`), preservando **100% (`10/10`)** do IP original `198.19.0.10` no socket do pod.
3. **Consistência de Hashing Maglev sob Falha de Backend (`scale=0`):**
   - **Esperado:** Na tabela Maglev `[146]/v4` / `[148]/v4` com 3 backends ativos (`IDs 185, 186, 187`), ao remover o backend `186` (`e26-echo-w2b` escalado para `0`), **nenhum slot que apontava para `185` ou `187` sofre realocação entre si (`0` rehash colateral)** — exclusivamente os slots que continham `186` são preenchidos por `185` ou `187`, mantendo `20/20` HTTP `200`.

### 2.2 Resultados Observados na `vm-cilium` (`E26`)

| Dimensão Medida | Esperado | Observado ao Vivo (`vm-cilium`) | Veredito |
|---|---|---|---|
| **Estado do Datapath (`cilium-dbg status`)** | `KubeProxyReplacement: True`, `Attach Mode: TCX`, `Maglev (16381)` | `KubeProxyReplacement: True [eth0 172.19.0.5, eth1 10.30.1.12]`, `Attach Mode: TCX`, `Mode: SNAT`, `Backend Selection: Maglev (Table Size: 16381)` | **PASS** |
| **RIB BGP Externa (`border1`) — `.26` e `.27` (`ETP=Cluster`)** | Anunciadas via `AS 65301` (`worker1`) e `AS 65302` (`worker2`) | `*> 10.202.255.26/32` e `*> 10.202.255.27/32` via `65203 65600 65201 65301 i` (com caminho ECMP alternativo por `65202 65302`) | **PASS** |
| **RIB BGP Externa (`border1`) — `.28` (`ETP=Local` em `worker2`)** | Anunciada exclusivamente via `AS 65302` (`worker2`) | `*> 10.202.255.28/32` via `10.254.0.0`, `AS_PATH 65203 65600 65202 65302 i` (`0` rotas vindas de `65301`) | **PASS** |
| **Alcance HTTP Norte-Sul (`30x` por VIP)** | `30/30` HTTP `200` em `.26`, `.27` e `.28` | `.26`: `30/30` (`18` `w1`, `4` `w2a`, `8` `w2b`); `.27`: `30/30` (`12` `w1`, `11` `w2a`, `7` `w2b`); `.28`: `30/30` (`30` `w2a`) | **PASS** |
| **Preservação de IP (`/clientip`) em `.26` (`ETP=Cluster`)** | Mix de IP real (hit local) e IP do nó (hit cross-node) | `5/10` viram `198.19.0.10` (hit local) e `5/10` sofreram SNAT cross-node (`3x 172.19.0.5`, `2x 172.19.0.6`) | **PASS** |
| **Preservação de IP (`/clientip`) em `.28` (`ETP=Local`)** | `10/10` (`100%`) `198.19.0.10` sem SNAT | **`10/10` (`100%`) `198.19.0.10`**; confirmado em `cilium-dbg monitor --type trace`: `orig-ip 198.19.0.10: 198.19.0.10:37658 -> 10.245.1.217:8080 tcp SYN` | **PASS** |
| **Resiliência Maglev (`scale=0` no backend `186`)** | `0` rehash colateral nos slots `185` e `187`; `20/20` HTTP `200` | Antes: `[185 186 186 185 187 185 185 186 187 187 187 187 185 185 185 186...]`; Depois: `[185 187 185 185 187 185 185 187 187 187 187 187 185 185 185 187...]` (`100%` dos slots `185`/`187` intactos; `20/20` HTTP `200`) | **PASS** |

---

## 3. Braço B (`E30`) — Cilium Cluster Mesh, Serviços Globais (`MCS-API` / `EndpointSlice`) e `CiliumNetworkPolicy` Cross-Cluster sobre BGP

### 3.1 Hipóteses e Comportamento Esperado

1. **Identidade de Cluster e Espaço de Identidades (`k01` vs `p003-gw`):**
   - **Esperado:** Inspeção read-only confirma que `k01` opera com `cluster-name: dci-poc` e `cluster-id: 1`, enquanto `p003-gw` opera com `cluster-name: p003-gw`, `cluster-id: 2` e `max-connected-clusters: 255`, habilitando identidades de segurança disjuntas entre clusters.
2. **Fusão Multi-Cluster via `EndpointSlice` e Anúncio BGP Global (`10.202.255.30/32`):**
   - **Esperado:** Um serviço anotado com `service.cilium.io/global: "true"` e `service.cilium.io/shared: "true"` (`e30-global-svc`, VIP `10.202.255.30`) funde no mapa eBPF de LoadBalancing tanto o `EndpointSlice` local (`e30-global-svc-rtdbn`, `10.245.2.19:8080`) quanto o `EndpointSlice` remoto sincronizado (`e30-global-svc-remote-c2`, `10.245.1.180:8080`, gerenciado por `cilium-clustermesh-mcs`), anunciando `10.202.255.30/32` ao `border1` via BGP.
3. **Failover Cross-Cluster Automático (`scale=0` local) e Controles Negativos (`3A` e `3B`):**
   - **Esperado:**
     - Ao escalar `e30-global-local` para `0` réplicas, o mapa BPF de LB retira instantaneamente `10.245.2.19:8080` e mantém `10.245.1.180:8080`, atendendo `20/20` requisições Leste-Oeste (`e30-client`) e `20/20` requisições Norte-Sul (`clab-p003-gw-fabric-client` via BGP) no backend remoto.
     - **Controle Negativo 3A (`CiliumNetworkPolicy` `egressDeny`):** Aplicar `e30-deny-remote-cluster` (`egressDeny` para `cluster-origin: remote-c2`) bloqueia `5/5` conexões do `e30-client`, e sua remoção restaura `5/5` HTTP `200`.
     - **Controle Negativo 3B (Desexportação do `EndpointSlice` remoto):** Remover `e30-global-svc-remote-c2` com `local=0` esvazia a lista de backends em `cilium-dbg service list` e recusa `5/5` conexões Norte-Sul.

### 3.2 Resultados Observados na `vm-cilium` (`E30`)

| Célula / Etapa | Esperado | Observado ao Vivo (`vm-cilium`) | Veredito |
|---|---|---|---|
| **Identidades de Cluster (`k01` vs `p003-gw`)** | `cluster-id` distintos (`1` vs `2`) | `k01`: `cluster_name="dci-poc"`, `cluster_id="1"`; `p003-gw`: `cluster_name="p003-gw"`, `cluster_id="2"`, `max_connected_clusters="255"` | **PASS** |
| **Fusão BPF LB (`cilium-dbg service list`)** | 2 backends ativos (`local` + `remote-c2`) em `ClusterIP` e `LoadBalancer` | `ID 166` (`10.112.129.28:80/TCP`) e `ID 167` (`10.202.255.30:80/TCP`) com `1 => 10.245.1.180:8080` e `2 => 10.245.2.19:8080 (active)` | **PASS** |
| **RIB BGP Externa (`border1`)** | `10.202.255.30/32` instalada via BGP (`distance 20`) | Convergida na tentativa 3: `Routing entry for 10.202.255.30/32, Known via "bgp", distance 20, * 10.254.0.0, via eth1` | **PASS** |
| **Fase 1 (Local + Remoto Ativos)** | `20/20` HTTP `200` Leste-Oeste e `20/20` Norte-Sul | Leste-Oeste: `20/20` (`local_c1=15`, `remote_c2=5`); Norte-Sul BGP: `20/20` (`local_c1=10`, `remote_c2=10`) | **PASS** |
| **Fase 2 (Failover Cross-Cluster com `local=0`)** | `20/20` E-W e `20/20` N-S atendidos por `remote-c2` | `cilium-dbg service list` manteve apenas `1 => 10.245.1.180:8080 (active)`; **E-W `20/20` (`remote_c2=20/20`)** e **N-S BGP `20/20` (`remote_c2=20/20`)** | **PASS** |
| **Controle Negativo 3A (`CNP egressDeny` `remote-c2`)** | `5/5` bloqueados (`000`) + `5/5` recuperados (`200`) após remoção | `blocked=5/5` (`exit code 28` timeout) durante vigência da CNP; `recovered=5/5` HTTP `200` imediatamente após `kubectl delete cnp` | **PASS** |
| **Controle Negativo 3B (Desexportação `EndpointSlice`)** | `0` backends ativos no mapa BPF; `5/5` conexões recusadas | `ID 166` e `ID 167` com lista de backends vazia em `cilium-dbg service list`; `recusados=5/5` (`000`) | **PASS** |

---

## 4. Braço C (`Bloco C1`) — Saneamento Estático, Sintaxe e Segurança (`revisao-projeto-2026-09-26.md`)

Em paralelo com `E26` e `E30`, todos os 8 itens de severidade Alta do **Bloco C1** foram resolvidos e verificados estaticamente:

| ID | Arquivo(s) Saneado(s) | Problema Original | Solução Aplicada e Verificação | Status |
|---|---|---|---|---|
| **`A4`** | [`studies/p003/cases/s012/11-c1-fixes-router.sh`](../../studies/p003/cases/s012/11-c1-fixes-router.sh) | Aspas simples não balanceadas nas linhas 55–57 impediam a execução das seções `[d]–[f]`. | Substituído por script Python inline com heredoc/aspas duplas limpas; `bash -n` retorna `0` erros. | **RESOLVIDO** |
| **`A5`** | [`studies/p003/cases/s012/81-tap-location-diag.sh`](../../studies/p003/cases/s012/81-tap-location-diag.sh) | `tr "\n" " "` dentro de `"..."` na linha 73 e escape quebrado na linha 18 abortavam o script antes do teardown. | Corrigido para `tr '\n' ' '` e regex limpa; `bash -n` retorna `0` erros. | **RESOLVIDO** |
| **`A6`** | [`studies/p003/e08-lifecycle-synthesis.md`](../../studies/p003/e08-lifecycle-synthesis.md) | Cópia não sanitizada com UIDs reais, caminhos `/root/.kube` e referências a `plans/`. | Sincronizada com a versão sanitizada canônica [`docs/estudos/08-lifecycle-synthesis.md`](08-lifecycle-synthesis.md) (`0` ocorrências residuais). | **RESOLVIDO** |
| **`A7`** | [`studies/p003/cases/s009/10-tls.yaml`](../../studies/p003/cases/s009/10-tls.yaml) e [`studies/p003/cases/s009/gen-tls.sh`](../../studies/p003/cases/s009/gen-tls.sh) | 5 chaves privadas `-----BEGIN PRIVATE KEY-----` estáticas no git e certificados com validade expirada. | Chaves removidas de `10-tls.yaml` (`<GENERATED_BY_GEN_TLS_SH>`) e criado gerador idempotente `gen-tls.sh` (`openssl` efêmero em runtime, invocado automaticamente por `s009-run.sh`). | **RESOLVIDO** |
| **`A8`** | [`studies/p003/cases/s011/reconf-ovs.sh`](../../studies/p003/cases/s011/reconf-ovs.sh) | Senha do banco do DevStack hardcoded na linha 38. | Extraída dinamicamente de `/opt/stack/devstack/local.conf` (`DATABASE_PASSWORD`), com fallback para variável de ambiente. | **RESOLVIDO** |
| **`A10`** | [`studies/p003/cases/s004-record-ports.sh`](../../studies/p003/cases/s004-record-ports.sh) | Invocava `$K` (variável inexistente) em vez da função `K()`. | Corrigido para invocar a função `K` diretamente nas linhas 27–28. | **RESOLVIDO** |
| **`A11`** | [`studies/p003/cases/s013/02-c01-c03.sh`](../../studies/p003/cases/s013/02-c01-c03.sh) | `awk 'NR==2'` na linha 60 lia C01 como baseline e `NR==3` na linha 71 ficava vazio. | Corrigido para `NR==1` (baseline) e `NR==2` (C01). | **RESOLVIDO** |
| **`A12`** | [`studies/p003/cases/s010/s010-run.sh`](../../studies/p003/cases/s010/s010-run.sh) | Caminhos apontavam para `studies/p003/s010/` e mutação de `node.spec.podCIDR` falhava na API do K8s. | Caminhos corrigidos para `studies/p003/cases/s010/` e teste de `podCIDR` ajustado para validar a rejeição da API sem abortar. | **RESOLVIDO** |

---

## 5. Higiene Operacional e Invariantes Pós-Sessão (`P006-S001`)

- **Canário `k01`:** UID `635e7274-5597-40c7-9de5-b1fbe3d68b22` intocado (`10/10` HTTP `200` em `http://10.201.255.10/hostname`).
- **Sandbox `p003-gw`:** UID `6bb32e0f-71f9-4558-ae33-356ba2250c26` preservado (`30/30` HTTP `200` em `http://10.202.255.10:8080/hostname`), namespaces `p006-e26` e `p006-e30` removidos (`0` recursos transientes).
- **Invariante `R6`:** `0` rotas `proto bgp` residuais no kernel Linux dos 3 nós de `p003-gw`.
- **Memória Livre (`R3`):** `MemAvailable = 4.484.216 kB` (`4,28 GiB >= 4,00 GiB`).
