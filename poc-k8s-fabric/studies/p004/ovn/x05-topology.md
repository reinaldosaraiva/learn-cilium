# X05 — subnets sobrepostas, desenho preparado

Este arquivo congela a topologia para um futuro adaptador X05 após Go próprio.
O `x05.sh` deste checkpoint só faz dry-run local e recusa execução. O recurso
A/M03 continua no `ovn-chassis-1`, com o marker e o
filtro já pertencentes ao M03. O recurso novo B é completamente nomeado e
fica no `ovn-chassis-2`.

| objeto | A/M03 existente | B/X05 temporário |
|---|---|---|
| cliente L3 | `mgc-client-1`, AS 200 | `mgc-client-2`, AS 201 |
| pernas `/30` | VLAN 100/200, `.1/.2` e `.5/.6` | VLAN 300/400, os mesmos `.1/.2` e `.5/.6` |
| prefixo anunciado | `10.0.0.0/16` | `10.0.0.0/16` |
| VPC | `ls-mgc-tenant`, `192.168.100.0/24` | `ls-x05-tenant-b`, `192.168.100.0/24` |
| sentinel | `.11` (LSP X05 no LS A) | `.12` (LSP X05 no LS B) |
| chassis/VRF | `ovn-chassis-1`, tabela 300, VNI 50100 | `ovn-chassis-2`, tabela 400, VNI 50200 |
| filtro de retorno | marker `labctl-m03-*`, só chassis 1 | marker `labctl-x05-*`, só chassis 2 |

O endereço `.10` pertence ao endpoint A existente e não identifica o tenant
num cenário de CIDRs sobrepostos. O plano não cria `.10` em B; a identidade
da prova usa somente `.11` para A e `.12` para B.
Cada cliente precisa mostrar uma rota BGP presente para o mesmo
`192.168.100.0/24`; depois, o cliente A deve alcançar `.11` e falhar em `.12`,
enquanto o cliente B alcança `.12` e falha em `.11`.

O controle negativo cria, por um intervalo curto e com marker próprio, um
datapath compartilhado errado: o LSP **real** `x05-tenant-b-vm` é removido do
LS B e anexado ao LS A em uma única transação OVSDB. Antes da transação, o
adaptador deve ler e guardar o UUID do LSP e os UUIDs dos dois LS, exigir
CAS dos conjuntos de portas e conferir o resultado das operações; depois,
deve confirmar que o UUID do LSP é o mesmo e que só o pai mudou. O
netns/veth, MAC e endereço `.12`
da sentinela B permanecem os mesmos. Assim, A → `.12` passa pelo LS A e a
captura do tap B mostra request/reply; isso prova vazamento do endpoint B e
não cria um endpoint A artificial. A operação é intencional e temporária.

O LSP é restaurado ao LS B antes da repetição: A → `.12` volta a falhar, B →
`.12` volta a passar, e o UUID/parent final são conferidos. Nenhuma opção,
mapping, peer ou link do M03 é usado para o controle. Falha em ler o UUID,
em confirmar o parent ou em restaurar o LS B bloqueia o ensaio e mantém o
marker para recuperação manual; não se declara PASS.

O caminho de cleanup é obrigatório: remover primeiro cliente/peer, sentinelas,
VRF/LSPs, filtros B, mirrors e o pathspace `x05`; provar ausência do marker
X05; somente então o coordenador pode chamar `labctl mgc down --m03`.
