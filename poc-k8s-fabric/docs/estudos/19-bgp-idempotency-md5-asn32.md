# 19 — Ciclo de Vida e Idempotência BGP (`E19`) & Sessão eBGP Autenticada TCP MD5 com ASN de 32 bits (`E09`)

**Plano / Sessão:** `P005-S001` (Onda 1 Paralela — Braço A: Conexão Dedicada eBGP)  
**Cluster Alvo:** `p003-gw` (`kind-p003-gw`, UID `6bb32e0f-71f9-4558-ae33-356ba2250c26`, Cilium `1.20.2`)  
**Canário Protegido:** `k01` (`kind-k01`, UID `635e7274-5597-40c7-9de5-b1fbe3d68b22`, `10/10` HTTP `200`)  
**Scripts Reprodutíveis:**
- [`poc-k8s-fabric/studies/p005/arm-a-ebgp/e19-bgp-idempotency-lifecycle.sh`](../../studies/p005/arm-a-ebgp/e19-bgp-idempotency-lifecycle.sh)
- [`poc-k8s-fabric/studies/p005/arm-a-ebgp/e09-bgp-md5-asn32.sh`](../../studies/p005/arm-a-ebgp/e09-bgp-md5-asn32.sh)
- [`poc-k8s-fabric/studies/p005/arm-a-ebgp/manifests/`](../../studies/p005/arm-a-ebgp/manifests/)

---

## 1. Contexto e Perguntas de Engenharia

Em ambientes de **Conexão Dedicada (Direct Connect / Interconnect)** operados via GitOps (ArgoCD, Flux ou pipelines declarativos), os recursos do **Cilium BGP Control Plane v2** (`CiliumBGPClusterConfig`, `CiliumBGPPeerConfig`, `CiliumBGPAdvertisement` e `CiliumLoadBalancerIPPool`) são reconciliados continuamente. Duas perguntas operacionais fundamentais precisam de resposta quantitativa antes de expor circuitos dedicados de clientes:

1. **Idempotência, Zero Resíduo e Reuso de VIP (`E19`):**
   - *A reaplicação declarativa repetida (`kubectl apply` 10 vezes seguidas) do conjunto completo de CRDs BGP causa flaps de sessão, incremento de `tableVersion` na RIB externa ou duplicação de políticas GoBGP?*
   - *A remoção de uma conexão/serviço dedicado limpa 100% do estado no Cilium Agent e na RIB do roteador de borda (`border1`), permitindo o reuso imediato do mesmo VIP `/32` por outro serviço sem respostas residuais (stale backends)?*
2. **Autenticação TCP MD5 (RFC 2385), ASN de 32 bits (RFC 6793) e Rotação de Chave (`E09`):**
   - *Como o Cilium `1.20.2` opera sessões eBGP autenticadas via `authSecretRef` (`bgp-secrets-namespace=kube-system`) contra um Customer Edge (CE) com ASN privado de 4 bytes (`4200000001`, RFC 6996)?*
   - *Qual o comportamento sob falha de autenticação (senha divergente ou `Secret` ausente) e qual o impacto nas sessões primárias do fabric Clos (`leaf1`/`leaf2`)?*
   - *Qual a janela real de convergência durante a rotação da chave TCP MD5 em produção?*

---

## 2. Estudo `E19` — Ciclo de Vida da Configuração BGP: Idempotência (10x), Zero Resíduo e Reuso de VIP

### 2.1 Metodologia e Topologia Experimental

No cluster `p003-gw`, dois deployments HTTP distintos foram instanciados no namespace `p005-e19` ([`01-e19-workloads.yaml`](../../studies/p005/arm-a-ebgp/manifests/01-e19-workloads.yaml)):
- `e19-echo-a` (respondendo `e19-echo-a-*` em `:8080/hostname`)
- `e19-echo-b` (respondendo `e19-echo-b-*` em `:8080/hostname`)

O bundle [`02-e19-svc-a-bundle.yaml`](../../studies/p005/arm-a-ebgp/manifests/02-e19-svc-a-bundle.yaml) inclui os CRDs estruturais do cluster (`CiliumBGPPeerConfig/fabric-peer`, `CiliumBGPAdvertisement/fabric-advertisements`, `CiliumBGPClusterConfig/rack1` e `rack2`, `CiliumLoadBalancerIPPool/p003-vips`) mais um `CiliumBGPAdvertisement/e19-vip-advertisement` (com community `65301:190`) e o `Service LoadBalancer svc-a` fixado no VIP dedicado **`10.202.255.190/32`**.

### 2.2 Esperado vs. Observado (`E19`)

| Fase do Ciclo | Esperado (Hipótese) | Observado ao Vivo (`vm-cilium`, `02-e19-bgp-idempotency.txt`) | Veredito |
|---|---|---|---|
| **1. Convergência Inicial (`svc-a`)** | VIP `10.202.255.190/32` anunciado com community `65301:190` até `border1`; `10/10` HTTP `200` (`e19-echo-a-*` em `/hostname`) a partir de `clab-p003-gw-fabric-client` (`198.19.0.10`). | Convergência em `border1` na tentativa 6 (+`4 s` de janela MRAI para acomodar ambos os racks Clos SR Linux); `SVC_A_INITIAL_HTTP_OK=10/10`. | **PASS** |
| **2. Idempotência Declarativa (`10x kubectl apply`)** | `0` diffs em `cilium-dbg bgp route-policies`, `0` diffs em `cilium-dbg bgp routes advertised ipv4 unicast` e `0` diffs na RIB JSON de `border1` (`version` da rota constante). | `ITER=2` a `ITER=10`: `diff_route_policies_total=0`, `diff_advertised_total=0`, `diff_border1_rib_total=0`. Versão da tabela BGP em `border1` permaneceu cravada em **`version: 488`** em todas as 10 iterações. | **PASS** |
| **3. Teardown e Auditoria de Zero Resíduo** | Após `kubectl delete` de `svc-a` e `e19-vip-advertisement`: `0` rotas anunciadas para `.190`, `0` route-policies `e19-vip-advertisement`, `0` entradas na RIB de `border1` e `0` rotas `proto bgp` no kernel (`R6=0`). | BGP `WITHDRAW` propagado através dos 3 saltos SR Linux (`leaf1/2 -> spine1/2 -> leaf3 -> border1`) em **`11 s`**. `ZERO_RESIDUE_AUDIT: cilium_advertised=0 cilium_policies=0 border1_rib=0 kernel_proto_bgp_R6=0`. | **PASS** |
| **4. Reuso Imediato do VIP (`svc-b`)** | Aplicação de [`03-e19-svc-b-bundle.yaml`](../../studies/p005/arm-a-ebgp/manifests/03-e19-svc-b-bundle.yaml) reutilizando `10.202.255.190/32` (`community 65301:190`) → `30/30` respostas `e19-echo-b-*` e `0/30` respostas antigas de `svc-a`. | VIP reinstalado na RIB de `border1` em `6 s`; `VIP_REUSE_AUDIT: svc_b_http_ok=30/30 svc_a_stale_responses=0/30`. | **PASS** |

> **Achado Operacional (MRAI em Clos Dual-Rack):** Quando um VIP anycast é anunciado simultaneamente por dois racks distintos (`rack1` `AS 65301` e `rack2` `AS 65302`), os dois caminhos atravessam `leaf1`/`leaf2` → `spine1`/`spine2` → `leaf3` → `border1` com um deslocamento de ~`2 s` devido ao timer de MRAI dos switches SR Linux. Aguardar `4 s` após a chegada do primeiro caminho estabiliza a tabela BGP externa (`version: 488`), confirmando que 10 reaplicações consecutivas dos CRDs não geram nenhum BGP `UPDATE` supérfluo.

---

## 3. Estudo `E09` — Sessão eBGP Autenticada (TCP MD5 RFC 2385) e ASN de 32 bits (`4200000001`)

### 3.1 Metodologia e Topologia Experimental

O script [`e09-bgp-md5-asn32.sh`](../../studies/p005/arm-a-ebgp/e09-bgp-md5-asn32.sh) instancia um roteador Customer Edge efêmero (`clab-p003-gw-fabric-frr-e09`, FRR `8.4.1`) conectado diretamente ao worker `p003-gw-worker2` (`AS 65302`) via enlace ponto a ponto `/30` (`e09p0` `10.255.209.1/30` ↔ `e09p1` `10.255.209.2/30`):
- **ASN Local (Cilium `p003-gw-worker2`):** `65302` (2 bytes)
- **ASN Remoto (`frr-e09`):** `4200000001` (4 bytes / 32 bits — RFC 6793 / RFC 6996)
- **Namespace de Secrets BGP no Cilium Agent:** `--bgp-secrets-namespace=kube-system`
- **Configuração de Peer (`CiliumBGPPeerConfig/e09-md5-peer`):** `authSecretRef: bgp-md5-secret-e09`, `connectRetryTimeSeconds: 3`, `keepAliveTimeSeconds: 3`, `holdTimeSeconds: 9`, `gracefulRestart.enabled: true` (`restartTimeSeconds: 15`).

### 3.2 Matriz Experimental: 4 Células (Positiva, 2 Controles Negativos e Rotação em Produção)

| Célula | Configuração | Esperado | Observado ao Vivo (`vm-cilium`, `03-e09-bgp-md5-asn32.txt`) | Veredito |
|---|---|---|---|---|
| **Célula 1 — Positiva (`MD5 + ASN 32-bit`)** | Chave `P005-E09-ValidKey` idêntica no Secret K8s e no FRR (`neighbor 10.255.209.1 password ...`), `peerASN: 4200000001`. | Sessão `Established`, troca de rotas IPv4 unicast e presença da opção **TCP Option 19 (`md5`)** nos pacotes na porta `179`. | Sessão `65302 <-> 4200000001` entrou em `established` em **`3 s`**. FRR aprendeu `10.202.255.10/32` e `10.245.1.0/24` via `10.255.209.1` (`AS_PATH 65302 i`). `tcpdump` comprovou `options [nop,nop,md5 shared secret ... a464304d90b9d6e91b0301b096a936c3]`. | **PASS** |
| **Célula 2 — Negativa (`Senha MD5 Divergente`)** | FRR alterado para `P005-E09-WrongKey` + reset da sessão; Cilium mantido com `P005-E09-ValidKey`. | Sessão com `frr-e09` bloqueada em `active`; contador kernel `TcpExtTCPMD5Failure > 0`; sessões primárias do fabric (`3/3`) intactas. | Sessão `10.255.209.2` caiu para `active (0s)` com `0` rotas recebidas/anunciadas; `frr_TcpExtTCPMD5Failure=2`; `primary_fabric_sessions_established=3/3` (`10.30.2.1:179` manteve `19h12m19s` de uptime sem flap). | **PASS** |
| **Célula 3 — Negativa (`Secret Inexistente`)** | `CiliumBGPPeerConfig/e09-md5-peer` aponta para `authSecretRef: bgp-md5-secret-inexistente`. | Comportamento fail-safe: Cilium Agent não sofre crash/restart (`restarts=0`), não abre sessão sem autenticação e preserva o fabric (`3/3`). | Sessão permaneceu em `active (0s)`; `cilium_agent_restarts_before=0`, `cilium_agent_restarts_after=0`; `primary_fabric_sessions_established=3/3`. | **PASS** |
| **Célula 4 — Rotação de Chave em Produção (`ValidKey -> RotatedKey-2026`)** | Atualização coordenada do Secret K8s e da senha no FRR para `P005-E09-RotatedKey-2026`. | Reestabelecimento automático da sessão com novo digest MD5 e anúncio de `198.18.209.0/24` com `AS_PATH 4200000001` (`0xfa56ea01`). | Sessão reestabelecida em **`rotation_and_reestablish_ms=9387` (`9,39 s`)**. `tcpdump` capturou BGP `UPDATE` com novo digest MD5 (`eae702565ef93b6084c2155059bcefc3`) e `AS Path (2), length: 6, Flags [TE]: 4200000001 (0x0201 fa56 ea01)`. | **PASS** |

### 3.3 Evidência de Pacotes (`tcpdump` — RFC 2385 TCP Option 19 + RFC 6793 4-byte ASN)

Durante a **Célula 4**, a captura externa na interface `e09p1` comprovou simultaneamente a assinatura TCP MD5 rotacionada e a codificação de 4 bytes do ASN `4200000001` (`0xfa56ea01` em hexadecimal: `250 * 256^3 + 86 * 256^2 + 234 * 256 + 1 = 4200000001`):

```text
18:18:30.455889 IP (tos 0xc0, ttl 1, id 49061, offset 0, flags [DF], proto TCP (6), length 257)
    10.255.209.2.179 > 10.255.209.1.60757: Flags [P.], seq 1715216884:1715217081, ack 2289328783, win 502,
    options [nop,nop,md5 shared secret not supplied with -M, can't check - eae702565ef93b6084c2155059bcefc3], length 197: BGP
	Update Message (2), length: 55
	  Origin (1), length: 1, Flags [T]: IGP
	  AS Path (2), length: 6, Flags [TE]: 4200000001
	    0x0000:  0201 fa56 ea01
	  Next Hop (3), length: 4, Flags [T]: 10.255.209.2
	  Updated routes:
	    198.18.209.0/24
```

---

## 4. Recomendações de Produção para Conexões Dedicadas

1. **GitOps Seguro:** Os CRDs `CiliumBGPClusterConfig`, `CiliumBGPPeerConfig` e `CiliumBGPAdvertisement` são **estritamente idempotentes** no Cilium `1.20.2`. Loops de reconciliação periódica não geram churn de BGP `UPDATE` nem alteram a versão da RIB nos roteadores de borda.
2. **Isolamento de Falhas por Peer:** Erros de credencial TCP MD5 (`TcpExtTCPMD5Failure`) ou `Secret` ausente ficam confinados à máquina de estados do neighbor afetado, com zero impacto nas sessões uplink ToR (`leaf1`/`leaf2`).
3. **Rotação de Senha MD5:** Com `holdTimeSeconds: 9` e `connectRetryTimeSeconds: 3`, a atualização do `Secret` Kubernetes seguida da atualização no CE converge em **`~9,4 s`**. Com Graceful Restart habilitado (`restartTimeSeconds: 15`), o plano de encaminhamento mantém as rotas marcadas como stale durante a janela de troca da chave, evitando perda de pacotes se não houver `clear bgp` destrutivo.
