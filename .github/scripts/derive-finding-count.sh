#!/usr/bin/env bash
# Derive the finding/blocker count from a review comment body (read on
# stdin) and print a single non-negative integer to stdout. Used to
# build the ai-review-log issue title — `N finding(s) — triage pending`
# vs `no blockers`. Pure logic (no gh / network), so it is unit-tested
# in tests/derive-finding-count.test.sh.
#
# The first non-blank, non-`<!--` line is the reviewer's standardized
# one-sentence summary; both reviewers' prompts emit either
# "Reviewed; no blockers found." or "N blocker(s) found." The substance
# can live in inline review comments instead of `### N.` headers, so the
# summary line — not the header count — is the primary signal, with the
# header count as a structural fallback.
#
# Hardening (issue #68): a summary that ASSERTS blockers were found must
# never collapse to 0. That regression happened on ai-review-log #683 /
# harper-pro#455: the count was spelled out ("One blocker found.") AND
# the finding was inline-only (no `### N.` header), so the digit regex
# missed "One", the header fallback returned 0, and a real blocker was
# logged under a "no blockers" title. We now (3) parse spelled-out
# cardinals and (4) floor any non-"no blockers" "...blocker(s) found."
# summary to >= 1.
set -uo pipefail

BODY=$(cat)

# First content line = the reviewer's one-sentence summary.
count_line=$(printf '%s\n' "$BODY" \
  | grep -v -E '^([[:space:]]*$|<!--)' \
  | head -1)

# Structural fallback / floor input: count of `### N.` finding headers.
header_count=$(printf '%s\n' "$BODY" | grep -c -E '^### [0-9]' || true)

# 1. Explicit clean pass. Checked first so a no-blockers line can never be
#    floored to >= 1 by step 4. The "no" is word-anchored ((^|[^a-zA-Z]))
#    so a token that merely ends in "no" ("Casino blockers found.") does
#    NOT read as clean — it falls through to the floor, since the safe
#    direction on any "...blocker(s) found." is >= 1, never 0. One optional
#    adjective is tolerated ("No critical/significant/new blockers found.")
#    so a real clean re-review isn't inflated to a phantom finding by step 4.
if printf '%s' "$count_line" | grep -qiE '(^|[^a-zA-Z])no( [a-zA-Z]+)? blockers? found'; then
  echo 0
  exit 0
fi

# 2. Leading digit count: "2 blockers found.", "**1 blocker found.**".
#    `[[:space:]*_]*` tolerates leading whitespace / bold / italic.
if printf '%s' "$count_line" | grep -qiE '^[[:space:]*_]*[0-9]+ blockers? found'; then
  printf '%s' "$count_line" | grep -oE '[0-9]+' | head -1
  exit 0
fi

# 3. Leading spelled-out cardinal: "One blocker found." (the #68 form
#    that previously slipped through to 0).
word=$(printf '%s' "$count_line" \
  | grep -ioE '^[[:space:]*_]*(one|two|three|four|five|six|seven|eight|nine|ten) blockers? found' \
  | grep -ioE 'one|two|three|four|five|six|seven|eight|nine|ten' \
  | head -1 | tr '[:upper:]' '[:lower:]')
if [ -n "$word" ]; then
  case "$word" in
    one) echo 1 ;; two) echo 2 ;; three) echo 3 ;; four) echo 4 ;; five) echo 5 ;;
    six) echo 6 ;; seven) echo 7 ;; eight) echo 8 ;; nine) echo 9 ;; ten) echo 10 ;;
  esac
  exit 0
fi

# 4. Defensive floor (#68): the summary asserts blockers were found (and
#    it is not the "no blockers" form, handled in step 1) but no count
#    parsed — never report 0. Use the header count if any, else floor to
#    1, so a real finding is always logged rather than hidden.
if printf '%s' "$count_line" | grep -qiE 'blockers? found'; then
  if [ "$header_count" -gt 0 ]; then echo "$header_count"; else echo 1; fi
  exit 0
fi

# 5. No count summary at all (older formats / a body that opens with
#    structured findings) → structural header count.
echo "$header_count"
