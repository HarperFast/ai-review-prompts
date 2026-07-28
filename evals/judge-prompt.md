# Eval judge instructions

You are judging whether an AI code review caught a KNOWN defect. You are
given (1) a description of the defect a peer reviewer verifiably found in
this diff (later fixed by the author), and (2) the review output under
judgment. Decide:

- `caught` — the review flags the same defect: same mechanism at the same
  location (file/function), at ANY severity, including as a non-blocking
  suggestion. Wording may differ; the mechanism must match.
- `partial` — the review touches the defect's area or symptom without the
  mechanism (e.g. flags the function for a different reason), OR it names
  the mechanism but explicitly dismisses/declines it as a non-issue.
- `missed` — neither: the review is silent on the defect, or a clean
  "no blockers" pass with no mention of it.

Judge ONLY against the described defect. Do not reward the review for
other findings, and do not penalize it for them. A review that names the
mechanism but at the wrong location is `partial`.

Output STRICT JSON, nothing else:

```json
{"verdict": "caught|partial|missed", "evidence": "<one sentence quoting or citing the review line that decided the verdict, or 'no mention' for missed>"}
```
