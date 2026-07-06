#!/bin/bash
# factory.sh — detroit code factory
# Reads next task file from tasks/, ships them as PRs.
# Usage: bash factory.sh [--dry-run] [--issues owner/repo] [--parallel N] [--verify owner/repo [pr]]
#
# Entry point only — the pipeline lives in lib/:
#   core.sh       logging, status files, with_timeout, INT cleanup
#   args.sh       CLI flag parsing
#   factory-md.sh factory.md section/stage/rule parsing
#   gates.sh      deterministic rule gates
#   agent.sh      agent CLI invocation (claude, dotbot, grok)
#   devserver.sh  dev server + test-account helpers
#   modes.sh      --parallel and --issues modes
#   verify-prs.sh --verify mode
#   pipeline.sh   PICK → ROUTE → PREPARE → SCAFFOLD → TRIAGE → PLAN → CODE → GATES → FIX → SHIP
#   postship.sh   CI → VERIFY → UPDATE → DONE

set -u -o pipefail  # no -e: pipeline control flow inspects failures explicitly

DETROIT="${DETROIT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
TASK_DIR="$DETROIT/tasks"
DONE_DIR="$TASK_DIR/done"
LOCK_DIR="$TASK_DIR/.locks"
PROJECTS="${DETROIT_PROJECTS:-$(dirname "$DETROIT")}"
LOGDIR="$DETROIT/logs"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")

STATUS_DIR="$DETROIT/.status"
mkdir -p "$LOGDIR" "$DONE_DIR" "$LOCK_DIR" "$STATUS_DIR"
AGENT_ID="${DETROIT_AGENT_ID:-0}"
LOGFILE="$LOGDIR/$TIMESTAMP-w$AGENT_ID.log"
WORKTREE_DIR=""
MAIN_REPO_DIR=""
TASK_FILE=""
# Force headless browser for all agent-browser calls
export AGENT_BROWSER_HEADED=""

# Shared function libraries (definitions only — no side effects on source)
. "$DETROIT/lib/core.sh"
. "$DETROIT/lib/args.sh"
. "$DETROIT/lib/factory-md.sh"
. "$DETROIT/lib/gates.sh"
. "$DETROIT/lib/agent.sh"
. "$DETROIT/lib/devserver.sh"
. "$DETROIT/lib/modes.sh"
. "$DETROIT/lib/verify-prs.sh"
. "$DETROIT/lib/pipeline.sh"
. "$DETROIT/lib/postship.sh"

parse_args "$@" || exit 2

# Ctrl+C cleanup (cleanup() defined in lib/core.sh)
trap cleanup INT

case "$MODE" in
  help)     usage; exit 0 ;;
  parallel) mode_parallel ;;
  verify)   mode_verify ;;
  issues)   mode_issues ;;
  run)
    run_pipeline
    run_postship  # its final check is the factory run's exit code
    ;;
esac
