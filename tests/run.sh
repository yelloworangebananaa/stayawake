#!/bin/sh
# Runs every tests/test_*.sh in a subshell. Exits non-zero if any fail.
cd "$(dirname "$0")" || exit 1
rc=0
for t in test_*.sh; do
  [ -f "$t" ] || continue
  printf '\n== %s ==\n' "$t"
  sh "$t" || rc=1
done
exit "$rc"
