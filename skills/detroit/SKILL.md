---
name: detroit
author: stevederico
description: Autonomous code factory — tasks in, PRs out. Triggers on run factory, ship task, pick next task, triage plan, dry-run prompt, parallel run, sync issues, verify PRs, detroit fix CI verify.
allowed-tools: Bash(git *), Bash(gh *), Bash(npm *), Bash(agent-browser *), Read, Edit, Write, Glob, Grep
---

# Detroit Skill

Thin router over `factory.sh`. The agent performs prompt stages inline.
Bash owns everything deterministic. Tokens never override exit codes.

## When User Says "detroit ..."

Map the verb to the factory flag and run it from the detroit repo root:

```bash
bash factory.sh                  # run the next task from tasks/
bash factory.sh --dry-run        # resolve task/repo/branch, print prompt, run nothing
bash factory.sh --parallel 3     # spawn 3 factory agents (worktree-isolated)
bash factory.sh --shift          # run tasks one by one until the usage window hits DETROIT_BUDGET_STOP
bash factory.sh --repo NAME      # only run tasks whose frontmatter repo: matches NAME
bash factory.sh --issues owner/repo       # pull open issues labeled detroit into tasks/
bash factory.sh --verify owner/repo       # screenshot all open PRs
bash factory.sh --verify owner/repo 42    # screenshot one PR
```

Flags combine (e.g. `--parallel 2 --dry-run`). `parallel` / `verify` / `issues`
are mutually exclusive — last one wins (`lib/args.sh`). `--shift` combines only
with `--dry-run` and `--repo`; pairing it with the others exits 2.

## Task Format

One markdown file per task in `tasks/`. Alphabetical order. Prefix with
numbers to control priority (`01-fix-auth.md` runs first).

Existing repo — `repo:` frontmatter:

```markdown
---
repo: my-app
---

Add a dark mode toggle to the settings page. Should respect system
preference by default. Use the existing ThemeProvider context.
```

New repo — omit `repo:`, Detroit creates one slugified from the filename.

Routing: local dir under `$DETROIT_PROJECTS` → `gh repo list --limit 500`
clone → error. New repos get `git init` on `main`.

## Pipeline (bash owns this)

PICK → ROUTE → PREPARE → SCAFFOLD → TRIAGE → PLAN → CODE → GATES → FIX →
SHIP → CI → VERIFY → UPDATE → DONE (`factory.sh`, `lib/pipeline.sh`,
`lib/code-stage.sh`, `lib/postship.sh`).

- PREPARE: detect base branch via `origin/HEAD`, `git pull --rebase`,
  isolate on worktree `detroit/<task-name>` — never touch default branch.
- SCAFFOLD: generate `.github/workflows/ci.yml` if missing and
  `package.json` exists. Node version is read from `factory.md` `## build`
  so spec and workflow cannot disagree.
- SHIP counts only on verified facts (commits + open PR via `gh pr list`,
  not the agent's printed result) — `lib/shipped.sh`.
- UPDATE: success → `tasks/done/`; shipped-but-quality-failed →
  `tasks/failed/`; unshipped stays. `FACTORY_RESULT:SUCCESS` only when
  shipped AND quality OK.

## Inline Stages (agent owns these)

Do these in-session instead of spawning a nested agent subprocess:

TRIAGE — classify, then reply exactly one line plus one reason:

```text
route: build — simple, unambiguous, single-file, no new dependency.
route: plan — new surface, more than one subsystem, schema change, new dep.
When in doubt, route: plan.
```

PLAN — fill this template into `plan.md` in the repo root:

```text
Intent: what changes for the user, and the invariant that must hold after.
Out of scope: what this explicitly does not do.
Targets: files/functions to touch, with paths; any new dependency.
Acceptance: checks that prove it works — each a command or observable behavior.
```

CODE — implement to the plan, then per `factory.md` rules: tests (max 3
fix attempts), doc comments matching implementation, README/AGENTS updates
for affected behavior, error logging with context, minor version bump +
CHANGELOG entry, stage specific files, commit, push, `gh pr create`.

Approval gate: `DETROIT_APPROVE_PLAN=web` pauses at plan until the dashboard
approves; `=1` asks on the terminal (`lib/code-stage.sh`).

## Gates (deterministic, in bash)

Every `factory.md` bullet dispatches through `check_gate` (`lib/gates.sh`).
Recognized rules run as shell checks. Unrecognized plain bullets are
forwarded to the agent as constraints. Strict `!` rules with no framework
check fail closed — add a `check_gate` pattern or drop the `!`.

| Rule text | Check |
|---|---|
| secret / .env / .pem / credential / token | filename scan + added-line secret-shape scan (lockfiles excluded) |
| changelog | CHANGELOG touched in branch diff |
| version bump | `package.json` version differs from pre-code capture |
| test pass | framework runs the repo tests itself (`DETROIT_TEST_CMD` override, else `npm test`, 300s timeout) |
| file over 500 lines | no touched file exceeds 500 lines |
| TODO / FIXME | no added line introduces TODO or FIXME |
| hardcoded credential / api key | added-line secret-shape scan |
| eval | no added `eval(` |
| child_process / exec interpolated / shell injection | no added `exec*(${` |
| `` `check: <shell>` `` suffix | run the shell inline, exit 0 = pass (takes precedence) |

FIX loop: max 2 attempts with failure text fed back. CI loop: `gh run watch`,
max 2 fix attempts with failed-log tail fed back. VERIFY: `agent-browser`
opens the diff-detected target route, screenshots, prints
`VERIFY_PASS` or `VERIFY_FAIL: reason`, one fix retry.

## Knobs

```bash
DETROIT_AGENT=claude|dotbot|grok   # default claude
DETROIT_CODE_TIMEOUT=3600          # CODE stage seconds
DETROIT_TEST_CMD="npm test --silent"
DETROIT_TEST_TIMEOUT=300
DETROIT_APPROVE_PLAN=0|1|web
DETROIT_REPO=NAME                  # same as --repo
DETROIT_PROJECTS="$HOME/code"      # where target repos live
```

## Format Requirements

### Lessons

Append durable one-line failures to `lessons.md` (cap 50). Last 15 lines
are injected into every CODE prompt (`lib/core.sh`, `lib/code-stage.sh`).

### Log Format

Plain text, no markdown, no `**` or `##` or `[]`. Stage headers use
`━━━ STAGE ━━━`.

### CHANGELOG

New version at top with 3-word indented entries, no dashes. Minor bump by
default (`1.7.0` → `1.8.0`).

## Prohibited

- No commits to the default branch, ever
- No `git add .` / `git add -A` — stage only files you changed
- No AI attribution, no Co-Authored-By trailers
- No trusting the agent's `FACTORY_RESULT` print — `verify_shipped` decides
- No new bash `case` arm in `check_gate` when a `` `check:` `` suffix suffices
- No secrets, `.env`, `.pem`, `.key`, credentials, or tokens in committed files
