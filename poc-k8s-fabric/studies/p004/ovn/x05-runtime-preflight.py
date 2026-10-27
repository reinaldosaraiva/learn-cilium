#!/usr/bin/env python3
"""Validate a pure-local X05 runtime admission snapshot.

The checker consumes observations only.  It never contacts Docker, OVN, OVS,
SSH, a lab host, or a network.  A fixture is useful to exercise the checker,
but is deliberately rejected by the normal ``--check`` path.  A PASS proves
only serialized schema and digest consistency; mutation authority exists only
in a live ``AdmissionSession.consume(PreparedAdmission)`` call.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import stat
from typing import Any


HERE = pathlib.Path(__file__).resolve().parent
RUNTIME_PLAN = HERE / "x05-runtime-plan.py"
SCHEMA = "p004-x05-runtime-preflight-v1"
M03_TOKEN_RE = re.compile(r"^labctl-m03-[^\s]+$")
M03_RUN_RE = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9]+$")
RUN_HEX_RE = re.compile(r"^[0-9a-f]{6}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
DOCKER_ID_RE = re.compile(r"^[0-9a-f]{64}$")
DOCKER_IMAGE_ID_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$")
EXPECTED_LOCAL_IP = "50100-170.168.0.6"
CLUSTER_NAMES = (
    "ovn-central-az1",
    "ovn-gw-1",
    "ovn-gw-2",
    "ovn-chassis-1",
    "ovn-chassis-2",
)
FIXED_X05_DOCKER_NAMES = ("dci-client-2", "dci-x05-peer-2")
MUTABLE_IMAGE_TAGS = ("frrouting/frr:v8.4.1", "ovn/ovn-multi-node:latest")
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
REQUIRED_SECTIONS = (
    "m03",
    "dci",
    "docker",
    "gateway_frr",
    "chassis2",
    "inventory",
    "evidence",
)
TOP_LEVEL_KEYS = {
    "schema",
    "mode",
    "status",
    "errors",
    "run_hex",
    "owner",
    "evidence_path",
    "runtime_plan_sha256",
    "snapshot_sha256",
    "sections",
    "before",
    "x05_marker",
    "journal_seed",
}
M03_RESOURCE_LINES = (
    "chassis:br-evpn-tenant:bridge",
    "chassis:vxlan-tenant:vxlan",
    "chassis:evpn-tenant:dummy",
    "peer:vrf-evpn-client:vrf",
    "peer:br-evpn-client:bridge",
    "peer:vxlan-m03-peer:vxlan",
    "peer:evpn-client:dummy",
)
M03_LINKS = (
    ("br-evpn-tenant", "bridge", "chassis", "ovn-chassis-1", None),
    ("vxlan-tenant", "vxlan", "chassis", "ovn-chassis-1", ("vni", 50100)),
    ("evpn-tenant", "dummy", "chassis", "ovn-chassis-1", None),
    ("vrf-evpn-client", "vrf", "peer", "dci-evpn-client-1", ("table", 50100)),
    ("br-evpn-client", "bridge", "peer", "dci-evpn-client-1", None),
    ("vxlan-m03-peer", "vxlan", "peer", "dci-evpn-client-1", ("vni", 50100)),
    ("evpn-client", "dummy", "peer", "dci-evpn-client-1", None),
)
DCI_ID_KEYS = {
    "ovn-central-az1": "owner_id_ovn_central_az1",
    "ovn-gw-1": "owner_id_ovn_gw_1",
    "ovn-gw-2": "owner_id_ovn_gw_2",
    "ovn-chassis-1": "owner_id_ovn_chassis_1",
    "ovn-chassis-2": "owner_id_ovn_chassis_2",
    "dci-client-1": "client_id_dci_client_1",
}
DCI_CONTAINER_NAMES = (*CLUSTER_NAMES, "dci-client-1")
ORIGINAL_OWNERSHIP_LABELS = frozenset(
    {"labctl.dci.owner", "labctl-m03-owner", "labctl-x05-owner"}
)
DCI_BRIDGE_ID_KEYS = {
    "br-ovn": "owner_bridge_br_ovn_uuid",
    "br-ovn-ext": "owner_bridge_br_ovn_ext_uuid",
}
A_FRR_SCOPES = {
    "ovn-gw-1": [
        "ip prefix-list MG-FROM-CLIENT seq 10 permit 10.0.0.0/16",
        "ip prefix-list MG-TO-CLIENT seq 10 permit 192.168.100.0/24",
        "route-map MG-FROM-CLIENT permit 10",
        " match ip address prefix-list MG-FROM-CLIENT",
        "exit",
        "route-map MG-TO-CLIENT permit 10",
        " match ip address prefix-list MG-TO-CLIENT",
        "exit",
        "vrf ovnvrf100",
        "exit-vrf",
        "router bgp 100 vrf ovnvrf100",
        " bgp router-id 169.254.254.1",
        " no bgp enforce-first-as",
        " neighbor 169.254.254.2 remote-as 200",
        " neighbor 169.254.254.2 bfd",
        " address-family ipv4 unicast",
        "  network 192.168.100.0/24",
        "  redistribute connected",
        "  neighbor 169.254.254.2 route-map MG-FROM-CLIENT in",
        "  neighbor 169.254.254.2 route-map MG-TO-CLIENT out",
        " exit-address-family",
        " address-family l2vpn evpn",
        "  advertise-pip",
        " exit-address-family",
        "exit",
        "bfd",
        " peer 169.254.254.2 vrf ovnvrf100",
        "  transmit-interval 500",
        "  receive-interval 500",
        " exit",
        "exit",
    ],
    "ovn-gw-2": [
        "ip prefix-list MG-FROM-CLIENT seq 10 permit 10.0.0.0/16",
        "ip prefix-list MG-TO-CLIENT seq 10 permit 192.168.100.0/24",
        "route-map MG-FROM-CLIENT permit 10",
        " match ip address prefix-list MG-FROM-CLIENT",
        "exit",
        "route-map MG-TO-CLIENT permit 10",
        " match ip address prefix-list MG-TO-CLIENT",
        "exit",
        "vrf ovnvrf200",
        "exit-vrf",
        "router bgp 100 vrf ovnvrf200",
        " bgp router-id 169.254.254.5",
        " no bgp enforce-first-as",
        " neighbor 169.254.254.6 remote-as 200",
        " neighbor 169.254.254.6 bfd",
        " address-family ipv4 unicast",
        "  network 192.168.100.0/24",
        "  redistribute connected",
        "  neighbor 169.254.254.6 route-map MG-FROM-CLIENT in",
        "  neighbor 169.254.254.6 route-map MG-TO-CLIENT out",
        " exit-address-family",
        " address-family l2vpn evpn",
        "  advertise-pip",
        " exit-address-family",
        "exit",
        "bfd",
        " peer 169.254.254.6 vrf ovnvrf200",
        "  transmit-interval 500",
        "  receive-interval 500",
        " exit",
        "exit",
    ],
}

M03_LINK_MASTERS = {
    "br-evpn-tenant": "ovnvrf-tenant",
    "vxlan-tenant": "br-evpn-tenant",
    "evpn-tenant": "br-evpn-tenant",
    "vrf-evpn-client": None,
    "br-evpn-client": "vrf-evpn-client",
    "vxlan-m03-peer": "br-evpn-client",
    "evpn-client": "br-evpn-client",
}


class SnapshotError(ValueError):
    """The supplied snapshot cannot establish a safe preflight result."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SnapshotError(message)


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise SnapshotError("duplicate JSON key: " + key)
        result[key] = value
    return result


def parse_json(data: bytes | str, *, context: str) -> Any:
    """Parse JSON strictly, including duplicate keys and non-finite values."""
    if isinstance(data, bytes):
        try:
            data = data.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise SnapshotError(context + " is not UTF-8") from exc
    try:
        return json.loads(
            data,
            object_pairs_hook=_unique_object,
            parse_constant=lambda value: (_ for _ in ()).throw(
                SnapshotError(context + " contains non-finite JSON: " + value)
            ),
        )
    except json.JSONDecodeError as exc:
        raise SnapshotError(context + " is malformed JSON: " + str(exc)) from exc


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_hash(value: Any) -> str:
    encoded = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    )
    return sha256(encoded.encode("utf-8"))


def normalize_frr_running_config(text: str) -> list[str]:
    """Return the exact stable FRR subtree, excluding display wrappers."""
    require(
        "\x00" not in text and "\r" not in text and "\t" not in text,
        "FRR running configuration contains forbidden bytes",
    )
    ignored_exact = {"Building configuration...", "Current configuration:", "end"}
    ignored_prefixes = ("frr version ", "frr defaults ", "hostname ")
    normalized: list[str] = []
    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        stripped = line.strip()
        if (
            not stripped
            or stripped.startswith("!")
            or stripped in ignored_exact
            or stripped.startswith(ignored_prefixes)
        ):
            continue
        normalized.append(line)
    require(normalized, "FRR running configuration has no stable scope")
    return normalized


def contains_placeholder(value: Any) -> bool:
    if isinstance(value, str):
        return "<" in value or ">" in value
    if isinstance(value, list):
        return any(contains_placeholder(item) for item in value)
    if isinstance(value, dict):
        return any(contains_placeholder(item) for item in value.values())
    return False


def read_snapshot(path: pathlib.Path, *, required_uid: int = 0) -> Any:
    """Read one root/private snapshot with identity checks and no symlinks."""
    try:
        before = path.lstat()
    except OSError as exc:
        raise SnapshotError("snapshot is unavailable: " + str(path)) from exc
    require(
        not stat.S_ISLNK(before.st_mode) and stat.S_ISREG(before.st_mode),
        "snapshot must be a regular non-symlink file",
    )
    require(stat.S_IMODE(before.st_mode) == 0o600, "snapshot mode must be exactly 0600")
    require(before.st_uid == required_uid, "snapshot owner is wrong")
    require(before.st_size <= 8 * 1024 * 1024, "snapshot exceeds the bounded size")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
        try:
            opened = os.fstat(fd)
            require(
                stat.S_ISREG(opened.st_mode)
                and (opened.st_dev, opened.st_ino) == (before.st_dev, before.st_ino)
                and stat.S_IMODE(opened.st_mode) == 0o600
                and opened.st_uid == required_uid,
                "snapshot changed while opening",
            )
            data = bytearray()
            while len(data) <= 8 * 1024 * 1024:
                chunk = os.read(fd, min(65536, 8 * 1024 * 1024 + 1 - len(data)))
                if not chunk:
                    break
                data.extend(chunk)
        finally:
            os.close(fd)
    except OSError as exc:
        raise SnapshotError("snapshot cannot be read") from exc
    require(len(data) <= 8 * 1024 * 1024, "snapshot exceeds the bounded size")
    try:
        after = path.lstat()
    except OSError as exc:
        raise SnapshotError("snapshot changed while reading") from exc

    def identity(info: os.stat_result) -> tuple[int, ...]:
        return (
            info.st_dev,
            info.st_ino,
            info.st_size,
            info.st_mtime_ns,
            info.st_ctime_ns,
            info.st_mode,
            info.st_uid,
        )

    require(identity(after) == identity(before), "snapshot changed while reading")
    return parse_json(bytes(data), context="snapshot")


def sha256_file(filename: str) -> tuple[int, str]:
    path = HERE / filename
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise SnapshotError("canonical fixture is unavailable: " + filename) from exc
    return len(data), sha256(data)


def expected_identity(resource: dict[str, Any]) -> dict[str, Any]:
    return {
        key: resource.get(key, "") for key in ("id", "kind", "host", "parent", "name")
    }


def _load_plan(snapshot_context: dict[str, str] | None = None):
    """Load the frozen template or its concrete, run-bound materialization."""
    spec = importlib.util.spec_from_file_location(
        "x05_runtime_plan_manifest", RUNTIME_PLAN
    )
    if spec is None or spec.loader is None:
        raise SnapshotError("runtime plan cannot be loaded")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if snapshot_context is None:
        plan = module.build_plan()
    else:
        try:
            plan = module.materialize_plan(
                snapshot_context["run_hex"],
                snapshot_context["owner"],
                snapshot_context["evidence_path"],
                snapshot_context["profile_owner"],
            )
        except (AttributeError, TypeError, ValueError) as exc:
            raise SnapshotError(
                "runtime plan cannot be materialized: " + str(exc)
            ) from exc
    require(
        isinstance(plan, dict) and plan.get("schema") == "p004-x05-runtime-plan-v1",
        "runtime plan schema changed",
    )
    resources = plan.get("resources")
    require(
        isinstance(resources, list) and len(resources) == 43,
        "runtime plan must contain exactly 43 resources",
    )
    frozen_ids = getattr(module, "EXPECTED_RESOURCE_IDS", None)
    frozen_digest = getattr(module, "EXPECTED_RESOURCE_MANIFEST_SHA256", None)
    require(
        isinstance(frozen_ids, frozenset) and len(frozen_ids) == 43,
        "runtime plan frozen identity set is missing",
    )
    require(
        isinstance(frozen_digest, str)
        and SHA256_RE.fullmatch(frozen_digest) is not None,
        "runtime plan frozen digest is missing",
    )
    ids = [item.get("id") if isinstance(item, dict) else None for item in resources]
    require(
        all(isinstance(item, str) for item in ids) and len(set(ids)) == 43,
        "runtime plan contains duplicate or malformed identity",
    )
    if snapshot_context is None:
        require(
            set(ids) == set(frozen_ids),
            "runtime plan identities differ from frozen manifest",
        )
        manifest = json.dumps(resources, sort_keys=True, separators=(",", ":"))
        require(
            sha256(manifest.encode("utf-8")) == frozen_digest,
            "runtime plan fields differ from frozen manifest",
        )
    else:
        require(
            not contains_placeholder(resources),
            "materialized runtime inventory contains a placeholder",
        )
        template = module.build_plan()
        expected_ids = {
            module._replace_placeholders(
                item["id"],
                run_hex=snapshot_context["run_hex"],
                owner_token=snapshot_context["owner"],
                profile_owner=snapshot_context["profile_owner"],
                evidence_path=snapshot_context["evidence_path"],
            )
            for item in template["resources"]
        }
        require(
            set(ids) == expected_ids,
            "materialized runtime identities differ from frozen template",
        )
        manifest = json.dumps(resources, sort_keys=True, separators=(",", ":"))
        require(
            plan.get("runtime_plan_sha256") == sha256(manifest.encode("utf-8")),
            "runtime plan digest is not bound to concrete resources",
        )
        require(
            plan.get("resource_ids_sha256") == canonical_hash(sorted(ids)),
            "runtime plan identity digest is not bound",
        )
    return module, plan, {item["id"]: item for item in resources}


def load_expected_resources(
    context: dict[str, str] | None = None,
) -> dict[str, dict[str, Any]]:
    """Return the 43 frozen identities, optionally bound to a concrete run."""
    return _load_plan(context)[2]


def _marker_fields(raw: str) -> tuple[str, str, list[str]]:
    require(raw.endswith("\n"), "M03 marker must end with one newline")
    require(
        "\r" not in raw and "\x00" not in raw, "M03 marker contains forbidden bytes"
    )
    lines = raw.splitlines()
    require(len(lines) == 18, "M03 marker must contain exactly 18 lines")
    require(lines[0] == "version=2", "M03 marker version is not v2")
    fields: dict[str, str] = {}
    resources: list[str] = []
    for line in lines[1:]:
        if line.startswith("resource="):
            resources.append(line.removeprefix("resource="))
            continue
        require("=" in line, "M03 marker line is malformed")
        key, value = line.split("=", 1)
        require(key not in fields, "M03 marker repeats a key")
        fields[key] = value
    require(
        set(fields)
        == {
            "token",
            "run_token",
            "central",
            "lrp",
            "tenant_vrf",
            "intent",
            "baseline_lrp_maintain_vrf",
            "baseline_lrp_port_name",
            "baseline_chassis_port_mapping",
            "baseline_ls_dynamic_routing_vni",
        },
        "M03 marker scalar fields differ from v2",
    )
    require(
        fields["central"] == "ovn-central-az1"
        and fields["lrp"] == "lrp-dci-tenant"
        and fields["tenant_vrf"] == "ovnvrf-tenant"
        and fields["intent"] == "maintain-vrf"
        and fields["baseline_lrp_maintain_vrf"] == "absent"
        and fields["baseline_lrp_port_name"] == "absent"
        and fields["baseline_chassis_port_mapping"] == "absent"
        and fields["baseline_ls_dynamic_routing_vni"] == "50100",
        "M03 marker scalar values differ from v2",
    )
    require(
        resources == list(M03_RESOURCE_LINES),
        "M03 marker resource identities differ from v2",
    )
    token = fields["token"]
    run_token = fields["run_token"]
    require(
        M03_TOKEN_RE.fullmatch(token) is not None
        and M03_RUN_RE.fullmatch(run_token) is not None
        and token == "labctl-m03-" + run_token,
        "M03 marker token/run binding is invalid",
    )
    return token, run_token, resources


def _validate_linux_identity(
    row: Any, *, name: str, kind: str, node: str, master: str | None
) -> str:
    require(isinstance(row, dict), "M03 Linux identity is missing: " + name)
    require(
        row.get("name") == name
        and row.get("kind") == kind
        and row.get("node") == node
        and row.get("master") == master
        and isinstance(row.get("ifindex"), int)
        and row["ifindex"] > 0
        and isinstance(row.get("iflink"), int)
        and row["iflink"] > 0
        and isinstance(row.get("link_type"), str)
        and row["link_type"],
        "M03 Linux identity is incomplete: " + name,
    )
    namespace = row.get("namespace")
    require(
        isinstance(namespace, dict)
        and set(namespace) == {"container", "container_id"}
        and namespace.get("container") == node
        and isinstance(namespace.get("container_id"), str)
        and DOCKER_ID_RE.fullmatch(namespace["container_id"]) is not None,
        "M03 Linux namespace identity is incomplete: " + name,
    )
    return namespace["container_id"]


def validate_marker(section: Any, profile_owner: str) -> tuple[str, str, str]:
    """Validate the complete M03 schema and derive identity from raw bytes."""
    require(
        isinstance(section, dict)
        and set(section)
        == {
            "status",
            "owner_token",
            "profile_owner",
            "marker",
            "peer",
            "return_filter",
            "links",
            "frr_pathspace",
            "tenant_vrf",
            "a_fingerprint",
        }
        and section.get("status") == "PASS",
        "M03 section schema is incomplete",
    )
    marker = section.get("marker")
    require(
        isinstance(marker, dict)
        and set(marker)
        == {
            "active",
            "valid",
            "mode",
            "uid",
            "raw",
            "bytes",
            "sha256",
            "owner",
            "token",
            "run_token",
        },
        "M03 marker observation schema is incomplete",
    )
    raw = marker.get("raw")
    require(isinstance(raw, str), "M03 marker raw bytes are missing")
    raw_bytes = raw.encode("utf-8")
    token, run_token, _ = _marker_fields(raw)
    digest = sha256(raw_bytes)
    require(
        marker.get("bytes") == len(raw_bytes) and marker.get("sha256") == digest,
        "M03 marker digest is not recomputed from raw bytes",
    )
    require(
        marker.get("mode") == 0o600
        and marker.get("uid") == 0
        and marker.get("active") is True
        and marker.get("valid") is True,
        "M03 marker is not an active root-owned 0600 file",
    )
    require(
        marker.get("token") == token
        and marker.get("run_token") == run_token
        and marker.get("owner") == token
        and section.get("owner_token") == token
        and section.get("profile_owner") == profile_owner,
        "M03 ownership metadata is not bound to raw marker bytes",
    )

    peer = section.get("peer")
    require(
        isinstance(peer, dict)
        and set(peer)
        == {
            "name",
            "id",
            "state",
            "labels",
            "ovs",
        }
        and peer.get("name") == "dci-evpn-client-1"
        and peer.get("state") == "running"
        and isinstance(peer.get("id"), str)
        and DOCKER_ID_RE.fullmatch(peer["id"]) is not None,
        "M03 peer identity is missing",
    )
    labels = peer.get("labels")
    require(
        labels == {"labctl.dci.owner": profile_owner, "labctl-m03-owner": token},
        "M03 peer labels are not bound to DCI and marker owners",
    )
    ovs = peer.get("ovs")
    require(
        isinstance(ovs, dict)
        and set(ovs)
        == {
            "container_id",
            "container_iface",
            "owner",
            "bridge",
            "bridge_uuid",
            "port_name",
            "port_uuid",
            "interface_name",
            "interface_uuid",
            "port_interfaces",
        }
        and ovs.get("container_id") == "dci-evpn-client-1"
        and ovs.get("container_iface") == "eth1"
        and ovs.get("owner") == token
        and ovs.get("bridge") == "br-ovn"
        and all(
            isinstance(ovs.get(key), str) and UUID_RE.fullmatch(ovs[key]) is not None
            for key in ("bridge_uuid", "port_uuid", "interface_uuid")
        )
        and isinstance(ovs.get("port_name"), str)
        and ovs["port_name"]
        and isinstance(ovs.get("interface_name"), str)
        and ovs["interface_name"]
        and ovs.get("port_interfaces") == [ovs.get("interface_uuid")],
        "M03 peer OVS Port/Interface membership is not bound",
    )

    filter_row = section.get("return_filter")
    expected_filter = f"m03-evpn-{run_token}"
    require(
        isinstance(filter_row, dict)
        and set(filter_row)
        == {
            "port_name",
            "lrp",
            "dynamic-routing-port-name",
            "mapping",
        }
        and filter_row.get("port_name") == expected_filter
        and filter_row.get("lrp") == "lrp-dci-tenant"
        and filter_row.get("dynamic-routing-port-name") == expected_filter
        and filter_row.get("mapping") == expected_filter + "=br-evpn-tenant",
        "M03 return filter is not bound to marker",
    )

    links = section.get("links")
    require(
        isinstance(links, list) and len(links) == len(M03_LINKS),
        "M03 peer link observations are incomplete",
    )
    by_name = {row.get("name"): row for row in links if isinstance(row, dict)}
    require(
        len(by_name) == len(links) and set(by_name) == {row[0] for row in M03_LINKS},
        "M03 peer link names differ from marker resources",
    )
    base_keys = {
        "name",
        "kind",
        "role",
        "node",
        "alias",
        "ifindex",
        "iflink",
        "master",
        "link_type",
        "namespace",
    }
    for name, kind, role, node, typed_value in M03_LINKS:
        row = by_name[name]
        expected_keys = set(base_keys)
        if typed_value is not None:
            expected_keys.add(typed_value[0])
        require(
            set(row) == expected_keys
            and row.get("role") == role
            and row.get("alias") == f"labctl-m03-{run_token}",
            "M03 link schema, alias, or role drifted: " + name,
        )
        _validate_linux_identity(
            row, name=name, kind=kind, node=node, master=M03_LINK_MASTERS[name]
        )
        if typed_value is not None:
            field, expected = typed_value
            require(
                row.get(field) == expected, "M03 link typed identity drifted: " + name
            )

    pathspace = section.get("frr_pathspace")
    require(
        isinstance(pathspace, dict)
        and set(pathspace)
        == {
            "node",
            "config_dir",
            "run_dir",
            "active",
            "owner_token",
            "daemons",
        }
        and pathspace.get("node") == "ovn-chassis-1"
        and pathspace.get("config_dir") == "/etc/frr/m03"
        and pathspace.get("run_dir") == "/run/frr/m03"
        and pathspace.get("active") is True
        and pathspace.get("owner_token") == token,
        "M03 FRR pathspace is not bound to marker",
    )
    daemons = pathspace.get("daemons")
    require(
        isinstance(daemons, list) and len(daemons) == 3,
        "M03 FRR daemon identities are incomplete",
    )
    daemon_names: set[str] = set()
    daemon_pids: set[int] = set()
    for daemon in daemons:
        require(
            isinstance(daemon, dict)
            and set(daemon)
            == {
                "daemon",
                "pid",
                "start_time_ticks",
                "cmdline",
            }
            and daemon.get("daemon") in {"zebra", "bgpd", "staticd"}
            and isinstance(daemon.get("pid"), int)
            and daemon["pid"] > 0
            and isinstance(daemon.get("start_time_ticks"), int)
            and daemon["start_time_ticks"] > 0
            and isinstance(daemon.get("cmdline"), str)
            and ("-N m03" in daemon["cmdline"] or "/run/frr/m03" in daemon["cmdline"]),
            "M03 FRR daemon identity is malformed",
        )
        daemon_names.add(daemon["daemon"])
        daemon_pids.add(daemon["pid"])
    require(
        daemon_names == {"zebra", "bgpd", "staticd"} and len(daemon_pids) == 3,
        "M03 FRR daemon identities are duplicated or incomplete",
    )

    tenant = section.get("tenant_vrf")
    require(
        isinstance(tenant, dict)
        and set(tenant)
        == {
            "name",
            "kind",
            "table",
            "alias",
            "node",
            "ifindex",
            "iflink",
            "master",
            "link_type",
            "namespace",
        }
        and tenant.get("table") == 300
        and tenant.get("alias") is None,
        "M03 tenant VRF schema is incomplete",
    )
    _validate_linux_identity(
        tenant,
        name="ovnvrf-tenant",
        kind="vrf",
        node="ovn-chassis-1",
        master=None,
    )

    fingerprint = section.get("a_fingerprint")
    require(
        isinstance(fingerprint, dict)
        and set(fingerprint)
        == {
            "Logical_Switch",
            "Logical_Router",
            "Logical_Router_Port",
        },
        "M03 A fingerprint is incomplete",
    )
    switch = fingerprint["Logical_Switch"]
    router = fingerprint["Logical_Router"]
    lrp = fingerprint["Logical_Router_Port"]
    require(
        isinstance(switch, dict)
        and set(switch)
        == {
            "_uuid",
            "name",
            "ports",
            "other_config",
        }
        and switch.get("name") == "ls-dci-tenant"
        and switch.get("other_config") == {"dynamic-routing-vni": "50100"},
        "M03 A logical switch fingerprint is incomplete",
    )
    require(
        isinstance(router, dict)
        and set(router) == {"_uuid", "name", "ports"}
        and router.get("name") == "lr-dci-tenant",
        "M03 A logical router fingerprint is incomplete",
    )
    require(
        isinstance(lrp, dict)
        and set(lrp) == {"_uuid", "name", "options"}
        and lrp.get("name") == "lrp-dci-tenant"
        and lrp.get("options")
        == {
            "dynamic-routing-maintain-vrf": "true",
            "dynamic-routing-port-name": expected_filter,
        },
        "M03 A router port fingerprint is incomplete",
    )
    for row in (switch, router, lrp):
        require(
            isinstance(row.get("_uuid"), str)
            and UUID_RE.fullmatch(row["_uuid"]) is not None,
            "M03 A fingerprint UUID is malformed",
        )
    for row in (switch, router):
        require(
            isinstance(row.get("ports"), list)
            and row["ports"]
            and len(row["ports"]) == len(set(row["ports"]))
            and all(
                isinstance(value, str) and UUID_RE.fullmatch(value) is not None
                for value in row["ports"]
            ),
            "M03 A fingerprint port set is malformed",
        )
    require(
        lrp["_uuid"] in router["ports"], "M03 A router fingerprint omits the tenant LRP"
    )
    return token, run_token, digest


def validate_dci(section: Any) -> str:
    """Validate recorded IDs, observed IDs, labels, bridges, and ownership."""
    require(
        isinstance(section, dict) and section.get("status") == "PASS",
        "DCI ownership section is not PASS",
    )
    owner = section.get("profile_owner")
    require(
        isinstance(owner, str) and owner and "<" not in owner,
        "DCI profile owner is missing",
    )
    require(
        section.get("expected_cluster_names") == list(CLUSTER_NAMES),
        "DCI expected cluster names are incomplete",
    )
    require(
        section.get("foreign_names") == [], "foreign DCI container name was observed"
    )
    ids = section.get("container_ids")
    recorded = section.get("recorded_ids")
    require(
        isinstance(ids, dict) and set(ids) == set(DCI_CONTAINER_NAMES),
        "DCI observed container IDs are incomplete",
    )
    require(
        isinstance(recorded, dict) and set(recorded) == set(DCI_ID_KEYS.values()),
        "DCI recorded state IDs are incomplete",
    )
    for name, state_key in DCI_ID_KEYS.items():
        value = ids[name]
        require(
            isinstance(value, str)
            and DOCKER_ID_RE.fullmatch(value) is not None
            and value == recorded[state_key],
            "DCI observed ID does not equal recorded state ID: " + name,
        )
    require(len(set(ids.values())) == len(ids), "DCI observed IDs are duplicated")
    states = section.get("container_states")
    require(
        isinstance(states, dict)
        and set(states) == set(ids)
        and all(value == "running" for value in states.values()),
        "DCI containers are not all running",
    )
    labels = section.get("container_labels")
    require(
        isinstance(labels, dict) and set(labels) == set(ids),
        "DCI container labels are incomplete",
    )
    for name in DCI_CONTAINER_NAMES:
        row = labels[name]
        require(
            isinstance(row, dict)
            and all(isinstance(key, str) and isinstance(value, str) for key, value in row.items()),
            "DCI container labels are malformed: " + name,
        )
    image_bindings = section.get("original_image_bindings")
    require(
        isinstance(image_bindings, dict)
        and set(image_bindings) == set(CLUSTER_NAMES),
        "original image evidence is incomplete",
    )
    for name in CLUSTER_NAMES:
        binding = image_bindings[name]
        require(
            isinstance(binding, dict)
            and set(binding) == {"image_id", "image_labels"}
            and isinstance(binding.get("image_id"), str)
            and DOCKER_IMAGE_ID_RE.fullmatch(binding["image_id"]) is not None,
            "original image binding is malformed: " + name,
        )
        image_labels = binding["image_labels"]
        require(
            isinstance(image_labels, dict)
            and all(
                isinstance(key, str) and isinstance(value, str)
                for key, value in image_labels.items()
            ),
            "original image labels are malformed: " + name,
        )
        row = labels[name]
        require(
            row == image_labels,
            "original container labels do not equal image labels: " + name,
        )
        require(
            not ORIGINAL_OWNERSHIP_LABELS.intersection(image_labels)
            and not ORIGINAL_OWNERSHIP_LABELS.intersection(row),
            "original image carries an ownership label: " + name,
        )
    client_labels = labels["dci-client-1"]
    require(
        client_labels == {"labctl.dci.owner": owner},
        "DCI client profile label is missing",
    )

    bridge_ids = section.get("recorded_bridge_uuids")
    bridges = section.get("bridges")
    require(
        isinstance(bridge_ids, dict)
        and set(bridge_ids) == set(DCI_BRIDGE_ID_KEYS.values())
        and isinstance(bridges, dict)
        and set(bridges) == set(DCI_BRIDGE_ID_KEYS),
        "DCI bridge UUID records are incomplete",
    )
    for name, state_key in DCI_BRIDGE_ID_KEYS.items():
        row = bridges[name]
        require(
            isinstance(row, dict)
            and isinstance(row.get("uuid"), str)
            and UUID_RE.fullmatch(row["uuid"]) is not None
            and row["uuid"] == bridge_ids[state_key],
            "DCI bridge UUID does not equal recorded state UUID: " + name,
        )
        external_ids = row.get("external_ids")
        require(
            isinstance(external_ids, dict)
            and external_ids.get("labctl-dci-owner-token") == owner,
            "DCI bridge owner external-id is missing: " + name,
        )
    return owner


def validate_docker(
    section: Any, resources: dict[str, dict[str, Any]]
) -> tuple[dict[str, str], str]:
    require(
        isinstance(section, dict) and section.get("status") == "PASS",
        "Docker absence section is not PASS",
    )
    absent = section.get("names_absent")
    require(
        isinstance(absent, dict)
        and set(absent) == set(FIXED_X05_DOCKER_NAMES)
        and all(value is True for value in absent.values()),
        "fixed X05 Docker absence coverage is incomplete",
    )
    require(section.get("foreign_names") == [], "foreign X05 Docker name was observed")
    resolved = section.get("resolved_images")
    require(
        isinstance(resolved, dict) and set(resolved) == set(MUTABLE_IMAGE_TAGS),
        "resolved mutable image coverage is incomplete",
    )
    require(
        all(
            isinstance(value, str) and DOCKER_IMAGE_ID_RE.fullmatch(value) is not None
            for value in resolved.values()
        ),
        "resolved mutable image ID is not immutable",
    )
    require(
        len(set(resolved.values())) == len(MUTABLE_IMAGE_TAGS),
        "resolved mutable image IDs are unexpectedly identical",
    )
    planned_tags = {
        resource.get("desired", {}).get("image")
        for resource in resources.values()
        if resource.get("kind") == "docker-container"
    }
    require(
        planned_tags == set(MUTABLE_IMAGE_TAGS),
        "resolved image tags differ from the runtime inventory",
    )
    digest = canonical_hash(resolved)
    require(
        section.get("resolved_images_sha256") == digest,
        "resolved mutable image digest is not bound",
    )
    return resolved, digest


def validate_runtime_fixtures(resources: dict[str, dict[str, Any]]) -> None:
    """Cross-bind the three runtime FRR files to their inventory rows."""
    desired_by_fixture = {
        "x05-client2.conf": resources[
            "host:vm-cilium/docker-container/dci-client-2"
        ]["desired"],
        "x05-chassis.conf": resources[
            "container:ovn-chassis-2/frr-pathspace/x05"
        ]["desired"],
        "x05-peer.conf": resources[
            "container:dci-x05-peer-2/frr-pathspace/x05"
        ]["desired"],
    }
    for filename, expected in EXPECTED_RUNTIME_FIXTURES.items():
        actual = sha256_file(filename)
        require(actual == expected, "runtime fixture bytes/hash changed: " + filename)
        desired = desired_by_fixture[filename]
        if filename == "x05-client2.conf":
            require(
                desired.get("frr_fixture") == filename
                and desired.get("frr_fixture_bytes") == expected[0]
                and desired.get("frr_fixture_sha256") == expected[1],
                "client runtime fixture is not exactly bound in the plan",
            )
        else:
            require(
                desired.get("fixture") == filename
                and desired.get("fixture_bytes") == expected[0]
                and desired.get("fixture_sha256") == expected[1],
                "pathspace runtime fixture is not exactly bound in the plan: "
                + filename,
            )


def validate_gateway_frr(section: Any, resources: dict[str, dict[str, Any]]) -> None:
    require(
        isinstance(section, dict) and section.get("status") == "PASS",
        "gateway FRR section is not PASS",
    )
    gateways = section.get("gateways")
    require(
        isinstance(gateways, dict) and set(gateways) == {"ovn-gw-1", "ovn-gw-2"},
        "gateway FRR coverage is incomplete",
    )
    expected = {
        "ovn-gw-1": (
            "frr-gw1.conf",
            1030,
            "2838c8687b8d45dba49a3d6c488780cf8e3a00f281e5eb26c16d6fa7c6ebbbb7",
        ),
        "ovn-gw-2": (
            "frr-gw2.conf",
            964,
            "d464ddc249ae61a58a0df3058ae482d75ebb8e768ebd00c772e6a50fa5fee6c9",
        ),
    }
    frr_resources = {
        resource["host"].removeprefix("container:"): resource
        for resource in resources.values()
        if resource.get("kind") == "frr-config-delta"
    }
    require(
        set(frr_resources) == set(expected),
        "runtime plan FRR resource coverage is incomplete",
    )
    for node, (fixture, size, digest) in expected.items():
        row = gateways[node]
        require(
            isinstance(row, dict)
            and row.get("fixture") == fixture
            and row.get("bytes") == size
            and row.get("sha256") == digest
            and row.get("matches_fixture") is True
            and row.get("base_path") == "/etc/frr/frr.conf"
            and row.get("base_sha256") == digest
            and row.get("base_bytes") == size
            and row.get("base_matches") is True
            and row.get("extension_absent") is True
            and row.get("write_memory") is False
            and row.get("vtysh_b") is False,
            "gateway FRR base or command policy drifted: " + node,
        )
        require(
            row.get("a_scopes_before") == A_FRR_SCOPES[node],
            "gateway A FRR scopes are not the exact VRF/BGP/BFD set: " + node,
        )
        require(
            row.get("a_scopes_sha256") == canonical_hash(A_FRR_SCOPES[node]),
            "gateway A FRR scope digest is not bound: " + node,
        )
        require(
            isinstance(row.get("running_config_sha256"), str)
            and SHA256_RE.fullmatch(row["running_config_sha256"]) is not None,
            "gateway running configuration digest is missing: " + node,
        )
        desired = frr_resources[node].get("desired")
        require(
            isinstance(desired, dict), "gateway FRR plan fields are missing: " + node
        )
        for name_key, bytes_key, digest_key in (
            ("add_fixture", "add_fixture_bytes", "add_fixture_sha256"),
            ("remove_fixture", "remove_fixture_bytes", "remove_fixture_sha256"),
        ):
            filename = desired.get(name_key)
            require(
                isinstance(filename, str)
                and isinstance(desired.get(bytes_key), int)
                and isinstance(desired.get(digest_key), str),
                "gateway FRR extension binding is incomplete: " + node,
            )
            try:
                raw = (HERE / filename).read_bytes()
            except OSError as exc:
                raise SnapshotError(
                    "gateway FRR fixture is unavailable: " + filename
                ) from exc
            require(
                (len(raw), sha256(raw)) == (desired[bytes_key], desired[digest_key]),
                "gateway FRR extension bytes/hash changed: " + filename,
            )


def validate_chassis2(section: Any) -> None:
    require(
        isinstance(section, dict) and section.get("status") == "PASS",
        "chassis 2 section is not PASS",
    )
    require(
        section.get("dynamic-routing-port-mapping") in (None, "", "absent")
        and section.get("ovn-evpn-local-ip") == EXPECTED_LOCAL_IP,
        "chassis 2 baseline values drifted",
    )
    original = section.get("original_values")
    require(
        isinstance(original, dict)
        and original.get("dynamic-routing-port-mapping") in (None, "", "absent")
        and original.get("ovn-evpn-local-ip") == EXPECTED_LOCAL_IP,
        "chassis 2 original values are not exact",
    )


def validate_evidence(section: Any) -> None:
    require(
        isinstance(section, dict)
        and section.get("status") == "PASS"
        and section.get("path_absent") is True
        and section.get("capture_paths") == []
        and section.get("capture_processes") == [],
        "X05 evidence residue was observed",
    )


def validate_inventory(
    section: Any,
    resources: dict[str, dict[str, Any]],
    runtime_digest: str,
    ids_digest: str,
) -> None:
    require(
        isinstance(section, dict)
        and section.get("status") == "PASS"
        and section.get("count") == 43
        and section.get("gaps") == [],
        "runtime inventory is incomplete",
    )
    listed = section.get("resources")
    require(
        isinstance(listed, list)
        and set(listed) == set(resources)
        and len(listed) == 43
        and listed == sorted(listed),
        "runtime resource manifest coverage is incomplete",
    )
    require(
        section.get("runtime_plan_sha256") == runtime_digest
        and section.get("resource_ids_sha256") == ids_digest
        and section.get("all_absent") is True,
        "runtime inventory digest or absence proof is not bound",
    )
    generated = section.get("generated_vrfs")
    generated_ids = {
        key for key, row in resources.items() if row.get("kind") == "ovn-generated-vrf"
    }
    require(
        isinstance(generated, dict) and set(generated) == generated_ids,
        "OVN generated VRF observations are incomplete",
    )
    for resource_id, row in generated.items():
        require(
            isinstance(row, dict)
            and set(row)
            == {"exists", "observation_only", "generated_by", "direct_delete"}
            and row.get("exists") is False
            and row.get("observation_only") is True
            and row.get("generated_by") == "OVN"
            and row.get("direct_delete") is False,
            "generated VRF is not observation-only: " + resource_id,
        )


def validate_before(
    before: Any, resources: dict[str, dict[str, Any]], owner: str
) -> None:
    require(
        isinstance(before, dict) and set(before) == set(resources),
        "before-values do not cover exactly the 43 runtime identities",
    )
    baseline_ids = {
        resource_id
        for resource_id, resource in resources.items()
        if resource["kind"] == "ovs-external-id"
        and resource["name"] == "ovn-evpn-local-ip"
    }
    for resource_id, resource in resources.items():
        entry = before[resource_id]
        require(
            isinstance(entry, dict)
            and entry.get("identity") == expected_identity(resource)
            and entry.get("capture_fields") == resource["capture_before_mutation"],
            "before identity/capture drifted: " + resource_id,
        )
        ownership = entry.get("ownership")
        require(
            isinstance(ownership, dict)
            and ownership.get("owner") == owner
            and ownership.get("adopt_existing") is False,
            "before identity permits adoption: " + resource_id,
        )
        state = entry.get("state")
        require(
            state in {"absent", "absent-parent", "baseline"},
            "before state is ambiguous: " + resource_id,
        )
        observed = entry.get("observed")
        require(
            isinstance(observed, dict)
            and observed.get("identity") == expected_identity(resource)
            and observed.get("parent") == resource.get("parent")
            and type(observed.get("exists")) is bool,
            "before observation is incomplete: " + resource_id,
        )
        require(
            (observed["exists"] is False and state != "baseline")
            or (observed["exists"] is True and state == "baseline"),
            "before observation does not prove the recorded state: " + resource_id,
        )
        if resource["kind"] == "frr-config-delta":
            require(state == "baseline", "gateway FRR baseline is not captured")
            fixture = resource["desired"]["base_fixture"]
            size, digest = sha256_file(fixture)
            require(
                observed.get("fixture") == fixture
                and observed.get("bytes") == size
                and observed.get("sha256") == digest
                and observed.get("matches_fixture") is True
                and observed.get("extension_absent") is True
                and observed.get("a_scopes_before")
                == A_FRR_SCOPES[
                    "ovn-gw-1" if "ovn-gw-1" in resource_id else "ovn-gw-2"
                ],
                "gateway FRR before-value is not exact: " + resource_id,
            )
        elif resource_id in baseline_ids:
            require(
                state == "baseline"
                and observed.get("key") == "ovn-evpn-local-ip"
                and observed.get("value") == EXPECTED_LOCAL_IP,
                "chassis 2 local-ip before-value is not exact",
            )
        else:
            require(
                state in {"absent", "absent-parent"},
                "X05 identity was not absent: " + resource_id,
            )
        if resource["kind"] == "ovn-generated-vrf":
            require(
                resource.get("observation_only") is True
                and observed.get("generated_by") == "OVN"
                and observed.get("direct_delete") is False
                and observed.get("exists") is False,
                "generated VRF before-state is not observation-only",
            )
        if resource["kind"] == "frr-pathspace":
            require(
                observed.get("path_absent") is True,
                "FRR pathspace residue was not ruled out",
            )
        if resource["kind"] == "ovs-external-id":
            require(
                isinstance(observed.get("ovs_uuid"), str)
                and UUID_RE.fullmatch(observed["ovs_uuid"]) is not None,
                "OVS external-id UUID is invalid",
            )
        if resource["kind"] == "docker-container":
            require(
                observed.get("name") == resource["name"]
                and observed.get("exists") is False,
                "X05 Docker identity was not absent",
            )
        if resource["kind"] in {
            "linux-veth",
            "linux-vrf",
            "linux-bridge",
            "linux-vxlan",
            "linux-dummy",
            "ovn-generated-vrf",
            "netns",
            "ovs-port-interface",
        }:
            require(
                observed.get("exists") is False,
                "Linux/OVS/netns identity was not absent",
            )
        if resource["kind"] == "ovs-port-interface":
            require(
                isinstance(observed.get("parent_bridge_uuid"), str)
                and UUID_RE.fullmatch(observed["parent_bridge_uuid"]) is not None
                and isinstance(observed.get("parent_bridge_ports"), list)
                and all(
                    isinstance(value, str) and UUID_RE.fullmatch(value) is not None
                    for value in observed["parent_bridge_ports"]
                )
                and observed.get("interface_matches") == []
                and observed.get("port_matches") == [],
                "OVS Port/Interface absence is not bound to its parent bridge",
            )
        if resource["kind"] == "lsp-parent-control":
            require(observed.get("b_lsp_absent") is True, "control LSP was not absent")
        if resource["kind"] in {"capture-file", "capture-processes"}:
            require(
                observed.get("path_absent") is True,
                "capture identity path was not absent",
            )


def snapshot_digest(snapshot: dict[str, Any]) -> str:
    core = {
        key: value
        for key, value in snapshot.items()
        if key not in {"snapshot_sha256", "journal_seed"}
    }
    return canonical_hash(core)


def validate_snapshot(snapshot: Any, *, allow_fixture: bool = False) -> dict[str, Any]:
    """Validate one complete, run-bound snapshot and return a PASS report."""
    require(
        isinstance(snapshot, dict) and set(snapshot) == TOP_LEVEL_KEYS,
        "snapshot top-level schema is invalid",
    )
    require(
        snapshot.get("schema") == SCHEMA
        and snapshot.get("status") == "PASS"
        and snapshot.get("errors") == [],
        "snapshot status or schema is invalid",
    )
    require(
        snapshot.get("mode") == "live-observed"
        or (allow_fixture and snapshot.get("mode") == "fixture"),
        "fixture snapshots are not admitted",
    )
    run_hex = snapshot.get("run_hex")
    owner = snapshot.get("owner")
    evidence_path = snapshot.get("evidence_path")
    require(
        isinstance(run_hex, str) and RUN_HEX_RE.fullmatch(run_hex) is not None,
        "run_hex is not exactly six lowercase hexadecimal characters",
    )
    require(owner == "labctl-x05-" + run_hex, "X05 owner is not bound to run_hex")
    require(
        isinstance(evidence_path, str) and evidence_path.startswith("/"),
        "evidence path is not absolute",
    )
    path = pathlib.PurePosixPath(evidence_path)
    require(
        str(path) == evidence_path
        and all(part not in {"", ".", ".."} for part in path.parts),
        "evidence path is not canonical",
    )
    require(
        path.parts[-5:] == ("evidence", "P004", "S002", run_hex, "08-x05"),
        "evidence path is not the canonical P004/S002 run path",
    )
    runtime_digest = snapshot.get("runtime_plan_sha256")
    snapshot_sha = snapshot.get("snapshot_sha256")
    require(
        isinstance(runtime_digest, str)
        and SHA256_RE.fullmatch(runtime_digest) is not None
        and isinstance(snapshot_sha, str)
        and SHA256_RE.fullmatch(snapshot_sha) is not None,
        "snapshot or runtime plan digest is missing",
    )
    sections = snapshot.get("sections")
    require(
        isinstance(sections, dict) and set(sections) == set(REQUIRED_SECTIONS),
        "snapshot sections are incomplete",
    )
    for name in REQUIRED_SECTIONS:
        require(
            isinstance(sections[name], dict) and sections[name].get("status") == "PASS",
            "snapshot section is not PASS: " + name,
        )

    profile_owner = sections["dci"].get("profile_owner")
    require(isinstance(profile_owner, str), "DCI profile owner is missing")
    context = {
        "run_hex": run_hex,
        "owner": owner,
        "evidence_path": evidence_path,
        "profile_owner": profile_owner,
    }
    _, plan, resources = _load_plan(context)
    require(
        plan.get("runtime_plan_sha256") == runtime_digest,
        "snapshot runtime plan digest does not match materialized plan",
    )
    ids_digest = plan["resource_ids_sha256"]
    marker_token, marker_run, marker_digest = validate_marker(
        sections["m03"], profile_owner
    )
    validate_dci(sections["dci"])
    require(
        sections["m03"].get("profile_owner") == profile_owner,
        "M03 profile owner does not match DCI owner",
    )
    resolved_images, resolved_images_digest = validate_docker(
        sections["docker"], resources
    )
    validate_runtime_fixtures(resources)
    validate_gateway_frr(sections["gateway_frr"], resources)
    validate_chassis2(sections["chassis2"])
    validate_inventory(sections["inventory"], resources, runtime_digest, ids_digest)
    validate_evidence(sections["evidence"])
    validate_before(snapshot["before"], resources, owner)
    expected_namespaces = {
        **sections["dci"]["container_ids"],
        "dci-evpn-client-1": sections["m03"]["peer"]["id"],
    }
    for row in [*sections["m03"]["links"], sections["m03"]["tenant_vrf"]]:
        namespace = row["namespace"]
        require(
            namespace["container_id"] == expected_namespaces[namespace["container"]],
            "M03 Linux namespace ID differs from the recorded DCI ID: " + row["name"],
        )
    x05_marker = snapshot["x05_marker"]
    require(
        isinstance(x05_marker, dict)
        and set(x05_marker) == {"path", "exists"}
        and x05_marker.get("path") == "/run/labctl/dci-x05/active"
        and x05_marker.get("exists") is False,
        "X05 marker must be absent before preflight",
    )
    journal = snapshot["journal_seed"]
    require(
        isinstance(journal, dict)
        and set(journal)
        == {
            "schema",
            "run_hex",
            "owner",
            "evidence_path",
            "runtime_plan_sha256",
            "snapshot_sha256",
            "m03_marker_sha256",
            "m03_owner_token",
            "m03_run_token",
            "resource_count",
            "resource_ids_sha256",
            "resolved_images",
            "resolved_images_sha256",
        },
        "journal seed schema is incomplete",
    )
    require(
        journal
        == {
            "schema": "p004-x05-runtime-journal-seed-v1",
            "run_hex": run_hex,
            "owner": owner,
            "evidence_path": evidence_path,
            "runtime_plan_sha256": runtime_digest,
            "snapshot_sha256": snapshot_sha,
            "m03_marker_sha256": marker_digest,
            "m03_owner_token": marker_token,
            "m03_run_token": marker_run,
            "resource_count": 43,
            "resource_ids_sha256": ids_digest,
            "resolved_images": resolved_images,
            "resolved_images_sha256": resolved_images_digest,
        },
        "journal seed is not bound to all snapshot identities and digests",
    )
    require(
        snapshot_sha == snapshot_digest(snapshot),
        "snapshot digest does not cover the bound source snapshot",
    )
    return {
        "schema": SCHEMA,
        "status": "PASS",
        "mode": "schema-check",
        "authorizes_mutation": False,
        "run_hex": run_hex,
        "owner": owner,
        "runtime_plan_sha256": runtime_digest,
        "snapshot_sha256": snapshot_sha,
        "resources": 43,
    }


def _fixture_uuid(name: str) -> str:
    digest = sha256(name.encode("utf-8"))
    return (
        digest[:8]
        + "-"
        + digest[8:12]
        + "-"
        + digest[12:16]
        + "-"
        + digest[16:20]
        + "-"
        + digest[20:32]
    )


def synthetic_fixture() -> dict[str, Any]:
    """Build a deterministic non-admission fixture for local selftests."""
    run_hex = "a1b2c3"
    owner = "labctl-x05-" + run_hex
    evidence_path = f"/workspace/evidence/P004/S002/{run_hex}/08-x05"
    profile_owner = "dci-profile-fixture"
    context = {
        "run_hex": run_hex,
        "owner": owner,
        "evidence_path": evidence_path,
        "profile_owner": profile_owner,
    }
    _, plan, resources = _load_plan(context)

    marker_run = "20260101T000000Z-1"
    marker_token = "labctl-m03-" + marker_run
    marker_lines = [
        "version=2",
        f"token={marker_token}",
        f"run_token={marker_run}",
        "central=ovn-central-az1",
        "lrp=lrp-dci-tenant",
        "tenant_vrf=ovnvrf-tenant",
        "intent=maintain-vrf",
        "baseline_lrp_maintain_vrf=absent",
        "baseline_lrp_port_name=absent",
        "baseline_chassis_port_mapping=absent",
        "baseline_ls_dynamic_routing_vni=50100",
        *("resource=" + value for value in M03_RESOURCE_LINES),
    ]
    marker_raw = "\n".join(marker_lines) + "\n"
    marker_digest = sha256(marker_raw.encode("utf-8"))
    container_ids = {
        name: sha256(("dci:" + name).encode("utf-8")) for name in DCI_CONTAINER_NAMES
    }
    original_image_id = "sha256:" + sha256(b"fixture-original-image")
    original_image_labels = {
        "org.example.base": "fixture",
        "org.example.version": "1",
    }
    peer_id = sha256(b"m03-peer")
    namespace_ids = {**container_ids, "dci-evpn-client-1": peer_id}

    before: dict[str, Any] = {}
    for resource_id, resource in resources.items():
        observed: dict[str, Any] = {"exists": False}
        state = "absent"
        if resource["kind"] == "frr-config-delta":
            fixture = resource["desired"]["base_fixture"]
            size, digest = sha256_file(fixture)
            gateway = resource["host"].removeprefix("container:")
            state = "baseline"
            observed.update(
                {
                    "exists": True,
                    "fixture": fixture,
                    "bytes": size,
                    "sha256": digest,
                    "matches_fixture": True,
                    "extension_absent": True,
                    "a_scopes_before": list(A_FRR_SCOPES[gateway]),
                }
            )
        elif (
            resource["kind"] == "ovs-external-id"
            and resource["name"] == "ovn-evpn-local-ip"
        ):
            state = "baseline"
            observed.update(
                {
                    "exists": True,
                    "key": resource["name"],
                    "value": EXPECTED_LOCAL_IP,
                    "ovs_uuid": _fixture_uuid(resource_id),
                }
            )
        elif resource["kind"] == "ovs-external-id":
            observed["ovs_uuid"] = _fixture_uuid(resource_id)
        elif resource["kind"] == "docker-container":
            observed["name"] = resource["name"]
        elif resource["kind"] == "lsp-parent-control":
            observed["b_lsp_absent"] = True
        elif resource["kind"] == "frr-pathspace":
            observed["path_absent"] = True
        elif resource["kind"] in {"capture-file", "capture-processes"}:
            observed["path_absent"] = True
        elif resource["kind"] == "ovn-generated-vrf":
            observed.update({"generated_by": "OVN", "direct_delete": False})
        if resource["kind"] == "ovs-port-interface":
            observed.update(
                {
                    "parent_bridge_uuid": _fixture_uuid("parent:" + resource_id),
                    "parent_bridge_ports": [],
                    "interface_matches": [],
                    "port_matches": [],
                }
            )
        observed["identity"] = expected_identity(resource)
        observed["parent"] = resource.get("parent")
        before[resource_id] = {
            "identity": expected_identity(resource),
            "ownership": {"owner": owner, "adopt_existing": False},
            "capture_fields": list(resource["capture_before_mutation"]),
            "state": state,
            "observed": observed,
        }

    recorded_ids = {
        DCI_ID_KEYS[name]: container_ids[name] for name in DCI_CONTAINER_NAMES
    }
    bridges = {
        name: {
            "uuid": _fixture_uuid(name),
            "external_ids": {"labctl-dci-owner-token": profile_owner},
        }
        for name in DCI_BRIDGE_ID_KEYS
    }
    recorded_bridges = {
        DCI_BRIDGE_ID_KEYS[name]: bridges[name]["uuid"] for name in DCI_BRIDGE_ID_KEYS
    }
    m03 = {
        "status": "PASS",
        "owner_token": marker_token,
        "profile_owner": profile_owner,
        "marker": {
            "active": True,
            "valid": True,
            "owner": marker_token,
            "token": marker_token,
            "run_token": marker_run,
            "mode": 0o600,
            "uid": 0,
            "raw": marker_raw,
            "bytes": len(marker_raw.encode("utf-8")),
            "sha256": marker_digest,
        },
        "peer": {
            "name": "dci-evpn-client-1",
            "id": peer_id,
            "state": "running",
            "labels": {
                "labctl.dci.owner": profile_owner,
                "labctl-m03-owner": marker_token,
            },
            "ovs": {
                "container_id": "dci-evpn-client-1",
                "container_iface": "eth1",
                "owner": marker_token,
                "bridge": "br-ovn",
                "bridge_uuid": _fixture_uuid("m03-host-bridge"),
                "port_name": "veth-m03-host",
                "port_uuid": _fixture_uuid("m03-host-port"),
                "interface_name": "veth-m03-host",
                "interface_uuid": _fixture_uuid("m03-host-interface"),
                "port_interfaces": [_fixture_uuid("m03-host-interface")],
            },
        },
        "return_filter": {
            "port_name": f"m03-evpn-{marker_run}",
            "lrp": "lrp-dci-tenant",
            "dynamic-routing-port-name": f"m03-evpn-{marker_run}",
            "mapping": f"m03-evpn-{marker_run}=br-evpn-tenant",
        },
        "links": [
            {
                "name": name,
                "kind": kind,
                "role": role,
                "node": node,
                "alias": f"labctl-m03-{marker_run}",
                "ifindex": index + 10,
                "iflink": index + 10,
                "master": M03_LINK_MASTERS[name],
                "link_type": kind,
                "namespace": {"container": node, "container_id": namespace_ids[node]},
                **({typed_field: typed_value} if typed_field else {}),
            }
            for index, (name, kind, role, node, typed) in enumerate(M03_LINKS)
            for typed_field, typed_value in ([typed] if typed else [(None, None)])
            if typed_field is not None or typed is None
        ],
        "frr_pathspace": {
            "node": "ovn-chassis-1",
            "config_dir": "/etc/frr/m03",
            "run_dir": "/run/frr/m03",
            "active": True,
            "owner_token": marker_token,
            "daemons": [
                {
                    "daemon": daemon,
                    "pid": index + 101,
                    "start_time_ticks": index + 10001,
                    "cmdline": daemon + " -N m03",
                }
                for index, daemon in enumerate(("zebra", "bgpd", "staticd"))
            ],
        },
        "tenant_vrf": {
            "name": "ovnvrf-tenant",
            "kind": "vrf",
            "table": 300,
            "alias": None,
            "node": "ovn-chassis-1",
            "ifindex": 9,
            "iflink": 9,
            "master": None,
            "link_type": "vrf",
            "namespace": {
                "container": "ovn-chassis-1",
                "container_id": container_ids["ovn-chassis-1"],
            },
        },
        "a_fingerprint": {
            "Logical_Switch": {
                "_uuid": _fixture_uuid("ls-dci-tenant"),
                "name": "ls-dci-tenant",
                "ports": [_fixture_uuid("lsp-dci-tenant")],
                "other_config": {"dynamic-routing-vni": "50100"},
            },
            "Logical_Router": {
                "_uuid": _fixture_uuid("lr-dci-tenant"),
                "name": "lr-dci-tenant",
                "ports": [_fixture_uuid("lrp-dci-tenant")],
            },
            "Logical_Router_Port": {
                "_uuid": _fixture_uuid("lrp-dci-tenant"),
                "name": "lrp-dci-tenant",
                "options": {
                    "dynamic-routing-maintain-vrf": "true",
                    "dynamic-routing-port-name": f"m03-evpn-{marker_run}",
                },
            },
        },
    }
    gateway_rows = {}
    for node, fixture in (("ovn-gw-1", "frr-gw1.conf"), ("ovn-gw-2", "frr-gw2.conf")):
        size, digest = sha256_file(fixture)
        scopes = list(A_FRR_SCOPES[node])
        gateway_rows[node] = {
            "fixture": fixture,
            "bytes": size,
            "sha256": digest,
            "matches_fixture": True,
            "base_path": "/etc/frr/frr.conf",
            "base_sha256": digest,
            "base_bytes": size,
            "base_matches": True,
            "extension_absent": True,
            "write_memory": False,
            "vtysh_b": False,
            "a_scopes_before": scopes,
            "a_scopes_sha256": canonical_hash(scopes),
            "running_config_sha256": sha256(("\n".join(scopes) + "\n").encode("utf-8")),
        }
    sections = {
        "m03": m03,
        "dci": {
            "status": "PASS",
            "profile_owner": profile_owner,
            "expected_cluster_names": list(CLUSTER_NAMES),
            "foreign_names": [],
            "container_ids": container_ids,
            "recorded_ids": recorded_ids,
            "container_states": {name: "running" for name in DCI_CONTAINER_NAMES},
            "container_labels": {
                **{
                    name: copy.deepcopy(original_image_labels)
                    for name in CLUSTER_NAMES
                },
                "dci-client-1": {"labctl.dci.owner": profile_owner},
            },
            "original_image_bindings": {
                name: {
                    "image_id": original_image_id,
                    "image_labels": copy.deepcopy(original_image_labels),
                }
                for name in CLUSTER_NAMES
            },
            "recorded_bridge_uuids": recorded_bridges,
            "bridges": bridges,
        },
        "docker": {
            "status": "PASS",
            "names_absent": {name: True for name in FIXED_X05_DOCKER_NAMES},
            "foreign_names": [],
            "resolved_images": {
                tag: "sha256:" + sha256(("image:" + tag).encode("utf-8"))
                for tag in MUTABLE_IMAGE_TAGS
            },
        },
        "gateway_frr": {"status": "PASS", "gateways": gateway_rows},
        "chassis2": {
            "status": "PASS",
            "dynamic-routing-port-mapping": None,
            "ovn-evpn-local-ip": EXPECTED_LOCAL_IP,
            "original_values": {
                "dynamic-routing-port-mapping": None,
                "ovn-evpn-local-ip": EXPECTED_LOCAL_IP,
            },
        },
        "inventory": {
            "status": "PASS",
            "count": 43,
            "gaps": [],
            "resources": sorted(resources),
            "all_absent": True,
            "runtime_plan_sha256": plan["runtime_plan_sha256"],
            "resource_ids_sha256": plan["resource_ids_sha256"],
            "generated_vrfs": {
                resource_id: {
                    "exists": False,
                    "observation_only": True,
                    "generated_by": "OVN",
                    "direct_delete": False,
                }
                for resource_id, resource in resources.items()
                if resource["kind"] == "ovn-generated-vrf"
            },
        },
        "evidence": {
            "status": "PASS",
            "path_absent": True,
            "capture_paths": [],
            "capture_processes": [],
        },
    }
    snapshot: dict[str, Any] = {
        "schema": SCHEMA,
        "mode": "fixture",
        "status": "PASS",
        "errors": [],
        "run_hex": run_hex,
        "owner": owner,
        "evidence_path": evidence_path,
        "runtime_plan_sha256": plan["runtime_plan_sha256"],
        "snapshot_sha256": "0" * 64,
        "sections": sections,
        "before": before,
        "x05_marker": {"path": "/run/labctl/dci-x05/active", "exists": False},
        "journal_seed": {},
    }
    snapshot["sections"]["docker"]["resolved_images_sha256"] = canonical_hash(
        snapshot["sections"]["docker"]["resolved_images"]
    )
    snapshot["snapshot_sha256"] = snapshot_digest(snapshot)
    snapshot["journal_seed"] = {
        "schema": "p004-x05-runtime-journal-seed-v1",
        "run_hex": run_hex,
        "owner": owner,
        "evidence_path": evidence_path,
        "runtime_plan_sha256": plan["runtime_plan_sha256"],
        "snapshot_sha256": snapshot["snapshot_sha256"],
        "m03_marker_sha256": marker_digest,
        "m03_owner_token": marker_token,
        "m03_run_token": marker_run,
        "resource_count": 43,
        "resource_ids_sha256": plan["resource_ids_sha256"],
        "resolved_images": copy.deepcopy(
            snapshot["sections"]["docker"]["resolved_images"]
        ),
        "resolved_images_sha256": snapshot["sections"]["docker"][
            "resolved_images_sha256"
        ],
    }
    return snapshot


def expect_rejection(
    snapshot: dict[str, Any], label: str, *, allow_fixture: bool = False
) -> None:
    try:
        validate_snapshot(snapshot, allow_fixture=allow_fixture)
    except SnapshotError:
        return
    raise AssertionError("selftest accepted negative case: " + label)


def selftest() -> int:
    """Exercise fixture admission and the high-value drift controls."""
    fixture = synthetic_fixture()
    fixture_report = validate_snapshot(fixture, allow_fixture=True)
    require(
        fixture_report.get("authorizes_mutation") is False,
        "schema validation must never authorize mutation",
    )
    expect_rejection(fixture, "fixture mode at execution admission")

    relabeled_complete = copy.deepcopy(fixture)
    relabeled_complete["mode"] = "live-observed"
    relabeled_complete["snapshot_sha256"] = snapshot_digest(relabeled_complete)
    relabeled_complete["journal_seed"]["snapshot_sha256"] = relabeled_complete[
        "snapshot_sha256"
    ]
    relabeled_report = validate_snapshot(relabeled_complete)
    require(
        relabeled_report.get("authorizes_mutation") is False,
        "relabeled serialized evidence must remain non-authoritative",
    )

    relabeled_fixture = copy.deepcopy(fixture)
    relabeled_fixture["mode"] = "live-observed"
    relabeled_fixture["sections"]["m03"].pop("tenant_vrf", None)
    relabeled_fixture["sections"]["m03"].pop("a_fingerprint", None)
    relabeled_fixture["snapshot_sha256"] = snapshot_digest(relabeled_fixture)
    relabeled_fixture["journal_seed"]["snapshot_sha256"] = relabeled_fixture[
        "snapshot_sha256"
    ]
    expect_rejection(relabeled_fixture, "relabeled fixture without complete M03 proof")

    cases = []
    missing = copy.deepcopy(fixture)
    missing["before"].pop(next(iter(missing["before"])))
    cases.append((missing, "missing inventory item"))
    foreign = copy.deepcopy(fixture)
    foreign["sections"]["docker"]["names_absent"]["dci-client-2"] = False
    cases.append((foreign, "foreign Docker name"))
    wrong_frr = copy.deepcopy(fixture)
    wrong_frr["sections"]["gateway_frr"]["gateways"]["ovn-gw-1"]["sha256"] = "0" * 64
    cases.append((wrong_frr, "wrong gateway FRR hash"))
    chassis_drift = copy.deepcopy(fixture)
    chassis_drift["sections"]["chassis2"]["ovn-evpn-local-ip"] = "50100-170.168.0.7"
    cases.append((chassis_drift, "chassis local-ip drift"))
    id_drift = copy.deepcopy(fixture)
    id_drift["sections"]["dci"]["container_ids"]["ovn-gw-1"] = "1" * 64
    cases.append((id_drift, "recorded DCI ID drift"))
    uuid_drift = copy.deepcopy(fixture)
    uuid_drift["sections"]["dci"]["bridges"]["br-ovn"]["uuid"] = _fixture_uuid(
        "foreign"
    )
    cases.append((uuid_drift, "recorded bridge UUID drift"))
    label_drift = copy.deepcopy(fixture)
    label_drift["sections"]["dci"]["container_labels"]["ovn-gw-1"] = {
        "labctl.dci.owner": "foreign"
    }
    cases.append((label_drift, "original node DCI label"))
    missing_image_binding = copy.deepcopy(fixture)
    missing_image_binding["sections"]["dci"]["original_image_bindings"].pop(
        "ovn-gw-1"
    )
    missing_image_binding["snapshot_sha256"] = snapshot_digest(missing_image_binding)
    missing_image_binding["journal_seed"]["snapshot_sha256"] = missing_image_binding[
        "snapshot_sha256"
    ]
    cases.append((missing_image_binding, "missing original image binding"))
    malformed_image_binding = copy.deepcopy(fixture)
    malformed_image_binding["sections"]["dci"]["original_image_bindings"][
        "ovn-gw-1"
    ]["image_id"] = "malformed"
    malformed_image_binding["snapshot_sha256"] = snapshot_digest(
        malformed_image_binding
    )
    malformed_image_binding["journal_seed"]["snapshot_sha256"] = malformed_image_binding[
        "snapshot_sha256"
    ]
    cases.append((malformed_image_binding, "malformed original image binding"))
    mismatched_image_binding = copy.deepcopy(fixture)
    mismatched_image_binding["sections"]["dci"]["original_image_bindings"][
        "ovn-gw-1"
    ]["image_labels"] = {"org.example.foreign": "label"}
    mismatched_image_binding["snapshot_sha256"] = snapshot_digest(
        mismatched_image_binding
    )
    mismatched_image_binding["journal_seed"]["snapshot_sha256"] = mismatched_image_binding[
        "snapshot_sha256"
    ]
    cases.append((mismatched_image_binding, "mismatched original image labels"))
    peer_profile_label = copy.deepcopy(fixture)
    del peer_profile_label["sections"]["m03"]["peer"]["labels"]["labctl.dci.owner"]
    cases.append((peer_profile_label, "M03 peer missing DCI profile label"))
    peer_ovs_identity = copy.deepcopy(fixture)
    peer_ovs_identity["sections"]["m03"]["peer"]["ovs"]["container_iface"] = "eth2"
    cases.append((peer_ovs_identity, "M03 peer OVS interface identity"))
    link_node = copy.deepcopy(fixture)
    next(
        item
        for item in link_node["sections"]["m03"]["links"]
        if item["name"] == "vxlan-m03-peer"
    )["node"] = "ovn-chassis-1"
    cases.append((link_node, "M03 peer link node binding"))
    vrf_vni = copy.deepcopy(fixture)
    vrf_link = next(
        item
        for item in vrf_vni["sections"]["m03"]["links"]
        if item["name"] == "vrf-evpn-client"
    )
    vrf_link.pop("table")
    vrf_link["vni"] = 50100
    cases.append((vrf_vni, "M03 VRF uses VNI instead of table"))
    generated_future = copy.deepcopy(fixture)
    generated_id = next(
        iter(generated_future["sections"]["inventory"]["generated_vrfs"])
    )
    generated_future["sections"]["inventory"]["generated_vrfs"][generated_id][
        "absent_after_nb_inverse"
    ] = True
    cases.append((generated_future, "future generated VRF proof at admission"))
    marker_tamper = copy.deepcopy(fixture)
    marker_raw = marker_tamper["sections"]["m03"]["marker"]["raw"]
    marker_tamper["sections"]["m03"]["marker"]["raw"] = marker_raw.replace(
        "intent=maintain-vrf", "intent=foreign"
    )
    cases.append((marker_tamper, "M03 raw marker tamper"))
    path_drift = copy.deepcopy(fixture)
    path_drift["evidence_path"] = "/workspace/evidence/P004/S002/../a1b2c3/08-x05"
    cases.append((path_drift, "noncanonical evidence path"))
    run_drift = copy.deepcopy(fixture)
    run_drift["run_hex"] = "a1b2c4"
    cases.append((run_drift, "run identity drift"))
    journal_drift = copy.deepcopy(fixture)
    journal_drift["journal_seed"]["runtime_plan_sha256"] = "0" * 64
    cases.append((journal_drift, "journal digest tamper"))
    image_drift = copy.deepcopy(fixture)
    image_drift["sections"]["docker"]["resolved_images"]["frrouting/frr:v8.4.1"] = (
        "sha256:" + "0" * 64
    )
    cases.append((image_drift, "resolved image drift"))
    image_journal_drift = copy.deepcopy(fixture)
    image_journal_drift["journal_seed"]["resolved_images_sha256"] = "0" * 64
    cases.append((image_journal_drift, "resolved image journal drift"))
    placeholder = copy.deepcopy(fixture)
    resource_id = next(iter(placeholder["before"]))
    placeholder["before"][resource_id]["identity"]["name"] = "<run>"
    cases.append((placeholder, "placeholder in admitted inventory"))
    for case, label in cases:
        expect_rejection(case, label, allow_fixture=True)
    print(
        "X05 runtime preflight selftest PASS: concrete plan, marker, ownership "
        "and drift negatives"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", metavar="SNAPSHOT.json")
    group.add_argument("--selftest", action="store_true")
    args = parser.parse_args(argv)
    if args.selftest:
        return selftest()
    try:
        report = validate_snapshot(read_snapshot(pathlib.Path(args.check)))
    except (OSError, SnapshotError, ValueError) as exc:
        print(
            json.dumps(
                {"schema": SCHEMA, "status": "FAIL", "reason": str(exc)},
                sort_keys=True,
                separators=(",", ":"),
            )
        )
        return 1
    print(json.dumps(report, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
