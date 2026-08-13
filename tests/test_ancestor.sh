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

finish
