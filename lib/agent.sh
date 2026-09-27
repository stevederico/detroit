# shellcheck shell=bash
# lib/agent.sh — agent CLI invocation (claude, dotbot, grok, opencode).

# ── Agent configuration ───────────────────────────────────
# DETROIT_AGENT: grok (default), claude, dotbot, opencode
# DETROIT_PROVIDER: xai (default) — provider for dotbot (xai, anthropic, openai, ollama)
# DETROIT_MODEL: model for every call (grok needs XAI_API_KEY set). For claude it
#   replaces the caller's --model alias, so --shift checks the budget it spends.
#   For opencode it is provider/model (default: the local Studio model below).
# DETROIT_MODEL_ENDPOINT: OpenAI-style base URL agent_preflight checks for
#   opencode (default http://127.0.0.1:8090/v1); "none" skips the check.
DETROIT_CLI="${DETROIT_AGENT:-grok}"
OPENCODE_DEFAULT_MODEL="studio/mlx-community/Qwen3-Coder-Next-4bit"
OPENCODE_DEFAULT_ENDPOINT="http://127.0.0.1:8090/v1"

# agent_is_local — true when the agent runs on a local model: no usage window
# to budget against (lib/shift.sh), and an endpoint that can be down.
agent_is_local() { [ "${DETROIT_AGENT:-grok}" = opencode ]; }

# agent_preflight — true when the agent's model can be reached. Only opencode
# has a check: GET <endpoint>/models, cut off after DETROIT_PREFLIGHT_TIMEOUT
# (10s). On failure logs the endpoint and curl's error and returns 1.
agent_preflight() {
  agent_is_local || return 0
  local endpoint="${DETROIT_MODEL_ENDPOINT:-$OPENCODE_DEFAULT_ENDPOINT}" err rc=0
  [ "$endpoint" = none ] && return 0
  err=$(curl -fsS -o /dev/null -m "${DETROIT_PREFLIGHT_TIMEOUT:-10}" "${endpoint%/}/models" 2>&1) || rc=$?
  [ "$rc" = 0 ] && return 0
  log "Model endpoint down: ${endpoint%/}/models (curl rc=$rc${err:+, $err})"
  return 1
}

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

  case "$DETROIT_CLI" in
    claude)
      local -a args=(-p "$prompt" --dangerously-skip-permissions --output-format stream-json)
      [ -n "${DETROIT_MODEL:-}" ] && model="$DETROIT_MODEL"
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
      local -a args=(--provider "${DETROIT_PROVIDER:-xai}")
      [ -n "${DETROIT_MODEL:-}" ] && args+=(--model "$DETROIT_MODEL")

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
    grok)
      # Official xAI Grok CLI (`grok`). Needs XAI_API_KEY. Like dotbot, ignores
      # the caller's --model alias (claude-specific) and honors DETROIT_MODEL.
      # Docs: https://docs.x.ai/build/cli/headless-scripting
      local -a args=(--no-auto-update -p "$prompt" --output-format streaming-json)
      [ -n "${DETROIT_MODEL:-}" ] && args+=(--model "$DETROIT_MODEL")

      grok "${args[@]}" 2>/dev/null | \
        python3 -uc "
import sys, json, signal
timeout = $timeout_secs
tmsg = '''$timeout_msg'''
if timeout > 0:
    signal.alarm(timeout)
    signal.signal(signal.SIGALRM, lambda *_: (print(tmsg, flush=True), sys.exit(0)))
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: event = json.loads(line)
    except: continue
    update = event.get('params', {}).get('update', {})
    if not isinstance(update, dict): continue
    if update.get('sessionUpdate') == 'agent_message_chunk':
        content = update.get('content', {})
        text = content.get('text', '') if isinstance(content, dict) else ''
        if text: print(text, end='', flush=True)
print('', flush=True)
"
      ;;
    opencode)
      # opencode headless (`opencode run`). Like grok, ignores the caller's
      # --model alias (claude-specific) and honors DETROIT_MODEL. --auto
      # approves every permission that is not explicitly denied. Lines that
      # are not JSON events (the mise wrapper's banner) are dropped.
      local -a args=(opencode run --auto --format json -m "${DETROIT_MODEL:-$OPENCODE_DEFAULT_MODEL}")
      # The parser's alarm only ends the read. A local model that has gone
      # quiet never hits the closed pipe, so the CLI itself is cut off too.
      if [ "$timeout_secs" -gt 0 ] 2>/dev/null; then
        args=(with_timeout "$((timeout_secs + 2))" "${args[@]}")
      fi

      "${args[@]}" -- "$prompt" 2>/dev/null | \
        python3 -uc "
import sys, json, signal
timeout = $timeout_secs
tmsg = '''$timeout_msg'''
if timeout > 0:
    signal.alarm(timeout)
    signal.signal(signal.SIGALRM, lambda *_: (print(tmsg, flush=True), sys.exit(0)))
labels = {'read': 'Reading', 'edit': 'Editing', 'write': 'Writing'}
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: event = json.loads(line)
    except: continue
    if not isinstance(event, dict): continue
    etype = event.get('type', '')
    part = event.get('part') or {}
    if etype == 'text':
        text = part.get('text', '').strip()
        if text: print(text, flush=True)
    elif etype == 'tool_use':
        name = part.get('tool', '')
        inp = (part.get('state') or {}).get('input') or {}
        if name in labels: print(f'  {labels[name]} {inp.get(\"filePath\", \"?\")}'.rstrip(), flush=True)
        elif name == 'bash': print(f'  Running: {inp.get(\"command\", \"\")[:120]}'.rstrip(), flush=True)
        elif name == 'grep': print(f'  Searching: {inp.get(\"pattern\", \"?\")}'.rstrip(), flush=True)
        elif name == 'glob': print(f'  Finding: {inp.get(\"pattern\", \"?\")}'.rstrip(), flush=True)
        else: print(f'  Tool: {name}'.rstrip(), flush=True)
    elif etype == 'error':
        err = event.get('error') or {}
        msg = (err.get('data') or {}).get('message') or err.get('name') or 'unknown'
        print(f'opencode error: {msg}', flush=True)
"
      ;;
    *)
      log "Unknown agent: $DETROIT_CLI"
      return 1
      ;;
  esac
}
