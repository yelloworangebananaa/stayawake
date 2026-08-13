HERE="$(dirname "$0")"
. "$HERE/assert.sh"

STAYAWAKE_HOME="${TMPDIR:-/tmp}/stayawake-setuptest-$$"
export STAYAWAKE_HOME
rm -rf "$STAYAWAKE_HOME"

. "$HERE/../lib/state.sh"

# Stub restore_state/power_source instead of sourcing lib/macos/platform.sh --
# these tests run on a machine with no pmset, and the point of this file is
# the mode logic in sa_restore_if_stale/sa_status, not the platform calls.
RESTORE_LOG="$STAYAWAKE_HOME/restore.log"
mkdir -p "$STAYAWAKE_HOME"
restore_state() { echo "restore:$1" >> "$RESTORE_LOG"; } # baseline_text
power_source()  { printf 'ac 100'; }

. "$HERE/../lib/macos/setup.sh"

# --- normal mode: no baseline is a silent no-op ---
: > "$RESTORE_LOG"
out=$(sa_restore_if_stale)
rc=$?
assert_eq "$rc" "0" "normal, no baseline: exit 0"
assert_eq "$out" "" "normal, no baseline: no output"
assert_eq "$(cat "$RESTORE_LOG")" "" "normal, no baseline: restore_state never called"

# --- normal mode: baseline present, no guards -> restores and clears ---
claim_baseline "disablesleep=0"
: > "$RESTORE_LOG"
sa_restore_if_stale >/dev/null
assert_eq "$(cat "$RESTORE_LOG")" "restore:disablesleep=0" "normal, no guards: restores the baseline"
assert_eq "$(read_baseline)" "" "normal, no guards: baseline cleared after restore"

# --- normal mode: a live guard blocks the restore ---
claim_baseline "disablesleep=0"
guard_register "sess-live" "turn" "$$" "$$"
: > "$RESTORE_LOG"
sa_restore_if_stale >/dev/null
assert_eq "$(cat "$RESTORE_LOG")" "" "normal, live guard: restore_state not called"
assert_eq "$(read_baseline)" "disablesleep=0" "normal, live guard: baseline left intact"
guard_unregister "sess-live" "turn"

# --- normal mode: a dead guard is reaped, then restore proceeds ---
guard_register "sess-dead" "turn" "999999" "999999"
: > "$RESTORE_LOG"
sa_restore_if_stale >/dev/null
assert_eq "$(cat "$RESTORE_LOG")" "restore:disablesleep=0" "normal, dead guard: reaped and then restores"
assert_eq "$(guard_count)" "0" "normal, dead guard: reaping removed it"
clear_baseline

# --- force mode: restores even with a live guard, and does not touch it ---
claim_baseline "disablesleep=1"
guard_register "sess-live2" "turn" "$$" "$$"
: > "$RESTORE_LOG"
sa_restore_if_stale force >/dev/null
assert_eq "$(cat "$RESTORE_LOG")" "restore:disablesleep=1" "force: restores despite a live guard"
assert_eq "$(read_baseline)" "" "force: baseline cleared"
assert_eq "$(guard_count)" "1" "force: does not reap or remove the live guard file itself"
guard_unregister "sess-live2" "turn"

# --- boot mode: a guard file whose PID happens to be alive (post-reboot PID
# reuse) must NOT block the restore -- this is the whole point of Correction
# 2. Normal mode with the same fixture would refuse to restore; boot must not.
claim_baseline "disablesleep=1"
guard_register "sess-reused-pid" "turn" "$$" "$$"
: > "$RESTORE_LOG"
sa_restore_if_stale boot >/dev/null
assert_eq "$(cat "$RESTORE_LOG")" "restore:disablesleep=1" "boot: restores despite a live-looking guard PID"
assert_eq "$(read_baseline)" "" "boot: baseline cleared"
assert_eq "$(guard_count)" "0" "boot: guards directory wiped unconditionally, no PID consulted"

# --- boot mode: no baseline -> guards still cleared, still silent, exit 0 ---
mkdir -p "$(guards_dir)"
: > "$(guards_dir)/leftover-guard"
out=$(sa_restore_if_stale boot)
rc=$?
assert_eq "$rc" "0" "boot, no baseline: exit 0"
assert_eq "$out" "" "boot, no baseline: no output"
assert_eq "$(guard_count)" "0" "boot, no baseline: guards directory still wiped"

# --- sa_status: baseline line reads "none" when absent, and the value when present ---
clear_baseline
status_out=$(sa_status)
case "$status_out" in
  *"baseline:   none"*) assert_eq "ok" "ok" "status: baseline reads 'none' when absent" ;;
  *) assert_eq "$status_out" "*baseline:   none*" "status: baseline reads 'none' when absent" ;;
esac

claim_baseline "disablesleep=1"
status_out=$(sa_status)
case "$status_out" in
  *"baseline:   disablesleep=1"*) assert_eq "ok" "ok" "status: baseline reads the stored value when present" ;;
  *) assert_eq "$status_out" "*baseline:   disablesleep=1*" "status: baseline reads the stored value when present" ;;
esac
clear_baseline

# --- sa_status: grant line reflects whether SUDOERS_FILE exists ---
SUDOERS_FILE="$STAYAWAKE_HOME/fake-sudoers"
rm -f "$SUDOERS_FILE"
status_out=$(sa_status)
case "$status_out" in
  *"grant:      NOT installed"*) assert_eq "ok" "ok" "status: grant reports not-installed when the file is absent" ;;
  *) assert_eq "$status_out" "*NOT installed*" "status: grant reports not-installed when the file is absent" ;;
esac

: > "$SUDOERS_FILE"
status_out=$(sa_status)
case "$status_out" in
  *"grant:      installed ($SUDOERS_FILE)"*) assert_eq "ok" "ok" "status: grant reports installed when the file exists" ;;
  *) assert_eq "$status_out" "*grant installed*" "status: grant reports installed when the file exists" ;;
esac

rm -rf "$STAYAWAKE_HOME"
finish
