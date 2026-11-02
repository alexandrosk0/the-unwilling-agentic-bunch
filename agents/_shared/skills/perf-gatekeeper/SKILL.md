---
name: perf-gatekeeper
description: Scenario-aware PR-time perf check. Load on "perf regression", "regression check", a named perf scenario or baseline, a red Perf PR-fast CI check that needs a focused re-run, a PR near merge that touches render / grid / per-frame code, or after a perf fix to confirm adjacent scenarios did not regress. Maps the touched files to scenarios through the project's curated diff→scenario map, runs each via scripts/dev/perf-run.sh, compares against the per-host baselines with scripts/dev/perf-compare.py, and reports PASS / FAIL / MISSING_BASELINE. A "regression" with no perf wording is a behavioural bug — the debug-instrument skill, not this one.
triggers:
  - perf-gate
  - perf-review
  - regression check
version: 2
---

# perf-gatekeeper (skill)

Targeted perf coverage for a diff without running the full scenario suite. Deterministic: diff → map lookup → run → compare → report. The CI gate (`.github/workflows/perf-pr-fast.yml`) is the merge block and runs a fixed set (`scripts/dev/perf-pr-fast-set.json`); this skill is the scenario-aware local / per-PR complement.

## When to invoke

- A PR touches first-party source (`Source/Core/`, `Source/Plugins/`, `Source/Standalone/`, …) and the orchestrator or the user wants a targeted perf check before merge.
- A perf fix landed and you need to confirm it did not regress adjacent scenarios.
- The Perf PR-fast CI check reported a regression and the user wants a focused re-run of the affected scenarios.
- The orchestrator's slice-boundary auto-run (process-rules.md § Perf slice-boundary auto-run) uses the same map and the same run → compare commands.

## The map

`scripts/dev/perf-scenario-map.json` in the host repo is the single copy of the curated diff→scenario map. Its `description` field states the matching rule; `rules[]` maps globs to scenarios, `fallback` names the scenario for an unmapped source file, and `screenshotOnly[]` lists registered scenarios that cannot be baselined (screenshot-only) together with the scenario they route to.

## Workflow

1. **Identify touched files** — `gh pr diff <pr-number> --name-only` (PR mode) or `git diff --name-only develop...HEAD` (local mode).
2. **Classify into scenarios** — each scenario runs once however many files map to it:
   ```bash
   git diff --name-only develop...HEAD | python3 -c '
   import fnmatch, json, sys
   m = json.load(open(sys.argv[1]))
   run, gaps, touched = [], [], False
   for p in sys.stdin.read().split():
       rules = [r for r in m["rules"] if any(fnmatch.fnmatchcase(p, g) for g in r["globs"])]
       for r in rules:
           run += [s for s in r["scenarios"] if s not in run]
           touched = touched or r.get("alsoRunTouchedScenario", False)
       if not rules and p.startswith("Source/") and "ThirdParty/" not in p and p.endswith((".cpp", ".h", ".hpp")):
           gaps.append(p)
   if gaps and m["fallback"] not in run:
       run.append(m["fallback"])
   print("scenarios:", " ".join(run))
   print("map gaps:", " ".join(gaps) or "none")
   print("also run each touched scenario:", "yes" if touched else "no")
   ' scripts/dev/perf-scenario-map.json
   ```
   "also run each touched scenario: yes" adds every scenario the diff adds or edits (its registered `Name()`). A map gap still runs the fallback and is reported.
3. **Run + compare** each scenario against the baseline for the current host (§ Hard rules):
   ```bash
   FRESH_JSON="$(bash scripts/dev/perf-run.sh <scenario> | tail -n1)"   # result path is the last stdout line
   python scripts/dev/perf-compare.py \
       docs/perf/baselines/<scenario>.<host>.json "$FRESH_JSON" --markdown-only
   ```
   `perf-compare.py` exits 0 within policy, 1 on regression, 2 on malformed input; `--markdown-only` prints the table and suppresses the regression exit code, so read the verdict from the table.
4. **Emit the aggregated report** (§ Output). In PR mode also post it: `gh pr comment <pr-number> --body-file <path>`.
5. **Verdict** — PASS = zero regressions under the regression policy (`docs/perf/regression-policy.json`, project.config.json `perf.policy`); FAIL = at least one; MISSING_BASELINE when any affected scenario has no baseline for this host. Put the verdict at the top of the report.

## Hard rules

- **Sort scenario rows by `lastTotalMs`, never `avgPerCallMs`** — a 200-call × 50 µs row outweighs a 1-call × 5 ms row in frame-budget terms.
- **Name the exact exe** after a rebuild: stale-exe testing is the most common false pass ([`debug-techniques.md`](../../../../docs/agent-rules/debug-techniques.md) § Exe staleness check). `perf-run.sh --exe=<path>` pins it.
- **Per-host baselines** — local development compares against `<scenario>.dev.json`; CI against `<scenario>.ci-windows-latest.json`; a P4-gated ship-loop machine against `<scenario>.$<PREFIX>_PERF_HOST.json`, where `<PREFIX>` is project.config.json `project.env_prefix` and the value is the developer's per-machine host name (`desktop`, `laptop`, …; set up per the host's `docs/perforce/SETUP.md` § Per-machine perf baseline). All coexist as checked-in files under `docs/perf/baselines/` (project.config.json `perf.baselines_dir`); pick the one for the current context and say in the report which host was compared. If the per-machine host variable is set but its baseline file is missing, report `MISSING_BASELINE` — never fall back to `dev`.
- **Read-only on baselines** — never edit `docs/perf/baselines/*.json`. Baselines change only through `bash scripts/dev/perf-baseline.sh bump <scenario>` (manual, explicit confirmation) or the scheduled `.github/workflows/perf-full.yml`.
- **No false pass on a missing baseline** — an absent baseline file is `MISSING_BASELINE` in the verdict, never a silent pass.
- **Screenshot-only scenarios route to their stand-in** — a scenario in `screenshotOnly[]` cannot be baselined; run its `routeTo` scenario and do not report the original as missing.

## Output

```markdown
## Perf-gatekeeper — PR <N> (verdict: PASS | FAIL | MISSING_BASELINE)

- Touched scenarios: <list>
- Host: dev | ci-windows-latest | <per-machine host>
- Map gaps: <unmapped source files, or none>

<per-scenario delta table — perf-compare.py --markdown-only output>

### Summary
- N scenarios scanned
- M regressions
- K baselines missing
```

## Handoffs

- **Regression confirmed** → diagnose it with the steady-state loop in the project perf guide (`docs/guides/perf-workflow.md`), using the `perf-instrument` and `perf-measure` skills.
- **A NEW p99 above the 10 ms floor** (project.config.json `perf.fps_floor_ms`) → the spike workflow in the same guide (§ Spikes).
- **Map gap** (a touched source file no rule covers) → add a rule to `scripts/dev/perf-scenario-map.json`; when no registered scenario exercises the path, add one (perf guide § Path A3; `test-authoring` skill § Pattern B) in the same PR.
