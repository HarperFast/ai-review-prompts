#!/usr/bin/env bash
# Unit tests for .github/scripts/split-gemini-response.sh — splitting the
# Gemini response into PR comment + run-notes at the whole-line sentinel.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
SCRIPT="$DIR/../.github/scripts/split-gemini-response.sh"

TMPS=()
cleanup() { [ "${#TMPS[@]}" -gt 0 ] && rm -f "${TMPS[@]}"; }
trap cleanup EXIT

# split <input>: sets $COMMENT (stdout) and writes notes to a fresh $NOTES
# (pre-emptied, so "no notes written" is observable as an empty file).
split() { # <input>
  NOTES="$(mktemp)"; TMPS+=("$NOTES")
  : > "$NOTES"
  COMMENT="$(printf '%s' "$1" | bash "$SCRIPT" "$NOTES")"
}

# 1. whole-line marker → comment before, notes after, sentinel stripped
R=$'<!-- gemini-review:v1 -->\nReviewed; no blockers found.\n\n<!-- gemini-run-notes:v1 -->\n## Run notes\n\n### Surfaces verified\n- compose-review-scope.sh'
split "$R"
assert_contains "$COMMENT" "Reviewed; no blockers found." "comment keeps the review text"
assert_not_contains "$COMMENT" "gemini-run-notes" "comment excludes the sentinel line"
assert_not_contains "$COMMENT" "Run notes" "comment excludes the notes body"
assert_contains "$(cat "$NOTES")" "## Run notes" "notes file has the run-notes body"
assert_not_contains "$(cat "$NOTES")" "gemini-run-notes:v1" "notes file drops the sentinel line"
assert_not_contains "$(cat "$NOTES")" "Reviewed; no blockers" "notes file excludes the comment"

# 2. inline mention only (no whole-line marker) → no split (Codex regression)
R=$'<!-- gemini-review:v1 -->\n1 blocker.\n\n### 1. breaks if the agent writes <!-- gemini-run-notes:v1 --> inline.'
split "$R"
assert_contains "$COMMENT" "inline." "inline mention stays in the comment"
assert_eq "$(cat "$NOTES")" "" "inline mention writes no notes"

# 3. inline mention in comment + a real whole-line marker later
R=$'<!-- gemini-review:v1 -->\nthe <!-- gemini-run-notes:v1 --> marker inline.\n\n<!-- gemini-run-notes:v1 -->\n## Run notes\n- y'
split "$R"
assert_contains "$COMMENT" "marker inline." "comment keeps the inline mention"
assert_not_contains "$COMMENT" "## Run notes" "comment excludes notes after the real marker"
assert_contains "$(cat "$NOTES")" "## Run notes" "notes captured from the whole-line marker"

# 4. indented / trailing-space marker line still splits
R=$'<!-- gemini-review:v1 -->\nok\n   <!-- gemini-run-notes:v1 -->   \n## Run notes\n- z'
split "$R"
assert_not_contains "$COMMENT" "Run notes" "whitespace-padded marker still splits the comment"
assert_contains "$(cat "$NOTES")" "## Run notes" "whitespace-padded marker still writes notes"

# 5. no marker → whole response is the comment, no notes
R=$'<!-- gemini-review:v1 -->\n2 blockers found.'
split "$R"
assert_contains "$COMMENT" "2 blockers found." "no marker → whole response is the comment"
assert_eq "$(cat "$NOTES")" "" "no marker → no notes written"

# 6. empty input → empty comment, no notes
split ""
assert_eq "$COMMENT" "" "empty input → empty comment"
assert_eq "$(cat "$NOTES")" "" "empty input → no notes"

t_summary
