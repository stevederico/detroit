#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
bin="$root/bin/detroit"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0
failed=0

ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() {
  failed=$((failed + 1))
  printf 'FAIL %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /'
}
check() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1" "want: $2 / got: $3"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "missing: $2 / in: $3" ;; esac; }
lacks() { case "$3" in *"$2"*) bad "$1" "found: $2 / in: $3" ;; *) ok "$1" ;; esac; }

mkdir -p "$work/bin"
export GIT_CONFIG_GLOBAL="$work/gitconfig"
: > "$GIT_CONFIG_GLOBAL"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export DETROIT_STATE="$work/state" DETROIT_TASKS="$work/tasks" DETROIT_PROJECTS="$work/projects"
export DETROIT_LESSONS="$work/lessons.md" DETROIT_PAUSE=0 DETROIT_UNIT_DIR="$work/units"
export GH_PR_URL_FILE="$work/pr-url" GH_SIGNED_IN=1 STUB_LOG="$work/stub.log" STUB_CODE_PROMPT="$work/code-prompt"
export DETROIT_AGENT_CMD="$work/bin/agent-stub"
export PATH="$work/bin:$PATH"

cat > "$work/bin/gh" << 'EOF'
#!/bin/sh
case "$1 $2" in
  "auth status") [ "$GH_SIGNED_IN" = 1 ]; exit $? ;;
  "pr list") [ -f "$GH_PR_URL_FILE" ] && cat "$GH_PR_URL_FILE"; exit 0 ;;
esac
exit 0
EOF
cat > "$work/bin/agent-stub" << 'EOF'
#!/bin/sh
case "$1" in
  *"needs a written plan"*)
    echo plan >> "$STUB_LOG"
    [ "${STUB_PLAN:-0}" = 1 ] && echo "the plan text" > "$DETROIT_PLAN"
    ;;
  *)
    echo code >> "$STUB_LOG"
    printf '%s' "$1" > "$STUB_CODE_PROMPT"
    [ "${STUB_PR:-1}" = 1 ] && echo https://example.test/pr/1 > "$GH_PR_URL_FILE"
    ;;
esac
exit 0
EOF
cat > "$work/bin/systemctl" << 'EOF'
#!/bin/sh
echo "$@" >> "$STUB_LOG"
EOF
chmod +x "$work/bin/gh" "$work/bin/agent-stub" "$work/bin/systemctl"

reset() {
  rm -rf "$work/tasks" "$work/state" "$work/lessons.md" "$work/pr-url" "$work/stub.log" "$work/code-prompt"
  unset STUB_PLAN STUB_PR
  export GH_SIGNED_IN=1
}

git init -q -b main "$work/projects/app"
git -C "$work/projects/app" commit -q --allow-empty -m init

reset
out="$("$bin" help)"
has 'help lists the commands' 'shift [--hours N]' "$out"
"$bin" nonsense > /dev/null 2>&1
check 'an unknown command exits 2' 2 $?

reset
f1="$("$bin" add "fix the login bug" --repo app)"
f2="$("$bin" add "fix the login bug")"
check 'add names the file from the text' "$work/tasks/fix-the-login-bug.md" "$f1"
check 'add never overwrites a task' "$work/tasks/fix-the-login-bug-2.md" "$f2"
has 'add writes the repo into the frontmatter' 'repo: app' "$(cat "$f1")"
has 'add writes the text as the body' 'fix the login bug' "$(cat "$f1")"

reset
"$bin" add "first task" --repo app --name 01-first > /dev/null
"$bin" add "second task" --repo app --name 02-second > /dev/null
out="$("$bin" run 2>&1)"
check 'run succeeds when a pull request exists' 0 $?
[ -f "$work/tasks/done/01-first.md" ] && ok 'run takes the first task alphabetically and files it in done' || bad 'run files the task in done' "$out"
[ -f "$work/tasks/02-second.md" ] && ok 'run leaves the next task in the queue' || bad 'run leaves the next task in the queue'
has 'the code prompt carries the task' 'first task' "$(cat "$work/code-prompt")"
lacks 'the task frontmatter stays out of the prompt' 'repo: app' "$(cat "$work/code-prompt")"
has 'the code prompt tells the agent to use garden pr' 'garden pr' "$(cat "$work/code-prompt")"
check 'the worktree is removed after success' '' "$(ls "$work/state/work")"
has 'results log the pull request' 'https://example.test/pr/1' "$(cat "$work/state/results.log")"
check 'a lock is released after the run' '' "$(ls "$work/state/locks")"

reset
STUB_PLAN=1 "$bin" add "plan me" --repo app --name planned > /dev/null
STUB_PLAN=1 "$bin" run > /dev/null 2>&1
has 'an approved plan goes into the code prompt' 'the plan text' "$(cat "$work/code-prompt")"
has 'the code prompt labels the plan' 'APPROVED PLAN' "$(cat "$work/code-prompt")"

reset
"$bin" add "no plan" --repo app --name noplan > /dev/null
"$bin" run > /dev/null 2>&1
lacks 'no plan means no plan section' 'APPROVED PLAN' "$(cat "$work/code-prompt")"

reset
printf -- '- earlier: the build broke on a missing flag\n' > "$work/lessons.md"
"$bin" add "lesson task" --repo app --name lessons > /dev/null
"$bin" run > /dev/null 2>&1
has 'lessons go into the code prompt' 'the build broke on a missing flag' "$(cat "$work/code-prompt")"

reset
"$bin" add "no pr task" --repo app --name nopr > /dev/null
STUB_PR=0 "$bin" run > /dev/null 2>&1
check 'run exits 1 when no pull request exists' 1 $?
[ -f "$work/tasks/failed/nopr.md" ] && ok 'a task with no pull request moves to failed' || bad 'a task with no pull request moves to failed'
has 'a failure is written to lessons.md' 'nopr' "$(cat "$work/lessons.md")"
[ -n "$(ls "$work/state/work")" ] && ok 'the worktree is kept after a failure' || bad 'the worktree is kept after a failure'

reset
"$bin" add "missing repo" --repo nosuchrepo --name missing > /dev/null
"$bin" run > /dev/null 2>&1
check 'run exits 1 when the repo does not exist' 1 $?
[ -f "$work/tasks/failed/missing.md" ] && ok 'a task whose repo is missing moves to failed' || bad 'a task whose repo is missing moves to failed'

reset
"$bin" run > /dev/null 2>&1
check 'run exits 2 on an empty queue' 2 $?

reset
"$bin" add "signed out" --repo app --name signedout > /dev/null
GH_SIGNED_IN=0 "$bin" run > /dev/null 2>&1
check 'run exits 1 when gh is signed out' 1 $?
[ -f "$work/tasks/signedout.md" ] && ok 'gh signed out leaves the task in the queue' || bad 'gh signed out leaves the task in the queue'

reset
out="$("$bin" shift 2>&1)"
check 'shift exits 0 on an empty queue' 0 $?
has 'shift says the queue is empty' 'queue empty' "$out"
[ ! -e "$work/state/shift.lock" ] && ok 'shift releases its lock' || bad 'shift releases its lock'

reset
"$bin" add "one" --repo app --name a > /dev/null
"$bin" add "two" --repo app --name b > /dev/null
"$bin" shift > /dev/null 2>&1
[ -f "$work/tasks/done/a.md" ] && [ -f "$work/tasks/done/b.md" ] && ok 'shift runs every task until the queue is empty' || bad 'shift runs every task until the queue is empty'

reset
"$bin" add "capped" --repo app --name capped > /dev/null
"$bin" shift --hours 0 > /dev/null 2>&1
[ -f "$work/tasks/capped.md" ] && ok 'shift --hours 0 runs nothing' || bad 'shift --hours 0 runs nothing'

reset
mkdir -p "$work/state/shift.lock"
sleep 30 &
holder=$!
echo "$holder" > "$work/state/shift.lock/pid"
out="$("$bin" shift 2>&1)"
has 'a second shift defers to a live one' 'another shift is running' "$out"
kill "$holder" 2> /dev/null
wait "$holder" 2> /dev/null
out="$("$bin" shift 2>&1)"
has 'a lock left by a dead pid is taken over' 'queue empty' "$out"

cat > "$work/bin/claude" << 'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$STUB_ARGS"
case "$*" in
  *"needs a written plan"*) ;;
  *) echo https://example.test/pr/1 > "$GH_PR_URL_FILE" ;;
esac
EOF
cp "$work/bin/claude" "$work/bin/grok"
cp "$work/bin/claude" "$work/bin/opencode"
chmod +x "$work/bin/claude" "$work/bin/grok" "$work/bin/opencode"
export STUB_ARGS="$work/agent-args"

for agent in claude grok opencode; do
  reset
  "$bin" add "real $agent" --repo app --name "real-$agent" > /dev/null
  env -u DETROIT_AGENT_CMD DETROIT_AGENT="$agent" "$bin" run > /dev/null 2>&1
  check "$agent runs as the agent with no model set" 0 $?
  [ -f "$work/tasks/done/real-$agent.md" ] && ok "$agent task is filed in done" || bad "$agent task is filed in done"
done
has 'claude runs headless and skips prompts' '--dangerously-skip-permissions' "$(
  reset
  "$bin" add "claude flags" --repo app --name flags > /dev/null
  env -u DETROIT_AGENT_CMD DETROIT_AGENT=claude "$bin" run > /dev/null 2>&1
  cat "$work/agent-args"
)"
has 'DETROIT_MODEL reaches the agent' '--model sonnet' "$(
  reset
  "$bin" add "model flag" --repo app --name model > /dev/null
  env -u DETROIT_AGENT_CMD DETROIT_AGENT=claude DETROIT_MODEL=sonnet "$bin" run > /dev/null 2>&1
  cat "$work/agent-args"
)"
reset
"$bin" add "bad agent" --repo app --name bad > /dev/null
env -u DETROIT_AGENT_CMD DETROIT_AGENT=nosuchagent "$bin" run > /dev/null 2>&1
check 'an agent that is not installed stops the run before any task is touched' 1 $?
[ -f "$work/tasks/bad.md" ] && ok 'the task stays queued when the agent is missing' || bad 'the task stays queued when the agent is missing'

reset
"$bin" add "queued" --repo app --name q > /dev/null
out="$("$bin" status)"
has 'status shows the queue size' 'queue: 1 task(s)' "$out"
has 'status shows nothing running' 'running: none' "$out"
has 'status shows the shift state' 'shift: not running' "$out"

reset
"$bin" install > /dev/null 2>&1
has 'install writes the service with the shift command' "ExecStart=$bin shift" "$(cat "$work/units/detroit-nightly.service")"
has 'install writes the 01:00 timer' 'OnCalendar=*-*-* 01:00:00' "$(cat "$work/units/detroit-nightly.timer")"
has 'install enables the timer' 'enable --now detroit-nightly.timer' "$(cat "$work/stub.log")"
"$bin" uninstall > /dev/null 2>&1
[ ! -e "$work/units/detroit-nightly.timer" ] && ok 'uninstall removes the units' || bad 'uninstall removes the units'

printf '%s passed, %s failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
