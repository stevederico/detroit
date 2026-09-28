# shellcheck shell=bash
# lib/core.sh — logging, status, and cleanup helpers.
# Function definitions only; factory.sh sets the globals (AGENT_ID, LOGFILE,
# STATUS_DIR, LOCK_DIR, TASK_FILE, WORKTREE_DIR, DETROIT) and installs the trap.

if [ "$AGENT_ID" = "0" ]; then
  log() { echo "[$(date +"%H:%M:%S")] $1" >> "$LOGFILE"; echo "$1"; }
  PREFIX=""
else
  log() { echo "[$(date +"%H:%M:%S")] $1" >> "$LOGFILE"; echo "[Agent-$AGENT_ID] $1"; }
  PREFIX="[Agent-$AGENT_ID] "
fi
stage() { echo "" >> "$LOGFILE"; echo ""; log "━━━ $1 ━━━"; }
update_status() { echo "$1" > "$STATUS_DIR/agent-$AGENT_ID"; }
# Prefixed tee: writes raw to log, prefixed to terminal
ptee() { while IFS= read -r line; do echo "$line" >> "$LOGFILE"; echo "${PREFIX}${line}"; done; }

# with_timeout <secs> <cmd...> — portable timeout (macOS has no timeout(1)).
# A python3 supervisor starts cmd in a new session (setsid; macOS has no
# setsid(1)) and waits for it. On timeout, or when the supervisor itself gets
# INT, TERM or HUP (Ctrl+C, systemd stop), it sends TERM to cmd's process
# group and to the group of every descendant (opencode starts each tool
# command in its own session), waits up to WITH_TIMEOUT_GRACE seconds (10)
# for them to exit, then sends KILL. So npm test, dev servers and tool
# commands go with cmd. Returns 124 on timeout or any signal death, 127 when
# cmd is not found, else cmd's rc. cmd must be an executable, not a shell
# function. The supervisor exits with cmd, so $(with_timeout ...) returns as
# soon as cmd does.
WITH_TIMEOUT_PY='
import os, signal, subprocess, sys, time

class Stop(Exception):
    pass

def on_signal(signum, _frame):
    raise Stop(signum)

def tree_groups(root):
    # Process groups of root and every descendant, never our own
    try:
        out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,pgid="],
                             capture_output=True, text=True).stdout
    except OSError:
        out = ""
    kids, pgid = {}, {}
    for line in out.splitlines():
        f = line.split()
        if len(f) == 3 and all(x.isdigit() for x in f):
            pid, ppid, g = map(int, f)
            kids.setdefault(ppid, []).append(pid)
            pgid[pid] = g
    groups, todo = {root}, [root]
    while todo:
        for c in kids.get(todo.pop(), []):
            todo.append(c)
            groups.add(pgid.get(c, c))
    groups.discard(os.getpgrp())
    return groups

def signal_groups(groups, sig):
    alive = set()
    for g in groups:
        try:
            os.killpg(g, sig)
            alive.add(g)
        except (ProcessLookupError, PermissionError):
            pass
    return alive

def stop(child, grace):
    for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(s, signal.SIG_IGN)
    groups = signal_groups(tree_groups(child.pid), signal.SIGTERM)
    deadline = time.monotonic() + grace
    while groups and time.monotonic() < deadline:
        child.poll()  # reap the leader so its group can empty
        time.sleep(0.2)
        groups = signal_groups(groups, 0)
    signal_groups(groups, signal.SIGKILL)
    child.poll()

secs, grace = float(sys.argv[1]), float(os.environ.get("WITH_TIMEOUT_GRACE") or 10)
try:
    child = subprocess.Popen(sys.argv[2:], start_new_session=True)
except OSError as e:
    sys.stderr.write("%s: %s\n" % (sys.argv[2], e.strerror))
    sys.exit(127 if isinstance(e, FileNotFoundError) else 126)
for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(s, on_signal)
try:
    rc = child.wait(timeout=secs)
except subprocess.TimeoutExpired:
    stop(child, grace)
    sys.exit(124)
except Stop as e:
    stop(child, grace)
    signal.signal(e.args[0], signal.SIG_DFL)
    os.kill(os.getpid(), e.args[0])
    sys.exit(128 + e.args[0])
sys.exit(128 - rc if rc < 0 else rc)
'
with_timeout() {
  local secs="$1"; shift
  local rc=0
  python3 -c "$WITH_TIMEOUT_PY" "$secs" "$@" || rc=$?
  [ "$rc" -ge 128 ] && rc=124
  return "$rc"
}

# resolve_gh_repo [dir] — print owner/name for the git repo at dir (default: REPO_DIR).
# Order: gh repo view → origin remote parse → gh user + basename.
resolve_gh_repo() {
  local dir="${1:-${REPO_DIR:-.}}" slug url owner name
  slug=$(cd "$dir" 2>/dev/null && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || true
  if [ -n "$slug" ]; then
    printf '%s\n' "$slug"
    return 0
  fi
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || true
  if [ -n "$url" ]; then
    # git@github.com:owner/name.git | https://github.com/owner/name(.git)
    slug=$(printf '%s' "$url" | sed -E \
      -e 's#^git@github\.com:##' \
      -e 's#^https?://github\.com/##' \
      -e 's#\.git$##' \
      -e 's#/$##')
    case "$slug" in
      */*) printf '%s\n' "$slug"; return 0 ;;
    esac
  fi
  owner=$(gh api user --jq '.login' 2>/dev/null) || true
  name=$(basename "$(cd "$dir" 2>/dev/null && pwd)")
  if [ -n "$owner" ] && [ -n "$name" ]; then
    printf '%s/%s\n' "$owner" "$name"
    return 0
  fi
  return 1
}

# task_in_repo_filter <task-file> — true when REPO_FILTER is unset or matches
# the task's frontmatter repo: (so a run targets one project).
task_in_repo_filter() {
  [ -n "${REPO_FILTER:-}" ] || return 0
  local repo
  repo=$(awk '/^---$/{n++;next} n==1 && /^repo:/{gsub(/^repo: */,"");print;exit}' "$1")
  [ "$repo" = "$REPO_FILTER" ]
}

# pick_task [--lock] — print the first task PICK takes: *.md directly in
# TASK_DIR (never done/ or failed/), filename order, matching REPO_FILTER, not
# named in DETROIT_SHIFT_SKIP (newline list), not locked. Locks older than 30
# min are cleared first. --lock takes the lock (atomic mkdir) before printing;
# without it this is a peek. Prints nothing when no task is free.
pick_task() {
  local take=false candidate name nl='
'
  [ "${1:-}" = --lock ] && take=true
  find "$LOCK_DIR" -maxdepth 1 -name '*.lock' -type d -mmin +30 -exec rm -rf {} \; 2>/dev/null
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    name=$(basename "$candidate")
    case "$nl${DETROIT_SHIFT_SKIP:-}$nl" in *"$nl$name$nl"*) continue ;; esac
    task_in_repo_filter "$candidate" || continue
    if [ "$take" = true ]; then
      mkdir "$LOCK_DIR/$name.lock" 2>/dev/null || continue
    else
      [ -d "$LOCK_DIR/$name.lock" ] && continue
    fi
    printf '%s\n' "$candidate"
    return 0
  done < <(find "$TASK_DIR" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort)
  return 0
}

# append_lesson <one-line> — durable failure memory in $DETROIT/lessons.md (max 50 bullets).
append_lesson() {
  local line="$1" file="${DETROIT}/lessons.md" date_s tmp count
  [ -n "$line" ] || return 0
  [ -n "${DETROIT:-}" ] || return 0
  date_s=$(date +%Y-%m-%d)
  if [ ! -f "$file" ]; then
    printf '# Lessons\n\nFailures recorded by the factory. Injected into CODE prompts.\n\n' > "$file"
  fi
  printf -- '- %s %s\n' "$date_s" "$line" >> "$file"
  count=$(grep -c '^- ' "$file" 2>/dev/null || echo 0)
  if [ "${count:-0}" -gt 50 ]; then
    tmp=$(mktemp)
    # Keep header lines (non-bullets) + last 50 bullets
    grep -v '^- ' "$file" > "$tmp" 2>/dev/null || true
    grep '^- ' "$file" | tail -50 >> "$tmp"
    mv "$tmp" "$file"
  fi
}

# quality_fail <stage> <reason> — mark run quality failed and record a lesson.
# QUALITY_OK is a pipeline global consumed by postship.sh (SC2034 is a false positive).
quality_fail() {
  # shellcheck disable=SC2034
  QUALITY_OK=false
  append_lesson "$1: $2"
  log "QUALITY_OK=false — $1: $2"
}

# Ctrl+C / TERM cleanup (trap installed by factory.sh)
cleanup() {
  echo "" | ptee
  log "━━━ CANCELLED ━━━"
  # Release a --shift lock (lib/shift.sh)
  [ -n "${SHIFT_LOCK_HELD:-}" ] && rm -rf "$SHIFT_LOCK_HELD"
  # Remove task lock
  if [ -n "$TASK_FILE" ]; then
    rm -rf "$LOCK_DIR/$(basename "$TASK_FILE").lock" 2>/dev/null
  fi
  # Clean up worktree
  if [ -n "$WORKTREE_DIR" ] && [ -d "$WORKTREE_DIR" ]; then
    cd "$DETROIT" || true
    if [ -n "${MAIN_REPO_DIR:-}" ]; then
      git -C "$MAIN_REPO_DIR" worktree remove --force "$WORKTREE_DIR" 2>/dev/null || rm -rf "$WORKTREE_DIR"
      git -C "$MAIN_REPO_DIR" worktree prune 2>/dev/null
    else
      rm -rf "$WORKTREE_DIR" 2>/dev/null
    fi
    log "Cleaned up worktree"
  fi
  exit 130
}
