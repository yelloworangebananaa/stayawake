# macOS one-time privileged setup, uninstall, status, and the login-time
# stale-restore backstop. Sourced, not executed. bash 3.2 / POSIX sh safe.

SUDOERS_FILE="/etc/sudoers.d/stayawake"
AGENT_PLIST="$HOME/Library/LaunchAgents/com.stayawake.restore.plist"

# Injectable so tests can supply fake values without a real reboot or the
# BSD-only tools below (`sysctl`, `stat -f`) -- this file only ever runs on
# macOS in production, so no portability shim is added here. A test sources
# this file and then redefines these two functions before calling
# sa_restore_if_stale boot.
#
# `kern.boottime` prints as: { sec = 1723526400, usec = 123456 } Fri Aug 12 ...
# The sed below is POSIX BRE (no \+, \s, \?, \|) so it behaves the same
# under BSD sed (macOS) and GNU sed: anchor on the literal prefix, capture
# the run of digits after "sec = ", discard the rest of the line.
# Pure parse, callable directly on a string (no `sysctl` needed) so the
# breakage-prone sed extraction is testable on its own: malformed or absent
# input yields empty output (not a bogus epoch), which is what tells the
# caller in sa_restore_if_stale to skip the wipe rather than guess.
_parse_boot_time() {
  sed -n 's/^{ sec = \([0-9][0-9]*\).*/\1/p'
}

_sa_boot_time() {
  sysctl -n kern.boottime 2>/dev/null | _parse_boot_time
}

_sa_file_mtime() { # file
  stat -f %m "$1" 2>/dev/null
}

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
#   boot    Used by the LaunchAgent, which fires on RunAtLoad -- every
#           login, not just a post-reboot one (fast user switching,
#           re-login). No guard process survives a reboot, so every guard
#           file left over from BEFORE the reboot is stale by definition --
#           whatever its PID says. A PID recorded in a leftover guard file
#           can be reused by an unrelated long-lived process after reboot,
#           which would make _pid_alive report it as live and wedge the
#           very backstop this mode exists to run. So `boot` does not
#           consult any PID at all -- but it must not blow away a guard
#           file that is genuinely live from a session running right now
#           (an ordinary re-login while a turn is in flight), so it only
#           removes guard files older than the current boot time. Every
#           file left over from before a real reboot predates boot by
#           definition; every file written by a guard running in the
#           current boot is newer than it. If boot time can't be
#           determined, skip the wipe entirely rather than guess -- restore
#           still proceeds unconditionally below regardless of what's left
#           in the guards directory.
sa_restore_if_stale() { # [force|boot]
  case "${1:-}" in
    boot)
      _sa_boot="$(_sa_boot_time)"
      case "$_sa_boot" in
        ''|*[!0-9]*) _sa_boot='' ;;
      esac
      if [ -n "$_sa_boot" ]; then
        for _sa_f in "$(guards_dir)"/*; do
          [ -f "$_sa_f" ] || continue
          _sa_mtime="$(_sa_file_mtime "$_sa_f")"
          case "$_sa_mtime" in
            ''|*[!0-9]*) continue ;;
          esac
          [ "$_sa_mtime" -lt "$_sa_boot" ] && rm -f "$_sa_f"
        done
      else
        echo "stayawake: could not determine boot time, skipping stale-guard cleanup (restore still proceeds)" >&2
      fi
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
    echo "grant:      NOT installed — run '/stayawake setup' for lid-close coverage"
  fi
  lid_available || echo "lid:        unavailable on this machine"
  echo "guards:     $(guard_count) active"
  echo "power:      $(power_source)"
  b=$(read_baseline)
  [ -n "$b" ] || b=none
  echo "baseline:   $b"
}
