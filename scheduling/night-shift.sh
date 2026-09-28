#!/bin/bash
# scheduling/night-shift.sh — the nightly shifts, one agent after another.
# DETROIT_NIGHT_AGENTS (default "grok opencode") lists the agents in order.
# Subscription agents go first: whatever their usage window has left goes to
# the queue before it resets. The local model then takes what is still
# queued. Each entry is a normal `factory.sh --shift`: a subscription shift
# stops at DETROIT_BUDGET_STOP, a local one at DETROIT_SHIFT_MAX_HOURS, and
# both stop on an empty queue. One failed shift never skips the next.
# Exit code: the number of shifts that failed (2 for an unknown agent).
set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS="${DETROIT_NIGHT_AGENTS:-grok opencode}"
# A typo stops the night before any shift, not halfway through it
for agent in $AGENTS; do
  case "$agent" in
    grok|claude|dotbot|opencode) ;;
    *) echo "[$(date +%H:%M:%S)] night shift: unknown agent '$agent' in DETROIT_NIGHT_AGENTS" >&2; exit 2 ;;
  esac
done
failed=0
for agent in $AGENTS; do
  echo "[$(date +%H:%M:%S)] night shift: $agent"
  DETROIT_AGENT="$agent" bash "$ROOT/factory.sh" --shift || failed=$((failed + 1))
done
exit "$failed"
