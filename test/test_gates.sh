#!/bin/bash
# Tests for lib/gates.sh — characterizes each check_gate case and the bullet runner.
. "$(dirname "$0")/helpers.sh"

AGENT_ID=0
STATUS_DIR="$TESTDIR/.status"; mkdir -p "$STATUS_DIR"
LOGFILE="$TESTDIR/test.log"; : > "$LOGFILE"
TASK_FILE=""; WORKTREE_DIR=""; LOCK_DIR="$TESTDIR/.locks"; DETROIT="$DETROIT_ROOT"
. "$DETROIT_ROOT/lib/core.sh"
. "$DETROIT_ROOT/lib/factory-md.sh"
. "$DETROIT_ROOT/lib/gates.sh"
log() { echo "$1" >> "$LOGFILE"; }  # quiet log for tests

# fresh_repo <name> — new fixture repo on branch detroit/test; sets globals, cds into it
fresh_repo() {
  REPO_DIR="$TESTDIR/$1"
  make_repo "$REPO_DIR"
  make_branch "$REPO_DIR" detroit/test
  BASE_BRANCH=main
  BRANCH=detroit/test
  PRE_VERSION=""
  cd "$REPO_DIR" || exit 1
}

echo "secret filename gate:"
fresh_repo sec1
add_commit "$REPO_DIR" ".env" "API_KEY=abc"
assert_rc 1 ".env file in diff fails" check_gate "No secrets in committed files"
fresh_repo sec2
add_commit "$REPO_DIR" "notes.txt" "hello"
assert_rc 0 "plain file passes" check_gate "No secrets in committed files"

echo "changelog gate:"
fresh_repo ch1
add_commit "$REPO_DIR" "app.js" "x"
assert_rc 1 "missing changelog fails" check_gate "CHANGELOG.md updated per PR"
add_commit "$REPO_DIR" "CHANGELOG.md" "0.1.0"
assert_rc 0 "changelog in diff passes" check_gate "CHANGELOG.md updated per PR"

echo "version bump gate:"
fresh_repo v1
add_commit "$REPO_DIR" "package.json" '{"version": "1.0.0"}'
PRE_VERSION="1.0.0"
assert_rc 1 "unchanged version fails" check_gate "package.json version bumped per PR"
add_commit "$REPO_DIR" "package.json" '{"version": "1.1.0"}'
assert_rc 0 "bumped version passes" check_gate "package.json version bumped per PR"
PRE_VERSION=""
assert_rc 0 "no PRE_VERSION skips" check_gate "package.json version bumped per PR"

echo "tests-pass gate (deterministic):"
fresh_repo t1
DETROIT_TEST_CMD="exit 0"
assert_rc 0 "passing test command passes" check_gate "All tests must pass before a PR is opened"
DETROIT_TEST_CMD="exit 1"
assert_rc 1 "failing test command fails" check_gate "All tests must pass before a PR is opened"
DETROIT_TEST_CMD="sleep 30"
DETROIT_TEST_TIMEOUT=2
assert_rc 1 "hung test command times out" check_gate "All tests must pass before a PR is opened"
unset DETROIT_TEST_CMD DETROIT_TEST_TIMEOUT
assert_rc 0 "no package.json → skip-pass" check_gate "All tests must pass before a PR is opened"
add_commit "$REPO_DIR" "package.json" '{"scripts": {"test": "echo \"Error: no test specified\" && exit 1"}}'
assert_rc 1 "npm placeholder script → fail" check_gate "All tests must pass before a PR is opened"
fresh_repo t1b
add_commit "$REPO_DIR" "package.json" '{"name":"t1b","version":"1.0.0"}'
assert_rc 1 "package.json with no test script → fail" check_gate "All tests must pass before a PR is opened"
if command -v npm >/dev/null 2>&1; then
  fresh_repo t2
  add_commit "$REPO_DIR" "package.json" '{"name":"t2","version":"1.0.0","scripts":{"test":"node -e \"process.exit(0)\""}}'
  assert_rc 0 "real npm test run passes" check_gate "All tests must pass before a PR is opened"
fi

echo "test failure output threading:"
fresh_repo t3
GATE_FAILURES=""; GATE_CUSTOM=""; GATE_SEEN=""
DETROIT_TEST_CMD="echo boom-notice; exit 1"
run_gate_bullets < <(printf '%s\n' "- ! All tests must pass before a PR is opened")
unset DETROIT_TEST_CMD
assert_contains "$GATE_FAILURES" "boom-notice" "failing test output threaded into GATE_FAILURES"

echo "secret content scan:"
# Secret-shaped fixtures are concatenated so this test file never contains one itself
AWS_FAKE="AKIA""BCDEFGHIJKLMNOPQ"
GH_FAKE="ghp_""ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
PEM_FAKE="-----BEGIN RSA"" PRIVATE KEY-----"
PW_FAKE='const pass''word = "supersecretvalue99"'
fresh_repo sc1
add_commit "$REPO_DIR" "config.js" "const key = '$AWS_FAKE'"
assert_rc 1 "AWS key in diff content fails secret gate" check_gate "No secrets in committed files"
assert_rc 1 "AWS key fails credential gate too" check_gate "No hardcoded api key values"
fresh_repo sc2
add_commit "$REPO_DIR" "auth.js" "token = '$GH_FAKE'"
assert_rc 1 "GitHub token in diff fails" check_gate "No hardcoded api key values"
fresh_repo sc3
add_commit "$REPO_DIR" "deploy.txt" "$PEM_FAKE"
assert_rc 1 "PEM header in diff fails" check_gate "No hardcoded api key values"
fresh_repo sc4
add_commit "$REPO_DIR" "login.js" "$PW_FAKE"
assert_rc 1 "quoted password assignment fails" check_gate "No hardcoded api key values"
fresh_repo sc5
add_commit "$REPO_DIR" "package-lock.json" "{\"integrity\": \"sha512-$AWS_FAKE\"}"
assert_rc 0 "lockfile content excluded from scan" check_gate "No secrets in committed files"
fresh_repo sc6
add_commit "$REPO_DIR" "README.md" "rotate your api key regularly"
assert_rc 0 "prose about keys passes" check_gate "No hardcoded api key values"
fresh_repo sc7
add_commit "$REPO_DIR" "config.envelope.js" "export const x = 1"
assert_rc 0 "config.envelope.js not flagged by .env filename check" check_gate "No secrets in committed files"

echo "500-line gate:"
fresh_repo big1
python3 -c "print('x\n' * 501, end='')" > big.js
git add -A && git commit -qm big
assert_rc 1 "501-line file fails" check_gate "No files over 500 lines"
fresh_repo big2
python3 -c "print('x\n' * 100, end='')" > small.js
git add -A && git commit -qm small
assert_rc 0 "small file passes" check_gate "No files over 500 lines"

echo "todo gate:"
fresh_repo td1
add_commit "$REPO_DIR" "app.js" "// TODO: later"
assert_rc 1 "added TODO fails" check_gate "No new TODO or FIXME introduced in the diff"
fresh_repo td2
add_commit "$REPO_DIR" "app.js" "done()"
assert_rc 0 "no TODO passes" check_gate "No new TODO or FIXME introduced in the diff"

echo "hardcoded credential gate:"
fresh_repo hc1
add_commit "$REPO_DIR" "config.js" 'const api_key = "abcdef123456789"'
assert_rc 1 "quoted api_key literal fails" check_gate "No hardcoded api key values"
fresh_repo hc2
add_commit "$REPO_DIR" "config.js" 'const api_key = process.env.API_KEY'
assert_rc 0 "env-sourced key passes" check_gate "No hardcoded api key values"

echo "eval gate:"
fresh_repo ev1
add_commit "$REPO_DIR" "app.js" 'eval(userInput)'
assert_rc 1 "added eval() fails" check_gate "No eval() or equivalent"
fresh_repo ev2
add_commit "$REPO_DIR" "app.js" 'evaluate(x)'
assert_rc 0 "evaluate() passes" check_gate "No eval() or equivalent"

echo "exec interpolation gate:"
fresh_repo ex1
add_commit "$REPO_DIR" "app.js" 'exec(`rm ${userPath}`)'
assert_rc 1 "interpolated exec fails" check_gate "No child_process.exec with interpolated user input"
fresh_repo ex2
add_commit "$REPO_DIR" "app.js" 'execSync("ls -la")'
assert_rc 0 "static exec passes" check_gate "No child_process.exec with interpolated user input"

echo "inline check suffix:"
fresh_repo ic1
assert_rc 0 "check: exit 0 passes" check_gate 'anything `check: exit 0`'
assert_rc 1 "check: exit 1 fails" check_gate 'anything `check: exit 1`'
assert_rc 0 "check runs in REPO_DIR" check_gate 'repo files `check: test -f README.md`'

echo "unrecognized gate:"
fresh_repo un1
assert_rc 2 "unknown rule returns 2" check_gate "Single responsibility per function"

echo "run_gate_bullets:"
fresh_repo rb1
GATE_FAILURES=""; GATE_CUSTOM=""; GATE_SEEN=""
run_gate_bullets < <(printf '%s\n' "- ! Single responsibility per function" "- Log errors with context" "- Log errors with context")
assert_contains "$GATE_FAILURES" "Single responsibility" "strict unrecognized lands in GATE_FAILURES"
assert_contains "$GATE_CUSTOM" "Log errors with context" "plain unrecognized lands in GATE_CUSTOM"
assert_eq "1" "$(printf '%b' "$GATE_CUSTOM" | grep -c 'Log errors')" "duplicate bullets deduped via GATE_SEEN"

echo "run_all_gates (staged factory.md):"
fresh_repo ra1
add_commit "$REPO_DIR" "CHANGELOG.md" "0.1.0"
cat > "$TESTDIR/staged.md" <<'EOF'
## stages
- triage: prompt
- test: quality

## quality
- ! CHANGELOG.md updated per PR
- Custom quality rule
EOF
run_all_gates "$TESTDIR/staged.md"
assert_eq "" "$GATE_FAILURES" "strict changelog rule passes via stage grouping"
assert_contains "$GATE_CUSTOM" "Custom quality rule" "plain custom rule forwarded"

summarize
