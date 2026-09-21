# Diff dos artefatos studies/p003/ vs kit original (P003-S003 closeout item #4)

Gerado em 2026-09-21 (UTC) no checkout local. Base do kit: bd7bee0.
Cada seção: arquivo do kit (a) vs artefato do sandbox (b).

## topo/kind-cluster.yaml vs studies/p003/topo/kind-cluster-p003.yaml

```diff
--- topo/kind-cluster.yaml	2026-09-19 17:49:43
+++ studies/p003/topo/kind-cluster-p003.yaml	2026-09-21 08:40:22
@@ -1,15 +1,12 @@
-# Cluster kind SEM CNI e SEM kube-proxy: o Cilium assume os dois papeis.
+# Cluster kind do sandbox p003-gw: SEM CNI e SEM kube-proxy (Cilium assume).
+# IPv4 only nesta rodada (dual-stack e extensao explicita, nao inferida).
 kind: Cluster
 apiVersion: kind.x-k8s.io/v1alpha4
 networking:
-  disableDefaultCNI: true       # sem kindnet - Cilium sera o CNI
-  kubeProxyMode: "none"         # kubeProxyReplacement do Cilium
-  # P002-S001 S3: dual-stack (kind >= v0.23 exige ipFamily explicitamente)
-  ipFamily: dual
-  # DUAL-STACK (P002-S001 S3): o KCM so distribui PodCIDR IPv6 se o podSubnet
-  # do cluster incluir um range IPv6 (nao da p/ patchar node depois — API proibe).
-  podSubnet: "10.244.0.0/16,fd13::/48"
-  serviceSubnet: "10.96.0.0/12,fd12::/108"
+  disableDefaultCNI: true
+  kubeProxyMode: "none"
+  podSubnet: "10.245.0.0/16"
+  serviceSubnet: "10.112.0.0/16"
 nodes:
   - role: control-plane
     image: kindest/node:v1.35.0@sha256:452d707d4862f52530247495d180205e029056831160e22870e37e3f6c1ac31f
```

## k8s/cilium/values-native.yaml vs studies/p003/base/values-p003.yaml

```diff
--- k8s/cilium/values-native.yaml	2026-09-17 05:11:47
+++ studies/p003/base/values-p003.yaml	2026-09-21 10:12:30
@@ -1,65 +1,53 @@
 # =============================================================================
-# Cilium 1.20.x - CENARIOS A / B / C : NATIVE ROUTING + BGP Control Plane v2
-# -----------------------------------------------------------------------------
-# helm repo add cilium https://helm.cilium.io
-# helm upgrade --install cilium cilium/cilium -n kube-system --version 1.20.1 \
-#   -f k8s/cilium/values-native.yaml
-#
-# Sem encapsulamento: o IP do pod entra no fabric como esta. Quem sabe alcancar
-# cada PodCIDR e o leaf SR Linux, que aprendeu o prefixo por BGP do proprio no.
+# Cilium 1.20.2 - sandbox p003-gw: NATIVE ROUTING + BGP CP v2 + Gateway API
+# Base: k8s/cilium/values-native.yaml (k01), valores do envelope S003.
+# Diferencas do k01: cluster.id 2, CIDRs do sandbox, gatewayAPI + l7Proxy,
+# hubble/prometheus desligados (economia de RAM; Hubble nao e prova de entrega),
+# operator 1 replica.
+# Install: helm install cilium <cilium-1.20.2.tgz> -n kube-system
+#   --kubeconfig /root/.kube/p003-gw.config --kube-context kind-p003-gw
+#   -f base/values-p003.yaml
 # =============================================================================
 
 cluster:
-  name: magalu-poc
-  id: 1
+  name: p003-gw
+  id: 2
 
 # ----------------------------------------------------------------- datapath
 routingMode: native
-ipv4NativeRoutingCIDR: "10.244.0.0/16"
-# rota direta no-a-no quando os nos estao na mesma L2 (mesmo rack);
-# skipUnreachable evita erro quando o outro no esta em outro rack/sub-rede.
+ipv4NativeRoutingCIDR: "10.245.0.0/16"
 autoDirectNodeRoutes: true
 directRoutingSkipUnreachable: true
 endpointRoutes:
   enabled: true
 
-# ----------------------------------------------------------------- devices
-# O devices-controller do Cilium PULA veth sem rota default (workaround p/
-# kubernetes-in-docker). No node kind a rota default e da rede kind (eth0); a
-# interface de fabric (eth1, veth p/ o leaf) NAO tem rota default -> auto-deteccao
-# a ignora e o bpf-lb nao e anexado nela. Resultado: VIP anycast nao responde a
-# tráfego externo (chega em eth1 sem DNAT e o kernel o roteia de volta p/ o fabric
-# em loop). Fix: declarar explicitamente as interfaces de fabric.
-# (Cenário B / S09 — ver evidence/REQ-009/root-cause-and-fix.txt)
+# devices: mesmo workaround do k01 (veth sem rota default e pulado pelo
+# devices-controller; declarar explicitamente as interfaces de fabric).
 devices: "eth+"
 
 ipam:
-  mode: kubernetes          # /24 por no, distribuido pelo kube-controller-manager
+  mode: kubernetes
 
 k8s:
   requireIPv4PodCIDR: true
 
-# MTU 1500: a VPC da Magalu nao entrega jumbo (medido 2026-09-16).
-# No overlay isso custa 50 bytes = 3,3% do payload - e exatamente o que
-# o Cenario D precisa medir.
 MTU: 1500
 
 # ------------------------------------------------- kube-proxy replacement (eBPF)
 kubeProxyReplacement: true
-# ajuste para o endereco/porta do seu API server (obrigatorio sem kube-proxy)
-k8sServiceHost: "10.10.1.11"
+# IP de kind do control-plane (nao o IP de fabric nem o service IP):
+# presente nos SANs do cert do apiserver e alcancavel pela rede kind.
+# Mesmo padrao do k01 (helm values: k8sServiceHost 172.19.0.3).
+k8sServiceHost: "172.19.0.5"
 k8sServicePort: 6443
 
 # ------------------------------------------------------------- masquerading
 enableIPv4Masquerade: true
 bpf:
   masquerade: true
-# trafego DENTRO de ipv4NativeRoutingCIDR nunca e mascarado -> o fabric ve o IP do pod
 
 # --------------------------------------------------------- load balancing L4
 loadBalancer:
-  # maglev = hashing consistente; importante para anycast/ECMP: se o fabric
-  # trocar o no de destino, a conexao ainda cai no mesmo backend.
   algorithm: maglev
   mode: snat
 
@@ -67,24 +55,22 @@
 bgpControlPlane:
   enabled: true
 
-# ------------------------------------------------------------- observabilidade
-hubble:
+# ------------------------------------------------------------- Gateway API
+gatewayAPI:
   enabled: true
-  relay:
-    enabled: true
-  ui:
-    enabled: true
-  metrics:
-    enabled:
-      - dns
-      - drop
-      - tcp
-      - flow
-      - port-distribution
+  # create explicit (nao auto): GatewayClass 'cilium' e criado pelo chart
+  # sem depender de deteccao de API version no momento do install.
+  gatewayClass:
+    create: true
+# no chart 1.20.2 l7Proxy e booleano (nao tabela)
+l7Proxy: true
 
+# ------------------------------------------------------------- observabilidade
+# Hubble desligado no sandbox: nao e evidencia de entrega (invariante do
+# contrato) e economiza RAM sob o gate de capacidade.
+hubble:
+  enabled: false
 prometheus:
-  enabled: true
+  enabled: false
 operator:
-  replicas: 2
-  prometheus:
-    enabled: true
+  replicas: 1
```

## k8s/bgp/01-peer-config.yaml vs studies/p003/base/bgp/01-peer-config.yaml

```diff
--- k8s/bgp/01-peer-config.yaml	2026-09-17 13:55:12
+++ studies/p003/base/bgp/01-peer-config.yaml	2026-09-21 08:42:27
@@ -1,16 +1,14 @@
-# Perfil de sessao BGP reutilizado por todos os peers do fabric.
+# Perfil de sessao BGP reutilizado por todos os peers do fabric (sandbox p003).
+# Base: k8s/bgp/01-peer-config.yaml (k01), IPv4 only.
 apiVersion: cilium.io/v2
 kind: CiliumBGPPeerConfig
 metadata:
   name: fabric-peer
 spec:
-  # Timers agressivos: deteccao de falha em ~9s (o minimo aceito e 9/3).
   timers:
     connectRetryTimeSeconds: 5
     holdTimeSeconds: 9
     keepAliveTimeSeconds: 3
-  # Graceful restart: o leaf mantem as rotas durante um restart do cilium-agent,
-  # evitando blackhole de trafego nas atualizacoes do DaemonSet.
   gracefulRestart:
     enabled: true
     restartTimeSeconds: 30
@@ -21,13 +19,3 @@
       advertisements:
         matchLabels:
           advertise: fabric
-    # P002-S001 S3: dual-stack - anuncia tambem o PodCIDR/VIP IPv6
-    - afi: ipv6
-      safi: unicast
-      advertisements:
-        matchLabels:
-          advertise: fabric
-  # Opcional - autenticacao TCP-MD5 (RFC 2385). Crie o secret antes:
-  #   kubectl -n kube-system create secret generic bgp-auth-secret \
-  #     --from-literal=password='<senha>'
-  # authSecretRef: bgp-auth-secret
```

## k8s/bgp/02-advertisements.yaml vs studies/p003/base/bgp/02-advertisements.yaml

```diff
--- k8s/bgp/02-advertisements.yaml	2026-09-16 16:24:21
+++ studies/p003/base/bgp/02-advertisements.yaml	2026-09-21 08:42:31
@@ -1,23 +1,21 @@
-# O que o Cilium anuncia para o fabric.
-# O label advertise=fabric e o que amarra este objeto ao CiliumBGPPeerConfig.
+# O que o Cilium anuncia para o fabric (sandbox p003).
+# Base: k8s/bgp/02-advertisements.yaml (k01), communities do AS local 65301.
 apiVersion: cilium.io/v2
 kind: CiliumBGPAdvertisement
 metadata:
   name: fabric-advertisements
   labels:
     advertise: fabric
+    study: P003
 spec:
   advertisements:
-    # 1) PodCIDR do proprio no (/24 vindo do IPAM do Kubernetes).
-    #    CENARIO A - e isto que torna o pod roteavel no underlay.
-    #    NO CENARIO D (overlay/VXLAN) remova este bloco.
+    # 1) PodCIDR do proprio no (/24 do IPAM do Kubernetes) - native routing.
     - advertisementType: "PodCIDR"
       attributes:
         communities:
-          standard: ["65101:100"]
+          standard: ["65301:100"]
 
-    # 2) VIPs de servico. CENARIO B - cada no anuncia o mesmo /32,
-    #    o fabric faz ECMP e o resultado e um anycast de servico.
+    # 2) VIPs de servico: cada no anuncia o mesmo /32 -> ECMP/anycast no fabric.
     - advertisementType: "Service"
       service:
         addresses:
@@ -27,15 +25,4 @@
           - { key: "bgp-advertise", operator: In, values: ["true"] }
       attributes:
         communities:
-          standard: ["65101:200"]
-
-    # 3) (opcional) ClusterIP - util para expor Services internos a rede corp.
-    #    Descomente com cuidado: coloca a ServiceCIDR dentro do fabric.
-    # - advertisementType: "Service"
-    #   service:
-    #     addresses:
-    #       - ClusterIP
-    #     aggregationLengthIPv4: 32
-    #   selector:
-    #     matchExpressions:
-    #       - { key: "bgp-advertise-clusterip", operator: In, values: ["true"] }
+          standard: ["65301:200"]
```

## k8s/bgp/03-cluster-config-rack1.yaml vs studies/p003/base/bgp/03-cluster-config-rack1.yaml

```diff
--- k8s/bgp/03-cluster-config-rack1.yaml	2026-09-16 16:24:21
+++ studies/p003/base/bgp/03-cluster-config-rack1.yaml	2026-09-21 08:42:35
@@ -1,19 +1,20 @@
 # Rack 1 (leaf1) - nos com label topology.kubernetes.io/rack=rack1
-#   kubectl label node node1 node2 topology.kubernetes.io/rack=rack1
+#   kubectl label node p003-gw-control-plane p003-gw-worker topology.kubernetes.io/rack=rack1
 apiVersion: cilium.io/v2
 kind: CiliumBGPClusterConfig
 metadata:
   name: rack1
+  labels: { study: P003 }
 spec:
   nodeSelector:
     matchLabels:
       topology.kubernetes.io/rack: rack1
   bgpInstances:
     - name: "rack1"
-      localASN: 65101
+      localASN: 65301
       peers:
         - name: "leaf1"
-          peerASN: 65001
-          peerAddress: 10.10.1.1     # IP do IRB do leaf1 (gateway do rack)
+          peerASN: 65201
+          peerAddress: 10.30.1.1     # IP do IRB do leaf1 (gateway do rack1)
           peerConfigRef:
             name: "fabric-peer"
```

## k8s/bgp/04-cluster-config-rack2.yaml vs studies/p003/base/bgp/04-cluster-config-rack2.yaml

```diff
--- k8s/bgp/04-cluster-config-rack2.yaml	2026-09-16 16:24:21
+++ studies/p003/base/bgp/04-cluster-config-rack2.yaml	2026-09-21 08:42:38
@@ -1,19 +1,20 @@
 # Rack 2 (leaf2) - nos com label topology.kubernetes.io/rack=rack2
-#   kubectl label node node3 topology.kubernetes.io/rack=rack2
+#   kubectl label node p003-gw-worker2 topology.kubernetes.io/rack=rack2
 apiVersion: cilium.io/v2
 kind: CiliumBGPClusterConfig
 metadata:
   name: rack2
+  labels: { study: P003 }
 spec:
   nodeSelector:
     matchLabels:
       topology.kubernetes.io/rack: rack2
   bgpInstances:
     - name: "rack2"
-      localASN: 65102
+      localASN: 65302
       peers:
         - name: "leaf2"
-          peerASN: 65002
-          peerAddress: 10.10.2.1
+          peerASN: 65202
+          peerAddress: 10.30.2.1     # IP do IRB do leaf2 (gateway do rack2)
           peerConfigRef:
             name: "fabric-peer"
```

## k8s/bgp/05-lb-ippool.yaml vs studies/p003/base/bgp/05-lb-ippool.yaml

```diff
--- k8s/bgp/05-lb-ippool.yaml	2026-09-17 13:55:14
+++ studies/p003/base/bgp/05-lb-ippool.yaml	2026-09-21 08:42:41
@@ -1,14 +1,13 @@
-# Pool de VIPs entregue aos Services type=LoadBalancer (LB-IPAM do Cilium).
-# Este /24 e o que o fabric SR Linux espera receber por BGP dos nos.
+# Pool de VIPs do sandbox (LB-IPAM do Cilium). IPv4 only nesta rodada.
 apiVersion: "cilium.io/v2"
 kind: CiliumLoadBalancerIPPool
 metadata:
-  name: "poc-vips"
+  name: "p003-vips"
+  labels: { study: P003 }
 spec:
   blocks:
-    - cidr: "10.201.255.0/24"
-    # P002-S001 S3: pool de VIPs IPv6 (anycast /128)
-    - cidr: "fd14::/64"
+    - cidr: "10.202.255.0/24"
   allowFirstLastIPs: "No"
   # serviceSelector vazio = qualquer Service pode consumir o pool.
-  # Em producao, restrinja por namespace/label.
+  # Restricao por label e feita no caso que precisar (GW07 usa o selector
+  # do anuncio, nao do pool).
```

## k8s/apps/10-echo-deployment.yaml vs studies/p003/fixtures/http-echo.yaml

```diff
--- k8s/apps/10-echo-deployment.yaml	2026-09-16 16:24:21
+++ studies/p003/fixtures/http-echo.yaml	2026-09-21 08:43:36
@@ -1,30 +1,43 @@
+# Fixture HTTP (GW01): agnhost netexec, marcador = hostname do pod no corpo.
+# Base: k8s/apps/10-echo-deployment.yaml (k01).
 apiVersion: apps/v1
 kind: Deployment
 metadata:
-  name: echo
-  labels: { app: echo }
+  name: http-echo
+  namespace: p003-gateway
+  labels: { app: http-echo, study: P003 }
 spec:
-  replicas: 6
+  replicas: 3
   selector:
-    matchLabels: { app: echo }
+    matchLabels: { app: http-echo }
   template:
     metadata:
-      labels: { app: echo }
+      labels: { app: http-echo, study: P003 }
     spec:
-      # espalha as replicas pelos nos para o ECMP ter de fato varios caminhos
       topologySpreadConstraints:
         - maxSkew: 1
           topologyKey: kubernetes.io/hostname
           whenUnsatisfiable: ScheduleAnyway
           labelSelector:
-            matchLabels: { app: echo }
+            matchLabels: { app: http-echo }
       containers:
         - name: agnhost
           image: registry.k8s.io/e2e-test-images/agnhost:2.47
           args: ["netexec", "--http-port=8080"]
           ports:
-            - containerPort: 8080
+            - { containerPort: 8080 }
           readinessProbe:
             httpGet: { path: /healthz, port: 8080 }
           resources:
             requests: { cpu: 10m, memory: 32Mi }
+---
+apiVersion: v1
+kind: Service
+metadata:
+  name: http-echo
+  namespace: p003-gateway
+  labels: { app: http-echo, study: P003 }
+spec:
+  selector: { app: http-echo }
+  ports:
+    - { name: http, port: 80, targetPort: 8080 }
```

## topo/poc-kind.clab.yml vs studies/p003/topo/p003-gw.clab.yml

```diff
--- topo/poc-kind.clab.yml	2026-09-19 17:58:57
+++ studies/p003/topo/p003-gw.clab.yml	2026-09-21 08:40:05
@@ -1,16 +1,14 @@
 # =============================================================================
-# PoC Magalu Cloud - variante 100% autocontida (ensaio / dry-run)
-# Containerlab sobe o fabric E um cluster kind de 3 nos.
-# Use esta topologia para ensaiar o roteiro antes de tocar no cluster real.
-#
-# Pre-requisito: kind >= 0.20 instalado no host.
-# Deploy:  sudo clab deploy -t topo/poc-kind.clab.yml
+# P003-S003 - sandbox p003-gw (fabric + kind) - envelope S002
+# Base: topo/poc-kind.clab.yml (k01), renomeado com os valores aprovados.
+# Sem link a VPC. Sem dual-stack (IPv4 only nesta rodada).
+# Deploy: sudo clab deploy -t p003-gw.clab.yml   (depois do dry-run)
 # =============================================================================
-name: poc-k8s-kind
+name: p003-gw-fabric
 
 mgmt:
-  network: clab-poc-kind
-  ipv4-subnet: 10.223.31.0/24
+  network: p003-gw-mgmt
+  ipv4-subnet: 10.223.32.0/24
 
 topology:
   kinds:
@@ -24,90 +22,73 @@
     spine1:
       kind: nokia_srlinux
       type: ixrd3l
-      startup-config: ../configs/srl/spine1.cfg
+      startup-config: ../configs/srl/p003-spine1.cfg
     spine2:
       kind: nokia_srlinux
       type: ixrd3l
-      startup-config: ../configs/srl/spine2.cfg
+      startup-config: ../configs/srl/p003-spine2.cfg
     leaf1:
       kind: nokia_srlinux
-      startup-config: ../configs/srl/leaf1.cfg
+      startup-config: ../configs/srl/p003-leaf1.cfg
     leaf2:
       kind: nokia_srlinux
-      startup-config: ../configs/srl/leaf2.cfg
+      startup-config: ../configs/srl/p003-leaf2.cfg
     leaf3:
       kind: nokia_srlinux
-      startup-config: ../configs/srl/leaf3-border.cfg
+      startup-config: ../configs/srl/p003-leaf3-border.cfg
 
     border1:
       kind: linux
       image: frrouting/frr:v8.4.1
       binds:
-        - ../configs/frr/daemons:/etc/frr/daemons
-        - ../configs/frr/frr.conf:/etc/frr/frr.conf
+        - ../configs/frr/p003-daemons:/etc/frr/daemons
+        - ../configs/frr/p003-frr.conf:/etc/frr/frr.conf
       exec:
         - sysctl -w net.ipv4.ip_forward=1
-        - sysctl -w net.ipv6.conf.all.forwarding=1
 
-    client-ext:
+    client:
       kind: linux
       exec:
-        - ip addr add 203.0.113.10/24 dev eth1
-        - ip route replace default via 203.0.113.1
-        # P002-S001 S3: IPv6 p/ o VIP anycast (fd14::/64) e o PodCIDR IPv6 (fd13::/48)
-        - ip -6 addr add fd00:203:113::10/64 dev eth1
-        - ip -6 route replace default via fd00:203:113::1
+        - ip addr add 198.19.0.10/24 dev eth1
+        - ip route replace default via 198.19.0.1
 
-    # ------------------------------------------------------- cluster kind (k01)
-    k01:
+    # ------------------------------------------------------- cluster kind (sandbox)
+    p003-gw:
       kind: k8s-kind
-      startup-config: kind-cluster.yaml
+      startup-config: kind-cluster-p003.yaml
 
-    # Os containers do cluster sao anexados como ext-container.
-    # IMPORTANTE: nao mexemos na rota default (eth0/docker) - ela e usada pela
-    # API do kind e pelo pull de imagens. So adicionamos rotas especificas.
-    k01-control-plane:                      # rack1 / node1
+    # ext-containers: nos kind anexados ao fabric (mesmo padrao do k01).
+    # Sem rota default em eth1 - so rotas especificas do sandbox.
+    p003-gw-control-plane:                      # rack1 / node1
       kind: ext-container
       exec:
-        - ip addr add 10.10.1.11/24 dev eth1
+        - ip addr add 10.30.1.11/24 dev eth1
         - ip link set eth1 up
         - ip link set eth1 mtu 1500
-        - ip route replace 10.10.0.0/16 via 10.10.1.1
-        - ip route replace 10.244.0.0/16 via 10.10.1.1
-        - ip route replace 10.201.255.0/24 via 10.10.1.1
-        - ip route replace 203.0.113.0/24 via 10.10.1.1
-        # P002-S001 S3: dual-stack - fabric IPv6 + PodCIDR/VIP IPv6 via fabric
-        - ip -6 addr add fd00:10:1::11/64 dev eth1
-        - ip -6 route replace fd13::/48 via fd00:10:1::1 dev eth1
-        - ip -6 route replace fd14::/64 via fd00:10:1::1 dev eth1
-    k01-worker:                             # rack1 / node2
+        - ip route replace 10.30.0.0/16 via 10.30.1.1
+        - ip route replace 10.245.0.0/16 via 10.30.1.1
+        - ip route replace 10.202.255.0/24 via 10.30.1.1
+        - ip route replace 198.19.0.0/24 via 10.30.1.1
+    p003-gw-worker:                             # rack1 / node2
       kind: ext-container
       exec:
-        - ip addr add 10.10.1.12/24 dev eth1
+        - ip addr add 10.30.1.12/24 dev eth1
         - ip link set eth1 up
         - ip link set eth1 mtu 1500
-        - ip route replace 10.10.0.0/16 via 10.10.1.1
-        - ip route replace 10.244.0.0/16 via 10.10.1.1
-        - ip route replace 10.201.255.0/24 via 10.10.1.1
-        - ip route replace 203.0.113.0/24 via 10.10.1.1
-        # P002-S001 S3: dual-stack - fabric IPv6 + PodCIDR/VIP IPv6 via fabric
-        - ip -6 addr add fd00:10:1::12/64 dev eth1
-        - ip -6 route replace fd13::/48 via fd00:10:1::1 dev eth1
-        - ip -6 route replace fd14::/64 via fd00:10:1::1 dev eth1
-    k01-worker2:                            # rack2 / node3
+        - ip route replace 10.30.0.0/16 via 10.30.1.1
+        - ip route replace 10.245.0.0/16 via 10.30.1.1
+        - ip route replace 10.202.255.0/24 via 10.30.1.1
+        - ip route replace 198.19.0.0/24 via 10.30.1.1
+    p003-gw-worker2:                            # rack2 / node3
       kind: ext-container
       exec:
-        - ip addr add 10.10.2.11/24 dev eth1
+        - ip addr add 10.30.2.11/24 dev eth1
         - ip link set eth1 up
         - ip link set eth1 mtu 1500
-        - ip route replace 10.10.0.0/16 via 10.10.2.1
-        - ip route replace 10.244.0.0/16 via 10.10.2.1
-        - ip route replace 10.201.255.0/24 via 10.10.2.1
-        - ip route replace 203.0.113.0/24 via 10.10.2.1
-        # P002-S001 S3: dual-stack - fabric IPv6 + PodCIDR/VIP IPv6 via fabric
-        - ip -6 addr add fd00:10:2::11/64 dev eth1
-        - ip -6 route replace fd13::/48 via fd00:10:2::1 dev eth1
-        - ip -6 route replace fd14::/64 via fd00:10:2::1 dev eth1
+        - ip route replace 10.30.0.0/16 via 10.30.2.1
+        - ip route replace 10.245.0.0/16 via 10.30.2.1
+        - ip route replace 10.202.255.0/24 via 10.30.2.1
+        - ip route replace 198.19.0.0/24 via 10.30.2.1
 
   links:
     - endpoints: ["leaf1:e1-49", "spine1:e1-1"]
@@ -118,14 +99,12 @@
     - endpoints: ["leaf3:e1-50", "spine2:e1-3"]
 
     - endpoints: ["leaf3:e1-1", "border1:eth1"]
-    - endpoints: ["border1:eth2", "client-ext:eth1"]
+    - endpoints: ["border1:eth2", "client:eth1"]
 
-    # CAMINHO B+ : porta do FRR que termina no netns do HOST da vm-cilium.
-    # E por aqui que o VIP do lab fica alcancavel de outras VMs da VPC, usando
-    # o MAC da propria vm-cilium (o filtro de MAC da VPC nao se aplica).
-    # Configure o lado do host com: sudo ./scripts/06-expor-vip-na-vpc.sh
-    - endpoints: ["border1:eth3", "host:clab-ext"]
+    # Link host<->fabric (debug/canario do host). NAO e link de VPC.
+    # Lado do host: 10.101.0.1/30 + rotas (acao autorizada do gate S003).
+    - endpoints: ["border1:eth3", "host:p003-ext"]
 
-    - endpoints: ["leaf1:e1-1", "k01-control-plane:eth1"]
-    - endpoints: ["leaf1:e1-2", "k01-worker:eth1"]
-    - endpoints: ["leaf2:e1-1", "k01-worker2:eth1"]
+    - endpoints: ["leaf1:e1-1", "p003-gw-control-plane:eth1"]
+    - endpoints: ["leaf1:e1-2", "p003-gw-worker:eth1"]
+    - endpoints: ["leaf2:e1-1", "p003-gw-worker2:eth1"]
```

