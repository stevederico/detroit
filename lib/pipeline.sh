# shellcheck shell=bash
# shellcheck disable=SC2034  # pipeline globals are consumed by postship.sh/gates.sh/core.sh
# lib/pipeline.sh — the pre-ship pipeline: PICK → ROUTE → PREPARE → SCAFFOLD →
# TRIAGE → PLAN → CODE → GATES → FIX → SHIP. State is global on purpose: the
# INT trap and lib/postship.sh read TASK_FILE, REPO_DIR, BRANCH, BASE_BRANCH,
# MAIN_REPO_DIR, WORKTREE_DIR, HAS_SHIPPED, TASK_BODY, TASK_NAME, TASK_PROMPT.

run_pipeline() {
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
  log "Factory:    $DETROIT/factory.md"
  log ""
  log "━━━ PROMPT ━━━"
  echo "$TASK_PROMPT" | ptee
  rm -rf "$LOCK_DIR/$(basename "$TASK_FILE").lock" 2>/dev/null
  exit 0
fi

# ── CODE (TEST — agent session) ───────────────────────────
# ── TRIAGE + PLAN (factory.md v2 pre-code prompt stages) ──
# Run only when the factory declares them as `prompt` stages and provides a
# `## triage` / `## plan` body. Unattended by default; DETROIT_APPROVE_PLAN=1
# adds an interactive plan-approval gate. Threads the resulting plan into CODE.
TASK_ROUTE="build"
PLAN_DOC=""
if [ "$DRY_RUN" = false ]; then
  FACTORY_STAGES=$(factory_stages "$DETROIT/factory.md")
  TRIAGE_BODY=$(factory_section "triage" "$DETROIT/factory.md")
  if echo "$FACTORY_STAGES" | grep -q '^triage:prompt$' && [ -n "$TRIAGE_BODY" ]; then
    stage "TRIAGE"
    update_status "$TASK_NAME — triaging"
    TRIAGE_PROMPT_FILE=$(mktemp)
    cat > "$TRIAGE_PROMPT_FILE" <<TRIAGE_EOF
$TRIAGE_BODY

--- TASK ---
$TASK_PROMPT
--- END TASK ---

Respond with exactly one line — "route: build" or "route: plan" — then a one-sentence reason. Do nothing else; do not touch the repo.
TRIAGE_EOF
    TRIAGE_OUT=$(run_agent "$TRIAGE_PROMPT_FILE" --model sonnet --timeout 60)
    rm -f "$TRIAGE_PROMPT_FILE"
    printf '%s\n' "$TRIAGE_OUT" | ptee
    if printf '%s' "$TRIAGE_OUT" | grep -qiE 'route:[[:space:]]*plan'; then
      TASK_ROUTE="plan"
    fi
    log "Triage route: $TASK_ROUTE"
  fi

  PLAN_BODY=$(factory_section "plan" "$DETROIT/factory.md")
  if [ "$TASK_ROUTE" = "plan" ] && echo "$FACTORY_STAGES" | grep -q '^plan:prompt$' && [ -n "$PLAN_BODY" ]; then
    stage "PLAN"
    update_status "$TASK_NAME — writing plan"
    PLAN_PROMPT_FILE=$(mktemp)
    cat > "$PLAN_PROMPT_FILE" <<PLAN_EOF
$PLAN_BODY

--- TASK ---
$TASK_PROMPT
--- END TASK ---

Repo: $REPO_NAME (branch $BRANCH). Write the filled template to plan.md in the repo root. Output only the plan — do not implement anything, do not run git.
PLAN_EOF
    run_agent "$PLAN_PROMPT_FILE" --model sonnet --timeout 120 | ptee
    rm -f "$PLAN_PROMPT_FILE"
    if [ -f "$REPO_DIR/plan.md" ]; then
      PLAN_DOC=$(cat "$REPO_DIR/plan.md")
      log "Plan written: $REPO_DIR/plan.md"
      if [ "${DETROIT_APPROVE_PLAN:-0}" = "web" ]; then
        # File-based gate for the web UI: publish a request, poll for the verdict.
        stage "APPROVE"
        log "Review $REPO_DIR/plan.md — awaiting web approval"
        req="$STATUS_DIR/approve-request-$AGENT_ID"
        ans="$STATUS_DIR/approve-$AGENT_ID"
        rm -f "$ans"
        echo "$REPO_DIR/plan.md" > "$req"
        update_status "$TASK_NAME — awaiting plan approval"
        waited=0
        while [ ! -f "$ans" ] && [ "$waited" -lt 1800 ]; do sleep 2; waited=$((waited + 2)); done
        _approve=$(cat "$ans" 2>/dev/null || echo n)
        rm -f "$ans" "$req"
        case "$_approve" in
          y|Y|yes|YES) log "Plan approved (web)" ;;
          *) log "Plan rejected — aborting task"; cleanup; exit 0 ;;
        esac
      elif [ "${DETROIT_APPROVE_PLAN:-0}" = "1" ]; then
        stage "APPROVE"
        log "Review $REPO_DIR/plan.md"
        printf 'Approve plan and continue? [y/N] '
        read -r _approve </dev/tty 2>/dev/null || _approve="y"
        case "$_approve" in
          y|Y|yes|YES) log "Plan approved" ;;
          *) log "Plan rejected — aborting task"; cleanup; exit 0 ;;
        esac
      fi
    else
      log "No plan.md produced; proceeding without a plan"
    fi
  fi
fi

stage "CODE"
update_status "$TASK_NAME — coding..."
log "Ctrl+C to cancel. Monitor: tail -f $LOGFILE"
CODE_START=$(date +%s)

# Write prompt to temp file to avoid quoting issues with script
PROMPT_FILE=$(mktemp)
cat > "$PROMPT_FILE" <<PROMPT_EOF
You are running in detroit mode. Complete this task autonomously.

REPO: $REPO_NAME
NEW_REPO: $IS_NEW_REPO
BRANCH: $BRANCH
BASE_BRANCH: $BASE_BRANCH

--- TASK ---
$TASK_PROMPT
--- END TASK ---
$([ -n "$PLAN_DOC" ] && printf '\n--- APPROVED PLAN (implement to this) ---\n%s\n--- END PLAN ---\n' "$PLAN_DOC")

Log format rules (follow exactly):
- Stage headers: ━━━ STAGE_NAME ━━━ (e.g. ━━━ CODE ━━━, ━━━ TEST ━━━)
- Progress: plain text, no markdown, no ** or ## or []
- Results: plain text summary of what changed

Factory rules (every bullet is mandatory — grouped by the 8 factory.md sections):
$(factory_rules "$DETROIT/factory.md")

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

# Stream agent output in real time (hung sessions die at DETROIT_CODE_TIMEOUT)
run_agent "$PROMPT_FILE" --verbose \
  --timeout "${DETROIT_CODE_TIMEOUT:-3600}" \
  --timeout-msg "CODE stage timed out after ${DETROIT_CODE_TIMEOUT:-3600}s" | ptee
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
}
