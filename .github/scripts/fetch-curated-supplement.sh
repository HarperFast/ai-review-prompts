#!/usr/bin/env bash
# Fetch the curated calibration issue for a week, including every comment.
# Usage: fetch-curated-supplement.sh <label> <week-yyyy-mm-dd> <output-file>
# Best-effort: issue-list failure produces []; per-issue comment failure
# produces comments:[] and a workflow warning. All REST pages are flattened.
set -uo pipefail

LABEL="${1:-}"
WEEK="${2:-}"
OUTPUT_FILE="${3:-}"
if [ -z "$LABEL" ] || [ -z "$WEEK" ] || [ -z "$OUTPUT_FILE" ]; then
	echo "::error::usage: fetch-curated-supplement.sh <label> <week-yyyy-mm-dd> <output-file>"
	exit 2
fi

if ! RAW_ISSUES=$(gh api --paginate \
	"repos/HarperFast/ai-review-log/issues?state=all&labels=$LABEL&per_page=100"); then
	echo '[]' > "$OUTPUT_FILE"
	echo "::warning::Curated '$LABEL' issue fetch failed; continuing without it"
	exit 0
fi

if ! ISSUES=$(printf '%s\n' "$RAW_ISSUES" | jq -sce --arg week "$WEEK" '
  [.[][]
   | select(.title | contains($week))
   | {number, title, body, labels: [.labels[]?.name]}]
'); then
	echo '[]' > "$OUTPUT_FILE"
	echo "::warning::Curated '$LABEL' issue response was malformed; continuing without it"
	exit 0
fi

RESULT_ITEMS=()
while IFS= read -r ISSUE; do
	NUMBER=$(printf '%s' "$ISSUE" | jq -r '.number')
	if RAW_COMMENTS=$(gh api --paginate \
		"repos/HarperFast/ai-review-log/issues/$NUMBER/comments?per_page=100"); then
		if ! COMMENTS=$(printf '%s\n' "$RAW_COMMENTS" | jq -sce '
      [.[][] | {
        id,
        user: .user.login,
        authorAssociation: .author_association,
        createdAt: .created_at,
        updatedAt: .updated_at,
        body
      }]
    '); then
			COMMENTS='[]'
			echo "::warning::Comments response was malformed for ai-review-log#$NUMBER"
		fi
	else
		COMMENTS='[]'
		echo "::warning::Comments fetch failed for ai-review-log#$NUMBER"
	fi
	if ! ENRICHED=$(printf '%s\n%s\n' "$ISSUE" "$COMMENTS" | jq -sc '.[0] + {comments: .[1]}'); then
		echo "::warning::Could not enrich ai-review-log#$NUMBER; retaining the issue with empty comment evidence"
		ENRICHED=$(printf '%s' "$ISSUE" | jq -c '. + {comments: []}')
	fi
	RESULT_ITEMS+=("$ENRICHED")
done < <(printf '%s' "$ISSUES" | jq -c '.[]')

if [ "${#RESULT_ITEMS[@]}" -eq 0 ]; then
	printf '%s\n' '[]' > "$OUTPUT_FILE"
else
	printf '%s\n' "${RESULT_ITEMS[@]}" | jq -s '.' > "$OUTPUT_FILE"
fi
