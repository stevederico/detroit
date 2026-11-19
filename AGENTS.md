# Detroit

Being rebuilt from the ground up. Read `DESIGN.md` first.

- Runner: the outer loop (Shift, Setup, Plan, Code, Done). Decides what runs.
- Factory: the inner loop, built by Garden (`~/Projects/garden`, formerly my-factory). Decides what passes. Put checks there, not here.
- Old Detroit: the `alpha-archive` branch.
- `archive/` holds the old Detroit's research, scheduling files, todo list and Code-stage rules, kept for the rebuild. `todo.md` holds ideas for the new one.
- `tasks/` is the task queue: one markdown file per task, finished ones in `tasks/done/`, failed ones in `tasks/failed/`.
