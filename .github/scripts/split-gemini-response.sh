#!/usr/bin/env bash
# Split a Gemini review response at the run-notes sentinel (#29).
#
# Reads the full agent response on STDIN. Prints the PR-comment part —
# everything BEFORE the `<!-- gemini-run-notes:v1 -->` line — to STDOUT.
# If $1 (a notes-file path) is given AND the sentinel appears as a whole
# line, writes the run-notes part (everything AFTER the sentinel line,
# sentinel dropped) to that path. With no sentinel the whole response is
# the comment and the notes file is left untouched, so a missing /
# malformed marker degrades gracefully (the log step skips an absent
# notes file).
#
# The sentinel matches ONLY as a trimmed WHOLE line — never an inline
# mention of it in the review text, which would otherwise truncate the
# PR comment and misroute real findings into the log (Codex P2 on #29).
set -uo pipefail

MARKER='<!-- gemini-run-notes:v1 -->'
NOTES_FILE="${1:-}"
input="$(cat)"
[ -z "$input" ] && exit 0

# True when some line, trimmed, equals the sentinel.
has_marker() {
  printf '%s\n' "$input" | awk -v m="$MARKER" '
    {t=$0; sub(/^[ \t]+/,"",t); sub(/[ \t]+$/,"",t)}
    t==m {hit=1}
    END {exit(hit?0:1)}'
}

if has_marker; then
  # Comment: lines before the sentinel line.
  printf '%s\n' "$input" | awk -v m="$MARKER" '
    {t=$0; sub(/^[ \t]+/,"",t); sub(/[ \t]+$/,"",t)}
    t==m {exit}
    {print}'
  # Notes: lines after the sentinel line (the sentinel itself dropped).
  if [ -n "$NOTES_FILE" ]; then
    printf '%s\n' "$input" | awk -v m="$MARKER" '
      {t=$0; sub(/^[ \t]+/,"",t); sub(/[ \t]+$/,"",t)}
      f {print}
      t==m {f=1}' > "$NOTES_FILE"
  fi
else
  printf '%s\n' "$input"
fi
