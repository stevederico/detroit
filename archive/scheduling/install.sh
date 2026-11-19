#!/bin/bash
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
  GROK_DIR="$ROOT/scheduling"
fi

mkdir -p "$UNIT_DIR" "$ROOT/logs" || exit 1
for u in $UNITS; do
  sed -e "s|%h/Projects/detroit|$ROOT|g" -e "s|@OPENCODE_DIR@|$OPENCODE_DIR|g" \
      -e "s|@GROK_DIR@|$GROK_DIR|g" "$HERE/$u" > "$UNIT_DIR/$u" || exit 1
done
systemctl --user daemon-reload || exit 1
systemctl --user enable --now detroit-nightly.timer || exit 1
systemctl --user list-timers detroit-nightly.timer --no-pager
