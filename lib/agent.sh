# shellcheck shell=bash
# lib/agent.sh — agent CLI invocation (claude, dotbot, grok, opencode).

# ── Agent configuration ───────────────────────────────────
# DETROIT_AGENT: grok (default), claude, dotbot, opencode
# DETROIT_PROVIDER: xai (default) — provider for dotbot (xai, anthropic, openai, ollama)
# DETROIT_MODEL: model for every call. For claude it
#   replaces the caller's --model alias, so --shift checks the budget it spends.
#   For opencode it is provider/model (default: the local Studio model below).
# DETROIT_MODEL_ENDPOINT: OpenAI-style base URL agent_preflight checks for
#   opencode (default http://127.0.0.1:8090/v1); "none" skips the check.
# DETROIT_PREFLIGHT_TIMEOUT: seconds for each agent_preflight call (default 10).
DETROIT_CLI="${DETROIT_AGENT:-grok}"
OPENCODE_DEFAULT_MODEL="studio/mlx-community/Qwen3-Coder-Next-4bit"
OPENCODE_DEFAULT_ENDPOINT="http://127.0.0.1:8090/v1"

# agent_is_local — true when the agent runs on a local model: no usage window
# to budget against (lib/shift.sh), and an endpoint that can be down.
agent_is_local() { [ "${DETROIT_AGENT:-grok}" = opencode ]; }

# agent_preflight — true when a task can start. Checks, in order:
#   1. gh has a token (`gh auth token`). SHIP opens the PR with it. All agents.
#   2. opencode only: GET <endpoint>/models answers, and its data[].id list
#      has the model id from DETROIT_MODEL (the part after provider/). An MLX
#      server asked for a model it is not serving tries to load that model.
# Each call is cut off after DETROIT_PREFLIGHT_TIMEOUT. On failure logs why,
# sets PREFLIGHT_REASON ("gh not authenticated", "model endpoint down",
# "model not served") and returns 1.
# shellcheck disable=SC2034  # PREFLIGHT_REASON is read by factory.sh and lib/shift.sh
agent_preflight() {
  local t="${DETROIT_PREFLIGHT_TIMEOUT:-10}" endpoint url model body rc=0
  PREFLIGHT_REASON=""
  if ! with_timeout "$t" gh auth token >/dev/null 2>&1; then
    PREFLIGHT_REASON="gh not authenticated"
    log "gh not authenticated: 'gh auth token' failed (run gh auth login)"
    return 1
  fi
  agent_is_local || return 0
  endpoint="${DETROIT_MODEL_ENDPOINT:-$OPENCODE_DEFAULT_ENDPOINT}"
  [ "$endpoint" = none ] && return 0
  url="${endpoint%/}/models"
  model="${DETROIT_MODEL:-$OPENCODE_DEFAULT_MODEL}"
  model="${model#*/}"
  # -sS: stdout is the body on success, stderr the error on failure
  body=$(curl -fsS -m "$t" "$url" 2>&1) || rc=$?
  if [ "$rc" != 0 ]; then
    PREFLIGHT_REASON="model endpoint down"
    log "Model endpoint down: $url (curl rc=$rc${body:+, $body})"
    return 1
  fi
  if ! printf '%s' "$body" | MODEL_ID="$model" python3 -c '
import json, os, sys
try:
    ids = [m.get("id") for m in json.load(sys.stdin).get("data", []) if isinstance(m, dict)]
except Exception:
    sys.exit(1)
sys.exit(0 if os.environ["MODEL_ID"] in ids else 1)'; then
    PREFLIGHT_REASON="model not served"
    log "Model not served: $model is not in $url"
    return 1
  fi
  return 0
}

# run_agent <prompt_file> [--model <model>] [--timeout <secs>] [--timeout-msg <msg>] [--verbose]
# Runs the configured agent CLI and streams parsed output to stdout. The
# parsers read the timeout from AGENT_TIMEOUT / AGENT_TIMEOUT_MSG (env, so a
# quote in the message cannot break the Python). A --timeout that is not a
# whole number of seconds is logged and treated as none.
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

  case "$timeout_secs" in
    ""|*[!0-9]*)
      log "run_agent: --timeout '$timeout_secs' is not whole seconds; running without a timeout"
      timeout_secs=0 ;;
  esac
  local -x AGENT_TIMEOUT="$timeout_secs" AGENT_TIMEOUT_MSG="$timeout_msg"

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
import os, sys, json, signal
timeout = int(os.environ['AGENT_TIMEOUT'])
if timeout > 0:
    signal.signal(signal.SIGALRM, lambda *_: (print(os.environ['AGENT_TIMEOUT_MSG'], flush=True), sys.exit(0)))
    signal.alarm(timeout)
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

      if [ "$timeout_secs" -gt 0 ]; then
        dotbot "$prompt" "${args[@]}" 2>/dev/null | \
          python3 -uc "
import os, sys, signal
signal.signal(signal.SIGALRM, lambda *_: (print(os.environ['AGENT_TIMEOUT_MSG'], flush=True), sys.exit(0)))
signal.alarm(int(os.environ['AGENT_TIMEOUT']))
for line in sys.stdin:
    print(line.rstrip(), flush=True)
"
      else
        dotbot "$prompt" "${args[@]}" 2>/dev/null
      fi
      ;;
    grok)
      # Official xAI Grok CLI (`grok`). Signs in with the subscription
      # (~/.grok/auth.json) or XAI_API_KEY. Like dotbot, ignores the caller's
      # --model alias (claude-specific) and honors DETROIT_MODEL.
      # Docs: https://docs.x.ai/build/cli/headless-scripting
      # Stream formats: 1.0.40 sends {"type":"text","data":...} chunks a few
      # words at a time and {"type":"tool_call",...} per tool; older CLIs sent
      # params.update agent_message_chunk. Both are parsed.
      local -a args=(--no-auto-update -p "$prompt" --output-format streaming-json)
      [ -n "${DETROIT_MODEL:-}" ] && args+=(--model "$DETROIT_MODEL")

      grok "${args[@]}" 2>/dev/null | \
        python3 -uc "
import os, sys, json, signal
timeout = int(os.environ['AGENT_TIMEOUT'])
if timeout > 0:
    signal.signal(signal.SIGALRM, lambda *_: (print(os.environ['AGENT_TIMEOUT_MSG'], flush=True), sys.exit(0)))
    signal.alarm(timeout)
mid_line = False
def text(chunk):
    global mid_line
    if not chunk: return
    print(chunk, end='', flush=True)
    mid_line = not chunk.endswith('\\n')
def line(msg):
    global mid_line
    if mid_line: print('', flush=True)
    print(msg.rstrip(), flush=True)
    mid_line = False
def tool(name, inp):
    path = inp.get('target_file') or inp.get('file_path') or inp.get('path') or '?'
    if name == 'read_file': line(f'  Reading {path}')
    elif name in ('search_replace', 'edit_file'): line(f'  Editing {path}')
    elif name == 'write_file': line(f'  Writing {path}')
    elif name == 'run_terminal_command': line(f'  Running: {str(inp.get(\"command\", \"\"))[:120]}')
    elif name == 'grep': line(f'  Searching: {inp.get(\"pattern\") or inp.get(\"query\") or \"?\"}')
    elif name == 'list_dir': line(f'  Listing {path}')
    else: line(f'  Tool: {name}')
for raw in sys.stdin:
    raw = raw.strip()
    if not raw: continue
    try: event = json.loads(raw)
    except: continue
    if not isinstance(event, dict): continue
    etype = event.get('type', '')
    if etype == 'text':
        text(event.get('data') or '')
    elif etype == 'tool_call':
        tool(event.get('toolName') or event.get('title') or '', event.get('rawInput') or {})
    elif etype == 'error':
        line(f'grok error: {event.get(\"message\") or event.get(\"error\") or \"unknown\"}')
    else:
        update = (event.get('params') or {}).get('update') or {}
        if isinstance(update, dict) and update.get('sessionUpdate') == 'agent_message_chunk':
            content = update.get('content') or {}
            text(content.get('text', '') if isinstance(content, dict) else '')
if mid_line: print('', flush=True)
"
      ;;
    opencode)
      # opencode headless (`opencode run`). Like grok, ignores the caller's
      # --model alias (claude-specific) and honors DETROIT_MODEL. --auto
      # approves every permission that is not explicitly denied. Lines that
      # are not JSON events (the mise wrapper's banner) are dropped.
      local -a args=(opencode run --auto --format json -m "${DETROIT_MODEL:-$OPENCODE_DEFAULT_MODEL}")
      # The parser's alarm only ends the read. A local model that has gone
      # quiet never hits the closed pipe, so the CLI and every process it
      # started (tool commands run in their own sessions) are cut off too.
      if [ "$timeout_secs" -gt 0 ]; then
        args=(with_timeout "$((timeout_secs + 2))" "${args[@]}")
      fi

      "${args[@]}" -- "$prompt" 2>/dev/null | \
        python3 -uc "
import os, sys, json, signal
timeout = int(os.environ['AGENT_TIMEOUT'])
if timeout > 0:
    signal.signal(signal.SIGALRM, lambda *_: (print(os.environ['AGENT_TIMEOUT_MSG'], flush=True), sys.exit(0)))
    signal.alarm(timeout)
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
