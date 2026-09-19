#!/usr/bin/env node
// Cuts (or force-updates) one pin-bump PR against a single caller repo,
// bumping its `.github/workflows/claude-review.yml` +
// `gemini-review.yml` `ai-review-prompts` pin to the SHA this run
// resolved for ai-review-prompts' own `main`. Invoked once per caller
// repo by `.github/workflows/cut-pin-bumps.yml` (a matrix leg per repo,
// `fail-fast: false`, so one repo's failure — e.g. a missing App-token
// grant — never blocks the others).
//
// Required env:
//   GH_TOKEN       token for reading ai-review-prompts itself (compare +
//                   commit/PR lookups) — the workflow's own default token
//                   is enough; this repo is public.
//   CALLER_TOKEN   HarperFast AI App installation token scoped ONLY to
//                   CALLER_REPO, with contents + pull_requests + workflows
//                   write. No personal token may substitute for this.
//   CALLER_REPO    "HarperFast/<repo>", e.g. "HarperFast/oauth".
//   NEW_SHA        the ai-review-prompts commit SHA to pin callers to
//                   (full 40-char).
// Optional env:
//   PROMPTS_REPO   defaults to "HarperFast/ai-review-prompts".
//   PROMPTS_DIR    local checkout of ai-review-prompts used for
//                   `git diff`/`git log` (defaults to cwd).
//
// The live `claude-review.yml` on the caller's default branch is the
// only source of truth for "what pin is this repo on" — never a
// previously-opened pin-bump branch, which could be stale or manually
// edited. A caller already at NEW_SHA is a no-op (exit 0, no PR).

import { execFileSync } from 'node:child_process';

const WORKFLOW_FILES = ['.github/workflows/claude-review.yml', '.github/workflows/gemini-review.yml'];
const PIN_BRANCH_PREFIX = 'ai-review-prompts-pin-';
const PIN_RE = /_(?:claude|gemini)-review\.yml@([0-9a-f]{40})/;
const PROMPT_FILE_RE = /^(universal\.md|harper\/.*\.md|repo-type\/.*\.md)$/;

export function extractPin(content) {
	const m = content.match(PIN_RE);
	return m ? m[1] : null;
}

export function isPromptFile(path) {
	return PROMPT_FILE_RE.test(path);
}

export function summarizePrs(prs, { maxEntries = 6, maxLen = 240 } = {}) {
	if (prs.length === 0) return '';
	const entries = prs.slice(0, maxEntries).map((pr) => `#${pr.number} ${pr.title}`);
	let summary = entries.join('; ');
	if (prs.length > maxEntries) summary += `; +${prs.length - maxEntries} more`;
	if (summary.length > maxLen) summary = `${summary.slice(0, maxLen - 1)}…`;
	return summary;
}

export function buildPinComment({ date, prs, prevShortSha }) {
	const summary = summarizePrs(prs);
	const body = summary ? `${summary}; on ${prevShortSha}` : `on ${prevShortSha}`;
	return `main ${date} (${body})`;
}

// Swaps every occurrence of `oldSha` for `newSha` (the `uses:` ref and
// the `ai-review-prompts-ref:` input both carry the literal 40-char
// SHA), then refreshes the trailing `# main <date> (<summary>)` comment
// on the `uses:` line. Throws if `oldSha` isn't present — a mismatch
// here means the caller's pin drifted from what the caller-wide check
// assumed, and guessing at a partial bump is worse than failing loudly.
export function bumpPinContent(content, { oldSha, newSha, comment }) {
	if (!content.includes(oldSha)) {
		throw new Error(`pin ${oldSha} not found in file content; refusing to bump`);
	}
	let next = content.replaceAll(oldSha, newSha);
	const usesLineRe = new RegExp(`^(.*_(?:claude|gemini)-review\\.yml@${newSha})(?:[^\\n]*)$`, 'm');
	if (!usesLineRe.test(next)) {
		throw new Error(`no 'uses:' line found for ${newSha} after substitution; refusing to bump`);
	}
	next = next.replace(usesLineRe, (_match, prefix) => `${prefix} # ${comment}`);
	return next;
}

export function buildPrBody({ oldShort, newShort, compareUrl, changedPaths, promptFilesChanged }) {
	const pathsList = changedPaths.map((p) => `- \`${p}\``).join('\n');
	const promptNote = promptFilesChanged
		? '**Prompt files changed: yes** — reviews on this repo run uncalibrated against the new layer content until this merges.'
		: '**Prompt files changed:** no — workflow/script-only bump.';
	return `Bumps the \`ai-review-prompts\` pin from \`${oldShort}\` to \`${newShort}\`.

Compare: ${compareUrl}

**Changed paths:**
${pathsList}

${promptNote}

Opened automatically by \`.github/workflows/cut-pin-bumps.yml\` in HarperFast/ai-review-prompts.
`;
}

function execGit(args) {
	return execFileSync('git', args, { cwd: process.env.PROMPTS_DIR || process.cwd(), encoding: 'utf8' }).trim();
}

async function ghRequest(token, url, options = {}) {
	const res = await fetch(url, {
		...options,
		headers: {
			'Authorization': `Bearer ${token}`,
			'Accept': 'application/vnd.github+json',
			'X-GitHub-Api-Version': '2022-11-28',
			...(options.body ? { 'Content-Type': 'application/json' } : {}),
			...(options.headers || {}),
		},
	});
	if (!res.ok) {
		const body = await res.text().catch(() => '');
		const err = new Error(
			`${options.method || 'GET'} ${url} failed: ${res.status} ${res.statusText}${body ? ` — ${body}` : ''}`
		);
		err.status = res.status;
		throw err;
	}
	if (res.status === 204) return null;
	return res.json();
}

async function getFile(token, repo, path) {
	const data = await ghRequest(token, `https://api.github.com/repos/${repo}/contents/${path}`);
	return Buffer.from(data.content, 'base64').toString('utf8');
}

async function getDefaultBranch(token, repo) {
	const data = await ghRequest(token, `https://api.github.com/repos/${repo}`);
	return data.default_branch;
}

// PRs merged into ai-review-prompts' main between oldSha and newSha,
// oldest first — one API call per commit in the compare, resolved via
// GitHub's commit->PR association rather than parsing commit subjects,
// so both squash-merged and merge-commit PRs resolve correctly.
async function collectMergedPrs(token, promptsRepo, commits) {
	const seen = new Map();
	for (const commit of commits) {
		const pulls = await ghRequest(token, `https://api.github.com/repos/${promptsRepo}/commits/${commit.sha}/pulls`);
		for (const pr of pulls) {
			if (pr.merge_commit_sha === commit.sha && !seen.has(pr.number)) {
				seen.set(pr.number, { number: pr.number, title: pr.title });
			}
		}
	}
	return [...seen.values()];
}

async function listPinBranches(token, repo) {
	try {
		return await ghRequest(token, `https://api.github.com/repos/${repo}/git/matching-refs/heads/${PIN_BRANCH_PREFIX}`);
	} catch (err) {
		if (err.status === 404) return [];
		throw err;
	}
}

// One open pin PR per repo at a time: any other `ai-review-prompts-pin-*`
// branch is deleted (GitHub auto-closes its PR, same-repo branch), so a
// later run never stacks a second pin PR alongside an unmerged one.
async function supersedeOtherPinBranches(token, repo, targetBranch) {
	for (const ref of await listPinBranches(token, repo)) {
		const branch = ref.ref.replace('refs/heads/', '');
		if (branch === targetBranch) continue;
		console.log(`${repo}: deleting superseded pin branch ${branch}`);
		await ghRequest(token, `https://api.github.com/repos/${repo}/git/refs/heads/${branch}`, { method: 'DELETE' });
	}
}

// Builds one commit (both files, from the CURRENT default-branch tip —
// never from a possibly-stale prior pin branch) and force-updates (or
// creates) `targetBranch` to point at it.
async function commitFiles(token, repo, targetBranch, files, message) {
	const defaultBranch = await getDefaultBranch(token, repo);
	const baseRef = await ghRequest(token, `https://api.github.com/repos/${repo}/git/ref/heads/${defaultBranch}`);
	const baseCommitSha = baseRef.object.sha;
	const baseCommit = await ghRequest(token, `https://api.github.com/repos/${repo}/git/commits/${baseCommitSha}`);
	const tree = Object.entries(files).map(([path, content]) => ({ path, mode: '100644', type: 'blob', content }));
	const newTree = await ghRequest(token, `https://api.github.com/repos/${repo}/git/trees`, {
		method: 'POST',
		body: JSON.stringify({ base_tree: baseCommit.tree.sha, tree }),
	});
	const newCommit = await ghRequest(token, `https://api.github.com/repos/${repo}/git/commits`, {
		method: 'POST',
		body: JSON.stringify({ message, tree: newTree.sha, parents: [baseCommitSha] }),
	});
	try {
		await ghRequest(token, `https://api.github.com/repos/${repo}/git/refs/heads/${targetBranch}`, {
			method: 'PATCH',
			body: JSON.stringify({ sha: newCommit.sha, force: true }),
		});
	} catch (err) {
		if (err.status !== 404 && err.status !== 422) throw err;
		await ghRequest(token, `https://api.github.com/repos/${repo}/git/refs`, {
			method: 'POST',
			body: JSON.stringify({ ref: `refs/heads/${targetBranch}`, sha: newCommit.sha }),
		});
	}
}

async function openOrUpdatePr(token, repo, branch, title, body) {
	const owner = repo.split('/')[0];
	const defaultBranch = await getDefaultBranch(token, repo);
	const existing = await ghRequest(
		token,
		`https://api.github.com/repos/${repo}/pulls?head=${owner}:${branch}&state=open`
	);
	if (existing.length > 0) {
		await ghRequest(token, `https://api.github.com/repos/${repo}/pulls/${existing[0].number}`, {
			method: 'PATCH',
			body: JSON.stringify({ title, body }),
		});
		return existing[0].number;
	}
	const created = await ghRequest(token, `https://api.github.com/repos/${repo}/pulls`, {
		method: 'POST',
		body: JSON.stringify({ title, body, head: branch, base: defaultBranch }),
	});
	return created.number;
}

export async function main() {
	const { GH_TOKEN, CALLER_TOKEN, CALLER_REPO, NEW_SHA, PROMPTS_REPO = 'HarperFast/ai-review-prompts' } = process.env;
	for (const [name, value] of Object.entries({ GH_TOKEN, CALLER_TOKEN, CALLER_REPO, NEW_SHA })) {
		if (!value) throw new Error(`missing required env var ${name}`);
	}

	const primaryContent = await getFile(CALLER_TOKEN, CALLER_REPO, WORKFLOW_FILES[0]);
	const oldSha = extractPin(primaryContent);
	if (!oldSha) throw new Error(`could not find an ai-review-prompts pin in ${CALLER_REPO}/${WORKFLOW_FILES[0]}`);

	if (oldSha === NEW_SHA) {
		console.log(`${CALLER_REPO} is already at head (${oldSha}); nothing to do.`);
		return;
	}

	const oldShort = oldSha.slice(0, 7);
	const newShort = NEW_SHA.slice(0, 7);

	const changedPaths = execGit(['diff', '--name-only', oldSha, NEW_SHA]).split('\n').filter(Boolean);
	if (changedPaths.length === 0) {
		throw new Error(
			`git diff ${oldSha}..${NEW_SHA} reported no changed paths; refusing to cut a pin bump for an empty diff`
		);
	}

	const compare = await ghRequest(
		GH_TOKEN,
		`https://api.github.com/repos/${PROMPTS_REPO}/compare/${oldSha}...${NEW_SHA}`
	);
	const prs = await collectMergedPrs(GH_TOKEN, PROMPTS_REPO, compare.commits);
	const date = execGit(['log', '-1', '--format=%cd', '--date=short', NEW_SHA]);
	const comment = buildPinComment({ date, prs, prevShortSha: oldShort });

	const files = {};
	for (const path of WORKFLOW_FILES) {
		const content = path === WORKFLOW_FILES[0] ? primaryContent : await getFile(CALLER_TOKEN, CALLER_REPO, path);
		const currentPin = extractPin(content);
		if (currentPin !== oldSha) {
			throw new Error(
				`${CALLER_REPO}/${path} pin (${currentPin}) does not match ${WORKFLOW_FILES[0]}'s pin (${oldSha}); refusing to bump inconsistent pins`
			);
		}
		files[path] = bumpPinContent(content, { oldSha, newSha: NEW_SHA, comment });
	}

	const targetBranch = `${PIN_BRANCH_PREFIX}${newShort}`;
	await supersedeOtherPinBranches(CALLER_TOKEN, CALLER_REPO, targetBranch);
	await commitFiles(CALLER_TOKEN, CALLER_REPO, targetBranch, files, `ci: bump ai-review-prompts pin to ${newShort}`);

	const compareUrl = `https://github.com/${PROMPTS_REPO}/compare/${oldSha}...${NEW_SHA}`;
	const promptFilesChanged = changedPaths.some(isPromptFile);
	const body = buildPrBody({ oldShort, newShort, compareUrl, changedPaths, promptFilesChanged });
	const prNumber = await openOrUpdatePr(
		CALLER_TOKEN,
		CALLER_REPO,
		targetBranch,
		`ci: bump ai-review-prompts pin to ${newShort}`,
		body
	);

	console.log(`${CALLER_REPO}: pin bump ${oldShort} -> ${newShort} on branch ${targetBranch} (PR #${prNumber})`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
	main().catch((err) => {
		console.error(err.stack || String(err));
		process.exit(1);
	});
}
