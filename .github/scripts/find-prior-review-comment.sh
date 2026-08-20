#!/usr/bin/env bash
# Find a prior marker'd review surface on a PR (if any) and write
# its integer database ID to $GITHUB_OUTPUT under key `id`. Empty
# when no prior exists.
#
# Provider-agnostic. Callers pass:
#
# - MARKER — the sentinel the body starts with (e.g.
#   `<!-- claude-review:v1 -->` for `_claude-review.yml`,
#   `<!-- gemini-review:v1 -->` for `_gemini-review.yml`).
#
# - LOOKUP_API_PATH — optional. The GitHub API path to query.
#   Two shapes are in use:
#
#     a) `repos/<owner>/<repo>/issues/<N>/comments` — top-level
#        issue comments. Both shared review workflows use one
#        provider-specific comment per PR and edit it across runs.
#        DEFAULT when LOOKUP_API_PATH is unset.
#
#     b) `repos/<owner>/<repo>/pulls/<N>/reviews` — pull request
#        reviews submitted by a custom caller via the GitHub Review
#        API. We return the most recent matching review's id.
#
# Both endpoints return JSON arrays of objects with `body` and
# `id` fields, so the same `select(.body | startswith(marker))` +
# `| last | .id` jq pipeline works for either.
#
# Marker collision risk (a manually-posted comment or review
# starting with the sentinel) is vanishingly small and self-healing
# (next reviewer run posts/edits accordingly).
#
# Inputs:
#   MARKER               — required. Body prefix to match,
#                          e.g. `<!-- claude-review:v1 -->`.
#   LOOKUP_API_PATH      — optional. API path to query for the
#                          provider's surface. Default
#                          `repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments`
#                          (legacy claude top-level-comment path).
#   GH_TOKEN             — token with `pull-requests: read`
#   GITHUB_REPOSITORY    — owner/repo (auto-set by GitHub Actions)
#   PR_NUMBER            — pull request number
#   GITHUB_OUTPUT        — output file path
set -uo pipefail

if [ -z "${MARKER:-}" ]; then
  echo "::error::MARKER env var is required (e.g. '<!-- claude-review:v1 -->')."
  exit 1
fi

API_PATH="${LOOKUP_API_PATH:-repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments}"
if [[ "$API_PATH" == *\?* ]]; then
  API_URL="${API_PATH}&per_page=100"
else
  API_URL="${API_PATH}?per_page=100"
fi

EXISTING_ID=$(gh api --paginate "$API_URL" \
  | jq -sr --arg marker "$MARKER" \
    '[.[][] | select(.body // "" | startswith($marker))] | last | .id // empty')

if [ -n "$EXISTING_ID" ]; then
  echo "Prior review surface ($MARKER) found at $API_PATH: id=$EXISTING_ID"
else
  echo "No prior review surface ($MARKER) found at $API_PATH — agent will post fresh."
fi
echo "id=${EXISTING_ID}" >> "$GITHUB_OUTPUT"
