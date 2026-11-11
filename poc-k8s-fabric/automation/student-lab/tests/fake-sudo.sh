#!/usr/bin/env bash
set -euo pipefail

while (($#)); do
  case "$1" in
    -H|-S|-n|-E|-i|-k) shift ;;
    -u|-g|-p|-C) shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

exec "$@"
