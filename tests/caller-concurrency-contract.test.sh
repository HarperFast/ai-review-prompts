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

# --- relation ----------------------------------------------------------
# Every arm that can cancel must also run: the labeled arm appears in
# both; the always-on cancelling arm is the job gate's always-on arm
# minus ready_for_review. Assert the cancelling always-on arm carries
# BOTH exclusions so it stays strictly narrower.
assert_contains "$GROUP_LINE" "github.event.action != 'labeled' && github.event.action != 'ready_for_review' && vars.CLAUDE_ALWAYS_ON == 'true'" \
  "always-on cancelling arm excludes labeled and ready_for_review"
assert_contains "$GROUP_LINE" "github.event.pull_request.draft == false" \
  "always-on cancelling arm carries the job gate's draft guard"
assert_contains "$GROUP_LINE" "github.event.pull_request.author_association" \
  "always-on cancelling arm carries the job gate's author-trust guard"

# --- sibling: this repo's own gemini-review.yml dogfood caller ---------
G_GROUP_LINE="$(grep -E '^  group: ' "$DIR/../.github/workflows/gemini-review.yml")"
assert_contains "$G_GROUP_LINE" "&& 'eligible' || github.run_id" \
  "gemini dogfood caller scopes its cancelling group"
assert_not_contains "$G_GROUP_LINE" "github.event.label.name" \
  "gemini dogfood: no labeled arm in the cancelling set"
assert_contains "$G_GROUP_LINE" "github.event.action != 'labeled'" \
  "gemini dogfood cancelling arm excludes labeled events"
assert_contains "$G_GROUP_LINE" "github.event.action != 'ready_for_review'" \
  "gemini dogfood cancelling arm excludes ready_for_review"
assert_contains "$G_GROUP_LINE" "github.event.pull_request.draft == false" \
  "gemini dogfood cancelling arm carries the draft guard"
assert_contains "$G_GROUP_LINE" "github.event.pull_request.author_association" \
  "gemini dogfood cancelling arm carries the author-trust guard"

G_IF_LINE="$(grep -E "^    if: .*GEMINI_ALWAYS_ON" "$DIR/../.github/workflows/gemini-review.yml")"
assert_contains "$G_IF_LINE" "github.event.label.name == 'gemini-review'" \
  "gemini dogfood job gate requires its own label on labeled events"
assert_contains "$G_IF_LINE" "github.event.action == 'ready_for_review'" \
  "gemini dogfood job gate runs label-opted ready_for_review"
assert_contains "$G_IF_LINE" "contains(github.event.pull_request.labels.*.name, 'gemini-review')" \
  "gemini dogfood ready arm requires the persisted opt-in label"

t_summary
