#!/usr/bin/env bash
# Split a Gemini review response at a sentinel line (#29).
#
# Reads the full agent response on STDIN. Prints the part BEFORE the
# sentinel line to STDOUT. If $1 (an out-file path) is given, writes the
# part AFTER the sentinel line (sentinel dropped) to that path. With no
# sentinel the whole response goes to STDOUT and the out-file is never
# written, so a missing / malformed marker degrades gracefully (callers
# skip an absent out-file).
#
# The sentinel defaults to the run-notes marker `<!-- gemini-run-notes:v1 -->`
# (the #29 split: PR comment to STDOUT, run notes to the log file).
# Override via the MARKER env var to reuse the same one-pass split for
# other sentinels — e.g. MARKER='<!-- gemini-inline:v1 -->' peels the
# structured inline-comments block off the tail of the PR comment. The
# response is split run-notes-first, then inline-block, so each call sees
# its own marker as the last sentinel in its input.
#
# The sentinel matches ONLY as a trimmed WHOLE line — never an inline
# mention of it in the review text, which would otherwise truncate the
# output and misroute content (Codex P2 on #29).
#
# Single pass: awk reads STDIN once, emitting the head to stdout and
# (after the sentinel) the tail straight to the file — no full-input
# shell buffering, no repeated awk invocations.
set -uo pipefail

MARKER="${MARKER:-<!-- gemini-run-notes:v1 -->}"
NOTES_FILE="${1:-}"

awk -v m="$MARKER" -v nf="$NOTES_FILE" '
  BEGIN { has_notes = (nf != "") }
  { t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t) }
  !found && t == m { found = 1; next }
  !found { print }
  found && has_notes { print > nf }
'
