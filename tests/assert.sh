# Minimal assertion harness. Sourced, not executed.
SA_TESTS=0
SA_FAILS=0

assert_eq() { # actual expected name
  SA_TESTS=$((SA_TESTS + 1))
  if [ "$1" = "$2" ]; then
    printf '  ok   %s\n' "$3"
  else
    printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$3" "$2" "$1"
    SA_FAILS=$((SA_FAILS + 1))
  fi
}

finish() {
  printf '\n%s tests, %s failures\n' "$SA_TESTS" "$SA_FAILS"
  [ "$SA_FAILS" -eq 0 ]
}
