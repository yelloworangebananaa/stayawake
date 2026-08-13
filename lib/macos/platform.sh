# macOS power platform module. Sourced, not executed. bash 3.2 / POSIX sh safe.

# Reads `pmset -g batt` on stdin. Echoes "<ac|battery> <percent>".
parse_batt() {
  text=$(cat)
  case "$text" in
    *"'AC Power'"*) source=ac ;;
    *) source=battery ;;
  esac
  pct=$(printf '%s\n' "$text" | sed -n 's/.*[^0-9]\([0-9][0-9]*\)%.*/\1/p' | head -1)
  # ponytail: no percentage in the output means no battery present; treat as full.
  [ -n "$pct" ] || pct=100
  printf '%s %s' "$source" "$pct"
}

# Reads `pmset -g` on stdin. Echoes the disablesleep value.
# macOS omits the key entirely until it has been set at least once, hence the default.
parse_disablesleep() {
  v=$(sed -n 's/^[[:space:]]*disablesleep[[:space:]][[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
  [ -n "$v" ] || v=0
  printf '%s' "$v"
}
