#!/usr/bin/env bash
# Zero-dependency test runner for the .github/scripts/ unit tests.
# Runs every tests/*.test.sh (bash scripts) and tests/*.test.mjs (plain
# Node, via the built-in `node:test` runner — no test framework
# dependency) in its own process, aggregating pass/fail.
# Usage: `npm test` or `bash tests/run.sh`.
set -uo pipefail
cd "$(dirname "$0")/.."

shopt -s nullglob
sh_files=(tests/*.test.sh)
mjs_files=(tests/*.test.mjs)
if [ ${#sh_files[@]} -eq 0 ] && [ ${#mjs_files[@]} -eq 0 ]; then
  echo "No test files found (tests/*.test.sh, tests/*.test.mjs)."
  exit 1
fi

failed=0
total=0
for f in "${sh_files[@]}"; do
  total=$((total + 1))
  printf '\n== %s ==\n' "$f"
  if ! bash "$f"; then
    failed=$((failed + 1))
  fi
done

for f in "${mjs_files[@]}"; do
  total=$((total + 1))
  printf '\n== %s ==\n' "$f"
  if ! node --test "$f"; then
    failed=$((failed + 1))
  fi
done

printf '\n========================================\n'
if [ "$failed" -eq 0 ]; then
  printf 'PASS — all %d test file(s) passed\n' "$total"
else
  printf 'FAIL — %d of %d test file(s) failed\n' "$failed" "$total"
  exit 1
fi
