#!/bin/bash
# factory.sh — shipyard code factory
# Reads next task file from tasks/, ships them as PRs.
# Usage: bash factory.sh [--dry-run] [--issues owner/repo] [--parallel N] [--verify owner/repo]

SHIPYARD="${SHIPYARD_DIR:-$(cd "$(dirname "$0")" && pwd)}"
TASK_DIR="$SHIPYARD/tasks"
DONE_DIR="$TASK_DIR/done"
LOCK_DIR="$TASK_DIR/.locks"
PROJECTS="${SHIPYARD_PROJECTS:-$(dirname "$SHIPYARD")}"
LOGDIR="$SHIPYARD/logs"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")

STATUS_DIR="$SHIPYARD/.status"
mkdir -p "$LOGDIR" "$DONE_DIR" "$LOCK_DIR" "$STATUS_DIR"
AGENT_ID="${SHIPYARD_AGENT_ID:-0}"
LOGFILE="$LOGDIR/$TIMESTAMP-w$AGENT_ID.log"
WORKTREE_DIR=""
# Force headless browser for all agent-browser calls
export AGENT_BROWSER_HEADED=""

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

# factory_section <section-name> <factory.md path>
# Extracts the body of an H2 section from a factory.md file (case-insensitive).
# See https://github.com/stevederico/factory-md for the spec.
factory_section() {
  local section="$1"
  local file="$2"
  awk -v target="## $section" '
    BEGIN { found=0; t=tolower(target) }
    /^## / {
      if (found) exit
      if (tolower($0) == t) { found=1; next }
    }
    found { print }
  ' "$file"
}

# factory_rules <factory.md path>
# Concatenates every known factory.md section with a heading prefix so the
# agent prompt contains every rule the factory declares.
# Spec: https://github.com/stevederico/factory-md
factory_rules() {
  local file="$1"
  local section body
  for section in style build testing documentation environment quality observability security; do
    body=$(factory_section "$section" "$file")
    [ -z "$body" ] && continue
    printf '\n%s\n%s\n' "[$section]" "$body"
  done
}

# check_gate <gate-text>
# Dispatches a natural-language rule bullet to a framework-recognized check.
# Uses bash glob keyword matching against gate text.
# Returns: 0 = pass, 1 = fail (recognized + violated), 2 = custom (unrecognized).
# Reads outer-scope: BASE_BRANCH, BRANCH, REPO_DIR, PRE_VERSION, LOGFILE.
check_gate() {
  local gate="$1"
  local gate_lower
  gate_lower=$(echo "$gate" | tr '[:upper:]' '[:lower:]')

  case "$gate_lower" in
    *secret*|*.env*|*.pem*|*.key*|*credential*|*token*)
      git diff "$BASE_BRANCH...$BRANCH" --name-only 2>/dev/null \
        | grep -qE '\.env|\.pem|\.key|credentials|secrets|tokens' && return 1
      return 0
      ;;
    *changelog*)
      git diff "$BASE_BRANCH...$BRANCH" --name-only 2>/dev/null \
        | grep -qi "changelog" || return 1
      return 0
      ;;
    *version*bump*|*bump*version*)
      [ -f "$REPO_DIR/package.json" ] || return 0
      [ -n "$PRE_VERSION" ] || return 0
      local post_version
      post_version=$(python3 -c "import json; print(json.load(open('package.json')).get('version',''))" 2>/dev/null)
      [ "$post_version" = "$PRE_VERSION" ] && return 1
      return 0
      ;;
    *test*pass*|*pass*test*)
      if grep -qE "(FAIL|ERROR|test.*failed|Tests:.*failed)" "$LOGFILE" 2>/dev/null \
        && ! grep -q "FACTORY_RESULT:SUCCESS" "$LOGFILE"; then
        return 1
      fi
      return 0
      ;;
    *file*over*500*line*|*file*500*line*|*no*file*500*)
      local f flines
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        [ -f "$REPO_DIR/$f" ] || continue
        flines=$(wc -l < "$REPO_DIR/$f" 2>/dev/null | tr -d ' ')
        [ -n "$flines" ] && [ "$flines" -gt 500 ] && return 1
      done < <(git diff "$BASE_BRANCH...$BRANCH" --name-only 2>/dev/null)
      return 0
      ;;
    *todo*|*fixme*)
      git diff "$BASE_BRANCH...$BRANCH" 2>/dev/null \
        | grep -qE '^\+.*\b(TODO|FIXME)\b' && return 1
      return 0
      ;;
    *hardcoded*credential*|*api*key*|*access*token*|*private*key*)
      git diff "$BASE_BRANCH...$BRANCH" 2>/dev/null \
        | grep -qE "^\+.*(api[_-]?key|secret[_-]?key|password|private[_-]?key|access[_-]?token)[[:space:]]*[:=][[:space:]]*['\"][^'\"]{8,}['\"]" && return 1
      return 0
      ;;
    *eval*)
      git diff "$BASE_BRANCH...$BRANCH" 2>/dev/null \
        | grep -qE '^\+.*\beval[[:space:]]*\(' && return 1
      return 0
      ;;
    *child_process*|*exec*interpolat*|*shell*injection*)
      git diff "$BASE_BRANCH...$BRANCH" 2>/dev/null \
        | grep -qE "^\+.*(child_process\.)?exec(Sync)?[[:space:]]*\(.*\\\$\{" && return 1
      return 0
      ;;
    *)
      return 2
      ;;
  esac
}

# ── Agent configuration ───────────────────────────────────
# SHIPYARD_AGENT: claude (default), dotbot
# SHIPYARD_PROVIDER: xai (default) — provider for dotbot (xai, anthropic, openai, ollama)
# SHIPYARD_MODEL: model override for dotbot
SHIPYARD_CLI="${SHIPYARD_AGENT:-claude}"

# run_agent <prompt_file> [--model <model>] [--timeout <secs>] [--timeout-msg <msg>] [--verbose]
# Runs the configured agent CLI and streams parsed output to stdout.
run_agent() {
  local prompt_file="$1"; shift
  local model="" timeout_secs=0 timeout_msg="timed out" verbose=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --model) model="$2"; shift 2 ;;
      --timeout) timeout_secs="$2"; shift 2 ;;
      --timeout-msg) timeout_msg="$2"; shift 2 ;;
      --verbose) verbose="yes"; shift ;;
      *) shift ;;
    esac
  done

  local prompt
  prompt=$(cat "$prompt_file")

  case "$SHIPYARD_CLI" in
    claude)
      local -a args=(-p "$prompt" --dangerously-skip-permissions --output-format stream-json)
      [ -n "$model" ] && args+=(--model "$model")
      [ -n "$verbose" ] && args+=(--verbose)

      claude "${args[@]}" 2>/dev/null | \
        python3 -uc "
import sys, json, signal
timeout = $timeout_secs
tmsg = '''$timeout_msg'''
if timeout > 0:
    signal.alarm(timeout)
    signal.signal(signal.SIGALRM, lambda *_: (print(tmsg, flush=True), sys.exit(0)))
seen = set()
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: event = json.loads(line)
    except: continue
    etype = event.get('type', '')
    if etype == 'assistant':
        uid = event.get('uuid', '')
        if uid in seen: continue
        seen.add(uid)
        for block in event.get('message', {}).get('content', []):
            bt = block.get('type', '')
            if bt == 'text':
                print(block['text'], flush=True)
            elif bt == 'tool_use':
                name = block.get('name', '')
                inp = block.get('input', {})
                if name == 'Read': print(f'  Reading {inp.get(\"file_path\", \"?\")}'.rstrip(), flush=True)
                elif name == 'Edit': print(f'  Editing {inp.get(\"file_path\", \"?\")}'.rstrip(), flush=True)
                elif name == 'Write': print(f'  Writing {inp.get(\"file_path\", \"?\")}'.rstrip(), flush=True)
                elif name == 'Bash': print(f'  Running: {inp.get(\"command\", \"\")[:120]}'.rstrip(), flush=True)
                elif name == 'Grep': print(f'  Searching: {inp.get(\"pattern\", \"?\")}'.rstrip(), flush=True)
                elif name == 'Glob': print(f'  Finding: {inp.get(\"pattern\", \"?\")}'.rstrip(), flush=True)
                else: print(f'  Tool: {name}'.rstrip(), flush=True)
    elif etype == 'result':
        text = event.get('result', '')
        if text: print(text, flush=True)
"
      ;;
    dotbot)
      local -a args=(--provider "${SHIPYARD_PROVIDER:-xai}")
      [ -n "${SHIPYARD_MODEL:-}" ] && args+=(--model "$SHIPYARD_MODEL")

      if [ "$timeout_secs" -gt 0 ] 2>/dev/null; then
        dotbot "$prompt" "${args[@]}" 2>/dev/null | \
          python3 -uc "
import sys, signal
signal.alarm($timeout_secs)
signal.signal(signal.SIGALRM, lambda *_: (print('''$timeout_msg''', flush=True), sys.exit(0)))
for line in sys.stdin:
    print(line.rstrip(), flush=True)
"
      else
        dotbot "$prompt" "${args[@]}" 2>/dev/null
      fi
      ;;
    *)
      log "Unknown agent: $SHIPYARD_CLI"
      return 1
      ;;
  esac
}

# ── Ctrl+C cleanup ────────────────────────────────────────
cleanup() {
  echo "" | ptee
  log "━━━ CANCELLED ━━━"
  # Remove task lock
  if [ -n "$TASK_FILE" ]; then
    rm -rf "$LOCK_DIR/$(basename "$TASK_FILE").lock" 2>/dev/null
  fi
  # Clean up worktree
  if [ -n "$WORKTREE_DIR" ] && [ -d "$WORKTREE_DIR" ]; then
    cd "$SHIPYARD"
    rm -rf "$WORKTREE_DIR" 2>/dev/null
    git -C "$(dirname "$WORKTREE_DIR")" worktree prune 2>/dev/null
    log "Cleaned up worktree"
  fi
  exit 130
}
trap cleanup INT

# ── PARALLEL: spawn N agents ──────────────────────────────
if [ "$1" = "--parallel" ]; then
  AGENTS="${2:-3}"
  rm -f "$STATUS_DIR"/agent-* 2>/dev/null

  echo "━━━ SHIPYARD: $AGENTS parallel agents ━━━"
  echo ""

  PIDS=""
  for i in $(seq 1 "$AGENTS"); do
    SHIPYARD_AGENT_ID="$i" bash "$0" &
    PIDS="$PIDS $!"
    sleep 1
  done
  echo ""

  # Wait for all agents (output streams live with [AN] prefix)
  FAILED=0
  for pid in $PIDS; do
    wait "$pid" || FAILED=$((FAILED + 1))
  done

  # Final summary
  echo ""
  echo "━━━ SUMMARY ━━━"
  for i in $(seq 1 "$AGENTS"); do
    STATUS="unknown"
    if [ -f "$STATUS_DIR/worker-$i" ]; then
      STATUS=$(cat "$STATUS_DIR/worker-$i")
    fi
    echo "  W$i: $STATUS"
  done
  echo ""
  rm -f "$STATUS_DIR"/agent-* 2>/dev/null
  exit $FAILED
fi

# ── VERIFY: screenshot all open PRs for a repo ───────────
if [ "$1" = "--verify" ]; then
  REPO="$2"
  PR_FILTER="$3"
  if [ -z "$REPO" ]; then
    echo "Usage: bash factory.sh --verify owner/repo [pr-number]"
    exit 1
  fi

  REPO_NAME=$(echo "$REPO" | cut -d/ -f2)
  REPO_DIR=$(find "$PROJECTS" -maxdepth 1 -iname "$REPO_NAME" -type d 2>/dev/null | head -1)

  if [ -z "$REPO_DIR" ]; then
    echo "Could not find repo: $REPO_NAME"
    exit 1
  fi

  echo "━━━ VERIFY ALL PRs: $REPO ━━━"
  echo "Repo: $REPO_DIR"
  echo ""

  cd "$REPO_DIR"
  # Clean up any stale worktrees from previous runs
  rm -rf .worktrees 2>/dev/null
  git worktree prune 2>/dev/null
  BASE_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
  if [ -z "$BASE_BRANCH" ]; then
    BASE_BRANCH=$(git branch -r 2>/dev/null | grep -oE 'origin/(main|master)' | head -1 | sed 's@origin/@@')
  fi
  BASE_BRANCH="${BASE_BRANCH:-main}"
  git checkout "$BASE_BRANCH" 2>/dev/null
  git pull --rebase origin "$BASE_BRANCH" 2>/dev/null

  DEV_CMD=$(python3 -c "
import json
scripts = json.load(open('package.json')).get('scripts', {})
for cmd in ['start', 'dev', 'preview']:
    if cmd in scripts:
        print(cmd)
        break
" 2>/dev/null)

  if [ -z "$DEV_CMD" ]; then
    echo "No dev/start/preview script found"
    exit 1
  fi

  PR_LIST=$(mktemp)
  if [ -n "$PR_FILTER" ]; then
    # Single PR
    gh pr view "$PR_FILTER" --repo "$REPO" --json number,title,headRefName 2>/dev/null | \
      python3 -c "import json,sys; pr=json.loads(sys.stdin.read()); print(f\"{pr['number']}|{pr['headRefName']}|{pr['title']}\")" > "$PR_LIST"
    echo "Verifying PR #$PR_FILTER"
  else
    # All open PRs
    PRS=$(gh pr list --repo "$REPO" --state open --json number,title,headRefName --limit 50 2>/dev/null)
    PR_COUNT=$(echo "$PRS" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))")
    echo "Found $PR_COUNT open PRs"
    echo "$PRS" | python3 -c "
import json, sys
prs = json.loads(sys.stdin.read())
for pr in prs:
    print(f\"{pr['number']}|{pr['headRefName']}|{pr['title']}\")
" > "$PR_LIST"
  fi
  echo ""

  while IFS='|' read -r PR_NUM BRANCH TITLE; do
    echo "━━━ PR #$PR_NUM: $TITLE ━━━"

    SCREENSHOT_DIR="$LOGDIR/screenshots/pr-$PR_NUM"
    mkdir -p "$SCREENSHOT_DIR"

    # Checkout branch directly (no worktree — need real DB, .env, etc.)
    cd "$REPO_DIR"
    rm -rf .worktrees 2>/dev/null
    git worktree prune 2>/dev/null
    git checkout "$BRANCH" 2>/dev/null
    if [ $? -ne 0 ]; then
      echo "  Could not checkout $BRANCH — skipping"
      echo ""
      continue
    fi

    # Detect ports from project config and clear them
    DEV_PORTS=$(python3 -c "
import json, re, os
ports = set()
for f in ['vite.config.js', 'vite.config.ts']:
    if os.path.exists(f):
        content = open(f).read()
        m = re.search(r'port\s*:\s*(\d+)', content)
        if m: ports.add(m.group(1))
for f in ['backend/config.json', 'backend/server.js', 'backend/index.js']:
    if os.path.exists(f):
        content = open(f).read()
        for m in re.finditer(r'(?:port|PORT)\s*[:=]\s*[\"'\'']*(\d+)', content):
            ports.add(m.group(1))
for f in ['.env', 'backend/.env']:
    if os.path.exists(f):
        for line in open(f):
            m = re.match(r'PORT\s*=\s*(\d+)', line)
            if m: ports.add(m.group(1))
for f in ['package.json', 'backend/package.json']:
    if os.path.exists(f):
        scripts = json.load(open(f)).get('scripts', {})
        for v in scripts.values():
            for m in re.finditer(r'--port\s+(\d+)', v):
                ports.add(m.group(1))
ports.update(['3000', '5173', '8000'])
print(','.join(sorted(ports)))
" 2>/dev/null)
    if [ -n "$DEV_PORTS" ]; then
      echo "  Clearing ports $DEV_PORTS..."
      lsof -ti :$DEV_PORTS 2>/dev/null | xargs kill 2>/dev/null
      sleep 1
    fi

    # Start backend if it exists
    BACKEND_PID=""
    if [ -f "backend/package.json" ]; then
      BACKEND_START=$(python3 -c "
import json
scripts = json.load(open('backend/package.json')).get('scripts', {})
for cmd in ['start', 'dev']:
    if cmd in scripts:
        print(cmd)
        break
" 2>/dev/null)
      if [ -n "$BACKEND_START" ]; then
        echo "  Starting backend: npm run $BACKEND_START --prefix backend"
        npm run "$BACKEND_START" --prefix backend > /dev/null 2>&1 &
        BACKEND_PID=$!
        sleep 3
      fi
    fi

    DEV_LOG=$(mktemp)
    npm run "$DEV_CMD" > "$DEV_LOG" 2>&1 &
    DEV_PID=$!

    DEV_URL=""
    for i in $(seq 1 30); do
      DEV_URL=$(grep -oE 'https?://localhost:[0-9]+' "$DEV_LOG" 2>/dev/null | head -1)
      if [ -n "$DEV_URL" ]; then break; fi
      sleep 1
    done
    rm -f "$DEV_LOG"

    if [ -z "$DEV_URL" ]; then
      echo "  Dev server failed to start — skipping"
      kill "$DEV_PID" 2>/dev/null; wait "$DEV_PID" 2>/dev/null
      if [ -n "$BACKEND_PID" ]; then kill "$BACKEND_PID" 2>/dev/null; wait "$BACKEND_PID" 2>/dev/null; fi
      [ -n "$DEV_PORTS" ] && lsof -ti :$DEV_PORTS 2>/dev/null | xargs kill 2>/dev/null
      git checkout "$BASE_BRANCH" 2>/dev/null
      echo ""
      continue
    fi

    echo "  Dev server at $DEV_URL"
    DIFF=$(git diff "$BASE_BRANCH...$BRANCH" 2>/dev/null | head -200)

    # Pre-extract target route from diff
    TARGET_ROUTE=$(echo "$DIFF" | python3 -c "
import sys, re
routes = set()
for line in sys.stdin:
    for m in re.finditer(r\"path:\s*['\\\"]([^'\\\"]+)\", line):
        routes.add(m.group(1))
    m = re.match(r'^\+\+\+ b/.*?/(\w+View)\.\w+', line)
    if m:
        name = m.group(1).replace('View', '').lower()
        if name and name != 'app': routes.add(name)
if routes:
    best = sorted(routes, key=len, reverse=True)[0]
    print(best.strip('/'))
" 2>/dev/null)

    if [ -n "$TARGET_ROUTE" ]; then
      TARGET_URL="$DEV_URL/$TARGET_ROUTE"
      echo "  Target route: /$TARGET_ROUTE"
    else
      TARGET_URL="$DEV_URL"
    fi

    # Pre-create test account via API
    BACKEND_URL=$(echo "$DEV_URL" | sed 's/:5173/:8000/' | sed 's/:5174/:8000/')
    TEST_AUTH=""
    SIGNUP_RESULT=$(curl -s -X POST "$BACKEND_URL/api/signup" \
      -H "Content-Type: application/json" \
      -d '{"name":"Test User","email":"test@shipyard.dev","password":"shipyard123"}' 2>/dev/null)
    if echo "$SIGNUP_RESULT" | python3 -c "import sys,json; json.load(sys.stdin)['token']" 2>/dev/null; then
      TEST_AUTH="Test account created (test@shipyard.dev / shipyard123)"
    else
      SIGNIN_RESULT=$(curl -s -X POST "$BACKEND_URL/api/signin" \
        -H "Content-Type: application/json" \
        -d '{"email":"test@shipyard.dev","password":"shipyard123"}' 2>/dev/null)
      if echo "$SIGNIN_RESULT" | python3 -c "import sys,json; json.load(sys.stdin)['token']" 2>/dev/null; then
        TEST_AUTH="Test account exists (test@shipyard.dev / shipyard123)"
      fi
    fi

    VERIFY_PROMPT="You are verifying PR #$PR_NUM: $TITLE. Be fast — go directly to the target.

TARGET URL: $TARGET_URL
DEV SERVER: $DEV_URL
${TEST_AUTH:+AUTH: $TEST_AUTH — if you hit a login page, use these credentials to sign in.}

Log format: plain text only, no markdown.

GIT DIFF (truncated):
$DIFF

Steps:
1. Go directly to: agent-browser open $TARGET_URL
2. Wait: agent-browser wait --load networkidle
3. Snapshot: agent-browser snapshot -i
   If login page: sign in with test@shipyard.dev / shipyard123, then go to $TARGET_URL
4. Take a screenshot: agent-browser screenshot $SCREENSHOT_DIR/description.png
   You MUST take at least one screenshot.
5. Print VERIFY_DONE"

    echo "  Verifying PR #$PR_NUM..."
    VERIFY_PROMPT_FILE=$(mktemp)
    echo "$VERIFY_PROMPT" > "$VERIFY_PROMPT_FILE"
    VERIFY_LOG=$(mktemp)
    run_agent "$VERIFY_PROMPT_FILE" --model sonnet --timeout 120 --timeout-msg "  timed out" | \
      sed 's/^/  /' | tee "$VERIFY_LOG"
    rm -f "$VERIFY_PROMPT_FILE"

    kill "$DEV_PID" 2>/dev/null; wait "$DEV_PID" 2>/dev/null
    if [ -n "$BACKEND_PID" ]; then kill "$BACKEND_PID" 2>/dev/null; wait "$BACKEND_PID" 2>/dev/null; fi
    [ -n "$DEV_PORTS" ] && lsof -ti :$DEV_PORTS 2>/dev/null | xargs kill 2>/dev/null

    SCREENSHOTS=$(find "$SCREENSHOT_DIR" -name '*.png' -type f 2>/dev/null)
    if [ -n "$SCREENSHOTS" ]; then
      GH_OWNER=$(echo "$REPO" | cut -d/ -f1)

      cp "$SCREENSHOT_DIR"/*.png "$REPO_DIR/" 2>/dev/null
      cd "$REPO_DIR"
      git add *.png 2>/dev/null
      git commit -m "Add verification screenshots" 2>/dev/null
      git push origin "$BRANCH" 2>/dev/null

      COMMENT="## Verification Screenshots\n"
      for img in "$REPO_DIR"/*.png; do
        IMG_NAME=$(basename "$img")
        COMMENT="${COMMENT}\n### ${IMG_NAME%.png}\n![${IMG_NAME}](https://github.com/${GH_OWNER}/${REPO_NAME}/blob/${BRANCH}/${IMG_NAME}?raw=true)\n"
      done

      gh pr comment "$PR_NUM" --repo "$REPO" \
        --body "$(echo -e "$COMMENT")" 2>/dev/null
      echo "  Screenshots attached to PR #$PR_NUM"
    else
      echo "  No screenshots taken"
      VERIFY_REASON=$(tail -10 "$VERIFY_LOG" 2>/dev/null | grep -v 'still working' | tail -5)
      gh pr comment "$PR_NUM" --repo "$REPO" \
        --body "Screenshots missing

Verify output:
\`\`\`
${VERIFY_REASON:-no output from verify session}
\`\`\`" 2>/dev/null
    fi
    rm -f "$VERIFY_LOG"

    cd "$REPO_DIR"
    git checkout "$BASE_BRANCH" 2>/dev/null
    echo ""
  done < "$PR_LIST"
  rm -f "$PR_LIST"

  cd "$REPO_DIR"
  git checkout "$BASE_BRANCH" 2>/dev/null
  echo "━━━ DONE ━━━"
  exit 0
fi

# ── ISSUES: pull GitHub issues into tasks/ ─────────────────
if [ "$1" = "--issues" ]; then
  REPO="$2"
  if [ -z "$REPO" ]; then
    echo "Usage: bash factory.sh --issues owner/repo"
    exit 1
  fi

  log "Syncing issues from $REPO (label: shipyard)"
  export PROJECT_NAME=$(echo "$REPO" | cut -d/ -f2)
  export REPO TASK_DIR

  gh issue list --repo "$REPO" --label "shipyard" --state open --json number,title,body --limit 50 2>/dev/null | \
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
    print('  No issues with label \"shipyard\" found')
"
  exit 0
fi

# ── PICK (TRIAGE) ─────────────────────────────────────────
stage "PICK"
update_status "picking task..."
log "Reading tasks from $TASK_DIR"

# Find first unlocked task
TASK_FILE=""
for candidate in $(find "$TASK_DIR" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort); do
  LOCK_FILE="$LOCK_DIR/$(basename "$candidate").lock"
  # Try to acquire lock (atomic via mkdir)
  if mkdir "$LOCK_FILE" 2>/dev/null; then
    TASK_FILE="$candidate"
    break
  fi
done

# Clean up stale locks (older than 30 min)
find "$LOCK_DIR" -maxdepth 1 -name '*.lock' -type d -mmin +30 -exec rm -rf {} \; 2>/dev/null

if [ -z "$TASK_FILE" ]; then
  log "No pending tasks (or all locked)"
  update_status "idle — no tasks"
  exit 0
fi

TASK_NAME=$(basename "$TASK_FILE" .md)
TASK_BODY=$(cat "$TASK_FILE")

# Parse optional frontmatter for repo field
TASK_REPO=""
IS_NEW_REPO=false
if echo "$TASK_BODY" | head -1 | grep -q '^---$'; then
  TASK_REPO=$(echo "$TASK_BODY" | awk '/^---$/{n++;next} n==1 && /^repo:/{gsub(/^repo: */, ""); print}')
  TASK_PROMPT=$(echo "$TASK_BODY" | awk 'BEGIN{n=0} /^---$/{n++;next} n>=2{print}')
else
  TASK_PROMPT="$TASK_BODY"
fi

log "Task: $TASK_NAME"
log "Repo: ${TASK_REPO:-(new repo)}"
update_status "$TASK_NAME — picked"

DRY_RUN=false
if [ "$1" = "--dry-run" ]; then
  DRY_RUN=true
fi

# ── ROUTE (TRIAGE) ────────────────────────────────────────
stage "ROUTE"
update_status "$TASK_NAME — routing"

if [ -n "$TASK_REPO" ]; then
  # 1. Check local directory
  REPO_DIR=$(find "$PROJECTS" -maxdepth 1 -iname "$TASK_REPO" -type d 2>/dev/null | head -1)

  # 2. Not local — try cloning from GitHub (if gh is available)
  if [ -z "$REPO_DIR" ] && command -v gh &>/dev/null; then
    log "Not found locally, searching GitHub..."
    GH_REPO=$(gh repo list --limit 500 --json name,nameWithOwner 2>/dev/null | \
      python3 -c "import json,sys; repos=json.loads(sys.stdin.read()); matches=[r for r in repos if r['name'].lower()=='$TASK_REPO'.lower()]; print(matches[0]['nameWithOwner'] if matches else '')" 2>/dev/null)

    if [ -n "$GH_REPO" ]; then
      if [ "$DRY_RUN" = true ]; then
        log "Found on GitHub: $GH_REPO (would clone)"
        REPO_DIR="$PROJECTS/$TASK_REPO"
      else
        log "Found on GitHub: $GH_REPO — cloning"
        gh repo clone "$GH_REPO" "$PROJECTS/$TASK_REPO" 2>&1 | ptee
        REPO_DIR="$PROJECTS/$TASK_REPO"
      fi
    fi
  fi

  # 3. Not found anywhere — error
  if [ -z "$REPO_DIR" ]; then
    log "Could not find repo '$TASK_REPO' locally or on GitHub"
    exit 1
  fi
else
  # No repo specified — create new
  REPO_NAME=$(echo "$TASK_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
  REPO_DIR="$PROJECTS/$REPO_NAME"
  if [ "$DRY_RUN" = true ]; then
    IS_NEW_REPO=true
    log "Would create new repo: $REPO_NAME ($REPO_DIR)"
  else
    mkdir -p "$REPO_DIR"
    cd "$REPO_DIR" && git init 2>&1 | ptee
    IS_NEW_REPO=true
    log "Created new repo: $REPO_NAME ($REPO_DIR)"
  fi
fi

REPO_NAME=$(basename "$REPO_DIR")
log "Repo: $REPO_NAME ($REPO_DIR)"

# ── PREPARE (ENVIRONMENT) ─────────────────────────────────
stage "PREPARE"
update_status "$TASK_NAME — preparing"
cd "$REPO_DIR" 2>/dev/null
if [ "$IS_NEW_REPO" = false ]; then
  HAS_REMOTE=$(git remote 2>/dev/null | head -1)
  if [ -n "$HAS_REMOTE" ]; then
    # Detect default branch
    BASE_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
    if [ -z "$BASE_BRANCH" ]; then
      BASE_BRANCH=$(git branch -r 2>/dev/null | grep -oE 'origin/(main|master)' | head -1 | sed 's@origin/@@')
    fi
    BASE_BRANCH="${BASE_BRANCH:-main}"
    log "Base branch: $BASE_BRANCH"
    if [ "$DRY_RUN" = false ]; then
      git pull --rebase origin "$BASE_BRANCH" 2>&1 | ptee
    fi
  else
    BASE_BRANCH=$(git branch --show-current 2>/dev/null || echo "main")
    log "No remote — skipping pull (branch: $BASE_BRANCH)"
  fi
else
  BASE_BRANCH="main"
  log "New repo — skipping pull"
fi

BRANCH="shipyard/$TASK_NAME"
if [ "$IS_NEW_REPO" = false ] && [ "$DRY_RUN" = false ]; then
  git branch -D "$BRANCH" 2>/dev/null
  # Use worktree for isolation (parallel-safe)
  WORKTREE_DIR="$REPO_DIR/.worktrees/$TASK_NAME"
  rm -rf "$WORKTREE_DIR" 2>/dev/null
  git worktree prune 2>/dev/null
  git worktree add "$WORKTREE_DIR" -b "$BRANCH" 2>&1 | ptee
  REPO_DIR="$WORKTREE_DIR"
  cd "$REPO_DIR"
fi
log "Branch: $BRANCH"

# ── SCAFFOLD (BUILD) ──────────────────────────────────────
stage "SCAFFOLD"
update_status "$TASK_NAME — scaffolding"
if [ "$IS_NEW_REPO" = false ] && [ ! -d "$REPO_DIR/.github/workflows" ] && [ -f "$REPO_DIR/package.json" ]; then
  log "No CI workflow found — generating .github/workflows/ci.yml"
  mkdir -p "$REPO_DIR/.github/workflows"
  # Detect runtime and scripts
  CI_RUNTIME="node"
  CI_NODE_VERSION="22"
  if [ -f "$REPO_DIR/deno.json" ] || [ -f "$REPO_DIR/deno.jsonc" ]; then
    CI_RUNTIME="deno"
  fi
  HAS_BUILD=$(python3 -c "import json; s=json.load(open('$REPO_DIR/package.json')).get('scripts',{}); print('yes' if 'build' in s else '')" 2>/dev/null)
  HAS_TEST=$(python3 -c "import json; s=json.load(open('$REPO_DIR/package.json')).get('scripts',{}); print('yes' if 'test' in s else '')" 2>/dev/null)

  if [ "$CI_RUNTIME" = "deno" ]; then
    cat > "$REPO_DIR/.github/workflows/ci.yml" <<'CIEOF'
name: CI
on: [pull_request]
env:
  FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: denoland/setup-deno@v2
      - run: deno install
CIEOF
    if [ -n "$HAS_BUILD" ]; then
      echo "      - run: deno run build" >> "$REPO_DIR/.github/workflows/ci.yml"
    fi
    if [ -n "$HAS_TEST" ]; then
      echo "      - run: deno run test" >> "$REPO_DIR/.github/workflows/ci.yml"
    fi
  else
    cat > "$REPO_DIR/.github/workflows/ci.yml" <<CIEOF
name: CI
on: [pull_request]
env:
  FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: $CI_NODE_VERSION
      - run: npm install
CIEOF
    if [ -n "$HAS_BUILD" ]; then
      echo "      - run: npm run build" >> "$REPO_DIR/.github/workflows/ci.yml"
    fi
    if [ -n "$HAS_TEST" ]; then
      echo "      - run: npm test" >> "$REPO_DIR/.github/workflows/ci.yml"
    fi
  fi
  log "Generated CI workflow ($CI_RUNTIME)"
else
  log "CI workflow already present or not applicable"
fi

# Save pre-code state for lint checks
PRE_VERSION=""
if [ -f "$REPO_DIR/package.json" ]; then
  PRE_VERSION=$(python3 -c "import json; print(json.load(open('package.json')).get('version',''))" 2>/dev/null)
fi

# ── Dry run summary ───────────────────────────────────────
if [ "$DRY_RUN" = true ]; then
  echo "" | ptee
  log "━━━ DRY RUN SUMMARY ━━━"
  log "Task:       $TASK_NAME"
  log "Repo:       ${TASK_REPO:-(new repo)} → $REPO_DIR"
  log "New repo:   $IS_NEW_REPO"
  log "Branch:     $BRANCH"
  log "Base:       $BASE_BRANCH"
  log "Verify:     $(command -v agent-browser &>/dev/null && echo 'agent-browser available' || echo 'agent-browser not installed — skip')"
  log "Factory:    $SHIPYARD/factory.md"
  log ""
  log "━━━ PROMPT ━━━"
  echo "$TASK_PROMPT" | ptee
  rm -rf "$LOCK_DIR/$(basename "$TASK_FILE").lock" 2>/dev/null
  exit 0
fi

# ── CODE (TEST — agent session) ───────────────────────────
stage "CODE"
update_status "$TASK_NAME — coding..."
log "Ctrl+C to cancel. Monitor: tail -f $LOGFILE"
CODE_START=$(date +%s)

# Write prompt to temp file to avoid quoting issues with script
PROMPT_FILE=$(mktemp)
cat > "$PROMPT_FILE" <<PROMPT_EOF
You are running in shipyard mode. Complete this task autonomously.

REPO: $REPO_NAME
NEW_REPO: $IS_NEW_REPO
BRANCH: $BRANCH
BASE_BRANCH: $BASE_BRANCH

--- TASK ---
$TASK_PROMPT
--- END TASK ---

Log format rules (follow exactly):
- Stage headers: ━━━ STAGE_NAME ━━━ (e.g. ━━━ CODE ━━━, ━━━ TEST ━━━)
- Progress: plain text, no markdown, no ** or ## or []
- Results: plain text summary of what changed

Factory rules (every bullet is mandatory — grouped by the 8 factory.md sections):
$(factory_rules "$SHIPYARD/factory.md")

Pipeline (execute in order):
1. If NEW_REPO is true, scaffold the repo from scratch (README, package.json, etc.)
2. Implement the task
3. Run tests if they exist; if they fail, fix and re-run (max 3 attempts)
4. For each new or modified exported function, ensure a doc comment matches the implementation
5. If README describes features affected by your change, update it
6. If AGENTS.md or CLAUDE.md describes behavior affected by your change, update it
7. For each new error path, log the error with context
8. For each new external API call, log timing and result
9. Read package.json version and CHANGELOG.md before changing either
10. Bump minor version in package.json (e.g. 1.7.0 → 1.8.0); bump again if that version already exists in CHANGELOG
11. Add the new version to the top of CHANGELOG.md with a 3-word description (2-space indent, no dash)
12. Stage modified files plus .github/workflows/ if it exists (never git add . or git add -A)
13. Commit with a descriptive message (no AI attribution, no Co-Authored-By)
14. If NEW_REPO is true, create a GitHub repo: gh repo create PROJECT --private --source=. --push
15. Push the branch: git push origin $BRANCH
16. If NEW_REPO is false, open a PR: gh pr create --base $BASE_BRANCH
17. Print FACTORY_RESULT:SUCCESS or FACTORY_RESULT:FAILED
PROMPT_EOF

# Stream agent output in real time
run_agent "$PROMPT_FILE" --verbose | ptee
rm -f "$PROMPT_FILE"

CODE_END=$(date +%s)
CODE_ELAPSED=$(( CODE_END - CODE_START ))
log "Agent session completed in ${CODE_ELAPSED}s"

# Only run downstream gates if code stage actually shipped a PR
HAS_SHIPPED=false
grep -q "FACTORY_RESULT:SUCCESS" "$LOGFILE" 2>/dev/null && HAS_SHIPPED=true

# ── GATES (dispatch every rule bullet to check_gate) ─────
# Reads every bullet from the 8 factory.md sections and runs each through
# check_gate. Rules prefixed with `!` are strict: the framework must recognize
# and verify them, or the pipeline fails. Plain rules fall through to the
# agent when unrecognized.
stage "GATES"
update_status "$TASK_NAME — checking gates"
GATE_FAILURES=""
GATE_CUSTOM=""

while IFS= read -r line; do
  raw=$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*//' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
  [ -z "$raw" ] && continue
  case "$raw" in
    \[*\]) continue ;;  # skip section header labels from factory_rules
  esac

  # Detect `!` strict prefix
  strict=false
  gate="$raw"
  case "$raw" in
    "!"*) strict=true; gate=$(echo "$raw" | sed -E 's/^![[:space:]]*//') ;;
  esac

  check_gate "$gate"
  case "$?" in
    0) if [ "$strict" = true ]; then log "PASS: ! $gate"; else log "PASS: $gate"; fi ;;
    1) if [ "$strict" = true ]; then log "FAIL: ! $gate"; else log "FAIL: $gate"; fi
       GATE_FAILURES="${GATE_FAILURES}\n- $gate" ;;
    2) if [ "$strict" = true ]; then
         log "FAIL: ! $gate (strict — framework has no check for this rule)"
         GATE_FAILURES="${GATE_FAILURES}\n- $gate (strict: add a check_gate pattern or drop the !)"
       else
         log "FWD:  $gate"
         GATE_CUSTOM="${GATE_CUSTOM}\n- $gate"
       fi ;;
  esac
done < <(factory_rules "$SHIPYARD/factory.md")

GATE_FWD_COUNT=$(echo -e "$GATE_CUSTOM" | grep -c '^- ' || true)
if [ -z "$GATE_FAILURES" ]; then
  log "All strict gates passed ($GATE_FWD_COUNT plain rules forwarded to agent)"
else
  log "Gate failures detected"
fi

# ── FIX (agent fixes gate failures — max 2 attempts) ─────
if [ -n "$GATE_FAILURES" ] && [ "$HAS_SHIPPED" = true ]; then
  stage "FIX"
  update_status "$TASK_NAME — fixing gates"
  FIX_ATTEMPT=0
  MAX_FIX_ATTEMPTS=2

  while [ -n "$GATE_FAILURES" ] && [ "$FIX_ATTEMPT" -lt "$MAX_FIX_ATTEMPTS" ]; do
    FIX_ATTEMPT=$((FIX_ATTEMPT + 1))
    log "Fix attempt $FIX_ATTEMPT/$MAX_FIX_ATTEMPTS"

    FIX_PROMPT_FILE=$(mktemp)
    cat > "$FIX_PROMPT_FILE" <<FIX_EOF
You are fixing factory gate failures in a shipyard run. Fix these issues and commit.

PROJECT: $REPO_NAME
BRANCH: $BRANCH

GATE FAILURES (verified by the framework):
$(echo -e "$GATE_FAILURES")
$([ -n "$GATE_CUSTOM" ] && printf '\nADDITIONAL CONSTRAINTS (from factory.md, not auto-verified — honor them):%s\n' "$(echo -e "$GATE_CUSTOM")")

Log format: plain text, no markdown, no ** or ## or []. Use ━━━ STAGE ━━━ for headers.

Steps:
1. Fix each verified failure above
2. Honor the additional constraints if applicable
3. Stage only files you changed, commit with a descriptive message
4. Push: git push origin $BRANCH
5. Print FIX_DONE when finished
FIX_EOF

    run_agent "$FIX_PROMPT_FILE" --model sonnet --timeout 120 | ptee
    rm -f "$FIX_PROMPT_FILE"

    # Re-run gates
    GATE_FAILURES=""
    while IFS= read -r line; do
      raw=$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*//' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
      [ -z "$raw" ] && continue
      case "$raw" in \[*\]) continue ;; esac
      strict=false
      gate="$raw"
      case "$raw" in
        "!"*) strict=true; gate=$(echo "$raw" | sed -E 's/^![[:space:]]*//') ;;
      esac
      check_gate "$gate"
      rc=$?
      if [ "$rc" = "1" ]; then
        GATE_FAILURES="${GATE_FAILURES}\n- $gate"
      elif [ "$rc" = "2" ] && [ "$strict" = true ]; then
        GATE_FAILURES="${GATE_FAILURES}\n- $gate (strict: framework has no check)"
      fi
    done < <(factory_rules "$SHIPYARD/factory.md")

    if [ -z "$GATE_FAILURES" ]; then
      log "All gate failures fixed"
      break
    else
      log "Gates still failing after attempt $FIX_ATTEMPT"
    fi
  done

  if [ -n "$GATE_FAILURES" ]; then
    log "Could not fix all gate failures after $MAX_FIX_ATTEMPTS attempts"
  fi
fi

# ── SHIP ──────────────────────────────────────────────────
stage "SHIP"
update_status "$TASK_NAME — shipping"
if grep -q "FACTORY_RESULT:SUCCESS" "$LOGFILE" 2>/dev/null; then
  log "PR shipped on branch $BRANCH"
else
  log "No PR — agent reported failure"
fi

# ── CI GATE (watch GitHub Actions, fix failures) ─────────
if grep -q "FACTORY_RESULT:SUCCESS" "$LOGFILE" 2>/dev/null; then
  stage "CI"
  update_status "$TASK_NAME — watching CI"
  PR_NUM_CI=$(grep -o 'https://github.com/[^ ]*pull/[0-9]*' "$LOGFILE" | tail -1 | grep -o '[0-9]*$')
  GH_OWNER_CI=$(gh api user --jq '.login' 2>/dev/null)

  if [ -n "$PR_NUM_CI" ]; then
    # Wait for CI run to appear (max 30s)
    CI_RUN_ID=""
    for i in $(seq 1 15); do
      CI_RUN_ID=$(gh run list --repo "${GH_OWNER_CI}/${REPO_NAME}" --branch "$BRANCH" \
        --json databaseId,status --limit 1 2>/dev/null | \
        python3 -c "import json,sys; runs=json.loads(sys.stdin.read()); print(runs[0]['databaseId'] if runs else '')" 2>/dev/null)
      if [ -n "$CI_RUN_ID" ]; then break; fi
      sleep 2
    done

    if [ -n "$CI_RUN_ID" ]; then
      log "Watching CI run #$CI_RUN_ID..."
      gh run watch "$CI_RUN_ID" --repo "${GH_OWNER_CI}/${REPO_NAME}" 2>&1 | ptee

      CI_CONCLUSION=$(gh run view "$CI_RUN_ID" --repo "${GH_OWNER_CI}/${REPO_NAME}" --json conclusion --jq '.conclusion' 2>/dev/null)
      log "CI result: $CI_CONCLUSION"

      # If CI failed, try to fix (max 2 attempts)
      CI_FIX_ATTEMPT=0
      CI_MAX_ATTEMPTS=2
      while [ "$CI_CONCLUSION" = "failure" ] && [ "$CI_FIX_ATTEMPT" -lt "$CI_MAX_ATTEMPTS" ]; do
        CI_FIX_ATTEMPT=$((CI_FIX_ATTEMPT + 1))
        log "CI fix attempt $CI_FIX_ATTEMPT/$CI_MAX_ATTEMPTS"

        CI_FAILURES=$(gh run view "$CI_RUN_ID" --repo "${GH_OWNER_CI}/${REPO_NAME}" --log-failed 2>/dev/null | tail -50)
        CI_FIX_PROMPT_FILE=$(mktemp)
        cat > "$CI_FIX_PROMPT_FILE" <<CI_FIX_EOF
GitHub Actions CI failed. Fix the issues and push.

PROJECT: $REPO_NAME
BRANCH: $BRANCH

CI FAILURE LOG:
$CI_FAILURES

Log format: plain text, no markdown, no ** or ## or [].

Steps:
1. Read the failure log above and identify the issue
2. Fix the code
3. Stage and commit: git add <files> && git commit -m "Fix CI: <description>"
4. Push: git push origin $BRANCH
5. Print CI_FIX_DONE when finished
CI_FIX_EOF

        run_agent "$CI_FIX_PROMPT_FILE" --model sonnet --timeout 120 | ptee
        rm -f "$CI_FIX_PROMPT_FILE"

        # Wait for new CI run
        sleep 5
        CI_RUN_ID=$(gh run list --repo "${GH_OWNER_CI}/${REPO_NAME}" --branch "$BRANCH" \
          --json databaseId --limit 1 --jq '.[0].databaseId' 2>/dev/null)
        if [ -n "$CI_RUN_ID" ]; then
          log "Watching CI run #$CI_RUN_ID..."
          gh run watch "$CI_RUN_ID" --repo "${GH_OWNER_CI}/${REPO_NAME}" 2>&1 | ptee
          CI_CONCLUSION=$(gh run view "$CI_RUN_ID" --repo "${GH_OWNER_CI}/${REPO_NAME}" --json conclusion --jq '.conclusion' 2>/dev/null)
          log "CI result: $CI_CONCLUSION"
        else
          log "No new CI run found"
          break
        fi
      done

      if [ "$CI_CONCLUSION" = "success" ]; then
        log "CI passed"
      elif [ "$CI_CONCLUSION" = "failure" ]; then
        log "CI still failing after $CI_MAX_ATTEMPTS fix attempts"
      fi
    else
      log "No CI run found — skipping CI gate"
    fi
  fi
fi

# ── VERIFY (self-verification loop) ───────────────────────
if grep -q "FACTORY_RESULT:SUCCESS" "$LOGFILE" 2>/dev/null && command -v agent-browser &>/dev/null; then
  stage "VERIFY"
  update_status "$TASK_NAME — verifying"
  PR_NUM=$(grep -o 'https://github.com/[^ ]*pull/[0-9]*' "$LOGFILE" | tail -1 | grep -o '[0-9]*$')
  SCREENSHOT_DIR="$LOGDIR/screenshots/$TASK_NAME"
  mkdir -p "$SCREENSHOT_DIR"

  # Detect dev server command from package.json
  DEV_CMD=""
  DEV_URL=""
  cd "$REPO_DIR"
  if [ -f "package.json" ]; then
    DEV_CMD=$(python3 -c "
import json
scripts = json.load(open('package.json')).get('scripts', {})
for cmd in ['start', 'dev', 'preview']:
    if cmd in scripts:
        print(cmd)
        break
" 2>/dev/null)
  fi

  if [ -n "$DEV_CMD" ]; then
    # Detect ports from project config and clear them
    DEV_PORTS=$(python3 -c "
import json, re, os
ports = set()
# Check vite.config for frontend port
for f in ['vite.config.js', 'vite.config.ts']:
    if os.path.exists(f):
        content = open(f).read()
        m = re.search(r'port\s*:\s*(\d+)', content)
        if m: ports.add(m.group(1))
# Check backend config for server port
for f in ['backend/config.json', 'backend/server.js', 'backend/index.js']:
    if os.path.exists(f):
        content = open(f).read()
        for m in re.finditer(r'(?:port|PORT)\s*[:=]\s*[\"'\'']*(\d+)', content):
            ports.add(m.group(1))
# Check .env for PORT
for f in ['.env', 'backend/.env']:
    if os.path.exists(f):
        for line in open(f):
            m = re.match(r'PORT\s*=\s*(\d+)', line)
            if m: ports.add(m.group(1))
# Check package.json scripts for --port flags
for f in ['package.json', 'backend/package.json']:
    if os.path.exists(f):
        scripts = json.load(open(f)).get('scripts', {})
        for v in scripts.values():
            for m in re.finditer(r'--port\s+(\d+)', v):
                ports.add(m.group(1))
# Always include defaults: vite (5173) and common backend ports
ports.update(['3000', '5173', '8000'])
print(','.join(sorted(ports)))
" 2>/dev/null)
    if [ -n "$DEV_PORTS" ]; then
      log "Clearing ports $DEV_PORTS..."
      lsof -ti :$DEV_PORTS 2>/dev/null | xargs kill 2>/dev/null
      sleep 1
    fi

    # Install deps (worktree symlinks may be broken)
    if [ -n "$WORKTREE_DIR" ] && [ -f "package.json" ]; then
      log "Installing dependencies..."
      npm install --silent 2>/dev/null
      # Install workspace deps (e.g. backend/)
      if grep -q '"workspaces"' package.json 2>/dev/null; then
        npm install --workspaces --silent 2>/dev/null
      fi
    fi

    # Start backend if it exists (e.g. Skateboard apps with backend/)
    BACKEND_PID=""
    if [ -f "backend/package.json" ]; then
      BACKEND_START=$(python3 -c "
import json
scripts = json.load(open('backend/package.json')).get('scripts', {})
for cmd in ['start', 'dev']:
    if cmd in scripts:
        print(cmd)
        break
" 2>/dev/null)
      if [ -n "$BACKEND_START" ]; then
        log "Starting backend: npm run $BACKEND_START --prefix backend"
        npm run "$BACKEND_START" --prefix backend > /dev/null 2>&1 &
        BACKEND_PID=$!
        sleep 3
      fi
    fi

    log "Starting: npm run $DEV_CMD"
    DEV_LOG=$(mktemp)
    npm run "$DEV_CMD" > "$DEV_LOG" 2>&1 &
    DEV_PID=$!

    # Wait for server URL in output (max 30s)
    for i in $(seq 1 30); do
      DEV_URL=$(grep -oE 'https?://localhost:[0-9]+' "$DEV_LOG" 2>/dev/null | head -1)
      if [ -n "$DEV_URL" ]; then
        break
      fi
      sleep 1
    done
    rm -f "$DEV_LOG"

    if [ -n "$DEV_URL" ]; then
      log "Dev server ready at $DEV_URL — verifying changes"
      DIFF=$(git diff "$BASE_BRANCH...$BRANCH" 2>/dev/null)

      # Pre-extract target route from diff (deterministic, no agent needed)
      TARGET_ROUTE=$(echo "$DIFF" | python3 -c "
import sys, re
routes = set()
for line in sys.stdin:
    # Match route definitions: path: 'foo', '/foo', element: <FooView>
    for m in re.finditer(r\"path:\s*['\\\"]([^'\\\"]+)\", line):
        routes.add(m.group(1))
    # Match changed component filenames like PostsView, HomeView
    m = re.match(r'^\+\+\+ b/.*?/(\w+View)\.\w+', line)
    if m:
        name = m.group(1).replace('View', '').lower()
        if name and name != 'app': routes.add(name)
if routes:
    # Prefer the most specific route
    best = sorted(routes, key=len, reverse=True)[0]
    print(best.strip('/'))
" 2>/dev/null)

      if [ -n "$TARGET_ROUTE" ]; then
        TARGET_URL="$DEV_URL/$TARGET_ROUTE"
        log "Target route detected: /$TARGET_ROUTE"
      else
        TARGET_URL="$DEV_URL"
      fi

      # Pre-create test account via API (skip signup dance)
      TEST_AUTH=""
      BACKEND_URL=$(echo "$DEV_URL" | sed 's/:5173/:8000/' | sed 's/:5174/:8000/')
      SIGNUP_RESULT=$(curl -s -X POST "$BACKEND_URL/api/signup" \
        -H "Content-Type: application/json" \
        -d '{"name":"Test User","email":"test@shipyard.dev","password":"shipyard123"}' 2>/dev/null)
      if echo "$SIGNUP_RESULT" | python3 -c "import sys,json; json.load(sys.stdin)['token']" 2>/dev/null; then
        TEST_AUTH="Test account created (test@shipyard.dev / shipyard123)"
        log "Test account pre-created"
      else
        # Try signin in case account exists
        SIGNIN_RESULT=$(curl -s -X POST "$BACKEND_URL/api/signin" \
          -H "Content-Type: application/json" \
          -d '{"email":"test@shipyard.dev","password":"shipyard123"}' 2>/dev/null)
        if echo "$SIGNIN_RESULT" | python3 -c "import sys,json; json.load(sys.stdin)['token']" 2>/dev/null; then
          TEST_AUTH="Test account exists (test@shipyard.dev / shipyard123)"
          log "Test account already exists"
        fi
      fi

      VERIFY_PROMPT_FILE=$(mktemp)
      cat > "$VERIFY_PROMPT_FILE" <<VERIFY_EOF
You are a QA engineer verifying a code change. Be fast — go directly to the target.

TARGET URL: $TARGET_URL
DEV SERVER: $DEV_URL
${TEST_AUTH:+AUTH: $TEST_AUTH — if you hit a login page, use these credentials to sign in.}

TASK REQUIREMENTS:
$TASK_PROMPT

GIT DIFF:
$DIFF

SCREENSHOT DIR: $SCREENSHOT_DIR

Log format: plain text, no markdown, no ** or ## or []. Use ━━━ STAGE ━━━ for headers.

Steps:
1. Go directly to the target: agent-browser open $TARGET_URL
2. Wait for load: agent-browser wait --load networkidle
3. Snapshot: agent-browser snapshot -i
   - If login page: sign in with test@shipyard.dev / shipyard123, then go to $TARGET_URL again
4. Take a screenshot: agent-browser screenshot $SCREENSHOT_DIR/description.png
   - You MUST take at least one screenshot. This is not optional.
5. Compare the snapshot against task requirements

Print your verdict:
  VERIFY_PASS — implementation matches requirements
  VERIFY_FAIL: reason — something is wrong

Max 2 minutes. Focus on what the task asked for, not unrelated issues.
VERIFY_EOF

      log "Verifying implementation (max 120s)..."
      VERIFY_OUTPUT=$(run_agent "$VERIFY_PROMPT_FILE" --model sonnet --timeout 120 \
        --timeout-msg "VERIFY_PASS (timed out)" | ptee)
      rm -f "$VERIFY_PROMPT_FILE"

      # Check if verification passed or failed
      if echo "$VERIFY_OUTPUT" | grep -q "VERIFY_FAIL"; then
        FAIL_REASON=$(echo "$VERIFY_OUTPUT" | grep "VERIFY_FAIL" | sed 's/VERIFY_FAIL: *//')
        log "Verification FAILED: $FAIL_REASON"
        log "Attempting fix..."

        # Second agent session to fix the issue
        FIX_PROMPT_FILE=$(mktemp)
        cat > "$FIX_PROMPT_FILE" <<FIX_EOF
The QA verification of your code change found an issue. Fix it.

Log format: plain text, no markdown, no ** or ## or []. Use ━━━ STAGE ━━━ for headers.

TASK: $TASK_PROMPT
ISSUE: $FAIL_REASON

The dev server is running at $DEV_URL. Fix the code, then verify with agent-browser that it works.

Steps:
1. Fix the issue in the source code
2. Wait for hot reload (the dev server is still running)
3. Verify: agent-browser open $DEV_URL && agent-browser wait --load networkidle && agent-browser snapshot -i
4. Take a screenshot: agent-browser screenshot $SCREENSHOT_DIR/after-fix.png (REQUIRED)
5. Stage and commit: git add <files> && git commit -m "Fix: <description>"
6. Push: git push origin $BRANCH
7. Print VERIFY_PASS if fixed, VERIFY_FAIL: <reason> if still broken
FIX_EOF

        log "Running fix session..."
        run_agent "$FIX_PROMPT_FILE" --model sonnet --timeout 120 \
          --timeout-msg "VERIFY_PASS (timed out)" | ptee
        rm -f "$FIX_PROMPT_FILE"
        log "Fix attempt completed"
      else
        log "Verification PASSED"
      fi
    else
      log "Dev server did not start within 30s"
    fi

    # Kill dev server and backend
    kill "$DEV_PID" 2>/dev/null; wait "$DEV_PID" 2>/dev/null
    if [ -n "$BACKEND_PID" ]; then
      kill "$BACKEND_PID" 2>/dev/null; wait "$BACKEND_PID" 2>/dev/null
    fi
    # Kill any leftover node processes on the dev ports
    [ -n "$DEV_PORTS" ] && lsof -ti :$DEV_PORTS 2>/dev/null | xargs kill 2>/dev/null
  else
    log "No dev/start/preview script found — skipping verification"
  fi

  # Attach screenshots to PR
  SCREENSHOTS=$(find "$SCREENSHOT_DIR" -name '*.png' -type f 2>/dev/null)
  if [ -n "$SCREENSHOTS" ] && [ -n "$PR_NUM" ]; then
    GH_OWNER=$(gh api user --jq '.login' 2>/dev/null)

    # Commit screenshots to branch
    cp "$SCREENSHOT_DIR"/*.png "$REPO_DIR/" 2>/dev/null
    cd "$REPO_DIR"
    git add *.png 2>/dev/null
    git commit -m "Add verification screenshots" 2>/dev/null
    git push origin "$BRANCH" 2>/dev/null

    # Build PR comment with all screenshots
    COMMENT="## Verification Screenshots\n"
    for img in "$REPO_DIR"/*.png; do
      IMG_NAME=$(basename "$img")
      COMMENT="${COMMENT}\n### ${IMG_NAME%.png}\n![${IMG_NAME}](https://github.com/${GH_OWNER}/${REPO_NAME}/blob/${BRANCH}/${IMG_NAME}?raw=true)\n"
    done

    gh pr comment "$PR_NUM" --repo "${GH_OWNER}/${REPO_NAME}" \
      --body "$(echo -e "$COMMENT")" 2>/dev/null
    log "Screenshots attached to PR #$PR_NUM"
  elif [ -n "$PR_NUM" ]; then
    # Determine why screenshots are missing
    REASON="unknown"
    if ! command -v agent-browser &>/dev/null; then
      REASON="agent-browser is not installed"
    elif [ -z "$DEV_CMD" ]; then
      REASON="no dev/start/preview script found in package.json"
    elif [ -z "$DEV_URL" ]; then
      REASON="dev server did not start within 30s"
    else
      VERIFY_TAIL=$(tail -10 "$LOGFILE" 2>/dev/null | grep -v 'still working' | tail -5)
      REASON="verify session ran but did not produce screenshots

Verify output:
\`\`\`
${VERIFY_TAIL:-no output}
\`\`\`"
    fi
    log "WARN: No screenshots — $REASON"
    GH_OWNER=$(gh api user --jq '.login' 2>/dev/null)
    gh pr comment "$PR_NUM" --repo "${GH_OWNER}/${REPO_NAME}" \
      --body "Screenshots missing: $REASON" 2>/dev/null
  fi
fi

# ── UPDATE ────────────────────────────────────────────────
stage "UPDATE"
if grep -q "FACTORY_RESULT:SUCCESS" "$LOGFILE" 2>/dev/null; then
  # If task came from a GitHub issue, comment the PR link and close it
  ISSUE_REF=$(echo "$TASK_BODY" | sed -n '/^---$/,/^---$/p' | grep '^issue:' | sed 's/^issue: *//')
  if [ -n "$ISSUE_REF" ]; then
    ISSUE_REPO=$(echo "$ISSUE_REF" | cut -d'#' -f1)
    ISSUE_NUM=$(echo "$ISSUE_REF" | cut -d'#' -f2)
    PR_URL=$(grep -o 'https://github.com/[^ ]*pull/[0-9]*' "$LOGFILE" | tail -1)
    gh issue comment "$ISSUE_NUM" --repo "$ISSUE_REPO" --body "Shipped in ${PR_URL:-branch $BRANCH}" 2>&1 | ptee
    gh issue close "$ISSUE_NUM" --repo "$ISSUE_REPO" 2>&1 | ptee
    log "Closed issue: $ISSUE_REF"
  fi

  mv "$TASK_FILE" "$DONE_DIR/$(basename "$TASK_FILE")"
  log "Moved to done: $TASK_NAME"

  REMAINING=$(find "$TASK_DIR" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | xargs)
  log "Remaining tasks: $REMAINING"
else
  log "Skipped — task failed"
fi

# ── DONE ──────────────────────────────────────────────────
stage "DONE"
if grep -q "FACTORY_RESULT:SUCCESS" "$LOGFILE" 2>/dev/null; then
  log "Factory run successful"
  update_status "$TASK_NAME ✓ done"
else
  log "Factory run failed — check log: $LOGFILE"
  update_status "$TASK_NAME ✗ failed"
fi

# Clean up worktree and lock
if [ -n "$WORKTREE_DIR" ] && [ -d "$WORKTREE_DIR" ]; then
  ORIG_REPO=$(dirname "$WORKTREE_DIR")/..
  cd "$SHIPYARD"
  rm -rf "$WORKTREE_DIR" 2>/dev/null
  git -C "$(cd "$ORIG_REPO" && pwd)" worktree prune 2>/dev/null
fi
if [ -n "$TASK_FILE" ]; then
  rm -rf "$LOCK_DIR/$(basename "$TASK_FILE").lock" 2>/dev/null
fi

# Exit based on factory result
grep -q "FACTORY_RESULT:SUCCESS" "$LOGFILE" 2>/dev/null
