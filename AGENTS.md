# Detroit

Being rebuilt from the ground up. Read `DESIGN.md` first.

- Detroit is the factory floor: it hands out tasks, runs many lines at once and keeps them running. The Runner is its outer loop (Shift, Setup, Plan, Code, Done).
- Garden (`~/Projects/garden`, formerly my-factory) is an assembly line: the inner loop that decides what passes. Put checks there, not here.
- Old Detroit: the `alpha-archive` branch.
- `archive/` holds the old Detroit's research, scheduling files, todo list and Code-stage rules, kept for the rebuild. `todo.md` holds ideas for the new one.
- `web/dashboard.html` is the page `detroit dash --web` serves; it reads `status.json` from `detroit status --json`.
- `bin/detroit` is the whole Runner in one bash script. `test/run.sh` is its test suite; run it before every commit.
- `tasks/` is the task queue: one markdown file per task, finished ones in `tasks/done/`, failed ones in `tasks/failed/`.
