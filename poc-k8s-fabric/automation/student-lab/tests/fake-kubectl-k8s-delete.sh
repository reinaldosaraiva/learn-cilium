#!/usr/bin/env bash
set -euo pipefail

object_file="${P010_HYBRID_FAKE_KUBECTL_OBJECT_JSON:?}"
expected_path_file="${P010_HYBRID_FAKE_KUBECTL_EXPECTED_PATH_FILE:?}"
deletes_file="${P010_HYBRID_FAKE_KUBECTL_DELETES:?}"
calls_file="${P010_HYBRID_FAKE_KUBECTL_CALLS:?}"

while (($#)); do
  case "$1" in
    --kubeconfig|--context) shift 2 ;;
    *) break ;;
  esac
done

case "${1:-}" in
  get)
    if [[ -f "${object_file}" ]]; then
      cat -- "${object_file}"
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
    [[ "${raw_path}" == "$(<"${expected_path_file}")" ]]
    [[ -f "${object_file}" && -f "${options_file}" ]]
    grep -Fq '55555555-5555-4555-8555-555555555555' "${options_file}"
    printf '%s\n' "${raw_path}" >>"${calls_file}"
    count="$(<"${deletes_file}")"
    printf '%s\n' "$((count + 1))" >"${deletes_file}"
    rm -- "${object_file}"
    ;;
  *)
    printf 'unexpected fake kubectl action\n' >&2
    exit 84
    ;;
esac
