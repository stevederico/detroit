# shellcheck shell=bash

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

check_gate() {
  local gate="$1"
  local gate_lower
  gate_lower=$(echo "$gate" | tr '[:upper:]' '[:lower:]')

  local inline_check
  inline_check=$(echo "$gate" | grep -oE '`check:[^`]*`' | tail -n1 | sed -E 's/^`check:[[:space:]]*//; s/`$//')
  if [ -n "$inline_check" ]; then
    ( cd "$REPO_DIR" 2>/dev/null || true
      BASE_BRANCH="$BASE_BRANCH" BRANCH="$BRANCH" REPO_DIR="$REPO_DIR" LOGFILE="$LOGFILE" \
        bash -c "$inline_check" >/dev/null 2>&1
    )
    return $?
  fi

  # shellcheck disable=SC2221,SC2222
  case "$gate_lower" in
    *secret*|*.env*|*.pem*|*.key*|*credential*|*token*)
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

run_gate_bullets() {
  local line raw strict gate
  while IFS= read -r line; do
    raw=$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*//' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
    [ -z "$raw" ] && continue
    case "$raw" in \[*\]) continue ;; esac
    strict=false
    gate="$raw"
    case "$raw" in
      "!"*) strict=true; gate=$(echo "$raw" | sed -E 's/^![[:space:]]*//') ;;
    esac
    case $'\n'"$GATE_SEEN"$'\n' in
      *$'\n'"$gate"$'\n'*) continue ;;
    esac
    GATE_SEEN="${GATE_SEEN}${gate}"$'\n'
    check_gate "$gate"
    case "$?" in
      0) if [ "$strict" = true ]; then log "PASS: ! $gate"; else log "PASS: $gate"; fi ;;
      1) if [ "$strict" = true ]; then log "FAIL: ! $gate"; else log "FAIL: $gate"; fi
         GATE_FAILURES="${GATE_FAILURES}\n- $gate"
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
