# debug-instrument — reference recipes

The copy-paste mechanics for the loop in [`SKILL.md`](SKILL.md); the judgement (when, why, how many) lives there. Section names match SKILL.md's citations.

**Placeholders** (values come from `project.config.json`, read via `scripts/dev/project-config.sh`):

- `<iter>` — the iteration preset (first entry of `build.presets`); `<test-preset>` / `<asan>` — the test and sanitizer presets in `build.presets`; list the rest with `cmake --list-presets`.
- `<target>` — each entry of `build.targets` the touched code compiles into (shared core code compiles into every target).
- `<exe>` — `build.exe_path` with `{preset}` filled in, as an absolute path.
- `<helper>` — the NDJSON helper path, `<log-fn>` — the template's log function, `<debug-dir>` / `<session-id>` — the production helper's output, all named in SKILL.md § NDJSON helper; `<hex>` — this investigation's rolled 6-hex id.
- `<name>` / `<PREFIX>` — `project.name` / `project.env_prefix`.

## Instrument

Add each include and call with a `// [temp-debug]` marker, at the smallest set of sites that **distinguish the listed hypotheses from each other**. Template branch:

```cpp
#include "<path to the rolled helper, relative to this TU>"  // [temp-debug]

// at the suspect call site:
<log-fn>(
    __FUNCTION__,                       // location
    "h1",                               // hypothesisId: one of the listed hypotheses
    "selection out of range",           // message: short fixed text, no quotes
    static_cast<long long>(rowIndex));  // data.i: the value that separates hypotheses
// [temp-debug]
```

Use a distinct `hypothesisId` (`"h1"`, `"h2"`, …) per listed hypothesis; one site may emit several breadcrumbs when it separates two hypotheses by different values. **Cross-boundary**: the bug almost always sits at an interface whose two sides disagree about a contract (UI thread vs worker, command dispatch vs handler, parser vs payload builder, save vs load) — instrument **both sides**, each with its own `location` (or `hypothesisId`), so the log correlates them.

**Logger fallback** — only where the helper cannot be used (deep in a header where its include is intrusive, or bootstrap code that runs before the filesystem library is safe). Same marker rules:

- `LOG_TRACE("[temp-debug] %s ...")` inside tight loops, per-frame and per-cell paths.
- `LOG_DEBUG("[temp-debug] %s ...")` for occasional events.
- Never `LOG_INFO` / `LOG_WARN` / `LOG_ERROR` for a temporary breadcrumb.

**Marker rules** (helper and fallback alike): every temporary edit — include, call, log line, diagnostic toggle, sentinel value, repro scaffolding — carries the literal `[temp-debug]` on its line (prefix a log format string; add a trailing `// [temp-debug]` otherwise), so the single regex `\[temp-debug\]` finds the whole delta. Keep instrumentation out of public headers. No sleeps to "prove" a race. No behaviour change except a temporary diagnostic toggle, reverted before completion. Keep a round small, then build.

Useful values to log:

- Object identity — a stable ID first, a pointer only if needed.
- Thread identity — the project's UI-thread check (e.g. `UiThreadAffinity::IsOnUiThread()`) as 0/1, plus `static_cast<long long>(std::hash<std::thread::id>{}(std::this_thread::get_id()))` to tell workers apart.
- Old and new values; container sizes and indices; ownership / lifetime transitions; return values and error codes; command / scenario names; file paths and normalized keys.

## Build + exe freshness

```bash
cmake --build --preset <iter> --target <target>      # once per round, per touched target
ls -la <exe>                                         # report absolute path, size, mtime
bash scripts/dev/is-exe-fresh.sh --preset <iter>     # where the project ships it: exit 3 = STALE
```

A build that needs the production NDJSON channel uses an agent-debug-ON preset instead (SKILL.md § Production helper contract); it has its own build tree, so its exe is a different path — name the exe you built and the exe you ran. Rationale for side-by-side mtimes: [`debug-techniques.md`](../../../../docs/agent-rules/debug-techniques.md) § Exe staleness check.

## Run

Run the deterministic reproducer yourself; capture stderr and the NDJSON log.

```bash
<exe> cmd scenario.run --name=<repro> --frames=300 --yes 2> debug.log
<exe> cmd tickets.get --id=<id> 2> debug.log
ctest --preset <test-preset> -R <UnitName>           # pure-logic repros
```

`cmd` attaches to a running instance with `mcp_enabled: true`; adding `--spawn` launches an ephemeral instance for the one command (a light build always boots a hidden in-process instance). Discovery: `<exe> cmd commands.list --category=<cat>` · `commands.help --name=<cmd>` · `commands.search --query=<q>`.

Command groups (details via discovery):

- `debug.*` — `log` (emit a known breadcrumb into the runtime log) · `log_tail` (read the last N ring entries back; `--minLevel`, `--contains`) · `dump_self` (minidump of the live process, every thread's stack) · `mcp_status` (MCP reachability / last activity) · `thread_dump` (thread counts + whether `dump_self` has a writer here) · `dock.dump` (dock nodes) · `dock.reset` (recovery only, not a diagnosis) · `window.resize` (reproduce layout regressions) · `window.screenshot` (viewport evidence) · `lua_eval` (probe runtime state without rebuilding).
- `scenario.*` — `list` (discover deterministic scenarios) · `run --name=<n> --frames=<N> --yes` · `cancel` (stop active automation).
- `tickets.list_active` / `tickets.get --id=<id>` (ticket state) · `sync.tracker_status` (sync-layer state) · `app.version` (confirm build hash / version).

**Which `debug.*` commands survive a hang.** UI-thread marshalling (`RunOnUiThreadAsCommandResult`) waits with **no timeout**, so marshalling commands are useless exactly when the app is unresponsive:

| Safe — inline, answers while the UI thread is stuck | Blocks forever — marshals to the UI thread |
|---|---|
| `debug.log_tail` · `debug.dump_self` · `debug.log` · `debug.mcp_status` | `debug.dock.dump` · `debug.dock.reset` · `debug.window.resize` · `debug.window.screenshot` · `debug.grid.edit-burst` · `debug.lua_eval` · `debug.lua_log_test` |

`debug.lua_eval` / `debug.lua_log_test` marshal because the main Lua state is UI-thread-owned. A `--spawn` child proves MCP reachability before its command dispatches, so a child that then wedges still has a live server on a known port — run `debug.dump_self` against that port. Triage the dump: debug-techniques.md § Hang capture and § Dump triage.

## Read evidence

**Production helper** — `<debug-dir>/<session-id>.ndjson` (SKILL.md § Production helper contract):

```bash
jq -c 'select(.category == "temp-debug")' <session-id>.ndjson
jq -c '{ts, tid, scope, payload}' <session-id>.ndjson
```

**Template helper** — `debug-<hex>.log`: on Windows at the repo root (first `.git` ancestor of the exe) or beside the exe; elsewhere in the process working directory:

```bash
ls -la "$(git rev-parse --show-toplevel)/debug-<hex>.log" "$(dirname <exe>)/debug-<hex>.log"
jq -c 'select(.hypothesisId == "h1")' debug-<hex>.log            # one hypothesis
jq -c 'select(.location == "ApplySort")' debug-<hex>.log         # one call site
jq -c '{ts: .timestamp, loc: .location, h: .hypothesisId, i: .data.i, msg: .message}' debug-<hex>.log
```

Without `jq`: `grep -n '"hypothesisId":"h1"' debug-<hex>.log`.

**Logger fallback** — the standalone app writes a file sink by default: `<PREFIX>_DEBUG_LOG` if set, else `%LOCALAPPDATA%\<name>\<name>-<pid>.log` on Windows (`$TMPDIR/<name>-<timestamp>.log` elsewhere); its first lines record the path. `debug.log_tail --contains="[temp-debug]"` reads the same ring from a live process, and stderr capture (`<exe> 2> debug.log`) covers the rest:

```bash
grep -n "\[temp-debug\]" <log>
```

## Crash

Collect: the faulting thread; the top application frames; the exception code / signal; the assertion message; the faulting address if available; whether the crashing pointer / value was null, freed or out of range. A crash with no OS crash record, procdump capture, and `.dmp` triage (`cdb`, or `dump-triage.sh` without a debugger): debug-techniques.md § Crash capture (no WER dump) and § Dump triage (.dmp).

Pick **one** sanitizer per investigation:

```bash
cmake --preset <asan>
cmake --build --preset <asan> --target <target>
cmake --list-presets | grep -i -E 'asan|tsan'        # the other sanitizer presets
```

The MSVC ASan preset is ASan only (MSVC has no UBSan); the Clang ASan preset is ASan + UBSan; TSan has a Linux preset over a threading subset. Without a preset for the sanitizer you need, set `-D<PREFIX>_SANITIZER=asan|tsan|msan` on a Clang preset — MSVC does not support TSan, and MSan is Clang-only (needs `clang` / `clang++` on PATH; `winget install LLVM.LLVM`). Wiring: `cmake/Sanitizers.cmake`. Sanitizer runtime DLLs (`libasan-*`, `libtsan-*`, `libubsan-*`, `libclang_rt.msan*`) must be on `PATH` at launch — "DLL not found" on a sanitized exe is the runtime, not the build. Preset failures or a new sanitizer request: [`build.md`](../../../../docs/agent-rules/build.md).

## Scenario reuse + add

**Bug-class** = the smallest grouping that shares:

- an **injection point** — which tracker backend (real or fixture), which AI client (real or stub), which UI panel / command, which subsystem boundary; AND
- a **render path** — which scenario's `OnFinish` `rows[]` emission would have caught the regression (the `rows[]` shape that matches the observable failure).

Search (semantic search first, then text-search):

```bash
dir="$(dirname "$(git ls-files '*ScenarioRegistry.cpp' | head -n1)")"
ls "$dir"
grep -l "<suspect-symbol-or-panel>" "$dir"/*.cpp
```

**Parametrize** a match (CLI arg / fixture variant / new sub-case in its `OnFrame`) rather than fork a near-duplicate. **Fork** only when the existing scenario's render path is genuinely orthogonal — e.g. same panel, but the bug emits to a `rows[]` column the existing scenario does not assert on — and write the rationale into the report.

**Add**: one new `<Name>Scenario.cpp` implementing `IScenario`, whose `OnFinish` `rows[]` shape matches the observable failure (phase 0 dimension b), plus one `runner.RegisterFactory(...)` line in the scenario registry — no app-controller edit. Lifecycle and registration detail: the `test-authoring` skill § Pattern B. The scenario lands on the **same branch as the fix**, not a precursor PR. An intermittent bug's scenario defines a repeat loop and an expected failure signal (assertion / log line / `rows[]` value).

## Hypothesis + metric examples

Good hypothesis list (bad: a single unfalsifiable "it is probably a race"):

> 1. `TicketGridModel::ApplySort` invalidates row indices before `TicketSelection::Restore` reads them.
> 2. `OnFieldEditCommit` runs on a worker thread while the UI iterates the same `rows_` vector.
> 3. A layout-schema-version mismatch silently resets the selection during config load.

Metrics (the value the bug produces vs what the fix should produce):

- Bug → `selectedRowIndex = 2` after sort; fixed → `selectedRowIndex` follows the moved ticket.
- Bug → the second sync replays `pending_creates` count = 3; fixed → count = 0.
- Bug → the log shows `Draw` reading `rows_.size() == 0` then `5` in the same frame; fixed → size stable across the frame.

## Evidence-source catalogue

Before adding logs: stack trace, assertions, existing logs (`debug.log_tail` on a live process), command output, state-dump commands, sanitizer reports, debugger watch / backtrace, minidumps, existing tests. Instrument only when these cannot distinguish the hypotheses.

## Race / ordering checklist

1. Identify the shared state.
2. List every writer.
3. Name the expected owning thread.
4. State the synchronization contract (mutex, atomic, post-to-main-thread, publish-once).
5. Log thread identity and a sequence number at each read and write.
6. Prefer deterministic scheduling evidence over timing guesses.
7. Never add sleeps as proof.
8. Use TSan where the code compiles under it.

## Handoff

The packet:

- Target — the implementer and the leaf `AGENTS.md` it works under.
- Concrete cause (file:line where possible).
- Files likely involved.
- Allowed write set.
- Interface decisions already resolved.
- Invariants that must be preserved.
- Exact repro to rerun.
- The metric to re-check on the fixed build.
- Build targets to verify.
- Instrumentation already removed, and promoted log lines (file:line).
- `adversarial-RCA: <what was tried, why it held>` (P0 / crash-class).

## Promote logs

1. Level: `LOG_DEBUG` for development-time breadcrumbs, `LOG_INFO` for shipped operational state transitions; never `LOG_TRACE` (tight loops only — promote one only when its cost is proven negligible at the frame budget).
2. Strip the `[temp-debug]` marker; the line becomes permanent code.
3. Replace any template-helper call with the project `LOG_*` macros — a rolled template is deleted at § Cleanup 12b, so its calls cannot survive.
4. Rewrite the message in the project logger style (`LOG_DEBUG("module: did X with id=%d", id)`); drop `__FUNCTION__` boilerplate (the logger records source location).
5. List each promoted line (file:line) in the handoff packet — it ships with the fix, reviewed with it, not as a free edit.

## Cleanup

```bash
# 12a. Strip markers; expect zero hits outside vendored / build trees
git grep --untracked -n "\[temp-debug\]" -- . ':(exclude)ThirdParty' ':(exclude)build'

# 12b. Delete the helper ONLY when you rolled the template; a tracked helper is the
#      committed production helper — leave it, only your include/call lines go in 12a.
git ls-files <helper> | grep -q . || rm -f <helper>

# 12c. Delete the NDJSON logs this investigation wrote
rm -f "$(git rev-parse --show-toplevel)/debug-<hex>.log" "$(dirname <exe>)/debug-<hex>.log"
rm -f <debug-dir>/<session-id>.ndjson

# 12d. Rebuild clean
cmake --build --preset <iter> --target <target>
```

Report: zero `[temp-debug]` hits · helper state (rolled template deleted, or tracked helper untouched) · log deleted · final build status · fresh exe path + mtime.
