#!/bin/sh
# usage: guard.sh <session_id> <kind> <parent_pid>
# Holds the machine awake until the parent dies, its guard file is removed,
# or the battery drops below the floor. Restores on every exit path.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/lib/state.sh"
if [ -n "${STAYAWAKE_PLATFORM_STUB:-}" ]; then
  . "$STAYAWAKE_PLATFORM_STUB"
else
  . "$ROOT/lib/macos/platform.sh"
fi

SESSION="$1"
KIND="$2"
PARENT="$3"
POLL="${STAYAWAKE_POLL:-30}"
CAFF_PID=""

config_get() { # key default
  f="$(state_dir)/config.json"
  [ -f "$f" ] || { printf '%s' "$2"; return; }
  v=$(sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$f" | head -1)
  [ -n "$v" ] || v="$2"
  printf '%s' "$v"
}

FLOOR="$(config_get batteryFloor 30)"

on_battery_below_floor() {
  set -- $(power_source)
  [ "$1" = "battery" ] && [ "$2" -lt "$FLOOR" ]
}

# Checked BEFORE claiming or registering anything, so a turn started on a
# flat battery does not engage the override and release it one poll later.
if on_battery_below_floor; then
  exit 0
fi

# --- critical section 1: claim baseline + register guard, atomically ---
# Locked together so a concurrent cleanup (unregister -> count==0 -> restore)
# can never observe this guard half-registered: either both the claim and
# the registration are visible, or neither is.
_startup() { # session kind guard_pid parent_pid state_text
  claim_baseline "$5"
  _su_rc=$?
  [ "$_su_rc" -eq 2 ] && return 2
  guard_register "$1" "$2" "$3" "$4"
}

if ! with_state_lock _startup "$SESSION" "$KIND" "$$" "$PARENT" "$(read_state)"; then
  echo "stayawake: guard startup aborted (lock timeout or baseline claim failed)" >&2
  exit 1
fi

# --- critical section 2: unregister + reap + count + restore-if-last-out ---
# Locked together so a reaper never deletes a guard file that a resuming
# session just atomically replaced (the file it checked liveness on isn't
# the file it would delete), and so guard_count==0 is acted on before any
# other session can register in between.
_cleanup_locked() { # session kind
  guard_unregister "$1" "$2"
  reap_dead_guards
  if [ "$(guard_count)" -eq 0 ]; then
    restore_state "$(read_baseline)"
    clear_baseline
  fi
}

cleanup() {
  with_state_lock _cleanup_locked "$SESSION" "$KIND"
  [ -n "$CAFF_PID" ] && kill "$CAFF_PID" 2>/dev/null
  exit 0
}
# The trap is armed only after registering. Arming it earlier would let an
# early exit run cleanup against a baseline this guard does not own,
# potentially restoring another session's settings.
trap cleanup EXIT INT TERM HUP

apply_state

# -i blocks system idle sleep and deliberately leaves display sleep alone, so
# the screen still goes dark. -w makes caffeinate exit when the parent does,
# so it can never outlive it. Do not add -d.
if command -v caffeinate >/dev/null 2>&1; then
  caffeinate -i -s -w "$PARENT" &
  CAFF_PID=$!
fi

while :; do
  kill -0 "$PARENT" 2>/dev/null || break
  [ -f "$(guard_file "$SESSION" "$KIND")" ] || break
  on_battery_below_floor && break
  # ponytail: deliberately unlocked. This periodic tidy is best-effort (reaps
  # guard files left behind by sessions that crashed without running
  # cleanup); nothing here reads its result and acts on it, unlike the two
  # locked critical sections above. It can in theory still race a concurrent
  # guard_register the same way Race B describes, but the fallout is bounded
  # to a spurious file delete on someone else's in-flight resume, not a
  # false zero-refcount restore -- that path stays fully locked. Closing it
  # would mean holding the lock across the poll loop, which the spec
  # explicitly forbids. Revisit if reap_dead_guards ever gains a caller that
  # acts on its outcome outside the two locked sections.
  reap_dead_guards
  sleep "$POLL"
done
# EXIT trap runs cleanup.
