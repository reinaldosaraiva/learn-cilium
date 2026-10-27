# S012 — Coleção histórica de diagnóstico OpenStack

Este diretório preserva arquivos da investigação histórica da integração entre
`p003-gw` e OpenStack Neutron. Os scripts refletem sondas, tentativas de
recuperação e verificações em momentos diferentes; os números nos nomes não
definem uma sequência única para execução.

Alguns arquivos da coleção, apresentados apenas como exemplos de nomes
versionados:

- [`01-restart-relight.sh`](01-restart-relight.sh)
- [`05-relight-testbed-safe.sh`](05-relight-testbed-safe.sh)
- [`49-matrix-a.sh`](49-matrix-a.sh)
- [`81-tap-location-diag.sh`](81-tap-location-diag.sh)

O [dossiê E07](../../../../docs/estudos/07-openstack.md) resume o escopo e as
observações publicadas. A solução C5 está no [dossiê público da VM fora do
container](../../../../docs/estudos/09-vm-outside-container.md); C5 é uma emenda
histórica e não corresponde ao estudo E09.
