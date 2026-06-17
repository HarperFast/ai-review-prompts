#!/usr/bin/env bash
# Split a Gemini review response at the run-notes sentinel (#29).
#
# Reads the full agent response on STDIN. Prints the PR-comment part —
# everything BEFORE the `<!-- gemini-run-notes:v1 -->` line — to STDOUT.
# If $1 (a notes-file path) is given, writes the run-notes part
# (everything AFTER the sentinel line, sentinel dropped) to that path.
# With no sentinel the whole response is the comment and the notes file
# is never written, so a missing / malformed marker degrades gracefully
# (the log step skips an absent notes file).
#
# The sentinel matches ONLY as a trimmed WHOLE line — never an inline
# mention of it in the review text, which would otherwise truncate the
# PR comment and misroute real findings into the log (Codex P2 on #29).
#
# Single pass: awk reads STDIN once, emitting the comment to stdout and
# (after the sentinel) the notes straight to the file — no full-input
# shell buffering, no repeated awk invocations.
set -uo pipefail

MARKER='<!-- gemini-run-notes:v1 -->'
NOTES_FILE="${1:-}"

awk -v m="$MARKER" -v nf="$NOTES_FILE" '
  BEGIN { has_notes = (nf != "") }
  { t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t) }
  !found && t == m { found = 1; next }
  !found { print }
  found && has_notes { print > nf }
'
