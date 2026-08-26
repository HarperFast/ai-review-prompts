#!/usr/bin/env bash
# Event-matrix contract for the canonical caller (examples/claude-review.yml).
#
# The caller has two predicates that must relate as cancelling ⊆ running:
#   - the concurrency group predicate (which runs may CANCEL an in-flight
#     review — GitHub applies cancel-in-progress at queue time, before
#     any job `if:`),
#   - the review job `if:` (which runs REVIEW).
#
# Matrix this test pins (the bugs it prevents were all found in review —
# harper#2348 / harper#2353 / harper#2357 / harper-pro#766–#768):
#   labeled(claude-review, human): cancels + runs
#   labeled(anything else):        neither (must not share the group)
#   ready_for_review:              RUNS (label-opted, or always-on via the
#                                  job gate) but NEVER cancels — its
#                                  authorization is author-based, so it
#                                  must not kill a labeler-authorized run
#   other events + ALWAYS_ON:      cancel + run
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
EXAMPLE="$DIR/../examples/claude-review.yml"
source "$DIR/lib.sh"

GROUP_LINE="$(grep -E '^  group: ' "$EXAMPLE")"
IF_BLOCK="$(awk '/^    if: >-/,/^    runs-on:/' "$EXAMPLE")"

# --- cancelling set (concurrency predicate) ---------------------------
assert_contains "$GROUP_LINE" "&& 'eligible' || github.run_id" \
  "ineligible events get a unique run_id group"
assert_contains "$GROUP_LINE" "github.event.label.name == 'claude-review'" \
  "labeled arm cancels only on the provider's own label"
assert_contains "$GROUP_LINE" "github.event.action != 'ready_for_review'" \
  "always-on arm excludes ready_for_review from the cancelling set"
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

# --- relation ----------------------------------------------------------
# Every arm that can cancel must also run: the labeled arm appears in
# both; the always-on cancelling arm is the job gate's always-on arm
# minus ready_for_review. Assert the cancelling always-on arm carries
# BOTH exclusions so it stays strictly narrower.
assert_contains "$GROUP_LINE" "github.event.action != 'labeled' && github.event.action != 'ready_for_review' && vars.CLAUDE_ALWAYS_ON == 'true'" \
  "always-on cancelling arm is the running arm minus ready_for_review"

t_summary
