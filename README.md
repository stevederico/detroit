<p align="center">
  <img src="headline.webp" alt="Detroit" width="750" height="500">
</p>

# Detroit

### an autonomous code factory — tasks in, pull requests out

Drop a markdown task in `tasks/`, and Detroit drives a coding agent through the whole pipeline — **triage → plan → build → test → ship** — running your tests and opening a PR with screenshots. It's a shell script you own, not a hosted black box, and it runs on Claude, Grok, or dotbot.

> [!TIP]
> **One [`factory.md`](https://github.com/stevederico/factory-md) runs the whole line.** A single file at your repo root declares the pipeline and the standards every change must meet — style, build, testing, security — in named sections. Edit it to control exactly what the agent does. Clone a factory, run it anywhere.

## How It Works

1. Picks the next task file from `tasks/`
2. Routes to the repo (local, GitHub, or creates a new one)
3. Claude codes it, runs tests, commits, opens a PR
4. Moves the task file to `tasks/done/`

## Setup

Detroit expects your repos to live in the parent directory:

```
projects/
  detroit/        # this repo
  my-app/          # a repo detroit can work on
  another-app/     # another repo
```

If a repo isn't local, Detroit searches your GitHub account and clones it automatically.

Or set `DETROIT_PROJECTS` to point elsewhere:

```bash
export DETROIT_PROJECTS="$HOME/code"
```

## Usage

```bash
./factory.sh                              # run one task (Claude by default)
./factory.sh --dry-run                    # preview what it would pick
./factory.sh --parallel 3                 # run 3 tasks in parallel
./factory.sh --issues owner/repo          # pull GitHub issues into tasks/
./factory.sh --verify owner/repo          # re-verify all open PRs
./factory.sh --verify owner/repo 42       # re-verify a specific PR

DETROIT_AGENT=dotbot ./factory.sh        # use dotbot instead of Claude
DETROIT_AGENT=dotbot DETROIT_PROVIDER=anthropic ./factory.sh  # dotbot + Anthropic
DETROIT_AGENT=grok ./factory.sh          # use the xAI Grok CLI (needs XAI_API_KEY)
```

Run in its own terminal — not inside another tool. Monitor progress in a second terminal:

```bash
tail -f logs/*.log
```

Cancel anytime with `Ctrl+C` — Detroit cleans up the branch and returns to the default branch.

## Task Format

Each task is a markdown file in `tasks/`. The filename becomes the task name. The file body is the full prompt sent to Claude — write as much or as little as you need.

**Existing repo** — add `repo:` in frontmatter:

```markdown
---
repo: my-app
---

Add a dark mode toggle to the settings page. Should respect system
preference by default. Use the existing ThemeProvider context.
```

**Screenshot verification** — if `agent-browser` is installed and the project has a `dev`/`start`/`preview` script, Detroit starts the dev server after shipping, reads the git diff to figure out which pages were affected, and uses Claude + agent-browser to take targeted screenshots of the changes. Screenshots are committed to the branch and commented on the PR.

**New repo** — omit `repo:` and Detroit creates one (named from the filename):

```markdown
Build a weather dashboard that shows 5-day forecast.
Use OpenWeatherMap API. Include a search bar for city lookup.
```

Tasks run in alphabetical order by filename. Prefix with numbers to control priority:

```
tasks/
  01-fix-auth.md           ← runs first
  02-add-dashboard.md
  03-refactor-api.md
```

Completed tasks move to `tasks/done/`.

## GitHub Issues

Pull issues from any repo into your task queue:

```bash
./factory.sh --issues owner/repo
```

This fetches open issues labeled `detroit` and creates task files from them. After the factory completes a task, it comments the PR link on the issue and closes it.

## Schedule

Detroit is designed to run unattended. Point cron at it and your issues get solved while you sleep.

**Every hour** — process one task from the queue:

```bash
0 * * * * /path/to/detroit/factory.sh >> /path/to/detroit/detroit.log 2>&1
```

**Every hour** — pull new GitHub issues, then process them:

```bash
0 * * * * /path/to/detroit/factory.sh --issues owner/repo >> /path/to/detroit/detroit.log 2>&1
```

**Nightly batch** — run 5 tasks in parallel at 2am:

```bash
0 2 * * * /path/to/detroit/factory.sh --parallel 5 >> /path/to/detroit/detroit.log 2>&1
```

Label a GitHub issue `detroit`, go to bed, wake up to a PR with screenshots. That's the workflow.

## Factory Features

Based on patterns from Ramp Inspect and Stripe Minions:

1. **Task queue** — `tasks/` folder, one markdown file per task
2. **Task routing** — finds repo locally, clones from GitHub, or creates new
3. **Branch isolation** — agents work on feature branches, never the default branch
4. **Autonomous coding** — agent runs non-interactively (Claude or dotbot)
5. **Test verification** — run tests, fail fast if broken
6. **PR creation** — open a PR via `gh` CLI for every task
7. **CI gate** — auto-generates GitHub Actions workflow, watches CI, fixes failures
8. **Task completion** — move task file to `tasks/done/`
9. **Visual verification** — targeted screenshots of changes via agent-browser
10. **Streaming output** — real-time Claude session output via stream-json
11. **Parallel execution** — run multiple tasks concurrently with `--parallel N`
12. **Logging** — timestamped logs per run for debugging
13. **Scheduling** — cron or trigger to run without you

## Configuration

A single file controls the factory: **`factory.md`** at the repo root. A Dockerfile for code factories — all the standards an autonomous agent needs to ship code in a repo, in one file you can clone and run anywhere. See the [factory.md spec](https://github.com/stevederico/factory-md) for the full format.

`factory.md` has 8 reserved sections. Each section is a bullet list of rules.

| # | Section | Covers |
|---|---------|--------|
| 1 | `## style` | Formatting, naming, function size, imports, changelog hygiene |
| 2 | `## build` | Runtime, package manager, CI workflow, version bumping |
| 3 | `## testing` | Test framework, pass/fail gates, new-code test requirements |
| 4 | `## documentation` | Doc comments, README, AGENTS.md updates |
| 5 | `## environment` | Dev tools, branching rules, worktrees |
| 6 | `## quality` | File size, function size, TODO/FIXME, complexity |
| 7 | `## observability` | Logging, error reporting, tracing |
| 8 | `## security` | Hardcoded credentials, dangerous patterns, dependencies |

Every bullet is one rule. The framework reads each bullet and either:

- **Runs it as a gate** if it recognizes the rule (e.g. "no secrets in diff", "tests pass")
- **Forwards it to the agent** as an additional rule to honor if it doesn't recognize it

Prefix a bullet with `!` to mark it **strict** — the framework must verify it deterministically or the pipeline fails. Use strict for security, correctness, and release-critical rules you refuse to trust a model on:

```markdown
## security
- ! No hardcoded credentials
- ! No eval
- Dependency audit clean
```

Edit any section to match your preferences. `factory.md` is framework-agnostic — the same file can drive any autonomous agent pipeline, not just Detroit.

## Pipeline

Detroit's pipeline is an implementation detail of `factory.sh`:

1. Pick the next task from `tasks/`
2. Route it to a repo (local, GitHub, or new)
3. Prepare a feature branch (worktree)
4. Scaffold a CI workflow if missing
5. Run the agent with every `factory.md` rule injected into the prompt
6. Dispatch every rule bullet through `check_gate`; recognized gates run as checks, unrecognized gates are forwarded
7. Fix gate failures by re-engaging the agent (max 2 attempts)
8. Confirm the PR, watch CI, fix failures (max 2 attempts)
9. Screenshot affected pages via agent-browser
10. Move the task file to `tasks/done/`, close the issue, return to the default branch

## Requirements

- [Claude Code](https://claude.ai/claude-code), [dotbot](https://github.com/stevederico/dotbot), or the [Grok CLI](https://docs.x.ai/build/cli) (needs `XAI_API_KEY`)
- `gh` CLI (authenticated)
- `agent-browser` (optional, for screenshot verification)

## Why Detroit

Detroit does the same thing as GitHub Copilot Coding Agent and Claude for GitHub — task in, PR out, automated. The difference is it's a shell script you own.

### What Detroit has that they don't

- **Task queue with priority** — file-based, numbered for order, not one-off prompts
- **Configurable standards and workflow** — edit `factory.md` (a portable, framework-agnostic spec) to control exactly what the agent does
- **Screenshot verification** — starts the dev server, reads the diff, screenshots the actual pages that changed
- **Runs locally** — no data leaves your machine except API calls
- **Swappable agent** — Claude Code, the xAI Grok CLI, or dotbot (any provider: xAI, Anthropic, OpenAI, Ollama)
- **GitHub issues integration** — pull labeled issues into the queue, close them on completion
- **No vendor lock-in** — swap Claude for another model, change the pipeline, fork it

### What they have that Detroit doesn't

- Hosted infrastructure (no local machine needed)
- Web UI
- No setup

### Who is Detroit for

Developers who want to own their code factory. Same idea as self-hosting vs SaaS — you trade convenience for control.

## Contributing

```bash
git clone https://github.com/stevederico/detroit
cd detroit
```

Edit `factory.sh` or `factory.md`. Open a PR.

## License

MIT — see [LICENSE](LICENSE).
