# E02 — Portas TCP/UDP e host network

Sessão prevista S004; depende de E01. Fontes R03/R04/R06/R07/R08.
`host network` significa exclusivamente `gatewayAPI.hostNetwork.enabled`.
Backend continua pod normal; não alterar Pod.spec.hostNetwork para tentar reproduzir.

## Hipótese e medidas

Em 1.20.2, o tradutor escolhe Service NodePort quando hostNetwork está ligado.
Para L4 não há listener Envoy que reproduza a porta configurada no host.
Hipótese é por produto/versão; observar antes de concluir. A combinação é
documentada sem suporte e seu comportamento não é uma promessa de compatibilidade.

Para cada protocolo, registrar cinco campos distintos:
`Gateway.listeners.port`, `Service.port`, `Service.nodePort`,
`EndpointSlice.ports.port` e destino efetivamente usado pelo cliente.
Porta de origem efêmera do cliente é outro campo e não entra nessa comparação.

## Matriz

| Caso | Exposição | Protocolo | Probe principal | Resultado esperado a verificar |
|---|---|---|---|---|
| L401 | hostNetwork OFF, LoadBalancer | TCP | VIP:15432 | payload chega ao backend |
| L402 | hostNetwork OFF, LoadBalancer | UDP | VIP:15353 | DNS responde |
| L403 | hostNetwork OFF, NodePort explícito por GatewayClassConfig | TCP | nó:nodePort observado | controle NodePort funciona |
| L404 | mesma configuração | UDP | nó:nodePort observado | controle UDP NodePort funciona |
| L405 | hostNetwork ON | TCP | nó:15432 e nó:nodePort | caracterizar diferença de exposição |
| L406 | hostNetwork ON | UDP | nó:15353 e nó:nodePort | caracterizar diferença de exposição |
| L407 | hostNetwork ON | HTTPRoute | nó:8080 | controle L7 no host funciona |
| L408 | hostNetwork OFF restaurado | TCP + UDP + HTTP | VIP:portas | baseline recuperado |

30 probes por célula, três repetições. Os dois destinos de L405/L406 são subcasos
separados. Rodar primeiro em workerA, depois workerB. Seleção de nós hostNetwork
é configuração L7; não presumir que restrinja o NodePort L4 da mesma forma.

## Procedimento

1. Registrar values/Helm revision, Gateway UID, Services e listeners existentes.
   Verificar portas do host livres antes de ligar L7; preferir todas >1023.
2. Rodar L401/402 e congelar correspondência de portas por protocolo.
3. Criar GatewayClass e CiliumGatewayClassConfig exclusivos com service.type=NodePort;
   associar Gateways de controle. Não editar Service gerado diretamente.
4. Rodar L403/404. Obter nodePort por nome E protocolo; não pegar item [0] sem filtro.
5. Salvar values completos, mudar somente hostNetwork no sandbox; Helm template
   offline e diff antes da aplicação. CRDs/workloads/policies permanecem constantes.
6. Aguardar reconciliação por UID/generation atual. Registrar todas as portas
   novamente: nodePort pode mudar ao recriar Service. Não reaproveitar valor antigo.
7. Rodar L405–407 e capturar interface do nó/client. `ss` sem socket L4 não prova
   porta fechada: o datapath de Service usa BPF, não um processo escutando.
8. Retirar rota BGP/VIP da interpretação quando Service for NodePort; a ausência
   de VIP não deve ser chamada falha de BGP nesta variante.
9. Restaurar values anteriores e Gateways de baseline. Rodar L408 e canário k01.

## Inspeção de portas

```bash
k -n "$STUDY_NS" get service "$STUDY_GENERATED_SERVICE" -o json \
  | jq '{type:.spec.type, ports:.spec.ports, ingress:.status.loadBalancer.ingress}'
k -n "$STUDY_NS" get endpointslice \
  -l "kubernetes.io/service-name=$STUDY_GENERATED_SERVICE" -o json
```

Selecionar Service pela ownerReference do Gateway antes de atribuir a variável.
Em caso de mesmo número TCP/UDP, registrar duas linhas. Não fixar nodePort manual
como workaround e declarar o host listener resolvido.

## Critérios e falsos positivos

- Declarar limitação reproduzida só se NodePort alternativo funciona e listener
  desejado não, com backend saudável e firewall/rota controlados.
- Falha em ambos destinos é INCONCLUSIVE até eliminar rota, Service e policy.
- Resposta na porta do listener pode vir de processo antigo: validar marcador,
  PID/socket quando aplicável e dono do recurso; não aceitar sucesso por coincidência.
- Captura deve separar request e reply, endereço externo e endpoint após DNAT.
- Não tirar conclusão de UDP só por timeout: capturar consulta e resposta do servidor.
- HTTP hostNetwork funcionando não valida TCPRoute/UDPRoute.

## Entrega e rollback

`ports.csv`, oito casos, pcaps discriminantes, values antes/depois e conclusão
por protocolo. PASS do estudo permite registrar UNSUPPORTED como resultado;
gate de adoção permanece “usar LoadBalancer ou NodePort explícito conforme requisito”.
Rollback é OFF e manifests anteriores, verificado com L408. Se a referência k01
mudar, interromper a sessão e diagnosticar isolamento antes de prosseguir.
