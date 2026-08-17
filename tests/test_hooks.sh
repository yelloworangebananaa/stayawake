HERE="$(dirname "$0")"
. "$HERE/assert.sh"
ROOT="$(cd "$HERE/.." && pwd)"
HOOK="$ROOT/bin/hook.sh"

STAYAWAKE_HOME="${TMPDIR:-/tmp}/stayawake-hooktest-$$"
export STAYAWAKE_HOME
rm -rf "$STAYAWAKE_HOME"
mkdir -p "$STAYAWAKE_HOME/guards"

# hook.sh's own platform gate (`uname -s` = Darwin) blocks everything on this
# Windows dev machine, same as it would in production. Every test below that
# exercises real Stop/SessionEnd/UserPromptSubmit behavior therefore needs
# `uname` faked to report Darwin -- via a PATH override, never by editing the
# gate line itself. FAKEBIN is deliberately NOT used by the "wrong platform"
# test group further down: that group is the one place the real ambient
# (non-Darwin) platform is exactly what's under test.
FAKEBIN="$STAYAWAKE_HOME/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/uname" <<'EOF'
#!/bin/sh
echo "Darwin"
EOF
chmod +x "$FAKEBIN/uname"
FAKE_PATH="$FAKEBIN:$PATH"

plant() { # session kind
  printf 'guard_pid=%s\nparent_pid=%s\n' "$$" "$$" > "$STAYAWAKE_HOME/guards/$1-$2"
}
exists() { # session kind -> "yes"/"no"
  if [ -f "$STAYAWAKE_HOME/guards/$1-$2" ]; then printf yes; else printf no; fi
}
clear_guards() {
  rm -f "$STAYAWAKE_HOME/guards"/*
}
run_hook_real_platform() { # event  (payload on stdin already)
  PATH="$FAKE_PATH" sh "$HOOK" "$1"
}

# --- Stop removes only the turn guard file ---
plant "sess-a" "turn"
plant "sess-a" "pin"
printf '%s' '{"session_id":"sess-a","hook_event_name":"Stop"}' | run_hook_real_platform Stop
rc=$?
assert_eq "$rc" "0" "Stop: hook exits 0"
assert_eq "$(exists sess-a turn)" "no" "Stop: turn guard removed"
assert_eq "$(exists sess-a pin)" "yes" "Stop: pin guard survives"
clear_guards

# --- SessionEnd removes both ---
plant "sess-b" "turn"
plant "sess-b" "pin"
printf '%s' '{"session_id":"sess-b","hook_event_name":"SessionEnd"}' | run_hook_real_platform SessionEnd
rc=$?
assert_eq "$rc" "0" "SessionEnd: hook exits 0"
assert_eq "$(exists sess-b turn)" "no" "SessionEnd: turn guard removed"
assert_eq "$(exists sess-b pin)" "no" "SessionEnd: pin guard removed"
clear_guards

# --- malformed / missing payload falls back to session "unknown", never
# aborts the turn. Each case unregisters the "unknown" guard(s), which is
# the only externally-observable proof the fallback ran instead of the hook
# dying/blocking on bad input. ---
plant "unknown" "turn"
plant "unknown" "pin"
printf '' | run_hook_real_platform SessionEnd
rc=$?
assert_eq "$rc" "0" "empty stdin: hook still exits 0"
assert_eq "$(exists unknown turn)" "no" "empty stdin: falls back to session 'unknown' and unregisters it"
assert_eq "$(exists unknown pin)" "no" "empty stdin: pin for 'unknown' also removed"

plant "unknown" "turn"
printf '%s' '{not valid json at all' | run_hook_real_platform Stop
rc=$?
assert_eq "$rc" "0" "malformed JSON: hook still exits 0"
assert_eq "$(exists unknown turn)" "no" "malformed JSON: falls back to 'unknown' rather than aborting"

plant "unknown" "turn"
printf '%s' '{"hook_event_name":"Stop"}' | run_hook_real_platform Stop
rc=$?
assert_eq "$rc" "0" "JSON missing session_id: hook still exits 0"
assert_eq "$(exists unknown turn)" "no" "JSON missing session_id: falls back to 'unknown'"
clear_guards

# --- platform gate holds: this dev machine's REAL `uname -s` is not Darwin
# (no fake here, on purpose), so hook.sh must be a total no-op for every
# event -- it must not touch guard files at all, let alone the wrong one. ---
plant "sess-gate" "turn"
plant "sess-gate" "pin"
printf '%s' '{"session_id":"sess-gate","hook_event_name":"Stop"}' | sh "$HOOK" Stop
rc=$?
assert_eq "$rc" "0" "wrong platform: Stop hook still exits 0"
assert_eq "$(exists sess-gate turn)" "yes" "wrong platform: Stop must NOT remove the turn guard"
printf '%s' '{"session_id":"sess-gate","hook_event_name":"SessionEnd"}' | sh "$HOOK" SessionEnd
rc=$?
assert_eq "$rc" "0" "wrong platform: SessionEnd hook still exits 0"
assert_eq "$(exists sess-gate turn)" "yes" "wrong platform: SessionEnd must NOT remove the turn guard"
assert_eq "$(exists sess-gate pin)" "yes" "wrong platform: SessionEnd must NOT remove the pin guard"
clear_guards

# --- UserPromptSubmit dispatch decision, without ever spawning a real guard ---
# A real bin/guard.sh holds a live idle assertion and polls forever; spawning
# it from a test would leak a background process (this machine's own known
# hazard: orphaned guards plus fast Windows PID reuse causing confusing
# cross-run failures later). Instead: copy hook.sh + the real lib it sources
# into a scratch tree, and replace ONLY guard.sh with an inert stub that
# records its argv and exits immediately. hook.sh's own $ROOT computation
# points bin/guard.sh at this scratch copy, so the real UserPromptSubmit
# branch (find_claude_pid, nohup, argv construction) runs for real -- it just
# can't reach a real guard.
#
# Run the SAME scratch copy twice: once with `uname` faked to report Darwin,
# so the real platform gate reads as "right platform" and the dispatch must
# happen; once on the real ambient (non-Darwin) platform, where the gate
# must block it. This proves the gate actually discriminates the dispatch
# decision, not just Stop/SessionEnd.
HOOKTREE="$STAYAWAKE_HOME/hooktree"
mkdir -p "$HOOKTREE/bin" "$HOOKTREE/lib"
cp "$ROOT/bin/hook.sh" "$HOOKTREE/bin/hook.sh"
cp "$ROOT/lib/state.sh" "$HOOKTREE/lib/state.sh"
cp "$ROOT/lib/ancestor.sh" "$HOOKTREE/lib/ancestor.sh"
cat > "$HOOKTREE/bin/guard.sh" <<'EOF'
#!/bin/sh
# Test stub standing in for the real guard.sh: records the dispatch argv
# instead of holding a real idle assertion and polling forever.
printf 'session=%s kind=%s parent=%s\n' "$1" "$2" "$3" > "${STAYAWAKE_HOME}/dispatch-marker"
EOF

wait_for_marker() { # max_tenths_of_a_second
  _n=0
  while [ "$_n" -lt "$1" ]; do
    [ -f "$STAYAWAKE_HOME/dispatch-marker" ] && return 0
    sleep 0.1
    _n=$((_n + 1))
  done
  return 1
}

printf '%s' '{"session_id":"sess-ups","hook_event_name":"UserPromptSubmit"}' \
  | PATH="$FAKE_PATH" sh "$HOOKTREE/bin/hook.sh" UserPromptSubmit
rc=$?
wait_for_marker 30
assert_eq "$rc" "0" "UserPromptSubmit dispatch (faked Darwin): hook exits 0 immediately (detached)"
assert_eq "$(sed -n 's/^session=\([^ ]*\).*/\1/p' "$STAYAWAKE_HOME/dispatch-marker" 2>/dev/null)" "sess-ups" \
  "UserPromptSubmit dispatch (faked Darwin): guard invoked for the right session"
assert_eq "$(sed -n 's/.*kind=\([^ ]*\).*/\1/p' "$STAYAWAKE_HOME/dispatch-marker" 2>/dev/null)" "turn" \
  "UserPromptSubmit dispatch (faked Darwin): guard invoked with kind=turn"
rm -f "$STAYAWAKE_HOME/dispatch-marker"

printf '%s' '{"session_id":"sess-ups2","hook_event_name":"UserPromptSubmit"}' \
  | sh "$HOOKTREE/bin/hook.sh" UserPromptSubmit
rc=$?
sleep 0.5
assert_eq "$rc" "0" "UserPromptSubmit gate (real ambient platform): hook still exits 0"
assert_eq "$([ -f "$STAYAWAKE_HOME/dispatch-marker" ] && echo yes || echo no)" "no" \
  "UserPromptSubmit gate (real ambient platform): guard never invoked, nothing spawned"

rm -rf "$STAYAWAKE_HOME"
finish
