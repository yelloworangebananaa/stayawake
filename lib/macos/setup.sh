# macOS one-time privileged setup, uninstall, status, and the login-time
# stale-restore backstop. Sourced, not executed. bash 3.2 / POSIX sh safe.

SUDOERS_FILE="/etc/sudoers.d/stayawake"
AGENT_PLIST="$HOME/Library/LaunchAgents/com.stayawake.restore.plist"

# Two exact commands, no wildcard. This grant cannot be used for anything but
# toggling disablesleep on and off.
_sudoers_body() {
  cat <<EOF
%admin ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
EOF
}

_agent_body() { # root
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.stayawake.restore</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>$1/bin/stayawake.sh</string>
    <string>restore-if-stale</string>
    <string>boot</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
}

sa_setup() { # root
  tmp=$(mktemp)
  _sudoers_body > "$tmp"
  if ! visudo -cf "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    echo "stayawake: generated sudoers rule failed validation, refusing to install" >&2
    return 1
  fi
  echo "stayawake needs one administrator approval to allow toggling lid-close sleep."
  sudo install -m 0440 -o root -g wheel "$tmp" "$SUDOERS_FILE" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"

  mkdir -p "$(dirname "$AGENT_PLIST")"
  _agent_body "$1" > "$AGENT_PLIST"
  launchctl unload "$AGENT_PLIST" 2>/dev/null
  launchctl load "$AGENT_PLIST" 2>/dev/null

  echo "stayawake: setup complete. Lid-close coverage is active."
}

sa_uninstall() {
  # Restore first, with the force variant. Uninstalling while a guard is
  # live must never strand the user's lid setting once the grant is gone.
  sa_restore_if_stale force
  launchctl unload "$AGENT_PLIST" 2>/dev/null
  rm -f "$AGENT_PLIST"
  sudo -n rm -f "$SUDOERS_FILE" 2>/dev/null || sudo rm -f "$SUDOERS_FILE"
  rm -rf "$(state_dir)"
  echo "stayawake: uninstalled. Sudoers rule, login agent, and state removed."
}

# Restores stale power settings a guard left behind. Three modes, selected by
# the single optional argument:
#
#   (none)  Normal/manual invocation (CLI, ad-hoc troubleshooting). Reaps
#           dead guards, then restores only if no live guard remains --
#           a genuinely running guard still owns the baseline and gets to
#           restore it itself on its own exit path.
#
#   force   Used by sa_uninstall. Same reaping, but restores regardless of
#           guard count: uninstalling must never leave the lid setting
#           permanently overridden just because some guard file is still
#           sitting there.
#
#   boot    Used by the LaunchAgent, which runs at login. No guard process
#           survives a reboot, so every guard file left over from before
#           the reboot is stale by definition -- whatever its PID says. A
#           PID recorded in a leftover guard file can be reused by an
#           unrelated long-lived process after reboot, which would make
#           _pid_alive report it as live and wedge the very backstop this
#           mode exists to run. So `boot` does not consult any PID at all:
#           it wipes the guards directory unconditionally and then
#           restores from the baseline if one exists.
sa_restore_if_stale() { # [force|boot]
  case "${1:-}" in
    boot)
      rm -rf "$(guards_dir)"
      ;;
    force)
      reap_dead_guards
      ;;
    *)
      reap_dead_guards
      [ "$(guard_count)" -eq 0 ] || return 0
      ;;
  esac
  b=$(read_baseline)
  [ -n "$b" ] || return 0
  restore_state "$b"
  clear_baseline
  echo "stayawake: restored stale power settings."
}

sa_status() {
  if [ -f "$SUDOERS_FILE" ]; then
    echo "grant:      installed ($SUDOERS_FILE)"
  else
    echo "grant:      NOT installed — run 'stayawake setup' for lid-close coverage"
  fi
  echo "guards:     $(guard_count) active"
  echo "power:      $(power_source)"
  b=$(read_baseline)
  [ -n "$b" ] || b=none
  echo "baseline:   $b"
}
