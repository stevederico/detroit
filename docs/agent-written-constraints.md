# Agent-written constraints (Uncle Bob model)

How Uncle Bob Martin runs agents without reading their code — and what Detroit would need to match it.

Source: [thread](https://x.com/unclebobmartin/status/2080257779395154409) (Jul 2026), especially [this reply](https://x.com/unclebobmartin/status/2080392677753790875). Related: [swarm-forge](https://github.com/unclebob/swarm-forge), [crap4java](https://github.com/unclebob/crap4java).

---

## The model

Bob does **not** review product code. He surrounds agents with a gauntlet so confidence comes from pass/fail tools, not from reading diffs.

| Artifact | Who writes it | Who reviews it |
|---|---|---|
| Product code | Agents | Nobody (Bob) |
| Unit tests | Agents | Nobody |
| Gherkin acceptance + QA procedures | Agents | Bob (spot-check → thorough by criticality) |
| Deterministic checker tools | Agents | Implicitly — tools are small; he sets thresholds |
| Metric / coverage thresholds | Bob | Bob |

Key quote:

> I have the agents write the tools that check the constraints. Those tools are deterministic. They are relatively small programs that check the quality of the code or check the coverage of the tests or manipulate the code and look for errors.

Layers he names: unit tests, Gherkin, scripted QA, quality metrics (function size, cyclomatic complexity), mutation testing, coverage, duplication checkers — “a plethora of others.” Overlapping layers make it harder for agents to game a single weak test.

Why structure still matters: messy code slows *agents*; they’ve gotten stuck in their own tangles. Constraints keep the factory moving.

Human role shifts to: **specs + thresholds + occasional manual smoke** — not line-by-line code ownership.

---

## What Detroit does today

| Bob layer | Detroit |
|---|---|
| Unit tests | Yes — Vitest policy; `!` gate runs the repo’s test script |
| Gherkin / acceptance | No |
| Scripted QA procedures | Partial — VERIFY + agent-browser screenshots (if installed) |
| Quality metrics | Thin — e.g. 500-line files, no new TODO/FIXME; most style is agent-trusted |
| Mutation testing | No |
| Coverage floors | No |
| Checker tools | Fixed `check_gate` patterns in `lib/gates.sh` + optional `` `check: <shell>` `` bullets — **framework authors** write these, not the task agent |
| Spec review (Gherkin/QA) | No first-class gate; plan approval is the closest human checkpoint |

Pipeline shape: CODE → GATES (`factory.md` bullets) → FIX → SHIP → CI → VERIFY → fail-closed to `tasks/done` or `tasks/failed`.

Detroit’s philosophy: **portable rules in `factory.md`**, some deterministic, some forwarded to the agent. Bob’s philosophy: **agents build the gauntlet**; humans audit the *behavioral* surface (Gherkin/QA) and set numbers.

---

## Gap in one line

Detroit hardcodes a few checks and trusts the agent for the rest. Bob has agents **author small deterministic programs**, then runs only those programs — so the human never needs to read implementation.

---

## What we’d need to go that far

### 1. Agent-authored checkers (the core move)

In CODE (or a dedicated stage), agents produce small tools under something like `tools/gates/` (or repo-local `scripts/check-*`):

- complexity / function-size scanner
- coverage threshold runner
- mutation harness (mutate → tests must fail)
- duplication / import / secret scanners as needed

Each tool: stdin/CLI in, exit 0/1 out, no LLM in the loop.

`factory.md` (or a manifest) lists which tools run and their thresholds. GATES only **executes** them — it does not re-implement policy in bash case statements.

### 2. Split review surface

| Review | Action |
|---|---|
| Unit tests + product code | Do not require human read (Bob default) |
| Gherkin / acceptance features | Human or plan-approval gate — required |
| QA procedure scripts | Same |
| Checker tool source | Prefer small + audited once; re-run is deterministic |

Wire plan/approve to “accept `.feature` + QA scripts,” not “read the PR diff.”

### 3. Overlapping layers (anti-gaming)

One green unit suite is not enough. Require several independent pass criteria so soft tests can’t paper over behavior:

- unit + Gherkin + mutation + coverage + metrics

Bob’s point: agents must change *many* test layers to cheat — harder than flipping one assert.

### 4. Thresholds owned by the factory, not the agent

Bob: “I set the constraints on the metric analysis and coverage tools.”

Detroit equivalent: numbers live in `factory.md` (or env), not invented per task by the agent:

```markdown
## quality
- ! function max 50 lines `check: tools/gates/fn-size.sh --max 50`
- ! cyclomatic complexity max N `check: tools/gates/cc.sh --max N`
- ! coverage min X% `check: tools/gates/coverage.sh --min X`
- ! mutation score min Y% `check: tools/gates/mutation.sh --min Y`
```

Existing `` `check: …` `` support in `gates.sh` already runs arbitrary shell — path of least resistance.

### 5. Optional: bootstrap library of checkers

First runs shouldn’t invent mutation testing from scratch every task. Ship (or generate once) a starter kit of checker scripts; agents extend them. Same idea as Bob’s small deterministic programs + fixed thresholds.

### 6. What not to confuse with “going that far”

- More prose in CODE prompts without exit-code gates → still agent-trusted
- VERIFY screenshots alone → useful QA, not a full gauntlet
- Framework-only `check_gate` keywords forever → scales poorly; agents writing tools is the leverage

---

## Minimal path for Detroit

1. Prefer `` `check:` `` (or a `tools/gates/` runner) over new bash `case` arms for every rule.
2. CODE prompt: ship checkers + Gherkin/QA for the change when the factory requires them.
3. Plan/approve gate: human signs off on acceptance + QA scripts.
4. GATES: run all listed tools fail-closed; FIX loop already exists.
5. Grow the layer list over time (coverage → metrics → mutation → …), same pipeline.

Success criterion: a factory operator can skip reading product diffs and still trust ship decisions from **deterministic tool exit codes** plus **reviewed behavioral specs**.
