#!/usr/bin/env bash
# Compose the custom `/harper-review` slash-command TOML by
# substituting the runtime layered review scope into the
# template at `prompts/gemini-review.toml.template`. Writes the
# result to `.gemini/commands/harper-review.toml` where the
# Gemini CLI auto-discovers it.
#
# Driven by `_gemini-review.yml`'s "Compose Harper review
# command TOML" step.
#
# The template is adopted from Google's official PR review
# example for `run-gemini-cli`:
#   google-github-actions/run-gemini-cli@f77273f4 (v0.1.22)
#   examples/workflows/pr-review/gemini-review.toml
# Our version replaces the upstream "Review Criteria" section
# with Harper's layered review scope; everything else (security
# constraints, execution workflow, comment formatting,
# submission flow) is structurally adopted from upstream.
#
# Three placeholders are substituted (mustache-style so we don't
# collide with the template's own documentation comments):
#   {{LAYERED_SCOPE}}        — REVIEW_SCOPE env var (from
#                              compose-review-scope.sh's
#                              `composed` output)
#   {{REPO_SPECIFIC_CHECKS}} — REPO_SPECIFIC_CHECKS env var
#                              (caller's repo-specific-checks input)
#   {{MARKER}}               — sentinel the agent prefixes to its
#                              submission summary. Default
#                              `<!-- gemini-review:v1 -->`.
#
# Inputs:
#   REVIEW_SCOPE              — required. Composed layered review
#                               scope (markdown). Multi-line OK.
#   REPO_SPECIFIC_CHECKS      — optional. Repo-specific bullets
#                               that stack on top of the layered
#                               scope. Empty is fine.
#   MARKER                    — optional. Override the marker
#                               line. Default
#                               `<!-- gemini-review:v1 -->`.
#   TEMPLATE_PATH             — optional. Path to the template
#                               file. Default
#                               `.ai-review-prompts/prompts/gemini-review.toml.template`.
#   OUTPUT_PATH               — optional. Where to write the
#                               composed TOML. Default
#                               `.gemini/commands/harper-review.toml`.
set -uo pipefail

if [ -z "${REVIEW_SCOPE:-}" ]; then
  echo "::error::REVIEW_SCOPE env var is required (typically from compose-review-scope.sh's `composed` output)."
  exit 1
fi

MARKER="${MARKER:-<!-- gemini-review:v1 -->}"
TEMPLATE_PATH="${TEMPLATE_PATH:-.ai-review-prompts/prompts/gemini-review.toml.template}"
OUTPUT_PATH="${OUTPUT_PATH:-.gemini/commands/harper-review.toml}"

if [ ! -f "$TEMPLATE_PATH" ]; then
  echo "::error::Template not found at $TEMPLATE_PATH"
  exit 1
fi

# Write the multi-line env vars to tempfiles so awk can stream them
# in at the placeholder positions. awk's `getline` reads line-by-line
# which preserves arbitrary markdown (including code fences, backticks,
# dollar signs, quotes) without shell-interpretation surprises.
SCOPE_FILE=$(mktemp)
CHECKS_FILE=$(mktemp)
trap 'rm -f "$SCOPE_FILE" "$CHECKS_FILE"' EXIT

printf '%s' "$REVIEW_SCOPE" > "$SCOPE_FILE"
printf '%s' "${REPO_SPECIFIC_CHECKS:-}" > "$CHECKS_FILE"

# Output directory needs to exist.
mkdir -p "$(dirname "$OUTPUT_PATH")"

# Substitute. awk reads the template line by line; when a placeholder
# line is encountered, the relevant tempfile is streamed in its place.
# `__MARKER__` is a single-token replacement (the marker is one line),
# done via gsub. The block-substitutions for layered scope and
# repo-specific checks use the streaming approach.
awk \
  -v scope_file="$SCOPE_FILE" \
  -v checks_file="$CHECKS_FILE" \
  -v marker="$MARKER" '
  /\{\{LAYERED_SCOPE\}\}/ {
    while ((getline line < scope_file) > 0) print line
    close(scope_file)
    next
  }
  /\{\{REPO_SPECIFIC_CHECKS\}\}/ {
    while ((getline line < checks_file) > 0) print line
    close(checks_file)
    next
  }
  {
    gsub(/\{\{MARKER\}\}/, marker)
    print
  }
' "$TEMPLATE_PATH" > "$OUTPUT_PATH"

BYTES=$(wc -c < "$OUTPUT_PATH")
echo "Composed Harper review TOML: $OUTPUT_PATH ($BYTES bytes)"

if [ "$BYTES" -lt 1000 ]; then
  echo "::warning::Composed TOML is suspiciously small ($BYTES bytes). Did REVIEW_SCOPE compose correctly?"
fi

# Sanity check: ensure no placeholders leaked through.
if grep -qE '\{\{LAYERED_SCOPE\}\}|\{\{REPO_SPECIFIC_CHECKS\}\}|\{\{MARKER\}\}' "$OUTPUT_PATH"; then
  echo "::error::Unresolved placeholders in $OUTPUT_PATH — composition incomplete."
  grep -nE '\{\{LAYERED_SCOPE\}\}|\{\{REPO_SPECIFIC_CHECKS\}\}|\{\{MARKER\}\}' "$OUTPUT_PATH"
  exit 1
fi
