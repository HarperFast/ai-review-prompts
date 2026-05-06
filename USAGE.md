# Using the Claude-powered workflows

A consumer repo (e.g. `HarperFast/harper`, `HarperFast/oauth`) that installs the workflows from `examples/` gets three ways to interact with Claude: automatic PR review, `@claude` mention, and label-triggered issue-to-PR. This document is the day-to-day user reference — what works, how to invoke it, and what's out of scope.

For the security model and threat analysis, see the [README's Security section](./README.md#security-reading-the-example-workflows-critically).

---

## 1. Pull request review

**What fires it:** opening, re-opening, or pushing to any PR from:

- An org `OWNER` / `MEMBER` / `COLLABORATOR`, or
- `claude[bot]` (so AI-authored PRs from the issue-to-PR pipeline also get reviewed)

**What happens:** Claude reads the PR, applies the layered review scope (universal + Harper + repo-type), and posts one of:

- **`No blockers found.`** — followed by an optional short "here's what I traced" summary so you can spot-check the reasoning. No other noise.
- **Blocker findings** — a single top-level summary comment listing each finding as `### N. <title>` with `**File:** path:line`, plus **inline comments** anchored to specific code lines in the diff.

**Severity discipline:**

- Posts blocker-severity only: correctness bugs, security issues, broken public API contracts, missing tests the PR itself should have added, misleading docs.
- Skips nits (style, naming, "consider a comment", missing edge-case tests when happy-path + primary failure-path are covered, speculative architecture).
- Pre-existing coverage gaps in code the PR merely touches are explicitly NOT blockers.

**Never approves or requests changes.** Comments only, during calibration.

**What won't auto-review:**

- External contributor PRs (non-org, non-collaborator). A maintainer can opt one in via `@claude review this PR`.
- Fork PRs with any workflow change (GitHub won't give fork runs access to secrets like `ANTHROPIC_API_KEY` regardless).

---

## 2. `@claude` mention

Type `@claude` as the **first non-whitespace token** of a PR or issue comment, followed by your ask.

**Examples:**

```
@claude review this PR
```

```
@claude address the two blockers in the review above
```

```
@claude implement the interface from my last comment, add tests, open a PR
```

```
@claude deep audit the transaction-boundary changes — give me your reasoning
```

**Model selection:**

- **Default: Sonnet 4.6** — fast, cheap, good for most asks (review, explain, small edits, address feedback).
- **Opt-in: Opus 4.7** — include the word `deep` anywhere in the comment (case-insensitive, word-boundary). Use for reasoning-heavy asks: "audit this approach," "design the migration plan," etc.

**What the agent can do:**

- Read files, grep, understand context
- Run the repo's own validation (`npm run build`, `npm run lint`, `npm run test:unit`, etc.) — but **not** install arbitrary packages
- Edit + commit + push to the PR's branch (for mentions on PRs) or a new `claude/…` branch (for mentions on issues)
- Open a PR via `gh pr create`
- Post comments back to the PR/issue explaining what it did or asking for clarification

**What the agent won't do:**

- Push to `main` / `release_*` / `v*.x` (branch protection blocks this; the prompt reinforces)
- Use `REQUEST_CHANGES` or `APPROVE` on a PR
- Install arbitrary npm packages (`Bash(npx:*)` and `Bash(npm install <pkg>)` are not in the allowlist)
- Commit secrets, credentials, or large generated artifacts

**Matching rules — what does NOT trigger the workflow:**

- `@claudette please...` — `@claude` must be followed by a word boundary
- `I saw @claude's fix in #42` — prose references don't count; `@claude` must be first
- `> @claude flagged this as a blocker\n\nActually, disagree` — quoted replies where the text after the quote isn't `@claude`-led don't trigger. Put your `@claude` line at the top if you want to command after quoting.
- Any comment from a user who isn't an org `OWNER` / `MEMBER` / `COLLABORATOR` — silently skipped
- `claude[bot]`-authored comments (prevents loops)

---

## 3. Issue-to-PR (label-triggered)

Apply one of these labels to an issue, and Claude opens a PR linking back to it.

| Label             | Scope                               | What's appropriate                                                             |
| ----------------- | ----------------------------------- | ------------------------------------------------------------------------------ |
| `claude-fix:typo` | 1–2 line prose fix in a single file | Spelling, grammar, punctuation                                                 |
| `claude-fix:docs` | Documentation updates               | `*.md` changes, `package.json` keyword/description edits, doc comments in code |
| `claude-fix:deps` | Dependency version bump             | Update `package.json`, regenerate lockfile, verify `npm ci`                    |
| `claude-fix:bug`  | Focused bug fix                     | Code change with at least one test that fails before, passes after             |

The label's suffix is a scope contract. Asks that would require judgment beyond it — new public API, architecture changes, cross-cutting refactors — are **refused**: the agent comments on the issue explaining what it sees and does NOT open a PR.

**Gating:**

- Only those four exact labels trigger. Typoed variants (`claude-fix:typos`, `claude-fix:foo`) don't — deliberately.
- The issue must have been opened by an org member or collaborator. Labels on issues from external contributors are ignored.

**Where the PR lands:**

- A new branch named `claude/fix-<issue-number>` (or `claude/fix-<issue-number>-<short-desc>` if useful).
- PR body says `Closes #<issue-number>`.
- A comment is posted on the original issue linking to the PR.

**Still needs human review!** The PR is auto-reviewed by the same review workflow (gate #1 above admits `claude[bot]` author). But humans still need to merge.

---

## What's NOT (yet) supported

- **External contributor PRs** aren't auto-reviewed. A maintainer opts in via `@claude review this PR`.
- **Feature issues** don't have a dedicated label. For anything beyond the four `claude-fix:*` scopes, use an `@claude` mention on the issue with a clear description of the desired design. Opus opt-in (`deep`) is usually warranted.
- **Cross-repo work** — the agent operates on one repo at a time. "Apply this change to harper and oauth" requires two invocations.
- **Long-running async work** — each workflow has a timeout (15–25 min). If an ask is genuinely big, split it.
- **Inline editing of closed / merged PRs** — the mention workflow only works on open PRs and issues.

---

## The feedback loop (how this gets better)

The review prompts aren't hard-coded truth — they're a living checklist that gets sharper with every PR they run on. Two paths for that:

### Where review outcomes get logged

Every completed review posts a follow-up entry in `HarperFast/ai-review-log` (private, internal-only today). Each entry captures:

- The repo and PR being reviewed, the model used, and the review job status
- The finding count (or "no blockers") in the title
- The verbatim review body as an issue body, labeled `repo:<short>`, `verdict:pending`, `phase:baseline`

This is what gets swept periodically to see how the bot's judgment is holding up — are findings actually blocker-worthy? Is the review missing things we later catch in human review? Is a layer rule too loose or too strict?

**Why the log repo is internal for now:** logged issue bodies include code snippets from private-repo PRs (Harper core, harper-pro, etc.). Making the log public would leak those. The public half of the picture is this repo — the prompts themselves — where anyone can see what the bot is being told to check.

**Consumers can skip the log step.** The `AI_REVIEW_LOG_TOKEN` secret is optional. If unset, the review step runs but the logging step exits gracefully. Reviews still post on the PR itself; they just don't feed the central tracker.

### How to report / contribute to the prompts

If the bot's output is wrong in a consistent way — false-positive finding, real issue it keeps missing, rule that reads too strictly on a repo-type it wasn't calibrated against — that's signal for a prompt change.

- **Open an issue on [`HarperFast/ai-review-prompts`](https://github.com/HarperFast/ai-review-prompts/issues)** with a link to the specific PR review that shows the misfire. Internal `ai-review-log` issue links are fine too — we'll triage.
- **PRs are welcome.** The prompts are short markdown files; most improvements are one-to-three-bullet edits on an existing layer. The PR-to-prompt-to-review feedback loop is itself reviewed by the bot (this repo has the workflows installed), so you'll see the new rules applied to your own PR before they affect anyone else.
- **New repo-type layers** (e.g. an eventual `repo-type/core.md` for Harper core, or `repo-type/app.md` for customer apps) land here once they've been through enough real PR rounds in that repo type to be stable. Until then, repo-specific bullets live inline in the consumer repo's `claude-review.yml`.

---

## Per-repo setup (maintainer checklist)

1. **Secrets:** add `ANTHROPIC_API_KEY` as a repository secret. Add `AI_REVIEW_LOG_TOKEN` if the repo should log reviews to `HarperFast/ai-review-log` (optional; skipped gracefully if unset).
2. **Labels:** create exactly these four GitHub labels on the repo: `claude-fix:typo`, `claude-fix:docs`, `claude-fix:deps`, `claude-fix:bug`. Any other spelling won't trigger the workflow.
3. **Branch protection:** enable on `main` and any `release_*` / `v*.x` branches. Require reviews on merge. This is load-bearing — the prompt's "don't push to main" instruction is a soft guardrail, branch protection is the real one.
4. **CODEOWNERS:** optional but recommended — pair with "Require review from Code Owners" in branch protection.
5. **Workflow files:** copy `examples/claude-review.yml`, `examples/claude-mention.yml`, `examples/claude-issue-to-pr.yml` into `.github/workflows/` and pin all `uses:` lines to commit SHAs. Adjust `REVIEW_LAYERS` in `claude-review.yml` for your repo (see available layers in this repo).
6. **Caller invariants check:** add a thin `auth-gate-invariants.yml` (or similar) that calls `_validate-caller-workflows.yml` from this repo. It runs on PRs that touch `.github/workflows/claude-*.yml` and rejects: shadow jobs (a non-`uses:` job alongside the legit reusable call would run with the caller's perms and bypass the auth gate); tag/branch refs in `uses:` or `with.ai-review-prompts-ref` (mutable refs defeat SHA-pinning). Make this job a required status check on `main`.

---

## Troubleshooting

**"I `@claude`'d and nothing happened."**

- Is `@claude` the first non-whitespace token of your comment? Prose mentions and quoted replies don't trigger.
- Are you an org member / collaborator? External accounts can't trigger.
- Is the workflow run showing `skipped` (vs `failed`)? `skipped` usually means a gate didn't pass.

**"The review complained about something unrelated to my PR."**

- Check which layers the repo's `claude-review.yml` declares in `REVIEW_LAYERS`.
- Layer bullets are reviewer-discipline rules. If one seems wrong for your repo, open an issue against `HarperFast/ai-review-prompts` — the layers evolve from real calibration feedback.

**"I applied `claude-fix:docs` and got no PR."**

- Confirm the label name is exact (`claude-fix:docs`, lowercase, colon, no trailing space).
- Confirm you're an org member / collaborator — labels on external-authored issues are ignored.
- Check the workflow run for the specific reason it skipped.
