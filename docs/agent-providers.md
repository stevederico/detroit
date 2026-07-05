# Agent Providers

Detroit currently hardcodes Claude Code CLI. This doc captures research on making the agent layer swappable.

## Current coupling

`factory.sh` calls `claude -p "prompt" --dangerously-skip-permissions` in 6 places (CODE, FIX, CI FIX, VERIFY stages). The prompts themselves are model-agnostic. The pipeline logic (task routing, branching, linting, CI gating, PR creation) is plain shell with `git` and `gh`.

## CLI landscape (as of 2026-04)

| CLI | Autonomous flag | Sandboxed? | Streaming? |
|---|---|---|---|
| Claude Code | `--dangerously-skip-permissions` | No | `--output-format stream-json` |
| Codex CLI | `--approval-mode full-auto` | Yes (network-disabled sandbox) | Yes |
| Gemini CLI | `echo "prompt" \| gemini` | Optional `-s` flag | Yes |
| aider | `--message "prompt" --yes-always` | No | Yes (default) |

opencode and Cursor lack headless modes — not viable as CLIs.

Only Codex CLI is sandboxed by default. Claude, Gemini, and aider give unrestricted filesystem + shell access. If the runner is the sandbox (GitHub Actions, Modal), the CLI's own sandbox doesn't matter.

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

### 1. Swap CLI flags (minimal)

Abstract the 6 call sites into a `run_agent()` function. Config var `DETROIT_AGENT=claude|codex|gemini|aider` selects the CLI and flags. Ship today, low effort.

Pros: simple, no new deps, keeps shell script identity
Cons: each CLI has different streaming formats, error handling, quirks

### 2. OpenCode as runtime (Ramp model)

Replace CLI calls with OpenCode server. Gains model-agnostic agent, SDK, plugins. Bigger change — moves from shell-out to embedded runtime.

Pros: model-agnostic, what Ramp validated at scale, unified interface
Cons: new dependency, bigger rewrite, more complexity

### 3. Stay Claude-only

Keep current approach. Simplest. Already works.

Pros: no abstraction overhead, one thing to maintain
Cons: vendor lock-in, can't use cheaper/faster models per task

## Sandbox + agent are independent decisions

The sandbox (where code runs) and the agent (what runs the code) are orthogonal:

- **Local + Claude** — current state
- **GitHub Actions + Claude** — isolation without changing agent
- **GitHub Actions + any CLI** — isolation + swappable agent
- **Modal + OpenCode** — Ramp's approach, maximum flexibility
