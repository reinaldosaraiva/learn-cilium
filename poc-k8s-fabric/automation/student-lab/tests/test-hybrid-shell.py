#!/usr/bin/env python3
"""Exercise private console setup and the wrapper's shared-lock lifecycle."""

from __future__ import annotations

import base64
import datetime as dt
import fcntl
import json
import os
import pty
import pwd
import re
import select
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

import yaml


LAB_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = LAB_DIR.parents[2]
ANSIBLE_PLAYBOOK = Path(
    os.environ.get(
        "ANSIBLE_PLAYBOOK_BIN",
        REPO_ROOT
        / "poc-k8s-fabric/evidence/P010/S003/20261029-student-bootstrap/tooling/bin/ansible-playbook",
    )
)
TEST_ROOT = Path(os.environ.get("P010_SHELL_TEST_SCRATCH", "/tmp/p010-hybrid-shell-tests"))


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def write_executable(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    content = content.replace("#!/usr/bin/env python3", f"#!{sys.executable}", 1)
    path.write_text(content, encoding="utf-8")
    path.chmod(0o700)


def write_json_line(path: Path, record: dict[str, object]) -> None:
    payload = (json.dumps(record, sort_keys=True) + "\n").encode()
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, payload)
    finally:
        os.close(fd)


def read_json_lines(path: Path) -> list[dict[str, object]]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def invoke(
    argv: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    log_dir: Path,
    timeout: float = 30,
) -> subprocess.CompletedProcess[bytes]:
    started = utc_now()
    result = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, timeout=timeout)
    (log_dir / "stdout.log").write_bytes(result.stdout)
    (log_dir / "stderr.log").write_bytes(result.stderr)
    (log_dir / "receipt.json").write_text(
        json.dumps(
            {
                "argv": argv,
                "started_utc": started,
                "finished_utc": utc_now(),
                "rc": result.returncode,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    return result


class PtyChild:
    def __init__(self, argv: list[str], *, cwd: Path, env: dict[str, str], log_path: Path):
        self.pid, self.fd = pty.fork()
        self.output = bytearray()
        self.log_path = log_path
        self.started_utc = utc_now()
        if self.pid == 0:
            os.chdir(cwd)
            os.execve(argv[0], argv, env)

    def read_available(self, timeout: float = 0.1) -> None:
        ready, _, _ = select.select([self.fd], [], [], timeout)
        if not ready:
            return
        try:
            self.output.extend(os.read(self.fd, 8192))
        except OSError:
            pass

    def wait_for_file(self, path: Path, timeout: float = 10) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.read_available(0.05)
            if path.exists():
                return
            exited, status = os.waitpid(self.pid, os.WNOHANG)
            if exited:
                self.write_receipt(status)
                raise AssertionError(f"process exited before {path.name}: {self.output.decode(errors='replace')}")
        raise AssertionError(f"timed out waiting for {path.name}: {self.output.decode(errors='replace')}")

    def finish(self, timeout: float = 15) -> int:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.read_available(0.05)
            exited, status = os.waitpid(self.pid, os.WNOHANG)
            if exited:
                self.write_receipt(status)
                return os.waitstatus_to_exitcode(status)
        raise AssertionError(f"process did not exit: {self.output.decode(errors='replace')}")

    def send(self, data: bytes) -> None:
        os.write(self.fd, data)

    def signal(self, number: int) -> None:
        os.kill(self.pid, number)

    def write_receipt(self, status: int) -> None:
        self.log_path.write_text(
            json.dumps(
                {
                    "argv": "bash lab <action>",
                    "started_utc": self.started_utc,
                    "finished_utc": utc_now(),
                    "rc": os.waitstatus_to_exitcode(status),
                    "terminal_output_sha256": __import__("hashlib").sha256(self.output).hexdigest(),
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )


class ConsoleFixtures(unittest.TestCase):
    def setUp(self) -> None:
        TEST_ROOT.mkdir(parents=True, exist_ok=True)
        self.scratch = Path(tempfile.mkdtemp(prefix=f"{self._testMethodName}-", dir=TEST_ROOT))
        self.addCleanup(lambda: None)

    def test_private_templates_create_and_remove_only_matching_files(self) -> None:
        """A successful prep creates exact private files; cleanup refuses replacement inodes."""
        guest_home = self.scratch / "guest-home"
        guest_home.mkdir(mode=0o700)
        run_id = "20261030-" + "a" * 32
        console_id = "b" * 32
        synthetic_password = "synthetic-password-never-use-in-runtime-0123456789"
        cloud = {
            "clouds": {
                "p010": {
                    "auth_type": "v3password",
                    "auth": {
                        "auth_url": "http://10.0.2.15/identity/v3",
                        "user_id": "c" * 32,
                        "project_id": "d" * 32,
                        "user_domain_name": "Default",
                        "project_domain_name": "Default",
                        "password": synthetic_password,
                    },
                    "interface": "internal",
                    "identity_api_version": "3",
                }
            }
        }
        cloud_b64 = base64.b64encode(yaml.safe_dump(cloud, sort_keys=False).encode()).decode()
        render_dir = self.scratch / "render"
        render_dir.mkdir()
        (render_dir / "ansible-tmp").mkdir()
        rendered_prepare = render_dir / "prepare.sh"
        rendered_cleanup = render_dir / "cleanup.sh"
        playbook = render_dir / "render.yml"
        playbook.write_text(
            f"""---
- hosts: localhost
  connection: local
  gather_facts: false
  vars:
    student_hybrid_shell_home: {json.dumps(str(guest_home))}
    student_hybrid_shell_run_id: {run_id}
    student_hybrid_shell_console_id: {console_id}
    student_hybrid_shell_cloud_config: {cloud_b64}
    prepare_template_path: {json.dumps(str(LAB_DIR / 'templates/hybrid-m11-shell-prepare.sh.j2'))}
    cleanup_template_path: {json.dumps(str(LAB_DIR / 'templates/hybrid-m11-shell-cleanup.sh.j2'))}
  tasks:
    - name: Render the actual private preparation and cleanup scripts
      ansible.builtin.set_fact:
        rendered_prepare: "{{{{ lookup('template', prepare_template_path) }}}}"
        rendered_cleanup: "{{{{ lookup('template', cleanup_template_path) }}}}"
      no_log: true
    - ansible.builtin.copy:
        dest: {json.dumps(str(rendered_prepare))}
        content: "{{{{ rendered_prepare }}}}"
        mode: '0700'
      no_log: true
    - ansible.builtin.copy:
        dest: {json.dumps(str(rendered_cleanup))}
        content: "{{{{ rendered_cleanup }}}}"
        mode: '0700'
      no_log: true
""",
            encoding="utf-8",
        )
        remote_bin = self.scratch / "remote-bin"
        self._write_remote_shims(remote_bin)
        env = self._ansible_env(render_dir)
        env["PATH"] = f"{remote_bin}:/usr/bin:/bin"
        log_dir = self.scratch / "render-ansible"
        log_dir.mkdir()
        result = invoke(
            [str(ANSIBLE_PLAYBOOK), str(playbook), "--inventory", "localhost,", "--connection", "local", "--limit", "localhost"],
            cwd=render_dir,
            env=env,
            log_dir=log_dir,
        )
        self.assertEqual(0, result.returncode, result.stderr.decode(errors="replace"))

        run_script = subprocess.run(["/bin/bash", str(rendered_prepare)], env=env, capture_output=True, timeout=10)
        self.assertEqual(0, run_script.returncode, run_script.stderr.decode(errors="replace"))
        console_dir = guest_home / ".p010-student-lab" / "runs" / run_id / "shell" / console_id
        self.assertEqual(0o700, stat.S_IMODE(console_dir.stat().st_mode))
        self.assertEqual(0o600, stat.S_IMODE((console_dir / "clouds.yaml").stat().st_mode))
        self.assertEqual(0o600, stat.S_IMODE((console_dir / "secure.yaml").stat().st_mode))
        self.assertEqual("clouds: {}\n", (console_dir / "secure.yaml").read_text())
        parsed = yaml.safe_load((console_dir / "clouds.yaml").read_text())
        self.assertEqual("http://10.0.2.15/identity/v3", parsed["clouds"]["p010"]["auth"]["auth_url"])
        self.assertEqual("c" * 32, parsed["clouds"]["p010"]["auth"]["user_id"])
        self.assertEqual("d" * 32, parsed["clouds"]["p010"]["auth"]["project_id"])
        self.assertEqual(synthetic_password, parsed["clouds"]["p010"]["auth"]["password"])

        original_cloud = (console_dir / "clouds.yaml").read_text()
        (console_dir / "clouds.yaml").unlink()
        (console_dir / "clouds.yaml").write_text(original_cloud)
        (console_dir / "clouds.yaml").chmod(0o600)
        refused = subprocess.run(["/bin/bash", str(rendered_cleanup)], env=env, capture_output=True, timeout=10)
        self.assertNotEqual(0, refused.returncode)
        self.assertTrue((console_dir / "secure.yaml").exists())
        (console_dir / "clouds.yaml").unlink()
        (console_dir / "clouds.yaml").write_text(original_cloud)
        (console_dir / "clouds.yaml").chmod(0o600)
        marker = console_dir / ".owner"
        fields = marker.read_text().split()
        st = (console_dir / "clouds.yaml").stat()
        fields[3:5] = [str(st.st_dev), str(st.st_ino)]
        marker.write_text(" ".join(fields) + "\n")
        marker.chmod(0o600)
        cleanup = subprocess.run(["/bin/bash", str(rendered_cleanup)], env=env, capture_output=True, timeout=10)
        self.assertEqual(0, cleanup.returncode, cleanup.stderr.decode(errors="replace"))
        self.assertFalse(console_dir.exists())

    def test_wrapper_rejects_bad_inputs_before_effects_and_preserves_prepare_failure(self) -> None:
        """Input refusal and a failed prepare do not launch the student SSH child."""
        env, fixture = self._wrapper_fixture("prepare-failure")
        invalid = dict(env, LAB="hibrido", GUEST="speaker")
        child = self._start_wrapper(fixture, "shell", invalid, self.scratch / "invalid-terminal.json")
        self.assertEqual(2, child.finish())
        self.assertEqual([], read_json_lines(fixture["events"]))

        (fixture["base"] / "fail-prepare").write_text("17\n")
        valid = dict(env, LAB="hibrido", GUEST="ubuntu")
        child = self._start_wrapper(fixture, "shell", valid, self.scratch / "prepare-failure-terminal.json")
        rc = child.finish()
        self.assertEqual(17, rc, child.output.decode(errors="replace"))
        events = read_json_lines(fixture["events"])
        self.assertEqual(["prepare", "cleanup"], [event["phase"] for event in events])
        self.assertFalse(any(event["event"] == "ssh-start" for event in read_json_lines(fixture["ssh_events"])))
        logs = list(fixture["state_dir"].glob("shell-*.log"))
        self.assertEqual(1, len(logs))
        self.assertEqual(0o600, stat.S_IMODE(logs[0].stat().st_mode))

    def test_shared_console_lock_survives_child_close_and_blocks_exclusive_down(self) -> None:
        """Two tty shells share FD9; exclusive down waits until both children and cleanup finish."""
        env1, fixture = self._wrapper_fixture("shared-lock")
        env2 = dict(env1)
        env1["GUEST"] = "ubuntu"
        env2["GUEST"] = "ubuntu"
        fixture["uuid_file_a"].write_text("11111111-1111-4111-8111-111111111111\n")
        fixture["uuid_file_b"].write_text("22222222-2222-4222-8222-222222222222\n")
        fixture["wrapper_a"].write_text(fixture["wrapper_source"].replace(str(fixture["uuid_placeholder"]), str(fixture["uuid_file_a"])))
        fixture["wrapper_b"].write_text(fixture["wrapper_source"].replace(str(fixture["uuid_placeholder"]), str(fixture["uuid_file_b"])))
        fixture["wrapper_a"].chmod(0o700)
        fixture["wrapper_b"].chmod(0o700)

        first = self._start_wrapper(fixture, "shell", env1, self.scratch / "shell-a-terminal.json", wrapper=fixture["wrapper_a"])
        second = self._start_wrapper(fixture, "shell", env2, self.scratch / "shell-b-terminal.json", wrapper=fixture["wrapper_b"])
        deadline = time.monotonic() + 10
        consoles: dict[str, Path] = {}
        while time.monotonic() < deadline and len(consoles) < 2:
            first.read_available(0.05)
            second.read_available(0.05)
            for event in read_json_lines(fixture["ssh_events"]):
                if event.get("event") == "ssh-start":
                    consoles[str(event["console_id"])] = fixture["ssh_ready"] / str(event["console_id"])
        self.assertEqual(2, len(consoles), f"ssh children did not start: {read_json_lines(fixture['ssh_events'])}")
        first.send(b"x\n")
        second.send(b"x\n")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if all((fixture["ssh_ready"] / f"fd9-closed-{console_id}").exists() for console_id in consoles):
                break
            first.read_available(0.05)
            second.read_available(0.05)
        for console_id, ready in consoles.items():
            self.assertTrue(ready.exists(), console_id)
            self.assertTrue((fixture["ssh_ready"] / f"fd9-closed-{console_id}").exists())
            (fixture["ssh_ready"] / f"release-input-{console_id}").write_text("x")

        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            events = read_json_lines(fixture["ssh_events"])
            if len([event for event in events if event.get("event") == "ssh-input"] ) == 2:
                break
            first.read_available(0.05)
            second.read_available(0.05)
        ssh_events = read_json_lines(fixture["ssh_events"])
        starts = [event for event in ssh_events if event.get("event") == "ssh-start"]
        inputs = [event for event in ssh_events if event.get("event") == "ssh-input"]
        self.assertEqual(2, len(inputs), ssh_events)
        self.assertEqual(["x", "x"], sorted(event["value"] for event in inputs), ssh_events)
        self.assertTrue(all(event["fd9_closed"] for event in starts), starts)
        self.assertTrue(all(event["stdin_is_tty"] and event["foreground"] for event in starts), starts)
        self.assertTrue(all(event["strict_pins"] for event in starts), starts)

        down_env = dict(env1, LAB="hibrido", GUEST="")
        down = subprocess.Popen(
            ["/bin/bash", str(fixture["wrapper"]), "down"],
            cwd=fixture["repo_root"],
            env=down_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        time.sleep(0.4)
        self.assertFalse(any(event.get("action") == "down" for event in read_json_lines(fixture["events"])))

        # Exercise signal forwarding for one shell while the other shared owner remains.
        first.signal(signal.SIGTERM)
        first_rc = first.finish()
        self.assertEqual(143, first_rc, first.output.decode(errors="replace"))
        self.assertFalse(any(event.get("action") == "down" for event in read_json_lines(fixture["events"])))
        remaining = next(event for event in starts if not (fixture["ssh_ready"] / f"release-{event['console_id']}").exists())
        remaining_id = str(remaining["console_id"])
        (fixture["ssh_ready"] / f"release-{remaining_id}").write_text("0")
        second_rc = second.finish()
        self.assertEqual(0, second_rc, second.output.decode(errors="replace"))
        stdout, stderr = down.communicate(timeout=15)
        (self.scratch / "down.stdout.log").write_bytes(stdout)
        (self.scratch / "down.stderr.log").write_bytes(stderr)
        self.assertEqual(0, down.returncode, stderr.decode(errors="replace"))

        events = read_json_lines(fixture["events"])
        shell_cleanup = [event for event in events if event.get("phase") == "cleanup"]
        down_event = next(event for event in events if event.get("action") == "down")
        self.assertEqual(2, len(shell_cleanup), events)
        self.assertGreater(down_event["time_ns"], max(event["time_ns"] for event in shell_cleanup))
        for event in starts:
            with self.assertRaises(ProcessLookupError):
                os.kill(int(event["pid"]), 0)

        remote = str(starts[0]["remote_command"])
        self.assertIn("OS_CLIENT_CONFIG_FILE=\"$clouds\"", remote)
        self.assertIn("OS_CLIENT_SECURE_FILE=\"$secure\"", remote)
        self.assertNotIn("OS_PASSWORD", remote)
        self.assertNotIn("OS_TOKEN", remote)
        self._exercise_remote_config_guard(remote, fixture, starts[0])

    def test_cirros_shell_has_only_the_pinned_cirros_environment_and_exit_status(self) -> None:
        """CirrOS gets its own pinned interactive sh and propagates the SSH result."""
        env, fixture = self._wrapper_fixture("cirros")
        env["LAB"] = "hibrido"
        env["GUEST"] = "cirros"
        child = self._start_wrapper(fixture, "shell", env, self.scratch / "cirros-terminal.json")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            child.read_available(0.05)
            events = [event for event in read_json_lines(fixture["ssh_events"]) if event.get("event") == "ssh-start"]
            if events:
                break
        self.assertTrue(events, "CirrOS SSH did not start")
        event = events[0]
        (fixture["ssh_ready"] / f"release-{event['console_id']}").write_text("42")
        self.assertEqual(42, child.finish(), child.output.decode(errors="replace"))
        self.assertEqual("cirros@127.0.0.1", event["target"])
        self.assertIn("/bin/sh -i", event["remote_command"])
        self.assertNotIn("OS_CLIENT_CONFIG_FILE", event["remote_command"])
        self.assertTrue(event["strict_pins"])

    def test_root_make_shell_target_keeps_the_captured_command_quiet(self) -> None:
        """The root target forwards GUEST and suppresses recursive directory chatter."""
        result = subprocess.run(
            ["make", "--no-print-directory", "-n", "lab-shell", "LAB=hibrido", "GUEST=ubuntu"],
            cwd=REPO_ROOT,
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(0, result.returncode, result.stderr.decode(errors="replace"))
        rendered = result.stdout.decode()
        self.assertIn('automation/student-lab/lab "shell"', rendered)
        self.assertNotIn("Entering directory", rendered)

    def _write_remote_shims(self, bin_dir: Path) -> None:
        uid = os.getuid()
        write_executable(
            bin_dir / "id",
            f"""#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
if args == ['-un']:
    print('stack')
elif args == ['-u']:
    print({uid})
elif args == ['-g']:
    print(os.getgid())
else:
    raise SystemExit(2)
""",
        )
        write_executable(
            bin_dir / "stat",
            """#!/usr/bin/env python3
import os, stat, sys
args = sys.argv[1:]
if len(args) < 3 or args[0] != '-c':
    raise SystemExit(2)
fmt = args[1]
path = args[-1]
st = os.lstat(path)
values = {'%u': str(st.st_uid), '%a': format(stat.S_IMODE(st.st_mode), 'o'), '%d': str(st.st_dev), '%i': str(st.st_ino)}
for key, value in values.items():
    fmt = fmt.replace(key, value)
print(fmt)
""",
        )
        write_executable(
            bin_dir / "base64",
            """#!/usr/bin/env python3
import base64, sys
if sys.argv[1:] != ['--decode']:
    raise SystemExit(2)
sys.stdout.buffer.write(base64.b64decode(sys.stdin.buffer.read(), validate=True))
""",
        )

    def _ansible_env(self, log_dir: Path) -> dict[str, str]:
        return {
            "HOME": str(log_dir),
            "PATH": "/usr/local/bin:/usr/bin:/bin",
            "ANSIBLE_CONFIG": str(LAB_DIR / "ansible.cfg"),
            "ANSIBLE_NOCOLOR": "1",
            "ANSIBLE_LOCAL_TEMP": str(log_dir / "ansible-tmp"),
            "PYTHONDONTWRITEBYTECODE": "1",
        }

    def _wrapper_fixture(self, name: str) -> tuple[dict[str, str], dict[str, Path | str]]:
        base = self.scratch / name
        repo_root = base / "repo"
        lab_dir = repo_root / "poc-k8s-fabric/automation/student-lab"
        state_home = base / "home"
        state_dir = state_home / ".local/state/p010-student-lab"
        cache_dir = state_home / ".cache/p010-student-lab"
        tool_dir = state_dir / "tools/bin"
        venv_dir = cache_dir / "ansible-core-2.19.3"
        for directory in [
            lab_dir,
            state_home / ".local",
            state_home / ".local/state",
            state_dir,
            state_dir / "tools",
            tool_dir,
            cache_dir,
            venv_dir,
            venv_dir / "bin",
        ]:
            directory.mkdir(parents=True, exist_ok=True)
            directory.chmod(0o700)
        for filename in ["lab", "sudo-auth.sh", "site.yml", "ansible.cfg"]:
            shutil.copy2(LAB_DIR / filename, lab_dir / filename)
        events = base / "ansible-events.jsonl"
        ssh_events = base / "ssh-events.jsonl"
        ssh_ready = base / "ssh-ready"
        ssh_ready.mkdir(mode=0o700)
        fakebin = base / "fakebin"
        fakebin.mkdir(mode=0o700)
        uuid_placeholder = "/tmp/p010-shell-test-uuid"
        uuid_file = base / "uuid"
        uuid_file_a = base / "uuid-a"
        uuid_file_b = base / "uuid-b"
        uuid_file.write_text("33333333-3333-4333-8333-333333333333\n")
        uuid_file_a.write_text("11111111-1111-4111-8111-111111111111\n")
        uuid_file_b.write_text("22222222-2222-4222-8222-222222222222\n")

        original = (LAB_DIR / "lab").read_text()
        replaced = original.replace("/proc/sys/kernel/random/uuid", uuid_placeholder)
        replaced = replaced.replace("/usr/bin/jq", str(shutil.which("jq")))
        replaced = replaced.replace("/usr/bin/nsenter", str(fakebin / "nsenter"))
        replaced = replaced.replace("/usr/bin/setpriv", str(fakebin / "setpriv"))
        replaced = replaced.replace("/usr/bin/ssh", str(fakebin / "ssh"))
        wrapper = lab_dir / "lab"
        wrapper_source = replaced
        wrapper.write_text(replaced.replace(uuid_placeholder, str(uuid_file)))
        wrapper.chmod(0o700)
        wrapper_a = lab_dir / "lab-a"
        wrapper_b = lab_dir / "lab-b"
        wrapper_a.write_text(wrapper_source.replace(uuid_placeholder, str(uuid_file_a)))
        wrapper_b.write_text(wrapper_source.replace(uuid_placeholder, str(uuid_file_b)))
        wrapper_a.chmod(0o700)
        wrapper_b.chmod(0o700)

        write_executable(
            fakebin / "getent",
            f"""#!/usr/bin/env python3
import os, sys
if sys.argv[1:] == ['passwd', str(os.getuid())]:
    print(f'{{os.getuid()}}:x:{{os.getuid()}}:{{os.getgid()}}:student:{state_home}:')
else:
    raise SystemExit(2)
""",
        )
        write_executable(
            fakebin / "id",
            """#!/usr/bin/env python3
import os, pwd, sys
args = sys.argv[1:]
if args == ['-u']:
    print(os.getuid())
elif args == ['-g']:
    print(os.getgid())
elif args == ['-un']:
    print(pwd.getpwuid(os.getuid()).pw_name)
else:
    raise SystemExit(2)
""",
        )
        write_executable(
            fakebin / "stat",
            """#!/usr/bin/env python3
import os, stat, sys
args = sys.argv[1:]
if len(args) < 3 or args[0] != '-c':
    raise SystemExit(2)
fmt = args[1]
path = args[-1]
st = os.lstat(path)
values = {'%u': str(st.st_uid), '%a': format(stat.S_IMODE(st.st_mode), 'o'), '%d': str(st.st_dev), '%i': str(st.st_ino)}
for key, value in values.items():
    fmt = fmt.replace(key, value)
print(fmt)
""",
        )
        write_executable(
            fakebin / "sudo",
            """#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
if args == ['-n', 'true']:
    raise SystemExit(0)
if args and args[0] == '-n':
    args = args[1:]
if not args:
    raise SystemExit(2)
os.execvpe(args[0], args, os.environ)
""",
        )
        write_executable(
            fakebin / "flock",
            f"""#!/usr/bin/env python3
import fcntl, os, sys, time
args = sys.argv[1:]
mode = fcntl.LOCK_SH if '-s' in args else fcntl.LOCK_EX
fd = int(args[-1])
timeout = 15.0
if '-w' in args:
    timeout = float(args[args.index('-w') + 1])
deadline = time.monotonic() + timeout
while True:
    try:
        fcntl.flock(fd, mode | fcntl.LOCK_NB)
        break
    except BlockingIOError:
        if time.monotonic() >= deadline:
            raise SystemExit(1)
        time.sleep(0.01)
""",
        )
        write_executable(
            fakebin / "nsenter",
            """#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
while args and args[0] != '--':
    args = args[1:]
if not args:
    raise SystemExit(2)
os.execv(args[1], args[1:])
""",
        )
        write_executable(
            fakebin / "setpriv",
            """#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
while args and args[0] != '--':
    args = args[1:]
if not args:
    raise SystemExit(2)
os.execv(args[1], args[1:])
""",
        )
        write_executable(
            fakebin / "ssh",
            f"""#!/usr/bin/env python3
import json, os, re, select, signal, sys, time
events = {json.dumps(str(ssh_events))}
ready_dir = {json.dumps(str(ssh_ready))}
args = sys.argv[1:]
remote = args[-1]
target = args[-2]
match = re.search(r'/shell/([0-9a-f]{{32}})', remote)
console_id = match.group(1) if match else 'cirros'
try:
    os.close(9)
    fd9_closed = True
except OSError:
    fd9_closed = False
try:
    foreground = os.tcgetpgrp(0) == os.getpgrp()
except OSError:
    foreground = False
strict = all(value in args for value in [
    '-F', '/dev/null', '-tt', 'IdentitiesOnly=yes', 'IdentityAgent=none',
    'StrictHostKeyChecking=yes', 'GlobalKnownHostsFile=/dev/null',
    'HostKeyAlgorithms=ssh-ed25519', 'UpdateHostKeys=no'
]) and any(value.startswith('UserKnownHostsFile=') for value in args) and any(value.startswith('HostKeyAlias=p010-') for value in args)
def record(kind, **extra):
    row = {{'event': kind, 'console_id': console_id, 'pid': os.getpid(), 'time_ns': time.time_ns(), **extra}}
    with open(events, 'a', encoding='utf-8') as out:
        out.write(json.dumps(row, sort_keys=True) + '\\n')
def stop(signum, _frame):
    record('ssh-signal', signal=signum)
    raise SystemExit(128 + signum)
for signum in [signal.SIGTERM, signal.SIGINT, signal.SIGHUP]:
    signal.signal(signum, stop)
record('ssh-start', target=target, remote_command=remote, strict_pins=strict, fd9_closed=fd9_closed, stdin_is_tty=os.isatty(0), foreground=foreground)
open(os.path.join(ready_dir, console_id), 'w').close()
ready, _, _ = select.select([0], [], [], 5)
typed = os.read(0, 1).decode(errors='replace') if ready else ''
record('ssh-input', value=typed)
open(os.path.join(ready_dir, 'fd9-closed-' + console_id), 'w').close()
deadline = time.monotonic() + 30
release = os.path.join(ready_dir, 'release-' + console_id)
while time.monotonic() < deadline and not os.path.exists(release):
    time.sleep(0.01)
if not os.path.exists(release):
    raise SystemExit(124)
raise SystemExit(int(open(release, encoding='utf-8').read().strip() or '0'))
""",
        )

        ansible = venv_dir / "bin/ansible-playbook"
        write_executable(
            ansible,
            f"""#!/usr/bin/env python3
import json, os, sys, time
events = {json.dumps(str(events))}
args = sys.argv[1:]
if args == ['--version']:
    print('ansible-playbook [core 2.19.3]')
    raise SystemExit(0)
action = os.environ.get('P010_LAB_ACTION', '')
phase = os.environ.get('P010_LAB_SHELL_PHASE', '')
record = {{'action': action, 'phase': phase, 'profile': os.environ.get('P010_LAB_PROFILE', ''), 'guest': os.environ.get('P010_LAB_GUEST', ''), 'console_id': os.environ.get('P010_LAB_SHELL_CONSOLE_ID', ''), 'time_ns': time.time_ns()}}
with open(events, 'a', encoding='utf-8') as out:
    out.write(json.dumps(record, sort_keys=True) + '\\n')
if phase == 'prepare' and os.path.exists({json.dumps(str(base / 'fail-prepare'))}):
    raise SystemExit(int(open({json.dumps(str(base / 'fail-prepare'))}, encoding='utf-8').read().strip()))
raise SystemExit(0)
""",
        )
        state_file = state_dir / "state.json"
        run_id = "20261030-" + "e" * 32
        uuid = "12345678-1234-4234-8234-123456789abc"
        key_path = state_dir / "runs" / run_id / "keys/hybrid-ed25519"
        known_hosts = state_dir / "runs" / run_id / "keys/known_hosts"
        key_path.parent.mkdir(parents=True)
        key_path.parent.chmod(0o700)
        key_path.write_text("synthetic-private-key\n")
        key_path.chmod(0o600)
        known_hosts.write_text("synthetic-pinned-host-key\n")
        known_hosts.chmod(0o600)
        key_stat = key_path.stat()
        hosts_stat = known_hosts.stat()
        for path in [state_dir / "runs", state_dir / "runs" / run_id, state_dir / "runs" / run_id / "keys"]:
            path.chmod(0o700)
        state = {
            "profile": "hibrido",
            "status": "up",
            "owner_uid": os.getuid(),
            "run_id": run_id,
            "hybrid": {
                "schema": 4,
                "phase": "verified",
                "network": {"border": {"pid": 4321}},
                "guests": {
                    "ubuntu": {
                        "uuid": uuid,
                        "host_port": 42422,
                        "pid": 4322,
                        "starttime": 123456,
                        "ssh_private_key": str(key_path),
                        "ssh_device": key_stat.st_dev,
                        "ssh_inode": key_stat.st_ino,
                    },
                    "cirros": {
                        "uuid": "87654321-4321-4321-8321-cba987654321",
                        "host_port": 42423,
                        "pid": 4323,
                        "starttime": 123457,
                        "ssh_private_key": str(key_path),
                        "ssh_device": key_stat.st_dev,
                        "ssh_inode": key_stat.st_ino,
                    },
                },
                "m11": {
                    "phase": "verified",
                    "api": {"pending": {}},
                    "verification": {
                        "phase": "verified",
                        "gates": {
                            "k8s_pending": {},
                            "k8s_delete_pending": {},
                            "positive": {
                                "phase": "verified",
                                "bgp_established": 3,
                                "tenant_route": True,
                                "podcidr_route": True,
                                "pod_to_vm_icmp": True,
                                "pod_to_vm_tcp22": True,
                                "vm_to_pod_icmp": True,
                                "vm_to_pod_http": True,
                                "vm_source_observed_on_tenant_link": True,
                            },
                        },
                    },
                    "ssh": {
                        "known_hosts_path": str(known_hosts),
                        "known_hosts_device": hosts_stat.st_dev,
                        "known_hosts_inode": hosts_stat.st_ino,
                        "host_keys": {
                            "ubuntu": {"alias": f"p010-{run_id}-{uuid}-ubuntu"},
                            "cirros": {"alias": f"p010-{run_id}-87654321-4321-4321-8321-cba987654321-cirros"},
                        },
                    },
                },
            },
        }
        state_file.write_text(json.dumps(state))
        state_file.chmod(0o600)
        lock = state_dir / "lock"
        lock.write_text("")
        lock.chmod(0o600)
        env = {
            "HOME": str(state_home),
            "LAB": "hibrido",
            "GUEST": "ubuntu",
            "PATH": f"{fakebin}:/usr/local/bin:/usr/bin:/bin",
            "LC_ALL": "C",
        }
        return env, {
            "base": base,
            "repo_root": repo_root,
            "lab_dir": lab_dir,
            "wrapper": wrapper,
            "wrapper_a": wrapper_a,
            "wrapper_b": wrapper_b,
            "wrapper_source": wrapper_source,
            "uuid_placeholder": uuid_placeholder,
            "uuid_file_a": uuid_file_a,
            "uuid_file_b": uuid_file_b,
            "state_dir": state_dir,
            "state_file": state_file,
            "events": events,
            "ssh_events": ssh_events,
            "ssh_ready": ssh_ready,
        }

    def _start_wrapper(self, fixture: dict[str, Path | str], action: str, env: dict[str, str], receipt: Path, wrapper: Path | None = None) -> PtyChild:
        child = PtyChild(
            ["/bin/bash", str(wrapper or fixture["wrapper"]), action],
            cwd=Path(fixture["repo_root"]),
            env=env,
            log_path=receipt,
        )
        return child

    def _exercise_remote_config_guard(self, remote: str, fixture: dict[str, Path | str], event: dict[str, object]) -> None:
        guest_home = self.scratch / "guest-shell-home"
        run_id = "20261030-" + "e" * 32
        console_id = str(event["console_id"])
        directory = guest_home / ".p010-student-lab" / "runs" / run_id / "shell" / console_id
        directory.mkdir(parents=True, mode=0o700)
        (directory / "clouds.yaml").write_text("clouds: {p010: {}}\n")
        (directory / "secure.yaml").write_text("clouds: {}\n")
        (directory / "clouds.yaml").chmod(0o600)
        (directory / "secure.yaml").chmod(0o600)
        clouds_stat = (directory / "clouds.yaml").stat()
        secure_stat = (directory / "secure.yaml").stat()
        (directory / ".owner").write_text(
            f"{run_id} {console_id} ubuntu {clouds_stat.st_dev} {clouds_stat.st_ino} {secure_stat.st_dev} {secure_stat.st_ino}\n"
        )
        (directory / ".owner").chmod(0o600)
        prefix = str(remote).split(" && exec /usr/bin/env -i ", 1)[0]
        self.assertNotEqual(prefix, str(remote), "expected a distinct file guard before starting Bash")
        prefix = prefix.replace("/home/stack", str(guest_home))
        remote_bin = self.scratch / "remote-bin"
        self._write_remote_shims(remote_bin)
        env = {"PATH": f"{remote_bin}:/usr/bin:/bin", "HOME": str(guest_home)}
        valid = subprocess.run(["/bin/bash", "-c", prefix], env=env, capture_output=True, timeout=5)
        self.assertEqual(0, valid.returncode, valid.stderr.decode(errors="replace"))

        clouds = directory / "clouds.yaml"
        secure = directory / "secure.yaml"
        owner = directory / ".owner"
        clouds_contents = clouds.read_text()
        secure_contents = secure.read_text()

        def refresh_marker() -> None:
            clouds_stat = clouds.stat()
            secure_stat = secure.stat()
            owner.write_text(
                f"{run_id} {console_id} ubuntu {clouds_stat.st_dev} {clouds_stat.st_ino} {secure_stat.st_dev} {secure_stat.st_ino}\n"
            )
            owner.chmod(0o600)

        for target in (clouds, secure):
            contents = target.read_text()
            target.unlink()
            missing = subprocess.run(["/bin/bash", "-c", prefix], env=env, capture_output=True, timeout=5)
            self.assertNotEqual(0, missing.returncode, f"missing config was accepted: {target.name}")
            target.write_text(contents)
            target.chmod(0o600)
            refresh_marker()

        for target in (clouds, secure):
            target.chmod(0o000)
            unreadable = subprocess.run(["/bin/bash", "-c", prefix], env=env, capture_output=True, timeout=5)
            self.assertNotEqual(0, unreadable.returncode, f"unreadable config was accepted: {target.name}")
            target.chmod(0o600)

        secure.write_text("clouds: {unexpected: {}}\n")
        secure.chmod(0o600)
        refresh_marker()
        divergent = subprocess.run(["/bin/bash", "-c", prefix], env=env, capture_output=True, timeout=5)
        self.assertNotEqual(0, divergent.returncode, "unexpected secure configuration was accepted")
        clouds.write_text(clouds_contents)
        secure.write_text(secure_contents)


if __name__ == "__main__":
    unittest.main()
