#!/usr/bin/env bash
# Unit tests for .github/scripts/compose-review-scope.sh — composing the
# layered review scope from layer files into the `composed` GITHUB_OUTPUT.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
SCRIPT="$DIR/../.github/scripts/compose-review-scope.sh"

# Run the script against $LDIR with a LAYERS string; leaves the script's
# output file path in $OUT_FILE and captures stdout/stderr to temp files.
run_compose() { # <layers-string>
  OUT_FILE="$(mktemp)"
  LOG_FILE="$(mktemp)"
  # The script echoes ::warning:: annotations to stdout, so capture
  # stdout+stderr combined for log assertions.
  LAYERS="$1" LAYERS_DIR="$LDIR" GITHUB_OUTPUT="$OUT_FILE" \
    bash "$SCRIPT" >"$LOG_FILE" 2>&1
}

# Extract the `composed<<DELIM ... DELIM` heredoc value from a
# GITHUB_OUTPUT file (the random delimiter is read from the opening line).
extract_composed() { # <github-output-file>
  awk '
    /^composed<</ { d = substr($0, index($0, "<<") + 2); inside = 1; next }
    inside && $0 == d { inside = 0; next }
    inside { print }
  ' "$1"
}

LDIR="$(mktemp -d)"
printf 'UNIVERSAL CONTENT\n' > "$LDIR/universal.md"
mkdir -p "$LDIR/harper"
printf 'HARPER V5 CONTENT\n' > "$LDIR/harper/v5.md"

# 1. composes present layers, in order
run_compose $'universal\nharper/v5'; st=$?
assert_status "$st" 0 "two present layers → exit 0"
composed="$(extract_composed "$OUT_FILE")"
assert_contains "$composed" "UNIVERSAL CONTENT" "composed includes universal layer"
assert_contains "$composed" "HARPER V5 CONTENT" "composed includes harper/v5 layer"
case "$composed" in
  *UNIVERSAL*HARPER*) t_ok "layer order preserved (universal before harper/v5)" ;;
  *) t_bad "layer order preserved (universal before harper/v5)" ;;
esac

# 2. a missing layer warns and is skipped; present siblings still compose
run_compose $'universal\nnope/missing'; st=$?
assert_status "$st" 0 "missing layer → still exit 0"
assert_contains "$(cat "$LOG_FILE")" "not found" "missing layer emits a warning"
assert_contains "$(extract_composed "$OUT_FILE")" "UNIVERSAL CONTENT" \
  "present layer still composed when a sibling is missing"

# 3. all layers missing → empty scope → exit 1 (no review = no discipline)
run_compose $'nope/a\nnope/b'; st=$?
assert_status "$st" 1 "all layers missing → exit 1 (empty scope)"

# 4. whitespace around a layer name is trimmed
run_compose $'   universal   '; st=$?
assert_status "$st" 0 "whitespace-padded layer name → exit 0"
assert_contains "$(extract_composed "$OUT_FILE")" "UNIVERSAL CONTENT" \
  "padded layer name resolves to the file"

t_summary
