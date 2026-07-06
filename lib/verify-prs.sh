# shellcheck shell=bash
# lib/verify-prs.sh — --verify mode: screenshot open PRs for a repo.
# Uses the shared dev-server helpers in lib/devserver.sh.

mode_verify() {
  REPO="$VERIFY_REPO"
  PR_FILTER="$VERIFY_PR"

  REPO_NAME=$(echo "$REPO" | cut -d/ -f2)
  REPO_DIR=$(find "$PROJECTS" -maxdepth 1 -iname "$REPO_NAME" -type d 2>/dev/null | head -1)

  if [ -z "$REPO_DIR" ]; then
    echo "Could not find repo: $REPO_NAME"
    exit 1
  fi

  echo "━━━ VERIFY ALL PRs: $REPO ━━━"
  echo "Repo: $REPO_DIR"
  echo ""

  cd "$REPO_DIR" || exit 1
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

  detect_dev_cmd
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
    cd "$REPO_DIR" || continue
    rm -rf .worktrees 2>/dev/null
    git worktree prune 2>/dev/null
    if ! git checkout "$BRANCH"; then
      echo "  Could not checkout $BRANCH — skipping"
      echo ""
      continue
    fi

    detect_dev_ports
    if [ -n "$DEV_PORTS" ]; then
      echo "  Clearing ports $DEV_PORTS..."
      clear_dev_ports
    fi

    start_backend
    start_dev_server

    if [ -z "$DEV_URL" ]; then
      echo "  Dev server failed to start — skipping"
      stop_dev_servers
      git checkout "$BASE_BRANCH"
      echo ""
      continue
    fi

    echo "  Dev server at $DEV_URL"
    DIFF=$(git diff "$BASE_BRANCH...$BRANCH" 2>/dev/null | head -200)

    extract_target_route "$DIFF"
    if [ -n "$TARGET_ROUTE" ]; then
      TARGET_URL="$DEV_URL/$TARGET_ROUTE"
      echo "  Target route: /$TARGET_ROUTE"
    else
      TARGET_URL="$DEV_URL"
    fi

    precreate_test_account

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
   If login page: sign in with $TEST_EMAIL / $TEST_PASSWORD, then go to $TARGET_URL
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

    stop_dev_servers

    SCREENSHOTS=$(find "$SCREENSHOT_DIR" -name '*.png' -type f 2>/dev/null)
    if [ -n "$SCREENSHOTS" ]; then
      GH_OWNER=$(echo "$REPO" | cut -d/ -f1)

      cd "$REPO_DIR" || continue
      COMMENT="## Verification Screenshots\n"
      for img in "$SCREENSHOT_DIR"/*.png; do
        [ -e "$img" ] || continue  # empty glob — no screenshots
        IMG_NAME=$(basename "$img")
        cp "$img" "$REPO_DIR/" && git add -- "$IMG_NAME"
        COMMENT="${COMMENT}\n### ${IMG_NAME%.png}\n![${IMG_NAME}](https://github.com/${GH_OWNER}/${REPO_NAME}/blob/${BRANCH}/${IMG_NAME}?raw=true)\n"
      done
      git commit -m "Add verification screenshots"
      git push origin "$BRANCH"

      gh pr comment "$PR_NUM" --repo "$REPO" \
        --body "$(echo -e "$COMMENT")"
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

    cd "$REPO_DIR" || continue
    git checkout "$BASE_BRANCH"
    echo ""
  done < "$PR_LIST"
  rm -f "$PR_LIST"

  cd "$REPO_DIR" || exit 1
  git checkout "$BASE_BRANCH"
  echo "━━━ DONE ━━━"
  exit 0
}
