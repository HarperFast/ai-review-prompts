#!/usr/bin/env bash
# Concurrency contract for the two caller patterns:
#
#   STANDALONE (examples/claude-review.yml): the caller's gate IS the
#   authorization, so the caller carries an eligibility-scoped
#   workflow-level group whose cancelling predicate must stay a strict
#   subset of the job gate (cancel-in-progress applies at queue time,
#   before any job `if:`).
#
#   THIN CALLER (this repo's gemini-review.yml dogfood, and the fleet
#   callers): NO workflow-level concurrency — cancellation is owned by
#   the reusable's review job (job-level group, engaged only after
#   authorize/skip/key gates pass), so an unauthorized event can never
#   cancel a legitimate review.
#
# Matrix this test pins (the bugs it prevents were all found in review —
# harper#2348 / harper#2353 / harper#2357 and their harper-pro twins):
#   labeled(claude-review, human): RUNS but never cancels — the review
#                                  platform's own labeler trust is
#                                  stricter than any caller expression;
#                                  a duplicate beats a silent loss
#   labeled(anything else):        neither runs nor cancels
#   ready_for_review:              RUNS (label-opted, or always-on via the
#                                  job gate) but NEVER cancels — its
#                                  authorization is author-based
#   trusted push + ALWAYS_ON:      cancels + runs (draft == false,
#                                  trusted author association)
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
EXAMPLE="$DIR/../examples/claude-review.yml"
source "$DIR/lib.sh"

GROUP_LINE="$(grep -E '^  group: ' "$EXAMPLE")"
IF_BLOCK="$(awk '/^    if: >-/,/^    runs-on:/' "$EXAMPLE")"

# --- cancelling set (concurrency predicate) ---------------------------
assert_contains "$GROUP_LINE" "&& 'eligible' || github.run_id" \
  "ineligible events get a unique run_id group"
assert_not_contains "$GROUP_LINE" "github.event.label.name" \
  "no labeled arm in the cancelling set — labeled runs review, never cancels"
assert_contains "$GROUP_LINE" "github.event.action != 'labeled'" \
  "cancelling arm explicitly excludes labeled events"
assert_contains "$GROUP_LINE" "github.event.action != 'ready_for_review'" \
  "cancelling arm excludes ready_for_review"
assert_not_contains "$GROUP_LINE" "action == 'ready_for_review'" \
  "no arm makes ready_for_review eligible to cancel"

# --- running set (job gate) -------------------------------------------
assert_contains "$IF_BLOCK" "github.event.action == 'ready_for_review'" \
  "ready_for_review still runs a review (label-opted arm present)"
assert_contains "$IF_BLOCK" "contains(github.event.pull_request.labels.*.name, 'claude-review')" \
  "the ready arm requires the persisted opt-in label"
assert_contains "$IF_BLOCK" "github.event.label.name == 'claude-review'" \
  "labeled arm of the job gate requires the provider's own label"
assert_contains "$IF_BLOCK" "github.event.pull_request.draft == false" \
  "always-on arm skips drafts"
assert_not_contains "$IF_BLOCK" "github.event.action != 'ready_for_review'" \
  "the job gate never excludes ready_for_review — that split is the concurrency predicate's"
assert_contains "$IF_BLOCK" "github.event.action != 'labeled'" \
  "the always-on arm admits non-label events (ready_for_review included)"

# --- relation ----------------------------------------------------------
# Every arm that can cancel must also run. The cancelling set is ONE
# arm — always-on trusted-author non-draft pushes — strictly narrower
# than the job gate (which additionally runs labeled and label-opted
# ready_for_review events, without cancel rights). Assert the
# cancelling arm carries both event exclusions and both guards.
assert_contains "$GROUP_LINE" "github.event.action != 'labeled' && github.event.action != 'ready_for_review' && vars.CLAUDE_ALWAYS_ON == 'true'" \
  "always-on cancelling arm excludes labeled and ready_for_review"
assert_contains "$GROUP_LINE" "github.event.pull_request.draft == false" \
  "always-on cancelling arm carries the job gate's draft guard"
assert_contains "$GROUP_LINE" "github.event.pull_request.author_association" \
  "always-on cancelling arm carries the job gate's author-trust guard"

# --- thin-caller pattern: dogfood carries NO workflow-level group ------
DOGFOOD="$(cat "$DIR/../.github/workflows/gemini-review.yml")"
assert_not_contains "$DOGFOOD" "cancel-in-progress" \
  "gemini dogfood thin caller has no workflow-level concurrency"

# --- reusables own cancellation at the review job, post-authorization --
for wf in _claude-review _gemini-review; do
  prov="${wf#_}"; prov="${prov%-review}"
  JOB_CONC="$(awk '/^  review:/,/^    steps:/' "$DIR/../.github/workflows/$wf.yml")"
  assert_contains "$JOB_CONC" "group: ${prov}-review-\${{ github.repository }}-\${{ github.event.pull_request.number || github.run_id }}" \
    "$wf review job carries the job-level cancellation group"
  assert_contains "$JOB_CONC" "cancel-in-progress: true" \
    "$wf review job cancels superseded in-flight reviews"
done

G_IF_LINE="$(grep -E "^    if: .*GEMINI_ALWAYS_ON" "$DIR/../.github/workflows/gemini-review.yml")"
assert_contains "$G_IF_LINE" "github.event.label.name == 'gemini-review'" \
  "gemini dogfood job gate requires its own label on labeled events"
assert_contains "$G_IF_LINE" "github.event.action == 'ready_for_review'" \
  "gemini dogfood job gate runs label-opted ready_for_review"
assert_contains "$G_IF_LINE" "contains(github.event.pull_request.labels.*.name, 'gemini-review')" \
  "gemini dogfood ready arm requires the persisted opt-in label"
assert_not_contains "$G_IF_LINE" "github.event.action != 'ready_for_review'" \
  "gemini dogfood job gate never excludes ready_for_review"
assert_contains "$G_IF_LINE" "github.event.action != 'labeled'" \
  "gemini dogfood always-on arm admits non-label events"

t_summary
