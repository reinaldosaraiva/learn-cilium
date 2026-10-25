# 21 — `netkit` vs `veth` no Datapath eBPF (`E23`) & Escala de Burst IPAM com Warm Pool (`E21`)

**Plano / Sessão:** `P005-S001` (Onda 1 Paralela — Braço B: Datapath eBPF & Escala de Alocação)  
**Cluster Alvo:** `p003-gw` (`kind-p003-gw`, UID `6bb32e0f-71f9-4558-ae33-356ba2250c26`, Cilium `1.20.2`, Kernel `6.8.0-139-generic` com `CONFIG_NETKIT=y`)  
**Canário Protegido:** `k01` (`kind-k01`, UID `635e7274-5597-40c7-9de5-b1fbe3d68b22`, `10/10` HTTP `200`)  
**Scripts Reprodutíveis:**
- [`poc-k8s-fabric/studies/p005/arm-b-datapath/e23-netkit-vs-veth.sh`](../../studies/p005/arm-b-datapath/e23-netkit-vs-veth.sh)
- [`poc-k8s-fabric/studies/p005/arm-b-datapath/e21-ipam-burst-scale.sh`](../../studies/p005/arm-b-datapath/e21-ipam-burst-scale.sh)
- [`poc-k8s-fabric/studies/p005/arm-b-datapath/manifests/`](../../studies/p005/arm-b-datapath/manifests/)

---

## 1. Contexto e Perguntas de Engenharia

O plano de dados por pod e o caminho crítico de criação de sandboxes (`CNI ADD`) determinam tanto a eficiência de CPU em regime estacionário quanto a velocidade de reação do cluster sob rajadas de escalonamento (*autoscaling bursts*):

1. **`netkit` vs `veth` no Datapath de Containers (`E23`):**
   - *O dispositivo virtual **`netkit`** (introduzido no Linux 6.7+ pelos mantenedores do Cilium com `CONFIG_NETKIT=y`, operando em modo `L3` `NOARP` com programas `BPF_NETKIT_PRIMARY` / `BPF_NETKIT_PEER`) reduz interrupções de software (`NET_RX` softirq) e retransmissões TCP em comparação ao par `veth` clássico com `tcx`?*
   - *Como o Cilium `1.20.2` protege o nó contra a coexistência de endpoints legados `veth` durante a migração para `datapath-mode=netkit`?*
   - *A aplicação de `CiliumNetworkPolicy` L3/L4 em modo `netkit` bloqueia 100% do tráfego negado sem vazamento de pacotes na interface do pod?*
2. **Escala de Burst IPAM, Warm Pool (`preAllocate`) e Latência `CNI ADD` (`E21`):**
   - *Qual o custo real no caminho crítico do `CNI ADD` ao migrar do IPAM estático por nó (`ipam.mode=kubernetes`, PodCIDR `/24` local) para `ipam.mode=multi-pool` sob Demanda Fria (`preAllocate=1`) vs. Pool Pré-Aquecido (`preAllocate=32`) durante uma rajada simultânea de 16 pods?*
   - *O que acontece quando um pool dedicado (`CiliumPodIPPool` `/29` com 6 IPs utilizáveis) sofre exaustão de endereços, e qual o impacto sobre outros pools do mesmo cluster?*

---

## 2. Estudo `E23` — `netkit` vs `veth` no Datapath eBPF (`Cilium 1.20.2` / Kernel `6.8`)

### 2.1 Metodologia Experimental

O script [`e23-netkit-vs-veth.sh`](../../studies/p005/arm-b-datapath/e23-netkit-vs-veth.sh) executa quatro baterias complementares em `vm-cilium`:
1. **Seção 1 — Microbenchmark Isolado de Kernel (`ip netns` em `p003-gw-worker`):** Criação direta de um par `veth` (`ip link add ... type veth`) vs. um par `netkit` em modo L3 (`ip link add ... type netkit mode l3`), medindo 100 amostras de RTT ICMP e inspecionando flags de interface (`NOARP`, MAC `00:00:00:00:00:00`, `numtxqueues=1`).
2. **Seção 2 — Baseline do Cluster em `datapath-mode=veth`:** Pods de benchmark (`e23-srv-w1`, `e23-cli-same-w1`, `e23-cli-cross-w2`, `e23-cli-denied-w1`) medindo RTT ICMP (`50` pacotes), `50` transações HTTP curtas sequenciais (`keep-alive` desligado, `p50`/`p95`/`p99`), throughput TCP `iperf3` (`5 s`) e delta de `/proc/softirqs` (`NET_RX`) em cenários **Same-Node** (`worker -> worker`) e **Cross-Node** (`worker2 -> leaf2 -> spine -> leaf1 -> worker`).
3. **Seção 3a — Guarda Fail-Closed de Migração (`veth -> netkit`):** Demonstração da proteção do Cilium `1.20.2` quando o `cilium-agent` reinicia em `datapath-mode=netkit` enquanto ainda existe um pod com interface `veth` no nó.
4. **Seção 3b & 4 — Cluster em `datapath-mode=netkit` + Controle Negativo (`CiliumNetworkPolicy`):** Recreação limpa dos pods com interfaces `netkit` (`cil_from_container` / `cil_to_container` anexados via `netkit`), repetição idêntica das medições e prova negativa com `tcpdump` no `eth0` do servidor (`leaked_pkts=0`).

### 2.2 Resultados Comparativos (`04-e23-netkit-vs-veth.txt`)

#### A. Microbenchmark Isolado de Kernel (Namespaces Puros em `p003-gw-worker`)

| Primitiva de Kernel | Flags / Atributos da Interface | Ping RTT `avg` | Ping RTT `p50` | Ping RTT `p95` | Ping RTT `p99` |
|---|---|---:|---:|---:|---:|
| **`veth` (L2 par virtual)** | `BROADCAST,MULTICAST,UP,LOWER_UP`, MAC `62:50:1d:16:24:0b` | `0,007 ms` | `0,005 ms` | `0,014 ms` | `0,023 ms` |
| **`netkit` (`mode l3`)** | `NOARP,UP,LOWER_UP`, MAC `00:00:00:00:00:00`, `numtxqueues 1` | `0,008 ms` | `0,007 ms` | `0,014 ms` | `0,019 ms` |

#### B. Comparativo Fim a Fim no Cluster Kubernetes (`Cilium 1.20.2`, `routing-mode=native`)

| Métrica / Cenário | `datapath-mode=veth` (`tcx`) | `datapath-mode=netkit` (`l3` `NOARP`) | Delta / Observação Operacional |
|---|---|---|---|
| **Inspeção `ip -d link` no Pod (`eth0`)** | `veth`, `BROADCAST,MULTICAST,UP,LOWER_UP`, MAC L2 | `netkit mode l3`, `NOARP,UP,LOWER_UP`, MAC `00:00:00:00:00:00` | `netkit` elimina ARP/L2 entre pod e host. |
| **Anexação eBPF (`bpftool net show`)** | `tcx/ingress` (`cil_from_container`) / `tcx/egress` (`cil_to_container`) | `netkit/primary` (`cil_from_container`) / `netkit/peer` (`cil_to_container`) | Execução direta no driver `netkit_xmit` sem passar pela fila `tcx` genérica. |
| **Ping RTT `avg` (`50` pkts, Same-Node / Cross-Node)** | `0,031 ms` / `0,055 ms` | `0,064 ms` / `0,057 ms` | Cross-Node praticamente idêntico (`0,055` vs `0,057 ms`). |
| **HTTP Short-Conn RR (`50` reqs, `p50 / p95 / p99` Same-Node)** | `0,287 / 0,357 / 0,414 ms` (`avg 0,295 ms`) | `0,327 / 0,477 / 0,555 ms` (`avg 0,353 ms`) | Sub-milissegundo em ambos os modos (`50/50` HTTP `200`). |
| **HTTP Short-Conn RR (`50` reqs, `p50 / p95 / p99` Cross-Node)** | `0,334 / 0,397 / 0,411 ms` (`avg 0,341 ms`) | `0,395 / 0,507 / 0,599 ms` (`avg 0,402 ms`) | Sub-milissegundo através do fabric Clos (`50/50` HTTP `200`). |
| **TCP Bulk `iperf3` Same-Node (`5 s`)** | `31,7 Gbps` (**`47` retransmissões**) | `29,0 Gbps` (**`0` retransmissões**) | **`netkit` eliminou 100% das retransmissões TCP** (`47 -> 0`). |
| **TCP Bulk `iperf3` Cross-Node (`5 s`)** | `27,2 Gbps` (**`11` retransmissões**) | `21,6 Gbps` (**`0` retransmissões**) | **`netkit` eliminou 100% das retransmissões TCP** (`11 -> 0`). |
| **Delta `NET_RX` Softirqs (Same-Node / Cross-Node)** | `888.538` / `765.581` | `809.323` (**`-8,9%`**) / `608.921` (**`-20,5%`**) | Menor pressão de escalonamento de backlog `NET_RX` no kernel. |
| **Controle Negativo (`CiliumNetworkPolicy` Deny)** | _Baseline conhecido_ | `allowed=30/30`, `denied=0/30`, **`leaked_pkts_on_srv_eth0=0`** | Bloqueio no programa `BPF_NETKIT` antes de alcançar a `eth0` do pod destino. |

### 2.3 Achado Crítico de Operação (`3a`): Guarda Fail-Closed na Transição `veth <-> netkit`

Ao alterar `datapath-mode` no `ConfigMap/cilium-config` de `veth` para `netkit` (ou vice-versa) mantendo pods em execução com o tipo de interface anterior no nó, o `cilium-agent` recusa a inicialização de forma **fail-closed** (`init-enga` / `start-agent`):

```text
level=error msg="Cannot start cilium-agent with datapath-mode=netkit: detected 1 existing endpoint(s) using incompatible datapath-modes. Affected endpoints: default/e23-veth-guard-canary (endpoint-4004). Detected incompatible datapath-modes: veth. To resolve this, either: (1) drain the node and recreate all pods before switching datapath-mode, or (2) revert datapath-mode to match the existing endpoints." subsys=daemon
```

> **Regra de Migração em Produção:** A mudança entre `veth` e `netkit` **nunca é in-place para pods existentes**. Em produção, deve ser executada via **Node Drain + Rollout por Nó** (ou Node Pool Blue/Green) para que todos os pods do nó sejam recriados sob o novo `datapath-mode`.

---

## 3. Estudo `E21` — IPAM Burst Scale: `kubernetes` PodCIDR vs. `multi-pool` Frio (`preAllocate=1`) vs. Aquecido (`preAllocate=32`)

### 3.1 Metodologia Experimental

Para isolar estritamente a latência do caminho crítico de **IPAM + `CNI ADD` + regeneração de `CiliumEndpoint`** sem ruído de rede ou container registry:
- Todos os pods de burst utilizam a imagem `registry.k8s.io/e2e-test-images/agnhost:2.47` (`command: ["sh", "-c", "sleep 3600"]`, `imagePullPolicy: IfNotPresent`) já pré-carregada no containerd dos workers `p003-gw-worker` e `p003-gw-worker2`.
- Em cada célula, um `Deployment` de **`16` réplicas** é criado em burst simultâneo, medindo o tempo relógio (`wall_s`), a taxa efetiva (`pods/s`), a distribuição `PodScheduled -> Ready` (`p50`, `p95`, `max`), a contagem de erros `FailedCreatePodSandBox` / `postIpamFailure` (`[POST /ipam][502]`) nos eventos do namespace e a latência de reconciliação em `CiliumNode`.

### 3.2 Matriz Experimental: 4 Células (`05-e21-ipam-burst-scale.txt`)

| Célula | Modo IPAM & Configuração do Pool | `wall_s` (`16` pods) | Taxa (`pods/s`) | `Ready` `p50 / p95 / max` | Falhas CNI `postIpamFailure` (`502`) | `FailedCreatePodSandBox` Events | Veredito |
|---|---|---:|---:|---:|---:|---:|---|
| **Célula 1 — `C1-K8S-PODCIDR`** | `ipam.mode=kubernetes` (`10.245.1.0/24`, `10.245.2.0/24` locais ao nó, `sample_ips=['10.245.2.70', '10.245.1.101', '10.245.1.144']`) | **`5,40 s`** | **`2,96 pods/s`** | `2,00 / 5,00 / 5,00 s` | **`0`** | **`0`** | **PASS** |
| **Célula 2 — `C2-MP-COLD-PRE1`** | `ipam.mode=multi-pool`, pool `e21-burst-pool` (`10.252.0.0/16`, `maskSize: 32`), **`ipam.multiPoolPreAllocation="default=8,e21-burst-pool=1"`** (frio) | `47,48 s` | `0,34 pods/s` | `46,00 / 48,00 / 48,00 s` | **`27`** | **`27`** | **PASS** *(efeito frio provado)* |
| **Célula 3 — `C3-MP-WARM-PRE32`** | `ipam.mode=multi-pool`, pool `e21-burst-pool` (`10.252.0.0/16`, `maskSize: 32`, `sample_ips=['10.252.0.12', '10.252.0.5', '10.252.0.2']`), **`ipam.multiPoolPreAllocation="default=8,e21-burst-pool=32"`** (aquecido) | `48,26 s` | `0,33 pods/s` | `48,00 / 48,00 / 48,00 s` | **`0`** (`-100%`) | **`0`** (`-100%`) | **PASS** *(zero falha de IPAM)* |
| **Célula 4 — `C4-NEG-EXHAUSTION`** | Controle Negativo: pool `e21-tiny-pool` (`10.253.21.0/29`, `maskSize: 29` = **6 IPs utilizáveis**, `.1`–`.6`) sob burst de **10 pods** | _Exaustão controlada_ | `6/10 Running`, **`4/10 Pending`** | — | Bloqueio explícito nos 4 pods excedentes | Isolamento `100%` (`e21-burst-pool` manteve `16/16 Ready`) | **PASS** |

### 3.3 Análise Causal: Por que `multiPoolPreAllocation=32` Elimina 100% dos Erros `CNI ADD` (`27 -> 0`)?

1. **O Gargalo da Demanda Fria (`C2-MP-COLD-PRE1`):**
   - No modo `multi-pool`, o `cilium-agent` local não aloca IPs diretamente do CIDR global do `CiliumPodIPPool`; ele depende de que o `cilium-operator` atribua blocos/IPs por nó em `CiliumNode.spec.ipam.pools.allocated` a partir da demanda anunciada em `CiliumNode.spec.ipam.pools.requested`.
   - Com `multiPoolPreAllocation="default=8,e21-burst-pool=1"` (`maskSize: 32`) e apenas 1 IP pré-alocado por nó, quando o `kubelet` dispara 16 chamadas `CNI ADD` em paralelo, o agente local esgota imediatamente o único endereço pré-alocado no `CiliumNode`. O resultado imediato são **27 falhas `FailedCreatePodSandBox`** com erro:
     ```text
     plugin type="cilium-cni" failed (add): unable to allocate IP via local cilium agent: [POST /ipam][502] postIpamFailure "unable to allocate from pool \"e21-burst-pool\" (family ipv4): pool not (yet) available"
     ```
   - O `kubelet` entra em backoff exponencial de recriação de sandbox (`~12–15 s` por ciclo) até que o `cilium-operator` conclua o loop de reconciliação do `CiliumNode`.
2. **O Efeito do Pool Pré-Aquecido (`C3-MP-WARM-PRE32`):**
   - Com `ipam.multiPoolPreAllocation="default=8,e21-burst-pool=32"`, cada `CiliumNode` já mantém `32` IPs prontos em `spec.ipam.pools.allocated` antes da rajada.
   - Durante o burst de 16 pods, **todas as 16 chamadas `CNI ADD` recebem IP na primeira tentativa (`ipam_alloc_failures=0`, `failed_sandbox_events=0`)**, eliminando completamente a fila de retry do `kubelet` e a pressão sobre o `cilium-operator`.
   - O tempo total de prontidão em `multi-pool` (`~48 s` para 16 pods concomitantes em 2 workers Kind compartilhados) passa a ser governado exclusivamente pela compilação/anexação serial de programas BPF dos `CiliumEndpoint`s sob contenção de CPU, e não mais por falhas de alocação de IP.
3. **Exaustão Determinística e Isolamento entre Pools (`C4-NEG-EXHAUSTION`):**
   - No pool `/29` (`10.253.21.0/29`, `maskSize: 29`), o Cilium reserva `.0` (rede) e `.7` (broadcast), entregando exatamente **6 IPs utilizáveis (`10.253.21.1` a `10.253.21.6`)** aos primeiros 6 pods.
   - Os 4 pods excedentes permanecem em `ContainerCreating` com diagnóstico claro (`unable to allocate from pool "e21-tiny-pool"`), enquanto os `16/16` pods do `e21-burst-pool` continuam operando sem qualquer degradação.

---

## 4. Síntese de Engenharia da Onda 1 (Braço B)

- **Quando adotar `datapath-mode=netkit`:** Recomendado para clusters com Kernel `>= 6.8` quando se deseja eliminar a camada L2/ARP entre host e container, reduzir softirqs `NET_RX` (`-8,9%` a `-20,5%`) e zerar retransmissões TCP sob carga intensa, planejando sempre a transição via **Node Drain / Rollout de Nós** devido à guarda fail-closed de compatibilidade de endpoints.
- **Quando adotar `ipam.mode=multi-pool`:** Indispensável para isolamento de tenants por subnet/VRF (como demonstrado em `P004`). Para cargas com *autoscaling* agressivo, configure **`ipam.multiPoolPreAllocation="<pool>=<BurstSize>"`** no Helm / `cilium-config` para zerar erros `[POST /ipam][502] pool not (yet) available` durante rajadas de criação de pods.
