# Why Shipyard

Shipyard does the same thing as GitHub Copilot Coding Agent and Claude for GitHub — task in, PR out, automated. The difference is it's a shell script you own.

## What Shipyard has that they don't

- **Task queue with priority** — file-based, numbered for order, not one-off prompts
- **Configurable standards and workflow** — edit `factory.md` (a portable, framework-agnostic spec) to control exactly what the agent does
- **Screenshot verification** — starts the dev server, reads the diff, screenshots the actual pages that changed
- **Runs locally** — no data leaves your machine except API calls to Claude
- **GitHub issues integration** — pull labeled issues into the queue, close them on completion
- **No vendor lock-in** — swap Claude for another model, change the pipeline, fork it

## What they have that Shipyard doesn't

- Hosted infrastructure (no local machine needed)
- Web UI
- No setup

## Who is Shipyard for

Developers who want to own their code factory. Same idea as self-hosting vs SaaS — you trade convenience for control.
