# Changelog

0.49.0

  Split into lib modules
  Dedupe dev server logic
  Slim entry point

0.48.0

  Combinable CLI flags
  Fix parallel summary
  CODE stage timeout
  Surface swallowed errors
  Safer worktree cleanup

0.47.0

  Add self-test suite
  Add GitHub Actions CI
  Extract lib gate modules

0.46.0
  Revert top tiles
  Task badge shows stage

0.45.0
  Pipeline stage rail
  Six stages up top
  Active stage highlighted

0.44.0
  Light/dark theme toggle (top right)
  Higher-contrast dark mode
  Theme persists via localStorage

0.43.0
  Full-width queue with status/label filters
  Search issues, stat count tiles
  Task status and labels frontmatter

0.42.0
  Brutalist theme for the web UI
  Zero radius, orange accent, mono uppercase

0.41.0
  Local web UI (web.rs, std-only Rust)
  Monitor floor, create tasks, trigger runs
  Browser plan approval (DETROIT_APPROVE_PLAN=web)
  Show projects folder in header

0.40.0
  Rewrite README intro
  factory.md callout near top

0.39.0
  WebP-only banner
  Drop jpg fallback

0.38.0
  New banner image

0.37.0
  Rename project to detroit
  DETROIT_* env vars (hard cut, no aliases)
  Branch prefix and factory name updated

0.36.0
  Rename check stage to test
  check: keyword and check_gate unchanged

0.35.0
  Rename spec stage to plan
  PLAN stage, plan.md, route: plan

0.34.0
  Stage-aware gates (factory.md v2)
  Read ## stages section
  Triage and spec pre-code stages
  Grok CLI agent option
  Dedupe rules across stages

0.33.0
  Support inline check suffix on rules
  Run rule-local shell checks in GATES

0.32.0
  Extract factory-md as standalone repo
  Point references at github.com/stevederico/factory-md
0.31.0
  Strict rule prefix support
  Block pipeline on unrecognized strict rules
0.30.0
  Simplify factory.md to 8 sections
  Collapse pipeline stages into gates dispatcher
0.29.0
  Add document instrument audit secure scaffold stages
  Pipeline grows to 16 stages across 10 containers
0.28.0
  Read lint gates from factory.md
  Custom gates fall through to agent
0.27.0
  Declarative stages spec
  Replace workflow with stages
0.26.0
  Adopt factory.md spec
  Consolidate standards and workflow
0.25.0
  Swappable agent provider
  Support dotbot and Claude
0.24.0
  CI workflow generator
  CI gate with fix loop
0.23.0
  Start backend before frontend
  Add versioning rules workflow
0.22.0
  Open source prep
  Add MIT LICENSE
  Add Why Detroit section
  Fix README accuracy
0.21.0
  Parallel execution
  Self-verification loop
  FIX stage lint retry
0.20.0
  Screenshot verification
0.19.0
  Rename project to repo
  GitHub clone fallback
0.18.0
  Configurable workflow file
  Auto-detect base branch
  Configurable standards file
0.17.0
  Configurable standards file
0.16.0
  Fix audit bugs
0.15.0
  GitHub issues sync
0.14.0
  Tasks folder queue
0.13.0
  Create new projects
0.12.0
  Remove hardcoded paths
0.11.0
  Local task queue
0.10.0
  Gap analysis docs
  Remove --cwd flag
0.9.0
  Deterministic lint gates
  Stream Claude session
  Verbose stage logging
  Subtask completion logic
  Project CLAUDE.md loading
  12-stage pipeline
  Factory prompt standards
  Initial detroit factory
