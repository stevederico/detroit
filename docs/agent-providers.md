# Agent Providers

Research on making the agent layer swappable. Option 1 below shipped: `run_agent()` in `lib/agent.sh` runs the Grok CLI (default), Claude Code, dotbot, or opencode, chosen by `DETROIT_AGENT`.

## Current coupling

Every stage (TRIAGE, PLAN, CODE, FIX, CI FIX, VERIFY) calls `run_agent()` in `lib/agent.sh`. It picks the CLI from `DETROIT_AGENT` (`grok` default, `claude`, `dotbot`, `opencode`) and parses each CLI's stream format. `DETROIT_MODEL` sets the model for every call, for every agent. The prompts are model-agnostic. The pipeline logic (task routing, branching, linting, CI gating, PR creation) is plain shell with `git` and `gh`.

Originally `factory.sh` called `claude -p "prompt" --dangerously-skip-permissions` directly in 6 places.

## CLI landscape (as of 2026-04)

| CLI | Autonomous flag | Sandboxed? | Streaming? |
|---|---|---|---|
| Grok CLI (default) | `-p "prompt"` headless | No | `--output-format streaming-json` |
| Claude Code | `--dangerously-skip-permissions` | No | `--output-format stream-json` |
| opencode | `run --auto "prompt"` headless | No | `--format json` |
| Codex CLI | `--approval-mode full-auto` | Yes (network-disabled sandbox) | Yes |
| Gemini CLI | `echo "prompt" \| gemini` | Optional `-s` flag | Yes |
| aider | `--message "prompt" --yes-always` | No | Yes (default) |

Cursor lacks a headless mode, so it is not viable as a CLI. opencode has one (`opencode run`) and is wired up as `DETROIT_AGENT=opencode`.

Only Codex CLI is sandboxed by default. Grok, Claude, Gemini, aider, and opencode give unrestricted filesystem + shell access. If the runner is the sandbox (GitHub Actions, Modal), the CLI's own sandbox doesn't matter.

## opencode on a local model

`DETROIT_AGENT=opencode` runs `opencode run --auto --format json -m <model> -- "<prompt>"` and parses the JSON events (`text`, `tool_use`, `error`).

- `DETROIT_MODEL` is `provider/model` as opencode names it. Default: `studio/mlx-community/Qwen3-Coder-Next-4bit`, the MLX model a Mac Studio serves at `http://127.0.0.1:8090/v1`.
- `--auto` approves every permission that is not explicitly denied. Same trust level as the other CLIs: no sandbox.
- A stage timeout kills the CLI as well as ending the read. A local model that stalls writes nothing, so it would never notice the closed pipe. `with_timeout` (`lib/core.sh`) kills the CLI's process group and the group of every descendant: opencode starts each tool command in its own session, so killing only its pid left them running.
- Preflight: before PICK, and before each `--shift` task, `agent_preflight` checks `gh auth token` (every agent), then `GET $DETROIT_MODEL_ENDPOINT/models` (default `http://127.0.0.1:8090/v1`, 10s) and that its `data[].id` list has the model id from `DETROIT_MODEL` (the part after `provider/`). An MLX server asked for another model tries to load it, so a 200 alone is not enough. On failure the run logs why and exits 0. Set `DETROIT_MODEL_ENDPOINT=none` when opencode points at a hosted model.
- No usage window: `--shift` skips the Omarchy usage record and stops on an empty queue or `DETROIT_SHIFT_MAX_HOURS` (default 6). See [budget-shift.md](budget-shift.md).
- The stage timeouts (TRIAGE 60s, PLAN and FIX 120s) were sized for hosted models. A local model has less room inside them.

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

Abstract the call sites into a `run_agent()` function. Config var `DETROIT_AGENT` selects the CLI and flags. Shipped with `grok` (default), `claude`, `dotbot`, and `opencode`; codex, gemini, and aider are not wired up.

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

- **Local + Grok (default), Claude, dotbot, or opencode** — current state
- **GitHub Actions + one CLI** — isolation without changing agent
- **GitHub Actions + any CLI** — isolation + swappable agent
- **Modal + OpenCode** — Ramp's approach, maximum flexibility
