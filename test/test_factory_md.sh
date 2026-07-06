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

## environment
- bash + python3 + gh CLI
- dev ports: 4000, 5555
- test account: qa@example.com hunter2secret
- backend port: 9000

## build
- node 21
- gh CLI authenticated
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

echo "read_env_bullet:"
assert_eq "4000, 5555" "$(read_env_bullet "dev ports" "$FIXTURE")" "key: value bullet read"
assert_eq "qa@example.com hunter2secret" "$(read_env_bullet "test account" "$FIXTURE")" "multi-word value read"
assert_eq "" "$(read_env_bullet "missing knob" "$FIXTURE")" "absent key is empty"

echo "resolve_knob:"
DETROIT="$TESTDIR"  # point resolve_knob at the fixture
cp "$FIXTURE" "$TESTDIR/factory.md"
# shellcheck disable=SC2034  # read indirectly via ${!1} in resolve_knob
KNOB_TEST_VAR="from-env"
assert_eq "from-env" "$(resolve_knob KNOB_TEST_VAR "dev ports" "fallback")" "env var wins"
unset KNOB_TEST_VAR
assert_eq "9000" "$(resolve_knob KNOB_TEST_VAR "backend port" "fallback")" "factory.md bullet second"
assert_eq "fallback" "$(resolve_knob KNOB_TEST_VAR "missing knob" "fallback")" "default last"
DETROIT="$DETROIT_ROOT"

echo "scaffold node version parse:"
assert_eq "21" "$(factory_section "build" "$FIXTURE" | sed -nE 's/^[-*+[:space:]]*node[[:space:]]+([0-9]+).*/\1/p' | head -1)" "node NN bullet parsed"

echo "factory_rules:"
OUT=$(factory_rules "$FIXTURE")
assert_contains "$OUT" "[style]" "rules include style"
assert_contains "$OUT" "[quality]" "rules include quality"
assert_not_contains "$OUT" "triage: prompt" "rules exclude stages section"

summarize
