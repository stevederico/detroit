#!/bin/bash
# Tests for lib/agent.sh: default CLI, DETROIT_MODEL handling, and the local
# model preflight. Stub CLIs print the args they got as their agent's stream
# format. curl is stubbed: no test reaches a real endpoint.
. "$(dirname "$0")/helpers.sh"

AGENT_ID=0
LOGFILE="$TESTDIR/test.log"; : > "$LOGFILE"
. "$DETROIT_ROOT/lib/core.sh"

stub_bin claude 'printf "{\"type\":\"result\",\"result\":\"claude %s\"}\n" "$*"'
stub_bin grok 'printf "{\"params\":{\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"text\":\"grok %s\"}}}}\n" "$*"'
# opencode: a wrapper banner, a tool call, a text part carrying the args, an error
stub_bin opencode 'echo "mise ~/.config/mise/config.toml tools: opencode"
printf "{\"type\":\"tool_use\",\"part\":{\"tool\":\"bash\",\"state\":{\"input\":{\"command\":\"npm test\"}}}}\n"
printf "{\"type\":\"tool_use\",\"part\":{\"tool\":\"read\",\"state\":{\"input\":{\"filePath\":\"/repo/a.md\"}}}}\n"
printf "{\"type\":\"text\",\"part\":{\"type\":\"text\",\"text\":\"opencode %s\"}}\n" "$*"
printf "{\"type\":\"error\",\"error\":{\"name\":\"UnknownError\",\"data\":{\"message\":\"server fell over\"}}}\n"'
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

OUT=$(agent_out -u DETROIT_MODEL DETROIT_AGENT=opencode)
assert_contains "$OUT" "opencode run --auto --format json" "DETROIT_AGENT=opencode runs opencode headless"
assert_contains "$OUT" "-m studio/mlx-community/Qwen3-Coder-Next-4bit" "opencode defaults to the local Studio model"
assert_contains "$OUT" "-- hello" "opencode gets the prompt after --"
assert_not_contains "$OUT" "sonnet" "opencode ignores the caller's claude alias"
assert_not_contains "$OUT" "mise" "non-JSON lines are dropped"
assert_contains "$OUT" "  Running: npm test" "opencode bash tool call shown"
assert_contains "$OUT" "  Reading /repo/a.md" "opencode read tool call shown"
assert_contains "$OUT" "opencode error: server fell over" "opencode error event shown"

OUT=$(agent_out DETROIT_AGENT=opencode DETROIT_MODEL=studio-ollama/nemotron3:33b-64k)
assert_contains "$OUT" "-m studio-ollama/nemotron3:33b-64k" "DETROIT_MODEL applies to opencode"

stub_bin opencode 'exec sleep 30'
T0=$SECONDS
OUT=$(env DETROIT_AGENT=opencode bash -c "AGENT_ID=0; LOGFILE='$LOGFILE'; . '$DETROIT_ROOT/lib/core.sh'; . '$DETROIT_ROOT/lib/agent.sh'; run_agent '$PROMPT' --timeout 1 --timeout-msg 'too slow'")
assert_contains "$OUT" "too slow" "opencode honors --timeout"
assert_eq "true" "$([ $((SECONDS - T0)) -lt 10 ] && echo true)" "timed-out opencode call returns"

echo "agent_preflight:"
# preflight <env...> -- agent_preflight in a fresh shell; prints the log lines
preflight() {
  env "$@" bash -c "AGENT_ID=0; LOGFILE='$LOGFILE'; . '$DETROIT_ROOT/lib/core.sh'; . '$DETROIT_ROOT/lib/agent.sh'; agent_preflight"
}
stub_bin curl "echo \"\$*\" >> '$TESTDIR/curls'; exit 7"
assert_rc 0 "grok (default) has no preflight" preflight -u DETROIT_AGENT
assert_rc 0 "claude has no preflight" preflight DETROIT_AGENT=claude
assert_eq "false" "$([ -f "$TESTDIR/curls" ] && echo true || echo false)" "other agents never call the endpoint"
OUT=$(preflight -u DETROIT_MODEL_ENDPOINT DETROIT_AGENT=opencode); RC=$?
assert_eq 1 "$RC" "opencode + endpoint down: fails"
assert_contains "$OUT" "Model endpoint down: http://127.0.0.1:8090/v1/models" "endpoint down is logged with the URL"
assert_contains "$(cat "$TESTDIR/curls")" "http://127.0.0.1:8090/v1/models" "default endpoint is the Studio tunnel"
assert_rc 0 "DETROIT_MODEL_ENDPOINT=none skips the check" preflight DETROIT_AGENT=opencode DETROIT_MODEL_ENDPOINT=none
stub_bin curl "echo \"\$*\" >> '$TESTDIR/curls'; exit 0"
assert_rc 0 "opencode + endpoint up: passes" preflight DETROIT_AGENT=opencode DETROIT_MODEL_ENDPOINT=http://10.0.0.5:9000/v1/
assert_contains "$(cat "$TESTDIR/curls")" "http://10.0.0.5:9000/v1/models" "DETROIT_MODEL_ENDPOINT honored"

echo "factory.sh preflight:"
# Real entry point against a copied tree: endpoint down stops a run before PICK
mkdir -p "$TESTDIR/tree/tasks"
cp -R "$DETROIT_ROOT/factory.sh" "$DETROIT_ROOT/lib" "$TESTDIR/tree/"
echo "task" > "$TESTDIR/tree/tasks/a.md"
stub_bin curl 'exit 7'
OUT=$(DETROIT_AGENT=opencode DETROIT_DIR="$TESTDIR/tree" bash "$TESTDIR/tree/factory.sh" 2>&1); RC=$?
assert_eq 0 "$RC" "endpoint down: exit 0"
assert_contains "$OUT" "Model endpoint down" "endpoint down: logged"
assert_not_contains "$OUT" "PICK" "endpoint down: pipeline never picks"
assert_eq "true" "$([ -f "$TESTDIR/tree/tasks/a.md" ] && echo true)" "endpoint down: task left in place"

summarize
