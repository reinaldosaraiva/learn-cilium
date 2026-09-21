#!/usr/bin/env bash
# S004 — agrega OK/FAIL por secao de um log de probes.
# Uso: bash s004-sections.sh <log>
awk 'BEGIN{sec="?"} /^===/{sec=$0; c[sec]=0; f[sec]=0}
     /^r[0-9] /{c[sec]++; if($0 ~ /FAIL$/) f[sec]++}
     END{for(s in c) printf "%-72s %3d probes %3d FAIL\n", s, c[s], f[s]}' "$1"
