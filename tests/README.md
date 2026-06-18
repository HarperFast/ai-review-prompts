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

## Scope: pure logic only

These cover scripts that are deterministic text/file transforms — no
`gh`, no network, no mocking:

- `compose-review-scope.sh` — layer files → composed scope
- `parse-claude-mention.sh` — comment body → proceed / model decision
- `split-gemini-response.sh` — review response → head + tail file at a
  whole-line sentinel; default run-notes marker, `MARKER`-overridable to
  also peel the inline-comments block (the workflow chains two calls)
- `post-inline-comments.sh` — its pure helpers only (`badge_for`,
  `item_key`, `format_body`): severity badge, dedup key, comment-body
  shape. Sourced past its `BASH_SOURCE`-guarded `main`, so no network.

The **gh-orchestration** scripts (`post-review-comment.sh`,
`find-prior-review-comment.sh`, `log-review-to-ai-review-log.sh`, and the
`main` of `post-inline-comments.sh`) are intentionally **not** unit-tested
here — they're thin wrappers over `gh api` and are exercised end-to-end by
the live review dogfood on every PR. If a pure, branch-y helper is
extracted from one of them, add a test (as `post-inline-comments.sh`
does for its formatting helpers).

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
