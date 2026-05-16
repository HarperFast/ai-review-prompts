# Harper common conventions

Version-agnostic review guidance for repos in the Harper ecosystem. The repo's own `CLAUDE.md` may duplicate or extend this — when in conflict, the repo's CLAUDE.md wins (it's closer to the source).

## Meta-checks (run these before tracing internals)

Before diving into line-level review of any PR, run these three meta-checks. Verifying internal consistency of the wrong target is wasted analysis; if a meta-check raises a concern, post that finding BEFORE tracing internals — it's higher signal than line-level observations on a misframed change.

1. **Test validity.** Does the test actually exercise the bug's mechanism? A synchronous test cannot validate a cross-thread race; an in-process mock cannot validate IPC behavior; a test that stubs the I/O it's supposed to exercise validates nothing. If the PR claims to fix concurrency / IPC / cross-process / cross-platform behavior, verify the test exercises that mechanism — not a single-threaded simplification. Example miss: a fix for "two workers race on `temp.{pid}.tmp` filenames" with a sync test that calls the function 100 times in a row and asserts the temp paths are distinct — the test validates path uniqueness, not race-condition coverage. The bug requires worker threads to reproduce; a sync loop can't.

2. **Right target.** Is this the right code path for the stated goal? When the PR touches one of two parallel paths — LMDB vs RocksDB, v1 vs v2, sync vs async, `copyDb` vs `migrateOnStart`, op handler vs replication-receive — confirm the path matches the PR's stated intent. Example miss: a bug describing "happens on regular RocksDB startup" fixed inside `copyDbToRocks` (the LMDB→RocksDB conversion path used only during one-time migrations) instead of `migrateOnStart` (regular RocksDB startup). The changes inside `copyDbToRocks` were internally consistent — but the function itself was the wrong target.

3. **Premise.** Does the bug being fixed actually exist? When a PR adds functionality that "should exist", grep for the functionality first. If found, flag the PR as potentially redundant rather than reviewing the new implementation. Example miss: a PR adding an initial sync loop to a subscribe-call site, when `subscribeToNodeUpdates` already runs that loop for other callers in the same module — the framing was a misread of existing code, and the PR was withdrawn after a maintainer pointed it out.

These checks are mandatory on any PR where the description claims to fix a specific bug or add a specific capability. The order matters — premise first (does the bug exist?), then target (is this the right place?), then test validity (does the test cover it?). Internal correctness review comes after all three.

## Non-obvious behavior

- **`GenericTrackedObject` + spread.** `{ ...obj }` on a Harper _generic_ tracked object (the shape for `session.oauth`, `session.oauthUser`, and any tracked object without a declared schema) copies nothing — properties are served through a Proxy `get` trap, not as own enumerable properties. `Object.keys(obj)` returns `[]`. Use explicit property access: `{ provider: obj.provider, ... }`. Typed TrackedObjects (table rows with declared attributes) may behave differently; verify against the specific tracked type rather than assuming either way. Any test using spread on session fields is testing a plain object, not the production shape.
- **`session.oauth` vs `session.delete()`.** Some session objects expose `.delete(id)` (Harper production shape — destroys the DB record). Some don't (in-memory test mocks). Code calling `clearOAuthSession` or similar may mutate `.oauth`/`.oauthUser` in-memory on test shapes but destroy the entire session record in production. Tests that exercise only one shape hide the divergence.
- **`npm run build` tolerance.** Many Harper repos use `tsc || true` so the build passes even with type errors. "Build passes" ≠ "types are sound." Type correctness must be verified separately (editor diagnostics, a dedicated typecheck script, or CI step).
- **`npm run lint` is ESLint-only**, not a typecheck.

## Code conventions

- TypeScript strict mode; ES modules with `.js` extensions in imports; named exports only (no default exports).
- Logging uses the optional-chain pattern `logger?.info?.()` — the `logger` argument is frequently undefined in library code, so code must not assume it's present.
- Error classes come from each repo's `src/errors.ts` OR the framework package (`harper` v5 / `harperdb` v4). All custom errors include a `statusCode` property.
- Tokens, passwords, session IDs — **never** log, never return in responses, never include in error messages.

## Review checks specific to Harper

- **`scope.resources` / `scope.server` usage.** Declared optional in the Harper type but always assigned in the Scope constructor. Code should either guard once at entry or use narrowed locals, not sprinkle `?.` / `!` throughout.
- **`static loadAsInstance = false` (Resource API v2).** Harper instantiates the class per request; do NOT rely on shared mutable instance state across requests. If per-request state is stored, it belongs on the context (`this.getContext()`).
- **Unused runtime dependencies.** Harper repos target minimal runtime deps. New ones require explicit justification in the PR description (some repos maintain a `dependencies.md` for this).
- **Dev/prod dependency mismatch.** Production code paths must only import from `dependencies` or `peerDependencies`. A `devDependencies` package referenced by runtime code (e.g. `await import('undici')` in an HTTPS path, a runtime helper imported from a test-only utility) breaks deployment for any consumer that doesn't share the dev environment. Caveat: some packages are also Node built-ins on recent Node versions (`undici` on Node 22+); using them without an explicit dep is OK ONLY if `engines.node` declares the floor that makes them built-in. When the runtime requirement and the declared engine floor disagree, flag both — the missing dep AND the permissive `engines.node`.
- **Existing-dependency reuse.** Before accepting a reimplementation of common functionality (semver math, version compare, path joining, retry/backoff, file utilities, identity/auth helpers), check the package's existing `dependencies` and `utility/` / `shared/` helpers for an equivalent. Harper-side examples seen in past reviews: `semver` already a direct dep for version operations, `getPrivateKeyByName` already in `keys.js`, `node:path` over manual string concatenation. Reuse beats reimplementation; flag the duplicate as a suggestion (not a blocker) so the author can decide.
- **CI workflow hygiene.** When `.github/workflows/*.yml` changes touch dependency install steps: flag `npm install` → should be `npm ci` so the lockfile is honored. Flag missing `--ignore-scripts` when the workflow runs in a context where postinstall scripts shouldn't fire (most CI jobs, especially diagnostic / artifact-collection jobs).
- **Lockfile drift.** When `package.json` changes without a matching `package-lock.json` change (or vice versa), or when `package-lock.json` has churn unrelated to the PR's stated intent, surface it. Usually not a blocker for the current PR, but worth flagging in the run notes so it gets a separate cleanup PR rather than sitting in main indefinitely.

## Documentation boundary (defer to Harper docs)

Harper maintains its own documentation at [docs.harperdb.io](https://docs.harperdb.io) covering core, pro, and fabric. App, sample, and plugin repos should:

- Document what is specific to the app/plugin itself — env var names, config shape, setup flow, integration API.
- **Link** to the Harper documentation for anything not app/component-specific: deployment mechanics, runtime env var handling, Fabric configuration, core database behavior, SQL translator, replication, etc.

Flag PRs that re-explain Harper behavior in-repo when a link to the authoritative Harper docs would be more maintainable. Re-explanation creates drift — Harper updates its docs, the copy doesn't.

Borderline calls (judgment, not a blocker):

- Short factual reminders where a link alone is too thin (e.g. "Harper reads env vars directly from the process environment — see [...]") are fine.
- Duplicating whole Harper docs sections inline is not — link.
