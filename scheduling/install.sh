#!/bin/bash
# scheduling/install.sh — install the nightly shift as a systemd user timer.
# Copies detroit-nightly.service and .timer into ~/.config/systemd/user with
# the paths pointed at this checkout, then enables the timer. Safe to re-run.
# Usage: bash scheduling/install.sh [--uninstall]
#
# opencode and grok are pinned: the service's PATH starts with the
# directories of their real binaries, so a `mise use -g` wrapper never runs
# (or upgrades them) during a shift. A grok upgrade changed its stream format
# once already. OPENCODE_DIR / GROK_DIR override; otherwise `mise where`.
# Grok is optional: without it the grok shift uses whatever grok is on PATH.
# Re-run after upgrading either on purpose.
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

OPENCODE_DIR="${OPENCODE_DIR:-$(mise where opencode 2>/dev/null)}"
# Resolve symlinks (mise's latest -> 1.18.32) so an upgrade can't move the pin
OPENCODE_DIR=$(cd "$OPENCODE_DIR" 2>/dev/null && pwd -P)
if [ -z "$OPENCODE_DIR" ] || [ ! -x "$OPENCODE_DIR/opencode" ]; then
  echo "error: no opencode binary at '${OPENCODE_DIR}/opencode'; set OPENCODE_DIR to its directory" >&2
  exit 1
fi
case "$OPENCODE_DIR" in
  *[[:space:]%:]*) echo "error: opencode path has a space, % or colon: $OPENCODE_DIR" >&2; exit 1 ;;
esac
echo "opencode pinned: $OPENCODE_DIR ($("$OPENCODE_DIR/opencode" --version 2>/dev/null))"

GROK_DIR="${GROK_DIR:-$(mise where npm:@xai-official/grok 2>/dev/null)}"
GROK_DIR=$(cd "$GROK_DIR/node_modules/.bin" 2>/dev/null && pwd -P)
case "$GROK_DIR" in
  *[[:space:]%:]*) echo "error: grok path has a space, % or colon: $GROK_DIR" >&2; exit 1 ;;
esac
if [ -n "$GROK_DIR" ] && [ -x "$GROK_DIR/grok" ]; then
  echo "grok pinned: $GROK_DIR"
else
  echo "warning: no grok install found to pin; the grok shift uses grok from PATH" >&2
  GROK_DIR="$ROOT/scheduling"   # harmless PATH entry (no grok binary there)
fi

mkdir -p "$UNIT_DIR" "$ROOT/logs" || exit 1
for u in $UNITS; do
  sed -e "s|%h/Projects/detroit|$ROOT|g" -e "s|@OPENCODE_DIR@|$OPENCODE_DIR|g" \
      -e "s|@GROK_DIR@|$GROK_DIR|g" "$HERE/$u" > "$UNIT_DIR/$u" || exit 1
done
systemctl --user daemon-reload || exit 1
systemctl --user enable --now detroit-nightly.timer || exit 1
systemctl --user list-timers detroit-nightly.timer --no-pager
