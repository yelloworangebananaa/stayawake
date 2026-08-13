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

# Creates the baseline only if absent.
# The subshell keeps `set -C` (noclobber) from leaking into the caller; noclobber
# makes `>` fail atomically when the file already exists, which is the whole trick.
#
# Return contract (callers in later tasks depend on this):
#   0 = this call created the baseline. Caller captured it, safe to proceed.
#   1 = baseline already existed. Another session owns it, safe to proceed.
#   2 = the write failed for a reason OTHER than "already exists" (unwritable
#       dir, disk full, mkdir failure in _ensure_dirs, ...). No baseline was
#       written. Caller MUST NOT proceed to mutate power settings on 2 —
#       there would be nothing to restore from.
claim_baseline() { # text
  _ensure_dirs
  if ( set -C; printf '%s\n' "$1" > "$(baseline_file)" ) 2>/dev/null; then
    return 0
  fi
  [ -f "$(baseline_file)" ] && return 1
  return 2
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
  # Write to a dot-prefixed temp file, then rename into place. rename(2) is
  # atomic, so a guard file is never observable mid-write — a force-kill
  # between the write and the rename just leaves an orphan temp file, never
  # a truncated/unparseable guard. The leading dot is deliberate: the plain
  # "*" globs in guard_count/reap_dead_guards do not match dotfiles, so an
  # in-flight temp file can never be miscounted as a guard. Keep it dotted.
  _sa_tmp="$(guards_dir)/.tmp-$1-$2-$$"
  printf 'guard_pid=%s\nparent_pid=%s\n' "$3" "$4" > "$_sa_tmp" &&
    mv -f "$_sa_tmp" "$(guard_file "$1" "$2")"
}

guard_unregister() { # session_id kind
  rm -f "$(guard_file "$1" "$2")"
}

guard_count() {
  # _sa_-namespaced: this file is sourced into the caller's shell, and POSIX
  # sh has no `local`, so bare names like `n`/`f` would clobber the caller's.
  _sa_n=0
  for _sa_f in "$(guards_dir)"/*; do
    [ -f "$_sa_f" ] && _sa_n=$((_sa_n + 1))
  done
  printf '%s' "$_sa_n"
}

_pid_alive() { # pid
  kill -0 "$1" 2>/dev/null
}

# ponytail: PID reuse could in principle keep a stale guard file alive. The
# window is seconds and the cost is one extra poll cycle, so it is ignored.
#
# The `[ -n "$_sa_pid" ] || continue` guard below is now genuinely unreachable
# defence rather than a leak path: guard_register() only ever makes a fully
# written file observable (atomic rename), so a file matched by this glob
# always has a guard_pid= line. Left in place as a defensive no-op.
reap_dead_guards() {
  for _sa_f in "$(guards_dir)"/*; do
    [ -f "$_sa_f" ] || continue
    _sa_pid=$(sed -n 's/^guard_pid=\([0-9][0-9]*\)$/\1/p' "$_sa_f" | head -1)
    [ -n "$_sa_pid" ] || continue
    _pid_alive "$_sa_pid" || rm -f "$_sa_f"
  done
}
