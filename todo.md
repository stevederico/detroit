# Detroit TODO

Updated with insights from AIE-26 code factory discussions (Ramp Inspect, Stripe Minions, dark factory patterns, self-compounding, engineering fundamentals).

## Completed

- [x] GitHub issues integration (`--issues`)
- [x] `tasks/` folder queue with priority
- [x] Screenshot verification (agent-browser + diff analysis)
- [x] CI gate with fix loop (max attempts)
- [x] Multi-provider support (Claude Code, dotbot, Grok CLI)
- [x] `factory.md` spec (8 sections: style, build, testing, documentation, environment, quality, observability, security)
- [x] Declarative stages (triage → plan → build → test → ship → monitor)
- [x] Strict rules with `!` prefix (must pass deterministically)
- [x] Web UI ("factory floor"): live agents, streaming logs, task queue, plan approval gate
- [x] Standalone `factory-md` spec repo published

## Pending / Next

### Self-Improving & Compounding (meta-game)
- [ ] Post-run extraction: after every task/correction, capture reusable patterns into lessons/rules and update `factory.md` or dedicated files
- [ ] Meta-compounding: build meta-skills that scan transcripts/runs and auto-improve other skills, rules, or standards
- [ ] Daily cycle: ship high-leverage work → extract/improve harness/skills/factory.md → repeat
- [ ] Memory systems: load `lessons.md`, `DECISIONS.md`, `KNOWN_ISSUES.md` + semantic search over history into agent prompts
- [ ] "The meta-game (personal agent OS that improves itself)" — track compounding rate as primary metric

### Dark Factory & Verification
- [ ] Dark factory mode: "one prompt, fully tested, no human" — spec in, tested code out, zero human writing or review for the change
- [ ] Enhanced self-verification before done: LLM-as-judge + "would staff engineer approve?" + visual/screenshots
- [ ] "Agents merge to main can't get it to stop" protection (pre-push hooks or stricter branch protection)
- [ ] Blueprints-style orchestration: explicit deterministic nodes (git/lint) interleaved with agentic nodes + post-eval critics

### Isolation & Execution
- [ ] Sandbox execution: Docker/Modal-style isolated environments per run (full Ramp/Stripe parity for Postgres/Redis/etc.)
- [ ] Scheduling daemon mode (`--watch` that polls `tasks/` or uses fswatch/dotbot jobs)
- [ ] Context injection: auto-load target repo's `CLAUDE.md` + representative files into prompt
- [ ] Parallel subagents: spawn dedicated agents for research, exploration, verification stages

### Tools & Extensibility
- [ ] MCP integration: expose factory tools, resources, and context via Model Context Protocol ("MCP engineers build once. Deploy everywhere.")
- [ ] Skills as folders: executable scripts + data + workflows (not just text prompts); evolve from edge cases/failures
- [ ] Broader deterministic gates for style, quality, security, etc.

### Observability, Evals & Intake
- [ ] Post-deploy observability: wire into Sentry/Datadog/LaunchDarkly etc. so the factory can verify its own shipped changes in production
- [ ] Evals harness: personal "SWE-bench for my workflows" — track error rate, context efficiency, tasks resolved per $, compounding progress
- [ ] Intake breadth: Slack, Linear, PR comments, Chrome extension/visual selection, in addition to `tasks/` and GitHub issues
- [ ] "Filesystem becomes part of the agent's brain" — deeper persistent memory and context across runs

### Full SDLC Coverage and Self-Improvement Loop
- [ ] Continuous signal ingestion and advanced triage to turn diverse inputs into owned goals and actions
- [ ] Long-running goal agents and multi-day autonomous missions/automations with coordinated multi-agent workflows
- [ ] Persistent remote execution environments for agents beyond local CLI
- [ ] Expanded automated quality gates: exhaustive code review, browser-driven test generation and QA, security reviews (STRIDE/OWASP style)
- [ ] Operations and knowledge layer: automated root cause analysis and postmortems, always-current documentation, deployment rollouts, outcome analytics
- [ ] Outcome metrics focus: signal-to-production cycle time, autonomy ratio (work with no human touch), incident MTTR, code shelf life, cost per merged change
- [ ] Enhanced governance: risk tiers per repo/project, policy enforcement (command allow/deny lists), full auditable trails; humans define the rules
- [ ] Sovereign deployment paths: easy support for on-prem, hybrid, and air-gapped setups
- [ ] Full-loop self-improvement: every stage (triage through operations) strengthens the others and the system compounds over cycles

## Key principles
- Success depends more on **engineering fundamentals** (the 8 stages + reproducible envs + fast tests) than model choice.
- Ramp: 30%+ of merged PRs, full sandboxes + observability wiring + self-verification.
- Stripe: 1,300+ PRs/week, ~500 MCP tools, devboxes, blueprints.
- StrongDM/Cursor examples: 35% agent-created PRs via dark factory approach.
- Key principle: "Without this [stage]: [specific failure mode for autonomous agents]"


