# P004-S003 — Braço OVN-Kubernetes (`C`): `UDN`, `EVPN`, `frr-k8s` e `KubeVirt v1.9.0` (`K01–K04`)

Scripts e manifests reprodutíveis da sessão **P004-S003** (`Verdict: PASS`, 23/10/2026) para validar o perfil [`labctl ovnk`](../../../labctl/labs/ovnk.sh) (`Kind 3 nós` + `OVN-Kubernetes v1.4.0` + `KubeVirt v1.9.0` em KVM nativo `/dev/kvm` + `frr-k8s v0.0.27`), provando o gate **`G03`**.

## Estrutura de Arquivos

| Arquivo | Função |
|---|---|
| `kind-3nodes.yaml` | Topologia Kind de 3 nós (`ovnk-control-plane`, `ovnk-worker`, `ovnk-worker2`) com CNI padrão desabilitada para instalação do OVN-Kubernetes |
| `values-udn-evpn.yaml` | Configuração de feature gates do OVN-Kubernetes (`enableMultiNetwork`, `enableNetworkSegmentation`, `enableRouteAdvertisements`, `enableEVPN`) |
| `udn-net-a.yaml` / `udn-net-b.yaml` | `UserDefinedNetwork`s Layer 2 primárias para `tenant-a` e `tenant-b` com **o mesmo CIDR** `10.100.0.0/24` (`K01`) |
| `vm-a-udn.yaml` / `vm-b-udn.yaml` | `VirtualMachine`s KubeVirt conectadas nativamente às UDNs com `binding: l2bridge` (`K01` / `K02`) |
| `k03-evpn-cudn.yaml` / `evpn-nad-fabric.yaml` | `ClusterUserDefinedNetwork` (`transport: EVPN`, `MAC-VRF VNI 10100`, `IP-VRF VNI 50100`, `RT 65000:10100`/`65000:50100`), `FRRConfiguration` e `RouteAdvertisements` (`K03`) |
| `k04-legacy-vm.yaml` | `VirtualMachine` KubeVirt preservando IP estático (`10.50.0.10/24`) e gateway legado (`10.50.0.1/24`) em lift-and-shift sem NAT (`K04`) |
| `k01.sh` | Automação e validação de `K01` (dois tenants com `10.100.0.0/24` sobreposto e VMs com IP `10.100.0.12` idêntico isolados em switches lógicos OVN distintos) |
| `k02.sh` | Automação e validação de `K02` (live migration KubeVirt entre `ovnk-worker` e `ovnk-worker2` preservando IP `10.100.0.12`, MAC e sessão TCP contínua com `0` drops) |
| `k03.sh` | Automação e validação de `K03` (exportação EVPN Type 2 e Type 5 para o `evpn-fabric` externo via `frr-k8s`) |
| `k04.sh` | Automação e validação de `K04` (lift-and-shift de VM legada `10.50.0.10/24` sem reendereçamento) |

## Matriz de Casos (`K01–K04` / Gate `G03`)

| Caso | Descrição | Resultado ao vivo (`vm-cilium`, 23/10/2026) |
|---|---|---|
| `K01` | Dois tenants (`tenant-a` e `tenant-b`) com `UserDefinedNetwork`s usando **o mesmo CIDR** (`10.100.0.0/24`) e VMs com **o mesmo IP** (`10.100.0.12`) | **PASS** (`30/30` intra-tenant; `0/3` cross-tenant; `0` pacotes vazados em captura; `logical_switch` OVN distintos por UDN) |
| `K02` | Live migration de VM KubeVirt (`ovnk-worker` → `ovnk-worker2`) sobre UDN Layer 2 (`l2bridge`) | **PASS** (IP `10.100.0.12` e MAC `02:00:0a:64:00:0c` preservados; `62/62` mensagens em sessão TCP contínua com `0` drops) |
| `K03` | `ClusterUserDefinedNetwork` com `transport: EVPN` (`VNI 10100`/`50100`) e anúncio BGP EVPN via `frr-k8s` | **PASS** (`RouteAdvertisements Accepted=True`; rotas EVPN Type 2 e Type 5 instaladas no ToR externo; `30/30` ping bidirecional) |
| `K04` | Lift-and-shift de VM legada (`10.50.0.10/24`, gw `10.50.0.1`) para UDN Layer 2 + EVPN | **PASS** (`30/30` ping externo para `10.50.0.10` preservando IP e MAC originais sem NAT) |

## Uso

```bash
# Subir e verificar o perfil ovnk via labctl
sudo LAB_ROOT=/opt/poc-k8s-fabric ./poc-k8s-fabric/labctl/labctl ovnk up
sudo LAB_ROOT=/opt/poc-k8s-fabric ./poc-k8s-fabric/labctl/labctl ovnk verify

# Validação estática sem mutação (--dry-run)
for s in poc-k8s-fabric/studies/p004/ovnk/k0*.sh; do
  bash "$s" --dry-run
done
```

Para a análise comparativa com os Braços Cilium A e B e o blueprint da arquitetura híbrida `D`, consulte [`docs/estudos/20-mgc-estado-parcial.md`](../../../docs/estudos/20-mgc-estado-parcial.md) (§5–§8).
