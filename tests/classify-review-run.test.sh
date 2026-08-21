#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/../.github/scripts/classify-review-run.sh"
source "$DIR/lib.sh"

classify() { bash "$SCRIPT" "$@"; }

assert_eq "$(classify success abc abc success)" "valid-current" "matching head is current"
assert_eq "$(classify success abc def success)" "valid-superseded" "completed review remains valid but superseded"
assert_eq "$(classify success abc '' failure)" "valid-head-unverified" "head lookup failure is explicit"
assert_eq "$(classify failure abc abc success)" "invalid-review-status" "failed execution is invalid"
assert_eq "$(classify cancelled abc abc success)" "invalid-review-status" "cancelled execution is invalid"
assert_eq "$(classify success '' abc success)" "invalid-missing-reviewed-head" "missing reviewed head is invalid"

t_summary
