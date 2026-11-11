#!/usr/bin/env python3
"""Exercise border capture against the active profile and saved identities."""

from __future__ import annotations

from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml


BASELINE_SHA256 = "ad2eb7e0f3efab66e8388a3aa1cd9dc13990ffbfa6c32cc25eafd679e73b2a0a"
OWNER_TOKEN = "11111111-1111-4111-8111-111111111111"
CONTAINER_ID = "a" * 64
OTHER_CONTAINER_ID = "b" * 64
PID = 4444
STARTTIME = 123456


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class HybridBorderCaptureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.student_lab = Path(__file__).resolve().parents[1]
        cls.project_root = cls.student_lab.parents[2]
        cls.vars_path = cls.student_lab / "vars.yml"
        cls.profile = yaml.safe_load(cls.vars_path.read_text(encoding="utf-8"))["student_profiles"]["hibrido"]
        cls.production_task = cls.student_lab / "tasks/hybrid-m11-capture-border.yml"
        baseline_path = os.environ.get("P010_HYBRID_BORDER_BASELINE_TASK", "")
        cls.baseline_task: Path | None = None
        if baseline_path:
            candidate_baseline = Path(baseline_path)
            if not candidate_baseline.is_absolute() or not candidate_baseline.is_file():
                raise RuntimeError("The explicitly configured baseline task path is not an existing absolute file")
            if sha256(candidate_baseline) != BASELINE_SHA256:
                raise RuntimeError("The explicitly configured baseline task does not match the reviewed SHA-256")
            cls.baseline_task = candidate_baseline.resolve()

        configured_ansible = os.environ.get("ANSIBLE_PLAYBOOK_BIN", "")
        candidate = Path(configured_ansible) if configured_ansible else Path()
        if not candidate.is_file():
            candidate = (
                cls.student_lab.parents[1]
                / "evidence/P010/S003/20261029-student-bootstrap/tooling/bin/ansible-playbook"
            )
        if not candidate.is_file():
            raise RuntimeError("The pinned Ansible 2.19.3 ansible-playbook executable is unavailable")
        cls.ansible_playbook = candidate

        scratch = os.environ.get("P010_HYBRID_BORDER_TEST_SCRATCH", "")
        cls.scratch = Path(scratch) if scratch else Path(tempfile.mkdtemp(prefix="p010-border-capture-"))
        cls.scratch.mkdir(mode=0o700, parents=True, exist_ok=True)
        cls.receipt_log = cls.scratch / "ansible-cases.jsonl"
        mode = {
            "baseline_status": "requested" if cls.baseline_task else "not-requested",
            "baseline_task": str(cls.baseline_task) if cls.baseline_task else None,
            "baseline_sha256": sha256(cls.baseline_task) if cls.baseline_task else None,
        }
        (cls.scratch / "mode.json").write_text(json.dumps(mode, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    def setUp(self) -> None:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
        self.test_name = f"{self._testMethodName}-{stamp}"

    @staticmethod
    def border_keys(profile: dict) -> list[str]:
        return [node for node in profile.get("fabric_nodes", []) if node.endswith("-border1")]

    def state_for(self, profile: dict, *, old_alias_only: bool = False) -> dict:
        node_ids = {
            name: f"{number:064x}"
            for number, name in enumerate(profile.get("fabric_nodes", []), start=1)
        }
        if old_alias_only:
            for name in self.border_keys(profile):
                node_ids.pop(name, None)
            node_ids["clab-p010-hibrido-border1"] = CONTAINER_ID
        elif self.border_keys(profile):
            node_ids[self.border_keys(profile)[0]] = CONTAINER_ID

        return {
            "schema": 3,
            "profile": "hibrido",
            "status": "partial",
            "phase": "fabric-created",
            "run_id": "20261030-0123456789abcdef0123456789abcdef",
            "owner_token": OWNER_TOKEN,
            "fabric_node_ids": node_ids,
            "hybrid": {"schema": 4, "phase": "fabric-created", "network": {}},
        }

    def run_task(
        self,
        label: str,
        task_source: str,
        profile: dict,
        state: dict,
        *,
        docker_mode: str = "ok",
        output_id: str = CONTAINER_ID,
        output_owner: str = OWNER_TOKEN,
        output_pid: int = PID,
        starttime_value: str = str(STARTTIME),
        missing_netns: bool = False,
    ) -> dict:
        case_dir = self.scratch / f"{self.test_name}-{label}"
        case_dir.mkdir(mode=0o700, parents=True)
        fake_bin = case_dir / "bin"
        fake_bin.mkdir(mode=0o700)
        fake_proc = case_dir / "fake-proc"
        fake_proc.mkdir(mode=0o700)
        proc_dir = fake_proc / str(PID)
        proc_dir.mkdir(mode=0o700)
        ns_dir = proc_dir / "ns"
        ns_dir.mkdir(mode=0o700)
        proc_stat = proc_dir / "stat"
        proc_stat.write_text(
            f"{PID} (border worker (fixture)) S" + " 0" * 18 + f" {starttime_value}\n",
            encoding="ascii",
        )
        target = ns_dir / "netns-target"
        if not missing_netns:
            target.write_text("synthetic network namespace identity\n", encoding="ascii")
        (ns_dir / "net").symlink_to(target.name)

        docker_trace = case_dir / "docker-argv.txt"
        docker_trace.write_text("", encoding="ascii")
        docker = fake_bin / "docker"
        docker.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "printf '%s\\n' \"$@\" >>\"$P010_BORDER_DOCKER_TRACE\"\n"
            "if [ \"$P010_BORDER_DOCKER_MODE\" = error ]; then\n"
            "  printf 'synthetic docker inspection error\\n' >&2\n"
            "  exit 44\n"
            "fi\n"
            "[ \"$#\" -eq 5 ] || exit 91\n"
            "[ \"$1\" = --host ] && [ \"$2\" = unix:///var/run/docker.sock ] && [ \"$3\" = inspect ] || exit 92\n"
            "case \"$4\" in --format=*) ;; *) exit 93 ;; esac\n"
            "case \"$4\" in *p010-student-owner*) ;; *) exit 94 ;; esac\n"
            "[ \"$5\" = \"$P010_BORDER_EXPECTED_ID\" ] || exit 95\n"
            "printf '%s|%s|%s\\n' \"$P010_BORDER_OUTPUT_ID\" \"$P010_BORDER_OUTPUT_PID\" \"$P010_BORDER_OUTPUT_OWNER\"\n",
            encoding="ascii",
        )
        docker.chmod(0o700)

        fake_sudo = fake_bin / "fake-sudo"
        shutil.copy2(self.student_lab / "tests/fake-sudo.sh", fake_sudo)
        fake_sudo.chmod(0o700)

        shadow_task = case_dir / "tasks/hybrid-m11-capture-border.yml"
        shadow_task.parent.mkdir(mode=0o700)
        shadow_source = task_source.replace("/usr/bin/docker", str(docker)).replace(
            "/proc/", f"{fake_proc}/"
        )
        if "/usr/bin/docker" in shadow_source or "/proc/" in shadow_source:
            raise AssertionError("The scratch task retained a production Docker or proc path")
        shadow_task.write_text(shadow_source, encoding="utf-8")
        state_input = case_dir / "state-input.json"
        state_input.write_text(json.dumps(state, sort_keys=True) + "\n", encoding="utf-8")
        state_input.chmod(0o600)
        profile_input = case_dir / "profile-input.json"
        profile_input.write_text(json.dumps(profile, sort_keys=True) + "\n", encoding="utf-8")
        profile_input.chmod(0o600)
        state_file = case_dir / "durable-state.json"
        initial_state = json.dumps(state, sort_keys=True) + "\n"
        state_file.write_text(initial_state, encoding="utf-8")
        state_file.chmod(0o600)

        playbook = case_dir / "capture-border.yml"
        playbook.write_text(
            "- name: Execute the real border capture task with local boundary fakes\n"
            "  hosts: localhost\n"
            "  connection: local\n"
            "  gather_facts: true\n"
            "  vars:\n"
            "    ansible_become_method: sudo\n"
            "    ansible_become_exe: \"{{ lookup('env', 'P010_BORDER_BECOME_EXE') }}\"\n"
            "    student_uid: \"{{ ansible_user_uid | int }}\"\n"
            "    student_profile: \"{{ lookup('file', lookup('env', 'P010_BORDER_PROFILE_FILE')) | from_json }}\"\n"
            "    student_state: \"{{ lookup('file', lookup('env', 'P010_BORDER_STATE_INPUT')) | from_json }}\"\n"
            "    student_state_file: \"{{ lookup('env', 'P010_BORDER_STATE_FILE') }}\"\n"
            "  tasks:\n"
            "    - name: Run the production border capture task\n"
            "      ansible.builtin.include_tasks: tasks/hybrid-m11-capture-border.yml\n",
            encoding="utf-8",
        )

        local_temp = case_dir / "ansible-local"
        local_temp.mkdir(mode=0o700)
        env = os.environ.copy()
        env.update(
            {
                "ANSIBLE_CONFIG": str(self.student_lab / "ansible.cfg"),
                "ANSIBLE_LOCAL_TEMP": str(local_temp),
                "ANSIBLE_NOCOLOR": "1",
                "PYTHONDONTWRITEBYTECODE": "1",
                "P010_BORDER_BECOME_EXE": str(fake_sudo),
                "P010_BORDER_PROFILE_FILE": str(profile_input),
                "P010_BORDER_STATE_INPUT": str(state_input),
                "P010_BORDER_STATE_FILE": str(state_file),
                "P010_BORDER_DOCKER_TRACE": str(docker_trace),
                "P010_BORDER_DOCKER_MODE": docker_mode,
                "P010_BORDER_EXPECTED_ID": state.get("fabric_node_ids", {}).get(
                    self.border_keys(profile)[0] if self.border_keys(profile) else "", ""
                ),
                "P010_BORDER_OUTPUT_ID": output_id,
                "P010_BORDER_OUTPUT_OWNER": output_owner,
                "P010_BORDER_OUTPUT_PID": str(output_pid),
            }
        )
        argv = [str(self.ansible_playbook), "-i", "localhost,", str(playbook)]
        started = datetime.now(timezone.utc).isoformat(timespec="microseconds")
        result = subprocess.run(
            argv,
            cwd=self.project_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        ended = datetime.now(timezone.utc).isoformat(timespec="microseconds")
        stdout_path = case_dir / "ansible.stdout"
        stderr_path = case_dir / "ansible.stderr"
        stdout_path.write_text(result.stdout, encoding="utf-8")
        stderr_path.write_text(result.stderr, encoding="utf-8")
        receipt = {
            "label": label,
            "start_utc": started,
            "end_utc": ended,
            "cwd": str(self.project_root),
            "argv": argv,
            "rc": result.returncode,
            "production_or_baseline_sha256": hashlib.sha256(task_source.encode("utf-8")).hexdigest(),
            "baseline_status": "requested" if self.baseline_task else "not-requested",
            "baseline_task": str(self.baseline_task) if self.baseline_task else None,
            "shadow_task": str(shadow_task),
            "fake_boundaries": {"docker": str(docker), "proc_root": str(fake_proc), "become": str(fake_sudo)},
            "docker_trace": str(docker_trace),
            "state_file": str(state_file),
            "state_file_unchanged": state_file.read_text(encoding="utf-8") == initial_state,
            "stdout": str(stdout_path),
            "stderr": str(stderr_path),
        }
        with self.receipt_log.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(receipt, sort_keys=True) + "\n")
        return {
            **receipt,
            "stdout_text": result.stdout,
            "stderr_text": result.stderr,
            "docker_argv": docker_trace.read_text(encoding="ascii").splitlines(),
            "state": json.loads(state_file.read_text(encoding="utf-8")),
            "initial_state": state,
            "case_dir": case_dir,
        }

    def assert_failed_without_checkpoint(self, result: dict, *, docker_called: bool) -> None:
        self.assertNotEqual(result["rc"], 0, result["stdout_text"] + result["stderr_text"])
        self.assertTrue(result["state_file_unchanged"])
        self.assertEqual(bool(result["docker_argv"]), docker_called)
        self.assertEqual(result["state"], result["initial_state"])

    def test_current_profile_border_capture_and_optional_historical_baseline(self) -> None:
        profile = deepcopy(self.profile)
        keys = self.border_keys(profile)
        self.assertEqual(len(keys), 1)
        self.assertEqual(keys[0], "clab-p010-hibrido-fabric-border1")
        state = self.state_for(profile)

        production = self.run_task("fixed-positive", self.production_task.read_text(encoding="utf-8"), profile, state)
        self.assertEqual(production["rc"], 0, production["stdout_text"] + production["stderr_text"])
        self.assertTrue(production["docker_argv"], "the exact saved container ID was not inspected")
        self.assertEqual(production["docker_argv"][-1], CONTAINER_ID)
        self.assertEqual(production["state_file_unchanged"], False)
        border = production["state"]["hybrid"]["network"]["border"]
        self.assertEqual(border["container_id"], CONTAINER_ID)
        self.assertEqual(border["pid"], PID)
        self.assertEqual(border["starttime"], STARTTIME)
        self.assertEqual(border["uid"], os.getuid())
        self.assertGreater(border["netns_device"], 0)
        self.assertGreater(border["netns_inode"], 0)

        if self.baseline_task is not None:
            baseline = self.run_task(
                "baseline26-positive",
                self.baseline_task.read_text(encoding="utf-8"),
                profile,
                state,
            )
            self.assert_failed_without_checkpoint(baseline, docker_called=False)

    def test_missing_border_in_profile_stops_before_docker(self) -> None:
        profile = deepcopy(self.profile)
        profile["fabric_nodes"] = [node for node in profile["fabric_nodes"] if not node.endswith("-border1")]
        result = self.run_task("profile-missing", self.production_task.read_text(encoding="utf-8"), profile, self.state_for(profile))
        self.assert_failed_without_checkpoint(result, docker_called=False)

    def test_ambiguous_border_profile_stops_before_docker(self) -> None:
        profile = deepcopy(self.profile)
        profile["fabric_nodes"].append("clab-p010-hibrido-extra-border1")
        result = self.run_task("profile-ambiguous", self.production_task.read_text(encoding="utf-8"), profile, self.state_for(profile))
        self.assert_failed_without_checkpoint(result, docker_called=False)

    def test_mapping_border_profile_stops_before_docker(self) -> None:
        profile = deepcopy(self.profile)
        border_key = self.border_keys(profile)[0]
        profile["fabric_nodes"] = {border_key: "ignored-mapping-value"}
        result = self.run_task(
            "profile-mapping",
            self.production_task.read_text(encoding="utf-8"),
            profile,
            self.state_for(profile),
        )
        self.assert_failed_without_checkpoint(result, docker_called=False)

    def test_old_alias_only_state_is_not_used_as_fallback(self) -> None:
        profile = deepcopy(self.profile)
        result = self.run_task(
            "old-alias-only",
            self.production_task.read_text(encoding="utf-8"),
            profile,
            self.state_for(profile, old_alias_only=True),
        )
        self.assert_failed_without_checkpoint(result, docker_called=False)

    def test_docker_id_mismatch_does_not_checkpoint(self) -> None:
        profile = deepcopy(self.profile)
        result = self.run_task(
            "id-mismatch",
            self.production_task.read_text(encoding="utf-8"),
            profile,
            self.state_for(profile),
            output_id=OTHER_CONTAINER_ID,
        )
        self.assert_failed_without_checkpoint(result, docker_called=True)
        self.assertEqual(result["docker_argv"][-1], CONTAINER_ID)

    def test_owner_mismatch_does_not_checkpoint(self) -> None:
        profile = deepcopy(self.profile)
        result = self.run_task(
            "owner-mismatch",
            self.production_task.read_text(encoding="utf-8"),
            profile,
            self.state_for(profile),
            output_owner="22222222-2222-4222-8222-222222222222",
        )
        self.assert_failed_without_checkpoint(result, docker_called=True)

    def test_docker_error_does_not_checkpoint(self) -> None:
        profile = deepcopy(self.profile)
        result = self.run_task(
            "docker-error",
            self.production_task.read_text(encoding="utf-8"),
            profile,
            self.state_for(profile),
            docker_mode="error",
        )
        self.assert_failed_without_checkpoint(result, docker_called=True)

    def test_missing_process_namespace_does_not_checkpoint(self) -> None:
        profile = deepcopy(self.profile)
        result = self.run_task(
            "missing-netns",
            self.production_task.read_text(encoding="utf-8"),
            profile,
            self.state_for(profile),
            missing_netns=True,
        )
        self.assert_failed_without_checkpoint(result, docker_called=True)

    def test_unobserved_pid_does_not_checkpoint(self) -> None:
        profile = deepcopy(self.profile)
        result = self.run_task(
            "pid-mismatch",
            self.production_task.read_text(encoding="utf-8"),
            profile,
            self.state_for(profile),
            output_pid=PID + 1,
        )
        self.assert_failed_without_checkpoint(result, docker_called=True)

    def test_zero_or_non_numeric_starttime_does_not_checkpoint(self) -> None:
        profile = deepcopy(self.profile)
        for label, starttime in (("zero-starttime", "0"), ("invalid-starttime", "not-a-number")):
            with self.subTest(starttime=starttime):
                result = self.run_task(
                    label,
                    self.production_task.read_text(encoding="utf-8"),
                    profile,
                    self.state_for(profile),
                    starttime_value=starttime,
                )
                self.assert_failed_without_checkpoint(result, docker_called=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
