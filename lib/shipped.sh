# shellcheck shell=bash
# lib/shipped.sh — decide whether a factory run actually shipped.
# Sets HAS_SHIPPED, PR_NUM, PR_URL from verified facts (git + gh), not agent prints.

# verify_shipped — Existing repo: commits on the branch AND an open PR for it
# (gh outage falls back to remote-branch existence with a WARN).
# New repo: local commits AND a reachable origin remote.
verify_shipped() {
  HAS_SHIPPED=false
  PR_NUM=""
  PR_URL=""
  local commits pr_json gh_rc=0

  if [ "$IS_NEW_REPO" = true ]; then
    commits=$(git -C "$REPO_DIR" rev-list --count HEAD 2>/dev/null || echo 0)
    if [ "${commits:-0}" -gt 0 ] && git -C "$REPO_DIR" ls-remote origin >/dev/null 2>&1; then
      HAS_SHIPPED=true
      log "shipped check: new repo pushed ($commits commits)"
    else
      log "shipped check: new repo has no pushed remote"
    fi
    return 0
  fi

  commits=$(git -C "$REPO_DIR" rev-list --count "$BASE_BRANCH..$BRANCH" 2>/dev/null || echo 0)
  if [ "${commits:-0}" -eq 0 ]; then
    log "shipped check: no commits on $BRANCH"
    return 0
  fi

  pr_json=$(cd "$REPO_DIR" && gh pr list --head "$BRANCH" --state open --json number,url 2>/dev/null) || gh_rc=$?
  if [ "$gh_rc" -ne 0 ]; then
    # gh unavailable — fall back to remote-branch existence
    if [ -n "$(git -C "$REPO_DIR" ls-remote --heads origin "$BRANCH" 2>/dev/null)" ]; then
      log "WARN: gh unavailable — branch is on origin, treating as shipped (no PR metadata)"
      HAS_SHIPPED=true
    else
      log "shipped check: gh unavailable and branch not on origin"
    fi
    return 0
  fi

  PR_NUM=$(echo "$pr_json" | python3 -c "import json,sys; prs=json.loads(sys.stdin.read() or '[]'); print(prs[0]['number'] if prs else '')" 2>/dev/null)
  PR_URL=$(echo "$pr_json" | python3 -c "import json,sys; prs=json.loads(sys.stdin.read() or '[]'); print(prs[0]['url'] if prs else '')" 2>/dev/null)
  if [ -n "$PR_NUM" ]; then
    HAS_SHIPPED=true
    log "shipped check: $commits commit(s) on $BRANCH, open PR #$PR_NUM"
    log "PR: $PR_URL"
  else
    log "shipped check: $commits commit(s) on $BRANCH but no open PR"
  fi
}
