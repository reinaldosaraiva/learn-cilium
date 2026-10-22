#!/usr/bin/env python3
"""Local adversarial tests for the disabled X05 runtime admission API."""

from __future__ import annotations

import argparse
import contextlib
import copy
import datetime as dt
import fcntl
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import pickle
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
from unittest import mock
from typing import Any


HERE = pathlib.Path(__file__).resolve().parent
LIVE_PATH = HERE / "x05-runtime-live.py"


def load_live():
    spec = importlib.util.spec_from_file_location(
        "x05_runtime_live_selftest_target", LIVE_PATH
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


LIVE = load_live()
LIVE.load_local_test_modules()


# Exact OVS JSON stdout captured in the G0 postcheck on 2026-10-01.
# The five DBs contain 49 singleton Port.interfaces UUID atoms.
CAPTURED_OVS_SET_READBACKS: dict[str, dict[str, bytes]] = {
    'host': {
        'Port': (
            b'{"data":[[["uuid","9e3ee240-d49e-4613-b77b-2abf1a1157b5"],"a4e1cab5fd674_l",["uuid","6ba'
            b'3d0ad-8ce9-4037-a438-a01edf5f4045"],["set",[]],["map",[]]],[["uuid","2d0b4059-7a87-4b19-'
            b'b753-3f6a26ea7f85"],"br-ovn",["uuid","2c0f313b-f2d1-4a29-8f3d-65d437ba0733"],["set",[]],'
            b'["map",[]]],[["uuid","7c0a751b-39d9-4f06-b671-05c39f1d71a9"],"b819cb01b62d4_l",["uuid","'
            b'6523d167-a4f1-42c8-a43a-ac11f8abd2e2"],100,["map",[]]],[["uuid","d8f65483-6848-441d-ae10'
            b'-11ee74aea8ea"],"e8dcc455a2c94_l",["uuid","480b6af2-dd9d-41c1-b8bb-b96efcebb833"],["set"'
            b',[]],["map",[]]],[["uuid","f66e0003-300a-4954-b2b1-09639df49f07"],"41fa6d40b0aa4_l",["uu'
            b'id","27241904-bacb-4e43-9245-78203a9beabd"],["set",[]],["map",[]]],[["uuid","42b8cb94-91'
            b'76-45e8-a97e-dc2ae7480136"],"21a09e6b94894_l",["uuid","49509f2e-6c97-4abb-8a35-49c801768'
            b'cb6"],["set",[]],["map",[]]],[["uuid","2605665c-f476-43c9-8abc-19ba19ae2a85"],"0ba9d3e55'
            b'c6f4_l",["uuid","5934f646-a4ba-4ebd-809d-e60fa658868d"],["set",[]],["map",[]]],[["uuid",'
            b'"ec9959b4-9dbd-4fa8-b16f-f5fe51622655"],"f41ffe2cb4734_l",["uuid","a1bf962c-e852-453e-98'
            b'40-9888575e46af"],["set",[]],["map",[]]],[["uuid","b0472985-f6c7-45c6-912b-d672a40d5919"'
            b'],"7ef905776be34_l",["uuid","f08516fc-5cc0-4b67-ae81-170c936af463"],["set",[]],["map",[]'
            b']],[["uuid","3e781815-ee39-45c3-a74b-c48f13a1807a"],"f771316ba1a34_l",["uuid","194d9c4b-'
            b'c1fc-4d41-b220-37f51de9c0f7"],["set",[]],["map",[]]],[["uuid","9c582506-805c-434d-acd0-1'
            b'2391f1e1b28"],"5dd72743d20b4_l",["uuid","4d54a74f-d222-41dc-b03b-c864af194f9d"],["set",['
            b']],["map",[]]],[["uuid","e4451936-7a23-4db8-a01d-46efad08d659"],"31506ade345e4_l",["uuid'
            b'","1269be97-5da4-4d1f-a283-397128144c47"],["set",[]],["map",[]]],[["uuid","2546496f-8a68'
            b'-441c-b193-c8c9ecf203ae"],"br-ovn-ext",["uuid","50fed4b6-05a4-4a53-9ace-cfcb855fe152"],['
            b'"set",[]],["map",[]]],[["uuid","47746357-ec85-4355-b8d7-d263fee91c81"],"50c238c950094_l"'
            b',["uuid","657de1fb-50cb-4984-8b8b-42a08dae7f2b"],200,["map",[]]]],"headings":["_uuid","n'
            b'ame","interfaces","tag","external_ids"]}\n'
        ),
        'Bridge': (
            b'{"data":[[["uuid","853e86cc-e7c9-4147-b727-44e0867100fd"],"br-ovn",["set",[["uuid","2d0b'
            b'4059-7a87-4b19-b753-3f6a26ea7f85"],["uuid","3e781815-ee39-45c3-a74b-c48f13a1807a"],["uui'
            b'd","9c582506-805c-434d-acd0-12391f1e1b28"],["uuid","9e3ee240-d49e-4613-b77b-2abf1a1157b5'
            b'"],["uuid","b0472985-f6c7-45c6-912b-d672a40d5919"],["uuid","f66e0003-300a-4954-b2b1-0963'
            b'9df49f07"]]]],[["uuid","e2b6f1e2-ef50-4f85-8556-bdedd603e05f"],"br-ovn-ext",["set",[["uu'
            b'id","2546496f-8a68-441c-b193-c8c9ecf203ae"],["uuid","2605665c-f476-43c9-8abc-19ba19ae2a8'
            b'5"],["uuid","42b8cb94-9176-45e8-a97e-dc2ae7480136"],["uuid","47746357-ec85-4355-b8d7-d26'
            b'3fee91c81"],["uuid","7c0a751b-39d9-4f06-b671-05c39f1d71a9"],["uuid","d8f65483-6848-441d-'
            b'ae10-11ee74aea8ea"],["uuid","e4451936-7a23-4db8-a01d-46efad08d659"],["uuid","ec9959b4-9d'
            b'bd-4fa8-b16f-f5fe51622655"]]]]],"headings":["_uuid","name","ports"]}\n'
        ),
    },
    'ovn-chassis-1': {
        'Port': (
            b'{"data":[[["uuid","e88842c8-47f2-4ec3-a9ee-ae79815bad0c"],"ovn-ovn-gw-0",["uuid","b8675c'
            b'77-a093-4fff-832c-b6c0970f2906"],["set",[]],["map",[["ovn-chassis-id","ovn-gw-2@170.168.'
            b'0.4%170.168.0.5"]]]],[["uuid","0172dff3-b81d-4b61-afcb-57ffc04cf489"],"br-ex",["uuid","f'
            b'ef71796-9fe6-46ce-9049-17b9f5f98bfc"],["set",[]],["map",[]]],[["uuid","7fd9b0b3-facf-446'
            b'8-8437-a8758ff56a94"],"br-int",["uuid","8cca8c19-bded-4256-813e-c4fe333694dd"],["set",[]'
            b'],["map",[]]],[["uuid","f2acb53d-2a3f-42df-9ff1-cdb6afa473cb"],"mgc-tenant-vm-p",["uuid"'
            b',"ed19b67a-3afc-462e-a1ff-96bf460f6541"],["set",[]],["map",[]]],[["uuid","e689d89d-5656-'
            b'4bef-804f-6a38faaaf4e1"],"eth2",["uuid","85a859ac-9285-4bf6-ac7b-d817300ba97d"],["set",['
            b']],["map",[]]],[["uuid","ab02945e-1db8-4e11-8bbc-35313e72288b"],"ovn-ovn-ch-0",["uuid","'
            b'9b3dcae3-1ce7-4b98-81b2-91a89ab41a10"],["set",[]],["map",[["ovn-chassis-id","ovn-chassis'
            b'-2@170.168.0.6%170.168.0.5"]]]],[["uuid","471814ce-139e-428d-bfca-a4ffb46796c3"],"ovn-ov'
            b'n-gw-1",["uuid","ba1cbe9f-8a50-4daa-9eed-32d559f2e344"],["set",[]],["map",[["ovn-chassis'
            b'-id","ovn-gw-1@170.168.0.3%170.168.0.5"]]]],[["uuid","755e724f-e8cc-42c5-a73f-4fbd7eb8f7'
            b'd5"],"ovn-evpn-4789",["uuid","dda54d8f-c1cd-43c4-a2b6-4a2bf70430eb"],["set",[]],["map",['
            b'["ovn-evpn-tunnel","true"]]]]],"headings":["_uuid","name","interfaces","tag","external_i'
            b'ds"]}\n'
        ),
        'Bridge': (
            b'{"data":[[["uuid","08d0a5ac-ee4d-4e7e-934e-b664e6e1f7a9"],"br-ex",["set",[["uuid","0172d'
            b'ff3-b81d-4b61-afcb-57ffc04cf489"],["uuid","e689d89d-5656-4bef-804f-6a38faaaf4e1"]]]],[["'
            b'uuid","9774efde-906a-469e-b225-f3f8327902dd"],"br-int",["set",[["uuid","471814ce-139e-42'
            b'8d-bfca-a4ffb46796c3"],["uuid","755e724f-e8cc-42c5-a73f-4fbd7eb8f7d5"],["uuid","7fd9b0b3'
            b'-facf-4468-8437-a8758ff56a94"],["uuid","ab02945e-1db8-4e11-8bbc-35313e72288b"],["uuid","'
            b'e88842c8-47f2-4ec3-a9ee-ae79815bad0c"],["uuid","f2acb53d-2a3f-42df-9ff1-cdb6afa473cb"]]]'
            b']],"headings":["_uuid","name","ports"]}\n'
        ),
    },
    'ovn-chassis-2': {
        'Port': (
            b'{"data":[[["uuid","1ecc6df8-d08e-4e4e-8865-8ff2cd6f288b"],"br-ex",["uuid","383b0843-f603'
            b'-44dc-b734-877c2f8cc392"],["set",[]],["map",[]]],[["uuid","d07ce8ec-4645-4459-8c1e-eac64'
            b'09d9301"],"br-int",["uuid","4e3eaf87-d9e2-4d1b-a42f-b194af06e63a"],["set",[]],["map",[]]'
            b'],[["uuid","c8dc1719-ca60-4515-aeb2-95ae74fb926b"],"ovn-ovn-gw-0",["uuid","e4ad9a48-f757'
            b'-4dcb-bb9b-76b36b3ee1b0"],["set",[]],["map",[["ovn-chassis-id","ovn-gw-2@170.168.0.4%170'
            b'.168.0.6"]]]],[["uuid","e4520e8a-7b0f-4a00-9ed5-5b9d97f9910b"],"ovn-ovn-gw-1",["uuid","4'
            b'b8ce2cc-f6af-4893-b355-233975321dfd"],["set",[]],["map",[["ovn-chassis-id","ovn-gw-1@170'
            b'.168.0.3%170.168.0.6"]]]],[["uuid","7e5246d2-a90e-40a4-a488-e64d46592ea1"],"ovn-evpn-478'
            b'9",["uuid","f95d1bc3-df6e-4f20-bb17-f095ab53fd37"],["set",[]],["map",[["ovn-evpn-tunnel"'
            b',"true"]]]],[["uuid","29d07716-2f6d-4f94-9ea4-cf95ebf33437"],"ovn-ovn-ch-0",["uuid","8f6'
            b'387f6-7e53-4897-b279-41e1ae08df43"],["set",[]],["map",[["ovn-chassis-id","ovn-chassis-1@'
            b'170.168.0.5%170.168.0.6"]]]],[["uuid","24189663-5007-49d9-a071-a4f144422923"],"eth2",["u'
            b'uid","0016510f-89a5-4794-b7b2-8e55fd4d3639"],["set",[]],["map",[]]]],"headings":["_uuid"'
            b',"name","interfaces","tag","external_ids"]}\n'
        ),
        'Bridge': (
            b'{"data":[[["uuid","9f8c366d-5b72-4bea-b94d-a95885ab657f"],"br-ex",["set",[["uuid","1ecc6'
            b'df8-d08e-4e4e-8865-8ff2cd6f288b"],["uuid","24189663-5007-49d9-a071-a4f144422923"]]]],[["'
            b'uuid","2f1b5331-8e8c-4d25-83c5-67558da6e6a6"],"br-int",["set",[["uuid","29d07716-2f6d-4f'
            b'94-9ea4-cf95ebf33437"],["uuid","7e5246d2-a90e-40a4-a488-e64d46592ea1"],["uuid","c8dc1719'
            b'-ca60-4515-aeb2-95ae74fb926b"],["uuid","d07ce8ec-4645-4459-8c1e-eac6409d9301"],["uuid","'
            b'e4520e8a-7b0f-4a00-9ed5-5b9d97f9910b"]]]]],"headings":["_uuid","name","ports"]}\n'
        ),
    },
    'ovn-gw-1': {
        'Port': (
            b'{"data":[[["uuid","2f41c0c8-2dea-4466-a759-64017e2a63b9"],"br-ex",["uuid","3827da02-9573'
            b'-4b92-a255-0c21d58ed19a"],["set",[]],["map",[]]],[["uuid","c5123588-18d8-409e-a22b-673df'
            b'fbc1d2d"],"ovn-ovn-ch-0",["uuid","bea14699-72bd-4aa5-bc8c-57be6c1060f4"],["set",[]],["ma'
            b'p",[["ovn-chassis-id","ovn-chassis-1@170.168.0.5%170.168.0.3"]]]],[["uuid","3625bbd1-e90'
            b'8-447f-a69d-2357d5446a9b"],"eth2",["uuid","7dfb9b86-43fb-466e-8587-fb18266c4468"],["set"'
            b',[]],["map",[]]],[["uuid","d5826871-12ad-4fee-a478-2044faf40356"],"ovn-evpn-4789",["uuid'
            b'","1bc54ee8-d5d2-459b-8044-3ca61d7c8f83"],["set",[]],["map",[["ovn-evpn-tunnel","true"]]'
            b']],[["uuid","18389b52-5564-4c2d-9391-40f25f2fada0"],"patch-ln-mgc-100-to-br-int",["uuid"'
            b',"cb446ab3-2a87-4bf3-92e2-56d0de40b592"],["set",[]],["map",[["ovn-localnet-port","ln-mgc'
            b'-100"]]]],[["uuid","ba73512a-aedb-4314-9a73-8918088918c3"],"patch-br-int-to-ln-mgc-100",'
            b'["uuid","63a0f5c7-70a9-44af-aaec-f8c396026342"],["set",[]],["map",[["ovn-localnet-port",'
            b'"ln-mgc-100"]]]],[["uuid","d650bbf3-9bb4-4a35-a6b2-311a2a1a9a18"],"br-int",["uuid","f1ad'
            b'605e-b744-420e-b045-9003ceea62d8"],["set",[]],["map",[]]],[["uuid","38fbe484-3ce5-4187-a'
            b'12c-fdb575510be4"],"bgpvrf100-ovs",["uuid","6ccd9b30-c39b-4e99-bb64-f51be512e674"],["set'
            b'",[]],["map",[]]],[["uuid","16d75474-ce09-45b9-9870-adefdfa18c48"],"ovn-ovn-ch-1",["uuid'
            b'","d7ca508a-7a06-49c3-8636-040b980bf1a7"],["set",[]],["map",[["ovn-chassis-id","ovn-chas'
            b'sis-2@170.168.0.6%170.168.0.3"]]]],[["uuid","377ec37c-3a42-4cec-a0b2-ac815bc70708"],"ovn'
            b'-ovn-gw-0",["uuid","0102c369-0e27-4b4b-9d48-bd17170a457c"],["set",[]],["map",[["ovn-chas'
            b'sis-id","ovn-gw-2@170.168.0.4%170.168.0.3"]]]]],"headings":["_uuid","name","interfaces",'
            b'"tag","external_ids"]}\n'
        ),
        'Bridge': (
            b'{"data":[[["uuid","4e226028-b92f-4315-8571-eb7e1a3cc3e8"],"br-int",["set",[["uuid","16d7'
            b'5474-ce09-45b9-9870-adefdfa18c48"],["uuid","377ec37c-3a42-4cec-a0b2-ac815bc70708"],["uui'
            b'd","38fbe484-3ce5-4187-a12c-fdb575510be4"],["uuid","ba73512a-aedb-4314-9a73-8918088918c3'
            b'"],["uuid","c5123588-18d8-409e-a22b-673dffbc1d2d"],["uuid","d5826871-12ad-4fee-a478-2044'
            b'faf40356"],["uuid","d650bbf3-9bb4-4a35-a6b2-311a2a1a9a18"]]]],[["uuid","da24354b-824a-47'
            b'95-b11f-e8342a35f835"],"br-ex",["set",[["uuid","18389b52-5564-4c2d-9391-40f25f2fada0"],['
            b'"uuid","2f41c0c8-2dea-4466-a759-64017e2a63b9"],["uuid","3625bbd1-e908-447f-a69d-2357d544'
            b'6a9b"]]]]],"headings":["_uuid","name","ports"]}\n'
        ),
    },
    'ovn-gw-2': {
        'Port': (
            b'{"data":[[["uuid","e3afe3a8-6c10-4087-8dfb-9e00d9ccf718"],"br-ex",["uuid","35c58dec-fde0'
            b'-479e-a223-c44fa0b9cad0"],["set",[]],["map",[]]],[["uuid","6612dab8-0e2f-4865-b1ee-eb75f'
            b'd2cf4ac"],"ovn-ovn-ch-1",["uuid","c0af5335-9c90-4231-9302-06085af22443"],["set",[]],["ma'
            b'p",[["ovn-chassis-id","ovn-chassis-2@170.168.0.6%170.168.0.4"]]]],[["uuid","d98138f1-cba'
            b'f-4a57-8226-c6d5d27aa3b5"],"ovn-ovn-ch-0",["uuid","a843acfe-4a73-4c64-9f45-65471c1d85c4"'
            b'],["set",[]],["map",[["ovn-chassis-id","ovn-chassis-1@170.168.0.5%170.168.0.4"]]]],[["uu'
            b'id","af8eab51-e577-4308-9688-3d7d0c212b62"],"patch-br-int-to-ln-mgc-200",["uuid","f000e6'
            b'76-c0f5-447f-9d95-92fd0d883a38"],["set",[]],["map",[["ovn-localnet-port","ln-mgc-200"]]]'
            b'],[["uuid","74f64af1-f24e-4135-9acb-e938c6adb2bf"],"ovn-evpn-4789",["uuid","a4daef8c-f8f'
            b'5-4bdc-a9d9-cd216e9ab8ac"],["set",[]],["map",[["ovn-evpn-tunnel","true"]]]],[["uuid","8c'
            b'8c66aa-b1b3-4905-ba86-00832a498bf5"],"br-int",["uuid","11a190dd-634d-4903-a8e6-eb2164524'
            b'477"],["set",[]],["map",[]]],[["uuid","9c38e053-44d0-447d-ba3b-11f3ef039651"],"bgpvrf200'
            b'-ovs",["uuid","7e4a5c61-b640-480c-8c00-df28005a2965"],["set",[]],["map",[]]],[["uuid","c'
            b'bb1b27c-3e20-4a6b-9ae3-c4957a8fb019"],"patch-ln-mgc-200-to-br-int",["uuid","94527136-165'
            b'9-44a6-9c8b-c461975d153f"],["set",[]],["map",[["ovn-localnet-port","ln-mgc-200"]]]],[["u'
            b'uid","c3e6c7a4-25f4-4e4c-afaf-54f2c280798b"],"eth2",["uuid","b51f5ab2-7baf-4bf5-a30a-302'
            b'6c2695fed"],["set",[]],["map",[]]],[["uuid","c26fd155-af7a-4514-8543-f4bf6ceae514"],"ovn'
            b'-ovn-gw-0",["uuid","3c4a66cd-800e-4011-ad11-9fa5ef0687bf"],["set",[]],["map",[["ovn-chas'
            b'sis-id","ovn-gw-1@170.168.0.3%170.168.0.4"]]]]],"headings":["_uuid","name","interfaces",'
            b'"tag","external_ids"]}\n'
        ),
        'Bridge': (
            b'{"data":[[["uuid","70eb8e1c-3951-4c6c-9705-a980c8dbbeb1"],"br-ex",["set",[["uuid","c3e6c'
            b'7a4-25f4-4e4c-afaf-54f2c280798b"],["uuid","cbb1b27c-3e20-4a6b-9ae3-c4957a8fb019"],["uuid'
            b'","e3afe3a8-6c10-4087-8dfb-9e00d9ccf718"]]]],[["uuid","e7b09121-2b44-4b32-a951-e655f7153'
            b'918"],"br-int",["set",[["uuid","6612dab8-0e2f-4865-b1ee-eb75fd2cf4ac"],["uuid","74f64af1'
            b'-f24e-4135-9acb-e938c6adb2bf"],["uuid","8c8c66aa-b1b3-4905-ba86-00832a498bf5"],["uuid","'
            b'9c38e053-44d0-447d-ba3b-11f3ef039651"],["uuid","af8eab51-e577-4308-9688-3d7d0c212b62"],['
            b'"uuid","c26fd155-af7a-4514-8543-f4bf6ceae514"],["uuid","d98138f1-cbaf-4a57-8226-c6d5d27a'
            b'a3b5"]]]]],"headings":["_uuid","name","ports"]}\n'
        ),
    },
}


def digest(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def uuid(name: str) -> str:
    value = digest("uuid:" + name)
    return f"{value[:8]}-{value[8:12]}-{value[12:16]}-{value[16:20]}-{value[20:32]}"


def lock_fdinfo_literal(
    *,
    flags: str = "0100002",
    counter: str = "1",
    mode: str = "WRITE",
    pid: str = "4242",
    major: str = "00",
    minor: str = "2a",
    inode: str = "63107",
) -> bytes:
    return (
        "pos:\t0\n"
        f"flags:\t{flags}\n"
        "mnt_id:\t19\n"
        f"ino:\t{inode}\n"
        f"lock:\t{counter}: FLOCK  ADVISORY  {mode} "
        f"{pid} {major}:{minor}:{inode} 0 EOF\n"
    ).encode("ascii")


def ovs_json(rows: list[dict[str, Any]], columns: tuple[str, ...]) -> bytes:
    def encode(value: Any) -> Any:
        if isinstance(value, dict):
            return ["map", [[key, encode(item)] for key, item in sorted(value.items())]]
        if isinstance(value, list):
            return ["set", [encode(item) for item in value]]
        if isinstance(value, tuple) and len(value) == 2 and value[0] == "uuid":
            return ["uuid", value[1]]
        return value

    return json.dumps(
        {
            "headings": list(columns),
            "data": [
                [encode(row.get(column, [])) for column in columns] for row in rows
            ],
        },
        separators=(",", ":"),
    ).encode()


class FakeRunner:
    def __init__(self, config: Any) -> None:
        self.config = config
        self.active = False
        self.marker_run = "20260930T130000Z-4242"
        self.calls: list[dict[str, Any]] = []
        self.setup_rc = 0
        self.setup_foreign = False
        self.cleanup_rc = 0
        self.baseline_verify_rc = 0
        self.malformed_netns = False
        self.nonzero_netns = False
        self.drift: str | None = None
        self.docker_list_count = 0
        self.inspect_count: dict[str, int] = {}
        self.image_count: dict[str, int] = {}
        self.frr_count: dict[str, int] = {}
        self.chassis2_count = 0
        self.m03_ovs_generation = 0
        self.m03_link_generation = 0
        self.m03_daemon_generation = 0
        self.inject_x05_at_docker_list: int | None = None
        self.x05_name_present = False
        self.bad_initial_chassis = False
        self.foreign_frr_scope = False
        self.profile_owner = "mgc-profile-owner"
        self.ids = {
            name: digest("container:" + name)
            for name in (
                *LIVE.PREFLIGHT.MGC_CONTAINER_NAMES,
                "mgc-evpn-client-1",
                "mgc-client-2",
                "mgc-x05-peer-2",
                "p003-os",
            )
        }
        self.image_ids = {
            tag: "sha256:" + digest("image:" + tag) for tag in LIVE.MUTABLE_IMAGE_TAGS
        }
        self.original_image_id = "sha256:" + digest("original-image")
        self.original_image_labels = {
            "org.example.base": "fixture",
            "org.example.version": "1",
        }
        self.original_label_fault: str | None = None
        self.original_image_fault: str | None = None
        self.original_owner_label: str | None = None
        self.original_image_inspect_count = 0

    @property
    def marker_token(self) -> str:
        return "labctl-m03-" + self.marker_run

    def marker_text(self) -> str:
        lines = [
            "version=2",
            "token=" + self.marker_token,
            "run_token=" + self.marker_run,
            "central=ovn-central-az1",
            "lrp=lrp-mgc-tenant",
            "tenant_vrf=ovnvrf-tenant",
            "intent=maintain-vrf",
            "baseline_lrp_maintain_vrf=absent",
            "baseline_lrp_port_name=absent",
            "baseline_chassis_port_mapping=absent",
            "baseline_ls_dynamic_routing_vni=50100",
            *("resource=" + value for value in LIVE.PREFLIGHT.M03_RESOURCE_LINES),
        ]
        return "\n".join(lines) + "\n"

    def write_marker(self) -> None:
        self.config.m03_marker_path.parent.mkdir(parents=True, exist_ok=True)
        self.config.m03_marker_path.write_text(self.marker_text())
        self.config.m03_marker_path.chmod(0o600)

    def result(
        self,
        argv: tuple[str, ...],
        stdout: bytes = b"",
        returncode: int = 0,
        stderr: bytes = b"",
    ) -> Any:
        return LIVE.CommandResult(argv, returncode, stdout, stderr, 0.001)

    def run(
        self,
        argv,
        *,
        env,
        timeout,
        pass_fds=(),
        max_output_bytes=LIVE.MAX_OUTPUT,
    ):
        command = tuple(argv)
        call = {
            "argv": command,
            "env": dict(env),
            "timeout": timeout,
            "pass_fds": tuple(pass_fds),
        }
        self.calls.append(call)
        if command[0] == str(self.config.labctl_path):
            assert tuple(pass_fds) == (9,)
            assert env == {
                **LIVE.BASE_ENV,
                "EVIDENCE_DIR": str(self.config.m03_evidence_path),
                "M03_EVIDENCE_DIR": str(self.config.m03_evidence_path),
                "M03_K01_KUBECONFIG": str(self.config.k01_kubeconfig),
                "M03_LOCK_HELD_FD": "9",
                "M03_P003_KUBECONFIG": str(self.config.p003_kubeconfig),
                "M03_PREFLIGHT_RECEIPT": str(self.config.receipt_path),
                "X05_COORDINATOR_TOKEN": self.config.owner,
            }
            assert os.fstat(9).st_ino == self.config.lock_path.stat().st_ino
            action = command[2]
            m03 = command[-1:] == ("--m03",)
            events = [
                json.loads(line)
                for line in self.config.event_path.read_text().splitlines()
            ]
            if action == "up":
                assert m03 and events[-1]["event"] == "m03-up-intent"
                self.active = True
                self.write_marker()
                if self.setup_foreign:
                    self.marker_run = "20260930T130001Z-9999"
                    self.write_marker()
                return self.result(command, b"setup\n", self.setup_rc)
            if action == "down":
                assert m03 and events[-1]["event"] == "m03-down-intent"
                if self.cleanup_rc == 0:
                    self.active = False
                    with contextlib.suppress(FileNotFoundError):
                        self.config.m03_marker_path.unlink()
                return self.result(command, b"down\n", self.cleanup_rc)
            if action == "verify" and m03:
                return self.result(command, b"verify-m03\n", 0 if self.active else 1)
            if action == "verify" and not m03:
                return self.result(
                    command, b"verify-baseline\n", self.baseline_verify_rc
                )
            raise AssertionError(command)

        assert tuple(pass_fds) == ()
        assert env == LIVE.BASE_ENV
        assert timeout == self.config.command_timeout
        if command[:6] == (
            "docker",
            "container",
            "ls",
            "--all",
            "--no-trunc",
            "--format",
        ):
            self.docker_list_count += 1
            if (
                self.inject_x05_at_docker_list is not None
                and self.docker_list_count >= self.inject_x05_at_docker_list
            ):
                self.x05_name_present = True
            if self.drift == "marker" and self.docker_list_count == 4:
                self.marker_run = "20260930T130002Z-4242"
                self.write_marker()
            names = [*LIVE.PREFLIGHT.MGC_CONTAINER_NAMES, "p003-os"]
            if self.active:
                names.append("mgc-evpn-client-1")
            if self.x05_name_present:
                names.append("mgc-client-2")
            return self.result(
                command,
                b"".join(
                    json.dumps({"Names": name}, separators=(",", ":")).encode() + b"\n"
                    for name in names
                ),
            )
        if command[:3] == ("docker", "container", "inspect"):
            name = command[3]
            self.inspect_count[name] = self.inspect_count.get(name, 0) + 1
            container_id = self.ids[name]
            if (
                self.drift == "identity"
                and name == "ovn-gw-1"
                and self.inspect_count[name] >= 4
            ):
                container_id = digest("replacement:ovn-gw-1")
            labels: dict[str, str] = {}
            state = "running"
            image_id = "sha256:" + digest("container-image:" + name)
            container_config: dict[str, Any]
            if name in LIVE.PREFLIGHT.CLUSTER_NAMES:
                labels = dict(self.original_image_labels)
                if self.original_label_fault == "container-added":
                    labels["org.example.added"] = "container"
                elif self.original_label_fault == "container-overridden":
                    labels["org.example.version"] = "different"
                elif self.original_label_fault == "container-owner":
                    labels[self.original_owner_label or "labctl.mgc.owner"] = "foreign-owner"
                if self.drift == "labels" and self.inspect_count[name] >= 3:
                    labels["org.example.drift"] = "changed"
                if self.original_label_fault == "reordered":
                    labels = dict(reversed(tuple(labels.items())))
                image_id = self.original_image_id
                container_config = {"Labels": labels}
                if self.original_label_fault == "container-missing":
                    container_config.pop("Labels")
            elif name == "mgc-client-1":
                labels = {"labctl.mgc.owner": self.profile_owner}
                container_config = {"Labels": labels}
            elif name == "mgc-evpn-client-1":
                labels = {
                    "labctl.mgc.owner": self.profile_owner,
                    "labctl-m03-owner": (
                        "foreign-owner" if self.setup_foreign else self.marker_token
                    ),
                }
                container_config = {"Labels": labels}
            elif name == "p003-os":
                state = "exited"
                container_config = {"Labels": labels}
            else:
                container_config = {"Labels": labels}
            payload = [
                {
                    "Id": container_id,
                    "State": {"Status": state},
                    "Config": container_config,
                    "Image": image_id,
                }
            ]
            return self.result(command, json.dumps(payload).encode())
        if command[:3] == ("docker", "image", "inspect"):
            tag = command[3]
            if tag == self.original_image_id:
                self.original_image_inspect_count += 1
                image_labels: Any = dict(self.original_image_labels)
                if self.original_image_fault in {"owner", "image-owner"}:
                    image_labels[self.original_owner_label or "labctl.mgc.owner"] = "foreign-owner"
                elif self.original_image_fault == "reordered":
                    image_labels = dict(reversed(tuple(image_labels.items())))
                elif self.drift == "labels" and self.original_image_inspect_count >= 3:
                    image_labels["org.example.drift"] = "changed"
                image_id = tag
                if self.original_image_fault == "id-mismatch":
                    image_id = "sha256:" + digest("mismatched-original-image")
                config: dict[str, Any] = {"Labels": image_labels}
                if self.original_image_fault == "missing-labels":
                    config.pop("Labels")
                elif self.original_image_fault == "malformed-labels":
                    config["Labels"] = {"org.example.version": 1}
                elif self.original_image_fault == "null-labels":
                    config["Labels"] = None
                return self.result(
                    command,
                    json.dumps([{"Id": image_id, "Config": config}]).encode(),
                )
            self.image_count[tag] = self.image_count.get(tag, 0) + 1
            image_id = self.image_ids[tag]
            if self.drift == "image" and self.image_count[tag] >= 3:
                image_id = "sha256:" + digest("replacement:" + tag)
            return self.result(
                command, json.dumps([{"Id": image_id, "RepoTags": [tag]}]).encode()
            )
        if command[0] == "kubectl":
            context = command[4]
            uid = "uid-k01-123" if context == "kind-k01" else "uid-p003-456"
            return self.result(command, uid.encode())
        if command[:2] == ("docker", "exec") and "curl" in command:
            return self.result(command, b"200")
        if command[-4:] == ("ip", "-j", "netns", "list"):
            if self.nonzero_netns and self.active:
                return self.result(command, b"", 3, b"netns failed")
            if self.malformed_netns and self.active:
                return self.result(command, b"not-json")
            return self.result(command, b"[]")
        if command[-5:] == ("ip", "-j", "-d", "link", "show"):
            node = command[2] if command[:2] == ("docker", "exec") else None
            rows = self.ip_links(node)
            return self.result(
                command, json.dumps(rows, separators=(",", ":")).encode()
            )
        if (
            command[:2] == ("docker", "exec")
            and command[3] == "cat"
            and command[4].startswith("/sys/class/net/")
            and command[4].endswith("/iflink")
        ):
            name = command[4].split("/")[-2]
            value = self.link_index(name) + self.m03_link_generation * 100
            return self.result(command, (str(value) + "\n").encode())
        if "ovs-vsctl" in command and "--format=json" in command:
            return self.result(command, self.ovs_readback(command))
        if "ovn-nbctl" in command and "--format=json" in command:
            return self.result(command, self.nb_readback(command))
        if command[:2] == ("ovs-vsctl", "port-to-br"):
            return self.result(command, b"br-ovn\n")
        if command[:2] == ("docker", "exec") and command[3:5] == ("sh", "-c"):
            node = command[2]
            if "pidof" in command[5]:
                offset = self.m03_daemon_generation * 100
                output = (
                    f"zebra\t{31 + offset}\t{3100 + offset}\tzebra -N m03\n"
                    f"bgpd\t{32 + offset}\t{3200 + offset}\tbgpd -N m03\n"
                    f"staticd\t{33 + offset}\t{3300 + offset}\tstaticd -N m03\n".encode()
                    if self.active
                    else b""
                )
                return self.result(command, output)
            paths = command[7:]
            existing: list[str] = []
            if node == "ovn-chassis-1" and self.active:
                existing = [
                    path for path in paths if path in {"/etc/frr/m03", "/run/frr/m03"}
                ]
            return self.result(
                command, ("\n".join(existing) + ("\n" if existing else "")).encode()
            )
        if command[:2] == ("docker", "exec") and command[3:5] == (
            "cat",
            "/etc/frr/frr.conf",
        ):
            node = command[2]
            self.frr_count[node] = self.frr_count.get(node, 0) + 1
            fixture = "frr-gw1.conf" if node == "ovn-gw-1" else "frr-gw2.conf"
            data = (HERE / fixture).read_bytes()
            if self.drift == "frr" and self.frr_count[node] >= 3:
                data += b"\n! drift\n"
            return self.result(command, data)
        if command[:2] == ("docker", "exec") and command[3:6] == (
            "vtysh",
            "-c",
            "show running-config",
        ):
            node = command[2]
            text = "\n".join(LIVE.PREFLIGHT.A_FRR_SCOPES[node]) + "\n"
            if self.foreign_frr_scope:
                text += "route-map FOREIGN permit 10\nexit\n"
            return self.result(command, text.encode())
        raise AssertionError("unexpected fake command: " + repr(command))

    def ip_links(self, node: str | None) -> list[dict[str, Any]]:
        rows = [
            {
                "ifname": "lo",
                "ifindex": 1,
                "iflink": 1,
                "master": None,
                "link_type": "loopback",
                "linkinfo": {"info_kind": "loopback", "info_data": {}},
            }
        ]
        if not self.active:
            return rows
        expected = [
            row
            for row in LIVE.PREFLIGHT.M03_LINKS
            if (
                (node == "ovn-chassis-1" and row[2] == "chassis")
                or (node == "mgc-evpn-client-1" and row[2] == "peer")
            )
        ]
        for name, kind, _role, _expected_node, typed in expected:
            data: dict[str, Any] = {}
            if typed is not None:
                field, value = typed
                data["id" if field == "vni" else field] = value
            rows.append(
                {
                    "ifname": name,
                    "ifalias": self.marker_token,
                    "ifindex": self.link_index(name) + self.m03_link_generation * 100,
                    "iflink": self.link_index(name) + self.m03_link_generation * 100,
                    "master": LIVE.PREFLIGHT.M03_LINK_MASTERS[name],
                    "link_type": "ether",
                    "linkinfo": {"info_kind": kind, "info_data": data},
                }
            )
        if node == "ovn-chassis-1":
            rows.append(
                {
                    "ifname": "ovnvrf-tenant",
                    "ifindex": self.link_index("ovnvrf-tenant")
                    + self.m03_link_generation * 100,
                    "iflink": self.link_index("ovnvrf-tenant")
                    + self.m03_link_generation * 100,
                    "master": None,
                    "link_type": "ether",
                    "linkinfo": {"info_kind": "vrf", "info_data": {"table": 300}},
                }
            )
        return rows

    @staticmethod
    def link_index(name: str) -> int:
        names = [row[0] for row in LIVE.PREFLIGHT.M03_LINKS] + ["ovnvrf-tenant"]
        return names.index(name) + 10

    def ovs_readback(self, command: tuple[str, ...]) -> bytes:
        node = command[2] if command[:2] == ("docker", "exec") else None
        table = command[-1]
        columns = tuple(
            next(value for value in command if value.startswith("--columns="))
            .split("=", 1)[1]
            .split(",")
        )
        rows: list[dict[str, Any]] = []
        if table == "Bridge":
            names = ("br-ovn", "br-ovn-ext") if node is None else ("br-int",)
            rows = []
            for name in names:
                ports = []
                if node is None and name == "br-ovn" and self.active:
                    ports = [("uuid", uuid("m03-port:" + str(self.m03_ovs_generation)))]
                rows.append(
                    {
                        "_uuid": (
                            "uuid",
                            uuid(name if node is None else node + ":" + name),
                        ),
                        "name": name,
                        "ports": ports,
                        "external_ids": (
                            {"labctl-mgc-owner-token": self.profile_owner}
                            if node is None
                            else {}
                        ),
                    }
                )
        elif node is None and table == "Interface":
            if self.active:
                rows = [
                    {
                        "_uuid": (
                            "uuid",
                            uuid("m03-interface:" + str(self.m03_ovs_generation)),
                        ),
                        "name": "veth-m03-host",
                        "external_ids": {
                            "container_id": "mgc-evpn-client-1",
                            "container_iface": "eth1",
                            "labctl-m03-owner": self.marker_token,
                        },
                    }
                ]
        elif node is None and table == "Port":
            if self.active:
                rows = [
                    {
                        "_uuid": (
                            "uuid",
                            uuid("m03-port:" + str(self.m03_ovs_generation)),
                        ),
                        "name": "veth-m03-host",
                        "interfaces": [
                            (
                                "uuid",
                                uuid("m03-interface:" + str(self.m03_ovs_generation)),
                            )
                        ],
                        "tag": [],
                        "external_ids": {},
                    }
                ]
        elif table == "Port":
            rows = []
        elif table == "Interface":
            rows = []
        elif table == "Open_vSwitch":
            external = {
                "ovn-evpn-local-ip": (
                    ("foreign" if self.bad_initial_chassis else "50100-170.168.0.6")
                    if node == "ovn-chassis-2"
                    else "50100-170.168.0.5"
                )
            }
            if node == "ovn-chassis-2":
                self.chassis2_count += 1
                if self.drift == "chassis2" and self.chassis2_count >= 3:
                    external["ovn-evpn-local-ip"] = "foreign"
            if node == "ovn-chassis-1" and self.active:
                external["dynamic-routing-port-mapping"] = (
                    "m03-evpn-" + self.marker_run + "=br-evpn-tenant"
                )
            rows = [
                {"_uuid": ("uuid", uuid("ovs:" + str(node))), "external_ids": external}
            ]
        return ovs_json(rows, columns)

    def nb_readback(self, command: tuple[str, ...]) -> bytes:
        table = command[-2]
        name = command[-1].split("=", 1)[1]
        columns = tuple(
            next(value for value in command if value.startswith("--columns="))
            .split("=", 1)[1]
            .split(",")
        )
        rows: list[dict[str, Any]] = []
        if table == "Logical_Router_Port" and name == "lrp-mgc-tenant":
            options = {}
            if self.active:
                options = {
                    "dynamic-routing-maintain-vrf": "true",
                    "dynamic-routing-port-name": "m03-evpn-" + self.marker_run,
                }
            rows = [{"_uuid": ("uuid", uuid(name)), "name": name, "options": options}]
        elif table == "Logical_Switch" and name == "ls-mgc-tenant":
            rows = [
                {
                    "_uuid": ("uuid", uuid(name)),
                    "name": name,
                    "ports": [("uuid", uuid("a-lsp"))],
                    "other_config": {"dynamic-routing-vni": "50100"},
                }
            ]
        elif table == "Logical_Router" and name == "lr-mgc-tenant":
            rows = [
                {
                    "_uuid": ("uuid", uuid(name)),
                    "name": name,
                    "ports": [("uuid", uuid("lrp-mgc-tenant"))],
                }
            ]
        elif table == "Logical_Switch_Port" and name == "x05-tenant-b-vm":
            rows = []
        return ovs_json(rows, columns)


def make_config(root: pathlib.Path, *, run_hex: str = "a1b2c3") -> Any:
    evidence = root / "evidence" / "P004" / "S002" / run_hex / "08-x05"
    evidence.parent.mkdir(parents=True)
    evidence.parent.chmod(0o700)
    receipt = root / "receipt.txt"
    runtime_source_sha256 = hashlib.sha256(LIVE_PATH.read_bytes()).hexdigest()
    receipt.write_text(
        "k01_uid=uid-k01-123\n"
        "p003_gw_uid=uid-p003-456\n"
        "k01_canary=10/10\n"
        "p003_gw_canary=10/10\n"
        "timestamp=2026-09-30T12:00:00Z\n"
        "host=fakehost\n"
        "runtime_source_sha256=" + runtime_source_sha256 + "\n"
    )
    receipt.chmod(0o600)
    k01 = root / "k01.config"
    p003 = root / "p003.config"
    for path in (k01, p003):
        path.write_text("apiVersion: v1\n")
        path.chmod(0o600)
    state = root / "mgc.json"
    profile_owner = "mgc-profile-owner"
    value = {
        "owner_token": profile_owner,
        **{
            state_key: digest("container:" + name)
            for name, state_key in LIVE.PREFLIGHT.MGC_ID_KEYS.items()
        },
        **{
            state_key: uuid(name)
            for name, state_key in LIVE.PREFLIGHT.MGC_BRIDGE_ID_KEYS.items()
        },
    }
    state.write_text(json.dumps(value))
    state.chmod(0o600)
    meminfo = root / "meminfo"
    meminfo.write_text("MemAvailable:       8388608 kB\n")
    labctl = root / "labctl"
    labctl.write_text("#!/bin/sh\nexit 75\n")
    labctl.chmod(0o700)
    return LIVE.AdmissionConfig(
        run_hex=run_hex,
        evidence_path=evidence,
        receipt_path=receipt,
        k01_kubeconfig=k01,
        p003_kubeconfig=p003,
        lock_path=root / "labctl-mgc-m03.lock",
        state_path=state,
        m03_marker_path=root / "run" / "mgc-m03" / "active",
        x05_marker_path=root / "run" / "mgc-x05" / "active",
        bundle_root=LIVE.HERE.parents[2],
        labctl_path=labctl,
        meminfo_path=meminfo,
        command_timeout=2.5,
        required_uid=os.getuid(),
        test_only_paths=True,
        now=lambda: dt.datetime(2026, 9, 30, 13, 0, tzinfo=dt.timezone.utc),
        hostname=lambda: "fakehost.example",
    )


def expect_error(error_type, function, label: str) -> Exception:
    try:
        function()
    except error_type as exc:
        return exc
    raise AssertionError("expected failure: " + label)


def read_events(path: pathlib.Path) -> list[dict[str, Any]]:
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    previous = "0" * 64
    for sequence, row in enumerate(rows, 1):
        assert row["sequence"] == sequence
        assert row["previous_sha256"] == previous
        body = {key: value for key, value in row.items() if key != "event_sha256"}
        assert LIVE._digest(body) == row["event_sha256"]
        previous = row["event_sha256"]
    return rows


def close_retained_test_descriptors(session: Any, *, close_fd9: bool = True) -> None:
    """Release descriptors deliberately retained by production incident handling."""
    keeper = session._lock_keeper_fd
    if close_fd9:
        with contextlib.suppress(OSError):
            os.close(9)
    if keeper is not None:
        with contextlib.suppress(OSError):
            os.close(keeper)
    session._lock_fd = None
    session._lock_keeper_fd = None


def assert_competing_lock_blocked(path: pathlib.Path) -> None:
    probe = os.open(path, os.O_RDWR)
    try:
        expect_error(
            BlockingIOError,
            lambda: fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB),
            "competing exclusive lock",
        )
    finally:
        os.close(probe)


def happy_path() -> None:
    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        session = LIVE.AdmissionSession(config, runner)
        with session:
            prepared = session.admit()
            assert prepared.active and not prepared.consumed
            assert session.consume(prepared) is prepared
            assert prepared.active and prepared.consumed
            snapshot_path = prepared.snapshot_path
            assert runner.active
            assert stat.S_IMODE(snapshot_path.stat().st_mode) == 0o600
            assert stat.S_IMODE(config.evidence_path.stat().st_mode) == 0o700
            snapshot = LIVE.PREFLIGHT.read_snapshot(
                snapshot_path, required_uid=config.required_uid
            )
            report = LIVE.PREFLIGHT.validate_snapshot(snapshot)
            assert report["authorizes_mutation"] is False
            assert snapshot["mode"] == "live-observed"
            assert len(snapshot["before"]) == 43
            assert set(snapshot["sections"]["docker"]["resolved_images"]) == set(
                LIVE.MUTABLE_IMAGE_TAGS
            )
        assert not runner.active
        assert not prepared.active and not prepared.consumed
        session.close()
        lifecycle = [
            call["argv"][2:]
            for call in runner.calls
            if call["argv"][0] == str(config.labctl_path)
        ]
        assert lifecycle == [
            ("up", "--m03"),
            ("verify", "--m03"),
            ("down", "--m03"),
            ("verify",),
        ]
        assert all(call["timeout"] == 2.5 for call in runner.calls)
        observed_argv = {call["argv"] for call in runner.calls}
        assert (
            "docker",
            "exec",
            "ovn-chassis-1",
            "ip",
            "-j",
            "netns",
            "list",
        ) in observed_argv
        assert (
            "docker",
            "exec",
            "ovn-chassis-2",
            "ip",
            "-j",
            "netns",
            "list",
        ) in observed_argv
        assert ("ip", "-j", "netns", "list") not in observed_argv
        events = read_events(config.event_path)
        names = [row["event"] for row in events]
        assert names.index("m03-up-intent") < names.index("m03-up-outcome")
        assert names.index("m03-up-outcome") < names.index("m03-up-readback")
        assert names.index("m03-pre-down-readback") < names.index("m03-down-intent")
        assert names.index("m03-down-intent") < names.index("m03-down-outcome")
        assert names[-1] == "lock-release-intent"
        lock_fd = os.open(config.lock_path, os.O_RDWR)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            os.close(lock_fd)


def prepared_authority_checks() -> None:
    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        session = LIVE.AdmissionSession(config, runner)
        with session:
            prepared = session.admit()
            expect_error(TypeError, lambda: copy.copy(prepared), "copied capability")
            expect_error(
                TypeError, lambda: copy.deepcopy(prepared), "deep-copied capability"
            )
            expect_error(
                TypeError, lambda: pickle.dumps(prepared), "serialized capability"
            )
            expect_error(
                LIVE.AdmissionError,
                lambda: session.consume(LIVE.PREFLIGHT.synthetic_fixture()),
                "serialized fixture used as authority",
            )
            session.consume(prepared)
            event_bytes = config.event_path.read_bytes()
            call_count = len(runner.calls)
            with mock.patch.object(
                session,
                "_identity_detail",
                side_effect=AssertionError("duplicate consume reached lock proof"),
            ):
                expect_error(
                    LIVE.AdmissionError,
                    lambda: session.consume(prepared),
                    "duplicate prepared admission consumption",
                )
            assert config.event_path.read_bytes() == event_bytes
            assert len(runner.calls) == call_count
            assert prepared.active and prepared.consumed
            expect_error(
                LIVE.AdmissionError,
                lambda: session.consume(prepared),
                "repeated duplicate prepared admission consumption",
            )
            assert prepared.active and prepared.consumed
        expect_error(
            LIVE.AdmissionError,
            lambda: session.consume(prepared),
            "capability used after owning session closed",
        )

    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        session = LIVE.AdmissionSession(config, runner)

        def tampered_snapshot() -> None:
            with session:
                prepared = session.admit()
                with prepared.snapshot_path.open("ab") as stream:
                    stream.write(b" \n")
                    stream.flush()
                    os.fsync(stream.fileno())
                expect_error(
                    LIVE.AdmissionIncident,
                    lambda: session.consume(prepared),
                    "changed durable snapshot",
                )

        expect_error(
            LIVE.AdmissionIncident, tampered_snapshot, "tampered snapshot at close"
        )
        assert runner.active
        assert not any(call["argv"][2:4] == ("down", "--m03") for call in runner.calls)


def concurrent_consume_check() -> None:
    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        session = LIVE.AdmissionSession(config, runner)
        with session:
            prepared = session.admit()
            barrier = threading.Barrier(3)
            outcomes: list[tuple[str, object]] = []
            outcomes_lock = threading.Lock()

            def consume() -> None:
                barrier.wait()
                try:
                    result: object = session.consume(prepared)
                except Exception as exc:
                    outcome = ("error", exc)
                else:
                    outcome = ("accepted", result)
                with outcomes_lock:
                    outcomes.append(outcome)

            threads = [threading.Thread(target=consume) for _ in range(2)]
            for thread in threads:
                thread.start()
            barrier.wait()
            for thread in threads:
                thread.join(timeout=10)
                assert not thread.is_alive()
            accepted = [value for status, value in outcomes if status == "accepted"]
            rejected = [value for status, value in outcomes if status == "error"]
            assert accepted == [prepared]
            assert len(rejected) == 1 and isinstance(
                rejected[0], LIVE.AdmissionError
            )
            assert sum(
                row["event"] == "prepared-consume-pass"
                for row in read_events(config.event_path)
            ) == 1


def execution_producer_happy_path() -> None:
    """Continuing evidence stays detached while the original producer advances."""
    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        session = LIVE.AdmissionSession(config, runner)
        with session:
            prepared = session.admit()
            expect_error(
                LIVE.AdmissionError,
                lambda: session.verify_execution(prepared),
                "unconsumed execution verification",
            )
            expect_error(
                LIVE.AdmissionError,
                lambda: prepared.execution_session,
                "unconsumed execution producer",
            )
            assert session._execution_failure is None
            session.consume(prepared)
            session.verify_execution(prepared)
            assert prepared.execution_session is session
            first = session.execution_context(prepared)
            assert first["authorizes_mutation"] is False
            assert first["producer"] == {
                "run_hex": config.run_hex,
                "owner": config.owner,
                "paths": {
                    "evidence": str(config.evidence_path),
                    "events": str(config.event_path),
                    "snapshot": str(config.snapshot_path),
                    "receipt": str(config.receipt_path),
                    "k01_kubeconfig": str(config.k01_kubeconfig),
                    "p003_kubeconfig": str(config.p003_kubeconfig),
                },
            }
            json.dumps(first, allow_nan=False)
            original_profile_owner = first["anchors"]["profile_owner"]
            first["anchors"]["profile_owner"] = "detached-change"
            first["snapshot"]["owner"] = "detached-change"
            second = session.execution_context(prepared)
            assert second["anchors"]["profile_owner"] == original_profile_owner
            assert second["snapshot"]["owner"] == config.owner

            runner.x05_name_present = True
            config.x05_marker_path.parent.mkdir(parents=True, exist_ok=True)
            config.x05_marker_path.write_text("owned-x05-in-progress\n")
            config.x05_marker_path.chmod(0o600)
            session.verify_execution(prepared)
            record = session.record_execution_event(
                prepared,
                "x05-window-opened",
                {"gate": "G1", "samples": [1, 2], "ok": True},
            )
            assert record["event"] == "x05-window-opened"
            assert record["detail"]["producer"] == {
                "run_hex": config.run_hex,
                "owner": config.owner,
                "evidence_path": str(config.evidence_path),
            }
            assert record["detail"]["detail"] == {
                "gate": "G1",
                "samples": [1, 2],
                "ok": True,
            }
            assert record["detail"]["admission"]["event_head_sha256"] == record[
                "previous_sha256"
            ]
            assert session.execution_context(prepared)["admission"][
                "event_head_sha256"
            ] == record["event_sha256"]
            runner.x05_name_present = False
            config.x05_marker_path.unlink()
        assert not runner.active
        expect_error(
            LIVE.AdmissionError,
            lambda: session.verify_execution(prepared),
            "closed execution verification",
        )
        expect_error(
            LIVE.AdmissionError,
            lambda: prepared.execution_session,
            "closed execution producer",
        )
        execution_rows = [
            row
            for row in read_events(config.event_path)
            if row["event"] == "x05-window-opened"
        ]
        assert len(execution_rows) == 1


def execution_detail_validation_checks() -> None:
    """Malformed caller detail fails before any authority read or log write."""
    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        with LIVE.AdmissionSession(config, runner) as session:
            prepared = session.admit()
            session.consume(prepared)
            before = config.event_path.read_bytes()
            deep: dict[str, Any] = {}
            cursor = deep
            for _ in range(LIVE.EXECUTION_DETAIL_MAX_DEPTH + 1):
                child: dict[str, Any] = {}
                cursor["level"] = child
                cursor = child
            cycle: dict[str, Any] = {}
            cycle["cycle"] = cycle
            invalid_details = (
                {"owner": "substitute"},
                {"nested": {"bundle_manifest_sha256": "0" * 64}},
                {"number": float("nan")},
                {"number": float("inf")},
                {"value": object()},
                {"value": prepared},
                {"value": lambda: None},
                {"value": (1, 2)},
                {1: "non-string"},
                deep,
                cycle,
                {"payload": "x" * (LIVE.EXECUTION_DETAIL_MAX_BYTES + 1)},
                {
                    "items": list(range(LIVE.EXECUTION_DETAIL_MAX_ITEMS + 1))
                },
            )
            invalid_events = (
                "execution-window",
                "x05-",
                "x05-UPPER",
                "x05-" + "a" * LIVE.EXECUTION_EVENT_MAX_LENGTH,
            )
            blocked = AssertionError("invalid detail reached execution authority I/O")
            with (
                mock.patch.object(
                    session, "_verify_execution_locked", side_effect=blocked
                ),
                mock.patch.object(session.events, "append", side_effect=blocked),
            ):
                for detail in invalid_details:
                    expect_error(
                        LIVE.AdmissionError,
                        lambda detail=detail: session.record_execution_event(
                            prepared, "x05-invalid-detail", detail
                        ),
                        "invalid execution detail",
                    )
                for event in invalid_events:
                    expect_error(
                        LIVE.AdmissionError,
                        lambda event=event: session.record_execution_event(
                            prepared, event, {"valid": True}
                        ),
                        "invalid execution event namespace",
                    )
            assert config.event_path.read_bytes() == before
            assert session._execution_failure is None
            session.verify_execution(prepared)
            session.record_execution_event(
                prepared, "x05-validation-complete", {"valid": True}
            )


def execution_capability_rejections() -> None:
    """Foreign calls cannot poison the one genuine consumed capability."""
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        first_config = make_config(root / "first")
        first_runner = FakeRunner(first_config)
        first_session = LIVE.AdmissionSession(first_config, first_runner)
        with first_session:
            first_prepared = first_session.admit()
            expect_error(
                TypeError, lambda: copy.copy(first_prepared), "execution copy"
            )
            expect_error(
                TypeError,
                lambda: copy.deepcopy(first_prepared),
                "execution deep copy",
            )
            expect_error(
                TypeError,
                lambda: pickle.dumps(first_prepared),
                "execution serialization",
            )
            expect_error(
                LIVE.AdmissionError,
                lambda: first_session.verify_execution(
                    LIVE.PREFLIGHT.synthetic_fixture()
                ),
                "serialized evidence as execution authority",
            )
            assert first_session._execution_failure is None
            first_session.consume(first_prepared)
            first_session.verify_execution(first_prepared)
        expect_error(
            LIVE.AdmissionError,
            lambda: first_session.verify_execution(first_prepared),
            "stale execution capability",
        )

        second_config = make_config(root / "second", run_hex="d4e5f6")
        second_runner = FakeRunner(second_config)
        with LIVE.AdmissionSession(second_config, second_runner) as second_session:
            second_prepared = second_session.admit()
            expect_error(
                LIVE.AdmissionError,
                lambda: second_session.verify_execution(first_prepared),
                "foreign genuine execution capability",
            )
            assert second_session._execution_failure is None
            second_session.consume(second_prepared)
            second_session.verify_execution(second_prepared)


def execution_helper_authority_sticky_checks() -> None:
    """Observed helper loss is terminal only for the genuine consumed capability."""
    for scope in ("instance", "class"):
        for name in ("_verify_bundle", "_assert_origin_bindings_locked"):
            with tempfile.TemporaryDirectory() as directory:
                config = make_config(pathlib.Path(directory))
                runner = FakeRunner(config)
                session = LIVE.AdmissionSession(config, runner)
                session.__enter__()
                prepared = session.admit()
                session.consume(prepared)
                event_bytes = config.event_path.read_bytes()
                calls: list[str] = []
                owner = session if scope == "instance" else type(session)
                attributes = vars(owner)
                existed = name in attributes
                original = attributes.get(name)

                def substitute(*args, **kwargs):
                    calls.append("substitute reached")
                    return "foreign"

                setattr(owner, name, substitute)
                try:
                    first = expect_error(
                        LIVE.AdmissionIncident,
                        lambda: session.verify_execution(prepared),
                        f"{scope} {name} authority loss",
                    )
                finally:
                    if existed:
                        setattr(owner, name, original)
                    else:
                        delattr(owner, name)
                failure = session._execution_failure
                assert calls == [] and failure is not None
                assert str(first) == failure
                for label, action in (
                    ("verify", lambda: session.verify_execution(prepared)),
                    ("producer", lambda: prepared.execution_session),
                    ("context", lambda: session.execution_context(prepared)),
                    (
                        "publish",
                        lambda: session.record_execution_event(
                            prepared, "x05-after-helper-loss", {"blocked": True}
                        ),
                    ),
                ):
                    replay = expect_error(
                        LIVE.AdmissionIncident,
                        action,
                        f"{scope} {name} sticky {label}",
                    )
                    assert str(replay) == failure
                assert config.event_path.read_bytes() == event_bytes
                session.close()
                assert not runner.active

    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        with LIVE.AdmissionSession(config, runner) as session:
            prepared = session.admit()
            calls: list[str] = []

            def substitute(*args, **kwargs):
                calls.append("substitute reached")

            session._assert_origin_bindings_locked = substitute
            try:
                expect_error(
                    LIVE.AdmissionIncident,
                    lambda: session.verify_execution(prepared),
                    "unconsumed helper authority loss",
                )
            finally:
                del session._assert_origin_bindings_locked
            assert calls == []
            assert session._execution_failure is None
            session.consume(prepared)
            session.verify_execution(prepared)


def execution_immutable_drift_checks() -> None:
    """Every original durable binding fails sticky before another effect."""
    for attribute in ("receipt_path", "k01_kubeconfig", "p003_kubeconfig"):
        with tempfile.TemporaryDirectory() as directory:
            config = make_config(pathlib.Path(directory))
            runner = FakeRunner(config)
            session = LIVE.AdmissionSession(config, runner)
            session.__enter__()
            prepared = session.admit()
            session.consume(prepared)
            path = getattr(config, attribute)
            saved = path.read_bytes()
            path.write_bytes(saved + b"drift\n")
            expect_error(
                LIVE.AdmissionIncident,
                lambda: session.verify_execution(prepared),
                attribute + " execution drift",
            )
            path.write_bytes(saved)
            path.chmod(0o600)
            expect_error(
                LIVE.AdmissionIncident,
                lambda: session.verify_execution(prepared),
                attribute + " sticky execution drift",
            )
            session.close()
            assert not runner.active

    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        session = LIVE.AdmissionSession(config, runner)
        session.__enter__()
        prepared = session.admit()
        session.consume(prepared)
        with mock.patch.object(session, "_verify_bundle", return_value="foreign"):
            expect_error(
                LIVE.AdmissionIncident,
                lambda: session.verify_execution(prepared),
                "reviewed bundle execution drift",
            )
        expect_error(
            LIVE.AdmissionIncident,
            lambda: session.verify_execution(prepared),
            "sticky reviewed bundle execution drift",
        )
        session.close()
        assert not runner.active

    for replacement in (False, True):
        with tempfile.TemporaryDirectory() as directory:
            config = make_config(pathlib.Path(directory))
            runner = FakeRunner(config)
            session = LIVE.AdmissionSession(config, runner)
            session.__enter__()
            prepared = session.admit()
            session.consume(prepared)
            if replacement:
                substitute = prepared.snapshot_path.with_name("replacement.json")
                substitute.write_bytes(prepared.snapshot_path.read_bytes())
                substitute.chmod(0o600)
                os.replace(substitute, prepared.snapshot_path)
                label = "snapshot inode drift"
            else:
                with prepared.snapshot_path.open("ab") as stream:
                    stream.write(b" ")
                    stream.flush()
                    os.fsync(stream.fileno())
                label = "snapshot raw digest drift"
            expect_error(
                LIVE.AdmissionIncident,
                lambda: session.verify_execution(prepared),
                label,
            )
            expect_error(
                LIVE.AdmissionIncident,
                session.close,
                label + " cleanup retention",
            )
            assert runner.active
            assert not any(
                call["argv"][2:4] == ("down", "--m03") for call in runner.calls
            )


def execution_log_tamper_checks() -> None:
    """Well-formed, hash-corrupt, and torn foreign tails remain unblessed."""
    for kind in ("well-formed", "hash", "torn"):
        with tempfile.TemporaryDirectory() as directory:
            config = make_config(pathlib.Path(directory))
            runner = FakeRunner(config)
            session = LIVE.AdmissionSession(config, runner)
            session.__enter__()
            prepared = session.admit()
            session.consume(prepared)
            if kind == "well-formed":
                session.events.append("x05-out-of-band", {"valid": True})
            elif kind == "hash":
                raw = config.event_path.read_bytes()
                changed = raw.replace(b"lock-acquired", b"lock-acquireD", 1)
                assert changed != raw and len(changed) == len(raw)
                with config.event_path.open("r+b") as stream:
                    stream.write(changed)
                    stream.flush()
                    os.fsync(stream.fileno())
            else:
                descriptor = os.open(config.event_path, os.O_WRONLY | os.O_APPEND)
                try:
                    os.write(descriptor, b'{"torn":')
                    os.fsync(descriptor)
                finally:
                    os.close(descriptor)
            foreign_bytes = config.event_path.read_bytes()
            expect_error(
                LIVE.AdmissionIncident,
                lambda: session.verify_execution(prepared),
                kind + " event-log drift",
            )
            expect_error(
                LIVE.AdmissionIncident,
                lambda: session.record_execution_event(
                    prepared, "x05-after-tamper", {"kind": kind}
                ),
                kind + " sticky event-log drift",
            )
            expect_error(
                LIVE.AdmissionIncident,
                session.close,
                kind + " event-log cleanup retention",
            )
            assert config.event_path.read_bytes().startswith(foreign_bytes)
            assert runner.active
            assert not any(
                call["argv"][2:4] == ("down", "--m03") for call in runner.calls
            )


def execution_append_publication_drift() -> None:
    """A drift after fsync cannot publish the intended head into the capability."""
    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        session = LIVE.AdmissionSession(config, runner)
        session.__enter__()
        prepared = session.admit()
        session.consume(prepared)
        original_head = prepared._event_head
        original_count = prepared._event_count
        original_publisher = session.record_execution_event.__func__
        assert original_publisher is LIVE.AdmissionSession.record_execution_event
        event_fd = session.events._fd
        assert event_fd is not None
        event_info = os.fstat(event_fd)
        event_identity = (event_info.st_dev, event_info.st_ino)
        path_info = config.event_path.stat()
        assert event_identity == (path_info.st_dev, path_info.st_ino)
        original_fsync = os.fsync
        drifted = False
        reached_seam = 0

        def fsync_and_drift_snapshot(descriptor: int) -> None:
            nonlocal drifted, reached_seam
            original_fsync(descriptor)
            if drifted or descriptor != event_fd:
                return
            current = os.fstat(descriptor)
            if (current.st_dev, current.st_ino) != event_identity:
                return
            lines = config.event_path.read_bytes().splitlines(keepends=True)
            if not lines:
                return
            record = json.loads(lines[-1])
            wrapped_detail = record.get("detail", {})
            if (
                record.get("event") != "x05-publication-window"
                or record.get("sequence") != original_count + 1
                or record.get("previous_sha256") != original_head
                or wrapped_detail.get("detail") != {"phase": "after-fsync"}
            ):
                return
            assert lines[-1] == LIVE._canonical_bytes(record) + b"\n"
            reached_seam += 1
            drifted = True
            with prepared.snapshot_path.open("ab") as stream:
                stream.write(b" ")
                stream.flush()
                original_fsync(stream.fileno())

        with mock.patch.object(LIVE.os, "fsync", side_effect=fsync_and_drift_snapshot):
            expect_error(
                LIVE.AdmissionIncident,
                lambda: session.record_execution_event(
                    prepared, "x05-publication-window", {"phase": "after-fsync"}
                ),
                "append-to-publication evidence drift",
            )
        assert drifted
        assert reached_seam == 1
        assert session.record_execution_event.__func__ is original_publisher
        assert prepared._event_head == original_head
        assert prepared._event_count == original_count
        assert sum(
            row["event"] == "x05-publication-window"
            for row in read_events(config.event_path)
        ) == 1
        expect_error(
            LIVE.AdmissionIncident,
            lambda: session.verify_execution(prepared),
            "sticky append-to-publication refusal",
        )
        expect_error(
            LIVE.AdmissionIncident,
            session.close,
            "append-to-publication cleanup retention",
        )
        assert runner.active


def execution_lock_observer_check() -> None:
    """Continuing verification reuses the original observational OFD proof."""
    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        session = LIVE.AdmissionSession(config, runner)
        session.__enter__()
        prepared = session.admit()
        session.consume(prepared)
        with mock.patch.object(
            LIVE,
            "_read_lock_fdinfo_bytes",
            side_effect=OSError("forced observational failure"),
        ) as observer:
            expect_error(
                LIVE.AdmissionIncident,
                lambda: session.verify_execution(prepared),
                "continuing OFD observation loss",
            )
        assert observer.called
        expect_error(
            LIVE.AdmissionIncident,
            lambda: session.record_execution_event(
                prepared, "x05-after-lock-loss", {"blocked": True}
            ),
            "sticky continuing OFD observation loss",
        )
        expect_error(
            LIVE.AdmissionIncident,
            session.close,
            "continuing OFD observation cleanup retention",
        )
        assert runner.active
        assert_competing_lock_blocked(config.lock_path)
        close_retained_test_descriptors(session)


def concurrent_execution_events_check() -> None:
    """Legitimate concurrent callers publish one contiguous producer chain."""
    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        with LIVE.AdmissionSession(config, runner) as session:
            prepared = session.admit()
            session.consume(prepared)
            initial_count = prepared._event_count
            barrier = threading.Barrier(9)
            outcomes: list[tuple[int, object]] = []
            outcomes_lock = threading.Lock()

            def append(index: int) -> None:
                barrier.wait()
                try:
                    outcome: object = session.record_execution_event(
                        prepared,
                        "x05-concurrent-sample",
                        {"index": index},
                    )
                except Exception as exc:
                    outcome = exc
                with outcomes_lock:
                    outcomes.append((index, outcome))

            threads = [threading.Thread(target=append, args=(index,)) for index in range(8)]
            for thread in threads:
                thread.start()
            barrier.wait()
            for thread in threads:
                thread.join(timeout=20)
                assert not thread.is_alive()
            assert len(outcomes) == 8
            assert all(isinstance(outcome, dict) for _, outcome in outcomes)
            records = [outcome for _, outcome in outcomes]
            assert sorted(record["sequence"] for record in records) == list(
                range(initial_count + 1, initial_count + 9)
            )
            rows = read_events(config.event_path)
            samples = [row for row in rows if row["event"] == "x05-concurrent-sample"]
            assert len(samples) == 8
            assert {row["detail"]["detail"]["index"] for row in samples} == set(
                range(8)
            )
            assert prepared._event_count == initial_count + 8
            session.verify_execution(prepared)


def execution_close_verify_race() -> None:
    """Close and continuing verification serialize to completion or refusal."""
    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        session = LIVE.AdmissionSession(config, runner)
        session.__enter__()
        prepared = session.admit()
        session.consume(prepared)
        barrier = threading.Barrier(3)
        outcomes: dict[str, object] = {}
        outcomes_lock = threading.Lock()

        def verify() -> None:
            barrier.wait()
            try:
                session.verify_execution(prepared)
            except Exception as exc:
                outcome: object = exc
            else:
                outcome = "verified"
            with outcomes_lock:
                outcomes["verify"] = outcome

        def close() -> None:
            barrier.wait()
            try:
                session.close()
            except Exception as exc:
                outcome: object = exc
            else:
                outcome = "closed"
            with outcomes_lock:
                outcomes["close"] = outcome

        threads = [threading.Thread(target=verify), threading.Thread(target=close)]
        for thread in threads:
            thread.start()
        barrier.wait()
        for thread in threads:
            thread.join(timeout=20)
            assert not thread.is_alive()
        assert outcomes["close"] == "closed"
        assert outcomes["verify"] == "verified" or isinstance(
            outcomes["verify"], LIVE.AdmissionError
        )
        assert session._closed and not runner.active
        expect_error(
            LIVE.AdmissionError,
            lambda: session.verify_execution(prepared),
            "verification after close race",
        )


def continuing_marker_cleanup_guard() -> None:
    """Owned X05 presence is allowed during execution but blocks M03 cleanup."""
    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        session = LIVE.AdmissionSession(config, runner)
        session.__enter__()
        prepared = session.admit()
        session.consume(prepared)
        runner.x05_name_present = True
        config.x05_marker_path.parent.mkdir(parents=True, exist_ok=True)
        config.x05_marker_path.write_text("owned-x05-in-progress\n")
        config.x05_marker_path.chmod(0o600)
        session.verify_execution(prepared)
        session.record_execution_event(
            prepared, "x05-owned-effects-present", {"present": True}
        )
        expect_error(
            LIVE.AdmissionIncident,
            session.close,
            "owned X05 marker retains M03 cleanup",
        )
        assert runner.active
        assert config.x05_marker_path.is_file()
        assert not any(
            call["argv"][2:4] == ("down", "--m03") for call in runner.calls
        )


def full_inventory_race_checks() -> None:
    for injection_count, published in ((4, False), (5, True)):
        with tempfile.TemporaryDirectory() as directory:
            config = make_config(pathlib.Path(directory))
            runner = FakeRunner(config)
            runner.inject_x05_at_docker_list = injection_count

            def run() -> None:
                with LIVE.AdmissionSession(config, runner) as session:
                    session.admit()

            expect_error(
                LIVE.AdmissionError,
                run,
                "43-resource injection at read " + str(injection_count),
            )
            assert config.snapshot_path.exists() is published
            assert runner.x05_name_present and runner.active
            assert not any(
                call["argv"][2:4] == ("down", "--m03") for call in runner.calls
            )
            if published:
                report = LIVE.PREFLIGHT.validate_snapshot(
                    LIVE.PREFLIGHT.read_snapshot(
                        config.snapshot_path, required_uid=config.required_uid
                    )
                )
                assert report["authorizes_mutation"] is False


def initial_baseline_rejections() -> None:
    for attribute in ("bad_initial_chassis", "foreign_frr_scope"):
        with tempfile.TemporaryDirectory() as directory:
            config = make_config(pathlib.Path(directory))
            runner = FakeRunner(config)
            setattr(runner, attribute, True)

            def run() -> None:
                with LIVE.AdmissionSession(config, runner) as session:
                    session.admit()

            expect_error(LIVE.AdmissionError, run, attribute)
            assert not any(
                call["argv"][0] == str(config.labctl_path) for call in runner.calls
            )


def original_image_label_cases() -> None:
    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        runner.original_image_fault = "reordered"
        collector = LIVE.LiveCollector(config, runner)
        g0 = collector.g0()
        assert set(g0["mgc"]["original_image_bindings"]) == set(
            LIVE.PREFLIGHT.CLUSTER_NAMES
        )
        assert g0["mgc"]["container_labels"]["ovn-gw-1"] == {
            "org.example.base": "fixture",
            "org.example.version": "1",
        }

    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        runner.original_image_labels = {}
        runner.original_image_fault = "null-labels"
        LIVE.LiveCollector(config, runner).g0()

    for fault in (
        "container-added",
        "container-overridden",
        "container-missing",
        "missing-labels",
        "malformed-labels",
        "id-mismatch",
    ):
        with tempfile.TemporaryDirectory() as directory:
            config = make_config(pathlib.Path(directory))
            runner = FakeRunner(config)
            if fault.startswith("container-"):
                runner.original_label_fault = fault
            else:
                runner.original_image_fault = fault
            collector = LIVE.LiveCollector(config, runner)
            expect_error(
                LIVE.AdmissionError,
                collector.g0,
                "original image label " + fault,
            )
            assert not any(
                call["argv"][0] == str(config.labctl_path) for call in runner.calls
            )

    for owner_label in sorted(LIVE.PREFLIGHT.ORIGINAL_OWNERSHIP_LABELS):
        with tempfile.TemporaryDirectory() as directory:
            config = make_config(pathlib.Path(directory))
            runner = FakeRunner(config)
            runner.original_owner_label = owner_label
            runner.original_label_fault = "container-owner"
            runner.original_image_fault = "owner"
            expect_error(
                LIVE.AdmissionError,
                LIVE.LiveCollector(config, runner).g0,
                "inherited original ownership label " + owner_label,
            )
            assert not any(
                call["argv"][0] == str(config.labctl_path) for call in runner.calls
            )


def continuing_image_label_drift() -> None:
    """Keep admission and continuing-capability label checks at their seams."""
    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        session = LIVE.AdmissionSession(config, runner)
        with session:
            prepared = session.admit()
            runner.drift = "labels"
            try:
                incident = expect_error(
                    LIVE.AdmissionIncident,
                    lambda: session.consume(prepared),
                    "original image label drift before consumption",
                )
                assert "runtime identity changed before consumption" in str(incident)
                assert not prepared._consumed
                assert runner.active
            finally:
                runner.drift = None
        assert runner.active is False
        assert sum(
            call["argv"][2:4] == ("down", "--m03") for call in runner.calls
        ) == 1

    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        session = LIVE.AdmissionSession(config, runner)

        def run_postconsume_drift() -> None:
            with session:
                prepared = session.admit()
                session.consume(prepared)
                assert prepared.consumed
                runner.drift = "labels"
                calls_before_verify = list(runner.calls)
                session.verify_execution(prepared)
                assert runner.calls == calls_before_verify
                assert runner.active

        try:
            incident = expect_error(
                LIVE.AdmissionIncident,
                run_postconsume_drift,
                "original image label drift before cleanup",
            )
            assert str(incident) == (
                "M03 ownership changed before cleanup; state retained"
            )
            assert runner.active is True
            assert not any(
                call["argv"][2:4] == ("down", "--m03") for call in runner.calls
            )
        finally:
            runner.drift = None


def complete_m03_identity_checks() -> None:
    for attribute in (
        "m03_ovs_generation",
        "m03_link_generation",
        "m03_daemon_generation",
    ):
        with tempfile.TemporaryDirectory() as directory:
            config = make_config(pathlib.Path(directory))
            runner = FakeRunner(config)
            session = LIVE.AdmissionSession(config, runner)

            def run() -> None:
                with session:
                    session.admit()
                    setattr(runner, attribute, 1)

            expect_error(LIVE.AdmissionIncident, run, attribute + " replacement")
            assert runner.active
            assert not any(
                call["argv"][2:4] == ("down", "--m03") for call in runner.calls
            )


def drift_cases() -> None:
    for drift in ("identity", "image", "labels", "marker", "frr", "chassis2"):
        with tempfile.TemporaryDirectory() as directory:
            config = make_config(pathlib.Path(directory))
            runner = FakeRunner(config)
            runner.drift = drift

            def run() -> None:
                with LIVE.AdmissionSession(config, runner) as session:
                    session.admit()

            expect_error(LIVE.AdmissionError, run, drift + " drift")
            down = [
                call for call in runner.calls if call["argv"][2:4] == ("down", "--m03")
            ]
            assert len(down) == 0, drift
            assert runner.active


def readback_failures() -> None:
    for attribute in ("malformed_netns", "nonzero_netns"):
        with tempfile.TemporaryDirectory() as directory:
            config = make_config(pathlib.Path(directory))
            runner = FakeRunner(config)
            setattr(runner, attribute, True)

            def run() -> None:
                with LIVE.AdmissionSession(config, runner) as session:
                    session.admit()

            expect_error(LIVE.AdmissionError, run, attribute)
            assert not any(
                call["argv"][2:4] == ("down", "--m03") for call in runner.calls
            )
            assert runner.active


def parser_checks() -> None:
    literal = lock_fdinfo_literal()
    parsed = LIVE._parse_lock_fdinfo(literal)
    assert parsed == LIVE._LockFdinfo(
        position=0,
        flags=int("0100002", 8),
        mount_id=19,
        inode=63107,
        lock_counter=1,
        lock_pid=4242,
        device_major=0,
        device_minor=42,
        lock_inode=63107,
    )
    alternate_counter = LIVE._parse_lock_fdinfo(
        lock_fdinfo_literal(counter="7", flags="02100002")
    )
    assert alternate_counter.lock_counter == 7
    assert alternate_counter.flags == int("02100002", 8)
    assert (
        parsed.position,
        parsed.mount_id,
        parsed.inode,
        parsed.lock_pid,
        parsed.device_major,
        parsed.device_minor,
        parsed.lock_inode,
    ) == (
        alternate_counter.position,
        alternate_counter.mount_id,
        alternate_counter.inode,
        alternate_counter.lock_pid,
        alternate_counter.device_major,
        alternate_counter.device_minor,
        alternate_counter.lock_inode,
    )

    def rejected(
        payload: bytes,
        label: str,
        *,
        exclusive: bool | None = None,
    ) -> None:
        error = expect_error(
            LIVE._LockFdinfoError,
            lambda: LIVE._parse_lock_fdinfo(payload),
            label,
        )
        assert error.exclusive_flock_observed is exclusive, label

    rejected(literal[:-1], "fdinfo missing EOF newline")
    rejected(literal[:-9], "fdinfo truncated lock range")
    rejected(
        b"x" * LIVE.LOCK_FDINFO_MAX_BYTES + b"\n",
        "fdinfo oversized",
    )
    rejected(
        literal.replace(b"ino:\t63107", b"mnt_id:\t19"),
        "fdinfo duplicate key",
    )
    rejected(literal + b"eventfd-count:\t1\n", "fdinfo additional field")
    rejected(
        literal.replace(b"FLOCK  ADVISORY", b"POSIX   ADVISORY"),
        "fdinfo unknown lock kind",
    )
    rejected(literal + literal.splitlines(keepends=True)[-1], "fdinfo duplicate lock")
    rejected(lock_fdinfo_literal(pid="0"), "fdinfo zero PID")
    rejected(lock_fdinfo_literal(pid=str(1 << 31)), "fdinfo PID range")
    rejected(lock_fdinfo_literal(counter="0"), "fdinfo counter range")
    rejected(lock_fdinfo_literal(major="000000000"), "fdinfo device range")
    rejected(
        lock_fdinfo_literal(inode=str(1 << 64)),
        "fdinfo inode range",
    )
    rejected(literal.replace(b"pos:\t0", b"pos:\t1"), "fdinfo nonzero position")
    rejected(literal.replace(b"mnt_id:\t19", b"mnt_id:\t0"), "fdinfo mount range")
    rejected(lock_fdinfo_literal(flags="0100008"), "fdinfo non-octal flags")
    rejected(lock_fdinfo_literal(flags="00"), "fdinfo read-only flags")
    rejected(lock_fdinfo_literal(flags="0" + "7" * 20), "fdinfo flags range")
    rejected(
        literal.replace(b" 0 EOF\n", b" 1 EOF\n"),
        "fdinfo nonzero flock range",
    )
    rejected(literal.replace(b"ino:\t", b"ino:\t\xff"), "fdinfo non-ASCII")
    rejected(literal.rsplit(b"lock:", 1)[0], "fdinfo absent flock", exclusive=False)
    rejected(lock_fdinfo_literal(mode="READ"), "fdinfo shared flock", exclusive=False)

    columns = ("_uuid", "name", "ports", "external_ids")
    first = {
        "_uuid": ("uuid", uuid("switch")),
        "name": "switch",
        "ports": [("uuid", uuid("z-port")), ("uuid", uuid("a-port"))],
        "external_ids": {"owner": "test"},
    }
    second = {**first, "ports": list(reversed(first["ports"]))}
    assert LIVE._ovs_rows(ovs_json([first], columns), "ordered") == LIVE._ovs_rows(
        ovs_json([second], columns), "reordered"
    )
    duplicate_headings = json.dumps(
        {"headings": ["name", "name"], "data": [["one", "two"]]}
    ).encode()
    expect_error(
        LIVE.AdmissionError,
        lambda: LIVE._ovs_rows(duplicate_headings, "duplicate headings"),
        "duplicate OVS headings",
    )
    uuid_set_cardinality_checks()


def uuid_set_cardinality_checks() -> None:
    """Schema-declared UUID sets stay list-shaped for every cardinality."""
    assert LIVE.OVS_UUID_SET_COLUMNS == {
        "Bridge": frozenset({"ports"}),
        "Port": frozenset({"interfaces"}),
    }
    assert LIVE.OVN_UUID_SET_COLUMNS == {
        "Logical_Router": frozenset({"ports"}),
        "Logical_Switch": frozenset({"ports"}),
    }

    cases = (
        ("Port", "interfaces"),
        ("Bridge", "ports"),
        ("Logical_Switch", "ports"),
        ("Logical_Router", "ports"),
    )
    for table, column in cases:
        one = uuid(table + ":one")
        lower = uuid(table + ":lower")
        upper = uuid(table + ":upper")

        def decode_cell(cell: Any) -> dict[str, Any]:
            raw = json.dumps(
                {
                    "headings": ["_uuid", column],
                    "data": [[["uuid", uuid(table + ":row")], cell]],
                },
                separators=(",", ":"),
            ).encode()
            set_columns = (
                LIVE.OVS_UUID_SET_COLUMNS.get(table)
                or LIVE.OVN_UUID_SET_COLUMNS[table]
            )
            return LIVE._ovs_rows(
                raw, table + " singleton fixture", uuid_set_columns=set_columns
            )[0]

        singleton = decode_cell(["uuid", one])
        assert singleton["_uuid"] == uuid(table + ":row")
        assert isinstance(singleton["_uuid"], str)
        assert singleton[column] == [one]
        assert decode_cell(["set", []])[column] == []
        assert decode_cell(
            ["set", [["uuid", upper], ["uuid", lower]]]
        )[column] == sorted((lower, upper))
        assert decode_cell(
            ["set", [["uuid", lower], ["uuid", upper]]]
        ) == decode_cell(["set", [["uuid", upper], ["uuid", lower]]])

    malformed_uuid = json.dumps(
        {
            "headings": ["interfaces"],
            "data": [[["uuid", 7]]],
        },
        separators=(",", ":"),
    ).encode()
    error = expect_error(
        LIVE.AdmissionError,
        lambda: LIVE._ovs_rows(
            malformed_uuid,
            "malformed UUID atom",
            uuid_set_columns=("interfaces",),
        ),
        "non-string UUID atom",
    )
    assert str(error) == "OVS JSON UUID atom is malformed"

    duplicate_uuid = uuid("duplicate")
    duplicate_set = json.dumps(
        {
            "headings": ["interfaces"],
            "data": [[
                [
                    "set",
                    [["uuid", duplicate_uuid], ["uuid", duplicate_uuid]],
                ]
            ]],
        },
        separators=(",", ":"),
    ).encode()
    error = expect_error(
        LIVE.AdmissionError,
        lambda: LIVE._ovs_rows(
            duplicate_set,
            "duplicate UUID set",
            uuid_set_columns=("interfaces",),
        ),
        "duplicate UUID set member",
    )
    assert str(error) == "OVS JSON set contains duplicates"

    malformed_map = json.dumps(
        {"headings": ["interfaces"], "data": [[["map", {}]]]},
        separators=(",", ":"),
    ).encode()
    error = expect_error(
        LIVE.AdmissionError,
        lambda: LIVE._ovs_rows(
            malformed_map,
            "malformed UUID-set map",
            uuid_set_columns=("interfaces",),
        ),
        "malformed map remains rejected",
    )
    assert str(error) == "OVS JSON map is malformed"

    port_counts = {
        "host": 14,
        "ovn-chassis-1": 8,
        "ovn-chassis-2": 7,
        "ovn-gw-1": 10,
        "ovn-gw-2": 10,
    }
    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        collector = LIVE.LiveCollector(config, object())

        def captured_run(argv: tuple[str, ...]) -> bytes:
            node = argv[2] if argv[:2] == ("docker", "exec") else None
            capture_node = "host" if node is None else node
            return CAPTURED_OVS_SET_READBACKS[capture_node][argv[-1]]

        collector._run = captured_run
        total_ports = 0
        for capture_node, expected_count in port_counts.items():
            node = None if capture_node == "host" else capture_node
            ports = collector.ovs(
                node,
                "Port",
                ("_uuid", "name", "interfaces", "tag", "external_ids"),
            )
            bridges = collector.ovs(node, "Bridge", ("_uuid", "name", "ports"))
            assert len(ports) == expected_count
            assert all(
                isinstance(row["_uuid"], str)
                and isinstance(row["interfaces"], list)
                and len(row["interfaces"]) == 1
                and LIVE.PREFLIGHT.UUID_RE.fullmatch(row["interfaces"][0])
                is not None
                for row in ports
            )
            assert all(
                isinstance(row["_uuid"], str)
                and isinstance(row["ports"], list)
                and all(
                    LIVE.PREFLIGHT.UUID_RE.fullmatch(port_uuid) is not None
                    for port_uuid in row["ports"]
                )
                for row in bridges
            )
            total_ports += len(ports)
        assert total_ports == 49

        host_ports = collector.ovs(
            None, "Port", ("_uuid", "name", "interfaces", "tag", "external_ids")
        )
        host_bridges = collector.ovs(None, "Bridge", ("_uuid", "name", "ports"))
        port, parent = next(
            (port, bridge)
            for bridge in host_bridges
            for port in host_ports
            if port["_uuid"] in bridge["ports"]
        )
        interface_raw = ovs_json(
            [
                {
                    "_uuid": ("uuid", port["interfaces"][0]),
                    "name": port["name"],
                    "external_ids": {},
                }
            ],
            ("_uuid", "name", "external_ids"),
        )
        original_run = collector._run

        def observe_run(argv: tuple[str, ...]) -> bytes:
            if argv[-1] == "Interface":
                return interface_raw
            return original_run(argv)

        collector.clear_cache()
        collector._run = observe_run
        state, observed = collector._observe_ovs_port(
            {
                "host": "host:vm-cilium",
                "name": port["name"],
                "parent": parent["name"],
                "id": "captured-port-membership",
            }
        )
        assert state == "absent"
        assert observed["exists"] is True
        assert observed["parent_bridge_uuid"] == parent["_uuid"]
        assert observed["port_matches"][0]["parent_member"] is True

        bridge_doc = json.loads(CAPTURED_OVS_SET_READBACKS["host"]["Bridge"])
        bridge_name_index = bridge_doc["headings"].index("name")
        bridge_ports_index = bridge_doc["headings"].index("ports")
        parent_row = next(
            row
            for row in bridge_doc["data"]
            if row[bridge_name_index] == parent["name"]
        )
        parent_row[bridge_ports_index][1] = [
            item
            for item in parent_row[bridge_ports_index][1]
            if item != ["uuid", port["_uuid"]]
        ]
        bridge_without_member = json.dumps(
            bridge_doc, separators=(",", ":")
        ).encode()
        nonmember_collector = LIVE.LiveCollector(config, object())

        def nonmember_run(argv: tuple[str, ...]) -> bytes:
            if argv[-1] == "Interface":
                return interface_raw
            if argv[-1] == "Bridge":
                return bridge_without_member
            return CAPTURED_OVS_SET_READBACKS["host"]["Port"]

        nonmember_collector._run = nonmember_run
        _, nonmember = nonmember_collector._observe_ovs_port(
            {
                "host": "host:vm-cilium",
                "name": port["name"],
                "parent": parent["name"],
                "id": "captured-port-nonmembership",
            }
        )
        assert nonmember["port_matches"][0]["parent_member"] is False

        captured_port_doc = json.loads(CAPTURED_OVS_SET_READBACKS["host"]["Port"])
        port_headings = captured_port_doc["headings"]
        port_uuid_index = port_headings.index("_uuid")
        interfaces_index = port_headings.index("interfaces")
        for invalid_interfaces in (["uuid", "not-a-uuid"], "not-a-set"):
            invalid_doc = copy.deepcopy(captured_port_doc)
            invalid_row = next(
                row
                for row in invalid_doc["data"]
                if row[port_uuid_index] == ["uuid", port["_uuid"]]
            )
            invalid_row[interfaces_index] = invalid_interfaces
            invalid_port_raw = json.dumps(
                invalid_doc, separators=(",", ":")
            ).encode()
            invalid_collector = LIVE.LiveCollector(config, object())

            def invalid_ovs_run(argv: tuple[str, ...]) -> bytes:
                if argv[-1] == "Interface":
                    return ovs_json([], ("_uuid", "name", "external_ids"))
                if argv[-1] == "Port":
                    return invalid_port_raw
                return CAPTURED_OVS_SET_READBACKS["host"]["Bridge"]

            invalid_collector._run = invalid_ovs_run
            error = expect_error(
                LIVE.AdmissionError,
                lambda: invalid_collector._observe_ovs_port(
                    {
                        "host": "host:vm-cilium",
                        "name": port["name"],
                        "parent": parent["name"],
                        "id": "invalid-captured-port",
                    }
                ),
                "invalid Port.interfaces reference",
            )
            assert str(error) == "OVS Port readback is malformed"

    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        runner.active = True
        collector = LIVE.LiveCollector(config, runner)

        def active_nb_run(argv: tuple[str, ...]) -> bytes:
            raw = runner.nb_readback(argv)
            document = json.loads(raw)
            table = argv[-2]
            if table in {"Logical_Switch", "Logical_Router"}:
                ports_index = document["headings"].index("ports")
                for row in document["data"]:
                    cell = row[ports_index]
                    if cell[0] == "set" and len(cell[1]) == 1:
                        row[ports_index] = cell[1][0]
            return json.dumps(document, separators=(",", ":")).encode()

        collector._run = active_nb_run
        fingerprint = collector._a_fingerprint()
        assert fingerprint["Logical_Switch"]["ports"] == [uuid("a-lsp")]
        assert fingerprint["Logical_Router"]["ports"] == [
            uuid("lrp-mgc-tenant")
        ]

        invalid_collector = LIVE.LiveCollector(config, runner)

        def invalid_active_nb_run(argv: tuple[str, ...]) -> bytes:
            document = json.loads(active_nb_run(argv))
            if argv[-2] == "Logical_Switch":
                ports_index = document["headings"].index("ports")
                document["data"][0][ports_index] = "not-a-set"
            return json.dumps(document, separators=(",", ":")).encode()

        invalid_collector._run = invalid_active_nb_run
        error = expect_error(
            LIVE.AdmissionError,
            invalid_collector._a_fingerprint,
            "malformed M03 logical-switch port set",
        )
        assert str(error) == (
            "M03 A fingerprint port set is malformed: Logical_Switch"
        )


def path_failures() -> None:
    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        config.evidence_path.mkdir()
        expect_error(
            LIVE.AdmissionError,
            lambda: LIVE.AdmissionSession(config, FakeRunner(config)).__enter__(),
            "preexisting target",
        )
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        config = make_config(root)
        target = root / "foreign"
        target.write_text("x")
        config.evidence_path.symlink_to(target)
        expect_error(
            LIVE.AdmissionError,
            lambda: LIVE.AdmissionSession(config, FakeRunner(config)).__enter__(),
            "symlink target",
        )
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        config = make_config(root)
        config.run_parent.chmod(0o755)
        expect_error(
            LIVE.AdmissionError,
            lambda: LIVE.AdmissionSession(config, FakeRunner(config)).__enter__(),
            "wrong run parent mode",
        )
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        config = make_config(root)
        config.lock_path.write_text("")
        config.lock_path.chmod(0o644)
        expect_error(
            LIVE.AdmissionError,
            lambda: LIVE.AdmissionSession(config, FakeRunner(config)).__enter__(),
            "wrong lock mode",
        )
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        config = make_config(root)
        target = root / "foreign-lock"
        target.write_text("")
        config.lock_path.symlink_to(target)
        expect_error(
            LIVE.AdmissionError,
            lambda: LIVE.AdmissionSession(config, FakeRunner(config)).__enter__(),
            "symlink lock",
        )
    for attribute in ("state_path", "k01_kubeconfig"):
        with tempfile.TemporaryDirectory() as directory:
            config = make_config(pathlib.Path(directory))
            getattr(config, attribute).chmod(0o666)
            runner = FakeRunner(config)

            def unsafe_input() -> None:
                with LIVE.AdmissionSession(config, runner) as session:
                    session.admit()

            expect_error(LIVE.AdmissionError, unsafe_input, attribute + " unsafe mode")
            assert not any(
                call["argv"][0] == str(config.labctl_path) for call in runner.calls
            )
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        config = make_config(root)
        target = root / "real-labctl"
        target.write_text("#!/bin/sh\nexit 75\n")
        target.chmod(0o700)
        config.labctl_path.unlink()
        config.labctl_path.symlink_to(target)
        runner = FakeRunner(config)

        def symlink_labctl() -> None:
            with LIVE.AdmissionSession(config, runner) as session:
                session.admit()

        expect_error(LIVE.AdmissionError, symlink_labctl, "symlink labctl")
        assert runner.calls == []


def lifecycle_failures() -> None:
    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        runner.setup_rc = 7

        def setup_failure() -> None:
            with LIVE.AdmissionSession(config, runner) as session:
                session.admit()

        expect_error(LIVE.AdmissionError, setup_failure, "setup failure")
        lifecycle = [
            call["argv"][2:]
            for call in runner.calls
            if call["argv"][0] == str(config.labctl_path)
        ]
        assert lifecycle == [("up", "--m03"), ("down", "--m03"), ("verify",)]
    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        runner.setup_rc = 7
        runner.setup_foreign = True

        def foreign_failure() -> None:
            with LIVE.AdmissionSession(config, runner) as session:
                session.admit()

        expect_error(LIVE.AdmissionError, foreign_failure, "foreign setup residue")
        assert not any(call["argv"][2:4] == ("down", "--m03") for call in runner.calls)
        assert runner.active
    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        runner.cleanup_rc = 9
        session = LIVE.AdmissionSession(config, runner)

        def cleanup_failure() -> None:
            with session:
                session.admit()

        expect_error(LIVE.AdmissionIncident, cleanup_failure, "cleanup failure")
        assert runner.active
        assert sum(call["argv"][2:4] == ("down", "--m03") for call in runner.calls) == 1
        session.close()
        assert sum(call["argv"][2:4] == ("down", "--m03") for call in runner.calls) == 1
        assert any(row["event"] == "incident" for row in read_events(config.event_path))


def unexpected_x05_marker() -> None:
    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        session = LIVE.AdmissionSession(config, runner)

        def run() -> None:
            with session:
                session.admit()
                config.x05_marker_path.parent.mkdir(parents=True, exist_ok=True)
                config.x05_marker_path.write_text("foreign-or-unproved\n")
                config.x05_marker_path.chmod(0o600)

        expect_error(LIVE.AdmissionIncident, run, "unexpected X05 marker")
        assert runner.active
        assert config.m03_marker_path.is_file()
        assert config.x05_marker_path.is_file()
        assert not any(call["argv"][2:4] == ("down", "--m03") for call in runner.calls)
        assert any(
            "X05 marker appeared" in row["detail"].get("reason", "")
            for row in read_events(config.event_path)
        )


def replaced_m03_before_cleanup() -> None:
    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        session = LIVE.AdmissionSession(config, runner)

        def run() -> None:
            with session:
                session.admit()
                runner.marker_run = "20260930T140000Z-5151"
                runner.write_marker()

        expect_error(LIVE.AdmissionIncident, run, "replaced M03 before cleanup")
        assert runner.active
        assert not any(call["argv"][2:4] == ("down", "--m03") for call in runner.calls)
        readback = next(
            row
            for row in read_events(config.event_path)
            if row["event"] == "m03-pre-down-readback"
        )
        assert readback["detail"]["owned"] is True
        assert readback["detail"]["matches_setup"] is False


def lock_failures() -> None:
    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        config.lock_path.touch(mode=0o600)
        config.lock_path.chmod(0o600)
        fd = os.open(config.lock_path, os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            expect_error(
                LIVE.AdmissionError,
                lambda: LIVE.AdmissionSession(config, FakeRunner(config)).__enter__(),
                "lock contention",
            )
        finally:
            os.close(fd)
    try:
        os.fstat(9)
    except OSError:
        pass
    else:
        raise AssertionError("selftest requires FD 9 initially closed")
    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        fd = os.open(os.devnull, os.O_RDONLY)
        os.dup2(fd, 9)
        os.close(fd)
        try:
            expect_error(
                LIVE.AdmissionError,
                lambda: LIVE.AdmissionSession(config, FakeRunner(config)).__enter__(),
                "wrong FD 9",
            )
        finally:
            os.close(9)


def lock_keeper_boundary_checks() -> None:
    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        session = LIVE.AdmissionSession(config, FakeRunner(config))
        session.__enter__()
        keeper = session._lock_keeper_fd
        assert keeper is not None and keeper != 9
        assert os.get_inheritable(9)
        assert not os.get_inheritable(keeper)
        assert fcntl.fcntl(keeper, fcntl.F_GETFD) & fcntl.FD_CLOEXEC
        assert_competing_lock_blocked(config.lock_path)
        child = (
            "import errno,os,sys; "
            "keeper=int(sys.argv[1]); "
            "fd9=True; hidden=False; "
            "\ntry: os.fstat(9)\nexcept OSError: fd9=False"
            "\ntry: os.fstat(keeper)\nexcept OSError as exc: hidden=exc.errno==errno.EBADF"
            "\nraise SystemExit(0 if fd9 and hidden else 1)"
        )
        inherited = subprocess.run(
            (sys.executable, "-B", "-c", child, str(keeper)),
            check=False,
            close_fds=False,
            env={**LIVE.BASE_ENV, "PYTHONDONTWRITEBYTECODE": "1"},
        )
        assert inherited.returncode == 0
        session.close()
        assert session._lock_keeper_fd is None

    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        with mock.patch.object(
            LIVE.AdmissionSession,
            "_duplicate_lock_keeper",
            side_effect=OSError("injected keeper duplication failure"),
        ):
            expect_error(
                OSError,
                lambda: LIVE.AdmissionSession(config, FakeRunner(config)).__enter__(),
                "keeper creation failure",
            )
        expect_error(OSError, lambda: os.fstat(9), "FD 9 after keeper failure")
        probe = os.open(config.lock_path, os.O_RDWR)
        try:
            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            os.close(probe)


def observational_syscall_checks() -> None:
    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        session = LIVE.AdmissionSession(config, runner)
        session.__enter__()
        with mock.patch.object(
            LIVE.fcntl,
            "flock",
            side_effect=AssertionError("authority observation called flock"),
        ) as flock_spy:
            prepared = session.prepare()
            assert session.consume(prepared) is prepared
            session.close()
        assert flock_spy.call_count == 0
        assert not runner.active


def scheduled_lock_loss_regressions() -> None:
    real_flock = fcntl.flock
    for phase in ("prepare", "consume"):
        with tempfile.TemporaryDirectory() as directory:
            config = make_config(pathlib.Path(directory))
            runner = FakeRunner(config)
            session = LIVE.AdmissionSession(config, runner)
            session.__enter__()
            prepared = session.prepare() if phase == "consume" else None
            keeper = session._lock_keeper_fd
            assert keeper is not None
            real_flock(keeper, fcntl.LOCK_UN)
            competitor = os.open(config.lock_path, os.O_RDWR)
            real_flock(competitor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            assert_competing_lock_blocked(config.lock_path)
            real_reader = LIVE._read_lock_fdinfo_bytes
            competitor_released = False

            def release_after_observation(descriptor: int) -> bytes:
                nonlocal competitor_released
                data = real_reader(descriptor)
                if not competitor_released:
                    real_flock(competitor, fcntl.LOCK_UN)
                    competitor_released = True
                return data

            try:
                with mock.patch.object(
                    LIVE,
                    "_read_lock_fdinfo_bytes",
                    side_effect=release_after_observation,
                ):
                    if phase == "prepare":
                        expect_error(
                            LIVE.AdmissionIncident,
                            session.prepare,
                            "lost lock with competitor release before prepare",
                        )
                    else:
                        assert prepared is not None
                        expect_error(
                            LIVE.AdmissionIncident,
                            lambda: session.consume(prepared),
                            "lost lock with competitor release before consume",
                        )
                assert competitor_released
                expect_error(
                    LIVE.AdmissionIncident,
                    session.close,
                    "lost lock cleanup refusal",
                )
                assert not session._lock_keeper_retained
                assert not any(
                    call["argv"][2:4] == ("down", "--m03")
                    for call in runner.calls
                )
                expected_up = 1 if phase == "consume" else 0
                assert (
                    sum(
                        call["argv"][2:4] == ("up", "--m03")
                        for call in runner.calls
                    )
                    == expected_up
                )
            finally:
                with contextlib.suppress(OSError):
                    os.close(competitor)
                close_retained_test_descriptors(session)

    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        session = LIVE.AdmissionSession(config, runner)
        session.__enter__()
        keeper = session._lock_keeper_fd
        assert keeper is not None
        real_flock(keeper, fcntl.LOCK_SH)
        expect_error(
            LIVE.AdmissionIncident,
            session.prepare,
            "shared flock before prepare",
        )
        expect_error(
            LIVE.AdmissionIncident,
            session.close,
            "shared flock cleanup refusal",
        )
        assert not session._lock_keeper_retained
        assert not any(
            call["argv"][0] == str(config.labctl_path) for call in runner.calls
        )
        close_retained_test_descriptors(session)


def procfs_observation_failures() -> None:
    real_open = os.open

    def proc_unavailable(path, flags, mode=0o777, *, dir_fd=None):
        if str(path).startswith("/proc/self/fdinfo/"):
            raise FileNotFoundError("injected unavailable procfs fdinfo")
        if dir_fd is None:
            return real_open(path, flags, mode)
        return real_open(path, flags, mode, dir_fd=dir_fd)

    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        with mock.patch.object(LIVE.os, "open", side_effect=proc_unavailable):
            expect_error(
                LIVE.AdmissionError,
                lambda: LIVE.AdmissionSession(config, FakeRunner(config)).__enter__(),
                "procfs unavailable during acquisition",
            )
        expect_error(OSError, lambda: os.fstat(9), "FD 9 after procfs failure")
        probe = os.open(config.lock_path, os.O_RDWR)
        try:
            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            os.close(probe)

    for failure in ("unavailable", "unsupported"):
        with tempfile.TemporaryDirectory() as directory:
            config = make_config(pathlib.Path(directory))
            runner = FakeRunner(config)
            session = LIVE.AdmissionSession(config, runner)
            session.__enter__()
            prepared = session.prepare()
            if failure == "unavailable":
                patcher = mock.patch.object(
                    LIVE.os, "open", side_effect=proc_unavailable
                )
            else:
                patcher = mock.patch.object(
                    LIVE,
                    "_read_lock_fdinfo_bytes",
                    return_value=lock_fdinfo_literal()
                    + b"unsupported:\tvalue\n",
                )
            with patcher:
                expect_error(
                    LIVE.AdmissionIncident,
                    lambda: session.consume(prepared),
                    "procfs " + failure + " before consume",
                )
            expect_error(
                LIVE.AdmissionIncident,
                session.close,
                "procfs " + failure + " cleanup refusal",
            )
            assert runner.active
            assert session._lock_keeper_retained
            assert not any(
                call["argv"][2:4] == ("down", "--m03")
                for call in runner.calls
            )
            close_retained_test_descriptors(session)


def lock_authority_regressions() -> None:
    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        session = LIVE.AdmissionSession(config, runner)
        session.__enter__()
        prepared = session.admit()
        keeper = session._lock_keeper_fd
        assert keeper is not None
        os.close(keeper)
        expect_error(
            LIVE.AdmissionIncident,
            lambda: session.consume(prepared),
            "closed original lock keeper",
        )
        expect_error(
            LIVE.AdmissionIncident,
            session.close,
            "closed original lock keeper cleanup",
        )
        assert session._lock_keeper_fd == keeper
        assert not session._lock_keeper_retained
        retention = session._lock_retention_evidence
        assert retention is not None
        assert retention["keeper"]["descriptor_open"] is False
        assert retention["keeper"]["exclusive_flock_observed"] is None
        events = read_events(config.event_path)
        incident = next(
            row["detail"]
            for row in events
            if row["event"] == "incident"
            and "original_keeper_retained" in row["detail"]
        )
        assert incident["original_keeper_retained"] is False
        assert incident["original_keeper_exclusive_flock_observed"] is None
        assert not any(
            call["argv"][2:4] == ("down", "--m03") for call in runner.calls
        )
        assert_competing_lock_blocked(config.lock_path)
        close_retained_test_descriptors(session)

    for replacement in ("same-inode", "foreign"):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            config = make_config(root)
            runner = FakeRunner(config)
            session = LIVE.AdmissionSession(config, runner)
            session.__enter__()
            prepared = session.admit()
            keeper = session._lock_keeper_fd
            assert keeper is not None
            os.close(keeper)
            replacement_path = (
                config.lock_path
                if replacement == "same-inode"
                else root / "foreign-keeper"
            )
            replacement_fd = os.open(
                replacement_path,
                os.O_RDWR | os.O_CREAT,
                0o600,
            )
            if replacement_fd != keeper:
                os.dup2(replacement_fd, keeper, inheritable=False)
                os.close(replacement_fd)
            os.set_inheritable(keeper, False)
            descriptor_flags = fcntl.fcntl(keeper, fcntl.F_GETFD)
            fcntl.fcntl(
                keeper,
                fcntl.F_SETFD,
                descriptor_flags | fcntl.FD_CLOEXEC,
            )
            replacement_identity = (os.fstat(keeper).st_dev, os.fstat(keeper).st_ino)
            expect_error(
                LIVE.AdmissionIncident,
                lambda: session.consume(prepared),
                replacement + " reused keeper",
            )
            expect_error(
                LIVE.AdmissionIncident,
                session.close,
                replacement + " reused keeper cleanup",
            )
            assert not session._lock_keeper_retained
            assert (os.fstat(keeper).st_dev, os.fstat(keeper).st_ino) == (
                replacement_identity
            )
            retention = session._lock_retention_evidence
            assert retention is not None
            if replacement == "same-inode":
                assert retention["keeper"]["metadata_matches"] is True
                assert (
                    retention["keeper"]["exclusive_flock_observed"] is False
                )
            else:
                assert retention["keeper"]["metadata_matches"] is False
                assert retention["keeper"]["exclusive_flock_observed"] is None
            assert not any(
                call["argv"][2:4] == ("down", "--m03")
                for call in runner.calls
            )
            close_retained_test_descriptors(session)

    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        session = LIVE.AdmissionSession(config, runner)
        session.__enter__()
        prepared = session.admit()
        keeper = session._lock_keeper_fd
        assert keeper is not None
        os.close(keeper)
        session._lock_keeper_fd = None
        expect_error(
            LIVE.AdmissionIncident,
            lambda: session.consume(prepared),
            "missing original lock keeper",
        )
        expect_error(
            LIVE.AdmissionIncident,
            session.close,
            "missing original lock keeper cleanup",
        )
        assert not session._lock_keeper_retained
        assert not any(call["argv"][2:4] == ("down", "--m03") for call in runner.calls)
        assert_competing_lock_blocked(config.lock_path)
        close_retained_test_descriptors(session)

    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        session = LIVE.AdmissionSession(config, runner)
        session.__enter__()
        prepared = session.admit()
        os.close(9)
        expect_error(
            LIVE.AdmissionIncident,
            lambda: session.consume(prepared),
            "closed FD 9",
        )
        expect_error(
            LIVE.AdmissionIncident,
            session.close,
            "closed FD 9 cleanup",
        )
        assert runner.active and config.snapshot_path.is_file()
        assert session._lock_keeper_retained
        assert not any(call["argv"][2:4] == ("down", "--m03") for call in runner.calls)
        assert_competing_lock_blocked(config.lock_path)
        close_retained_test_descriptors(session)

    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        config = make_config(root)
        runner = FakeRunner(config)
        session = LIVE.AdmissionSession(config, runner)
        session.__enter__()
        prepared = session.admit()
        os.close(9)
        foreign_path = root / "foreign-fd9"
        foreign = os.open(foreign_path, os.O_RDWR | os.O_CREAT, 0o600)
        if foreign != 9:
            os.dup2(foreign, 9, inheritable=True)
            os.close(foreign)
        foreign_identity = (os.fstat(9).st_dev, os.fstat(9).st_ino)
        expect_error(
            LIVE.AdmissionIncident,
            lambda: session.consume(prepared),
            "foreign FD 9 inode",
        )
        expect_error(
            LIVE.AdmissionIncident,
            session.close,
            "foreign FD 9 cleanup",
        )
        assert (os.fstat(9).st_dev, os.fstat(9).st_ino) == foreign_identity
        assert foreign_identity != (
            config.lock_path.stat().st_dev,
            config.lock_path.stat().st_ino,
        )
        assert session._lock_keeper_retained
        assert not any(call["argv"][2:4] == ("down", "--m03") for call in runner.calls)
        assert_competing_lock_blocked(config.lock_path)
        close_retained_test_descriptors(session)

    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        session = LIVE.AdmissionSession(config, runner)
        session.__enter__()
        prepared = session.admit()
        os.close(9)
        reopened = os.open(config.lock_path, os.O_RDWR)
        if reopened != 9:
            os.dup2(reopened, 9, inheritable=True)
            os.close(reopened)
        expect_error(
            LIVE.AdmissionIncident,
            lambda: session.consume(prepared),
            "same-inode unlocked FD 9 reopen",
        )
        expect_error(
            LIVE.AdmissionIncident,
            session.close,
            "same-inode unlocked FD 9 cleanup",
        )
        assert os.fstat(9).st_ino == config.lock_path.stat().st_ino
        assert session._lock_keeper_retained
        assert not any(call["argv"][2:4] == ("down", "--m03") for call in runner.calls)
        assert_competing_lock_blocked(config.lock_path)
        close_retained_test_descriptors(session)

    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        session = LIVE.AdmissionSession(config, runner)
        session.__enter__()
        prepared = session.admit()
        keeper = session._lock_keeper_fd
        assert keeper is not None
        # Production never issues LOCK_UN. This is a test-only authority-loss fault.
        fcntl.flock(keeper, fcntl.LOCK_UN)
        expect_error(
            LIVE.AdmissionIncident,
            lambda: session.consume(prepared),
            "test-only flock authority drop",
        )
        expect_error(
            LIVE.AdmissionIncident,
            session.close,
            "test-only flock authority drop cleanup",
        )
        os.fstat(keeper)
        assert session._lock_keeper_fd == keeper
        assert not session._lock_keeper_retained
        assert session._lock_retention_evidence is not None
        assert (
            session._lock_retention_evidence["keeper"][
                "exclusive_flock_observed"
            ]
            is False
        )
        assert not any(call["argv"][2:4] == ("down", "--m03") for call in runner.calls)
        probe = os.open(config.lock_path, os.O_RDWR)
        try:
            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            os.close(probe)
        close_retained_test_descriptors(session)

    with tempfile.TemporaryDirectory() as directory:
        config = make_config(pathlib.Path(directory))
        runner = FakeRunner(config)
        session = LIVE.AdmissionSession(config, runner)
        session.__enter__()
        prepared = session.admit()
        keeper = session._lock_keeper_fd
        assert keeper is not None
        os.close(9)
        assert_competing_lock_blocked(config.lock_path)
        os.dup2(keeper, 9, inheritable=True)
        assert session.consume(prepared) is prepared
        session.close()
        assert not runner.active
        assert sum(call["argv"][2:4] == ("down", "--m03") for call in runner.calls) == 1
        assert session._lock_keeper_fd is None

    for drift in ("metadata", "path"):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            config = make_config(root)
            runner = FakeRunner(config)
            session = LIVE.AdmissionSession(config, runner)
            session.__enter__()
            prepared = session.admit()
            keeper = session._lock_keeper_fd
            assert keeper is not None
            if drift == "metadata":
                config.lock_path.chmod(0o640)
                retained_path = config.lock_path
            else:
                moved = root / "original-lock-inode"
                config.lock_path.rename(moved)
                config.lock_path.touch(mode=0o600)
                config.lock_path.chmod(0o600)
                retained_path = moved
            expect_error(
                LIVE.AdmissionIncident,
                lambda: session.consume(prepared),
                "lock " + drift + " drift",
            )
            expect_error(
                LIVE.AdmissionIncident,
                session.close,
                "lock " + drift + " drift cleanup",
            )
            retained_identity = (
                retained_path.stat().st_dev,
                retained_path.stat().st_ino,
            )
            for descriptor in (keeper, 9):
                retained_info = os.fstat(descriptor)
                assert (
                    retained_info.st_dev,
                    retained_info.st_ino,
                ) == retained_identity
            assert_competing_lock_blocked(retained_path)
            retention = session._lock_retention_evidence
            assert retention is not None
            for label in ("keeper", "fd9"):
                evidence = retention[label]
                assert evidence["descriptor_open"] is True
                expected_validated = (
                    evidence["metadata_matches"] is True
                    and evidence["exclusive_flock_observed"] is True
                    and evidence["matches_acquisition"] is True
                )
                assert (
                    evidence["validated_descriptor_retained"]
                    is expected_validated
                )
            assert session._lock_keeper_retained is retention["keeper"][
                "validated_descriptor_retained"
            ]
            claims = [
                row["detail"]
                for row in read_events(config.event_path)
                if "lock_retention_evidence" in row["detail"]
            ]
            assert claims
            for claim in claims:
                assert claim["original_keeper_retained"] is claim[
                    "lock_retention_evidence"
                ]["keeper"]["validated_descriptor_retained"]
                assert claim["fd9_retained"] is claim[
                    "lock_retention_evidence"
                ]["fd9"]["validated_descriptor_retained"]
            assert claims[-1]["lock_retention_evidence"] == retention
            if drift == "metadata":
                for evidence in retention.values():
                    assert evidence["metadata_matches"] is False
                    assert evidence["exclusive_flock_observed"] is None
                    assert evidence["validated_descriptor_retained"] is False
            else:
                assert (
                    os.fstat(keeper).st_ino
                    != config.lock_path.stat().st_ino
                )
            assert not any(
                call["argv"][2:4] == ("down", "--m03") for call in runner.calls
            )
            close_retained_test_descriptors(session)


def subprocess_runner_checks() -> None:
    runner = LIVE.SubprocessRunner(terminate_grace=0.1)
    with tempfile.TemporaryDirectory() as directory:
        path = pathlib.Path(directory) / "fd9"
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        os.dup2(fd, 9, inheritable=True)
        if fd != 9:
            os.close(fd)
        try:
            result = runner.run(
                (sys.executable, "-c", "import os; print(os.fstat(9).st_ino)"),
                env=LIVE.BASE_ENV,
                timeout=2,
                pass_fds=(9,),
            )
            assert result.returncode == 0
            assert int(result.stdout) == path.stat().st_ino
        finally:
            os.close(9)
    started = time.monotonic()
    command = (
        sys.executable,
        "-c",
        "import subprocess,sys,time; "
        "subprocess.Popen([sys.executable,'-c','import time; time.sleep(10)']); "
        "time.sleep(10)",
    )
    expect_error(
        LIVE.CommandTimeout,
        lambda: runner.run(command, env=LIVE.BASE_ENV, timeout=0.2),
        "process group timeout",
    )
    assert time.monotonic() - started < 3
    started = time.monotonic()
    flood = (
        sys.executable,
        "-c",
        "import os; os.write(1, b'o' * 40000); os.write(2, b'e' * 40000)",
    )
    expect_error(
        LIVE.CommandOutputLimit,
        lambda: runner.run(
            flood,
            env=LIVE.BASE_ENV,
            timeout=2,
            max_output_bytes=65536,
        ),
        "combined streaming output limit",
    )
    assert time.monotonic() - started < 3
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        lock_path = root / "fd9-lock"
        pid_path = root / "detached.pid"
        raw_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        os.dup2(raw_fd, 9, inheritable=True)
        if raw_fd != 9:
            os.close(raw_fd)
        fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
        detached_pid: int | None = None
        probe_fd: int | None = None
        fd9_open = True
        try:
            child = "import time; time.sleep(10)"
            parent = (
                "import os,pathlib,subprocess,sys,time; "
                "path=pathlib.Path(sys.argv[1]); "
                "child=subprocess.Popen([sys.executable,'-c',sys.argv[2]],"
                "pass_fds=(9,),preexec_fn=os.setsid); "
                "path.write_text(str(child.pid)); "
                "time.sleep(10)"
            )
            started = time.monotonic()
            incident = expect_error(
                LIVE.RetainedDescriptorIncident,
                lambda: runner.run(
                    (sys.executable, "-c", parent, str(pid_path), child),
                    env=LIVE.BASE_ENV,
                    timeout=0.3,
                    pass_fds=(9,),
                ),
                "detached descendant descriptors",
            )
            assert "FD 9 may remain open" in str(incident)
            assert time.monotonic() - started < 3
            detached_pid = int(pid_path.read_text())
            os.close(9)
            fd9_open = False
            probe_fd = os.open(lock_path, os.O_RDWR)
            expect_error(
                BlockingIOError,
                lambda: fcntl.flock(probe_fd, fcntl.LOCK_EX | fcntl.LOCK_NB),
                "detached descendant retained FD 9 lock",
            )
            os.kill(detached_pid, signal.SIGKILL)
            deadline = time.monotonic() + 2
            while True:
                try:
                    fcntl.flock(probe_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise AssertionError("detached descendant did not release FD 9")
                    time.sleep(0.01)
        finally:
            if fd9_open:
                os.close(9)
            if detached_pid is not None:
                with contextlib.suppress(ProcessLookupError):
                    os.kill(detached_pid, signal.SIGKILL)
            if probe_fd is not None:
                os.close(probe_fd)


def retained_descriptor_session_check() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        config = make_config(root / "first")
        pid_path = root / "detached.pid"

        class RetainingSetupRunner(FakeRunner):
            def run(self, argv, **kwargs):
                command = tuple(argv)
                if command[0] != str(self.config.labctl_path) or command[2] != "up":
                    return super().run(argv, **kwargs)
                super().run(argv, **kwargs)
                child = "import time; time.sleep(10)"
                parent = (
                    "import os,pathlib,subprocess,sys,time; "
                    "path=pathlib.Path(sys.argv[1]); "
                    "child=subprocess.Popen([sys.executable,'-c',sys.argv[2]],"
                    "pass_fds=(9,),preexec_fn=os.setsid); "
                    "path.write_text(str(child.pid)); time.sleep(10)"
                )
                actual = LIVE.SubprocessRunner(terminate_grace=0.1)
                return actual.run(
                    (sys.executable, "-c", parent, str(pid_path), child),
                    env=kwargs["env"],
                    timeout=0.25,
                    pass_fds=(9,),
                )

        runner = RetainingSetupRunner(config)
        session = LIVE.AdmissionSession(config, runner)
        expect_error(
            LIVE.RetainedDescriptorIncident,
            lambda: session.__enter__().prepare(),
            "session detached descendant",
        )
        expect_error(
            LIVE.AdmissionIncident,
            session.close,
            "retained descriptor cleanup incident",
        )
        assert runner.active and session._retained_descriptor
        assert not any(call["argv"][2:4] == ("down", "--m03") for call in runner.calls)
        detached_pid = int(pid_path.read_text())
        try:
            second_config = make_config(root / "second", run_hex="d4e5f6")
            object.__setattr__(second_config, "lock_path", config.lock_path)
            second = LIVE.AdmissionSession(second_config, FakeRunner(second_config))
            expect_error(
                LIVE.AdmissionError,
                second.__enter__,
                "second coordinator while exact descendant holds shared OFD",
            )
            os.kill(detached_pid, signal.SIGKILL)
            deadline = time.monotonic() + 2
            while True:
                probe = LIVE.AdmissionSession(second_config, FakeRunner(second_config))
                try:
                    probe.__enter__()
                except LIVE.AdmissionError as exc:
                    if "lock is held" not in str(exc) or time.monotonic() >= deadline:
                        raise
                    time.sleep(0.01)
                    continue
                probe.close()
                break
        finally:
            with contextlib.suppress(ProcessLookupError):
                os.kill(detached_pid, signal.SIGKILL)


def fixture_and_cli_checks() -> None:
    fixture = LIVE.PREFLIGHT.synthetic_fixture()
    expect_error(
        LIVE.PREFLIGHT.SnapshotError,
        lambda: LIVE.PREFLIGHT.validate_snapshot(fixture),
        "fixture admission",
    )
    report = LIVE.dry_run_report()
    assert report["writes"] == 0 and report["subprocesses"] == 0
    assert report["resource_count"] == 43
    forbidden = AssertionError("disabled CLI attempted an effect")
    with (
        mock.patch.object(LIVE.subprocess, "Popen", side_effect=forbidden),
        mock.patch.object(LIVE.os, "mkdir", side_effect=forbidden),
        mock.patch.object(LIVE.os, "write", side_effect=forbidden),
        contextlib.redirect_stdout(io.StringIO()),
        contextlib.redirect_stderr(io.StringIO()),
    ):
        assert LIVE.main(["--dry-run"]) == 0
        assert LIVE.main(["--execute"]) == 75


class _ReviewedSourceTree:
    def __init__(self, source_root: pathlib.Path) -> None:
        if not source_root.is_absolute() or ".." in source_root.parts:
            raise LIVE.AdmissionError("reviewed source root is not canonical")
        directory_flag = getattr(os, "O_DIRECTORY", None)
        nofollow_flag = getattr(os, "O_NOFOLLOW", None)
        if directory_flag is None or nofollow_flag is None:
            raise LIVE.AdmissionError(
                "reviewed source no-follow directory opens are unavailable"
            )
        self.source_root = source_root
        self._directory_flags = (
            os.O_RDONLY
            | directory_flag
            | nofollow_flag
            | getattr(os, "O_CLOEXEC", 0)
        )
        self._directories: dict[
            tuple[str, ...],
            tuple[pathlib.Path, int, tuple[int, int]],
        ] = {}
        self._held_files: dict[
            tuple[str, ...],
            tuple[pathlib.Path, int, tuple[int, ...]],
        ] = {}
        self._fds: list[int] = []
        self._layout: str | None = None
        self._source_root_key = tuple(source_root.parts[1:])
        self._open_absolute_directory_chain()

    @staticmethod
    def _identity(info: os.stat_result) -> tuple[int, int]:
        return info.st_dev, info.st_ino

    def _display(self, parts: tuple[str, ...]) -> str:
        root_length = len(self._source_root_key)
        if parts[:root_length] == self._source_root_key:
            return "/".join(parts[root_length:]) or "."
        return "/" + "/".join(parts)

    @staticmethod
    def _metadata(info: os.stat_result) -> tuple[int, ...]:
        return (
            info.st_dev,
            info.st_ino,
            info.st_size,
            info.st_mtime_ns,
            info.st_ctime_ns,
            info.st_mode,
            info.st_uid,
            info.st_gid,
            info.st_nlink,
        )

    def _record_directory(
        self, parts: tuple[str, ...], path: pathlib.Path, fd: int
    ) -> None:
        info = os.fstat(fd)
        self._directories[parts] = (path, fd, self._identity(info))
        self._fds.append(fd)

    def _open_absolute_directory_chain(self) -> None:
        root_path = pathlib.Path("/")
        try:
            before = root_path.lstat()
        except OSError as exc:
            raise LIVE.AdmissionError(
                "reviewed source filesystem root is unavailable"
            ) from exc
        if stat.S_ISLNK(before.st_mode) or not stat.S_ISDIR(before.st_mode):
            raise LIVE.AdmissionError("reviewed source filesystem root is unsafe")
        try:
            root_fd = os.open(root_path, self._directory_flags)
        except OSError as exc:
            raise LIVE.AdmissionError(
                "reviewed source filesystem root cannot be opened"
            ) from exc
        try:
            opened = os.fstat(root_fd)
            named = root_path.lstat()
            if (
                not stat.S_ISDIR(opened.st_mode)
                or not stat.S_ISDIR(named.st_mode)
                or self._identity(before) != self._identity(opened)
                or self._identity(opened) != self._identity(named)
            ):
                raise LIVE.AdmissionError(
                    "reviewed source filesystem root changed while opening"
                )
            self._record_directory((), root_path, root_fd)
        except BaseException:
            os.close(root_fd)
            raise

        try:
            parent_key: tuple[str, ...] = ()
            for component in self._source_root_key:
                child_key = parent_key + (component,)
                self._open_child_directory(parent_key, component, child_key)
                parent_key = child_key
            self.revalidate()
        except BaseException:
            self.close()
            raise

    def _open_child_directory(
        self,
        parent_key: tuple[str, ...],
        component: str,
        child_key: tuple[str, ...],
    ) -> int:
        if child_key in self._directories:
            return self._directories[child_key][1]
        parent_fd = self._directories[parent_key][1]
        relative = self._display(child_key)
        self.revalidate()
        try:
            before = os.stat(component, dir_fd=parent_fd, follow_symlinks=False)
        except OSError as exc:
            raise LIVE.AdmissionError(
                f"reviewed source directory is unavailable: {relative}"
            ) from exc
        if stat.S_ISLNK(before.st_mode) or not stat.S_ISDIR(before.st_mode):
            raise LIVE.AdmissionError(
                f"reviewed source directory is unsafe: {relative}"
            )
        try:
            child_fd = os.open(
                component, self._directory_flags, dir_fd=parent_fd
            )
        except OSError as exc:
            raise LIVE.AdmissionError(
                f"reviewed source directory cannot be opened: {relative}"
            ) from exc
        try:
            opened = os.fstat(child_fd)
            named = os.stat(component, dir_fd=parent_fd, follow_symlinks=False)
            if (
                stat.S_ISLNK(named.st_mode)
                or not stat.S_ISDIR(opened.st_mode)
                or not stat.S_ISDIR(named.st_mode)
                or self._identity(before) != self._identity(opened)
                or self._identity(opened) != self._identity(named)
            ):
                raise LIVE.AdmissionError(
                    f"reviewed source directory changed: {relative}"
                )
            path = pathlib.Path("/").joinpath(*child_key)
            self._record_directory(child_key, path, child_fd)
        except BaseException:
            os.close(child_fd)
            raise
        self.revalidate()
        return child_fd

    def close(self) -> None:
        for fd in reversed(self._fds):
            with contextlib.suppress(OSError):
                os.close(fd)
        self._fds.clear()
        self._held_files.clear()
        self._directories.clear()

    def revalidate(self) -> None:
        for parts, (path, fd, expected_identity) in self._directories.items():
            relative = self._display(parts)
            try:
                held = os.fstat(fd)
                named = path.lstat()
            except OSError as exc:
                raise LIVE.AdmissionError(
                    f"reviewed source directory changed: {relative}"
                ) from exc
            if (
                stat.S_ISLNK(named.st_mode)
                or not stat.S_ISDIR(held.st_mode)
                or not stat.S_ISDIR(named.st_mode)
            ):
                raise LIVE.AdmissionError(
                    f"reviewed source directory is unsafe: {relative}"
                )
            if (
                self._identity(held) != expected_identity
                or self._identity(named) != expected_identity
            ):
                raise LIVE.AdmissionError(
                    f"reviewed source directory changed: {relative}"
                )
        for parts, (path, fd, expected_metadata) in self._held_files.items():
            relative = "/".join(parts)
            parent_key = self._source_root_key + parts[:-1]
            parent_fd = self._directories[parent_key][1]
            try:
                held = os.fstat(fd)
                named = os.stat(parts[-1], dir_fd=parent_fd, follow_symlinks=False)
                named_path = path.lstat()
            except OSError as exc:
                raise LIVE.AdmissionError(
                    f"reviewed source layout discriminator changed: {relative}"
                ) from exc
            if stat.S_ISLNK(named.st_mode) or stat.S_ISLNK(named_path.st_mode):
                raise LIVE.AdmissionError(
                    f"reviewed source layout discriminator became a symlink: {relative}"
                )
            if (
                not stat.S_ISREG(held.st_mode)
                or not stat.S_ISREG(named.st_mode)
                or not stat.S_ISREG(named_path.st_mode)
            ):
                raise LIVE.AdmissionError(
                    f"reviewed source layout discriminator changed type: {relative}"
                )
            if (
                self._metadata(held) != expected_metadata
                or self._metadata(named) != expected_metadata
                or self._metadata(named_path) != expected_metadata
            ):
                raise LIVE.AdmissionError(
                    f"reviewed source layout discriminator changed: {relative}"
                )
        if self._layout == "repository":
            root_fd = self._directories[self._source_root_key][1]
            for sibling in ("lib", "labs"):
                try:
                    info = os.stat(
                        sibling, dir_fd=root_fd, follow_symlinks=False
                    )
                except FileNotFoundError:
                    continue
                except OSError as exc:
                    raise LIVE.AdmissionError(
                        f"reviewed source path is unavailable: {sibling}"
                    ) from exc
                if stat.S_ISLNK(info.st_mode):
                    raise LIVE.AdmissionError(
                        f"reviewed source directory is unsafe: {sibling}"
                    )
                raise LIVE.AdmissionError("reviewed source layouts are mixed")
        elif self._layout == "installed" and ("labctl",) not in self._held_files:
            raise LIVE.AdmissionError(
                "reviewed source installed layout discriminator is not held"
            )

    def hold_layout_file(self, relative: tuple[str, ...]) -> None:
        if not relative:
            raise LIVE.AdmissionError("reviewed source layout path is empty")
        parent_fd = self.open_relative_directory(relative[:-1])
        leaf = relative[-1]
        display = "/".join(relative)
        self.revalidate()
        try:
            before = os.stat(leaf, dir_fd=parent_fd, follow_symlinks=False)
        except OSError as exc:
            raise LIVE.AdmissionError(
                f"reviewed source layout discriminator is unavailable: {display}"
            ) from exc
        if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
            raise LIVE.AdmissionError(
                f"reviewed source layout discriminator is unsafe: {display}"
            )
        flags = (
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NONBLOCK", 0)
            | getattr(os, "O_NOFOLLOW")
        )
        try:
            fd = os.open(leaf, flags, dir_fd=parent_fd)
        except OSError as exc:
            raise LIVE.AdmissionError(
                f"reviewed source layout discriminator cannot be opened: {display}"
            ) from exc
        try:
            opened = os.fstat(fd)
            named = os.stat(leaf, dir_fd=parent_fd, follow_symlinks=False)
            if (
                not stat.S_ISREG(opened.st_mode)
                or not stat.S_ISREG(named.st_mode)
                or self._metadata(before) != self._metadata(opened)
                or self._metadata(opened) != self._metadata(named)
            ):
                raise LIVE.AdmissionError(
                    f"reviewed source layout discriminator changed: {display}"
                )
            path = self.source_root.joinpath(*relative)
            self._held_files[relative] = (path, fd, self._metadata(opened))
            self._fds.append(fd)
        except BaseException:
            os.close(fd)
            raise
        self.revalidate()

    def select_layout(self, layout: str) -> None:
        if layout not in ("repository", "installed"):
            raise LIVE.AdmissionError("reviewed source layout is unsupported")
        if layout == "installed":
            self.hold_layout_file(("labctl",))
        self._layout = layout
        self.revalidate()

    def open_relative_directory(self, relative: tuple[str, ...]) -> int:
        key = self._source_root_key
        for component in relative:
            child_key = key + (component,)
            self._open_child_directory(key, component, child_key)
            key = child_key
        self.revalidate()
        return self._directories[key][1]

    def stat_child(
        self,
        parent: tuple[str, ...],
        name: str,
        *,
        optional: bool = False,
    ) -> os.stat_result | None:
        parent_fd = self.open_relative_directory(parent)
        self.revalidate()
        try:
            info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError as exc:
            if optional:
                return None
            raise LIVE.AdmissionError(
                f"reviewed source path is unavailable: {name}"
            ) from exc
        except OSError as exc:
            raise LIVE.AdmissionError(
                f"reviewed source path is unavailable: {name}"
            ) from exc
        self.revalidate()
        return info

    def read_regular(self, relative: tuple[str, ...], maximum: int) -> bytes:
        if not relative:
            raise LIVE.AdmissionError("reviewed source file path is empty")
        parent_fd = self.open_relative_directory(relative[:-1])
        leaf = relative[-1]
        display = "/".join(relative)
        self.revalidate()
        try:
            before = os.stat(leaf, dir_fd=parent_fd, follow_symlinks=False)
        except OSError as exc:
            raise LIVE.AdmissionError(
                f"reviewed source file is unavailable: {display}"
            ) from exc
        if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
            raise LIVE.AdmissionError(
                f"reviewed source file is unsafe: {display}"
            )
        if before.st_size > maximum:
            raise LIVE.AdmissionError(
                f"reviewed source file exceeds size bound: {display}"
            )
        leaf_flags = (
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NONBLOCK", 0)
            | getattr(os, "O_NOFOLLOW")
        )
        try:
            fd = os.open(leaf, leaf_flags, dir_fd=parent_fd)
        except OSError as exc:
            raise LIVE.AdmissionError(
                f"reviewed source file cannot be opened: {display}"
            ) from exc
        try:
            opened = os.fstat(fd)
            if (
                not stat.S_ISREG(opened.st_mode)
                or self._metadata(opened) != self._metadata(before)
            ):
                raise LIVE.AdmissionError(
                    f"reviewed source file changed while opening: {display}"
                )
            data = bytearray()
            while len(data) <= maximum:
                chunk = os.read(fd, min(65536, maximum + 1 - len(data)))
                if not chunk:
                    break
                data.extend(chunk)
            if len(data) > maximum:
                raise LIVE.AdmissionError(
                    f"reviewed source file exceeds size bound: {display}"
                )
            after_held = os.fstat(fd)
            after_named = os.stat(
                leaf, dir_fd=parent_fd, follow_symlinks=False
            )
            if (
                not stat.S_ISREG(after_held.st_mode)
                or not stat.S_ISREG(after_named.st_mode)
                or self._metadata(after_held) != self._metadata(before)
                or self._metadata(after_named) != self._metadata(before)
            ):
                raise LIVE.AdmissionError(
                    f"reviewed source file changed while reading: {display}"
                )
            self.revalidate()
            return bytes(data)
        finally:
            os.close(fd)


def _reviewed_source_layout(tree: _ReviewedSourceTree) -> str:
    labctl_info = tree.stat_child((), "labctl")
    assert labctl_info is not None
    if stat.S_ISLNK(labctl_info.st_mode):
        raise LIVE.AdmissionError("reviewed source labctl entry is a symlink")

    if stat.S_ISDIR(labctl_info.st_mode):
        for relative in ("lib", "labs"):
            sibling = tree.stat_child((), relative, optional=True)
            if sibling is None:
                continue
            if stat.S_ISLNK(sibling.st_mode):
                raise LIVE.AdmissionError(
                    f"reviewed source directory is unsafe: {relative}"
                )
            raise LIVE.AdmissionError("reviewed source layouts are mixed")
        tree.open_relative_directory(("labctl",))
        tree.open_relative_directory(("labctl", "lib"))
        tree.open_relative_directory(("labctl", "labs"))
        tree.select_layout("repository")
        return "repository"

    if stat.S_ISREG(labctl_info.st_mode):
        tree.open_relative_directory(("lib",))
        tree.open_relative_directory(("labs",))
        tree.select_layout("installed")
        return "installed"

    raise LIVE.AdmissionError(
        "reviewed source labctl entry has an unsupported type"
    )


def _reviewed_source_path(
    source_root: pathlib.Path, relative: str, layout: str
) -> pathlib.Path:
    path = pathlib.PurePosixPath(relative)
    if (
        path.is_absolute()
        or not path.parts
        or ".." in path.parts
        or "\\" in relative
    ):
        raise LIVE.AdmissionError("reviewed source path is unsafe")
    if layout == "repository":
        if relative == "labctl":
            return source_root / "labctl/labctl"
        if relative.startswith(("lib/", "labs/")):
            return source_root / "labctl" / relative
    elif layout != "installed":
        raise LIVE.AdmissionError("reviewed source layout is unsupported")
    return source_root / relative


def _reviewed_source_bytes(source_root: pathlib.Path) -> dict[str, bytes]:
    if (
        LIVE._digest(LIVE.REVIEWED_BUNDLE_FILES)
        != LIVE.REVIEWED_BUNDLE_MANIFEST_SHA256
    ):
        raise LIVE.AdmissionError(
            "compiled reviewed bundle manifest pin is inconsistent"
        )
    tree = _ReviewedSourceTree(source_root)
    try:
        layout = _reviewed_source_layout(tree)
        sources: dict[str, bytes] = {}
        for relative, expected_digest in LIVE.REVIEWED_BUNDLE_FILES.items():
            file_parts = pathlib.PurePosixPath(relative)
            if (
                file_parts.is_absolute()
                or not file_parts.parts
                or ".." in file_parts.parts
                or "\\" in relative
            ):
                raise LIVE.AdmissionError("reviewed source path is unsafe")
            if layout == "repository":
                if relative == "labctl":
                    parts = ("labctl", "labctl")
                elif relative.startswith(("lib/", "labs/")):
                    parts = ("labctl",) + file_parts.parts
                else:
                    parts = file_parts.parts
            else:
                parts = file_parts.parts
            data = tree.read_regular(parts, maximum=8 * 1024 * 1024)
            if hashlib.sha256(data).hexdigest() != expected_digest:
                raise LIVE.AdmissionError(
                    f"reviewed source digest changed: {relative}"
                )
            tree.revalidate()
            sources[relative] = data
        tree.revalidate()
        return sources
    finally:
        tree.close()


def _stage_source_layout_fixture(
    root: pathlib.Path, layout: str, sources: dict[str, bytes]
) -> None:
    root.mkdir(mode=0o755, parents=True)
    for relative, data in sources.items():
        source = _reviewed_source_path(root, relative, layout)
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_bytes(data)
        source.chmod(
            0o755 if relative == "labctl" or relative.endswith(".sh") else 0o644
        )
    for path in [root, *root.rglob("*")]:
        if path.is_dir():
            path.chmod(0o755)


def _expect_reviewed_source_failure(
    source_root: pathlib.Path, expected_cause: str, label: str
) -> Exception:
    error = expect_error(
        LIVE.AdmissionError,
        lambda: _reviewed_source_bytes(source_root),
        label,
    )
    assert expected_cause in str(error), f"{label}: unexpected cause: {error}"
    return error


def reviewed_bundle_checks() -> None:
    source_root = HERE.parents[2]
    source_bytes = _reviewed_source_bytes(source_root)

    for layout in ("repository", "installed"):
        with tempfile.TemporaryDirectory() as directory:
            fixture_parent = pathlib.Path(directory).resolve()
            fixture_root = fixture_parent / layout
            _stage_source_layout_fixture(fixture_root, layout, source_bytes)
            assert _reviewed_source_bytes(fixture_root) == source_bytes

    with tempfile.TemporaryDirectory() as directory:
        fixture_parent = pathlib.Path(directory).resolve()
        real_parent = fixture_parent / "real-parent"
        real_parent.mkdir()
        fixture_root = real_parent / "repository"
        _stage_source_layout_fixture(fixture_root, "repository", source_bytes)
        linked_parent = fixture_parent / "linked-parent"
        linked_parent.symlink_to(real_parent, target_is_directory=True)
        _expect_reviewed_source_failure(
            linked_parent / "repository",
            f"reviewed source directory is unsafe: {linked_parent}",
            "symlinked absolute source ancestor",
        )

    with tempfile.TemporaryDirectory() as directory:
        fixture_parent = pathlib.Path(directory).resolve()
        fixture_root = fixture_parent / "repository"
        _stage_source_layout_fixture(fixture_root, "repository", source_bytes)
        (fixture_root / "lib").mkdir()
        (fixture_root / "labs").mkdir()
        _expect_reviewed_source_failure(
            fixture_root,
            "reviewed source layouts are mixed",
            "mixed source layouts",
        )

    with tempfile.TemporaryDirectory() as directory:
        fixture_parent = pathlib.Path(directory).resolve()
        fixture_root = fixture_parent / "repository"
        _stage_source_layout_fixture(fixture_root, "repository", source_bytes)
        missing = fixture_root / "labctl/lib/common.sh"
        missing.unlink()
        _expect_reviewed_source_failure(
            fixture_root,
            "reviewed source file is unavailable: labctl/lib/common.sh",
            "missing reviewed source",
        )

    with tempfile.TemporaryDirectory() as directory:
        fixture_parent = pathlib.Path(directory).resolve()
        fixture_root = fixture_parent / "repository"
        _stage_source_layout_fixture(fixture_root, "repository", source_bytes)
        common = fixture_root / "labctl/lib/common.sh"
        outside = fixture_parent / "outside-common.sh"
        outside.write_bytes(source_bytes["lib/common.sh"])
        common.unlink()
        common.symlink_to(outside)
        _expect_reviewed_source_failure(
            fixture_root,
            "reviewed source file is unsafe: labctl/lib/common.sh",
            "symlinked reviewed source",
        )

    with tempfile.TemporaryDirectory() as directory:
        fixture_parent = pathlib.Path(directory).resolve()
        fixture_root = fixture_parent / "repository"
        _stage_source_layout_fixture(fixture_root, "repository", source_bytes)
        library = fixture_root / "labctl/lib"
        parked_library = fixture_parent / "parked-lib"
        library.rename(parked_library)
        library.symlink_to(parked_library, target_is_directory=True)
        _expect_reviewed_source_failure(
            fixture_root,
            "reviewed source directory is unsafe: labctl/lib",
            "symlinked reviewed source directory",
        )

    with tempfile.TemporaryDirectory() as directory:
        fixture_parent = pathlib.Path(directory).resolve()
        fixture_root = fixture_parent / "repository"
        _stage_source_layout_fixture(fixture_root, "repository", source_bytes)
        common = fixture_root / "labctl/lib/common.sh"
        common.write_bytes(source_bytes["lib/common.sh"] + b"\n# foreign\n")
        _expect_reviewed_source_failure(
            fixture_root,
            "reviewed source digest changed: lib/common.sh",
            "changed reviewed source bytes",
        )

    with tempfile.TemporaryDirectory() as directory:
        fixture_parent = pathlib.Path(directory).resolve()
        fixture_root = fixture_parent / "repository"
        _stage_source_layout_fixture(fixture_root, "repository", source_bytes)
        ancestor = fixture_root / "labctl"
        parked = fixture_parent / "parked-labctl"
        real_read = os.read
        swapped = False

        def swap_ancestor_to_symlink(fd, size):
            nonlocal swapped
            if not swapped:
                ancestor.rename(parked)
                ancestor.symlink_to(parked, target_is_directory=True)
                swapped = True
            return real_read(fd, size)

        with mock.patch.object(os, "read", side_effect=swap_ancestor_to_symlink):
            _expect_reviewed_source_failure(
                fixture_root,
                "reviewed source directory is unsafe: labctl",
                "ancestor replaced by symlink during source read",
            )
        assert swapped

    with tempfile.TemporaryDirectory() as directory:
        fixture_parent = pathlib.Path(directory).resolve()
        fixture_root = fixture_parent / "repository"
        replacement_root = fixture_parent / "replacement"
        _stage_source_layout_fixture(fixture_root, "repository", source_bytes)
        _stage_source_layout_fixture(replacement_root, "repository", source_bytes)
        assert _reviewed_source_bytes(replacement_root) == source_bytes
        ancestor = fixture_root / "labctl"
        parked = fixture_parent / "parked-labctl"
        replacement = replacement_root / "labctl"
        real_read = os.read
        replaced = False

        def replace_ancestor_directory(fd, size):
            nonlocal replaced
            if not replaced:
                ancestor.rename(parked)
                replacement.rename(ancestor)
                replaced = True
            return real_read(fd, size)

        with mock.patch.object(os, "read", side_effect=replace_ancestor_directory):
            _expect_reviewed_source_failure(
                fixture_root,
                "reviewed source directory changed: labctl",
                "ancestor replaced by real directory during source read",
            )
        assert replaced

    with tempfile.TemporaryDirectory() as directory:
        fixture_parent = pathlib.Path(directory).resolve()
        fixture_root = fixture_parent / "installed"
        _stage_source_layout_fixture(fixture_root, "installed", source_bytes)
        discriminator = fixture_root / "labctl"
        parked = fixture_parent / "parked-labctl"
        real_read = os.read
        read_count = 0
        replaced = False
        later_read = (len(source_bytes["labctl"]) + 65535) // 65536 + 2

        def replace_installed_discriminator_with_symlink(fd, size):
            nonlocal read_count, replaced
            read_count += 1
            if read_count == later_read:
                discriminator.rename(parked)
                discriminator.symlink_to(parked)
                replaced = True
            return real_read(fd, size)

        with mock.patch.object(
            os, "read", side_effect=replace_installed_discriminator_with_symlink
        ):
            _expect_reviewed_source_failure(
                fixture_root,
                "reviewed source layout discriminator became a symlink: labctl",
                "installed discriminator replaced by symlink during later source read",
            )
        assert replaced and parked.read_bytes() == source_bytes["labctl"]

    with tempfile.TemporaryDirectory() as directory:
        fixture_parent = pathlib.Path(directory).resolve()
        fixture_root = fixture_parent / "installed"
        replacement_root = fixture_parent / "replacement"
        _stage_source_layout_fixture(fixture_root, "installed", source_bytes)
        _stage_source_layout_fixture(replacement_root, "repository", source_bytes)
        assert _reviewed_source_bytes(replacement_root) == source_bytes
        discriminator = fixture_root / "labctl"
        parked = fixture_parent / "parked-labctl"
        replacement = replacement_root / "labctl"
        real_read = os.read
        read_count = 0
        replaced = False
        later_read = (len(source_bytes["labctl"]) + 65535) // 65536 + 2

        def replace_installed_discriminator_with_directory(fd, size):
            nonlocal read_count, replaced
            read_count += 1
            if read_count == later_read:
                discriminator.rename(parked)
                replacement.rename(discriminator)
                replaced = True
            return real_read(fd, size)

        with mock.patch.object(
            os, "read", side_effect=replace_installed_discriminator_with_directory
        ):
            _expect_reviewed_source_failure(
                fixture_root,
                "reviewed source layout discriminator changed type: labctl",
                "installed discriminator replaced by real directory during later source read",
            )
        assert replaced

    with tempfile.TemporaryDirectory() as directory:
        fixture_parent = pathlib.Path(directory).resolve()
        fixture_root = fixture_parent / "repository"
        _stage_source_layout_fixture(fixture_root, "repository", source_bytes)
        real_read = os.read
        real_revalidate = _ReviewedSourceTree.revalidate
        read_count = 0
        expected_reads = sum(
            (len(data) + 65535) // 65536 + 1 for data in source_bytes.values()
        )
        siblings_created = False

        def count_source_reads(fd, size):
            nonlocal read_count
            data = real_read(fd, size)
            read_count += 1
            return data

        def add_repository_siblings_after_final_leaf(tree):
            nonlocal siblings_created
            result = real_revalidate(tree)
            if not siblings_created and read_count == expected_reads:
                (fixture_root / "lib").mkdir()
                (fixture_root / "labs").mkdir()
                siblings_created = True
            return result

        with (
            mock.patch.object(os, "read", side_effect=count_source_reads),
            mock.patch.object(
                _ReviewedSourceTree,
                "revalidate",
                new=add_repository_siblings_after_final_leaf,
            ),
        ):
            _expect_reviewed_source_failure(
                fixture_root,
                "reviewed source layouts are mixed",
                "repository siblings created before final bundle revalidation",
            )
        assert siblings_created and read_count == expected_reads

    def stage(root: pathlib.Path) -> None:
        for relative, data in source_bytes.items():
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            target.chmod(0o755 if relative == "labctl" else 0o644)
        for path in [root, *root.rglob("*")]:
            if path.is_dir():
                path.chmod(0o755)

    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory).resolve() / "bundle"
        stage(root)
        assert (
            LIVE._verify_reviewed_bundle(root, required_uid=os.getuid())
            == LIVE.REVIEWED_BUNDLE_MANIFEST_SHA256
        )
        helper = root / "lib/common.sh"
        helper.write_bytes(helper.read_bytes() + b"\n# foreign\n")
        expect_error(
            LIVE.AdmissionError,
            lambda: LIVE._verify_reviewed_bundle(root, required_uid=os.getuid()),
            "changed sourced helper",
        )

    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory).resolve() / "bundle"
        stage(root)
        optional = root / "labctl.env"
        optional.write_text("FOREIGN=1\n")
        optional.chmod(0o600)
        expect_error(
            LIVE.AdmissionError,
            lambda: LIVE._verify_reviewed_bundle(root, required_uid=os.getuid()),
            "unreviewed optional labctl.env",
        )

    with tempfile.TemporaryDirectory() as directory:
        fixture_parent = pathlib.Path(directory).resolve()
        root = fixture_parent / "bundle"
        stage(root)
        target = root / "studies/p004/ovn/frr-gw1.conf"
        saved = target.read_bytes()
        target.unlink()
        outside = fixture_parent / "outside"
        outside.write_bytes(saved)
        target.symlink_to(outside)
        expect_error(
            LIVE.AdmissionError,
            lambda: LIVE._verify_reviewed_bundle(root, required_uid=os.getuid()),
            "symlinked reviewed fixture",
        )

    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory).resolve() / "bundle"
        stage(root)
        root.chmod(0o775)
        expect_error(
            LIVE.AdmissionError,
            lambda: LIVE._verify_reviewed_bundle(root, required_uid=os.getuid()),
            "group-writable bundle root",
        )


def main(argv: list[str] | None = None) -> int:
    argument_parser = argparse.ArgumentParser(description=__doc__)
    argument_parser.add_argument(
        "--parser-only",
        action="store_true",
        help="run portable parser/static/dry checks and report runtime NOT_RUN",
    )
    args = argument_parser.parse_args(argv)
    parser_checks()
    fixture_and_cli_checks()
    reviewed_bundle_checks()
    if args.parser_only or sys.platform != "linux":
        print(
            "X05 runtime parser/static/dry PASS; runtime NOT_RUN: "
            "real Linux /proc/self/fdinfo is required",
            file=(
                sys.stderr
                if sys.platform != "linux" and not args.parser_only
                else sys.stdout
            ),
        )
        return 0 if args.parser_only else 77
    happy_path()
    prepared_authority_checks()
    concurrent_consume_check()
    execution_producer_happy_path()
    execution_detail_validation_checks()
    execution_capability_rejections()
    execution_helper_authority_sticky_checks()
    execution_immutable_drift_checks()
    execution_log_tamper_checks()
    execution_append_publication_drift()
    execution_lock_observer_check()
    concurrent_execution_events_check()
    execution_close_verify_race()
    continuing_marker_cleanup_guard()
    full_inventory_race_checks()
    initial_baseline_rejections()
    original_image_label_cases()
    continuing_image_label_drift()
    complete_m03_identity_checks()
    drift_cases()
    readback_failures()
    path_failures()
    lifecycle_failures()
    unexpected_x05_marker()
    replaced_m03_before_cleanup()
    lock_failures()
    lock_keeper_boundary_checks()
    observational_syscall_checks()
    scheduled_lock_loss_regressions()
    procfs_observation_failures()
    lock_authority_regressions()
    subprocess_runner_checks()
    retained_descriptor_session_check()
    print(
        "X05 runtime live selftest PASS: active authority, 43-resource rechecks, "
        "complete identities, provenance, observational FD9/OFD authority, "
        "truthful retention, bounded execution events, and bounded I/O negatives"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
