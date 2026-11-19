# Detroit

Being rebuilt from the ground up. Read `DESIGN.md` first.

- Runner: the outer loop (Shift, Setup, Plan, Code, Done). Decides what runs.
- Factory: the inner loop, built by Garden (`~/Projects/garden`, formerly my-factory). Decides what passes. Put checks there, not here.
- Old Detroit: the `alpha-archive` branch. The removed Code-stage rules are in `archive/`.
- `docs/` is research on the old Detroit, kept for the rebuild. `todo.md` holds ideas.
- `tasks/` is the task queue: one markdown file per task, finished ones in `tasks/done/`, failed ones in `tasks/failed/`.
