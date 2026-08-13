# Shared state for stayawake guards. Sourced, not executed.

state_dir() {
  printf '%s' "${STAYAWAKE_HOME:-$HOME/.stayawake}"
}

guards_dir() {
  printf '%s/guards' "$(state_dir)"
}

guard_file() { # session_id kind
  printf '%s/%s-%s' "$(guards_dir)" "$1" "$2"
}

baseline_file() {
  printf '%s/original.state' "$(state_dir)"
}

_ensure_dirs() {
  mkdir -p "$(guards_dir)" 2>/dev/null
}

# Creates the baseline only if absent. Returns 0 if this call created it.
# The subshell keeps `set -C` (noclobber) from leaking into the caller; noclobber
# makes `>` fail atomically when the file already exists, which is the whole trick.
claim_baseline() { # text
  _ensure_dirs
  if ( set -C; printf '%s\n' "$1" > "$(baseline_file)" ) 2>/dev/null; then
    return 0
  fi
  return 1
}

read_baseline() {
  [ -f "$(baseline_file)" ] || return 0
  cat "$(baseline_file)"
}

clear_baseline() {
  rm -f "$(baseline_file)"
}

guard_register() { # session_id kind guard_pid parent_pid
  _ensure_dirs
  printf 'guard_pid=%s\nparent_pid=%s\n' "$3" "$4" > "$(guard_file "$1" "$2")"
}

guard_unregister() { # session_id kind
  rm -f "$(guard_file "$1" "$2")"
}

guard_count() {
  n=0
  for f in "$(guards_dir)"/*; do
    [ -f "$f" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

_pid_alive() { # pid
  kill -0 "$1" 2>/dev/null
}

# ponytail: PID reuse could in principle keep a stale guard file alive. The
# window is seconds and the cost is one extra poll cycle, so it is ignored.
reap_dead_guards() {
  for f in "$(guards_dir)"/*; do
    [ -f "$f" ] || continue
    pid=$(sed -n 's/^guard_pid=\([0-9][0-9]*\)$/\1/p' "$f" | head -1)
    [ -n "$pid" ] || continue
    _pid_alive "$pid" || rm -f "$f"
  done
}
