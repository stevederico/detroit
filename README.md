# Detroit

Task in, pull request out. Being rebuilt as a Runner (outer loop) around the Factory (inner loop, built by [Garden](https://github.com/stevederico/garden)). See `DESIGN.md`.

The previous version lives on the `alpha-archive` branch.

## Use

```bash
bin/detroit add "fix the login bug" --repo app
bin/detroit run
bin/detroit shift --hours 4
bin/detroit install
```

`bin/detroit help` lists every command. Tests: `bash test/run.sh`.
