HERE="$(dirname "$0")"
. "$HERE/assert.sh"

STAYAWAKE_HOME="${TMPDIR:-/tmp}/stayawake-test-$$"
export STAYAWAKE_HOME
rm -rf "$STAYAWAKE_HOME"

. "$HERE/../lib/state.sh"

# --- baseline is claimed exactly once ---
claim_baseline "disablesleep=0"
assert_eq "$?" "0" "first claim succeeds"
claim_baseline "disablesleep=9"
assert_eq "$?" "1" "second claim is refused"
assert_eq "$(read_baseline)" "disablesleep=0" "baseline holds the first writer's value"

# --- a write failure is distinguishable from an existing claim ---
# Point STAYAWAKE_HOME at a path whose parent cannot be created: "blocker" is
# a regular file, so mkdir -p on "blocker/sub/guards" and the baseline write
# both fail with ENOTDIR, not "already exists". claim_baseline must report
# that as 2 (do not proceed), never 1 (proceed, someone else has it).
_sa_blocker="${TMPDIR:-/tmp}/sa-blocker-$$"
: > "$_sa_blocker"
_sa_rc=$(
  STAYAWAKE_HOME="$_sa_blocker/sub"
  export STAYAWAKE_HOME
  claim_baseline "x"
  echo "$?"
)
assert_eq "$_sa_rc" "2" "write failure (unwritable parent) returns 2, not 1"
rm -f "$_sa_blocker"

# --- guards directory unusable: _ensure_dirs fails, claim must not proceed ---
# "guards" exists as a regular file, so mkdir -p on it fails. Before the
# `_ensure_dirs || return 2` fix, claim_baseline ignored that failure and
# went on to write the baseline anyway, returning 0 -- telling the caller it
# was safe to mutate power settings even though no guard could ever be
# registered to release them later.
_sa_guards_home="${TMPDIR:-/tmp}/sa-guardsfile-$$"
rm -rf "$_sa_guards_home"
mkdir -p "$_sa_guards_home"
: > "$_sa_guards_home/guards"
_sa_rc=$(
  STAYAWAKE_HOME="$_sa_guards_home"
  export STAYAWAKE_HOME
  claim_baseline "x"
  echo "$?"
)
assert_eq "$_sa_rc" "2" "guards dir unusable (regular file) returns 2, not 0"
rm -rf "$_sa_guards_home"

# --- empty baseline is a partial write, not a valid claim to proceed from ---
# A zero-byte original.state means the create succeeded but the data write
# didn't. Before the `[ -s ... ]` fix (was `[ -f ... ]`), this looked like
# "already exists" and returned 1 (safe to proceed) -- but proceeding means
# restoring from nothing.
_sa_empty_home="${TMPDIR:-/tmp}/sa-emptybaseline-$$"
rm -rf "$_sa_empty_home"
mkdir -p "$_sa_empty_home"
: > "$_sa_empty_home/original.state"
_sa_rc=$(
  STAYAWAKE_HOME="$_sa_empty_home"
  export STAYAWAKE_HOME
  claim_baseline "x"
  echo "$?"
)
assert_eq "$_sa_rc" "2" "empty baseline file returns 2, not 1"
rm -rf "$_sa_empty_home"

# --- refcount ---
assert_eq "$(guard_count)" "0" "no guards at start"
guard_register "sess-a" "turn" "$$" "$$"
assert_eq "$(guard_count)" "1" "one guard after register"
guard_register "sess-a" "pin" "$$" "$$"
assert_eq "$(guard_count)" "2" "pin and turn coexist in one session"
guard_unregister "sess-a" "turn"
assert_eq "$(guard_count)" "1" "unregister removes only its own file"

# --- dead guards are reaped, live ones are not ---
# PID 999999 is above the default pid_max on both platforms, so it is never alive.
guard_register "sess-dead" "turn" "999999" "999999"
assert_eq "$(guard_count)" "2" "dead guard counted before reaping"
reap_dead_guards
assert_eq "$(guard_count)" "1" "dead guard reaped, live guard kept"

# --- teardown clears the baseline ---
guard_unregister "sess-a" "pin"
assert_eq "$(guard_count)" "0" "all guards gone"
clear_baseline
assert_eq "$(read_baseline)" "" "baseline cleared"

rm -rf "$STAYAWAKE_HOME"

# --- twenty concurrent claimers, exactly one wins ---
rm -rf "$STAYAWAKE_HOME"
i=0
while [ "$i" -lt 20 ]; do
  ( claim_baseline "writer=$i" && echo won >> "${TMPDIR:-/tmp}/sa-race-$$" ) &
  i=$((i + 1))
done
wait
assert_eq "$(wc -l < "${TMPDIR:-/tmp}/sa-race-$$" | tr -d ' ')" "1" "exactly one concurrent claimer wins"
rm -f "${TMPDIR:-/tmp}/sa-race-$$"

# --- with_state_lock: two concurrent holders never overlap ---
STAYAWAKE_HOME="${TMPDIR:-/tmp}/stayawake-lock-test-$$"
export STAYAWAKE_HOME
rm -rf "$STAYAWAKE_HOME"
_sa_out="$STAYAWAKE_HOME/order.log"
mkdir -p "$STAYAWAKE_HOME"

(
  with_state_lock sh -c 'printf "BEGIN %s\n" "$1" >> "$2"; sleep 1; printf "END %s\n" "$1" >> "$2"' _ A "$_sa_out"
) &
_sa_p1=$!
(
  with_state_lock sh -c 'printf "BEGIN %s\n" "$1" >> "$2"; sleep 1; printf "END %s\n" "$1" >> "$2"' _ B "$_sa_out"
) &
_sa_p2=$!
wait "$_sa_p1" "$_sa_p2"

_sa_l1=$(sed -n '1p' "$_sa_out" | cut -d' ' -f1)
_sa_l1id=$(sed -n '1p' "$_sa_out" | cut -d' ' -f2)
_sa_l2=$(sed -n '2p' "$_sa_out" | cut -d' ' -f1)
_sa_l2id=$(sed -n '2p' "$_sa_out" | cut -d' ' -f2)
assert_eq "$(wc -l < "$_sa_out" | tr -d ' ')" "4" "lock: both holders logged BEGIN and END"
assert_eq "$_sa_l1 $_sa_l1id" "BEGIN $_sa_l1id" "lock: first line is a BEGIN"
assert_eq "$_sa_l2 $_sa_l2id" "END $_sa_l1id" "lock: second holder's BEGIN never lands before the first holder's END"

# --- with_state_lock: released even when the command fails ---
with_state_lock false
assert_eq "$(ls "$STAYAWAKE_HOME/lock" 2>/dev/null)" "" "lock dir removed after a failing command"
_sa_t0=$(date +%s)
with_state_lock true
assert_eq "$?" "0" "lock reacquirable immediately after a failed run"
_sa_t1=$(date +%s)
assert_eq "$([ "$((_sa_t1 - _sa_t0))" -lt 3 ] && echo fast)" "fast" "reacquire after failure did not wait out the timeout"

# --- with_state_lock: a stale lock held by a dead PID is broken, not wedged ---
mkdir -p "$STAYAWAKE_HOME/lock"
printf '999999\n' > "$STAYAWAKE_HOME/lock/pid"
_sa_t0=$(date +%s)
with_state_lock true
_sa_stale_rc=$?
_sa_t1=$(date +%s)
assert_eq "$_sa_stale_rc" "0" "stale lock (dead pid) is broken and the command still runs"
assert_eq "$([ "$((_sa_t1 - _sa_t0))" -lt 3 ] && echo fast)" "fast" "stale lock was broken immediately, not waited out"
assert_eq "$(ls "$STAYAWAKE_HOME/lock" 2>/dev/null)" "" "lock dir clean after the stale-lock run"

# --- with_state_lock: concurrent breakers of the SAME stale lock never both win ---
# Regression test for Critical 2 (rm -rf-by-path stale break): plants one
# stale lock (dead pid) and releases 8 waiters at it simultaneously through a
# start barrier, to maximize the chance more than one is mid-break at once.
# `rm -rf` acting on a shared path let two waiters both judge the same dead
# pid stale and both proceed -- the second's rm could hit a lock a third
# process (or the first waiter) had already legitimately recreated at that
# path. `mv` to a private per-process name before removing is what actually
# closes it: only one racer's rename can ever succeed.
#
# STAYAWAKE_LOCK_MAX_WAIT is raised for this test on purpose: with 8 waiters
# serializing 1s critical sections and no fairness/FIFO ordering, plain
# queueing can legitimately need close to 8s for the last waiter to get a
# turn -- that is a budget question (covered separately), not this race. A
# tight budget here would fail the test on ordinary contention and mask the
# actual bug (a waiter silently never running its command at all because its
# freshly-acquired lock got deleted out from under it) behind an unrelated
# timeout.
STAYAWAKE_LOCK_MAX_WAIT=20
export STAYAWAKE_LOCK_MAX_WAIT
rm -rf "$STAYAWAKE_HOME"
mkdir -p "$STAYAWAKE_HOME"
_sa_out="$STAYAWAKE_HOME/order.log"
: > "$_sa_out"
_sa_go="$STAYAWAKE_HOME/go"
mkdir -p "$STAYAWAKE_HOME/lock"
printf '999999\n' > "$STAYAWAKE_HOME/lock/pid"

_sa_i=0
_sa_pids=""
while [ "$_sa_i" -lt 8 ]; do
  (
    while [ ! -e "$_sa_go" ]; do :; done
    with_state_lock sh -c 'printf "BEGIN %s\n" "$1" >> "$2"; sleep 1; printf "END %s\n" "$1" >> "$2"' _ "$_sa_i" "$_sa_out"
  ) &
  _sa_pids="$_sa_pids $!"
  _sa_i=$((_sa_i + 1))
done
: > "$_sa_go"
wait $_sa_pids
unset STAYAWAKE_LOCK_MAX_WAIT

_sa_open=""
_sa_bad=0
while read -r _sa_ev _sa_id; do
  if [ "$_sa_ev" = "BEGIN" ]; then
    [ -n "$_sa_open" ] && _sa_bad=1
    _sa_open="$_sa_id"
  else
    [ "$_sa_open" = "$_sa_id" ] || _sa_bad=1
    _sa_open=""
  fi
done < "$_sa_out"
assert_eq "$(wc -l < "$_sa_out" | tr -d ' ')" "16" "stale-breaker race: all 8 waiters completed exactly one BEGIN/END pair"
assert_eq "$_sa_bad" "0" "stale-breaker race: no two waiters were ever inside the critical section together"

rm -rf "$STAYAWAKE_HOME"

finish
