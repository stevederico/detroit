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
