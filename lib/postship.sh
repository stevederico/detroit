# shellcheck shell=bash
# lib/postship.sh — post-ship stages: CI → VERIFY → UPDATE → DONE.
# Reads pipeline globals set by lib/pipeline.sh; its final command's exit code
# is the factory run's exit code. VERIFY uses lib/devserver.sh helpers.

run_postship() {
# ── CI GATE (watch GitHub Actions, fix failures) ─────────
if grep -q "FACTORY_RESULT:SUCCESS" "$LOGFILE" 2>/dev/null; then
  stage "CI"
  update_status "$TASK_NAME — watching CI"
  PR_NUM_CI=$(grep -o 'https://github.com/[^ ]*pull/[0-9]*' "$LOGFILE" | tail -1 | grep -o '[0-9]*$')
  GH_OWNER_CI=$(gh api user --jq '.login' 2>/dev/null)

  if [ -n "$PR_NUM_CI" ]; then
    # Wait for CI run to appear (max 30s)
    CI_RUN_ID=""
    for _ in $(seq 1 15); do
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
  DEV_URL=""
  cd "$REPO_DIR" || exit 1
  detect_dev_cmd

  if [ -n "$DEV_CMD" ]; then
    detect_dev_ports
    if [ -n "$DEV_PORTS" ]; then
      log "Clearing ports $DEV_PORTS..."
      clear_dev_ports
    fi

    # Install deps (worktree symlinks may be broken); surface failures in the log
    if [ -n "$WORKTREE_DIR" ] && [ -f "package.json" ]; then
      log "Installing dependencies..."
      npm install --silent 2>&1 | tail -5 | ptee
      # Install workspace deps (e.g. backend/)
      if grep -q '"workspaces"' package.json 2>/dev/null; then
        npm install --workspaces --silent 2>&1 | tail -5 | ptee
      fi
    fi

    # Start backend if it exists (e.g. Skateboard apps with backend/)
    start_backend

    log "Starting: npm run $DEV_CMD"
    start_dev_server

    if [ -n "$DEV_URL" ]; then
      log "Dev server ready at $DEV_URL — verifying changes"
      DIFF=$(git diff "$BASE_BRANCH...$BRANCH" 2>/dev/null)

      # Pre-extract target route from diff (deterministic, no agent needed)
      extract_target_route "$DIFF"
      if [ -n "$TARGET_ROUTE" ]; then
        TARGET_URL="$DEV_URL/$TARGET_ROUTE"
        log "Target route detected: /$TARGET_ROUTE"
      else
        TARGET_URL="$DEV_URL"
      fi

      # Pre-create test account via API (skip signup dance)
      precreate_test_account
      case "$TEST_AUTH" in
        *created*) log "Test account pre-created" ;;
        *exists*)  log "Test account already exists" ;;
      esac

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
   - If login page: sign in with test@detroit.dev / detroit123, then go to $TARGET_URL again
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

    # Kill dev server, backend, and anything left on the dev ports
    stop_dev_servers
  else
    log "No dev/start/preview script found — skipping verification"
  fi

  # Attach screenshots to PR
  SCREENSHOTS=$(find "$SCREENSHOT_DIR" -name '*.png' -type f 2>/dev/null)
  if [ -n "$SCREENSHOTS" ] && [ -n "$PR_NUM" ]; then
    GH_OWNER=$(gh api user --jq '.login' 2>/dev/null)

    # Commit screenshots to branch and build the PR comment in one pass
    cd "$REPO_DIR" || exit 1
    COMMENT="## Verification Screenshots\n"
    for img in "$SCREENSHOT_DIR"/*.png; do
      [ -e "$img" ] || continue  # empty glob — no screenshots
      IMG_NAME=$(basename "$img")
      cp "$img" "$REPO_DIR/" && git add -- "$IMG_NAME"
      COMMENT="${COMMENT}\n### ${IMG_NAME%.png}\n![${IMG_NAME}](https://github.com/${GH_OWNER}/${REPO_NAME}/blob/${BRANCH}/${IMG_NAME}?raw=true)\n"
    done
    git commit -m "Add verification screenshots" 2>&1 | ptee
    git push origin "$BRANCH" 2>&1 | ptee

    gh pr comment "$PR_NUM" --repo "${GH_OWNER}/${REPO_NAME}" \
      --body "$(echo -e "$COMMENT")" 2>&1 | ptee
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
if [ -n "$WORKTREE_DIR" ] && [ -d "$WORKTREE_DIR" ] && [ -n "$MAIN_REPO_DIR" ]; then
  cd "$DETROIT" || exit 1
  git -C "$MAIN_REPO_DIR" worktree remove --force "$WORKTREE_DIR" 2>/dev/null || rm -rf "$WORKTREE_DIR"
  git -C "$MAIN_REPO_DIR" worktree prune 2>/dev/null
fi
if [ -n "$TASK_FILE" ]; then
  rm -rf "$LOCK_DIR/$(basename "$TASK_FILE").lock" 2>/dev/null
fi

# Exit based on factory result
grep -q "FACTORY_RESULT:SUCCESS" "$LOGFILE" 2>/dev/null
}
