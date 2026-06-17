#!/usr/bin/env bash
# Minimal zero-dependency assertion helpers for the .github/scripts/
# unit tests. A test file sources this, runs assertions, then ends with
# `t_summary` — whose exit status (0 iff every assertion passed) becomes
# the file's exit status, which tests/run.sh aggregates.

t_pass=0
t_fail=0

t_ok() { t_pass=$((t_pass + 1)); printf '  ok   %s\n' "$1"; }
t_bad() { t_fail=$((t_fail + 1)); printf '  FAIL %s\n' "$1"; }

# assert_eq <actual> <expected> <message>
assert_eq() {
  if [ "$1" = "$2" ]; then
    t_ok "$3"
  else
    t_bad "$3"
    printf '       got:  %q\n       want: %q\n' "$1" "$2"
  fi
}

# assert_contains <haystack> <needle> <message>
assert_contains() {
  case "$1" in
    *"$2"*) t_ok "$3" ;;
    *) t_bad "$3"; printf '       missing substring: %q\n' "$2" ;;
  esac
}

# assert_not_contains <haystack> <needle> <message>
assert_not_contains() {
  case "$1" in
    *"$2"*) t_bad "$3"; printf '       unexpected substring: %q\n' "$2" ;;
    *) t_ok "$3" ;;
  esac
}

# assert_status <actual-code> <expected-code> <message>
assert_status() {
  if [ "$1" -eq "$2" ]; then
    t_ok "$3"
  else
    t_bad "$3"
    printf '       exit status %s != %s\n' "$1" "$2"
  fi
}

t_summary() {
  printf '  [%d passed, %d failed]\n' "$t_pass" "$t_fail"
  [ "$t_fail" -eq 0 ]
}
