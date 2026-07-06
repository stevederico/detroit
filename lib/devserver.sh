# shellcheck shell=bash
# shellcheck disable=SC2034  # globals here are consumed by verify-prs.sh/postship.sh
# lib/devserver.sh — dev server, port, and test-account helpers shared by the
# VERIFY stage (lib/postship.sh) and --verify mode (lib/verify-prs.sh).
# Functions run in the current directory (the checked-out repo) and communicate
# via globals: DEV_CMD, DEV_PORTS, DEV_URL, DEV_PID, BACKEND_PID, TARGET_ROUTE,
# TEST_AUTH.

# detect_dev_cmd — first of start/dev/preview in package.json scripts → DEV_CMD
detect_dev_cmd() {
  DEV_CMD=""
  [ -f "package.json" ] || return 0
  DEV_CMD=$(python3 -c "
import json
scripts = json.load(open('package.json')).get('scripts', {})
for cmd in ['start', 'dev', 'preview']:
    if cmd in scripts:
        print(cmd)
        break
" 2>/dev/null)
}

# detect_dev_ports — scan project config for ports (plus seeded defaults) → DEV_PORTS (csv)
detect_dev_ports() {
  local seed
  seed=$(resolve_knob DETROIT_DEV_PORTS "dev ports" "3000,5173,8000")
  DEV_PORTS=$(DETROIT_SEED_PORTS="$seed" python3 -c "
import json, re, os
ports = set()
# Check vite.config for frontend port
for f in ['vite.config.js', 'vite.config.ts']:
    if os.path.exists(f):
        content = open(f).read()
        m = re.search(r'port\s*:\s*(\d+)', content)
        if m: ports.add(m.group(1))
# Check backend config for server port
for f in ['backend/config.json', 'backend/server.js', 'backend/index.js']:
    if os.path.exists(f):
        content = open(f).read()
        for m in re.finditer(r'(?:port|PORT)\s*[:=]\s*[\"'\'']*(\d+)', content):
            ports.add(m.group(1))
# Check .env for PORT
for f in ['.env', 'backend/.env']:
    if os.path.exists(f):
        for line in open(f):
            m = re.match(r'PORT\s*=\s*(\d+)', line)
            if m: ports.add(m.group(1))
# Check package.json scripts for --port flags
for f in ['package.json', 'backend/package.json']:
    if os.path.exists(f):
        scripts = json.load(open(f)).get('scripts', {})
        for v in scripts.values():
            for m in re.finditer(r'--port\s+(\d+)', v):
                ports.add(m.group(1))
# Seed ports: DETROIT_DEV_PORTS env > factory.md 'dev ports:' bullet > vite/common defaults
ports.update(p for p in os.environ.get('DETROIT_SEED_PORTS', '').replace(' ', '').split(',') if p)
print(','.join(sorted(ports)))
" 2>/dev/null)
}

# clear_dev_ports — kill whatever holds DEV_PORTS (no-op if lsof is absent)
clear_dev_ports() {
  [ -n "$DEV_PORTS" ] || return 0
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -ti :"$DEV_PORTS" 2>/dev/null | xargs kill 2>/dev/null
  sleep 1
}

# start_backend — npm run start/dev in backend/ if present → BACKEND_PID
start_backend() {
  BACKEND_PID=""
  [ -f "backend/package.json" ] || return 0
  local backend_start
  backend_start=$(python3 -c "
import json
scripts = json.load(open('backend/package.json')).get('scripts', {})
for cmd in ['start', 'dev']:
    if cmd in scripts:
        print(cmd)
        break
" 2>/dev/null)
  [ -n "$backend_start" ] || return 0
  log "Starting backend: npm run $backend_start --prefix backend"
  npm run "$backend_start" --prefix backend > /dev/null 2>&1 &
  BACKEND_PID=$!
  sleep 3
}

# start_dev_server — npm run $DEV_CMD, wait up to 30s for a localhost URL
# → DEV_PID, DEV_URL (empty on failure)
start_dev_server() {
  local dev_log
  dev_log=$(mktemp)
  npm run "$DEV_CMD" > "$dev_log" 2>&1 &
  DEV_PID=$!

  DEV_URL=""
  local _
  for _ in $(seq 1 30); do
    DEV_URL=$(grep -oE 'https?://localhost:[0-9]+' "$dev_log" 2>/dev/null | head -1)
    if [ -n "$DEV_URL" ]; then break; fi
    sleep 1
  done
  rm -f "$dev_log"
}

# stop_dev_servers — kill dev server, backend, and anything left on DEV_PORTS
stop_dev_servers() {
  kill "$DEV_PID" 2>/dev/null; wait "$DEV_PID" 2>/dev/null
  if [ -n "$BACKEND_PID" ]; then kill "$BACKEND_PID" 2>/dev/null; wait "$BACKEND_PID" 2>/dev/null; fi
  if [ -n "$DEV_PORTS" ] && command -v lsof >/dev/null 2>&1; then
    lsof -ti :"$DEV_PORTS" 2>/dev/null | xargs kill 2>/dev/null
  fi
}

# extract_target_route <diff> — best route guess from the diff → TARGET_ROUTE
extract_target_route() {
  TARGET_ROUTE=$(echo "$1" | python3 -c "
import sys, re
routes = set()
for line in sys.stdin:
    # Match route definitions: path: 'foo', '/foo', element: <FooView>
    for m in re.finditer(r\"path:\s*['\\\"]([^'\\\"]+)\", line):
        routes.add(m.group(1))
    # Match changed component filenames like PostsView, HomeView
    m = re.match(r'^\+\+\+ b/.*?/(\w+View)\.\w+', line)
    if m:
        name = m.group(1).replace('View', '').lower()
        if name and name != 'app': routes.add(name)
if routes:
    # Prefer the most specific route
    best = sorted(routes, key=len, reverse=True)[0]
    print(best.strip('/'))
" 2>/dev/null)
}

# precreate_test_account — signup (or signin) the shared test account against
# the backend derived from DEV_URL → TEST_AUTH (empty if no auth API), plus
# TEST_EMAIL/TEST_PASSWORD for the verify prompts. Knobs (env > factory.md
# `## environment` bullet > default): DETROIT_TEST_EMAIL + DETROIT_TEST_PASSWORD
# (bullet `test account: <email> <password>`), DETROIT_SIGNUP_PATH (bullet
# `signup api:`; signin path derived), DETROIT_BACKEND_PORT (bullet `backend port:`).
precreate_test_account() {
  TEST_AUTH=""
  local backend_url signup_result signin_result acct signup_path signin_path backend_port

  TEST_EMAIL="${DETROIT_TEST_EMAIL:-}"
  TEST_PASSWORD="${DETROIT_TEST_PASSWORD:-}"
  if [ -z "$TEST_EMAIL" ] || [ -z "$TEST_PASSWORD" ]; then
    acct=$(read_env_bullet "test account" "$DETROIT/factory.md")
    [ -z "$TEST_EMAIL" ] && TEST_EMAIL=$(echo "$acct" | awk '{print $1}')
    [ -z "$TEST_PASSWORD" ] && TEST_PASSWORD=$(echo "$acct" | awk '{print $2}')
  fi
  TEST_EMAIL="${TEST_EMAIL:-test@detroit.dev}"
  TEST_PASSWORD="${TEST_PASSWORD:-detroit123}"
  signup_path=$(resolve_knob DETROIT_SIGNUP_PATH "signup api" "/api/signup")
  signin_path="${signup_path/signup/signin}"
  backend_port=$(resolve_knob DETROIT_BACKEND_PORT "backend port" "8000")

  backend_url=$(echo "$DEV_URL" | sed "s/:5173/:$backend_port/" | sed "s/:5174/:$backend_port/")
  signup_result=$(curl -s -X POST "$backend_url$signup_path" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"Test User\",\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\"}" 2>/dev/null)
  if echo "$signup_result" | python3 -c "import sys,json; json.load(sys.stdin)['token']" 2>/dev/null; then
    TEST_AUTH="Test account created ($TEST_EMAIL / $TEST_PASSWORD)"
  else
    signin_result=$(curl -s -X POST "$backend_url$signin_path" \
      -H "Content-Type: application/json" \
      -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\"}" 2>/dev/null)
    if echo "$signin_result" | python3 -c "import sys,json; json.load(sys.stdin)['token']" 2>/dev/null; then
      TEST_AUTH="Test account exists ($TEST_EMAIL / $TEST_PASSWORD)"
    fi
  fi
}
