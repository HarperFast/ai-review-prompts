#!/usr/bin/env bash
# Offline regression eval for the review prompts: replay each fixture
# (a verified production review miss, pinned by SHAs) against a chosen
# prompt ref + model, and judge whether the review now catches the
# known defect.
#
# Fixtures are metadata-only YAML in HarperFast/ai-review-log (PRIVATE
# — they describe pre-merge defects in private repos; see
# fixtures/README.md there). This script fetches them at runtime; the
# "frozen diff" is reconstructed from the pinned base/reviewed SHAs.
#
# Usage:
#   evals/run-eval.sh [--ref <ai-review-prompts ref>] [--model <id>]
#                     [--judge-model <id>] [--fixtures <id-glob>]
#                     [--baseline <path>]
#
#   --ref         prompt ref under test. Default: the checkout this
#                 script lives in (test your working tree).
#   --model       reviewer model. Default: claude-sonnet-5 (the harper
#                 canary; use claude-sonnet-4-6 for the fleet default).
#   --judge-model cheap judge. Default: claude-haiku-4-5.
#   --fixtures    only run fixture ids matching this glob.
#   --baseline    baseline results file (id: verdict lines). Exit 1 if
#                 any fixture regresses caught->missed/partial vs it.
#
# Requirements: gh (authed, with access to ai-review-log + source
# repos), yq, jq, claude CLI (authed). Runs reviews SEQUENTIALLY —
# each fixture is one real agentic review (~1-3 min).
#
# Fidelity caveats vs production (documented, accepted for v1):
#   * no PR title/body/comment context (fixtures test code-level
#     detection, not conversation reconciliation);
#   * single `claude -p` pass with a read-only tool set, not the full
#     claude-code-action harness (no prior-review continuity, no
#     posting steps);
#   * repo-specific-checks blocks from the caller workflows are not
#     included — only the shared layers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REF=""
MODEL="claude-sonnet-5"
JUDGE_MODEL="claude-haiku-4-5"
FIXTURE_GLOB="*"
BASELINE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) REF="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --judge-model) JUDGE_MODEL="$2"; shift 2 ;;
    --fixtures) FIXTURE_GLOB="$2"; shift 2 ;;
    --baseline) BASELINE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

for bin in gh yq jq claude git; do
  command -v "$bin" >/dev/null || { echo "missing: $bin" >&2; exit 2; }
done

# GNU timeout on Linux, gtimeout via coreutils on macOS, perl fallback.
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
run_with_timeout() {
  local secs="$1"; shift
  if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" "$secs" "$@"
  else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

CACHE="${EVAL_CACHE:-$HOME/.cache/ai-review-evals}"
mkdir -p "$CACHE/repos"
OUT_DIR="$REPO_ROOT/evals-out/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT_DIR"

# --- prompts checkout under test -------------------------------------
if [ -n "$REF" ]; then
  PROMPTS_DIR="$CACHE/prompts-$REF"
  if [ ! -d "$PROMPTS_DIR/.git" ]; then
    gh repo clone HarperFast/ai-review-prompts "$PROMPTS_DIR" -- --quiet
  fi
  git -C "$PROMPTS_DIR" fetch --quiet origin
  git -C "$PROMPTS_DIR" checkout --quiet "$REF"
else
  PROMPTS_DIR="$REPO_ROOT"
  REF="$(git -C "$REPO_ROOT" rev-parse --short HEAD)(working-tree)"
fi

# --- fixtures ---------------------------------------------------------
FIXTURES_DIR="$CACHE/ai-review-log"
if [ ! -d "$FIXTURES_DIR/.git" ]; then
  gh repo clone HarperFast/ai-review-log "$FIXTURES_DIR" -- --quiet --depth 1
else
  git -C "$FIXTURES_DIR" pull --quiet --ff-only
fi
[ -d "$FIXTURES_DIR/fixtures" ] || { echo "no fixtures/ dir in ai-review-log" >&2; exit 2; }

RESULTS="$OUT_DIR/results.tsv"
: > "$RESULTS"

echo "prompt ref: $REF"
echo "reviewer:   $MODEL   judge: $JUDGE_MODEL"
echo

shopt -s nullglob
for fy in "$FIXTURES_DIR"/fixtures/$FIXTURE_GLOB.yml; do
  id="$(yq -r '.id' "$fy")"
  repo="$(yq -r '.source_repo' "$fy")"
  pr="$(yq -r '.pr' "$fy")"
  reviewed="$(yq -r '.reviewed_sha' "$fy")"
  base="$(yq -r '.base_sha' "$fy")"
  defect="$(yq -r '.defect' "$fy")"

  echo "── $id ($repo#$pr @ ${reviewed:0:8})"

  # source checkout at the reviewed head
  rdir="$CACHE/repos/${repo##*/}"
  if [ ! -d "$rdir/.git" ]; then
    gh repo clone "$repo" "$rdir" -- --quiet
  fi
  git -C "$rdir" fetch --quiet origin "pull/$pr/head" 2>/dev/null || true
  git -C "$rdir" cat-file -e "$reviewed" 2>/dev/null || git -C "$rdir" fetch --quiet origin "$reviewed"
  # Standalone clone containing ONLY the reviewed commit's ancestry —
  # a shared worktree would expose post-review refs (incl. the fix
  # commit) via `git log --all`, letting the reviewer see the future.
  # Production reviews can never see past the PR head; neither may evals.
  wdir="$CACHE/worktrees/$id"
  rm -rf "$wdir"
  git -C "$rdir" branch -f eval-tmp "$reviewed"
  git clone --quiet --single-branch --branch eval-tmp "$rdir" "$wdir"
  git -C "$wdir" checkout --quiet --detach "$reviewed"
  git -C "$wdir" branch -D eval-tmp >/dev/null
  git -C "$wdir" remote remove origin
  git -C "$rdir" branch -D eval-tmp >/dev/null

  # composed layer scope at the ref under test
  layers="$(yq -r ".repos.\"$repo\".layers[]" "$SCRIPT_DIR/repos.yml")"
  LAYERS="$layers" LAYERS_DIR="$PROMPTS_DIR" GITHUB_OUTPUT=/dev/null \
    bash "$PROMPTS_DIR/.github/scripts/compose-review-scope.sh" >/dev/null
  scope="$(cat /tmp/composed-scope.md)"

  git -C "$wdir" diff "$base" "$reviewed" > "$wdir/.eval-diff.patch"

  prompt_file="$OUT_DIR/$id.prompt.md"
  {
    echo "You are reviewing a pull request. Your working directory is the repository checked out at the PR head. The full diff under review is in .eval-diff.patch (base ${base:0:8} -> head ${reviewed:0:8}); you may also use git and read files to trace code."
    echo
    echo "Apply the following review scope EXACTLY — it defines what to flag, what to ignore, severity discipline, and output format:"
    echo
    echo "$scope"
    echo
    echo "Output the review now: blocker findings with file:line and rationale (plus up to 3 non-blocking Suggestions), or the one-sentence 'No blockers found.' clean pass. Output ONLY the review text."
  } > "$prompt_file"

  review_file="$OUT_DIR/$id.review.md"
  if ! (cd "$wdir" && run_with_timeout 1500 claude -p "$(cat "$prompt_file")" \
        --model "$MODEL" \
        --allowedTools "Read,Grep,Glob,Bash(git log:*),Bash(git diff:*),Bash(git show:*),Bash(cat:*)" \
        ) > "$review_file" 2>"$OUT_DIR/$id.stderr"; then
    echo -e "$id\tERROR\treview run failed" >> "$RESULTS"
    echo "   ERROR (review run failed — see $id.stderr)"
    continue
  fi

  judge_file="$OUT_DIR/$id.judge.json"
  judge_prompt="$(cat "$SCRIPT_DIR/judge-prompt.md")

## Known defect
$defect

## Review output under judgment
$(cat "$review_file")"
  if ! run_with_timeout 300 claude -p "$judge_prompt" --model "$JUDGE_MODEL" \
       > "$judge_file.raw" 2>/dev/null; then
    echo -e "$id\tERROR\tjudge run failed" >> "$RESULTS"
    echo "   ERROR (judge run failed)"
    continue
  fi
  # tolerate fenced or prose-wrapped JSON
  verdict="$(sed -n 's/.*"verdict"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' "$judge_file.raw" | head -1)"
  evidence="$(sed -n 's/.*"evidence"[[:space:]]*:[[:space:]]*"\(.*\)"[}].*/\1/p' "$judge_file.raw" | head -1)"
  [ -n "$verdict" ] || verdict="UNPARSEABLE"
  echo -e "$id\t$verdict\t$evidence" >> "$RESULTS"
  echo "   $verdict — $evidence"
done

echo
echo "== summary ($REF, $MODEL) =="
for v in caught partial missed ERROR UNPARSEABLE; do
  n="$(cut -f2 "$RESULTS" | grep -cx "$v" || true)"
  [ "$n" -gt 0 ] && echo "  $v: $n"
done
echo "results: $RESULTS"

# --- baseline regression gate ----------------------------------------
if [ -n "$BASELINE" ] && [ -f "$BASELINE" ]; then
  regressed=0
  while IFS=$'\t' read -r id verdict _; do
    prev="$(grep -E "^$id[[:space:]]" "$BASELINE" | cut -f2 || true)"
    if [ "$prev" = "caught" ] && [ "$verdict" != "caught" ]; then
      echo "REGRESSION: $id was caught in baseline, now $verdict" >&2
      regressed=1
    fi
  done < "$RESULTS"
  exit "$regressed"
fi
