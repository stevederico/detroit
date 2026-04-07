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

### pick (deterministic)
Take the first `.md` file from `tasks/` in alphabetical order. Atomic file lock to prevent double-processing in parallel runs.

### route (deterministic)
Resolve the task to a repo:
- `repo:` frontmatter → use that local path or GitHub URL
- No frontmatter → scaffold a new repo (name slugified from filename)

### prepare (deterministic)
- Detect default branch (`main` or `master`)
- `git pull` to sync
- Create a feature branch
- Generate `.github/workflows/ci.yml` if the repo has none

### code (agentic)
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

### lint (deterministic)
- No secrets, .env, .pem, .key, credentials, or tokens in committed files
- `CHANGELOG.md` updated
- `package.json` version bumped (when applicable)
- Tests passed

### fix (mixed)
If `lint` fails, pass the failure list to the agent. Agent fixes and re-runs lint. Max 2 attempts.

### ship (deterministic)
Confirm a PR was opened. Capture and report the PR URL.

### ci (mixed)
Watch GitHub Actions on the PR. If failing, pass logs to the agent. Max 2 fix attempts.

### verify (agentic)
1. Read the diff
2. Identify affected pages
3. Start dev server + backend
4. Screenshot affected pages via `agent-browser`
5. Attach screenshots to the PR

### update (deterministic)
- Move task file from `tasks/` to `tasks/done/`
- Close the GitHub issue if `--issues` was used

### done (deterministic)
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
