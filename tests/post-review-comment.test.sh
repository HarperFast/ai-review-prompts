#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/../.github/scripts/post-review-comment.sh"
source "$DIR/lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$STUB_CAPTURE"
STUB
chmod +x "$TMP/bin/gh"

MARKER='<!-- gemini-review:v1 -->'
RUN_MARKER='<!-- ai-review-run:v1 run=12 attempt=2 head=abc -->'

BODY="$MARKER
$RUN_MARKER
Reviewed; no blockers found." \
PATH="$TMP/bin:$PATH" STUB_CAPTURE="$TMP/call" MARKER="$MARKER" RUN_MARKER="$RUN_MARKER" \
GITHUB_REPOSITORY=HarperFast/harper PR_NUMBER=7 bash "$SCRIPT" >/dev/null
assert_contains "$(<"$TMP/call")" "pr comment 7" "bound response is posted"

rm -f "$TMP/call"
BODY=$(printf '%s\r\n%s\r\n%s\r\n' "$MARKER" "$RUN_MARKER" 'Reviewed; no blockers found.') \
PATH="$TMP/bin:$PATH" STUB_CAPTURE="$TMP/call" MARKER="$MARKER" RUN_MARKER="$RUN_MARKER" \
GITHUB_REPOSITORY=HarperFast/harper PR_NUMBER=7 bash "$SCRIPT" >/dev/null
assert_contains "$(<"$TMP/call")" "pr comment 7" "CRLF-delimited bound response is normalized and posted"

rm -f "$TMP/call"
BODY="$MARKER
<!-- ai-review-run:v1 run=other attempt=1 head=abc -->
Reviewed; no blockers found." \
PATH="$TMP/bin:$PATH" STUB_CAPTURE="$TMP/call" MARKER="$MARKER" RUN_MARKER="$RUN_MARKER" \
GITHUB_REPOSITORY=HarperFast/harper PR_NUMBER=7 bash "$SCRIPT" >/dev/null
if [ -e "$TMP/call" ]; then t_bad "wrong run marker is refused"; else t_ok "wrong run marker is refused"; fi

t_summary
