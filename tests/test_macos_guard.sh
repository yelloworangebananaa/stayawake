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
sleep 2
kill -9 "$FAKE_PARENT"
sleep 3
assert_eq "$(grep -c '^restore:' "$STUB_LOG")" "1" "guard restored after parent was SIGKILLed"

rm -rf "$STAYAWAKE_HOME"
finish
