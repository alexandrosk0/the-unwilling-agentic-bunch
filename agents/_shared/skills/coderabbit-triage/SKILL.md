---
name: coderabbit-triage
description: Triage PR-bot review feedback — CodeRabbit or Cursor Bugbot findings on a pull request. Load on "address the CodeRabbit comments", "triage PR feedback", "PR bot review", "review comments on the PR", "fix the bot findings", a merge blocked on CodeRabbit or Bugbot threads, or the merge watcher's auto-act. Fetches every bot finding, validates it against the branch (stale / superseded / false-positive), rejects suggestions that break project rules (19-rule override table, first match wins, rule number cited), classifies severity, routes each survivor to its owning area and docs through the project's area map, files pre-existing product bugs as GitHub Issues, and emits a triage table plus per-finding handoff packets before any fix is applied. SKILL.md holds the judgement; REFERENCE.md holds the fetch commands, body-shape markers, report template and watcher dispatch.
triggers:
  - coderabbit
  - code rabbit
  - bugbot
  - PR bot
  - triage PR feedback
  - address review comments
  - PR review comments
  - CR-blocked
  - coderabbit-triage
version: 1
---

# coderabbit-triage

Run this in whatever session received the PR feedback — the main session, or the headless session the merge watcher spawns; it needs no dedicated subagent. It has two phases, in order: **triage** (read-only: fetch, validate, override, classify, route, report) and **apply** (§ Hand-back contract). Nothing is edited, committed or posted to the PR until the triage table is complete, so a finding the override table rejects is never applied, however harmless the bot's suggestion looks. Recipes cited by section name live in [`REFERENCE.md`](REFERENCE.md).

## Process

1. **Resolve the PR.** Use the number given; otherwise `gh pr view --json number,headRefName,baseRefName` for the current branch. No open PR → stop with `## Outcome: aborted` and the reason.
2. **Fetch** every bot artefact in parallel (REFERENCE.md § Fetch), keep only allow-listed bot authors and drop run-status noise (§ Bot allow-list).
3. **Parse** each surviving finding: `file` and `line` / `start_line` / `original_line` (review comments are line-anchored), the prose summary, any ```` ```suggestion ```` block, and the severity marker (REFERENCE.md § Body-shape markers). Bugbot anchors file and line in the comment metadata, never in the body.
4. **Validate** each finding against the branch (§ Validation states).
5. **Override** — check every live finding against § Override rules; first match wins.
6. **Classify severity** of the survivors (§ Severity).
7. **Route** each survivor to its area and docs (§ Routing).
8. **Report** the triage table and one block per finding (§ Report), file any pre-existing product bug (§ Pre-existing product bug), then delete the `.triage-*.json` dumps.
9. **Apply** per § Hand-back contract.

## Bot allow-list

Triage only comments whose author is an allow-listed PR bot: CodeRabbit (the logins in `project.config.json` `merge_gates.cr_bot_logins` — `coderabbitai[bot]` / `coderabbitai`) and Cursor Bugbot (`cursor[bot]` / `cursor`). REST returns the `[bot]` suffix and GraphQL may strip it, so match the bare and the suffixed form of each login. A Pro or self-hosted bot may post under a different login: confirm it against the fetched JSON before extending the list. Another PR bot (Greptile, Sweep) joins the list when it appears; the override, severity and routing rules then apply to it unchanged.

**Bugbot noise filter**: a `cursor[bot]` conversation comment whose body is a run-status notice — `### Bugbot couldn't run …`, `usage limit reached` — reports spend or availability, not a finding. Drop it before triage. The merge gate reads it as Bugbot's no-wedge TERMINAL signal, never as a block ([`merge-gates.md`](../../../../docs/agent-rules/merge-gates.md) gate 4).

## Validation states

Confirm each finding still applies at the branch head. Every state except **live** is kept in the triage table for audit and gets no handoff packet.

- **stale** — the review thread is already resolved or outdated (thread state: REFERENCE.md § Fetch).
- **superseded** — the cited `file:line` no longer has the cited shape because the branch rewrote it after the review: check `git diff origin/<base>...HEAD -- <file>` and read the slice. Name the commit.
- **false-positive** — the cited symbol, call site or pattern does not exist: one semantic search, or a text search for an exact symbol, confirms it.
- **live** — everything else; it goes on to the override rules.

## Override rules

Reject — do not route — a live finding whose suggestion matches a row below. **First match wins.** The triage-table cell `applies?` reads `no (override #N)` and the reason cites the number (`override #1 — C++14 hard`), so the user can check it. A suggestion that contradicts a rule this table does not list — a leaf `AGENTS.md` invariant, a project rule, the project's review checklist — is rejected the same way, citing that rule.

| # | Suggestion shape | Reject because |
|---|---|---|
| 1 | `std::string_view`, `std::optional`, `std::variant`, `std::filesystem`, structured bindings, `if constexpr`, designated initialisers, any other post-C++14 construct | C++14 hard: the code must compile on MSVC and Clang for engine compatibility (`AGENTS.md` § Project rules). |
| 2 | Add a windowing or GL include (`<GLFW/…>`, `<glad/…>`, `<GL/…>`) to a header in the shared core include tree | Dual-target: the engine target compiles those headers too (`no-glfw-in-core-headers`). |
| 3 | Define `IMGUI_USE_WCHAR32` (or another ImGui config macro) in a file or target | ImGui configuration comes from the one user-config header the ImGui library target publishes; a local define desyncs `ImWchar` across translation units. |
| 4 | Replace `LOG_*` with `printf`, `std::cerr`, `std::cout` or `fprintf(stderr, …)` | Logging contract: `LOG_*` only (`AGENTS.md` § Project rules). |
| 5 | Reassign an `nlohmann::json` object with a brace list (`obj = {…}`) | Won't compile; write `obj["k"] = v` ([`cpp-rules.md`](../../../../docs/agent-rules/cpp-rules.md) § nlohmann json). |
| 6 | Raw `new` / `delete` outside the named exceptions (`// C-ABI handle`, `// custom-deleter`, third-party adapter seams) | RAII, Pillar 3 — never crash (`cpp-rules.md` § Quality). |
| 7 | Bypass a chokepoint a leaf `AGENTS.md` mandates — e.g. call the HTTP library directly instead of the tracker's typed HTTP client | Leaf invariant; cite the leaf rule. |
| 8 | Inline a synchronous network, database, VCS or file call into code a UI frame reaches | Pillar 2 — the UI never freezes; work that can exceed 100 ms runs on a worker. |
| 9 | Drop `LOG_TRACE` / `LOG_DEBUG` from a non-trivial branch "for cleanliness" | `cpp-rules.md` § Quality requires them in non-trivial branches. |
| 10 | Add a backwards-compat shim, re-export or `// removed` comment for deleted code | Delete completely; every caller is in the repo. |
| 11 | Add a comment that restates WHAT the code does, or names the current PR, task or fix | Comments state durable intent (`pr-numbered-temporal-comments` and the comment-regrowth rules). |
| 12 | Wrap code that cannot throw in `try` / `catch`, or validate arguments from internal callers | Errors are caught at the boundaries [`exception-handling-policy.md`](../../../../docs/agent-rules/exception-handling-policy.md) names; internal callers are trusted. |
| 13 | Split a trivial-visual-only diff into separate PRs, or run the UI screenshot bucket on a palette or localization-literal swap | [`process-rules.md`](../../../../docs/agent-rules/process-rules.md) **Trivial-visual-only change envelope** lets that diff ship without it. |
| 14 | Edit an engine-only build target (`EXCLUDE_FROM_ALL`) or the engine plugin's packaged `ThirdParty/` output from a PR that does not target the engine build | Engine-only: outside the default build, and the plugin's `ThirdParty/` tree is packaging output. |
| 15 | Add a third-party dependency the build does not already pin | Outside the dependency budget — escalate to the `architect` agent. |
| 16 | "Drop `const&` and pass by value, the compiler will elide" on a non-trivial type | `const&` for non-trivial parameters (`cpp-rules.md` § Quality). |
| 17 | "Use `std::map` for deterministic order" where order does not matter | Prefer `std::unordered_map` on hot paths; changing a container for speed needs a measurement, not a review nit. |
| 18 | Rename a public symbol the task did not authorise | Scope creep: flag it for the user. A sanctioned rename follows `process-rules.md` § Mechanical edits. |
| 19 | Silence a strict-zone lint (`no-printf-stderr`, `no-raw-new`, `define-imgui`, `narrowing-conversions`) with an ad-hoc comment or `// NOLINT` | A strict-zone deviation uses the project's deviation marker — `<keyword>(rule=…; reason=…; owner=…; revisit=…)`, keyword from `project.config.json` `lint.deviation_keyword` (`cpp-rules.md` § Tiered enforcement) — so it carries a revisit date. Recommend that form. |

`agents/scripts/core/coderabbit-triage.py` is the executable mirror the merge watcher runs for its advisory PR comment: regexes for rules 1, 2, 4, 5 and 6, plus C++17/20 mentions. This table decides; the script is a coarse first pass.

## Severity

- **Critical** — build break, crash, data loss, ABI break, or a security implication (also hand it to the `security-review` agent).
- **High** — behaviour bug, leak, race, or a missed project invariant.
- **Medium** — convention drift that slows future readers.
- **Low / Nit** — cosmetic.

Bugbot states its own severity: `**High Severity**` → High, `**Medium Severity**` → Medium, `**Low Severity**` → Low / Nit. CodeRabbit's markers (REFERENCE.md § Body-shape markers) are read literally, then placed on this scale on the finding's merits.

## Routing

Each survivor gets a **target**: an area and the docs to read before fixing it.

1. **By finding kind**, whatever the path:
   - pure rename, typo, format-only, copyright bump, ignore-file line, localization literal → a mechanical edit ([`process-rules.md`](../../../../docs/agent-rules/process-rules.md) § Mechanical edits);
   - a crash repro or regression that needs `[temp-debug]` instrumentation before a fix is feasible → the `debug-instrument` skill;
   - a security finding (CWE, injection, secret leakage, unsafe deserialisation) → the `security-review` agent.
2. **By path, through the project's area map** — `docs/area-map.json` under the project root (`PROJECT_ROOT`): an ordered list of routes, each `{area, globs, docs}`; the **first route whose glob matches wins**. `python3 <agent-layer root>/agents/scripts/core/coderabbit-triage.py area <path>…` prints the route for each path. The route's `docs` (a leaf `AGENTS.md`, a guide or a header) hold the invariants the fix must keep: the packet names them, and whoever applies the fix reads them first.
3. **No route matches, or the finding spans areas** → the `architect` agent when it needs a design (it returns a design doc, then the fixes are dispatched); otherwise the nearest leaf `AGENTS.md` (the project's `CONTEXT-MAP.md` registry) and `cpp-rules.md`.

A project without an area map routes by step 1, then the nearest leaf `AGENTS.md`.

## Pre-existing product bug → GitHub Issue

A confirmed **pre-existing** product bug — a real defect in shipped behaviour that this PR neither introduced nor fixes — becomes a GitHub Issue (ADR-0014), never a `bug.md` entry (that category is deprecated). Apply the bug-vs-debt rule first: an internal-maintainability-only finding (duplication, god-object, coupling) goes to `debt.md`. Then follow [`issue-triage.md`](../../../../docs/agent-rules/issue-triage.md) § Orchestrator create-flow: dedup with `gh issue list --search`, and if nothing covers it, `gh issue create` with the labels `bug` + `P0`–`P3` + `area:<area>` (the finding's route area in the area map; a route with no area adds no area label) + `src:code-review`.

## Hand-back contract

The triage phase edits nothing and posts nothing. After the report, the session that loaded this skill:

- **applies** each VALID finding with the smallest change, reading its route's docs first; findings with disjoint write sets may go to parallel implementers ([`delegation.md`](../../../../docs/agent-rules/delegation.md)). The triage phase itself spawns nothing.
- **skips** every REJECTED finding and puts its rule and reason in the commit body.
- **commits and pushes** in the order `process-rules.md` **CR-fix commit sequencing** sets, so no reply cites a fix origin never received.
- **replies** to the bot once a fix lands (`gh pr review --comment`, or a thread reply via `gh api`), using each packet's reply line.
- **resolves** the addressed threads (GraphQL `resolveReviewThread`). A rejected or false-positive CodeRabbit thread that still blocks the merge takes the two-step override in `merge-gates.md` **CR false-positive override**.

This is the review agents' split: an investigator's severity-tagged list first, then the implementers.

## Watcher auto-act

When a PR is blocked on CodeRabbit findings and `MERGE_WATCH_AUTO_ACT=true`, the merge watcher spawns a headless session with `merge-watcher.py` `AUTO_ACT_PROMPT`. That session loads this skill, finishes the triage phase, then applies, commits and pushes. No user is present: an ambiguous finding stays REJECT-AMBIGUOUS and is listed in the commit body, never guessed. Dispatch steps: REFERENCE.md § Watcher dispatch.

## Report

Emit `## Triage table`, then `## Findings` with one `### #N` block per finding, then `## Outcome: applied | partial | aborted`, `## Session context append` (decisions locked across the round, with `file:line` evidence) and `## Self-improvement` (a recurring bot finding class that should become a `.coderabbit.yaml` `path_instructions` entry; an override rule you had to invent — promote it into the table; empty is fine). Template and worked examples: REFERENCE.md § Report template.

<!-- triage-rules-version: 5 -->
<!-- Bump in BOTH this file AND agents/scripts/core/coderabbit-triage.py whenever the
     login allow-list, override table, severity parse or noise filter changes;
     `coderabbit-triage.py selftest` fails on drift. v5: one skill replaces the agent
     and the handoff skill; rule 1 names std::filesystem; routing goes through the
     project's area map. v4: allow-list {coderabbitai[bot], cursor[bot]}, Bugbot
     body-shape severity parse, couldn't-run / usage-limit noise filter. -->
