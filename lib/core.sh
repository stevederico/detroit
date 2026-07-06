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
# Runs cmd with a sleep-kill watchdog; returns 124 on timeout, else cmd's rc.
with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) &
  local dog=$!
  local rc=0
  wait "$pid" || rc=$?
  kill "$dog" 2>/dev/null
  wait "$dog" 2>/dev/null
  [ "$rc" -ge 128 ] && rc=124
  return "$rc"
}

# Ctrl+C cleanup (trap installed by factory.sh)
cleanup() {
  echo "" | ptee
  log "━━━ CANCELLED ━━━"
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
