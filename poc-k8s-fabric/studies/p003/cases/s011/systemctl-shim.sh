#!/bin/bash
# Container systemctl shim for DevStack-in-Docker (no systemd as PID 1).
#
# DevStack (current main) manages its API services (keystone, neutron, ...) as
# systemd template units devstack@<svc>.service whose ExecStart is a uwsgi
# command (with --venv pointing at the DevStack venv). With no systemd, a
# no-op shim leaves those uwsgi processes unstarted, so the HTTP endpoints
# never come up. This shim therefore:
#   - `start devstack@X`  -> run the unit's ExecStart in the background as its
#                            User (parsed from the unit file).
#   - `start <other>`     -> fall back to SysV `service <other> start`.
#   - `is-active devstack@X` -> true if a uwsgi for that procname-prefix lives.
#   - `stop devstack@X`   -> best-effort pkill by procname-prefix.
#   - everything else     -> tolerant no-op success (enable, daemon-reload, ...).
cmd="${1:-}"; shift || true

unit_file() {
  local u="$1"
  for f in "/etc/systemd/system/${u}.service" "/lib/systemd/system/${u}.service" \
           "/usr/lib/systemd/system/${u}.service"; do
    [ -f "$f" ] && { echo "$f"; return 0; }
  done
  return 1
}

run_unit() {
  local u="$1" f execstart user
  f=$(unit_file "$u") || return 1
  execstart=$(grep -E '^ExecStart[ =]' "$f" | head -1 | sed -E 's/^ExecStart[ =]+//')
  user=$(grep -E '^User[ =]' "$f" | head -1 | sed -E 's/^User[ =]+//')
  [ -n "$execstart" ] || return 1
  if [ -n "$user" ]; then
    sudo -u "$user" bash -c "nohup $execstart >/dev/null 2>&1 &" 2>/dev/null || \
      bash -c "nohup $execstart >/dev/null 2>&1 &"
  else
    bash -c "nohup $execstart >/dev/null 2>&1 &"
  fi
  return 0
}

case "$cmd" in
  start|restart|reload|try-restart|force-reload)
    svc="${1:-}"
    if [ -n "$svc" ] && unit_file "$svc" >/dev/null; then
      run_unit "$svc"
    else
      [ -n "$svc" ] && service "$svc" "$cmd" >/dev/null 2>&1 || true
    fi
    exit 0
    ;;
  stop)
    svc="${1:-}"
    if [ -n "$svc" ] && unit_file "$svc" >/dev/null; then
      pkill -f "procname-prefix ${svc#@}" 2>/dev/null || true
    fi
    [ -n "$svc" ] && service "$svc" stop >/dev/null 2>&1 || true
    exit 0
    ;;
  is-active)
    svc="${1:-}"
    if [ -n "$svc" ] && unit_file "$svc" >/dev/null; then
      pgrep -f "procname-prefix ${svc#@}" >/dev/null 2>&1 && exit 0 || exit 3
    fi
    [ -n "$svc" ] && service "$svc" status >/dev/null 2>&1 && exit 0 || exit 3
    ;;
  is-enabled)
    exit 0
    ;;
  status)
    svc="${1:-}"
    [ -n "$svc" ] && { service "$svc" status 2>/dev/null || true; }
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
