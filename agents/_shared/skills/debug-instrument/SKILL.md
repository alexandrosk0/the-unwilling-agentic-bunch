---
name: debug-instrument
description: Diagnose a behavioural bug — a crash, assert, exception or access violation, wrong output, a regression ("this used to work"), a hang that never recovers (a wedged process), something that "doesn't work" / is "broken" / "looks wrong", a sanitizer report (ASan / UBSan / TSan / MSan) or a minidump — as a paused, reproducer-first, hypothesis-driven loop with temporary `[temp-debug]` instrumentation, then hand the fix off. A debug request suspends the autonomous ship-loop (ship-loops.md § Debug-mode pause-loop). Not for sustained slowness, low FPS, frame hitches, or a brief / intermittent stall that recovers on its own (perf skills and the perf guide § Spikes). SKILL.md holds the judgement, the pause-loop, the NDJSON helper contract and the report shapes; REFERENCE.md holds the recipes.
triggers:
  - debug
  - bug
  - crash
  - regression
  - broken
  - hang
  - "doesn't work"
  - "looks wrong"
  - "wrong output"
  - "used to work"
  - sanitizer
  - minidump
  - temp-debug
  - debug-instrument
version: 4
---

# debug-instrument

Run this loop in whatever context received the bug — the main session or a spawned agent; it needs no dedicated subagent. This file says *what to do and why*; [`REFERENCE.md`](REFERENCE.md) has the shell, CLI and log recipes under the section names cited below. Every temporary edit carries the literal token `[temp-debug]` so one text-search finds the whole delta at cleanup. Pink-clear gap detection, exe staleness, crash capture, hang capture and dump triage live in [`debug-techniques.md`](../../../../docs/agent-rules/debug-techniques.md) and are mandatory whenever they apply.

## Scope and classification

**Own**: crashes, assertions, exceptions, access violations; wrong output, stale UI state, bad serialization, incorrect command behaviour; regressions ("worked yesterday", "only happens after X"); hangs that never recover — a wedged process, captured with `debug.dump_self` (§ 3); suspected races, lifetime bugs, data corruption, ordering bugs.

**Not this loop**: sustained slowness, low FPS or throughput, intermittent hitches / stutter, and a brief or recurring stall that recovers on its own ("sometimes hangs for a second" — a perf spike) → the perf skills (`perf-instrument`, `perf-measure`) and the project's perf workflow guide § Spikes; a *perf* regression caught by the scenario gate ("regression check", "perf regression", a named scenario or baseline) → `perf-gatekeeper`, while a "regression" without perf wording is behavioural and stays here; a build failure unrelated to the bug → [`build.md`](../../../../docs/agent-rules/build.md). Classify an ambiguous symptom first — do not instrument until the bug belongs to this loop.

Search order: semantic search first, file skeletons over full reads, text-search once semantic search has narrowed the area, full reads only for exact control flow, lifetimes, ownership or call-site detail. Never hide a bug with retries, caches, broad null checks or feature disablement.

## Debug-mode pause-loop (orchestrator side)

The trigger keywords, and the rule that a debug request suspends **both** the git and the P4-gated ship-loops, live in [`ship-loops.md`](../../../../docs/agent-rules/ship-loops.md) § Debug-mode pause-loop. While the investigation is open:

- **Pause-loop is not pause-everything.** Inside a round, edit instrumentation, build, run the reproducer and read logs freely; the pause is at the **round boundary** (§ 7.5), once the hypotheses are re-marked.
- No commit, push, PR or merge, and no speculative product edit until a hypothesis is confirmed. The default ship-loop would collapse diagnosis, ship the first plausible fix and discard the evidence; the pause-loop keeps each round's evidence in the user's hands.
- Resume only on a user signal: "fixed" · "still broken, here's the log" · "try hypothesis N" · "use this repro instead" · "the metric now reads X" · "skip to handoff" · "abort". A next-round signal loops back to § 2 (new hypotheses), or straight to § 4 when the call sites are already chosen.
- After § 12 cleanup and the user's acceptance of `propose-fix`, the ship-loop resumes **in the same session**: implement the fix from the § 11 handoff packet under the touched subsystem's leaf `AGENTS.md` invariants, or hand the packet to a spawned implementer.

## Headless auto-act (sanitizer CI failure)

When the merge-watcher's sanitizer auto-act (`MERGE_WATCH_AUTO_ACT_ON_SANITIZER`) runs this skill in a headless session, nobody can answer a question or a pause, so:

- **The sanitizer stderr is the reproducer.** The failing test re-run under the same sanitizer preset replays it deterministically; phase 0 is satisfied by construction — skip its question.
- **Skip the § 7.5 pause.** Run the rounds back to back. The three-round re-frame (§ 10) becomes a stop: report `## Outcome: failed` with the evidence instead of guessing.
- **After `propose-fix`, apply the fix in this session** — the smallest change that resolves the finding, with § 11's adversarial RCA first (a memory-safety finding is crash-class). Then run § 12 cleanup, rebuild, re-run the failing test under the same preset, and commit + push as the auto-act prompt directs. The prompt's head-SHA and attempt-budget guards override this skill.

## Loop

### Phase 0 — Concreteness check (one front-loaded question)

Before any state-mutating call (no edit, no build, no instrumentation), classify the bug description on three required dimensions:

- **(a) Breaking surface** — the component / scenario / file / panel / command where the failure manifests ("AI assistant streaming" is too broad; "`AiAssistantPanel::RenderMessages` after a 401 response" is concrete).
- **(b) Observable failure** — assertion text, exact log line, sanitizer excerpt, screenshot diff, perf delta, golden-image mismatch, or a symptom tied to a file:line / feature path ("looks wrong" alone fails).
- **(c) Input shape** — CLI args, scenario name, fixture path, Lua snippet, failing-doctest name, or a click-path that maps to a registered bucket-E UI-test action ("click around the UI until it breaks" fails; `scenario.run --name=... --frames=... --fixture=...` passes).

If any dimension is missing, batch **every** uncertainty into **one** `AskUserQuestion`: the missing dimension(s) plus symptom precision (exact error text / screenshot), reproducer availability, build target (iter / debug / publish; standalone or engine-embedded), the last-known-good commit or "worked yesterday" window, and the severity gate (blocking a ship = sanitizer build pre-authorised and longer cycles fine; background = short cycles). Never ask what you can derive (file existence, signatures, log paths) and never drip-feed later: this is the **only** user-input point in the loop — § 7.5 routes user *signals*, not questions. A fully specified input (a CI sanitizer stack + failing-test name, a failing scenario the session found, a review finding with file:line) needs zero questions — go to phase 0.5 and say so in the report.

### Phase 0.5 — Existing-scenario reuse search

Before adding a scenario, search the scenario directory for one whose **bug-class** (injection point + render path; definition and search recipe in REFERENCE.md § Scenario reuse + add) covers the failure. Order: **reuse > parametrize > fork > add**. Parametrize a match (CLI arg, fixture variant, new sub-case in its `OnFrame`) rather than fork a near-duplicate; fork only when the render path is genuinely orthogonal, and write the orthogonality rationale into the report; fall through to phase 1's scenario-add only when nothing covers the bug-class. Record the choice in the `missing-scenario` entry (§ Self-improvement).

### 1. Reproduce — reproducer-first contract (hard refusal)

The loop refuses to start without a deterministic reproducer: a CLI command (`<exe> cmd <name> ...`), a `scenario.run --name=<x>` invocation, a Lua snippet, a failing doctest (`ctest -R <Unit>`), or a registered bucket-E UI-test action. If none is supplied or discoverable **and** phase 0.5 found nothing to reuse or parametrize, the **first action is to add a scenario** that reproduces the bug, on the same branch as the fix. No "please re-click and observe" fallback; no instrumentation before a repro. Crash logs, minidumps, stack traces, assertion text and sanitizer reports are *evidence* (dimension b), not by themselves a reproducer — still wire a scenario that triggers them. An intermittent bug's scenario defines a repeat loop and an expected failure signal, so it is deterministic by construction. If `scenario.run` cannot drive the bug at all, load the `test-authoring` skill for that harness gap in parallel (flag it in § Self-improvement) instead of blocking this round.

### 2. Hypotheses (two to four)

Write **two to four** concrete, falsifiable causes, ranked by which single piece of evidence best tells them apart, and instrument the **cheapest to confirm or reject first**, not the one you find most likely. If you cannot list two, read more code before editing — single-hypothesis debugging confirms what you already suspect, and the bug is often the one you did not list. Each round either rejects a hypothesis or forces a new one; keep the list in every report and strike the rejected ones. Examples: REFERENCE.md § Hypothesis + metric examples.

### 3. Evidence and the metric

Prefer existing evidence (REFERENCE.md § Evidence-source catalogue); instrument only when it cannot distinguish the hypotheses.

**Live-process evidence comes before instrumentation.** If the process is still running, `debug.log_tail` reads its log ring over CLI/MCP, and for a **hang** — which the crash pipeline never sees — `debug.dump_self` captures every thread's stack for `dump-triage.sh`. Only the inline `debug.*` commands answer while the UI thread is wedged; the marshalling ones block forever (REFERENCE.md § Run; debug-techniques.md § Hang capture).

**Write the metric down before instrumenting**: the observable value or sequence the bug produces and what the fixed behaviour should produce. After the fix, re-run the reproducer and compare the same metric. Never accept "I think it's fixed".

### 4. Instrument

Only at the smallest set of sites that separate the listed hypotheses, on **both sides of the boundary** the bug crosses (UI thread ↔ worker, dispatch ↔ handler, save ↔ load, parser ↔ payload). Use the NDJSON helper (§ NDJSON helper); fall back to `LOG_DEBUG` / `LOG_TRACE` only where the helper is intrusive. Keep a round small, then build. No instrumentation in public headers, no sleeps to "prove" a race, no behaviour change except a temporary diagnostic toggle reverted before completion. Temporary C++ still passes the comment-noise gates ([`cpp-rules.md`](../../../../docs/agent-rules/cpp-rules.md) § Tiered enforcement). Recipe: REFERENCE.md § Instrument.

### 5. Build

One build per instrumentation round — batch the edits ([`process-rules.md`](../../../../docs/agent-rules/process-rules.md) § Cadence and verification). A build broken by instrumentation gets an instrumentation fix only, never a drift into a product fix. Then prove freshness: report the absolute path, size and mtime of the exe you will run (REFERENCE.md § Build + exe freshness).

### 6. Run

Run the deterministic reproducer yourself and capture stderr + the NDJSON log. Never substitute an interactive user repro for a checked-in one.

### 7. Read and mark

Parse the log (REFERENCE.md § Read evidence). Mark each hypothesis confirmed, rejected or open; add and re-rank any the evidence forces.

### 7.5. Wait-for-feedback gate

**Hard pause** after every instrument → build → run → read cycle: emit the mid-loop report (§ Report shapes) with exactly one next step —

- `propose-fix` — the cause is pinned (after § 11's adversarial RCA where it applies); ready to hand off.
- `next-round` — survivors need another round; name the new call sites and the new metric.
- `re-frame` — three rounds without progress (§ 10); ask whether the reproducer, the suspected subsystem or the symptom classification must change.
- `blocked` — missing repro, log, sanitizer build or CLI command; state the specific ask.

Until a resume signal arrives (§ Debug-mode pause-loop) do not edit, build or run anything: silent re-instrumentation across the pause produces stale logs and conflated evidence.

### 8. Crash

Stack evidence before logs (checklist: REFERENCE.md § Crash). **One sanitizer per investigation** — they cannot coexist at link/runtime: ASan + UBSan for lifetime / bounds / UB, TSan for data races, MSan for uninitialised reads; or a minidump / debugger backtrace when no sanitizer applies. Do not treat the final crash frame as the root cause without checking ownership and earlier mutation paths.

### 9. Race / ordering

A race hypothesis names the specific read, the write and the missing ordering / synchronization edge (checklist: REFERENCE.md § Race / ordering checklist).

### 10. Iterate and re-frame

Each round rejects the hypotheses the evidence disproves and either advances to a survivor or regenerates hypotheses from what the logs revealed — iterative narrowing, not refining one guess. After **three rounds** with no hypothesis confirmed and no new one emerging, stop and re-frame: wrong reproducer? stale exe? logs from the wrong run? wrong suspected subsystem? actually a perf / spike / build / config problem? Do not keep adding logs across unrelated code.

### 11. Hand off the fix

The investigation does not apply the product fix (except § Headless auto-act); it packages it (REFERENCE.md § Handoff) for the implementer — this session once the user accepts, or a spawned one — working under the touched subsystem's leaf `AGENTS.md`.

**Adversarial RCA before `propose-fix` (P0 / crash-class only).** Try to *refute* the pinned cause: a refute-hypothesis fan-out (parallel agents each argue a surviving alternative) or an inline **which-path-is-NOT-covered** self-check that names the code paths, inputs and orderings the cause does not explain and confirms the evidence rules each out. Record `adversarial-RCA: <what was tried to break it, why it held>` in the packet. A cause that survives ships; one that does not returns to § 2. Non-P0 bugs use the normal reject-by-evidence loop.

### 11.5. Promote useful logs

Before § 12 strips the rest, keep a line permanently only if **all** hold: it sits on a **boundary** (UI thread ↔ worker, dispatch ↔ handler, save ↔ load, parser ↔ payload, tracker request ↔ response); it logs a **state transition or error edge**, not a per-frame heartbeat or hot-loop value; it helped **this** investigation and plausibly helps a future one in the same area; it costs at most one cache line / one short string-format per call. Hard cap **≤ 3 promoted lines per investigation** — more means a subsystem logging slice, so flag it for the subsystem owner instead. Zero is valid and common: say "Nothing worth promoting" explicitly. Mechanics: REFERENCE.md § Promote logs.

### 12. Cleanup

Four mandatory steps (REFERENCE.md § Cleanup): **12a** strip every `[temp-debug]` marker (expect zero hits in code — the sweep skips docs and Markdown, which may mention the token in prose); **12b** delete the per-investigation helper **only if you rolled it** — never the tracked production helper; **12c** delete the NDJSON log; **12d** rebuild clean. Remove every diagnostic toggle, temporary repro artefact and temporary behaviour change not explicitly approved to stay; gitignore patterns are a safety net, not a substitute — delete explicitly. Report cleanup status and the final build.

### Standing rules

- Re-confirm a CI-sourced symptom (a red check, a CI sanitizer report) still reproduces on current develop before instrumenting it — CI symptoms decay (process-rules.md § Cadence and verification).
- Verify the rebuilt exe path and mtime every round; an empty log from the wrong exe is not evidence.

## NDJSON helper

Check first: `git ls-files tests/_debug/SmatchetAgentDebug.h`. Two helpers coexist at that path with different schemas and audiences — never roll the template over the tracked file.

| Aspect | Production helper (tracked) | Per-investigation template (untracked path only) |
|---|---|---|
| Source | `tests/_debug/SmatchetAgentDebug.h`, committed | `agents/_shared/templates/SmatchetAgentDebug.h.tmpl`, rolled into that path |
| Lifetime | persistent — never overwrite or delete | one investigation — deleted at § 12b |
| Call | `LOG_AGENT_DEBUG("temp-debug", msg)` or `SMATCHET_AGENT_DEBUG_LOG("temp-debug", json)` | `SmatchetAgentNdjsonLog(location, hypothesisId, message, dataInt)` |
| Line schema | `{ts, category, pid, tid, scope, payload}` | `{sessionId, location, hypothesisId, message, data:{i}, timestamp}` |
| Output | `<debug-dir>/<session-id>.ndjson` | `debug-<hex>.log` (REFERENCE.md § Read evidence) |
| Active | only where `SMATCHET_AGENT_DEBUG` is ON | always, in the TUs that include it |

### Production helper contract

- **Line fields**: `ts` ISO-8601 UTC with milliseconds; `category` from a closed set — `backend-call`, `ui-event`, `worker-handoff`, `lock-claim`, `scenario-phase`, `cli-command`, `temp-debug` (an out-of-set category prints an error to stderr and drops the line); `pid`; `tid` string; `scope` `<file>:<line>`; `payload` a caller-supplied JSON object (by convention `backend-call` carries `{method, url, status}`; the helper does not check keys). Investigation breadcrumbs use `temp-debug`.
- **Build flag**: ON in `ninja-iter-agentdebug-msvc` (iteration speed, its own `build/ninja-iter-agentdebug-msvc/` tree), the debug presets, the ui-test presets and the ASan presets; OFF everywhere else — `ninja-iter-msvc`, `ninja-test-msvc` and the publish presets included — where `SMATCHET_AGENT_DEBUG_LOG` is `((void)0)` and the sink stays empty however you instrument. `LOG_AGENT_DEBUG(category, msg)` (`Logger.h`) is always callable: NDJSON with `payload = {"msg": msg}` when ON, `LOG_DEBUG("[agent-debug:<category>] ...")` when OFF. Two iter-shaped exes exist — name the one you built and the one you ran.
- **Session id**: `SMATCHET_AGENT_DEBUG_SESSION_ID` when set at launch, otherwise `<unix-epoch>-<pid>`, exported to child processes. Pin it — export it before launching — so the read path is known; never guess. If the id is unknown and the run cannot be repeated with it pinned, halt with `## Outcome: aborted — SMATCHET_AGENT_DEBUG_SESSION_ID not set; re-run the scenario with it exported on an agent-debug build`.
- **Directory**: `SMATCHET_AGENT_DEBUG_DIR`, else `%LOCALAPPDATA%\Smatchet\agent-debug` (temp-dir fallback) on Windows and `$HOME/.smatchet/agent-debug` elsewhere; doctest redirects to `tests/_debug/scratch/<test-name>.ndjson`. One file per session, created (truncated) on the first emit — the directory too; a doctest redirect (`SetTargetPath`) opens and truncates its file at once, before any emit — and capped at 50 MB — on overflow a terminal `scenario-phase` line with `"name":"_overflow"` is written and logging stops. Each line is flushed (it survives a process crash); `SMATCHET_AGENT_DEBUG_FSYNC=true` only counts writes today — the stream sink does not fsync.
- **Missing- or empty-file semantic**: with the default sink, no `<session-id>.ndjson` after a run means the instrumentation never fired — the scenario never reached a wrapped scope (no product code logs to it permanently; only breadcrumbs do); a file that exists but is empty means every emit was rejected (check stderr for `[SmatchetAgentDebug] ERROR: invalid category`) or the first emit threw while serialising its payload (an invalid-UTF-8 string). Under a doctest redirect the file exists from the redirect on, so an empty file there means no emit ran at all. First rule out an OFF-build exe; then treat it as a signal: phase 0.5 picks a different scenario or phase 1 adds a scope on the real code path. It is never a pass.

### Instrument with the production helper (tracked)

Prefer `LOG_AGENT_DEBUG("temp-debug", std::string("h1 rowIndex=") + std::to_string(rowIndex));  // [temp-debug]` — it needs only `Logger.h`, and `msg` must be a `std::string`. For a structured payload, include the header by its path relative to the TU (`Source/Core/src/Logger.cpp` uses `"../../../tests/_debug/SmatchetAgentDebug.h"`) and call `SMATCHET_AGENT_DEBUG_LOG("temp-debug", nlohmann::json{{"loc", __FUNCTION__}, {"h", "h1"}, {"i", rowIndex}})`, putting the hypothesis id in the payload. Build an ON preset. The only `[temp-debug]` residue is your include and call lines; the tracked file stays untouched.

### Roll the template (untracked path only)

Pick one fresh 6-hex id per investigation (e.g. `61b011`) and reuse it for every helper + log of this investigation; never reuse a previous id, even for the same bug — that conflates runs.

```bash
git ls-files tests/_debug/SmatchetAgentDebug.h | grep -q . || {
  mkdir -p tests/_debug
  sed 's/__SMATCHET_AGENT_DEBUG_ID__/<hex>/g' \
      agents/_shared/templates/SmatchetAgentDebug.h.tmpl > tests/_debug/SmatchetAgentDebug.h
}
```

API: `SmatchetAgentNdjsonLog(location, hypothesisId, message, dataInt)` appends one line to `SmatchetAgentDebugLogPath()` — on Windows the first ancestor of the exe's directory (≤ 12 levels) that holds a `.git` **directory**, else the exe's directory — a linked worktree's `.git` is a file, so a worktree nested inside the main clone logs at the main clone's root and one outside it logs beside the exe; elsewhere the process working directory. `SmatchetAgentDebugTempLogPath()` (`Smatchet-debug-<hex>.log` in TEMP / `/tmp`) exists but the logger never writes it. The template does not escape strings: keep `location` / `message` fixed text without quotes or backslashes. `static` functions give per-TU copies (no ODR conflicts across instrumented TUs); it pulls no GLFW / OpenGL / DX12, so it compiles into both `SmatchetStandalone` and `SmatchetCore_DX12`; it uses `ghc::filesystem`. One `dataInt` per call — when a hypothesis needs strings or several ints, extend the rolled helper inline (still gitignored, still deleted) rather than letting the call sites drift. Call-site shape: REFERENCE.md § Instrument.

## Report shapes

**Mid-loop report** — at every § 7.5 pause:

```markdown
## Cycle <N>
Reproducer: <exact command / scenario / doctest>
Build / exe: <absolute path + mtime>

## Hypotheses (ranked by distinguishing-evidence cost)
1. <cause #1>  — status: confirmed | rejected | open
2. <cause #2>  — status: ...

## Evidence Delta (this round only)
<new log lines / sanitizer output / stack frames / metric reads>

## Next Step Proposal
propose-fix | next-round | re-frame | blocked
<one-paragraph rationale; for next-round the call sites + metric to add>

## AWAITING USER FEEDBACK
<the exact question or yes/no expected back, e.g. "did the patched exe still freeze on drag-reorder?">

## Outcome: halted
```

**Final report** — after § 12 cleanup, handoff-ready:

```markdown
## Hypotheses (final)
1. <cause #1>  — confirmed
2. ~~<cause #2>~~  — rejected: <evidence>

## Reproducer
<exact command, scenario, doctest, crash artefact or evidence source; scenario added/parametrized/forked + rationale>

## Metric (observable, before / after)
Before fix: <observed value or sequence>
After fix:  <observed value or sequence>

## Evidence Collected
<stack trace, NDJSON / `[temp-debug]` lines, sanitizer output, command output, screenshots>

## Files changed (temp-debug)
<files and breadcrumbs touched; BOTH sides of every thread / subsystem / save-load boundary>

## Findings
<per hypothesis: confirmed / rejected / replaced, with the evidence>

## Cause
<concrete explanation, file:line where possible>

## Promoted Logs (kept permanent)
- <file>:<line> · LOG_DEBUG | LOG_INFO · "<message>" · rationale
(≤ 3 entries, or the literal line "Nothing worth promoting.")

## Handoff (proposed fix)
<the REFERENCE.md § Handoff packet, including adversarial-RCA for P0 / crash-class>

## Cleanup
`[temp-debug]` code text-search (REFERENCE.md § Cleanup 12a): 0 hits
Helper: rolled template deleted | tracked production helper untouched
NDJSON log deleted: <path> → absent
Final build: <targets> → <status>
Fresh exe: <absolute path + mtime>

## Outcome: applied
```

**`## Outcome:` values**: `halted` — mid-loop pause awaiting user feedback (every § 7.5 gate); `applied` — cause pinned, cleanup done, handoff packet ready (or, headless, the fix pushed); `partial` — ≥ 1 hypothesis confirmed but more rounds needed, and the user approved a concurrent partial fix; `failed` — three rounds with no progress and the user chose to stop at the re-frame (or the headless stop); `aborted` — the user aborted before the cause was pinned, or the session id was unknown (§ Production helper contract).

## Self-improvement

Record only real friction: a missing or weak CLI command, log-discovery friction, missing scenario coverage, a missing sanitizer / build preset, an ambiguous ownership or threading invariant, repeated reproducer round-trips, or a useful debug pattern found in the codebase. Empty is fine.

**`missing-scenario`** (optional category) — when the reproducer-first contract forced a scenario add or parametrize before debugging could begin, record the **bug-class** (injection point — which tracker backend / AI client / UI panel / command — and render path, i.e. which scenario's `OnFinish` `rows[]` catches it), the **chosen scenario name**, and the **parametrization shape** when forking or parametrizing (e.g. "added `--state=401` CLI arg + an `OnFrame` sub-case to `ai-assistant-streaming-happy-path`"; empty when added fresh). These entries are pattern-mined quarterly to consolidate duplicate scenarios (several bug-classes sharing one injection point + render path); the `git-janitor` orphan-scenario sweep (step 10.5) is the inverse signal.
