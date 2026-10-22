#!/usr/bin/env bash
# Build and check the OVSDB transaction for moving one existing LSP.
# This tool never connects to OVSDB or mutates a lab.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: x05-cas.sh --build SNAPSHOT.json | --check-result RESULT.json

SNAPSHOT.json contains source/target LS UUIDs, their complete current ports
UUID sets, and the LSP UUID. The caller must independently prove the named
LS/LSP ownership and re-read their parent sets after a successful commit.
EOF
}

[[ $# -eq 2 && -r "$2" ]] || { usage; exit 2; }
command -v jq >/dev/null 2>&1 || { echo 'jq is required' >&2; exit 2; }

case "$1" in
  --build)
    jq -e '
      def uuid: type == "string" and test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$");
      def valid_set: type == "array" and all(.[]; uuid) and (unique | length) == length;
      def encoded_set($ports): ["set", ($ports | map(["uuid", .]))];
      def guard($ls): {
        op: "wait", timeout: 0, table: "Logical_Switch",
        where: [["_uuid", "==", ["uuid", $ls.uuid]]],
        columns: ["ports"], until: "==",
        rows: [{ports: encoded_set($ls.ports)}]
      };
      def mutate($ls; $op; $lsp): {
        op: "mutate", table: "Logical_Switch",
        where: [["_uuid", "==", ["uuid", $ls.uuid]]],
        mutations: [["ports", $op, ["set", [["uuid", $lsp]]]]]
      };
      . as $snapshot
      | if ((.source.uuid | uuid) and (.target.uuid | uuid)
          and (.lsp_uuid | uuid)
          and (.source.ports | valid_set) and (.target.ports | valid_set)
          and .source.uuid != .target.uuid
          and ([.source.ports[] | select(. == $snapshot.lsp_uuid)] | length) == 1
          and ([.target.ports[] | select(. == $snapshot.lsp_uuid)] | length) == 0)
      then ["OVN_Northbound",
            guard(.source), guard(.target),
            mutate(.source; "delete"; .lsp_uuid),
            mutate(.target; "insert"; .lsp_uuid)]
      else error("invalid LSP move snapshot or parent sets") end
    ' "$2"
    ;;
  --check-result)
    jq -e '
      . as $response
      | (if type == "object" then .result else . end) as $ops
      | if (($response | type) != "object" or $response.error == null)
            and ($ops | type) == "array" and ($ops | length) == 4
            and all($ops[]; type == "object" and (.error == null))
            and $ops[2].count == 1 and $ops[3].count == 1
        then "X05 CAS result PASS: both LS rows mutated once"
        else error("OVSDB transaction did not commit exactly one detach and attach") end
    ' "$2"
    ;;
  *) usage; exit 2 ;;
esac
