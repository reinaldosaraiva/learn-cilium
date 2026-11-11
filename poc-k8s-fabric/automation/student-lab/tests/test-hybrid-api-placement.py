#!/usr/bin/env python3
"""Check that M11 HTTP requests execute through the pinned Ubuntu SSH host."""

from pathlib import Path
import unittest

from jinja2 import Environment, StrictUndefined
import yaml


class ApiPlacementTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.student_lab = Path(__file__).resolve().parents[1]

    def test_every_m11_uri_is_delegated_to_the_pinned_guest(self):
        paths = sorted((self.student_lab / "tasks").glob("hybrid-m11-api-*.yml"))
        paths.append(self.student_lab / "hybrid-m11-api-playbook.yml")
        uri_tasks = []

        for path in paths:
            documents = yaml.safe_load(path.read_text(encoding="utf-8")) or []
            if isinstance(documents, dict):
                documents = [documents]
            for task in documents:
                if "ansible.builtin.uri" in task:
                    uri_tasks.append((path, task))

        self.assertGreater(len(uri_tasks), 10)
        for path, task in uri_tasks:
            with self.subTest(path=path.name, name=task.get("name", "unnamed")):
                self.assertEqual(task.get("delegate_to"), "student_hybrid_ubuntu")
                self.assertIs(task.get("no_log"), True)
                self.assertEqual(task["ansible.builtin.uri"].get("follow_redirects"), "none")

    def test_api_ssh_target_has_private_pinned_host_identity(self):
        playbook = yaml.safe_load(
            (self.student_lab / "hybrid-m11-api-playbook.yml").read_text(
                encoding="utf-8"
            )
        )[0]
        tasks = playbook["tasks"]
        add_host = next(
            task["ansible.builtin.add_host"]
            for task in tasks
            if "ansible.builtin.add_host" in task
        )
        ssh_args = add_host["ansible_ssh_common_args"]

        self.assertEqual(add_host["ansible_connection"], "ssh")
        self.assertEqual(add_host["ansible_host"], "127.0.0.1")
        self.assertEqual(add_host["ansible_user"], "stack")
        self.assertIs(add_host["ansible_ssh_host_key_checking"], True)
        self.assertIn("student_state.hybrid.guests.ubuntu.host_port", str(add_host["ansible_port"]))
        self.assertIn("student_state.hybrid.guests.ubuntu.ssh_private_key", str(add_host["ansible_ssh_private_key_file"]))
        for option in (
            "-F /dev/null",
            "IdentitiesOnly=yes",
            "IdentityAgent=none",
            "StrictHostKeyChecking=yes",
            "GlobalKnownHostsFile=/dev/null",
            "HostKeyAlgorithms=ssh-ed25519",
            "UpdateHostKeys=no",
            "HostKeyAlias=",
        ):
            self.assertIn(option, ssh_args)
        ssh_args = add_host["ansible_ssh_args"]
        for option in ("ControlMaster=no", "ControlPath=none", "ControlPersist=no"):
            self.assertIn(option, ssh_args)

        names = [task.get("name", "") for task in tasks]
        address_check = names.index("Prove the API target management address is this pinned Ubuntu guest")
        endpoint_check = names.index("Require the exact guest-owned management address and configured Keystone target")
        first_uri = names.index("Discover the configured Keystone v3 endpoint inside the validated guest")
        self.assertLess(address_check, endpoint_check)
        self.assertLess(endpoint_check, first_uri)

        api_runner = yaml.safe_load(
            (self.student_lab / "tasks/hybrid-m11-run-api.yml").read_text(
                encoding="utf-8"
            )
        )
        guest_api_task = next(
            task
            for task in api_runner
            if task.get("name") == "Invoke the selected API phase with only non-secret path and mode variables"
        )
        self.assertNotEqual(guest_api_task["environment"]["ANSIBLE_CONFIG"], "/dev/null")
        self.assertTrue(
            guest_api_task["environment"]["ANSIBLE_CONFIG"].endswith(
                "/automation/student-lab/ansible.cfg"
            )
        )

    def test_api_host_forwards_are_not_configured(self):
        qemu_args = (self.student_lab / "tasks/hybrid-qemu-network-args.yml").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("42424", qemu_args)
        self.assertNotIn("42425", qemu_args)
        self.assertNotIn("api_http_host_port", qemu_args)
        self.assertNotIn("api_neutron_host_port", qemu_args)

    def test_cilium_peer_templates_target_the_existing_rack_leaves(self):
        templates = self.student_lab / "templates"
        environment = Environment(undefined=StrictUndefined)
        state = {
            "run_id": "20261030-0123456789abcdef0123456789abcdef",
            "owner_token": "11111111111141118111111111111111",
            "hybrid": {"m11": {"network": {
                "provider_speaker_ip": "198.18.48.2",
                "speaker_asn": 64590,
            }}},
        }
        expected = {
            "rack1": ("65201", "10.30.1.1", "p003-leaf1.cfg"),
            "rack2": ("65202", "10.30.2.1", "p003-leaf2.cfg"),
        }

        for rack, (peer_asn, peer_ip, leaf_config) in expected.items():
            with self.subTest(rack=rack):
                template_path = templates / f"hybrid-m11-cluster-{rack}.yml.j2"
                rendered = environment.from_string(
                    template_path.read_text(encoding="utf-8")
                ).render(student_state=state)
                leaf = (self.student_lab.parents[1] / "studies/p003/configs/srl" / leaf_config).read_text(
                    encoding="utf-8"
                )

                self.assertIn(f"peerASN: {peer_asn}", rendered)
                self.assertIn(f"peerAddress: {peer_ip}", rendered)
                self.assertIn(f"bgp autonomous-system {peer_asn}", leaf)
                self.assertIn(f"ipv4 address {peer_ip}/24", leaf)
                self.assertNotIn("peerASN: 64590", rendered)
                self.assertNotIn("peerAddress: 198.18.48.2", rendered)

    def test_m11_stdout_readers_use_the_bounded_raw_marker_parser(self):
        callers = {
            "hybrid-m11-up.yml": 3,
            "hybrid-m11-positive-verify.yml": 1,
            "hybrid-m11-devstack.yml": 1,
        }
        for name, expected_includes in callers.items():
            with self.subTest(path=name):
                source = (self.student_lab / "tasks" / name).read_text(encoding="utf-8")
                self.assertEqual(source.count("hybrid-m11-parse-markers.yml"), expected_includes)
                self.assertNotIn("map('split', '|')", source)
                self.assertNotIn("regex_replace", source)

    def test_verify_checks_the_live_security_group_without_requiring_deleted_defaults(self):
        verify_path = self.student_lab / "tasks/hybrid-m11-verify.yml"
        tasks = yaml.safe_load(verify_path.read_text(encoding="utf-8"))
        resource_fact = next(
            task["ansible.builtin.set_fact"]["student_hybrid_api_verify_resources"]
            for task in tasks
            if task.get("name") == "Define the exact per-run Neutron objects to re-read by ID"
        )
        self.assertNotIn(
            "default_ipv4",
            [resource["slot"] for resource in resource_fact if resource["key"] == "security_group_rules"],
        )
        self.assertNotIn(
            "default_ipv6",
            [resource["slot"] for resource in resource_fact if resource["key"] == "security_group_rules"],
        )

        source = verify_path.read_text(encoding="utf-8")
        rule_check = (self.student_lab / "tasks/hybrid-m11-api-verify-rules.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("/security-group-rules?security_group_id=", source)
        self.assertIn("student_hybrid_api_actual_rule_ids == student_hybrid_api_expected_rule_ids", rule_check)
        self.assertIn("get('default_ipv4', {}).get('id', '') not in student_hybrid_api_rule_ids", rule_check)
        self.assertIn("get('default_ipv6', {}).get('id', '') not in student_hybrid_api_rule_ids", rule_check)
        self.assertNotIn("student_state.hybrid.guests.cirros.tenant_ipv4", source)
        gateway_expected = next(
            resource["expected"]
            for resource in resource_fact
            if resource["key"] == "router_gateway_port"
        )
        self.assertNotIn("project_id", gateway_expected)

    def test_auth_retains_uri_token_field_and_not_a_headers_alias(self):
        auth_source = (self.student_lab / "tasks/hybrid-m11-api-retain-auth.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("student_hybrid_api_auth_response.x_subject_token", auth_source)
        self.assertNotIn("headers['x-subject-token']", auth_source)

    def test_verify_snapshots_agents_before_response_is_reused(self):
        verify_path = self.student_lab / "tasks/hybrid-m11-verify.yml"
        tasks = yaml.safe_load(verify_path.read_text(encoding="utf-8"))
        names = [task.get("name", "") for task in tasks]
        agent_read = names.index("Read the Neutron v3 agents used by the verified API objects")
        rules_read = names.index("Read every rule attached to this run's security group")
        agent_assert = names.index("Require the exact saved OVS, DHCP, L3, and BGP agents to remain active")
        self.assertLess(agent_read, rules_read)
        self.assertLess(rules_read, agent_assert)
        store_index = next(
            index
            for index, task in enumerate(tasks)
            if task.get("ansible.builtin.include_tasks") == "hybrid-m11-api-store-agents.yml"
        )
        self.assertEqual(agent_read + 1, store_index)
        source = verify_path.read_text(encoding="utf-8")
        self.assertIn("student_hybrid_api_verify_agents | selectattr", source)
        self.assertNotIn("student_hybrid_api_response.json.agents | selectattr", source)

    def test_uncertain_post_cleanup_does_not_query_or_adopt_by_name(self):
        path = self.student_lab / "tasks/hybrid-m11-api-reconcile-post.yml"
        tasks = yaml.safe_load(path.read_text(encoding="utf-8"))
        self.assertFalse(any("ansible.builtin.uri" in task for task in tasks))
        self.assertTrue(any("ansible.builtin.fail" in task for task in tasks))
        source = path.read_text(encoding="utf-8")
        self.assertNotIn("selectattr('name'", source)
        self.assertNotIn("method: POST", source)

    def test_router_interface_is_removed_through_the_router_action(self):
        source = (
            self.student_lab / "tasks/hybrid-m11-api-remove-router-interface.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("/remove_router_interface", source)
        self.assertIn("method: PUT", source)
        self.assertNotIn("method: DELETE", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
