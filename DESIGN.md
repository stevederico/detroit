# Detroit design

Detroit is rebuilt from the ground up on my-factory. Old Detroit is intact on the `alpha-archive` branch. The removed Code-stage rules are in `archive/detroit-alpha-code-factory-archive.md`.

## Names

- **Detroit**: the whole system.
- **Runner**: the outer loop. Decides what runs.
- **Factory**: the inner loop, my-factory. Decides what passes.

## Outline

```
0 Shift
1 Setup
2 Plan
3 Code (Factory: ToolGuard, CommitGuard, PushGuard, Verify)
4 Done
```

## Steps

**0 Shift.** A systemd timer starts it at 01:00. It loops tasks while the budget lasts. Before each task it checks the usage budget (or the hours cap for opencode), that the agent and `gh` are ready, that no other shift is running, and that the agent's Herdr session is free. It stops when the budget is gone or the queue is empty.

**1 Setup.** Take the first `.md` file in `tasks/` (alphabetical) and lock it. Find its repo: `repo:` in the frontmatter names an existing local or GitHub repo, and no `repo:` means a new repo named from the filename. Pull the default branch and create a feature branch in a worktree.

**2 Plan (optional).** The agent judges whether the task needs a plan. If it does, it writes `plan.md` and the user approves or rejects it before coding (terminal or web, 30-minute timeout, rejected aborts the task). If not, it skips to Code.

**3 Code.** The agent implements the task. The prompt holds only the task, the approved plan and the last 15 lines of `lessons.md`. The Factory checks every step: ToolGuard before each command, CommitGuard at each commit, PushGuard at each push, Verify before done. A block tells the agent what to fix and it retries. The Factory also handles pushing and opening the PR.

**4 Done.** Success means the PR was created. The task file moves to `tasks/done/` and its GitHub issue closes. No PR means it moves to `tasks/failed/`, and failed tasks are never retried. The result is logged to `logs/`.

## Lessons

Failures are written to `lessons.md` and the last 15 lines go into the next Code prompt. Each lesson should become a Factory check so the same failure is blocked rather than just remembered.

## Removed from the old pipeline

| Old step | Why |
|---|---|
| Route, Prepare | Merged into Setup |
| Scaffold | Not needed |
| Triage, Approve | Merged into Plan |
| Gates, Fix | The Factory checks at commit and push time |
| Ship | The Factory pushes and opens the PR |
| CI | Removed. The lessons idea is kept |
| Verify (old) | Now Factory Verify, inside Code |
| Review | Lives in my-factory as optional adversarial review |
| Update | Merged into Done |

## Open questions

- Task intake beyond `tasks/`: an API source (GitHub issues already work through `--issues`).
- README and AGENTS.md updates, error logging and API timing logs: prose, or new Factory checks.
- New-repo creation (`gh repo create --private`): Setup or the Factory.
- What writes `lessons.md` now that CI is gone.
