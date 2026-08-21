#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/../.github/scripts/fetch-curated-supplement.sh"
source "$DIR/lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
URL="${*: -1}"
if [ "${STUB_MODE:-complete}" = "issue-failure" ] && [[ "$URL" == *"issues?"* ]]; then
	exit 1
fi
if [[ "$URL" == *"/comments?"* ]]; then
	if [ "${STUB_MODE:-complete}" = "comment-failure" ]; then exit 1; fi
	if [ "${STUB_MODE:-complete}" = "large-comments" ] && [[ "$URL" == *"/100/comments?"* ]]; then
		printf '%s' '[{"id":13,"user":null,"author_association":"NONE","created_at":"2026-08-20T00:00:00Z","updated_at":"2026-08-20T00:00:00Z","body":"'
		printf '%150000s' '' | tr ' ' x
		printf '%s\n' '"}]'
		exit 0
	fi
	if [[ "$URL" == *"/100/comments?"* ]]; then
		printf '%s\n' '[{"id":13,"user":null,"author_association":"NONE","created_at":"2026-08-20T00:00:00Z","updated_at":"2026-08-20T00:00:00Z","body":"ghost-user evidence"}]'
	else
		printf '%s\n' '[{"id":11,"user":{"login":"grader"},"author_association":"MEMBER","created_at":"2026-08-18T00:00:00Z","updated_at":"2026-08-18T01:00:00Z","body":"confirmed miss"}]' '[{"id":12,"user":{"login":"author"},"author_association":"CONTRIBUTOR","created_at":"2026-08-19T00:00:00Z","updated_at":"2026-08-19T00:00:00Z","body":"fixed in abc"}]'
	fi
else
	if [ "${STUB_MODE:-complete}" = "zero-matches" ]; then
		printf '%s\n' '[{"number":98,"title":"False negatives 2026-08-10","body":"older","labels":[{"name":"false-negatives"}]}]'
		exit 0
	fi
	if [ "${STUB_MODE:-complete}" = "malformed-issues" ]; then
		printf '%s\n' 'not-json'
		exit 0
	fi
	printf '%s\n' '[{"number":99,"title":"False negatives 2026-08-17","body":"boilerplate","labels":[{"name":"false-negatives"}]},{"number":100,"title":"False negatives follow-up 2026-08-17","body":"more evidence","labels":[{"name":"false-negatives"}]}]'
fi
STUB
chmod +x "$TMP/bin/gh"

run_fetch() {
	STUB_MODE="$1" PATH="$TMP/bin:$PATH" bash "$SCRIPT" false-negatives 2026-08-17 "$TMP/supplement.json" >/dev/null
	RUN_STATUS=$?
}

run_fetch complete
assert_status "$RUN_STATUS" 0 "complete fetch exits successfully"
assert_eq "$(jq 'length' "$TMP/supplement.json")" "2" "all matching curated issues are retained"
assert_eq "$(jq '.[0].comments | length' "$TMP/supplement.json")" "2" "all comment pages are flattened"
assert_eq "$(jq -r '.[0].comments[0].body' "$TMP/supplement.json")" "confirmed miss" "comment evidence is included"
assert_eq "$(jq -r '.[0].comments[0].authorAssociation' "$TMP/supplement.json")" "MEMBER" "comment authority metadata is included"
assert_eq "$(jq -r '.[1].comments[0].user | type' "$TMP/supplement.json")" "null" "deleted comment authors do not break enrichment"

run_fetch large-comments
assert_status "$RUN_STATUS" 0 "large comment evidence exits successfully"
assert_eq "$(jq '.[1].comments[0].body | length' "$TMP/supplement.json")" "150000" "large comment evidence is not lost through an argv limit"

run_fetch comment-failure
assert_status "$RUN_STATUS" 0 "comment failure remains best-effort"
assert_eq "$(jq '.[0].comments | length' "$TMP/supplement.json")" "0" "comment failure is explicit empty evidence"

run_fetch issue-failure
assert_status "$RUN_STATUS" 0 "issue-list failure remains best-effort"
assert_eq "$(jq 'length' "$TMP/supplement.json")" "0" "issue-list failure degrades to an empty supplement"

run_fetch zero-matches
assert_status "$RUN_STATUS" 0 "zero-match week exits successfully"
assert_eq "$(jq 'length' "$TMP/supplement.json")" "0" "zero-match week writes an empty supplement"

run_fetch malformed-issues
assert_status "$RUN_STATUS" 0 "malformed issue response remains best-effort"
assert_eq "$(jq 'length' "$TMP/supplement.json")" "0" "malformed issue response writes an empty supplement"

t_summary
