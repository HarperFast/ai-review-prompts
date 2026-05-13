#!/usr/bin/env bash
# Validate auth-gate and supply-chain invariants on every reusable
# workflow of the shape `_<provider>-{review,mention,issue-to-pr}.yml`
# in this repo.
#
# Two classes of checks:
#
# 1. Auth-gate structural invariants (checks 1-7) — the authorize
#    job exists, wires its outputs correctly, uses the App-token
#    action pinned to a SHA, has minimal permissions, references
#    the right secrets, sets USERS_TO_CHECK, and every non-authorize
#    job gates on `needs.authorize.outputs.authorized == 'true'`
#    without `||` short-circuits.
#
# 2. Supply-chain pinning (check 8) — third-party Docker image
#    references must use `@sha256:` digest, not `:tag`. Same
#    discipline already applied to GitHub Actions versions via
#    `@<40-char-sha>` pinning; this extends it to images referenced
#    from MCP server configs, service containers, etc.
#
# STRUCTURAL lint, not a semantic test — catches the obvious attacks
# (delete the authorize job, drop the `needs:` dependency, broaden
# permissions, weaken the if-expression to admit unauthorized runs,
# reference an unpinned image whose tag could be silently repointed).
# Subtle attacks (e.g., modifying the bash logic inside the auth
# check to admit everyone) are out of scope for this validator and
# are caught by CODEOWNERS review on `.github/` changes.
#
# This validator lives in HarperFast/ai-review-prompts and runs on
# PRs that touch the reusable workflows or their scripts. Consumer
# repos call the reusables via
# `uses: HarperFast/ai-review-prompts/.github/workflows/_*-{...}.yml@<sha>`
# — there's no per-consumer authorize job to validate, the auth gate
# code lives here.
#
# Defense in depth: branch-protection on this repo's `main` should
# make this workflow's job a REQUIRED status check.
#
# Inputs (none — runs in the workflow checkout). Validates:
#   .github/workflows/_*-review.yml
#   .github/workflows/_*-mention.yml
#   .github/workflows/_*-issue-to-pr.yml
#
# Exit code:
#   0  all workflows pass
#   1  any check failed (errors emitted as ::error::)
set -uo pipefail

fail() {
  echo "::error::$1"
  exit 1
}

# yq is pre-installed on ubuntu-latest runners.
command -v yq >/dev/null || fail "yq not available on runner"

# Pattern-based file enumeration: every reusable that follows the
# `_<provider>-{review,mention,issue-to-pr}.yml` convention gets
# validated. New providers added by following the naming
# convention are picked up automatically; the validator's coverage
# doesn't drift as we onboard more reviewers.
shopt -s nullglob
files=(
  .github/workflows/_*-review.yml
  .github/workflows/_*-mention.yml
  .github/workflows/_*-issue-to-pr.yml
)
if [ "${#files[@]}" -eq 0 ]; then
  echo "No auth-gated reusable workflows found; nothing to validate."
  exit 0
fi

for f in "${files[@]}"; do
  echo ""
  echo "=== Validating $f ==="

  # 1. The authorize job exists.
  yq -e '.jobs.authorize' "$f" >/dev/null \
    || fail "$f: missing 'authorize' job"

  # 2. authorize.outputs.authorized is wired to some step output.
  output_expr=$(yq -r '.jobs.authorize.outputs.authorized // ""' "$f")
  [ -n "$output_expr" ] \
    || fail "$f: authorize job has no outputs.authorized"
  echo "$output_expr" | grep -q 'steps\..*\.outputs\.authorized' \
    || fail "$f: authorize.outputs.authorized must come from a step output (got: $output_expr)"

  # 3. authorize uses actions/create-github-app-token (pinned to a SHA).
  app_token_step=$(yq -r '.jobs.authorize.steps[] | select(.uses != null) | .uses' "$f" | grep '^actions/create-github-app-token@' || true)
  [ -n "$app_token_step" ] \
    || fail "$f: authorize doesn't use actions/create-github-app-token"
  echo "$app_token_step" | grep -qE '@[0-9a-f]{40}( |$)' \
    || fail "$f: actions/create-github-app-token must be pinned to a 40-char SHA (got: $app_token_step)"

  # 4. authorize.permissions doesn't grant any write-level scope.
  write_perms=$(yq -r '.jobs.authorize.permissions | (.[] // "") | select(. == "write")' "$f" 2>/dev/null || true)
  [ -z "$write_perms" ] \
    || fail "$f: authorize.permissions grants 'write' on at least one scope — auth job must be read-only"

  # 5. Required secrets are referenced (the auth check can't work without them).
  grep -q 'HARPERFAST_AI_CLIENT_ID' "$f" \
    || fail "$f: HARPERFAST_AI_CLIENT_ID secret not referenced"
  grep -q 'HARPERFAST_AI_APP_PRIVATE_KEY' "$f" \
    || fail "$f: HARPERFAST_AI_APP_PRIVATE_KEY secret not referenced"

  # 6. The authorize job sets USERS_TO_CHECK on at least one of its
  #    steps. The auth script (`authorize-ai-workflow.sh`) fails
  #    closed if USERS_TO_CHECK is empty, but the workflow still
  #    shouldn't ship without it — make the omission a structural
  #    error rather than a silent runtime denial. Defense in depth
  #    against a PR that drops the env var thinking the script will
  #    "do the right thing".
  #
  # NOTE: yq on ubuntu-latest is mikefarah/yq (Go), not jq. It does
  # NOT support jq's `empty` keyword, and an earlier version of this
  # check using `// empty` lexer-erred silently (`2>/dev/null` ate it)
  # and produced a false fail on workflows that DID set the env var.
  # `select(. != null)` is the idiomatic yq filter for "skip steps
  # without this env var"; `head -1` collapses the per-step stream to
  # a single value (or empty).
  users_to_check=$(yq -r '.jobs.authorize.steps[].env.USERS_TO_CHECK | select(. != null)' "$f" 2>/dev/null | head -1)
  [ -n "$users_to_check" ] \
    || fail "$f: authorize job has no step setting USERS_TO_CHECK env var — the auth script needs at least one login to check (PR author, commenter, labeler, etc.)"

  # 7. Every non-authorize job has `needs: authorize` and an
  #    if-expression that REQUIRES the auth check.
  #
  #    Rule: the if MUST contain the literal substring
  #    `needs.authorize.outputs.authorized == 'true'` AND MUST NOT
  #    contain `||`. Additional `&&` conjuncts (e.g. checking for
  #    an optional secret like GEMINI_API_KEY before running the
  #    review job) are allowed because `&&` is strictly more
  #    restrictive — false on the new term still blocks the job.
  #    `||` is banned because it could short-circuit the auth
  #    check (`auth == 'true' || true` is the classic attack).
  other_jobs=$(yq -r '.jobs | keys | .[]' "$f" | grep -v '^authorize$' || true)
  [ -n "$other_jobs" ] \
    || fail "$f: no non-authorize job found — workflow has nothing gated"

  for j in $other_jobs; do
    needs=$(yq -r ".jobs.${j}.needs // \"\"" "$f")
    [ "$needs" = "authorize" ] \
      || fail "$f: job '$j' must have 'needs: authorize' (got: $needs)"

    if_expr=$(yq -r ".jobs.${j}.if // \"\"" "$f")
    # Normalize whitespace for the substring check.
    normalized=$(echo "$if_expr" | tr -s ' ' | tr -d "\n")
    required="needs.authorize.outputs.authorized == 'true'"
    echo "$normalized" | grep -qF "$required" \
      || fail "$f: job '$j' if: must include \"$required\" (got: $if_expr)"
    if echo "$normalized" | grep -qF '||'; then
      fail "$f: job '$j' if: contains '||' — only && conjuncts allowed to keep the auth check load-bearing (got: $if_expr)"
    fi
  done

  # 8. Third-party Docker image references MUST be pinned by
  #    `@sha256:` digest, not by `:tag`. Same supply-chain
  #    discipline as GitHub Actions SHA-pinning — image tags are
  #    mutable and can be silently repointed to malicious content
  #    by the registry owner or anyone who compromises their
  #    credentials. The digest is content-addressed and immutable.
  #
  #    The regex matches `<registry>/<path>:<tag>` shapes for the
  #    common registries we'd realistically use; digest-form refs
  #    (`<registry>/<path>@sha256:<hex>`) don't match (no `:tag`
  #    suffix after the path), so passing refs are silently OK.
  #    Failing refs surface here with file:line context.
  #
  #    A digest-form ref CAN appear in the same line as the
  #    matching context (e.g. a Docker `args` array that lists
  #    `["run", "-i", "--rm", "<image>@sha256:..."]` on one
  #    logical line); the regex's path/colon shape distinguishes.
  #
  #    URLs (e.g. https://ghcr.io/v2/<image>/manifests/v1.0.4) do
  #    NOT match because the manifests path doesn't end in
  #    `:<tag>` — the tag-shaped match requires a colon
  #    immediately after the path. This is verified empirically;
  #    if a real-world false positive emerges, refine the regex
  #    rather than relaxing the check.
  unpinned=$(grep -nE '(ghcr\.io|quay\.io|docker\.io|registry\.k8s\.io|mcr\.microsoft\.com|public\.ecr\.aws)/[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)*:[a-zA-Z0-9._-]+' "$f" || true)
  if [ -n "$unpinned" ]; then
    echo "::error::$f: Docker image references must be pinned by @sha256: digest, not by tag. Tags are mutable; same supply-chain discipline as GitHub Actions SHA-pinning."
    echo "  Unpinned reference(s):"
    printf '%s\n' "$unpinned" | sed 's/^/    /'
    echo ""
    echo "  To fetch a digest from GHCR:"
    echo "    GHCR_TOKEN=\$(curl -sSL \"https://ghcr.io/token?scope=repository:<org>/<image>:pull&service=ghcr.io\" | jq -r .token)"
    echo "    curl -sSI -H \"Authorization: Bearer \$GHCR_TOKEN\" \\"
    echo "      -H \"Accept: application/vnd.oci.image.index.v1+json\" \\"
    echo "      \"https://ghcr.io/v2/<org>/<image>/manifests/<tag>\" \\"
    echo "      | grep -i docker-content-digest"
    echo "  Then reference as: <image>@sha256:<digest>"
    fail "$f: unpinned Docker image reference(s) found"
  fi

  echo "  ✓ $f passed"
done

echo ""
echo "All auth-gated reusable workflows pass auth gate invariants."
