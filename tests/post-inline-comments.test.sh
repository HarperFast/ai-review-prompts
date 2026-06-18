#!/usr/bin/env bash
# Unit tests for the pure helpers in
# .github/scripts/post-inline-comments.sh (badge selection, dedup key,
# comment-body formatting). The script guards its network `main` behind
# a BASH_SOURCE check, so sourcing here exercises the helpers without
# touching the GitHub API — the live posting/dedup path is covered by
# the dogfood review on the PR itself.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"

# Source the script: defines badge_for / item_key / format_body without
# running main (BASH_SOURCE != $0 when sourced).
. "$DIR/../.github/scripts/post-inline-comments.sh"

# --- badge_for: binary severity by design (blocker | suggestion) ----
assert_contains "$(badge_for finding)" "🔴" "finding → red badge"
assert_contains "$(badge_for finding)" "Blocker" "finding → Blocker label"
assert_contains "$(badge_for suggestion)" "💡" "suggestion → bulb badge"
assert_contains "$(badge_for suggestion)" "Suggestion (non-blocking)" "suggestion → non-blocking label"
# Unknown kind defaults to the non-gating suggestion badge (never a blocker).
assert_contains "$(badge_for nonsense)" "Suggestion (non-blocking)" "unknown kind → defaults to suggestion"
assert_not_contains "$(badge_for nonsense)" "Blocker" "unknown kind → never a blocker"

# --- item_key: deterministic, 16 hex chars, distinct per input ------
K1="$(item_key src/a.ts 42 'Title one')"
K2="$(item_key src/a.ts 42 'Title one')"
K3="$(item_key src/a.ts 43 'Title one')"   # line differs
K4="$(item_key src/b.ts 42 'Title one')"   # path differs
assert_eq "$K1" "$K2" "item_key: deterministic for identical inputs"
assert_eq "${#K1}" "16" "item_key: 16-char short hash"
case "$K1" in *[!0-9a-f]*) t_bad "item_key: hex only"; printf '       got: %q\n' "$K1" ;; *) t_ok "item_key: hex only" ;; esac
[ "$K1" != "$K3" ] && t_ok "item_key: line change → different key" || t_bad "item_key: line change → different key"
[ "$K1" != "$K4" ] && t_ok "item_key: path change → different key" || t_bad "item_key: path change → different key"

# --- format_body: badge + title + body + embedded dedup marker ------
B="$(format_body finding 'Off-by-one in loop' 'Use <= so the last row is included.' deadbeefdeadbeef)"
assert_contains "$B" "🔴 **Blocker** — **Off-by-one in loop**" "format_body: badge + bold title headline"
assert_contains "$B" "Use <= so the last row is included." "format_body: body text included"
assert_contains "$B" "<!-- gemini-inline-item:v1 gikey=deadbeefdeadbeef -->" "format_body: well-formed item marker with key"

S="$(format_body suggestion 'Reuse helper' 'Call existing parse() instead.' 0011223344556677)"
assert_contains "$S" "💡 **Suggestion (non-blocking)** — **Reuse helper**" "format_body: suggestion badge + title"
assert_contains "$S" "gikey=0011223344556677" "format_body: suggestion carries its dedup key"

t_summary
