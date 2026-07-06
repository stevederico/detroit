#!/bin/bash
# Tests for lib/factory-md.sh parsing.
. "$(dirname "$0")/helpers.sh"
. "$DETROIT_ROOT/lib/factory-md.sh"

FIXTURE="$TESTDIR/factory.md"
cat > "$FIXTURE" <<'EOF'
---
name: fixture
version: 2
---

# fixture factory

## stages
- triage: prompt
- build: style, build
- test: testing, quality

## Style
- camelCase functions
- ! No secrets in committed files

## testing
- Vitest colocated
- ! All tests must pass

## quality
- ! No files over 500 lines
EOF

echo "factory_section:"
assert_eq "- camelCase functions
- ! No secrets in committed files" "$(factory_section style "$FIXTURE" | sed '/^$/d')" "case-insensitive section extraction"
assert_eq "" "$(factory_section security "$FIXTURE")" "missing section is empty"
assert_contains "$(factory_section testing "$FIXTURE")" "Vitest colocated" "section terminates at next H2"
assert_not_contains "$(factory_section testing "$FIXTURE")" "500 lines" "section body excludes next section"

echo "factory_stages:"
assert_eq "triage:prompt
build:style, build
test:testing, quality" "$(factory_stages "$FIXTURE")" "v2 stages parsed as stage:value lines"

V1="$TESTDIR/v1.md"
printf '# v1 factory\n\n## style\n- a rule\n' > "$V1"
assert_eq "" "$(factory_stages "$V1")" "v1 file (no stages) yields empty"

echo "factory_rules_for_stage:"
OUT=$(factory_rules_for_stage "style, testing" "$FIXTURE")
assert_contains "$OUT" "[style]" "csv includes style"
assert_contains "$OUT" "[testing]" "csv includes testing"
assert_not_contains "$OUT" "[quality]" "csv excludes quality"
assert_eq "" "$(factory_rules_for_stage "prompt, bogus" "$FIXTURE")" "unknown sections skipped"

echo "factory_rules:"
OUT=$(factory_rules "$FIXTURE")
assert_contains "$OUT" "[style]" "rules include style"
assert_contains "$OUT" "[quality]" "rules include quality"
assert_not_contains "$OUT" "triage: prompt" "rules exclude stages section"

summarize
