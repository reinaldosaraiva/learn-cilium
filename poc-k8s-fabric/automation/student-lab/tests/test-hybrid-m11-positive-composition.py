#!/usr/bin/env python3
"""Exercise the M11 positive verifier and saved-state callers with local fakes."""

from __future__ import annotations

import hashlib
import atexit
import json
import os
import signal
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from textwrap import dedent


RUN_ID = "20261030-0123456789abcdef0123456789abcdef"
OWNER_TOKEN = "11111111111141118111111111111111"
NAMESPACE = "p010-hyb-0123456789ab"
POD_CLIENT = "10.246.1.10"
POD_SERVER = "10.246.2.10"
VM_IP = "198.18.49.22"
CLUSTER_UID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
UIDS = {
    "server_deployment": "11111111-1111-4111-8111-111111111111",
    "client_deployment": "22222222-2222-4222-8222-222222222222",
    "cluster_rack1": "33333333-3333-4333-8333-333333333333",
    "cluster_rack2": "44444444-4444-4444-8444-444444444444",
    "advertisement": "55555555-5555-4555-8555-555555555555",
    "peer_config": "66666666-6666-4666-8666-666666666666",
    "namespace": "77777777-7777-4777-8777-777777777777",
}
IDS = {
    key: f"{number:08x}-1111-4111-8111-{number:012x}"
    for number, key in enumerate(
        [
            "address_scope",
            "external_subnetpool",
            "tenant_subnetpool",
            "external_network",
            "tenant_network",
            "external_subnet",
            "tenant_subnet",
            "router",
            "router_interface",
            "router_gateway_port",
            "security_group",
            "cirros_port",
            "bgp_speaker",
            "bgp_peer",
        ],
        start=1,
    )
}


def write_json(path: Path, value: object, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
    path.chmod(mode)


def make_state(run_dir: Path, uid: int) -> dict:
    k8s_names = {
        "server_deployment": f"{NAMESPACE}-server",
        "client_deployment": f"{NAMESPACE}-client",
        "cluster_rack1": f"{NAMESPACE}-rack1",
        "cluster_rack2": f"{NAMESPACE}-rack2",
        "advertisement": f"{NAMESPACE}-pods",
        "peer_config": f"{NAMESPACE}-peer",
        "namespace": NAMESPACE,
    }
    k8s_kinds = {
        "server_deployment": ("Deployment", "apps/v1", NAMESPACE),
        "client_deployment": ("Deployment", "apps/v1", NAMESPACE),
        "cluster_rack1": ("CiliumBGPClusterConfig", "cilium.io/v2", ""),
        "cluster_rack2": ("CiliumBGPClusterConfig", "cilium.io/v2", ""),
        "advertisement": ("CiliumBGPAdvertisement", "cilium.io/v2", ""),
        "peer_config": ("CiliumBGPPeerConfig", "cilium.io/v2", ""),
        "namespace": ("Namespace", "v1", ""),
    }
    k8s_resources = {
        key: {
            "name": k8s_names[key],
            "uid": UIDS[key],
            "kind": k8s_kinds[key][0],
            "api_version": k8s_kinds[key][1],
            "namespace": k8s_kinds[key][2],
        }
        for key in UIDS
    }

    qmp_dir = run_dir / "qemu"
    qmp_dir.mkdir(mode=0o700, exist_ok=True)
    ssh_root = run_dir / "ssh"
    ssh_root.mkdir(mode=0o700, exist_ok=True)
    keys = {}
    known_lines = []
    for guest, fingerprint_char in (("ubuntu", "A"), ("cirros", "B")):
        private_path = ssh_root / f"{guest}.key"
        public_path = ssh_root / f"{guest}.pub"
        private_path.write_text("synthetic private-key fixture\n", encoding="ascii")
        public_blob = "YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXo=" if guest == "ubuntu" else "cXdlcnR5dWlvcGFzZGZnaGprbHpoeGN2Ym5t"
        public_path.write_text(f"ssh-ed25519 {public_blob} {guest}-fixture\n", encoding="ascii")
        private_path.chmod(0o600)
        public_path.chmod(0o600)
        public_stat = public_path.stat()
        guest_uuid = "00112233-4455-4677-8899-aabbccddeeff" if guest == "ubuntu" else "10112233-4455-4677-8899-aabbccddeeff"
        alias = f"p010-20261030-{RUN_ID.split('-')[-1]}-{guest_uuid}-{guest}"
        keys[guest] = {
            "fingerprint": "SHA256:" + fingerprint_char * 43,
            "alias": alias,
            "public_path": str(public_path),
            "public_device": public_stat.st_dev,
            "public_inode": public_stat.st_ino,
        }
        known_lines.append(f"{alias} ssh-ed25519 {public_blob}")
    known_hosts = ssh_root / "known_hosts"
    known_hosts.write_text("\n".join(known_lines) + "\n", encoding="ascii")
    known_hosts.chmod(0o600)
    known_stat = known_hosts.stat()
    ubuntu_key = ssh_root / "ubuntu.key"
    ubuntu_key_stat = ubuntu_key.stat()

    network = {
        "provider_cidr": "198.18.48.0/29",
        "provider_border_ip": "198.18.48.1",
        "provider_speaker_ip": "198.18.48.2",
        "provider_router_ip": "198.18.48.3",
        "tenant_cidr": "198.18.49.0/24",
        "tenant_gateway": "198.18.49.1",
        "speaker_asn": 64590,
        "border_asn": 64590,
    }
    resource_names = {
        "address_scope": "p010-hyb-scope",
        "external_subnetpool": "p010-hyb-external-pool",
        "tenant_subnetpool": "p010-hyb-tenant-pool",
        "external_network": "p010-hyb-external",
        "tenant_network": "p010-hyb-tenant",
        "external_subnet": "p010-hyb-external-subnet",
        "tenant_subnet": "p010-hyb-tenant-subnet",
        "router": "p010-hyb-router",
        "router_interface": "p010-hyb-router-interface",
        "router_gateway_port": "p010-hyb-router-gateway-port",
        "security_group": "p010-hyb-security",
        "cirros_port": "p010-hyb-cirros-port",
        "bgp_speaker": "p010-hyb-speaker",
        "bgp_peer": "p010-hyb-peer",
    }
    api_resources = {
        key: {"primary": {"id": IDS[key], "name": resource_names[key]}}
        for key in resource_names
    }
    api_resources["cirros_port"]["primary"]["fixed_ips"] = [
        {"subnet_id": IDS["tenant_subnet"], "ip_address": VM_IP}
    ]
    api_resources["cirros_port"]["primary"]["mac_address"] = "02:00:00:00:00:22"
    api_resources["security_group_rules"] = {
        name: {"id": f"{number:08x}-1111-4111-8111-{number:012x}"}
        for number, name in enumerate(
            ("ingress_icmp", "ingress_tcp", "egress_icmp", "egress_tcp"), start=100
        )
    }
    agent_ids = {
        key: f"{number:08x}-aaaa-4aaa-8aaa-{number:012x}"
        for number, key in enumerate(("bgp", "dhcp", "l3", "ovs", "ovs_host"), start=201)
    }
    fabric_node_ids = {
        name: f"{number:064x}"
        for number, name in enumerate(
            (
                "clab-p010-hibrido-fabric-spine1",
                "clab-p010-hibrido-fabric-spine2",
                "clab-p010-hibrido-fabric-leaf1",
                "clab-p010-hibrido-fabric-leaf2",
                "clab-p010-hibrido-fabric-leaf3",
                "clab-p010-hibrido-fabric-border1",
                "clab-p010-hibrido-fabric-client",
            ),
            start=1,
        )
    }
    border_id = fabric_node_ids["clab-p010-hibrido-fabric-border1"]
    border_pid = 3444
    netns_device = 2050
    netns_inode = 90001
    guest_common = {
        "netns_device": netns_device,
        "netns_inode": netns_inode,
        "ssh_private_key": str(ubuntu_key),
        "ssh_device": ubuntu_key_stat.st_dev,
        "ssh_inode": ubuntu_key_stat.st_ino,
    }
    guest_state = {
        "ubuntu": {
            **guest_common,
            "uuid": "00112233-4455-4677-8899-aabbccddeeff",
            "tenant_mac": "52:54:00:10:11:03",
            "pid": 3555,
            "starttime": 44000,
            "host_port": 42422,
            "pidfile": str(run_dir / "qemu" / "ubuntu.pid"),
            "pidfile_device": 1,
            "pidfile_inode": 1001,
            "qmp_path": str(run_dir / "qemu" / "u.qmp"),
            "qmp_device": 1,
            "qmp_inode": 1002,
        },
        "cirros": {
            **guest_common,
            "uuid": "10112233-4455-4677-8899-aabbccddeeff",
            "pid": 3666,
            "starttime": 45000,
            "host_port": 42423,
            "pidfile": str(run_dir / "qemu" / "cirros.pid"),
            "pidfile_device": 1,
            "pidfile_inode": 1003,
            "qmp_path": str(run_dir / "qemu" / "c.qmp"),
            "qmp_device": 1,
            "qmp_inode": 1004,
            "tenant_mac": "02:00:00:00:00:22",
        },
    }
    for guest in guest_state.values():
        guest["overlay_path"] = str(run_dir / f"{guest['uuid']}.qcow2")
        guest["overlay_device"] = 1
        guest["overlay_inode"] = 2000
        guest["seed_path"] = str(run_dir / f"{guest['uuid']}.seed.iso")
        guest["seed_device"] = 1
        guest["seed_inode"] = 3000

    return {
        "schema": 3,
        "owner_uid": uid,
        "owner_token": OWNER_TOKEN,
        "profile": "hibrido",
        "run_id": RUN_ID,
        "status": "up",
        "phase": "verified",
        "context": "kind-p010-hibrido",
        "kubeconfig": str(run_dir / "kubeconfig"),
        "kubeconfig_sha256": "a" * 64,
        "api_server": "https://127.0.0.1:6443",
        "cluster_uid": CLUSTER_UID,
        "kind_node_ids": {name: f"{number:064x}" for number, name in enumerate(("p010-hibrido-control-plane", "p010-hibrido-worker", "p010-hibrido-worker2"), start=31)},
        "fabric_node_ids": fabric_node_ids,
        "network_ids": {"management": "10.223.48.0/24"},
        "values_sha256": "b" * 64,
        "hybrid": {
            "schema": 4,
            "phase": "verified",
            "qmp_dir": {"path": str(qmp_dir), "device": qmp_dir.stat().st_dev, "inode": qmp_dir.stat().st_ino},
            "network": {
                "border": {
                    "container_id": border_id,
                    "pid": border_pid,
                    "starttime": 44001,
                    "uid": uid,
                    "netns_device": netns_device,
                    "netns_inode": netns_inode,
                },
                "tap": {
                    "name": "p10t00112233",
                    "reserved_alias": f"p010-hyb-{uid}-{RUN_ID}",
                    "alias": f"p010-hyb-{uid}-{RUN_ID}",
                    "ifindex": 18,
                    "create_phase": "identified",
                },
            },
            "guests": guest_state,
            "m11": {
                "schema": 2,
                "phase": "verified",
                "cilium": {"values_sha256": "b" * 64},
            "network": network,
                "ssh": {
                    "host_keys": keys,
                    "known_hosts_path": str(known_hosts),
                    "known_hosts_device": known_stat.st_dev,
                    "known_hosts_inode": known_stat.st_ino,
                },
                "api": {
                    "identity_endpoint": "http://127.0.0.1:5000/v3",
                    "neutron_endpoint": "http://127.0.0.1:9696/v2.0",
                    "project_id": "1234567890abcdef1234567890abcdef",
                    "agent_ids": agent_ids,
                    "pending": {},
                    "links": {
                        "drinstance": {
                            "agent_id": agent_ids["bgp"],
                            "speaker_id": IDS["bgp_speaker"],
                            "method": "POST",
                            "status": 201,
                            "envelope": "bgp_speakers",
                        },
                    },
                    "resources": api_resources,
                },
                "verification": {
                    "phase": "verified",
                    "gates": {
                        "namespace": NAMESPACE,
                        "k8s_pending": {},
                        "k8s_delete_pending": {},
                        "k8s_resources": k8s_resources,
                        "port_binding": True,
                        "dhcp_lease": {"phase": "verified"},
                        "c0_binding_evidence": {"path": str(run_dir / "m11-evidence" / "c0-binding.json"), "sha256": "c" * 64, "device": 1, "inode": 1, "owner_uid": uid, "mode": "0600", "scope": "C0 Neutron port binding, security-group rules, and OVS attachment"},
                        "ovs_attach": {
                            "phase": "attached", "bridge_name": "br-int", "interface_name": "tenant0",
                            "bridge_uuid": "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa", "port_uuid": "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb",
                            "interface_uuid": "cccccccc-3333-4333-8333-cccccccccccc", "ifindex": 8, "ofport": 6,
                            "neutron_port_id": IDS["cirros_port"], "guest_uuid": guest_state["ubuntu"]["uuid"],
                            "attached_mac": "02:00:00:00:00:22", "guest_interface_mac": "52:54:00:10:11:03"
                        },
                        "client_pod": {"name": "client-pod", "uid": "88888888-8888-4888-8888-888888888888", "ip": POD_CLIENT, "node": "p010-hibrido-worker", "pod_cidr": "10.246.1.0/24"},
                        "server_pod": {"name": "server-pod", "uid": "99999999-9999-4999-8999-999999999999", "ip": POD_SERVER, "node": "p010-hibrido-worker2", "pod_cidr": "10.246.2.0/24"},
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
                        "traffic_capture": {"phase": "absent", "path": "", "pid": 0, "starttime": 0, "process_uid": 0, "file_uid": 0, "device": 0, "inode": 0, "mode": ""},
                        "dhcp_capture": {"phase": "absent", "path": "", "client_mac": "", "address": "", "gateway": "", "server_ip": "", "pid": 0, "starttime": 0, "process_uid": 0, "owner_uid": 0, "device": 0, "inode": 0, "xid": ""},
                        "ovs_attach": {"phase": "detached"},
                    },
                },
            },
        },
    }


def write_fake_tools(bin_dir: Path) -> None:
    bin_dir.mkdir(parents=True, exist_ok=True)
    script = bin_dir / "fake-tool.py"
    script.write_text(
        """#!__PYTHON__
import hashlib, json, os, re, shlex, shutil, signal, subprocess, sys, tempfile, time
from pathlib import Path

name = Path(sys.argv[0]).name
args = sys.argv[1:]
mode = os.environ.get('P010_M20_MODE', 'positive')
trace = Path(os.environ['P010_M20_TRACE'])
deleted_file = Path(os.environ['P010_M20_DELETED'])
run_id = os.environ['P010_M20_RUN_ID']
uid = int(os.environ['P010_M20_UID'])
NAMESPACE = 'p010-hyb-0123456789ab'
POD_CLIENT = '10.246.1.10'
POD_SERVER = '10.246.2.10'
STATE_FILE = Path(os.environ['P010_M20_STATE_FILE'])
PROC_ROOT = Path(os.environ['P010_M20_PROC_ROOT'])
IDENTITY_ROOT = Path(os.environ['P010_M20_FIXTURE_IDENTITIES'])

def read_state():
    return json.loads(STATE_FILE.read_text(encoding='utf-8'))

def active_observers():
    return read_state()['hybrid']['m11']['verification']['gates']['c1_capture_active']['observers']

def kernel_starttime(pid):
    line = Path(f'/proc/{pid}/stat').read_text(encoding='ascii')
    rest = line[line.rfind(') ') + 2:].split()
    return int(rest[19])

def record_fixture_identity(pid):
    identity = {'pid': pid, 'uid': os.stat(f'/proc/{pid}').st_uid, 'starttime': kernel_starttime(pid)}
    IDENTITY_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    (IDENTITY_ROOT / f'{pid}.json').write_text(json.dumps(identity, sort_keys=True) + '\\n', encoding='ascii')
    return identity

def trace_has_wave(number):
    if not trace.exists(): return False
    for line in trace.read_text(encoding='utf-8').splitlines():
        try: event = json.loads(line)
        except json.JSONDecodeError: continue
        if event.get('kind') == 'c1-wave' and event.get('wave') == number: return True
    return False

def assignment(script, name):
    match = re.search(r'^' + re.escape(name) + r'=(.+)$', script, re.MULTILINE)
    if not match: return ''
    values = shlex.split(match.group(1))
    return values[0] if values else ''

def packet_lines(flow, observer, wave):
    if wave == 1:
        src, dst, port = POD_CLIENT, '198.18.49.22', 22
        first_seq, second_seq, first_stamp = 0xffffffff, 41, '2026-10-30 00:00:01'
        ident, icmp_sequences = 0, (0, 65535)
    else:
        src, dst, port = '198.18.49.22', POD_SERVER, 8080
        first_seq, second_seq, first_stamp = 123, 0xffffffff, '2026-10-30 00:00:02'
        ident, icmp_sequences = 65535, (1, 2)
    local_mac = observer['mac']
    peer_mac = '02:aa:bb:cc:dd:ee'
    lines = []
    def frame(offset, source, destination, body, reverse=False, protocol=1):
        source_mac, destination_mac = (peer_mac, local_mac) if reverse else (local_mac, peer_mac)
        stamp = first_stamp + f'.{offset:06d}'
        detail = body if ' > ' in body else f'{source} > {destination}: {body}'
        protocol_name = {1: 'ICMP', 6: 'TCP'}[protocol]
        lines.append(f'{stamp} {source_mac} > {destination_mac}, ethertype IPv4 (0x0800), length 98: IP (tos 0x0, ttl 64, id 1, offset 0, flags [DF], proto {protocol_name} ({protocol}), length 84) {detail}')
    for offset, sequence in enumerate(icmp_sequences):
        frame(offset, src, dst, f'ICMP echo request, id {ident}, seq {sequence}, length 64')
        frame(offset + 2, dst, src, f'ICMP echo reply, id {ident}, seq {sequence}, length 64', True)
    client_port = 40000 + wave
    frame(5, src, dst, f'{src}.{client_port} > {dst}.{port}: Flags [SEW], seq {first_seq}, win 64240, length 0', protocol=6)
    frame(6, dst, src, f'{dst}.{port} > {src}.{client_port}: Flags [S.EW], seq {second_seq}, ack {(first_seq + 1) & 0xffffffff}, win 65160, length 0', True, protocol=6)
    frame(7, src, dst, f'{src}.{client_port} > {dst}.{port}: Flags [.], ack {(second_seq + 1) & 0xffffffff}, win 502, length 0', protocol=6)
    return lines

def append_wave(wave):
    active = [entry for entry in active_observers() if entry.get('phase') == 'capturing']
    selected_border_interface = 'swp1' if wave == 1 else 'swp2'
    expected = [entry for entry in active if entry.get('role') in ('ubuntu-tenant0', 'cirros-endpoint', 'qrouter-tenant', 'qrouter-provider', 'border-tap') or (entry.get('role') == 'border-fabric' and entry.get('interface') == selected_border_interface) or entry.get('key') in (('worker-pod_to_cirros', 'pod-pod_to_cirros') if wave == 1 else ('worker-cirros_to_pod', 'pod-cirros_to_pod'))]
    if len(active) < 10 or len(expected) < 7:
        raise SystemExit(66)
    for entry in expected:
        path = Path(entry['capture_path'])
        text = '\\n'.join(packet_lines('', entry, wave)) + '\\n'
        if os.environ.get('P010_M20_MODE') == 'capture-tuple' and wave == 1 and entry['key'] == 'border-tap':
            text = text.replace(POD_CLIENT, '10.246.1.11', 1)
        if os.environ.get('P010_M20_MODE') == 'capture-ack-ambiguous' and wave == 1 and entry['key'] == 'border-tap':
            text += f'2026-10-30 00:00:01.000008 {entry["mac"]} > 02:aa:bb:cc:dd:ee, ethertype IPv4 (0x0800), length 98: IP (tos 0x0, ttl 64, id 1, offset 0, flags [DF], proto 6, length 60) 198.18.49.22.22 > {POD_CLIENT}.40001: Flags [S.], seq 41, ack 1, win 64240, length 0\\n'
        if os.environ.get('P010_M20_MODE') == 'capture-rstack' and wave == 1 and entry['key'] == 'border-tap':
            text = text.replace('Flags [.], ack 42', 'Flags [R.], seq 0, ack 42')
        if os.environ.get('P010_M20_MODE') == 'capture-synfin' and wave == 1 and entry['key'] == 'border-tap':
            text = text.replace('Flags [SEW], seq 4294967295', 'Flags [SF], seq 4294967295')
        if os.environ.get('P010_M20_MODE') == 'capture-nul' and wave == 1 and entry['key'] == 'border-tap':
            text = text.replace('Flags [.], ack 42', 'Flags [.], ack 42\\x00')
        if os.environ.get('P010_M20_MODE') == 'capture-truncated' and wave == 1 and entry['key'] == 'border-tap':
            text = text[:-1]
        with path.open('a', encoding='utf-8') as stream:
            stream.write(text)
    emit('c1-wave', wave=wave, ready=len(active), observers=len(expected))

def c1_capture_action(script):
    for marker, action in (('P010_C1_CAPTURE_RECORD=', 'start'), ('P010_C1_CAPTURE_CHECK=', 'check'), ('P010_C1_CAPTURE_SNAPSHOT=', 'snapshot'), ('P010_C1_CAPTURE_RESULT=', 'stop'), ('P010_C1_CAPTURE_REMOVED=', 'cleanup')):
        if marker in script: return action
    return ''

def run_c1_capture_script(script, transport, guest=''):
    action = c1_capture_action(script)
    if not action: return False
    script_sha256 = hashlib.sha256(script.encode('utf-8')).hexdigest()
    tool_dir = Path(sys.argv[0]).resolve().parent
    capture = assignment(script, 'capture')
    observer = next((entry for entry in active_observers() if entry.get('capture_path') == capture), {})
    key = observer.get('key') or assignment(script, 'key')
    child_env = os.environ.copy()
    child_env['PATH'] = str(tool_dir) + os.pathsep + child_env.get('PATH', '')
    child_env['P010_M20_CAPTURE_ACTION'] = action
    child_env['P010_M20_CAPTURE_KEY'] = key
    rendered_script = script
    if child_env.get('P010_M20_DEBUG_C1') == '1' and script.count('exec >/dev/null 2>&1') == 1:
        script = script.replace('exec >/dev/null 2>&1', 'exec >/dev/null 2>&1\\nexec 2>&4\\nset -x', 1)
    with tempfile.TemporaryFile(mode='w+t', encoding='utf-8') as stdout_file, tempfile.TemporaryFile(mode='w+t', encoding='utf-8') as stderr_file:
        result = subprocess.run(['/bin/bash', '-se'], input=script, text=True, env=child_env,
                                stdout=stdout_file, stderr=stderr_file, check=False)
        stdout_file.seek(0)
        stderr_file.seek(0)
        stdout = stdout_file.read()
        stderr = stderr_file.read()
    sys.stdout.write(stdout)
    sys.stderr.write(stderr)
    emit('c1-capture', action=action, transport=transport, guest=guest, key=key, rc=result.returncode,
         script_sha256=script_sha256,
         stderr=stderr[-4000:] if result.returncode else '')
    if result.returncode:
        failure_root = Path(child_env['P010_C1_FAILURE_ROOT'])
        failure_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        failure_dir = failure_root / script_sha256
        failure_dir.mkdir(mode=0o700, exist_ok=True)
        (failure_dir / 'rendered.sh').write_text(rendered_script, encoding='utf-8')
        (failure_dir / 'stdout.log').write_text(stdout, encoding='utf-8')
        (failure_dir / 'stderr.log').write_text(stderr, encoding='utf-8')
        (failure_dir / 'failure.json').write_text(json.dumps({
            'utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
            'rc': result.returncode,
            'sha256': hashlib.sha256(rendered_script.encode('utf-8')).hexdigest(),
            'action': action, 'transport': transport, 'guest': guest, 'key': key,
        }, sort_keys=True, indent=2) + '\\n', encoding='utf-8')
        raise SystemExit(result.returncode)
    return True

def proc_entry(pid, argv, process_uid, netns, starttime, missing_terminator=False):
    directory = PROC_ROOT / str(pid)
    (directory / 'ns').mkdir(parents=True, exist_ok=True)
    fields = ['S'] + [str(value) for value in range(4, 23)]
    fields[-1] = str(starttime)
    (directory / 'stat').write_text(f'{pid} (capture fixture) ' + ' '.join(fields) + '\\n', encoding='ascii')
    (directory / 'status').write_text(f'Name:\tcapture\\nUid:\t{process_uid}\\t{process_uid}\\t{process_uid}\\t{process_uid}\\n', encoding='ascii')
    (directory / 'ns/net').write_text('net namespace fixture\\n', encoding='ascii')
    command_line = b'\\0'.join(str(part).encode('utf-8') for part in argv)
    if not missing_terminator:
        command_line += b'\\0'
    (directory / 'cmdline').write_bytes(command_line)
    (directory / 'identity.json').write_text(json.dumps({'uid': process_uid, 'netns': netns, 'starttime': starttime}), encoding='ascii')

def tcpdump_process():
    if args == ['--version']:
        print('tcpdump version 4.99.5')
        return 0
    argv = [sys.argv[0], *args]
    observer = next((item for item in active_observers() if item.get('argv') == argv), None)
    if observer is None:
        return 47
    PROC_ROOT.mkdir(parents=True, exist_ok=True)
    if not (PROC_ROOT / '1' / 'stat').exists():
        (PROC_ROOT / '1').mkdir(parents=True, exist_ok=True)
        proc_entry(1, ['init'], 0, '205:1', 1)
    netns = observer.get('expected_netns') or '205:7001'
    boot_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    boot_path = PROC_ROOT / 'sys/kernel/random/boot_id'
    boot_path.parent.mkdir(parents=True, exist_ok=True)
    boot_path.write_text(boot_id + '\\n', encoding='ascii')
    supervisor_pid = os.getppid()
    child_pid = os.getpid()
    starttime = kernel_starttime(child_pid)
    child_identity = record_fixture_identity(child_pid)
    supervisor_identity = record_fixture_identity(supervisor_pid)
    if not observer.get('expected_netns') and '/5111/' in observer.get('netns_path', ''):
        netns = '205:5111'
    elif not observer.get('expected_netns') and '/5222/' in observer.get('netns_path', ''):
        netns = '205:5222'
    proc_entry(supervisor_pid, observer['supervisor_argv'], supervisor_identity['uid'], netns, supervisor_identity['starttime'],
               mode == 'capture-cmdline-supervisor-terminator' and observer.get('key') == 'border-tap')
    proc_entry(child_pid, observer['argv'], child_identity['uid'], netns, starttime,
               mode == 'capture-cmdline-child-terminator' and observer.get('key') == 'border-tap')
    print(f'tcpdump: listening on {observer["interface"]}, link-type EN10MB (Ethernet), snapshot length 262144 bytes', flush=True)
    capture_path = Path(observer['capture_path'])
    def finish(signum, _frame):
        text = capture_path.read_text(encoding='utf-8') if capture_path.exists() else ''
        packets = sum(line.startswith('2026-') for line in text.splitlines())
        dropped = 1 if mode == 'capture-dropped' and observer.get('key') == 'border-tap' else 0
        sys.stdout.write(f'{packets} packets captured\\n{packets} packets received by filter\\n{dropped} packets dropped by kernel\\n')
        sys.stdout.flush()
        shutil.rmtree(PROC_ROOT / str(child_pid), ignore_errors=True)
        raise SystemExit(130)
    signal.signal(signal.SIGINT, finish)
    signal.signal(signal.SIGTERM, finish)
    while True:
        time.sleep(30)

def fake_proc_metadata(path):
    try:
        relative = Path(path).relative_to(PROC_ROOT)
    except ValueError:
        return None
    if not relative.parts or not relative.parts[0].isdigit():
        return None
    identity = PROC_ROOT / relative.parts[0] / 'identity.json'
    if not identity.exists():
        return None
    return json.loads(identity.read_text(encoding='ascii'))

def fake_stat():
    format_string = args[1] if len(args) > 1 else ''
    path = args[-1] if args else ''
    metadata = fake_proc_metadata(path)
    if metadata:
        observer = next((entry for entry in active_observers() if entry.get('key') == os.environ.get('P010_M20_CAPTURE_KEY')), {})
        target_pid = observer.get('tcpdump_pid')
        try:
            proc_relative = Path(path).relative_to(PROC_ROOT)
            proc_pid = proc_relative.parts[0] if proc_relative.parts else ''
        except ValueError:
            proc_pid = ''
        if mode == 'capture-stop-uid' and os.environ.get('P010_M20_CAPTURE_ACTION') == 'stop' and proc_pid == str(target_pid):
            metadata['uid'] += 1
        if mode == 'capture-stop-netns' and os.environ.get('P010_M20_CAPTURE_ACTION') == 'stop' and proc_pid == str(target_pid) and path.endswith('/ns/net'):
            metadata['netns'] = '205:9999'
        if format_string == '%u': print(metadata['uid'])
        elif format_string == '%d:%i': print(metadata['netns'])
        else: raise SystemExit(49)
        return
    guest_observer = next((entry for entry in active_observers() if entry.get('key') == os.environ.get('P010_M20_CAPTURE_KEY')), {})
    guest_files = {guest_observer.get('capture_path', '')}
    guest_files.update(guest_observer.get('capture_path', '') + suffix for suffix in ('.supervisor', '.tcpdump', '.rc'))
    if (mode in ('capture-guest-owner', 'capture-guest-owner-mismatch') and guest_observer.get('transport') == 'guest'
            and path in guest_files and os.environ.get('P010_M20_CAPTURE_ACTION') in ('start', 'check', 'snapshot', 'stop', 'cleanup')):
        stat_result = os.stat(path, follow_symlinks=False)
        guest_uid = int(os.environ.get('P010_M20_GUEST_UID', str(uid + 1)))
        file_uid = int(os.environ.get('P010_M20_UID', str(uid))) if mode == 'capture-guest-owner-mismatch' else guest_uid
        values = {'%d': stat_result.st_dev, '%i': stat_result.st_ino, '%u': file_uid,
                  '%a': format(stat_result.st_mode & 0o777, 'o')}
        if format_string == '%d|%i|%u|%a': print(f'{values["%d"]}|{values["%i"]}|{values["%u"]}|{values["%a"]}')
        elif format_string == '%u|%a': print(f'{values["%u"]}|{values["%a"]}')
        elif format_string in values: print(values[format_string])
        else: raise SystemExit(49)
        return
    for observer in active_observers():
        if path == observer.get('netns_path'):
            if format_string == '%d:%i': print(observer.get('expected_netns') or '205:7001'); return
    if format_string == '%d:%i' and path.endswith('/ns/pid'):
        print('205:100')
        return
    if format_string == '%d:%i' and path.endswith('/ns/net'):
        print('205:' + ('5111' if '/5111/' in path else '5222'))
        return
    stat_result = os.stat(path, follow_symlinks=False)
    values = {'%d': stat_result.st_dev, '%i': stat_result.st_ino, '%u': stat_result.st_uid,
              '%a': format(stat_result.st_mode & 0o777, 'o')}
    if format_string == '%d|%i|%u|%a': print(f'{values["%d"]}|{values["%i"]}|{values["%u"]}|{values["%a"]}')
    elif format_string in values: print(values[format_string])
    else: raise SystemExit(49)

def fake_cat():
    path = args[-1] if args else ''
    if path == '-':
        sys.stdout.buffer.write(sys.stdin.buffer.read())
        return
    data = Path(path).read_bytes()
    sys.stdout.buffer.write(data)

def fake_kill():
    if len(args) != 2 or args[0] not in ('-0', '-INT', '-TERM'):
        raise SystemExit(64)
    pid = int(args[1])
    if (args[0] == '-0' and mode == 'capture-readiness'
            and os.environ.get('P010_M20_CAPTURE_ACTION') == 'check'
            and os.environ.get('P010_M20_CAPTURE_KEY') == 'pod-cirros_to_pod'):
        identity_path = IDENTITY_ROOT / f'{pid}.json'
        if not identity_path.is_file():
            raise SystemExit(77)
        expected = json.loads(identity_path.read_text(encoding='ascii'))
        actual = {'pid': pid, 'uid': os.stat(f'/proc/{pid}').st_uid, 'starttime': kernel_starttime(pid)}
        if actual != expected:
            raise SystemExit(78)
        if hasattr(os, 'pidfd_open') and hasattr(signal, 'pidfd_send_signal'):
            process_fd = os.pidfd_open(pid)
            try: signal.pidfd_send_signal(process_fd, signal.SIGTERM)
            finally: os.close(process_fd)
        else:
            os.kill(pid, signal.SIGTERM)
        raise SystemExit(1)
    if args[0] in ('-INT', '-TERM'):
        identity_path = IDENTITY_ROOT / f'{pid}.json'
        if not identity_path.is_file():
            raise SystemExit(77)
        expected = json.loads(identity_path.read_text(encoding='ascii'))
        try:
            actual = {'pid': pid, 'uid': os.stat(f'/proc/{pid}').st_uid, 'starttime': kernel_starttime(pid)}
        except (FileNotFoundError, ProcessLookupError):
            raise SystemExit(1)
        if actual != expected:
            raise SystemExit(78)
        emit('fake-signal', pid=pid, signal=args[0], identity=actual)
    try:
        os.kill(pid, 0 if args[0] == '-0' else (signal.SIGINT if args[0] == '-INT' else signal.SIGTERM))
    except ProcessLookupError:
        shutil.rmtree(PROC_ROOT / str(pid), ignore_errors=True)
        raise SystemExit(1)
    raise SystemExit(0)

def fake_test():
    if len(args) != 2 or args[0] not in ('-d', '-e', '-r', '-f'):
        raise SystemExit(64)
    path = args[1]
    metadata = fake_proc_metadata(path)
    if (metadata and args[0] == '-r' and path.endswith('/stat')
            and mode == 'capture-stop-proc-query'
            and os.environ.get('P010_M20_CAPTURE_ACTION') == 'stop'):
        observer = next((entry for entry in active_observers() if entry.get('key') == os.environ.get('P010_M20_CAPTURE_KEY')), {})
        try:
            proc_relative = Path(path).relative_to(PROC_ROOT)
            proc_pid = proc_relative.parts[0] if proc_relative.parts else ''
        except ValueError:
            proc_pid = ''
        if proc_pid == str(observer.get('tcpdump_pid')):
            raise SystemExit(1)
    if metadata and args[0] == '-d' and Path(path) == PROC_ROOT / Path(path).name:
        pid = int(Path(path).name)
        if pid == 1: raise SystemExit(0)
        try: os.kill(pid, 0)
        except ProcessLookupError:
            shutil.rmtree(PROC_ROOT / str(pid), ignore_errors=True)
            raise SystemExit(1)
        except PermissionError:
            raise SystemExit(0)
        raise SystemExit(0)
    if metadata and path.endswith('/stat'):
        pid = int(Path(path).parts[-2])
        if pid == 1:
            raise SystemExit(0)
        try: os.kill(int(Path(path).parts[-2]), 0)
        except ProcessLookupError:
            shutil.rmtree(PROC_ROOT / Path(path).parts[-2], ignore_errors=True)
            raise SystemExit(1)
        except PermissionError:
            raise SystemExit(0)
        raise SystemExit(0)
    if Path(path).exists(): raise SystemExit(0)
    raise SystemExit(1)

def fake_ip(pod_ip=None, netns_path=''):
    if args[:6] == ['-d', '-o', 'link', 'show', 'dev', 'p10t00112233']:
        emit('border-tap-link', args=args)
        print('18: p10t00112233: <BROADCAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP mode DEFAULT group default qlen 1000 link/ether 52:54:00:11:22:33 brd ff:ff:ff:ff:ff:ff alias p010-hyb-' + str(uid) + '-' + run_id + ' tun type tap')
        return
    if args[:4] == ['-j', 'route', 'show', 'exact']:
        prefix = args[4] if len(args) > 4 else ''
        if mode == 'route':
            emit('border-route', prefix=prefix, rc=38)
            raise SystemExit(38)
        gateway, dev = ('10.30.1.1', 'swp1') if prefix == '10.246.1.0/24' else ('10.30.2.1', 'swp2')
        emit('border-route', prefix=prefix, dev=dev)
        print(json.dumps([{'dst':prefix,'protocol':'bgp','nexthops':[{'gateway':gateway,'dev':dev,'weight':1,'flags':[]}] }], separators=(',',':')))
        return
    if len(args) >= 5 and args[:4] == ['-d', '-o', 'link', 'show']:
        dev = args[-1]
        observer = next((entry for entry in active_observers() if entry.get('interface') == dev), None)
        if observer is None:
            index, mac = (30, '02:aa:bb:cc:dd:01') if dev == 'swp1' else (31, '02:aa:bb:cc:dd:02')
        else:
            index, mac = observer.get('expected_ifindex', 1), observer.get('expected_mac', '02:aa:bb:cc:dd:01')
        emit('border-fabric-link', dev=dev)
        print(f'{index}: {dev}: <BROADCAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP mode DEFAULT group default qlen 1000 link/ether {mac} brd ff:ff:ff:ff:ff:ff')
        return
    if args[:3] == ['-j', 'address', 'show']:
        is_server = pod_ip == POD_SERVER
        emit('pod-link-read', args=args)
        print(json.dumps([{'ifindex':5 if is_server else 4,'ifname':'eth0','address':'02:00:00:00:00:33' if is_server else '02:00:00:00:00:22','addr_info':[{'family':'inet','local':pod_ip or '198.18.49.22','prefixlen':24}]}], separators=(',',':')))
        return
    if args[:4] == ['-o', 'link', 'show', 'dev']:
        interface = args[4] if len(args) > 4 else ''
        observers = active_observers()
        observer = next((entry for entry in observers if entry.get('interface') == interface), None)
        current = next((entry for entry in observers if entry.get('key') == os.environ.get('P010_M20_CAPTURE_KEY')), {})
        qrouter_roles = ('qrouter-tenant', 'qrouter-provider')
        if observer is None:
            if current.get('role') in qrouter_roles:
                domain = 'qrouter' if netns_path == current.get('netns_path') else 'guest'
                emit('qrouter-link-inventory', domain=domain, role=current['role'], interface=interface, found=False)
            raise SystemExit(48)
        if observer.get('role') in qrouter_roles:
            domain = 'qrouter' if netns_path == observer.get('netns_path') else 'guest'
            found = domain == 'qrouter'
            emit('qrouter-link-inventory', domain=domain, role=observer['role'], interface=interface,
                 found=found, ifindex=observer['expected_ifindex'] if found else None)
            if not found:
                raise SystemExit(48)
        index = observer['expected_ifindex']
        if mode == 'capture-interface' and trace_has_wave(1): index += 1
        print(f"{index}: {interface}: <BROADCAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP mode DEFAULT group default qlen 1000 link/ether {observer['expected_mac']} brd ff:ff:ff:ff:ff:ff")
        return
    raise SystemExit(49)

def emit(kind, **fields):
    with trace.open('a', encoding='utf-8') as stream:
        stream.write(json.dumps({'kind': kind, **fields}, sort_keys=True) + '\\n')

def output(value):
    if isinstance(value, (dict, list)):
        print(json.dumps(value, separators=(',', ':')))
    elif value:
        print(value)

def after(token):
    return args[args.index(token) + 1] if token in args and args.index(token) + 1 < len(args) else ''

def recorded_name(resource):
    if resource == 'namespaces': return 'p010-hyb-0123456789ab'
    names = {
      'deployments': ['p010-hyb-0123456789ab-server','p010-hyb-0123456789ab-client'],
      'ciliumbgpclusterconfigs': ['p010-hyb-0123456789ab-rack1','p010-hyb-0123456789ab-rack2'],
      'ciliumbgpadvertisements': ['p010-hyb-0123456789ab-pods'],
      'ciliumbgppeerconfigs': ['p010-hyb-0123456789ab-peer'],
    }
    for candidate in names.get(resource, []):
        if candidate in args: return candidate
    return ''

def object_for(resource, obj_name):
    groups = {
      'namespaces': ('Namespace','v1',''),
      'deployments': ('Deployment','apps/v1','p010-hyb-0123456789ab'),
      'ciliumbgpclusterconfigs': ('CiliumBGPClusterConfig','cilium.io/v2',''),
      'ciliumbgpadvertisements': ('CiliumBGPAdvertisement','cilium.io/v2',''),
      'ciliumbgppeerconfigs': ('CiliumBGPPeerConfig','cilium.io/v2',''),
    }
    kind, version, namespace = groups[resource]
    suffix = {'-server':'server_deployment','-client':'client_deployment','-rack1':'cluster_rack1','-rack2':'cluster_rack2','-pods':'advertisement','-peer':'peer_config'}.get(obj_name[len('p010-hyb-0123456789ab'):], 'namespace')
    uids = {
      'server_deployment':'11111111-1111-4111-8111-111111111111','client_deployment':'22222222-2222-4222-8222-222222222222',
      'cluster_rack1':'33333333-3333-4333-8333-333333333333','cluster_rack2':'44444444-4444-4444-8444-444444444444',
      'advertisement':'55555555-5555-4555-8555-555555555555','peer_config':'66666666-6666-4666-8666-666666666666','namespace':'77777777-7777-4777-8777-777777777777'}
    return {'apiVersion':version,'kind':kind,'metadata':{'name':obj_name,'namespace':namespace,'uid':uids[suffix], 'labels':{'p010-student-owner':'11111111111141118111111111111111','p010-student-run':run_id}}}

if name == 'events':
    emit(args[0], **({'action':args[1], 'guest':args[2]} if args[0] == 'qmp' else {'mode':args[1]} if args[0] == 'api' else {}))
    raise SystemExit(0)
if name == 'setpriv':
    while args and args[0] != '--': args.pop(0)
    if args: args.pop(0)
    os.execvp(args[0], args)
if name == 'nsenter':
    command_args = args[args.index('--') + 1:] if '--' in args else args
    script = sys.stdin.read() if command_args and command_args[0] in ('/bin/sh', '/bin/bash') else ''
    net_path = next((part.split('=', 1)[1] for part in args if part.startswith('--net=')), '')
    is_server = '/5111/' in net_path
    if '--' in args: args = args[args.index('--') + 1:]
    if args and Path(args[0]).name == 'ip':
        args = args[1:]
        link_netns_path = net_path
        current = next((entry for entry in active_observers() if entry.get('key') == os.environ.get('P010_M20_CAPTURE_KEY')), {})
        if (mode == 'capture-qrouter-wrong-netns'
                and os.environ.get('P010_M20_CAPTURE_ACTION') == 'check'
                and current.get('role') in ('qrouter-tenant', 'qrouter-provider')):
            link_netns_path = ''
        fake_ip(POD_SERVER if is_server else POD_CLIENT, netns_path=link_netns_path)
        raise SystemExit(0)
    if args[:7] == ['/usr/sbin/ip', '-d', '-o', 'link', 'show', 'dev', 'p10t00112233']:
        emit('border-tap-link', args=args)
        print('18: p10t00112233: <BROADCAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP mode DEFAULT group default qlen 1000 link/ether 52:54:00:11:22:33 brd ff:ff:ff:ff:ff:ff alias p010-hyb-' + str(uid) + '-' + run_id + ' tun type tap')
        raise SystemExit(0)
    if args[:5] == ['/usr/sbin/ip', '-j', 'route', 'show', 'exact']:
        prefix = args[5] if len(args) > 5 else ''
        if mode == 'route':
            emit('border-route', prefix=prefix, rc=38)
            raise SystemExit(38)
        gateway, dev = ('10.30.1.1', 'swp1') if prefix == '10.246.1.0/24' else ('10.30.2.1', 'swp2')
        emit('border-route', prefix=prefix, dev=dev)
        output([{'dst':prefix,'protocol':'bgp','nexthops':[{'gateway':gateway,'dev':dev,'weight':1,'flags':[]}] }])
        raise SystemExit(0)
    if len(args) >= 7 and args[:6] == ['/usr/sbin/ip', '-d', '-o', 'link', 'show', 'dev']:
        dev = args[6]
        emit('border-fabric-link', dev=dev)
        print(('30: ' if dev == 'swp1' else '31: ') + dev + ': <BROADCAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP mode DEFAULT group default qlen 1000 link/ether 02:aa:bb:cc:dd:01 brd ff:ff:ff:ff:ff:ff')
        raise SystemExit(0)
    if args[:4] == ['/usr/sbin/ip', '-j', 'address', 'show']:
        emit('pod-link-read', args=args)
        ip = POD_SERVER if is_server else POD_CLIENT
        mac = '0a:58:0a:f6:02:0a' if is_server else '0a:58:0a:f6:01:0a'
        print(json.dumps([{'ifindex':5 if is_server else 4,'ifname':'eth0','address':mac,'addr_info':[{'family':'inet','local':ip,'prefixlen':24}]}], separators=(',',':')))
        raise SystemExit(0)
    if run_c1_capture_script(script, 'netns'):
        raise SystemExit(0)
    emit('nsenter', executable=Path(args[0]).name if args else '')
    if script:
        result = subprocess.run(args, input=script, text=True, check=False)
        raise SystemExit(result.returncode)
    os.execvp(args[0], args)
if name == 'ip':
    fake_ip()
    raise SystemExit(0)
if name == 'stat':
    fake_stat()
    raise SystemExit(0)
if name == 'cat':
    fake_cat()
    raise SystemExit(0)
if name == 'kill':
    fake_kill()
    raise SystemExit(0)
if name == 'test':
    fake_test()
    raise SystemExit(0)
if name == 'id':
    if args != ['-u']: raise SystemExit(64)
    if mode in ('capture-guest-owner', 'capture-guest-owner-mismatch'):
        print(int(os.environ.get('P010_M20_UID', str(uid))) + 1)
    else:
        print(os.environ.get('P010_M20_UID', str(uid)))
    raise SystemExit(0)
if name == 'tcpdump':
    raise SystemExit(tcpdump_process())
if name == 'sha256sum':
    for path in args: print(f'{hashlib.sha256(Path(path).read_bytes()).hexdigest()}  {path}')
    raise SystemExit(0)
if name == 'ssh-keygen':
    key_file = args[-1]
    char = 'A' if 'ubuntu' in key_file else 'B'
    print(f'256 SHA256:{char * 43} {key_file} (ED25519)')
    raise SystemExit(0)
if name == 'ssh':
    script = sys.stdin.read()
    guest = 'cirros' if 'cirros@127.0.0.1' in args else 'ubuntu'
    if run_c1_capture_script(script, 'guest', guest):
        raise SystemExit(0)
    if 'P010_C1_REVERSE_PROBE=ok' in script:
        append_wave(2)
        emit('ssh', guest=guest, phase='c1-reverse-probe')
        print('P010_C1_REVERSE_PROBE=ok')
        raise SystemExit(0)
    if 'P010_C0_OVS_BRIDGE=' in script:
        phase = 'ovs-verify'
    elif 'P010_C1_GUEST_LINKS=' in script:
        phase = 'c1-discovery'
    elif 'P010_ORIGIN_CAPTURE_PATH=' in script:
        phase = 'capture-start'
    elif 'P010_ORIGIN_SOURCE=' in script:
        phase = 'observer'
    elif 'P010_M11_ORIGIN_CAPTURE=absent' in script:
        phase = 'capture-stop'
    elif 'P010_M11_DHCP_CAPTURE=absent' in script:
        phase = 'dhcp-stop'
    elif 'P010_OVS_DETACH=absent' in script:
        phase = 'ovs-detach'
    else:
        phase = 'guest-probe'
    emit('ssh', guest=guest, phase=phase)
    if phase == 'ovs-verify':
        values = {
          'BRIDGE':'br-int', 'BRIDGE_UUID':'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',
          'PORT_UUID':'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb', 'INTERFACE_UUID':'cccccccc-3333-4333-8333-cccccccccccc',
          'IFINDEX':'8', 'OFPORT':'6', 'IFACE_ID':'0000000c-1111-4111-8111-00000000000c',
          'ATTACHED_MAC':'02:00:00:00:00:22', 'GUEST_MAC':'52:54:00:10:11:03'
        }
        for key, value in values.items(): print(f'P010_C0_OVS_{key}={value}')
    elif phase == 'c1-discovery':
        print('P010_C1_GUEST_LINKS=2050:6001|tenant0|8')
        print('P010_C1_QROUTER=qrouter-synthetic|2050:6002|qr-tenant|10|fa:16:3e:49:00:01|qg-provider|11|fa:16:3e:48:00:03')
    elif 'P010_C1_CIRROS_LINKS=' in script:
        print('P010_C1_CIRROS_LINKS=[{"ifindex":7,"ifname":"eth0","address":"02:00:00:00:00:22","addr_info":[{"family":"inet","local":"198.18.49.22","prefixlen":24}]}]')
    elif mode == 'observer' and phase == 'observer': raise SystemExit(31)
    elif phase == 'capture-start':
        print(f'P010_ORIGIN_CAPTURE_PATH=/tmp/p010-{run_id}-m11-origin.Ab12Cd34')
        print('P010_ORIGIN_CAPTURE_PID=12345')
        print('P010_ORIGIN_CAPTURE_STARTTIME=55555')
        print(f'P010_ORIGIN_CAPTURE_UID={uid}')
        print(f'P010_ORIGIN_CAPTURE_FILE=111|222|{uid}|600')
    elif phase == 'observer':
        print('P010_ORIGIN_SOURCE=198.18.49.22')
        print('P010_ORIGIN_DESTINATION=10.246.2.10')
    elif phase == 'capture-stop': print('P010_M11_ORIGIN_CAPTURE=absent')
    elif phase == 'dhcp-stop': print('P010_M11_DHCP_CAPTURE=absent')
    elif phase == 'ovs-detach': print('P010_OVS_DETACH=absent')
    raise SystemExit(0)

if name == 'kubectl':
    op = next((part for part in ('create','get','rollout','wait','exec','delete') if part in args), 'unknown')
    pos = args.index(op) if op in args else 0
    tail = args[pos + 1:]
    emit('kubectl', operation=op, args=tail[:4])
    if op == 'create':
        filename = after('-f')
        document = Path(filename).read_text(encoding='utf-8')
        api_version = re.search(r'(?m)^apiVersion:\\s*([^\\s]+)', document)
        kind_match = re.search(r'(?m)^kind:\\s*([^\\s]+)', document)
        name_match = re.search(r'(?m)^  name:\\s*([^\\s]+)', document)
        namespace_match = re.search(r'(?m)^  namespace:\\s*([^\\s]+)', document)
        if not (api_version and kind_match and name_match): raise SystemExit(49)
        kind, obj_name = kind_match.group(1), name_match.group(1)
        uid_by_kind = {
          'Namespace': '77777777-7777-4777-8777-777777777777',
          'CiliumBGPPeerConfig': '66666666-6666-4666-8666-666666666666',
          'CiliumBGPAdvertisement': '55555555-5555-4555-8555-555555555555',
          'CiliumBGPClusterConfig': '33333333-3333-4333-8333-333333333333' if obj_name.endswith('-rack1') else '44444444-4444-4444-8444-444444444444',
          'Deployment': '11111111-1111-4111-8111-111111111111' if obj_name.endswith('-server') else '22222222-2222-4222-8222-222222222222',
        }
        if kind not in uid_by_kind: raise SystemExit(50)
        output({'apiVersion': api_version.group(1), 'kind': kind, 'metadata': {
          'name': obj_name, 'namespace': namespace_match.group(1) if namespace_match else '',
          'uid': uid_by_kind[kind], 'labels': {
            'p010-student-owner': '11111111111141118111111111111111',
            'p010-student-run': run_id,
          }
        }})
    elif op == 'get':
        resource = tail[0] if tail else ''
        obj_name = tail[1] if len(tail) > 1 and not tail[1].startswith('-') else ''
        if resource == 'nodes' and any(part.startswith('jsonpath=') for part in tail):
            print('p010-hibrido-control-plane True\\np010-hibrido-worker True\\np010-hibrido-worker2 True')
        elif resource == 'namespace' and obj_name == 'kube-system': print('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')
        elif resource == 'ciliumnodes':
            output({'apiVersion':'cilium.io/v2','kind':'CiliumNodeList','items':[
              {'metadata':{'name':'p010-hibrido-worker'},'spec':{'ipam':{'podCIDRs':['10.246.1.0/24']}}},
              {'metadata':{'name':'p010-hibrido-worker2'},'spec':{'ipam':{'podCIDRs':['10.246.2.0/24']}}}]})
        elif resource == 'pod':
            is_server = obj_name == 'server-pod'
            pod_uid = '99999999-9999-4999-8999-999999999999' if is_server else '88888888-8888-4888-8888-888888888888'
            deploy = 'p010-hyb-0123456789ab-server' if is_server else 'p010-hyb-0123456789ab-client'
            rs_name = deploy + ('-0987654321' if is_server else '-1234567890')
            rs_uid = '66666666-6666-4666-8666-666666666666' if is_server else '55555555-5555-4555-8555-555555555555'
            node = 'p010-hibrido-worker2' if is_server else 'p010-hibrido-worker'
            ip = '10.246.2.10' if is_server else '10.246.1.10'
            container_name = 'agnhost' if is_server else 'netshoot'
            container_id = 'b' * 64 if is_server else 'a' * 64
            app = 'p010-hyb-server' if is_server else 'p010-hyb-client'
            output({'apiVersion':'v1','kind':'Pod','metadata':{'name':obj_name,'namespace':'p010-hyb-0123456789ab','uid':pod_uid,'labels':{'p010-student-owner':'11111111111141118111111111111111','p010-student-run':run_id,'app':app},'ownerReferences':[{'apiVersion':'apps/v1','kind':'ReplicaSet','name':rs_name,'uid':rs_uid,'controller':True,'blockOwnerDeletion':True}]},'spec':{'nodeName':node},'status':{'phase':'Running','podIP':ip,'conditions':[{'type':'Ready','status':'True'}],'containerStatuses':[{'name':container_name,'containerID':'containerd://'+container_id,'imageID':'sha256:'+'c'*64,'ready':True,'restartCount':0,'state':{'running':{'startedAt':'2026-10-30T00:00:00Z'}}}]}})
        elif resource == 'pods':
            selector = after('--selector')
            app = 'p010-hyb-server' if 'app=p010-hyb-server' in selector else 'p010-hyb-client'
            is_server = app.endswith('server')
            pod_name = 'server-pod' if is_server else 'client-pod'
            pod_uid = '99999999-9999-4999-8999-999999999999' if is_server else '88888888-8888-4888-8888-888888888888'
            deploy = 'p010-hyb-0123456789ab-server' if is_server else 'p010-hyb-0123456789ab-client'
            rs_name = deploy + ('-0987654321' if is_server else '-1234567890')
            rs_uid = '66666666-6666-4666-8666-666666666666' if is_server else '55555555-5555-4555-8555-555555555555'
            node = 'p010-hibrido-worker2' if is_server else 'p010-hibrido-worker'
            ip = '10.246.2.10' if is_server else '10.246.1.10'
            container_name = 'agnhost' if is_server else 'netshoot'
            container_id = 'b' * 64 if is_server else 'a' * 64
            output({'apiVersion':'v1','kind':'List','metadata':{'resourceVersion':'1'},'items':[{'apiVersion':'v1','kind':'Pod','metadata':{'name':pod_name,'namespace':'p010-hyb-0123456789ab','uid':pod_uid,'labels':{'p010-student-owner':'11111111111141118111111111111111','p010-student-run':run_id,'app':app},'ownerReferences':[{'apiVersion':'apps/v1','kind':'ReplicaSet','name':rs_name,'uid':rs_uid,'controller':True,'blockOwnerDeletion':True}]},'spec':{'nodeName':node},'status':{'phase':'Running','podIP':ip,'conditions':[{'type':'Ready','status':'True'}],'containerStatuses':[{'name':container_name,'containerID':'containerd://'+container_id,'imageID':'sha256:'+'c'*64,'ready':True,'restartCount':0,'state':{'running':{'startedAt':'2026-10-30T00:00:00Z'}}}]}}]})
        elif resource in ('replicaset','replicasets'):
            rs_name = obj_name
            is_server = rs_name.endswith('-server-0987654321')
            deploy_name = 'p010-hyb-0123456789ab-server' if is_server else 'p010-hyb-0123456789ab-client'
            rs_uid = '66666666-6666-4666-8666-666666666666' if is_server else '55555555-5555-4555-8555-555555555555'
            deploy_uid = '11111111-1111-4111-8111-111111111111' if is_server else '22222222-2222-4222-8222-222222222222'
            app = 'p010-hyb-server' if is_server else 'p010-hyb-client'
            output({'apiVersion':'apps/v1','kind':'ReplicaSet','metadata':{'name':rs_name,'namespace':'p010-hyb-0123456789ab','uid':rs_uid,'labels':{'p010-student-owner':'11111111111141118111111111111111','p010-student-run':run_id,'app':app},'ownerReferences':[{'apiVersion':'apps/v1','kind':'Deployment','name':deploy_name,'uid':deploy_uid,'controller':True,'blockOwnerDeletion':True}]}})
        elif resource in ('deployments','namespaces','ciliumbgpclusterconfigs','ciliumbgpadvertisements','ciliumbgppeerconfigs'):
            deleted = set(deleted_file.read_text(encoding='utf-8').splitlines()) if deleted_file.exists() else set()
            if obj_name in deleted and '--ignore-not-found=true' in args: raise SystemExit(0)
            output(object_for(resource, obj_name))
        else:
            raise SystemExit(44)
    elif op == 'rollout' or op == 'wait':
        print('condition satisfied')
    elif op == 'exec':
        if mode == 'traffic': raise SystemExit(37)
        if '--container' in args and 'netshoot' in args:
            if 'pod/client-pod' not in args or '-ec' not in args or 'nc -vz -w 4' not in args[-1]: raise SystemExit(68)
            append_wave(1)
        print('probe succeeded')
    elif op == 'delete':
        raw = next((part.split('=',1)[1] for part in tail if part.startswith('--raw=')), '')
        filename = after('--filename')
        options = json.loads(Path(filename).read_text(encoding='utf-8'))
        emit('k8s-delete', path=raw, uid=options.get('preconditions',{}).get('uid',''))
        name_part = raw.rsplit('/',1)[-1]
        with deleted_file.open('a',encoding='utf-8') as stream: stream.write(name_part+'\\n')
        print('{}')
    raise SystemExit(0)
if name == 'cilium':
    op = 'bgp' if 'bgp' in args else 'status'
    emit('cilium', operation=op)
    if op == 'bgp':
        if mode == 'bgp': print('10.30.1.1 Established\\n10.30.2.1 Idle')
        else: print('10.30.1.1 Established\\n10.30.2.1 Established\\n10.30.3.1 Established')
    else: print('Cilium status OK')
    raise SystemExit(0)
if name == 'docker':
    command = ' '.join(args)
    if 'inspect' in args and '--format={{.State.Pid}}' in args:
        worker_id = args[-1]
        print('811' if int(worker_id, 16) == 32 else '822')
        raise SystemExit(0)
    if 'exec' in args:
        exec_args = args[args.index('exec') + 1:]
        worker_id = exec_args[0]
        if '/usr/sbin/ip' in exec_args and 'route' in exec_args and 'get' in exec_args:
            target_ip = exec_args[-1]
            dev = 'eth1' if int(worker_id, 16) == 32 else 'eth1'
            emit('worker-route', worker=worker_id, target=target_ip, dev=dev)
            output([{'dst':target_ip,'dev':dev,'gateway':'10.30.0.1','prefsrc':'10.30.1.2' if int(worker_id, 16) == 32 else '10.30.2.2'}])
            raise SystemExit(0)
        if '/usr/sbin/ip' in exec_args and 'link' in exec_args and 'show' in exec_args:
            dev = exec_args[-1]
            emit('worker-link', worker=worker_id, dev=dev)
            print('3: ' + dev + ': <BROADCAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP mode DEFAULT group default qlen 1000 link/ether 02:bb:cc:dd:ee:01 brd ff:ff:ff:ff:ff:ff')
            raise SystemExit(0)
        if 'vtysh' in exec_args:
            emit('docker', operation='border-rib', container=worker_id)
            print('*> 198.18.49.0/24 198.18.48.3\\n*> 10.246.1.0/24 10.30.1.1\\n*> 10.246.2.0/24 10.30.2.1')
            raise SystemExit(0)
        if 'sr_cli' in exec_args:
            prefix = exec_args[-1].split()[-1]
            emit('docker', operation='leaf-route', container=worker_id, prefix=prefix)
            print(f'{prefix} [BGP/170] via 10.30.0.1')
            raise SystemExit(0)
        is_server = int(worker_id, 16) == 33
        key = 'cirros_to_pod' if is_server else 'pod_to_cirros'
        pod_uid = '99999999-9999-4999-8999-999999999999' if is_server else '88888888-8888-4888-8888-888888888888'
        pod_name = 'server-pod' if is_server else 'client-pod'
        container_name = 'agnhost' if is_server else 'netshoot'
        container_id = 'b' * 64 if is_server else 'a' * 64
        sandbox_id = 'd' * 64 if is_server else 'e' * 64
        if '/bin/sh' in exec_args and '-s' in exec_args:
            emit('cri-discovery', worker=key)
            script = sys.stdin.read()
            worker_pid = 822 if is_server else 811
            worker_root = PROC_ROOT / str(worker_pid) / 'root/proc'
            kubelet_pid = 102 if is_server else 101
            kubelet = worker_root / str(kubelet_pid)
            kubelet.mkdir(mode=0o700, parents=True, exist_ok=True)
            config_path = trace.parent / f'kubelet-{worker_pid}.yaml'
            config_path.write_text('containerRuntimeEndpoint: unix:///run/containerd/containerd.sock\\n', encoding='ascii')
            if mode == 'discovery-endpoint-duplicate':
                kubelet_args = ['kubelet', '--container-runtime-endpoint=unix:///run/containerd/containerd.sock', '--container-runtime-endpoint', 'unix:///run/containerd/containerd.sock']
            elif mode == 'discovery-config-duplicate':
                kubelet_args = ['kubelet', '--container-runtime-endpoint=unix:///run/containerd/containerd.sock', '--config', str(config_path), '--config=' + str(config_path)]
            elif mode == 'discovery-config':
                kubelet_args = ['kubelet', '--config', str(config_path)]
            else:
                kubelet_args = ['kubelet', '--container-runtime-endpoint=unix:///run/containerd/containerd.sock']
            (kubelet / 'cmdline').write_bytes(b'\\0'.join(part.encode() for part in kubelet_args) + b'\\0')
            stat_fields = ['S'] + [str(value) for value in range(4, 23)]
            stat_fields[-1] = '123456'
            (kubelet / 'stat').write_text(f'{kubelet_pid} (kubelet fixture) ' + ' '.join(stat_fields) + '\\n', encoding='ascii')
            boot = worker_root / 'sys/kernel/random/boot_id'
            boot.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            boot.write_text('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\\n', encoding='ascii')
            script = script.replace('/proc', str(worker_root))
            child_env = os.environ.copy()
            child_env['PATH'] = str(Path(sys.argv[0]).resolve().parent) + os.pathsep + child_env.get('PATH', '')
            result = subprocess.run(['/bin/sh', '-se'], input=script, text=True, env=child_env, capture_output=True, check=False)
            sys.stdout.write(result.stdout)
            sys.stderr.write(result.stderr)
            emit('cri-discovery-script', worker=key, rc=result.returncode)
            raise SystemExit(result.returncode)
        crictl_index = next((index for index, part in enumerate(exec_args) if part.endswith('/crictl')), -1)
        if crictl_index < 0:
            raise SystemExit(47)
        crictl_args = exec_args[crictl_index + 1:]
        if crictl_args == ['--version']:
            print('crictl version v1.33.0')
        elif crictl_args[-1:] == ['version']:
            print('Version:  0.1.0\\nRuntimeName:  containerd\\nRuntimeVersion:  2.1.4\\nRuntimeApiVersion:  v1')
        elif crictl_args[-3:] == ['ps', '-o', 'json']:
            attempt = 2
            if mode == 'capture-container-attempt' and trace_has_wave(1): attempt += 1
            output({'containers':[{'id':container_id,'podSandboxId':sandbox_id,'state':'CONTAINER_RUNNING','metadata':{'name':container_name,'attempt':attempt},'labels':{'io.kubernetes.pod.uid':pod_uid,'io.kubernetes.pod.name':pod_name,'io.kubernetes.pod.namespace':NAMESPACE,'io.kubernetes.container.name':container_name}}]})
        elif crictl_args[-4:-1] == ['inspectp', '-o', 'json']:
            attempt = 3
            if mode == 'capture-sandbox-attempt' and trace_has_wave(1): attempt += 1
            sandbox_metadata = {'uid':pod_uid,'name':pod_name,'namespace':NAMESPACE}
            if not (mode == 'capture-sandbox-attempt-missing' and trace_has_wave(1)):
                sandbox_metadata['attempt'] = attempt
            output({'status':{'id':sandbox_id,'metadata':sandbox_metadata,'state':'SANDBOX_READY','network':{'ip':POD_SERVER if is_server else POD_CLIENT},'linux':{'namespaces':{'options':{'network':'POD'}}},'runtimeHandler':'runc'},'info':{'pid':5111 if is_server else 5222,'processStatus':'running','netNamespaceClosed':False,'runtimeType':'io.containerd.runc.v2'}})
        else:
            emit('cri-command-unknown', argv=crictl_args)
            raise SystemExit(48)
        emit('cri', worker=key, operation=crictl_args[-1])
        raise SystemExit(0)
    if 'show ip bgp' in command:
        kind = 'border-rib'
        value = '*> 198.18.49.0/24 198.18.48.3\\n*> 10.246.1.0/24 10.30.1.1\\n*> 10.246.2.0/24 10.30.2.1'
    elif 'sr_cli' in command:
        kind = 'leaf-route'
        prefix = args[-1].split()[-1]
        value = f'{prefix} [BGP/170] via 10.30.0.1'
    elif 'show ip route' in command:
        kind = 'border-fib'
        prefix = args[-1].split()[-1]
        value = f'{prefix} via 198.18.48.3' if prefix == '198.18.49.0/24' else f'{prefix} via 10.30.1.1'
    elif 'inspect' in command:
        kind = 'inspect'
        value = f'{args[-1]}|3444'
    else:
        raise SystemExit(45)
    emit('docker', operation=kind)
    if mode == 'route' and kind in ('border-rib','leaf-route','border-fib'): raise SystemExit(38)
    print(value)
    raise SystemExit(0)
raise SystemExit(46)
""".replace("__PYTHON__", sys.executable),
        encoding="utf-8",
    )
    script.chmod(0o700)
    for name in ("events", "kubectl", "cilium", "docker", "crictl", "nsenter", "stat", "setpriv", "ssh-keygen", "ssh", "tcpdump", "cat", "kill", "test", "sha256sum", "ip", "id"):
        if name == "crictl":
            shutil.copy2(script, bin_dir / name)
        else:
            (bin_dir / name).symlink_to(script.name)
    fake_sudo = bin_dir / "fake-sudo"
    shutil.copy2(Path(__file__).with_name("fake-sudo.sh"), fake_sudo)
    fake_sudo.chmod(0o700)
    (bin_dir / "sudo").symlink_to(fake_sudo.name)


API_RUNNER = """---
- name: Prove the parent has not loaded an API token before guest dispatch
  ansible.builtin.assert:
    that: student_hybrid_api_token is not defined
    fail_msg: the API token must remain inside the guest child process
- name: Record the simulated child API operation
  ansible.builtin.command:
    argv: ["{{ student_hybrid_m20_event_bin }}", api, "{{ student_hybrid_api_mode }}"]
  changed_when: false
  no_log: true
- name: Fail only the selected external API response
  ansible.builtin.fail:
    msg: simulated API verification failure
  when:
    - student_hybrid_api_mode == 'verify'
    - lookup('env', 'P010_M20_MODE') == 'api'
- name: Compute the API inventory after removing the saved routing objects
  ansible.builtin.set_fact:
    student_hybrid_m20_api_resources: "{{ student_state.hybrid.m11.api.resources | dict2items | rejectattr('key', 'in', ['bgp_peer', 'bgp_speaker']) | items2dict }}"
    student_hybrid_m20_api_links: "{{ student_state.hybrid.m11.api.links | dict2items | rejectattr('key', 'equalto', 'drinstance') | items2dict }}"
  when: student_hybrid_api_mode == 'remove-routing'
  no_log: true
- name: Compute empty maps after the final resource-removal phase
  ansible.builtin.set_fact:
    student_hybrid_m20_api_resources: {}
    student_hybrid_m20_api_links: {}
  when: student_hybrid_api_mode == 'remove-resources'
  no_log: true
- name: Replace the API identity maps in the simulated cleanup result
  ansible.builtin.set_fact:
    student_state: >-
      {{ student_state | combine({'hybrid': student_state.hybrid | combine({
        'm11': student_state.hybrid.m11 | combine({'api': student_state.hybrid.m11.api | combine({
          'resources': student_hybrid_m20_api_resources,
          'links': student_hybrid_m20_api_links,
          'pending': {}
        }, recursive=false)}, recursive=false)
      }, recursive=false)}, recursive=false) }}
  when: student_hybrid_api_mode in ['remove-routing', 'remove-resources']
  no_log: true
- name: Persist only the simulated API cleanup identities
  ansible.builtin.copy:
    dest: "{{ student_state_file }}"
    content: "{{ student_state | to_nice_json }}\\n"
    owner: "{{ student_uid }}"
    mode: '0600'
  when: student_hybrid_api_mode in ['remove-routing', 'remove-resources']
  no_log: true
"""

QMP_SHIM = """---
- name: Record the QMP boundary reached by the real caller
  ansible.builtin.command:
    argv: ["{{ student_hybrid_m20_event_bin }}", qmp, "{{ student_hybrid_qmp_action }}", "{{ student_hybrid_qmp_guest_name }}"]
  changed_when: false
  no_log: true
- name: Fail only the selected guest identity probe
  ansible.builtin.fail:
    msg: simulated guest identity failure
  when:
    - student_hybrid_qmp_action == 'verify'
    - student_hybrid_qmp_guest_name == 'ubuntu'
    - lookup('env', 'P010_M20_MODE') == 'guest'
"""

BORDER_SHIM = """---
- name: Record the border namespace identity boundary reached by the caller
  ansible.builtin.command:
    argv: ["{{ student_hybrid_m20_event_bin }}", border, inspect]
  changed_when: false
  no_log: true
"""


def configure_shadow(student_lab: Path, scratch: Path, bin_dir: Path) -> Path:
    shadow = scratch / "shadow"
    shutil.copytree(student_lab / "tasks", shadow / "tasks")
    verify_api = (student_lab / "tasks/hybrid-m11-verify.yml").read_text(encoding="utf-8")
    c1_map_task = "- name: Build a sanitized C1 identity map from the exact Neutron router-port GETs"
    c1_save_task = "- name: Persist the API-confirmed binding gate only after the OVS port is live"
    c1_map_start = verify_api.index(c1_map_task)
    c1_map_end = verify_api.index(c1_save_task, c1_map_start)
    (shadow / "tasks/hybrid-m11-c1-api-map.yml").write_text(verify_api[c1_map_start:c1_map_end].rstrip() + "\n", encoding="utf-8")
    api_map_runner = """- name: Return fixture router and port responses at the external Neutron API boundary
  ansible.builtin.set_fact:
    student_hybrid_api_verify_objects:
      'router:primary':
        id: "{{ student_state.hybrid.m11.api.resources.router.primary.id }}"
        tenant_id: "{{ student_state.hybrid.m11.api.project_id }}"
        external_gateway_info:
          enable_snat: false
          network_id: "{{ student_state.hybrid.m11.api.resources.external_network.primary.id }}"
          external_fixed_ips:
            - subnet_id: "{{ student_state.hybrid.m11.api.resources.external_subnet.primary.id }}"
              ip_address: "{{ student_state.hybrid.m11.network.provider_router_ip }}"
      'router_interface:primary':
        id: "{{ student_state.hybrid.m11.api.resources.router_interface.primary.id }}"
        tenant_id: "{{ student_state.hybrid.m11.api.project_id }}"
        network_id: "{{ student_state.hybrid.m11.api.resources.tenant_network.primary.id }}"
        device_id: "{{ student_state.hybrid.m11.api.resources.router.primary.id }}"
        device_owner: network:router_interface
        mac_address: fa:16:3e:49:00:01
        fixed_ips:
          - subnet_id: "{{ student_state.hybrid.m11.api.resources.tenant_subnet.primary.id }}"
            ip_address: "{{ student_state.hybrid.m11.network.tenant_gateway }}"
      'router_gateway_port:primary':
        id: "{{ student_state.hybrid.m11.api.resources.router_gateway_port.primary.id }}"
        tenant_id: ''
        network_id: "{{ student_state.hybrid.m11.api.resources.external_network.primary.id }}"
        device_id: "{{ student_state.hybrid.m11.api.resources.router.primary.id }}"
        device_owner: network:router_gateway
        mac_address: fa:16:3e:48:00:03
        fixed_ips:
          - subnet_id: "{{ student_state.hybrid.m11.api.resources.external_subnet.primary.id }}"
            ip_address: "{{ student_state.hybrid.m11.network.provider_router_ip }}"
  when: student_hybrid_api_mode == 'verify'
  no_log: true
- name: Run the product C1 Neutron map builder and its relationship assertions
  ansible.builtin.include_tasks: hybrid-m11-c1-api-map.yml
  when: student_hybrid_api_mode == 'verify'
  no_log: true
- name: Persist the exact API fixture through the product API checkpoint writer
  ansible.builtin.include_tasks: hybrid-m11-api-save.yml
  vars:
    student_hybrid_api_state_patch:
      hybrid:
        phase: partial
        m11:
          phase: api-ready
          verification:
            phase: api-ready
            gates:
              c1_api_paths: "{{ student_hybrid_api_c1_paths }}"
  when: student_hybrid_api_mode == 'verify'
  no_log: true
"""
    api_runner = API_RUNNER.replace("- name: Compute the API inventory after removing the saved routing objects\n", api_map_runner + "- name: Compute the API inventory after removing the saved routing objects\n")
    (shadow / "tasks/hybrid-m11-run-api.yml").write_text(api_runner, encoding="utf-8")
    (shadow / "tasks/hybrid-qmp-command.yml").write_text(QMP_SHIM, encoding="utf-8")
    (shadow / "tasks/hybrid-validate-border.yml").write_text(BORDER_SHIM, encoding="utf-8")
    ssh_task = shadow / "tasks/hybrid-m11-ssh.yml"
    ssh_task.write_text(
        ssh_task.read_text(encoding="utf-8").replace("/usr/bin/setpriv", str(bin_dir / "setpriv")),
        encoding="utf-8",
    )
    positive_task = shadow / "tasks/hybrid-m11-positive-verify.yml"
    capture_task = shadow / "tasks/hybrid-m11-build-stop-origin-script.yml"
    fake_proc = scratch / "fake-proc"
    for worker_pid, sandbox_pid, worker_start, sandbox_start in ((811, 5222, 123456, 654321), (822, 5111, 123457, 654322)):
        worker = fake_proc / str(worker_pid)
        worker_root = worker / "root/proc"
        for relative in ("ns/pid", "root/proc/1/ns/pid"):
            path = worker / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("pid namespace fixture\n", encoding="ascii")
        worker_stat = worker / "stat"
        worker_stat.write_text(proc_stat_line(worker_pid, "kubelet worker (test)", worker_start), encoding="ascii")
        sandbox = worker_root / str(sandbox_pid)
        (sandbox / "ns").mkdir(parents=True, exist_ok=True)
        (sandbox / "ns/net").write_text("net namespace fixture\n", encoding="ascii")
        (sandbox / "stat").write_text(proc_stat_line(sandbox_pid, "pause (sandbox test)", sandbox_start), encoding="ascii")
        (sandbox / "status").write_text("Name:\tpause\nUid:\t0\t0\t0\t0\n", encoding="ascii")
        boot_id = worker_root / "sys/kernel/random/boot_id"
        boot_id.parent.mkdir(parents=True, exist_ok=True)
        boot_id.write_text("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\n", encoding="ascii")
    positive_task.write_text(
        positive_task.read_text(encoding="utf-8").replace("retries: 60", "retries: 1").replace("delay: 5", "delay: 0").replace("/usr/bin/docker", str(bin_dir / "docker")).replace("/usr/bin/nsenter", str(bin_dir / "nsenter")).replace("/usr/bin/stat", str(bin_dir / "stat")).replace("proc_root=/proc", f"proc_root={fake_proc}").replace("'/tmp/p010-'", repr(str(scratch / "guest-p010-"))),
        encoding="utf-8",
    )
    capture_text = capture_task.read_text(encoding="utf-8")
    capture_text = capture_text.replace("proc_root=/proc", f"proc_root={fake_proc}")
    for source, target in (
        ("/usr/sbin/tcpdump", str(bin_dir / "tcpdump")),
        ("/usr/bin/stat", str(bin_dir / "stat")),
        ("/usr/bin/cat", str(bin_dir / "cat")),
        ("/usr/bin/kill", str(bin_dir / "kill")),
        ("/usr/bin/test", str(bin_dir / "test")),
        ("/usr/bin/nsenter", str(bin_dir / "nsenter")),
        ("/usr/bin/sudo", str(bin_dir / "sudo")),
        ("/usr/sbin/ip", str(bin_dir / "ip")),
        ("/usr/bin/bash", "/bin/bash"),
    ):
        capture_text = capture_text.replace(source, target)
    capture_task.write_text(capture_text, encoding="utf-8")
    positive_text = positive_task.read_text(encoding="utf-8")
    pod_identity_task = "- name: Verify each worker PID namespace bridge and inspect the sandbox process and Pod links"
    pod_identity_start = positive_text.index(pod_identity_task)
    pod_identity_end = positive_text.index("\n- name:", pod_identity_start + len(pod_identity_task))
    pod_identity_block = positive_text[pod_identity_start:pod_identity_end].replace("  no_log: true", "  no_log: false")
    positive_task.write_text(positive_text[:pod_identity_start] + pod_identity_block + positive_text[pod_identity_end:], encoding="utf-8")
    verify_task = shadow / "tasks/verify.yml"
    verify_text = verify_task.read_text(encoding="utf-8")
    async_block = "  async: 300\n  poll: 10\n"
    if verify_text.count(async_block) != 1:
        raise AssertionError("verify.yml async call site changed; test boundary must be reviewed")
    verify_task.write_text(verify_text.replace(async_block, ""), encoding="utf-8")
    return shadow / "tasks"


def fixture_state_file(root: Path, state: dict) -> Path:
    path = root / "state.json"
    write_json(path, state)
    return path


def write_vars(root: Path, state: dict, state_file: Path, run_dir: Path, bin_dir: Path, uid: int, extra: dict | None = None) -> Path:
    values = {
        "student_state": state,
        "student_state_file": str(state_file),
        "student_run_dir": str(run_dir),
        "student_repo_root": str(Path(__file__).resolve().parents[4]),
        "student_uid": uid,
        "student_profile_name": "hibrido",
        "student_profile": "{{ student_profiles['hibrido'] }}",
        "student_effective_exercise": "baseline",
        "student_exercise_config": "{{ student_exercises['baseline'] }}",
        "student_tool_dir": str(bin_dir),
        "student_has_state": True,
        "student_hybrid_m11_positive_existing": True,
        "student_hybrid_m11_positive_complete_status": "up",
        "student_hybrid_m11_verify_existing": True,
        "student_hybrid_nsenter_bin": str(bin_dir / "nsenter"),
        "student_hybrid_ssh_bin": str(bin_dir / "ssh"),
        "student_hybrid_ssh_keygen_bin": str(bin_dir / "ssh-keygen"),
        "student_hybrid_m20_event_bin": str(bin_dir / "events"),
        "ansible_become_exe": str(bin_dir / "fake-sudo"),
        "ansible_user_gid": os.getgid(),
    }
    if extra:
        values.update(extra)
    path = root / "vars.json"
    write_json(path, values)
    return path


def write_playbook(root: Path, student_lab: Path, vars_file: Path, task_path: Path, task_name: str, extra_asserts: str = "") -> Path:
    path = root / "playbook.yml"
    path.write_text(
        "---\n"
        f"- name: {task_name}\n"
        "  hosts: localhost\n"
        "  connection: local\n"
        "  gather_facts: true\n"
        "  vars_files:\n"
        f"    - {json.dumps(str(student_lab / 'vars.yml'))}\n"
        f"    - {json.dumps(str(vars_file))}\n"
        "  tasks:\n"
        f"    - ansible.builtin.include_tasks: {json.dumps(str(task_path))}\n"
        + extra_asserts,
        encoding="utf-8",
    )
    return path


class Runner:
    def __init__(self, ansible_playbook: Path, student_lab: Path, scratch: Path, bin_dir: Path):
        self.ansible_playbook = ansible_playbook
        self.student_lab = student_lab
        self.scratch = scratch
        self.bin_dir = bin_dir
        self.attempts = []

    def run(self, name: str, playbook: Path, env_extra: dict[str, str], expected: int = 0) -> None:
        log_path = self.scratch / f"{name}.log"
        vars_file = None
        in_vars_files = False
        vars_file_count = 0
        for line in playbook.read_text(encoding="utf-8").splitlines():
            if line.strip() == "vars_files:":
                in_vars_files = True
                continue
            if in_vars_files and line.startswith("  tasks:"):
                break
            if in_vars_files and line.lstrip().startswith("- "):
                vars_file_count += 1
                if vars_file_count == 2:
                    vars_file = Path(json.loads(line.strip()[2:]))
                    break
        if vars_file is None:
            raise AssertionError(f"could not locate the case vars file in {playbook}")
        case_vars = json.loads(vars_file.read_text(encoding="utf-8"))
        state_file = Path(case_vars["student_state_file"])
        proc_root = self.scratch / "fake-proc"
        identity_root = self.scratch / "fixture-identities"
        env = os.environ.copy()
        env.update(
            {
                "ANSIBLE_CONFIG": str(self.student_lab / "ansible.cfg"),
                "ANSIBLE_LOCAL_TEMP": str(self.scratch / "ansible-local"),
                "ANSIBLE_NOCOLOR": "1",
                "PYTHONDONTWRITEBYTECODE": "1",
                "P010_M20_TRACE": str(self.scratch / f"{name}.trace.jsonl"),
                "P010_M20_DELETED": str(self.scratch / f"{name}.deleted"),
                "P010_M20_STATE_FILE": str(state_file),
                "P010_M20_PROC_ROOT": str(proc_root),
                "P010_M20_FIXTURE_IDENTITIES": str(identity_root),
                "P010_C1_FAILURE_ROOT": str(self.scratch / "focused" / "failures"),
                "P010_M20_MODE": env_extra.pop("P010_M20_MODE", "positive"),
                "P010_M20_RUN_ID": RUN_ID,
                "P010_M20_UID": str(os.getuid()),
            }
        )
        env.update(env_extra)
        argv = [str(self.ansible_playbook), "-i", "localhost,", str(playbook)]
        started_utc = datetime.now(timezone.utc).isoformat(timespec="microseconds")
        with log_path.open("w", encoding="utf-8") as log_stream:
            result = subprocess.run(argv, env=env, stdout=log_stream, stderr=subprocess.STDOUT, check=False)
        finished_utc = datetime.now(timezone.utc).isoformat(timespec="microseconds")
        record = {
            "name": name,
            "started_utc": started_utc,
            "finished_utc": finished_utc,
            "argv": argv,
            "cwd": str(Path.cwd()),
            "rc": result.returncode,
            "log": str(log_path),
            "log_sha256": hashlib.sha256(log_path.read_bytes()).hexdigest(),
            "trace": env["P010_M20_TRACE"],
        }
        self.attempts.append(record)
        self.write_receipt()
        if result.returncode != expected:
            raise AssertionError(f"{name} rc={result.returncode}, esperado={expected}; log={log_path}")

    def write_receipt(self) -> None:
        write_json(self.scratch / "attempts.json", self.attempts)


def set_up_case(case_root: Path, base_state: dict, student_lab: Path, tasks: Path, bin_dir: Path, extra: dict | None = None) -> tuple[Path, Path, Path]:
    run_dir = case_root / "private-run"
    run_dir.mkdir(mode=0o700, parents=True)
    state = json.loads(json.dumps(base_state))
    gates = state["hybrid"]["m11"]["verification"]["gates"]
    historical_c1 = gates["positive"].get("c1")
    if historical_c1 is not None:
        source_receipt_path = Path(historical_c1["receipt"]["path"])
        source_receipt_bytes = source_receipt_path.read_bytes()
        source_receipt = json.loads(source_receipt_bytes)
        source_receipt_sha256 = hashlib.sha256(source_receipt_bytes).hexdigest()
        if (
            historical_c1["phase"] != "verified"
            or source_receipt_sha256 != historical_c1["receipt"]["sha256"]
            or source_receipt.get("check_id") != historical_c1["check_id"]
            or source_receipt.get("run_id") != state["run_id"]
        ):
            raise AssertionError("the prior C1 receipt is not an intact producer output")
        (run_dir / "m11-k8s").mkdir(mode=0o700)
        receipt_dir = run_dir / "m11-evidence" / historical_c1["check_id"]
        receipt_dir.mkdir(mode=0o700, parents=True)
        receipt_path = receipt_dir / "receipt.json"
        receipt_path.write_bytes(source_receipt_bytes)
        receipt_path.chmod(0o600)
        receipt_stat = receipt_path.stat()
    gates["c1_capture_active"] = {"schema": 1, "check_id": "", "phase": "absent", "observers": []}
    gates["ovs_attach"] = {
        "phase": "attached", "bridge_name": "br-int", "interface_name": "tenant0",
        "bridge_uuid": "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa", "port_uuid": "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb",
        "interface_uuid": "cccccccc-3333-4333-8333-cccccccccccc", "ifindex": 8, "ofport": 6,
        "neutron_port_id": IDS["cirros_port"], "guest_uuid": "10112233-4455-4677-8899-aabbccddeeff",
        "attached_mac": "02:00:00:00:00:22", "guest_interface_mac": "52:54:00:10:11:03"
    }
    c0_timestamp = "2026-10-30T12:00:00Z"
    c0_completed = "2026-10-30T12:00:01Z"
    c0_raw_headers = (
        "listening on tenant0, link-type EN10MB (Ethernet), snapshot length 262144 bytes\n"
        "6 packets captured\n8 packets received by filter\n0 packets dropped by kernel\n"
    )
    c0_sha256 = hashlib.sha256(c0_raw_headers.encode("utf-8")).hexdigest()
    cirros_port = state["hybrid"]["m11"]["api"]["resources"]["cirros_port"]["primary"]
    security_group_id = state["hybrid"]["m11"]["api"]["resources"]["security_group"]["primary"]["id"]
    c0_rule_ids = sorted(
        entry["id"]
        for entry in state["hybrid"]["m11"]["api"]["resources"]["security_group_rules"].values()
    )
    c0_rules = [
        {"id": c0_rule_ids[0], "direction": "ingress", "protocol": "icmp", "remote_ip_prefix": "10.30.0.0/16"},
        {"id": c0_rule_ids[1], "direction": "ingress", "protocol": "tcp", "port_range_min": 8080, "port_range_max": 8080, "remote_ip_prefix": "10.30.0.0/16"},
        {"id": c0_rule_ids[2], "direction": "egress", "protocol": "icmp", "remote_ip_prefix": "10.30.0.0/16"},
        {"id": c0_rule_ids[3], "direction": "egress", "protocol": "tcp", "port_range_min": 8080, "port_range_max": 8080, "remote_ip_prefix": "10.30.0.0/16"},
    ]
    dhcp_server = {
        "id": IDS["bgp_speaker"], "ip_address": "198.18.49.2",
        "mac_address": "fa:16:3e:49:00:02", "subnet_id": IDS["tenant_subnet"],
    }
    gates["dhcp_server"] = dhcp_server
    c0_binding_observation = {
        "schema": 1, "observed_utc": c0_timestamp, "run_id": state["run_id"],
        "port": {
            "id": cirros_port["id"], "mac_address": cirros_port["mac_address"],
            "fixed_ips": cirros_port["fixed_ips"], "security_groups": [security_group_id],
            "port_security_enabled": True, "allowed_address_pairs": [],
            "binding_host_id": "p010-hibrido-ovs-host", "binding_vnic_type": "normal",
            "binding_vif_type": "ovs", "binding_vif_details": {"port_filter": True},
            "device_id": state["hybrid"]["guests"]["cirros"]["uuid"], "device_owner": "",
        },
        "dhcp_server": dhcp_server,
        "security_group": {"id": security_group_id, "rule_ids": c0_rule_ids, "rules": c0_rules},
        "ovs": {"attachment": gates["ovs_attach"]},
    }
    gates["c0_binding_observation"] = c0_binding_observation
    binding_path = run_dir / "m11-evidence" / "c0-binding.json"
    write_json(binding_path, {
        "schema": 1,
        "scope": "C0 Neutron port binding, security-group rules, and OVS attachment",
        "run_id": state["run_id"],
        "observation": c0_binding_observation,
    })
    binding_stat = binding_path.stat()
    gates["c0_binding_evidence"] = {
        "path": str(binding_path), "sha256": hashlib.sha256(binding_path.read_bytes()).hexdigest(),
        "device": binding_stat.st_dev, "inode": binding_stat.st_ino,
        "owner_uid": os.getuid(), "mode": "0600",
        "scope": "C0 Neutron port binding, security-group rules, and OVS attachment",
    }
    capture_identity = {
        "file_device": 1, "file_inode": 30001, "file_owner_uid": os.getuid(),
        "result_device": 1, "result_inode": 30002, "result_owner_uid": os.getuid(),
        "capture_rc": 130, "started_utc": c0_timestamp,
        "completed_utc": c0_completed, "stop_requested": True,
    }
    c0_dora_observation = {
        "schema": 1, "scope": "C0 initial DHCP DORA on tenant0; no C1-C8 path claim",
        "run_id": state["run_id"],
        "command": {
            "argv": ["sudo", "-n", "/usr/bin/timeout", "120", "/usr/sbin/tcpdump", "-n", "-e", "-vv", "-l", "-c", "32", "-i", "tenant0", "udp and (port 67 or port 68)"],
            "rc": 130, "started_utc": c0_timestamp, "completed_utc": c0_completed,
            "stop_requested": True,
        },
        "observer": {
            "pid": 321, "starttime": 111111, "uid": 0, "netns": "net:[4026531840]", "ifindex": 5,
            "supervisor_pid": 320, "supervisor_starttime": 333333, "supervisor_uid": os.getuid(),
            "tcpdump_pid": 322, "tcpdump_starttime": 222222, "tcpdump_uid": 0,
            "tcpdump_netns": "net:[4026531840]",
        },
        "capture": {
            "remote_path": f"/tmp/p010-{state['run_id']}-dhcp.log", "device": 1,
            "inode": 30001, "owner_uid": os.getuid(), "mode": "0600", "sha256": c0_sha256,
            "captured_packets": 6, "received_by_filter": 8, "dropped_by_kernel": 0,
            "stop_requested": True, "result_path": f"/tmp/p010-{state['run_id']}-dhcp.result",
            "result_device": 1, "result_inode": 30002, "result_owner_uid": os.getuid(),
            "result_mode": "0600",
        },
        "transaction": {
            "xid": "0x1234abcd", "exchange": ["DISCOVER", "OFFER", "REQUEST", "ACK"],
            "packet_count": 6, "client_mac": state["hybrid"]["guests"]["cirros"]["tenant_mac"],
            "server_ip": dhcp_server["ip_address"], "server_mac": dhcp_server["mac_address"],
            "address": cirros_port["fixed_ips"][0]["ip_address"],
            "gateway": state["hybrid"]["m11"]["network"]["tenant_gateway"],
        },
        "raw_headers": c0_raw_headers,
    }
    dora_path = run_dir / "m11-evidence" / "c0-dora.json"
    write_json(dora_path, c0_dora_observation)
    dora_stat = dora_path.stat()
    gates["c0_dora_evidence"] = {
        "path": str(dora_path), "sha256": hashlib.sha256(dora_path.read_bytes()).hexdigest(),
        "device": dora_stat.st_dev, "inode": dora_stat.st_ino,
        "owner_uid": os.getuid(), "mode": "0600", "capture_sha256": c0_sha256,
        "captured_packets": 6, "received_by_filter": 8, "dropped_by_kernel": 0,
        "xid": "0x1234abcd", "capture_identity": capture_identity,
        "scope": "C0 first-boot DHCP DORA on tenant0; no tenant-to-pod origin claim",
    }
    if historical_c1 is not None:
        historical_c1["receipt"] = {
            "path": str(receipt_path),
            "sha256": source_receipt_sha256,
            "device": receipt_stat.st_dev,
            "inode": receipt_stat.st_ino,
            "owner_uid": os.getuid(),
            "mode": "0600",
        }
    state_file = fixture_state_file(case_root, state)
    vars_file = write_vars(case_root, state, state_file, run_dir, bin_dir, os.getuid(), extra)
    return run_dir, state_file, vars_file


def read_events(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def cleanup_fixture_processes(identity_root: Path) -> None:
    results = []
    if identity_root.is_dir():
        for identity_path in sorted(identity_root.glob("*.json")):
            expected = json.loads(identity_path.read_text(encoding="ascii"))
            pid = int(expected["pid"])
            try:
                pidfd = os.pidfd_open(pid) if hasattr(os, "pidfd_open") else None
                stat_line = Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
                actual = {
                    "pid": pid,
                    "uid": os.stat(f"/proc/{pid}").st_uid,
                    "starttime": int(stat_line[stat_line.rfind(") ") + 2 :].split()[19]),
                }
            except (FileNotFoundError, ProcessLookupError):
                results.append({"pid": pid, "result": "already-exited"})
                continue
            if actual != expected:
                if pidfd is not None:
                    os.close(pidfd)
                results.append({"pid": pid, "result": "identity-mismatch-no-signal"})
                continue
            try:
                if pidfd is not None and hasattr(signal, "pidfd_send_signal"):
                    signal.pidfd_send_signal(pidfd, signal.SIGTERM)
                else:
                    os.kill(pid, signal.SIGTERM)
                results.append({"pid": pid, "result": "SIGTERM-identity-matched"})
            except ProcessLookupError:
                results.append({"pid": pid, "result": "exited-before-cleanup"})
            finally:
                if pidfd is not None:
                    os.close(pidfd)
    if identity_root.parent.exists():
        (identity_root.parent / "fixture-cleanup.json").write_text(
            json.dumps({"utc": datetime.now(timezone.utc).isoformat(), "results": results}, sort_keys=True, indent=2) + "\n",
            encoding="utf-8",
        )


def proc_stat_line(pid: int, command: str, starttime: int) -> str:
    fields = ["S"] + [str(value) for value in range(4, 23)]
    fields[-1] = str(starttime)
    return f"{pid} ({command}) " + " ".join(fields) + "\n"


def yaml_literal(source: str, start_marker: str, end_marker: str) -> str:
    start = source.index(start_marker) + len(start_marker)
    end = source.index(end_marker, start)
    return dedent(source[start:end]).rstrip() + "\n"


def run_recorded_process(
    name: str,
    command: list[str],
    cwd: Path,
    input_bytes: bytes,
    result_dir: Path,
    expected_rc: int,
    env_extra: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[bytes]:
    result_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    input_path = result_dir / "stdin.bin"
    input_path.write_bytes(input_bytes)
    env = os.environ.copy()
    if env_extra:
        env.update(env_extra)
    started = datetime.now(timezone.utc).isoformat(timespec="microseconds")
    result = subprocess.run(command, cwd=cwd, env=env, input=input_bytes, capture_output=True, check=False)
    finished = datetime.now(timezone.utc).isoformat(timespec="microseconds")
    stdout_path = result_dir / "stdout.log"
    stderr_path = result_dir / "stderr.log"
    stdout_path.write_bytes(result.stdout)
    stderr_path.write_bytes(result.stderr)
    record = {
        "name": name,
        "command": command,
        "cwd": str(cwd),
        "started_utc": started,
        "finished_utc": finished,
        "expected_rc": expected_rc,
        "rc": result.returncode,
        "stdin_sha256": hashlib.sha256(input_bytes).hexdigest(),
        "script_files": [
            {"path": str(Path(part)), "sha256": hashlib.sha256(Path(part).read_bytes()).hexdigest()}
            for part in command if Path(part).is_file() and Path(part).suffix in (".py", ".sh")
        ],
        "stdout_sha256": hashlib.sha256(result.stdout).hexdigest(),
        "stderr_sha256": hashlib.sha256(result.stderr).hexdigest(),
        "stdout": str(stdout_path),
        "stderr": str(stderr_path),
    }
    write_json(result_dir / "result.json", record)
    if result.returncode != expected_rc:
        raise AssertionError(f"{name} rc={result.returncode}, esperado={expected_rc}; evidence={result_dir}")
    return result


def parser_observations() -> list[dict]:
    common = [
        ("ubuntu-tenant0", "ubuntu-tenant0"),
        ("cirros-endpoint", "cirros-endpoint"),
        ("qrouter-tenant", "qrouter-tenant"),
        ("qrouter-provider", "qrouter-provider"),
        ("border-tap", "border-tap"),
        ("border-swp1", "border-fabric"),
        ("worker-pod_to_cirros", "worker-fabric"),
        ("pod-pod_to_cirros", "pod-endpoint"),
    ]
    observations = []
    for key, role in common:
        observer = {"key": key, "role": role, "interface": "swp1" if key == "border-swp1" else "eth0"}
        if role == "border-fabric":
            observer["route_candidates"] = [
                {"direction": "pod_to_cirros", "prefix": "10.246.1.0/24", "hops": [{"dev": "swp1", "gateway": "10.30.1.1"}]},
                {"direction": "cirros_to_pod", "prefix": "10.246.2.0/24", "hops": [{"dev": "swp1", "gateway": "10.30.2.1"}]},
            ]
        observations.append(observer)
    return observations


def parser_packets(mac: str, interface: str, mutation: str = "") -> str:
    source, destination, port = POD_CLIENT, VM_IP, 22
    peer = "02:aa:bb:cc:dd:ee"
    lines: list[str] = []

    def frame(offset: int, src: str, dst: str, body: str, reverse: bool = False, protocol: int = 1) -> None:
        source_mac, destination_mac = (peer, mac) if reverse else (mac, peer)
        stamp = f"2026-10-30 00:00:01.{offset:06d}"
        detail = body if " > " in body else f"{src} > {dst}: {body}"
        protocol_name = {1: "ICMP", 6: "TCP"}[protocol]
        lines.append(
            f"{stamp} {source_mac} > {destination_mac}, ethertype IPv4 (0x0800), length 98: "
            f"IP (tos 0x0, ttl 64, id 1, offset 0, flags [DF], proto {protocol_name} ({protocol}), length 84) {detail}"
        )

    for offset, sequence in enumerate((0, 65535)):
        frame(offset, source, destination, f"ICMP echo request, id 0, seq {sequence}, length 64")
        frame(offset + 2, destination, source, f"ICMP echo reply, id 0, seq {sequence}, length 64", True)
    frame(5, source, destination, f"{source}.40001 > {destination}.{port}: Flags [SEW], seq 4294967295, win 64240, length 0", protocol=6)
    frame(6, destination, source, f"{destination}.{port} > {source}.40001: Flags [S.EW], seq 41, ack 0, win 65160, length 0", True, protocol=6)
    frame(7, source, destination, f"{source}.40001 > {destination}.{port}: Flags [.], ack 42, win 502, length 0", protocol=6)
    text = "\n".join([f"tcpdump: listening on {interface}, link-type EN10MB (Ethernet), snapshot length 262144 bytes", *lines]) + "\n"
    if mutation == "rst_ack":
        text = text.replace("Flags [.], ack 42", "Flags [R.], seq 0, ack 42")
    elif mutation == "syn_fin":
        text = text.replace("Flags [SEW], seq 4294967295", "Flags [SF], seq 4294967295")
    elif mutation == "nul":
        text = text.replace("Flags [.], ack 42", "Flags [.], ack 42\x00")
    elif mutation == "truncated":
        text = text[:-1]
    elif mutation == "source":
        text = text.replace(f"{source}.40001 >", "10.246.1.11.40001 >", 1)
    elif mutation == "icmp_id":
        text = text.replace("ICMP echo request, id 0", "ICMP echo request, id 1", 1)
    elif mutation == "icmp_sequence":
        text = text.replace("ICMP echo request, id 0, seq 0", "ICMP echo request, id 0, seq 1", 1)
    elif mutation == "icmp_reply":
        text = text.replace("ICMP echo reply, id 0, seq 0", "ICMP echo reply, id 0, seq 1", 1)
    elif mutation == "synack_sequence":
        text = text.replace("Flags [S.EW], seq 41", "Flags [S.EW], seq 42")
    elif mutation == "synack_ack":
        text = text.replace("seq 41, ack 0", "seq 41, ack 1")
    elif mutation == "final_ack":
        text = text.replace("Flags [.], ack 42", "Flags [.], ack 43")
    elif mutation == "protocol":
        text = text.replace("proto TCP (6)", "proto 17", 1)
    elif mutation == "protocol_missing":
        text = text.replace("proto TCP (6)", "proto", 1)
    elif mutation == "protocol_ambiguous":
        text = text.replace("proto TCP (6)", "proto TCP (6), proto TCP (6)", 1)
    elif mutation == "protocol_name_mismatch":
        text = text.replace("proto TCP (6)", "proto TCP (1)", 1)
    elif mutation == "ambiguous_synack":
        text += f"2026-10-30 00:00:01.000008 {peer} > {mac}, ethertype IPv4 (0x0800), length 98: IP (tos 0x0, ttl 64, id 1, offset 0, flags [DF], proto TCP (6), length 60) {destination}.22 > {source}.40001: Flags [S.], seq 41, ack 1, win 64240, length 0\n"
    return text


def parser_stage_data(mutation: str = "") -> dict:
    observers = parser_observations()
    streams = []
    for observer in observers:
        text = parser_packets("02:bb:cc:dd:ee:01", observer["interface"], mutation if observer["key"] == "border-tap" else "")
        # The common route observer and endpoint captures all share the selected frame set;
        # the parser still checks their role and inventory independently.
        streams.append({
            "key": observer["key"], "interface": observer["interface"], "text": text,
            "bytes": len(text.encode("utf-8")), "sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
        })
    return {
        "stage": "pod_to_cirros", "streams": streams, "observers": observers,
        "route_cidrs": {"pod_to_cirros": "10.246.1.0/24", "cirros_to_pod": "10.246.2.0/24"},
        "flows": {
            "pod_to_cirros": {"source_ip": POD_CLIENT, "destination_ip": VM_IP, "service_port": 22},
            "cirros_to_pod": {"source_ip": VM_IP, "destination_ip": POD_SERVER, "service_port": 8080},
        },
    }


def parser_helper_entry(mutation: str = "") -> dict:
    listener = "tcpdump: listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes\n"
    frame = (
        "2026-10-30 00:00:01.000000 02:bb:cc:dd:ee:01 > 02:aa:bb:cc:dd:ee, ethertype IPv4 (0x0800), length 98: "
        "IP (tos 0x0, ttl 64, id 1, offset 0, flags [DF], proto TCP (6), length 60) "
        "10.246.1.10.40001 > 198.18.49.22.22: Flags [SEW], seq 4294967295, win 64240, length 0\n"
    )
    text = listener + frame + frame.replace(".000000", ".000001")
    text += "2 packets captured\n2 packets received by filter\n0 packets dropped by kernel\n"
    entry = {
        "key": "helper-control", "interface": "eth0", "text": text,
        "bytes": len(text.encode("utf-8")), "sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
        "child_rc": 130, "supervisor_rc": 130, "transport_rc": 0,
    }
    if mutation == "nul": entry["text"] = entry["text"].replace("seq 4294967295", "seq 4294967295\x00")
    elif mutation == "truncated": entry["text"] = entry["text"].rstrip("\n")
    elif mutation == "dropped": entry["text"] = entry["text"].replace("0 packets dropped", "1 packets dropped")
    elif mutation == "captured": entry["text"] = entry["text"].replace("2 packets captured", "3 packets captured")
    elif mutation == "received": entry["text"] = entry["text"].replace("2 packets received", "1 packets received")
    elif mutation == "duplicate_stat": entry["text"] += "2 packets captured\n"
    elif mutation == "listener": entry["text"] = entry["text"].replace("listening on eth0", "listening on tap0")
    elif mutation == "child_rc": entry["child_rc"] = 9
    elif mutation == "supervisor_rc": entry["supervisor_rc"] = 9
    elif mutation == "transport_rc": entry["transport_rc"] = 1
    elif mutation == "digest": entry["sha256"] = "0" * 64
    elif mutation == "length": entry["bytes"] += 1
    elif mutation == "cap": entry["text"] = listener + frame * 128 + "128 packets captured\n128 packets received by filter\n0 packets dropped by kernel\n"
    encoded = entry["text"].encode("utf-8")
    if mutation not in ("digest", "length"):
        entry["bytes"] = len(encoded)
        entry["sha256"] = hashlib.sha256(encoded).hexdigest()
    return entry


def run_focused_parser_controls(source: str, focused_root: Path) -> dict[str, object]:
    parser = yaml_literal(
        source,
        "    student_hybrid_m11_c1_parser_script: |-\n",
        "  no_log: true\n",
    )
    parser_path = focused_root / "parser" / "capture-parser.py"
    parser_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    parser_path.write_text(parser, encoding="utf-8")
    helper_stop = parser.index("def deduplicate(packets):")
    reader_helper = parser[:helper_stop].replace("DATA = json.load(sys.stdin)\n", "", 1)
    reader_helper += "\nDATA = json.load(sys.stdin)\nentry = DATA['entry']\npackets, stats = read_stream(entry, True)\nprint(json.dumps({'packets': len(packets), 'stats': stats}, separators=(',', ':')))\n"
    helper_path = focused_root / "parser" / "capture-reader.py"
    helper_path.write_text(reader_helper, encoding="utf-8")
    flow_helper = parser[:parser.index("def validate_stage(entries, observers, flows, stage, final):")].replace("DATA = json.load(sys.stdin)\n", "", 1)
    flow_helper += "\nDATA = json.load(sys.stdin)\npackets, _stats = read_stream(DATA['entry'], False)\nprint(json.dumps(flow_events(packets, DATA['flow']), separators=(',', ':')))\n"
    flow_helper_path = focused_root / "parser" / "capture-flow-events.py"
    flow_helper_path.write_text(flow_helper, encoding="utf-8")
    results: dict[str, object] = {}
    valid_data = parser_stage_data()
    valid_result_record: dict[str, object] | None = None
    for name, mutation in [("valid-ecn-wrap-ack-no-seq", "")] + [
        (label, label) for label in (
            "rst_ack", "syn_fin", "nul", "truncated", "source", "icmp_id", "icmp_sequence",
            "icmp_reply", "synack_sequence", "synack_ack", "final_ack", "protocol", "protocol_missing",
            "protocol_ambiguous", "protocol_name_mismatch", "ambiguous_synack",
        )
    ]:
        data = valid_data if not mutation else parser_stage_data(mutation)
        result_dir = focused_root / "parser" / name
        result = run_recorded_process(
            name, [sys.executable, "-B", str(parser_path)], Path.cwd(), json.dumps(data, separators=(",", ":")).encode(),
            result_dir, 0 if not mutation else 2,
        )
        if not mutation:
            parsed = json.loads(result.stdout)
            if parsed.get("stage") != "pod_to_cirros" or parsed.get("packets", 0) <= 0:
                raise AssertionError("valid full parser body did not accept the measured stage")
            entry = next(item for item in data["streams"] if item["key"] == "border-tap")
            measurement_result = run_recorded_process(
                "valid-flow-measurement", [sys.executable, "-B", str(flow_helper_path)], Path.cwd(),
                json.dumps({"entry": entry, "flow": data["flows"]["pod_to_cirros"]}, separators=(",", ":")).encode(),
                focused_root / "parser" / "valid-flow-measurement", 0,
            )
            tcp = json.loads(measurement_result.stdout)
            if tcp["tcp"]["client_syn_seq"] != 0xFFFFFFFF or tcp["tcp"]["server_synack_seq"] != 41 or tcp["tcp"]["server_synack_ack"] != 0 or not tcp["tcp"]["seq_absent"] or tcp["tcp"]["client_ack"] != 42:
                raise AssertionError("valid ECN/wrap/ACK-without-sequence control did not retain measured fields")
            valid_result_record = json.loads((result_dir / "result.json").read_text(encoding="utf-8"))
        else:
            results[name] = json.loads(result.stdout)
    for mutation in (
        "valid", "nul", "truncated", "dropped", "captured", "received", "duplicate_stat", "listener",
        "child_rc", "supervisor_rc", "transport_rc", "digest", "length", "cap",
    ):
        entry = parser_helper_entry("" if mutation == "valid" else mutation)
        input_bytes = json.dumps({"entry": entry}, separators=(",", ":")).encode()
        expected_rc = 0 if mutation == "valid" else 2
        result = run_recorded_process(
            f"reader-{mutation}", [sys.executable, "-B", str(helper_path)], Path.cwd(), input_bytes,
            focused_root / "parser" / f"reader-{mutation}", expected_rc,
        )
        if mutation != "valid":
            results[f"reader-{mutation}"] = json.loads(result.stdout)
    write_json(focused_root / "parser" / "summary.json", {
        "parser_sha256": hashlib.sha256(parser.encode()).hexdigest(),
        "reader_sha256": hashlib.sha256(reader_helper.encode()).hexdigest(),
        "flow_helper_sha256": hashlib.sha256(flow_helper.encode()).hexdigest(),
        "valid_result": valid_result_record,
        "valid_fields": {"client_syn_seq": 0xFFFFFFFF, "server_synack_seq": 41, "server_synack_ack": 0, "client_ack": 42, "client_ack_seq": None},
        "negative_results": results,
    })
    return results


def run_focused_discovery_controls(source: str, focused_root: Path) -> dict[str, object]:
    section = source[source.index("- name: Locate each kubelet's effective CRI endpoint and the node-local crictl executable"):]
    body = yaml_literal(section, "    stdin: |-\n", "    stdin_add_newline: false\n")
    base = focused_root / "discovery"
    endpoint = "unix:///run/containerd/containerd.sock"
    cases: list[tuple[str, list[list[str]], str, int, str]] = [
        ("zero-kubelets", [], "", 1, ""),
        ("two-kubelets", [
            ["kubelet", f"--container-runtime-endpoint={endpoint}"],
            ["kubelet", f"--container-runtime-endpoint={endpoint}"],
        ], "", 1, ""),
        ("duplicate-endpoint", [["kubelet", f"--container-runtime-endpoint={endpoint}", "--container-runtime-endpoint", endpoint]], "", 74, ""),
        ("duplicate-config", [["kubelet", f"--container-runtime-endpoint={endpoint}", "--config", "/tmp/fixture-kubelet.yaml", "--config=/tmp/fixture-kubelet.yaml"]], "", 74, ""),
        ("missing-endpoint-value", [["kubelet", "--container-runtime-endpoint"]], "", 74, ""),
        ("missing-config-value", [["kubelet", "--config"]], "", 74, ""),
        ("unix-endpoint-flag", [["kubelet", f"--container-runtime-endpoint={endpoint}"],], "", 0, "flag"),
        ("unix-endpoint-config", [["kubelet", "--config", "/tmp/fixture-kubelet.yaml"]], f"containerRuntimeEndpoint: {endpoint}\n", 0, "config"),
    ]
    results: dict[str, object] = {}
    for case_name, kubelets, config_contents, expected_rc, expected_source in cases:
        case_root = base / case_name
        proc_root = case_root / "proc"
        temporary = case_root / "tmp"
        fake_bin = case_root / "bin"
        for directory in (proc_root, temporary, fake_bin):
            directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        config_path = case_root / "fixture-kubelet.yaml"
        if config_contents:
            config_path.write_text(config_contents, encoding="ascii")
        for index, arguments in enumerate(kubelets, start=101):
            arguments = [str(config_path) if value == "/tmp/fixture-kubelet.yaml" else value for value in arguments]
            proc_entry_dir = proc_root / str(index)
            proc_entry_dir.mkdir(mode=0o700)
            (proc_entry_dir / "cmdline").write_bytes(b"\0".join(value.encode() for value in arguments) + b"\0")
            (proc_entry_dir / "stat").write_text(proc_stat_line(index, "kubelet fixture", 230000 + index), encoding="ascii")
        boot_id = proc_root / "sys/kernel/random/boot_id"
        boot_id.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        boot_id.write_text("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\n", encoding="ascii")
        crictl_trace = case_root / "crictl-invocations.log"
        crictl = fake_bin / "crictl"
        crictl.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$P010_C1_DISCOVERY_CRI_TRACE\"\nexit 0\n", encoding="utf-8")
        crictl.chmod(0o700)
        (fake_bin / "readlink").write_text("#!/bin/sh\nfor value do last=$value; done\nprintf '%s\\n' \"$last\"\n", encoding="utf-8")
        (fake_bin / "sha256sum").write_text("#!/bin/sh\nshasum -a 256 \"$1\"\n", encoding="utf-8")
        (fake_bin / "stat").write_text("#!/bin/sh\nprintf '1:1\\n'\n", encoding="utf-8")
        for wrapper in (fake_bin / "readlink", fake_bin / "sha256sum", fake_bin / "stat"):
            wrapper.chmod(0o700)
        shell = body.replace("/proc", str(proc_root))
        shell = shell.replace("/tmp/p010-c1-kubelet-args.", str(temporary / "args."))
        shell = shell.replace("/usr/bin/stat", str(fake_bin / "stat"))
        shell_path = case_root / "discovery.sh"
        shell_path.write_text(shell, encoding="utf-8")
        env_extra = {
            "PATH": str(fake_bin) + os.pathsep + os.environ.get("PATH", ""),
            "P010_C1_DISCOVERY_CRI_TRACE": str(crictl_trace),
        }
        result = run_recorded_process(
            case_name, ["/bin/sh", "-se"], Path.cwd(), shell.encode("utf-8"), case_root / "result", expected_rc, env_extra,
        )
        if expected_rc:
            if result.stdout or crictl_trace.exists():
                raise AssertionError(f"{case_name} reached CRI or emitted a discovery record before failing; evidence={case_root}")
        else:
            fields = result.stdout.decode("utf-8").strip().split("|")
            if len(fields) != 8 or fields[0] != endpoint or fields[1] != expected_source:
                raise AssertionError(f"{case_name} did not preserve the single unix endpoint record: {fields}")
            if fields[4] != str(crictl) or crictl_trace.exists():
                raise AssertionError(f"{case_name} did not discover crictl without invoking it: {fields}")
        result_record_path = case_root / "result/result.json"
        result_record = json.loads(result_record_path.read_text(encoding="utf-8"))
        result_record["rendered_script"] = str(shell_path)
        result_record["rendered_script_sha256"] = hashlib.sha256(shell.encode("utf-8")).hexdigest()
        write_json(result_record_path, result_record)
        results[case_name] = result_record
    write_json(base / "summary.json", {
        "cases": results,
        "body_sha256": hashlib.sha256(body.encode()).hexdigest(),
        "proc_fixture": "synthetic cmdline/stat/boot-id files; no live PID/starttime claim",
    })
    return results


def linux_proc_available() -> bool:
    return sys.platform == "linux" and Path("/proc/1/stat").is_file() and os.geteuid() == 0


def kernel_starttime(pid: int) -> int:
    line = Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
    return int(line[line.rfind(") ") + 2:].split()[19])


def run_focused_stop_identity_controls(
    ansible_playbook: Path,
    student_lab: Path,
    tasks: Path,
    runner: Runner,
    scratch: Path,
    bin_dir: Path,
) -> dict[str, object]:
    case_root = scratch / "focused-stop-fixture"
    case_root.mkdir(mode=0o700, parents=True)
    run_dir = case_root / "private-run"
    run_dir.mkdir(mode=0o700)
    state = make_state(run_dir, os.getuid())
    state["status"] = "partial"
    state["phase"] = "hybrid-c1-observer-starting"
    check_id = "c1-stopfixture41"
    gates = state["hybrid"]["m11"]["verification"]["gates"]
    gates["positive"]["c1"] = {"phase": "verified", "check_id": check_id}
    gates["c1_capture_active"] = {"schema": 1, "check_id": "", "phase": "absent", "observers": []}
    capture_path = run_dir / "m11-evidence" / check_id / "observer-stop-fixture.txt"
    capture_path.parent.mkdir(mode=0o700, parents=True)
    observer = {
        "key": "stop-fixture", "role": "border-tap", "transport": "netns", "check_id": check_id,
        "capture_path": str(capture_path), "netns_path": "/proc/900/ns/net", "expected_netns": "205:5222",
        "interface": "eth0", "expected_ifindex": 4, "expected_mac": "02:bb:cc:dd:ee:01",
        "filter": f"ip and host {POD_CLIENT} and host {VM_IP} and tcp port 22",
    }
    state_file = fixture_state_file(case_root, state)
    vars_file = write_vars(case_root, state, state_file, run_dir, bin_dir, os.getuid(), {
        "student_hybrid_m11_c1_capture_action": "start",
        "student_hybrid_m11_c1_observer": observer,
        "student_hybrid_m11_c1_filter": observer["filter"],
    })
    start_play = write_playbook(case_root, student_lab, vars_file, tasks / "hybrid-m11-build-stop-origin-script.yml", "Start one genuine C1 stop fixture")
    runner.run("focused-stop-start", start_play, {"P010_M20_MODE": "positive"})
    started_state = json.loads(state_file.read_text(encoding="utf-8"))
    active = started_state["hybrid"]["m11"]["verification"]["gates"]["c1_capture_active"]
    if active.get("phase") != "capturing" or len(active.get("observers", [])) != 1:
        raise AssertionError("product start did not persist exactly one measured capture identity")
    saved_observer = active["observers"][0]
    capture_path = Path(saved_observer["capture_path"])
    fake_proc = runner.scratch / "fake-proc"
    pid = int(saved_observer["tcpdump_pid"])
    proc_dir = fake_proc / str(pid)
    identity_path = runner.scratch / "fixture-identities" / f"{pid}.json"
    identity = json.loads(identity_path.read_text(encoding="ascii"))
    if identity != {"pid": pid, "uid": os.stat(f"/proc/{pid}").st_uid, "starttime": kernel_starttime(pid)}:
        raise AssertionError("fixture cleanup identity was not measured from the live kernel process")

    stop_vars = json.loads(vars_file.read_text(encoding="utf-8"))
    stop_vars["student_state"] = started_state
    write_json(vars_file, stop_vars)

    stop_tasks = case_root / "stop-action.yml"
    stop_tasks.write_text(
        "---\n"
        f"- ansible.builtin.include_tasks: {json.dumps(str(tasks / 'hybrid-m11-build-stop-origin-script.yml'))}\n"
        "  loop: \"{{ student_state.hybrid.m11.verification.gates.c1_capture_active.observers }}\"\n"
        "  loop_control:\n"
        "    loop_var: student_hybrid_m11_c1_observer\n"
        "    label: \"{{ student_hybrid_m11_c1_observer.key }}\"\n"
        "  vars:\n"
        "    student_hybrid_m11_c1_capture_action: stop\n",
        encoding="utf-8",
    )
    mismatch_cases = (
        "capture-stop-starttime", "capture-stop-uid", "capture-stop-netns",
        "capture-stop-argv", "capture-stop-final-nul", "capture-stop-proc-query",
    )
    control_results: dict[str, object] = {}
    stat_path = proc_dir / "stat"
    identity_file = proc_dir / "identity.json"
    cmdline_path = proc_dir / "cmdline"
    for mode in mismatch_cases:
        originals = {
            "stat": stat_path.read_bytes(),
            "identity": identity_file.read_bytes(),
            "cmdline": cmdline_path.read_bytes(),
        }
        if mode == "capture-stop-starttime":
            line = originals["stat"].decode("ascii")
            head, rest = line.rsplit(") ", 1)
            fields = rest.split()
            fields[19] = str(int(fields[19]) + 1)
            stat_path.write_text(head + ") " + " ".join(fields) + "\n", encoding="ascii")
        elif mode == "capture-stop-argv":
            argv_fields = originals["cmdline"].split(b"\0")
            if len(argv_fields) < 2 or not argv_fields[0] or argv_fields[-1] != b"":
                raise AssertionError("stop argv fixture must have a first field and final NUL")
            argv_fields[0] += b".mismatch"
            cmdline_path.write_bytes(b"\0".join(argv_fields))
        elif mode == "capture-stop-final-nul":
            cmdline_path.write_bytes(originals["cmdline"].rstrip(b"\0"))
        elif mode == "capture-stop-proc-query":
            stat_path.unlink()
        stop_play = write_playbook(case_root, student_lab, vars_file, stop_tasks, f"Reject stop identity mismatch {mode}")
        try:
            if mode == "capture-stop-argv":
                original_fields = originals["cmdline"].split(b"\0")
                mutated_payload = cmdline_path.read_bytes()
                mutated_fields = mutated_payload.split(b"\0")
                if (
                    mutated_payload == originals["cmdline"]
                    or mutated_fields[0] == original_fields[0]
                    or mutated_fields[1:] != original_fields[1:]
                    or mutated_fields[-1] != b""
                ):
                    raise AssertionError("stop argv mutation must change only argv[0] and preserve its final NUL")
            runner.run(f"focused-stop-{mode}", stop_play, {"P010_M20_MODE": mode}, expected=2)
        finally:
            stat_path.write_bytes(originals["stat"])
            identity_file.write_bytes(originals["identity"])
            cmdline_path.write_bytes(originals["cmdline"])
        trace_path = runner.scratch / f"focused-stop-{mode}.trace.jsonl"
        events = read_events(trace_path)
        if any(event.get("kind") == "fake-signal" for event in events):
            raise AssertionError(f"{mode} sent a signal after identity rejection")
        current_state = json.loads(state_file.read_text(encoding="utf-8"))
        current_observer = current_state["hybrid"]["m11"]["verification"]["gates"]["c1_capture_active"]["observers"][0]
        if current_observer["phase"] != "capturing" or int(current_observer["tcpdump_pid"]) != pid:
            raise AssertionError(f"{mode} changed the saved active observer before safe stop")
        if not all(Path(str(capture_path) + suffix).exists() for suffix in ("", ".supervisor", ".tcpdump", ".rc")):
            raise AssertionError(f"{mode} removed a capture identity file after mismatch")
        if os.stat(f"/proc/{pid}").st_uid != identity["uid"] or kernel_starttime(pid) != identity["starttime"]:
            raise AssertionError(f"{mode} fixture process identity changed unexpectedly")
        control_results[mode] = {"rc": runner.attempts[-1]["rc"], "trace": str(trace_path), "no_signal": True, "files_retained": True}
        if mode == "capture-stop-argv":
            control_results[mode]["cmdline_payload_changed"] = True
            control_results[mode]["remaining_argv_and_final_nul_preserved"] = True

    recovery_root = scratch / "fresh-process-active-only"
    recovery_root.mkdir(mode=0o700)
    recovery_dir = recovery_root / "private-run"
    recovery_dir.mkdir(mode=0o700)
    recovery_state = json.loads(state_file.read_text(encoding="utf-8"))
    recovery_gates = recovery_state["hybrid"]["m11"]["verification"]["gates"]
    active_map = recovery_gates["c1_capture_active"]
    recovery_gates.clear()
    recovery_gates.update({
        "c1_capture_active": active_map,
        "traffic_capture": {"phase": "absent"},
        "dhcp_capture": {"phase": "absent"},
    })
    recovery_state["hybrid"]["m11"]["api"]["resources"] = {}
    recovery_file = fixture_state_file(recovery_root, recovery_state)
    if "receipt" in json.dumps(recovery_state) or "client_pod" in recovery_gates or "server_pod" in recovery_gates:
        raise AssertionError("fresh stop fixture retained a historical receipt or Pod gate")
    recovery_vars = write_vars(recovery_root, recovery_state, recovery_file, recovery_dir, bin_dir, os.getuid(), {"student_hybrid_live_guest_names": []})
    recovery_play = write_playbook(recovery_root, student_lab, recovery_vars, tasks / "hybrid-m11-stop-captures.yml", "Fresh process stops only the saved active map")
    runner.run("focused-stop-fresh-process", recovery_play, {"P010_M20_MODE": "positive"})
    removed_state = json.loads(recovery_file.read_text(encoding="utf-8"))
    removed_map = removed_state["hybrid"]["m11"]["verification"]["gates"]["c1_capture_active"]
    if removed_map != {"schema": 1, "check_id": "", "phase": "absent", "observers": []}:
        raise AssertionError("fresh-process stop did not durably clear the exact active map")
    for suffix in ("", ".supervisor", ".tcpdump", ".rc"):
        if Path(str(capture_path) + suffix).exists():
            raise AssertionError("fresh-process stop left a measured capture file")
    for observed in (saved_observer["tcpdump_pid"], saved_observer["supervisor_pid"]):
        try:
            os.kill(int(observed), 0)
        except ProcessLookupError:
            continue
        raise AssertionError("fresh-process stop left a measured capture process alive")
    signal_events = [event for event in read_events(runner.scratch / "focused-stop-fresh-process.trace.jsonl") if event.get("kind") == "fake-signal"]
    if len(signal_events) != 1 or signal_events[0].get("pid") != pid:
        raise AssertionError("valid saved identity did not authorize exactly one measured tcpdump signal")
    control_results["fresh-process-active-only"] = {"cleared": True, "signals": len(signal_events), "receipt_or_pod_input": False}
    write_json(scratch / "focused-stop-summary.json", {
        "cases": control_results,
        "fixture_identity": identity,
        "active_map_sha256": hashlib.sha256(json.dumps(active_map, sort_keys=True).encode()).hexdigest(),
        "cleanup_process": "fresh ansible-playbook invocation; identity measured at process birth",
    })
    return control_results


def main() -> int:
    ansible_playbook = Path(os.environ.get("ANSIBLE_PLAYBOOK_BIN", ""))
    if not ansible_playbook.is_file() or not os.access(ansible_playbook, os.X_OK):
        raise SystemExit("ANSIBLE_PLAYBOOK_BIN must name the existing executable Ansible wrapper")
    student_lab = Path(__file__).resolve().parents[1]
    scratch = Path(os.environ.get("P010_M20_TEST_SCRATCH") or tempfile.mkdtemp(prefix="p010-hybrid20-positive."))
    scratch.mkdir(mode=0o700, parents=True, exist_ok=True)
    focused_root = scratch / "focused"
    focused_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    syntax_root = focused_root / "syntax"
    syntax_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    test_source = Path(__file__).resolve()
    python_syntax = run_recorded_process(
        "python-ast", [sys.executable, "-B", "-c", "import ast,pathlib,sys; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'), filename=sys.argv[1])", str(test_source)],
        Path.cwd(), b"", syntax_root / "python-ast", 0,
    )
    positive_task_path = student_lab / "tasks/hybrid-m11-positive-verify.yml"
    capture_task_path = student_lab / "tasks/hybrid-m11-build-stop-origin-script.yml"
    syntax_play = syntax_root / "focused-syntax.yml"
    syntax_play.write_text(
        "---\n- hosts: localhost\n  gather_facts: false\n  tasks:\n"
        f"    - ansible.builtin.import_tasks: {json.dumps(str(positive_task_path))}\n"
        f"    - ansible.builtin.import_tasks: {json.dumps(str(capture_task_path))}\n",
        encoding="utf-8",
    )
    ansible_syntax = run_recorded_process(
        "ansible-syntax-check", [str(ansible_playbook), "--syntax-check", "-i", "localhost,", str(syntax_play)],
        Path.cwd(), b"", syntax_root / "ansible", 0,
    )
    positive_source = (student_lab / "tasks/hybrid-m11-positive-verify.yml").read_text(encoding="utf-8")
    parser_results = run_focused_parser_controls(positive_source, focused_root)
    discovery_results = run_focused_discovery_controls(positive_source, focused_root)
    bin_dir = scratch / "bin"
    write_fake_tools(bin_dir)
    tasks = configure_shadow(student_lab, scratch, bin_dir)

    qrouter_case_root = focused_root / "qrouter-link-domain"
    qrouter_case_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    qrouter_run = qrouter_case_root / "private-run"
    qrouter_run.mkdir(mode=0o700)
    qrouter_state = make_state(qrouter_run, os.getuid())
    qrouter_observer = {
        "key": "qrouter-tenant", "role": "qrouter-tenant", "transport": "guest",
        "netns_path": "/run/netns/qrouter-synthetic", "expected_netns": "2050:6002",
        "interface": "qr-tenant", "expected_ifindex": 10, "expected_mac": "fa:16:3e:49:00:01",
    }
    qrouter_state["hybrid"]["m11"]["verification"]["gates"]["c1_capture_active"] = {
        "phase": "capturing", "observers": [qrouter_observer],
    }
    qrouter_state_file = fixture_state_file(qrouter_case_root, qrouter_state)
    capture_task_text = (tasks / "hybrid-m11-build-stop-origin-script.yml").read_text(encoding="utf-8")
    proc_read_at = capture_task_text.index('actual_start="$(proc_starttime "$proc_root/$pid/stat")"')
    guest_link_at = capture_task_text.index('live_link="$(run_as_root ')
    if proc_read_at >= guest_link_at or "nsenter --net=\"$netns_path\"" not in capture_task_text[guest_link_at:guest_link_at + 200]:
        raise AssertionError("guest proc identity reads must remain outside the measured link namespace")
    qrouter_link_lines = [
        line.strip() for line in capture_task_text.splitlines()
        if (line.strip().startswith("live_link=") and "nsenter --net=" in line)
        or line.strip().startswith((
            "live_ifindex=", "live_mac=", '[ "$live_ifindex" =', '[ "$live_mac" =',
        ))
    ]
    if len(qrouter_link_lines) != 5 or "nsenter --net=" not in qrouter_link_lines[0] or "$netns_path" not in qrouter_link_lines[0]:
        raise AssertionError("the rendered guest link lookup no longer uses its measured netns")
    qrouter_trace = qrouter_case_root / "qrouter-link.trace.jsonl"
    qrouter_env = {
        "PATH": str(bin_dir) + os.pathsep + os.environ.get("PATH", ""),
        "P010_M20_TRACE": str(qrouter_trace),
        "P010_M20_DELETED": str(qrouter_case_root / "deleted.txt"),
        "P010_M20_STATE_FILE": str(qrouter_state_file),
        "P010_M20_PROC_ROOT": str(scratch / "fake-proc"),
        "P010_M20_FIXTURE_IDENTITIES": str(scratch / "fixture-identities"),
        "P010_M20_MODE": "positive",
        "P010_M20_CAPTURE_ACTION": "check",
        "P010_M20_CAPTURE_KEY": qrouter_observer["key"],
        "P010_M20_RUN_ID": RUN_ID,
        "P010_M20_UID": str(os.getuid()),
        "P010_C1_FAILURE_ROOT": str(focused_root / "failures"),
    }
    qrouter_link_cases = (
        ("measured-netns", qrouter_observer["netns_path"], qrouter_observer["interface"], 0),
        ("wrong-netns", "/run/netns/guest-external", qrouter_observer["interface"], 90),
        ("wrong-interface", qrouter_observer["netns_path"], "qr-missing", 90),
    )
    qrouter_case_results = []
    for case_name, netns_path, interface, expected_rc in qrouter_link_cases:
        shell = "\n".join((
            "set -e",
            'run_as_root() { sudo -n "$@"; }',
            f"netns_path={netns_path}",
            f"interface={interface}",
            f"expected_ifindex={qrouter_observer['expected_ifindex']}",
            f"expected_mac={qrouter_observer['expected_mac']}",
            *qrouter_link_lines,
            "printf 'P010_TEST_AFTER_READINESS=1\\n'",
            "",
        ))
        result = run_recorded_process(
            f"qrouter-link-{case_name}", ["/bin/bash", "-se"], Path.cwd(),
            shell.encode("utf-8"), focused_root / "qrouter-link-domain" / case_name,
            expected_rc, qrouter_env,
        )
        marker = b"P010_TEST_AFTER_READINESS=1\n" in result.stdout
        if marker != (expected_rc == 0):
            raise AssertionError(f"qrouter link case {case_name} crossed the readiness barrier unexpectedly")
        qrouter_case_results.append({"case": case_name, "rc": result.returncode, "after_readiness": marker})
    qrouter_inventory_events = [
        event for event in read_events(qrouter_trace) if event.get("kind") == "qrouter-link-inventory"
    ]
    if [(event.get("domain"), event.get("found"), event.get("interface")) for event in qrouter_inventory_events] != [
        ("qrouter", True, "qr-tenant"), ("guest", False, "qr-tenant"), ("qrouter", False, "qr-missing"),
    ]:
        raise AssertionError("guest and qrouter fake link inventories were not causally distinguished")
    write_json(focused_root / "qrouter-link-domain-summary.json", {
        "cases": qrouter_case_results,
        "inventory": qrouter_inventory_events,
        "process_or_probe_started": False,
    })

    if not linux_proc_available():
        write_json(focused_root / "platform-skip.json", {
            "status": "SKIP_LIVE_PROCESS_AND_COMPOSITION",
            "platform": sys.platform,
            "machine": os.uname().machine,
            "proc_1_stat": Path("/proc/1/stat").is_file(),
            "effective_uid": os.geteuid(),
            "reason": "live PID/starttime/UID/netns checks require Linux procfs; no process identity fixture or C1 composition was started; portable qrouter link cases ran separately",
            "syntax_checks": {
                "python_ast_rc": python_syntax.returncode,
                "ansible_syntax_rc": ansible_syntax.returncode,
                "ansible_version": "2.19.3 per pinned EV tooling",
            },
            "focused_parser_cases": ["valid", *sorted(parser_results)],
            "focused_discovery_cases": sorted(discovery_results),
            "qrouter_link_domain_cases": qrouter_case_results,
        })
        print("FOCUSED PASS; live stop controls and C1 composition NOT_RUN on this host")
        return 0
    atexit.register(cleanup_fixture_processes, scratch / "fixture-identities")
    (scratch / "ansible-local").mkdir(mode=0o700, exist_ok=True)
    event_bin = str(bin_dir / "events")
    base_run = scratch / "base-private-run"
    base_run.mkdir(mode=0o700)
    base_state = make_state(base_run, os.getuid())
    runner = Runner(ansible_playbook, student_lab, scratch, bin_dir)
    run_focused_stop_identity_controls(ansible_playbook, student_lab, tasks, runner, focused_root, bin_dir)

    # The first pass creates the C1 receipt from measured output; later cases
    # copy that producer output as historical integrity input for fresh checks.
    positive_dir = scratch / "positive"
    positive_dir.mkdir(mode=0o700)
    first_state = json.loads(json.dumps(base_state))
    first_state["status"] = "partial"
    first_state["phase"] = "hybrid-guest-ready"
    first_state["hybrid"]["phase"] = "partial"
    first_state["hybrid"]["m11"]["phase"] = "guest-ready"
    first_gates = first_state["hybrid"]["m11"]["verification"]["gates"]
    first_gates["k8s_resources"] = {}
    first_gates["positive"] = {}
    run_dir, state_file, vars_file = set_up_case(
        positive_dir, first_state, student_lab, tasks, bin_dir,
        {"student_hybrid_m11_positive_existing": False},
    )
    positive_sequence = positive_dir / "c1-producer-and-caller-save.yml"
    positive_sequence.write_text(
        "---\n"
        f"- ansible.builtin.include_tasks: {json.dumps(str(tasks / 'hybrid-m11-positive-verify.yml'))}\n"
        "- name: Model the enclosing up caller's final state save after measured C1 success\n"
        "  ansible.builtin.set_fact:\n"
        "    student_state: \"{{ student_state | combine({'status': 'up'}, recursive=false) }}\"\n"
        "  when: >-\n"
        "    student_state.hybrid.m11.verification.gates.positive.c1.phase == 'verified' and\n"
        "    student_state.hybrid.m11.verification.gates.c1_capture_active.phase == 'absent'\n"
        "  no_log: true\n"
        "- name: Persist the caller state after measured C1 success\n"
        "  ansible.builtin.copy:\n"
        "    dest: \"{{ student_state_file }}\"\n"
        "    content: \"{{ student_state | to_nice_json }}\\n\"\n"
        "    owner: \"{{ student_uid }}\"\n"
        "    mode: '0600'\n"
        "  when: student_state.status == 'up'\n"
        "  no_log: true\n",
        encoding="utf-8",
    )
    positive_play = write_playbook(positive_dir, student_lab, vars_file, positive_sequence, "Initial M11 C1 producer verification")
    runner.run("positive-full", positive_play, {"P010_M20_MODE": "capture-guest-owner"})
    positive_state = json.loads(state_file.read_text(encoding="utf-8"))
    assert positive_state["status"] == "up"
    gates = positive_state["hybrid"]["m11"]["verification"]["gates"]
    assert gates["positive"]["phase"] == "verified"
    assert gates["positive"]["vm_source_observed_on_tenant_link"] is True
    assert gates["traffic_capture"]["phase"] == "absent"
    assert len(gates["k8s_resources"]) == 7
    c1 = gates["positive"]["c1"]
    assert c1["phase"] == "verified" and c1["schema"] == 1
    active_captures = gates["c1_capture_active"]
    assert active_captures == {"schema": 1, "check_id": "", "phase": "absent", "observers": []}
    receipt_meta = c1["receipt"]
    receipt_path = Path(receipt_meta["path"])
    receipt_stat = receipt_path.stat()
    assert receipt_stat.st_dev == receipt_meta["device"]
    assert receipt_stat.st_ino == receipt_meta["inode"]
    assert receipt_stat.st_uid == receipt_meta["owner_uid"] == os.getuid()
    assert receipt_stat.st_mode & 0o777 == 0o600
    assert hashlib.sha256(receipt_path.read_bytes()).hexdigest() == receipt_meta["sha256"]
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    assert receipt["schema"] == 1 and receipt["check_id"] == c1["check_id"]
    assert set(receipt["waves"]) == {"pod_to_cirros", "cirros_to_pod"}
    expected_wave_data = {
        "pod_to_cirros": {
            "source": POD_CLIENT, "destination": VM_IP, "port": 22,
            "icmp_id": 0, "icmp_sequences": [0, 65535], "border_interface": "swp1",
        },
        "cirros_to_pod": {
            "source": VM_IP, "destination": POD_SERVER, "port": 8080,
            "icmp_id": 65535, "icmp_sequences": [1, 2], "border_interface": "swp2",
        },
    }
    expected_roles = {
        "ubuntu-tenant0", "cirros-endpoint", "qrouter-tenant", "qrouter-provider",
        "border-tap", "border-fabric", "worker-fabric", "pod-endpoint",
    }
    for wave_name, expected in expected_wave_data.items():
        wave = receipt["waves"][wave_name]
        assert wave["phase"] == "observed"
        assert wave["source_ip"] == expected["source"]
        assert wave["destination_ip"] == expected["destination"]
        assert wave["destination_port"] == expected["port"]
        assert wave["icmp"] == {
            "id": expected["icmp_id"], "sequences": expected["icmp_sequences"],
            "requests": 2, "replies": 2,
        }
        assert set(observer["role"] for observer in wave["observers"]) == expected_roles
        border = next(observer for observer in wave["observers"] if observer["role"] == "border-fabric")
        assert border["interface"] == expected["border_interface"]
        route = next(candidate for candidate in border["route_candidates"] if candidate["direction"] == wave_name)
        expected_prefix = "10.246.1.0/24" if wave_name == "pod_to_cirros" else "10.246.2.0/24"
        assert route["prefix"] == expected_prefix
        assert border["interface"] in {hop["dev"] for hop in route["hops"]}
        ack = wave["tcp"]
        assert ack["seq_absent"] is True and ack.get("client_ack_seq") is None
        assert ack["client_ip"] == expected["source"] and ack["server_ip"] == expected["destination"]
        assert ack["server_port"] == expected["port"]
        assert all(set(header) <= {
            "timestamp", "protocol", "src", "dst", "type", "id", "icmp_seq",
            "sport", "dport", "flags", "seq", "ack", "retransmissions",
        } for observer in wave["observers"] for header in observer["selected_headers"])
    events = read_events(scratch / "positive-full.trace.jsonl")
    assert sum(event.get("kind") == "k8s-delete" for event in events) == 0
    assert sum(event.get("kind") == "docker" and event.get("operation") == "leaf-route" for event in events) == 6
    border_routes = [event for event in events if event.get("kind") == "border-route"]
    assert {event.get("prefix") for event in border_routes} == {"10.246.1.0/24", "10.246.2.0/24"}
    assert {event.get("dev") for event in border_routes} == {"swp1", "swp2"}
    assert sum(event.get("kind") == "kubectl" and event.get("operation") == "exec" for event in events) == 1
    assert [(event.get("guest"), event.get("phase")) for event in events if event.get("kind") == "ssh"] == [
        ("ubuntu", "ovs-verify"), ("ubuntu", "c1-discovery"),
        ("cirros", "guest-probe"), ("cirros", "c1-reverse-probe"),
    ]
    waves = [(index, event) for index, event in enumerate(events) if event.get("kind") == "c1-wave"]
    assert [event.get("wave") for _, event in waves] == [1, 2]
    assert all(event.get("ready") == 11 and event.get("observers") == 8 for _, event in waves)
    capture_events = [(index, event) for index, event in enumerate(events) if event.get("kind") == "c1-capture"]
    starts = [(index, event) for index, event in capture_events if event.get("action") == "start"]
    checks = [(index, event) for index, event in capture_events if event.get("action") == "check"]
    start_identities = [
        (event.get("key"), event.get("transport"), event.get("guest")) for _, event in starts
    ]
    first_wave_index = waves[0][0]
    second_wave_index = waves[1][0]
    stops = [(index, event) for index, event in capture_events if event.get("action") == "stop"]
    stop_indices = [index for index, _ in stops]
    check_barriers = (
        [(index, event) for index, event in checks if index < first_wave_index],
        [(index, event) for index, event in checks if first_wave_index < index < second_wave_index],
        [(index, event) for index, event in checks if second_wave_index < index < min(stop_indices)],
    )
    assert len(starts) == 11 and len(start_identities) == len({key for key, _, _ in start_identities}) == 11
    assert len(checks) == 33 and [len(barrier) for barrier in check_barriers] == [11, 11, 11]
    assert all(
        [(event.get("key"), event.get("transport"), event.get("guest")) for _, event in barrier] == start_identities
        and all(event.get("rc") == 0 for _, event in barrier)
        for barrier in check_barriers
    )
    assert max(index for index, _ in starts) < min(index for index, _ in check_barriers[0]) < first_wave_index
    assert first_wave_index < max(index for index, _ in check_barriers[1]) < second_wave_index
    assert second_wave_index < max(index for index, _ in check_barriers[2]) < min(stop_indices)
    initial_snapshots = [(index, event) for index, event in capture_events
                         if event.get("action") == "snapshot" and index < first_wave_index]
    assert len(initial_snapshots) == 11
    second_wave_index = waves[1][0]
    between_wave_snapshots = [(index, event) for index, event in capture_events
                              if event.get("action") == "snapshot" and first_wave_index < index < second_wave_index]
    assert len(between_wave_snapshots) == 11
    removals = [(index, event) for index, event in capture_events if event.get("action") == "cleanup"]
    assert len(stops) == len(removals) == 11
    assert max(index for index, _ in stops) < min(index for index, _ in removals)

    # Existing up and direct verify both dispatch the saved API child, then re-run
    # the real positive verifier without creating or POSTing any resource.
    for action, task in (("up", "up.yml"), ("verify", "verify.yml")):
        case_root = scratch / f"caller-{action}"
        case_root.mkdir(mode=0o700)
        run_dir, state_file, vars_file = set_up_case(case_root, positive_state, student_lab, tasks, bin_dir)
        play = write_playbook(case_root, student_lab, vars_file, tasks / task, f"Existing {action} lifecycle")
        runner.run(f"caller-{action}", play, {})
        caller_state = json.loads(state_file.read_text(encoding="utf-8"))
        assert caller_state["status"] == "up"
        caller_events = read_events(scratch / f"caller-{action}.trace.jsonl")
        assert any(event.get("kind") == "api" and event.get("mode") == "verify" for event in caller_events)
        assert not any(event.get("kind") == "api" and event.get("mode") in ("provision", "create") for event in caller_events)
        assert sum(event.get("kind") == "kubectl" and event.get("operation") == "get" for event in caller_events) >= 14

    # Failed live checks persist partial state and retain run-owned identities.
    for failure in (
        "api", "guest", "bgp", "route", "traffic",
        "capture-readiness", "capture-guest-owner-mismatch", "capture-qrouter-wrong-netns",
        "capture-cmdline-child-terminator", "capture-cmdline-supervisor-terminator",
        "capture-container-attempt", "capture-sandbox-attempt", "capture-sandbox-attempt-missing",
        "capture-interface", "capture-rstack", "capture-nul", "capture-synfin",
        "capture-tuple", "capture-ack-ambiguous", "capture-truncated", "capture-dropped",
    ):
        case_root = scratch / f"negative-{failure}"
        case_root.mkdir(mode=0o700)
        run_dir, state_file, vars_file = set_up_case(case_root, positive_state, student_lab, tasks, bin_dir)
        prior_c1 = json.loads(state_file.read_text(encoding="utf-8"))["hybrid"]["m11"]["verification"]["gates"]["positive"]["c1"]
        play = write_playbook(case_root, student_lab, vars_file, tasks / "verify.yml", f"Negative M11 {failure}")
        runner.run(f"negative-{failure}", play, {"P010_M20_MODE": failure}, expected=2)
        failed_state = json.loads(state_file.read_text(encoding="utf-8"))
        assert failed_state["status"] == "partial"
        assert failed_state["run_id"] == RUN_ID
        assert set(failed_state["hybrid"]["m11"]["verification"]["gates"]["k8s_resources"]) == set(UIDS)
        trace = read_events(scratch / f"negative-{failure}.trace.jsonl")
        assert any(event.get("kind") == "api" and event.get("mode") == "verify" for event in trace)
        waves = [event.get("wave") for event in trace if event.get("kind") == "c1-wave"]
        if failure in ("api", "guest", "bgp", "route"):
            assert waves == []
            assert not any(event.get("kind") == "c1-capture" for event in trace)
            assert not any(event.get("kind") == "kubectl" and event.get("operation") == "exec" for event in trace)
        elif failure in (
            "traffic", "capture-readiness", "capture-guest-owner-mismatch", "capture-qrouter-wrong-netns",
            "capture-cmdline-child-terminator", "capture-cmdline-supervisor-terminator",
        ):
            assert waves == []
            exec_events = [event for event in trace if event.get("kind") == "kubectl" and event.get("operation") == "exec"]
            if failure == "traffic":
                assert len(exec_events) == 1
            else:
                assert exec_events == []
        elif failure in (
            "capture-container-attempt", "capture-sandbox-attempt", "capture-sandbox-attempt-missing",
            "capture-interface", "capture-rstack", "capture-nul", "capture-synfin",
            "capture-tuple", "capture-ack-ambiguous", "capture-truncated",
        ):
            assert waves == [1]
        elif failure == "capture-dropped":
            assert waves == [1, 2]
        if failure == "capture-qrouter-wrong-netns":
            link_events = [event for event in trace if event.get("kind") == "qrouter-link-inventory"]
            assert any(event.get("domain") == "guest" and event.get("found") is False for event in link_events)
        if failure in ("capture-cmdline-child-terminator", "capture-cmdline-supervisor-terminator"):
            capture_events = [event for event in trace if event.get("kind") == "c1-capture"]
            assert any(event.get("action") == "start" and event.get("key") == "border-tap" and event.get("rc") != 0 for event in capture_events)
            assert not any(event.get("action") == "check" for event in capture_events)
            assert not any(event.get("action") in ("snapshot", "stop", "cleanup") for event in capture_events)
            assert not any(event.get("kind") == "fake-signal" for event in trace)
        if failure == "capture-readiness":
            capture_state = failed_state["hybrid"]["m11"]["verification"]["gates"]["c1_capture_active"]
            assert capture_state["phase"] == "capturing" and len(capture_state["observers"]) >= 7
        if failure == "capture-guest-owner-mismatch":
            capture_events = [event for event in trace if event.get("kind") == "c1-capture"]
            assert len(capture_events) == 1 and capture_events[0].get("action") == "start" and capture_events[0].get("rc") != 0
            assert not list((run_dir / "m11-evidence").rglob("*.tcpdump"))
        if failure.startswith("capture-"):
            failed_c1 = failed_state["hybrid"]["m11"]["verification"]["gates"]["positive"]["c1"]
            assert failed_c1["phase"] != "verified"
        if failure in ("route", "traffic") or failure.startswith("capture-"):
            failed_c1 = failed_state["hybrid"]["m11"]["verification"]["gates"]["positive"]["c1"]
            assert failed_c1["check_id"] != prior_c1["check_id"]
            assert failed_c1["previous_receipt"]["sha256"] == prior_c1["receipt"]["sha256"]
            assert failed_c1["receipt"]["path"] == ""
            if failure in ("capture-cmdline-child-terminator", "capture-cmdline-supervisor-terminator"):
                assert all(
                    failed_c1["previous_receipt"].get(field) == prior_c1["receipt"].get(field)
                    for field in ("path", "sha256", "device", "inode", "owner_uid", "mode")
                )

    # Exercise the full M11 cleanup order twice, using only the saved IDs and UIDs.
    down_root = scratch / "down"
    down_root.mkdir(mode=0o700)
    run_dir, state_file, vars_file = set_up_case(down_root, positive_state, student_lab, tasks, bin_dir, {"student_hybrid_live_guest_names": ["ubuntu", "cirros"]})
    initial = json.loads(state_file.read_text(encoding="utf-8"))
    historical_receipt = Path(initial["hybrid"]["m11"]["verification"]["gates"]["positive"]["c1"]["receipt"]["path"])
    historical_receipt.unlink()
    assert not historical_receipt.exists()
    initial["hybrid"]["m11"]["verification"]["gates"]["ovs_attach"] = {
        "phase": "attached", "bridge_name": "br-int", "interface_name": "tenant0",
        "bridge_uuid": "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa", "port_uuid": "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb",
        "interface_uuid": "cccccccc-3333-4333-8333-cccccccccccc", "ifindex": 8, "ofport": 6,
        "neutron_port_id": IDS["cirros_port"], "guest_uuid": "10112233-4455-4677-8899-aabbccddeeff",
        "attached_mac": "02:00:00:00:00:22", "guest_interface_mac": "02:00:00:00:00:22"
    }
    write_json(state_file, initial)
    vars_file = write_vars(down_root, initial, state_file, run_dir, bin_dir, os.getuid(), {"student_hybrid_live_guest_names": ["ubuntu", "cirros"]})
    down_play = write_playbook(down_root, student_lab, vars_file, tasks / "hybrid-m11-down.yml", "Full M11 cleanup")
    runner.run("down-first", down_play, {})
    down_state = json.loads(state_file.read_text(encoding="utf-8"))
    assert down_state["hybrid"]["m11"]["verification"]["gates"]["k8s_resources"] == {}
    assert down_state["hybrid"]["m11"]["api"]["resources"] == {}
    assert not historical_receipt.exists()
    down_events = read_events(scratch / "down-first.trace.jsonl")
    operations = [event.get("mode") for event in down_events if event.get("kind") == "api"]
    assert operations == ["remove-routing", "remove-resources"]
    deletes = [event for event in down_events if event.get("kind") == "k8s-delete"]
    assert [event["uid"] for event in deletes] == [
        UIDS["server_deployment"], UIDS["client_deployment"], UIDS["cluster_rack1"],
        UIDS["cluster_rack2"], UIDS["advertisement"], UIDS["peer_config"], UIDS["namespace"]
    ]
    qmp_quit = next(index for index, event in enumerate(down_events) if event.get("kind") == "qmp" and event.get("action") == "quit")
    detach = next(index for index, event in enumerate(down_events) if event.get("kind") == "ssh" and event.get("phase") == "ovs-detach")
    assert qmp_quit < detach
    api_remove_resources = next(index for index, event in enumerate(down_events) if event.get("kind") == "api" and event.get("mode") == "remove-resources")
    assert detach < api_remove_resources

    second_root = scratch / "down-repeat"
    second_root.mkdir(mode=0o700)
    second_state = json.loads(state_file.read_text(encoding="utf-8"))
    second_run_dir = second_root / "private-run"
    second_run_dir.mkdir(mode=0o700)
    second_state_file = fixture_state_file(second_root, second_state)
    second_vars = write_vars(second_root, second_state, second_state_file, second_run_dir, bin_dir, os.getuid(), {"student_hybrid_live_guest_names": []})
    second_play = write_playbook(second_root, student_lab, second_vars, tasks / "hybrid-m11-down.yml", "Repeated M11 cleanup")
    runner.run("down-repeat", second_play, {})
    assert not read_events(scratch / "down-repeat.trace.jsonl")

    runner.write_receipt()
    print(f"PASS: full positive, verify/up rechecks, 5 C1 fail-closed controls, and two-pass M11 down; LOG_DIR={scratch}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise
