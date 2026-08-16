#!/bin/sh
# usage: hook.sh <UserPromptSubmit|Stop|SessionEnd>
# Reads the hook payload on stdin, extracts session_id, and starts or stops a
# guard. Registered unconditionally alongside the powershell command form in
# hooks/hooks.json (see docs/hook-dispatch.md) -- the OS guard below is what
# makes this a no-op everywhere except macOS. On a Windows machine with Git
# Bash on PATH, `sh` resolves and this script WILL run; without the guard it
# would double up with hook.ps1 on every turn.
[ "$(uname -s)" = "Darwin" ] || exit 0
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/lib/state.sh"
. "$ROOT/lib/ancestor.sh"

EVENT="${1:-}"
PAYLOAD=$(cat)
# POSIX BRE sed extraction (no \+ \s \? \| -- must also run under BSD sed on
# macOS). A malformed/missing payload must never block the turn: fall back to
# a placeholder session id and exit 0 regardless of what happens above.
SESSION=$(printf '%s' "$PAYLOAD" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -n "$SESSION" ] || SESSION="unknown"

case "$EVENT" in
  UserPromptSubmit)
    # find_claude_pid walks past this short-lived hook shell to the actual
    # Claude Code process -- a guard watching the hook's own pid would see
    # its parent exit almost immediately and drop protection mid-turn.
    PARENT=$(find_claude_pid "$$")
    # Detached and backgrounded so this hook returns immediately; a hook
    # that blocks on the guard adds latency to every prompt submission.
    nohup sh "$ROOT/bin/guard.sh" "$SESSION" "turn" "$PARENT" >/dev/null 2>&1 &
    ;;
  Stop)
    guard_unregister "$SESSION" "turn"
    ;;
  SessionEnd)
    guard_unregister "$SESSION" "turn"
    guard_unregister "$SESSION" "pin"
    ;;
esac
exit 0
