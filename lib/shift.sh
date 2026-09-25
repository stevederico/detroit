# shellcheck shell=bash
# lib/shift.sh — --shift mode: one worker runs the normal pipeline task after
# task while the resetting usage window has room, then stops.
# Spec: docs/budget-shift.md. Reads Omarchy's usage record; never calls a
# provider usage API itself. Never invents tasks, never replays tasks/failed/.
#
# Env:
#   DETROIT_BUDGET_STOP    stop at this session/weekly fraction (default 0.80)
#   DETROIT_SHIFT_PAUSE    seconds between tasks (default 30)
#   DETROIT_USAGE_MAX_AGE  usage record older than this is stale (default 900)
#   DETROIT_AGENT          which usage record + Herdr agent kind (default grok)
#   DETROIT_MODEL          also count a matching model-scoped limit row
#
# Only one shift runs at a time ($DETROIT/.shift.lock). Tasks it already ran
# go in DETROIT_SHIFT_SKIP, which the child's PICK honors (lib/core.sh
# pick_task), so a task left in tasks/ never blocks the rest of the queue.
#
# Test seams (override after sourcing): shift_run_task, shift_sleep.
# Internal timeouts: SHIFT_HERDR_TIMEOUT (10s), SHIFT_REFRESH_TIMEOUT (120s).

shift_agent() { printf '%s\n' "${DETROIT_AGENT:-grok}"; }

shift_usage_file() {
  printf '%s/omarchy/agents/usage/%s.json\n' "${XDG_STATE_HOME:-$HOME/.local/state}" "$(shift_agent)"
}

# shift_read_usage <file> — print one line:
#   ok <session> <weekly>   fractions 0..1, "-" when that window is absent
#   missing                 no file or unreadable JSON
#   stale                   older than DETROIT_USAGE_MAX_AGE
#   noreset                 no resetting session/weekly window (prepaid balance)
# Age comes from updatedAt, falling back to the file mtime.
shift_read_usage() {
  USAGE_FILE="$1" MAX_AGE="${DETROIT_USAGE_MAX_AGE:-900}" MODEL="${DETROIT_MODEL:-}" python3 - <<'PY'
import datetime as dt, json, os, re, time

path = os.environ["USAGE_FILE"]
try:
    with open(path) as f:
        rec = json.load(f)
    if not isinstance(rec, dict):
        raise ValueError
except Exception:
    print("missing"); raise SystemExit

updated = None
try:
    updated = dt.datetime.fromisoformat(str(rec["updatedAt"]).replace("Z", "+00:00")).timestamp()
except Exception:
    updated = os.path.getmtime(path)
if time.time() - updated > float(os.environ["MAX_AGE"]):
    print("stale"); raise SystemExit

def tokens(s):
    s = re.sub(r"\(.*?\)", " ", s.lower())
    return [t for t in re.split(r"[^a-z0-9]+", s) if t]

model = set(tokens(os.environ["MODEL"]))
flat, scoped = {}, {}
for row in rec.get("limits") or []:
    if not isinstance(row, dict):
        continue
    try:
        pct = float(row.get("percent"))
    except Exception:
        continue
    title = str(row.get("title") or "")
    if title:
        # Model-scoped row, e.g. "Fable Weekly": model name + window.
        m = re.match(r"^(.*)\s+(Session|Weekly)$", title)
        if not m or not model:
            continue
        name = tokens(m.group(1))
        if name and all(t in model for t in name):
            scoped[m.group(2).lower()] = pct
        continue
    label = str(row.get("label") or "").lower()
    if "session" in label or "5-hour" in label:
        flat.setdefault("session", pct)
    elif "weekly" in label or "7-day" in label:
        flat.setdefault("weekly", pct)

# A model-scoped row never hides the account-wide one: take the fuller window.
win = dict(flat)
for k, v in scoped.items():
    win[k] = max(v, win.get(k, v))
if not win:
    print("noreset"); raise SystemExit
fmt = lambda k: repr(win[k]) if k in win else "-"
print("ok", fmt("session"), fmt("weekly"))
PY
}

# shift_at_or_above <pct> <stop> — true when pct >= stop ("-" never is)
shift_at_or_above() {
  [ "$1" != "-" ] && awk -v p="$1" -v s="$2" 'BEGIN { exit !(p + 0 >= s + 0) }'
}

# shift_session_busy — true when a focused Herdr workspace has a working agent
# of the same kind as DETROIT_AGENT (someone is using the budget by hand).
shift_session_busy() {
  command -v herdr >/dev/null 2>&1 || return 1
  local ws agents t="${SHIFT_HERDR_TIMEOUT:-10}"
  ws=$(with_timeout "$t" herdr workspace list 2>/dev/null) || return 1
  agents=$(with_timeout "$t" herdr agent list 2>/dev/null) || return 1
  WS_JSON="$ws" AGENTS_JSON="$agents" KIND="$(shift_agent)" python3 - <<'PY'
import json, os
try:
    ws = json.loads(os.environ["WS_JSON"])["result"]["workspaces"]
    agents = json.loads(os.environ["AGENTS_JSON"])["result"]["agents"]
except Exception:
    raise SystemExit(1)
focused = {w.get("workspace_id") for w in ws if w.get("focused")}
busy = any(
    a.get("workspace_id") in focused
    and a.get("agent") == os.environ["KIND"]
    and a.get("agent_status") == "working"
    for a in agents
)
raise SystemExit(0 if busy else 1)
PY
}

# shift_run_task — one no-flag factory run in a child, so its exits and
# globals stay out of the loop. Returns the child's exit code.
shift_run_task() {
  if [ "$DRY_RUN" = true ]; then
    DETROIT_REPO="${REPO_FILTER:-}" bash "$DETROIT/factory.sh" --dry-run
  else
    DETROIT_REPO="${REPO_FILTER:-}" bash "$DETROIT/factory.sh"
  fi
}

shift_sleep() { sleep "$1"; }

# shift_status <text> — the shift's own status (web UI "agent shift"); the
# child keeps agent-$AGENT_ID. Never put a task name here: the web UI marks a
# task running when any status contains its name.
shift_status() { echo "$1" > "$STATUS_DIR/agent-shift"; }

# shift_lock — take $DETROIT/.shift.lock (mkdir + pid). A lock whose pid is
# gone, or that never got a pid and is over a minute old, is taken over.
# Sets SHIFT_LOCK_HELD on success, SHIFT_HOLDER on failure.
shift_lock() {
  local lock="$DETROIT/.shift.lock" pid
  if ! mkdir "$lock" 2>/dev/null; then
    pid=$(cat "$lock/pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      SHIFT_HOLDER="$pid"; return 1
    fi
    if [ -z "$pid" ] && [ -z "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      SHIFT_HOLDER="starting"; return 1
    fi
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || { SHIFT_HOLDER="?"; return 1; }
  fi
  echo "$$" > "$lock/pid"
  SHIFT_LOCK_HELD="$lock"
}

shift_unlock() {
  [ -n "${SHIFT_LOCK_HELD:-}" ] && rm -rf "$SHIFT_LOCK_HELD"
  SHIFT_LOCK_HELD=""
}

# shift_stop <reason> — log why the shift ended
shift_stop() {
  log "Shift over: $1 ($SHIFT_RAN ran, $SHIFT_FAILED failed)"
  shift_status "$1"
}

# mode_shift — one worker, the loop from docs/budget-shift.md. Returns 0 on
# every stop, including when another shift already holds the lock.
mode_shift() {
  # shellcheck disable=SC2034  # read by log() in lib/core.sh
  LOGFILE="$LOGDIR/$TIMESTAMP-shift.log"
  stage "SHIFT"
  if ! shift_lock; then
    log "idle — another shift is running (pid $SHIFT_HOLDER)"
    return 0
  fi
  local rc=0
  shift_loop || rc=$?
  shift_unlock
  return "$rc"
}

shift_loop() {
  local stop="${DETROIT_BUDGET_STOP:-0.80}" pause="${DETROIT_SHIFT_PAUSE:-30}"
  local file usage session weekly next name rc nl='
'
  SHIFT_RAN=0
  SHIFT_FAILED=0
  DETROIT_SHIFT_SKIP=""
  export DETROIT_SHIFT_SKIP
  file=$(shift_usage_file)
  log "Agent: $(shift_agent)  stop: $stop  pause: ${pause}s  usage: $file"

  while true; do
    # 1. Someone is driving this agent by hand — leave the budget to them
    if shift_session_busy; then
      log "idle — session in use"
      shift_status "idle — session in use"
      shift_sleep "$pause"
      continue
    fi

    # 2-3. Fresh usage or nothing; one refresh attempt
    usage=$(shift_read_usage "$file")
    case "$usage" in
      missing|stale)
        log "Usage record $usage — refreshing once"
        if command -v omarchy-agent-usage-update >/dev/null 2>&1; then
          with_timeout "${SHIFT_REFRESH_TIMEOUT:-120}" omarchy-agent-usage-update "$(shift_agent)" >/dev/null 2>&1
        fi
        usage=$(shift_read_usage "$file") ;;
    esac
    case "$usage" in
      missing|stale|"") shift_stop "idle — no fresh usage"; return 0 ;;
      noreset)          shift_stop "idle — budget does not reset"; return 0 ;;
    esac
    read -r _ session weekly <<< "$usage"
    log "Usage: session $session, weekly $weekly"

    # 4. Window full
    if shift_at_or_above "$session" "$stop"; then
      shift_stop "idle — session window at $session (stop $stop)"; return 0
    fi
    if shift_at_or_above "$weekly" "$stop"; then
      shift_stop "idle — weekly window at $weekly (stop $stop)"; return 0
    fi

    # 5. Something to do that this shift has not run yet
    next=$(pick_task)
    if [ -z "$next" ]; then
      shift_stop "idle — no tasks"; return 0
    fi
    name=$(basename "$next")

    # 6. The same path as a no-flag factory.sh. Whatever happens, this task
    # is done for this shift: shipped, failed, or left in tasks/ (dry run, or
    # stopped before SHIP) — the child's PICK skips it from now on.
    log "Shift task $((SHIFT_RAN + 1)): $name"
    shift_status "shift running task $((SHIFT_RAN + 1))"
    rc=0
    shift_run_task || rc=$?
    SHIFT_RAN=$((SHIFT_RAN + 1))
    [ "$rc" = 0 ] || SHIFT_FAILED=$((SHIFT_FAILED + 1))
    log "Shift task $name exited $rc"
    DETROIT_SHIFT_SKIP="${DETROIT_SHIFT_SKIP:+$DETROIT_SHIFT_SKIP$nl}$name"

    # 7. Breathe, then re-check the budget
    shift_sleep "$pause"
  done
}
