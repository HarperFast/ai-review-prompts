# ai-review-prompts

Layered prompt content for AI-powered code review on Harper-ecosystem repositories. Consumed by GitHub Actions workflows that run [`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action) (or equivalent) against pull requests.

> **Using the workflows in a repo that has them installed?** See [`USAGE.md`](./USAGE.md) for the day-to-day reference — what `@claude` can do, what labels trigger what, how to get a PR reviewed.

This README is for workflow _authors / maintainers_: what the layers are, how consumers compose them, and the security trade-offs.

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
  native-addon.md      # Node.js native addons (TS over an N-API C++ binding,
                       # e.g. @harperfast/rocksdb-js)
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
    # Random heredoc delimiter — collision-proof against any content a
    # future layer file might include.
    DELIM="EOF_$(openssl rand -hex 16)"
    { echo "composed<<${DELIM}"; cat "$OUT"; echo "${DELIM}"; } >> "$GITHUB_OUTPUT"
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

### Gates the examples put in place

These are the boundaries you can actually count on — explicit mechanisms, not soft guardrails:

- **`author_association` gate** at the job level — `OWNER` / `MEMBER` / `COLLABORATOR` only. Blocks external comments from spawning a runner. Also `allowed_bots: claude` on the review workflow so AI-authored PRs get reviewed by the same pipeline.
- **First-token `@claude` rule** on the mention workflow. A shell step parses the comment body and only proceeds if `@claude` is the first non-whitespace token (word-boundary after). Rules out `@claudette`, inline prose mentions, and quoted replies (`> @claude …`) where the `@claude` is addressing a human. Subsequent workflow steps guard on its output.
- **Tool allowlist** — individually scoped. `Bash(npx:*)` is absent (biggest RCE primitive); read-only git subcommands on review; broader `Bash(git:*)` on mention/issue-to-pr bounded by branch protection rather than allowlist shape.
- **Branch protection** on `main` / `release_*` / `v*.x` — load-bearing. The "don't push to main" prompt instruction is a soft guardrail; branch protection is the real one.

### Vectors to think about

- **Unfenced / unbounded user input in the prompt.** Comment body, issue title, issue body all arrive as attacker-shaped strings. The examples wrap them in code fences or inline backticks, but the fence can be escaped. Real defense is the author gate + first-token rule + tight tool allowlist — not delimiter syntax.
- **The tool allowlist IS a security boundary — but not a complete one.** Every entry is a potential RCE primitive if an injection succeeds. The examples deliberately OMIT `Bash(npx:*)` (lets the agent run arbitrary published packages). They TIGHTEN `Bash(npm install:*)` → `Bash(npm install)` (no-arg). **Important caveat:** no-arg `Bash(npm install)` blocks `npm install @attacker/<pkg>` but does NOT close the `Write(package.json)` + `postinstall` + bare `npm install` chain. A successful injection can edit `package.json` to add a malicious `postinstall` script, then invoke bare `npm install` to execute it with `GITHUB_TOKEN` and the `claude[bot]` installation token reachable from the subprocess. Mitigation options (not in the default examples, but supported):
  - Add `.npmrc` with `ignore-scripts=true` to the repos that install these workflows — blocks the postinstall path at the npm-config level.
  - Drop `Bash(npm install)` from the allowlist entirely; defer installs to a separate CI job the agent can't trigger.
  - Split issue-to-pr into read-only research + narrow-write commit steps (future follow-up).
- **Indirect injection via PR contents.** The review workflow reads agent context files (`CLAUDE.md`, `AGENTS.md`, etc.) from the PR's own checkout. A malicious PR editing those files can steer the reviewer's output. The review-side tool scope is read-only so blast radius is bounded to a misleading review; consumers who broaden the review workflow's tools should revisit this. The review prompt explicitly tells the agent to flag such edits as findings rather than honor them.
- **`GITHUB_TOKEN` is subprocess-readable.** GitHub auto-redacts it from logs, but any command the agent runs can read it from its environment. The token scope is whatever the workflow's `permissions:` block grants — keep that minimal per workflow.

### What's NOT sufficient alone

- The `author_association` gate — it narrows the population but doesn't eliminate compromised or distracted org-member accounts.
- The first-token `@claude` rule — strengthens the mention gate but doesn't replace the author-association check; they stack.
- Code fences around interpolated user content — visual hygiene, not a boundary.
- The `Must NOT push to main` section of the prompt — soft prompt guardrail, trivially overridden by a well-placed injected instruction. Branch protection does the real work.

### Minimum checklist before you enable these workflows on your repo

1. Copy the example verbatim; audit the `--allowedTools` list and prune anything you don't need.
2. Enable branch protection on `main` / `release_*` / `v*.x` with required reviews.
3. Confirm `permissions:` in each workflow is the tightest that lets the job succeed.
4. Decide your org-member trust model explicitly. If you don't trust every OWNER / MEMBER / COLLABORATOR to avoid accidentally `@claude run npx …`-ing something, tighten the gate further (named-user allowlist, separate team).

## Packaging

The `package.json` here is intentionally marked `"private": true`. This repo is consumed via `actions/checkout` (git) rather than `npm install`, so there's no npm publication. The `package.json` exists only to pin the prettier toolchain used to format the markdown.

## License

Apache-2.0. See [LICENSE](./LICENSE).
