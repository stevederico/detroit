# shellcheck shell=bash
# lib/gates.sh — deterministic rule gates.
# check_gate reads outer-scope: BASE_BRANCH, BRANCH, REPO_DIR, PRE_VERSION, LOGFILE.
# run_gate_bullets / run_all_gates accumulate into GATE_FAILURES, GATE_CUSTOM, GATE_SEEN.

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

  # yagni: *credential*/*token* in the first case shadow the content-scanning
  # case below, so bullets like "No hardcoded credentials" only get the filename
  # check — fixed when both cases merge into one diff-content secret scan.
  # shellcheck disable=SC2221,SC2222
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
         GATE_FAILURES="${GATE_FAILURES}\n- $gate" ;;
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
