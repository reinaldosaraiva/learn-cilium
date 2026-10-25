# P004-S005 & P004-S006 — Braço Cilium A: KubeVirt v1.9.0 no cluster `p003-gw` (Cilium 1.20.2)

Scripts e manifests reprodutíveis das sessões **P004-S005** e **P004-S006** (`Verdict: PASS`, 24/10/2026)
para validar o **Braço Cilium A** (`KubeVirt v1.9.0` com KVM nativo em `/dev/kvm`
sobre `Cilium 1.20.2` com BGP Control Plane v2 e Multi-Pool IPAM) no cluster
Kind `p003-gw` (`p003-gw-control-plane`, `p003-gw-worker`, `p003-gw-worker2`).

## Estrutura

| Arquivo | Função |
|---|---|
| `00-prep-kubevirt-p003gw.sh` | Higiene de RAM (`labctl ovnk/evpn-fabric/mgc down`, `MemAvailable >= 4 GiB`) e instalação idempotente do KubeVirt `v1.9.0` (`useEmulation: false`, `LiveMigration`) no `p003-gw` |
| `v00-datapath-baseline.sh` | `V00`: gate de datapath KVM nativo (`pod/http-echo <-> vmi/vm-a`, `client-a -> vmi/vm-a:8080`, controle negativo `runStrategy=Halted`) |
| `v01-cilium-endpoint.sh` | `V01 (C01 / H1)`: verificação de `vmi/vm-a` como `CiliumEndpoint` (`cep_id`, `sec_identity`, `PodCIDR` vs `eth0` interna sob `masquerade`) |
| `v02-bgp-vip-reachability.sh` | `V02 (C02 / H1)`: `Service LoadBalancer vm-a-vip` (`10.202.255.20/32`) anunciado via BGP a `border1`, alcance externo e withdraw negativo |
| `v03-cnp-policy.sh` | `V03 (C03 / H1)`: `CiliumNetworkPolicy` por label (`fromEndpoints: app=p004-client-a`) e evidência `Policy denied` no `cilium-dbg monitor` |
| `v04-ip-reuse-policy.sh` | `V04 (C04 / Gate G01 / H2)`: reuso determinístico de IP (`CiliumPodIPPool p004-single-ip` `10.253.0.100/32`) entre `vm-a-reuse` e `vm-b-reuse` sob `fromEndpoints`, `fromCIDR` e ACL por IP (`-s 10.253.0.100/32`) |
| `v05-live-migration-oss.sh` | `V05 (C05 / H3)`: live migration entre `p003-gw-worker` e `p003-gw-worker2` em `ipam.mode=kubernetes`, medindo troca de podIP, queda de sessão TCP direta e reconvergência da VIP BGP |
| `v06-multipool-m32-bgp.sh` | `V06 (C06 / H4)`: `CiliumPodIPPool p004-vm` (`10.252.0.0/16`, `maskSize: 32`) anunciado via BGP a `border1`, live migration com troca de `/32`, retenção pelo piso `multiPoolPreAllocation` (`D-S010-1`) e rollback completo a `ipam.mode=kubernetes` (`D-S010-4`) |
| `v07a-overlapping-cidr-cneg.sh` | `V07-A (C07 / C-neg / H5)`: dois tenants (`p004-tenant-a` e `p004-tenant-b`) requisitando `CiliumPodIPPool`s com o mesmo CIDR (`10.253.10.0/24` e `10.253.10.100/32`) no Cilium OSS sob `ipam.mode=multi-pool` |
| `v08a-legacy-ip-cutover.sh` | `V08-A (C08 / H8)`: VM legada QEMU/KVM em `10.60.0.50/24` acessível de `198.19.0.10` (`30/30`), desligamento com corte (`0/5`), ativação de `CiliumPodIPPool/p004-legacy-ip` (`10.60.0.50/32`) via BGP a `border1` e subida de `vmi/vm-legacy-cutover` assumindo `10.60.0.50/32` (`30/30`), com rollback limpo |
| `manifests/` | Manifests YAML (`01-namespace-clients.yaml` a `08-v08a-legacy-cutover.yaml` e `values-p004-m32.yaml`) |

## Matriz de casos (`C01–C08` / `V00–V08A` / `C-neg`)

| Caso | Mapa | Descrição | Resultado ao vivo (`vm-cilium`, 24/10/2026) |
|---|---|---|---|
| `V00` | Gate KVM | `vmi/vm-a` (CirrOS `0.6.3`, `masquerade` sobre `/dev/kvm`) ↔ `pod/http-echo` e `client-a` | **PASS** (`30/30` RX/TX; `0/30` com `runStrategy=Halted`) |
| `V01` | `C01` / `H1` | `virt-launcher-vm-a` como `CiliumEndpoint` no `PodCIDR` `10.245.2.0/24` | **PASS** (`cep_id=242`, `sec_identity=172890`, `podIP=10.245.2.231`, guest `eth0=10.0.2.2/24`) |
| `V02` | `C02` / `H1` | `Service LoadBalancer vm-a-vip` (`10.202.255.20/32`) anunciado via BGP a `border1` | **PASS** (`30/30` HTTP 200 de `198.19.0.10`; withdraw em `8 s` → `0/30`) |
| `V03` | `C03` / `H1` | `CiliumNetworkPolicy` por label (`fromEndpoints: app=p004-client-a`) na VM | **PASS** (`client-a=30/30 PERMIT`, `client-b=0/30` com `18` drops `Policy denied`) |
| `V04` | `C04` / `G01` / `H2` | Reuso determinístico de IP (`10.253.0.100/32`) entre `vm-a-reuse` e `vm-b-reuse` | **PASS** (`vm-a-reuse sec_id=163024` → `30/30 ALLOW`; `vm-b-reuse sec_id=133690` c/ mesmo IP → `0/30 ALLOW` e `25` drops sob `fromEndpoints`, vs `30/30 ALLOW` sob ACL por IP) |
| `V05` | `C05` / `H3` | Live migration em `ipam.mode=kubernetes` (`worker` → `worker2`) | **PASS** (`10.245.2.190` → `10.245.1.23` em `22 s`; TCP p/ podIP antigo cai; VIP BGP `10.202.255.20/32` reconverge com `max_gap_ms=3000.0ms`) |
| `V06` | `C06` / `H4` | Multi-Pool `/32` BGP (`p004-vm`, `10.252.0.0/16`) + live migration + rollback | **PASS** (`10.252.0.23/32` → `10.252.0.4/32` em `border1`, `30/30` probes diretos; `/32` antigo retido por `multiPoolPreAllocation`; rollback limpo a `ipam.mode=kubernetes`) |
| `V07-A` | `C07` / `C-neg` / `H5` | Dois tenants requisitando o mesmo CIDR (`10.253.10.0/24`) e o mesmo IP (`10.253.10.100/32`) em `CiliumPodIPPool`s distintos sem VRF | **PASS (controle negativo)** (`0` webhook rejection; `10.253.10.100` em ambos os nós; colisão no mapa global `cilium_lxc` `endpoint 3893` local somberando `10.253.10.100/32` remoto) |
| `V08-A` | `C08` / `H8` | Cutover `/32` de VM legada (`10.60.0.50`) para KubeVirt via `CiliumPodIPPool` + BGP | **PASS** (`30/30` `LEGACY_VM_10.60.0.50` via `10.60.0.0/24` → `0/5` no corte → `30/30` `KUBEVIRT_VM_10.60.0.50` via `/32` BGP LPM em `border1` → rollback `30/30`) |

## Uso

```bash
# Validação estática sem mutação (--dry-run)
for s in poc-k8s-fabric/studies/p004/cilium-a/*.sh; do
  bash "$s" --dry-run
done
```

As evidências ao vivo estão em `poc-k8s-fabric/evidence/P004/S005/` e `poc-k8s-fabric/evidence/P004/S006/`,
sumarizadas em `plans/P004-S005-results.md`, `plans/P004-S006-results.md` e `docs/estudos/20-mgc-estado-parcial.md`.
