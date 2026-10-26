# Estudos P006 — Datapath Avançado, Multi-Cluster, SRv6, Tetragon e Live Migration (`E26–E33`)

Este diretório reúne os scripts reproduzíveis e manifestos declarativos do plano **`P006`** (`E26–E33`), executados em **3 braços paralelos** (`Braço A ∥ Braço B ∥ Braço C` de saneamento estático):

- **`arm-a-datapath/` (Braço A — Datapath eBPF, Aceleração de Borda e QoS — `E26–E29`):**
  - `e26-lb-xdp-dsr-maglev.sh` + `01-e26-lb-xdp-dsr-maglev.yaml` (**`E26`** — LoadBalancer XDP + DSR Direct Server Return & Maglev Consistent Hashing vs SNAT)
  - `e27-big-tcp-netkit-jumbo.sh` + `01-e27-big-tcp-jumbo.yaml` (**`E27`** — BIG TCP GSO/GRO > 64 KiB + `netkit` + Jumbo MTU 9000)
  - `e28-bandwidth-manager-edt-bbr.sh` + `01-e28-bandwidth-manager-edt-bbr.yaml` (**`E28`** — Bandwidth Manager EDT + BBR vs CUBIC e Pacing eBPF por Pod)
  - `e29-bgp-unnumbered-l2-announcements.sh` + `01-e29-bgp-unnumbered-l2-announcements.yaml` (**`E29`** — BGP Unnumbered RFC 5549/8950 Extended Next-Hop vs L2 Announcements)
- **`arm-b-platform/` (Braço B — Multi-Cluster, SRv6, Segurança eBPF e Virtualização — `E30–E33`):**
  - `e30-clustermesh-bgp-mcs.sh` + `01-e30-clustermesh-bgp-mcs.yaml` (**`E30`** — Cilium Cluster Mesh, Serviços Globais `service.cilium.io/global` / MCS-API e `CiliumNetworkPolicy` Cross-Cluster sobre o Fabric BGP)
  - `e31-srv6-l3vpn-frr.sh` + `01-e31-srv6-l3vpn.yaml` (**`E31`** — SRv6 L3VPN `seg6local` / `encap seg6` Kernel Linux + FRR para Multi-Tenancy sem VXLAN `End.DT4`)
  - `e32-tetragon-ebpf-runtime.sh` + `01-e32-tetragon-ebpf-runtime.yaml` (**`E32`** — Tetragon: Observabilidade e Enforcement eBPF em Runtime / Syscalls / Sockets `TracingPolicy`)
  - `e33-kubevirt-live-migration-bgp-evpn.sh` + `01-e33-kubevirt-live-migration.yaml` (**`E33`** — KubeVirt Live Migration sob Tráfego Contínuo: `Cilium B /32 BGP` vs `OVN-Kubernetes EVPN Type-2 MAC-IP Mobility`)

## Invariantes Operacionais

1. Todos os scripts suportam `--dry-run` (imprime o plano completo e sai com `rc=0` sem mutar nada).
2. Todos os scripts validam o UID de `k01` (`635e7274-5597-40c7-9de5-b1fbe3d68b22`, estritamente **somente-leitura**) e de `p003-gw` (`6bb32e0f-71f9-4558-ae33-356ba2250c26`), além de `MemAvailable >= 4 GiB` e `R6=0` no `p003-gw`.
3. Todo estudo executa `cleanup` / rollback determinístico via `trap EXIT` e comprova os canários de `k01` (`10/10`) e `p003-gw` (`30/30` HTTP, `10/10` TCP, `10/10` UDP) ao final.
