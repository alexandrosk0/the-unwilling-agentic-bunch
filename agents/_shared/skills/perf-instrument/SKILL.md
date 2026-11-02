---
name: perf-instrument
description: Add or strip temporary `SMATCHET_UI_PERF_SCOPE("perf_temp:...")` perf markers. Load when a perf investigation needs numbers on a suspected hot path or blocking call — the app is slow, low FPS, laggy, hitches, stutters or freezes, a grid scroll or startup is slow, a perf regression needs locating — and again to strip every `perf_temp:` marker when the round ends. Encodes the overhead rules (string-literal names, one outer scope always safe, no nesting in million-call loops, no double-wrap, mandatory `perf_temp:` prefix, header include check). The investigation itself (hypothesis, steady-state vs spike, validation) lives in the project perf guide.
triggers:
  - instrument
  - perf-scope
  - perf-marker
  - perf-cleanup
version: 3
---

# perf-instrument (skill)

Mechanical perf-marker editor. It executes an instrumentation spec; it does not choose what to measure. The loop that produces the spec — hypothesis, steady-state vs spike classification, the spike scope plan, validation and the fix rules — is the project perf guide (`docs/guides/perf-workflow.md` in the host repo). Read it first, then come here for the edit.

**Tooling** — use **text-search** for exhaustive cleanup enumeration (you need every match). Call your harness's semantic codebase search only when the spec doesn't name a file and you need to locate a call site.

## The spec

A list of `(file, function-or-block, scope-name)` tuples, every scope name prefixed `perf_temp:`. Default shape: one outer scope per hot loop. Sub-scopes inside per-cell code only when the spec asks for them (relative ranking). A spec that names a block already covered by a committed scope reads that committed row instead of adding a marker.

## The macro

`SMATCHET_UI_PERF_SCOPE("perf_temp:<area>")` from `Source/Core/include/Ui/UiPerfMonitor.h`. Per-call overhead ~200–500 ns (two `steady_clock::now()`, a mutex lock, an O(N) linear scan over the scope names, a sample-ring push).

## Hard rules

- **`perf_temp:` prefix on every new scope.** Cleanup is one text-search call. Pre-existing non-`perf_temp:` scopes are never retagged.
- **String literal only.** The scope object keeps the raw `const char*` and reads it again when the scope ends, so a `std::string::c_str()` from a temporary, a `std::string` variable or a concatenated string dangles by then. Always a literal: `"perf_temp:RenderFooCell"`, not `("perf_temp:" + name).c_str()`.
- **One outer scope is always safe.** Wrapping the whole hot loop / render block is the default insertion shape.
- **Sub-scopes inside per-cell code are conditional.** Only insert them if the spec asks (the caller accepts that their own measurements are inflated and reads them as relative ranking).
- **Never nest inside a million-call inner loop** (e.g. glyph rendering inside font rasterization). Move the scope outward to its caller — overhead dominates the measurement otherwise.
- **Don't double-wrap.** If the target line is already inside a non-`perf_temp:` scope at the same block level, the inner one is redundant. Skip and report.
- **One rebuild per measurement cycle.** Insert every tuple of the spec, then build once — never one rebuild per marker (process-rules.md § Build / ctest cadence).

## Workflow

### Insert mode (instrumenting)

1. Take the spec verbatim.
2. For each tuple:
   - Read the function. Confirm the insertion point is NOT inside an inner per-cell loop unless the spec says so.
   - Insert `SMATCHET_UI_PERF_SCOPE("perf_temp:<name>");` at the requested position. Default: first line of the function body. Sub-scope: as the first line inside the requested `{ ... }` block.
3. Verify `#include "UiPerfMonitor.h"` is present in the file. Add it (alphabetised with other `Source/Core` includes) if missing.
4. Build to confirm no compile errors:
   ```
   cmake --build --preset ninja-iter-msvc --target SmatchetStandalone
   ```

### Cleanup mode (stripping)

1. Text-search for `SMATCHET_UI_PERF_SCOPE\("perf_temp:` across `Source/` and `tests/` (skip `ThirdParty/`) — that covers `Source/Core/`, `Source/Plugins/`, `Source/Standalone/` and every other first-party tree.
2. Delete every matching line (the macro statement; not the surrounding braces).
3. If a file now has an unused `#include "UiPerfMonitor.h"` (no other `SMATCHET_UI_PERF_SCOPE` calls remain), leave the include — other code in the file may add scopes later, and removing it is a wider judgement call.
4. Re-search to confirm zero matches. The project's marker-inventory test fails the test pass on any leftover `perf_temp:` marker, so a leak cannot ship silently — but strip before you commit, not after the gate fires.
5. Build `cmake --build --preset ninja-iter-msvc --target SmatchetStandalone` to confirm clean compile after the deletions.

## Report

- **Spec executed** — the tuples (insert mode) or the strip roots + search pattern (cleanup mode), copied verbatim.
- **Result** — each tuple as inserted / skipped (with the reason), files touched, the final `perf_temp:` match count (must be zero after cleanup), and the build target with pass / fail.
