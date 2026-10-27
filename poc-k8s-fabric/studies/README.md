# Índice dos estudos E01–E41

Este índice reúne a trilha e os arquivos públicos associados a cada estudo.
Scripts e manifestos apontam para os materiais versionados; os dossiês descrevem
escopo, resultados e limites. P007 e P008 também têm índices próprios em seus
diretórios.

| Estudo | Trilha | Script ou manifesto real | Dossiê público |
|---|---|---|---|
| E01 — Gateway API e VIP BGP | P003 | [`gateway.yaml`](p003/base/gateway.yaml) | [E01](../docs/estudos/01-gateway-bgp.md) |
| E02 — Portas TCP/UDP e host network | P003 | [`s004-record-ports.sh`](p003/cases/s004-record-ports.sh) | [E02](../docs/estudos/02-l4-hostnetwork.md) |
| E03 — ExternalAuth e controles de falha | P003 | [`s005-probes.sh`](p003/cases/s005-probes.sh), [`s006-probes.sh`](p003/cases/s006-probes.sh) | [E03](../docs/estudos/03-externalauth.md) |
| E04 — WireGuard em native routing e VXLAN | P003 | [`s007-run.sh`](p003/cases/s007-run.sh), [`s008-run.sh`](p003/cases/s008-run.sh) | [E04](../docs/estudos/04-wireguard.md) |
| E05 — Tenants, delegação e TLS | P003 | [`gen-tls.sh`](p003/cases/s009/gen-tls.sh) | [E05](../docs/estudos/05-tenants.md) |
| E06 — IPAM /24 e /32 | P003 | [`s010-run.sh`](p003/cases/s010/s010-run.sh) | [E06](../docs/estudos/06-ipam.md) |
| E07 — Tenant híbrido Kubernetes e OpenStack | P003 | [`s011`](p003/cases/s011/README.md), [`s012`](p003/cases/s012/README.md) | [E07](../docs/estudos/07-openstack.md) |
| E08 — Ciclo de vida, reuso de IP e revogação | P003 | [`02-c01-c03.sh`](p003/cases/s013/02-c01-c03.sh), [`run-s014-lifecycle.sh`](p003/cases/s014/run-s014-lifecycle.sh) | [Síntese E08](../docs/estudos/08-lifecycle-synthesis.md) |
| E09 — Sessão eBGP autenticada com TCP MD5 | P005 | [`e09-bgp-md5-asn32.sh`](p005/arm-a-ebgp/e09-bgp-md5-asn32.sh) | [E09/E19](../docs/estudos/19-bgp-idempotency-md5-asn32.md) |
| E10 — Detecção BGP com BFD | P005 | [`e10-bgp-failure-detection-bfd.sh`](p005/arm-a-ebgp/e10-bgp-failure-detection-bfd.sh) | [E10–E12](../docs/estudos/11-bgp-maxprefix-communities-bfd.md) |
| E11 — Limite de prefixos e filtro de importação | P005 | [`e11-bgp-maxprefix-import-filter.sh`](p005/arm-a-ebgp/e11-bgp-maxprefix-import-filter.sh) | [E10–E12](../docs/estudos/11-bgp-maxprefix-communities-bfd.md) |
| E12 — Communities, prepend e MED | P005 | [`e12-bgp-communities-prepend-med.sh`](p005/arm-a-ebgp/e12-bgp-communities-prepend-med.sh) | [E10–E12](../docs/estudos/11-bgp-maxprefix-communities-bfd.md) |
| E13 — Failover dual-border e Graceful Restart | P005 | [`e13-bgp-dual-border-failover.sh`](p005/arm-a-ebgp/e13-bgp-dual-border-failover.sh) | [E13/E14](../docs/estudos/13-bgp-dual-border-gr-ipv6.md) |
| E14 — eBGP IPv6 e VIP fim a fim | P005 | [`e14-bgp-ipv6-e2e-vip.sh`](p005/arm-a-ebgp/e14-bgp-ipv6-e2e-vip.sh) | [E13/E14](../docs/estudos/13-bgp-dual-border-gr-ipv6.md) |
| E15 — VRF por tenant via BGP community | P005 | [`e15-bgp-vrf-per-tenant-community.sh`](p005/arm-a-ebgp/e15-bgp-vrf-per-tenant-community.sh) | [E15/E16/E18](../docs/estudos/15-bgp-vrf-return-paths-l2-mtu-qinq-macsec.md) |
| E16 — Caminhos de retorno PE/CE e Egress Gateway | P005 | [`e16-pe-ce-return-paths-egress-gw.sh`](p005/arm-a-ebgp/e16-pe-ce-return-paths-egress-gw.sh) | [E15/E16/E18](../docs/estudos/15-bgp-vrf-return-paths-l2-mtu-qinq-macsec.md) |
| E17 — Observabilidade contínua BGP | P005 | [`e17-e25-bgp-hubble-observability.sh`](p005/arm-b-datapath/e17-e25-bgp-hubble-observability.sh) | [E17/E25](../docs/estudos/17-bgp-hubble-observability.md) |
| E18 — MTU, QinQ, MACsec e WireGuard | P005 | [`e18-l2-mtu9000-qinq-macsec-wg.sh`](p005/arm-a-ebgp/e18-l2-mtu9000-qinq-macsec-wg.sh) | [E15/E16/E18](../docs/estudos/15-bgp-vrf-return-paths-l2-mtu-qinq-macsec.md) |
| E19 — Idempotência e ciclo de vida BGP | P005 | [`e19-bgp-idempotency-lifecycle.sh`](p005/arm-a-ebgp/e19-bgp-idempotency-lifecycle.sh) | [E09/E19](../docs/estudos/19-bgp-idempotency-md5-asn32.md) |
| E20 — DCI, Cilium, FRR e OVN-Kubernetes | P004 | [Índice P004](p004/README.md) | [Síntese E20](../docs/estudos/20-dci-estado-parcial.md) |
| E21 — Burst IPAM e Warm Pool | P005 | [`e21-ipam-burst-scale.sh`](p005/arm-b-datapath/e21-ipam-burst-scale.sh) | [E21/E23](../docs/estudos/21-netkit-vs-veth-ipam-burst.md) |
| E22 — XLB eBPF, SocketLB e Envoy | P005 | [`e22-xlb-ebpf-socket-lb-vs-envoy.sh`](p005/arm-b-datapath/e22-xlb-ebpf-socket-lb-vs-envoy.sh) | [E22](../docs/estudos/22-xlb-ebpf-socket-lb-vs-envoy.md) |
| E23 — netkit e veth no datapath | P005 | [`e23-netkit-vs-veth.sh`](p005/arm-b-datapath/e23-netkit-vs-veth.sh) | [E21/E23](../docs/estudos/21-netkit-vs-veth-ipam-burst.md) |
| E24 — DRA para dispositivos de rede | P005 | [`e24-cilium-dra-network-device.sh`](p005/arm-b-datapath/e24-cilium-dra-network-device.sh) | [E24](../docs/estudos/24-cilium-dra-network-device.md) |
| E25 — Hubble e observabilidade de serviços | P005 | [`e17-e25-bgp-hubble-observability.sh`](p005/arm-b-datapath/e17-e25-bgp-hubble-observability.sh) | [E17/E25](../docs/estudos/17-bgp-hubble-observability.md) |
| E26 — LoadBalancer TCX/XDP, DSR e Maglev | P006 | [`e26-lb-xdp-dsr-maglev.sh`](p006/arm-a-datapath/e26-lb-xdp-dsr-maglev.sh), [`manifesto`](p006/arm-a-datapath/01-e26-lb-xdp-dsr-maglev.yaml) | [E26/E30](../docs/estudos/26-lb-xdp-dsr-maglev-clustermesh.md) |
| E27 — BIG TCP e netkit | P006 | [`e27-big-tcp-netkit-jumbo.sh`](p006/arm-a-datapath/e27-big-tcp-netkit-jumbo.sh), [`manifesto`](p006/arm-a-datapath/01-e27-big-tcp-jumbo.yaml) | [E27/E31](../docs/estudos/27-big-tcp-netkit-srv6-l3vpn.md) |
| E28 — Bandwidth Manager e BBR | P006 | [`e28-bandwidth-edt-bbr.sh`](p006/arm-a-datapath/e28-bandwidth-edt-bbr.sh), [`manifesto`](p006/arm-a-datapath/01-e28-bandwidth-edt-bbr.yaml) | [E28/E32](../docs/estudos/28-bandwidth-edt-bbr-tetragon.md) |
| E29 — BGP Unnumbered e L2 Announcements | P006 | [`e29-bgp-unnumbered-l2.sh`](p006/arm-a-datapath/e29-bgp-unnumbered-l2.sh), [`manifesto`](p006/arm-a-datapath/01-e29-bgp-unnumbered-l2.yaml) | [E29/E33](../docs/estudos/29-bgp-unnumbered-l2-live-migration.md) |
| E30 — Cluster Mesh e MCS-API | P006 | [`e30-clustermesh-bgp-mcs.sh`](p006/arm-b-platform/e30-clustermesh-bgp-mcs.sh), [`manifesto`](p006/arm-b-platform/01-e30-clustermesh-bgp-mcs.yaml) | [E26/E30](../docs/estudos/26-lb-xdp-dsr-maglev-clustermesh.md) |
| E31 — SRv6 L3VPN | P006 | [`e31-srv6-l3vpn-frr.sh`](p006/arm-b-platform/e31-srv6-l3vpn-frr.sh), [`manifesto`](p006/arm-b-platform/01-e31-srv6-l3vpn.yaml) | [E27/E31](../docs/estudos/27-big-tcp-netkit-srv6-l3vpn.md) |
| E32 — Tetragon e segurança em runtime | P006 | [`e32-tetragon-runtime-ebpf.sh`](p006/arm-b-platform/e32-tetragon-runtime-ebpf.sh), [`manifesto`](p006/arm-b-platform/01-e32-tetragon-runtime-ebpf.yaml) | [E28/E32](../docs/estudos/28-bandwidth-edt-bbr-tetragon.md) |
| E33 — Live migration de KubeVirt | P006 | [`e33-kubevirt-live-migration.sh`](p006/arm-b-platform/e33-kubevirt-live-migration.sh), [`manifesto`](p006/arm-b-platform/01-e33-kubevirt-live-migration.yaml) | [E29/E33](../docs/estudos/29-bgp-unnumbered-l2-live-migration.md) |
| E34 — BGP Graceful Shutdown e drain | P007 | [`e34-bgp-gshut-zero-loss-drain.sh`](p007/arm-a-datapath/e34-bgp-gshut-zero-loss-drain.sh), [`manifesto`](p007/arm-a-datapath/01-e34-bgp-gshut.yaml) | [E34/E35](../docs/estudos/30-bgp-gshut-spiffe-mtls-wireguard.md) |
| E35 — SPIFFE mTLS e WireGuard | P007 | [`e35-spiffe-mtls-wireguard-zerotrust.sh`](p007/arm-b-platform/e35-spiffe-mtls-wireguard-zerotrust.sh), [`manifesto`](p007/arm-b-platform/01-e35-spiffe-mtls-wireguard.yaml) | [E34/E35](../docs/estudos/30-bgp-gshut-spiffe-mtls-wireguard.md) |
| E36 — Local Redirect Policy | P007 | [`e36-local-redirect-policy-nodelocal.sh`](p007/arm-a-datapath/e36-local-redirect-policy-nodelocal.sh), [`manifesto`](p007/arm-a-datapath/02-e36-local-redirect-policy.yaml) | [E36/E37](../docs/estudos/31-local-redirect-multus-ipvlan-dualhomed.md) |
| E37 — Multus e redes dual-homed | P007 | [`e37-multus-ipvlan-macvlan-kubevirt-dualhomed.sh`](p007/arm-b-platform/e37-multus-ipvlan-macvlan-kubevirt-dualhomed.sh), [`manifesto`](p007/arm-b-platform/02-e37-multus-ipvlan-dualhomed.yaml) | [E36/E37](../docs/estudos/31-local-redirect-multus-ipvlan-dualhomed.md) |
| E38 — Host Firewall e XDP | P008 | [`e38-host-firewall-xdp-prefilter.sh`](p008/arm-a-datapath/e38-host-firewall-xdp-prefilter.sh), [`manifesto`](p008/arm-a-datapath/01-e38-host-firewall-xdp.yaml) | [E38/E39](../docs/estudos/32-host-firewall-xdp-envoy-l7-resilience.md) |
| E39 — Cilium Envoy e resiliência L7 | P008 | [`e39-cilium-envoy-l7-resilience.sh`](p008/arm-b-platform/e39-cilium-envoy-l7-resilience.sh), [`manifesto`](p008/arm-b-platform/01-e39-cilium-envoy-l7.yaml) | [E38/E39](../docs/estudos/32-host-firewall-xdp-envoy-l7-resilience.md) |
| E40 — BGP Route Reflector e SRv6 | P008 | [`e40-bgp-route-reflector-srv6-dualstack.sh`](p008/arm-a-datapath/e40-bgp-route-reflector-srv6-dualstack.sh), [`manifesto`](p008/arm-a-datapath/02-e40-bgp-route-reflector-srv6-dualstack.yaml) | [E40/E41](../docs/estudos/33-bgp-rr-srv6-dualstack-netkit-wg-matrix.md) |
| E41 — Matriz netkit, BIG TCP e WireGuard | P008 | [`e41-netkit-bigtcp-wireguard-matrix.sh`](p008/arm-b-platform/e41-netkit-bigtcp-wireguard-matrix.sh), [`manifesto`](p008/arm-b-platform/02-e41-netkit-bigtcp-wireguard-matrix.yaml) | [E40/E41](../docs/estudos/33-bgp-rr-srv6-dualstack-netkit-wg-matrix.md) |

> **Nota histórica:** C5 documenta a VM fora do container como uma emenda da
> trilha P003. É um registro separado e não corresponde ao estudo E09, que
> trata da sessão eBGP autenticada com TCP MD5.
