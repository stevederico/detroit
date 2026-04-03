#!/bin/bash
# Simulated factory.sh run for demo recording
# Matches real factory.sh output format exactly

TASK_DIR="$(cd "$(dirname "$0")" && pwd)/tasks"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")

log() { echo "$1"; }
stage() { echo ""; log "━━━ $1 ━━━"; }

# ── 1/12 PICK
stage "PICK"
sleep 0.2
log "Reading tasks from $TASK_DIR"
sleep 0.2
log "Task: 01-add-dark-mode"
log "Repo: skateboard"

# ── 2/12 ROUTE
stage "ROUTE"
sleep 0.2
log "Repo: skateboard (/Users/me/Desktop/projects/skateboard)"

# ── 3/12 PULL
stage "PULL"
sleep 0.2
log "Base branch: master"
sleep 0.1
echo "Already up to date."

# ── BRANCH
stage "BRANCH"
sleep 0.2
echo "Preparing worktree (new branch 'shipyard/01-add-dark-mode')"
sleep 0.1
log "Branch: shipyard/01-add-dark-mode"

# ── CODE + TEST (agent session)
stage "CODE"
sleep 0.2
log "Ctrl+C to cancel. Monitor: tail -f logs/$TIMESTAMP-w0.log"
sleep 0.8
echo "Reading project structure and task requirements..."
sleep 0.6
echo "Creating ThemeContext with system preference detection..."
sleep 0.7
echo "Adding DarkModeToggle component to SettingsView..."
sleep 0.6
echo "Updating tailwind.config.js for dark mode class strategy..."
sleep 0.5
echo "Writing tests for theme persistence and system preference..."
sleep 0.7
echo "Running tests... 14 passed, 0 failed"
sleep 0.4
echo "Updating CHANGELOG.md"
sleep 0.3
echo "Bumping version 0.2.0 → 0.3.0"
sleep 0.3
echo "Committing: 0.3.0 Add dark mode toggle"
sleep 0.3
echo "Pushing to origin/shipyard/01-add-dark-mode..."
sleep 0.5
echo "Creating pull request..."
sleep 0.4
echo "https://github.com/stevederico/skateboard/pull/47"
sleep 0.2
echo "FACTORY_RESULT:SUCCESS"
sleep 0.2
log "Agent session completed in 142s"

# ── LINT
stage "LINT"
sleep 0.2
log "OK: version 0.2.0 → 0.3.0"
sleep 0.1
log "All lint checks passed"

# ── SHIP
stage "SHIP"
sleep 0.2
log "PR shipped on branch shipyard/01-add-dark-mode"

# ── CI
stage "CI"
sleep 0.2
log "Watching CI run #12849301..."
sleep 1.5
echo "build   In progress"
sleep 1.0
echo "build   Pass"
sleep 0.2
log "CI result: success"
log "CI passed"

# ── VERIFY
stage "VERIFY"
sleep 0.2
log "Clearing ports 3000,5173,8000..."
sleep 0.2
log "Starting: npm run dev"
sleep 0.5
log "Dev server ready at http://localhost:5173 — verifying changes"
log "Target route detected: /settings"
sleep 0.2
log "Verifying implementation (max 120s)..."
sleep 0.6
echo "Opening http://localhost:5173/settings..."
sleep 0.8
echo "Taking screenshot: settings-dark-mode.png"
sleep 0.6
echo "Toggle working — switches between light and dark"
sleep 0.3
echo "System preference respected on first load"
sleep 0.2
echo "VERIFY_PASS"
sleep 0.3
echo "Committed 2 screenshots to branch"
echo "Posted PR comment with screenshots"

# ── UPDATE
stage "UPDATE"
sleep 0.2
log "Moved tasks/01-add-dark-mode.md → tasks/done/"

# ── DONE
stage "DONE"
sleep 0.2
log "PR: https://github.com/stevederico/skateboard/pull/47"
echo ""
