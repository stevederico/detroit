# Remote Execution via GitHub Actions

Gap 4 (environment isolation) — each factory run shares local machine state. GitHub Actions solves this with disposable VMs.

## How it would work

- `factory.sh --remote` triggers a workflow via `gh workflow run`
- The action installs deps, runs `claude -p` (API key in GitHub Secrets)
- Codes, tests, commits, opens PR — all inside a fresh VM
- Detroit locally dispatches and monitors

## What you gain

- Full isolation (fresh SQLite, clean ports, no stale state)
- No local machine needed to run tasks
- Free minutes on public repos (2,000/month)

## What you lose

- Real-time streaming to terminal (would need to poll logs)
- Local env files / secrets (must be in GitHub Secrets)
- `agent-browser` screenshot verification (headless could still work)
- Speed — VM spin-up adds ~30-60s per task

## Approach

Opt-in via `--remote` flag. Default stays local. Hybrid model — local for fast iteration, remote for isolation.
