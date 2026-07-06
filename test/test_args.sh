#!/bin/bash
# Tests for lib/args.sh and the factory.sh CLI surface.
. "$(dirname "$0")/helpers.sh"
. "$DETROIT_ROOT/lib/args.sh"

run_quiet() { "$@" >/dev/null 2>&1; }

echo "parse_args:"
parse_args
assert_eq "run" "$MODE" "no flags → run mode"
assert_eq "false" "$DRY_RUN" "dry-run defaults off"

parse_args --dry-run
assert_eq "run" "$MODE" "--dry-run keeps run mode"
assert_eq "true" "$DRY_RUN" "--dry-run sets flag"

parse_args --parallel 2 --dry-run
assert_eq "parallel" "$MODE" "--parallel sets mode"
assert_eq "2" "$PARALLEL_N" "--parallel N honored"
assert_eq "true" "$DRY_RUN" "--parallel combines with --dry-run"

parse_args --dry-run --parallel
assert_eq "parallel" "$MODE" "flag order irrelevant"
assert_eq "3" "$PARALLEL_N" "--parallel defaults to 3"

parse_args --verify owner/repo 12
assert_eq "verify" "$MODE" "--verify sets mode"
assert_eq "owner/repo" "$VERIFY_REPO" "--verify repo captured"
assert_eq "12" "$VERIFY_PR" "--verify PR number captured"

parse_args --verify owner/repo
assert_eq "" "$VERIFY_PR" "--verify PR number optional"

parse_args --issues owner/repo
assert_eq "issues" "$MODE" "--issues sets mode"
assert_eq "owner/repo" "$ISSUES_REPO" "--issues repo captured"

assert_rc 2 "--verify without repo rejected" run_quiet parse_args --verify
assert_rc 2 "--issues without repo rejected" run_quiet parse_args --issues
assert_rc 2 "unknown flag rejected" run_quiet parse_args --bogus

parse_args --help
assert_eq "help" "$MODE" "--help sets mode"

echo "factory.sh CLI:"
assert_rc 0 "--help exits 0" run_quiet bash "$DETROIT_ROOT/factory.sh" --help
assert_rc 2 "unknown arg exits 2" run_quiet bash "$DETROIT_ROOT/factory.sh" --nope
assert_rc 2 "--verify without repo exits 2" run_quiet bash "$DETROIT_ROOT/factory.sh" --verify

echo "with_timeout:"
AGENT_ID=0
. "$DETROIT_ROOT/lib/core.sh"
assert_rc 0 "fast command passes" with_timeout 5 true
assert_rc 1 "failing command rc preserved" with_timeout 5 false
assert_rc 124 "hung command times out" with_timeout 1 sleep 30

summarize
