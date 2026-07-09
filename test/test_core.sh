#!/bin/bash
# Tests for lib/core.sh helpers: resolve_gh_repo, append_lesson, quality_fail.
. "$(dirname "$0")/helpers.sh"

AGENT_ID=0
STATUS_DIR="$TESTDIR/.status"; mkdir -p "$STATUS_DIR"
LOGFILE="$TESTDIR/test.log"; : > "$LOGFILE"
DETROIT="$TESTDIR/detroit"; mkdir -p "$DETROIT"
TASK_FILE=""; WORKTREE_DIR=""; LOCK_DIR="$TESTDIR/.locks"
. "$DETROIT_ROOT/lib/core.sh"
log() { echo "$1" >> "$LOGFILE"; }

echo "resolve_gh_repo:"
make_repo "$TESTDIR/repo"
# gh repo view succeeds
stub_bin gh 'if [ "$1" = "repo" ] && [ "$2" = "view" ]; then echo "acme/widget"; exit 0; fi; exit 1'
assert_eq "acme/widget" "$(resolve_gh_repo "$TESTDIR/repo")" "gh repo view → owner/name"

# gh fails; parse origin HTTPS
stub_bin gh 'exit 1'
git -C "$TESTDIR/repo" remote add origin "https://github.com/org/app.git"
assert_eq "org/app" "$(resolve_gh_repo "$TESTDIR/repo")" "https origin → owner/name"

# SSH remote
git -C "$TESTDIR/repo" remote set-url origin "git@github.com:team/svc.git"
assert_eq "team/svc" "$(resolve_gh_repo "$TESTDIR/repo")" "ssh origin → owner/name"

# fallback: user + basename
git -C "$TESTDIR/repo" remote remove origin
stub_bin gh 'if [ "$1" = "api" ]; then echo "alice"; exit 0; fi; exit 1'
assert_eq "alice/repo" "$(resolve_gh_repo "$TESTDIR/repo")" "fallback user + basename"

echo "append_lesson:"
append_lesson "gates: changelog missing"
assert_eq "true" "$([ -f "$DETROIT/lessons.md" ] && echo true || echo false)" "creates lessons.md"
assert_contains "$(cat "$DETROIT/lessons.md")" "gates: changelog missing" "lesson body written"
# Cap at 50 bullets
i=0
while [ "$i" -lt 55 ]; do
  append_lesson "noise $i"
  i=$((i + 1))
done
count=$(grep -c '^- ' "$DETROIT/lessons.md")
assert_eq "50" "$count" "lessons capped at 50 bullets"

echo "quality_fail:"
QUALITY_OK=true
quality_fail "ci" "still red"
assert_eq "false" "$QUALITY_OK" "QUALITY_OK flipped"
assert_contains "$(cat "$DETROIT/lessons.md")" "ci: still red" "quality_fail records lesson"

summarize
