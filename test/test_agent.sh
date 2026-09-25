#!/bin/bash
# Tests for lib/agent.sh: default CLI and DETROIT_MODEL handling. Stub CLIs
# print the args they got as their agent's stream format.
. "$(dirname "$0")/helpers.sh"

AGENT_ID=0
LOGFILE="$TESTDIR/test.log"; : > "$LOGFILE"
. "$DETROIT_ROOT/lib/core.sh"

stub_bin claude 'printf "{\"type\":\"result\",\"result\":\"claude %s\"}\n" "$*"'
stub_bin grok 'printf "{\"params\":{\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"text\":\"grok %s\"}}}}\n" "$*"'
PROMPT="$TESTDIR/prompt.txt"; echo "hello" > "$PROMPT"

# agent_out <env...> -- run_agent in a fresh shell so DETROIT_CLI is re-read
agent_out() {
  env "$@" bash -c "AGENT_ID=0; LOGFILE='$LOGFILE'; . '$DETROIT_ROOT/lib/core.sh'; . '$DETROIT_ROOT/lib/agent.sh'; run_agent '$PROMPT' --model sonnet"
}

echo "run_agent:"
OUT=$(agent_out -u DETROIT_AGENT -u DETROIT_MODEL)
assert_contains "$OUT" "grok " "grok is the default agent"
assert_not_contains "$OUT" "sonnet" "grok ignores the caller's claude alias"

OUT=$(agent_out -u DETROIT_MODEL DETROIT_AGENT=claude)
assert_contains "$OUT" "claude " "DETROIT_AGENT=claude runs claude"
assert_contains "$OUT" "--model sonnet" "claude keeps the caller's model when DETROIT_MODEL is unset"

OUT=$(agent_out DETROIT_AGENT=claude DETROIT_MODEL=claude-fable-5-1)
assert_contains "$OUT" "--model claude-fable-5-1" "DETROIT_MODEL applies to claude"
assert_not_contains "$OUT" "sonnet" "DETROIT_MODEL replaces the caller's alias"

OUT=$(agent_out DETROIT_AGENT=grok DETROIT_MODEL=grok-4.7-build)
assert_contains "$OUT" "--model grok-4.7-build" "DETROIT_MODEL applies to grok"

summarize
