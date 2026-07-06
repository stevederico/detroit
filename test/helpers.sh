# shellcheck shell=bash
# test/helpers.sh — shared fixtures and assertions for the detroit test suite.
# Plain bash (3.2-safe), no dependencies. Never calls lsof, timeout, or /dev/tty.
# Source from a test_*.sh file; call summarize at the end.

TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT

# shellcheck disable=SC2034  # consumed by the sourcing test file
DETROIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0

# make_repo <dir> — init a git repo with a main branch and one commit
make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@detroit.dev
  git -C "$dir" config user.name detroit-test
  git -C "$dir" checkout -q -b main
  echo "# fixture" > "$dir/README.md"
  git -C "$dir" add -A
  git -C "$dir" commit -qm init
}

# add_commit <dir> <file> <content...> — write a file (multi-line via stdin-style args) and commit
add_commit() {
  local dir="$1" file="$2"; shift 2
  mkdir -p "$dir/$(dirname "$file")"
  printf '%s\n' "$@" > "$dir/$file"
  git -C "$dir" add -A -f  # -f: fixtures like .env are often globally gitignored
  git -C "$dir" commit -qm "add $file"
}

# make_branch <dir> <name> — create and switch to a branch off the current HEAD
make_branch() {
  git -C "$1" checkout -q -b "$2"
}

# assert_rc <expected-rc> <desc> <cmd...> — run cmd, compare exit code
assert_rc() {
  local expected="$1" desc="$2"; shift 2
  local rc=0
  "$@" || rc=$?
  if [ "$rc" = "$expected" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok: $desc"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "  FAIL: $desc (expected rc=$expected, got rc=$rc)"
  fi
}

# assert_eq <expected> <actual> <desc>
assert_eq() {
  if [ "$1" = "$2" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok: $3"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "  FAIL: $3 (expected [$1], got [$2])"
  fi
}

# assert_contains <haystack> <needle> <desc>
assert_contains() {
  case "$1" in
    *"$2"*)
      PASS_COUNT=$((PASS_COUNT + 1))
      echo "  ok: $3" ;;
    *)
      FAIL_COUNT=$((FAIL_COUNT + 1))
      echo "  FAIL: $3 (missing [$2])" ;;
  esac
}

# assert_not_contains <haystack> <needle> <desc>
assert_not_contains() {
  case "$1" in
    *"$2"*)
      FAIL_COUNT=$((FAIL_COUNT + 1))
      echo "  FAIL: $3 (unexpectedly found [$2])" ;;
    *)
      PASS_COUNT=$((PASS_COUNT + 1))
      echo "  ok: $3" ;;
  esac
}

# stub_bin <name> <script-body> — install a PATH shim in $TESTDIR/bin
stub_bin() {
  mkdir -p "$TESTDIR/bin"
  printf '#!/bin/bash\n%s\n' "$2" > "$TESTDIR/bin/$1"
  chmod +x "$TESTDIR/bin/$1"
  case ":$PATH:" in
    *":$TESTDIR/bin:"*) ;;
    *) PATH="$TESTDIR/bin:$PATH" ;;
  esac
}

summarize() {
  echo "$(basename "$0"): $PASS_COUNT passed, $FAIL_COUNT failed"
  [ "$FAIL_COUNT" = 0 ]
}
