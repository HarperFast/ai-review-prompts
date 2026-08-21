#!/usr/bin/env bash
# Fetch a deterministic snapshot of a pull request's inline review threads.
#
# Usage: fetch-review-context.sh <output-file> [pr-number] [owner/repo]
#
# Required environment:
#   GH_TOKEN           Token with pull-request read access.
#   GITHUB_REPOSITORY  owner/repo.
#   PR_NUMBER          Pull request number.
#
# The top-level reviewThreads connection is fully paginated by gh. Thread
# comments are capped at 100; the snapshot is marked partial, and each
# affected thread carries commentsTruncated=true, if that cap is exceeded.
# On runners with GNU timeout, the API call is bounded to 45 seconds by
# default (override with REVIEW_CONTEXT_TIMEOUT_SECONDS). API, timeout, and
# parse failures degrade to a status=unavailable snapshot and exit 0.
set -uo pipefail

OUTPUT_FILE="${1:-}"
if [ -z "$OUTPUT_FILE" ]; then
	echo "::error::usage: fetch-review-context.sh <output-file>"
	exit 2
fi

write_unavailable() {
	local reason="$1"
	if [ -f "$OUTPUT_FILE" ] && jq -e '
		.schema == "ai-review-context/v1"
		and (.status == "complete" or .status == "partial")
	' "$OUTPUT_FILE" >/dev/null 2>&1; then
		echo "::warning::Review-thread context refresh failed; retaining the previous usable snapshot: $reason"
		return
	fi
	jq -n \
		--arg fetched_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--arg repository "${GITHUB_REPOSITORY:-unknown}" \
		--arg pr_number "${PR_NUMBER:-unknown}" \
		--arg reason "$reason" \
		'{schema:"ai-review-context/v1", status:"unavailable", fetchedAt:$fetched_at, repository:$repository, pullRequest:{number:(if ($pr_number | test("^[0-9]+$")) then ($pr_number | tonumber) else null end)}, threads:[], warnings:[$reason]}' \
		> "$OUTPUT_FILE"
	echo "::warning::Review-thread context unavailable: $reason"
}

PR_NUMBER="${2:-${PR_NUMBER:-}}"
GITHUB_REPOSITORY="${3:-${GITHUB_REPOSITORY:-}}"

if [ -z "${GITHUB_REPOSITORY:-}" ] || [[ "$GITHUB_REPOSITORY" != */* ]] || [ -z "${PR_NUMBER:-}" ]; then
	write_unavailable "missing GITHUB_REPOSITORY or PR_NUMBER"
	exit 0
fi

OWNER="${GITHUB_REPOSITORY%%/*}"
NAME="${GITHUB_REPOSITORY#*/}"
QUERY='
query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      number
      title
      url
      baseRefOid
      headRefOid
      reviewThreads(first: 100, after: $endCursor) {
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          originalLine
          diffSide
          comments(first: 100) {
            totalCount
            nodes {
              id
              url
              body
              path
              line
              originalLine
              createdAt
              updatedAt
              authorAssociation
              author { login }
            }
          }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}'

GH_COMMAND=(gh api graphql --paginate --slurp \
	-f query="$QUERY" \
	-F owner="$OWNER" \
	-F name="$NAME" \
	-F number="$PR_NUMBER")
if command -v timeout >/dev/null 2>&1; then
	GH_COMMAND=(timeout "${REVIEW_CONTEXT_TIMEOUT_SECONDS:-45}" "${GH_COMMAND[@]}")
fi
if ! RAW=$("${GH_COMMAND[@]}"); then
	write_unavailable "GraphQL request failed"
	exit 0
fi

if ! SNAPSHOT=$(printf '%s\n' "$RAW" | jq -ce \
	--arg fetched_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	--arg repository "$GITHUB_REPOSITORY" '
    if type != "array" or length == 0 then error("no GraphQL pages") else . end
    | ([.[].data.repository.pullRequest | select(. != null)]) as $prs
    | if ($prs | length) == 0 then error("pull request missing from GraphQL response") else . end
    | ([.[].errors[]?.message] | unique) as $graphql_errors
    | ([ $prs[].reviewThreads.nodes[]? ]
       | map(. + {
           commentsTruncated: (
             (.comments.totalCount // 0) > ((.comments.nodes // []) | length)
           )
         })) as $threads
    | ([$threads[] | select(.commentsTruncated)] | length) as $truncated_count
    | {
        schema: "ai-review-context/v1",
        status: (if ($graphql_errors | length) > 0 or $truncated_count > 0 then "partial" else "complete" end),
        fetchedAt: $fetched_at,
        repository: $repository,
        pullRequest: {
          number: $prs[0].number,
          title: $prs[0].title,
          url: $prs[0].url,
          baseRefOid: $prs[0].baseRefOid,
          headRefOid: $prs[0].headRefOid
        },
        threads: $threads,
        warnings: (
          $graphql_errors
          + if $truncated_count > 0
            then ["\($truncated_count) thread(s) exceed the 100-comment snapshot cap; do not infer dismissal from truncated threads"]
            else []
            end
        )
      }' 2>/dev/null); then
	write_unavailable "GraphQL response was malformed"
	exit 0
fi

printf '%s\n' "$SNAPSHOT" > "$OUTPUT_FILE"
echo "Review-thread context: $(jq -r '.status' "$OUTPUT_FILE"), $(jq '.threads | length' "$OUTPUT_FILE") thread(s)"
