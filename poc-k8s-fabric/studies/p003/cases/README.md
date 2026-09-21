# P003-S003 — Casos GW01–GW07 (comandos explícitos)

Cliente: container `clab-p003-gw-fabric-client` (198.19.0.10), na vm-cilium.
Todos os probes: conexão nova por requisição, `--retry 0`/`+tries=1`, sem `-f`.
Evidência: `poc-k8s-fabric/evidence/P003/S003/<UTC-run>/<case>/` (protocolo §4).

Variáveis (definir antes de executar):
```bash
STUDY_KUBECONFIG=/root/.kube/p003-gw.config
STUDY_CONTEXT=kind-p003-gw
STUDY_CLUSTER_UID=<registrado no bootstrap>
STUDY_NS=p003-gateway
STUDY_GATEWAY=p003-main
VIP=10.202.255.10
k() { kubectl --kubeconfig "$STUDY_KUBECONFIG" --context "$STUDY_CONTEXT" "$@"; }
test "$(k get namespace kube-system -o jsonpath='{.metadata.uid}')" = "$STUDY_CLUSTER_UID"
C="sudo docker exec clab-p003-gw-fabric-client"
```

## GW01 — HTTP VIP:8080 com Host correto (30 requisições)

```bash
for i in $(seq 1 30); do
  $C curl -sS --noproxy '*' --retry 0 --connect-timeout 3 --max-time 10 \
    -H 'Connection: close' -H 'Host: echo.p003.study' \
    -H "X-Lab-Request-ID: gw01-$i" \
    -o /tmp/gw01_body_$i -w "%{http_code}\t%{time_total}\n" \
    "http://$VIP:8080/hostname"
  $C cat /tmp/gw01_body_$i
done
```
Esperado: 30/30 HTTP 200 com hostname de pod `http-echo-*` no corpo
(marcador). Controle negativo: Host errado → 404 do Envoy:
`$C curl -sS --retry 0 -o /dev/null -w '%{http_code}\n' -H 'Host: wrong.example' http://$VIP:8080/hostname`

## GW02 — TCP VIP:15432 (30 requisições com nonce)

```bash
for i in $(seq 1 30); do
  nonce="P003-gw02-$i-$(date +%s%N)"
  $C sh -c "echo $nonce | nc -w 3 $VIP 15432"
done
```
Esperado: 30/30 nonce devolvido idêntico.

## GW03 — UDP VIP:15353, DNS sintético (30 consultas)

```bash
for i in $(seq 1 30); do
  $C dig @$VIP -p 15353 study.p003 TXT +short +notcp +ignore +tries=1 +time=2
done
```
Esperado: 30/30 `"P003-OK"`.

## GW04 — Porta TCP não configurada (controle negativo)

```bash
$C sh -c "echo P003-gw04 | nc -w 3 $VIP 15433"   # sem listener/route
```
Esperado: sem resposta da fixture (timeout/reset); nenhuma chegada na app
(verificar ausência de conexão nos pods da fixture).

## GW05 — TCPRoute no listener HTTP (controle negativo)

```bash
k apply -f cases/gw05-tcp-on-http.yaml
k -n $STUDY_NS get tcproute p003-gw05-tcp-on-http -o jsonpath='{range .status.parents[*]}{.conditions}{end}'
$C curl -sS --retry 0 -o /dev/null -w '%{http_code}\n' -H 'Host: echo.p003.study' http://$VIP:8080/hostname  # GW01 continua OK
k delete -f cases/gw05-tcp-on-http.yaml
```
Esperado: condition Rejected/ResolvingFailed (protocolo incompatível); GW01
inalterado; backend tcp-echo não atendido via 8080.

## GW06 — Backend removido e restaurado

```bash
k -n $STUDY_NS scale deployment http-echo --replicas=0
k -n $STUDY_NS get endpointslices -l kubernetes.io/service-name=http-echo -o json
$C curl -sS --retry 0 --max-time 5 -o /dev/null -w '%{http_code}\n' -H 'Host: echo.p003.study' http://$VIP:8080/hostname  # falha
k -n $STUDY_NS scale deployment http-echo --replicas=3
# aguardar ready; repetir GW01 (30x) — recuperação
```
Esperado: EndpointSlice vazio → falha (503/timeout); após restaurar, 30/30 200.

## GW07 — Selector BGP da VIP deixa de casar

```bash
# RIB antes:
sudo docker exec clab-p003-gw-fabric-spine1 sr_cli "show network-instance default route-table ipv4-unicast prefix 10.202.255.10/32"
k apply -f cases/gw07-advertisement-nomatch.yaml
# aguardar convergencia (~15s); RIB depois:
sudo docker exec clab-p003-gw-fabric-spine1 sr_cli "show network-instance default route-table ipv4-unicast prefix 10.202.255.10/32"
# controle interno: IP do pod continua alcancavel do client
PODIP=$($C sh -c "true"; k -n $STUDY_NS get pods -l app=http-echo -o jsonpath='{.items[0].status.podIP}')
$C curl -sS --retry 0 --max-time 5 -o /dev/null -w '%{http_code}\n' -H 'Host: echo.p003.study' http://$PODIP:8080/hostname
# probe externo: VIP deve falhar
$C curl -sS --retry 0 --max-time 5 -o /dev/null -w '%{http_code}\n' -H 'Host: echo.p003.study' http://$VIP:8080/hostname
# restaurar:
k apply -f base/bgp/02-advertisements.yaml
# aguardar convergencia; repetir GW01–GW03 (30x cada)
```
Esperado: /32 presente antes, ausente depois (convergência); pod IP direto
funciona (controle interno); VIP falha; após restaurar, GW01–03 recuperados.
Não exigir que conexões antigas caiam instantaneamente (conntrack).

## Observação (todos os casos)

```bash
k -n $STUDY_NS get gateway $STUDY_GATEWAY -o json
k -n $STUDY_NS get httproutes,tcproutes,udproutes -o yaml
k -n $STUDY_NS get services,endpointslices -o json
k -n kube-system get pods -l k8s-app=cilium -o wide
sudo KUBECONFIG=$STUDY_KUBECONFIG cilium --context $STUDY_CONTEXT bgp peers
sudo KUBECONFIG=$STUDY_KUBECONFIG cilium --context $STUDY_CONTEXT bgp routes advertised ipv4 unicast
```
