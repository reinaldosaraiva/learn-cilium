# Scripts Reprodutíveis por Sessão — Trilha `P003` (`s004`..`s014`)

Cada subdiretório (ou script de topo) reproduz os casos experimentais da sessão correspondente no sandbox `p003-gw` (e `p003-os` para a trilha híbrida OpenStack), preservando o cluster `k01` intocado (`R1`).

## Índice de Sessões e Casos (`s004` a `s014`)

| Sessão / Diretório | Estudo | Escopo e Entregáveis Reprodutíveis | Dossiê Público |
|---|---|---|---|
| `s004-setup.sh`, `s004-probe.sh`, `s004-record-ports.sh`, `s004-cleanup.sh` | **`E02`** (`P003-S004`) | Matriz L4 (`TCPRoute`/`UDPRoute`) + `hostNetwork` vs Envoy listener e tabela de portas observadas | [`02-l4-hostnetwork.md`](../../../docs/estudos/02-l4-hostnetwork.md) |
| `s005-setup.sh`, `s005-probe.sh` | **`E03` Parte 1** (`P003-S005`) | Fixture controlada HTTP/gRPC ExternalAuth (`ext_authz`) e correlação por `X-Lab-Request-ID` | [`03-externalauth.md`](../../../docs/estudos/03-externalauth.md) |
| `s006-run.sh` | **`E03` Parte 2** (`P003-S006`) | Matriz fail-closed de ExternalAuth (timeout, serviço ausente, `ReferenceGrant` cross-namespace) | [`03-externalauth.md`](../../../docs/estudos/03-externalauth.md) |
| `s007-run.sh` | **`E04` Parte 1** (`P003-S007`) | WireGuard Transparent Encryption (`cilium_wg0`) sobre Native Routing (`W0`/`W1`/`W2`) | [`04-wireguard.md`](../../../docs/estudos/04-wireguard.md) |
| `s008-run.sh` | **`E04` Parte 2** (`P003-S008`) | WireGuard sobre VXLAN Overlay, overhead combinado de MTU e análise da issue `#41635` | [`04-wireguard.md`](../../../docs/estudos/04-wireguard.md) |
| [`s009/`](s009/) (`s009-run.sh`, `01-namespaces-psa.yaml`..`10-tls.yaml`) | **`E05`** (`P003-S009`) | Isolamento Multi-Tenant L3/L4/L7, RBAC, PSA, anti-bypass e geração efêmera de TLS | [`05-tenants.md`](../../../docs/estudos/05-tenants.md) |
| [`s010/`](s010/) (`s010-run.sh`, `values-m24.yaml`, `values-m32.yaml`) | **`E06`** (`P003-S010`) | Comparação controlada de IPAM (`M24` `/24` vs `M32` `/32` `multi-pool`) e impacto na FIB | [`06-ipam.md`](../../../docs/estudos/06-ipam.md) |
| [`s011/`](s011/) ([`s011/README.md`](s011/README.md)) | **`E07` Descoberta & Testbed** (`P003-S011`) | Provisionamento e configuração do testbed OpenStack DevStack containerizado (`p003-os`) | [`07-openstack.md`](../../../docs/estudos/07-openstack.md) |
| [`s012/`](s012/) ([`s012/README.md`](s012/README.md)) | **`E07` Matriz Híbrida** (`P003-S012`) | Pareamento BGP `qrouter` ↔ `border1`, diagnóstico KVM/OVS e matriz híbrida `C01–C11` | [`07-openstack.md`](../../../docs/estudos/07-openstack.md) |
| [`s013/`](s013/) (`01-preflight.sh`, `02-c01-c03.sh`, `03-c04-c08.sh`, `04-rollback.sh`) | **`E08`** (`P003-S013`) | Ciclo de vida e revogação/reuso de IP (`fromCIDR` stale vs identidade Kubernetes) | [`08-lifecycle.md`](../../../docs/estudos/08-lifecycle.md) |
| [`s014/`](s014/) (`01-relight-and-fix-dhcp.sh`..`04-c5-vm-outside-container.sh`) | **`E08` Síntese & `E09`/`C5`** (`P003-S014`..`S016`) | Remediação definitiva do RX da VM via KVM real no host (`C5`) e tráfego bidirecional `pod↔VM` | [`08-lifecycle-synthesis.md`](../../../docs/estudos/08-lifecycle-synthesis.md), [`09-vm-outside-container.md`](../../../docs/estudos/09-vm-outside-container.md) |

## Pré-requisitos e Invariantes

- **Cluster Sandbox:** `p003-gw` (`STUDY_KUBECONFIG=/root/.kube/p003-gw.config`, `STUDY_CONTEXT=kind-p003-gw`).
- **Canário Protegido (`R1`):** `k01` (`10/10` HTTP `200` antes e depois de cada bateria).
