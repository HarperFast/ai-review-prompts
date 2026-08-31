#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/../.github/scripts/drop-superseded-run.sh"
source "$DIR/lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "${STUB_MODE:-match}" in
	api-fail) exit 1 ;;
	stale) printf 'bbbbbbbb\n' ;;
	null-head) printf 'null\n' ;;
	*) printf 'aaaaaaaa\n' ;;
esac
STUB
chmod +x "$TMP/bin/gh"

run_drop() {
	STUB_MODE="$1" PATH="$TMP/bin:$PATH" \
		REPO=HarperFast/x PR_NUMBER=1 EVENT_HEAD=aaaaaaaa \
		bash "$SCRIPT" > "$TMP/out" 2>&1
	RUN_STATUS=$?
}

run_drop match
assert_status "$RUN_STATUS" 0 "matching live head proceeds"

run_drop stale
assert_status "$RUN_STATUS" 1 "a moved live head fails the run"
assert_contains "$(cat "$TMP/out")" "Superseded" "stale failure names the supersession"

run_drop null-head
assert_status "$RUN_STATUS" 0 "a null live head fails open and proceeds"

run_drop api-fail
assert_status "$RUN_STATUS" 0 "an unreadable live head fails open and proceeds"

t_summary
