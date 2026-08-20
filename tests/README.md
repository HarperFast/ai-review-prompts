# Script tests

Zero-dependency bash unit tests for the logic in `.github/scripts/`.

```sh
npm test          # or: bash tests/run.sh
```

`tests/run.sh` runs every `tests/*.test.sh` in its own process and exits
non-zero if any fail. CI runs it via `.github/workflows/tests.yml` on
every PR (no `paths:` filter — so it can safely be a required check; see
the workflow header). No framework / dependency — just bash + the
`tests/lib.sh` assertion helpers.

## Scope: deterministic and offline

Pure text/file transforms run directly. Scripts that orchestrate `gh` or
`curl` run against small PATH-injected fixture binaries; tests never use the
network or mutate GitHub state. This keeps pagination and failure branches
repeatable while the draft PR supplies the live workflow check.

- `compose-review-scope.sh` — layer files → composed scope
- `parse-claude-mention.sh` — comment body → proceed / model decision
- `split-gemini-response.sh` — review response → head + tail file at a
  whole-line sentinel; default run-notes marker, `MARKER`-overridable to
  also peel the inline-comments block (the workflow chains two calls)
- `post-inline-comments.sh` — its pure helpers only (`badge_for`,
  `item_key`, `format_body`): severity badge, dedup key, comment-body
  shape. Sourced past its `BASH_SOURCE`-guarded `main`, so no network.
- `fetch-review-context.sh` — paginated GraphQL pages → explicit complete,
  partial, or unavailable thread snapshot
- `fetch-curated-supplement.sh` — curated issue + all comment pages → weekly
  calibration supplement
- `classify-review-run.sh` — execution/head state → current, superseded,
  head-unverified, or invalid classification
- `log-review-to-ai-review-log.sh` and `post-review-comment.sh` — run binding,
  immutable metadata, title safety, and failure behavior via fixture CLIs
- `workflow-contract.test.sh` — static cross-file assertions that keep the
  prompts, reusable workflows, calibration prefetch, and logger aligned

`find-prior-review-comment.sh` and the network-facing main path of
`post-inline-comments.sh` remain covered by live review dogfood; their pure
selection/formatting helpers are tested here where applicable.

## Adding a test

Create `tests/<name>.test.sh`:

```sh
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
SCRIPT="$DIR/../.github/scripts/<name>.sh"

# ... run SCRIPT with controlled env/inputs, then:
assert_eq    "$got" "$want" "message"
assert_contains "$haystack" "$needle" "message"
assert_status "$?" 0 "message"

t_summary    # last line — its exit status is the file's result
```

New `.github/scripts/*.sh` with real branching logic should ship with a
matching test.
