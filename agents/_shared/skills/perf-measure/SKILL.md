---
name: perf-measure
description: Run a perf measurement — `scenario.run --spawn`, or `perf.reset` → `perf.snapshot` against a running app — read the JSON and return the top rows by `lastTotalMs`, `perf_temp:` rows separated from pre-existing ones, plus `maxMs` / `p99Ms` for spike work. Load when a perf investigation needs numbers ("what's hot right now", "measure scenario X", before/after a perf fix, an "optimize X" or "profile X" request, the app is slow / low FPS / laggy / hitching / stuttering / freezing, a brief or intermittent stall / spike that recovers on its own), after markers are in. Holds the CLI-gap halt contract: never falls back to a manual UI session or reads FPS by eye. The investigation itself lives in the project perf guide.
triggers:
  - measure
  - snapshot
  - scenario
  - perf-run
  - optimize
  - profile
  - spike
version: 4
---

# perf-measure (skill)

Perf-measurement runner: CLI + JSON, no judgement. What to measure, how to read steady state vs spikes and when a fix counts are in the project perf guide (`docs/guides/perf-workflow.md` in the host repo).

**Tooling** — use direct file-read for written-out snapshot files. Use your harness's semantic codebase search only to locate a scenario definition by name.

## Prerequisites

Config must have `mcp_enabled: true`. **No running instance required** — `--spawn` (Path A1 in the perf guide) launches a hidden ephemeral app on a free port and tears it down at exit. List the registered scenarios with `cmd scenario.list --spawn` before naming one.

## Standard loop (Path A1 — fully automated, no user)

```bash
# 1. Build once per measurement cycle (skip if this round already built).
cmake --build --preset ninja-iter-msvc --target SmatchetStandalone

# 2. Run the scenario end-to-end. --spawn handles launch + MCP wait + result file + app.quit.
build/ninja-iter-msvc/Smatchet.exe cmd scenario.run \
  --name=<scenario> --frames=<N> --outPath=perf_<round>.json --spawn --yes

# 3. Read the result file directly — the snapshot rows are already inside .data.rows.
#    (No separate perf.snapshot call: scenario.run already wrote the snapshot.)
```

Filter / sort in-process:

```python
Read("perf_<round>.json")
# rows = json.data.rows sorted by -lastTotalMs; filter startswith("perf_temp:")
```

Name `perf_<round>.json` per round (`perf_before.json`, `perf_after.json`) so the before/after diff in the perf guide can read both.

## Path A2 — ad-hoc snapshot (running app, user drives the path)

Use only to explore when no scenario covers the path yet. A2 numbers steer a hypothesis; they never validate a fix or gate a PR — register a scenario (perf guide § Path A3) and validate on A1.

```bash
build/ninja-iter-msvc/Smatchet.exe cmd perf.reset    # against the running instance
# ← user reproduces the slow path for ~5 s
build/ninja-iter-msvc/Smatchet.exe cmd perf.snapshot --pretty
build/ninja-iter-msvc/Smatchet.exe cmd perf.snapshot \
  | jq '[.data.rows[] | select(.name | startswith("perf_temp:"))]'
```

## Sorting rule

**Sort by `lastTotalMs`, NEVER by `avgPerCallMs`.** A 200-call × 50 µs row (10 ms total) beats a 1-call × 5 ms row when you're trying to recover frame time. For spike work also carry each suspect row's `maxMs` (worst single call this frame) and `p99Ms` (over the recent per-call samples) — `avgPerCallMs` hides a spike.

## Consistency rule

For a before / after comparison, run the **same** scenario with the same `--frames` value. Numbers from different scenarios are not comparable.

## CLI unavailable — halt, never go manual

If `mcp_enabled: false`, `--spawn` can't reach the MCP socket within its ready window, `perf.snapshot` errors out, or the scenario the measurement needs is not registered, the measurement is **blocked**. Do not fall back to a manual UI session (process-rules.md § Verification automation — zero manual steps), and do not read FPS visually — you can't observe the GUI, and the rule disallows it even if you could. End the run with:

```
## Outcome: halted
halt_reason: cli-gap — <name the missing CLI surface, e.g. "MCP socket unreachable on --spawn", or "perf.snapshot errored: <message>", or "scenario `<name>` not registered with ScenarioRunner">
```

Then route it:

- **MCP socket unreachable / build broken** → fix the build per [`build.md`](../../../../docs/agent-rules/build.md) § Fix discipline, and file a `docs/self-improvement/categories/process/<YYYY-MM-DD>-<slug>.md` entry naming the failing target.
- **Scenario missing, or the path has no non-MCP CLI surface** → add the scenario (perf guide § Path A3; the `test-authoring` skill, § Pattern B) under `Source/Core/src/Commands/Scenarios/` on the same branch, then measure on A1.

## Report

```text
Spec executed: scenario <name>, <N> frames, preset <preset>, path A1 | A2 | A3
Top rows by lastTotalMs:
1. <name>  lastTotalMs=<ms>  calls=<n>  avgPerCallMs=<ms>  maxMs=<ms>  p99Ms=<ms>
2. ...

perf_temp:* rows: <list>  (markers the caller is tracking this round)
Pre-existing dominant rows: <list>  (context — what the perf_temp: markers compete against)
```

Show the top-5 rows, then the raw `perf.snapshot --pretty` block (or the result file's `.data.rows`) for reference.
