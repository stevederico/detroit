#!/bin/bash
set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS="${DETROIT_NIGHT_AGENTS:-grok opencode}"
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
