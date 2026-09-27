#!/bin/bash
# scheduling/install.sh — install the nightly shift as a systemd user timer.
# Copies detroit-nightly.service and .timer into ~/.config/systemd/user with
# the paths pointed at this checkout, then enables the timer. Safe to re-run.
# Usage: bash scheduling/install.sh [--uninstall]
set -u -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNITS="detroit-nightly.service detroit-nightly.timer"

if [ "${1:-}" = --uninstall ]; then
  systemctl --user disable --now detroit-nightly.timer
  for u in $UNITS; do rm -f "$UNIT_DIR/$u"; done
  systemctl --user daemon-reload
  echo "Removed detroit-nightly from $UNIT_DIR"
  exit 0
fi

case "$ROOT" in
  *[[:space:]%]*) echo "error: checkout path has a space or %: $ROOT" >&2; exit 1 ;;
esac

mkdir -p "$UNIT_DIR" "$ROOT/logs" || exit 1
for u in $UNITS; do
  sed "s|%h/Projects/detroit|$ROOT|g" "$HERE/$u" > "$UNIT_DIR/$u" || exit 1
done
systemctl --user daemon-reload || exit 1
systemctl --user enable --now detroit-nightly.timer || exit 1
systemctl --user list-timers detroit-nightly.timer --no-pager
