# E08 — Síntese: recriação, reuso de IP e revogação (guia didático local)

> **Escopo:** consolidação didática da matriz E08 (C01–C09) — lado K8s
> (P003-S013) + lado VM/OpenStack (P003-S014). Guia **local** (não é a
> publicação sanitizada de `poc-k8s-fabric/docs/estudos/`). Cada afirmação
> aponta para a evidência datada (results + artefatos); não re-executa nada.
> **Versões fixas:** Cilium 1.20.2, Gateway API 1.6.1, K8s v1.35.0, OpenStack
> (DevStack-in-container, neutron 34.x), cirros-0.6.0.

## 1. Visão geral — a pergunta de identidade

**Hipótese crítica (do spec `plans/P003/08-lifecycle.md`):** IP pode mudar de
dono. Uma regra IP/CIDR antiga pode autorizar o novo dono se não houver
revogação/sincronização. Ver duas plataformas funcionando **não** demonstra que
a transição de dono é segura.

A pergunta que a matriz responde: **a autorização segue a identidade
(label/UUID) ou o endereço (IP)?**

- **Lado K8s (C01–C03, C06–C09):** a authz por **label** (`fromEndpoints`)
  segue a **identidade** — o novo dono com IP reaproveitado é **negado** (C03).
- **Lado VM (C04–C05):** a authz por **IP** (`fromCIDR`) segue o **endereço** —
  a nova VM com IP reaproveitado **herda** a concessão (C05); o IP antigo não
  concede à VM recriada com IP novo (C04).

**Conclusão máxima (gate rebaixado):** "seguro sob **sequenciamento manual
testado**", **não** "Kubernetes/OpenStack sincronizam identidade
automaticamente". Não há controlador novo nesta trilha — a revogação é manual.

## 2. Fluxo L4 VM↔Pod e pontos de decisão de authz

Caminho **VM→Pod** (medido em S014, **sem iptables** — rota do host
`via 10.101.0.2 dev p003-ext`; `DOCKER-FORWARD -i docker0 -j ACCEPT` cobre):

```
VM (tap) ──OVS br-int (tag 1)──▶ qr port ──▶ qrouter netns ──OVS br-ex──▶
  veth-ext1 (container) ──▶ veth-ext0 (host, master docker0) ──▶ host FORWARD
  ──▶ p003-ext ──▶ fabric (spine/leaf) ──▶ worker2 eth1 (10.30.2.11) ──▶
  [Cilium policy: CNP ingress] ──▶ pod (10.245.1.208)
```

**Pontos de decisão de authz (onde o deny é observado):**
- **CNP (lado K8s):** `ingress` no pod — `fromCIDR` (por IP) ou `fromEndpoints`
  (por label). Deny = drop **antes** de chegar ao pod (counters do pod ficam
  flat).
- **SG (lado OVS/Neutron):** security group da VM — control plane (não medido
  como deny de datapath em S014; invariante registrado).

**Sentido pod→VM** (limitação conhecida): bloqueado pela chain DOCKER
(`iifname != docker0 oifname docker0 drop`, D-S013-1) — o fix (ACCEPT
direcionado) é mutação de testbed, revertido no rollback. Timeout/000 esperado.

**Sequenciamento de revogação manual (mecanismo do experimento):**
1. Abrir coletor de probes **novos** contínuos com timestamp.
2. Retirar o allow de A dependente do endereço a ser liberado; registrar
   comando aceito + primeiro bloqueio observado.
3. Confirmar revogação por **novas** conexões **antes** de reutilizar o IP.
4. Recriar o recurso (novo UUID/UID); conferir se o IP mudou ou foi reaproveitado.
5. Reautorizar **somente depois** de verificar o novo dono.

## 3. Matriz C01–C09 — status, janelas, evidência, lição

| Caso | Evento | Lado | Status | Janela medida | Lição |
|---|---|---|---|---|---|
| C01 | Pod A recriado, IP diferente | K8s | **PASS** | — | Authz por label: novo dono autorizado; IP velho sem concessão |
| C02 | Pod A recriado, IP igual/UID novo | K8s | **PASS-parcial** | — | Sem reuso de IP (IPAM k8s atribui IP novo); authz por label demonstrada |
| C03 | IP de A passa a Pod B | K8s | **PASS** | — | **B negado** (100% loss) — authz por **label não vaza** no reuso de IP |
| C04 | VM A recriada, porta/IP novos | VM | **PASS** | reconvergência **~4-9s** | CNP antigo (IP antigo/32) **não concede** à VM com IP novo (deny flat); reautorizar pelo IP novo é efetivo |
| C05 | IP da VM A reaproveitado por VM B | VM | **PASS** | revogação **~1-7s** | **Leak de herança** por IP (CNP antigo cobre B); revogar é efetivo — **falha de desenho** |
| C06 | Auth pod recriado | K8s | **PASS** | — | ExternalAuth resiliente a recriação do backend (200/403/401/200) |
| C07 | Grant/rota removida | K8s | **PASS-achado** | indefinida | Rota ampla (path=/) faz fallback — revogação por remoção de rota específica **ineficaz** |
| C08 | Conexão longa antes da revogação | K8s | **PASS-controle** | — | Híbrido pod↔VM bloqueado por D-S012-13; não inferir encerramento automático |
| C09 | Regra stale (controle) | K8s | **PASS** | ~4s | COM allow → vazamento (0% loss); SEM allow +egressDeny → negativo (100% loss) |

**Evidência:** S013 `plans/P003-S013-results.md` +
`…/evidence/P003/S013/2026-09-24T1145Z/`; S014 `plans/P003-S014-results.md` +
`…/evidence/P003/S014/2026-09-24T1830Z/` (samplers em `/tmp/s014-sampler-*.txt`).

## 4. Contraste central — C03 (label) vs C05 (IP)

Este é o achado de desenho da trilha:

| | C03 (K8s, `fromEndpoints`) | C05 (VM, `fromCIDR`) |
|---|---|---|
| Mecanismo | authz por **label** do endpoint | authz por **IP/CIDR** da fonte |
| IP reaproveitado por novo dono | **Negado** (B não herda) | **Permitido** (B herda) |
| Por quê | o label identifica o **dono** (identidade) | o IP identifica o **endereço** (não o dono) |
| Conclusão | seguro (segue identidade) | **falha de desenho** (segue endereço) |

**Leitura didática:** em K8s, a identidade (label/UID) é a âncora da authz — o
IP é um atributo mutável. Em OpenStack/CNP por CIDR, a âncora é o endereço — se
o endereço muda de dono, a concessão vai junto. **A segurança depende de a
authz ancorar na identidade, não no endereço.** Em desenho por IP, a revogação
manual (retratar o CIDR antes de reutilizar o IP) é o único mecanismo — daí
"seguro sob sequenciamento manual testado".

## 5. Tabela por feature (versão, combinado, lacunas)

| Feature | Versão/API | Combinado testado | Não suportado / lacuna |
|---|---|---|---|
| CNP `fromCIDR` (ingress por IP) | Cilium 1.20.2 | allow/deny/revogação medidos (C04/C05) | `ingress: []` inválido (D-S014-2) |
| CNP `fromEndpoints` (ingress por label) | Cilium 1.20.2 | allow/deny (C01/C03) | — |
| CNP `egressDeny` | Cilium 1.20.2 | default-deny de egress eficaz (C03/C09) | `egress: []` ineficaz (D-S013-2) |
| Neutron SG (stateful) | neutron 34.x | control plane invariante (sg-a) | deny de datapath não medido como gate |
| Neutron port + fixed IP | neutron 34.x | reuso de IP via mesmo port (C05) | DHCP RPC timeout → link-local (D-S014-1) |
| IPAM kubernetes (K8s) | K8s v1.35.0 | sem reuso de IP (atribui IP novo, C02) | reuso determinístico não observado |
| Cilium identity (numérico) | Cilium 1.20.2 | por label (app=…) | ID numérico reciclável — não é identificador eterno |
| Gateway API ExternalAuth | Gateway API 1.6.1 | resiliente a recriação (C06) | cross-ns HTTP allow pendura (D-S006-1) |
| Authz bidirecional pod↔VM | — | VM→Pod unidirecional (TX ok) | pod→VM bloqueado (D-S013-1) + RX intermitente (D-S012-13) |
| Sincronização automática de identidade | — | **não implementada** (sequenciamento manual) | a lacuna central da trilha |

## 6. Interpretação de fails (o que cada erro significa)

| Sinal | Causa | Ação |
|---|---|---|
| VM com `169.254.x.x` em vez do fixed IP | `neutron-dhcp-agent` com RPC `MessagingTimeout` não sincronizou o port (D-S014-1) | **reiniciar o `neutron-dhcp-agent`** (re-sync → host file + lease) |
| CNP `ingress: []` rejeitado / sem efeito | inválido no Cilium 1.20.2 (D-S014-2) | revogar setando `fromCIDR` p/ IP que a VM **não** tem |
| CNP `egress: []` sem efeito | não é default-deny eficaz (D-S013-2) | usar `egressDeny` com `toCIDR` |
| pod→VM timeout/000 (mesmo com RX vivo) | chain DOCKER isola docker0 (D-S013-1) | ACCEPT direcionado na FORWARD (mutação de testbed, revertida) |
| VM envia mas não responde (RX) | KVM aninhado no container (D-S012-13) — **intermitente** | medir por VM; C5 (VM fora do container) para resolver |
| fonte do pod = IP fabric do nó | masquerade BPF expõe o IP do nó (D-S012-12) | SG de tenant cobre os IPs fabric dos nós |
| counters do pod flat com a VM sondando | deny no CNP (drop antes do pod) — **esperado** em C04/C05 deny | confirmar com `cilium monitor` (action deny) |

**Contadores do pod (observabilidade):** `/proc/net/snmp` — **InEchos = campo
10** da linha `Icmp:` (campo 9 = InRedirects — off-by-one comum); **OutRsts =
campo 15** da linha `Tcp:`. Ler com `cut -d" " -fN` dentro de `sh -c`
single-quoted (quoting aninhado de awk corrompe `\$10`).

## 7. Instruções de reprodução (scripts reais entregues)

**Ambiente:** testbed `p003-os` (DevStack-in-container na vm-cilium, cap 8GiB);
sandbox `p003-gw` (kind + fabric, origem dos pods); k01 (protegido, somente
leitura). Kubeconfig do sandbox: `/root/.kube/p003-gw.config`.

**Lado K8s (S013)** — `poc-k8s-fabric/studies/p003/cases/s013/`:
- `01-setup.sh` + `01a-ns-cnps.yaml` + `01b-pod-a.yaml` + `01c-auth.yaml` +
  `01d-auth-routes.yaml` — fixture (ns, CNPs, Pod A, auth, rotas).
- `02-c01-c03.sh` — C01–C03 (recriação + reuso de IP + authz por label).
- `03-c06-c09.sh` — C06–C09 (auth recriado, rota, conexão longa, regra stale).
- `04-rollback.sh` — teardown.

**Lado VM (S014)** — `poc-k8s-fabric/studies/p003/cases/s014/` + scripts no
host `/tmp/s014-*.sh` (referenciados na evidência):
- `01a-ns-pod-a.yaml` — fixture (ns p003-lc + Pod A + CNP `fromCIDR`).
- `s014-01-setup-vm-a.sh` … `s014-09-rollback.sh` — spawn/delete de VMs, CNP,
  sampler de counters, rollback (ver `plans/P003-S014-results.md` §Evidência).

**Spawn de VM (padrão):**
```bash
openstack port create --network net-a --fixed-ip subnet=subnet-a,ip-address=IP \
  --security-group sg-a <port-name>
openstack server create <vm> --image cirros-0.6.0 --flavor m1.p003 \
  --nic port-id=<UUID> --config-drive True --user-data /opt/stack/vm-s014-init.sh --wait
```
**Gate de memória por spawn:** container `p003-os` ≤ 6.8GiB (85%) **e** host ≥
1GiB available; senão abortar/escalar.

## 8. Checklist de adoção (baseado na matriz — sem "pronto p/ produção")

- [ ] **Authz por IP (fromCIDR):** revogar o CIDR **antes** de reutilizar o IP
  (sequenciamento manual testado — C04/C05). Janela de revogação ~1-7s;
  orçar margem.
- [ ] **Authz por label (fromEndpoints):** preferir quando a identidade for a
  âncora de segurança (C03 — não vaza no reuso de IP).
- [ ] **CNP Cilium 1.20.2:** nunca `ingress: []`/`egress: []` p/ default-deny —
  usar `egressDeny`/`fromCIDR` p/ IP ausente (D-S013-2/D-S014-2).
- [ ] **Reuso de IP:** em K8s (IPAM kubernetes) o IP **não** é reaproveitado
  (C02) — não depender de reuso; em OpenStack, fixed IP por port **é**
  reaproveitável (C05) — tratar como risco de herança.
- [ ] **Testbed OpenStack-in-container:** verificar DHCP agent antes de spawn
  (D-S014-1); tratar RX da VM (D-S012-13) como intermitente; gate de memória.
- [ ] **Bidirecional pod↔VM:** não assumir — VM→Pod unidirecional provado;
  pod→VM requer fix de DOCKER chain (D-S013-1) + RX vivo.
- [ ] **Sincronização automática:** **não** existe nesta trilha — a conclusão é
  "seguro sob sequenciamento manual", não "sincronizado automaticamente".

## 9. Estado final + retenção/cleanup

- **Sandbox `p003-gw`:** NO AR (reutilizado entre sessões). UID
  `8216d179-9eed-4dc1-ab9c-97c0c6612b32`. Fixtures de S013/S014 removidas no
  rollback (ns p003-lc inexistente); só `p003-http` pré-existente resta.
  **Retenção:** manter (base das sessões futuras).
- **Testbed `p003-os`:** VMs da sessão deletadas; port a2-port deletado (back to
  2 ports de infra). Cloud intacta (ext-net/r-a/net-a/sg-a/m1.p003/cirros).
  **Retenção:** manter a infra C1 (reutilizável); custo = container 8GiB cap.
- **k01:** protegido, UID `45cb3818-248b-4dd2-b65c-5909bde08fe6` inalterado.
  **Retenção:** manter (baseline do lab).
- **Evidência bruta:** no host `/opt/poc-k8s-fabric-studies/…/evidence/P003/
  S01{3,4}/` — **retenção** (referenciada por path nos results).

## 10. Exercícios de leitura (estudante) + roteiro (instrutor)

**Estudante (leitura segura, sem mutação):**
1. Ler §3 (matriz) e §4 (contraste C03 vs C05) — identificar **por que** a
   authz por label não vaza e a por IP vaza.
2. Abrir `plans/P003-S014-results.md` §Janelas — localizar os timestamps do
   sampler e confirmar a janela de revogação (~1-7s).
3. Ler §6 (interpretação de fails) — para cada sinal, nomear a causa e a ação.
4. Rastrear o caminho VM→Pod no §2 — marcar os dois pontos de decisão de authz.

**Instrutor (roteiro):**
1. Partir da hipótese (§1) — "IP muda de dono; a regra antiga autoriza o novo
   dono?".
2. Mostrar C03 (label, negado) vs C05 (IP, permitido) lado a lado (§4) — o
   contraste é a lição.
3. Demonstrar a revogação manual (§2 sequenciamento) — por que "seguro sob
   sequenciamento manual" e não "sincronizado".
4. Fechar com o checklist de adoção (§8) — o que fazer em produção.
5. Perguntas de verificação: "o que acontece se o IP for reaproveitado sem
   revogar?", "por que `ingress: []` não funciona?", "como provar que o deny
   foi no CNP e não na rede?".

## 11. Perguntas do leitor novo (respostas sem contexto)

- **Qual cluster usar?** Sandbox `p003-gw` (kubeconfig
  `/root/.kube/p003-gw.config`) para os pods; testbed `p003-os` para as VMs;
  k01 é **somente leitura** (protegido).
- **Onde roda cada comando?** `kubectl` no host (com `sudo KUBECONFIG=…`);
  `openstack` **dentro** do container (`docker exec -i p003-os bash -s`);
  probes de counters **no pod** (`kubectl exec … /proc/net/snmp`).
- **Como provar consulta auth?** `cilium monitor` no worker (action allow/deny)
  + counters do pod (InEchos/OutRsts) — o deny aparece como counters flat.
- **Como detectar NodePort?** `kubectl get svc` (porta 30xxx); probe **do
  client do fabric** com `-H 'Host: echo.p003.study'` (do host → 000, não é
  regressão).
- **Como comprovar nó remoto?** `kubectl get pods -o wide` (NODE) + `cilium
  monitor` naquele worker; o worker2 (10.30.2.11) é o nó dos backends.
- **O que fazer se o IP não é reutilizado?** Marcar o caso de reuso
  BLOCKED/INCONCLUSIVE — **não** substituir por dois IPs diferentes e declarar a
  propriedade provada (C02: IPAM k8s não reaproveita; o reuso só é reproduzível
  no lado OpenStack por fixed IP).
- **Quando parar/escalar?** Gate de memória (container > 85% ou host < 1GiB)
  antes de spawn; qualquer restauração/ownership/teste final falhou → handoff
  BLOCKED com estado parcial (não afirmar que o ambiente foi restaurado).

---

**Referências:** `plans/P003/08-lifecycle.md` (spec), `plans/P003-S013-results.md`
(lado K8s), `plans/P003-S014-results.md` (lado VM), `plans/P003-design-contract.md`
(contrato), `plans/P003/publication-spec.md` (publicação futura). Sessões de
contexto do estudo (S003–S012): ver `plans/INDEX.md`.
