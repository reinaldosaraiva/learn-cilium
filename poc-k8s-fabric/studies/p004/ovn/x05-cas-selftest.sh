#!/usr/bin/env bash
# Local protocol-shape and fail-closed checks. Never connects to OVSDB.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

bash "$here/x05-cas.sh" --build "$here/x05-cas-fixture.json" >"$work/forward.json"
jq -e '
  length == 5 and .[0] == "OVN_Northbound"
  and .[1].op == "wait" and .[1].timeout == 0
  and .[2].op == "wait" and .[2].timeout == 0
  and .[3].op == "mutate" and .[3].mutations[0][1] == "delete"
  and .[4].op == "mutate" and .[4].mutations[0][1] == "insert"
  and .[3].where[0][2] == .[1].where[0][2]
  and .[4].where[0][2] == .[2].where[0][2]
' "$work/forward.json" >/dev/null

jq '
  .source as $source | .target as $target | .lsp_uuid as $port
  | .source = ($target | .ports += [$port])
  | .target = ($source | .ports -= [$port])
' "$here/x05-cas-fixture.json" >"$work/reverse-snapshot.json"
bash "$here/x05-cas.sh" --build "$work/reverse-snapshot.json" >"$work/reverse.json"
jq -e --slurpfile forward "$work/forward.json" '
  .[1].where[0][2] == $forward[0][2].where[0][2]
  and .[2].where[0][2] == $forward[0][1].where[0][2]
' "$work/reverse.json" >/dev/null

jq '.source.ports -= [.lsp_uuid]' "$here/x05-cas-fixture.json" \
  >"$work/missing-parent.json"
if bash "$here/x05-cas.sh" --build "$work/missing-parent.json" \
  >"$work/invalid.out" 2>&1; then
  echo 'missing source parent was accepted' >&2
  exit 1
fi

printf '[{},{},{"count":1},{"count":1}]\n' >"$work/success.json"
bash "$here/x05-cas.sh" --check-result "$work/success.json" >/dev/null
printf '[{},{},{"count":0},{"count":1}]\n' >"$work/zero-count.json"
if bash "$here/x05-cas.sh" --check-result "$work/zero-count.json" \
  >"$work/invalid.out" 2>&1; then
  echo 'zero mutation count was accepted' >&2
  exit 1
fi
printf '[{"error":"timed out"},null,null,null]\n' >"$work/stale.json"
if bash "$here/x05-cas.sh" --check-result "$work/stale.json" \
  >"$work/invalid.out" 2>&1; then
  echo 'stale wait guard was accepted' >&2
  exit 1
fi
printf '[null,null,{"count":1},{"count":1}]\n' >"$work/malformed.json"
if bash "$here/x05-cas.sh" --check-result "$work/malformed.json" \
  >"$work/invalid.out" 2>&1; then
  echo 'missing wait results were accepted' >&2
  exit 1
fi

echo 'X05 CAS local selftest PASS (forward, reverse, stale parent, malformed results, counts)'
