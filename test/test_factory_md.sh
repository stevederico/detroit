#!/bin/bash
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
DETROIT="$TESTDIR"
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

echo "precreate_test_account:"
DETROIT="$TESTDIR/knobs"; mkdir -p "$DETROIT"
printf '%s\n' "## environment" "- test account: bullet@example.com bulletpass" "- signup api: /v2/signup" "- backend port: 9100" > "$DETROIT/factory.md"
stub_bin curl 'printf "%s\n" "$*" >> "$CURL_LOG"; case "$*" in *signin*) echo "{\"token\":\"t\"}" ;; *) echo "$SIGNUP_REPLY" ;; esac'
export CURL_LOG="$TESTDIR/curl.log" SIGNUP_REPLY='{"token":"t"}'
DEV_URL="http://localhost:5173"
precreate() { : > "$CURL_LOG"; env "$@" bash -c '. "$1"; . "$2"; DETROIT="$3"; DEV_URL="$4"; precreate_test_account; echo "$TEST_AUTH"' _ "$DETROIT_ROOT/lib/factory-md.sh" "$DETROIT_ROOT/lib/devserver.sh" "$DETROIT" "$DEV_URL"; }
OUT=$(precreate DETROIT_TEST_EMAIL=env@example.com DETROIT_TEST_PASSWORD=envpass DETROIT_SIGNUP_PATH=/env/signup DETROIT_BACKEND_PORT=7100)
assert_contains "$(cat "$CURL_LOG")" "http://localhost:7100/env/signup" "env signup path and backend port beat factory.md"
assert_contains "$OUT" "env@example.com / envpass" "env test account beats factory.md"
OUT=$(precreate -u DETROIT_TEST_EMAIL -u DETROIT_TEST_PASSWORD -u DETROIT_SIGNUP_PATH -u DETROIT_BACKEND_PORT)
assert_contains "$(cat "$CURL_LOG")" "http://localhost:9100/v2/signup" "factory.md signup api and backend port beat defaults"
assert_contains "$OUT" "bullet@example.com / bulletpass" "factory.md test account beats defaults"
OUT=$(precreate -u DETROIT_TEST_PASSWORD -u DETROIT_SIGNUP_PATH -u DETROIT_BACKEND_PORT DETROIT_TEST_EMAIL=env@example.com)
assert_contains "$OUT" "env@example.com / bulletpass" "env email alone keeps the factory.md password"
OUT=$(precreate -u DETROIT_TEST_EMAIL -u DETROIT_TEST_PASSWORD -u DETROIT_SIGNUP_PATH -u DETROIT_BACKEND_PORT SIGNUP_REPLY='{"error":"exists"}')
assert_contains "$(cat "$CURL_LOG")" "http://localhost:9100/v2/signin" "signin path follows the factory.md signup api"
assert_contains "$OUT" "Test account exists" "signup refused: signin fallback used"
: > "$DETROIT/factory.md"
OUT=$(precreate -u DETROIT_TEST_EMAIL -u DETROIT_TEST_PASSWORD -u DETROIT_SIGNUP_PATH -u DETROIT_BACKEND_PORT)
assert_contains "$(cat "$CURL_LOG")" "http://localhost:8000/api/signup" "no env, no bullets: default signup path and port"
assert_contains "$OUT" "test@detroit.dev / detroit123" "no env, no bullets: default test account"
DETROIT="$DETROIT_ROOT"

summarize
