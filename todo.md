github issues
tasks folder support
screenshots
fix stage re-run loop
sandbox plan
CI gate with fix loop
support other providers via dotbot
adopt factory.md spec
declarative stages spec
- publish factory-md spec as standalone repo
- scheduleing daemon mode: --watch that polls tasks/ or uses fswatch, auto-processes new files or dotbot 
- context injection: load target repo CLAUDE.md and representative files into prompt
- sandbox-exceution - environment isolation: Docker or Modal sandbox per run (Ramp/Stripe parity)
- observability: post-deploy health check against production URL
- web dashboard for monitoring tasks and agent status - intake breadth: Slack, web UI, or PR comment triggers for non-engineer access
