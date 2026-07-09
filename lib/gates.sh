# shellcheck shell=bash
# lib/gates.sh — deterministic rule gates.
# check_gate reads outer-scope: BASE_BRANCH, BRANCH, REPO_DIR, PRE_VERSION, LOGFILE.
# run_gate_bullets / run_all_gates accumulate into GATE_FAILURES, GATE_CUSTOM, GATE_SEEN.

# run_repo_tests — deterministically run the target repo's tests in $REPO_DIR.
# Command resolution: DETROIT_TEST_CMD env override > package.json scripts.test
# (npm test). No package.json → skip-pass (non-Node). package.json with missing
# or npm-placeholder scripts.test → fail (Node projects must have real tests).
# Installs node_modules first if missing. Timeout: DETROIT_TEST_TIMEOUT (300s).
# On failure the tail lands in TEST_GATE_OUTPUT for the FIX prompt.
# Returns 0 on pass/skip, 1 on failure or timeout.
run_repo_tests() {
  TEST_GATE_OUTPUT=""
  local cmd="" script out rc=0
  local timeout_secs="${DETROIT_TEST_TIMEOUT:-300}"
  if [ -n "${DETROIT_TEST_CMD:-}" ]; then
    cmd="$DETROIT_TEST_CMD"
  elif [ -f "$REPO_DIR/package.json" ]; then
    script=$(python3 -c "import json; print(json.load(open('$REPO_DIR/package.json')).get('scripts',{}).get('test',''))" 2>/dev/null)
    case "$script" in
      ""|*"no test specified"*)
        TEST_GATE_OUTPUT="package.json present but no real test script"
        log "test gate: no real test script — fail"
        return 1
        ;;
      *) cmd="npm test --silent" ;;
    esac
  else
    log "test gate: no package.json — skipped"
    return 0
  fi
  if [ -f "$REPO_DIR/package.json" ] && [ ! -d "$REPO_DIR/node_modules" ]; then
    log "test gate: node_modules missing — npm install"
    if ! (cd "$REPO_DIR" && npm install --silent) >>"$LOGFILE" 2>&1; then
      TEST_GATE_OUTPUT="npm install failed before tests could run (see log)"
      log "test gate: npm install failed"
      return 1
    fi
  fi
  log "test gate: running '$cmd' (timeout ${timeout_secs}s)"
  out=$(mktemp)
  ( cd "$REPO_DIR" && with_timeout "$timeout_secs" bash -c "$cmd" ) >"$out" 2>&1 || rc=$?
  cat "$out" >> "$LOGFILE"
  if [ "$rc" -eq 124 ]; then
    TEST_GATE_OUTPUT="tests timed out after ${timeout_secs}s"
  elif [ "$rc" -ne 0 ]; then
    TEST_GATE_OUTPUT=$(tail -30 "$out")
  fi
  rm -f "$out"
  [ "$rc" -eq 0 ]
}

# scan_secret_diff — scan the ADDED lines of the branch diff for secret-shaped
# content: AWS/Anthropic/GitHub/Slack token formats, PEM private-key headers,
# and quoted key/token/password assignments (12+ chars). Lockfiles excluded
# (integrity hashes false-positive). Returns 0 if a secret is found.
scan_secret_diff() {
  local added
  added=$(git diff "$BASE_BRANCH...$BRANCH" -- . ':(exclude)package-lock.json' ':(exclude)bun.lock' ':(exclude)yarn.lock' 2>/dev/null \
    | grep -E '^\+' | grep -v '^+++')  # BRE literal +++: BSD grep rejects \+\+\+
  [ -n "$added" ] || return 1
  echo "$added" | grep -qE \
    -e 'AKIA[0-9A-Z]{16}' \
    -e 'sk-(ant-)?[A-Za-z0-9_-]{20,}' \
    -e '(ghp|gho|ghu|ghs)_[A-Za-z0-9]{36}' \
    -e 'github_pat_[A-Za-z0-9_]{22,}' \
    -e 'xox[baprs]-[A-Za-z0-9-]{10,}' \
    -e '\-\-\-\-\-BEGIN( RSA| EC| DSA| OPENSSH| PGP)? PRIVATE KEY' && return 0
  echo "$added" | grep -qiE \
    "(api[_-]?key|secret[_-]?key|access[_-]?token|private[_-]?key|password|passwd)[\"']?[[:space:]]*[:=][[:space:]]*[\"'][^\"']{12,}[\"']" && return 0
  return 1
}

# check_gate <gate-text>
# Dispatches a natural-language rule bullet to a framework-recognized check.
# Uses bash glob keyword matching against gate text.
# Returns: 0 = pass, 1 = fail (recognized + violated), 2 = custom (unrecognized).
check_gate() {
  local gate="$1"
  local gate_lower
  gate_lower=$(echo "$gate" | tr '[:upper:]' '[:lower:]')

  # Inline `check: <shell>` suffix takes precedence over keyword matching.
  # Format: bullet text `check: <shell command>`
  # Exit 0 = pass, non-zero = fail. Any bullet with a recognized check: suffix
  # is deterministically verified and never falls through to "custom".
  local inline_check
  inline_check=$(echo "$gate" | grep -oE '`check:[^`]*`' | tail -n1 | sed -E 's/^`check:[[:space:]]*//; s/`$//')
  if [ -n "$inline_check" ]; then
    ( cd "$REPO_DIR" 2>/dev/null || true
      BASE_BRANCH="$BASE_BRANCH" BRANCH="$BRANCH" REPO_DIR="$REPO_DIR" LOGFILE="$LOGFILE" \
        bash -c "$inline_check" >/dev/null 2>&1
    )
    return $?
  fi

  # *credential*/*token* here still shadow the *hardcoded*credential* case
  # below, but harmlessly — both run the same scan_secret_diff content scan;
  # this case just adds the filename check on top.
  # shellcheck disable=SC2221,SC2222
  case "$gate_lower" in
    *secret*|*.env*|*.pem*|*.key*|*credential*|*token*)
      # Filename check: .env anchored (config.envelope.js must not match),
      # .pem/.key by extension, credential-ish names anywhere in the path.
      git diff "$BASE_BRANCH...$BRANCH" --name-only 2>/dev/null \
        | grep -qE '(^|/)\.env(\.|$)|\.(pem|key)$|credentials|secrets|tokens' && return 1
      scan_secret_diff && return 1
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
      # Deterministic: the framework runs the repo's tests itself; the exit
      # code decides. (Replaces the old grep-the-log-for-FAIL heuristic.)
      run_repo_tests || return 1
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
      scan_secret_diff && return 1
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

# run_gate_bullets
# Reads rule-bullet lines on stdin and dispatches each through check_gate.
# Appends verified failures to GATE_FAILURES and forwarded (unrecognized, plain)
# rules to GATE_CUSTOM — both outer-scope. Must be fed via process substitution,
# not a pipe, so it runs in the caller's shell and its writes persist.
run_gate_bullets() {
  local line raw strict gate
  while IFS= read -r line; do
    raw=$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*//' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
    [ -z "$raw" ] && continue
    case "$raw" in \[*\]) continue ;; esac  # skip section header labels
    strict=false
    gate="$raw"
    case "$raw" in
      "!"*) strict=true; gate=$(echo "$raw" | sed -E 's/^![[:space:]]*//') ;;
    esac
    # Dedupe: a category may be declared in more than one stage (e.g. security in
    # test and ship). Checks are deterministic with no state change between stage
    # groups, so gate each unique rule once. (Pure-bash membership; bash 3.2-safe.)
    case $'\n'"$GATE_SEEN"$'\n' in
      *$'\n'"$gate"$'\n'*) continue ;;
    esac
    GATE_SEEN="${GATE_SEEN}${gate}"$'\n'
    check_gate "$gate"
    case "$?" in
      0) if [ "$strict" = true ]; then log "PASS: ! $gate"; else log "PASS: $gate"; fi ;;
      1) if [ "$strict" = true ]; then log "FAIL: ! $gate"; else log "FAIL: $gate"; fi
         GATE_FAILURES="${GATE_FAILURES}\n- $gate"
         # Test gate captures WHY it failed — thread it into the FIX prompt
         if [ -n "${TEST_GATE_OUTPUT:-}" ]; then
           GATE_FAILURES="${GATE_FAILURES}\n  test output (last lines):\n$TEST_GATE_OUTPUT"
           TEST_GATE_OUTPUT=""
         fi ;;
      2) if [ "$strict" = true ]; then
           log "FAIL: ! $gate (strict — framework has no check for this rule)"
           GATE_FAILURES="${GATE_FAILURES}\n- $gate (strict: add a check_gate pattern or drop the !)"
         else
           log "FWD:  $gate"
           GATE_CUSTOM="${GATE_CUSTOM}\n- $gate"
         fi ;;
    esac
  done
}

# run_all_gates <factory.md path>
# Resets the gate accumulators, then gates every rule. If the factory declares a
# v2 `## stages` section, gates run grouped by stage in declared order (prompt
# stages like triage/plan are skipped here). Otherwise every section is gated in
# one flat pass — identical to v1 behavior.
run_all_gates() {
  local file="$1" stages sline sname sval
  GATE_FAILURES=""
  GATE_CUSTOM=""
  GATE_SEEN=""
  stages=$(factory_stages "$file")
  if [ -n "$stages" ]; then
    while IFS= read -r sline; do
      sname="${sline%%:*}"
      sval="${sline#*:}"
      [ "$sval" = "prompt" ] && continue
      log "── gate stage: $sname → $sval"
      run_gate_bullets < <(factory_rules_for_stage "$sval" "$file")
    done <<< "$stages"
  else
    run_gate_bullets < <(factory_rules "$file")
  fi
}
