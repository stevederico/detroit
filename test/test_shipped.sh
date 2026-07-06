#!/bin/bash
# Tests for verify_shipped (lib/pipeline.sh) — stubbed gh, local bare origin.
. "$(dirname "$0")/helpers.sh"

AGENT_ID=0
STATUS_DIR="$TESTDIR/.status"; mkdir -p "$STATUS_DIR"
LOGFILE="$TESTDIR/test.log"; : > "$LOGFILE"
TASK_FILE=""; WORKTREE_DIR=""; LOCK_DIR="$TESTDIR/.locks"; DETROIT="$DETROIT_ROOT"
. "$DETROIT_ROOT/lib/core.sh"
. "$DETROIT_ROOT/lib/pipeline.sh"
log() { echo "$1" >> "$LOGFILE"; }  # quiet log for tests

make_repo "$TESTDIR/repo"
git init -q --bare "$TESTDIR/origin.git"
git -C "$TESTDIR/repo" remote add origin "$TESTDIR/origin.git"
git -C "$TESTDIR/repo" push -q origin main
make_branch "$TESTDIR/repo" detroit/test
add_commit "$TESTDIR/repo" "f.js" "x"
git -C "$TESTDIR/repo" push -q origin detroit/test

REPO_DIR="$TESTDIR/repo"; BASE_BRANCH=main; BRANCH=detroit/test; IS_NEW_REPO=false

echo "verify_shipped:"
stub_bin gh 'echo "[{\"number\":7,\"url\":\"https://github.com/o/r/pull/7\"}]"'
verify_shipped
assert_eq "true" "$HAS_SHIPPED" "commits + open PR → shipped"
assert_eq "7" "$PR_NUM" "PR number from gh, not log scraping"
assert_eq "https://github.com/o/r/pull/7" "$PR_URL" "PR URL captured"

stub_bin gh 'echo "[]"'
verify_shipped
assert_eq "false" "$HAS_SHIPPED" "commits but no open PR → not shipped"

stub_bin gh 'exit 1'
verify_shipped
assert_eq "true" "$HAS_SHIPPED" "gh outage + branch on origin → shipped fallback"
assert_contains "$(cat "$LOGFILE")" "WARN" "fallback logged as WARN"

make_repo "$TESTDIR/empty"
git init -q --bare "$TESTDIR/origin2.git"
git -C "$TESTDIR/empty" remote add origin "$TESTDIR/origin2.git"
make_branch "$TESTDIR/empty" detroit/test
REPO_DIR="$TESTDIR/empty"
stub_bin gh 'echo "[]"'
verify_shipped
assert_eq "false" "$HAS_SHIPPED" "no commits on branch → not shipped"

REPO_DIR="$TESTDIR/repo"; IS_NEW_REPO=true
verify_shipped
assert_eq "true" "$HAS_SHIPPED" "new repo with commits + reachable origin → shipped"
assert_eq "" "$PR_NUM" "new repo has no PR"

summarize
