#!/bin/bash
# Runs every test/test_*.sh; exit code = number of failing suites.
DIR="$(cd "$(dirname "$0")" && pwd)"
FAILED=0
for t in "$DIR"/test_*.sh; do
  echo "━━━ $(basename "$t") ━━━"
  bash "$t" || FAILED=$((FAILED + 1))
  echo ""
done
if [ "$FAILED" = 0 ]; then
  echo "all suites passed"
else
  echo "$FAILED suite(s) failed"
fi
exit "$FAILED"
