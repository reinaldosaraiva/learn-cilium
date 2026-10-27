# Estudos P004 (E20 v2) — Lab DCI Connect × INV × Equivalente Aberto

Artefatos reprodutíveis (scripts idempotentes com `--dry-run`, manifests YAML e templates FRR/OVN) do plano **P004** (`P004-S001` a `P004-S008`, **PASS** em 25/10/2026), integrados ao CLI [`labctl`](../../labctl/README.md) e documentados na síntese consolidada [`docs/estudos/20-dci-estado-parcial.md`](../../docs/estudos/20-dci-estado-parcial.md) (§1–§8).

## Estrutura de Diretórios

| Diretório | Sessão | Escopo |
|---|---|---|
| [`ovn/`](ovn/README.md) | `P004-S002` | Réplica DCI Connect (`OVN 26.03.3` + `OVS 3.7.2` + `FRR 10.7.0` por VRF + cliente `AS 200`): casos `M01` (ECMP/withdraw/failover sob `A5`), `M02` (`gateway_mtu` 1500 vs 9000 sob `A6`), `M03` (EVPN Type 5 `VNI 50100` sob `A7`) e `X05` (isolamento de dois clientes com o mesmo CIDR `192.168.0.0/24` via VRF/EVPN) |
| [`evpn-fabric/`](evpn-fabric/) | `P004-S002` / `S003` | Templates de configuração FRR (`x05-*.conf`) e suporte ao fabric standalone `labctl evpn-fabric` (`VNI 10100`/`10200`) |
| [`ovnk/`](ovnk/README.md) | `P004-S003` | Braço OVN-Kubernetes (`Kind 3 nós` + `OVN-K v1.4.0` com `UDN`/`CUDN`/`EVPN`/`RouteAdvertisements` + `KubeVirt v1.9.0` em `/dev/kvm` + `frr-k8s v0.0.27`): casos `K01` (`same-CIDR` `10.100.0.0/24`), `K02` (live migration L2 preservando IP e sessão TCP), `K03` (`ClusterUserDefinedNetwork` EVPN Type 2/5) e `K04` (lift-and-shift `10.50.0.10/24`) |
| [`cases/`](cases/README.md) | `P004-S004` | Casos cruzados multi-plano (`X01–X04`, `X06`, `X07`, complementando `X05` de `S002`): tenant unificado `X01`, isolamento cross-plane `X02`, BGP community policy `X03`, guardrail RT errado `X04`, hub overlap admission `X06` e MAC-VRF Type 2 overlap `X07` |
| [`cilium-a/`](cilium-a/README.md) | `P004-S005` / `S006` | Braço Cilium A (`Cilium 1.20.2` + `KubeVirt v1.9.0` no cluster `p003-gw`, BGP Control Plane v2 nativo + Multi-Pool IPAM): casos `V00–V06` (`C01–C06`, incluindo `G01` em `V04`), `V07-A` (`C-neg` / `H5` colisão same-CIDR sem VRF) e `V08-A` (`H8` cutover `/32` de VM legada `10.60.0.50`) |
| [`cilium-b/`](cilium-b/README.md) | `P004-S006` / `S007` | Braço Cilium B (`Cilium 1.20.2` + `DaemonSet/frr-node` `FRR 10.7.1` por nó sob invariante `R6` com `RM-NO-KERNEL`): `H6` (peering local `:1790` + BGP externo `:179` com `R6=0`), `V09`/`H7` (EVPN Type 5 por tenant em `vrf-tenant-a`/`vrf-tenant-b`), `V07-B` (sub-redes sobrepostas `10.253.10.0/24` isoladas em VRF vs limite `cilium_lxc` na `eth0`) e `V08-B` (cutover `/32` `10.60.0.50` via FRR no nó) |
| [`host-installation/`](host-installation/) | `P004-S002` | Utilitários determinísticos com selftests para staging e sincronização de fontes revisadas de `X05` |

## Referências Cruzadas

- **Dossiê e Síntese Consolidada (§1–§8, Matriz `INV × Equivalente Aberto` `G07` e Critérios `INV-PoC-01..06`):** [`docs/estudos/20-dci-estado-parcial.md`](../../docs/estudos/20-dci-estado-parcial.md)
- **Resultados Numéricos Consolidados:** [`docs/lab-results.md`](../../docs/lab-results.md)
- **Módulo 13 do guia do estudante:** [`docs/lab-guide-student.md`](../../docs/lab-guide-student.md)
