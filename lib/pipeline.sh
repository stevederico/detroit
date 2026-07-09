# shellcheck shell=bash
# shellcheck disable=SC2034  # pipeline globals are consumed by postship.sh/gates.sh/core.sh
# lib/pipeline.sh — pre-ship pipeline: PICK → ROUTE → PREPARE → SCAFFOLD →
# CODE (via code-stage.sh) → GATES → FIX → SHIP. State is global on purpose:
# INT trap and lib/postship.sh read TASK_FILE, REPO_DIR, BRANCH, BASE_BRANCH,
# MAIN_REPO_DIR, WORKTREE_DIR, HAS_SHIPPED, QUALITY_OK, TASK_BODY, TASK_NAME,
# TASK_PROMPT.

run_pipeline() {
# ── PICK (TRIAGE) ─────────────────────────────────────────
stage "PICK"
update_status "picking task..."
log "Reading tasks from $TASK_DIR"
QUALITY_OK=true
HAS_SHIPPED=false
FACTORY_OK=false

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
cd "$REPO_DIR" || { log "Cannot cd to $REPO_DIR"; exit 1; }
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

BRANCH="detroit/$TASK_NAME"
if [ "$IS_NEW_REPO" = false ] && [ "$DRY_RUN" = false ]; then
  MAIN_REPO_DIR="$REPO_DIR"
  git branch -D "$BRANCH" 2>/dev/null
  # Use worktree for isolation (parallel-safe)
  WORKTREE_DIR="$REPO_DIR/.worktrees/$TASK_NAME"
  rm -rf "$WORKTREE_DIR" 2>/dev/null
  git worktree prune 2>/dev/null
  git worktree add "$WORKTREE_DIR" -b "$BRANCH" 2>&1 | ptee
  REPO_DIR="$WORKTREE_DIR"
  cd "$REPO_DIR" || exit 1
fi
log "Branch: $BRANCH"

# ── SCAFFOLD (BUILD) ──────────────────────────────────────
stage "SCAFFOLD"
update_status "$TASK_NAME — scaffolding"
if [ "$IS_NEW_REPO" = false ] && [ ! -d "$REPO_DIR/.github/workflows" ] && [ -f "$REPO_DIR/package.json" ]; then
  log "No CI workflow found — generating .github/workflows/ci.yml"
  mkdir -p "$REPO_DIR/.github/workflows"
  # Detect runtime and scripts; node version comes from factory.md `## build`
  # (`node NN` bullet) so spec and generated workflow can't disagree
  CI_RUNTIME="node"
  CI_NODE_VERSION=$(factory_section "build" "$DETROIT/factory.md" | sed -nE 's/^[-*+[:space:]]*node[[:space:]]+([0-9]+).*/\1/p' | head -1)
  CI_NODE_VERSION="${CI_NODE_VERSION:-22}"
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
  log "Factory:    $DETROIT/factory.md"
  log ""
  log "━━━ PROMPT ━━━"
  echo "$TASK_PROMPT" | ptee
  rm -rf "$LOCK_DIR/$(basename "$TASK_FILE").lock" 2>/dev/null
  exit 0
fi

# ── CODE (via lib/code-stage.sh) ──────────────────────────
run_code_stage

# Only run downstream gates if code stage actually shipped — verified facts
# (commits + PR/remote), not the agent's FACTORY_RESULT print
verify_shipped

# ── GATES (dispatch every rule bullet to check_gate) ─────
# Rules prefixed with `!` are strict: framework must recognize and verify them.
# Plain rules fall through to the agent when unrecognized.
stage "GATES"
update_status "$TASK_NAME — checking gates"
run_all_gates "$DETROIT/factory.md"

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
You are fixing factory gate failures in a detroit run. Fix these issues and commit.

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

    # Re-run gates (stage-aware; resets accumulators)
    run_all_gates "$DETROIT/factory.md"

    if [ -z "$GATE_FAILURES" ]; then
      log "All gate failures fixed"
      break
    else
      log "Gates still failing after attempt $FIX_ATTEMPT"
    fi
  done
fi

if [ -n "$GATE_FAILURES" ]; then
  log "Could not clear gate failures"
  quality_fail "gates" "remaining failures after max fix attempts"
fi

# ── SHIP ──────────────────────────────────────────────────
stage "SHIP"
update_status "$TASK_NAME — shipping"
if [ "$HAS_SHIPPED" = true ]; then
  log "PR shipped on branch $BRANCH${PR_URL:+ — $PR_URL}"
else
  log "No PR — nothing verified on branch"
fi
}
