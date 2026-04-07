# factory.md

**A Dockerfile for code factories.**

`factory.md` is a single markdown file at the root of a repository. It holds the standards an autonomous coding agent must follow to ship code in that repo — coding style, build environment, testing, documentation, dev environment, code quality, observability, and security — all in one place.

Clone a factory, run it anywhere.

## Why not AGENTS.md?

`AGENTS.md` is freeform prose about how to write code in a repo. `factory.md` is a fixed set of named sections any framework can parse. They are complementary: a repo may have both.

## Location

Place `factory.md` at the root of the repository. Frameworks should look for it before falling back to framework-specific config.

## Format

Standard CommonMark markdown. H2 headings (`##`) are reserved section names. Every section is a bullet list of rules. Frameworks read what they understand and ignore the rest. **All sections are optional.**

## The 8 sections

| # | Section | What it covers |
|---|---|---|
| 1 | `## style` | Formatting, naming, function size, imports, changelog hygiene |
| 2 | `## build` | Runtime, package manager, CI workflow, version bumping |
| 3 | `## testing` | Test framework, colocations, pass/fail gates |
| 4 | `## documentation` | Doc comments, README, AGENTS.md updates |
| 5 | `## environment` | Dev tools, branching rules, worktrees |
| 6 | `## quality` | File size, function size, TODO/FIXME, complexity |
| 7 | `## observability` | Logging, error reporting, tracing |
| 8 | `## security` | Hardcoded credentials, dangerous patterns, dependency checks |

Each section is a bullet list. Every bullet is one rule. Plain English.

## Rule dispatch

Frameworks read each bullet and decide what to do with it:

- **Recognized as a gate** — the framework runs a check. If it passes, the pipeline continues. If it fails, the pipeline blocks (or a remediation stage kicks in).
- **Recognized as a runtime hint** — the framework uses it to configure the environment (e.g. `node 20` → install Node 20).
- **Unrecognized** — the framework forwards the bullet to the agent as an additional rule to honor.

The spec does not prescribe which bullets must be gates vs hints vs forwarded. Authors write rules in plain English; frameworks do the best they can and forward the rest.

## Minimal example

```markdown
## style
- camelCase functions, PascalCase components
- Functions max 50 lines
- No secrets in diff
- CHANGELOG updated per PR

## testing
- Vitest, colocated .test.js
- All tests pass before PR

## security
- No hardcoded credentials
- No eval
```

## Full example

````markdown
---
name: shipyard
version: 1
---

# shipyard factory

## style
- camelCase functions, PascalCase components, UPPER_SNAKE constants
- Functions max 50 lines, single responsibility, early returns
- Imports: external then internal then relative
- No secrets, .env, .pem, .key in diff
- CHANGELOG.md updated per PR

## build
- node 20
- CI workflow at .github/workflows/ci.yml (auto-generate if missing)
- package.json version bumped per PR

## testing
- Vitest, colocated .test.js
- All tests must pass before PR opens
- New code requires new tests

## documentation
- JSDoc on exported functions
- README updated for user-facing changes
- AGENTS.md updated for agent-facing changes

## environment
- bash, gh CLI authenticated
- Worktrees for parallel-safe branches
- Feature branches, never commit to default

## quality
- No files over 500 lines
- No new TODO/FIXME in diff
- No function over 50 lines

## observability
- Log errors with context at system boundaries
- Error reporting on new code paths
- Never swallow errors silently

## security
- No hardcoded credentials, API keys, or tokens
- No eval, no child_process with string interpolation
- No dangerous shell patterns
````

## Parsing rules

1. Section headings are matched case-insensitively against the 8 reserved names.
2. Bullets can use `-`, `*`, or `+` markers.
3. Unknown sections are preserved and ignored.
4. YAML frontmatter is allowed for metadata: `name`, `version`, `framework_min_version`.
5. Anything before the first H2 is preamble.

## Spec versioning

This document describes `factory.md` **v1**. Future versions are backward-compatible at the section level: existing reserved names will not change meaning. New reserved sections may be added in later versions.

## Implementations

- **Shipyard** — reference implementation. `factory.sh` reads `factory.md` from the repo root, injects every section into the agent prompt as rules, and dispatches bullets from `## testing`, `## quality`, and `## security` as gates against a built-in check library. Unrecognized bullets are forwarded to the agent as additional constraints.
- *(your framework here — PRs welcome)*
