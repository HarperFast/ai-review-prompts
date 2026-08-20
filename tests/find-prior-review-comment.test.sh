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
printf '%s\n' '[{"id":1,"body":"ordinary comment"}]'
printf '%s\n' '[{"id":42,"body":"<!-- claude-review:v1 -->\nprior review"}]'
STUB
chmod +x "$TMP/bin/gh"

PATH="$TMP/bin:$PATH" MARKER='<!-- claude-review:v1 -->' \
GITHUB_REPOSITORY=HarperFast/harper PR_NUMBER=7 GITHUB_OUTPUT="$TMP/output" \
	bash "$SCRIPT" >/dev/null

assert_eq "$(<"$TMP/output")" "id=42" "prior review is found beyond the first API page"

t_summary
