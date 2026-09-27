#!/bin/bash
# Runs every test/test_*.sh; exit code = number of failing suites.
DIR="$(cd "$(dirname "$0")" && pwd)"
# Under `npm test` this repo's npm_* variables leak into the nested npm calls
# the gate tests make and break them; drop them so both entry points match.
while IFS= read -r v; do unset "$v"; done < <(env | grep -oE '^(npm_[A-Za-z0-9_]+|INIT_CWD)')
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
