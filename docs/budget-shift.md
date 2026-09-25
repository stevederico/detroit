# Budget shift

Detroit already takes the next file in `tasks/` and ships it. A shift keeps doing that while a resetting token window still has room, then stops.

## What stays

- `bash factory.sh` still runs exactly one task.
- Pick order stays filename sort, with the existing lock dir.
- A shipped task still moves to `tasks/done/`. A failed ship still moves to `tasks/failed/`.
- `--parallel`, `--issues`, and `--verify` stay as they are.
- `factory.md` stages do not change.
- The shift does not invent tasks and does not replay `tasks/failed/`.

## Command

```bash
bash factory.sh --shift
```

`--shift` is mutually exclusive with `--parallel`, `--issues`, and `--verify`. It may combine with `--dry-run` and `--repo`.

Environment:

| Name | Default | Meaning |
|---|---|---|
| `DETROIT_BUDGET_STOP` | `0.80` | Stop when the 5-hour session or the weekly limit reaches this fraction |
| `DETROIT_SHIFT_PAUSE` | `30` | Seconds to sleep between tasks |
| `DETROIT_USAGE_MAX_AGE` | `900` | Usage file older than this many seconds is stale |
| `DETROIT_AGENT` | `grok` | Which usage record to read. Already selects the CLI |

## Loop

1. If a focused Herdr workspace is `working` on the same agent kind as `DETROIT_AGENT`, log `idle — session in use` and sleep. Do not pick a task.
2. Read `~/.local/state/omarchy/agents/usage/<agent>.json`. Use the 5-hour session percent, and the weekly percent. If `DETROIT_MODEL` matches a scoped row, use that row. Otherwise use the unscoped session and weekly numbers.
3. If the file is missing or older than `DETROIT_USAGE_MAX_AGE`, run `omarchy-agent-usage-update` once and read again. If it is still missing or stale, exit 0 and log `idle — no fresh usage`. Do not start a task on a guess.
4. If either percent is at or above `DETROIT_BUDGET_STOP`, exit 0 and log which window stopped the shift.
5. If `tasks/` has no unlocked `.md` file, exit 0 and log `idle — no tasks`.
6. Run the existing pipeline once, the same path as a no-flag `factory.sh`.
7. Sleep `DETROIT_SHIFT_PAUSE`, then go back to step 1.

One shift is one worker. It does not spawn `--parallel` inside the loop.

## Usage file

Omarchy already writes this file. The Claude collector exposes a 5-hour session percent and a weekly percent, including model-scoped rows. The shift only reads that JSON. It does not call a provider usage API of its own.

A record that is a prepaid balance you keep, rather than a window that resets, does not start a shift. If the JSON has no resetting session or weekly limit, exit 0 and log `idle — budget does not reset`.

## Files

- `lib/shift.sh` holds the loop, the usage read, and the session check.
- `lib/args.sh` adds `--shift` and the mutual exclusion.
- `factory.sh` dispatches `MODE=shift`.
- `test/test_shift.sh` uses fixture JSON. No live Claude call.

## Tests

- Session at 0.79 and a fixture task: the loop would run once.
- Session at 0.80: exit before pick.
- Weekly at 0.80 with session at 0.10: exit before pick.
- Missing usage file, and a stale file after one refresh attempt: exit before pick.
- Empty `tasks/`: exit 0.
- Focused Herdr workspace with `agent_status: working` for the same agent: sleep, do not pick.
- Prepaid-only record: exit before pick.

## Order

1. Usage reader and fixtures.
2. `--shift` loop with a seam so tests call a fake pipeline.
3. Herdr session check.
4. Wire `factory.sh` and `usage()`.
5. One `--dry-run --shift` against a fixture task on this machine.

## Implementation notes (0.61.0)

- Grok is the default agent (`DETROIT_AGENT` unset). Grok's record has only a weekly window, so a default shift gates on weekly alone.
- Each task runs as a child `bash factory.sh [--dry-run]`, so the pipeline's own `exit` calls end that task, not the shift.
- Every task the shift ran goes in `DETROIT_SHIFT_SKIP`, which the child's PICK honors. A task left in `tasks/` (dry run, or stopped before SHIP) runs once per shift and never blocks the tasks behind it. The shift ends on `idle — no tasks`.
- PICK and the shift share `pick_task` (`lib/core.sh`). It clears stale locks before choosing, so the shift's peek and the child's pick agree. Filenames with spaces work.
- One shift at a time: `.shift.lock` (mkdir plus pid) in the Detroit root. A second shift logs `idle — another shift is running (pid N)` and exits 0. A lock whose pid is gone is taken over. While Herdr shows the session in use, the one shift sleeps. Cron can't stack more.
- Usage age comes from the record's `updatedAt`, falling back to the file mtime. The refresh is `omarchy-agent-usage-update <agent>`, cut off after 120s. Herdr calls are cut off after 10s and then count as free. The file path honors `XDG_STATE_HOME` like the collector does.
- `DETROIT_MODEL` matches a scoped row when every word of the row's model name (for example `Fable` in `Fable Weekly`) is a word of the model id (`claude-fable-5-1`). Each window uses the fuller of the matched row and the account-wide row, so a model row never hides the account limit.
- `DETROIT_MODEL` sets the model for every agent call, claude included, so the budget checked is the budget spent.
- A record with only a weekly window still runs. Only a record with no session or weekly window counts as prepaid.
- The shift logs to `logs/<timestamp>-shift.log` and reports its state in `.status/agent-shift`. Each child keeps its own `-w0.log` and `agent-0`.
