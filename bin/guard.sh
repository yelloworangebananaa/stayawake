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
  # Trailing "unknown 0" are fallback defaults, not real data: if power_source
  # produces no output at all, `$1`/`$2` still bind under `set -u` instead of
  # killing the shell mid-poll (which would skip the EXIT trap's restore).
  set -- $(power_source) unknown 0
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
#
# read_state is called IN HERE, under the lock -- not captured as a
# `$(read_state)` argument before with_state_lock runs. A command
# substitution in the call's argument list is evaluated by the shell before
# with_state_lock is even entered, i.e. before this guard has any claim on
# the lock at all. Another session's cleanup could read/restore the live
# value in the gap between that early read and this guard actually
# acquiring the lock, and this guard would then persist a value that was
# already stale by the time it got recorded as "the baseline".
_startup() { # session kind guard_pid parent_pid
  claim_baseline "$(read_state)"
  _su_rc=$?
  [ "$_su_rc" -eq 2 ] && return 2
  guard_register "$1" "$2" "$3" "$4"
}

if ! with_state_lock _startup "$SESSION" "$KIND" "$$" "$PARENT"; then
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
  # trap cleanup fires for EXIT and for INT/TERM/HUP; a signal-triggered
  # `exit` below re-fires the EXIT trap on the way out, invoking cleanup a
  # second time. Without this sentinel that second pass runs the locked
  # unregister/reap/restore sequence again -- against a baseline the first
  # pass may have already cleared, silently re-applying disablesleep=0.
  [ -n "${_sa_cleanup_done:-}" ] && return
  _sa_cleanup_done=1
  # Cleanup gets a materially longer lock budget than startup: timing out
  # unlocked here means power settings stay overridden with nothing left
  # that will ever restore them, which is worse than a slow exit.
  STAYAWAKE_LOCK_MAX_WAIT=30
  if with_state_lock _cleanup_locked "$SESSION" "$KIND"; then
    [ -n "$CAFF_PID" ] && kill "$CAFF_PID" 2>/dev/null
    exit 0
  fi
  echo "stayawake: FATAL could not acquire the state lock during cleanup for session=$SESSION kind=$KIND after ${STAYAWAKE_LOCK_MAX_WAIT}s -- disablesleep was NOT restored and the baseline was NOT cleared. Guard file $(guard_file "$SESSION" "$KIND") is left registered; the next guard that successfully acquires the lock will reap this dead guard and restore automatically. If no other guard is running, check 'pmset -g' and restore disablesleep by hand." >&2
  [ -n "$CAFF_PID" ] && kill "$CAFF_PID" 2>/dev/null
  exit 1
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
  # Locked: an unlocked reap here could delete a guard file that a resuming
  # session just atomically replaced via its own locked guard_register (Race
  # B). The victim would see its own guard file vanish, break out of ITS
  # poll loop, and run cleanup while genuinely still live -- a mid-turn loss
  # of protection, not a benign tidy. The lock is held only for this one
  # call, released before `sleep`, so it does not block other sessions for
  # the poll interval -- just for one mkdir/rmdir per tick.
  with_state_lock reap_dead_guards
  sleep "$POLL"
done
# EXIT trap runs cleanup.
