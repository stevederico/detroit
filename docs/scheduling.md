# Scheduling via dotbot

Detroit needs a daemon mode (`--watch`) to auto-process new task files. dotbot already has a cron-like job scheduler (`schedule_job`, `list_jobs`, `toggle_job`, `cancel_job`) that fires prompts through the agent loop on recurring intervals.

## How dotbot scheduling works

- `schedule_job` stores a prompt + interval in SQLite via `cronStore`
- `cron_handler.js` polls for due jobs, injects the prompt into `agent.chat()`
- The agent processes it using its 53 tools (files, web, memory, tasks, etc.)
- Supports one-shot and recurring intervals (`30m`, `2h`, `1d`, `1w`)

## The gap

dotbot's `run_code` tool is a sandboxed Node.js subprocess (no shell, no git, no arbitrary commands). So a scheduled job can't directly run `./factory.sh`.

## Options

### 1. Add a shell tool to dotbot

Add a `run_command` tool (~30 lines) to dotbot that does `execFile("bash", ["-c", cmd])`. Then a dotbot job could: "Check `tasks/` for new files, if any exist, run `./factory.sh`".

Pros:
- Smallest change (~30 lines in dotbot)
- Detroit gets daemon mode for free via dotbot's existing scheduler
- No fswatch, no custom polling, no crontab
- Job management via `dotbot jobs` CLI

Cons:
- Adds a shell execution tool to dotbot (security surface)
- Couples detroit scheduling to dotbot being installed

### 2. Make detroit a dotbot tool

Register a `detroit_run` tool in dotbot that triggers the factory pipeline. Usage: `dotbot "Schedule a job every hour to run detroit"`.

Pros:
- Clean separation — dotbot knows about detroit as a first-class tool
- Can pass context (which task, which repo) through the tool interface
- dotbot's scheduler, notifications, and audit trail all work automatically

Cons:
- More integration work than option 1
- Tighter coupling between the two projects

### 3. Use dotbot as the full runtime

Skip factory.sh entirely. dotbot's task system + file tools + scheduled jobs handle the full pipeline: pick task, route to repo, code, test, commit, PR.

Pros:
- Single runtime, no shell script
- Full audit trail via dotbot's event store
- Multi-provider scheduling + coding in one system

Cons:
- Major rewrite — factory.sh is ~1000 lines of battle-tested pipeline logic
- dotbot needs git tools, test runners, PR creation, CI gating
- Loses the deterministic shell stages that make the pipeline reliable

## Recommendation

Option 1 is the pragmatic choice. One small tool in dotbot, and detroit gets scheduling without building anything new. Option 2 is worth revisiting if dotbot becomes the primary way people interact with detroit. Option 3 is premature — factory.sh works, no reason to rewrite it.
