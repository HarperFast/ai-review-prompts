#!/usr/bin/env bash
# Post (or edit) a marker'd review comment on a PR. Driven by
# _gemini-review.yml's "Post Gemini review comment" step.
#
# Why this script exists: google-github-actions/run-gemini-cli
# runs the Gemini CLI in `--prompt … --output-format json` mode,
# which is single-shot text completion — the agent CAN'T call
# `gh pr comment` or `gh api` on its own. Claude's reviewer uses
# claude-code-action's agentic loop and posts directly; Gemini has
# no such surface in this mode, so the workflow posts on the
# agent's behalf. The agent's only contract is "produce the review
# text starting with the marker line". This script validates that
# contract and does the posting.
#
# Inputs:
#   MARKER                     — required. Sentinel the response
#                                MUST start with (e.g.
#                                `<!-- gemini-review:v1 -->`).
#                                Defense against posting mystery
#                                content if the model deviates.
#   RUN_MARKER                 — required. Exact second-line marker
#                                binding the body to run id, attempt,
#                                and reviewed head.
#   BODY                       — required. Agent's response text
#                                (typically captured from the
#                                action's `gemini_response` step
#                                output).
#   PRIOR_REVIEW_COMMENT_ID    — optional. Integer DB id of a
#                                prior marker'd comment to edit.
#                                Empty / unset means "post fresh".
#   GH_TOKEN                   — token with `pull-requests: write`
#   GITHUB_REPOSITORY          — owner/repo (auto-set by Actions)
#   PR_NUMBER                  — pull request number
set -uo pipefail

if [ -z "${MARKER:-}" ]; then
  echo "::error::MARKER env var is required."
  exit 1
fi
if [ -z "${RUN_MARKER:-}" ]; then
  echo "::error::RUN_MARKER env var is required."
  exit 1
fi
if [ -z "${BODY:-}" ]; then
  echo "::notice::No agent response — skipping post."
  exit 0
fi

# Trim leading blank lines AND leading whitespace on the first
# non-blank line before checking the marker. The Gemini CLI's
# JSON-mode response is whitespace-stable on the leading edge in
# practice, but if any provider ever indents the first line the
# marker check would refuse to post a perfectly valid review.
TRIMMED=$(printf '%s' "$BODY" \
  | sed -e '1,/[^[:space:]]/{/^[[:space:]]*$/d;}' \
  | sed -e '1s/^[[:space:]]*//')

FIRST_LINE=$(printf '%s' "$TRIMMED" | head -1)
SECOND_LINE=$(printf '%s' "$TRIMMED" | sed -n '2p')
if [ "$FIRST_LINE" != "$MARKER" ]; then
    echo "::warning::Agent response did not start with marker ('$MARKER'); refusing to post mystery content. First line was:"
    printf '  %s\n' "$FIRST_LINE"
    exit 0
fi
if [ "$SECOND_LINE" != "$RUN_MARKER" ]; then
  echo "::warning::Agent response did not carry this run's binding marker on line 2; refusing to post unbound content."
  exit 0
fi

# Use --body-file / -F body=@<file> to dodge shell-arg-length
# limits for large reviews.
TMPF=$(mktemp)
trap 'rm -f "$TMPF"' EXIT
printf '%s\n' "$TRIMMED" > "$TMPF"

if [ -n "${PRIOR_REVIEW_COMMENT_ID:-}" ]; then
  echo "Editing prior review comment #${PRIOR_REVIEW_COMMENT_ID}"
  gh api -X PATCH \
    "repos/${GITHUB_REPOSITORY}/issues/comments/${PRIOR_REVIEW_COMMENT_ID}" \
    -F "body=@${TMPF}"
else
  echo "Posting fresh review comment on PR #${PR_NUMBER}"
  gh pr comment "${PR_NUMBER}" --repo "${GITHUB_REPOSITORY}" --body-file "${TMPF}"
fi
