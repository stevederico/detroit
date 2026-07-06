# shellcheck shell=bash
# lib/agent.sh — agent CLI invocation (claude, dotbot, grok).

# ── Agent configuration ───────────────────────────────────
# DETROIT_AGENT: claude (default), dotbot, grok
# DETROIT_PROVIDER: xai (default) — provider for dotbot (xai, anthropic, openai, ollama)
# DETROIT_MODEL: model override for dotbot and grok (grok needs XAI_API_KEY set)
DETROIT_CLI="${DETROIT_AGENT:-claude}"

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
    *)
      log "Unknown agent: $DETROIT_CLI"
      return 1
      ;;
  esac
}
