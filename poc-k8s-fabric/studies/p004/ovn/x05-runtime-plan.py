#!/usr/bin/env python3
"""Pure-local X05 runtime inventory; no host, Docker, OVS, or NB access."""

import argparse
import copy
import hashlib
import json
import re
import sys
from pathlib import Path


HERE = Path(__file__).resolve().parent
TOKEN = "labctl-x05-<six-hex-run-token>"
ABSENT = "absent; reject existing unowned or ambiguous identity"
RESOURCES = []
RUN_HEX_RE = re.compile(r"^[0-9a-f]{6}$")

# Extension files are independently frozen.  The base FRR files already have
# their own review hashes below; these four values also bind the exact bytes
# used for the scoped add/remove operation into the materialized plan.
EXPECTED_FRR_EXTENSION_FIXTURES = {
    "x05-gw1-add.conf": (515, "4d30657f0b6af7f88c0ccc3e964d26d5f20d4e1938d54cb56a531b71510533d7"),
    "x05-gw1-remove.conf": (97, "3cc0890efe0e98f999370ee53456c97e3ba575865fbe7862807cb4b76ef64014"),
    "x05-gw2-add.conf": (515, "6ce1142b5bd8063a320c4d8224278106ec93a48f78a941fad4b6dd3d7e50291f"),
    "x05-gw2-remove.conf": (97, "c4689cfef5306d0d29aff77986041d98753a7ec494ab2d08c9ca845b52b9921e"),
}

EXPECTED_RUNTIME_FIXTURES = {
    "x05-client2.conf": (
        1388,
        "c4f928c4f84e794c29bb4660e171cd84e6c924a4dad3056866dccaf128982589",
    ),
    "x05-chassis.conf": (
        1043,
        "9ec32352c308f090362e02e44ce5e725baaa3cda74dbf79b71092e3e0da3cfce",
    ),
    "x05-peer.conf": (
        1083,
        "f047d33f87ea87b94ad0e964bd63325218ad5ba6312fef6627cb9b4e7aef828f",
    ),
}

# Independently frozen review manifest. The IDs are human-auditable; the
# digest pins every resource field (including desired, before, parent, owner
# proof, capture fields and rollback stage), so a future edit needs a review.
EXPECTED_RESOURCE_IDS = frozenset("""
host:vm-cilium/marker//run/labctl/dci-x05/active
host:vm-cilium/docker-container/dci-client-2
host:vm-cilium/ovs-port-interface/dci-client-2:eth1
host:vm-cilium/ovs-port-interface/dci-client-2:eth2
container:ovn-gw-1/ovn-generated-vrf/ovnvrf300
container:ovn-gw-1/linux-veth/bgpvrf300-ovs
container:ovn-gw-1/linux-veth/bgpvrf300
container:ovn-gw-1/ovs-port-interface/bgpvrf300-ovs
container:ovn-gw-1/frr-config-delta//etc/frr/frr.conf:ovnvrf300
container:ovn-gw-2/ovn-generated-vrf/ovnvrf400
container:ovn-gw-2/linux-veth/bgpvrf400-ovs
container:ovn-gw-2/linux-veth/bgpvrf400
container:ovn-gw-2/ovs-port-interface/bgpvrf400-ovs
container:ovn-gw-2/frr-config-delta//etc/frr/frr.conf:ovnvrf400
container:ovn-chassis-1/netns/x05-tenant-a-vm
container:ovn-chassis-1/linux-veth/x05-tenant-a-p
netns:ovn-chassis-1:x05-tenant-a-vm/linux-veth/x05-tenant-a
container:ovn-chassis-1/ovs-port-interface/x05-tenant-a-p
container:ovn-chassis-2/netns/x05-tenant-b-vm
container:ovn-chassis-2/linux-veth/x05-tenant-b-p
netns:ovn-chassis-2:x05-tenant-b-vm/linux-veth/x05-tenant-b
container:ovn-chassis-2/ovs-port-interface/x05-tenant-b-p
container:ovn-chassis-2/ovn-generated-vrf/ovnvrf-x05-b
container:ovn-chassis-2/linux-bridge/br-x05-b
container:ovn-chassis-2/linux-vxlan/vxlan-x05-b
container:ovn-chassis-2/linux-dummy/evpn-x05-b
container:ovn-chassis-2/frr-pathspace/x05
container:ovn-chassis-2/ovs-external-id/dynamic-routing-port-mapping
container:ovn-chassis-2/ovs-external-id/ovn-evpn-local-ip
host:vm-cilium/docker-container/dci-x05-peer-2
host:vm-cilium/ovs-port-interface/dci-x05-peer-2:eth1
container:dci-x05-peer-2/linux-vrf/vrf-x05-peer
container:dci-x05-peer-2/linux-bridge/br-x05-peer
container:dci-x05-peer-2/linux-vxlan/vxlan-x05-pr
container:dci-x05-peer-2/linux-dummy/evpn-x05-pr
container:dci-x05-peer-2/frr-pathspace/x05
NB:ovn-central-az1/lsp-parent-control/x05-tenant-b-vm
host:vm-cilium/capture-processes/<run>/08-x05/tcpdump-pids
host:vm-cilium/capture-file/<run>/08-x05/fabric.pcap
host:vm-cilium/capture-file/<run>/08-x05/chassis-1.pcap
host:vm-cilium/capture-file/<run>/08-x05/chassis-2.pcap
host:vm-cilium/capture-file/<run>/08-x05/gateway-300.pcap
host:vm-cilium/capture-file/<run>/08-x05/gateway-400.pcap
""".split())
EXPECTED_RESOURCE_MANIFEST_SHA256 = "fe9ad4619e4a941d677807faba0f155f9188cb9ce79ad34f178f9350a584c1c9"


def add(kind, host, name, *, parent=None, desired=None, before="absent",
        precondition=ABSENT, ownership=None, rollback_stage=50,
        rollback=None, capture=None, observation_only=False):
    """Record an identity and the state a future adapter must journal."""
    resource_id = f"{host}/{kind}/{name}"
    resource = {
        "id": resource_id, "kind": kind, "host": host, "name": name,
        "parent": parent, "desired": desired, "before": before,
        "precondition": precondition, "owner_token": TOKEN,
        "ownership_proof": ownership or "name, type, parent, captured identity and owner token",
        "capture_before_mutation": capture or ["existence", "identity", "parent"],
        "rollback_stage": rollback_stage,
        "rollback": rollback or "remove only after ownership and captured identity match",
    }
    if observation_only:
        resource["observation_only"] = True
        resource["after_inverse"] = "absent; verify OVN generated object after NB inverse"
    RESOURCES.append(resource)
    return resource_id


def build_plan():
    """Freeze runtime resources separately from the 34-row NB inventory."""
    RESOURCES.clear()
    add("marker", "host:vm-cilium", "/run/labctl/dci-x05/active",
        desired={"mode": "0600", "owner": "root", "token": TOKEN},
        ownership="root, mode 0600, token and complete journal",
        rollback_stage=90,
        rollback="remove only after every X05 resource is absent and B LSP parent restored")

    # Client B's host OVS port names are assigned by ovs-runc. The exact
    # lookup identity is container_id + container_iface; journal both UUIDs.
    client = "container:dci-client-2"
    add("docker-container", "host:vm-cilium", "dci-client-2",
        desired={"image": "frrouting/frr:v8.4.1", "network": "none", "as": 201,
                 "loopback": "10.0.0.1/32", "frr_fixture": "x05-client2.conf",
                 "frr_fixture_bytes": EXPECTED_RUNTIME_FIXTURES["x05-client2.conf"][0],
                 "frr_fixture_sha256": EXPECTED_RUNTIME_FIXTURES["x05-client2.conf"][1],
                 "labels": {"labctl.dci.owner": "<profile-owner>", "labctl-x05-owner": TOKEN}},
        ownership="Docker ID, exact name, X05 label and DCI profile label",
        rollback_stage=45, rollback="remove labeled container after both OVS ports")
    for iface, vlan, address in (("eth1", 300, "169.254.254.2/30"),
                                 ("eth2", 400, "169.254.254.6/30")):
        add("ovs-port-interface", "host:vm-cilium", f"dci-client-2:{iface}",
            parent="br-ovn-ext", desired={"container": "dci-client-2", "container_iface": iface,
                                          "ip": address, "vlan": vlan, "mtu": 1500,
                                          "interface_external_ids": {"x05-owner": TOKEN}},
            ownership="container_id+container_iface, Port UUID, Interface UUID, host ifname, br-ovn-ext, VLAN, X05 owner",
            capture=["Port UUID", "Interface UUID", "host ifname", "container ID", "VLAN"],
            rollback_stage=40, rollback="ovs-runc del-port only for captured owned port/interface")

    for number, gateway, fixture_key, gw_ip, peer_ip, lrp_mac, client_if in (
        (300, "ovn-gw-1", "gw1", "169.254.254.1/30", "169.254.254.2",
         "02:00:2c:00:00:01", "eth1"),
        (400, "ovn-gw-2", "gw2", "169.254.254.5/30", "169.254.254.6",
         "02:00:90:00:00:01", "eth2"),
    ):
        node = f"container:{gateway}"
        vrf = f"ovnvrf{number}"
        ovs_if = f"bgpvrf{number}-ovs"
        vrf_if = f"bgpvrf{number}"
        add("ovn-generated-vrf", node, vrf,
            parent=f"NB:lr-x05-{number}", desired={"table": number},
            before="absent; generated by owned NB dynamic routing",
            ownership="VRF table, name, owning NB router UUID and X05 marker",
            rollback_stage=80, rollback="verify absent after owned NB router removal; never delete directly",
            observation_only=True)
        add("linux-veth", node, ovs_if, parent=f"br-int/{vrf_if}",
            desired={"type": "veth", "peer": vrf_if, "alias": TOKEN},
            ownership="ifindex, iflink peer, alias, OVS port UUID and br-int",
            capture=["ifindex", "peer ifindex", "alias", "OVS Port UUID"],
            rollback_stage=61, rollback="delete veth only after mirror OVS port detached")
        add("linux-veth", node, vrf_if, parent=vrf,
            desired={"type": "veth", "peer": ovs_if, "address": gw_ip,
                     "master": vrf, "alias": TOKEN,
                     "mac_source": f"NB:lrp-x05-{number}-external",
                     "expected_lrp_mac": lrp_mac,
                     "neighbor_invalidation_if_mac_changes":
                         f"dci-client-2:{client_if} via {gw_ip.removesuffix('/30')}"},
            ownership="ifindex, iflink peer, alias, master VRF, address and NB LRP MAC",
            capture=["ifindex", "peer ifindex", "alias", "master", "address",
                     "current MAC", "NB LRP UUID", "NB LRP MAC", "client B neighbor"],
            rollback_stage=61, rollback="removed with owned veth pair; verify address and peer absent")
        add("ovs-port-interface", node, ovs_if, parent="br-int",
            desired={"iface-id": f"bgpvrf{number}", "external_ids": {"x05-owner": TOKEN}},
            ownership="Port UUID, Interface UUID, iface-id, br-int and X05 owner",
            capture=["Port UUID", "Interface UUID", "ifindex", "iface-id"],
            rollback_stage=60, rollback="detach captured owned mirror before deleting veth pair")
        add("frr-config-delta", node, f"/etc/frr/frr.conf:ovnvrf{number}",
            parent="/etc/frr/frr.conf",
            desired={"base_fixture": f"frr-{fixture_key}.conf",
                     "base_path": "/etc/frr/frr.conf",
                     "base_sha256": {
                         "gw1": "2838c8687b8d45dba49a3d6c488780cf8e3a00f281e5eb26c16d6fa7c6ebbbb7",
                         "gw2": "d464ddc249ae61a58a0df3058ae482d75ebb8e768ebd00c772e6a50fa5fee6c9",
                     }[fixture_key],
                     "add_fixture": f"x05-{fixture_key}-add.conf",
                     "remove_fixture": f"x05-{fixture_key}-remove.conf",
                     "add_fixture_bytes": EXPECTED_FRR_EXTENSION_FIXTURES[
                         f"x05-{fixture_key}-add.conf"][0],
                     "add_fixture_sha256": EXPECTED_FRR_EXTENSION_FIXTURES[
                         f"x05-{fixture_key}-add.conf"][1],
                     "remove_fixture_bytes": EXPECTED_FRR_EXTENSION_FIXTURES[
                         f"x05-{fixture_key}-remove.conf"][0],
                     "remove_fixture_sha256": EXPECTED_FRR_EXTENSION_FIXTURES[
                         f"x05-{fixture_key}-remove.conf"][1],
                     "apply": {
                         "check": f"vtysh -C -f x05-{fixture_key}-add.conf",
                         "add": f"vtysh -f x05-{fixture_key}-add.conf",
                         "remove": f"vtysh -f x05-{fixture_key}-remove.conf",
                         "write_memory": False,
                         "vtysh_b": False,
                     },
                     "scopes": [f"vrf {vrf}", f"router bgp 100 vrf {vrf}",
                                f"bfd peer {peer_ip} vrf {vrf}"],
                     "remote_as": 201, "neighbor": peer_ip,
                     "preserve_base": True,
                     "preserve_a_scopes": True},
            before="exact /etc/frr/frr.conf bytes and SHA256; must match canonical base fixture",
            precondition="gateway FRR baseline equals canonical fixture; X05 VRF/neighbor absent",
            ownership="base hash, extension add/remove fixture hashes, exact X05 VRF/neighbor scope",
            capture=["exact file bytes", "SHA256", "running VRF/neighbor/BFD state"],
            rollback_stage=20,
            rollback="apply extension-only remove fixture, verify base hash and A VRF intact")

    # A and B sentinels are separate netns/veth pairs in different chassis.
    for tenant, node, ip, mac in (
        ("a", "ovn-chassis-1", "192.168.100.11", "02:00:00:10:00:11"),
        ("b", "ovn-chassis-2", "192.168.100.12", "02:00:00:10:00:12"),
    ):
        host = f"container:{node}"
        ns = f"x05-tenant-{tenant}-vm"
        tap = f"x05-tenant-{tenant}-p"
        inner = f"x05-tenant-{tenant}"
        add("netns", host, ns, desired={"name": ns},
            ownership="netns inode, exact name, marker journal and owned veth peer",
            capture=["netns inode", "name"], rollback_stage=33,
            rollback="delete namespace only after its OVS port and veth pair")
        add("linux-veth", host, tap, parent=f"br-int/{ns}",
            desired={"type": "veth", "peer": inner, "alias": TOKEN},
            ownership="ifindex, iflink peer, alias and OVS UUID",
            capture=["ifindex", "peer ifindex", "alias", "OVS UUID"],
            rollback_stage=32, rollback="delete owned veth after OVS detach")
        add("linux-veth", f"netns:{node}:{ns}", inner, parent=ns,
            desired={"type": "veth", "peer": tap, "mac": mac,
                     "address": f"{ip}/24", "default_via": "192.168.100.1", "alias": TOKEN},
            ownership="netns inode, ifindex, peer ifindex, MAC, address and alias",
            capture=["netns inode", "ifindex", "peer ifindex", "MAC", "address", "route"],
            rollback_stage=32, rollback="removed with owned host veth; verify address gone")
        add("ovs-port-interface", host, tap, parent="br-int",
            desired={"iface-id": ns, "external_ids": {"x05-owner": TOKEN}},
            ownership="Port UUID, Interface UUID, br-int, iface-id and X05 owner",
            capture=["Port UUID", "Interface UUID", "ifindex", "iface-id"],
            rollback_stage=31, rollback="detach owned sentinel OVS port after B LSP restoration")

    chassis = "container:ovn-chassis-2"
    add("ovn-generated-vrf", chassis, "ovnvrf-x05-b",
        parent="NB:lr-x05-tenant-b", desired={"table": 400, "alias": TOKEN},
        before="absent; may be generated by NB dynamic routing",
        ownership="ifindex, table 400, alias if created locally, owning NB router UUID",
        rollback_stage=75,
        rollback="verify absent after B router withdrawal; never delete directly",
        observation_only=True)
    for name, kind, parent, desired, stage in (
        ("br-x05-b", "linux-bridge", "ovnvrf-x05-b", {"alias": TOKEN}, 73),
        ("vxlan-x05-b", "linux-vxlan", "br-x05-b",
         {"vni": 50200, "local": "170.168.0.6", "underlay": "vxlan_sys_4789",
          "dstport": 60010, "alias": TOKEN}, 72),
        ("evpn-x05-b", "linux-dummy", "br-x05-b", {"alias": TOKEN}, 72),
    ):
        add(kind, chassis, name, parent=parent, desired=desired,
            ownership="ifindex, alias, link type and expected master",
            capture=["ifindex", "alias", "link type", "master"],
            rollback_stage=stage)
    add("frr-pathspace", chassis, "x05", parent="/etc/frr/x05;/run/frr/x05",
        desired={"fixture": "x05-chassis.conf", "vrf": "ovnvrf-x05-b",
                 "fixture_bytes": EXPECTED_RUNTIME_FIXTURES["x05-chassis.conf"][0],
                 "fixture_sha256": EXPECTED_RUNTIME_FIXTURES["x05-chassis.conf"][1],
                 "as": 65101, "neighbor": "170.168.0.8", "vni": 50200},
        ownership="-N x05 daemon cmdlines, pathspace files and exact fixture hash",
        capture=["pathspace absence", "daemon PIDs", "config directory absence"],
        rollback_stage=21, rollback="withdraw Type 5, stop only -N x05 daemons, remove owned pathspace files")
    add("ovs-external-id", chassis, "dynamic-routing-port-mapping",
        parent="Open_vSwitch .",
        desired="x05-b-<six-hex-run-token>=br-x05-b",
        before="capture exact original key value; expected absent on chassis 2",
        precondition="M03 mapping on chassis 1 remains unchanged; chassis 2 key absent",
        ownership="exact previous value, exact X05 filter name and token",
        capture=["exact original value", "Open_vSwitch UUID"],
        rollback_stage=76, rollback="compare X05 value, restore exact original value")
    add("ovs-external-id", chassis, "ovn-evpn-local-ip",
        parent="Open_vSwitch .",
        desired="50100-170.168.0.6,50200-170.168.0.6",
        before="capture exact original key value; expected 50100-170.168.0.6",
        precondition="exact expected chassis 2 baseline; other nodes read for drift only",
        ownership="Open_vSwitch UUID, exact original and X05 updated value",
        capture=["exact original value", "Open_vSwitch UUID", "other nodes' values"],
        rollback_stage=77, rollback="after B withdrawal, compare X05 value and restore exact original")

    peer = "container:dci-x05-peer-2"
    add("docker-container", "host:vm-cilium", "dci-x05-peer-2",
        desired={"image": "ovn/ovn-multi-node:latest", "network": "none",
                 "labels": {"labctl.dci.owner": "<profile-owner>", "labctl-x05-owner": TOKEN}},
        ownership="Docker ID, exact name, X05 label and DCI profile label",
        rollback_stage=56,
        rollback="remove labeled peer after OVS port, FRR stop, and owned internal links")
    add("ovs-port-interface", "host:vm-cilium", "dci-x05-peer-2:eth1",
        parent="br-ovn", desired={"ip": "170.168.0.8/16", "vlan": "untagged",
                                  "external_ids": {"x05-owner": TOKEN}},
        ownership="container_id+container_iface, Port/Interface UUIDs, br-ovn and X05 owner",
        capture=["Port UUID", "Interface UUID", "host ifname", "container ID"],
        rollback_stage=40, rollback="ovs-runc del-port for captured owned interface")
    for name, kind, parent, desired, stage in (
        ("vrf-x05-peer", "linux-vrf", None, {"table": 50200, "alias": TOKEN}, 54),
        ("br-x05-peer", "linux-bridge", "vrf-x05-peer", {"alias": TOKEN,
                                                     "address": "10.251.0.1/32"}, 53),
        ("vxlan-x05-pr", "linux-vxlan", "br-x05-peer",
         {"vni": 50200, "local": "170.168.0.8", "underlay": "eth1",
          "dstport": 4789, "alias": TOKEN}, 52),
        ("evpn-x05-pr", "linux-dummy", "br-x05-peer", {"alias": TOKEN}, 52),
    ):
        add(kind, peer, name, parent=parent, desired=desired,
            ownership="ifindex, alias, link type and expected master",
            capture=["ifindex", "alias", "link type", "master", "address"],
            rollback_stage=stage)
    add("frr-pathspace", peer, "x05", parent="/etc/frr/x05;/run/frr/x05",
        desired={"fixture": "x05-peer.conf", "vrf": "vrf-x05-peer", "as": 65201,
                 "fixture_bytes": EXPECTED_RUNTIME_FIXTURES["x05-peer.conf"][0],
                 "fixture_sha256": EXPECTED_RUNTIME_FIXTURES["x05-peer.conf"][1],
                 "neighbor": "170.168.0.6", "source": "10.251.0.1/32"},
        ownership="-N x05 daemon cmdlines, pathspace files and exact fixture hash",
        capture=["pathspace absence", "daemon PIDs", "config directory absence"],
        rollback_stage=21, rollback="withdraw Type 5, stop only -N x05 daemons, remove owned pathspace files")

    add("lsp-parent-control", "NB:ovn-central-az1", "x05-tenant-b-vm",
        parent="ls-x05-tenant-b",
        desired={"temporary_parent": "ls-dci-tenant", "final_parent": "ls-x05-tenant-b",
                 "same_lsp_uuid": True},
        before="capture B LSP UUID and complete A/B LS port sets; B sole parent",
        precondition="B LSP exists once in B, absent in A; CAS guards both complete sets",
        ownership="captured LSP UUID, both LS UUIDs and complete port sets",
        capture=["LSP UUID", "A/B LS UUIDs", "A/B complete ports"],
        rollback_stage=10,
        rollback="inverse CAS first; verify same UUID and B sole parent before all other cleanup")
    add("capture-processes", "host:vm-cilium", "<run>/08-x05/tcpdump-pids",
        parent="evidence/P004/S002/<run>/08-x05",
        desired={"locations": ["fabric:br-ovn", "ovn-chassis-1:tap/vxlan",
                                "ovn-chassis-2:tap/vxlan", "gateway:300/400"]},
        before="absent run directory and PID journal",
        ownership="marker PID+start time+command+namespace; run-specific evidence path",
        capture=["PID", "start time", "command", "namespace inode", "output path"],
        rollback_stage=0, rollback="stop only captured matching PIDs; preserve capture files")
    for location in ("fabric", "chassis-1", "chassis-2", "gateway-300", "gateway-400"):
        add("capture-file", "host:vm-cilium", f"<run>/08-x05/{location}.pcap",
            parent="evidence/P004/S002/<run>/08-x05",
            desired={"bounded": True, "filter": "fixed SLL2 DLT 276 link[4:4] ifindex-only; decoder selects tuples, UDP/VNI, ICMP semantics and windows"},
            before="absent run-specific evidence file",
            ownership="run path, marker token, capture PID, file inode and SHA256",
            capture=["path", "inode", "PID", "SHA256 after capture"],
            rollback_stage=1, rollback="preserve evidence file; never delete during rollback")

    return {"schema": "p004-x05-runtime-plan-v1", "mode": "pure-local",
            "owner_token_placeholder": TOKEN,
            "run_token_pattern": "[0-9a-f]{6}",
            "no_apply_mode": True,
            "baseline": "M03 absent at G0, then active and fingerprinted under FD 9 before X05 intent",
            "journal_rule": "persist owner, exact before value and intended step before mutation; never adopt",
            "nb_inventory": "x05-nb-plan.sh --plan (34 separate NB rows)",
            "transit": {"300": {"tenant": "10.31.100.1/30", "gateway": "10.31.100.2/30",
                                "next_hop": "10.31.100.2"},
                        "400": {"tenant": "10.41.100.1/30", "gateway": "10.41.100.2/30",
                                "next_hop": "10.41.100.2"}},
            "rollback_policy": "verify ownership and captured identity at every step",
            "rollback_order": [item["id"] for item in sorted(
                RESOURCES, key=lambda item: (item["rollback_stage"], item["id"]))],
            "resources": RESOURCES}


def _replace_placeholders(value, *, run_hex, owner_token, profile_owner,
                           evidence_path):
    """Materialize one plan without changing the frozen template."""
    if isinstance(value, str):
        value = value.replace("evidence/P004/S002/<run>/08-x05", evidence_path)
        value = value.replace(TOKEN, owner_token)
        value = value.replace("<profile-owner>", profile_owner)
        value = value.replace("<six-hex-run-token>", run_hex)
        value = value.replace("<run>", run_hex)
        return value
    if isinstance(value, list):
        return [_replace_placeholders(item, run_hex=run_hex,
                                      owner_token=owner_token,
                                      profile_owner=profile_owner,
                                      evidence_path=evidence_path)
                for item in value]
    if isinstance(value, dict):
        return {key: _replace_placeholders(item, run_hex=run_hex,
                                            owner_token=owner_token,
                                            profile_owner=profile_owner,
                                            evidence_path=evidence_path)
                for key, item in value.items()}
    return value


def _contains_placeholder(value):
    if isinstance(value, str):
        return "<" in value or ">" in value
    if isinstance(value, list):
        return any(_contains_placeholder(item) for item in value)
    if isinstance(value, dict):
        return any(_contains_placeholder(item) for item in value.values())
    return False


def resource_ids_sha256(resources):
    """Hash sorted concrete identities for journal binding."""
    payload = json.dumps(sorted(item["id"] for item in resources),
                         separators=(",", ":"))
    return hashlib.sha256(payload.encode()).hexdigest()


def _fixture_digest(filename, data=None):
    """Return the byte count and digest for one frozen local fixture."""
    if data is None:
        data = (HERE / filename).read_bytes()
    return len(data), hashlib.sha256(data).hexdigest()


def _fixture_matches(filename, data):
    """Check exact bytes against the reviewed extension fixture contract."""
    return _fixture_digest(filename, data) == EXPECTED_FRR_EXTENSION_FIXTURES[filename]


def materialize_plan(run_hex, owner_token, evidence_path, profile_owner):
    """Return a concrete, admission-ready copy of the pure-local template."""
    if RUN_HEX_RE.fullmatch(run_hex or "") is None:
        raise ValueError("run_hex must be exactly six lowercase hexadecimal characters")
    if owner_token != f"labctl-x05-{run_hex}":
        raise ValueError("owner token is not bound to run_hex")
    if not isinstance(evidence_path, str) or not evidence_path.startswith("/"):
        raise ValueError("evidence path must be absolute")
    if not isinstance(profile_owner, str) or not profile_owner or "<" in profile_owner:
        raise ValueError("profile owner is missing or contains a placeholder")
    plan = copy.deepcopy(build_plan())
    plan = _replace_placeholders(plan, run_hex=run_hex, owner_token=owner_token,
                                 profile_owner=profile_owner,
                                 evidence_path=evidence_path)
    if _contains_placeholder(plan["resources"]):
        raise ValueError("materialized runtime inventory contains a placeholder")
    plan["run_hex"] = run_hex
    plan["owner_token"] = owner_token
    plan["profile_owner"] = profile_owner
    plan["evidence_path"] = evidence_path
    manifest = json.dumps(plan["resources"], sort_keys=True, separators=(",", ":"))
    plan["runtime_plan_sha256"] = hashlib.sha256(manifest.encode()).hexdigest()
    plan["resource_ids_sha256"] = resource_ids_sha256(plan["resources"])
    return plan


def validate(plan):
    errors = []
    if plan["schema"] != "p004-x05-runtime-plan-v1" or not plan["no_apply_mode"]:
        errors.append("schema or local-only mode changed")
    resources = plan["resources"]
    ids = [item["id"] for item in resources]
    if len(ids) != len(set(ids)):
        errors.append("duplicate resource identity")
    if set(ids) != EXPECTED_RESOURCE_IDS:
        errors.append("resource identities differ from frozen manifest")
    manifest = json.dumps(resources, sort_keys=True, separators=(",", ":"))
    if hashlib.sha256(manifest.encode()).hexdigest() != EXPECTED_RESOURCE_MANIFEST_SHA256:
        errors.append("resource fields differ from frozen manifest")
    if plan["rollback_order"] != [item["id"] for item in sorted(
            resources, key=lambda item: (item["rollback_stage"], item["id"]))]:
        errors.append("rollback order disagrees with resource stages")
    if any(item["owner_token"] != TOKEN or not item["precondition"] or
           not item["ownership_proof"] or not item["capture_before_mutation"] or
           not item["rollback"] for item in resources):
        errors.append("incomplete owner/precondition/capture/rollback")
    generated = [item for item in resources if item["kind"] == "ovn-generated-vrf"]
    if {item["name"] for item in generated} != {"ovnvrf300", "ovnvrf400", "ovnvrf-x05-b"}:
        errors.append("OVN generated VRF observation inventory is incomplete")
    if any(item.get("observation_only") is not True or
           item.get("after_inverse") != "absent; verify OVN generated object after NB inverse"
           or "never delete directly" not in item["rollback"] for item in generated):
        errors.append("generated VRFs must be observation-only and absent after inverse")
    for item in resources:
        if item["kind"].startswith("linux-"):
            if len(item["name"].encode("ascii")) > 15:
                errors.append(f"Linux ifname exceeds 15 bytes: {item['id']}")
    if plan["transit"] != {
        "300": {"tenant": "10.31.100.1/30", "gateway": "10.31.100.2/30",
                "next_hop": "10.31.100.2"},
        "400": {"tenant": "10.41.100.1/30", "gateway": "10.41.100.2/30",
                "next_hop": "10.41.100.2"},
    }:
        errors.append("transit addresses changed")
    sentinels = {item["name"]: item for item in resources if item["kind"] == "linux-veth"
                 and item["host"].startswith("netns:")}
    if set(sentinels) != {"x05-tenant-a", "x05-tenant-b"} or any(
        sentinels[name]["desired"]["address"] != ip or
        sentinels[name]["desired"]["mac"] != mac
        for name, ip, mac in (
            ("x05-tenant-a", "192.168.100.11/24", "02:00:00:10:00:11"),
            ("x05-tenant-b", "192.168.100.12/24", "02:00:00:10:00:12"))
    ):
        errors.append("sentinel identity or address mismatch")
    gateway_specs = (
        (300, "ovn-gw-1", "gw1", "eth1", "02:00:2c:00:00:01", "169.254.254.1"),
        (400, "ovn-gw-2", "gw2", "eth2", "02:00:90:00:00:01", "169.254.254.5"),
    )
    by_id = {item["id"]: item for item in resources}
    for number, gateway, fixture_key, client_if, lrp_mac, gw_ip in gateway_specs:
        mirror = by_id.get(f"container:{gateway}/linux-veth/bgpvrf{number}", {})
        desired = mirror.get("desired", {})
        if (desired.get("mac_source") != f"NB:lrp-x05-{number}-external" or
            desired.get("expected_lrp_mac") != lrp_mac or
            desired.get("neighbor_invalidation_if_mac_changes") !=
                f"dci-client-2:{client_if} via {gw_ip}" or
            "NB LRP MAC" not in mirror.get("capture_before_mutation", [])):
            errors.append(f"{gateway} mirror MAC provenance or neighbor guard missing")
        frr = by_id.get(
            f"container:{gateway}/frr-config-delta//etc/frr/frr.conf:ovnvrf{number}", {})
        desired_frr = frr.get("desired", {})
        if (desired_frr.get("base_fixture") != f"frr-{fixture_key}.conf" or
            desired_frr.get("add_fixture") != f"x05-{fixture_key}-add.conf" or
            desired_frr.get("remove_fixture") != f"x05-{fixture_key}-remove.conf" or
            desired_frr.get("base_path") != "/etc/frr/frr.conf" or
            desired_frr.get("preserve_base") is not True or
            desired_frr.get("preserve_a_scopes") is not True or
            desired_frr.get("apply", {}).get("write_memory") is not False or
            desired_frr.get("apply", {}).get("vtysh_b") is not False):
            errors.append(f"{gateway} FRR fixture reference mismatch")
    peer_vxlan = by_id.get("container:dci-x05-peer-2/linux-vxlan/vxlan-x05-pr", {})
    if peer_vxlan.get("desired", {}).get("vni") != 50200:
        errors.append("peer VXLAN VNI mismatch")
    peer_container = by_id.get("host:vm-cilium/docker-container/dci-x05-peer-2", {})
    peer_links = [by_id.get(f"container:dci-x05-peer-2/{kind}/{name}", {})
                  for kind, name in (("linux-vrf", "vrf-x05-peer"),
                                     ("linux-bridge", "br-x05-peer"),
                                     ("linux-vxlan", "vxlan-x05-pr"),
                                     ("linux-dummy", "evpn-x05-pr"))]
    if not peer_container or any(not link or link["rollback_stage"] >=
                                 peer_container["rollback_stage"] for link in peer_links):
        errors.append("peer container cleanup precedes internal link cleanup")
    stages = {item["kind"]: item["rollback_stage"] for item in resources}
    if stages["capture-processes"] != 0 or stages["lsp-parent-control"] != 10:
        errors.append("unsafe first rollback steps")
    if any(item["rollback_stage"] < 20 for item in resources
           if item["kind"] not in {"capture-processes", "capture-file", "lsp-parent-control"}):
        errors.append("resource cleanup precedes LSP restoration")
    try:
        import subprocess
        nb = subprocess.run(["bash", str(HERE / "x05-nb-plan.sh"), "--plan"],
                            check=True, capture_output=True, text=True)
        nb_plan = json.loads(nb.stdout)
        networks = [value for row in nb_plan["objects"]
                    for value in row["values"].get("networks", [])]
        nexthops = [row["values"].get("nexthop") for row in nb_plan["objects"]]
        if not all(value in networks for value in ("10.31.100.1/30", "10.31.100.2/30",
                                                    "10.41.100.1/30", "10.41.100.2/30")):
            errors.append("NB transit /30 mismatch")
        if not all(value in nexthops for value in ("10.31.100.2", "10.41.100.2")):
            errors.append("NB transit next-hop mismatch")
        addresses = [address for row in nb_plan["objects"]
                     for address in row["values"].get("addresses", [])]
        if any("192.168.100.10" in address for address in addresses):
            errors.append("B/A sentinel collides with existing .10")
        for number, gateway, _, _, lrp_mac, _ in gateway_specs:
            nb_lrp = next((row for row in nb_plan["objects"]
                           if row["name"] == f"lrp-x05-{number}-external"), None)
            if nb_lrp is None or nb_lrp["values"].get("mac") != lrp_mac:
                errors.append(f"{gateway} NB LRP MAC does not match mirror")
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as exc:
        errors.append(f"NB inventory unavailable: {exc}")
    for gateway, vrf, neighbor, expected_hash, expected_bytes in (
            ("gw1", "ovnvrf300", "169.254.254.2",
             "2838c8687b8d45dba49a3d6c488780cf8e3a00f281e5eb26c16d6fa7c6ebbbb7", 1030),
            ("gw2", "ovnvrf400", "169.254.254.6",
             "d464ddc249ae61a58a0df3058ae482d75ebb8e768ebd00c772e6a50fa5fee6c9", 964)):
        base = (HERE / f"frr-{gateway}.conf").read_bytes()
        add_name = f"x05-{gateway}-add.conf"
        remove_name = f"x05-{gateway}-remove.conf"
        add_bytes = (HERE / add_name).read_bytes()
        remove_bytes = (HERE / remove_name).read_bytes()
        add_fixture = add_bytes.decode("utf-8")
        remove_fixture = remove_bytes.decode("utf-8")
        frr_resource = by_id.get(
            f"container:{'ovn-gw-1' if gateway == 'gw1' else 'ovn-gw-2'}"
            f"/frr-config-delta//etc/frr/frr.conf:{vrf}", {})
        desired_frr = frr_resource.get("desired", {})
        if len(base) != expected_bytes or hashlib.sha256(base).hexdigest() != expected_hash:
            errors.append(f"{gateway} canonical FRR base hash changed")
        expected_add = EXPECTED_FRR_EXTENSION_FIXTURES[add_name]
        expected_remove = EXPECTED_FRR_EXTENSION_FIXTURES[remove_name]
        if not _fixture_matches(add_name, add_bytes):
            errors.append(f"{gateway} add fixture bytes/hash changed")
        if not _fixture_matches(remove_name, remove_bytes):
            errors.append(f"{gateway} remove fixture bytes/hash changed")
        if (desired_frr.get("add_fixture_bytes") != expected_add[0] or
                desired_frr.get("add_fixture_sha256") != expected_add[1] or
                desired_frr.get("remove_fixture_bytes") != expected_remove[0] or
                desired_frr.get("remove_fixture_sha256") != expected_remove[1]):
            errors.append(f"{gateway} extension fixture digest is not bound in plan")
        if not add_fixture.endswith("\n") or not remove_fixture.endswith("\n"):
            errors.append(f"{gateway} extension fixtures lack final newline")
        if re.search(r"\b(?:ovnvrf100|ovnvrf200)\b", add_fixture + remove_fixture):
            errors.append(f"{gateway} extension touches A VRF")
        if (f"vrf {vrf}\n" not in add_fixture or
                f"router bgp 100 vrf {vrf}\n" not in add_fixture or
                f" neighbor {neighbor} remote-as 201\n" not in add_fixture or
                f" peer {neighbor} vrf {vrf}\n" not in add_fixture):
            errors.append(f"{gateway} add fixture is missing the reviewed X05 scopes")
        if (f"bfd\n no peer {neighbor} vrf {vrf}\nexit\n" not in remove_fixture or
                f"no router bgp 100 vrf {vrf}\n" not in remove_fixture or
                f"no vrf {vrf}\n" not in remove_fixture):
            errors.append(f"{gateway} remove fixture is not scoped")
    runtime_fixture_resources = {
        "x05-client2.conf": by_id.get(
            "host:vm-cilium/docker-container/dci-client-2", {}
        ).get("desired", {}),
        "x05-chassis.conf": by_id.get(
            "container:ovn-chassis-2/frr-pathspace/x05", {}
        ).get("desired", {}),
        "x05-peer.conf": by_id.get(
            "container:dci-x05-peer-2/frr-pathspace/x05", {}
        ).get("desired", {}),
    }
    for filename, required, bgp_scopes in (
        ("x05-client2.conf", ["router bgp 201", "10.0.0.0/16"],
         ["router bgp 201"]),
        ("x05-chassis.conf", ["vrf ovnvrf-x05-b", "vni 50200"],
         ["router bgp 65101", "router bgp 65101 vrf ovnvrf-x05-b"]),
        ("x05-peer.conf", ["vrf vrf-x05-peer", "10.251.0.1/32"],
         ["router bgp 65201", "router bgp 65201 vrf vrf-x05-peer"]),
    ):
        fixture_bytes = (HERE / filename).read_bytes()
        content = fixture_bytes.decode("utf-8")
        expected_size, expected_digest = EXPECTED_RUNTIME_FIXTURES[filename]
        desired = runtime_fixture_resources[filename]
        if (len(fixture_bytes) != expected_size or
                hashlib.sha256(fixture_bytes).hexdigest() != expected_digest):
            errors.append(f"{filename} exact bytes/hash changed")
        if filename == "x05-client2.conf":
            bound_size = desired.get("frr_fixture_bytes")
            bound_digest = desired.get("frr_fixture_sha256")
        else:
            bound_size = desired.get("fixture_bytes")
            bound_digest = desired.get("fixture_sha256")
        if bound_size != expected_size or bound_digest != expected_digest:
            errors.append(f"{filename} digest is not bound in plan")
        if not all(value in content for value in required):
            errors.append(f"{filename} scope mismatch")
        if re.findall(r"^router bgp .+$", content, re.MULTILINE) != bgp_scopes:
            errors.append(f"{filename} unexpected BGP scope")
    return errors


def selftest():
    """A damaged local plan must fail before it can be used as a journal recipe."""
    original = build_plan()
    if validate(original):
        return 1
    concrete = materialize_plan(
        "a1b2c3", "labctl-x05-a1b2c3",
        "/evidence/P004/S002/a1b2c3/08-x05", "dci-profile-fixture")
    if (len(concrete["resources"]) != 43
            or any(_contains_placeholder(item) for item in concrete["resources"])
            or concrete["owner_token"] != "labctl-x05-a1b2c3"
            or concrete["run_hex"] != "a1b2c3"):
        print("X05 runtime selftest FAIL: concrete materialization retained a placeholder",
              file=sys.stderr)
        return 1
    injected = (HERE / "x05-gw1-add.conf").read_bytes() + b"no route-map MG-FROM-CLIENT\n"
    if _fixture_matches("x05-gw1-add.conf", injected):
        print("X05 runtime selftest FAIL: injected global FRR command accepted",
              file=sys.stderr)
        return 1
    cases = []
    duplicate = copy.deepcopy(original)
    duplicate["resources"].append(copy.deepcopy(duplicate["resources"][0]))
    cases.append(duplicate)
    long_name = copy.deepcopy(original)
    next(item for item in long_name["resources"] if item["kind"] == "linux-veth")["name"] = "x05-too-long-ifname"
    cases.append(long_name)
    transit = copy.deepcopy(original)
    transit["transit"]["400"]["tenant"] = "10.40.100.1/30"
    cases.append(transit)
    ownership = copy.deepcopy(original)
    ownership["resources"][0]["owner_token"] = "foreign"
    cases.append(ownership)
    sentinel = copy.deepcopy(original)
    next(item for item in sentinel["resources"]
         if item["id"] == "netns:ovn-chassis-2:x05-tenant-b-vm/linux-veth/x05-tenant-b")[
             "desired"]["address"] = "192.168.100.10/24"
    cases.append(sentinel)
    peer_vni = copy.deepcopy(original)
    next(item for item in peer_vni["resources"]
         if item["id"] == "container:dci-x05-peer-2/linux-vxlan/vxlan-x05-pr")[
             "desired"]["vni"] = 50100
    cases.append(peer_vni)
    fixture = copy.deepcopy(original)
    next(item for item in fixture["resources"]
         if item["id"] == "container:ovn-gw-1/frr-config-delta//etc/frr/frr.conf:ovnvrf300")[
             "desired"]["base_fixture"] = "frr-w-1.conf"
    cases.append(fixture)
    fixture_hash = copy.deepcopy(original)
    next(item for item in fixture_hash["resources"]
         if item["id"] == "container:ovn-gw-1/frr-config-delta//etc/frr/frr.conf:ovnvrf300")[
             "desired"]["add_fixture_sha256"] = "0" * 64
    cases.append(fixture_hash)
    runtime_fixture_hash = copy.deepcopy(original)
    next(item for item in runtime_fixture_hash["resources"]
         if item["id"] == "container:ovn-chassis-2/frr-pathspace/x05")[
             "desired"]["fixture_sha256"] = "0" * 64
    cases.append(runtime_fixture_hash)
    order = copy.deepcopy(original)
    next(item for item in order["resources"]
         if item["id"] == "host:vm-cilium/docker-container/dci-x05-peer-2")[
             "rollback_stage"] = 45
    order["rollback_order"] = [item["id"] for item in sorted(
        order["resources"], key=lambda item: (item["rollback_stage"], item["id"]))]
    cases.append(order)
    if any(not validate(case) for case in cases):
        print("X05 runtime selftest FAIL: damaged plan accepted", file=sys.stderr)
        return 1
    print("X05 runtime selftest PASS: identity, VNI, fixture, ownership and rollback mutations rejected")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    options = parser.add_mutually_exclusive_group(required=True)
    options.add_argument("--plan", action="store_true")
    options.add_argument("--check", action="store_true")
    options.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    plan = build_plan()
    errors = validate(plan)
    if errors:
        for error in errors:
            print(f"X05 runtime plan FAIL: {error}", file=sys.stderr)
        return 1
    if args.plan:
        json.dump(plan, sys.stdout, indent=2)
        print()
    else:
        print(f"X05 runtime plan PASS: {len(plan['resources'])} resources; local only")
    return 0


if __name__ == "__main__":
    sys.exit(main())
