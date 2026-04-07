---
name: shipyard
version: 1
---

# shipyard factory

Autonomous code factory pipeline. Reads task files from `tasks/` and ships them as PRs.

## standards
- Error handling: visible to user, human-readable messages, recovery actions, loading indicators >200ms
- Accessibility: labels or aria-label on all interactive elements, semantic HTML, WCAG 2.1 AA contrast, 44px touch targets
- API safety: exponential backoff on 429/5xx (1s>2s>4s>8s, max 3-5 retries), never loop without throttling
- Functions: max ~50 lines, single responsibility, early returns, no magic numbers
- Naming: camelCase functions, PascalCase components, UPPER_SNAKE_CASE constants, is/has/should booleans
- Imports: external > internal > relative
- Doc comments on exported/public functions (JSDoc for JS, # for Shell)
- Write tests for new code (Vitest, colocated .test.js files)
- Umami analytics: add data-umami-event on interactive elements if analytics is wired up

## stages

Stages run in order. Each stage is one of three types:

- **agentic** — body is injected into the agent's prompt as instructions
- **deterministic** — body is a list of gates the framework verifies
- **mixed** — deterministic detection with agentic remediation

Stages are grouped into 10 containers (TRIAGE, STYLE, BUILD, TEST, DOCUMENTATION, ENVIRONMENT, QUALITY, OBSERVABILITY, SECURITY, SHIP). Containers are taxonomy; stages run in pipeline order, not container order.

### pick (deterministic) — TRIAGE
Take the first `.md` file from `tasks/` in alphabetical order. Atomic file lock to prevent double-processing in parallel runs.

### route (deterministic) — TRIAGE
Resolve the task to a repo:
- `repo:` frontmatter → use that local path or GitHub URL
- No frontmatter → create a new repo (name slugified from filename)

### prepare (deterministic) — ENVIRONMENT
- Detect default branch (`main` or `master`)
- `git pull` to sync
- Create a feature branch via `git worktree add` (parallel-safe isolation)

### scaffold (deterministic) — BUILD
- Generate `.github/workflows/ci.yml` if the repo has none
- Detect runtime (deno vs node) and add `build` / `test` steps if scripts exist

### code (agentic) — TEST
1. If NEW_REPO is true, scaffold the repo from scratch (README, package.json, etc.)
2. Implement the task
3. Run tests if they exist; if they fail, fix and re-run (max 3 attempts)
4. Read `package.json` version and `CHANGELOG.md` before changing either
5. Bump minor version in `package.json` (e.g. 1.7.0 → 1.8.0)
6. If that version already exists in `CHANGELOG.md`, bump again (e.g. → 1.9.0)
7. Add the new version to the top of `CHANGELOG.md` with a 3-word description (2-space indent, no dash)
8. Stage modified files plus `.github/workflows/` if it exists (never `git add .` or `git add -A`)
9. Commit with a descriptive message (no AI attribution, no Co-Authored-By)
10. If NEW_REPO is true, create a GitHub repo: `gh repo create PROJECT --private --source=. --push`
11. Push the branch: `git push origin BRANCH`
12. If NEW_REPO is false, open a PR: `gh pr create --base BASE_BRANCH`
13. Print `FACTORY_RESULT:SUCCESS` or `FACTORY_RESULT:FAILED`

### document (agentic) — DOCUMENTATION
1. Read the diff against the base branch
2. For each new or modified exported function/class/component, ensure it has a doc comment matching the implementation
3. If `README.md` describes features, update it to reflect new functionality
4. If `AGENTS.md` or `CLAUDE.md` exists and your changes affect agent workflows, update it
5. Stage only files you modified, commit with message `docs: update documentation`
6. Push to the existing PR branch
7. Print `DOCUMENT_DONE` when finished, or `DOCUMENT_NOOP` if nothing needed updating

### instrument (agentic) — OBSERVABILITY
1. Read the diff against the base branch
2. For each new error path, ensure there is a log or error report following the project's existing conventions
3. For each new external API call, ensure timing and result are logged
4. Honor `prefers-reduced-motion` and any analytics conventions already in the project
5. Stage only files you modified, commit with message `observability: add logging`
6. Push to the existing PR branch
7. Print `INSTRUMENT_DONE` when finished, or `INSTRUMENT_NOOP` if nothing needed updating

### audit (deterministic) — QUALITY
- No file in the diff exceeds 500 lines
- No function exceeds 50 lines (best-effort heuristic)
- No `TODO` or `FIXME` introduced in committed code

### lint (deterministic) — STYLE
- No secrets, .env, .pem, .key, credentials, or tokens in committed files
- `CHANGELOG.md` updated
- `package.json` version bumped (when applicable)
- Tests passed

### fix (mixed) — STYLE
If `lint` fails, pass the failure list to the agent. Agent fixes and re-runs lint. Max 2 attempts.

### secure (deterministic) — SECURITY
- No hardcoded credentials in diff (matches `api_key`, `secret_key`, `password`, `private_key`, `access_token` assignments)
- No `eval()` or equivalent introduced
- No `child_process.exec` with user input

### ship (deterministic) — SHIP
Confirm a PR was opened. Capture and report the PR URL.

### ci (mixed) — SHIP
Watch GitHub Actions on the PR. If failing, pass logs to the agent. Max 2 fix attempts.

### verify (agentic) — TEST
1. Read the diff
2. Identify affected pages
3. Start dev server + backend
4. Screenshot affected pages via `agent-browser`
5. Attach screenshots to the PR

### update (deterministic) — SHIP
- Move task file from `tasks/` to `tasks/done/`
- Close the GitHub issue if `--issues` was used

### done (deterministic) — SHIP
- Return to default branch
- Report final status to the log

## routing
- Tasks with `repo:` frontmatter route to that repo (local path or GitHub URL)
- Tasks without frontmatter scaffold a new repo (name slugified from filename)
- Files in `tasks/` run in alphabetical order

## runtime
- bash
- node 20
- gh cli
- python3 (for JSON parsing)

## tasks
./tasks/
