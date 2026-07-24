# shellcheck shell=bash
# lib/args.sh — CLI flag parsing.
# parse_args sets: MODE (run|parallel|verify|issues|help), PARALLEL_N,
# VERIFY_REPO, VERIFY_PR, ISSUES_REPO, DRY_RUN, REPO_FILTER. Returns 2 on bad input.
# Flags combine (e.g. --parallel 2 --dry-run); parallel/verify/issues are
# mutually exclusive — last one wins.

usage() {
  cat <<'USAGE'
Usage: bash factory.sh [--dry-run] [--parallel N] [--repo NAME] [--issues owner/repo] [--verify owner/repo [pr]]

  (no flags)                run the next task from tasks/
  --dry-run                 resolve task/repo/branch and print the prompt without running
  --parallel N              spawn N factory agents (default 3); combines with --dry-run
  --repo NAME               only run tasks whose frontmatter repo: matches NAME (env: DETROIT_REPO)
  --issues owner/repo       pull open GitHub issues labeled 'detroit' into tasks/
  --verify owner/repo [pr]  screenshot open PRs (all, or one PR number)
USAGE
}

# shellcheck disable=SC2034  # all outputs consumed by factory.sh after sourcing
parse_args() {
  MODE=run
  PARALLEL_N=3
  VERIFY_REPO=""
  VERIFY_PR=""
  ISSUES_REPO=""
  DRY_RUN=false
  REPO_FILTER="${DETROIT_REPO:-}"   # env seeds it; --repo overrides
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)
        if [ -z "${2:-}" ]; then echo "error: --repo needs NAME" >&2; usage >&2; return 2; fi
        REPO_FILTER="$2"; shift 2 ;;
      --parallel)
        MODE=parallel
        case "${2:-}" in
          *[!0-9]*|"") ;;  # no numeric arg — keep default
          *) PARALLEL_N="$2"; shift ;;
        esac
        shift ;;
      --verify)
        MODE=verify
        if [ -z "${2:-}" ]; then echo "error: --verify needs owner/repo" >&2; usage >&2; return 2; fi
        VERIFY_REPO="$2"; shift 2
        case "${1:-}" in
          *[!0-9]*|"") ;;  # no PR number
          *) VERIFY_PR="$1"; shift ;;
        esac ;;
      --issues)
        MODE=issues
        if [ -z "${2:-}" ]; then echo "error: --issues needs owner/repo" >&2; usage >&2; return 2; fi
        ISSUES_REPO="$2"; shift 2 ;;
      --dry-run)
        DRY_RUN=true; shift ;;
      -h|--help)
        MODE=help; shift ;;
      *)
        echo "error: unknown argument: $1" >&2; usage >&2; return 2 ;;
    esac
  done
  return 0
}
