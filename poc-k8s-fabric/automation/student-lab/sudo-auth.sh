student_require_sudo_auth() {
  if sudo -n true >/dev/null 2>&1; then
    return 0
  fi
  sudo -v
}
