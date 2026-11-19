# Detroit TODO

Ideas for the rebuild. The old list is in `archive/todo-alpha.md`.

## Build

- [x] `bin/detroit` CLI: run, shift, add, status, install
- [x] Shift: hours cap, one shift at a time
- [x] `shift --parallel N`: N tasks at once
- [ ] Keep the lines running: restart a stuck or crashed task, a heartbeat per line, alert when a line stalls
- [ ] Per-repo lines: a ruleset and a limit per repo, so one noisy repo cannot starve the rest
- [ ] Shift: usage-window budget (stop at 80% of the agent's window)
- [ ] Run the real agents end to end with `garden pr`, then `detroit install`
- [ ] New repos: check that `gh repo create --private` and the first PR work

## Intake

- [ ] Task sources beyond `tasks/`: an API, GitHub issues, Slack, Linear, PR comments
- [ ] Analytics feed: take an app's analytics (installs, usage, errors, drop-offs), turn problems and opportunities into tasks, and measure the result on the next cycle

## Learning

- [ ] Lessons loop: every failure becomes a line in `lessons.md` and then a Garden check
- [ ] Post-run extraction: capture reusable patterns after each task
- [ ] Memory: `DECISIONS.md` and `KNOWN_ISSUES.md` loaded into the Code prompt
- [ ] Metrics: cycle time, share of work with no human touch, cost per merged change
- [ ] Evals harness: a personal benchmark for my own tasks

## Later

- [ ] Sandboxed runs (Docker or a disposable VM) per task
- [ ] `--watch` mode that polls `tasks/` instead of a timer
