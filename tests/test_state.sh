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

finish
