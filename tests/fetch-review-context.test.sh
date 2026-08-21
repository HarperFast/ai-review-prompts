#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/../.github/scripts/fetch-review-context.sh"
source "$DIR/lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "${STUB_MODE:-complete}" in
	failure) exit 1 ;;
	malformed) printf '%s\n' 'not-json' ;;
	truncated)
		printf '%s\n' '[{"data":{"repository":{"pullRequest":{"number":7,"title":"T","url":"https://example/pr/7","baseRefOid":"base","headRefOid":"head","reviewThreads":{"nodes":[{"id":"t1","isResolved":true,"isOutdated":false,"path":"a.ts","line":3,"comments":{"totalCount":101,"nodes":[{"id":"c1","body":"resolved","authorAssociation":"MEMBER","author":{"login":"maintainer"}}],"pageInfo":{"hasNextPage":true,"endCursor":"c"}}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}]'
		;;
	*)
		printf '%s\n' '[{"data":{"repository":{"pullRequest":{"number":7,"title":"T","url":"https://example/pr/7","baseRefOid":"base","headRefOid":"head","reviewThreads":{"nodes":[{"id":"t1","isResolved":false,"isOutdated":false,"path":"a.ts","line":3,"comments":{"totalCount":1,"nodes":[{"id":"c1","body":"finding","authorAssociation":"CONTRIBUTOR","author":{"login":"reviewer"}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}],"pageInfo":{"hasNextPage":true,"endCursor":"p1"}}}}}},{"data":{"repository":{"pullRequest":{"number":7,"title":"T","url":"https://example/pr/7","baseRefOid":"base","headRefOid":"head","reviewThreads":{"nodes":[{"id":"t2","isResolved":true,"isOutdated":false,"path":"b.ts","line":9,"comments":{"totalCount":1,"nodes":[{"id":"c2","body":"fixed","authorAssociation":"MEMBER","author":{"login":"maintainer"}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}]'
		;;
esac
STUB
chmod +x "$TMP/bin/gh"

cat > "$TMP/bin/timeout" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" > "$STUB_TIMEOUT_CAPTURE"
shift
exec "$@"
STUB
chmod +x "$TMP/bin/timeout"

run_fetch() {
	STUB_MODE="$1" STUB_TIMEOUT_CAPTURE="$TMP/timeout" PATH="$TMP/bin:$PATH" GITHUB_REPOSITORY=HarperFast/harper PR_NUMBER=7 \
		bash "$SCRIPT" "$TMP/context.json" >/dev/null
}

run_fetch complete
assert_eq "$(jq -r '.status' "$TMP/context.json")" "complete" "complete multi-page snapshot"
assert_eq "$(<"$TMP/timeout")" "45" "GraphQL request uses the default API deadline"
assert_eq "$(jq '.threads | length' "$TMP/context.json")" "2" "top-level thread pages are flattened"
assert_eq "$(jq -r '.threads[1].comments.nodes[0].authorAssociation' "$TMP/context.json")" "MEMBER" "author association is preserved"

STUB_TIMEOUT_CAPTURE="$TMP/timeout" PATH="$TMP/bin:$PATH" GITHUB_REPOSITORY='' PR_NUMBER='' \
	bash "$SCRIPT" "$TMP/context.json" 7 HarperFast/harper >/dev/null
assert_eq "$(jq -r '.repository' "$TMP/context.json")" "HarperFast/harper" "explicit args support in-review refresh"

run_fetch truncated
assert_eq "$(jq -r '.status' "$TMP/context.json")" "partial" "nested comment truncation marks snapshot partial"
assert_eq "$(jq -r '.threads[0].commentsTruncated' "$TMP/context.json")" "true" "truncated thread is explicit"
assert_contains "$(jq -r '.warnings[]' "$TMP/context.json")" "100-comment" "truncation warning explains the cap"

run_fetch failure
assert_eq "$(jq -r '.status' "$TMP/context.json")" "partial" "failed refresh preserves the previous usable snapshot"

rm -f "$TMP/context.json"
run_fetch failure
assert_eq "$(jq -r '.status' "$TMP/context.json")" "unavailable" "GraphQL failure degrades without failing review"
assert_eq "$(jq '.threads | length' "$TMP/context.json")" "0" "unavailable snapshot has no invented threads"
assert_eq "$(jq -r '.pullRequest.number | type' "$TMP/context.json")" "number" "unavailable snapshot keeps PR number type stable"

run_fetch malformed
assert_eq "$(jq -r '.status' "$TMP/context.json")" "unavailable" "malformed response degrades without failing review"

t_summary
