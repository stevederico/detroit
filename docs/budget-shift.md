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
| `DETROIT_AGENT` | `claude` | Which usage record to read. Already selects the CLI |

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
