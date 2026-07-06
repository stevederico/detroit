# Detroit

Autonomous code factory that reads task files from `tasks/` and ships them as PRs.

## Structure

- `factory.sh` — entry point. Parses flags, sources `lib/`, dispatches modes. Reads rules from `factory.md` and enforces them.
- `lib/` — the actual pipeline, one sourced module per concern: `core.sh` (logging/status/cleanup), `args.sh` (flag parsing), `factory-md.sh` (spec parsing), `gates.sh` (deterministic rule gates), `agent.sh` (claude/dotbot/grok invocation), `devserver.sh` (dev server + test-account helpers), `modes.sh` (--parallel/--issues), `verify-prs.sh` (--verify), `pipeline.sh` (PICK→SHIP), `postship.sh` (CI→DONE).
- `factory.md` — portable spec of the standards the agent must follow. 8 H2 sections: `## style`, `## build`, `## testing`, `## documentation`, `## environment`, `## quality`, `## observability`, `## security`. Each bullet is one rule. Spec: https://github.com/stevederico/factory-md
- `tasks/` — task queue. One markdown file per task. Completed tasks move to `tasks/done/`.
- `test/` — self-test suite (`bash test/run.sh`); runs with shellcheck in this repo's CI.
- `logs/` — timestamped logs per run (gitignored)

## Task Format

Each file in `tasks/` is a task. The filename is the task name, the body is the prompt.

- Optional `repo:` in YAML frontmatter routes to an existing repo (local or GitHub).
- No frontmatter = new repo (name slugified from filename).
- Files run in alphabetical order.

## Factory Flow

`factory.sh` runs a fixed bash pipeline. `factory.md` supplies the rules the agent enforces during the CODE stage and the gates the framework runs afterwards.

1. **PICK** — first `.md` file from `tasks/` (alphabetical, atomic lock)
2. **ROUTE** — resolve task to a repo (local, GitHub, or new)
3. **PREPARE** — pull default branch, create feature branch via worktree
4. **SCAFFOLD** — generate `.github/workflows/ci.yml` if missing
5. **CODE** — agent session. Every `factory.md` rule is injected into the prompt. Agent implements, tests, documents, instruments, versions, commits, pushes, opens PR.
6. **GATES** — every rule bullet from `factory.md` is dispatched through `check_gate`. Recognized rules run as shell checks; unrecognized rules are held as "custom" constraints.
7. **FIX** — if GATES fails, re-engage the agent with the failures and custom constraints (max 2 attempts).
8. **SHIP** — confirm PR opened.
9. **CI** — watch GitHub Actions, re-engage agent on failure (max 2 attempts).
10. **VERIFY** — agent reads diff, screenshots affected pages via agent-browser.
11. **UPDATE** — move task file to `tasks/done/`, close GitHub issue.
12. **DONE** — return to default branch, log to `logs/{timestamp}.log`.

## Configuration

Edit `factory.md` to customize the factory. Every rule the factory enforces lives in one of the 8 reserved sections. Add a bullet, it becomes a rule. If the framework recognizes the bullet it runs as a gate; otherwise it is forwarded to the agent.

`factory.md` is a portable spec — see https://github.com/stevederico/factory-md for the full format.
