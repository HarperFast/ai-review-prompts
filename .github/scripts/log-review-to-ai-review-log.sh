#!/usr/bin/env bash
# Log this run's PR review to the central HarperFast/ai-review-log
# tracker — finds the per-PR issue by stable title prefix and
# appends a comment, or creates a new issue if none exists. Driven
# by the "Log review to ai-review-log" step in _claude-review.yml
# and _gemini-review.yml.
#
# Provider-agnostic: callers pass MARKER (sentinel that discriminates
# the review comment), MODEL (for the body header), and optionally
# PROVIDER_LABEL (selects the per-provider title format and label —
# empty preserves the legacy Claude-only format, non-empty creates
# one issue per (PR, provider) so each reviewer's verdict and cost
# stays unambiguous) and NOTES_FILE_BASENAME (the agent's run-notes
# filename under $RUNNER_TEMP).
#
# When PROVIDER_LABEL is set:
#   * Title shape: `[<repo>] PR #<N> (<provider>): <count>`. Disjoint
#     prefix from the legacy `[<repo>] PR #<N>:` shape — lookups
#     scope cleanly to each provider's own issues.
#   * `provider:<label>` is added to the issue's labels on creation,
#     making sweep queries like
#     `label:repo:harper label:provider:gemini label:verdict:noise`
#     trivial.
#   * Body header includes a **Peers:** field linking to a GitHub
#     issue search that finds every provider's issue for the same
#     PR — cross-reference without needing run-time lookups.
#
# When PROVIDER_LABEL is empty (default — Claude's caller):
#   * Title shape stays `[<repo>] PR #<N>: <count>` (unchanged from
#     pre-Gemini history; no migration of existing issues).
#   * No `provider:` label, no **Peers:** field.
#
# Best-effort: never fails the job. A missing AI_REVIEW_LOG_TOKEN
# secret, an absent marker'd review comment, or a stale comment
# all exit cleanly with a notice/warning rather than failing.
#
# Inputs:
#   MARKER                — required. Body prefix to match
#                           (e.g. `<!-- claude-review:v1 -->`).
#   MODEL                 — required. Model id for the body header
#                           (e.g. "claude-sonnet-4-6", "gemini-2.5-pro").
#   PROVIDER_LABEL        — optional. When non-empty, prefixed to
#                           the title's count part (e.g. "gemini").
#                           Empty preserves the legacy Claude title
#                           format.
#   NOTES_FILE_BASENAME   — optional. Run-notes filename under
#                           $RUNNER_TEMP. Defaults to
#                           "claude-review-notes.md".
#   LOOKUP_API_PATH       — optional. The GitHub API path to query
#                           for the provider's review surface.
#                           Default:
#                           `repos/<owner>/<repo>/issues/<N>/comments`
#                           (top-level issue comments — the Claude
#                           legacy path). Set to
#                           `repos/<owner>/<repo>/pulls/<N>/reviews`
#                           for the Gemini reviewer, which submits
#                           via the GitHub Review API rather than
#                           posting a top-level issue comment. Both
#                           endpoints return JSON arrays with
#                           `body` / `updated_at` / `created_at`,
#                           so the marker-startswith filter works
#                           uniformly.
#   GH_TOKEN              — token with `pull-requests: read`
#   AI_REVIEW_LOG_TOKEN   — fine-grained PAT scoped to
#                           ai-review-log with `issues: write`
#                           (optional — missing skips logging
#                           with a warning)
#   PR_NUMBER             — pull request number
#   PR_URL                — html URL of the PR
#   REVIEW_STATUS         — outcome of the review step
#                           (success / failure / cancelled / etc.)
#   REPO_SHORT            — short repo name (e.g. "harper")
#   GITHUB_REPOSITORY     — owner/repo of the PR's repo
#   GITHUB_RUN_ID         — current Actions run ID (for staleness
#                           guard)
#   RUNNER_TEMP           — runner temp dir (where the agent's
#                           optional run-notes file lives)
set -uo pipefail

if [ -z "${MARKER:-}" ]; then
  echo "::error::MARKER env var is required (e.g. '<!-- claude-review:v1 -->')."
  exit 1
fi
if [ -z "${MODEL:-}" ]; then
  echo "::error::MODEL env var is required (e.g. 'claude-sonnet-4-6')."
  exit 1
fi

PROVIDER_LABEL="${PROVIDER_LABEL:-}"
NOTES_FILE_BASENAME="${NOTES_FILE_BASENAME:-claude-review-notes.md}"

if [ -z "${AI_REVIEW_LOG_TOKEN:-}" ]; then
  echo "::warning::AI_REVIEW_LOG_TOKEN secret not set; skipping log entry."
  exit 0
fi

# When this workflow job started. Used to filter out stale review
# comments from previous runs so a cancelled in-flight run (e.g.
# from a force-push) doesn't re-log a prior run's content as a
# fresh finding.
JOB_STARTED=$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}" --jq '.run_started_at // empty')

# Fetch the marker'd review surface via raw API. Two endpoints
# are in use depending on the provider:
#   * Default (Claude legacy): top-level issue comments
#     (`/issues/<N>/comments`)
#   * Gemini reviewer (MCP-based): pull request reviews
#     (`/pulls/<N>/reviews`)
# Both return JSON arrays with `body` / `updated_at` / `created_at`,
# so the marker-startswith filter is uniform. We can't use
# `gh pr view --json comments` because it doesn't expose
# `updated_at` (which we need below for the staleness guard).
LOOKUP_API_PATH="${LOOKUP_API_PATH:-repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments}"
REVIEW_JSON=$(gh api "$LOOKUP_API_PATH" \
  | jq --arg marker "$MARKER" \
    '[.[] | select((.body // "") | startswith($marker))] | last // empty')

if [ -z "$REVIEW_JSON" ] || [ "$REVIEW_JSON" = "null" ]; then
  echo "No marker'd review surface ($MARKER) found at $LOOKUP_API_PATH (review_status=$REVIEW_STATUS); skipping log."
  exit 0
fi

REVIEW_BODY=$(printf '%s' "$REVIEW_JSON" | jq -r '.body // empty')
# Prefer updated_at (top-level comments — reflects the most
# recent edit) > submitted_at (PR reviews — set when the agent
# calls submit_pending_pull_request_review) > created_at (issue-
# comments fallback). Both endpoints' shapes are covered.
REVIEW_AT=$(printf '%s' "$REVIEW_JSON" | jq -r '.updated_at // .submitted_at // .created_at // empty')

if [ -z "$REVIEW_BODY" ]; then
  echo "Review comment had empty body; skipping log."
  exit 0
fi

# No-log marker: the review prompt tags a pass on a wholly-mechanical /
# no-reviewable-code diff (version/CI/pin/submodule/scaffold/dead-code) with
# `<!-- review:no-log -->`. Those carry no calibration signal, so don't create a
# triage-only log entry for them. (A real review never emits the marker, so its
# clean verdict is still logged.)
if printf '%s' "$REVIEW_BODY" | grep -qF '<!-- review:no-log -->'; then
  echo "::notice::Review carries the no-log marker (mechanical / no-reviewable-code diff); skipping log entry."
  exit 0
fi

# ISO-8601 lexicographic compare — both are UTC timestamps in the
# same shape, so string comparison is sound.
if [ -n "$JOB_STARTED" ] && [ -n "$REVIEW_AT" ] && [ "$REVIEW_AT" \< "$JOB_STARTED" ]; then
  echo "::notice::Latest review comment update ($REVIEW_AT) predates this job's start ($JOB_STARTED); skipping to avoid re-logging stale content."
  exit 0
fi

# Title: extract the count from the standardized first-content line
# both reviewers' prompts emit:
#   "N blockers found."      / "1 blocker found."   -> N
#   "Reviewed; no blockers found."                  -> 0
# This holds even when a reviewer puts the substantive findings in
# inline review comments and uses the top-level body as a terse
# recap (Claude's evolved pattern on oauth#89) — the count line is
# present regardless of where the substance lives.
#
# Fall back to counting `^### [0-9]\.` headers when the count line
# isn't present (older formats / future deviations). Earlier
# iterations (#88, #89, #104) relied SOLELY on prose-grep and fell
# through to "0 finding(s) — triage pending" when phrasing varied —
# the fallback to header counting is what prevents that regression
# now.
COUNT_LINE=$(printf '%s\n' "$REVIEW_BODY" \
  | grep -v -E '^([[:space:]]*$|<!--)' \
  | head -1)

# Tolerate optional markdown wrapping on the count line. LLMs
# occasionally bold or italicize first-sentence summaries
# ("**2 blockers found.**", "_1 blocker found._"); without the
# allowance, those would skip the count-line branch and fall
# through to header counting (which returns 0 on Claude's recap
# format). `[[:space:]*_]*` matches any combination of leading
# whitespace, asterisks, and underscores. The no-blockers branch
# is already substring-matched, so it tolerates wrapping
# implicitly.
if echo "$COUNT_LINE" | grep -qiE 'no blockers? found'; then
  FINDING_COUNT=0
elif echo "$COUNT_LINE" | grep -qE '^[[:space:]*_]*[0-9]+ blockers? found'; then
  FINDING_COUNT=$(echo "$COUNT_LINE" | grep -oE '[0-9]+' | head -1)
else
  FINDING_COUNT=$(printf '%s\n' "$REVIEW_BODY" | grep -c '^### [0-9]' || true)
fi

if [ "$FINDING_COUNT" = "0" ]; then
  COUNT_PART="no blockers"
else
  COUNT_PART="${FINDING_COUNT} finding(s) — triage pending"
fi

# Title prefix and shape branch on PROVIDER_LABEL. Empty
# (legacy Claude) keeps the original format; non-empty inserts
# `(<provider>)` before the colon, giving each provider its own
# disjoint title-prefix namespace so lookups don't cross-match.
if [ -n "$PROVIDER_LABEL" ]; then
  TITLE_PREFIX="[$REPO_SHORT] PR #$PR_NUMBER ($PROVIDER_LABEL):"
else
  TITLE_PREFIX="[$REPO_SHORT] PR #$PR_NUMBER:"
fi

if [ "$REVIEW_STATUS" = "success" ]; then
  TITLE="$TITLE_PREFIX $COUNT_PART"
else
  TITLE="$TITLE_PREFIX $COUNT_PART (review $REVIEW_STATUS — may be incomplete)"
fi

# Run URL — one click to the action run page where usage / cost
# data is shown (token counts, estimated $). Useful for both
# providers; included unconditionally.
RUN_URL="https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

# Peers link — only included when PROVIDER_LABEL is set, since
# legacy Claude-only flows don't have peer issues to point at.
# This URL is a GitHub issue-search prefiltered to the same
# `[<repo>] PR #<N>` token, so each provider's issue can link
# back to the search that finds all of them.
if [ -n "$PROVIDER_LABEL" ]; then
  PEERS_QUERY=$(printf '%s' "[$REPO_SHORT] PR #$PR_NUMBER" | jq -sRr @uri)
  PEERS_URL="https://github.com/HarperFast/ai-review-log/issues?q=is%3Aissue+${PEERS_QUERY}"
  BODY=$(printf '**Source:** %s\n**Repo:** %s\n**PR:** #%s\n**Provider:** %s\n**Model:** %s\n**Run:** %s\n**Peers:** %s\n**Phase:** baseline\n**Review job status:** %s\n**Date:** %s\n\n---\n\n%s\n' \
    "$PR_URL" "$REPO_SHORT" "$PR_NUMBER" "$PROVIDER_LABEL" "$MODEL" "$RUN_URL" "$PEERS_URL" "$REVIEW_STATUS" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REVIEW_BODY")
else
  BODY=$(printf '**Source:** %s\n**Repo:** %s\n**PR:** #%s\n**Model:** %s\n**Run:** %s\n**Phase:** baseline\n**Review job status:** %s\n**Date:** %s\n\n---\n\n%s\n' \
    "$PR_URL" "$REPO_SHORT" "$PR_NUMBER" "$MODEL" "$RUN_URL" "$REVIEW_STATUS" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REVIEW_BODY")
fi

# Structured run notes from the agent (optional). This is the
# channel that keeps verbose context off the PR — the agent writes
# to a fixed path under $RUNNER_TEMP, and we append here so the log
# issue gets the full picture while the PR comment stays concise.
# Absent file is fine; means the run had nothing structured to
# capture.
NOTES_FILE="${RUNNER_TEMP:-/tmp}/${NOTES_FILE_BASENAME}"
if [ -f "$NOTES_FILE" ]; then
  NOTES_CONTENT=$(cat "$NOTES_FILE")
  BODY=$(printf '%s\n\n---\n\n%s\n' "$BODY" "$NOTES_CONTENT")
  echo "Appended $(wc -c < "$NOTES_FILE") bytes of run notes from $NOTES_FILE"
else
  echo "No run notes file at $NOTES_FILE — skipping notes append"
fi

# One ai-review-log issue per (PR, provider). The TITLE_PREFIX
# constructed above is provider-scoped when PROVIDER_LABEL is set
# — each provider's lookup hits only its own issues. List API
# (not search) is used because search is eventually-consistent —
# a same-day second review run might fire before the first issue
# is indexed.
EXISTING_NUMBER=$(curl -sS \
  -H "Authorization: Bearer $AI_REVIEW_LOG_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/HarperFast/ai-review-log/issues?labels=repo:$REPO_SHORT&state=all&per_page=100&sort=created&direction=desc" \
  | jq -r --arg prefix "$TITLE_PREFIX" \
    '[.[] | select(.title | startswith($prefix))] | first | .number // empty')

if [ -n "$EXISTING_NUMBER" ] && [ "$EXISTING_NUMBER" != "null" ]; then
  # Existing issue: append a comment, refresh the title to reflect
  # this run's status. Title refresh is best-effort — we still
  # report success on the comment alone.
  COMMENT_PAYLOAD=$(jq -nc --arg body "$BODY" '{body: $body}')
  HTTP_C=$(curl -sS -o /tmp/ai-log-comment-resp.json -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $AI_REVIEW_LOG_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/HarperFast/ai-review-log/issues/$EXISTING_NUMBER/comments" \
    -d "$COMMENT_PAYLOAD")

  PATCH_PAYLOAD=$(jq -nc --arg title "$TITLE" '{title: $title}')
  HTTP_T=$(curl -sS -o /tmp/ai-log-patch-resp.json -w '%{http_code}' -X PATCH \
    -H "Authorization: Bearer $AI_REVIEW_LOG_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/HarperFast/ai-review-log/issues/$EXISTING_NUMBER" \
    -d "$PATCH_PAYLOAD")

  if [ "$HTTP_C" -ge 200 ] && [ "$HTTP_C" -lt 300 ]; then
    COMMENT_URL=$(jq -r '.html_url' /tmp/ai-log-comment-resp.json)
    echo "Logged review as comment on existing issue: $COMMENT_URL"
  else
    echo "::warning::ai-review-log comment POST failed (HTTP $HTTP_C):"
    cat /tmp/ai-log-comment-resp.json
  fi

  if [ "$HTTP_T" -lt 200 ] || [ "$HTTP_T" -ge 300 ]; then
    echo "::warning::ai-review-log title PATCH failed (HTTP $HTTP_T):"
    cat /tmp/ai-log-patch-resp.json
  fi
else
  # No existing issue for this (PR, provider) — create one.
  # `provider:<label>` is added alongside the existing labels when
  # PROVIDER_LABEL is set; this is what makes sweep queries like
  # `label:provider:gemini label:verdict:noise` work.
  if [ -n "$PROVIDER_LABEL" ]; then
    CREATE_PAYLOAD=$(jq -nc \
      --arg title "$TITLE" \
      --arg repo_label "repo:$REPO_SHORT" \
      --arg provider_label "provider:$PROVIDER_LABEL" \
      --arg body "$BODY" \
      '{title: $title, body: $body, labels: [$repo_label, $provider_label, "verdict:pending", "phase:baseline"]}')
  else
    CREATE_PAYLOAD=$(jq -nc \
      --arg title "$TITLE" \
      --arg repo_label "repo:$REPO_SHORT" \
      --arg body "$BODY" \
      '{title: $title, body: $body, labels: [$repo_label, "verdict:pending", "phase:baseline"]}')
  fi

  HTTP=$(curl -sS -o /tmp/ai-log-resp.json -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $AI_REVIEW_LOG_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    https://api.github.com/repos/HarperFast/ai-review-log/issues \
    -d "$CREATE_PAYLOAD")

  if [ "$HTTP" -ge 200 ] && [ "$HTTP" -lt 300 ]; then
    ISSUE_URL=$(jq -r '.html_url' /tmp/ai-log-resp.json)
    echo "Logged review to new issue: $ISSUE_URL"
  else
    echo "::warning::ai-review-log POST failed (HTTP $HTTP):"
    cat /tmp/ai-log-resp.json
  fi
fi
