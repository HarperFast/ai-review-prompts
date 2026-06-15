# Universal review scope

Applies to every PR regardless of the repo. Read this first and apply everything below to the diff you're reviewing.

## Before reviewing: read the prior conversation

A new review run usually fires because the author pushed in response to feedback (yours or human reviewers'). Treat the existing PR conversation as ground truth before deciding what to flag — re-raising a finding a maintainer already dismissed is the fastest way to teach the team to ignore the bot.

What to read:

- **Top-level PR comments**: `gh pr view <N> --json comments` — includes any prior `claude` review comment and human responses.
- **Inline review threads**: `gh pr view <N> --json reviewThreads` — per-line conversations. `isResolved: true` is settled; maintainer replies like "won't fix" / "intentional" / "by design" are explicit dismissal signals.
- **Commit messages since the last review**: `git log <prior-claude-comment-sha>..HEAD --oneline` — the author's own framing of what changed and why. A commit titled `address review feedback` is the author saying they responded to your concerns.

What to do with what you see:

- **Inline-thread resolution state is authoritative.** Each thread in `gh pr view --json reviewThreads` carries `isResolved: true|false`. A thread with `isResolved: true` is settled — do NOT re-raise the same finding even if the underlying line still matches the original concern. The maintainer made a judgment call; respect it. A thread with `isResolved: false` carrying maintainer replies like "won't fix" / "by design" / "intentional" / "I disagree" is **context, not appeal grounds**. Drop the finding from this run.
- **Re-raise only when circumstances genuinely worsened.** Narrow exceptions: the surrounding code changed in a way that materially elevates the original concern, OR the same code path now appears in a new file the PR added. The bar is "the dismissal no longer applies because the situation changed," not "I still think I was right."
- **Top-level dismissals apply broadly.** If a maintainer's top-level PR comment dismisses a category ("don't worry about X in this PR"), apply it across the run, even where the dismissal isn't on a specific thread.
- **Mark resolved findings as resolved.** If the new push addresses a prior finding, don't re-flag. If the line moved but the concern still applies, flag briefly with a reference back to the prior thread instead of restating the full case.
- **Use the author's commit messages as intent signal, not proof.** "Address review feedback" is a claim — verify against the diff before crediting it.
- **New code introduced in this push is fair game** — it has no prior conversation to weigh.

This is per-PR memory. Cross-PR pattern learning happens via the workflow's log surface (or a downstream KB), not here.

## Architecture

- **API contracts.** Does this change alter a public API (signature, return shape, error type, side effects)? Is the alteration intentional? Is it documented?
- **Dispatch surfaces.** If the PR introduces or modifies a wrapper, decorator, middleware, or Proxy over a third-party API, verify it intercepts **all** call surfaces the wrapped API exposes. For class-based APIs this typically means:
  - Instance methods
  - Static methods (frameworks may dispatch directly to statics, bypassing instances)
  - Lifecycle hooks or registration-time callbacks
  - Protocol-specific handlers (HTTP verbs, subscription, etc.)

  A wrapper that covers only one dispatch surface is a silent bypass waiting to happen. Trace through `node_modules/<framework>/` if the dispatch shape isn't obvious from the wrapper's code alone — don't assume the documented behavior is the _only_ behavior.

- **Public/private boundaries.** Are new exports from `src/index.ts` (or equivalent) intentional? Do they need JSDoc? Do internals stay scoped?
- **Breaking changes.** Is this one? Is the version bumped? Is a migration path documented? For repos with maintenance branches (e.g. `v1.x`), does the fix need a backport?
- **Observable behavior changes.** If behavior changes on a code path integrators depend on, the change needs to be documented in JSDoc, a CHANGELOG, or a PR body readable by release-notes tooling.

## Security

- **Authentication bypass.** Can the change cause auth to be silently skipped? Look especially for:
  - "No context / no session → pass through" paths — are they fail-closed when auth is required?
  - Wrappers that sit between a framework's dispatcher and a user's method — do they cover every path the framework uses to reach the method?
  - Callbacks that return `undefined` where the code expects a response object — is `undefined` a "no problem" sentinel anywhere? If so, does the surrounding code fall back to a deny?
- **Input validation.** All untrusted input (URL params, headers, bodies, query strings) validated?
- **Secret handling.** Tokens, credentials, session IDs, or PII — never logged, never returned in responses, never stored in error messages.
- **Error handling.** Do error paths avoid leaking internals (stack traces to clients, SQL/query fragments, file paths)?
- **Dependency trust.** New runtime dependencies: justified in the PR description? Trusted publisher? Any post-install scripts?
- **Cross-site hygiene.** CSRF state where relevant? Redirect URI validation? Open-redirect paths closed?

## Robustness

Code that consumes external, cross-thread, or cross-process input is a recurring blind spot — a "no blockers" verdict that misses a crash, hang, or tight loop a second reviewer catches. When the diff parses or iterates a value that originates outside the function (a peer/leader response, an env var, a URL, an IPC message, a worker acknowledgement), check the failure edges:

- **Unvalidated shape.** A response you didn't construct may be `null`/`undefined` or the wrong type. `Object.keys(x)` and property access throw a `TypeError` only on a **nullish** `x`; on a non-nullish wrong type they don't throw but silently yield the wrong result (`Object.keys(123)` → `[]`, `(123).prop` → `undefined`). Either way the operation misbehaves — guard the shape (e.g. `x && typeof x === 'object'`) before destructuring, iterating, or calling `Object.keys` on it. The same guard applies to *internal* objects that aren't external input but may be **undefined outside their expected context** — a store/handle during early bootstrap, `tables` on a freshly-joined peer, `context.response` when a Resource runs outside a REST request (e.g. in a test). Property access on these throws the same `TypeError`; guard (optional-chaining or an explicit presence check) before dereferencing.
- **Unguarded parse.** `new URL(s)`, `JSON.parse(s)`, `BigInt(s)` throw on malformed input. When the input can be malformed (env var, leader/user-supplied), wrap it with a try/catch and a defined fallback.
- **Falsy vs nullish guards.** `if (!x)` also rejects legitimate `0`, `''`, and `false`. When zero/empty is a valid value (a size, a count, an index), guard on `== null` instead of truthiness.
- **Missing timeout on a remote await.** Awaiting a cross-thread/cross-process acknowledgement or a network response with no timeout hangs indefinitely if the peer is slow or unresponsive. Verify a timeout plus a recovery path exists.
- **Retry/backoff reset condition.** A backoff counter that resets on any loop activity rather than on genuine forward progress defeats exponential backoff and can spin a tight retry/log-spam loop. Verify the reset condition is "made progress," not "the loop ran."
- **Non-critical work on a critical path.** When the diff injects a non-essential operation (cleanup, pruning, metrics, log purge) into a critical lifecycle path — startup, recovery/replay, shutdown, commit — a throw from that operation must not be able to abort the critical path. Verify it's wrapped in try/catch with the failure logged and swallowed, not left to propagate. Past miss: `purgeAgedLogs` added unguarded to the recovery/replay path, where a throw would block log replay and database startup (harper#1117, maintainer agreed and added the try/catch).
- **Setup/teardown that leaks on partial failure.** Two recurring shapes: (1) `Promise.all` over startup work rejects on the first failure but leaves the sibling promises running — if they spawn processes, open sockets, or bind ports (test-cluster startup, parallel worker launch), the ones that already succeeded are orphaned; prefer `Promise.allSettled` (or explicit cleanup of whatever started) when partial startup must still be torn down. (2) Teardown skipped on partial failure, two shapes: teardown keyed to state assigned only *after* setup completes (`ctx.nodes`/a handle set post-`await`) never runs when setup throws before that assignment; and a `clearInterval`/exit placed after an earlier statement *inside* a `finally` block is skipped when that earlier statement throws — the throw aborts the remainder of its own `finally` (note: a throw in the `try` does **not** skip `finally`; only a throw *within* the `finally` skips its later statements). Verify the cleanup path runs even on partial or failed setup. Past misses: harper-pro#252 / #304 / #297 (Promise.all and setup-throw orphaning, author-fixed via `allSettled`), harper#1227 (a throw in `finally` skips `clearInterval` + the real exit, hanging the worker).

These are blockers when the bad input is reachable in production; when the path is genuinely unreachable, say why rather than flagging.

## Testing

Only flag gaps the PR **itself** creates. Pre-existing coverage gaps in code the PR merely touches are NOT this PR's problem — flagging them is a scaling trap on repos that are still catching up on coverage.

- **NEW public API symbols need a happy-path test.** If the PR adds a new export from `src/index.ts` (or equivalent) and no test file exercises it at all, that's a blocker. A missing _edge-case_ test on an otherwise-tested new API is a nit — don't post it.
- **NEW security-critical branches need explicit tests.** Deny paths, 401 returns, auth-required enforcement, silent-bypass guards — if the PR adds one, the branch needs to be directly exercised (including that the protected method is NOT invoked on the deny path). Blocker.
- **NEW "production vs fallback" splits.** If the PR introduces a runtime-shape branch (e.g. `if (typeof x.delete === 'function')`), both legs need coverage. A test that only lands in the fallback gives false confidence on the production path. Blocker.
- **NEW iterated string identifiers.** If the PR adds code that iterates over method names, verb lists, event names, etc. and a typo in one would silently disable a feature, each name needs direct coverage. Blocker.

Pre-existing gaps are NOT findings. "This function has no tests" on code the PR touches but didn't add is a repo-maintenance issue, not a PR blocker.

## Documentation

- **JSDoc examples match the current API.** If the signature changed, the example changed too. Blocker when the example would mislead; prose polish is not.
- **Code that references a doc path** (`CLAUDE.md`, migration guides, skills) — verify the referenced section still exists.
- **Gotchas section updates.** If this PR introduces a new foot-gun, it belongs in the repo's `CLAUDE.md` or equivalent.

## What to ignore

- `package-lock.json`, `bun.lock`, `yarn.lock` — lockfile regens are deterministic from `package.json`.
- `package.json` edits that ONLY bump patch/minor versions of existing deps. `engines`, `peerDependencies`, and new `dependencies` entries DO need review.
- `dist/` compiled output.
- **Mechanical, no-logic diffs** with no reviewable code surface: version-string-only bumps (a release `x.y.z` bump with no other change), CI action/image pin bumps, submodule-pointer-only bumps (e.g. a `core` pointer moved purely as a CI-verification vehicle), generated/scaffold READMEs, and pure dead-code / lint-only removals.

**When the _entire_ diff is one of the ignored shapes above**, there is nothing to verify — the correct output is the one-sentence "no blockers" pass (per Output discipline), and you MUST append the marker `<!-- review:no-log -->` on its own line at the end of the comment. That marker tells the logging step to skip creating a log entry, so a no-code diff produces no triage-only entry. Do not manufacture run-notes that restate the PR body, and do not promote a lockfile/dependency observation to a finding. (Emit the marker ONLY when the entire diff is non-reviewable; a real review — even one that finds no blockers on actual code — must NOT carry it, so its clean verdict is still logged as calibration signal.)

## Output discipline

**What counts as a blocker:**

- Correctness bugs (the code does the wrong thing)
- Security issues (auth bypass, token exposure, missing CSRF, unvalidated redirect or path, injection)
- Broken public API contracts (signature / return shape / error type changed without a migration path)
- Missing tests the PR itself should have added — per the scoping rules in the Testing section above
- Documentation drift that would actively mislead integrators

**What is NOT a blocker** (do not post these, even if they're true):

- Pre-existing coverage gaps in code the PR merely touches but didn't add
- Style, naming, or formatting preferences
- **Forward-looking or speculative observations the diff doesn't make actionable** — "worth a follow-up grep," "other callers may also swallow this," notes about code outside the diff. They read as findings at triage time but block nothing. Do NOT append run-notes that restate non-blocking observations as findings — least of all on a PR that is already approved or merged. If the review has no blockers, say so in one sentence (per Output discipline) and stop; a genuinely separable follow-up belongs in the log surface or a tracking issue, not in the PR review.
- "Consider adding a comment" / "Could be more readable"
- Missing edge-case tests when happy-path and primary failure-path are covered
- Minor JSDoc prose polish (the _example matching the API_ is a blocker; wording is not)
- Architectural suggestions the current code doesn't call for
- **Cosmetic stale comments.** A code comment the diff leaves stale (e.g. `# Runtime stage (UBI9)` after a bump to ubi10) is a nit — note it inline at most, never as a blocker.
- **By-design or pre-existing lines the PR didn't introduce.** A line the PR merely moves or retains that is intentional or already accepted elsewhere in the repo is not this PR's blocker — especially when the PR body itself flags it (e.g. "left as a default — flag if we'd rather drop it") or an identical line is accepted in a sibling file (e.g. the same `ENV HDB_ADMIN_PASSWORD=password` default present in the main Dockerfile). Confirm the PR actually introduced the line before flagging it; a pre-existing accepted trade-off is at most an observation.
- **Cosmetic CI-check-list / "skipped"-run noise.** A "skipped" check entry or a cosmetic CI-status-list artifact (e.g. on a label-only add) is not a correctness/security/contract issue — don't emit it as a blocker.

**Severity discipline.** The recurring miscalibration is severity *inflation*, not omission: a finding that is real but cosmetic, pre-existing, or an accepted trade-off gets promoted to "blocker." Hold the blocker bar at correctness / security / API-contract / integrator-misleading docs only. A real-but-non-blocking item is at most a one-line observation — never a blocker.

If a finding doesn't have concrete impact on correctness, security, contract, or integrator experience — it's a nit. Don't post it.

**How to post:**

- Structured format: `### <N>. <title>` + `**File:** path:line` + `**What:** …` + `**Why it matters:** …` + `**Suggested fix:** …`.
- **Surface a real finding; never bury it.** A blocker — or a genuinely actionable concern a human should act on — must appear as a **finding in your review output**, never demoted to a run-note / "new observation" on the log surface and never dropped while you report "no blockers." **Where** the finding goes follows your workflow's posting contract, not a fixed channel: if the workflow supports inline review comments, anchor the finding to its line (threaded/resolvable) and keep the top-level comment minimal; if it doesn't, put the finding in the single top-level comment in the structured `**File:** path:line` format above. Either way, a `no blockers` summary MUST be consistent with the findings you posted — the log surface is for _what you traced_, not for _findings you declined to surface_. The dividing line from a suppressed nit is actionability on a line in this diff; speculative or out-of-diff observations stay out per "What is NOT a blocker."
- **PR comments stay concise** — every reader pays the cost. If zero blockers, the PR comment is **one sentence** (e.g. `Reviewed; no blockers found.`). The "what I traced" calibration summary — one line per surface verified, no full re-derivation — belongs in the workflow's **log surface** (a per-PR issue threaded by a `Log review to <log-repo>` step) when one is wired. Workflows without a log surface MAY keep the tracing on the PR as a calibration aid, but only until a log surface is added.
- Never `REQUEST_CHANGES` or `APPROVE` during calibration — comments only.
