# Revisão do projeto — 26/09/2026

Revisão estática do repositório `learn-cilium` (branch `main`, commit `f20442f`).
Nada foi executado contra a `vm-cilium`; todos os achados foram verificados por
leitura, `bash -n`, `shellcheck`, `yamllint`, `go vet`, decodificação de
Secrets e reconstrução do PDF do guia. Caminhos abaixo são relativos a
`poc-k8s-fabric/` salvo indicação em contrário.

## Resumo executivo

O kit didático (topologia, CRs de BGP, values do Cilium, configs SR Linux/FRR)
está internamente coerente: ASNs, enlaces `/31`, PodCIDRs, VIPs e versões batem
entre todos os arquivos, os links do Markdown resolvem, os manifests do Gateway
API casam com os CRDs `v1.6.1` vendorizados e o builder do PDF funciona em um
clone limpo. Os problemas concentram-se em quatro frentes:

1. **Scripts do kit não rodam como estão.** Os defaults apontam para a topologia
   errada (`poc-fabric` em vez de `poc-kind`), para um prefixo de container que
   não existe (`clab-poc-k8s-fabric-*` em vez de `clab-poc-k8s-kind-*`) e para
   nós `node1/node2/node3` que não existem no kind `k01`. O guia do estudante
   contorna tudo isso com variáveis de ambiente, mas o `99-destroy.sh` nunca é
   corrigido.
2. **Dois scripts com erro de sintaxe** (`bash -n` falha): `s012/11` e
   `s012/81`. O segundo cria uma VM e o bloco de teardown nunca executa.
3. **Política de sanitização violada.** O repositório publica a cópia *não*
   sanitizada da síntese E08 (UIDs de cluster, paths `/root/.kube`,
   `/opt/...`), cinco chaves privadas TLS em `s009/10-tls.yaml`, uma senha root
   de MySQL em `s011/reconf-ovs.sh` e UIDs/bridges/pods/NodePorts fixos em
   dezenas de scripts, contradizendo `design-contract.md` e
   `execution-protocol.md`.
4. **Fixtures contradizem o próprio achado do estudo.** As CNPs "default-deny"
   com `egress: []` / `ingress: []` são exatamente a construção que a síntese
   E08 documenta como ineficaz (D-S013-2). Ou o achado ou as fixtures estão
   errados; os dois não podem estar certos.

## Achados por severidade

### Alta — impede reprodução ou viola política declarada

| # | Arquivo:linha | Problema |
|---|---|---|
| A1 | `scripts/01-deploy-fabric.sh:6`, `scripts/99-destroy.sh:4` | `TOPO` default é `topo/poc-fabric.clab.yml` (variante de cluster externo, não documentada nos READMEs). O README só cita `poc-kind.clab.yml`. Rodando sem override, sobe SR Linux + FRR + bridges vazias e nenhum kind; `02-install-cilium.sh` falha. |
| A2 | `scripts/04-validate.sh:6`, `scripts/05-evpn-scenario.sh:5`, `scripts/01-deploy-fabric.sh:24-25`, `configs/srl/evpn/*.cfg:4` | `PFX=clab-poc-k8s-fabric`, mas `topo/poc-kind.clab.yml:9` define `name: poc-k8s-kind`. Passos 3–7 da validação e todo o cenário EVPN falham com "No such container". |
| A3 | `scripts/03-apply-bgp.sh:7-8`, `k8s/bgp/06-node-config-override-example.yaml:7` | Nós default `node1 node2` / `node3`; os nós reais são `k01-control-plane`, `k01-worker`, `k01-worker2`. Com `set -e`, o script aborta antes de aplicar qualquer CR. |
| A4 | `studies/p003/cases/s012/11-c1-fixes-router.sh:55-57` | Aspa simples fechada cedo demais na linha 55 e reaberta na 57: `bash -n` falha. Seções [a]–[c] mutam o testbed (veth, `br-ex`, `neutron.conf`, `kill -9`), seções [d]–[f] (provas e verificação de integridade do lab) nunca rodam. |
| A5 | `studies/p003/cases/s012/81-tap-location-diag.sh:73` | `tr "\n" " ')"` contém `'` que fecha o bloco `DX '...'`: erro de sintaxe. A VM `vm-a` é criada na linha 33 e o teardown (69–73) nunca executa; o cabeçalho promete o contrário. Linha 18 imprime `|| echo sem` literalmente. |
| A6 | `studies/p003/e08-lifecycle-synthesis.md` (inteiro) | Cópia não sanitizada de `docs/estudos/08-lifecycle-synthesis.md` (160 linhas de diff). Contém UIDs `8216d179-…` e `45cb3818-…` (l.180, 186), `/root/.kube/p003-gw.config` (l.133, 216), `/opt/poc-k8s-fabric-studies/...`, IPs observados e referências a `plans/*` inexistentes no repo. O próprio cabeçalho diz "não é a publicação sanitizada". |
| A7 | `studies/p003/cases/s009/10-tls.yaml:34,46,106,118,130` | Cinco Secrets `tls.key` com `-----BEGIN PRIVATE KEY-----` em base64. `execution-protocol.md:114` proíbe registrar Secrets. O certificado `edge.p003.study` vale de 22/09 a **22/10/2026**: o caso positivo T11 para de funcionar em menos de quatro semanas. |
| A8 | `studies/p003/cases/s011/reconf-ovs.sh:38` | Senha root MySQL em texto claro: `mysql -uroot -pp003s011dbpass`. Todos os outros scripts leem a senha de `local.conf`. |
| A9 | `studies/p003/cases/s013/01a-ns-cnps.yaml:18-19`, `s009/07-policies.yaml:26,67,79,120` | `egress: []` / `ingress: []` como "deny-all", construção documentada como ineficaz em `docs/estudos/08-lifecycle-synthesis.md:105,119-120,177`. Os negativos C03/C09 (`s013/03-c06-c09.sh:124`) não são reproduzíveis com o que está no repo. |
| A10 | `studies/p003/cases/s004-record-ports.sh:6,10,17,24` | `K()` é função, mas é invocada como `$K …`. Com `set -u`: `K: unbound variable`; o script não produz nada. |
| A11 | `studies/p003/cases/s013/02-c01-c03.sh:32-59` | Off-by-one: baseline é a linha 1 de `$HIST`, C01 a linha 2; `awk 'NR==2'` compara C01 consigo mesmo (sempre `IP-IGUAL`) e `BASE_IP` do churn C02 é o IP de C01. |
| A12 | `studies/p003/cases/s010/s010-run.sh:259-260,299` | Aplica `…/studies/p003/s010/01-m24-setup.yaml`; o caminho no repo é `studies/p003/cases/s010/`. Linhas 266-267/326-328 tentam remover e recolocar `node.spec.podCIDR`, campo imutável na API; erro vai para log e a precondição "fonte única de alocação" pode nunca ter valido. |

### Média — funciona com intervenção manual ou documenta algo que não acontece

| # | Arquivo:linha | Problema |
|---|---|---|
| M1 | `configs/frr/frr.conf:79` | `network 172.18.0.0/16   ! VPC …`: FRR só aceita comentário no início da linha; o `network` provavelmente é rejeitado no `vtysh -b`, quebrando o retorno usado por `scripts/06-expor-vip-na-vpc.sh`. Verificar na VM com `show run`. |
| M2 | `k8s/cilium/values-dualstack.yaml:93-95`, `values-overlay-poc.yaml:59-60` | Chaves inexistentes no chart 1.20 (`podIPv6CIDR`, `maskSizePodIPv6`, `clusterIPv6`, `config.nodeAddressSelector`): ignoradas silenciosamente. O "S13 fix" é no-op; use `extraConfig:`. |
| M3 | `scripts/02-install-cilium.sh:12` vs `topo/kind-cluster.yaml:8-12`, `k8s/bgp/01-peer-config.yaml:25-29`, `k8s/bgp/05-lb-ippool.yaml:11`, `k8s/apps/11-echo-svc-anycast.yaml:22-42` | Default `values-native.yaml` não habilita IPv6, mas cluster, peers, pool e Service são dual-stack. `README.md:19` só é verdadeiro com `VALUES=values-dualstack.yaml`. `values-native.yaml` e `values-dualstack.yaml` são quase idênticos (risco de drift). |
| M4 | `scripts/06-expor-vip-na-vpc.sh:25,41,53,84-85` | `UPLINK=ens3` + `sysctl` sob `set -e` aborta em qualquer NIC diferente; `\$(ip …)` escapado imprime o comando em vez do IP; instruções de undo hard-coded. Também orienta desligar `ip-spoofing-guard` na cloud, embora o README diga que esse caminho está fora de escopo. |
| M5 | `scripts/05-evpn-scenario.sh` + `configs/srl/evpn/*.cfg` | Emite `delete` em cinco nós sem confirmação, idempotência ou rollback; falha no meio deixa o fabric partido. Cabeçalhos falam em "eBGP unnumbered", mas o underlay é numerado `/31`. |
| M6 | `scripts/00-prep-vm.sh:19-20,63,83,97` | `curl \| bash` sem pin (containerlab, helm); `KIND_VERSION=v0.30.0` e canal apt `v1.34` para um cluster `v1.35.0`; pré-pull de `network-multitool:latest` enquanto as topologias pinam digest. |
| M7 | `studies/p003/cases/s012/05-relight-testbed-safe.sh:31-34` | O "guard" que deveria recusar tocar OVS/módulos nunca falha (o `if` casa consigo mesmo e não faz `exit`); mensagem invertida. |
| M8 | `studies/p003/cases/s011/01-devstack-container.sh:26-72` | `local.conf` usa variáveis que o DevStack não lê (`SERVICE_LIST`, `Q_PLUGIN_ml2_drivers`, `FLAT_NETWORKS`, `VLAN_RANGES`) e não define senhas que `s012/06:92` e `s012/21:38` esperam; imagem `ubuntu:22.04` sem `sudo` e sem `--init` (vs `24.04` e `--init` em `s012/01`, `03`, `69`). `reconf-ovs.sh:2-3` indica que o que subiu foi OVN. Um clone limpo não reproduz o `p003-os` que os scripts s012 operam. |
| M9 | `studies/p003/cases/s012/66-c6b-vhost-cpu.sh:10`, `41-c15b-cpu-limit-drop.sh:13-14` | `rmmod vhost_net` no kernel do host sem `modprobe` no teardown (`68`); remoção do limite de CPU não restaurada por `57-teardown-study.sh` apesar do cabeçalho prometer. |
| M10 | `studies/p003/cases/s007-run.sh:68`, `s008-run.sh:152` | Drivers "master" abortam como estão (`rollout status deploy/cilium` num DaemonSet; `routingMode=vxlan` inválido). Só os `*-resume.sh` admitem isso. |
| M11 | `studies/p003/cases/k01-canary.sh:19-24` | Usa `/root/.kube/k01.config`; todo o resto usa `k01-rebuild.config`. |
| M12 | `studies/p003/fixtures/auth/main.go:103`, `Dockerfile:1,9` | `<-ctx.Done()` em vez de `gctx.Done()`: se o HTTP falhar, o processo fica vivo com gRPC no ar e readiness quebrada. Sem `go.sum` (build depende de rede); bases `golang:1.24` e `chainguard/static:latest` contrariam `research.md:19-20` e `03-externalauth.md:41`. |
| M13 | `studies/p003/cases/s009/10-tls.yaml:162`, `fixtures/auth/auth-deploy.yaml:21` | `p003-tlsecho:1.0.0` não tem fonte no repo; `p003-authz:1.0.0` tem fonte mas nenhum passo de build/`kind load` documentado. Scripts `s014-0*.sh` citados em `08-lifecycle-synthesis.md:153` estão fora do repo. |
| M14 | `topo/poc-fabric.clab.yml:9`, `scripts/00-prep-vm.sh:10`, `k8s/cilium/values-native.yaml:33`, `configs/srl/*.cfg:17`, `s012/01:17`, `s012/05:9` | Referências a arquivos privados/ignorados (`docs/06-…`, `docs/11-…`, `evidence/…`, `P001-S003-results.md`). |
| M15 | `studies/p003/base/values-p003.yaml:41`, `cases/s010/values-*.yaml:28-30` | `k8sServiceHost: 172.19.0.5` é IP atribuído pelo Docker; o comentário admite que `k01` recebeu `.3`. Frágil em deploy limpo. |

### Baixa — drift documental e higiene

- `docs/lab-guide-student.md` e `docs/student-guide-template.md` são byte-idênticos; o "template" não é um template.
- `docs/estudos/README.md:3,41,82-91` e `proximos-estudos.md:10` dizem que só E08/C5 executaram, mas o repo contém closeouts e run-ids de S003, S007, S008, S012 (`diff-vs-kit.md:1`, `s009/09-delegation.yaml:10-16`). README fala em "14 sessões" com 15 linhas na tabela; `design-contract.md:11` lista dossiês `00`–`08`, mas existe `09`.
- `execution-protocol.md` define `REFERENCE_*` = k01 e `STUDY_*` = sandbox; `08-lifecycle-synthesis.md:138-139` e `09-vm-outside-container.md:143-144` usam `REFERENCE_*` para o sandbox. Layout de evidência difere entre protocolo §4, `cases/README.md:5`, s007/s008 e s013.
- Não existe README/índice para `cases/s011` e `cases/s012` (88 scripts); `cases/README.md` cobre só GW01–GW07. Numeração de s012 pula o `02`. Qual script é canônico vs beco sem saída só se descobre por comentários de cabeçalho (`01`→`05`, `03`/`04`, `09`→`09c`, `10`→`11`).
- `docs/estudos/07-openstack.md:67` diz "não criar DevStack automaticamente"; s011 faz exatamente isso. `09-vm-outside-container.md:147` usa `testbed-os`; os scripts usam `p003-os`.
- Identificadores operacionais que a política manda redigir aparecem em scripts: UIDs de cluster (`k01-canary.sh:8`, `s004-restore.sh:11`, `s007-run.sh:18-19`, `s008-run.sh:20-21`, `s010-run.sh:9`, `s013/01-setup.sh:19-20`, `s012/01:25,28`, `s012/05:160-161` …), bridge Docker `br-b56f3de1d858`, pods `cilium-tntn7/k9ssl/…` (`s004-diag2..9`), NodePorts congelados (`l403-l404-probes.sh:10-11`, `l405-l407-probes.sh:10-11`, `NP=30676`), UUIDs Neutron (`s012/74:17-18`), PIDs (`s012/10:16`), `instance-00000010` (`s012/44:18`).
- Nomes de fornecedor sobrevivem à sanitização: "Magalu"/"MKE"/`magalu-poc` em `execution-protocol.md:39`, `lab-results.md:20`, `diff-vs-kit.md:61,96,418`, `configs/frr/frr.conf:79`, `scripts/06-expor-vip-na-vpc.sh`.
- Sobreposição de endereçamento: subnet OpenStack `10.30.0.0/24` dentro do agregado do fabric sandbox `10.30.0.0/16` (`p003-gw.clab.yml:68,78,88`), o que obriga rotas mais específicas em `s013/01-setup.sh:31,33` e viola `00-preflight.md:87`.
- `09-vm-outside-container.md:67,94`: o netns é `qrouter-<router-uuid>`, não `<net-uuid>`.
- `configs/hosts/node-prep.sh:43` filtra `172.31.255.` (faixa de VIP antiga). `k8s/bgp/01-peer-config.yaml:7` diz mínimo 9/3 (CRD aceita 3/1). `k8s/bgp/02-advertisements.yaml:17,30` marca `65101:*` também nos nós do rack2. `policy-hardening.cfg` não tem prefix-set IPv6. `frr.conf:20` MTU 9216 vs SRL 9194.
- Só `s005-probes.sh` usa `set -euo pipefail`; 121 dos 129 scripts não têm `set -e`. `shellcheck -S warning`: 27×SC2034, 18×SC2024, além dos dois erros de parse.
- Sem README, `Makefile` ou CI. Nenhum lint roda automaticamente; os dois erros de sintaxe teriam sido pegos por `bash -n` em um hook.

## O que foi verificado e está correto

- CRDs Cilium `cilium.io/v2` (`CiliumBGPClusterConfig`, `PeerConfig`, `Advertisement`, `LoadBalancerIPPool`, `NodeConfigOverride`) com campos válidos para 1.20; selector `bgp-advertise: "true"` casa com os três Services; `loadBalancerClass: io.cilium/bgp-control-plane`; `externalTrafficPolicy: Cluster` conforme README.
- Seis enlaces `/31`, IPs de vizinhos, endpoints clab, ASNs (65001/2/3, 65500, 65100, 65101/65102, 65000 no kit; 65301/65302 ↔ 65201/65202 ↔ 65600 ↔ 65203 ↔ 65400 no sandbox), PodCIDR `10.244.0.0/16`, VIPs `10.201.255.0/24` e `10.202.255.10`, `fd13::/48`, `fd14::/64` consistentes em todos os arquivos.
- Versões: Cilium `1.20.1` (k01) e `1.20.2` (sandbox, chart vendorizado confirmado), kind `v1.35.0`, SR Linux `25.3.2`, FRR `8.4.1` consistentes; única exceção é `00-prep-vm.sh` (M6).
- Gateway API: Gateway/HTTPRoute/TCPRoute/UDPRoute `v1`, ReferenceGrant `v1beta1`, ListenerSet `v1`, BackendTLSPolicy `v1` batem com CRDs `v1.6.1`; `externalAuth` só existe no canal experimental (obrigatório, não documentado em `values-p003.yaml`). Todos os `parentRefs`/`sectionName` resolvem; todo `backendRef` cross-namespace tem ReferenceGrant; portas Service/Deployment/Route coerentes.
- Todos os links Markdown e imagens resolvem (0 quebrados em 25 arquivos). `yamllint` sem erros. `python3 tools/build_guide.py` gera o PDF (11 páginas) em clone limpo com `reportlab==5.0.1`.
- Nenhum IP público, e-mail ou path `/home/<usuário>`; IPs em RFC1918, `198.19.0.0/16`, `203.0.113.0/24` e ULA. Única credencial além das descobertas acima é a default pública `NokiaSrl1!`.

## Plano de correção sugerido (ordem)

1. **Sintaxe e segurança imediata:** corrigir `s012/11:55-57` e `s012/81:73`; remover `studies/p003/e08-lifecycle-synthesis.md` (ou reduzi-lo a um ponteiro para a versão pública); substituir as chaves de `s009/10-tls.yaml` por um script de geração; trocar a senha fixa de `s011/reconf-ovs.sh:38` pela leitura de `local.conf`; rotacionar quaisquer segredos reais se algum deles não for sintético.
2. **Defaults do kit:** `TOPO` → `poc-kind.clab.yml`, `PFX` → `clab-poc-k8s-kind`, nós → `k01-*` (ou derivar com `kubectl get nodes`), e documentar `poc-fabric.clab.yml` como variante ou removê-lo; alinhar `02-install-cilium.sh` com o cluster dual-stack ou tornar o kind single-stack.
3. **Fixtures vs achado:** decidir se `egress: []` é ineficaz (então trocar por `egressDeny`/`ingressDeny` nas fixtures) ou se o achado D-S013-2 precisa de errata.
4. **Scripts de estudo:** parametrizar UIDs, kubeconfigs, bridge, NodePorts e nomes de pod por variáveis com descoberta; corrigir `$K`, o `NR==2`, o caminho de `s010-run.sh`, `k01.config`; acrescentar README de execução em `s011/` e `s012/` marcando canônico vs beco sem saída.
5. **Higiene contínua:** adicionar um alvo `make lint` (ou CI) com `bash -n`, `shellcheck -S error`, `yamllint` e o verificador de links; remover chaves de Helm inexistentes; pinar bases de imagem; consolidar `values-native`/`values-dualstack`; atualizar status no índice de estudos.

## Método

- Inventário: 3 diretórios de topo, 129 scripts shell, 61 YAML (fora CRDs vendorizados), 25 Markdown, 1 fixture Go, 1 builder Python.
- Ferramentas: `bash -n` em todos os scripts, `shellcheck 0.11.0`, `yamllint`, `go vet`, `openssl x509`, `base64 -d`, `diff`, verificador de links Markdown, extração do `values.schema.json` do chart `cilium-1.20.2.tgz` para validar chaves Helm.
- Três leituras independentes em paralelo (kit, estudos P003, testbed OpenStack), com verificação cruzada dos achados de maior impacto.
