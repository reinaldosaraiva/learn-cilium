# Braço Cilium B — Cilium `1.20.2` + FRR `10.7.1` no Nó (`H6`, `H7`/`V09`, `V07-B`, `V08-B` e Invariante `R6`)

Este diretório contém os manifestos e scripts reproduzíveis do **Braço Cilium B** da investigação [`plans/P004/20-kubevirt-inv.md`] no cluster `p003-gw` (`Cilium 1.20.2` + `KubeVirt v1.9.0`), cobrindo a execução da [`P004-S006`] (`H6`) e os artefatos de `V09`/`H7`, `V07-B` e `V08-B` + transição para **OVN-Kubernetes (`C` / `D`)** na [`P004-S007`].

## Arquitetura do Braço Cilium B

No **Braço Cilium A**, o agente Cilium (`GoBGP` embarcado via BGP Control Plane v2) pareia diretamente com os switches ToR (`leaf1` `10.30.1.1:179` `AS 65201` e `leaf2` `10.30.2.1:179` `AS 65202`). Como o Cilium OSS `1.20.2` suporta apenas `ipv4/unicast` e `ipv6/unicast` nos seus `CiliumBGPPeerConfig`s (sem `l2vpn/evpn` nem VRFs BGP por tenant), o **Braço Cilium B** introduz um **DaemonSet FRR `10.7.1` por nó** (`kube-system/frr-node`, imagem pinada por digest `quay.io/frrouting/frr:10.7.1@sha256:9aeb1c4947207a3d405674c4de06451d8b7e0d00e6f7d1f8e61e7354273efc63`, conforme `Q3`):

1. **Loopback de Peering Local (`10.255.255.1/30` em `lo`, porta TCP `1790`):**
   - O `GoBGP` do Cilium usa ASN local `65311` (`rack1`) e `65312` (`rack2`) e pareia com `10.255.255.1:1790` (`CiliumBGPPeerConfig/local-frr-peer`).
   - O `bgpd` do FRR escuta em `1790` (`bgp listen range 10.255.255.0/30 peer-group CILIUM`), recebe as rotas de `PodCIDR` (`10.245.x.0/24`), `LoadBalancer VIP` (`10.202.255.10/32`, `10.202.255.20/32`) e `CiliumPodIPPool` (`/32` ou `/24`) anunciadas pelo Cilium e as redistribui para os ToRs (`leaf1`/`leaf2` na porta `179`) com `next-hop-self force` (`10.30.1.11`, `10.30.1.12`, `10.30.2.11`).
2. **Invariante `R6` (Proteção do Datapath eBPF na Tabela Default do Kernel Linux):**
   - O `zebra`/`bgpd` na VRF `default` aplica `table-map RM-NO-KERNEL` + `ip protocol bgp route-map RM-NO-KERNEL` (`deny 10`), garantindo **`0` rotas `proto bgp` instaladas na tabela `main` do kernel Linux** (`ip -4 route show table main proto bgp | wc -l == 0`).
   - Dessa forma, o FRR atua como *route-server/speaker* BGP/EVPN na VRF default sem sobrescrever as rotas locais de endpoints gerenciadas pelo `cilium-agent` (`lxc*`).
3. **Extensão `V09` (`H7` — EVPN Type 5 por Tenant em VRFs Dedicadas):**
   - Enquanto a VRF `default` permanece protegida por `RM-NO-KERNEL`, o FRR `10.7.1` instancia VRFs Linux dedicadas por tenant (`vrf-tenant-a` `table 10100` `L3VNI 10100` `RT 65000:10100` e `vrf-tenant-b` `table 10200` `L3VNI 10200` `RT 65000:10200`) e anuncia rotas **EVPN Type 5 (`[5]`)** sobre VXLAN (`vxlan-10100`, `vxlan-10200`, porta `4789`).
   - Limite arquitetural frente ao **Braço OVN-Kubernetes (`C` / `D`)**: no Cilium OSS `1.20.2`, a interface primária `eth0` de Pods e VMIs KubeVirt continua vinculada ao mapa eBPF global `cilium_lxc` na VRF `default`; portanto, o isolamento VRF/EVPN Type 5 no Braço Cilium B exige interfaces secundárias/auxiliares ou migração para **OVN-Kubernetes (`C` / `D`)** quando o requisito é `UDN`/`CUDN` primária declarativa com `same-CIDR` e Live Migration L2 nativa.

## Artefatos neste Diretório

| Arquivo | Papel | Sessão |
|---|---|---|
| [`manifests/01-frr-node-daemonset.yaml`](manifests/01-frr-node-daemonset.yaml) | `ConfigMap/frr-node-config` + `DaemonSet/frr-node` (`H6`, BGP IPv4 Unicast + `RM-NO-KERNEL` `R6`) | `P004-S006` |
| [`manifests/02-cilium-bgp-local-frr.yaml`](manifests/02-cilium-bgp-local-frr.yaml) | `CiliumBGPPeerConfig/local-frr-peer` (`10.255.255.1:1790`) + `CiliumBGPClusterConfig` (`rack1` `AS 65311`, `rack2` `AS 65312`) | `P004-S006` |
| [`manifests/03-frr-evpn-type5-vrf.yaml`](manifests/03-frr-evpn-type5-vrf.yaml) | `ConfigMap/frr-node-evpn-config` + `DaemonSet/frr-node` com VRFs `vrf-tenant-a` (`VNI 10100`) e `vrf-tenant-b` (`VNI 10200`) + EVPN Type 5 (`V09`/`H7`) | `P004-S007` |
| [`00-deploy-frr-node-h6.sh`](00-deploy-frr-node-h6.sh) | Automação E2E de `H6` (convergência `10s`, `R6=0`, `30/30` Pod VIP + VM VIP, controle negativo e rollback) | `P004-S006` |
| [`01-v09-evpn-type5-tenant-h7.sh`](01-v09-evpn-type5-tenant-h7.sh) | Automação de `V09`/`H7` (EVPN Type 5 por tenant em `vrf-tenant-a`/`vrf-tenant-b`, JSON `R8`, `R6=0`, guardrail RT `65000:99900`) | `P004-S007` |
| [`02-v07b-overlapping-vrf-evpn.sh`](02-v07b-overlapping-vrf-evpn.sh) | Variante `V07-B` (sub-redes sobrepostas `10.253.10.0/24` e IP idêntico `10.253.10.100/24` isolados por VRF/EVPN Type 5 no FRR vs limite `cilium_lxc` em `eth0`) | `P004-S007` |
| [`03-v08b-legacy-cutover-frr.sh`](03-v08b-legacy-cutover-frr.sh) | Variante `V08-B` (cutover de IP legado `10.60.0.50/32` para KubeVirt VMI anunciado via FRR `10.7.1` no nó com `R6=0`) | `P004-S007` |

## Matriz de casos (`H6`, `V09`/`H7`, `V07-B`, `V08-B`)

| Caso | Mapa | Descrição | Resultado ao vivo (`vm-cilium`, 24/10/2026) |
|---|---|---|---|
| `H6` | Base Cilium B | `DaemonSet/frr-node` (`FRR 10.7.1`) pareando localmente em `10.255.255.1:1790` com Cilium e externamente em `:179` com `leaf1`/`leaf2` sob `RM-NO-KERNEL` (`R6`) | **PASS** (`convergência=10s`, `R6=0` rotas `proto bgp` em `table main`, `30/30` Pod VIP + `30/30` VM VIP `10.202.255.20/32`, withdraw `0/5`) |
| `V09` | `H7` | EVPN Type 5 (`[5]`) por tenant em VRFs dedicadas (`vrf-tenant-a` `VNI 10100` `RT 65000:10100` e `vrf-tenant-b` `VNI 10200` `RT 65000:10200`) sobre VXLAN | **PASS** (`type5_routes > 0` em JSON `R8`, `30/30` intra-VRF, `0/10` cross-VRF, guardrail RT errado `65000:99900` rejeitado, `R6=0`) |
| `V07-B` | `H5` + `H7` | Sub-redes sobrepostas (`10.253.10.0/24`) e IP idêntico (`10.253.10.100/24`) nos dois tenants isolados por VRF/EVPN no FRR vs limite `cilium_lxc` na `eth0` | **PASS (parcial arquitetural documentado)** (`30/30` intra-VRF para o mesmo IP `10.253.10.100` em A e B; `0/10` cross-VRF; `eth0` primária permanece na VRF `default`) |
| `V08-B` | `H8` + `H6` | Cutover `/32` de VM legada (`10.60.0.50`) para KubeVirt VMI anunciado via `Cilium -> FRR 10.7.1 no nó -> border1` sob `R6=0` | **PASS** (`30/30` legado → `0/5` corte → `30/30` `KUBEVIRT_VM_B_10.60.0.50` com `AS_PATH 65203 65600 65201 65301 65311` e `R6=0` → rollback `30/30`) |

## Evidências

- [`evidence/P004/S006/05-cilium-b-frr-h6.txt`] — Execução ao vivo de `H6` (`PASS`).
- [`evidence/P004/S007/01-baseline-s007.txt`] — Baseline read-only de `vm-cilium` na `P004-S007`.
- [`evidence/P004/S007/02-static-dryrun-s007.txt`] — Validação estática (`bash -n`, `shellcheck -x`) e `--dry-run` dos 4 scripts do Braço Cilium B.
- [`evidence/P004/S007/03-v09-evpn-type5.txt`] — Execução ao vivo de `V09`/`H7` (`PASS`).
- [`evidence/P004/S007/04-v07b-overlapping-vrf.txt`] — Execução ao vivo de `V07-B` (`PASS`).
- [`evidence/P004/S007/05-v08b-legacy-cutover-frr.txt`] — Execução ao vivo de `V08-B` (`PASS`).
- [`evidence/P004/S007/06-post-verify-capacity.txt`] e [`evidence/P004/S008/02-final-verify-g08.txt`] — Verificação pós-rollback e higiene operacional final (`G08`).
- Matriz Comparativa Final **Cilium A vs Cilium B**, **Blueprint de Transição para OVN-Kubernetes (`C` / `D`)** e **Síntese `INV × Equivalente Aberto` (`G07`)**: [`docs/estudos/20-dci-estado-parcial.md`](../../../docs/estudos/20-dci-estado-parcial.md) (§4–§8).

> **Referência privada.** Os identificadores de planos e evidências citados permanecem apenas como texto; os arquivos de origem são privados e não são publicados neste documento.
