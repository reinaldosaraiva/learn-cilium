# E07 — Tenant híbrido Kubernetes + OpenStack

S011 descoberta/desenho; S012 execução condicionada. Fontes R18/R19/R20.
Ainda não há endpoint, release ou recursos OpenStack confirmados. Este documento
especifica a descoberta e as decisões; não inventa comandos de criação da cloud.

## Caso mínimo e mapa de autoridade

Tenant A tem api-pod-a e db-vm-a; tenant B tem api-pod-b e db-vm-b.
A→A e B→B somente na porta de teste; cross-tenant negado. A primeira fixture
de VM pode ser servidor TCP com marcador, sem dados reais; depois banco real
se houver objetivo adicional. A VM é VM Nova real, não pod com nome de VM.
O aceite híbrido é bidirecional: pod→VM e VM→pod, ambos A/B simétricos.
Se a infraestrutura só permitir um sentido, precisa de emenda de escopo explícita;
não preencher a metade não testada como PASS.

| Elemento | Autoridade | Atualização |
|---|---|---|
| Pod UID/IP/labels/SA | Kubernetes + Cilium | CNI/identidades |
| VM UUID/port ID/fixed IP | Nova + Neutron | API cloud |
| Alcance entre domínios | roteador/gateway sob dono definido | BGP ou rotas explícitas |
| Acesso pod→VM | Cilium egress + SG da porta VM | duas decisões separadas |
| Acesso VM→pod | SG egress + Cilium ingress | origem efetiva identificada |
| Endpoints de Service sem selector | executor experimental | reconciliação manual registrada |

“Mesmo tenant” é um mapeamento explícito de IDs de projeto/namespace; não surge
por igualdade de nomes. Cilium não aprende automaticamente security group Neutron.

## S011 — descoberta somente leitura

Entradas exigidas: configuração OpenStack local já autenticada (`STUDY_OS_CLOUD`),
UUID do projeto autorizado (`STUDY_PROJECT_ID`), UUID da porta própria inventariada
(`STUDY_PORT_ID`), release e autorização para consultar esses alvos.
Não imprimir clouds.yaml, token ou `openstack configuration show`.

```bash
openstack --version
openstack --os-cloud "$STUDY_OS_CLOUD" extension list --network -f json
openstack --os-cloud "$STUDY_OS_CLOUD" network list --project "$STUDY_PROJECT_ID" -f json
openstack --os-cloud "$STUDY_OS_CLOUD" subnet list --project "$STUDY_PROJECT_ID" -f json
openstack --os-cloud "$STUDY_OS_CLOUD" security group list --project "$STUDY_PROJECT_ID" -f json
```

Validar `--help` do CLI instalado antes de cada subcomando; versão/plug-in pode
não expor filtro indicado. Se filtro não existe, coordenador define alternativa
com escopo equivalente; não listar todas as contas silenciosamente.
Para a porta própria conhecida, `openstack --os-cloud "$STUDY_OS_CLOUD" port show "$STUDY_PORT_ID" -f json` seleciona campos necessários:
network_id, fixed_ips, security_group_ids, port_security_enabled,
allowed_address_pairs e binding relevante disponível ao papel de leitura.

Perguntas obrigatórias, com fonte de cada resposta:

1. ML2/OVN, ML2/OVS ou outro? Não inferir de nome de rede.
2. Provider/project networks, router e NAT: quem entrega ida e volta aos PodCIDRs?
3. Neutron dynamic routing/BGP speaker disponível e acessível? Existe alternativa
   com roteador experimental/rotas administradas? BGP não é requisito para SG.
4. SG é stateful/stateless na implantação? Quais defaults de egress?
5. Port security/anti-spoofing permite origem real de pod ou precisa de tratamento
   explícito? Quais allowed-address-pairs são suportados? Não desligar globalmente.
6. Quotas de VM/ports/IPs, imagens, flavors e custo estimado por recurso?
7. Captura/console/SSH da VM é possível? Qual interface tem o tráfego de teste?
8. Endereços se sobrepõem ao k01/sandbox? Há retorno assimétrico/NAT?

Saídas: `openstack-inventory.md`, `tenant-map.md`, `routing-decision.md`,
`resource-plan.md`, `access-matrix.csv` e `rollback-plan.md`.
Se não há acesso/infra, S011 BLOCKED; estudos Kubernetes anteriores mantêm suas
evidências. Não criar cloud nem DevStack automaticamente para preencher a lacuna.

## Decisão de arquitetura

| Opção | Uso | Limitação |
|---|---|---|
| L3 roteado sem SNAT, endereços não sobrepostos | preferida para observar IP de pod | requer retorno e port security coerentes |
| Egress/SNAT distinto por tenant | alternativa se underlay não roteia pods | SG vê IP egress, não identidade original |
| Gateway/proxy de aplicação | caso de acesso apenas à aplicação | não prova alcance direto VM↔pod |

Escolher uma primária com base no inventário; opções restantes não se somam por
default. Egress compartilhado A/B perde distinção por origem no SG; não declarar
isolamento VM equivalente sem outro mecanismo demonstrado.
Desenho L3 inicial usa CIDRs não sobrepostos; VRF/CIDRs sobrepostos é fora de escopo.

## S012 — procedimento após desenho e autorização

1. Materializar manifests/comandos cloud usando IDs/names concretos do resource-plan;
   coordenador revisa diff e custo. Registrar UIDs/UUIDs criados por cada ação.
2. Criar duas VMs e duas portas do experimento, ou reutilizar VMs explicitamente
   reservadas ao estudo. Aplicar SGs mínimos e iniciar fixture com marcador A/B.
3. Provar acesso direto de cliente de controle a cada fixture, antes das negativas.
4. Instalar somente rotas necessárias à comunicação de teste, documentando
   next-hop/origem e retorno. BGP opcional conforme routing-decision.
5. Em Kubernetes, policies por SA/namespace e egress somente ao destino/porta
   necessário. SG usa origem efetiva observada; não CIDR presumido antes do NAT.
6. Capturar ao sair do pod/nó e ao entrar na VM. Correlacionar SNAT/DNAT e portas.
7. Executar matriz abaixo com conexões novas; coletar canário permitido entre
   negativos para distinguir indisponibilidade de isolamento.
   Antes da matriz de tenants, executar controles separados de Cilium/SG abaixo;
   não atribuir ao SG um pacote que o Cilium já descartou.
8. Opcional no mesmo caso: representar VM em Service sem selector + EndpointSlice
   com o fixed IP inventariado. Gateway backendRef continua Service. Registrar
   manutenção manual do endpoint; não chamar isso integração automática.

## Matriz de atribuição Cilium × Neutron SG

Usar somente um par de fixtures próprias e uma porta sintética, sem dados reais,
sob rotas constantes verificadas. As regras de controle alteram apenas esse par;
não abrir todo o CIDR, desligar port security ou relaxar segurança compartilhada.
Revisar todos os SGs anexados, pois allows adicionais invalidam o controle.

| Controle | Cilium | SG | Esperado e prova |
|---|---|---|---|
| H01 | allow par/porta | allow par/porta | sucesso fim a fim e origem observada |
| H02 | deny par/porta | allow par/porta | drop Cilium; app VM não recebe |
| H03 | allow par/porta | deny/ausência de allow para par/porta | tráfego sai do nó; SG impede entrega; controle H01 antes/depois |
| H04 | deny par/porta | deny/ausência de allow | bloqueio combinado; não atribuir duas observações a um pacote |

Repetir no sentido VM→pod com SG egress e Cilium ingress. Para H03, preferir
contador/log/captura pré-SG no backend se o papel cloud permitir. Sem esse acesso,
manter rota/origem/policy constantes, alternar só a regra SG e cercar o negativo
com H01; registrar limite de observação. Sem esse contraste causal, resultado do
SG é INCONCLUSIVE. Restore das regras mínimas de tenant precede matriz final.

## Matriz

| Origem | Destino | Esperado |
|---|---|---|
| pod A | VM A porta autorizada | permite; VM registra marcador e origem efetiva |
| pod B | VM B porta autorizada | permite |
| pod A | VM B | nega |
| pod B | VM A | nega |
| VM A | pod A porta explicitamente escolhida | permite |
| VM B | pod B porta explicitamente escolhida | permite |
| VM B | pod A | nega |
| VM A | pod B | nega |
| pod A | VM A porta não autorizada | nega |
| cliente não autenticado | HTTPRoute para backend VM | nega no Gateway quando esse caminho existir |

Primeiro medir conectividade somente onde autorizado; não desativar segurança
de toda a cloud para “provar baseline”. 30 conexões/caso, três rodadas; aplicação
e política precisam permitir atribuir o bloqueio ao controle certo.

## Aceite, riscos e rollback

PASS exige VM real, origem/retorno medidos, controles H01–H04 nos dois sentidos,
matriz A/B bidirecional completa, positivos e negativos eficazes,
identity-map explícito e nenhuma dependência de labels mutáveis sem autoridade.
Se a origem foi SNAT para o mesmo IP de A/B, o resultado só comprova o controle
Cilium/egress observado; não atribuir ao SG uma distinção que ele não possui.

Rollback em ordem reversa do resource-plan: retirar referências/autorizações,
restaurar rotas e SGs anteriores, remover somente recursos experimentais autorizados.
Nunca remover rede/projeto compartilhado, nunca desativar port security global.
Retenção de recursos e custos fica explícita; teardown histórico continua separado.
