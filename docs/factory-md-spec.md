# factory.md

**A portable spec for autonomous coding agent pipelines.**

`factory.md` is a single markdown file at the root of a repository that tells any autonomous agent framework how to ship code in that repo: the standards to follow, the pipeline to run, how to validate, and how to deploy.

It is to autonomous agents what `Dockerfile` is to containers — a declarative, portable, framework-agnostic instruction set.

## Why not AGENTS.md?

`AGENTS.md` describes **how to write code** in a repo (style, conventions, gotchas). `factory.md` describes **how to run the full ship-it loop** (test, validate, commit, PR, deploy, verify).

They are complementary. A repo can have both. `AGENTS.md` answers *"what should this code look like?"* `factory.md` answers *"what does done mean and how do I get there unattended?"*

## Location

Place `factory.md` at the root of the repository. Frameworks should look for it before falling back to framework-specific config (`.cursorrules`, `CLAUDE.md`, `standards.md` + `workflow.md`, etc.).

## Format

Standard CommonMark markdown. Sections are H2 headings (`##`) with reserved names. Frameworks read the sections they understand and ignore the rest. **All sections are optional.**

## Reserved sections

### `## standards`
Coding rules the agent must follow. Bullet list or prose.

### `## workflow`
The ordered pipeline the agent runs after coding. Numbered list. Each step is one imperative instruction. Frameworks execute in order; the agent decides how.

### `## validation`
How to verify a task is done. Commands to run, URLs to check, expected outputs. The deterministic gate before a task is marked complete.

### `## routing`
How tasks map to repos, branches, or services. Used by multi-repo factories.

### `## runtime`
Language, package manager, and tooling hints. e.g. `node 20`, `deno 1.40+`, `python 3.12`, `swift 5.10`.

### `## secrets`
Names of environment variables required (never values). Frameworks resolve these from their own secret store.

### `## tasks`
Optional location of the task queue. Defaults to `tasks/` if omitted.

## Parsing rules

1. Section headings are matched case-insensitively against reserved names.
2. Unknown sections are preserved and ignored — frameworks may extend with custom sections.
3. Order of sections does not matter.
4. Anything before the first H2 is treated as a description / preamble.
5. YAML frontmatter is allowed for metadata: `name`, `version`, `framework_min_version`.

## Minimal example

````markdown
# my-app factory

## standards
- Functional React, no class components
- Tailwind v4 with semantic tokens

## workflow
1. Implement the task
2. Run `deno test`
3. Bump minor version in package.json
4. Commit with descriptive message
5. Open PR against master

## validation
- `deno test` must pass
- `curl localhost:8000/health` returns 200
````

## Full example

````markdown
---
name: shipyard
version: 1
framework_min_version: 0.1
---

# shipyard factory

Autonomous code factory pipeline for the shipyard project.

## runtime
- node 20
- deno 1.40+
- gh cli

## standards
- Functions max ~50 lines, single responsibility, early returns
- camelCase functions, PascalCase components, UPPER_SNAKE_CASE constants
- Doc comments on exported/public functions
- Visible error handling, never swallow errors
- Tests required for new code (Vitest, colocated `.test.js`)

## workflow
1. Implement the task
2. Run tests; if they fail, fix and retry up to 3 times
3. Bump minor version in `package.json`
4. Add new version entry to `CHANGELOG.md`
5. Stage modified files only (no `git add .`)
6. Commit with a descriptive message, no AI attribution
7. Push branch, open PR against `master`
8. Print `FACTORY_RESULT:SUCCESS` or `FACTORY_RESULT:FAILED`

## validation
- All tests pass
- No secrets in diff
- `CHANGELOG.md` updated
- CI workflow green on the PR

## routing
- Tasks with `repo:` frontmatter route to that repo
- Tasks without frontmatter scaffold a new repo

## secrets
- GITHUB_TOKEN
- ANTHROPIC_API_KEY

## tasks
./tasks/
````

## Spec versioning

This document describes `factory.md` **v1**. Future versions are backward-compatible at the section level: existing reserved section names will not change meaning. New reserved sections may be added.

## Implementations

- **Shipyard** — reference implementation. `factory.sh` reads `factory.md` from the repo root and injects the `## standards` and `## workflow` sections into every Claude session.
- *(your framework here — PRs welcome)*
