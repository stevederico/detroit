#!/bin/bash
# Tests for scheduling/: night-shift.sh order and exit codes against a fake
# factory.sh, and the unit files' key settings. Never touches systemd.
. "$(dirname "$0")/helpers.sh"

TREE="$TESTDIR/tree"
mkdir -p "$TREE/scheduling"
cp "$DETROIT_ROOT/scheduling/night-shift.sh" "$TREE/scheduling/"
# Fake factory.sh: records "<agent> <args>", fails when FAIL_AGENT matches
cat > "$TREE/factory.sh" <<EOF
#!/bin/bash
echo "\$DETROIT_AGENT \$*" >> "$TESTDIR/calls"
[ "\$DETROIT_AGENT" = "\${FAIL_AGENT:-}" ] && exit 1
exit 0
EOF

# night <env...> — run night-shift.sh with a fresh call log; sets RC and CALLS
night() {
  rm -f "$TESTDIR/calls"
  RC=0
  env "$@" bash "$TREE/scheduling/night-shift.sh" >/dev/null 2>&1 || RC=$?
  CALLS=""
  [ -f "$TESTDIR/calls" ] && CALLS=$(tr '\n' ',' < "$TESTDIR/calls" | sed 's/,$//')
}

echo "night-shift.sh:"
night -u DETROIT_NIGHT_AGENTS
assert_eq 0 "$RC" "default: exit 0"
assert_eq "grok --shift,opencode --shift" "$CALLS" "default: grok shift first, then opencode"

night DETROIT_NIGHT_AGENTS="claude grok opencode"
assert_eq "claude --shift,grok --shift,opencode --shift" "$CALLS" "DETROIT_NIGHT_AGENTS sets the order"

night DETROIT_NIGHT_AGENTS=opencode
assert_eq "opencode --shift" "$CALLS" "one agent: one shift"

night DETROIT_NIGHT_AGENTS="grok opencode" FAIL_AGENT=grok
assert_eq "grok --shift,opencode --shift" "$CALLS" "a failed shift never skips the next"
assert_eq 1 "$RC" "exit code counts failed shifts"

night DETROIT_NIGHT_AGENTS="grok gpt5 opencode"
assert_eq 2 "$RC" "unknown agent: exit 2"
assert_eq "" "$CALLS" "unknown agent: no shift runs"

echo "unit files:"
SERVICE=$(cat "$DETROIT_ROOT/scheduling/detroit-nightly.service")
TIMER=$(cat "$DETROIT_ROOT/scheduling/detroit-nightly.timer")
assert_contains "$SERVICE" "scheduling/night-shift.sh" "service runs night-shift.sh"
assert_contains "$SERVICE" "DETROIT_NIGHT_AGENTS=grok opencode" "service: subscription first, local last"
assert_contains "$SERVICE" "PATH=@OPENCODE_DIR@:" "service: pinned opencode first in PATH"
assert_contains "$TIMER" "OnCalendar=*-*-* 01:00:00" "timer: 01:00"
assert_not_contains "$(grep -v '^#' "$DETROIT_ROOT/scheduling/detroit-nightly.timer")" "Persistent=" "timer: no catch-up run at boot"

summarize
