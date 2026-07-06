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
    cd "$DETROIT"
    rm -rf "$WORKTREE_DIR" 2>/dev/null
    git -C "$(dirname "$WORKTREE_DIR")" worktree prune 2>/dev/null
    log "Cleaned up worktree"
  fi
  exit 130
}
