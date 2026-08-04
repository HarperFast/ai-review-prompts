# Review-prompt regression evals

Offline harness that replays **verified production review misses** against
a prompt ref + model and judges whether the review now catches each known
defect. The point: a calibration PR can answer "does the new text catch
the misses that motivated it?" in minutes, instead of shipping blind and
waiting a week for production verdicts. (Pattern borrowed from
[lgtmaybe](https://lgtmaybe.coles.codes/)'s `evals/` idea, populated with
our own calibration corpus.)

## What a fixture is

One confirmed miss from the calibration loop: a case where a production
review gave a clean/under-called pass while a peer (gemini or a human)
flagged a real defect the author then fixed. Fixtures are
**metadata-only YAML** — pinned `base_sha`/`reviewed_sha` reconstruct
the exact reviewed state from the source repo, so nothing is frozen or
copied. They live in `fixtures/` of **HarperFast/ai-review-log**
(private, deliberately: they describe pre-merge defects in private
repos; this public repo holds only the harness).

## Usage

```bash
# test your working tree against every fixture (reviewer = harper canary model)
evals/run-eval.sh

# test a specific ref / the fleet default model / one fixture class
evals/run-eval.sh --ref 224c2ad --model claude-sonnet-4-6 --fixtures 'oauth-*'

# regression gate against a recorded baseline
evals/run-eval.sh --baseline evals/baseline.tsv
```

Requirements: `gh` (authed with access to ai-review-log + the source
repos), `claude` CLI (authed), `yq`, `jq`. Each fixture is one real
agentic review run (~1–3 min, sequential) plus a cheap judge call —
budget accordingly. Results land in `evals-out/<timestamp>/` (review
text, judge verdict + evidence, `results.tsv`).

Verdicts per fixture: `caught` (same mechanism, same location, any
severity), `partial` (area/symptom without mechanism, or named then
dismissed), `missed`. See `judge-prompt.md` for the judging contract.

## Baseline

`evals/run-eval.sh` prints a `results.tsv`; commit a snapshot as
`evals/baseline.tsv` to turn later runs into a regression gate
(`caught` → anything else fails). The **first full-corpus run** also
answers a standing question for free: how many of the historical misses
do the current rules (post-#73/#80) already catch?

## Fidelity caveats (v1, accepted)

- No PR title/body/comments context — fixtures test code-level
  detection, not conversation reconciliation (so the concurrent-peer-
  review timing class is out of scope here).
- Single `claude -p` pass with read-only tools, not the full
  claude-code-action harness (no prior-review continuity, no posting).
- Caller `repo-specific-checks` blocks are not composed — shared layers
  only.
- Judge is a cheap model on a strict contract; spot-check `*.judge.json`
  when a verdict is surprising.

## Adding a fixture

When triage confirms a new author-fixed miss worth freezing, add a YAML
file under ai-review-log `fixtures/` (schema in its README) citing the
log issue, the pinned SHAs, and a self-contained defect description a
judge can score against.
