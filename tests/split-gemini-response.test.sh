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

# 7. MARKER override → split at a different whole-line sentinel (the
#    inline-comments block), reusing the same one-pass logic.
INLINE_MARK='<!-- gemini-inline:v1 -->'
split_m() { # <input> <marker>
  OUTF="$(mktemp)"; TMPS+=("$OUTF"); : > "$OUTF"
  HEAD="$(printf '%s' "$1" | MARKER="$2" bash "$SCRIPT" "$OUTF")"
}
R=$'<!-- gemini-review:v1 -->\n1 blocker found.\n\n<!-- gemini-inline:v1 -->\n[{"path":"a.ts","line":1}]'
split_m "$R" "$INLINE_MARK"
assert_contains "$HEAD" "1 blocker found." "MARKER override: text before the inline marker is kept"
assert_not_contains "$HEAD" "gemini-inline:v1" "MARKER override: inline sentinel stripped from head"
assert_not_contains "$HEAD" "a.ts" "MARKER override: JSON excluded from head"
assert_contains "$(cat "$OUTF")" '[{"path":"a.ts"' "MARKER override: JSON written to the out-file"

# 8. full 3-way peel (run-notes first, then inline) — the workflow's
#    exact sequence: top-level comment | inline JSON | run notes.
R=$'<!-- gemini-review:v1 -->\nReviewed; 1 blocker found.\n\n<!-- gemini-inline:v1 -->\n[{"path":"x.ts","line":9,"kind":"finding"}]\n<!-- gemini-run-notes:v1 -->\n## Run notes\n- traced auth'
NOTES="$(mktemp)"; TMPS+=("$NOTES"); : > "$NOTES"
INLINE="$(mktemp)"; TMPS+=("$INLINE"); : > "$INLINE"
PRE="$(printf '%s' "$R" | bash "$SCRIPT" "$NOTES")"
CMT="$(printf '%s' "$PRE" | MARKER="$INLINE_MARK" bash "$SCRIPT" "$INLINE")"
assert_contains "$CMT" "1 blocker found." "3-way: top-level comment retained"
assert_not_contains "$CMT" "x.ts" "3-way: inline JSON peeled off the comment"
assert_not_contains "$CMT" "Run notes" "3-way: run notes peeled off the comment"
assert_contains "$(cat "$INLINE")" '"x.ts"' "3-way: inline file has the JSON"
assert_not_contains "$(cat "$INLINE")" "Run notes" "3-way: inline file excludes run notes"
assert_contains "$(cat "$NOTES")" "## Run notes" "3-way: notes file has the run notes"
assert_not_contains "$(cat "$NOTES")" "x.ts" "3-way: notes file excludes the inline JSON"

t_summary
