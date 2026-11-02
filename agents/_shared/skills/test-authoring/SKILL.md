---
name: test-authoring
description: Turn verification into deterministic, human-free tests. Load when adding, automating or fixing tests; when a plan, PR test-plan or report carries a manual verification step ("open X, click Y, observe Z", "visually verify", "user checks", eye-test); when drafting or auditing a plan's Verification section or bucket A-E test plan; when writing a doctest unit test or editing the test list; when wiring a UI-test-engine (bucket-E) test, CLI probe, scenario, screenshot scan or sanitizer run; or when creating or refreshing a golden image. Holds the judgement (every item maps to a bucket, never manual forever), the verification gate, the unit-rig rules and the copy-paste recipes.
triggers:
  - test-authoring
  - automate testing
  - headless test
  - manual verification step
  - replace manual verification
  - test plan
  - unit test
  - doctest
  - ctest
  - golden image
  - bucket-e
  - imgui-test-engine
  - cli-probe-test
  - scenario-test
  - screenshot-scan
  - sanitizer-test
  - mock-tracker
version: 2
---

<!-- Skill-only helper (no agent twin; registered in SKILL_ONLY_HELPERS). The single
     home for test automation: judgement + verification gate + unit-rig rules first,
     then the copy-paste recipes. Project facts about the rig (targets, test lists,
     fixtures, gating) live in the host's docs/guides/testing-surface.md. Cross-harness:
     Claude Code loads this skill on demand; other harnesses reach it through the
     on-demand table in AGENTS.md. -->

# test-authoring (skill)

Converts every verification step that needs a person ("open X, click Y, observe Z") into a deterministic CLI / scenario / screenshot / sanitizer / UI-test-engine assertion, and keeps unit tests honest. **Automate at every cost** — "truly interactive" is a gap to close (add a CLI probe, a scenario, a UI-engine test), never a permanent excuse.

Run it at three points: at plan time (find the automation path before coding), after the first verification round (cover the residue), and whenever a report hands back a manual step. Project facts — test targets, the explicit test list, shared fixtures, which lanes gate — live in the host project's `docs/guides/testing-surface.md`; read it before scoping test work.

## Judgement

### Every verification item maps to a bucket

| Bucket | What it looks like | Automation tactic |
|---|---|---|
| **A. Headless CLI probe / unit test** | "Function X returns Y" / "Lua snippet outputs Z" | A doctest case (§ Unit rig), or `debug.lua_eval` / a new `debug.<feature>_test` returning JSON that bash asserts on (§ Pattern A) |
| **B. Scenario + perf snapshot** | "Frame budget under N ms" / "Cache hit rate = 100% in steady state" | An `IScenario` subclass drives N frames and returns rows; bash asserts on row values (§ Pattern B) |
| **C. Screenshot diff** | "Cell renders red text" / "Icon visible" | `debug.window.screenshot` capture + sentinel-colour scan or golden diff (§ Pattern C) |
| **D. Sanitizer build** | "No UAF on shutdown" / "No leak after N runs" | Run the scenario under ASan / UBSan; the exit code is the assertion (§ Pattern D) |
| **E. UI test engine** | "Drag column to position X" / "Type into editor and see autocomplete" / "Click menu item and observe state" | The ImGui Test Engine drives the real widget tree — clicks, typing and drags become recorded test cases (§ Bucket E). Nothing escapes automation here; it only costs more setup. |

Every plan § Verification item maps to A, B, C, D or E. An item that fits no bucket marks a gap in the **test infrastructure**, not in the item: name the missing piece (e.g. "needs new CLI probe `debug.dock.layout_dump`", "needs a UI-engine harness for the dock layout") and file it as a **bucket-E follow-up** — never "manual forever". The same rule applies when drafting a plan: classify each Verification item into a bucket before coding; a step that is interactive today is bucket E with an explicit "wire the UI-engine test before or alongside the slice" follow-up.

### Deliverable shape

1. Classification table: item → bucket → rationale.
2. A driver script per feature, `scripts/dev/test-<feature>.sh` (assertions + exit codes per § Bash conventions).
3. A CLI probe command when internal state must be observable — registered once in the command registry like every other command, so every front-end reaches it (§ Pattern A).
4. An `IScenario` subclass for multi-frame state (§ Pattern B); a UI-engine test for widget interaction (§ Bucket E); a doctest case for pure logic (§ Unit rig).
5. A final report: item × automated equivalent × residue (§ Report format).

### Authoring discipline

- **No `[temp-debug]` markers left behind** in any new or touched source.
- **No commented-out code** — delete a one-off probe; ship a probe worth keeping.
- **Comment intent, not history** — `// Captures pre-mutation cache size for the regression assertion.`, never `// Added for PR #71.`
- **Single-purpose CLI test commands** — `debug.lua_log_test` does ONE thing. Split a "test 5 features" mega-command into five commands.

### Golden-image bootstrap pause

Every checked-in reference artefact a gate diffs against (`tests/golden/<scenario>.png`, a JSON snapshot, a deterministic byte stream) ships under [`golden-image-approval.md`](../../../../docs/agent-rules/golden-image-approval.md): build → hand the file and the launched app to the user → **wait for an explicit approve-golden verdict before `git add`**. The pause holds in both loop modes; a golden captured while a bug is live certifies that bug forever. That doc also says where the committed bytes must come from. Prefer dual-capture-no-golden (§ Pattern C) whenever both states are produced at runtime.

### Report mapping

When the work comes back as a delegated result, use the Maintenance shape from `delegation.md` § Agent output contract, with the § Report format template inside it:

- `## Pre-flight` — one row per audited Verification item with its current status: auto / manual / partial.
- `## Mutations applied` — one bullet per new artefact (driver script, scenario class, CLI probe, bucket-E test TU, doctest file) with its path and assertion count.
- `## Regression gate` — the feature script and the unified runner, each with its `Passed: N  Failed: 0` line.
- `## Residue requiring user action` — every item still manual, each with its own dated backlog entry `docs/self-improvement/categories/tooling/<YYYY-MM-DD>-<slug>.md` that names the missing infrastructure and the concrete next action. No residue: write `none`.

### Self-improvement is proactive here

The report's `## Self-improvement` lists **every** verification step met this round that needed a new CLI probe, scenario, debug command or UI-engine harness, plus the deferred-automation entry for any residue that stayed manual. An empty list is the rare case — only when the audited plan had zero manual residue.

## Verification gate

Before reporting done:

1. The new driver runs end-to-end and ends `Passed: <N>  Failed: 0`.
2. The unified runner picks it up: `bash scripts/dev/test-all.sh` globs every `test-*.sh` under its test roots, so a script named with the `test-` prefix auto-enrols, and the run still ends `Failed: 0`.
3. No `[temp-debug]` markers remain in any new source file (a text search returns zero hits).
4. Every new CLI command is registered: save the output of `"$EXE" cmd commands.list --mcp-port=<test port> --spawn --yes`, then search it for the command name.
5. The plan doc cross-links the work: the new script is listed in the plan's `## Verification` section, and `## Implementation log` gains a bullet (`process-rules.md` § Plan-doc family).
6. Every manual-residue item has its dated `tooling` backlog entry (§ Report mapping). Manual residue without a backlog entry fails the gate.
7. For a unit-test change: the **full** local test suite passes (§ Unit rig), not just the new file or CI's filtered subset.

## Unit rig

Rules for pure-logic unit tests (doctest + CTest). The project's targets, test-list layout, fixtures and run commands are in the host testing guide.

- **One test file per logical unit**; production headers and sources stay test-free.
- **One `TEST_CASE` per public function with non-trivial behaviour.** Cover the happy path plus at least one edge case: empty, oversized or malformed input, or a boundary value. Use `SUBCASE` for variants of one setup.
- **Prefer `CHECK` over `REQUIRE`.** `CHECK` keeps the test running after a failure, so one run reports every broken assertion; use `REQUIRE` only when a later line would crash on the bad value (null dereference, out-of-range index).
- **Capture expected values by running the code — never transcribe a golden from source.** A value read off the code is a guess: build and run the function or binary, then copy the actual output. A duration formatter that emits `"0h 30m"` rather than the `"Spent 30m"` you expected is the kind of gap this catches.
- **Assert shape, not an environment-dependent literal**, for any output that flows through locale, timezone, clock or float formatting. A hardcoded `"2026-03-15"` renders `"2026-03-14"` under a US timezone; CI runners use UTC, so the defect passes CI and fails only on a developer machine.
- **Append to the END of explicit test lists.** When the project lists test files by hand, add the new test and its production sources at the end of the relevant list, so parallel PRs that each add a test do not conflict; the merge order serialises them.
- **Never link production-only adapter TUs into a unit-test target.** An adapter that implements a deps interface against the live application controller drags that controller's unresolved symbols into the test link. Test through the fake deps fixtures instead.
- **Prefer pure units.** Lift the pure decision logic out of a heavy subsystem (a retry cap, a conflict-priority rule) into a free function or small header so it tests without the heavy dependency. A heavier surface (database, HTTP, UI state) is tested through the project's shared fixtures (in-memory or temp-file databases, fake deps, a loopback HTTP server), not skipped; widget interaction belongs in bucket E.
- **A failing new test means one side is wrong.** Fix the assertion when your reading of the contract was wrong. When the production code is wrong, that is a bug with its own diagnosis and fix; never bend the assertion to match it.
- **Build and run once, at the slice boundary**, after every test file and test-list edit is in place (`process-rules.md` § Cadence and verification). Run the full local suite before declaring a test-bearing slice done.

## Bucket E — ImGui Test Engine (wired)

**Status**: WIRED (per `docs/plans/shipped/imgui-test-engine-bucket-e-execution.md`). First test landed at `tests/ui/views_columns_reorder.test.cpp`; bash driver at `scripts/dev/test-ui-views-columns-reorder.sh`. Run via `cmake --build --preset ninja-ui-test-msvc`.

How the surface works today:

- `imgui_test_engine` fetched + built as `SmatchetImGuiTestEngine` (`cmake/ImGuiTestEngine.cmake`), pinned to a specific upstream SHA.
- ImGui configuration consolidated in `Source/Core/include/SmatchetImConfig.h` (wired via `IMGUI_USER_CONFIG`). Test-engine hooks gated on `SMATCHET_BUILD_UI_TESTS`.
- `UiTestScenario` (`Source/Core/src/Commands/Scenarios/UiTestScenario.cpp`) owns the engine lifecycle behind the standard `IScenario` contract. Driven from `Source/Standalone/main.cpp` via the post-`glfwSwapBuffers` hook.
- CLI: `ui_test.run --name=<filter> [--all]` returns pass/fail JSON. The filter is **substring-match with `^` (anchor-start) / `$` (anchor-end) modifiers** — NOT a glob. `*` does not work; use `ColumnsReorder` to match every `ColumnsReorder_*` test.
- Tests register via `IM_REGISTER_TEST(engine, category, name)` and add a `RegisterX(engine)` call to `tests/ui/ui_tests_registry.cpp::SmatchetRegisterAllUiTests`.

Adding a new bucket-E test:

1. New `tests/ui/<feature>.test.cpp`. Use a TU-local `Register<Feature>Tests(engine)` entry point + register the test inside.
2. Append the call to `SmatchetRegisterAllUiTests` in `ui_tests_registry.cpp`.
3. New bash wrapper at `scripts/dev/test-ui-<feature>.sh` mirroring `test-ui-views-columns-reorder.sh`. Auto-enrolled by `scripts/dev/test-all.sh`.

Gotchas the wire-up hit (record once, save the next agent):

- `IMGUI_TEST_ENGINE_ENABLE_COROUTINE_STDTHREAD_IMPL` MUST be 1 — `ImGuiTestEngine_Start` asserts on null `CoroutineFuncs`.
- `IMGUI_TEST_ENGINE_ENABLE_CAPTURE` MUST stay 1 — `imgui_te_engine.cpp` calls `ImGuiCaptureContext::*` unconditionally (no `#if` guards). Disabling capture loses link-time symbols. We never wire a `ScreenCaptureFunc` so the runtime cost is zero.
- `IMGUI_DEFINE_MATH_OPERATORS` must be defined BEFORE `imgui.h`. Setting it in `SmatchetImConfig.h` (read at `imgui.h` start via `IMGUI_USER_CONFIG`) is the right hook point.
- The engine's filter language is substring + `^` / `$` / `,` modifiers, NOT shell glob. Don't write `Views/*` — write `Views` or `^Views/`.
- Fresh-profile drivers MUST seed `whisper_setup_completed=true` (and ideally `backend_has_been_reachable=true`) in the test config — otherwise the first-launch `##WhisperSetupBanner` overlays the UI and silently swallows `ItemClick`s, failing click-driven tests with no obvious cause. The host's shared driver preamble (`scripts/dev/lib/ui-test-driver.sh`) does this with `ui_test_isolate_home --seed`; leave the seed off only for a suite that asserts first-run defaults.
- An item ref that resolves to nothing must HARD-FAIL with the literal ref text in the failure message — never `IM_CHECK_NO_RET(found); if (!found) return;`, which logs one failed check and then reads like a clean skip, so a renamed label silently degrades the test to a no-op. Keep a checkbox / button label that doubles as an item ref in ONE shared constant with the `T(key, fallback)` fallback string it mirrors, so a rename cannot drift the label and the ref independently.
- Any bucket-E test that performs a queue/field-edit WRITE MUST use `BucketE::UiTestWriteScope` (`tests/ui/_helpers/UiTestWriteScope.h`) to flip the fresh-profile `ReadOnlyMode=true` default OFF, and MUST HARD-FAIL — not skip — on a write failure once its env gates are met. A fresh profile defaults read-only, so an unscoped write is silently rejected and the test goes vacuously green.

Two more harness traps that read as product defects — a docked panel whose body stops being submitted once a sibling tab holds the dock node, and an open modal that inhibits input beneath it — are recorded with their fixes in the host testing guide § 2.1.

If a future bucket-E test needs synthetic input that the existing engine doesn't cover, the fallback is a recorded one-shot (mouse / key event log replayed via `ImGuiIO`) — but record the recipe so the next bucket-E item stays cheap.

## Authoring patterns

### Pattern A — CLI probe + bash assert

Smallest viable test. Two artifacts: a CLI command that captures state, a bash script that runs it and asserts the JSON.

**CLI command shape** (mirror `debug.lua_log_test` in `Source/Core/src/Commands/Builtin/BuiltinCommands_Debug.cpp`):

```cpp
{
    Command c = MakeCommand("debug.<feature>_test",
        "<one-line summary>",
        [&app](const nlohmann::json& args, const CommandContext& /*ctx*/) {
            // 1. Install ephemeral capture (sink, flag, etc.).
            // 2. Run the feature path via an existing public method.
            // 3. Read captured state into a json result.
            return CommandResult::Success(std::move(out));
        });
    c.Destructive = true;
    c.Idempotent = false;
    c.Params = {PString("<arg>", "<desc>", true)};
    reg.Register(std::move(c));
}
```

If the command runs Lua / requires the automation host, gate the body in `#if defined(SMATCHET_WITH_LUA_AUTOMATION)` with an `else` returning `ErrorCode::HandlerError`.

**Bash shape** (mirror `scripts/dev/test-lua-error-log.sh`):

```bash
#!/usr/bin/env bash
set -euo pipefail
EXE="${SMATCHET_EXE:-build/ninja-iter-msvc/Smatchet.exe}"
PY="${PYTHON:-python}"
# Non-default port forces --spawn to start a fresh child against the rebuilt exe
# (default port may be a stale running UI instance).
TEST_PORT="${SMATCHET_TEST_PORT:-58731}"

PASSED=0; FAILED=0
extract() { "$PY" -c "import sys,json,re; t=sys.stdin.read(); m=re.search(r'\{.*\}',t,re.S); d=json.loads(m.group(0)); print(json.dumps(d.get('data',{}).get('$1','MISSING')))"; }
assert_eq() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; PASSED=$((PASSED+1)); else echo "  FAIL  $1 expected=$3 got=$2"; FAILED=$((FAILED+1)); fi; }
assert_contains() { if echo "$2" | grep -q "$3"; then echo "  PASS  $1"; PASSED=$((PASSED+1)); else echo "  FAIL  $1 needle=$3"; FAILED=$((FAILED+1)); fi; }
run() { "$EXE" cmd debug.<feature>_test --code="$1" --mcp-port="$TEST_PORT" --spawn --yes 2>&1; }

OUT=$(run "<test code>")
assert_eq "<assertion label>" "$(echo "$OUT" | extract <field>)" "<expected>"
# ... more assertions

echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -gt 0 ] && exit 1 || exit 0
```

Always use `--code=<value>` not `--code <value>` — the latter is a positional arg and the CLI rejects it.

### Pattern B — Scenario + frame-driven assertion

When the path needs multiple frames (scroll, animation, cache warmup), use an `IScenario` subclass. Existing examples: `PriorityGridScrollScenario.cpp`, `LuaRecorderFuzzScenario.cpp`. The scenario:

1. Sets up state in `OnStart` (e.g. via `app.ScenarioRegisterLuaCachedProvider`).
2. Drives N frames in `OnFrame` (sets `scrollY_` etc.; runner reads `CurrentScrollY()`).
3. Tears down in `OnCancel` AND `OnFinish` — both must restore state.
4. Returns `UiPerfMonitor::Instance().GetLastFrameRows()` from `OnFinish` so bash can parse perf metrics.

Register in `Source/Core/src/Commands/Scenarios/SmatchetScenarioRegistry.cpp` next to the other `runner.RegisterFactory(...)` lines (the registration table the pre-refactor `scenarioRunner_->RegisterFactory(...)` calls moved into).

Bash drives it with `scenario.run --name=<name> --frames=<N> --mcp-port=<...> --spawn --yes`. Assert on row totals via the same `extract` helper, indexing into `data.rows[N]`.

### Pattern C — Screenshot scan

For visual regressions (red text, icon visible, layout shift), use `debug.window.screenshot` to write a PPM file then scan pixels for a sentinel colour (or count non-bg pixels).

```bash
"$EXE" cmd debug.window.screenshot --outPath=/tmp/shot.ppm --window=Scripting ...
# count red pixels in the "Lua Errors" panel region
"$PY" -c "import sys; data=open('/tmp/shot.ppm','rb').read(); ..."
```

Coordinate-based slicing of the PPM is brittle; prefer counting global colour-class occurrences (e.g. "≥ 100 pixels with R≥240 G≤80 B≤80 → red ErrorItems present"). Pink-clear (`glClearColor(1,0,1,1)`) is the existing pattern for UI-gap detection — see AGENTS.md § Debug techniques.

Prefer dual-capture-no-golden patterns (`scripts/dev/test-theme-roundtrip.sh`) when both states are produced at runtime within the same test — no checked-in artefact to enshrine.

#### Golden determinism recipe

A golden is trustworthy only if two fresh captures on the same machine self-diff within tolerance AND the capture does not depend on whose machine took it. A scenario that skips these steps renders ambient state, fails every fresh local diff, and teaches people to ignore the lane. Before bootstrapping a golden, make the driver + scenario:

1. **Isolate user data** — boot each capture against its own throwaway, empty user-data dir (the `<ENV_PREFIX>_USER_DATA` override; `env_prefix` in `project.config.json`). A real profile carries cached tracker credentials, so the frame shows a live backend: grid rows, async "Loading…", sync toasts, relative dates that rot with the wall clock.
2. **Turn the startup update check off** (`<ENV_PREFIX>_UPDATE_CHECK=0`) — its completion is network-timed and can paint the update modal over the capture frame.
3. **Pin the UI mode** in the scenario's start hook (and restore it on finish / cancel) — an auto mode keyed on framebuffer width can switch a narrow capture into a different shell that never draws the window under test.
4. **Dismiss live toasts** on the capture frame (the toast manager's dismiss-all) — wall-clock-timed toasts land on a different frame each run.
5. **Fast-fail every network / subprocess leg** the frame shows — clear the identity / credential / repo inputs so each async leg resolves synchronously to fixed text instead of racing a loading cue against a resolved state.
6. **Pin first-run state** — mark first-run setup flows completed so their banners never overlay the frame.
7. **One scenario tick per rendered frame.** The runner ticks once per frame (a former second tick site on the spawn loop is gone), so `--warmupFrames=N` means N rendered frames. A golden that flip-flops between two states run-to-run — widgets submitted twice, or a capture taken at half the intended warm-up — is the signature of a second tick site: fix the tick, never loosen the tolerance.

Then prove it: capture twice back-to-back and require the self-diff within tolerance before committing the golden.

### Pattern D — Sanitizer build run

For UAF / leak / heap-overflow checks at shutdown, run the scenario under ASan / UBSan. `cmake/Sanitizers.cmake` already wires the flags; the existing CMakePresets has sanitizer variants. Test script invocation:

```bash
cmake --preset ninja-msvc-asan
cmake --build --preset ninja-msvc-asan --target SmatchetStandalone
build/ninja-msvc-asan/Smatchet.exe cmd scenario.run --name=<feature>-stress --frames=600 --mcp-port=<...> --spawn --yes
# Exit code != 0 OR stderr contains "==ERROR: AddressSanitizer:" → fail
```

## Mock-tracker setup

Many cell-rendering tests need real Jira data (field catalog, ticket rows). Without a live tracker, `fieldMeta` is null and by-name providers never fire. Two viable mocks:

1. **Cache-seed**: write a fixture SQLite cache under `<userData>/cache/` with synthetic tickets + a fake field catalog before launching `--spawn`. Existing `LocalCacheManager` can be exercised this way. Heaviest but most realistic.

2. **Lua-injected catalog**: extend `debug.<feature>_test` to take a synthetic field-catalog arg, install it via a new `AppController::ScenarioSeedFieldCatalog(...)` helper. Lighter; requires a new public method.

Pick (2) for most cases — fewer moving parts. Add `AppController::Scenario*` helpers that mirror the lifetime contract of the existing `ScenarioRegisterLuaCachedProvider` (set up in `OnStart`, tear down in `OnCancel` / `OnFinish`).

## Bash conventions

The test-script convention: `scripts/dev/test-all.sh` states it in its header and its parser relies on it.

- `set -euo pipefail` always.
- Exit codes: 0 pass, 1 assertion fail, 2 missing binary/build.
- Env overrides: `SMATCHET_EXE`, `SMATCHET_TEST_PORT`, `PYTHON`.
- Print a banner per test group.
- Print a per-assertion `PASS` / `FAIL` line.
- Print a final `Passed: N  Failed: M` summary.
- Use a non-default `--mcp-port` so `--spawn` always launches a fresh child — the default port might be a stale running UI binary.

## Report format

```text
Audited <plan path> § Verification — N items.

Classification:
| # | Item                                          | Bucket   | Status |
|---|---|---|---|
| 1 | log_info shows in scrolling log               | A (CLI)  | automated → scripts/dev/test-X.sh |
| 2 | red [ERROR] color visible                     | C (shot) | automated → scripts/dev/test-X-visual.sh |
| 3 | window auto-opens on error                    | A (CLI)  | automated (flag captured via debug.lua_log_test) |
| 4 | drag column header to re-order                | E        | residue — needs ImGui Test Engine |

New artifacts:
- scripts/dev/test-X.sh           — N assertions
- BuiltinCommands.cpp +debug.X    — captures Y state

Residue (with concrete next action — NEVER "manual forever"):
- Drag/drop column re-order      — bucket E; wired (`tests/ui/views_columns_reorder.test.cpp` + `scripts/dev/test-ui-views-columns-reorder.sh`). Run: `bash scripts/dev/test-ui-views-columns-reorder.sh`.

Run: bash scripts/dev/test-X.sh         →   Passed: N  Failed: 0
Run: bash scripts/dev/test-all.sh       →   Passed: <total>  Failed: 0
```
