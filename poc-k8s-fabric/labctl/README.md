# labctl — lab-as-code (P004)

Sobe, verifica e desce os labs do `vm-cilium` por um único CLI idempotente,
com `--dry-run` e prova de ausência de resíduo. Contrato:
`plans/P004/labctl-spec.md`.

## Uso

```bash
# no host (vm-cilium), como root
sudo LAB_ROOT=/opt/poc-k8s-fabric /caminho/para/labctl <lab> <acao> [--dry-run] [--evidence DIR]
sudo LAB_ROOT=/opt/poc-k8s-fabric /caminho/para/labctl status
```

- **Labs:** `k01`, `mgc`, `p003-gw`, `openstack`, `evpn-fabric`, `ovnk`.
- **Ações:** `preflight`, `up`, `verify`, `down`, `status`, `resources`.
- `--dry-run` imprime cada mutação com prefixo `DRY:` e não executa nenhuma.
- `--evidence DIR` grava comando, saída, duração e memória antes/depois
  (padrão `/var/tmp/labctl/<lab>/<UTC>/`).
- Saída final de toda ação: `LABCTL <lab> <acao> OK|FAIL|NEEDS_INPUT <s>s mem_avail=<GiB>`.

## Pré-requisitos

- `docker`, `containerlab` (`clab`), `kind`, `kubectl`, `helm`, `cilium` no host.
- Kit em `$LAB_ROOT` (padrão `/opt/poc-k8s-fabric`) com `scripts/00`–`99`.
- `labctl.env` (ignorado pelo git) com os valores do host; veja `labctl.env.example`.

## Perfis

- **k01** — lab de referência (fabric SR Linux + kind + Cilium dual-stack + BGP; canário `10/10` intocado).
- **mgc** — réplica MGC Connect OVN 26.03.3 + OVS 3.7 + FRR (`M01–M03`, `--m03`, e isolamento same-CIDR `X05` em `studies/p004/ovn/`).
- **p003-gw** — sandbox Cilium 1.20.2 + Gateway API + BGP (VIP `10.202.255.10`) + suporte ao **Braço Cilium A** com KubeVirt v1.9.0 (`studies/p004/cilium-a/`, `V00–V08A` / `C-neg`) e ao **Braço Cilium B** com DaemonSet FRR `10.7.1` no nó sob invariante `R6` (`studies/p004/cilium-b/`, `H6`, `V09`/`H7`, `V07-B`, `V08-B`).
- **openstack** — testbed `p003-os` (só `status`/`down`/`up`; nunca rebuild; `preserve-only`).
- **evpn-fabric** — fabric standalone OVN 26.03 + FRR 10.7 EVPN/BGP multi-VRF (`10.0.0.0/24` same-CIDR, VNI 10100/10200, casos cruzados `X01–X07` em `studies/p004/cases/`).
- **ovnk** — Kind 3 nós + OVN-Kubernetes v1.4.0 (`UDN`, `EVPN`, `RouteAdvertisements`) + KubeVirt v1.9.0 (KVM real) + `frr-k8s` v0.0.27 (`K01–K04` em `studies/p004/ovnk/`).

## Lições operacionais (L1–L8)

| # | Lição | Gate |
|---|-------|------|
| L1 | `client-ext` pode perder o IPv4 após deploy | validar `203.0.113.10` sempre |
| L2 | `docker stop` de SR Linux destrói os veths | falhas só com `admin-state disable` via `sr_cli` |
| L3 | `clab destroy` parcial apaga o kind | nunca destroy/redeploy com cluster no ar |
| L4 | contagem de falhas superestima blackhole | medir por gap entre OKs |
| L5 | bulk-delete por label leva colaterais | deletar por lista explícita de nomes |
| L6 | `helm upgrade` regenera o ConfigMap | reconferir `devices=eth+` |
| L7 | testbed OpenStack tem cap de 8 GiB | gate de memória antes de cada spawn de VM |
| L8 | `/run/log/journal` em nós Kind consome page cache (`tmpfs`) e reduz `MemAvailable` abaixo de `4 GiB` (`R3`) | aplicar `journalctl --vacuum-size=10M` nos nós Kind antes de gates de memória |
