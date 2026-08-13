HERE="$(dirname "$0")"
. "$HERE/assert.sh"

STAYAWAKE_HOME="${TMPDIR:-/tmp}/stayawake-guardtest-$$"
export STAYAWAKE_HOME
rm -rf "$STAYAWAKE_HOME"

# Stub platform: record calls to a log instead of touching the system.
STUB_LOG="$STAYAWAKE_HOME/calls.log"
mkdir -p "$STAYAWAKE_HOME"

export STAYAWAKE_PLATFORM_STUB="$STAYAWAKE_HOME/stub_platform.sh"
cat > "$STAYAWAKE_PLATFORM_STUB" <<'EOF'
read_state()    { printf 'disablesleep=0'; }
apply_state()   { echo apply >> "$STUB_LOG"; }
restore_state() { echo "restore:$1" >> "$STUB_LOG"; }
power_source()  { printf '%s' "${STUB_POWER:-ac 100}"; }
lid_available() { return 0; }
EOF

export STAYAWAKE_POLL=1
export STUB_LOG

# --- a guard on low battery refuses to engage and leaves no trace ---
STUB_POWER="battery 12"
export STUB_POWER
sh "$HERE/../bin/guard.sh" "sess-low" "turn" "$$"
assert_eq "$(cat "$STUB_LOG" 2>/dev/null)" "" "low battery guard never applies"
assert_eq "$(ls "$STAYAWAKE_HOME/guards" 2>/dev/null | wc -l | tr -d ' ')" "0" "low battery guard registers nothing"
assert_eq "$(ls "$STAYAWAKE_HOME"/original.state 2>/dev/null)" "" "low battery guard never claims a baseline either"

# --- a guard on AC applies, then restores when its guard file is deleted ---
STUB_POWER="ac 100"
sh "$HERE/../bin/guard.sh" "sess-ac" "turn" "$$" &
GUARD_SHELL=$!
sleep 2
assert_eq "$(grep -c '^apply$' "$STUB_LOG")" "1" "AC guard applied once"
rm -f "$STAYAWAKE_HOME/guards/sess-ac-turn"
sleep 3
assert_eq "$(grep -c '^restore:disablesleep=0$' "$STUB_LOG")" "1" "guard restored after its file was removed"
assert_eq "$(ls "$STAYAWAKE_HOME"/original.state 2>/dev/null)" "" "baseline cleared by last guard out"
wait "$GUARD_SHELL" 2>/dev/null

# --- killing the parent triggers restore via the poll ---
: > "$STUB_LOG"
sh -c 'sleep 60' &
FAKE_PARENT=$!
sh "$HERE/../bin/guard.sh" "sess-kill" "turn" "$FAKE_PARENT" &
GUARD_KILL_SHELL=$!
sleep 2
# Confirm the log is empty immediately before the kill, so a restore emitted
# for some unrelated earlier reason can't be mistaken for this one.
assert_eq "$(grep -c '^restore:' "$STUB_LOG")" "0" "no restore logged yet, right before SIGKILLing the parent"
kill -9 "$FAKE_PARENT"
sleep 3
assert_eq "$(grep -c '^restore:' "$STUB_LOG")" "1" "guard restored after parent was SIGKILLed"
wait "$GUARD_KILL_SHELL" 2>/dev/null

# --- Critical-1 regression: read_state must be read INSIDE the lock, not
# captured as a command-substitution argument before the lock is acquired ---
# Simulates session A still holding the lock (about to restore live state
# from 1 back to 0) while session B is blocked waiting to start. If B reads
# the live state before it even attempts to acquire the lock, it captures
# the value A is mid-restoring and persists THAT as "the original" -- wrong,
# and unrecoverable, once A actually finishes and clears its own baseline.
rm -rf "$STAYAWAKE_HOME"
mkdir -p "$STAYAWAKE_HOME"
LIVE_STATE_FILE="$STAYAWAKE_HOME/live_disablesleep"
printf '1' > "$LIVE_STATE_FILE"
export STAYAWAKE_PLATFORM_STUB="$STAYAWAKE_HOME/stub_platform2.sh"
cat > "$STAYAWAKE_PLATFORM_STUB" <<EOF
read_state()    { printf 'disablesleep=%s' "\$(cat '$LIVE_STATE_FILE' 2>/dev/null)"; }
apply_state()   { :; }
restore_state() { :; }
power_source()  { printf 'ac 100'; }
lid_available() { return 0; }
EOF

# Session A: holds the lock itself (simulated -- the test process stands in
# for A's still-in-progress locked cleanup).
mkdir -p "$STAYAWAKE_HOME/lock"
printf '%s\n' "$$" > "$STAYAWAKE_HOME/lock/pid"

sh "$HERE/../bin/guard.sh" "sess-critical1" "turn" "$$" &
GUARD_B=$!
sleep 2
# B should be blocked on the lock by now, having made no progress past it.
assert_eq "$(ls "$STAYAWAKE_HOME"/original.state 2>/dev/null)" "" "B has not claimed a baseline yet -- still blocked on the lock"

# A finishes: live state goes back to 0, then A releases the lock.
printf '0' > "$LIVE_STATE_FILE"
rm -rf "$STAYAWAKE_HOME/lock"
sleep 3

assert_eq "$(cat "$STAYAWAKE_HOME/original.state" 2>/dev/null)" "disablesleep=0" \
  "baseline reflects the state at the moment the lock was actually acquired, not a stale pre-block read"

kill "$GUARD_B" 2>/dev/null
wait "$GUARD_B" 2>/dev/null

rm -rf "$STAYAWAKE_HOME"
finish
