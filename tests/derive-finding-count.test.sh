#!/usr/bin/env bash
# Unit tests for .github/scripts/derive-finding-count.sh — deriving the
# finding count that builds the ai-review-log issue title. Regression
# anchor: issue #68 (a spelled-out count + inline-only finding logged as
# "no blockers", hiding a real blocker — ai-review-log #683).
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
SCRIPT="$DIR/../.github/scripts/derive-finding-count.sh"

count() { printf '%s' "$1" | bash "$SCRIPT"; } # <body> -> integer on stdout

# 1. Explicit clean pass → 0.
assert_eq "$(count $'<!-- claude-review:v1 -->\nReviewed; no blockers found.')" "0" \
  "no blockers found -> 0"

# 2. Leading digit count.
assert_eq "$(count $'<!-- claude-review:v1 -->\n1 blocker found.')" "1" "1 blocker found -> 1"
assert_eq "$(count '2 blockers found.')" "2" "2 blockers found -> 2"

# 3. Markdown-wrapped digit summary still counts.
assert_eq "$(count '**3 blockers found.**')" "3" "bold-wrapped 3 blockers -> 3"

# 4. #68 REGRESSION: spelled-out count + inline-only finding (no `### N.`
#    header). Before the fix this fell through to 0 → "no blockers" title.
R=$'<!-- claude-review:v1 -->\nOne blocker found — see inline comment on line 2753.\n\n---\n\n## Run notes\n- traced the blob-handle leak path'
assert_eq "$(count "$R")" "1" "#683: 'One blocker found' + inline-only -> 1 (not 0)"

# 5. Other spelled-out cardinals.
assert_eq "$(count 'Three blockers found.')" "3" "spelled 'Three' -> 3"
assert_eq "$(count 'Ten blockers found.')" "10" "spelled 'Ten' -> 10"

# 6. Count line is primary: wins over a different `### N.` header tally.
assert_eq "$(count $'2 blockers found.\n\n### 1. a\n### 2. b\n### 3. c')" "2" \
  "count line beats header count (2, not 3)"

# 7. No count-summary line → structural `### N.` header fallback.
assert_eq "$(count $'### 1. first\n\n### 2. second\n\n### 3. third')" "3" \
  "no summary line -> header count"

# 8. Defensive floor (#68): asserts blockers but no parseable count.
assert_eq "$(count 'Blocker found.')" "1" "unparseable 'Blocker found.' floors to 1"
assert_eq "$(count $'Multiple blockers found:\n\n### 1. a\n### 2. b')" "2" \
  "unparseable assertion + headers -> header count (2)"

# 9. "no blockers" wins even when a non-finding `### Suggestions` header
#    is present (suggestions are `### <word>`, not `### N.`).
assert_eq "$(count $'Reviewed; no blockers found.\n\n### Suggestions (non-blocking)\n- foo')" "0" \
  "no blockers + suggestions section -> 0"

# 10. Empty / whitespace input → 0.
assert_eq "$(count '')" "0" "empty input -> 0"

t_summary
