#!/usr/bin/env bash
# Post a Gemini review's structured findings/suggestions as inline,
# line-anchored, resolvable PR review comments — parity with the
# inline surface the Claude leg gets from claude-code-action's
# `create_inline_comment`, and with the (sunsetting) third-party
# gemini-code-assist's inline + severity-labeled comments.
#
# Why this script exists: single-shot Gemini (`gemini --prompt
# --output-format json`) can't call the GitHub API itself, so the
# workflow posts on its behalf. The top-level summary comment is
# still posted by post-review-comment.sh (unchanged) and remains the
# durable, always-present record that feeds the ai-review-log; THIS
# script is additive — it fans the same findings out to inline
# threads the author can reply to and resolve. If inline posting
# fails for any item (e.g. a line not in the diff -> 422), nothing is
# lost: the item is still in the full top-level comment. Best-effort
# by design — never fails the job.
#
# Input contract: the agent emits, after its top-level comment and
# before the run-notes marker, a block introduced by
# `<!-- gemini-inline:v1 -->` containing a JSON array of items:
#
#   [{ "path": "src/x.ts", "line": 42, "kind": "finding",
#      "title": "…", "body": "…" }, …]
#
#   path  — repo-relative file path (RIGHT side of the diff)
#   line  — line number in the new file; MUST be within the diff or
#           GitHub rejects the inline comment (we catch and warn)
#   kind  — "finding" (blocker) | "suggestion" (non-blocking).
#           Anything else is treated as a suggestion (non-gating).
#   title — short headline
#   body  — the detail (what/why/fix, or improvement/benefit)
#
# Idempotency: each posted comment carries a hidden
# `gikey=<hash(path|line|title)>` token inside the item marker. Before
# posting, existing bot comments carrying our marker are read and
# their keys collected; an item whose key already exists is skipped.
# That suppresses exact re-posts on a same-commit re-run or an
# unchanged line across pushes. When a line genuinely moves, its key
# changes, so the comment re-posts at the new line and GitHub marks
# the superseded one "outdated" — the same post-fresh/outdate model
# the Claude leg documents.
#
# Inputs (env):
#   GH_TOKEN            — token with `pull-requests: write`
#   GITHUB_REPOSITORY   — owner/repo (auto-set by Actions)
#   PR_NUMBER           — pull request number
#   HEAD_SHA            — PR head commit SHA (commit_id to anchor to)
#   INLINE_FILE         — path to the file holding the inline JSON
#                         block (split off the response upstream).
#                         Absent/empty/malformed -> nothing to do.
#   INLINE_ITEM_MARKER  — optional. Hidden marker embedded in each
#                         posted body for identification/dedup.
#                         Default `<!-- gemini-inline-item:v1 -->`.
set -uo pipefail

INLINE_ITEM_MARKER="${INLINE_ITEM_MARKER:-<!-- gemini-inline-item:v1 -->}"

# --- pure helpers (unit-tested via tests/lib.sh; no network) --------

# Severity label. Findings are blockers; everything else is a
# non-blocking suggestion. Binary by design — our review discipline
# is "blocker or not", not a high/med/low gradient.
badge_for() {
  case "$1" in
    finding) printf '🔴 **Blocker**' ;;
    *)       printf '💡 **Suggestion (non-blocking)**' ;;
  esac
}

# Stable short key over (path, line, title) for dedup. Portable across
# the sha256 tool name on Linux runners (sha256sum) and macOS (shasum).
item_key() {
  local raw="$1|$2|$3" h
  if command -v sha256sum >/dev/null 2>&1; then
    h=$(printf '%s' "$raw" | sha256sum)
  else
    h=$(printf '%s' "$raw" | shasum -a 256)
  fi
  printf '%s' "${h%% *}" | cut -c1-16
}

# Compose the inline comment body: severity badge, title, detail, and
# the hidden identification/dedup marker with its key.
format_body() {
  local kind="$1" title="$2" body="$3" key="$4"
  printf '%s — **%s**\n\n%s\n\n%s gikey=%s -->' \
    "$(badge_for "$kind")" "$title" "$body" "${INLINE_ITEM_MARKER% -->}" "$key"
}

# --- main (network) -------------------------------------------------

main() {
  local file="${INLINE_FILE:-}"
  if [ -z "$file" ] || [ ! -s "$file" ]; then
    echo "::notice::No inline-comments block to post (INLINE_FILE absent/empty)."
    return 0
  fi

  # Parse the block as a JSON array. The agent is told to emit raw JSON,
  # so try the content untouched first — that way a ``` fence inside a
  # finding body can never be corrupted by fence stripping. Only if the
  # raw content doesn't parse do we fall back to stripping ```-fence
  # lines (the model occasionally wraps the array in ```json … ```) and
  # retry.
  local json
  json=$(cat "$file")
  if ! printf '%s' "$json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    json=$(sed -e '/^[[:space:]]*```/d' "$file")
  fi
  if ! printf '%s' "$json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "::warning::Inline block is not a JSON array; skipping inline comments (top-level comment still carries the findings)."
    return 0
  fi
  local count
  count=$(printf '%s' "$json" | jq 'length')
  if [ "$count" = "0" ]; then
    echo "::notice::Inline block is an empty array; nothing to post."
    return 0
  fi

  # Collect keys already posted by us (dedup across re-runs/pushes).
  # Match on the marker PREFIX (the marker minus its ` -->` close), not
  # the full marker: format_body emits `<!-- gemini-inline-item:v1
  # gikey=<key> -->`, so the closed full marker is never a substring of
  # a posted body — filtering on it would match nothing and dedup would
  # silently never fire (caught by the dogfood on this PR).
  local marker_prefix="${INLINE_ITEM_MARKER% -->}"
  local existing_keys
  existing_keys=$(gh api --paginate \
    "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/comments" 2>/dev/null \
    | jq -r --arg m "$marker_prefix" \
      '.[] | select((.body // "") | contains($m)) | .body' \
    | grep -oE 'gikey=[0-9a-f]+' | sort -u || true)

  local posted=0 skipped=0 failed=0 i
  for ((i = 0; i < count; i++)); do
    local item path line kind title body
    item=$(printf '%s' "$json" | jq -c ".[$i]")
    path=$(printf '%s' "$item" | jq -r '.path // ""')
    line=$(printf '%s' "$item" | jq -r '.line // ""')
    kind=$(printf '%s' "$item" | jq -r '.kind // "suggestion"')
    title=$(printf '%s' "$item" | jq -r '.title // ""')
    body=$(printf '%s' "$item" | jq -r '.body // ""')

    if [ -z "$path" ] || ! printf '%s' "$line" | grep -qE '^[0-9]+$' || [ -z "$title" ]; then
      echo "::warning::Skipping malformed inline item #$i (need path, numeric line, title): $item"
      failed=$((failed + 1))
      continue
    fi

    local key
    key=$(item_key "$path" "$line" "$title")
    if printf '%s\n' "$existing_keys" | grep -qx "gikey=$key"; then
      echo "Already posted (gikey=$key): ${path}:${line} — ${title}; skipping."
      skipped=$((skipped + 1))
      continue
    fi

    local comment_body payload err
    comment_body=$(format_body "$kind" "$title" "$body" "$key")
    payload=$(jq -nc \
      --arg body "$comment_body" \
      --arg sha "$HEAD_SHA" \
      --arg path "$path" \
      --argjson line "$line" \
      '{body: $body, commit_id: $sha, path: $path, line: $line, side: "RIGHT"}')

    err=$(mktemp)
    if printf '%s' "$payload" | gh api --method POST \
        "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/comments" \
        --input - >/dev/null 2>"$err"; then
      echo "Posted inline (${kind}) at ${path}:${line} — ${title}"
      posted=$((posted + 1))
    else
      echo "::warning::Failed to post inline comment at ${path}:${line} (likely not in the diff); it remains in the top-level comment. gh said:"
      sed 's/^/  /' "$err"
      failed=$((failed + 1))
    fi
    rm -f "$err"
  done

  echo "Inline comments: ${posted} posted, ${skipped} deduped, ${failed} skipped/failed (of ${count})."
  return 0
}

# Only run main when executed directly — sourcing (the unit tests)
# gets the pure helpers without the network path.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
