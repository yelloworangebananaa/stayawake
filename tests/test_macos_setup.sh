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
lid_available() { return 0; } # default: has a lid, no status line

. "$HERE/../lib/macos/setup.sh"

# Inject boot time and mtime lookups instead of exercising the real
# `sysctl`/`stat -f` (BSD-only, unavailable under Git Bash on this dev
# machine, and untestable without a real reboot anyway). Any guard file
# whose name doesn't contain "postboot" is treated as older than the fake
# boot time (the ordinary case: a leftover from before a real reboot);
# "postboot"-named files are newer (a guard registered by a session running
# in the current boot, e.g. mid-turn during a fast-user-switch re-login).
# --- _parse_boot_time: pure parse of the real `sysctl -n kern.boottime`
# text, exercised directly (not through the stub below) so the actual sed
# extraction in setup.sh runs against realistic input at least once. ---
assert_eq "$(printf '{ sec = 1723526400, usec = 123456 } Fri Aug 12 12:00:00 2026\n' | _parse_boot_time)" \
  "1723526400" "_parse_boot_time: normal kern.boottime output"
assert_eq "$(printf '' | _parse_boot_time)" "" "_parse_boot_time: empty input yields empty"
assert_eq "$(printf 'garbage nonsense\n' | _parse_boot_time)" "" "_parse_boot_time: malformed input yields empty, not a bogus epoch"

FAKE_BOOT=2000000000
_sa_boot_time() { printf '%s' "$FAKE_BOOT"; }
_sa_file_mtime() { # file
  case "$1" in
    *postboot*) printf '%s' $((FAKE_BOOT + 100)) ;;
    *)          printf '%s' $((FAKE_BOOT - 100)) ;;
  esac
}

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
# reuse) must NOT block the restore. Its mtime predates the fake boot time
# (the stub's default case), so it is exactly the leftover-from-before-
# reboot scenario boot mode exists to clean up. Normal mode with the same
# fixture would refuse to restore; boot must not.
claim_baseline "disablesleep=1"
guard_register "sess-reused-pid" "turn" "$$" "$$"
: > "$RESTORE_LOG"
sa_restore_if_stale boot >/dev/null
assert_eq "$(cat "$RESTORE_LOG")" "restore:disablesleep=1" "boot: restores despite a live-looking guard PID"
assert_eq "$(read_baseline)" "" "boot: baseline cleared"
assert_eq "$(guard_count)" "0" "boot: pre-boot guard file reaped, no PID consulted"

# --- boot mode: only guard files OLDER than boot time are removed. A guard
# file NEWER than boot time is a live session from an ordinary re-login
# (fast user switching, not a reboot) and must survive -- this is the I3 fix.
# Restore still proceeds regardless (boot mode never gates on guard_count).
claim_baseline "disablesleep=1"
guard_register "sess-preboot" "turn" "$$" "$$"
guard_register "sess-postboot" "turn" "$$" "$$"
: > "$RESTORE_LOG"
sa_restore_if_stale boot >/dev/null
assert_eq "$(cat "$RESTORE_LOG")" "restore:disablesleep=1" "boot, mixed guards: restores regardless"
assert_eq "$(read_baseline)" "" "boot, mixed guards: baseline cleared"
if [ -f "$(guard_file "sess-preboot" "turn")" ]; then pre=present; else pre=gone; fi
if [ -f "$(guard_file "sess-postboot" "turn")" ]; then post=present; else post=gone; fi
assert_eq "$pre" "gone" "boot, mixed guards: pre-boot guard file is removed"
assert_eq "$post" "present" "boot, mixed guards: post-boot (live) guard file is left alone"
guard_unregister "sess-postboot" "turn"

# --- boot mode: no baseline -> pre-boot guards still cleared, still silent,
# exit 0 ---
mkdir -p "$(guards_dir)"
: > "$(guards_dir)/leftover-guard"
out=$(sa_restore_if_stale boot)
rc=$?
assert_eq "$rc" "0" "boot, no baseline: exit 0"
assert_eq "$out" "" "boot, no baseline: no output"
assert_eq "$(guard_count)" "0" "boot, no baseline: pre-boot guard file still reaped"

# --- boot mode: boot time can't be determined -> skip the wipe entirely
# (never fall back to an unconditional rm -rf; that would reintroduce I3),
# but restore still proceeds unconditionally ---
_sa_boot_time() { printf ''; }
claim_baseline "disablesleep=1"
guard_register "sess-unknown-boot" "turn" "$$" "$$"
: > "$RESTORE_LOG"
sa_restore_if_stale boot >/dev/null 2>/dev/null
assert_eq "$(cat "$RESTORE_LOG")" "restore:disablesleep=1" "boot, unknown boot time: restore still proceeds"
assert_eq "$(guard_count)" "1" "boot, unknown boot time: wipe skipped, guard file left alone"
guard_unregister "sess-unknown-boot" "turn"
_sa_boot_time() { printf '%s' "$FAKE_BOOT"; }

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

# --- sa_status: lid line is silent when the machine has a lid ---
lid_available() { return 0; }
status_out=$(sa_status)
case "$status_out" in
  *"lid:"*) assert_eq "$status_out" "<no lid line>" "status: no lid line when lid_available is true" ;;
  *) assert_eq "ok" "ok" "status: no lid line when lid_available is true" ;;
esac

# --- sa_status: lid line warns when the machine has no lid (Mac mini,
# Mac Studio, iMac) -- this is the actual defect from Fix 1: a lid-less
# Mac granted root got zero indication lid coverage would never engage ---
lid_available() { return 1; }
status_out=$(sa_status)
case "$status_out" in
  *"lid:        unavailable on this machine"*) assert_eq "ok" "ok" "status: lid line present when lid_available is false" ;;
  *) assert_eq "$status_out" "*lid:        unavailable on this machine*" "status: lid line present when lid_available is false" ;;
esac
lid_available() { return 0; }

rm -rf "$STAYAWAKE_HOME"
finish
