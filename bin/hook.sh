#!/bin/sh
# Spike: record that we ran, what shell we are, and what stdin looked like.
[ "$(uname -s)" = "Darwin" ] || exit 0
{
  echo "--- hook.sh ran at $(date) ---"
  echo "shell=$0 ppid=$PPID"
  echo "stdin:"
  cat
} >> "${TMPDIR:-/tmp}/stayawake-spike.log" 2>&1
exit 0
