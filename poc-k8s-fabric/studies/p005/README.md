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
│   └── manifests/
│       ├── 01-e19-workloads.yaml
│       ├── 02-e19-svc-a-bundle.yaml
│       └── 03-e19-svc-b-bundle.yaml
└── arm-b-datapath/                       # Braço B — Datapath eBPF, Escala e Observabilidade (E17, E21..E25)
    ├── e23-netkit-vs-veth.sh             # E23: netkit vs veth (microbenchmark kernel + Cilium + CNP deny)
    ├── e21-ipam-burst-scale.sh           # E21: IPAM burst 16 pods (kubernetes vs multi-pool cold/warm + exaustão)
    └── manifests/
        ├── 01-e23-pods-and-cnp.yaml
        └── 02-e21-multipool-burst.yaml
```

---

## Onda 1 (`P005-S001`) — Scripts e Execução

| Estudo | Script | Modo Dry-Run | Execução ao Vivo (`vm-cilium`) | Dossiê Público |
|---|---|---|---|---|
| **`E19`** | [`arm-a-ebgp/e19-bgp-idempotency-lifecycle.sh`](arm-a-ebgp/e19-bgp-idempotency-lifecycle.sh) | `bash arm-a-ebgp/e19-bgp-idempotency-lifecycle.sh --dry-run` | `sudo bash arm-a-ebgp/e19-bgp-idempotency-lifecycle.sh` | [`docs/estudos/19-bgp-idempotency-md5-asn32.md`](../../docs/estudos/19-bgp-idempotency-md5-asn32.md) |
| **`E09`** | [`arm-a-ebgp/e09-bgp-md5-asn32.sh`](arm-a-ebgp/e09-bgp-md5-asn32.sh) | `bash arm-a-ebgp/e09-bgp-md5-asn32.sh --dry-run` | `sudo bash arm-a-ebgp/e09-bgp-md5-asn32.sh` | [`docs/estudos/19-bgp-idempotency-md5-asn32.md`](../../docs/estudos/19-bgp-idempotency-md5-asn32.md) |
| **`E23`** | [`arm-b-datapath/e23-netkit-vs-veth.sh`](arm-b-datapath/e23-netkit-vs-veth.sh) | `bash arm-b-datapath/e23-netkit-vs-veth.sh --dry-run` | `sudo bash arm-b-datapath/e23-netkit-vs-veth.sh` | [`docs/estudos/21-netkit-vs-veth-ipam-burst.md`](../../docs/estudos/21-netkit-vs-veth-ipam-burst.md) |
| **`E21`** | [`arm-b-datapath/e21-ipam-burst-scale.sh`](arm-b-datapath/e21-ipam-burst-scale.sh) | `bash arm-b-datapath/e21-ipam-burst-scale.sh --dry-run` | `sudo bash arm-b-datapath/e21-ipam-burst-scale.sh` | [`docs/estudos/21-netkit-vs-veth-ipam-burst.md`](../../docs/estudos/21-netkit-vs-veth-ipam-burst.md) |

---

## Invariantes Operacionais (`R1`–`R6`)

1. **`R1` (Canário `k01` intocado):** Todo script valida o UID `635e7274-5597-40c7-9de5-b1fbe3d68b22` no início e no fim.
2. **`R2` (`--dry-run` e Rollback):** Nenhum recurso de estudo permanece após o término (`trap cleanup EXIT`).
3. **`R3` (`MemAvailable >= 4,00 GiB`):** Verificado antes e depois de cada bateria.
4. **`R6` (`proto bgp = 0`):** Zero rotas BGP residuais no kernel Linux dos nós de `p003-gw`.
