#!/usr/bin/env python3
"""Exercise the production tenant0 attach script with local command fakes."""

from __future__ import annotations

import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

from jinja2 import Environment, FileSystemLoader


LAB = Path(__file__).resolve().parents[1]
TEMPLATE = LAB / "templates" / "hybrid-m11-ovs-attach.sh.j2"
DETACH_TEMPLATE = LAB / "templates" / "hybrid-m11-ovs-detach.sh.j2"
GUEST_MAC = "52:54:00:11:22:33"
NEUTRON_MAC = "fa:16:3e:aa:bb:cc"
PORT_ID = "11111111-2222-4333-8444-555555555555"
BRIDGE_UUID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
PORT_UUID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
INTERFACE_UUID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"


FAKES = {
    "cat": r'''#!/usr/bin/env bash
set -eu
case "${1:-}" in
  /sys/class/net/tenant0/address) printf '%s\n' "$P010_FAKE_GUEST_MAC" ;;
  /sys/class/net/tenant0/ifindex) printf '%s\n' "$P010_FAKE_IFINDEX" ;;
  *) exec /bin/cat "$@" ;;
esac
''',
    "ip": r'''#!/usr/bin/env bash
set -eu
printf 'ip %s\n' "$*" >>"$P010_FAKE_COMMAND_LOG"
[[ "$*" == '-o -4 address show dev tenant0' ]] || exit 64
printf '%s' "$P010_FAKE_IP_OUTPUT"
''',
    "sudo": r'''#!/usr/bin/env bash
set -eu
[[ "${1:-}" == -n ]] || exit 65
shift
exec "$@"
''',
    "crudini": r'''#!/usr/bin/env bash
set -eu
printf 'crudini %s\n' "$*" >>"$P010_FAKE_COMMAND_LOG"
[[ "${1:-}" == --get && $# == 4 ]] || exit 66
case "$3/$4" in
  securitygroup/enable_security_group) printf '%s\n' "$P010_FAKE_ENABLE_SG" ;;
  securitygroup/firewall_driver) printf '%s\n' "$P010_FAKE_FIREWALL_DRIVER" ;;
  ovs/bridge_mappings) printf '%s\n' "$P010_FAKE_BRIDGE_MAPPINGS" ;;
  *) exit 67 ;;
esac
''',
    "ovs-vsctl": r'''#!/usr/bin/env python3
import os
import sys

args = [arg for arg in sys.argv[1:] if not arg.startswith("--timeout=")]
with open(os.environ["P010_FAKE_COMMAND_LOG"], "a", encoding="utf-8") as stream:
    stream.write("ovs-vsctl " + " ".join(args) + "\n")

if args == ["br-exists", "br-int"]:
    raise SystemExit(int(os.environ.get("P010_FAKE_BRIDGE_RC", "0")))
if args[-2:] == ["list", "Interface"] and "--columns=name" in args:
    if os.path.exists(os.environ["P010_FAKE_DELETED"]) and int(os.environ.get("P010_FAKE_FAIL_LIST_AFTER_DELETE", "0")):
        print("database query failed after detach", file=sys.stderr)
        raise SystemExit(int(os.environ["P010_FAKE_FAIL_LIST_AFTER_DELETE"]))
    if int(os.environ.get("P010_FAKE_INTERFACE_LIST_RC", "0")):
        print("database unavailable", file=sys.stderr)
        raise SystemExit(int(os.environ["P010_FAKE_INTERFACE_LIST_RC"]))
    names = os.environ.get("P010_FAKE_EXISTING_INTERFACES", "").splitlines()
    if os.path.exists(os.environ["P010_FAKE_ATTACHED"]):
        names.append("tenant0")
    print("\n".join(names))
    raise SystemExit(0)
if args[-2:] == ["list", "Port"] and "--columns=name" in args:
    if os.path.exists(os.environ["P010_FAKE_DELETED"]) and int(os.environ.get("P010_FAKE_FAIL_LIST_AFTER_DELETE", "0")):
        print("database query failed after detach", file=sys.stderr)
        raise SystemExit(int(os.environ["P010_FAKE_FAIL_LIST_AFTER_DELETE"]))
    if int(os.environ.get("P010_FAKE_PORT_LIST_RC", "0")):
        print("database unavailable", file=sys.stderr)
        raise SystemExit(int(os.environ["P010_FAKE_PORT_LIST_RC"]))
    names = os.environ.get("P010_FAKE_EXISTING_PORTS", "").splitlines()
    if os.path.exists(os.environ["P010_FAKE_ATTACHED"]):
        names.append("tenant0")
    print("\n".join(names))
    raise SystemExit(0)
if args[:2] == ["add-port", "br-int"]:
    if int(os.environ.get("P010_FAKE_ADD_RC", "0")):
        raise SystemExit(int(os.environ["P010_FAKE_ADD_RC"]))
    open(os.environ["P010_FAKE_ATTACHED"], "w", encoding="utf-8").close()
    raise SystemExit(0)
if args[:2] == ["del-port", "br-int"]:
    if int(os.environ.get("P010_FAKE_DELETE_RC", "0")):
        raise SystemExit(int(os.environ["P010_FAKE_DELETE_RC"]))
    os.unlink(os.environ["P010_FAKE_ATTACHED"])
    open(os.environ["P010_FAKE_DELETED"], "w", encoding="utf-8").close()
    raise SystemExit(0)
if len(args) == 4 and args[:2] == ["get", "Bridge"]:
    print('"' + os.environ.get("P010_FAKE_BRIDGE_UUID", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa") + '"')
    raise SystemExit(0)
if len(args) == 4 and args[:2] == ["get", "Port"]:
    print('"' + os.environ.get("P010_FAKE_PORT_UUID", "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb") + '"')
    raise SystemExit(0)
if len(args) == 4 and args[:2] == ["get", "Interface"]:
    field = args[3]
    if field == "_uuid":
        print('"' + os.environ.get("P010_FAKE_INTERFACE_UUID", "cccccccc-cccc-4ccc-8ccc-cccccccccccc") + '"')
    elif field == "ofport":
        print('"17"')
    elif field == "external_ids:iface-id":
        print(os.environ.get("P010_FAKE_REPORTED_PORT_ID", os.environ["P010_TEST_PORT_ID"]))
    elif field == "external_ids:attached-mac":
        if int(os.environ.get("P010_FAKE_POST_ATTACH_QUERY_RC", "0")):
            print("database query failed", file=sys.stderr)
            raise SystemExit(int(os.environ["P010_FAKE_POST_ATTACH_QUERY_RC"]))
        print(os.environ.get("P010_FAKE_REPORTED_ATTACHED_MAC", os.environ["P010_TEST_NEUTRON_MAC"]))
    else:
        raise SystemExit(68)
    raise SystemExit(0)
if args == ["port-to-br", "tenant0"]:
    print(os.environ.get("P010_FAKE_REPORTED_BRIDGE", "br-int"))
    raise SystemExit(0)
print("unexpected fake ovs-vsctl arguments", file=sys.stderr)
raise SystemExit(69)
''',
}


class OVSAttachTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        env = Environment(loader=FileSystemLoader(str(TEMPLATE.parent)))
        env.filters["quote"] = shlex.quote
        cls.render = env.get_template(TEMPLATE.name).render
        cls.render_detach_template = env.get_template(DETACH_TEMPLATE.name).render

    def setUp(self) -> None:
        requested = os.environ.get("P010_HYBRID_OVS_TEST_SCRATCH")
        if requested:
            Path(requested).mkdir(mode=0o700, parents=True, exist_ok=True)
            self.root = Path(tempfile.mkdtemp(prefix="ovs-", dir=requested))
        else:
            self._scratch = tempfile.TemporaryDirectory(prefix="p010-hybrid-ovs-")
            self.root = Path(self._scratch.name)
        self.fake_bin = self.root / "bin"
        self.fake_bin.mkdir(mode=0o700)
        for name, content in FAKES.items():
            path = self.fake_bin / name
            path.write_text(content, encoding="utf-8")
            path.chmod(0o700)
        self.script = self.root / "attach.sh"
        self.script.write_text(
            self.render(
                student_state={
                    "hybrid": {
                        "m11": {
                            "verification": {
                                "gates": {
                                    "ovs_attach": {
                                        "bridge_name": "br-int",
                                        "interface_name": "tenant0",
                                        "guest_interface_mac": GUEST_MAC,
                                        "neutron_port_id": PORT_ID,
                                        "attached_mac": NEUTRON_MAC,
                                    }
                                }
                            }
                        }
                    }
                }
            ),
            encoding="utf-8",
        )
        self.log = self.root / "commands.log"
        self.attached = self.root / "attached"
        self.deleted = self.root / "deleted"

    def write_detach_script(self) -> None:
        self.script = self.root / "detach.sh"
        self.script.write_text(
            self.render_detach_template(
                student_state={
                    "hybrid": {
                        "m11": {
                            "verification": {
                                "gates": {
                                    "ovs_attach": {
                                        "bridge_name": "br-int",
                                        "interface_name": "tenant0",
                                        "guest_interface_mac": GUEST_MAC,
                                        "neutron_port_id": PORT_ID,
                                        "attached_mac": NEUTRON_MAC,
                                        "bridge_uuid": BRIDGE_UUID,
                                        "port_uuid": PORT_UUID,
                                        "interface_uuid": INTERFACE_UUID,
                                        "ifindex": 45,
                                        "ofport": 17,
                                    }
                                }
                            }
                        }
                    }
                }
            ),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        scratch_root = os.environ.get("P010_HYBRID_OVS_TEST_SCRATCH")
        if not scratch_root:
            self._scratch.cleanup()

    def run_case(self, **overrides: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.fake_bin}:/usr/bin:/bin",
                "P010_FAKE_GUEST_MAC": GUEST_MAC,
                "P010_FAKE_IFINDEX": "45",
                "P010_FAKE_IP_OUTPUT": "",
                "P010_FAKE_ENABLE_SG": "True",
                "P010_FAKE_FIREWALL_DRIVER": "openvswitch",
                "P010_FAKE_BRIDGE_MAPPINGS": "m11public:br-ex",
                "P010_FAKE_EXISTING_INTERFACES": "",
                "P010_FAKE_EXISTING_PORTS": "",
                "P010_FAKE_BRIDGE_RC": "0",
                "P010_FAKE_INTERFACE_LIST_RC": "0",
                "P010_FAKE_PORT_LIST_RC": "0",
                "P010_FAKE_ADD_RC": "0",
                "P010_FAKE_DELETE_RC": "0",
                "P010_FAKE_FAIL_LIST_AFTER_DELETE": "0",
                "P010_FAKE_POST_ATTACH_QUERY_RC": "0",
                "P010_FAKE_REPORTED_PORT_ID": PORT_ID,
                "P010_FAKE_REPORTED_ATTACHED_MAC": NEUTRON_MAC,
                "P010_FAKE_REPORTED_BRIDGE": "br-int",
                "P010_FAKE_COMMAND_LOG": str(self.log),
                "P010_FAKE_ATTACHED": str(self.attached),
                "P010_FAKE_DELETED": str(self.deleted),
                "P010_TEST_PORT_ID": PORT_ID,
                "P010_TEST_NEUTRON_MAC": NEUTRON_MAC,
            }
        )
        env.update(overrides)
        return subprocess.run(
            ["/bin/bash", str(self.script)],
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )

    def assert_no_attach(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.attached.exists())
        log = self.log.read_text(encoding="utf-8") if self.log.exists() else ""
        self.assertNotIn("ovs-vsctl add-port", log)

    def test_attaches_only_after_firewall_and_guest_checks(self) -> None:
        result = self.run_case()
        self.assertEqual(result.returncode, 0, result.stderr)
        markers = dict(line.removeprefix("P010_OVS_").split("=", 1) for line in result.stdout.splitlines())
        self.assertEqual(markers["BRIDGE"], "br-int")
        self.assertEqual(markers["IFINDEX"], "45")
        self.assertEqual(markers["OFPORT"], "17")
        self.assertEqual(markers["IFACE_ID"], PORT_ID)
        self.assertEqual(markers["ATTACHED_MAC"], NEUTRON_MAC)
        self.assertEqual(markers["GUEST_MAC"], GUEST_MAC)
        self.assertTrue(self.attached.exists())
        self.assertEqual(self.log.read_text(encoding="utf-8").count("ovs-vsctl add-port"), 1)

    def test_existing_interface_is_never_adopted(self) -> None:
        result = self.run_case(P010_FAKE_EXISTING_INTERFACES="tenant0")
        self.assert_no_attach(result)

    def test_existing_port_is_never_adopted(self) -> None:
        result = self.run_case(P010_FAKE_EXISTING_PORTS="tenant0")
        self.assert_no_attach(result)

    def test_guest_identity_or_address_mismatch_stops_before_attach(self) -> None:
        for override in (
            {"P010_FAKE_GUEST_MAC": "52:54:00:99:88:77"},
            {"P010_FAKE_IP_OUTPUT": "7: tenant0 inet 198.18.49.88/24 scope global tenant0"},
        ):
            with self.subTest(override=override):
                result = self.run_case(**override)
                self.assert_no_attach(result)

    def test_effective_security_or_ovs_query_failure_stops_before_attach(self) -> None:
        for override in (
            {"P010_FAKE_ENABLE_SG": "False"},
            {"P010_FAKE_FIREWALL_DRIVER": "iptables_hybrid"},
            {"P010_FAKE_BRIDGE_MAPPINGS": "m11public:br-other"},
            {"P010_FAKE_BRIDGE_RC": "70"},
            {"P010_FAKE_INTERFACE_LIST_RC": "71"},
            {"P010_FAKE_PORT_LIST_RC": "72"},
        ):
            with self.subTest(override=override):
                result = self.run_case(**override)
                self.assert_no_attach(result)

    def test_post_attach_query_failure_leaves_partial_attachment_visible(self) -> None:
        result = self.run_case(P010_FAKE_POST_ATTACH_QUERY_RC="73")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue(self.attached.exists())
        self.assertIn("ovs-vsctl add-port", self.log.read_text(encoding="utf-8"))

    def test_reported_binding_must_match_saved_ids(self) -> None:
        result = self.run_case(P010_FAKE_REPORTED_PORT_ID="22222222-2222-4222-8222-222222222222")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue(self.attached.exists())

    def run_detach_case(self, **overrides: str) -> subprocess.CompletedProcess[str]:
        self.attached.touch()
        self.write_detach_script()
        return self.run_case(**overrides)

    def test_detaches_only_the_exact_saved_port(self) -> None:
        result = self.run_detach_case()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "P010_OVS_DETACH=absent")
        self.assertFalse(self.attached.exists())
        self.assertEqual(self.log.read_text(encoding="utf-8").count("ovs-vsctl del-port"), 1)

    def test_absent_port_is_idempotently_confirmed_without_deletion(self) -> None:
        self.write_detach_script()
        result = self.run_case()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "P010_OVS_DETACH=absent")
        self.assertNotIn("ovs-vsctl del-port", self.log.read_text(encoding="utf-8"))

    def test_detach_refuses_identity_mismatches_and_query_failures(self) -> None:
        for override in (
            {"P010_FAKE_BRIDGE_UUID": "dddddddd-dddd-4ddd-8ddd-dddddddddddd"},
            {"P010_FAKE_PORT_UUID": "dddddddd-dddd-4ddd-8ddd-dddddddddddd"},
            {"P010_FAKE_INTERFACE_UUID": "dddddddd-dddd-4ddd-8ddd-dddddddddddd"},
            {"P010_FAKE_REPORTED_PORT_ID": "22222222-2222-4222-8222-222222222222"},
            {"P010_FAKE_REPORTED_ATTACHED_MAC": "fa:16:3e:00:00:01"},
            {"P010_FAKE_IFINDEX": "46"},
            {"P010_FAKE_INTERFACE_LIST_RC": "71"},
            {"P010_FAKE_PORT_LIST_RC": "72"},
        ):
            with self.subTest(override=override):
                result = self.run_detach_case(**override)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertTrue(self.attached.exists())
                self.assertNotIn("ovs-vsctl del-port", self.log.read_text(encoding="utf-8"))

    def test_post_delete_query_failure_leaves_absence_for_state_reconciliation(self) -> None:
        self.attached.touch()
        result = self.run_detach_case(P010_FAKE_FAIL_LIST_AFTER_DELETE="71")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.attached.exists())
        self.assertIn("ovs-vsctl del-port", self.log.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
