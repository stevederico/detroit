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
#   DETROIT_AGENT          which usage record + Herdr agent kind (default claude)
#   DETROIT_MODEL          prefer a model-scoped limit row when one matches
#
# Test seams (override after sourcing): shift_run_task, shift_sleep.

shift_agent() { printf '%s\n' "${DETROIT_AGENT:-claude}"; }

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

win = {**flat, **scoped}
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
  local ws agents
  ws=$(herdr workspace list 2>/dev/null) || return 1
  agents=$(herdr agent list 2>/dev/null) || return 1
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

# shift_next_task — print the first task PICK would take (same sort, repo
# filter, and lock rules), or nothing. Never looks in tasks/failed/.
shift_next_task() {
  local candidate lock
  for candidate in $(find "$TASK_DIR" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort); do
    task_in_repo_filter "$candidate" || continue
    lock="$LOCK_DIR/$(basename "$candidate").lock"
    # PICK clears locks older than 30 min, so those count as free
    if [ -d "$lock" ] && [ -z "$(find "$lock" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
      continue
    fi
    printf '%s\n' "$candidate"
    return 0
  done
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

# shift_stop <reason> — log why the shift ended and return 0
shift_stop() {
  log "Shift over: $1 ($SHIFT_RAN ran, $SHIFT_FAILED failed)"
  update_status "$1"
}

# mode_shift — the loop from docs/budget-shift.md. Returns 0 on every stop.
mode_shift() {
  local stop="${DETROIT_BUDGET_STOP:-0.80}" pause="${DETROIT_SHIFT_PAUSE:-30}"
  local file usage session weekly next name rc tried=" "
  SHIFT_RAN=0
  SHIFT_FAILED=0
  file=$(shift_usage_file)
  stage "SHIFT"
  log "Agent: $(shift_agent)  stop: $stop  pause: ${pause}s  usage: $file"

  while true; do
    # 1. Someone is driving this agent by hand — leave the budget to them
    if shift_session_busy; then
      log "idle — session in use"
      update_status "idle — session in use"
      shift_sleep "$pause"
      continue
    fi

    # 2-3. Fresh usage or nothing; one refresh attempt
    usage=$(shift_read_usage "$file")
    case "$usage" in
      missing|stale)
        log "Usage record $usage — refreshing once"
        if command -v omarchy-agent-usage-update >/dev/null 2>&1; then
          omarchy-agent-usage-update "$(shift_agent)" >/dev/null 2>&1
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

    # 5. Something to do. A task still first in line after its run (dry run,
    # or a pre-ship failure whose lock went stale) ends the shift instead of
    # burning budget on it again.
    next=$(shift_next_task)
    if [ -z "$next" ]; then
      shift_stop "idle — no tasks"; return 0
    fi
    name=$(basename "$next")
    case "$tried" in
      *" $name "*) shift_stop "idle — $name already ran this shift"; return 0 ;;
    esac
    tried="$tried$name "

    # 6. The same path as a no-flag factory.sh
    log "Shift task $((SHIFT_RAN + 1)): $name"
    rc=0
    shift_run_task || rc=$?
    SHIFT_RAN=$((SHIFT_RAN + 1))
    [ "$rc" = 0 ] || SHIFT_FAILED=$((SHIFT_FAILED + 1))
    log "Shift task $name exited $rc"

    # 7. Breathe, then re-check the budget
    shift_sleep "$pause"
  done
}
