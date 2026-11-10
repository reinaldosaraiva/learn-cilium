#!/usr/bin/env python3
"""Exercise pinned API cleanup and effective SSH options with local fakes."""

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import yaml


AGENT_ID = "11111111-1111-4111-8111-111111111111"
SPEAKER_ID = "22222222-2222-4222-8222-222222222222"
RUN_ID = "33333333-3333-4333-8333-333333333333"


class ApiHandler(BaseHTTPRequestHandler):
    response_body = {"bgp_speakers": []}
    response_status = 200
    seen = []

    def do_GET(self):
        type(self).seen.append(self.path)
        body = json.dumps(type(self).response_body).encode()
        self.send_response(type(self).response_status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return


class ApiRuntimeContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.student_lab = Path(__file__).resolve().parents[1]
        cls.repo_root = cls.student_lab.parents[2]
        cls.ansible_playbook = Path(
            os.environ.get("ANSIBLE_PLAYBOOK_BIN", "")
        )
        if not cls.ansible_playbook.is_file():
            cls.ansible_playbook = Path(shutil.which("ansible-playbook") or "")
        if not cls.ansible_playbook.is_file():
            raise unittest.SkipTest("ansible-playbook is not available")
        cls.scratch = Path(
            os.environ.get("P010_HYBRID_API_TEST_SCRATCH")
            or tempfile.mkdtemp(prefix="p010-hybrid-api-runtime-")
        )
        cls.scratch.mkdir(mode=0o700, parents=True, exist_ok=True)
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), ApiHandler)
        cls.server_thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.server_thread.start()
        cls.endpoint = f"http://127.0.0.1:{cls.httpd.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()
        cls.server_thread.join(timeout=5)

    def make_state(self, state_path):
        return {
            "run_id": RUN_ID,
            "hybrid": {
                "m11": {
                    "phase": "api-removing",
                    "api": {
                        "neutron_endpoint": self.endpoint,
                        "pending": {
                            "method": "DELETE",
                            "run_id": RUN_ID,
                            "resource": "relation:drinstance",
                            "path": f"/agents/{AGENT_ID}/bgp-drinstances/{SPEAKER_ID}",
                            "collection_path": f"/agents/{AGENT_ID}/bgp-drinstances",
                            "agent_id": AGENT_ID,
                            "speaker_id": SPEAKER_ID,
                        },
                        "agent_ids": {"bgp": AGENT_ID},
                        "resources": {
                            "bgp_speaker": {"primary": {"id": SPEAKER_ID}},
                            "drinstance": {
                                "primary": {
                                    "id": "",
                                    "name": "",
                                    "agent_id": AGENT_ID,
                                    "speaker_id": SPEAKER_ID,
                                }
                            },
                        },
                        "links": {
                            "drinstance": {
                                "agent_id": AGENT_ID,
                                "speaker_id": SPEAKER_ID,
                                "method": "POST",
                                "status": 201,
                                "envelope": "bgp_speakers",
                            }
                        },
                    },
                }
            },
        }

    def run_reconcile(self, label, body, status=200):
        case_dir = self.scratch / label
        case_dir.mkdir(mode=0o700, parents=True)
        state_file = case_dir / "state.json"
        state_file.write_text(json.dumps(self.make_state(state_file)), encoding="utf-8")
        ApiHandler.response_body = body
        ApiHandler.response_status = status
        ApiHandler.seen = []
        playbook = case_dir / "reconcile.yml"
        playbook.write_text(
            yaml.safe_dump(
                [
                    {
                        "name": f"Exercise {label}",
                        "hosts": "localhost",
                        "connection": "local",
                        "gather_facts": False,
                        "vars": {
                            "student_state": self.make_state(state_file),
                            "student_state_file": str(state_file),
                            "student_uid": os.getuid(),
                            "student_hybrid_api_mode": "remove-routing",
                            "student_hybrid_api_token": "local-fake-token",
                        },
                        "tasks": [
                            {
                                "name": "Add a local alias for the production URI task",
                                "ansible.builtin.add_host": {
                                    "name": "student_hybrid_ubuntu",
                                    "ansible_connection": "local",
                                },
                            },
                            {
                                "name": "Run production uncertain DELETE reconciliation",
                                "ansible.builtin.include_tasks": str(
                                    self.student_lab
                                    / "tasks/hybrid-m11-api-reconcile-delete.yml"
                                ),
                            },
                            {
                                "name": "Assert the resulting relationship checkpoint",
                                "ansible.builtin.assert": {
                                    "that": [
                                        "student_state.hybrid.m11.api.pending | length == 0",
                                        "student_state.hybrid.m11.api.resources.bgp_speaker.primary.id == '"
                                        + SPEAKER_ID
                                        + "'",
                                        "student_state.hybrid.m11.api.links.drinstance.speaker_id == '"
                                        + (
                                            SPEAKER_ID
                                            if status == 200
                                            and body.get("bgp_speakers")
                                            else ""
                                        )
                                        + "'",
                                    ]
                                },
                            },
                        ],
                    }
                ],
                sort_keys=False,
            ),
            encoding="utf-8",
        )
        argv = [str(self.ansible_playbook), "-i", "localhost,", str(playbook)]
        started = datetime.now(timezone.utc).isoformat()
        result = subprocess.run(
            argv,
            cwd=self.repo_root,
            env=os.environ.copy(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        (case_dir / "ansible.log").write_text(result.stdout, encoding="utf-8")
        (case_dir / "receipt.json").write_text(
            json.dumps(
                {
                    "started_utc": started,
                    "argv": argv,
                    "rc": result.returncode,
                    "http_status": status,
                    "http_paths": ApiHandler.seen,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        return case_dir, result

    def test_uncertain_delete_reads_only_saved_collection_and_distinguishes_presence(self):
        case_dir, result = self.run_reconcile(
            "scheduler-absent", {"bgp_speakers": []}
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(ApiHandler.seen, [f"/agents/{AGENT_ID}/bgp-drinstances"])
        saved = json.loads((case_dir / "state.json").read_text(encoding="utf-8"))
        self.assertEqual(saved["hybrid"]["m11"]["api"]["pending"], {})
        self.assertEqual(saved["hybrid"]["m11"]["api"]["links"]["drinstance"]["speaker_id"], "")
        self.assertEqual(
            saved["hybrid"]["m11"]["api"]["resources"]["bgp_speaker"]["primary"]["id"],
            SPEAKER_ID,
        )

        case_dir, result = self.run_reconcile(
            "scheduler-present", {"bgp_speakers": [{"id": SPEAKER_ID}]}
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(ApiHandler.seen, [f"/agents/{AGENT_ID}/bgp-drinstances"])
        saved = json.loads((case_dir / "state.json").read_text(encoding="utf-8"))
        self.assertEqual(saved["hybrid"]["m11"]["api"]["pending"], {})
        self.assertEqual(saved["hybrid"]["m11"]["api"]["links"]["drinstance"]["speaker_id"], SPEAKER_ID)

    def test_uncertain_delete_query_error_keeps_pending_identity(self):
        case_dir, result = self.run_reconcile(
            "scheduler-query-error", {"error": "unavailable"}, status=503
        )
        self.assertNotEqual(result.returncode, 0)
        saved = json.loads((case_dir / "state.json").read_text(encoding="utf-8"))
        self.assertEqual(
            saved["hybrid"]["m11"]["api"]["pending"]["resource"],
            "relation:drinstance",
        )
        self.assertEqual(saved["hybrid"]["m11"]["api"]["links"]["drinstance"]["speaker_id"], SPEAKER_ID)


class EffectiveSshOptions(unittest.TestCase):
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
            os.environ.get("P010_HYBRID_API_TEST_SCRATCH")
            or tempfile.mkdtemp(prefix="p010-hybrid-api-ssh-options-")
        )
        cls.scratch.mkdir(mode=0o700, parents=True, exist_ok=True)

    def test_ansible_ssh_plugin_receives_strict_pinning_effectively(self):
        case_dir = self.scratch / "effective-ssh-options"
        case_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        source = yaml.safe_load(
            (self.student_lab / "hybrid-m11-api-playbook.yml").read_text(
                encoding="utf-8"
            )
        )[0]
        add_host = next(
            task for task in source["tasks"] if "ansible.builtin.add_host" in task
        )
        fake_ssh = case_dir / "ssh"
        captured = case_dir / "ssh-argv.json"
        fake_ssh.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "with open(os.environ['P010_FAKE_SSH_CAPTURE'], 'w', encoding='utf-8') as f:\n"
            "    json.dump(sys.argv[1:], f)\n"
            "print('')\n"
            "raise SystemExit(0)\n",
            encoding="utf-8",
        )
        fake_ssh.chmod(0o700)
        playbook = case_dir / "effective-ssh.yml"
        playbook.write_text(
            yaml.safe_dump(
                [
                    {
                        "name": "Exercise the production add_host SSH variables",
                        "hosts": "localhost",
                        "connection": "local",
                        "gather_facts": False,
                        "vars": {
                            "student_state": {
                                "hybrid": {
                                    "guests": {
                                        "ubuntu": {
                                            "host_port": 2222,
                                            "ssh_private_key": str(case_dir / "id_ed25519"),
                                        }
                                    },
                                    "m11": {
                                        "ssh": {
                                            "known_hosts_path": str(case_dir / "known_hosts"),
                                            "host_keys": {"ubuntu": {"alias": "p010-test-ubuntu"}},
                                        }
                                    },
                                }
                            }
                        },
                        "tasks": [
                            add_host,
                            {
                                "name": "Invoke a remote raw command through the fake SSH binary",
                                "ansible.builtin.raw": "true",
                                "delegate_to": "student_hybrid_ubuntu",
                                "changed_when": False,
                            },
                        ],
                    }
                ],
                sort_keys=False,
            ),
            encoding="utf-8",
        )
        argv = [str(self.ansible_playbook), "-i", "localhost,", str(playbook)]
        env = os.environ.copy()
        env["P010_FAKE_SSH_CAPTURE"] = str(captured)
        env["PATH"] = f"{case_dir}{os.pathsep}{env.get('PATH', '')}"
        env["ANSIBLE_CONFIG"] = str(self.student_lab / "ansible.cfg")
        started = datetime.now(timezone.utc).isoformat()
        result = subprocess.run(
            argv,
            cwd=self.repo_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        (case_dir / "ansible.log").write_text(result.stdout, encoding="utf-8")
        options = json.loads(captured.read_text(encoding="utf-8")) if captured.exists() else []
        strict_values = [
            options[index + 1].split("=", 1)[1]
            for index, value in enumerate(options[:-1])
            if value == "-o" and options[index + 1].startswith("StrictHostKeyChecking=")
        ]
        (case_dir / "receipt.json").write_text(
            json.dumps(
                {"started_utc": started, "argv": argv, "rc": result.returncode, "strict_values": strict_values},
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(strict_values, options)
        self.assertEqual(strict_values[0], "yes", options)
        self.assertNotIn("no", strict_values, options)


if __name__ == "__main__":
    unittest.main()
