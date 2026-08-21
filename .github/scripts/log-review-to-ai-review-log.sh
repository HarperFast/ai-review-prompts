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
# all exit cleanly with a notice/warning rather than failing unless
# FAIL_ON_UNBOUND=true makes a successful-but-unbound review fatal.
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
#   AI_REVIEW_PROMPTS_REF — optional. The ai-review-prompts ref this
#                           run reviewed under (the caller's pinned SHA).
#                           Recorded as the body's **Prompt ref:** field
#                           and a best-effort `prompt:<shortsha>` label so
#                           calibration can attribute verdicts to a
#                           specific prompt version. Absent → "unknown".
#   LOOKUP_API_PATH       — optional. The GitHub API path to query
#                           for the provider's review surface.
#                           Default:
#                           `repos/<owner>/<repo>/issues/<N>/comments`
#                           (top-level issue comments — the Claude
#                           and Gemini shared-workflow path). Set to
#                           `repos/<owner>/<repo>/pulls/<N>/reviews`
#                           for a custom reviewer that submits via
#                           the GitHub Review API. Both
#                           endpoints return JSON arrays with
#                           `body` / `updated_at` / `created_at`,
#                           so the author-and-run-bound filter works
#                           uniformly.
#   EXPECTED_REVIEW_AUTHOR — optional login that must own the selected
#                           review surface. Defaults to github-actions[bot].
#   FAIL_ON_UNBOUND        — optional. When true, a successful review
#                           without a bound bot-authored surface exits 1.
#   GH_TOKEN              — token with `pull-requests: read`
#   AI_REVIEW_LOG_TOKEN   — fine-grained PAT scoped to
#                           ai-review-log with `issues: write`
#                           (optional — missing skips logging
#                           with a warning)
#   PR_NUMBER             — pull request number
#   PR_URL                — html URL of the PR
#   REVIEW_STATUS         — outcome of the review step
#                           (success / failure / cancelled / etc.)
#   BASE_SHA              — base commit from the pull_request event
#   REVIEWED_HEAD_SHA     — head commit checked out for this review
#   REPO_SHORT            — short repo name (e.g. "harper")
#   GITHUB_REPOSITORY     — owner/repo of the PR's repo
#   GITHUB_RUN_ID         — current Actions run ID (for staleness
#                           guard)
#   GITHUB_RUN_ATTEMPT    — current Actions attempt number
#   REVIEW_CONTEXT_FILE   — optional ai-review-context/v1 snapshot;
#                           its status is recorded with the run
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
EXPECTED_REVIEW_AUTHOR="${EXPECTED_REVIEW_AUTHOR:-github-actions[bot]}"

if [ -z "${AI_REVIEW_LOG_TOKEN:-}" ]; then
  echo "::warning::AI_REVIEW_LOG_TOKEN secret not set; skipping log entry."
  exit 0
fi

RUN_ID="${GITHUB_RUN_ID:-}"
RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-}"
REVIEWED_HEAD_SHA="${REVIEWED_HEAD_SHA:-}"
BASE_SHA="${BASE_SHA:-unknown}"

RUN_VALIDITY=$(bash "$(dirname "$0")/classify-review-run.sh" \
  "${REVIEW_STATUS:-}" "$REVIEWED_HEAD_SHA" "" "failure")
case "$RUN_VALIDITY" in
  invalid-*)
    echo "::warning::Review attempt run=${RUN_ID:-unknown} attempt=${RUN_ATTEMPT:-unknown} is $RUN_VALIDITY (review_status=${REVIEW_STATUS:-unknown}); not logging its body as a verdict."
    exit 0
    ;;
esac

if [ -z "$RUN_ID" ] || [ -z "$RUN_ATTEMPT" ]; then
  echo "::warning::Run ID or attempt is missing; refusing to create an unbound review record."
  exit 0
fi

RUN_MARKER="<!-- ai-review-run:v1 run=$RUN_ID attempt=$RUN_ATTEMPT head=$REVIEWED_HEAD_SHA -->"

# When this workflow job started. Used to filter out stale review
# comments from previous runs so a cancelled in-flight run (e.g.
# from a force-push) doesn't re-log a prior run's content as a
# fresh finding.
JOB_STARTED=$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}" --jq '.run_started_at // empty')

# Fetch the marker'd review surface via raw API. Two endpoint
# shapes are supported:
#   * Default (shared Claude/Gemini): top-level issue comments
#     (`/issues/<N>/comments`)
#   * Custom Review-API callers: pull request reviews
#     (`/pulls/<N>/reviews`)
# Both return JSON arrays with `body` / `user.login` and timestamps,
# so the bot-author and two-line run-binding filter is uniform. We can't use
# `gh pr view --json comments` because it doesn't expose
# `updated_at` (which we need below for the staleness guard).
LOOKUP_API_PATH="${LOOKUP_API_PATH:-repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments}"
if [[ "$LOOKUP_API_PATH" == *\?* ]]; then
  LOOKUP_API_URL="${LOOKUP_API_PATH}&per_page=100"
else
  LOOKUP_API_URL="${LOOKUP_API_PATH}?per_page=100"
fi
REVIEW_JSON=$(gh api --paginate "$LOOKUP_API_URL" \
  | jq -s --arg marker "$MARKER" --arg run_marker "$RUN_MARKER" --arg expected_author "$EXPECTED_REVIEW_AUTHOR" '
    def rtrim_marker: sub("[ \t]+$"; "");
    [.[][]
      | select((.user.login // "") == $expected_author)
      | select(
          (((.body // "") | gsub("\r\n"; "\n") | split("\n")) as $lines
          | ($lines | length) >= 2
          and (($lines[0] | rtrim_marker) == $marker)
          and (($lines[1] | rtrim_marker) == $run_marker))
        )
    ] | last // empty')

if [ -z "$REVIEW_JSON" ] || [ "$REVIEW_JSON" = "null" ]; then
  if [ "${FAIL_ON_UNBOUND:-false}" = "true" ]; then
    echo "::error::No bot-authored review surface bound to run=$RUN_ID attempt=$RUN_ATTEMPT head=$REVIEWED_HEAD_SHA found at $LOOKUP_API_PATH."
    exit 1
  fi
  echo "::warning::No bot-authored review surface bound to run=$RUN_ID attempt=$RUN_ATTEMPT head=$REVIEWED_HEAD_SHA found at $LOOKUP_API_PATH; skipping log."
  exit 0
fi

REVIEW_BODY=$(printf '%s' "$REVIEW_JSON" | jq -r '.body // empty' | sed -e 's/\r$//')
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
if [[ "$REVIEW_BODY" == *"<!-- review:no-log -->"* ]]; then
  echo "::notice::Review carries the no-log marker (mechanical / no-reviewable-code diff); skipping log entry."
  exit 0
fi

# ISO-8601 lexicographic compare — both are UTC timestamps in the
# same shape, so string comparison is sound.
if [ -n "$JOB_STARTED" ] && [ -n "$REVIEW_AT" ] && [ "$REVIEW_AT" \< "$JOB_STARTED" ]; then
  echo "::notice::Latest review comment update ($REVIEW_AT) predates this job's start ($JOB_STARTED); skipping to avoid re-logging stale content."
  exit 0
fi

# Resolve current-head validity only after selecting this run's
# bound review surface, minimizing the interval in which a new push
# could make a clean-current classification stale.
CURRENT_HEAD_SHA=""
HEAD_FETCH_STATUS="failure"
if CURRENT_HEAD_SHA=$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" --jq '.head.sha // empty' 2>/dev/null) \
  && [ -n "$CURRENT_HEAD_SHA" ]; then
  HEAD_FETCH_STATUS="success"
fi
RUN_VALIDITY=$(bash "$(dirname "$0")/classify-review-run.sh" \
  "${REVIEW_STATUS:-}" "$REVIEWED_HEAD_SHA" "$CURRENT_HEAD_SHA" "$HEAD_FETCH_STATUS")

# Title: derive the finding count from the review body. The logic — the
# standardized one-sentence summary line as the primary signal, `### N.`
# headers as the fallback, plus the #68 hardening (spelled-out cardinals,
# and a floor so an asserted "...blocker(s) found." summary never logs as
# "no blockers") — lives in derive-finding-count.sh as a pure, unit-tested
# unit (tests/derive-finding-count.test.sh).
FINDING_COUNT=$(printf '%s' "$REVIEW_BODY" | bash "$(dirname "$0")/derive-finding-count.sh")

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

case "$RUN_VALIDITY" in
  valid-current) TITLE="$TITLE_PREFIX $COUNT_PART" ;;
  valid-superseded) TITLE="$TITLE_PREFIX ${FINDING_COUNT} finding(s) — superseded by push" ;;
  valid-head-unverified) TITLE="$TITLE_PREFIX ${FINDING_COUNT} finding(s) — current head unverified" ;;
  *)
    echo "::warning::Unexpected run validity '$RUN_VALIDITY'; skipping log entry."
    exit 0
    ;;
esac

# Run URL — one click to the action run page where usage / cost
# data is shown (token counts, estimated $). Useful for both
# providers; included unconditionally.
RUN_URL="https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
CURRENT_HEAD_FIELD="${CURRENT_HEAD_SHA:-unknown}"
REVIEW_CONTEXT_STATUS="unknown"
if [ -n "${REVIEW_CONTEXT_FILE:-}" ] && [ -f "$REVIEW_CONTEXT_FILE" ]; then
  REVIEW_CONTEXT_STATUS=$(jq -r '.status // "unknown"' "$REVIEW_CONTEXT_FILE" 2>/dev/null || printf 'unknown')
fi

# ai-review-prompts ref this run reviewed under (passed by the reusable
# workflow's log step as AI_REVIEW_PROMPTS_REF). Recorded in the body so
# calibration can attribute a verdict to a specific prompt version rather
# than a date bucket, and applied as a best-effort `prompt:<shortsha>`
# label below for sweepable per-version queries.
PROMPT_REF="${AI_REVIEW_PROMPTS_REF:-}"
PROMPT_REF_FIELD="${PROMPT_REF:-unknown}"
PROMPT_LABEL=""
[ -n "$PROMPT_REF" ] && PROMPT_LABEL="prompt:${PROMPT_REF:0:12}"
# Set in whichever branch below logs the entry (existing/new); declared
# here so the best-effort label step can reference it unconditionally
# under `set -u`.
ISSUE_NUMBER=""

# Peers link — only included when PROVIDER_LABEL is set, since
# legacy Claude-only flows don't have peer issues to point at.
# This URL is a GitHub issue-search prefiltered to the same
# `[<repo>] PR #<N>` token, so each provider's issue can link
# back to the search that finds all of them.
if [ -n "$PROVIDER_LABEL" ]; then
  PEERS_QUERY=$(printf '%s' "[$REPO_SHORT] PR #$PR_NUMBER" | jq -sRr @uri)
  PEERS_URL="https://github.com/HarperFast/ai-review-log/issues?q=is%3Aissue+${PEERS_QUERY}"
  BODY=$(printf '**Source:** %s\n**Repo:** %s\n**PR:** #%s\n**Provider:** %s\n**Model:** %s\n**Prompt ref:** %s\n**Run:** %s\n**Peers:** %s\n**Phase:** baseline\n**Review job status:** %s\n**Run ID:** %s\n**Run attempt:** %s\n**Base SHA:** %s\n**Reviewed head:** %s\n**Current head:** %s\n**Run validity:** %s\n**Review context:** %s\n**Date:** %s\n\n---\n\n%s\n' \
    "$PR_URL" "$REPO_SHORT" "$PR_NUMBER" "$PROVIDER_LABEL" "$MODEL" "$PROMPT_REF_FIELD" "$RUN_URL" "$PEERS_URL" "$REVIEW_STATUS" "$RUN_ID" "$RUN_ATTEMPT" "$BASE_SHA" "$REVIEWED_HEAD_SHA" "$CURRENT_HEAD_FIELD" "$RUN_VALIDITY" "$REVIEW_CONTEXT_STATUS" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REVIEW_BODY")
else
  BODY=$(printf '**Source:** %s\n**Repo:** %s\n**PR:** #%s\n**Model:** %s\n**Prompt ref:** %s\n**Run:** %s\n**Phase:** baseline\n**Review job status:** %s\n**Run ID:** %s\n**Run attempt:** %s\n**Base SHA:** %s\n**Reviewed head:** %s\n**Current head:** %s\n**Run validity:** %s\n**Review context:** %s\n**Date:** %s\n\n---\n\n%s\n' \
    "$PR_URL" "$REPO_SHORT" "$PR_NUMBER" "$MODEL" "$PROMPT_REF_FIELD" "$RUN_URL" "$REVIEW_STATUS" "$RUN_ID" "$RUN_ATTEMPT" "$BASE_SHA" "$REVIEWED_HEAD_SHA" "$CURRENT_HEAD_FIELD" "$RUN_VALIDITY" "$REVIEW_CONTEXT_STATUS" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REVIEW_BODY")
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

# One ai-review-log issue per (PR, provider). Indexed title search finds
# old PRs without walking the repo's full issue history. The first list
# page is a fallback for a just-created issue not indexed by search yet.
SEARCH_QUERY="repo:HarperFast/ai-review-log is:issue in:title label:\"repo:$REPO_SHORT\" \"$TITLE_PREFIX\""
SEARCH_JSON=""
if ! SEARCH_JSON=$(GH_TOKEN="$AI_REVIEW_LOG_TOKEN" gh api --method GET search/issues \
  -f q="$SEARCH_QUERY" -f per_page=100 2>/dev/null); then
  echo "::warning::Indexed ai-review-log lookup failed; checking only the recent issue page."
fi
EXISTING_NUMBER=$(printf '%s' "$SEARCH_JSON" | jq -r --arg prefix "$TITLE_PREFIX" \
  '[.items[]? | select(.title | startswith($prefix))] | first | .number // empty' 2>/dev/null)
if [ -z "$EXISTING_NUMBER" ]; then
  if ! RECENT_ISSUES=$(GH_TOKEN="$AI_REVIEW_LOG_TOKEN" gh api \
    "repos/HarperFast/ai-review-log/issues?labels=repo:$REPO_SHORT&state=all&per_page=100&sort=created&direction=desc" 2>/dev/null); then
    echo "::warning::Recent ai-review-log lookup failed; refusing to create a possible duplicate."
    exit 0
  fi
  EXISTING_NUMBER=$(printf '%s' "$RECENT_ISSUES" | jq -r --arg prefix "$TITLE_PREFIX" \
    '[.[]? | select(.title | startswith($prefix))] | first | .number // empty' 2>/dev/null)
fi

if [ -n "$EXISTING_NUMBER" ] && [ "$EXISTING_NUMBER" != "null" ]; then
  ISSUE_NUMBER="$EXISTING_NUMBER"
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

  HTTP_T=""
  if [ "$RUN_VALIDITY" = "valid-current" ]; then
    PATCH_PAYLOAD=$(jq -nc --arg title "$TITLE" '{title: $title}')
    HTTP_T=$(curl -sS -o /tmp/ai-log-patch-resp.json -w '%{http_code}' -X PATCH \
      -H "Authorization: Bearer $AI_REVIEW_LOG_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/repos/HarperFast/ai-review-log/issues/$EXISTING_NUMBER" \
      -d "$PATCH_PAYLOAD")
  else
    echo "Preserving the existing issue title for $RUN_VALIDITY evidence."
  fi

  if [ "$HTTP_C" -ge 200 ] && [ "$HTTP_C" -lt 300 ]; then
    COMMENT_URL=$(jq -r '.html_url' /tmp/ai-log-comment-resp.json)
    echo "Logged review as comment on existing issue: $COMMENT_URL"
  else
    echo "::warning::ai-review-log comment POST failed (HTTP $HTTP_C):"
    cat /tmp/ai-log-comment-resp.json
  fi

  if [ -n "$HTTP_T" ] && { [ "$HTTP_T" -lt 200 ] || [ "$HTTP_T" -ge 300 ]; }; then
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
    ISSUE_NUMBER=$(jq -r '.number // empty' /tmp/ai-log-resp.json)
    echo "Logged review to new issue: $ISSUE_URL"
  else
    echo "::warning::ai-review-log POST failed (HTTP $HTTP):"
    cat /tmp/ai-log-resp.json
  fi
fi

# Best-effort: tag the issue with the `prompt:<shortsha>` label so the
# calibration sweep can filter verdicts by prompt version. This NEVER
# gates the log entry — the ref is already recorded in the body above —
# so any failure here is a notice, not a warning. Create the label if it
# is missing (idempotent; an existing label returns 422, ignored), then
# add it to the issue. Re-reviews under a newer ref accumulate a second
# prompt:* label, which correctly marks an issue that spans versions.
if [ -n "$PROMPT_LABEL" ] && [ -n "$ISSUE_NUMBER" ] && [ "$ISSUE_NUMBER" != "null" ]; then
  curl -sS -o /dev/null -X POST \
    -H "Authorization: Bearer $AI_REVIEW_LOG_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    https://api.github.com/repos/HarperFast/ai-review-log/labels \
    -d "$(jq -nc --arg n "$PROMPT_LABEL" '{name: $n, color: "c5def5", description: "ai-review-prompts ref the review ran under"}')" >/dev/null 2>&1 || true
  HTTP_L=$(curl -sS -o /tmp/ai-log-label-resp.json -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $AI_REVIEW_LOG_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/HarperFast/ai-review-log/issues/$ISSUE_NUMBER/labels" \
    -d "$(jq -nc --arg n "$PROMPT_LABEL" '{labels: [$n]}')")
  if [ "$HTTP_L" -ge 200 ] && [ "$HTTP_L" -lt 300 ]; then
    echo "Tagged issue #$ISSUE_NUMBER with $PROMPT_LABEL"
  else
    echo "::notice::prompt-label add returned HTTP $HTTP_L (non-fatal; ref is in the body)"
  fi
fi
