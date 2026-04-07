---
name: shipyard
version: 1
---

# shipyard factory

Autonomous code factory. Reads task files from `tasks/` and ships them as PRs.

## style
- camelCase functions, PascalCase components, UPPER_SNAKE_CASE constants
- Booleans prefixed with `is`, `has`, or `should`
- Functions max 50 lines, single responsibility, early returns, no magic numbers
- Imports ordered: external then internal then relative
- No secrets, .env, .pem, .key, credentials, or tokens in committed files
- CHANGELOG.md updated per PR

## build
- node 20
- gh CLI authenticated
- CI workflow at `.github/workflows/ci.yml` (auto-generate if missing)
- `package.json` version bumped per PR (minor bump by default)

## testing
- Vitest, colocated `.test.js` files
- All tests must pass before a PR is opened
- New code requires new tests

## documentation
- JSDoc on exported/public functions (`#` for Shell, `///` for Swift)
- README updated for user-facing changes
- AGENTS.md or CLAUDE.md updated for agent-facing changes
- Doc comments must match the implementation

## environment
- bash + python3 + gh CLI
- Worktrees for parallel-safe feature branches
- Never commit directly to the default branch
- Detect default branch automatically (main or master)

## quality
- No files over 500 lines
- No functions over 50 lines
- No new TODO or FIXME introduced in the diff
- Single responsibility per function

## observability
- Log errors with context at system boundaries
- Error reporting on new error paths
- Log timing and result for new external API calls
- Never swallow errors silently

## security
- No hardcoded credentials, API keys, or access tokens
- No `eval()` or equivalent
- No `child_process.exec` with interpolated user input
- No shell injection or SQL concatenation patterns
