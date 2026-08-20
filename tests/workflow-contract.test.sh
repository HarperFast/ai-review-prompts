#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$DIR/.."
source "$DIR/lib.sh"

CLAUDE=$(<"$ROOT/.github/workflows/_claude-review.yml")
GEMINI=$(<"$ROOT/.github/workflows/_gemini-review.yml")
CALIBRATION=$(<"$ROOT/.github/workflows/calibration-sweep.yml")
UNIVERSAL=$(<"$ROOT/universal.md")
LOGGER=$(<"$ROOT/.github/scripts/log-review-to-ai-review-log.sh")
PRIOR_LOOKUP=$(<"$ROOT/.github/scripts/find-prior-review-comment.sh")

assert_not_contains "$UNIVERSAL" "--json reviewThreads" "prompt does not prescribe an unsupported gh field"
assert_contains "$CLAUDE" "fetch-review-context.sh" "Claude workflow snapshots review threads"
assert_contains "$GEMINI" "fetch-review-context.sh" "Gemini workflow snapshots review threads"
assert_contains "$CLAUDE" "REVIEW_RUN_MARKER:" "Claude body is bound to run identity"
assert_contains "$GEMINI" "REVIEW_RUN_MARKER:" "Gemini body is bound to run identity"
assert_contains "$GEMINI" '--include-directories "$RUNNER_TEMP"' "Gemini can read the runner-temp context snapshot"
assert_contains "$CALIBRATION" "fetch-curated-supplement.sh" "calibration supplements include their comments"
assert_contains "$CALIBRATION" "comments?per_page=100" "triage-rationale comments are paginated"
assert_contains "$LOGGER" "**Run ID:**" "log records carry an explicit run id"
assert_contains "$LOGGER" "**Run attempt:**" "log records distinguish rerun attempts"
assert_contains "$LOGGER" "**Reviewed head:**" "log records identify the reviewed commit"
assert_contains "$LOGGER" "**Run validity:**" "log records expose current/superseded/unverified state"
assert_contains "$LOGGER" 'gh api --paginate "$LOOKUP_API_URL"' "run-bound review lookup covers every comment page"
assert_contains "$PRIOR_LOOKUP" 'gh api --paginate "$API_URL"' "prior-review continuity lookup covers every comment page"

t_summary
