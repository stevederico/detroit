#!/bin/bash
# Tests for lib/shift.sh (--shift mode). Fixture usage JSON, fake pipeline,
# stubbed herdr and omarchy-agent-usage-update. No live Claude call.
. "$(dirname "$0")/helpers.sh"

AGENT_ID=0
STATUS_DIR="$TESTDIR/.status"; mkdir -p "$STATUS_DIR"
LOGDIR="$TESTDIR/logs"; mkdir -p "$LOGDIR"
TIMESTAMP="test"; LOGFILE="$LOGDIR/setup.log"
DETROIT="$TESTDIR/detroit"
TASK_DIR="$DETROIT/tasks"; LOCK_DIR="$TASK_DIR/.locks"
mkdir -p "$TASK_DIR/done" "$TASK_DIR/failed" "$LOCK_DIR"
TASK_FILE=""; WORKTREE_DIR=""
DRY_RUN=false; REPO_FILTER=""
. "$DETROIT_ROOT/lib/core.sh"
. "$DETROIT_ROOT/lib/shift.sh"
log() { echo "$1" >> "$LOGFILE"; }
stage() { :; }

export XDG_STATE_HOME="$TESTDIR/state"
USAGE_DIR="$XDG_STATE_HOME/omarchy/agents/usage"
mkdir -p "$USAGE_DIR"
unset DETROIT_AGENT DETROIT_MODEL DETROIT_BUDGET_STOP DETROIT_USAGE_MAX_AGE DETROIT_SHIFT_SKIP
export DETROIT_SHIFT_PAUSE=0

# Never reach the real Herdr or the real Omarchy collectors
stub_bin herdr 'exit 1'
stub_bin omarchy-agent-usage-update "echo called >> '$TESTDIR/refreshes'"

now_iso() { python3 -c 'import datetime as d; print(d.datetime.now(d.timezone.utc).isoformat())'; }
OLD_ISO="2020-01-01T00:00:00+00:00"

# write_usage <session|-> <weekly|-> [updatedAt] [extra-limit-json] — fixture
# for the current agent (grok by default)
write_usage() {
  local s="$1" w="$2" at="${3:-$(now_iso)}" extra="${4:-}" limits=""
  [ "$s" = "-" ] || limits="{\"label\":\"Session (5-hour)\",\"percent\":$s,\"resetsAt\":\"2099-01-01T00:00:00+00:00\"}"
  if [ "$w" != "-" ]; then
    [ -n "$limits" ] && limits="$limits,"
    limits="$limits{\"label\":\"Weekly (7-day)\",\"percent\":$w,\"resetsAt\":\"2099-01-01T00:00:00+00:00\"}"
  fi
  if [ -n "$extra" ]; then
    [ -n "$limits" ] && limits="$limits,"
    limits="$limits$extra"
  fi
  printf '{"schemaVersion":1,"updatedAt":"%s","limits":[%s]}\n' "$at" "$limits" > "$USAGE_DIR/${DETROIT_AGENT:-grok}.json"
}
USAGE_FILE="$USAGE_DIR/grok.json"

add_task() { printf '%s\n' "${2:-do the thing}" > "$TASK_DIR/$1"; }
count() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }

# Fake child factory.sh: PICK exactly like the real one (pick_task --lock
# under the exported skip list), then per FAKE_CHILD: ship → tasks/done/,
# anything else → left in tasks/ (dry run, or stopped before SHIP). The lock is
# released either way, as postship.sh and the dry-run summary do.
shift_run_task() {
  local t; t=$(pick_task --lock)
  echo "$(basename "${t:-none}")" >> "$TESTDIR/runs"
  [ -n "$t" ] || return 0
  [ "${FAKE_CHILD:-leave}" = ship ] && mv "$t" "$TASK_DIR/done/"
  rm -rf "$LOCK_DIR/$(basename "$t").lock"
  return "${FAKE_RC:-0}"
}
shift_sleep() { echo slept >> "$TESTDIR/sleeps"; }

# run_shift — fresh counters and log, then one mode_shift; sets RC and LOG
run_shift() {
  rm -f "$TESTDIR/runs" "$TESTDIR/sleeps" "$TESTDIR/refreshes" "$LOGDIR"/*
  RC=0
  mode_shift || RC=$?
  LOG=$(cat "$LOGFILE" 2>/dev/null)
}
runs() { [ -f "$TESTDIR/runs" ] || return 0; tr '\n' ' ' < "$TESTDIR/runs" | sed 's/ $//'; }

reset_tasks() { rm -rf "${TASK_DIR:?}"/*.md "${TASK_DIR:?}/done"/* "${TASK_DIR:?}/failed"/* "${LOCK_DIR:?}"/*; }

echo "shift_read_usage:"
write_usage 0.2 0.04
assert_eq "ok 0.2 0.04" "$(shift_read_usage "$USAGE_FILE")" "session + weekly fractions"
write_usage - 0.63
assert_eq "ok - 0.63" "$(shift_read_usage "$USAGE_FILE")" "weekly-only record (grok shape)"
assert_eq "missing" "$(shift_read_usage "$USAGE_DIR/nope.json")" "missing file"
echo 'not json' > "$TESTDIR/bad.json"
assert_eq "missing" "$(shift_read_usage "$TESTDIR/bad.json")" "unreadable JSON counts as missing"
write_usage 0.2 0.04 "$OLD_ISO"
assert_eq "stale" "$(shift_read_usage "$USAGE_FILE")" "old updatedAt is stale"
write_usage 0.2 0.04 "$(now_iso)"
assert_eq "stale" "$(DETROIT_USAGE_MAX_AGE=-1 shift_read_usage "$USAGE_FILE")" "DETROIT_USAGE_MAX_AGE honored"

FABLE='{"label":"Fable Weekly","title":"Fable Weekly","percent":0.9,"resetsAt":"2099-01-01T00:00:00+00:00"}'
write_usage 0.2 0.1 "" "$FABLE"
assert_eq "ok 0.2 0.1" "$(shift_read_usage "$USAGE_FILE")" "scoped row ignored without DETROIT_MODEL"
assert_eq "ok 0.2 0.9" "$(DETROIT_MODEL=claude-fable-5-1 shift_read_usage "$USAGE_FILE")" "DETROIT_MODEL counts a fuller scoped row"
FABLE_LOW='{"label":"Fable Weekly","title":"Fable Weekly","percent":0.0}'
write_usage 0.2 0.95 "" "$FABLE_LOW"
assert_eq "ok 0.2 0.95" "$(DETROIT_MODEL=claude-fable-5-1 shift_read_usage "$USAGE_FILE")" "empty scoped row never hides the account-wide limit"
write_usage 0.2 0.1 "" "$FABLE"
assert_eq "ok 0.2 0.1" "$(DETROIT_MODEL=claude-opus-5-5 shift_read_usage "$USAGE_FILE")" "non-matching model keeps unscoped row"

printf '{"id":"fireworks","updatedAt":"%s","tierLabel":"Prepaid","limits":[]}\n' "$(now_iso)" > "$TESTDIR/prepaid.json"
assert_eq "noreset" "$(shift_read_usage "$TESTDIR/prepaid.json")" "prepaid, no limits → noreset"
printf '{"id":"cursor","updatedAt":"%s","limits":[{"label":"Included total","percent":0.5}]}\n' "$(now_iso)" > "$TESTDIR/total.json"
assert_eq "noreset" "$(shift_read_usage "$TESTDIR/total.json")" "balance row without a session/weekly window → noreset"

echo "shift_at_or_above:"
assert_rc 0 "0.80 >= 0.80" shift_at_or_above 0.80 0.80
assert_rc 1 "0.79 < 0.80" shift_at_or_above 0.79 0.80
assert_rc 1 "absent window never stops" shift_at_or_above - 0.80

echo "mode_shift:"
reset_tasks; add_task a.md; write_usage 0.79 0.10
run_shift
assert_eq 0 "$RC" "session 0.79: exit 0"
assert_eq "a.md" "$(runs)" "session 0.79 + one task: pipeline runs once"
assert_contains "$LOG" "idle — no tasks" "task left in place is not rerun; shift ends on no tasks"
assert_eq "false" "$([ -d "$DETROIT/.shift.lock" ] && echo true || echo false)" "shift lock released"
assert_eq "true" "$([ -f "$LOGDIR/test-shift.log" ] && echo true)" "shift logs to its own -shift.log"
assert_contains "$(cat "$STATUS_DIR/agent-shift")" "idle — no tasks" "shift status in agent-shift"

reset_tasks; add_task a.md; add_task b.md; add_task c.md; write_usage 0.1 0.1
FAKE_RC=1 run_shift
assert_eq "a.md b.md c.md" "$(runs)" "tasks that stop before SHIP don't block the queue"
assert_contains "$LOG" "(3 ran, 3 failed)" "failures counted"

reset_tasks; add_task a.md; add_task b.md; mkdir "$LOCK_DIR/a.md.lock"
touch -t 202001010000 "$LOCK_DIR/a.md.lock"
FAKE_CHILD=ship run_shift
assert_eq "a.md b.md" "$(runs)" "stale lock: shift and PICK agree on the same task"

reset_tasks; add_task a.md; write_usage 0.80 0.10
run_shift
assert_eq 0 "$RC" "session 0.80: exit 0"
assert_eq "" "$(runs)" "session 0.80: no pick"
assert_contains "$LOG" "session window at 0.8" "logs the session window stopped it"

reset_tasks; add_task a.md; write_usage 0.10 0.80
run_shift
assert_eq "" "$(runs)" "weekly 0.80, session 0.10: no pick"
assert_contains "$LOG" "weekly window at 0.8" "logs the weekly window stopped it"

reset_tasks; add_task a.md; write_usage - 0.10
run_shift
assert_eq "a.md" "$(runs)" "weekly-only record (grok default) runs"

reset_tasks; add_task a.md
DETROIT_AGENT=claude DETROIT_MODEL=claude-fable-5-1 write_usage 0.1 0.95 "" "$FABLE_LOW"
DETROIT_AGENT=claude DETROIT_MODEL=claude-fable-5-1 run_shift
assert_eq "" "$(runs)" "claude + Fable model: account weekly 0.95 still stops"
assert_contains "$LOG" "claude.json" "DETROIT_AGENT picks the usage record"

reset_tasks; add_task a.md; rm -f "$USAGE_FILE"
run_shift
assert_eq 0 "$RC" "missing usage: exit 0"
assert_eq "" "$(runs)" "missing usage: no pick"
assert_eq 1 "$(count "$TESTDIR/refreshes")" "missing usage: one refresh attempt"
assert_contains "$LOG" "idle — no fresh usage" "missing usage logged"

write_usage 0.1 0.1 "$OLD_ISO"
run_shift
assert_eq "" "$(runs)" "stale after refresh: no pick"
assert_eq 1 "$(count "$TESTDIR/refreshes")" "stale: exactly one refresh attempt"
assert_contains "$LOG" "idle — no fresh usage" "stale usage logged"

stub_bin omarchy-agent-usage-update "echo called >> '$TESTDIR/refreshes'
printf '{\"updatedAt\":\"%s\",\"limits\":[{\"label\":\"Session (5-hour)\",\"percent\":0.1}]}' \"\$(date -u +%Y-%m-%dT%H:%M:%S+00:00)\" > '$USAGE_FILE'"
write_usage 0.1 0.1 "$OLD_ISO"
run_shift
assert_eq "a.md" "$(runs)" "stale, refresh brings fresh numbers: runs"

stub_bin omarchy-agent-usage-update 'exec sleep 30'
write_usage 0.1 0.1 "$OLD_ISO"
T0=$SECONDS
SHIFT_REFRESH_TIMEOUT=1 run_shift
assert_eq "true" "$([ $((SECONDS - T0)) -lt 10 ] && echo true)" "hung usage collector is cut off"
assert_contains "$LOG" "idle — no fresh usage" "hung collector → no fresh usage"
stub_bin omarchy-agent-usage-update "echo called >> '$TESTDIR/refreshes'"

reset_tasks; write_usage 0.1 0.1
run_shift
assert_eq 0 "$RC" "empty tasks/: exit 0"
assert_contains "$LOG" "idle — no tasks" "empty tasks/ logged"

reset_tasks; add_task a.md
printf '{"updatedAt":"%s","tierLabel":"Prepaid","limits":[]}\n' "$(now_iso)" > "$USAGE_FILE"
run_shift
assert_eq "" "$(runs)" "prepaid-only record: no pick"
assert_contains "$LOG" "idle — budget does not reset" "prepaid-only logged"

reset_tasks; add_task a.md; add_task b.md; write_usage 0.1 0.1
FAKE_CHILD=ship run_shift
assert_eq "a.md b.md" "$(runs)" "keeps going in filename order while there is room"
assert_eq 2 "$(count "$TESTDIR/sleeps")" "pauses after each task"
assert_contains "$LOG" "idle — no tasks" "stops when the queue drains"

reset_tasks; add_task a.md; mv "$TASK_DIR/a.md" "$TASK_DIR/failed/"
run_shift
assert_eq "" "$(runs)" "tasks/failed/ is never replayed"

reset_tasks; add_task a.md; add_task b.md; mkdir "$LOCK_DIR/a.md.lock"
FAKE_CHILD=ship run_shift
assert_eq "b.md" "$(runs)" "locked task skipped"

reset_tasks; printf -- '---\nrepo: other\n---\nx\n' > "$TASK_DIR/a.md"; add_task b.md
REPO_FILTER=other; FAKE_CHILD=ship run_shift; REPO_FILTER=""
assert_eq "a.md" "$(runs)" "--repo filter scopes the shift"

reset_tasks; add_task "fix login bug.md"; add_task z.md
FAKE_CHILD=ship run_shift
assert_eq "fix login bug.md z.md" "$(runs)" "task names with spaces"

echo "one shift at a time:"
reset_tasks; add_task a.md
sleep 30 & LIVE=$!
mkdir "$DETROIT/.shift.lock"; echo "$LIVE" > "$DETROIT/.shift.lock/pid"
run_shift
assert_eq 0 "$RC" "second shift: exit 0"
assert_eq "" "$(runs)" "second shift: no pick"
assert_contains "$LOG" "another shift is running (pid $LIVE)" "second shift logs the holder"
assert_eq "$LIVE" "$(cat "$DETROIT/.shift.lock/pid")" "holder's lock untouched"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
run_shift
assert_eq "a.md" "$(runs)" "lock left by a dead pid is taken over"
assert_eq "false" "$([ -d "$DETROIT/.shift.lock" ] && echo true || echo false)" "taken-over lock released"
rm -f "$LOCK_DIR"/*; mkdir "$DETROIT/.shift.lock"
run_shift
assert_contains "$LOG" "another shift is running (pid starting)" "fresh lock without pid is respected"
rm -rf "$DETROIT/.shift.lock"

echo "herdr session check:"
# herdr stub reads its answers from files so a test can flip them mid-loop
HERDR_WS="$TESTDIR/herdr-ws.json"; HERDR_AGENTS="$TESTDIR/herdr-agents.json"
stub_bin herdr "case \"\$1 \$2\" in
  'workspace list') cat '$HERDR_WS' ;;
  'agent list') cat '$HERDR_AGENTS' ;;
  *) exit 1 ;;
esac"
herdr_state() {  # herdr_state <focused-ws-id> <agent-kind> <agent-ws-id> <status>
  printf '{"result":{"workspaces":[{"workspace_id":"w1","focused":%s},{"workspace_id":"w2","focused":%s}]}}\n' \
    "$([ "$1" = w1 ] && echo true || echo false)" "$([ "$1" = w2 ] && echo true || echo false)" > "$HERDR_WS"
  printf '{"result":{"agents":[{"agent":"%s","workspace_id":"%s","agent_status":"%s"}]}}\n' "$2" "$3" "$4" > "$HERDR_AGENTS"
}
herdr_state w1 grok w1 working
assert_rc 0 "focused workspace, same kind (grok default), working → busy" shift_session_busy
herdr_state w1 grok w2 working
assert_rc 1 "working grok in an unfocused workspace → free" shift_session_busy
herdr_state w1 claude w1 working
assert_rc 1 "different agent kind → free" shift_session_busy
assert_rc 0 "DETROIT_AGENT selects the kind" env DETROIT_AGENT=claude bash -c ". '$DETROIT_ROOT/lib/core.sh' 2>/dev/null; . '$DETROIT_ROOT/lib/shift.sh'; shift_session_busy"
herdr_state w1 grok w1 idle
assert_rc 1 "idle agent → free" shift_session_busy

reset_tasks; add_task a.md; write_usage 0.1 0.1
herdr_state w1 grok w1 working
# First sleep: session ends and the window fills, so the loop exits on re-check
shift_sleep() {
  echo slept >> "$TESTDIR/sleeps"
  herdr_state w1 grok w1 idle
  write_usage 0.9 0.1
}
run_shift
assert_eq 1 "$(count "$TESTDIR/sleeps")" "session in use: sleeps"
assert_eq "" "$(runs)" "session in use: no pick"
assert_contains "$LOG" "idle — session in use" "session in use logged"
shift_sleep() { echo slept >> "$TESTDIR/sleeps"; }
stub_bin herdr 'exec sleep 30'
T0=$SECONDS
assert_rc 1 "hung herdr → free" env SHIFT_HERDR_TIMEOUT=1 bash -c "AGENT_ID=0; . '$DETROIT_ROOT/lib/core.sh'; . '$DETROIT_ROOT/lib/shift.sh'; shift_session_busy"
assert_eq "true" "$([ $((SECONDS - T0)) -lt 10 ] && echo true)" "hung herdr is cut off"
stub_bin herdr 'exit 1'
assert_rc 1 "herdr unavailable → free" shift_session_busy

echo "factory.sh --shift:"
# Real entry point against a copied tree: fixture usage, stubbed herdr, empty queue
mkdir -p "$TESTDIR/tree"
cp -R "$DETROIT_ROOT/factory.sh" "$DETROIT_ROOT/lib" "$TESTDIR/tree/"
write_usage 0.1 0.1
OUT=$(DETROIT_DIR="$TESTDIR/tree" bash "$TESTDIR/tree/factory.sh" --shift 2>&1); RC=$?
assert_eq 0 "$RC" "empty queue: exit 0"
assert_contains "$OUT" "idle — no tasks" "empty queue: logged"
assert_eq "true" "$(ls "$TESTDIR/tree/logs/"*-shift.log >/dev/null 2>&1 && echo true)" "writes logs/*-shift.log"
write_usage 0.85 0.1
echo "task" > "$TESTDIR/tree/tasks/a.md"
OUT=$(DETROIT_DIR="$TESTDIR/tree" bash "$TESTDIR/tree/factory.sh" --dry-run --shift 2>&1); RC=$?
assert_eq 0 "$RC" "--dry-run --shift over budget: exit 0"
assert_not_contains "$OUT" "PICK" "over budget: pipeline never picks"
assert_eq "true" "$([ -f "$TESTDIR/tree/tasks/a.md" ] && echo true)" "task left in place"

summarize
