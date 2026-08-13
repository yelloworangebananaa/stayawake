#!/bin/sh
# usage: stayawake.sh <setup|uninstall|status|on|off|restore-if-stale> [arg]
#   on/off              [arg] is the session id (default "manual").
#   restore-if-stale    [arg] is the mode: "" (normal), "force", or "boot".
#                       See sa_restore_if_stale in lib/macos/setup.sh.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/lib/state.sh"
. "$ROOT/lib/macos/platform.sh"
. "$ROOT/lib/macos/setup.sh"
. "$ROOT/lib/ancestor.sh"

VERB="${1:-status}"
SESSION="${2:-manual}"

case "$VERB" in
  setup)            sa_setup "$ROOT" ;;
  uninstall)        sa_uninstall ;;
  status)           sa_status ;;
  restore-if-stale) sa_restore_if_stale "${2:-}" ;;
  on)
    PARENT=$(find_claude_pid "$$")
    nohup sh "$ROOT/bin/guard.sh" "$SESSION" "pin" "$PARENT" >/dev/null 2>&1 &
    echo "stayawake: pinned on for this session."
    ;;
  off)
    guard_unregister "$SESSION" "pin"
    echo "stayawake: pin released."
    ;;
  *)
    echo "stayawake: unknown verb '$VERB'" >&2
    exit 1
    ;;
esac
