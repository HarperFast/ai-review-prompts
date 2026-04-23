# ai-review-prompts

Layered prompt content for AI-powered code review on Harper-ecosystem repositories. Consumed by GitHub Actions workflows that run [`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action) (or equivalent) against pull requests.

Each layer is a short markdown document that reads as **review guidance**. Workflows compose a selection of layers into a single prompt, so a reviewer bot gets exactly the checklist relevant to the repo it's reviewing — architecture + security for every PR, Harper-version conventions for Harper repos, and repo-type-specific rules on top (plugin, core, app, etc.).

## Layout

```
universal.md           # architecture, security, dispatch surfaces, testing,
                       # output discipline — applies to EVERY reviewed repo
harper/
  common.md            # Harper gotchas that cross versions
  v5.md                # v5-specific (harper package, Resource API v2,
                       # static vs instance dispatch, Fabric deployment)
repo-type/
  plugin.md            # npm-published Harper plugins
examples/
  claude-review.yml    # reference GitHub Actions workflow
  claude-mention.yml
  claude-issue-to-pr.yml
```

New `repo-type` layers land in this repo as they're calibrated against a real repo's PR stream. Until then, consumers compose from `universal` + `harper/*` and add a repo-specific addendum inline in their own workflow's prompt — see the examples.

## How a consumer workflow composes these

At the job level, declare the layers that apply via an env var:

```yaml
env:
  REVIEW_LAYERS: |
    universal
    harper/common
    harper/v5
    repo-type/plugin
```

Check out this repo into a subpath, then concatenate the declared layer files into a single prompt block:

```yaml
- name: Clone review prompts
  uses: actions/checkout@<pinned-sha> # pin your action versions
  with:
    repository: HarperFast/ai-review-prompts
    ref: <pinned-sha-or-tag> # pin — don't track main
    path: .ai-review-prompts

- name: Compose review scope from layers
  id: scope
  env:
    LAYERS: ${{ env.REVIEW_LAYERS }}
  run: |
    set -euo pipefail
    OUT=/tmp/composed-scope.md
    : > "$OUT"
    while IFS= read -r raw_layer; do
      layer="$(printf '%s' "$raw_layer" | awk '{$1=$1;print}')"
      [ -z "$layer" ] && continue
      file=".ai-review-prompts/${layer}.md"
      if [ ! -f "$file" ]; then
        echo "::warning::Review layer '$layer' not found at $file; skipping."
        continue
      fi
      { cat "$file"; printf '\n\n'; } >> "$OUT"
    done <<< "$LAYERS"
    { echo 'composed<<CLAUDE_SCOPE_EOF'; cat "$OUT"; echo 'CLAUDE_SCOPE_EOF'; } >> "$GITHUB_OUTPUT"
```

Inject `${{ steps.scope.outputs.composed }}` into the `prompt:` input of your Claude review step. See `examples/claude-review.yml` for a complete workflow you can copy and adapt.

## Pinning

**Pin to a SHA or a tag, not `main`.** Review behavior is meant to be reproducible across runs; bumping the pin is how you adopt changes intentionally.

## Writing / editing layers

- Each bullet should be something a reviewer can check on a PR — specific, not generic.
- Tag check severity explicitly (e.g. ending a bullet with `Blocker.` when the check should produce a blocker finding rather than a nit).
- Keep layers tight (aim for ~1–2 KB each). Every included layer is read into the LLM prompt on every review; bigger layers are slower and more token-expensive.

## Relationship to other HarperFast repos

- `HarperFast/skills` is the customer-facing authoring guidance for building on Harper. If a review check here contradicts a skill there, the skill is authoritative for authors; this repo's job is reviewer discipline. When in doubt, link from a layer here to the relevant skill.
- `HarperFast/ai-review-log` is where PR review findings are logged as GitHub Issues. Separate concern from these prompts — that repo is the output side, this repo is the input side.

## Security: reading the example workflows critically

The example workflows interpolate user-controlled input (comment bodies, issue titles and bodies) into the prompt that drives an agent with `Write`, `Edit`, and shell tools. That is a prompt-injection surface even behind an author-association gate. The examples mitigate the obvious shape by fencing multi-line bodies in code blocks and keeping the tool allowlist tight, but **fences are cosmetic — a determined commenter can close them and inject what reads like template-author instructions.** Consumers should adopt these workflows with that in mind.

### Vectors to think about

- **Unfenced / unbounded user input in the prompt.** Comment body, issue title, issue body all arrive as attacker-shaped strings. The examples wrap them in code fences or inline backticks, but the fence can be escaped. The real defense is the author gate combined with a tight tool allowlist — not delimiter syntax.
- **The tool allowlist IS a security boundary.** Every entry there is a potential RCE primitive if an injection succeeds. The examples deliberately OMIT `Bash(npx:*)` (lets the agent run arbitrary published packages) and use `Bash(npm install)` (bare, no-args) rather than `Bash(npm install:*)` (arbitrary packages) for that reason. If you add either back, understand what you're accepting.
- **Indirect injection via PR contents.** The review workflow reads agent context files (`CLAUDE.md`, `AGENTS.md`, etc.) from the PR's own checkout. A malicious PR editing those files can steer the reviewer's output. The review-side tool scope is read-only so blast radius is bounded to a misleading review, but consumers who broaden the review workflow's tools should revisit this.
- **`GITHUB_TOKEN` is subprocess-readable.** GitHub auto-redacts it from logs, but any command the agent runs can read it from its environment. The token scope is whatever the workflow's `permissions:` block grants — keep that minimal per workflow.
- **Branch protection is load-bearing.** The "Must NOT push to main" guidance in the issue-to-pr example is a soft guardrail; the actual guarantee comes from GitHub branch protection + required reviews on your default and release branches. Enable those.

### What's NOT sufficient alone

- The `author_association` gate — it narrows the population but doesn't eliminate compromised or distracted org-member accounts.
- Code fences around interpolated user content — visual hygiene, not a boundary.
- The `Must NOT` section of the prompt — soft prompt guardrail, trivial to override with a well-placed injected instruction.

### Minimum checklist before you enable these workflows on your repo

1. Copy the example verbatim; audit the `--allowedTools` list and prune anything you don't need.
2. Enable branch protection on `main` / `release_*` / `v*.x` with required reviews.
3. Confirm `permissions:` in each workflow is the tightest that lets the job succeed.
4. Decide your org-member trust model explicitly. If you don't trust every OWNER / MEMBER / COLLABORATOR to avoid accidentally `@claude run npx …`-ing something, tighten the gate further (named-user allowlist, separate team).

## Packaging

The `package.json` here is intentionally marked `"private": true`. This repo is consumed via `actions/checkout` (git) rather than `npm install`, so there's no npm publication. The `package.json` exists only to pin the prettier toolchain used to format the markdown.

## License

Apache-2.0. See [LICENSE](./LICENSE).
