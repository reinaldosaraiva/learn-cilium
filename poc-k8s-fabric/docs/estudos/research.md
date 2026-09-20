# Pesquisa primária — P003

Data de consulta: 2026-09-20. Nenhum experimento remoto executado nesta pesquisa.
Documentação `stable` é móvel; execução usa tags/SHAs abaixo e reconfirma o estado
de issues antes do teste. Uma atualização posterior não pode reescrever resultados antigos.

## Versões de referência

| Componente | Referência pesquisada | Uso no plano |
|---|---|---|
| Cilium existente | 1.20.1, registro local 19/09 | Baseline histórico protegido |
| Cilium alvo | v1.20.2, commit e0dc92bd6dac33d7ba3b5eace82a0448bbb13aac | Sandbox principal, patch com correção ExternalAuth |
| Gateway API | v1.6.1, commit 8bb74df00e56ec8f944d48c25e6c1c9c2f6848e3 | CRDs experimental para ExternalAuth; versões servidas verificadas |
| Kubernetes | kindest/node v1.35.0, digest no arquivo de topologia | Candidato de reprodução local, não mesma versão da issue |
| FRR / SR Linux | 8.4.1 / 25.3.2 no kit | Reusar baseline; sem atualização incidental |
| Issue 46768 | Cilium 1.20.0-pre.3, Talos 1.13.4, K8s 1.36.2 | Referência histórica, não baseline de produção |
| OpenStack | desconhecido | S011 MUST descobrir release, backend, permissões e extensões |

Digests de imagens de aplicação e chart checksum são pendências determinísticas
de S002/S003. MUST resolvê-los antes de executar; não usar latest para fechar gates.

## Classificação das alegações

| ID | Alegação | Evidência / limite | Consequência |
|---|---|---|---|
| F01 | 1.20 integra Gateway API v1.6.1 após v1.4 | Release oficial R01 | Não confundir versão das CRDs com versão do Cilium |
| F02 | TCPRoute e UDPRoute no Standard; ExternalAuth experimental | R02, R03, R04, R05 | Instalar schema certo e verificar campo persistido |
| F03 | L4 evita Envoy; usa Service/EndpointSlices | Código tagged R06/R07 + R08 | Logs Envoy não provam tráfego TCP/UDP |
| F04 | gatewayAPI.hostNetwork muda Service para NodePort | toServiceType em R06 | Verificar nodePort alocado, não assumir listener no host |
| F05 | ExternalAuth remoto fica sem resposta com WireGuard/VXLAN | Relato R09; pré-release; sem pcap; need-more-info | Reprodução controlada, sem declarar causa antes da evidência |
| F06 | Referência inválida de ExternalAuth podia omitir filtro | PR R10 e release R11 | Controle negativo obrigatório de Service/port/ReferenceGrant |
| F07 | Demo oficial auth sempre permite | R12 README/main | Serve apenas como smoke; construir/adaptar fixture negativa antes do aceite |
| F08 | HTTP auth usa timeout de 10s no código 1.20.2 | R13 | Não encerrar curl antes do timeout e chamar isso fail-closed |
| F09 | WireGuard tem modos de cobertura e opt-out de control-plane | R14 | Matriz entre workers; nodeEncryption não é correção presumida |
| F10 | ListenerSets compartilham Gateway com delegação por namespace | R15 | Testar permissions, conflito por listener, Secret/Grant próprio |
| F11 | /32 são blocos alocados ao nó; há preallocation | R16/R17 | Remover pod não implica retirada imediata de rota |
| F12 | SG Neutron e identidade Cilium têm autoridades diferentes | R18/R19/R20 | Mapear origem efetiva/NAT e revogação de permissões |

## Fontes e recortes de uso

### R01 — release Cilium
[v1.20.0](https://github.com/cilium/cilium/releases/tag/v1.20.0).
Confirma conjunto de funcionalidades e salto de Gateway API. Não prova uma
combinação particular de knobs nem a disponibilidade de infraestrutura local.

### R02 — contexto/maturidade
[Anúncio do projeto na CNCF](https://www.cncf.io/blog/2026/09/14/cilium-1-20-gateway-api-externalauth-tcproute-udproute-eni-ipam-for-ipv6-and-more/).
Publicado 14/09; é contextualização do projeto. TLSRoute/CORS/ListenerSets e
TCPRoute/UDPRoute têm histórico de graduação distinto de ExternalAuth.

### R03 — TCPRoute
[Guia upstream](https://gateway-api.sigs.k8s.io/guides/user-guides/tcp/).
Listener TCP e parentRefs.sectionName ligam rota e porta; backendRef.port é
a porta do Service. API v1 está no Standard desde 1.6. Testar payload, não só SYN.

### R04 — UDPRoute
[Guia upstream](https://gateway-api.sigs.k8s.io/guides/user-guides/udp/).
Datagramas são ligados ao listener UDP. TCP e UDP com mesmo número de porta são
protocolos distintos. Um processo nc terminando com zero não prova entrega UDP.

### R05 — schema exato de ExternalAuth
[HTTPRoute types v1.6.1](https://github.com/kubernetes-sigs/gateway-api/blob/v1.6.1/apis/v1/httproute_types.go)
e [GEP-1494](https://gateway-api.sigs.k8s.io/geps/gep-1494/).
O filtro está marcado experimental. HTTP usa resposta 200 para permitir; gRPC
usa o protocolo Check de ext_authz, não uma resposta HTTP arbitrária.
Campos de policy futuros no GEP não são promessa de implementação no Cilium.

### R06 — tradução do Gateway
[translator.go v1.20.2](https://github.com/cilium/cilium/blob/v1.20.2/operator/pkg/model/translation/gateway-api/translator.go).
Inspecionados Translate, desiredService, toServicePorts e toServiceType.
Service gerado recebe ownership/labels; hostNetwork prioriza NodePort.
Somente HTTP/TLS passthrough demanda CiliumEnvoyConfig.

### R07 — reconciliação de L4
[gateway_reconcile.go v1.20.2](https://github.com/cilium/cilium/blob/v1.20.2/operator/pkg/gateway-api/gateway_reconcile.go)
e [endpointslices.go](https://github.com/cilium/cilium/blob/v1.20.2/operator/pkg/model/translation/gateway-api/endpointslices.go).
EndpointSlices de L4 acompanham backends. O experimento deve observar a porta,
protocolo, endereço e ownership finais; não editar manualmente objetos reconciliados.

### R08 — pré-requisitos e exposição
[Gateway API Support](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/).
KPR e L7 proxy; CRDs detectadas pelo controlador; LB-IPAM e anúncio são etapas
distintas. O aviso host network/TCP/UDP permanece na documentação consultada.
Para HTTP, policy tem pontos world→ingress e ingress→backend.

### R09 — relato WireGuard
[Issue 46768](https://github.com/cilium/cilium/issues/46768).
Aberta em 27/06/2026; consulta API em 20/09: open, need-more-info e stale.
Envoy→oauth2-proxy remoto, VXLAN, nodeEncryption=false; SYNs sem resposta no
emissor. Autor não confirmou causa. Mantenedor solicitou sysdump.
Não é o handshake SPIRE da issue 46767; não comprova regressão da versão estável.

### R10 — falha de autorização por referência
[Issue 47877](https://github.com/cilium/cilium/issues/47877) e
[PR 47929](https://github.com/cilium/cilium/pull/47929).
Referência inválida podia retirar filtro com rota ativa. Fix retorna erro e
mantém bloqueio; casos incluem backend ausente e cross-namespace sem Grant.

### R11 — backport
[Release v1.20.2](https://github.com/cilium/cilium/releases/tag/v1.20.2).
Inclui backport 48017 do fix 47929. Sua presença não comprova que a issue 46768
foi resolvida. Um teste 1.20.1 pode caracterizar o defeito em ambiente descartável.

### R12 — fixture oficial
[ExternalAuth demo v1.20.2](https://github.com/cilium/cilium/tree/v1.20.2/examples/kubernetes/gateway/external-authz).
HTTP 8080/gRPC 9000, logs e cabeçalho de teste; sempre autoriza. Reusar como smoke,
mantendo a licença; S005 deve fornecer deny/timeout com comportamento verificável.

### R13 — transporte ao autorizador
[envoy_http_connection_manager.go v1.20.2](https://github.com/cilium/cilium/blob/v1.20.2/operator/pkg/model/translation/envoy_http_connection_manager.go).
HTTP ServerUri usa 10 segundos nesta tag. Não inventar um campo de timeout no
ExternalAuth schema. Observar também configuração xDS e limite do cliente.

### R14 — criptografia e observabilidade
[WireGuard](https://docs.cilium.io/en/stable/security/network/encryption-wireguard/),
[fonte tagged](https://github.com/cilium/cilium/blob/v1.20.2/Documentation/security/network/encryption-wireguard.rst),
[Access Logs](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/access-logs/).
UDP 51871; tráfego local não é cifrado no fio; tabela de cobertura depende de
origem/caminho. Captura em cilium_wg0 vê pacote interno; inspeção do underlay é
necessária para provar cifra. Control-plane sai de nodeEncryption por padrão.

### R15 — delegação e TLS
[ListenerSet](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/listenerset/),
[BackendTLSPolicy](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/backendtlspolicy/).
Gateway precisa de listener próprio válido; allowedListeners/allowedRoutes
controlam anexação, não isolamento de pacotes. TLS upstream valida nome e CA;
terminação TLS externa não prova criptografia ao backend.

### R16 — alocação de pods
[Multi-Pool](https://docs.cilium.io/en/stable/network/concepts/ipam/multi-pool/)
e [fonte v1.20.2](https://github.com/cilium/cilium/blob/v1.20.2/Documentation/network/concepts/ipam/multi-pool.rst).
maskSize imutável; reservas podem sobreviver a pods; pools sobrepostos não são
suportados. O default de preallocation é relevante para interpretar rotas ociosas.
Schema de API deve vir da CRD instalada: não copiar v2alpha1 de exemplos móveis.

### R17 — anúncios
[BGP Control Plane Resources](https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-configuration/).
PodCIDR e CiliumPodIPPool são anúncios diferentes. Para Multi-Pool, selecionar
os pools e observar os blocos efetivamente alocados ao CiliumNode.

### R18 — Kubernetes/identidade
[Cilium policies](https://docs.cilium.io/en/stable/security/policy/kubernetes/),
[Kubernetes multi-tenancy](https://kubernetes.io/docs/concepts/security/multi-tenancy/),
[Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/),
[ValidatingAdmissionPolicy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/).
Namespace, identidade, RBAC e admissão têm responsabilidades diferentes.
Labels alteráveis pelo tenant não podem servir de fronteira confiável sozinhos.

### R19 — rede OpenStack
[Networking](https://docs.openstack.org/neutron/latest/admin/intro-os-networking.html),
[BGP dynamic routing](https://docs.openstack.org/neutron/latest/admin/config-bgp-dynamic-routing.html),
[OVN features](https://docs.openstack.org/neutron/latest/admin/ovn/features.html).
Port security, SGs, provider/project networks e backend dependem da implantação.
Instalar Cilium não cria integração automática com Neutron ou BGP speaker.
Fontes latest são explicação geral; S011 deve fixar documentação da release real.

### R20 — VM representada como backend
[Services sem selector](https://kubernetes.io/docs/concepts/services-networking/service/#services-without-selectors).
Service/EndpointSlice pode apontar para endpoint externo alcançável; não cria
rota, identidade Kubernetes para a VM ou sincronização automática de ciclo de vida.

## Lacunas que exigem descoberta, não palpite

- Saúde atual, RAM livre, espaço e sub-redes da VM; S002 somente leitura.
- Imagens fixture por digest, flags do CLI local, CRD schema realmente servido.
- Cobertura da cifra de conexões geradas pelo Envoy no cenário exato de auth.
- Reprodução da issue em 1.20.2; não foi medida por esta pesquisa.
- OpenStack, acesso, release, quotas, driver, BGP disponível e origem após NAT.
- Reutilização determinística de IP de pod: não é assegurada por delete/recreate.

## Evidência negativa de pesquisa

Algumas URLs presumidas (tcp/, udp/, external-auth/, backend-tls/ no Cilium)
não resolveram. Foram substituídas por guias upstream, links reais do índice
e fonte tagged. Nenhum comando de execução dependerá de URL adivinhada.
