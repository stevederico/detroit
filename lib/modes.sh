# shellcheck shell=bash
# lib/modes.sh — --parallel and --issues entry modes.

# mode_parallel — spawn PARALLEL_N factory agents and summarize their statuses
mode_parallel() {
  local AGENTS="$PARALLEL_N"
  rm -f "$STATUS_DIR"/agent-* 2>/dev/null

  echo "━━━ DETROIT: $AGENTS parallel agents ━━━"
  echo ""

  local PIDS="" i pid
  for i in $(seq 1 "$AGENTS"); do
    if [ "$DRY_RUN" = true ]; then
      DETROIT_AGENT_ID="$i" bash "$0" --dry-run &
    else
      DETROIT_AGENT_ID="$i" bash "$0" &
    fi
    PIDS="$PIDS $!"
    sleep 1
  done
  echo ""

  # Wait for all agents (output streams live with [AN] prefix)
  local FAILED=0
  for pid in $PIDS; do
    wait "$pid" || FAILED=$((FAILED + 1))
  done

  # Final summary
  echo ""
  echo "━━━ SUMMARY ━━━"
  local STATUS
  for i in $(seq 1 "$AGENTS"); do
    STATUS="unknown"
    if [ -f "$STATUS_DIR/agent-$i" ]; then
      STATUS=$(cat "$STATUS_DIR/agent-$i")
    fi
    echo "  W$i: $STATUS"
  done
  echo ""
  rm -f "$STATUS_DIR"/agent-* 2>/dev/null
  exit $FAILED
}

# mode_issues — pull open GitHub issues labeled 'detroit' into tasks/
mode_issues() {
  REPO="$ISSUES_REPO"

  log "Syncing issues from $REPO (label: detroit)"
  PROJECT_NAME=$(echo "$REPO" | cut -d/ -f2)
  export PROJECT_NAME
  export REPO TASK_DIR

  gh issue list --repo "$REPO" --label "detroit" --state open --json number,title,body --limit 50 2>/dev/null | \
    python3 -c "
import json, sys, re, os

task_dir = os.environ['TASK_DIR']
project = os.environ['PROJECT_NAME']
repo = os.environ['REPO']

issues = json.loads(sys.stdin.read())
for issue in issues:
    num = issue['number']
    title = issue['title']
    body = issue.get('body', '') or ''
    slug = re.sub(r'[^a-z0-9]+', '-', title.lower()).strip('-')
    filename = os.path.join(task_dir, f'{num:03d}-{slug}.md')

    with open(filename, 'w') as f:
        f.write(f'---\nrepo: {project}\nissue: {repo}#{num}\n---\n\n# {title}\n\n{body}\n')

    print(f'  Created {filename}')

if not issues:
    print('  No issues with label \"detroit\" found')
"
  exit 0
}
