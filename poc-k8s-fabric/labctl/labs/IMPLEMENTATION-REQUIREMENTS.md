# Implementation requirements — evpn-fabric / ovnk (before first real implementation)

Advisory annex traveling with the skeleton profiles. Sources: deepseek-v4-pro
second opinion (2026-10-22, artifacts
`.humanlayer/tasks/pi-9de5911af792/lane1-deepseek-second-opinion.md`),
lane1-reviewer findings (zai/glm-5.3, worktree wt-s003), coordinator review.

Verdict common to all three: the skeleton discipline (stubs, gated rc 75,
pure host reads, hard-fail on unknown, no bulk deletes) is sound. The
requirements below bind the FIRST REAL IMPLEMENTATION, not the skeletons.

## Already applied to the skeletons (2026-10-22)

- dry-run is side-effect-free: `state_set` removed from dry-run paths
  (diverges from sibling profiles k01/p003-gw, which record `up_at` in
  dry-run — that inherited wart is NOT copied forward). [deepseek R1,
  reviewer P3-1]
- KVM gate is mode-consistent: `ovnk up --dry-run` on a host without nested
  virt prints the plan FOR REVIEW ONLY and returns 75, matching real mode.
  [deepseek R1, reviewer P3-1]
- `evpn-fabric` down residue read anchored to the exact `170.168.0.0/24`
  string and an `ip route show` read failure is explicit unknown -> rc 75.
  [reviewer P3-2]
- Spec draft (wt-spec): A.3 process name fixed to `apply` per v6/v758B.
  [lane2-reviewer P3]

## Requirements for the first real implementation (deepseek R1–R8)

1. **Dry-run purity everywhere.** No state writes of any kind in dry-run;
   record `up_at` only after a real `up` passed verification.
2. **Primitive-level idempotency.** `ensure_container` helper (check existing
   before `docker run --name`); static underlay IPs (`--ip 170.168.0.5/6/8` —
   never rely on Docker IPAM); `kind create` conditional on prior existence;
   exact names, never prune/`--all`.
3. **EVPN dataplane model fixed before coding.** Combined OVN+FRR image (or
   FRR sidecar) in gw1/gw2 (pure OVN image has no `vtysh`); `ovn-nbctl
   lsp-add` tenant logical ports BEFORE attaching OVS ports with
   `iface-id` (current plan references nonexistent logical ports); OVS and
   OVN controller services started explicitly in gateways.
4. **Same-CIDR isolation proof stronger than ping counters.** Positive
   control first (own-tenant 5/5); during the cross-tenant attempt capture on
   the target veth/OVS port or use `ovn-trace`/flow dumps proving zero
   ingress; `Network/Port Unreachable`, zero emitted packets, or local error
   replies are FAILURE, not isolation.
5. **Nested-KVM gate end-to-end.** `/dev/kvm` readable AND writable (not just
   a char device); expose `/dev/kvm` to kind nodes (extraMounts/devices);
   re-check KVM INSIDE a kind node before installing KubeVirt; any
   unverifiable hop fails closed.
6. **Live-migration IP persistence defined precisely.** Static guest IP via
   cloud-init on the UDN interface (IP belongs to the VM, not the pod); gate
   compares GUEST-level IP before/after (console/qemu-guest-agent), never the
   pod IP; require `MigrationSucceeded` + `VMI Ready` + post-migration 5/5
   ping; set `LiveMigrate` eviction strategy.
7. **Teardown is cleanup-then-proof.** Every withdrawal idempotent
   (`--ignore-not-found`, finalizer wait/removal); FRR withdrawn on ALL
   speakers (current plan only gw2); OVN logical ports deleted explicitly;
   residue checks inside container namespaces BEFORE container removal and at
   host level AFTER network removal.
8. **Exact verify gates + complete preflight.** JSON output for
   BGP/EVPN/KubeVirt parsing where possible; exact VNI/RD/RT/next-hop filters
   for Type-5; only valid neighbor entries count; `helm` and `kctl` in
   preflight; reconcile "exactly one Type-5" with the dual same-CIDR VRF
   design (two VRFs advertising the same prefix) so the gate cannot fail by
   ambiguity.

## Landing checkoff — applied to the SKELETON plans (2026-10-23, step apply-worker, wt-s003)

R2–R8 now shape what the skeletons PRINT (idempotent plans, gate
definitions, teardown order) while they remain stubs: every mutation goes
through `srun` (DRY:/stub, rc 0), real mode still ends gated rc 75, and no
ssh/docker/ovn/kubectl/kind/helm/virtctl command executes. The requirements
stay binding for the live implementation.

- [x] R2 primitive idempotency — `ensure_container` helper (inspect by exact
  name; create/start/disconnect-reconnect `--ip` paths printed,
  evpn-fabric.sh:181) used for all 5 containers with static underlay IPs
  central=.4/gw1=.5/gw2=.6/client=.7/peer=.8 (evpn-fabric.sh:86-92);
  kind create conditional `exists, skip` vs `create` (ovnk.sh:240); exact
  names kept, no prune/--all anywhere.
- [x] R3 EVPN dataplane — gw1/gw2 switch to combined ovn+frr image
  (`LAB_GW_IMAGE`, ovn-core has no vtysh; combined public tag not verifiable
  → 'TBD com digest pinado', evpn-fabric.sh:94-98); explicit `ovn-nbctl
  lsp-add` per tenant port BEFORE the `ovs-vsctl ... iface-id` attach
  (evpn-fabric.sh:301-309, 311-321); explicit ovsdb/ovs-vswitchd
  (`ovs-ctl start`) + `ovn-ctl start_controller` in both gateways
  (evpn-fabric.sh:256-262); peer/client stay pure FRR.
- [x] R4 isolation proof — both cross gates reworked: own-tenant positive
  control 5/5 REQUIRED first (evpn-fabric.sh:365, ovnk.sh:357); cross test
  proves ZERO ingress with `timeout 12 tcpdump -ni -c 1` ON the target
  port/node (evpn-fabric.sh:368, ovnk.sh:361) + origin emission capture
  (exactly 5) + ovn-trace/ovnkube-trace; Network-Unreachable / zero
  emitted / local error classified FAILURE (evpn-fabric.sh:375-376,
  ovnk.sh:368-369).
- [x] R5 nested-KVM end-to-end — gate now `test -r && test -w` on /dev/kvm
  (ovnk.sh:158-172); kind-3nodes.yaml gains per-node `extraMounts:
  /dev/kvm` printed in the plan (ovnk.sh:242-247); post-up re-check INSIDE
  each node (`docker exec <node> test -r/-w /dev/kvm`) before KubeVirt
  install (ovnk.sh:254-259); any unverifiable hop → gated rc 75
  (ovnk.sh:244-249 extraMounts plan).
- [x] R6 migration IP — VM spec printed with cloud-init static GUEST IP on
  the UDN iface (NoCloud networkData) + `evictionStrategy: LiveMigrate`
  (ovnk.sh:282-310); gate compares GUEST-level IP before/after via
  qemu-guest-agent (`kctl get vmi -o jsonpath '{.status.guest...}'`,
  virtctl console documented; NEVER pod IP) + MigrationSucceeded + VMI
  Ready + post-migration 5/5 ping (ovnk.sh:370-378).
- [x] R7 teardown cleanup-then-proof — FRR withdrawal on ALL speakers
  gw1/gw2/peer (evpn-fabric.sh:414-419); explicit `ovn-nbctl --if-exists
  lsp-del` per tenant port (evpn-fabric.sh:406,409); residue checks INSIDE
  container/node namespaces printed BEFORE rm (evpn-fabric.sh:428-434,
  ovnk.sh:432-437); host-level checks AFTER network/cluster rm
  (evpn-fabric.sh:443-460, ovnk.sh:440-456); KubeVirt CRs: finalizer wait
  then removal + `kctl wait --for=delete ns/kubevirt` (ovnk.sh:422-427);
  all withdrawals `--ignore-not-found`/`--if-exists`.
- [x] R8 gates/preflight — preflight requires helm + kctl (explicit-kubeconfig
  contract, ovnk.sh:193) and probes ovn/frr tools INSIDE the pinned images
  for the containerized topology (evpn-fabric.sh:212-216); verify gates
  print exact parse commands with JSON output (`vtysh ... json`,
  `kubectl -o json`/jsonpath — evpn-fabric.sh:349-353, ovnk.sh:352-355);
  Type-5 gate reconciles the dual same-CIDR VRFs with exact VNI+RD+RT+
  next-hop match and documents why 'exactly one per VRF' holds (peer/gateway
  VRF imports ONLY tenant-B RT 50200:100; count 2 only admissible across
  distinct VRFs/RTs) — evpn-fabric.sh:354-361, ovnk.sh:380-386.

Validation (2026-10-23): `bash -n` clean on evpn-fabric.sh, ovnk.sh, labctl;
direct dispatch — evpn-fabric up/down --dry-run rc 0; ovnk up --dry-run rc 75
(host has no /dev/kvm — gate fails closed in both modes), ovnk verify/down
--dry-run rc 0; zero state files created (LABCTL_STATE_DIR inspected after
runs).

## Convergence note

deepseek R1 and the zai reviewer independently flagged the same dry-run
rc/state semantics — two distinct providers, same finding; treated as
confirmed. The skeletons remain gated (rc 75) in real mode; nothing here
authorizes live execution.

## Live-implementation notes from the r2 review (2026-10-22, 5×P3, non-blocking)

Bound the FIRST REAL IMPLEMENTATION alongside R1-R8 above:

- N1: the printed `clear bgp * soft` is NOT a withdrawal (re-advertises);
  live impl must withdraw per-speaker (e.g. `no network <prefix>` after
  configure terminal) or carry an explicit TBD marker.
- N2: `tcpdump -c 5` cannot prove "exactly 5" emissions; live gate must count
  within a bounded window (timeout + write-to-file + count) or use -c with a
  ceiling and treat saturation as "at least", never "exactly".
- N3: the 9 referenced fixtures do not exist yet (studies/ovnk/); when
  kind-3nodes.yaml is authored it MUST carry the R5 extraMounts (/dev/kvm)
  — the skeleton only prints them as log lines today.
- N4: the KubeVirt finalizer-strip patch must print as an EXPLICITLY
  conditional branch (only after the wait poll fails), never straight-line.
- N5: R6 primary guest-IP path (.status.guest.interfaces) requires
  qemu-guest-agent; the nominal cirros image does not ship it — live impl
  either changes the image or makes console the primary path.

Status: skeletons remain gated rc 75 in real mode; dry-run side-effect-free
(zero state/evidence artifacts verified by dispatch); ovnk up dry-run rc 75
without KVM (mode-consistent gate).
