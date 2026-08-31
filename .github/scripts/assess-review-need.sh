#!/usr/bin/env bash
# Decide, BEFORE the expensive agent step runs, whether this PR needs a
# review at all and at what reasoning effort — from the PR's file list
# alone (GitHub API; runs pre-checkout in the authorize job).
#
# Inputs (env):
#   REPO              owner/repo of the PR
#   PR_NUMBER         PR number
#   HEAD_SHA          the event's head SHA; compared against the PR's
#                     live head for the freshness output (empty skips
#                     the check and reports fresh)
#   EFFORT            fixed effort when EFFORT_BY_SIZE is empty
#                     ('' = omit the flag)
#   EFFORT_BY_SIZE    newline-separated '<max-lines> <level>' bands,
#                     ascending, with an optional '* <level>' catch-all —
#                     the first band whose max-lines covers the diff's
#                     changed lines (skip-listed files excluded) picks
#                     the effort. Empty disables laddering. When set,
#                     EFFORT applies only past the last band.
#   SKIP_WHEN_ONLY    newline-separated globs; when EVERY changed file
#                     matches one, the review is skipped entirely
#   GITHUB_OUTPUT     step-output file
#
# Outputs (to $GITHUB_OUTPUT):
#   skip    true | false
#   effort  effort level the review should run at ('' = omit the flag)
#   fresh   true | false — false only when the PR's live head is known
#           to differ from HEAD_SHA (stale event; the review job must
#           not be admitted to the cancelling concurrency group)
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
    printf 'fresh=%s\n' "${FRESH}"
    printf 'reason=%s\n' "$3"
  } >> "$GITHUB_OUTPUT"
  echo "assess-review-need: skip=$1 effort=$2 fresh=${FRESH} reason=$3"
}

# --- freshness: is this event still the PR's head? ---------------------
# A stale run admitted to the review job could cancel a NEWER in-flight
# review at queue time (GitHub does not order concurrency-group entry).
# Deciding freshness here — before the review job queues — keeps stale
# runs out of the cancelling group entirely. Fail-OPEN: an unreadable
# live head reports fresh (the post-acquire re-check in the review job
# is the second line of defense).
FRESH=true
if [ -n "${HEAD_SHA:-}" ]; then
  LIVE_HEAD=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq .head.sha 2>/dev/null) || LIVE_HEAD=""
  # `--jq` prints the literal string "null" for a missing field — treat
  # it as unreadable (fail-open), not as a differing head.
  if [ -n "$LIVE_HEAD" ] && [ "$LIVE_HEAD" != "null" ] && [ "$LIVE_HEAD" != "$HEAD_SHA" ]; then
    FRESH=false
    emit false "" "stale-event (head moved ${HEAD_SHA} -> ${LIVE_HEAD}; not admitted to the cancelling group)"
    exit 0
  fi
fi

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

# --- effort ladder -----------------------------------------------------
EFFORT_OUT="${EFFORT}"
REASON="reviewable (${REVIEWABLE_LINES} changed lines outside skip globs)"
# EFFORT='' is the omit-the-flag escape hatch; it overrides the ladder.
[ -z "${EFFORT}" ] && EFFORT_BY_SIZE=""
while IFS= read -r band; do
  band="${band#"${band%%[![:space:]]*}"}"
  band="${band%"${band##*[![:space:]]}"}"
  [ -z "$band" ] && continue
  max="${band%% *}"
  level="${band#* }"
  # Malformed band (no two fields, or non-numeric non-* threshold):
  # fail open to EFFORT for the rest of the ladder.
  if [ "$max" = "$band" ] || [ -z "$level" ]; then
    REASON="reviewable (${REVIEWABLE_LINES} changed lines; malformed effort-by-size band ignored)"
    break
  fi
  if [ "$max" = '*' ]; then
    EFFORT_OUT="$level"
    REASON="effort-by-size: ${REVIEWABLE_LINES} changed lines → ${level} (catch-all)"
    break
  fi
  case "$max" in
    ''|*[!0-9]*)
      REASON="reviewable (${REVIEWABLE_LINES} changed lines; malformed effort-by-size band ignored)"
      break ;;
  esac
  if [ "$REVIEWABLE_LINES" -le "$max" ]; then
    EFFORT_OUT="$level"
    REASON="effort-by-size: ${REVIEWABLE_LINES} changed lines <= ${max} → ${level}"
    break
  fi
done <<< "${EFFORT_BY_SIZE:-}"

emit false "${EFFORT_OUT}" "${REASON}"
