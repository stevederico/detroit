# Agent Providers

Research on making the agent layer swappable. Option 1 below shipped: `run_agent()` in `lib/agent.sh` runs the Grok CLI (default), Claude Code, or dotbot, chosen by `DETROIT_AGENT`.

## Current coupling

Every stage (TRIAGE, PLAN, CODE, FIX, CI FIX, VERIFY) calls `run_agent()` in `lib/agent.sh`. It picks the CLI from `DETROIT_AGENT` (`grok` default, `claude`, `dotbot`) and parses each CLI's stream format. `DETROIT_MODEL` sets the model for every call, for every agent. The prompts are model-agnostic. The pipeline logic (task routing, branching, linting, CI gating, PR creation) is plain shell with `git` and `gh`.

Originally `factory.sh` called `claude -p "prompt" --dangerously-skip-permissions` directly in 6 places.

## CLI landscape (as of 2026-04)

| CLI | Autonomous flag | Sandboxed? | Streaming? |
|---|---|---|---|
| Grok CLI (default) | `-p "prompt"` headless | No | `--output-format streaming-json` |
| Claude Code | `--dangerously-skip-permissions` | No | `--output-format stream-json` |
| Codex CLI | `--approval-mode full-auto` | Yes (network-disabled sandbox) | Yes |
| Gemini CLI | `echo "prompt" \| gemini` | Optional `-s` flag | Yes |
| aider | `--message "prompt" --yes-always` | No | Yes (default) |

opencode and Cursor lack headless modes — not viable as CLIs.

Only Codex CLI is sandboxed by default. Grok, Claude, Gemini, and aider give unrestricted filesystem + shell access. If the runner is the sandbox (GitHub Actions, Modal), the CLI's own sandbox doesn't matter.

## OpenCode as a runtime (Ramp's approach)

Ramp's Inspect agent uses OpenCode not as a CLI but as a **server with a typed SDK**. Source: https://builders.ramp.com/post/why-we-built-our-background-agent

Their stack:
- **Agent:** OpenCode (open-source, model-agnostic, plugin system)
- **Sandbox:** Modal VMs with pre-built repo images (rebuild every 30 min)
- **API:** Cloudflare Durable Objects (per-session SQLite)
- **Streaming:** Cloudflare Agents SDK (WebSockets)
- **Intake:** Slack, web UI, Chrome extension, VS Code

OpenCode advantages over CLI swapping:
- Model-agnostic by design (Claude, GPT, Gemini without changing orchestration)
- Structured as a server — embeddable in infra, not just shelling out
- Typed SDK, plugin system, unified interface

## Options

### 1. Swap CLI flags (minimal) — shipped

Abstract the call sites into a `run_agent()` function. Config var `DETROIT_AGENT` selects the CLI and flags. Shipped with `grok` (default), `claude`, and `dotbot`; codex, gemini, and aider are not wired up.

Pros: simple, no new deps, keeps shell script identity
Cons: each CLI has different streaming formats, error handling, quirks

### 2. OpenCode as runtime (Ramp model)

Replace CLI calls with OpenCode server. Gains model-agnostic agent, SDK, plugins. Bigger change — moves from shell-out to embedded runtime.

Pros: model-agnostic, what Ramp validated at scale, unified interface
Cons: new dependency, bigger rewrite, more complexity

### 3. Stay Claude-only — superseded

The original approach, replaced by option 1.

Pros: no abstraction overhead, one thing to maintain
Cons: vendor lock-in, can't use cheaper/faster models per task

## Sandbox + agent are independent decisions

The sandbox (where code runs) and the agent (what runs the code) are orthogonal:

- **Local + Grok (default), Claude, or dotbot** — current state
- **GitHub Actions + one CLI** — isolation without changing agent
- **GitHub Actions + any CLI** — isolation + swappable agent
- **Modal + OpenCode** — Ramp's approach, maximum flexibility
