#!/usr/bin/env bash
set -euo pipefail

object_file="${P010_HYBRID_FAKE_KUBECTL_OBJECT:?}"
uid_file="${P010_HYBRID_FAKE_KUBECTL_UID_FILE:?}"
delete_count_file="${P010_HYBRID_FAKE_KUBECTL_DELETES:?}"
uid="$(<"$uid_file")"

while (($#)); do
  case "$1" in
    --kubeconfig|--context) shift 2 ;;
    *) break ;;
  esac
done

respond_object() {
  printf '{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"p010-hyb-0123456789ab","uid":"%s","labels":{"p010-student-owner":"11111111111141118111111111111111","p010-student-run":"20261029-0123456789abcdef0123456789abcdef"}}}\n' "$uid"
}

case "${1:-}" in
  create)
    shift
    [[ "${1:-}" == -f && -f "${2:-}" ]] || exit 81
    grep -Fq 'p010-student-owner: "11111111111141118111111111111111"' "$2"
    grep -Fq 'p010-student-run: "20261029-0123456789abcdef0123456789abcdef"' "$2"
    : >"$object_file"
    respond_object
    ;;
  get)
    if [[ -f "$object_file" ]]; then
      respond_object
    fi
    ;;
  delete)
    shift
    raw_path=''
    options_file=''
    while (($#)); do
      case "$1" in
        --raw=*) raw_path="${1#--raw=}" ;;
        --filename) shift; options_file="${1:-}" ;;
        *) ;;
      esac
      shift
    done
    [[ "$raw_path" == /api/v1/namespaces/p010-hyb-0123456789ab ]] || exit 82
    [[ -f "$options_file" && -f "$object_file" ]] || exit 83
    grep -Eq '"uid"[[:space:]]*:[[:space:]]*"33333333-3333-4333-8333-333333333333"' "$options_file"
    count="$(<"$delete_count_file")"
    printf '%s\n' "$((count + 1))" >"$delete_count_file"
    rm -- "$object_file"
    ;;
  *)
    printf 'unexpected fake kubectl action\n' >&2
    exit 84
    ;;
esac
