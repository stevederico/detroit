# Detroit

Task in, pull request out. Detroit is the factory floor: it hands out tasks, runs many lines at once and keeps them running. Each line is a [Garden](https://github.com/stevederico/garden), which inspects the work on a repo. See `DESIGN.md`.

The previous version lives on the `alpha-archive` branch.

## Use

```bash
bin/detroit add "fix the login bug" --repo app
bin/detroit run
bin/detroit shift --hours 4 --parallel 3
bin/detroit dash
bin/detroit dash --web
bin/detroit install
```

`bin/detroit help` lists every command. Tests: `bash test/run.sh`.
