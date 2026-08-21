#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/../.github/scripts/find-prior-review-comment.sh"
source "$DIR/lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '[{"id":1,"body":"ordinary comment","user":{"login":"human"}}]'
printf '%s\n' '[{"id":42,"body":"<!-- claude-review:v1 -->\nprior review","user":{"login":"claude[bot]"}}]'
printf '%s\n' '[{"id":99,"body":"<!-- claude-review:v1 -->\nspoofed review","user":{"login":"attacker"}}]'
STUB
chmod +x "$TMP/bin/gh"

PATH="$TMP/bin:$PATH" MARKER='<!-- claude-review:v1 -->' EXPECTED_REVIEW_AUTHOR='claude[bot]' \
GITHUB_REPOSITORY=HarperFast/harper PR_NUMBER=7 GITHUB_OUTPUT="$TMP/output" \
	bash "$SCRIPT" >/dev/null

assert_eq "$(<"$TMP/output")" "id=42" "prior review is found beyond the first API page"
assert_not_contains "$(<"$TMP/output")" "99" "spoofed marker comment is not selected for editing"

t_summary
