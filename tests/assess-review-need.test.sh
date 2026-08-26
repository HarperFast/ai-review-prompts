#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/../.github/scripts/assess-review-need.sh"
source "$DIR/lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
URL="${*: -1}"
case "${STUB_MODE:-small}" in
	api-failure)
		exit 1 ;;
	empty)
		printf '[]\n' ;;
	small)
		printf '%s\n' '[{"filename":"src/auth.ts","additions":20,"deletions":8},{"filename":"src/auth.test.ts","additions":12,"deletions":0}]' ;;
	large)
		printf '%s\n' '[{"filename":"src/replication.ts","additions":400,"deletions":90},{"filename":"src/storage.ts","additions":120,"deletions":30}]' ;;
	lockfile-only)
		printf '%s\n' '[{"filename":"package-lock.json","additions":900,"deletions":850}]' ;;
	lockfile-churn)
		printf '%s\n' '[{"filename":"package-lock.json","additions":5000,"deletions":4800},{"filename":"src/fix.ts","additions":9,"deletions":2}]' ;;
	version-bump)
		printf '%s\n' '[{"filename":"package.json","additions":1,"deletions":1,"patch":"@@ -1,5 +1,5 @@\n {\n-  \"version\": \"2.5.0\",\n+  \"version\": \"2.5.1\",\n   \"name\": \"x\""},{"filename":"package-lock.json","additions":2,"deletions":2}]' ;;
	dep-change)
		printf '%s\n' '[{"filename":"package.json","additions":2,"deletions":1,"patch":"@@ -1,6 +1,7 @@\n {\n-  \"version\": \"2.5.0\",\n+  \"version\": \"2.5.1\",\n+  \"dependencies\": {\"left-pad\": \"^1.0.0\"},\n   \"name\": \"x\""},{"filename":"package-lock.json","additions":40,"deletions":2}]' ;;
	null-fields)
		printf '%s\n' '[{"filename":"assets/logo.png","additions":null,"deletions":null},{"filename":"src/tiny.ts","additions":3,"deletions":1}]' ;;
	paginated)
		printf '%s' '['
		for i in $(seq 1 99); do printf '{"filename":"f%s.ts","additions":1,"deletions":0},' "$i"; done
		printf '%s\n' '{"filename":"f100.ts","additions":1,"deletions":0}]' ;;
esac
STUB
chmod +x "$TMP/bin/gh"

run_assess() {
	local mode="$1"; shift
	: > "$TMP/out"
	STUB_MODE="$mode" PATH="$TMP/bin:$PATH" \
		REPO=HarperFast/x PR_NUMBER=1 GITHUB_OUTPUT="$TMP/out" \
		EFFORT="${EFFORT_OVERRIDE-xhigh}" EFFORT_SMALL="${EFFORT_SMALL_OVERRIDE-high}" \
		SMALL_DIFF_LINES="${SMALL_DIFF_LINES_OVERRIDE-60}" \
		SKIP_WHEN_ONLY="${SKIP_WHEN_ONLY_OVERRIDE-$(printf 'package-lock.json\nnpm-shrinkwrap.json\nyarn.lock\npnpm-lock.yaml\nbun.lockb\nCHANGELOG.md')}" \
		bash "$SCRIPT" >/dev/null
	RUN_STATUS=$?
}
out() { grep -m1 "^$1=" "$TMP/out" | cut -d= -f2-; }

run_assess small
assert_status "$RUN_STATUS" 0 "small diff exits successfully"
assert_eq "$(out skip)" "false" "small diff is reviewed"
assert_eq "$(out effort)" "high" "small diff tiers effort down"

run_assess large
assert_eq "$(out skip)" "false" "large diff is reviewed"
assert_eq "$(out effort)" "xhigh" "large diff keeps full effort"

run_assess lockfile-only
assert_eq "$(out skip)" "true" "lockfile-only diff is skipped"
assert_contains "$(out reason)" "only-mechanical-files" "lockfile-only reason names the gate"

run_assess lockfile-churn
assert_eq "$(out skip)" "false" "lockfile churn plus source change is reviewed"
assert_eq "$(out effort)" "high" "lockfile churn does not inflate the tiering count"

run_assess version-bump
assert_eq "$(out skip)" "true" "version-only package.json bump is skipped"
assert_contains "$(out reason)" "version-bump-only" "version bump reason names the gate"

run_assess dep-change
assert_eq "$(out skip)" "false" "dependency change in package.json is reviewed"

run_assess api-failure
assert_status "$RUN_STATUS" 0 "files API failure exits zero (best-effort)"
assert_eq "$(out skip)" "false" "files API failure fails OPEN to a review"
assert_eq "$(out effort)" "xhigh" "fail-open keeps full effort"

run_assess empty
assert_eq "$(out skip)" "true" "empty diff is skipped"

EFFORT_OVERRIDE="" run_assess small
assert_eq "$(out effort)" "" "empty effort input disables the flag and tiering"
assert_eq "$(out skip)" "false" "empty effort input still reviews"

EFFORT_SMALL_OVERRIDE="" run_assess small
assert_eq "$(out effort)" "xhigh" "empty effort-small disables tiering only"

run_assess null-fields
assert_status "$RUN_STATUS" 0 "null additions/deletions do not crash the script"
assert_eq "$(out skip)" "false" "null-field diff is reviewed"
assert_eq "$(out effort)" "high" "null fields count as zero lines for tiering"

run_assess paginated
assert_eq "$(out skip)" "false" "pagination cap fails open to a review"
assert_contains "$(out reason)" "large-pr" "pagination cap reason names the gate"

t_summary
