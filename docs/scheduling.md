# Scheduling

Two parts: the nightly systemd timer that ships today, and the older research on scheduling through dotbot.

## Nightly timer (systemd, opencode on a local model)

`scheduling/` holds a systemd user service and timer. Every night at 01:00 local time the timer starts one shift on the local model:

```bash
DETROIT_AGENT=opencode ./factory.sh --shift
```

Install, from the detroit repo root:

```bash
bash scheduling/install.sh               # copy units, point them at this checkout, enable the timer
bash scheduling/install.sh --uninstall   # disable and remove them
```

| File | What it does |
|---|---|
| `scheduling/detroit-nightly.timer` | `OnCalendar=*-*-* 01:00:00`, `Persistent=true` (a run missed while the machine was off starts at next boot) |
| `scheduling/detroit-nightly.service` | `Type=oneshot`, sets `DETROIT_AGENT=opencode` and `PATH`, runs `factory.sh --shift`, appends output to `logs/nightly.log` |
| `scheduling/install.sh` | Writes both units to `~/.config/systemd/user/` with this checkout's path, then `enable --now` on the timer |

What a night looks like:

1. The shift takes `.shift.lock`. A second shift exits at once.
2. It checks the model endpoint (`curl $DETROIT_MODEL_ENDPOINT/models`, default `http://127.0.0.1:8090/v1`). Down: it logs `Model endpoint down` and exits 0.
3. It runs the next task in `tasks/`, the same pipeline as a no-flag `factory.sh`.
4. It repeats until the queue is empty, every task left has already run this shift, or `DETROIT_SHIFT_MAX_HOURS` (default 6) have passed. A task already started runs to its end. The service's `TimeoutStartSec=8h` is the hard stop.

Logs:

- `logs/nightly.log`: everything the service printed, all nights
- `logs/<timestamp>-shift.log`: one shift
- `logs/<timestamp>-w0.log`: one task

Useful commands:

```bash
systemctl --user list-timers | grep detroit      # next and last run
systemctl --user start detroit-nightly.service   # run a shift now
systemctl --user status detroit-nightly.service  # last result
```

To change the knobs, add `Environment=` lines with `systemctl --user edit detroit-nightly.service` (for example `DETROIT_SHIFT_MAX_HOURS=4` or `DETROIT_REPO=my-app`). The user manager only runs while you are logged in, unless lingering is on (`loginctl enable-linger`).

# Scheduling via dotbot (research)

Detroit needs a daemon mode (`--watch`) to auto-process new task files. dotbot already has a cron-like job scheduler (`schedule_job`, `list_jobs`, `toggle_job`, `cancel_job`) that fires prompts through the agent loop on recurring intervals.

> Since 0.59.0, `factory.sh --shift` covers the budget-bounded case without dotbot: cron starts a shift, and it runs tasks until the queue drains or the usage window reaches `DETROIT_BUDGET_STOP`. See [budget-shift.md](budget-shift.md). A `--watch` daemon is still open.

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
