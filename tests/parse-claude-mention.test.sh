#!/usr/bin/env bash
# Unit tests for .github/scripts/parse-claude-mention.sh — the precision
# gate deciding whether an `@claude` comment proceeds, and which model.
# (Uses grep -P; runs on GNU grep in CI.)
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
SCRIPT="$DIR/../.github/scripts/parse-claude-mention.sh"

# parse-claude-mention.sh uses `grep -P` (PCRE) and `-z` (GNU null-data);
# both are GNU-grep features. On a non-GNU grep (BSD, ugrep) the script
# can't run, so skip cleanly — CI (ubuntu / GNU grep) runs these for real.
if ! grep --version 2>/dev/null | grep -q 'GNU grep'; then
  echo "  SKIP — requires GNU grep (script uses grep -P/-z); local grep is not GNU. CI runs these."
  exit 0
fi

# Run the script with a BODY; return "<proceed>|<model>" from GITHUB_OUTPUT.
run_parse() { # <comment-body>
  local out proceed model
  out="$(mktemp)"
  BODY="$1" GITHUB_OUTPUT="$out" bash "$SCRIPT" >/dev/null 2>&1
  proceed="$(grep -E '^proceed=' "$out" | tail -1 | cut -d= -f2-)"
  model="$(grep -E '^model=' "$out" | tail -1 | cut -d= -f2-)"
  rm -f "$out"
  printf '%s|%s' "${proceed:-}" "${model:-}"
}

# proceed + model selection
assert_eq "$(run_parse '@claude fix this')"          "true|claude-sonnet-4-6" "@claude first → proceed, sonnet default"
assert_eq "$(run_parse '   @claude please look')"    "true|claude-sonnet-4-6" "leading whitespace before @claude → proceed"
assert_eq "$(run_parse '@claude do a deep review')"  "true|claude-opus-4-8"   "'deep' → opus"
assert_eq "$(run_parse '@claude DEEP dive')"         "true|claude-opus-4-8"   "'DEEP' (case-insensitive) → opus"
assert_eq "$(run_parse '@claude deepen the tests')"  "true|claude-sonnet-4-6" "'deepen' (no word boundary) → sonnet, not opus"

# rejection (precision gate)
assert_eq "$(run_parse '@claudette fix this')"       "false|" "@claudette (word boundary) → no proceed"
assert_eq "$(run_parse 'saw @claude fix earlier')"   "false|" "inline @claude (not first token) → no proceed"
assert_eq "$(run_parse '> @claude can you help')"    "false|" "quoted reply (> @claude) → no proceed"
assert_eq "$(run_parse 'just a normal comment')"     "false|" "no @claude → no proceed"

t_summary
