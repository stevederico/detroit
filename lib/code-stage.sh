# shellcheck shell=bash

run_code_stage() {
  local TASK_ROUTE="build" PLAN_BODY TRIAGE_BODY FACTORY_STAGES
  local TRIAGE_PROMPT_FILE TRIAGE_OUT PLAN_PROMPT_FILE PROMPT_FILE
  local CODE_START CODE_END CODE_ELAPSED LESSONS_SNIP req ans waited _approve
  PLAN_DOC=""

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

  stage "CODE"
  update_status "$TASK_NAME — coding..."
  log "Ctrl+C to cancel. Monitor: tail -f $LOGFILE"
  CODE_START=$(date +%s)

  LESSONS_SNIP=""
  if [ -f "$DETROIT/lessons.md" ] && grep -q '^- ' "$DETROIT/lessons.md" 2>/dev/null; then
    LESSONS_SNIP=$(grep '^- ' "$DETROIT/lessons.md" | tail -15)
  fi

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
$([ -n "$LESSONS_SNIP" ] && printf '\n--- PAST LESSONS (avoid repeating these failures) ---\n%s\n--- END LESSONS ---\n' "$LESSONS_SNIP")

PROMPT_EOF

  run_agent "$PROMPT_FILE" --verbose \
    --timeout "${DETROIT_CODE_TIMEOUT:-3600}" \
    --timeout-msg "CODE stage timed out after ${DETROIT_CODE_TIMEOUT:-3600}s" | ptee
  rm -f "$PROMPT_FILE"

  CODE_END=$(date +%s)
  CODE_ELAPSED=$(( CODE_END - CODE_START ))
  log "Agent session completed in ${CODE_ELAPSED}s"
}
