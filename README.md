<p align="center">
  <picture>
    <source srcset="headline.webp" type="image/webp">
    <img src="headline.jpg" alt="Shipyard" width="750" height="500">
  </picture>
</p>

# Shipyard

Autonomous code factory. Issues go in, PRs come out.

## How It Works

1. Picks the next task file from `tasks/`
2. Routes to the repo (local, GitHub, or creates a new one)
3. Claude codes it, runs tests, commits, opens a PR
4. Moves the task file to `tasks/done/`

## Setup

Shipyard expects your repos to live in the parent directory:

```
projects/
  shipyard/        # this repo
  my-app/          # a repo shipyard can work on
  another-app/     # another repo
```

If a repo isn't local, Shipyard searches your GitHub account and clones it automatically.

Or set `SHIPYARD_PROJECTS` to point elsewhere:

```bash
export SHIPYARD_PROJECTS="$HOME/code"
```

## Usage

```bash
./factory.sh                              # run one task (Claude by default)
./factory.sh --dry-run                    # preview what it would pick
./factory.sh --parallel 3                 # run 3 tasks in parallel
./factory.sh --issues owner/repo          # pull GitHub issues into tasks/
./factory.sh --verify owner/repo          # re-verify all open PRs
./factory.sh --verify owner/repo 42       # re-verify a specific PR

SHIPYARD_AGENT=dotbot ./factory.sh        # use dotbot instead of Claude
SHIPYARD_AGENT=dotbot SHIPYARD_PROVIDER=anthropic ./factory.sh  # dotbot + Anthropic
```

Run in its own terminal — not inside another tool. Monitor progress in a second terminal:

```bash
tail -f logs/*.log
```

Cancel anytime with `Ctrl+C` — Shipyard cleans up the branch and returns to the default branch.

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

**Screenshot verification** — if `agent-browser` is installed and the project has a `dev`/`start`/`preview` script, Shipyard starts the dev server after shipping, reads the git diff to figure out which pages were affected, and uses Claude + agent-browser to take targeted screenshots of the changes. Screenshots are committed to the branch and commented on the PR.

**New repo** — omit `repo:` and Shipyard creates one (named from the filename):

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

This fetches open issues labeled `shipyard` and creates task files from them. After the factory completes a task, it comments the PR link on the issue and closes it.

## Schedule

Shipyard is designed to run unattended. Point cron at it and your issues get solved while you sleep.

**Every hour** — process one task from the queue:

```bash
0 * * * * /path/to/shipyard/factory.sh >> /path/to/shipyard/shipyard.log 2>&1
```

**Every hour** — pull new GitHub issues, then process them:

```bash
0 * * * * /path/to/shipyard/factory.sh --issues owner/repo >> /path/to/shipyard/shipyard.log 2>&1
```

**Nightly batch** — run 5 tasks in parallel at 2am:

```bash
0 2 * * * /path/to/shipyard/factory.sh --parallel 5 >> /path/to/shipyard/shipyard.log 2>&1
```

Label a GitHub issue `shipyard`, go to bed, wake up to a PR with screenshots. That's the workflow.

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

## Stages

Defined declaratively in the `## stages` section of `factory.md`. Each stage is `agentic` (the agent does it), `deterministic` (the framework verifies gates), or `mixed` (deterministic detection with agentic remediation).

| Stage | Type | What |
|-------|------|------|
| `pick` | deterministic | Take first `.md` file from `tasks/` |
| `route` | deterministic | Find repo locally, clone from GitHub, or create new |
| `prepare` | deterministic | Detect default branch, git pull, create feature branch, generate CI |
| `code` | agentic | Claude implements, tests, versions, commits, pushes, opens PR |
| `lint` | deterministic | Shell gates: no secrets, changelog updated, version bumped |
| `fix` | mixed | Claude fixes lint failures (max 2 attempts) |
| `ship` | deterministic | Confirm PR opened, capture URL |
| `ci` | mixed | Watch GitHub Actions, fix failures (max 2 attempts) |
| `verify` | agentic | Agent reads diff, screenshots affected pages via agent-browser |
| `update` | deterministic | Move task file to `tasks/done/`, close GitHub issue |
| `done` | deterministic | Report result, return to default branch |

## Configuration

A single file controls the factory: **`factory.md`** at the repo root. It is a portable spec made of named H2 sections — see `docs/factory-md-spec.md` for the format.

- `## standards` — coding standards (error handling, accessibility, naming, etc.)
- `## stages` — the declarative pipeline (each stage is an H3 with a type tag)
- `## routing` — how tasks map to repos
- `## runtime` — language/tooling hints

Edit any section to match your preferences. The factory auto-detects your default branch (`main` or `master`) and new repos are created as private.

`factory.md` is designed to be framework-agnostic so the same file can drive any autonomous agent pipeline, not just Shipyard.

## Requirements

- [Claude Code](https://claude.ai/claude-code) or [dotbot](https://github.com/stevederico/dotbot)
- `gh` CLI (authenticated)
- `agent-browser` (optional, for screenshot verification)

## Why Shipyard

Shipyard does the same thing as GitHub Copilot Coding Agent and Claude for GitHub — task in, PR out, automated. The difference is it's a shell script you own.

### What Shipyard has that they don't

- **Task queue with priority** — file-based, numbered for order, not one-off prompts
- **Configurable standards and workflow** — edit `factory.md` (a portable, framework-agnostic spec) to control exactly what the agent does
- **Screenshot verification** — starts the dev server, reads the diff, screenshots the actual pages that changed
- **Runs locally** — no data leaves your machine except API calls
- **Swappable agent** — Claude Code or dotbot (any provider: xAI, Anthropic, OpenAI, Ollama)
- **GitHub issues integration** — pull labeled issues into the queue, close them on completion
- **No vendor lock-in** — swap Claude for another model, change the pipeline, fork it

### What they have that Shipyard doesn't

- Hosted infrastructure (no local machine needed)
- Web UI
- No setup

### Who is Shipyard for

Developers who want to own their code factory. Same idea as self-hosting vs SaaS — you trade convenience for control.

## Contributing

```bash
git clone https://github.com/stevederico/shipyard
cd shipyard
```

Edit `factory.sh` or `factory.md`. Open a PR.

## License

MIT — see [LICENSE](LICENSE).
