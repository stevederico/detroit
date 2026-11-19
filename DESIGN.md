# Detroit design

Detroit is rebuilt from the ground up on Garden (`~/Projects/garden`, github.com/stevederico/garden, formerly my-factory). Old Detroit is intact on the `alpha-archive` branch. The removed Code-stage rules are in `archive/detroit-alpha-code-factory-archive.md`.

## Names

- **Detroit**: the whole system.
- **Runner**: the outer loop. Decides what runs.
- **Factory**: the inner loop, built by Garden. Decides what passes.

## Outline

```
RUNNER
  0 Shift (timer 01:00, loops tasks while budget lasts)
  1 Setup (pick task, find repo, make branch)
  2 Plan (optional, includes approve)
  3 Code
    FACTORY (Garden)
      ToolGuard      checks every agent command
      CommitGuard    checks every commit
      PushGuard      checks every push, requires a version bump
      Verify         runs the real app: pages, flows, state chart
      garden pr      verify, push, open the PR with proof
      garden review  a fresh robot tries to prove the PR wrong
      automerge      optional, off by default
  4 Done (PR created: file task in done/, else failed/)
```

## CLI

One script, `bin/detroit`:

```
detroit run               one task: setup, plan, code, done
detroit shift [--hours N] loop the queue until it is empty or N hours pass (default 6)
detroit add "text"        write a task into tasks/ (--repo, --name)
detroit status            queue, running tasks, last results
detroit install           nightly shift at 01:00 (systemd user timer)
detroit uninstall         stop the nightly shift
```

State (locks, logs, plans, worktrees, results) lives in `~/.local/state/detroit`. The agent is `DETROIT_AGENT` (grok, claude or opencode). Shift stops on an hours cap only; the usage-window budget is not built yet.

## Steps

**0 Shift.** A systemd timer starts it at 01:00. It loops tasks while the budget lasts. Before each task it checks the usage budget (or the hours cap for opencode), that the agent and `gh` are ready, that no other shift is running, and that the agent's Herdr session is free. It stops when the budget is gone or the queue is empty.

**1 Setup.** Take the first `.md` file in `tasks/` (alphabetical) and lock it. Find its repo: `repo:` in the frontmatter names an existing local or GitHub repo, and no `repo:` means a new repo named from the filename. Pull the default branch and create a feature branch in a worktree.

**2 Plan (optional).** The agent judges whether the task needs a plan. If it does, it writes `plan.md` and the user approves or rejects it before coding (terminal or web, 30-minute timeout, rejected aborts the task). If not, it skips to Code.

**3 Code.** The agent implements the task. The prompt holds only the task, the approved plan and the last 15 lines of `lessons.md`. Garden checks every step: ToolGuard before each command, CommitGuard at each commit, PushGuard at each push, Verify against the running app. A block tells the agent what to fix and it retries. The agent finishes with `garden pr`, which verifies, pushes and opens the pull request with proof. `garden review` then has a fresh robot try to prove the change wrong. Automerge is optional and off by default.

**4 Done.** Success means the PR was created. The task file moves to `tasks/done/` and its GitHub issue closes. No PR means it moves to `tasks/failed/`, and failed tasks are never retried. The result is logged to `logs/`.

## Lessons

Failures are written to `lessons.md` and the last 15 lines go into the next Code prompt. Each lesson should become a Garden check so the same failure is blocked rather than just remembered.

## Removed from the old pipeline

| Old step | Why |
|---|---|
| Route, Prepare | Merged into Setup |
| Scaffold | Not needed |
| Triage, Approve | Merged into Plan |
| Gates, Fix | Garden checks at commit and push time |
| Ship | `garden pr` pushes and opens the PR |
| CI | Removed. The lessons idea is kept |
| Verify (old) | Now Garden Verify, inside Code |
| Review | Now `garden review` |
| Update | Merged into Done |

## Carried over from the old Code prompt

Three rules moved into Garden: no empty catch (0.54.0), no `exec` or `execSync` (0.55.0), and a version bump on every code push (0.59.0, `GARDEN_BUMP_CHECK`). The plan template (Intent, Out of scope, Targets, Acceptance) was dropped; it is in `factory.md` on `alpha-archive`.

## Open questions

- Task intake beyond `tasks/`: an API source (GitHub issues already work through `--issues`).
- README and AGENTS.md updates, error logging and API timing logs: prose, or new Garden checks.
- New-repo creation (`gh repo create --private`): Setup or Garden.
- What writes `lessons.md` now that CI is gone.
- Whether Detroit turns on Garden's automerge, or leaves merging to a person.
