# X05 execution contract (P004-S002)

This contract is the input for the X05 adapter. It does not authorize a lab
run. `x05.sh --execute` remains closed until the adapter and an independent
review satisfy every gate below. The M03 result is an input to X05, not a test
to repeat. Literal VNI removal remains a separate `NOT_RUN` characterization.

## State and serialization

The delivered baseline has **no** M03 marker or peer. The coordinator
acquires `/var/lock/labctl-dci-m03.lock` on FD 9 before any read that can
authorize a mutation. Under that lock it validates the historical receipt,
calls `labctl dci up --m03` with `M03_PREFLIGHT_RECEIPT`, and runs
`labctl dci verify --m03`. This is setup for X05, not a repeat of the M03
causal experiment. It holds the lock through X05 cleanup, then calls
`labctl dci down --m03` and baseline `labctl dci verify` before release.
`M03_LOCK_HELD_FD=9` is passed to `labctl dci`
only after path and inode checks, as in `dci_m03_lock_action`. The X05 marker
is `/run/labctl/dci-x05/active`, mode 0600, owned by root. A marker may be
removed only after every X05 resource is absent and the B LSP is back in its
original LS. Normal `labctl dci up`, `verify`, and `down` must refuse an X05
marker unless they are the locked X05 coordinator. A stale marker stops the
run and leaves recovery to the owned rollback path.
The run identifier is six lowercase hex digits. The marker owner token is
`labctl-x05-<run-hex>`; the B return-filter port is `x05-b-<run-hex>`.
The coordinator must persist the token before the first X05 mutation and
verify the same value in the marker, NB rows and rollback journal.

The state transitions are `ABSENT -> M03_ACTIVE -> INTENT -> BUILT ->
BASELINE_PROVED -> LEAK_PROVED -> RESTORED -> X05_CLEANED -> ABSENT`.
The marker is persisted at `INTENT`,
before the first mutation. Each step records the intended resource, original
value or `absent`, owner token, and a completion flag. A crash after mutation
but before completion leaves an ambiguous step; rollback checks actual state
and ownership before compensating it. No step adopts an existing unowned
resource. A failed rollback retains the marker and exits without claiming
PASS.

## Resource inventory

| Owner | Resource | Exact identity | Precondition | Rollback |
|---|---|---|---|---|
| M03 | A LS/LR/LRP and return filter | `ls-dci-tenant`, `lr-dci-tenant`, `lrp-dci-tenant` | Valid M03 marker and fingerprint after setup | X05 changes only the A LS `ports` set during the explicit control; restore the exact set; then M03 teardown |
| X05 | A sentinel | LSP `x05-tenant-a-vm`, netns/tap on chassis 1, `192.168.100.11`, distinct MAC | LS A belongs to DCI; LSP/netns/tap absent | Remove only owned LSP and netns/tap |
| X05 | B tenant | `ls-x05-tenant-b`, `lr-x05-tenant-b`, `lrp-x05-tenant-b`, chassis 2, table 400, VNI 50200 | Names, UUIDs, mapping and Linux links absent | Remove in reverse dependency order by UUID/owner |
| X05 | B sentinel | LSP `x05-tenant-b-vm`, netns/tap on chassis 2, `192.168.100.12`, distinct MAC | B LS exists and port/tap absent | Restore parent to B first; then remove by UUID |
| X05 | B external connections | `lr-x05-300/400`, `ls-x05-300/400-external`, `lrp-x05-300/400-external`, `lsp-x05-300/400-router`, `ln-x05-300/400`, `bgpvrf300/400`; VLAN/VRF 300 on gw1 and 400 on gw2, `/30` values reused from A | No X05 NB/OVS/FRR residue | Withdraw FRR, remove mirror/OVS ports, then NB rows |
| X05 | B transit | `ls-x05-300/400-transit`, `lrp-x05-300/400-tenant`, `lsp-x05-300/400-tenant`, `lrp-x05-tenant-b-300/400`, `lsp-x05-tenant-b-300/400` | Rows absent, unique UUIDs | Remove routes and LRPs/LSPs before LS/LR rows |
| X05 | B client | `dci-client-2`, AS201, both `/30` legs, `10.0.0.0/16` | Docker name/ports absent | Remove its OVS ports and labeled container |
| X05 | B EVPN | chassis 2 pathspace, peer `dci-x05-peer-2`, source `10.251.0.1/32`, VNI 50200 | Pathspace, peer, links and filter absent | Withdraw Type 5, stop FRR, remove labeled links/peer/filter |
| X05 | Captures | run-specific files and PIDs on fabric and both nodes | Evidence directory unique | Stop only PIDs in the marker; preserve files |

The B transit addresses are `10.31.100.1/30`↔`.2/30` and
`10.41.100.1/30`↔`.2/30`. VLAN/VRF IDs 300/400 are **not** interpolated into
IPv4 octets. The A and B sentinel MACs must be different. Existing A `.10`
does not identify a tenant under overlapping CIDRs; the plan creates no B `.10`.

The A sentinel uses netns `x05-tenant-a-vm`, host tap `x05-tenant-a-p` and
MAC `02:00:00:10:00:11`; B uses netns `x05-tenant-b-vm`, host tap
`x05-tenant-b-p` and MAC `02:00:00:10:00:12`. They are created inside their
respective chassis containers. B tenant LS/LR options and the return filter
use `ovnvrf-x05-b` (table 400), `br-x05-b`, `vxlan-x05-b` (VNI 50200),
`evpn-x05-b` and FRR pathspace `x05`. The B LRP filter uses
`options:dynamic-routing-port-name=x05-b-<six-hex-run-token>` and chassis 2
uses the matching
`external_ids:dynamic-routing-port-mapping=x05-b-<six-hex-run-token>=br-x05-b`.
The peer uses `vrf-x05-peer`, `br-x05-peer`, `vxlan-x05-pr` and
`evpn-x05-pr` in its own pathspace. B LS options point only to the B links;
B LR uses `dynamic-routing-vrf-id=400`, chassis 2 and distinct transit routes
via `10.31.100.2`/`10.41.100.2`. The executable inventory must still freeze
the baseline and inverse for each key before a Go. The pinned DCI profile
currently writes `external_ids:ovn-evpn-local-ip=50100-170.168.0.6` on
chassis 2. OVN 26.03 supports a comma-separated per-VNI address list, so the
planned chassis 2 value is `50100-170.168.0.6,50200-170.168.0.6`; UDP 4789
is unchanged. The adapter must read the **exact** original value before
mutation, require the expected baseline, change only chassis 2, and restore
that value after B withdrawal. Other nodes' baseline keys are read for drift
but not changed. See the [OVN controller option reference](https://www.ovn.org/support/dist-docs/ovn-controller.8.html)
and the [OVN 26.03 changelog](https://www.ovn.org/en/releases/changelog_v26.03.0/).
The setter, ownership proof and inverse are not implemented yet.

Every X05-created NB object must carry `external_ids:x05-owner=<token>`.
The M03-owned A LS keeps its original owner; only its complete `ports` set
changes temporarily under the guarded control transaction. Linux links use
`ip link alias <token>`, OVS interfaces use `external_ids:x05-owner`, Docker
objects use an X05 label plus the DCI profile label, and FRR state is scoped
to an X05 pathspace or exact named VRF/neighbor. An owner token alone is not
enough for deletion: name, UUID or interface index, type, and expected parent
must agree. The M03 marker digest and A LS/LR/LRP UUIDs and complete A LS
`ports` set are read just after M03 setup, before X05 mutations, and again
after X05 cleanup. The original baseline absence of M03 marker/peer is checked
again after `down --m03`.

`x05-nb-tx.py` generates local forward and inverse OVSDB JSON. The inverse
requires the checked forward UUID journal, matching run token and original A
fingerprint, plus a stable, complete-column NB snapshot. It rejects a
populated column omitted from the forward insert and any foreign row that
references an owned UUID (except the planned A sentinel in A LS). It waits
for every observed column of the 34 owned rows and their captured UUIDs,
including parent reference sets. It also guards A LS/LR/LRP identities, the
complete A LS/LR port sets, and requires the control LSP to be back in B.
It then detaches the A sentinel and deletes the 34 captured UUIDs in one
transaction. The result checker requires one mutation and 34 deletions.
`x05-nb-full-snapshot.sh` collects ten tables with bounded, read-only
`ovn-nbctl list` calls. They include the four extra schema referrers
`Network_Function`, `Port_Group`, `Logical_Router_Policy` and `NAT`. Seven
table-wide waits over `_uuid` and each reference column guard against a new
foreign reference between that snapshot and inverse commit. Its live reader
was exercised against the M03-absent baseline, not against a built X05 state.
The local postflight verifier checks built and clean NB states. A clean PASS
requires matching checked forward and inverse receipts plus a fresh snapshot
captured after the inverse result check; those timestamps and receipts must
be created in sequence on the same host under the shared lock. A future
adapter must verify postconditions after commit, refuse ambiguous outcomes
and keep the marker on any failed wait or postcondition. These helpers have
no apply mode and do not establish G7/G8 without live integration.

`x05-runtime-plan.py` fixes a separate 43-resource non-NB inventory and
rollback order. Its local checker cross-checks gateway mirror MACs against
the B external LRPs, exact gateway FRR fixtures and the peer VNI. It records
the intended ownership and before-state fields for a future adapter, but
contains no live collector, mutation, journal or rollback. The peer's
internal FRR and links must be stopped and verified before its container is
removed.

Gateway FRR mutation is a scoped extension operation. The adapter must first
verify the exact bytes and SHA256 of `/etc/frr/frr.conf`, then run the matching
`vtysh -C -f` check and `vtysh -f` add fixture for the one X05 VRF, BGP
neighbor, and BFD peer. Rollback uses the matching remove fixture and repeats
the base hash and running-scope checks. The extension fixtures contain no
`frr version`, hostname, service, A VRF, `write memory`, or `vtysh -b`
operation. Their byte counts and SHA256 values are frozen in the materialized
runtime plan. BFD removal enters the `bfd` node and uses
`no peer <address> vrf <vrf>` followed by `exit`; a global `no bfd peer` form
is not admitted. The canonical base file and the exact A VRF, BGP-neighbor,
and BFD scopes must have the same bytes and observations before and after the
scoped operation.

The `ovnvrf300`, `ovnvrf400`, and `ovnvrf-x05-b` rows are OVN-generated
observation-only inventory. The adapter records their table, parent router,
and owner proof, but never directly deletes those VRFs. After the NB inverse,
it must assert that OVN has removed each generated VRF and retain the marker
when that absence check is incomplete.

## Negative control transaction

The control moves the **same** B sentinel LSP UUID; it does not create a
second `.12` endpoint. Before moving, read A/B LS UUIDs, the B LSP UUID, and
the complete `ports` UUID sets for both LS rows. Verify that B contains the
port exactly once and A does not. Use one `ovsdb-client transact` on OVN NB:
two `wait` operations on the LS `_uuid` and exact `ports` sets, then a
`mutate` delete on B and a `mutate` insert on A. Each operation is a JSON
object in a transaction array whose first element is the database name.
`x05-cas.sh --build` renders this transaction from a caller-supplied snapshot
and `--check-result` rejects transaction errors or mutation counts other than
one. It has no OVSDB connection or apply mode. The snapshot fixture uses fake
UUIDs and is only a local shape check.
Check the returned operation count, each `error`, and both mutation counts;
CLI exit status alone is insufficient. Read both parent port sets and the
LSP UUID after the commit. A mismatch aborts probes and starts restoration.

Restoration uses the inverse compare-and-swap transaction. It is the first
rollback step after any failure and must verify B as the sole parent. If an
unrelated writer changes either LS set, the wait guard fails closed and the
marker remains for manual recovery. Poll the SB Port_Binding and datapath
after each NB commit; an NB success does not prove datapath convergence.

## Evidence gates

| Gate | Required observation | Failure result |
|---|---|---|
| G0 | Local hashes, receipt, 5 DCI OVN nodes, M03/X05 absence, `p003-os=exited`, memory, k01/p003-gw UIDs and 10/10 canaries | STOP before mutation |
| G0a | Under shared lock, `labctl dci up --m03` and `verify --m03` pass; M03 marker/owner and A UUID/ports fingerprint captured | M03 owned rollback; no X05 mutation |
| G1 | Both B BGP legs established in distinct VRFs; A legs still established; each client RIB/FIB has its own `192.168.100.0/24` route | Rollback, no PASS |
| G2 | Simultaneous A/B EVPN Type 5 for the same prefix, respective VNI 50100/50200, correct VRF RIB/FIB/route-get, scoped `Learned_Route` on each tenant LRP/datapath | Rollback, no PASS |
| G3 | A→`.11` and B→`.12` pass; A→`.12` and B→`.11` fail while their own routes remain; peer sources `10.250.0.1` and `10.251.0.1` pass only to their own sentinel | Rollback, no PASS |
| G4 | Fabric and node captures show UDP 4789 and correct VNI plus tap request/reply on the intended sentinel; zero cross-tenant packets on the other tap | Rollback, no PASS |
| G5 | After the LSP move, A→`.12` passes with B tap request/reply, B→`.12` loses reachability, LSP UUID unchanged and parent A only | Restore immediately; no PASS if any observation missing |
| G6 | After inverse move, A→`.12` fails, B→`.12` passes, same UUID and B-only parent; positive gates remain | Rollback, no PASS |
| G7 | X05 resources/marker absent, M03 marker digest, A UUIDs and complete A LS `ports` set unchanged, `labctl dci verify --m03` passes | Retain marker or incident evidence; no PASS |
| G8 | `labctl dci down --m03` and baseline `verify` pass; M03 marker/peer absent, historical canaries/UIDs 10/10 | No PASS; preserve incident evidence |

Each probe records command, exit status, UTC time, output, and capture hash in
`evidence/P004/S002/<run>/08-x05/`. ICMP alone does not establish isolation.
The negative windows require route presence and concurrent taps so that a
failed ping is not mistaken for isolation when routing or the endpoint is
down. Each capture uses the fixed SLL2 DLT 276 `link[4:4]` ifindex-only
filter for its admitted interfaces; the decoder selects exact sentinel tuples,
UDP/VNI, ICMP semantics and bounded windows.

Rollback order: stop captures; restore B LSP and prove its parent; withdraw B
EVPN and B gateway BGP; remove X05 sentinel ports/netns; remove B peer/client
ports and containers; remove X05 links, mirrors, filters, NB rows and FRR
state; prove X05 absence; verify M03; call `labctl dci down --m03`, baseline
`verify`, and check canaries. X05 failure cleanup must attempt this sequence
once X05 absence is proven; if X05 ownership or LSP restoration is uncertain,
it retains both markers and stops before M03 teardown.
