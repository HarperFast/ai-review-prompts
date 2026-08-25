#!/usr/bin/env bash
# Classify a review attempt without mutating external state.
# Usage: classify-review-run.sh <review-status> <reviewed-head> <current-head> <head-fetch-status>
set -uo pipefail

REVIEW_STATUS="${1:-}"
REVIEWED_HEAD="${2:-}"
CURRENT_HEAD="${3:-}"
HEAD_FETCH_STATUS="${4:-failure}"

if [ "$REVIEW_STATUS" != "success" ]; then
	echo "invalid-review-status"
elif [ -z "$REVIEWED_HEAD" ]; then
	echo "invalid-missing-reviewed-head"
elif [ "$HEAD_FETCH_STATUS" != "success" ] || [ -z "$CURRENT_HEAD" ]; then
	echo "valid-head-unverified"
elif [ "$REVIEWED_HEAD" = "$CURRENT_HEAD" ]; then
	echo "valid-current"
else
	echo "valid-superseded"
fi
