#!/usr/bin/env python3
"""Deterministic producer-bound checks for the X05 runtime builder.

The fake implements the fixed Docker/Linux/OVS/OVN/FRR command surface in
memory.  It never invokes Docker, unshare, nsenter, OVS, OVN, FRR, SSH, or a
lab helper.  Admission itself is the genuine reviewed producer and the NB
adapter is the genuine library adapter using that producer's Runner.
"""

from __future__ import annotations

import contextlib
import copy
import dataclasses
import datetime as dt
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import stat
import sys
import tempfile
import time
import types
from collections.abc import Callable, Iterator, Mapping, Sequence
from typing import Any
from unittest import mock


HERE = pathlib.Path(__file__).resolve().parent


def load(name: str, path: pathlib.Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


CAPTURE = sys.modules.get("x05_capture_runtime_contract") or load(
    "x05_capture_runtime_contract", HERE / "x05-capture.py"
)
APPLY = CAPTURE.APPLY
SUPPORT = load(
    "x05_runtime_apply_producer_support", HERE / "x05-runtime-live-selftest.py"
)
SUPPORT.LIVE = APPLY.RUNTIME
APPLY.RUNTIME.load_local_test_modules()


def digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def uuid(value: str) -> str:
    return SUPPORT.uuid(value)


def ovs_json(rows: Sequence[Mapping[str, Any]], columns: Sequence[str]) -> bytes:
    def encode(value: Any) -> Any:
        if isinstance(value, dict):
            return ["map", [[key, encode(item)] for key, item in sorted(value.items())]]
        if isinstance(value, list):
            return ["set", [encode(item) for item in value]]
        if isinstance(value, tuple) and len(value) == 2 and value[0] == "uuid":
            return ["uuid", value[1]]
        return value

    return json.dumps(
        {
            "headings": list(columns),
            "data": [
                [encode(row.get(column, [])) for column in columns] for row in rows
            ],
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode("ascii")


def current_pin(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_worktree_pins() -> None:
    """Require the frozen producer pins; never patch authority in a test."""
    reviewed = APPLY.RUNTIME.REVIEWED_BUNDLE_FILES
    for name in (
        "x05-runtime-plan.py",
        "x05-runtime-preflight.py",
        "x05-runtime-apply.py",
        "x05-capture.py",
    ):
        assert reviewed["studies/p004/ovn/" + name] == current_pin(HERE / name)
    assert (
        APPLY.RUNTIME.REVIEWED_BUNDLE_MANIFEST_SHA256
        == APPLY.RUNTIME._digest(reviewed)
    )


FINGERPRINT = {
    "ls_uuid": "00000000-0000-4000-8000-000000000001",
    "lr_uuid": "00000000-0000-4000-8000-000000000002",
    "lrp_uuid": "00000000-0000-4000-8000-000000000003",
    "ls_ports": ["00000000-0000-4000-8000-000000000004"],
    "lr_ports": ["00000000-0000-4000-8000-000000000003"],
}


@dataclasses.dataclass
class Link:
    name: str
    ifindex: int
    iflink: int
    kind: str
    alias: str | None = None
    mac: str = "02:00:00:00:00:01"
    mtu: int = 1500
    master: str | None = None
    up: bool = False
    info_data: dict[str, Any] = dataclasses.field(default_factory=dict)
    addresses: list[str] = dataclasses.field(default_factory=list)

    def row(self) -> dict[str, Any]:
        return {
            "ifname": self.name,
            "ifindex": self.ifindex,
            "ifalias": self.alias,
            "address": self.mac,
            "mtu": self.mtu,
            "master": self.master,
            "operstate": "UP" if self.up else "DOWN",
            "flags": ["BROADCAST", "MULTICAST", *( ["UP"] if self.up else [])],
            "linkinfo": {"info_kind": self.kind, "info_data": copy.deepcopy(self.info_data)},
        }


class RuntimeFakeRunner(SUPPORT.FakeRunner):
    """Stateful bounded model for the builder's exact command surface."""

    def __init__(
        self,
        config: Any,
        *,
        empty_original_image_labels: bool = False,
    ) -> None:
        super().__init__(config)
        if empty_original_image_labels:
            self.original_image_labels = {}
        self.runtime_calls: list[tuple[str, ...]] = []
        self.nb_calls: list[tuple[str, ...]] = []
        self.effect_calls: list[tuple[str, ...]] = []
        self.nb_effects = 0
        self.nb_forward = False
        self.fail_before_effect: str | None = None
        self.fail_effect: str | None = None
        self.fail_after_effect: str | None = None
        self.fail_between_moves = False
        self.after_effect: Callable[[tuple[str, ...]], None] | None = None
        self.next_ifindex = 100
        self.next_pid = 6000
        self.pid_to_scope: dict[int, str] = {os.getpid(): "host"}
        self.process_start: dict[int, int] = {os.getpid(): 900001}
        self.netns_inode: dict[int, int] = {os.getpid(): 800001}
        self.mntns_inode: dict[int, int] = {os.getpid(): 810001}
        self.containers: dict[str, dict[str, Any]] = {}
        self.container_by_id: dict[str, str] = {}
        self.links: dict[str, dict[str, Link]] = {"host": {}}
        self.routes: dict[str, list[dict[str, Any]]] = {}
        self.named_netns: dict[str, dict[str, int]] = {}
        self.files: dict[str, dict[str, bytes]] = {}
        self.directories: dict[str, set[str]] = {}
        self.frr_processes: dict[str, list[dict[str, Any]]] = {}
        self.gateway_extension: dict[str, bool] = {
            "ovn-gw-1": False,
            "ovn-gw-2": False,
        }
        self.ovs_ports: dict[str, dict[str, dict[str, Any]]] = {}
        self.ovs_external: dict[str, dict[str, str]] = {
            "ovn-chassis-2": {"ovn-evpn-local-ip": "50100-170.168.0.6"}
        }
        self.ovs_root_uuid = {"ovn-chassis-2": uuid("ovs:ovn-chassis-2")}
        self.null_label_names: set[str] = set()
        self.netns_next_inode = 920000
        self._initialize_containers()
        self._initialize_links()

    def _initialize_containers(self) -> None:
        names = (
            *APPLY.RUNTIME.PREFLIGHT.DCI_CONTAINER_NAMES,
            "dci-evpn-client-1",
            "p003-os",
        )
        for offset, name in enumerate(names, 1):
            labels: dict[str, str] = {}
            image = "sha256:" + digest("container-image:" + name)
            if name in APPLY.RUNTIME.PREFLIGHT.CLUSTER_NAMES:
                labels = copy.deepcopy(self.original_image_labels)
                image = self.original_image_id
            elif name == "dci-client-1":
                labels = {"labctl.dci.owner": self.profile_owner}
            elif name == "dci-evpn-client-1":
                labels = {
                    "labctl.dci.owner": self.profile_owner,
                    "labctl-m03-owner": self.marker_token,
                }
            self._add_container(
                name,
                self.ids[name],
                image,
                labels,
                4000 + offset,
                running=name != "p003-os",
            )
        self.files["ovn-gw-1"]["/etc/frr/frr.conf"] = (
            HERE / "frr-gw1.conf"
        ).read_bytes()
        self.files["ovn-gw-2"]["/etc/frr/frr.conf"] = (
            HERE / "frr-gw2.conf"
        ).read_bytes()

    def _add_container(
        self,
        name: str,
        container_id: str,
        image: str,
        labels: Mapping[str, str],
        pid: int,
        *,
        running: bool = True,
    ) -> None:
        self.containers[name] = {
            "id": container_id,
            "image": image,
            "labels": dict(labels),
            "pid": pid,
            "running": running,
        }
        self.container_by_id[container_id] = name
        self.pid_to_scope[pid] = name
        self.process_start[pid] = 100000 + pid
        self.netns_inode[pid] = 200000 + pid
        self.mntns_inode[pid] = 300000 + pid
        self.links.setdefault(name, {})
        self.routes.setdefault(name, [])
        self.named_netns.setdefault(name, {})
        self.files.setdefault(name, {})
        self.directories.setdefault(name, set())
        self.frr_processes.setdefault(name, [])
        self.links[name].setdefault(
            "lo", Link("lo", 1, 1, "loopback", mac="00:00:00:00:00:00", up=True)
        )

    def _initialize_links(self) -> None:
        self.links["host"]["br-ovn"] = Link("br-ovn", 2, 2, "bridge", up=True)
        self.links["host"]["br-ovn-ext"] = Link(
            "br-ovn-ext", 3, 3, "bridge", up=True
        )
        self.links["host"]["veth-m03-host"] = Link(
            "veth-m03-host", 4, 44, "veth", up=True
        )
        self.links["dci-client-1"]["lo"].addresses = ["10.0.0.1/32"]
        self.links["dci-evpn-client-1"].update(
            {
                "vrf-evpn-client": Link(
                    "vrf-evpn-client",
                    40,
                    40,
                    "vrf",
                    alias=self.marker_token,
                    up=True,
                    info_data={"table": 50100},
                ),
                "br-evpn-client": Link(
                    "br-evpn-client",
                    41,
                    41,
                    "bridge",
                    alias=self.marker_token,
                    master="vrf-evpn-client",
                    up=True,
                    addresses=["10.250.0.1/32"],
                ),
                "vxlan-m03-peer": Link(
                    "vxlan-m03-peer",
                    42,
                    42,
                    "vxlan",
                    alias=self.marker_token,
                    master="br-evpn-client",
                    up=True,
                    info_data={"id": 50100},
                ),
                "evpn-client": Link(
                    "evpn-client",
                    43,
                    43,
                    "dummy",
                    alias=self.marker_token,
                    master="br-evpn-client",
                    up=True,
                ),
            }
        )
        self.links["ovn-chassis-1"].update(
            {
                "ovnvrf-tenant": Link(
                    "ovnvrf-tenant", 30, 30, "vrf", up=True, info_data={"table": 300}
                ),
                "br-evpn-tenant": Link(
                    "br-evpn-tenant", 31, 31, "bridge", alias=self.marker_token,
                    master="ovnvrf-tenant", up=True,
                ),
                "vxlan-tenant": Link(
                    "vxlan-tenant", 32, 32, "vxlan", alias=self.marker_token,
                    master="br-evpn-tenant", up=True, info_data={"id": 50100},
                ),
                "evpn-tenant": Link(
                    "evpn-tenant", 33, 33, "dummy", alias=self.marker_token,
                    master="br-evpn-tenant", up=True,
                ),
            }
        )
        for node, number, address, index in (
            ("ovn-gw-1", 100, "169.254.254.1/30", 50),
            ("ovn-gw-2", 200, "169.254.254.5/30", 60),
        ):
            self.links[node][f"bgpvrf{number}"] = Link(
                f"bgpvrf{number}", index, index + 1, "veth", up=True,
                addresses=[address],
            )
            self.links[node][f"bgpvrf{number}-ovs"] = Link(
                f"bgpvrf{number}-ovs", index + 1, index, "veth", up=True,
            )
        for index, node in enumerate(("ovn-chassis-1", "ovn-chassis-2"), 20):
            self.links[node]["vxlan_sys_4789"] = Link(
                "vxlan_sys_4789",
                index,
                index,
                "vxlan",
                up=True,
                info_data={
                    "id": 0,
                    "local": "170.168.0.5" if node.endswith("1") else "170.168.0.6",
                    "port": 4789,
                    "learning": False,
                    "link": index,
                },
            )

    def result(
        self,
        argv: tuple[str, ...],
        stdout: bytes = b"",
        returncode: int = 0,
        stderr: bytes = b"",
    ) -> Any:
        return APPLY.RUNTIME.CommandResult(argv, returncode, stdout, stderr, 0.001)

    def _container_name(self, value: str) -> str:
        return self.container_by_id.get(value, value)

    def _container_row(self, value: str) -> dict[str, Any]:
        name = self._container_name(value)
        entry = self.containers[name]
        labels: dict[str, str] | None = (
            None
            if name in self.null_label_names and not entry["labels"]
            else copy.deepcopy(entry["labels"])
        )
        return {
            "Id": entry["id"],
            "Name": "/" + name,
            "Image": entry["image"],
            "State": {
                "Status": "running" if entry["running"] else "exited",
                "Running": entry["running"],
                "Pid": entry["pid"] if entry["running"] else 0,
            },
            "Config": {"Image": entry["image"], "Labels": labels},
        }

    def _columns(self, command: Sequence[str]) -> tuple[str, ...]:
        return tuple(
            next(item for item in command if item.startswith("--columns="))
            .split("=", 1)[1]
            .split(",")
        )

    def _node_from_docker(self, command: Sequence[str]) -> str:
        return self._container_name(command[2])

    def _result_with_faults(
        self, command: tuple[str, ...], stdout: bytes = b"", stderr: bytes = b""
    ) -> Any:
        joined = " ".join(command)
        self.effect_calls.append(command)
        if self.fail_effect and self.fail_effect in joined:
            raise APPLY.RUNTIME.CommandTimeout("synthetic unknown effect")
        result = self.result(command, stdout, 0, stderr)
        if self.after_effect is not None:
            callback = self.after_effect
            self.after_effect = None
            callback(command)
        if self.fail_after_effect and self.fail_after_effect in joined:
            self.fail_after_effect = None
            return object()
        return result

    def _nb_command(
        self,
        command: tuple[str, ...],
        *,
        env: Mapping[str, str],
        timeout: float,
        pass_fds: Sequence[int],
        max_output_bytes: int,
    ) -> Any | None:
        joined = " ".join(command)
        helper = any(
            name in joined
            for name in (
                "x05-nb-preflight.sh",
                "x05-nb-full-snapshot.sh",
                "x05-nb-tx.py",
                "x05-nb-postflight.py",
            )
        )
        nb_effect = "ovsdb-client" in command and "ovnnb_db.sock" in joined
        if not helper and not nb_effect:
            return None
        assert env == APPLY.RUNTIME.BASE_ENV
        assert timeout == self.config.command_timeout
        assert max_output_bytes == APPLY.RUNTIME.MAX_OUTPUT
        assert tuple(pass_fds) == ((APPLY.NB.LOCK_FD,) if nb_effect else ())
        self.nb_calls.append(command)
        if nb_effect:
            self.nb_effects += 1
            self.nb_forward = self.nb_effects == 1
            if self.nb_forward:
                self._create_generated_vrfs()
            else:
                self._remove_generated_vrfs()
            return self._result_with_faults(command, b"[{}]\n")
        if "x05-nb-preflight.sh" in joined:
            return self.result(
                command,
                json.dumps(
                    {
                        "schema": "p004-x05-nb-preflight-v1",
                        "status": "PASS",
                        "planned_rows_absent": 34,
                        "owner_residue": 0,
                        "nb_cfg": 10,
                        "a_fingerprint": FINGERPRINT,
                    },
                    separators=(",", ":"),
                ).encode()
                + b"\n",
            )
        if "x05-nb-full-snapshot.sh" in joined:
            return self.result(
                command,
                json.dumps(
                    {
                        "schema": "p004-x05-nb-full-snapshot-v1",
                        "capture_started_ns": 10 + len(self.nb_calls),
                        "capture_finished_ns": 20 + len(self.nb_calls),
                        "nb_cfg_before": 10,
                        "nb_cfg_after": 10,
                        "tables": {},
                    },
                    separators=(",", ":"),
                ).encode()
                + b"\n",
            )
        if "--check-result" in command:
            return self.result(
                command,
                json.dumps(
                    {
                        "schema": "p004-x05-nb-tx-result-v1",
                        "status": "PASS",
                        "owner": self.config.owner,
                        "run_hex": self.config.run_hex,
                        "a_fingerprint": FINGERPRINT,
                        "inserted": {},
                        "a_ls_attach_count": 1,
                    },
                    separators=(",", ":"),
                ).encode()
                + b"\n",
            )
        if "--check-inverse-result" in command:
            return self.result(
                command,
                json.dumps(
                    {
                        "schema": "p004-x05-nb-inverse-result-v1",
                        "status": "PASS",
                        "owner": self.config.owner,
                        "run_hex": self.config.run_hex,
                        "a_fingerprint": FINGERPRINT,
                        "inserted": {},
                        "a_ls_detach_count": 1,
                        "deleted_owned_rows": 34,
                    },
                    separators=(",", ":"),
                ).encode()
                + b"\n",
            )
        if "x05-nb-postflight.py" in joined:
            return self.result(
                command,
                json.dumps(
                    {
                        "schema": "p004-x05-nb-postflight-v1",
                        "status": "PASS",
                        "mode": "built" if "--built" in command else "clean",
                        "owner": self.config.owner,
                        "run_hex": self.config.run_hex,
                    },
                    separators=(",", ":"),
                ).encode()
                + b"\n",
            )
        if "x05-nb-tx.py" in joined:
            return self.result(command, b'["OVN_Northbound",{}]\n')
        raise AssertionError("unhandled NB command: " + repr(command))

    def _create_generated_vrfs(self) -> None:
        for node, name, table in (
            ("ovn-gw-1", "ovnvrf300", 300),
            ("ovn-gw-2", "ovnvrf400", 400),
            ("ovn-chassis-2", "ovnvrf-x05-b", 400),
        ):
            index = self.next_ifindex
            self.next_ifindex += 1
            self.links[node][name] = Link(
                name,
                index,
                index,
                "vrf",
                up=True,
                info_data={"table": table},
            )

    def _remove_generated_vrfs(self) -> None:
        for node, name in (
            ("ovn-gw-1", "ovnvrf300"),
            ("ovn-gw-2", "ovnvrf400"),
            ("ovn-chassis-2", "ovnvrf-x05-b"),
        ):
            self.links[node].pop(name, None)

    def _scope_for_pid(self, pid: int) -> str:
        if pid not in self.pid_to_scope:
            raise AssertionError("unknown fake PID: " + str(pid))
        return self.pid_to_scope[pid]

    def _network_command(
        self, command: tuple[str, ...]
    ) -> tuple[str, str | None, tuple[str, ...]] | None:
        candidate: tuple[str, str | None, tuple[str, ...]] | None = None
        if command and command[0] == "nsenter":
            pid = int(command[command.index("--target") + 1])
            rest = command[command.index("--") + 1 :]
            candidate = (self._scope_for_pid(pid), None, rest)
        elif command and command[0] in {"ip", "cat"}:
            candidate = ("host", None, command)
        elif command[:2] == ("docker", "exec"):
            node = self._container_name(command[2])
            if command[3:6] == ("ip", "netns", "exec"):
                namespace = command[6]
                candidate = (node, namespace, command[7:])
            elif command[3] == "ip":
                candidate = (node, None, command[3:])
        if candidate is None:
            return None
        rest = candidate[2]
        supported = (
            rest[:5] == ("ip", "-j", "-details", "link", "show")
            or rest[:4] == ("ip", "-j", "link", "show")
            or rest[:1] == ("cat",)
            or rest[:5] == ("ip", "-j", "-4", "address", "show")
            or rest[:5] == ("ip", "-j", "-4", "route", "show")
            or rest[:4] == ("ip", "link", "set", "dev")
            or rest[:3] == ("ip", "address", "add")
            or rest[:4] == ("ip", "route", "replace", "default")
            or rest[:3] == ("ip", "link", "del")
        )
        return candidate if supported else None

    @staticmethod
    def _scope_key(node: str, namespace: str | None) -> str:
        return node if namespace is None else node + "/" + namespace

    def _link(self, node: str, namespace: str | None, name: str) -> Link | None:
        return self.links.setdefault(self._scope_key(node, namespace), {}).get(name)

    def _link_json(self, link: Link) -> bytes:
        return json.dumps([link.row()], sort_keys=True, separators=(",", ":")).encode()

    def _network_result(
        self,
        command: tuple[str, ...],
        node: str,
        namespace: str | None,
        argv: tuple[str, ...],
    ) -> Any:
        scope = self._scope_key(node, namespace)
        links = self.links.setdefault(scope, {})
        routes = self.routes.setdefault(scope, [])
        if argv[:5] == ("ip", "-j", "-details", "link", "show"):
            name = argv[-1]
            link = links.get(name)
            if link is None:
                return self.result(command, b"", 1, b'Device "' + name.encode() + b'" does not exist.\n')
            return self.result(command, self._link_json(link))
        if argv[:4] == ("ip", "-j", "link", "show"):
            name = argv[-1]
            link = links.get(name)
            if link is None:
                return self.result(command, b"", 1, b'Device "' + name.encode() + b'" does not exist.\n')
            return self.result(command, self._link_json(link))
        if argv[0] == "cat" and argv[1].startswith("/sys/class/net/"):
            name = argv[1].split("/")[-2]
            link = links[name]
            value = link.ifindex if argv[1].endswith("/ifindex") else link.iflink
            return self.result(command, (str(value) + "\n").encode())
        if argv[:5] == ("ip", "-j", "-4", "address", "show"):
            name = argv[-1]
            link = links[name]
            values = []
            for address in link.addresses:
                local, prefix = address.split("/", 1)
                values.append({"family": "inet", "local": local, "prefixlen": int(prefix)})
            payload = [{"ifname": name, "addr_info": values}]
            return self.result(
                command,
                json.dumps(payload, sort_keys=True, separators=(",", ":")).encode(),
            )
        if argv[:5] == ("ip", "-j", "-4", "route", "show"):
            return self.result(
                command,
                json.dumps(routes, sort_keys=True, separators=(",", ":")).encode(),
            )
        if argv[:4] == ("ip", "link", "set", "dev"):
            name = argv[4]
            link = links[name]
            tail = argv[5:]
            if tail == ("up",):
                link.up = True
            elif tail[:1] == ("master",):
                link.master = tail[1]
            elif tail[:1] == ("address",):
                link.mac = tail[1].lower()
            elif tail[:1] == ("mtu",):
                link.mtu = int(tail[1])
            elif tail[:1] == ("netns",):
                destination = node + "/" + tail[1]
                old_index = link.ifindex
                new_index = self.next_ifindex
                self.next_ifindex += 1
                del links[name]
                link.ifindex = new_index
                self.links.setdefault(destination, {})[name] = link
                for candidate in links.values():
                    if candidate.iflink == old_index:
                        candidate.iflink = new_index
            else:
                raise AssertionError("unknown link set: " + repr(argv))
            return self._result_with_faults(command)
        if argv[:3] == ("ip", "address", "add"):
            address = argv[3]
            name = argv[-1]
            if address in links[name].addresses:
                return self.result(command, b"", 2, b"RTNETLINK answers: File exists\n")
            links[name].addresses.append(address)
            return self._result_with_faults(command)
        if argv[:4] == ("ip", "route", "replace", "default"):
            gateway = argv[5]
            name = argv[7]
            routes[:] = [row for row in routes if row.get("dst") != "default"]
            routes.append({"dst": "default", "gateway": gateway, "dev": name})
            return self._result_with_faults(command)
        if argv[:3] == ("ip", "link", "del"):
            name = argv[-1]
            link = links.pop(name)
            for other_scope in self.links.values():
                for other_name, candidate in list(other_scope.items()):
                    if candidate.ifindex == link.iflink and candidate.iflink == link.ifindex:
                        del other_scope[other_name]
            return self._result_with_faults(command)
        raise AssertionError("unhandled network command: " + repr(command))

    def _private_publish(self, command: tuple[str, ...]) -> Any:
        specification = json.loads(command[-1])
        kind = specification["kind"]
        names = specification["names"]
        targets = [self._scope_for_pid(int(row["pid"])) for row in specification["targets"]]
        if kind == "veth":
            left_index, right_index = self.next_ifindex, self.next_ifindex + 1
            self.next_ifindex += 2
            left = Link(names[0], left_index, right_index, "veth", alias=specification["alias"])
            right = Link(names[1], right_index, left_index, "veth", alias=specification["alias"])
            self.links[targets[0]][names[0]] = left
            if self.fail_between_moves:
                self.fail_between_moves = False
                self.effect_calls.append(command)
                raise APPLY.RUNTIME.CommandTimeout("synthetic failure between moves")
            self.links[targets[1]][names[1]] = right
        else:
            index = self.next_ifindex
            self.next_ifindex += 1
            info: dict[str, Any] = {}
            if kind == "vrf":
                info["table"] = specification["table"]
            elif kind == "vxlan":
                info = {
                    "id": specification["vni"],
                    "local": specification["local"],
                    "port": specification["dstport"],
                    "learning": False,
                    "link": specification["underlay_ifindex"],
                }
            self.links[targets[0]][names[0]] = Link(
                names[0], index, index, kind, alias=specification["alias"], info_data=info
            )
        payload = json.dumps(
            {"status": "PUBLISHED", "kind": kind, "names": names},
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
        return self._result_with_faults(command, payload)

    def _proc_result(self, command: tuple[str, ...]) -> Any | None:
        if command[:1] == ("cat",) and command[1].startswith("/proc/"):
            parts = command[1].split("/")
            pid = int(parts[2])
            if pid not in self.process_start:
                return self.result(command, b"", 1, b"cat: No such file or directory\n")
            fields = ["S"] + ["0"] * 18 + [str(self.process_start[pid])] + ["0"] * 4
            return self.result(command, f"{pid} (fake) {' '.join(fields)}\n".encode())
        if command[:3] == ("stat", "-Lc", "%i") and command[3].startswith("/proc/"):
            parts = command[3].split("/")
            pid = int(parts[2])
            inode = self.netns_inode[pid] if parts[-1] == "net" else self.mntns_inode[pid]
            return self.result(command, (str(inode) + "\n").encode())
        return None

    def _docker_lifecycle(self, command: tuple[str, ...]) -> Any | None:
        if command[:3] == ("docker", "container", "inspect"):
            value = command[3]
            name = self._container_name(value)
            if name not in self.containers:
                return self.result(command, b"[]\n", 1, b"No such container\n")
            return self.result(
                command,
                json.dumps([self._container_row(value)], sort_keys=True, separators=(",", ":")).encode(),
            )
        if command[:6] == (
            "docker",
            "container",
            "ls",
            "--all",
            "--no-trunc",
            "--filter",
        ):
            criterion = command[6]
            rows: list[tuple[str, str]] = []
            for name, entry in self.containers.items():
                include = False
                if criterion.startswith("name=^/"):
                    include = name == criterion.removeprefix("name=^/").removesuffix("$")
                elif criterion.startswith("id="):
                    include = entry["id"] == criterion.split("=", 1)[1]
                if include:
                    rows.append((entry["id"], name))
            raw = b"".join((container_id + "\t" + name + "\n").encode() for container_id, name in rows)
            return self.result(command, raw)
        if command[:2] == ("docker", "run"):
            name = command[command.index("--name") + 1]
            image = command[command.index("--entrypoint") + 2]
            labels = {
                item.split("=", 1)[0]: item.split("=", 1)[1]
                for index, item in enumerate(command)
                if index > 0 and command[index - 1] == "--label"
            }
            container_id = digest("runtime-container:" + name)
            pid = self.next_pid
            self.next_pid += 1
            self._add_container(name, container_id, image, labels, pid)
            return self._result_with_faults(command, (container_id + "\n").encode())
        if command[:4] == ("docker", "container", "rm", "--force"):
            container_id = command[4]
            name = self._container_name(container_id)
            entry = self.containers.pop(name)
            del self.container_by_id[entry["id"]]
            pid = entry["pid"]
            self.process_start.pop(pid, None)
            self.netns_inode.pop(pid, None)
            self.mntns_inode.pop(pid, None)
            self.pid_to_scope.pop(pid, None)
            self.links.pop(name, None)
            self.routes.pop(name, None)
            self.files.pop(name, None)
            self.directories.pop(name, None)
            self.frr_processes.pop(name, None)
            return self._result_with_faults(command, (container_id + "\n").encode())
        if command[:3] == ("docker", "container", "cp"):
            source = pathlib.Path(command[3])
            target, destination = command[4].split(":", 1)
            name = self._container_name(target)
            self.files[name][destination] = source.read_bytes()
            return self._result_with_faults(command)
        return None

    def _netns_command(self, command: tuple[str, ...]) -> Any | None:
        if command[:3] != ("docker", "exec", command[2] if len(command) > 2 else ""):
            return None
        if len(command) < 4:
            return None
        node = self._container_name(command[2])
        if command[3:6] == ("ip", "netns", "add"):
            namespace = command[6]
            self.netns_next_inode += 1
            self.named_netns[node][namespace] = self.netns_next_inode
            self.links[node + "/" + namespace] = {
                "lo": Link("lo", 1, 1, "loopback", mac="00:00:00:00:00:00")
            }
            self.routes[node + "/" + namespace] = []
            return self._result_with_faults(command)
        if command[3:6] == ("ip", "netns", "del"):
            namespace = command[6]
            del self.named_netns[node][namespace]
            self.links.pop(node + "/" + namespace, None)
            self.routes.pop(node + "/" + namespace, None)
            return self._result_with_faults(command)
        if command[3:6] == ("stat", "-Lc", "%i") and command[6].startswith("/var/run/netns/"):
            namespace = command[6].rsplit("/", 1)[1]
            inode = self.named_netns[node].get(namespace)
            if inode is None:
                return self.result(command, b"", 1, b"stat: No such file or directory\n")
            return self.result(command, (str(inode) + "\n").encode())
        return None

    def _frr_running(self, node: str) -> bytes:
        baseline = list(APPLY.RUNTIME.PREFLIGHT.A_FRR_SCOPES[node])
        if not self.gateway_extension[node]:
            return ("\n".join(baseline) + "\n").encode()
        if node == "ovn-gw-1":
            vrf, neighbor = "ovnvrf300", "169.254.254.2"
        else:
            vrf, neighbor = "ovnvrf400", "169.254.254.6"
        bfd = baseline.index("bfd")
        prefix = baseline[:bfd]
        bfd_lines = baseline[bfd:-1]
        suffix = [baseline[-1]]
        extension = [
            "vrf " + vrf,
            "exit-vrf",
            "router bgp 100 vrf " + vrf,
            " bgp router-id " + ("169.254.254.1" if node.endswith("1") else "169.254.254.5"),
            " neighbor " + neighbor + " remote-as 201",
            " neighbor " + neighbor + " bfd",
            " address-family ipv4 unicast",
            "  network 192.168.100.0/24",
            "  redistribute connected",
            "  neighbor " + neighbor + " activate",
            "  neighbor " + neighbor + " route-map MG-FROM-CLIENT in",
            "  neighbor " + neighbor + " route-map MG-TO-CLIENT out",
            " exit-address-family",
            "exit",
        ]
        peer = [
            " peer " + neighbor + " vrf " + vrf,
            "  no shutdown",
            "  receive-interval 500",
            "  transmit-interval 500",
            "  detect-multiplier 3",
            " exit",
        ]
        return ("\n".join(prefix + extension + bfd_lines + peer + suffix) + "\n").encode()

    def _frr_rows(self, node: str) -> bytes:
        rows = self.frr_processes[node]
        return b"".join(
            (
                f"{row['daemon']}\t{row['pid']}\t{row['start_ticks']}\t{row['command']}\n"
            ).encode()
            for row in rows
        )

    def _start_processes(self, node: str, mode: str) -> None:
        daemons = (
            sorted(APPLY.EXPECTED_CLIENT_DAEMONS)
            if mode == "client"
            else sorted(APPLY.EXPECTED_PATHSPACE_DAEMONS)
        )
        rows = []
        for daemon in daemons:
            pid = self.next_pid
            self.next_pid += 1
            start = 500000 + pid
            command = (
                f"/usr/lib/frr/{daemon} -d -f /etc/frr/frr.conf"
                if mode == "client"
                else f"/usr/lib/frr/{daemon} -d -N x05 --vty_socket /run/frr/x05"
            )
            rows.append(
                {"daemon": daemon, "pid": pid, "start_ticks": start, "command": command}
            )
            self.process_start[pid] = start
        self.frr_processes[node] = rows

    def _file_or_frr_command(self, command: tuple[str, ...]) -> Any | None:
        if command[:2] != ("docker", "exec") or len(command) < 4:
            return None
        node = self._container_name(command[2])
        rest = command[3:]
        if rest[:3] == ("vtysh", "-c", "show running-config"):
            return self.result(command, self._frr_running(node))
        if rest[:2] == ("vtysh", "-C"):
            return self.result(command)
        if rest[:2] == ("vtysh", "-f"):
            raw = self.files[node][rest[2]]
            if b"no router bgp" in raw:
                self.gateway_extension[node] = False
            else:
                self.gateway_extension[node] = True
            return self._result_with_faults(command)
        if rest[:1] == ("rm",) and rest[-1].startswith("/"):
            self.files[node].pop(rest[-1], None)
            return self._result_with_faults(command)
        if rest[:2] == ("test", "!") and rest[2] == "-e":
            present = rest[3] in self.files[node] or rest[3] in self.directories[node]
            return self.result(command, b"", 1 if present else 0)
        if rest[:2] == ("sh", "-ceu"):
            script = rest[2]
            args = rest[4:] if len(rest) >= 4 and rest[3] == "--" else rest[3:]
            if "sha256sum --" in script and "wc -c" in script:
                path = args[-1]
                raw = self.files[node][path]
                output = f"{len(raw)}\t{hashlib.sha256(raw).hexdigest()}\n".encode()
                return self.result(command, output)
            if script == APPLY.FRR_PROCESS_READER:
                return self.result(command, self._frr_rows(node))
            if script in {APPLY.FRR_PATHSPACE_STAGE, APPLY.FRR_CLIENT_STAGE}:
                if script == APPLY.FRR_PATHSPACE_STAGE:
                    self.directories[node].update({"/etc/frr/x05", "/run/frr/x05"})
                    self.files[node]["/etc/frr/x05/daemons"] = b"generated\n"
                    self.files[node]["/etc/frr/x05/vtysh.conf"] = b""
                else:
                    self.directories[node].add("/run/frr")
                    self.files[node]["/etc/frr/daemons"] = b"generated\n"
                    self.files[node]["/etc/frr/vtysh.conf"] = b""
                return self._result_with_faults(command)
            if script in {APPLY.FRR_PATHSPACE_START, APPLY.FRR_CLIENT_ACTION}:
                if script == APPLY.FRR_CLIENT_ACTION and args[-1] == "stop":
                    for row in self.frr_processes[node]:
                        self.process_start.pop(row["pid"], None)
                    self.frr_processes[node] = []
                else:
                    mode = "pathspace" if script == APPLY.FRR_PATHSPACE_START else "client"
                    self._start_processes(node, mode)
                return self._result_with_faults(command)
            if script == APPLY.FRR_PATHSPACE_STOP:
                for row in self.frr_processes[node]:
                    self.process_start.pop(row["pid"], None)
                self.frr_processes[node] = []
                return self._result_with_faults(command)
            if "rmdir -- /etc/frr/x05 /run/frr/x05" in script:
                for path in (
                    "/etc/frr/x05/daemons",
                    "/etc/frr/x05/vtysh.conf",
                ):
                    self.files[node].pop(path, None)
                self.directories[node].discard("/etc/frr/x05")
                self.directories[node].discard("/run/frr/x05")
                return self._result_with_faults(command)
            if "test ! -e /etc/frr/x05" in script:
                present = bool(
                    {"/etc/frr/x05", "/run/frr/x05"} & self.directories[node]
                )
                return self.result(command, b"", 1 if present else 0)
            if "test -d /etc/frr/x05" in script:
                present = {"/etc/frr/x05", "/run/frr/x05"}.issubset(
                    self.directories[node]
                )
                return self.result(command, b"", 0 if present else 1)
        return None

    def _ovs_scope(self, command: tuple[str, ...], program: str) -> tuple[str, int] | None:
        if command[:1] == (program,):
            return "host", 0
        if command[:2] == ("docker", "exec") and len(command) > 3 and command[3] == program:
            return self._container_name(command[2]), 3
        return None

    @staticmethod
    def _bridge_name(scope: str, interface: str) -> str:
        del interface
        return "br-ovn" if scope == "host" else "br-int"

    @staticmethod
    def _bridge_uuid(scope: str, bridge: str) -> str:
        return uuid(bridge if scope == "host" else scope + ":" + bridge)

    def _ovs_vsctl(self, command: tuple[str, ...]) -> Any | None:
        located = self._ovs_scope(command, "ovs-vsctl")
        if located is None:
            return None
        scope, offset = located
        argv = command[offset + 1 :]
        if "find" in argv and "--format=json" in argv:
            index = argv.index("find")
            table = argv[index + 1]
            name = argv[index + 2].split("=", 1)[1]
            columns = self._columns(argv)
            rows: list[dict[str, Any]] = []
            entry = self.ovs_ports.setdefault(scope, {}).get(name)
            if table == "Bridge":
                bridge_uuid = self._bridge_uuid(scope, name)
                members = [
                    ("uuid", row["port_uuid"])
                    for row in self.ovs_ports.setdefault(scope, {}).values()
                    if row["bridge"] == name
                ]
                rows = [{"_uuid": ("uuid", bridge_uuid), "name": name, "ports": members}]
            elif table == "Port" and entry is not None:
                rows = [
                    {
                        "_uuid": ("uuid", entry["port_uuid"]),
                        "name": name,
                        "tag": [] if entry["tag"] is None else entry["tag"],
                        "interfaces": [("uuid", entry["interface_uuid"])],
                        "external_ids": entry["port_external_ids"],
                    }
                ]
            elif table == "Interface" and entry is not None:
                rows = [
                    {
                        "_uuid": ("uuid", entry["interface_uuid"]),
                        "name": name,
                        "external_ids": entry["interface_external_ids"],
                    }
                ]
            return self.result(command, ovs_json(rows, columns))
        if "list" in argv and argv[-1] == "Open_vSwitch" and scope == "ovn-chassis-2":
            columns = self._columns(argv)
            rows = [
                {
                    "_uuid": ("uuid", self.ovs_root_uuid[scope]),
                    "external_ids": copy.deepcopy(self.ovs_external[scope]),
                }
            ]
            return self.result(command, ovs_json(rows, columns))
        if argv[:2] == ("--", "add-port"):
            bridge, interface = argv[2], argv[3]
            port_set = argv.index("Port")
            interface_set = argv.index("Interface")
            port_tokens = argv[port_set + 2 : interface_set - 2]
            interface_tokens = argv[interface_set + 2 :]
            tag_token = next(item for item in port_tokens if item.startswith("tag="))
            tag = None if tag_token == "tag=[]" else int(tag_token.split("=", 1)[1])

            def external(tokens: Sequence[str]) -> dict[str, str]:
                return {
                    item.removeprefix("external_ids:").split("=", 1)[0]:
                    item.split("=", 1)[1]
                    for item in tokens
                    if item.startswith("external_ids:")
                }

            self.ovs_ports.setdefault(scope, {})[interface] = {
                "bridge": bridge,
                "port_uuid": uuid("x05-port:" + scope + ":" + interface),
                "interface_uuid": uuid("x05-interface:" + scope + ":" + interface),
                "tag": tag,
                "port_external_ids": external(port_tokens),
                "interface_external_ids": external(interface_tokens),
            }
            return self._result_with_faults(command)
        return None

    def _ovsdb(self, command: tuple[str, ...]) -> Any | None:
        located = self._ovs_scope(command, "ovsdb-client")
        if located is None:
            return None
        scope, offset = located
        argv = command[offset + 1 :]
        if argv[:2] != ("transact", "unix:/var/run/openvswitch/db.sock"):
            return None
        transaction = json.loads(argv[2])
        operations = transaction[1:]
        if any(row.get("table") == "Open_vSwitch" for row in operations):
            update = next(row for row in operations if row.get("op") == "update")
            mapping = update["row"]["external_ids"]
            assert mapping[0] == "map"
            self.ovs_external[scope] = dict(mapping[1])
            reply = [{}, {"count": 1}]
        else:
            port_uuid = operations[0]["where"][0][2][1]
            matches = [
                name
                for name, row in self.ovs_ports.setdefault(scope, {}).items()
                if row["port_uuid"] == port_uuid
            ]
            assert len(matches) == 1
            del self.ovs_ports[scope][matches[0]]
            reply = [{}, {}, {"count": 1}, {"count": 1}, {"count": 1}]
        return self._result_with_faults(
            command,
            json.dumps(reply, sort_keys=True, separators=(",", ":")).encode(),
        )

    def _ovn_readback(self, command: tuple[str, ...]) -> Any | None:
        if command[:2] != ("docker", "exec") or len(command) < 7:
            return None
        program = command[3]
        if program not in {"ovn-nbctl", "ovn-sbctl"} or "--format=json" not in command:
            return None
        columns = self._columns(command)
        rows: list[dict[str, Any]] = []
        if program == "ovn-nbctl" and command[-2:] == ("list", "Logical_Switch"):
            if self.nb_forward:
                rows = [
                    {
                        "_uuid": ("uuid", uuid("ls-x05-tenant-b")),
                        "name": "ls-x05-tenant-b",
                        "ports": [("uuid", uuid("x05-tenant-b-vm"))],
                    }
                ]
        elif program == "ovn-nbctl" and command[-3:-1] == ("find", "Logical_Switch_Port"):
            if self.nb_forward and command[-1] == "name=x05-tenant-b-vm":
                rows = [
                    {"_uuid": ("uuid", uuid("x05-tenant-b-vm")), "name": "x05-tenant-b-vm"}
                ]
        elif program == "ovn-sbctl" and command[-3:-1] == ("find", "Port_Binding"):
            if self.nb_forward and command[-1] == "logical_port=x05-tenant-b-vm":
                rows = [
                    {
                        "_uuid": ("uuid", uuid("sb:x05-tenant-b-vm")),
                        "logical_port": "x05-tenant-b-vm",
                        "datapath": ("uuid", uuid("datapath:ls-x05-tenant-b")),
                    }
                ]
        elif program == "ovn-nbctl" and command[-3:-1] == ("find", "Logical_Router_Port"):
            name = command[-1].split("=", 1)[1]
            macs = {
                "lrp-x05-300-external": "02:00:2c:00:00:01",
                "lrp-x05-400-external": "02:00:90:00:00:01",
                "lrp-x05-tenant-b": "02:00:00:20:00:01",
            }
            if name not in macs:
                return None
            if self.nb_forward and name in macs:
                rows = [
                    {"_uuid": ("uuid", uuid(name)), "name": name, "mac": [macs[name]]}
                ]
        else:
            return None
        return self.result(command, ovs_json(rows, columns))

    def run(
        self,
        argv: Sequence[str],
        *,
        env: Mapping[str, str],
        timeout: float,
        pass_fds: Sequence[int] = (),
        max_output_bytes: int = APPLY.RUNTIME.MAX_OUTPUT,
    ) -> Any:
        command = tuple(argv)
        if command and command[0] == str(self.config.labctl_path):
            return super().run(
                command,
                env=env,
                timeout=timeout,
                pass_fds=pass_fds,
                max_output_bytes=max_output_bytes,
            )
        nb = self._nb_command(
            command,
            env=env,
            timeout=timeout,
            pass_fds=pass_fds,
            max_output_bytes=max_output_bytes,
        )
        if nb is not None:
            return nb
        assert env == APPLY.RUNTIME.BASE_ENV
        assert timeout == self.config.command_timeout
        assert max_output_bytes == APPLY.RUNTIME.MAX_OUTPUT
        assert tuple(pass_fds) == ()
        self.runtime_calls.append(command)
        self.calls.append(
            {"argv": command, "env": dict(env), "timeout": timeout, "pass_fds": ()}
        )
        joined = " ".join(command)
        if self.fail_before_effect and self.fail_before_effect in joined:
            self.fail_before_effect = None
            raise APPLY.RUNTIME.CommandTimeout("synthetic pre-effect failure")
        if command[:2] == ("unshare", "--net"):
            return self._private_publish(command)
        for handler in (
            self._docker_lifecycle,
            self._proc_result,
            self._netns_command,
            self._file_or_frr_command,
            self._ovs_vsctl,
            self._ovsdb,
            self._ovn_readback,
        ):
            value = handler(command)
            if value is not None:
                return value
        network = self._network_command(command)
        if network is not None:
            return self._network_result(command, *network)
        # Admission-only reads and the owned M03 lifecycle remain the genuine
        # producer FakeRunner surface.
        self.calls.pop()
        return super().run(
            command,
            env=env,
            timeout=timeout,
            pass_fds=pass_fds,
            max_output_bytes=max_output_bytes,
        )

    def reset_runtime_for_session_close(self) -> None:
        for name in ("dci-client-2", "dci-x05-peer-2"):
            entry = self.containers.pop(name, None)
            if entry is not None:
                self.container_by_id.pop(entry["id"], None)
                self.process_start.pop(entry["pid"], None)
                self.pid_to_scope.pop(entry["pid"], None)
                self.netns_inode.pop(entry["pid"], None)
                self.mntns_inode.pop(entry["pid"], None)
            self.links.pop(name, None)
            self.routes.pop(name, None)
            self.files.pop(name, None)
            self.directories.pop(name, None)
            self.frr_processes.pop(name, None)
        for scope, links in list(self.links.items()):
            if "/x05-tenant-" in scope:
                del self.links[scope]
                self.routes.pop(scope, None)
                continue
            for name, link in list(links.items()):
                if link.alias == self.config.owner or name.startswith("ovnvrf") and name != "ovnvrf-tenant":
                    del links[name]
        self.named_netns = {name: {} for name in self.named_netns}
        self.ovs_ports.clear()
        self.ovs_external["ovn-chassis-2"] = {"ovn-evpn-local-ip": "50100-170.168.0.6"}
        self.gateway_extension = {"ovn-gw-1": False, "ovn-gw-2": False}
        self.nb_forward = False


def fdinfo_for(descriptor: int) -> bytes:
    info = os.fstat(descriptor)
    flags = os.O_RDWR
    if not os.get_inheritable(descriptor):
        flags |= getattr(os, "O_CLOEXEC", 0)
    return SUPPORT.lock_fdinfo_literal(
        flags="0" + format(flags, "o"),
        pid=str(os.getpid()),
        major=format(os.major(info.st_dev), "02x"),
        minor=format(os.minor(info.st_dev), "02x"),
        inode=str(info.st_ino),
    )


@contextlib.contextmanager
def admitted_builder(
    *,
    null_labels: Sequence[str] = (),
    empty_original_image_labels: bool = False,
) -> Iterator[tuple[Any, Any, Any, Any]]:
    verify_worktree_pins()
    with tempfile.TemporaryDirectory(
        dir=pathlib.Path(tempfile.gettempdir()).resolve()
    ) as directory:
        config = SUPPORT.make_config(pathlib.Path(directory))
        runtime_root = config.x05_marker_path.parent.parent
        runtime_root.mkdir(mode=0o700)
        runtime_root.chmod(0o700)
        runtime_info = runtime_root.lstat()
        assert (
            stat.S_ISDIR(runtime_info.st_mode)
            and stat.S_IMODE(runtime_info.st_mode) == 0o700
            and runtime_info.st_uid == config.required_uid
        )
        runner = RuntimeFakeRunner(
            config,
            empty_original_image_labels=empty_original_image_labels,
        )
        runner.null_label_names.update(null_labels)
        session = APPLY.RUNTIME.AdmissionSession(config, runner)
        patcher = (
            mock.patch.object(
                APPLY.RUNTIME,
                "_read_lock_fdinfo_bytes",
                side_effect=fdinfo_for,
            )
            if sys.platform != "linux"
            else contextlib.nullcontext()
        )
        with patcher:
            session.__enter__()
            try:
                prepared = session.admit()
                session.consume(prepared)
                builder = APPLY.RuntimeBuilder.from_admission(prepared)
                yield builder, runner, session, prepared
            finally:
                runner.reset_runtime_for_session_close()
                with contextlib.suppress(FileNotFoundError):
                    config.x05_marker_path.unlink()
                with contextlib.suppress(FileNotFoundError):
                    (config.evidence_path / APPLY.CAPTURE_PID_NAME).unlink()
                session.close()


def write_forged_stopped_observation(builder: Any) -> pathlib.Path:
    contract = builder.capture_bindings()
    captures = []
    for index, point in enumerate(contract["points"], 1):
        argv = ["tcpdump", "-i", point["interfaces"][0]["name"], "-w", f"{point['id']}.pcap"]
        captures.append(
            {
                "id": point["id"],
                "pid": 9000 + index,
                "start_ticks": 700000 + index,
                "argv": argv,
                "argv_sha256": builder._command_digest(argv),
                "target_sha256": point["target_sha256"],
                "started_at_ns": 100 + index,
                "stop_intent_at_ns": 200 + index,
                "reaped_at_ns": 300 + index,
                "wait_returncode": 0,
                "reaped": True,
            }
        )
    value = {
        "schema": APPLY.CAPTURE_PID_SCHEMA,
        "owner": contract["owner"],
        "run_hex": contract["run_hex"],
        "state": "STOPPED",
        "builder_marker_sha256": contract["marker_sha256"],
        "runtime_journal_path": contract["runtime_journal_path"],
        "runtime_journal_sha256": contract["runtime_journal_sha256"],
        "runtime_journal_head_sha256": contract["runtime_journal_head_sha256"],
        "captures": captures,
    }
    path = pathlib.Path(contract["pid_journal"]["path"])
    path.write_bytes(APPLY._canonical(value))
    path.chmod(0o600)
    return path


def stopped_successor_binding_checks() -> None:
    """A canonical detached replacement is data, never cleanup authority."""
    with tempfile.TemporaryDirectory() as directory:
        path = pathlib.Path(directory) / APPLY.CAPTURE_PID_NAME
        fields = [
            "id",
            "pid",
            "start_ticks",
            "argv",
            "argv_sha256",
            "target_sha256",
            "started_at_ns",
            "stop_intent_at_ns",
            "reaped_at_ns",
            "wait_returncode",
            "reaped",
        ]
        points = [
            {"id": capture_id, "target_sha256": digest("target-" + capture_id)}
            for capture_id in APPLY.CAPTURE_POINT_IDS
        ]
        contract = {
            "owner": "binding-test",
            "run_hex": "abc123",
            "marker_sha256": "1" * 64,
            "runtime_journal_path": str(path.parent / "runtime.jsonl"),
            "runtime_journal_sha256": "2" * 64,
            "runtime_journal_head_sha256": "3" * 64,
            "points": points,
            "pid_journal": {"path": str(path), "entry_fields": fields},
        }
        slots = {
            point["id"]: {
                "id": point["id"],
                "pid": None,
                "start_ticks": None,
                "argv": ["tcpdump", "-i", "any"],
                "argv_sha256": APPLY.RuntimeBuilder._command_digest(
                    ("tcpdump", "-i", "any")
                ),
                "target_sha256": point["target_sha256"],
                "started_at_ns": None,
                "stop_intent_at_ns": 100,
                "reaped_at_ns": None,
                "wait_returncode": None,
                "reaped": False,
            }
            for point in points
        }
        value = {
            "schema": APPLY.CAPTURE_PID_SCHEMA,
            "owner": contract["owner"],
            "run_hex": contract["run_hex"],
            "state": "STOPPED",
            "builder_marker_sha256": contract["marker_sha256"],
            "runtime_journal_path": contract["runtime_journal_path"],
            "runtime_journal_sha256": contract["runtime_journal_sha256"],
            "runtime_journal_head_sha256": contract[
                "runtime_journal_head_sha256"
            ],
            "captures": [
                {name: copy.deepcopy(slots[point["id"]][name]) for name in fields}
                for point in points
            ],
        }
        raw = APPLY._canonical(value)
        path.write_bytes(raw)
        path.chmod(0o600)
        marker_base = b"reviewed-built-marker\n"
        marker = {
            "state": "STOPPED",
            "sequence": 1,
            "previous_sha256": "4" * 64,
            "pid_journal_sha256": hashlib.sha256(raw).hexdigest(),
        }
        marker_lines = (
            "capture_schema=p004-x05-capture-marker-v1",
            "capture_state=STOPPED",
            "capture_sequence=1",
            "capture_previous_marker_sha256=" + marker["previous_sha256"],
            "capture_pid_journal_sha256=" + marker["pid_journal_sha256"],
            "capture_started_count=0",
            "capture_ready_count=0",
            "capture_packet_status=ERROR",
        )
        marker_bytes = marker_base + ("\n".join(marker_lines) + "\n").encode(
            "ascii"
        )
        marker["sha256"] = hashlib.sha256(marker_bytes).hexdigest()
        capture = types.SimpleNamespace(
            _slots=slots,
            _pid_raw=raw,
            _pid_sha256=hashlib.sha256(raw).hexdigest(),
            _last_marker=copy.deepcopy(marker),
            _handles=[],
            _started_count=0,
            _ready_count=0,
            _packet_status="ERROR",
        )
        builder = object.__new__(APPLY.RuntimeBuilder)
        builder._capture_contract = contract
        builder._capture_last_completed_marker = copy.deepcopy(marker)
        builder._capture_built_marker_bytes = marker_base
        builder._marker_bytes = marker_bytes
        builder._config = types.SimpleNamespace(required_uid=os.getuid())
        builder._owner = contract["owner"]
        builder._run_hex = contract["run_hex"]
        builder._capture_session = capture
        assert builder._bound_stopped_capture_raw(capture) == raw

        replacement = copy.deepcopy(value)
        replacement["captures"][0]["argv"] = ["tcpdump", "-i", "foreign"]
        replacement["captures"][0]["argv_sha256"] = (
            APPLY.RuntimeBuilder._command_digest(("tcpdump", "-i", "foreign"))
        )
        replacement_raw = APPLY._canonical(replacement)
        path.write_bytes(replacement_raw)
        path.chmod(0o600)
        assert builder._read_stopped_capture_observation()["state"] == "STOPPED"
        expect_error(
            APPLY.SecurityError,
            lambda: builder._bound_stopped_capture_raw(capture),
            "self-consistent STOPPED replacement",
        )
        assert capture._pid_raw == raw
        assert builder._capture_last_completed_marker == marker
        path.write_bytes(raw)
        path.chmod(0o600)
        assert builder._bound_stopped_capture_raw(capture) == raw


def expect_error(error_type: type[BaseException], function: Callable[[], Any], label: str) -> BaseException:
    try:
        function()
    except error_type as exc:
        return exc
    raise AssertionError("expected failure: " + label)


def exercise_inverse_helpers(builder: Any) -> dict[str, Any]:
    """Exercise fixed inverse helpers without pretending capture authority."""
    for resource_id in (
        "container:ovn-gw-1/frr-config-delta//etc/frr/frr.conf:ovnvrf300",
        "container:ovn-gw-2/frr-config-delta//etc/frr/frr.conf:ovnvrf400",
    ):
        builder._remove_gateway_frr(resource_id)
    for resource_id in (
        APPLY.CLIENT_CONTAINER_ID,
        "container:ovn-chassis-2/frr-pathspace/x05",
        "container:dci-x05-peer-2/frr-pathspace/x05",
    ):
        builder._stop_frr(resource_id)
    for chassis, suffix in (("ovn-chassis-1", "a"), ("ovn-chassis-2", "b")):
        namespace = "x05-tenant-" + suffix + "-vm"
        outer = "x05-tenant-" + suffix + "-p"
        inner = "x05-tenant-" + suffix
        builder._remove_ovs_port(
            "isolated-sentinel-ovs-" + suffix,
            f"container:{chassis}/ovs-port-interface/{outer}",
        )
        builder._delete_veth_pair(
            f"container:{chassis}/linux-veth/{outer}",
            f"netns:{chassis}:{namespace}/linux-veth/{inner}",
        )
        builder._delete_netns(f"container:{chassis}/netns/{namespace}")
    for resource_id in (
        APPLY.CLIENT_ETH1_ID,
        APPLY.CLIENT_ETH2_ID,
        APPLY.PEER_ETH1_ID,
    ):
        builder._remove_ovs_port("isolated-host-ovs", resource_id)
    for resource_id in (
        APPLY.CLIENT_ETH1_ID,
        APPLY.CLIENT_ETH2_ID,
        APPLY.PEER_ETH1_ID,
    ):
        builder._delete_attachment(resource_id)
    builder._remove_container(APPLY.CLIENT_CONTAINER_ID)
    for resource_id in (
        "container:dci-x05-peer-2/linux-dummy/evpn-x05-pr",
        "container:dci-x05-peer-2/linux-vxlan/vxlan-x05-pr",
        "container:dci-x05-peer-2/linux-bridge/br-x05-peer",
        "container:dci-x05-peer-2/linux-vrf/vrf-x05-peer",
    ):
        builder._delete_single_link(resource_id)
    builder._remove_container(APPLY.PEER_CONTAINER_ID)
    for gateway, number in (("ovn-gw-1", 300), ("ovn-gw-2", 400)):
        builder._remove_ovs_port(
            "isolated-gateway-ovs-" + str(number),
            f"container:{gateway}/ovs-port-interface/bgpvrf{number}-ovs",
        )
        builder._delete_veth_pair(
            f"container:{gateway}/linux-veth/bgpvrf{number}-ovs",
            f"container:{gateway}/linux-veth/bgpvrf{number}",
        )
    for resource_id in (
        "container:ovn-chassis-2/linux-dummy/evpn-x05-b",
        "container:ovn-chassis-2/linux-vxlan/vxlan-x05-b",
        "container:ovn-chassis-2/linux-bridge/br-x05-b",
    ):
        builder._delete_single_link(resource_id)
    builder._change_external_ids(inverse=True)
    inverse = builder._inverse_nb()
    assert builder._built_bindings is not None
    generated = []
    for resource_id, binding in sorted(builder._built_bindings["generated_vrfs"].items()):
        generated.append(
            builder._wait_generated_absent(
                resource_id, builder._targets[binding["target"]["label"]]
            )
        )
    runtime = builder._runtime_absence_readback()
    immutable = builder._immutable_baseline_readback()
    return {
        "inverse": inverse,
        "generated": generated,
        "runtime": runtime,
        "immutable": immutable,
    }


def static_contract_checks() -> None:
    assert "start_new_session=False" in APPLY.PRIVATE_LINK_HELPER
    assert "start_new_session=True" not in APPLY.PRIVATE_LINK_HELPER
    assert "close_fds=True" in APPLY.PRIVATE_LINK_HELPER
    assert "selectors.DefaultSelector" in APPLY.PRIVATE_LINK_HELPER
    assert "remaining = deadline - time.monotonic()" in APPLY.PRIVATE_LINK_HELPER
    assert "pass_fds" not in APPLY.PRIVATE_LINK_HELPER
    assert APPLY.KNOWN_VXLAN_STDERR == b"info: Using default fan map value (33)\n"
    assert APPLY.RuntimeBuilder._container_labels(None, "null") == {}
    assert APPLY.RuntimeBuilder._container_labels({}, "empty") == {}
    for malformed in ({"x": 1}, [], "labels"):
        expect_error(
            APPLY.SecurityError,
            lambda malformed=malformed: APPLY.RuntimeBuilder._container_labels(
                malformed, "malformed"
            ),
            "malformed labels",
        )
    checker = object.__new__(APPLY.RuntimeBuilder)
    command = ("true",)
    valid = APPLY.RUNTIME.CommandResult(command, 0, b"", b"", 0.01)
    assert checker._checked_result(valid, command) is valid

    class BytesSubclass(bytes):
        pass

    class StringSubclass(str):
        pass

    malformed_results = (
        APPLY.RUNTIME.CommandResult(["true"], 0, b"", b"", 0.01),
        APPLY.RUNTIME.CommandResult((StringSubclass("true"),), 0, b"", b"", 0.01),
        APPLY.RUNTIME.CommandResult(command, 0, BytesSubclass(), b"", 0.01),
        APPLY.RUNTIME.CommandResult(command, 0, b"", BytesSubclass(), 0.01),
        APPLY.RUNTIME.CommandResult(command, 0, b"", b"", True),
    )
    for malformed_result in malformed_results:
        expect_error(
            APPLY.AmbiguousEffect,
            lambda malformed_result=malformed_result: checker._checked_result(
                malformed_result, command
            ),
            "non-exact runner result field",
        )
    stream = io.StringIO()
    with contextlib.redirect_stdout(stream):
        assert APPLY.main(["--dry-run"]) == 0
    dry = json.loads(stream.getvalue())
    assert dry["status"] == "DRY_RUN" and dry["live_enabled"] is False
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(
        io.StringIO()
    ):
        assert APPLY.main(["--execute"]) == 75


def _current_umask() -> int:
    current = os.umask(0)
    os.umask(current)
    return current


def umask_fixture_checks() -> None:
    """Keep the fake producer hermetic without relaxing the production guard."""
    original = _current_umask()
    previous = os.umask(0o002)
    try:
        assert previous == original
        with admitted_builder() as (builder, _runner, _session, _prepared):
            runtime_root = builder._config.x05_marker_path.parent.parent
            assert stat.S_IMODE(runtime_root.lstat().st_mode) == 0o700
            builder._create_journal_and_marker()
            assert builder._config.x05_marker_path.is_file()
            assert not builder._unknown
    finally:
        os.umask(previous)
    assert _current_umask() == original

    previous = os.umask(0o002)
    try:
        assert previous == original
        with admitted_builder() as (builder, _runner, _session, _prepared):
            runtime_root = builder._config.x05_marker_path.parent.parent
            runtime_root.chmod(0o775)
            try:
                failure = expect_error(
                    APPLY.AmbiguousEffect,
                    builder._create_journal_and_marker,
                    "group-writable production marker ancestor",
                )
                assert "local durable effect outcome is unknown" in str(failure)
                assert builder._unknown
                assert not builder._config.x05_marker_path.parent.exists()
            finally:
                runtime_root.chmod(0o700)
    finally:
        os.umask(previous)
    assert _current_umask() == original


def terminal_g7_checks() -> dict[str, Any]:
    """Exercise the actual private terminal friend without laboratory effects."""

    published: list[dict[str, Any]] = []
    publisher = object.__new__(APPLY.RuntimeBuilder)
    publisher._consume_lock = __import__("threading").RLock()
    publisher._journal = types.SimpleNamespace(
        binding=lambda: {
            "artifact_path": "/fixture/runtime.jsonl",
            "artifact_sha256": "3" * 64,
            "journal_head_sha256": "4" * 64,
            "journal_count": 1,
        },
        append=lambda *_args, **_kwargs: {},
    )
    publisher._verify_object_bindings = lambda: None
    publisher._session = object()
    publisher._prepared = object()
    with mock.patch.object(
        APPLY,
        "_SESSION_RECORD_EXECUTION_EVENT",
        side_effect=lambda _session, _prepared, event, detail: published.append(
            {"event": event, "detail": copy.deepcopy(detail)}
        ) or {"sequence": 1, "event_sha256": "5" * 64},
    ):
        APPLY.RuntimeBuilder._publish(
            publisher,
            "x05-terminal-cleanup",
            "x05-cleaned-complete",
            {
                "status": "VERIFIED",
                "operation": "x05-marker-remove-complete",
                "resource_ids": [APPLY.MARKER_ID],
                "state": "X05_CLEANED",
            },
        )
    assert published == [
        {
            "event": "x05-terminal-cleanup",
            "detail": {
                "stage": "x05-cleaned-complete",
                "status": "VERIFIED",
                "operation": "x05-marker-remove-complete",
                "resource_ids": [APPLY.MARKER_ID],
                "artifact_path": "/fixture/runtime.jsonl",
                "artifact_sha256": "3" * 64,
                "journal_head_sha256": "4" * 64,
                "journal_count": 1,
                "state": "X05_CLEANED",
            },
        }
    ]

    def candidate(directory: pathlib.Path) -> tuple[Any, Any, list[str]]:
        marker_path = directory / "active"
        marker_path.write_bytes(b"same-builder-stopped-marker\n")
        marker_path.chmod(0o600)
        marker_raw, marker_identity = APPLY._read_regular(
            marker_path, mode=0o600, uid=os.getuid()
        )
        parent = marker_path.parent.lstat()
        m03 = {"owner": "fixture", "marker": "owned"}
        session = types.SimpleNamespace(
            _m03_ownership_sha256=APPLY.RUNTIME._digest(m03)
        )
        verify_argv = (str(directory / "labctl"), "dci", "verify", "--m03")
        session_labctl = lambda action, *, m03: APPLY.RUNTIME.CommandResult(
            verify_argv, 0, b"M03 PASS\n", b"", 0.01
        )
        capture = types.SimpleNamespace(
            _released=False,
            _retention_complete=False,
            _retention_unknown=False,
            _last_marker=None,
        )
        completed = {
            "state": "STOPPED",
            "sequence": 8,
            "previous_sha256": "1" * 64,
            "sha256": hashlib.sha256(marker_raw).hexdigest(),
            "pid_journal_sha256": "2" * 64,
        }
        capture._last_marker = copy.deepcopy(completed)
        events: list[str] = []
        journal = types.SimpleNamespace(
            verify_current=lambda: None,
            binding=lambda: {
                "artifact_path": str(directory / "runtime.jsonl"),
                "artifact_sha256": "3" * 64,
                "journal_head_sha256": "4" * 64,
                "journal_count": 1,
            },
        )
        builder = object.__new__(APPLY.RuntimeBuilder)
        builder._config = types.SimpleNamespace(
            test_only_paths=True,
            required_uid=os.getuid(),
            x05_marker_path=marker_path,
            labctl_path=directory / "labctl",
            evidence_path=directory,
        )
        builder._consume_lock = __import__("threading").RLock()
        builder._state = "COMPENSATED"
        builder._unknown = False
        builder._terminal_result = None
        builder._cleanup_result = {"status": "PASS"}
        builder._final_absence = {"status": "PASS"}
        builder._capture_session = capture
        builder._capture_last_completed_marker = copy.deepcopy(completed)
        builder._marker_bytes = marker_raw
        builder._marker_identity = marker_identity
        builder._marker_directory_identity = (
            parent.st_dev,
            parent.st_ino,
            parent.st_mode,
            parent.st_uid,
        )
        builder._collector = object()
        builder._profile_owner = "fixture-owner"
        builder._session = session
        builder._prepared = object()
        builder._owner = "labctl-x05-aabbcc"
        builder._run_hex = "aabbcc"
        builder._journal = journal
        builder._session_labctl_call = session_labctl
        builder._journal_append = (
            lambda _kind, stage, _detail: events.append("journal:" + stage) or {}
        )
        builder._terminal_published_details = []

        def publish(_event: str, stage: str, detail: Any) -> None:
            events.append("publish:" + stage)
            builder._terminal_published_details.append(copy.deepcopy(detail))

        builder._publish = publish
        retained = {
            "directory": str(directory / "completed-captures"),
            "status": "VERIFIED",
            "files": [],
        }

        def release(value: Any) -> dict[str, Any]:
            assert value is capture
            value._released = True
            value._retention_complete = True
            return {"status": "PASS", "released": True}

        module = types.SimpleNamespace(_CAPTURE_SESSION_RELEASE=release)
        builder._verify_authority = lambda: None
        builder._verify_capture_creator = lambda value: module
        builder._verify_stopped_captures = lambda: {
            "status": "PASS",
            "state": "STOPPED",
            "ownership_status": "PASS",
            "packet_status": "PASS",
        }
        builder._verify_final_absence = lambda: {"status": "PASS"}
        builder._verify_retained_capture_map = lambda value: copy.deepcopy(retained)
        builder._verify_object_bindings = lambda: None
        builder._verify_sources = lambda: None
        return builder, m03, events

    def run_fault(stage: str) -> tuple[Any, pathlib.Path, BaseException]:
        directory = pathlib.Path(tempfile.mkdtemp())
        builder, m03, _events = candidate(directory)
        APPLY._TEST_TERMINAL_FAULT = stage
        with mock.patch.object(
            APPLY,
            "_COLLECTOR_OWNED_M03_IDENTITY",
            return_value=m03,
        ), mock.patch.object(APPLY, "_SESSION_VERIFY_EXECUTION", return_value=None):
            error = expect_error(
                APPLY.AmbiguousEffect,
                builder._finalize_x05_cleanup,
                "terminal fault " + stage,
            )
        APPLY._TEST_TERMINAL_FAULT = None
        return builder, directory, error

    try:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = pathlib.Path(raw_directory)
            builder, m03, events = candidate(directory)
            with mock.patch.object(
                APPLY,
                "_COLLECTOR_OWNED_M03_IDENTITY",
                return_value=m03,
            ), mock.patch.object(
                APPLY, "_SESSION_VERIFY_EXECUTION", return_value=None
            ):
                result = builder._finalize_x05_cleanup()
            assert result["status"] == "PASS"
            assert result["state"] == "X05_CLEANED"
            assert result["marker_absent"] is True
            assert builder._state == "X05_CLEANED" and not builder._unknown
            assert not builder._config.x05_marker_path.exists()
            assert events[-2:] == [
                "journal:x05-cleaned",
                "publish:x05-cleaned-complete",
            ]
            assert builder._terminal_published_details[-1]["state"] == "X05_CLEANED"

        before, before_directory, _ = run_fault("before-marker-unlink")
        try:
            assert before._state == "CLEANUP_FAILED" and before._unknown
            assert before._config.x05_marker_path.exists()
        finally:
            __import__("shutil").rmtree(before_directory)

        after, after_directory, _ = run_fault("after-marker-unlink")
        try:
            assert after._state == "TERMINAL_UNKNOWN" and after._unknown
            assert not after._config.x05_marker_path.exists()
            expect_error(
                APPLY.SecurityError,
                after._finalize_x05_cleanup,
                "terminal replay after unknown unlink",
            )
        finally:
            __import__("shutil").rmtree(after_directory)

        fsync_directory = pathlib.Path(tempfile.mkdtemp())
        try:
            fsync_failure, m03, _events = candidate(fsync_directory)
            with mock.patch.object(
                APPLY,
                "_COLLECTOR_OWNED_M03_IDENTITY",
                return_value=m03,
            ), mock.patch.object(
                APPLY, "_SESSION_VERIFY_EXECUTION", return_value=None
            ), mock.patch.object(
                APPLY.os, "fsync", side_effect=OSError("synthetic directory fsync")
            ):
                expect_error(
                    OSError,
                    fsync_failure._finalize_x05_cleanup,
                    "terminal directory fsync failure",
                )
            assert fsync_failure._state == "TERMINAL_UNKNOWN"
            assert fsync_failure._unknown
            assert not fsync_failure._config.x05_marker_path.exists()
        finally:
            __import__("shutil").rmtree(fsync_directory)

        publication_directory = pathlib.Path(tempfile.mkdtemp())
        try:
            publication, m03, events = candidate(publication_directory)
            original_publish = publication._publish

            def fail_completion(event: str, stage: str, detail: Any) -> None:
                if stage == "x05-cleaned-complete":
                    raise RuntimeError("synthetic terminal publication")
                original_publish(event, stage, detail)

            publication._publish = fail_completion
            with mock.patch.object(
                APPLY,
                "_COLLECTOR_OWNED_M03_IDENTITY",
                return_value=m03,
            ), mock.patch.object(
                APPLY, "_SESSION_VERIFY_EXECUTION", return_value=None
            ):
                expect_error(
                    RuntimeError,
                    publication._finalize_x05_cleanup,
                    "terminal completion publication failure",
                )
            assert publication._state == "TERMINAL_UNKNOWN"
            assert publication._unknown
            assert not publication._config.x05_marker_path.exists()
            assert events[-1] == "journal:x05-cleaned"
        finally:
            __import__("shutil").rmtree(publication_directory)

        with tempfile.TemporaryDirectory() as raw_directory:
            directory = pathlib.Path(raw_directory)
            retarget, m03, _events = candidate(directory)
            replacement = directory / "replacement"
            replacement.write_bytes(retarget._marker_bytes)
            replacement.chmod(0o600)
            os.replace(replacement, retarget._config.x05_marker_path)
            with mock.patch.object(
                APPLY,
                "_COLLECTOR_OWNED_M03_IDENTITY",
                return_value=m03,
            ), mock.patch.object(
                APPLY, "_SESSION_VERIFY_EXECUTION", return_value=None
            ):
                expect_error(
                    APPLY.SecurityError,
                    retarget._finalize_x05_cleanup,
                    "terminal same-byte marker retarget",
                )
            assert retarget._config.x05_marker_path.exists()
            assert retarget._state == "CLEANUP_FAILED" and retarget._unknown
    finally:
        APPLY._TEST_TERMINAL_FAULT = None
    return {
        "success": 1,
        "state_publications": 1,
        "faults": 2,
        "fsync_failures": 1,
        "publication_failures": 1,
        "retargets": 1,
    }


def callable_binding_checks() -> None:
    command = ("docker", "container", "inspect", "ovn-central-az1")
    with admitted_builder() as (builder, runner, _session, _prepared):
        wrapper_first = builder._runner.run
        wrapper_second = builder._runner.run
        delegate_first = runner.run
        delegate_second = runner.run
        assert wrapper_first is not wrapper_second
        assert delegate_first is not delegate_second
        assert APPLY._same_bound_method(
            wrapper_first,
            wrapper_second,
            owner=builder._runner,
            implementation=APPLY._INCIDENT_RUNNER_RUN,
        )
        assert APPLY._same_bound_method(
            delegate_first,
            delegate_second,
            owner=runner,
            implementation=type(runner).run,
        )
        builder._verify_object_bindings()
        before = len(runner.runtime_calls)
        result = builder._dispatch(command)
        assert result.returncode == 0
        assert len(runner.runtime_calls) == before + 1

    for target in ("wrapper", "delegate"):
        with admitted_builder() as (builder, runner, _session, _prepared):
            forged_calls: list[tuple[str, ...]] = []

            def forged(
                argv: Sequence[str],
                *,
                env: Mapping[str, str],
                timeout: float,
                pass_fds: Sequence[int] = (),
                max_output_bytes: int,
            ) -> Any:
                del env, timeout, pass_fds, max_output_bytes
                forged_calls.append(tuple(argv))
                return builder._runner_delegate.result(tuple(argv), b"forged")

            victim = builder._runner if target == "wrapper" else runner
            before_runtime = len(runner.runtime_calls)
            before_effects = len(runner.effect_calls)
            victim.run = forged
            try:
                failure = expect_error(
                    APPLY.SecurityError,
                    lambda: builder._dispatch(command),
                    target + " direct dispatch shadow",
                )
                expected_context = "runner" if target == "wrapper" else "delegate"
                assert expected_context in str(failure)
                expect_error(
                    APPLY.SecurityError,
                    builder.build,
                    target + " public build shadow",
                )
                expect_error(
                    APPLY.SecurityError,
                    lambda: builder._effect(
                        "callable-shadow-effect",
                        [APPLY.MARKER_ID],
                        command,
                        lambda result: result,
                    ),
                    target + " effect-entry shadow",
                )
                assert not forged_calls
                assert len(runner.runtime_calls) == before_runtime
                assert len(runner.effect_calls) == before_effects
                assert builder._journal is None
                assert builder._state == "ADMITTED" and not builder._unknown
            finally:
                del victim.run
            builder._verify_object_bindings()

    for target in ("wrapper", "delegate"):
        with admitted_builder() as (builder, runner, _session, _prepared):
            builder._create_journal_and_marker()
            marker = builder._config.x05_marker_path.read_bytes()
            victim = builder._runner if target == "wrapper" else runner
            forged_calls: list[tuple[str, ...]] = []

            def forged_after_effect(
                argv: Sequence[str],
                *,
                env: Mapping[str, str],
                timeout: float,
                pass_fds: Sequence[int] = (),
                max_output_bytes: int,
            ) -> Any:
                del env, timeout, pass_fds, max_output_bytes
                forged_calls.append(tuple(argv))
                return runner.result(tuple(argv), b"forged")

            def replace_after_effect(_command: tuple[str, ...]) -> None:
                victim.run = forged_after_effect

            runner.after_effect = replace_after_effect
            before_effects = len(runner.effect_calls)
            try:
                failure = expect_error(
                    APPLY.AmbiguousEffect,
                    lambda: builder._create_container(APPLY.CLIENT_CONTAINER_ID),
                    target + " replacement during effect",
                )
                assert "binding changed after dispatch" in str(failure)
                assert len(runner.effect_calls) == before_effects + 1
                assert not forged_calls
                assert builder._unknown
                assert builder._config.x05_marker_path.read_bytes() == marker
                assert builder._journal is not None
                rows = [
                    json.loads(line)
                    for line in builder._journal.path.read_text().splitlines()
                ]
                relevant = [
                    row
                    for row in rows
                    if row["stage"] == "container-create-dci-client-2"
                ]
                assert any(
                    row["kind"] == "effect-intent"
                    and row["detail"].get("status") == "INTENT"
                    for row in relevant
                )
                assert any(
                    row["kind"] == "effect-outcome"
                    and row["detail"].get("status") == "UNKNOWN"
                    for row in relevant
                )
                assert not any(
                    row["detail"].get("status") == "VERIFIED"
                    for row in relevant
                )
            finally:
                runner.after_effect = None
                if "run" in vars(victim):
                    del victim.run
            retry_effects = len(runner.effect_calls)
            expect_error(
                APPLY.SecurityError,
                lambda: builder._effect(
                    "callable-drift-retry",
                    [APPLY.CLIENT_CONTAINER_ID],
                    command,
                    lambda result: result,
                ),
                target + " replacement no reissue",
            )
            assert len(runner.effect_calls) == retry_effects


def fault_window_checks() -> None:
    cases = ("before", "during", "after", "between-moves")
    for case in cases:
        with admitted_builder() as (builder, runner, _session, _prepared):
            builder._create_journal_and_marker()
            target = builder._original_target("ovn-gw-1")
            stage = "fault-" + case
            if case == "before":
                runner.fail_before_effect = "unshare --net"
            elif case == "during":
                runner.fail_effect = "unshare --net"
            elif case == "after":
                runner.fail_after_effect = "unshare --net"
            else:
                runner.fail_between_moves = True
            expect_error(
                APPLY.AmbiguousEffect,
                lambda: builder._private_publish(
                    stage,
                    (
                        "container:ovn-gw-1/linux-veth/bgpvrf300-ovs",
                        "container:ovn-gw-1/linux-veth/bgpvrf300",
                    ),
                    kind="veth",
                    names=("bgpvrf300-ovs", "bgpvrf300"),
                    targets=(target, target),
                ),
                stage,
            )
            assert builder._unknown and builder._state == "INTENT"
            assert builder._marker_bytes is not None
            assert b"state=INTENT\n" in builder._marker_bytes
            matching = [
                call for call in runner.effect_calls if call[:2] == ("unshare", "--net")
            ]
            assert len(matching) == (0 if case == "before" else 1)
            if case == "between-moves":
                left = runner.links["ovn-gw-1"]["bgpvrf300-ovs"]
                assert left.alias == builder._owner
                assert "bgpvrf300" not in runner.links["ovn-gw-1"]
            before_retry = len(runner.effect_calls)
            expect_error(
                APPLY.SecurityError,
                lambda: builder._private_publish(
                    stage + "-retry",
                    (
                        "container:ovn-gw-1/linux-veth/bgpvrf300-ovs",
                        "container:ovn-gw-1/linux-veth/bgpvrf300",
                    ),
                    kind="veth",
                    names=("bgpvrf300-ovs", "bgpvrf300"),
                    targets=(target, target),
                ),
                stage + " no retry",
            )
            assert len(runner.effect_calls) == before_retry
            assert builder._journal is not None
            rows = [json.loads(line) for line in builder._journal.path.read_text().splitlines()]
            relevant = [row for row in rows if row["stage"] == stage]
            assert any(row["kind"] == "effect-intent" for row in relevant)
            assert any(
                row["kind"] == "effect-outcome"
                and row["detail"].get("status") == "UNKNOWN"
                for row in relevant
            )


def full_build_and_guard_checks() -> dict[str, Any]:
    started = time.monotonic()
    with admitted_builder(
        null_labels=("ovn-gw-1",),
        empty_original_image_labels=True,
    ) as (
        builder,
        runner,
        session,
        prepared,
    ):
        assert runner._container_row("ovn-gw-1")["Config"]["Labels"] is None
        assert runner.original_image_labels == {}
        assert runner._container_row("ovn-gw-2")["Config"]["Labels"] == {}
        original_runner = session.runner
        original_lock = session._consume_lock
        original_events = session.events
        built = builder.build()
        assert built["status"] == "PASS" and built["state"] == "BUILT"
        assert set(built["completed_resource_ids"]) == APPLY.BASE_MUTABLE_IDS
        assert set(built["generated_resource_ids"]) == APPLY.GENERATED_VRF_IDS
        assert len(builder._resources) == 43 and len(builder._completed_ids) == 32
        assert built["inventory"] == {
            "total": 43,
            "mutable_base": 32,
            "marker": 1,
            "generated_observation_only": 3,
            "lsp_parent_control": 1,
            "capture": 6,
        }
        detached = copy.deepcopy(built)
        built["bindings"].clear()
        assert builder._built_result == detached

        private_calls = [call for call in runner.effect_calls if call[:2] == ("unshare", "--net")]
        assert private_calls
        for call in private_calls:
            specification = json.loads(call[-1])
            assert specification["alias"] == builder._owner
            assert specification["kind"] in {"veth", "bridge", "vxlan", "dummy", "vrf"}
            assert specification["maximum_output"] == APPLY.PRIVATE_HELPER_OUTPUT
            assert all(row["pid"] > 0 for row in specification["targets"])
        joined_effects = [" ".join(call) for call in runner.effect_calls]
        assert not any("write memory" in command for command in joined_effects)
        assert not any(
            "ip link del" in command and "ovnvrf" in command
            for command in joined_effects
        )
        assert runner.nb_effects == 1
        assert builder._marker_bytes is not None
        assert b"state=BUILT\n" in builder._marker_bytes
        assert builder._journal is not None
        builder._journal.verify()

        contract = builder.capture_bindings()
        assert tuple(point["id"] for point in contract["points"]) == APPLY.CAPTURE_POINT_IDS
        assert [
            [interface["name"] for interface in point["interfaces"]]
            for point in contract["points"]
        ] == [
            ["br-ovn", builder._anchors["m03_peer"]["ovs"]["interface_name"], "x05p2e1"],
            ["x05-tenant-a-p", "vxlan_sys_4789"],
            ["x05-tenant-b-p", "vxlan_sys_4789"],
            ["bgpvrf100", "bgpvrf300"],
            ["bgpvrf200", "bgpvrf400"],
        ]
        assert [source["id"] for source in contract["sources"]] == [
            "classic-original",
            "classic-created",
            "evpn-original",
            "evpn-created",
        ]
        assert [source["source"] for source in contract["sources"]] == [
            "10.0.0.1",
            "10.0.0.1",
            "10.250.0.1",
            "10.251.0.1",
        ]
        assert contract["pid_journal"] == {
            "schema": APPLY.CAPTURE_PID_SCHEMA,
            "path": str(builder._config.evidence_path / APPLY.CAPTURE_PID_NAME),
            "required_state": "STOPPED",
            "capture_ids": list(APPLY.CAPTURE_POINT_IDS),
            "entry_fields": [
                "id",
                "pid",
                "start_ticks",
                "argv",
                "argv_sha256",
                "target_sha256",
                "started_at_ns",
                "stop_intent_at_ns",
                "reaped_at_ns",
                "wait_returncode",
                "reaped",
            ],
        }
        write_forged_stopped_observation(builder)
        observation = builder._read_stopped_capture_observation()
        assert observation["state"] == "STOPPED" and len(observation["captures"]) == 5
        cleanup_effects = len(runner.effect_calls)
        cleanup_nb_effects = runner.nb_effects
        not_ready = expect_error(
            APPLY.NotReady, builder.compensate, "forged STOPPED cleanup"
        )
        assert str(not_ready) == (
            "creator-owned CaptureSession is required before compensation"
        )
        assert len(runner.effect_calls) == cleanup_effects
        assert runner.nb_effects == cleanup_nb_effects == 1
        assert builder._state == "BUILT" and not builder._unknown

        builder._verify_stopped_captures = lambda: {
            "schema": "forged-capture-authority",
            "state": "STOPPED",
            "captures": [],
        }
        try:
            shadow = expect_error(
                APPLY.SecurityError,
                builder.compensate,
                "instance capture-stop shadow",
            )
            assert str(shadow) == (
                "runtime capture-stop gate implementation changed"
            )
            assert len(runner.effect_calls) == cleanup_effects
            assert runner.nb_effects == cleanup_nb_effects == 1
            assert builder._state == "BUILT" and not builder._unknown
        finally:
            del builder._verify_stopped_captures

        capture_stop_implementation = APPLY.RuntimeBuilder._verify_stopped_captures
        APPLY.RuntimeBuilder._verify_stopped_captures = lambda self: {
            "schema": "forged-capture-authority",
            "state": "STOPPED",
            "captures": [],
        }
        try:
            shadow = expect_error(
                APPLY.SecurityError,
                builder.compensate,
                "class capture-stop shadow",
            )
            assert str(shadow) == (
                "runtime capture-stop gate implementation changed"
            )
            assert len(runner.effect_calls) == cleanup_effects
            assert runner.nb_effects == cleanup_nb_effects == 1
            assert builder._state == "BUILT" and not builder._unknown
        finally:
            APPLY.RuntimeBuilder._verify_stopped_captures = (
                capture_stop_implementation
            )
        builder._verify_object_bindings()
        expect_error(
            APPLY.SecurityError,
            builder.verify_final_absence,
            "final absence before authorized compensation",
        )

        session.runner = object()
        expect_error(APPLY.SecurityError, builder.capture_bindings, "runner replacement")
        session.runner = original_runner
        session._consume_lock = object()
        expect_error(APPLY.SecurityError, builder.capture_bindings, "mutex replacement")
        session._consume_lock = original_lock
        session.events = object()
        expect_error(APPLY.SecurityError, builder.capture_bindings, "eventlog replacement")
        session.events = original_events
        session.record_execution_event = lambda *_args, **_kwargs: {}
        expect_error(APPLY.SecurityError, builder.capture_bindings, "event method replacement")
        del session.record_execution_event
        assert prepared is builder._prepared and builder._runner is original_runner

        created = runner.containers["dci-client-2"]
        original_id = created["id"]
        created["id"] = digest("foreign-created-container")
        expect_error(APPLY.BuilderError, builder.capture_bindings, "created container ABA")
        created["id"] = original_id

        source_path = next(iter(builder._source_bindings))
        source_identity, source_digest = builder._source_bindings[source_path]
        builder._source_bindings[source_path] = (source_identity, "0" * 64)
        expect_error(APPLY.SecurityError, builder._verify_sources, "source digest binding")
        builder._source_bindings[source_path] = (source_identity, source_digest)

        link = runner.links["host"]["x05c2e1"]
        original_ifindex = link.ifindex
        link.ifindex += 1000
        expect_error(
            APPLY.SecurityError,
            lambda: builder._verify_link_binding(APPLY.CLIENT_ETH1_ID),
            "link ifindex drift",
        )
        link.ifindex = original_ifindex
        namespace_id = "container:ovn-chassis-1/netns/x05-tenant-a-vm"
        namespace_binding = builder._bindings["namespaces"][namespace_id]
        namespace_name = namespace_binding["name"]
        original_inode = runner.named_netns["ovn-chassis-1"][namespace_name]
        runner.named_netns["ovn-chassis-1"][namespace_name] += 1
        expect_error(
            APPLY.SecurityError,
            lambda: builder._verify_netns(namespace_id),
            "namespace inode drift",
        )
        runner.named_netns["ovn-chassis-1"][namespace_name] = original_inode
        ovs_id = APPLY.CLIENT_ETH1_ID
        ovs_binding = builder._bindings["ovs"][ovs_id]
        ovs_row = runner.ovs_ports["host"][ovs_binding["port_name"]]
        original_port_uuid = ovs_row["port_uuid"]
        ovs_row["port_uuid"] = uuid("foreign-port")
        expect_error(
            APPLY.BuilderError,
            lambda: builder._verify_ovs_binding(ovs_id),
            "OVS UUID drift",
        )
        ovs_row["port_uuid"] = original_port_uuid

        effect_count_before_inverse = len(runner.effect_calls)
        inverse = exercise_inverse_helpers(builder)
        assert runner.nb_effects == 2
        assert len(inverse["generated"]) == 3
        assert all(row["absent"] for row in inverse["generated"])
        assert inverse["runtime"]["external_ids"]["external_ids"] == {
            "ovn-evpn-local-ip": "50100-170.168.0.6"
        }
        assert len(runner.effect_calls) > effect_count_before_inverse
        assert not any(
            "ip link del" in " ".join(call) and "ovnvrf" in " ".join(call)
            for call in runner.effect_calls
        )
        assert builder._config.x05_marker_path.read_bytes() == builder._marker_bytes
        assert session._entered and not session._closed and prepared.active

        events = SUPPORT.read_events(builder._config.event_path)
        event_names = {row["event"] for row in events}
        assert {
            "x05-runtime-intent",
            "x05-runtime-outcome",
            "x05-runtime-readback",
            "x05-runtime-state",
        }.issubset(event_names)
        builder._journal.verify()
        metrics = {
            "elapsed_seconds": round(time.monotonic() - started, 3),
            "effect_calls": len(runner.effect_calls),
            "runtime_calls": len(runner.runtime_calls),
            "producer_event_count": len(events),
            "producer_event_bytes": builder._config.event_path.stat().st_size,
            "runtime_journal_count": builder._journal.count,
            "runtime_journal_bytes": builder._journal.path.stat().st_size,
            "private_helper_calls": len(private_calls),
        }
        marker_path = builder._config.x05_marker_path
        marker_path.write_bytes(b"foreign-marker\n")
        marker_path.chmod(0o600)
        expect_error(APPLY.SecurityError, builder._verify_authority, "marker tamper")
        with builder._journal.path.open("ab") as stream:
            stream.write(b"{}\n")
            stream.flush()
            os.fsync(stream.fileno())
        expect_error(
            APPLY.SecurityError,
            builder._journal.verify_current,
            "runtime journal tamper",
        )
        return metrics


def main() -> int:
    static_contract_checks()
    terminal = terminal_g7_checks()
    stopped_successor_binding_checks()
    umask_fixture_checks()
    callable_binding_checks()
    fault_window_checks()
    metrics = full_build_and_guard_checks()
    print(
        "X05 runtime builder producer-model PASS: "
        + json.dumps(
            {"builder": metrics, "terminal": terminal},
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    if sys.platform != "linux":
        print(
            "X05 runtime real-Linux execution NOT_RUN: Darwin producer model is not lab proof",
            file=sys.stderr,
        )
        return 77
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
