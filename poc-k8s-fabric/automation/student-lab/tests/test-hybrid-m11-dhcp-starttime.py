#!/usr/bin/env python3
"""Exercise the production DHCP starttime producer through saved state and stop."""

from __future__ import annotations

from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

import yaml


STARTTIME = 23456
CLIENT_MAC = "02:00:00:00:00:22"


def load_fixture_module(student_lab: Path):
    fixture_path = student_lab / "tests/test-hybrid-m11-positive-composition.py"
    spec = importlib.util.spec_from_file_location("positive_composition_fixture", fixture_path)
    if spec is None or spec.loader is None:
        raise RuntimeError("Cannot load the existing student-state fixture")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DhcpStarttimeRoundTrip(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.student_lab = Path(__file__).resolve().parents[1]
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
        scratch = os.environ.get("P010_HYBRID_API_TEST_SCRATCH")
        cls.scratch = Path(scratch) if scratch else Path(tempfile.mkdtemp(prefix="p010-hybrid22-dhcp-"))
        cls.scratch.mkdir(mode=0o700, parents=True, exist_ok=True)

    def setUp(self):
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
        self.case_dir = self.scratch / f"{self._testMethodName}-{stamp}"
        self.case_dir.mkdir(mode=0o700, parents=True)
        self.bin_dir = self.case_dir / "bin"
        self.bin_dir.mkdir(mode=0o700)
        self.proc_root = self.case_dir / "proc"
        self.proc_root.mkdir(mode=0o700)
        self.write_synthetic_stat(324, 333333)
        self.run_id = f"hybrid25-{self.case_dir.name.replace('.', '')}"
        self.capture = Path("/tmp") / f"p010-{self.run_id}-dhcp.log"
        self.result_file = Path("/tmp") / f"p010-{self.run_id}-dhcp.result"
        if self.capture.exists() or self.result_file.exists():
            raise RuntimeError("The unique DHCP test path already exists")
        self.capture.touch(mode=0o600)
        self.result_file.touch(mode=0o600)
        self.capture.chmod(0o600)
        self.result_file.chmod(0o600)
        self.ifindex_file = self.case_dir / "tenant0.ifindex"
        self.ifindex_file.write_text("5\n", encoding="ascii")
        self.state_file = self.case_dir / "state.json"
        self.producer_script = self.case_dir / "dhcp-producer.sh"
        self.finish_script = self.case_dir / "dhcp-finish.sh"
        self.stop_script = self.case_dir / "dhcp-stop.sh"
        self.events_file = self.case_dir / "events.jsonl"
        self.events_file.touch(mode=0o600)
        self.worker_pid: int | None = None
        self.install_command_fakes()

    def tearDown(self):
        if self.worker_pid is not None:
            try:
                os.kill(self.worker_pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        self.capture.unlink(missing_ok=True)
        self.result_file.unlink(missing_ok=True)

    def write_synthetic_stat(self, pid: int, starttime: int):
        proc = self.proc_root / str(pid)
        proc.mkdir(mode=0o700, parents=True, exist_ok=True)
        content = f"{pid} (capture worker (synthetic)) S" + " 0" * 16 + f" 1 0 {starttime}\n"
        (proc / "stat").write_text(content, encoding="ascii")

    def run_logged(self, argv: list[str], label: str, env: dict[str, str], cwd: Path | None = None):
        started = datetime.now(timezone.utc).isoformat()
        log = self.case_dir / f"{label}.log"
        result = subprocess.run(
            argv,
            cwd=cwd or self.student_lab.parents[2],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        log.write_text(result.stdout, encoding="utf-8")
        receipt = {"started_utc": started, "argv": argv, "rc": result.returncode, "log": str(log)}
        (self.case_dir / f"{label}.receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        self.assertEqual(result.returncode, 0, result.stdout)
        return result.stdout

    def ansible_env(self) -> dict[str, str]:
        env = os.environ.copy()
        env.update(
            {
                "ANSIBLE_CONFIG": str(self.student_lab / "ansible.cfg"),
                "ANSIBLE_NOCOLOR": "1",
                "PYTHONDONTWRITEBYTECODE": "1",
            }
        )
        return env

    def install_command_fakes(self):
        sudo = self.bin_dir / "sudo"
        sudo.write_text(
            "#!/bin/bash\n"
            "set -euo pipefail\n"
            "[[ \"${1:-}\" == -n ]] && shift\n"
            "map_proc() { case \"$1\" in /proc/*) printf '%s/%s' \"${P010_HYBRID22_PROC_ROOT}\" \"${1#/proc/}\" ;; *) printf '%s' \"$1\" ;; esac; }\n"
            "write_stat() { local pid=\"$1\" path=\"$2\" start=\"$3\"; { printf '%s (capture worker (synthetic)) S' \"$pid\"; for _ in {1..16}; do printf ' 0'; done; printf ' 1 0 %s\\n' \"$start\"; } >\"$path/stat\"; }\n"
            "case \"${1:-}\" in\n"
            "  /usr/bin/timeout)\n"
            "    launcher=$$\n"
            "    proc=\"${P010_HYBRID22_PROC_ROOT}/${launcher}\"\n"
            "    mkdir -m 0700 -p \"$proc/task/$launcher\" \"$proc/ns\"\n"
            "    write_stat \"$launcher\" \"$proc\" \"${P010_HYBRID22_STARTTIME}\"\n"
            "    printf '%s\\0' '/usr/bin/timeout' '120' '/usr/sbin/tcpdump' '-n' '-e' '-vv' '-l' '-c' '32' '-i' 'tenant0' 'udp and (port 67 or port 68)' >\"$proc/cmdline\"\n"
            "    ln -s 'net:[4026531840]' \"$proc/ns/net\"\n"
            "    ( while [ ! -e \"${P010_HYBRID22_STOP_FILE}\" ]; do /bin/sleep 0.05; done; exit 130 ) & child=$!\n"
            "    child_proc=\"${P010_HYBRID22_PROC_ROOT}/${child}\"\n"
            "    mkdir -m 0700 -p \"$child_proc/ns\"\n"
            "    write_stat \"$child\" \"$child_proc\" \"${P010_HYBRID22_TCPDUMP_STARTTIME}\"\n"
            "    printf '%s\\0' '/usr/sbin/tcpdump' '-n' '-e' '-vv' '-l' '-c' '32' '-i' 'tenant0' 'udp and (port 67 or port 68)' >\"$child_proc/cmdline\"\n"
            "    ln -s 'net:[4026531840]' \"$child_proc/ns/net\"\n"
            "    printf '%s\\n' \"$child\" >\"$proc/task/$launcher/children\"\n"
            "    printf '%s\\n' \"$child\" >\"${P010_HYBRID22_WORKER_PID}\"\n"
            "    printf 'listening on tenant0, link-type EN10MB (Ethernet)\\n' >\"${P010_HYBRID22_CAPTURE_PATH}\"\n"
            "    printf '%s\\n' \"$launcher\" >\"${P010_HYBRID22_LAUNCHER_PID_FILE}\"\n"
            "    set +e; wait \"$child\"; rc=$?\n"
            "    printf '4 packets captured\\n8 packets received by filter\\n0 packets dropped by kernel\\n' >>\"${P010_HYBRID22_CAPTURE_PATH}\"\n"
            "    rm -rf -- \"$proc\" \"$child_proc\" \"${P010_HYBRID22_PROC_ROOT}/${P010_HYBRID22_SUPERVISOR_PID}\"\n"
            "    exit \"$rc\"\n"
            "    ;;\n"
            "  /usr/bin/stat)\n"
            "    shift; [[ \"$1\" == -c ]] || exit 65; format=\"$2\"; path=\"$(map_proc \"$3\")\"\n"
            "    case \"$format\" in '%u') exec /usr/bin/stat -f '%u' \"$path\" ;; *) exit 66 ;; esac\n"
            "    ;;\n"
            "  /usr/bin/awk)\n"
            "    shift; args=(); for arg in \"$@\"; do args+=(\"$(map_proc \"$arg\")\"); done; exec /usr/bin/awk \"${args[@]}\"\n"
            "    ;;\n"
            "  /usr/bin/cat) shift; path=\"$(map_proc \"$1\")\"; exec /bin/cat \"$path\" ;;\n"
            "  /usr/bin/readlink) shift; path=\"$(map_proc \"$1\")\"; exec /usr/bin/readlink \"$path\" ;;\n"
            "  /usr/bin/kill)\n"
            "    shift; signal=\"$1\"; pid=\"$2\"\n"
            "    printf '%s %s\\n' \"$signal\" \"$pid\" >>\"${P010_HYBRID22_KILL_LOG}\"\n"
            "    : >\"${P010_HYBRID22_STOP_FILE}\"\n"
            "    ;;\n"
            "  *) printf 'unexpected synthetic sudo target\\n' >&2; exit 64 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        sudo.chmod(0o700)
        stat = self.bin_dir / "stat"
        stat.write_text(
            "#!/bin/bash\n"
            "set -euo pipefail\n"
            "[[ \"$1\" == -c ]] || exit 65\n"
            "case \"$2\" in\n"
            "  '%d|%i|%u|%a') exec /usr/bin/stat -f '%d|%i|%u|%Lp' \"$3\" ;;\n"
            "  '%u|%a') exec /usr/bin/stat -f '%u|%Lp' \"$3\" ;;\n"
            "  '%u') exec /usr/bin/stat -f '%u' \"$3\" ;;\n"
            "  '%a') exec /usr/bin/stat -f '%Lp' \"$3\" ;;\n"
            "  *) exit 66 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        stat.chmod(0o700)

    def command_env(self) -> dict[str, str]:
        env = self.ansible_env()
        env.update(
            {
                "PATH": f"{self.bin_dir}:{env['PATH']}",
                "P010_HYBRID22_PROC_ROOT": str(self.proc_root),
                "P010_HYBRID22_STARTTIME": str(STARTTIME),
                "P010_HYBRID22_TCPDUMP_STARTTIME": str(STARTTIME + 1),
                "P010_HYBRID22_CLIENT_MAC": CLIENT_MAC,
                "P010_HYBRID22_UID": str(os.getuid()),
                "P010_HYBRID22_WORKER_PID": str(self.case_dir / "worker.pid"),
                "P010_HYBRID22_LAUNCHER_PID_FILE": str(self.case_dir / "launcher.pid"),
                "P010_HYBRID22_KILL_LOG": str(self.case_dir / "kill.log"),
                "P010_HYBRID22_STOP_FILE": str(self.case_dir / "stop.requested"),
                "P010_HYBRID22_TRACE": str(self.case_dir / "producer.trace"),
                "P010_HYBRID22_CAPTURE_PATH": str(self.capture),
                "P010_HYBRID22_RESULT_PATH": str(self.result_file),
                "P010_HYBRID22_IFINDEX_FILE": str(self.ifindex_file),
                "P010_HYBRID22_SUPERVISOR_PID": "324",
                "P010_HYBRID22_SUPERVISOR_STARTTIME": "333333",
            }
        )
        return env

    def production_tasks(self) -> list[dict]:
        document = yaml.safe_load((self.student_lab / "tasks/hybrid-m11-up.yml").read_text(encoding="utf-8"))
        wanted = {
            "Start a bounded DHCP capture on the Neutron-attached guest interface",
            "Parse the DHCP capture markers without rewriting their values",
            "Retain the parsed DHCP capture markers",
            "Require a private capture file and a running command bound to tenant0",
            "Checkpoint the bounded DHCP capture process before booting CirrOS",
            "Persist the capture process identity before starting CirrOS",
        }
        tasks = [task for task in document if task.get("name") in wanted]
        if {task.get("name") for task in tasks} != wanted:
            raise AssertionError("The production DHCP tasks changed; update the focused extraction deliberately")
        return tasks

    def initial_state(self) -> dict:
        return {
            "schema": 3,
            "run_id": self.run_id,
            "owner_uid": os.getuid(),
            "profile": "hibrido",
            "status": "partial",
            "phase": "hybrid-dhcp-capture-pending",
            "hybrid": {
                "schema": 4,
                "network": {"tenant_gateway": "198.18.49.1"},
                "guests": {"cirros": {"tenant_mac": CLIENT_MAC}},
                "m11": {
                    "schema": 2,
                    "network": {"tenant_gateway": "198.18.49.1"},
                    "api": {"resources": {"cirros_port": {"primary": {"fixed_ips": [{"ip_address": "198.18.49.4"}]}}}},
                    "verification": {
                        "gates": {
                            "dhcp_server": {"ip_address": "198.18.49.1"},
                            "dhcp_capture": {
                                "phase": "starting",
                                "path": str(self.capture),
                                "result_path": str(self.result_file),
                                "client_mac": CLIENT_MAC,
                                "address": "198.18.49.4",
                                "gateway": "198.18.49.1",
                                "server_ip": "198.18.49.1",
                                "server_mac": "52:54:00:10:12:01",
                                "pid": 0,
                                "starttime": 0,
                                "process_uid": 0,
                                "owner_uid": os.getuid(),
                                "device": self.capture.stat().st_dev,
                                "inode": self.capture.stat().st_ino,
                                "result_owner_uid": os.getuid(),
                                "result_device": self.result_file.stat().st_dev,
                                "result_inode": self.result_file.stat().st_ino,
                                "xid": "",
                            },
                        }
                    },
                },
            },
        }

    def render_producer(self, state: dict):
        source_play = self.case_dir / "render-producer.yml"
        task = next(
            item for item in self.production_tasks()
            if item.get("name") == "Start a bounded DHCP capture on the Neutron-attached guest interface"
        )
        play = [
            {
                "name": "Render the production DHCP process-identity producer",
                "hosts": "localhost",
                "connection": "local",
                "gather_facts": False,
                "vars": {"student_state": state},
                "tasks": [
                    task,
                    {
                        "name": "Write the rendered production script to private test scratch",
                        "ansible.builtin.copy": {
                            "dest": str(self.producer_script),
                            "content": "{{ student_hybrid_m11_dhcp_start_script }}\n",
                            "mode": "0700",
                        },
                    },
                ],
            }
        ]
        source_play.write_text(yaml.safe_dump(play, sort_keys=False), encoding="utf-8")
        env = self.ansible_env()
        self.run_logged([str(self.ansible_playbook), "-i", "localhost,", str(source_play)], "render-producer", env)

    def run_real_producer_shell(self):
        rendered = self.producer_script.read_text(encoding="utf-8")
        rendered = rendered.replace('"/proc/$pid/stat"', '"$P010_HYBRID22_PROC_ROOT/$pid/stat"')
        rendered = rendered.replace('"/proc/$pid/cmdline"', '"$P010_HYBRID22_PROC_ROOT/$pid/cmdline"')
        rendered = rendered.replace('"/proc/$pid/ns/net"', '"$P010_HYBRID22_PROC_ROOT/$pid/ns/net"')
        rendered = rendered.replace('"/proc/$candidate_pid/cmdline"', '"$P010_HYBRID22_PROC_ROOT/$candidate_pid/cmdline"')
        rendered = rendered.replace('"/proc/$parent_pid/task/$parent_pid/children"', '"$P010_HYBRID22_PROC_ROOT/$parent_pid/task/$parent_pid/children"')
        rendered = rendered.replace('"/proc/$supervisor_pid/stat"', '"$P010_HYBRID22_PROC_ROOT/$supervisor_pid/stat"')
        rendered = rendered.replace('"/proc/$supervisor_pid"', '"$P010_HYBRID22_PROC_ROOT/$supervisor_pid"')
        rendered = rendered.replace('supervisor_pid="$BASHPID"', 'supervisor_pid="$P010_HYBRID22_SUPERVISOR_PID"')
        rendered = rendered.replace('supervisor_pid=$!', 'supervisor_pid="$P010_HYBRID22_SUPERVISOR_PID"')
        rendered = rendered.replace('/sys/class/net/tenant0/ifindex', '"$P010_HYBRID22_IFINDEX_FILE"')
        rendered = rendered.replace("exec >/dev/null 2>&1", 'exec >"$P010_HYBRID22_TRACE" 2>&1\nset -x')
        if "/proc/$pid/stat" in rendered or "/proc/$pid/cmdline" in rendered or "/proc/$pid/ns/net" in rendered:
            raise AssertionError("The local test adaptation did not replace the two proc observations")
        self.producer_script.write_text(rendered, encoding="utf-8")
        self.producer_script.chmod(0o700)
        env = self.command_env()
        stdout = self.run_logged(["bash", str(self.producer_script)], "run-producer", env, self.case_dir)
        self.worker_pid = int((self.case_dir / "worker.pid").read_text(encoding="ascii").strip())
        self.launcher_pid = int((self.case_dir / "launcher.pid").read_text(encoding="ascii").strip())
        markers = [line for line in stdout.splitlines() if line.startswith("P010_DHCP_")]
        expected = {
            "P010_DHCP_PID": str(self.launcher_pid),
            "P010_DHCP_STARTTIME": str(STARTTIME),
            "P010_DHCP_UID": str(os.getuid()),
        }
        observed = dict(line.split("=", 1) for line in markers)
        for key, value in expected.items():
            self.assertEqual(observed.get(key), value)
        self.assertRegex(observed["P010_DHCP_FILE"], r"^[0-9]+\|[0-9]+\|[0-9]+\|600$")
        self.assertRegex(observed["P010_DHCP_RESULT_FILE"], r"^[0-9]+\|[0-9]+\|[0-9]+\|600$")
        self.assertEqual(observed["P010_DHCP_TCPDUMP_STARTTIME"], str(STARTTIME + 1))
        self.assertEqual(observed["P010_DHCP_TCPDUMP_PID"], str(self.worker_pid))
        self.assertIn(r'sub(/^.*\) /, ""); print $20', self.producer_script.read_text(encoding="utf-8"))
        return markers

    def checkpoint_and_render_finish(self, markers: list[str], state: dict):
        play_path = self.case_dir / "checkpoint-and-render-finish.yml"
        tasks = self.production_tasks()
        finish_tasks = yaml.safe_load((self.student_lab / "tasks/hybrid-m11-finish-dhcp-capture.yml").read_text(encoding="utf-8"))
        finish_render_task = next(
            task for task in finish_tasks
            if task.get("name") == "Render the exact bounded DHCP observer finish request"
        )
        parse_and_checkpoint = [
            {"name": "Provide the exact stdout from the executed production producer at the SSH seam", "ansible.builtin.set_fact": {"student_hybrid_ssh_result": {"rc": 0, "stdout_lines": markers}}, "no_log": True},
        ]
        parse_and_checkpoint.extend(
            task for task in tasks
            if task.get("name") in {
                "Parse the DHCP capture markers without rewriting their values",
                "Retain the parsed DHCP capture markers",
                "Require a private capture file and a running command bound to tenant0",
                "Checkpoint the bounded DHCP capture process before booting CirrOS",
                "Persist the capture process identity before starting CirrOS",
            }
        )
        for task in parse_and_checkpoint:
            if task.get("name") == "Parse the DHCP capture markers without rewriting their values":
                task["ansible.builtin.include_tasks"] = str(self.student_lab / "tasks/hybrid-m11-parse-markers.yml")
        parse_and_checkpoint.extend(
            [
                {"name": "Reload the durable checkpoint from disk as the next process would", "ansible.builtin.slurp": {"src": str(self.state_file)}, "register": "dhcp_saved_state", "no_log": True},
                {"name": "Use only the state loaded from the durable file", "ansible.builtin.set_fact": {"student_state": "{{ dhcp_saved_state.content | b64decode | from_json }}"}, "no_log": True},
                finish_render_task,
                {"name": "Write the rendered production DHCP finish script to test scratch", "ansible.builtin.copy": {"dest": str(self.finish_script), "content": "{{ student_hybrid_m11_dhcp_finish_script }}\n", "mode": "0700"}},
            ]
        )
        play = [
            {
                "name": "Parse producer stdout, checkpoint its process identity, reload, and render finish",
                "hosts": "localhost",
                "connection": "local",
                "gather_facts": True,
                "vars": {
                    "student_state": state,
                    "student_state_file": str(self.state_file),
                    "student_uid": os.getuid(),
                    "student_hybrid_ssh_result": {"rc": 0, "stdout_lines": markers},
                },
                "tasks": parse_and_checkpoint,
            }
        ]
        play_path.write_text(yaml.safe_dump(play, sort_keys=False), encoding="utf-8")
        self.run_logged([str(self.ansible_playbook), "-i", "localhost,", str(play_path)], "checkpoint-and-render-finish", self.ansible_env())
        saved = json.loads(self.state_file.read_text(encoding="utf-8"))
        capture = saved["hybrid"]["m11"]["verification"]["gates"]["dhcp_capture"]
        self.assertEqual(capture["phase"], "capturing")
        self.assertEqual(capture["pid"], self.launcher_pid)
        self.assertEqual(capture["starttime"], STARTTIME)
        self.assertEqual(capture["process_uid"], os.getuid())
        self.assertEqual(capture["tcpdump_pid"], self.worker_pid)
        self.assertEqual(capture["tcpdump_starttime"], STARTTIME + 1)
        self.assertEqual(capture["inode"], self.capture.stat().st_ino)
        self.assertEqual(self.state_file.stat().st_mode & 0o777, 0o600)

    def run_real_finish_shell(self):
        rendered = self.finish_script.read_text(encoding="utf-8")
        rendered = rendered.replace('"/proc/$tcpdump_pid/stat"', '"$P010_HYBRID22_PROC_ROOT/$tcpdump_pid/stat"')
        rendered = rendered.replace("exec >/dev/null 2>&1", 'exec >"$P010_HYBRID22_FINISH_TRACE" 2>&1\nset -x')
        if '"/proc/$tcpdump_pid/stat"' in rendered:
            raise AssertionError("The local finish adaptation did not replace its direct proc existence check")
        self.finish_script.write_text(rendered, encoding="utf-8")
        self.finish_script.chmod(0o700)
        env = self.command_env()
        env["P010_HYBRID22_FINISH_TRACE"] = str(self.case_dir / "finish.trace")
        stdout = self.run_logged(["bash", str(self.finish_script)], "run-finish", env, self.case_dir)
        observed = {line.split("=", 1)[0]: line.split("=", 1)[1] for line in stdout.splitlines() if line.startswith("P010_DHCP_")}
        self.assertEqual(observed["P010_DHCP_FINISH_RC"], "130")
        self.assertEqual(observed["P010_DHCP_STOP_REQUESTED"], "1")
        self.assertEqual(observed["P010_DHCP_FINISH_CAPTURED_COUNT"], "4")
        self.assertIn("8 packets received by filter", self.capture.read_text(encoding="utf-8"))
        self.assertIn("0 packets dropped by kernel", self.capture.read_text(encoding="utf-8"))
        return stdout.splitlines()

    def checkpoint_finish_and_render_cleanup(self, markers: list[str]):
        play_path = self.case_dir / "checkpoint-finish-render-cleanup.yml"
        finish_tasks = yaml.safe_load((self.student_lab / "tasks/hybrid-m11-finish-dhcp-capture.yml").read_text(encoding="utf-8"))
        wanted = {
            "Require a completed bounded DHCP capture with an explicit command status",
            "Retain the completed observer status markers",
            "Checkpoint that the observer completed before parsing DORA",
            "Persist the completed capture status for DORA parsing and later cleanup",
        }
        tasks = [task for task in finish_tasks if task.get("name") in wanted]
        if {task.get("name") for task in tasks} != wanted:
            raise AssertionError("The production finish checkpoint tasks changed; update the focused extraction deliberately")
        for task in tasks:
            if task.get("name") == "Retain the completed observer status markers":
                task["ansible.builtin.include_tasks"] = str(self.student_lab / "tasks/hybrid-m11-parse-markers.yml")
        tasks = [
            {"name": "Provide the exact stdout from the executed production finish script at the SSH seam", "ansible.builtin.set_fact": {"student_hybrid_ssh_result": {"rc": 0, "stdout_lines": markers}}, "no_log": True},
            *tasks,
            {"name": "Reload the completed DHCP checkpoint from disk", "ansible.builtin.slurp": {"src": str(self.state_file)}, "register": "dhcp_finished_state", "no_log": True},
            {"name": "Use only the reloaded completed DHCP state", "ansible.builtin.set_fact": {"student_state": "{{ dhcp_finished_state.content | b64decode | from_json }}"}, "no_log": True},
            {"name": "Render production cleanup from the completed state", "ansible.builtin.include_tasks": str(self.student_lab / "tasks/hybrid-m11-build-stop-dhcp-script.yml")},
            {"name": "Write the rendered production cleanup script to test scratch", "ansible.builtin.copy": {"dest": str(self.stop_script), "content": "{{ student_hybrid_m11_stop_dhcp_script }}\n", "mode": "0700"}},
        ]
        play = [{
            "name": "Apply the production finish checkpoint, reload, and prepare exact cleanup",
            "hosts": "localhost",
            "connection": "local",
            "gather_facts": True,
            "vars": {
                "student_state": json.loads(self.state_file.read_text(encoding="utf-8")),
                "student_state_file": str(self.state_file),
                "student_uid": os.getuid(),
                "student_hybrid_ssh_result": {"rc": 0, "stdout_lines": markers},
            },
            "tasks": tasks,
        }]
        play_path.write_text(yaml.safe_dump(play, sort_keys=False), encoding="utf-8")
        self.run_logged([str(self.ansible_playbook), "-i", "localhost,", str(play_path)], "checkpoint-finish-render-cleanup", self.ansible_env())
        saved = json.loads(self.state_file.read_text(encoding="utf-8"))
        capture = saved["hybrid"]["m11"]["verification"]["gates"]["dhcp_capture"]
        self.assertEqual(capture["phase"], "captured")
        self.assertEqual(capture["capture_rc"], 130)
        self.assertTrue(capture["stop_requested"])
        self.assertEqual(capture["captured_count"], 4)
        self.assertTrue(capture["completed_utc"].startswith("20"))
        self.assertEqual(self.state_file.stat().st_mode & 0o777, 0o600)

    def run_real_stop_shell(self):
        rendered = self.stop_script.read_text(encoding="utf-8").replace(
            "proc_root=/proc", 'proc_root="$P010_HYBRID22_PROC_ROOT"'
        )
        rendered = rendered.replace("exec >/dev/null 2>&1", 'exec >"$P010_HYBRID22_STOP_TRACE" 2>&1\nset -x')
        if "proc_root=/proc" in rendered:
            raise AssertionError("The local stop adaptation did not replace proc_root")
        self.stop_script.write_text(rendered, encoding="utf-8")
        self.stop_script.chmod(0o700)
        env = self.command_env()
        env["P010_HYBRID22_STOP_TRACE"] = str(self.case_dir / "stop.trace")
        kill_log = self.case_dir / "kill.log"
        env["P010_HYBRID22_KILL_LOG"] = str(kill_log)
        saved_state = json.loads(self.state_file.read_text(encoding="utf-8"))
        capture = saved_state["hybrid"]["m11"]["verification"]["gates"]["dhcp_capture"]
        env["P010_HYBRID22_LAUNCHER_PID_VALUE"] = str(capture["pid"])
        env["P010_HYBRID22_SUPERVISOR_PID"] = str(capture["supervisor_pid"])
        stdout = self.run_logged(["bash", str(self.stop_script)], "run-stop", env, self.case_dir)
        self.assertIn("P010_M11_DHCP_CAPTURE=absent", stdout)
        self.assertFalse(self.capture.exists())
        self.assertEqual(kill_log.read_text(encoding="ascii").strip(), f"-INT {self.worker_pid}")
        self.assertFalse((self.proc_root / str(self.worker_pid) / "stat").exists())

    def test_real_producer_finish_checkpoint_reload_and_cleanup_use_proc_starttime_22(self):
        state = self.initial_state()
        self.render_producer(state)
        markers = self.run_real_producer_shell()
        self.checkpoint_and_render_finish(markers, state)
        finish_markers = self.run_real_finish_shell()
        self.checkpoint_finish_and_render_cleanup(finish_markers)
        self.run_real_stop_shell()


if __name__ == "__main__":
    unittest.main()
