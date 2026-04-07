# factory.md

**A portable spec for autonomous coding agent pipelines.**

`factory.md` is a single markdown file at the root of a repository that tells any autonomous agent framework how to ship code in that repo: the standards to follow, the stages of the pipeline, and how to run them.

It is to autonomous agents what `Dockerfile` is to containers — a declarative, portable, framework-agnostic instruction set.

## Why not AGENTS.md?

`AGENTS.md` describes **how to write code** in a repo (style, conventions, gotchas). `factory.md` describes **the full ship-it loop** as a sequence of named stages (code, lint, ship, verify, etc.).

They are complementary. A repo can have both. `AGENTS.md` answers *"what should this code look like?"* `factory.md` answers *"what stages run, in what order, and what does each one do?"*

## Location

Place `factory.md` at the root of the repository. Frameworks should look for it before falling back to framework-specific config (`.cursorrules`, `CLAUDE.md`, etc.).

## Format

Standard CommonMark markdown. H2 headings (`##`) are reserved section names. Within `## stages`, H3 headings (`###`) define individual stages. Frameworks read what they understand and ignore the rest. **All sections are optional.**

## Reserved sections

### `## standards`
Coding rules the agent must follow. Bullet list or prose. Cross-cutting — applied to every agentic stage.

### `## stages`
The ordered pipeline. Each H3 inside this section is a stage. Stage headings carry a type tag in parens:

- **agentic** — the stage body is injected into the agent's prompt as instructions
- **deterministic** — the body is a list of gates the framework verifies in code
- **mixed** — deterministic detection with agentic remediation (e.g. lint fails → agent fixes)

Stages run in document order. Frameworks may skip stages they don't implement.

### `## routing`
How tasks map to repos, branches, or services. Used by multi-repo factories.

### `## runtime`
Language, package manager, and tooling hints. e.g. `node 20`, `deno 1.40+`, `python 3.12`, `swift 5.10`.

### `## secrets`
Names of environment variables required (never values). Frameworks resolve these from their own secret store.

### `## tasks`
Optional location of the task queue. Defaults to `tasks/` if omitted.

## Stage anatomy

A stage is an H3 heading with the form:

```markdown
### <name> (<type>)
<body>
```

- **`<name>`** is a lowercase identifier (`code`, `lint`, `ship`, `verify`, etc.). Frameworks recognize common names by convention.
- **`<type>`** is `agentic`, `deterministic`, or `mixed`.
- **`<body>`** is markdown until the next H3 or H2. For `agentic` stages, write imperative numbered steps. For `deterministic` stages, write a bullet list of gates.

## Common stage names

These names have conventional semantics. Frameworks should recognize them. Custom stages with other names are allowed.

| Name | Type | Purpose |
|---|---|---|
| `pick` | deterministic | Choose the next task from the queue |
| `route` | deterministic | Resolve task to a repo |
| `prepare` | deterministic | Pull, branch, scaffold CI |
| `code` | agentic | Implement, test, version, commit, push, PR |
| `lint` | deterministic | Pre-PR gates (no secrets, changelog updated, etc.) |
| `fix` | mixed | Re-engage agent if lint fails |
| `ship` | deterministic | Confirm PR opened |
| `ci` | mixed | Watch CI; re-engage agent on failure |
| `verify` | agentic | Visual / runtime verification |
| `update` | deterministic | Cleanup, move task to done, close issues |
| `done` | deterministic | Report final status |

## Parsing rules

1. Section headings are matched case-insensitively against reserved names.
2. Stage headings are matched case-insensitively. The type tag in parens is stripped before matching.
3. Unknown sections and unknown stages are preserved and ignored.
4. Order of sections does not matter. Order of stages within `## stages` is significant.
5. Anything before the first H2 is preamble.
6. YAML frontmatter is allowed for metadata: `name`, `version`, `framework_min_version`.

## Minimal example

````markdown
# my-app factory

## standards
- Functional React, no class components
- Tailwind v4 with semantic tokens

## stages

### code (agentic)
1. Implement the task
2. Run `deno test`
3. Bump minor version in package.json
4. Commit, push, open PR against master

### lint (deterministic)
- All tests pass
- No secrets in diff
- CHANGELOG updated
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
- bash
- node 20
- gh cli

## standards
- Functions max ~50 lines, single responsibility, early returns
- camelCase functions, PascalCase components, UPPER_SNAKE_CASE constants
- Doc comments on exported/public functions
- Visible error handling, never swallow errors
- Tests required for new code (Vitest, colocated `.test.js`)

## stages

### pick (deterministic)
Take the first `.md` file from `tasks/` in alphabetical order. Atomic file lock.

### route (deterministic)
Resolve the task to a repo: `repo:` frontmatter → that path; otherwise scaffold a new repo.

### prepare (deterministic)
- Detect default branch
- `git pull`
- Create feature branch
- Generate `.github/workflows/ci.yml` if missing

### code (agentic)
1. Implement the task
2. Run tests; fix failures (max 3 attempts)
3. Bump minor version in `package.json`
4. Add CHANGELOG entry
5. Stage modified files only (no `git add .`)
6. Commit (no AI attribution)
7. Push branch, open PR against `master`
8. Print `FACTORY_RESULT:SUCCESS` or `FAILED`

### lint (deterministic)
- No secrets, .env, .pem, .key in diff
- CHANGELOG.md updated
- package.json version bumped

### fix (mixed)
On lint failure, pass failures to the agent. Max 2 attempts.

### ship (deterministic)
Confirm a PR was opened. Capture URL.

### ci (mixed)
Watch GitHub Actions. On failure, pass logs to agent. Max 2 attempts.

### verify (agentic)
1. Read the diff
2. Identify affected pages
3. Start dev server
4. Screenshot via `agent-browser`

### update (deterministic)
Move task to `tasks/done/`. Close GitHub issue.

### done (deterministic)
Return to default branch. Report status.

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

This document describes `factory.md` **v1**. Future versions are backward-compatible at the section and stage level: existing reserved names will not change meaning. New reserved sections and conventional stage names may be added.

## Implementations

- **Shipyard** — reference implementation. `factory.sh` reads `factory.md` from the repo root, injects `## standards` and the `code` stage into every Claude session, and orchestrates the deterministic stages directly.
- *(your framework here — PRs welcome)*
