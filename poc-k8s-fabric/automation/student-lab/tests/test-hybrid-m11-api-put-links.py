#!/usr/bin/env python3
"""Exercise production API relationship checkpointing with a loopback fake."""

from datetime import datetime, timezone
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest
from urllib.parse import urlsplit

import yaml


RUN_ID = "20261030-33333333333343338333333333333333"
ROUTER_ID = "11111111-1111-4111-8111-111111111111"
SPEAKER_ID = "22222222-2222-4222-8222-222222222222"
PEER_ID = "33333333-3333-4333-8333-333333333333"
NETWORK_ID = "44444444-4444-4444-8444-444444444444"
SUBNET_ID = "55555555-5555-4555-8555-555555555555"
PORT_ID = "66666666-6666-4666-8666-666666666666"


class LinkHandler(BaseHTTPRequestHandler):
    events = []
    event_lock = threading.Lock()

    def _send(self, status, body, request_id):
        encoded = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("X-Openstack-Request-Id", request_id)
        self.end_headers()
        self.wfile.write(encoded)

    def do_PUT(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        with type(self).event_lock:
            ordinal = len(type(self).events) + 1
            type(self).events.append(
                {"method": "PUT", "path": urlsplit(self.path).path, "body": body}
            )
        result = {}
        if self.path.endswith("/add_router_interface"):
            result = {"port_id": PORT_ID, "subnet_id": body["subnet_id"]}
        elif self.path.endswith("/remove_router_interface"):
            result = {"port_id": PORT_ID}
        self._send(200, result, f"req-p010-{ordinal}")

    def do_GET(self):
        with type(self).event_lock:
            type(self).events.append(
                {"method": "GET", "path": urlsplit(self.path).path}
            )
        self._send(404, {"error": "not found"}, "req-p010-get")

    def log_message(self, fmt, *args):
        return


class ApiPutRelationshipState(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.student_lab = Path(__file__).resolve().parents[1]
        cls.repo_root = cls.student_lab.parents[2]
        cls.ansible_playbook = Path(os.environ.get("ANSIBLE_PLAYBOOK_BIN", ""))
        if not cls.ansible_playbook.is_file():
            cls.ansible_playbook = Path(shutil.which("ansible-playbook") or "")
        if not cls.ansible_playbook.is_file():
            raise unittest.SkipTest("ansible-playbook is not available")
        cls.scratch = Path(
            os.environ.get("P010_HYBRID_PUT_TEST_SCRATCH")
            or tempfile.mkdtemp(prefix="p010-hybrid-api-put-links-")
        )
        cls.scratch.mkdir(mode=0o700, parents=True, exist_ok=True)
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), LinkHandler)
        cls.server_thread = threading.Thread(
            target=cls.httpd.serve_forever, daemon=True
        )
        cls.server_thread.start()
        cls.endpoint = f"http://127.0.0.1:{cls.httpd.server_port}/v2.0"

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()
        cls.server_thread.join(timeout=5)

    def make_state(self):
        return {
            "run_id": RUN_ID,
            "status": "partial",
            "phase": "hybrid-api-provisioning",
            "hybrid": {
                "phase": "partial",
                "m11": {
                    "phase": "api-provisioning",
                    "api": {
                        "neutron_endpoint": self.endpoint,
                        "pending": {},
                        "links": {},
                        "resources": {
                            "router": {"primary": {"id": ROUTER_ID}},
                            "router_interface": {
                                "primary": {"id": "", "name": "p010-router-interface"}
                            },
                            "tenant_subnet": {"primary": {"id": SUBNET_ID}},
                            "bgp_speaker": {"primary": {"id": SPEAKER_ID}},
                            "bgp_peer": {"primary": {"id": PEER_ID}},
                            "external_network": {"primary": {"id": NETWORK_ID}},
                        },
                    },
                },
            },
        }

    def run_relationship_flow(self):
        case_dir = self.scratch / "put-checkpoint-repeat-unlink"
        case_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        state_file = case_dir / "state.json"
        initial_state = self.make_state()
        state_file.write_text(json.dumps(initial_state), encoding="utf-8")
        state_file.chmod(0o600)
        LinkHandler.events = []

        relationships = [
            {
                "key": "router_interface",
                "put_path": f"/routers/{ROUTER_ID}/add_router_interface",
                "put_body": {"subnet_id": SUBNET_ID},
                "unlink_kind": "router_interface",
            },
            {
                "key": "bgp_peer",
                "put_path": f"/bgp-speakers/{SPEAKER_ID}/add_bgp_peer",
                "put_body": {"bgp_peer_id": PEER_ID},
                "unlink_kind": "generic",
                "unlink_path": f"/bgp-speakers/{SPEAKER_ID}/remove_bgp_peer",
                "unlink_body": {"bgp_peer_id": PEER_ID},
            },
            {
                "key": "bgp_gateway_network",
                "put_path": f"/bgp-speakers/{SPEAKER_ID}/add_gateway_network",
                "put_body": {"network_id": NETWORK_ID},
                "unlink_kind": "generic",
                "unlink_path": f"/bgp-speakers/{SPEAKER_ID}/remove_gateway_network",
                "unlink_body": {"network_id": NETWORK_ID},
            },
        ]
        tasks = [
            {
                "name": "Provide the protected guest alias using a local fake transport",
                "ansible.builtin.add_host": {
                    "name": "student_hybrid_ubuntu",
                    "ansible_connection": "local",
                },
            }
        ]

        for relationship in relationships:
            key = relationship["key"]
            put_vars = {
                "student_hybrid_api_link_key": key,
                "student_hybrid_api_path": relationship["put_path"],
                "student_hybrid_api_body": relationship["put_body"],
            }
            tasks.extend(
                [
                    {
                        "name": f"Run production PUT for {key}",
                        "ansible.builtin.include_tasks": str(
                            self.student_lab / "tasks/hybrid-m11-api-put.yml"
                        ),
                        "vars": put_vars,
                    },
                    {
                        "name": f"Reload the durable {key} checkpoint",
                        "ansible.builtin.slurp": {"src": str(state_file)},
                        "register": "student_test_state_reload",
                        "no_log": True,
                    },
                    {
                        "name": f"Use only the persisted {key} checkpoint",
                        "ansible.builtin.set_fact": {
                            "student_state": "{{ student_test_state_reload.content | b64decode | from_json }}"
                        },
                        "no_log": True,
                    },
                    {
                        "name": f"Require {key} to be saved with a resolved key",
                        "ansible.builtin.assert": {
                            "that": [
                                f"student_state.hybrid.m11.api.links['{key}'] | bool",
                                "student_state.hybrid.m11.api.pending == {}",
                                "student_state.hybrid.m11.api.links.keys() | list | difference(['last_request_id', 'router_interface', 'bgp_peer', 'bgp_gateway_network']) | length == 0",
                            ]
                        },
                        "no_log": True,
                    },
                    {
                        "name": f"Prove repeated PUT for {key} is refused before mutation",
                        "block": [
                            {
                                "name": f"Attempt duplicate {key} PUT",
                                "ansible.builtin.include_tasks": str(
                                    self.student_lab / "tasks/hybrid-m11-api-put.yml"
                                ),
                                "vars": put_vars,
                            }
                        ],
                        "rescue": [
                            {
                                "ansible.builtin.set_fact": {
                                    "student_test_duplicate_refused": True
                                },
                                "no_log": True,
                            }
                        ],
                    },
                    {
                        "name": f"Require duplicate {key} PUT to stop at the guard",
                        "ansible.builtin.assert": {
                            "that": ["student_test_duplicate_refused | default(false) | bool"]
                        },
                        "no_log": True,
                    },
                    {
                        "name": f"Reload {key} after its duplicate guard",
                        "ansible.builtin.slurp": {"src": str(state_file)},
                        "register": "student_test_state_reload",
                        "no_log": True,
                    },
                    {
                        "ansible.builtin.set_fact": {
                            "student_state": "{{ student_test_state_reload.content | b64decode | from_json }}"
                        },
                        "no_log": True,
                    },
                ]
            )
            if key == "router_interface":
                tasks.extend(
                    [
                        {
                            "name": "Persist the real returned router-interface port ID",
                            "ansible.builtin.include_tasks": str(
                                self.student_lab / "tasks/hybrid-m11-api-save.yml"
                            ),
                            "vars": {
                                "student_hybrid_api_state_patch": {
                                    "hybrid": {
                                        "m11": {
                                            "api": {
                                                "resources": {
                                                    "router_interface": {
                                                        "primary": "{{ student_state.hybrid.m11.api.resources.router_interface.primary | combine({'id': student_hybrid_api_put_response.json.port_id}) }}"
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            },
                            "no_log": True,
                        },
                        {
                            "name": "Reload router-interface ID from disk",
                            "ansible.builtin.slurp": {"src": str(state_file)},
                            "register": "student_test_state_reload",
                            "no_log": True,
                        },
                        {
                            "ansible.builtin.set_fact": {
                                "student_state": "{{ student_test_state_reload.content | b64decode | from_json }}"
                            },
                            "no_log": True,
                        },
                    ]
                )

            if relationship["unlink_kind"] == "router_interface":
                tasks.append(
                    {
                        "name": "Run the production router-interface unlink",
                        "ansible.builtin.include_tasks": str(
                            self.student_lab
                            / "tasks/hybrid-m11-api-remove-router-interface.yml"
                        ),
                    }
                )
            else:
                tasks.append(
                    {
                        "name": f"Run production unlink for {key}",
                        "ansible.builtin.include_tasks": str(
                            self.student_lab / "tasks/hybrid-m11-api-unlink.yml"
                        ),
                        "vars": {
                            "student_hybrid_api_link_key": key,
                            "student_hybrid_api_path": relationship["unlink_path"],
                            "student_hybrid_api_body": relationship["unlink_body"],
                        },
                    }
                )
            tasks.extend(
                [
                    {
                        "name": f"Reload {key} after unlink",
                        "ansible.builtin.slurp": {"src": str(state_file)},
                        "register": "student_test_state_reload",
                        "no_log": True,
                    },
                    {
                        "ansible.builtin.set_fact": {
                            "student_state": "{{ student_test_state_reload.content | b64decode | from_json }}"
                        },
                        "no_log": True,
                    },
                    {
                        "name": f"Require {key} unlink to clear only its saved relationship",
                        "ansible.builtin.assert": {
                            "that": [
                                f"not (student_state.hybrid.m11.api.links['{key}'] | bool)",
                                "student_state.hybrid.m11.api.pending == {}",
                                "student_state.hybrid.m11.api.links.keys() | list | difference(['last_request_id', 'router_interface', 'bgp_peer', 'bgp_gateway_network']) | length == 0",
                            ]
                        },
                        "no_log": True,
                    },
                ]
            )

        playbook = case_dir / "put-links.yml"
        playbook.write_text(
            yaml.safe_dump(
                [
                    {
                        "name": "Exercise exact API link checkpoint roundtrips",
                        "hosts": "localhost",
                        "connection": "local",
                        "gather_facts": False,
                        "vars": {
                            "student_state": initial_state,
                            "student_state_file": str(state_file),
                            "student_uid": os.getuid(),
                            "student_hybrid_api_token": "local-fake-token",
                        },
                        "tasks": tasks,
                    }
                ],
                sort_keys=False,
            ),
            encoding="utf-8",
        )
        argv = [str(self.ansible_playbook), "-i", "localhost,", str(playbook)]
        started_utc = datetime.now(timezone.utc).isoformat()
        env = os.environ.copy()
        env["ANSIBLE_CONFIG"] = str(self.student_lab / "ansible.cfg")
        env["ANSIBLE_NOCOLOR"] = "1"
        result = subprocess.run(
            argv,
            cwd=self.repo_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        log_path = case_dir / "ansible.log"
        log_path.write_text(result.stdout, encoding="utf-8")
        events = list(LinkHandler.events)
        (case_dir / "receipt.json").write_text(
            json.dumps(
                {
                    "started_utc": started_utc,
                    "argv": argv,
                    "rc": result.returncode,
                    "event_log": events,
                    "ansible_log_sha256": hashlib.sha256(
                        result.stdout.encode()
                    ).hexdigest(),
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        return case_dir, result, events

    def test_put_roundtrips_guards_repeats_and_unlinks_three_relationships(self):
        case_dir, result, events = self.run_relationship_flow()
        self.assertEqual(result.returncode, 0, result.stdout)
        state = json.loads((case_dir / "state.json").read_text(encoding="utf-8"))
        links = state["hybrid"]["m11"]["api"]["links"]
        self.assertTrue(all(links[key] is False for key in (
            "router_interface", "bgp_peer", "bgp_gateway_network"
        )))
        self.assertEqual(state["hybrid"]["m11"]["api"]["pending"], {})
        puts = [event for event in events if event["method"] == "PUT"]
        self.assertEqual(len(puts), 6, events)
        self.assertEqual(
            [event["path"] for event in puts],
            [
                f"/v2.0/routers/{ROUTER_ID}/add_router_interface",
                f"/v2.0/routers/{ROUTER_ID}/remove_router_interface",
                f"/v2.0/bgp-speakers/{SPEAKER_ID}/add_bgp_peer",
                f"/v2.0/bgp-speakers/{SPEAKER_ID}/remove_bgp_peer",
                f"/v2.0/bgp-speakers/{SPEAKER_ID}/add_gateway_network",
                f"/v2.0/bgp-speakers/{SPEAKER_ID}/remove_gateway_network",
            ],
        )
        self.assertEqual(
            [event["method"] for event in events].count("GET"), 1, events
        )
        self.assertNotIn("{{ student_hybrid_api_link_key }}", json.dumps(state))


if __name__ == "__main__":
    unittest.main()
