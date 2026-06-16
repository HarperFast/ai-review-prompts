#!/usr/bin/env bash
# Zero-dependency test runner for the .github/scripts/ unit tests.
# Runs every tests/*.test.sh in its own process and aggregates pass/fail.
# Usage: `npm test` or `bash tests/run.sh`.
set -uo pipefail
cd "$(dirname "$0")/.."

shopt -s nullglob
files=(tests/*.test.sh)
if [ ${#files[@]} -eq 0 ]; then
  echo "No test files found (tests/*.test.sh)."
  exit 1
fi

failed=0
for f in "${files[@]}"; do
  printf '\n== %s ==\n' "$f"
  if ! bash "$f"; then
    failed=$((failed + 1))
  fi
done

printf '\n========================================\n'
if [ "$failed" -eq 0 ]; then
  printf 'PASS — all %d test file(s) passed\n' "${#files[@]}"
else
  printf 'FAIL — %d of %d test file(s) failed\n' "$failed" "${#files[@]}"
  exit 1
fi
