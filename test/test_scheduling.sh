#!/bin/bash
. "$(dirname "$0")/helpers.sh"

TREE="$TESTDIR/tree"
mkdir -p "$TREE/scheduling"
cp "$DETROIT_ROOT/scheduling/night-shift.sh" "$TREE/scheduling/"
cat > "$TREE/factory.sh" <<EOF
#!/bin/bash
echo "\$DETROIT_AGENT \$*" >> "$TESTDIR/calls"
[ "\$DETROIT_AGENT" = "\${FAIL_AGENT:-}" ] && exit 1
exit 0
EOF

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
assert_contains "$SERVICE" "PATH=@OPENCODE_DIR@:@GROK_DIR@:" "service: pinned opencode and grok first in PATH"
assert_contains "$TIMER" "OnCalendar=*-*-* 01:00:00" "timer: 01:00"
assert_not_contains "$(grep -v '^#' "$DETROIT_ROOT/scheduling/detroit-nightly.timer")" "Persistent=" "timer: no catch-up run at boot"

echo "install.sh:"
cp "$DETROIT_ROOT/scheduling/install.sh" "$DETROIT_ROOT/scheduling/detroit-nightly.service" "$DETROIT_ROOT/scheduling/detroit-nightly.timer" "$TREE/scheduling/"
mkdir -p "$TESTDIR/real/opencode-1.2" "$TESTDIR/real/grok-1.0/node_modules/.bin"
printf '#!/bin/bash\necho 1.2\n' > "$TESTDIR/real/opencode-1.2/opencode"
printf '#!/bin/bash\n' > "$TESTDIR/real/grok-1.0/node_modules/.bin/grok"
chmod +x "$TESTDIR/real/opencode-1.2/opencode" "$TESTDIR/real/grok-1.0/node_modules/.bin/grok"
ln -s "$TESTDIR/real/opencode-1.2" "$TESTDIR/opencode-current"
ln -s "$TESTDIR/real/grok-1.0" "$TESTDIR/grok-current"
stub_bin systemctl 'exit 0'
RC=0
env XDG_CONFIG_HOME="$TESTDIR/config" OPENCODE_DIR="$TESTDIR/opencode-current" GROK_DIR="$TESTDIR/grok-current" \
  bash "$TREE/scheduling/install.sh" >/dev/null 2>&1 || RC=$?
assert_eq 0 "$RC" "install.sh with stubbed systemctl: exit 0"
REAL_OPENCODE=$(cd "$TESTDIR/real/opencode-1.2" && pwd -P)
REAL_GROK=$(cd "$TESTDIR/real/grok-1.0/node_modules/.bin" && pwd -P)
INSTALLED=$(cat "$TESTDIR/config/systemd/user/detroit-nightly.service" 2>/dev/null)
assert_contains "$INSTALLED" "PATH=$REAL_OPENCODE:$REAL_GROK:" "installed service pins the real opencode and grok dirs, not the symlinks"
assert_not_contains "$INSTALLED" "-current" "installed service never pins a symlinked install path"

summarize
