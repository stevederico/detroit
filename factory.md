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

## workflow
1. If NEW_REPO is true, scaffold the repo from scratch (create README, package.json, etc.)
2. Implement the task
3. Run tests if they exist
4. If tests fail, fix and re-run (max 3 attempts)
5. Update versioning:
   - Read package.json version and CHANGELOG.md before changing either
   - Bump minor version in package.json (e.g. 1.7.0 → 1.8.0)
   - If that version already exists in CHANGELOG.md, bump again (e.g. → 1.9.0)
   - Add the new version at the top of CHANGELOG.md with a 3-word description (2-space indent, no dash)
6. Stage the files you modified plus .github/workflows/ if it exists (never git add . or git add -A)
7. Commit with a descriptive message (no AI attribution, no Co-Authored-By)
8. If NEW_REPO is true, create a GitHub repo: gh repo create PROJECT --private --source=. --push
9. Push the branch: git push origin BRANCH
10. If NEW_REPO is false, open a PR: gh pr create --base BASE_BRANCH
11. Print FACTORY_RESULT:SUCCESS or FACTORY_RESULT:FAILED

## validation
- All tests pass
- No secrets, .env, .pem, .key, credentials, or tokens in committed files
- CHANGELOG.md updated
- package.json version bumped
- CI workflow green on the PR

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
