# Gap Analysis: Shipyard vs Ramp Inspect vs Stripe Minions

Ramp and Stripe are running code factories at enterprise scale — hundreds of concurrent sandboxed
VMs, integrated into Slack/Sentry/Datadog, shipping 30-50% of their merged PRs autonomously.
Shipyard is a shell script on your laptop doing the same core loop: task in, code, test, PR out.

The original gaps (self-verification, CI retry, parallel execution) have all been closed.
Two structural gaps remain: environment isolation and observability.

---

## At parity

| Capability | Ramp | Stripe | Shipyard |
|---|---|---|---|
| Task queue | Slack, web, Chrome ext, GitHub PR comments | Slack, web UI, internal system triggers | `tasks/` markdown files + `--issues` GitHub sync |
| Branch isolation | Per-sandbox branches on Modal | Devbox branches on EC2 | Worktree-isolated `shipyard/` branches |
| Autonomous coding | OpenCode in Modal sandbox | Goose fork (models undisclosed) | Claude Code `-p` |
| PR creation | GitHub App + user tokens | GitHub | `gh pr create` (via `## workflow` in `factory.md`) |
| Deterministic + agentic stages | Deterministic infra + agentic OpenCode | Blueprints: deterministic nodes + agentic nodes | Multi-stage pipeline (PICK, ROUTE, PULL, BRANCH, CODE, LINT, FIX, SHIP, VERIFY, UPDATE) |
| Coding standards | MCP plugins + skill files | Scoped rule files per directory (same format as Cursor/Claude Code) | `## standards` in `factory.md` + project `CLAUDE.md` |
| Self-verification | Chromium via VNC, before/after screenshots, Sentry, Datadog, LaunchDarkly | Local lint daemon (<1s), selective CI from 3M+ test battery, known autofixes | VERIFY stage: dev server + agent-browser DOM snapshots + screenshots + verify/fix loop |
| CI iteration loop | Tests in sandbox, agent retries | Max 2 CI rounds, autofixes applied first, then agent attempt | FIX stage: lint failures passed to Claude, re-run lint, max 2 attempts |
| Parallel sessions | Hundreds concurrent on Modal, filesystem snapshots every 30 min | Parallel devboxes on EC2, ~6 per engineer | `--parallel N` with atomic mkdir locks + worktrees |
| Visual verification | Chromium screenshots, live previews via VS Code server | Not publicly described | Screenshots committed to branch + attached as PR comments |

---

## Remaining gaps

| Gap | Impact | Effort |
|---|---|---|
| Environment isolation | Medium | High |
| Observability integration | Low (solo) / High (team) | Medium |
| Intake breadth | Low (solo) | Medium |

**Environment isolation.** Ramp spins up full Modal sandboxes per session: Postgres, Redis,
Temporal, RabbitMQ, Chromium, VS Code server. Filesystem snapshots rebuild every 30 minutes;
startup from snapshot takes seconds. Stripe uses pre-warmed EC2 devboxes that provision in ~10
seconds, pre-loaded with their full git repo, Bazel caches, and code-gen services. Both are
isolated from production.

Shipyard runs on your Mac. It shares local state — if a factory run messes up a database or
leaves ports occupied, it affects your next run. Worktrees handle code isolation and most projects
use SQLite (file-based, no shared server), so this is less painful than it sounds. Closing it
would require Docker or Modal per run — not justified for solo use yet.

**Observability integration.** Ramp queries Sentry for new errors and Datadog for metric
regressions after shipping. Stripe's agents check CI results and telemetry. Shipyard verifies
against the dev server pre-merge but doesn't watch production post-deploy. Next step: a
post-deploy health check that curls the production URL and checks for 200s.

**Intake breadth.** Ramp has five entry points: Slack, Chrome extension (visual element selection),
web interface, GitHub PR comments, and VS Code. Stripe triggers from Slack, a web UI, and internal
system buttons (e.g., flaky-test auto-tickets). Shipyard triggers from markdown files and GitHub
issues — ideal for solo, but a team would want Slack or web intake.

---

## Where Shipyard is ahead

**Zero infrastructure.** Ramp needs Modal + Cloudflare Durable Objects. Stripe needs EC2 devboxes.
Shipyard needs `bash factory.sh`. One file, no cloud dependencies, runs on a laptop.

**Self-healing verify loop.** Ramp and Stripe run verification as a gate. Shipyard's VERIFY stage
detects failures and triggers a fix session automatically — verify, catch issues, fix, re-verify —
before marking the task done.

**GitHub issue intake.** `--issues owner/repo` pulls labeled GitHub issues into the task queue.
When the factory ships a PR, it comments the PR link on the issue and closes it. Two-way
integration without webhooks or a Slack bot.

---

## Ramp Inspect

Cloud-based agent on **Modal**. Uses **OpenCode** as the coding engine (LLM not publicly
disclosed). Each session gets a full sandbox: Postgres, Redis, Temporal, RabbitMQ, Vite, VS Code
server (code-server), web terminal, and a VNC stack with Chromium. Filesystem snapshots rebuild
every 30 minutes via Modal Cron; startup from snapshot takes seconds. API backend uses Cloudflare
Durable Objects (per-session SQLite) and Cloudflare Agents SDK for WebSocket streaming.

Wired into **Sentry, Datadog, LaunchDarkly, Braintrust, GitHub, Buildkite, Slack** — the agent
runs tests, reviews telemetry, queries feature flags, and navigates the app in a real browser as
part of its verification loop. Chrome extension lets PMs/designers visually select UI elements
(analyzes DOM trees, not image tokens).

~30% of merged PRs are Inspect-written (Ramp blog, Jan 2026). Modal blog says "roughly half" —
possibly a later measurement. 80%+ of Inspect's own code is written by Inspect.

Not open-sourced. Ramp published a blog-post blueprint; OpenCode (the underlying framework) is a
separate open-source project they adopted. Community implementation at
[ColeMurray/background-agents](https://github.com/ColeMurray/background-agents).

In Feb 2026, Ramp ran a security sweep using Inspect: a three-stage pipeline (detectors,
adversarial managers, Inspect as fixer) found ~100 vulnerabilities missed by pen testing, bug
bounties, static analysis, and 10+ scanning vendors. All patches deployed within one week.

- [Why We Built Our Own Background Agent (Jan 2026)](https://builders.ramp.com/post/why-we-built-our-background-agent)
- [How Ramp built a full context background coding agent on Modal](https://modal.com/blog/how-ramp-built-a-full-context-background-coding-agent-on-modal)
- [100 Vulnerabilities Patched with 0 Humans (Feb 2026)](https://builders.ramp.com/post/100-vulnerabilities-patched-with-0-humans)

## Stripe Minions

Internal fork of **Goose** (Block's open-source agent), heavily customized for fully unattended,
one-shot operation. Models not publicly disclosed. **1,300+ PRs merged per week** (~185/day), all
zero human-written code, all human-reviewed.

Architecture uses **blueprints** — workflow graphs mixing deterministic nodes (linters, git push,
formatting) with agentic nodes (LLM reasoning). Deterministic nodes save tokens, reduce errors,
and enforce mandatory steps without LLM invocation.

Runs in **devboxes**: standard AWS EC2 instances pre-warmed to ~10-second ready-state, pre-loaded
with Stripe's full git repo, Bazel caches, type-checking caches, and code-gen services. Isolated
from production and the internet.

**Toolshed**: centralized MCP server exposing ~500 tools spanning internal systems and SaaS
platforms. Agents receive a curated subset per task, not the full 500. Context hydration runs
relevant MCP tools on links/references before the agentic loop starts.

Testing: 3M+ preexisting tests, selective subset per run. Local lint daemon returns results in
under 1 second. Known autofixes applied automatically. Remaining failures sent back to agent for
one local retry. **Hard cap: 2 CI rounds max.** After second failure, escalates to human.

Key insight: **"The walls matter more than the model."** Guardrails, deterministic nodes, hard
iteration caps, curated tool subsets, and mandatory human review do more work than model choice.

- [Minions Part 1 (Jan 2026)](https://stripe.dev/blog/minions-stripes-one-shot-end-to-end-coding-agents)
- [Minions Part 2 (Feb 2026)](https://stripe.dev/blog/minions-stripes-one-shot-end-to-end-coding-agents-part-2)

---

## The "Dark Factory" pattern

The **dark factory** borrows from lights-out manufacturing — fully autonomous pipelines where specs
go in and tested code comes out, zero human writing or review. BCG Platinion published a formal
framework in March 2026, defining five pillars: Intent-Driven Operating Model, Codified Knowledge,
Workforce Upskilling, Factory Architecture (Harness Engineering), and Governance/Quality/Trust.

Companies publicly running dark factories:

- **StrongDM** — 3-person team formed July 2025. Built 32,000 lines of production code (16K Rust,
  9.5K Go, 6.7K TypeScript) without writing or reviewing a single line. Their Attractor system's
  repo contains zero code — only three markdown spec files.
- **Spotify** — 650 AI-generated PRs/month via internal platform "Honk." 90% reduction in
  migration time. Engineers reportedly haven't written code since December 2025.

BCG reports 20% productivity gains after two days, 50%+ at scale. The key architectural insight
(per HackerNoon): evaluation scenarios must be held out from the agent during development,
preventing "teaching to the test."

- [BCG Platinion: The Dark Software Factory (Mar 2026)](https://www.bcgplatinion.com/insights/the-dark-software-factory)
- [Dark Factory pattern — HackerNoon (Feb 2026)](https://hackernoon.com/the-dark-factory-pattern-moving-from-ai-assisted-to-fully-autonomous-coding)
- [Simon Willison on StrongDM's Software Factory (Feb 2026)](https://simonwillison.net/2026/Feb/7/software-factory/)
