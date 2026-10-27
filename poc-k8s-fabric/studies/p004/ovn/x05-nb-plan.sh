#!/usr/bin/env bash
# Pure-local X05 NB inventory. This file has no OVSDB connection or apply mode.
# Static-route names are plan identities; NB identifies those rows by parent,
# ip_prefix, nexthop and the captured UUID, not by a name column.
set -euo pipefail

usage() { printf 'Usage: %s --plan|--check\n' "$0" >&2; }
[[ $# -eq 1 ]] || { usage; exit 2; }
case "$1" in --plan|--check) mode="$1" ;; *) usage; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { echo 'jq is required' >&2; exit 2; }

plan() {
  jq -n '
    def owner: {external_ids: {"x05-owner": "<token>"}};
    def row($table; $name; $parent; $values):
      {id: ($table + ":" + $name), table: $table, name: $name,
       parent: $parent, values: ($values + owner), ownership: "X05",
       precondition: "absent; never adopt"};
    def ls($name; $values): row("Logical_Switch"; $name; null; $values);
    def lr($name; $values): row("Logical_Router"; $name; null; $values);
    def lrp($name; $parent; $mac; $network; $extra):
      row("Logical_Router_Port"; $name; $parent;
          {mac: $mac, networks: [$network]} + $extra);
    def lsp($name; $parent; $type; $addresses; $options; $extra):
      row("Logical_Switch_Port"; $name; $parent;
          {type: $type, addresses: $addresses, options: $options} + $extra);
    def route($name; $parent; $prefix; $nexthop; $options):
      row("Logical_Router_Static_Route"; $name; $parent;
          {ip_prefix: $prefix, nexthop: $nexthop, options: $options});
    def leg($v; $gw; $vlan; $ip; $mac; $octet; $transit):
      ("lr-x05-" + $v) as $r |
      ("ls-x05-" + $v + "-external") as $e |
      ("ls-x05-" + $v + "-transit") as $t |
      [lr($r; {options: {"dynamic-routing": "true",
                            "dynamic-routing-vrf-name": ("ovnvrf" + $v),
                            "dynamic-routing-vrf-id": $v,
                            "dynamic-routing-redistribute": "connected,static"}}),
       ls($e; {}), ls($t; {}),
       lrp("lrp-x05-" + $v + "-external"; $r; $mac; $ip;
           {options: {"routing-protocols": "BGP,BFD",
                      "routing-protocol-redirect": ("bgpvrf" + $v),
                      "dynamic-routing-maintain-vrf": "true",
                      gateway_mtu: "1500"}})
         + {references: {gateway_chassis: [("gc-x05-" + $v)]}},
       row("Gateway_Chassis"; "gc-x05-" + $v;
           "lrp-x05-" + $v + "-external";
           {chassis_name: $gw, priority: 20}),
       lsp("lsp-x05-" + $v + "-router"; $e; "router"; ["router"];
           {"router-port": ("lrp-x05-" + $v + "-external")}; {}),
       lsp("ln-x05-" + $v; $e; "localnet"; ["unknown"];
           {network_name: "public"}; {tag_request: ($vlan | tonumber)}),
       lsp("bgpvrf" + $v; $e; ""; ["unknown"]; {}; {}),
       lrp("lrp-x05-" + $v + "-tenant"; $r;
           ("02:00:" + $octet + ":00:00:02"); ($transit + ".2/30"); {}),
       lsp("lsp-x05-" + $v + "-tenant"; $t; "router"; ["router"];
           {"router-port": ("lrp-x05-" + $v + "-tenant")}; {}),
       lrp("lrp-x05-tenant-b-" + $v; "lr-x05-tenant-b";
           ("02:00:" + $octet + ":00:00:01"); ($transit + ".1/30"); {}),
       lsp("lsp-x05-tenant-b-" + $v; $t; "router"; ["router"];
           {"router-port": ("lrp-x05-tenant-b-" + $v)}; {}),
       route("route-x05-" + $v + "-to-b"; $r;
             "192.168.100.0/24"; ($transit + ".1"); {})];
    ([ls("ls-x05-tenant-b";
          {other_config: {subnet: "192.168.100.0/24",
                          "dynamic-routing-vni": "50200",
                          "dynamic-routing-bridge-ifname": "br-x05-b",
                          "dynamic-routing-vxlan-ifname": "vxlan-x05-b",
                          "dynamic-routing-advertise-ifname": "evpn-x05-b",
                          "dynamic-routing-redistribute": "fdb"}}),
      lr("lr-x05-tenant-b";
         {options: {"dynamic-routing": "true",
                    "dynamic-routing-vrf-name": "ovnvrf-x05-b",
                    "dynamic-routing-vrf-id": "400",
                    "dynamic-routing-redistribute": "connected,static",
                    chassis: "ovn-chassis-2"}})]
     + leg("300"; "ovn-gw-1"; "300"; "169.254.254.1/30";
           "02:00:2c:00:00:01"; "1f"; "10.31.100")
     + leg("400"; "ovn-gw-2"; "400"; "169.254.254.5/30";
           "02:00:90:00:00:01"; "29"; "10.41.100")
     + [lrp("lrp-x05-tenant-b"; "lr-x05-tenant-b";
            "02:00:00:20:00:01"; "192.168.100.1/24";
            {options: {"dynamic-routing-port-name": "x05-b-<six-hex-run-token>",
                       "dynamic-routing-maintain-vrf": "true"}}),
        lsp("lsp-x05-tenant-b-router"; "ls-x05-tenant-b";
            "router"; ["router"];
            {"router-port": "lrp-x05-tenant-b"}; {}),
        lsp("x05-tenant-b-vm"; "ls-x05-tenant-b"; "";
            ["02:00:00:10:00:12 192.168.100.12"]; {}; {}),
        lsp("x05-tenant-a-vm"; "ls-dci-tenant"; "";
            ["02:00:00:10:00:11 192.168.100.11"]; {}; {}),
        route("route-x05-b-return-300"; "lr-x05-tenant-b";
              "10.0.0.0/16"; "10.31.100.2";
              {ecmp_symmetric_reply: "true"}),
        route("route-x05-b-return-400"; "lr-x05-tenant-b";
              "10.0.0.0/16"; "10.41.100.2";
              {ecmp_symmetric_reply: "true"})]) as $objects
    | {schema: "p004-x05-nb-plan-v1", owner_token_placeholder: "<token>",
       adoption: "forbidden; every X05 row must be absent before creation",
       route_identity: "plan name is synthetic; select NB row by router UUID, prefix and nexthop, then capture UUID",
       reference_resolution: "references hold plan IDs; resolve to captured NB UUIDs before setting database reference columns",
       exceptions: [
         {name: "ls-dci-tenant", owner: "M03", change: "ports set only, guarded CAS; restore exact original set"},
         {name: "lr-dci-tenant", owner: "M03", change: "none"},
         {name: "lrp-dci-tenant", owner: "M03", change: "none"}],
       objects: $objects,
       inverse_dependency_order: ($objects | reverse | map(.id))}
  '
}

if [[ "$mode" == --plan ]]; then
  plan
  exit
fi

plan | jq -e '
  def leg_names($v):
    ["lr-x05-" + $v, "ls-x05-" + $v + "-external",
     "ls-x05-" + $v + "-transit", "lrp-x05-" + $v + "-external",
     "gc-x05-" + $v, "lsp-x05-" + $v + "-router",
     "ln-x05-" + $v, "bgpvrf" + $v,
     "lrp-x05-" + $v + "-tenant", "lsp-x05-" + $v + "-tenant",
     "lrp-x05-tenant-b-" + $v, "lsp-x05-tenant-b-" + $v,
     "route-x05-" + $v + "-to-b"];
  def expected_names:
    ["ls-x05-tenant-b", "lr-x05-tenant-b"]
    + leg_names("300") + leg_names("400")
    + ["lrp-x05-tenant-b", "lsp-x05-tenant-b-router",
       "x05-tenant-b-vm", "x05-tenant-a-vm",
       "route-x05-b-return-300", "route-x05-b-return-400"];
  .schema == "p004-x05-nb-plan-v1"
  and .owner_token_placeholder == "<token>"
  and .adoption == "forbidden; every X05 row must be absent before creation"
  and ([.exceptions[].name] == ["ls-dci-tenant", "lr-dci-tenant", "lrp-dci-tenant"])
  and (.objects | length) == 34
  and ([.objects[].name] == expected_names)
  and ([.objects[].id] | unique | length) == 34
  and ([.objects[] | select(.values.external_ids."x05-owner" != "<token>")] | length) == 0
  and ([.objects[] | select(.precondition != "absent; never adopt")] | length) == 0
  and ([.objects[] | select(.parent == "ls-dci-tenant")] | map(.name) == ["x05-tenant-a-vm"])
  and ([.objects[] | select(.name == "x05-tenant-a-vm" or .name == "x05-tenant-b-vm") | .values.addresses[0]] ==
       ["02:00:00:10:00:12 192.168.100.12", "02:00:00:10:00:11 192.168.100.11"])
  and ([.objects[] | select(.values.networks[]? | test("^10\\.(31|41)\\.100\\.[12]/30$"))] | length) == 4
  and ([.objects[] | select(.values.nexthop? == "10.31.100.2" or .values.nexthop? == "10.41.100.2")] | length) == 2
  and ([.objects[] | select(.table == "Gateway_Chassis") | [.values.chassis_name, .values.priority]] == [["ovn-gw-1", 20], ["ovn-gw-2", 20]])
  and ([.objects[] | select(.table == "Logical_Router_Port" and .references.gateway_chassis? != null)
        | .references.gateway_chassis[0]] == ["gc-x05-300", "gc-x05-400"])
  and ([.objects[] | select(.values.options.ecmp_symmetric_reply? == "true")] | length) == 2
  and ([.objects[] | select(.name == "lrp-x05-tenant-b")
        | .values.options."dynamic-routing-maintain-vrf"] == ["true"])
  and ([.objects[] | select(.values.networks[]? | test("10\\.(300|400)\\."))] | length) == 0
  and (.inverse_dependency_order == ([.objects[].id] | reverse))
  and ([.objects[] | select(.parent != null and .parent != "ls-dci-tenant") | .parent] - [.objects[].name] | length) == 0
' >/dev/null
printf 'X05 NB plan PASS: 34 owned rows, M03 exceptions, explicit transit and inverse order\n'
