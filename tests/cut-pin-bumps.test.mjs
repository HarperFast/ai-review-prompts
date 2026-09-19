import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
	bumpPinContent,
	buildPinComment,
	buildPrBody,
	extractPin,
	isPromptFile,
	main,
	summarizePrs,
} from '../.github/scripts/cut-pin-bumps.mjs';

const OLD_SHA = '28544a1a3c39b295401412b77f863c972bacdf6f';
const NEW_SHA = 'f811c3aca67c666a6a9410434b85aa1af02d4d20';

const SAMPLE = `jobs:
  review:
    uses: HarperFast/ai-review-prompts/.github/workflows/_claude-review.yml@${OLD_SHA} # main 2026-09-14 (stale)
    with:
      ai-review-prompts-ref: ${OLD_SHA}
`;

test('extractPin reads the pinned SHA off a uses: line', () => {
	assert.equal(extractPin(SAMPLE), OLD_SHA);
});

test('extractPin returns null when there is no pin', () => {
	assert.equal(extractPin('no pin here'), null);
});

test('isPromptFile matches layer content, not workflow/script files', () => {
	assert.equal(isPromptFile('universal.md'), true);
	assert.equal(isPromptFile('harper/common.md'), true);
	assert.equal(isPromptFile('repo-type/plugin.md'), true);
	assert.equal(isPromptFile('.github/workflows/_claude-review.yml'), false);
	assert.equal(isPromptFile('.github/scripts/cut-pin-bumps.mjs'), false);
});

test('summarizePrs joins PR number + title and caps long lists', () => {
	assert.equal(summarizePrs([]), '');
	assert.equal(
		summarizePrs([{ number: 98, title: 'mint the ai-review-log token' }]),
		'#98 mint the ai-review-log token'
	);
	const many = Array.from({ length: 8 }, (_, i) => ({ number: i, title: `pr ${i}` }));
	const summary = summarizePrs(many, { maxEntries: 6 });
	assert.match(summary, /\+2 more$/);
});

test('buildPinComment includes the date, PR summary, and previous short SHA', () => {
	const comment = buildPinComment({
		date: '2026-09-18',
		prs: [{ number: 98, title: 'mint the ai-review-log token' }],
		prevShortSha: OLD_SHA.slice(0, 7),
	});
	assert.equal(comment, `main 2026-09-18 (#98 mint the ai-review-log token; on ${OLD_SHA.slice(0, 7)})`);
});

test('buildPinComment falls back gracefully with no PRs in range', () => {
	const comment = buildPinComment({ date: '2026-09-18', prs: [], prevShortSha: '28544a1' });
	assert.equal(comment, 'main 2026-09-18 (on 28544a1)');
});

test('bumpPinContent swaps the SHA everywhere and refreshes the trailing comment', () => {
	const next = bumpPinContent(SAMPLE, { oldSha: OLD_SHA, newSha: NEW_SHA, comment: 'main 2026-09-18 (#98 fixed)' });
	assert.ok(!next.includes(OLD_SHA), 'old SHA fully replaced');
	assert.match(next, new RegExp(`uses: .*@${NEW_SHA} # main 2026-09-18 \\(#98 fixed\\)`));
	assert.match(next, new RegExp(`ai-review-prompts-ref: ${NEW_SHA}`));
});

test('bumpPinContent throws when the old SHA is not present', () => {
	assert.throws(() => bumpPinContent(SAMPLE, { oldSha: NEW_SHA, newSha: OLD_SHA, comment: 'x' }), /not found/);
});

test('buildPrBody flags prompt-file changes and lists changed paths', () => {
	const body = buildPrBody({
		oldShort: '28544a1',
		newShort: 'f811c3a',
		compareUrl: 'https://github.com/HarperFast/ai-review-prompts/compare/28544a1...f811c3a',
		changedPaths: ['.github/workflows/_claude-review.yml', 'harper/common.md'],
		promptFilesChanged: true,
	});
	assert.match(body, /28544a1` to `f811c3a/);
	assert.match(body, /- `harper\/common\.md`/);
	assert.match(body, /Prompt files changed: yes/);
});

test('main() is a no-op (no commit/PR calls) when the caller is already at head', async (t) => {
	const fetchCalls = [];
	t.mock.method(globalThis, 'fetch', async (url) => {
		fetchCalls.push(String(url));
		return new Response(JSON.stringify({ content: Buffer.from(SAMPLE).toString('base64') }), { status: 200 });
	});
	process.env.GH_TOKEN = 'gh-token';
	process.env.CALLER_TOKEN = 'caller-token';
	process.env.CALLER_REPO = 'HarperFast/oauth';
	process.env.NEW_SHA = OLD_SHA; // caller's live pin already matches "new" SHA
	try {
		await main();
	} finally {
		delete process.env.GH_TOKEN;
		delete process.env.CALLER_TOKEN;
		delete process.env.CALLER_REPO;
		delete process.env.NEW_SHA;
	}
	assert.equal(fetchCalls.length, 1, 'only reads the live pin; no compare/commit/PR calls');
	assert.match(fetchCalls[0], /contents\/\.github\/workflows\/claude-review\.yml/);
});

test('buildPrBody reports no prompt-file changes for a workflow-only bump', () => {
	const body = buildPrBody({
		oldShort: '28544a1',
		newShort: 'f811c3a',
		compareUrl: 'https://github.com/HarperFast/ai-review-prompts/compare/28544a1...f811c3a',
		changedPaths: ['.github/workflows/_claude-review.yml'],
		promptFilesChanged: false,
	});
	assert.match(body, /Prompt files changed:\*\* no/);
});
