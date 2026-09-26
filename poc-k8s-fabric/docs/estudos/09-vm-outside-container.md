# C5 — VM fora do container: RX resolvido e pod↔VM bidirecional (edição pública)

> **Escopo:** edição pública sanitizada da emenda **C5** (S016) — rodar a VM em
> **KVM real no host** (fora do container) para resolver a limitação conhecida
> **D-S012-13** (RX da VM morto em KVM aninhado no container, que bloqueava o
> sentido pod→VM) e provar tráfego **bidirecional pod↔VM**, preservando o
> datapath Neutron (qdhcp + qrouter + SG). Sem credenciais, sem paths pessoais
> e sem UIDs observados; os valores de rede são internos ao laboratório e
> ilustrativos. Cada afirmação aponta para a evidência datada mantida na árvore
> Reentry local (privada); este documento não re-executa nada.
> **Versões fixas:** Cilium 1.20.2, Gateway API 1.6.1, K8s v1.35.0, OpenStack
> (DevStack-in-container, neutron 34.x), cirros-0.6.0.
>
> **Dossiês de planejamento:** [E07 — tenant híbrido](07-openstack.md) ·
> [síntese E08](08-lifecycle-synthesis.md).

## 1. A limitação que a C5 resolve (D-S012-13)

Na trilha E07/E08 a VM Nova roda **dentro** do container do testbed
(DevStack-in-container). O hypervisor da VM é então um **KVM aninhado** (o
container já roda sobre um KVM do host). O sintoma medido (D-S012-13, na trilha
E07/E08) é assimétrico:

- **TX da VM funciona** — os pacotes saem do `tap` (DHCP requests, probes).
- **RX da VM falha** — a VM não recebe (sem resposta a ARP/ping/curl; o DHCP
  sai sem OFFER). O datapath entrega o tráfego ao `tap` (proven por tcpdump);
  a falha está no guest.

Consequência prática: o sentido **pod→VM dava timeout/000** (a VM não recebia o
ICMP do pod), enquanto **VM→pod funcionava** (a TX da VM era entregue). A
matriz E08 foi encerrada com esse limite conhecido (gate rebaixado); a C5 é a
única saída que o resolve por construção.

## 2. A abordagem C5 — KVM real no host

A C5 move o **hypervisor da VM para fora do container**: a VM roda em **KVM
real no host** (usando o `/dev/kvm` do host diretamente, fora do isolamento de
netns/cgroup do container) e é conectada à **mesma rede tenant** do testbed por
uma **ponte veth** que atravessa a fronteira host↔container. O datapath
Neutron (qdhcp, qrouter, SG) é **preservado** — a VM continua obtendo IP por
DHCP e passando pelo roteador e pelo security group.

**Por que resolve:** o RX morto (D-S012-13) era específico da VM rodando
**dentro** do container (KVM aninhado + isolamento do container). Com a VM em
KVM real no host, fora do container, o guest recebe normalmente — o sentido
pod→VM passa a funcionar. A VM não é mais uma VM Nova gerenciada pelo compute
(que apontaria para o container); é uma VM `qemu` direta no host, com NIC
ligada a um `tap` que a ponte leva até o `br-int` do container.

## 3. Topologia da ponte host↔container

```
VM (qemu, KVM real no host)
  └─ NIC virtio ─ tap-c5 ─ br-c5 (bridge do host)
                       └─ veth-c5-host ═══ veth-c5-ctr (netns do container)
                                              └─ br-int (OVS, ofport tag VLAN 1)
                                                    ├─ qdhcp  (interface 10.30.0.2)
                                                    └─ qrouter (tenant 10.30.0.1 / ext 10.40.0.181)
```

- A ponta do **host** (`br-c5` + `tap-c5`) é onde a NIC da VM se conecta.
- O **par veth** atravessa a fronteira: `veth-c5-host` (host) ↔ `veth-c5-ctr`
  (netns do container).
- A ponta do **container** entra no `br-int` do OVS **como um port tagado
  (VLAN 1)** — a rede tenant 10.30.0.0/24 roda em VLAN 1 no `br-int`.
- O **qdhcp** (dnsmasq) e o **qrouter** ficam nos seus **netns próprios**
  (`qdhcp-<net-uuid>`, `qrouter-<net-uuid>`), não no netns raiz do container
  onde vive o `br-int`.

O egress da VM segue o datapath Neutron completo: VM → qrouter (10.30.0.1) →
interface externa (10.40.0.181) → rede externa → sandbox (pods). O IP da VM
(10.30.0.50/24) é atribuído pelo **qdhcp** via DHCP.

## 4. Os três pontos de integração (o que custou tempo)

A ponte host↔container tem três armadilhas que bloqueiam o DHCP/tráfego de
forma **silenciosa** (a VM cai em link-local 169.254.x.x sem erro visível).
Foram encontradas por tcpdump de ponta a ponta na fronteira host/container/netns:

1. **A ponta do container do veth PRECISA de tag VLAN 1.**
   A rede tenant roda em VLAN 1 no `br-int` (os ports do qdhcp/qrouter têm
   `tag: 1`). Um veth **untagged** entrega o DISCOVER da VM ao ofport, mas o
   frame não casa com os ports **tagados** no egress do OVS — o DISCOVER chega
   à ponta do veth e **não** chega ao qdhcp. Fix:
   `ovs-vsctl set port <veth> tag=1`.
2. **O dnsmasq do qdhcp precisa de `kill -HUP` para recarregar o
   `dhcp-hostsfile`.** O dnsmasq roda num netns próprio, foi subido **antes**
   do MAC da VM ser adicionado ao hostsfile, e o `--dhcp-range` é `static`
   (só atende MACs que estão no hostsfile). O inotify não pegou o append; o
   `kill -HUP <pid-dnsmasq>` forçou o reload e o OFFER apareceu. (Distinto do
   D-S014-1, que é RPC timeout do `neutron-dhcp-agent` → reiniciar o agente.)
3. **qdhcp/qrouter vivem em netns separados** (`qdhcp-…`/`qrouter-…`), não no
   netns raiz do container. Para inspecionar o DHCP, capturar **dentro** do
   netns: `ip netns exec qdhcp-<net-uuid> tcpdump -i <qdhcp-iface>`. O netns do
   qrouter guarda a interface tenant (10.30.0.1) e a externa (10.40.0.181).

**Diagnóstico que isola a causa:** capturar o DHCP nas duas pontas. Se o
DISCOVER aparece na ponta do veth mas **não** no netns do qdhcp → falta a tag
VLAN (item 1). Se o DISCOVER chega ao qdhcp mas **não** há OFFER → o MAC não
está no hostsfile recarregado (item 2).

## 5. Resultados — bidirecional pod↔VM

| Teste | Antes (KVM aninhado) | C5 (KVM real no host) |
|---|---|---|
| **pod→VM** (o sentido bloqueado, D-S012-13) | timeout/000 (RX morto) | **0% loss** (RX vivo) |
| **VM→pod** (via qrouter 10.30.0.1→10.40.0.181) | 0% loss (TX ok) | **0% loss** |
| **CNP allow** (`fromCIDR` = IP da VM /32) → pod de teste | — | **0% loss** |
| **CNP deny** (VM fora do allow) → pod de teste | — | **100% loss** |

- **pod→VM** (a direção que estava bloqueada) agora funciona: a VM recebeu o
  ICMP do pod e respondeu — RX vivo em KVM real.
- **VM→pod** segue o datapath Neutron completo (qrouter + OVS + SG).
- **CNP no caminho:** um `CiliumNetworkPolicy` no pod de teste, com
  `ingress.fromCIDR` = IP da VM, permite (0% loss); ao retirar a VM do allow
  (apontar o `fromCIDR` para um CIDR que a VM não tem), o VM→pod é negado
  (100% loss) — o enforcement do Cilium é confirmado no caminho.
- **SG** (`sg-a`) ativo na porta da VM; os fluxos SG do OVS para o ofport da
  ponte foram adicionados e ativos durante o tráfego.

## 6. Lição — por que KVM real resolve

O RX morto **não** era um bug de rede nem de configuração Neutron: era o guest
em KVM aninhado. Mover o hypervisor para KVM real no host elimina a causa por
construção — sem mudar o datapath. A lição para o desenho do testbed:

- **VM em KVM aninhado (container sobre KVM) tem RX intermitente/morto** —
  trate como limitação estrutural, não como falha de rede a depurar.
- **Para tráfego real bidirecional pod↔VM, a VM precisa de KVM real** (fora do
  container). O datapath Neutron (qdhcp/qrouter/SG) continua íntegro.
- **A authz (CNP por CIDR) ancora no endereço, não na identidade** (ver
  [síntese E08](08-lifecycle-synthesis.md) §4) — a C5 confirma o enforcement no
  caminho bidirecional, mas não muda essa propriedade.

## 7. Reprodução (comandos sanitizados)

**Variáveis** (defina antes; convenção `STUDY_*` do [dossiê E07](07-openstack.md)):

```bash
# no Mac: alvo SSH do host + chave; no host: kubeconfig do sandbox
export REFERENCE_SSH_TARGET='user@host'          # host onde a VM roda (KVM real)
export REFERENCE_SSH_KEY='/secure/path/reference-key'
export REFERENCE_KUBECONFIG='/secure/path/sandbox-kubeconfig'
export REFERENCE_CONTEXT='kind-sandbox'

# valores do experimento (substitua pelo seu inventário)
export STUDY_OS_CONTAINER='testbed-os'            # container do testbed OpenStack
export STUDY_CIRROS_IMG='/tmp/cirros.qcow2'       # imagem cirros no host
export STUDY_VM_MAC='fa:16:3e:00:00:01'           # MAC da NIC da VM
export STUDY_VM_IP='10.30.0.50'                   # IP fixo (subnet-a)
export STUDY_VM_PASSWORD='gocubsgo'               # senha padrão do cirros
export STUDY_NET_ID='<net-a-uuid>'                 # rede tenant
export STUDY_SUBNET_ID='<subnet-a-uuid>'
export STUDY_SG_ID='<sg-a-uuid>'
export STUDY_DNSMASQ_PID='<pid-dnsmasq>'           # dnsmasq do qdhcp
export STUDY_HOSTSFILE='/opt/stack/data/neutron/dhcp/<net-a-uuid>/host'
export STUDY_NS='p003-test'                         # namespace do pod de teste
export STUDY_POD='echo-0'                           # nome do pod de teste
export STUDY_POD_IP='10.245.1.16'                   # IP do pod de teste
```

**1. Porta Neutron + DHCP** (dentro do container do testbed, `bash`, sem pipe no
`source` — pipe coloca o `source` em subshell e perde as variáveis):

```bash
# delimitador SEM aspas: o shell do host expande as variáveis $STUDY_* antes
# de enviá-las ao container (o bash do container não herdaria as variáveis do host)
docker exec -i "$STUDY_OS_CONTAINER" bash -s <<EOS
  . /opt/stack/devstack/openrc admin admin
  openstack port create --network "$STUDY_NET_ID" \
    --fixed-ip subnet="$STUDY_SUBNET_ID",ip-address="$STUDY_VM_IP" \
    --security-group "$STUDY_SG_ID" c5-vm
EOS
# registrar o MAC no hostsfile do qdhcp e forçar o reload:
docker exec "$STUDY_OS_CONTAINER" bash -c \
  "echo '$STUDY_VM_MAC,host,${STUDY_VM_IP}' >> '$STUDY_HOSTSFILE'; kill -HUP '$STUDY_DNSMASQ_PID'"
```

**2. Ponte host↔container** (no host):

```bash
# par veth: ponta host + ponta container
ip link add veth-c5-host type veth peer name veth-c5-ctr
ip link set veth-c5-ctr netns "$(docker inspect -f '{{.State.Pid}}' "$STUDY_OS_CONTAINER")"
# ponta container entra no br-int COMO PORT TAGADO (VLAN 1)
docker exec "$STUDY_OS_CONTAINER" bash -c \
  "ip link set veth-c5-ctr up; ovs-vsctl add-port br-int veth-c5-ctr; ovs-vsctl set port veth-c5-ctr tag=1"
# bridge + tap no host para a NIC da VM
ip link add br-c5 type bridge; ip link set br-c5 up
ip link add tap-c5 type tap; ip link set tap-c5 master br-c5; ip link set tap-c5 up
ip link set veth-c5-host master br-c5; ip link set veth-c5-host up
```

**3. Lançar a VM em KVM real no host:**

```bash
qemu-system-x86_64 -enable-kvm -m 512 -smp 1 \
  -drive file="$STUDY_CIRROS_IMG",format=qcow2,if=virtio \
  -netdev tap,ifname=tap-c5,script=no,downscript=no,id=net0 \
  -device virtio-net-pci,netdev=net0,mac="$STUDY_VM_MAC" \
  -display none -daemonize
```

**4. Verificar o DHCP e o tráfego bidirecional:**

```bash
# a VM deve obter $STUDY_VM_IP via qdhcp (não 169.254.x.x)
sshpass -p "$STUDY_VM_PASSWORD" ssh -o StrictHostKeyChecking=no cirros@"$STUDY_VM_IP" \
  'ip -4 addr show eth0 | grep inet'
# pod→VM (o sentido antes bloqueado) e VM→pod
sudo kubectl --kubeconfig "$REFERENCE_KUBECONFIG" --context "$REFERENCE_CONTEXT" \
  -n "$STUDY_NS" exec "$STUDY_POD" -- ping -c 3 -W 2 "$STUDY_VM_IP"
sshpass -p "$STUDY_VM_PASSWORD" ssh -o StrictHostKeyChecking=no cirros@"$STUDY_VM_IP" \
  "ping -c 3 -W 2 $STUDY_POD_IP"
```

**Gate de memória por spawn:** container ≤ 6.8GiB (85%) **e** host ≥ 1GiB
available; senão abortar/escalar.

## 8. Checklist de adoção

- [ ] **VM para tráfego real bidirecional:** rodar em **KVM real** (fora do
  container). KVM aninhado tem RX intermitente/morto (D-S012-13).
- [ ] **Ponte veth → br-int:** a ponta do container **precisa de `tag=1`**
  (VLAN da rede tenant). Sem a tag, o DHCP/tráfego não cruza para os ports
  tagados (qdhcp/qrouter).
- [ ] **DHCP da VM nova:** adicionar o MAC ao `dhcp-hostsfile` **e** `kill -HUP`
  no dnsmasq do qdhcp (range `static`). Se a VM cair em 169.254.x.x, checar
  isso antes de tudo (e o D-S014-1: RPC timeout → reiniciar o agente).
- [ ] **Inspecionar o DHCP:** capturar **dentro** do netns do qdhcp
  (`ip netns exec qdhcp-<net-uuid> tcpdump …`), não no netns raiz.
- [ ] **CLI OpenStack:** `source …/openrc admin admin` **sem pipe**; `openstack`
  roda **dentro** do container do testbed.
- [ ] **Acesso à VM:** `sshpass -p <senha-cirros> ssh cirros@<ip>` (dropbear no
  cirros); o cirros **não** tem `timeout` — usar `ping -c N -W S`.
- [ ] **Authz (CNP por CIDR):** revogar o CIDR antes de reutilizar o IP
  (sequenciamento manual — síntese E08 §4).

## 9. Estado final + rollback

Rollback em ordem reversa (executado e verificado):

1. Matar a VM (`qemu`) e remover o fixture K8s de teste (`kubectl delete ns`).
2. Remover os fluxos SG do ofport da ponte (`ovs-ofctl del-flows br-int …`).
3. Remover o par veth (a ponta do container derruba a do host) **e** o port OVS
   residual: `ovs-vsctl --if-exists del-port br-int <veth>` (o port fica
   **stale** após o netdev sumir — precisa ser removido explicitamente).
4. `openstack port delete <uuid>`; remover o bridge/tap do host.
5. Retirar o MAC do `dhcp-hostsfile`.

**Verificação de integridade pós-rollback:** UIDs do sandbox e do cluster
protegido inalterados (`<uid-do-sandbox>` / `<uid-do-k01>`); `ovs-vsctl show`
sem o veth; 3 agentes Neutron Alive; `openstack port list` só com os ports de
infra; canário do cluster protegido 10/10; memória do testbed de volta ao
baseline. **Retenção:** manter a infra (reutilizável); a VM e a ponte são
descartadas no rollback.

## 10. Perguntas do leitor novo

- **Por que o RX morre no container?** A VM dentro do container roda em KVM
  aninhado + isolamento de netns/cgroup — o guest não recebe (D-S012-13). KVM
  real no host, fora do container, resolve por construção.
- **A VM continua no datapath Neutron?** Sim — IP por qdhcp (DHCP), egress por
  qrouter, SG ativo na porta. A ponte só muda *onde* o hypervisor roda.
- **Por que a VM cai em 169.254.x.x?** Falta a tag VLAN no veth (item 1) ou o
  MAC não está no hostsfile recarregado (item 2). Isolar com tcpdump nas duas
  pontas (§4).
- **O pod→VM passou por SG/OVS?** O RX da VM fica provado independentemente do
  caminho (a VM recebeu e respondeu); o VM→pod seguiu o datapath Neutron
  completo. Um IP no bridge do host dá atalho L2 para SSH/ping, mas o RX é
  comprovado de qualquer forma.
- **Isso muda a conclusão da E08 (authz por IP)?** Não — confirma o enforcement
  do CNP no caminho bidirecional; a propriedade "authz por CIDR segue o
  endereço" permanece (síntese E08 §4).

---

**Referências:** [dossiê E07](07-openstack.md), [dossiê E08](08-lifecycle.md),
[síntese E08](08-lifecycle-synthesis.md), [contrato técnico](design-contract.md),
[protocolo de execução](execution-protocol.md). Results datados e evidência
bruta: árvore Reentry local (privada).
