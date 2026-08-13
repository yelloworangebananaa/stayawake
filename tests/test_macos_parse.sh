HERE="$(dirname "$0")"
. "$HERE/assert.sh"
. "$HERE/../lib/macos/platform.sh"

assert_eq "$(parse_batt < "$HERE/fixtures/pmset-batt-ac.txt")" "ac 100" "AC at full charge"
assert_eq "$(parse_batt < "$HERE/fixtures/pmset-batt-low.txt")" "battery 23" "battery at 23 percent"
assert_eq "$(parse_disablesleep < "$HERE/fixtures/pmset-g-disabled.txt")" "1" "disablesleep set to 1"
assert_eq "$(parse_disablesleep < "$HERE/fixtures/pmset-g-absent.txt")" "0" "absent disablesleep defaults to 0"

finish
