# Estudos P005 — Execução em 4 Ondas Paralelas (`Braço A: eBGP` ∥ `Braço B: Datapath, Escala e Observabilidade`)

Este diretório armazena os scripts automatizados, idempotentes (com suporte a `--dry-run` e `trap cleanup EXIT`) e manifests declarativos do plano **`P005`**, cobrindo os 16 estudos avançados (`E09–E19` e `E21–E25`) do roadmap ([`docs/proximos-estudos.md`](../../docs/proximos-estudos.md)).

---

## Estrutura de Diretórios

```text
poc-k8s-fabric/studies/p005/
├── README.md
├── arm-a-ebgp/                           # Braço A — Conexão Dedicada eBGP (E09..E16, E18, E19)
│   ├── e19-bgp-idempotency-lifecycle.sh  # E19: Idempotência 10x, withdraw zero resíduo e reuso de VIP
│   ├── e09-bgp-md5-asn32.sh              # E09: TCP MD5 RFC 2385 + ASN 32-bit 4200000001 + rotação de chave
│   ├── e11-bgp-maxprefix-import-filter.sh # E11: max-prefix e prefix-list de import (Cilium vs FRR PE)
│   ├── e12-bgp-communities-prepend-med.sh # E12: Communities 65400:100/200, AS-path prepend e MED
│   ├── e10-bgp-failure-detection-bfd.sh   # E10: Detecção de falha (Timers 3/9s e 1/3s vs BFD < 1s)
│   ├── e13-bgp-dual-border-failover.sh    # E13: Redundância Dual-Border ECMP, failover e Graceful Restart
│   ├── e14-bgp-ipv6-e2e-vip.sh            # E14: Sessão eBGP IPv6 dedicada e VIP fd14::a/128 fim a fim
│   └── manifests/
│       ├── 01-e19-workloads.yaml
│       ├── 02-e19-svc-a-bundle.yaml
│       ├── 03-e19-svc-b-bundle.yaml
│       ├── 04-e12-communities-workloads.yaml
│       ├── 05-e13-dual-border-failover.yaml
│       └── 06-e14-ipv6-e2e-vip.yaml
└── arm-b-datapath/                       # Braço B — Datapath eBPF, Escala e Observabilidade (E17, E21..E25)
    ├── e23-netkit-vs-veth.sh             # E23: netkit vs veth (microbenchmark kernel + Cilium + CNP deny)
    ├── e21-ipam-burst-scale.sh           # E21: IPAM burst 16 pods (kubernetes vs multi-pool cold/warm + exaustão)
    ├── e22-xlb-ebpf-socket-lb-vs-envoy.sh # E22: XLB sockmap/bpf_sock_ops/sk_msg L7 vs SocketLB L4 vs Envoy L7
    ├── e17-e25-bgp-hubble-observability.sh # E17+E25: Observabilidade BGP (3 leituras) + Hubble L3/L4/L7/TLS/Prometheus
    └── manifests/
        ├── 01-e23-pods-and-cnp.yaml
        ├── 02-e21-multipool-burst.yaml
        ├── 03-e22-xlb-vs-envoy.yaml
        └── 04-e17-e25-observability.yaml
```

---

## Onda 1 (`P005-S001`), Onda 2 (`P005-S002`) e Onda 3 (`P005-S003`) — Scripts e Execução

| Onda | Estudo | Script | Modo Dry-Run | Execução ao Vivo (`vm-cilium`) | Dossiê Público |
|---|---|---|---|---|---|
| `S001` | **`E19`** | [`arm-a-ebgp/e19-bgp-idempotency-lifecycle.sh`](arm-a-ebgp/e19-bgp-idempotency-lifecycle.sh) | `bash arm-a-ebgp/e19-bgp-idempotency-lifecycle.sh --dry-run` | `sudo bash arm-a-ebgp/e19-bgp-idempotency-lifecycle.sh` | [`docs/estudos/19-bgp-idempotency-md5-asn32.md`](../../docs/estudos/19-bgp-idempotency-md5-asn32.md) |
| `S001` | **`E09`** | [`arm-a-ebgp/e09-bgp-md5-asn32.sh`](arm-a-ebgp/e09-bgp-md5-asn32.sh) | `bash arm-a-ebgp/e09-bgp-md5-asn32.sh --dry-run` | `sudo bash arm-a-ebgp/e09-bgp-md5-asn32.sh` | [`docs/estudos/19-bgp-idempotency-md5-asn32.md`](../../docs/estudos/19-bgp-idempotency-md5-asn32.md) |
| `S001` | **`E23`** | [`arm-b-datapath/e23-netkit-vs-veth.sh`](arm-b-datapath/e23-netkit-vs-veth.sh) | `bash arm-b-datapath/e23-netkit-vs-veth.sh --dry-run` | `sudo bash arm-b-datapath/e23-netkit-vs-veth.sh` | [`docs/estudos/21-netkit-vs-veth-ipam-burst.md`](../../docs/estudos/21-netkit-vs-veth-ipam-burst.md) |
| `S001` | **`E21`** | [`arm-b-datapath/e21-ipam-burst-scale.sh`](arm-b-datapath/e21-ipam-burst-scale.sh) | `bash arm-b-datapath/e21-ipam-burst-scale.sh --dry-run` | `sudo bash arm-b-datapath/e21-ipam-burst-scale.sh` | [`docs/estudos/21-netkit-vs-veth-ipam-burst.md`](../../docs/estudos/21-netkit-vs-veth-ipam-burst.md) |
| `S002` | **`E11`** | [`arm-a-ebgp/e11-bgp-maxprefix-import-filter.sh`](arm-a-ebgp/e11-bgp-maxprefix-import-filter.sh) | `bash arm-a-ebgp/e11-bgp-maxprefix-import-filter.sh --dry-run` | `sudo bash arm-a-ebgp/e11-bgp-maxprefix-import-filter.sh` | [`docs/estudos/11-bgp-maxprefix-communities-bfd.md`](../../docs/estudos/11-bgp-maxprefix-communities-bfd.md) |
| `S002` | **`E12`** | [`arm-a-ebgp/e12-bgp-communities-prepend-med.sh`](arm-a-ebgp/e12-bgp-communities-prepend-med.sh) | `bash arm-a-ebgp/e12-bgp-communities-prepend-med.sh --dry-run` | `sudo bash arm-a-ebgp/e12-bgp-communities-prepend-med.sh` | [`docs/estudos/11-bgp-maxprefix-communities-bfd.md`](../../docs/estudos/11-bgp-maxprefix-communities-bfd.md) |
| `S002` | **`E10`** | [`arm-a-ebgp/e10-bgp-failure-detection-bfd.sh`](arm-a-ebgp/e10-bgp-failure-detection-bfd.sh) | `bash arm-a-ebgp/e10-bgp-failure-detection-bfd.sh --dry-run` | `sudo bash arm-a-ebgp/e10-bgp-failure-detection-bfd.sh` | [`docs/estudos/11-bgp-maxprefix-communities-bfd.md`](../../docs/estudos/11-bgp-maxprefix-communities-bfd.md) |
| `S002` | **`E22`** | [`arm-b-datapath/e22-xlb-ebpf-socket-lb-vs-envoy.sh`](arm-b-datapath/e22-xlb-ebpf-socket-lb-vs-envoy.sh) | `bash arm-b-datapath/e22-xlb-ebpf-socket-lb-vs-envoy.sh --dry-run` | `sudo bash arm-b-datapath/e22-xlb-ebpf-socket-lb-vs-envoy.sh` | [`docs/estudos/22-xlb-ebpf-socket-lb-vs-envoy.md`](../../docs/estudos/22-xlb-ebpf-socket-lb-vs-envoy.md) |
| `S003` | **`E13`** | [`arm-a-ebgp/e13-bgp-dual-border-failover.sh`](arm-a-ebgp/e13-bgp-dual-border-failover.sh) | `bash arm-a-ebgp/e13-bgp-dual-border-failover.sh --dry-run` | `sudo bash arm-a-ebgp/e13-bgp-dual-border-failover.sh` | [`docs/estudos/13-bgp-dual-border-gr-ipv6.md`](../../docs/estudos/13-bgp-dual-border-gr-ipv6.md) |
| `S003` | **`E14`** | [`arm-a-ebgp/e14-bgp-ipv6-e2e-vip.sh`](arm-a-ebgp/e14-bgp-ipv6-e2e-vip.sh) | `bash arm-a-ebgp/e14-bgp-ipv6-e2e-vip.sh --dry-run` | `sudo bash arm-a-ebgp/e14-bgp-ipv6-e2e-vip.sh` | [`docs/estudos/13-bgp-dual-border-gr-ipv6.md`](../../docs/estudos/13-bgp-dual-border-gr-ipv6.md) |
| `S003` | **`E17` + `E25`** | [`arm-b-datapath/e17-e25-bgp-hubble-observability.sh`](arm-b-datapath/e17-e25-bgp-hubble-observability.sh) | `bash arm-b-datapath/e17-e25-bgp-hubble-observability.sh --dry-run` | `sudo bash arm-b-datapath/e17-e25-bgp-hubble-observability.sh` | [`docs/estudos/17-bgp-hubble-observability.md`](../../docs/estudos/17-bgp-hubble-observability.md) |

---

## Invariantes Operacionais (`R1`–`R6`)

1. **`R1` (Canário `k01` intocado):** Todo script valida o UID `635e7274-5597-40c7-9de5-b1fbe3d68b22` no início e no fim.
2. **`R2` (`--dry-run` e Rollback):** Nenhum recurso de estudo permanece após o término (`trap cleanup EXIT`).
3. **`R3` (`MemAvailable >= 4,00 GiB`):** Verificado antes e depois de cada bateria.
4. **`R6` (`proto bgp = 0`):** Zero rotas BGP residuais no kernel Linux dos nós de `p003-gw`.
