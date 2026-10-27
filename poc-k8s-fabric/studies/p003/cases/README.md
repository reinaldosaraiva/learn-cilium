# Casos P003

Este diretório reúne arquivos de sessões P003. Os nomes abaixo correspondem a
arquivos versionados; o [índice de estudos](../../README.md) e os dossiês
descrevem o escopo de cada estudo.

> **Contexto dos scripts:** sandbox `p003-gw` (`STUDY_KUBECONFIG=/root/.kube/p003-gw.config`, `STUDY_CONTEXT=kind-p003-gw`); canário protegido `k01` com `10/10` HTTP `200` antes e depois.

| Estudo | Arquivos associados | Dossiê |
|---|---|---|
| E02 — Portas TCP/UDP e host network | [`s004-record-ports.sh`](s004-record-ports.sh), [`s004-verify-on.sh`](s004-verify-on.sh) | [E02](../../../docs/estudos/02-l4-hostnetwork.md) |
| E03 — ExternalAuth | [`s005-probes.sh`](s005-probes.sh), [`s006-probes.sh`](s006-probes.sh) | [E03](../../../docs/estudos/03-externalauth.md) |
| E04 — WireGuard | [`s007-run.sh`](s007-run.sh), [`s008-run.sh`](s008-run.sh) | [E04](../../../docs/estudos/04-wireguard.md) |
| E05 — Tenants e TLS | [`s009/`](s009/), [`gen-tls.sh`](s009/gen-tls.sh) | [E05](../../../docs/estudos/05-tenants.md) |
| E06 — IPAM | [`s010/`](s010/), [`s010-run.sh`](s010/s010-run.sh) | [E06](../../../docs/estudos/06-ipam.md) |
| E07 — OpenStack e tenant híbrido | [`s011/README.md`](s011/README.md), [`s012/README.md`](s012/README.md) | [E07](../../../docs/estudos/07-openstack.md) |
| E08 — Ciclo de vida e síntese | [`s013/02-c01-c03.sh`](s013/02-c01-c03.sh), [`s014/run-s014-lifecycle.sh`](s014/run-s014-lifecycle.sh) | [Síntese E08](../../../docs/estudos/08-lifecycle-synthesis.md) |

> **Nota histórica:** C5 é uma emenda documentada separadamente sobre a VM fora
> do container. Ela não é o estudo E09; E09 corresponde ao ensaio de TCP MD5
> eBGP listado no [índice geral](../../README.md).

O diretório `s012/` conserva sondas históricas de diagnóstico e recuperação.
Consulte seu [índice](s012/README.md) como inventário de arquivos, sem inferir
uma sequência operacional a partir da numeração.
