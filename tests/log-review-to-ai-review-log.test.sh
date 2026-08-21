#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/../.github/scripts/log-review-to-ai-review-log.sh"
source "$DIR/lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
ARGS="$*"
if [[ "$ARGS" == *"/actions/runs/"* ]]; then
	printf '%s\n' '2026-08-20T10:00:00Z'
elif [[ "$ARGS" == *"/pulls/7 --jq"* ]]; then
	printf '%s\n' "$STUB_CURRENT_HEAD"
elif [[ "$ARGS" == *"repos/HarperFast/ai-review-log/issues?"* ]]; then
	printf '%s\n' '[]'
	if [ "${STUB_EXISTING_ISSUE:-0}" = "1" ]; then
		printf '%s\n' '[{"title":"[harper] PR #7: no blockers","number":42}]'
	else
		printf '%s\n' '[]'
	fi
elif [[ "$ARGS" == *"/issues/7/comments"* ]]; then
	if [ "${STUB_CRLF:-0}" = "1" ]; then
		CORRECT=$(printf '%s\r\n%s\r\n%s' "$STUB_MARKER" "$STUB_RUN_MARKER" "$STUB_REVIEW_TEXT")
	else
		CORRECT="${STUB_MARKER}
${STUB_RUN_MARKER}
${STUB_REVIEW_TEXT}"
	fi
	WRONG="${STUB_MARKER}
<!-- ai-review-run:v1 run=999 attempt=1 head=abc -->
wrong concurrent body"
	jq -nc --arg wrong "$WRONG" '[{body:$wrong, updated_at:"2026-08-20T10:02:00Z", created_at:"2026-08-20T10:02:00Z"}]'
	jq -nc --arg correct "$CORRECT" '[{body:$correct, updated_at:"2026-08-20T10:01:00Z", created_at:"2026-08-20T10:01:00Z"}]'
else
	exit 1
fi
STUB
chmod +x "$TMP/bin/gh"

cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
OUT=""
DATA=""
URL=""
METHOD="GET"
while [ "$#" -gt 0 ]; do
	case "$1" in
		-o) OUT="$2"; shift 2 ;;
		-d) DATA="$2"; shift 2 ;;
		-X) METHOD="$2"; shift 2 ;;
		http*) URL="$1"; shift ;;
		*) shift ;;
	esac
done
printf '%s %s\n' "$METHOD" "$URL" >> "$STUB_CURL_LOG"
if [[ "$URL" == "https://api.github.com/repos/HarperFast/ai-review-log/issues" ]]; then
	printf '%s\n' "$DATA" > "$STUB_CAPTURE"
	printf '%s\n' '{"html_url":"https://example/log/42","number":42}' > "$OUT"
	printf '201'
elif [[ "$URL" == *"/issues/42/comments" ]]; then
	printf '%s\n' '{"html_url":"https://example/log/42#comment"}' > "$OUT"
	printf '201'
elif [ -n "$OUT" ] && [ "$OUT" != "/dev/null" ]; then
	printf '%s\n' '{}' > "$OUT"
	printf '200'
fi
STUB
chmod +x "$TMP/bin/curl"

MARKER='<!-- claude-review:v1 -->'
RUN_MARKER='<!-- ai-review-run:v1 run=123 attempt=2 head=abc -->'
printf '%s\n' '{"status":"partial"}' > "$TMP/context.json"

run_logger() {
	rm -f "$TMP/payload.json"
	rm -f "$TMP/curl.log"
	PATH="$TMP/bin:$PATH" \
	STUB_CAPTURE="$TMP/payload.json" \
	STUB_CURL_LOG="$TMP/curl.log" \
	STUB_CURRENT_HEAD="$1" \
	STUB_EXISTING_ISSUE="${3:-0}" \
	STUB_CRLF="${4:-0}" \
	STUB_MARKER="$MARKER" \
	STUB_RUN_MARKER="$RUN_MARKER" \
	STUB_REVIEW_TEXT='Reviewed; no blockers found.' \
	GH_TOKEN=token AI_REVIEW_LOG_TOKEN=log-token \
	GITHUB_REPOSITORY=HarperFast/harper GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=2 \
	PR_NUMBER=7 PR_URL=https://example/pr/7 REPO_SHORT=harper \
	REVIEW_STATUS="$2" BASE_SHA=base REVIEWED_HEAD_SHA=abc \
	REVIEW_CONTEXT_FILE="$TMP/context.json" \
	MARKER="$MARKER" MODEL=claude-sonnet bash "$SCRIPT" >/dev/null
}

run_logger abc success
assert_status "$?" 0 "current run logger remains best-effort"
PAYLOAD=$(<"$TMP/payload.json")
assert_eq "$(printf '%s' "$PAYLOAD" | jq -r '.title')" "[harper] PR #7: no blockers" "current successful run keeps clean title"
assert_contains "$(printf '%s' "$PAYLOAD" | jq -r '.body')" "**Run ID:** 123" "run id is immutable row metadata"
assert_contains "$(printf '%s' "$PAYLOAD" | jq -r '.body')" "**Run attempt:** 2" "run attempt is immutable row metadata"
assert_contains "$(printf '%s' "$PAYLOAD" | jq -r '.body')" "**Base SHA:** base" "base sha is recorded"
assert_contains "$(printf '%s' "$PAYLOAD" | jq -r '.body')" "**Reviewed head:** abc" "reviewed head is recorded"
assert_contains "$(printf '%s' "$PAYLOAD" | jq -r '.body')" "**Run validity:** valid-current" "current-head validity is recorded"
assert_contains "$(printf '%s' "$PAYLOAD" | jq -r '.body')" "**Review context:** partial" "snapshot completeness is recorded"
assert_not_contains "$(printf '%s' "$PAYLOAD" | jq -r '.body')" "wrong concurrent body" "body is selected by exact run binding"

run_logger def success
assert_status "$?" 0 "superseded run logger remains best-effort"
PAYLOAD=$(<"$TMP/payload.json")
assert_contains "$(printf '%s' "$PAYLOAD" | jq -r '.title')" "superseded by push" "superseded run is not titled as a clean current verdict"
assert_not_contains "$(printf '%s' "$PAYLOAD" | jq -r '.title')" "no blockers" "superseded title cannot masquerade as current clean"
assert_contains "$(printf '%s' "$PAYLOAD" | jq -r '.body')" "**Run validity:** valid-superseded" "superseded evidence remains attributable"

run_logger '' success
assert_status "$?" 0 "head-unverified logger remains best-effort"
PAYLOAD=$(<"$TMP/payload.json")
assert_contains "$(printf '%s' "$PAYLOAD" | jq -r '.title')" "current head unverified" "head API failure cannot produce a clean-current title"
assert_contains "$(printf '%s' "$PAYLOAD" | jq -r '.body')" "**Run validity:** valid-head-unverified" "head lookup failure remains explicit"

run_logger abc success 0 1
assert_status "$?" 0 "CRLF-bound review remains loggable"
PAYLOAD=$(<"$TMP/payload.json")
assert_eq "$(printf '%s' "$PAYLOAD" | jq -r '.title')" "[harper] PR #7: no blockers" "CRLF marker lines are normalized before binding"

run_logger def success 1
assert_status "$?" 0 "superseded existing-issue logger remains best-effort"
assert_not_contains "$(<"$TMP/curl.log")" "PATCH https://api.github.com/repos/HarperFast/ai-review-log/issues/42" "superseded run cannot overwrite a current issue title"
assert_contains "$(<"$TMP/curl.log")" "POST https://api.github.com/repos/HarperFast/ai-review-log/issues/42/comments" "existing issue lookup covers later API pages"

run_logger abc failure
assert_status "$?" 0 "failed review skip remains best-effort"
if [ -e "$TMP/payload.json" ]; then t_bad "failed review is not logged as a verdict"; else t_ok "failed review is not logged as a verdict"; fi

t_summary
