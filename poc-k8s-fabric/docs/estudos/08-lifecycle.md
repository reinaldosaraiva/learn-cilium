# E08 — Recriação, reuso de IP e síntese dos estudos

S013 executa lifecycle híbrido após E07. S014 entrega consolidação didática.
O estudo Kubernetes de UID/IP já começa em E05/E06; aqui a questão é revogação
entre duas plataformas sem identidade sincronizada automaticamente.

> **Executado:** a matriz C01–C09 foi executada (S013 lado K8s, S014 lado VM) e
> consolidada na [síntese didática E08](08-lifecycle-synthesis.md) — janelas
> medidas, contraste C03/C05, runbook e checklist de adoção.

## Hipótese crítica

IP pode mudar de dono. Uma regra IP/CIDR antiga pode autorizar o novo dono se
não houver revogação/sincronização. Ver duas plataformas funcionando não demonstra
que essa transição é segura. Não implementar um controlador novo nesta trilha.

## Livro de ownership

Antes do primeiro caso, registrar:

| Campo | Pod | VM |
|---|---|---|
| Identificador imutável da instância | metadata.uid | Nova server UUID |
| Identificador de rede | endpoint/Cilium identity observada | Neutron port UUID |
| Tenant | namespace + ServiceAccount autorizados | project UUID |
| Endereço | pod IP e nó | fixed IP, network/subnet |
| Autorizações dependentes | CNP/CIDR/Service endpoint | SG/rules/allowed address pairs |
| Rotas | bloco/nó/anúncio | rede/host route/next-hop |
| Dono da atualização | controlador ou executor explícito | controlador ou executor explícito |

ID numérico de Cilium identity também pode ser reciclado; não tratar como
identificador eterno. Registrar labels/SA e janela de validade junto ao número.

## Procedimento de revogação controlada

1. Validar canários permitidos/negados e abrir uma conexão longa de controle.
2. Iniciar coletor de probes NOVOS contínuos com ID antes de mudar ownership.
3. Retirar o endpoint/allow de A dependente do endereço a ser liberado; registrar
   comando aceito, geração e primeiro bloqueio observado.
4. Confirmar revogação efetiva por novas conexões; só depois liberar/reutilizar IP
   no fluxo seguro. Esse sequenciamento manual é mecanismo do experimento.
5. Recriar recurso com novo UID/UUID; conferir se o IP mudou ou foi reaproveitado.
6. Reautorizar somente depois de verificar novo dono. Testar A e B durante a
   janela inteira, distinguindo nova conexão de conexão já estabelecida.
7. Comparar com controle negativo de regra obsoleta em sandbox descartável, se
   explicitamente autorizado: a sensibilidade do teste deve detectar o bypass.

Não assumir que delete/recreate de pod devolve o mesmo IP. Para reuso determinístico:
usar suporte do IPAM/API verificado, ou churn limitado (máximo 50 recriações) com
observação. Sem reuso real, marcar caso de reuso BLOCKED/INCONCLUSIVE; não substituí-lo
por dois IPs diferentes e declarar a propriedade provada.
No Neutron, pedido de fixed IP é condicionado à API e disponibilidade do alvo;
não reutilizar endereço fora do inventário próprio.

## Matriz

| Caso | Evento | Critério |
|---|---|---|
| C01 | pod A recriado, IP diferente | A autorizado pela nova identidade; IP velho sem concessão indevida |
| C02 | pod A recriado, IP igual/UID diferente | permissões seguem o dono atual, não UID antigo |
| C03 | IP antes de A passa a pod B | B não herda acesso à VM A |
| C04 | VM A recriada, porta/IP diferentes | endpoint e SG atualizados; antigo não concede acesso |
| C05 | IP da VM A reaproveitado por VM B | pod A não acessa B por allow antigo |
| C06 | auth pod movido/recriado | allow/deny continuam corretos no caminho novo |
| C07 | Grant/listener/rota removidos | novos requests deixam de alcançar o backend após convergência medida |
| C08 | conexão longa antes da revogação | comportamento documentado separadamente; não inferir encerramento automático |
| C09 | controle proposital com regra stale | teste identifica vazamento, depois regra é removida e caso fica negativo |

Três repetições por evento possível. Registrar tempo desde API até último sucesso
indevido/primeiro bloqueio consistente. Nenhum limiar de “instantâneo” será inventado:
medir distribuição e decidir orçamento de revogação separadamente antes de produção.

## Gate de segurança

PASS do fluxo seguro exige zero acessos indevidos em novas conexões após o gate
de revogação; janela anterior e conexões existentes são explicitamente reportadas.
Se a solução depende de quarentena manual, conclusão é “seguro sob sequenciamento
manual testado”, não “Kubernetes/OpenStack sincronizam identidade automaticamente”.
Se não existe mecanismo que impeça herança de IP, registrar falha de desenho;
não relaxar expectativa para fazer o plano passar.

## Rollback e estado final de S013

1. Encerrar somente os geradores, coletores e conexão longa iniciados pela sessão,
   por PID/handle registrado; preservar outros túneis/processos do laboratório.
2. Remover por ID/UID a regra stale de C09 e quaisquer allows/Grants de falha.
   Comprovar ausência no controle e com probe negativo antes de reautorizar.
3. Restaurar auth, Routes/ListenerSets, Services/EndpointSlices, CNP e SGs mínimos
   para os DONOS ATUAIS identificados. Repor rotas/next-hops conforme inventário
   vigente; não reaplicar endereço antigo de A agora pertencente a B.
4. Reconstituir fixtures A/B próprias se a execução autorizada as removeu. Nova
   VM/pod terá novo UUID/UID: atualizar o livro de ownership e o registro de
   configuração final. Rollback funcional não restaura UID nem conexão TCP extinta.
5. Repetir canários permitidos A→A/B→B e negativos cruzados nos dois sentidos,
   incluindo HTTP allow/deny. Confirmar inexistência de endpoint/rota/allow stale.
6. Registrar recursos retidos, seus IDs/custo e destino. Limpar somente recursos
   próprios cuja autorização inclua cleanup; nenhum teardown histórico inferido.
7. Se qualquer restauração, ownership ou teste final falhar, parar com handoff
   BLOCKED e estado parcial. Não criar S014 nem afirmar que o ambiente foi restaurado.

O relatório MUST distinguir baseline original, recursos substituídos e baseline
funcional final; não falsificar restauração byte a byte após um teste de destruição.

## S014 — entrega didática e mapa de decisão

Produzir um guia local que referencie resultados datados, com:

1. Diagrama do fluxo L4 versus L7, incluindo BGP, Service, Envoy, auth e backend.
2. Tabela por feature: versão/API, combinações testadas, não suportadas e lacunas.
3. Exercícios de leitura seguros para estudante e separado roteiro de instrutor.
4. Instruções de reprodução usando os scripts/manifests realmente entregues.
5. Interpretação de fails: auth deny, transporte, CRD, policy, BGP e lifecycle.
6. Checklist de adoção baseado na matriz, sem “pronto para produção” genérico.
7. Estado final de todos os recursos e decisão de retenção/cleanup/custo.

Revisão de leitor novo deve responder sem contexto: qual cluster usar; onde roda
cada comando; como provar consulta auth; como detectar NodePort; como comprovar
nó remoto; o que fazer se IP não é reutilizado; quando parar/escalar.

## Gates de adoção por combinação

| Uso pretendido | Evidência mínima |
|---|---|
| TCP/UDP porta fixa externa | LoadBalancer + portas/protocolos observados; sem hostNetwork incompatível |
| HTTP protegido por ExternalAuth | allow/deny/default deny/referência inválida/timeout + anti-bypass |
| Auth remoto com WireGuard | topologia/placement/cifra e falhas do perfil alvo |
| Gateway compartilhado | ownership/RBAC/Grant/ListenerSet/TLS sem acesso cruzado |
| Pods /32 | alocação/reserva/convergência/lifecycle medidos, requisitos justificados |
| Tenant híbrido | Neutron real, origem após NAT, isolamento e revogação testados |

Entrega final não exige publicar GitHub/PDF nesta rodada de planejamento.
Publicação e criação de vídeo/aula são tarefas posteriores, se solicitadas.
