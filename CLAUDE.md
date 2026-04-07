# Shipyard

Autonomous code factory that reads task files from `tasks/` and ships them as PRs.

## Structure

- `factory.sh` — factory pipeline. Deterministic stages interleaved with agentic Claude sessions.
- `factory.md` — portable spec describing standards, workflow, validation, routing, and runtime. Injected into every Claude session. See `docs/factory-md-spec.md`.
- `tasks/` — task queue. One markdown file per task. Completed tasks move to `tasks/done/`.
- `logs/` — timestamped logs per run (gitignored)

## Task Format

Each file in `tasks/` is a task. The filename is the task name, the body is the prompt.

- Optional `repo:` in YAML frontmatter routes to an existing repo (local or GitHub).
- No frontmatter = new repo (name slugified from filename).
- Files run in alphabetical order.

## Factory Flow

1. Pick first `.md` file from `tasks/`
2. Route to repo (local → GitHub clone → create new)
3. Detect default branch (`main`/`master`), git pull
4. Generate CI workflow if repo has none (`.github/workflows/ci.yml`)
5. Claude codes, tests, follows the `## workflow` section of `factory.md` (commit, push, PR) — output streams in real time
6. Deterministic lint checks: no secrets, test failures, changelog, version bump
7. Ship PR, watch GitHub Actions CI — fix failures (max 2 attempts)
8. Verify: start dev server + backend, Claude screenshots affected pages via agent-browser
9. Task file moved to `tasks/done/`
10. Logs to `logs/{timestamp}.log`

## Configuration

Edit `factory.md` to customize the factory. All configuration lives in named H2 sections:

- `## standards` — coding standards injected into every Claude session
- `## workflow` — step-by-step instructions Claude follows after coding (commit, push, PR, etc.)
- `## validation` — deterministic gates a task must pass before being marked done
- `## routing` — how tasks map to repos
- `## runtime` — language/tooling hints

`factory.md` is a portable spec — see `docs/factory-md-spec.md` for the full format.
