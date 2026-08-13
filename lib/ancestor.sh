# Walks the process tree to find the Claude Code process the guard should watch.
# _ppid_of and _name_of are overridable so the walker can be tested without a
# real process tree.

_ppid_of() { # pid
  ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '
}

_name_of() { # pid
  ps -o comm= -p "$1" 2>/dev/null | tr -d ' '
}

find_claude_pid() { # start_pid
  cur="$1"
  fallback=$(_ppid_of "$cur")
  [ -n "$fallback" ] || fallback="$cur"
  i=0
  while [ "$i" -lt 6 ]; do
    cur=$(_ppid_of "$cur")
    [ -n "$cur" ] || break
    [ "$cur" = "1" ] && break
    [ "$cur" = "0" ] && break
    case "$(_name_of "$cur")" in
      *claude*) printf '%s' "$cur"; return 0 ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$fallback"
}
