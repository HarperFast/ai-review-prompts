#!/usr/bin/env bash
# Decide, BEFORE the expensive agent step runs, whether this PR needs a
# review at all and at what reasoning effort — from the PR's file list
# alone (GitHub API; runs pre-checkout in the authorize job).
#
# Inputs (env):
#   REPO              owner/repo of the PR
#   PR_NUMBER         PR number
#   EFFORT            effort for normal/large diffs ('' = omit the flag)
#   EFFORT_SMALL      effort for small diffs ('' disables tiering)
#   SMALL_DIFF_LINES  changed-line threshold at or under which
#                     EFFORT_SMALL applies (skip-listed files excluded
#                     from the count)
#   SKIP_WHEN_ONLY    newline-separated globs; when EVERY changed file
#                     matches one, the review is skipped entirely
#   GITHUB_OUTPUT     step-output file
#
# Outputs (to $GITHUB_OUTPUT):
#   skip    true | false
#   effort  effort level the review should run at ('' = omit the flag)
#   reason  one-line explanation for the run log
#
# Fail-OPEN by design: any API or parse failure proceeds with a full
# review at EFFORT. This gate exists to save cost on runs we are SURE
# are wasteful — uncertainty means review.
set -uo pipefail

emit() {
  {
    printf 'skip=%s\n' "$1"
    printf 'effort=%s\n' "$2"
    printf 'reason=%s\n' "$3"
  } >> "$GITHUB_OUTPUT"
  echo "assess-review-need: skip=$1 effort=$2 reason=$3"
}

# Up to 3 pages (300 files). A PR past that is unambiguously reviewable
# and unambiguously not small.
PAGES=()
for page in 1 2 3; do
  PAGE_JSON=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/files?per_page=100&page=${page}" 2>/dev/null) || {
    emit false "${EFFORT}" "assess-unavailable (files API failed; fail-open)"
    exit 0
  }
  COUNT=$(printf '%s' "$PAGE_JSON" | jq 'length' 2>/dev/null) || {
    emit false "${EFFORT}" "assess-unavailable (unparseable files payload; fail-open)"
    exit 0
  }
  PAGES+=("$PAGE_JSON")
  [ "$COUNT" -lt 100 ] && break
  if [ "$page" = 3 ] && [ "$COUNT" = 100 ]; then
    emit false "${EFFORT}" "large-pr (>300 files)"
    exit 0
  fi
done
FILES_JSON=$(printf '%s\n' "${PAGES[@]}" | jq -s 'add')

TOTAL=$(printf '%s' "$FILES_JSON" | jq 'length')
if [ "$TOTAL" -eq 0 ]; then
  emit true "" "empty-diff"
  exit 0
fi

# --- vacuous-diff gate: every file matches a skip glob -----------------
GLOBS=()
while IFS= read -r glob; do
  glob="${glob#"${glob%%[![:space:]]*}"}"
  glob="${glob%"${glob##*[![:space:]]}"}"
  [ -n "$glob" ] && GLOBS+=("$glob")
done <<< "${SKIP_WHEN_ONLY:-}"

matches_skip_glob() {
  local f="$1" glob
  for glob in "${GLOBS[@]+"${GLOBS[@]}"}"; do
    # shellcheck disable=SC2254 — glob comes from workflow input on purpose
    case "$f" in
      $glob) return 0 ;;
    esac
  done
  return 1
}

ALL_SKIPPABLE=true
REVIEWABLE_LINES=0
while IFS=$'\t' read -r fname changes; do
  if matches_skip_glob "$fname"; then
    continue
  fi
  ALL_SKIPPABLE=false
  REVIEWABLE_LINES=$((REVIEWABLE_LINES + changes))
done < <(printf '%s' "$FILES_JSON" | jq -r '.[] | [.filename, ((.additions // 0) + (.deletions // 0))] | @tsv')

if [ "$ALL_SKIPPABLE" = true ]; then
  emit true "" "only-mechanical-files (all files match skip-when-only)"
  exit 0
fi

# --- release-bump gate: package.json version line + lockfiles only -----
# Files limited to package.json + lockfiles, and every changed line in
# package.json touches only the "version" field → a release bump with
# nothing to review.
read -r NON_PKG HAS_PKG < <(printf '%s' "$FILES_JSON" | jq -r '
  [([.[] | .filename
     | select(. != "package.json" and . != "package-lock.json"
              and . != "npm-shrinkwrap.json" and . != "yarn.lock"
              and . != "pnpm-lock.yaml" and . != "bun.lockb")] | length),
   ([.[] | select(.filename == "package.json")] | length)] | @tsv' | tr "\t" " ")
if [ "$NON_PKG" = 0 ] && [ "$HAS_PKG" = 1 ]; then
  PKG_PATCH=$(printf '%s' "$FILES_JSON" | jq -r '.[] | select(.filename == "package.json") | .patch // ""')
  NON_VERSION_CHANGES=$(printf '%s' "$PKG_PATCH" \
    | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' \
    | grep -cvE '^[+-][[:space:]]*"version":') || true
  if [ "${NON_VERSION_CHANGES:-1}" = 0 ]; then
    emit true "" "version-bump-only"
    exit 0
  fi
fi

# --- effort tiering ----------------------------------------------------
EFFORT_OUT="${EFFORT}"
REASON="reviewable (${REVIEWABLE_LINES} changed lines outside skip globs)"
if [ -n "${EFFORT}" ] && [ -n "${EFFORT_SMALL:-}" ] \
  && [ "$REVIEWABLE_LINES" -le "${SMALL_DIFF_LINES:-0}" ]; then
  EFFORT_OUT="${EFFORT_SMALL}"
  REASON="small-diff (${REVIEWABLE_LINES} <= ${SMALL_DIFF_LINES} changed lines) — effort tiered down"
fi

emit false "${EFFORT_OUT}" "${REASON}"
