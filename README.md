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

## Packaging

The `package.json` here is intentionally marked `"private": true`. This repo is consumed via `actions/checkout` (git) rather than `npm install`, so there's no npm publication. The `package.json` exists only to pin the prettier toolchain used to format the markdown.

## License

Apache-2.0. See [LICENSE](./LICENSE).
