#!/usr/bin/env bash
# Validate consumer caller workflows for the AI workflow chain.
# Runs in a CONSUMER repo's checkout (harper, oauth, etc.) against
# its `.github/workflows/claude-*.yml` and `gemini-*.yml` files —
# both providers' callers grant `pull-requests: write` and delegate
# to a reusable here, so both need the same fail-closed guard
# (gemini coverage was a gap flagged in rocksdb-js#701 review
# feedback). The companion validator
# in `validate-auth-gate-invariants.sh` validates the *reusables*
# (`_claude-*.yml`) inside this repo; this one validates the
# *callers* in consumer repos.
#
# STRUCTURAL lint, not a semantic test. Catches:
#
#   * **Shadow jobs.** Caller workflows are gated by the reusables
#     they invoke; the auth-gate, the team check, the trust-set logic
#     all live downstream. A caller file that contains a non-`uses:`
#     job (or a `uses:` pointing somewhere other than `HarperFast/`)
#     would run with the caller's permissions WITHOUT going through
#     the auth gate. Reject those.
#
#   * **Mutable refs.** A `uses:` pinned to a tag/branch could be
#     silently repointed; an `ai-review-prompts-ref` input pinned to
#     a tag/branch defeats the SHA-pinning we put on the `uses:` line
#     (the reusable would check out scripts/layers from a moving
#     target). Both must be 40-char SHAs.
#
# What it does NOT enforce (intentional, per HarperFast/harper PR
# review feedback): SHA-MATCH between `uses:` and
# `ai-review-prompts-ref`. Enforcing match across consumer repos is
# too churny for the marginal protection it adds; the SHA-shape check
# below catches the actual supply-chain risk.
#
# Inputs (none — runs in the consumer repo's checkout). Validates:
#   .github/workflows/claude-*.yml
#   .github/workflows/gemini-*.yml
#
# Exit code:
#   0  all callers pass (or no caller files present)
#   1  any check failed (errors emitted as ::error::)
set -uo pipefail

fail() {
  echo "::error::$1"
  exit 1
}

command -v yq >/dev/null || fail "yq not available on runner"

shopt -s nullglob
files=(.github/workflows/claude-*.yml .github/workflows/gemini-*.yml)
if [ "${#files[@]}" -eq 0 ]; then
  echo "No claude-*.yml / gemini-*.yml caller workflows found; nothing to validate."
  exit 0
fi

for f in "${files[@]}"; do
  echo ""
  echo "=== Validating $f ==="

  jobs=$(yq -r '.jobs | keys | .[]' "$f" 2>/dev/null || true)
  [ -n "$jobs" ] || fail "$f: no jobs defined"

  for j in $jobs; do
    uses=$(yq -r ".jobs.\"${j}\".uses // \"\"" "$f")
    if [ -z "$uses" ]; then
      fail "$f: job '$j' has no 'uses:' — caller-pattern workflows must delegate every job to a HarperFast/ reusable (no shadow jobs)"
    fi

    case "$uses" in
      HarperFast/*) ;;
      *) fail "$f: job '$j' uses '$uses' — must reference a HarperFast/ reusable" ;;
    esac

    # The `uses:` ref (the part after the last @) must be a 40-char SHA.
    ref="${uses##*@}"
    if ! [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
      fail "$f: job '$j' uses ref '$ref' — must pin to a 40-char SHA (got '$uses'); tag/branch refs are mutable and a supply-chain risk"
    fi
    echo "  ✓ job '$j' pinned: $uses"

    # If `with.ai-review-prompts-ref` is set on this job, it must be a
    # 40-char SHA too. Mutable refs there defeat the SHA-pinning we
    # just enforced on `uses:`.
    input_ref=$(yq -r ".jobs.\"${j}\".with.\"ai-review-prompts-ref\" // \"\"" "$f")
    if [ -n "$input_ref" ]; then
      if ! [[ "$input_ref" =~ ^[0-9a-f]{40}$ ]]; then
        fail "$f: job '$j' with.ai-review-prompts-ref='$input_ref' — must be a 40-char SHA; tag/branch refs defeat SHA-pinning"
      fi
      echo "    ✓ ai-review-prompts-ref pinned: $input_ref"
    fi
  done

  echo "  ✓ $f passed"
done

echo ""
echo "All AI-review caller workflows (claude-*.yml / gemini-*.yml) pass invariants."
