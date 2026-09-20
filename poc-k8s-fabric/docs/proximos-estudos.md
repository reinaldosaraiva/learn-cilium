# Próximos estudos

As propostas abaixo são desenhos de laboratório. Não foram aplicadas ao ambiente vivo `k01` e não fazem parte do exercício básico.

O [índice público dos estudos P003](estudos/README.md) é o roteiro completo,
revisado em 20/09/2026, com 14 sessões previstas. Gateway API vem primeiro:
consulte os dossiês de [Gateway e BGP](estudos/01-gateway-bgp.md), [L4 e host
network](estudos/02-l4-hostnetwork.md) e [ExternalAuth](estudos/03-externalauth.md)
antes das trilhas de tenants, IPAM e integração híbrida. O preflight é somente
leitura e nenhum experimento foi executado por esta publicação.

## Ordem pública dos estudos

O plano começa com Gateway HTTP/TCP/UDP e anúncios VIP+BGP. Em seguida mede a
exposição L4, a autorização externa e os caminhos native/VXLAN. Só depois trata
de tenants, Multi-Pool IPAM e OpenStack/lifecycle, sempre em sandbox isolado e
com evidência própria. Os dossiês são planos detalhados; não concedem acesso ou
autorização para alterar o laboratório de referência.

## PodCIDR `/24` versus blocos `/32`

O desenho atual usa IPAM Kubernetes e um PodCIDR IPv4 `/24` por nó. O Cilium anuncia esse bloco pelo anúncio `PodCIDR`; um pod novo que recebe um endereço desse bloco já está coberto pela rota do nó. O VIP do Service continua sendo um anúncio de serviço `/32`.

A comparação causal principal do estudo usa Multi-Pool nos dois braços: `M24`
com `maskSize: 24` e `M32` com `maskSize: 32`, mantendo versões, três nós,
imagens, afinidades, probes, timers BGP e subnet constantes. O braço `K24`
(IPAM Kubernetes e `/24` por nó) é referência histórica adicional, não o
contraste principal. Cada pool é executado em cluster ou reconstituição
experimental separada; não alterar o IPAM de `k01`.

Uma variante pode estudar pools com blocos `/32` e um anúncio BGP de pool de pods. A documentação estável do Cilium descreve `maskSize: 32` no Multi-Pool IPAM e o tipo de anúncio `CiliumPodIPPool` para blocos alocados a um `CiliumNode` ([Multi-Pool IPAM](https://docs.cilium.io/en/stable/network/concepts/ipam/multi-pool/) e [configuração do BGP Control Plane](https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-configuration/)). Aplicar essa composição ao sandbox Cilium `1.20.2` do novo plano; o lab `1.20.1` permanece apenas como referência histórica preservada, não como resultado desta hipótese.

Mesmo ignorando o tamanho da FIB, os comportamentos são diferentes:

| Pergunta | `M24`: Multi-Pool `/24` | `M32`: Multi-Pool `/32` |
|---|---|---|
| Pod recém-criado no nó | já coberto quando há IP livre em bloco alocado e anunciado | depende de alocação e anúncio do bloco |
| Seleção de caminho por IP | granularidade do nó | pode ser granular por endereço |
| Morte de um pod | rota do nó continua válida para o bloco | bloco reservado pode continuar anunciado; não presumir retirada por readiness |
| Recriação efêmera | o pod pode receber outro IP dentro do bloco | pode receber outro IP e outro UID; a rota antiga não preserva TCP |
| Pergunta de convergência | “o PodCIDR do nó chegou?” | “quando o bloco foi alocado, anunciado e retirado?” |

O experimento deve manter três nós e medir `M24` e `M32` com seis e quarenta
réplicas. `K24` entra como controle histórico adicional:

1. medir criação do pod, alocação do IP, anúncio no Cilium e chegada no spine;
2. apagar somente recursos do laboratório experimental e medir retirada do anúncio;
3. recriar pods efêmeros e registrar se o IP muda;
4. testar alcance direto de pod e alcance do VIP de serviço;
5. comparar tempos de convergência e comportamento durante a troca de nó.

A recomendação para o lab didático permanece `/24` para pods e `/32` para VIPs. A variante `/32` deve existir quando houver uma necessidade de seleção de caminho por endereço, e deve ser validada com as regras de alocação e retirada do produto escolhido.

## Isolamento declarativo entre tenants

Uma aproximação de VPC lógica pode ser estudada sem alterar o código da aplicação:

- um namespace por tenant, com labels imutáveis ou controlados pelo administrador;
- `CiliumNetworkPolicy` ou `CiliumClusterwideNetworkPolicy` em default deny;
- regras explícitas de ingress e egress por identidade, namespace e ServiceAccount;
- exceção mínima para DNS e para os serviços compartilhados necessários;
- RBAC que limite recursos, verbos e namespaces, incluindo quem pode editar policies e ler Secrets;
- Pod Security Admission com perfil `restricted` (quando aplicável) para restringir workloads privilegiados, `hostNetwork` e outros campos de `PodSpec`;
- `ValidatingAdmissionPolicy` ou webhook para exigir e proteger a presença/imutabilidade dos labels de tenant;
- Hubble para verificar fluxos permitidos e bloqueados antes e depois de recriar pods.

Uma política inicial precisa casar origem de egress, destino de ingress e DNS; um default deny isolado pode interromper aplicações. O tráfego de resposta de uma conexão permitida é acompanhado pelo estado do Cilium e não exige uma regra de “retorno” separada. As políticas são aditivas: deve-se auditar as regras existentes e testar a combinação antes de aplicar a mudança.

Exemplo de ponto de partida para um namespace de laboratório, ainda incompleto sem as regras de allow adicionais:

~~~yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: tenant-default-deny
  namespace: tenant-a
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
~~~

Esse controle de identidade não é uma rota BGP. Ele não isola o kernel compartilhado do host, não cria VRF nem espaços de endereçamento independentes e não permite CIDRs sobrepostos. A pergunta do estudo é se namespaces, identidades, RBAC, admissão e observabilidade entregam a separação lógica necessária para os tenants do produto.

Fontes: [políticas Kubernetes do Cilium](https://docs.cilium.io/en/stable/security/policy/kubernetes/), [default deny do Kubernetes](https://kubernetes.io/docs/concepts/services-networking/network-policies/#default-deny-all-ingress-and-all-egress-traffic) e [introdução à segurança do Cilium](https://docs.cilium.io/en/stable/security/).

## Proposta principal: tenant híbrido Kubernetes + OpenStack

O próximo laboratório pode juntar pods Kubernetes e VMs OpenStack no mesmo desenho de tenant. O caso mínimo é: `tenant-a/api-pod` pode alcançar `db-vm-a`; `tenant-b/api-pod` é recusado; depois ambos os recursos são recriados, inclusive com possível reutilização de IP, e o teste confirma que não ficaram autorizações nem rotas antigas.

Separe as três perguntas do experimento:

1. **Alcance:** BGP e o underlay conseguem levar o pacote ao prefixo do pod ou da VM?
2. **Autorização:** as políticas Cilium protegem os pods e os Security Groups/port security do Neutron protegem as VMs?
3. **Ciclo de vida:** quem atualiza cada identidade e regra quando um pod ou uma VM nasce, morre ou troca de IP?

O desenho deve começar com PodCIDR `/24` e VIP `/32`, e depois comparar uma variante `/32` para blocos de pods. Não se deve afirmar sincronização automática entre identidade Kubernetes e Security Group Neutron sem um controlador ou integração implementada e testada. O suporte a anúncios BGP no Neutron e os detalhes de port security dependem da implantação OpenStack escolhida; confirme-os antes do experimento ([Neutron dynamic routing](https://docs.openstack.org/neutron/latest/admin/config-bgp-dynamic-routing.html) e [introdução à rede OpenStack](https://docs.openstack.org/neutron/2024.2/admin/intro-os-networking.html)).
