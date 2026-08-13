HERE="$(dirname "$0")"
. "$HERE/assert.sh"
. "$HERE/../lib/ancestor.sh"

# The walker is pure given an injectable parent-lookup and name-lookup, so the
# tree is faked rather than requiring a real claude process.
_ppid_of() { case "$1" in 100) echo 200 ;; 200) echo 300 ;; 300) echo 1 ;; *) echo 1 ;; esac; }
_name_of() { case "$1" in 100) echo sh ;; 200) echo bash ;; 300) echo claude ;; *) echo init ;; esac; }

assert_eq "$(find_claude_pid 100)" "300" "walks up to the claude process"

_name_of() { echo bash; }
assert_eq "$(find_claude_pid 100)" "200" "falls back to immediate parent when no claude found"

# Test deep chain - claude at level 6 (should be found, verifies 6-level cap)
_ppid_of() { case "$1" in 1000) echo 1001 ;; 1001) echo 1002 ;; 1002) echo 1003 ;; 1003) echo 1004 ;; 1004) echo 1005 ;; 1005) echo 1006 ;; 1006) echo 1 ;; *) echo 1 ;; esac; }
_name_of() { case "$1" in 1000) echo sh ;; 1001) echo bash ;; 1002) echo python ;; 1003) echo docker ;; 1004) echo systemd ;; 1005) echo node ;; 1006) echo claude ;; *) echo init ;; esac; }

assert_eq "$(find_claude_pid 1000)" "1006" "finds claude at level 6"

# Test deep chain - claude at level 7 (past cap, should return fallback and verify cap)
_ppid_of() { case "$1" in 2000) echo 2001 ;; 2001) echo 2002 ;; 2002) echo 2003 ;; 2003) echo 2004 ;; 2004) echo 2005 ;; 2005) echo 2006 ;; 2006) echo 2007 ;; 2007) echo 1 ;; *) echo 1 ;; esac; }
_name_of() { case "$1" in 2000) echo sh ;; 2001) echo bash ;; 2002) echo python ;; 2003) echo docker ;; 2004) echo systemd ;; 2005) echo node ;; 2006) echo npm ;; 2007) echo claude ;; *) echo init ;; esac; }

assert_eq "$(find_claude_pid 2000)" "2001" "falls back when claude is at level 7 (past 6-level cap)"

# Test PID 1 boundary - PID 1 is resolvable but walker should stop there
_ppid_of() { case "$1" in 3000) echo 3001 ;; 3001) echo 1 ;; 1) echo 0 ;; *) echo 1 ;; esac; }
_name_of() { case "$1" in 3000) echo sh ;; 3001) echo bash ;; 1) echo init ;; 0) echo kernel ;; *) echo init ;; esac; }

assert_eq "$(find_claude_pid 3000)" "3001" "stops at PID 1 boundary even when resolvable"

finish
