# Detroit alpha: Code stage, archived

Removed from `lib/code-stage.sh` (the CODE prompt) on 2026-11-18. The Factory (my-factory) replaces the checks; the Runner keeps only the task, the plan and the lessons in the prompt. Old Detroit is intact on the `alpha-archive` branch.

## Where each item goes

| Item | Where it goes |
|---|---|
| Implement the task | Code (agent) |
| Run tests, retry up to 3 times | Factory: PushGuard |
| Version bump and changelog | Factory: CommitGuard |
| Never `git add .`, no AI attribution | Factory: ToolGuard, commit-msg |
| Push the branch | Open: Code or Ship |
| Open the PR | Open: Code or Ship |
| Doc comments on exported functions | Dropped: conflicts with the Factory's no-comments rule |
| Update README, AGENTS.md, CLAUDE.md when affected | Open: prose, not enforced |
| Log errors and API call timing | Open: prose, or a new Factory check |
| New repo: scaffold, `gh repo create --private` | Open: Setup or Code |
| `FACTORY_RESULT:SUCCESS/FAILED` | Open: the Runner decides the result itself |
| Log format rules | Dropped |

## Old prompt text

```
Log format rules (follow exactly):
- Stage headers: ━━━ STAGE_NAME ━━━ (e.g. ━━━ CODE ━━━, ━━━ TEST ━━━)
- Progress: plain text, no markdown, no ** or ## or []
- Results: plain text summary of what changed

Factory rules (every bullet is mandatory — grouped by the 8 factory.md sections):
$(factory_rules "$DETROIT/factory.md")

Pipeline (execute in order):
1. If NEW_REPO is true, scaffold the repo from scratch (README, package.json, etc.)
2. Implement the task
3. Run tests if they exist; if they fail, fix and re-run (max 3 attempts)
4. For each new or modified exported function, ensure a doc comment matches the implementation
5. If README describes features affected by your change, update it
6. If AGENTS.md or CLAUDE.md describes behavior affected by your change, update it
7. For each new error path, log the error with context
8. For each new external API call, log timing and result
9. Read package.json version and CHANGELOG.md before changing either
10. Bump minor version in package.json (e.g. 1.7.0 → 1.8.0); bump again if that version already exists in CHANGELOG
11. Add the new version to the top of CHANGELOG.md with a 3-word description (2-space indent, no dash)
12. Stage modified files plus .github/workflows/ if it exists (never git add . or git add -A)
13. Commit with a descriptive message (no AI attribution, no Co-Authored-By)
14. If NEW_REPO is true, create a GitHub repo: gh repo create PROJECT --private --source=. --push
15. Push the branch: git push origin $BRANCH
16. If NEW_REPO is false, open a PR: gh pr create --base $BASE_BRANCH
17. Print FACTORY_RESULT:SUCCESS or FACTORY_RESULT:FAILED
```
