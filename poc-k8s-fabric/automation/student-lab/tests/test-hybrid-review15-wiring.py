from pathlib import Path


ROOT = Path(__file__).resolve().parents[4]
LAB = ROOT / "poc-k8s-fabric/automation/student-lab"


def read(relative_path: str) -> str:
    return (LAB / relative_path).read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    site = read("site.yml")
    identities_call = site.index("include_tasks: tasks/hybrid-identities.yml")
    identities_dispatch = site[identities_call : site.index("- name:", identities_call)]
    require("student_action in ['status', 'down']" in identities_dispatch, "hybrid status/down must validate recorded identities")
    require("student_state.status == 'partial'" in identities_dispatch, "partial hybrid status must reach identity validation")

    boot_one = read("tasks/hybrid-boot-one.yml")
    checkpoint = boot_one.index("Persist this guest's QEMU identity before starting the next guest")
    qmp_verify = boot_one.index("Verify QMP greeting, capabilities, and UUID on the newly booted connection")
    require(checkpoint < qmp_verify, "QMP identity verification must follow the durable guest checkpoint")
    require("student_hybrid_qmp_action: verify" in boot_one[qmp_verify:], "newly booted guest must use the QMP verify action")

    down = read("tasks/hybrid-down.yml")
    intent = down.index("include_tasks: hybrid-validate-tap-create-intent.yml")
    quit_guests = down.index("Ask live guests to quit only after same-connection QMP UUID verification")
    require(intent < quit_guests, "uncertain TAP creation must be resolved before guest or TAP cleanup")
    intent_block = down[intent:quit_guests]
    require("student_hybrid_tap_intent_record_absence: true" in intent_block, "proven TAP absence must be checkpointed before cleanup")
    require("student_state.hybrid.network.tap.create_phase == 'creating'" in intent_block, "the guard must target only an unresolved create")

    border = read("tasks/hybrid-validate-border.yml")
    require(border.count("become: true") >= 4, "border PID, namespace, process, and container identities require privileged inspection")
    qmp = read("tasks/hybrid-qmp-command.yml")
    require("become: true" in qmp, "QMP inspection must be callable by the privileged identity reader")

    preflight = read("tasks/hybrid-preflight.yml")
    require("student_hybrid_dig_bin" in preflight and "-v" in preflight, "host dig prerequisite must be checked before guest preparation")
    boot = read("tasks/hybrid-boot.yml")
    dns = boot.index("include_tasks: hybrid-discover-dns.yml")
    image_download = boot.index("Download and checkpoint each pinned image")
    require(dns < image_download, "direct namespace DNS proof must precede image/guest work")
    probe = read("tasks/hybrid-probe-dns.yml")
    require("--net=/proc/{{ student_state.hybrid.network.border.pid }}/ns/net" in probe, "DNS proof must run in the saved border namespace")
    require("@{{ item }}" in probe, "DNS proof must query each discovered upstream directly")
    network_config = read("templates/hybrid-ubuntu-network-config.yml.j2")
    tenant_config = network_config.split("  tenant:\n", 1)[1]
    require("dhcp4: false" in tenant_config and "dhcp6: false" in tenant_config, "Ubuntu tenant NIC must not run DHCP or replace management DNS")
    require("dhcp4-overrides" not in tenant_config, "Ubuntu tenant config must not request DHCP-provided DNS")

    devstack = read("tasks/hybrid-m11-devstack.yml")
    stack_run = devstack.index("if ./stack.sh")
    bridge_checks = devstack.index("sudo -n ovs-vsctl --timeout=10 br-exists br-ex", stack_run)
    require("br-exists br-ex" not in devstack[:stack_run], "fresh DevStack must create br-ex before the bridge is checked")
    require("br-exists br-int" not in devstack[:stack_run], "fresh DevStack must create br-int before the bridge is checked")
    require(stack_run < bridge_checks, "bridge existence must be checked after stack.sh")

    print("PASS: hybrid status/QMP/TAP/DNS corrections are wired into production task paths")


if __name__ == "__main__":
    main()
