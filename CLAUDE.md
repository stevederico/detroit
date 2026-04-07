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

The pipeline runs as a sequence of stages declared in `factory.md` under `## stages`. Each stage belongs to one of 10 containers (TRIAGE, STYLE, BUILD, TEST, DOCUMENTATION, ENVIRONMENT, QUALITY, OBSERVABILITY, SECURITY, SHIP).

1. **pick** (TRIAGE) — first `.md` file from `tasks/` (alphabetical, atomic lock)
2. **route** (TRIAGE) — resolve task to a repo (local, GitHub, or new)
3. **prepare** (ENVIRONMENT) — pull default branch, create feature branch via worktree
4. **scaffold** (BUILD) — generate `.github/workflows/ci.yml` if missing
5. **code** (TEST) — Claude implements, tests, versions, commits, pushes, opens PR
6. **document** (DOCUMENTATION) — Claude updates README, doc comments, AGENTS.md
7. **instrument** (OBSERVABILITY) — Claude adds logging / error reporting for new paths
8. **audit** (QUALITY) — file/function size warnings, TODO/FIXME detection
9. **lint** (STYLE) — gates from factory.md (secrets, changelog, version, tests)
10. **fix** (STYLE) — re-engage Claude on lint failure (max 2 attempts)
11. **secure** (SECURITY) — hardcoded credentials, eval, dangerous patterns
12. **ship** (SHIP) — confirm PR opened
13. **ci** (SHIP) — watch GitHub Actions, re-engage Claude on failure (max 2 attempts)
14. **verify** (TEST) — Claude reads diff, screenshots affected pages via agent-browser
15. **update** (SHIP) — move task file to `tasks/done/`, close GitHub issue
16. **done** (SHIP) — return to default branch, log to `logs/{timestamp}.log`

## Configuration

Edit `factory.md` to customize the factory. Configuration lives in named H2 sections:

- `## standards` — coding rules cross-cutting all agentic stages
- `## stages` — the pipeline itself. Each H3 is one stage with a type tag (`agentic`, `deterministic`, `mixed`)
- `## routing` — how tasks map to repos
- `## runtime` — language/tooling hints

`factory.md` is a portable spec — see `docs/factory-md-spec.md` for the full format.
