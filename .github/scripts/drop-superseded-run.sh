#!/usr/bin/env bash
# Post-acquire freshness check for the reusable review jobs: after the
# job-level concurrency slot is acquired, confirm the event this run
# was born from is still the PR's head. If the head moved, FAIL (exit
# 1) rather than review a stale commit — the failed check lands on the
# superseded (old) head, and the log step refuses failed runs as
# verdicts. Fresh, unreadable, or null live heads exit 0 (fail-open:
# the pre-queue gate in assess-review-need.sh is the first line of
# defense; this is the second).
#
# Inputs (env):
#   REPO        owner/repo of the PR
#   PR_NUMBER   PR number
#   EVENT_HEAD  the head SHA the triggering event carried
set -uo pipefail

LIVE=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq .head.sha 2>/dev/null) || LIVE=""
# `--jq` prints the literal string "null" for a missing field — treat
# it as unreadable (fail-open), not as a differing head.
if [ -n "$LIVE" ] && [ "$LIVE" != "null" ] && [ "$LIVE" != "${EVENT_HEAD}" ]; then
  echo "::error::Superseded (head moved ${EVENT_HEAD} -> ${LIVE}); failing instead of reviewing a stale head. The tip is covered by the newer event's run — or, if this run cancelled it in the residual reorder window, by the next event."
  exit 1
fi
exit 0
