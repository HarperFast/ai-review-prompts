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
if [ "${STUB_FAIL:-0}" = "1" ]; then exit 17; fi
printf '%s\n' "$*" > "$STUB_CAPTURE"
STUB
chmod +x "$TMP/bin/gh"

MARKER='<!-- gemini-review:v1 -->'
RUN_MARKER='<!-- ai-review-run:v1 run=12 attempt=2 head=abc -->'

BODY="$MARKER
$RUN_MARKER
Reviewed; no blockers found." \
PATH="$TMP/bin:$PATH" STUB_CAPTURE="$TMP/call" MARKER="$MARKER" RUN_MARKER="$RUN_MARKER" \
GITHUB_OUTPUT="$TMP/output" GITHUB_REPOSITORY=HarperFast/harper PR_NUMBER=7 bash "$SCRIPT" >/dev/null
assert_contains "$(<"$TMP/call")" "pr comment 7" "bound response is posted"
assert_contains "$(<"$TMP/output")" "posted=true" "successful top-level post is exposed to downstream steps"

rm -f "$TMP/call" "$TMP/output"
BODY="$MARKER
$RUN_MARKER
Reviewed; no blockers found." \
PATH="$TMP/bin:$PATH" STUB_CAPTURE="$TMP/call" MARKER="$MARKER" RUN_MARKER="$RUN_MARKER" \
PRIOR_REVIEW_COMMENT_ID=42 GITHUB_OUTPUT="$TMP/output" GITHUB_REPOSITORY=HarperFast/harper PR_NUMBER=7 bash "$SCRIPT" >/dev/null
assert_contains "$(<"$TMP/call")" "api -X PATCH repos/HarperFast/harper/issues/comments/42" "bound response can edit the exact prior comment"
assert_contains "$(<"$TMP/output")" "posted=true" "successful edit authorizes downstream steps"

rm -f "$TMP/call" "$TMP/output"
BODY=$(printf '%s   \n%s \t\n%s' "$MARKER" "$RUN_MARKER" 'Reviewed; no blockers found.') \
PATH="$TMP/bin:$PATH" STUB_CAPTURE="$TMP/call" MARKER="$MARKER" RUN_MARKER="$RUN_MARKER" \
GITHUB_OUTPUT="$TMP/output" GITHUB_REPOSITORY=HarperFast/harper PR_NUMBER=7 bash "$SCRIPT" >/dev/null
assert_contains "$(<"$TMP/call")" "pr comment 7" "trailing marker whitespace is normalized and posted"
assert_contains "$(<"$TMP/output")" "posted=true" "normalized top-level post authorizes downstream steps"

rm -f "$TMP/call" "$TMP/output"
BODY=$(printf '%s\r\n%s\r\n%s\r\n' "$MARKER" "$RUN_MARKER" 'Reviewed; no blockers found.') \
PATH="$TMP/bin:$PATH" STUB_CAPTURE="$TMP/call" MARKER="$MARKER" RUN_MARKER="$RUN_MARKER" \
GITHUB_OUTPUT="$TMP/output" GITHUB_REPOSITORY=HarperFast/harper PR_NUMBER=7 bash "$SCRIPT" >/dev/null
assert_contains "$(<"$TMP/call")" "pr comment 7" "CRLF-delimited bound response is normalized and posted"

rm -f "$TMP/call" "$TMP/output"
BODY="$MARKER
<!-- ai-review-run:v1 run=other attempt=1 head=abc -->
Reviewed; no blockers found." \
PATH="$TMP/bin:$PATH" STUB_CAPTURE="$TMP/call" MARKER="$MARKER" RUN_MARKER="$RUN_MARKER" \
GITHUB_OUTPUT="$TMP/output" GITHUB_REPOSITORY=HarperFast/harper PR_NUMBER=7 bash "$SCRIPT" >/dev/null
POST_STATUS=$?
if [ -e "$TMP/call" ]; then t_bad "wrong run marker is refused"; else t_ok "wrong run marker is refused"; fi
assert_contains "$(<"$TMP/output")" "posted=false" "refused top-level post blocks downstream steps"
assert_status "$POST_STATUS" 1 "refused unbound post fails the review job loudly"

rm -f "$TMP/call" "$TMP/output"
BODY="$MARKER
$RUN_MARKER
Reviewed; no blockers found." \
PATH="$TMP/bin:$PATH" STUB_FAIL=1 STUB_CAPTURE="$TMP/call" MARKER="$MARKER" RUN_MARKER="$RUN_MARKER" \
GITHUB_OUTPUT="$TMP/output" GITHUB_REPOSITORY=HarperFast/harper PR_NUMBER=7 bash "$SCRIPT" >/dev/null
POST_STATUS=$?
assert_status "$POST_STATUS" 17 "GitHub post failure propagates"
assert_contains "$(<"$TMP/output")" "posted=false" "failed GitHub post blocks downstream steps"

t_summary
