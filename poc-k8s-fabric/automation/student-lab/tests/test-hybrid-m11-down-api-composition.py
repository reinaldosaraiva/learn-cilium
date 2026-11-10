#!/usr/bin/env python3
"""Exercise the production M11 API teardown through a local HTTP boundary."""

from __future__ import annotations

from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

import yaml


PROJECT_ID = "1234567890abcdef1234567890abcdef"
FAKE_TOKEN = "local-fake-token-for-teardown-test"


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def append_event(path: Path, event: dict) -> None:
    with path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(event, sort_keys=True) + "\n")


class NeutronHandler(BaseHTTPRequestHandler):
    objects: dict[str, tuple[str, dict]] = {}
    relations: set[tuple[str, str]] = set()
    event_path: Path
    failure_mode = ""
    lock = threading.Lock()

    def log_message(self, fmt, *args):
        return

    def _body(self) -> dict:
        size = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(size)) if size else {}

    def _send(self, status: int, body: dict | None = None) -> None:
        encoded = json.dumps(body or {}).encode("utf-8") if status != 204 else b""
        self.send_response(status)
        if status != 204:
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        if encoded:
            self.wfile.write(encoded)

    def _record(self, method: str, path: str, body: dict, status: int) -> None:
        append_event(
            type(self).event_path,
            {"kind": "http", "method": method, "path": path, "body": body, "status": status},
        )

    def _authorized(self) -> bool:
        return self.headers.get("X-Auth-Token") == FAKE_TOKEN

    def do_GET(self):
        body = {}
        path = urlsplit(self.path).path
        if not self._authorized():
            self._record("GET", path, body, 401)
            return self._send(401, {"error": "unauthorized"})
        route_path = path.removeprefix("/v2.0")
        if route_path == "/agents/" + self.agent_id + "/bgp-drinstances":
            if type(self).failure_mode == "scheduler-query-error":
                self._record("GET", path, body, 503)
                return self._send(503, {"error": "synthetic unavailable"})
            with type(self).lock:
                speakers = [
                    {"id": speaker_id}
                    for agent_id, speaker_id in sorted(type(self).relations)
                    if agent_id == self.agent_id
                ]
            self._record("GET", path, body, 200)
            return self._send(200, {"bgp_speakers": speakers})
        if route_path.startswith("/bgp-speakers/") and route_path.endswith("/get_advertised_routes"):
            self._record("GET", path, body, 200)
            return self._send(200, {"advertised_routes": []})
        key = route_path
        with type(self).lock:
            stored = type(self).objects.get(key)
            if stored is None:
                self._record("GET", path, body, 404)
                return self._send(404, {"error": "not found"})
            envelope, value = stored
            value = dict(value)
            if type(self).failure_mode == "foreign-speaker" and route_path.endswith(
                "/" + self.speaker_id
            ):
                value["tenant_id"] = "ffffffffffffffffffffffffffffffff"
            self._record("GET", path, body, 200)
            return self._send(200, {envelope: value})

    @property
    def module(self):
        return type(self).fixture_module

    @property
    def agent_id(self):
        return type(self).agent_id_value

    @property
    def speaker_id(self):
        return type(self).speaker_id_value

    @property
    def peer_id(self):
        return type(self).peer_id_value

    @property
    def external_network_id(self):
        return type(self).external_network_id_value

    @property
    def tenant_subnet_id(self):
        return type(self).tenant_subnet_id_value

    @property
    def router_interface_id(self):
        return type(self).router_interface_id_value

    @property
    def router_gateway_port_id(self):
        return type(self).router_gateway_port_id_value

    def do_PUT(self):
        body = self._body()
        path = urlsplit(self.path).path
        route_path = path.removeprefix("/v2.0")
        if not self._authorized():
            self._record("PUT", path, body, 401)
            return self._send(401, {"error": "unauthorized"})

        with type(self).lock:
            if route_path == f"/bgp-speakers/{self.speaker_id}/remove_gateway_network":
                if body != {"network_id": self.external_network_id}:
                    self._record("PUT", path, body, 409)
                    return self._send(409, {"error": "wrong network identity"})
                self._record("PUT", path, body, 200)
                return self._send(200, {})
            if route_path == f"/bgp-speakers/{self.speaker_id}/remove_bgp_peer":
                if body != {"bgp_peer_id": self.peer_id}:
                    self._record("PUT", path, body, 409)
                    return self._send(409, {"error": "wrong peer identity"})
                self._record("PUT", path, body, 200)
                return self._send(200, {})
            if route_path == f"/routers/{self.router_id}/remove_router_interface":
                if body != {"subnet_id": self.tenant_subnet_id}:
                    self._record("PUT", path, body, 409)
                    return self._send(409, {"error": "wrong subnet identity"})
                type(self).objects.pop(f"/ports/{self.router_interface_id}", None)
                self._record("PUT", path, body, 200)
                return self._send(200, {"port_id": self.router_interface_id})
            if route_path == f"/routers/{self.router_id}":
                if body != {"router": {"external_gateway_info": None}}:
                    self._record("PUT", path, body, 409)
                    return self._send(409, {"error": "wrong router update"})
                envelope, router = type(self).objects[f"/routers/{self.router_id}"]
                router = dict(router)
                router["external_gateway_info"] = None
                type(self).objects[f"/routers/{self.router_id}"] = (envelope, router)
                type(self).objects.pop(f"/ports/{self.router_gateway_port_id}", None)
                self._record("PUT", path, body, 200)
                return self._send(200, {"router": router})

        self._record("PUT", path, body, 404)
        self._send(404, {"error": "not found"})

    def do_DELETE(self):
        body = {}
        path = urlsplit(self.path).path
        route_path = path.removeprefix("/v2.0")
        if not self._authorized():
            self._record("DELETE", path, body, 401)
            return self._send(401, {"error": "unauthorized"})
        relation_path = f"/agents/{self.agent_id}/bgp-drinstances/{self.speaker_id}"
        with type(self).lock:
            if route_path == relation_path:
                type(self).relations.discard((self.agent_id, self.speaker_id))
                self._record("DELETE", path, body, 204)
                return self._send(204)
            if route_path in type(self).objects:
                del type(self).objects[route_path]
                self._record("DELETE", path, body, 204)
                return self._send(204)
        self._record("DELETE", path, body, 404)
        self._send(404, {"error": "not found"})

    @property
    def router_id(self):
        return type(self).router_id_value


def load_fixture_module(student_lab: Path):
    fixture_path = student_lab / "tests/test-hybrid-m11-positive-composition.py"
    spec = importlib.util.spec_from_file_location("positive_composition_fixture", fixture_path)
    if spec is None or spec.loader is None:
        raise RuntimeError("Cannot load the existing owned-state fixture")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def api_objects(state: dict, fixture_module) -> tuple[dict[str, tuple[str, dict]], set]:
    resources = state["hybrid"]["m11"]["api"]["resources"]
    api = state["hybrid"]["m11"]["api"]
    network = state["hybrid"]["m11"]["network"]
    project = api["project_id"]
    ids = fixture_module.IDS
    names = {key: entry["primary"]["name"] for key, entry in resources.items() if "primary" in entry}
    objects: dict[str, tuple[str, dict]] = {}

    def add(collection: str, key: str, envelope: str, attrs: dict) -> None:
        object_id = resources[key]["primary"]["id"]
        if object_id:
            objects[f"{collection}/{object_id}"] = (
                envelope,
                {"id": object_id, **attrs},
            )

    add("/address-scopes", "address_scope", "address_scope", {
        "tenant_id": project, "name": names["address_scope"], "ip_version": 4, "shared": False,
    })
    for key in ("external_subnetpool", "tenant_subnetpool"):
        add("/subnetpools", key, "subnetpool", {
            "tenant_id": project, "name": names[key], "address_scope_id": ids["address_scope"],
        })
    add("/networks", "external_network", "network", {
        "tenant_id": project, "name": names["external_network"],
        "provider:network_type": "flat", "provider:physical_network": "m11public",
    })
    add("/networks", "tenant_network", "network", {
        "tenant_id": project, "name": names["tenant_network"], "provider:network_type": "local",
    })
    for key in ("external_subnet", "tenant_subnet"):
        parent = "external" if key == "external_subnet" else "tenant"
        add("/subnets", key, "subnet", {
            "tenant_id": project,
            "name": names[key],
            "network_id": ids[f"{parent}_network"],
            "subnetpool_id": ids[f"{parent}_subnetpool"],
        })

    gateway = {
        "network_id": ids["external_network"],
        "enable_snat": False,
        "external_fixed_ips": [{
            "subnet_id": ids["external_subnet"],
            "ip_address": network["provider_router_ip"],
        }],
    }
    add("/routers", "router", "router", {
        "tenant_id": project, "name": names["router"], "external_gateway_info": gateway,
    })
    add("/ports", "router_interface", "port", {"tenant_id": project, "device_owner": "network:router_interface"})
    add("/ports", "router_gateway_port", "port", {"tenant_id": ""})
    add("/security-groups", "security_group", "security_group", {
        "tenant_id": project, "name": names["security_group"],
    })
    rule_attrs = {
        "egress_tcp": {"direction": "egress", "ethertype": "IPv4", "protocol": "tcp", "port_range_min": 8080, "port_range_max": 8080, "remote_ip_prefix": "10.246.0.0/16"},
        "egress_icmp": {"direction": "egress", "ethertype": "IPv4", "protocol": "icmp", "remote_ip_prefix": "10.246.0.0/16"},
        "ingress_tcp": {"direction": "ingress", "ethertype": "IPv4", "protocol": "tcp", "port_range_min": 22, "port_range_max": 22, "remote_ip_prefix": "10.246.0.0/16"},
        "ingress_icmp": {"direction": "ingress", "ethertype": "IPv4", "protocol": "icmp", "remote_ip_prefix": "10.246.0.0/16"},
    }
    for slot, attrs in rule_attrs.items():
        object_id = resources["security_group_rules"][slot]["id"]
        if object_id:
            objects[f"/security-group-rules/{object_id}"] = (
                "security_group_rule",
                {"id": object_id, "tenant_id": project, "security_group_id": ids["security_group"], **attrs},
            )

    port_attrs = {
        "tenant_id": project,
        "name": names["cirros_port"],
        "network_id": ids["tenant_network"],
        "mac_address": state["hybrid"]["guests"]["cirros"]["tenant_mac"],
        "security_groups": [ids["security_group"]],
        "binding:host_id": api["agent_ids"]["ovs_host"],
        "binding:vnic_type": "normal",
        "device_id": state["hybrid"]["guests"]["cirros"]["uuid"],
        "device_owner": "",
        "fixed_ips": [{"subnet_id": ids["tenant_subnet"], "ip_address": fixture_module.VM_IP}],
    }
    add("/ports", "cirros_port", "port", port_attrs)
    add("/bgp-speakers", "bgp_speaker", "bgp_speaker", {
        "tenant_id": project, "name": names["bgp_speaker"],
    })
    add("/bgp-peers", "bgp_peer", "bgp_peer", {
        "tenant_id": project, "name": names["bgp_peer"],
    })
    # Neutron's built-in IPv4 and IPv6 egress rules are intentionally absent from
    # this fixture when no exact UUID was checkpointed for them.
    return objects, {(api["agent_ids"]["bgp"], ids["bgp_speaker"])}


class HybridM11DownApiComposition(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.student_lab = Path(__file__).resolve().parents[1]
        cls.repo_root = cls.student_lab.parents[2]
        candidate = Path(os.environ.get("ANSIBLE_PLAYBOOK_BIN", ""))
        if not candidate.is_file():
            candidate = (
                cls.student_lab.parents[1]
                / "evidence/P010/S003/20261029-student-bootstrap/tooling/bin/ansible-playbook"
            )
        if not candidate.is_file():
            candidate = Path(shutil.which("ansible-playbook") or "")
        if not candidate.is_file():
            raise unittest.SkipTest("ansible-playbook is unavailable")
        cls.ansible_playbook = candidate
        cls.fixture_module = load_fixture_module(cls.student_lab)
        requested_scratch = os.environ.get("P010_HYBRID_API_TEST_SCRATCH")
        cls.scratch = Path(requested_scratch) if requested_scratch else Path(
            tempfile.mkdtemp(prefix="p010-hybrid22-down-api-")
        )
        cls.scratch.mkdir(mode=0o700, parents=True, exist_ok=True)
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), NeutronHandler)
        cls.server_thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.server_thread.start()
        cls.endpoint = f"http://127.0.0.1:{cls.httpd.server_port}/v2.0"

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()
        cls.server_thread.join(timeout=5)

    def setUp(self):
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
        self.case_dir = self.scratch / f"{self._testMethodName}-{stamp}"
        self.case_dir.mkdir(mode=0o700, parents=True)
        self.shadow_repo = self.case_dir / "repo"
        shadow_lab = self.shadow_repo / "poc-k8s-fabric/automation/student-lab"
        shutil.copytree(self.student_lab, shadow_lab)
        self.events_file = self.case_dir / "events.jsonl"
        self.events_file.touch(mode=0o600)
        self.deleted_tap_file = self.case_dir / "tap-deleted"
        self.bin_dir = self.case_dir / "bin"
        self.bin_dir.mkdir(mode=0o700)
        self.write_fakes()
        self.configure_shadow(shadow_lab)
        NeutronHandler.event_path = self.events_file
        NeutronHandler.failure_mode = ""

    def write_fakes(self):
        event_tool = self.bin_dir / "event"
        event_tool.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "with open(os.environ['P010_HYBRID22_EVENTS'], 'a', encoding='utf-8') as f:\n"
            " f.write(json.dumps({'kind': sys.argv[1], 'fields': sys.argv[2:]}) + '\\n')\n",
            encoding="utf-8",
        )
        event_tool.chmod(0o700)
        nsenter = self.bin_dir / "nsenter"
        nsenter.write_text(
            "#!/bin/sh\n"
            "while [ \"$#\" -gt 0 ] && [ \"$1\" != -- ]; do shift; done\n"
            "[ \"$#\" -gt 0 ] && shift\n"
            "exec \"$@\"\n",
            encoding="utf-8",
        )
        nsenter.chmod(0o700)
        setpriv = self.bin_dir / "setpriv"
        setpriv.write_text(
            "#!/bin/sh\n"
            "while [ \"$#\" -gt 0 ] && [ \"$1\" != -- ]; do shift; done\n"
            "[ \"$#\" -gt 0 ] && shift\n"
            "exec \"$@\"\n",
            encoding="utf-8",
        )
        setpriv.chmod(0o700)
        fake_ip = self.bin_dir / "ip"
        fake_ip.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "from pathlib import Path\n"
            "args=sys.argv[1:]\n"
            "event=os.environ['P010_HYBRID22_EVENTS']\n"
            "deleted=Path(os.environ['P010_HYBRID22_TAP_DELETED'])\n"
            "if args[:2] == ['link','del']:\n"
            " deleted.touch(); open(event,'a').write(json.dumps({'kind':'border','fields':['tap-delete']})+'\\n'); raise SystemExit(0)\n"
            "if args[-2:] == ['link','show']:\n"
            " value=[] if deleted.exists() else [{'ifname':'p010tap-test','ifindex':77,'ifalias':'p010-test-tap','linkinfo':{'info_kind':'tun','info_data':{'type':'tap'}}}]\n"
            " print(json.dumps(value,separators=(',',':'))); raise SystemExit(0)\n"
            "raise SystemExit(44)\n",
            encoding="utf-8",
        )
        fake_ip.chmod(0o700)

    def configure_shadow(self, shadow_lab: Path):
        runner = shadow_lab / "tasks/hybrid-m11-run-api.yml"
        text = runner.read_text(encoding="utf-8")
        if text.count("/usr/bin/setpriv") != 2 or text.count("  become: true\n") != 2:
            raise AssertionError("The runner's privilege/transport boundary changed")
        runner.write_text(
            text.replace("/usr/bin/setpriv", str(self.bin_dir / "setpriv")).replace(
                "  become: true\n", "  become: false\n"
            ),
            encoding="utf-8",
        )
        (shadow_lab / "tasks/hybrid-qmp-command.yml").write_text(
            "---\n"
            "- name: Record the QMP boundary reached by the real down caller\n"
            "  ansible.builtin.command:\n"
            "    argv: [\"{{ student_hybrid_m22_event_bin }}\", qmp, \"{{ student_hybrid_qmp_action }}\", \"{{ student_hybrid_qmp_guest_name }}\"]\n"
            "  changed_when: false\n"
            "  no_log: true\n",
            encoding="utf-8",
        )
        (shadow_lab / "tasks/hybrid-validate-border.yml").write_text(
            "---\n"
            "- name: Record the border validation boundary reached by the real runner\n"
            "  ansible.builtin.command:\n"
            "    argv: [\"{{ student_hybrid_m22_event_bin }}\", border, validate]\n"
            "  changed_when: false\n"
            "  no_log: true\n",
            encoding="utf-8",
        )
        (shadow_lab / "tasks/hybrid-m11-ssh.yml").write_text(
            "---\n"
            "- name: Record the synthetic OVS guest detach boundary\n"
            "  ansible.builtin.command:\n"
            "    argv: [\"{{ student_hybrid_m22_event_bin }}\", ssh, ovs-detach]\n"
            "  changed_when: false\n"
            "  no_log: true\n"
            "- name: Return the exact detached marker to the real OVS caller\n"
            "  ansible.builtin.set_fact:\n"
            "    student_hybrid_ssh_result: {rc: 0, stdout_lines: ['P010_OVS_DETACH=absent']}\n"
            "  no_log: true\n",
            encoding="utf-8",
        )
        (shadow_lab / "tasks/validate-identities.yml").write_text(
            "---\n"
            "- name: Record the outer caller's Docker identity inspection boundary\n"
            "  ansible.builtin.command:\n"
            "    argv: [\"{{ student_hybrid_m22_event_bin }}\", identities, validate]\n"
            "  changed_when: false\n"
            "  no_log: true\n",
            encoding="utf-8",
        )
        (shadow_lab / "tasks/down.yml").write_text(
            "---\n"
            "- name: Record the outer caller's final fabric cleanup boundary\n"
            "  ansible.builtin.command:\n"
            "    argv: [\"{{ student_hybrid_m22_event_bin }}\", fabric, cleanup]\n"
            "  changed_when: false\n"
            "  no_log: true\n",
            encoding="utf-8",
        )
        child = [
            {
                "name": "Run the production API removal graph with a synthetic local guest boundary",
                "hosts": "localhost",
                "connection": "local",
                "gather_facts": True,
                "vars_files": ["{{ student_repo_root }}/poc-k8s-fabric/automation/student-lab/vars.yml"],
                "vars": {
                    "student_profile_name": "hibrido",
                    "student_profile": "{{ student_profiles.hibrido }}",
                },
                "tasks": [
                    {
                        "name": "Read the private state written by the production caller",
                        "ansible.builtin.slurp": {"src": "{{ student_state_file }}"},
                        "register": "student_hybrid_m22_input",
                        "no_log": True,
                    },
                    {
                        "name": "Load the exact durable state in this child process",
                        "ansible.builtin.set_fact": {
                            "student_state": "{{ student_hybrid_m22_input.content | b64decode | from_json }}",
                            "student_state_dir": "{{ student_state_file | dirname }}",
                        },
                        "no_log": True,
                    },
                    {
                        "name": "Provide only a local synthetic guest connection",
                        "ansible.builtin.add_host": {
                            "name": "student_hybrid_ubuntu",
                            "groups": "student_hybrid_guest_api",
                            "ansible_connection": "local",
                        },
                    },
                    {
                        "name": "Keep the fake token inside the child API process",
                        "ansible.builtin.set_fact": {
                            "student_hybrid_api_token": FAKE_TOKEN,
                            "student_hybrid_api_project_id": "{{ student_state.hybrid.m11.api.project_id }}",
                        },
                        "no_log": True,
                    },
                    {
                        "name": "Use the stateful loopback endpoint for the real task graph",
                        "ansible.builtin.assert": {
                            "that": [
                                "student_hybrid_api_mode in ['remove-routing', 'remove-resources']",
                                "student_state.profile == 'hibrido'",
                                "student_state.owner_uid | int == student_uid | int",
                            ]
                        },
                        "no_log": True,
                    },
                    {
                        "name": "Execute the production API relationships and resource teardown",
                        "ansible.builtin.include_tasks": "tasks/hybrid-m11-api-remove.yml",
                        "vars": {
                            "student_hybrid_api_remove_phase": "{{ 'routing' if student_hybrid_api_mode == 'remove-routing' else 'resources' }}"
                        },
                    },
                ],
            }
        ]
        (shadow_lab / "hybrid-m11-api-playbook.yml").write_text(
            yaml.safe_dump(child, sort_keys=False), encoding="utf-8"
        )

    def fixture_state(self, run_dir: Path) -> dict:
        state = self.fixture_module.make_state(run_dir, os.getuid())
        api = state["hybrid"]["m11"]["api"]
        api["neutron_endpoint"] = self.endpoint
        api["project_id"] = PROJECT_ID
        api["links"].update(
            {
                "bgp_gateway_network": True,
                "bgp_peer": True,
                "router_interface": True,
                "router_gateway": True,
            }
        )
        api["resources"]["drinstance"] = {
            "primary": {
                "id": "",
                "name": "",
                "agent_id": api["agent_ids"]["bgp"],
                "speaker_id": self.fixture_module.IDS["bgp_speaker"],
            }
        }
        api["resources"]["security_group_rules"].update(
            {"default_ipv4": {"id": ""}, "default_ipv6": {"id": ""}}
        )
        gates = state["hybrid"]["m11"]["verification"]["gates"]
        gates["k8s_resources"] = {}
        gates["k8s_pending"] = {}
        gates["k8s_delete_pending"] = {}
        gates["ovs_attach"] = {
            "phase": "attached",
            "bridge_name": "br-int",
            "interface_name": "tenant0",
            "guest_uuid": state["hybrid"]["guests"]["cirros"]["uuid"],
            "neutron_port_id": self.fixture_module.IDS["cirros_port"],
            "attached_mac": "02:00:00:00:00:22",
            "guest_interface_mac": "02:00:00:00:00:22",
            "bridge_uuid": "11111111-1111-4111-8111-111111111111",
            "port_uuid": "22222222-2222-4222-8222-222222222222",
            "interface_uuid": "33333333-3333-4333-8333-333333333333",
            "ifindex": 77,
            "ofport": 8,
        }
        state["hybrid"]["guests"]["cirros"]["pid"] = 9_876_543
        state["hybrid"]["guests"]["ubuntu"]["pid"] = 9_876_544
        ubuntu_public = Path(state["hybrid"]["guests"]["ubuntu"]["ssh_private_key"] + ".pub")
        ubuntu_public.write_text("ssh-ed25519 c3ludGhldGljLXNoYXJlZC1wdWJsaWM= shared-fixture\n", encoding="ascii")
        ubuntu_public.chmod(0o600)
        ubuntu_public_stat = ubuntu_public.stat()
        state["hybrid"]["guests"]["ubuntu"]["ssh_public_device"] = ubuntu_public_stat.st_dev
        state["hybrid"]["guests"]["ubuntu"]["ssh_public_inode"] = ubuntu_public_stat.st_ino
        for guest_name, host_key in state["hybrid"]["m11"]["ssh"]["host_keys"].items():
            host_key.update(
                {
                    "private_path": str(run_dir / "ssh" / f"{guest_name}-host.key"),
                    "private_device": 0,
                    "private_inode": 0,
                }
            )
        state["hybrid"]["network"]["tenant_socket"] = {
            "path": str(run_dir / "qemu" / "tenant.sock"),
            "device": 0,
            "inode": 0,
        }
        state["hybrid"]["sources"] = {}
        for guest in state["hybrid"]["guests"].values():
            guest["seed_dir"] = str(run_dir / f"{guest['uuid']}.seed")
            guest["seed_dir_device"] = 0
            guest["seed_dir_inode"] = 0
        state["hybrid"]["m11"].update(
            {
                "credentials": {"path": str(run_dir / "secrets.json"), "device": 0, "inode": 0},
                "devstack": {"config_path": str(run_dir / "local.conf"), "config_device": 0, "config_inode": 0},
                "frr": {"private_config_path": str(run_dir / "frr.conf"), "config_device": 0, "config_inode": 0},
                "cilium": {"values_path": str(run_dir / "cilium-values.yaml"), "values_device": 0, "values_inode": 0},
            }
        )
        state["hybrid"]["network"]["tap"] = {
            "name": "p010tap-test",
            "ifindex": 77,
            "alias": "p010-test-tap",
            "reserved_alias": "p010-test-tap",
            "create_phase": "created",
        }
        return state

    def start_server(self, state: dict, failure_mode: str = ""):
        objects, relations = api_objects(state, self.fixture_module)
        # The one exact GET 404 exercises the production already-absent branch.
        objects.pop(
            f"/security-group-rules/{state['hybrid']['m11']['api']['resources']['security_group_rules']['ingress_icmp']['id']}",
            None,
        )
        NeutronHandler.objects = objects
        NeutronHandler.relations = relations
        NeutronHandler.failure_mode = failure_mode
        NeutronHandler.agent_id_value = state["hybrid"]["m11"]["api"]["agent_ids"]["bgp"]
        NeutronHandler.speaker_id_value = self.fixture_module.IDS["bgp_speaker"]
        NeutronHandler.peer_id_value = self.fixture_module.IDS["bgp_peer"]
        NeutronHandler.external_network_id_value = self.fixture_module.IDS["external_network"]
        NeutronHandler.tenant_subnet_id_value = self.fixture_module.IDS["tenant_subnet"]
        NeutronHandler.router_interface_id_value = self.fixture_module.IDS["router_interface"]
        NeutronHandler.router_gateway_port_id_value = self.fixture_module.IDS["router_gateway_port"]
        NeutronHandler.router_id_value = self.fixture_module.IDS["router"]

    def playbook(self, state_file: Path, live_guests: list[str]) -> Path:
        path = self.case_dir / f"down-{len(list(self.case_dir.glob('down-*.yml')))}.yml"
        shadow_lab = self.shadow_repo / "poc-k8s-fabric/automation/student-lab"
        play = [
            {
                "name": "Exercise the production hybrid down, M11 API, guest, and border order",
                "hosts": "localhost",
                "connection": "local",
                "gather_facts": True,
                "vars_files": [str(shadow_lab / "vars.yml")],
                "vars": {
                    "student_state_file": str(state_file),
                    "student_state": "{{ lookup('file', student_state_file) | from_json }}",
                    "student_has_state": True,
                    "student_uid": os.getuid(),
                    "student_user_gid": os.getgid(),
                    "ansible_user_gid": os.getgid(),
                    "student_repo_root": str(self.shadow_repo),
                    "student_profile_name": "hibrido",
                    "student_profile": "{{ student_profiles.hibrido }}",
                    "student_action": "down",
                    "student_hybrid_live_guest_names": live_guests,
                    "student_hybrid_nsenter_bin": str(self.bin_dir / "nsenter"),
                    "student_hybrid_ip_bin": str(self.bin_dir / "ip"),
                    "student_hybrid_become": False,
                    "student_hybrid_m22_event_bin": str(self.bin_dir / "event"),
                },
                "tasks": [
                    {"name": "Run the production outer down and nested API/guest/border graph", "ansible.builtin.include_tasks": str(shadow_lab / "tasks/hybrid-down.yml")},
                    {
                        "name": "Require every saved API ID and relationship to be cleared",
                        "ansible.builtin.assert": {
                            "that": [
                                "student_state.hybrid.m11.api.pending == {}",
                                "student_state.hybrid.m11.api.resources.address_scope.primary.id == ''",
                                "student_state.hybrid.m11.api.resources.tenant_network.primary.id == ''",
                                "student_state.hybrid.m11.api.resources.cirros_port.primary.id == ''",
                                "student_state.hybrid.m11.api.resources.router_interface.primary.id == ''",
                                "student_state.hybrid.m11.api.resources.router_gateway_port.primary.id == ''",
                                "student_state.hybrid.m11.api.resources.bgp_speaker.primary.id == ''",
                                "student_state.hybrid.m11.api.links.bgp_gateway_network == false",
                                "student_state.hybrid.m11.api.links.bgp_peer == false",
                                "student_state.hybrid.m11.api.links.router_interface == false",
                                "student_state.hybrid.m11.api.links.router_gateway == false",
                                "student_state.hybrid.m11.verification.gates.ovs_attach.phase == 'detached'",
                            ]
                        },
                        "no_log": True,
                    },
                ],
            }
        ]
        path.write_text(yaml.safe_dump(play, sort_keys=False), encoding="utf-8")
        return path

    def run_down(self, state_file: Path, live_guests: list[str], label: str) -> tuple[subprocess.CompletedProcess, list[dict]]:
        playbook = self.playbook(state_file, live_guests)
        argv = [str(self.ansible_playbook), "-i", "localhost,", str(playbook)]
        started = datetime.now(timezone.utc).isoformat()
        env = os.environ.copy()
        env.update(
            {
                "ANSIBLE_CONFIG": str(self.shadow_repo / "poc-k8s-fabric/automation/student-lab/ansible.cfg"),
                "ANSIBLE_NOCOLOR": "1",
                "PYTHONDONTWRITEBYTECODE": "1",
                "P010_HYBRID22_EVENTS": str(self.events_file),
                "P010_HYBRID22_TAP_DELETED": str(self.deleted_tap_file),
            }
        )
        result = subprocess.run(
            argv,
            cwd=self.shadow_repo,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        log_path = self.case_dir / f"{label}.ansible.log"
        log_path.write_text(result.stdout, encoding="utf-8")
        events = [json.loads(line) for line in self.events_file.read_text(encoding="utf-8").splitlines() if line]
        receipt = {
            "started_utc": started,
            "argv": argv,
            "rc": result.returncode,
            "failure_mode": NeutronHandler.failure_mode,
            "http_request_count": sum(event.get("kind") == "http" for event in events),
            "events_file": str(self.events_file),
            "ansible_log": str(log_path),
        }
        (self.case_dir / f"{label}.receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        return result, events

    def seed(self) -> tuple[Path, dict]:
        run_dir = self.case_dir / "run"
        run_dir.mkdir(mode=0o700)
        state = self.fixture_state(run_dir)
        state_file = self.case_dir / "state.json"
        self.fixture_module.write_json(state_file, state)
        return state_file, state

    def test_full_down_removes_owned_api_objects_once_in_dependency_order(self):
        state_file, state = self.seed()
        self.start_server(state)
        result, first_events = self.run_down(state_file, ["cirros", "ubuntu"], "first-down")
        self.assertEqual(result.returncode, 0, result.stdout)
        saved = read_json(state_file)
        api = saved["hybrid"]["m11"]["api"]
        self.assertEqual(api["pending"], {})
        self.assertTrue(all(record.get("id", "") == "" for resource in api["resources"].values() for record in resource.values() if isinstance(record, dict)))
        self.assertEqual(api["links"]["drinstance"]["speaker_id"], "")
        self.assertEqual(saved["hybrid"]["m11"]["verification"]["gates"]["ovs_attach"]["phase"], "detached")
        self.assertTrue(any(event.get("method") == "PUT" and event.get("path", "").endswith("/remove_router_interface") for event in first_events))
        self.assertTrue(any(event.get("method") == "PUT" and event.get("path", "").endswith("/routers/" + self.fixture_module.IDS["router"]) for event in first_events))
        self.assertTrue(any(event.get("method") == "DELETE" and event.get("path", "").endswith("/bgp-drinstances/" + self.fixture_module.IDS["bgp_speaker"]) for event in first_events))
        absent_rule_id = state["hybrid"]["m11"]["api"]["resources"]["security_group_rules"]["ingress_icmp"]["id"]
        self.assertTrue(any(event.get("status") == 404 and event.get("path", "").endswith(absent_rule_id) for event in first_events))

        kinds = [event.get("kind") for event in first_events]
        qmp_quit = next(index for index, event in enumerate(first_events) if event.get("kind") == "qmp" and event.get("fields") == ["quit", "cirros"])
        ovs_detach = next(index for index, event in enumerate(first_events) if event.get("kind") == "ssh")
        tap_delete = next(index for index, event in enumerate(first_events) if event.get("kind") == "border" and event.get("fields") == ["tap-delete"])
        fabric_cleanup = next(index for index, event in enumerate(first_events) if event.get("kind") == "fabric")
        resource_deletes = [
            index
            for index, event in enumerate(first_events)
            if event.get("kind") == "http"
            and event.get("method") == "DELETE"
            and not event.get("path", "").startswith("/v2.0/agents/")
            and not event.get("path", "").startswith("/v2.0/bgp-speakers/")
            and not event.get("path", "").startswith("/v2.0/bgp-peers/")
        ]
        route_deletes = [
            index
            for index, event in enumerate(first_events)
            if event.get("kind") == "http"
            and event.get("method") == "DELETE"
            and (
                event.get("path", "").startswith("/v2.0/agents/")
                or event.get("path", "").startswith("/v2.0/bgp-speakers/")
                or event.get("path", "").startswith("/v2.0/bgp-peers/")
            )
        ]
        self.assertTrue(route_deletes)
        self.assertLess(max(route_deletes), qmp_quit)
        self.assertLess(qmp_quit, ovs_detach)
        self.assertTrue(resource_deletes)
        self.assertTrue(all(ovs_detach < index < tap_delete for index in resource_deletes))
        self.assertGreater(tap_delete, max(resource_deletes))
        self.assertGreater(fabric_cleanup, tap_delete)

        request_count = len([event for event in first_events if event.get("kind") == "http"])
        self.deleted_tap_file.touch()
        result, second_events = self.run_down(state_file, [], "repeat-down")
        self.assertEqual(result.returncode, 0, result.stdout)
        second_request_count = len([event for event in second_events if event.get("kind") == "http"])
        self.assertEqual(second_request_count, request_count)
        self.assertFalse(any(event.get("kind") == "http" and event.get("method") in {"DELETE", "PUT"} for event in second_events[len(first_events):]))

    def test_scheduler_query_error_reloads_partial_child_state_and_keeps_ids(self):
        state_file, state = self.seed()
        self.start_server(state, "scheduler-query-error")
        result, events = self.run_down(state_file, ["cirros"], "scheduler-error")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        saved_api = read_json(state_file)["hybrid"]["m11"]["api"]
        self.assertEqual(saved_api["pending"], {})
        self.assertEqual(saved_api["resources"]["bgp_speaker"]["primary"]["id"], self.fixture_module.IDS["bgp_speaker"])
        self.assertEqual(saved_api["resources"]["bgp_peer"]["primary"]["id"], self.fixture_module.IDS["bgp_peer"])
        self.assertFalse(saved_api["links"]["bgp_gateway_network"])
        self.assertFalse(saved_api["links"]["bgp_peer"])
        self.assertTrue(any(event.get("kind") == "http" and event.get("status") == 503 for event in events))
        self.assertFalse(any(event.get("kind") == "qmp" and event.get("fields") == ["quit", "cirros"] for event in events))
        self.assertFalse(any(event.get("kind") == "ssh" for event in events))
        self.assertFalse(any(event.get("kind") == "border" and event.get("fields") == ["tap-delete"] for event in events))
        self.assertFalse(any(event.get("kind") == "http" and event.get("method") == "DELETE" for event in events))

    def test_foreign_speaker_identity_stops_before_delete_and_keeps_own_id(self):
        state_file, state = self.seed()
        self.start_server(state, "foreign-speaker")
        result, events = self.run_down(state_file, ["cirros"], "foreign-speaker")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        saved_api = read_json(state_file)["hybrid"]["m11"]["api"]
        self.assertEqual(saved_api["resources"]["bgp_speaker"]["primary"]["id"], self.fixture_module.IDS["bgp_speaker"])
        self.assertTrue(any(event.get("kind") == "http" and event.get("method") == "GET" and event.get("path", "").endswith("/bgp-speakers/" + self.fixture_module.IDS["bgp_speaker"]) for event in events))
        self.assertFalse(any(event.get("kind") == "http" and event.get("method") == "DELETE" and event.get("path", "").endswith("/bgp-speakers/" + self.fixture_module.IDS["bgp_speaker"]) for event in events))
        self.assertFalse(any(event.get("kind") == "qmp" and event.get("fields") == ["quit", "cirros"] for event in events))

    def test_invalid_child_checkpoint_is_not_overwritten_by_startup_rescue(self):
        state_file, state = self.seed()
        state_file.chmod(0o600)
        invalid_checkpoint = b'{"schema":\n'
        saver_called = self.case_dir / "save-state-called"
        (self.bin_dir / "nsenter").write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "args=sys.argv[1:]\n"
            "kind='syntax-check' if '--syntax-check' in args else 'child'\n"
            "with open(os.environ['P010_HYBRID22_EVENTS'], 'a', encoding='utf-8') as stream:\n"
            " stream.write(json.dumps({'kind':'runner-boundary','fields':[kind]})+'\\n')\n"
            "if kind == 'child':\n"
            " open(os.environ['P010_HYBRID22_STATE'], 'wb').write(b'{\\\"schema\\\":\\n')\n"
            " raise SystemExit(42)\n"
            "raise SystemExit(0)\n",
            encoding="utf-8",
        )
        (self.bin_dir / "nsenter").chmod(0o700)
        (self.shadow_repo / "poc-k8s-fabric/automation/student-lab/tasks/save-state.yml").write_text(
            "---\n"
            "- name: Detect an unsafe stale-state rewrite in the test boundary\n"
            "  ansible.builtin.file:\n"
            f"    path: {str(saver_called)!r}\n"
            "    state: touch\n",
            encoding="utf-8",
        )
        playbook = self.case_dir / "invalid-child-checkpoint.yml"
        shadow_lab = self.shadow_repo / "poc-k8s-fabric/automation/student-lab"
        play = [
            {
                "name": "Keep an invalid API child checkpoint out of startup rescue writes",
                "hosts": "localhost",
                "connection": "local",
                "gather_facts": True,
                "vars_files": [str(shadow_lab / "vars.yml")],
                "vars": {
                    "student_state_file": str(state_file),
                    "student_state": state,
                    "student_has_state": True,
                    "student_uid": os.getuid(),
                    "student_user_gid": os.getgid(),
                    "ansible_user_gid": os.getgid(),
                    "student_repo_root": str(self.shadow_repo),
                    "student_run_dir": str(self.case_dir / "run"),
                    "student_profile_name": "hibrido",
                    "student_profile": "{{ student_profiles.hibrido }}",
                    "student_hybrid_nsenter_bin": str(self.bin_dir / "nsenter"),
                    "student_hybrid_become": False,
                    "student_hybrid_api_mode": "verify",
                    "student_hybrid_m11_verify_existing": True,
                    "student_hybrid_m22_event_bin": str(self.bin_dir / "event"),
                },
                "tasks": [
                    {
                        "block": [
                            {"name": "Run the production API child boundary", "ansible.builtin.include_tasks": str(shadow_lab / "tasks/hybrid-m11-run-api.yml")}
                        ],
                        "rescue": [
                            {
                                "block": [
                                    {"name": "Run the production startup rescue guard", "ansible.builtin.include_tasks": str(shadow_lab / "tasks/rescue-up.yml")}
                                ],
                                "rescue": [
                                    {"name": "Record the expected refusal without exposing checkpoint contents", "ansible.builtin.set_fact": {"student_hybrid22_rescue_refused": True}, "no_log": True}
                                ],
                            }
                        ],
                    },
                    {"name": "Inspect whether a stale save path ran", "ansible.builtin.stat": {"path": str(saver_called)}, "register": "student_hybrid22_saver_stat"},
                    {
                        "name": "Require the invalid child file to remain byte-for-byte and refuse stale save-state",
                        "ansible.builtin.assert": {
                            "that": [
                                "not student_hybrid22_saver_stat.stat.exists",
                                "student_hybrid_api_checkpoint_reload_failed | bool",
                                "student_hybrid22_rescue_refused | default(false) | bool",
                            ]
                        },
                        "no_log": True,
                    },
                ],
            }
        ]
        playbook.write_text(yaml.safe_dump(play, sort_keys=False), encoding="utf-8")
        argv = [str(self.ansible_playbook), "-i", "localhost,", str(playbook)]
        started = datetime.now(timezone.utc).isoformat()
        log_path = self.case_dir / "invalid-child-checkpoint.ansible.log"
        env = os.environ.copy()
        env.update(
            {
                "ANSIBLE_CONFIG": str(self.shadow_repo / "poc-k8s-fabric/automation/student-lab/ansible.cfg"),
                "ANSIBLE_NOCOLOR": "1",
                "PYTHONDONTWRITEBYTECODE": "1",
                "P010_HYBRID22_EVENTS": str(self.events_file),
                "P010_HYBRID22_STATE": str(state_file),
            }
        )
        result = subprocess.run(argv, cwd=self.shadow_repo, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
        log_path.write_text(result.stdout, encoding="utf-8")
        receipt = {"started_utc": started, "argv": argv, "rc": result.returncode, "log": str(log_path), "state_file": str(state_file)}
        (self.case_dir / "invalid-child-checkpoint.receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(state_file.read_bytes(), invalid_checkpoint)
        self.assertFalse(saver_called.exists())
        events = [json.loads(line) for line in self.events_file.read_text(encoding="utf-8").splitlines() if line]
        self.assertEqual([event["fields"] for event in events if event.get("kind") == "runner-boundary"], [["syntax-check"], ["child"]])


if __name__ == "__main__":
    unittest.main(verbosity=2)
