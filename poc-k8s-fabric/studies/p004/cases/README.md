# P004-S004 — Casos Cruzados Multi-Plano (`X01–X04`, `X06`, `X07` + `X05`)

Scripts reprodutíveis da sessão **P004-S004** (`Verdict: PASS`, 24/10/2026) que integram simultaneamente a réplica **MGC Connect** (`labctl mgc`), o **Fabric EVPN** (`labctl evpn-fabric`) e o cluster **OVN-Kubernetes + KubeVirt** (`labctl ovnk`), provando os gates **`G04`** e **`G05`**.

> **Nota sobre `X05`:** O caso `X05` (dois clientes on-prem anunciando o mesmo CIDR `192.168.0.0/24` via MGC Connect com isolamento por VRF/EVPN) foi provado na sessão `P004-S002` (`c9d0e1` + rollback negativo `b8c9d0`) e seus scripts residem em [`../ovn/`](../ovn/README.md).

## Estrutura de Arquivos

| Arquivo | Caso | Descrição | Resultado ao vivo (`vm-cilium`, 24/10/2026) |
|---|---|---|---|
| `x01-unified-tenant.sh` | `X01` (`G04`) | Tenant unificado fim-a-fim: VM KubeVirt (`10.100.0.12`, UDN `ovnk`) ↔ Fabric EVPN (`VNI 10100`, `RT 65000:10100`) ↔ VPC OVN MGC (`192.168.100.10`) ↔ Cliente on-prem (`172.16.100.2`, `AS 200`) | **PASS** (`30/30` pings nos 3 pares; withdrawal BGP em `client-a` derruba tráfego `0/3` em `2s`) |
| `x02-cross-plane-isolation.sh` | `X02` (`G05`) | Isolamento cross-plane com **subnets sobrepostas** (`10.100.0.0/24` e `192.168.0.0/24` idênticas nos tenants A e B em todos os 3 planos) | **PASS** (`30/30` intra-A e intra-B com IPs idênticos; `0/3` cross-tenant; `0` pacotes vazados em `tcpdump` nas VXLANs `10100`/`10200`) |
| `x03-bgp-community-policy.sh` | `X03` | Política de exportação/importação por BGP standard community (`65000:100` vs `65000:999`) no spine/border do fabric | **PASS** (`10.250.100.0/24` c/ `65000:100` aceita e `30/30` ping; `10.250.200.0/24` c/ `65000:999` filtrada e `0/3` ping) |
| `x04-wrong-rt-guardrail.sh` | `X04` (`G05`) | Guardrail contra importação de Route Target incorreto (`RT 65000:10200` do Tenant B tentado na VRF do Tenant A) | **PASS** (rota `172.16.200.0/24` bloqueada por `route-map RM_GUARD_VRF_A_IMPORT deny 10`; `0` rotas vazadas na `vrf-tenant-a`; `0/3` ping) |
| `x06-hub-overlap-admission.sh` | `X06` (`G05`) | Controle de admissão no `vrf-hub` compartilhado quando `tenant-a` e `tenant-b` anunciam o mesmo prefixo `192.168.0.0/24` | **PASS** (detector e `RM_HUB_GUARD_OVERLAP` bloqueiam a colisão no `vrf-hub`; `10.100.10.0/24` e `10.100.20.0/24` não sobrepostos comunicam `30/30` c/ `hub` `10.254.0.1`) |
| `x07-macvrf-type2-overlap.sh` | `X07` (`G05`) | Domínio L2 estendido via EVPN Type 2 (`MAC-VRF`, `L2VNI 10100` vs `L2VNI 10200`) com **mesmo IP** (`10.100.0.50/24`) e **mesmo MAC** (`02:00:0a:64:00:32`) nos dois tenants | **PASS** (`30/30` ARP/ping L2 intra-VNI entre VM KubeVirt e host bare-metal simulado; `0` frames cross-VNI e FDBs isoladas) |

## Uso

```bash
# Validação estática sem mutação (--dry-run)
for s in poc-k8s-fabric/studies/p004/cases/x0*.sh; do
  bash "$s" --dry-run
done
```

Para os detalhes completos e evidências consolidadas, consulte [`docs/estudos/20-mgc-estado-parcial.md`](../../../docs/estudos/20-mgc-estado-parcial.md) e [`docs/lab-results.md`](../../../docs/lab-results.md).
