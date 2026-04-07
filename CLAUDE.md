# Shipyard

Autonomous code factory that reads task files from `tasks/` and ships them as PRs.

## Structure

- `factory.sh` — factory pipeline runner. Reads stages from `factory.md` and executes them.
- `factory.md` — portable spec declaring standards, stages, routing, and runtime. The `## stages` section defines the full pipeline declaratively. See `docs/factory-md-spec.md`.
- `tasks/` — task queue. One markdown file per task. Completed tasks move to `tasks/done/`.
- `logs/` — timestamped logs per run (gitignored)

## Task Format

Each file in `tasks/` is a task. The filename is the task name, the body is the prompt.

- Optional `repo:` in YAML frontmatter routes to an existing repo (local or GitHub).
- No frontmatter = new repo (name slugified from filename).
- Files run in alphabetical order.

## Factory Flow

The pipeline runs as a sequence of stages declared in `factory.md` under `## stages`:

1. **pick** — first `.md` file from `tasks/` (alphabetical, atomic lock)
2. **route** — resolve task to a repo (local, GitHub, or new)
3. **prepare** — pull default branch, create feature branch, generate CI workflow if missing
4. **code** — Claude implements, tests, versions, commits, pushes, opens PR (one agent session, output streams in real time)
5. **lint** — gates: no secrets, changelog updated, version bumped
6. **fix** — re-engage Claude on lint failure (max 2 attempts)
7. **ship** — confirm PR opened
8. **ci** — watch GitHub Actions, re-engage Claude on failure (max 2 attempts)
9. **verify** — Claude reads diff, screenshots affected pages via agent-browser
10. **update** — move task file to `tasks/done/`, close GitHub issue
11. **done** — return to default branch, log to `logs/{timestamp}.log`

## Configuration

Edit `factory.md` to customize the factory. Configuration lives in named H2 sections:

- `## standards` — coding rules cross-cutting all agentic stages
- `## stages` — the pipeline itself. Each H3 is one stage with a type tag (`agentic`, `deterministic`, `mixed`)
- `## routing` — how tasks map to repos
- `## runtime` — language/tooling hints

`factory.md` is a portable spec — see `docs/factory-md-spec.md` for the full format.
