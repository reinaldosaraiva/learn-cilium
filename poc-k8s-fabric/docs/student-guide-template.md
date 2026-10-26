# Template Estrutural de Apostila — Cilium 1.20.x & Fabric BGP/EVPN

> **Nota de Autoridade Documental (`v2.6.0`):**
> Este arquivo (`student-guide-template.md`) é o **esqueleto/template estrutural** utilizado para derivar novas apostilas e turmas de laboratório.
> A **apostila viva, completa e atualizada** do projeto — cobrindo os **37 estudos experimentais (`E01` a `E37`)** em `P001`–`P007` — reside em **[`poc-k8s-fabric/docs/lab-guide-student.md`](lab-guide-student.md)** (e no PDF compilado `output/pdf/cilium-lab-student-guide.pdf`).
> **Não edite este template para atualizar resultados do laboratório; atualize `lab-guide-student.md` e execute `make pdf`.**

---

## Como usar este Template para uma Nova Turma ou Variante de Lab

Substitua os placeholders `{{VARIAVEL}}` abaixo antes de distribuir ou gerar o PDF:

| Placeholder | Descrição | Valor Canônico (`lab-guide-student.md`) |
|---|---|---|
| `{{VERSAO}}` | Versão da apostila | `v2.6.0` |
| `{{DATA}}` | Data da edição | `2026-10-26` |
| `{{HOST_SSH}}` | Alvo SSH do laboratório | `ubuntu@<IP_VM_CILIUM>` |
| `{{CLUSTER_REF}}` | Cluster canário de referência | `k01` (`kind-k01`) |
| `{{CLUSTER_SANDBOX}}` | Cluster sandbox de estudos | `p003-gw` (`kind-p003-gw`) |
| `{{CILIUM_VERSION}}` | Versão do Cilium | `1.20.2` |
| `{{GATEWAY_API_VERSION}}` | Versão dos CRDs Gateway API | `v1.2.1` / `1.6.1` |

---

## Estrutura Padrão de Capítulos (Skeleton Pedagógico)

### Parte I — Fundamentos e Topologia Base (`P001`–`P002`)
1. **Visão Geral e Arquitetura Clos Spine-Leaf**
   - Topologia Containerlab (`{{CLUSTER_REF}}`): `spine1`, `spine2`, `leaf1` (`AS 65001`), `leaf2` (`AS 65002`), `leaf3` (`AS 65003`), `border1` (`AS 65100`).
   - Endereçamento Dual-Stack (`IPv4` + `IPv6`) e BGP Peering (`CiliumBGPClusterConfig`, `CiliumBGPPeerConfig`, `CiliumBGPAdvertisement`).
2. **Cenários Base (`A` a `D`)**
   - Cenário A: PodCIDR Native Routing (`/24` IPv4 + `/64` IPv6).
   - Cenário B: Service VIP Anycast ECMP (`/32` IPv4 + `/128` IPv6, `CiliumLoadBalancerIPPool`).
   - Cenário C: Multi-Rack + BFD Sub-Second Failover.
   - Cenário D: VXLAN Overlay vs Native Routing e Jumbo MTU.

### Parte II — Estudos de Fronteira em Sandbox (`P003`: `E01`–`E09`)
3. **Gateway API, HostNetwork, ExternalAuth e WireGuard (`E01`–`E04`)**
   - `E01`: Gateway API L7/L4 (`HTTPRoute`, `GRPCRoute`, `TLSRoute`, `TCPRoute`, `UDPRoute`) + BGP Anycast VIP.
   - `E02`: L4 HostNetwork vs Portas de Nó.
   - `E03`: Envoy ExternalAuth (`CiliumEnvoyConfig` + `ext_authz` fail-closed).
   - `E04`: WireGuard Transparent Encryption (`cilium_wg0`, overhead de MTU, Native vs VXLAN).
4. **Isolamento Multi-Tenant, IPAM `/32` e Híbrido OpenStack (`E05`–`E09`)**
   - `E05`: Multi-Tenancy L3/L4/L7, RBAC e `ReferenceGrant`.
   - `E06`: IPAM `multi-pool` `/24` vs `/32` e escala de FIB.
   - `E07`–`E09`: Integração Híbrida Kubernetes + OpenStack Neutron (`p003-os`), Segurança de Ciclo de Vida (`E08`) e KVM Real no Host (`C5`/`E09`).

### Parte III — Convergência EVPN/VXLAN, KubeVirt e Equivalente Aberto (`P004`: `E20`)
5. **Orquestração `labctl` e Arquitetura em 3 Planos (`mgc` × `evpn-fabric` × `ovnk` × `Cilium A/B`)**
   - Plano MGC (`OVN 26.03.3` + `FRR` por VRF: `M01`–`M03`, `X05`).
   - Plano OVN-Kubernetes (`UDN` + `EVPN` + `KubeVirt`: `K01`–`K04`, `X01`–`X07`).
   - Braço Cilium A (`KubeVirt` nativo: `V00`–`V08-A`) vs Braço Cilium B (`FRR 10.7.1` no nó: `H6`, `V09`/`H7`, `V07-B`, `V08-B`, invariante `R6=0`).

### Parte IV — Segurança Avançada, Resiliência e Operação (`P005`: `E09`–`E19` e `E21`–`E25`)
6. **BGP Avançado, Datapath e Plataforma (`E09`–`E19` e `E21`–`E25`)**
   - `E09`–`E12` & `E19`: eBGP TCP MD5 `RFC 2385` + ASN 32 bits (`E09`), BFD `< 1s` vs Timers (`E10`), `max-prefix` e filtros de import (`E11`), Communities/AS-path/MED (`E12`) e Idempotência 10x BGP (`E19`).
   - `E13`–`E18`: Dual-Border + Graceful Restart (`E13`), eBGP IPv6 `fd14::a/128` (`E14`), VRF por Tenant via Community (`E15`), Retorno PE/CE + `CiliumEgressGatewayPolicy` (`E16`), Observabilidade BGP Contínua (`E17`) e MTU 9000 + QinQ `802.1ad` + MACsec `802.1AE` vs WireGuard (`E18`).
   - `E21`–`E25`: Escala de Burst IPAM `kubernetes` vs `multi-pool` (`E21`), XLB L7 eBPF (`sockmap`) vs `SocketLB` vs `Envoy` (`E22`), `netkit` vs `veth` (`E23`), Dynamic Resource Allocation `resource.k8s.io/v1` (`E24`) e Microsserviços com Hubble L3/L4/L7 + Prometheus (`E25`).

### Parte V — Fronteiras de Alta Performance, Multi-Cluster, SRv6 e Runtime eBPF (`P006`: `E26`–`E33`)
7. **Datapath Avançado, SRv6, Tetragon e Live Migration (`E26`–`E33`)**
   - `E26` & `E30`: LoadBalancer XDP/TCX + DSR & Maglev vs Cluster Mesh & MCS-API.
   - `E27` & `E31`: BIG TCP (`GSO/GRO > 64 KiB`) + `netkit` vs SRv6 L3VPN (`seg6local End.DT4`).
   - `E28` & `E32`: Bandwidth Manager (`EDT` + `BBR`) vs Tetragon Runtime Security (`TracingPolicyNamespaced`).
   - `E29` & `E33`: BGP Unnumbered (`RFC 5549`/`8950`) + L2 Announcements vs KubeVirt Live Migration sob Tráfego Contínuo.

### Parte VI — Operação Zero-Loss BGP, Zero-Trust SPIFFE mTLS, Local Redirect e Dual-Homing (`P007`: `E34`–`E37`)
8. **Dreno BGP `RFC 8326`, Autenticação Mútua SPIFFE + WireGuard, `CiliumLocalRedirectPolicy` e Multus + `ipvlan L2/L3` (`E34`–`E37`)**
   - `E34` & `E35`: BGP Graceful Shutdown (`RFC 8326` `65535:0`, `0/150` perda) vs Cilium Mutual Auth (`SPIFFE` X.509 SVID mTLS + `cilium_wg0` WireGuard).
   - `E36` & `E37`: `CiliumLocalRedirectPolicy` (`serviceMatcher` + `addressMatcher` `169.254.20.10:8080`) vs Workloads Dual-Homed com Multus + `ipvlan mode l2/l3` vs `macvlan` (`MTU 9000` & Cloud L2 MAC Anti-Spoofing).

---

## Template de Exercício Prático (Copiar por Estudo)

```markdown
### Exercício {{ID_ESTUDO}} — {{TITULO_ESTUDO}}

- **Objetivo:** {{OBJETIVO_OBSERVAVEL}}
- **Script Reprodutível:** `{{CAMINHO_SCRIPT}}`
- **Dossiê Técnico:** [`{{DOSSIE_MD}}`](estudos/{{DOSSIE_MD}})

#### 1. Validação em Modo `--dry-run`
\`\`\`bash
bash {{CAMINHO_SCRIPT}} --dry-run
\`\`\`

#### 2. Execução ao Vivo e Coleta Externa
\`\`\`bash
sudo bash {{CAMINHO_SCRIPT}}
\`\`\`

#### 3. Critérios de Aceite (Positivo, Negativo e Rollback)
- **Controle Positivo:** {{CONTROLE_POSITIVO}}
- **Controle Negativo:** {{CONTROLE_NEGATIVO}}
- **Invariante Pós-Rollback:** `R6=0` (zero rotas BGP no kernel do nó) e canário `{{CLUSTER_REF}}` `10/10` HTTP `200`.
```
